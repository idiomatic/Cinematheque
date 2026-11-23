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
//!
//! A list shared with every member moves its titles to a public key of its
//! own, `l/<owner>/<id>`, beside its `name`, which other devices admit only
//! from its owner's devices; its owner's private index still names it. Its
//! mode is a log of changes (`mode:<random>`, `shared` or `private`, each
//! written once), the latest-written current, so a mode as of any write's
//! clock can be told however they arrive (for lists all members change,
//! to come). Made private again, its titles go back, and the public copy
//! is emptied: other devices hold what they received, so unsharing hides a
//! list, it doesn't recall it. Devices too old to know shared lists show
//! one shared as empty.

const std = @import("std");
const Io = std.Io;
const replica_ = @import("replica.zig");
const Replica = replica_.Replica;
const library = @import("library.zig");

pub const watchlist_id = "watchlist";

/// A name's most bytes: a list's name is a word or two.
const max_name = 200;
/// A placeholder's note's most bytes: a line, or an article's address.
const max_note = 1000;

pub const List = struct {
    /// Its ID; another member's, `<owner>/<id>`, as each person has a
    /// Watchlist.
    id: []const u8,
    name: []const u8,
    /// Its owner's person key, in hex.
    owner: []const u8,
    /// Another member's name, as everyone sees it, if set.
    ownerName: []const u8 = "",
    /// Whether it's this person's own, which only they change.
    mine: bool = true,
    /// Whether it's its owner's alone, or every member sees it.
    mode: Mode = .private,
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

/// Who sees a list: its owner alone, or every member, as its mode's log
/// names it (`private`, `shared`).
pub const Mode = enum { private, shared };

/// This person's lists, then other members' shared ones, each by name.
pub fn lists(replica: *Replica, arena: std.mem.Allocator) ![]const List {
    var out: std.ArrayList(List) = .empty;
    const me = try arena.dupe(u8, &std.fmt.bytesToHex(replica.personKey(), .lower));
    var named_watchlist = false;
    const s = try replica.db.prepare("SELECT field, value FROM winners WHERE key = ?1");
    defer s.finalize();
    try s.bindText(1, try key(replica, arena, null));
    while (try s.step()) {
        const id = try arena.dupe(u8, s.blob(0));
        if (std.mem.eql(u8, id, watchlist_id)) named_watchlist = true;
        if (s.blob(1).len == 0 or !validId(id)) continue;
        try out.append(arena, .{ .id = id, .name = try arena.dupe(u8, s.blob(1)), .owner = me, .titles = &.{} });
    }
    if (!named_watchlist) try out.append(arena, .{ .id = watchlist_id, .name = "Watchlist", .owner = me, .titles = &.{} });
    for (out.items) |*l| {
        l.mode = try modeOf(replica, try public(arena, me, l.id));
        const on = try titles(replica, arena, switch (l.mode) {
            .private => try key(replica, arena, l.id),
            .shared => try public(arena, me, l.id),
        });
        l.titles = on.titles;
        l.wanted = on.wanted;
    }
    sort(out.items);
    const mine = out.items.len;
    try others(replica, arena, me, &out);
    sort(out.items[mine..]);
    return out.items;
}

fn sort(items: []List) void {
    std.mem.sort(List, items, {}, struct {
        fn less(_: void, a: List, b: List) bool {
            return std.ascii.lessThanIgnoreCase(a.name, b.name) or (std.ascii.eqlIgnoreCase(a.name, b.name) and std.mem.lessThan(u8, a.id, b.id));
        }
    }.less);
}

/// Other members' shared lists, named.
fn others(replica: *Replica, arena: std.mem.Allocator, me: []const u8, out: *std.ArrayList(List)) !void {
    const members = try replica.members(arena);
    const names = try library.names(replica, arena);
    const s = try replica.db.prepare("SELECT value, key FROM winners WHERE key >= 'l/' AND key < 'l0' AND field = 'name' AND length(value) > 0");
    defer s.finalize();
    while (try s.step()) {
        const k = try arena.dupe(u8, s.blob(1));
        const parsed = parsePublic(k) orelse continue;
        if (std.mem.eql(u8, parsed.owner, me)) continue;
        const owner = replica_.parseHex(parsed.owner) orelse continue;
        for (members) |m| {
            if (std.mem.eql(u8, &m, &owner)) break;
        } else continue;
        if (try modeOf(replica, k) != .shared) continue;
        const on = try titles(replica, arena, k);
        try out.append(arena, .{
            .id = k[2..],
            .name = try arena.dupe(u8, s.blob(0)),
            .owner = parsed.owner,
            .ownerName = library.nameOf(names, parsed.owner) orelse "",
            .mine = false,
            .mode = .shared,
            .titles = on.titles,
            .wanted = on.wanted,
        });
    }
}

/// Shares a list of this person's with every member.
pub fn share(io: Io, replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, id: []const u8) !void {
    const list = try own(replica, arena, id);
    if (list.mode == .shared) return;
    const public_key = try public(arena, list.owner, id);
    const private_key = try key(replica, arena, id);
    // Its titles to the public key first, then off the private one, so a
    // failure between leaves them in both, not neither.
    const moved = try entries(replica, arena, private_key);
    try writePublic(replica, wall_ms, public_key, &.{ .{ "name", list.name }, .{ try newMode(io, arena), @tagName(Mode.shared) } }, moved);
    try writePrivate(replica, wall_ms, private_key, try emptied(arena, moved));
}

/// Makes a shared list its owner's alone again: its titles back to its
/// private key first, then off the public one, emptied (hiding it, not
/// recalling what other devices hold).
pub fn stopSharing(io: Io, replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, id: []const u8) !void {
    const list = try own(replica, arena, id);
    if (list.mode == .private) return;
    const public_key = try public(arena, list.owner, id);
    const private_key = try key(replica, arena, id);
    const moved = try entries(replica, arena, public_key);
    try writePrivate(replica, wall_ms, private_key, moved);
    try writePublic(replica, wall_ms, public_key, &.{ .{ "name", "" }, .{ try newMode(io, arena), @tagName(Mode.private) } }, try emptied(arena, moved));
}

/// A field of the mode's log, written once: `mode:` and a random suffix.
fn newMode(io: Io, arena: std.mem.Allocator) ![]const u8 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    return std.fmt.allocPrint(arena, "mode:{s}", .{std.fmt.bytesToHex(bytes, .lower)});
}

