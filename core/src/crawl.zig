//! Crawls a source's listings breadth-first with concurrent workers,
//! reading JSON (Caddy's form), HTML autoindex (links' targets only), or an
//! `INDEX` file.

const std = @import("std");
const deadline = @import("deadline.zig");
const Io = std.Io;
const http = std.http;
const url = @import("url.zig");

/// `auto` reads an `INDEX` if the source has one, else JSON listings if
/// it gives them (Caddy's, nginx's), else HTML.
pub const Format = enum { auto, json, html, index };

/// One listed file or directory, by URL.
pub const Entry = struct {
    url: []const u8,
    parent: []const u8,
    is_dir: bool,
    size: u64,
    /// As the listing gives it, or empty (HTML listings).
    mtime: []const u8,
};

const Dir = struct { url: []const u8, mtime: []const u8 = "" };

/// A previous crawl, to skip directories that haven't changed.
pub const Snapshot = struct {
    entries: []const Entry,
    by_url: std.StringHashMapUnmanaged(usize) = .empty,
    children: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty,

    pub fn init(arena: std.mem.Allocator, entries: []const Entry) !Snapshot {
        var s: Snapshot = .{ .entries = entries };
        for (entries, 0..) |e, i| {
            try s.by_url.put(arena, e.url, i);
            const gop = try s.children.getOrPut(arena, e.parent);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, i);
        }
        return s;
    }

    /// The previous entries of a directory whose modification time hasn't
    /// changed and that held only files, so nothing below it can have
    /// changed either (short of files rewritten in place).
    pub fn unchangedLeaf(s: *const Snapshot, dir: Dir) ?[]const usize {
        if (dir.mtime.len == 0) return null;
        const i = s.by_url.get(dir.url) orelse return null;
        if (!std.mem.eql(u8, s.entries[i].mtime, dir.mtime)) return null;
        const kids = s.children.get(dir.url) orelse return &.{};
        for (kids.items) |k| if (s.entries[k].is_dir) return null;
        return kids.items;
    }

    /// Lines of `url<TAB>parent<TAB>d|f<TAB>size<TAB>mtime`.
    /// A tab or newline in a field (a hostile listing's) couldn't be read
    /// back, and leaving only that entry out would leave its directory
    /// looking whole, so then nothing is saved and the next crawl lists all.
    pub fn save(entries: []const Entry, w: *Io.Writer) !void {
        for (entries) |e| {
            if (std.mem.indexOfAny(u8, e.url, "\t\n") != null or std.mem.indexOfAny(u8, e.parent, "\t\n") != null or
                std.mem.indexOfAny(u8, e.mtime, "\t\n") != null) return;
        }
        for (entries) |e| try w.print("{s}\t{s}\t{s}\t{d}\t{s}\n", .{ e.url, e.parent, if (e.is_dir) "d" else "f", e.size, e.mtime });
    }

    /// A snapshot only saves work, so a damaged one (a line that doesn't
    /// read) is none at all: never an error, and never partial, since a
    /// directory missing children would be reused as it stands.
    pub fn load(arena: std.mem.Allocator, text: []const u8) ![]Entry {
        var entries: std.ArrayList(Entry) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const entry = parseLine(line) orelse return &.{};
            try entries.append(arena, entry);
        }
        return entries.items;
    }

    fn parseLine(line: []const u8) ?Entry {
        var f = std.mem.splitScalar(u8, line, '\t');
        const entry_url = f.next() orelse return null;
        const parent = f.next() orelse return null;
        const kind = f.next() orelse return null;
        const size = std.fmt.parseInt(u64, f.next() orelse return null, 10) catch return null;
        const mtime = f.next() orelse "";
        if (f.next() != null) return null;
        return .{ .url = entry_url, .parent = parent, .is_dir = std.mem.eql(u8, kind, "d"), .size = size, .mtime = mtime };
    }
};

