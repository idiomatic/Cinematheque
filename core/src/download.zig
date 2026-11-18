//! Downloads: a title's, a season's, or an item's files, fetched into a
//! directory of this device's under their paths in the repository that held
//! them, so the directory, crawled or served, names them as the library did.
//!
//! Each file comes from its copies in the order copy racing gives (see
//! race.zig), the next tried when one fails. A file is fetched into
//! `<path>.part`, resumed by a range request where an earlier attempt left
//! off, and renamed once whole; one already there at its size is kept.
//!
//! A player's downloads (`reconcile`) go further: its directory is a
//! repository of its own, `managed`, which it serves and no one crawls;
//! each file fetched is recorded as its holding on the very rendition it
//! came from, so peers see it and copy racing can use it. What it keeps is
//! this device's (in `local`): titles, seasons, and items wanted, and per
//! series, the next N episodes after where this user is ("keep"); with
//! `drop_watched`, a kept series' watched episode is deleted once another
//! repository is confirmed to hold it (same rendition and size, not
//! absent), else such episodes are deleted only as space is needed. It
//! keeps `floor_bytes` free.

const std = @import("std");
const Io = std.Io;
const library = @import("library.zig");
const race = @import("race.zig");
const art = @import("art.zig");
const Replica = @import("replica.zig").Replica;

/// One file to fetch.
pub const File = struct {
    /// The item's key (e.g., `t/s/firefly/-/e/s01e02`).
    item: []const u8,
    rendition: []const u8,
    /// Where it goes, relative to the directory: its path in the repository.
    path: []const u8,
    size: u64,
    /// Its copies' URLs, those not under an absent directory first.
    urls: []const []const u8,
};

/// The files of `key`: a title (`t/m/alien/1979`), a season of a series
/// (`t/s/firefly/-/e/s01`), or an item (`t/s/firefly/-/e/s01e02`). Each
/// item's file is of `rendition` if given (items without it are left out),
/// else of the rendition most of them have, so a season comes alike.
pub fn plan(replica: *Replica, arena: std.mem.Allocator, key: []const u8, rendition: ?[]const u8) ![]File {
    const title_end = titleEnd(key) orelse return error.NotFound;
    const d = try library.detail(replica, arena, key[0..title_end]) orelse return error.NotFound;
    const below = if (title_end < key.len) key[title_end + 1 ..] else "";
    // Copies come from anywhere but a device's downloads, which a player
    // knows it has (and another can't be sure is awake).
    var bases: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (try library.repositories(replica, arena)) |rp| if (!rp.managed) try bases.put(arena, try arena.dupe(u8, &rp.id), rp.url);

    var items: std.ArrayList(library.Item) = .empty;
    for (d.items.items) |item| if (within(item.key, below)) try items.append(arena, item);
    if (items.items.len == 0) return error.NotFound;
    const label = rendition orelse commonest(items.items);

    var files: std.ArrayList(File) = .empty;
    for (items.items) |item| {
        const r = for (item.renditions.items) |r| {
            if (std.mem.eql(u8, r.label, label)) break r;
        } else if (rendition != null) continue else item.renditions.items[0];
        var urls: std.ArrayList([]const u8) = .empty;
        var path: ?[]const u8 = null;
        var size: u64 = 0;
        for ([_]bool{ false, true }) |absent| for (r.holdings.items) |h| {
            if (h.absent != absent) continue;
            const base = bases.get(h.repository) orelse continue;
            if (!safe(h.path)) continue;
            try urls.append(arena, try art.fileUrl(arena, base, h.path));
            if (path == null) {
                path = h.path;
                size = h.size;
            }
        };
        try files.append(arena, .{
            .item = try std.fmt.allocPrint(arena, "{s}/{s}", .{ d.key, item.key }),
            .rendition = r.label,
            .path = path orelse continue,
            .size = size,
            .urls = urls.items,
        });
    }
    return files.items;
}

/// Where a title's key ends within `key` (its first four segments).
fn titleEnd(key: []const u8) ?usize {
    var slashes: usize = 0;
    for (key, 0..) |ch, i| if (ch == '/') {
        slashes += 1;
        if (slashes == 4) return i;
    };
    return if (slashes == 3) key.len else null;
}

