const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const sqlite = b.createModule(.{ .root_source_file = b.path("../../core/src/sqlite.zig"), .target = target, .optimize = optimize });
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "sqlite", .module = sqlite }},
    });
    module.linkSystemLibrary("sqlite3", .{});
    const exe = b.addExecutable(.{ .name = "browse", .root_module = module });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Compare facet queries").dependOn(&run.step);
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
}
