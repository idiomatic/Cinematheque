//! One peer's replica of one library, in SQLite: each field's winning
//! operation, the signed batches that vouch for operations, and a version
//! vector of what the replica has seen.

const std = @import("std");
const Io = std.Io;
const Ed25519 = std.crypto.sign.Ed25519;
const Blake3 = std.crypto.hash.Blake3;
const sqlite = @import("sqlite.zig");
const merkle = @import("merkle.zig");
const Hlc = @import("hlc.zig").Hlc;
const op_ = @import("op.zig");
const Op = op_.Op;
const Device = op_.Device;
const Hash = merkle.Hash;

const schema =
    \\PRAGMA journal_mode = WAL;
    \\PRAGMA synchronous = NORMAL;
    \\CREATE TABLE IF NOT EXISTS devices (
    \\  id INTEGER PRIMARY KEY,
    \\  key BLOB NOT NULL UNIQUE
    \\);
    \\CREATE TABLE IF NOT EXISTS batches (
    \\  device INTEGER NOT NULL,
    \\  first INTEGER NOT NULL,
    \\  count INTEGER NOT NULL,
    \\  root BLOB NOT NULL,
    \\  sig BLOB NOT NULL,
    \\  leaves BLOB NOT NULL,
    \\  PRIMARY KEY (device, first)
    \\) WITHOUT ROWID;
    \\CREATE TABLE IF NOT EXISTS winners (
    \\  key TEXT NOT NULL,
    \\  field TEXT NOT NULL,
    \\  kind INTEGER NOT NULL,
    \\  hlc INTEGER NOT NULL,
    \\  device INTEGER NOT NULL,
    \\  seq INTEGER NOT NULL,
    \\  value BLOB NOT NULL,
    \\  PRIMARY KEY (key, field)
    \\) WITHOUT ROWID;
    \\CREATE INDEX IF NOT EXISTS winners_by_device ON winners (device, seq);
    \\CREATE TABLE IF NOT EXISTS repair (
    \\  key TEXT NOT NULL,
    \\  field TEXT NOT NULL,
    \\  PRIMARY KEY (key, field)
    \\) WITHOUT ROWID;
    \\-- Per device (interned), the highest sequence number this replica
    \\-- covers, sent with sync requests.
    \\CREATE TABLE IF NOT EXISTS version_vector (
    \\  device INTEGER PRIMARY KEY,
    \\  seq INTEGER NOT NULL
    \\);
    \\-- The peer's own state, which doesn't replicate (e.g., crawl snapshots).
    \\CREATE TABLE IF NOT EXISTS local (
    \\  key TEXT PRIMARY KEY,
    \\  value BLOB NOT NULL
    \\) WITHOUT ROWID;
;

pub const VersionVector = []const Entry;

pub const Entry = struct {
    device: Device,
    seq: u64,
};

pub const Outcome = enum {
    /// The operation now wins its field.
    won,
    /// Another operation already holds the field.
    lost,
    /// The version vector already covers it.
    known,
};

pub const Stats = struct {
    sent: usize = 0,
    won: usize = 0,
    lost: usize = 0,
    known: usize = 0,
    /// Operations in batches whose devices don't act for members.
    rejected: usize = 0,
    /// Batches held until later frames admitted their devices.
    deferred: usize = 0,
    /// Operations a removed device (or a removed member's) wrote past its
    /// cutoff.
    refused: usize = 0,
    batches: usize = 0,
    /// What a network transfer would carry: operations, plus each batch's
    /// device, range, signature, and leaves (or proofs, for repair).
    wire_bytes: usize = 0,

    fn count(stats: *Stats, outcome: Outcome) void {
        stats.sent += 1;
        switch (outcome) {
            .won => stats.won += 1,
            .lost => stats.lost += 1,
            .known => stats.known += 1,
        }
    }
};

/// A signed batch of one device's consecutive operations.
pub const Batch = struct {
    device: Device,
    first: u64,
    leaves: []const Hash,
    root: Hash,
    sig: op_.Signature,

    const header_wire_len = 32 + 8 + 4 + 64;

    fn contains(batch: *const Batch, seq: u64) bool {
        return seq >= batch.first and seq < batch.first + batch.leaves.len;
    }
};

/// A device's secrets: its own seed, from which its device keys derive, and
/// its user's, which the user's devices share.
pub const Identity = struct {
    device: [32]u8,
    user: [32]u8,

    /// A device's identity when its user has no other devices yet: the
    /// user's seed derives from the device's.
    pub fn from(device_seed: [32]u8) Identity {
        return .{ .device = device_seed, .user = derive("cinematheque user", device_seed) };
    }
};

fn derive(context: []const u8, seed: [32]u8) [32]u8 {
    var out: [32]u8 = undefined;
    var h = Blake3.init(.{});
    h.update(context);
    h.update(&seed);
    h.final(&out);
    return out;
}

