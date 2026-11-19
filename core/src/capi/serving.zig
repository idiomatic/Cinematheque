//! The C interface (see ../capi.zig): serving.

const std = @import("std");
const capi = @import("../capi.zig");
const library = @import("../library.zig");
const sync = @import("../sync.zig");
const Host = @import("../host.zig").Host;
const serve_ = @import("../serve.zig");
const gpa = capi.gpa;
const fail = capi.fail;
const Library = capi.Library;
const json = capi.json;
const span = capi.span;

/// Serving the library (and folders): the host, and what it needs that
/// outlives the call that started it.
pub const Serving = struct {
    arena: std.heap.ArenaAllocator,
    sharing: sync.Sharing,
    host: Host,
};

const MountJson = struct { prefix: []const u8, path: []const u8 };

/// Long, but returns once listening: serves this library to devices (their
/// syncs) and `folders_json`'s folders as sources (a JSON array of
/// objects with `prefix`, the path they're served at, and `path`), on
/// `port`, else 8008, else any free port; advertises it by DNS-SD; and
/// keeps serving, on a thread of its own, until `cq_stop_serving` or
/// `cq_close`. Serving again restarts it. Returns the port, or -1.
export fn cq_serve(lib: *Library, port: c_int, folders_json: [*:0]const u8) c_int {
    return startServing(lib, @intCast(std.math.clamp(port, 0, 65535)), std.mem.span(folders_json)) catch |err| {
        fail(err);
        return -1;
    };
}

/// Stops serving, if it is.
export fn cq_stop_serving(lib: *Library) void {
    stopServing(lib);
}

fn startServing(lib: *Library, port: u16, folders_json: []const u8) !c_int {
    stopServing(lib);
    const s = try gpa.create(Serving);
    errdefer gpa.destroy(s);
    s.arena = .init(gpa);
    errdefer s.arena.deinit();
    const arena = s.arena.allocator();
    // Copied, since they outlive the caller's string.
    const folders = try std.json.parseFromSliceLeaky([]const MountJson, arena, folders_json, .{ .allocate = .alloc_always });
    const mounts = try arena.alloc(serve_.Mount, folders.len);
    for (folders, mounts) |f, *m| m.* = .{ .prefix = f.prefix, .path = f.path, .index = false };
    s.sharing = .{
        .path = try lib.store.replicaPath(arena),
        .founder = try lib.store.founder(arena),
        .identity = lib.store.identity,
        .served = Library.onServed,
        .received = Library.onReceived,
        .context = lib,
    };
    s.host = .{
        .io = lib.io(),
        .gpa = gpa,
        .options = .{ .host = "0.0.0.0", .port = if (port == 0) 8008 else port, .fallback = true, .mounts = mounts, .handler = s.sharing.handler() },
        .name = try std.fmt.allocPrintSentinel(arena, "{s}", .{try lib.store.serviceName(arena)}, 0),
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
