//! What this build is: which app (the command-line app, or the Apple app
//! for macOS, tvOS, or iOS), its version (`-Dversion`, as its builder
//! gives it), what it was built from (`git describe`, as the build found
//! it), how it was optimized, and by which Zig, so a device's report of a
//! problem says which code it ran. Served at `/version`.

const std = @import("std");
const builtin = @import("builtin");

pub const Info = struct {
    app: []const u8,
    version: []const u8,
    revision: []const u8,
    mode: []const u8,
    zig: []const u8,
};

pub const info: Info = .{
    .app = app,
    .version = @import("stamp").version,
    .revision = @import("stamp").revision,
    .mode = @tagName(builtin.mode),
    .zig = builtin.zig_version_string,
};

/// Which app this is: as the build's root names it (the command-line
/// app's `app_name`), else the Apple app, by the platform it's built for.
const app: []const u8 = if (@hasDecl(@import("root"), "app_name")) @import("root").app_name else switch (builtin.os.tag) {
    .macos => "macOS app",
    .tvos => "tvOS app",
    .ios => "iOS app",
    else => @tagName(builtin.os.tag) ++ " app",
};

/// `info` as JSON.
pub fn json(gpa: std.mem.Allocator) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, info, .{});
}

test json {
    const text = try json(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"app\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"mode\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"revision\":\"") != null);
}
