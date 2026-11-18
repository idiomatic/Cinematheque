//! Sync over HTTP, both ways, started by either side. A device POSTs to
//! `/sync` a request signed by its device:
//!
//! device key (32) | certificate (96) | time, Unix milliseconds (8) |
//! version vector (see `replica.writeVector`) | signature (64)
//!
//! The certificate is the device's user's signature over the device key
//! (see `Replica.certificate`). The peer answers only members, with its
//! frames (see `replica.writeSync`), in a chunked, gzipped response, leaving
//! out other users' private streams, and with its own device key and
//! certificate in headers. The device then pushes what the peer lacks: a
//! second POST (`push_type`), of the request's length (u32) and a request,
//! then its frames above the peer's vector, gzipped, which the peer applies
//! as it would a response. So a device that can reach a peer, though the
//! peer can't reach it (behind a NAT), syncs both ways.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const flate = std.compress.flate;
const Ed25519 = std.crypto.sign.Ed25519;
const replica_ = @import("replica.zig");
const serve_ = @import("serve.zig");
const discover = @import("discover.zig");
const library_ = @import("library.zig");
const Replica = replica_.Replica;

/// Where peers answer syncs, as they advertise it.
pub const path = "/sync";

/// Where peers added by URL are kept, in the replica's `local` state: on
/// this device only.
const added_prefix = "peer:";

/// A peer's sync URL, from its base URL or the sync URL itself.
pub fn syncUrl(arena: std.mem.Allocator, target: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, target, " \n");
    if (std.mem.endsWith(u8, t, path)) return t;
    return std.mem.concat(arena, u8, &.{ std.mem.trimEnd(u8, t, "/"), path });
}

/// What a peer serving `r`'s library advertises by DNS-SD (its TXT
/// record): the library's ID, the sync path, its user's key, and the names
/// of this device (`device`) and its user (`user`), if they have them.
pub fn advertisement(arena: std.mem.Allocator, r: *Replica, user: [32]u8, device: [32]u8) ![]const u8 {
    const user_hex = std.fmt.bytesToHex(user, .lower);
    const named = try library_.names(r, arena);
    return discover.txtRecord(arena, &.{
        .{ "library", &std.fmt.bytesToHex(r.library, .lower) },
        .{ "path", path },
        .{ "user", &user_hex },
        .{ "name", library_.nameOf(named, &std.fmt.bytesToHex(device, .lower)) orelse "" },
        .{ "person", library_.nameOf(named, &user_hex) orelse "" },
    });
}

/// The sync URL of a peer found nearby.
pub fn foundUrl(arena: std.mem.Allocator, s: discover.Service) ![]const u8 {
    return std.fmt.allocPrint(arena, "http://{s}:{d}{s}", .{ s.host, s.port, s.get("path") orelse path });
}

/// The sync URLs of the peers added by URL.
pub fn addedPeers(r: *Replica, arena: std.mem.Allocator) ![]const []const u8 {
    const keys = try r.localKeys(arena, added_prefix);
    const urls = try arena.alloc([]const u8, keys.len);
    for (keys, urls) |k, *u| u.* = k[added_prefix.len..];
    return urls;
}

/// Adds a peer by URL, or removes one added; returns its sync URL.
pub fn setAdded(r: *Replica, arena: std.mem.Allocator, target: []const u8, add: bool) ![]const u8 {
    const u = try syncUrl(arena, target);
    const key = try std.mem.concat(arena, u8, &.{ added_prefix, u });
    if (add) try r.setLocal(key, "") else try r.removeLocal(key);
    return u;
}

/// The peers to sync with: their sync URLs, and the names of those found
/// nearby, as they advertise them.
pub const Peers = struct {
    urls: []const []const u8,
    names: std.StringHashMapUnmanaged([]const u8),
};

