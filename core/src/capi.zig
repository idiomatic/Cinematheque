//! A C interface to the library, for apps in other languages (Swift, for the
//! Apple players). Results are JSON strings, freed with `cq_free`; on
//! failure, functions return null and `cq_error` says why. See
//! include/cinematheque.h.

const std = @import("std");
const Io = std.Io;
const library = @import("library.zig");
const store_ = @import("store.zig");
const url = @import("url.zig");
const Replica = @import("replica.zig").Replica;

const gpa = std.heap.c_allocator;

threadlocal var last_error: [256:0]u8 = @splat(0);

fn fail(err: anyerror) void {
    _ = std.fmt.bufPrintSentinel(&last_error, "{t}", .{err}, 0) catch {};
}

const Library = struct {
    threaded: Io.Threaded,
    arena_state: std.heap.ArenaAllocator,
    store: store_.Store,
    replica: Replica,
};

export fn cq_error() [*:0]const u8 {
    return &last_error;
}

/// Opens the library in `data_dir`, or in the default directory if null.
export fn cq_open(peer_home: ?[*:0]const u8) ?*Library {
    return open(peer_home) catch |err| {
        fail(err);
        return null;
    };
}

fn open(peer_home: ?[*:0]const u8) !*Library {
    const lib = try gpa.create(Library);
    errdefer gpa.destroy(lib);
    lib.threaded = .init(gpa, .{});
    errdefer lib.threaded.deinit();
    lib.arena_state = .init(gpa);
    errdefer lib.arena_state.deinit();
    const arena = lib.arena_state.allocator();
    const dir = if (peer_home orelse std.c.getenv("CINEMATHEQUE_HOME")) |d| try arena.dupe(u8, std.mem.span(d)) else blk: {
        const home = std.c.getenv("HOME") orelse return error.NoHome;
        const xdg = std.c.getenv("XDG_DATA_HOME");
        break :blk try store_.defaultHome(arena, std.mem.span(home), if (xdg) |x| std.mem.span(x) else null);
    };
    lib.store = try store_.Store.open(lib.threaded.io(), gpa, arena, dir);
    lib.replica = try lib.store.openReplica(arena);
    return lib;
}

export fn cq_close(lib: ?*Library) void {
    const l = lib orelse return;
    l.replica.close();
    l.arena_state.deinit();
    l.threaded.deinit();
    gpa.destroy(l);
}

export fn cq_free(text: ?[*:0]u8) void {
    const t = text orelse return;
    gpa.free(std.mem.span(t));
}

/// Every title, as a JSON array of objects with `key`, `name`, `year`,
/// `kind` (`movie` or `series`), `items`, `renditions`, `labels`, and
/// `alias` (the title it's an alias of, or null).
export fn cq_titles(lib: *Library) ?[*:0]u8 {
    return titles(lib) catch |err| {
        fail(err);
        return null;
    };
}

fn titles(lib: *Library) ![*:0]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const all = try library.titles(&lib.replica, arena);
    const Json = struct {
        key: []const u8,
        name: []const u8,
        year: ?u16,
        kind: []const u8,
        items: usize,
        renditions: usize,
        labels: []const []const u8,
        alias: ?[]const u8,
    };
    const out = try arena.alloc(Json, all.len);
    for (all, out) |t, *o| o.* = .{
        .key = t.key,
        .name = t.name,
        .year = t.year,
        .kind = if (t.kind == 's') "series" else "movie",
        .items = t.items,
        .renditions = t.renditions,
        .labels = t.labels.items,
        .alias = t.alias,
    };
    return stringify(out);
}

/// One title, as a JSON object with `key`, `name`, `year`, `aliasOf`,
/// `aliases`, and `items`, each with its `key` and `renditions`, each with
/// its `label`, `name` (as its repositories give it), and `copies`, and
/// this user's `position`, `duration` (milliseconds), and `watched`; copies: `url` (ready to play), `size`, `mtime`, and
/// `repository`. Null if there's no such title.
export fn cq_title(lib: *Library, key: [*:0]const u8) ?[*:0]u8 {
    return title(lib, std.mem.span(key)) catch |err| {
        fail(err);
        return null;
    };
}

