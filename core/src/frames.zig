//! Sync frames on the wire: version vectors, and a sync's operations
//! grouped by batch, written by a sender and read and checked by a
//! receiver (see replica.zig, and ARCHITECTURE.md's Sync).

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
const replica = @import("replica.zig");
const Batch = replica.Batch;
const Entry = replica.Entry;
const Replica = replica.Replica;
const Stats = replica.Stats;
const VersionVector = replica.VersionVector;
const max_batch_bytes = replica.max_batch_bytes;
const max_pending_bytes = replica.max_pending_bytes;
/// The least a batch held back costs of `max_pending_bytes`, so a response
/// of strangers' one-write batches can't hold millions (each checked).
const min_pending_bytes = 4096;
const max_seq = replica.max_seq;
const max_value_len = replica.max_value_len;
const max_vector_entries = replica.max_vector_entries;

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
    if (n > max_vector_entries) return error.Malformed;
    // Grown as entries arrive, not up front, so a count the bytes don't
    // back costs nothing.
    var entries: std.ArrayList(Entry) = .empty;
    for (0..n) |_| {
        var entry: Entry = undefined;
        try r.readSliceAll(&entry.device);
        entry.seq = try r.takeInt(u64, .little);
        try entries.append(arena, entry);
    }
    return entries.items;
}

const Row = struct { seq: u64, hlc: u64, kind: op_.Kind, key: []const u8, field: []const u8, value: []const u8 };

/// What a sync's frames answer: the signature of the request they follow (a
/// pull's, or a push's own), and the device sending them.
pub const Binding = struct { request: [64]u8, sender: Device };

/// A hash of a sync's frames' headers (each batch's range, signature, and
/// which operations it sends, and each version vector entry), which the
/// sender signs, bound to its request, so the receiver adopts its vector only
/// if it comes from that device, in answer to that request, with no batch
/// left out.
const Transcript = struct {
    hasher: Blake3,

    fn init(library: op_.Library, binding: Binding) Transcript {
        var t: Transcript = .{ .hasher = Blake3.init(.{}) };
        t.add(&library);
        t.add(&binding.request);
        t.add(&binding.sender);
        return t;
    }

    fn add(t: *Transcript, bytes: []const u8) void {
        t.hasher.update(bytes);
    }

    fn addInt(t: *Transcript, comptime T: type, value: T) void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .little);
        t.add(&bytes);
    }

    fn message(t: *Transcript) [19 + 32]u8 {
        var digest: [32]u8 = undefined;
        t.hasher.final(&digest);
        var out: [19 + 32]u8 = undefined;
        out[0..19].* = "cinematheque frames".*;
        out[19..].* = digest;
        return out;
    }
};

/// `reader` is the person the response is for: other people's private streams
/// (and their places in the version vector) are left out. The frames end
/// with the sender's signature over their headers, bound to `request`.
pub fn writeSync(src: *Replica, arena: std.mem.Allocator, wanted: VersionVector, reader: Device, request: [64]u8, w: *std.Io.Writer) !usize {
    var transcript: Transcript = .init(src.library, .{ .request = request, .sender = src.device() });
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
                try writeBatch(w, &transcript, b, rows.items);
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
        transcript.add(&entry.device);
        transcript.addInt(u64, entry.seq);
    }
    try w.writeByte('S');
    try w.writeAll(&(try src.key_pair.sign(&transcript.message(), null)).toBytes());
    try w.writeByte('E');
    return sent;
}

fn writeBatch(w: *std.Io.Writer, transcript: *Transcript, batch: *const Batch, rows: []const Row) !void {
    const count = batch.leaves.len;
    var sent: std.StaticBitSet(merkle.max_leaves) = .empty;
    for (rows) |row| sent.set(row.seq - batch.first);
    try w.writeByte('B');
    try w.writeAll(&batch.device);
    try w.writeInt(u64, batch.first, .little);
    try w.writeInt(u32, @intCast(count), .little);
    try w.writeAll(&batch.sig);
    try w.writeAll(std.mem.sliceAsBytes(&sent.masks)[0 .. (count + 7) / 8]);
    transcript.add(&batch.device);
    transcript.addInt(u64, batch.first);
    transcript.addInt(u32, @intCast(count));
    transcript.add(&batch.sig);
    transcript.add(std.mem.sliceAsBytes(&sent.masks)[0 .. (count + 7) / 8]);
    for (batch.leaves, 0..) |leaf, i| if (!sent.isSet(i)) try w.writeAll(&leaf);
    for (rows) |row| try writeOpFrame(w, row);
}