pub const Replica = struct {
    gpa: std.mem.Allocator,
    db: sqlite.Db,
    library: op_.Library,
    /// The user who created the library, from whom its ID derives.
    genesis: Device,
    /// The founder now: the genesis founder, or the last successor in the
    /// chain of handovers. The founder is always a member and can't be
    /// removed.
    founder: Device,
    /// The user this device acts for, who certifies its key.
    user: Ed25519.KeyPair,
    key_pair: Ed25519.KeyPair,
    own: i64,
    seq: u64,
    /// The device's private stream: its own key, numbering, and batches, for
    /// its user's private data (`p/<user>/...`), which replicates only among
    /// that user's devices.
    private_pair: Ed25519.KeyPair,
    private_own: i64 = 0,
    private_seq: u64 = 0,
    hlc: Hlc = .{},
    /// Check signatures of received batches; off only to measure their cost.
    verify: bool = true,
    /// Interned device keys: `keys[id - 1]` is the key of device `id`.
    keys: std.ArrayList(Device) = .empty,
    ids: std.AutoHashMapUnmanaged(Device, i64) = .empty,
    body: std.ArrayList(u8) = .empty,
    /// Leaves of local writes not yet signed, starting at `pending_first`.
    pending: std.ArrayList(Hash) = .empty,
    pending_first: u64 = 0,
    batching: bool = false,
    /// Whether this connection has checked the device's own certificates,
    /// its stream's and its private stream's, before writing on them.
    checked_certificate: bool = false,
    checked_private_certificate: bool = false,
    /// Whether any fields await `repair`, so merges needn't check otherwise.
    repairing: bool = false,
    select_winner: sqlite.Stmt,
    upsert_winner: sqlite.Stmt,
    select_version: sqlite.Stmt,
    upsert_version: sqlite.Stmt,
    insert_device: sqlite.Stmt,
    insert_batch: sqlite.Stmt,

    /// Opens a replica of the library `founder` created, as the device and
    /// user `identity` gives. A device writes its certificate with its first
    /// write, so devices that only read never need one.
    /// Renames tables from replicas made before their names changed (`vv`
    /// became `version_vector`). Another process opening the replica may
    /// rename one first.
    fn renameOldTables(db: sqlite.Db) !void {
        if (try db.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'vv'") == 0) return;
        db.exec("ALTER TABLE vv RENAME TO version_vector") catch |err| {
            if (try db.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'vv'") != 0) return err;
        };
    }

    pub fn open(gpa: std.mem.Allocator, io: Io, path: [:0]const u8, founder: Device, identity: Identity) !Replica {
        const db = try sqlite.Db.open(path, io);
        errdefer db.close();
        try renameOldTables(db);
        try db.exec(schema);
        var replica: Replica = .{
            .gpa = gpa,
            .db = db,
            .library = libraryId(founder),
            .genesis = founder,
            .founder = founder,
            .user = try Ed25519.KeyPair.generateDeterministic(identity.user),
            .key_pair = try Ed25519.KeyPair.generateDeterministic(identity.device),
            .private_pair = try Ed25519.KeyPair.generateDeterministic(derive("cinematheque private", identity.device)),
            .own = 0,
            .seq = 0,
            .select_winner = try db.prepare("SELECT kind, hlc, device, value FROM winners WHERE key = ?1 AND field = ?2"),
            .upsert_winner = try db.prepare(
                \\INSERT INTO winners VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                \\ON CONFLICT (key, field) DO UPDATE SET
                \\  kind = excluded.kind, hlc = excluded.hlc, device = excluded.device,
                \\  seq = excluded.seq, value = excluded.value
            ),
            .select_version = try db.prepare("SELECT seq FROM version_vector WHERE device = ?1"),
            .upsert_version = try db.prepare(
                \\INSERT INTO version_vector VALUES (?1, ?2)
                \\ON CONFLICT (device) DO UPDATE SET seq = max(seq, excluded.seq)
            ),
            .insert_device = try db.prepare("INSERT INTO devices (key) VALUES (?1) RETURNING id"),
            .insert_batch = try db.prepare("INSERT OR IGNORE INTO batches VALUES (?1, ?2, ?3, ?4, ?5, ?6)"),
        };
        errdefer replica.close();
        const s = try db.prepare("SELECT id, key FROM devices ORDER BY id");
        defer s.finalize();
        while (try s.step()) try replica.intern(s.int(0), s.blob(1)[0..32].*);
        replica.own = try replica.deviceId(replica.device());
        replica.seq = try replica.seen(replica.own);
        replica.private_own = try replica.deviceId(replica.private_pair.public_key.toBytes());
        replica.private_seq = try replica.seen(replica.private_own);
        replica.repairing = try replica.repairsPending() > 0;
        replica.founder = (try replica.founderAt(std.math.maxInt(u32))).user;
        return replica;
    }

    /// The user's key and signature over `"cinematheque device" | library |
    /// device key`, or, for a private stream, `"cinematheque private" |
    /// library | key`.
    pub fn certificate(replica: *const Replica, private: bool) ![96]u8 {
        const key = if (private) replica.private_pair.public_key.toBytes() else replica.device();
        const sig = try replica.user.sign(&certMessage(replica.library, key, private), null);
        var value: [96]u8 = undefined;
        value[0..32].* = replica.user.public_key.toBytes();
        value[32..].* = sig.toBytes();
        return value;
    }

    /// Writes this device's certificate, at `wall_ms`, so a fresh one wins
    /// over one that didn't verify.
    fn certify(replica: *Replica, wall_ms: u64) anyerror!void {
        var key: [66]u8 = undefined;
        try replica.write(wall_ms, certKey(&key, replica.device()), "user", &try replica.certificate(false));
    }

    /// A device's first write is its certificate; one that doesn't verify
    /// (or none) is written afresh, checked once a connection.
    fn checkCertificate(replica: *Replica, wall_ms: u64) !void {
        if (replica.checked_certificate) return;
        replica.checked_certificate = true;
        if (!try replica.ownCertified(false)) try replica.certify(wall_ms);
    }

    /// Rewrites this device's certificates that it holds but that don't
    /// verify, as when it opens, so other devices take its stream again
    /// without waiting for it to write. One it doesn't hold waits for its
    /// first write: a device whose replica was lost must learn where its
    /// numbering left off before it writes.
    pub fn recertify(replica: *Replica, wall_ms: u64) !void {
        var key: [66]u8 = undefined;
        if (try replica.holds(certKey(&key, replica.device()), "user") and !try replica.ownCertified(false)) {
            replica.checked_certificate = true;
            try replica.certify(wall_ms);
        }
        const private = replica.private_pair.public_key.toBytes();
        if (try replica.holds(certKey(&key, private), "private") and !try replica.ownCertified(true)) {
            replica.checked_private_certificate = true;
            try replica.write(wall_ms, certKey(&key, private), "private", &try replica.certificate(true));
        }
    }

    fn holds(replica: *Replica, key: []const u8, field: []const u8) !bool {
        const s = replica.select_winner;
        defer s.reset();
        try s.bindText(1, key);
        try s.bindText(2, field);
        return try s.step();
    }

    /// Whether this device's own certificate, or its private stream's, as
    /// held, is valid for this library and names its user. Its own writes
    /// pass without one, so only others would notice one that isn't, by
    /// refusing every write on the stream (as an older build's may be).
    fn ownCertified(replica: *Replica, private: bool) !bool {
        const key = if (private) replica.private_pair.public_key.toBytes() else replica.device();
        const c = try replica.certified(key, &.{}) orelse return false;
        return c.private == private and std.mem.eql(u8, &c.user, &replica.userKey());
    }

    pub fn userKey(replica: *const Replica) Device {
        return replica.user.public_key.toBytes();
    }

    /// Writes `fields` of the private `key` (which must be this user's,
    /// `p/<user>/...`) as one batch of the device's private stream.
    pub fn writePrivate(replica: *Replica, wall_ms: u64, key: []const u8, fields: []const [2][]const u8) !void {
        const hex = std.fmt.bytesToHex(replica.userKey(), .lower);
        if (!std.mem.startsWith(u8, key, "p/") or !std.mem.startsWith(u8, key[2..], &hex) or key.len < 67 or key[66] != '/')
            return error.NotPrivate;
        try replica.flush();
        // The private stream's certificate travels on the device's own.
        try replica.checkCertificate(wall_ms);
        if (!replica.checked_private_certificate) {
            replica.checked_private_certificate = true;
            if (!try replica.ownCertified(true)) {
                var cert_key: [66]u8 = undefined;
                try replica.write(wall_ms, certKey(&cert_key, replica.private_pair.public_key.toBytes()), "private", &try replica.certificate(true));
            }
        }
        var leaves: std.ArrayList(Hash) = .empty;
        defer leaves.deinit(replica.gpa);
        const first = replica.private_seq + 1;
        for (fields) |f| {
            replica.private_seq += 1;
            const op: Op = .{
                .library = replica.library,
                .device = replica.private_pair.public_key.toBytes(),
                .seq = replica.private_seq,
                .hlc = replica.hlc.tick(wall_ms),
                .kind = .lww,
                .key = key,
                .field = f[0],
                .value = f[1],
            };
            try op.encode(replica.gpa, &replica.body);
            try leaves.append(replica.gpa, merkle.leaf(replica.body.items));
            _ = try replica.merge(op, replica.private_own);
        }
        const root = merkle.root(leaves.items);
        try replica.storeBatch(replica.private_own, first, leaves.items, root, (try replica.private_pair.sign(&root, null)).toBytes());
        try replica.advance(replica.private_own, replica.private_seq);
    }

    /// Adds `user` to the library's members.
    pub fn addMember(replica: *Replica, wall_ms: u64, user: Device) !void {
        try replica.setMember(wall_ms, "members", &std.fmt.bytesToHex(user, .lower), true);
    }

    /// Hands the library over to `successor`, who becomes a member if not
    /// one already; this user stays a member if `stay`. Only the founder may.
    pub fn handOver(replica: *Replica, wall_ms: u64, successor: Device, stay: bool) !void {
        const me = replica.user.public_key.toBytes();
        if (!std.mem.eql(u8, &me, &replica.founder)) return error.NotFounder;
        if (!try replica.isMemberUser(successor)) try replica.addMember(wall_ms, successor);
        if (stay) try replica.addMember(wall_ms, me);
        const now = try replica.founderAt(std.math.maxInt(u32));
        var field: [10]u8 = undefined;
        try replica.write(wall_ms, "founders", try std.fmt.bufPrint(&field, "{d:0>6}", .{now.generation + 1}), &successor);
    }

    const Founder = struct { user: Device, generation: u32 };

    /// Follows the chain of handovers held (`founders`, fields numbered
    /// from 1, each naming a successor and written by a device of the
    /// previous founder) up to `generation`, or as far as it goes.
    fn founderAt(replica: *Replica, generation: u32) !Founder {
        var holder = replica.genesis;
        var n: u32 = 0;
        while (n < generation) : (n += 1) {
            var field: [10]u8 = undefined;
            const s = try replica.db.prepare("SELECT device, value FROM winners WHERE key = 'founders' AND field = ?1");
            defer s.finalize();
            try s.bindText(1, try std.fmt.bufPrint(&field, "{d:0>6}", .{n + 1}));
            if (!try s.step() or s.blob(1).len != 32) break;
            const author = replica.keys.items[@intCast(s.int(0) - 1)];
            const user = try replica.certifiedUser(author, &.{}) orelse break;
            if (!std.mem.eql(u8, &user, &holder)) break;
            holder = s.blob(1)[0..32].*;
        }
        return .{ .user = holder, .generation = n };
    }

    /// Checks a batch's handovers: each must come from the founder of the
    /// generation before it. `error.Unauthorized` defers the batch while
    /// that generation is missing; ill-made handovers are marked in
    /// `refused`.
    fn checkHandovers(replica: *Replica, device_key: Device, ops: []const Op, refused: *std.StaticBitSet(merkle.max_leaves)) !void {
        for (ops, 0..) |op, i| {
            if (!std.mem.eql(u8, op.key, "founders")) continue;
            const n = std.fmt.parseInt(u32, op.field, 10) catch 0;
            const author = try replica.certifiedUser(device_key, ops);
            if (n == 0 or op.value.len != 32 or author == null) {
                refused.set(i);
                continue;
            }
            const before = try replica.founderAt(n - 1);
            if (before.generation < n - 1) return error.Unauthorized;
            if (!std.mem.eql(u8, &author.?, &before.user)) refused.set(i);
        }
    }

    pub fn isMemberUser(replica: *Replica, user: Device) !bool {
        return std.mem.eql(u8, &user, &replica.founder) or
            try replica.isMember("members", &std.fmt.bytesToHex(user, .lower));
    }

    /// What a device's batches may hold: everything (its user is a
    /// member), nothing yet (no certificate naming a member), or, for a
    /// removed device (or a removed member's), writes through its cutoff.
    const Admission = union(enum) { all, none, through: u64 };

    fn admission(replica: *Replica, device_key: Device, ops: []const Op) !Admission {
        if (std.mem.eql(u8, &device_key, &replica.device())) return .all;
        if (std.mem.eql(u8, &device_key, &replica.private_pair.public_key.toBytes())) return .all;
        const c = try replica.certified(device_key, ops) orelse return .none;
        if (try replica.revoked(device_key)) |seq| return .{ .through = seq };
        if (try replica.isMemberUser(c.user)) return .all;
        return .none;
    }

    pub const Certified = struct { user: Device, private: bool };

    /// The user whose valid certificate, from `ops` or already held, names
    /// `device_key`, and whether it names a private stream.
    pub fn certified(replica: *Replica, device_key: Device, ops: []const Op) !?Certified {
        var key_buf: [66]u8 = undefined;
        const key = certKey(&key_buf, device_key);
        for ([_]bool{ false, true }) |private| {
            const field = if (private) "private" else "user";
            var cert: ?[96]u8 = null;
            for (ops) |op| if (std.mem.eql(u8, op.key, key) and std.mem.eql(u8, op.field, field) and op.value.len == 96) {
                cert = op.value[0..96].*;
            };
            if (cert == null) {
                const s = replica.select_winner;
                defer s.reset();
                try s.bindText(1, key);
                try s.bindText(2, field);
                if (try s.step()) if (s.blob(3).len == 96) {
                    cert = s.blob(3)[0..96].*;
                };
            }
            const c = cert orelse continue;
            if (verifyCertificate(replica.library, device_key, private, c)) |user| return .{ .user = user, .private = private };
        }
        return null;
    }

    fn certifiedUser(replica: *Replica, device_key: Device, ops: []const Op) !?Device {
        const c = try replica.certified(device_key, ops) orelse return null;
        return if (c.private) null else c.user;
    }

    /// Refuses private data written by anyone but its user's private stream,
    /// and anything else a private stream writes.
    fn checkPrivate(replica: *Replica, device_key: Device, ops: []const Op, refused: *std.StaticBitSet(merkle.max_leaves)) !void {
        // This device's own private stream is its user's, certificate or
        // not: a replica rebuilt from peers (e.g., after tvOS purged it) may
        // get the stream's batches before the public one carrying its
        // certificate.
        const own = std.mem.eql(u8, &device_key, &replica.private_pair.public_key.toBytes());
        const c: ?Certified = if (own) .{ .user = replica.userKey(), .private = true } else try replica.certified(device_key, ops);
        for (ops, 0..) |op, i| {
            const is_private = std.mem.startsWith(u8, op.key, "p/");
            if (c != null and c.?.private) {
                const hex = std.fmt.bytesToHex(c.?.user, .lower);
                if (!is_private or op.key.len < 67 or !std.mem.eql(u8, op.key[2..66], &hex) or op.key[66] != '/') refused.set(i);
            } else if (is_private) refused.set(i);
        }
    }

    /// Devices certified for `user`, by the certificates held.
    fn devicesOf(replica: *Replica, arena: std.mem.Allocator, user: Device) ![]Device {
        var out: std.ArrayList(Device) = .empty;
        const s = try replica.db.prepare("SELECT key, value FROM winners WHERE key >= 'c/' AND key < 'c0' AND field = 'user'");
        defer s.finalize();
        while (try s.step()) {
            const value = s.blob(1);
            if (value.len != 96 or !std.mem.eql(u8, value[0..32], &user)) continue;
            var dev: Device = undefined;
            _ = std.fmt.hexToBytes(&dev, s.blob(0)[2..]) catch continue;
            try out.append(arena, dev);
        }
        return out.items;
    }

    /// Removes one device (of this user's, or any member's) without its
    /// user: its streams, its own and its private one, are cut off where
    /// this replica has seen them, so writes through there stand and later
    /// ones are refused, and it's served no more. It still holds its user's
    /// secret, so it isn't kept out of the user's other devices' data that
    /// it already has, and could pair afresh as another device.
    pub fn revokeDevice(replica: *Replica, wall_ms: u64, device_key: Device) !void {
        if (std.mem.eql(u8, &device_key, &replica.device())) return error.ThisDevice;
        try replica.revokeStreams(wall_ms, device_key);
    }

    /// Cuts off a device's streams, its own and its private one, where this
    /// replica has seen them (`revoked`, a field per stream); merging it
    /// drops what the stream wrote past there (see `cut`).
    fn revokeStreams(replica: *Replica, wall_ms: u64, device_key: Device) !void {
        var arena_state = std.heap.ArenaAllocator.init(replica.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var streams: std.ArrayList(Device) = .empty;
        try streams.append(arena, device_key);
        // Its private streams, whose certificates it wrote.
        {
            const s = try replica.db.prepare("SELECT key FROM winners WHERE key >= 'c/' AND key < 'c0' AND field = 'private' AND device = ?1");
            defer s.finalize();
            try s.bindInt(1, try replica.deviceId(device_key));
            while (try s.step()) {
                var private: Device = undefined;
                _ = std.fmt.hexToBytes(&private, s.blob(0)[2..]) catch continue;
                try streams.append(arena, private);
            }
        }
        for (streams.items) |stream| {
            var seq: [8]u8 = undefined;
            std.mem.writeInt(u64, &seq, try replica.seen(try replica.deviceId(stream)), .little);
            try replica.write(wall_ms, "revoked", &std.fmt.bytesToHex(stream, .lower), &seq);
        }
    }

    /// Where a stream of a removed device was cut off, if it was.
    pub fn revoked(replica: *Replica, stream: Device) !?u64 {
        const s = replica.select_winner;
        defer s.reset();
        try s.bindText(1, "revoked");
        try s.bindText(2, &std.fmt.bytesToHex(stream, .lower));
        if (!try s.step()) return null;
        const value = s.blob(3);
        if (value.len != 8) return null;
        return std.mem.readInt(u64, value[0..8], .little);
    }

    /// Removes `user` from the library, and cuts off each of their devices
    /// as `revokeDevice` does: their writes up to what this replica has
    /// seen stand; later ones are refused. A device the remover didn't
    /// know isn't admitted, its user no longer a member. The founder (as
    /// handed over, if it was) can't be removed.
    pub fn removeMember(replica: *Replica, wall_ms: u64, user: Device) !void {
        if (std.mem.eql(u8, &user, &replica.founder)) return error.FounderIsPermanent;
        var arena_state = std.heap.ArenaAllocator.init(replica.gpa);
        defer arena_state.deinit();
        try replica.setMember(wall_ms, "members", &std.fmt.bytesToHex(user, .lower), false);
        for (try replica.devicesOf(arena_state.allocator(), user)) |dev| {
            if (!std.mem.eql(u8, &dev, &replica.device())) try replica.revokeStreams(wall_ms, dev);
        }
    }

    /// Applies a stream's cutoff (a `revoked` field, `stream_hex`, and its
    /// last sequence number that stands): drops the winners the stream
    /// wrote past it, and notes those fields for `repair`, which refetches
    /// them from a peer that refused those writes.
    fn cut(replica: *Replica, stream_hex: []const u8, value: []const u8) !void {
        if (value.len != 8) return;
        var stream: Device = undefined;
        _ = std.fmt.hexToBytes(&stream, stream_hex) catch return;
        const id = replica.ids.get(stream) orelse return;
        const through = std.mem.readInt(u64, value[0..8], .little);
        inline for (.{
            "INSERT OR IGNORE INTO repair SELECT key, field FROM winners WHERE device = ?1 AND seq > ?2 AND key NOT LIKE 'c/%'",
            "DELETE FROM winners WHERE device = ?1 AND seq > ?2 AND key NOT LIKE 'c/%'",
        }) |sql| {
            const s = try replica.db.prepare(sql);
            defer s.finalize();
            try s.bindInt(1, id);
            try s.bindInt(2, @intCast(through));
            _ = try s.step();
        }
        replica.repairing = try replica.repairsPending() > 0;
    }

    pub fn repairsPending(replica: *Replica) !i64 {
        return replica.db.scalar("SELECT count(*) FROM repair");
    }

    pub fn close(replica: *Replica) void {
        for ([_]sqlite.Stmt{
            replica.select_winner, replica.upsert_winner, replica.select_version,
            replica.upsert_version,     replica.insert_device, replica.insert_batch,
        }) |s| s.finalize();
        replica.db.close();
        replica.keys.deinit(replica.gpa);
        replica.ids.deinit(replica.gpa);
        replica.body.deinit(replica.gpa);
        replica.pending.deinit(replica.gpa);
    }

    pub fn device(replica: *const Replica) Device {
        return replica.key_pair.public_key.toBytes();
    }

    fn intern(replica: *Replica, id: i64, key: Device) !void {
        std.debug.assert(id == replica.keys.items.len + 1);
        try replica.keys.append(replica.gpa, key);
        try replica.ids.put(replica.gpa, key, id);
    }

    fn deviceId(replica: *Replica, key: Device) !i64 {
        if (replica.ids.get(key)) |id| return id;
        const id = blk: {
            const s = replica.insert_device;
            defer s.reset();
            try s.bindBlob(1, &key);
            if (!try s.step()) return error.Sqlite;
            break :blk s.int(0);
        };
        // Devices another connection added meanwhile come first.
        if (id != replica.keys.items.len + 1) try replica.internAdded();
        if (replica.ids.get(key) == null) try replica.intern(id, key);
        return id;
    }

    /// Learns the devices other connections added since this one last did.
    fn internAdded(replica: *Replica) !void {
        const s = try replica.db.prepare("SELECT id, key FROM devices WHERE id > ?1 ORDER BY id");
        defer s.finalize();
        try s.bindInt(1, @intCast(replica.keys.items.len));
        while (try s.step()) try replica.intern(s.int(0), s.blob(1)[0..32].*);
    }

    /// Catches up with what another connection to the same database wrote:
    /// devices it learned of, this device's sequence numbers, and the
    /// founder. Only one connection may write as this device at a time.
    pub fn refresh(replica: *Replica) !void {
        try replica.internAdded();
        replica.seq = try replica.seen(replica.own);
        replica.private_seq = try replica.seen(replica.private_own);
        replica.founder = (try replica.founderAt(std.math.maxInt(u32))).user;
    }

    /// The peer's own `key`, which doesn't replicate, if set.
    pub fn local(replica: *Replica, arena: std.mem.Allocator, key: []const u8) !?[]u8 {
        const s = try replica.db.prepare("SELECT value FROM local WHERE key = ?1");
        defer s.finalize();
        try s.bindText(1, key);
        return if (try s.step()) try arena.dupe(u8, s.blob(0)) else null;
    }

    pub fn setLocal(replica: *Replica, key: []const u8, value: []const u8) !void {
        const s = try replica.db.prepare("INSERT OR REPLACE INTO local VALUES (?1, ?2)");
        defer s.finalize();
        try s.bindText(1, key);
        try s.bindBlob(2, value);
        _ = try s.step();
    }

    pub fn removeLocal(replica: *Replica, key: []const u8) !void {
        const s = try replica.db.prepare("DELETE FROM local WHERE key = ?1");
        defer s.finalize();
        try s.bindText(1, key);
        _ = try s.step();
    }

    /// The peer's own keys starting with `prefix`, in order.
    pub fn localKeys(replica: *Replica, arena: std.mem.Allocator, prefix: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        const s = try replica.db.prepare("SELECT key FROM local WHERE substr(key, 1, length(?1)) = ?1 ORDER BY key");
        defer s.finalize();
        try s.bindText(1, prefix);
        while (try s.step()) try out.append(arena, try arena.dupe(u8, s.blob(0)));
        return out.items;
    }

    /// Starts a transaction; local writes until `commit` share one signature.
    /// It takes the write lock at once (waiting for another connection's,
    /// as a server applying a push may hold it), since a deferred one that
    /// read first would fail to write once another had committed.
    pub fn begin(replica: *Replica) !void {
        try replica.db.exec("BEGIN IMMEDIATE");
        replica.batching = true;
    }

    pub fn commit(replica: *Replica) !void {
        try replica.flush();
        replica.batching = false;
        try replica.db.exec("COMMIT");
    }

    pub fn write(replica: *Replica, wall_ms: u64, key: []const u8, field: []const u8, value: []const u8) !void {
        try replica.writeOp(.lww, wall_ms, key, field, value);
    }

    /// Adds or removes `element` of the set at `key`.
    pub fn setMember(replica: *Replica, wall_ms: u64, key: []const u8, element: []const u8, present: bool) !void {
        const length = try replica.causalLength(key, element);
        if ((length % 2 == 1) == present) return;
        var value: [4]u8 = undefined;
        std.mem.writeInt(u32, &value, length + 1, .little);
        try replica.writeOp(.causal_length, wall_ms, key, element, &value);
    }

    /// The library's members: the founder, then the users added and not
    /// removed.
    pub fn members(replica: *Replica, arena: std.mem.Allocator) ![]Device {
        var out: std.ArrayList(Device) = .empty;
        try out.append(arena, replica.founder);
        const s = try replica.db.prepare("SELECT field, value FROM winners WHERE key = 'members' ORDER BY field");
        defer s.finalize();
        while (try s.step()) {
            if (op_.causalLength(s.blob(1)) % 2 == 0) continue;
            const user = parseHex(s.blob(0)) orelse continue;
            if (!std.mem.eql(u8, &user, &replica.founder)) try out.append(arena, user);
        }
        return out.items;
    }

    pub fn isMember(replica: *Replica, key: []const u8, element: []const u8) !bool {
        return try replica.causalLength(key, element) % 2 == 1;
    }

    fn causalLength(replica: *Replica, key: []const u8, element: []const u8) !u32 {
        const s = replica.select_winner;
        defer s.reset();
        try s.bindText(1, key);
        try s.bindText(2, element);
        return if (try s.step()) op_.causalLength(s.blob(3)) else 0;
    }

    fn writeOp(replica: *Replica, kind: op_.Kind, wall_ms: u64, key: []const u8, field: []const u8, value: []const u8) !void {
        var own_key: [66]u8 = undefined;
        if (!std.mem.eql(u8, key, certKey(&own_key, replica.device()))) try replica.checkCertificate(wall_ms);
        replica.seq += 1;
        const op: Op = .{
            .library = replica.library,
            .device = replica.device(),
            .seq = replica.seq,
            .hlc = replica.hlc.tick(wall_ms),
            .kind = kind,
            .key = key,
            .field = field,
            .value = value,
        };
        try op.encode(replica.gpa, &replica.body);
        if (replica.pending.items.len == 0) replica.pending_first = op.seq;
        try replica.pending.append(replica.gpa, merkle.leaf(replica.body.items));
        _ = try replica.merge(op, replica.own);
        try replica.advance(replica.own, op.seq);
        if (!replica.batching or replica.pending.items.len == merkle.max_leaves) try replica.flush();
    }

    /// Signs pending local writes as one batch.
    fn flush(replica: *Replica) !void {
        const leaves = replica.pending.items;
        if (leaves.len == 0) return;
        const root = merkle.root(leaves);
        const sig = (try replica.key_pair.sign(&root, null)).toBytes();
        try replica.storeBatch(replica.own, replica.pending_first, leaves, root, sig);
        replica.pending.clearRetainingCapacity();
    }

    fn storeBatch(replica: *Replica, id: i64, first: u64, leaves: []const Hash, root: Hash, sig: op_.Signature) !void {
        const s = replica.insert_batch;
        defer s.reset();
        try s.bindInt(1, id);
        try s.bindInt(2, @intCast(first));
        try s.bindInt(3, @intCast(leaves.len));
        try s.bindBlob(4, &root);
        try s.bindBlob(5, &sig);
        try s.bindBlob(6, std.mem.sliceAsBytes(leaves));
        _ = try s.step();
    }

    /// Accepts a batch from another peer with those of its operations being
    /// sent. `leaves` holds the batch's leaves, except where `ops` fall,
    /// which are rebuilt from the operations themselves; then the root must
    /// match the device's signature before anything is applied.
    pub fn receiveBatch(replica: *Replica, batch: Batch, leaves: []Hash, ops: []const Op, stats: *Stats) !void {
        for (ops) |op| {
            if (!std.mem.eql(u8, &op.library, &replica.library)) return error.WrongLibrary;
            if (!std.mem.eql(u8, &op.device, &batch.device) or op.seq < batch.first or op.seq >= batch.first + leaves.len) return error.NoBatch;
            try op.encode(replica.gpa, &replica.body);
            leaves[op.seq - batch.first] = merkle.leaf(replica.body.items);
        }
        const root = merkle.root(leaves);
        if (replica.verify) try verifyRoot(batch.device, root, batch.sig);
        const admitted = try replica.admission(batch.device, ops);
        if (admitted == .none) return error.Unauthorized;
        var bad: std.StaticBitSet(merkle.max_leaves) = .empty;
        try replica.checkHandovers(batch.device, ops, &bad);
        try replica.checkPrivate(batch.device, ops, &bad);
        const id = try replica.deviceId(batch.device);
        try replica.storeBatch(id, batch.first, leaves, root, batch.sig);
        const seen_seq = try replica.seen(id);
        for (ops, 0..) |op, i| {
            if (op.seq <= seen_seq) {
                stats.count(.known);
                continue;
            }
            if (bad.isSet(i) or admitted == .through and op.seq > admitted.through) {
                stats.refused += 1;
                continue;
            }
            replica.hlc.observe(op.hlc);
            const outcome = try replica.merge(op, id);
            if (outcome == .won) try replica.repaired(op);
            stats.count(outcome);
        }
    }

    /// Accepts some of a batch's operations with one shared proof against
    /// the batch's signed root, as repair does, keeping neither the
    /// batch nor a version vector.
    pub fn receiveShared(replica: *Replica, batch: Batch, count: usize, indices: []const usize, siblings: []const Hash, ops: []const Op, stats: *Stats) !void {
        var leaves: [merkle.max_leaves]Hash = undefined;
        for (ops, 0..) |op, k| {
            if (!std.mem.eql(u8, &op.library, &replica.library)) return error.WrongLibrary;
            if (op.seq != batch.first + indices[k]) return error.NoBatch;
            try op.encode(replica.gpa, &replica.body);
            leaves[k] = merkle.leaf(replica.body.items);
        }
        const root = try merkle.rootFromMulti(count, indices, leaves[0..ops.len], siblings);
        if (replica.verify) try verifyRoot(batch.device, root, batch.sig);
        const admitted = try replica.admission(batch.device, ops);
        if (admitted == .none) return error.Unauthorized;
        var bad: std.StaticBitSet(merkle.max_leaves) = .empty;
        try replica.checkHandovers(batch.device, ops, &bad);
        try replica.checkPrivate(batch.device, ops, &bad);
        const id = try replica.deviceId(batch.device);
        for (ops, 0..) |op, i| {
            if (bad.isSet(i) or admitted == .through and op.seq > admitted.through) {
                stats.refused += 1;
                continue;
            }
            const outcome = try replica.merge(op, id);
            if (outcome == .won) try replica.repaired(op);
            stats.count(outcome);
        }
    }

    fn merge(replica: *Replica, op: Op, id: i64) !Outcome {
        const s = replica.select_winner;
        defer s.reset();
        try s.bindText(1, op.key);
        try s.bindText(2, op.field);
        if (try s.step()) {
            const newer = switch (op.kind) {
                // Last writer wins, by hybrid logical clock, then device key.
                .lww => blk: {
                    const hlc: u64 = @bitCast(s.int(1));
                    const holder = replica.keys.items[@intCast(s.int(2) - 1)];
                    break :blk op.hlc > hlc or
                        (op.hlc == hlc and std.mem.order(u8, &op.device, &holder) == .gt);
                },
                // The longer causal length wins.
                .causal_length => op_.causalLength(op.value) > op_.causalLength(s.blob(3)),
            };
            if (!newer) return .lost;
        }
        // Free the statement for the checks the hooks below make.
        s.reset();
        const u = replica.upsert_winner;
        defer u.reset();
        try u.bindText(1, op.key);
        try u.bindText(2, op.field);
        try u.bindInt(3, @intFromEnum(op.kind));
        try u.bindInt(4, @bitCast(op.hlc));
        try u.bindInt(5, id);
        try u.bindInt(6, @intCast(op.seq));
        try u.bindBlob(7, op.value);
        _ = try u.step();
        if (std.mem.eql(u8, op.key, "revoked")) try replica.cut(op.field, op.value);
        if (std.mem.eql(u8, op.key, "founders")) replica.founder = (try replica.founderAt(std.math.maxInt(u32))).user;
        return .won;
    }

    fn repaired(replica: *Replica, op: Op) !void {
        if (!replica.repairing) return;
        const s = try replica.db.prepare("DELETE FROM repair WHERE key = ?1 AND field = ?2");
        defer s.finalize();
        try s.bindText(1, op.key);
        try s.bindText(2, op.field);
        _ = try s.step();
    }

    /// The highest sequence number of device `id` that this replica covers.
    fn seen(replica: *Replica, id: i64) !u64 {
        const s = replica.select_version;
        defer s.reset();
        try s.bindInt(1, id);
        return if (try s.step()) @intCast(s.int(0)) else 0;
    }

    fn advance(replica: *Replica, id: i64, seq: u64) !void {
        const u = replica.upsert_version;
        defer u.reset();
        try u.bindInt(1, id);
        try u.bindInt(2, @intCast(seq));
        _ = try u.step();
    }

    /// The version vector without other users' private streams than `reader`'s.
    pub fn readableVector(replica: *Replica, arena: std.mem.Allocator, reader: Device) !VersionVector {
        var out: std.ArrayList(Entry) = .empty;
        for (try replica.versionVector(arena)) |entry| {
            if (try replica.certified(entry.device, &.{})) |c| if (c.private and !std.mem.eql(u8, &c.user, &reader)) continue;
            try out.append(arena, entry);
        }
        return out.items;
    }

    pub fn versionVector(replica: *Replica, arena: std.mem.Allocator) !VersionVector {
        var entries: std.ArrayList(Entry) = .empty;
        // Most recently learned devices first, which puts a relayed device's
        // batches ahead of the invitation that admits it, as can happen.
        const s = try replica.db.prepare("SELECT device, seq FROM version_vector ORDER BY device DESC");
        defer s.finalize();
        while (try s.step()) {
            try entries.append(arena, .{ .device = replica.keys.items[@intCast(s.int(0) - 1)], .seq = @intCast(s.int(1)) });
        }
        return entries.items;
    }

    /// Order-independent fingerprint of every field's winning value.
    pub fn digest(replica: *Replica) ![32]u8 {
        var hasher = Blake3.init(.{});
        const s = try replica.db.prepare("SELECT key, field, value FROM winners ORDER BY key, field");
        defer s.finalize();
        while (try s.step()) {
            for (0..3) |i| {
                const column = s.blob(@intCast(i));
                var len: [4]u8 = undefined;
                std.mem.writeInt(u32, &len, @intCast(column.len), .little);
                hasher.update(&len);
                hasher.update(column);
            }
        }
        var out: [32]u8 = undefined;
        hasher.final(&out);
        return out;
    }

    /// Reads the batch of device `id` that holds `seq` into `leaves`.
    fn loadBatch(replica: *Replica, id: i64, seq: u64, leaves: *std.ArrayList(Hash)) !Batch {
        const s = try replica.db.prepare(
            \\SELECT first, root, sig, leaves FROM batches
            \\WHERE device = ?1 AND first <= ?2 ORDER BY first DESC LIMIT 1
        );
        defer s.finalize();
        try s.bindInt(1, id);
        try s.bindInt(2, @intCast(seq));
        if (!try s.step()) return error.NoBatch;
        leaves.clearRetainingCapacity();
        try leaves.appendSlice(replica.gpa, std.mem.bytesAsSlice(Hash, s.blob(3)));
        const batch: Batch = .{
            .device = replica.keys.items[@intCast(id - 1)],
            .first = @intCast(s.int(0)),
            .leaves = leaves.items,
            .root = s.blob(1)[0..32].*,
            .sig = s.blob(2)[0..64].*,
        };
        if (!batch.contains(seq)) return error.NoBatch;
        return batch;
    }
};

/// The user keys of a device's identity when the user's seed derives from the
/// device's (see `Identity.from`).
pub fn userKeyPair(seed: [32]u8) !Ed25519.KeyPair {
    return Ed25519.KeyPair.generateDeterministic(Identity.from(seed).user);
}

/// A library's ID derives from its founder, so every peer can tell who
/// founded it.
pub fn libraryId(founder: Device) op_.Library {
    var out: [32]u8 = undefined;
    Blake3.hash(&founder, &out, .{});
    return out[0..16].*;
}

fn certKey(buf: *[66]u8, device_key: Device) []const u8 {
    buf[0..2].* = "c/".*;
    buf[2..].* = std.fmt.bytesToHex(device_key, .lower);
    return buf;
}

fn certMessage(library: op_.Library, device_key: Device, private: bool) [20 + 16 + 32]u8 {
    var out: [20 + 16 + 32]u8 = undefined;
    out[0..20].* = if (private) "cinematheque private".* else "cinematheque device ".*;
    out[20..36].* = library;
    out[36..].* = device_key;
    return out;
}

fn parseHex(hex: []const u8) ?Device {
    var out: Device = undefined;
    if (hex.len != 64) return null;
    _ = std.fmt.hexToBytes(&out, hex) catch return null;
    return out;
}

/// The user a certificate names, if its signature holds.
pub fn verifyCertificate(library: op_.Library, device_key: Device, private: bool, cert: [96]u8) ?Device {
    const user = Ed25519.PublicKey.fromBytes(cert[0..32].*) catch return null;
    Ed25519.Signature.fromBytes(cert[32..96].*).verify(&certMessage(library, device_key, private), user) catch return null;
    return cert[0..32].*;
}

fn verifyRoot(device: Device, root: Hash, sig: op_.Signature) !void {
    try Ed25519.Signature.fromBytes(sig).verify(&root, try Ed25519.PublicKey.fromBytes(device));
}

/// Reads a winners row (kind, key, field, hlc, seq, value) as an operation.
fn rowOp(src: *Replica, s: sqlite.Stmt, device: Device) Op {
    return .{
        .library = src.library,
        .device = device,
        .kind = @enumFromInt(s.int(0)),
        .key = s.blob(1),
        .field = s.blob(2),
        .hlc = @bitCast(s.int(3)),
        .seq = @intCast(s.int(4)),
        .value = s.blob(5),
    };
}

/// The sync protocol. The receiver sends its version vector; the sender
/// answers with frames, all integers little-endian:
///
/// * `B` device (32) | first seq (8) | count (4) | signature (64) |
///   sent bitmap (count bits) | leaves of operations not sent (32 each),
///   followed by an `O` frame for each operation sent, in order
/// * `O` seq (8) | hlc (8) | kind (1) | key length (2) | key |
///   field length (2) | field | value length (4) | value
/// * `V` device (32) | seq (8), one per entry of the sender's vector
/// * `E`, the end
///
/// For each device, the sender sends its winning operations above the
/// receiver's vector, grouped by batch; the receiver rebuilds their leaves,
/// so only superseded operations' leaves travel, then checks each batch's
/// signature, and finally adopts the sender's vector, since it now holds
/// everything the sender does.
pub fn writeVector(w: *std.Io.Writer, vector: VersionVector) !void {
    try w.writeInt(u32, @intCast(vector.len), .little);
    for (vector) |entry| {
        try w.writeAll(&entry.device);
        try w.writeInt(u64, entry.seq, .little);
    }
}

pub fn readVector(arena: std.mem.Allocator, r: *std.Io.Reader) !VersionVector {
    const n = try r.takeInt(u32, .little);
    const entries = try arena.alloc(Entry, n);
    for (entries) |*entry| {
        try r.readSliceAll(&entry.device);
        entry.seq = try r.takeInt(u64, .little);
    }
    return entries;
}

const Row = struct { seq: u64, hlc: u64, kind: op_.Kind, key: []const u8, field: []const u8, value: []const u8 };

/// `reader` is the user the response is for: other users' private streams
/// (and their places in the version vector) are left out.
pub fn writeSync(src: *Replica, arena: std.mem.Allocator, wanted: VersionVector, reader: Device, w: *std.Io.Writer) !usize {
    var sent: usize = 0;
    var have: std.AutoHashMapUnmanaged(Device, u64) = .empty;
    for (wanted) |entry| try have.put(arena, entry.device, entry.seq);
    var leaves: std.ArrayList(Hash) = .empty;
    defer leaves.deinit(src.gpa);
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(src.gpa);
    var row_arena_state = std.heap.ArenaAllocator.init(src.gpa);
    defer row_arena_state.deinit();

    const theirs = try src.readableVector(arena, reader);
    for (theirs) |entry| {
        const from = have.get(entry.device) orelse 0;
        if (entry.seq <= from) continue;
        const id = src.ids.get(entry.device).?;
        const s = try src.db.prepare(
            \\SELECT kind, key, field, hlc, seq, value FROM winners
            \\WHERE device = ?1 AND seq > ?2 ORDER BY seq
        );
        defer s.finalize();
        try s.bindInt(1, id);
        try s.bindInt(2, @intCast(from));
        var batch: ?Batch = null;
        while (true) {
            const more = try s.step();
            const seq: u64 = if (more) @intCast(s.int(4)) else 0;
            if (batch) |*b| if (!more or !b.contains(seq)) {
                try writeBatch(w, b, rows.items);
                rows.clearRetainingCapacity();
                _ = row_arena_state.reset(.retain_capacity);
                batch = null;
            };
            if (!more) break;
            if (batch == null) batch = try src.loadBatch(id, seq, &leaves);
            const ra = row_arena_state.allocator();
            sent += 1;
            try rows.append(src.gpa, .{
                .kind = @enumFromInt(s.int(0)),
                .key = try ra.dupe(u8, s.blob(1)),
                .field = try ra.dupe(u8, s.blob(2)),
                .hlc = @bitCast(s.int(3)),
                .seq = seq,
                .value = try ra.dupe(u8, s.blob(5)),
            });
        }
    }
    for (theirs) |entry| {
        try w.writeByte('V');
        try w.writeAll(&entry.device);
        try w.writeInt(u64, entry.seq, .little);
    }
    try w.writeByte('E');
    return sent;
}

fn writeBatch(w: *std.Io.Writer, batch: *const Batch, rows: []const Row) !void {
    const count = batch.leaves.len;
    var sent: std.StaticBitSet(merkle.max_leaves) = .empty;
    for (rows) |row| sent.set(row.seq - batch.first);
    try w.writeByte('B');
    try w.writeAll(&batch.device);
    try w.writeInt(u64, batch.first, .little);
    try w.writeInt(u32, @intCast(count), .little);
    try w.writeAll(&batch.sig);
    try w.writeAll(std.mem.sliceAsBytes(&sent.masks)[0 .. (count + 7) / 8]);
    for (batch.leaves, 0..) |leaf, i| if (!sent.isSet(i)) try w.writeAll(&leaf);
    for (rows) |row| {
        try w.writeByte('O');
        try w.writeInt(u64, row.seq, .little);
        try w.writeInt(u64, row.hlc, .little);
        try w.writeByte(@intFromEnum(row.kind));
        try w.writeInt(u16, @intCast(row.key.len), .little);
        try w.writeAll(row.key);
        try w.writeInt(u16, @intCast(row.field.len), .little);
        try w.writeAll(row.field);
        try w.writeInt(u32, @intCast(row.value.len), .little);
        try w.writeAll(row.value);
    }
}

/// The sender's version vector, as a sync's frames end with it, for the
/// receiver to answer with what the sender lacks (a push).
pub const Theirs = struct { arena: std.mem.Allocator, vector: *std.ArrayList(Entry) };

/// Applies a sync's frames (a pulled response's, or a pushed request's) in
/// one transaction; nothing is kept unless they all check out.
pub fn readSync(dst: *Replica, r: *std.Io.Reader, theirs: ?Theirs) !Stats {
    var leaves: std.ArrayList(Hash) = .empty;
    defer leaves.deinit(dst.gpa);
    var ops: std.ArrayList(Op) = .empty;
    defer ops.deinit(dst.gpa);
    var text_state = std.heap.ArenaAllocator.init(dst.gpa);
    defer text_state.deinit();

    // Batches whose devices aren't yet known to act for members wait for
    // the rest of the response, which may hold their invitations.
    const Pending = struct { batch: Batch, leaves: []Hash, ops: []Op };
    var pending_state = std.heap.ArenaAllocator.init(dst.gpa);
    defer pending_state.deinit();
    const pa = pending_state.allocator();
    var pending: std.ArrayList(Pending) = .empty;
    var vector: std.ArrayList(Entry) = .empty;

    var stats: Stats = .{};
    try dst.begin();
    errdefer dst.db.exec("ROLLBACK") catch {};
    while (true) {
        const tag = try r.takeByte();
        stats.wire_bytes += 1;
        switch (tag) {
            'B' => {
                var batch: Batch = undefined;
                try r.readSliceAll(&batch.device);
                batch.first = try r.takeInt(u64, .little);
                const count = try r.takeInt(u32, .little);
                if (count == 0 or count > merkle.max_leaves) return error.Malformed;
                try r.readSliceAll(&batch.sig);
                var sent: std.StaticBitSet(merkle.max_leaves) = .empty;
                try r.readSliceAll(std.mem.sliceAsBytes(&sent.masks)[0 .. (count + 7) / 8]);
                try leaves.resize(dst.gpa, count);
                for (leaves.items, 0..) |*leaf, i| if (!sent.isSet(i)) try r.readSliceAll(leaf);
                // The operations sent follow, one per set bit.
                ops.clearRetainingCapacity();
                _ = text_state.reset(.retain_capacity);
                const ta = text_state.allocator();
                var it = sent.iterator(.{});
                while (it.next()) |i| {
                    if (i >= count or try r.takeByte() != 'O') return error.Malformed;
                    const seq = try r.takeInt(u64, .little);
                    if (seq != batch.first + i) return error.Malformed;
                    const hlc = try r.takeInt(u64, .little);
                    const kind = std.enums.fromInt(op_.Kind, try r.takeByte()) orelse return error.Malformed;
                    const key = try ta.alloc(u8, try r.takeInt(u16, .little));
                    try r.readSliceAll(key);
                    const field = try ta.alloc(u8, try r.takeInt(u16, .little));
                    try r.readSliceAll(field);
                    const value = try ta.alloc(u8, try r.takeInt(u32, .little));
                    try r.readSliceAll(value);
                    const op: Op = .{ .library = dst.library, .device = batch.device, .seq = seq, .hlc = hlc, .kind = kind, .key = key, .field = field, .value = value };
                    try ops.append(dst.gpa, op);
                    stats.wire_bytes += 1 + op.wireLen();
                }
                dst.receiveBatch(batch, leaves.items, ops.items, &stats) catch |err| switch (err) {
                    error.Unauthorized => {
                        const copied = try pa.dupe(Op, ops.items);
                        for (copied) |*op| {
                            op.key = try pa.dupe(u8, op.key);
                            op.field = try pa.dupe(u8, op.field);
                            op.value = try pa.dupe(u8, op.value);
                        }
                        try pending.append(pa, .{ .batch = batch, .leaves = try pa.dupe(Hash, leaves.items), .ops = copied });
                    },
                    else => |e| return e,
                };
                stats.batches += 1;
                stats.wire_bytes += Batch.header_wire_len + (count + 7) / 8 + 32 * (count - ops.items.len);
            },
            'V' => {
                var entry: Entry = undefined;
                try r.readSliceAll(&entry.device);
                entry.seq = try r.takeInt(u64, .little);
                try vector.append(pa, entry);
                if (theirs) |t| try t.vector.append(t.arena, entry);
                stats.wire_bytes += 40;
            },
            'E' => break,
            else => return error.Malformed,
        }
    }
    var progress = true;
    while (progress) {
        progress = false;
        var i: usize = 0;
        while (i < pending.items.len) {
            const p = pending.items[i];
            if (dst.receiveBatch(p.batch, p.leaves, p.ops, &stats)) {
                _ = pending.swapRemove(i);
                stats.deferred += 1;
                progress = true;
            } else |err| switch (err) {
                error.Unauthorized => i += 1,
                else => |e| return e,
            }
        }
    }
    // Don't claim what was rejected, so it can be accepted once its
    // device's invitation arrives.
    for (vector.items) |entry| {
        var seq = entry.seq;
        for (pending.items) |p| if (std.mem.eql(u8, &p.batch.device, &entry.device)) {
            seq = @min(seq, p.batch.first - 1);
        };
        if (seq > 0) try dst.advance(try dst.deviceId(entry.device), seq);
    }
    for (pending.items) |p| stats.rejected += p.ops.len;
    try dst.commit();
    return stats;
}

/// Syncs in memory, through the same encoding a network would carry.
pub fn sync(arena: std.mem.Allocator, dst: *Replica, src: *Replica) !Stats {
    var request: std.Io.Writer.Allocating = .init(arena);
    try writeVector(&request.writer, try dst.versionVector(arena));
    var request_reader: std.Io.Reader = .fixed(request.written());
    const wanted = try readVector(arena, &request_reader);

    var response: std.Io.Writer.Allocating = .init(arena);
    _ = try writeSync(src, arena, wanted, dst.userKey(), &response.writer);
    var response_reader: std.Io.Reader = .fixed(response.written());
    var stats = try readSync(dst, &response_reader, null);
    stats.wire_bytes = request.written().len + response.written().len;
    return stats;
}

/// Refetches the fields a removal dropped (see `Replica.cut`) from a peer,
/// whose winners exclude the refused writes.
pub fn repair(dst: *Replica, src: *Replica) !Stats {
    var arena_state = std.heap.ArenaAllocator.init(src.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fields: std.ArrayList(Field) = .empty;
    const s = try dst.db.prepare("SELECT key, field FROM repair");
    defer s.finalize();
    while (try s.step()) try fields.append(arena, .{
        .key = try arena.dupe(u8, s.blob(0)),
        .field = try arena.dupe(u8, s.blob(1)),
    });
    return fetchFields(dst, src, fields.items);
}

const Field = struct { key: []const u8, field: []const u8 };

/// Fetches `fields`' winning operations from `src`: for each batch they
/// come from, its device, range, and signature, the operations' indices,
/// one shared proof, and the operations, which `dst` verifies against the
/// batch's signed root without the batch's other leaves. Batches not yet
/// admitted wait for the rest of the fetch.
fn fetchFields(dst: *Replica, src: *Replica, fields: []const Field) !Stats {
    const gpa = src.gpa;
    var leaves: std.ArrayList(Hash) = .empty;
    defer leaves.deinit(gpa);
    const tree = try gpa.create(merkle.Tree);
    defer gpa.destroy(tree);
    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(gpa);
    var siblings: std.ArrayList(Hash) = .empty;
    defer siblings.deinit(gpa);
    var ops: std.ArrayList(Op) = .empty;
    defer ops.deinit(gpa);
    var text_state = std.heap.ArenaAllocator.init(gpa);
    defer text_state.deinit();
    const Pending = struct { batch: Batch, count: usize, indices: []usize, siblings: []Hash, ops: []Op };
    var pending_state = std.heap.ArenaAllocator.init(gpa);
    defer pending_state.deinit();
    const pa = pending_state.allocator();
    var pending: std.ArrayList(Pending) = .empty;

    var stats: Stats = .{};
    try dst.begin();
    errdefer dst.db.exec("ROLLBACK") catch {};
    for (fields) |f| {
        const s = try src.db.prepare(
            \\SELECT kind, key, field, hlc, seq, value, device FROM winners
            \\WHERE key = ?1 AND field = ?2
        );
        defer s.finalize();
        try s.bindText(1, f.key);
        try s.bindText(2, f.field);
        var batch: ?Batch = null;
        var batch_id: i64 = 0;
        while (true) {
            const more = try s.step();
            const id = if (more) s.int(6) else 0;
            const seq: u64 = if (more) @intCast(s.int(4)) else 0;
            if (batch) |b| if (!more or batch_id != id or !b.contains(seq)) {
                tree.init(b.leaves);
                siblings.clearRetainingCapacity();
                try tree.multiproof(indices.items, gpa, &siblings);
                dst.receiveShared(b, b.leaves.len, indices.items, siblings.items, ops.items, &stats) catch |err| switch (err) {
                    error.Unauthorized => {
                        const copied = try pa.dupe(Op, ops.items);
                        for (copied) |*op| {
                            op.key = try pa.dupe(u8, op.key);
                            op.field = try pa.dupe(u8, op.field);
                            op.value = try pa.dupe(u8, op.value);
                        }
                        var held = b;
                        held.leaves = &.{};
                        try pending.append(pa, .{ .batch = held, .count = b.leaves.len, .indices = try pa.dupe(usize, indices.items), .siblings = try pa.dupe(Hash, siblings.items), .ops = copied });
                    },
                    else => |e| return e,
                };
                stats.batches += 1;
                stats.wire_bytes += Batch.header_wire_len + 2 + 2 * indices.items.len + 32 * siblings.items.len;
                for (ops.items) |op| stats.wire_bytes += op.wireLen();
                indices.clearRetainingCapacity();
                ops.clearRetainingCapacity();
                _ = text_state.reset(.retain_capacity);
                batch = null;
            };
            if (!more) break;
            if (batch == null) {
                batch = try src.loadBatch(id, seq, &leaves);
                batch_id = id;
            }
            const ta = text_state.allocator();
            var op = rowOp(src, s, src.keys.items[@intCast(id - 1)]);
            op.key = try ta.dupe(u8, op.key);
            op.field = try ta.dupe(u8, op.field);
            op.value = try ta.dupe(u8, op.value);
            try ops.append(gpa, op);
            try indices.append(gpa, seq - batch.?.first);
        }
    }
    var progress = true;
    while (progress) {
        progress = false;
        var i: usize = 0;
        while (i < pending.items.len) {
            const p = pending.items[i];
            if (dst.receiveShared(p.batch, p.count, p.indices, p.siblings, p.ops, &stats)) {
                _ = pending.swapRemove(i);
                stats.deferred += 1;
                progress = true;
            } else |err| switch (err) {
                error.Unauthorized => i += 1,
                else => |e| return e,
            }
        }
    }
    for (pending.items) |p| stats.rejected += p.ops.len;
    try dst.commit();
    return stats;
}

const testing = std.testing;

fn testUser(seed: u8) !Device {
    return (try userKeyPair(@splat(seed))).public_key.toBytes();
}

const Peers = struct {
    arena_state: std.heap.ArenaAllocator,
    replicas: [3]Replica,

    /// Replica 0's user founds the library; `added` of the others' users
    /// are members, and every replica has caught up with replica 0.
    fn initAdding(peers: *Peers, added: usize) !void {
        peers.arena_state = .init(testing.allocator);
        const founder = try testUser(1);
        for (&peers.replicas, 1..) |*r, seed| {
            r.* = try Replica.open(testing.allocator, testing.io, ":memory:", founder, .from(@splat(@intCast(seed))));
        }
        for (1..added + 1) |i| try peers.replicas[0].addMember(1, try testUser(@intCast(i + 1)));
        for (1..peers.replicas.len) |i| _ = try peers.sync(i, 0);
    }

    fn init(peers: *Peers) !void {
        try peers.initAdding(2);
    }

    fn deinit(peers: *Peers) void {
        for (&peers.replicas) |*r| r.close();
        peers.arena_state.deinit();
    }

    fn sync(peers: *Peers, dst: usize, src: usize) !Stats {
        return replica_sync(peers.arena_state.allocator(), &peers.replicas[dst], &peers.replicas[src]);
    }

    fn value(peers: *Peers, r: usize, key: []const u8, field: []const u8) ![]const u8 {
        const s = try peers.replicas[r].db.prepare("SELECT value FROM winners WHERE key = ?1 AND field = ?2");
        defer s.finalize();
        try s.bindText(1, key);
        try s.bindText(2, field);
        if (!try s.step()) return error.Missing;
        return peers.arena_state.allocator().dupe(u8, s.blob(0));
    }
};

const replica_sync = sync;

test "concurrent writes to one field converge on the later one" {
    var p: Peers = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];
    const b = &p.replicas[1];

    try a.write(1000, "t/00001", "name", "Metropolis");
    try a.write(1000, "t/00001", "year", "1927");
    _ = try p.sync(1, 0);
    try a.write(2000, "t/00001", "name", "Metropolis (1927)");
    try b.write(3000, "t/00001", "name", "Metropolis (restored)");
    _ = try p.sync(1, 0);
    _ = try p.sync(0, 1);

    try testing.expectEqual(try a.digest(), try b.digest());
    try testing.expectEqualStrings("Metropolis (restored)", try p.value(0, "t/00001", "name"));
}

test "sync sends only what the receiver lacks" {
    var p: Peers = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];

    try a.begin();
    for (0..10) |i| {
        var key: [16]u8 = undefined;
        try a.write(1000, try std.fmt.bufPrint(&key, "t/{d:0>5}", .{i}), "name", "x");
    }
    try a.commit();
    const first = try p.sync(1, 0);
    try testing.expectEqual(@as(usize, 10), first.sent);
    try testing.expectEqual(@as(usize, 1), first.batches);
    try a.write(2000, "t/00003", "name", "y");
    try testing.expectEqual(@as(usize, 1), (try p.sync(1, 0)).sent);
    try testing.expectEqual(@as(usize, 0), (try p.sync(1, 0)).sent);
}

test "writes in a transaction share signatures, up to the batch limit" {
    var p: Peers = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];

    try a.begin();
    for (0..merkle.max_leaves + 5) |i| {
        var key: [16]u8 = undefined;
        try a.write(1000, try std.fmt.bufPrint(&key, "t/{d:0>5}", .{i}), "name", "x");
    }
    try a.commit();
    // Two batches beyond the certificate's and the two invitations'.
    try testing.expectEqual(@as(i64, 5), try a.db.scalar("SELECT count(*) FROM batches"));
    const stats = try p.sync(1, 0);
    try testing.expectEqual(@as(usize, 2), stats.batches);
    _ = try p.sync(0, 1); // a takes b's certificate, so the two match
    try testing.expectEqual(try a.digest(), try p.replicas[1].digest());
}

test "relayed operations reach a third peer, and superseded ones are skipped" {
    var p: Peers = undefined;
    try p.init();
    defer p.deinit();

    try p.replicas[0].write(1000, "t/00001", "name", "first");
    try p.replicas[0].write(1001, "t/00002", "name", "kept");
    _ = try p.sync(1, 0);
    try p.replicas[1].write(2000, "t/00001", "name", "second");
    _ = try p.sync(2, 1);
    _ = try p.sync(0, 2);

    try testing.expectEqualStrings("second", try p.value(0, "t/00001", "name"));
    try testing.expectEqualStrings("second", try p.value(2, "t/00001", "name"));
    try testing.expectEqualStrings("kept", try p.value(2, "t/00002", "name"));
}

test "a tampered operation or signature is rejected" {
    var p: Peers = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];

    try a.write(1000, "t/00001", "name", "Metropolis");
    try a.db.exec("UPDATE winners SET value = 'Metropolix' WHERE key = 't/00001'");
    try testing.expectError(error.SignatureVerificationFailed, p.sync(1, 0));
    try a.db.exec("UPDATE winners SET value = 'Metropolis' WHERE key = 't/00001'");
    try a.db.exec("UPDATE batches SET sig = zeroblob(64) WHERE first = (SELECT max(first) FROM batches)");
    if (p.sync(1, 0)) |_| return error.TestUnexpectedResult else |_| {}
}

