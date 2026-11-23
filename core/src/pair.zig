//! Pairing a new device with a library's member's by a short code: the new
//! device shows a 6-digit code, and the other, given it, sends the library's
//! founder's key, and to pair one of its person's own devices, the person's
//! secret too, sealed with a key only a device that knows the code can
//! derive; the new device answers with its person's key and its own, sealed
//! the same way, so a new member's can be added, and the device named, at
//! once. CPace (draft-irtf-cfrg-cpace), over
//! ristretto255 and SHA-512, makes the code worth one guess per attempt (an
//! eavesdropper learns nothing to guess it by offline), and the new device
//! stops pairing after a few wrong ones.
//!
//! Over HTTP, at `/pair` on the new device: `GET` starts an attempt,
//! answering its session ID and the new device's share; `POST` answers it
//! with the session ID, the other device's share, and the sealed secrets,
//! and is answered with the new device's sealed person and device keys. The
//! member's device decides what the new one is (`Kind`): sent the person's
//! secret, another of the person's devices; sent none (zeros), a new
//! member's. The new device makes one offer, for either.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const Sha512 = std.crypto.hash.sha2.Sha512;
const Ristretto255 = std.crypto.ecc.Ristretto255;
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const serve_ = @import("serve.zig");

pub const path = "/pair";
/// Wrong codes the new device takes from one address, and from all, before
/// it stops pairing: so no one host can stop it, and thirty guesses at a
/// million codes are all anyone gets.
pub const max_failures = 3;
pub const max_total_failures = 30;

pub const Code = [6]u8;

/// What the member's device makes of a new device: another of its person's
/// devices (it gets the person's secret), or a new member's (it doesn't).
pub const Kind = enum { pair, join };

/// What's sent: the person's seed (its secret; zeros when joining) and the
/// library's founder's key.
pub const Secrets = struct {
    person: [32]u8,
    founder: [32]u8,

    /// Whether they make the new device a new member's (no secret sent).
    pub fn joining(s: Secrets) bool {
        return std.mem.allEqual(u8, &s.person, 0);
    }
};

const sid_length = 16;
const challenge_length = sid_length + 32;
const sealed_length = 64 + Aead.tag_length;
const answer_length = sid_length + 32 + sealed_length;
const reply_length = 64 + Aead.tag_length;

/// Who the new device is, as its reply says.
pub const Joined = struct { person: [32]u8, device: [32]u8 };

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
    // Once what the offer was for; now always this, as offers for pairing
    // were, so those still pair.
    lv(&h, "pair");
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

// Each key seals one message each way: the secrets with nonce 0, and the
// reply with nonce 1.
fn seal(key: [32]u8, secrets: Secrets) [sealed_length]u8 {
    var out: [sealed_length]u8 = undefined;
    Aead.encrypt(out[0..64], out[64..], &(secrets.person ++ secrets.founder), ad, @splat(0), key);
    return out;
}

fn open(key: [32]u8, sealed: *const [sealed_length]u8) !Secrets {
    var plain: [64]u8 = undefined;
    Aead.decrypt(&plain, sealed[0..64], sealed[64..].*, ad, @splat(0), key) catch return error.WrongCode;
    return .{ .person = plain[0..32].*, .founder = plain[32..].* };
}

const reply_ad = "Cinematheque pairing reply";

fn sealReply(key: [32]u8, joined: Joined) [reply_length]u8 {
    var out: [reply_length]u8 = undefined;
    Aead.encrypt(out[0..64], out[64..], &(joined.person ++ joined.device), reply_ad, nonceOne(), key);
    return out;
}

