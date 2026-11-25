//! The app on the network: serving, syncing, and the devices it finds or
//! is given.

const std = @import("std");
const Io = std.Io;
const core = @import("core");
const main = @import("main.zig");
const App = main.App;
const web = @import("web.zig");
const setup = @import("setup.zig");
const Command = main.Command;
const Replica = core.replica.Replica;

/// The port devices serve on by default.
const default_port = 8008;
/// Where `serve --media` serves its directory.
pub const media_prefix = "media";

/// Devices found nearby (listening for 2 seconds), and addresses added.
pub fn listNearby(p: *App) !void {
    for (try core.discover.browse(p.io, p.arena, 2000)) |s| {
        const found = core.sync.foundUrl(p.arena, s) catch continue;
        try p.out.print("{s}  nearby  {s}, library {s}\n", .{ found, s.name, s.get("library") orelse "?" });
    }
    var r = try p.open();
    defer r.close();
    for (try core.sync.addedAddresses(&r, p.arena)) |u| try p.out.print("{s}  added\n", .{u});
}

/// Adds the address of a device that can't be found nearby.
pub fn addAddress(p: *App, target: []const u8) !void {
    var r = try p.open();
    defer r.close();
    try p.out.print("added {s}\n", .{try core.sync.addAddress(&r, p.arena, target)});
}

/// Forgets an address added.
pub fn forgetAddress(p: *App, target: []const u8) !void {
    var r = try p.open();
    defer r.close();
    try p.out.print("forgot {s}\n", .{try core.sync.forgetAddress(&r, p.arena, target)});
}

/// `sync [URL]`: pulls from a device, or from every device found or added.
pub fn sync(p: *App, c: Command) !void {
    if (c.rest.len > 1) return error.Usage;
    try c.args.only(&.{});
    var r = try p.open();
    defer r.close();
    const found = if (c.rest.len == 1) try core.sync.oneDevice(p.arena, c.rest[0]) else try core.sync.everyDevice(p.io, p.arena, &r, try serviceName(p));
    try exchangeAll(p, &r, found);
}

/// Syncs with every device of this library found or added.
pub fn syncEvery(p: *App) !void {
    var r = try p.open();
    defer r.close();
    try exchangeAll(p, &r, try core.sync.everyDevice(p.io, p.arena, &r, try serviceName(p)));
}

/// `serve [--port PORT] [--media DIR] [--no-web]
/// [--permissive]`: serves on `PORT`, or on `default_port` if none, falling
/// back to any free port if that's taken, and advertises the port it got;
/// the web client too, unless `--no-web`, which sets up a library if this
/// device has none yet.
pub fn serve(p: *App, c: Command) !void {
    if (c.rest.len > 0) return error.Usage;
    try c.args.only(&.{ "--port", "--media", "--no-web", "--permissive" });
    const browsing = !c.args.has("--no-web");
    if (!browsing and c.args.has("--permissive")) return error.Usage;
    const port = try c.args.port();
    const media = c.args.get("--media");
    // With the web client, a library can be made or joined from it.
    const creator: ?[32]u8 = p.store.creator(p.arena) catch |err| switch (err) {
        error.NoLibrary => if (browsing) null else return err,
        else => |e| return e,
    };
    const name = try advertisedName(p);
    var sharing: core.sync.Sharing = .{
        .path = try p.store.replicaPath(p.arena),
        .creator = creator orelse undefined,
        .identity = p.store.identity,
    };
    var long = std.heap.ArenaAllocator.init(p.gpa);
    defer long.deinit();
    // The web client answers syncs itself, as this device is when asked,
    // before the media.
    var browsers: web.Web = .{
        .store = p.store,
        .creator = creator,
        .long = long.allocator(),
        .path = sharing.path,
        .permissive = c.args.has("--permissive"),
        .host_name = name,
    };
    defer browsers.deinit(p.gpa);
    const handler = if (browsing) browsers.handler() else sharing.handler();
    const txt = if (creator != null) blk: {
        var r = try p.open();
        defer r.close();
        // Its model, for its person's other devices to show it by, before
        // anything else writes.
        if (core.model.this(p.io, p.arena)) |model| try core.library.recordModel(&r, p.arena, p.now(), try p.store.device(), model);
        break :blk try core.sync.advertisement(p.arena, &r, try p.store.person(), try p.store.device());
    } else try core.discover.txtRecord(p.arena, &.{.{ "name", name }});
    // The media directory, if any, at `/media/`, leaving the root to the
    // web client.
    var mounts: std.ArrayList(core.serve.Mount) = .empty;
    if (media) |m| try mounts.append(p.arena, .{ .prefix = media_prefix, .path = m });
    var host: core.host.Host = .{
        .io = p.io,
        .gpa = p.gpa,
        .options = .{ .host = "::", .port = port orelse default_port, .fallback = port == null, .mounts = mounts.items, .handler = handler, .volumes = &browsers.volumes },
        .name = try serviceName(p),
        .txt = txt,
    };
    try host.start();
    browsers.host = &host;
    // Where it serves its own sources now: one field, should its port have
    // changed, rather than every copy (their addresses are port-free).
    if (creator != null) {
        var r = try p.open();
        defer r.close();
        try core.library.recordServed(&r, p.arena, p.now(), try p.store.device(), try std.fmt.allocPrint(p.arena, "http://{s}.local:{d}/", .{ name, host.port }));
    }
    // Settings may add it as a source: it, and no other folder; by its
    // port-free address.
    if (media) |m| {
        const path = "/" ++ media_prefix ++ "/";
        browsers.media = .{ .dir = m, .url = try core.url.deviceSource(p.arena, try p.store.device(), path) };
    }
    // Synced with at once, as the apps sync at launch: what changed while
    // it was off arrives, and a device removed meanwhile hears so and leaves.
    if (creator != null) browsers.changed.store(1, .release);
    var syncing: ?Io.Future(Io.Cancelable!void) = if (browsing) try p.io.concurrent(web.Web.keepInSync, .{ &browsers, p.io, p.gpa }) else null;
    defer if (syncing) |*f| f.cancel(p.io) catch {};
    var refreshing: ?Io.Future(Io.Cancelable!void) = if (browsing) try p.io.concurrent(setup.keepRefreshed, .{ &browsers, p.io, p.gpa }) else null;
    defer if (refreshing) |*f| f.cancel(p.io) catch {};
    var watching: ?Io.Future(Io.Cancelable!void) = if (media != null) try p.io.concurrent(web.Web.watchVolumes, .{ &browsers, p.io, p.gpa }) else null;
    defer if (watching) |*f| f.cancel(p.io) catch {};
    const with_media = if (media != null) " with media from " else "";
    if (creator) |f| {
        try p.out.print("serving library {s} on port {d}{s}{s}, as {s}\n", .{ &std.fmt.bytesToHex(core.replica.libraryId(f), .lower), host.port, with_media, media orelse "", host.name });
    } else try p.out.print("serving on port {d}{s}{s}, as {s}, with no library yet\n", .{ host.port, with_media, media orelse "", host.name });
    if (browsing) {
        // As other computers on the network reach it: `firefly.local`.
        try p.out.print("web client at http://{s}.local:{d}/\n", .{ name, host.port });
        if (creator == null) try p.out.print("to create a library, or join one, open http://localhost:{d}/ on this computer\n", .{host.port});
        if (!browsers.permissive) try p.out.print("only a browser on this computer acts as this device (--permissive lets every browser)\n", .{});
    }
    try p.out.flush();
    try host.wait();
}

