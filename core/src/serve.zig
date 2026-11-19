//! A source server that looks like a well-behaved static server:
//! files with byte ranges and ETags, directory listings as JSON (in Caddy's
//! form, on `Accept: application/json`) or HTML, and an `INDEX` of the tree
//! with each file's size and modification time.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const url = @import("url.zig");

/// Answers requests the server doesn't, such as a peer's `POST /sync`.
pub const Handler = struct {
    context: ?*anyopaque,
    /// Returns false to let the server answer instead.
    function: *const fn (context: ?*anyopaque, io: Io, gpa: std.mem.Allocator, request: *http.Server.Request) anyerror!bool,
};

/// A directory served as a source, at `/` (an empty prefix, as the only
/// one) or at `/<prefix>/`.
pub const Mount = struct {
    prefix: []const u8 = "",
    path: []const u8,
    /// Serve an `INDEX` of the tree, built when the server starts, so it
    /// goes stale as the tree changes; without one, crawlers read listings,
    /// which are live.
    index: bool = true,
};

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16,
    /// If `port` is taken, listen on any free port instead (reported to
    /// `on_listen`).
    fallback: bool = false,
    /// Directories to serve as sources, if any.
    mounts: []const Mount = &.{},
    handler: ?Handler = null,
    /// Called once the server listens, with the port it got.
    on_listen: ?*const fn (context: ?*anyopaque, port: u16) void = null,
    on_listen_context: ?*anyopaque = null,
    /// Set (then `wake`) to stop: the server checks it whenever `accept`
    /// returns. Canceling alone can miss a thread blocked in `accept`.
    stop: ?*const std.atomic.Value(bool) = null,
};

const Context = struct {
    io: Io,
    gpa: std.mem.Allocator,
    mounts: []Served,
    handler: ?Handler,
};

/// How old an `INDEX` may be before a request for it rebuilds it, so the
/// drives plugged in or unplugged since show.
const index_max_age_ms = 60 * 1000;

const Served = struct {
    prefix: []const u8,
    path: []const u8,
    /// Kept open if it has an `INDEX` (the command-line peer's media);
    /// else opened for each request, so a folder that goes (a share
    /// unmounted, a drive unplugged) and comes back is served as it is.
    root: ?Io.Dir,
    /// Its `INDEX`, if it has one (allocated by the server's `gpa`), its
    /// ETag, and when it was built; held while built or sent.
    index: ?[]u8,
    index_etag: [18]u8 = undefined,
    index_built_ms: i64 = 0,
    index_mutex: Io.Mutex = .init,

    /// Builds its `INDEX` afresh, if it has one and it's stale.
    fn freshen(m: *Served, io: Io, gpa: std.mem.Allocator, now_ms: i64) !void {
        const old = m.index orelse return;
        if (now_ms - m.index_built_ms < index_max_age_ms) return;
        const index = try buildIndex(io, gpa, m.root.?);
        gpa.free(old);
        m.setIndex(index, now_ms);
    }

    fn setIndex(m: *Served, index: []u8, now_ms: i64) void {
        m.index = index;
        m.index_built_ms = now_ms;
        _ = std.fmt.bufPrint(&m.index_etag, "\"{x:0>16}\"", .{std.hash.Wyhash.hash(0, index)}) catch unreachable;
    }
};

fn nowMs(io: Io) i64 {
    return @intCast(Io.Timestamp.now(io, .awake).toMilliseconds());
}

extern "c" fn socket(domain: c_uint, sock_type: c_uint, protocol: c_uint) c_int;

/// Listens on `address` with `SO_REUSEADDR` alone, so a restarted server
/// can take its port back at once, but no other process can share it. (Zig's
/// `reuse_address` also sets `SO_REUSEPORT`, which lets two servers take the
/// same port and split its connections.)
fn listen(address: Io.net.Ip4Address) !Io.net.Server {
    const c = std.c;
    const fd = socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SystemResources;
    errdefer _ = c.close(fd);
    _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    const one: c_int = 1;
    if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &one, @sizeOf(c_int)) != 0) return error.Unexpected;
    var addr: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, address.port), .addr = @bitCast(address.bytes) };
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) return switch (c.errno(@as(c_int, -1))) {
        .ADDRINUSE => error.AddressInUse,
        .ACCES => error.AccessDenied,
        else => error.Unexpected,
    };
    if (c.listen(fd, 128) != 0) return error.Unexpected;
    var len: c.socklen_t = @sizeOf(c.sockaddr.in);
    if (c.getsockname(fd, @ptrCast(&addr), &len) != 0) return error.Unexpected;
    return .{
        .socket = .{ .handle = fd, .address = .{ .ip4 = .{ .bytes = @bitCast(addr.addr), .port = std.mem.bigToNative(u16, addr.port) } } },
        .options = {},
    };
}

