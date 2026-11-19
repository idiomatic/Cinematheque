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
//! while one runs, but for progress and watchlists, which don't need to.

const std = @import("std");
const Io = std.Io;
const library = @import("library.zig");
const art = @import("art.zig");
const thumbhash = @import("thumbhash.zig");
const store_ = @import("store.zig");
const sync = @import("sync.zig");
const discover = @import("discover.zig");
const Host = @import("host.zig").Host;
const race = @import("race.zig");
const download = @import("download.zig");
const serve_ = @import("serve.zig");
const pair = @import("pair.zig");
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
    /// How far the long operation running has come.
    steps: Steps = .{},
    /// Serving, while it does (`cq_serve`).
    serving: ?*Serving = null,
    /// Offering to pair, while it does (`cq_pair_offer`).
    pairing: ?*Pairing = null,
    /// The last sync served (`cq_served`), and the last push taken
    /// (`cq_received`), from the server's task.
    served: Heard = .{},
    received: Heard = .{},
    /// Servers whose copies didn't answer lately (`cq_race`).
    racing: race.Memory = .{},
    /// Reconciling downloads (`cq_reconcile`), apart from `progress`, since
    /// it runs alongside crawls: whether it runs, whether it's asked to run
    /// again, and how far it's come, in megabytes.
    reconciling: std.atomic.Value(bool) = .init(false),
    reconcile_again: std.atomic.Value(bool) = .init(false),
    downloaded_mb: std.atomic.Value(u32) = .init(0),
    /// Set while a stream plays (`cq_downloads_hold`): no download begins.
    hold: std.atomic.Value(bool) = .init(false),
    download_mb: std.atomic.Value(u32) = .init(0),

    fn onServed(context: ?*anyopaque, device: [32]u8, operations: usize) void {
        const lib: *Library = @ptrCast(@alignCast(context.?));
        lib.served.note(lib, device, operations);
    }

    fn onReceived(context: ?*anyopaque, device: [32]u8, operations: usize) void {
        const lib: *Library = @ptrCast(@alignCast(context.?));
        lib.received.note(lib, device, operations);
    }

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

/// Opens this device's data directory `data_dir`; if null, `$CINEMATHEQUE_DATA`, or else
/// the default. It may not hold a library yet (see `cq_status`).
export fn cq_open(data_dir: ?[*:0]const u8) ?*Library {
    return open(data_dir) catch |err| {
        fail(err);
        return null;
    };
}

fn open(data_dir: ?[*:0]const u8) !*Library {
    const lib = try gpa.create(Library);
    errdefer gpa.destroy(lib);
    lib.* = .{ .threaded = .init(gpa, .{}), .arena_state = .init(gpa), .store = undefined };
    errdefer lib.threaded.deinit();
    errdefer lib.arena_state.deinit();
    const arena = lib.arena_state.allocator();
    const dir = if (data_dir orelse std.c.getenv("CINEMATHEQUE_DATA")) |d| try arena.dupe(u8, std.mem.span(d)) else blk: {
        const home = std.c.getenv("HOME") orelse return error.NoHome;
        const xdg = std.c.getenv("XDG_DATA_HOME");
        break :blk try store_.defaultDataDir(arena, std.mem.span(home), if (xdg) |x| std.mem.span(x) else null);
    };
    lib.store = try store_.Store.open(lib.io(), gpa, arena, dir);
    _ = lib.store.founder(arena) catch return lib;
    lib.replica = try lib.store.openReplica(arena);
    // One an older build certified wrongly is accepted by others again.
    try lib.replica.?.recertify(lib.now());
    return lib;
}

