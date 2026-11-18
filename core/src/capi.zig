//! A C interface to the library, for apps in other languages (Swift, for the
//! Apple players). Results are JSON strings, freed with `cq_free`; on
//! failure, functions return null (or -1) and `cq_error` says why. See
//! include/cinematheque.h.
//!
//! Threads: functions on a library, except those marked as long, belong to
//! one thread (the app's main one), on the library's own connection. Long
//! ones (crawling, syncing, describing) may run on any thread, each on a
//! connection of its own. Only one connection writes as this device at a
//! time: long ones wait for each other, and other writes fail with `Busy`
//! while one runs, but for playheads and watchlists, which don't need to.

const std = @import("std");
const Io = std.Io;
const library = @import("library.zig");
const art = @import("art.zig");
const thumbhash = @import("thumbhash.zig");
const store_ = @import("store.zig");
const sync = @import("sync.zig");
const discover = @import("discover.zig");
const replica_ = @import("replica.zig");
const Replica = replica_.Replica;

const gpa = std.heap.c_allocator;

threadlocal var last_error: [256:0]u8 = @splat(0);

fn fail(err: anyerror) void {
    _ = std.fmt.bufPrintSentinel(&last_error, "{t}", .{err}, 0) catch {};
}

const Library = struct {
    threaded: Io.Threaded,
    arena_state: std.heap.ArenaAllocator,
    store: store_.Store,
    /// The main thread's connection, once there's a library.
    replica: ?Replica = null,
    /// Held while a connection writes as this device.
    writer: Io.Mutex = .init,
    /// Titles to describe first while a crawl runs, such as those on screen.
    priority: art.Priority = .{},

    fn io(lib: *Library) Io {
        return lib.threaded.io();
    }

    fn now(lib: *Library) u64 {
        return @intCast(Io.Timestamp.now(lib.io(), .real).toMilliseconds());
    }

    /// The main connection, caught up with other connections' writes.
    fn main(lib: *Library) !*Replica {
        const r = &(lib.replica orelse return error.NoLibrary);
        try r.refresh();
        return r;
    }
};

export fn cq_error() [*:0]const u8 {
    return &last_error;
}

/// Renders a ThumbHash in base64 as RGBA pixels (not premultiplied) into
/// `rgba`, which holds 32×32×4 bytes, 32 pixels on its longer side; sets
/// `width` and `height`. Returns 0, or -1 if the hash isn't one. Any thread.
export fn cq_thumbhash(hash_base64: [*:0]const u8, rgba: *[thumbhash.max_pixels * 4]u8, width: *c_int, height: *c_int) c_int {
    var bytes: [thumbhash.max_len]u8 = undefined;
    const text = std.mem.span(hash_base64);
    const len = std.base64.standard.Decoder.calcSizeForSlice(text) catch return -1;
    if (len > bytes.len) return -1;
    std.base64.standard.Decoder.decode(bytes[0..len], text) catch return -1;
    const r = thumbhash.decode(bytes[0..len], rgba) catch return -1;
    width.* = @intCast(r.width);
    height.* = @intCast(r.height);
    return 0;
}

export fn cq_free(text: ?[*:0]u8) void {
    const t = text orelse return;
    gpa.free(std.mem.span(t));
}

/// Opens the peer's home `peer_home`; if null, `$CINEMATHEQUE_HOME`, or else
/// the default. It may not hold a library yet (see `cq_status`).
export fn cq_open(peer_home: ?[*:0]const u8) ?*Library {
    return open(peer_home) catch |err| {
        fail(err);
        return null;
    };
}

