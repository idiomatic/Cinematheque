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

/// Setup's and settings' calls, by their names under `/api/`.
pub const Call = enum {
    settings, nearby, @"setup-create", @"setup-join", @"setup-join-stop", pair, refresh, @"refresh-fully", leave,
    @"name-person", @"name-device", @"member-remove", @"device-remove", @"source-add", @"source-add-media", @"source-remove", @"unavailable-remove", @"crawl-every",
};

/// Refresh Library, as it runs on a task of its own (`keepRefreshed`), and
/// how it went, for settings to show.
pub const Refreshing = struct {
    asked: std.atomic.Value(Asked) = .init(.none),
    steps: core.art.Steps = .{},
    /// How the last one went, in words; held by `said_lock`.
    said: [256]u8 = undefined,
    said_len: usize = 0,
    said_lock: Io.Mutex = .init,

    const Asked = enum(u8) { none, refresh, fully };

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
        defer w.refreshing.steps.finish();
        refresh(w, io, gpa, if (asked == .fully) .afresh else .reuse) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Removed => leaveRemoved(w, io, gpa),
            else => w.refreshing.say(io, "Refreshing failed: {t}", .{err}),
        };
    }
}

fn refresh(w: *Web, io: Io, gpa: std.mem.Allocator, listing: core.art.Listing) !void {
    const state = &w.refreshing;
    state.steps.start(.syncing, 0);
    try w.syncAll(io, gpa);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r = try web.open(w, io, gpa);
    defer r.close();
    const sources = try lib.sources(&r, arena);
    // The writer held for each source's crawl, as the apps hold it, so a
    // page's writes wait out one source, not all of them.
    const refreshed = try core.art.crawlAndDescribe(io, gpa, &r, arena, sources, .{ .listing = listing, .writer = &w.writer, .steps = &state.steps });
    var files: usize = 0;
    var failed: usize = 0;
    for (refreshed.sources) |result| switch (result.outcome) {
        .crawled => |s| files += s.ingest.files,
        .failed => |err| {
            std.log.warn("crawling {s}: {t}", .{ result.source.url, err });
            failed += 1;
        },
        .skipped => {},
    };
    if (failed > 0)
        state.say(io, "Refreshed: {d} files; {d} of {d} sources couldn't be reached.", .{ files, failed, sources.len })
    else
        state.say(io, "Refreshed: {d} files.", .{files});
    // What's new, for this person's other devices.
    w.changed.store(@intCast(web.now(io)), .release);
}

/// Where this device stands, for the page to show setup, settings, or why
/// this browser can do neither: `admin` (whether this browser acts as this
/// device's person), `library`, the
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
    if (w.creator) |creator| {
        var r = try Replica.open(gpa, io, w.path, creator, w.store.identity);
        defer r.close();
        const named = try lib.names(&r, arena);
        person_name = lib.nameOf(named, &std.fmt.bytesToHex(person, .lower));
        device_name = lib.nameOf(named, &std.fmt.bytesToHex(device, .lower));
    }
    return web.sendJson(arena, request, .{
        .admin = true,
        .library = w.creator != null,
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
            try w.store.join(arena, secrets);
            w.creator = secrets.creator;
        }
        try becameMember(w, io, gpa, arena);
    } else if (closed) {
        // Too many wrong codes: offered again, with a new one.
        w.offer = try w.store.offer(io);
    }
}

/// Once this device has a library: named by its computer's name, if it has
/// no name yet, as the apps name themselves; advertised as the library's; and synced at once, so a library
/// joined arrives. With `state` held.
fn becameMember(w: *Web, io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator) !void {
    {
        var r = try Replica.open(gpa, io, w.path, w.creator.?, w.store.identity);
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
        // Where it serves its own sources (port-free), as `serve` records.
        if (w.host) |host| {
            try w.writer.lock(io);
            defer w.writer.unlock(io);
            try lib.recordServed(&r, arena, web.now(io), device, try std.fmt.allocPrint(arena, "http://{s}.local:{d}/", .{ w.host_name, host.port }));
        }
    }
    try advertise(w, io, gpa, arena);
    w.changed.store(@intCast(web.now(io)), .release);
}

/// Advertises this device as it is now: its library's, with its names; a
/// new device offering to be added, while it shows a code; or with neither.
/// With `state` held.
pub fn advertise(w: *Web, io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator) !void {
    const host = w.host orelse return;
    const txt = if (w.creator) |creator| blk: {
        var r = try Replica.open(gpa, io, w.path, creator, w.store.identity);
        defer r.close();
        break :blk try core.sync.advertisement(arena, &r, try w.store.person(), try w.store.device());
    } else if (w.offering)
        try core.pair.offerRecord(arena, w.host_name, core.model.this(io, arena) orelse "")
    else
        try core.discover.txtRecord(arena, &.{.{ "name", w.host_name }});
    host.readvertise(try w.store.serviceName(w.long), try w.long.dupe(u8, txt));
}

