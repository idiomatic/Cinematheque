//! Downloads: a title's, a season's, or an item's files, fetched into a
//! directory of this device's under their paths in the source that held
//! them, so the directory, crawled or served, names them as the library did.
//!
//! Each file comes from its copies in the order copy racing gives (see
//! race.zig), the next tried when one fails. A file is fetched into
//! `<path>.part`, resumed by a range request where an earlier attempt left
//! off, and renamed once whole; one already there at its size is kept.
//!
//! A player's downloads (`reconcile`) go further: its directory is a
//! source of its own, `managed`, which it serves and no one crawls;
//! each file fetched is recorded as its copy on the very quality it
//! came from, so devices see it and copy racing can use it. What it keeps is
//! this device's (in `local`): items wanted by hand (a title or season
//! wanted is its items, as of then), which stay until deleted, and per
//! series, a choice of episodes (`Choice`): the next N after where this
//! person is ("download next"), or all of them. A series' download watched
//! since it was fetched (but for all of them) is done with: deleted as its
//! space is needed, oldest fetched first, once another source is confirmed
//! to hold it (same quality and size, not unavailable); the only copy,
//! never. It keeps `floor_bytes` free.

const std = @import("std");
const Io = std.Io;
const library = @import("library.zig");
const naming = @import("naming.zig");
const deadline = @import("deadline.zig");
const race = @import("race.zig");
const art = @import("art.zig");
const views = @import("views.zig");
const Replica = @import("replica.zig").Replica;

/// One file to fetch.
pub const File = struct {
    /// The item's key (e.g., `t/s/firefly/-/e/s01e02`).
    item: []const u8,
    quality: []const u8,
    /// Where it goes, relative to the directory: its path in the source.
    path: []const u8,
    size: u64,
    /// Its copies' URLs, those not under an unavailable directory first.
    urls: []const []const u8,
    /// Whether a file already at its path, of another size, may be
    /// replaced: one this device's own downloads recorded. Else it's
    /// someone's own file, or another download's that a member's device
    /// gave the same path, and stays.
    replaces: bool = false,
};

/// The files of `key`: a title (`t/m/alien/1979`), a season of a series
/// (`t/s/firefly/-/e/s01`), a version (its parts, if it has no whole
/// file), or an item (`t/s/firefly/-/e/s01e02`, that file alone). Each
/// item's file is of `quality` if given (else, as players play it, the
/// nearest at or below its resolution, else above), else of the quality
/// most of them have, so a season comes alike.
pub fn plan(replica: *Replica, arena: std.mem.Allocator, key: []const u8, quality: ?[]const u8) ![]File {
    const title_end = titleEnd(key) orelse return error.NotFound;
    const planner = try Planner.init(replica, arena, key[0..title_end]) orelse return error.NotFound;
    return planner.files(arena, if (title_end < key.len) key[title_end + 1 ..] else "", quality);
}

/// One title's files to plan from, read once (its details, and the
/// sources' URLs), so planning each of a series' episodes doesn't read the
/// whole series again for each.
pub const Planner = struct {
    d: library.Detail,
    bases: std.StringHashMapUnmanaged([]const u8),

    /// The title `title` (its key), or null if there's none.
    pub fn init(replica: *Replica, arena: std.mem.Allocator, title: []const u8) !?Planner {
        const d = try library.detail(replica, arena, title) orelse return null;
        // Copies come from anywhere but a device's downloads, which a
        // player knows it has (and another can't be sure is awake).
        var bases: std.StringHashMapUnmanaged([]const u8) = .empty;
        for (try library.sources(replica, arena)) |rp| if (!rp.managed) try bases.put(arena, try arena.dupe(u8, &rp.id), rp.url);
        return .{ .d = d, .bases = bases };
    }

    /// As `plan`, for `below` the title's key (empty for all of it).
    pub fn files(planner: Planner, arena: std.mem.Allocator, below: []const u8, quality: ?[]const u8) ![]File {
        return filesOf(arena, planner.d, planner.bases, below, quality);
    }

    /// As `ahead`.
    pub fn ahead(planner: Planner, arena: std.mem.Allocator, choice: Choice) ![]const []const u8 {
        return aheadIn(arena, planner.d, choice);
    }
};

fn filesOf(arena: std.mem.Allocator, d: library.Detail, bases: std.StringHashMapUnmanaged([]const u8), below: []const u8, quality: ?[]const u8) ![]File {
    var items: std.ArrayList(library.Item) = .empty;
    const exact = hasItem(d, below);
    for (d.items.items) |item| if (covers(item.key, below, exact)) try items.append(arena, item);
    if (items.items.len == 0) return error.NotFound;
    const label = quality orelse commonest(items.items);

    var files: std.ArrayList(File) = .empty;
    for (items.items) |item| {
        const r = for (item.qualities.items) |r| {
            if (std.mem.eql(u8, r.label, label)) break r;
        } else if (quality != null) nearest(item.qualities.items, label) orelse continue else item.qualities.items[0];
        var urls: std.ArrayList([]const u8) = .empty;
        var path: ?[]const u8 = null;
        var size: u64 = 0;
        for ([_]bool{ false, true }) |unavailable| for (r.copies.items) |h| {
            if (h.unavailable != unavailable) continue;
            const base = bases.get(h.source) orelse continue;
            if (!safe(h.path) or h.size > max_size) continue;
            try urls.append(arena, try art.fileUrl(arena, base, h.path));
            if (path == null) {
                path = h.path;
                size = h.size;
            }
        };
        try files.append(arena, .{
            .item = try std.fmt.allocPrint(arena, "{s}/{s}", .{ d.key, item.key }),
            .quality = r.label,
            .path = path orelse continue,
            .size = size,
            .urls = urls.items,
        });
    }
    return files.items;
}

/// Whether a title has an item of exactly this key (below the title's).
fn hasItem(d: library.Detail, below: []const u8) bool {
    for (d.items.items) |item| if (std.mem.eql(u8, item.key, below)) return true;
    return false;
}

/// Whether `key` (below its title's) covers an item: an item's key, that
/// item alone (`exact`), else every item within it.
fn covers(item: []const u8, below: []const u8, exact: bool) bool {
    return if (exact) std.mem.eql(u8, item, below) else within(item, below);
}

