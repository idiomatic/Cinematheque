//! The C interface (see ../capi.zig): this person's private data.

const std = @import("std");
const capi = @import("../capi.zig");
const library = @import("../library.zig");
const lists = @import("../lists.zig");
const Replica = @import("../replica.zig").Replica;
const Library = capi.Library;
const json = capi.json;
const status = capi.status;
const writePrivate = capi.writePrivate;

/// Records this person's progress in an item (a title's key and an item's,
/// e.g., `t/m/alien/1979/v/-`).
export fn cq_set_progress(lib: *Library, item_key: [*:0]const u8, position_ms: u64, duration_ms: u64) c_int {
    return writePrivate(lib, library.setProgress, .{ std.mem.span(item_key), position_ms, duration_ms });
}

/// Marks an item watched.
export fn cq_mark_watched(lib: *Library, item_key: [*:0]const u8) c_int {
    return writePrivate(lib, library.markWatched, .{std.mem.span(item_key)});
}

/// Marks an item unwatched, forgetting where this person stopped, so it
/// plays from the beginning.
export fn cq_mark_unwatched(lib: *Library, item_key: [*:0]const u8) c_int {
    return writePrivate(lib, library.markUnwatched, .{std.mem.span(item_key)});
}

/// Removes this person's progress in an item: its position and watched mark.
export fn cq_remove_progress(lib: *Library, item_key: [*:0]const u8) c_int {
    return writePrivate(lib, library.removeProgress, .{std.mem.span(item_key)});
}

/// This person's lists, then other members' shared ones, each by name, as
/// a JSON array of objects: `id` (another member's, `<owner>/<id>`),
/// `name`, `owner` (its person's key, in hex), `ownerName` (another
/// member's name, if set), `mine` (only its owner changes it), `mode`
/// (`private`, its owner's alone, or `shared`, every member sees it), `titles`, each a movie's title key or a season's tile
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
    return capi.writingPrivate(lib, arena, create, .{ lib.io(), name });
}

fn create(r: *Replica, arena: std.mem.Allocator, now: u64, io: std.Io, name: []const u8) ![]const u8 {
    return lists.create(io, r, arena, now, name);
}

export fn cq_list_rename(lib: *Library, id: [*:0]const u8, name: [*:0]const u8) c_int {
    return status(lib, renameList, .{ std.mem.span(id), std.mem.span(name) });
}

fn renameList(lib: *Library, arena: std.mem.Allocator, id: []const u8, name: []const u8) !void {
    try writingList(lib, arena, id, lists.rename, .{ id, name });
}

/// Deletes a list, for good.
export fn cq_list_remove(lib: *Library, id: [*:0]const u8) c_int {
    return status(lib, removeList, .{std.mem.span(id)});
}

fn removeList(lib: *Library, arena: std.mem.Allocator, id: []const u8) !void {
    try writingList(lib, arena, id, lists.remove, .{id});
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
    try writingList(lib, arena, id, lists.setListed, .{ id, title_key, on });
}

/// Shares a list of this person's with every member.
export fn cq_list_share(lib: *Library, id: [*:0]const u8) c_int {
    return status(lib, shareList, .{std.mem.span(id)});
}

fn shareList(lib: *Library, arena: std.mem.Allocator, id: []const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    try lists.share(lib.io(), try lib.main(), arena, lib.now(), id);
}

/// Makes a shared list of this person's theirs alone again.
export fn cq_list_stop_sharing(lib: *Library, id: [*:0]const u8) c_int {
    return status(lib, stopSharing, .{std.mem.span(id)});
}

fn stopSharing(lib: *Library, arena: std.mem.Allocator, id: []const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    try lists.stopSharing(lib.io(), try lib.main(), arena, lib.now(), id);
}

/// Runs `f(replica, arena, now, args...)` to change the list `id`: a shared
/// one's changes are public, so holding the writer; a private one's, as
/// other private writes.
fn writingList(lib: *Library, arena: std.mem.Allocator, id: []const u8, comptime f: anytype, args: anytype) !void {
    if (try lists.isShared(try lib.main(), arena, id)) return capi.writing(lib, arena, f, args);
    return capi.writingPrivate(lib, arena, f, args);
}