/// Whether an item's key (below its title's) is `below`, or within it: a
/// season (`e/s01`) holds its episodes (`e/s01e02`) and their versions.
fn within(item: []const u8, below: []const u8) bool {
    if (below.len == 0) return true;
    if (!std.mem.startsWith(u8, item, below)) return false;
    if (item.len == below.len) return true;
    const next = item[below.len];
    return next == '/' or (std.mem.startsWith(u8, below, "e/s") and std.mem.indexOfAny(u8, below[3..], "e-") == null and (next == 'e' or next == '-'));
}

/// The rendition most of `items` have, the first such if tied.
fn commonest(items: []const library.Item) []const u8 {
    var best: []const u8 = items[0].renditions.items[0].label;
    var best_count: usize = 0;
    for (items) |item| for (item.renditions.items) |r| {
        var count: usize = 0;
        for (items) |other| for (other.renditions.items) |o| {
            if (std.mem.eql(u8, o.label, r.label)) count += 1;
        };
        if (count > best_count) {
            best = r.label;
            best_count = count;
        }
    };
    return best;
}

/// Whether a repository's path stays within the directory it's fetched to,
/// since a path comes from whichever member's device crawled it.
fn safe(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |s| {
        if (s.len == 0 or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return false;
    }
    return true;
}

/// How far a file has come, told as it does.
pub const Progress = struct {
    context: *anyopaque,
    report: *const fn (context: *anyopaque, done: u64, total: u64) void,
};

pub const Fetched = enum { fetched, kept };

/// Fetches `file` into `dir`, from the first of its copies (raced) that
/// gives all of it.
pub fn fetch(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, client: *std.http.Client, memory: *race.Memory, dir: Io.Dir, file: File, now_ms: u64, progress: ?Progress) !Fetched {
    if (dir.statFile(io, file.path, .{})) |st| {
        if (st.size == file.size) return .kept;
    } else |_| {}
    if (std.fs.path.dirname(file.path)) |parent| try dir.createDirPath(io, parent);
    const part = try std.fmt.allocPrint(arena, "{s}.part", .{file.path});
    var last: anyerror = error.NoCopies;
    for (try race.order(io, gpa, arena, memory, file.urls, now_ms)) |u| {
        fetchFrom(io, client, dir, part, u, file.size, progress) catch |err| {
            if (err == error.Canceled) return err;
            last = err;
            try memory.lost(io, gpa, u, now_ms);
            continue;
        };
        try dir.rename(part, dir, file.path, io);
        return .fetched;
    }
    return last;
}

/// Fetches `url` into `part`, resuming where it leaves off.
fn fetchFrom(io: Io, client: *std.http.Client, dir: Io.Dir, part: []const u8, url: []const u8, size: u64, progress: ?Progress) !void {
    const out = try dir.createFile(io, part, .{ .truncate = false });
    defer out.close(io);
    var have = try out.length(io);
    if (have > size) {
        try out.setLength(io, 0);
        have = 0;
    }
    if (have < size) {
        var range_buf: [64]u8 = undefined;
        const range = try std.fmt.bufPrint(&range_buf, "bytes={d}-", .{have});
        var request = try client.request(.GET, try std.Uri.parse(url), .{
            // Bytes as stored, so lengths and ranges are the file's.
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
            .extra_headers = if (have > 0) &.{.{ .name = "range", .value = range }} else &.{},
        });
        defer request.deinit();
        try request.sendBodiless();
        var response = try request.receiveHead(&.{});
        switch (response.head.status) {
            .partial_content => {},
            // Whole: from the beginning, then.
            .ok => if (have > 0) {
                try out.setLength(io, 0);
                have = 0;
            },
            .not_found => return error.NotFound,
            else => return error.BadStatus,
        }
        var transfer: [64 * 1024]u8 = undefined;
        const body = response.reader(&transfer);
        var write_buf: [64 * 1024]u8 = undefined;
        var writer = out.writer(io, &write_buf);
        try writer.seekTo(have);
        // Never past the file's size, whatever the server sends.
        while (have < size) {
            const n = body.stream(&writer.interface, .limited(@min(size - have, 1 << 20))) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
                error.WriteFailed => return writer.err orelse error.WriteFailed,
            };
            if (n == 0) break;
            have += n;
            if (progress) |p| p.report(p.context, have, size);
        }
        try writer.interface.flush();
    }
    if (try out.length(io) != size) return error.Truncated;
}

// A player's downloads.

