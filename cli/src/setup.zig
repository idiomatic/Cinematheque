//! The web client's setup and settings (see web.zig): creating a library or
//! joining one, and what the Mac's Settings change: names, people, devices
//! (adding one by its code), sources, how often they're crawled, addresses
//! added, refreshing, and leaving. Only a browser on this computer reaches
//! these, or every browser with `serve --permissive`.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const core = @import("core");
const lib = core.library;
const web = @import("web.zig");
const Web = web.Web;
const Replica = core.replica.Replica;

const names = [_][]const u8{
    "setup-create",  "setup-join",    "setup-join-stop",    "settings",       "nearby",         "pair",
    "name-person",   "name-device",   "member-remove",      "device-remove",  "source-add",     "source-add-media",
    "source-remove", "unavailable-remove", "crawl-every",   "refresh",
    "refresh-fully", "leave",
};

/// Whether `name` is one of setup's or settings' calls.
pub fn handles(name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Refresh Library, as it runs on a task of its own (`keepRefreshed`), and
/// how it went, for settings to show.
pub const Refreshing = struct {
    asked: std.atomic.Value(Asked) = .init(.none),
    phase: std.atomic.Value(Phase) = .init(.idle),
    done: std.atomic.Value(u32) = .init(0),
    total: std.atomic.Value(u32) = .init(0),
    /// How the last one went, in words; held by `said_lock`.
    said: [256]u8 = undefined,
    said_len: usize = 0,
    said_lock: Io.Mutex = .init,

    const Asked = enum(u8) { none, refresh, fully };
    pub const Phase = enum(u8) { idle, syncing, crawling, describing };

    fn say(r: *Refreshing, io: Io, comptime format: []const u8, args: anytype) void {
        r.said_lock.lockUncancelable(io);
        defer r.said_lock.unlock(io);
        r.said_len = if (std.fmt.bufPrint(&r.said, format, args)) |text| text.len else |_| 0;
    }

    fn told(r: *Refreshing, io: Io, arena: std.mem.Allocator) ![]const u8 {
        r.said_lock.lockUncancelable(io);
        defer r.said_lock.unlock(io);
        return arena.dupe(u8, r.said[0..r.said_len]);
    }
};

/// While serving: runs Refresh Library whenever settings ask: syncing with
/// every device first (as the apps do), then crawling every source (but
/// devices' downloads), afresh if asked, and describing what's new.
pub fn keepRefreshed(w: *Web, io: Io, gpa: std.mem.Allocator) Io.Cancelable!void {
    while (true) {
        try io.sleep(.fromMilliseconds(300), .awake);
        const asked = w.refreshing.asked.swap(.none, .acq_rel);
        if (asked == .none) continue;
        defer w.refreshing.phase.store(.idle, .release);
        refresh(w, io, gpa, asked == .fully) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Removed => leaveRemoved(w, io, gpa),
            else => w.refreshing.say(io, "Refreshing failed: {t}", .{err}),
        };
    }
}

