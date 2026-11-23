//! The review of a library's titles: close matches (a year off, a spelling,
//! diacritics) and duplicates, for a person to resolve, and the aliases
//! that resolve them, two keys of one title (`aliases`; see
//! [library.zig](library.zig)).

const std = @import("std");
const Replica = @import("replica.zig").Replica;
const library = @import("library.zig");
const Title = library.Title;
const fold = library.fold;

pub const Match = struct {
    a: []const u8,
    b: []const u8,
    reason: []const u8,
};

/// Pairs of titles whose keys nearly agree: the same title with a year off
/// by one, with transposed digits, or missing; or the same year with a
/// title spelled slightly differently, or differing only in diacritics.
pub fn closeMatches(arena: std.mem.Allocator, all: []const Title) ![]Match {
    const Info = struct { t: *const Title, norm: []const u8, folded: []const u8 };
    var infos: std.ArrayList(Info) = .empty;
    for (all) |*t| {
        // Titles aliased already, or held by no source (e.g., one
        // dropped), aren't for review.
        if (t.alias != null or t.qualities == 0) continue;
        const parts = std.mem.splitScalar(u8, t.key, '/');
        var it = parts;
        _ = it.next();
        _ = it.next();
        const norm = it.next() orelse continue;
        try infos.append(arena, .{ .t = t, .norm = norm, .folded = try fold(arena, norm) });
    }
    var by_folded: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty;
    var by_year: std.AutoHashMapUnmanaged(u32, std.ArrayList(usize)) = .empty;
    for (infos.items, 0..) |info, i| {
        const f = try by_folded.getOrPut(arena, info.folded);
        if (!f.found_existing) f.value_ptr.* = .empty;
        try f.value_ptr.append(arena, i);
        const y = try by_year.getOrPut(arena, (@as(u32, @backingInt(info.t.kind)) << 16) | (info.t.year orelse 0));
        if (!y.found_existing) y.value_ptr.* = .empty;
        try y.value_ptr.append(arena, i);
    }
    var out: std.ArrayList(Match) = .empty;
    var fit = by_folded.valueIterator();
    while (fit.next()) |group| for (group.items, 0..) |i, n| for (group.items[n + 1 ..]) |j| {
        const a = infos.items[i];
        const b = infos.items[j];
        if (a.t.kind != b.t.kind) continue;
        const reason = if (!std.mem.eql(u8, a.norm, b.norm) and a.t.year == b.t.year)
            "diacritics"
        else
            yearReason(a.t.year, b.t.year) orelse continue;
        try out.append(arena, .{ .a = a.t.key, .b = b.t.key, .reason = reason });
    };
    var yit = by_year.valueIterator();
    while (yit.next()) |group| for (group.items, 0..) |i, n| for (group.items[n + 1 ..]) |j| {
        const a = infos.items[i];
        const b = infos.items[j];
        if (std.mem.eql(u8, a.folded, b.folded) or @min(a.folded.len, b.folded.len) < 6) continue;
        // Numbers tell sequels and seasons apart ("rocky-2", "rocky-3").
        if (!sameDigits(a.folded, b.folded)) continue;
        if (editDistance(a.folded, b.folded, 2) <= 2) try out.append(arena, .{ .a = a.t.key, .b = b.t.key, .reason = "spelling" });
    };
    return out.items;
}

fn sameDigits(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and !std.ascii.isDigit(a[i])) i += 1;
        while (j < b.len and !std.ascii.isDigit(b[j])) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (a[i] != b[j]) return false;
        i += 1;
        j += 1;
    }
}

fn yearReason(a: ?u16, b: ?u16) ?[]const u8 {
    const x = a orelse return if (b != null) "year missing" else null;
    const y = b orelse return "year missing";
    if (x == y) return null;
    if (@max(x, y) - @min(x, y) == 1) return "year off by one";
    var xs: [4]u8 = undefined;
    var ys: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&xs, "{d:0>4}", .{x}) catch return null;
    _ = std.fmt.bufPrint(&ys, "{d:0>4}", .{y}) catch return null;
    var diffs: [4]usize = undefined;
    var n: usize = 0;
    for (0..4) |i| if (xs[i] != ys[i]) {
        diffs[n] = i;
        n += 1;
    };
    if (n == 2 and diffs[1] == diffs[0] + 1 and xs[diffs[0]] == ys[diffs[1]] and xs[diffs[1]] == ys[diffs[0]]) return "year digits transposed";
    return null;
}

