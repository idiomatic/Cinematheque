//! The web client, served at the root by `serve` (unless `--no-web`): a
//! page (and its script and style, embedded) that sets up a library,
//! browses it, plays from its sources, and changes its settings, and the
//! JSON it asks for under `/api/`. A browser has no keys of its own, so it
//! acts as this device's person: its progress, watched marks, and lists
//! are theirs. Only a browser on this computer may (one at `localhost`, or
//! through an SSH tunnel), unless `serve --permissive` lets every browser
//! that reaches the port; others are told so.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const core = @import("core");
const Replica = core.replica.Replica;
const setup = @import("setup.zig");

const files = [_]struct { path: []const u8, type: []const u8, body: []const u8 }{
    .{ .path = "/", .type = "text/html; charset=utf-8", .body = @embedFile("web/index.html") },
    .{ .path = "/app.js", .type = "text/javascript; charset=utf-8", .body = @embedFile("web/app.js") },
    .{ .path = "/settings.js", .type = "text/javascript; charset=utf-8", .body = @embedFile("web/settings.js") },
    .{ .path = "/route.js", .type = "text/javascript; charset=utf-8", .body = @embedFile("web/route.js") },
    .{ .path = "/app.css", .type = "text/css; charset=utf-8", .body = @embedFile("web/app.css") },
    // The app's icon, at the sizes browsers' tabs show it (drawn by
    // apple/draw-icons.swift).
    .{ .path = "/favicon.ico", .type = "image/x-icon", .body = @embedFile("web/favicon.ico") },
};

