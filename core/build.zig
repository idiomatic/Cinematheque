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

/// The stamp module `version.zig` imports (its version, and what the
/// checkout is), printed by stamp.zig, a tool run on every build: Zig caches
/// configuring, so Git run here would stamp a checkout as it once was.
fn stamp(b: *std.Build) *std.Build.Module {
    const exe = b.addExecutable(.{ .name = "stamp", .root_module = b.createModule(.{
        .root_source_file = b.path("stamp.zig"),
        .target = b.graph.host,
    }) });
    const run = b.addRunArtifact(exe);
    run.addFileArg(b.path("../Version.xcconfig"));
    run.addArg(b.root.joinString(b.allocator, "..") catch @panic("OOM"));
    run.has_side_effects = true;
    return b.createModule(.{ .root_source_file = run.captureStdOut(.{ .basename = "stamp.zig" }) });
}
