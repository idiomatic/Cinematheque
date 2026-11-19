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
const span = capi.span;
const CrawlJson = capi.CrawlJson;
const SyncJson = capi.SyncJson;
const HeardJson = capi.HeardJson;
const steps = capi.steps;

pub fn connection(lib: *Library, arena: std.mem.Allocator) !Replica {
    return lib.store.openReplica(arena);
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
    return json(lib, crawlAll, .{false});
}

/// Long: as `cq_crawl`, but for a refresh not asked for (at launch, or on
/// a timer), once synced: skips sources a device crawled within the
/// library's interval (`cq_crawl_every`), give or take a 24th of it
/// (`lately` in their results), whose copies syncing brought; or all of
/// them, if it's Manually (`manual`).
export fn cq_crawl_due(lib: *Library) ?[*:0]u8 {
    return json(lib, crawlAll, .{true});
}

fn crawlAll(lib: *Library, arena: std.mem.Allocator, due: bool) ![]const CrawlJson {
    var r = try connection(lib, arena);
    defer r.close();
    var client: std.http.Client = .{ .allocator = gpa, .io = lib.io() };
    defer client.deinit();
    const list = try library.sources(&r, arena);
    const out = try arena.alloc(CrawlJson, list.len);
    const every = try library.crawlEvery(&r, arena);
    const window = if (every) |hours| library.crawlWindow(lib.io(), hours) else 0;
    var crawled: std.ArrayList(art.Crawled) = .empty;
    lib.steps.start(.crawling, list.len);
    defer lib.steps.finish();
    for (list, out) |rp, *o| {
        defer lib.steps.step();
        if (rp.managed) {
            o.* = .{ .url = rp.url, .files = 0, .titles = 0, .covers = 0, .@"error" = null };
            continue;
        }
        if (due and every == null) {
            o.* = .{ .url = rp.url, .files = 0, .titles = 0, .covers = 0, .@"error" = null, .manual = true };
            continue;
        }
        if (due and rp.crawledLately(lib.now(), window)) {
            o.* = .{ .url = rp.url, .files = 0, .titles = 0, .covers = 0, .@"error" = null, .lately = true };
            continue;
        }
        try lib.writer.lock(lib.io());
        defer lib.writer.unlock(lib.io());
        try r.refresh();
        const s = library.crawlSource(&r, lib.io(), arena, &client, lib.now(), rp, 16) catch |err| {
            o.* = .{ .url = rp.url, .files = 0, .titles = 0, .covers = 0, .@"error" = @errorName(err) };
            continue;
        };
        o.* = .{
            .url = rp.url,
            .files = s.ingest.files,
            .titles = s.ingest.titles_added,
            .covers = 0,
            .@"error" = null,
            .crawl_ms = s.crawl_ms,
            .total_ms = s.total_ms,
            .requests = s.crawl.requests,
            .reused = s.crawl.skipped,
            .changed = s.ingest.copies_added + s.ingest.copies_changed + s.ingest.copies_removed,
        };
        try crawled.append(arena, .{ .source = rp, .entries = s.entries });
    }
    const plan = try art.plan(&r, arena, crawled.items);
    lib.steps.start(.describing, plan.jobs.len);
    _ = try art.run(lib.io(), &r, arena, &client, lib.now(), plan.jobs, .{
        .workers = 16,
        .priority = &lib.priority,
        .writer = &lib.writer,
        .done = &lib.steps.done,
    });
    return out;
}

/// Sets the titles to describe first, a JSON array of title keys (e.g., the
/// tiles on screen); any thread.
export fn cq_prioritize(lib: *Library, title_keys: [*:0]const u8) c_int {
    return status(lib, prioritize, .{std.mem.span(title_keys)});
}

fn prioritize(lib: *Library, arena: std.mem.Allocator, title_keys: []const u8) !void {
    const keys = try std.json.parseFromSliceLeaky([]const []const u8, arena, title_keys, .{});
    try lib.priority.set(lib.io(), keys);
}

