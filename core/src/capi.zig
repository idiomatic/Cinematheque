//! A C interface to the library, for apps in other languages (Swift, for the
//! Apple players). Results are JSON strings, freed with `cq_free`; on
//! failure, functions return null (or -1) and `cq_error` says why. See
//! include/cinematheque.h, and include/README.md, which documents it.
//!
//! Threads: functions on a library, except those marked as long, belong to
//! one thread (the app's main one), on the library's own connection. Long
//! ones (crawling, syncing, describing) may run on any thread, each on a
//! connection of its own. Only one connection writes as this device at a
//! time: long ones wait for each other, and other writes fail with `Busy`
//! while one runs, but for progress and lists, which don't need to.

pub const std = @import("std");

/// Warnings too, not errors alone (a release build's default), on the
/// apps' stderr: what's slow says so (copy racing, say).
pub const std_options: std.Options = .{ .log_level = .warn };
const Io = std.Io;
pub const library = @import("library.zig");
pub const art = @import("art.zig");
pub const thumbhash = @import("thumbhash.zig");
pub const store_ = @import("store.zig");
pub const sync = @import("sync.zig");
pub const discover = @import("discover.zig");
pub const Host = @import("host.zig").Host;
pub const race = @import("race.zig");
pub const download = @import("download.zig");
pub const views = @import("views.zig");
pub const pair = @import("pair.zig");
pub const replica_ = @import("replica.zig");
const Replica = replica_.Replica;
// What the library holds of serving, pairing, and syncing, from their parts.
const Known = @import("capi/long.zig").Known;
const Serving = @import("capi/serving.zig").Serving;
const stopServing = @import("capi/serving.zig").stopServing;
const Pairing = @import("capi/pairing.zig").Pairing;
const stopPairing = @import("capi/pairing.zig").stopPairing;

pub const gpa = std.heap.c_allocator;

pub threadlocal var last_error: [256:0]u8 = @splat(0);

pub fn fail(err: anyerror) void {
    _ = std.fmt.bufPrintSentinel(&last_error, "{t}", .{err}, 0) catch {};
}