const dir_key = "downloads/dir";
const repo_key = "downloads/repo";
const drop_key = "downloads/drop-watched";
const want_prefix = "downloads/want/";
const keep_prefix = "downloads/keep/";

/// Free space a download never goes below.
pub const floor_bytes: u64 = 20_000_000_000;

/// `floor_bytes`, unless `CINEMATHEQUE_DOWNLOAD_FLOOR` gives another (in
/// bytes), for testing on a small disk, such as a VM's.
pub fn floor() u64 {
    const text = std.c.getenv("CINEMATHEQUE_DOWNLOAD_FLOOR") orelse return floor_bytes;
    return std.fmt.parseInt(u64, std.mem.span(text), 10) catch floor_bytes;
}

pub const Settings = struct {
    dir: []const u8,
    repo: library.Repository,
    drop_watched: bool,
};

/// Sets where this device keeps downloads (`dir`), the URL it serves them
/// at (made a repository, `managed`, if it isn't one), and whether a kept
/// series' watched episodes go at once.
pub fn configure(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, dir: []const u8, served_at: []const u8, drop_watched: bool) !void {
    var typed: std.ArrayList(u8) = .empty;
    try @import("url.zig").escape(arena, &typed, served_at);
    if (!std.mem.endsWith(u8, typed.items, "/")) try typed.append(arena, '/');
    const repo = library.findRepository(replica, arena, typed.items) catch |err| switch (err) {
        error.NoSuchRepository => blk: {
            _ = try library.addRepository(replica, wall_ms, typed.items, .{});
            break :blk try library.findRepository(replica, arena, typed.items);
        },
        else => |e| return e,
    };
    if (!repo.managed) try replica.write(wall_ms, try std.fmt.allocPrint(arena, "r/{s}", .{&repo.id}), "managed", "1");
    try replica.setLocal(dir_key, dir);
    try replica.setLocal(repo_key, typed.items);
    try replica.setLocal(drop_key, if (drop_watched) "1" else "");
}

/// This device's downloads' settings, if configured.
pub fn settings(replica: *Replica, arena: std.mem.Allocator) !?Settings {
    const dir = try replica.local(arena, dir_key) orelse return null;
    const served_at = try replica.local(arena, repo_key) orelse return null;
    const repo = library.findRepository(replica, arena, served_at) catch return null;
    const drop = try replica.local(arena, drop_key) orelse "";
    return .{ .dir = dir, .repo = repo, .drop_watched = drop.len > 0 };
}

pub const Want = struct { key: []const u8, rendition: []const u8 };

/// Wants a title's, season's, or item's files kept (see `plan`), in a
/// rendition (empty for the one most of its items have).
pub fn want(replica: *Replica, arena: std.mem.Allocator, key: []const u8, rendition: []const u8) !void {
    try replica.setLocal(try std.fmt.allocPrint(arena, "{s}{s}", .{ want_prefix, key }), rendition);
}

pub fn wants(replica: *Replica, arena: std.mem.Allocator) ![]Want {
    var out: std.ArrayList(Want) = .empty;
    for (try replica.localKeys(arena, want_prefix)) |k|
        try out.append(arena, .{ .key = k[want_prefix.len..], .rendition = try replica.local(arena, k) orelse "" });
    return out.items;
}

pub const Keep = struct { title: []const u8, episodes: u32 };

/// Keeps a series' next `episodes` downloaded (0: none).
pub fn setKeep(replica: *Replica, arena: std.mem.Allocator, title: []const u8, episodes: u32) !void {
    const k = try std.fmt.allocPrint(arena, "{s}{s}", .{ keep_prefix, title });
    if (episodes == 0) return replica.removeLocal(k);
    try replica.setLocal(k, try std.fmt.allocPrint(arena, "{d}", .{episodes}));
}

pub fn keeps(replica: *Replica, arena: std.mem.Allocator) ![]Keep {
    var out: std.ArrayList(Keep) = .empty;
    for (try replica.localKeys(arena, keep_prefix)) |k| {
        const n = std.fmt.parseInt(u32, try replica.local(arena, k) orelse "0", 10) catch 0;
        if (n > 0) try out.append(arena, .{ .title = k[keep_prefix.len..], .episodes = n });
    }
    return out.items;
}

/// A file this device's downloads hold.
pub const Held = struct {
    /// Its rendition's key (`<item>/r/<rendition>`).
    key: []const u8,
    item: []const u8,
    path: []const u8,
    size: u64,
};

