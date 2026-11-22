//! replica.zig's tests: replicas syncing, merging, admitting, removing,
//! and repairing, as devices would.

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
const readFields = replica.readFields;
const readVector = replica.readVector;
const readOpFrame = @import("frames.zig").readOpFrame;
const repair = replica.repair;
const readSync = replica.readSync;
const writeOpFrame = @import("frames.zig").writeOpFrame;
const Field = replica.Field;
const testing = std.testing;
const fetchFields = @import("repair.zig").fetchFields;
const sync = replica.sync;
const writeSync = replica.writeSync;
const Identity = replica.Identity;
const Replica = replica.Replica;
const Stats = replica.Stats;
const certKey = replica.certKey;
const certMessage = replica.certMessage;
const libraryId = replica.libraryId;
const max_batch_bytes = replica.max_batch_bytes;
const max_value_len = replica.max_value_len;
const max_vector_entries = replica.max_vector_entries;
const personKeyPair = replica.personKeyPair;
const verifyBatch = replica.verifyBatch;

fn testPerson(seed: u8) !Device {
    return (try personKeyPair(@splat(seed))).public_key.toBytes();
}

const Devices = struct {
    arena_state: std.heap.ArenaAllocator,
    replicas: [3]Replica,

    /// Replica 0's person founds the library; `added` of the others' people
    /// are members, and every replica has caught up with replica 0.
    fn initAdding(others: *Devices, added: usize) !void {
        others.arena_state = .init(testing.allocator);
        const founder = try testPerson(1);
        for (&others.replicas, 1..) |*r, seed| {
            r.* = try Replica.open(testing.allocator, testing.io, ":memory:", founder, .from(@splat(@intCast(seed))));
        }
        for (1..added + 1) |i| try others.replicas[0].addMember(1, try testPerson(@intCast(i + 1)));
        for (1..others.replicas.len) |i| _ = try others.sync(i, 0);
    }

    fn init(others: *Devices) !void {
        try others.initAdding(2);
    }

    fn deinit(others: *Devices) void {
        for (&others.replicas) |*r| r.close();
        others.arena_state.deinit();
    }

    fn sync(others: *Devices, dst: usize, src: usize) !Stats {
        return replica_sync(others.arena_state.allocator(), &others.replicas[dst], &others.replicas[src]);
    }

    fn value(others: *Devices, r: usize, key: []const u8, field: []const u8) ![]const u8 {
        const s = try others.replicas[r].db.prepare("SELECT value FROM winners WHERE key = ?1 AND field = ?2");
        defer s.finalize();
        try s.bindText(1, key);
        try s.bindText(2, field);
        if (!try s.step()) return error.Missing;
        return others.arena_state.allocator().dupe(u8, s.blob(0));
    }
};

const replica_sync = sync;

test "concurrent writes to one field converge on the later one" {
    var p: Devices = undefined;
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
    var p: Devices = undefined;
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
    var p: Devices = undefined;
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

test "relayed operations reach a third device, and superseded ones are skipped" {
    var p: Devices = undefined;
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
    var p: Devices = undefined;
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

test "a batch's signature covers its range" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];

    try a.begin();
    for (0..3) |i| {
        var key: [16]u8 = undefined;
        try a.write(1000, try std.fmt.bufPrint(&key, "t/{d:0>5}", .{i}), "name", "x");
    }
    try a.commit();
    const s = try a.db.prepare("SELECT first, count, root, sig FROM batches WHERE count = 3");
    defer s.finalize();
    try testing.expect(try s.step());
    const first: u64 = @intCast(s.int(0));
    const count: usize = @intCast(s.int(1));
    const root = s.blob(2)[0..32].*;
    const sig = s.blob(3)[0..64].*;
    try verifyBatch(a.library, a.device(), first, count, root, sig);
    try testing.expectError(error.SignatureVerificationFailed, verifyBatch(a.library, a.device(), first + 1, count, root, sig));
    try testing.expectError(error.SignatureVerificationFailed, verifyBatch(a.library, a.device(), first, count - 1, root, sig));
    try testing.expectError(error.SignatureVerificationFailed, verifyBatch(@splat(9), a.device(), first, count, root, sig));
}

