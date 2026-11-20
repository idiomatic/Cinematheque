//! JSON for the players: as `std.json.Stringify` writes it, but every
//! string valid UTF-8. Names come from files and other devices, so one
//! may not be (a Latin-1 name on an old share); `Stringify` would write
//! it as an array of numbers, which a player reading a string refuses,
//! and with it the whole result. Such a string's bad bytes become U+FFFD.

const std = @import("std");

pub fn valueAlloc(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    if (!needs(value)) return std.json.Stringify.valueAlloc(gpa, value, .{});
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    return std.json.Stringify.valueAlloc(gpa, try valid(arena_state.allocator(), value), .{});
}

/// Whether any string in `value` isn't valid UTF-8.
fn needs(value: anytype) bool {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.child == u8) return !std.unicode.utf8ValidateSlice(value);
                for (value) |v| if (needs(v)) return true;
                return false;
            },
            .one => return needs(value.*),
            else => return false,
        },
        .array => |a| {
            if (a.child == u8) return false;
            for (value) |v| if (needs(v)) return true;
            return false;
        },
        .optional => return if (value) |v| needs(v) else false,
        .@"struct" => |s| {
            inline for (s.field_names) |name| if (needs(@field(value, name))) return true;
            return false;
        },
        .@"union" => |u| {
            if (u.tag_type == null) return false;
            switch (value) {
                inline else => |v| return needs(v),
            }
        },
        else => return false,
    }
}

/// `value` with each string made valid UTF-8, copied only where needed.
fn valid(arena: std.mem.Allocator, value: anytype) !@TypeOf(value) {
    const T = @TypeOf(value);
    if (!needs(value)) return value;
    switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.child == u8) return repaired(arena, value);
                const out = try arena.alloc(p.child, value.len);
                for (out, value) |*o, v| o.* = try valid(arena, v);
                return out;
            },
            .one => {
                const out = try arena.create(p.child);
                out.* = try valid(arena, value.*);
                return out;
            },
            else => return value,
        },
        .array => {
            var out = value;
            for (&out) |*o| o.* = try valid(arena, o.*);
            return out;
        },
        .optional => return if (value) |v| try valid(arena, v) else null,
        .@"struct" => |s| {
            var out = value;
            inline for (s.field_names, s.field_attrs) |name, attrs| {
                if (!attrs.@"comptime") @field(out, name) = try valid(arena, @field(value, name));
            }
            return out;
        },
        .@"union" => switch (value) {
            inline else => |v, tag| return @unionInit(T, @tagName(tag), try valid(arena, v)),
        },
        else => return value,
    }
}

fn repaired(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 0;
        if (n > 0 and i + n <= text.len and std.unicode.utf8ValidateSlice(text[i..][0..n])) {
            try out.appendSlice(arena, text[i..][0..n]);
            i += n;
        } else {
            try out.appendSlice(arena, "\u{FFFD}");
            i += 1;
        }
    }
    return out.items;
}

test "strings that aren't UTF-8 are written as strings" {
    const gpa = std.testing.allocator;
    const Item = struct { name: []const u8, tags: []const []const u8, key: ?[]const u8 };
    const items = [_]Item{
        .{ .name = "Am\xe9lie", .tags = &.{ "ok", "bad\xff" }, .key = "t/m/am\xe9lie/2001" },
        .{ .name = "Alien", .tags = &.{}, .key = null },
    };
    const text = try valueAlloc(gpa, @as([]const Item, &items));
    defer gpa.free(text);
    try std.testing.expectEqualStrings("[{\"name\":\"Am\u{FFFD}lie\",\"tags\":[\"ok\",\"bad\u{FFFD}\"],\"key\":\"t/m/am\u{FFFD}lie/2001\"},{\"name\":\"Alien\",\"tags\":[],\"key\":null}]", text);
    const plain = try valueAlloc(gpa, .{ .name = "Amélie" });
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("{\"name\":\"Amélie\"}", plain);
}
