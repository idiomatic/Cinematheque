//! Plans and runs the transcoder's cheapest path to an MP4 that Apple
//! players accept: probe the input over HTTP with `ffprobe`; if the video
//! plays, remux with `ffmpeg` straight from the repository, converting only
//! audio or subtitles that don't; otherwise copy the input to a cache by
//! resumable range requests and re-encode it with `HandBrakeCLI`. Both
//! tools run as separate processes.
//!
//! Usage: transcode <output dir> <cache dir> <input URL>...

const std = @import("std");
const Io = std.Io;

const Stream = struct {
    index: u32,
    codec_type: []const u8,
    codec_name: []const u8 = "",
    profile: []const u8 = "",
    pix_fmt: []const u8 = "",
    channels: u32 = 0,
};

const Probe = struct { streams: []const Stream };

pub const Action = enum { copy, retag_hvc1, to_aac, to_eac3, to_mov_text, drop, reencode };

pub fn plan(s: Stream) Action {
    const eql = std.mem.eql;
    if (eql(u8, s.codec_type, "video")) {
        const eight_bit = eql(u8, s.pix_fmt, "yuv420p");
        if (eql(u8, s.codec_name, "h264"))
            return if (eight_bit and !eql(u8, s.profile, "High 10")) .copy else .reencode;
        if (eql(u8, s.codec_name, "hevc"))
            return if (eql(u8, s.profile, "Main") or eql(u8, s.profile, "Main 10")) .retag_hvc1 else .reencode;
        return .reencode;
    }
    if (eql(u8, s.codec_type, "audio")) {
        for ([_][]const u8{ "aac", "alac", "ac3", "eac3", "mp3", "flac" }) |ok| if (eql(u8, s.codec_name, ok)) return .copy;
        return if (s.channels > 2) .to_eac3 else .to_aac;
    }
    if (eql(u8, s.codec_type, "subtitle")) {
        for ([_][]const u8{ "subrip", "ass", "webvtt", "mov_text" }) |text| if (eql(u8, s.codec_name, text)) return .to_mov_text;
        return .drop; // image subtitles (PGS, VobSub) need OCR or burning in
    }
    return .drop;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) {
        std.log.err("usage: transcode <output dir> <cache dir> <input URL>...", .{});
        return error.Usage;
    }
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, args[1]);
    try cwd.createDirPath(io, args[2]);
    var client: std.http.Client = .{ .allocator = init.gpa, .io = io };
    defer client.deinit();

    for (args[3..]) |input| {
        const start = Io.Timestamp.now(io, .awake);
        const probe = try probeStreams(io, arena, input);
        const name = try decodedBase(arena, input);
        const output = try std.fmt.allocPrint(arena, "{s}/{s}.mp4", .{ args[1], name[0 .. name.len - std.fs.path.extension(name).len] });

        var reencode = false;
        try out.print("{s}\n", .{name});
        for (probe.streams) |s| {
            const action = plan(s);
            if (action == .reencode) reencode = true;
            try out.print("  #{d} {s} {s} {s}: {t}\n", .{ s.index, s.codec_type, s.codec_name, s.profile, action });
        }
        const how = if (reencode) blk: {
            const cached = try std.fmt.allocPrint(arena, "{s}/{s}", .{ args[2], name });
            const bytes = try download(io, &client, input, cached);
            try out.print("  cached {d:.1} MB\n", .{@as(f64, @floatFromInt(bytes)) / 1e6});
            try handbrake(io, arena, cached, output);
            break :blk "re-encoded by HandBrakeCLI";
        } else blk: {
            try remux(io, arena, input, output, probe.streams);
            break :blk "remuxed by ffmpeg from HTTP";
        };
        const ms = start.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds();

        const result = try probeStreams(io, arena, output);
        try out.print("  {s} in {d} ms; output:", .{ how, ms });
        for (result.streams) |s| {
            const tag = try codecTag(io, arena, output, s.index);
            try out.print(" {s}/{s}", .{ s.codec_name, tag });
        }
        try out.print("; moov first: {}\n", .{try moovFirst(io, output)});
        try out.flush();
    }
}

fn probeStreams(io: Io, arena: std.mem.Allocator, target: []const u8) !Probe {
    const result = try std.process.run(arena, io, .{ .argv = &.{
        "ffprobe", "-v", "error", "-of", "json", "-show_streams", target,
    } });
    if (result.term != .exited or result.term.exited != 0) {
        std.log.err("ffprobe {s}: {s}", .{ target, result.stderr });
        return error.ProbeFailed;
    }
    return std.json.parseFromSliceLeaky(Probe, arena, result.stdout, .{ .ignore_unknown_fields = true });
}

fn codecTag(io: Io, arena: std.mem.Allocator, path: []const u8, index: u32) ![]const u8 {
    const result = try std.process.run(arena, io, .{ .argv = &.{
        "ffprobe",                                                                      "-v", "error", "-select_streams", try std.fmt.allocPrint(arena, "{d}", .{index}),
        "-show_entries", "stream=codec_tag_string", "-of", "default=nw=1:nk=1", path,
    } });
    return std.mem.trim(u8, result.stdout, " \n");
}

