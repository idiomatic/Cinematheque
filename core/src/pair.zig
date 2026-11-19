//! Pairing a new device with a library's member's by a short code: the new
//! device shows a 6-digit code, and the other, given it, sends the library's
//! founder's key, and to pair one of its user's own devices, the user's
//! secret too, sealed with a key only a device that knows the code can
//! derive; the new device answers with its user's key and its own, sealed
//! the same way, so a new member's can be added, and the device named, at
//! once. CPace (draft-irtf-cfrg-cpace), over
//! ristretto255 and SHA-512, makes the code worth one guess per attempt (an
//! eavesdropper learns nothing to guess it by offline), and the new device
//! stops pairing after a few wrong ones.
//!
//! Over HTTP, at `/pair` on the new device: `GET` starts an attempt,
//! answering its session ID and the new device's share; `POST` answers it
//! with the session ID, the other device's share, and the sealed secrets,
//! and is answered with the new device's sealed user and device keys. What the offer is
//! for (`Kind`) goes into the key, so it can't be changed on the way.

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

/// What an offer is for: pairingAsYours another of the user's devices (it gets
/// the user's secret), or a new member's joining (it doesn't).
pub const Kind = enum { pair, join };

/// What's sent: the user's seed (its secret; zeros when joining) and the
/// library's founder's key.
pub const Secrets = struct { user: [32]u8, founder: [32]u8 };

const sid_length = 16;
const challenge_length = sid_length + 32;
const sealed_length = 64 + Aead.tag_length;
const answer_length = sid_length + 32 + sealed_length;
const reply_length = 64 + Aead.tag_length;

/// Who the new device is, as its reply says.
pub const Joined = struct { user: [32]u8, device: [32]u8 };

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
fn generator(code: []const u8, kind: Kind, sid: [sid_length]u8) Ristretto255 {
    var h = Sha512.init(.{});
    lv(&h, "CPaceRistretto255");
    lv(&h, code);
    lv(&h, "Cinematheque pairing");
    lv(&h, @tagName(kind));
    lv(&h, &sid);
    var uniform: [64]u8 = undefined;
    h.final(&uniform);
    return Ristretto255.fromUniform(uniform);
}

/// One side's share: a random scalar, and the generator times it.
const Share = struct {
    scalar: [32]u8,
    point: [32]u8,

    fn init(io: Io, code: []const u8, kind: Kind, sid: [sid_length]u8) !Share {
        const scalar = Ristretto255.scalar.random(io);
        return .{ .scalar = scalar, .point = (try generator(code, kind, sid).mul(scalar)).toBytes() };
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

// Each key seals one message each way: the secrets with nonce 0, and the
// reply with nonce 1.
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

const reply_ad = "Cinematheque pairing reply";

fn sealReply(key: [32]u8, joined: Joined) [reply_length]u8 {
    var out: [reply_length]u8 = undefined;
    Aead.encrypt(out[0..64], out[64..], &(joined.user ++ joined.device), reply_ad, nonceOne(), key);
    return out;
}

fn openReply(key: [32]u8, sealed: []const u8) !Joined {
    if (sealed.len != reply_length) return error.Malformed;
    var plain: [64]u8 = undefined;
    Aead.decrypt(&plain, sealed[0..64], sealed[64..][0..Aead.tag_length].*, reply_ad, nonceOne(), key) catch return error.BadReply;
    return .{ .user = plain[0..32].*, .device = plain[32..].* };
}

fn nonceOne() [Aead.nonce_length]u8 {
    var n: [Aead.nonce_length]u8 = @splat(0);
    n[0] = 1;
    return n;
}

/// The new device's side, while it shows its code; its server's tasks
/// answer through it, and the main thread reads what it received.
pub const Offer = struct {
    code: Code,
    kind: Kind,
    /// This device's user's key, and its own, to answer with.
    user: [32]u8,
    device: [32]u8,
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
        const share = try Share.init(io, &o.code, o.kind, sid);
        o.attempt = .{ .sid = sid, .share = share };
        return sid ++ share.point;
    }

    /// Takes the other device's answer to the attempt under way: its share
    /// and the sealed secrets, which open only if it had the code. Returns
    /// the reply: this device's user's key and its own, sealed.
    pub fn answer(o: *Offer, io: Io, body: []const u8) ![reply_length]u8 {
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
        return sealReply(key, .{ .user = o.user, .device = o.device });
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
            const reply = o.answer(io, body) catch |err| {
                try request.respond(@errorName(err), .{ .status = switch (err) {
                    error.WrongCode => .forbidden,
                    error.Closed => .gone,
                    else => .bad_request,
                } });
                return true;
            };
            try request.respond(&reply, .{});
        },
        else => return false,
    }
    return true;
}

