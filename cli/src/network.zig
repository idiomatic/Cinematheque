//! The app on the network: serving, syncing, and the devices it finds or
//! is given.

const std = @import("std");
const Io = std.Io;
const core = @import("core");
const main = @import("main.zig");
const App = main.App;
const Command = main.Command;
const Replica = core.replica.Replica;

/// The port devices serve on by default.
const default_port = 8008;

/// Devices found nearby (listening for 2 seconds), and addresses added.
pub fn listNearby(p: *App) !void {
    for (try core.discover.browse(p.io, p.arena, 2000)) |s|
        try p.out.print("{s}  nearby  {s}, library {s}\n", .{ try core.sync.foundUrl(p.arena, s), s.name, s.get("library") orelse "?" });
    var r = try p.open();
    defer r.close();
    for (try core.sync.addedAddresses(&r, p.arena)) |u| try p.out.print("{s}  added\n", .{u});
}

/// Adds the address of a device that can't be found nearby, or forgets one.
pub fn setAddress(p: *App, target: []const u8, add: bool) !void {
    var r = try p.open();
    defer r.close();
    const u = try core.sync.setAdded(&r, p.arena, target, add);
    try p.out.print("{s} {s}\n", .{ if (add) "added" else "forgot", u });
}

/// `sync [URL]`: pulls from a device, or from every device found or added.
pub fn sync(p: *App, c: Command) !void {
    if (c.rest.len > 1) return error.Usage;
    try c.args.only(&.{});
    try syncAll(p, if (c.rest.len == 1) c.rest[0] else null);
}

/// `serve [--port PORT] [--media DIR]`: serves on `PORT`, or on
/// `default_port` if none, falling back to any free port if that's taken,
/// and advertises the port it got.
pub fn serve(p: *App, c: Command) !void {
    if (c.rest.len > 0) return error.Usage;
    try c.args.only(&.{ "--port", "--media" });
    const port = try c.args.port();
    const media = c.args.get("--media");
    var sharing: core.sync.Sharing = .{
        .path = try p.store.replicaPath(p.arena),
        .founder = try p.store.founder(p.arena),
        .identity = p.store.identity,
    };
    var r = try p.open();
    const library_hex = std.fmt.bytesToHex(r.library, .lower);
    const txt = try core.sync.advertisement(p.arena, &r, try p.store.person(), try p.store.device());
    r.close();
    // The media directory, if any, at the root.
    const one = [_]core.serve.Mount{.{ .path = media orelse "" }};
    var host: core.host.Host = .{
        .io = p.io,
        .gpa = p.gpa,
        .options = .{ .host = "0.0.0.0", .port = port orelse default_port, .fallback = port == null, .mounts = if (media != null) &one else &.{}, .handler = sharing.handler() },
        .name = try std.fmt.allocPrintSentinel(p.arena, "{s}", .{try serviceName(p)}, 0),
        .txt = txt,
    };
    try host.start();
    try p.out.print("serving library {s} on port {d}{s}{s}, as {s}\n", .{ &library_hex, host.port, if (media != null) " with media from " else "", media orelse "", host.name });
    try p.out.flush();
    try host.wait();
}

pub fn offerPairing(p: *App, kind: core.pair.Kind) !void {
    if (p.store.founder(p.arena)) |_| return error.LibraryExists else |_| {}
    var offer: core.pair.Offer = .{ .code = core.pair.newCode(p.io), .kind = kind, .person = try p.person(), .device = try p.store.device() };
    var host: core.host.Host = .{
        .io = p.io,
        .gpa = p.gpa,
        .options = .{ .host = "0.0.0.0", .port = 0, .handler = offer.handler() },
        .name = try std.fmt.allocPrintSentinel(p.arena, "{s}", .{try serviceName(p)}, 0),
        .txt = try core.discover.txtRecord(p.arena, &.{
            .{ "pair", @tagName(kind) },
            .{ "path", core.pair.path },
            .{ "name", p.environ.get("HOST") orelse "" },
        }),
    };
    try host.start();
    defer host.stop();
    try p.out.print("{s} {s}\n", .{ switch (kind) {
        .pair => "on another of your devices, pair this one with the code",
        .join => "on a member's device, let this one join with the code",
    }, offer.code });
    // For a device that can't find this one nearby, as `pair CODE URL`.
    try p.out.print("listening for it on port {d}, at /pair\n", .{host.port});
    try p.out.flush();
    while (true) {
        try p.io.sleep(.fromSeconds(1), .awake);
        const received, const closed = offer.outcome(p.io);
        if (received) |secrets| {
            if (kind == .pair) try p.store.pair(p.arena, &std.fmt.bytesToHex(secrets.person, .lower));
            try p.store.setFounder(p.arena, secrets.founder);
            try p.out.print("paired: this device acts as person {s}, in the library {s} founded\n", .{ std.fmt.bytesToHex(try p.person(), .lower), std.fmt.bytesToHex(secrets.founder, .lower) });
            return;
        }
        if (closed) return error.TooManyWrongCodes;
    }
}

fn serviceName(p: *App) ![]const u8 {
    return p.store.serviceName(p.arena);
}

/// Syncs both ways with the device at `target`, or else with every device of
/// this library found or added.
pub fn syncAll(p: *App, target: ?[]const u8) !void {
    var r = try p.open();
    defer r.close();
    var client: std.http.Client = .{ .allocator = p.gpa, .io = p.io };
    defer client.deinit();
    const found = try core.sync.reachable(p.io, p.arena, &r, try serviceName(p), target);
    if (found.urls.len == 0) try p.out.print("no devices of this library found or added\n", .{});
    for (found.urls) |u| {
        const start = Io.Timestamp.now(p.io, .awake);
        const exchanged = core.sync.exchange(p.arena, &client, &r, u, p.now()) catch |err| {
            try p.out.print("{s}: {t}\n", .{ u, err });
            if (err == error.Removed) try p.out.print("this device was removed from the library; `library leave`, then pair again\n", .{});
            continue;
        };
        const stats = exchanged.stats;
        try p.out.print("{s}: {d} operations ({d} new, {d} lost, {d} known, {d} rejected, {d} refused) in {d} batches, {d:.1} KB; {d} pushed; {d} ms\n", .{
            u,                                               stats.sent,     stats.won,                                                         stats.lost, stats.known, stats.rejected, stats.refused, stats.batches,
            @as(f64, @floatFromInt(stats.wire_bytes)) / 1e3, exchanged.sent, start.durationTo(Io.Timestamp.now(p.io, .awake)).toMilliseconds(),
        });
    }
}