pub const Web = struct {
    /// This device's data directory, whose identity and library change as
    /// one's created, joined, or left (with `state` held, and `seen` around
    /// each change, so a snapshot sees it whole).
    store: core.store.Store,
    /// The library, by its creator, if this device has one yet.
    creator: ?[32]u8,
    /// Held through setup's changes (a library created, joined, or left,
    /// and advertising); taken before `writer`, never after.
    state: Io.Mutex = .init,
    /// Held only to read or change `creator` and `store`'s identity, with
    /// nothing else taken meanwhile, so any task may take a snapshot.
    seen: Io.Mutex = .init,
    /// What lasts as long as serving: the store's own (opened again as the
    /// device leaves) and what it advertises.
    long: std.mem.Allocator,
    path: [:0]const u8,
    /// Whether every browser that reaches the port acts as this device's
    /// person, not only one on this computer (`serve --permissive`).
    permissive: bool = false,
    /// What serves, to advertise afresh as the library or names change.
    host: ?*core.host.Host = null,
    /// The folder `serve --media` shares, and its address, which settings
    /// may add as a source (no other folder, so a browser can't share one).
    media: ?struct { dir: []const u8, url: []const u8 } = null,
    /// Counted up as the computer's volumes change, for the server to build
    /// the media's `INDEX` afresh (`watchVolumes`).
    volumes: std.atomic.Value(u32) = .init(0),
    /// This device's offer to be added, as a new device, while setup shows
    /// its code (`offering`), answered at `/pair` on this port; with `state`
    /// held. Kept, not freed, once done, as an answer may still be using it.
    offer: core.pair.Offer = undefined,
    offering: bool = false,
    /// Refresh Library, run on a task of its own (`setup.keepRefreshed`).
    refreshing: setup.Refreshing = .{},
    /// Held around this device's own writes (progress, lists), one
    /// connection writing as the device at a time.
    writer: Io.Mutex = .init,
    /// Servers whose copies didn't answer lately, for copy racing.
    racing: core.race.Memory = .{},
    /// Devices that couldn't be reached when last synced with (a phone
    /// whose app is napping, as iOS suspends it, still advertised), said
    /// once, not at every sync, until they answer again.
    asleep: Asleep = .{},
    /// When a browser last changed something of this person's (in
    /// milliseconds), if it hasn't been synced since; else 0.
    changed: std.atomic.Value(i64) = .init(0),
    /// Whether a source's server has been unreachable for a cover yet, said
    /// once, so a page of placeholders without covers says why.
    unreachable_said: std.atomic.Value(bool) = .init(false),
    /// The name this device goes by on the network.
    host_name: []const u8 = "",

    /// Frees what serving gathered.
    pub fn deinit(w: *Web, gpa: std.mem.Allocator) void {
        w.asleep.deinit(gpa);
    }

    pub fn handler(w: *Web) core.serve.Handler {
        return .{ .context = w, .function = respond };
    }

    /// Who this device is, and its library, as of now.
    pub const Snapshot = struct { creator: [32]u8, identity: core.replica.Identity, own: []const u8 };

    /// This device's library and identity, or `error.NoLibrary`.
    pub fn snapshot(w: *Web, io: Io, arena: std.mem.Allocator) !Snapshot {
        try w.seen.lock(io);
        defer w.seen.unlock(io);
        return .{ .creator = w.creator orelse return error.NoLibrary, .identity = w.store.identity, .own = try w.store.serviceName(arena) };
    }

    /// While serving: a second after a browser's change, once changes stop,
    /// syncs with every device found nearby or added, so the person's other
    /// devices have it at once, as the apps' changes reach them, rather than
    /// when they next sync.
    pub fn keepInSync(w: *Web, io: Io, gpa: std.mem.Allocator) Io.Cancelable!void {
        while (true) {
            try io.sleep(.fromMilliseconds(500), .awake);
            const at = w.changed.load(.acquire);
            if (at == 0 or @as(i64, @intCast(now(io))) - at < 1000) continue;
            if (w.changed.cmpxchgStrong(at, 0, .acq_rel, .acquire) != null) continue;
            w.syncAll(io, gpa) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Removed => setup.leaveRemoved(w, io, gpa),
                else => std.log.warn("syncing after a change: {t}", .{err}),
            };
        }
    }

    /// Syncs with every device found or added; `error.Removed` if one says
    /// this device was removed from the library (see `setup.leaveRemoved`).
    pub fn syncAll(w: *Web, io: Io, gpa: std.mem.Allocator) !void {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var r = try open(w, io, gpa);
        defer r.close();
        // Found before writing, so looking holds up no page's writes.
        const found = try core.sync.everyDevice(io, arena, &r, (try w.snapshot(io, arena)).own);
        var client: http.Client = .{ .allocator = gpa, .io = io };
        defer client.deinit();
        // The writer taken for one device at a time, so a page's writes
        // (progress saved as it plays) wait out one exchange, not them all.
        for (found.urls) |u| {
            try w.writer.lock(io);
            defer w.writer.unlock(io);
            try r.refresh();
            if (core.sync.exchange(arena, &client, &r, u, now(io))) |_| {
                if (w.asleep.woke(io, u)) std.log.info("{s} answers again", .{u});
            } else |err| if (err == error.Removed) {
                // Told, under a member's signature, that this device was
                // removed: no use syncing with the rest.
                return error.Removed;
            } else if (!Asleep.unreachable_(err)) {
                std.log.warn("syncing with {s}: {t}", .{ u, err });
            } else if (w.asleep.fell(io, gpa, u)) {
                std.log.info("{s} can't be reached ({t}), as a phone or tablet whose app is napping can't; it's synced with when it answers again", .{ u, err });
            }
        }
    }

    /// While serving media: as the computer's volumes change (a drive
    /// plugged in or out under it), its `INDEX` is built afresh and it's
    /// crawled at once, so its copies are marked unavailable (one field),
    /// or available again, for every device. The mount table is read every 2 seconds, one small read
    /// however many drives, as `Io` has no way to wait on the kernel's
    /// notice of it.
    pub fn watchVolumes(w: *Web, io: Io, gpa: std.mem.Allocator) Io.Cancelable!void {
        var last = core.volumes.signature(io, gpa);
        while (true) {
            try io.sleep(.fromSeconds(2), .awake);
            const now_ = core.volumes.signature(io, gpa);
            if (now_ == last) continue;
            last = now_;
            _ = w.volumes.fetchAdd(1, .acq_rel);
            if (w.creator == null) continue;
            w.crawlMedia(io, gpa) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => std.log.warn("looking through the media: {t}", .{err}),
            };
            // Other devices told.
            w.changed.store(@intCast(now(io)), .release);
        }
    }

    /// Crawls this device's media, if it's a source, then describes what's
    /// new.
    fn crawlMedia(w: *Web, io: Io, gpa: std.mem.Allocator) !void {
        const media = w.media orelse return;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var r = try open(w, io, gpa);
        defer r.close();
        const source = for (try core.library.sources(&r, arena)) |s| {
            if (std.mem.eql(u8, s.url, media.url)) break s;
        } else return;
        var client: http.Client = .{ .allocator = gpa, .io = io };
        defer client.deinit();
        const stats = blk: {
            try w.writer.lock(io);
            defer w.writer.unlock(io);
            try r.refresh();
            break :blk try core.library.crawlSource(&r, io, arena, &client, now(io), source, 16);
        };
        const plan = try core.art.plan(&r, arena, &.{.{ .source = source, .entries = stats.entries }});
        _ = try core.art.run(io, &r, arena, &client, now(io), plan.jobs, .{ .workers = 16, .writer = &w.writer });
    }

};

