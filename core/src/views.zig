//! What players show, as JSON shapes: the grid's tiles, and one title's
//! detail, with its covers and copies as URLs. The C interface returns
//! them to the apps, and the command-line app's web client to browsers.

const std = @import("std");
const art = @import("art.zig");
const library = @import("library.zig");
const Replica = @import("replica.zig").Replica;

pub const CoverJson = struct { url: []const u8, offset: u64, length: u64, stamp: []const u8 };
pub const TileJson = struct { key: []const u8, name: []const u8, year: ?u16, kind: []const u8, season: ?u16, cover: ?CoverJson, thumb: ?[]const u8, watched: bool, progress: f64, elapsed: u64, runtime: u64, started: bool, items: usize, unavailable: bool };

pub fn tiles(r: *Replica, arena: std.mem.Allocator) ![]const TileJson {
    const bases = try sourceBases(r, arena);
    const list = try art.tiles(r, arena);
    const out = try arena.alloc(TileJson, list.len);
    for (list, out) |t, *o| o.* = .{
        .key = t.key,
        .name = t.name,
        .year = t.year,
        .kind = if (t.kind == 's') "series" else "movie",
        .season = t.season,
        .cover = if (t.cover) |c| try coverJson(arena, bases, c) else null,
        .thumb = t.thumb,
        .watched = t.watched,
        .progress = t.progress,
        .elapsed = t.played,
        .runtime = t.total,
        .started = t.started,
        .items = t.items,
        .unavailable = t.unavailable,
    };
    return out;
}

fn sourceBases(r: *Replica, arena: std.mem.Allocator) !std.StringHashMapUnmanaged(library.Source) {
    var bases: std.StringHashMapUnmanaged(library.Source) = .empty;
    for (try library.sources(r, arena)) |rp| try bases.put(arena, try arena.dupe(u8, &rp.id), rp);
    return bases;
}

fn coverJson(arena: std.mem.Allocator, bases: std.StringHashMapUnmanaged(library.Source), c: art.Cover) !?CoverJson {
    const rp = bases.get(c.source) orelse return null;
    return .{ .url = try art.fileUrl(arena, rp.url, c.path), .offset = c.offset, .length = c.length, .stamp = c.stamp };
}

pub const CopyJson = struct { url: []const u8, size: u64, mtime: []const u8, source: []const u8, unavailable: bool };
/// A quality: its `label` (as keyed), `name` (as its sources give it), and
/// `short` name for a picker (see `shortNames`).
pub const QualityJson = struct { label: []const u8, name: []const u8, short: []const u8, copies: []const CopyJson };
/// An item, with what players call it, so none reads its key: an
/// episode's `season` and `number` (a special's number null; a dated one's
/// season its year, its number its month and day, and `aired` its date);
/// its `label` ("Episode 3", "Special", "March 12", or a version's name,
/// "Standard" or its edition); and its `name` in a list ("3. Title", or a
/// special's or dated episode's title alone, else its label).
pub const ItemJson = struct {
    key: []const u8,
    season: ?u16,
    number: ?u16,
    aired: ?[]const u8,
    label: []const u8,
    name: []const u8,
    fields: std.json.ArrayHashMap([]const u8),
    qualities: []const QualityJson,
    position: u64,
    duration: u64,
    watched: bool,
};

pub const Title = struct {
    key: []const u8,
    name: []const u8,
    year: ?u16,
    aliasOf: ?[]const u8,
    aliases: []const []const u8,
    fields: std.json.ArrayHashMap([]const u8),
    covers: std.json.ArrayHashMap(CoverJson),
    items: []const ItemJson,
};