fn open(peer_home: ?[*:0]const u8) !*Library {
    const lib = try gpa.create(Library);
    errdefer gpa.destroy(lib);
    lib.* = .{ .threaded = .init(gpa, .{}), .arena_state = .init(gpa), .store = undefined };
    errdefer lib.threaded.deinit();
    errdefer lib.arena_state.deinit();
    const arena = lib.arena_state.allocator();
    const dir = if (peer_home orelse std.c.getenv("CINEMATHEQUE_HOME")) |d| try arena.dupe(u8, std.mem.span(d)) else blk: {
        const home = std.c.getenv("HOME") orelse return error.NoHome;
        const xdg = std.c.getenv("XDG_DATA_HOME");
        break :blk try store_.defaultHome(arena, std.mem.span(home), if (xdg) |x| std.mem.span(x) else null);
    };
    lib.store = try store_.Store.open(lib.io(), gpa, arena, dir);
    _ = lib.store.founder(arena) catch return lib;
    lib.replica = try lib.store.openReplica(arena);
    return lib;
}

export fn cq_close(lib: ?*Library) void {
    const l = lib orelse return;
    if (l.replica) |*r| r.close();
    l.priority.deinit();
    l.arena_state.deinit();
    l.threaded.deinit();
    gpa.destroy(l);
}

fn stringify(value: anytype) ![*:0]u8 {
    const text = try std.json.Stringify.valueAlloc(gpa, value, .{});
    defer gpa.free(text);
    return (try gpa.dupeSentinel(u8, text, 0)).ptr;
}

/// Runs `f(lib, arena, args...)`, returning its JSON, or null on failure.
fn json(lib: *Library, comptime f: anytype, args: anytype) ?[*:0]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const value = @call(.auto, f, .{ lib, arena_state.allocator() } ++ args) catch |err| {
        fail(err);
        return null;
    };
    return stringify(value) catch |err| {
        fail(err);
        return null;
    };
}

/// Runs `f(lib, arena, args...)`, returning 0, or -1 on failure.
fn status(lib: *Library, comptime f: anytype, args: anytype) c_int {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    @call(.auto, f, .{ lib, arena_state.allocator() } ++ args) catch |err| {
        fail(err);
        return -1;
    };
    return 0;
}

fn span(text: ?[*:0]const u8) ?[]const u8 {
    return if (text) |t| std.mem.span(t) else null;
}

const CoverJson = struct { url: []const u8, offset: u64, length: u64, stamp: []const u8 };
const MemberJson = struct { key: []const u8, founder: bool, you: bool };
const CrawlJson = struct { url: []const u8, files: usize, titles: usize, covers: usize, @"error": ?[]const u8 };
const SyncJson = struct { url: []const u8, new: usize, @"error": ?[]const u8 };
const TileJson = struct { key: []const u8, name: []const u8, year: ?u16, kind: []const u8, season: ?u16, cover: ?CoverJson, thumb: ?[]const u8, watched: bool, progress: f64 };
const StatusJson = struct { user: []const u8, library: ?[]const u8, founder: ?[]const u8, members: usize };

// Identity and membership.

/// This peer, as JSON: `user` (its user's key), `library` (the library's ID,
/// or null if it has none yet), `founder`, and `members` (how many).
export fn cq_status(lib: *Library) ?[*:0]u8 {
    return json(lib, getStatus, .{});
}

fn getStatus(lib: *Library, arena: std.mem.Allocator) !StatusJson {
    const user = try arena.dupe(u8, &std.fmt.bytesToHex(try lib.store.user(), .lower));
    const r = lib.main() catch return .{ .user = user, .library = null, .founder = null, .members = 0 };
    return .{
        .user = user,
        .library = try arena.dupe(u8, &std.fmt.bytesToHex(r.library, .lower)),
        .founder = try arena.dupe(u8, &std.fmt.bytesToHex(r.founder, .lower)),
        .members = (try r.members(arena)).len,
    };
}

/// This user's secret, which links another of the user's devices, as a
/// JSON string.
export fn cq_secret(lib: *Library) ?[*:0]u8 {
    return json(lib, getSecret, .{});
}

fn getSecret(lib: *Library, arena: std.mem.Allocator) ![]const u8 {
    return arena.dupe(u8, &lib.store.userSecret());
}

/// Makes this device act as the user whose secret it is, before it has a
/// library.
export fn cq_link(lib: *Library, secret: [*:0]const u8) c_int {
    return status(lib, link, .{std.mem.span(secret)});
}

