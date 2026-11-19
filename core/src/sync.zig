//! Sync over HTTP, both ways, started by either side. A device POSTs to
//! `/sync` a request signed by its device:
//!
//! device key (32) | certificate (96) | time, Unix milliseconds (8) |
//! version vector (see `replica.writeVector`) | signature (64)
//!
//! The certificate is the device's person's signature over the device key
//! (see `Replica.certificate`). The other device answers only members, with its
//! frames (see `replica.writeSync`), in a chunked, gzipped response, leaving
//! out other people's private streams, and with its own device key and
//! certificate in headers. The device then pushes what the other device lacks: a
//! second POST (`push_type`), of the request's length (u32) and a request,
//! then its frames above the other device's vector, gzipped, which the other device applies
//! as it would a response. So a device that can reach a device, though the
//! device can't reach it (behind a NAT), syncs both ways.

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

/// Where devices answer syncs, as they advertise it.
pub const path = "/sync";

/// Where devices added by URL are kept, in the replica's `local` state: on
/// this device only.
const added_prefix = "address:";
/// As they were kept, carried over (see `addedAddresses`).
const obsolete_added_prefix = "device:";

/// A device's sync URL, from its base URL or the sync URL itself.
pub fn syncUrl(arena: std.mem.Allocator, target: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, target, " \n");
    if (std.mem.endsWith(u8, t, path)) return t;
    return std.mem.concat(arena, u8, &.{ std.mem.trimEnd(u8, t, "/"), path });
}

/// What a device serving `r`'s library advertises by DNS-SD (its TXT
/// record): the library's ID, the sync path, its person's key, and the names
/// of this device (`device`) and its person (`person`), if they have them.
pub fn advertisement(arena: std.mem.Allocator, r: *Replica, person: [32]u8, device: [32]u8) ![]const u8 {
    const person_hex = std.fmt.bytesToHex(person, .lower);
    const named = try library_.names(r, arena);
    return discover.txtRecord(arena, &.{
        .{ "library", &std.fmt.bytesToHex(r.library, .lower) },
        .{ "path", path },
        .{ "user", &person_hex },
        .{ "name", library_.nameOf(named, &std.fmt.bytesToHex(device, .lower)) orelse "" },
        .{ "person", library_.nameOf(named, &person_hex) orelse "" },
    });
}

/// The sync URL of a device found nearby.
pub fn foundUrl(arena: std.mem.Allocator, s: discover.Service) ![]const u8 {
    return std.fmt.allocPrint(arena, "http://{s}:{d}{s}", .{ s.host, s.port, s.get("path") orelse path });
}

/// The sync URLs of the devices added by URL.
pub fn addedAddresses(r: *Replica, arena: std.mem.Allocator) ![]const []const u8 {
    for (try r.localKeys(arena, obsolete_added_prefix)) |k| {
        try r.setLocal(try std.mem.concat(arena, u8, &.{ added_prefix, k[obsolete_added_prefix.len..] }), "");
        try r.removeLocal(k);
    }
    const keys = try r.localKeys(arena, added_prefix);
    const urls = try arena.alloc([]const u8, keys.len);
    for (keys, urls) |k, *u| u.* = k[added_prefix.len..];
    return urls;
}

/// Adds a device by URL, or removes one added; returns its sync URL.
pub fn setAdded(r: *Replica, arena: std.mem.Allocator, target: []const u8, add: bool) ![]const u8 {
    const u = try syncUrl(arena, target);
    const key = try std.mem.concat(arena, u8, &.{ added_prefix, u });
    if (add) try r.setLocal(key, "") else try r.removeLocal(key);
    return u;
}

/// The devices to sync with: their sync URLs, and the names of those found
/// nearby, as they advertise them.
pub const Devices = struct {
    urls: []const []const u8,
    names: std.StringHashMapUnmanaged([]const u8),
};

