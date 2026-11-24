//! The library's crawl tests, apart from library.zig for its length:
//! crawling records when, reuses listings, and keeps an unplugged folder's
//! copies.

const std = @import("std");
const Io = std.Io;
const ascii = std.ascii;
const Replica = @import("replica.zig").Replica;
const crawl = @import("crawl.zig");
const library = @import("library.zig");
const Source = library.Source;
const sources = library.sources;
const CrawlStats = library.CrawlStats;
const unavailable_expiry_ms = library.unavailable_expiry_ms;
const detail = library.detail;
const addSource = library.addSource;
const crawlSource = library.crawlSource;
const crawlSourceAfresh = library.crawlSourceAfresh;
const crawlEvery = library.crawlEvery;
const setCrawlEvery = library.setCrawlEvery;
const crawlWindow = library.crawlWindow;
const countCopies = library.countCopies;
const removeUnavailable = library.removeUnavailable;
const unavailableDirs = library.unavailableDirs;
const moveSource = library.moveSource;
const recordServed = library.recordServed;

test "a crawl records when it was, so refreshes not asked for skip it for a day" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "Alien (1979).mp4", .data = "x" });
    var server: @import("host.zig").Host = .{ .io = io, .gpa = gpa, .options = .{ .port = 0, .mounts = &.{.{ .path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path}), .index = false }} } };
    try server.start();
    defer server.stop();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const founder: [32]u8 = (try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(1))).public_key.toBytes();
    var r = try Replica.open(gpa, io, ":memory:", founder, .from(@splat(1)));
    defer r.close();
    _ = try addSource(&r, 1, try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/", .{server.port}), .{});
    try std.testing.expectEqual(@as(?u64, 24), try crawlEvery(&r, arena));
    try setCrawlEvery(&r, 2, 0);
    try std.testing.expectEqual(@as(?u64, null), try crawlEvery(&r, arena));
    try setCrawlEvery(&r, 3, 3);
    try std.testing.expectEqual(@as(?u64, 3), try crawlEvery(&r, arena));
    const window = crawlWindow(io, 24);
    try std.testing.expect(window >= 23 * 3600 * 1000 and window <= 25 * 3600 * 1000);
    try std.testing.expect(!(try sources(&r, arena))[0].crawledLately(1000, window));
    const at: u64 = 1_000_000;
    _ = try crawlSource(&r, io, arena, &client, at, (try sources(&r, arena))[0], 4);
    const source = (try sources(&r, arena))[0];
    try std.testing.expectEqual(at, source.crawled_ms);
    try std.testing.expect(source.crawledLately(at + window - 1, window));
    try std.testing.expect(!source.crawledLately(at + window, window));
}

test "a full crawl sees a file rewritten in place, which reusing listings misses" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Movies");
    try tmp.dir.writeFile(io, .{ .sub_path = "Movies/Alien (1979).mp4", .data = "x" });
    var server: @import("host.zig").Host = .{ .io = io, .gpa = gpa, .options = .{ .port = 0, .mounts = &.{.{ .path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path}), .index = false }} } };
    try server.start();
    defer server.stop();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const founder: [32]u8 = (try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(1))).public_key.toBytes();
    var r = try Replica.open(gpa, io, ":memory:", founder, .from(@splat(1)));
    defer r.close();
    _ = try addSource(&r, 1, try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/", .{server.port}), .{});
    const source = (try sources(&r, arena))[0];
    _ = try crawlSource(&r, io, arena, &client, 1000, source, 1);
    // Retagged: rewritten in place, its directory's time unchanged.
    try tmp.dir.writeFile(io, .{ .sub_path = "Movies/Alien (1979).mp4", .data = "xyz" });
    const reused = try crawlSource(&r, io, arena, &client, 2000, source, 1);
    try std.testing.expectEqual(@as(usize, 1), reused.crawl.skipped);
    try std.testing.expectEqual(@as(usize, 0), reused.ingest.copies_changed);
    const full = try crawlSourceAfresh(&r, io, arena, &client, 3000, source, 1);
    try std.testing.expectEqual(@as(usize, 0), full.crawl.skipped);
    try std.testing.expectEqual(@as(usize, 1), full.ingest.copies_changed);
}