fn refresh(w: *Web, io: Io, gpa: std.mem.Allocator, fully: bool) !void {
    const state = &w.refreshing;
    state.phase.store(.syncing, .release);
    try w.syncAll(io, gpa);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r = try web.open(w, io, gpa);
    defer r.close();
    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const sources = try lib.sources(&r, arena);
    state.phase.store(.crawling, .release);
    state.done.store(0, .release);
    state.total.store(@intCast(sources.len), .release);
    var crawled: std.ArrayList(core.art.Crawled) = .empty;
    var files: usize = 0;
    var failed: usize = 0;
    for (sources) |rp| {
        defer _ = state.done.fetchAdd(1, .acq_rel);
        if (rp.managed) continue;
        // The writer held for each source's crawl, as the apps hold it, so
        // a page's writes wait out one source, not all of them.
        try w.writer.lock(io);
        defer w.writer.unlock(io);
        try r.refresh();
        const crawler = if (fully) &lib.crawlSourceAfresh else &lib.crawlSource;
        const s = crawler(&r, io, arena, &client, web.now(io), rp, 16) catch |err| {
            if (err == error.Canceled) return err;
            std.log.warn("crawling {s}: {t}", .{ rp.url, err });
            failed += 1;
            continue;
        };
        files += s.ingest.files;
        try crawled.append(arena, .{ .source = rp, .entries = s.entries });
    }
    const plan = try core.art.plan(&r, arena, crawled.items);
    state.phase.store(.describing, .release);
    state.done.store(0, .release);
    state.total.store(@intCast(plan.jobs.len), .release);
    _ = try core.art.run(io, &r, arena, &client, web.now(io), plan.jobs, .{ .writer = &w.writer, .done = &state.done });
    if (failed > 0)
        state.say(io, "Refreshed: {d} files; {d} of {d} sources couldn't be reached.", .{ files, failed, sources.len })
    else
        state.say(io, "Refreshed: {d} files.", .{files});
    // What's new, for this person's other devices.
    w.changed.store(@intCast(web.now(io)), .release);
}

/// Where this device stands, for the page to show setup, settings, or why
/// this browser can do neither: `admin` (whether this browser acts as this
/// device's person), `library`, `founder` (this person founded it), the
/// person's and the device's names, and the code shown while joining.
pub fn status(w: *Web, io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, request: *http.Server.Request, admin: bool) !void {
    if (!admin) return web.sendJson(arena, request, .{ .admin = false });
    try w.state.lock(io);
    defer w.state.unlock(io);
    // A joining device learns it's been added as its page asks.
    try finishJoining(w, io, gpa, arena);
    const person = try w.store.person();
    const device = try w.store.device();
    var person_name: ?[]const u8 = null;
    var device_name: ?[]const u8 = null;
    if (w.founder) |founder| {
        var r = try Replica.open(gpa, io, w.path, founder, w.store.identity);
        defer r.close();
        const named = try lib.names(&r, arena);
        person_name = lib.nameOf(named, &std.fmt.bytesToHex(person, .lower));
        device_name = lib.nameOf(named, &std.fmt.bytesToHex(device, .lower));
    }
    return web.sendJson(arena, request, .{
        .admin = true,
        .library = w.founder != null,
        .founder = if (w.founder) |f| std.mem.eql(u8, &f, &person) else false,
        .person = person_name,
        .device = device_name,
        .host = w.host_name,
        .joining = if (w.offering) try arena.dupe(u8, &w.offer.code) else null,
    });
}

/// Once a member's device has added this one (its offer's outcome), takes
/// the library it sent: as that person's device, or a new member's. With
/// `state` held.
fn finishJoining(w: *Web, io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator) !void {
    if (!w.offering) return;
    const received, const closed = w.offer.outcome(io);
    if (received) |secrets| {
        w.offering = false;
        {
            w.seen.lockUncancelable(io);
            defer w.seen.unlock(io);
            if (!secrets.joining()) try w.store.pair(arena, &std.fmt.bytesToHex(secrets.person, .lower));
            try w.store.setFounder(arena, secrets.founder);
            w.founder = secrets.founder;
        }
        try becameMember(w, io, gpa, arena);
    } else if (closed) {
        // Too many wrong codes: offered again, with a new one.
        w.offer = .{ .code = core.pair.newCode(io), .person = try w.store.person(), .device = try w.store.device() };
    }
}

