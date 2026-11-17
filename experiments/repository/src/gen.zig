//! Generates a media tree at Cinematheque's scale, named the way Plex and
//! Jellyfin expect, with sparse files so sizes cost no disk space.

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

/// Changes a generated tree as a library changes, and logs the truth as
/// `old<TAB>new` lines (`-` for none): renames 500 episodes in place, moves
/// 100 movie folders into a collection, deletes 100 episodes, and adds 100
/// files. Returns the number of changes.
pub fn mutate(io: Io, gpa: std.mem.Allocator, root_path: []const u8, log_path: []const u8) !usize {
    const cwd = Io.Dir.cwd();
    var root = try cwd.openDir(io, root_path, .{ .iterate = true });
    defer root.close(io);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var episodes: std.ArrayList([]const u8) = .empty;
    var movies: std.ArrayList([]const u8) = .empty;
    var walker = try root.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and std.mem.startsWith(u8, entry.path, "TV/")) try episodes.append(arena, try arena.dupe(u8, entry.path));
        if (entry.kind == .directory and std.mem.startsWith(u8, entry.path, "Movies/") and
            std.mem.count(u8, entry.path, "/") == 1) try movies.append(arena, try arena.dupe(u8, entry.path));
    }
    var prng = std.Random.DefaultPrng.init(11);
    const random = prng.random();
    random.shuffle([]const u8, episodes.items);
    random.shuffle([]const u8, movies.items);

    var log: std.ArrayList(u8) = .empty;
    var changes: usize = 0;
    // Rename episodes in place.
    for (episodes.items[0..500]) |old| {
        const dash = std.mem.lastIndexOf(u8, old, " - ").?;
        const new = try std.fmt.allocPrint(arena, "{s} - Retitled.mkv", .{old[0..dash]});
        try root.rename(old, root, new, io);
        try log.print(arena, "{s}\t{s}\n", .{ old, new });
        changes += 1;
    }
    // Move movie folders into a collection.
    try root.createDirPath(io, "Movies/Collection");
    for (movies.items[0..100]) |old_dir| {
        const name = old_dir["Movies/".len..];
        const new_dir = try std.fmt.allocPrint(arena, "Movies/Collection/{s}", .{name});
        try root.rename(old_dir, root, new_dir, io);
        var dir = try root.openDir(io, new_dir, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            try log.print(arena, "{s}/{s}\t{s}/{s}\n", .{ old_dir, entry.name, new_dir, entry.name });
            changes += 1;
        }
    }
    // Delete episodes.
    for (episodes.items[500..600]) |old| {
        try root.deleteFile(io, old);
        try log.print(arena, "{s}\t-\n", .{old});
        changes += 1;
    }
    // Add files beside other episodes.
    for (episodes.items[600..700], 0..) |beside, i| {
        const new = try std.fmt.allocPrint(arena, "{s}/Bonus {d}.mkv", .{ std.fs.path.dirname(beside).?, i });
        try sparse(io, root, new, random.intRangeAtMost(u64, 200 << 20, 4 << 30));
        try log.print(arena, "-\t{s}\n", .{new});
        changes += 1;
    }
    try cwd.writeFile(io, .{ .sub_path = log_path, .data = log.items });
    return changes;
}