/// A list's public key's latest mode; private if it has none.
fn modeOf(replica: *Replica, public_key: []const u8) !Mode {
    const s = try replica.db.prepare(
        \\SELECT value FROM winners WHERE key = ?1 AND field >= 'mode:' AND field < 'mode;'
        \\  ORDER BY hlc DESC, field DESC LIMIT 1
    );
    defer s.finalize();
    try s.bindText(1, public_key);
    if (!try s.step()) return .private;
    // Admission takes no other (see `validPublicField`).
    return std.meta.stringToEnum(Mode, s.blob(0)) orelse error.Malformed;
}

/// A key's titles' fields and values, placeholders' too.
fn entries(replica: *Replica, arena: std.mem.Allocator, k: []const u8) ![]const [2][]const u8 {
    var out: std.ArrayList([2][]const u8) = .empty;
    const s = try replica.db.prepare("SELECT field, value FROM winners WHERE key = ?1 AND field >= 't/' AND field < 't0' AND length(value) > 0");
    defer s.finalize();
    try s.bindText(1, k);
    while (try s.step()) try out.append(arena, .{ try arena.dupe(u8, s.blob(0)), try arena.dupe(u8, s.blob(1)) });
    return out.items;
}

fn emptied(arena: std.mem.Allocator, fields: []const [2][]const u8) ![]const [2][]const u8 {
    const out = try arena.alloc([2][]const u8, fields.len);
    for (fields, out) |f, *o| o.* = .{ f[0], "" };
    return out;
}

/// Writes `fields` of a private key, in batches, as a write takes at most
/// so many.
fn writePrivate(replica: *Replica, wall_ms: u64, k: []const u8, fields: []const [2][]const u8) !void {
    var at: usize = 0;
    while (at < fields.len) : (at += 512) try replica.writePrivate(wall_ms, k, fields[at..@min(at + 512, fields.len)]);
}

/// Writes `first`, then `fields`, of a public key, together.
fn writePublic(replica: *Replica, wall_ms: u64, k: []const u8, first: []const [2][]const u8, fields: []const [2][]const u8) !void {
    try replica.begin();
    errdefer replica.rollback();
    for (first) |f| try replica.write(wall_ms, k, f[0], f[1]);
    for (fields) |f| try replica.write(wall_ms, k, f[0], f[1]);
    try replica.commit();
}