/// `target` alone, if given; else every device of `r`'s library found nearby
/// (but this one, advertised as `own`), then those added that weren't.
pub fn reachable(io: Io, arena: std.mem.Allocator, r: *Replica, own: []const u8, target: ?[]const u8) !Devices {
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
    for (try addedAddresses(r, arena)) |u| {
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

/// A push's content type, which a device too old to take pushes doesn't
/// know, and so refuses as a request whose signature doesn't verify.
pub const push_type = "application/x-cinematheque-push";
/// A repair's: a request for fields a removal dropped, in the push's form,
/// then the fields (see `replica.writeFields`), gzipped.
pub const repair_type = "application/x-cinematheque-repair";
const device_header = "x-cinematheque-device";
const certificate_header = "x-cinematheque-certificate";
const signature_header = "x-cinematheque-signature";

/// What a device signs, refusing a removed device, so the device can trust
/// the news: the library, the device refused, and its request's time.
fn removedMessage(library: [16]u8, device: [32]u8, time_ms: u64) [20 + 16 + 32 + 8]u8 {
    var out: [20 + 16 + 32 + 8]u8 = undefined;
    out[0..20].* = "cinematheque removed".*;
    out[20..36].* = library;
    out[36..68].* = device;
    std.mem.writeInt(u64, out[68..76], time_ms, .little);
    return out;
}

/// How far a request's time may be from the server's.
const freshness_ms = 10 * 60 * 1000;

/// What the server needs to open its own connection to a replica for each
/// sync, since SQLite connections aren't shared across threads.
pub const Sharing = struct {
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

    pub fn handler(sharing: *Sharing) serve_.Handler {
        return .{ .context = sharing, .function = respond };
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
/// Returns it and the person it's from.
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
    const person = replica_.verifyCertificate(library, request.device, false, request.certificate) orelse return error.BadCertificate;
    if (@max(now_ms, request.time_ms) - @min(now_ms, request.time_ms) > freshness_ms) return error.Stale;
    return .{ request, person };
}

fn respond(context: ?*anyopaque, io: Io, gpa: std.mem.Allocator, request: *http.Server.Request) anyerror!bool {
    if (request.head.method != .POST or !std.mem.eql(u8, request.head.target, path)) return false;
    const sharing: *Sharing = @ptrCast(@alignCast(context.?));
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pushed = if (request.head.content_type) |t| std.mem.eql(u8, t, push_type) else false;
    const repairing = if (request.head.content_type) |t| std.mem.eql(u8, t, repair_type) else false;

    var body_buf: [64 * 1024]u8 = undefined;
    const body = request.readerExpectNone(&body_buf);
    // A push's or repair's request comes first, its length before it; a
    // pull's is the whole body.
    const head = if (pushed or repairing) blk: {
        const n = try body.takeInt(u32, .little);
        if (n > 1 << 20) {
            try request.respond("Malformed", .{ .status = .bad_request });
            return true;
        }
        const bytes = try arena.alloc(u8, n);
        try body.readSliceAll(bytes);
        break :blk bytes;
    } else try body.allocRemaining(arena, .limited(1 << 20));
    var src = try Replica.open(gpa, io, sharing.path, sharing.founder, sharing.identity);
    defer src.close();
    const now: u64 = @intCast(Io.Timestamp.now(io, .real).toMilliseconds());
    const checked = readRequest(arena, src.library, head, now) catch |err| {
        try request.respond(@errorName(err), .{ .status = .bad_request });
        return true;
    };
    const reader = checked[1];
    // A removed device is told so, signed, so it can leave and pair afresh.
    if (try src.revoked(checked[0].device) != null) {
        const device_hex = std.fmt.bytesToHex(src.device(), .lower);
        const certificate_hex = std.fmt.bytesToHex(try src.certificate(false), .lower);
        const sig = try src.key_pair.sign(&removedMessage(src.library, checked[0].device, checked[0].time_ms), null);
        const signature_hex = std.fmt.bytesToHex(sig.toBytes(), .lower);
        try request.respond("removed\n", .{ .status = .forbidden, .extra_headers = &.{
            .{ .name = device_header, .value = &device_hex },
            .{ .name = certificate_header, .value = &certificate_hex },
            .{ .name = signature_header, .value = &signature_hex },
        } });
        return true;
    }
    if (!try src.isMemberPerson(reader)) {
        try request.respond("not a member\n", .{ .status = .forbidden });
        return true;
    }
    const window = try arena.alloc(u8, flate.max_window_len);

    if (pushed) {
        var gunzip: flate.Decompress = .init(body, .gzip, window);
        const stats = replica_.readSync(&src, &gunzip.reader, null, .{ .request = head[head.len - 64 ..][0..64].*, .sender = checked[0].device }) catch |err| {
            try request.respond(@errorName(err), .{ .status = .bad_request });
            return true;
        };
        try request.respond("", .{ .status = .no_content });
        if (sharing.received) |f| f(sharing.context, checked[0].device, stats.won);
        return true;
    }

    if (repairing) {
        var gunzip: flate.Decompress = .init(body, .gzip, window);
        const fields = replica_.readFields(arena, &gunzip.reader) catch |err| {
            try request.respond(@errorName(err), .{ .status = .bad_request });
            return true;
        };
        var repair_buf: [64 * 1024]u8 = undefined;
        var response = try request.respondStreaming(&repair_buf, .{ .respond_options = .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/octet-stream" },
                .{ .name = "content-encoding", .value = "gzip" },
            },
        } });
        var gz = try flate.Compress.init(&response.writer, try arena.alloc(u8, flate.max_window_len), .gzip, .fastest);
        _ = try replica_.writeRepair(&src, arena, fields, reader, &gz.writer);
        try gz.finish();
        try response.end();
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
    const sent = try replica_.writeSync(&src, arena, checked[0].vector, reader, head[head.len - 64 ..][0..64].*, &gz.writer);
    try gz.finish();
    try response.end();
    if (sharing.served) |f| f(sharing.context, checked[0].device, sent);
    return true;
}

/// What came of a sync with a device: what was pulled, and how many
/// operations were pushed (none to a device too old to take pushes).
pub const Exchanged = struct {
    stats: replica_.Stats,
    sent: usize = 0,
    /// How many fields a removal had dropped it got back.
    repaired: usize = 0,
};

/// Syncs both ways with the other device at `url` (e.g.,
/// `http://perihelion.local:8008/sync`): pulls what `dst` lacks, then pushes
/// what the other device does, if it's a member's device that takes pushes.
pub fn exchange(arena: std.mem.Allocator, client: *http.Client, dst: *Replica, url: []const u8, now_ms: u64) !Exchanged {
    var theirs: std.ArrayList(replica_.Entry) = .empty;
    const pulled = try pull(arena, client, dst, url, now_ms, &theirs);
    var out: Exchanged = .{ .stats = pulled.stats };
    const person = pulled.person orelse return out;
    if (!try dst.isMemberPerson(person)) return out;
    // Fields a removal dropped, from a device that may hold what stands.
    out.repaired = repairFrom(arena, client, dst, url, now_ms) catch |err| switch (err) {
        error.Refused => 0,
        else => |e| return e,
    };
    out.sent = push(arena, client, dst, url, now_ms, theirs.items, person) catch |err| switch (err) {
        // A device too old to take pushes, which still pulls from this one.
        error.Refused => 0,
        else => |e| return e,
    };
    return out;
}

const Pulled = struct { stats: replica_.Stats, person: ?[32]u8 };

/// Who a device's response says answered: its device key, certificate, and
/// (refusing a removed device) signature, as headers give them.
const Named = struct {
    device: ?[32]u8 = null,
    certificate: ?[96]u8 = null,
    signature: ?[64]u8 = null,

    fn of(head: http.Client.Response.Head) Named {
        var n: Named = .{};
        var headers = head.iterateHeaders();
        while (headers.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, device_header)) n.device = hex(32, h.value) //
            else if (std.ascii.eqlIgnoreCase(h.name, certificate_header)) n.certificate = hex(96, h.value) //
            else if (std.ascii.eqlIgnoreCase(h.name, signature_header)) n.signature = hex(64, h.value);
        }
        return n;
    }

    fn hex(comptime n: usize, text: []const u8) ?[n]u8 {
        var out: [n]u8 = undefined;
        _ = std.fmt.hexToBytes(&out, text) catch return null;
        return out;
    }

    /// The person its certificate names, if it verifies.
    fn person(n: Named, library: [16]u8) ?[32]u8 {
        return replica_.verifyCertificate(library, n.device orelse return null, false, n.certificate orelse return null);
    }
};

