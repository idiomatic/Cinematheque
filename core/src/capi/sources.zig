//! The C interface (see ../capi.zig): sources.

const std = @import("std");
const capi = @import("../capi.zig");
const library = @import("../library.zig");
const race = @import("../race.zig");
const long = @import("long.zig");
const gpa = capi.gpa;
const Library = capi.Library;
const json = capi.json;
const span = capi.span;

/// The sources, in the order to list them (by `path`, devices' downloads
/// last), as a JSON array of objects with `id`, `url`, `path` (its server
/// and folders as a person reads them, to join with " › "), `owner` (the
/// key of the device whose it is, which wrote its address),
/// `quality_from` (`path`, `named`, or `unknown`, a newer
/// device's), `quality` (its name, if named), `skip`, `copies`, `managed` (a device's downloads), and
/// `unavailable`, its unavailable directories
/// (`dir`, relative to it, empty for the whole of it, and `since`, in
/// milliseconds since the epoch). Any thread, on a connection of its own,
/// as `cq_tiles` is (counting copies reads every one).
export fn cq_repos(lib: *Library) ?[*:0]u8 {
    return json(lib, sources, .{});
}

const AbsenceJson = struct { dir: []const u8, since: u64 };
const SourceJson = struct { id: []const u8, url: []const u8, address: ?[]const u8, path: []const []const u8, owner: ?[]const u8, quality_from: std.meta.Tag(library.QualityFrom), quality: []const u8, skip: []const u8, copies: i64, unavailable: []const AbsenceJson, managed: bool };

fn sources(lib: *Library, arena: std.mem.Allocator) ![]const SourceJson {
    var connection = try long.reader(lib, arena);
    defer long.release(lib, &connection);
    const r = &connection;
    const list = try library.sources(r, arena);
    const out = try arena.alloc(SourceJson, list.len);
    const counts = try library.copyCounts(r, arena);
    for (list, out) |rp, *o| o.* = .{
        .id = try arena.dupe(u8, &rp.id),
        .url = rp.url,
        .address = rp.at(),
        .path = try library.shownPath(arena, rp),
        .owner = if (rp.owner) |key| try arena.dupe(u8, &std.fmt.bytesToHex(key, .lower)) else null,
        .quality_from = rp.layout.quality,
        .quality = switch (rp.layout.quality) {
            .named => |n| n,
            .path, .unknown => "",
        },
        .skip = rp.layout.skip,
        .copies = counts.get(&rp.id) orelse 0,
        .managed = rp.managed,
        .unavailable = blk: {
            const list_ = try library.unavailableDirs(r, arena, &rp.id);
            const unavailable = try arena.alloc(AbsenceJson, list_.len);
            for (list_, unavailable) |a, *j| j.* = .{ .dir = a.dir, .since = a.since_ms };
            break :blk unavailable;
        },
    };
    return out;
}

/// Long (up to `race.timeout_ms`), on any thread: copy racing. Takes an
/// item's copies' URLs, `count` of them, in the order a player would try
/// them, and returns them as a JSON array in the order to try: those whose
/// servers answer, at once and briefly, first; a server that didn't lately,
/// last (see race.zig).
export fn cq_race(lib: *Library, urls: ?[*]const [*:0]const u8, count: usize) ?[*:0]u8 {
    return json(lib, raceCopies, .{ urls, count });
}

fn raceCopies(lib: *Library, arena: std.mem.Allocator, urls: ?[*]const [*:0]const u8, count: usize) ![]const []const u8 {
    return race.order(lib.io(), gpa, arena, &lib.racing, try capi.spans(arena, urls, count), lib.now());
}

/// Long: looks up the names of the servers of `urls` (`count` of them, such
/// as the sources'), so copy racing's first race finds them answered. Any
/// thread.
export fn cq_race_warm(lib: *Library, urls: ?[*]const [*:0]const u8, count: usize) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    race.warm(lib.io(), arena, capi.spans(arena, urls, count) catch return) catch {};
}

/// Notes that a copy didn't load, so its server is raced last for a while.
/// Any thread.
export fn cq_race_lost(lib: *Library, url: [*:0]const u8) void {
    lib.racing.lost(lib.io(), gpa, std.mem.span(url), lib.now()) catch {};
}