pub const Result = struct {
    files: usize = 0,
    dirs: usize = 0,
    /// Sum of reported file sizes, where the format reports them.
    size: u64 = 0,
    requests: usize = 0,
    /// Directories whose previous listings were reused.
    skipped: usize = 0,
    retries: usize = 0,
    listing_bytes: usize = 0,
    /// The first file's URL.
    sample: ?[]const u8 = null,

    fn add(r: *Result, o: Result) void {
        r.files += o.files;
        r.dirs += o.dirs;
        r.size +|= o.size;
        r.requests += o.requests;
        r.skipped += o.skipped;
        r.retries += o.retries;
        r.listing_bytes += o.listing_bytes;
        if (r.sample == null) r.sample = o.sample;
    }
};

const Worker = struct {
    client: *http.Client,
    arena: std.mem.Allocator,
    format: Format,
    dirs: []const Dir,
    prev: ?*const Snapshot,
    /// Entries found so far by every worker, to stop at `max_entries`
    /// as they're found, not once a level's done.
    seen: *std.atomic.Value(usize),
    next: std.ArrayList(Dir) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    result: Result = .{},
    err: ?anyerror = null,

    fn run(w: *Worker) Io.Cancelable!void {
        for (w.dirs) |dir| {
            if (w.prev) |prev| if (prev.unchangedLeaf(dir)) |kids| {
                w.result.skipped += 1;
                for (kids) |k| {
                    const e = prev.entries[k];
                    w.found(e.url, e.parent, e.is_dir, e.size, e.mtime) catch |err| {
                        w.err = err;
                        return;
                    };
                }
                continue;
            };
            w.list(dir.url) catch |err| {
                w.err = err;
                return;
            };
        }
    }

    fn list(w: *Worker, dir: []const u8) !void {
        const json = w.format == .json;
        // A server may close a pooled keep-alive connection between
        // requests (e.g., Apache after 100), so retry on a fresh one.
        var attempts: usize = 0;
        const got = while (true) : (attempts += 1) {
            break get(w.arena, w.client, dir, if (json) &.{.{ .name = "accept", .value = "application/json" }} else &.{}) catch |err| switch (err) {
                error.HttpConnectionClosing, error.ConnectionResetByPeer, error.ReadFailed, error.WriteFailed => {
                    if (attempts == 3) return err;
                    w.result.retries += 1;
                    continue;
                },
                else => return err,
            };
        };
        if (got.status != .ok) {
            std.log.err("{s}: {d}", .{ dir, @intFromEnum(got.status) });
            return statusError(got.status);
        }
        const text = got.body;
        w.result.requests += 1;
        w.result.listing_bytes += text.len;
        if (json) try w.parseJson(dir, text) else try w.parseHtml(dir, text);
    }

    fn parseJson(w: *Worker, dir: []const u8, text: []const u8) !void {
        // Caddy's items have `is_dir` and `mod_time`; nginx's, `type` and
        // `mtime`.
        const Item = struct {
            name: []const u8,
            size: u64 = 0,
            is_dir: ?bool = null,
            type: ?[]const u8 = null,
            mod_time: ?[]const u8 = null,
            mtime: ?[]const u8 = null,
        };
        const items = try std.json.parseFromSliceLeaky([]Item, w.arena, text, .{ .ignore_unknown_fields = true });
        var href: std.ArrayList(u8) = .empty;
        for (items) |item| {
            // Caddy ends directories' names with a slash.
            const name = std.mem.trimEnd(u8, item.name, "/");
            // Never a name that leaves or loops within the tree.
            if (escapes(name)) continue;
            href.clearRetainingCapacity();
            try href.appendSlice(w.arena, dir);
            try url.encode(w.arena, &href, name);
            const is_dir = item.is_dir orelse std.mem.eql(u8, item.type orelse "", "directory");
            if (is_dir) try href.append(w.arena, '/');
            try w.found(try w.arena.dupe(u8, href.items), dir, is_dir, item.size, item.mod_time orelse item.mtime orelse "");
        }
    }

    /// Reads only links' targets, since displayed names may be truncated
    /// (nginx, Apache) or decorated.
    fn parseHtml(w: *Worker, dir: []const u8, text: []const u8) !void {
        var rest = text;
        while (std.mem.indexOf(u8, rest, "href=\"")) |at| {
            rest = rest[at + 6 ..];
            const end = std.mem.indexOfScalar(u8, rest, '"') orelse break;
            const href = rest[0..end];
            rest = rest[end..];
            // Skip sort and download links, fragments, parents, and links
            // outside the tree.
            if (href.len == 0 or href[0] == '/' or std.mem.indexOfAny(u8, href, "?#") != null or
                std.mem.indexOf(u8, href, "://") != null) continue;
            const target = try unescapeHtml(w.arena, if (std.mem.startsWith(u8, href, "./")) href[2..] else href);
            if (target.len == 0) continue;
            const is_dir = target[target.len - 1] == '/';
            // Decoded, checked, and encoded afresh, as JSON's and INDEX's
            // names are, so `%2e%2e` or an encoded control character can't
            // pass for a name.
            const name = url.decode(try w.arena.dupe(u8, std.mem.trimEnd(u8, target, "/"))) catch continue;
            if (escapes(name)) continue;
            var link: std.ArrayList(u8) = .empty;
            try link.appendSlice(w.arena, dir);
            var segments = std.mem.splitScalar(u8, name, '/');
            var first = true;
            while (segments.next()) |seg| {
                if (!first) try link.append(w.arena, '/');
                first = false;
                try url.encode(w.arena, &link, seg);
            }
            if (is_dir) try link.append(w.arena, '/');
            try w.found(link.items, dir, is_dir, 0, "");
        }
    }

    fn found(w: *Worker, target: []const u8, parent: []const u8, is_dir: bool, size: u64, mtime: []const u8) !void {
        if (w.seen.fetchAdd(1, .monotonic) >= max_entries) return error.TooMany;
        try w.entries.append(w.arena, .{ .url = target, .parent = parent, .is_dir = is_dir, .size = size, .mtime = mtime });
        if (is_dir) {
            w.result.dirs += 1;
            try w.next.append(w.arena, .{ .url = target, .mtime = mtime });
        } else {
            w.result.files += 1;
            w.result.size +|= size;
            if (w.result.sample == null) w.result.sample = target;
        }
    }
};

