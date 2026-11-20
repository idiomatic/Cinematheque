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

/// Percent-encodes what can't appear in a URL as typed (spaces, quotes,
/// non-ASCII letters, and the like), keeping existing escapes and the
/// URL's structure.
pub fn escape(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| {
        const safe = c > 0x20 and c < 0x7f and std.mem.indexOfScalar(u8, "\"<>\\^`{|}", c) == null;
        if (safe) try out.append(gpa, c) else try out.print(gpa, "%{X:0>2}", .{c});
    }
}

test "escape a typed URL" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try escape(gpa, &out, "http://nas.local/Video/Movies/Very Fast 720p30/Amélie%20x/");
    try std.testing.expectEqualStrings("http://nas.local/Video/Movies/Very%20Fast%20720p30/Am%C3%A9lie%20x/", out.items);
}

/// Whether `text` may be a source's address: an http or https URL with a
/// host, of printable ASCII (spaces escaped), without a query or fragment.
/// A source's address replicates from any member, so a device checks it
/// before fetching from it, or opening it: else a member could aim other
/// devices' requests anywhere, in any form.
pub fn fitForSource(text: []const u8) bool {
    for (text) |c| if (c <= 0x20 or c >= 0x7f or c == '\\') return false;
    if (std.mem.indexOfAny(u8, text, "?#") != null) return false;
    const uri = std.Uri.parse(text) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return false;
    const host = uri.host orelse return false;
    return componentText(host).len > 0;
}

fn componentText(c: std.Uri.Component) []const u8 {
    return switch (c) {
        .raw, .percent_encoded => |s| s,
    };
}

fn port(uri: std.Uri) ?u16 {
    return uri.port orelse if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) 443 else if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) 80 else null;
}

fn optionalEql(a: ?std.Uri.Component, b: ?std.Uri.Component) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, componentText(a.?), componentText(b.?));
}

/// Whether two URLs are of one origin: scheme, user, host, and port.
pub fn sameOrigin(a: std.Uri, b: std.Uri) bool {
    return std.ascii.eqlIgnoreCase(a.scheme, b.scheme) and
        optionalEql(a.user, b.user) and optionalEql(a.password, b.password) and
        a.host != null and b.host != null and std.ascii.eqlIgnoreCase(componentText(a.host.?), componentText(b.host.?)) and
        port(a) == port(b);
}

/// Whether `target` lies within `base`: of its origin, and below its path
/// at a segment's boundary, with no `.` or `..` segment (encoded or not)
/// to climb out of it.
pub fn within(base: []const u8, target: []const u8) bool {
    if (std.mem.indexOfAny(u8, target, "?#\\") != null) return false;
    const b = std.Uri.parse(base) catch return false;
    const t = std.Uri.parse(target) catch return false;
    if (!sameOrigin(b, t)) return false;
    const bp = componentText(b.path);
    const tp = componentText(t.path);
    if (!std.mem.startsWith(u8, tp, bp)) return false;
    if (tp.len > bp.len and !std.mem.endsWith(u8, bp, "/") and tp[bp.len] != '/') return false;
    var segments = std.mem.splitScalar(u8, tp, '/');
    while (segments.next()) |s| {
        var buf: [16]u8 = undefined;
        if (s.len > 9) continue; // longer than `%2E%2E` and then some
        @memcpy(buf[0..s.len], s);
        const d = decode(buf[0..s.len]) catch return false;
        if (std.mem.eql(u8, d, ".") or std.mem.eql(u8, d, "..")) return false;
    }
    return true;
}

test "a source's address, and what lies within it" {
    try std.testing.expect(fitForSource("http://nas.local/Video/"));
    try std.testing.expect(fitForSource("https://user:pw@nas:8443/a%20b/"));
    try std.testing.expect(!fitForSource("file:///Users/Shared/"));
    try std.testing.expect(!fitForSource("smb://nas/share/"));
    try std.testing.expect(!fitForSource("http://127.0.0.1:8080/x HTTP/1.1\r\nHost: a\r\n\r\n"));
    try std.testing.expect(!fitForSource("http:///nohost/"));
    try std.testing.expect(!fitForSource("http://nas/a?b"));

    try std.testing.expect(within("http://nas/media/", "http://nas/media/a.mp4"));
    try std.testing.expect(within("http://nas/media", "http://nas/media/a.mp4"));
    try std.testing.expect(within("http://NAS:80/media/", "http://nas/media/a.mp4"));
    try std.testing.expect(!within("http://nas/media", "http://nas/media-evil/a.mp4"));
    try std.testing.expect(!within("http://nas", "http://nas.evil.com/a.mp4"));
    try std.testing.expect(!within("http://nas/media/", "http://nas@evil/media/a.mp4"));
    try std.testing.expect(!within("http://nas/media/", "http://nas:81/media/a.mp4"));
    try std.testing.expect(!within("http://nas/media/", "https://nas/media/a.mp4"));
    try std.testing.expect(!within("http://nas/media/", "http://nas/media/../etc/passwd"));
    try std.testing.expect(!within("http://nas/media/", "http://nas/media/%2e%2E/x"));
    try std.testing.expect(!within("http://nas/media/", "http://nas/media/a.mp4?x"));
}
