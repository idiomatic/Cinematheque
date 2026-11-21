//! A person's lists of titles (a Watchlist, Favorites), private as their
//! progress is: `p/<person>/lists`, a field per list's ID naming it (empty
//! once deleted, for good), and each list's titles at
//! `p/<person>/list/<id>`, a field per movie's title key or season's tile
//! (`<title key>#<season>`), `1` while on it; or, for a title not in the
//! library yet (a placeholder, wanted), `w<TAB>name<TAB>note`, keyed as
//! its file will be once it comes, so it's on the list as it arrives, with
//! no backfilling (devices too old to know placeholders show only `1`s).
//! The Watchlist, the first, is
//! a list like any other, but keeps its titles where they always were
//! (`p/<person>/watchlist`), so devices too old to know lists still show
//! it, and is named "Watchlist" until renamed.

const std = @import("std");
const Io = std.Io;
const Replica = @import("replica.zig").Replica;
const library = @import("library.zig");

pub const watchlist_id = "watchlist";

/// A name's most bytes: a list's name is a word or two.
const max_name = 200;
/// A placeholder's note's most bytes: a line, or an article's address.
const max_note = 1000;

pub const List = struct {
    id: []const u8,
    name: []const u8,
    /// Movies' title keys and seasons' tiles, in key order, placeholders'
    /// too.
    titles: []const []const u8,
    /// The placeholders among them, titles not in the library when put on
    /// it: their keys, names as typed, and notes.
    wanted: []const Wanted = &.{},
};

pub const Wanted = struct {
    key: []const u8,
    name: []const u8,
    note: []const u8,
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
    for (out.items) |*l| {
        const on = try titles(replica, arena, l.id);
        l.titles = on.titles;
        l.wanted = on.wanted;
    }
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

/// Puts a title not in the library yet on a list, as a placeholder: a
/// movie, or a series' season (the first, unless another's given), by its
/// name and year as its file will have them, so it's there as it arrives;
/// returns its key.
pub fn want(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, id: []const u8, series: bool, name: []const u8, year: ?u16, season: ?u16, note: []const u8) ![]const u8 {
    _ = try existing(replica, arena, id);
    const n = try checkName(name);
    const normalized = try library.normalize(arena, n);
    if (normalized.len == 0) return error.InvalidArgument;
    const t = std.mem.trim(u8, note, " \t\r\n");
    if (t.len > max_note or !std.unicode.utf8ValidateSlice(t)) return error.InvalidArgument;
    for (t) |c| if (c < 0x20 or c == 0x7f) return error.InvalidArgument;
    const y = if (year) |v| try std.fmt.allocPrint(arena, "{d}", .{v}) else "-";
    const title = try std.fmt.allocPrint(arena, "t/{c}/{s}/{s}", .{ @as(u8, if (series) 's' else 'm'), normalized, y });
    const k = if (series) try std.fmt.allocPrint(arena, "{s}#{d}", .{ title, season orelse 1 }) else title;
    try replica.writePrivate(wall_ms, try key(replica, arena, id), &.{.{ k, try std.fmt.allocPrint(arena, "w\t{s}\t{s}", .{ n, t }) }});
    return k;
}

/// A placeholder's fields, as the apps and the web client send them.
pub const WantJson = struct {
    /// "movie" or "series".
    kind: []const u8,
    name: []const u8,
    year: ?u16 = null,
    /// A series' season, the first unless given.
    season: ?u16 = null,
    note: []const u8 = "",
};

pub fn wantJson(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, id: []const u8, w: WantJson) ![]const u8 {
    return want(replica, arena, wall_ms, id, std.mem.eql(u8, w.kind, "series"), w.name, w.year, w.season, w.note);
}

fn existing(replica: *Replica, arena: std.mem.Allocator, id: []const u8) !List {
    for (try lists(replica, arena)) |l| if (std.mem.eql(u8, l.id, id)) return l;
    return error.NotFound;
}

fn titles(replica: *Replica, arena: std.mem.Allocator, id: []const u8) !struct { titles: []const []const u8, wanted: []const Wanted } {
    var out: std.ArrayList([]const u8) = .empty;
    var wanted: std.ArrayList(Wanted) = .empty;
    const s = try replica.db.prepare("SELECT field, value FROM winners WHERE key = ?1 AND length(value) > 0 ORDER BY field");
    defer s.finalize();
    try s.bindText(1, try key(replica, arena, id));
    while (try s.step()) {
        const field = try arena.dupe(u8, s.blob(0));
        const value = s.blob(1);
        if (std.mem.eql(u8, value, "1")) {
            try out.append(arena, field);
        } else if (std.mem.startsWith(u8, value, "w\t")) {
            var parts = std.mem.splitScalar(u8, value[2..], '\t');
            try out.append(arena, field);
            try wanted.append(arena, .{ .key = field, .name = try arena.dupe(u8, parts.first()), .note = try arena.dupe(u8, parts.next() orelse "") });
        }
    }
    return .{ .titles = out.items, .wanted = wanted.items };
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

test "a placeholder is keyed as its file will be, so it's on the list as it arrives" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const founder = (try @import("replica.zig").personKeyPair(@splat(1))).public_key.toBytes();
    var r = try Replica.open(std.testing.allocator, std.testing.io, ":memory:", founder, .from(@splat(1)));
    defer r.close();
    const movie = try want(&r, arena, 1, watchlist_id, false, "Dune: Part Three", 2026, null, "https://example.com/dune");
    // As the file `Dune Part Three (2026).m4v` will be keyed.
    var scratch: [256]u8 = undefined;
    try std.testing.expectEqualStrings((try library.keys(arena, @import("naming.zig").parse("Dune Part Three (2026).m4v", &scratch))).title, movie);
    try std.testing.expectEqualStrings("t/s/the-chair/-#1", try want(&r, arena, 2, watchlist_id, true, "The Chair", null, null, ""));
    const l = (try lists(&r, arena))[0];
    try std.testing.expectEqual(@as(usize, 2), l.titles.len);
    try std.testing.expectEqual(@as(usize, 2), l.wanted.len);
    try std.testing.expectEqualStrings("Dune: Part Three", l.wanted[0].name);
    try std.testing.expectEqualStrings("https://example.com/dune", l.wanted[0].note);
    // Taken off as any title is.
    try setListed(&r, arena, 3, watchlist_id, movie, false);
    try std.testing.expectEqual(@as(usize, 1), (try lists(&r, arena))[0].wanted.len);
    try std.testing.expectError(error.InvalidArgument, want(&r, arena, 4, watchlist_id, false, "...", null, null, ""));
    try std.testing.expectError(error.InvalidArgument, want(&r, arena, 4, watchlist_id, false, "Alien", 1979, null, "a\nb"));
}
