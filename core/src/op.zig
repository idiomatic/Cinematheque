//! An operation: one write of one field, by one device. Devices sign
//! batches of operations (see merkle.zig), not operations one by one.
//!
//! Canonical encoding, all integers little-endian:
//! library (16) | device (32) | seq (8) | hlc (8) | kind (1) |
//! key length (2) | key | field length (2) | field | value length (4) | value

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;

pub const Library = [16]u8;
pub const Device = [Ed25519.PublicKey.encoded_length]u8;
pub const Signature = [Ed25519.Signature.encoded_length]u8;

pub const Kind = enum(u8) {
    /// The value replaces the field's; the later clock wins.
    lww = 0,
    /// The field is a set element; the value is its causal length (u32),
    /// odd while present, and the longer length wins.
    causal_length = 1,
};

pub const Op = struct {
    library: Library,
    device: Device,
    seq: u64,
    hlc: u64,
    kind: Kind,
    key: []const u8,
    field: []const u8,
    value: []const u8,

    pub fn encode(op: Op, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        out.clearRetainingCapacity();
        try out.appendSlice(gpa, &op.library);
        try out.appendSlice(gpa, &op.device);
        try appendInt(gpa, out, u64, op.seq);
        try appendInt(gpa, out, u64, op.hlc);
        try out.append(gpa, @intFromEnum(op.kind));
        try appendInt(gpa, out, u16, @intCast(op.key.len));
        try out.appendSlice(gpa, op.key);
        try appendInt(gpa, out, u16, @intCast(op.field.len));
        try out.appendSlice(gpa, op.field);
        try appendInt(gpa, out, u32, @intCast(op.value.len));
        try out.appendSlice(gpa, op.value);
    }

    /// The returned op borrows slices of `body`.
    pub fn decode(body: []const u8) error{Malformed}!Op {
        var r: Reader = .{ .bytes = body };
        const op: Op = .{
            .library = (try r.take(16))[0..16].*,
            .device = (try r.take(32))[0..32].*,
            .seq = try r.int(u64),
            .hlc = try r.int(u64),
            .kind = std.enums.fromInt(Kind, (try r.take(1))[0]) orelse return error.Malformed,
            .key = try r.take(try r.int(u16)),
            .field = try r.take(try r.int(u16)),
            .value = try r.take(try r.int(u32)),
        };
        if (r.at != body.len) return error.Malformed;
        return op;
    }

    /// Bytes on the wire within a batch, which already names the library
    /// and device.
    pub fn wireLen(op: Op) usize {
        return 8 + 8 + 1 + 2 + op.key.len + 2 + op.field.len + 4 + op.value.len;
    }
};

pub fn causalLength(value: []const u8) u32 {
    return if (value.len == 4) std.mem.readInt(u32, value[0..4], .little) else 0;
}

fn appendInt(gpa: std.mem.Allocator, out: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try out.appendSlice(gpa, &bytes);
}

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(r: *Reader, n: usize) error{Malformed}![]const u8 {
        if (r.bytes.len - r.at < n) return error.Malformed;
        defer r.at += n;
        return r.bytes[r.at..][0..n];
    }

    fn int(r: *Reader, comptime T: type) error{Malformed}!T {
        return std.mem.readInt(T, (try r.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }
};

test "encode and decode round-trip" {
    const gpa = std.testing.allocator;
    const op: Op = .{
        .library = @splat(2),
        .device = @splat(1),
        .seq = 3,
        .hlc = 4,
        .kind = .lww,
        .key = "t/00001",
        .field = "name",
        .value = "Metropolis",
    };
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try op.encode(gpa, &body);
    const decoded = try Op.decode(body.items);
    try std.testing.expectEqualStrings("Metropolis", decoded.value);
    try std.testing.expectEqual(@as(u64, 3), decoded.seq);
    try std.testing.expectEqual(Kind.lww, decoded.kind);
    body.items[64] = 9;
    try std.testing.expectError(error.Malformed, Op.decode(body.items));
}