/// Undoes the entities an HTML attribute may hold (e.g., Apache's `&amp;`).
fn unescapeHtml(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '&') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const entities = [_]struct { []const u8, u8 }{
            .{ "&amp;", '&' },
            .{ "&lt;", '<' },
            .{ "&gt;", '>' },
            .{ "&quot;", '"' },
            .{ "&#39;", '\'' },
        };
        for (entities) |e| {
            if (std.mem.startsWith(u8, text[i..], e[0])) {
                try out.append(arena, e[1]);
                i += e[0].len;
                break;
            }
        } else {
            try out.append(arena, text[i]);
            i += 1;
        }
    }
    return out.items;
}

/// Crawls `base`, reusing `prev`'s listings of unchanged leaf directories,
/// and appends every entry found to `entries`.
pub const Options = struct {
    format: Format = .auto,
    workers: usize = 16,
    /// A previous crawl whose unchanged leaf directories are reused.
    prev: ?*const Snapshot = null,
    /// Where to append every entry found.
    entries: ?*std.ArrayList(Entry) = null,
};

/// Crawls `base`, reusing `prev`'s listings of unchanged leaf directories,
/// and appends every entry found to `entries`.
pub fn crawl(io: Io, arena: std.mem.Allocator, client: *http.Client, base: []const u8, options: Options) !Result {
    const workers = @max(1, options.workers);
    const prev = options.prev;
    const entries = options.entries;
    var format = options.format;
    if (format == .auto or format == .index) {
        if (try crawlIndex(arena, client, base, entries)) |r| return r;
        if (format == .index) return error.NoIndex;
        format = try sniff(arena, client, base);
    }
    var result: Result = .{};
    var level: []const Dir = &.{.{ .url = base }};
    const pool = try arena.alloc(Worker, workers);
    var seen: std.atomic.Value(usize) = .init(0);
    var depth: usize = 0;
    while (level.len > 0) : (depth += 1) {
        if (depth == max_depth) return error.TooDeep;
        var group: Io.Group = .init;
        // The workers use this frame's state, so none outlives an early return.
        errdefer group.cancel(io);
        const n = @min(workers, level.len);
        for (pool[0..n], 0..) |*w, i| {
            const chunk = (level.len + n - 1) / n;
            w.* = .{
                .client = client,
                .arena = arena,
                .format = format,
                .dirs = level[@min(level.len, i * chunk)..@min(level.len, (i + 1) * chunk)],
                .prev = prev,
                .seen = &seen,
            };
            try group.concurrent(io, Worker.run, .{w});
        }
        try group.await(io);
        var next: std.ArrayList(Dir) = .empty;
        for (pool[0..n]) |*w| {
            if (w.err) |err| return err;
            result.add(w.result);
            if (result.files +| result.dirs > max_entries) return error.TooMany;
            try next.appendSlice(arena, w.next.items);
            if (entries) |e| try e.appendSlice(arena, w.entries.items);
        }
        level = next.items;
    }
    return result;
}