fn openReply(key: [32]u8, sealed: []const u8) !Joined {
    if (sealed.len != reply_length) return error.Malformed;
    var plain: [64]u8 = undefined;
    Aead.decrypt(&plain, sealed[0..64], sealed[64..][0..Aead.tag_length].*, reply_ad, nonceOne(), key) catch return error.BadReply;
    return .{ .person = plain[0..32].*, .device = plain[32..].* };
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
    /// This device's person's key, and its own, to answer with.
    person: [32]u8,
    device: [32]u8,
    mutex: Io.Mutex = .init,
    /// The attempt under way: its session, this device's share, and when it
    /// started.
    attempt: ?struct { sid: [sid_length]u8, share: Share, started: Io.Timestamp } = null,
    /// How long a new request for a challenge is given the attempt under way
    /// instead of starting another: without it, anyone on the network could
    /// ask in a loop and end the other device's attempt before it answered.
    /// An attempt takes one answer either way, so it's still one guess.
    reuse_ms: i64 = 10_000,
    failures: u8 = 0,
    /// Wrong codes by address (its host), the first few seen.
    by_address: [max_total_failures]struct { peer: Peer, failures: u8 } = undefined,
    addresses: usize = 0,
    received: ?Secrets = null,

    fn failuresFrom(o: *Offer, peer: Peer) u8 {
        for (o.by_address[0..o.addresses]) |a| if (std.mem.eql(u8, &a.peer, &peer)) return a.failures;
        return 0;
    }

    fn fail(o: *Offer, peer: Peer) void {
        o.failures += 1;
        for (o.by_address[0..o.addresses]) |*a| if (std.mem.eql(u8, &a.peer, &peer)) {
            a.failures += 1;
            return;
        };
        if (o.addresses < o.by_address.len) {
            o.by_address[o.addresses] = .{ .peer = peer, .failures = 1 };
            o.addresses += 1;
        }
    }

    fn closedTo(o: *Offer, peer: Peer) bool {
        return o.received != null or o.failures >= max_total_failures or o.failuresFrom(peer) >= max_failures;
    }

    /// What's come of it: the secrets, once received, and whether it has
    /// stopped, after too many wrong codes.
    pub fn outcome(o: *Offer, io: Io) struct { ?Secrets, bool } {
        o.mutex.lockUncancelable(io);
        defer o.mutex.unlock(io);
        return .{ o.received, o.failures >= max_total_failures };
    }

    /// Starts an attempt (ending any other, but one started within
    /// `reuse_ms`, which it returns again): its session ID and this device's
    /// share.
    pub fn challenge(o: *Offer, io: Io, peer: Peer) ![challenge_length]u8 {
        try o.mutex.lock(io);
        defer o.mutex.unlock(io);
        if (o.closedTo(peer)) return error.Closed;
        const now = Io.Timestamp.now(io, .awake);
        if (o.attempt) |a| if (a.started.durationTo(now).toMilliseconds() < o.reuse_ms) return a.sid ++ a.share.point;
        var sid: [sid_length]u8 = undefined;
        io.random(&sid);
        const share = try Share.init(io, &o.code, sid);
        o.attempt = .{ .sid = sid, .share = share, .started = now };
        return sid ++ share.point;
    }

    /// Takes the other device's answer to the attempt under way: its share
    /// and the sealed secrets, which open only if it had the code. Returns
    /// the reply: this device's person's key and its own, sealed.
    pub fn answer(o: *Offer, io: Io, peer: Peer, body: []const u8) ![reply_length]u8 {
        if (body.len != answer_length) return error.Malformed;
        try o.mutex.lock(io);
        defer o.mutex.unlock(io);
        if (o.closedTo(peer)) return error.Closed;
        const attempt = o.attempt orelse return error.NoAttempt;
        if (!std.mem.eql(u8, &attempt.sid, body[0..sid_length])) return error.NoAttempt;
        o.attempt = null;
        const theirs = body[sid_length..][0..32].*;
        const key = sessionKey(attempt.share, theirs, attempt.sid, theirs, attempt.share.point) catch {
            o.fail(peer);
            return error.WrongCode;
        };
        o.received = open(key, body[sid_length + 32 ..][0..sealed_length]) catch {
            o.fail(peer);
            return error.WrongCode;
        };
        return sealReply(key, .{ .person = o.person, .device = o.device });
    }

    pub fn handler(o: *Offer) serve_.Handler {
        return .{ .context = o, .function = respond };
    }
};

/// An address's host (not its port), itself, not a hash another address
/// could be chosen to share: an IPv6 address, or an IPv4 one mapped into
/// IPv6's space.
pub const Peer = [16]u8;

fn peerKey(address: Io.net.IpAddress) Peer {
    return switch (address) {
        .ip4 => |a| @as([12]u8, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff }) ++ a.bytes,
        .ip6 => |a| a.bytes,
    };
}

/// A test's peer, by number.
fn testPeer(n: u8) Peer {
    var peer: Peer = @splat(0);
    peer[15] = n;
    return peer;
}

