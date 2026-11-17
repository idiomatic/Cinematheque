//! Compares ways to sign and verify the library's operations:
//! one Ed25519 signature each, verified singly or in batches, or one
//! signature per batch over a Merkle tree of the operations' BLAKE3 hashes.
//!
//! Usage: crdt-sigbench [operations]

const std = @import("std");
const Io = std.Io;
const Ed25519 = std.crypto.sign.Ed25519;
const Blake3 = std.crypto.hash.Blake3;

const body_len = 110; // a typical encoded operation
const verify_batch = 64;
const merkle_batch = 1024;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const n = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 409_500;

    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;

    const key_pair = try Ed25519.KeyPair.generateDeterministic(@splat(1));
    const bodies = try gpa.alloc([body_len]u8, n);
    defer gpa.free(bodies);
    var prng = std.Random.DefaultPrng.init(1);
    for (bodies) |*b| prng.random().bytes(b);

    const sigs = try gpa.alloc(Ed25519.Signature, n);
    defer gpa.free(sigs);

    try out.print("{d} operations of {d} bytes\n\n", .{ n, body_len });

    var t = Timer.start(io);
    for (bodies, sigs) |*b, *s| s.* = try key_pair.sign(b, null);
    try report(out, "Sign each", t.lap(), n);

    t = Timer.start(io);
    for (bodies, sigs) |*b, s| try s.verify(b, key_pair.public_key);
    try report(out, "Verify each", t.lap(), n);

    t = Timer.start(io);
    var i: usize = 0;
    while (i + verify_batch <= n) : (i += verify_batch) {
        var batch: [verify_batch]Ed25519.BatchElement = undefined;
        for (&batch, i..) |*e, j| e.* = .{ .sig = sigs[j], .msg = &bodies[j], .public_key = key_pair.public_key };
        try Ed25519.verifyBatch(io, verify_batch, batch);
    }
    try report(out, "Verify in batches of 64", t.lap(), i);

    // One signature per batch, over the root of a Merkle tree of op hashes.
    const leaves = try gpa.alloc([32]u8, n);
    defer gpa.free(leaves);
    const roots = try gpa.alloc(Ed25519.Signature, (n + merkle_batch - 1) / merkle_batch);
    defer gpa.free(roots);

    t = Timer.start(io);
    for (bodies, leaves) |*b, *l| Blake3.hash(b, l, .{});
    for (roots, 0..) |*s, k| {
        const root = merkleRoot(leaves[k * merkle_batch .. @min(n, (k + 1) * merkle_batch)]);
        s.* = try key_pair.sign(&root, null);
    }
    try report(out, "Sign batches of 1,024", t.lap(), n);

    t = Timer.start(io);
    for (bodies, leaves) |*b, *l| Blake3.hash(b, l, .{});
    for (roots, 0..) |s, k| {
        const root = merkleRoot(leaves[k * merkle_batch .. @min(n, (k + 1) * merkle_batch)]);
        try s.verify(&root, key_pair.public_key);
    }
    try report(out, "Verify batches of 1,024", t.lap(), n);

    // A thin replica checks one operation: its hash, its proof, and its
    // batch's signature (cached across operations from the same batch).
    const proof = merkleProof(leaves[0..merkle_batch], 5);
    t = Timer.start(io);
    const reps = 1000;
    for (0..reps) |_| {
        var leaf: [32]u8 = undefined;
        Blake3.hash(&bodies[5], &leaf, .{});
        const root = proof.rootFrom(leaf);
        try roots[0].verify(&root, key_pair.public_key);
    }
    try report(out, "Verify one by proof", t.lap(), reps);

    try out.flush();
}

fn parent(left: [32]u8, right: [32]u8) [32]u8 {
    var h = Blake3.init(.{});
    h.update(&left);
    h.update(&right);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

/// Root of a tree whose odd nodes are promoted unpaired.
fn merkleRoot(leaves: []const [32]u8) [32]u8 {
    var level: [merkle_batch][32]u8 = undefined;
    @memcpy(level[0..leaves.len], leaves);
    var len = leaves.len;
    while (len > 1) {
        var next: usize = 0;
        var i: usize = 0;
        while (i < len) : (i += 2) {
            level[next] = if (i + 1 < len) parent(level[i], level[i + 1]) else level[i];
            next += 1;
        }
        len = next;
    }
    return level[0];
}

const Proof = struct {
    siblings: [10][32]u8 = undefined,
    right: [10]bool = undefined,
    len: usize = 0,

    fn rootFrom(proof: Proof, leaf: [32]u8) [32]u8 {
        var node = leaf;
        for (proof.siblings[0..proof.len], proof.right[0..proof.len]) |sibling, right| {
            node = if (right) parent(node, sibling) else parent(sibling, node);
        }
        return node;
    }
};

fn merkleProof(leaves: []const [32]u8, index: usize) Proof {
    var level: [merkle_batch][32]u8 = undefined;
    @memcpy(level[0..leaves.len], leaves);
    var len = leaves.len;
    var at = index;
    var proof: Proof = .{};
    while (len > 1) {
        const sibling = at ^ 1;
        if (sibling < len) {
            proof.siblings[proof.len] = level[sibling];
            proof.right[proof.len] = at % 2 == 0;
            proof.len += 1;
        }
        var next: usize = 0;
        var i: usize = 0;
        while (i < len) : (i += 2) {
            level[next] = if (i + 1 < len) parent(level[i], level[i + 1]) else level[i];
            next += 1;
        }
        len = next;
        at /= 2;
    }
    return proof;
}

test "a proof rebuilds the root" {
    var leaves: [merkle_batch][32]u8 = undefined;
    for (&leaves, 0..) |*l, i| l.* = @splat(@intCast(i % 256));
    for ([_]usize{ 0, 5, 1023 }) |index| {
        try std.testing.expectEqual(merkleRoot(&leaves), merkleProof(&leaves, index).rootFrom(leaves[index]));
    }
    try std.testing.expectEqual(merkleRoot(leaves[0..7]), merkleProof(leaves[0..7], 6).rootFrom(leaves[6]));
}

const Timer = struct {
    io: Io,
    start_at: Io.Timestamp,

    fn start(io: Io) Timer {
        return .{ .io = io, .start_at = Io.Timestamp.now(io, .awake) };
    }

    fn lap(timer: Timer) u64 {
        return @intCast(timer.start_at.durationTo(Io.Timestamp.now(timer.io, .awake)).toMicroseconds());
    }
};

fn report(out: *Io.Writer, label: []const u8, us: u64, ops: usize) !void {
    const per_op = @as(f64, @floatFromInt(us)) / @as(f64, @floatFromInt(ops));
    try out.print("{s:<26} {d:>8.1} ms  {d:>6.2} µs/op\n", .{ label, @as(f64, @floatFromInt(us)) / 1000, per_op });
}
