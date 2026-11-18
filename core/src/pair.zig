//! Pairing a new device with another of its user's by a short code: the new
//! device shows a 6-digit code, and the other, given it, sends the user's
//! secret and the library's founder's key, sealed with a key only a device
//! that knows the code can derive. CPace (draft-irtf-cfrg-cpace), over
//! ristretto255 and SHA-512, makes the code worth one guess per attempt (an
//! eavesdropper learns nothing to guess it by offline), and the new device
//! stops pairing after a few wrong ones.
//!
//! Over HTTP, at `/pair` on the new device: `GET` starts an attempt,
//! answering its session ID and the new device's share; `POST` answers it
//! with the session ID, the other device's share, and the sealed secrets.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const Sha512 = std.crypto.hash.sha2.Sha512;
const Ristretto255 = std.crypto.ecc.Ristretto255;
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const serve_ = @import("serve.zig");

pub const path = "/pair";
/// Wrong codes the new device takes before it stops pairing.
pub const max_failures = 3;

pub const Code = [6]u8;

/// What's sent: the user's seed (its secret) and the library's founder's
/// key.
pub const Secrets = struct { user: [32]u8, founder: [32]u8 };

const sid_length = 16;
const challenge_length = sid_length + 32;
const sealed_length = 64 + Aead.tag_length;
const answer_length = sid_length + 32 + sealed_length;

/// A random code of 6 digits.
pub fn newCode(io: Io) Code {
    var n: u64 = undefined;
    io.random(std.mem.asBytes(&n));
    var code: Code = undefined;
    _ = std.fmt.bufPrint(&code, "{d:0>6}", .{n % 1_000_000}) catch unreachable;
    return code;
}

fn isCode(code: []const u8) bool {
    if (code.len != 6) return false;
    for (code) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Hashes `data` prefixed by its length (all here are under 128 bytes).
fn lv(h: *Sha512, data: []const u8) void {
    std.debug.assert(data.len < 128);
    h.update(&.{@intCast(data.len)});
    h.update(data);
}

/// The session's generator, from the code: a point no one knows the
/// discrete log of, so a share made from it tests one code only.
fn generator(code: []const u8, sid: [sid_length]u8) Ristretto255 {
    var h = Sha512.init(.{});
    lv(&h, "CPaceRistretto255");
    lv(&h, code);
    lv(&h, "Cinematheque pairing");
    lv(&h, &sid);
    var uniform: [64]u8 = undefined;
    h.final(&uniform);
    return Ristretto255.fromUniform(uniform);
}

/// One side's share: a random scalar, and the generator times it.
const Share = struct {
    scalar: [32]u8,
    point: [32]u8,

    fn init(io: Io, code: []const u8, sid: [sid_length]u8) !Share {
        const scalar = Ristretto255.scalar.random(io);
        return .{ .scalar = scalar, .point = (try generator(code, sid).mul(scalar)).toBytes() };
    }
};

/// The key both sides derive, over the session and both shares, the
/// sender's (`initiator`) first.
fn sessionKey(own: Share, theirs: [32]u8, sid: [sid_length]u8, initiator: [32]u8, responder: [32]u8) ![32]u8 {
    const k = try (try Ristretto255.fromBytes(theirs)).mul(own.scalar);
    var h = Sha512.init(.{});
    lv(&h, "CPaceRistretto255_ISK");
    lv(&h, &sid);
    lv(&h, &k.toBytes());
    lv(&h, &initiator);
    lv(&h, &responder);
    var isk: [64]u8 = undefined;
    h.final(&isk);
    return isk[0..32].*;
}

const ad = "Cinematheque pairing secrets";

// Each key seals one message, so a zero nonce is safe.
fn seal(key: [32]u8, secrets: Secrets) [sealed_length]u8 {
    var out: [sealed_length]u8 = undefined;
    Aead.encrypt(out[0..64], out[64..], &(secrets.user ++ secrets.founder), ad, @splat(0), key);
    return out;
}

fn open(key: [32]u8, sealed: *const [sealed_length]u8) !Secrets {
    var plain: [64]u8 = undefined;
    Aead.decrypt(&plain, sealed[0..64], sealed[64..].*, ad, @splat(0), key) catch return error.WrongCode;
    return .{ .user = plain[0..32].*, .founder = plain[32..].* };
}

/// The new device's side, while it shows its code; its server's tasks
/// answer through it, and the main thread reads what it received.
pub const Offer = struct {
    code: Code,
    mutex: Io.Mutex = .init,
    /// The attempt under way: its session, and this device's share.
    attempt: ?struct { sid: [sid_length]u8, share: Share } = null,
    failures: u8 = 0,
    received: ?Secrets = null,

    /// What's come of it: the secrets, once received, and whether it has
    /// stopped, after too many wrong codes.
    pub fn outcome(o: *Offer, io: Io) struct { ?Secrets, bool } {
        o.mutex.lockUncancelable(io);
        defer o.mutex.unlock(io);
        return .{ o.received, o.failures >= max_failures };
    }

    /// Starts an attempt (ending any other): its session ID and this
    /// device's share.
    pub fn challenge(o: *Offer, io: Io) ![challenge_length]u8 {
        try o.mutex.lock(io);
        defer o.mutex.unlock(io);
        if (o.received != null or o.failures >= max_failures) return error.Closed;
        var sid: [sid_length]u8 = undefined;
        io.random(&sid);
        const share = try Share.init(io, &o.code, sid);
        o.attempt = .{ .sid = sid, .share = share };
        return sid ++ share.point;
    }

    /// Takes the other device's answer to the attempt under way: its share
    /// and the sealed secrets, which open only if it had the code.
    pub fn answer(o: *Offer, io: Io, body: []const u8) !void {
        if (body.len != answer_length) return error.Malformed;
        try o.mutex.lock(io);
        defer o.mutex.unlock(io);
        if (o.received != null or o.failures >= max_failures) return error.Closed;
        const attempt = o.attempt orelse return error.NoAttempt;
        if (!std.mem.eql(u8, &attempt.sid, body[0..sid_length])) return error.NoAttempt;
        o.attempt = null;
        const theirs = body[sid_length..][0..32].*;
        const key = sessionKey(attempt.share, theirs, attempt.sid, theirs, attempt.share.point) catch {
            o.failures += 1;
            return error.WrongCode;
        };
        o.received = open(key, body[sid_length + 32 ..][0..sealed_length]) catch {
            o.failures += 1;
            return error.WrongCode;
        };
    }

    pub fn handler(o: *Offer) serve_.Handler {
        return .{ .context = o, .function = respond };
    }
};

fn respond(context: ?*anyopaque, io: Io, gpa: std.mem.Allocator, request: *http.Server.Request) anyerror!bool {
    if (!std.mem.eql(u8, request.head.target, path)) return false;
    const o: *Offer = @ptrCast(@alignCast(context.?));
    switch (request.head.method) {
        .GET => {
            const challenge = o.challenge(io) catch |err| {
                try request.respond(@errorName(err), .{ .status = .gone });
                return true;
            };
            try request.respond(&challenge, .{});
        },
        .POST => {
            var body_buf: [1024]u8 = undefined;
            const body = try request.readerExpectNone(&body_buf).allocRemaining(gpa, .limited(1024));
            defer gpa.free(body);
            o.answer(io, body) catch |err| {
                try request.respond(@errorName(err), .{ .status = switch (err) {
                    error.WrongCode => .forbidden,
                    error.Closed => .gone,
                    else => .bad_request,
                } });
                return true;
            };
            try request.respond("paired\n", .{});
        },
        else => return false,
    }
    return true;
}

/// Sends `secrets` to the new device at `url` (its `/pair`), given the
/// code it shows.
pub fn send(io: Io, arena: std.mem.Allocator, client: *http.Client, url: []const u8, code: []const u8, secrets: Secrets) !void {
    if (!isCode(code)) return error.WrongCode;
    const uri = try std.Uri.parse(url);
    const challenge = blk: {
        var request = try client.request(.GET, uri, .{});
        defer request.deinit();
        try request.sendBodiless();
        var response = try request.receiveHead(&.{});
        if (response.head.status == .gone) return error.Closed;
        if (response.head.status != .ok) return error.BadStatus;
        var transfer: [256]u8 = undefined;
        break :blk try response.reader(&transfer).allocRemaining(arena, .limited(256));
    };
    if (challenge.len != challenge_length) return error.Malformed;
    const sid = challenge[0..sid_length].*;
    const theirs = challenge[sid_length..][0..32].*;
    const share = try Share.init(io, code, sid);
    const key = try sessionKey(share, theirs, sid, share.point, theirs);
    const body = sid ++ share.point ++ seal(key, secrets);

    var request = try client.request(.POST, uri, .{});
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = body.len };
    var sending = try request.sendBodyUnflushed(&.{});
    try sending.writer.writeAll(&body);
    try sending.end();
    try request.connection.?.flush();
    const response = try request.receiveHead(&.{});
    return switch (response.head.status) {
        .ok => {},
        .forbidden => error.WrongCode,
        .gone => error.Closed,
        else => error.BadStatus,
    };
}

