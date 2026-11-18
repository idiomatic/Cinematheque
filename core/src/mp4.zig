//! Reads an MP4's cover and rudimentary metadata over HTTP range requests,
//! without downloading its media: it walks atom headers, skipping atoms by
//! their sizes, to `moov`, reads `mvhd` for the duration, and reads `udta`
//! (or a `meta` directly in `moov`) whole for its iTunes-style items. A
//! file written with its index first (as HandBrake writes them) takes about
//! eight requests.

const std = @import("std");
const http = std.http;

pub const Image = enum { jpeg, png };

/// Where a cover's bytes are in the file, so any peer can fetch them with
/// one range request.
pub const Cover = struct {
    offset: u64,
    length: u64,
    image: Image,
    /// The image itself, read with `udta`.
    bytes: []const u8 = &.{},
};

pub const Info = struct {
    cover: ?Cover = null,
    /// `©nam`: a movie's or an episode's title.
    title: ?[]const u8 = null,
    /// `©gen`.
    genre: ?[]const u8 = null,
    /// `©day`: a release date or year, as written.
    released: ?[]const u8 = null,
    /// `ldes`, or else `desc`.
    description: ?[]const u8 = null,
    /// `tvsh`, `tvnn`, `tvsn`, and `tves`.
    show: ?[]const u8 = null,
    network: ?[]const u8 = null,
    season: ?u32 = null,
    episode: ?u32 = null,
    /// From `mvhd`.
    duration_ms: ?u64 = null,
};

/// The most of `udta` read at once: covers are a few hundred kilobytes.
const max_udta = 16 << 20;

/// Reads `url`'s cover and metadata. Fails with `error.NoRanges` if the
/// server ignores range requests, rather than downloading the file.
pub fn read(arena: std.mem.Allocator, client: *http.Client, target: []const u8) !Info {
    var f: File = .{ .arena = arena, .client = client, .uri = try std.Uri.parse(target) };
    var info: Info = .{};
    // The top level: ftyp, then moov first or after mdat.
    _ = try f.get(0, 64);
    const size = f.size orelse return error.NoRanges;
    var at: u64 = 0;
    const moov = while (at + 8 <= size) {
        const a = try f.atomAt(at);
        if (std.mem.eql(u8, &a.kind, "moov")) break a;
        at += a.size;
    } else return error.NoMovie;
    // moov's children: mvhd, traks (skipped), udta, and perhaps meta.
    at = moov.offset + moov.header;
    while (at + 8 <= moov.offset + moov.size) {
        const a = try f.atomAt(at);
        if (std.mem.eql(u8, &a.kind, "mvhd")) {
            info.duration_ms = duration(try f.get(a.offset + a.header, 32));
        } else if (std.mem.eql(u8, &a.kind, "udta") or std.mem.eql(u8, &a.kind, "meta")) {
            if (a.size <= max_udta) {
                const bytes = try f.get(a.offset, a.size);
                parseContainer(&info, bytes, a.offset, std.mem.eql(u8, &a.kind, "meta"));
            }
        }
        at += a.size;
    }
    return info;
}

const Atom = struct {
    offset: u64,
    size: u64,
    header: u64,
    kind: [4]u8,
};

/// Parses an atom header from `bytes` (at `offset` within the file).
fn header(bytes: []const u8, offset: u64, end: u64) !Atom {
    if (bytes.len < 8) return error.Truncated;
    var size: u64 = std.mem.readInt(u32, bytes[0..4], .big);
    var h: u64 = 8;
    if (size == 1) {
        if (bytes.len < 16) return error.Truncated;
        size = std.mem.readInt(u64, bytes[8..16], .big);
        h = 16;
    } else if (size == 0) size = end - offset;
    if (size < h) return error.Malformed;
    return .{ .offset = offset, .size = size, .header = h, .kind = bytes[4..8].* };
}

