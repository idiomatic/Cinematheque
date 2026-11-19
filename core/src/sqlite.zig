//! Minimal SQLite bindings: just what the replica needs.

const std = @import("std");
const Io = std.Io;

const c = struct {
    const sqlite3 = opaque {};
    const sqlite3_stmt = opaque {};

    extern "c" fn sqlite3_open(filename: [*:0]const u8, db: *?*sqlite3) c_int;
    extern "c" fn sqlite3_close_v2(db: *sqlite3) c_int;
    extern "c" fn sqlite3_busy_handler(db: *sqlite3, handler: ?*const fn (?*anyopaque, c_int) callconv(.c) c_int, arg: ?*anyopaque) c_int;
    extern "c" fn sqlite3_exec(db: *sqlite3, sql: [*:0]const u8, callback: ?*const anyopaque, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) c_int;
    extern "c" fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;
    extern "c" fn sqlite3_prepare_v2(db: *sqlite3, sql: [*]const u8, n: c_int, stmt: *?*sqlite3_stmt, tail: ?*?[*]const u8) c_int;
    extern "c" fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
    extern "c" fn sqlite3_reset(stmt: *sqlite3_stmt) c_int;
    extern "c" fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
    extern "c" fn sqlite3_bind_blob(stmt: *sqlite3_stmt, i: c_int, data: ?*const anyopaque, n: c_int, destructor: ?*const anyopaque) c_int;
    extern "c" fn sqlite3_bind_text(stmt: *sqlite3_stmt, i: c_int, data: [*]const u8, n: c_int, destructor: ?*const anyopaque) c_int;
    extern "c" fn sqlite3_bind_int64(stmt: *sqlite3_stmt, i: c_int, value: i64) c_int;
    extern "c" fn sqlite3_column_blob(stmt: *sqlite3_stmt, i: c_int) ?[*]const u8;
    extern "c" fn sqlite3_column_bytes(stmt: *sqlite3_stmt, i: c_int) c_int;
    extern "c" fn sqlite3_column_int64(stmt: *sqlite3_stmt, i: c_int) i64;
};

const ok = 0;
const row = 100;
const done = 101;

pub const Error = error{Sqlite};

pub const Db = struct {
    handle: *c.sqlite3,
    /// What the busy handler waits through, kept where SQLite can find it.
    io: *Io,

    /// How long to wait out other connections' writes (e.g., a crawl while
    /// serving) instead of failing at once, in steps of `busy_step_ms`.
    const busy_ms = 10_000;
    const busy_step_ms = 10;

    pub fn open(path: [:0]const u8, io: Io) Error!Db {
        const kept = std.heap.c_allocator.create(Io) catch return error.Sqlite;
        errdefer std.heap.c_allocator.destroy(kept);
        kept.* = io;
        var handle: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path.ptr, &handle) != ok) {
            // SQLite returns a handle even when it fails, for the error.
            if (handle) |h| _ = c.sqlite3_close_v2(h);
            return error.Sqlite;
        }
        _ = c.sqlite3_busy_handler(handle.?, busy, kept);
        return .{ .handle = handle.?, .io = kept };
    }

    /// Waits for another connection's write through `Io`, so the wait can be
    /// canceled (which gives up, failing the statement) rather than sleeping
    /// inside SQLite.
    fn busy(context: ?*anyopaque, count: c_int) callconv(.c) c_int {
        const io: *Io = @ptrCast(@alignCast(context.?));
        if (@as(i64, count) * busy_step_ms >= busy_ms) return 0;
        io.sleep(.fromMilliseconds(busy_step_ms), .awake) catch return 0;
        return 1;
    }

    pub fn close(db: Db) void {
        _ = c.sqlite3_close_v2(db.handle);
        std.heap.c_allocator.destroy(db.io);
    }

    pub fn exec(db: Db, sql: [:0]const u8) Error!void {
        if (c.sqlite3_exec(db.handle, sql.ptr, null, null, null) != ok) return db.fail();
    }

    pub fn prepare(db: Db, sql: []const u8) Error!Stmt {
        var handle: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db.handle, sql.ptr, @intCast(sql.len), &handle, null) != ok) return db.fail();
        return .{ .handle = handle.?, .db = db };
    }

    /// Returns the first column of the first row of `sql` as an integer.
    pub fn scalar(db: Db, sql: []const u8) Error!i64 {
        var stmt = try db.prepare(sql);
        defer stmt.finalize();
        if (!try stmt.step()) return error.Sqlite;
        return stmt.int(0);
    }

    fn fail(db: Db) Error {
        std.log.err("sqlite: {s}", .{c.sqlite3_errmsg(db.handle)});
        return error.Sqlite;
    }
};

/// Bound slices must outlive the next `step`, since SQLite doesn't copy them.
pub const Stmt = struct {
    handle: *c.sqlite3_stmt,
    db: Db,

    pub fn finalize(stmt: Stmt) void {
        _ = c.sqlite3_finalize(stmt.handle);
    }

    pub fn reset(stmt: Stmt) void {
        _ = c.sqlite3_reset(stmt.handle);
    }

    pub fn bindBlob(stmt: Stmt, i: c_int, value: []const u8) Error!void {
        if (c.sqlite3_bind_blob(stmt.handle, i, value.ptr, @intCast(value.len), null) != ok) return stmt.db.fail();
    }

    pub fn bindText(stmt: Stmt, i: c_int, value: []const u8) Error!void {
        if (c.sqlite3_bind_text(stmt.handle, i, value.ptr, @intCast(value.len), null) != ok) return stmt.db.fail();
    }

    pub fn bindInt(stmt: Stmt, i: c_int, value: i64) Error!void {
        if (c.sqlite3_bind_int64(stmt.handle, i, value) != ok) return stmt.db.fail();
    }

    /// Returns true when a row is ready, false when the statement is done.
    pub fn step(stmt: Stmt) Error!bool {
        return switch (c.sqlite3_step(stmt.handle)) {
            row => true,
            done => false,
            else => stmt.db.fail(),
        };
    }

    /// Valid until the next `step`, `reset`, or `finalize`.
    pub fn blob(stmt: Stmt, i: c_int) []const u8 {
        const ptr = c.sqlite3_column_blob(stmt.handle, i) orelse return &.{};
        return ptr[0..@intCast(c.sqlite3_column_bytes(stmt.handle, i))];
    }

    pub fn int(stmt: Stmt, i: c_int) i64 {
        return c.sqlite3_column_int64(stmt.handle, i);
    }
};