/// The most a listing may be, and how deep a crawl goes, so a hostile or
/// broken server (or a symlink loop) can't exhaust memory or never finish.
const max_listing_bytes = 64 << 20;
const max_depth = 64;
/// The most entries a crawl takes, many times the largest library it's
/// made for, so a server inventing directories can't exhaust memory.
const max_entries = 4 << 20;

const Fetched = struct { status: http.Status, body: []const u8 };

/// `fetch` into memory, at most `max_listing_bytes` of it, following up to
/// 3 redirects, each within the source's own origin: a listing's server
/// could otherwise aim a crawl at any other server it can reach.
fn get(arena: std.mem.Allocator, client: *http.Client, location: []const u8, extra_headers: []const http.Header) !Fetched {
    // Within two minutes: a listing of a large folder from a slow server
    // takes seconds, and one sent a byte at a time no longer holds a worker.
    return deadline.within(client.io, 2 * 60 * 1000, getNow, .{ arena, client, location, extra_headers });
}

fn getNow(arena: std.mem.Allocator, client: *http.Client, location: []const u8, extra_headers: []const http.Header) !Fetched {
    const origin = try std.Uri.parse(location);
    var uri = origin;
    var hops: usize = 0;
    while (true) : (hops += 1) {
        var req = try client.request(.GET, uri, .{ .redirect_behavior = .unhandled, .extra_headers = extra_headers });
        defer req.deinit();
        try req.sendBodiless();
        var response = try req.receiveHead(&.{});
        if (response.head.status.class() == .redirect) {
            if (hops == 3) return error.TooManyHttpRedirects;
            const to = response.head.location orelse return error.HttpRedirectLocationMissing;
            // Room for the target resolved against where it came from.
            const aux = try arena.alloc(u8, 2 * to.len + 2 * location.len + 4096);
            @memcpy(aux[0..to.len], to);
            var rest: []u8 = aux;
            const next = uri.resolveInPlace(to.len, &rest) catch return error.HttpRedirectLocationInvalid;
            if (!url.sameOrigin(origin, next)) return error.RedirectedElsewhere;
            uri = next;
            continue;
        }
        return readBody(arena, &response);
    }
}

fn readBody(arena: std.mem.Allocator, response: *http.Client.Response) !Fetched {
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try arena.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try arena.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (decompress_buffer.len > 0) arena.free(decompress_buffer);
    var transfer: [64]u8 = undefined;
    var decompress: http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer, &decompress, decompress_buffer);
    const status = response.head.status;
    const body = reader.allocRemaining(arena, .limited(max_listing_bytes)) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };
    return .{ .status = status, .body = body };
}

/// Whether a path segment would leave or loop within the tree.
fn dotSegment(s: []const u8) bool {
    return s.len == 0 or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..");
}

/// The longest name a crawl takes, and the longest path: what a file
/// system allows, well within what a signed write can carry (a key's 64
/// KiB), and short enough to parse quickly.
const max_segment_bytes = 255;
const max_path_bytes = 4096;

/// Whether a relative path is one a crawl refuses: one with an empty, `.`,
/// or `..` segment (a trailing slash aside), which could leave the
/// source's tree; one too long; or one with a control character, which
/// would cut the records it's written in short.
fn escapes(path: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (trimmed.len > max_path_bytes) return true;
    for (trimmed) |ch| if (ch < 0x20 or ch == 0x7f) return true;
    var segments = std.mem.splitScalar(u8, trimmed, '/');
    while (segments.next()) |s| if (dotSegment(s) or s.len > max_segment_bytes) return true;
    return false;
}