const File = struct {
    arena: std.mem.Allocator,
    client: *http.Client,
    uri: std.Uri,
    size: ?u64 = null,
    /// The first bytes, which hold the first atoms' headers.
    head: []const u8 = &.{},

    /// The atom at `offset`, from bytes already read if they hold its
    /// header, else from a request for it.
    fn atomAt(f: *File, offset: u64) !Atom {
        if (offset + 16 <= f.head.len) return header(f.head[offset..], offset, f.size.?);
        return header(try f.get(offset, 16), offset, f.size.?);
    }

    fn get(f: *File, offset: u64, length: u64) ![]const u8 {
        var range_buf: [64]u8 = undefined;
        const range = try std.fmt.bufPrint(&range_buf, "bytes={d}-{d}", .{ offset, offset + length - 1 });
        var request = try f.client.request(.GET, f.uri, .{
            .extra_headers = &.{.{ .name = "range", .value = range }},
        });
        defer request.deinit();
        try request.sendBodiless();
        var response = try request.receiveHead(&.{});
        if (response.head.status != .partial_content) return error.NoRanges;
        if (f.size == null) {
            var headers = response.head.iterateHeaders();
            while (headers.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "content-range")) {
                const slash = std.mem.lastIndexOfScalar(u8, h.value, '/') orelse continue;
                f.size = std.fmt.parseInt(u64, h.value[slash + 1 ..], 10) catch null;
            };
        }
        var transfer: [8192]u8 = undefined;
        const body = try response.reader(&transfer).allocRemaining(f.arena, .limited(max_udta + 1024));
        if (offset == 0 and f.head.len == 0) f.head = body;
        return body;
    }
};

/// mvhd's duration in milliseconds.
fn duration(b: []const u8) ?u64 {
    if (b.len < 32) return null;
    const timescale: u64, const units: u64 = if (b[0] == 1)
        .{ std.mem.readInt(u32, b[20..24], .big), std.mem.readInt(u64, b[24..32], .big) }
    else
        .{ std.mem.readInt(u32, b[12..16], .big), std.mem.readInt(u32, b[16..20], .big) };
    if (timescale == 0) return null;
    return units * 1000 / timescale;
}

/// Finds `meta` > `ilst` within `udta` (or `meta` itself) and reads its
/// items. `bytes` is the whole atom, at `base` within the file.
fn parseContainer(info: *Info, bytes: []const u8, base: u64, is_meta: bool) void {
    if (is_meta) return parseMeta(info, bytes, base);
    const udta = header(bytes, 0, bytes.len) catch return;
    var at: usize = @intCast(udta.header);
    while (at + 8 <= bytes.len) {
        const a = header(bytes[at..], at, bytes.len) catch return;
        if (at + a.size > bytes.len) return;
        if (std.mem.eql(u8, &a.kind, "meta")) parseMeta(info, bytes[at..][0..@intCast(a.size)], base + at);
        at += @intCast(a.size);
    }
}

fn parseMeta(info: *Info, bytes: []const u8, base: u64) void {
    const meta = header(bytes, 0, bytes.len) catch return;
    // meta is a full box: version and flags before its children.
    var at: usize = @intCast(meta.header + 4);
    while (at + 8 <= bytes.len) {
        const a = header(bytes[at..], at, bytes.len) catch return;
        if (at + a.size > bytes.len) return;
        if (std.mem.eql(u8, &a.kind, "ilst")) parseItems(info, bytes[at..][0..@intCast(a.size)], base + at);
        at += @intCast(a.size);
    }
}

fn parseItems(info: *Info, bytes: []const u8, base: u64) void {
    const ilst = header(bytes, 0, bytes.len) catch return;
    var at: usize = @intCast(ilst.header);
    while (at + 8 <= bytes.len) {
        const item = header(bytes[at..], at, bytes.len) catch return;
        if (at + item.size > bytes.len) return;
        const body = bytes[at..][0..@intCast(item.size)];
        // An item holds a `data` atom: type (4), locale (4), then the value.
        const data = header(body[@intCast(item.header)..], 0, body.len) catch {
            at += @intCast(item.size);
            continue;
        };
        const start: usize = @intCast(item.header + data.header + 8);
        const end: usize = @intCast(item.header + data.size);
        if (std.mem.eql(u8, &data.kind, "data") and start <= end and end <= body.len) {
            const value = body[start..end];
            const kind = std.mem.readInt(u32, body[@intCast(item.header + data.header)..][0..4], .big) & 0xffffff;
            setItem(info, item.kind, kind, value, base + at + start);
        }
        at += @intCast(item.size);
    }
}

