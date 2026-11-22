//! A build tool, run on every build (core/build.zig's and cli/build.zig's
//! `stamp`), printing the stamp module that src/version.zig imports:
//!   stamp VERSION_XCCONFIG CHECKOUT
//! `version`, Version.xcconfig's `MARKETING_VERSION`; and `revision`, what
//! the checkout is: `git describe --tags` (lightweight tags too), `-dirty`
//! if a tracked file differs from it (but CHANGELOG.md, whose Unreleased
//! section is kept out of commits), else `unknown`, as with no Git. It runs
//! at make time, not as the build script configures, since Zig caches
//! configuring, which knows nothing of commits.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) return error.Usage;
    const xcconfig = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(4096));
    const version = marketingVersion(xcconfig) orelse return error.NoMarketingVersion;
    const checkout = args[2];

    const described = git(arena, io, &.{ "git", "-C", checkout, "describe", "--tags", "--always", "--abbrev=12" });
    const changed = git(arena, io, &.{ "git", "-C", checkout, "status", "--porcelain", "--untracked-files=no", "--", ":/", ":(top,exclude)CHANGELOG.md" });
    const revision = if (described) |d|
        if (changed != null and changed.?.len > 0) try std.fmt.allocPrint(arena, "{s}-dirty", .{d}) else d
    else
        "unknown";

    var buffer: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buffer);
    try out.interface.print("pub const version = \"{f}\";\npub const revision = \"{f}\";\n", .{ std.zig.fmtString(version), std.zig.fmtString(revision) });
    try out.interface.flush();
}

/// The `MARKETING_VERSION` an xcconfig sets.
fn marketingVersion(text: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.splitScalar(u8, line, '=');
        if (!std.mem.eql(u8, std.mem.trim(u8, parts.first(), " \t"), "MARKETING_VERSION")) continue;
        return std.mem.trim(u8, parts.rest(), " \t\r");
    }
    return null;
}

/// What a Git command printed, trimmed, or null if it failed (or there's no Git).
fn git(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(arena, io, .{ .argv = argv }) catch return null;
    if (!result.term.success()) return null;
    return std.mem.trim(u8, result.stdout, " \r\n");
}