test "a response is believed only from the device that signed it, for its request" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const arena = p.arena_state.allocator();
    const a = &p.replicas[0];
    const b = &p.replicas[1];
    try a.write(1000, "t/00001", "name", "Metropolis");

    const request: [64]u8 = @splat(5);
    var response: std.Io.Writer.Allocating = .init(arena);
    _ = try writeSync(a, arena, try b.versionVector(arena), b.personKey(), request, &response.writer);
    const frames = response.written();

    const sender = a.device();
    // Another request's answer, or another device's claim, is refused.
    var r: std.Io.Reader = .fixed(frames);
    try testing.expectError(error.BadSignature, readSync(b, &r, null, .{ .request = @splat(6), .sender = sender }));
    r = .fixed(frames);
    try testing.expectError(error.BadSignature, readSync(b, &r, null, .{ .request = request, .sender = p.replicas[2].device() }));
    // So is one whose vector was changed on the way, or one unsigned.
    const changed = try arena.dupe(u8, frames);
    changed[changed.len - 2 - 64 - 1] ^= 1;
    r = .fixed(changed);
    try testing.expectError(error.BadSignature, readSync(b, &r, null, .{ .request = request, .sender = sender }));
    const unsigned = try arena.dupe(u8, frames[0 .. frames.len - 65]);
    unsigned[unsigned.len - 1] = 'E';
    r = .fixed(unsigned[0 .. unsigned.len]);
    try testing.expectError(error.BadSignature, readSync(b, &r, null, .{ .request = request, .sender = sender }));
    // Nothing of the refused was kept; the real one is taken.
    try testing.expectError(error.Missing, p.value(1, "t/00001", "name"));
    r = .fixed(frames);
    _ = try readSync(b, &r, null, .{ .request = request, .sender = sender });
    try testing.expectEqualStrings("Metropolis", try p.value(1, "t/00001", "name"));
}

test "membership: a removal wins over a concurrent addition, and stands" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];
    const b = &p.replicas[1];
    const hex = std.fmt.bytesToHex(try testPerson(9), .lower);

    try a.setMember(1000, "members", &hex, true);
    _ = try p.sync(1, 0);
    // Concurrently, a removes the person and b re-adds them (a no-op, since
    // b already holds them): the removal wins.
    try a.setMember(2000, "members", &hex, false);
    try b.setMember(2000, "members", &hex, true);
    _ = try p.sync(1, 0);
    _ = try p.sync(0, 1);
    try testing.expect(!try a.isMember("members", &hex));
    try testing.expect(!try b.isMember("members", &hex));
    // Removed for good: they come back as someone new.
    try testing.expectError(error.RemovedForGood, b.setMember(3000, "members", &hex, true));
}

test "a count no removal could outrank, and one of the wrong kind, are refused" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const b = &p.replicas[1];
    const hex = std.fmt.bytesToHex(try testPerson(9), .lower);

    var huge: [4]u8 = undefined;
    std.mem.writeInt(u32, &huge, std.math.maxInt(u32), .little);
    try b.begin();
    try b.writeOp(.causal_length, 1000, "members", &hex, &huge);
    try b.writeOp(.lww, 1000, "members", &std.fmt.bytesToHex(try testPerson(8), .lower), &.{ 1, 0, 0, 0 });
    try b.writeOp(.causal_length, 1000, "t/00001", "name", &.{ 9, 0, 0, 0 });
    try b.commit();
    const stats = try p.sync(0, 1);
    try testing.expectEqual(@as(usize, 3), stats.refused);
    try testing.expect(!try p.replicas[0].isMember("members", &hex));
}

test "an operation dated over a day ahead is refused, and a clock can't wrap" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];
    const b = &p.replicas[1];

    try b.write(2000, "t/00002", "name", "Now");
    try b.write(std.math.maxInt(u64) >> 16, "t/00001", "name", "Forever");
    a.now_ms = 2000;
    const stats = try p.sync(0, 1);
    try testing.expectEqual(@as(usize, 1), stats.refused);
    try testing.expectError(error.Missing, p.value(0, "t/00001", "name"));
    try testing.expectEqualStrings("Now", try p.value(0, "t/00002", "name"));
    // b's own clock is at its end, and stays there.
    var hlc: Hlc = .{ .last = std.math.maxInt(u64) };
    try testing.expectEqual(std.math.maxInt(u64), hlc.tick(1));
}

