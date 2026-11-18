//! Downloads: a title's, a season's, or an item's files, fetched into a
//! directory of this device's under their paths in the repository that held
//! them, so the directory, crawled or served, names them as the library did.
//!
//! Each file comes from its copies in the order copy racing gives (see
//! race.zig), the next tried when one fails. A file is fetched into
//! `<path>.part`, resumed by a range request where an earlier attempt left
//! off, and renamed once whole; one already there at its size is kept.

const std = @import("std");
const Io = std.Io;
const library = @import("library.zig");
const race = @import("race.zig");
const art = @import("art.zig");
const Replica = @import("replica.zig").Replica;

/// One file to fetch.
pub const File = struct {
    /// The item's key (e.g., `t/s/firefly/-/e/s01e02`).
    item: []const u8,
    rendition: []const u8,
    /// Where it goes, relative to the directory: its path in the repository.
    path: []const u8,
    size: u64,
    /// Its copies' URLs, those not under an absent directory first.
    urls: []const []const u8,
};

/// The files of `key`: a title (`t/m/alien/1979`), a season of a series
/// (`t/s/firefly/-/e/s01`), or an item (`t/s/firefly/-/e/s01e02`). Each
/// item's file is of `rendition` if given (items without it are left out),
/// else of the rendition most of them have, so a season comes alike.
pub fn plan(replica: *Replica, arena: std.mem.Allocator, key: []const u8, rendition: ?[]const u8) ![]File {
    const title_end = titleEnd(key) orelse return error.NotFound;
    const d = try library.detail(replica, arena, key[0..title_end]) orelse return error.NotFound;
    const below = if (title_end < key.len) key[title_end + 1 ..] else "";
    var bases: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (try library.repositories(replica, arena)) |rp| try bases.put(arena, try arena.dupe(u8, &rp.id), rp.url);

    var items: std.ArrayList(library.Item) = .empty;
    for (d.items.items) |item| if (within(item.key, below)) try items.append(arena, item);
    if (items.items.len == 0) return error.NotFound;
    const label = rendition orelse commonest(items.items);

    var files: std.ArrayList(File) = .empty;
    for (items.items) |item| {
        const r = for (item.renditions.items) |r| {
            if (std.mem.eql(u8, r.label, label)) break r;
        } else if (rendition != null) continue else item.renditions.items[0];
        var urls: std.ArrayList([]const u8) = .empty;
        var path: ?[]const u8 = null;
        var size: u64 = 0;
        for ([_]bool{ false, true }) |absent| for (r.holdings.items) |h| {
            if (h.absent != absent) continue;
            const base = bases.get(h.repository) orelse continue;
            if (!safe(h.path)) continue;
            try urls.append(arena, try art.fileUrl(arena, base, h.path));
            if (path == null) {
                path = h.path;
                size = h.size;
            }
        };
        try files.append(arena, .{
            .item = try std.fmt.allocPrint(arena, "{s}/{s}", .{ d.key, item.key }),
            .rendition = r.label,
            .path = path orelse continue,
            .size = size,
            .urls = urls.items,
        });
    }
    return files.items;
}

/// Where a title's key ends within `key` (its first four segments).
fn titleEnd(key: []const u8) ?usize {
    var slashes: usize = 0;
    for (key, 0..) |ch, i| if (ch == '/') {
        slashes += 1;
        if (slashes == 4) return i;
    };
    return if (slashes == 3) key.len else null;
}

/// Whether an item's key (below its title's) is `below`, or within it: a
/// season (`e/s01`) holds its episodes (`e/s01e02`) and their versions.
fn within(item: []const u8, below: []const u8) bool {
    if (below.len == 0) return true;
    if (!std.mem.startsWith(u8, item, below)) return false;
    if (item.len == below.len) return true;
    const next = item[below.len];
    return next == '/' or (std.mem.startsWith(u8, below, "e/s") and std.mem.indexOfAny(u8, below[3..], "e-") == null and (next == 'e' or next == '-'));
}

