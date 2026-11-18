//! ThumbHash: an image's blurred likeness in about 25 bytes, for a
//! placeholder until the image loads. Ported from Evan Wallace's reference
//! implementation (https://github.com/evanw/thumbhash), whose hashes and
//! images it reproduces, under its license:
//!
//! Copyright (c) 2023 Evan Wallace
//!
//! Permission is hereby granted, free of charge, to any person obtaining a
//! copy of this software and associated documentation files (the
//! "Software"), to deal in the Software without restriction, including
//! without limitation the rights to use, copy, modify, merge, publish,
//! distribute, sublicense, and/or sell copies of the Software, and to
//! permit persons to whom the Software is furnished to do so, subject to
//! the following conditions:
//!
//! The above copyright notice and this permission notice shall be included
//! in all copies or substantial portions of the Software.
//!
//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
//! OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//! MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
//! IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
//! CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
//! TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
//! SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

const std = @import("std");
const pi = std.math.pi;

/// The longest hash: a header and the most coefficients, with alpha.
pub const max_len = 32;

/// Encodes an image, at most 100×100, of RGBA pixels (not premultiplied),
/// returning how much of `out` the hash takes.
pub fn encode(gpa: std.mem.Allocator, w: usize, h: usize, rgba: []const u8, out: *[max_len]u8) !usize {
    std.debug.assert(w <= 100 and h <= 100 and w > 0 and h > 0);
    var avg_r: f64 = 0;
    var avg_g: f64 = 0;
    var avg_b: f64 = 0;
    var avg_a: f64 = 0;
    for (0..w * h) |i| {
        const alpha = f(rgba[i * 4 + 3]) / 255;
        avg_r += alpha / 255 * f(rgba[i * 4]);
        avg_g += alpha / 255 * f(rgba[i * 4 + 1]);
        avg_b += alpha / 255 * f(rgba[i * 4 + 2]);
        avg_a += alpha;
    }
    if (avg_a > 0) {
        avg_r /= avg_a;
        avg_g /= avg_a;
        avg_b /= avg_a;
    }
    const has_alpha = avg_a < f(w * h);
    const l_limit: f64 = if (has_alpha) 5 else 7;
    const longer = f(@max(w, h));
    const lx: usize = @max(1, round(l_limit * f(w) / longer));
    const ly: usize = @max(1, round(l_limit * f(h) / longer));

    const lpqa = try gpa.alloc(f64, 4 * w * h);
    defer gpa.free(lpqa);
    const l = lpqa[0 .. w * h];
    const p = lpqa[w * h .. 2 * w * h];
    const q = lpqa[2 * w * h .. 3 * w * h];
    const a = lpqa[3 * w * h ..];
    for (0..w * h) |i| {
        const alpha = f(rgba[i * 4 + 3]) / 255;
        const r = avg_r * (1 - alpha) + alpha / 255 * f(rgba[i * 4]);
        const g = avg_g * (1 - alpha) + alpha / 255 * f(rgba[i * 4 + 1]);
        const b = avg_b * (1 - alpha) + alpha / 255 * f(rgba[i * 4 + 2]);
        l[i] = (r + g + b) / 3;
        p[i] = (r + g) / 2 - b;
        q[i] = r - g;
        a[i] = alpha;
    }

    const lc = channel(l, w, h, @max(3, lx), @max(3, ly));
    const pc = channel(p, w, h, 3, 3);
    const qc = channel(q, w, h, 3, 3);
    const ac: ?Channel = if (has_alpha) channel(a, w, h, 5, 5) else null;

    const landscape = w > h;
    const header24: u32 = round(63 * lc.dc) | (round(31.5 + 31.5 * pc.dc) << 6) | (round(31.5 + 31.5 * qc.dc) << 12) | (round(31 * lc.scale) << 18) | (@as(u32, @intFromBool(has_alpha)) << 23);
    const header16: u32 = @as(u32, @intCast(if (landscape) ly else lx)) | (round(63 * pc.scale) << 3) | (round(63 * qc.scale) << 9) | (@as(u32, @intFromBool(landscape)) << 15);
    out.* = @splat(0);
    out[0] = @truncate(header24);
    out[1] = @truncate(header24 >> 8);
    out[2] = @truncate(header24 >> 16);
    out[3] = @truncate(header16);
    out[4] = @truncate(header16 >> 8);
    const ac_start: usize = if (has_alpha) 6 else 5;
    if (ac) |c| out[5] = @intCast(round(15 * c.dc) | (round(15 * c.scale) << 4));
    var index: usize = 0;
    const channels = [_]?Channel{ lc, pc, qc, ac };
    for (channels) |maybe| if (maybe) |c| for (c.ac[0..c.len]) |v| {
        out[ac_start + (index >> 1)] |= @intCast(round(15 * v) << @intCast((index & 1) << 2));
        index += 1;
    };
    return ac_start + (index + 1) / 2;
}