fn respond(context: ?*anyopaque, io: Io, gpa: std.mem.Allocator, request: *http.Server.Request, peer: Io.net.IpAddress) anyerror!bool {
    const w: *Web = @ptrCast(@alignCast(context.?));
    const target = request.head.target;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    // Another device's sync, answered as this device is now, once it has a
    // library.
    if (std.mem.eql(u8, path, core.sync.path)) {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const now_is = w.snapshot(io, arena_state.allocator()) catch |err| switch (err) {
            error.NoLibrary => return false,
            else => |e| return e,
        };
        var sharing: core.sync.Sharing = .{ .path = w.path, .creator = now_is.creator, .identity = now_is.identity };
        const h = sharing.handler();
        return h.function(h.context, io, gpa, request, peer);
    }
    // A member's device adding this one, while it offers to be added.
    if (std.mem.eql(u8, path, core.pair.path) and w.offering) {
        const h = w.offer.handler();
        return h.function(h.context, io, gpa, request, peer);
    }
    const page = for (files) |f| {
        if (std.mem.eql(u8, path, f.path) or (std.mem.eql(u8, f.path, "/") and std.mem.eql(u8, path, "/index.html"))) break f;
    } else null;
    if (page == null and !std.mem.startsWith(u8, path, "/api/")) return false;
    // By an address no other site can take, so a site that rebinds its
    // name here is refused. The page itself, which holds nothing of the
    // library, opens from a link anywhere (an email's, say); what reads
    // the library or acts as this person is this page's own.
    if (!privateHostOf(request) or page == null and !fromThisPage(request)) {
        try request.respond("Forbidden", .{ .status = .forbidden, .extra_headers = &guarded });
        return true;
    }
    if (page) |f| {
        try request.respond(f.body, .{ .extra_headers = &([_]http.Header{
            .{ .name = "content-type", .value = f.type },
            .{ .name = "cache-control", .value = "no-cache" },
        } ++ guarded) });
        return true;
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const name = path["/api/".len..];
    // Where it stands, which any browser may ask, to be told what it may do.
    const attempt = if (std.mem.eql(u8, name, "status"))
        setup.status(w, io, gpa, arena, request, w.permissive or local(peer))
    else if (!w.permissive and !local(peer))
        error.NotLocal
    else if (setup.handles(name))
        setup.api(w, io, gpa, arena, request, name)
    else
        api(w, io, gpa, arena, request, name, query(target));
    attempt catch |err| {
        // An answer begun can't tell of a failure in its body: the
        // connection's dropped, its length unmet, so the browser knows.
        if (err == error.CutShort) return err;
        const status: http.Status = switch (err) {
            error.NoSuchTitle, error.NotFound => .not_found,
            error.Forbidden, error.NotLocal => .forbidden,
            error.NoLibrary, error.LibraryExists, error.Busy => .conflict,
            error.BadRequest, error.InvalidArgument, error.SyntaxError, error.UnexpectedEndOfInput, error.InvalidCharacter, error.Overflow => .bad_request,
            else => .internal_server_error,
        };
        try request.respond(@errorName(err), .{ .status = status, .extra_headers = &guarded });
    };
    return true;
}

/// What every answer of the web client's says: not to be framed by another
/// site's page, nor read as another type than it says.
const guarded = [_]http.Header{
    .{ .name = "x-frame-options", .value = "DENY" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
};

/// The devices that couldn't be reached, by their sync URLs.
const Asleep = struct {
    urls: std.StringHashMapUnmanaged(void) = .empty,
    lock: Io.Mutex = .init,

    /// Whether `err` says only that the device couldn't be reached.
    fn unreachable_(err: anyerror) bool {
        return switch (err) {
            error.ConnectionRefused, error.ConnectionTimedOut, error.Timeout, error.HostUnreachable, error.NetworkUnreachable, error.UnknownHostName, error.ConnectionResetByPeer => true,
            else => false,
        };
    }

    /// Notes `url` unreachable; whether it wasn't already.
    fn fell(a: *Asleep, io: Io, gpa: std.mem.Allocator, url: []const u8) bool {
        a.lock.lockUncancelable(io);
        defer a.lock.unlock(io);
        if (a.urls.contains(url)) return false;
        const key = gpa.dupe(u8, url) catch return true;
        a.urls.put(gpa, key, {}) catch gpa.free(key);
        return true;
    }

    fn deinit(a: *Asleep, gpa: std.mem.Allocator) void {
        var keys = a.urls.keyIterator();
        while (keys.next()) |k| gpa.free(k.*);
        a.urls.deinit(gpa);
    }

    /// Notes `url` reached; whether it had been unreachable.
    fn woke(a: *Asleep, io: Io, url: []const u8) bool {
        a.lock.lockUncancelable(io);
        defer a.lock.unlock(io);
        return a.urls.remove(url);
    }
};

/// Whether a request comes from this computer: its loopback address, as a
/// browser on it reaches it by `localhost`, or an SSH tunnel's end does.
/// (A proxy on this computer passing others' requests on would be taken for
/// it, so serve none.)
fn local(peer: Io.net.IpAddress) bool {
    return switch (peer) {
        .ip4 => |a| a.bytes[0] == 127,
        .ip6 => |a| std.mem.eql(u8, &a.bytes, &loopback6) or
            (std.mem.eql(u8, a.bytes[0..12], &mapped4) and a.bytes[12] == 127),
    };
}

/// `::1`, and the prefix of an IPv4 address mapped into IPv6.
const loopback6 = [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
const mapped4 = [12]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };

test "only this computer's own addresses are local" {
    try std.testing.expect(local(.{ .ip4 = .loopback(8008) }));
    try std.testing.expect(local(try Io.net.IpAddress.parse("::1", 8008)));
    try std.testing.expect(local(try Io.net.IpAddress.parse("::ffff:127.0.0.1", 8008)));
    try std.testing.expect(!local(try Io.net.IpAddress.parse("192.168.1.20", 8008)));
    try std.testing.expect(!local(try Io.net.IpAddress.parse("fe80::1", 8008)));
}

pub fn header(request: *http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

/// Whether a request is by a host no other site can be (an address,
/// `localhost`, a `.local` or single-label name, or this computer's).
fn privateHostOf(request: *http.Server.Request) bool {
    return privateHost(header(request, "host") orelse return false);
}

/// Whether a request is this page's own (by a private host, as
/// `privateHostOf` checks first): from this origin, and a change (a POST)
/// JSON, which a page elsewhere can't send without asking first.
fn fromThisPage(request: *http.Server.Request) bool {
    const host = header(request, "host") orelse return false;
    if (header(request, "sec-fetch-site")) |site| if (!std.mem.eql(u8, site, "same-origin") and !std.mem.eql(u8, site, "none")) return false;
    if (header(request, "origin")) |origin| {
        const rest = if (std.mem.startsWith(u8, origin, "http://")) origin[7..] else if (std.mem.startsWith(u8, origin, "https://")) origin[8..] else return false;
        if (!std.ascii.eqlIgnoreCase(rest, host)) return false;
    }
    if (request.head.method == .POST) {
        const t = request.head.content_type orelse return false;
        if (!std.mem.startsWith(u8, t, "application/json")) return false;
    }
    return true;
}

fn privateHost(host_port: []const u8) bool {
    if (std.mem.startsWith(u8, host_port, "[")) return true; // an IPv6 address
    const name = host_port[0 .. std.mem.lastIndexOfScalar(u8, host_port, ':') orelse host_port.len];
    if (name.len == 0) return false;
    if (std.Io.net.Ip4Address.parse(name, 0)) |_| return true else |_| {}
    if (std.ascii.eqlIgnoreCase(name, "localhost") or std.mem.indexOfScalar(u8, name, '.') == null) return true;
    if (name.len > 6 and std.ascii.eqlIgnoreCase(name[name.len - 6 ..], ".local")) return true;
    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const own = std.posix.gethostname(&buf) catch return false;
    return std.ascii.eqlIgnoreCase(name, own);
}

test "the web client answers only its own page" {
    try std.testing.expect(privateHost("192.168.1.20:8008"));
    try std.testing.expect(privateHost("[fe80::1]:8008"));
    try std.testing.expect(privateHost("localhost:8008"));
    try std.testing.expect(privateHost("art.local:8008"));
    try std.testing.expect(privateHost("art:8008"));
    try std.testing.expect(!privateHost("rebind.skynet.example:8008"));
    try std.testing.expect(!privateHost(":8008"));
}

fn query(target: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return "";
    return target[q + 1 ..];
}

/// A query's parameter, percent-decoded, if given.
fn param(arena: std.mem.Allocator, q: []const u8, name: []const u8) !?[]const u8 {
    var pairs = std.mem.splitScalar(u8, q, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        const value = try arena.dupe(u8, pair[eq + 1 ..]);
        for (value) |*c| if (c.* == '+') {
            c.* = ' ';
        };
        return core.url.decode(value) catch error.BadRequest;
    }
    return null;
}

pub fn open(w: *Web, io: Io, gpa: std.mem.Allocator) !Replica {
    // Enough for its service name, which `snapshot` gives too.
    var buffer: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const now_is = try w.snapshot(io, fixed.allocator());
    return Replica.open(gpa, io, w.path, now_is.creator, now_is.identity);
}

pub fn now(io: Io) u64 {
    return @intCast(Io.Timestamp.now(io, .real).toMilliseconds());
}

fn api(w: *Web, io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, request: *http.Server.Request, name: []const u8, q: []const u8) !void {
    const get = request.head.method == .GET or request.head.method == .HEAD;
    if (get and std.mem.eql(u8, name, "tiles")) {
        var r = try open(w, io, gpa);
        defer r.close();
        return sendJson(arena, request, .{
            .tiles = try core.views.tiles(&r, arena),
            .lists = try core.lists.lists(&r, arena),
        });
    }
    if (get and std.mem.eql(u8, name, "title")) {
        var r = try open(w, io, gpa);
        defer r.close();
        return sendJson(arena, request, try core.views.title(&r, arena, try param(arena, q, "key") orelse return error.BadRequest));
    }
    if (get and std.mem.eql(u8, name, "cover")) return cover(w, io, gpa, arena, request, q);
    if (get and std.mem.eql(u8, name, "file")) return file(w, io, gpa, arena, request, q);
    if (request.head.method != .POST) return error.NotFound;

    var body_buf: [4096]u8 = undefined;
    const body = try (try request.readerExpectContinue(&body_buf)).allocRemaining(arena, .limited(64 * 1024));
    if (std.mem.eql(u8, name, "race")) {
        const urls = try std.json.parseFromSliceLeaky([]const []const u8, arena, body, .{});
        var r = try open(w, io, gpa);
        const allowed = try withinSources(&r, arena, urls);
        r.close();
        if (!allowed) return error.Forbidden;
        return sendJson(arena, request, try core.race.order(io, gpa, arena, &w.racing, urls, now(io)));
    }
    if (std.mem.eql(u8, name, "lost")) {
        const lost = try std.json.parseFromSliceLeaky(struct { url: []const u8 }, arena, body, .{});
        var r = try open(w, io, gpa);
        const allowed = try withinSources(&r, arena, &.{lost.url});
        r.close();
        if (!allowed) return error.Forbidden;
        try w.racing.lost(io, gpa, lost.url, now(io));
        return sendJson(arena, request, true);
    }

    // An episode's title, description, and duration, read from its file,
    // as the apps describe a season's as it's shown: the writer taken only
    // to write them, not as the file's read.
    if (std.mem.eql(u8, name, "describe")) {
        const p = try std.json.parseFromSliceLeaky(struct { item: []const u8 }, arena, body, .{});
        var r = try open(w, io, gpa);
        defer r.close();
        var client: http.Client = .{ .allocator = gpa, .io = io };
        defer client.deinit();
        // Shared metadata, which needs no hurry to reach other devices.
        try core.art.describeItem(&r, arena, &client, &w.writer, now(io), p.item);
        return sendJson(arena, request, true);
    }

    // This person's own writes.
    try w.writer.lock(io);
    defer w.writer.unlock(io);
    var r = try open(w, io, gpa);
    defer r.close();
    // A new list's ID, to answer with.
    var created: ?[]const u8 = null;
    if (std.mem.eql(u8, name, "progress")) {
        const p = try std.json.parseFromSliceLeaky(struct { item: []const u8, position: u64, duration: u64 }, arena, body, .{});
        try core.library.setProgress(&r, arena, now(io), p.item, p.position, p.duration);
    } else if (std.mem.eql(u8, name, "watched")) {
        const p = try std.json.parseFromSliceLeaky(struct { item: []const u8, watched: bool }, arena, body, .{});
        if (p.watched) try core.library.markWatched(&r, arena, now(io), p.item) else try core.library.markUnwatched(&r, arena, now(io), p.item);
    } else if (std.mem.eql(u8, name, "listed")) {
        const p = try std.json.parseFromSliceLeaky(struct { list: []const u8, key: []const u8, on: bool }, arena, body, .{});
        try core.lists.setListed(&r, arena, now(io), p.list, p.key, p.on);
    } else if (std.mem.eql(u8, name, "list-create")) {
        const p = try std.json.parseFromSliceLeaky(struct { name: []const u8 }, arena, body, .{});
        created = try core.lists.create(io, &r, arena, now(io), p.name);
    } else if (std.mem.eql(u8, name, "list-rename")) {
        const p = try std.json.parseFromSliceLeaky(struct { id: []const u8, name: []const u8 }, arena, body, .{});
        try core.lists.rename(&r, arena, now(io), p.id, p.name);
    } else if (std.mem.eql(u8, name, "list-remove")) {
        const p = try std.json.parseFromSliceLeaky(struct { id: []const u8 }, arena, body, .{});
        try core.lists.remove(&r, arena, now(io), p.id);
    } else if (std.mem.eql(u8, name, "list-share")) {
        // Every member's to see, or this person's alone again.
        const p = try std.json.parseFromSliceLeaky(struct { id: []const u8, on: bool }, arena, body, .{});
        if (p.on) try core.lists.share(io, &r, arena, now(io), p.id) else try core.lists.stopSharing(io, &r, arena, now(io), p.id);
    } else return error.NotFound;
    // This person's, for their other devices.
    w.changed.store(@intCast(now(io)), .release);
    if (created) |id| return sendJson(arena, request, id);
    return sendJson(arena, request, true);
}

pub fn sendJson(arena: std.mem.Allocator, request: *http.Server.Request, value: anytype) !void {
    const text = try core.json.valueAlloc(arena, value);
    try request.respond(text, .{ .extra_headers = &([_]http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "cache-control", .value = "no-store" },
    } ++ guarded) });
}

/// Whether every URL is within one of the library's sources (of its
/// origin, below its path), so the server fetches (or asks) only what the
/// library already names.
fn withinSources(r: *Replica, arena: std.mem.Allocator, urls: []const []const u8) !bool {
    const sources = try core.library.sources(r, arena);
    for (urls) |u| {
        for (sources) |s| {
            if (core.url.within(s.at() orelse continue, u)) break;
        } else return false;
    }
    return true;
}

/// The largest cover a page asks for.
const max_cover_bytes = 8 << 20;

/// A cover, read from its byte range of a file on a source (which a page
/// couldn't read itself, sources answering other sites' scripts nothing),
/// cached by the browser for good: its URL names what changes it.
fn cover(w: *Web, io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, request: *http.Server.Request, q: []const u8) !void {
    const u = try param(arena, q, "url") orelse return error.BadRequest;
    const offset = try std.fmt.parseInt(u64, try param(arena, q, "offset") orelse return error.BadRequest, 10);
    const length = try std.fmt.parseInt(u64, try param(arena, q, "length") orelse return error.BadRequest, 10);
    if (length == 0 or length > max_cover_bytes) return error.BadRequest;
    {
        var r = try open(w, io, gpa);
        defer r.close();
        if (!try withinSources(&r, arena, &.{u})) return error.Forbidden;
    }
    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    // Within a minute, as the apps' covers are, so a source that answers a
    // byte at a time holds no connection for long.
    const image = try core.deadline.within(io, 60 * 1000, fetchCover, .{ w, arena, &client, u, offset, length });
    try request.respond(image, .{ .extra_headers = &([_]http.Header{
        .{ .name = "content-type", .value = imageType(image) },
        .{ .name = "cache-control", .value = "max-age=31536000, immutable" },
    } ++ guarded) });
}

/// A cover's bytes: its range of the file at `u`.
fn fetchCover(w: *Web, arena: std.mem.Allocator, client: *http.Client, u: []const u8, offset: u64, length: u64) ![]const u8 {
    const last = std.math.add(u64, offset, length - 1) catch return error.BadRequest;
    const range = try std.fmt.allocPrint(arena, "bytes={d}-{d}", .{ offset, last });
    // No redirect: it could lead anywhere the server likes.
    var req = client.request(.GET, try std.Uri.parse(u), .{ .redirect_behavior = .not_allowed, .extra_headers = &.{.{ .name = "range", .value = range }} }) catch |err| {
        if (!w.unreachable_said.swap(true, .acq_rel)) {
            const host = if (std.Uri.parse(u)) |uri| (if (uri.host) |h| h.percent_encoded else "?") else |_| "?";
            std.log.warn("covers from {s} can't be had: {t}{s}", .{ host, err, if (err == error.HostUnreachable and @import("builtin").os.tag == .macos)
                " (on macOS, start it from an app allowed Local Network, in System Settings › Privacy & Security, such as Terminal; some apps' built-in terminals aren't, even when the app is)"
            else
                "" });
        }
        return err;
    };
    defer req.deinit();
    try req.sendBodiless();
    var redirect: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect);
    if (response.head.status != .partial_content and response.head.status != .ok) return error.NotFound;
    var transfer: [64 * 1024]u8 = undefined;
    const bytes = try response.reader(&transfer).allocRemaining(arena, .limited(max_cover_bytes + 1));
    // A whole file, from a server that ignored the range: its cover's part.
    if (response.head.status == .ok and bytes.len > length) {
        if (offset > bytes.len or length > bytes.len - offset) return error.NotFound;
        return bytes[offset..][0..length];
    }
    return bytes;
}

