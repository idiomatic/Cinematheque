//! The orders shelves sort in, decided here once for every player: by
//! title, by release, by when added, by when last modified, and by when last
//! watched. Each tile
//! gets its title's place in each (a series' seasons share their series'),
//! counting from what comes first in that order's usual direction: A to Z,
//! the newest released, the latest added, the latest modified, the latest
//! watched. A title with
//! nothing to order it by (never watched, say) has no place in that order,
//! and goes last whichever way it's shown.

const std = @import("std");
const art = @import("art.zig");

pub const Order = struct {
    title: u32,
    released: ?u32,
    added: ?u32,
    modified: ?u32,
    watched: ?u32,
};

/// Each tile's places, in the tiles' order.
pub fn orders(arena: std.mem.Allocator, tiles: []const art.Tile) ![]Order {
    // The titles, each once, with what orders them: a series' seasons
    // together, added when its first was, watched when its last was.
    var titles: std.ArrayList(Title) = .empty;
    var index: std.StringHashMapUnmanaged(u32) = .empty;
    const of = try arena.alloc(u32, tiles.len);
    for (tiles, of) |t, *o| {
        const g = try index.getOrPut(arena, t.key);
        if (!g.found_existing) {
            g.value_ptr.* = @intCast(titles.items.len);
            try titles.append(arena, .{
                .key = t.key,
                .sort = try fold(arena, t.sort orelse withoutArticle(t.name)),
                .year = t.year,
                .released = date(t.released) orelse if (t.year) |y| try std.fmt.allocPrint(arena, "{d:0>4}", .{y}) else null,
            });
        }
        o.* = g.value_ptr.*;
        const title = &titles.items[o.*];
        if (t.added_ms) |a| title.added = if (title.added) |b| @min(a, b) else a;
        if (t.modified_ms) |m| title.modified = if (title.modified) |b| @max(m, b) else m;
        if (t.watched_ms) |w| title.watched = if (title.watched) |b| @max(w, b) else w;
    }

    // By title first, which breaks the others' ties.
    const ranked = try arena.alloc(u32, titles.items.len);
    for (ranked, 0..) |*r, i| r.* = @intCast(i);
    std.mem.sort(u32, ranked, titles.items, byTitle);
    for (ranked, 0..) |t, place| titles.items[t].place.title = @intCast(place);
    inline for (.{ "released", "added", "modified", "watched" }) |field| {
        std.mem.sort(u32, ranked, titles.items, latestFirst(field));
        var place: u32 = 0;
        for (ranked) |t| if (@field(titles.items[t], field) != null) {
            @field(titles.items[t].place, field) = place;
            place += 1;
        };
    }

    const out = try arena.alloc(Order, tiles.len);
    for (of, out) |t, *o| o.* = titles.items[t].place;
    return out;
}

const Title = struct {
    key: []const u8,
    sort: []const u8,
    year: ?u16,
    released: ?[]const u8,
    added: ?u64 = null,
    modified: ?u64 = null,
    watched: ?u64 = null,
    place: Order = .{ .title = 0, .released = null, .added = null, .modified = null, .watched = null },
};

fn byTitle(titles: []const Title, a: u32, b: u32) bool {
    const x = titles[a];
    const y = titles[b];
    return switch (natural(x.sort, y.sort)) {
        .lt => true,
        .gt => false,
        .eq => if ((x.year orelse 0) != (y.year orelse 0)) (x.year orelse 0) < (y.year orelse 0) else std.mem.lessThan(u8, x.key, y.key),
    };
}

/// Latest first, by `field`, ties (and titles without it) by title.
fn latestFirst(comptime field: []const u8) fn ([]const Title, u32, u32) bool {
    return struct {
        fn less(titles: []const Title, a: u32, b: u32) bool {
            const x = @field(titles[a], field);
            const y = @field(titles[b], field);
            if (x == null or y == null) {
                if (x != null) return true;
                if (y != null) return false;
            } else if (later(x.?, y.?)) |first| return first;
            return titles[a].place.title < titles[b].place.title;
        }
    }.less;
}