test "a port in use is refused, and a free one found" {
    var first = try listen(.{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 });
    defer _ = std.c.close(first.socket.handle);
    const port = first.socket.address.getPort();
    try std.testing.expect(port != 0);
    try std.testing.expectError(error.AddressInUse, listen(.{ .bytes = .{ 127, 0, 0, 1 }, .port = port }));
}

/// Serves until canceled (through `io`).
pub fn serve(io: Io, gpa: std.mem.Allocator, options: Options) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const mounts = try arena.alloc(Served, options.mounts.len);
    var opened: usize = 0;
    defer for (mounts[0..opened]) |m| {
        if (m.root) |root| root.close(io);
        if (m.index) |index| gpa.free(index);
    };
    for (options.mounts, mounts) |m, *out| {
        const root = if (m.index) try Io.Dir.cwd().openDir(io, m.path, .{ .iterate = true }) else null;
        out.* = .{ .prefix = std.mem.trim(u8, m.prefix, "/"), .path = m.path, .root = root, .index = null };
        opened += 1;
        if (root) |r| out.setIndex(try buildIndex(io, gpa, r), nowMs(io));
    }
    const ctx: Context = .{
        .io = io,
        .gpa = gpa,
        .mounts = mounts,
        .handler = options.handler,
    };

    const address = try Io.net.IpAddress.parse(options.host, options.port);
    var listener = listen(address.ip4) catch |err| switch (err) {
        error.AddressInUse => if (options.fallback)
            try listen(.{ .bytes = address.ip4.bytes, .port = 0 })
        else
            return err,
        else => return err,
    };
    defer listener.deinit(io);
    if (options.on_listen) |f| f(options.on_listen_context, listener.socket.address.getPort());
    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = try listener.accept(io);
        if (options.stop) |stop| if (stop.load(.acquire)) {
            stream.close(io);
            return;
        };
        group.concurrent(io, handle, .{ &ctx, stream }) catch |err| {
            std.log.err("connection: {t}", .{err});
            stream.close(io);
        };
    }
}

/// Wakes a server listening on `port` (on this host) from `accept`, so it
/// sees its `stop`, by connecting to it.
pub fn wake(io: Io, port: u16) void {
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    // On loopback, to a socket listening or not, connecting doesn't wait,
    // so it needs no timeout (which Zig 0.17's Io doesn't implement).
    const stream = address.connect(io, .{ .mode = .stream }) catch return;
    stream.close(io);
}

fn handle(ctx: *const Context, stream: Io.net.Stream) Io.Cancelable!void {
    const io = ctx.io;
    defer stream.close(io);
    var in_buf: [16 * 1024]u8 = undefined;
    var out_buf: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var writer = stream.writer(io, &out_buf);
    var server = http.Server.init(&reader.interface, &writer.interface);
    while (true) {
        var request = server.receiveHead() catch return;
        respond(ctx, &request) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            return;
        };
        if (!request.head.keep_alive) return;
    }
}

