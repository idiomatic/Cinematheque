//! A person's lists of titles (a Watchlist, Favorites), private as their
//! progress is: `p/<person>/lists`, a field per list's ID naming it (empty
//! once deleted, for good), and each list's titles at
//! `p/<person>/list/<id>`, a field per movie's title key or season's tile
//! (`<title key>#<season>`), `1` while on it. The Watchlist, the first, is
//! a list like any other, but keeps its titles where they always were
//! (`p/<person>/watchlist`), so devices too old to know lists still show
//! it, and is named "Watchlist" until renamed.

const std = @import("std");
const Io = std.Io;
const Replica = @import("replica.zig").Replica;

pub const watchlist_id = "watchlist";

/// A name's most bytes: a list's name is a word or two.
const max_name = 200;

pub const List = struct {
    id: []const u8,
    name: []const u8,
    /// Movies' title keys and seasons' tiles, in key order.
    titles: []const []const u8,
};

/// This person's lists, by name.
pub fn lists(replica: *Replica, arena: std.mem.Allocator) ![]const List {
    var out: std.ArrayList(List) = .empty;
    var named_watchlist = false;
    const s = try replica.db.prepare("SELECT field, value FROM winners WHERE key = ?1");
    defer s.finalize();
    try s.bindText(1, try key(replica, arena, null));
    while (try s.step()) {
        const id = try arena.dupe(u8, s.blob(0));
        if (std.mem.eql(u8, id, watchlist_id)) named_watchlist = true;
        if (s.blob(1).len == 0 or !validId(id)) continue;
        try out.append(arena, .{ .id = id, .name = try arena.dupe(u8, s.blob(1)), .titles = &.{} });
    }
    if (!named_watchlist) try out.append(arena, .{ .id = watchlist_id, .name = "Watchlist", .titles = &.{} });
    for (out.items) |*l| l.titles = try titles(replica, arena, l.id);
    std.mem.sort(List, out.items, {}, struct {
        fn less(_: void, a: List, b: List) bool {
            return std.ascii.lessThanIgnoreCase(a.name, b.name) or (std.ascii.eqlIgnoreCase(a.name, b.name) and std.mem.lessThan(u8, a.id, b.id));
        }
    }.less);
    return out.items;
}

/// Makes a list, empty, returning its ID.
pub fn create(io: Io, replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, name: []const u8) ![]const u8 {
    const n = try checkName(name);
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    const id = try arena.dupe(u8, &std.fmt.bytesToHex(bytes, .lower));
    try replica.writePrivate(wall_ms, try key(replica, arena, null), &.{.{ id, n }});
    return id;
}

pub fn rename(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, id: []const u8, name: []const u8) !void {
    const n = try checkName(name);
    _ = try existing(replica, arena, id);
    try replica.writePrivate(wall_ms, try key(replica, arena, null), &.{.{ id, n }});
}

/// Deletes a list, for good: its name emptied, so no device brings it
/// back, and its titles taken off it.
pub fn remove(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, id: []const u8) !void {
    const list = try existing(replica, arena, id);
    try replica.writePrivate(wall_ms, try key(replica, arena, null), &.{.{ id, "" }});
    var off: std.ArrayList([2][]const u8) = .empty;
    for (list.titles) |t| try off.append(arena, .{ t, "" });
    // In batches, as a write takes at most so many fields.
    var at: usize = 0;
    while (at < off.items.len) : (at += 512) try replica.writePrivate(wall_ms, try key(replica, arena, id), off.items[at..@min(at + 512, off.items.len)]);
}

/// Puts a movie (its title key) or a season (`<title key>#<season>`) on a
/// list, or takes it off.
pub fn setListed(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, id: []const u8, title: []const u8, on: bool) !void {
    _ = try existing(replica, arena, id);
    if (title.len == 0 or title.len > 1024 or !std.mem.startsWith(u8, title, "t/")) return error.InvalidArgument;
    try replica.writePrivate(wall_ms, try key(replica, arena, id), &.{.{ title, if (on) "1" else "" }});
}