fn title(lib: *Library, key: []const u8) ![*:0]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try library.detail(&lib.replica, arena, key) orelse return error.NoSuchTitle;
    var bases: std.StringHashMapUnmanaged([]const u8) = .empty;
    var names: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (try library.repositories(&lib.replica, arena)) |repo| {
        const id = try arena.dupe(u8, &repo.id);
        try bases.put(arena, id, repo.url);
        if (repo.layout.rendition.len > 0) try names.put(arena, id, repo.layout.rendition);
    }

    const Copy = struct { url: []const u8, size: u64, mtime: []const u8, repository: []const u8 };
    const Rendition = struct { label: []const u8, name: []const u8, copies: []const Copy };
    const Item = struct { key: []const u8, renditions: []const Rendition, position: u64, duration: u64, watched: bool };
    const items = try arena.alloc(Item, d.items.items.len);
    for (d.items.items, items) |item, *io| {
        const renditions = try arena.alloc(Rendition, item.renditions.items.len);
        for (item.renditions.items, renditions) |r, *ro| {
            const copies = try arena.alloc(Copy, r.holdings.items.len);
            for (r.holdings.items, copies) |h, *c| {
                var target: std.ArrayList(u8) = .empty;
                try target.appendSlice(arena, bases.get(h.repository) orelse "");
                var segments = std.mem.splitScalar(u8, h.path, '/');
                var first = true;
                while (segments.next()) |segment| {
                    if (!first) try target.append(arena, '/');
                    first = false;
                    try url.encode(arena, &target, segment);
                }
                c.* = .{ .url = target.items, .size = h.size, .mtime = h.mtime, .repository = h.repository };
            }
            // The rendition's name as its repositories give it.
            var name = r.label;
            for (r.holdings.items) |h| if (names.get(h.repository)) |n| {
                name = n;
                break;
            };
            ro.* = .{ .label = r.label, .name = name, .copies = copies };
        }
        io.* = .{
            .key = item.key,
            .renditions = renditions,
            .position = item.playhead.position_ms,
            .duration = item.playhead.duration_ms,
            .watched = item.playhead.watched,
        };
    }
    return stringify(.{
        .key = d.key,
        .name = d.name,
        .year = d.year,
        .aliasOf = d.alias_of,
        .aliases = d.aliases.items,
        .items = items,
    });
}

fn now(lib: *Library) u64 {
    return @intCast(Io.Timestamp.now(lib.threaded.io(), .real).toMilliseconds());
}

/// Records this user's playhead in an item (a title's key and an item's,
/// e.g., `t/m/alien/1979/v/-`). Returns 0, or -1 on failure.
export fn cq_set_playhead(lib: *Library, item_key: [*:0]const u8, position_ms: u64, duration_ms: u64) c_int {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    library.setPlayhead(&lib.replica, arena_state.allocator(), now(lib), std.mem.span(item_key), position_ms, duration_ms) catch |err| {
        fail(err);
        return -1;
    };
    return 0;
}

/// Marks an item watched (nonzero) or not. Returns 0, or -1 on failure.
export fn cq_set_watched(lib: *Library, item_key: [*:0]const u8, watched: c_int) c_int {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    library.setWatched(&lib.replica, arena_state.allocator(), now(lib), std.mem.span(item_key), watched != 0) catch |err| {
        fail(err);
        return -1;
    };
    return 0;
}

fn stringify(value: anytype) ![*:0]u8 {
    const json = try std.json.Stringify.valueAlloc(gpa, value, .{});
    defer gpa.free(json);
    return (try gpa.dupeSentinel(u8, json, 0)).ptr;
}