/// The rendition most of `items` have, the first such if tied.
fn commonest(items: []const library.Item) []const u8 {
    var best: []const u8 = items[0].renditions.items[0].label;
    var best_count: usize = 0;
    for (items) |item| for (item.renditions.items) |r| {
        var count: usize = 0;
        for (items) |other| for (other.renditions.items) |o| {
            if (std.mem.eql(u8, o.label, r.label)) count += 1;
        };
        if (count > best_count) {
            best = r.label;
            best_count = count;
        }
    };
    return best;
}

/// Whether a repository's path stays within the directory it's fetched to,
/// since a path comes from whichever member's device crawled it.
fn safe(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |s| {
        if (s.len == 0 or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return false;
    }
    return true;
}

/// How far a file has come, told as it does.
pub const Progress = struct {
    context: *anyopaque,
    report: *const fn (context: *anyopaque, done: u64, total: u64) void,
};

pub const Fetched = enum { fetched, kept };

/// Fetches `file` into `dir`, from the first of its copies (raced) that
/// gives all of it.
pub fn fetch(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, client: *std.http.Client, memory: *race.Memory, dir: Io.Dir, file: File, now_ms: u64, progress: ?Progress) !Fetched {
    if (dir.statFile(io, file.path, .{})) |st| {
        if (st.size == file.size) return .kept;
    } else |_| {}
    if (std.fs.path.dirname(file.path)) |parent| try dir.createDirPath(io, parent);
    const part = try std.fmt.allocPrint(arena, "{s}.part", .{file.path});
    var last: anyerror = error.NoCopies;
    for (try race.order(io, gpa, arena, memory, file.urls, now_ms)) |u| {
        fetchFrom(io, client, dir, part, u, file.size, progress) catch |err| {
            if (err == error.Canceled) return err;
            last = err;
            try memory.lost(io, gpa, u, now_ms);
            continue;
        };
        try dir.rename(part, dir, file.path, io);
        return .fetched;
    }
    return last;
}

/// Fetches `url` into `part`, resuming where it leaves off.
fn fetchFrom(io: Io, client: *std.http.Client, dir: Io.Dir, part: []const u8, url: []const u8, size: u64, progress: ?Progress) !void {
    const out = try dir.createFile(io, part, .{ .truncate = false });
    defer out.close(io);
    var have = try out.length(io);
    if (have > size) {
        try out.setLength(io, 0);
        have = 0;
    }
    if (have < size) {
        var range_buf: [64]u8 = undefined;
        const range = try std.fmt.bufPrint(&range_buf, "bytes={d}-", .{have});
        var request = try client.request(.GET, try std.Uri.parse(url), .{
            // Bytes as stored, so lengths and ranges are the file's.
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
            .extra_headers = if (have > 0) &.{.{ .name = "range", .value = range }} else &.{},
        });
        defer request.deinit();
        try request.sendBodiless();
        var response = try request.receiveHead(&.{});
        switch (response.head.status) {
            .partial_content => {},
            // Whole: from the beginning, then.
            .ok => if (have > 0) {
                try out.setLength(io, 0);
                have = 0;
            },
            .not_found => return error.NotFound,
            else => return error.BadStatus,
        }
        var transfer: [64 * 1024]u8 = undefined;
        const body = response.reader(&transfer);
        var write_buf: [64 * 1024]u8 = undefined;
        var writer = out.writer(io, &write_buf);
        try writer.seekTo(have);
        // Never past the file's size, whatever the server sends.
        while (have < size) {
            const n = body.stream(&writer.interface, .limited(@min(size - have, 1 << 20))) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
                error.WriteFailed => return writer.err orelse error.WriteFailed,
            };
            if (n == 0) break;
            have += n;
            if (progress) |p| p.report(p.context, have, size);
        }
        try writer.interface.flush();
    }
    if (try out.length(io) != size) return error.Truncated;
}

