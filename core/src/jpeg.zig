//! Decodes a JPEG's DC coefficients alone: each 8×8 block's average color,
//! an image at an eighth of the full size (84×125 for a 667×1000 poster),
//! which is all a ThumbHash needs. Baseline and extended sequential JPEGs
//! are Huffman-decoded block by block, skipping the AC coefficients;
//! progressive ones need only their first DC scans. Arithmetic coding,
//! 12-bit samples, and CMYK aren't read.

const std = @import("std");

pub const Error = error{ NotJpeg, Unsupported, Corrupt, OutOfMemory };

/// Pixels as RGB, row by row.
pub const Image = struct {
    width: usize,
    height: usize,
    rgb: []u8,
};

const Huffman = struct {
    /// By the next 9 bits: the code's length (above 8 bits) and its symbol;
    /// 0 for a longer code.
    lut: [512]u16 = @splat(0),
    maxcode: [18]i32 = @splat(-1),
    valptr: [17]i32 = @splat(0),
    mincode: [17]i32 = @splat(0),
    values: [256]u8 = @splat(0),

    fn init(counts: *const [16]u8, symbols: []const u8) Error!Huffman {
        var h: Huffman = .{};
        if (symbols.len > 256) return error.Corrupt;
        @memcpy(h.values[0..symbols.len], symbols);
        var code: i32 = 0;
        var k: i32 = 0;
        for (1..17) |len| {
            const n: i32 = counts[len - 1];
            h.valptr[len] = k;
            h.mincode[len] = code;
            if (n > 0) {
                h.maxcode[len] = code + n - 1;
                if (len <= 9) for (0..@intCast(n)) |i| {
                    const c: usize = @intCast(code + @as(i32, @intCast(i)));
                    const shift: u4 = @intCast(9 - len);
                    const entry: u16 = @intCast((len << 8) | h.values[@intCast(k + @as(i32, @intCast(i)))]);
                    for (c << shift..(c + 1) << shift) |p| {
                        if (p < h.lut.len) h.lut[p] = entry;
                    }
                };
            }
            code += n;
            k += n;
            code <<= 1;
        }
        h.maxcode[17] = std.math.maxInt(i32);
        return h;
    }
};

/// Entropy-coded bits, stopping at the next marker (and reading zeros past
/// it), with `FF 00` unstuffed.
const Bits = struct {
    data: []const u8,
    pos: usize,
    acc: u64 = 0,
    n: u7 = 0,
    marker: bool = false,

    fn fill(b: *Bits) void {
        while (b.n <= 48) {
            var byte: u8 = 0;
            if (!b.marker and b.pos < b.data.len) {
                byte = b.data[b.pos];
                if (byte == 0xff) {
                    if (b.pos + 1 < b.data.len and b.data[b.pos + 1] == 0) {
                        b.pos += 2;
                    } else {
                        b.marker = true;
                        byte = 0;
                    }
                } else b.pos += 1;
            }
            b.acc = (b.acc << 8) | byte;
            b.n += 8;
        }
    }

    fn peek(b: *Bits, k: u5) u32 {
        b.fill();
        return @intCast((b.acc >> @intCast(b.n - k)) & ((@as(u64, 1) << k) - 1));
    }

    fn get(b: *Bits, k: u5) u32 {
        if (k == 0) return 0;
        const v = b.peek(k);
        b.n -= k;
        return v;
    }

    fn decode(b: *Bits, h: *const Huffman) Error!u8 {
        const e = h.lut[b.peek(9)];
        if (e != 0) {
            b.n -= @intCast(e >> 8);
            return @truncate(e);
        }
        var len: u5 = 10;
        while (len <= 16) : (len += 1) {
            const code: i32 = @intCast(b.peek(len));
            if (code <= h.maxcode[len]) {
                b.n -= len;
                const i = h.valptr[len] + code - h.mincode[len];
                if (i < 0 or i > 255) return error.Corrupt;
                return h.values[@intCast(i)];
            }
        }
        return error.Corrupt;
    }

    /// A value of `s` bits, sign-extended as JPEG codes it.
    fn receive(b: *Bits, s: u8) Error!i32 {
        if (s == 0) return 0;
        if (s > 16) return error.Corrupt;
        const v: i32 = @intCast(b.get(@intCast(s)));
        return if (v < (@as(i32, 1) << @intCast(s - 1))) v - (@as(i32, 1) << @intCast(s)) + 1 else v;
    }

    /// After a restart interval: discards what's buffered and steps over
    /// the `RSTn` marker.
    fn restart(b: *Bits) void {
        b.acc = 0;
        b.n = 0;
        b.marker = false;
        const at = nextMarker(b.data, b.pos);
        if (at + 1 < b.data.len and b.data[at + 1] >= 0xd0 and b.data[at + 1] <= 0xd7) b.pos = at + 2 else b.pos = at;
    }
};

