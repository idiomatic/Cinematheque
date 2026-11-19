//! Copy racing: which of an item's copies a player tries first. Each
//! copy's server is asked at once, briefly (`HEAD`, `timeout_ms`), and
//! those that answer go first, in their order, as soon as the best-placed
//! one has, so a copy on a device that's asleep costs a second or so rather
//! than a network timeout; like Happy Eyeballs (RFC 8305), which races a
//! server's addresses, but over copies on different servers. A server that
//! didn't answer lately (`remembered_ms`, noted in `Memory`, on this device
//! only) is asked last.
//!
//! The servers are asked as tasks of `Io`'s (an `Io.Select`, with a task
//! for the deadline), over `Io`'s networking. A name lookup can't be
//! interrupted where the system's resolver can't (on macOS, getaddrinfo),
//! so a race may outlast its deadline while one finishes.

const std = @import("std");
const Io = std.Io;

/// How long a server has to answer.
pub const timeout_ms = 1500;
/// How long a server that didn't answer is asked last.
pub const remembered_ms = 10 * 60 * 1000;

/// Servers (`host:port`) that didn't answer lately, and when. Any thread.
pub const Memory = struct {
    mutex: Io.Mutex = .init,
    failed: std.StringHashMapUnmanaged(u64) = .empty,

    pub fn deinit(m: *Memory, gpa: std.mem.Allocator) void {
        var keys = m.failed.keyIterator();
        while (keys.next()) |k| gpa.free(k.*);
        m.failed.deinit(gpa);
    }

    /// Notes that `url`'s server didn't answer, or its copy didn't load.
    pub fn lost(m: *Memory, io: Io, gpa: std.mem.Allocator, url: []const u8, now_ms: u64) !void {
        var buf: [300]u8 = undefined;
        const server = serverOf(&buf, url) orelse return;
        m.mutex.lockUncancelable(io);
        defer m.mutex.unlock(io);
        const gop = try m.failed.getOrPut(gpa, server);
        if (!gop.found_existing) gop.key_ptr.* = try gpa.dupe(u8, server);
        gop.value_ptr.* = now_ms;
    }

    fn recent(m: *Memory, io: Io, url: []const u8, now_ms: u64) bool {
        var buf: [300]u8 = undefined;
        const server = serverOf(&buf, url) orelse return false;
        m.mutex.lockUncancelable(io);
        defer m.mutex.unlock(io);
        const at = m.failed.get(server) orelse return false;
        return now_ms -| at < remembered_ms;
    }
};

/// `urls` in the order to try them: those whose servers answer, first, in
/// their order; then the rest, in theirs (any lately unanswered last).
pub fn order(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, memory: *Memory, urls: []const []const u8, now_ms: u64) ![]const []const u8 {
    if (urls.len < 2) return urls;
    var candidates: std.ArrayList([]const u8) = .empty;
    for (urls) |u| if (!memory.recent(io, u, now_ms)) try candidates.append(arena, u);
    for (urls) |u| if (memory.recent(io, u, now_ms)) try candidates.append(arena, u);

    // Each server once.
    var servers: std.ArrayList(Server) = .empty;
    for (candidates.items) |u| {
        var buf: [300]u8 = undefined;
        const key = serverOf(&buf, u) orelse continue;
        if (indexOf(servers.items, key) != null) continue;
        const uri = std.Uri.parse(u) catch continue;
        const tls = std.mem.eql(u8, uri.scheme, "https");
        try servers.append(arena, .{
            .key = try arena.dupe(u8, key),
            .host = try (uri.host orelse continue).toRawMaybeAlloc(arena),
            .port = uri.port orelse if (tls) 443 else 80,
            .path = try std.fmt.allocPrint(arena, "{f}", .{uri.fmt(.{ .path = true, .query = true })}),
            .tls = tls,
        });
    }
    const results = try arena.alloc(Result, servers.items.len);
    @memset(results, .unknown);

    // Asked at once, with a deadline, until the best-placed server that
    // might answer has, or the deadline passes.
    const buffer = try arena.alloc(Event, servers.items.len + 1);
    var select: Io.Select(Event) = .init(io, buffer);
    defer select.cancelDiscard();
    try select.concurrent(.deadline, deadline, .{io});
    for (servers.items, 0..) |server, i| try select.concurrent(.asked, ask, .{ io, server, i });
    while (!decided(servers.items, results, candidates.items)) {
        switch (try select.await()) {
            .asked => |a| results[a.index] = if (a.answered) .yes else .no,
            .deadline => break,
        }
    }

    var first: std.ArrayList([]const u8) = .empty;
    var rest: std.ArrayList([]const u8) = .empty;
    for (candidates.items) |u| {
        // Still asking at the deadline is as good as no answer.
        if (resultOf(servers.items, results, u) == .yes) {
            try first.append(arena, u);
        } else {
            try memory.lost(io, gpa, u, now_ms);
            try rest.append(arena, u);
        }
    }
    try first.appendSlice(arena, rest.items);
    return first.items;
}