fn remux(io: Io, arena: std.mem.Allocator, input: []const u8, output: []const u8, streams: []const Stream) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", input });
    var out_index: u32 = 0;
    for (streams) |s| {
        const action = plan(s);
        if (action == .drop) continue;
        try argv.appendSlice(arena, &.{ "-map", try std.fmt.allocPrint(arena, "0:{d}", .{s.index}) });
        const spec = try std.fmt.allocPrint(arena, "{d}", .{out_index});
        out_index += 1;
        const codec = try std.mem.concat(arena, u8, &.{ "-c:", spec });
        switch (action) {
            .copy => try argv.appendSlice(arena, &.{ codec, "copy" }),
            .retag_hvc1 => try argv.appendSlice(arena, &.{ codec, "copy", try std.mem.concat(arena, u8, &.{ "-tag:", spec }), "hvc1" }),
            .to_aac => try argv.appendSlice(arena, &.{ codec, "aac", try std.mem.concat(arena, u8, &.{ "-b:", spec }), "192k" }),
            .to_eac3 => try argv.appendSlice(arena, &.{ codec, "eac3", try std.mem.concat(arena, u8, &.{ "-b:", spec }), "640k" }),
            .to_mov_text => try argv.appendSlice(arena, &.{ codec, "mov_text" }),
            .drop, .reencode => unreachable,
        }
    }
    try argv.appendSlice(arena, &.{ "-movflags", "+faststart", output });
    try runChecked(io, arena, argv.items);
}

fn handbrake(io: Io, arena: std.mem.Allocator, input: []const u8, output: []const u8) !void {
    try runChecked(io, arena, &.{
        "HandBrakeCLI", "--preset", "Apple 1080p30 Surround", "--optimize", "--json", "-i", input, "-o", output,
    });
}

fn runChecked(io: Io, arena: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try std.process.run(arena, io, .{ .argv = argv });
    if (result.term != .exited or result.term.exited != 0) {
        std.log.err("{s} failed: {s}", .{ argv[0], result.stderr[result.stderr.len -| 2000..] });
        return error.ToolFailed;
    }
}

/// Copies `source` to `path`, resuming a partial copy with a range request.
fn download(io: Io, client: *std.http.Client, source: []const u8, path: []const u8) !u64 {
    const cwd = Io.Dir.cwd();
    const have: u64 = if (cwd.statFile(io, path, .{})) |s| s.size else |_| 0;
    var range_buf: [48]u8 = undefined;
    const range = try std.fmt.bufPrint(&range_buf, "bytes={d}-", .{have});
    var request = try client.request(.GET, try std.Uri.parse(source), .{
        .extra_headers = &.{.{ .name = "range", .value = range }},
    });
    defer request.deinit();
    try request.sendBodiless();
    var response = try request.receiveHead(&.{});
    switch (response.head.status) {
        .partial_content => {},
        .range_not_satisfiable => return have, // already complete
        .ok => if (have != 0) return error.RangesUnsupported,
        else => return error.BadStatus,
    }
    const file = if (have == 0) try cwd.createFile(io, path, .{}) else try cwd.openFile(io, path, .{ .mode = .write_only });
    defer file.close(io);
    var file_buf: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &file_buf);
    try writer.seekTo(have);
    var transfer: [64 * 1024]u8 = undefined;
    const copied = try response.reader(&transfer).streamRemaining(&writer.interface);
    try writer.interface.flush();
    return have + copied;
}

fn decodedBase(arena: std.mem.Allocator, target: []const u8) ![]const u8 {
    const base = try arena.dupe(u8, target[(std.mem.lastIndexOfScalar(u8, target, '/') orelse return error.BadUrl) + 1 ..]);
    return std.Uri.percentDecodeInPlace(base);
}

/// Whether the MP4's index (`moov`) precedes its media (`mdat`), as
/// progressive playback needs.
fn moovFirst(io: Io, path: []const u8) !bool {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var offset: u64 = 0;
    while (true) {
        var head: [16]u8 = undefined;
        if (try file.readPositionalAll(io, &head, offset) < 8) return false;
        var size: u64 = std.mem.readInt(u32, head[0..4], .big);
        if (size == 1) size = std.mem.readInt(u64, head[8..16], .big);
        if (std.mem.eql(u8, head[4..8], "moov")) return true;
        if (std.mem.eql(u8, head[4..8], "mdat") or size < 8) return false;
        offset += size;
    }
}

test plan {
    try std.testing.expectEqual(Action.copy, plan(.{ .index = 0, .codec_type = "video", .codec_name = "h264", .profile = "High", .pix_fmt = "yuv420p" }));
    try std.testing.expectEqual(Action.reencode, plan(.{ .index = 0, .codec_type = "video", .codec_name = "h264", .profile = "High 10", .pix_fmt = "yuv420p10le" }));
    try std.testing.expectEqual(Action.retag_hvc1, plan(.{ .index = 0, .codec_type = "video", .codec_name = "hevc", .profile = "Main 10" }));
    try std.testing.expectEqual(Action.reencode, plan(.{ .index = 0, .codec_type = "video", .codec_name = "mpeg2video" }));
    try std.testing.expectEqual(Action.to_eac3, plan(.{ .index = 1, .codec_type = "audio", .codec_name = "dts", .channels = 6 }));
    try std.testing.expectEqual(Action.to_aac, plan(.{ .index = 1, .codec_type = "audio", .codec_name = "truehd", .channels = 2 }));
    try std.testing.expectEqual(Action.to_mov_text, plan(.{ .index = 2, .codec_type = "subtitle", .codec_name = "subrip" }));
    try std.testing.expectEqual(Action.drop, plan(.{ .index = 3, .codec_type = "subtitle", .codec_name = "hdmv_pgs_subtitle" }));
}