/// The offset of the next marker other than a restart, from `from`.
fn nextScanEnd(data: []const u8, from: usize) usize {
    var i = from;
    while (i + 1 < data.len) : (i += 1) {
        if (data[i] != 0xff) continue;
        const m = data[i + 1];
        if (m == 0 or m == 0xff or (m >= 0xd0 and m <= 0xd7)) continue;
        return i;
    }
    return data.len;
}

/// The offset of the next marker, restarts included.
fn nextMarker(data: []const u8, from: usize) usize {
    var i = from;
    while (i + 1 < data.len) : (i += 1) {
        if (data[i] == 0xff and data[i + 1] != 0 and data[i + 1] != 0xff) return i;
    }
    return data.len;
}

const Component = struct {
    id: u8,
    h: u8,
    v: u8,
    tq: u8,
    /// Blocks per row and rows, padded to whole MCUs.
    stride: usize = 0,
    rows: usize = 0,
    dc: []i32 = &.{},
    seen: bool = false,
    td: u8 = 0,
    pred: i32 = 0,
};

/// Decodes `bytes`' DC coefficients into an image an eighth of its size.
pub fn decodeDc(arena: std.mem.Allocator, bytes: []const u8) Error!Image {
    if (bytes.len < 4 or bytes[0] != 0xff or bytes[1] != 0xd8) return error.NotJpeg;
    var quant: [4][64]u16 = @splat(@splat(1));
    var dc_tables: [4]?Huffman = @splat(null);
    var ac_tables: [4]?Huffman = @splat(null);
    var comps: [4]Component = undefined;
    var ncomps: usize = 0;
    var width: usize = 0;
    var height: usize = 0;
    var progressive = false;
    var restart_interval: usize = 0;
    var adobe_rgb = false;
    var hmax: u8 = 1;
    var vmax: u8 = 1;
    var mcux: usize = 0;
    var mcuy: usize = 0;

    var pos: usize = 2;
    while (pos + 4 <= bytes.len) {
        if (bytes[pos] != 0xff) return error.Corrupt;
        const marker = bytes[pos + 1];
        if (marker == 0xff) {
            pos += 1;
            continue;
        }
        if (marker == 0xd9) break;
        const len = std.mem.readInt(u16, bytes[pos + 2 ..][0..2], .big);
        if (len < 2 or pos + 2 + len > bytes.len) return error.Corrupt;
        const seg = bytes[pos + 4 .. pos + 2 + len];
        pos += 2 + len;
        switch (marker) {
            0xdb => { // DQT
                var i: usize = 0;
                while (i < seg.len) {
                    const pq = seg[i] >> 4;
                    const tq = seg[i] & 3;
                    i += 1;
                    for (0..64) |k| {
                        if (pq == 0) {
                            if (i >= seg.len) return error.Corrupt;
                            quant[tq][k] = seg[i];
                            i += 1;
                        } else {
                            if (i + 1 >= seg.len) return error.Corrupt;
                            quant[tq][k] = std.mem.readInt(u16, seg[i..][0..2], .big);
                            i += 2;
                        }
                    }
                }
            },
            0xc4 => { // DHT
                var i: usize = 0;
                while (i + 17 <= seg.len) {
                    const class = seg[i] >> 4;
                    const th = seg[i] & 3;
                    const counts = seg[i + 1 ..][0..16];
                    var total: usize = 0;
                    for (counts) |c| total += c;
                    i += 17;
                    if (i + total > seg.len) return error.Corrupt;
                    const h = try Huffman.init(counts, seg[i .. i + total]);
                    if (class == 0) dc_tables[th] = h else ac_tables[th] = h;
                    i += total;
                }
            },
            0xdd => { // DRI
                if (seg.len < 2) return error.Corrupt;
                restart_interval = std.mem.readInt(u16, seg[0..2], .big);
            },
            0xee => { // APP14: Adobe's color transform
                if (seg.len >= 12 and std.mem.eql(u8, seg[0..5], "Adobe")) adobe_rgb = seg[11] == 0;
            },
            0xc0, 0xc1, 0xc2 => { // SOF: sequential or progressive Huffman
                if (seg.len < 6 or seg[0] != 8) return error.Unsupported;
                progressive = marker == 0xc2;
                height = std.mem.readInt(u16, seg[1..3], .big);
                width = std.mem.readInt(u16, seg[3..5], .big);
                ncomps = seg[5];
                if (width == 0 or height == 0) return error.Unsupported;
                if (ncomps != 1 and ncomps != 3) return error.Unsupported;
                if (seg.len < 6 + 3 * ncomps) return error.Corrupt;
                for (0..ncomps) |c| {
                    const s = seg[6 + 3 * c ..];
                    comps[c] = .{ .id = s[0], .h = s[1] >> 4, .v = s[1] & 15, .tq = s[2] & 3 };
                    if (comps[c].h == 0 or comps[c].v == 0 or comps[c].h > 4 or comps[c].v > 4) return error.Corrupt;
                    hmax = @max(hmax, comps[c].h);
                    vmax = @max(vmax, comps[c].v);
                }
                mcux = (width + 8 * @as(usize, hmax) - 1) / (8 * @as(usize, hmax));
                mcuy = (height + 8 * @as(usize, vmax) - 1) / (8 * @as(usize, vmax));
                for (comps[0..ncomps]) |*c| {
                    c.stride = mcux * c.h;
                    c.rows = mcuy * c.v;
                    c.dc = try arena.alloc(i32, c.stride * c.rows);
                    @memset(c.dc, 0);
                }
            },
            0xc3, 0xc5...0xc7, 0xc9...0xcb, 0xcd...0xcf => return error.Unsupported,
            0xda => { // SOS
                if (ncomps == 0 or seg.len < 1) return error.Corrupt;
                const ns = seg[0];
                if (ns == 0 or ns > 4 or seg.len < 1 + 2 * @as(usize, ns) + 3) return error.Corrupt;
                var scan: [4]*Component = undefined;
                for (0..ns) |i| {
                    const id = seg[1 + 2 * i];
                    const c = for (comps[0..ncomps]) |*c| {
                        if (c.id == id) break c;
                    } else return error.Corrupt;
                    c.td = seg[2 + 2 * i] >> 4;
                    if (c.td > 3 or seg[2 + 2 * i] & 15 > 3) return error.Corrupt;
                    scan[i] = c;
                    c.pred = 0;
                }
                const ss = seg[1 + 2 * ns];
                const ah = seg[3 + 2 * ns] >> 4;
                const al: u5 = @intCast(seg[3 + 2 * ns] & 15);
                const ta = blk: {
                    var t: [4]u8 = undefined;
                    for (0..ns) |i| t[i] = seg[2 + 2 * i] & 15;
                    break :blk t;
                };
                const wanted = if (progressive) ss == 0 and ah == 0 else true;
                if (wanted) {
                    var bits: Bits = .{ .data = bytes, .pos = pos };
                    try decodeScan(&bits, scan[0..ns], ta[0..ns], &dc_tables, &ac_tables, progressive, al, restart_interval, mcux, mcuy, width, height, hmax, vmax);
                    for (scan[0..ns]) |c| c.seen = true;
                    pos = bits.pos;
                }
                pos = nextScanEnd(bytes, pos);
                // Progressive: done once every component's DC is in.
                if (progressive) {
                    for (comps[0..ncomps]) |c| {
                        if (!c.seen) break;
                    } else break;
                }
            },
            else => {},
        }
    }
    if (ncomps == 0) return error.Corrupt;
    for (comps[0..ncomps]) |c| if (!c.seen) return error.Corrupt;

    // An eighth of the size, each pixel from its blocks' averages.
    const out_w = (width + 7) / 8;
    const out_h = (height + 7) / 8;
    const rgb = try arena.alloc(u8, out_w * out_h * 3);
    for (0..out_h) |y| for (0..out_w) |x| {
        var v: [3]f32 = undefined;
        for (comps[0..ncomps], 0..) |c, i| {
            const bx = @min(x * c.h / hmax, c.stride - 1);
            const by = @min(y * c.v / vmax, c.rows - 1);
            const q: f32 = @floatFromInt(quant[c.tq][0]);
            v[i] = @as(f32, @floatFromInt(c.dc[by * c.stride + bx])) * q / 8 + 128;
        }
        const px = rgb[(y * out_w + x) * 3 ..][0..3];
        if (ncomps == 1) {
            px.* = @splat(clamp(v[0]));
        } else if (adobe_rgb) {
            px.* = .{ clamp(v[0]), clamp(v[1]), clamp(v[2]) };
        } else {
            const cb = v[1] - 128;
            const cr = v[2] - 128;
            px.* = .{ clamp(v[0] + 1.402 * cr), clamp(v[0] - 0.344136 * cb - 0.714136 * cr), clamp(v[0] + 1.772 * cb) };
        }
    };
    return .{ .width = out_w, .height = out_h, .rgb = rgb };
}