test "a stranger's word for what it holds isn't taken" {
    var p: Devices = undefined;
    try p.initAdding(1); // replica 2's person isn't a member
    defer p.deinit();
    const a = &p.replicas[0];
    const c = &p.replicas[2];
    const arena = p.arena_state.allocator();

    // c claims to hold everything of a's stream, and of the founder's
    // device's, signed by c itself.
    const request: [64]u8 = @splat(5);
    var response: std.Io.Writer.Allocating = .init(arena);
    const forged = try arena.dupe(replica.Entry, &.{ .{ .device = a.device(), .seq = replica.max_seq }, .{ .device = p.replicas[1].device(), .seq = replica.max_seq } });
    _ = try writeSync(c, arena, forged, c.personKey(), request, &response.writer);
    var r: std.Io.Reader = .fixed(response.written());
    _ = try readSync(a, &r, null, .{ .request = request, .sender = c.device() });
    try a.write(3000, "t/00001", "name", "Still numbered");
    // a still numbers its writes where they were, so b takes them.
    _ = try p.sync(1, 0);
    try testing.expectEqualStrings("Still numbered", try p.value(1, "t/00001", "name"));
}

test "a certificate for another device's stream is refused" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];
    const b = &p.replicas[1];
    const arena = p.arena_state.allocator();
    const private_key = try std.fmt.allocPrint(arena, "p/{s}/t/m/alien/1979/v/-", .{std.fmt.bytesToHex(a.personKey(), .lower)});
    try a.writePrivate(1000, private_key, &.{.{ "position", "1234" }});
    _ = try p.sync(1, 0);

    // b claims a's private stream as its person's, as a device and as a
    // private stream, by certificates its person signs.
    const stream = a.private_pair.public_key.toBytes();
    var key: [66]u8 = undefined;
    var forged: [96]u8 = undefined;
    forged[0..32].* = b.personKey();
    for ([_]bool{ false, true }) |private| {
        forged[32..].* = (try b.person.sign(&replica.certMessage(b.library, stream, private), null)).toBytes();
        try b.write(2000, certKey(&key, stream), if (private) "private" else "user", &forged);
    }
    const stats = try p.sync(0, 1);
    try testing.expectEqual(@as(usize, 2), stats.refused);
    const c = (try a.certified(stream, &.{})).?;
    try testing.expect(c.private and std.mem.eql(u8, &c.person, &a.personKey()));
    // So a doesn't offer b's person its private stream.
    for (try a.readableVector(arena, b.personKey())) |entry|
        try testing.expect(!std.mem.eql(u8, &entry.device, &stream));
}

test "only the founder removes the founder's devices, and a removal can't be undone" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0]; // the founder's
    const b = &p.replicas[1];
    const c = &p.replicas[2];
    try a.write(1000, "t/00001", "name", "Alien");
    _ = try p.sync(1, 0);
    _ = try p.sync(2, 0);

    // a removes c's device; b can't raise the cutoff to undo it.
    try a.revokeDevice(2000, c.device());
    _ = try p.sync(1, 0);
    const cutoff = (try b.revoked(c.device())).?;
    var higher: [8]u8 = undefined;
    std.mem.writeInt(u64, &higher, replica.max_seq, .little);
    try b.write(3000, "revoked", &std.fmt.bytesToHex(c.device(), .lower), &higher);
    try testing.expectEqual(cutoff, (try b.revoked(c.device())).?);

    // b may not remove the founder's device, nor by writing it outright:
    // a device that hears of it (here, one of the founder's) refuses it.
    try testing.expectError(error.FoundersDevice, b.revokeDevice(4000, a.device()));
    var zero: [8]u8 = @splat(0);
    try b.write(4000, "revoked", &std.fmt.bytesToHex(a.device(), .lower), &zero);
    const stats = try p.sync(0, 1);
    try testing.expectEqual(@as(usize, 1), stats.refused);
    try testing.expectEqual(@as(?u64, null), try a.revoked(a.device()));
    try testing.expectEqualStrings("Alien", try p.value(0, "t/00001", "name"));
}

test "a batch over numbers another batch holds is refused" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const b = &p.replicas[1];

    try b.begin();
    for (0..3) |i| {
        var key: [16]u8 = undefined;
        try b.write(1000, try std.fmt.bufPrint(&key, "t/{d:0>5}", .{i}), "name", "first");
    }
    try b.commit();
    _ = try p.sync(0, 1);
    // b numbers writes again, from within the batch a holds to past it,
    // and signs them as one batch.
    b.seq -= 2;
    try b.begin();
    for (10..13) |i| {
        var key: [16]u8 = undefined;
        try b.write(2000, try std.fmt.bufPrint(&key, "t/{d:0>5}", .{i}), "name", "again");
    }
    try b.commit();
    const stats = try p.sync(0, 1);
    try testing.expectEqual(@as(usize, 1), stats.refused);
    try testing.expectError(error.Missing, p.value(0, "t/00012", "name"));
}