fn header(request: *const http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

fn respond(ctx: *const Context, request: *http.Server.Request) !void {
    if (ctx.handler) |h| if (try h.function(h.context, ctx.io, ctx.gpa, request)) return;
    var target_buf: [4096]u8 = undefined;
    const raw = request.head.target;
    const path_end = std.mem.indexOfScalar(u8, raw, '?') orelse raw.len;
    if (path_end > target_buf.len or raw.len == 0 or raw[0] != '/') return request.respond("", .{ .status = .bad_request });
    @memcpy(target_buf[0..path_end], raw[0..path_end]);
    const path = url.decode(target_buf[0..path_end]) catch return request.respond("", .{ .status = .bad_request });
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |s| if (std.mem.eql(u8, s, "..")) return request.respond("", .{ .status = .forbidden });

    // The mount, and the path within it.
    const found: struct { mount: *Served, within: []const u8 } = for (ctx.mounts) |*m| {
        if (m.prefix.len == 0) break .{ .mount = m, .within = path };
        if (path.len > m.prefix.len and std.mem.eql(u8, path[1 .. 1 + m.prefix.len], m.prefix) and (path.len == 1 + m.prefix.len or path[1 + m.prefix.len] == '/'))
            break .{ .mount = m, .within = path[1 + m.prefix.len ..] };
    } else return request.respond("not found\n", .{ .status = .not_found });
    const mount = found.mount;
    const within = if (found.within.len == 0) "/" else found.within;

    if (std.mem.eql(u8, within, "/INDEX") and mount.index != null) {
        try mount.index_mutex.lock(ctx.io);
        defer mount.index_mutex.unlock(ctx.io);
        try mount.freshen(ctx.io, ctx.gpa, nowMs(ctx.io));
        if (header(request, "if-none-match")) |tag| if (std.mem.eql(u8, tag, &mount.index_etag))
            return request.respond("", .{ .status = .not_modified, .extra_headers = &.{.{ .name = "etag", .value = &mount.index_etag }} });
        return request.respond(mount.index.?, .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
            .{ .name = "etag", .value = &mount.index_etag },
        } });
    }

    const rel = std.mem.trim(u8, within, "/");
    const json = if (header(request, "accept")) |a| std.mem.indexOf(u8, a, "application/json") != null else false;
    const opened = if (mount.root == null) Io.Dir.cwd().openDir(ctx.io, mount.path, .{ .iterate = true }) catch {
        // Not there: listed empty, as an unplugged drive's mount point is,
        // so a crawl finds it unavailable (its copies kept) rather than failing.
        if (rel.len == 0 and path[path.len - 1] == '/') return request.respond(if (json) "[]" else "<!DOCTYPE html>\n<html><body><pre>\n</pre></body></html>\n", .{ .extra_headers = &.{
            .{ .name = "content-type", .value = if (json) "application/json" else "text/html; charset=utf-8" },
        } });
        return request.respond("not found\n", .{ .status = .not_found });
    } else null;
    defer if (opened) |d| d.close(ctx.io);
    const root = mount.root orelse opened.?;
    const stat = root.statFile(ctx.io, if (rel.len == 0) "." else rel, .{}) catch
        return request.respond("not found\n", .{ .status = .not_found });
    if (stat.kind == .directory) {
        if (path[path.len - 1] != '/') {
            var location: [4100]u8 = undefined;
            return request.respond("", .{ .status = .moved_permanently, .extra_headers = &.{
                .{ .name = "location", .value = try std.fmt.bufPrint(&location, "{s}/", .{raw[0..path_end]}) },
            } });
        }
        return listing(ctx, request, root, rel, json);
    }
    return sendFile(ctx, request, root, rel, stat);
}

fn listing(ctx: *const Context, request: *http.Server.Request, root: Io.Dir, rel: []const u8, json: bool) !void {
    const io = ctx.io;
    const gpa = ctx.gpa;
    var dir = try root.openDir(io, if (rel.len == 0) "." else rel, .{ .iterate = true });
    defer dir.close(io);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var href: std.ArrayList(u8) = .empty;
    defer href.deinit(gpa);

    try out.appendSlice(gpa, if (json) "[" else "<!DOCTYPE html>\n<html><body><pre>\n<a href=\"../\">../</a>\n");
    var it = dir.iterate();
    var first = true;
    while (try it.next(io)) |entry| {
        if (entry.name[0] == '.') continue;
        const stat = try dir.statFile(io, entry.name, .{});
        const is_dir = stat.kind == .directory;
        href.clearRetainingCapacity();
        try url.encode(gpa, &href, entry.name);
        if (is_dir) try href.append(gpa, '/');
        if (json) {
            if (!first) try out.append(gpa, ',');
            first = false;
            try out.appendSlice(gpa, "{\"name\":");
            try appendJsonString(gpa, &out, entry.name);
            try out.print(gpa, ",\"size\":{d},\"url\":\"./{s}\",\"mod_time\":\"", .{ stat.size, href.items });
            try appendRfc3339(gpa, &out, stat.mtime);
            try out.print(gpa, "\",\"is_dir\":{}}}", .{is_dir});
        } else {
            try out.print(gpa, "<a href=\"{s}\">", .{href.items});
            try appendHtml(gpa, &out, entry.name);
            try out.print(gpa, "{s}</a> {d}\n", .{ if (is_dir) "/" else "", stat.size });
        }
    }
    try out.appendSlice(gpa, if (json) "]" else "</pre></body></html>\n");
    return request.respond(out.items, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = if (json) "application/json" else "text/html; charset=utf-8" },
    } });
}