/// The sending side without HTTP, for tests: answers a challenge.
fn answerFor(io: Io, challenge: [challenge_length]u8, code: []const u8, secrets: Secrets) ![answer_length]u8 {
    const sid = challenge[0..sid_length].*;
    const theirs = challenge[sid_length..][0..32].*;
    const share = try Share.init(io, code, sid);
    const key = try sessionKey(share, theirs, sid, share.point, theirs);
    return sid ++ share.point ++ seal(key, secrets);
}

test "the right code pairs; wrong ones count, and close it" {
    const io = std.testing.io;
    const secrets: Secrets = .{ .user = @splat(7), .founder = @splat(9) };
    var offer: Offer = .{ .code = "042917".* };

    for (0..max_failures - 1) |_| {
        const c = try offer.challenge(io);
        try std.testing.expectError(error.WrongCode, offer.answer(io, &try answerFor(io, c, "042918", secrets)));
    }
    // An answer to an attempt since replaced is refused, uncounted.
    const stale = try offer.challenge(io);
    _ = try offer.challenge(io);
    try std.testing.expectError(error.NoAttempt, offer.answer(io, &try answerFor(io, stale, "042917", secrets)));

    const c = try offer.challenge(io);
    try offer.answer(io, &try answerFor(io, c, "042917", secrets));
    const got, const closed = offer.outcome(io);
    try std.testing.expectEqualDeep(secrets, got.?);
    try std.testing.expect(!closed);
    try std.testing.expectError(error.Closed, offer.challenge(io));
}

test "too many wrong codes close it" {
    const io = std.testing.io;
    var offer: Offer = .{ .code = "111111".* };
    for (0..max_failures) |_| {
        const c = try offer.challenge(io);
        try std.testing.expectError(error.WrongCode, offer.answer(io, &try answerFor(io, c, "222222", .{ .user = @splat(1), .founder = @splat(2) })));
    }
    _, const closed = offer.outcome(io);
    try std.testing.expect(closed);
    try std.testing.expectError(error.Closed, offer.challenge(io));
}

test "codes are six digits" {
    const code = newCode(std.testing.io);
    try std.testing.expect(isCode(&code));
    try std.testing.expect(!isCode("12345"));
    try std.testing.expect(!isCode("12a456"));
}
