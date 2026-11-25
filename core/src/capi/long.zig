//! The C interface (see ../capi.zig): long operations, each on a connection of its own.

const std = @import("std");
const Io = std.Io;
const capi = @import("../capi.zig");
const library = @import("../library.zig");
const art = @import("../art.zig");
const sync = @import("../sync.zig");
const replica_ = @import("../replica.zig");
const Replica = replica_.Replica;
const gpa = capi.gpa;
const Library = capi.Library;
const json = capi.json;
const status = capi.status;
const CrawlJson = capi.CrawlJson;
const SyncJson = capi.SyncJson;

pub fn connection(lib: *Library, arena: std.mem.Allocator) !Replica {
    _ = lib.connections.fetchAdd(1, .seq_cst);
    errdefer _ = lib.connections.fetchSub(1, .seq_cst);
    if (lib.leaving.load(.seq_cst)) return error.Busy;
    return lib.store.openReplica(arena);
}

/// A connection of its own for reading, on any thread, once there's a
/// library: counted first, so leaving (which then refuses) can't take the
/// library away between the check and the opening.
pub fn reader(lib: *Library, arena: std.mem.Allocator) !Replica {
    _ = lib.connections.fetchAdd(1, .seq_cst);
    defer _ = lib.connections.fetchSub(1, .seq_cst);
    if (!lib.has_library.load(.seq_cst)) return error.NoLibrary;
    return connection(lib, arena);
}

/// Closes a connection `connection` opened.
pub fn release(lib: *Library, r: *Replica) void {
    r.close();
    _ = lib.connections.fetchSub(1, .seq_cst);
}

/// How often refreshes not asked for (at launch, on a timer) look in the
/// library's sources, for every device: every `hours` (1, 3, 24, 168), or
/// 0 for only when asked (Refresh Library), sparing a NAS's disks.
export fn cq_crawl_every(lib: *Library, hours: c_int) c_int {
    return status(lib, crawlEvery, .{@as(u64, @intCast(@max(hours, 0)))});
}

fn crawlEvery(lib: *Library, _: std.mem.Allocator, hours: u64) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    try library.setCrawlEvery(try lib.main(), lib.now(), hours);
}

/// Long: crawls every source, committing each as it's crawled, then
/// describes what's new (covers and metadata) with concurrent workers,
/// committing as it goes and taking prioritized titles (`cq_prioritize`)
/// first. Returns a JSON array of objects with `url`, `files`, `titles`,
/// and `error` (null, or why its crawl failed), one per source, with its
/// times and counts (see `CrawlJson`).
export fn cq_crawl(lib: *Library) ?[*:0]u8 {
    return json(lib, crawlAll, .{});
}

/// Long: as `cq_crawl`, but listing every directory afresh, reusing none
/// of the last crawl's listings, so files rewritten in place (retagged),
/// whose directories' times don't change, are seen (Refresh Library
/// Fully).
export fn cq_crawl_full(lib: *Library) ?[*:0]u8 {
    return json(lib, crawlAllAfresh, .{});
}

/// Long: as `cq_crawl`, for one source (by ID or URL), as a Mac crawls its
/// own folder as it comes or goes (a drive plugged in or unplugged), so
/// its copies are known unavailable at once (one field), or available
/// again, rather than at the next refresh.
export fn cq_crawl_source(lib: *Library, source: [*:0]const u8) ?[*:0]u8 {
    return json(lib, crawlOne, .{std.mem.span(source)});
}

fn crawlOne(lib: *Library, arena: std.mem.Allocator, which: []const u8) ![]const CrawlJson {
    var r = try connection(lib, arena);
    defer release(lib, &r);
    return crawlAndDescribe(lib, arena, &r, &.{try library.findSource(&r, arena, which)}, .{});
}

/// Long: as `cq_crawl`, but for a refresh not asked for (at launch, or on
/// a timer), once synced: skips sources a device crawled within the
/// library's interval (`cq_crawl_every`), give or take a 24th of it
/// (`skipped` `lately` in their results), whose copies syncing brought; or
/// all of them, if it's Manually (`manual`).
export fn cq_crawl_due(lib: *Library) ?[*:0]u8 {
    return json(lib, crawlDue, .{});
}

fn crawlAll(lib: *Library, arena: std.mem.Allocator) ![]const CrawlJson {
    var r = try connection(lib, arena);
    defer release(lib, &r);
    return crawlAndDescribe(lib, arena, &r, try library.sources(&r, arena), .{});
}

