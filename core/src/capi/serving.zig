//! The C interface (see ../capi.zig): serving.

const std = @import("std");
const capi = @import("../capi.zig");
const sync = @import("../sync.zig");
const Host = @import("../host.zig").Host;
const serve_ = @import("../serve.zig");
const gpa = capi.gpa;
const fail = capi.fail;
const Library = capi.Library;

/// Serving the library (and folders): the host, and what it needs that
/// outlives the call that started it.
pub const Serving = struct {
    arena: std.heap.ArenaAllocator,
    sharing: sync.Sharing,
    host: Host,
};

/// A folder to serve as a source (`cq_folder`): the path it's served at,
/// and where it is.
pub const Folder = extern struct { prefix: [*:0]const u8, path: [*:0]const u8 };

/// Long, but returns once listening: serves this library to devices (their
/// syncs) and `count` folders as sources, on `port`, else 8008, else any
/// free port; advertises it by DNS-SD; and keeps serving, on a thread of
/// its own, until `cq_stop_serving` or `cq_close`. Serving again restarts
/// it. Returns the port, or -1.
export fn cq_serve(lib: *Library, port: c_int, folders: ?[*]const Folder, count: usize) c_int {
    const given: []const Folder = if (count == 0) &.{} else if (folders) |f| f[0..count] else {
        capi.fail(error.InvalidArgument);
        return -1;
    };
    return startServing(lib, @intCast(std.math.clamp(port, 0, 65535)), given) catch |err| {
        fail(err);
        return -1;
    };
}

/// Stops serving, if it is.
export fn cq_stop_serving(lib: *Library) void {
    stopServing(lib);
}

fn startServing(lib: *Library, port: u16, folders: []const Folder) !c_int {
    stopServing(lib);
    const s = try gpa.create(Serving);
    errdefer gpa.destroy(s);
    s.arena = .init(gpa);
    errdefer s.arena.deinit();
    const arena = s.arena.allocator();
    // Copied, since they outlive the caller's strings.
    const mounts = try arena.alloc(serve_.Mount, folders.len);
    for (folders, mounts) |f, *m| m.* = .{ .prefix = try arena.dupe(u8, std.mem.span(f.prefix)), .path = try arena.dupe(u8, std.mem.span(f.path)), .index = false };
    s.sharing = .{
        .path = try lib.store.replicaPath(arena),
        .creator = try lib.store.creator(arena),
        .identity = lib.store.identity,
    };
    s.host = .{
        .io = lib.io(),
        .gpa = gpa,
        .options = .{ .host = "::", .port = if (port == 0) 8008 else port, .fallback = true, .mounts = mounts, .handler = s.sharing.handler() },
        .name = try lib.store.serviceName(arena),
        .txt = try sync.advertisement(arena, try lib.main(), try lib.store.person(), try lib.store.device()),
    };
    try s.host.start();
    lib.serving = s;
    return s.host.port;
}

pub fn stopServing(lib: *Library) void {
    const s = lib.serving orelse return;
    s.host.stop();
    s.arena.deinit();
    gpa.destroy(s);
    lib.serving = null;
}
