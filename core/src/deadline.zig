//! Deadlines for what waits on another host, which Zig 0.17's `Io` reads
//! have none of: the work runs as a task beside a sleep, and whichever
//! finishes first decides; the other is canceled. So a host that sends a
//! byte at a time, or nothing, holds a task no longer than its deadline.

const std = @import("std");
const Io = std.Io;

fn Result(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}

/// `f(args...)`'s result, or `error.Timeout` if it didn't finish within
/// `ms` milliseconds (it's canceled then).
pub fn within(io: Io, ms: i64, comptime f: anytype, args: anytype) (error{ Timeout, Canceled } || ErrorOf(Result(f)))!Payload(Result(f)) {
    const Event = union(enum) { done: Result(f), timeout: void };
    var buffer: [2]Event = undefined;
    var select: Io.Select(Event) = .init(io, &buffer);
    defer select.cancelDiscard();
    // Without tasks to spare, it's done as it would be without a deadline.
    select.concurrent(.timeout, sleep, .{ io, ms }) catch return @call(.auto, f, args);
    select.concurrent(.done, f, args) catch {
        select.cancelDiscard();
        return @call(.auto, f, args);
    };
    return switch (try select.await()) {
        .done => |r| r,
        .timeout => error.Timeout,
    };
}

/// Runs `f` as a task while a watchdog checks `beat`, a count `f` advances
/// as it makes headway (each mebibyte come) and sets to `finished` as it
/// ends: canceled, as `error.Timeout`, once `ms` pass without one. For a
/// long transfer: one task for all of it, and no cancel unless it stalls,
/// as `within` around each read cost a cancel per read, and canceling a
/// sleeping task takes signaling it (and so other threads' calls, such as
/// a server's in the same process) until it wakes, which held a download
/// from a local drive to 8 MB/s.
pub fn paced(io: Io, ms: i64, beat: *const std.atomic.Value(u64), comptime f: anytype, args: anytype) (error{ Timeout, Canceled } || ErrorOf(Result(f)))!Payload(Result(f)) {
    const Event = union(enum) { done: Result(f), stalled: void };
    var buffer: [2]Event = undefined;
    var select: Io.Select(Event) = .init(io, &buffer);
    defer select.cancelDiscard();
    // Without tasks to spare, it's done as it would be without a deadline.
    select.concurrent(.stalled, watch, .{ io, ms, beat }) catch return @call(.auto, f, args);
    select.concurrent(.done, f, args) catch {
        select.cancelDiscard();
        return @call(.auto, f, args);
    };
    switch (try select.await()) {
        // The watchdog sees it's finished, and returns, uncanceled.
        .done => |r| {
            _ = try select.await();
            return r;
        },
        .stalled => return error.Timeout,
    }
}

/// What `paced`'s work sets its beat to as it ends.
pub const finished = std.math.maxInt(u64);

/// Returns once `ms` pass without `beat` changing, or once it's `finished`.
fn watch(io: Io, ms: i64, beat: *const std.atomic.Value(u64)) void {
    var seen = beat.load(.acquire);
    var since = Io.Timestamp.now(io, .awake);
    while (true) {
        io.sleep(.fromMilliseconds(@min(ms, 50)), .awake) catch return;
        const now = beat.load(.acquire);
        if (now == finished) return;
        if (now != seen) {
            seen = now;
            since = Io.Timestamp.now(io, .awake);
        } else if (since.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds() >= ms) return;
    }
}

fn ErrorOf(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |e| e.error_set,
        else => error{},
    };
}

fn Payload(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |e| e.payload,
        else => T,
    };
}

/// In steps, so canceling it (as the work finishing first does) takes
/// within one, where `Io` can't interrupt a sleep under way: in the apps,
/// whose threads don't take the signal it interrupts with (see the
/// development notes), canceling a single long sleep waited it out, and
/// held every request a connection made after its first.
fn sleep(io: Io, ms: i64) void {
    const step = 50;
    const start = Io.Timestamp.now(io, .awake);
    while (true) {
        const left = ms - start.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds();
        if (left <= 0) return;
        io.sleep(.fromMilliseconds(@min(left, step)), .awake) catch return;
    }
}

test "work that finishes in time gives its result; work that doesn't, a timeout" {
    const io = std.testing.io;
    const quick = struct {
        fn run(n: u32) !u32 {
            return n + 1;
        }
    };
    try std.testing.expectEqual(@as(u32, 2), try within(io, 1000, quick.run, .{@as(u32, 1)}));
    const slow = struct {
        fn run(i: Io) !u32 {
            try i.sleep(.fromSeconds(10), .awake);
            return 0;
        }
    };
    try std.testing.expectError(error.Timeout, within(io, 50, slow.run, .{io}));
}

test "paced work goes on while it makes headway, and stops once it doesn't" {
    const io = std.testing.io;
    const steady = struct {
        fn run(i: Io, beat: *std.atomic.Value(u64)) !u32 {
            // Longer in all than the deadline, a beat well within it each time.
            defer beat.store(finished, .release);
            for (0..6) |_| {
                try i.sleep(.fromMilliseconds(100), .awake);
                _ = beat.fetchAdd(1, .acq_rel);
            }
            return 7;
        }
    };
    var beat: std.atomic.Value(u64) = .init(0);
    try std.testing.expectEqual(@as(u32, 7), try paced(io, 300, &beat, steady.run, .{ io, &beat }));
    const stalled = struct {
        fn run(i: Io) !u32 {
            try i.sleep(.fromSeconds(10), .awake);
            return 0;
        }
    };
    var silent: std.atomic.Value(u64) = .init(0);
    try std.testing.expectError(error.Timeout, paced(io, 200, &silent, stalled.run, .{io}));
}
