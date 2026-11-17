//! Covers and metadata, for browsing by cover art.
//!
//! Fields, beside the library's (see library.zig):
//! * on a title's key: `art`, its cover; for a series, `art:s01`, `art:s02`,
//!   and so on, its seasons'; and `description`, `genre`, `released`, and
//!   `network`.
//! * on an item's key: `title` (an episode's), `description`, and
//!   `duration` (milliseconds).
//!
//! A cover is a byte range of a file in a repository, `<repository> TAB
//! <path> TAB <offset> TAB <length> TAB <stamp>`, where the stamp is the
//! file's size and modification time, so a cover is found again only when
//! its file changes. A cover is a sidecar image beside the video, by Plex,
//! Jellyfin, and Kodi convention, or else the one an MP4 embeds. Images
//! don't replicate: players fetch them from repositories by range request.

const std = @import("std");
const Io = std.Io;
const Replica = @import("replica.zig").Replica;
const library = @import("library.zig");
const naming = @import("naming.zig");
const crawl = @import("crawl.zig");
const mp4 = @import("mp4.zig");
const url = @import("url.zig");

pub const Cover = struct {
    repository: []const u8,
    path: []const u8,
    offset: u64,
    length: u64,
    stamp: []const u8,

    pub fn parse(value: []const u8) ?Cover {
        var parts = std.mem.splitScalar(u8, value, '\t');
        const repository = parts.next() orelse return null;
        const path = parts.next() orelse return null;
        const offset = std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch return null;
        const length = std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch return null;
        return .{ .repository = repository, .path = path, .offset = offset, .length = length, .stamp = parts.rest() };
    }

    fn format(c: Cover, arena: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(arena, "{s}\t{s}\t{d}\t{d}\t{s}", .{ c.repository, c.path, c.offset, c.length, c.stamp });
    }
};

/// A file's URL in its repository, ready to fetch.
pub fn fileUrl(arena: std.mem.Allocator, base: []const u8, path: []const u8) ![]const u8 {
    var target: std.ArrayList(u8) = .empty;
    try target.appendSlice(arena, base);
    var segments = std.mem.splitScalar(u8, path, '/');
    var first = true;
    while (segments.next()) |segment| {
        if (!first) try target.append(arena, '/');
        first = false;
        try url.encode(arena, &target, segment);
    }
    return target.items;
}

pub const Stats = struct {
    covers: usize = 0,
    described: usize = 0,
    unchanged: usize = 0,
    failed: usize = 0,
};

/// What describes one movie or season: the file to read, and where its
/// cover and metadata go.
pub const Target = struct {
    title_key: []const u8,
    item_key: []const u8,
    /// `art` or `art:s01`.
    field: []const u8,
    path: []const u8,
    stamp: []const u8,
    episode: u32,
    is_episode: bool,
};

fn isImage(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg") or std.ascii.eqlIgnoreCase(ext, ".png");
}

/// A repository and its crawl's listing.
pub const Crawled = struct {
    repo: library.Repository,
    entries: []const crawl.Entry,
};

const Source = struct { path: []const u8, stamp: []const u8 };

/// Describing one movie or season: its target, and the source to read.
pub const Job = struct {
    target: Target,
    repo: library.Repository,
    sidecar: ?Source,

    /// The file the cover comes from.
    fn source(j: Job) Source {
        return j.sidecar orelse .{ .path = j.target.path, .stamp = j.target.stamp };
    }
};

pub const Plan = struct {
    jobs: []Job,
    unchanged: usize,
};