/// What a server's status says went wrong, as an error a person can read
/// (see the apps' messages): nothing there, refused, or the server's fault.
pub fn statusError(status: http.Status) anyerror {
    return switch (status) {
        .not_found, .gone => error.NotFound,
        .unauthorized, .forbidden => error.AccessDenied,
        else => if (@intFromEnum(status) >= 500) error.ServerError else error.BadStatus,
    };
}

/// Asks for a listing as JSON and sees whether that's what came back.
fn sniff(arena: std.mem.Allocator, client: *http.Client, base: []const u8) !Format {
    const got = try get(arena, client, base, &.{.{ .name = "accept", .value = "application/json" }});
    if (got.status != .ok) return statusError(got.status);
    const text = std.mem.trimStart(u8, got.body, " \t\r\n");
    return if (text.len > 0 and text[0] == '[') .json else .html;
}

/// Reads the source's `INDEX`, if it has one: a path per line, relative
/// to the base (as `find .` writes them, `./` and all), optionally followed
/// by a tab, the size, a tab, and the modification time. Returns null when
/// there's none.
fn crawlIndex(arena: std.mem.Allocator, client: *http.Client, base: []const u8, entries: ?*std.ArrayList(Entry)) !?Result {
    const got = try get(arena, client, try std.mem.concat(arena, u8, &.{ base, "INDEX" }), &.{});
    const status = got.status;
    // A server that refuses or rejects the probe (403, 405) has no INDEX to
    // give; only a refusal to be asked at all (401) or a failure is one.
    if (status == .not_found or (@intFromEnum(status) >= 400 and @intFromEnum(status) < 500 and status != .unauthorized)) return null;
    if (status != .ok) return statusError(status);
    var result: Result = .{ .requests = 1, .listing_bytes = got.body.len };
    var lines = std.mem.splitScalar(u8, got.body, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        var path = fields.first();
        if (std.mem.startsWith(u8, path, "./")) path = path[2..];
        if (path.len == 0 or std.mem.eql(u8, path, "INDEX")) continue;
        // A directory, as Cinematheque's own server lists them, so an empty
        // one (an unplugged drive's mount point) shows it's still there.
        const is_dir = std.mem.endsWith(u8, path, "/");
        if (is_dir) path = path[0 .. path.len - 1];
        if (escapes(path) or path.len == 0) continue;
        if (result.files +| result.dirs >= max_entries) return error.TooMany;
        const size = if (fields.next()) |f| std.fmt.parseInt(u64, f, 10) catch 0 else 0;
        const mtime = fields.next() orelse "";
        var href: std.ArrayList(u8) = .empty;
        try href.appendSlice(arena, base);
        var parent_len = base.len;
        var segments = std.mem.splitScalar(u8, path, '/');
        var first = true;
        while (segments.next()) |seg| {
            if (!first) {
                try href.append(arena, '/');
                parent_len = href.items.len;
            }
            first = false;
            try url.encode(arena, &href, seg);
        }
        if (is_dir) {
            try href.append(arena, '/');
            result.dirs += 1;
        } else {
            result.files += 1;
            result.size +|= size;
            if (result.sample == null) result.sample = href.items;
        }
        if (entries) |e| try e.append(arena, .{ .url = href.items, .parent = href.items[0..parent_len], .is_dir = is_dir, .size = size, .mtime = mtime });
    }
    return result;
}