/// The quality an item lacking `label` plays in its place: the nearest at
/// or below its resolution, else the nearest above; null if either's
/// resolution is unknown.
fn nearest(qualities: []const library.Quality, label: []const u8) ?library.Quality {
    const target = views.height(label, label) orelse return null;
    var below: ?library.Quality = null;
    var above: ?library.Quality = null;
    for (qualities) |q| {
        const h = views.height(q.label, q.label) orelse continue;
        if (h <= target) {
            if (below == null or h > views.height(below.?.label, below.?.label).?) below = q;
        } else if (above == null or h < views.height(above.?.label, above.?.label).?) above = q;
    }
    return below orelse above;
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

/// The quality most of `items` have, the first such if tied.
fn commonest(items: []const library.Item) []const u8 {
    var best: []const u8 = items[0].qualities.items[0].label;
    var best_count: usize = 0;
    for (items) |item| for (item.qualities.items) |r| {
        var count: usize = 0;
        for (items) |other| for (other.qualities.items) |o| {
            if (std.mem.eql(u8, o.label, r.label)) count += 1;
        };
        if (count > best_count) {
            best = r.label;
            best_count = count;
        }
    };
    return best;
}

/// Whether a source's path is one to fetch to, or delete: a video's,
/// within the directory, hidden nowhere along it, since a path comes from
/// whichever member's device crawled it (and could otherwise name, say,
/// `.ssh/authorized_keys`).
fn safe(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |s| {
        if (s.len == 0 or s[0] == '.') return false;
    }
    return naming.isVideo(path);
}

test "a path to fetch to is a video's, within the directory, hidden nowhere" {
    try std.testing.expect(safe("Firefly/Season 1/Firefly S01E01.mp4"));
    try std.testing.expect(!safe("../Firefly S01E01.mp4"));
    try std.testing.expect(!safe("/Users/hal/Firefly S01E01.mp4"));
    try std.testing.expect(!safe(".ssh/authorized_keys"));
    try std.testing.expect(!safe("a/.hidden/Firefly S01E01.mp4"));
    try std.testing.expect(!safe("Firefly/notes.txt"));
}

/// The largest file taken as a copy's size, past any real one (a
/// petabyte), so a size another device wrote can't overflow what's added.
const max_size = 1 << 50;

/// How far a file has come, told as it does; told back whether to go on
/// (false: it's no longer wanted, and stops, its `.part` deleted).
pub const Progress = struct {
    context: *anyopaque,
    report: *const fn (context: *anyopaque, done: u64, total: u64) Verdict,

    /// Whether to go on, as told so far: `error.Unwanted` (its part to be
    /// deleted) or `error.Stopped` (its part kept, to resume) if not.
    fn ask(progress: ?Progress, done: u64, total: u64) !void {
        const p = progress orelse return;
        switch (p.report(p.context, done, total)) {
            .go_on => {},
            .unwanted => return error.Unwanted,
            .stop => return error.Stopped,
        }
    }
};

/// What a file under way is told as it comes: to go on, that it's no
/// longer wanted, or to stop for now.
pub const Verdict = enum { go_on, unwanted, stop };

pub const Fetched = enum { fetched, kept };

/// Fetches `file` into `dir`, from the first of its copies (raced) that
/// gives all of it.
pub fn fetch(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, client: *std.http.Client, memory: *race.Memory, dir: Io.Dir, file: File, now_ms: u64, progress: ?Progress) !Fetched {
    if (dir.statFile(io, file.path, .{})) |st| {
        if (st.size == file.size) return .kept;
        if (!file.replaces) return error.PathTaken;
    } else |_| {}
    if (std.fs.path.dirname(file.path)) |parent| try dir.createDirPath(io, parent);
    const part = try std.fmt.allocPrint(arena, "{s}.part", .{file.path});
    var last: anyerror = error.NoCopies;
    for (try race.order(io, gpa, arena, memory, file.urls, now_ms)) |u| {
        fetchFrom(io, client, dir, part, u, file.size, progress) catch |err| {
            if (err == error.Canceled) return err;
            if (err == error.Unwanted) {
                dir.deleteFile(io, part) catch {};
                return err;
            }
            if (err == error.Stopped) return err;
            last = err;
            try memory.lost(io, gpa, u, now_ms);
            continue;
        };
        try dir.rename(part, dir, file.path, io);
        return .fetched;
    }
    return last;
}

const step_ms = 60 * 1000;

fn receiveHead(request: *std.http.Client.Request) !std.http.Client.Response {
    return request.receiveHead(&.{});
}

fn streamSome(body: *Io.Reader, w: *Io.Writer, n: usize) Io.Reader.StreamError!usize {
    return body.stream(w, .limited(n));
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
    try Progress.ask(progress, have, size);
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
        // A minute to answer, and a minute for each mebibyte after (at
        // least 17 KB/s): so long as bytes come, a large file goes on, but
        // a server sending one at a time doesn't hold reconciling.
        var response = try deadline.within(io, step_ms, receiveHead, .{&request});
        switch (response.head.status) {
            // Only from where the file stands, else it would be corrupted.
            .partial_content => if ((contentRangeStart(response.head) orelse return error.BadRange) != have) return error.BadRange,
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
            const n = deadline.within(io, step_ms, streamSome, .{ body, &writer.interface, @min(size - have, 1 << 20) }) catch |err| switch (err) {
                error.Timeout, error.Canceled => |e| return e,
                error.EndOfStream => break,
                error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
                error.WriteFailed => return writer.err orelse error.WriteFailed,
            };
            if (n == 0) break;
            have += n;
            try Progress.ask(progress, have, size);
        }
        try writer.interface.flush();
    }
    if (try out.length(io) != size) return error.Truncated;
}

/// A copy's file passed on as it comes (to a browser saving it, through
/// this device, which can reach sources the browser may not): from its
/// beginning, or from a `range` asked for (a `Range` header's value, passed
/// on as is, so a browser resumes). The same deadlines as fetching: a
/// minute to answer, and a minute for each mebibyte after.
pub const Relay = struct {
    request: std.http.Client.Request = undefined,
    response: std.http.Client.Response = undefined,
    transfer: [64 * 1024]u8 = undefined,
    status: std.http.Status = .ok,
    /// Its bytes, if the source says; its `Content-Range`, for a range.
    length: ?u64 = null,
    content_range: ?[]const u8 = null,

    /// Asks the source for it; once it answers, `status`, `length`, and
    /// `content_range` say what comes.
    pub fn open(relay: *Relay, io: Io, arena: std.mem.Allocator, client: *std.http.Client, url: []const u8, range: ?[]const u8) !void {
        relay.request = try client.request(.GET, try std.Uri.parse(url), .{
            // No redirect: it could lead anywhere the server likes.
            .redirect_behavior = .not_allowed,
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
            .extra_headers = if (range) |r| &.{.{ .name = "range", .value = r }} else &.{},
        });
        errdefer relay.request.deinit();
        try relay.request.sendBodiless();
        relay.response = try deadline.within(io, step_ms, receiveHead, .{&relay.request});
        relay.status = relay.response.head.status;
        switch (relay.status) {
            .ok, .partial_content => {},
            .not_found => return error.NotFound,
            .range_not_satisfiable => return error.BadRange,
            else => return error.BadStatus,
        }
        relay.length = relay.response.head.content_length;
        var headers = relay.response.head.iterateHeaders();
        while (headers.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "content-range")) {
            relay.content_range = try arena.dupe(u8, h.value);
        };
    }

    /// Passes its bytes on to `out`, flushing as they come.
    pub fn pump(relay: *Relay, io: Io, out: *Io.Writer) !void {
        const body = relay.response.reader(&relay.transfer);
        var sent: u64 = 0;
        while (relay.length == null or sent < relay.length.?) {
            const left = if (relay.length) |l| l - sent else 1 << 20;
            const n = deadline.within(io, step_ms, streamSome, .{ body, out, @min(left, 1 << 20) }) catch |err| switch (err) {
                error.Timeout, error.Canceled, error.WriteFailed => |e| return e,
                error.EndOfStream => break,
                error.ReadFailed => return relay.response.bodyErr() orelse error.ReadFailed,
            };
            if (n == 0) break;
            sent += n;
            try out.flush();
        }
        if (relay.length) |l| if (sent != l) return error.Truncated;
    }

    pub fn deinit(relay: *Relay) void {
        relay.request.deinit();
    }
};

/// Where a `206` response says its bytes start (`Content-Range: bytes
/// 100-199/300`).
fn contentRangeStart(head: std.http.Client.Response.Head) ?u64 {
    var headers = head.iterateHeaders();
    while (headers.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-range")) return rangeStart(h.value);
    }
    return null;
}

fn rangeStart(value: []const u8) ?u64 {
    const rest = std.mem.trimStart(u8, value, " ");
    if (!std.mem.startsWith(u8, rest, "bytes ")) return null;
    const spec = rest["bytes ".len..];
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, spec[0..dash], " "), 10) catch null;
}

test "a change to what's kept, as one file comes, is seen by each file planned before it" {
    var f: Fetching = .{};
    const planned = f.mark();
    try std.testing.expect(!f.changedSince(planned));
    // A deletion as the first file comes: it asks, and goes on.
    f.recheck();
    var seen = planned;
    try std.testing.expect(f.changedSince(seen));
    seen = f.mark();
    try std.testing.expect(!f.changedSince(seen));
    // The next file, planned before the deletion, is asked too.
    try std.testing.expect(f.changedSince(planned));
}

