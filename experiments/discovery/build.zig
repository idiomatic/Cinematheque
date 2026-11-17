const std = @import("std");

pub fn build(b: *std.Build) void {
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .link_libc = true,
    });
    // On Linux, Avahi's compatibility library provides the same API.
    if (module.resolved_target.?.result.os.tag == .linux) module.linkSystemLibrary("dns_sd", .{});
    const exe = b.addExecutable(.{ .name = "discover", .root_module = module });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Advertise and browse").dependOn(&run.step);
}
