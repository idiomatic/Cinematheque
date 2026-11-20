//! The C interface (see ../capi.zig): downloads (see ../download.zig).

const std = @import("std");
const capi = @import("../capi.zig");
const connection = @import("long.zig").connection;
const library = @import("../library.zig");
const download = @import("../download.zig");
const gpa = capi.gpa;
const Library = capi.Library;
const json = capi.json;
const status = capi.status;
const span = capi.span;

/// Sets where this device keeps downloads (`dir`), and the URL it serves
/// them at (made a source of its own, which no one crawls).
export fn cq_downloads_configure(lib: *Library, dir: [*:0]const u8, served_at: [*:0]const u8) c_int {
    return status(lib, downloadsConfigure, .{ std.mem.span(dir), std.mem.span(served_at) });
}

fn downloadsConfigure(lib: *Library, arena: std.mem.Allocator, dir: []const u8, served_at: []const u8) !void {
    try lib.writer.lock(lib.io());
    defer lib.writer.unlock(lib.io());
    try download.configure(try lib.main(), arena, lib.now(), dir, served_at);
}

/// Wants a title's, a season's (`<title>/e/s01`), or an item's files kept
/// on this device (each item as of now), in `quality` (null or empty:
/// the one most items have), until deleted; `cq_reconcile` fetches them.
export fn cq_download(lib: *Library, key: [*:0]const u8, quality: ?[*:0]const u8) c_int {
    return status(lib, downloadWant, .{ std.mem.span(key), span(quality) orelse "" });
}

fn downloadWant(lib: *Library, arena: std.mem.Allocator, key: []const u8, quality: []const u8) !void {
    try download.want(try lib.main(), arena, key, quality);
}

/// Stops keeping a title's, season's, or item's files: deletes those held
/// here, and forgets wanting them.
export fn cq_download_remove(lib: *Library, key: [*:0]const u8) c_int {
    return status(lib, downloadRemove, .{std.mem.span(key)});
}

fn downloadRemove(lib: *Library, arena: std.mem.Allocator, key: []const u8) !void {
    _ = try download.remove(lib.io(), arena, try lib.main(), &lib.writer, lib.now(), key);
}

/// Chooses which of a series' episodes download, as it's watched: the
/// next N after where this person is (`3`), the watched ones going as their
/// space is needed, or `all` of them, kept however they're watched; empty
/// or `0`, none.
export fn cq_download_next(lib: *Library, title_key: [*:0]const u8, choice: [*:0]const u8) c_int {
    return status(lib, downloadNext, .{ std.mem.span(title_key), std.mem.span(choice) });
}

fn downloadNext(lib: *Library, arena: std.mem.Allocator, title_key: []const u8, choice: []const u8) !void {
    const parsed = download.Choice.parse(choice);
    if (parsed == null and choice.len > 0 and !std.mem.eql(u8, choice, "0")) return error.InvalidArgument;
    try download.setNext(try lib.main(), arena, title_key, parsed);
}

/// What downloading would come to, as a JSON array, one object per choice
/// in `choices_json` (an array of strings): `choice`, `size` (bytes, of all
/// its files), and `needed` (of those, what isn't here yet). A choice is a
/// series' (`key` its title's), as `cq_download_next` takes it, or empty
/// for `key`'s own files (a title's, season's, or item's) in `quality`
/// (null: the one most have).
export fn cq_download_sizes(lib: *Library, key: [*:0]const u8, choices_json: [*:0]const u8, quality: ?[*:0]const u8) ?[*:0]u8 {
    return json(lib, downloadSizes, .{ std.mem.span(key), std.mem.span(choices_json), span(quality) });
}

const SizeJson = struct { choice: []const u8, size: u64, needed: u64 };

fn downloadSizes(lib: *Library, arena: std.mem.Allocator, key: []const u8, choices_json: []const u8, quality: ?[]const u8) ![]const SizeJson {
    const r = try lib.main();
    const choices = try std.json.parseFromSliceLeaky([]const []const u8, arena, choices_json, .{});
    const out = try arena.alloc(SizeJson, choices.len);
    for (choices, out) |c, *o| {
        const choice = if (c.len == 0) null else download.Choice.parse(c) orelse return error.InvalidArgument;
        const s = try download.sizeOf(r, arena, key, choice, quality);
        o.* = .{ .choice = c, .size = s.size, .needed = s.needed };
    }
    return out;
}

