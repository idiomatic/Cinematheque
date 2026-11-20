//! The C interface (see ../capi.zig): pairing.

const std = @import("std");
const capi = @import("../capi.zig");
const openFounded = @import("membership.zig").openFounded;
const library = @import("../library.zig");
const store_ = @import("../store.zig");
const discover = @import("../discover.zig");
const Host = @import("../host.zig").Host;
const pair = @import("../pair.zig");
const gpa = capi.gpa;
const Library = capi.Library;
const json = capi.json;
const status = capi.status;
const span = capi.span;
const MemberJson = capi.MemberJson;
const PairJson = capi.PairJson;
const PairedJson = capi.PairedJson;

// Pairing: a new device shows a code, and a member's, given it, sends it
// the library's founder's key, and to pair another of its person's devices,
// the person's secret too (see pair.zig).

pub const Pairing = struct {
    offer: pair.Offer,
    arena: std.heap.ArenaAllocator,
    host: Host,
};

/// On a new device, before it has a library: offers to be added to one, as
/// another of a member's devices or a new member's, as the member's device
/// decides, serving and advertising by DNS-SD (as `name`, for the other
/// device to show) until paired or `cq_pair_stop`. Returns its state, as
/// `cq_pair_check` does, with a new code. Offering again starts over, with
/// another code.
export fn cq_pair_offer(lib: *Library, name: [*:0]const u8) ?[*:0]u8 {
    return json(lib, pairOffer, .{std.mem.span(name)});
}

fn pairOffer(lib: *Library, arena: std.mem.Allocator, name: []const u8) !PairJson {
    if (lib.replica != null) return error.LibraryExists;
    stopPairing(lib);
    const p = try gpa.create(Pairing);
    errdefer gpa.destroy(p);
    p.offer = .{ .code = pair.newCode(lib.io()), .person = try lib.store.person(), .device = try lib.store.device() };
    p.arena = .init(gpa);
    errdefer p.arena.deinit();
    const a = p.arena.allocator();
    p.host = .{
        .io = lib.io(),
        .gpa = gpa,
        .options = .{ .host = "0.0.0.0", .port = 0, .handler = p.offer.handler() },
        .name = try std.fmt.allocPrintSentinel(a, "{s}", .{try lib.store.serviceName(arena)}, 0),
        .txt = try discover.txtRecord(a, &.{
            .{ "pair", "new" },
            .{ "path", pair.path },
            .{ "name", name[0..@min(name.len, 200)] },
        }),
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
        if (!secrets.joining()) try lib.store.pair(arena, &std.fmt.bytesToHex(secrets.person, .lower));
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

pub fn stopPairing(lib: *Library) void {
    const p = lib.pairing orelse return;
    p.host.stop();
    p.arena.deinit();
    gpa.destroy(p);
    lib.pairing = null;
}

/// Long: pairs the new device offering at `url` (a `pairing` device's, from
/// `cq_nearby`), given the code it shows, as another of this person's
/// devices, or with nonzero `join`, a new member's: sends it the library's
/// founder's key, and if this person's, this person's secret, which it takes only if the code is right. Returns
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
