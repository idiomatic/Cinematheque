//! Covers and metadata, for browsing by cover art.
//!
//! Fields, beside the library's (see library.zig):
//! * on a title's key: `art`, its cover; for a series, `art:s01`, `art:s02`,
//!   and so on, its seasons'; `shape` (and `shape:s01`...), each cover's
//!   width and height (`667x1000`), for players to lay it out before it
//!   loads (`-` if its image isn't a JPEG they can be read from);
//!   and `description`, `genre`, `released`, and `network`.
//! * on an item's key: `title` (an episode's), `description`, and
//!   `duration` (milliseconds).
//!
//! A cover is a byte range of a file in a source, `<source> TAB
//! <path> TAB <offset> TAB <length> TAB <stamp>`, where the stamp is what
//! describing read it from (see `readStamp`), so a title is described
//! again only when that changes. A cover is a sidecar image beside the video, by Plex,
//! Jellyfin, and Kodi convention, or else the one an MP4 embeds. Images
//! don't replicate: players fetch them from sources by range request.

const std = @import("std");
const deadline = @import("deadline.zig");
const Io = std.Io;
const Replica = @import("replica.zig").Replica;
const library = @import("library.zig");
const naming = @import("naming.zig");
const crawl = @import("crawl.zig");
const mp4 = @import("mp4.zig");
const url = @import("url.zig");
const jpeg = @import("jpeg.zig");
const testkit = @import("testkit.zig");

pub const Cover = struct {
    source: []const u8,
    path: []const u8,
    offset: u64,
    length: u64,
    stamp: []const u8,

    pub fn parse(value: []const u8) ?Cover {
        var parts = std.mem.splitScalar(u8, value, '\t');
        const source = parts.next() orelse return null;
        const path = parts.next() orelse return null;
        const offset = std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch return null;
        const length = std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch return null;
        return .{ .source = source, .path = path, .offset = offset, .length = length, .stamp = parts.rest() };
    }

    fn format(c: Cover, arena: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(arena, "{s}\t{s}\t{d}\t{d}\t{s}", .{ c.source, c.path, c.offset, c.length, c.stamp });
    }
};

/// A file's URL in its source, ready to fetch.
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

/// A source and its crawl's listing.
pub const Crawled = struct {
    source: library.Source,
    entries: []const crawl.Entry,
};

const ImageFile = struct { path: []const u8, stamp: []const u8 };

/// Describing one movie or season: its target, and the file to read.
pub const Job = struct {
    target: Target,
    source: library.Source,
    sidecar: ?ImageFile,
    /// An unchanged cover still without its shape, to read it for alone
    /// (one request, for covers described before shapes were).
    shape_for: ?Cover = null,
    /// Other MP4s of its title or season, tried in turn (`max_tries` in
    /// all) if its own has no cover, as one episode's or quality's file may
    /// have none where another's has.
    others: []const Job = &.{},

    /// The file the cover comes from.
    fn imageFile(j: Job) ImageFile {
        return j.sidecar orelse .{ .path = j.target.path, .stamp = j.target.stamp };
    }

    /// What describing read it from: the cover's file's size and time; the
    /// video's too, if the cover is a sidecar, as its metadata is read all
    /// the same (a sort name a tool adds later, say); and what describing
    /// reads (`reads`), so a title described before it read more is
    /// described again, once, by whichever device crawls it first.
    fn readStamp(j: Job, arena: std.mem.Allocator) ![]const u8 {
        if (j.sidecar) |s| return std.fmt.allocPrint(arena, "{s}\t{s}\t{s}", .{ s.stamp, j.target.stamp, reads });
        return std.fmt.allocPrint(arena, "{s}\t{s}", .{ j.target.stamp, reads });
    }
};

/// What describing reads, by version: `r2`, an MP4's sort names too.
const reads = "r2";

/// Marks a cover recorded as none from an MP4 once its title's other MP4s
/// were tried (`Job.others`), so it isn't tried again until its file
/// changes; one without it (recorded before they were tried) is.
const tried = "\ttried";

/// How many MP4s of a title or season are read for a cover, at most.
const max_tries = 4;

pub const Plan = struct {
    jobs: []Job,
    unchanged: usize,
};

