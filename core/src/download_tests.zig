//! Tests of what downloading a title, season, or item would fetch.

const std = @import("std");
const library = @import("library.zig");
const download = @import("download.zig");
const testkit = @import("testkit.zig");

test "a title's, season's, or item's files, in the quality most have" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r = try testkit.replica(1);
    defer r.close();
    const id = try library.addSource(&r, 1, "http://nas/tv/", .{});
    const held_field = try std.fmt.allocPrint(arena, "held:{s}", .{&id});
    try r.write(2, "t/s/firefly/-", "name", "Firefly");
    try r.write(2, "t/s/firefly/-/e/s01e01/r/720p", held_field, "Firefly/S01E01 720p.mkv\t100\t1");
    try r.write(2, "t/s/firefly/-/e/s01e01/r/1080p", held_field, "Firefly/S01E01 1080p.mkv\t200\t1");
    try r.write(2, "t/s/firefly/-/e/s01e02/r/1080p", held_field, "Firefly/S01E02 1080p.mkv\t200\t1");
    try r.write(2, "t/s/firefly/-/e/s02e01/r/1080p", held_field, "Firefly/S02E01 1080p.mkv\t200\t1");
    try r.write(2, "t/s/firefly/-/e/s01e03/r/1080p", held_field, "../../etc/passwd\t200\t1");

    const season = try download.plan(&r, arena, "t/s/firefly/-/e/s01", null);
    try testing.expectEqual(2, season.len);
    try testing.expectEqualStrings("Firefly/S01E01 1080p.mkv", season[0].path);
    try testing.expectEqualStrings("http://nas/tv/Firefly/S01E01%201080p.mkv", season[0].urls[0]);
    try testing.expectEqual(3, (try download.plan(&r, arena, "t/s/firefly/-", null)).len);
    const one = try download.plan(&r, arena, "t/s/firefly/-/e/s01e01", "720p");
    try testing.expectEqual(1, one.len);
    try testing.expectEqual(100, one[0].size);
    // Those without 720p come in the nearest quality: none lower, so 1080p.
    const all = try download.plan(&r, arena, "t/s/firefly/-", "720p");
    try testing.expectEqual(3, all.len);
    try testing.expectEqualStrings("1080p", all[1].quality);
    // A version with parts and a whole file: its key, the whole alone; a
    // version of parts alone, its parts.
    try r.write(2, "t/m/gandhi/1982/v/-/r/1080p", held_field, "Gandhi (1982).m4v\t300\t1");
    try r.write(2, "t/m/gandhi/1982/v/-/p/1/r/1080p", held_field, "Gandhi (1982) - Part 1.m4v\t150\t1");
    try r.write(2, "t/m/gandhi/1982/v/-/p/2/r/1080p", held_field, "Gandhi (1982) - Part 2.m4v\t150\t1");
    try r.write(2, "t/m/gandhi/1982/v/extended/p/1/r/1080p", held_field, "Gandhi (1982) - Extended Part 1.m4v\t150\t1");
    try r.write(2, "t/m/gandhi/1982/v/extended/p/2/r/1080p", held_field, "Gandhi (1982) - Extended Part 2.m4v\t150\t1");
    try testing.expectEqual(1, (try download.plan(&r, arena, "t/m/gandhi/1982/v/-", null)).len);
    try testing.expectEqual(2, (try download.plan(&r, arena, "t/m/gandhi/1982/v/extended", null)).len);
    try testing.expectEqual(5, (try download.plan(&r, arena, "t/m/gandhi/1982", null)).len);
    try testing.expectError(error.NotFound, download.plan(&r, arena, "t/s/serenity/2005", null));
}