test "a source's address is its own, and its device's alone to mark as downloads" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];
    const b = &p.replicas[1];
    const nas = "http://nas.local/Movies/";
    var hash: [8]u8 = undefined;
    Blake3.hash(nas, &hash, .{});
    const key = try std.fmt.allocPrint(p.arena_state.allocator(), "r/{s}", .{std.fmt.bytesToHex(hash, .lower)});
    try a.write(1000, key, "url", nas);
    _ = try p.sync(1, 0);

    // b points it elsewhere, claims it (as if re-adding it), and marks it
    // as its downloads, so no one would crawl it: c takes none of that.
    try b.write(2000, key, "url", "http://skynet.example/");
    try b.write(2001, key, "url", nas);
    try b.write(2002, key, "managed", "1");
    _ = try p.sync(2, 0);
    const stats = try p.sync(2, 1);
    try testing.expectEqual(@as(usize, 2), stats.refused);
    try testing.expectEqualStrings(nas, try p.value(2, key, "url"));
    try testing.expectError(error.Missing, p.value(2, key, "managed"));
}

test "a shared list is every member's to see, and its owner's alone to change" {
    const lists = @import("lists.zig");
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const arena = p.arena_state.allocator();
    const a = &p.replicas[0];
    const b = &p.replicas[1];
    const id = try lists.create(testing.io, a, arena, 1000, "Date Night");
    try lists.setListed(a, arena, 1001, id, "t/m/alien/1979", true);
    _ = try lists.want(a, arena, 1002, id, .movie, "Dune: Part Three", 2026, null, "");
    try lists.share(testing.io, a, arena, 1003, id);
    _ = try p.sync(1, 0);

    // b sees a's list, as a's, with its titles and placeholder.
    var seen = try lists.lists(b, arena);
    try testing.expectEqual(@as(usize, 2), seen.len);
    try testing.expectEqualStrings("Date Night", seen[1].name);
    try testing.expect(!seen[1].mine and seen[1].mode == .shared);
    try testing.expectEqualStrings(&std.fmt.bytesToHex(a.personKey(), .lower), seen[1].owner);
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}/{s}", .{ seen[1].owner, id }), seen[1].id);
    try testing.expectEqual(@as(usize, 2), seen[1].titles.len);
    try testing.expectEqual(@as(usize, 1), seen[1].wanted.len);
    try testing.expectError(error.NotFound, lists.setListed(b, arena, 2000, id, "t/m/heat/1995", true));

    // b writing to it anyway, as if it were its own: c takes none of it.
    const key = try std.fmt.allocPrint(arena, "l/{s}/{s}", .{ std.fmt.bytesToHex(a.personKey(), .lower), id });
    try b.write(2001, key, "t/m/heat/1995", "1");
    try b.write(2002, key, "name", "Mine Now");
    _ = try p.sync(2, 0);
    const stats = try p.sync(2, 1);
    try testing.expectEqual(@as(usize, 2), stats.refused);
    seen = try lists.lists(&p.replicas[2], arena);
    try testing.expectEqualStrings("Date Night", seen[1].name);
    try testing.expectEqual(@as(usize, 2), seen[1].titles.len);

    // Made private again, it's gone from b's lists, and a keeps its titles.
    try lists.stopSharing(testing.io, a, arena, 3000, id);
    _ = try p.sync(1, 0);
    try testing.expectEqual(@as(usize, 1), (try lists.lists(b, arena)).len);
    seen = try lists.lists(a, arena);
    try testing.expect(seen[0].mine and seen[0].mode == .private);
    try testing.expectEqual(@as(usize, 2), seen[0].titles.len);
}