/// Plans describing the movies and seasons the `crawled` sources hold:
/// one file for each, keeping the one already described while its file
/// is unchanged, else a sidecar image, else an MP4, else any file; jobs for
/// those to describe, in title order. A title held in several sources
/// (e.g., one per quality) is described from one of them; one described
/// from a source not crawled now (another drive, a NAS crawled lately)
/// stays while that source does, unless a better file is crawled (an
/// image, then an MP4): else a drive's MKVs, crawled alone as it's plugged
/// in, replaced a NAS's MP4s' covers with none.
pub fn plan(replica: *Replica, arena: std.mem.Allocator, crawled: []const Crawled) !Plan {
    var candidates: std.StringArrayHashMapUnmanaged(std.ArrayList(Job)) = .empty;
    for (crawled) |c| {
        const source = c.source;
        // Its entries are as crawled, where it's reached.
        const base = source.at() orelse continue;
        // Images by their path, lowercased, for sidecars.
        var images: std.StringHashMapUnmanaged(ImageFile) = .empty;
        var targets: std.StringArrayHashMapUnmanaged(Target) = .empty;
        // Every MP4 of each, for a cover if the target's has none.
        var mp4s: std.StringHashMapUnmanaged(std.ArrayList(Target)) = .empty;
        // How many titles each directory holds, so a `poster.jpg` is taken
        // as a movie's only where it's the only one there.
        var titles_in: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)) = .empty;
        const series = try library.seriesByFolder(arena, base, source.layout, c.entries);
        for (c.entries) |entry| {
            if (entry.is_dir or !std.mem.startsWith(u8, entry.url, base)) continue;
            const rel = url.decode(try arena.dupe(u8, entry.url[base.len..])) catch continue;
            const stamp = try std.fmt.allocPrint(arena, "{d}\t{s}", .{ entry.size, entry.mtime });
            if (isImage(rel)) {
                try images.put(arena, try std.ascii.allocLowerString(arena, rel), .{ .path = rel, .stamp = stamp });
                continue;
            }
            if (!naming.isVideo(rel) or library.skipped(rel, source.layout.skip)) continue;
            const p = try library.parseFile(arena, (try library.named(arena, source.layout, rel)).path, &series);
            if (p.kind == .extra or p.title.len == 0) continue;
            const k = try library.keys(arena, p);
            const is_episode = p.kind == .episode;
            if (is_episode and p.season == null) continue;
            const field = if (is_episode) try std.fmt.allocPrint(arena, "art:s{d:0>2}", .{p.season.?}) else "art";
            const id = try std.fmt.allocPrint(arena, "{s}#{s}", .{ k.title, field });
            // A season's first episode; a movie's standard version (its
            // editions after it); then the first file by name.
            const episode: u32 = if (p.episode) |e| e else if (p.edition != null) 1 else 0;
            const target: Target = .{ .title_key = k.title, .item_key = k.item, .field = field, .path = rel, .stamp = stamp, .episode = episode, .is_episode = is_episode };
            const gop = try targets.getOrPut(arena, id);
            if (!gop.found_existing or episode < gop.value_ptr.episode or (episode == gop.value_ptr.episode and std.mem.lessThan(u8, rel, gop.value_ptr.path)))
                gop.value_ptr.* = target;
            if (isMp4(rel)) {
                const m = try mp4s.getOrPut(arena, id);
                if (!m.found_existing) m.value_ptr.* = .empty;
                try m.value_ptr.append(arena, target);
            }
            const dir = std.fs.path.dirname(rel) orelse "";
            const t = try titles_in.getOrPut(arena, dir);
            if (!t.found_existing) t.value_ptr.* = .empty;
            try t.value_ptr.put(arena, k.title, {});
        }
        for (targets.keys(), targets.values()) |id, t| {
            const gop = try candidates.getOrPut(arena, id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            // Its source's other MP4s of it: the same item's (another
            // quality's) first, then the next items', a few at most.
            var others: std.ArrayList(Job) = .empty;
            if (mp4s.get(id)) |all| {
                std.mem.sort(Target, all.items, t, struct {
                    fn less(first: Target, a: Target, b: Target) bool {
                        const a_same = std.mem.eql(u8, a.item_key, first.item_key);
                        const b_same = std.mem.eql(u8, b.item_key, first.item_key);
                        if (a_same != b_same) return a_same;
                        if (a.episode != b.episode) return a.episode < b.episode;
                        return std.mem.lessThan(u8, a.path, b.path);
                    }
                }.less);
                for (all.items) |o| {
                    if (others.items.len == max_tries - 1) break;
                    if (!std.mem.eql(u8, o.path, t.path)) try others.append(arena, .{ .target = o, .source = source, .sidecar = null });
                }
            }
            try gop.value_ptr.append(arena, .{ .target = t, .source = source, .sidecar = findSidecar(arena, &images, &titles_in, t) catch null, .others = others.items });
        }
    }
    var jobs: std.ArrayList(Job) = .empty;
    var unchanged: usize = 0;
    var crawled_ids: std.StringHashMapUnmanaged(void) = .empty;
    for (crawled) |c| try crawled_ids.put(arena, &c.source.id, {});
    var known: ?std.StringHashMapUnmanaged([]const u8) = null;
    next: for (candidates.values()) |list| {
        const first = list.items[0];
        var best = first;
        for (list.items) |j| if (rank(j) > rank(best)) {
            best = j;
        };
        if (try library.fieldValue(replica, arena, first.target.title_key, first.target.field)) |old| if (Cover.parse(old)) |c| {
            // The candidates, and the other MP4s each would try: a cover
            // taken from one of those is as current while it's unchanged.
            var considered: std.ArrayList(Job) = .empty;
            for (list.items) |j| {
                try considered.append(arena, j);
                for (j.others) |o| try considered.append(arena, o);
            }
            for (considered.items) |j| {
                const src = j.imageFile();
                // Kept while unchanged, unless a better file's here now
                // (an MP4 beside the MKV it was described from).
                if (rank(j) < rank(best)) continue;
                // None from an MP4, its title's others not yet tried: again.
                if (c.length == 0 and isMp4(c.path) and !std.mem.endsWith(u8, c.stamp, tried) and considered.items.len > 1) continue;
                const stamp = if (std.mem.endsWith(u8, c.stamp, tried)) c.stamp[0 .. c.stamp.len - tried.len] else c.stamp;
                if (std.mem.eql(u8, c.source, &j.source.id) and std.mem.eql(u8, c.path, src.path) and std.mem.eql(u8, stamp, try j.readStamp(arena))) {
                    if (c.length > 0 and try library.fieldValue(replica, arena, j.target.title_key, try shapeField(arena, j.target.field)) == null) {
                        var again = j;
                        again.shape_for = c;
                        try jobs.append(arena, again);
                    } else unchanged += 1;
                    continue :next;
                }
            }
        };
        // Other MP4s to try for a cover, if its own has none: its own
        // source's (gathered above), then other sources' candidates.
        if (best.sidecar == null and isMp4(best.target.path)) {
            var others: std.ArrayList(Job) = .empty;
            try others.appendSlice(arena, best.others);
            for (list.items) |j| if (!std.mem.eql(u8, &j.source.id, &best.source.id) and isMp4(j.target.path)) try others.append(arena, j);
            best.others = others.items[0..@min(others.items.len, max_tries - 1)];
        } else best.others = &.{};
        // Described from a source not crawled now, still in the library,
        // from a file as good: kept.
        if (try library.fieldValue(replica, arena, first.target.title_key, first.target.field)) |old| if (Cover.parse(old)) |c| {
            if (!crawled_ids.contains(c.source)) {
                if (known == null) {
                    known = .empty;
                    for (try library.sources(replica, arena)) |s| try known.?.put(arena, try arena.dupe(u8, &s.id), s.url);
                }
                if (known.?.get(c.source)) |at| if (fileRank(c.path) * 2 + @intFromBool(steady(at)) >= rank(best)) {
                    unchanged += 1;
                    continue :next;
                };
            }
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

/// How good a job's file is for a cover: an image, then an MP4, then
/// another; of each, a server's (a NAS, always there) over a device's own
/// folder's (often a drive that's unplugged, its covers unreachable).
fn rank(j: Job) u8 {
    const kind: u8 = if (j.sidecar != null) 2 else fileRank(j.target.path);
    return kind * 2 + @intFromBool(steady(j.source.url));
}

/// A cover's file's kind, as `rank` counts it: an image, an MP4, else
/// another.
fn fileRank(path: []const u8) u8 {
    if (isImage(path)) return 2;
    return if (isMp4(path)) 1 else 0;
}

/// Whether a source is a server's, not a device's own folder.
fn steady(source_url: []const u8) bool {
    return url.device(source_url) == null;
}

pub const Write = struct { key: []const u8, field: []const u8, value: []const u8 };

/// Describes one job, appending what it found to `writes`.
fn describeJob(arena: std.mem.Allocator, client: *std.http.Client, job: Job, writes: *std.ArrayList(Write), stats: *Stats) !void {
    const t = job.target;
    const source = job.source;
    // A device's own source whose device hasn't said where: next crawl.
    const base = source.at() orelse return;
    if (job.shape_for) |c| {
        const bytes = fetch(arena, client, try fileUrl(arena, base, c.path), c.offset, c.length) catch |err| {
            if (unreachable_(err)) return; // to try again next crawl
            return writeShape(arena, writes, t, null);
        };
        return writeShape(arena, writes, t, bytes);
    }
    const stamp = try job.readStamp(arena);
    if (job.sidecar) |s| {
        const size = std.fmt.parseInt(u64, s.stamp[0 .. std.mem.indexOfScalar(u8, s.stamp, '\t') orelse 0], 10) catch 0;
        const bytes = fetch(arena, client, try fileUrl(arena, base, s.path), 0, size) catch |err| blk: {
            if (unreachable_(err)) return; // to try again next crawl
            break :blk null;
        };
        try writes.append(arena, .{ .key = t.title_key, .field = t.field, .value = try (Cover{ .source = &source.id, .path = s.path, .offset = 0, .length = size, .stamp = stamp }).format(arena) });
        try writeShape(arena, writes, t, bytes);
        stats.covers += 1;
    }
    if (!isMp4(t.path)) {
        // Remember the file was looked at, without a cover.
        if (job.sidecar == null)
            try writes.append(arena, .{ .key = t.title_key, .field = t.field, .value = try (Cover{ .source = &source.id, .path = t.path, .offset = 0, .length = 0, .stamp = stamp }).format(arena) });
        return;
    }
    const info = mp4.read(arena, client, try fileUrl(arena, base, t.path)) catch |err| {
        stats.failed += 1;
        if (unreachable_(err)) return; // to try again next crawl
        // A file that can't be read as an MP4 is remembered as without a
        // cover, so it isn't read again until it changes.
        if (job.sidecar == null)
            try writes.append(arena, .{ .key = t.title_key, .field = t.field, .value = try (Cover{ .source = &source.id, .path = t.path, .offset = 0, .length = 0, .stamp = stamp }).format(arena) });
        return;
    };
    stats.described += 1;
    // No cover in it: another MP4 of its title's that has one, if any.
    if (job.sidecar == null and info.cover == null and job.others.len > 0) {
        for (job.others) |other| {
            const other_base = other.source.at() orelse continue;
            const found = mp4.read(arena, client, try fileUrl(arena, other_base, other.target.path)) catch continue;
            if (found.cover == null) continue;
            return record(arena, writes, other, found, try other.readStamp(arena), stats);
        }
        return record(arena, writes, job, info, try std.fmt.allocPrint(arena, "{s}{s}", .{ stamp, tried }), stats);
    }
    return record(arena, writes, job, info, stamp, stats);
}

/// Records what describing read from a job's MP4: its item's `read`, its
/// cover (none if it has none), and its metadata.
fn record(arena: std.mem.Allocator, writes: *std.ArrayList(Write), job: Job, info: mp4.Info, stamp: []const u8, stats: *Stats) !void {
    const t = job.target;
    const source = job.source;
    // Its item, as read, so it isn't read again on demand until it changes.
    {
        const size = std.fmt.parseInt(u64, t.stamp[0 .. std.mem.indexOfScalar(u8, t.stamp, '\t') orelse t.stamp.len], 10) catch 0;
        const mtime = if (std.mem.indexOfScalar(u8, t.stamp, '\t')) |i| t.stamp[i + 1 ..] else "";
        try writes.append(arena, .{ .key = t.item_key, .field = "read", .value = try itemRead(arena, &source.id, t.path, size, mtime) });
    }
    if (job.sidecar == null) {
        const c = info.cover orelse mp4.Cover{ .offset = 0, .length = 0, .image = .jpeg };
        try writes.append(arena, .{ .key = t.title_key, .field = t.field, .value = try (Cover{ .source = &source.id, .path = t.path, .offset = c.offset, .length = c.length, .stamp = stamp }).format(arena) });
        if (info.cover) |found| {
            stats.covers += 1;
            try writeShape(arena, writes, t, found.bytes);
        }
    }
    try appendInfo(arena, writes, t, info);
}

/// `shape` for `art`, `shape:s01` for `art:s01`.
fn shapeField(arena: std.mem.Allocator, art_field: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "shape{s}", .{art_field[3..]});
}

/// Records a cover's shape, `<width>x<height>`, or `-` if it can't be read
/// (so it isn't tried again until the cover changes).
fn writeShape(arena: std.mem.Allocator, writes: *std.ArrayList(Write), t: Target, image: ?[]const u8) !void {
    const size = if (image) |bytes| jpeg.size(bytes) catch null else null;
    const value = if (size) |z| try std.fmt.allocPrint(arena, "{d}x{d}", .{ z.width, z.height }) else "-";
    try writes.append(arena, .{ .key = t.title_key, .field = try shapeField(arena, t.field), .value = value });
}

/// A file's bytes, or the range of them given; at most 16 MB.
/// Within a minute, as `mp4.read`'s requests are.
fn fetch(arena: std.mem.Allocator, client: *std.http.Client, target: []const u8, offset: u64, length: u64) ![]const u8 {
    return deadline.within(client.io, 60 * 1000, fetchNow, .{ arena, client, target, offset, length });
}

fn fetchNow(arena: std.mem.Allocator, client: *std.http.Client, target: []const u8, offset: u64, length: u64) ![]const u8 {
    if (length == 0 or length > 16 << 20) return error.TooLarge;
    var range_buf: [64]u8 = undefined;
    const last = std.math.add(u64, offset, length - 1) catch return error.TooLarge;
    const range = try std.fmt.bufPrint(&range_buf, "bytes={d}-{d}", .{ offset, last });
    var request = try client.request(.GET, try std.Uri.parse(target), .{
        // No redirect: it could lead anywhere the server likes.
        .redirect_behavior = .not_allowed,
        .extra_headers = &.{.{ .name = "range", .value = range }},
    });
    defer request.deinit();
    try request.sendBodiless();
    var response = try request.receiveHead(&.{});
    // Whole, only if the file is no more than what was asked for.
    if (response.head.status != .partial_content and !(response.head.status == .ok and offset == 0)) return mp4.statusError(response.head.status);
    var transfer: [8192]u8 = undefined;
    return response.reader(&transfer).allocRemaining(arena, .limited(length));
}

/// Whether an error is the network's, worth trying again later.
fn unreachable_(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused, error.ConnectionResetByPeer, error.ConnectionTimedOut, error.NetworkUnreachable, error.HostUnreachable, error.TemporaryNameServerFailure, error.UnknownHostName, error.NameServerFailure, error.EndOfStream, error.ReadFailed, error.WriteFailed, error.Timeout, error.HttpConnectionClosing, error.ServerUnavailable => true,
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
    /// Counts the jobs done, for another thread to read.
    done: ?*std.atomic.Value(u32) = null,
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
    errdefer group.cancel(io);
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
        if (r.options.done) |d| _ = d.fetchAdd(1, .monotonic);
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
        errdefer r.replica.rollback();
        for (r.pending.items) |w| try r.replica.write(r.wall_ms, w.key, w.field, w.value);
        try r.replica.commit();
        r.pending.clearRetainingCapacity();
    }
};