const Channel = struct {
    dc: f64,
    ac: [64]f64,
    len: usize,
    scale: f64,
};

fn channel(values: []const f64, w: usize, h: usize, nx: usize, ny: usize) Channel {
    var c: Channel = .{ .dc = 0, .ac = undefined, .len = 0, .scale = 0 };
    var fx: [100]f64 = undefined;
    for (0..ny) |cy| {
        var cx: usize = 0;
        while (cx * ny < nx * (ny - cy)) : (cx += 1) {
            var sum: f64 = 0;
            for (0..w) |x| fx[x] = @cos(pi / f(w) * f(cx) * (f(x) + 0.5));
            for (0..h) |y| {
                const fy = @cos(pi / f(h) * f(cy) * (f(y) + 0.5));
                for (0..w) |x| sum += values[x + y * w] * fx[x] * fy;
            }
            sum /= f(w * h);
            if (cx > 0 or cy > 0) {
                c.ac[c.len] = sum;
                c.len += 1;
                c.scale = @max(c.scale, @abs(sum));
            } else c.dc = sum;
        }
    }
    if (c.scale > 0) for (c.ac[0..c.len]) |*v| {
        v.* = 0.5 + 0.5 / c.scale * v.*;
    };
    return c;
}

/// The largest image `decode` renders: 32 pixels on the longer side.
pub const max_pixels = 32 * 32;

pub const Rendered = struct { width: usize, height: usize };

/// Renders a hash as RGBA pixels (not premultiplied) into `rgba`, 32
/// pixels on its longer side.
pub fn decode(hash: []const u8, rgba: *[max_pixels * 4]u8) error{Invalid}!Rendered {
    if (hash.len < 5) return error.Invalid;
    const header24: u32 = @as(u32, hash[0]) | (@as(u32, hash[1]) << 8) | (@as(u32, hash[2]) << 16);
    const header16: u32 = @as(u32, hash[3]) | (@as(u32, hash[4]) << 8);
    const l_dc = f(header24 & 63) / 63;
    const p_dc = f((header24 >> 6) & 63) / 31.5 - 1;
    const q_dc = f((header24 >> 12) & 63) / 31.5 - 1;
    const l_scale = f((header24 >> 18) & 31) / 31;
    const has_alpha = (header24 >> 23) != 0;
    const p_scale = f((header16 >> 3) & 63) / 63;
    const q_scale = f((header16 >> 9) & 63) / 63;
    const landscape = (header16 >> 15) != 0;
    const lx: usize = @max(3, if (landscape) (if (has_alpha) @as(usize, 5) else 7) else header16 & 7);
    const ly: usize = @max(3, if (landscape) header16 & 7 else (if (has_alpha) @as(usize, 5) else 7));
    if (has_alpha and hash.len < 6) return error.Invalid;
    const a_dc: f64 = if (has_alpha) f(hash[5] & 15) / 15 else 1;
    const a_scale: f64 = if (has_alpha) f(hash[5] >> 4) / 15 else 0;

    var reader: Reader = .{ .hash = hash, .start = if (has_alpha) 6 else 5 };
    var l_ac: [64]f64 = undefined;
    var p_ac: [64]f64 = undefined;
    var q_ac: [64]f64 = undefined;
    var a_ac: [64]f64 = undefined;
    try reader.channel(lx, ly, l_scale, &l_ac);
    // Saturation boosted by 1.25 to make up for quantizing.
    try reader.channel(3, 3, p_scale * 1.25, &p_ac);
    try reader.channel(3, 3, q_scale * 1.25, &q_ac);
    if (has_alpha) try reader.channel(5, 5, a_scale, &a_ac);

    const ratio = aspectRatio(hash);
    const w: usize = @intCast(round(if (ratio > 1) 32 else 32 * ratio));
    const h: usize = @intCast(round(if (ratio > 1) 32 / ratio else 32));
    var fx: [8]f64 = undefined;
    var fy: [8]f64 = undefined;
    var i: usize = 0;
    for (0..h) |y| for (0..w) |x| {
        var l = l_dc;
        var p = p_dc;
        var q = q_dc;
        var a = a_dc;
        for (0..@max(lx, @as(usize, if (has_alpha) 5 else 3))) |cx| fx[cx] = @cos(pi / f(w) * (f(x) + 0.5) * f(cx));
        for (0..@max(ly, @as(usize, if (has_alpha) 5 else 3))) |cy| fy[cy] = @cos(pi / f(h) * (f(y) + 0.5) * f(cy));
        var j: usize = 0;
        for (0..ly) |cy| {
            const fy2 = fy[cy] * 2;
            var cx: usize = if (cy > 0) 0 else 1;
            while (cx * ly < lx * (ly - cy)) : (cx += 1) {
                l += l_ac[j] * fx[cx] * fy2;
                j += 1;
            }
        }
        j = 0;
        for (0..3) |cy| {
            const fy2 = fy[cy] * 2;
            var cx: usize = if (cy > 0) 0 else 1;
            while (cx < 3 - cy) : (cx += 1) {
                const k = fx[cx] * fy2;
                p += p_ac[j] * k;
                q += q_ac[j] * k;
                j += 1;
            }
        }
        if (has_alpha) {
            j = 0;
            for (0..5) |cy| {
                const fy2 = fy[cy] * 2;
                var cx: usize = if (cy > 0) 0 else 1;
                while (cx < 5 - cy) : (cx += 1) {
                    a += a_ac[j] * fx[cx] * fy2;
                    j += 1;
                }
            }
        }
        const b = l - 2.0 / 3.0 * p;
        const r = (3 * l - b + q) / 2;
        const g = r - q;
        rgba[i..][0..4].* = .{ byte(r), byte(g), byte(b), byte(a) };
        i += 4;
    };
    return .{ .width = w, .height = h };
}