test "a title's, season's, or item's files, in the rendition most have" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const founder: [32]u8 = (try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(1))).public_key.toBytes();
    var r = try Replica.open(testing.allocator, testing.io, ":memory:", founder, .from(@splat(1)));
    defer r.close();
    const id = try library.addRepository(&r, 1, "http://nas/tv/", .{});
    const held = try std.fmt.allocPrint(arena, "held:{s}", .{&id});
    try r.write(2, "t/s/firefly/-", "name", "Firefly");
    try r.write(2, "t/s/firefly/-/e/s01e01/r/720p", held, "Firefly/S01E01 720p.mkv\t100\t1");
    try r.write(2, "t/s/firefly/-/e/s01e01/r/1080p", held, "Firefly/S01E01 1080p.mkv\t200\t1");
    try r.write(2, "t/s/firefly/-/e/s01e02/r/1080p", held, "Firefly/S01E02 1080p.mkv\t200\t1");
    try r.write(2, "t/s/firefly/-/e/s02e01/r/1080p", held, "Firefly/S02E01 1080p.mkv\t200\t1");
    try r.write(2, "t/s/firefly/-/e/s01e03/r/1080p", held, "../../etc/passwd\t200\t1");

    const season = try plan(&r, arena, "t/s/firefly/-/e/s01", null);
    try testing.expectEqual(2, season.len);
    try testing.expectEqualStrings("Firefly/S01E01 1080p.mkv", season[0].path);
    try testing.expectEqualStrings("http://nas/tv/Firefly/S01E01%201080p.mkv", season[0].urls[0]);
    try testing.expectEqual(3, (try plan(&r, arena, "t/s/firefly/-", null)).len);
    const one = try plan(&r, arena, "t/s/firefly/-/e/s01e01", "720p");
    try testing.expectEqual(1, one.len);
    try testing.expectEqual(100, one[0].size);
    try testing.expectEqual(1, (try plan(&r, arena, "t/s/firefly/-", "720p")).len);
    try testing.expectError(error.NotFound, plan(&r, arena, "t/s/serenity/2005", null));
}

test "fetches a file, resuming a part, and keeps one whole" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = try arena.alloc(u8, 10_000);
    for (content, 0..) |*b, i| b.* = '0' + @as(u8, @intCast(i % 10));
    try tmp.dir.createDirPath(io, "media/Alien (1979)");
    try tmp.dir.writeFile(io, .{ .sub_path = "media/Alien (1979)/Alien (1979).mp4", .data = content });
    const media = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/media", .{tmp.sub_path});

    var server: @import("host.zig").Host = .{ .io = io, .gpa = gpa, .options = .{ .port = 0, .mounts = &.{.{ .path = media, .index = false }} } };
    try server.start();
    defer server.stop();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var memory: race.Memory = .{};
    defer memory.deinit(gpa);
    const live = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/Alien%20(1979)/Alien%20(1979).mp4", .{server.port});
    const file: File = .{ .item = "t/m/alien/1979/v/-", .rendition = "-", .path = "Alien (1979)/Alien (1979).mp4", .size = content.len, .urls = &.{ "http://127.0.0.1:1/gone.mp4", live } };

    try tmp.dir.createDirPath(io, "out/Alien (1979)");
    var out = try tmp.dir.openDir(io, "out", .{});
    defer out.close(io);
    // As an attempt cut short would leave it.
    try out.writeFile(io, .{ .sub_path = "Alien (1979)/Alien (1979).mp4.part", .data = content[0..1234] });
    try std.testing.expectEqual(.fetched, try fetch(io, gpa, arena, &client, &memory, out, file, 1000, null));
    const got = try out.readFileAlloc(io, file.path, arena, .limited(1 << 20));
    try std.testing.expectEqualStrings(content, got);
    try std.testing.expectEqual(.kept, try fetch(io, gpa, arena, &client, &memory, out, file, 1000, null));
}