test "fetched fields are verified by shared proof" {
    var p: Devices = undefined;
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

test "batches from devices of people who aren't members are rejected, then accepted once added" {
    var p: Devices = undefined;
    try p.initAdding(1); // replica 2's person isn't a member
    defer p.deinit();
    const a = &p.replicas[0];
    const c = &p.replicas[2];

    try c.write(1000, "t/00001", "name", "Unadded");
    const rejected = try p.sync(1, 2);
    try testing.expect(rejected.rejected > 0);
    try testing.expectError(error.Missing, p.value(1, "t/00001", "name"));

    // a adds c's person; b hears of it from a, then accepts c's writes,
    // since b didn't claim them in its version vector.
    try a.addMember(2000, try testPerson(3));
    _ = try p.sync(1, 0);
    const accepted = try p.sync(1, 2);
    try testing.expectEqual(@as(usize, 0), accepted.rejected);
    try testing.expectEqualStrings("Unadded", try p.value(1, "t/00001", "name"));
}

test "a device whose certificate doesn't verify writes a fresh one, and its whole stream is accepted" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const c = &p.replicas[2];

    // c's stream starts with a certificate signed for another library.
    var key: [66]u8 = undefined;
    const sig = try c.person.sign(&certMessage(libraryId(@splat(9)), c.device(), false), null);
    try c.write(0, certKey(&key, c.device()), "user", &(c.personKey() ++ sig.toBytes()));
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
    try c.writePrivate(2000, try std.fmt.allocPrint(p.arena_state.allocator(), "p/{s}/t/m/x/2000/v/-", .{std.fmt.bytesToHex(c.personKey(), .lower)}), &.{.{ "position", "60000" }});
    try c.write(2000, "t/00002", "name", "Nosferatu");
    const stats = try p.sync(1, 2);
    try testing.expectEqual(@as(usize, 0), stats.rejected);
    try testing.expectEqualStrings("Metropolis", try p.value(1, "t/00001", "name"));
    try testing.expectEqualStrings("Nosferatu", try p.value(1, "t/00002", "name"));
}

test "a device removed has its later writes refused, though its person stays" {
    var p: Devices = undefined;
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
    try testing.expect(try c.isMemberPerson(c.personKey()));
    try testing.expectError(error.ThisDevice, a.revokeDevice(4000, a.device()));
}

test "a device removing itself has its removal taken, and its later writes refused" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const c = &p.replicas[2];

    try c.write(1000, "t/00001", "name", "Before");
    try c.removeSelf(2000, null);
    try c.write(3000, "t/00002", "name", "After");
    try c.removeSelf(4000, null); // Again, as a retried leave: nothing.
    const stats = try p.sync(0, 2);
    try testing.expect(stats.refused > 0);
    try testing.expectEqualStrings("Before", try p.value(0, "t/00001", "name"));
    try testing.expectError(error.Missing, p.value(0, "t/00002", "name"));
    // The removal reaches a device that hears of it only from another, and
    // the write after it doesn't, even from the removed device itself.
    _ = try p.sync(1, 0);
    _ = try p.sync(1, 2);
    try testing.expectEqualStrings("Before", try p.value(1, "t/00001", "name"));
    try testing.expectError(error.Missing, p.value(1, "t/00002", "name"));
}

test "a founder's device removing itself hands the library over first" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];
    const b = &p.replicas[1];

    try a.removeSelf(2000, b.personKey());
    _ = try p.sync(1, 0);
    try testing.expectEqual(b.personKey(), b.founder);
    try a.write(3000, "t/00003", "name", "After");
    try testing.expect((try p.sync(1, 0)).refused > 0);
    try testing.expectError(error.Missing, p.value(1, "t/00003", "name"));
}

test "an invitation later in the same response admits earlier batches" {
    var p: Devices = undefined;
    try p.initAdding(1);
    defer p.deinit();
    const a = &p.replicas[0];
    const c = &p.replicas[2];

    // a learns c's writes before inviting c's person, so a rejects them;
    // after inviting, a takes them on the next sync.
    try c.write(1000, "t/00002", "name", "Relayed");
    try testing.expect((try p.sync(0, 2)).rejected > 0);
    try a.addMember(2000, try testPerson(3));
    _ = try p.sync(0, 2);
    // b, fresh, gets c's batches and a's invitation in one response from a,
    // in whatever order the devices come.
    const b_stats = try p.sync(1, 0);
    try testing.expectEqual(@as(usize, 0), b_stats.rejected);
    try testing.expect(b_stats.deferred > 0);
    try testing.expectEqualStrings("Relayed", try p.value(1, "t/00002", "name"));
}

test "a device that took a removed device's later writes repairs from one that refused them" {
    var p: Devices = undefined;
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
    try testing.expect(try c.isMemberPerson(b.personKey()));
}

test "the founder can't be removed" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    try testing.expectError(error.FounderIsPermanent, p.replicas[1].removeMember(1000, try testPerson(1)));
}