test "a Content-Range's start" {
    try std.testing.expectEqual(@as(?u64, 100), rangeStart("bytes 100-199/300"));
    try std.testing.expectEqual(@as(?u64, 0), rangeStart("bytes 0-9/*"));
    try std.testing.expectEqual(@as(?u64, null), rangeStart("bytes */300"));
    try std.testing.expectEqual(@as(?u64, null), rangeStart("items 1-2/3"));
}

// A player's downloads.

const dir_key = "downloads/dir";
const source_key = "downloads/source";
const want_prefix = "downloads/want/";
const next_prefix = "downloads/next/";
const at_prefix = "downloads/at/";

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
    source: library.Source,
};

/// Sets where this device keeps downloads (`dir`), the URL it serves them
/// at (made a source, `managed`, if it isn't one).
pub fn configure(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, dir: []const u8, served_at: []const u8) !void {
    var typed: std.ArrayList(u8) = .empty;
    try @import("url.zig").escape(arena, &typed, served_at);
    if (!std.mem.endsWith(u8, typed.items, "/")) try typed.append(arena, '/');
    const source = library.findSource(replica, arena, typed.items) catch |err| switch (err) {
        error.NoSuchSource => blk: {
            _ = try library.addSource(replica, wall_ms, typed.items, .{});
            break :blk try library.findSource(replica, arena, typed.items);
        },
        else => |e| return e,
    };
    if (!source.managed) try replica.write(wall_ms, try std.fmt.allocPrint(arena, "r/{s}", .{&source.id}), "managed", "1");
    try replica.setLocal(dir_key, dir);
    try replica.setLocal(source_key, typed.items);
}

/// This device's downloads' settings, if configured.
pub fn settings(replica: *Replica, arena: std.mem.Allocator) !?Settings {
    const dir = try replica.local(arena, dir_key) orelse return null;
    const served_at = try replica.local(arena, source_key) orelse return null;
    const source = library.findSource(replica, arena, served_at) catch return null;
    return .{ .dir = dir, .source = source };
}

pub const Want = struct { key: []const u8, quality: []const u8 };

/// Wants a title's, season's, or item's files kept (see `plan`), in a
/// quality (empty for the one most of its items have): each item as of
/// now, so one deleted by hand isn't fetched again. They stay, watched or
/// not, until deleted.
pub fn want(replica: *Replica, arena: std.mem.Allocator, key: []const u8, quality: []const u8) !void {
    for (try plan(replica, arena, key, if (quality.len > 0) quality else null)) |f|
        try replica.setLocal(try std.fmt.allocPrint(arena, "{s}{s}", .{ want_prefix, f.item }), f.quality);
}

/// A series' download watched since it was fetched, not wanted by hand
/// (nor all of its series chosen): `deletable` once another source holds
/// it alike; else it's the only copy, which stays. Oldest fetched first.
pub const Done = struct { held: Held, deletable: bool, fetched_ms: u64 };

pub fn finishedWith(replica: *Replica, arena: std.mem.Allocator, source: library.Source) ![]Done {
    const sources = try library.sources(replica, arena);
    const unavailable = try library.UnavailableDirs.load(replica, arena);
    // Series whose every episode is chosen keep them, watched or not.
    var all: std.StringHashMapUnmanaged(void) = .empty;
    for (try nexts(replica, arena)) |n| if (n.choice == .all) try all.put(arena, n.title, {});
    var out: std.ArrayList(Done) = .empty;
    for (try held(replica, arena, source)) |h| {
        if (try replica.local(arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ want_prefix, h.item })) != null) continue;
        if (titleEnd(h.item)) |end| if (all.contains(h.item[0..end])) continue;
        const at = std.fmt.parseInt(u64, try replica.local(arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ at_prefix, h.item })) orelse "0", 10) catch 0;
        const watched_ms = try watchedAt(replica, arena, h.item) orelse continue;
        if (watched_ms <= at) continue;
        try out.append(arena, .{ .held = h, .deletable = try confirmed(replica, sources, &unavailable, h), .fetched_ms = at });
    }
    std.mem.sort(Done, out.items, {}, struct {
        fn lt(_: void, a: Done, b: Done) bool {
            return a.fetched_ms < b.fetched_ms;
        }
    }.lt);
    return out.items;
}

/// When this person marked an item watched (its mark's clock, in ms), if it
/// is.
fn watchedAt(replica: *Replica, arena: std.mem.Allocator, item: []const u8) !?u64 {
    const s = try replica.db.prepare("SELECT hlc, value FROM winners WHERE key = ?1 AND field = 'watched'");
    defer s.finalize();
    try s.bindText(1, try library.progressKey(replica, arena, item));
    if (!try s.step() or !std.mem.eql(u8, s.blob(1), "1")) return null;
    return @as(u64, @intCast(s.int(0))) >> 16;
}

pub fn wants(replica: *Replica, arena: std.mem.Allocator) ![]Want {
    var out: std.ArrayList(Want) = .empty;
    for (try replica.localKeys(arena, want_prefix)) |k|
        try out.append(arena, .{ .key = k[want_prefix.len..], .quality = try replica.local(arena, k) orelse "" });
    return out.items;
}

/// Which of a series' episodes download, as it's watched: the `next` N
/// after where this person is (and the one in progress), specials aside,
/// or `all` of them, specials too, kept however they're watched. Written as
/// the number, or `all`; `current`, an earlier choice, reads as the next 1.
pub const Choice = union(enum) {
    next: u32,
    all,

    /// Null for none (empty, `0`, or one that doesn't read).
    pub fn parse(text: []const u8) ?Choice {
        if (std.mem.eql(u8, text, "all")) return .all;
        if (std.mem.eql(u8, text, "current")) return .{ .next = 1 };
        const n = std.fmt.parseInt(u32, text, 10) catch return null;
        return if (n == 0) null else .{ .next = @min(n, 1000) };
    }

    pub fn write(c: Choice, arena: std.mem.Allocator) ![]const u8 {
        return switch (c) {
            .next => |n| std.fmt.allocPrint(arena, "{d}", .{n}),
            .all => "all",
        };
    }
};

pub const Next = struct { title: []const u8, choice: Choice };

/// Chooses which of a series' episodes download (see `Choice`); null, none.
pub fn setNext(replica: *Replica, arena: std.mem.Allocator, title: []const u8, choice: ?Choice) !void {
    const k = try std.fmt.allocPrint(arena, "{s}{s}", .{ next_prefix, title });
    const c = choice orelse return replica.removeLocal(k);
    try replica.setLocal(k, try c.write(arena));
}

pub fn nexts(replica: *Replica, arena: std.mem.Allocator) ![]Next {
    var out: std.ArrayList(Next) = .empty;
    for (try replica.localKeys(arena, next_prefix)) |k| {
        const c = Choice.parse(try replica.local(arena, k) orelse "") orelse continue;
        try out.append(arena, .{ .title = k[next_prefix.len..], .choice = c });
    }
    return out.items;
}

/// What downloading comes to: the files' total size, and of it, what isn't
/// here yet (`needed`), which is what space it would take.
pub const Size = struct { size: u64 = 0, needed: u64 = 0 };

/// The size of `key`'s files (a title's, season's, or item's, in `quality`,
/// else the one most have, as `plan`), or with `choice`, of the episodes the
/// series' choice comes to now (each in the quality most of its files have,
/// as reconciling fetches them).
pub fn sizeOf(replica: *Replica, arena: std.mem.Allocator, key: []const u8, choice: ?Choice, quality: ?[]const u8) !Size {
    return sizeIn(replica, arena, try heldHere(replica, arena), key, choice, quality);
}

/// The quality keys of the files this device's downloads hold.
fn heldHere(replica: *Replica, arena: std.mem.Allocator) !std.StringHashMapUnmanaged(void) {
    var here: std.StringHashMapUnmanaged(void) = .empty;
    if (try settings(replica, arena)) |s| for (try held(replica, arena, s.source)) |h| try here.put(arena, h.key, {});
    return here;
}