/// A copy's file, saved by the browser on its own computer (through this
/// device, as the browser may be unable to reach the source): as it comes,
/// with its name, from a range if asked (resuming), within the library's
/// sources only.
fn file(w: *Web, io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, request: *http.Server.Request, q: []const u8) !void {
    const u = try param(arena, q, "url") orelse return error.BadRequest;
    {
        var r = try open(w, io, gpa);
        defer r.close();
        if (!try withinSources(&r, arena, &.{u})) return error.Forbidden;
    }
    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var relay: core.download.Relay = .{};
    try relay.open(io, arena, &client, u, header(request, "range"));
    defer relay.deinit();
    var headers: std.ArrayList(http.Header) = .empty;
    try headers.appendSlice(arena, &.{
        .{ .name = "content-type", .value = "application/octet-stream" },
        .{ .name = "content-disposition", .value = try disposition(arena, u) },
        .{ .name = "accept-ranges", .value = "bytes" },
        .{ .name = "cache-control", .value = "no-store" },
    });
    if (relay.content_range) |range| try headers.append(arena, .{ .name = "content-range", .value = range });
    try headers.appendSlice(arena, &guarded);
    var buffer: [64 * 1024]u8 = undefined;
    var body = try request.respondStreaming(&buffer, .{
        .content_length = relay.length,
        .respond_options = .{ .status = relay.status, .extra_headers = headers.items },
    });
    relay.pump(io, &body.writer) catch |err| return cutShort(err);
    body.end() catch |err| return cutShort(err);
}