pub fn api(w: *Web, io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, request: *http.Server.Request, call: Call) !void {
    const get = request.head.method == .GET or request.head.method == .HEAD;
    if (get and call == .settings) return settings(w, io, gpa, arena, request);
    if (get and call == .nearby) return nearby(w, io, arena, request);
    if (request.head.method != .POST) return error.NotFound;
    var body_buf: [4096]u8 = undefined;
    const body = try (try request.readerExpectContinue(&body_buf)).allocRemaining(arena, .limited(64 * 1024));

    if (call == .@"setup-create") {
        try w.state.lock(io);
        defer w.state.unlock(io);
        if (w.creator != null) return error.LibraryExists;
        const person = try w.store.person();
        {
            w.seen.lockUncancelable(io);
            defer w.seen.unlock(io);
            try w.store.setCreator(arena, person);
            w.creator = person;
        }
        w.offering = false;
        try becameMember(w, io, gpa, arena);
        return web.sendJson(arena, request, true);
    }
    if (call == .@"setup-join") {
        // Offering to be added, as `person pair` does, on this port.
        try w.state.lock(io);
        defer w.state.unlock(io);
        if (w.creator != null) return error.LibraryExists;
        if (!w.offering) {
            w.offer = try w.store.offer(io);
            w.offering = true;
            try advertise(w, io, gpa, arena);
        }
        return web.sendJson(arena, request, try arena.dupe(u8, &w.offer.code));
    }
    if (call == .@"setup-join-stop") {
        try w.state.lock(io);
        defer w.state.unlock(io);
        if (w.offering) {
            w.offering = false;
            try advertise(w, io, gpa, arena);
        }
        return web.sendJson(arena, request, true);
    }
    if (call == .pair) return pairDevice(w, io, gpa, arena, request, body);
    if (call == .refresh or call == .@"refresh-fully") {
        _ = try web.open(w, io, gpa);
        w.refreshing.asked.store(if (call == .refresh) .refresh else .fully, .release);
        return web.sendJson(arena, request, true);
    }
    if (call == .leave) return leave(w, io, gpa, arena, request);

    // The rest change the library, as this device; names are advertised,
    // so a change of one is advertised afresh, once the writer's let go
    // (`state` is taken before the writer, never after).
    if (try change(w, io, gpa, arena, call, body)) {
        try w.state.lock(io);
        defer w.state.unlock(io);
        try advertise(w, io, gpa, arena);
    }
    return web.sendJson(arena, request, true);
}