fn appendInfo(arena: std.mem.Allocator, writes: *std.ArrayList(Write), t: Target, info: mp4.Info) !void {
    const W = Write;
    const title_fields = .{ .{ "genre", info.genre }, .{ "network", info.network } };
    inline for (title_fields) |f| if (f[1]) |v| try writes.append(arena, W{ .key = t.title_key, .field = f[0], .value = v });
    // What the title sorts as: a show's, from an episode; a movie's own.
    if (if (t.is_episode) info.sort_show else info.sort_name) |v| try writes.append(arena, W{ .key = t.title_key, .field = "sort", .value = v });
    if (t.is_episode) {
        if (info.title) |v| try writes.append(arena, W{ .key = t.item_key, .field = "title", .value = v });
        if (info.description) |v| try writes.append(arena, W{ .key = t.item_key, .field = "description", .value = v });
    } else {
        if (info.description) |v| try writes.append(arena, W{ .key = t.title_key, .field = "description", .value = v });
        if (info.released) |v| try writes.append(arena, W{ .key = t.title_key, .field = "released", .value = v });
    }
    if (info.duration_ms) |d| try writes.append(arena, W{ .key = t.item_key, .field = "duration", .value = try std.fmt.allocPrint(arena, "{d}", .{d}) });
}

/// A sidecar image for a target, by Plex, Jellyfin, and Kodi convention.
fn findSidecar(arena: std.mem.Allocator, images: anytype, titles_in: anytype, t: Target) !?ImageFile {
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

/// What describing an item read, its `read` field: the file's source,
/// path, size, and time, so it's read again once that file changes (as
/// retagging it does), as a title's cover is (see `readStamp`).
pub fn itemRead(arena: std.mem.Allocator, source: []const u8, path: []const u8, size: u64, mtime: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}\t{s}\t{d}\t{s}", .{ source, path, size, mtime });
}

