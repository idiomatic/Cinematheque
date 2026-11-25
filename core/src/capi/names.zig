//! The C interface (see ../capi.zig): names and devices.

const std = @import("std");
const capi = @import("../capi.zig");
const connection = @import("long.zig").connection;
const release = @import("long.zig").release;
const library = @import("../library.zig");
const store_ = @import("../store.zig");
const sync = @import("../sync.zig");
const discover = @import("../discover.zig");
const model = @import("../model.zig");
const Library = capi.Library;
const json = capi.json;
const status = capi.status;
const DeviceJson = capi.DeviceJson;
const NearbyJson = capi.NearbyJson;

/// Names this person, for every device to show in place of their key.
export fn cq_set_person_name(lib: *Library, name: [*:0]const u8) c_int {
    return status(lib, setPersonName, .{std.mem.span(name)});
}

fn setPersonName(lib: *Library, arena: std.mem.Allocator, name: []const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    try library.setName(try lib.main(), arena, lib.now(), try lib.store.person(), name, null);
}

/// Names this device, as its person's, for every device to show in place of
/// its key.
export fn cq_set_device_name(lib: *Library, name: [*:0]const u8) c_int {
    return status(lib, setDeviceName, .{std.mem.span(name)});
}

fn setDeviceName(lib: *Library, arena: std.mem.Allocator, name: []const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    try library.setName(try lib.main(), arena, lib.now(), try lib.store.device(), name, try lib.store.person());
}

/// Records this device's model (an Apple identifier, as `iPhone14,4`, shown
/// by its name; or a name), beside its name, for its person's other devices
/// to show it by, unless it's recorded already.
export fn cq_set_device_model(lib: *Library, model_: [*:0]const u8) c_int {
    return status(lib, setDeviceModel, .{std.mem.span(model_)});
}

fn setDeviceModel(lib: *Library, arena: std.mem.Allocator, given: []const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    try library.recordModel(try lib.main(), arena, lib.now(), try lib.store.device(), model.shown(given));
}

/// What this device names itself as, told `name` by its platform, at `host`
/// (its own, as `localhost` or `lint.local`), as JSON: `name`, unless it's
/// generic, as iOS and tvOS tell apps only "iPhone" or "Apple TV"; then its
/// host's, by the rule other devices show it by (`Service.shownName`); else
/// null, so it keeps the name pairing gave it.
export fn cq_shown_name(lib: *Library, name: [*:0]const u8, host: [*:0]const u8) ?[*:0]u8 {
    return json(lib, shownName, .{ std.mem.span(name), std.mem.span(host) });
}

fn shownName(_: *Library, arena: std.mem.Allocator, name: []const u8, host: []const u8) !?[]const u8 {
    const s: discover.Service = .{ .name = "", .host = host, .port = 0, .txt = try discover.txtRecord(arena, &.{.{ "name", name }}) };
    return s.shownName(arena);
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
        try out.append(arena, .{ .key = n.key, .name = n.name, .you = std.mem.eql(u8, n.key, &this), .model = n.model, .kind = if (n.model) |m| model.kind(m) else null, .seen = try sync.lastSeen(r, arena, key) });
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

fn removeDevice(lib: *Library, arena: std.mem.Allocator, device: []const u8) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    const key = try store_.parseKey(device);
    const r = try lib.main();
    try r.revokeDevice(lib.now(), key);
    // Its downloads too, as no one would serve them again.
    try library.removeDownloadsOf(r, arena, lib.now(), key);
}

/// Removes this device from the library, as it leaves: cutting off this
/// device's own streams just past these writes, so other devices,
/// once synced with, take the removal and refuse anything after. Sync, then
/// `cq_leave`, to finish leaving.
export fn cq_remove_self(lib: *Library) c_int {
    return status(lib, removeSelf, .{});
}

fn removeSelf(lib: *Library, _: std.mem.Allocator) !void {
    if (!lib.writer.tryLock()) return error.Busy;
    defer lib.writer.unlock(lib.io());
    try (try lib.main()).removeSelf(lib.now());
}

/// Long (it listens for 2 seconds): the devices found on the network, by
/// DNS-SD, other than this one, and those added by address, as a JSON
/// array of objects with `url` (to sync with, or for one `pairing`, to pair
/// with), `device` and `person` (their names, if advertised), `model` (what
/// kind of device, as one offering to be added says), `host` (as
/// DNS-SD resolved it), `person_key`,
/// `ours` (of this library), `member` (its person is one), `added`, and
/// `pairing` (`new`, for a new device offering to be added, by `cq_pair`;
/// else null).
export fn cq_nearby(lib: *Library) ?[*:0]u8 {
    return json(lib, nearby, .{});
}

fn nearby(lib: *Library, arena: std.mem.Allocator) ![]const NearbyJson {
    var r = try connection(lib, arena);
    defer release(lib, &r);
    const mine = std.fmt.bytesToHex(r.library, .lower);
    const own = try lib.store.serviceName(arena);
    const list = try r.members(arena);
    var out: std.ArrayList(NearbyJson) = .empty;
    for (try discover.browse(lib.io(), arena, 2000)) |s| {
        if (s.host.len == 0 or sync.isOwn(s.name, own)) continue;
        const found = sync.foundUrl(arena, s) catch continue;
        const person = s.get("user");
        const is_member = if (person) |u| for (list) |m| {
            if (std.mem.eql(u8, &std.fmt.bytesToHex(m, .lower), u)) break true;
        } else false else false;
        // As it advertised itself, or by its host if that's generic.
        const name = try s.shownName(arena);
        try out.append(arena, .{
            .url = found,
            .device = name,
            // What kind, as a new device offering to be added says.
            .model = s.shownModel(name),
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


