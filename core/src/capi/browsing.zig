//! The C interface (see ../capi.zig): browsing.

const std = @import("std");
const capi = @import("../capi.zig");
const art = @import("../art.zig");
const views = @import("../views.zig");
const long = @import("long.zig");
const Library = capi.Library;
const json = capi.json;
const span = capi.span;

/// The grid's tiles, as a JSON array of objects with `key` (the title's),
/// `name`, `year`, `kind` (`movie` or `series`), `season` (a series', or
/// null), and `cover` (null, or `url`, `offset`, `length`, and `stamp`, a
/// byte range to fetch, and what changes when it does), `aspect` (null, or
/// the cover's width over its height, to lay it out before it loads), and
/// this person's `watched` (every item), `progress` (0 to 1, by running time),
/// `elapsed` and `runtime` (milliseconds played, of how many), and `started`;
/// `items`, how many it holds; and `unavailable`, whether every copy it has is under an unavailable directory.
/// Any thread, on a connection of its own, so the apps read it off the
/// main thread as a long operation commits (it reads the whole catalog).
export fn cq_tiles(lib: *Library) ?[*:0]u8 {
    return json(lib, tiles, .{});
}

fn tiles(lib: *Library, arena: std.mem.Allocator) ![]const views.TileJson {
    var r = try long.reader(lib, arena);
    defer long.release(lib, &r);
    return views.tiles(&r, arena);
}

/// One title, as a JSON object with `key`, `name`, `year`, `fields` (its metadata, e.g., `description` and `genre`),
/// `covers` (by field, `art` or `art:s01`...), and `items`, each with its
/// `key`, `fields` (e.g., an episode's `title`), this person's `position`,
/// `duration` (milliseconds), and `watched`, and `qualities`, each with
/// its `label`, `name` (as its sources give it), and `copies`: `url`
/// (ready to play), `size`, `mtime`, `source`, and `unavailable` (under an
/// unavailable directory of its source). Null if there's no such title.
export fn cq_title(lib: *Library, key: [*:0]const u8) ?[*:0]u8 {
    return json(lib, title, .{std.mem.span(key)});
}

fn title(lib: *Library, arena: std.mem.Allocator, key: []const u8) !views.Title {
    return views.title(try lib.main(), arena, key);
}
