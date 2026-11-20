//! Repair: refetching, from a device that refused them, the fields a
//! removal dropped (see `Replica.cut`), with one shared proof per batch.

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
const writeOpFrame = @import("frames.zig").writeOpFrame;
const takeText = @import("frames.zig").takeText;
const readOpFrame = @import("frames.zig").readOpFrame;
const Batch = replica.Batch;
const Replica = replica.Replica;
const Stats = replica.Stats;
const max_batch_bytes = replica.max_batch_bytes;
const max_pending_bytes = replica.max_pending_bytes;
const max_seq = replica.max_seq;
const rowOp = replica.rowOp;

/// Refetches the fields a removal dropped (see `Replica.cut`) from a device,
/// whose winners exclude the refused writes, through the same frames a
/// network carries.
pub fn repair(dst: *Replica, src: *Replica) !Stats {
    var arena_state = std.heap.ArenaAllocator.init(src.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var response: std.Io.Writer.Allocating = .init(arena);
    _ = try writeRepair(src, arena, try repairFields(dst, arena), dst.personKey(), &response.writer);
    var reader: std.Io.Reader = .fixed(response.written());
    return readRepair(dst, &reader);
}

/// A key's field.
pub const Field = struct { key: []const u8, field: []const u8 };

/// Writes the fields to refetch: a count (u32), then each one's key and field,
/// each its length (u16) and bytes.
pub fn writeFields(w: *std.Io.Writer, fields: []const Field) !void {
    try w.writeInt(u32, @intCast(fields.len), .little);
    for (fields) |f| {
        try w.writeInt(u16, @intCast(f.key.len), .little);
        try w.writeAll(f.key);
        try w.writeInt(u16, @intCast(f.field.len), .little);
        try w.writeAll(f.field);
    }
}

/// The most fields one repair asks for, so a request can't ask for more
/// than a library holds.
const max_repair_fields = 1 << 20;

pub fn readFields(arena: std.mem.Allocator, r: *std.Io.Reader) ![]Field {
    const n = try r.takeInt(u32, .little);
    if (n > max_repair_fields) return error.Malformed;
    var out: std.ArrayList(Field) = .empty;
    var budget: usize = max_batch_bytes;
    for (0..n) |_| {
        const key = try takeText(r, arena, try r.takeInt(u16, .little), &budget);
        const field = try takeText(r, arena, try r.takeInt(u16, .little), &budget);
        try out.append(arena, .{ .key = key, .field = field });
    }
    return out.items;
}

/// The fields a removal dropped, which a repair refetches.
pub fn repairFields(dst: *Replica, arena: std.mem.Allocator) ![]Field {
    var fields: std.ArrayList(Field) = .empty;
    const s = try dst.db.prepare("SELECT key, field FROM repair");
    defer s.finalize();
    while (try s.step()) try fields.append(arena, .{
        .key = try arena.dupe(u8, s.blob(0)),
        .field = try arena.dupe(u8, s.blob(1)),
    });
    return fields.items;
}

const Found = struct { id: i64, op: Op };

fn foundBefore(_: void, a: Found, b: Found) bool {
    return if (a.id != b.id) a.id < b.id else a.op.seq < b.op.seq;
}

/// Answers a repair: the winning operations of `fields`, for each batch they
/// come from, an `R` frame, then an `O` frame for each operation:
///
/// * `R` device (32) | first seq (8) | count (4) | signature (64) |
///   operations (2) | their indices in the batch (2 each) | proof hashes (2) |
///   the hashes (32 each)
///
/// with one shared proof per batch (the sibling hashes covering all the
/// operations taken from it), so the receiver verifies them against the
/// batch's signed root without its other leaves; then `E`. Streams that aren't
/// `reader`'s (its person's private ones) are left out, as a sync's are.
/// Returns how many operations it sent.
pub fn writeRepair(src: *Replica, arena: std.mem.Allocator, fields: []const Field, reader: Device, w: *std.Io.Writer) !usize {
    var allowed: std.AutoHashMapUnmanaged(Device, void) = .empty;
    for (try src.readableVector(arena, reader)) |entry| try allowed.put(arena, entry.device, {});

    var found: std.ArrayList(Found) = .empty;
    const s = try src.db.prepare(
        \\SELECT kind, key, field, hlc, seq, value, device FROM winners
        \\WHERE key = ?1 AND field = ?2
    );
    defer s.finalize();
    for (fields) |f| {
        defer s.reset();
        try s.bindText(1, f.key);
        try s.bindText(2, f.field);
        if (!try s.step()) continue;
        const id = s.int(6);
        const device = try src.keyOf(id);
        if (!allowed.contains(device)) continue;
        var op = rowOp(src, s, device);
        op.key = try arena.dupe(u8, op.key);
        op.field = try arena.dupe(u8, op.field);
        op.value = try arena.dupe(u8, op.value);
        try found.append(arena, .{ .id = id, .op = op });
    }
    std.mem.sort(Found, found.items, {}, foundBefore);
    // A request may name a field more than once, but an operation is
    // proved once: duplicates would break a proof, or overrun its indices.
    var kept: usize = 0;
    for (found.items) |f| {
        if (kept > 0 and found.items[kept - 1].id == f.id and found.items[kept - 1].op.seq == f.op.seq) continue;
        found.items[kept] = f;
        kept += 1;
    }
    found.items.len = kept;

    const gpa = src.gpa;
    var leaves: std.ArrayList(Hash) = .empty;
    defer leaves.deinit(gpa);
    const tree = try gpa.create(merkle.Tree);
    defer gpa.destroy(tree);
    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(gpa);
    var siblings: std.ArrayList(Hash) = .empty;
    defer siblings.deinit(gpa);

    var at: usize = 0;
    while (at < found.items.len) {
        const id = found.items[at].id;
        const batch = try src.loadBatch(id, found.items[at].op.seq, &leaves);
        var end = at;
        indices.clearRetainingCapacity();
        while (end < found.items.len and found.items[end].id == id and batch.contains(found.items[end].op.seq)) : (end += 1)
            try indices.append(gpa, found.items[end].op.seq - batch.first);
        if (end == at) return error.NoBatch;
        tree.init(batch.leaves);
        siblings.clearRetainingCapacity();
        try tree.multiproof(indices.items, gpa, &siblings);

        try w.writeByte('R');
        try w.writeAll(&batch.device);
        try w.writeInt(u64, batch.first, .little);
        try w.writeInt(u32, @intCast(batch.leaves.len), .little);
        try w.writeAll(&batch.sig);
        try w.writeInt(u16, @intCast(indices.items.len), .little);
        for (indices.items) |i| try w.writeInt(u16, @intCast(i), .little);
        try w.writeInt(u16, @intCast(siblings.items.len), .little);
        for (siblings.items) |h| try w.writeAll(&h);
        for (found.items[at..end]) |f| try writeOpFrame(w, f.op);
        at = end;
    }
    try w.writeByte('E');
    return found.items.len;
}

/// Applies a repair's frames (see `writeRepair`) in one transaction. A batch
/// whose stream isn't admitted yet waits for the rest of them.
pub fn readRepair(dst: *Replica, r: *std.Io.Reader) !Stats {
    var text_state = std.heap.ArenaAllocator.init(dst.gpa);
    defer text_state.deinit();
    const Pending = struct { batch: Batch, count: usize, indices: []usize, siblings: []Hash, ops: []Op };
    var pending_state = std.heap.ArenaAllocator.init(dst.gpa);
    defer pending_state.deinit();
    const pa = pending_state.allocator();
    var pending: std.ArrayList(Pending) = .empty;
    var pending_bytes: usize = 0;

    var stats: Stats = .{};
    try dst.begin();
    errdefer dst.rollback();
    while (true) {
        const tag = try r.takeByte();
        switch (tag) {
            'R' => {
                _ = text_state.reset(.retain_capacity);
                const ta = text_state.allocator();
                var batch: Batch = undefined;
                try r.readSliceAll(&batch.device);
                batch.first = try r.takeInt(u64, .little);
                const count = try r.takeInt(u32, .little);
                if (batch.first == 0 or batch.first > max_seq) return error.Malformed;
                if (count == 0 or count > merkle.max_leaves) return error.Malformed;
                try r.readSliceAll(&batch.sig);
                batch.leaves = &.{};
                const n = try r.takeInt(u16, .little);
                if (n == 0 or n > count) return error.Malformed;
                const indices = try ta.alloc(usize, n);
                for (indices) |*i| {
                    i.* = try r.takeInt(u16, .little);
                    if (i.* >= count) return error.Malformed;
                }
                const siblings = try ta.alloc(Hash, try r.takeInt(u16, .little));
                for (siblings) |*h| try r.readSliceAll(h);
                const ops = try ta.alloc(Op, n);
                var budget: usize = max_batch_bytes;
                for (ops, indices) |*op, i| op.* = try readOpFrame(r, ta, dst.library, batch.device, batch.first + i, &budget);
                dst.receiveShared(batch, count, indices, siblings, ops, &stats) catch |err| switch (err) {
                    error.Unauthorized => {
                        pending_bytes += max_batch_bytes - budget;
                        if (pending_bytes > max_pending_bytes) return error.Malformed;
                        const copied = try pa.dupe(Op, ops);
                        for (copied) |*op| {
                            op.key = try pa.dupe(u8, op.key);
                            op.field = try pa.dupe(u8, op.field);
                            op.value = try pa.dupe(u8, op.value);
                        }
                        try pending.append(pa, .{ .batch = batch, .count = count, .indices = try pa.dupe(usize, indices), .siblings = try pa.dupe(Hash, siblings), .ops = copied });
                    },
                    else => |e| return e,
                };
                stats.batches += 1;
                stats.wire_bytes += Batch.header_wire_len + 2 + 2 * indices.len + 32 * siblings.len;
                for (ops) |op| stats.wire_bytes += op.wireLen();
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

/// Fetches `fields` from `src` through a repair's frames.
pub fn fetchFields(dst: *Replica, src: *Replica, fields: []const Field) !Stats {
    var arena_state = std.heap.ArenaAllocator.init(src.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var response: std.Io.Writer.Allocating = .init(arena);
    _ = try writeRepair(src, arena, fields, dst.personKey(), &response.writer);
    var reader: std.Io.Reader = .fixed(response.written());
    return readRepair(dst, &reader);
}