fn crawlAllAfresh(lib: *Library, arena: std.mem.Allocator) ![]const CrawlJson {
    var r = try connection(lib, arena);
    defer release(lib, &r);
    return crawlAndDescribe(lib, arena, &r, try library.sources(&r, arena), .{ .listing = .afresh });
}

/// Those no device crawled within the library's interval, unless it's
/// Manually; the rest told as skipped, in their places.
fn crawlDue(lib: *Library, arena: std.mem.Allocator) ![]const CrawlJson {
    var r = try connection(lib, arena);
    defer release(lib, &r);
    return crawlAndDescribe(lib, arena, &r, try library.sources(&r, arena), .{ .due = try library.due(&r, lib.io(), arena, lib.now()) });
}

/// Crawls `list`'s sources, then describes what's new; a result per source.
fn crawlAndDescribe(lib: *Library, arena: std.mem.Allocator, r: *Replica, list: []const library.Source, options: art.Options) ![]const CrawlJson {
    defer lib.steps.finish();
    var with = options;
    with.writer = &lib.writer;
    with.steps = &lib.steps;
    with.priority = &lib.priority;
    const refreshed = try art.crawlAndDescribe(lib.io(), gpa, r, arena, list, with);
    const out = try arena.alloc(CrawlJson, list.len);
    for (refreshed.sources, out) |result, *o| {
        o.* = .{ .url = result.source.url };
        switch (result.outcome) {
            .skipped => |why| o.skipped = why,
            .failed => |err| o.@"error" = @errorName(err),
            .crawled => |s| {
                o.files = s.ingest.files;
                o.titles = s.ingest.titles_added;
                o.crawl_ms = s.crawl_ms;
                o.total_ms = s.total_ms;
                o.requests = s.crawl.requests;
                o.reused = s.crawl.skipped;
                o.changed = s.ingest.copies_added + s.ingest.copies_changed + s.ingest.copies_removed;
            },
        }
    }
    return out;
}

/// Sets the titles to describe first, `count` title keys (e.g., the tiles
/// on screen); any thread.
export fn cq_prioritize(lib: *Library, title_keys: ?[*]const [*:0]const u8, count: usize) c_int {
    return status(lib, prioritize, .{ title_keys, count });
}

fn prioritize(lib: *Library, arena: std.mem.Allocator, title_keys: ?[*]const [*:0]const u8, count: usize) !void {
    try lib.priority.set(lib.io(), try capi.spans(arena, title_keys, count));
}

/// A number that changes when another connection (a long operation) has
/// committed changes, so the app knows to reload; -1 on failure.
export fn cq_data_version(lib: *Library) i64 {
    const r = &(lib.replica orelse return -1);
    return r.db.scalar("PRAGMA data_version") catch -1;
}

/// Long: syncs with every device of this library found or added, as a
/// JSON array of objects with `url`, `name` (as it advertised itself),
/// `new` (operations won), `sent` (operations pushed), and `error`.
export fn cq_sync(lib: *Library) ?[*:0]u8 {
    return json(lib, syncEvery, .{});
}

/// Long: as `cq_sync`, with the device at `url` alone.
export fn cq_sync_with(lib: *Library, url: [*:0]const u8) ?[*:0]u8 {
    return json(lib, syncWith, .{std.mem.span(url)});
}

/// Long: as `cq_sync`, but with the devices the last such sync found
/// nearby (and those added), without looking for two seconds again; if
/// none has, it looks. For a change to reach other devices at once.
export fn cq_sync_known(lib: *Library) ?[*:0]u8 {
    return json(lib, syncKnown, .{});
}

