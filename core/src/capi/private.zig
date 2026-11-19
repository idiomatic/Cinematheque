//! The C interface (see ../capi.zig): this person's private data.

const std = @import("std");
const capi = @import("../capi.zig");
const library = @import("../library.zig");
const art = @import("../art.zig");
const replica_ = @import("../replica.zig");
const Replica = replica_.Replica;
const Library = capi.Library;
const json = capi.json;
const status = capi.status;
const span = capi.span;

/// Records this person's progress in an item (a title's key and an item's,
/// e.g., `t/m/alien/1979/v/-`).
export fn cq_set_progress(lib: *Library, item_key: [*:0]const u8, position_ms: u64, duration_ms: u64) c_int {
    return status(lib, setProgress, .{ std.mem.span(item_key), position_ms, duration_ms });
}

fn setProgress(lib: *Library, arena: std.mem.Allocator, item_key: []const u8, position_ms: u64, duration_ms: u64) !void {
    const r = try privateWriter(lib);
    defer if (r.locked) lib.writer.unlock(lib.io());
    try library.setProgress(r.replica, arena, lib.now(), item_key, position_ms, duration_ms);
}

/// Marks an item watched (nonzero) or not.
export fn cq_set_watched(lib: *Library, item_key: [*:0]const u8, watched: c_int) c_int {
    return status(lib, setWatched, .{ std.mem.span(item_key), watched != 0 });
}

fn setWatched(lib: *Library, arena: std.mem.Allocator, item_key: []const u8, watched: bool) !void {
    const r = try privateWriter(lib);
    defer if (r.locked) lib.writer.unlock(lib.io());
    try library.setWatched(r.replica, arena, lib.now(), item_key, watched);
}

/// Removes this person's progress in an item: its position and watched mark.
export fn cq_remove_progress(lib: *Library, item_key: [*:0]const u8) c_int {
    return status(lib, removeProgress, .{std.mem.span(item_key)});
}

fn removeProgress(lib: *Library, arena: std.mem.Allocator, item_key: []const u8) !void {
    const r = try privateWriter(lib);
    defer if (r.locked) lib.writer.unlock(lib.io());
    try library.removeProgress(r.replica, arena, lib.now(), item_key);
}

/// What's on this person's watchlist, as a JSON array of keys: a movie's
/// title key, or a season's tile (`<title key>#<season>`).
export fn cq_watchlist(lib: *Library) ?[*:0]u8 {
    return json(lib, getWatchlist, .{});
}

fn getWatchlist(lib: *Library, arena: std.mem.Allocator) ![]const []const u8 {
    return art.watchlist(try lib.main(), arena);
}

/// Adds a movie or a season (as `cq_watchlist` keys them) to this person's
/// watchlist (nonzero `on`), or removes it.
export fn cq_set_watchlisted(lib: *Library, title_key: [*:0]const u8, on: c_int) c_int {
    return status(lib, setWatchlisted, .{ std.mem.span(title_key), on != 0 });
}

fn setWatchlisted(lib: *Library, arena: std.mem.Allocator, title_key: []const u8, on: bool) !void {
    const r = try privateWriter(lib);
    defer if (r.locked) lib.writer.unlock(lib.io());
    try art.setWatchlisted(r.replica, arena, lib.now(), title_key, on);
}

/// The main connection, for private writes, which need the writer lock only
/// for the device's first (whose private stream's certificate is public).
fn privateWriter(lib: *Library) !struct { replica: *Replica, locked: bool } {
    const r = try lib.main();
    if (r.private_seq > 0) return .{ .replica = r, .locked = false };
    if (!lib.writer.tryLock()) return error.Busy;
    try r.refresh();
    return .{ .replica = r, .locked = true };
}
