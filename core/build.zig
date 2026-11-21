const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core = b.addModule("core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const version = stamp(b);
    core.addImport("stamp", version);
    core.linkSystemLibrary("sqlite3", .{});
    // On Linux, Avahi's compatibility library provides DNS-SD.
    if (target.result.os.tag == .linux) core.linkSystemLibrary("dns_sd", .{});

    // A static library with a C interface (include/cinematheque.h), for
    // apps in other languages; they link SQLite themselves.
    const capi = b.addLibrary(.{
        .name = "cinematheque",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    capi.root_module.addImport("stamp", version);
    capi.bundle_compiler_rt = true;
    b.installArtifact(capi);
    b.installFile("include/cinematheque.h", "include/cinematheque.h");
    // Its Swift module (`import CCinematheque`), for Apple players.
    b.installFile("include/module.modulemap", "include/module.modulemap");

    const tests = b.addTest(.{ .root_module = core });
    b.step("test", "Run the core's unit tests").dependOn(&b.addRunArtifact(tests).step);
}

/// What this build is built from, for `version.zig`: `git describe` of the
/// checkout (the commit, until there are tags), `-dirty` if a tracked file
/// differs from it (but CHANGELOG.md, whose Unreleased section is kept out
/// of commits), else `unknown`, as with no Git.
fn stamp(b: *std.Build) *std.Build.Module {
    const options = b.addOptions();
    var code: u8 = 0;
    const root = b.root.toString(b.allocator) catch @panic("OOM");
    const described = b.runAllowFail(&.{ "git", "-C", root, "describe", "--always", "--abbrev=12" }, &code, .ignore) catch "unknown";
    const changed = b.runAllowFail(&.{ "git", "-C", root, "status", "--porcelain", "--untracked-files=no", "--", ":/", ":(top,exclude)CHANGELOG.md" }, &code, .ignore) catch "";
    const version = std.mem.trim(u8, described, " \n");
    options.addOption([]const u8, "version", if (changed.len > 0) b.fmt("{s}-dirty", .{version}) else version);
    return options.createModule();
}