/// Plans describing the movies and seasons the `crawled` repositories hold:
/// one source for each, keeping the one already described while its file
/// is unchanged, else a sidecar image, else an MP4, else any file; jobs for
/// those to describe, in title order. A title held in several repositories
/// (e.g., one per rendition) is described from one of them.
pub fn plan(replica: *Replica, arena: std.mem.Allocator, crawled: []const Crawled) !Plan {
    var candidates: std.StringArrayHashMapUnmanaged(std.ArrayList(Job)) = .empty;
    for (crawled) |c| {
        const repo = c.repo;
        // Images by their path, lowercased, for sidecars.
        var images: std.StringHashMapUnmanaged(Source) = .empty;
        var targets: std.StringArrayHashMapUnmanaged(Target) = .empty;
        // How many titles each directory holds, so a `poster.jpg` is taken
        // as a movie's only where it's the only one there.
        var titles_in: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)) = .empty;
        const series = try library.seriesByFolder(arena, repo.url, c.entries);
        for (c.entries) |entry| {
            if (entry.is_dir or !std.mem.startsWith(u8, entry.url, repo.url)) continue;
            const rel = url.decode(try arena.dupe(u8, entry.url[repo.url.len..])) catch continue;
            const stamp = try std.fmt.allocPrint(arena, "{d}\t{s}", .{ entry.size, entry.mtime });
            if (isImage(rel)) {
                try images.put(arena, try std.ascii.allocLowerString(arena, rel), .{ .path = rel, .stamp = stamp });
                continue;
            }
            if (!naming.isVideo(rel) or skippedPath(rel, repo.layout.skip)) continue;
            const p = try library.parseFile(arena, rel, &series);
            if (p.kind == .extra or p.title.len == 0) continue;
            const k = try library.keys(arena, p);
            const is_episode = p.kind == .episode;
            if (is_episode and p.season == null) continue;
            const field = if (is_episode) try std.fmt.allocPrint(arena, "art:s{d:0>2}", .{p.season.?}) else "art";
            const id = try std.fmt.allocPrint(arena, "{s}#{s}", .{ k.title, field });
            // A season's first episode; a movie's standard version (its
            // editions after it); then the first file by name.
            const episode: u32 = if (p.episode) |e| e else if (p.edition != null) 1 else 0;
            const gop = try targets.getOrPut(arena, id);
            if (!gop.found_existing or episode < gop.value_ptr.episode or (episode == gop.value_ptr.episode and std.mem.lessThan(u8, rel, gop.value_ptr.path)))
                gop.value_ptr.* = .{ .title_key = k.title, .item_key = k.item, .field = field, .path = rel, .stamp = stamp, .episode = episode, .is_episode = is_episode };
            const dir = std.fs.path.dirname(rel) orelse "";
            const t = try titles_in.getOrPut(arena, dir);
            if (!t.found_existing) t.value_ptr.* = .empty;
            try t.value_ptr.put(arena, k.title, {});
        }
        for (targets.keys(), targets.values()) |id, t| {
            const gop = try candidates.getOrPut(arena, id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, .{ .target = t, .repo = repo, .sidecar = findSidecar(arena, &images, &titles_in, t) catch null });
        }
    }
    var jobs: std.ArrayList(Job) = .empty;
    var unchanged: usize = 0;
    next: for (candidates.values()) |list| {
        const first = list.items[0];
        if (try library.fieldValue(replica, arena, first.target.title_key, first.target.field)) |old| if (Cover.parse(old)) |c| {
            for (list.items) |j| {
                const src = j.source();
                if (std.mem.eql(u8, c.repository, &j.repo.id) and std.mem.eql(u8, c.path, src.path) and std.mem.eql(u8, c.stamp, src.stamp)) {
                    unchanged += 1;
                    continue :next;
                }
            }
        };
        var best = first;
        for (list.items) |j| if (rank(j) > rank(best)) {
            best = j;
        };
        try jobs.append(arena, best);
    }
    std.mem.sort(Job, jobs.items, {}, struct {
        fn less(_: void, a: Job, b: Job) bool {
            const order = std.mem.order(u8, a.target.title_key, b.target.title_key);
            return order == .lt or (order == .eq and std.mem.lessThan(u8, a.target.field, b.target.field));
        }
    }.less);
    return .{ .jobs = jobs.items, .unchanged = unchanged };
}

fn isMp4(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(ext, ".mp4") or std.ascii.eqlIgnoreCase(ext, ".m4v") or std.ascii.eqlIgnoreCase(ext, ".mov");
}

