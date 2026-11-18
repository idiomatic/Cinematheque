//! A server on a task of its own: it starts, advertises itself by DNS-SD
//! once it listens, and stops for sure. The C interface's serving and
//! pairing, and the command-line peer's, are each one.

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

    /// Waits while it serves, as a peer that does nothing else does.
    pub fn wait(h: *Host) !void {
        return h.future.await(h.io);
    }

    /// Stops it, and waits until it has. Canceling alone can miss a thread
    /// blocked in `accept`, so it's told to stop and woken first, then
    /// canceled, which ends what it's still answering.
    pub fn stop(h: *Host) void {
        h.stopping.store(true, .release);
        if (h.port != 0) serve_.wake(h.port);
        _ = h.future.cancel(h.io) catch {};
    }

    fn onListen(context: ?*anyopaque, port: u16) void {
        const h: *Host = @ptrCast(@alignCast(context.?));
        h.port = port;
        if (h.name.len > 0) h.advertisement = discover.advertise(h.name, port, h.txt) catch |err| blk: {
            std.log.warn("not advertised: {t}", .{err});
            break :blk null;
        };
        h.ready.set(h.io);
    }

    fn run(h: *Host) anyerror!void {
        defer if (h.advertisement) |a| a.deinit();
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