fn link(lib: *Library, arena: std.mem.Allocator, secret: []const u8) !void {
    if (lib.replica != null) return error.LibraryExists;
    try lib.store.link(arena, secret);
}

/// Creates a library, founded by this user (`founder` null), or joins the
/// one `founder` founded.
export fn cq_found(lib: *Library, founder: ?[*:0]const u8) c_int {
    return status(lib, found, .{span(founder)});
}

fn found(lib: *Library, arena: std.mem.Allocator, founder: ?[]const u8) !void {
    if (lib.replica != null) return error.LibraryExists;
    const key = if (founder) |f| try store_.parseKey(std.mem.trim(u8, f, " \n")) else try lib.store.user();
    try lib.store.setFounder(arena, key);
    lib.replica = try lib.store.openReplica(lib.arena_state.allocator());
}

/// The members, as a JSON array of objects with `key`, `founder`, and `you`.
export fn cq_members(lib: *Library) ?[*:0]u8 {
    return json(lib, members, .{});
}

fn members(lib: *Library, arena: std.mem.Allocator) ![]const MemberJson {
    const r = try lib.main();
    const me = try lib.store.user();
    const list = try r.members(arena);
    const out = try arena.alloc(MemberJson, list.len);
    for (list, out) |m, *o| o.* = .{
        .key = try arena.dupe(u8, &std.fmt.bytesToHex(m, .lower)),
        .founder = std.mem.eql(u8, &m, &r.founder),
        .you = std.mem.eql(u8, &m, &me),
    };
    return out;
}

/// Adds (nonzero `add`) or removes a member, by user key.
export fn cq_member(lib: *Library, key: [*:0]const u8, add: c_int) c_int {
    return status(lib, member, .{ std.mem.span(key), add != 0 });
}

fn member(lib: *Library, _: std.mem.Allocator, key: []const u8, add: bool) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    const r = try lib.main();
    const user = try store_.parseKey(std.mem.trim(u8, key, " \n"));
    if (add) try r.addMember(lib.now(), user) else try r.removeMember(lib.now(), user);
}

// Repositories.

/// The repositories, as a JSON array of objects with `id`, `url`,
/// `rendition`, `skip`, and `copies`.
export fn cq_repos(lib: *Library) ?[*:0]u8 {
    return json(lib, repos, .{});
}

const RepoJson = struct { id: []const u8, url: []const u8, rendition: []const u8, skip: []const u8, copies: i64 };

fn repos(lib: *Library, arena: std.mem.Allocator) ![]const RepoJson {
    const r = try lib.main();
    const list = try library.repositories(r, arena);
    const out = try arena.alloc(RepoJson, list.len);
    for (list, out) |rp, *o| o.* = .{
        .id = try arena.dupe(u8, &rp.id),
        .url = rp.url,
        .rendition = rp.layout.rendition,
        .skip = rp.layout.skip,
        .copies = try library.copies(r, arena, rp),
    };
    return out;
}

/// Adds a repository by URL, as typed, with its rendition and the prefix of
/// names to skip (each null for the default).
export fn cq_repo_add(lib: *Library, target: [*:0]const u8, rendition: ?[*:0]const u8, skip: ?[*:0]const u8) c_int {
    return status(lib, repoAdd, .{ std.mem.span(target), span(rendition), span(skip) });
}

fn repoAdd(lib: *Library, arena: std.mem.Allocator, target: []const u8, rendition: ?[]const u8, skip: ?[]const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    const r = try lib.main();
    var typed: std.ArrayList(u8) = .empty;
    try @import("url.zig").escape(arena, &typed, std.mem.trim(u8, target, " \n"));
    if (!std.mem.endsWith(u8, typed.items, "/")) try typed.append(arena, '/');
    var layout: library.Layout = .{};
    if (rendition) |v| layout.rendition = v;
    if (skip) |v| layout.skip = v;
    _ = try library.addRepository(r, lib.now(), typed.items, layout);
}