/// A listing's modification time in Unix milliseconds: RFC 3339 (Caddy's,
/// and this app's JSON listings), Unix seconds (an `INDEX`'s), or an HTTP
/// date (nginx's, `Sat, 24 Oct 2026 04:44:00 GMT`); null for none or
/// another form (HTML listings give none). Offsets are taken as UTC.
pub fn timeMs(text: []const u8) ?u64 {
    const t = std.mem.trim(u8, text, " ");
    if (t.len == 0) return null;
    if (std.fmt.parseInt(u64, t, 10)) |seconds| return seconds *| 1000 else |_| {}
    const num = struct {
        fn at(s: []const u8, from: usize, len: usize) ?u32 {
            if (from + len > s.len) return null;
            return std.fmt.parseInt(u32, s[from .. from + len], 10) catch null;
        }
    }.at;
    var y: u32 = 0;
    var mo: u32 = 0;
    var d: u32 = 0;
    var clock: usize = 0;
    if (t.len >= 19 and t[4] == '-' and t[7] == '-' and (t[10] == 'T' or t[10] == ' ')) {
        y = num(t, 0, 4) orelse return null;
        mo = num(t, 5, 2) orelse return null;
        d = num(t, 8, 2) orelse return null;
        clock = 11;
    } else if (t.len >= 25 and t[3] == ',') {
        // `Sat, 24 Oct 2026 04:44:00 GMT`
        d = num(t, 5, 2) orelse return null;
        const months = "JanFebMarAprMayJunJulAugSepOctNovDec";
        const m = std.mem.indexOf(u8, months, t[8..11]) orelse return null;
        if (m % 3 != 0) return null;
        mo = @intCast(m / 3 + 1);
        y = num(t, 12, 4) orelse return null;
        clock = 17;
    } else return null;
    const h = num(t, clock, 2) orelse return null;
    const mi = num(t, clock + 3, 2) orelse return null;
    const sec = num(t, clock + 6, 2) orelse return null;
    if (mo < 1 or mo > 12 or d < 1 or d > 31 or y < 1970 or h > 23 or mi > 59 or sec > 60) return null;
    // Days from the civil date (Howard Hinnant's algorithm).
    const yy: i64 = @as(i64, y) - @intFromBool(mo <= 2);
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp: i64 = @mod(@as(i64, mo) + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, d) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return @intCast(((days * 24 + h) * 60 + mi) * 60_000 + @as(i64, sec) * 1000);
}

test "listing times in each form" {
    try std.testing.expectEqual(@as(?u64, 1_792_817_040_000), timeMs("2026-10-24T04:44:00.8443915Z"));
    try std.testing.expectEqual(@as(?u64, 1_792_817_040_000), timeMs("Sat, 24 Oct 2026 04:44:00 GMT"));
    try std.testing.expectEqual(@as(?u64, 1_792_817_040_000), timeMs("1792817040"));
    try std.testing.expectEqual(@as(?u64, 951_782_400_000), timeMs("2000-02-29T00:00:00Z"));
    try std.testing.expectEqual(@as(?u64, null), timeMs(""));
    try std.testing.expectEqual(@as(?u64, null), timeMs("yesterday"));
}

test "a damaged snapshot loads as none, and a hostile entry isn't saved" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqual(@as(usize, 0), (try Snapshot.load(arena, "http://a/\thttp://\td\tnope\t\n")).len);
    try std.testing.expectEqual(@as(usize, 1), (try Snapshot.load(arena, "http://a/\thttp://\td\t0\tx\n")).len);

    var buf: Io.Writer.Allocating = .init(arena);
    const bad: Entry = .{ .url = "http://a/b", .parent = "http://a/", .is_dir = false, .size = 1, .mtime = "x\ty" };
    const good: Entry = .{ .url = "http://a/c", .parent = "http://a/", .is_dir = false, .size = 1, .mtime = "" };
    try Snapshot.save(&.{ good, bad }, &buf.writer);
    try std.testing.expectEqual(@as(usize, 0), buf.written().len);
}

test "paths that leave or loop within the tree are refused" {
    try std.testing.expect(escapes("a/../../x"));
    try std.testing.expect(escapes(".."));
    try std.testing.expect(escapes("./a"));
    try std.testing.expect(escapes(""));
    try std.testing.expect(escapes("a//b"));
    try std.testing.expect(!escapes("a/b/"));
    try std.testing.expect(!escapes("a.b/..c"));
    // Nor a name too long, or with a control character.
    const long: [256]u8 = @splat('x');
    try std.testing.expect(escapes("a/" ++ long));
    try std.testing.expect(!escapes("a/" ++ long[1..]));
    var deep: [21 * 201]u8 = @splat('x');
    for (1..22) |i| deep[i * 201 - 1] = '/';
    try std.testing.expect(escapes(&deep));
    try std.testing.expect(escapes("a\tb.mp4"));
    try std.testing.expect(escapes("a\x00.mp4"));
}