/// Writes fields of a list's titles, where they are.
fn writeTitles(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, list: List, fields: []const [2][]const u8) !void {
    if (list.mode == .shared)
        try writePublic(replica, wall_ms, try public(arena, list.owner, list.id), &.{}, fields)
    else
        try writePrivate(replica, wall_ms, try key(replica, arena, list.id), fields);
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
    const list = try own(replica, arena, id);
    try replica.writePrivate(wall_ms, try key(replica, arena, null), &.{.{ id, n }});
    if (list.mode == .shared) try writePublic(replica, wall_ms, try public(arena, list.owner, id), &.{.{ "name", n }}, &.{});
}

/// Deletes a list, for good: its name emptied, so no device brings it
/// back, and its titles taken off it.
pub fn remove(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, id: []const u8) !void {
    const list = try own(replica, arena, id);
    try replica.writePrivate(wall_ms, try key(replica, arena, null), &.{.{ id, "" }});
    var off: std.ArrayList([2][]const u8) = .empty;
    for (list.titles) |t| try off.append(arena, .{ t, "" });
    // A shared one's name emptied too, so other members' devices drop it.
    if (list.mode == .shared)
        try writePublic(replica, wall_ms, try public(arena, list.owner, id), &.{.{ "name", "" }}, off.items)
    else
        try writePrivate(replica, wall_ms, try key(replica, arena, id), off.items);
}

/// Puts a movie (its title key) or a season (`<title key>#<season>`) on a
/// list, or takes it off.
pub fn setListed(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, id: []const u8, title: []const u8, on: bool) !void {
    const list = try own(replica, arena, id);
    if (title.len == 0 or title.len > 1024 or !std.mem.startsWith(u8, title, "t/")) return error.InvalidArgument;
    try writeTitles(replica, arena, wall_ms, list, &.{.{ title, if (on) "1" else "" }});
}

/// Puts a title not in the library yet on a list, as a placeholder: a
/// movie, or a series' season (the first, unless another's given), by its
/// name and year as its file will have them, so it's there as it arrives;
/// returns its key.
pub fn want(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, id: []const u8, w: WantJson) ![]const u8 {
    const list = try own(replica, arena, id);
    const k, const value = try wanting(arena, w);
    try writeTitles(replica, arena, wall_ms, list, &.{.{ k, value }});
    return k;
}

/// Changes a placeholder on a list (its name, year, season, or note), in
/// one change: keyed by its name and year (and season), the old one is
/// taken off as the new one goes on, unless they're keyed alike. Returns
/// its key.
pub fn editWant(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, id: []const u8, old: []const u8, w: WantJson) ![]const u8 {
    const list = try own(replica, arena, id);
    for (list.wanted) |had| {
        if (!std.mem.eql(u8, had.key, old)) continue;
        const k, const value = try wanting(arena, w);
        if (std.mem.eql(u8, k, old))
            try writeTitles(replica, arena, wall_ms, list, &.{.{ k, value }})
        else
            try writeTitles(replica, arena, wall_ms, list, &.{ .{ old, "" }, .{ k, value } });
        return k;
    }
    return error.NotFound;
}

/// A placeholder's key, as its file will be keyed (a movie by its title, a
/// series by season, as players list them), and its value on a list.
fn wanting(arena: std.mem.Allocator, w: WantJson) !struct { []const u8, []const u8 } {
    const n = try checkName(w.name);
    const normalized = try library.normalize(arena, n);
    if (normalized.len == 0) return error.InvalidArgument;
    const t = std.mem.trim(u8, w.note, " \t\r\n");
    if (t.len > max_note or !std.unicode.utf8ValidateSlice(t)) return error.InvalidArgument;
    for (t) |c| if (c < 0x20 or c == 0x7f) return error.InvalidArgument;
    const y = if (w.year) |v| try std.fmt.allocPrint(arena, "{d}", .{v}) else "-";
    const title = try std.fmt.allocPrint(arena, "t/{c}/{s}/{s}", .{ @backingInt(w.kind), normalized, y });
    const k = switch (w.kind) {
        .movie => title,
        .series => try std.fmt.allocPrint(arena, "{s}#{d}", .{ title, w.season orelse 1 }),
    };
    return .{ k, try std.fmt.allocPrint(arena, "w\t{s}\t{s}", .{ n, t }) };
}

