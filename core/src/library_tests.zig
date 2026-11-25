//! The library's crawl tests, apart from library.zig for its length:
//! crawling records when, reuses listings, and keeps an unplugged folder's
//! copies.

const std = @import("std");
const Io = std.Io;
const Replica = @import("replica.zig").Replica;
const crawl = @import("crawl.zig");
const library = @import("library.zig");
const naming = @import("naming.zig");
const testkit = @import("testkit.zig");
const testing = std.testing;
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
const recordServed = library.recordServed;

test "a crawl records when it was, so refreshes not asked for skip it for a day" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const served = try testkit.Served.start(arena, "");
    defer served.stop();
    const dir = served.tmp.dir;
    try dir.writeFile(io, .{ .sub_path = "Alien (1979).mp4", .data = "x" });

    var r = try testkit.replica(1);
    defer r.close();
    _ = try addSource(&r, 1, served.url, .{});
    try std.testing.expectEqual(@as(?u64, 24), try crawlEvery(&r, arena));
    try setCrawlEvery(&r, 2, 0);
    try std.testing.expectEqual(@as(?u64, null), try crawlEvery(&r, arena));
    try setCrawlEvery(&r, 3, 3);
    try std.testing.expectEqual(@as(?u64, 3), try crawlEvery(&r, arena));
    const window = crawlWindow(io, 24);
    try std.testing.expect(window >= 23 * 3600 * 1000 and window <= 25 * 3600 * 1000);
    try std.testing.expect(!(try sources(&r, arena))[0].crawledLately(1000, window));
    const at: u64 = 1_000_000;
    _ = try crawlSource(&r, io, arena, &served.client, at, (try sources(&r, arena))[0], 4);
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
    const served = try testkit.Served.start(arena, "");
    defer served.stop();
    const dir = served.tmp.dir;
    try dir.createDirPath(io, "Movies");
    try dir.writeFile(io, .{ .sub_path = "Movies/Alien (1979).mp4", .data = "x" });
    var r = try testkit.replica(1);
    defer r.close();
    _ = try addSource(&r, 1, served.url, .{});
    const source = (try sources(&r, arena))[0];
    _ = try crawlSource(&r, io, arena, &served.client, 1000, source, 1);
    // Retagged: rewritten in place, its directory's time unchanged.
    try dir.writeFile(io, .{ .sub_path = "Movies/Alien (1979).mp4", .data = "xyz" });
    const reused = try crawlSource(&r, io, arena, &served.client, 2000, source, 1);
    try std.testing.expectEqual(@as(usize, 1), reused.crawl.skipped);
    try std.testing.expectEqual(@as(usize, 0), reused.ingest.copies_changed);
    const full = try crawlSourceAfresh(&r, io, arena, &served.client, 3000, source, 1);
    try std.testing.expectEqual(@as(usize, 0), full.crawl.skipped);
    try std.testing.expectEqual(@as(usize, 1), full.ingest.copies_changed);
}