test "set membership: concurrent add and remove, then re-add" {
    var p: Peers = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];
    const b = &p.replicas[1];

    try a.setMember(1000, "l/watchlist", "t/00001", true);
    _ = try p.sync(1, 0);
    // Concurrently, a removes the element and b re-adds it (a no-op, since
    // b already holds it): the removal wins.
    try a.setMember(2000, "l/watchlist", "t/00001", false);
    try b.setMember(2000, "l/watchlist", "t/00001", true);
    _ = try p.sync(1, 0);
    _ = try p.sync(0, 1);
    try testing.expect(!try a.isMember("l/watchlist", "t/00001"));
    try testing.expect(!try b.isMember("l/watchlist", "t/00001"));
    // Re-adding after seeing the removal brings it back everywhere.
    try b.setMember(3000, "l/watchlist", "t/00001", true);
    _ = try p.sync(0, 1);
    try testing.expect(try a.isMember("l/watchlist", "t/00001"));
}

test "fetched fields are verified by shared proof" {
    var p: Peers = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];

    try a.begin();
    for (0..50) |i| {
        var key: [16]u8 = undefined;
        try a.write(1000, try std.fmt.bufPrint(&key, "t/{d:0>5}", .{i / 10}), try std.fmt.bufPrint(key[8..], "f{d}", .{i}), "x");
    }
    try a.commit();
    // The certificate that admits a's device, then two fields of its batch.
    var cert: [66]u8 = undefined;
    _ = try fetchFields(&p.replicas[2], a, &.{.{ .key = certKey(&cert, a.device()), .field = "user" }});
    const stats = try fetchFields(&p.replicas[2], a, &.{ .{ .key = "t/00002", .field = "f20" }, .{ .key = "t/00002", .field = "f21" } });
    try testing.expectEqual(@as(usize, 2), stats.won);
    try a.db.exec("UPDATE winners SET value = 'y' WHERE key = 't/00003' AND field = 'f30'");
    try testing.expectError(error.SignatureVerificationFailed, fetchFields(&p.replicas[2], a, &.{.{ .key = "t/00003", .field = "f30" }}));
}