pub fn held(replica: *Replica, arena: std.mem.Allocator, repo: library.Repository) ![]Held {
    var out: std.ArrayList(Held) = .empty;
    const s = try replica.db.prepare("SELECT key, value FROM winners WHERE field = ?1 AND length(value) > 0 ORDER BY key");
    defer s.finalize();
    try s.bindText(1, try std.fmt.allocPrint(arena, "held:{s}", .{&repo.id}));
    while (try s.step()) {
        const key = try arena.dupe(u8, s.blob(0));
        const r = std.mem.lastIndexOf(u8, key, "/r/") orelse continue;
        var parts = std.mem.splitScalar(u8, s.blob(1), '\t');
        const path = try arena.dupe(u8, parts.first());
        const size = std.fmt.parseInt(u64, parts.next() orelse "0", 10) catch 0;
        try out.append(arena, .{ .key = key, .item = key[0..r], .path = path, .size = size });
    }
    return out.items;
}

/// Whether another repository (not a device's downloads) holds `h`'s file
/// alike, its rendition and size, and isn't absent: so deleting it loses
/// nothing.
fn confirmed(replica: *Replica, repos: []const library.Repository, absences: *const library.Absences, h: Held) !bool {
    const s = try replica.db.prepare("SELECT field, value FROM winners WHERE key = ?1 AND field >= 'held:' AND field < 'held;' AND length(value) > 0");
    defer s.finalize();
    try s.bindText(1, h.key);
    while (try s.step()) {
        const repo_id = s.blob(0)["held:".len..];
        const repo = for (repos) |rp| {
            if (std.mem.eql(u8, &rp.id, repo_id)) break rp;
        } else continue;
        if (repo.managed or absences.has(repo_id, s.blob(1))) continue;
        var parts = std.mem.splitScalar(u8, s.blob(1), '\t');
        _ = parts.first();
        if ((std.fmt.parseInt(u64, parts.next() orelse "", 10) catch continue) == h.size) return true;
    }
    return false;
}

