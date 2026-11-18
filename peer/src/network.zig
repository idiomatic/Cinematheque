//! The peer on the network: serving, syncing, and the peers it finds or
//! is given.

const std = @import("std");
const Io = std.Io;
const core = @import("core");
const main = @import("main.zig");
const Peer = main.Peer;
const Command = main.Command;
const Replica = core.replica.Replica;

/// The port peers serve on by default.
const default_port = 8008;

/// Where peers added by URL are kept, in the replica's `local` state: on
/// this device only.
const added_prefix = "peer:";

pub fn peer(p: *Peer, c: Command) !void {
    if (c.is("list", 0, &.{})) {
        for (try core.discover.browse(p.io, p.arena, 2000)) |s|
            try p.out.print("http://{s}:{d}{s}  found  {s}, library {s}\n", .{ s.host, s.port, s.get("path") orelse "", s.name, s.get("library") orelse "?" });
        var r = try p.open();
        defer r.close();
        for (try addedPeers(&r, p.arena)) |u| try p.out.print("{s}  added\n", .{u});
    } else if (c.is("add", 1, &.{}) or c.is("remove", 1, &.{})) {
        var r = try p.open();
        defer r.close();
        const u = try syncUrl(p.arena, c.rest[0]);
        const key = try std.mem.concat(p.arena, u8, &.{ added_prefix, u });
        if (std.mem.eql(u8, c.verb, "add")) try r.setLocal(key, "") else try r.removeLocal(key);
        try p.out.print("{s} {s}\n", .{ if (std.mem.eql(u8, c.verb, "add")) "added" else "removed", u });
    } else return error.Usage;
}

/// `sync [URL]`: pulls from a peer, or from every peer found or added.
pub fn sync(p: *Peer, c: Command) !void {
    if (c.rest.len > 1) return error.Usage;
    try c.args.only(&.{});
    try pullAll(p, if (c.rest.len == 1) c.rest[0] else null);
}

/// `serve [--port PORT] [--media DIR]`: serves on `PORT`, or on
/// `default_port` if none, falling back to any free port if that's taken,
/// and advertises the port it got.
pub fn serve(p: *Peer, c: Command) !void {
    if (c.rest.len > 0) return error.Usage;
    try c.args.only(&.{ "--port", "--media" });
    const port = try c.args.port();
    const media = c.args.get("--media");
    var source: core.sync.Source = .{
        .path = try p.store.replicaPath(p.arena),
        .founder = try p.store.founder(p.arena),
        .identity = p.store.identity,
    };
    var r = try p.open();
    const library_hex = std.fmt.bytesToHex(r.library, .lower);
    const user_hex = std.fmt.bytesToHex(try p.store.user(), .lower);
    const named = try core.library.names(&r, p.arena);
    r.close();
    const Listening = struct {
        peer: *Peer,
        name: [:0]const u8,
        txt: []const u8,
        library: []const u8,
        media: ?[]const u8,
        advertisement: ?core.discover.Advertisement = null,

        fn onListen(context: ?*anyopaque, got: u16) void {
            const l: *@This() = @ptrCast(@alignCast(context.?));
            l.advertisement = core.discover.advertise(l.name, got, l.txt) catch |err| blk: {
                std.log.warn("not advertised: {t}", .{err});
                break :blk null;
            };
            l.peer.out.print("serving library {s} on port {d}{s}{s}, as {s}\n", .{ l.library, got, if (l.media != null) " with media from " else "", l.media orelse "", l.name }) catch {};
            l.peer.out.flush() catch {};
        }
    };
    var listening: Listening = .{
        .peer = p,
        .name = try std.fmt.allocPrintSentinel(p.arena, "{s}", .{try serviceName(p)}, 0),
        .txt = try core.discover.txtRecord(p.arena, &.{
            .{ "library", &library_hex },
            .{ "path", "/sync" },
            .{ "user", &user_hex },
            .{ "name", core.library.nameOf(named, &std.fmt.bytesToHex(try p.store.device(), .lower)) orelse "" },
            .{ "person", core.library.nameOf(named, &user_hex) orelse "" },
        }),
        .library = &library_hex,
        .media = media,
    };
    defer if (listening.advertisement) |a| a.deinit();
    // The media directory, if any, at the root.
    const one = [_]core.serve.Mount{.{ .path = media orelse "" }};
    const mounts: []const core.serve.Mount = if (media != null) &one else &.{};
    try core.serve.serve(p.io, p.gpa, .{
        .host = "0.0.0.0",
        .port = port orelse default_port,
        .fallback = port == null,
        .mounts = mounts,
        .handler = source.handler(),
        .on_listen = Listening.onListen,
        .on_listen_context = &listening,
    });
}

fn serviceName(p: *Peer) ![]const u8 {
    return p.store.serviceName(p.arena);
}

/// Pulls from the peer at `target`, or else from every peer of this
/// library found or added.
pub fn pullAll(p: *Peer, target: ?[]const u8) !void {
    var r = try p.open();
    defer r.close();
    var client: std.http.Client = .{ .allocator = p.gpa, .io = p.io };
    defer client.deinit();
    var urls: std.ArrayList([]const u8) = .empty;
    if (target) |t| {
        try urls.append(p.arena, try syncUrl(p.arena, t));
    } else {
        const mine = std.fmt.bytesToHex(r.library, .lower);
        const own = try serviceName(p);
        for (try core.discover.browse(p.io, p.arena, 2000)) |s| {
            if (s.host.len == 0 or std.mem.eql(u8, s.name, own)) continue;
            if (!std.mem.eql(u8, s.get("library") orelse "", &mine)) continue;
            try urls.append(p.arena, try std.fmt.allocPrint(p.arena, "http://{s}:{d}{s}", .{ s.host, s.port, s.get("path") orelse "/sync" }));
        }
        for (try addedPeers(&r, p.arena)) |u| {
            for (urls.items) |found| {
                if (std.mem.eql(u8, found, u)) break;
            } else try urls.append(p.arena, u);
        }
        if (urls.items.len == 0) try p.out.print("no peers of this library found or added\n", .{});
    }
    for (urls.items) |u| {
        const start = Io.Timestamp.now(p.io, .awake);
        const stats = core.sync.pull(p.arena, &client, &r, u, p.now()) catch |err| {
            try p.out.print("{s}: {t}\n", .{ u, err });
            continue;
        };
        try p.out.print("{s}: {d} operations ({d} new, {d} lost, {d} known, {d} rejected, {d} refused) in {d} batches, {d:.1} KB, {d} ms\n", .{
            u, stats.sent, stats.won, stats.lost, stats.known, stats.rejected, stats.refused, stats.batches,
            @as(f64, @floatFromInt(stats.wire_bytes)) / 1e3, start.durationTo(Io.Timestamp.now(p.io, .awake)).toMilliseconds(),
        });
    }
}

/// A peer's sync URL, from its base URL or the sync URL itself.
fn syncUrl(arena: std.mem.Allocator, target: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, target, "/sync")) return target;
    return std.mem.concat(arena, u8, &.{ std.mem.trimEnd(u8, target, "/"), "/sync" });
}

fn addedPeers(r: *Replica, arena: std.mem.Allocator) ![]const []const u8 {
    const keys = try r.localKeys(arena, added_prefix);
    const urls = try arena.alloc([]const u8, keys.len);
    for (keys, urls) |k, *u| u.* = k[added_prefix.len..];
    return urls;
}