/// The original image's approximate width over its height.
pub fn aspectRatio(hash: []const u8) f64 {
    const header = hash[3];
    const has_alpha = hash[2] & 0x80 != 0;
    const landscape = hash[4] & 0x80 != 0;
    const lx: f64 = if (landscape) (if (has_alpha) 5 else 7) else f(header & 7);
    const ly: f64 = if (landscape) f(header & 7) else (if (has_alpha) 5 else 7);
    return if (ly == 0) 1 else lx / ly;
}

const Reader = struct {
    hash: []const u8,
    start: usize,
    index: usize = 0,

    fn channel(r: *Reader, nx: usize, ny: usize, scale: f64, out: *[64]f64) error{Invalid}!void {
        var n: usize = 0;
        for (0..ny) |cy| {
            var cx: usize = if (cy > 0) 0 else 1;
            while (cx * ny < nx * (ny - cy)) : (cx += 1) {
                const at = r.start + (r.index >> 1);
                if (at >= r.hash.len or n >= out.len) return error.Invalid;
                const nibble = (r.hash[at] >> @intCast((r.index & 1) << 2)) & 15;
                out[n] = (f(nibble) / 7.5 - 1) * scale;
                n += 1;
                r.index += 1;
            }
        }
    }
};

fn f(v: anytype) f64 {
    return @floatFromInt(v);
}

/// JavaScript's Math.round, for values that are never negative here.
fn round(v: f64) u32 {
    return @intFromFloat(@max(0, @floor(v + 0.5)));
}

/// As the reference stores into a Uint8Array: clamped, then truncated.
fn byte(v: f64) u8 {
    return @intFromFloat(@max(0, 255 * @min(1, v)));
}

test "a hash renders at its image's aspect ratio" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // 66×100 of a poster; the reference implementation's hash.
    var pixels: [32 * 32 * 4]u8 = undefined;
    const hash = [_]u8{ 0x60, 0x19, 0x0e, 0x1d, 0x04, 0xf8, 0x77, 0x88, 0x93, 0x99, 0x77, 0x88, 0x98, 0x6a, 0xd6, 0x97, 0x98, 0x70, 0x68, 0x06, 0x57 };
    const r = try decode(&hash, &pixels);
    try std.testing.expectEqual(@as(usize, 23), r.width);
    try std.testing.expectEqual(@as(usize, 32), r.height);
    try std.testing.expectEqual(@as(u8, 255), pixels[3]);
    try std.testing.expectError(error.Invalid, decode(hash[0..6], &pixels));
}