/// A placeholder's fields, as the apps and the web client send them.
pub const WantJson = struct {
    /// `movie` or `series`; any other is refused.
    kind: library.TitleKind,
    name: []const u8,
    year: ?u16 = null,
    /// A series' season, the first unless given.
    season: ?u16 = null,
    note: []const u8 = "",
};

/// One of this person's own lists, which only they change.
fn own(replica: *Replica, arena: std.mem.Allocator, id: []const u8) !List {
    for (try lists(replica, arena)) |l| if (l.mine and std.mem.eql(u8, l.id, id)) return l;
    return error.NotFound;
}

/// Whether a list of this person's is shared, as changing it then writes
/// to the device's public stream.
pub fn isShared(replica: *Replica, arena: std.mem.Allocator, id: []const u8) !bool {
    return (try own(replica, arena, id)).mode == .shared;
}

/// The titles at a list's key, private or public.
fn titles(replica: *Replica, arena: std.mem.Allocator, k: []const u8) !struct { titles: []const []const u8, wanted: []const Wanted } {
    var out: std.ArrayList([]const u8) = .empty;
    var wanted: std.ArrayList(Wanted) = .empty;
    const s = try replica.db.prepare("SELECT field, value FROM winners WHERE key = ?1 AND field >= 't/' AND field < 't0' AND length(value) > 0 ORDER BY field");
    defer s.finalize();
    try s.bindText(1, k);
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

/// A shared list's public key.
fn public(arena: std.mem.Allocator, owner: []const u8, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "l/{s}/{s}", .{ owner, id });
}

/// A public list key's owner (64 hex digits) and ID, if it's well formed.
pub fn parsePublic(k: []const u8) ?struct { owner: []const u8, id: []const u8 } {
    if (k.len < 2 + 64 + 2 or !std.mem.startsWith(u8, k, "l/") or k[66] != '/') return null;
    const owner = k[2..66];
    for (owner) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return null;
    const id = k[67..];
    return if (validId(id)) .{ .owner = owner, .id = id } else null;
}

/// Whether a field of a public list key is one a list has: its `name`, a
/// change of its mode (`mode:` and 16 hex digits, `shared` or `private`),
/// or a title.
pub fn validPublicField(field: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, field, "name")) return value.len <= max_name;
    if (std.mem.startsWith(u8, field, "mode:")) {
        if (field.len != 5 + 16) return false;
        for (field[5..]) |c| if (!std.ascii.isHex(c)) return false;
        return std.meta.stringToEnum(Mode, value) != null;
    }
    return std.mem.startsWith(u8, field, "t/");
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
    const movie = try want(&r, arena, 1, watchlist_id, .{ .kind = .movie, .name = "Dune: Part Three", .year = 2026, .note = "https://example.com/dune" });
    // As the file `Dune Part Three (2026).m4v` will be keyed.
    var scratch: [256]u8 = undefined;
    try std.testing.expectEqualStrings((try library.keys(arena, @import("naming.zig").parse("Dune Part Three (2026).m4v", &scratch))).title, movie);
    try std.testing.expectEqualStrings("t/s/the-chair/-#1", try want(&r, arena, 2, watchlist_id, .{ .kind = .series, .name = "The Chair" }));
    const l = (try lists(&r, arena))[0];
    try std.testing.expectEqual(@as(usize, 2), l.titles.len);
    try std.testing.expectEqual(@as(usize, 2), l.wanted.len);
    try std.testing.expectEqualStrings("Dune: Part Three", l.wanted[0].name);
    try std.testing.expectEqualStrings("https://example.com/dune", l.wanted[0].note);
    // Taken off as any title is.
    try setListed(&r, arena, 3, watchlist_id, movie, false);
    try std.testing.expectEqual(@as(usize, 1), (try lists(&r, arena))[0].wanted.len);
    try std.testing.expectError(error.InvalidArgument, want(&r, arena, 4, watchlist_id, .{ .kind = .movie, .name = "..." }));
    try std.testing.expectError(error.InvalidArgument, want(&r, arena, 4, watchlist_id, .{ .kind = .movie, .name = "Alien", .year = 1979, .note = "a\nb" }));
}