pub fn offerPairing(p: *App) !void {
    if (p.store.creator(p.arena)) |_| return error.LibraryExists else |_| {}
    var offer = try p.store.offer(p.io);
    var host: core.host.Host = .{
        .io = p.io,
        .gpa = p.gpa,
        .options = .{ .host = "::", .port = 0, .handler = offer.handler() },
        .name = try serviceName(p),
        .txt = try core.pair.offerRecord(p.arena, try advertisedName(p), core.model.this(p.io, p.arena) orelse ""),
    };
    try host.start();
    defer host.stop();
    try p.out.print("on a member's device, add this one with the code {s}: as theirs (person pair), or as a new person's (member pair)\n", .{offer.code});
    // For a device that can't find this one nearby, as `pair CODE URL`.
    try p.out.print("listening for it on port {d}, at /pair\n", .{host.port});
    try p.out.flush();
    while (true) {
        try p.io.sleep(.fromSeconds(1), .awake);
        const received, const closed = offer.outcome(p.io);
        if (received) |secrets| {
            try p.store.join(p.arena, secrets);
            try p.out.print("paired: this device acts as person {s}, in the library {s} created\n", .{ std.fmt.bytesToHex(try p.person(), .lower), std.fmt.bytesToHex(secrets.creator, .lower) });
            return;
        }
        if (closed) return error.TooManyWrongCodes;
    }
}

/// The name a device offering to pair advertises: the computer's, as the
/// system gives it (not `$HOST`, which shells don't export and launchd
/// doesn't set), its first label alone, as mDNS answers to it with
/// `.local` (a DHCP server can make it `firefly.localdomain`, a name other
/// computers can't look up, and that changes as networks do); else its
/// service name.
fn advertisedName(p: *App) ![]const u8 {
    var buffer: [std.posix.HOST_NAME_MAX + 1]u8 = undefined;
    if (std.c.gethostname(&buffer, buffer.len) == 0) {
        const name = std.mem.sliceTo(&buffer, 0);
        const label = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
        if (label.len > 0) return p.arena.dupe(u8, label);
    }
    return serviceName(p);
}

fn serviceName(p: *App) ![:0]const u8 {
    return p.store.serviceName(p.arena);
}

/// Syncs both ways with each of `found`, printing how it went.
fn exchangeAll(p: *App, r: *Replica, found: core.sync.Devices) !void {
    if (found.urls.len == 0) try p.out.print("no devices of this library found or added\n", .{});
    for (try core.sync.exchangeEach(p.io, p.gpa, p.arena, r, found.urls, .{})) |s| {
        const exchanged = s.result catch |err| {
            try p.out.print("{s}: {t}\n", .{ s.url, err });
            if (err == error.Removed) try p.out.print("this device was removed from the library; `library leave`, then pair again\n", .{});
            continue;
        };
        const stats = exchanged.stats;
        try p.out.print("{s}: {d} operations ({d} new, {d} lost, {d} known, {d} rejected, {d} refused) in {d} batches, {d:.1} KB; {d} pushed; {d} ms\n", .{
            s.url,                                           stats.sent,     stats.won, stats.lost, stats.known, stats.rejected, stats.refused, stats.batches,
            @as(f64, @floatFromInt(stats.wire_bytes)) / 1e3, exchanged.sent, s.ms,
        });
    }
}