/// A number that changes when another connection (a long operation) has
/// committed changes, so the app knows to reload; -1 on failure.
export fn cq_data_version(lib: *Library) i64 {
    const r = &(lib.replica orelse return -1);
    return r.db.scalar("PRAGMA data_version") catch -1;
}

/// Long: pulls from the device at `target`, or else from every device of this
/// library found or added, as a JSON array of objects with `url`, `new`
/// (operations won), and `error`.
export fn cq_sync(lib: *Library, target: ?[*:0]const u8) ?[*:0]u8 {
    return json(lib, syncAll, .{ span(target), false });
}

/// Long: as `cq_sync` with every device, but with those the last such sync
/// found nearby (and those added), without looking for two seconds again;
/// if none has, it looks. For a change to reach other devices at once.
export fn cq_sync_known(lib: *Library) ?[*:0]u8 {
    return json(lib, syncAll, .{ null, true });
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

fn syncAll(lib: *Library, arena: std.mem.Allocator, target: ?[]const u8, known: bool) ![]const SyncJson {
    // Devices are counted once they're found.
    lib.steps.start(.syncing, 0);
    defer lib.steps.finish();
    try lib.writer.lock(lib.io());
    defer lib.writer.unlock(lib.io());
    var r = try connection(lib, arena);
    defer r.close();
    const reachable = if (target != null)
        try sync.reachable(lib.io(), arena, &r, try lib.store.serviceName(arena), target)
    else found: {
        const seen = (if (known) try lib.known.get(lib.io(), arena) else null) orelse looked: {
            const fresh = try sync.nearby(lib.io(), arena, &r, try lib.store.serviceName(arena));
            try lib.known.save(lib.io(), fresh);
            break :looked fresh;
        };
        break :found try sync.withAdded(arena, &r, seen);
    };
    const urls = reachable.urls;
    const names = reachable.names;
    var client: std.http.Client = .{ .allocator = gpa, .io = lib.io() };
    defer client.deinit();
    const out = try arena.alloc(SyncJson, urls.len);
    lib.steps.start(.syncing, urls.len);
    for (urls, out) |u, *o| {
        defer lib.steps.step();
        const exchanged = sync.exchange(arena, &client, &r, u, lib.now()) catch |err| {
            o.* = .{ .url = u, .name = names.get(u), .new = 0, .@"error" = @errorName(err) };
            continue;
        };
        o.* = .{ .url = u, .name = names.get(u), .new = exchanged.stats.won, .sent = exchanged.sent, .@"error" = null };
    }
    return out;
}


/// The last sync this device served, while serving, as JSON: `device` (the
/// key of the device that asked), its `name` if it has one, how many
/// `operations` it was sent, and when (`at`, in milliseconds since the
/// epoch); or null if none yet.
export fn cq_served(lib: *Library) ?[*:0]u8 {
    return json(lib, served, .{});
}

/// The last push this device took, while serving, as `cq_served` tells of a
/// sync: from which device, and how many of its operations won; an app
/// reloads when it changes.
export fn cq_received(lib: *Library) ?[*:0]u8 {
    return json(lib, receivedPush, .{});
}

fn receivedPush(lib: *Library, arena: std.mem.Allocator) !?HeardJson {
    return lib.received.json(lib, arena);
}

fn served(lib: *Library, arena: std.mem.Allocator) !?HeardJson {
    return lib.served.json(lib, arena);
}

/// Long: reads an item's metadata (an episode's title, description, and
/// duration) from its first copy, if an MP4.
export fn cq_describe(lib: *Library, item_key: [*:0]const u8) c_int {
    return status(lib, describeItem, .{std.mem.span(item_key)});
}

fn describeItem(lib: *Library, arena: std.mem.Allocator, item_key: []const u8) !void {
    try lib.writer.lock(lib.io());
    defer lib.writer.unlock(lib.io());
    var r = try connection(lib, arena);
    defer r.close();
    var client: std.http.Client = .{ .allocator = gpa, .io = lib.io() };
    defer client.deinit();
    try art.describeItem(&r, arena, &client, lib.now(), item_key);
}