test "batches from devices of users who aren't members are rejected, then accepted once added" {
    var p: Peers = undefined;
    try p.initAdding(1); // replica 2's user isn't a member
    defer p.deinit();
    const a = &p.replicas[0];
    const c = &p.replicas[2];

    try c.write(1000, "t/00001", "name", "Unadded");
    const rejected = try p.sync(1, 2);
    try testing.expect(rejected.rejected > 0);
    try testing.expectError(error.Missing, p.value(1, "t/00001", "name"));

    // a adds c's user; b hears of it from a, then accepts c's writes,
    // since b didn't claim them in its version vector.
    try a.addMember(2000, try testUser(3));
    _ = try p.sync(1, 0);
    const accepted = try p.sync(1, 2);
    try testing.expectEqual(@as(usize, 0), accepted.rejected);
    try testing.expectEqualStrings("Unadded", try p.value(1, "t/00001", "name"));
}

test "a device whose certificate doesn't verify writes a fresh one, and its whole stream is accepted" {
    var p: Peers = undefined;
    try p.init();
    defer p.deinit();
    const c = &p.replicas[2];

    // c's stream starts with a certificate signed for another library.
    var key: [66]u8 = undefined;
    const sig = try c.user.sign(&certMessage(libraryId(@splat(9)), c.device(), false), null);
    try c.write(0, certKey(&key, c.device()), "user", &(c.userKey() ++ sig.toBytes()));
    c.checked_certificate = true; // As an older build would, c doesn't check.
    try c.write(1000, "t/00001", "name", "Metropolis");
    try testing.expect((try p.sync(1, 2)).rejected > 0);
    try testing.expectError(error.Missing, p.value(1, "t/00001", "name"));

    // Opened again, c rewrites the certificate before writing anything.
    c.checked_certificate = false;
    c.hlc = .{};
    try c.recertify(1500);
    try testing.expectEqual(@as(usize, 0), (try p.sync(1, 2)).rejected);
    try testing.expectEqualStrings("Metropolis", try p.value(1, "t/00001", "name"));

    // And again: it checks, and certifies afresh,
    // even when it writes only private data.
    c.checked_certificate = false;
    c.hlc = .{};
    try c.writePrivate(2000, try std.fmt.allocPrint(p.arena_state.allocator(), "p/{s}/t/m/x/2000/v/-", .{std.fmt.bytesToHex(c.userKey(), .lower)}), &.{.{ "position", "60000" }});
    try c.write(2000, "t/00002", "name", "Nosferatu");
    const stats = try p.sync(1, 2);
    try testing.expectEqual(@as(usize, 0), stats.rejected);
    try testing.expectEqualStrings("Metropolis", try p.value(1, "t/00001", "name"));
    try testing.expectEqualStrings("Nosferatu", try p.value(1, "t/00002", "name"));
}