test "a removed member's writes up to the cutoff stand, and later ones are refused" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];
    const b = &p.replicas[1];

    try b.write(1000, "t/00001", "name", "before");
    _ = try p.sync(0, 1);
    try a.removeMember(2000, try testPerson(2));
    try b.write(3000, "t/00001", "name", "after");
    try b.write(3000, "t/00002", "name", "new");
    const stats = try p.sync(0, 1);
    try testing.expectEqual(@as(usize, 2), stats.refused);
    try testing.expectEqualStrings("before", try p.value(0, "t/00001", "name"));
    try testing.expectError(error.Missing, p.value(0, "t/00002", "name"));
}

test "a device that took a removed member's later writes repairs from one that refused them" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];
    const b = &p.replicas[1];
    const c = &p.replicas[2];

    try b.write(1000, "t/00001", "name", "before");
    _ = try p.sync(0, 1);
    try a.removeMember(2000, try testPerson(2));
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
    // The field a never had stays pending, in case another device has it.
    try testing.expectEqual(@as(i64, 1), try c.repairsPending());
    // b's later writes stay refused, from b or anyone.
    _ = try p.sync(2, 1);
    try testing.expectEqualStrings("before", try p.value(2, "t/00001", "name"));
    _ = try p.sync(0, 2);
    try testing.expectEqualStrings("before", try p.value(0, "t/00001", "name"));
}

test "the founder hands over to a successor, who is then permanent" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];
    const b = &p.replicas[1];
    const c = &p.replicas[2];

    try a.handOver(1000, try testPerson(2), true);
    _ = try p.sync(1, 0);
    _ = try p.sync(2, 0);
    for (&p.replicas) |*r| try testing.expectEqual(try testPerson(2), r.founder);
    // The former founder, still a member, can be removed, but not the new one.
    try testing.expectError(error.FounderIsPermanent, a.removeMember(2000, try testPerson(2)));
    try b.removeMember(2000, try testPerson(1));
    _ = try p.sync(2, 1);
    try testing.expect(!try c.isMemberPerson(try testPerson(1)));
    // Only the founder may hand over.
    try testing.expectError(error.NotFounder, c.handOver(3000, try testPerson(3), true));
}

test "a handover not from the founder is refused" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const b = &p.replicas[1];

    // b forges generation 1, naming itself.
    try b.write(1000, "founders", "000001", &(try testPerson(2)));
    const stats = try p.sync(0, 1);
    try testing.expectEqual(@as(usize, 1), stats.refused);
    try testing.expectEqual(try testPerson(1), p.replicas[0].founder);
}

test "a chain of handovers arriving out of order is followed" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];
    const b = &p.replicas[1];

    try a.handOver(1000, try testPerson(2), false);
    _ = try p.sync(1, 0);
    try b.handOver(2000, try testPerson(3), true);
    // c learned of a's device before b's, so a fresh device syncing from c
    // gets b's generation 2 ahead of a's generation 1 (devices learned last
    // come first), holds it, then follows the chain.
    _ = try p.sync(2, 1);
    var d = try Replica.open(testing.allocator, testing.io, ":memory:", try testPerson(1), .from(@splat(9)));
    defer d.close();
    const stats = try replica_sync(p.arena_state.allocator(), &d, &p.replicas[2]);
    try testing.expect(stats.deferred > 0);
    try testing.expectEqual(try testPerson(3), d.founder);
    // a left the library when handing over.
    try testing.expect(!try d.isMemberPerson(try testPerson(1)));
}

test "private data reaches its person's other devices, directly, and no one else" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];
    const b = &p.replicas[1];
    // b2 is another device of b's person.
    var b2 = try Replica.open(testing.allocator, testing.io, ":memory:", try testPerson(1), .{ .device = @splat(42), .person = Identity.from(@splat(2)).person });
    defer b2.close();
    const key = try std.fmt.allocPrint(p.arena_state.allocator(), "p/{s}/t/m/alien/1979/v/-", .{std.fmt.bytesToHex(b.personKey(), .lower)});

    try b.write(1000, "t/m/alien/1979", "name", "Alien");
    try b.writePrivate(2000, key, &.{ .{ "position", "1234" }, .{ "duration", "7000" } });
    // a, another person, gets b's public writes but not its private ones.
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

