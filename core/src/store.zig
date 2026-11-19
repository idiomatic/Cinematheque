//! A device's data directory: its identity (`identity`, a random seed from
//! which its device keys derive, and `user`, its person's seed, shared with the
//! person's other devices, or else derived from the device's), the founder of
//! its library, and its replica.

const std = @import("std");
const Io = std.Io;
const replica_ = @import("replica.zig");
const Replica = replica_.Replica;

/// A device's data directory unless told otherwise: in Application Support on macOS
/// and iOS; in the caches on tvOS, the only place its apps may keep files
/// (which it may purge); and in the XDG data directory elsewhere.
pub fn defaultDataDir(arena: std.mem.Allocator, home: []const u8, xdg_data_home: ?[]const u8) ![]const u8 {
    switch (@import("builtin").os.tag) {
        .macos, .ios => return std.fmt.allocPrint(arena, "{s}/Library/Application Support/Cinematheque", .{home}),
        .tvos => return std.fmt.allocPrint(arena, "{s}/Library/Caches/Cinematheque", .{home}),
        else => {},
    }
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
            _ = try std.fmt.hexToBytes(&identity.person, std.mem.trim(u8, text, " \n"));
        } else |_| {}
        return .{ .io = io, .gpa = gpa, .dir = dir, .identity = identity };
    }

    /// Makes this device act as the person whose secret `hex` is (as pairing
    /// sends it), before it opens or joins a library.
    pub fn pair(s: *Store, arena: std.mem.Allocator, hex: []const u8) !void {
        if (Io.Dir.cwd().access(s.io, try path(arena, s.dir, "replica.db"), .{})) |_| return error.AlreadyInUse else |_| {}
        const secret = try parseKey(hex);
        try Io.Dir.cwd().writeFile(s.io, .{ .sub_path = try path(arena, s.dir, "user"), .data = &std.fmt.bytesToHex(secret, .lower) });
        s.identity.person = secret;
    }

    fn path(arena: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
    }

    pub fn person(s: *const Store) ![32]u8 {
        return (try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(s.identity.person)).public_key.toBytes();
    }

    /// Whether this device acts as another device's person (`pair`), rather
    /// than the one its own seed derives.
    pub fn paired(s: *const Store) bool {
        return !std.mem.eql(u8, &s.identity.person, &replica_.Identity.from(s.identity.device).person);
    }

    /// This device's key.
    pub fn device(s: *const Store) ![32]u8 {
        return (try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(s.identity.device)).public_key.toBytes();
    }

    /// The name this device advertises by DNS-SD, and knows itself by when
    /// browsing: its device's key, shortened, so a person's devices are told
    /// apart.
    pub fn serviceName(s: *const Store, arena: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(arena, "cinematheque-{s}", .{std.fmt.bytesToHex(try s.device(), .lower)[0..8]});
    }

    pub fn founder(s: *const Store, arena: std.mem.Allocator) ![32]u8 {
        const text = Io.Dir.cwd().readFileAlloc(s.io, try path(arena, s.dir, "library"), arena, .limited(128)) catch return error.NoLibrary;
        return parseKey(std.mem.trim(u8, text, " \n"));
    }

    /// Records the library this device belongs to, by its founder's key.
    pub fn setFounder(s: *const Store, arena: std.mem.Allocator, key: [32]u8) !void {
        const file = try path(arena, s.dir, "library");
        if (Io.Dir.cwd().access(s.io, file, .{})) |_| return error.LibraryExists else |_| {}
        try Io.Dir.cwd().writeFile(s.io, .{ .sub_path = file, .data = &std.fmt.bytesToHex(key, .lower) });
    }

    /// Forgets the library and this device's identity, its seeds and its
    /// replica, as a device removed from its library does to pair afresh as
    /// a new device; a new identity is made when the data directory is next opened.
    pub fn forget(s: *const Store, arena: std.mem.Allocator) !void {
        for ([_][]const u8{ "replica.db", "replica.db-wal", "replica.db-shm", "library", "user", "identity" }) |name|
            Io.Dir.cwd().deleteFile(s.io, try path(arena, s.dir, name)) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
    }

    pub fn replicaPath(s: *const Store, arena: std.mem.Allocator) ![:0]u8 {
        return std.fmt.allocPrintSentinel(arena, "{s}/replica.db", .{s.dir}, 0);
    }

    pub fn openReplica(s: *const Store, arena: std.mem.Allocator) !Replica {
        return Replica.open(s.gpa, s.io, try s.replicaPath(arena), try s.founder(arena), s.identity);
    }
};

pub fn parseKey(hex: []const u8) ![32]u8 {
    var key: [32]u8 = undefined;
    if (hex.len != 64) return error.BadKey;
    _ = std.fmt.hexToBytes(&key, hex) catch return error.BadKey;
    return key;
}