export fn cq_close(lib: ?*Library) void {
    const l = lib orelse return;
    stopServing(l);
    stopPairing(l);
    if (l.replica) |*r| r.close();
    l.priority.deinit();
    l.racing.deinit(gpa);
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
const MemberJson = struct { key: []const u8, name: ?[]const u8, founder: bool, you: bool };
const DeviceJson = struct { key: []const u8, name: []const u8, you: bool };
const NearbyJson = struct { url: []const u8, device: ?[]const u8, host: ?[]const u8 = null, person: ?[]const u8, person_key: ?[]const u8, ours: bool, member: bool, added: bool, pairing: ?[]const u8 };
const PairJson = struct { code: ?[]const u8, paired: bool, closed: bool };
const PairedJson = struct { person: []const u8, device: []const u8 };
const CrawlJson = struct { url: []const u8, files: usize, titles: usize, covers: usize, @"error": ?[]const u8 };
const SyncJson = struct { url: []const u8, name: ?[]const u8 = null, new: usize, sent: usize = 0, @"error": ?[]const u8 };
const HeardJson = struct { device: []const u8, name: ?[]const u8, operations: usize, at: u64 };

/// An exchange the server had with a device, recorded on the server's task:
/// with which device, how many operations, and when.
const Heard = struct {
    mutex: Io.Mutex = .init,
    device: [32]u8 = @splat(0),
    operations: usize = 0,
    at: u64 = 0,

    fn note(h: *Heard, lib: *Library, device: [32]u8, operations: usize) void {
        h.mutex.lockUncancelable(lib.io());
        defer h.mutex.unlock(lib.io());
        h.device = device;
        h.operations = operations;
        h.at = lib.now();
    }

    /// As JSON, with the device's name if it has one; null if none yet.
    fn json(h: *Heard, lib: *Library, arena: std.mem.Allocator) !?HeardJson {
        h.mutex.lockUncancelable(lib.io());
        const device = h.device;
        const operations = h.operations;
        const at = h.at;
        h.mutex.unlock(lib.io());
        if (at == 0) return null;
        const key = try arena.dupe(u8, &std.fmt.bytesToHex(device, .lower));
        const named = library.names(try lib.main(), arena) catch &.{};
        return .{ .device = key, .name = library.nameOf(named, key), .operations = operations, .at = at };
    }
};
const TileJson = struct { key: []const u8, name: []const u8, year: ?u16, kind: []const u8, season: ?u16, cover: ?CoverJson, thumb: ?[]const u8, watched: bool, progress: f64, elapsed: u64, runtime: u64, started: bool, unavailable: bool };
const StatusJson = struct { person: []const u8, paired: bool, library: ?[]const u8, founder: ?[]const u8, members: usize };

/// How far a long operation has come, in steps of its phase (sources
/// crawled, movies and seasons described, devices synced); read from any
/// thread.
const Steps = struct {
    phase: std.atomic.Value(Phase) = .init(.idle),
    done: std.atomic.Value(u32) = .init(0),
    total: std.atomic.Value(u32) = .init(0),

    const Phase = enum(u8) { idle, crawling, describing, syncing };

    fn start(p: *Steps, phase: Phase, total: usize) void {
        p.done.store(0, .monotonic);
        p.total.store(@intCast(total), .monotonic);
        p.phase.store(phase, .release);
    }

    fn step(p: *Steps) void {
        _ = p.done.fetchAdd(1, .monotonic);
    }

    fn finish(p: *Steps) void {
        p.phase.store(.idle, .release);
    }
};

const StepsJson = struct { phase: ?[]const u8, done: u32, total: u32 };

/// How far the long operation running has come: a JSON object with `phase`
/// (`crawling`, `describing`, `syncing`, or null when none runs), and
/// `done` and `total` steps of it. Any thread.
export fn cq_steps(lib: *Library) ?[*:0]u8 {
    return json(lib, steps, .{});
}

fn steps(lib: *Library, _: std.mem.Allocator) !StepsJson {
    const phase = lib.steps.phase.load(.acquire);
    return .{
        .phase = if (phase == .idle) null else @tagName(phase),
        .done = lib.steps.done.load(.monotonic),
        .total = lib.steps.total.load(.monotonic),
    };
}

// Serving.

/// Serving the library (and folders): the host, and what it needs that
/// outlives the call that started it.
const Serving = struct {
    arena: std.heap.ArenaAllocator,
    sharing: sync.Sharing,
    host: Host,
};

const MountJson = struct { prefix: []const u8, path: []const u8 };

/// Long, but returns once listening: serves this library to devices (their
/// syncs) and `folders_json`'s folders as sources (a JSON array of
/// objects with `prefix`, the path they're served at, and `path`), on
/// `port`, else 8008, else any free port; advertises it by DNS-SD; and
/// keeps serving, on a thread of its own, until `cq_stop_serving` or
/// `cq_close`. Serving again restarts it. Returns the port, or -1.
export fn cq_serve(lib: *Library, port: c_int, folders_json: [*:0]const u8) c_int {
    return startServing(lib, @intCast(std.math.clamp(port, 0, 65535)), std.mem.span(folders_json)) catch |err| {
        fail(err);
        return -1;
    };
}

/// Stops serving, if it is.
export fn cq_stop_serving(lib: *Library) void {
    stopServing(lib);
}

fn startServing(lib: *Library, port: u16, folders_json: []const u8) !c_int {
    stopServing(lib);
    const s = try gpa.create(Serving);
    errdefer gpa.destroy(s);
    s.arena = .init(gpa);
    errdefer s.arena.deinit();
    const arena = s.arena.allocator();
    // Copied, since they outlive the caller's string.
    const folders = try std.json.parseFromSliceLeaky([]const MountJson, arena, folders_json, .{ .allocate = .alloc_always });
    const mounts = try arena.alloc(serve_.Mount, folders.len);
    for (folders, mounts) |f, *m| m.* = .{ .prefix = f.prefix, .path = f.path, .index = false };
    s.sharing = .{
        .path = try lib.store.replicaPath(arena),
        .founder = try lib.store.founder(arena),
        .identity = lib.store.identity,
        .served = Library.onServed,
        .received = Library.onReceived,
        .context = lib,
    };
    s.host = .{
        .io = lib.io(),
        .gpa = gpa,
        .options = .{ .host = "0.0.0.0", .port = if (port == 0) 8008 else port, .fallback = true, .mounts = mounts, .handler = s.sharing.handler() },
        .name = try std.fmt.allocPrintSentinel(arena, "{s}", .{try lib.store.serviceName(arena)}, 0),
        .txt = try sync.advertisement(arena, try lib.main(), try lib.store.person(), try lib.store.device()),
    };
    try s.host.start();
    lib.serving = s;
    return s.host.port;
}

fn stopServing(lib: *Library) void {
    const s = lib.serving orelse return;
    s.host.stop();
    s.arena.deinit();
    gpa.destroy(s);
    lib.serving = null;
}

// Identity and membership.

/// This device, as JSON: `person` (its person's key), `paired` (acting as the
/// person of another of the person's devices), `library` (the library's ID,
/// or null if it has none yet), `founder`, and `members` (how many).
export fn cq_status(lib: *Library) ?[*:0]u8 {
    return json(lib, getStatus, .{});
}

fn getStatus(lib: *Library, arena: std.mem.Allocator) !StatusJson {
    const person = try arena.dupe(u8, &std.fmt.bytesToHex(try lib.store.person(), .lower));
    const paired = lib.store.paired();
    const r = lib.main() catch return .{ .person = person, .paired = paired, .library = null, .founder = null, .members = 0 };
    return .{
        .person = person,
        .paired = paired,
        .library = try arena.dupe(u8, &std.fmt.bytesToHex(r.library, .lower)),
        .founder = try arena.dupe(u8, &std.fmt.bytesToHex(r.founder, .lower)),
        .members = (try r.members(arena)).len,
    };
}

/// Leaves the library, as a device removed from it does (a sync's result
/// `error` is `Removed`): stops serving and pairing, and forgets the
/// library and this device's identity, seeds and replica alike, so it can
/// pair again as a new device.
export fn cq_leave(lib: *Library) c_int {
    return status(lib, leave, .{});
}

fn leave(lib: *Library, arena: std.mem.Allocator) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    stopServing(lib);
    stopPairing(lib);
    if (lib.replica) |*r| r.close();
    lib.replica = null;
    try lib.store.forget(arena);
    lib.store = try store_.Store.open(lib.io(), gpa, lib.arena_state.allocator(), lib.store.dir);
    lib.served = .{};
    lib.received = .{};
}

