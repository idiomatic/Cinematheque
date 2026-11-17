//! Measures the replica design at Cinematheque's scale: build a library on
//! one peer, sync it cold to another, diverge both by about 1%, sync both
//! ways, and fetch single titles into a thin replica.
//!
//! Usage: crdt-bench [divisor] [directory]
//! The divisor shrinks the library (e.g., 10 for a tenth); the directory
//! holds the replicas' databases and is replaced on each run.

const std = @import("std");
const Io = std.Io;
const replica_ = @import("replica.zig");
const net = @import("net.zig");
const Replica = replica_.Replica;

test {
    _ = @import("hlc.zig");
    _ = @import("op.zig");
    _ = @import("merkle.zig");
    _ = net;
    _ = replica_;
}

/// The laptop's user founds the library; the desktop's user is invited.
fn founder() ![32]u8 {
    return (try replica_.userKeyPair(@splat(1))).public_key.toBytes();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const divisor = if (args.len > 1) try std.fmt.parseInt(u32, args[1], 10) else 1;
    const dir = if (args.len > 2) args[2] else "bench";

    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;

    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);

    const movies = 4000 / divisor;
    const series = 500 / divisor;
    const seasons = 8;
    const episodes = 24;

    var laptop = try open(init.gpa, arena, dir, "laptop", 1);
    defer laptop.close();
    var desktop = try open(init.gpa, arena, dir, "desktop", 2);
    try laptop.invite(wallMs(io), (try replica_.userKeyPair(@splat(2))).public_key.toBytes());
    defer desktop.close();
    var unverified = try open(init.gpa, arena, dir, "unverified", 3);
    defer unverified.close();
    unverified.verify = false;
    var thin = try open(init.gpa, arena, dir, "thin", 4);
    defer thin.close();

    try out.print("Library: {d} movies, {d} series of {d} episodes, {d} renditions\n\n", .{
        movies, series, seasons * episodes, movies + series * seasons * episodes,
    });

    var timer = Timer.start(io);
    const ops = try populate(io, &laptop, movies, series, seasons, episodes);
    try report(out, "Build on laptop (sign)", timer.lap(), ops, try laptop.bytes());

    timer = Timer.start(io);
    var stats = try replica_.sync(arena, &desktop, &laptop);
    try report(out, "Cold sync (verify)", timer.lap(), stats.sent, try desktop.bytes());
    try wire(out, stats);

    timer = Timer.start(io);
    stats = try replica_.sync(arena, &unverified, &laptop);
    try report(out, "Cold sync (no verify)", timer.lap(), stats.sent, try unverified.bytes());

    // The same cold sync over HTTP on loopback, from a second connection to
    // the laptop's database, served on another thread.
    {
        var served = try open(init.gpa, arena, dir, "laptop", 1);
        defer served.close();
        var networked = try open(init.gpa, arena, dir, "networked", 5);
        defer networked.close();
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        var listener = try address.listen(io, .{});
        defer listener.deinit(io);
        const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/sync", .{listener.socket.address.getPort()});
        var group: Io.Group = .init;
        defer group.cancel(io);
        try group.concurrent(io, serveOnce, .{ io, init.gpa, &served, &listener });
        var client: std.http.Client = .{ .allocator = init.gpa, .io = io };
        defer client.deinit();
        timer = Timer.start(io);
        stats = try net.pull(arena, &client, &networked, url);
        try report(out, "Cold sync over HTTP", timer.lap(), stats.sent, try networked.bytes());
        try wire(out, stats);
        try group.await(io);
        const same = std.mem.eql(u8, &try laptop.digest(), &try networked.digest());
        try out.print("  Matches laptop: {s}\n", .{if (same) "yes" else "NO"});
        if (!same) return error.Diverged;

        // Keep a cold sync's response, to measure how it compresses.
        var response: Io.Writer.Allocating = .init(arena);
        try replica_.writeSync(&served, arena, &.{}, &response.writer);
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/cold-sync.bin", .{dir}), .data = response.written() });

        // How Zig's own gzip would shrink it (it has no zstd compressor).
        for ([_]struct { []const u8, std.compress.flate.Compress.Options }{
            .{ "gzip, fastest", .fastest },
            .{ "gzip, default", .default },
        }) |level| {
            timer = Timer.start(io);
            var compressed: Io.Writer.Allocating = .init(arena);
            const window = try arena.alloc(u8, std.compress.flate.max_window_len);
            var gz = try std.compress.flate.Compress.init(&compressed.writer, window, .gzip, level[1]);
            try gz.writer.writeAll(response.written());
            try gz.finish();
            const ms = timer.lap();
            try out.print("  {s}: {d:.1} MB in {d} ms\n", .{ level[0], @as(f64, @floatFromInt(compressed.written().len)) / 1e6, ms });
        }
    }

    // Each side edits about 0.5% of the library; 100 edits collide.
    const edits = ops / 200;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    var conflicts: [100]u32 = undefined;
    for (&conflicts) |*e| e.* = random.uintLessThan(u32, series * seasons * episodes);
    try diverge(io, &laptop, random, &conflicts, edits, movies, series, "laptop");
    try diverge(io, &desktop, random, &conflicts, edits, movies, series, "desktop");

    timer = Timer.start(io);
    const to_desktop = try replica_.sync(arena, &desktop, &laptop);
    const to_laptop = try replica_.sync(arena, &laptop, &desktop);
    try report(out, "1% divergence, both ways", timer.lap(), to_desktop.sent + to_laptop.sent, null);
    try out.print("  {d} won and {d} lost on desktop; {d} won and {d} lost on laptop\n", .{
        to_desktop.won, to_desktop.lost, to_laptop.won, to_laptop.lost,
    });
    const converged = std.mem.eql(u8, &try laptop.digest(), &try desktop.digest());
    try out.print("  Converged: {s}\n", .{if (converged) "yes" else "NO"});
    var both = to_desktop;
    both.batches += to_laptop.batches;
    both.wire_bytes += to_laptop.wire_bytes;
    try wire(out, both);

    timer = Timer.start(io);
    stats = try replica_.fetch(&thin, &laptop, &.{ "c/", "members", "t/00000" });
    try report(out, "Thin fetch: one movie, members", timer.lap(), stats.sent, null);
    try wire(out, stats);

    var prefix: [16]u8 = undefined;
    timer = Timer.start(io);
    stats = try replica_.fetch(&thin, &laptop, &.{try std.fmt.bufPrint(&prefix, "t/{d:0>5}", .{movies})});
    try report(out, "Thin fetch: one series", timer.lap(), stats.sent, try thin.bytes());
    try wire(out, stats);

    try out.flush();
    if (!converged) return error.Diverged;
}