/// As `sizeOf`, given what's held here.
fn sizeIn(replica: *Replica, arena: std.mem.Allocator, here: std.StringHashMapUnmanaged(void), key: []const u8, choice: ?Choice, quality: ?[]const u8) !Size {
    var out: Size = .{};
    const add = struct {
        fn files(a: std.mem.Allocator, h: std.StringHashMapUnmanaged(void), total: *Size, list: []const File) !void {
            for (list) |f| {
                total.size +|= f.size;
                if (!h.contains(try std.fmt.allocPrint(a, "{s}/r/{s}", .{ f.item, f.quality }))) total.needed +|= f.size;
            }
        }
    };
    const c = choice orelse {
        const files = plan(replica, arena, key, quality) catch |err| switch (err) {
            error.NotFound => return out,
            else => |e| return e,
        };
        try add.files(arena, here, &out, files);
        return out;
    };
    const planner = try Planner.init(replica, arena, key) orelse return out;
    for (try planner.ahead(arena, c)) |item| {
        const files = planner.files(arena, item, null) catch |err| switch (err) {
            error.NotFound => continue,
            else => |e| return e,
        };
        try add.files(arena, here, &out, files);
    }
    return out;
}

/// A file this device's downloads hold.
pub const Held = struct {
    /// Its quality's key (`<item>/r/<quality>`).
    key: []const u8,
    item: []const u8,
    path: []const u8,
    size: u64,
};

/// Those this device itself recorded: another member's device may write a
/// copy of this device's downloads too, which mustn't have it delete (or
/// keep) a file of its choosing.
pub fn held(replica: *Replica, arena: std.mem.Allocator, source: library.Source) ![]Held {
    var out: std.ArrayList(Held) = .empty;
    // `+device`: not by the device index, which for a device that crawled
    // the library (as a Mac does) is nearly every row, each then looked up
    // (220 ms of 184,000), where scanning them in order takes 16 ms.
    const s = try replica.db.prepare("SELECT key, value FROM winners WHERE field = ?1 AND +device = ?2 AND length(value) > 0 ORDER BY key");
    defer s.finalize();
    try s.bindText(1, try std.fmt.allocPrint(arena, "held:{s}", .{&source.id}));
    try s.bindInt(2, replica.own);
    while (try s.step()) {
        const key = try arena.dupe(u8, s.blob(0));
        const r = std.mem.lastIndexOf(u8, key, "/r/") orelse continue;
        var parts = std.mem.splitScalar(u8, s.blob(1), '\t');
        // A path comes from whichever member's device wrote it.
        const first = parts.first();
        if (!safe(first)) continue;
        const path = try arena.dupe(u8, first);
        const size = std.fmt.parseInt(u64, parts.next() orelse "0", 10) catch 0;
        if (size > max_size) continue;
        try out.append(arena, .{ .key = key, .item = key[0..r], .path = path, .size = size });
    }
    return out.items;
}

/// Whether another source (not a device's downloads) holds `h`'s file
/// alike, its quality and size, and isn't unavailable: so deleting it loses
/// nothing.
/// Whether another source holds a download alike (its quality and size,
/// not unavailable); if not, it's the only copy.
pub fn confirmed(replica: *Replica, sources: []const library.Source, unavailable: *const library.UnavailableDirs, h: Held) !bool {
    const s = try replica.db.prepare("SELECT field, value FROM winners WHERE key = ?1 AND field >= 'held:' AND field < 'held;' AND length(value) > 0");
    defer s.finalize();
    try s.bindText(1, h.key);
    while (try s.step()) {
        const source_id = s.blob(0)["held:".len..];
        const source = for (sources) |rp| {
            if (std.mem.eql(u8, &rp.id, source_id)) break rp;
        } else continue;
        if (source.managed or unavailable.has(source_id, s.blob(1))) continue;
        var parts = std.mem.splitScalar(u8, s.blob(1), '\t');
        _ = parts.first();
        if ((std.fmt.parseInt(u64, parts.next() orelse "", 10) catch continue) == h.size) return true;
    }
    return false;
}

/// Whether another source's server answers for a download's file alike: a
/// `HEAD` of a copy that `confirmed` counts, giving its size.
fn answered(io: Io, arena: std.mem.Allocator, client: *std.http.Client, replica: *Replica, h: Held) !bool {
    _ = io;
    const sources = try library.sources(replica, arena);
    const unavailable = try library.UnavailableDirs.load(replica, arena);
    const s = try replica.db.prepare("SELECT field, value FROM winners WHERE key = ?1 AND field >= 'held:' AND field < 'held;' AND length(value) > 0");
    defer s.finalize();
    try s.bindText(1, h.key);
    var urls: std.ArrayList([]const u8) = .empty;
    while (try s.step()) {
        const source_id = s.blob(0)["held:".len..];
        const source = for (sources) |rp| {
            if (std.mem.eql(u8, &rp.id, source_id)) break rp;
        } else continue;
        if (source.managed or unavailable.has(source_id, s.blob(1))) continue;
        var parts = std.mem.splitScalar(u8, s.blob(1), '\t');
        const path = parts.first();
        if ((std.fmt.parseInt(u64, parts.next() orelse "", 10) catch continue) != h.size or !safe(path)) continue;
        try urls.append(arena, try art.fileUrl(arena, source.url, path));
    }
    for (urls.items) |u| {
        var request = client.request(.HEAD, std.Uri.parse(u) catch continue, .{ .redirect_behavior = .not_allowed }) catch continue;
        defer request.deinit();
        request.sendBodiless() catch continue;
        const response = request.receiveHead(&.{}) catch continue;
        if (response.head.status == .ok and response.head.content_length == h.size) return true;
    }
    return false;
}

/// The item keys (below the title's) of a series' episodes `choice` comes
/// to for this person. For the next `n`, specials aside: the latest in
/// progress and the `n` unwatched after it, so the next is there before
/// this one ends; else, none in progress, the first `n` unwatched.
pub fn ahead(replica: *Replica, arena: std.mem.Allocator, title: []const u8, choice: Choice) ![]const []const u8 {
    return aheadIn(arena, try library.detail(replica, arena, title) orelse return &.{}, choice);
}