/// Changes a repository's settings, those not null.
export fn cq_repo_set(lib: *Library, repo: [*:0]const u8, rendition: ?[*:0]const u8, skip: ?[*:0]const u8) c_int {
    return status(lib, repoSet, .{ std.mem.span(repo), span(rendition), span(skip) });
}

fn repoSet(lib: *Library, arena: std.mem.Allocator, repo: []const u8, rendition: ?[]const u8, skip: ?[]const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    _ = try library.setRepository(try lib.main(), arena, lib.now(), repo, rendition, skip);
}

/// Removes a repository, by ID or URL, and the copies it held.
export fn cq_repo_remove(lib: *Library, repo: [*:0]const u8) c_int {
    return status(lib, repoRemove, .{std.mem.span(repo)});
}

fn repoRemove(lib: *Library, arena: std.mem.Allocator, repo: []const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    _ = try library.removeRepository(try lib.main(), arena, lib.now(), repo);
}

// Long operations, each on a connection of its own.

fn connection(lib: *Library, arena: std.mem.Allocator) !Replica {
    return lib.store.openReplica(arena);
}

/// Long: crawls every repository, committing each as it's crawled, then
/// describes what's new (covers and metadata) with concurrent workers,
/// committing as it goes and taking prioritized titles (`cq_prioritize`)
/// first. Returns a JSON array of objects with `url`, `files`, `titles`,
/// and `error` (null, or why its crawl failed), one per repository.
export fn cq_crawl(lib: *Library) ?[*:0]u8 {
    return json(lib, crawlAll, .{});
}

