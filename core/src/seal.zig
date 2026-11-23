//! What a sync sends, sealed so only the two devices read it: the device
//! asking makes a key pair for the request alone, agrees a secret with the
//! other device's key (its Ed25519 key, as X25519), and derives a key each
//! way. A body is sealed in chunks of up to 64 KiB with ChaCha20-Poly1305,
//! numbered, the last one marked, so none can be dropped, reordered, or cut
//! off. Who sent it is proved as before, by signatures inside.

const std = @import("std");
const X25519 = std.crypto.dh.X25519;
const Ed25519 = std.crypto.sign.Ed25519;
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const Blake3 = std.crypto.hash.Blake3;

pub const Key = [Aead.key_length]u8;

/// A request's keys, each way.
pub const Keys = struct { request: Key, response: Key };

const chunk_max = 64 * 1024;
const last_flag: u32 = 1 << 31;

fn derive(library: [16]u8, ephemeral: [32]u8, recipient: [32]u8, shared: [32]u8) Keys {
    var out: [64]u8 = undefined;
    var h = Blake3.init(.{});
    h.update("cinematheque sync keys");
    h.update(&library);
    h.update(&ephemeral);
    h.update(&recipient);
    h.update(&shared);
    h.final(&out);
    return .{ .request = out[0..32].*, .response = out[32..64].* };
}

/// The device asking's side: a fresh key pair's public key, to send first,
/// and the keys, for the device whose key (Ed25519) is `recipient`.
pub fn initiate(io: std.Io, library: [16]u8, recipient: [32]u8) !struct { [32]u8, Keys } {
    const theirs = try X25519.publicKeyFromEd25519(try Ed25519.PublicKey.fromBytes(recipient));
    var seed: [32]u8 = undefined;
    io.random(&seed);
    const ephemeral = X25519.KeyPair.generateDeterministic(seed);
    const shared = try X25519.scalarmult(ephemeral.secret_key, theirs);
    return .{ ephemeral.public_key, derive(library, ephemeral.public_key, recipient, shared) };
}

/// The other device's side: the keys for a request that began with
/// `ephemeral`, by its own key pair.
pub fn respond(library: [16]u8, own: Ed25519.KeyPair, ephemeral: [32]u8) !Keys {
    const mine = try X25519.KeyPair.fromEd25519(own);
    const shared = try X25519.scalarmult(mine.secret_key, ephemeral);
    return derive(library, ephemeral, own.public_key.toBytes(), shared);
}

/// A response's key, made afresh by the answering device's random `salt`
/// (sent beside it), so a request replayed is answered under a new key,
/// not with another plaintext under the first's keys and nonces.
pub fn salted(key: Key, salt: [32]u8) Key {
    var out: Key = undefined;
    var h = Blake3.init(.{ .key = key });
    h.update("cinematheque response");
    h.update(&salt);
    h.final(&out);
    return out;
}

/// What's sealed under one key, each part its own run of nonces.
pub const Part = enum(u8) { head = 1, body = 2, response = 3 };

fn nonce(part: Part, n: u64) [Aead.nonce_length]u8 {
    var out: [Aead.nonce_length]u8 = @splat(0);
    out[0] = @intFromEnum(part);
    std.mem.writeInt(u64, out[4..12], n, .little);
    return out;
}

/// `plain` sealed with `key`: chunks, each its length (u32, its top bit set
/// on the last), its ciphertext, and its tag.
pub fn seal(arena: std.mem.Allocator, key: Key, part: Part, plain: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    var n: u64 = 0;
    while (true) : (n += 1) {
        const len = @min(chunk_max, plain.len - at);
        const last = at + len == plain.len;
        const header: u32 = @as(u32, @intCast(len)) | if (last) last_flag else 0;
        var hb: [4]u8 = undefined;
        std.mem.writeInt(u32, &hb, header, .little);
        try out.appendSlice(arena, &hb);
        const start = out.items.len;
        try out.resize(arena, start + len + Aead.tag_length);
        var tag: [Aead.tag_length]u8 = undefined;
        Aead.encrypt(out.items[start..][0..len], &tag, plain[at..][0..len], &hb, nonce(part, n), key);
        out.items[start + len ..][0..Aead.tag_length].* = tag;
        at += len;
        if (last) return out.items;
    }
}

/// What `seal` sealed, or an error if any of it was changed, dropped,
/// reordered, or cut off.
pub fn open(arena: std.mem.Allocator, key: Key, part: Part, sealed: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    var n: u64 = 0;
    while (true) : (n += 1) {
        if (sealed.len - at < 4) return error.BadSeal;
        const hb = sealed[at..][0..4];
        const header = std.mem.readInt(u32, hb, .little);
        const len: usize = header & ~last_flag;
        at += 4;
        if (len > chunk_max or sealed.len - at < len + Aead.tag_length) return error.BadSeal;
        const start = out.items.len;
        try out.resize(arena, start + len);
        Aead.decrypt(out.items[start..][0..len], sealed[at..][0..len], sealed[at + len ..][0..Aead.tag_length].*, hb, nonce(part, n), key) catch return error.BadSeal;
        at += len + Aead.tag_length;
        if (header & last_flag != 0) {
            if (at != sealed.len) return error.BadSeal;
            return out.items;
        }
    }
}

test "sealed one way, opened the other, by the right device alone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const library: [16]u8 = @splat(1);
    const hal = try Ed25519.KeyPair.generateDeterministic(@splat(2));
    const skynet = try Ed25519.KeyPair.generateDeterministic(@splat(3));

    const ephemeral, const mine = try initiate(io, library, hal.public_key.toBytes());
    const theirs = try respond(library, hal, ephemeral);
    try std.testing.expectEqual(mine, theirs);
    // Each salt, its own response key.
    try std.testing.expect(!std.mem.eql(u8, &salted(mine.response, @splat(1)), &salted(mine.response, @splat(2))));
    try std.testing.expect(!std.mem.eql(u8, &salted(mine.response, @splat(1)), &mine.response));
    // Another device can't derive them.
    const not = try respond(library, skynet, ephemeral);
    try std.testing.expect(!std.mem.eql(u8, &not.request, &mine.request));

    var big: [200 * 1024]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i);
    for ([_][]const u8{ "", "frames", &big }) |plain| {
        const sealed = try seal(arena, mine.request, .body, plain);
        try std.testing.expectEqualSlices(u8, plain, try open(arena, theirs.request, .body, sealed));
        // Nor as another part.
        try std.testing.expectError(error.BadSeal, open(arena, theirs.request, .head, sealed));
        // Not with the other direction's key, nor changed, nor cut off.
        try std.testing.expectError(error.BadSeal, open(arena, theirs.response, .body, sealed));
        const changed = try arena.dupe(u8, sealed);
        changed[changed.len - 1] ^= 1;
        try std.testing.expectError(error.BadSeal, open(arena, theirs.request, .body, changed));
        if (plain.len > 64 * 1024) {
            // The first chunk alone, its header unmarked as the last.
            try std.testing.expectError(error.BadSeal, open(arena, theirs.request, .body, sealed[0 .. 4 + 64 * 1024 + 16]));
        }
    }
}