/// Creates a library, founded by this person. (Joining one is by pairing.)
export fn cq_found(lib: *Library) c_int {
    return status(lib, found, .{});
}

fn found(lib: *Library, arena: std.mem.Allocator) !void {
    try openFounded(lib, arena, try lib.store.person());
}

/// Opens the library `founder` founded, as this device's.
fn openFounded(lib: *Library, arena: std.mem.Allocator, founder: [32]u8) !void {
    if (lib.replica != null) return error.LibraryExists;
    // Once it has a library, it no longer offers to pair.
    stopPairing(lib);
    try lib.store.setFounder(arena, founder);
    lib.replica = try lib.store.openReplica(lib.arena_state.allocator());
}

// Pairing: a new device shows a code, and a member's, given it, sends it
// the library's founder's key, and to pair another of its person's devices,
// the person's secret too (see pair.zig).

const Pairing = struct {
    offer: pair.Offer,
    arena: std.heap.ArenaAllocator,
    host: Host,
};

/// On a new device, before it has a library: offers to pair, to be another
/// of a member's person's devices (`join` zero), or to join as a new member,
/// serving and advertising by DNS-SD (as `name`, for the other device to
/// show) until paired or `cq_pair_stop`. Returns its state, as
/// `cq_pair_check` does, with a new code. Offering again starts over, with
/// another code.
export fn cq_pair_offer(lib: *Library, name: [*:0]const u8, join: c_int) ?[*:0]u8 {
    return json(lib, pairOffer, .{ std.mem.span(name), if (join != 0) pair.Kind.join else pair.Kind.pair });
}

fn pairOffer(lib: *Library, arena: std.mem.Allocator, name: []const u8, kind: pair.Kind) !PairJson {
    if (lib.replica != null) return error.LibraryExists;
    stopPairing(lib);
    const p = try gpa.create(Pairing);
    errdefer gpa.destroy(p);
    p.offer = .{ .code = pair.newCode(lib.io()), .kind = kind, .person = try lib.store.person(), .device = try lib.store.device() };
    p.arena = .init(gpa);
    errdefer p.arena.deinit();
    const a = p.arena.allocator();
    p.host = .{
        .io = lib.io(),
        .gpa = gpa,
        .options = .{ .host = "0.0.0.0", .port = 0, .handler = p.offer.handler() },
        .name = try std.fmt.allocPrintSentinel(a, "{s}", .{try lib.store.serviceName(arena)}, 0),
        .txt = try discover.txtRecord(a, &.{
            .{ "pair", @tagName(kind) },
            .{ "path", pair.path },
            .{ "name", name[0..@min(name.len, 200)] },
        }),
    };
    try p.host.start();
    lib.pairing = p;
    return .{ .code = try arena.dupe(u8, &p.offer.code), .paired = false, .closed = false };
}

/// On a new device offering to pair: its state, as JSON: `code` (to show,
/// while it offers), `paired` (it has the library, and if pairing as theirs, its
/// person, and has stopped offering), and `closed` (it stopped, after too
/// many wrong codes; offer again for a new one).
export fn cq_pair_check(lib: *Library) ?[*:0]u8 {
    return json(lib, pairCheck, .{});
}