/// Describes one item from its first held copy (e.g., an episode the
/// season's describing didn't read), if it's an MP4; taking `writer`, if
/// given, only to write what it read, not as it reads the file.
pub fn describeItem(replica: *Replica, arena: std.mem.Allocator, client: *std.http.Client, writer: ?*std.Io.Mutex, wall_ms: u64, item_key: []const u8) !void {
    // Copied out and finalized before the network, so no read snapshot is
    // held open across it and the write after.
    const source_id, const value = blk: {
        const s = try replica.db.prepare("SELECT field, value FROM winners WHERE key > ?1 AND key < ?2 AND field LIKE 'held:%' AND length(value) > 0 LIMIT 1");
        defer s.finalize();
        try s.bindText(1, try std.fmt.allocPrint(arena, "{s}/r/", .{item_key}));
        try s.bindText(2, try std.fmt.allocPrint(arena, "{s}/r0", .{item_key}));
        if (!try s.step()) return error.NotHeld;
        break :blk .{ try arena.dupe(u8, s.blob(0)["held:".len..]), try arena.dupe(u8, s.blob(1)) };
    };
    const copy = library.CopyValue.parse(value);
    const path = copy.path;
    const read = try itemRead(arena, source_id, path, copy.size orelse 0, copy.mtime);
    const source = try library.findSource(replica, arena, source_id);
    // A file that isn't an MP4, or can't be read, is marked described too,
    // so it isn't read again; a network failure is tried again later.
    const info = mp4.read(arena, client, try fileUrl(arena, source.at() orelse return error.ConnectionRefused, path)) catch |err| if (unreachable_(err)) return err else mp4.Info{};
    const title_end = library.pastTitle(item_key, "/e/") orelse library.pastTitle(item_key, "/v/") orelse item_key.len;
    var writes: std.ArrayList(Write) = .empty;
    try appendInfo(arena, &writes, .{
        .title_key = item_key[0..title_end],
        .item_key = item_key,
        .field = "",
        .path = path,
        .stamp = "",
        .episode = 0,
        .is_episode = library.pastTitle(item_key, "/e/") != null,
    }, info);
    // A version's file speaks for itself alone, not its movie (whose
    // description and release its standard version's file gave).
    if (library.pastTitle(item_key, "/v/") != null) {
        var kept: usize = 0;
        for (writes.items) |w| if (std.mem.eql(u8, w.key, item_key)) {
            writes.items[kept] = w;
            kept += 1;
        };
        writes.shrinkRetainingCapacity(kept);
    }
    // Described even if the file says nothing, as of what was read.
    try writes.append(arena, .{ .key = item_key, .field = "read", .value = read });
    if (writer) |m| try m.lock(client.io);
    defer if (writer) |m| m.unlock(client.io);
    try replica.refresh();
    try replica.begin();
    errdefer replica.rollback();
    for (writes.items) |w| try replica.write(wall_ms, w.key, w.field, w.value);
    try replica.commit();
}

/// One tile of the grid: a movie, or a season of a series.
pub const Tile = struct {
    key: []const u8,
    name: []const u8,
    year: ?u16,
    kind: library.TitleKind,
    season: ?u16 = null,
    cover: ?Cover = null,
    /// The cover's width over its height, if known.
    aspect: ?f64 = null,
    /// This person's: whether every item is watched; how much of its running
    /// time has been played, in milliseconds (each watched item whole, so
    /// one stopped in its last 5% counts in full, and each item partway to
    /// its position), of how much (`total`, an item of unknown length
    /// taking the average of those known), and the share (`progress`); and
    /// whether any item has progress.
    watched: bool = false,
    progress: f64 = 0,
    played: u64 = 0,
    total: u64 = 0,
    started: bool = false,
    /// How many items it holds: a movie's versions and parts, or a season's
    /// episodes (an episode's versions and parts counting once).
    items: usize = 0,
    /// Every copy it has is under an unavailable directory (an unplugged drive's).
    unavailable: bool = false,
    /// For ordering (see order.zig), in Unix milliseconds where times: what
    /// the title sorts as, if its file says (`sort`); when it was released,
    /// as written (`released`); when it came (its `added`, written as a
    /// later crawl first found it, else its files' earliest modification
    /// time, else the earliest of its copies' records); its files' latest
    /// modification time; and when this person's progress in it last
    /// changed.
    sort: ?[]const u8 = null,
    released: ?[]const u8 = null,
    added_ms: ?u64 = null,
    modified_ms: ?u64 = null,
    watched_ms: ?u64 = null,
};