fn serveOnce(io: Io, gpa: std.mem.Allocator, src: *Replica, listener: *Io.net.Server) Io.Cancelable!void {
    net.serve(io, gpa, src, listener, 1) catch |err| std.log.err("serve: {t}", .{err});
}

fn open(gpa: std.mem.Allocator, arena: std.mem.Allocator, dir: []const u8, name: []const u8, seed: u8) !Replica {
    const path = try std.fmt.allocPrintSentinel(arena, "{s}/{s}.db", .{ dir, name }, 0);
    return Replica.open(gpa, path, try founder(), @splat(seed));
}

fn populate(io: Io, r: *Replica, movies: u32, series: u32, seasons: u32, episodes: u32) !usize {
    var key: [64]u8 = undefined;
    var value: [64]u8 = undefined;
    var ops: usize = 0;
    try r.begin();
    for (0..movies + series) |t| {
        const wall = wallMs(io);
        const is_movie = t < movies;
        const title = try std.fmt.bufPrint(&key, "t/{d:0>5}", .{t});
        try r.write(wall, title, "kind", if (is_movie) "movie" else "series");
        try r.write(wall, title, "name", try std.fmt.bufPrint(&value, "Title {d}", .{t}));
        try r.write(wall, title, "year", try std.fmt.bufPrint(&value, "{d}", .{1920 + t % 100}));
        ops += 3;
        if (is_movie) {
            ops += try rendition(r, wall, &key, title.len);
            continue;
        }
        for (1..seasons + 1) |s| {
            for (1..episodes + 1) |e| {
                const episode = try std.fmt.bufPrint(&key, "t/{d:0>5}/s{d:0>2}/e{d:0>2}", .{ t, s, e });
                try r.write(wall, episode, "name", try std.fmt.bufPrint(&value, "Episode {d}", .{e}));
                ops += 1 + try rendition(r, wall, &key, episode.len);
            }
        }
    }
    try r.commit();
    return ops;
}

/// Writes the rendition below the key in `key[0..len]`, and its holding.
fn rendition(r: *Replica, wall: u64, key: *[64]u8, len: usize) !usize {
    var value: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&value, "/media/{s}.mp4", .{key[2..len]});
    const k = try std.fmt.bufPrint(key[len..], "/r/0", .{});
    const full = key[0 .. len + k.len];
    try r.write(wall, full, "path", path);
    try r.write(wall, full, "resolution", "1080p");
    try r.write(wall, full, "held:nas", "1");
    return 3;
}

/// Renames random episodes, including every one in `conflicts`.
fn diverge(io: Io, r: *Replica, random: std.Random, conflicts: []const u32, edits: usize, movies: u32, series: u32, who: []const u8) !void {
    const episodes = series * 8 * 24;
    var key: [64]u8 = undefined;
    var value: [64]u8 = undefined;
    try r.begin();
    for (0..edits) |i| {
        const e = if (i < conflicts.len) conflicts[i] else random.uintLessThan(u32, episodes);
        const title = movies + e / (8 * 24);
        const episode = try std.fmt.bufPrint(&key, "t/{d:0>5}/s{d:0>2}/e{d:0>2}", .{ title, e / 24 % 8 + 1, e % 24 + 1 });
        try r.write(wallMs(io), episode, "name", try std.fmt.bufPrint(&value, "Renamed by {s}", .{who}));
    }
    try r.commit();
}

fn wallMs(io: Io) u64 {
    return @intCast(Io.Timestamp.now(io, .real).toMilliseconds());
}

const Timer = struct {
    io: Io,
    start_at: Io.Timestamp,

    fn start(io: Io) Timer {
        return .{ .io = io, .start_at = Io.Timestamp.now(io, .awake) };
    }

    fn lap(timer: Timer) u64 {
        return @intCast(timer.start_at.durationTo(Io.Timestamp.now(timer.io, .awake)).toMilliseconds());
    }
};

fn report(out: *Io.Writer, label: []const u8, ms: u64, ops: usize, bytes: ?i64) !void {
    const per_op_us = if (ops == 0) 0 else @as(f64, @floatFromInt(ms * 1000)) / @as(f64, @floatFromInt(ops));
    try out.print("{s:<28} {d:>7} ms  {d:>7} ops  {d:>5.1} µs/op", .{ label, ms, ops, per_op_us });
    if (bytes) |b| try out.print("  {d:>6.1} MB", .{@as(f64, @floatFromInt(b)) / 1e6});
    try out.print("\n", .{});
}

fn wire(out: *Io.Writer, stats: replica_.Stats) !void {
    try out.print("  {d} batches, {d:.1} KB on the wire", .{ stats.batches, @as(f64, @floatFromInt(stats.wire_bytes)) / 1e3 });
    try out.print("\n", .{});
}