test "private data written by anyone but its person's private stream is refused" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const b = &p.replicas[1];
    const c = &p.replicas[2];
    // c forges into b's private data, from its public stream.
    const key = try std.fmt.allocPrint(p.arena_state.allocator(), "p/{s}/t/m/alien/1979/v/-", .{std.fmt.bytesToHex(b.personKey(), .lower)});
    try c.write(1000, key, "position", "1");
    const stats = try p.sync(0, 2);
    try testing.expectEqual(@as(usize, 1), stats.refused);
    // And writePrivate takes only this person's keys.
    try testing.expectError(error.NotPrivate, c.writePrivate(1000, key, &.{.{ "position", "1" }}));
}

test "a device that lost its replica gets its own private data back" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const b = &p.replicas[1];
    const key = try std.fmt.allocPrint(p.arena_state.allocator(), "p/{s}/t/m/alien/1979/v/-", .{std.fmt.bytesToHex(b.personKey(), .lower)});
    try b.write(1000, "t/m/alien/1979", "name", "Alien");
    try b.writePrivate(2000, key, &.{.{ "position", "1234" }});
    // b2 is b's device again, with its replica lost (as tvOS may purge
    // one), rebuilt from a device of its person's.
    var b2 = try Replica.open(testing.allocator, testing.io, ":memory:", try testPerson(1), .{ .device = @splat(2), .person = Identity.from(@splat(2)).person });
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
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const b = &p.replicas[1];
    const key = try std.fmt.allocPrint(p.arena_state.allocator(), "p/{s}/t/m/alien/1979/v/-", .{std.fmt.bytesToHex(b.personKey(), .lower)});
    try b.writePrivate(1000, key, &.{.{ "position", "1" }});
    const stats = try p.sync(0, 1);
    try testing.expectEqual(@as(usize, 0), stats.rejected);
    try testing.expect(try p.replicas[0].certifiedPerson(b.device(), &.{}) != null);
}

test "a private stream without its certificate is sent only to its own person" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const arena = p.arena_state.allocator();
    const b = &p.replicas[1];
    const key = try std.fmt.allocPrint(arena, "p/{s}/t/m/alien/1979/v/-", .{std.fmt.bytesToHex(b.personKey(), .lower)});
    try b.writePrivate(2000, key, &.{.{ "position", "1234" }});
    // As on a device that took the stream before the certificate, which
    // travels on the public one.
    try b.db.exec("DELETE FROM winners WHERE key >= 'c/' AND key < 'c0' AND field = 'private'");
    const private = b.private_pair.public_key.toBytes();
    const others = try b.readableVector(arena, p.replicas[2].personKey());
    for (others) |entry| try testing.expect(!std.mem.eql(u8, &entry.device, &private));
    var found = false;
    for (try b.readableVector(arena, b.personKey())) |entry| found = found or std.mem.eql(u8, &entry.device, &private);
    try testing.expect(found);
}

test "frames and requests that claim more than they hold are refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var budget: usize = max_batch_bytes;

    // A value longer than any, then a batch's text past its budget.
    var frame: std.Io.Writer.Allocating = .init(arena);
    try writeOpFrame(&frame.writer, .{ .seq = 1, .hlc = 0, .kind = op_.Kind.lww, .key = "k", .field = "f", .value = "v" });
    var r: std.Io.Reader = .fixed(frame.written());
    _ = try readOpFrame(&r, arena, @splat(0), @splat(0), 1, &budget);
    const long = try arena.dupe(u8, frame.written());
    std.mem.writeInt(u32, long[1 + 8 + 8 + 1 + 2 + 1 + 2 + 1 ..][0..4], max_value_len + 1, .little);
    r = .fixed(long);
    try testing.expectError(error.Malformed, readOpFrame(&r, arena, @splat(0), @splat(0), 1, &budget));
    r = .fixed(frame.written());
    budget = 2;
    try testing.expectError(error.Malformed, readOpFrame(&r, arena, @splat(0), @splat(0), 1, &budget));

    // A vector that names more devices than it has bytes for.
    var vector: [4]u8 = undefined;
    std.mem.writeInt(u32, &vector, std.math.maxInt(u32), .little);
    r = .fixed(&vector);
    try testing.expectError(error.Malformed, readVector(arena, &r));
    std.mem.writeInt(u32, &vector, max_vector_entries, .little);
    r = .fixed(&vector);
    try testing.expectError(error.EndOfStream, readVector(arena, &r));

    // And fields, whose text is capped as well.
    var fields: std.Io.Writer.Allocating = .init(arena);
    try fields.writer.writeInt(u32, 1, .little);
    try fields.writer.writeInt(u16, 3, .little);
    try fields.writer.writeAll("key");
    try fields.writer.writeInt(u16, 5, .little);
    try fields.writer.writeAll("field");
    r = .fixed(fields.written());
    try testing.expectEqual(@as(usize, 1), (try readFields(arena, &r)).len);
}