fn respond(context: ?*anyopaque, io: Io, gpa: std.mem.Allocator, request: *http.Server.Request, address: Io.net.IpAddress) anyerror!bool {
    if (!std.mem.eql(u8, request.head.target, path)) return false;
    const o: *Offer = @ptrCast(@alignCast(context.?));
    const peer = peerKey(address);
    switch (request.head.method) {
        .GET => {
            const challenge = o.challenge(io, peer) catch |err| {
                try request.respond(@errorName(err), .{ .status = .gone });
                return true;
            };
            try request.respond(&challenge, .{});
        },
        .POST => {
            var body_buf: [1024]u8 = undefined;
            const body = try (try request.readerExpectContinue(&body_buf)).allocRemaining(gpa, .limited(1024));
            defer gpa.free(body);
            const reply = o.answer(io, peer, body) catch |err| {
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

/// Sends `secrets` to the new device at `url` (its `/pair`), making it
/// `kind`, given the code it shows (when joining, the person's secret isn't
/// sent). Returns the new device's keys, its person's and its own.
pub fn send(io: Io, arena: std.mem.Allocator, client: *http.Client, url: []const u8, kind: Kind, code: []const u8, secrets: Secrets) !Joined {
    if (!isCode(code)) return error.WrongCode;
    const uri = try std.Uri.parse(url);
    const challenge = blk: {
        var request = try client.request(.GET, uri, .{ .redirect_behavior = .not_allowed });
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
    const sent: Secrets = .{ .person = if (kind == .pair) secrets.person else @splat(0), .founder = secrets.founder };
    const body = sid ++ share.point ++ seal(key, sent);

    var request = try client.request(.POST, uri, .{ .redirect_behavior = .not_allowed });
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
fn answerFor(io: Io, challenge: [challenge_length]u8, code: []const u8, secrets: Secrets) !struct { [answer_length]u8, [32]u8 } {
    const sid = challenge[0..sid_length].*;
    const theirs = challenge[sid_length..][0..32].*;
    const share = try Share.init(io, code, sid);
    const key = try sessionKey(share, theirs, sid, share.point, theirs);
    return .{ sid ++ share.point ++ seal(key, secrets), key };
}

test "the right code pairs, and the reply carries the new person; wrong ones count" {
    const io = std.testing.io;
    const secrets: Secrets = .{ .person = @splat(7), .founder = @splat(9) };
    var offer: Offer = .{ .code = "042917".*, .person = @splat(3), .device = @splat(4), .reuse_ms = 0 };

    for (0..max_failures - 1) |_| {
        const c = try offer.challenge(io, testPeer(1));
        const wrong, _ = try answerFor(io, c, "042918", secrets);
        try std.testing.expectError(error.WrongCode, offer.answer(io, testPeer(1), &wrong));
    }
    // An answer to an attempt since replaced is refused, uncounted.
    const stale = try offer.challenge(io, testPeer(1));
    _ = try offer.challenge(io, testPeer(1));
    const late, _ = try answerFor(io, stale, "042917", secrets);
    try std.testing.expectError(error.NoAttempt, offer.answer(io, testPeer(1), &late));

    const c = try offer.challenge(io, testPeer(1));
    const right, const key = try answerFor(io, c, "042917", secrets);
    const reply = try offer.answer(io, testPeer(1), &right);
    try std.testing.expectEqualDeep(Joined{ .person = @splat(3), .device = @splat(4) }, try openReply(key, &reply));
    const got, const closed = offer.outcome(io);
    try std.testing.expectEqualDeep(secrets, got.?);
    try std.testing.expect(!closed);
    try std.testing.expectError(error.Closed, offer.challenge(io, testPeer(1)));
}

test "asking again soon doesn't end the attempt under way, which still takes one guess" {
    const io = std.testing.io;
    const secrets: Secrets = .{ .person = @splat(7), .founder = @splat(9) };
    var offer: Offer = .{ .code = "042917".*, .person = @splat(3), .device = @splat(4) };
    const c = try offer.challenge(io, testPeer(1));
    // Someone else asks meanwhile, and is given the same attempt.
    try std.testing.expectEqualSlices(u8, &c, &(try offer.challenge(io, testPeer(1))));
    const right, _ = try answerFor(io, c, "042917", secrets);
    _ = try offer.answer(io, testPeer(1), &right);
    // Taken, an attempt takes no second answer.
    try std.testing.expectError(error.Closed, offer.answer(io, testPeer(1), &right));
}

test "the member's device decides: a new member's gets no secret" {
    const io = std.testing.io;
    var offer: Offer = .{ .code = "123456".*, .person = @splat(3), .device = @splat(4) };
    const c = try offer.challenge(io, testPeer(1));
    const joining, _ = try answerFor(io, c, "123456", .{ .person = @splat(0), .founder = @splat(9) });
    _ = try offer.answer(io, testPeer(1), &joining);
    const got, _ = offer.outcome(io);
    try std.testing.expect(got.?.joining());
    try std.testing.expect(!(Secrets{ .person = @splat(7), .founder = @splat(9) }).joining());
}

test "too many wrong codes close it to their address, and to all" {
    const io = std.testing.io;
    var offer: Offer = .{ .code = "111111".*, .person = @splat(3), .device = @splat(4), .reuse_ms = 0 };
    const guess = struct {
        fn wrong(o: *Offer, peer: Peer) !void {
            const c = try o.challenge(std.testing.io, peer);
            const w, _ = try answerFor(std.testing.io, c, "222222", .{ .person = @splat(1), .founder = @splat(2) });
            try std.testing.expectError(error.WrongCode, o.answer(std.testing.io, peer, &w));
        }
    };
    for (0..max_failures) |_| try guess.wrong(&offer, testPeer(1));
    // Closed to that address, not to the device with the code.
    try std.testing.expectError(error.Closed, offer.challenge(io, testPeer(1)));
    _, var closed = offer.outcome(io);
    try std.testing.expect(!closed);
    _ = try offer.challenge(io, testPeer(2));
    // Enough wrong codes from enough addresses close it to all.
    var n: u8 = 3;
    while (offer.failures < max_total_failures) : (n += 1) for (0..max_failures) |_| {
        if (offer.failures == max_total_failures) break;
        try guess.wrong(&offer, testPeer(n));
    };
    _, closed = offer.outcome(io);
    try std.testing.expect(closed);
    try std.testing.expectError(error.Closed, offer.challenge(io, testPeer(2)));
}

test "codes are six digits" {
    const code = newCode(std.testing.io);
    try std.testing.expect(isCode(&code));
    try std.testing.expect(!isCode("12345"));
    try std.testing.expect(!isCode("12a456"));
}