fn clamp(v: f32) u8 {
    return @intFromFloat(std.math.clamp(@round(v), 0, 255));
}

fn decodeScan(
    bits: *Bits,
    scan: []const *Component,
    ta: []const u8,
    dc_tables: *const [4]?Huffman,
    ac_tables: *const [4]?Huffman,
    progressive: bool,
    al: u5,
    restart_interval: usize,
    mcux: usize,
    mcuy: usize,
    width: usize,
    height: usize,
    hmax: u8,
    vmax: u8,
) Error!void {
    for (scan) |c| if (dc_tables[c.td] == null) return error.Corrupt;
    if (!progressive) for (ta) |t| if (ac_tables[t] == null) return error.Corrupt;
    var count: usize = 0;
    if (scan.len == 1) {
        // Not interleaved: a block is an MCU, over the component's own size.
        const c = scan[0];
        const bw = ((width * c.h + hmax - 1) / hmax + 7) / 8;
        const bh = ((height * c.v + vmax - 1) / vmax + 7) / 8;
        for (0..bh) |by| for (0..bw) |bx| {
            try restartIfDue(bits, scan, restart_interval, &count);
            c.dc[by * c.stride + bx] = try block(bits, c, if (progressive) null else &ac_tables[ta[0]].?, dc_tables, al);
        };
        return;
    }
    for (0..mcuy) |my| for (0..mcux) |mx| {
        try restartIfDue(bits, scan, restart_interval, &count);
        for (scan, ta) |c, t| for (0..c.v) |v| for (0..c.h) |h| {
            c.dc[(my * c.v + v) * c.stride + mx * c.h + h] = try block(bits, c, if (progressive) null else &ac_tables[t].?, dc_tables, al);
        };
    };
}