/// The devices of this library a sync last found nearby.
pub const Known = struct {
    mutex: Io.Mutex = .init,
    arena: ?std.heap.ArenaAllocator = null,
    devices: sync.Devices = .{ .urls = &.{}, .names = .empty },

    pub fn save(k: *Known, io: Io, list: sync.Devices) !void {
        var next: std.heap.ArenaAllocator = .init(gpa);
        errdefer next.deinit();
        const copy = try dupe(next.allocator(), list);
        k.mutex.lockUncancelable(io);
        defer k.mutex.unlock(io);
        k.deinit();
        k.arena = next;
        k.devices = copy;
    }

    /// A copy in `arena`, or null if no sync has looked yet.
    pub fn get(k: *Known, io: Io, arena: std.mem.Allocator) !?sync.Devices {
        k.mutex.lockUncancelable(io);
        defer k.mutex.unlock(io);
        if (k.arena == null) return null;
        return try dupe(arena, k.devices);
    }

    pub fn dupe(arena: std.mem.Allocator, list: sync.Devices) !sync.Devices {
        const urls = try arena.alloc([]const u8, list.urls.len);
        var names: std.StringHashMapUnmanaged([]const u8) = .empty;
        for (list.urls, urls) |u, *out| {
            out.* = try arena.dupe(u8, u);
            if (list.names.get(u)) |n| try names.put(arena, out.*, try arena.dupe(u8, n));
        }
        return .{ .urls = urls, .names = names };
    }

    pub fn deinit(k: *Known) void {
        if (k.arena) |*a| a.deinit();
        k.arena = null;
    }
};

fn syncEvery(lib: *Library, arena: std.mem.Allocator) ![]const SyncJson {
    // Devices are counted once they're found.
    lib.steps.start(.syncing, 0);
    defer lib.steps.finish();
    var r = try connection(lib, arena);
    defer release(lib, &r);
    return exchangeAll(lib, arena, &r, try sync.withAdded(arena, &r, try lookNearby(lib, arena, &r)));
}

fn syncKnown(lib: *Library, arena: std.mem.Allocator) ![]const SyncJson {
    lib.steps.start(.syncing, 0);
    defer lib.steps.finish();
    var r = try connection(lib, arena);
    defer release(lib, &r);
    const seen = (try lib.known.get(lib.io(), arena)) orelse try lookNearby(lib, arena, &r);
    return exchangeAll(lib, arena, &r, try sync.withAdded(arena, &r, seen));
}

fn syncWith(lib: *Library, arena: std.mem.Allocator, url: []const u8) ![]const SyncJson {
    lib.steps.start(.syncing, 0);
    defer lib.steps.finish();
    var r = try connection(lib, arena);
    defer release(lib, &r);
    return exchangeAll(lib, arena, &r, try sync.oneDevice(arena, url));
}

/// The devices of this library found nearby, remembered for `cq_sync_known`.
fn lookNearby(lib: *Library, arena: std.mem.Allocator, r: *Replica) !sync.Devices {
    const fresh = try sync.nearby(lib.io(), arena, r, try lib.store.serviceName(arena));
    try lib.known.save(lib.io(), fresh);
    return fresh;
}

/// Syncs with `devices`, found before writing, so looking (however long the
/// network makes it) holds up no one else's writes; taking the writer for
/// one device at a time, caught up with others' writes first, so a quick
/// change waits out one exchange, not all.
fn exchangeAll(lib: *Library, arena: std.mem.Allocator, r: *Replica, devices: sync.Devices) ![]const SyncJson {
    var client: std.http.Client = .{ .allocator = gpa, .io = lib.io() };
    defer client.deinit();
    const out = try arena.alloc(SyncJson, devices.urls.len);
    lib.steps.start(.syncing, devices.urls.len);
    for (devices.urls, out) |u, *o| {
        defer lib.steps.step();
        try lib.writer.lock(lib.io());
        defer lib.writer.unlock(lib.io());
        try r.refresh();
        const exchanged = sync.exchange(arena, &client, r, u, lib.now()) catch |err| {
            o.* = .{ .url = u, .name = devices.names.get(u), .new = 0, .@"error" = @errorName(err) };
            continue;
        };
        o.* = .{ .url = u, .name = devices.names.get(u), .new = exchanged.stats.won, .sent = exchanged.sent, .@"error" = null };
    }
    return out;
}

/// Long: reads an item's metadata (an episode's title, description, and
/// duration) from its first copy, if an MP4.
export fn cq_describe(lib: *Library, item_key: [*:0]const u8) c_int {
    return status(lib, describeItem, .{std.mem.span(item_key)});
}

fn describeItem(lib: *Library, arena: std.mem.Allocator, item_key: []const u8) !void {
    var r = try connection(lib, arena);
    defer release(lib, &r);
    var client: std.http.Client = .{ .allocator = gpa, .io = lib.io() };
    defer client.deinit();
    try art.describeItem(&r, arena, &client, &lib.writer, lib.now(), item_key);
}
