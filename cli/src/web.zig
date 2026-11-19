//! The web client, served at the root by `serve --web`: a page (and its
//! script and style, embedded) that browses the library and plays from its
//! sources, and the JSON it asks for under `/api/`. A browser has no keys of
//! its own, so it acts as this device's person: its progress, watched marks,
//! and watchlist are theirs. Anyone who can reach the port can use it, as
//! they can the media it serves.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const core = @import("core");
const Replica = core.replica.Replica;

const files = [_]struct { path: []const u8, type: []const u8, body: []const u8 }{
    .{ .path = "/", .type = "text/html; charset=utf-8", .body = @embedFile("web/index.html") },
    .{ .path = "/app.js", .type = "text/javascript; charset=utf-8", .body = @embedFile("web/app.js") },
    .{ .path = "/app.css", .type = "text/css; charset=utf-8", .body = @embedFile("web/app.css") },
};

pub const Web = struct {
    path: [:0]const u8,
    founder: [32]u8,
    identity: core.replica.Identity,
    /// Answers first (another device's sync), before the web client does.
    next: core.serve.Handler,
    /// Held around this device's own writes (progress, the watchlist), one
    /// connection writing as the device at a time.
    writer: Io.Mutex = .init,
    /// Servers whose copies didn't answer lately, for copy racing.
    racing: core.race.Memory = .{},

    pub fn handler(w: *Web) core.serve.Handler {
        return .{ .context = w, .function = respond };
    }
};

fn respond(context: ?*anyopaque, io: Io, gpa: std.mem.Allocator, request: *http.Server.Request) anyerror!bool {
    const w: *Web = @ptrCast(@alignCast(context.?));
    if (try w.next.function(w.next.context, io, gpa, request)) return true;
    const target = request.head.target;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    for (files) |f| if (std.mem.eql(u8, path, f.path) or (std.mem.eql(u8, f.path, "/") and std.mem.eql(u8, path, "/index.html"))) {
        try request.respond(f.body, .{ .extra_headers = &.{
            .{ .name = "content-type", .value = f.type },
            .{ .name = "cache-control", .value = "no-cache" },
        } });
        return true;
    };
    if (!std.mem.startsWith(u8, path, "/api/")) return false;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    api(w, io, gpa, arena, request, path["/api/".len..], query(target)) catch |err| {
        const status: http.Status = switch (err) {
            error.NoSuchTitle, error.NotFound => .not_found,
            error.Forbidden => .forbidden,
            error.BadRequest, error.SyntaxError, error.UnexpectedEndOfInput, error.InvalidCharacter, error.Overflow => .bad_request,
            else => .internal_server_error,
        };
        try request.respond(@errorName(err), .{ .status = status });
    };
    return true;
}

fn query(target: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return "";
    return target[q + 1 ..];
}

/// A query's parameter, percent-decoded, if given.
fn param(arena: std.mem.Allocator, q: []const u8, name: []const u8) !?[]const u8 {
    var pairs = std.mem.splitScalar(u8, q, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        const value = try arena.dupe(u8, pair[eq + 1 ..]);
        for (value) |*c| if (c.* == '+') {
            c.* = ' ';
        };
        return core.url.decode(value) catch error.BadRequest;
    }
    return null;
}

fn open(w: *Web, io: Io, gpa: std.mem.Allocator) !Replica {
    return Replica.open(gpa, io, w.path, w.founder, w.identity);
}

fn now(io: Io) u64 {
    return @intCast(Io.Timestamp.now(io, .real).toMilliseconds());
}