/// An `O` frame: the operation's sequence number, clock, kind, key, field,
/// and value (`op` has those fields; the library and device are its batch's).
pub fn writeOpFrame(w: *std.Io.Writer, op: anytype) !void {
    try w.writeByte('O');
    try w.writeInt(u64, op.seq, .little);
    try w.writeInt(u64, op.hlc, .little);
    try w.writeByte(@intFromEnum(op.kind));
    try w.writeInt(u16, @intCast(op.key.len), .little);
    try w.writeAll(op.key);
    try w.writeInt(u16, @intCast(op.field.len), .little);
    try w.writeAll(op.field);
    try w.writeInt(u32, @intCast(op.value.len), .little);
    try w.writeAll(op.value);
}

/// Allocates `len` bytes of text from `budget` (what a batch may still take),
/// refusing more.
pub fn takeText(r: *std.Io.Reader, ta: std.mem.Allocator, len: usize, budget: *usize) ![]u8 {
    if (len > budget.*) return error.Malformed;
    budget.* -= len;
    const text = try ta.alloc(u8, len);
    try r.readSliceAll(text);
    return text;
}

/// Reads an `O` frame of `device`'s operation `seq`, its text in `ta`, taken
/// from `budget`.
pub fn readOpFrame(r: *std.Io.Reader, ta: std.mem.Allocator, library: op_.Library, device: Device, seq: u64, budget: *usize) !Op {
    if (try r.takeByte() != 'O') return error.Malformed;
    if (try r.takeInt(u64, .little) != seq) return error.Malformed;
    const hlc = try r.takeInt(u64, .little);
    const kind = std.enums.fromInt(op_.Kind, try r.takeByte()) orelse return error.Malformed;
    const key = try takeText(r, ta, try r.takeInt(u16, .little), budget);
    const field = try takeText(r, ta, try r.takeInt(u16, .little), budget);
    const value_len = try r.takeInt(u32, .little);
    if (value_len > max_value_len) return error.Malformed;
    const value = try takeText(r, ta, value_len, budget);
    return .{ .library = library, .device = device, .seq = seq, .hlc = hlc, .kind = kind, .key = key, .field = field, .value = value };
}

/// The sender's version vector, as a sync's frames end with it, for the
/// receiver to answer with what the sender lacks (a push).
pub const Theirs = struct { arena: std.mem.Allocator, vector: *std.ArrayList(Entry) };