fn rank(j: Job) u8 {
    if (j.sidecar != null) return 2;
    return if (isMp4(j.target.path)) 1 else 0;
}

pub const Write = struct { key: []const u8, field: []const u8, value: []const u8 };

/// Describes one job, appending what it found to `writes`.
fn describeJob(arena: std.mem.Allocator, client: *std.http.Client, job: Job, writes: *std.ArrayList(Write), stats: *Stats) !void {
    const t = job.target;
    const repo = job.repo;
    if (job.sidecar) |s| {
        const size = std.fmt.parseInt(u64, s.stamp[0 .. std.mem.indexOfScalar(u8, s.stamp, '\t') orelse 0], 10) catch 0;
        try writes.append(arena, .{ .key = t.title_key, .field = t.field, .value = try (Cover{ .repository = &repo.id, .path = s.path, .offset = 0, .length = size, .stamp = s.stamp }).format(arena) });
        stats.covers += 1;
    }
    if (!isMp4(t.path)) {
        // Remember the file was looked at, without a cover.
        if (job.sidecar == null)
            try writes.append(arena, .{ .key = t.title_key, .field = t.field, .value = try (Cover{ .repository = &repo.id, .path = t.path, .offset = 0, .length = 0, .stamp = t.stamp }).format(arena) });
        return;
    }
    const info = mp4.read(arena, client, try fileUrl(arena, repo.url, t.path)) catch |err| {
        stats.failed += 1;
        if (unreachable_(err)) return; // to try again next crawl
        // A file that can't be read as an MP4 is remembered as without a
        // cover, so it isn't read again until it changes.
        if (job.sidecar == null)
            try writes.append(arena, .{ .key = t.title_key, .field = t.field, .value = try (Cover{ .repository = &repo.id, .path = t.path, .offset = 0, .length = 0, .stamp = t.stamp }).format(arena) });
        return;
    };
    stats.described += 1;
    if (job.sidecar == null) {
        const c = info.cover orelse mp4.Cover{ .offset = 0, .length = 0, .image = .jpeg };
        if (info.cover != null) stats.covers += 1;
        try writes.append(arena, .{ .key = t.title_key, .field = t.field, .value = try (Cover{ .repository = &repo.id, .path = t.path, .offset = c.offset, .length = c.length, .stamp = t.stamp }).format(arena) });
    }
    try appendInfo(arena, writes, t, info);
}

/// Whether an error is the network's, worth trying again later.
fn unreachable_(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused, error.ConnectionResetByPeer, error.ConnectionTimedOut, error.NetworkUnreachable, error.HostUnreachable, error.TemporaryNameServerFailure, error.UnknownHostName, error.NameServerFailure, error.EndOfStream, error.ReadFailed, error.WriteFailed => true,
        else => false,
    };
}

/// Titles to describe first, such as those on screen; set from any thread.
pub const Priority = struct {
    mutex: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    keys: []const []const u8 = &.{},

    /// Replaces the titles to put first (by title key).
    pub fn set(p: *Priority, io: Io, keys: []const []const u8) !void {
        try p.mutex.lock(io);
        defer p.mutex.unlock(io);
        _ = p.arena.reset(.retain_capacity);
        const copy = try p.arena.allocator().alloc([]const u8, keys.len);
        for (keys, copy) |k, *c| c.* = try p.arena.allocator().dupe(u8, k);
        p.keys = copy;
    }

    pub fn deinit(p: *Priority) void {
        p.arena.deinit();
    }
};

pub const RunOptions = struct {
    workers: usize = 16,
    /// Titles to describe first.
    priority: ?*Priority = null,
    /// Held while writing, if other connections write as this device too.
    writer: ?*Io.Mutex = null,
    /// How many movies and seasons to describe between commits, at most,
    /// and how long, so what's found shows as it's found.
    batch: usize = 24,
    batch_ms: i64 = 750,
};