test "a device removed has its later writes refused, though its user stays" {
    var p: Peers = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];
    const c = &p.replicas[2];

    try c.write(1000, "t/00001", "name", "Before");
    _ = try p.sync(0, 2);
    try a.revokeDevice(2000, c.device());
    try c.write(3000, "t/00002", "name", "After");
    _ = try p.sync(1, 0);
    const stats = try p.sync(1, 2);
    try testing.expect(stats.refused > 0);
    try testing.expectEqualStrings("Before", try p.value(1, "t/00001", "name"));
    try testing.expectError(error.Missing, p.value(1, "t/00002", "name"));
    try testing.expect(try c.isMemberUser(c.userKey()));
    try testing.expectError(error.ThisDevice, a.revokeDevice(4000, a.device()));
}

test "an invitation later in the same response admits earlier batches" {
    var p: Peers = undefined;
    try p.initAdding(1);
    defer p.deinit();
    const a = &p.replicas[0];
    const c = &p.replicas[2];

    // a learns c's writes before inviting c's user, so a rejects them;
    // after inviting, a takes them on the next sync.
    try c.write(1000, "t/00002", "name", "Relayed");
    try testing.expect((try p.sync(0, 2)).rejected > 0);
    try a.addMember(2000, try testUser(3));
    _ = try p.sync(0, 2);
    // b, fresh, gets c's batches and a's invitation in one response from a,
    // in whatever order the devices come.
    const b_stats = try p.sync(1, 0);
    try testing.expectEqual(@as(usize, 0), b_stats.rejected);
    try testing.expect(b_stats.deferred > 0);
    try testing.expectEqualStrings("Relayed", try p.value(1, "t/00002", "name"));
}

