//! Crawls a source's listings breadth-first with concurrent workers,
//! reading JSON (Caddy's form), HTML autoindex (links' targets only), or an
//! `INDEX` file.

const std = @import("std");
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
        const entities = [_]struct { []const u8, u8 }{ .{ "&amp;", '&' }, .{ "&lt;", '<' }, .{ "&gt;", '>' }, .{ "&quot;", '"' }, .{ "&#39;", '\'' } };
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

/// `fetch` into memory, at most `max_listing_bytes` of it.
fn get(arena: std.mem.Allocator, client: *http.Client, location: []const u8, extra_headers: []const http.Header) !Fetched {
    var req = try client.request(.GET, try std.Uri.parse(location), .{ .redirect_behavior = .init(3), .extra_headers = extra_headers });
    defer req.deinit();
    try req.sendBodiless();
    var redirect: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect);
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