/// Describes the planned jobs with concurrent workers, committing as it
/// goes, and taking prioritized titles first.
pub fn run(io: Io, replica: *Replica, arena: std.mem.Allocator, client: *std.http.Client, wall_ms: u64, jobs: []const Job, options: RunOptions) !Stats {
    var runner: Runner = .{
        .io = io,
        .replica = replica,
        .arena = arena,
        .client = client,
        .wall_ms = wall_ms,
        .jobs = jobs,
        .done = try arena.alloc(bool, jobs.len),
        .options = options,
        .last_flush = Io.Timestamp.now(io, .awake),
    };
    @memset(runner.done, false);
    for (jobs, 0..) |j, i| {
        const gop = try runner.by_title.getOrPut(arena, j.target.title_key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, i);
    }
    var group: Io.Group = .init;
    for (0..@max(1, @min(options.workers, jobs.len))) |_| try group.concurrent(io, Runner.work, .{&runner});
    try group.await(io);
    try runner.mutex.lock(io);
    defer runner.mutex.unlock(io);
    try runner.flush();
    if (runner.err) |err| return err;
    return runner.stats;
}

const Runner = struct {
    io: Io,
    replica: *Replica,
    arena: std.mem.Allocator,
    client: *std.http.Client,
    wall_ms: u64,
    jobs: []const Job,
    done: []bool,
    options: RunOptions,
    by_title: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty,
    next: usize = 0,
    mutex: Io.Mutex = .init,
    pending: std.ArrayList(Write) = .empty,
    last_flush: Io.Timestamp,
    stats: Stats = .{},
    err: ?anyerror = null,
    /// Jobs whose findings are pending since the last commit.
    batched: usize = 0,

    /// The next job: a prioritized title's, else the next in order.
    fn pick(r: *Runner) Io.Cancelable!?usize {
        try r.mutex.lock(r.io);
        defer r.mutex.unlock(r.io);
        if (r.err != null) return null;
        if (r.options.priority) |p| {
            try p.mutex.lock(r.io);
            defer p.mutex.unlock(r.io);
            for (p.keys) |k| if (r.by_title.get(k)) |list| for (list.items) |i| if (!r.done[i]) {
                r.done[i] = true;
                return i;
            };
        }
        while (r.next < r.jobs.len) : (r.next += 1) if (!r.done[r.next]) {
            r.done[r.next] = true;
            return r.next;
        };
        return null;
    }

    fn work(r: *Runner) Io.Cancelable!void {
        while (try r.pick()) |i| {
            // Each job reads up to a few hundred kilobytes; keep none of it.
            var job_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer job_arena.deinit();
            var writes: std.ArrayList(Write) = .empty;
            var stats: Stats = .{};
            describeJob(job_arena.allocator(), r.client, r.jobs[i], &writes, &stats) catch |err| {
                stats.failed += 1;
                std.log.warn("describing {s}: {t}", .{ r.jobs[i].target.title_key, err });
            };
            try r.mutex.lock(r.io);
            defer r.mutex.unlock(r.io);
            r.add(writes.items, stats) catch |err| {
                r.err = err;
            };
        }
    }

    /// Takes a job's findings; commits once enough have gathered.
    fn add(r: *Runner, writes: []const Write, stats: Stats) !void {
        for (writes) |w| try r.pending.append(r.arena, .{
            .key = try r.arena.dupe(u8, w.key),
            .field = try r.arena.dupe(u8, w.field),
            .value = try r.arena.dupe(u8, w.value),
        });
        r.stats.covers += stats.covers;
        r.stats.described += stats.described;
        r.stats.failed += stats.failed;
        r.batched += 1;
        const elapsed = r.last_flush.durationTo(Io.Timestamp.now(r.io, .awake)).toMilliseconds();
        if (r.batched >= r.options.batch or elapsed >= r.options.batch_ms) try r.flush();
    }

    fn flush(r: *Runner) !void {
        defer {
            r.batched = 0;
            r.last_flush = Io.Timestamp.now(r.io, .awake);
        }
        if (r.pending.items.len == 0) return;
        if (r.options.writer) |w| try w.lock(r.io);
        defer if (r.options.writer) |w| w.unlock(r.io);
        try r.replica.refresh();
        try r.replica.begin();
        errdefer r.replica.db.exec("ROLLBACK") catch {};
        for (r.pending.items) |w| try r.replica.write(r.wall_ms, w.key, w.field, w.value);
        try r.replica.commit();
        r.pending.clearRetainingCapacity();
    }
};