/// Whether a refusal says, believably, that `dst`'s device was removed:
/// signed, over this request, by a device that a member certified and that
/// `dst` doesn't know to be removed itself. (A member could say so falsely,
/// but a member could remove it truly.)
fn removed(dst: *Replica, other: Named, time_ms: u64) !bool {
    const device = other.device orelse return false;
    const signature = other.signature orelse return false;
    const person = other.person(dst.library) orelse return false;
    if (std.mem.eql(u8, &device, &dst.device())) return false;
    if (!try dst.isMemberPerson(person) or try dst.revoked(device) != null) return false;
    const key = Ed25519.PublicKey.fromBytes(device) catch return false;
    Ed25519.Signature.fromBytes(signature).verify(&removedMessage(dst.library, dst.device(), time_ms), key) catch return false;
    return true;
}

/// Pulls from the other device at `url`, collecting its vector into `theirs`, and
/// the person its certificate names, if it sent one that verifies.
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
    const other = Named.of(response.head);
    switch (response.head.status) {
        .ok => {},
        .forbidden => return if (try removed(dst, other, now_ms)) error.Removed else error.NotAMember,
        .bad_request => return error.Refused,
        else => return error.BadStatus,
    }
    const person = other.person(dst.library);
    // The frames must be signed by the device that says it answered, for
    // this request: its certificate alone is public, so proves nothing.
    const binding: replica_.Binding = .{ .request = body[body.len - 64 ..][0..64].*, .sender = other.device orelse return error.Refused };
    var transfer: [64 * 1024]u8 = undefined;
    var decompress: http.Decompress = undefined;
    const window = try arena.alloc(u8, flate.max_window_len);
    var stats = try replica_.readSync(dst, response.readerDecompressing(&transfer, &decompress, window), .{ .arena = arena, .vector = theirs }, binding);
    stats.wire_bytes += body.len;
    return .{ .stats = stats, .person = person };
}

