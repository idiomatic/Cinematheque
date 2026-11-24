//! The C interface (see ../capi.zig): downloads (see ../download.zig).

const std = @import("std");
const capi = @import("../capi.zig");
const long = @import("long.zig");
const connection = long.connection;
const release = long.release;
const library = @import("../library.zig");
const download = @import("../download.zig");
const gpa = capi.gpa;
const Library = capi.Library;
const json = capi.json;
const status = capi.status;
const span = capi.span;

/// Long, on a connection of its own, waiting its turn to write: sets
/// where this device keeps downloads (`dir`), and the URL it serves them
/// at (made a source of its own, which no one crawls).
export fn cq_downloads_configure(lib: *Library, dir: [*:0]const u8, served_at: [*:0]const u8) c_int {
    return status(lib, downloadsConfigure, .{ std.mem.span(dir), std.mem.span(served_at) });
}

fn downloadsConfigure(lib: *Library, arena: std.mem.Allocator, dir: []const u8, served_at: []const u8) !void {
    var r = try long.reader(lib, arena);
    defer release(lib, &r);
    try lib.writer.lock(lib.io());
    defer lib.writer.unlock(lib.io());
    try r.refresh();
    try download.configure(&r, arena, lib.now(), dir, served_at);
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

/// Long, on a connection of its own, waiting its turn to write: stops
/// keeping a title's, season's, or item's files, deleting those held here,
/// and forgets wanting them.
export fn cq_download_remove(lib: *Library, key: [*:0]const u8) c_int {
    return status(lib, downloadRemove, .{std.mem.span(key)});
}

fn downloadRemove(lib: *Library, arena: std.mem.Allocator, key: []const u8) !void {
    var r = try long.reader(lib, arena);
    defer release(lib, &r);
    _ = try download.remove(lib.io(), arena, &r, &lib.writer, lib.now(), key);
    lib.fetching.recheck();
}

/// Any thread: stops reconciling under way (`cq_reconcile`), the file
/// coming at its next mebibyte (kept, to resume) and none after, as before
/// leaving the library; the next `cq_reconcile` runs afresh.
export fn cq_reconcile_stop(lib: *Library) void {
    lib.fetching.stop();
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
    lib.fetching.recheck();
}

/// What a download size is of (`cq_download_kind`): `key`'s own files, or
/// a series' choice of episodes (see `download.Choice`).
const ChoiceKind = enum(c_int) { own = 0, next = 1, all = 2 };

/// A choice to size (`cq_download_choice`): `count` is the next N's N.
pub const SizeChoice = extern struct { kind: c_int, count: c_uint };

/// What downloading would come to, as a JSON array, one object per choice
/// of `count`: `choice` (as `cq_download_next` takes it, empty for `key`'s
/// own), `size` (bytes, of all its files), and `needed` (of those, what
/// isn't here yet). A choice is a series' (`key` its title's), or `key`'s
/// own files (a title's, season's, or item's) in `quality` (null: the one
/// most have).
export fn cq_download_sizes(lib: *Library, key: [*:0]const u8, choices: ?[*]const SizeChoice, count: usize, quality: ?[*:0]const u8) ?[*:0]u8 {
    return json(lib, downloadSizes, .{ std.mem.span(key), choices, count, span(quality) });
}

fn downloadSizes(lib: *Library, arena: std.mem.Allocator, key: []const u8, choices: ?[*]const SizeChoice, count: usize, quality: ?[]const u8) ![]const download.SizeReport {
    const given: []const SizeChoice = if (count == 0) &.{} else if (choices) |c| c[0..count] else return error.InvalidArgument;
    const parsed = try arena.alloc(?download.Choice, given.len);
    for (given, parsed) |c, *p| p.* = try choiceOf(c);
    return download.sizesOf(try lib.main(), arena, key, parsed, quality);
}

/// A C choice as the core's: null for the key's own files.
fn choiceOf(c: SizeChoice) !?download.Choice {
    return switch (try capi.enumFrom(ChoiceKind, c.kind)) {
        .own => null,
        .all => .all,
        // As `Choice.parse` reads a count.
        .next => if (c.count == 0) error.InvalidArgument else .{ .next = @min(c.count, 1000) },
    };
}

/// This device's downloads, as a JSON object (see `download.Report`).
export fn cq_downloads(lib: *Library) ?[*:0]u8 {
    return json(lib, downloads, .{});
}

fn downloads(lib: *Library, arena: std.mem.Allocator) !download.Report {
    return download.report(lib.io(), try lib.main(), arena, .{
        .running = lib.reconciling.load(.acquire),
        .done_mb = lib.downloaded_mb.load(.monotonic),
        .total_mb = lib.download_mb.load(.monotonic),
        .no_room = lib.no_room.load(.monotonic),
        .fetching = &lib.fetching,
    });
}

/// Long, on a connection of its own: brings this device's downloads in line
/// with what it keeps (see download.zig), fetching, recording, and deleting
/// as it goes; if one runs already, asks it to run again and returns at
/// once, with `busy`. Returns a JSON object with `fetched`, `kept`,
/// `deleted`, `failed`, `no_room` (files left to keep the floor free),
/// `held` (files waiting while downloads are held), `error`, and `busy`.
export fn cq_reconcile(lib: *Library) ?[*:0]u8 {
    return json(lib, reconcile, .{});
}

const ReconciledJson = struct { fetched: usize = 0, kept: usize = 0, deleted: usize = 0, failed: usize = 0, no_room: usize = 0, held: usize = 0, @"error": ?[]const u8 = null, busy: bool = false };

/// Holds downloads back, as while a stream plays, which they'd slow: none
/// begins, though one under way finishes. Any thread.
export fn cq_downloads_hold(lib: *Library) void {
    lib.hold.store(true, .release);
}

/// Lets downloads held back go; then `cq_reconcile` fetches what waited.
/// Any thread.
export fn cq_downloads_resume(lib: *Library) void {
    lib.hold.store(false, .release);
}

fn reconcile(lib: *Library, arena: std.mem.Allocator) !ReconciledJson {
    lib.reconcile_again.store(true, .release);
    if (lib.reconciling.swap(true, .acq_rel)) return .{ .busy = true };
    errdefer lib.reconciling.store(false, .release);
    lib.fetching.start();
    var r = try connection(lib, arena);
    defer release(lib, &r);
    var client: std.http.Client = .{ .allocator = gpa, .io = lib.io() };
    defer client.deinit();
    var out: ReconciledJson = .{};
    while (true) {
        // Again while asked again (a download wanted meanwhile), unless
        // stopped.
        while (!lib.fetching.stopping.load(.acquire) and lib.reconcile_again.swap(false, .acq_rel)) {
            try r.refresh();
            const done = try download.reconcile(lib.io(), gpa, arena, &client, &lib.racing, &r, &lib.writer, lib.now(), .{ .done = &lib.downloaded_mb, .total = &lib.download_mb, .fetching = &lib.fetching }, &lib.hold);
            out.fetched += done.fetched;
            out.kept = done.kept;
            out.deleted += done.deleted;
            out.failed = done.failed;
            out.no_room = done.no_room;
            lib.no_room.store(@intCast(@min(done.no_room, std.math.maxInt(u32))), .monotonic);
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

/// Adds a source by URL, as typed, with the prefix of names to skip (null
/// for the default); its files' quality is from their names until set.
export fn cq_repo_add(lib: *Library, target: [*:0]const u8, skip: ?[*:0]const u8) c_int {
    return status(lib, sourceAdd, .{ std.mem.span(target), span(skip) });
}

fn sourceAdd(lib: *Library, arena: std.mem.Allocator, target: []const u8, skip: ?[]const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    const r = try lib.main();
    var typed: std.ArrayList(u8) = .empty;
    try @import("../url.zig").escape(arena, &typed, std.mem.trim(u8, target, " \n"));
    if (!std.mem.endsWith(u8, typed.items, "/")) try typed.append(arena, '/');
    var layout: library.Layout = .{};
    if (skip) |v| layout.skip = v;
    _ = try library.addSource(r, lib.now(), typed.items, layout);
}

/// Sets the prefix of names a source's crawls skip, applied at the next.
export fn cq_repo_skip(lib: *Library, source: [*:0]const u8, skip: [*:0]const u8) c_int {
    return status(lib, sourceSkip, .{ std.mem.span(source), std.mem.span(skip) });
}

fn sourceSkip(lib: *Library, arena: std.mem.Allocator, source: []const u8, skip: []const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    _ = try library.setSkip(try lib.main(), arena, lib.now(), source, skip);
}

/// Takes a source's files' quality from their names. Copies move at the
/// next crawl.
export fn cq_repo_quality_from_names(lib: *Library, source: [*:0]const u8) c_int {
    return status(lib, sourceQuality, .{ std.mem.span(source), library.QualityFrom.names });
}

/// Takes a source's files' quality from the first folder within it.
export fn cq_repo_quality_from_folder(lib: *Library, source: [*:0]const u8) c_int {
    return status(lib, sourceQuality, .{ std.mem.span(source), library.QualityFrom.folder });
}

/// Names one quality for all a source's files (e.g., a HandBrake preset's).
export fn cq_repo_quality_named(lib: *Library, source: [*:0]const u8, name: [*:0]const u8) c_int {
    return status(lib, sourceQuality, .{ std.mem.span(source), library.QualityFrom{ .named = std.mem.span(name) } });
}

/// Writes where the source's quality comes from: its value, written alike.
fn sourceQuality(lib: *Library, arena: std.mem.Allocator, source: []const u8, quality: library.QualityFrom) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    _ = try library.setQualityFrom(try lib.main(), arena, lib.now(), source, quality);
}

/// Names a source (by ID) as its owner calls it, as a folder's own name its
/// address had to put otherwise; only its owner's naming counts. Writes
/// nothing if it's named so already.
export fn cq_repo_name(lib: *Library, source: [*:0]const u8, name: [*:0]const u8) c_int {
    return status(lib, sourceName, .{ std.mem.span(source), std.mem.span(name) });
}

fn sourceName(lib: *Library, arena: std.mem.Allocator, source: []const u8, name: []const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    try library.setSourceName(try lib.main(), arena, lib.now(), source, name);
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
