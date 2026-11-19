//! Copy racing: which of an item's copies a player tries first. Each
//! copy's server is asked at once, briefly (`HEAD`, `timeout_ms`), and
//! those that answer go first, in their order, as soon as the best-placed
//! one has (or `grace_ms` after any has), so a copy on a device that's
//! asleep costs a moment rather than a network timeout; like Happy
//! Eyeballs (RFC 8305), which races a server's addresses, but over copies
//! on different servers. A server that
//! didn't answer lately (`remembered_ms`, noted in `Memory`, on this device
//! only) is asked last.
//!
//! The servers are asked as tasks of `Io`'s (an `Io.Select`, with a task
//! for the deadline), over `Io`'s networking. On Apple platforms, names are
//! looked up through DNS-SD, waiting through `Io` too, since the system's
//! resolver (getaddrinfo) can't be interrupted: a name that didn't resolve,
//! as a device's that's gone, held the race some 20 seconds past its
//! deadline, as its task was waited out.

const std = @import("std");
const Io = std.Io;

/// How long a server has to answer.
pub const timeout_ms = 1500;
/// Once one has, how much longer a better-placed one has (RFC 8305's
/// connection attempt delay): a server waking (a NAS spinning its disks
/// up) costs this, not the whole deadline, while another copy plays.
pub const grace_ms = 250;
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
    const started = Io.Timestamp.now(io, .awake);
    const buffer = try arena.alloc(Event, servers.items.len + 2);
    var select: Io.Select(Event) = .init(io, buffer);
    try select.concurrent(.deadline, deadline, .{io});
    for (servers.items, 0..) |server, i| try select.concurrent(.asked, ask, .{ io, server, i });
    const asked_at = Io.Timestamp.now(io, .awake);
    var graced = false;
    var timed_out = false;
    while (!decided(servers.items, results, candidates.items)) {
        switch (select.await() catch |err| {
            select.cancelDiscard();
            return err;
        }) {
            .asked => |a| {
                results[a.index] = if (a.answered) .yes else .no;
                if (a.answered and !graced) {
                    graced = true;
                    select.concurrent(.grace, grace, .{io}) catch {};
                }
            },
            .deadline => {
                timed_out = true;
                break;
            },
            .grace => break,
        }
    }
    const decided_at = Io.Timestamp.now(io, .awake);
    select.cancelDiscard();
    // A race that outlasts its deadline says why, and on whom it waited.
    const ms = struct {
        fn between(a: Io.Timestamp, b: Io.Timestamp) i64 {
            return @intCast(a.durationTo(b).toMilliseconds());
        }
    }.between;
    const took = ms(started, Io.Timestamp.now(io, .awake));
    if (took > timeout_ms + 500) {
        for (servers.items, results) |server, result| if (result == .unknown)
            std.log.warn("copy racing: {s} hadn't answered when the race was decided", .{server.key});
        std.log.warn("copy racing took {d} ms over {d} servers: asked in {d}, decided {d} later, then {d} winding down their tasks", .{ took, servers.items.len, ms(started, asked_at), ms(asked_at, decided_at), ms(decided_at, Io.Timestamp.now(io, .awake)) });
    }

    var first: std.ArrayList([]const u8) = .empty;
    var rest: std.ArrayList([]const u8) = .empty;
    for (candidates.items) |u| {
        // Still asking at the deadline is as good as no answer; still
        // asking when another's grace ended, only slower (waking, say).
        switch (resultOf(servers.items, results, u)) {
            .yes => try first.append(arena, u),
            .no => {
                try memory.lost(io, gpa, u, now_ms);
                try rest.append(arena, u);
            },
            .unknown => {
                if (timed_out) try memory.lost(io, gpa, u, now_ms);
                try rest.append(arena, u);
            },
        }
    }
    try first.appendSlice(arena, rest.items);
    return first.items;
}

/// Looks up each server's name in `urls` (on Apple platforms, through
/// DNS-SD), asking nothing of the servers and noting nothing, so the
/// system has the answers when a race needs them: a name's first lookup
/// may take longer than a race's deadline. Elsewhere, nothing.
pub fn warm(io: Io, arena: std.mem.Allocator, urls: []const []const u8) !void {
    if (comptime !@import("builtin").os.tag.isDarwin()) return;
    var seen: std.ArrayList([]const u8) = .empty;
    for (urls) |u| {
        const uri = std.Uri.parse(u) catch continue;
        const host = (uri.host orelse continue).toRawMaybeAlloc(arena) catch continue;
        if (Io.net.IpAddress.parse(host, 0)) |_| continue else |_| {}
        const known = for (seen.items) |h| {
            if (std.mem.eql(u8, h, host)) break true;
        } else false;
        if (known) continue;
        try seen.append(arena, host);
        const name = try arena.dupeSentinel(u8, host, 0);
        var buf: [8]Io.net.IpAddress = undefined;
        _ = @import("discover.zig").lookup(io, name, 80, 5000, &buf) catch {};
    }
}

