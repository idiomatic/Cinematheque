//! Sync over HTTP: the receiver POSTs its version vector to `/sync` and
//! reads the sender's frames (see `replica.writeSync`) from a chunked
//! response.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const replica_ = @import("replica.zig");
const Replica = replica_.Replica;

/// Serves `src` one connection at a time, since it holds one SQLite
/// connection, until `requests` syncs have been answered.
pub fn serve(io: Io, gpa: std.mem.Allocator, src: *Replica, listener: *Io.net.Server, requests: usize) !void {
    var served: usize = 0;
    while (served < requests) {
        const stream = try listener.accept(io);
        defer stream.close(io);
        var in_buf: [16 * 1024]u8 = undefined;
        var out_buf: [64 * 1024]u8 = undefined;
        var reader = stream.reader(io, &in_buf);
        var writer = stream.writer(io, &out_buf);
        var server = http.Server.init(&reader.interface, &writer.interface);
        while (served < requests) {
            var request = server.receiveHead() catch break;
            if (request.head.method != .POST or !std.mem.eql(u8, request.head.target, "/sync")) {
                try request.respond("", .{ .status = .not_found });
                continue;
            }
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var body_buf: [4096]u8 = undefined;
            const body = try request.readerExpectNone(&body_buf).allocRemaining(arena, .limited(1 << 20));
            var vector_reader: Io.Reader = .fixed(body);
            const wanted = try replica_.readVector(arena, &vector_reader);
            var response_buf: [64 * 1024]u8 = undefined;
            var response = try request.respondStreaming(&response_buf, .{ .respond_options = .{
                .extra_headers = &.{.{ .name = "content-type", .value = "application/octet-stream" }},
            } });
            try replica_.writeSync(src, arena, wanted, &response.writer);
            try response.end();
            served += 1;
            if (!request.head.keep_alive) break;
        }
    }
}

/// Pulls from the peer at `url` (e.g., `http://127.0.0.1:8095/sync`).
pub fn pull(arena: std.mem.Allocator, client: *http.Client, dst: *Replica, url: []const u8) !replica_.Stats {
    var vector: Io.Writer.Allocating = .init(arena);
    try replica_.writeVector(&vector.writer, try dst.versionVector(arena));
    var request = try client.request(.POST, try std.Uri.parse(url), .{});
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = vector.written().len };
    var body = try request.sendBodyUnflushed(&.{});
    try body.writer.writeAll(vector.written());
    try body.end();
    try request.connection.?.flush();
    var response = try request.receiveHead(&.{});
    if (response.head.status != .ok) return error.BadStatus;
    var transfer: [64 * 1024]u8 = undefined;
    var stats = try replica_.readSync(dst, response.reader(&transfer));
    stats.wire_bytes += vector.written().len;
    return stats;
}
