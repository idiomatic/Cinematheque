//! Hybrid logical clock packed into 64 bits: wall-clock milliseconds in the
//! high 48 bits, a logical counter in the low 16. Comparing packed values
//! orders events causally while staying close to wall time.

const std = @import("std");

pub const Hlc = struct {
    last: u64 = 0,

    /// Timestamps a local event.
    pub fn tick(hlc: *Hlc, wall_ms: u64) u64 {
        const physical = wall_ms << 16;
        hlc.last = if (physical > hlc.last) physical else hlc.last + 1;
        return hlc.last;
    }

    /// Folds in a timestamp received from another device, so later local
    /// events order after it.
    pub fn observe(hlc: *Hlc, remote: u64) void {
        hlc.last = @max(hlc.last, remote);
    }
};

test "tick is monotonic despite a stalled or rewound wall clock" {
    var hlc: Hlc = .{};
    const a = hlc.tick(1000);
    const b = hlc.tick(1000);
    const c = hlc.tick(900);
    try std.testing.expect(a < b and b < c);
}

test "observe orders later events after remote ones" {
    var hlc: Hlc = .{};
    _ = hlc.tick(1000);
    const remote = (@as(u64, 5000) << 16) + 7;
    hlc.observe(remote);
    try std.testing.expect(hlc.tick(1001) > remote);
}