/// The grid's tiles: titles some source holds, a series' by season,
/// each with its cover, a season without one taking its series'.
pub fn tiles(replica: *Replica, arena: std.mem.Allocator) ![]Tile {
    var out: std.ArrayList(Tile) = .empty;
    var seasons: std.StringHashMapUnmanaged(std.ArrayList(u16)) = .empty;
    // Held items, by title key and season (0 for a movie's), for progress;
    // and the tiles with a copy that isn't unavailable.
    var items: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    var present: std.StringHashMapUnmanaged(void) = .empty;
    // Items' lengths, as their files' metadata gives them.
    var durations: std.StringHashMapUnmanaged(u64) = .empty;
    // Titles' covers and their shapes (`art`, `art:s01`, `shape`...), and
    // what they sort as and when they were released, by their key and field
    // (`<key> <field>`).
    var covers: std.StringHashMapUnmanaged([]const u8) = .empty;
    // Each tile's files' earliest and latest times (else, for the earliest,
    // its copies' earliest record).
    var first: std.StringHashMapUnmanaged(u64) = .empty;
    var modified: std.StringHashMapUnmanaged(u64) = .empty;
    {
        // In one pass over the titles' keys, by range (as `LIKE` can't use
        // the key's index), as this runs on each reload, every second of a
        // crawl: copies, lengths, and covers.
        const unavailable = try library.UnavailableDirs.load(replica, arena);
        // Devices' downloads, whose copies' times are when they were
        // fetched, not when their files last changed.
        var fetched: std.StringHashMapUnmanaged(void) = .empty;
        for (try library.sources(replica, arena)) |source| if (source.managed) try fetched.put(arena, try arena.dupe(u8, &source.id), {});
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        const s = try replica.db.prepare(
            \\SELECT key, field, value, hlc FROM winners WHERE key >= 't/' AND key < 't0' AND length(value) > 0
            \\AND (field = 'duration' OR (field >= 'held:' AND field < 'held;') OR (field >= 'art' AND field < 'aru') OR (field >= 'shape' AND field < 'shapf') OR field = 'sort' OR field = 'released' OR field = 'added')
        );
        defer s.finalize();
        while (try s.step()) {
            const whole = s.blob(0);
            const field = s.blob(1);
            if (std.mem.eql(u8, field, "duration")) {
                const ms = std.fmt.parseInt(u64, s.blob(2), 10) catch continue;
                if (ms > 0) try durations.put(arena, try arena.dupe(u8, whole), ms);
                continue;
            }
            if (!std.mem.startsWith(u8, field, "held:")) {
                if (library.prefixSegments(whole, 4) == whole.len) try covers.put(arena, try std.fmt.allocPrint(arena, "{s} {s}", .{ whole, field }), try arena.dupe(u8, s.blob(2)));
                continue;
            }
            const here = !unavailable.has(field["held:".len..], s.blob(2));
            const held = whole[0 .. library.pastTitle(whole, "/r/") orelse continue];
            if (tileOf(held)) |id| {
                const tile = try std.fmt.allocPrint(arena, "{s}#{d}", .{ id.title, id.season });
                const file_ms = crawl.timeMs(library.CopyValue.parse(s.blob(2)).mtime);
                const at = file_ms orelse @as(u64, @bitCast(s.int(3))) >> 16;
                const g = try first.getOrPut(arena, tile);
                if (!g.found_existing or at < g.value_ptr.*) g.value_ptr.* = at;
                if (file_ms) |ms| if (!fetched.contains(field["held:".len..])) {
                    const m = try modified.getOrPut(arena, tile);
                    if (!m.found_existing or ms > m.value_ptr.*) m.value_ptr.* = ms;
                };
            }
            if (seen.contains(held)) {
                if (here) if (tileOf(held)) |id| try present.put(arena, try std.fmt.allocPrint(arena, "{s}#{d}", .{ id.title, id.season }), {});
                continue;
            }
            const item = try arena.dupe(u8, held);
            try seen.put(arena, item, {});
            const place = tileOf(item) orelse continue;
            const id = try std.fmt.allocPrint(arena, "{s}#{d}", .{ place.title, place.season });
            if (here) try present.put(arena, id, {});
            const gop = try items.getOrPut(arena, id);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
                if (library.pastTitle(item, "/e/s") != null) {
                    const sg = try seasons.getOrPut(arena, place.title);
                    if (!sg.found_existing) sg.value_ptr.* = .empty;
                    try sg.value_ptr.append(arena, place.season);
                }
            }
            try gop.value_ptr.append(arena, item);
        }
    }
    var heads: std.StringHashMapUnmanaged(library.Progress) = .empty;
    for (try library.progressOf(replica, arena, null)) |h| try heads.put(arena, h.item, h.progress);
    // When this person's progress in each tile last changed.
    var watched: std.StringHashMapUnmanaged(u64) = .empty;
    for (try progressChanged(replica, arena)) |c| if (tileOf(c.item)) |id| {
        const g = try watched.getOrPut(arena, try std.fmt.allocPrint(arena, "{s}#{d}", .{ id.title, id.season }));
        if (!g.found_existing or c.at_ms > g.value_ptr.*) g.value_ptr.* = c.at_ms;
    };
    for (try library.titles(replica, arena)) |t| {
        if (t.qualities == 0) continue;
        const own = coverOf(try coverField(arena, &covers, t.key, "art"));
        const sort = try coverField(arena, &covers, t.key, "sort");
        const released = try coverField(arena, &covers, t.key, "released");
        const came = if (try coverField(arena, &covers, t.key, "added")) |v| std.fmt.parseInt(u64, v, 10) catch null else null;
        const own_aspect = if (own != null) aspectOf(try coverField(arena, &covers, t.key, "shape")) else null;
        switch (t.kind) {
            .movie => {
                const id = try std.fmt.allocPrint(arena, "{s}#0", .{t.key});
                var tile: Tile = .{ .key = t.key, .name = t.name, .year = t.year, .kind = t.kind, .cover = own, .aspect = own_aspect, .unavailable = !present.contains(id), .sort = sort, .released = released, .added_ms = came orelse first.get(id), .modified_ms = modified.get(id), .watched_ms = watched.get(id) };
                progress(&tile, &items, &heads, &durations, id);
                try out.append(arena, tile);
            },
            .series => {
                const list = (seasons.get(t.key) orelse std.ArrayList(u16).empty).items;
                std.mem.sort(u16, list, {}, std.sort.asc(u16));
                for (list) |n| {
                    const field = try std.fmt.allocPrint(arena, "art:s{d:0>2}", .{n});
                    const cover = coverOf(try coverField(arena, &covers, t.key, field));
                    const id = try std.fmt.allocPrint(arena, "{s}#{d}", .{ t.key, n });
                    var tile: Tile = .{ .key = t.key, .name = t.name, .year = t.year, .kind = t.kind, .season = n, .cover = cover orelse own, .aspect = if (cover != null) aspectOf(try coverField(arena, &covers, t.key, try shapeField(arena, field))) else own_aspect, .unavailable = !present.contains(id), .sort = sort, .released = released, .added_ms = came orelse first.get(id), .modified_ms = modified.get(id), .watched_ms = watched.get(id) };
                    progress(&tile, &items, &heads, &durations, id);
                    try out.append(arena, tile);
                }
            },
        }
    }
    return out.items;
}

const ProgressChange = struct { item: []const u8, at_ms: u64 };

/// When this person's progress in each item (its full key) last changed, in
/// wall milliseconds: playing it, or marking it.
fn progressChanged(replica: *Replica, arena: std.mem.Allocator) ![]const ProgressChange {
    var out: std.ArrayList(ProgressChange) = .empty;
    const prefix = try library.progressKey(replica, arena, "");
    const s = try replica.db.prepare("SELECT key, max(hlc) FROM winners WHERE key >= ?1 AND key < ?2 GROUP BY key");
    defer s.finalize();
    // Titles' progress alone, not this person's lists beside it.
    try s.bindText(1, try std.fmt.allocPrint(arena, "{s}t/", .{prefix}));
    try s.bindText(2, try std.fmt.allocPrint(arena, "{s}t0", .{prefix}));
    while (try s.step()) try out.append(arena, .{ .item = try arena.dupe(u8, s.blob(0)[prefix.len..]), .at_ms = @as(u64, @bitCast(s.int(1))) >> 16 });
    return out.items;
}

/// A title's cover field, as `tiles` gathered them.
fn coverField(arena: std.mem.Allocator, covers: *const std.StringHashMapUnmanaged([]const u8), key: []const u8, field: []const u8) !?[]const u8 {
    return covers.get(try std.fmt.allocPrint(arena, "{s} {s}", .{ key, field }));
}

/// A season's number from the digits that start `rest` (after `/e/s`), of
/// any count up to the `e` or `-` that follows.
fn seasonNumber(rest: []const u8) ?u16 {
    var n: usize = 0;
    while (n < rest.len and std.ascii.isDigit(rest[n])) n += 1;
    return std.fmt.parseInt(u16, rest[0..n], 10) catch null;
}