fn existing(replica: *Replica, arena: std.mem.Allocator, id: []const u8) !List {
    for (try lists(replica, arena)) |l| if (std.mem.eql(u8, l.id, id)) return l;
    return error.NotFound;
}

fn titles(replica: *Replica, arena: std.mem.Allocator, id: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const s = try replica.db.prepare("SELECT field FROM winners WHERE key = ?1 AND value = CAST('1' AS BLOB) ORDER BY field");
    defer s.finalize();
    try s.bindText(1, try key(replica, arena, id));
    while (try s.step()) try out.append(arena, try arena.dupe(u8, s.blob(0)));
    return out.items;
}

/// The lists' names' key (no `id`), or a list's titles'.
fn key(replica: *Replica, arena: std.mem.Allocator, id: ?[]const u8) ![]const u8 {
    const person = std.fmt.bytesToHex(replica.personKey(), .lower);
    const list = id orelse return std.fmt.allocPrint(arena, "p/{s}/lists", .{person});
    if (std.mem.eql(u8, list, watchlist_id)) return std.fmt.allocPrint(arena, "p/{s}/watchlist", .{person});
    return std.fmt.allocPrint(arena, "p/{s}/list/{s}", .{ person, list });
}

/// An ID this code makes (16 hex digits), or the Watchlist's: none from
/// another device can name a key of another kind.
fn validId(id: []const u8) bool {
    if (std.mem.eql(u8, id, watchlist_id)) return true;
    if (id.len != 16) return false;
    for (id) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn checkName(name: []const u8) ![]const u8 {
    const n = std.mem.trim(u8, name, " \t\r\n");
    if (n.len == 0 or n.len > max_name or !std.unicode.utf8ValidateSlice(n)) return error.InvalidArgument;
    for (n) |c| if (c < 0x20 or c == 0x7f) return error.InvalidArgument;
    return n;
}

test "lists: the Watchlist first, then made, renamed, listed, and deleted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const founder = (try @import("replica.zig").personKeyPair(@splat(1))).public_key.toBytes();
    var r = try Replica.open(std.testing.allocator, std.testing.io, ":memory:", founder, .from(@splat(1)));
    defer r.close();

    // The Watchlist, unnamed, is there from the start.
    try std.testing.expectEqual(@as(usize, 1), (try lists(&r, arena)).len);
    try setListed(&r, arena, 1, watchlist_id, "t/m/alien/1979", true);
    const favorites = try create(std.testing.io, &r, arena, 2, "  Favorites ");
    try setListed(&r, arena, 3, favorites, "t/s/firefly/-#1", true);
    var all = try lists(&r, arena);
    try std.testing.expectEqualStrings("Favorites", all[0].name);
    try std.testing.expectEqualStrings("t/s/firefly/-#1", all[0].titles[0]);
    try std.testing.expectEqualStrings("Watchlist", all[1].name);
    try std.testing.expectEqualStrings("t/m/alien/1979", all[1].titles[0]);

    // The Watchlist renamed keeps its titles; deleted, it's gone for good.
    try rename(&r, arena, 4, watchlist_id, "To Watch");
    all = try lists(&r, arena);
    try std.testing.expectEqualStrings("To Watch", all[1].name);
    try std.testing.expectEqual(@as(usize, 1), all[1].titles.len);
    try remove(&r, arena, 5, watchlist_id);
    all = try lists(&r, arena);
    try std.testing.expectEqual(@as(usize, 1), all.len);
    try std.testing.expectError(error.NotFound, setListed(&r, arena, 6, watchlist_id, "t/m/alien/1979", true));

    try std.testing.expectError(error.InvalidArgument, create(std.testing.io, &r, arena, 7, "  "));
    try std.testing.expectError(error.InvalidArgument, rename(&r, arena, 7, favorites, "a\nb"));
    try std.testing.expectError(error.InvalidArgument, setListed(&r, arena, 7, favorites, "p/elsewhere", true));
}
