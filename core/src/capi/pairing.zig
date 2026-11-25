//! The C interface (see ../capi.zig): pairing.

const std = @import("std");
const capi = @import("../capi.zig");
const openJoined = @import("membership.zig").openJoined;
const store_ = @import("../store.zig");
const Host = @import("../host.zig").Host;
const pair = @import("../pair.zig");
const views = @import("../views.zig");
const gpa = capi.gpa;
const Library = capi.Library;
const json = capi.json;
const status = capi.status;
const PairJson = capi.PairJson;
const PairedJson = capi.PairedJson;

// Pairing: a new device shows a code, and a member's, given it, sends it
// the library's creator's key, and to pair another of its person's devices,
// the person's secret too (see pair.zig).

pub const Pairing = struct {
    offer: pair.Offer,
    arena: std.heap.ArenaAllocator,
    host: Host,
};

/// On a new device, before it has a library: offers to be added to one, as
/// another of a member's devices or a new member's, as the member's device
/// decides, serving and advertising by DNS-SD (as `name`, for the other
/// device to show) until paired or `cq_pair_stop`, with its `model` (an
/// Apple identifier, as `iPhone14,4`, shown by its name; or a name; or
/// empty), shown under its name. Returns its state, as `cq_pair_check`
/// does, with a new code. Offering again starts over, with another code.
export fn cq_pair_offer(lib: *Library, name: [*:0]const u8, model: [*:0]const u8) ?[*:0]u8 {
    return json(lib, pairOffer, .{ std.mem.span(name), std.mem.span(model) });
}

fn pairOffer(lib: *Library, arena: std.mem.Allocator, name: []const u8, model: []const u8) !PairJson {
    if (lib.replica != null) return error.LibraryExists;
    stopPairing(lib);
    const p = try gpa.create(Pairing);
    errdefer gpa.destroy(p);
    p.offer = try lib.store.offer(lib.io());
    p.arena = .init(gpa);
    errdefer p.arena.deinit();
    const a = p.arena.allocator();
    p.host = .{
        .io = lib.io(),
        .gpa = gpa,
        .options = .{ .host = "::", .port = 0, .handler = p.offer.handler() },
        .name = try lib.store.serviceName(a),
        .txt = try pair.offerRecord(a, name, model),
    };
    try p.host.start();
    lib.pairing = p;
    return .{ .code = try arena.dupe(u8, &p.offer.code), .paired = false, .closed = false };
}

/// On a new device offering to pair: its state, as JSON: `code` (to show,
/// while it offers), `paired` (it has the library, and if added as a
/// member's device, its person, and has stopped offering), and `closed` (it stopped, after too
/// many wrong codes; offer again for a new one).
export fn cq_pair_check(lib: *Library) ?[*:0]u8 {
    return json(lib, pairCheck, .{});
}

fn pairCheck(lib: *Library, arena: std.mem.Allocator) !PairJson {
    const p = lib.pairing orelse return .{ .code = null, .paired = lib.replica != null, .closed = lib.replica == null };
    const received, const closed = p.offer.outcome(lib.io());
    if (received) |secrets| {
        stopPairing(lib);
        try lib.store.join(arena, secrets);
        try openJoined(lib);
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

pub fn stopPairing(lib: *Library) void {
    const p = lib.pairing orelse return;
    p.host.stop();
    p.arena.deinit();
    gpa.destroy(p);
    lib.pairing = null;
}

/// Long: adds the new device offering at `url` (a `pairing` device's, from
/// `cq_nearby`), given the code it shows, as another of this person's
/// devices: sends it the library's creator's key and this person's secret,
/// which it takes only if the code is right. Returns its keys, as JSON:
/// `person` (this person's) and `device` (to name it by, with `cq_name`).
/// Fails with `WrongCode`, or `Closed` once it stopped.
export fn cq_pair_person(lib: *Library, url: [*:0]const u8, code: [*:0]const u8) ?[*:0]u8 {
    return json(lib, pairPerson, .{ std.mem.span(url), std.mem.span(code) });
}

fn pairPerson(lib: *Library, arena: std.mem.Allocator, url: []const u8, code: []const u8) !PairedJson {
    const joined = try send(lib, arena, url, .pair, code);
    // It acts as this person from now on, not as the one it had.
    return .{
        .person = try arena.dupe(u8, &std.fmt.bytesToHex(try lib.store.person(), .lower)),
        .device = try arena.dupe(u8, &std.fmt.bytesToHex(joined.device, .lower)),
    };
}

/// Long: as `cq_pair_person`, but adds the device as a new member's,
/// sending it only the library's creator's key. Its `person` is the new
/// member's, to add by `cq_member_add`.
export fn cq_pair_member(lib: *Library, url: [*:0]const u8, code: [*:0]const u8) ?[*:0]u8 {
    return json(lib, pairMember, .{ std.mem.span(url), std.mem.span(code) });
}

fn pairMember(lib: *Library, arena: std.mem.Allocator, url: []const u8, code: []const u8) !PairedJson {
    const joined = try send(lib, arena, url, .join, code);
    return .{
        .person = try arena.dupe(u8, &std.fmt.bytesToHex(joined.person, .lower)),
        .device = try arena.dupe(u8, &std.fmt.bytesToHex(joined.device, .lower)),
    };
}

/// Sends the device offering at `url` what pairing it as `kind` gives it.
fn send(lib: *Library, arena: std.mem.Allocator, url: []const u8, kind: pair.Kind, code: []const u8) !pair.Joined {
    var client: std.http.Client = .{ .allocator = gpa, .io = lib.io() };
    defer client.deinit();
    const digits = std.mem.trim(u8, code, " \n");
    return pair.send(lib.io(), arena, &client, url, kind, digits, .{ .person = lib.store.identity.person, .creator = try lib.store.creator(arena) });
}

/// The members, as a JSON array of objects with `key`, `name` (null if
/// none's set), and `you`.
export fn cq_members(lib: *Library) ?[*:0]u8 {
    return json(lib, members, .{});
}

fn members(lib: *Library, arena: std.mem.Allocator) ![]const views.MemberJson {
    return views.members(try lib.main(), arena);
}

/// Adds a member, by person key.
export fn cq_member_add(lib: *Library, key: [*:0]const u8) c_int {
    return status(lib, addMember, .{std.mem.span(key)});
}

fn addMember(lib: *Library, _: std.mem.Allocator, key: []const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    try (try lib.main()).addMember(lib.now(), try store_.parseKey(std.mem.trim(u8, key, " \n")));
}

/// Removes a member, by person key, for good: they come back only as
/// someone new.
export fn cq_member_remove(lib: *Library, key: [*:0]const u8) c_int {
    return status(lib, removeMember, .{std.mem.span(key)});
}

fn removeMember(lib: *Library, _: std.mem.Allocator, key: []const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    try (try lib.main()).removeMember(lib.now(), try store_.parseKey(std.mem.trim(u8, key, " \n")));
}