/// `target` alone, if given; else every peer of `r`'s library found nearby
/// (but this one, advertised as `own`), then those added that weren't.
pub fn peers(io: Io, arena: std.mem.Allocator, r: *Replica, own: []const u8, target: ?[]const u8) !Peers {
    var urls: std.ArrayList([]const u8) = .empty;
    var names: std.StringHashMapUnmanaged([]const u8) = .empty;
    if (target) |t| {
        try urls.append(arena, try syncUrl(arena, t));
        return .{ .urls = urls.items, .names = names };
    }
    const mine = std.fmt.bytesToHex(r.library, .lower);
    for (try discover.browse(io, arena, 2000)) |s| {
        if (s.host.len == 0 or std.mem.eql(u8, s.name, own)) continue;
        if (!std.mem.eql(u8, s.get("library") orelse "", &mine)) continue;
        const u = try foundUrl(arena, s);
        try urls.append(arena, u);
        if (s.get("name")) |n| if (n.len > 0) try names.put(arena, u, n);
    }
    const found = urls.items.len;
    for (try addedPeers(r, arena)) |u| {
        for (urls.items[0..found]) |f| {
            if (std.mem.eql(u8, f, u)) break;
        } else try urls.append(arena, u);
    }
    return .{ .urls = urls.items, .names = names };
}

test "sync URLs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("http://hal:8008/sync", try syncUrl(arena, "http://hal:8008"));
    try std.testing.expectEqualStrings("http://hal:8008/sync", try syncUrl(arena, "http://hal:8008/ "));
    try std.testing.expectEqualStrings("http://hal:8008/sync", try syncUrl(arena, "http://hal:8008/sync"));
}

/// A push's content type, which a peer too old to take pushes doesn't
/// know, and so refuses as a request whose signature doesn't verify.
pub const push_type = "application/x-cinematheque-push";
const device_header = "x-cinematheque-device";
const certificate_header = "x-cinematheque-certificate";

/// How far a request's time may be from the server's.
const freshness_ms = 10 * 60 * 1000;

/// What the server needs to open its own connection to a replica for each
/// sync, since SQLite connections aren't shared across threads.
pub const Source = struct {
    path: [:0]const u8,
    founder: [32]u8,
    identity: replica_.Identity,
    /// Told of each sync served: the device that asked, and how many
    /// operations it was sent (for apps to show).
    served: ?*const fn (context: ?*anyopaque, device: [32]u8, operations: usize) void = null,
    /// Told of each push taken: the device that pushed, and how many of its
    /// operations won (for apps to reload, and show).
    received: ?*const fn (context: ?*anyopaque, device: [32]u8, operations: usize) void = null,
    context: ?*anyopaque = null,

    pub fn handler(source: *Source) serve_.Handler {
        return .{ .context = source, .function = respond };
    }
};

pub const Request = struct {
    device: [32]u8,
    certificate: [96]u8,
    time_ms: u64,
    vector: replica_.VersionVector,
};

/// Writes `dst`'s request, signed by its device.
pub fn writeRequest(arena: std.mem.Allocator, dst: *Replica, time_ms: u64) ![]u8 {
    var out: Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll(&dst.device());
    try out.writer.writeAll(&try dst.certificate(false));
    try out.writer.writeInt(u64, time_ms, .little);
    try replica_.writeVector(&out.writer, try dst.versionVector(arena));
    const sig = try dst.key_pair.sign(out.written(), null);
    try out.writer.writeAll(&sig.toBytes());
    return out.written();
}

/// Reads and checks a request: its signature, its certificate, and its time.
/// Returns it and the user it's from.
pub fn readRequest(arena: std.mem.Allocator, library: [16]u8, body: []const u8, now_ms: u64) !struct { Request, [32]u8 } {
    if (body.len < 32 + 96 + 8 + 4 + 64) return error.Malformed;
    const signed = body[0 .. body.len - 64];
    var r: Io.Reader = .fixed(signed);
    var request: Request = undefined;
    try r.readSliceAll(&request.device);
    try r.readSliceAll(&request.certificate);
    request.time_ms = try r.takeInt(u64, .little);
    request.vector = try replica_.readVector(arena, &r);
    const key = Ed25519.PublicKey.fromBytes(request.device) catch return error.BadSignature;
    Ed25519.Signature.fromBytes(body[body.len - 64 ..][0..64].*).verify(signed, key) catch return error.BadSignature;
    const user = replica_.verifyCertificate(library, request.device, false, request.certificate) orelse return error.BadCertificate;
    if (@max(now_ms, request.time_ms) - @min(now_ms, request.time_ms) > freshness_ms) return error.Stale;
    return .{ request, user };
}

