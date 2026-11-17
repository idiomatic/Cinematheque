//! Percent-encoding of path segments, as listings' links need.

const std = @import("std");

fn unreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

/// Appends `segment` percent-encoded, keeping only unreserved bytes as is.
pub fn encode(gpa: std.mem.Allocator, out: *std.ArrayList(u8), segment: []const u8) !void {
    for (segment) |c| {
        if (unreserved(c)) {
            try out.append(gpa, c);
        } else {
            try out.print(gpa, "%{X:0>2}", .{c});
        }
    }
}

/// Decodes `text` in place, returning the decoded prefix.
pub fn decode(text: []u8) ![]u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (out += 1) {
        if (text[i] == '%') {
            if (i + 2 >= text.len) return error.BadEscape;
            text[out] = std.fmt.parseInt(u8, text[i + 1 ..][0..2], 16) catch return error.BadEscape;
            i += 3;
        } else {
            text[out] = text[i];
            i += 1;
        }
    }
    return text[0..out];
}

test "encode and decode round-trip" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const name = "Amélie (2001) 100% & more?.mkv";
    try encode(gpa, &out, name);
    try std.testing.expectEqualStrings("Am%C3%A9lie%20%282001%29%20100%25%20%26%20more%3F.mkv", out.items);
    try std.testing.expectEqualStrings(name, try decode(out.items));
}