test "season numbers of any width" {
    try std.testing.expectEqual(@as(?u16, 3), seasonNumber("03e17"));
    try std.testing.expectEqual(@as(?u16, 2024), seasonNumber("2024e05"));
    try std.testing.expectEqual(@as(?u16, 0), seasonNumber("00-special"));
    try std.testing.expectEqual(@as(?u16, null), seasonNumber("e05"));
}

/// An item's tile: its title's key, and its season (0 for a movie's).
fn tileOf(item: []const u8) ?struct { title: []const u8, season: u16 } {
    const e = library.pastTitle(item, "/e/s");
    const title_key = item[0 .. e orelse (library.pastTitle(item, "/v/") orelse item.len)];
    const n: u16 = if (e) |i| seasonNumber(item[i + 4 ..]) orelse return null else 0;
    return .{ .title = title_key, .season = n };
}

fn progress(tile: *Tile, items: anytype, heads: anytype, durations: anytype, id: []const u8) void {
    const list = (items.get(id) orelse return).items;
    tile.items = distinctItems(list);
    // An item of unknown length takes the average of those known (else half
    // an hour, an episode's usual length).
    var known_ms: u64 = 0;
    var known: u64 = 0;
    for (list) |item| if (itemLength(item, heads, durations)) |ms| {
        known_ms += ms;
        known += 1;
    };
    const average = if (known > 0) known_ms / known else 30 * 60 * 1000;
    var watched: usize = 0;
    for (list) |item| {
        const ms = itemLength(item, heads, durations) orelse average;
        tile.total += ms;
        const h = heads.get(item) orelse continue;
        tile.started = true;
        if (h.watched) {
            watched += 1;
            tile.played += ms;
        } else if (h.duration_ms > 0) {
            tile.played += ms * @min(h.position_ms, h.duration_ms) / h.duration_ms;
        }
    }
    tile.watched = list.len > 0 and watched == list.len;
    if (tile.total > 0) tile.progress = @as(f64, @floatFromInt(tile.played)) / @as(f64, @floatFromInt(tile.total));
}

/// How many items: an episode's versions and parts count as one.
fn distinctItems(list: []const []const u8) usize {
    var n: usize = 0;
    for (list, 0..) |item, i| {
        const here = withoutVersion(item);
        const seen = for (list[0..i]) |before| {
            if (std.mem.eql(u8, withoutVersion(before), here)) break true;
        } else false;
        if (!seen) n += 1;
    }
    return n;
}

/// An episode's item key without its version or part (`.../e/s01e02`).
fn withoutVersion(item: []const u8) []const u8 {
    const e = library.pastTitle(item, "/e/") orelse return item;
    const end = std.mem.indexOfScalarPos(u8, item, e + 3, '/') orelse return item;
    return item[0..end];
}

/// An item's length: its progress's, else its file's metadata's, if known.
fn itemLength(item: []const u8, heads: anytype, durations: anytype) ?u64 {
    if (heads.get(item)) |h| if (h.duration_ms > 0) return h.duration_ms;
    return durations.get(item);
}

/// `667x1000` as 0.667; null for `-`, or none.
fn aspectOf(value: ?[]const u8) ?f64 {
    const v = value orelse return null;
    const x = std.mem.indexOfScalar(u8, v, 'x') orelse return null;
    const w = std.fmt.parseInt(u16, v[0..x], 10) catch return null;
    const h = std.fmt.parseInt(u16, v[x + 1 ..], 10) catch return null;
    return if (w == 0 or h == 0) null else @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(h));
}

fn coverOf(value: ?[]const u8) ?Cover {
    const c = Cover.parse(value orelse return null) orelse return null;
    return if (c.length > 0) c else null;
}

test "covers round-trip, and a season without one takes its series'" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const c: Cover = .{ .source = "0123456789abcdef", .path = "TV/Firefly/Firefly 101.m4v", .offset = 12345, .length = 200000, .stamp = "907600000\t2026-01-01" };
    const back = Cover.parse(try c.format(arena)).?;
    try std.testing.expectEqualStrings(c.path, back.path);
    try std.testing.expectEqual(c.offset, back.offset);
    try std.testing.expectEqualStrings(c.stamp, back.stamp);

    var r = try testkit.replica(1);
    defer r.close();
    try r.write(1, "t/s/firefly/-", "name", "Firefly");
    try r.write(1, "t/s/firefly/-/e/s01e01/r/-", "held:0123456789abcdef", "Firefly/Firefly 101.m4v\t1\t-");
    try r.write(1, "t/s/firefly/-/e/s02e01/r/-", "held:0123456789abcdef", "Firefly/Firefly 201.m4v\t1\t-");
    try r.write(1, "t/s/firefly/-", "art", try c.format(arena));
    try r.write(1, "t/s/firefly/-", "art:s02", try (Cover{ .source = c.source, .path = "Firefly/season02.jpg", .offset = 0, .length = 9, .stamp = "9\t-" }).format(arena));
    const all = try tiles(&r, arena);
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqual(@as(?u16, 1), all[0].season);
    try std.testing.expectEqualStrings(c.path, all[0].cover.?.path);
    try std.testing.expectEqualStrings("Firefly/season02.jpg", all[1].cover.?.path);

    try library.markWatched(&r, arena, 2, "t/s/firefly/-/e/s01e01");
    const after = try tiles(&r, arena);
    try std.testing.expect(after[0].watched and after[0].progress == 1 and after[0].started);
    try std.testing.expect(!after[1].watched and after[1].progress == 0 and !after[1].started);
    // An episode begun starts its season, and counts to its position.
    try library.setProgress(&r, arena, 3, "t/s/firefly/-/e/s02e01", 600_000, 2_400_000);
    const begun = try tiles(&r, arena);
    try std.testing.expect(!begun[1].watched and begun[1].progress == 0.25 and begun[1].started);
    try std.testing.expectEqual(@as(u64, 600_000), begun[1].played);

    // By time, not by episode: a short episode watched, and a long one,
    // of known length, a quarter played.
    try r.write(4, "t/s/firefly/-/e/s01e02/r/-", "held:0123456789abcdef", "Firefly/Firefly 102.m4v\t1\t-");
    try r.write(4, "t/s/firefly/-/e/s01e01", "duration", "1200000");
    try r.write(4, "t/s/firefly/-/e/s01e02", "duration", "3600000");
    try library.setProgress(&r, arena, 5, "t/s/firefly/-/e/s01e02", 900_000, 3_600_000);
    const timed = try tiles(&r, arena);
    try std.testing.expectEqual(@as(u64, 1_200_000 + 900_000), timed[0].played);
    try std.testing.expectEqual(@as(u64, 4_800_000), timed[0].total);
    try std.testing.expectEqual(@as(usize, 2), timed[0].items);
    try std.testing.expect(!timed[0].watched);
}