pub fn title(r: *Replica, arena: std.mem.Allocator, key: []const u8) !Title {
    const d = try library.detail(r, arena, key) orelse return error.NoSuchTitle;
    const bases = try sourceBases(r, arena);
    const items = try arena.alloc(ItemJson, d.items.items.len);
    for (d.items.items, items) |item, *io| {
        const qualities = try arena.alloc(QualityJson, item.qualities.items.len);
        for (item.qualities.items, qualities) |rn, *ro| {
            const copies = try arena.alloc(CopyJson, rn.copies.items.len);
            var name = rn.label;
            for (rn.copies.items, copies) |h, *c| {
                const rp = bases.get(h.source);
                c.* = .{ .url = if (rp) |b| try art.fileUrl(arena, b.url, h.path) else "", .size = h.size, .mtime = h.mtime, .source = h.source, .unavailable = h.unavailable };
                // The quality's name as its sources give it.
                if (rp) |b| if (b.layout.quality.len > 0) {
                    name = b.layout.quality;
                };
            }
            ro.* = .{ .label = rn.label, .name = name, .short = "", .copies = copies };
        }
        const code = episodeCode(item.key);
        const aired: ?[]const u8 = if (code) |c| if (c.season >= 1000 and c.number != null) try std.fmt.allocPrint(arena, "{d}-{d:0>2}-{d:0>2}", .{ c.season, c.number.? / 100, c.number.? % 100 }) else null else null;
        const label = try itemLabel(arena, item.key, item.fields, code);
        const own = item.fields.get("title");
        io.* = .{
            .key = item.key,
            .season = if (code) |c| c.season else null,
            .number = if (code) |c| c.number else null,
            .aired = aired,
            .label = label,
            .name = if (code) |c|
                (if (c.season == 0 or aired != null) own orelse label else try std.fmt.allocPrint(arena, "{d}. {s}", .{ c.number orelse 0, own orelse label }))
            else
                label,
            .fields = .{ .map = item.fields },
            .qualities = qualities,
            .position = item.progress.position_ms,
            .duration = item.progress.duration_ms,
            .watched = item.progress.watched,
        };
    }
    try shortNames(arena, items);
    var fields: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var covers: std.StringArrayHashMapUnmanaged(CoverJson) = .empty;
    for (d.fields.keys(), d.fields.values()) |k, v| {
        if (std.mem.startsWith(u8, k, "art")) {
            const c = art.Cover.parse(v) orelse continue;
            if (c.length == 0) continue;
            if (try coverJson(arena, bases, c)) |cj| try covers.put(arena, k, cj);
        } else try fields.put(arena, k, v);
    }
    return .{
        .key = d.key,
        .name = d.name,
        .year = d.year,
        .aliasOf = d.alias_of,
        .aliases = d.aliases.items,
        .fields = .{ .map = fields },
        .covers = .{ .map = covers },
        .items = items,
    };
}

/// An item key's season and number: `e/s03e17` (dated, `e/s2024e0312`),
/// or a special's `e/s00-<name>`, number null; null for a movie's version.
const Code = struct { season: u16, number: ?u16 };

fn episodeCode(key: []const u8) ?Code {
    if (!std.mem.startsWith(u8, key, "e/s")) return null;
    const rest = key[3..];
    var i: usize = 0;
    while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
    const season = std.fmt.parseInt(u16, rest[0..i], 10) catch return null;
    if (i == rest.len or rest[i] != 'e') return .{ .season = season, .number = null };
    var j = i + 1;
    while (j < rest.len and std.ascii.isDigit(rest[j])) j += 1;
    return .{ .season = season, .number = std.fmt.parseInt(u16, rest[i + 1 .. j], 10) catch null };
}

const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

/// What players call an item: "Episode 3", "Special", "March 12", or a
/// version's name ("Standard", or its edition as written).
fn itemLabel(arena: std.mem.Allocator, key: []const u8, fields: std.StringArrayHashMapUnmanaged([]const u8), code: ?Code) ![]const u8 {
    if (code) |c| {
        const n = c.number orelse return "Special";
        if (c.season == 0) return "Special";
        if (c.season >= 1000 and n / 100 >= 1 and n / 100 <= 12) return std.fmt.allocPrint(arena, "{s} {d}", .{ months[n / 100 - 1], n % 100 });
        return std.fmt.allocPrint(arena, "Episode {d}", .{n});
    }
    if (fields.get("edition")) |e| return e;
    if (std.mem.startsWith(u8, key, "v/-")) return "Standard";
    // An edition's key, words capitalized ("v/directors-cut": "Directors Cut").
    const end = std.mem.indexOfScalarPos(u8, key, 2, '/') orelse key.len;
    const out = try arena.dupe(u8, key[2..end]);
    for (out, 0..) |*ch, k| {
        if (ch.* == '-') ch.* = ' ';
        if (k == 0 or out[k - 1] == ' ') ch.* = std.ascii.toUpper(ch.*);
    }
    return out;
}

/// Each quality's short name for a picker: its resolution (2160p as 4K),
/// with HDR if it says so ("1080p", "4K HDR"); "Other" for one of unknown
/// quality; its full name where it gives no resolution; and where two of a
/// title's would read alike, each with what else its full name says, its
/// resolution and options' syntax aside ("720p Very Fast"), failing that
/// its full name.
fn shortNames(arena: std.mem.Allocator, items: []ItemJson) !void {
    var labels: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    for (items) |it| for (it.qualities) |q| if (!labels.contains(q.label)) try labels.put(arena, q.label, q.name);
    const n = labels.count();
    const shorts = try arena.alloc([]const u8, n);
    for (labels.keys(), labels.values(), shorts) |label, full, *s| s.* = try short(arena, label, full);
    const told = try arena.alloc([]const u8, n);
    for (labels.values(), shorts, told) |full, s, *t| {
        var alike: usize = 0;
        for (shorts) |o| if (std.mem.eql(u8, o, s)) {
            alike += 1;
        };
        t.* = if (alike > 1) try withRest(arena, s, full) else s;
    }
    var names: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (labels.keys(), labels.values(), told) |label, full, t| {
        var alike: usize = 0;
        for (told) |o| if (std.mem.eql(u8, o, t)) {
            alike += 1;
        };
        try names.put(arena, label, if (alike > 1) full else t);
    }
    for (items) |it| for (it.qualities) |*q| {
        @constCast(q).short = names.get(q.label) orelse q.label;
    };
}

