//! Merkle trees over a batch of operations, so one signature covers the
//! batch and each operation stays verifiable on its own by a proof.
//! Leaves and inner nodes hash with distinct prefixes, so neither can pose
//! as the other; an odd node at the end of a level is promoted unpaired.

const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;

pub const Hash = [32]u8;
pub const max_leaves = 1024;
const max_depth = 10;

pub fn leaf(body: []const u8) Hash {
    var h = Blake3.init(.{});
    h.update(&.{0});
    h.update(body);
    var out: Hash = undefined;
    h.final(&out);
    return out;
}

fn node(left: Hash, right: Hash) Hash {
    var h = Blake3.init(.{});
    h.update(&.{1});
    h.update(&left);
    h.update(&right);
    var out: Hash = undefined;
    h.final(&out);
    return out;
}

pub fn root(leaves: []const Hash) Hash {
    var tree: Tree = undefined;
    tree.init(leaves);
    return tree.root();
}

pub fn proof(leaves: []const Hash, index: usize) Proof {
    var tree: Tree = undefined;
    tree.init(leaves);
    return tree.proof(index);
}

pub const Proof = struct {
    siblings: [max_depth]Hash = undefined,
    /// Bit i is set when the path's node at level i is a left child.
    left: u16 = 0,
    len: u8 = 0,

    pub fn rootFrom(p: *const Proof, leaf_hash: Hash) Hash {
        var at = leaf_hash;
        for (p.siblings[0..p.len], 0..) |sibling, i| {
            at = if (p.left & (@as(u16, 1) << @intCast(i)) != 0) node(at, sibling) else node(sibling, at);
        }
        return at;
    }

    /// Bytes on the wire: length, direction bits, and siblings.
    pub fn wireLen(p: *const Proof) usize {
        return 1 + 2 + 32 * @as(usize, p.len);
    }
};

/// Every level of a batch's tree, built once so that proofs for many of
/// its leaves are cheap.
pub const Tree = struct {
    nodes: [2 * max_leaves]Hash,
    /// Level i occupies nodes[starts[i]..][0..lens[i]]; level 0 is the leaves.
    starts: [max_depth + 1]usize,
    lens: [max_depth + 1]usize,
    levels: usize,

    pub fn init(tree: *Tree, leaves: []const Hash) void {
        std.debug.assert(leaves.len > 0 and leaves.len <= max_leaves);
        @memcpy(tree.nodes[0..leaves.len], leaves);
        tree.starts[0] = 0;
        tree.lens[0] = leaves.len;
        tree.levels = 1;
        var end = leaves.len;
        while (tree.lens[tree.levels - 1] > 1) : (tree.levels += 1) {
            const below = tree.nodes[tree.starts[tree.levels - 1]..][0..tree.lens[tree.levels - 1]];
            tree.starts[tree.levels] = end;
            var i: usize = 0;
            while (i < below.len) : (i += 2) {
                tree.nodes[end] = if (i + 1 < below.len) node(below[i], below[i + 1]) else below[i];
                end += 1;
            }
            tree.lens[tree.levels] = end - tree.starts[tree.levels];
        }
    }

    pub fn root(tree: *const Tree) Hash {
        return tree.nodes[tree.starts[tree.levels - 1]];
    }

    pub fn proof(tree: *const Tree, index: usize) Proof {
        var out: Proof = .{};
        var at = index;
        for (0..tree.levels - 1) |level| {
            if (at ^ 1 < tree.lens[level]) {
                out.siblings[out.len] = tree.nodes[tree.starts[level] + (at ^ 1)];
                if (at % 2 == 0) out.left |= @as(u16, 1) << @intCast(out.len);
                out.len += 1;
            }
            at /= 2;
        }
        return out;
    }

    /// Appends one shared proof for all of `indices` (sorted, distinct):
    /// the sibling hashes their leaves can't derive, in the order
    /// `rootFromMulti` consumes them.
    pub fn multiproof(tree: *const Tree, indices: []const usize, gpa: std.mem.Allocator, out: *std.ArrayList(Hash)) !void {
        var at: [max_leaves]usize = undefined;
        @memcpy(at[0..indices.len], indices);
        var n = indices.len;
        var level: usize = 0;
        while (tree.lens[level] > 1) : (level += 1) {
            const len = tree.lens[level];
            const nodes = tree.nodes[tree.starts[level]..][0..len];
            var m: usize = 0;
            var k: usize = 0;
            while (k < n) : (k += 1) {
                const i = at[k];
                if (i % 2 == 0) {
                    if (i + 1 < len) {
                        if (k + 1 < n and at[k + 1] == i + 1) k += 1 else try out.append(gpa, nodes[i + 1]);
                    }
                } else try out.append(gpa, nodes[i - 1]);
                at[m] = i / 2;
                m += 1;
            }
            n = m;
        }
    }
};

