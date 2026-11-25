//! Requests to other hosts, none following a redirect (it could lead
//! anywhere the server likes): a byte range, a body sent, and which
//! failures say only that a host is out of reach.

const std = @import("std");
const http = std.http;

pub const Ranged = struct {
    status: http.Status,
    /// The whole file's, as its `Content-Range` says.
    size: ?u64 = null,
    /// Read for `206` or `200` up to their limits.
    body: []const u8 = &.{},
};

/// How much of a body to read: of the range, and of a whole file sent in
/// its place (none, if 0).
pub const Limits = struct { partial: usize, whole: usize };

/// `length` bytes of `uri` from `offset`.
pub fn getRange(arena: std.mem.Allocator, client: *http.Client, uri: std.Uri, offset: u64, length: u64, limits: Limits) !Ranged {
    if (length == 0) return error.BadRange;
    const last = std.math.add(u64, offset, length - 1) catch return error.BadRange;
    var range_buf: [64]u8 = undefined;
    const range = try std.fmt.bufPrint(&range_buf, "bytes={d}-{d}", .{ offset, last });
    var request = try client.request(.GET, uri, .{ .redirect_behavior = .not_allowed, .extra_headers = &.{.{ .name = "range", .value = range }} });
    defer request.deinit();
    try request.sendBodiless();
    var response = try request.receiveHead(&.{});
    var out: Ranged = .{ .status = response.head.status };
    var headers = response.head.iterateHeaders();
    while (headers.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "content-range")) {
        const slash = std.mem.lastIndexOfScalar(u8, h.value, '/') orelse continue;
        out.size = std.fmt.parseInt(u64, h.value[slash + 1 ..], 10) catch null;
    };
    const limit = switch (out.status) {
        .partial_content => limits.partial,
        .ok => limits.whole,
        else => 0,
    };
    if (limit == 0) return out;
    var transfer: [64 * 1024]u8 = undefined;
    out.body = try response.reader(&transfer).allocRemaining(arena, .limited(limit));
    return out;
}

/// Sends `request` (made with `.redirect_behavior = .not_allowed`) its
/// whole body.
pub fn send(request: *http.Client.Request, body: []const u8) !void {
    request.transfer_encoding = .{ .content_length = body.len };
    var sending = try request.sendBodyUnflushed(&.{});
    try sending.writer.writeAll(body);
    try sending.end();
    try request.connection.?.flush();
}

/// A response's head, for `deadline.within` to wait on.
pub fn receiveHead(request: *http.Client.Request) !http.Client.Response {
    return request.receiveHead(&.{});
}

/// Whether `err` says only that a host couldn't be reached, for now.
pub fn unreachable_(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused, error.ConnectionResetByPeer, error.ConnectionTimedOut, error.NetworkUnreachable, error.HostUnreachable, error.TemporaryNameServerFailure, error.UnknownHostName, error.NameServerFailure, error.Timeout => true,
        else => false,
    };
}
