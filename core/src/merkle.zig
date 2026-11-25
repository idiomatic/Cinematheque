//! Merkle trees over a batch of operations, so one signature covers the
//! batch, and a receiver rebuilds its root from the operations sent and the
//! leaves of those that weren't. Leaves and inner nodes hash with distinct
//! prefixes, so neither can pose as the other; an odd node at the end of a
//! level is promoted unpaired.

const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;

pub const Hash = [32]u8;
pub const max_leaves = 1024;

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

/// The root of 1 to `max_leaves` leaves.
pub fn root(leaves: []const Hash) Hash {
    std.debug.assert(leaves.len > 0 and leaves.len <= max_leaves);
    var level: [max_leaves]Hash = undefined;
    @memcpy(level[0..leaves.len], leaves);
    var len = leaves.len;
    while (len > 1) {
        var i: usize = 0;
        while (i < len) : (i += 2) level[i / 2] = if (i + 1 < len) node(level[i], level[i + 1]) else level[i];
        len = (len + 1) / 2;
    }
    return level[0];
}

test "a root pairs leaves level by level, an odd one promoted" {
    const a = leaf("a");
    const b = leaf("b");
    const c = leaf("c");
    try std.testing.expectEqual(a, root(&.{a}));
    try std.testing.expectEqual(node(node(a, b), c), root(&.{ a, b, c }));
    try std.testing.expect(!std.mem.eql(u8, &root(&.{ a, b }), &root(&.{ b, a })));
}
