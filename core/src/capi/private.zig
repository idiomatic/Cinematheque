//! The C interface (see ../capi.zig): this person's private data.

const std = @import("std");
const capi = @import("../capi.zig");
const library = @import("../library.zig");
const lists = @import("../lists.zig");
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

/// Marks an item watched.
export fn cq_mark_watched(lib: *Library, item_key: [*:0]const u8) c_int {
    return status(lib, markWatched, .{std.mem.span(item_key)});
}

fn markWatched(lib: *Library, arena: std.mem.Allocator, item_key: []const u8) !void {
    const r = try privateWriter(lib);
    defer if (r.locked) lib.writer.unlock(lib.io());
    try library.markWatched(r.replica, arena, lib.now(), item_key);
}

/// Marks an item unwatched, forgetting where this person stopped, so it
/// plays from the beginning.
export fn cq_mark_unwatched(lib: *Library, item_key: [*:0]const u8) c_int {
    return status(lib, markUnwatched, .{std.mem.span(item_key)});
}

fn markUnwatched(lib: *Library, arena: std.mem.Allocator, item_key: []const u8) !void {
    const r = try privateWriter(lib);
    defer if (r.locked) lib.writer.unlock(lib.io());
    try library.markUnwatched(r.replica, arena, lib.now(), item_key);
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

/// This person's lists, then other members' shared ones, each by name, as
/// a JSON array of objects: `id` (another member's, `<owner>/<id>`),
/// `name`, `owner` (its person's key, in hex), `ownerName` (another
/// member's name, if set), `mine` (only its owner changes it), `shared` (every member sees
/// it), `titles`, each a movie's title key or a season's tile
/// (`<title key>#<season>`), and `wanted`, the placeholders among them
/// (`key`, `name` as typed, and `note`).
export fn cq_lists(lib: *Library) ?[*:0]u8 {
    return json(lib, getLists, .{});
}

fn getLists(lib: *Library, arena: std.mem.Allocator) ![]const lists.List {
    return lists.lists(try lib.main(), arena);
}

/// Makes a list named `name`, returning its ID as a JSON string.
export fn cq_list_create(lib: *Library, name: [*:0]const u8) ?[*:0]u8 {
    return json(lib, createList, .{std.mem.span(name)});
}

fn createList(lib: *Library, arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    const r = try privateWriter(lib);
    defer if (r.locked) lib.writer.unlock(lib.io());
    return lists.create(lib.io(), r.replica, arena, lib.now(), name);
}

export fn cq_list_rename(lib: *Library, id: [*:0]const u8, name: [*:0]const u8) c_int {
    return status(lib, renameList, .{ std.mem.span(id), std.mem.span(name) });
}

fn renameList(lib: *Library, arena: std.mem.Allocator, id: []const u8, name: []const u8) !void {
    const r = try listWriter(lib, arena, id);
    defer if (r.locked) lib.writer.unlock(lib.io());
    try lists.rename(r.replica, arena, lib.now(), id, name);
}

/// Deletes a list, for good.
export fn cq_list_remove(lib: *Library, id: [*:0]const u8) c_int {
    return status(lib, removeList, .{std.mem.span(id)});
}

fn removeList(lib: *Library, arena: std.mem.Allocator, id: []const u8) !void {
    const r = try listWriter(lib, arena, id);
    defer if (r.locked) lib.writer.unlock(lib.io());
    try lists.remove(r.replica, arena, lib.now(), id);
}

/// Puts a movie or a season (as `cq_lists` keys them) on the list `id`.
export fn cq_list_add_title(lib: *Library, id: [*:0]const u8, title_key: [*:0]const u8) c_int {
    return status(lib, setListed, .{ std.mem.span(id), std.mem.span(title_key), true });
}

/// Takes a movie or a season off the list `id`.
export fn cq_list_remove_title(lib: *Library, id: [*:0]const u8, title_key: [*:0]const u8) c_int {
    return status(lib, setListed, .{ std.mem.span(id), std.mem.span(title_key), false });
}

/// Writes whether a title's on a list: its value, the same write either way.
fn setListed(lib: *Library, arena: std.mem.Allocator, id: []const u8, title_key: []const u8, on: bool) !void {
    const r = try listWriter(lib, arena, id);
    defer if (r.locked) lib.writer.unlock(lib.io());
    try lists.setListed(r.replica, arena, lib.now(), id, title_key, on);
}

/// Puts a title not in the library yet on the list `id`, as a placeholder,
/// keyed as its file will be (see `lists.want`): `json` is an object with
/// `kind` ("movie" or "series"), `name`, and optionally `year`, `season`
/// (a series', else the first), and `note`. Returns its key as a JSON
/// string, as `cq_lists` will list it.
export fn cq_list_want(lib: *Library, id: [*:0]const u8, want_json: [*:0]const u8) ?[*:0]u8 {
    return json(lib, listWant, .{ std.mem.span(id), std.mem.span(want_json) });
}

fn listWant(lib: *Library, arena: std.mem.Allocator, id: []const u8, want_json: []const u8) ![]const u8 {
    const w = try std.json.parseFromSliceLeaky(lists.WantJson, arena, want_json, .{});
    const r = try listWriter(lib, arena, id);
    defer if (r.locked) lib.writer.unlock(lib.io());
    return lists.wantJson(r.replica, arena, lib.now(), id, w);
}

/// Shares a list of this person's with every member.
export fn cq_list_share(lib: *Library, id: [*:0]const u8) c_int {
    return status(lib, shareList, .{std.mem.span(id)});
}

fn shareList(lib: *Library, arena: std.mem.Allocator, id: []const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    const r = try lib.main();
    try r.refresh();
    try lists.share(lib.io(), r, arena, lib.now(), id);
}

/// Makes a shared list of this person's theirs alone again.
export fn cq_list_stop_sharing(lib: *Library, id: [*:0]const u8) c_int {
    return status(lib, stopSharing, .{std.mem.span(id)});
}

fn stopSharing(lib: *Library, arena: std.mem.Allocator, id: []const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    const r = try lib.main();
    try r.refresh();
    try lists.stopSharing(lib.io(), r, arena, lib.now(), id);
}

const Writer = struct { replica: *Replica, locked: bool };

/// The main connection, for changing the list `id`: a shared one's changes
/// are public, so take the writer lock; a private one's, as `privateWriter`.
fn listWriter(lib: *Library, arena: std.mem.Allocator, id: []const u8) !Writer {
    if (!try lists.isShared(try lib.main(), arena, id)) return privateWriter(lib);
    if (!lib.writer.tryLock()) return error.Busy;
    const r = try lib.main();
    try r.refresh();
    return .{ .replica = r, .locked = true };
}

/// The main connection, for private writes, which need the writer lock only
/// for the device's first (whose private stream's certificate is public).
fn privateWriter(lib: *Library) !Writer {
    const r = try lib.main();
    if (r.private_seq > 0) return .{ .replica = r, .locked = false };
    if (!lib.writer.tryLock()) return error.Busy;
    try r.refresh();
    return .{ .replica = r, .locked = true };
}
