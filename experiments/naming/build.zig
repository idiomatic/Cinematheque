const std = @import("std");

pub fn build(b: *std.Build) void {
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    const exe = b.addExecutable(.{ .name = "names", .root_module = module });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Parse an INDEX").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Run the naming fixtures").dependOn(&b.addRunArtifact(tests).step);
}