/// The item keys (below the title's) of a series' next `n` episodes for
/// this user: from the latest in progress, else the first unwatched, the
/// unwatched among those after it; specials aside.
pub fn ahead(replica: *Replica, arena: std.mem.Allocator, title: []const u8, n: u32) ![]const []const u8 {
    const d = try library.detail(replica, arena, title) orelse return &.{};
    const Episode = struct { item: library.Item, season: u32, number: u32 };
    var episodes: std.ArrayList(Episode) = .empty;
    for (d.items.items) |item| {
        const code = episodeCode(item.key) orelse continue;
        if (code[0] == 0) continue;
        try episodes.append(arena, .{ .item = item, .season = code[0], .number = code[1] });
    }
    std.mem.sort(Episode, episodes.items, {}, struct {
        fn lt(_: void, a: Episode, b: Episode) bool {
            return if (a.season != b.season) a.season < b.season else if (a.number != b.number) a.number < b.number else std.mem.lessThan(u8, a.item.key, b.item.key);
        }
    }.lt);
    var start: ?usize = null;
    for (episodes.items, 0..) |e, i| if (e.item.playhead.position_ms > 0 and !e.item.playhead.watched) {
        start = i;
    };
    if (start == null) for (episodes.items, 0..) |e, i| if (!e.item.playhead.watched) {
        start = i;
        break;
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (episodes.items[start orelse return &.{}..]) |e| {
        if (out.items.len == n) break;
        if (!e.item.playhead.watched) try out.append(arena, e.item.key);
    }
    return out.items;
}

/// An item key's season and episode (`e/s03e17...`), if an episode's.
fn episodeCode(key: []const u8) ?[2]u32 {
    if (!std.mem.startsWith(u8, key, "e/s")) return null;
    const rest = key[3..];
    const e = std.mem.indexOfScalar(u8, rest, 'e') orelse return null;
    const season = std.fmt.parseInt(u32, rest[0..e], 10) catch return null;
    var end = e + 1;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    const number = std.fmt.parseInt(u32, rest[e + 1 .. end], 10) catch return null;
    return .{ season, number };
}

/// Free bytes for this user on the volume holding `dir`, if the platform
/// tells.
pub fn freeBytes(arena: std.mem.Allocator, dir: []const u8) ?u64 {
    if (@import("builtin").os.tag != .macos) return null;
    const path = arena.dupeSentinel(u8, dir, 0) catch return null;
    var st: Statfs = undefined;
    if (statfs(path.ptr, &st) != 0) return null;
    return st.f_bavail * st.f_bsize;
}

/// macOS's `struct statfs` (64-bit inodes).
const Statfs = extern struct {
    f_bsize: u32,
    f_iosize: i32,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_owner: u32,
    f_type: u32,
    f_flags: u32,
    f_fssubtype: u32,
    f_fstypename: [16]u8,
    f_mntonname: [1024]u8,
    f_mntfromname: [1024]u8,
    f_flags_ext: u32,
    f_reserved: [7]u32,
};
const statfs = @extern(*const fn ([*:0]const u8, *Statfs) callconv(.c) c_int, .{
    .name = if (@import("builtin").cpu.arch == .x86_64) "statfs$INODE64" else "statfs",
});

/// What reconciling did.
pub const Reconciled = struct {
    fetched: usize = 0,
    kept: usize = 0,
    deleted: usize = 0,
    failed: usize = 0,
    /// Files left for want of space (keeping `floor_bytes` free).
    no_room: usize = 0,
    /// Why the last file that failed did.
    @"error": ?[]const u8 = null,
};

/// How far reconciling has come, in megabytes.
pub const Counter = struct {
    done: *std.atomic.Value(u32),
    total: *std.atomic.Value(u32),
};

/// Brings this device's downloads in line with what it keeps: forgets
/// holdings whose files are gone (deleted by hand, or a directory changed),
/// deletes watched episodes of kept series as `Settings.drop_watched` and
/// space call for, and fetches what's wanted and the next episodes kept,
/// recording each file as fetched. `writer`, if given, is held around each
/// write, as other connections' writers are.
pub fn reconcile(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, client: *std.http.Client, memory: *race.Memory, replica: *Replica, writer: ?*Io.Mutex, wall_ms: u64, counter: ?Counter) !Reconciled {
    const s = try settings(replica, arena) orelse return error.NoDownloads;
    var out: Reconciled = .{};
    try Io.Dir.cwd().createDirPath(io, s.dir);
    var dir = try Io.Dir.cwd().openDir(io, s.dir, .{});
    defer dir.close(io);

    // Gone by hand: forgotten.
    for (try held(replica, arena, s.repo)) |h| {
        const there = if (dir.statFile(io, h.path, .{})) |st| st.size == h.size else |_| false;
        if (!there) try locked(writer, io, replica, wall_ms, h.key, s.repo, "");
    }

    // What's kept: wanted, and kept series' next episodes.
    var files: std.ArrayList(File) = .empty;
    var keys: std.StringHashMapUnmanaged(void) = .empty;
    for (try wants(replica, arena)) |w| {
        const planned = plan(replica, arena, w.key, if (w.rendition.len > 0) w.rendition else null) catch |err| switch (err) {
            error.NotFound => continue,
            else => |e| return e,
        };
        for (planned) |f| if (!keys.contains(f.item)) {
            try keys.put(arena, f.item, {});
            try files.append(arena, f);
        };
    }
    const kept_series = try keeps(replica, arena);
    for (kept_series) |k| for (try ahead(replica, arena, k.title, k.episodes)) |item| {
        const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ k.title, item });
        if (keys.contains(full)) continue;
        const planned = plan(replica, arena, full, null) catch continue;
        for (planned) |f| {
            try keys.put(arena, f.item, {});
            try files.append(arena, f);
        }
    };

    // Watched episodes of kept series, confirmed held elsewhere, oldest
    // (first in order) first: deleted now, or as space is needed.
    const repos = try library.repositories(replica, arena);
    const absences = try library.Absences.load(replica, arena);
    var spare: std.ArrayList(Held) = .empty;
    for (try held(replica, arena, s.repo)) |h| {
        if (keys.contains(h.item)) continue;
        const series = for (kept_series) |k| {
            if (std.mem.startsWith(u8, h.item, k.title) and h.item.len > k.title.len and h.item[k.title.len] == '/') break k;
        } else continue;
        _ = series;
        if (!try watched(replica, arena, h.item)) continue;
        if (!try confirmed(replica, repos, &absences, h)) continue;
        try spare.append(arena, h);
    }
    var next_spare: usize = 0;
    if (s.drop_watched) {
        for (spare.items) |h| try delete(io, dir, replica, writer, wall_ms, s.repo, h, &out);
        next_spare = spare.items.len;
    }

    // Fetched, keeping the floor free.
    var total_mb: u64 = 0;
    for (files.items) |f| total_mb += f.size / 1_000_000;
    if (counter) |c| {
        c.done.store(0, .monotonic);
        c.total.store(@intCast(@min(total_mb, std.math.maxInt(u32))), .monotonic);
    }
    for (files.items) |f| {
        defer if (counter) |c| {
            _ = c.done.fetchAdd(@intCast(@min(f.size / 1_000_000, std.math.maxInt(u32))), .monotonic);
        };
        const have = if (dir.statFile(io, f.path, .{})) |st| st.size else |_| 0;
        if (have != f.size) {
            const part = if (dir.statFile(io, try std.fmt.allocPrint(arena, "{s}.part", .{f.path}), .{})) |st| st.size else |_| 0;
            const need = f.size -| part;
            while (freeBytes(arena, s.dir)) |free| {
                if (free >= need + floor()) break;
                if (next_spare == spare.items.len) break;
                try delete(io, dir, replica, writer, wall_ms, s.repo, spare.items[next_spare], &out);
                next_spare += 1;
            }
            if (freeBytes(arena, s.dir)) |free| if (free < need + floor()) {
                out.no_room += 1;
                continue;
            };
        }
        const fetched = fetch(io, gpa, arena, client, memory, dir, f, wall_ms, null) catch |err| {
            if (err == error.Canceled) return err;
            out.failed += 1;
            out.@"error" = @errorName(err);
            continue;
        };
        if (fetched == .fetched) out.fetched += 1 else out.kept += 1;
        const value = try std.fmt.allocPrint(arena, "{s}\t{d}\t{d}", .{ f.path, f.size, @divTrunc(Io.Timestamp.now(io, .real).toMilliseconds(), 1000) });
        try locked(writer, io, replica, wall_ms, try std.fmt.allocPrint(arena, "{s}/r/{s}", .{ f.item, f.rendition }), s.repo, value);
    }
    return out;
}