fn api(w: *Web, io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, request: *http.Server.Request, name: []const u8, q: []const u8) !void {
    const get = request.head.method == .GET or request.head.method == .HEAD;
    if (get and std.mem.eql(u8, name, "tiles")) {
        var r = try open(w, io, gpa);
        defer r.close();
        return sendJson(arena, request, .{
            .tiles = try core.views.tiles(&r, arena),
            .watchlist = try core.art.watchlist(&r, arena),
        });
    }
    if (get and std.mem.eql(u8, name, "title")) {
        var r = try open(w, io, gpa);
        defer r.close();
        return sendJson(arena, request, try core.views.title(&r, arena, try param(arena, q, "key") orelse return error.BadRequest));
    }
    if (get and std.mem.eql(u8, name, "cover")) return cover(w, io, gpa, arena, request, q);
    if (get and std.mem.eql(u8, name, "thumb")) return thumb(arena, request, try param(arena, q, "hash") orelse return error.BadRequest);
    if (request.head.method != .POST) return error.NotFound;

    var body_buf: [4096]u8 = undefined;
    const body = try request.readerExpectNone(&body_buf).allocRemaining(arena, .limited(64 * 1024));
    if (std.mem.eql(u8, name, "race")) {
        const urls = try std.json.parseFromSliceLeaky([]const []const u8, arena, body, .{});
        var r = try open(w, io, gpa);
        const allowed = try withinSources(&r, arena, urls);
        r.close();
        if (!allowed) return error.Forbidden;
        return sendJson(arena, request, try core.race.order(io, gpa, arena, &w.racing, urls, now(io)));
    }
    if (std.mem.eql(u8, name, "lost")) {
        const lost = try std.json.parseFromSliceLeaky(struct { url: []const u8 }, arena, body, .{});
        try w.racing.lost(io, gpa, lost.url, now(io));
        return sendJson(arena, request, true);
    }

    // This person's own writes.
    try w.writer.lock(io);
    defer w.writer.unlock(io);
    var r = try open(w, io, gpa);
    defer r.close();
    if (std.mem.eql(u8, name, "progress")) {
        const p = try std.json.parseFromSliceLeaky(struct { item: []const u8, position: u64, duration: u64 }, arena, body, .{});
        try core.library.setProgress(&r, arena, now(io), p.item, p.position, p.duration);
    } else if (std.mem.eql(u8, name, "watched")) {
        const p = try std.json.parseFromSliceLeaky(struct { item: []const u8, watched: bool }, arena, body, .{});
        try core.library.setWatched(&r, arena, now(io), p.item, p.watched);
    } else if (std.mem.eql(u8, name, "watchlist")) {
        const p = try std.json.parseFromSliceLeaky(struct { key: []const u8, on: bool }, arena, body, .{});
        try core.art.setWatchlisted(&r, arena, now(io), p.key, p.on);
    } else if (std.mem.eql(u8, name, "forget")) {
        const p = try std.json.parseFromSliceLeaky(struct { item: []const u8 }, arena, body, .{});
        try core.library.removeProgress(&r, arena, now(io), p.item);
    } else if (std.mem.eql(u8, name, "describe")) {
        // An episode's title, description, and duration, read from its
        // file, as the apps describe a season's as it's shown.
        const p = try std.json.parseFromSliceLeaky(struct { item: []const u8 }, arena, body, .{});
        var client: http.Client = .{ .allocator = gpa, .io = io };
        defer client.deinit();
        try core.art.describeItem(&r, arena, &client, now(io), p.item);
    } else return error.NotFound;
    return sendJson(arena, request, true);
}

fn sendJson(arena: std.mem.Allocator, request: *http.Server.Request, value: anytype) !void {
    const text = try std.json.Stringify.valueAlloc(arena, value, .{});
    try request.respond(text, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "cache-control", .value = "no-store" },
    } });
}

/// Whether every URL is within one of the library's sources, so the server
/// fetches (or asks) only what the library already names.
fn withinSources(r: *Replica, arena: std.mem.Allocator, urls: []const []const u8) !bool {
    const sources = try core.library.sources(r, arena);
    for (urls) |u| {
        for (sources) |s| {
            if (std.mem.startsWith(u8, u, s.url)) break;
        } else return false;
    }
    return true;
}

/// The largest cover a page asks for.
const max_cover_bytes = 8 << 20;