fn appendInfo(arena: std.mem.Allocator, writes: *std.ArrayList(Write), t: Target, info: mp4.Info) !void {
    const W = Write;
    const title_fields = .{ .{ "genre", info.genre }, .{ "network", info.network } };
    inline for (title_fields) |f| if (f[1]) |v| try writes.append(arena, W{ .key = t.title_key, .field = f[0], .value = v });
    if (t.is_episode) {
        if (info.title) |v| try writes.append(arena, W{ .key = t.item_key, .field = "title", .value = v });
        if (info.description) |v| try writes.append(arena, W{ .key = t.item_key, .field = "description", .value = v });
    } else {
        if (info.description) |v| try writes.append(arena, W{ .key = t.title_key, .field = "description", .value = v });
        if (info.released) |v| try writes.append(arena, W{ .key = t.title_key, .field = "released", .value = v });
    }
    if (info.duration_ms) |d| try writes.append(arena, W{ .key = t.item_key, .field = "duration", .value = try std.fmt.allocPrint(arena, "{d}", .{d}) });
}

fn skippedPath(rel: []const u8, skip: []const u8) bool {
    if (skip.len == 0) return false;
    var segments = std.mem.splitScalar(u8, rel, '/');
    while (segments.next()) |s| if (std.mem.startsWith(u8, s, skip)) return true;
    return false;
}

/// A sidecar image for a target, by Plex, Jellyfin, and Kodi convention.
fn findSidecar(arena: std.mem.Allocator, images: anytype, titles_in: anytype, t: Target) !?Source {
    const dir = std.fs.path.dirname(t.path) orelse "";
    const prefix = if (dir.len > 0) try std.fmt.allocPrint(arena, "{s}/", .{dir}) else "";
    const base = std.fs.path.stem(std.fs.path.basename(t.path));
    var names: std.ArrayList([]const u8) = .empty;
    if (!t.is_episode) {
        for ([_][]const u8{ "-poster.jpg", "-poster.png", ".jpg", ".png" }) |suffix|
            try names.append(arena, try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ prefix, base, suffix }));
        // A folder's poster is the movie's only if it's the folder's only title.
        if (dir.len > 0 and (titles_in.get(dir) orelse return null).count() == 1) {
            for ([_][]const u8{ "poster", "folder", "cover" }) |n| for ([_][]const u8{ ".jpg", ".png" }) |e|
                try names.append(arena, try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ prefix, n, e }));
        }
    } else {
        const season = t.field["art:s".len..];
        const leaf = std.fs.path.basename(dir);
        const in_season_folder = std.ascii.findIgnoreCase(leaf, "season") != null or std.ascii.findIgnoreCase(leaf, "specials") != null;
        const series_dir = if (in_season_folder) (std.fs.path.dirname(dir) orelse "") else dir;
        const series_prefix = if (series_dir.len > 0) try std.fmt.allocPrint(arena, "{s}/", .{series_dir}) else "";
        if (in_season_folder) for ([_][]const u8{ "poster", "folder", "cover" }) |n| for ([_][]const u8{ ".jpg", ".png" }) |e|
            try names.append(arena, try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ prefix, n, e }));
        for ([_][]const u8{ ".jpg", ".png" }) |e| {
            try names.append(arena, try std.fmt.allocPrint(arena, "{s}season{s}-poster{s}", .{ series_prefix, season, e }));
            try names.append(arena, try std.fmt.allocPrint(arena, "{s}season{s}{s}", .{ series_prefix, season, e }));
        }
        // The series' own poster, if its seasons have none.
        if (series_dir.len > 0) for ([_][]const u8{ "poster", "folder", "cover" }) |n| for ([_][]const u8{ ".jpg", ".png" }) |e|
            try names.append(arena, try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ series_prefix, n, e }));
    }
    for (names.items) |n| if (images.get(try std.ascii.allocLowerString(arena, n))) |found| return .{ .path = found.path, .stamp = found.stamp };
    return null;
}

