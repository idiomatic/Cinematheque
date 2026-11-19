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
    pub fn save(entries: []const Entry, w: *Io.Writer) !void {
        for (entries) |e| try w.print("{s}\t{s}\t{s}\t{d}\t{s}\n", .{ e.url, e.parent, if (e.is_dir) "d" else "f", e.size, e.mtime });
    }

    pub fn load(arena: std.mem.Allocator, text: []const u8) ![]Entry {
        var entries: std.ArrayList(Entry) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var f = std.mem.splitScalar(u8, line, '\t');
            try entries.append(arena, .{
                .url = f.next() orelse return error.Malformed,
                .parent = f.next() orelse return error.Malformed,
                .is_dir = std.mem.eql(u8, f.next() orelse return error.Malformed, "d"),
                .size = try std.fmt.parseInt(u64, f.next() orelse return error.Malformed, 10),
                .mtime = f.next() orelse "",
            });
        }
        return entries.items;
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
        r.size += o.size;
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
        var body: Io.Writer.Allocating = .init(w.arena);
        const json = w.format == .json;
        // A server may close a pooled keep-alive connection between
        // requests (e.g., Apache after 100), so retry on a fresh one.
        var attempts: usize = 0;
        const status = while (true) : (attempts += 1) {
            body.clearRetainingCapacity();
            break (w.client.fetch(.{
                .location = .{ .url = dir },
                .response_writer = &body.writer,
                .extra_headers = if (json) &.{.{ .name = "accept", .value = "application/json" }} else &.{},
            }) catch |err| switch (err) {
                error.HttpConnectionClosing, error.ConnectionResetByPeer, error.ReadFailed, error.WriteFailed => {
                    if (attempts == 3) return err;
                    w.result.retries += 1;
                    continue;
                },
                else => return err,
            }).status;
        };
        if (status != .ok) {
            std.log.err("{s}: {d}", .{ dir, @intFromEnum(status) });
            return statusError(status);
        }
        const text = body.written();
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
            href.clearRetainingCapacity();
            try href.appendSlice(w.arena, dir);
            // Caddy ends directories' names with a slash.
            try url.encode(w.arena, &href, std.mem.trimEnd(u8, item.name, "/"));
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
                std.mem.eql(u8, href, "..") or std.mem.startsWith(u8, href, "../") or
                std.mem.indexOf(u8, href, "://") != null) continue;
            const target = try unescapeHtml(w.arena, if (std.mem.startsWith(u8, href, "./")) href[2..] else href);
            if (target.len == 0) continue;
            const is_dir = target[target.len - 1] == '/';
            try w.found(try std.mem.concat(w.arena, u8, &.{ dir, target }), dir, is_dir, 0, "");
        }
    }

    fn found(w: *Worker, target: []const u8, parent: []const u8, is_dir: bool, size: u64, mtime: []const u8) !void {
        try w.entries.append(w.arena, .{ .url = target, .parent = parent, .is_dir = is_dir, .size = size, .mtime = mtime });
        if (is_dir) {
            w.result.dirs += 1;
            try w.next.append(w.arena, .{ .url = target, .mtime = mtime });
        } else {
            w.result.files += 1;
            w.result.size += size;
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
    while (level.len > 0) {
        var group: Io.Group = .init;
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
            try next.appendSlice(arena, w.next.items);
            if (entries) |e| try e.appendSlice(arena, w.entries.items);
        }
        level = next.items;
    }
    return result;
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
    var body: Io.Writer.Allocating = .init(arena);
    const status = (try client.fetch(.{
        .location = .{ .url = base },
        .response_writer = &body.writer,
        .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
    })).status;
    if (status != .ok) return statusError(status);
    const text = std.mem.trimStart(u8, body.written(), " \t\r\n");
    return if (text.len > 0 and text[0] == '[') .json else .html;
}

/// Reads the source's `INDEX`, if it has one: a path per line, relative
/// to the base (as `find .` writes them, `./` and all), optionally followed
/// by a tab, the size, a tab, and the modification time. Returns null when
/// there's none.
fn crawlIndex(arena: std.mem.Allocator, client: *http.Client, base: []const u8, entries: ?*std.ArrayList(Entry)) !?Result {
    var body: Io.Writer.Allocating = .init(arena);
    const status = (try client.fetch(.{
        .location = .{ .url = try std.mem.concat(arena, u8, &.{ base, "INDEX" }) },
        .response_writer = &body.writer,
    })).status;
    if (status == .not_found) return null;
    if (status != .ok) return statusError(status);
    var result: Result = .{ .requests = 1, .listing_bytes = body.written().len };
    var lines = std.mem.splitScalar(u8, body.written(), '\n');
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
            result.size += size;
            if (result.sample == null) result.sample = href.items;
        }
        if (entries) |e| try e.append(arena, .{ .url = href.items, .parent = href.items[0..parent_len], .is_dir = is_dir, .size = size, .mtime = mtime });
    }
    return result;
}