fn short(arena: std.mem.Allocator, label: []const u8, full: []const u8) ![]const u8 {
    if (std.mem.eql(u8, label, "-")) return if (std.mem.eql(u8, full, "-")) "Other" else full;
    const text = try std.ascii.allocLowerString(arena, try std.fmt.allocPrint(arena, "{s} {s}", .{ label, full }));
    const resolution: []const u8 = blk: {
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            var j = i;
            while (j < text.len and std.ascii.isDigit(text[j])) j += 1;
            if (j - i >= 3 and j - i <= 4 and j < text.len and text[j] == 'p' and (i == 0 or !std.ascii.isDigit(text[i - 1]))) {
                const digits = text[i..j];
                break :blk if (std.mem.eql(u8, digits, "2160")) "4K" else try std.fmt.allocPrint(arena, "{s}p", .{digits});
            }
            if (j > i) i = j;
        }
        if (std.mem.indexOf(u8, text, "4k") != null) break :blk "4K";
        return full;
    };
    const hdr = std.mem.indexOf(u8, text, "hdr") != null or std.mem.indexOf(u8, text, "dolby vision") != null or std.mem.indexOf(u8, text, "dovi") != null;
    return if (hdr) std.fmt.allocPrint(arena, "{s} HDR", .{resolution}) else resolution;
}

/// A short name with what else the full name says: its words but for a
/// resolution (`720p30`) and options' syntax (`--encoder=`).
fn withRest(arena: std.mem.Allocator, s: []const u8, full: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, s);
    var words = std.mem.tokenizeScalar(u8, full, ' ');
    while (words.next()) |w0| {
        var w = w0;
        // Options' syntax: "--encoder=x265" says x265.
        if (std.mem.startsWith(u8, w, "-")) if (std.mem.indexOfScalar(u8, w, '=')) |eq| {
            w = w[eq + 1 ..];
        };
        if (isResolution(w) or w.len == 0) continue;
        try out.append(arena, ' ');
        try out.appendSlice(arena, w);
    }
    return out.items;
}

fn isResolution(w: []const u8) bool {
    var i: usize = 0;
    while (i < w.len and std.ascii.isDigit(w[i])) i += 1;
    if (i < 3 or i > 4 or i >= w.len or (w[i] != 'p' and w[i] != 'P')) return false;
    for (w[i + 1 ..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

test "items' labels and names, and qualities' short names" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var none: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try std.testing.expectEqualStrings("Episode 17", try itemLabel(arena, "e/s03e17", none, episodeCode("e/s03e17")));
    try std.testing.expectEqualStrings("Special", try itemLabel(arena, "e/s00-the-gathering", none, episodeCode("e/s00-the-gathering")));
    try std.testing.expectEqualStrings("March 12", try itemLabel(arena, "e/s2024e0312", none, episodeCode("e/s2024e0312")));
    try std.testing.expectEqualStrings("Standard", try itemLabel(arena, "v/-", none, null));
    try std.testing.expectEqualStrings("Directors Cut", try itemLabel(arena, "v/directors-cut", none, null));
    try none.put(arena, "edition", "Director's Cut");
    try std.testing.expectEqualStrings("Director's Cut", try itemLabel(arena, "v/directors-cut", none, null));

    try std.testing.expectEqualStrings("4K HDR", try short(arena, "2160p-hdr", "2160p-hdr"));
    try std.testing.expectEqualStrings("Other", try short(arena, "-", "-"));
    var qualities = [_]QualityJson{
        .{ .label = "a", .name = "HQ 720p30 Surround", .short = "", .copies = &.{} },
        .{ .label = "b", .name = "Very Fast 720p30", .short = "", .copies = &.{} },
        .{ .label = "c", .name = "HQ 1080p30 Surround --encoder=x265", .short = "", .copies = &.{} },
    };
    var items = [_]ItemJson{.{ .key = "v/-", .season = null, .number = null, .aired = null, .label = "Standard", .name = "Standard", .fields = .{}, .qualities = &qualities, .position = 0, .duration = 0, .watched = false }};
    try shortNames(arena, &items);
    try std.testing.expectEqualStrings("720p HQ Surround", qualities[0].short);
    try std.testing.expectEqualStrings("720p Very Fast", qualities[1].short);
    try std.testing.expectEqualStrings("1080p", qualities[2].short);
}