test "a peer that took a removed device's later writes repairs from one that refused them" {
    var p: Peers = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];
    const b = &p.replicas[1];
    const c = &p.replicas[2];

    try b.write(1000, "t/00001", "name", "before");
    _ = try p.sync(0, 1);
    try a.revokeDevice(2000, b.device());
    try b.write(3000, "t/00001", "name", "after");
    // c hears from b before hearing of the removal, so takes the later write;
    // hearing of it drops it, and repairing from a restores what stands.
    _ = try p.sync(2, 1);
    try testing.expectEqualStrings("after", try p.value(2, "t/00001", "name"));
    _ = try p.sync(2, 0);
    try testing.expectEqual(@as(i64, 1), try c.repairsPending());
    _ = try repair(c, a);
    try testing.expectEqualStrings("before", try p.value(2, "t/00001", "name"));
    try testing.expect(try c.isMemberUser(b.userKey()));
}

test "the founder can't be removed" {
    var p: Peers = undefined;
    try p.init();
    defer p.deinit();
    try testing.expectError(error.FounderIsPermanent, p.replicas[1].removeMember(1000, try testUser(1)));
}

test "a removed member's writes up to the cutoff stand, and later ones are refused" {
    var p: Peers = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];
    const b = &p.replicas[1];

    try b.write(1000, "t/00001", "name", "before");
    _ = try p.sync(0, 1);
    try a.removeMember(2000, try testUser(2));
    try b.write(3000, "t/00001", "name", "after");
    try b.write(3000, "t/00002", "name", "new");
    const stats = try p.sync(0, 1);
    try testing.expectEqual(@as(usize, 2), stats.refused);
    try testing.expectEqualStrings("before", try p.value(0, "t/00001", "name"));
    try testing.expectError(error.Missing, p.value(0, "t/00002", "name"));
}