/// Once this device has a library: named by its computer's name, if it has
/// no name yet, as the apps name themselves; its downloads kept, if asked
/// for; advertised as the library's; and synced at once, so a library
/// joined arrives. With `state` held.
fn becameMember(w: *Web, io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator) !void {
    {
        var r = try Replica.open(gpa, io, w.path, w.founder.?, w.store.identity);
        defer r.close();
        const device = try w.store.device();
        const named = try lib.names(&r, arena);
        if (lib.nameOf(named, &hex(device)) == null) {
            try w.writer.lock(io);
            defer w.writer.unlock(io);
            try lib.setName(&r, arena, web.now(io), device, w.host_name, try w.store.person());
        }
        // Its model too, for its person's other devices to show it by, as
        // the apps record theirs.
        if (core.model.this(io, arena)) |model| {
            try w.writer.lock(io);
            defer w.writer.unlock(io);
            try lib.recordModel(&r, arena, web.now(io), device, model);
        }
    }
    if (w.downloads_dir) |dir| configureDownloads(w, io, gpa, arena, dir) catch |err| std.log.warn("keeping downloads in {s}: {t}", .{ dir, err });
    try advertise(w, io, gpa, arena);
    w.changed.store(@intCast(web.now(io)), .release);
}

/// Keeps downloads in `dir`, served at `/downloads/`, as `serve
/// --downloads` does (see network.zig), once there's a library to record
/// them in. With `state` held.
fn configureDownloads(w: *Web, io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, dir: []const u8) !void {
    const host = w.host orelse return;
    const url = try std.fmt.allocPrint(arena, "http://{s}.local:{d}/downloads/", .{ w.host_name, host.port });
    var r = try Replica.open(gpa, io, w.path, w.founder.?, w.store.identity);
    defer r.close();
    if (try core.download.settings(&r, arena)) |s| {
        if (!std.mem.eql(u8, s.dir, dir)) return error.DownloadsElsewhere;
        if (!std.mem.eql(u8, s.source.url, url)) _ = try lib.removeSource(&r, arena, web.now(io), &s.source.id);
    }
    try core.download.configure(&r, arena, web.now(io), dir, url);
    w.downloads = true;
}

/// Advertises this device as it is now: its library's, with its names; a
/// new device offering to be added, while it shows a code; or with neither.
/// With `state` held.
pub fn advertise(w: *Web, io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator) !void {
    const host = w.host orelse return;
    const txt = if (w.founder) |founder| blk: {
        var r = try Replica.open(gpa, io, w.path, founder, w.store.identity);
        defer r.close();
        break :blk try core.sync.advertisement(arena, &r, try w.store.person(), try w.store.device());
    } else if (w.offering)
        try core.pair.offerRecord(arena, w.host_name, core.model.this(io, arena) orelse "")
    else
        try core.discover.txtRecord(arena, &.{.{ "name", w.host_name }});
    host.readvertise(try std.fmt.allocPrintSentinel(w.long, "{s}", .{try w.store.serviceName(arena)}, 0), try w.long.dupe(u8, txt));
}