/// Writes `repo`'s holding of `key` as `value` (empty: none), holding
/// `writer` if given.
fn locked(writer: ?*Io.Mutex, io: Io, replica: *Replica, wall_ms: u64, key: []const u8, repo: library.Repository, value: []const u8) !void {
    if (writer) |w| try w.lock(io);
    defer if (writer) |w| w.unlock(io);
    try replica.refresh();
    var field: [5 + 16]u8 = undefined;
    try replica.write(wall_ms, key, try std.fmt.bufPrint(&field, "held:{s}", .{&repo.id}), value);
}

fn delete(io: Io, dir: Io.Dir, replica: *Replica, writer: ?*Io.Mutex, wall_ms: u64, repo: library.Repository, h: Held, out: *Reconciled) !void {
    dir.deleteFile(io, h.path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    try locked(writer, io, replica, wall_ms, h.key, repo, "");
    out.deleted += 1;
}

fn watched(replica: *Replica, arena: std.mem.Allocator, item: []const u8) !bool {
    const title_end = titleEnd(item) orelse return false;
    for (try library.playheads(replica, arena, item[0..title_end])) |p| {
        if (std.mem.eql(u8, p.item, item)) return p.playhead.watched;
    }
    return false;
}

/// Stops keeping a title's, season's, or item's files: deletes those this
/// device's downloads hold, and forgets wanting them.
pub fn remove(io: Io, arena: std.mem.Allocator, replica: *Replica, writer: ?*Io.Mutex, wall_ms: u64, key: []const u8) !usize {
    const s = try settings(replica, arena) orelse return error.NoDownloads;
    var dir = try Io.Dir.cwd().openDir(io, s.dir, .{});
    defer dir.close(io);
    const title_end = titleEnd(key) orelse return error.NotFound;
    const below = if (title_end < key.len) key[title_end + 1 ..] else "";
    var out: Reconciled = .{};
    for (try held(replica, arena, s.repo)) |h| {
        if (!std.mem.startsWith(u8, h.item, key[0..title_end]) or h.item.len <= title_end or h.item[title_end] != '/') continue;
        if (!within(h.item[title_end + 1 ..], below)) continue;
        try delete(io, dir, replica, writer, wall_ms, s.repo, h, &out);
    }
    for (try replica.localKeys(arena, want_prefix)) |k| {
        const wanted = k[want_prefix.len..];
        if (std.mem.eql(u8, wanted, key) or std.mem.startsWith(u8, wanted, try std.fmt.allocPrint(arena, "{s}/", .{key}))) try replica.removeLocal(k);
    }
    return out.deleted;
}

test "a title's, season's, or item's files, in the rendition most have" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const founder: [32]u8 = (try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(1))).public_key.toBytes();
    var r = try Replica.open(testing.allocator, testing.io, ":memory:", founder, .from(@splat(1)));
    defer r.close();
    const id = try library.addRepository(&r, 1, "http://nas/tv/", .{});
    const held_field = try std.fmt.allocPrint(arena, "held:{s}", .{&id});
    try r.write(2, "t/s/firefly/-", "name", "Firefly");
    try r.write(2, "t/s/firefly/-/e/s01e01/r/720p", held_field, "Firefly/S01E01 720p.mkv\t100\t1");
    try r.write(2, "t/s/firefly/-/e/s01e01/r/1080p", held_field, "Firefly/S01E01 1080p.mkv\t200\t1");
    try r.write(2, "t/s/firefly/-/e/s01e02/r/1080p", held_field, "Firefly/S01E02 1080p.mkv\t200\t1");
    try r.write(2, "t/s/firefly/-/e/s02e01/r/1080p", held_field, "Firefly/S02E01 1080p.mkv\t200\t1");
    try r.write(2, "t/s/firefly/-/e/s01e03/r/1080p", held_field, "../../etc/passwd\t200\t1");

    const season = try plan(&r, arena, "t/s/firefly/-/e/s01", null);
    try testing.expectEqual(2, season.len);
    try testing.expectEqualStrings("Firefly/S01E01 1080p.mkv", season[0].path);
    try testing.expectEqualStrings("http://nas/tv/Firefly/S01E01%201080p.mkv", season[0].urls[0]);
    try testing.expectEqual(3, (try plan(&r, arena, "t/s/firefly/-", null)).len);
    const one = try plan(&r, arena, "t/s/firefly/-/e/s01e01", "720p");
    try testing.expectEqual(1, one.len);
    try testing.expectEqual(100, one[0].size);
    try testing.expectEqual(1, (try plan(&r, arena, "t/s/firefly/-", "720p")).len);
    try testing.expectError(error.NotFound, plan(&r, arena, "t/s/serenity/2005", null));
}