/// A streamed answer's failure, once begun: `error.CutShort` (but for
/// cancellation), so it isn't answered again.
fn cutShort(err: anyerror) anyerror {
    return if (err == error.Canceled) err else error.CutShort;
}

/// Saving a file as its name in the source (`Alien (1979).m4v`): plainly,
/// for browsers that take only that, its unsafe characters `_`; and in
/// full, percent-encoded (RFC 6266).
fn disposition(arena: std.mem.Allocator, u: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(u);
    const path = try uri.path.toRawMaybeAlloc(arena);
    const last = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.BadRequest) + 1 ..];
    if (last.len == 0) return error.BadRequest;
    const decoded = core.url.decode(try arena.dupe(u8, last)) catch return error.BadRequest;
    const plain = try arena.dupe(u8, decoded);
    for (plain) |*c| if (c.* < 0x20 or c.* >= 0x7f or c.* == '"' or c.* == '\\' or c.* == '/') {
        c.* = '_';
    };
    var encoded: std.ArrayList(u8) = .empty;
    for (decoded) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "!#$&+-.^_`|~", c) != null) try encoded.append(arena, c) else try encoded.print(arena, "%{X:0>2}", .{c});
    }
    return std.fmt.allocPrint(arena, "attachment; filename=\"{s}\"; filename*=UTF-8''{s}", .{ plain, encoded.items });
}

test "a saved file's name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings(
        "attachment; filename=\"Am__lie \"; filename*=UTF-8''Am%C3%A9lie%20",
        try disposition(arena_state.allocator(), "http://nas/Movies/Am%C3%A9lie%20"),
    );
}

fn imageType(bytes: []const u8) []const u8 {
    if (std.mem.startsWith(u8, bytes, "\x89PNG")) return "image/png";
    if (std.mem.startsWith(u8, bytes, "\xff\xd8")) return "image/jpeg";
    return "application/octet-stream";
}