pub fn api(w: *Web, io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, request: *http.Server.Request, name: []const u8) !void {
    const get = request.head.method == .GET or request.head.method == .HEAD;
    if (get and std.mem.eql(u8, name, "settings")) return settings(w, io, gpa, arena, request);
    if (get and std.mem.eql(u8, name, "nearby")) return nearby(w, io, arena, request);
    if (request.head.method != .POST) return error.NotFound;
    var body_buf: [4096]u8 = undefined;
    const body = try (try request.readerExpectContinue(&body_buf)).allocRemaining(arena, .limited(64 * 1024));

    if (std.mem.eql(u8, name, "setup-create")) {
        try w.state.lock(io);
        defer w.state.unlock(io);
        if (w.founder != null) return error.LibraryExists;
        const person = try w.store.person();
        {
            w.seen.lockUncancelable(io);
            defer w.seen.unlock(io);
            try w.store.setFounder(arena, person);
            w.founder = person;
        }
        w.offering = false;
        try becameMember(w, io, gpa, arena);
        return web.sendJson(arena, request, true);
    }
    if (std.mem.eql(u8, name, "setup-join")) {
        // Offering to be added, as `person pair` does, on this port.
        try w.state.lock(io);
        defer w.state.unlock(io);
        if (w.founder != null) return error.LibraryExists;
        if (!w.offering) {
            w.offer = .{ .code = core.pair.newCode(io), .person = try w.store.person(), .device = try w.store.device() };
            w.offering = true;
            try advertise(w, io, gpa, arena);
        }
        return web.sendJson(arena, request, try arena.dupe(u8, &w.offer.code));
    }
    if (std.mem.eql(u8, name, "setup-join-stop")) {
        try w.state.lock(io);
        defer w.state.unlock(io);
        if (w.offering) {
            w.offering = false;
            try advertise(w, io, gpa, arena);
        }
        return web.sendJson(arena, request, true);
    }
    if (std.mem.eql(u8, name, "pair")) return pairDevice(w, io, gpa, arena, request, body);
    if (std.mem.eql(u8, name, "refresh") or std.mem.eql(u8, name, "refresh-fully")) {
        _ = try web.open(w, io, gpa);
        w.refreshing.asked.store(if (name.len == "refresh".len) .refresh else .fully, .release);
        return web.sendJson(arena, request, true);
    }
    if (std.mem.eql(u8, name, "leave")) return leave(w, io, gpa, arena, request, body);

    // The rest change the library, as this device; names are advertised,
    // so a change of one is advertised afresh, once the writer's let go
    // (`state` is taken before the writer, never after).
    if (try change(w, io, gpa, arena, name, body)) {
        try w.state.lock(io);
        defer w.state.unlock(io);
        try advertise(w, io, gpa, arena);
    }
    return web.sendJson(arena, request, true);
}

/// Changes the library as `name` says, with `body`'s arguments; whether it
/// renamed someone.
fn change(w: *Web, io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, name: []const u8, body: []const u8) !bool {
    try w.writer.lock(io);
    defer w.writer.unlock(io);
    var r = try web.open(w, io, gpa);
    defer r.close();
    const at = web.now(io);
    var renamed = false;
    if (std.mem.eql(u8, name, "name-person")) {
        const p = try std.json.parseFromSliceLeaky(struct { key: []const u8, name: []const u8 }, arena, body, .{});
        const key = try core.store.parseKey(p.key);
        if (!isMember(try r.members(arena), key)) return error.NotFound;
        try lib.setName(&r, arena, at, key, p.name, null);
        renamed = true;
    } else if (std.mem.eql(u8, name, "name-device")) {
        // This person's own devices'.
        const p = try std.json.parseFromSliceLeaky(struct { key: []const u8, name: []const u8 }, arena, body, .{});
        const key = try core.store.parseKey(p.key);
        const me = try personOf((try w.snapshot(io, arena)).identity);
        if (!isMember(try r.devicesOf(arena, me), key) and !std.mem.eql(u8, &key, &r.device())) return error.NotFound;
        try lib.setName(&r, arena, at, key, p.name, me);
        renamed = true;
    } else if (std.mem.eql(u8, name, "member-remove")) {
        const p = try std.json.parseFromSliceLeaky(struct { key: []const u8 }, arena, body, .{});
        try r.removeMember(at, try core.store.parseKey(p.key));
    } else if (std.mem.eql(u8, name, "device-remove")) {
        const p = try std.json.parseFromSliceLeaky(struct { key: []const u8 }, arena, body, .{});
        const key = try core.store.parseKey(p.key);
        try r.revokeDevice(at, key);
        // Its downloads too, as no one would serve them again.
        try lib.removeDownloadsOf(&r, arena, at, key);
    } else if (std.mem.eql(u8, name, "source-add")) {
        // A server's address alone: a folder of this computer's is shared
        // only as `serve --media` names it.
        const p = try std.json.parseFromSliceLeaky(struct { url: []const u8 }, arena, body, .{});
        if (!std.mem.startsWith(u8, p.url, "http://") and !std.mem.startsWith(u8, p.url, "https://")) return error.BadAddress;
        var typed: std.ArrayList(u8) = .empty;
        try core.url.escape(arena, &typed, p.url);
        if (!std.mem.endsWith(u8, typed.items, "/")) try typed.append(arena, '/');
        _ = try lib.addSource(&r, at, typed.items, .{});
    } else if (std.mem.eql(u8, name, "source-add-media")) {
        const media = w.media orelse return error.NotFound;
        _ = try lib.addSource(&r, at, media.url, .{});
    } else if (std.mem.eql(u8, name, "source-remove")) {
        const p = try std.json.parseFromSliceLeaky(struct { id: []const u8 }, arena, body, .{});
        _ = try lib.removeSource(&r, arena, at, p.id);
    } else if (std.mem.eql(u8, name, "unavailable-remove")) {
        // An unavailable folder's videos, as if deleted.
        const p = try std.json.parseFromSliceLeaky(struct { id: []const u8, dir: []const u8 }, arena, body, .{});
        _ = try lib.removeUnavailable(&r, arena, at, try lib.findSource(&r, arena, p.id), p.dir);
    } else if (std.mem.eql(u8, name, "crawl-every")) {
        // Hours, or 0 for only when asked.
        const p = try std.json.parseFromSliceLeaky(struct { hours: u64 }, arena, body, .{});
        if (std.mem.indexOfScalar(u64, &.{ 0, 1, 3, 24, 168 }, p.hours) == null) return error.BadRequest;
        try lib.setCrawlEvery(&r, at, p.hours);
    } else return error.NotFound;
    // For the other devices.
    w.changed.store(@intCast(at), .release);
    return renamed;
}

