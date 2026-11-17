const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.linkSystemLibrary("sqlite3", .{});

    const exe = b.addExecutable(.{ .name = "crdt-bench", .root_module = module });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the benchmark").dependOn(&run.step);

    const sig_module = b.createModule(.{
        .root_source_file = b.path("src/sigbench.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sig_exe = b.addExecutable(.{ .name = "crdt-sigbench", .root_module = sig_module });
    b.installArtifact(sig_exe);
    const sig_run = b.addRunArtifact(sig_exe);
    sig_run.addPassthruArgs();
    b.step("sigbench", "Compare signing schemes").dependOn(&sig_run.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = sig_module })).step);
}
