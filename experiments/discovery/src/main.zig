//! LAN discovery through the system's DNS-SD service (Bonjour on macOS;
//! Avahi's compatible `libdns_sd` on Linux): advertise a repository as
//! `_cinematheque._tcp` with a TXT record, then browse and resolve it, and
//! browse `_http._tcp` and `_webdav._tcp` for static servers to suggest.
//!
//! Usage: discover [seconds]

const std = @import("std");
const Io = std.Io;

const c = struct {
    const DNSServiceRef = ?*opaque {};
    const Flags = u32;
    const Error = i32;
    const flags_add: Flags = 0x2;
    const flags_more_coming: Flags = 0x1;

    const RegisterReply = *const fn (DNSServiceRef, Flags, Error, [*:0]const u8, [*:0]const u8, [*:0]const u8, ?*anyopaque) callconv(.c) void;
    const BrowseReply = *const fn (DNSServiceRef, Flags, u32, Error, [*:0]const u8, [*:0]const u8, [*:0]const u8, ?*anyopaque) callconv(.c) void;
    const ResolveReply = *const fn (DNSServiceRef, Flags, u32, Error, [*:0]const u8, [*:0]const u8, u16, u16, [*]const u8, ?*anyopaque) callconv(.c) void;

    extern "c" fn DNSServiceRegister(ref: *DNSServiceRef, flags: Flags, interface: u32, name: ?[*:0]const u8, regtype: [*:0]const u8, domain: ?[*:0]const u8, host: ?[*:0]const u8, port_be: u16, txt_len: u16, txt: ?*const anyopaque, callback: RegisterReply, context: ?*anyopaque) Error;
    extern "c" fn DNSServiceBrowse(ref: *DNSServiceRef, flags: Flags, interface: u32, regtype: [*:0]const u8, domain: ?[*:0]const u8, callback: BrowseReply, context: ?*anyopaque) Error;
    extern "c" fn DNSServiceResolve(ref: *DNSServiceRef, flags: Flags, interface: u32, name: [*:0]const u8, regtype: [*:0]const u8, domain: [*:0]const u8, callback: ResolveReply, context: ?*anyopaque) Error;
    extern "c" fn DNSServiceProcessResult(ref: DNSServiceRef) Error;
    extern "c" fn DNSServiceRefSockFD(ref: DNSServiceRef) i32;
    extern "c" fn DNSServiceRefDeallocate(ref: DNSServiceRef) void;
};

const Found = struct {
    name: [64]u8 = @splat(0),
    regtype: [64]u8 = @splat(0),
    domain: [64]u8 = @splat(0),
    interface: u32 = 0,
};

const State = struct {
    found: std.ArrayList(Found) = .empty,
    gpa: std.mem.Allocator,
    out: *Io.Writer,
    resolved: bool = false,
};

fn copyZ(dst: []u8, src: [*:0]const u8) void {
    const s = std.mem.span(src);
    const n = @min(s.len, dst.len - 1);
    @memcpy(dst[0..n], s[0..n]);
    dst[n] = 0;
}

fn onRegister(_: c.DNSServiceRef, _: c.Flags, err: c.Error, name: [*:0]const u8, regtype: [*:0]const u8, domain: [*:0]const u8, context: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(context.?));
    state.out.print("registered {s}.{s}{s} (error {d})\n", .{ name, regtype, domain, err }) catch {};
}

fn onBrowse(_: c.DNSServiceRef, flags: c.Flags, interface: u32, err: c.Error, name: [*:0]const u8, regtype: [*:0]const u8, domain: [*:0]const u8, context: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(context.?));
    if (err != 0 or flags & c.flags_add == 0) return;
    var f: Found = .{ .interface = interface };
    copyZ(&f.name, name);
    copyZ(&f.regtype, regtype);
    copyZ(&f.domain, domain);
    state.found.append(state.gpa, f) catch {};
    state.out.print("found {s} {s} on interface {d}\n", .{ name, regtype, interface }) catch {};
}

fn onResolve(_: c.DNSServiceRef, _: c.Flags, _: u32, err: c.Error, fullname: [*:0]const u8, host: [*:0]const u8, port_be: u16, txt_len: u16, txt: [*]const u8, context: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(context.?));
    state.resolved = true;
    if (err != 0) return;
    state.out.print("  resolved {s} -> {s}:{d}, TXT:", .{ fullname, host, std.mem.bigToNative(u16, port_be) }) catch {};
    // TXT records are length-prefixed strings.
    var i: usize = 0;
    while (i < txt_len) {
        const n = txt[i];
        state.out.print(" {s}", .{txt[i + 1 .. i + 1 + n]}) catch {};
        i += 1 + n;
    }
    state.out.print("\n", .{}) catch {};
}

/// Dispatches results for `ref` until `ms` milliseconds pass.
fn pump(ref: c.DNSServiceRef, ms: i64, io: Io) !void {
    const deadline = Io.Timestamp.now(io, .awake).nanoseconds + @as(i96, ms) * std.time.ns_per_ms;
    while (true) {
        const left = @divTrunc(deadline - Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms);
        if (left <= 0) return;
        var fds = [_]std.posix.pollfd{.{ .fd = c.DNSServiceRefSockFD(ref), .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, @intCast(left)) > 0) {
            if (c.DNSServiceProcessResult(ref) != 0) return error.DnsSd;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const seconds: i64 = if (args.len > 1) try std.fmt.parseInt(i64, args[1], 10) else 2;
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};
    var state: State = .{ .gpa = init.gpa, .out = out };
    defer state.found.deinit(init.gpa);

    // TXT: what a peer needs before connecting.
    const txt = "\x0bversion=0.1" ++ "\x0epath=/library/" ++ "\x0bindex=INDEX";
    var registration: c.DNSServiceRef = null;
    if (c.DNSServiceRegister(&registration, 0, 0, "perihelion", "_cinematheque._tcp", null, null, std.mem.nativeToBig(u16, 8090), txt.len, txt, onRegister, &state) != 0) return error.DnsSd;
    defer c.DNSServiceRefDeallocate(registration);
    try pump(registration, 500, io);

    const start = Io.Timestamp.now(io, .awake);
    for ([_][*:0]const u8{ "_cinematheque._tcp", "_http._tcp", "_webdav._tcp" }) |regtype| {
        var browse: c.DNSServiceRef = null;
        if (c.DNSServiceBrowse(&browse, 0, 0, regtype, null, onBrowse, &state) != 0) return error.DnsSd;
        defer c.DNSServiceRefDeallocate(browse);
        try pump(browse, seconds * 1000, io);
    }
    try out.print("browsed for {d} ms\n", .{start.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds()});

    for (state.found.items) |*f| {
        if (!std.mem.startsWith(u8, &f.regtype, "_cinematheque")) continue;
        var resolve: c.DNSServiceRef = null;
        state.resolved = false;
        if (c.DNSServiceResolve(&resolve, 0, f.interface, @ptrCast(&f.name), @ptrCast(&f.regtype), @ptrCast(&f.domain), onResolve, &state) != 0) return error.DnsSd;
        defer c.DNSServiceRefDeallocate(resolve);
        try pump(resolve, 1000, io);
    }
}