fn isMember(list: []const [32]u8, key: [32]u8) bool {
    for (list) |m| if (std.mem.eql(u8, &m, &key)) return true;
    return false;
}

/// The key of the person whose seed `identity` holds.
fn personOf(identity: core.replica.Identity) ![32]u8 {
    return (try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(identity.person)).public_key.toBytes();
}

fn hex(key: [32]u8) [64]u8 {
    return std.fmt.bytesToHex(key, .lower);
}

/// What settings show: people, this person's devices, sources, how often
/// they're crawled, addresses added, the folder `--media` shares, and how
/// Refresh Library is going.
fn settings(w: *Web, io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, request: *http.Server.Request) !void {
    var r = try web.open(w, io, gpa);
    defer r.close();
    const named = try lib.names(&r, arena);
    const me = try personOf((try w.snapshot(io, arena)).identity);
    const this = r.device();

    const Member = struct { key: []const u8, name: ?[]const u8, founder: bool, you: bool };
    var members: std.ArrayList(Member) = .empty;
    for (try r.members(arena)) |m| {
        const k = try arena.dupe(u8, &hex(m));
        try members.append(arena, .{ .key = k, .name = lib.nameOf(named, k), .founder = std.mem.eql(u8, &m, &r.founder), .you = std.mem.eql(u8, &m, &me) });
    }

    const Device = struct { key: []const u8, name: ?[]const u8, this: bool };
    var devices: std.ArrayList(Device) = .empty;
    var seen: std.AutoArrayHashMapUnmanaged([32]u8, void) = .empty;
    try seen.put(arena, this, {});
    try devices.append(arena, .{ .key = try arena.dupe(u8, &hex(this)), .name = lib.nameOf(named, &hex(this)), .this = true });
    // Certified, or named by the device that paired it before it's
    // written its certificate; not removed.
    var mine: std.ArrayList([32]u8) = .empty;
    try mine.appendSlice(arena, try r.devicesOf(arena, me));
    for (named) |n| if (n.person) |p| if (std.mem.eql(u8, p, &hex(me))) {
        try mine.append(arena, core.store.parseKey(n.key) catch continue);
    };
    for (mine.items) |d| {
        if ((try seen.getOrPut(arena, d)).found_existing) continue;
        if (try r.revoked(d) != null) continue;
        const k = try arena.dupe(u8, &hex(d));
        try devices.append(arena, .{ .key = k, .name = lib.nameOf(named, k), .this = false });
    }

    const Unavailable = struct { dir: []const u8, since_ms: u64 };
    // Its path as players show it, and whose it is, by name, for a
    // device's downloads.
    const Source = struct { id: []const u8, url: []const u8, path: []const []const u8, copies: i64, unavailable: []const Unavailable };
    var sources: std.ArrayList(Source) = .empty;
    var media_added = false;
    for (try lib.sources(&r, arena)) |s| {
        // Devices' downloads are theirs to manage (this one's under Kept),
        // as the apps leave them out of Sources.
        if (s.managed) continue;
        if (w.media) |m| if (std.mem.eql(u8, m.url, s.url)) {
            media_added = true;
        };
        var gone: std.ArrayList(Unavailable) = .empty;
        for (try lib.unavailableDirs(&r, arena, &s.id)) |a| try gone.append(arena, .{ .dir = a.dir, .since_ms = a.since_ms });
        try sources.append(arena, .{
            .id = try arena.dupe(u8, &s.id),
            .url = s.url,
            .path = try lib.shownPath(arena, s),
            .copies = try lib.countCopies(&r, arena, s),
            .unavailable = gone.items,
        });
    }

    return web.sendJson(arena, request, .{
        .members = members.items,
        .devices = devices.items,
        .sources = sources.items,
        .crawl_every = (try lib.crawlEvery(&r, arena)) orelse 0,
        .media = if (w.media) |m| .{ .dir = m.dir, .added = media_added } else null,
        .refreshing = .{
            .phase = w.refreshing.phase.load(.acquire),
            .done = w.refreshing.done.load(.acquire),
            .total = w.refreshing.total.load(.acquire),
            .said = try w.refreshing.told(io, arena),
        },
    });
}