/// Levenshtein distance, giving up past `limit`.
fn editDistance(a: []const u8, b: []const u8, limit: usize) usize {
    if (@max(a.len, b.len) - @min(a.len, b.len) > limit) return limit + 1;
    if (b.len > 255) return limit + 1;
    var prev: [256]usize = undefined;
    var cur: [256]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        var best = cur[0];
        for (b, 0..) |cb, j| {
            cur[j + 1] = @min(@min(prev[j + 1] + 1, cur[j] + 1), prev[j] + @intFromBool(ca != cb));
            best = @min(best, cur[j + 1]);
        }
        if (best > limit) return limit + 1;
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

/// Qualities held twice by one source: two files that parsed alike,
/// such as a mislabeled episode or a copy, as `key` and `value` pairs.
pub fn duplicates(replica: *Replica, arena: std.mem.Allocator) ![]Match {
    var out: std.ArrayList(Match) = .empty;
    const s = try replica.db.prepare(
        \\SELECT d.key, d.value, o.value FROM winners d
        \\JOIN winners o ON o.key = substr(d.key, 1, instr(d.key, '~') - 1) AND o.field = d.field
        \\WHERE d.key LIKE 't/%~%' AND d.field LIKE 'held:%' AND length(d.value) > 0
        \\ORDER BY d.key
    );
    defer s.finalize();
    while (try s.step()) {
        const first = s.blob(2);
        const second = s.blob(1);
        try out.append(arena, .{
            .reason = "duplicate",
            .a = try arena.dupe(u8, first[0 .. std.mem.indexOfScalar(u8, first, '\t') orelse first.len]),
            .b = try arena.dupe(u8, second[0 .. std.mem.indexOfScalar(u8, second, '\t') orelse second.len]),
        });
    }
    return out.items;
}

/// Records `from` as an alias of `to`, so every device merges them alike.
/// Records `from` as an alias of `to`: two names of one title.
pub fn addAlias(replica: *Replica, wall_ms: u64, from: []const u8, to: []const u8) !void {
    if (std.mem.eql(u8, from, to)) return error.SameTitle;
    try replica.write(wall_ms, "aliases", from, to);
}

/// Stops `from` being an alias of another title.
pub fn removeAlias(replica: *Replica, wall_ms: u64, from: []const u8) !void {
    try replica.write(wall_ms, "aliases", from, "");
}

pub const Alias = struct { from: []const u8, to: []const u8 };

pub fn aliases(replica: *Replica, arena: std.mem.Allocator) ![]Alias {
    var out: std.ArrayList(Alias) = .empty;
    const s = try replica.db.prepare("SELECT field, value FROM winners WHERE key = 'aliases' AND length(value) > 0 ORDER BY field");
    defer s.finalize();
    while (try s.step()) try out.append(arena, .{ .from = try arena.dupe(u8, s.blob(0)), .to = try arena.dupe(u8, s.blob(1)) });
    return out.items;
}

const testing = std.testing;

test "close matches" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const all = [_]Title{
        .{ .key = "t/m/amélie/2001", .kind = .movie, .name = "Amélie", .year = 2001, .qualities = 1 },
        .{ .key = "t/m/amelie/2001", .kind = .movie, .name = "Amelie", .year = 2001, .qualities = 1 },
        .{ .key = "t/m/heat/1995", .kind = .movie, .name = "Heat", .year = 1995, .qualities = 1 },
        .{ .key = "t/m/heat/1959", .kind = .movie, .name = "Heat", .year = 1959, .qualities = 1 },
        .{ .key = "t/m/gattaca/1997", .kind = .movie, .name = "Gattaca", .year = 1997, .qualities = 1 },
        .{ .key = "t/m/gatacca/1997", .kind = .movie, .name = "Gatacca", .year = 1997, .qualities = 1 },
        .{ .key = "t/m/alien/1979", .kind = .movie, .name = "Alien", .year = 1979, .qualities = 1 },
        .{ .key = "t/m/alien/1980", .kind = .movie, .name = "Alien", .year = 1980, .qualities = 1 },
        .{ .key = "t/m/aliens/1986", .kind = .movie, .name = "Aliens", .year = 1986, .qualities = 1 },
        .{ .key = "t/m/rocky-2/1979", .kind = .movie, .name = "Rocky 2", .year = 1979, .qualities = 1 },
        .{ .key = "t/m/rocky-3/1979", .kind = .movie, .name = "Rocky 3", .year = 1979, .qualities = 1 },
    };
    const matches = try closeMatches(a, &all);
    // Held by no source, so not for review.
    const unheld = [_]Title{ all[2], .{ .key = "t/m/heat/1996", .kind = .movie, .name = "Heat", .year = 1996 } };
    try testing.expectEqual(@as(usize, 0), (try closeMatches(a, &unheld)).len);
    var reasons: std.StringHashMapUnmanaged(void) = .empty;
    for (matches) |m| try reasons.put(a, m.reason, {});
    try testing.expectEqual(@as(usize, 4), matches.len);
    for ([_][]const u8{ "diacritics", "year digits transposed", "spelling", "year off by one" }) |r| try testing.expect(reasons.contains(r));
}

test "year reasons" {
    try testing.expectEqualStrings("year off by one", yearReason(1999, 2000).?);
    try testing.expectEqualStrings("year digits transposed", yearReason(1995, 1959).?);
    try testing.expect(yearReason(1995, 1975) == null);
}