fn aheadIn(arena: std.mem.Allocator, d: library.Detail, choice: Choice) ![]const []const u8 {
    const Episode = struct { item: library.Item, season: u32, number: u32 };
    var episodes: std.ArrayList(Episode) = .empty;
    for (d.items.items) |item| {
        const code = episodeCode(item.key) orelse continue;
        if (choice == .next and code[0] == 0) continue;
        try episodes.append(arena, .{ .item = item, .season = code[0], .number = code[1] });
    }
    std.mem.sort(Episode, episodes.items, {}, struct {
        fn lt(_: void, a: Episode, b: Episode) bool {
            return if (a.season != b.season) a.season < b.season else if (a.number != b.number) a.number < b.number else std.mem.lessThan(u8, a.item.key, b.item.key);
        }
    }.lt);
    var out: std.ArrayList([]const u8) = .empty;
    const n = switch (choice) {
        .next => |n| n,
        .all => {
            for (episodes.items) |e| try out.append(arena, e.item.key);
            return out.items;
        },
    };
    var start: ?usize = null;
    for (episodes.items, 0..) |e, i| if (e.item.progress.position_ms > 0 and !e.item.progress.watched) {
        start = i;
    };
    // The one in progress is kept beyond the `n`.
    const in_progress = start != null;
    if (start == null) for (episodes.items, 0..) |e, i| if (!e.item.progress.watched) {
        start = i;
        break;
    };
    const want_count = if (in_progress) n + 1 else n;
    for (episodes.items[start orelse return &.{}..]) |e| {
        if (out.items.len == want_count) break;
        if (!e.item.progress.watched) try out.append(arena, e.item.key);
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

/// Free bytes for this person on the volume holding `dir`, if the platform
/// tells (macOS and Linux). Where it doesn't, or the call fails, null:
/// reconciling then goes on unchecked, as a floor it can't measure can't
/// hold back a download a person asked for.
pub fn freeBytes(arena: std.mem.Allocator, dir: []const u8) ?u64 {
    const path = arena.dupeSentinel(u8, dir, 0) catch return null;
    switch (@import("builtin").os.tag) {
        .macos => {
            var st: Statfs = undefined;
            if (statfs(path.ptr, &st) != 0) return null;
            return st.f_bavail * st.f_bsize;
        },
        .linux => {
            var st: Statvfs = undefined;
            if (statvfs(path.ptr, &st) != 0) return null;
            // Blocks are counted in the fragment size.
            return @as(u64, st.f_bavail) * @as(u64, st.f_frsize);
        },
        else => return null,
    }
}

/// Linux's `struct statvfs` on 64-bit glibc and musl, padded past its end.
const Statvfs = extern struct {
    f_bsize: c_ulong,
    f_frsize: c_ulong,
    f_blocks: c_ulong,
    f_bfree: c_ulong,
    f_bavail: c_ulong,
    f_rest: [16]c_ulong,
};
extern "c" fn statvfs(path: [*:0]const u8, buf: *Statvfs) c_int;

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
    /// Files left while held (a stream playing), for when it isn't.
    held: usize = 0,
    /// Why the last file that failed did.
    @"error": ?[]const u8 = null,
};

/// How far reconciling has come, in megabytes, and the file under way.
pub const Counter = struct {
    done: *std.atomic.Value(u32),
    total: *std.atomic.Value(u32),
    fetching: ?*Fetching = null,
};

/// The file being fetched, if any: its item's full key, its size, and its
/// bytes here so far (a resumed file's earlier ones too), read from any
/// thread.
pub const Fetching = struct {
    mutex: Io.Mutex = .init,
    item: [1024]u8 = undefined,
    len: usize = 0,
    done: u64 = 0,
    size: u64 = 0,
    /// Counts changes to what's kept (something deleted, or a series'
    /// choice of episodes), so each file planned before one is asked again
    /// whether it's still wanted: the one under way, which stops if not,
    /// and each after it, which isn't started. A count, not a flag one
    /// file's asking clears, which left the files after it unasked.
    changes: std.atomic.Value(u32) = .init(0),

    /// Set to stop reconciling: the file under way at its next mebibyte
    /// (its part kept, to resume), and none after.
    stopping: std.atomic.Value(bool) = .init(false),

    /// Asks the files planned so far whether they're still wanted. Any
    /// thread.
    pub fn recheck(f: *Fetching) void {
        _ = f.changes.fetchAdd(1, .acq_rel);
    }

    /// Stops reconciling under way, and any after, until `start`. Any
    /// thread.
    pub fn stop(f: *Fetching) void {
        f.stopping.store(true, .release);
    }

    /// Lets reconciling run again, after `stop`.
    pub fn start(f: *Fetching) void {
        f.stopping.store(false, .release);
    }

    fn stopped(f: *const Fetching) bool {
        return f.stopping.load(.acquire);
    }

    /// The changes so far, to tell later ones by (`changedSince`).
    fn mark(f: *const Fetching) u32 {
        return f.changes.load(.acquire);
    }

    /// Whether what's kept changed since `seen` (a `mark`).
    fn changedSince(f: *const Fetching, seen: u32) bool {
        return f.mark() != seen;
    }

    /// Notes `item` under way (null: none), with `done` bytes; one whose key
    /// is too long to note isn't.
    fn note(f: *Fetching, io: Io, item: ?[]const u8, size: u64) void {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        if (item) |i| {
            if (i.len > f.item.len) {
                f.len = 0;
                return;
            }
            @memcpy(f.item[0..i.len], i);
            f.len = i.len;
        } else f.len = 0;
        f.done = 0;
        f.size = size;
    }

    fn progress(f: *Fetching, io: Io, done: u64) void {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        if (f.len > 0) f.done = done;
    }

    pub fn get(f: *Fetching, io: Io, arena: std.mem.Allocator) !?struct { item: []const u8, done: u64, size: u64 } {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        if (f.len == 0) return null;
        return .{ .item = try arena.dupe(u8, f.item[0..f.len]), .done = f.done, .size = f.size };
    }
};

/// What downloading would come to, one per choice: a series' (`key` its
/// title's), as `Choice.parse` takes it, or empty for `key`'s own files (a
/// title's, season's, or item's) in `quality` (null: the one most have):
/// the `size` of all its files, and what of it is `needed` (not here yet).
pub const SizeReport = struct { choice: []const u8, size: u64, needed: u64 };

pub fn sizes(replica: *Replica, arena: std.mem.Allocator, key: []const u8, choices: []const []const u8, quality: ?[]const u8) ![]const SizeReport {
    const parsed = try arena.alloc(?Choice, choices.len);
    for (choices, parsed) |c, *p| p.* = if (c.len == 0) null else Choice.parse(c) orelse return error.InvalidArgument;
    const out = try sizesOf(replica, arena, key, parsed, quality);
    for (choices, out) |c, *o| o.choice = c;
    return out;
}

/// As `sizes`, of choices already read: null for `key`'s own files; each
/// report's `choice` as `Choice.write` writes it (empty for null).
pub fn sizesOf(replica: *Replica, arena: std.mem.Allocator, key: []const u8, choices: []const ?Choice, quality: ?[]const u8) ![]SizeReport {
    const out = try arena.alloc(SizeReport, choices.len);
    const here = try heldHere(replica, arena);
    for (choices, out) |c, *o| {
        const s = try sizeIn(replica, arena, here, key, c, quality);
        o.* = .{ .choice = if (c) |v| try v.write(arena) else "", .size = s.size, .needed = s.needed };
    }
    return out;
}

/// This device's downloads, as players show them: `dir` and `source` (its
/// ID), as configured (null if not); `held`, the files held (`item`,
/// `size`, and whether it's the `only` copy, no other source holding it
/// alike); `wanted`; `next`, series whose episodes download as they're
/// watched (`title`, and `choice`, as `Choice.parse` takes it), and
/// `ahead`, the episodes (full item keys) they come to now; `free` bytes
/// on its volume, if known, and the `floor` kept free; and, from `live`,
/// whether reconciling is `running`, with `done_mb` of `total_mb`, and the
/// file it's `fetching` (`item`, its `size`, and the bytes `done`).
pub const Report = struct {
    dir: ?[]const u8,
    source: ?[]const u8,
    held: []const HeldReport,
    wanted: []const Want,
    next: []const NextReport,
    ahead: []const []const u8,
    free: ?u64,
    floor: u64,
    running: bool,
    done_mb: u32,
    total_mb: u32,
    fetching: ?FetchingReport,
};
pub const HeldReport = struct { item: []const u8, size: u64, only: bool };
pub const NextReport = struct { title: []const u8, choice: []const u8 };
pub const FetchingReport = struct { item: []const u8, done: u64, size: u64 };

/// What reconciling, under way or not, has come to, for `report`.
pub const Live = struct {
    running: bool = false,
    done_mb: u32 = 0,
    total_mb: u32 = 0,
    fetching: ?*Fetching = null,
};

pub fn report(io: Io, replica: *Replica, arena: std.mem.Allocator, live: Live) !Report {
    const s = try settings(replica, arena);
    var list: std.ArrayList(HeldReport) = .empty;
    if (s) |set| {
        const all = try library.sources(replica, arena);
        const unavailable = try library.UnavailableDirs.load(replica, arena);
        for (try held(replica, arena, set.source)) |h|
            try list.append(arena, .{ .item = h.item, .size = h.size, .only = !try confirmed(replica, all, &unavailable, h) });
    }
    // The episodes each series' next ones come to, as of now, by full key.
    var coming: std.ArrayList([]const u8) = .empty;
    const chosen = try nexts(replica, arena);
    const next = try arena.alloc(NextReport, chosen.len);
    for (chosen, next) |n, *j| {
        j.* = .{ .title = n.title, .choice = try n.choice.write(arena) };
        for (try ahead(replica, arena, n.title, n.choice)) |item|
            try coming.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ n.title, item }));
    }
    const fetching = if (live.fetching) |f| try f.get(io, arena) else null;
    return .{
        .dir = if (s) |set| set.dir else null,
        .source = if (s) |set| try arena.dupe(u8, &set.source.id) else null,
        .held = list.items,
        .wanted = try wants(replica, arena),
        .next = next,
        .ahead = coming.items,
        .free = if (s) |set| freeBytes(arena, set.dir) else null,
        .floor = floor(),
        .running = live.running,
        .done_mb = live.done_mb,
        .total_mb = live.total_mb,
        .fetching = if (fetching) |f| .{ .item = f.item, .done = f.done, .size = f.size } else null,
    };
}

