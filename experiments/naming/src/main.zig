//! Parses every video path in an `INDEX` and groups episodes into series,
//! reporting what correlation would have to work with.
//!
//! Usage: names <INDEX file> [--tsv]
//! With `--tsv`, prints each video's parse as `path, kind, title, year,
//! season, episode, last episode, part, edition, IDs` columns instead.

const std = @import("std");
const Io = std.Io;
const parse_ = @import("parse.zig");

test {
    _ = @import("tests.zig");
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.log.err("usage: names <INDEX file>", .{});
        return error.Usage;
    }
    const index = try Io.Dir.cwd().readFileAlloc(io, args[1], arena, .unlimited);
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const tsv = args.len > 2 and std.mem.eql(u8, args[2], "--tsv");
    var counts = std.EnumArray(parse_.Kind, usize).initFill(0);
    var no_year: usize = 0;
    var series: std.StringHashMapUnmanaged(void) = .empty;
    var movies: std.StringHashMapUnmanaged(void) = .empty;
    var files: usize = 0;
    var scratch: [1024]u8 = undefined;

    const start = Io.Timestamp.now(io, .awake);
    var lines = std.mem.splitScalar(u8, index, '\n');
    while (lines.next()) |line| {
        const path = line[0 .. std.mem.indexOfScalar(u8, line, '\t') orelse line.len];
        if (!parse_.isVideo(path)) continue;
        files += 1;
        const p = parse_.parse(path, &scratch);
        if (tsv) {
            try out.print("{s}\t{t}\t{s}\t{?d}\t{?d}\t{?d}\t{?d}\t{?d}\t{s}\t{s}{s}{s}\n", .{
                path,                     p.kind,       p.title,           p.year,       p.season, p.episode, p.last_episode, p.part, p.edition orelse "",
                p.tmdb orelse "", p.imdb orelse "", p.tvdb orelse "",
            });
            continue;
        }
        counts.getPtr(p.kind).* += 1;
        if (p.year == null) no_year += 1;
        const key = try std.fmt.allocPrint(arena, "{s} ({?d})", .{ p.title, p.year });
        switch (p.kind) {
            .episode => try series.put(arena, key, {}),
            .movie => try movies.put(arena, key, {}),
            .extra => {},
        }
    }
    if (tsv) return;
    const us = start.durationTo(Io.Timestamp.now(io, .awake)).toMicroseconds();
    try out.print("{d} video files in {d} ms ({d:.2} µs each): {d} movies ({d} distinct), {d} episodes of {d} series, {d} extras; {d} without a year\n", .{
        files,                         @divTrunc(us, 1000), @as(f64, @floatFromInt(us)) / @as(f64, @floatFromInt(files)),
        counts.get(.movie),            movies.count(),      counts.get(.episode),
        series.count(),                counts.get(.extra),  no_year,
    });
}