/// Applies a sync's frames (a pulled response's, or a pushed request's) in
/// one transaction; nothing is kept unless they all check out.
pub fn readSync(dst: *Replica, r: *std.Io.Reader, theirs: ?Theirs, binding: Binding) !Stats {
    var transcript: Transcript = .init(dst.library, binding);
    var signed = false;
    var leaves: std.ArrayList(Hash) = .empty;
    defer leaves.deinit(dst.gpa);
    var ops: std.ArrayList(Op) = .empty;
    defer ops.deinit(dst.gpa);
    var text_state = std.heap.ArenaAllocator.init(dst.gpa);
    defer text_state.deinit();

    // Batches whose devices aren't yet known to act for members wait for
    // the rest of the response, which may hold their invitations.
    const Pending = struct { batch: Batch, leaves: []Hash, ops: []Op, root: Hash };
    var pending_state = std.heap.ArenaAllocator.init(dst.gpa);
    defer pending_state.deinit();
    const pa = pending_state.allocator();
    var pending: std.ArrayList(Pending) = .empty;
    var pending_bytes: usize = 0;
    var vector: std.ArrayList(Entry) = .empty;

    var stats: Stats = .{};
    try dst.begin();
    errdefer dst.rollback();
    const sender_was_member = try dst.admission(binding.sender, &.{}) == .all;
    while (true) {
        const tag = try r.takeByte();
        stats.wire_bytes += 1;
        if (signed and tag != 'E') return error.Malformed;
        switch (tag) {
            'B' => {
                var batch: Batch = undefined;
                try r.readSliceAll(&batch.device);
                batch.first = try r.takeInt(u64, .little);
                const count = try r.takeInt(u32, .little);
                // Sequence numbers start at 1 and stay within i63, so the
                // arithmetic on them below can't overflow.
                if (batch.first == 0 or batch.first > max_seq) return error.Malformed;
                if (count == 0 or count > merkle.max_leaves) return error.Malformed;
                try r.readSliceAll(&batch.sig);
                var sent: std.StaticBitSet(merkle.max_leaves) = .empty;
                try r.readSliceAll(std.mem.sliceAsBytes(&sent.masks)[0 .. (count + 7) / 8]);
                transcript.add(&batch.device);
                transcript.addInt(u64, batch.first);
                transcript.addInt(u32, count);
                transcript.add(&batch.sig);
                transcript.add(std.mem.sliceAsBytes(&sent.masks)[0 .. (count + 7) / 8]);
                try leaves.resize(dst.gpa, count);
                for (leaves.items, 0..) |*leaf, i| if (!sent.isSet(i)) try r.readSliceAll(leaf);
                // The operations sent follow, one per set bit.
                ops.clearRetainingCapacity();
                _ = text_state.reset(.retain_capacity);
                const ta = text_state.allocator();
                var it = sent.iterator(.{});
                var budget: usize = max_batch_bytes;
                while (it.next()) |i| {
                    if (i >= count) return error.Malformed;
                    const op = try readOpFrame(r, ta, dst.library, batch.device, batch.first + i, &budget);
                    try ops.append(dst.gpa, op);
                    stats.wire_bytes += 1 + op.wireLen();
                }
                const root = try dst.checkBatch(batch, leaves.items, ops.items);
                dst.admitBatch(batch, leaves.items, ops.items, root, &stats) catch |err| switch (err) {
                    error.Unauthorized => {
                        // Its text, leaves, and operations, all held to the
                        // end, already checked.
                        pending_bytes += @max(min_pending_bytes, max_batch_bytes - budget + 32 * count + @sizeOf(Op) * ops.items.len);
                        if (pending_bytes > max_pending_bytes) return error.Malformed;
                        const copied = try pa.dupe(Op, ops.items);
                        for (copied) |*op| {
                            op.key = try pa.dupe(u8, op.key);
                            op.field = try pa.dupe(u8, op.field);
                            op.value = try pa.dupe(u8, op.value);
                        }
                        try pending.append(pa, .{ .batch = batch, .leaves = try pa.dupe(Hash, leaves.items), .ops = copied, .root = root });
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
                if (entry.seq > max_seq or vector.items.len >= max_vector_entries) return error.Malformed;
                transcript.add(&entry.device);
                transcript.addInt(u64, entry.seq);
                try vector.append(pa, entry);
                if (theirs) |t| try t.vector.append(t.arena, entry);
                stats.wire_bytes += 40;
            },
            // The sender's signature over every header before it, which
            // makes what it claims to hold believable.
            'S' => {
                var sig: op_.Signature = undefined;
                try r.readSliceAll(&sig);
                if (dst.verify) {
                    const key = Ed25519.PublicKey.fromBytes(binding.sender) catch return error.BadSignature;
                    Ed25519.Signature.fromBytes(sig).verify(&transcript.message(), key) catch return error.BadSignature;
                }
                signed = true;
                stats.wire_bytes += 64;
            },
            'E' => {
                if (!signed) return error.BadSignature;
                break;
            },
            else => return error.Malformed,
        }
    }
    var progress = true;
    while (progress) {
        progress = false;
        var i: usize = 0;
        while (i < pending.items.len) {
            const p = pending.items[i];
            if (dst.admitBatch(p.batch, p.leaves, p.ops, p.root, &stats)) {
                _ = pending.swapRemove(i);
                stats.deferred += 1;
                progress = true;
            } else |err| switch (err) {
                error.Unauthorized => i += 1,
                else => |e| return e,
            }
        }
    }
    // What the sender holds is believed only from a member's device: a
    // stranger's word could have this device skip any stream's writes.
    // Nor for this device's own streams, which only it numbers.
    // (A member then: a founder handing over and leaving is one no more.)
    const believed = sender_was_member or try dst.admission(binding.sender, &.{}) == .all;
    const own_private = dst.private_pair.public_key.toBytes();
    // Don't claim what was rejected, so it can be accepted once its
    // device's invitation arrives.
    for (vector.items) |entry| {
        if (!believed or std.mem.eql(u8, &entry.device, &dst.device()) or std.mem.eql(u8, &entry.device, &own_private)) continue;
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
    // No signed request here, so the frames answer a blank one.
    const unsigned: [64]u8 = @splat(0);
    _ = try writeSync(src, arena, wanted, dst.personKey(), unsigned, &response.writer);
    var response_reader: std.Io.Reader = .fixed(response.written());
    var stats = try readSync(dst, &response_reader, null, .{ .request = unsigned, .sender = src.device() });
    stats.wire_bytes = request.written().len + response.written().len;
    return stats;
}