/// Pushes to the other device at `url` what `wanted` (its vector) shows it lacks,
/// leaving out private streams that aren't `reader`'s (its person's); returns
/// how many operations it sent. Nothing to send sends nothing.
fn push(arena: std.mem.Allocator, client: *http.Client, src: *Replica, url: []const u8, now_ms: u64, wanted: replica_.VersionVector, reader: [32]u8) !usize {
    const head = try writeRequest(arena, src, now_ms);
    var body: Io.Writer.Allocating = .init(arena);
    try body.writer.writeInt(u32, @intCast(head.len), .little);
    try body.writer.writeAll(head);
    const window = try arena.alloc(u8, flate.max_window_len);
    var gz = try flate.Compress.init(&body.writer, window, .gzip, .fastest);
    const sent = try replica_.writeSync(src, arena, wanted, reader, head[head.len - 64 ..][0..64].*, &gz.writer);
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

/// Asks the other device at `url` for the fields a removal dropped from `dst`
/// (see `Replica.cut`), and applies what it holds of them; returns how many
/// came back. Nothing dropped asks nothing.
fn repairFrom(arena: std.mem.Allocator, client: *http.Client, dst: *Replica, url: []const u8, now_ms: u64) !usize {
    const fields = try replica_.repairFields(dst, arena);
    if (fields.len == 0) return 0;
    const head = try writeRequest(arena, dst, now_ms);
    var body: Io.Writer.Allocating = .init(arena);
    try body.writer.writeInt(u32, @intCast(head.len), .little);
    try body.writer.writeAll(head);
    const window = try arena.alloc(u8, flate.max_window_len);
    var gz = try flate.Compress.init(&body.writer, window, .gzip, .fastest);
    try replica_.writeFields(&gz.writer, fields);
    try gz.finish();
    var request = try client.request(.POST, try std.Uri.parse(url), .{
        .headers = .{ .content_type = .{ .override = repair_type }, .accept_encoding = .{ .override = "gzip" } },
    });
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = body.written().len };
    var sending = try request.sendBodyUnflushed(&.{});
    try sending.writer.writeAll(body.written());
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
    const stats = try replica_.readRepair(dst, response.readerDecompressing(&transfer, &decompress, try arena.alloc(u8, flate.max_window_len)));
    return stats.won;
}

