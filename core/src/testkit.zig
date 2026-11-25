//! What tests share: a replica in memory, and a temporary folder served
//! over HTTP. Only tests import it.

const std = @import("std");
const replica_ = @import("replica.zig");
const Replica = replica_.Replica;
const Host = @import("host.zig").Host;
const serve_ = @import("serve.zig");

/// A replica in memory of a library person 1 founded, as the device whose
/// seed is `device`'s bytes (device 1 being the founder's own).
pub fn replica(device: u8) !Replica {
    const creator = (try replica_.personKeyPair(@splat(1))).public_key.toBytes();
    return Replica.open(std.testing.allocator, std.testing.io, ":memory:", creator, .from(@splat(device)));
}

/// A temporary folder, its `sub` folder served (or all of it, if empty)
/// without an INDEX, so listings stay live, and a client to fetch with.
pub const Served = struct {
    tmp: std.testing.TmpDir,
    /// The folder's path.
    root: []const u8,
    mount: [1]serve_.Mount,
    server: Host,
    client: std.http.Client,
    /// Where it's served, ending in `/`.
    url: []const u8,

    /// Starts serving; the arena holds it, so it's stopped before the
    /// arena goes.
    pub fn start(arena: std.mem.Allocator, sub: []const u8) !*Served {
        const io = std.testing.io;
        const gpa = std.testing.allocator;
        const s = try arena.create(Served);
        s.tmp = std.testing.tmpDir(.{});
        errdefer s.tmp.cleanup();
        s.root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{s.tmp.sub_path});
        if (sub.len > 0) try s.tmp.dir.createDirPath(io, sub);
        s.mount = .{.{ .path = if (sub.len > 0) try std.fmt.allocPrint(arena, "{s}/{s}", .{ s.root, sub }) else s.root, .index = false }};
        s.server = .{ .io = io, .gpa = gpa, .options = .{ .port = 0, .mounts = &s.mount } };
        try s.server.start();
        s.client = .{ .allocator = gpa, .io = io };
        s.url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/", .{s.server.port});
        return s;
    }

    pub fn stop(s: *Served) void {
        s.client.deinit();
        s.server.stop();
        s.tmp.cleanup();
    }
};