/// Sends `secrets` to the new device at `url` (its `/pair`), offering for
/// `kind`, given the code it shows (when joining, the user's secret isn't
/// sent). Returns the new device's keys, its user's and its own.
pub fn send(io: Io, arena: std.mem.Allocator, client: *http.Client, url: []const u8, kind: Kind, code: []const u8, secrets: Secrets) !Joined {
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
    const share = try Share.init(io, code, kind, sid);
    const key = try sessionKey(share, theirs, sid, share.point, theirs);
    const sent: Secrets = .{ .user = if (kind == .pair) secrets.user else @splat(0), .founder = secrets.founder };
    const body = sid ++ share.point ++ seal(key, sent);

    var request = try client.request(.POST, uri, .{});
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = body.len };
    var sending = try request.sendBodyUnflushed(&.{});
    try sending.writer.writeAll(&body);
    try sending.end();
    try request.connection.?.flush();
    var response = try request.receiveHead(&.{});
    switch (response.head.status) {
        .ok => {},
        .forbidden => return error.WrongCode,
        .gone => return error.Closed,
        else => return error.BadStatus,
    }
    var transfer: [256]u8 = undefined;
    return openReply(key, try response.reader(&transfer).allocRemaining(arena, .limited(256)));
}

/// The sending side without HTTP, for tests: answers a challenge, and
/// the key to read the reply with.
fn answerFor(io: Io, challenge: [challenge_length]u8, kind: Kind, code: []const u8, secrets: Secrets) !struct { [answer_length]u8, [32]u8 } {
    const sid = challenge[0..sid_length].*;
    const theirs = challenge[sid_length..][0..32].*;
    const share = try Share.init(io, code, kind, sid);
    const key = try sessionKey(share, theirs, sid, share.point, theirs);
    return .{ sid ++ share.point ++ seal(key, secrets), key };
}

test "the right code pairs, and the reply carries the new user; wrong ones count" {
    const io = std.testing.io;
    const secrets: Secrets = .{ .user = @splat(7), .founder = @splat(9) };
    var offer: Offer = .{ .code = "042917".*, .kind = .pair, .user = @splat(3), .device = @splat(4) };

    for (0..max_failures - 1) |_| {
        const c = try offer.challenge(io);
        const wrong, _ = try answerFor(io, c, .pair, "042918", secrets);
        try std.testing.expectError(error.WrongCode, offer.answer(io, &wrong));
    }
    // An answer to an attempt since replaced is refused, uncounted.
    const stale = try offer.challenge(io);
    _ = try offer.challenge(io);
    const late, _ = try answerFor(io, stale, .pair, "042917", secrets);
    try std.testing.expectError(error.NoAttempt, offer.answer(io, &late));

    const c = try offer.challenge(io);
    const right, const key = try answerFor(io, c, .pair, "042917", secrets);
    const reply = try offer.answer(io, &right);
    try std.testing.expectEqualDeep(Joined{ .user = @splat(3), .device = @splat(4) }, try openReply(key, &reply));
    const got, const closed = offer.outcome(io);
    try std.testing.expectEqualDeep(secrets, got.?);
    try std.testing.expect(!closed);
    try std.testing.expectError(error.Closed, offer.challenge(io));
}

test "an offer to join isn't taken as one to pair" {
    const io = std.testing.io;
    var offer: Offer = .{ .code = "123456".*, .kind = .join, .user = @splat(3), .device = @splat(4) };
    const c = try offer.challenge(io);
    const pairingAsYours, _ = try answerFor(io, c, .pair, "123456", .{ .user = @splat(7), .founder = @splat(9) });
    try std.testing.expectError(error.WrongCode, offer.answer(io, &pairingAsYours));
}

test "too many wrong codes close it" {
    const io = std.testing.io;
    var offer: Offer = .{ .code = "111111".*, .kind = .pair, .user = @splat(3), .device = @splat(4) };
    for (0..max_failures) |_| {
        const c = try offer.challenge(io);
        const wrong, _ = try answerFor(io, c, .pair, "222222", .{ .user = @splat(1), .founder = @splat(2) });
        try std.testing.expectError(error.WrongCode, offer.answer(io, &wrong));
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
