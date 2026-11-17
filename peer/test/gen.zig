//! Generates a test repository: a media tree at Cinematheque's scale, or a
//! fraction of it, named the way Plex and Jellyfin expect, with sparse files
//! so sizes cost no disk space.
//!
//!   gen DIR [DIVISOR]

const std = @import("std");
const Io = std.Io;

pub const Scale = struct {
    movies: u32 = 4000,
    series: u32 = 500,
    seasons: u32 = 8,
    episodes: u32 = 24,
};

/// Names that need escaping or are long, mixed among plain ones.
const awkward = [_][]const u8{
    "Amélie",
    "Ocean's Eleven",
    "Crouching Tiger, Hidden Dragon & Friends",
    "100% Wolf",
    "What's Eating Gilbert Grape? A Very Long Title That Runs Past Fifty Bytes",
    "千と千尋の神隠し",
    "Léon #1",
};

pub fn generate(io: Io, root_path: []const u8, scale: Scale) !usize {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, root_path);
    var root = try cwd.openDir(io, root_path, .{});
    defer root.close(io);
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    var path: [512]u8 = undefined;
    var name: [256]u8 = undefined;
    var files: usize = 0;

    for (0..scale.movies) |m| {
        const title = try titleName(&name, "Movie", m);
        const year = 1920 + m % 100;
        const dir = try std.fmt.bufPrint(&path, "Movies/{s} ({d})", .{ title, year });
        try root.createDirPath(io, dir);
        const file = try std.fmt.bufPrint(path[dir.len..], "/{s} ({d}).mkv", .{ title, year });
        try sparse(io, root, path[0 .. dir.len + file.len], random.intRangeAtMost(u64, 1 << 30, 40 << 30));
        files += 1;
    }
    for (0..scale.series) |s| {
        const title = try titleName(&name, "Series", s);
        const year = 1950 + s % 75;
        for (1..scale.seasons + 1) |season| {
            const dir = try std.fmt.bufPrint(&path, "TV/{s} ({d})/Season {d:0>2}", .{ title, year, season });
            try root.createDirPath(io, dir);
            for (1..scale.episodes + 1) |episode| {
                const file = try std.fmt.bufPrint(path[dir.len..], "/{s} - S{d:0>2}E{d:0>2} - Episode {d}.mkv", .{ title, season, episode, episode });
                try sparse(io, root, path[0 .. dir.len + file.len], random.intRangeAtMost(u64, 200 << 20, 4 << 30));
                files += 1;
            }
        }
    }
    return files;
}

fn titleName(buf: []u8, kind: []const u8, i: usize) ![]const u8 {
    return if (i % 50 == 0)
        std.fmt.bufPrint(buf, "{s} {d}", .{ awkward[(i / 50) % awkward.len], i })
    else
        std.fmt.bufPrint(buf, "{s} {d:0>4}", .{ kind, i });
}

fn sparse(io: Io, root: Io.Dir, sub_path: []const u8, size: u64) !void {
    const file = try root.createFile(io, sub_path, .{});
    defer file.close(io);
    try file.setLength(io, size);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.log.err("usage: gen DIR [DIVISOR]", .{});
        std.process.exit(2);
    }
    const divisor = if (args.len > 2) try std.fmt.parseInt(u32, args[2], 10) else 1;
    _ = try generate(init.io, args[1], .{ .movies = 4000 / divisor, .series = 500 / divisor });
}