/// Rebuilds the root of a `count`-leaf tree from the leaves at `indices`
/// (sorted, distinct) and a shared proof from `Tree.multiproof`.
pub fn rootFromMulti(count: usize, indices: []const usize, leaves: []const Hash, siblings: []const Hash) error{BadProof}!Hash {
    if (indices.len == 0 or indices.len != leaves.len or count > max_leaves) return error.BadProof;
    var at: [max_leaves]usize = undefined;
    var hashes: [max_leaves]Hash = undefined;
    @memcpy(at[0..indices.len], indices);
    @memcpy(hashes[0..leaves.len], leaves);
    var n = indices.len;
    var len = count;
    var used: usize = 0;
    while (len > 1) : (len = (len + 1) / 2) {
        var m: usize = 0;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const i = at[k];
            if (i >= len or (k > 0 and at[k - 1] >= i)) return error.BadProof;
            var h = hashes[k];
            if (i % 2 == 0) {
                if (i + 1 < len) {
                    if (k + 1 < n and at[k + 1] == i + 1) {
                        h = node(h, hashes[k + 1]);
                        k += 1;
                    } else {
                        if (used == siblings.len) return error.BadProof;
                        h = node(h, siblings[used]);
                        used += 1;
                    }
                }
            } else {
                if (used == siblings.len) return error.BadProof;
                h = node(siblings[used], h);
                used += 1;
            }
            at[m] = i / 2;
            hashes[m] = h;
            m += 1;
        }
        n = m;
    }
    if (used != siblings.len or n != 1) return error.BadProof;
    return hashes[0];
}

test "every proof rebuilds the root" {
    var leaves: [max_leaves]Hash = undefined;
    for (&leaves, 0..) |*l, i| l.* = leaf(std.mem.asBytes(&i));
    for ([_]usize{ 1, 2, 7, 1000, max_leaves }) |n| {
        const r = root(leaves[0..n]);
        for (0..n) |i| try std.testing.expectEqual(r, proof(leaves[0..n], i).rootFrom(leaves[i]));
    }
}

test "a proof fails for another leaf" {
    var leaves: [8]Hash = undefined;
    for (&leaves, 0..) |*l, i| l.* = leaf(std.mem.asBytes(&i));
    try std.testing.expect(!std.mem.eql(u8, &root(&leaves), &proof(&leaves, 3).rootFrom(leaves[4])));
}

test "shared proofs rebuild the root, and a contiguous range needs few hashes" {
    const gpa = std.testing.allocator;
    var leaves: [max_leaves]Hash = undefined;
    for (&leaves, 0..) |*l, i| l.* = leaf(std.mem.asBytes(&i));
    const tree = try gpa.create(Tree);
    defer gpa.destroy(tree);
    var siblings: std.ArrayList(Hash) = .empty;
    defer siblings.deinit(gpa);
    var picked: std.ArrayList(Hash) = .empty;
    defer picked.deinit(gpa);

    var range: [64]usize = undefined;
    for (&range, 0..) |*r, i| r.* = 128 + i;
    const sets = [_][]const usize{ &range, &.{5}, &.{ 0, 1, 2, 999 }, &.{ 3, 500, 998 }, &.{6} };
    for ([_]usize{ max_leaves, 999, 7 }) |count| {
        tree.init(leaves[0..count]);
        for (sets) |set| {
            if (set[set.len - 1] >= count) continue;
            siblings.clearRetainingCapacity();
            picked.clearRetainingCapacity();
            try tree.multiproof(set, gpa, &siblings);
            for (set) |i| try picked.append(gpa, leaves[i]);
            try std.testing.expectEqual(tree.root(), try rootFromMulti(count, set, picked.items, siblings.items));
            // A wrong leaf yields another root.
            picked.items[0][0] ^= 1;
            try std.testing.expect(!std.mem.eql(u8, &tree.root(), &(rootFromMulti(count, set, picked.items, siblings.items) catch continue)));
        }
    }
    tree.init(&leaves);
    siblings.clearRetainingCapacity();
    try tree.multiproof(&range, gpa, &siblings);
    try std.testing.expectEqual(@as(usize, 4), siblings.items.len);
}