test "requests are checked" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const founder = (try replica_.personKeyPair(@splat(1))).public_key.toBytes();
    var r = try Replica.open(std.testing.allocator, std.testing.io, ":memory:", founder, .from(@splat(2)));
    defer r.close();
    const body = try writeRequest(arena, &r, 1_000_000);
    const checked = try readRequest(arena, r.library, body, 1_000_000 + 60_000);
    try std.testing.expectEqual(r.personKey(), checked[1]);
    try std.testing.expectError(error.Stale, readRequest(arena, r.library, body, 1_000_000 + freshness_ms + 1));
    try std.testing.expectError(error.BadCertificate, readRequest(arena, @splat(9), body, 1_000_000));
    body[40] ^= 1;
    try std.testing.expectError(error.BadSignature, readRequest(arena, r.library, body, 1_000_000));
}

test "a removed device is told so, believably, and can tell" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    // Two devices of one person, the founder.
    const person_seed: [32]u8 = @splat(7);
    const founder = (try Ed25519.KeyPair.generateDeterministic(person_seed)).public_key.toBytes();
    const a_identity: replica_.Identity = .{ .device = @splat(1), .person = person_seed };
    const a_path = try std.fmt.allocPrintSentinel(arena, "{s}/a.db", .{dir}, 0);
    var a = try Replica.open(gpa, io, a_path, founder, a_identity);
    defer a.close();
    var b = try Replica.open(gpa, io, try std.fmt.allocPrintSentinel(arena, "{s}/b.db", .{dir}, 0), founder, .{ .device = @splat(2), .person = person_seed });
    defer b.close();
    try a.write(1000, "t/00001", "name", "Alien");
    try b.write(1000, "t/00002", "name", "Brazil");

    var sharing: Sharing = .{ .path = a_path, .founder = founder, .identity = a_identity };
    var server: @import("host.zig").Host = .{ .io = io, .gpa = gpa, .options = .{ .port = 0, .handler = sharing.handler() } };
    try server.start();
    defer server.stop();
    const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/sync", .{server.port});
    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const now: u64 = @intCast(Io.Timestamp.now(io, .real).toMilliseconds());

    _ = try exchange(arena, &client, &b, url, now);
    try a.revokeDevice(now, b.device());
    try std.testing.expectError(error.Removed, exchange(arena, &client, &b, url, now + 1));
}

test "a device gets back the fields a removal dropped, over HTTP" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const person_seed: [32]u8 = @splat(7);
    const founder = (try Ed25519.KeyPair.generateDeterministic(person_seed)).public_key.toBytes();
    const a_identity: replica_.Identity = .{ .device = @splat(1), .person = person_seed };
    const a_path = try std.fmt.allocPrintSentinel(arena, "{s}/a.db", .{dir}, 0);
    var a = try Replica.open(gpa, io, a_path, founder, a_identity);
    defer a.close();
    var b = try Replica.open(gpa, io, try std.fmt.allocPrintSentinel(arena, "{s}/b.db", .{dir}, 0), founder, .{ .device = @splat(2), .person = person_seed });
    defer b.close();
    try a.write(1000, "t/00001", "name", "Alien");

    var sharing: Sharing = .{ .path = a_path, .founder = founder, .identity = a_identity };
    var server: @import("host.zig").Host = .{ .io = io, .gpa = gpa, .options = .{ .port = 0, .handler = sharing.handler() } };
    try server.start();
    defer server.stop();
    const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/sync", .{server.port});
    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const now: u64 = @intCast(Io.Timestamp.now(io, .real).toMilliseconds());

    _ = try exchange(arena, &client, &b, url, now);
    // As if a removal had dropped the field after b took it.
    try b.db.exec("DELETE FROM winners WHERE key = 't/00001'");
    try b.db.exec("INSERT INTO repair VALUES ('t/00001', 'name')");
    b.repairing = true;
    try std.testing.expectEqual(@as(i64, 1), try b.repairsPending());
    const out = try exchange(arena, &client, &b, url, now + 1);
    try std.testing.expectEqual(@as(usize, 1), out.repaired);
    try std.testing.expectEqual(@as(i64, 0), try b.repairsPending());
    const s = try b.db.prepare("SELECT value FROM winners WHERE key = 't/00001' AND field = 'name'");
    defer s.finalize();
    try std.testing.expect(try s.step());
    try std.testing.expectEqualStrings("Alien", s.blob(0));
}