fn crawlAll(lib: *Library, arena: std.mem.Allocator) ![]const CrawlJson {
    var r = try connection(lib, arena);
    defer r.close();
    var client: std.http.Client = .{ .allocator = gpa, .io = lib.io() };
    defer client.deinit();
    const list = try library.repositories(&r, arena);
    const out = try arena.alloc(CrawlJson, list.len);
    var crawled: std.ArrayList(art.Crawled) = .empty;
    for (list, out) |rp, *o| {
        try lib.writer.lock(lib.io());
        defer lib.writer.unlock(lib.io());
        try r.refresh();
        const s = library.crawlRepository(&r, lib.io(), arena, &client, lib.now(), rp, 16) catch |err| {
            o.* = .{ .url = rp.url, .files = 0, .titles = 0, .covers = 0, .@"error" = @errorName(err) };
            continue;
        };
        o.* = .{ .url = rp.url, .files = s.ingest.files, .titles = s.ingest.titles_added, .covers = 0, .@"error" = null };
        try crawled.append(arena, .{ .repo = rp, .entries = s.entries });
    }
    const plan = try art.plan(&r, arena, crawled.items);
    _ = try art.run(lib.io(), &r, arena, &client, lib.now(), plan.jobs, .{
        .workers = 16,
        .priority = &lib.priority,
        .writer = &lib.writer,
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

/// Long: pulls from the peer at `target`, or else from every peer of this
/// library found or added, as a JSON array of objects with `url`, `new`
/// (operations won), and `error`.
export fn cq_sync(lib: *Library, target: ?[*:0]const u8) ?[*:0]u8 {
    return json(lib, syncAll, .{span(target)});
}

fn syncAll(lib: *Library, arena: std.mem.Allocator, target: ?[]const u8) ![]const SyncJson {
    try lib.writer.lock(lib.io());
    defer lib.writer.unlock(lib.io());
    var r = try connection(lib, arena);
    defer r.close();
    var urls: std.ArrayList([]const u8) = .empty;
    if (target) |t| {
        try urls.append(arena, if (std.mem.endsWith(u8, t, "/sync")) t else try std.mem.concat(arena, u8, &.{ std.mem.trimEnd(u8, t, "/"), "/sync" }));
    } else {
        const mine = std.fmt.bytesToHex(r.library, .lower);
        const own = try std.fmt.allocPrint(arena, "cinematheque-{s}", .{std.fmt.bytesToHex(try lib.store.user(), .lower)[0..8]});
        for (try discover.browse(lib.io(), arena, 2000)) |s| {
            if (s.host.len == 0 or std.mem.eql(u8, s.name, own)) continue;
            if (!std.mem.eql(u8, s.get("library") orelse "", &mine)) continue;
            try urls.append(arena, try std.fmt.allocPrint(arena, "http://{s}:{d}{s}", .{ s.host, s.port, s.get("path") orelse "/sync" }));
        }
        for (try r.localKeys(arena, "peer:")) |k| try urls.append(arena, k["peer:".len..]);
    }
    var client: std.http.Client = .{ .allocator = gpa, .io = lib.io() };
    defer client.deinit();
    const out = try arena.alloc(SyncJson, urls.items.len);
    for (urls.items, out) |u, *o| {
        const stats = sync.pull(arena, &client, &r, u, lib.now()) catch |err| {
            o.* = .{ .url = u, .new = 0, .@"error" = @errorName(err) };
            continue;
        };
        o.* = .{ .url = u, .new = stats.won, .@"error" = null };
    }
    return out;
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

// Browsing.

/// The grid's tiles, as a JSON array of objects with `key` (the title's),
/// `name`, `year`, `kind` (`movie` or `series`), `season` (a series', or
/// null), and `cover` (null, or `url`, `offset`, `length`, and `stamp`, a
/// byte range to fetch, and what changes when it does), `thumb` (null, or
/// the cover's placeholder, a ThumbHash in base64, for `cq_thumbhash`), and
/// this user's `watched` (every item) and `progress` (0 to 1).
export fn cq_tiles(lib: *Library) ?[*:0]u8 {
    return json(lib, tiles, .{});
}


fn tiles(lib: *Library, arena: std.mem.Allocator) ![]const TileJson {
    const r = try lib.main();
    const bases = try repoBases(r, arena);
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
    };
    return out;
}

fn repoBases(r: *Replica, arena: std.mem.Allocator) !std.StringHashMapUnmanaged(library.Repository) {
    var bases: std.StringHashMapUnmanaged(library.Repository) = .empty;
    for (try library.repositories(r, arena)) |rp| try bases.put(arena, try arena.dupe(u8, &rp.id), rp);
    return bases;
}

fn coverJson(arena: std.mem.Allocator, bases: std.StringHashMapUnmanaged(library.Repository), c: art.Cover) !?CoverJson {
    const rp = bases.get(c.repository) orelse return null;
    return .{ .url = try art.fileUrl(arena, rp.url, c.path), .offset = c.offset, .length = c.length, .stamp = c.stamp };
}

/// One title, as a JSON object with `key`, `name`, `year`, `aliasOf`,
/// `aliases`, `fields` (its metadata, e.g., `description` and `genre`),
/// `covers` (by field, `art` or `art:s01`...), and `items`, each with its
/// `key`, `fields` (e.g., an episode's `title`), this user's `position`,
/// `duration` (milliseconds), and `watched`, and `renditions`, each with
/// its `label`, `name` (as its repositories give it), and `copies`: `url`
/// (ready to play), `size`, `mtime`, and `repository`. Null if there's no
/// such title.
export fn cq_title(lib: *Library, key: [*:0]const u8) ?[*:0]u8 {
    return json(lib, title, .{std.mem.span(key)});
}

const Copy = struct { url: []const u8, size: u64, mtime: []const u8, repository: []const u8 };
const RenditionJson = struct { label: []const u8, name: []const u8, copies: []const Copy };
const ItemJson = struct { key: []const u8, fields: std.json.ArrayHashMap([]const u8), renditions: []const RenditionJson, position: u64, duration: u64, watched: bool };

fn title(lib: *Library, arena: std.mem.Allocator, key: []const u8) !struct {
    key: []const u8,
    name: []const u8,
    year: ?u16,
    aliasOf: ?[]const u8,
    aliases: []const []const u8,
    fields: std.json.ArrayHashMap([]const u8),
    covers: std.json.ArrayHashMap(CoverJson),
    items: []const ItemJson,
} {
    const r = try lib.main();
    const d = try library.detail(r, arena, key) orelse return error.NoSuchTitle;
    const bases = try repoBases(r, arena);
    const items = try arena.alloc(ItemJson, d.items.items.len);
    for (d.items.items, items) |item, *io| {
        const renditions = try arena.alloc(RenditionJson, item.renditions.items.len);
        for (item.renditions.items, renditions) |rn, *ro| {
            const copies = try arena.alloc(Copy, rn.holdings.items.len);
            var name = rn.label;
            for (rn.holdings.items, copies) |h, *c| {
                const rp = bases.get(h.repository);
                c.* = .{ .url = if (rp) |b| try art.fileUrl(arena, b.url, h.path) else "", .size = h.size, .mtime = h.mtime, .repository = h.repository };
                // The rendition's name as its repositories give it.
                if (rp) |b| if (b.layout.rendition.len > 0) {
                    name = b.layout.rendition;
                };
            }
            ro.* = .{ .label = rn.label, .name = name, .copies = copies };
        }
        io.* = .{
            .key = item.key,
            .fields = .{ .map = item.fields },
            .renditions = renditions,
            .position = item.playhead.position_ms,
            .duration = item.playhead.duration_ms,
            .watched = item.playhead.watched,
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

// This user's private data.

/// Records this user's playhead in an item (a title's key and an item's,
/// e.g., `t/m/alien/1979/v/-`).
export fn cq_set_playhead(lib: *Library, item_key: [*:0]const u8, position_ms: u64, duration_ms: u64) c_int {
    return status(lib, setPlayhead, .{ std.mem.span(item_key), position_ms, duration_ms });
}

fn setPlayhead(lib: *Library, arena: std.mem.Allocator, item_key: []const u8, position_ms: u64, duration_ms: u64) !void {
    const r = try privateWriter(lib);
    defer if (r.locked) lib.writer.unlock(lib.io());
    try library.setPlayhead(r.replica, arena, lib.now(), item_key, position_ms, duration_ms);
}

/// Marks an item watched (nonzero) or not.
export fn cq_set_watched(lib: *Library, item_key: [*:0]const u8, watched: c_int) c_int {
    return status(lib, setWatched, .{ std.mem.span(item_key), watched != 0 });
}

fn setWatched(lib: *Library, arena: std.mem.Allocator, item_key: []const u8, watched: bool) !void {
    const r = try privateWriter(lib);
    defer if (r.locked) lib.writer.unlock(lib.io());
    try library.setWatched(r.replica, arena, lib.now(), item_key, watched);
}

/// The titles on this user's watchlist, as a JSON array of title keys.
export fn cq_watchlist(lib: *Library) ?[*:0]u8 {
    return json(lib, getWatchlist, .{});
}

fn getWatchlist(lib: *Library, arena: std.mem.Allocator) ![]const []const u8 {
    return art.watchlist(try lib.main(), arena);
}

/// Adds a title to this user's watchlist (nonzero `on`), or removes it.
export fn cq_set_watchlisted(lib: *Library, title_key: [*:0]const u8, on: c_int) c_int {
    return status(lib, setWatchlisted, .{ std.mem.span(title_key), on != 0 });
}

fn setWatchlisted(lib: *Library, arena: std.mem.Allocator, title_key: []const u8, on: bool) !void {
    const r = try privateWriter(lib);
    defer if (r.locked) lib.writer.unlock(lib.io());
    try art.setWatchlisted(r.replica, arena, lib.now(), title_key, on);
}

/// The main connection, for private writes, which need the writer lock only
/// for the device's first (whose private stream's certificate is public).
fn privateWriter(lib: *Library) !struct { replica: *Replica, locked: bool } {
    const r = try lib.main();
    if (r.private_seq > 0) return .{ .replica = r, .locked = false };
    if (!lib.writer.tryLock()) return error.Busy;
    try r.refresh();
    return .{ .replica = r, .locked = true };
}