test "a placeholder changed is keyed afresh, the old one taken off in the same change" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const founder = (try replica_.personKeyPair(@splat(1))).public_key.toBytes();
    var r = try Replica.open(std.testing.allocator, std.testing.io, ":memory:", founder, .from(@splat(1)));
    defer r.close();
    const old = try want(&r, arena, 1, watchlist_id, .{ .kind = .movie, .name = "Dune Part Three" });
    // Its year added: keyed as its file will be, alone on the list.
    const new = try editWant(&r, arena, 2, watchlist_id, old, .{ .kind = .movie, .name = "Dune: Part Three", .year = 2026, .note = "soon" });
    try std.testing.expectEqualStrings("t/m/dune-part-three/2026", new);
    var l = (try lists(&r, arena))[0];
    try std.testing.expectEqual(@as(usize, 1), l.wanted.len);
    try std.testing.expectEqualStrings(new, l.wanted[0].key);
    try std.testing.expectEqualStrings("Dune: Part Three", l.wanted[0].name);
    // Only its note changed: the same key.
    try std.testing.expectEqualStrings(new, try editWant(&r, arena, 3, watchlist_id, new, .{ .kind = .movie, .name = "Dune: Part Three", .year = 2026, .note = "later" }));
    l = (try lists(&r, arena))[0];
    try std.testing.expectEqualStrings("later", l.wanted[0].note);
    // One not on the list, or a title not a placeholder, isn't changed.
    try std.testing.expectError(error.NotFound, editWant(&r, arena, 4, watchlist_id, old, .{ .kind = .movie, .name = "Dune" }));
    try setListed(&r, arena, 5, watchlist_id, "t/m/alien/1979", true);
    try std.testing.expectError(error.NotFound, editWant(&r, arena, 6, watchlist_id, "t/m/alien/1979", .{ .kind = .movie, .name = "Aliens" }));
}

test "a list shared keeps its titles, renamed and changed where they are" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const founder = (try replica_.personKeyPair(@splat(1))).public_key.toBytes();
    var r = try Replica.open(std.testing.allocator, std.testing.io, ":memory:", founder, .from(@splat(1)));
    defer r.close();
    try setListed(&r, arena, 1, watchlist_id, "t/m/alien/1979", true);
    try share(std.testing.io, &r, arena, 2, watchlist_id);
    var l = (try lists(&r, arena))[0];
    try std.testing.expectEqual(Mode.shared, l.mode);
    try std.testing.expectEqualStrings("t/m/alien/1979", l.titles[0]);
    // Its private copy emptied, its titles public.
    try std.testing.expectEqual(@as(usize, 0), (try entries(&r, arena, try key(&r, arena, watchlist_id))).len);
    try setListed(&r, arena, 3, watchlist_id, "t/m/heat/1995", true);
    try rename(&r, arena, 4, watchlist_id, "Ours");
    l = (try lists(&r, arena))[0];
    try std.testing.expectEqual(@as(usize, 2), l.titles.len);
    try std.testing.expectEqualStrings("Ours", l.name);
    // Shared again, nothing changes; made private, its titles come back.
    try share(std.testing.io, &r, arena, 5, watchlist_id);
    try stopSharing(std.testing.io, &r, arena, 6, watchlist_id);
    l = (try lists(&r, arena))[0];
    try std.testing.expectEqual(Mode.private, l.mode);
    try std.testing.expectEqual(@as(usize, 2), l.titles.len);
    try std.testing.expectEqual(@as(usize, 0), (try entries(&r, arena, try public(arena, l.owner, watchlist_id))).len);
    // Deleted while shared, its public name's emptied too.
    try share(std.testing.io, &r, arena, 7, watchlist_id);
    try remove(&r, arena, 8, watchlist_id);
    try std.testing.expectEqual(@as(usize, 0), (try lists(&r, arena)).len);
}

test "a placeholder's kind is one the library knows, or refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const series = try std.json.parseFromSliceLeaky(WantJson, arena, "{\"kind\":\"series\",\"name\":\"The Chair\"}", .{});
    try std.testing.expectEqual(library.TitleKind.series, series.kind);
    try std.testing.expectError(error.InvalidEnumTag, std.json.parseFromSliceLeaky(WantJson, arena, "{\"kind\":\"album\",\"name\":\"Kid A\"}", .{}));
}