/// Describes one item from its first held copy (e.g., an episode the
/// season's describing didn't read), if it's an MP4.
pub fn describeItem(replica: *Replica, arena: std.mem.Allocator, client: *std.http.Client, wall_ms: u64, item_key: []const u8) !void {
    const s = try replica.db.prepare("SELECT field, value FROM winners WHERE key > ?1 AND key < ?2 AND field LIKE 'held:%' AND length(value) > 0 LIMIT 1");
    defer s.finalize();
    try s.bindText(1, try std.fmt.allocPrint(arena, "{s}/r/", .{item_key}));
    try s.bindText(2, try std.fmt.allocPrint(arena, "{s}/r0", .{item_key}));
    if (!try s.step()) return error.NotHeld;
    const repo_id = try arena.dupe(u8, s.blob(0)["held:".len..]);
    const value = try arena.dupe(u8, s.blob(1));
    const path = value[0 .. std.mem.indexOfScalar(u8, value, '\t') orelse value.len];
    const repo = try library.findRepository(replica, arena, repo_id);
    // A file that isn't an MP4, or can't be read, is marked described too,
    // so it isn't read again.
    const info = mp4.read(arena, client, try fileUrl(arena, repo.url, path)) catch |err| switch (err) {
        error.ConnectionRefused, error.NetworkUnreachable, error.HostUnreachable => return err,
        else => mp4.Info{},
    };
    const title_end = std.mem.indexOf(u8, item_key, "/e/") orelse std.mem.indexOf(u8, item_key, "/v/") orelse item_key.len;
    var writes: std.ArrayList(Write) = .empty;
    try appendInfo(arena, &writes, .{
        .title_key = item_key[0..title_end],
        .item_key = item_key,
        .field = "",
        .path = path,
        .stamp = "",
        .episode = 0,
        .is_episode = std.mem.indexOf(u8, item_key, "/e/") != null,
    }, info);
    // Mark it described even if the file says nothing.
    if (writes.items.len == 0) try writes.append(arena, .{ .key = item_key, .field = "duration", .value = "0" });
    try replica.begin();
    errdefer replica.db.exec("ROLLBACK") catch {};
    for (writes.items) |w| try replica.write(wall_ms, w.key, w.field, w.value);
    try replica.commit();
}

/// One tile of the grid: a movie, or a season of a series.
pub const Tile = struct {
    key: []const u8,
    name: []const u8,
    year: ?u16,
    kind: u8,
    season: ?u16 = null,
    cover: ?Cover = null,
    /// This user's: whether every item is watched, and how far along it
    /// is (a movie's position, or the share of a season's episodes watched).
    watched: bool = false,
    progress: f64 = 0,
};