const Result = enum { unknown, yes, no };
const Server = struct { key: []const u8, host: []const u8, port: u16, path: []const u8, tls: bool };
const Asked = struct { index: usize, answered: bool };
const Event = union(enum) { asked: Asked, deadline: void };

fn deadline(io: Io) void {
    io.sleep(.fromMilliseconds(timeout_ms), .awake) catch {};
}

fn ask(io: Io, server: Server, index: usize) Asked {
    return .{ .index = index, .answered = answers(io, server) };
}

fn indexOf(servers: []const Server, key: []const u8) ?usize {
    for (servers, 0..) |s, i| if (std.mem.eql(u8, s.key, key)) return i;
    return null;
}

fn resultOf(servers: []const Server, results: []const Result, url: []const u8) Result {
    var buf: [300]u8 = undefined;
    const key = serverOf(&buf, url) orelse return .no;
    return results[indexOf(servers, key) orelse return .no];
}

/// Whether the best-placed copy whose server might answer has one that did:
/// none placed before it can do better.
fn decided(servers: []const Server, results: []const Result, urls: []const []const u8) bool {
    for (urls) |u| switch (resultOf(servers, results, u)) {
        .yes => return true,
        .no => continue,
        .unknown => return false,
    };
    return true;
}

/// A URL's server, `host:port`, written into `buf`.
fn serverOf(buf: []u8, url: []const u8) ?[]const u8 {
    const uri = std.Uri.parse(url) catch return null;
    const host = uri.host orelse return null;
    var host_buf: [256]u8 = undefined;
    const name = host.toRaw(&host_buf) catch return null;
    const port = uri.port orelse if (std.mem.eql(u8, uri.scheme, "https")) @as(u16, 443) else 80;
    return std.fmt.bufPrint(buf, "{s}:{d}", .{ name, port }) catch null;
}

/// Whether the server answers at all (any status will do): connected to, for
/// TLS, which a status would need a handshake to read; else answering a
/// `HEAD` of its path. The race's deadline bounds it.
fn answers(io: Io, server: Server) bool {
    const host = Io.net.HostName.init(server.host) catch return false;
    const stream = host.connect(io, server.port, .{ .mode = .stream }) catch return false;
    defer stream.close(io);
    if (server.tls) return true;
    var out_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    writer.interface.print("HEAD {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ if (server.path.len == 0) "/" else server.path, server.host }) catch return false;
    writer.interface.flush() catch return false;
    var in_buf: [64]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    _ = reader.interface.takeByte() catch return false;
    return true;
}

test "copies whose servers answer go first, and one that doesn't is remembered" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var memory: Memory = .{};
    defer memory.deinit(gpa);

    var server: @import("host.zig").Host = .{ .io = io, .gpa = gpa, .options = .{ .port = 0 } };
    try server.start();
    defer server.stop();
    // A port nothing listens on, then the server.
    const dead = "http://127.0.0.1:1/a.mp4";
    const live = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/a.mp4", .{server.port});
    const ordered = try order(io, gpa, arena, &memory, &.{ dead, live }, 1000);
    try std.testing.expectEqualStrings(live, ordered[0]);
    try std.testing.expectEqualStrings(dead, ordered[1]);
    try std.testing.expect(memory.recent(io, dead, 2000));
    try std.testing.expect(!memory.recent(io, dead, 2000 + remembered_ms));

    // One that takes the connection but never answers, as a device asleep may
    // not, is passed over at the deadline, not waited on.
    var address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var silent = try address.listen(io, .{});
    defer silent.deinit(io);
    const mute = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/a.mp4", .{silent.socket.address.getPort()});
    const start = Io.Timestamp.now(io, .awake);
    const raced = try order(io, gpa, arena, &memory, &.{ mute, live }, 3000);
    const took = start.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds();
    try std.testing.expectEqualStrings(live, raced[0]);
    try std.testing.expect(took < timeout_ms + 500);
}