fn pairCheck(lib: *Library, arena: std.mem.Allocator) !PairJson {
    const p = lib.pairing orelse return .{ .code = null, .paired = lib.replica != null, .closed = lib.replica == null };
    const received, const closed = p.offer.outcome(lib.io());
    if (received) |secrets| {
        const kind = p.offer.kind;
        stopPairing(lib);
        if (kind == .pair) try lib.store.pair(arena, &std.fmt.bytesToHex(secrets.person, .lower));
        try openFounded(lib, arena, secrets.founder);
        return .{ .code = null, .paired = true, .closed = false };
    }
    if (closed) {
        stopPairing(lib);
        return .{ .code = null, .paired = false, .closed = true };
    }
    return .{ .code = try arena.dupe(u8, &p.offer.code), .paired = false, .closed = false };
}

/// Stops offering to pair, if it is.
export fn cq_pair_stop(lib: *Library) void {
    stopPairing(lib);
}

fn stopPairing(lib: *Library) void {
    const p = lib.pairing orelse return;
    p.host.stop();
    p.arena.deinit();
    gpa.destroy(p);
    lib.pairing = null;
}

/// Long: pairs the new device offering at `url` (a `pairing` device's, from
/// `cq_nearby`, offering to `pair` or to `join`, as `join` says), given the
/// code it shows: sends it the library's founder's key, and if pairingAsYours,
/// this person's secret, which it takes only if the code is right. Returns
/// its keys, as JSON: `person` (this person's, once paired; else a new
/// member's, to be added by `cq_member`) and `device` (to name it by, with
/// `cq_name`). Fails with
/// `WrongCode`, or `Closed` once it stopped.
export fn cq_pair(lib: *Library, url: [*:0]const u8, join: c_int, code: [*:0]const u8) ?[*:0]u8 {
    return json(lib, pairWith, .{ std.mem.span(url), if (join != 0) pair.Kind.join else pair.Kind.pair, std.mem.span(code) });
}

fn pairWith(lib: *Library, arena: std.mem.Allocator, url: []const u8, kind: pair.Kind, code: []const u8) !PairedJson {
    var client: std.http.Client = .{ .allocator = gpa, .io = lib.io() };
    defer client.deinit();
    const digits = std.mem.trim(u8, code, " \n");
    const joined = try pair.send(lib.io(), arena, &client, url, kind, digits, .{ .person = lib.store.identity.person, .founder = try lib.store.founder(arena) });
    // A paired device acts as this person from now on, not as the one it had.
    const person = if (kind == .pair) try lib.store.person() else joined.person;
    return .{
        .person = try arena.dupe(u8, &std.fmt.bytesToHex(person, .lower)),
        .device = try arena.dupe(u8, &std.fmt.bytesToHex(joined.device, .lower)),
    };
}

/// The members, as a JSON array of objects with `key`, `name` (null if
/// none's set), `founder`, and `you`.
export fn cq_members(lib: *Library) ?[*:0]u8 {
    return json(lib, members, .{});
}

fn members(lib: *Library, arena: std.mem.Allocator) ![]const MemberJson {
    const r = try lib.main();
    const me = try lib.store.person();
    const list = try r.members(arena);
    const named = try library.names(r, arena);
    const out = try arena.alloc(MemberJson, list.len);
    for (list, out) |m, *o| o.* = .{
        .key = try arena.dupe(u8, &std.fmt.bytesToHex(m, .lower)),
        .name = library.nameOf(named, &std.fmt.bytesToHex(m, .lower)),
        .founder = std.mem.eql(u8, &m, &r.founder),
        .you = std.mem.eql(u8, &m, &me),
    };
    return out;
}

/// Adds (nonzero `add`) or removes a member, by person key.
export fn cq_member(lib: *Library, key: [*:0]const u8, add: c_int) c_int {
    return status(lib, member, .{ std.mem.span(key), add != 0 });
}

fn member(lib: *Library, _: std.mem.Allocator, key: []const u8, add: bool) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    const r = try lib.main();
    const person = try store_.parseKey(std.mem.trim(u8, key, " \n"));
    if (add) try r.addMember(lib.now(), person) else try r.removeMember(lib.now(), person);
}

// Names and devices.

/// Names this person (`which` "person") or this device ("device"), for every
/// device to show in place of keys.
export fn cq_set_name(lib: *Library, which: [*:0]const u8, name: [*:0]const u8) c_int {
    return status(lib, setName, .{ std.mem.span(which), std.mem.span(name) });
}

fn setName(lib: *Library, arena: std.mem.Allocator, which: []const u8, name: []const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    const r = try lib.main();
    if (std.mem.eql(u8, which, "person"))
        try library.setName(r, arena, lib.now(), try lib.store.person(), name, null)
    else if (std.mem.eql(u8, which, "device"))
        try library.setName(r, arena, lib.now(), try lib.store.device(), name, try lib.store.person())
    else
        return error.Usage;
}

/// Names another device, `device`, as its person's, `person` (as one just
/// paired, until it names itself); any member may.
export fn cq_name(lib: *Library, device: [*:0]const u8, person: [*:0]const u8, name: [*:0]const u8) c_int {
    return status(lib, nameDevice, .{ std.mem.span(device), std.mem.span(person), std.mem.span(name) });
}

fn nameDevice(lib: *Library, arena: std.mem.Allocator, device: []const u8, person: []const u8, name: []const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    try library.setName(try lib.main(), arena, lib.now(), try store_.parseKey(device), name, try store_.parseKey(person));
}

