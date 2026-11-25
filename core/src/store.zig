//! A device's data directory: its identity (`identity`, a random seed from
//! which its device keys derive, and `user`, its person's seed, shared with the
//! person's other devices, or else derived from the device's), the creator of
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
        _ = try cwd.createDirPathStatus(io, dir, private(0o700));
        const file = try path(arena, dir, "identity");
        var seed: [32]u8 = undefined;
        // Only a missing file means a new device; any other failure
        // (out of file descriptors, say) must not replace its identity.
        if (cwd.readFileAlloc(io, file, arena, .limited(128))) |text| {
            seed = try parseKey(std.mem.trim(u8, text, " \n"));
        } else |err| switch (err) {
            error.FileNotFound => {
                io.random(&seed);
                try writeSecret(io, file, &std.fmt.bytesToHex(seed, .lower));
            },
            else => |e| return e,
        }
        var identity: replica_.Identity = .from(seed);
        if (cwd.readFileAlloc(io, try path(arena, dir, "user"), arena, .limited(128))) |text| {
            identity.person = try parseKey(std.mem.trim(u8, text, " \n"));
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }
        try tighten(io, arena, dir);
        return .{ .io = io, .gpa = gpa, .dir = dir, .identity = identity };
    }

    /// Makes a data directory, its seeds, and its replica (which holds
    /// people's progress) its owner's alone, as an older build, or a
    /// directory made before, may have left them readable by others.
    fn tighten(io: Io, arena: std.mem.Allocator, dir: []const u8) !void {
        if (!@hasDecl(Io.File.Permissions, "fromMode")) return;
        const cwd = Io.Dir.cwd();
        cwd.setFilePermissions(io, dir, private(0o700), .{}) catch {};
        for ([_][]const u8{ "identity", "user", "library", "replica.db", "replica.db-wal", "replica.db-shm" }) |name|
            cwd.setFilePermissions(io, try path(arena, dir, name), private(0o600), .{ .follow_symlinks = false }) catch {};
    }

    /// Permissions only the owner has, where the platform has such modes.
    fn private(mode: std.posix.mode_t) Io.File.Permissions {
        return if (@hasDecl(Io.File.Permissions, "fromMode")) .fromMode(mode) else .default_file;
    }

    /// Writes a seed, which only its owner may read.
    fn writeSecret(io: Io, file: []const u8, data: []const u8) !void {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = data, .flags = .{ .permissions = private(0o600) } });
    }

    /// Makes this device act as the person whose secret `hex` is (as pairing
    /// sends it), before it opens or joins a library.
    pub fn pair(s: *Store, arena: std.mem.Allocator, hex: []const u8) !void {
        if (Io.Dir.cwd().access(s.io, try path(arena, s.dir, "replica.db"), .{})) |_| return error.AlreadyInUse else |_| {}
        const secret = try parseKey(hex);
        try writeSecret(s.io, try path(arena, s.dir, "user"), &std.fmt.bytesToHex(secret, .lower));
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

    pub fn creator(s: *const Store, arena: std.mem.Allocator) ![32]u8 {
        // Only a missing file means no library; any other failure (out of
        // file descriptors, say) is itself, not taken for one.
        const text = Io.Dir.cwd().readFileAlloc(s.io, try path(arena, s.dir, "library"), arena, .limited(128)) catch |err| switch (err) {
            error.FileNotFound => return error.NoLibrary,
            else => |e| return e,
        };
        return parseKey(std.mem.trim(u8, text, " \n"));
    }

    /// Records the library this device belongs to, by its creator's key.
    pub fn setCreator(s: *const Store, arena: std.mem.Allocator, key: [32]u8) !void {
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
        return Replica.open(s.gpa, s.io, try s.replicaPath(arena), try s.creator(arena), s.identity);
    }
};

pub fn parseKey(hex: []const u8) ![32]u8 {
    var key: [32]u8 = undefined;
    if (hex.len != 64) return error.BadKey;
    _ = std.fmt.hexToBytes(&key, hex) catch return error.BadKey;
    return key;
}
