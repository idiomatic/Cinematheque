//! The C interface (see ../capi.zig): identity and membership.

const std = @import("std");
const capi = @import("../capi.zig");
const stopServing = @import("serving.zig").stopServing;
const stopPairing = @import("pairing.zig").stopPairing;
const library = @import("../library.zig");
const store_ = @import("../store.zig");
const sync = @import("../sync.zig");
const pair = @import("../pair.zig");
const gpa = capi.gpa;
const Library = capi.Library;
const open = capi.open;
const json = capi.json;
const status = capi.status;
const StatusJson = capi.StatusJson;

/// This device, as JSON: `person` (its person's key), `paired` (acting as the
/// person of another of the person's devices), `library` (the library's ID,
/// or null if it has none yet), `founder`, `members` (how many), and
/// `others` (how many other devices its person has, certified or named, and
/// not removed: none, and leaving takes the person's devices with it), and
/// `crawl_every` (`cq_crawl_every`'s hours, 0 for Manually).
export fn cq_status(lib: *Library) ?[*:0]u8 {
    return json(lib, getStatus, .{});
}

fn getStatus(lib: *Library, arena: std.mem.Allocator) !StatusJson {
    const person = try arena.dupe(u8, &std.fmt.bytesToHex(try lib.store.person(), .lower));
    const paired = lib.store.paired();
    const r = lib.main() catch return .{ .person = person, .paired = paired, .library = null, .founder = null, .members = 0, .others = 0 };
    const me = try lib.store.person();
    const this = try lib.store.device();
    var others: std.AutoArrayHashMapUnmanaged([32]u8, void) = .empty;
    for (try r.devicesOf(arena, me)) |d| try others.put(arena, d, {});
    // Named by the device that paired it, before it's written a certificate.
    const hex = std.fmt.bytesToHex(me, .lower);
    for (try library.names(r, arena)) |n| if (n.person) |u| if (std.mem.eql(u8, u, &hex)) {
        try others.put(arena, store_.parseKey(n.key) catch continue, {});
    };
    _ = others.swapRemove(this);
    var count: usize = 0;
    for (others.keys()) |d| {
        if (try r.revoked(d) == null) count += 1;
    }
    return .{
        .person = person,
        .paired = paired,
        .library = try arena.dupe(u8, &std.fmt.bytesToHex(r.library, .lower)),
        .founder = try arena.dupe(u8, &std.fmt.bytesToHex(r.founder, .lower)),
        .members = (try r.members(arena)).len,
        .others = count,
        .crawl_every = (try library.crawlEvery(r, arena)) orelse 0,
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
    // Not while another thread has a connection open (looking for devices,
    // reconciling downloads), whose files and store this would pull away.
    lib.leaving.store(true, .seq_cst);
    defer lib.leaving.store(false, .seq_cst);
    if (lib.connections.load(.seq_cst) > 0) return error.Busy;
    stopServing(lib);
    stopPairing(lib);
    lib.has_library.store(false, .seq_cst);
    if (lib.replica) |*r| r.close();
    lib.replica = null;
    lib.known.deinit();
    lib.known = .{};
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
pub fn openFounded(lib: *Library, arena: std.mem.Allocator, founder: [32]u8) !void {
    if (lib.replica != null) return error.LibraryExists;
    // Once it has a library, it no longer offers to pair.
    stopPairing(lib);
    try lib.store.setFounder(arena, founder);
    lib.replica = try lib.store.openReplica(lib.arena_state.allocator());
    lib.has_library.store(true, .seq_cst);
}