/// Whether `x` is later than `y`, if they differ.
fn later(x: anytype, y: @TypeOf(x)) ?bool {
    if (@TypeOf(x) == u64) return if (x == y) null else x > y;
    return switch (std.mem.order(u8, x, y)) {
        .eq => null,
        .gt => true,
        .lt => false,
    };
}

/// A release date as written (`2019-05-03T07:00:00Z`, or `2019`), its date
/// alone (`YYYY`, `YYYY-MM`, or `YYYY-MM-DD`), which sorts as text.
fn date(written: ?[]const u8) ?[]const u8 {
    const w = written orelse return null;
    var n: usize = 0;
    while (n < w.len and n < 10 and (std.ascii.isDigit(w[n]) or (w[n] == '-' and (n == 4 or n == 7)))) n += 1;
    while (n > 0 and w[n - 1] == '-') n -= 1;
    return if (n >= 4) w[0..n] else null;
}

/// A name without its leading article, as titles sort ("Thing, The").
fn withoutArticle(name: []const u8) []const u8 {
    for ([_][]const u8{ "the ", "a ", "an " }) |article| {
        if (name.len > article.len and std.ascii.startsWithIgnoreCase(name, article)) return name[article.len..];
    }
    return name;
}

/// A name as it compares: lowercase, and Latin letters without their
/// accents (`é` as `e`); other characters as they are.
fn fold(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = (std.unicode.Utf8View.init(name) catch return std.ascii.allocLowerString(arena, name)).iterator();
    while (it.nextCodepointSlice()) |slice| {
        const c = std.unicode.utf8Decode(slice) catch continue;
        const plain: u8 = if (c < 0x80) std.ascii.toLower(@intCast(c)) else if (c >= 0xC0 and c < 0x180) latin[c - 0xC0] else 0;
        if (plain != 0) try out.append(arena, plain) else try out.appendSlice(arena, slice);
    }
    return out.items;
}

/// Latin-1's and Latin Extended-A's letters (U+00C0 to U+017F) as plain
/// ones; 0 for the two that aren't letters (× and ÷).
const latin = "aaaaaaaceeeeiiiidnooooo\x00ouuuuyts" ++ "aaaaaaaceeeeiiiidnooooo\x00ouuuuyty" ++
    "aaaaaa" ++ "cccccccc" ++ "dddd" ++ "eeeeeeeeee" ++ "gggggggg" ++ "hhhh" ++ "iiiiiiiiii" ++ "ii" ++ "jj" ++ "kkk" ++
    "llllllllll" ++ "nnnnnnnnn" ++ "oooooo" ++ "oo" ++ "rrrrrr" ++ "ssssssss" ++ "tttttt" ++ "uuuuuuuuuuuu" ++ "ww" ++ "yyy" ++ "zzzzzz" ++ "s";

comptime {
    std.debug.assert(latin.len == 0x180 - 0xC0);
}

/// Folded names compared with runs of digits as numbers ("Movie 9" before
/// "Movie 10"), as Finder sorts.
fn natural(a: []const u8, b: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            const x = digits(a, &i);
            const y = digits(b, &j);
            // Without leading zeros, the longer is the larger.
            if (x.len != y.len) return std.math.order(x.len, y.len);
            const o = std.mem.order(u8, x, y);
            if (o != .eq) return o;
            continue;
        }
        if (a[i] != b[j]) return std.math.order(a[i], b[j]);
        i += 1;
        j += 1;
    }
    return std.math.order(a.len - i, b.len - j);
}

/// The digits at `at`, without leading zeros, moving `at` past them all.
fn digits(s: []const u8, at: *usize) []const u8 {
    var start = at.*;
    while (at.* < s.len and std.ascii.isDigit(s[at.*])) at.* += 1;
    while (start + 1 < at.* and s[start] == '0') start += 1;
    return s[start..at.*];
}