/// New devices nearby offering to be added (listening for 2 seconds).
fn nearby(w: *Web, io: Io, arena: std.mem.Allocator, request: *http.Server.Request) !void {
    const own = (try w.snapshot(io, arena)).own;
    const Offering = struct { name: []const u8, model: ?[]const u8, url: []const u8 };
    var out: std.ArrayList(Offering) = .empty;
    for (try core.discover.browse(io, arena, 2000)) |s| {
        if (s.host.len == 0 or s.get("pair") == null or core.sync.isOwn(s.name, own)) continue;
        // Its path, as any device may advertise what it likes, only a path.
        const path = s.get("path") orelse core.pair.path;
        if (!std.mem.eql(u8, path, core.pair.path)) continue;
        const name = try s.shownName(arena);
        try out.append(arena, .{
            .name = name orelse "A new device",
            .model = s.shownModel(name),
            .url = try std.fmt.allocPrint(arena, "http://{s}:{d}{s}", .{ s.host, s.port, path }),
        });
    }
    return web.sendJson(arena, request, out.items);
}

/// Adds the new device showing `code`, at `url`: as this person's (`pair`),
/// or a new member's (`join`), named as it advertised itself.
fn pairDevice(w: *Web, io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, request: *http.Server.Request, body: []const u8) !void {
    const p = try std.json.parseFromSliceLeaky(struct { url: []const u8, code: []const u8, kind: []const u8, name: []const u8 = "" }, arena, body, .{});
    const kind = std.meta.stringToEnum(core.pair.Kind, p.kind) orelse return error.BadRequest;
    // Pairing reaches only a pairing path, not wherever a URL points.
    const uri = std.Uri.parse(p.url) catch return error.BadAddress;
    if (!std.mem.eql(u8, uri.scheme, "http") or !std.mem.eql(u8, try uri.path.toRawMaybeAlloc(arena), core.pair.path)) return error.BadAddress;
    const now_is = try w.snapshot(io, arena);
    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const joined = try core.pair.send(io, arena, &client, p.url, kind, p.code, .{ .person = now_is.identity.person, .founder = now_is.founder });
    try w.writer.lock(io);
    defer w.writer.unlock(io);
    var r = try web.open(w, io, gpa);
    defer r.close();
    const me = try personOf((try w.snapshot(io, arena)).identity);
    const acting = switch (kind) {
        .pair => me,
        .join => joined.person,
    };
    if (kind == .join) try r.addMember(web.now(io), joined.person);
    if (p.name.len > 0) try lib.setName(&r, arena, web.now(io), joined.device, p.name, acting);
    w.changed.store(@intCast(web.now(io)), .release);
    return web.sendJson(arena, request, true);
}