/// Changes the library as `call` says, with `body`'s arguments; whether it
/// renamed someone.
fn change(w: *Web, io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, call: Call, body: []const u8) !bool {
    try w.writer.lock(io);
    defer w.writer.unlock(io);
    var r = try web.open(w, io, gpa);
    defer r.close();
    const at = web.now(io);
    var renamed = false;
    if (call == .@"name-person") {
        const p = try std.json.parseFromSliceLeaky(struct { key: []const u8, name: []const u8 }, arena, body, .{});
        const key = try core.store.parseKey(p.key);
        if (!isMember(try r.members(arena), key)) return error.NotFound;
        try lib.setName(&r, arena, at, key, p.name, null);
        renamed = true;
    } else if (call == .@"name-device") {
        // This person's own devices'.
        const p = try std.json.parseFromSliceLeaky(struct { key: []const u8, name: []const u8 }, arena, body, .{});
        const key = try core.store.parseKey(p.key);
        const me = try personOf((try w.snapshot(io, arena)).identity);
        if (!isMember(try r.devicesOf(arena, me), key) and !std.mem.eql(u8, &key, &r.device())) return error.NotFound;
        try lib.setName(&r, arena, at, key, p.name, me);
        renamed = true;
    } else if (call == .@"member-remove") {
        const p = try std.json.parseFromSliceLeaky(struct { key: []const u8 }, arena, body, .{});
        try r.removeMember(at, try core.store.parseKey(p.key));
    } else if (call == .@"device-remove") {
        const p = try std.json.parseFromSliceLeaky(struct { key: []const u8 }, arena, body, .{});
        const key = try core.store.parseKey(p.key);
        try r.revokeDevice(at, key);
        // Its downloads too, as no one would serve them again.
        try lib.removeDownloadsOf(&r, arena, at, key);
    } else if (call == .@"source-add") {
        // A server's address alone: a folder of this computer's is shared
        // only as `serve --media` names it.
        const p = try std.json.parseFromSliceLeaky(struct { url: []const u8 }, arena, body, .{});
        if (!std.mem.startsWith(u8, p.url, "http://") and !std.mem.startsWith(u8, p.url, "https://")) return error.BadAddress;
        var typed: std.ArrayList(u8) = .empty;
        try core.url.escape(arena, &typed, p.url);
        if (!std.mem.endsWith(u8, typed.items, "/")) try typed.append(arena, '/');
        _ = try lib.addSource(&r, at, typed.items, .{});
    } else if (call == .@"source-add-media") {
        const media = w.media orelse return error.NotFound;
        _ = try lib.addSource(&r, at, media.url, .{});
    } else if (call == .@"source-remove") {
        const p = try std.json.parseFromSliceLeaky(struct { id: []const u8 }, arena, body, .{});
        _ = try lib.removeSource(&r, arena, at, p.id);
    } else if (call == .@"unavailable-remove") {
        // An unavailable folder's videos, as if deleted.
        const p = try std.json.parseFromSliceLeaky(struct { id: []const u8, dir: []const u8 }, arena, body, .{});
        _ = try lib.removeUnavailable(&r, arena, at, try lib.findSource(&r, arena, p.id), p.dir);
    } else if (call == .@"crawl-every") {
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
    const this = r.device();

    const Device = struct { key: []const u8, name: ?[]const u8, this: bool, seen: ?u64 = null };
    var devices: std.ArrayList(Device) = .empty;
    try devices.append(arena, .{ .key = try arena.dupe(u8, &hex(this)), .name = lib.nameOf(named, &hex(this)), .this = true });
    for (try lib.otherDevices(&r, arena)) |d| {
        const k = try arena.dupe(u8, &hex(d));
        try devices.append(arena, .{ .key = k, .name = lib.nameOf(named, k), .this = false, .seen = try core.sync.lastSeen(&r, arena, d) });
    }

    var sources: std.ArrayList(core.views.SourceJson) = .empty;
    var media_added = false;
    for (try core.views.sources(&r, arena)) |s| {
        // Devices' downloads are theirs to manage, as the apps leave them
        // out of Sources.
        if (s.managed) continue;
        if (w.media) |m| if (std.mem.eql(u8, m.url, s.url)) {
            media_added = true;
        };
        try sources.append(arena, s);
    }

    return web.sendJson(arena, request, .{
        .members = try core.views.members(&r, arena),
        .devices = devices.items,
        .sources = sources.items,
        .crawl_every = (try lib.crawlEvery(&r, arena)) orelse 0,
        .media = if (w.media) |m| .{ .dir = m.dir, .added = media_added } else null,
        .refreshing = .{
            .phase = w.refreshing.steps.phase.load(.acquire),
            .done = w.refreshing.steps.done.load(.acquire),
            .total = w.refreshing.steps.total.load(.acquire),
            .said = try w.refreshing.told(io, arena),
        },
    });
}

/// New devices nearby offering to be added (listening for 2 seconds).
fn nearby(w: *Web, io: Io, arena: std.mem.Allocator, request: *http.Server.Request) !void {
    const found = try core.pair.offering(io, arena, (try w.snapshot(io, arena)).own);
    const Offering = struct { name: []const u8, model: ?[]const u8, url: []const u8 };
    const out = try arena.alloc(Offering, found.len);
    for (found, out) |f, *o| o.* = .{ .name = f.name orelse "A new device", .model = f.model, .url = f.url };
    return web.sendJson(arena, request, out);
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
    const joined = try core.pair.send(io, arena, &client, p.url, kind, p.code, .{ .person = now_is.identity.person, .creator = now_is.creator });
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

/// Leaves the library, as the apps do: this device removed, the removal synced to another device, and the library
/// and this device's identity forgotten, so it can be set up afresh. With
/// no one else in the library, it only forgets.
fn leave(w: *Web, io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, request: *http.Server.Request) !void {
    if (w.refreshing.steps.phase.load(.acquire) != .idle) return error.Busy;
    {
        try w.writer.lock(io);
        defer w.writer.unlock(io);
        var r = try web.open(w, io, gpa);
        defer r.close();
        // Another device takes the removal, so it stands.
        try core.sync.leave(io, gpa, arena, &r, (try w.snapshot(io, arena)).own);
    }
    try forgetLibrary(w, io, gpa, arena);
    return web.sendJson(arena, request, true);
}

/// Forgets the library and this device's identity, as leaving does, so
/// the web client sets it up afresh.
fn forgetLibrary(w: *Web, io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator) !void {
    try w.state.lock(io);
    defer w.state.unlock(io);
    {
        w.seen.lockUncancelable(io);
        defer w.seen.unlock(io);
        try w.store.forget(arena);
        w.store = try core.store.Store.open(io, gpa, w.long, w.store.dir);
        w.creator = null;
    }
    w.offering = false;
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