test "a title comes when a later crawl finds it; one there all along, by its files' times" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r = try testkit.replica(1);
    defer r.close();
    var source: library.Source = .{ .id = "aaaaaaaaaaaaaaaa".*, .url = "http://nas/", .layout = .{} };
    const alien: crawl.Entry = .{ .url = "http://nas/Alien%20(1979).m4v", .parent = "http://nas/", .is_dir = false, .size = 1, .mtime = "2001-01-01T00:00:00Z" };
    const zulu: crawl.Entry = .{ .url = "http://nas/Zulu%20(1964).m4v", .parent = "http://nas/", .is_dir = false, .size = 1, .mtime = "Mon, 01 Jan 2024 00:00:00 GMT" };
    // A source's first crawl: no `added`, the file's time instead.
    _ = try library.ingest(&r, arena, 5_000_000_000_000, source, &.{alien});
    try std.testing.expectEqual(@as(?[]const u8, null), try library.fieldValue(&r, arena, "t/m/alien/1979", "added"));
    // A later one: the time it found the new title.
    source.crawled_ms = 5_000_000_000_000;
    _ = try library.ingest(&r, arena, 6_000_000_000_000, source, &.{ alien, zulu });
    // Downloaded since, here: when it was fetched isn't when it changed.
    const downloads = try library.addSource(&r, 7, "http://firefly.local:8008/downloads/", .{});
    try r.write(7, "r/" ++ downloads, "managed", "1");
    try r.write(7, "t/m/alien/1979/r/-", "held:" ++ downloads, "Alien (1979).m4v\t1\t7000000000");
    const all = try tiles(&r, arena);
    for (all) |t| {
        if (std.mem.eql(u8, t.key, "t/m/alien/1979")) {
            try std.testing.expectEqual(@as(?u64, 978_307_200_000), t.added_ms);
            try std.testing.expectEqual(@as(?u64, 978_307_200_000), t.modified_ms);
        } else {
            try std.testing.expectEqual(@as(?u64, 6_000_000_000_000), t.added_ms);
            try std.testing.expectEqual(@as(?u64, 1_704_067_200_000), t.modified_ms);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), all.len);
}

test "a title in several sources is described once, from its best file, and kept while unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r = try testkit.replica(1);
    defer r.close();
    const a: library.Source = .{ .id = "aaaaaaaaaaaaaaaa".*, .url = "http://nas/720/", .layout = .{} };
    const b: library.Source = .{ .id = "bbbbbbbbbbbbbbbb".*, .url = "http://nas/4k/", .layout = .{} };
    const crawled = [_]Crawled{
        .{ .source = a, .entries = &.{.{ .url = "http://nas/720/Network%20Effect%20(2020).mkv", .parent = "http://nas/720/", .is_dir = false, .size = 1, .mtime = "t" }} },
        .{ .source = b, .entries = &.{.{ .url = "http://nas/4k/Network%20Effect%20(2020).m4v", .parent = "http://nas/4k/", .is_dir = false, .size = 2, .mtime = "t" }} },
    };
    const first = try plan(&r, arena, &crawled);
    try std.testing.expectEqual(@as(usize, 1), first.jobs.len);
    try std.testing.expectEqualStrings(&b.id, &first.jobs[0].source.id);
    // Described before describing read what it reads now, it's described
    // again.
    try r.write(1, "t/m/network-effect/2020", "art", try (Cover{ .source = &b.id, .path = "Network Effect (2020).m4v", .offset = 9, .length = 9, .stamp = "2\tt" }).format(arena));
    try r.write(1, "t/m/network-effect/2020", "shape", "-");
    const older = try plan(&r, arena, &crawled);
    try std.testing.expectEqual(@as(usize, 1), older.jobs.len);
    try std.testing.expectEqual(@as(?Cover, null), older.jobs[0].shape_for);
    try r.write(1, "t/m/network-effect/2020", "shape", "");
    // Once described from b, it's unchanged, whichever source's crawl
    // comes first.
    try r.write(1, "t/m/network-effect/2020", "art", try (Cover{ .source = &b.id, .path = "Network Effect (2020).m4v", .offset = 9, .length = 9, .stamp = "2\tt\t" ++ reads }).format(arena));
    // Without its shape, it's planned for that alone, from that cover.
    const again = try plan(&r, arena, &crawled);
    try std.testing.expectEqual(@as(usize, 1), again.jobs.len);
    try std.testing.expectEqual(@as(u64, 9), again.jobs[0].shape_for.?.offset);
    try r.write(1, "t/m/network-effect/2020", "shape", "-");
    const settled = try plan(&r, arena, &crawled);
    try std.testing.expectEqual(@as(usize, 0), settled.jobs.len);
    try std.testing.expectEqual(@as(usize, 1), settled.unchanged);
}

test "a cover from a source not crawled now stays, unless a better file is crawled" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r = try testkit.replica(1);
    defer r.close();
    const nas_id = try library.addSource(&r, 1, "http://nas/tv/", .{});
    const drive: library.Source = .{ .id = "dddddddddddddddd".*, .url = "http://mac/drive/", .layout = .{} };
    // Described from the NAS's MP4.
    try r.write(2, "t/m/network-effect/2020", "art", try (Cover{ .source = &nas_id, .path = "Network Effect (2020).m4v", .offset = 9, .length = 9, .stamp = "2\tt\t" ++ reads }).format(arena));
    try r.write(2, "t/m/network-effect/2020", "shape", "-");
    // The drive crawled alone: its MKV is no better, so the cover stays.
    const mkv = [_]Crawled{.{ .source = drive, .entries = &.{.{ .url = "http://mac/drive/Network%20Effect%20(2020).mkv", .parent = "http://mac/drive/", .is_dir = false, .size = 1, .mtime = "t" }} }};
    const kept = try plan(&r, arena, &mkv);
    try std.testing.expectEqual(@as(usize, 0), kept.jobs.len);
    try std.testing.expectEqual(@as(usize, 1), kept.unchanged);
    // Its own poster is better: described from it.
    const poster = [_]Crawled{.{ .source = drive, .entries = &.{
        .{ .url = "http://mac/drive/Network%20Effect%20(2020).mkv", .parent = "http://mac/drive/", .is_dir = false, .size = 1, .mtime = "t" },
        .{ .url = "http://mac/drive/Network%20Effect%20(2020)-poster.jpg", .parent = "http://mac/drive/", .is_dir = false, .size = 1, .mtime = "t" },
    } }};
    try std.testing.expectEqual(@as(usize, 1), (try plan(&r, arena, &poster)).jobs.len);
    // Crawled together, once described from the drive's MKV, the NAS's MP4
    // is better: described from it, though the MKV's unchanged.
    try r.write(4, "t/m/network-effect/2020", "art", try (Cover{ .source = &drive.id, .path = "Network Effect (2020).mkv", .offset = 0, .length = 0, .stamp = "1\tt\t" ++ reads }).format(arena));
    const nas = (try library.sources(&r, arena))[0];
    const both = [_]Crawled{ mkv[0], .{ .source = nas, .entries = &.{.{ .url = "http://nas/tv/Network%20Effect%20(2020).m4v", .parent = "http://nas/tv/", .is_dir = false, .size = 2, .mtime = "t" }} } };
    const better = try plan(&r, arena, &both);
    try std.testing.expectEqual(@as(usize, 1), better.jobs.len);
    try std.testing.expectEqualStrings(&nas_id, &better.jobs[0].source.id);
    // Described from the NAS again, then the NAS gone from the library:
    // described from what's crawled.
    try r.write(5, "t/m/network-effect/2020", "art", try (Cover{ .source = &nas_id, .path = "Network Effect (2020).m4v", .offset = 9, .length = 9, .stamp = "2\tt\t" ++ reads }).format(arena));
    _ = try library.removeSource(&r, arena, 6, &nas_id);
    try std.testing.expectEqual(@as(usize, 1), (try plan(&r, arena, &mkv)).jobs.len);
}