test "a peer that took a removed member's later writes repairs from one that refused them" {
    var p: Peers = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];
    const b = &p.replicas[1];
    const c = &p.replicas[2];

    try b.write(1000, "t/00001", "name", "before");
    _ = try p.sync(0, 1);
    try a.removeMember(2000, try testUser(2));
    try b.write(3000, "t/00001", "name", "after");
    try b.write(3000, "t/00002", "name", "new");
    // c hears from b before hearing of the removal, so takes the later writes.
    _ = try p.sync(2, 1);
    try testing.expectEqualStrings("after", try p.value(2, "t/00001", "name"));
    // Hearing of it drops them, and repairing from a restores what stands.
    _ = try p.sync(2, 0);
    try testing.expectEqual(@as(i64, 2), try c.repairsPending());
    _ = try repair(c, a);
    try testing.expectEqualStrings("before", try p.value(2, "t/00001", "name"));
    try testing.expectError(error.Missing, p.value(2, "t/00002", "name"));
    // The field a never had stays pending, in case another peer has it.
    try testing.expectEqual(@as(i64, 1), try c.repairsPending());
    // b's later writes stay refused, from b or anyone.
    _ = try p.sync(2, 1);
    try testing.expectEqualStrings("before", try p.value(2, "t/00001", "name"));
    _ = try p.sync(0, 2);
    try testing.expectEqualStrings("before", try p.value(0, "t/00001", "name"));
}

