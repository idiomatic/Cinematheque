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
pub const QualityJson = struct { label: []const u8, name: []const u8, copies: []const CopyJson };
pub const ItemJson = struct { key: []const u8, fields: std.json.ArrayHashMap([]const u8), qualities: []const QualityJson, position: u64, duration: u64, watched: bool };

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
            ro.* = .{ .label = rn.label, .name = name, .copies = copies };
        }
        io.* = .{
            .key = item.key,
            .fields = .{ .map = item.fields },
            .qualities = qualities,
            .position = item.progress.position_ms,
            .duration = item.progress.duration_ms,
            .watched = item.progress.watched,
        };
    }
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

