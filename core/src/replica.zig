//! One device's replica of one library, in SQLite: each field's winning
//! operation, the signed batches that vouch for operations, and a version
//! vector of what the replica has seen.

const std = @import("std");
const Io = std.Io;
const Ed25519 = std.crypto.sign.Ed25519;
const Blake3 = std.crypto.hash.Blake3;
const sqlite = @import("sqlite.zig");
const lists = @import("lists.zig");
const merkle = @import("merkle.zig");
const Hlc = @import("hlc.zig").Hlc;
const op_ = @import("op.zig");
const Op = op_.Op;
const Device = op_.Device;
const Hash = merkle.Hash;

/// The highest sequence number a device accepts: sequences are stored as
/// signed 64-bit integers, and a batch's `first + count` must not overflow.
pub const max_seq: u64 = std.math.maxInt(i63);

/// What frames may claim before their signatures are checked, so a gzip bomb
/// can't exhaust memory: one value, the text of one batch's operations, and
/// the text of the batches held back for a response's end.
pub const max_value_len = 4 << 20;
pub const max_batch_bytes = 64 << 20;
pub const max_pending_bytes = 256 << 20;

/// The most devices a version vector may name (two streams each).
pub const max_vector_entries = 1 << 16;

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
    \\-- Per device (interned), the highest sequence number this replica
    \\-- covers, sent with sync requests.
    \\CREATE TABLE IF NOT EXISTS version_vector (
    \\  device INTEGER PRIMARY KEY,
    \\  seq INTEGER NOT NULL
    \\);
    \\-- The other's own state, which doesn't replicate (e.g., crawl snapshots).
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
    /// device, range, signature, and leaves.
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

    pub const header_wire_len = 32 + 8 + 4 + 64;

    pub fn contains(batch: *const Batch, seq: u64) bool {
        return seq >= batch.first and seq < batch.first + batch.leaves.len;
    }
};