/// This person's devices that have names, as a JSON array of objects with
/// `key`, `name`, and `you` (this one).
export fn cq_devices(lib: *Library) ?[*:0]u8 {
    return json(lib, devices, .{});
}

fn devices(lib: *Library, arena: std.mem.Allocator) ![]const DeviceJson {
    const r = try lib.main();
    const me = std.fmt.bytesToHex(try lib.store.person(), .lower);
    const this = std.fmt.bytesToHex(try lib.store.device(), .lower);
    var out: std.ArrayList(DeviceJson) = .empty;
    for (try library.names(r, arena)) |n| if (n.person) |u| if (std.mem.eql(u8, u, &me)) {
        // Those removed aren't this person's devices any more.
        const key = store_.parseKey(n.key) catch continue;
        if (try r.revoked(key) != null) continue;
        try out.append(arena, .{ .key = n.key, .name = n.name, .you = std.mem.eql(u8, n.key, &this) });
    };
    return out.items;
}

/// Removes another device (`device`, a key) from the library: its writes
/// past where this one has seen them are refused everywhere, and it's
/// served no more. It still holds its person's secret, and could pair again
/// as a new device.
export fn cq_remove_device(lib: *Library, device: [*:0]const u8) c_int {
    return status(lib, removeDevice, .{std.mem.span(device)});
}

fn removeDevice(lib: *Library, _: std.mem.Allocator, device: []const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    try (try lib.main()).revokeDevice(lib.now(), try store_.parseKey(device));
}

/// Long (it listens for 2 seconds): the devices found on the network, by
/// DNS-SD, other than this one, and those added by address, as a JSON
/// array of objects with `url` (to sync with, or for one `pairing`, to pair
/// with), `device` and `person` (their names, if advertised), `person` (key),
/// `ours` (of this library), `member` (its person is one), `added`, and
/// `pairing` (for a new device offering to pair, by `cq_pair`, what for:
/// `pair`, to be another of this person's, or `join`, a new member's).
export fn cq_nearby(lib: *Library) ?[*:0]u8 {
    return json(lib, nearby, .{});
}

fn nearby(lib: *Library, arena: std.mem.Allocator) ![]const NearbyJson {
    var r = try connection(lib, arena);
    defer r.close();
    const mine = std.fmt.bytesToHex(r.library, .lower);
    const own = try lib.store.serviceName(arena);
    const list = try r.members(arena);
    var out: std.ArrayList(NearbyJson) = .empty;
    for (try discover.browse(lib.io(), arena, 2000)) |s| {
        if (s.host.len == 0 or std.mem.eql(u8, s.name, own)) continue;
        const person = s.get("user");
        const is_member = if (person) |u| for (list) |m| {
            if (std.mem.eql(u8, &std.fmt.bytesToHex(m, .lower), u)) break true;
        } else false else false;
        try out.append(arena, .{
            .url = try sync.foundUrl(arena, s),
            .device = s.get("name"),
            // As DNS-SD resolved it: an Apple TV's is its own name
            // (`Not-Your-AppleTV.local`), when tvOS tells apps only "Apple TV".
            .host = s.host,
            .person = s.get("person"),
            .person_key = person,
            .ours = std.mem.eql(u8, s.get("library") orelse "", &mine),
            .member = is_member,
            .added = false,
            .pairing = s.get("pair"),
        });
    }
    for (try sync.addedAddresses(&r, arena)) |u|
        try out.append(arena, .{ .url = u, .device = null, .person = null, .person_key = null, .ours = true, .member = true, .added = true, .pairing = null });
    return out.items;
}

/// Adds (nonzero `add`) or removes a device by address, such as one off the
/// network, which syncing then reaches too; on this device only.
export fn cq_device_address(lib: *Library, target: [*:0]const u8, add: c_int) c_int {
    return status(lib, deviceAddress, .{ std.mem.span(target), add != 0 });
}

fn deviceAddress(lib: *Library, arena: std.mem.Allocator, target: []const u8, add: bool) !void {
    _ = try sync.setAdded(try lib.main(), arena, target, add);
}

// Sources.

/// The sources, as a JSON array of objects with `id`, `url`,
/// `quality`, `skip`, `copies`, `managed` (a device's downloads), and
/// `unavailable`, its unavailable directories
/// (`dir`, relative to it, empty for the whole of it, and `since`, in
/// milliseconds since the epoch).
export fn cq_repos(lib: *Library) ?[*:0]u8 {
    return json(lib, sources, .{});
}

const AbsenceJson = struct { dir: []const u8, since: u64 };
const SourceJson = struct { id: []const u8, url: []const u8, quality: []const u8, skip: []const u8, copies: i64, unavailable: []const AbsenceJson, managed: bool };

fn sources(lib: *Library, arena: std.mem.Allocator) ![]const SourceJson {
    const r = try lib.main();
    const list = try library.sources(r, arena);
    const out = try arena.alloc(SourceJson, list.len);
    for (list, out) |rp, *o| o.* = .{
        .id = try arena.dupe(u8, &rp.id),
        .url = rp.url,
        .quality = rp.layout.quality,
        .skip = rp.layout.skip,
        .copies = try library.countCopies(r, arena, rp),
        .managed = rp.managed,
        .unavailable = blk: {
            const list_ = try library.unavailableDirs(r, arena, &rp.id);
            const unavailable = try arena.alloc(AbsenceJson, list_.len);
            for (list_, unavailable) |a, *j| j.* = .{ .dir = a.dir, .since = a.since_ms };
            break :blk unavailable;
        },
    };
    return out;
}