test "fetches a file, resuming a part, and keeps one whole" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = try arena.alloc(u8, 10_000);
    for (content, 0..) |*b, i| b.* = '0' + @as(u8, @intCast(i % 10));
    try tmp.dir.createDirPath(io, "media/Alien (1979)");
    try tmp.dir.writeFile(io, .{ .sub_path = "media/Alien (1979)/Alien (1979).mp4", .data = content });
    const media = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/media", .{tmp.sub_path});

    var server: @import("host.zig").Host = .{ .io = io, .gpa = gpa, .options = .{ .port = 0, .mounts = &.{.{ .path = media, .index = false }} } };
    try server.start();
    defer server.stop();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var memory: race.Memory = .{};
    defer memory.deinit(gpa);
    const live = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/Alien%20(1979)/Alien%20(1979).mp4", .{server.port});
    const file: File = .{ .item = "t/m/alien/1979/v/-", .rendition = "-", .path = "Alien (1979)/Alien (1979).mp4", .size = content.len, .urls = &.{ "http://127.0.0.1:1/gone.mp4", live } };

    try tmp.dir.createDirPath(io, "out/Alien (1979)");
    var out = try tmp.dir.openDir(io, "out", .{});
    defer out.close(io);
    // As an attempt cut short would leave it.
    try out.writeFile(io, .{ .sub_path = "Alien (1979)/Alien (1979).mp4.part", .data = content[0..1234] });
    try std.testing.expectEqual(.fetched, try fetch(io, gpa, arena, &client, &memory, out, file, 1000, null));
    const got = try out.readFileAlloc(io, file.path, arena, .limited(1 << 20));
    try std.testing.expectEqualStrings(content, got);
    try std.testing.expectEqual(.kept, try fetch(io, gpa, arena, &client, &memory, out, file, 1000, null));
}