/// Brings this device's downloads in line with what it keeps: forgets
/// copies whose files are gone (deleted by hand, or a directory changed),
/// deletes series' watched episodes as space calls for, and fetches what's wanted and the next episodes kept,
/// recording each file as fetched. `writer`, if given, is held around each
/// write, as other connections' writers are. While `hold` is set (a stream
/// playing, which a download would slow), no file is begun: a file under
/// way finishes, and the rest wait for the next reconciling.
pub fn reconcile(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, client: *std.http.Client, memory: *race.Memory, replica: *Replica, writer: ?*Io.Mutex, wall_ms: u64, counter: ?Counter, hold: ?*const std.atomic.Value(bool)) !Reconciled {
    const s = try settings(replica, arena) orelse return error.NoDownloads;
    var out: Reconciled = .{};
    try Io.Dir.cwd().createDirPath(io, s.dir);
    var dir = try Io.Dir.cwd().openDir(io, s.dir, .{});
    defer dir.close(io);

    // Gone by hand: forgotten. The rest, as recorded, aren't recorded
    // again, which would write (and sync) an operation per file each time.
    var recorded: std.StringHashMapUnmanaged(Held) = .empty;
    for (try held(replica, arena, s.source)) |h| {
        const there = if (dir.statFile(io, h.path, .{})) |st| st.size == h.size else |_| false;
        if (!there) try locked(writer, io, replica, wall_ms, h.key, s.source, "") else try recorded.put(arena, h.key, h);
    }

    // Done with: not fetched again; deleted as below.
    const finished = try finishedWith(replica, arena, s.source);
    var keys: std.StringHashMapUnmanaged(void) = .empty;
    for (finished) |d| try keys.put(arena, d.held.item, {});

    // What's kept: wanted, and kept series' next episodes.
    // Before reading what's wanted, so a change as it's read counts too.
    const planned_at = if (counter) |c| if (c.fetching) |f| f.mark() else 0 else 0;
    var files: std.ArrayList(File) = .empty;
    for (try wants(replica, arena)) |w| {
        if (keys.contains(w.key)) continue;
        const planned = plan(replica, arena, w.key, if (w.quality.len > 0) w.quality else null) catch |err| switch (err) {
            error.NotFound => continue,
            else => |e| return e,
        };
        for (planned) |f| if (!keys.contains(f.item)) {
            try keys.put(arena, f.item, {});
            try files.append(arena, f);
        };
    }
    for (try nexts(replica, arena)) |k| {
        const planner = try Planner.init(replica, arena, k.title) orelse continue;
        for (try planner.ahead(arena, k.choice)) |item| {
            if (keys.contains(try std.fmt.allocPrint(arena, "{s}/{s}", .{ k.title, item }))) continue;
            const planned = planner.files(arena, item, null) catch continue;
            for (planned) |f| {
                try keys.put(arena, f.item, {});
                try files.append(arena, f);
            }
        }
    }

    // Done with and held elsewhere, oldest first: deleted as space is
    // needed.
    var spare: std.ArrayList(Held) = .empty;
    for (finished) |d| if (d.deletable) try spare.append(arena, d.held);
    var next_spare: usize = 0;

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
        if (have != f.size) if (hold) |h| if (h.load(.acquire)) {
            out.held += 1;
            continue;
        };
        if (have != f.size) {
            const part = if (dir.statFile(io, try std.fmt.allocPrint(arena, "{s}.part", .{f.path}), .{})) |st| st.size else |_| 0;
            const need = f.size -| part;
            while (freeBytes(arena, s.dir)) |free| {
                if (free >= need +| floor()) break;
                if (next_spare == spare.items.len) break;
                const h = spare.items[next_spare];
                next_spare += 1;
                // Another copy's word is its record, which any member may
                // write: its server must hold it alike too.
                if (!try answered(io, arena, client, replica, h)) continue;
                try delete(io, arena, dir, replica, writer, wall_ms, s.source, h, &out);
            }
            if (freeBytes(arena, s.dir)) |free| if (free < need +| floor()) {
                out.no_room += 1;
                continue;
            };
        }
        const under_way = if (counter) |c| c.fetching else null;
        if (under_way) |u| if (u.stopped()) break;
        // What's kept changed since this was planned: whether it still is.
        if (under_way) |u| if (u.changedSince(planned_at) and !try stillWanted(replica, arena, f.item)) continue;
        var noted: struct {
            f: *Fetching,
            io: Io,
            replica: *Replica,
            arena: std.mem.Allocator,
            item: []const u8,
            seen: u32,
            fn report(context: *anyopaque, done: u64, _: u64) Verdict {
                const n: *@This() = @ptrCast(@alignCast(context));
                n.f.progress(n.io, done);
                if (n.f.stopped()) return .stop;
                // What's kept changed meanwhile: whether this still is.
                if (!n.f.changedSince(n.seen)) return .go_on;
                n.seen = n.f.mark();
                return if (stillWanted(n.replica, n.arena, n.item) catch true) .go_on else .unwanted;
            }
        } = undefined;
        if (under_way) |u| {
            u.note(io, f.item, f.size);
            noted = .{ .f = u, .io = io, .replica = replica, .arena = arena, .item = f.item, .seen = u.mark() };
        }
        defer if (under_way) |u| u.note(io, null, 0);
        var file = f;
        var owned = recorded.valueIterator();
        file.replaces = while (owned.next()) |h| {
            if (std.mem.eql(u8, h.path, f.path)) break true;
        } else false;
        const fetched = fetch(io, gpa, arena, client, memory, dir, file, wall_ms, if (under_way != null) .{ .context = &noted, .report = @TypeOf(noted).report } else null) catch |err| {
            if (err == error.Canceled) return err;
            // No longer wanted, as it came: stopped, nothing recorded.
            if (err == error.Unwanted) continue;
            // Stopped for now (as the device leaves): nothing after it.
            if (err == error.Stopped) break;
            out.failed += 1;
            out.@"error" = @errorName(err);
            continue;
        };
        if (fetched == .fetched) out.fetched += 1 else out.kept += 1;
        const at = try std.fmt.allocPrint(arena, "{s}{s}", .{ at_prefix, f.item });
        if (fetched == .fetched or try replica.local(arena, at) == null) try replica.setLocal(at, try std.fmt.allocPrint(arena, "{d}", .{wall_ms}));
        const copy = try std.fmt.allocPrint(arena, "{s}/r/{s}", .{ f.item, f.quality });
        if (fetched == .kept) if (recorded.get(copy)) |h| if (std.mem.eql(u8, h.path, f.path) and h.size == f.size) continue;
        const value = try std.fmt.allocPrint(arena, "{s}\t{d}\t{d}", .{ f.path, f.size, @divTrunc(Io.Timestamp.now(io, .real).toMilliseconds(), 1000) });
        try locked(writer, io, replica, wall_ms, copy, s.source, value);
    }
    return out;
}