/// The grid's tiles: titles some repository holds, a series' by season,
/// each with its cover, a season without one taking its series'.
pub fn tiles(replica: *Replica, arena: std.mem.Allocator) ![]Tile {
    var out: std.ArrayList(Tile) = .empty;
    var seasons: std.StringHashMapUnmanaged(std.ArrayList(u16)) = .empty;
    // Held items, by title key and season (0 for a movie's), for progress.
    var items: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    {
        const s = try replica.db.prepare("SELECT DISTINCT substr(key, 1, instr(key, '/r/') - 1) FROM winners WHERE key LIKE 't/%/r/%' AND field LIKE 'held:%' AND length(value) > 0");
        defer s.finalize();
        while (try s.step()) {
            const item = try arena.dupe(u8, s.blob(0));
            const e = std.mem.indexOf(u8, item, "/e/s");
            const title_key = item[0 .. e orelse (std.mem.indexOf(u8, item, "/v/") orelse item.len)];
            const n: u16 = if (e) |i| std.fmt.parseInt(u16, item[i + 4 ..][0..@min(2, item.len - i - 4)], 10) catch continue else 0;
            const id = try std.fmt.allocPrint(arena, "{s}#{d}", .{ title_key, n });
            const gop = try items.getOrPut(arena, id);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
                if (e != null) {
                    const sg = try seasons.getOrPut(arena, title_key);
                    if (!sg.found_existing) sg.value_ptr.* = .empty;
                    try sg.value_ptr.append(arena, n);
                }
            }
            try gop.value_ptr.append(arena, item);
        }
    }
    var heads: std.StringHashMapUnmanaged(library.Playhead) = .empty;
    for (try library.playheads(replica, arena, null)) |h| try heads.put(arena, h.item, h.playhead);
    for (try library.titles(replica, arena)) |t| {
        if (t.renditions == 0 or t.alias != null) continue;
        const own = coverOf(try library.fieldValue(replica, arena, t.key, "art"));
        if (t.kind != 's') {
            var tile: Tile = .{ .key = t.key, .name = t.name, .year = t.year, .kind = t.kind, .cover = own };
            progress(&tile, &items, &heads, try std.fmt.allocPrint(arena, "{s}#0", .{t.key}));
            try out.append(arena, tile);
            continue;
        }
        const list = (seasons.get(t.key) orelse std.ArrayList(u16).empty).items;
        std.mem.sort(u16, list, {}, std.sort.asc(u16));
        for (list) |n| {
            const field = try std.fmt.allocPrint(arena, "art:s{d:0>2}", .{n});
            var tile: Tile = .{ .key = t.key, .name = t.name, .year = t.year, .kind = t.kind, .season = n, .cover = coverOf(try library.fieldValue(replica, arena, t.key, field)) orelse own };
            progress(&tile, &items, &heads, try std.fmt.allocPrint(arena, "{s}#{d}", .{ t.key, n }));
            try out.append(arena, tile);
        }
    }
    return out.items;
}

fn progress(tile: *Tile, items: anytype, heads: anytype, id: []const u8) void {
    const list = (items.get(id) orelse return).items;
    var watched: usize = 0;
    for (list) |item| if (heads.get(item)) |h| {
        if (h.watched) watched += 1;
    };
    tile.watched = list.len > 0 and watched == list.len;
    if (tile.season != null or list.len != 1) {
        tile.progress = @as(f64, @floatFromInt(watched)) / @as(f64, @floatFromInt(list.len));
    } else if (heads.get(list[0])) |h| if (!h.watched and h.duration_ms > 0) {
        tile.progress = @as(f64, @floatFromInt(h.position_ms)) / @as(f64, @floatFromInt(h.duration_ms));
    };
}

fn coverOf(value: ?[]const u8) ?Cover {
    const c = Cover.parse(value orelse return null) orelse return null;
    return if (c.length > 0) c else null;
}

fn watchlistKey(replica: *Replica, arena: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(arena, "p/{s}/watchlist", .{std.fmt.bytesToHex(replica.userKey(), .lower)});
}

/// Adds a title to this user's watchlist, or removes it; private to the
/// user's devices.
pub fn setWatchlisted(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, title_key: []const u8, on: bool) !void {
    try replica.writePrivate(wall_ms, try watchlistKey(replica, arena), &.{.{ title_key, if (on) "1" else "" }});
}

/// The titles on this user's watchlist.
pub fn watchlist(replica: *Replica, arena: std.mem.Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const s = try replica.db.prepare("SELECT field FROM winners WHERE key = ?1 AND value = CAST('1' AS BLOB) ORDER BY field");
    defer s.finalize();
    try s.bindText(1, try watchlistKey(replica, arena));
    while (try s.step()) try out.append(arena, try arena.dupe(u8, s.blob(0)));
    return out.items;
}

