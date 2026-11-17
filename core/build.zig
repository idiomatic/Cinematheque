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
    capi.bundle_compiler_rt = true;
    b.installArtifact(capi);
    b.installFile("include/cinematheque.h", "include/cinematheque.h");
    // Its Swift module (`import CCinematheque`), for Apple players.
    b.installFile("include/module.modulemap", "include/module.modulemap");

    const tests = b.addTest(.{ .root_module = core });
    b.step("test", "Run the core's unit tests").dependOn(&b.addRunArtifact(tests).step);
}