/// Whether an item (its full key) is still wanted: by hand, or as one of
/// its series' next episodes.
fn stillWanted(replica: *Replica, arena: std.mem.Allocator, item: []const u8) !bool {
    if (try replica.local(arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ want_prefix, item })) != null) return true;
    const title_end = titleEnd(item) orelse return false;
    for (try nexts(replica, arena)) |n| {
        if (!std.mem.eql(u8, n.title, item[0..title_end])) continue;
        for (try ahead(replica, arena, n.title, n.choice)) |below| {
            if (item.len > title_end and std.mem.eql(u8, below, item[title_end + 1 ..])) return true;
        }
    }
    return false;
}

/// Writes `source`'s copy of `key` as `value` (empty: none), copy
/// `writer` if given.
fn locked(writer: ?*Io.Mutex, io: Io, replica: *Replica, wall_ms: u64, key: []const u8, source: library.Source, value: []const u8) !void {
    if (writer) |w| try w.lock(io);
    defer if (writer) |w| w.unlock(io);
    try replica.refresh();
    var field: [5 + 16]u8 = undefined;
    try replica.write(wall_ms, key, try std.fmt.bufPrint(&field, "held:{s}", .{&source.id}), value);
}

/// Deletes a download, and forgets wanting and fetching it.
fn delete(io: Io, arena: std.mem.Allocator, dir: Io.Dir, replica: *Replica, writer: ?*Io.Mutex, wall_ms: u64, source: library.Source, h: Held, out: *Reconciled) !void {
    if (!safe(h.path)) return error.UnsafePath;
    dir.deleteFile(io, h.path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    try locked(writer, io, replica, wall_ms, h.key, source, "");
    for ([_][]const u8{ want_prefix, at_prefix }) |prefix|
        try replica.removeLocal(try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, h.item }));
    out.deleted += 1;
}

/// Stops downloading a title's, season's, or item's files: deletes those this
/// device's downloads hold, and forgets wanting them; and if its series'
/// choice of episodes asks for any of them, sets it to none first, else
/// reconciling would fetch them again.
pub fn remove(io: Io, arena: std.mem.Allocator, replica: *Replica, writer: ?*Io.Mutex, wall_ms: u64, key: []const u8) !usize {
    const s = try settings(replica, arena) orelse return error.NoDownloads;
    var dir = try Io.Dir.cwd().openDir(io, s.dir, .{});
    defer dir.close(io);
    const title_end = titleEnd(key) orelse return error.NotFound;
    const below = if (title_end < key.len) key[title_end + 1 ..] else "";
    const exact = if (try library.detail(replica, arena, key[0..title_end])) |d| hasItem(d, below) else false;
    for (try nexts(replica, arena)) |n| {
        if (!std.mem.eql(u8, n.title, key[0..title_end])) continue;
        for (try ahead(replica, arena, n.title, n.choice)) |item| {
            if (!covers(item, below, exact)) continue;
            try setNext(replica, arena, n.title, null);
            break;
        }
    }
    var out: Reconciled = .{};
    for (try held(replica, arena, s.source)) |h| {
        if (!std.mem.startsWith(u8, h.item, key[0..title_end]) or h.item.len <= title_end or h.item[title_end] != '/') continue;
        if (!covers(h.item[title_end + 1 ..], below, exact)) continue;
        try delete(io, arena, dir, replica, writer, wall_ms, s.source, h, &out);
    }
    // Wanted but not yet fetched, too.
    for (try replica.localKeys(arena, want_prefix)) |k| {
        const wanted = k[want_prefix.len..];
        if (!std.mem.startsWith(u8, wanted, key[0..title_end]) or wanted.len <= title_end or wanted[title_end] != '/') continue;
        if (covers(wanted[title_end + 1 ..], below, exact)) try replica.removeLocal(k);
    }
    return out.deleted;
}