const Result = enum { unknown, yes, no };
const Server = struct { key: []const u8, host: []const u8, port: u16, path: []const u8, tls: bool };
const Asked = struct { index: usize, answered: bool };
const Event = union(enum) { asked: Asked, deadline: void, grace: void };

fn deadline(io: Io) void {
    io.sleep(.fromMilliseconds(timeout_ms), .awake) catch {};
}

fn grace(io: Io) void {
    io.sleep(.fromMilliseconds(grace_ms), .awake) catch {};
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

/// The `HEAD` of a server's path, asking it to close once it's answered.
const head_format = "HEAD {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n";

fn headArgs(server: Server) struct { []const u8, []const u8 } {
    return .{ if (server.path.len == 0) "/" else server.path, server.host };
}

/// Whether the server answers at all (any status will do): connected to, for
/// TLS, which a status would need a handshake to read; else answering a
/// `HEAD` of its path. The race's deadline bounds it.
fn answers(io: Io, server: Server) bool {
    var buf: [8]Io.net.IpAddress = undefined;
    if (addressesOf(io, server, &buf) catch return false) |addresses| return answersAt(io, addresses, server);
    // Elsewhere, by name: Zig's own resolver, which waits through Io.
    const host = Io.net.HostName.init(server.host) catch return false;
    const stream = host.connect(io, server.port, .{ .mode = .stream }) catch return false;
    defer stream.close(io);
    if (server.tls) return true;
    var out_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    writer.interface.print(head_format, headArgs(server)) catch return false;
    writer.interface.flush() catch return false;
    var in_buf: [64]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    _ = reader.interface.takeByte() catch return false;
    return true;
}

/// The server's addresses: its own, if it's given by address; else, on
/// Apple platforms, its name's, looked up through DNS-SD, so the race's
/// deadline cancels the lookup, as it can't the system's resolver
/// (getaddrinfo); elsewhere, null.
fn addressesOf(io: Io, server: Server, buf: []Io.net.IpAddress) !?[]Io.net.IpAddress {
    if (Io.net.IpAddress.parse(server.host, server.port)) |address| {
        buf[0] = address;
        return buf[0..1];
    } else |_| {}
    if (comptime !@import("builtin").os.tag.isDarwin()) return null;
    var name: [256:0]u8 = undefined;
    if (server.host.len >= name.len) return error.NameTooLong;
    @memcpy(name[0..server.host.len], server.host);
    name[server.host.len] = 0;
    return try @import("discover.zig").lookup(io, name[0..server.host.len :0], server.port, timeout_ms, buf);
}

/// Asks the server at all its addresses at once, as Happy Eyeballs (RFC
/// 8305) does: the first to connect gets the `HEAD`. Its sockets don't
/// block; between looks, Io waits, so the race's deadline cancels it. A
/// blocking connect to an address that drops it (as an IPv6 one may, where
/// IPv4 works) held a race some 20 seconds, where Io couldn't interrupt it.
fn answersAt(io: Io, addresses: []const Io.net.IpAddress, server: Server) bool {
    const c = std.c;
    var fds: [8]c.pollfd = undefined;
    var n: usize = 0;
    defer for (fds[0..n]) |p| if (p.fd >= 0) {
        _ = c.close(p.fd);
    };
    for (addresses[0..@min(addresses.len, fds.len)]) |a| {
        fds[n] = .{ .fd = connectStart(a) orelse continue, .events = c.POLL.OUT, .revents = 0 };
        n += 1;
    }
    // The first connection made, its socket's index.
    const won: usize = connecting: while (true) {
        var open: usize = 0;
        for (fds[0..n]) |p| open += @intFromBool(p.fd >= 0);
        if (open == 0) return false;
        if (c.poll(&fds, @intCast(n), 0) > 0) for (fds[0..n], 0..) |*p, i| {
            if (p.fd < 0 or p.revents == 0) continue;
            var err: c_int = 0;
            var len: c.socklen_t = @sizeOf(c_int);
            if (c.getsockopt(p.fd, c.SOL.SOCKET, c.SO.ERROR, &err, &len) == 0 and err == 0) break :connecting i;
            _ = c.close(p.fd);
            p.fd = -1;
        };
        io.sleep(.fromMilliseconds(10), .awake) catch return false;
    };
    if (server.tls) return true;
    const fd = fds[won].fd;
    var head: [1024]u8 = undefined;
    const request = std.fmt.bufPrint(&head, head_format, headArgs(server)) catch return false;
    if (c.send(fd, request.ptr, request.len, 0) != @as(isize, @intCast(request.len))) return false;
    // Its first byte, whatever it says.
    var wait = [_]c.pollfd{.{ .fd = fd, .events = c.POLL.IN, .revents = 0 }};
    while (c.poll(&wait, 1, 0) <= 0) io.sleep(.fromMilliseconds(10), .awake) catch return false;
    var byte: [1]u8 = undefined;
    return c.recv(fd, &byte, 1, 0) == 1;
}

/// A socket connecting to `address`, without waiting for it to connect.
fn connectStart(address: Io.net.IpAddress) ?std.c.fd_t {
    const c = std.c;
    const family: c_uint = switch (address) {
        .ip4 => c.AF.INET,
        .ip6 => c.AF.INET6,
    };
    const fd = c.socket(family, c.SOCK.STREAM, 0);
    if (fd < 0) return null;
    const flags = c.fcntl(fd, c.F.GETFL);
    if (flags < 0 or c.fcntl(fd, c.F.SETFL, flags | @as(c_int, @bitCast(c.O{ .NONBLOCK = true }))) < 0) {
        _ = c.close(fd);
        return null;
    }
    const rc = switch (address) {
        .ip4 => |a| connect: {
            const sin: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, a.port), .addr = @bitCast(a.bytes) };
            break :connect c.connect(fd, @ptrCast(&sin), @sizeOf(c.sockaddr.in));
        },
        .ip6 => |a| connect: {
            const sin6: c.sockaddr.in6 = .{ .port = std.mem.nativeToBig(u16, a.port), .flowinfo = a.flow, .addr = a.bytes, .scope_id = a.interface.index };
            break :connect c.connect(fd, @ptrCast(&sin6), @sizeOf(c.sockaddr.in6));
        },
    };
    if (rc == 0 or std.posix.errno(rc) == .INPROGRESS) return fd;
    _ = c.close(fd);
    return null;
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

