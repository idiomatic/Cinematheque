//! Runs the peer in the background on macOS, as two launch agents: one that
//! keeps `serve` running, and one that runs `refresh` (crawl, then sync with
//! peers found) every hour.

const std = @import("std");
const Io = std.Io;

pub const label_prefix = "com.rbrian.cinematheque";

pub const Agent = struct {
    label: []const u8,
    plist: []const u8,
};

/// The agents' launchd property lists, for `exe` acting on the peer home
/// `peer_home`, serving on `port` if given, else on the default or a free one.
pub fn agents(arena: std.mem.Allocator, exe: []const u8, peer_home: []const u8, home: []const u8, port: ?u16) ![2]Agent {
    const logs = try std.fmt.allocPrint(arena, "{s}/Library/Logs/Cinematheque", .{home});
    const serve: []const []const u8 = if (port) |p|
        &.{ exe, "--home", peer_home, "serve", "--port", try std.fmt.allocPrint(arena, "{d}", .{p}) }
    else
        &.{ exe, "--home", peer_home, "serve" };
    return .{
        .{
            .label = label_prefix ++ ".serve",
            .plist = try plist(arena, label_prefix ++ ".serve", serve, logs, "serve", .keep_alive),
        },
        .{
            .label = label_prefix ++ ".refresh",
            .plist = try plist(arena, label_prefix ++ ".refresh", &.{ exe, "--home", peer_home, "refresh" }, logs, "refresh", .hourly),
        },
    };
}

fn plist(arena: std.mem.Allocator, label: []const u8, arguments: []const []const u8, logs: []const u8, log: []const u8, run: enum { keep_alive, hourly }) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" ++
        "<plist version=\"1.0\">\n<dict>\n\t<key>Label</key>\n");
    try out.print(arena, "\t<string>{f}</string>\n\t<key>ProgramArguments</key>\n\t<array>\n", .{escaped(label)});
    for (arguments) |a| try out.print(arena, "\t\t<string>{f}</string>\n", .{escaped(a)});
    try out.appendSlice(arena, "\t</array>\n\t<key>RunAtLoad</key>\n\t<true/>\n");
    switch (run) {
        .keep_alive => try out.appendSlice(arena, "\t<key>KeepAlive</key>\n\t<true/>\n"),
        .hourly => try out.appendSlice(arena, "\t<key>StartInterval</key>\n\t<integer>3600</integer>\n"),
    }
    try out.print(arena, "\t<key>StandardOutPath</key>\n\t<string>{f}/{s}.log</string>\n", .{ escaped(logs), log });
    try out.print(arena, "\t<key>StandardErrorPath</key>\n\t<string>{f}/{s}.log</string>\n", .{ escaped(logs), log });
    try out.appendSlice(arena, "\t<key>ProcessType</key>\n\t<string>Background</string>\n</dict>\n</plist>\n");
    return out.items;
}

const Escaped = struct {
    text: []const u8,

    pub fn format(e: Escaped, w: *Io.Writer) Io.Writer.Error!void {
        for (e.text) |c| switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            else => try w.writeByte(c),
        };
    }
};

fn escaped(text: []const u8) Escaped {
    return .{ .text = text };
}

pub fn install(io: Io, arena: std.mem.Allocator, home: []const u8, list: [2]Agent) !void {
    const cwd = Io.Dir.cwd();
    const dir = try std.fmt.allocPrint(arena, "{s}/Library/LaunchAgents", .{home});
    try cwd.createDirPath(io, dir);
    try cwd.createDirPath(io, try std.fmt.allocPrint(arena, "{s}/Library/Logs/Cinematheque", .{home}));
    const domain = try std.fmt.allocPrint(arena, "gui/{d}", .{std.c.getuid()});
    for (list) |a| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}.plist", .{ dir, a.label });
        // Replace a running one.
        _ = std.process.run(arena, io, .{ .argv = &.{ "launchctl", "bootout", try std.fmt.allocPrint(arena, "{s}/{s}", .{ domain, a.label }) } }) catch {};
        try cwd.writeFile(io, .{ .sub_path = path, .data = a.plist });
        const result = try std.process.run(arena, io, .{ .argv = &.{ "launchctl", "bootstrap", domain, path } });
        if (result.term != .exited or result.term.exited != 0) {
            std.log.err("launchctl bootstrap {s}: {s}", .{ path, result.stderr });
            return error.LaunchctlFailed;
        }
    }
}

pub fn uninstall(io: Io, arena: std.mem.Allocator, home: []const u8) !void {
    const domain = try std.fmt.allocPrint(arena, "gui/{d}", .{std.c.getuid()});
    for ([_][]const u8{ label_prefix ++ ".serve", label_prefix ++ ".refresh" }) |label| {
        _ = std.process.run(arena, io, .{ .argv = &.{ "launchctl", "bootout", try std.fmt.allocPrint(arena, "{s}/{s}", .{ domain, label }) } }) catch {};
        Io.Dir.cwd().deleteFile(io, try std.fmt.allocPrint(arena, "{s}/Library/LaunchAgents/{s}.plist", .{ home, label })) catch {};
    }
}