/// Leaves the library, as the apps do: this device removed (handing the
/// library over to `successor` first, if this person founded it and has no
/// other device), the removal synced to another device, and the library
/// and this device's identity forgotten, so it can be set up afresh. With
/// no one else in the library, it only forgets.
fn leave(w: *Web, io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, request: *http.Server.Request, body: []const u8) !void {
    const p = try std.json.parseFromSliceLeaky(struct { successor: ?[]const u8 = null }, arena, body, .{});
    if (w.refreshing.phase.load(.acquire) != .idle) return error.Busy;
    alone: {
        try w.writer.lock(io);
        defer w.writer.unlock(io);
        var r = try web.open(w, io, gpa);
        defer r.close();
        const me = try personOf((try w.snapshot(io, arena)).identity);
        var others: usize = 0;
        for (try r.devicesOf(arena, me)) |d| {
            if (!std.mem.eql(u8, &d, &r.device()) and try r.revoked(d) == null) others += 1;
        }
        const members = try r.members(arena);
        if (members.len == 1 and others == 0) break :alone;
        const founding = std.mem.eql(u8, &me, &r.founder) and others == 0 and members.len > 1;
        const successor: ?[32]u8 = if (p.successor) |s| try core.store.parseKey(s) else null;
        if (founding and successor == null) return error.NeedsSuccessor;
        try r.removeSelf(web.now(io), if (founding) successor else null);
        // Another device takes the removal, so it stands.
        const found = try core.sync.everyDevice(io, arena, &r, (try w.snapshot(io, arena)).own);
        var client: http.Client = .{ .allocator = gpa, .io = io };
        defer client.deinit();
        var reached = false;
        for (found.urls) |u| {
            if (core.sync.exchange(arena, &client, &r, u, web.now(io))) |_| {
                reached = true;
            } else |err| std.log.warn("leaving: syncing with {s}: {t}", .{ u, err });
        }
        if (!reached) return error.NoOneReached;
    }
    try forgetLibrary(w, io, gpa, arena);
    return web.sendJson(arena, request, true);
}

/// Forgets the library and this device's identity, as leaving does, so
/// the web client sets it up afresh; its downloads' files stay.
fn forgetLibrary(w: *Web, io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator) !void {
    try w.state.lock(io);
    defer w.state.unlock(io);
    {
        w.seen.lockUncancelable(io);
        defer w.seen.unlock(io);
        try w.store.forget(arena);
        w.store = try core.store.Store.open(io, gpa, w.long, w.store.dir);
        w.founder = null;
    }
    w.offering = false;
    w.downloads = false;
    try advertise(w, io, gpa, arena);
}

/// Leaves a library that removed this device, as the apps do once a device
/// tells them (under a member's signature, so no one else can make it
/// leave): it forgets it, and the web client sets it up afresh, to join
/// again as a new device.
pub fn leaveRemoved(w: *Web, io: Io, gpa: std.mem.Allocator) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    std.log.warn("this device was removed from the library, so it leaves it; set it up again in a browser", .{});
    forgetLibrary(w, io, gpa, arena_state.allocator()) catch |err| std.log.warn("leaving the library it was removed from: {t}", .{err});
}