test "reconciling keeps what's wanted and the next episodes, and drops watched duplicates" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    // A NAS of small, real files: a movie and four episodes.
    const paths = [_][]const u8{ "Alien (1979).mp4", "Firefly/S01E01.mp4", "Firefly/S01E02.mp4", "Firefly/S01E03.mp4", "Firefly/S01E04.mp4" };
    try tmp.dir.createDirPath(io, "nas/Firefly");
    for (paths, 0..) |p, i| try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "nas/{s}", .{p}), .data = try arena.alloc(u8, 1000 + i) });
    var server: @import("host.zig").Host = .{ .io = io, .gpa = gpa, .options = .{ .port = 0, .mounts = &.{.{ .path = try std.fmt.allocPrint(arena, "{s}/nas", .{base}), .index = false }} } };
    try server.start();
    defer server.stop();

    const founder: [32]u8 = (try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(1))).public_key.toBytes();
    var r = try Replica.open(gpa, io, ":memory:", founder, .from(@splat(1)));
    defer r.close();
    const nas = try library.addRepository(&r, 1, try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/", .{server.port}), .{});
    const nas_field = try std.fmt.allocPrint(arena, "held:{s}", .{&nas});
    const keys = [_][]const u8{ "t/m/alien/1979/v/-", "t/s/firefly/-/e/s01e01", "t/s/firefly/-/e/s01e02", "t/s/firefly/-/e/s01e03", "t/s/firefly/-/e/s01e04" };
    try r.write(2, "t/m/alien/1979", "name", "Alien");
    try r.write(2, "t/s/firefly/-", "name", "Firefly");
    for (keys, paths, 0..) |k, p, i|
        try r.write(2, try std.fmt.allocPrint(arena, "{s}/r/-", .{k}), nas_field, try std.fmt.allocPrint(arena, "{s}\t{d}\t1", .{ p, 1000 + i }));

    const downloads = try std.fmt.allocPrint(arena, "{s}/downloads", .{base});
    try configure(&r, arena, 3, downloads, "http://hal.local:8008/downloads/", false);
    const s = (try settings(&r, arena)).?;
    try std.testing.expect(s.repo.managed);
    try want(&r, arena, "t/m/alien/1979", "");
    try setKeep(&r, arena, "t/s/firefly/-", 2);
    // Episode 1 watched: 2 and 3 are next.
    try library.setWatched(&r, arena, 4, keys[1], true);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var memory: race.Memory = .{};
    defer memory.deinit(gpa);
    var done = try reconcile(io, gpa, arena, &client, &memory, &r, null, 5, null);
    try std.testing.expectEqual(3, done.fetched);
    var holding = try held(&r, arena, s.repo);
    try std.testing.expectEqual(3, holding.len);
    try std.testing.expectEqualStrings("t/m/alien/1979/v/-", holding[0].item);
    try std.testing.expectEqualStrings("t/s/firefly/-/e/s01e02", holding[1].item);

    // Episode 2 watched: 4 comes; 2 stays (it's kept until space is needed),
    // then goes once watched episodes are dropped at once.
    try library.setWatched(&r, arena, 6, keys[2], true);
    done = try reconcile(io, gpa, arena, &client, &memory, &r, null, 7, null);
    try std.testing.expectEqual(1, done.fetched);
    try std.testing.expectEqual(0, done.deleted);
    try configure(&r, arena, 8, downloads, "http://hal.local:8008/downloads/", true);
    done = try reconcile(io, gpa, arena, &client, &memory, &r, null, 9, null);
    try std.testing.expectEqual(1, done.deleted);
    holding = try held(&r, arena, s.repo);
    try std.testing.expectEqual(3, holding.len);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "downloads/Firefly/S01E02.mp4", .{}));

    // Deleted by hand: forgotten. Removed: deleted, and no longer wanted.
    try tmp.dir.deleteFile(io, "downloads/Firefly/S01E04.mp4");
    try setKeep(&r, arena, "t/s/firefly/-", 0);
    _ = try reconcile(io, gpa, arena, &client, &memory, &r, null, 10, null);
    try std.testing.expectEqual(2, (try held(&r, arena, s.repo)).len);
    try std.testing.expectEqual(1, try remove(io, arena, &r, null, 11, "t/m/alien/1979"));
    try std.testing.expectEqual(0, (try wants(&r, arena)).len);
    try std.testing.expectEqual(1, (try held(&r, arena, s.repo)).len);
}