/// A series' choice of episodes, as `cq_downloads` tells it.
const NextJson = struct { title: []const u8, choice: []const u8 };

const HeldJson = struct { item: []const u8, size: u64, only: bool };

const DownloadsJson = struct {
    dir: ?[]const u8,
    source: ?[]const u8,
    held: []const HeldJson,
    wanted: []const download.Want,
    next: []const NextJson,
    ahead: []const []const u8,
    free: ?u64,
    floor: u64,
    running: bool,
    done_mb: u32,
    total_mb: u32,
    fetching: ?FetchingJson,
};
const FetchingJson = struct { item: []const u8, done: u64, size: u64 };

/// This device's downloads, as a JSON object: `dir` and `source` (its ID),
/// as configured (null if not); `held`, the files held
/// (`item`, `size`, and whether it's the `only` copy, no other source
/// holding it alike); `wanted` (`key`, `quality`); `next`, series whose
/// episodes download as they're watched (`title`, and `choice`, as
/// `cq_download_next` takes it), and `ahead`, the episodes (full item keys)
/// they come to now; `free` bytes on its volume, if known, and the
/// `floor` kept free; and whether `cq_reconcile` is `running`, with
/// `done_mb` of `total_mb`, and the file it's `fetching` (`item`, its
/// `size`, and the bytes `done`, a resumed file's earlier ones too), or
/// null.
export fn cq_downloads(lib: *Library) ?[*:0]u8 {
    return json(lib, downloads, .{});
}

fn downloads(lib: *Library, arena: std.mem.Allocator) !DownloadsJson {
    const r = try lib.main();
    const s = try download.settings(r, arena);
    var list: std.ArrayList(HeldJson) = .empty;
    if (s) |set| {
        const all = try library.sources(r, arena);
        const unavailable = try library.UnavailableDirs.load(r, arena);
        for (try download.held(r, arena, set.source)) |h|
            try list.append(arena, .{ .item = h.item, .size = h.size, .only = !try download.confirmed(r, all, &unavailable, h) });
    }
    // The episodes each series' next ones come to, as of now, by full key.
    var ahead: std.ArrayList([]const u8) = .empty;
    const nexts = try download.nexts(r, arena);
    const next = try arena.alloc(NextJson, nexts.len);
    for (nexts, next) |n, *j| {
        j.* = .{ .title = n.title, .choice = try n.choice.write(arena) };
        for (try download.ahead(r, arena, n.title, n.choice)) |item|
            try ahead.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ n.title, item }));
    }
    return .{
        .dir = if (s) |set| set.dir else null,
        .source = if (s) |set| try arena.dupe(u8, &set.source.id) else null,
        .held = list.items,
        .wanted = try download.wants(r, arena),
        .next = next,
        .ahead = ahead.items,
        .free = if (s) |set| download.freeBytes(arena, set.dir) else null,
        .floor = download.floor(),
        .running = lib.reconciling.load(.acquire),
        .done_mb = lib.downloaded_mb.load(.monotonic),
        .total_mb = lib.download_mb.load(.monotonic),
        .fetching = if (try lib.fetching.get(lib.io(), arena)) |f| .{ .item = f.item, .done = f.done, .size = f.size } else null,
    };
}

/// Long, on a connection of its own: brings this device's downloads in line
/// with what it keeps (see download.zig), fetching, recording, and deleting
/// as it goes; if one runs already, asks it to run again and returns at
/// once, with `busy`. Returns a JSON object with `fetched`, `kept`,
/// `deleted`, `failed`, `no_room` (files left to keep the floor free),
/// `error`, and `busy`.
export fn cq_reconcile(lib: *Library) ?[*:0]u8 {
    return json(lib, reconcile, .{});
}

const ReconciledJson = struct { fetched: usize = 0, kept: usize = 0, deleted: usize = 0, failed: usize = 0, no_room: usize = 0, held: usize = 0, @"error": ?[]const u8 = null, busy: bool = false };

/// Holds downloads back (nonzero), as while a stream plays, which they'd
/// slow: none begins, though one under way finishes; or lets them go (then
/// `cq_reconcile` fetches what waited). Any thread.
export fn cq_downloads_hold(lib: *Library, on: c_int) void {
    lib.hold.store(on != 0, .release);
}