test "names compare without case, accents, or articles, numbers as numbers" {
    const arena = std.testing.allocator;
    var state = std.heap.ArenaAllocator.init(arena);
    defer state.deinit();
    const a = state.allocator();
    try std.testing.expectEqualStrings("amelie", try fold(a, "Amélie"));
    try std.testing.expectEqualStrings("leon", try fold(a, "LÉON"));
    try std.testing.expectEqualStrings("千と千尋", try fold(a, "千と千尋"));
    try std.testing.expectEqualStrings("Thing", withoutArticle("The Thing"));
    try std.testing.expectEqualStrings("The", withoutArticle("The"));
    try std.testing.expectEqualStrings("Anatomy", withoutArticle("Anatomy"));
    try std.testing.expectEqual(std.math.Order.lt, natural("movie 9", "movie 10"));
    try std.testing.expectEqual(std.math.Order.lt, natural("movie 09", "movie 10"));
    try std.testing.expectEqual(std.math.Order.lt, natural("alien", "aliens"));
    try std.testing.expectEqualStrings("2019-05-03", date("2019-05-03T07:00:00Z").?);
    try std.testing.expectEqualStrings("1979", date("1979").?);
    try std.testing.expectEqual(@as(?[]const u8, null), date("soon"));
}

test "titles ordered every way, a series' seasons together" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const tiles = [_]art.Tile{
        .{ .key = "t/m/thing/1982", .name = "The Thing", .year = 1982, .kind = 'm', .added_ms = 30 },
        .{ .key = "t/m/alien/1979", .name = "Alien", .year = 1979, .kind = 'm', .released = "1979-05-25", .added_ms = 10, .watched_ms = 5 },
        .{ .key = "t/s/firefly/-", .name = "Firefly", .year = null, .kind = 's', .season = 1, .released = "2002", .added_ms = 20 },
        .{ .key = "t/s/firefly/-", .name = "Firefly", .year = null, .kind = 's', .season = 2, .added_ms = 40, .watched_ms = 9 },
        .{ .key = "t/m/zulu/1964", .name = "Zulu", .year = 1964, .kind = 'm', .sort = "Aardvark", .modified_ms = 50 },
    };
    const o = try orders(a, &tiles);
    // By title: Aardvark (Zulu's sort name), Alien, Firefly, Thing.
    try std.testing.expectEqual(@as(u32, 3), o[0].title);
    try std.testing.expectEqual(@as(u32, 1), o[1].title);
    try std.testing.expectEqual(o[2].title, o[3].title);
    try std.testing.expectEqual(@as(u32, 0), o[4].title);
    // Released: Firefly 2002, The Thing (1982, its year), Alien 1979, Zulu 1964.
    try std.testing.expectEqual(@as(?u32, 0), o[2].released);
    try std.testing.expectEqual(@as(?u32, 1), o[0].released);
    try std.testing.expectEqual(@as(?u32, 2), o[1].released);
    try std.testing.expectEqual(@as(?u32, 3), o[4].released);
    // Added: The Thing 30, Firefly (its first season, 20), Alien 10; Zulu never.
    try std.testing.expectEqual(@as(?u32, 0), o[0].added);
    try std.testing.expectEqual(@as(?u32, 1), o[3].added);
    try std.testing.expectEqual(@as(?u32, 2), o[1].added);
    try std.testing.expectEqual(@as(?u32, null), o[4].added);
    // Watched: Firefly (its last, 9), Alien 5; the rest never.
    try std.testing.expectEqual(@as(?u32, 0), o[2].watched);
    try std.testing.expectEqual(@as(?u32, 1), o[1].watched);
    try std.testing.expectEqual(@as(?u32, null), o[0].watched);
    // Modified: Zulu alone has a time.
    try std.testing.expectEqual(@as(?u32, 0), o[4].modified);
    try std.testing.expectEqual(@as(?u32, null), o[1].modified);
}