/// Long (up to `race.timeout_ms`), on any thread: copy racing. Takes a JSON
/// array of an item's copies' URLs, in the order a player would try them,
/// and returns them in the order to try: those whose servers answer, at
/// once and briefly, first; a server that didn't lately, last (see
/// race.zig).
export fn cq_race(lib: *Library, urls_json: [*:0]const u8) ?[*:0]u8 {
    return json(lib, raceCopies, .{std.mem.span(urls_json)});
}

fn raceCopies(lib: *Library, arena: std.mem.Allocator, urls_json: []const u8) ![]const []const u8 {
    const urls = try std.json.parseFromSliceLeaky([]const []const u8, arena, urls_json, .{ .allocate = .alloc_always });
    return race.order(lib.io(), gpa, arena, &lib.racing, urls, lib.now());
}

/// Notes that a copy didn't load, so its server is raced last for a while.
/// Any thread.
export fn cq_race_lost(lib: *Library, url: [*:0]const u8) void {
    lib.racing.lost(lib.io(), gpa, std.mem.span(url), lib.now()) catch {};
}

// Downloads (see download.zig).

/// Sets where this device keeps downloads (`dir`), the URL it serves them
/// at (made a source of its own, which no one crawls), and whether
/// downloads watched since fetched are deleted at once (nonzero) or only as
/// space is needed; either way, only once another source holds them,
/// and never pinned ones.
export fn cq_downloads_configure(lib: *Library, dir: [*:0]const u8, served_at: [*:0]const u8, drop_watched: c_int) c_int {
    return status(lib, downloadsConfigure, .{ std.mem.span(dir), std.mem.span(served_at), drop_watched != 0 });
}

fn downloadsConfigure(lib: *Library, arena: std.mem.Allocator, dir: []const u8, served_at: []const u8, drop_watched: bool) !void {
    try lib.writer.lock(lib.io());
    defer lib.writer.unlock(lib.io());
    try download.configure(try lib.main(), arena, lib.now(), dir, served_at, drop_watched);
}

/// Wants a title's, a season's (`<title>/e/s01`), or an item's files kept
/// on this device (each item as of now), in `quality` (null or empty:
/// the one most items have); `cq_reconcile` fetches them.
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

/// Downloads a series' next `episodes` (after where this person is), as
/// it's watched; 0 stops.
export fn cq_download_next(lib: *Library, title_key: [*:0]const u8, episodes: c_int) c_int {
    return status(lib, downloadNext, .{ std.mem.span(title_key), @as(u32, @intCast(std.math.clamp(episodes, 0, 1000))) });
}

fn downloadNext(lib: *Library, arena: std.mem.Allocator, title_key: []const u8, episodes: u32) !void {
    try download.setNext(try lib.main(), arena, title_key, episodes);
}

const HeldJson = struct { item: []const u8, size: u64, only: bool };
const DoneJson = struct { item: []const u8, deletable: bool };

/// Keeps a download (nonzero), so it's never deleted as watched, or lets
/// it go.
export fn cq_keep(lib: *Library, item_key: [*:0]const u8, on: c_int) c_int {
    return status(lib, keep, .{ std.mem.span(item_key), on != 0 });
}

fn keep(lib: *Library, arena: std.mem.Allocator, item_key: []const u8, on: bool) !void {
    try download.setKept(try lib.main(), arena, item_key, on);
}
const DownloadsJson = struct {
    dir: ?[]const u8,
    source: ?[]const u8,
    drop_watched: bool,
    held: []const HeldJson,
    wanted: []const download.Want,
    next: []const download.Next,
    watched: []const DoneJson,
    kept: []const []const u8,
    free: ?u64,
    floor: u64,
    running: bool,
    done_mb: u32,
    total_mb: u32,
};

/// This device's downloads, as a JSON object: `dir`, `source` (its ID),
/// and `drop_watched`, as configured (null if not); `held`, the files held
/// (`item`, `size`, and whether it's the `only` copy, no other source
/// holding it alike); `wanted` (`key`, `quality`); `next`, series whose
/// next episodes download (`title`, `episodes`); `watched`, downloads
/// watched since fetched and not kept, oldest first (`item`, and
/// `deletable`, once held elsewhere, else the only copy); `kept` items; `free` bytes on its volume, if
/// known, and the
/// `floor` kept free; and whether `cq_reconcile` is `running`, with
/// `done_mb` of `total_mb`.
export fn cq_downloads(lib: *Library) ?[*:0]u8 {
    return json(lib, downloads, .{});
}