test "a private write holds one to a batch's worth of fields" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const b = &p.replicas[1];
    const key = try std.fmt.allocPrint(p.arena_state.allocator(), "p/{s}/t/m/alien/1979/v/-", .{std.fmt.bytesToHex(b.personKey(), .lower)});
    try testing.expectError(error.BadBatchSize, b.writePrivate(1000, key, &.{}));
    const many = try p.arena_state.allocator().alloc([2][]const u8, merkle.max_leaves + 1);
    for (many) |*f| f.* = .{ "position", "1" };
    try testing.expectError(error.BadBatchSize, b.writePrivate(1000, key, many));
    try b.writePrivate(1000, key, many[0..merkle.max_leaves]);
}

test "a connection learns of devices another added" {
    const path = "/tmp/cinematheque-keys-test.db";
    std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
    const founder = (try personKeyPair(@splat(1))).public_key.toBytes();
    var a = try Replica.open(testing.allocator, testing.io, path, founder, .from(@splat(1)));
    defer a.close();
    var b = try Replica.open(testing.allocator, testing.io, path, founder, .from(@splat(1)));
    defer b.close();
    const id = try b.deviceId(@splat(9));
    try testing.expectEqualSlices(u8, &@as(Device, @splat(9)), &(try a.keyOf(id)));
    try testing.expectError(error.Sqlite, a.keyOf(id + 1));
}

test "two connections writing in turn, refreshing first, never reuse a sequence number" {
    const path = "/tmp/cinematheque-refresh-test.db";
    std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
    const founder = (try personKeyPair(@splat(1))).public_key.toBytes();
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

test "a device's write after a restart, or a clock step back, doesn't lose to its own earlier one" {
    const path = "/tmp/cinematheque-clock-test.db";
    std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
    const founder = (try personKeyPair(@splat(1))).public_key.toBytes();
    {
        var a = try Replica.open(testing.allocator, testing.io, path, founder, .from(@splat(1)));
        defer a.close();
        try a.write(5000, "t/m/a/-", "name", "first");
    }
    var a = try Replica.open(testing.allocator, testing.io, path, founder, .from(@splat(1)));
    defer a.close();
    var b = try Replica.open(testing.allocator, testing.io, path, founder, .from(@splat(1)));
    defer b.close();
    // The wall clock has stepped back since.
    try a.write(1000, "t/m/a/-", "name", "second");
    // Another connection to the same replica wrote meanwhile, later still.
    try b.write(9000, "t/m/b/-", "name", "x");
    try a.refresh();
    try a.write(2000, "t/m/b/-", "name", "y");
    const s = try a.db.prepare("SELECT key, value FROM winners WHERE field = 'name' ORDER BY key");
    defer s.finalize();
    try testing.expect(try s.step());
    try testing.expectEqualStrings("second", s.blob(1));
    try testing.expect(try s.step());
    try testing.expectEqualStrings("y", s.blob(1));
}

test "a repair request naming a field again and again is answered once" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];
    try a.write(1000, "t/00001", "name", "Metropolis");
    var cert: [66]u8 = undefined;
    _ = try fetchFields(&p.replicas[2], a, &.{.{ .key = certKey(&cert, a.device()), .field = "user" }});
    const same: [merkle.max_leaves + 5]Field = @splat(.{ .key = "t/00001", .field = "name" });
    const stats = try fetchFields(&p.replicas[2], a, &same);
    try testing.expectEqual(@as(usize, 1), stats.won);
}

test "a rolled-back transaction forgets the devices it learned of" {
    var p: Devices = undefined;
    try p.init();
    defer p.deinit();
    const a = &p.replicas[0];
    const known = a.keys.items.len;
    try a.begin();
    const stranger: Device = @splat(0x42);
    const id = try a.deviceId(stranger);
    try testing.expectEqual(@as(i64, @intCast(known + 1)), id);
    a.rollback();
    try testing.expectEqual(known, a.keys.items.len);
    try testing.expect(a.ids.get(stranger) == null);
    // The id is handed out again, to another device, and means that one.
    const other: Device = @splat(0x43);
    try testing.expectEqual(id, try a.deviceId(other));
    try testing.expectEqual(other, try a.keyOf(id));
}
