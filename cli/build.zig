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

    // A test repository's generator, for test.sh.
    const gen = b.addExecutable(.{ .name = "gen", .root_module = b.createModule(.{
        .root_source_file = b.path("test/gen.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("gen", "Build the test repository's generator").dependOn(&b.addInstallArtifact(gen, .{}).step);
}