fn respond(context: ?*anyopaque, io: Io, gpa: std.mem.Allocator, request: *http.Server.Request) anyerror!bool {
    if (request.head.method != .POST or !std.mem.eql(u8, request.head.target, path)) return false;
    const source: *Source = @ptrCast(@alignCast(context.?));
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pushed = if (request.head.content_type) |t| std.mem.eql(u8, t, push_type) else false;

    var body_buf: [64 * 1024]u8 = undefined;
    const body = request.readerExpectNone(&body_buf);
    // A push's request comes first, its length before it; a pull's is the
    // whole body.
    const head = if (pushed) blk: {
        const n = try body.takeInt(u32, .little);
        if (n > 1 << 20) {
            try request.respond("Malformed", .{ .status = .bad_request });
            return true;
        }
        const bytes = try arena.alloc(u8, n);
        try body.readSliceAll(bytes);
        break :blk bytes;
    } else try body.allocRemaining(arena, .limited(1 << 20));
    var src = try Replica.open(gpa, source.path, source.founder, source.identity);
    defer src.close();
    const now: u64 = @intCast(Io.Timestamp.now(io, .real).toMilliseconds());
    const checked = readRequest(arena, src.library, head, now) catch |err| {
        try request.respond(@errorName(err), .{ .status = .bad_request });
        return true;
    };
    const reader = checked[1];
    if (!try src.isMemberUser(reader) or try src.revoked(checked[0].device) != null) {
        try request.respond("not a member\n", .{ .status = .forbidden });
        return true;
    }
    const window = try arena.alloc(u8, flate.max_window_len);

    if (pushed) {
        var gunzip: flate.Decompress = .init(body, .gzip, window);
        const stats = replica_.readSync(&src, &gunzip.reader, null) catch |err| {
            try request.respond(@errorName(err), .{ .status = .bad_request });
            return true;
        };
        try request.respond("", .{ .status = .no_content });
        if (source.received) |f| f(source.context, checked[0].device, stats.won);
        return true;
    }

    // Who's answering, for the device to push to: its key and certificate.
    const device_hex = std.fmt.bytesToHex(src.device(), .lower);
    const certificate_hex = std.fmt.bytesToHex(try src.certificate(false), .lower);
    var response_buf: [64 * 1024]u8 = undefined;
    var response = try request.respondStreaming(&response_buf, .{ .respond_options = .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/octet-stream" },
            .{ .name = "content-encoding", .value = "gzip" },
            .{ .name = device_header, .value = &device_hex },
            .{ .name = certificate_header, .value = &certificate_hex },
        },
    } });
    var gz = try flate.Compress.init(&response.writer, window, .gzip, .fastest);
    const sent = try replica_.writeSync(&src, arena, checked[0].vector, reader, &gz.writer);
    try gz.finish();
    try response.end();
    if (source.served) |f| f(source.context, checked[0].device, sent);
    return true;
}

/// What came of a sync with a peer: what was pulled, and how many
/// operations were pushed (none to a peer too old to take pushes).
pub const Exchanged = struct {
    stats: replica_.Stats,
    sent: usize = 0,
};

/// Syncs both ways with the peer at `url` (e.g.,
/// `http://perihelion.local:8008/sync`): pulls what `dst` lacks, then pushes
/// what the peer does, if it's a member's device that takes pushes.
pub fn exchange(arena: std.mem.Allocator, client: *http.Client, dst: *Replica, url: []const u8, now_ms: u64) !Exchanged {
    var theirs: std.ArrayList(replica_.Entry) = .empty;
    const pulled = try pull(arena, client, dst, url, now_ms, &theirs);
    var out: Exchanged = .{ .stats = pulled.stats };
    const user = pulled.user orelse return out;
    if (!try dst.isMemberUser(user)) return out;
    out.sent = push(arena, client, dst, url, now_ms, theirs.items, user) catch |err| switch (err) {
        // A peer too old to take pushes, which still pulls from this one.
        error.Refused => 0,
        else => |e| return e,
    };
    return out;
}

const Pulled = struct { stats: replica_.Stats, user: ?[32]u8 };

