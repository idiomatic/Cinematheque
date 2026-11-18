//! Sync over HTTP. The receiver POSTs to `/sync` a request signed by its
//! device:
//!
//! device key (32) | certificate (96) | time, Unix milliseconds (8) |
//! version vector (see `replica.writeVector`) | signature (64)
//!
//! The certificate is the device's user's signature over the device key
//! (see `Replica.certificate`). The sender answers only members, with its
//! frames (see `replica.writeSync`), in a chunked, gzipped response, leaving
//! out other users' private streams.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const flate = std.compress.flate;
const Ed25519 = std.crypto.sign.Ed25519;
const replica_ = @import("replica.zig");
const serve_ = @import("serve.zig");
const Replica = replica_.Replica;

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
    served_context: ?*anyopaque = null,
    /// Told of each nudge: a peer that changed something, asking to be
    /// pulled from (`POST /nudge`, which carries nothing, so it's only ever
    /// a hint to sync with the peers this one already knows).
    nudged: ?*const fn (context: ?*anyopaque) void = null,

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
    if (request.head.method != .POST) return false;
    const source: *Source = @ptrCast(@alignCast(context.?));
    if (std.mem.eql(u8, request.head.target, "/nudge")) {
        if (source.nudged) |f| f(source.served_context);
        try request.respond("", .{ .status = .no_content });
        return true;
    }
    if (!std.mem.eql(u8, request.head.target, "/sync")) return false;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var body_buf: [4096]u8 = undefined;
    const body = try request.readerExpectNone(&body_buf).allocRemaining(arena, .limited(1 << 20));
    var src = try Replica.open(gpa, source.path, source.founder, source.identity);
    defer src.close();
    const now: u64 = @intCast(Io.Timestamp.now(io, .real).toMilliseconds());
    const checked = readRequest(arena, src.library, body, now) catch |err| {
        try request.respond(@errorName(err), .{ .status = .bad_request });
        return true;
    };
    const reader = checked[1];
    if (!try src.isMemberUser(reader) or try src.revoked(checked[0].device) != null) {
        try request.respond("not a member\n", .{ .status = .forbidden });
        return true;
    }

    var response_buf: [64 * 1024]u8 = undefined;
    var response = try request.respondStreaming(&response_buf, .{ .respond_options = .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/octet-stream" },
            .{ .name = "content-encoding", .value = "gzip" },
        },
    } });
    const window = try arena.alloc(u8, flate.max_window_len);
    var gz = try flate.Compress.init(&response.writer, window, .gzip, .fastest);
    const sent = try replica_.writeSync(&src, arena, checked[0].vector, reader, &gz.writer);
    try gz.finish();
    try response.end();
    if (source.served) |f| f(source.served_context, checked[0].device, sent);
    return true;
}

/// Pulls from the peer at `url` (e.g., `http://perihelion.local:8008/sync`).
/// Asks the peer whose sync URL this is to pull from this one soon.
pub fn nudge(client: *http.Client, sync_url: []const u8) !void {
    var buf: [512]u8 = undefined;
    const base = if (std.mem.endsWith(u8, sync_url, "/sync")) sync_url[0 .. sync_url.len - "/sync".len] else std.mem.trimEnd(u8, sync_url, "/");
    const url = try std.fmt.bufPrint(&buf, "{s}/nudge", .{base});
    var request = try client.request(.POST, try std.Uri.parse(url), .{ .keep_alive = false });
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = 0 };
    var sending = try request.sendBodyUnflushed(&.{});
    try sending.end();
    try request.connection.?.flush();
    const response = try request.receiveHead(&.{});
    if (response.head.status != .no_content) return error.Refused;
}

pub fn pull(arena: std.mem.Allocator, client: *http.Client, dst: *Replica, url: []const u8, now_ms: u64) !replica_.Stats {
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
    var transfer: [64 * 1024]u8 = undefined;
    var decompress: http.Decompress = undefined;
    const window = try arena.alloc(u8, flate.max_window_len);
    var stats = try replica_.readSync(dst, response.readerDecompressing(&transfer, &decompress, window));
    stats.wire_bytes += body.len;
    return stats;
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