test "an unplugged directory is unavailable, its copies kept; a deleted one's go" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const replica_ = @import("replica.zig");
    const founder = (try replica_.personKeyPair(@splat(1))).public_key.toBytes();
    var r = try Replica.open(gpa, io, ":memory:", founder, .from(@splat(1)));
    defer r.close();

    // Two drives' mount points, served without an INDEX, so listings stay live.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "a");
    try tmp.dir.createDirPath(io, "b");
    try tmp.dir.writeFile(io, .{ .sub_path = "a/Alien (1979).mp4", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b/Brazil (1985).mp4", .data = "x" });
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var server: @import("host.zig").Host = .{ .io = io, .gpa = gpa, .options = .{ .port = 0, .mounts = &.{.{ .path = root, .index = false }} } };
    try server.start();
    defer server.stop();
    _ = try addSource(&r, 1000, try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/", .{server.port}), .{});
    const source = (try sources(&r, arena))[0];
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const t = std.testing;
    // Each crawl reads every listing afresh: within one second, a reused
    // one would look unchanged.
    const Fresh = struct {
        fn crawl(rr: *Replica, io_: Io, a: std.mem.Allocator, c: *std.http.Client, wall: u64, rp: Source) !CrawlStats {
            return crawlSourceAfresh(rr, io_, a, c, wall, rp, 1);
        }
    };

    _ = try Fresh.crawl(&r, io, arena, &client, 2000, source);
    try t.expectEqual(@as(i64, 2), try countCopies(&r, arena, source));
    // b unplugged: its mount point lists empty. One marker; its copy kept.
    try tmp.dir.deleteFile(io, "b/Brazil (1985).mp4");
    var stats = (try Fresh.crawl(&r, io, arena, &client, 3000, source)).ingest;
    try t.expectEqual(@as(usize, 1), stats.unavailable);
    try t.expectEqual(@as(usize, 0), stats.copies_removed);
    try t.expectEqual(@as(i64, 2), try countCopies(&r, arena, source));
    var gone = try unavailableDirs(&r, arena, &source.id);
    try t.expectEqual(@as(usize, 1), gone.len);
    try t.expectEqualStrings("b", gone[0].dir);
    try t.expectEqual(@as(u64, 3000), gone[0].since_ms);
    const shown = (try detail(&r, arena, "t/m/brazil/1985")).?;
    try t.expect(shown.items.items[0].qualities.items[0].copies.items[0].unavailable);
    // Plugged back in: the marker goes, and nothing else changes.
    try tmp.dir.writeFile(io, .{ .sub_path = "b/Brazil (1985).mp4", .data = "x" });
    stats = (try Fresh.crawl(&r, io, arena, &client, 4000, source)).ingest;
    try t.expectEqual(@as(usize, 0), stats.unavailable);
    try t.expectEqual(@as(usize, 0), stats.copies_added + stats.copies_changed);
    try t.expectEqual(@as(usize, 0), (try unavailableDirs(&r, arena, &source.id)).len);
    // Deleted, b leaves its parent's listing, and its copy goes.
    try tmp.dir.deleteFile(io, "b/Brazil (1985).mp4");
    try tmp.dir.deleteDir(io, "b");
    stats = (try Fresh.crawl(&r, io, arena, &client, 5000, source)).ingest;
    try t.expectEqual(@as(usize, 1), stats.copies_removed);
    try t.expectEqual(@as(i64, 1), try countCopies(&r, arena, source));
    // The whole source listing nothing is the root unavailable.
    try tmp.dir.deleteFile(io, "a/Alien (1979).mp4");
    stats = (try Fresh.crawl(&r, io, arena, &client, 6000, source)).ingest;
    gone = try unavailableDirs(&r, arena, &source.id);
    try t.expectEqual(@as(usize, 1), gone.len);
    try t.expectEqualStrings("", gone[0].dir);
    try t.expectEqual(@as(i64, 1), try countCopies(&r, arena, source));
    // A year on, it's as if deleted.
    stats = (try Fresh.crawl(&r, io, arena, &client, 6000 + unavailable_expiry_ms, source)).ingest;
    try t.expectEqual(@as(usize, 1), stats.copies_removed);
    try t.expectEqual(@as(usize, 0), (try unavailableDirs(&r, arena, &source.id)).len);
    // Forgotten by hand, too.
    try tmp.dir.writeFile(io, .{ .sub_path = "a/Alien (1979).mp4", .data = "x" });
    _ = try Fresh.crawl(&r, io, arena, &client, 7000 + unavailable_expiry_ms, source);
    try tmp.dir.deleteFile(io, "a/Alien (1979).mp4");
    _ = try Fresh.crawl(&r, io, arena, &client, 8000 + unavailable_expiry_ms, source);
    try t.expectEqual(@as(usize, 1), try removeUnavailable(&r, arena, 9000 + unavailable_expiry_ms, source, "/"));
    try t.expectEqual(@as(i64, 0), try countCopies(&r, arena, source));
    try t.expectEqual(@as(usize, 0), (try unavailableDirs(&r, arena, &source.id)).len);

    // A folder served at a path of its own (as the apps serve theirs) that
    // goes altogether, as a share unmounted: it lists empty, so it's
    // unavailable, its copies kept, and back again once it returns.
    try tmp.dir.createDirPath(io, "share");
    try tmp.dir.writeFile(io, .{ .sub_path = "share/Casablanca (1942).mp4", .data = "x" });
    var folder: @import("host.zig").Host = .{ .io = io, .gpa = gpa, .options = .{ .port = 0, .mounts = &.{.{ .prefix = "movies", .path = try std.fmt.allocPrint(arena, "{s}/share", .{root}), .index = false }} } };
    try folder.start();
    defer folder.stop();
    _ = try addSource(&r, 9000, try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/movies/", .{folder.port}), .{});
    const share = for (try sources(&r, arena)) |rp| {
        if (std.mem.endsWith(u8, rp.url, "/movies/")) break rp;
    } else unreachable;
    _ = try Fresh.crawl(&r, io, arena, &client, 10_000, share);
    try t.expectEqual(@as(i64, 1), try countCopies(&r, arena, share));
    try tmp.dir.rename("share", tmp.dir, "share-away", io);
    stats = (try Fresh.crawl(&r, io, arena, &client, 11_000, share)).ingest;
    try t.expectEqual(@as(usize, 1), stats.unavailable);
    try t.expectEqual(@as(i64, 1), try countCopies(&r, arena, share));
    try t.expectEqualStrings("", (try unavailableDirs(&r, arena, &share.id))[0].dir);
    try tmp.dir.rename("share-away", tmp.dir, "share", io);
    stats = (try Fresh.crawl(&r, io, arena, &client, 12_000, share)).ingest;
    try t.expectEqual(@as(usize, 0), stats.unavailable);
    try t.expectEqual(@as(usize, 0), (try unavailableDirs(&r, arena, &share.id)).len);
}

test "a device's own source, moved to its port-free address once, keeps its copies, reached where it serves" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const replica_ = @import("replica.zig");
    const url = @import("url.zig");
    const founder = (try replica_.personKeyPair(@splat(1))).public_key.toBytes();
    var r = try Replica.open(gpa, io, ":memory:", founder, .from(@splat(1)));
    defer r.close();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "a");
    try tmp.dir.createDirPath(io, "b");
    try tmp.dir.writeFile(io, .{ .sub_path = "a/Alien (1979).mp4", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b/Brazil (1985).mkv", .data = "x" });
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var server: @import("host.zig").Host = .{ .io = io, .gpa = gpa, .options = .{ .port = 0, .mounts = &.{.{ .path = root, .index = false }} } };
    try server.start();
    defer server.stop();
    _ = try addSource(&r, 1000, try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/", .{server.port}), .{ .quality = .{ .named = "1080p" }, .skip = "." });
    const source = (try sources(&r, arena))[0];
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const t = std.testing;
    _ = try crawlSourceAfresh(&r, io, arena, &client, 2000, source, 1);
    // b unplugged: its copy kept, marked unavailable.
    try tmp.dir.deleteFile(io, "b/Brazil (1985).mkv");
    _ = try crawlSourceAfresh(&r, io, arena, &client, 3000, source, 1);

    // Moved once to this device's port-free address: unreached until the
    // device says where it serves.
    const me = r.device();
    // Added by hand at an IP address, it isn't the apps' to move.
    try t.expect(try library.portBound(&r, arena, me, "/") == null);
    const id = try moveSource(&r, arena, 4000, &source.id, try url.deviceSource(arena, me, "/"));
    var now = try sources(&r, arena);
    try t.expectEqual(@as(usize, 1), now.len);
    try t.expectEqualSlices(u8, &id, &now[0].id);
    try t.expect(now[0].at() == null);
    try t.expectEqualStrings(".", now[0].layout.skip);
    try t.expectEqual(@as(i64, 2), try countCopies(&r, arena, now[0]));
    try t.expectEqual(@as(usize, 1), (try unavailableDirs(&r, arena, &id)).len);
    // Said, it's reached there; a port changing is one field, the source
    // the same; and it crawls as before, its copies unchanged.
    try recordServed(&r, arena, 5000, me, "http://127.0.0.1:1/");
    try recordServed(&r, arena, 6000, me, try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/", .{server.port}));
    now = try sources(&r, arena);
    try t.expectEqualSlices(u8, &id, &now[0].id);
    try t.expectEqualStrings(try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/", .{server.port}), now[0].at().?);
    const stats = (try crawlSourceAfresh(&r, io, arena, &client, 7000, now[0], 1)).ingest;
    try t.expectEqual(@as(usize, 0), stats.copies_added + stats.copies_changed + stats.copies_removed);
    try t.expectEqual(@as(i64, 2), try countCopies(&r, arena, now[0]));
    // One the apps wrote, at this device's `.local` name and port, moves
    // to its port-free address once, and then stays.
    _ = try addSource(&r, 9000, "http://firefly.local:58275/downloads/", .{ .quality = .names });
    const own = try library.ownSource(&r, arena, 10000, me, "/downloads/");
    try t.expectEqualStrings(try url.deviceSource(arena, me, "/downloads/"), own);
    try t.expect(try library.portBound(&r, arena, me, "/downloads/") == null);
    try t.expectEqual(@as(usize, 2), (try sources(&r, arena)).len);
}