fn sendFile(ctx: *const Context, request: *http.Server.Request, root: Io.Dir, rel: []const u8, stat: Io.File.Stat) !void {
    const io = ctx.io;
    var etag_buf: [48]u8 = undefined;
    const mtime: u64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s));
    const etag = try std.fmt.bufPrint(&etag_buf, "\"{x}-{x}\"", .{ mtime, stat.size });

    var start: u64 = 0;
    var len: u64 = stat.size;
    var partial = false;
    if (header(request, "range")) |range| ranged: {
        if (header(request, "if-range")) |if_range| if (!std.mem.eql(u8, if_range, etag)) break :ranged;
        const r = parseRange(range, stat.size) orelse {
            var cr: [64]u8 = undefined;
            return request.respond("", .{ .status = .range_not_satisfiable, .extra_headers = &.{
                .{ .name = "content-range", .value = try std.fmt.bufPrint(&cr, "bytes */{d}", .{stat.size}) },
            } });
        };
        start = r.start;
        len = r.len;
        partial = true;
    }

    var content_range_buf: [96]u8 = undefined;
    const content_range = try std.fmt.bufPrint(&content_range_buf, "bytes {d}-{d}/{d}", .{ start, start + len -| 1, stat.size });
    const headers = [_]http.Header{
        .{ .name = "content-type", .value = mimeType(rel) },
        .{ .name = "accept-ranges", .value = "bytes" },
        .{ .name = "etag", .value = etag },
        .{ .name = "content-range", .value = content_range },
    };
    var body_buf: [64 * 1024]u8 = undefined;
    var body = try request.respondStreaming(&body_buf, .{
        .content_length = len,
        .respond_options = .{
            .status = if (partial) .partial_content else .ok,
            .extra_headers = if (partial) &headers else headers[0..3],
        },
    });
    if (request.head.method != .HEAD and len > 0) {
        const file = try root.openFile(io, rel, .{});
        defer file.close(io);
        var file_buf: [64 * 1024]u8 = undefined;
        var file_reader = file.reader(io, &file_buf);
        try file_reader.seekTo(start);
        _ = try body.writer.sendFileAll(&file_reader, .limited64(len));
    } else {
        // No body for HEAD (copy racing's question), yet its length stands.
        body.state = .{ .content_length = 0 };
    }
    try body.end();
}

const Range = struct { start: u64, len: u64 };

/// Parses a single range: `bytes=a-b`, `bytes=a-`, or `bytes=-n`.
fn parseRange(value: []const u8, size: u64) ?Range {
    if (!std.mem.startsWith(u8, value, "bytes=")) return null;
    const spec = value["bytes=".len..];
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return null;
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
    const a = spec[0..dash];
    const b = spec[dash + 1 ..];
    if (a.len == 0) {
        const n = std.fmt.parseInt(u64, b, 10) catch return null;
        if (n == 0 or size == 0) return null;
        const len = @min(n, size);
        return .{ .start = size - len, .len = len };
    }
    const start = std.fmt.parseInt(u64, a, 10) catch return null;
    if (start >= size) return null;
    const end = if (b.len == 0) size - 1 else @min(std.fmt.parseInt(u64, b, 10) catch return null, size - 1);
    if (end < start) return null;
    return .{ .start = start, .len = end - start + 1 };
}

fn mimeType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".mp4") or std.mem.endsWith(u8, path, ".m4v")) return "video/mp4";
    if (std.mem.endsWith(u8, path, ".mkv")) return "video/x-matroska";
    return "application/octet-stream";
}

fn appendJsonString(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        0...0x1f => try out.print(gpa, "\\u{x:0>4}", .{c}),
        else => try out.append(gpa, c),
    };
    try out.append(gpa, '"');
}

fn appendHtml(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '<' => try out.appendSlice(gpa, "&lt;"),
        '>' => try out.appendSlice(gpa, "&gt;"),
        '&' => try out.appendSlice(gpa, "&amp;"),
        '"' => try out.appendSlice(gpa, "&quot;"),
        else => try out.append(gpa, c),
    };
}

fn appendRfc3339(gpa: std.mem.Allocator, out: *std.ArrayList(u8), t: Io.Timestamp) !void {
    const secs: u64 = @intCast(@divTrunc(t.nanoseconds, std.time.ns_per_s));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    try out.print(gpa, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

/// Lists every file as `path<TAB>size<TAB>mtime` (Unix seconds), one per
/// line, and every directory as `path/`, so an empty one (an unplugged
/// drive's mount point) shows it's still there.
fn buildIndex(io: Io, gpa: std.mem.Allocator, root: Io.Dir) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var walker = try root.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            try out.print(gpa, "{s}/\n", .{entry.path});
            continue;
        }
        if (entry.kind != .file) continue;
        const stat = try entry.dir.statFile(io, entry.basename, .{});
        try out.print(gpa, "{s}\t{d}\t{d}\n", .{ entry.path, stat.size, @divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s) });
    }
    return out.toOwnedSlice(gpa);
}

test "parseRange" {
    try std.testing.expectEqual(Range{ .start = 0, .len = 1 }, parseRange("bytes=0-0", 100).?);
    try std.testing.expectEqual(Range{ .start = 10, .len = 90 }, parseRange("bytes=10-", 100).?);
    try std.testing.expectEqual(Range{ .start = 80, .len = 20 }, parseRange("bytes=-20", 100).?);
    try std.testing.expectEqual(Range{ .start = 90, .len = 10 }, parseRange("bytes=90-500", 100).?);
    try std.testing.expect(parseRange("bytes=100-", 100) == null);
    try std.testing.expect(parseRange("bytes=0-1,5-6", 100) == null);
}
