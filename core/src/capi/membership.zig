//! The C interface (see ../capi.zig): identity and membership.

const std = @import("std");
const capi = @import("../capi.zig");
const stopServing = @import("serving.zig").stopServing;
const stopPairing = @import("pairing.zig").stopPairing;
const library = @import("../library.zig");
const store_ = @import("../store.zig");
const gpa = capi.gpa;
const Library = capi.Library;
const json = capi.json;
const status = capi.status;
const StatusJson = capi.StatusJson;

/// This device, as JSON: `person` (its person's key), `paired` (acting as the
/// person of another of the person's devices), `library` (the library's ID,
/// or null if it has none yet), `members` (how many), and
/// `others` (how many other devices its person has, certified or named, and
/// not removed: none, and leaving takes the person's devices with it), and
/// `crawl_every` (`cq_crawl_every`'s hours, 0 for Manually).
export fn cq_status(lib: *Library) ?[*:0]u8 {
    return json(lib, getStatus, .{});
}

fn getStatus(lib: *Library, arena: std.mem.Allocator) !StatusJson {
    const person = try arena.dupe(u8, &std.fmt.bytesToHex(try lib.store.person(), .lower));
    // This device's key, for its own sources' addresses (`cqdevice://`).
    const device = try arena.dupe(u8, &std.fmt.bytesToHex(try lib.store.device(), .lower));
    const paired = lib.store.paired();
    const r = lib.main() catch return .{ .person = person, .device = device, .paired = paired, .library = null, .members = 0, .others = 0 };
    return .{
        .person = person,
        .device = device,
        .paired = paired,
        .library = try arena.dupe(u8, &std.fmt.bytesToHex(r.library, .lower)),
        .members = (try r.members(arena)).len,
        .others = (try library.otherDevices(r, arena)).len,
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
}

/// Creates a library, with this person its first member. (Joining one is
/// by pairing.)
export fn cq_found(lib: *Library) c_int {
    return status(lib, found, .{});
}

fn found(lib: *Library, arena: std.mem.Allocator) !void {
    if (lib.replica != null) return error.LibraryExists;
    // Once it has a library, it no longer offers to pair.
    stopPairing(lib);
    try lib.store.setCreator(arena, try lib.store.person());
    try openJoined(lib);
}

/// Opens the library the store now records as this device's.
pub fn openJoined(lib: *Library) !void {
    lib.replica = try lib.store.openReplica(lib.arena_state.allocator());
    lib.has_library.store(true, .seq_cst);
}