pub const Library = struct {
    threaded: Io.Threaded,
    arena_state: std.heap.ArenaAllocator,
    store: store_.Store,
    /// The main thread's connection, once there's a library.
    replica: ?Replica = null,
    /// Held while a connection writes as this device.
    writer: Io.Mutex = .init,
    /// Connections other threads have open (`connection`), and whether
    /// the library is being left: leaving waits for none, but refuses
    /// while any is open, and none opens while it leaves.
    connections: std.atomic.Value(u32) = .init(0),
    leaving: std.atomic.Value(bool) = .init(false),
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
    /// The devices a sync last found nearby, for one that doesn't look
    /// again (`cq_sync_known`).
    known: Known = .{},
    /// Reconciling downloads (`cq_reconcile`), apart from `progress`, since
    /// it runs alongside crawls: whether it runs, whether it's asked to run
    /// again, and how far it's come, in megabytes.
    reconciling: std.atomic.Value(bool) = .init(false),
    reconcile_again: std.atomic.Value(bool) = .init(false),
    downloaded_mb: std.atomic.Value(u32) = .init(0),
    fetching: download.Fetching = .{},
    /// Set while a stream plays (`cq_downloads_hold`): no download begins.
    hold: std.atomic.Value(bool) = .init(false),
    download_mb: std.atomic.Value(u32) = .init(0),

    pub fn onServed(context: ?*anyopaque, device: [32]u8, operations: usize) void {
        const lib: *Library = @ptrCast(@alignCast(context.?));
        lib.served.note(lib, device, operations);
    }

    pub fn onReceived(context: ?*anyopaque, device: [32]u8, operations: usize) void {
        const lib: *Library = @ptrCast(@alignCast(context.?));
        lib.received.note(lib, device, operations);
    }

    pub fn io(lib: *Library) Io {
        return lib.threaded.io();
    }

    pub fn now(lib: *Library) u64 {
        return @intCast(Io.Timestamp.now(lib.io(), .real).toMilliseconds());
    }

    /// The main connection, caught up with other connections' writes.
    pub fn main(lib: *Library) !*Replica {
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

/// What this build is, as JSON (`version`, `mode`, `zig`); see
/// version.zig. Any thread.
export fn cq_version() ?[*:0]u8 {
    return stringify(@import("version.zig").info) catch |err| {
        fail(err);
        return null;
    };
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

pub fn open(data_dir: ?[*:0]const u8) !*Library {
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
    _ = lib.store.founder(arena) catch |err| switch (err) {
        error.NoLibrary => return lib,
        else => |e| return e,
    };
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
    l.known.deinit();
    l.arena_state.deinit();
    l.threaded.deinit();
    gpa.destroy(l);
}

pub fn stringify(value: anytype) ![*:0]u8 {
    const text = try @import("json.zig").valueAlloc(gpa, value);
    defer gpa.free(text);
    return (try gpa.dupeSentinel(u8, text, 0)).ptr;
}

/// Runs `f(lib, arena, args...)`, returning its JSON, or null on failure.
pub fn json(lib: *Library, comptime f: anytype, args: anytype) ?[*:0]u8 {
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
pub fn status(lib: *Library, comptime f: anytype, args: anytype) c_int {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    @call(.auto, f, .{ lib, arena_state.allocator() } ++ args) catch |err| {
        fail(err);
        return -1;
    };
    return 0;
}

pub fn span(text: ?[*:0]const u8) ?[]const u8 {
    return if (text) |t| std.mem.span(t) else null;
}

/// A C array of `count` strings as slices (not copied); null for none.
pub fn spans(arena: std.mem.Allocator, items: ?[*]const [*:0]const u8, count: usize) ![]const []const u8 {
    if (count == 0) return &.{};
    const p = items orelse return error.InvalidArgument;
    const out = try arena.alloc([]const u8, count);
    for (p[0..count], out) |t, *o| o.* = std.mem.span(t);
    return out;
}

/// An optional integer from C, -1 for none; any other out of range fails.
pub fn optional(comptime T: type, value: c_int) !?T {
    if (value == -1) return null;
    return std.math.cast(T, value) orelse error.InvalidArgument;
}

/// A C enum's value as the Zig enum it mirrors, failing for any other.
pub fn enumFrom(comptime E: type, value: c_int) !E {
    return std.enums.fromInt(E, value) orelse error.InvalidArgument;
}

pub const MemberJson = struct { key: []const u8, name: ?[]const u8, founder: bool, you: bool };
pub const DeviceJson = struct { key: []const u8, name: []const u8, you: bool };
pub const NearbyJson = struct { url: []const u8, device: ?[]const u8, host: ?[]const u8 = null, person: ?[]const u8, person_key: ?[]const u8, ours: bool, member: bool, added: bool, pairing: ?[]const u8 };
pub const PairJson = struct { code: ?[]const u8, paired: bool, closed: bool };
pub const PairedJson = struct { person: []const u8, device: []const u8 };
/// A source's crawl: what it found, and for diagnosis, how long listing
/// (`crawl_ms`) and all of it (`total_ms`, recording what was found too)
/// took, how many listings it read and reused, and how many copies changed.
pub const CrawlJson = struct {
    url: []const u8,
    files: usize,
    titles: usize,
    covers: usize,
    @"error": ?[]const u8,
    crawl_ms: i64 = 0,
    total_ms: i64 = 0,
    requests: usize = 0,
    reused: usize = 0,
    changed: usize = 0,
    /// Why it wasn't crawled, if it wasn't.
    skipped: ?Skipped = null,
};

/// Why a crawl skipped a source: a device crawled it within the library's
/// interval (`cq_crawl_due`), the library's sources are looked in only when
/// asked (`cq_crawl_due`), or it's a device's downloads, never crawled.
pub const Skipped = enum { lately, manual, downloads };
pub const SyncJson = struct { url: []const u8, name: ?[]const u8 = null, new: usize, sent: usize = 0, @"error": ?[]const u8 };
pub const HeardJson = struct { device: []const u8, name: ?[]const u8, operations: usize, at: u64 };

/// An exchange the server had with a device, recorded on the server's task:
/// with which device, how many operations, and when.
pub const Heard = struct {
    mutex: Io.Mutex = .init,
    device: [32]u8 = @splat(0),
    operations: usize = 0,
    at: u64 = 0,

    pub fn note(h: *Heard, lib: *Library, device: [32]u8, operations: usize) void {
        h.mutex.lockUncancelable(lib.io());
        defer h.mutex.unlock(lib.io());
        h.device = device;
        h.operations = operations;
        h.at = lib.now();
    }

    /// As JSON, with the device's name if it has one; null if none yet.
    pub fn json(h: *Heard, lib: *Library, arena: std.mem.Allocator) !?HeardJson {
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
pub const StatusJson = struct { person: []const u8, paired: bool, library: ?[]const u8, founder: ?[]const u8, members: usize, others: usize, crawl_every: u64 = library.default_crawl_hours };

/// How far a long operation has come, in steps of its phase (sources
/// crawled, movies and seasons described, devices synced); read from any
/// thread.
pub const Steps = struct {
    phase: std.atomic.Value(Phase) = .init(.idle),
    done: std.atomic.Value(u32) = .init(0),
    total: std.atomic.Value(u32) = .init(0),

    const Phase = enum(u8) { idle, crawling, describing, syncing };

    pub fn start(p: *Steps, phase: Phase, total: usize) void {
        p.done.store(0, .monotonic);
        p.total.store(@intCast(total), .monotonic);
        p.phase.store(phase, .release);
    }

    pub fn step(p: *Steps) void {
        _ = p.done.fetchAdd(1, .monotonic);
    }

    pub fn finish(p: *Steps) void {
        p.phase.store(.idle, .release);
    }
};

pub const StepsJson = struct { phase: ?[]const u8, done: u32, total: u32 };

/// How far the long operation running has come: a JSON object with `phase`
/// (`crawling`, `describing`, `syncing`, or null when none runs), and
/// `done` and `total` steps of it. Any thread.
export fn cq_steps(lib: *Library) ?[*:0]u8 {
    return json(lib, steps, .{});
}

pub fn steps(lib: *Library, _: std.mem.Allocator) !StepsJson {
    const phase = lib.steps.phase.load(.acquire);
    return .{
        .phase = if (phase == .idle) null else @tagName(phase),
        .done = lib.steps.done.load(.monotonic),
        .total = lib.steps.total.load(.monotonic),
    };
}

// Each part of the interface, its exports kept by importing it.
comptime {
    _ = @import("capi/serving.zig");
    _ = @import("capi/membership.zig");
    _ = @import("capi/pairing.zig");
    _ = @import("capi/names.zig");
    _ = @import("capi/sources.zig");
    _ = @import("capi/downloads.zig");
    _ = @import("capi/long.zig");
    _ = @import("capi/browsing.zig");
    _ = @import("capi/private.zig");
}