fn downloads(lib: *Library, arena: std.mem.Allocator) !DownloadsJson {
    const r = try lib.main();
    try download.purgeObsolete(r, arena);
    const s = try download.settings(r, arena);
    var list: std.ArrayList(HeldJson) = .empty;
    if (s) |set| {
        const all = try library.sources(r, arena);
        const unavailable = try library.UnavailableDirs.load(r, arena);
        for (try download.held(r, arena, set.source)) |h|
            try list.append(arena, .{ .item = h.item, .size = h.size, .only = !try download.confirmed(r, all, &unavailable, h) });
    }
    var finished: std.ArrayList(DoneJson) = .empty;
    if (s) |set| for (try download.finishedWith(r, arena, set.source)) |d| try finished.append(arena, .{ .item = d.held.item, .deletable = d.deletable });
    return .{
        .dir = if (s) |set| set.dir else null,
        .source = if (s) |set| try arena.dupe(u8, &set.source.id) else null,
        .drop_watched = if (s) |set| set.drop_watched else false,
        .held = list.items,
        .wanted = try download.wants(r, arena),
        .next = try download.nexts(r, arena),
        .watched = finished.items,
        .kept = try download.kept(r, arena),
        .free = if (s) |set| download.freeBytes(arena, set.dir) else null,
        .floor = download.floor(),
        .running = lib.reconciling.load(.acquire),
        .done_mb = lib.downloaded_mb.load(.monotonic),
        .total_mb = lib.download_mb.load(.monotonic),
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
    defer lib.reconciling.store(false, .release);
    var r = try connection(lib, arena);
    defer r.close();
    var client: std.http.Client = .{ .allocator = gpa, .io = lib.io() };
    defer client.deinit();
    var out: ReconciledJson = .{};
    // Again while asked again (a download wanted meanwhile).
    while (lib.reconcile_again.swap(false, .acq_rel)) {
        try r.refresh();
        const done = try download.reconcile(lib.io(), gpa, arena, &client, &lib.racing, &r, &lib.writer, lib.now(), .{ .done = &lib.downloaded_mb, .total = &lib.download_mb }, &lib.hold);
        out.fetched += done.fetched;
        out.kept = done.kept;
        out.deleted += done.deleted;
        out.failed = done.failed;
        out.no_room = done.no_room;
        out.held = done.held;
        out.@"error" = done.@"error";
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
    try @import("url.zig").escape(arena, &typed, std.mem.trim(u8, target, " \n"));
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
    _ = try library.setSource(try lib.main(), arena, lib.now(), source, quality, skip);
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

// Long operations, each on a connection of its own.

fn connection(lib: *Library, arena: std.mem.Allocator) !Replica {
    return lib.store.openReplica(arena);
}

/// Long: crawls every source, committing each as it's crawled, then
/// describes what's new (covers and metadata) with concurrent workers,
/// committing as it goes and taking prioritized titles (`cq_prioritize`)
/// first. Returns a JSON array of objects with `url`, `files`, `titles`,
/// and `error` (null, or why its crawl failed), one per source.
export fn cq_crawl(lib: *Library) ?[*:0]u8 {
    return json(lib, crawlAll, .{});
}

fn crawlAll(lib: *Library, arena: std.mem.Allocator) ![]const CrawlJson {
    var r = try connection(lib, arena);
    defer r.close();
    var client: std.http.Client = .{ .allocator = gpa, .io = lib.io() };
    defer client.deinit();
    const list = try library.sources(&r, arena);
    const out = try arena.alloc(CrawlJson, list.len);
    var crawled: std.ArrayList(art.Crawled) = .empty;
    lib.steps.start(.crawling, list.len);
    defer lib.steps.finish();
    for (list, out) |rp, *o| {
        defer lib.steps.step();
        if (rp.managed) {
            o.* = .{ .url = rp.url, .files = 0, .titles = 0, .covers = 0, .@"error" = null };
            continue;
        }
        try lib.writer.lock(lib.io());
        defer lib.writer.unlock(lib.io());
        try r.refresh();
        const s = library.crawlSource(&r, lib.io(), arena, &client, lib.now(), rp, 16) catch |err| {
            o.* = .{ .url = rp.url, .files = 0, .titles = 0, .covers = 0, .@"error" = @errorName(err) };
            continue;
        };
        o.* = .{ .url = rp.url, .files = s.ingest.files, .titles = s.ingest.titles_added, .covers = 0, .@"error" = null };
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
    return json(lib, syncAll, .{span(target)});
}

fn syncAll(lib: *Library, arena: std.mem.Allocator, target: ?[]const u8) ![]const SyncJson {
    // Devices are counted once they're found.
    lib.steps.start(.syncing, 0);
    defer lib.steps.finish();
    try lib.writer.lock(lib.io());
    defer lib.writer.unlock(lib.io());
    var r = try connection(lib, arena);
    defer r.close();
    const reachable = try sync.reachable(lib.io(), arena, &r, try lib.store.serviceName(arena), target);
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

// Browsing.

/// The grid's tiles, as a JSON array of objects with `key` (the title's),
/// `name`, `year`, `kind` (`movie` or `series`), `season` (a series', or
/// null), and `cover` (null, or `url`, `offset`, `length`, and `stamp`, a
/// byte range to fetch, and what changes when it does), `thumb` (null, or
/// the cover's placeholder, a ThumbHash in base64, for `cq_thumbhash`), and
/// this person's `watched` (every item), `progress` (0 to 1, by running time),
/// `elapsed` and `runtime` (milliseconds played, of how many), and `started`;
/// and `unavailable`, whether every copy it has is under an unavailable directory.
export fn cq_tiles(lib: *Library) ?[*:0]u8 {
    return json(lib, tiles, .{});
}


fn tiles(lib: *Library, arena: std.mem.Allocator) ![]const TileJson {
    const r = try lib.main();
    const bases = try sourceBases(r, arena);
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
        .elapsed = t.played,
        .runtime = t.total,
        .started = t.started,
        .unavailable = t.unavailable,
    };
    return out;
}

fn sourceBases(r: *Replica, arena: std.mem.Allocator) !std.StringHashMapUnmanaged(library.Source) {
    var bases: std.StringHashMapUnmanaged(library.Source) = .empty;
    for (try library.sources(r, arena)) |rp| try bases.put(arena, try arena.dupe(u8, &rp.id), rp);
    return bases;
}

fn coverJson(arena: std.mem.Allocator, bases: std.StringHashMapUnmanaged(library.Source), c: art.Cover) !?CoverJson {
    const rp = bases.get(c.source) orelse return null;
    return .{ .url = try art.fileUrl(arena, rp.url, c.path), .offset = c.offset, .length = c.length, .stamp = c.stamp };
}

/// One title, as a JSON object with `key`, `name`, `year`, `aliasOf`,
/// `aliases`, `fields` (its metadata, e.g., `description` and `genre`),
/// `covers` (by field, `art` or `art:s01`...), and `items`, each with its
/// `key`, `fields` (e.g., an episode's `title`), this person's `position`,
/// `duration` (milliseconds), and `watched`, and `qualities`, each with
/// its `label`, `name` (as its sources give it), and `copies`: `url`
/// (ready to play), `size`, `mtime`, `source`, and `unavailable` (under an
/// unavailable directory of its source). Null if there's no such title.
export fn cq_title(lib: *Library, key: [*:0]const u8) ?[*:0]u8 {
    return json(lib, title, .{std.mem.span(key)});
}

const CopyJson = struct { url: []const u8, size: u64, mtime: []const u8, source: []const u8, unavailable: bool };
const QualityJson = struct { label: []const u8, name: []const u8, copies: []const CopyJson };
const ItemJson = struct { key: []const u8, fields: std.json.ArrayHashMap([]const u8), qualities: []const QualityJson, position: u64, duration: u64, watched: bool };

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
    const bases = try sourceBases(r, arena);
    const items = try arena.alloc(ItemJson, d.items.items.len);
    for (d.items.items, items) |item, *io| {
        const qualities = try arena.alloc(QualityJson, item.qualities.items.len);
        for (item.qualities.items, qualities) |rn, *ro| {
            const copies = try arena.alloc(CopyJson, rn.copies.items.len);
            var name = rn.label;
            for (rn.copies.items, copies) |h, *c| {
                const rp = bases.get(h.source);
                c.* = .{ .url = if (rp) |b| try art.fileUrl(arena, b.url, h.path) else "", .size = h.size, .mtime = h.mtime, .source = h.source, .unavailable = h.unavailable };
                // The quality's name as its sources give it.
                if (rp) |b| if (b.layout.quality.len > 0) {
                    name = b.layout.quality;
                };
            }
            ro.* = .{ .label = rn.label, .name = name, .copies = copies };
        }
        io.* = .{
            .key = item.key,
            .fields = .{ .map = item.fields },
            .qualities = qualities,
            .position = item.progress.position_ms,
            .duration = item.progress.duration_ms,
            .watched = item.progress.watched,
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

// This person's private data.

/// Records this person's progress in an item (a title's key and an item's,
/// e.g., `t/m/alien/1979/v/-`).
export fn cq_set_progress(lib: *Library, item_key: [*:0]const u8, position_ms: u64, duration_ms: u64) c_int {
    return status(lib, setProgress, .{ std.mem.span(item_key), position_ms, duration_ms });
}

fn setProgress(lib: *Library, arena: std.mem.Allocator, item_key: []const u8, position_ms: u64, duration_ms: u64) !void {
    const r = try privateWriter(lib);
    defer if (r.locked) lib.writer.unlock(lib.io());
    try library.setProgress(r.replica, arena, lib.now(), item_key, position_ms, duration_ms);
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

/// Removes this person's progress in an item: its position and watched mark.
export fn cq_remove_progress(lib: *Library, item_key: [*:0]const u8) c_int {
    return status(lib, removeProgress, .{std.mem.span(item_key)});
}

fn removeProgress(lib: *Library, arena: std.mem.Allocator, item_key: []const u8) !void {
    const r = try privateWriter(lib);
    defer if (r.locked) lib.writer.unlock(lib.io());
    try library.removeProgress(r.replica, arena, lib.now(), item_key);
}

/// What's on this person's watchlist, as a JSON array of keys: a movie's
/// title key, or a season's tile (`<title key>#<season>`).
export fn cq_watchlist(lib: *Library) ?[*:0]u8 {
    return json(lib, getWatchlist, .{});
}

fn getWatchlist(lib: *Library, arena: std.mem.Allocator) ![]const []const u8 {
    return art.watchlist(try lib.main(), arena);
}

/// Adds a movie or a season (as `cq_watchlist` keys them) to this person's
/// watchlist (nonzero `on`), or removes it.
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