/// Pulls from the peer at `url`, collecting its vector into `theirs`, and
/// the user its certificate names, if it sent one that verifies.
fn pull(arena: std.mem.Allocator, client: *http.Client, dst: *Replica, url: []const u8, now_ms: u64, theirs: *std.ArrayList(replica_.Entry)) !Pulled {
    const body = try writeRequest(arena, dst, now_ms);
    var request = try client.request(.POST, try std.Uri.parse(url), .{
        .headers = .{ .accept_encoding = .{ .override = "gzip" } },
    });
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = body.len };
    var sending = try request.sendBodyUnflushed(&.{});
    try sending.writer.writeAll(body);
    try sending.end();
    try request.connection.?.flush();
    var response = try request.receiveHead(&.{});
    switch (response.head.status) {
        .ok => {},
        .forbidden => return error.NotAMember,
        .bad_request => return error.Refused,
        else => return error.BadStatus,
    }
    var device: ?[32]u8 = null;
    var certificate: ?[96]u8 = null;
    var headers = response.head.iterateHeaders();
    while (headers.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, device_header)) {
            var d: [32]u8 = undefined;
            if (std.fmt.hexToBytes(&d, h.value)) |_| {
                device = d;
            } else |_| {}
        } else if (std.ascii.eqlIgnoreCase(h.name, certificate_header)) {
            var c: [96]u8 = undefined;
            if (std.fmt.hexToBytes(&c, h.value)) |_| {
                certificate = c;
            } else |_| {}
        }
    }
    const user = if (device != null and certificate != null) replica_.verifyCertificate(dst.library, device.?, false, certificate.?) else null;
    var transfer: [64 * 1024]u8 = undefined;
    var decompress: http.Decompress = undefined;
    const window = try arena.alloc(u8, flate.max_window_len);
    var stats = try replica_.readSync(dst, response.readerDecompressing(&transfer, &decompress, window), .{ .arena = arena, .vector = theirs });
    stats.wire_bytes += body.len;
    return .{ .stats = stats, .user = user };
}

/// Pushes to the peer at `url` what `wanted` (its vector) shows it lacks,
/// leaving out private streams that aren't `reader`'s (its user's); returns
/// how many operations it sent. Nothing to send sends nothing.
fn push(arena: std.mem.Allocator, client: *http.Client, src: *Replica, url: []const u8, now_ms: u64, wanted: replica_.VersionVector, reader: [32]u8) !usize {
    const head = try writeRequest(arena, src, now_ms);
    var body: Io.Writer.Allocating = .init(arena);
    try body.writer.writeInt(u32, @intCast(head.len), .little);
    try body.writer.writeAll(head);
    const window = try arena.alloc(u8, flate.max_window_len);
    var gz = try flate.Compress.init(&body.writer, window, .gzip, .fastest);
    const sent = try replica_.writeSync(src, arena, wanted, reader, &gz.writer);
    try gz.finish();
    if (sent == 0) return 0;
    var request = try client.request(.POST, try std.Uri.parse(url), .{
        .headers = .{ .content_type = .{ .override = push_type } },
    });
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = body.written().len };
    var sending = try request.sendBodyUnflushed(&.{});
    try sending.writer.writeAll(body.written());
    try sending.end();
    try request.connection.?.flush();
    const response = try request.receiveHead(&.{});
    return switch (response.head.status) {
        .no_content => sent,
        .forbidden => error.NotAMember,
        .bad_request => error.Refused,
        else => error.BadStatus,
    };
}

test "requests are checked" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const founder = (try replica_.userKeyPair(@splat(1))).public_key.toBytes();
    var r = try Replica.open(std.testing.allocator, ":memory:", founder, .from(@splat(2)));
    defer r.close();
    const body = try writeRequest(arena, &r, 1_000_000);
    const checked = try readRequest(arena, r.library, body, 1_000_000 + 60_000);
    try std.testing.expectEqual(r.userKey(), checked[1]);
    try std.testing.expectError(error.Stale, readRequest(arena, r.library, body, 1_000_000 + freshness_ms + 1));
    try std.testing.expectError(error.BadCertificate, readRequest(arena, @splat(9), body, 1_000_000));
    body[40] ^= 1;
    try std.testing.expectError(error.BadSignature, readRequest(arena, r.library, body, 1_000_000));
}