test "a movie with a poster is described again when its video changes, as a tool adding a sort name changes it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r = try testkit.replica(1);
    defer r.close();
    const a: library.Source = .{ .id = "aaaaaaaaaaaaaaaa".*, .url = "http://nas/", .layout = .{} };
    const entries = struct {
        fn of(video_mtime: []const u8) [2]crawl.Entry {
            return .{
                .{ .url = "http://nas/Alien%20(1979)/Alien%20(1979).m4v", .parent = "http://nas/Alien%20(1979)/", .is_dir = false, .size = 7, .mtime = video_mtime },
                .{ .url = "http://nas/Alien%20(1979)/poster.jpg", .parent = "http://nas/Alien%20(1979)/", .is_dir = false, .size = 3, .mtime = "p" },
            };
        }
    }.of;
    const before = entries("t1");
    const first = try plan(&r, arena, &.{.{ .source = a, .entries = &before }});
    try std.testing.expectEqualStrings("Alien (1979)/poster.jpg", first.jobs[0].sidecar.?.path);
    try r.write(1, "t/m/alien/1979", "art", try (Cover{ .source = &a.id, .path = "Alien (1979)/poster.jpg", .offset = 0, .length = 3, .stamp = try first.jobs[0].readStamp(arena) }).format(arena));
    try r.write(1, "t/m/alien/1979", "shape", "-");
    try std.testing.expectEqual(@as(usize, 0), (try plan(&r, arena, &.{.{ .source = a, .entries = &before }})).jobs.len);
    const retagged = entries("t2");
    try std.testing.expectEqual(@as(usize, 1), (try plan(&r, arena, &.{.{ .source = a, .entries = &retagged }})).jobs.len);
}

test "an episode's versions and parts count as one item" {
    const list = [_][]const u8{ "t/s/x/-/e/s01e01", "t/s/x/-/e/s01e01/v/Extended", "t/s/x/-/e/s01e01/p/2", "t/s/x/-/e/s01e02" };
    try std.testing.expectEqual(@as(usize, 2), distinctItems(&list));
}

/// A minimal MP4: `ftyp`, then `moov` holding `udta` with a cover, if
/// given, as tagged files have.
fn testMp4(arena: std.mem.Allocator, cover: ?[]const u8) ![]u8 {
    const W = struct {
        fn atom(gpa: std.mem.Allocator, kind: []const u8, body: []const u8) ![]u8 {
            var size: [4]u8 = undefined;
            std.mem.writeInt(u32, &size, @intCast(8 + body.len), .big);
            return std.mem.concat(gpa, u8, &.{ &size, kind, body });
        }
    };
    const ftyp = try W.atom(arena, "ftyp", "M4V \x00\x00\x00\x00");
    const items = if (cover) |c| try W.atom(arena, "covr", try W.atom(arena, "data", try std.mem.concat(arena, u8, &.{ &.{ 0, 0, 0, 13, 0, 0, 0, 0 }, c }))) else "";
    const meta = try W.atom(arena, "meta", try std.mem.concat(arena, u8, &.{ &.{ 0, 0, 0, 0 }, try W.atom(arena, "hdlr", &@as([25]u8, @splat(0))), try W.atom(arena, "ilst", items) }));
    return std.mem.concat(arena, u8, &.{ ftyp, try W.atom(arena, "moov", try W.atom(arena, "udta", meta)) });
}

test "a season whose first MP4 has no cover takes another's, and one with none anywhere isn't read again" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const served = try testkit.Served.start(arena, "");
    defer served.stop();
    const dir = served.tmp.dir;
    try dir.createDirPath(io, "Black Sails");
    try dir.createDirPath(io, "Devs");
    try dir.writeFile(io, .{ .sub_path = "Black Sails/Black Sails S01E01.m4v", .data = try testMp4(arena, null) });
    try dir.writeFile(io, .{ .sub_path = "Black Sails/Black Sails S01E02.m4v", .data = try testMp4(arena, "\xff\xd8\xff\xe0JPEG") });
    try dir.writeFile(io, .{ .sub_path = "Devs/Devs S01E01.m4v", .data = try testMp4(arena, null) });
    try dir.writeFile(io, .{ .sub_path = "Devs/Devs S01E02.m4v", .data = try testMp4(arena, null) });
    var r = try testkit.replica(1);
    defer r.close();
    _ = try library.addSource(&r, 1, served.url, .{});
    const source = (try library.sources(&r, arena))[0];
    const crawled = try library.crawlSourceAfresh(&r, io, arena, &served.client, 2, source, 1);
    const c = [_]Crawled{.{ .source = source, .entries = crawled.entries }};
    _ = try run(io, &r, arena, &served.client, 3, (try plan(&r, arena, &c)).jobs, .{ .workers = 1 });
    // Black Sails' cover is episode 2's.
    const black = Cover.parse((try library.fieldValue(&r, arena, "t/s/black-sails/-", "art:s01")).?).?;
    try std.testing.expectEqualStrings("Black Sails/Black Sails S01E02.m4v", black.path);
    try std.testing.expect(black.length > 0);
    // Devs has none anywhere: recorded as none, its others tried, so the
    // next crawl leaves both alone.
    const devs = Cover.parse((try library.fieldValue(&r, arena, "t/s/devs/-", "art:s01")).?).?;
    try std.testing.expectEqual(@as(u64, 0), devs.length);
    try std.testing.expect(std.mem.endsWith(u8, devs.stamp, tried));
    const again = try plan(&r, arena, &c);
    try std.testing.expectEqual(@as(usize, 0), again.jobs.len);
    try std.testing.expectEqual(@as(usize, 2), again.unchanged);
}

test "of files alike, a server's describes a title, not a device's own folder's" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r = try testkit.replica(1);
    defer r.close();
    const own = "cqdevice://" ++ @as([64]u8, @splat('a')) ++ "/Archive/";
    const drive: library.Source = .{ .id = "dddddddddddddddd".*, .url = own, .address = "http://mac/Archive/", .layout = .{} };
    const nas: library.Source = .{ .id = "nnnnnnnnnnnnnnnn".*, .url = "http://nas/tv/", .layout = .{} };
    const crawled = [_]Crawled{
        .{ .source = drive, .entries = &.{.{ .url = "http://mac/Archive/Andor%20(2022).mp4", .parent = "http://mac/Archive/", .is_dir = false, .size = 1, .mtime = "t" }} },
        .{ .source = nas, .entries = &.{.{ .url = "http://nas/tv/Andor%20(2022).m4v", .parent = "http://nas/tv/", .is_dir = false, .size = 2, .mtime = "t" }} },
    };
    const p = try plan(&r, arena, &crawled);
    try std.testing.expectEqual(@as(usize, 1), p.jobs.len);
    try std.testing.expectEqualStrings(&nas.id, &p.jobs[0].source.id);
}