test "the founder hands over to a successor, who is then permanent" {
    var p: Peers = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];
    const b = &p.replicas[1];
    const c = &p.replicas[2];

    try a.handOver(1000, try testUser(2), true);
    _ = try p.sync(1, 0);
    _ = try p.sync(2, 0);
    for (&p.replicas) |*r| try testing.expectEqual(try testUser(2), r.founder);
    // The former founder, still a member, can be removed, but not the new one.
    try testing.expectError(error.FounderIsPermanent, a.removeMember(2000, try testUser(2)));
    try b.removeMember(2000, try testUser(1));
    _ = try p.sync(2, 1);
    try testing.expect(!try c.isMemberUser(try testUser(1)));
    // Only the founder may hand over.
    try testing.expectError(error.NotFounder, c.handOver(3000, try testUser(3), true));
}

test "a handover not from the founder is refused" {
    var p: Peers = undefined;
    try p.init();
    defer p.deinit();
    const b = &p.replicas[1];

    // b forges generation 1, naming itself.
    try b.write(1000, "founders", "000001", &(try testUser(2)));
    const stats = try p.sync(0, 1);
    try testing.expectEqual(@as(usize, 1), stats.refused);
    try testing.expectEqual(try testUser(1), p.replicas[0].founder);
}

test "a chain of handovers arriving out of order is followed" {
    var p: Peers = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];
    const b = &p.replicas[1];

    try a.handOver(1000, try testUser(2), false);
    _ = try p.sync(1, 0);
    try b.handOver(2000, try testUser(3), true);
    // c learned of a's device before b's, so a fresh peer syncing from c
    // gets b's generation 2 ahead of a's generation 1 (devices learned last
    // come first), holds it, then follows the chain.
    _ = try p.sync(2, 1);
    var d = try Replica.open(testing.allocator, testing.io, ":memory:", try testUser(1), .from(@splat(9)));
    defer d.close();
    const stats = try replica_sync(p.arena_state.allocator(), &d, &p.replicas[2]);
    try testing.expect(stats.deferred > 0);
    try testing.expectEqual(try testUser(3), d.founder);
    // a left the library when handing over.
    try testing.expect(!try d.isMemberUser(try testUser(1)));
}

test "private data reaches its user's other devices, directly, and no one else" {
    var p: Peers = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];
    const b = &p.replicas[1];
    // b2 is another device of b's user.
    var b2 = try Replica.open(testing.allocator, testing.io, ":memory:", try testUser(1), .{ .device = @splat(42), .user = Identity.from(@splat(2)).user });
    defer b2.close();
    const key = try std.fmt.allocPrint(p.arena_state.allocator(), "p/{s}/t/m/alien/1979/v/-", .{std.fmt.bytesToHex(b.userKey(), .lower)});

    try b.write(1000, "t/m/alien/1979", "name", "Alien");
    try b.writePrivate(2000, key, &.{ .{ "position", "1234" }, .{ "duration", "7000" } });
    // a, another user, gets b's public writes but not its private ones.
    _ = try p.sync(0, 1);
    try testing.expectEqualStrings("Alien", try p.value(0, "t/m/alien/1979", "name"));
    try testing.expectError(error.Missing, p.value(0, key, "position"));
    // Nor can a relay them: b2 learns nothing private through a, and isn't
    // misled into thinking it has.
    _ = try replica_sync(p.arena_state.allocator(), &b2, a);
    try testing.expectEqual(@as(i64, 0), try b2.db.scalar("SELECT count(*) FROM winners WHERE key LIKE 'p/%'"));
    _ = try replica_sync(p.arena_state.allocator(), &b2, b);
    const s = try b2.db.prepare("SELECT value FROM winners WHERE key = ?1 AND field = 'position'");
    defer s.finalize();
    try s.bindText(1, key);
    try testing.expect(try s.step());
    try testing.expectEqualStrings("1234", s.blob(0));
}

test "private data written by anyone but its user's private stream is refused" {
    var p: Peers = undefined;
    try p.init();
    defer p.deinit();
    const b = &p.replicas[1];
    const c = &p.replicas[2];
    // c forges into b's private data, from its public stream.
    const key = try std.fmt.allocPrint(p.arena_state.allocator(), "p/{s}/t/m/alien/1979/v/-", .{std.fmt.bytesToHex(b.userKey(), .lower)});
    try c.write(1000, key, "position", "1");
    const stats = try p.sync(0, 2);
    try testing.expectEqual(@as(usize, 1), stats.refused);
    // And writePrivate takes only this user's keys.
    try testing.expectError(error.NotPrivate, c.writePrivate(1000, key, &.{.{ "position", "1" }}));
}

test "a device that lost its replica gets its own private data back" {
    var p: Peers = undefined;
    try p.init();
    defer p.deinit();
    const b = &p.replicas[1];
    const key = try std.fmt.allocPrint(p.arena_state.allocator(), "p/{s}/t/m/alien/1979/v/-", .{std.fmt.bytesToHex(b.userKey(), .lower)});
    try b.write(1000, "t/m/alien/1979", "name", "Alien");
    try b.writePrivate(2000, key, &.{.{ "position", "1234" }});
    // b2 is b's device again, with its replica lost (as tvOS may purge
    // one), rebuilt from a peer of its user's.
    var b2 = try Replica.open(testing.allocator, testing.io, ":memory:", try testUser(1), .{ .device = @splat(2), .user = Identity.from(@splat(2)).user });
    defer b2.close();
    try testing.expectEqualSlices(u8, &b.device(), &b2.device());
    const stats = try replica_sync(p.arena_state.allocator(), &b2, b);
    try testing.expectEqual(@as(usize, 0), stats.refused);
    const s = try b2.db.prepare("SELECT value FROM winners WHERE key = ?1 AND field = 'position'");
    defer s.finalize();
    try s.bindText(1, key);
    try testing.expect(try s.step());
    try testing.expectEqualStrings("1234", s.blob(0));
}

test "a device whose first write is private is still certified" {
    var p: Peers = undefined;
    try p.init();
    defer p.deinit();
    const b = &p.replicas[1];
    const key = try std.fmt.allocPrint(p.arena_state.allocator(), "p/{s}/t/m/alien/1979/v/-", .{std.fmt.bytesToHex(b.userKey(), .lower)});
    try b.writePrivate(1000, key, &.{.{ "position", "1" }});
    const stats = try p.sync(0, 1);
    try testing.expectEqual(@as(usize, 0), stats.rejected);
    try testing.expect(try p.replicas[0].certifiedUser(b.device(), &.{}) != null);
}

test "two connections writing in turn, refreshing first, never reuse a sequence number" {
    const path = "/tmp/cinematheque-refresh-test.db";
    std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
    const founder = (try userKeyPair(@splat(1))).public_key.toBytes();
    var a = try Replica.open(testing.allocator, testing.io, path, founder, .from(@splat(1)));
    defer a.close();
    var b = try Replica.open(testing.allocator, testing.io, path, founder, .from(@splat(1)));
    defer b.close();
    try a.write(1000, "t/m/a/-", "name", "A");
    try b.refresh();
    try b.write(2000, "t/m/b/-", "name", "B");
    try a.refresh();
    try a.write(3000, "t/m/c/-", "name", "C");
    // The device's writes are numbered 1 (its certificate) through 4.
    try testing.expectEqual(@as(u64, 4), a.seq);
    try testing.expectEqual(@as(i64, 4), try a.db.scalar("SELECT count(DISTINCT seq) FROM winners WHERE device = 1"));
}
