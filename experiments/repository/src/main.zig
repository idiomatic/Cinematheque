//! Usage:
//!   repo gen <dir> [divisor]                 make a media tree of sparse files
//!   repo serve <dir> <port> [address]        serve it (on 127.0.0.1 unless given)
//!   repo crawl <url/> json|html|index [workers]
//!   repo mutate <dir> <truth log>            rename, move, delete, and add files
//!   repo recrawl <url/> <old snapshot|-> <new snapshot> [workers]
//!   repo changes <url/> <old snapshot> <new snapshot> <truth log>

const std = @import("std");
const Io = std.Io;
const gen = @import("gen.zig");
const server = @import("server.zig");
const crawl_ = @import("crawl.zig");
const changes_ = @import("changes.zig");

test {
    _ = @import("url.zig");
    _ = server;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) return usage();
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    if (std.mem.eql(u8, args[1], "gen")) {
        const divisor = if (args.len > 3) try std.fmt.parseInt(u32, args[3], 10) else 1;
        const start = Io.Timestamp.now(io, .awake);
        const files = try gen.generate(io, args[2], .{ .movies = 4000 / divisor, .series = 500 / divisor });
        try out.print("{d} files in {d} ms\n", .{ files, start.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds() });
    } else if (std.mem.eql(u8, args[1], "serve") and args.len > 3) {
        try server.serve(io, init.gpa, args[2], if (args.len > 4) args[4] else "127.0.0.1", try std.fmt.parseInt(u16, args[3], 10));
    } else if (std.mem.eql(u8, args[1], "crawl") and args.len > 3) {
        const format = std.meta.stringToEnum(crawl_.Format, args[3]) orelse return usage();
        const workers = if (args.len > 4) try std.fmt.parseInt(usize, args[4], 10) else 8;
        var client: std.http.Client = .{ .allocator = init.gpa, .io = io };
        defer client.deinit();
        const start = Io.Timestamp.now(io, .awake);
        const result = try crawl_.crawl(io, arena, &client, args[2], format, workers, null, null);
        const ms = start.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds();
        const range = if (result.sample) |s| try crawl_.probeRange(&client, s) else .not_found;
        try out.print("{s} {t} x{d}: {d} files, {d} dirs, {d} requests ({d} retried), {d:.1} MB of listings, {d:.1} TB reported, {d} ms; range probe: {d}\n", .{
            args[2],                                                         format,                      workers,
            result.files,                                                    result.dirs,                 result.requests, result.retries,
            @as(f64, @floatFromInt(result.listing_bytes)) / 1e6, @as(f64, @floatFromInt(result.size)) / 1e12, ms,
            @intFromEnum(range),
        });
    } else if (std.mem.eql(u8, args[1], "mutate") and args.len > 3) {
        const n = try gen.mutate(io, init.gpa, args[2], args[3]);
        try out.print("{d} changes\n", .{n});
    } else if (std.mem.eql(u8, args[1], "recrawl") and args.len > 4) {
        const cwd = Io.Dir.cwd();
        var prev: ?crawl_.Snapshot = null;
        if (!std.mem.eql(u8, args[3], "-")) {
            const text = try cwd.readFileAlloc(io, args[3], arena, .unlimited);
            prev = try crawl_.Snapshot.init(arena, try crawl_.Snapshot.load(arena, text));
        }
        const workers = if (args.len > 5) try std.fmt.parseInt(usize, args[5], 10) else 8;
        var client: std.http.Client = .{ .allocator = init.gpa, .io = io };
        defer client.deinit();
        var entries: std.ArrayList(crawl_.Entry) = .empty;
        const start = Io.Timestamp.now(io, .awake);
        const result = try crawl_.crawl(io, arena, &client, args[2], .json, workers, if (prev) |*p| p else null, &entries);
        const ms = start.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds();
        var saved: Io.Writer.Allocating = .init(arena);
        try crawl_.Snapshot.save(entries.items, &saved.writer);
        try cwd.writeFile(io, .{ .sub_path = args[4], .data = saved.written() });
        try out.print("{d} files, {d} dirs: {d} requests, {d} directories reused, {d:.1} MB of listings, {d} ms\n", .{
            result.files, result.dirs, result.requests, result.skipped, @as(f64, @floatFromInt(result.listing_bytes)) / 1e6, ms,
        });
    } else if (std.mem.eql(u8, args[1], "changes") and args.len > 5) {
        try compare(io, arena, out, args[2], args[3], args[4], args[5]);
    } else return usage();
}

/// Diffs two snapshots and scores the moves, deletions, and additions found
/// against the truth log `mutate` wrote.
fn compare(io: Io, arena: std.mem.Allocator, out: *Io.Writer, base: []const u8, old_path: []const u8, new_path: []const u8, log_path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const old = try crawl_.Snapshot.load(arena, try cwd.readFileAlloc(io, old_path, arena, .unlimited));
    const new = try crawl_.Snapshot.load(arena, try cwd.readFileAlloc(io, new_path, arena, .unlimited));
    const start = Io.Timestamp.now(io, .awake);
    const report = try changes_.diff(arena, old, new);
    const us = start.durationTo(Io.Timestamp.now(io, .awake)).toMicroseconds();

    var truth: std.StringHashMapUnmanaged([]const u8) = .empty;
    var truth_count: usize = 0;
    var lines = std.mem.splitScalar(u8, try cwd.readFileAlloc(io, log_path, arena, .unlimited), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const a = f.first();
        const b = f.next() orelse continue;
        try truth.put(arena, if (std.mem.eql(u8, a, "-")) try std.mem.concat(arena, u8, &.{ "+", b }) else a, b);
        truth_count += 1;
    }
    var correct: usize = 0;
    var moves: usize = 0;
    var deleted: usize = 0;
    var added: usize = 0;
    for (report.changes) |c| {
        const old_rel = if (c.old) |o| try changes_.relative(arena, base, o) else null;
        const new_rel = if (c.new) |n| try changes_.relative(arena, base, n) else null;
        if (old_rel != null and new_rel != null) moves += 1 else if (old_rel != null) deleted += 1 else added += 1;
        const expected = if (old_rel) |o| truth.get(o) else truth.get(try std.mem.concat(arena, u8, &.{ "+", new_rel.? }));
        const want = expected orelse continue;
        if (std.mem.eql(u8, want, new_rel orelse "-")) correct += 1;
    }
    try out.print("{d} changes found ({d} moves, {d} deletions, {d} additions; {d} ambiguous) in {d} µs; {d} of {d} true changes right\n", .{
        report.changes.len, moves, deleted, added, report.ambiguous, us, correct, truth_count,
    });
}

fn usage() error{Usage} {
    std.log.err("usage: repo gen <dir> [divisor] | serve <dir> <port> | crawl <url/> json|html|index [workers]", .{});
    return error.Usage;
}
