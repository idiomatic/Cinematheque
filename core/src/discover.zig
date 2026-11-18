//! LAN discovery through the system's DNS-SD service: Bonjour on macOS
//! (in libSystem), and Avahi's compatibility library (`libdns_sd`) on Linux.

const std = @import("std");
const Io = std.Io;

pub const service_type = "_cinematheque._tcp";

const c = struct {
    const DNSServiceRef = ?*opaque {};
    const Flags = u32;
    const Error = i32;
    const flags_add: Flags = 0x2;

    const RegisterReply = *const fn (DNSServiceRef, Flags, Error, [*:0]const u8, [*:0]const u8, [*:0]const u8, ?*anyopaque) callconv(.c) void;
    const BrowseReply = *const fn (DNSServiceRef, Flags, u32, Error, [*:0]const u8, [*:0]const u8, [*:0]const u8, ?*anyopaque) callconv(.c) void;
    const ResolveReply = *const fn (DNSServiceRef, Flags, u32, Error, [*:0]const u8, [*:0]const u8, u16, u16, [*]const u8, ?*anyopaque) callconv(.c) void;

    extern "c" fn DNSServiceRegister(ref: *DNSServiceRef, flags: Flags, interface: u32, name: ?[*:0]const u8, regtype: [*:0]const u8, domain: ?[*:0]const u8, host: ?[*:0]const u8, port_be: u16, txt_len: u16, txt: ?*const anyopaque, callback: ?RegisterReply, context: ?*anyopaque) Error;
    extern "c" fn DNSServiceBrowse(ref: *DNSServiceRef, flags: Flags, interface: u32, regtype: [*:0]const u8, domain: ?[*:0]const u8, callback: BrowseReply, context: ?*anyopaque) Error;
    extern "c" fn DNSServiceResolve(ref: *DNSServiceRef, flags: Flags, interface: u32, name: [*:0]const u8, regtype: [*:0]const u8, domain: [*:0]const u8, callback: ResolveReply, context: ?*anyopaque) Error;
    extern "c" fn DNSServiceProcessResult(ref: DNSServiceRef) Error;
    extern "c" fn DNSServiceRefSockFD(ref: DNSServiceRef) i32;
    extern "c" fn DNSServiceRefDeallocate(ref: DNSServiceRef) void;
};

/// A registration, kept as long as the service runs.
pub const Advertisement = struct {
    ref: c.DNSServiceRef,

    pub fn deinit(a: Advertisement) void {
        c.DNSServiceRefDeallocate(a.ref);
    }
};

/// Builds a TXT record of `key=value` strings, each length-prefixed.
pub fn txtRecord(arena: std.mem.Allocator, pairs: []const [2][]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (pairs) |pair| {
        const len = pair[0].len + 1 + pair[1].len;
        if (len > 255) return error.TxtTooLong;
        try out.append(arena, @intCast(len));
        try out.print(arena, "{s}={s}", .{ pair[0], pair[1] });
    }
    return out.items;
}

pub fn advertise(name: [:0]const u8, port: u16, txt: []const u8) !Advertisement {
    var ref: c.DNSServiceRef = null;
    if (c.DNSServiceRegister(&ref, 0, 0, name.ptr, service_type, null, null, std.mem.nativeToBig(u16, port), @intCast(txt.len), txt.ptr, null, null) != 0)
        return error.DnsSd;
    return .{ .ref = ref };
}

pub const Service = struct {
    name: []const u8,
    host: []const u8,
    port: u16,
    txt: []const u8,

    /// The value of `key` in the TXT record.
    pub fn get(s: Service, key: []const u8) ?[]const u8 {
        var i: usize = 0;
        while (i < s.txt.len) {
            const n = s.txt[i];
            if (i + 1 + n > s.txt.len) return null;
            const entry = s.txt[i + 1 ..][0..n];
            if (entry.len > key.len and std.mem.startsWith(u8, entry, key) and entry[key.len] == '=') return entry[key.len + 1 ..];
            i += 1 + n;
        }
        return null;
    }
};

const Found = struct { name: [:0]const u8, regtype: [:0]const u8, domain: [:0]const u8, interface: u32 };

const State = struct {
    arena: std.mem.Allocator,
    found: std.ArrayList(Found) = .empty,
    services: std.ArrayList(Service) = .empty,
    err: ?anyerror = null,
};

