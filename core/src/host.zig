//! A server on a task of its own: it starts, advertises itself by DNS-SD
//! once it listens, and stops for sure. The C interface's serving and
//! pairing, and the command-line app's, are each one.

const std = @import("std");
const Io = std.Io;
const serve_ = @import("serve.zig");
const discover = @import("discover.zig");

pub const Host = struct {
    io: Io,
    gpa: std.mem.Allocator,
    /// What to serve, and where: `on_listen` and `stop` are the host's own.
    options: serve_.Options,
    /// The DNS-SD service it advertises as, and its TXT record; none if
    /// `name` is empty.
    name: [:0]const u8 = "",
    txt: []const u8 = "",
    /// The port it got, once listening.
    port: u16 = 0,

    future: Io.Future(anyerror!void) = undefined,
    ready: Io.Event = .unset,
    failure: ?anyerror = null,
    advertisement: ?discover.Advertisement = null,
    /// Held around the advertisement, as it's made again while serving
    /// (`readvertise`) and released as serving ends.
    advertising: Io.Mutex = .init,
    stopping: std.atomic.Value(bool) = .init(false),

    /// Starts serving on a task of its own, and returns once it listens, or
    /// fails to (within 10 seconds). The host must stay put until `stop`.
    pub fn start(h: *Host) !void {
        h.future = try h.io.concurrent(run, .{h});
        h.ready.waitTimeout(h.io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } }) catch {};
        if (!h.ready.isSet() or h.failure != null) {
            const why = h.failure orelse error.Timeout;
            _ = h.future.cancel(h.io) catch {};
            return why;
        }
    }

    /// Waits while it serves, as a device that does nothing else does.
    pub fn wait(h: *Host) !void {
        return h.future.await(h.io);
    }

    /// Stops it, and waits until it has. Canceling alone can miss a thread
    /// blocked in `accept`, so it's told to stop and woken first, then
    /// canceled, which ends what it's still answering.
    pub fn stop(h: *Host) void {
        h.stopping.store(true, .release);
        if (h.port != 0) serve_.wake(h.io, h.port);
        _ = h.future.cancel(h.io) catch {};
    }

    /// Advertises it afresh, as `name` with `txt` (both kept until it next
    /// does, or stops), as a device's name or library changes while it
    /// serves (one made, joined, or left).
    pub fn readvertise(h: *Host, name: [:0]const u8, txt: []const u8) void {
        h.advertising.lockUncancelable(h.io);
        defer h.advertising.unlock(h.io);
        if (h.advertisement) |a| a.deinit();
        h.name = name;
        h.txt = txt;
        h.advertisement = discover.advertise(name, h.port, txt) catch |err| blk: {
            std.log.warn("not advertised: {t}", .{err});
            break :blk null;
        };
    }

    fn onListen(context: ?*anyopaque, port: u16) void {
        const h: *Host = @ptrCast(@alignCast(context.?));
        h.port = port;
        if (h.name.len > 0) h.readvertise(h.name, h.txt);
        h.ready.set(h.io);
    }

    fn run(h: *Host) anyerror!void {
        defer {
            h.advertising.lockUncancelable(h.io);
            if (h.advertisement) |a| a.deinit();
            h.advertisement = null;
            h.advertising.unlock(h.io);
        }
        var options = h.options;
        options.on_listen = onListen;
        options.on_listen_context = h;
        options.stop = &h.stopping;
        serve_.serve(h.io, h.gpa, options) catch |err| {
            if (!h.ready.isSet()) {
                h.failure = err;
                h.ready.set(h.io);
            }
            return err;
        };
    }
};

test "a host starts, listens, and stops" {
    var h: Host = .{ .io = std.testing.io, .gpa = std.testing.allocator, .options = .{ .port = 0 } };
    try h.start();
    try std.testing.expect(h.port != 0);
    h.stop();
}

test "a secure connection, as a browser trying HTTPS first opens, is closed at once" {
    const io = std.testing.io;
    var h: Host = .{ .io = io, .gpa = std.testing.allocator, .options = .{ .port = 0 } };
    try h.start();
    defer h.stop();
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(h.port) };
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    const started = Io.Timestamp.now(io, .awake);
    var out_buf: [16]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    // The start of a ClientHello: a handshake record, TLS 1.0's version.
    try writer.interface.writeAll(&.{ 0x16, 0x03, 0x01, 0x00, 0x2a });
    try writer.interface.flush();
    var in_buf: [16]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    try std.testing.expectError(error.EndOfStream, reader.interface.takeByte());
    try std.testing.expect(started.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds() < 5000);
}