test "a name that doesn't resolve is passed over at the deadline, not waited out" {
    // The system's resolver would take some 20 seconds over it.
    if (comptime !@import("builtin").os.tag.isDarwin()) return error.SkipZigTest;
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
    const gone = "http://cinematheque-test-skynet-gone.local:8008/a.mp4";
    const live = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/a.mp4", .{server.port});
    const start = Io.Timestamp.now(io, .awake);
    const raced = try order(io, gpa, arena, &memory, &.{ gone, live }, 1000);
    const took = start.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds();
    try std.testing.expectEqualStrings(live, raced[0]);
    try std.testing.expect(took < timeout_ms + 500);
}

test "an address that drops connections is passed over at the deadline, not waited out" {
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
    // Routed, but nothing answers there, so a connect waits on the system's
    // TCP timeout, as one to an IPv6 address that drops it did.
    const dropped = "http://10.255.255.1:8008/a.mp4";
    const live = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/a.mp4", .{server.port});
    const start = Io.Timestamp.now(io, .awake);
    const raced = try order(io, gpa, arena, &memory, &.{ dropped, live }, 1000);
    const took = start.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds();
    try std.testing.expectEqualStrings(live, raced[0]);
    try std.testing.expect(took < timeout_ms + 500);
}

test "a .local name resolves and answers well within the deadline" {
    // This Mac's own name, through mDNS: its IPv4 answer flagged MoreComing,
    // an IPv6 one may never follow, which once held a lookup its whole time.
    if (comptime !@import("builtin").os.tag.isDarwin()) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var memory: Memory = .{};
    defer memory.deinit(gpa);
    var name_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const name = std.posix.gethostname(&name_buf) catch return error.SkipZigTest;
    // Its mDNS name: the first label, in .local ("firefly.localdomain" is
    // "firefly.local").
    const label = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
    const local = try std.fmt.allocPrint(arena, "{s}.local", .{label});
    var server: @import("host.zig").Host = .{ .io = io, .gpa = gpa, .options = .{ .host = "0.0.0.0", .port = 0 } };
    try server.start();
    defer server.stop();
    const mine = try std.fmt.allocPrint(arena, "http://{s}:{d}/a.mp4", .{ local, server.port });
    const other = "http://127.0.0.1:1/a.mp4";
    const start = Io.Timestamp.now(io, .awake);
    const raced = try order(io, gpa, arena, &memory, &.{ other, mine }, 1000);
    const took = start.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds();
    try std.testing.expectEqualStrings(mine, raced[0]);
    try std.testing.expect(took < timeout_ms / 2);
}

test "once a copy answers, a better-placed one that hasn't gets a grace, not the deadline" {
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
    // Placed first: takes the connection, never answers, as a NAS waking.
    var address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var silent = try address.listen(io, .{});
    defer silent.deinit(io);
    const waking = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/a.mp4", .{silent.socket.address.getPort()});
    const live = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/a.mp4", .{server.port});
    const start = Io.Timestamp.now(io, .awake);
    const raced = try order(io, gpa, arena, &memory, &.{ waking, live }, 1000);
    const took = start.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds();
    try std.testing.expectEqualStrings(live, raced[0]);
    try std.testing.expect(took < grace_ms + 300);
    // Only slower, it isn't noted as unanswering.
    try std.testing.expect(!memory.recent(io, waking, 1500));
}