fn setItem(info: *Info, name: [4]u8, kind: u32, value: []const u8, offset: u64) void {
    const eql = std.mem.eql;
    const text: ?[]const u8 = if (kind == 1 and std.unicode.utf8ValidateSlice(value)) value else null;
    if (eql(u8, &name, "covr") and info.cover == null and (kind == 13 or kind == 14)) {
        info.cover = .{ .offset = offset, .length = value.len, .image = if (kind == 14) .png else .jpeg, .bytes = value };
    } else if (eql(u8, &name, "\xa9nam")) {
        info.title = text;
    } else if (eql(u8, &name, "\xa9gen")) {
        info.genre = text;
    } else if (eql(u8, &name, "\xa9day")) {
        info.released = text;
    } else if (eql(u8, &name, "ldes")) {
        info.description = text orelse info.description;
    } else if (eql(u8, &name, "desc")) {
        if (info.description == null) info.description = text;
    } else if (eql(u8, &name, "tvsh")) {
        info.show = text;
    } else if (eql(u8, &name, "tvnn")) {
        info.network = text;
    } else if (eql(u8, &name, "tvsn") and value.len >= 4) {
        info.season = std.mem.readInt(u32, value[value.len - 4 ..][0..4], .big);
    } else if (eql(u8, &name, "tves") and value.len >= 4) {
        info.episode = std.mem.readInt(u32, value[value.len - 4 ..][0..4], .big);
    }
}

test "items are read from udta, with the cover's place in the file" {
    // udta > meta (full box) > hdlr, ilst > ©nam, tvsn, covr.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    const W = struct {
        fn atom(list: *std.ArrayList(u8), gpa: std.mem.Allocator, kind: []const u8, body: []const u8) !void {
            var size: [4]u8 = undefined;
            std.mem.writeInt(u32, &size, @intCast(8 + body.len), .big);
            try list.appendSlice(gpa, &size);
            try list.appendSlice(gpa, kind);
            try list.appendSlice(gpa, body);
        }
        fn data(gpa: std.mem.Allocator, kind: u8, value: []const u8) ![]u8 {
            var list: std.ArrayList(u8) = .empty;
            try atom(&list, gpa, "data", try std.mem.concat(gpa, u8, &.{ &.{ 0, 0, 0, kind, 0, 0, 0, 0 }, value }));
            return list.toOwnedSlice(gpa);
        }
    };
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var items: std.ArrayList(u8) = .empty;
    try W.atom(&items, ar, "\xa9nam", try W.data(ar, 1, "Serenity"));
    try W.atom(&items, ar, "tvsn", try W.data(ar, 21, &.{ 0, 0, 0, 1 }));
    try W.atom(&items, ar, "covr", try W.data(ar, 13, "\xff\xd8\xff\xe0JPEG"));
    var ilst: std.ArrayList(u8) = .empty;
    try W.atom(&ilst, ar, "ilst", items.items);
    var meta_body: std.ArrayList(u8) = .empty;
    try meta_body.appendSlice(ar, &.{ 0, 0, 0, 0 });
    try W.atom(&meta_body, ar, "hdlr", &@as([25]u8, @splat(0)));
    try meta_body.appendSlice(ar, ilst.items);
    var meta: std.ArrayList(u8) = .empty;
    try W.atom(&meta, ar, "meta", meta_body.items);
    try W.atom(&buf, a, "udta", meta.items);

    var info: Info = .{};
    parseContainer(&info, buf.items, 1000, false);
    try std.testing.expectEqualStrings("Serenity", info.title.?);
    try std.testing.expectEqual(@as(?u32, 1), info.season);
    const cover = info.cover.?;
    try std.testing.expectEqual(@as(u64, 8), cover.length);
    try std.testing.expectEqualStrings("\xff\xd8\xff\xe0JPEG", buf.items[@intCast(cover.offset - 1000)..][0..8]);
}

test "mvhd's duration, in either version" {
    var v0: [32]u8 = @splat(0);
    std.mem.writeInt(u32, v0[12..16], 600, .big);
    std.mem.writeInt(u32, v0[16..20], 600 * 90, .big);
    try std.testing.expectEqual(@as(?u64, 90_000), duration(&v0));
    var v1: [32]u8 = @splat(0);
    v1[0] = 1;
    std.mem.writeInt(u32, v1[20..24], 1000, .big);
    std.mem.writeInt(u64, v1[24..32], 5_400_000, .big);
    try std.testing.expectEqual(@as(?u64, 5_400_000), duration(&v1));
}