test "covers round-trip, and a season without one takes its series'" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const c: Cover = .{ .repository = "0123456789abcdef", .path = "TV/Firefly/Firefly 101.m4v", .offset = 12345, .length = 200000, .stamp = "907600000\t2026-01-01" };
    const back = Cover.parse(try c.format(arena)).?;
    try std.testing.expectEqualStrings(c.path, back.path);
    try std.testing.expectEqual(c.offset, back.offset);
    try std.testing.expectEqualStrings(c.stamp, back.stamp);

    const founder = (try @import("replica.zig").userKeyPair(@splat(1))).public_key.toBytes();
    var r = try Replica.open(std.testing.allocator, ":memory:", founder, .from(@splat(1)));
    defer r.close();
    try r.write(1, "t/s/firefly/-", "name", "Firefly");
    try r.write(1, "t/s/firefly/-/e/s01e01/r/-", "held:0123456789abcdef", "Firefly/Firefly 101.m4v\t1\t-");
    try r.write(1, "t/s/firefly/-/e/s02e01/r/-", "held:0123456789abcdef", "Firefly/Firefly 201.m4v\t1\t-");
    try r.write(1, "t/s/firefly/-", "art", try c.format(arena));
    try r.write(1, "t/s/firefly/-", "art:s02", try (Cover{ .repository = c.repository, .path = "Firefly/season02.jpg", .offset = 0, .length = 9, .stamp = "9\t-" }).format(arena));
    const all = try tiles(&r, arena);
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqual(@as(?u16, 1), all[0].season);
    try std.testing.expectEqualStrings(c.path, all[0].cover.?.path);
    try std.testing.expectEqualStrings("Firefly/season02.jpg", all[1].cover.?.path);

    try library.setWatched(&r, arena, 2, "t/s/firefly/-/e/s01e01", true);
    const after = try tiles(&r, arena);
    try std.testing.expect(after[0].watched and after[0].progress == 1);
    try std.testing.expect(!after[1].watched and after[1].progress == 0);

    try setWatchlisted(&r, arena, 2, "t/s/firefly/-", true);
    try std.testing.expectEqual(@as(usize, 1), (try watchlist(&r, arena)).len);
    try setWatchlisted(&r, arena, 3, "t/s/firefly/-", false);
    try std.testing.expectEqual(@as(usize, 0), (try watchlist(&r, arena)).len);
}

test "a title in several repositories is described once, from its best source, and kept while unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const founder = (try @import("replica.zig").userKeyPair(@splat(1))).public_key.toBytes();
    var r = try Replica.open(std.testing.allocator, ":memory:", founder, .from(@splat(1)));
    defer r.close();
    const a: library.Repository = .{ .id = "aaaaaaaaaaaaaaaa".*, .url = "http://nas/720/", .layout = .{} };
    const b: library.Repository = .{ .id = "bbbbbbbbbbbbbbbb".*, .url = "http://nas/4k/", .layout = .{} };
    const crawled = [_]Crawled{
        .{ .repo = a, .entries = &.{.{ .url = "http://nas/720/Network%20Effect%20(2020).mkv", .parent = "http://nas/720/", .is_dir = false, .size = 1, .mtime = "t" }} },
        .{ .repo = b, .entries = &.{.{ .url = "http://nas/4k/Network%20Effect%20(2020).m4v", .parent = "http://nas/4k/", .is_dir = false, .size = 2, .mtime = "t" }} },
    };
    const first = try plan(&r, arena, &crawled);
    try std.testing.expectEqual(@as(usize, 1), first.jobs.len);
    try std.testing.expectEqualStrings(&b.id, &first.jobs[0].repo.id);
    // Once described from b, it's unchanged, whichever repository's crawl
    // comes first.
    try r.write(1, "t/m/network-effect/2020", "art", try (Cover{ .repository = &b.id, .path = "Network Effect (2020).m4v", .offset = 9, .length = 9, .stamp = "2\tt" }).format(arena));
    const again = try plan(&r, arena, &crawled);
    try std.testing.expectEqual(@as(usize, 0), again.jobs.len);
    try std.testing.expectEqual(@as(usize, 1), again.unchanged);
}