fn restartIfDue(bits: *Bits, scan: []const *Component, interval: usize, count: *usize) Error!void {
    if (interval > 0 and count.* > 0 and count.* % interval == 0) {
        bits.restart();
        for (scan) |c| c.pred = 0;
    }
    count.* += 1;
}

/// A block's DC coefficient, skipping its AC coefficients if `ac` is given.
fn block(bits: *Bits, c: *Component, ac: ?*const Huffman, dc_tables: *const [4]?Huffman, al: u5) Error!i32 {
    const s = try bits.decode(&dc_tables[c.td].?);
    c.pred +%= try bits.receive(s);
    if (ac) |table| {
        var k: usize = 1;
        while (k < 64) {
            const rs = try bits.decode(table);
            const r = rs >> 4;
            const size = rs & 15;
            if (size == 0) {
                if (r != 15) break;
                k += 16;
                continue;
            }
            _ = bits.get(@intCast(size));
            k += r + 1;
        }
    }
    return c.pred *% (@as(i32, 1) << al);
}

test "baseline and progressive JPEGs decode to the same eighth-size image" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // ffmpeg's test pattern, 80×120, by cjpeg (the second with -progressive
    // -restart 1).
    const base = try decodeDc(arena, @embedFile("testdata/pattern.jpg"));
    const progressive = try decodeDc(arena, @embedFile("testdata/pattern-progressive.jpg"));
    try std.testing.expectEqual(@as(usize, 10), base.width);
    try std.testing.expectEqual(@as(usize, 15), base.height);
    var differ: usize = 0;
    for (base.rgb, progressive.rgb) |a, b| differ += @abs(@as(i32, a) - b);
    try std.testing.expect(differ / base.rgb.len <= 2);
    try std.testing.expectError(error.NotJpeg, decodeDc(arena, "\x89PNG\r\n"));
}