test "an unplugged directory is unavailable, its copies kept; a deleted one's go" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const served = try testkit.Served.start(arena, "");
    defer served.stop();
    const dir = served.tmp.dir;
    var r = try testkit.replica(1);
    defer r.close();

    // Two drives' mount points, served without an INDEX, so listings stay live.
    try dir.createDirPath(io, "a");
    try dir.createDirPath(io, "b");
    try dir.writeFile(io, .{ .sub_path = "a/Alien (1979).mp4", .data = "x" });
    try dir.writeFile(io, .{ .sub_path = "b/Brazil (1985).mp4", .data = "x" });
    _ = try addSource(&r, 1000, served.url, .{});
    const source = (try sources(&r, arena))[0];
    const t = std.testing;
    // Each crawl reads every listing afresh: within one second, a reused
    // one would look unchanged.
    const Fresh = struct {
        fn crawl(rr: *Replica, io_: Io, a: std.mem.Allocator, c: *std.http.Client, wall: u64, rp: Source) !CrawlStats {
            return crawlSourceAfresh(rr, io_, a, c, wall, rp, 1);
        }
    };

    _ = try Fresh.crawl(&r, io, arena, &served.client, 2000, source);
    try t.expectEqual(@as(i64, 2), try countCopies(&r, arena, source));
    // b unplugged: its mount point lists empty. One marker; its copy kept.
    try dir.deleteFile(io, "b/Brazil (1985).mp4");
    var stats = (try Fresh.crawl(&r, io, arena, &served.client, 3000, source)).ingest;
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
    try dir.writeFile(io, .{ .sub_path = "b/Brazil (1985).mp4", .data = "x" });
    stats = (try Fresh.crawl(&r, io, arena, &served.client, 4000, source)).ingest;
    try t.expectEqual(@as(usize, 0), stats.unavailable);
    try t.expectEqual(@as(usize, 0), stats.copies_added + stats.copies_changed);
    try t.expectEqual(@as(usize, 0), (try unavailableDirs(&r, arena, &source.id)).len);
    // Deleted, b leaves its parent's listing, and its copy goes.
    try dir.deleteFile(io, "b/Brazil (1985).mp4");
    try dir.deleteDir(io, "b");
    stats = (try Fresh.crawl(&r, io, arena, &served.client, 5000, source)).ingest;
    try t.expectEqual(@as(usize, 1), stats.copies_removed);
    try t.expectEqual(@as(i64, 1), try countCopies(&r, arena, source));
    // The whole source listing nothing is the root unavailable.
    try dir.deleteFile(io, "a/Alien (1979).mp4");
    stats = (try Fresh.crawl(&r, io, arena, &served.client, 6000, source)).ingest;
    gone = try unavailableDirs(&r, arena, &source.id);
    try t.expectEqual(@as(usize, 1), gone.len);
    try t.expectEqualStrings("", gone[0].dir);
    try t.expectEqual(@as(i64, 1), try countCopies(&r, arena, source));
    // A year on, it's as if deleted.
    stats = (try Fresh.crawl(&r, io, arena, &served.client, 6000 + unavailable_expiry_ms, source)).ingest;
    try t.expectEqual(@as(usize, 1), stats.copies_removed);
    try t.expectEqual(@as(usize, 0), (try unavailableDirs(&r, arena, &source.id)).len);
    // Forgotten by hand, too.
    try dir.writeFile(io, .{ .sub_path = "a/Alien (1979).mp4", .data = "x" });
    _ = try Fresh.crawl(&r, io, arena, &served.client, 7000 + unavailable_expiry_ms, source);
    try dir.deleteFile(io, "a/Alien (1979).mp4");
    _ = try Fresh.crawl(&r, io, arena, &served.client, 8000 + unavailable_expiry_ms, source);
    try t.expectEqual(@as(usize, 1), try removeUnavailable(&r, arena, 9000 + unavailable_expiry_ms, source, "/"));
    try t.expectEqual(@as(i64, 0), try countCopies(&r, arena, source));
    try t.expectEqual(@as(usize, 0), (try unavailableDirs(&r, arena, &source.id)).len);

    // A folder served at a path of its own (as the apps serve theirs) that
    // goes altogether, as a share unmounted: it lists empty, so it's
    // unavailable, its copies kept, and back again once it returns.
    try dir.createDirPath(io, "share");
    try dir.writeFile(io, .{ .sub_path = "share/Casablanca (1942).mp4", .data = "x" });
    var folder: @import("host.zig").Host = .{ .io = io, .gpa = gpa, .options = .{ .port = 0, .mounts = &.{.{ .prefix = "movies", .path = try std.fmt.allocPrint(arena, "{s}/share", .{served.root}), .index = false }} } };
    try folder.start();
    defer folder.stop();
    _ = try addSource(&r, 9000, try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/movies/", .{folder.port}), .{});
    const share = for (try sources(&r, arena)) |rp| {
        if (std.mem.endsWith(u8, rp.url, "/movies/")) break rp;
    } else unreachable;
    _ = try Fresh.crawl(&r, io, arena, &served.client, 10_000, share);
    try t.expectEqual(@as(i64, 1), try countCopies(&r, arena, share));
    try dir.rename("share", dir, "share-away", io);
    stats = (try Fresh.crawl(&r, io, arena, &served.client, 11_000, share)).ingest;
    try t.expectEqual(@as(usize, 1), stats.unavailable);
    try t.expectEqual(@as(i64, 1), try countCopies(&r, arena, share));
    try t.expectEqualStrings("", (try unavailableDirs(&r, arena, &share.id))[0].dir);
    try dir.rename("share-away", dir, "share", io);
    stats = (try Fresh.crawl(&r, io, arena, &served.client, 12_000, share)).ingest;
    try t.expectEqual(@as(usize, 0), stats.unavailable);
    try t.expectEqual(@as(usize, 0), (try unavailableDirs(&r, arena, &share.id)).len);
}