/// A cover, read from its byte range of a file on a source (which a page
/// couldn't read itself, sources answering other sites' scripts nothing),
/// cached by the browser for good: its URL names what changes it.
fn cover(w: *Web, io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, request: *http.Server.Request, q: []const u8) !void {
    const u = try param(arena, q, "url") orelse return error.BadRequest;
    const offset = try std.fmt.parseInt(u64, try param(arena, q, "offset") orelse return error.BadRequest, 10);
    const length = try std.fmt.parseInt(u64, try param(arena, q, "length") orelse return error.BadRequest, 10);
    if (length == 0 or length > max_cover_bytes) return error.BadRequest;
    {
        var r = try open(w, io, gpa);
        defer r.close();
        if (!try withinSources(&r, arena, &.{u})) return error.Forbidden;
    }
    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const range = try std.fmt.allocPrint(arena, "bytes={d}-{d}", .{ offset, offset + length - 1 });
    var req = try client.request(.GET, try std.Uri.parse(u), .{ .extra_headers = &.{.{ .name = "range", .value = range }} });
    defer req.deinit();
    try req.sendBodiless();
    var redirect: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect);
    if (response.head.status != .partial_content and response.head.status != .ok) return error.NotFound;
    var transfer: [64 * 1024]u8 = undefined;
    const bytes = try response.reader(&transfer).allocRemaining(arena, .limited(max_cover_bytes + 1));
    // A whole file, from a server that ignored the range: its cover's part.
    const image = if (response.head.status == .ok and bytes.len > length) blk: {
        if (offset + length > bytes.len) return error.NotFound;
        break :blk bytes[offset..][0..length];
    } else bytes;
    try request.respond(image, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = imageType(image) },
        .{ .name = "cache-control", .value = "max-age=31536000, immutable" },
    } });
}

fn imageType(bytes: []const u8) []const u8 {
    if (std.mem.startsWith(u8, bytes, "\x89PNG")) return "image/png";
    if (std.mem.startsWith(u8, bytes, "\xff\xd8")) return "image/jpeg";
    return "application/octet-stream";
}

/// A cover's placeholder, its ThumbHash drawn as a small bitmap (BMP, which
/// needs no compression) for the browser to scale up, as the apps do.
fn thumb(arena: std.mem.Allocator, request: *http.Server.Request, hash_base64: []const u8) !void {
    var hash: [core.thumbhash.max_len]u8 = undefined;
    const len = std.base64.standard.Decoder.calcSizeForSlice(hash_base64) catch return error.BadRequest;
    if (len > hash.len) return error.BadRequest;
    std.base64.standard.Decoder.decode(hash[0..len], hash_base64) catch return error.BadRequest;
    var rgba: [core.thumbhash.max_pixels * 4]u8 = undefined;
    const rendered = core.thumbhash.decode(hash[0..len], &rgba) catch return error.BadRequest;
    try request.respond(try bmp(arena, rendered.width, rendered.height, &rgba), .{ .extra_headers = &.{
        .{ .name = "content-type", .value = "image/bmp" },
        .{ .name = "cache-control", .value = "max-age=31536000, immutable" },
    } });
}

/// RGBA pixels as a 24-bit BMP: a 54-byte header, then rows bottom-up, each
/// blue, green, red, padded to 4 bytes. (Placeholders are opaque.)
fn bmp(arena: std.mem.Allocator, width: usize, height: usize, rgba: []const u8) ![]u8 {
    const row = (width * 3 + 3) & ~@as(usize, 3);
    const size = 54 + row * height;
    const out = try arena.alloc(u8, size);
    @memset(out, 0);
    out[0] = 'B';
    out[1] = 'M';
    std.mem.writeInt(u32, out[2..6], @intCast(size), .little);
    std.mem.writeInt(u32, out[10..14], 54, .little);
    std.mem.writeInt(u32, out[14..18], 40, .little);
    std.mem.writeInt(i32, out[18..22], @intCast(width), .little);
    std.mem.writeInt(i32, out[22..26], @intCast(height), .little);
    std.mem.writeInt(u16, out[26..28], 1, .little);
    std.mem.writeInt(u16, out[28..30], 24, .little);
    std.mem.writeInt(u32, out[34..38], @intCast(row * height), .little);
    for (0..height) |y| {
        const dst = out[54 + (height - 1 - y) * row ..];
        for (0..width) |x| {
            const p = rgba[(y * width + x) * 4 ..];
            dst[x * 3] = p[2];
            dst[x * 3 + 1] = p[1];
            dst[x * 3 + 2] = p[0];
        }
    }
    return out;
}

test "a bitmap's header and pixels" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rgba = [_]u8{ 255, 0, 0, 255, 0, 0, 255, 255 };
    const b = try bmp(arena_state.allocator(), 2, 1, &rgba);
    try std.testing.expectEqual(@as(usize, 54 + 8), b.len);
    try std.testing.expectEqualSlices(u8, "BM", b[0..2]);
    // Red, then blue, as blue-green-red triples.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255, 0, 0 }, b[54..60]);
}