test "a title's, season's, or item's files, in the quality most have" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const founder: [32]u8 = (try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(1))).public_key.toBytes();
    var r = try Replica.open(testing.allocator, testing.io, ":memory:", founder, .from(@splat(1)));
    defer r.close();
    const id = try library.addSource(&r, 1, "http://nas/tv/", .{});
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
    // Those without 720p come in the nearest quality: none lower, so 1080p.
    const all = try plan(&r, arena, "t/s/firefly/-", "720p");
    try testing.expectEqual(3, all.len);
    try testing.expectEqualStrings("1080p", all[1].quality);
    // A version with parts and a whole file: its key, the whole alone; a
    // version of parts alone, its parts.
    try r.write(2, "t/m/gandhi/1982/v/-/r/1080p", held_field, "Gandhi (1982).m4v\t300\t1");
    try r.write(2, "t/m/gandhi/1982/v/-/p/1/r/1080p", held_field, "Gandhi (1982) - Part 1.m4v\t150\t1");
    try r.write(2, "t/m/gandhi/1982/v/-/p/2/r/1080p", held_field, "Gandhi (1982) - Part 2.m4v\t150\t1");
    try r.write(2, "t/m/gandhi/1982/v/extended/p/1/r/1080p", held_field, "Gandhi (1982) - Extended Part 1.m4v\t150\t1");
    try r.write(2, "t/m/gandhi/1982/v/extended/p/2/r/1080p", held_field, "Gandhi (1982) - Extended Part 2.m4v\t150\t1");
    try testing.expectEqual(1, (try plan(&r, arena, "t/m/gandhi/1982/v/-", null)).len);
    try testing.expectEqual(2, (try plan(&r, arena, "t/m/gandhi/1982/v/extended", null)).len);
    try testing.expectEqual(5, (try plan(&r, arena, "t/m/gandhi/1982", null)).len);
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
    const file: File = .{ .item = "t/m/alien/1979/v/-", .quality = "-", .path = "Alien (1979)/Alien (1979).mp4", .size = content.len, .urls = &.{ "http://127.0.0.1:1/gone.mp4", live } };

    try tmp.dir.createDirPath(io, "out/Alien (1979)");
    var out = try tmp.dir.openDir(io, "out", .{});
    defer out.close(io);
    // As an attempt cut short would leave it.
    try out.writeFile(io, .{ .sub_path = "Alien (1979)/Alien (1979).mp4.part", .data = content[0..1234] });
    try std.testing.expectEqual(.fetched, try fetch(io, gpa, arena, &client, &memory, out, file, 1000, null));
    const got = try out.readFileAlloc(io, file.path, arena, .limited(1 << 20));
    try std.testing.expectEqualStrings(content, got);
    try std.testing.expectEqual(.kept, try fetch(io, gpa, arena, &client, &memory, out, file, 1000, null));

    // Told it's no longer wanted as it comes: it stops, its part deleted.
    const unwanted: File = .{ .item = file.item, .quality = file.quality, .path = "Alien (1979)/Again.mp4", .size = file.size, .urls = &.{live} };
    var drop = struct {
        fn report(_: *anyopaque, _: u64, _: u64) Verdict {
            return .unwanted;
        }
    }{};
    try std.testing.expectError(error.Unwanted, fetch(io, gpa, arena, &client, &memory, out, unwanted, 1000, .{ .context = &drop, .report = @TypeOf(drop).report }));
    try std.testing.expectError(error.FileNotFound, out.statFile(io, "Alien (1979)/Again.mp4.part", .{}));
    try std.testing.expectError(error.FileNotFound, out.statFile(io, "Alien (1979)/Again.mp4", .{}));

    // Told to stop for now: it stops, its part kept to resume.
    try out.writeFile(io, .{ .sub_path = "Alien (1979)/Again.mp4.part", .data = content[0..1234] });
    var pause = struct {
        fn report(_: *anyopaque, _: u64, _: u64) Verdict {
            return .stop;
        }
    }{};
    try std.testing.expectError(error.Stopped, fetch(io, gpa, arena, &client, &memory, out, unwanted, 1000, .{ .context = &pause, .report = @TypeOf(pause).report }));
    try std.testing.expectEqual(@as(u64, 1234), (try out.statFile(io, "Alien (1979)/Again.mp4.part", .{})).size);
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
    const nas = try library.addSource(&r, 1, try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/", .{server.port}), .{});
    const nas_field = try std.fmt.allocPrint(arena, "held:{s}", .{&nas});
    const keys = [_][]const u8{ "t/m/alien/1979/v/-", "t/s/firefly/-/e/s01e01", "t/s/firefly/-/e/s01e02", "t/s/firefly/-/e/s01e03", "t/s/firefly/-/e/s01e04" };
    try r.write(2, "t/m/alien/1979", "name", "Alien");
    try r.write(2, "t/s/firefly/-", "name", "Firefly");
    for (keys, paths, 0..) |k, p, i|
        try r.write(2, try std.fmt.allocPrint(arena, "{s}/r/-", .{k}), nas_field, try std.fmt.allocPrint(arena, "{s}\t{d}\t1", .{ p, 1000 + i }));

    const downloads = try std.fmt.allocPrint(arena, "{s}/downloads", .{base});
    try configure(&r, arena, 3, downloads, "http://hal.local:8008/downloads/");
    const s = (try settings(&r, arena)).?;
    try std.testing.expect(s.source.managed);
    try want(&r, arena, "t/m/alien/1979", "");
    try setNext(&r, arena, "t/s/firefly/-", .{ .next = 2 });
    // Episode 1 watched: 2 and 3 are next.
    try library.markWatched(&r, arena, 4, keys[1]);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var memory: race.Memory = .{};
    defer memory.deinit(gpa);
    var done = try reconcile(io, gpa, arena, &client, &memory, &r, null, 5, null, null);
    try std.testing.expectEqual(3, done.fetched);
    const copy = try held(&r, arena, s.source);
    try std.testing.expectEqual(3, copy.len);
    try std.testing.expectEqualStrings("t/m/alien/1979/v/-", copy[0].item);
    try std.testing.expectEqualStrings("t/s/firefly/-/e/s01e02", copy[1].item);
    // Again, with nothing to do: nothing written.
    const seq = r.seq;
    done = try reconcile(io, gpa, arena, &client, &memory, &r, null, 6, null, null);
    try std.testing.expectEqual(0, done.fetched);
    try std.testing.expectEqual(3, done.kept);
    try std.testing.expectEqual(seq, r.seq);

    // Episode 2 in progress: it and the 2 after it.
    try library.setProgress(&r, arena, 5, keys[2], 60_000, 600_000);
    try std.testing.expectEqual(3, (try ahead(&r, arena, "t/s/firefly/-", .{ .next = 2 })).len);
    // A stream playing holds new files back.
    var held_back: std.atomic.Value(bool) = .init(true);
    done = try reconcile(io, gpa, arena, &client, &memory, &r, null, 5, null, &held_back);
    try std.testing.expectEqual(0, done.fetched);
    try std.testing.expectEqual(1, done.held);

    // Episode 2 watched: 4 comes; 2 stays until its space is needed.
    try library.markWatched(&r, arena, 6, keys[2]);
    done = try reconcile(io, gpa, arena, &client, &memory, &r, null, 7, null, null);
    try std.testing.expectEqual(1, done.fetched);
    try std.testing.expectEqual(0, done.deleted);
    try std.testing.expectEqual(4, (try held(&r, arena, s.source)).len);
    var finished = try finishedWith(&r, arena, s.source);
    try std.testing.expectEqual(1, finished.len);
    try std.testing.expect(finished[0].deletable);

    // A download by hand stays, watched or not.
    try library.markWatched(&r, arena, 8, keys[0]);
    try std.testing.expectEqual(1, (try finishedWith(&r, arena, s.source)).len);
    // Watched, but the only copy (the NAS lost it): never deleted.
    try r.write(9, try std.fmt.allocPrint(arena, "{s}/r/-", .{keys[3]}), nas_field, "");
    try library.markWatched(&r, arena, 9, keys[3]);
    finished = try finishedWith(&r, arena, s.source);
    try std.testing.expectEqual(2, finished.len);
    try std.testing.expect(!finished[1].deletable);
    // A series whose every episode is chosen keeps them, watched or not.
    try setNext(&r, arena, "t/s/firefly/-", .all);
    try std.testing.expectEqual(0, (try finishedWith(&r, arena, s.source)).len);

    // Deleted by hand: forgotten. Removed: deleted, and no longer wanted.
    try tmp.dir.deleteFile(io, "downloads/Firefly/S01E04.mp4");
    try setNext(&r, arena, "t/s/firefly/-", null);
    _ = try reconcile(io, gpa, arena, &client, &memory, &r, null, 10, null, null);
    try std.testing.expectEqual(3, (try held(&r, arena, s.source)).len);
    try std.testing.expectEqual(1, try remove(io, arena, &r, null, 11, "t/m/alien/1979"));
    try std.testing.expectEqual(0, (try wants(&r, arena)).len);
    try std.testing.expectEqual(2, (try held(&r, arena, s.source)).len);
    // A season removed whose series' choice asks for it: the choice is
    // stopped, else reconciling would fetch it again.
    try setNext(&r, arena, "t/s/firefly/-", .all);
    _ = try remove(io, arena, &r, null, 12, "t/s/firefly/-/e/s01");
    try std.testing.expectEqual(0, (try nexts(&r, arena)).len);
}

test "a series' choice of episodes: the next few, or all" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const founder: [32]u8 = (try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(1))).public_key.toBytes();
    var r = try Replica.open(gpa, std.testing.io, ":memory:", founder, .from(@splat(1)));
    defer r.close();
    const nas = try library.addSource(&r, 1, "http://sulaco/", .{});
    const field = try std.fmt.allocPrint(arena, "held:{s}", .{&nas});
    try r.write(2, "t/s/firefly/-", "name", "Firefly");
    const items = [_][]const u8{ "e/s00e01", "e/s01e01", "e/s01e02", "e/s01e03", "e/s02e01", "e/s02e02" };
    for (items) |i| try r.write(2, try std.fmt.allocPrint(arena, "t/s/firefly/-/{s}/r/-", .{i}), field, try std.fmt.allocPrint(arena, "{s}.mp4\t1000\t1", .{i}));
    try library.markWatched(&r, arena, 3, "t/s/firefly/-/e/s01e01");

    const cases = [_]struct { choice: []const u8, want: []const []const u8 }{
        .{ .choice = "1", .want = &.{"e/s01e02"} },
        .{ .choice = "2", .want = &.{ "e/s01e02", "e/s01e03" } },
        .{ .choice = "all", .want = &items },
    };
    for (cases) |c| {
        const choice = Choice.parse(c.choice).?;
        // Each reads back as it was written.
        try std.testing.expectEqualStrings(c.choice, try choice.write(arena));
        const got = try ahead(&r, arena, "t/s/firefly/-", choice);
        try std.testing.expectEqual(c.want.len, got.len);
        for (c.want, got) |w, g| try std.testing.expectEqualStrings(w, g);
    }
    for ([_][]const u8{ "", "0", "s02", "unwatched", "none" }) |none| try std.testing.expectEqual(@as(?Choice, null), Choice.parse(none));
    // An earlier choice of the current episode reads as the next one.
    try std.testing.expectEqual(Choice{ .next = 1 }, Choice.parse("current").?);

    // Sizes: each file is 1,000 bytes, and none is here.
    try std.testing.expectEqual(Size{ .size = 2000, .needed = 2000 }, try sizeOf(&r, arena, "t/s/firefly/-", .{ .next = 2 }, null));
    try std.testing.expectEqual(Size{ .size = 6000, .needed = 6000 }, try sizeOf(&r, arena, "t/s/firefly/-", .all, null));
    try std.testing.expectEqual(Size{ .size = 3000, .needed = 3000 }, try sizeOf(&r, arena, "t/s/firefly/-/e/s01", null, null));

    // Chosen, then none.
    try setNext(&r, arena, "t/s/firefly/-", .all);
    try std.testing.expectEqual(Choice.all, (try nexts(&r, arena))[0].choice);
    try setNext(&r, arena, "t/s/firefly/-", null);
    try std.testing.expectEqual(0, (try nexts(&r, arena)).len);
}