fn onBrowse(_: c.DNSServiceRef, flags: c.Flags, interface: u32, err: c.Error, name: [*:0]const u8, regtype: [*:0]const u8, domain: [*:0]const u8, context: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(context.?));
    if (err != 0 or flags & c.flags_add == 0) return;
    // A service appears once per interface; keep the first.
    for (state.found.items) |f| if (std.mem.eql(u8, f.name, std.mem.span(name))) return;
    const f: Found = .{
        .name = state.arena.dupeSentinel(u8, std.mem.span(name), 0) catch |e| return fail(state, e),
        .regtype = state.arena.dupeSentinel(u8, std.mem.span(regtype), 0) catch |e| return fail(state, e),
        .domain = state.arena.dupeSentinel(u8, std.mem.span(domain), 0) catch |e| return fail(state, e),
        .interface = interface,
    };
    state.found.append(state.arena, f) catch |e| return fail(state, e);
}

fn onResolve(_: c.DNSServiceRef, _: c.Flags, _: u32, err: c.Error, _: [*:0]const u8, host: [*:0]const u8, port_be: u16, txt_len: u16, txt: [*]const u8, context: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(context.?));
    if (err != 0) return;
    const name = state.found.items[state.services.items.len].name;
    state.services.append(state.arena, .{
        .name = name,
        .host = state.arena.dupe(u8, std.mem.trimEnd(u8, std.mem.span(host), ".")) catch |e| return fail(state, e),
        .port = std.mem.bigToNative(u16, port_be),
        .txt = state.arena.dupe(u8, txt[0..txt_len]) catch |e| return fail(state, e),
    }) catch |e| return fail(state, e);
}

fn fail(state: *State, err: anyerror) void {
    state.err = err;
}

/// Dispatches results for `ref` for `ms` milliseconds, or until `done`.
fn pump(io: Io, ref: c.DNSServiceRef, ms: i64, state: *const State, done: ?usize) !void {
    const deadline = Io.Timestamp.now(io, .awake).nanoseconds + @as(i96, ms) * std.time.ns_per_ms;
    while (true) {
        if (done) |n| if (state.services.items.len >= n) return;
        const left = @divTrunc(deadline - Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms);
        if (left <= 0) return;
        // Whether a result is waiting, without waiting (Io has no wait on a
        // foreign socket); between looks, Io waits, so it can be canceled.
        var fds = [_]std.posix.pollfd{.{ .fd = c.DNSServiceRefSockFD(ref), .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, 0) > 0) {
            if (c.DNSServiceProcessResult(ref) != 0) return error.DnsSd;
        } else {
            try io.sleep(.fromMilliseconds(@intCast(@min(left, 10))), .awake);
        }
        if (state.err) |e| return e;
    }
}

/// Browses for Cinematheque peers for `ms` milliseconds, then resolves each.
pub fn browse(io: Io, arena: std.mem.Allocator, ms: i64) ![]Service {
    var state: State = .{ .arena = arena };
    var ref: c.DNSServiceRef = null;
    if (c.DNSServiceBrowse(&ref, 0, 0, service_type, null, onBrowse, &state) != 0) return error.DnsSd;
    defer c.DNSServiceRefDeallocate(ref);
    try pump(io, ref, ms, &state, null);
    for (state.found.items, 0..) |f, i| {
        var resolve: c.DNSServiceRef = null;
        if (c.DNSServiceResolve(&resolve, 0, f.interface, f.name.ptr, f.regtype.ptr, f.domain.ptr, onResolve, &state) != 0) return error.DnsSd;
        defer c.DNSServiceRefDeallocate(resolve);
        try pump(io, resolve, 2000, &state, i + 1);
        // A service that didn't resolve keeps the list aligned with an empty host.
        if (state.services.items.len == i) try state.services.append(arena, .{ .name = f.name, .host = "", .port = 0, .txt = "" });
    }
    return state.services.items;
}

test "TXT records round-trip" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const txt = try txtRecord(arena_state.allocator(), &.{ .{ "library", "abc" }, .{ "path", "/sync" } });
    const s: Service = .{ .name = "x", .host = "h", .port = 1, .txt = txt };
    try std.testing.expectEqualStrings("abc", s.get("library").?);
    try std.testing.expectEqualStrings("/sync", s.get("path").?);
    try std.testing.expect(s.get("lib") == null);
}