/// A device's secrets: its own seed, from which its device keys derive, and
/// its person's, which the person's devices share.
pub const Identity = struct {
    device: [32]u8,
    person: [32]u8,

    /// A device's identity when its person has no other devices yet: the
    /// person's seed derives from the device's.
    pub fn from(device_seed: [32]u8) Identity {
        return .{ .device = device_seed, .person = derive("cinematheque user", device_seed) };
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
    /// The person who created the library, from whom its ID derives: a
    /// member from the start, without a `members` write, until removed.
    genesis: Device,
    /// The person this device acts for, who certifies its key.
    person: Ed25519.KeyPair,
    key_pair: Ed25519.KeyPair,
    own: i64,
    seq: u64,
    /// The device's private stream: its own key, numbering, and batches, for
    /// its person's private data (`p/<person>/...`), which replicates only among
    /// that person's devices.
    private_pair: Ed25519.KeyPair,
    private_own: i64 = 0,
    private_seq: u64 = 0,
    hlc: Hlc = .{},
    /// Check signatures of received batches; off only to measure their cost.
    verify: bool = true,
    /// The wall-clock time operations are received at, in milliseconds,
    /// set by syncing: an operation dated more than a day past it is
    /// refused, else it could hold its field for good, and push every
    /// device's clock to its end. Unset, as in tests, any date is taken.
    now_ms: ?u64 = null,
    /// Interned device keys: `keys[id - 1]` is the key of device `id`.
    keys: std.ArrayList(Device) = .empty,
    ids: std.AutoHashMapUnmanaged(Device, i64) = .empty,
    body: std.ArrayList(u8) = .empty,
    /// Leaves of local writes not yet signed, starting at `pending_first`.
    pending: std.ArrayList(Hash) = .empty,
    pending_first: u64 = 0,
    batching: bool = false,
    /// The streams' numbering when `begin` started, to restore on `rollback`.
    begun_seq: u64 = 0,
    begun_private_seq: u64 = 0,
    /// Whether this connection has checked the device's own certificates,
    /// its stream's and its private stream's, before writing on them.
    checked_certificate: bool = false,
    checked_private_certificate: bool = false,
    /// Whether a removal dropped winners this replica held (see `cut`), so
    /// its next pull asks for everything (`requestVector`), taking again
    /// what it held before them; kept in `local` as `refill`.
    refilling: bool = false,
    select_winner: sqlite.Stmt,
    upsert_winner: sqlite.Stmt,
    select_version: sqlite.Stmt,
    upsert_version: sqlite.Stmt,
    insert_device: sqlite.Stmt,
    insert_batch: sqlite.Stmt,

    /// Opens a replica of the library `creator` created, as the device and
    /// person `identity` gives. A device writes its certificate with its first
    /// write, so devices that only read never need one.
    pub fn open(gpa: std.mem.Allocator, io: Io, path: [:0]const u8, creator: Device, identity: Identity) !Replica {
        const db = try sqlite.Db.open(path, io);
        // The replica closes the database once it's built, not before.
        var built = false;
        errdefer if (!built) db.close();
        try db.exec(schema);
        var replica: Replica = .{
            .gpa = gpa,
            .db = db,
            .library = libraryId(creator),
            .genesis = creator,
            .person = try Ed25519.KeyPair.generateDeterministic(identity.person),
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
        built = true;
        errdefer replica.close();
        const s = try db.prepare("SELECT id, key FROM devices ORDER BY id");
        defer s.finalize();
        while (try s.step()) try replica.intern(s.int(0), s.blob(1)[0..32].*);
        replica.own = try replica.deviceId(replica.device());
        replica.seq = try replica.seen(replica.own);
        replica.private_own = try replica.deviceId(replica.private_pair.public_key.toBytes());
        replica.private_seq = try replica.seen(replica.private_own);
        replica.refilling = try db.scalar("SELECT count(*) FROM local WHERE key = 'refill'") > 0;
        try replica.observeOwn();
        return replica;
    }

    /// The person's key and signature over `"cinematheque device" | library |
    /// device key`, or, for a private stream, `"cinematheque private" |
    /// library | key`.
    pub fn certificate(replica: *const Replica, private: bool) ![96]u8 {
        const key = if (private) replica.private_pair.public_key.toBytes() else replica.device();
        const sig = try replica.person.sign(&certMessage(replica.library, key, private), null);
        var value: [96]u8 = undefined;
        value[0..32].* = replica.person.public_key.toBytes();
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
        if (!try replica.ownCertified(false)) try replica.certify(wall_ms);
        replica.checked_certificate = true;
    }

    /// The hybrid logical clock of the write that holds `key`'s `field`, if
    /// one does.
    pub fn clock(replica: *Replica, key: []const u8, field: []const u8) !?u64 {
        const s = try replica.winner(key, field) orelse return null;
        defer s.reset();
        return @bitCast(s.int(1));
    }

    /// The statement holding `key`'s `field`'s winner (`kind`, `hlc`,
    /// `device`, and `value`), to reset once read; null if there's none.
    pub fn winner(replica: *Replica, key: []const u8, field: []const u8) !?sqlite.Stmt {
        const s = replica.select_winner;
        errdefer s.reset();
        try s.bind(.{ key, field });
        if (try s.step()) return s;
        s.reset();
        return null;
    }

    /// Whether this device's own certificate, or its private stream's, as
    /// held, is valid for this library and names its person. Its own writes
    /// pass without one, so only others would notice one that isn't, by
    /// refusing every write on the stream (as an older build's may be).
    fn ownCertified(replica: *Replica, private: bool) !bool {
        const key = if (private) replica.private_pair.public_key.toBytes() else replica.device();
        const c = try replica.certified(key, &.{}) orelse return false;
        return c.private == private and std.mem.eql(u8, &c.person, &replica.personKey());
    }

    pub fn personKey(replica: *const Replica) Device {
        return replica.person.public_key.toBytes();
    }

    /// Writes `fields` of the private `key` (which must be this person's,
    /// `p/<person>/...`) as one batch of the device's private stream: one
    /// to 1,024 of them.
    pub fn writePrivate(replica: *Replica, wall_ms: u64, key: []const u8, fields: []const [2][]const u8) !void {
        const hex = std.fmt.bytesToHex(replica.personKey(), .lower);
        if (!std.mem.startsWith(u8, key, "p/") or !std.mem.startsWith(u8, key[2..], &hex) or key.len < 67 or key[66] != '/')
            return error.NotPrivate;
        // A batch holds 1 to `merkle.max_leaves` operations.
        if (fields.len == 0 or fields.len > merkle.max_leaves) return error.BadBatchSize;
        // As `writeOp`'s.
        if (key.len > std.math.maxInt(u16)) return error.TooLong;
        for (fields) |f| if (f[0].len > std.math.maxInt(u16) or f[1].len > max_value_len) return error.TooLong;
        try replica.flush();
        // The private stream's certificate travels on the device's own.
        try replica.checkCertificate(wall_ms);
        if (!replica.checked_private_certificate) {
            if (!try replica.ownCertified(true)) {
                var cert_key: [66]u8 = undefined;
                try replica.write(wall_ms, certKey(&cert_key, replica.private_pair.public_key.toBytes()), "private", &try replica.certificate(true));
            }
            replica.checked_private_certificate = true;
        }
        // Stored, numbered, and signed together or not at all, as `writeOp`.
        const alone = !replica.batching;
        if (alone) try replica.begin();
        errdefer if (alone) replica.rollback();
        var leaves: std.ArrayList(Hash) = .empty;
        defer leaves.deinit(replica.gpa);
        const first = replica.private_seq + 1;
        for (fields) |f| {
            replica.private_seq += 1;
            const op = try replica.encodeOwn(replica.private_pair.public_key.toBytes(), replica.private_seq, wall_ms, .lww, key, f[0], f[1]);
            try leaves.append(replica.gpa, merkle.leaf(replica.body.items));
            _ = try replica.merge(op, replica.private_own);
        }
        const root = merkle.root(leaves.items);
        try replica.storeBatch(replica.private_own, first, leaves.items, root, try signBatch(replica, replica.private_pair, first, leaves.items.len, root));
        try replica.advance(replica.private_own, replica.private_seq);
        if (alone) try replica.commit();
    }

    /// Adds `person` to the library's members.
    pub fn addMember(replica: *Replica, wall_ms: u64, person: Device) !void {
        try replica.setMember(wall_ms, "members", &std.fmt.bytesToHex(person, .lower), true);
    }

    pub fn isMemberPerson(replica: *Replica, person: Device) !bool {
        return try replica.isMember("members", &std.fmt.bytesToHex(person, .lower));
    }

    /// What a device's batches may hold: everything (its person is a
    /// member), nothing yet (no certificate naming a member), or, for a
    /// removed device (or a removed member's), writes through its cutoff.
    const Admission = union(enum) { all, none, through: u64 };

    pub fn admission(replica: *Replica, device_key: Device, ops: []const Op) !Admission {
        if (std.mem.eql(u8, &device_key, &replica.device())) return .all;
        if (std.mem.eql(u8, &device_key, &replica.private_pair.public_key.toBytes())) return .all;
        const c = try replica.certified(device_key, ops) orelse return .none;
        if (try replica.revoked(device_key)) |seq| return .{ .through = seq };
        if (try replica.isMemberPerson(c.person)) return .all;
        return .none;
    }

    pub const Certified = struct { person: Device, private: bool };

    /// The person whose valid certificate, from `ops` or already held, names
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
            if (cert == null) if (try replica.winner(key, field)) |s| {
                defer s.reset();
                if (s.blob(3).len == 96) cert = s.blob(3)[0..96].*;
            };
            const c = cert orelse continue;
            if (verifyCertificate(replica.library, device_key, private, c)) |person| return .{ .person = person, .private = private };
        }
        return null;
    }

    pub fn certifiedPerson(replica: *Replica, device_key: Device, ops: []const Op) !?Device {
        const c = try replica.certified(device_key, ops) orelse return null;
        return if (c.private) null else c.person;
    }

    /// Refuses private data written by anyone but its person's private stream,
    /// and anything else a private stream writes.
    fn checkPrivate(replica: *Replica, device_key: Device, ops: []const Op, refused: *std.StaticBitSet(merkle.max_leaves)) !void {
        // This device's own private stream is its person's, certificate or
        // not: a replica rebuilt from devices (e.g., after tvOS purged it) may
        // get the stream's batches before the public one carrying its
        // certificate.
        const own = std.mem.eql(u8, &device_key, &replica.private_pair.public_key.toBytes());
        const c: ?Certified = if (own) .{ .person = replica.personKey(), .private = true } else try replica.certified(device_key, ops);
        for (ops, 0..) |op, i| {
            const is_private = std.mem.startsWith(u8, op.key, "p/");
            if (c != null and c.?.private) {
                const hex = std.fmt.bytesToHex(c.?.person, .lower);
                if (!is_private or op.key.len < 67 or !std.mem.eql(u8, op.key[2..66], &hex) or op.key[66] != '/') refused.set(i);
            } else if (is_private) refused.set(i);
        }
    }

    /// Refuses what no device may write: an operation of the wrong kind
    /// for its key (`members` causal lengths, 1 or a removal's even one;
    /// everything else last-writer-wins), one dated more than a day past
    /// `now_ms`, and a certificate (`c/<key>`) but a device's own (`user`)
    /// or, for a private stream, one naming the writer's person when none
    /// held names another (`private`), so no one can claim another's
    /// stream and be sent its private data.
    fn checkOps(replica: *Replica, device_key: Device, ops: []const Op, refused: *std.StaticBitSet(merkle.max_leaves)) !void {
        const horizon: ?u64 = if (replica.now_ms) |now| (now +| std.time.ms_per_day) << 16 else null;
        for (ops, 0..) |op, i| {
            const counted = std.mem.eql(u8, op.key, "members");
            const ok = if (counted)
                op.kind == .causal_length and op.value.len == 4 and validLength(op_.causalLength(op.value))
            else
                op.kind == .lww;
            if (!ok or horizon != null and op.hlc > horizon.?) {
                refused.set(i);
            } else if (std.mem.startsWith(u8, op.key, "c/") and !try replica.certificateAllowed(device_key, op, ops)) {
                refused.set(i);
            } else if (std.mem.eql(u8, op.key, "revoked") and !removalAllowed(op)) {
                refused.set(i);
            } else if (op.key.len == 18 and std.mem.startsWith(u8, op.key, "r/") and !try replica.sourceFieldAllowed(device_key, op, ops)) {
                refused.set(i);
            } else if (std.mem.startsWith(u8, op.key, "l/") and !try replica.listFieldAllowed(device_key, op, ops)) {
                refused.set(i);
            }
        }
    }

    /// A cutoff (`revoked`) is 8 bytes, a sequence number a stream can
    /// reach (past it, no device could store it).
    fn removalAllowed(op: Op) bool {
        return op.value.len == 8 and std.mem.readInt(u64, op.value[0..8], .little) <= max_seq and parseHex(op.field) != null;
    }

    /// A source's address (`url`) is the one its ID hashes, or empty (as
    /// a removal leaves it), and stands from whichever device wrote it, so
    /// no one can take a source over; and only that device marks it as its
    /// downloads (`managed`), so no one can stop crawls of another's.
    fn sourceFieldAllowed(replica: *Replica, writer: Device, op: Op, ops: []const Op) !bool {
        const url = std.mem.eql(u8, op.field, "url");
        if (!url and !std.mem.eql(u8, op.field, "managed")) return true;
        if (url and op.value.len == 0) return true;
        if (url) {
            var hash: [8]u8 = undefined;
            Blake3.hash(op.value, &hash, .{});
            if (!std.mem.eql(u8, &std.fmt.bytesToHex(hash, .lower), op.key[2..])) return false;
        }
        // Whose the address is: a held one's writer, or this batch's.
        if (try replica.winner(op.key, "url")) |s| {
            defer s.reset();
            if (s.blob(3).len > 0) return std.mem.eql(u8, &try replica.keyOf(s.int(2)), &writer);
        }
        if (url) return true;
        for (ops) |o| if (std.mem.eql(u8, o.key, op.key) and std.mem.eql(u8, o.field, "url") and o.value.len > 0) return true;
        return false;
    }

    /// A shared list's field (`l/<owner>/<id>`) is one a list has, from
    /// one of its owner's devices: no one else changes it.
    fn listFieldAllowed(replica: *Replica, writer: Device, op: Op, ops: []const Op) !bool {
        const parsed = lists.parsePublic(op.key) orelse return false;
        if (!lists.validPublicField(op.field, op.value)) return false;
        const owner = parseHex(parsed.owner) orelse return false;
        const author = try replica.certifiedPerson(writer, ops) orelse return false;
        return std.mem.eql(u8, &author, &owner);
    }

    fn validLength(length: u32) bool {
        return length == 1 or length > 0 and length % 2 == 0;
    }

    fn certificateAllowed(replica: *Replica, writer: Device, op: Op, ops: []const Op) !bool {
        const subject = (if (op.key.len == 66) parseHex(op.key[2..]) else null) orelse return false;
        if (std.mem.eql(u8, op.field, "user")) return std.mem.eql(u8, &subject, &writer);
        if (!std.mem.eql(u8, op.field, "private") or op.value.len != 96) return false;
        const person = verifyCertificate(replica.library, subject, true, op.value[0..96].*) orelse return false;
        const author = try replica.certifiedPerson(writer, ops) orelse return false;
        if (!std.mem.eql(u8, &person, &author)) return false;
        const s = try replica.winner(op.key, "private") orelse return true;
        defer s.reset();
        if (s.blob(3).len == 96) if (verifyCertificate(replica.library, subject, true, s.blob(3)[0..96].*)) |held|
            return std.mem.eql(u8, &held, &person);
        return true;
    }

    /// Whether the stream `id` holds a batch over any of `first`'s `count`
    /// numbers but this one (the same range and root). As batches held
    /// don't overlap, only the nearest at or before `first` can reach it,
    /// so it's two lookups, not a scan of every batch before.
    fn overlaps(replica: *Replica, id: i64, first: u64, count: usize, root: Hash) !bool {
        const s = try replica.db.prepare(
            \\SELECT 1 FROM (SELECT first, count, root FROM batches WHERE device = ?1 AND first <= ?2 ORDER BY first DESC LIMIT 1)
            \\  WHERE first + count > ?2 AND NOT (first = ?2 AND count = ?3 AND root = ?4)
            \\UNION ALL
            \\SELECT 1 FROM (SELECT 1 FROM batches WHERE device = ?1 AND first > ?2 AND first < ?2 + ?3 LIMIT 1)
        );
        defer s.finalize();
        try s.bind(.{ id, first, count, sqlite.asBlob(&root) });
        return try s.step();
    }

    /// Devices certified for `person`, by the certificates held.
    pub fn devicesOf(replica: *Replica, arena: std.mem.Allocator, person: Device) ![]Device {
        var out: std.ArrayList(Device) = .empty;
        const s = try replica.db.prepare("SELECT key, value FROM winners WHERE key >= 'c/' AND key < 'c0' AND field = 'user'");
        defer s.finalize();
        while (try s.step()) {
            const value = s.blob(1);
            if (value.len != 96 or !std.mem.eql(u8, value[0..32], &person)) continue;
            try out.append(arena, parseHex(s.blob(0)[2..]) orelse continue);
        }
        return out.items;
    }

    /// Removes one device (of this person's, or any member's) without its
    /// person: its streams, its own and its private one, are cut off where
    /// this replica has seen them, so writes through there stand and later
    /// ones are refused, and it's served no more. It still holds its person's
    /// secret, so it isn't kept out of the person's other devices' data that
    /// it already has, and could pair afresh as another device.
    pub fn revokeDevice(replica: *Replica, wall_ms: u64, device_key: Device) !void {
        if (std.mem.eql(u8, &device_key, &replica.device())) return error.ThisDevice;
        try replica.revokeStreams(wall_ms, device_key);
    }

    /// Removes this device from the library, as it leaves: cutting off its
    /// own streams just past these writes, in one transaction, so other
    /// devices take the removal and refuse anything after. Once removed, it does
    /// nothing, so leaving can be tried again until a sync reaches another
    /// device. (`revokeDevice` refuses this device: cut off where it is, its
    /// own removal would be past the cut.)
    pub fn removeSelf(replica: *Replica, wall_ms: u64) !void {
        if (try replica.revoked(replica.device()) != null) return;
        try replica.begin();
        errdefer replica.rollback();
        // A certificate this writes first would be numbered before the cut.
        try replica.checkCertificate(wall_ms);
        var arena_state = std.heap.ArenaAllocator.init(replica.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        // Its private streams, where they are.
        const private = try replica.privateStreams(arena, replica.device());
        const cuts = try arena.alloc(u64, private.len);
        for (private, cuts) |p, *s| s.* = try replica.seen(try replica.deviceId(p));
        var seq: [8]u8 = undefined;
        for (private, cuts) |p, s| {
            std.mem.writeInt(u64, &seq, s, .little);
            try replica.write(wall_ms, "revoked", &std.fmt.bytesToHex(p, .lower), &seq);
        }
        // Its own stream's cut comes last, taking in this write itself.
        std.mem.writeInt(u64, &seq, replica.seq + 1, .little);
        try replica.write(wall_ms, "revoked", &std.fmt.bytesToHex(replica.device(), .lower), &seq);
        try replica.commit();
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
        try streams.appendSlice(arena, try replica.privateStreams(arena, device_key));
        for (streams.items) |stream| {
            var seq: [8]u8 = undefined;
            std.mem.writeInt(u64, &seq, try replica.seen(try replica.deviceId(stream)), .little);
            try replica.write(wall_ms, "revoked", &std.fmt.bytesToHex(stream, .lower), &seq);
        }
    }

    /// A device's private streams, whose certificates it wrote.
    fn privateStreams(replica: *Replica, arena: std.mem.Allocator, device_key: Device) ![]const Device {
        var out: std.ArrayList(Device) = .empty;
        // By the keys' range (`+device`), not the device index, which for a
        // device that crawled the library is nearly every row.
        const s = try replica.db.prepare("SELECT key FROM winners WHERE key >= 'c/' AND key < 'c0' AND field = 'private' AND +device = ?1");
        defer s.finalize();
        try s.bind(.{try replica.deviceId(device_key)});
        while (try s.step()) try out.append(arena, parseHex(s.blob(0)[2..]) orelse continue);
        return out.items;
    }

    /// Every stream cut off (removed devices', and their private streams'),
    /// by its key in hex.
    pub fn revokedStreams(replica: *Replica, arena: std.mem.Allocator) ![]const []const u8 {
        const s = try replica.db.prepare("SELECT field FROM winners WHERE key = 'revoked' AND length(value) = 8");
        defer s.finalize();
        var out: std.ArrayList([]const u8) = .empty;
        while (try s.step()) try out.append(arena, try arena.dupe(u8, s.blob(0)));
        return out.items;
    }

    /// Where a stream of a removed device was cut off, if it was.
    pub fn revoked(replica: *Replica, stream: Device) !?u64 {
        const s = try replica.winner("revoked", &std.fmt.bytesToHex(stream, .lower)) orelse return null;
        defer s.reset();
        const value = s.blob(3);
        if (value.len != 8) return null;
        return std.mem.readInt(u64, value[0..8], .little);
    }

    /// Removes `person` from the library, and cuts off each of their devices
    /// as `revokeDevice` does: their writes up to what this replica has
    /// seen stand; later ones are refused. A device the remover didn't
    /// know isn't admitted, its person no longer a member.
    pub fn removeMember(replica: *Replica, wall_ms: u64, person: Device) !void {
        var arena_state = std.heap.ArenaAllocator.init(replica.gpa);
        defer arena_state.deinit();
        try replica.setMember(wall_ms, "members", &std.fmt.bytesToHex(person, .lower), false);
        for (try replica.devicesOf(arena_state.allocator(), person)) |dev| {
            if (!std.mem.eql(u8, &dev, &replica.device())) try replica.revokeStreams(wall_ms, dev);
        }
    }

    /// Applies a stream's cutoff (a `revoked` field, `stream_hex`, and its
    /// last sequence number that stands): drops the winners the stream
    /// wrote past it; if any, the next pull refills (see `refilling`).
    fn cut(replica: *Replica, stream_hex: []const u8, value: []const u8) !void {
        if (value.len != 8) return;
        const stream = parseHex(stream_hex) orelse return;
        // As another connection may have learned of it.
        const id = try replica.deviceId(stream);
        // A cutoff past any sequence number (which only its own writer
        // holds, as others refuse it) cuts nothing off.
        const through = std.math.cast(i64, std.mem.readInt(u64, value[0..8], .little)) orelse return;
        const s = try replica.db.prepare("DELETE FROM winners WHERE device = ?1 AND seq > ?2 AND key NOT LIKE 'c/%'");
        defer s.finalize();
        try s.bind(.{ id, through });
        _ = try s.step();
        if (replica.db.changes() == 0) return;
        try replica.setLocal("refill", "1");
        replica.refilling = true;
    }

    /// The vector a pull sends: this replica's, or none while refilling,
    /// so the other device sends every winner it holds.
    pub fn requestVector(replica: *Replica, arena: std.mem.Allocator) !VersionVector {
        return if (replica.refilling) &.{} else replica.versionVector(arena);
    }

    /// Ends refilling, once a pull that asked for everything has taken it.
    pub fn refilled(replica: *Replica) !void {
        if (!replica.refilling) return;
        try replica.removeLocal("refill");
        replica.refilling = false;
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

    pub fn deviceId(replica: *Replica, key: Device) !i64 {
        if (replica.ids.get(key)) |id| return id;
        // Another connection (a server's, taking a push) may have added it.
        try replica.internAdded();
        if (replica.ids.get(key)) |id| return id;
        const id = blk: {
            const s = replica.insert_device;
            defer s.reset();
            try s.bind(.{sqlite.asBlob(&key)});
            if (!try s.step()) return error.Sqlite;
            break :blk s.int(0);
        };
        // Devices another connection added meanwhile come first.
        if (id != replica.keys.items.len + 1) try replica.internAdded();
        if (replica.ids.get(key) == null) try replica.intern(id, key);
        return id;
    }

    /// The key of device `id`, learning of devices other connections added
    /// if it's one this connection hasn't seen.
    pub fn keyOf(replica: *Replica, id: i64) !Device {
        if (id < 1) return error.Sqlite;
        if (id > replica.keys.items.len) try replica.internAdded();
        if (id > replica.keys.items.len) return error.Sqlite;
        return replica.keys.items[@intCast(id - 1)];
    }

    /// Learns the devices other connections added since this one last did.
    fn internAdded(replica: *Replica) !void {
        const s = try replica.db.prepare("SELECT id, key FROM devices WHERE id > ?1 ORDER BY id");
        defer s.finalize();
        try s.bind(.{replica.keys.items.len});
        while (try s.step()) try replica.intern(s.int(0), s.blob(1)[0..32].*);
    }

    /// Catches up with what another connection to the same database wrote:
    /// devices it learned of, and this device's sequence numbers. Only one
    /// connection may write as this device at a time.
    pub fn refresh(replica: *Replica) !void {
        try replica.internAdded();
        replica.seq = try replica.seen(replica.own);
        replica.private_seq = try replica.seen(replica.private_own);
        try replica.observeOwn();
    }

    /// Folds in the clocks of this device's latest writes (another
    /// connection's, or before a restart), so a write now orders after them
    /// even in the same millisecond, or after the wall clock stepped back,
    /// and never loses to one of its own.
    fn observeOwn(replica: *Replica) !void {
        const s = try replica.db.prepare("SELECT hlc FROM winners WHERE device = ?1 ORDER BY seq DESC LIMIT 1");
        defer s.finalize();
        for ([_]i64{ replica.own, replica.private_own }) |id| {
            defer s.reset();
            try s.bind(.{id});
            if (try s.step()) replica.hlc.observe(@bitCast(s.int(0)));
        }
    }

    /// This device's own `key`, which doesn't replicate, if set.
    pub fn local(replica: *Replica, arena: std.mem.Allocator, key: []const u8) !?[]u8 {
        const s = try replica.db.prepare("SELECT value FROM local WHERE key = ?1");
        defer s.finalize();
        try s.bind(.{key});
        return if (try s.step()) try arena.dupe(u8, s.blob(0)) else null;
    }

    pub fn setLocal(replica: *Replica, key: []const u8, value: []const u8) !void {
        const s = try replica.db.prepare("INSERT OR REPLACE INTO local VALUES (?1, ?2)");
        defer s.finalize();
        try s.bind(.{ key, sqlite.asBlob(value) });
        _ = try s.step();
    }

    pub fn removeLocal(replica: *Replica, key: []const u8) !void {
        const s = try replica.db.prepare("DELETE FROM local WHERE key = ?1");
        defer s.finalize();
        try s.bind(.{key});
        _ = try s.step();
    }

    /// This device's own keys starting with `prefix`, in order.
    pub fn localKeys(replica: *Replica, arena: std.mem.Allocator, prefix: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        const s = try replica.db.prepare("SELECT key FROM local WHERE substr(key, 1, length(?1)) = ?1 ORDER BY key");
        defer s.finalize();
        try s.bind(.{prefix});
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
        replica.begun_seq = replica.seq;
        replica.begun_private_seq = replica.private_seq;
    }

    /// Abandons the transaction `begin` started, and with it the writes it
    /// numbered, so the streams' numbering matches what's stored.
    pub fn rollback(replica: *Replica) void {
        replica.db.exec("ROLLBACK") catch {};
        replica.batching = false;
        replica.pending.clearRetainingCapacity();
        replica.seq = replica.begun_seq;
        replica.private_seq = replica.begun_private_seq;
        // What the transaction learned that went with it: devices it
        // interned (whose ids the table will hand out again), and whether
        // the certificates were checked (their writes may have been undone).
        const known = replica.db.scalar("SELECT coalesce(max(id), 0) FROM devices") catch 0;
        while (replica.keys.items.len > known) _ = replica.ids.remove(replica.keys.pop().?);
        replica.checked_certificate = false;
        replica.checked_private_certificate = false;
    }

    pub fn commit(replica: *Replica) !void {
        try replica.flush();
        replica.batching = false;
        try replica.db.exec("COMMIT");
    }

    pub fn write(replica: *Replica, wall_ms: u64, key: []const u8, field: []const u8, value: []const u8) !void {
        try replica.writeOp(.lww, wall_ms, key, field, value);
    }

    /// Adds or removes `element` of the set at `key` (`members`, the only
    /// set). Removal is for good: an element removed can't be added again
    /// (a person removed comes back as someone new).
    pub fn setMember(replica: *Replica, wall_ms: u64, key: []const u8, element: []const u8, present: bool) !void {
        const length = try replica.causalLength(key, element);
        if ((length % 2 == 1) == present) return;
        if (present and length > 0) return error.RemovedForGood;
        var value: [4]u8 = undefined;
        std.mem.writeInt(u32, &value, length + 1, .little);
        try replica.writeOp(.causal_length, wall_ms, key, element, &value);
    }

    /// The library's members: its creator, unless removed, then the people
    /// added and not removed.
    pub fn members(replica: *Replica, arena: std.mem.Allocator) ![]Device {
        var out: std.ArrayList(Device) = .empty;
        if (try replica.isMemberPerson(replica.genesis)) try out.append(arena, replica.genesis);
        const s = try replica.db.prepare("SELECT field, value FROM winners WHERE key = 'members' ORDER BY field");
        defer s.finalize();
        while (try s.step()) {
            if (op_.causalLength(s.blob(1)) % 2 == 0) continue;
            const person = parseHex(s.blob(0)) orelse continue;
            if (!std.mem.eql(u8, &person, &replica.genesis)) try out.append(arena, person);
        }
        return out.items;
    }

    pub fn isMember(replica: *Replica, key: []const u8, element: []const u8) !bool {
        return try replica.causalLength(key, element) % 2 == 1;
    }

    fn causalLength(replica: *Replica, key: []const u8, element: []const u8) !u32 {
        if (try replica.winner(key, element)) |s| {
            defer s.reset();
            return op_.causalLength(s.blob(3));
        }
        // The creator was a member from the start.
        return if (std.mem.eql(u8, key, "members") and std.mem.eql(u8, element, &std.fmt.bytesToHex(replica.genesis, .lower))) 1 else 0;
    }

    pub fn writeOp(replica: *Replica, kind: op_.Kind, wall_ms: u64, key: []const u8, field: []const u8, value: []const u8) !void {
        // What its encoding can carry, and other devices take: else the
        // write, signed into the stream, would stop them taking any more.
        if (key.len > std.math.maxInt(u16) or field.len > std.math.maxInt(u16) or value.len > max_value_len) return error.TooLong;
        var own_key: [66]u8 = undefined;
        if (!std.mem.eql(u8, key, certKey(&own_key, replica.device()))) try replica.checkCertificate(wall_ms);
        if (!replica.batching) {
            // A write of its own is stored, numbered, and signed together
            // or not at all, so a failure between can't leave a number
            // with no batch to prove it.
            try replica.begin();
            errdefer replica.rollback();
            try replica.writeOp(kind, wall_ms, key, field, value);
            return replica.commit();
        }
        replica.seq += 1;
        const op = try replica.encodeOwn(replica.device(), replica.seq, wall_ms, kind, key, field, value);
        if (replica.pending.items.len == 0) replica.pending_first = op.seq;
        try replica.pending.append(replica.gpa, merkle.leaf(replica.body.items));
        _ = try replica.merge(op, replica.own);
        try replica.advance(replica.own, op.seq);
        if (!replica.batching or replica.pending.items.len == merkle.max_leaves) try replica.flush();
    }

    /// An operation of this device's on `stream` (its own, or its private
    /// one), numbered `seq` and clocked now, its encoding in `body`.
    fn encodeOwn(replica: *Replica, stream: Device, seq: u64, wall_ms: u64, kind: op_.Kind, key: []const u8, field: []const u8, value: []const u8) !Op {
        const op: Op = .{ .library = replica.library, .device = stream, .seq = seq, .hlc = replica.hlc.tick(wall_ms), .kind = kind, .key = key, .field = field, .value = value };
        try op.encode(replica.gpa, &replica.body);
        return op;
    }

    /// Signs pending local writes as one batch.
    fn flush(replica: *Replica) !void {
        const leaves = replica.pending.items;
        if (leaves.len == 0) return;
        const root = merkle.root(leaves);
        const sig = try signBatch(replica, replica.key_pair, replica.pending_first, leaves.len, root);
        try replica.storeBatch(replica.own, replica.pending_first, leaves, root, sig);
        replica.pending.clearRetainingCapacity();
    }

    fn storeBatch(replica: *Replica, id: i64, first: u64, leaves: []const Hash, root: Hash, sig: op_.Signature) !void {
        const s = replica.insert_batch;
        defer s.reset();
        try s.bind(.{ id, first, leaves.len, sqlite.asBlob(&root), sqlite.asBlob(&sig), sqlite.asBlob(std.mem.sliceAsBytes(leaves)) });
        _ = try s.step();
    }

    /// A batch's root, once it matches its device's signature. `leaves`
    /// holds the batch's leaves, except where `ops` fall, which are rebuilt
    /// from the operations themselves.
    pub fn checkBatch(replica: *Replica, batch: Batch, leaves: []Hash, ops: []const Op) !Hash {
        for (ops) |op| {
            if (!std.mem.eql(u8, &op.library, &replica.library)) return error.WrongLibrary;
            if (!std.mem.eql(u8, &op.device, &batch.device) or op.seq < batch.first or op.seq >= batch.first + leaves.len) return error.NoBatch;
            try op.encode(replica.gpa, &replica.body);
            leaves[op.seq - batch.first] = merkle.leaf(replica.body.items);
        }
        const root = merkle.root(leaves);
        if (replica.verify) try verifyBatch(replica.library, batch.device, batch.first, leaves.len, root, batch.sig);
        return root;
    }

    /// Applies a checked batch (its `root`, as `checkBatch` gave it), or
    /// `error.Unauthorized` if its device isn't admitted (yet).
    pub fn admitBatch(replica: *Replica, batch: Batch, leaves: []const Hash, ops: []const Op, root: Hash, stats: *Stats) !void {
        const admitted = try replica.admission(batch.device, ops);
        if (admitted == .none) return error.Unauthorized;
        var bad: std.StaticBitSet(merkle.max_leaves) = .empty;
        try replica.checkPrivate(batch.device, ops, &bad);
        try replica.checkOps(batch.device, ops, &bad);
        const id = try replica.deviceId(batch.device);
        // A stream numbers each write once: a batch over a range another
        // already holds, but for that one itself, is refused, else a device
        // could be left holding numbers whose batch doesn't hold them.
        if (try replica.overlaps(id, batch.first, leaves.len, root)) {
            stats.refused += ops.len;
            return;
        }
        try replica.storeBatch(id, batch.first, leaves, root, batch.sig);
        const seen_seq = try replica.seen(id);
        for (ops, 0..) |op, i| {
            // Known, unless refilling, when what it held is taken again.
            if (op.seq <= seen_seq and !replica.refilling) {
                stats.count(.known);
                continue;
            }
            if (bad.isSet(i) or admitted == .through and op.seq > admitted.through) {
                stats.refused += 1;
                continue;
            }
            replica.hlc.observe(op.hlc);
            stats.count(try replica.merge(op, id));
        }
    }

    fn merge(replica: *Replica, op: Op, id: i64) !Outcome {
        if (try replica.winner(op.key, op.field)) |s| {
            // Freed at once, for the checks the hooks below make.
            defer s.reset();
            const newer = switch (op.kind) {
                // Last writer wins, by hybrid logical clock, then device key.
                .lww => blk: {
                    const hlc: u64 = @bitCast(s.int(1));
                    const order = std.mem.order(u8, &op.device, &try replica.keyOf(s.int(2)));
                    // But a removal only stands or tightens: the lower
                    // cutoff wins, so no one can undo another's.
                    if (std.mem.eql(u8, op.key, "revoked")) {
                        const held = s.blob(3);
                        if (held.len != 8) break :blk true;
                        break :blk std.mem.readInt(u64, op.value[0..8], .little) < std.mem.readInt(u64, held[0..8], .little);
                    }
                    break :blk op.hlc > hlc or (op.hlc == hlc and order == .gt);
                },
                // A removal (an even causal length) wins over any addition,
                // so it's for good; else the longer wins.
                .causal_length => outranks(op_.causalLength(op.value), op_.causalLength(s.blob(3))),
            };
            if (!newer) return .lost;
        }
        const u = replica.upsert_winner;
        defer u.reset();
        try u.bind(.{ op.key, op.field, @intFromEnum(op.kind), @as(i64, @bitCast(op.hlc)), id, op.seq, sqlite.asBlob(op.value) });
        _ = try u.step();
        if (std.mem.eql(u8, op.key, "revoked")) try replica.cut(op.field, op.value);
        return .won;
    }

    fn outranks(length: u32, held: u32) bool {
        const removed = length > 0 and length % 2 == 0;
        const held_removed = held > 0 and held % 2 == 0;
        return if (removed != held_removed) removed else length > held;
    }

    /// The highest sequence number of device `id` that this replica covers.
    fn seen(replica: *Replica, id: i64) !u64 {
        const s = replica.select_version;
        defer s.reset();
        try s.bind(.{id});
        return if (try s.step()) @intCast(s.int(0)) else 0;
    }

    pub fn advance(replica: *Replica, id: i64, seq: u64) !void {
        const u = replica.upsert_version;
        defer u.reset();
        try u.bind(.{ id, seq });
        _ = try u.step();
    }

    /// The version vector without other people's private streams than `reader`'s.
    /// A stream without a certificate held might be private, so it's left
    /// out, but for this device's own streams: its public one, and its
    /// private one (taken before its certificate, as a lost replica does),
    /// which is this person's.
    pub fn readableVector(replica: *Replica, arena: std.mem.Allocator, reader: Device) !VersionVector {
        var out: std.ArrayList(Entry) = .empty;
        const own_private = replica.private_pair.public_key.toBytes();
        for (try replica.versionVector(arena)) |entry| {
            const person = if (std.mem.eql(u8, &entry.device, &own_private))
                replica.personKey()
            else if (std.mem.eql(u8, &entry.device, &replica.device()))
                reader // this device's own public stream, whatever its certificate
            else if (try replica.certified(entry.device, &.{})) |c| (if (c.private) c.person else reader) else continue;
            if (!std.mem.eql(u8, &person, &reader)) continue;
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
            try entries.append(arena, .{ .device = try replica.keyOf(s.int(0)), .seq = @intCast(s.int(1)) });
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
    pub fn loadBatch(replica: *Replica, id: i64, seq: u64, leaves: *std.ArrayList(Hash)) !Batch {
        const s = try replica.db.prepare(
            \\SELECT first, root, sig, leaves FROM batches
            \\WHERE device = ?1 AND first <= ?2 ORDER BY first DESC LIMIT 1
        );
        defer s.finalize();
        try s.bind(.{ id, seq });
        if (!try s.step()) return error.NoBatch;
        leaves.clearRetainingCapacity();
        try leaves.appendSlice(replica.gpa, std.mem.bytesAsSlice(Hash, s.blob(3)));
        const batch: Batch = .{
            .device = try replica.keyOf(id),
            .first = @intCast(s.int(0)),
            .leaves = leaves.items,
            .root = s.blob(1)[0..32].*,
            .sig = s.blob(2)[0..64].*,
        };
        if (!batch.contains(seq)) return error.NoBatch;
        return batch;
    }
};

/// The person keys of a device's identity when the person's seed derives from the
/// device's (see `Identity.from`).
pub fn personKeyPair(seed: [32]u8) !Ed25519.KeyPair {
    return Ed25519.KeyPair.generateDeterministic(Identity.from(seed).person);
}

/// A library's ID derives from its creator's person key.
pub fn libraryId(creator: Device) op_.Library {
    var out: [32]u8 = undefined;
    Blake3.hash(&creator, &out, .{});
    return out[0..16].*;
}

pub fn certKey(buf: *[66]u8, device_key: Device) []const u8 {
    buf[0..2].* = "c/".*;
    buf[2..].* = std.fmt.bytesToHex(device_key, .lower);
    return buf;
}

pub fn certMessage(library: op_.Library, device_key: Device, private: bool) [20 + 16 + 32]u8 {
    var out: [20 + 16 + 32]u8 = undefined;
    out[0..20].* = if (private) "cinematheque private".* else "cinematheque device ".*;
    out[20..36].* = library;
    out[36..].* = device_key;
    return out;
}

pub fn parseHex(hex: []const u8) ?Device {
    var out: Device = undefined;
    if (hex.len != 64) return null;
    _ = std.fmt.hexToBytes(&out, hex) catch return null;
    return out;
}

/// The person a certificate names, if its signature holds.
pub fn verifyCertificate(library: op_.Library, device_key: Device, private: bool, cert: [96]u8) ?Device {
    const person = Ed25519.PublicKey.fromBytes(cert[0..32].*) catch return null;
    Ed25519.Signature.fromBytes(cert[32..96].*).verify(&certMessage(library, device_key, private), person) catch return null;
    return cert[0..32].*;
}

/// What a stream's key signs for a batch: its library, the stream, where the
/// batch starts and how many operations it holds, and their root, so a batch
/// can't be presented with another range than it was signed for.
fn batchMessage(library: op_.Library, device: Device, first: u64, count: usize, root: Hash) [18 + 16 + 32 + 8 + 4 + 32]u8 {
    var out: [18 + 16 + 32 + 8 + 4 + 32]u8 = undefined;
    out[0..18].* = "cinematheque batch".*;
    out[18..34].* = library;
    out[34..66].* = device;
    std.mem.writeInt(u64, out[66..74], first, .little);
    std.mem.writeInt(u32, out[74..78], @intCast(count), .little);
    out[78..110].* = root;
    return out;
}

fn signBatch(replica: *const Replica, pair: Ed25519.KeyPair, first: u64, count: usize, root: Hash) !op_.Signature {
    return (try pair.sign(&batchMessage(replica.library, pair.public_key.toBytes(), first, count, root), null)).toBytes();
}

pub fn verifyBatch(library: op_.Library, device: Device, first: u64, count: usize, root: Hash, sig: op_.Signature) !void {
    try Ed25519.Signature.fromBytes(sig).verify(&batchMessage(library, device, first, count, root), try Ed25519.PublicKey.fromBytes(device));
}

// The sync frames' parts, re-exported for their callers.
const frames = @import("frames.zig");
pub const writeVector = frames.writeVector;
pub const readVector = frames.readVector;
pub const Binding = frames.Binding;
pub const writeSync = frames.writeSync;
pub const Theirs = frames.Theirs;
pub const readSync = frames.readSync;
pub const sync = frames.sync;
