//! A peer's home directory: its identity (`identity`, a random seed from
//! which its device keys derive, and `user`, its user's seed, shared with the
//! user's other devices, or else derived from the device's), the founder of
//! its library, and its replica.

const std = @import("std");
const Io = std.Io;
const replica_ = @import("replica.zig");
const Replica = replica_.Replica;

/// A peer's home unless told otherwise: in Application Support on macOS,
/// and in the XDG data directory elsewhere.
pub fn defaultHome(arena: std.mem.Allocator, home: []const u8, xdg_data_home: ?[]const u8) ![]const u8 {
    if (@import("builtin").os.tag == .macos)
        return std.fmt.allocPrint(arena, "{s}/Library/Application Support/Cinematheque", .{home});
    if (xdg_data_home) |data| if (data.len > 0)
        return std.fmt.allocPrint(arena, "{s}/cinematheque", .{data});
    return std.fmt.allocPrint(arena, "{s}/.local/share/cinematheque", .{home});
}

pub const Store = struct {
    io: Io,
    gpa: std.mem.Allocator,
    dir: []const u8,
    identity: replica_.Identity,

    /// Opens `dir`, creating it and a new identity if need be.
    pub fn open(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, dir: []const u8) !Store {
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, dir);
        const file = try path(arena, dir, "identity");
        var seed: [32]u8 = undefined;
        if (cwd.readFileAlloc(io, file, arena, .limited(128))) |text| {
            _ = try std.fmt.hexToBytes(&seed, std.mem.trim(u8, text, " \n"));
        } else |_| {
            io.random(&seed);
            try cwd.writeFile(io, .{ .sub_path = file, .data = &std.fmt.bytesToHex(seed, .lower) });
        }
        var identity: replica_.Identity = .from(seed);
        if (cwd.readFileAlloc(io, try path(arena, dir, "user"), arena, .limited(128))) |text| {
            _ = try std.fmt.hexToBytes(&identity.user, std.mem.trim(u8, text, " \n"));
        } else |_| {}
        return .{ .io = io, .gpa = gpa, .dir = dir, .identity = identity };
    }

    /// The user's seed, to link another device as this user. It's a secret:
    /// whoever has it acts as this user.
    pub fn userSecret(s: *const Store) [64]u8 {
        return std.fmt.bytesToHex(s.identity.user, .lower);
    }

    /// Makes this device act as the user whose secret `hex` is, before it
    /// opens or joins a library.
    pub fn link(s: *Store, arena: std.mem.Allocator, hex: []const u8) !void {
        if (Io.Dir.cwd().access(s.io, try path(arena, s.dir, "replica.db"), .{})) |_| return error.AlreadyInUse else |_| {}
        const secret = try parseKey(hex);
        try Io.Dir.cwd().writeFile(s.io, .{ .sub_path = try path(arena, s.dir, "user"), .data = &std.fmt.bytesToHex(secret, .lower) });
        s.identity.user = secret;
    }

    fn path(arena: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
    }

    pub fn user(s: *const Store) ![32]u8 {
        return (try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(s.identity.user)).public_key.toBytes();
    }

    pub fn founder(s: *const Store, arena: std.mem.Allocator) ![32]u8 {
        const text = Io.Dir.cwd().readFileAlloc(s.io, try path(arena, s.dir, "library"), arena, .limited(128)) catch return error.NoLibrary;
        return parseKey(std.mem.trim(u8, text, " \n"));
    }

    /// Records the library this peer belongs to, by its founder's key.
    pub fn setFounder(s: *const Store, arena: std.mem.Allocator, key: [32]u8) !void {
        const file = try path(arena, s.dir, "library");
        if (Io.Dir.cwd().access(s.io, file, .{})) |_| return error.LibraryExists else |_| {}
        try Io.Dir.cwd().writeFile(s.io, .{ .sub_path = file, .data = &std.fmt.bytesToHex(key, .lower) });
    }

    pub fn replicaPath(s: *const Store, arena: std.mem.Allocator) ![:0]u8 {
        return std.fmt.allocPrintSentinel(arena, "{s}/replica.db", .{s.dir}, 0);
    }

    pub fn openReplica(s: *const Store, arena: std.mem.Allocator) !Replica {
        return Replica.open(s.gpa, try s.replicaPath(arena), try s.founder(arena), s.identity);
    }
};

pub fn parseKey(hex: []const u8) ![32]u8 {
    var key: [32]u8 = undefined;
    if (hex.len != 64) return error.BadKey;
    _ = std.fmt.hexToBytes(&key, hex) catch return error.BadKey;
    return key;
}
