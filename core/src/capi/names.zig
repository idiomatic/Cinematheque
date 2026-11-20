//! The C interface (see ../capi.zig): names and devices.

const std = @import("std");
const capi = @import("../capi.zig");
const connection = @import("long.zig").connection;
const library = @import("../library.zig");
const store_ = @import("../store.zig");
const sync = @import("../sync.zig");
const discover = @import("../discover.zig");
const pair = @import("../pair.zig");
const Library = capi.Library;
const json = capi.json;
const status = capi.status;
const span = capi.span;
const DeviceJson = capi.DeviceJson;
const NearbyJson = capi.NearbyJson;

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

/// Removes this device from the library, as it leaves: if `successor` (a
/// person's key) is given, first handing the library over to them (this
/// device's person must be the founder, and stays a member); then cutting
/// off this device's own streams just past these writes, so other devices,
/// once synced with, take the removal and refuse anything after. Sync, then
/// `cq_leave`, to finish leaving.
export fn cq_remove_self(lib: *Library, successor: ?[*:0]const u8) c_int {
    return status(lib, removeSelf, .{span(successor)});
}

fn removeSelf(lib: *Library, _: std.mem.Allocator, successor: ?[]const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    try (try lib.main()).removeSelf(lib.now(), if (successor) |s| try store_.parseKey(s) else null);
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
        const found = sync.foundUrl(arena, s) catch continue;
        const person = s.get("user");
        const is_member = if (person) |u| for (list) |m| {
            if (std.mem.eql(u8, &std.fmt.bytesToHex(m, .lower), u)) break true;
        } else false else false;
        try out.append(arena, .{
            .url = found,
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
