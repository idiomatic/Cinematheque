const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core = b.createModule(.{
        .root_source_file = b.path("../core/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core.addImport("stamp", stamp(b));
    core.linkSystemLibrary("sqlite3", .{});
    if (target.result.os.tag == .linux) core.linkSystemLibrary("dns_sd", .{});

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });
    const exe = b.addExecutable(.{ .name = "cinematheque", .root_module = module });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the command-line app").dependOn(&run.step);

    // The app's own unit tests (the web client's, say); the core's are its own.
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/web.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    }) });
    b.step("test", "Run the command-line app's unit tests").dependOn(&b.addRunArtifact(tests).step);

    // A test repository's generator, for test.sh.
    const gen = b.addExecutable(.{ .name = "gen", .root_module = b.createModule(.{
        .root_source_file = b.path("test/gen.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("gen", "Build the test repository's generator").dependOn(&b.addInstallArtifact(gen, .{}).step);
}

/// What this build is built from, for the core's `version.zig`, as
/// core/build.zig stamps it: `git describe` of the
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