fn reconcile(lib: *Library, arena: std.mem.Allocator) !ReconciledJson {
    lib.reconcile_again.store(true, .release);
    if (lib.reconciling.swap(true, .acq_rel)) return .{ .busy = true };
    errdefer lib.reconciling.store(false, .release);
    var r = try connection(lib, arena);
    defer r.close();
    var client: std.http.Client = .{ .allocator = gpa, .io = lib.io() };
    defer client.deinit();
    var out: ReconciledJson = .{};
    while (true) {
        // Again while asked again (a download wanted meanwhile).
        while (lib.reconcile_again.swap(false, .acq_rel)) {
            try r.refresh();
            const done = try download.reconcile(lib.io(), gpa, arena, &client, &lib.racing, &r, &lib.writer, lib.now(), .{ .done = &lib.downloaded_mb, .total = &lib.download_mb, .fetching = &lib.fetching }, &lib.hold);
            out.fetched += done.fetched;
            out.kept = done.kept;
            out.deleted += done.deleted;
            out.failed = done.failed;
            out.no_room = done.no_room;
            out.held = done.held;
            out.@"error" = done.@"error";
        }
        lib.reconciling.store(false, .release);
        // A caller may have asked after the last check and found us still
        // running, so returned busy: take its request up, unless another has.
        if (!lib.reconcile_again.load(.acquire)) break;
        if (lib.reconciling.swap(true, .acq_rel)) break;
    }
    return out;
}

/// Forgets an unavailable directory of a source (by ID or URL), as if it
/// were deleted: its copies go, for every device.
export fn cq_remove_unavailable(lib: *Library, source: [*:0]const u8, dir: [*:0]const u8) c_int {
    return status(lib, removeUnavailable, .{ std.mem.span(source), std.mem.span(dir) });
}

fn removeUnavailable(lib: *Library, arena: std.mem.Allocator, source: []const u8, dir: []const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    const r = try lib.main();
    _ = try library.removeUnavailable(r, arena, lib.now(), try library.findSource(r, arena, source), dir);
}

/// Adds a source by URL, as typed, with its quality and the prefix of
/// names to skip (each null for the default).
export fn cq_repo_add(lib: *Library, target: [*:0]const u8, quality: ?[*:0]const u8, skip: ?[*:0]const u8) c_int {
    return status(lib, sourceAdd, .{ std.mem.span(target), span(quality), span(skip) });
}

fn sourceAdd(lib: *Library, arena: std.mem.Allocator, target: []const u8, quality: ?[]const u8, skip: ?[]const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    const r = try lib.main();
    var typed: std.ArrayList(u8) = .empty;
    try @import("../url.zig").escape(arena, &typed, std.mem.trim(u8, target, " \n"));
    if (!std.mem.endsWith(u8, typed.items, "/")) try typed.append(arena, '/');
    var layout: library.Layout = .{};
    if (quality) |v| layout.quality = v;
    if (skip) |v| layout.skip = v;
    _ = try library.addSource(r, lib.now(), typed.items, layout);
}

/// Changes a source's settings, those not null.
export fn cq_repo_set(lib: *Library, source: [*:0]const u8, quality: ?[*:0]const u8, skip: ?[*:0]const u8) c_int {
    return status(lib, sourceSet, .{ std.mem.span(source), span(quality), span(skip) });
}

fn sourceSet(lib: *Library, arena: std.mem.Allocator, source: []const u8, quality: ?[]const u8, skip: ?[]const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    _ = try library.setSource(try lib.main(), arena, lib.now(), source, quality, skip, null);
}

/// Whether a source's files take their quality from the first folder
/// within it (nonzero), else from its name or the files'. Copies move at
/// the next crawl.
export fn cq_repo_quality_by_folder(lib: *Library, source: [*:0]const u8, on: c_int) c_int {
    return status(lib, sourceByFolder, .{ std.mem.span(source), on != 0 });
}

fn sourceByFolder(lib: *Library, arena: std.mem.Allocator, source: []const u8, on: bool) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    _ = try library.setSource(try lib.main(), arena, lib.now(), source, null, null, on);
}

/// Removes a source, by ID or URL, and the copies it held.
export fn cq_repo_remove(lib: *Library, source: [*:0]const u8) c_int {
    return status(lib, sourceRemove, .{std.mem.span(source)});
}

fn sourceRemove(lib: *Library, arena: std.mem.Allocator, source: []const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    _ = try library.removeSource(try lib.main(), arena, lib.now(), source);
}