test "a device's own source is reached where it serves, a new port changing only that" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const served = try testkit.Served.start(arena, "");
    defer served.stop();
    const dir = served.tmp.dir;
    const url = @import("url.zig");
    var r = try testkit.replica(1);
    defer r.close();
    try dir.writeFile(io, .{ .sub_path = "Alien (1979).mp4", .data = "x" });
    try dir.writeFile(io, .{ .sub_path = "Brazil (1985).mkv", .data = "x" });
    const t = std.testing;

    // Unreached until the device says where it serves.
    const me = r.device();
    const id = try addSource(&r, 1000, try url.deviceSource(arena, me, "/"), .{ .quality = .{ .named = "1080p" } });
    try t.expect((try sources(&r, arena))[0].at() == null);
    // Said, it's reached there; a port changing is one field, the source
    // the same; and it crawls as before, its copies unchanged.
    try recordServed(&r, arena, 2000, me, served.url);
    _ = try crawlSourceAfresh(&r, io, arena, &served.client, 3000, (try sources(&r, arena))[0], 1);
    try recordServed(&r, arena, 4000, me, "http://127.0.0.1:1/");
    try recordServed(&r, arena, 5000, me, served.url);
    const now = try sources(&r, arena);
    try t.expectEqualSlices(u8, &id, &now[0].id);
    try t.expectEqualStrings(served.url, now[0].at().?);
    const stats = (try crawlSourceAfresh(&r, io, arena, &served.client, 6000, now[0], 1)).ingest;
    try t.expectEqual(@as(usize, 0), stats.copies_added + stats.copies_changed + stats.copies_removed);
    try t.expectEqual(@as(i64, 2), try countCopies(&r, arena, now[0]));
}

test "qualities come from the source, or else from the file's name, or its folders'" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Parses share nothing with each other but their scratch space.
    var scratch: [3][512]u8 = undefined;
    const sd = naming.parse("Movies/Alien (1979)/Alien (1979) - 720p.mkv", &scratch[0]);
    const uhd = naming.parse("Movies/Alien (1979)/Alien (1979) - 4K HDR.mkv", &scratch[1]);
    try testing.expectEqualStrings((try library.keys(a, sd)).item, (try library.keys(a, uhd)).item);
    try testing.expectEqualStrings("720p", try library.qualityOf(a, .{}, sd, null));
    try testing.expectEqualStrings("2160p-hdr", try library.qualityOf(a, .{}, uhd, null));
    try testing.expectEqualStrings("very-fast-720p30", try library.qualityOf(a, .{ .quality = .{ .named = "Very Fast 720p30" } }, uhd, null));
    try testing.expectEqualStrings("-", try library.qualityOf(a, .{}, naming.parse("Alien (1979).mkv", &scratch[2]), null));
    // By default, names and folders: the nearest that says one, a folder by
    // its whole name, unless it reads as a title's.
    const Case = struct { []const u8, []const u8, []const u8 };
    for ([_]Case{
        .{ "Video/TV Shows/1080p/30 Rock/30 Rock 101 Pilot.mkv", "Video/TV Shows/30 Rock/30 Rock 101 Pilot.mkv", "1080p" },
        .{ "HQ 1080p30 Surround/Firefly/Season 01/Firefly S01E02.m4v", "Firefly/Season 01/Firefly S01E02.m4v", "hq-1080p30-surround" },
        .{ "Downloaded 1080p/Hamilton.2020.2160p.WEBRip.x264.mp4", "Downloaded 1080p/Hamilton.2020.2160p.WEBRip.x264.mp4", "2160p-web-h264" },
        .{ "Very Fast 720p30/Madame Web (2024).m4v", "Madame Web (2024).m4v", "very-fast-720p30" },
        .{ "TV Shows/30 Rock (2006) 1080p/30 Rock 101 Pilot.mkv", "TV Shows/30 Rock (2006) 1080p/30 Rock 101 Pilot.mkv", "1080p" },
        .{ "Video/Alien (1979).mkv", "Video/Alien (1979).mkv", "-" },
    }) |c| {
        const layout: library.Layout = .{};
        const at = try library.named(a, layout, c[0]);
        try testing.expectEqualStrings(c[1], at.path);
        try testing.expectEqualStrings(c[2], try library.qualityOf(a, layout, naming.parse(at.path, &scratch[2]), at.folder));
    }
}
