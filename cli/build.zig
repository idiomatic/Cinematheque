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

/// The stamp module the core's `version.zig` imports, as core/build.zig
/// makes it: printed by the core's stamp.zig, a tool run on every build, as
/// Zig caches configuring, so Git run here would stamp a checkout as it once
/// was.
fn stamp(b: *std.Build) *std.Build.Module {
    const exe = b.addExecutable(.{ .name = "stamp", .root_module = b.createModule(.{
        .root_source_file = b.path("../core/stamp.zig"),
        .target = b.graph.host,
    }) });
    const run = b.addRunArtifact(exe);
    // The project's version, apple/Version.xcconfig's MARKETING_VERSION,
    // read as it builds, not as this configures (cached), so a new one's
    // seen.
    const sed = b.addSystemCommand(&.{ "sed", "-n", "s/^[[:space:]]*MARKETING_VERSION[[:space:]]*=[[:space:]]*\\([^[:space:]]*\\).*/\\1/p" });
    sed.addFileArg(b.path("../apple/Version.xcconfig"));
    run.addFileArg(sed.captureStdOut(.{ .basename = "version" }));
    run.addArg(b.root.joinString(b.allocator, "..") catch @panic("OOM"));
    run.has_side_effects = true;
    return b.createModule(.{ .root_source_file = run.captureStdOut(.{ .basename = "stamp.zig" }) });
}
