//! What kind of device one is ("iPhone 13 mini"), shown under its name as
//! it offers to be added, so two named alike (or not yet named) are told
//! apart. Apple's devices tell apps only an identifier (`iPhone14,4`), so
//! its name is looked up here, one copy for every player.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// What to show for `model`: an Apple identifier's name, else, for one
/// newer than this table, its family's ("iPhone"); anything else (a Mac's
/// own name, as "MacBook Pro (14-inch, 2021)", or a PC's) as it is.
pub fn shown(model: []const u8) []const u8 {
    if (names.get(model)) |name| return name;
    const family = identifierFamily(model) orelse return model;
    return families.get(family) orelse model;
}

/// The family of an Apple identifier (`iPhone` of `iPhone14,4`), if
/// `model` is one: letters, then numbers either side of a comma.
fn identifierFamily(model: []const u8) ?[]const u8 {
    const letters = for (model, 0..) |c, i| {
        if (!std.ascii.isAlphabetic(c)) break i;
    } else return null;
    const rest = model[letters..];
    const comma = std.mem.indexOfScalar(u8, rest, ',') orelse return null;
    if (letters == 0 or comma == 0 or comma == rest.len - 1) return null;
    for (rest[0..comma]) |c| if (!std.ascii.isDigit(c)) return null;
    for (rest[comma + 1 ..]) |c| if (!std.ascii.isDigit(c)) return null;
    return model[0..letters];
}

/// This computer's model, for the command-line app to offer: a Mac's
/// family, by its identifier (`hw.model`); a PC's product name, as its
/// firmware gives it (DMI), unless that's a placeholder; else none.
pub fn this(io: Io, arena: std.mem.Allocator) ?[]const u8 {
    if (builtin.os.tag.isDarwin()) {
        var buffer: [64]u8 = undefined;
        var len: usize = buffer.len;
        if (std.c.sysctlbyname("hw.model", &buffer, &len, null, 0) != 0 or len == 0) return null;
        return arena.dupe(u8, shown(std.mem.sliceTo(buffer[0..len], 0))) catch null;
    }
    if (builtin.os.tag != .linux) return null;
    const text = Io.Dir.cwd().readFileAlloc(io, "/sys/devices/virtual/dmi/id/product_name", arena, .limited(256)) catch return null;
    const name = std.mem.trim(u8, text, " \t\r\n");
    for (placeholders) |p| if (std.ascii.eqlIgnoreCase(name, p)) return null;
    return if (name.len == 0) null else name;
}

/// What firmware says when its maker didn't fill a product name in.
const placeholders = [_][]const u8{
    "To be filled by O.E.M.",
    "System Product Name",
    "Default string",
    "Not Applicable",
    "None",
};

/// Families, for identifiers newer than the table below.
const families: std.StaticStringMap([]const u8) = .initComptime(.{
    .{ "iPhone", "iPhone" },
    .{ "iPad", "iPad" },
    .{ "iPod", "iPod touch" },
    .{ "AppleTV", "Apple TV" },
    .{ "MacBookPro", "MacBook Pro" },
    .{ "MacBookAir", "MacBook Air" },
    .{ "MacBook", "MacBook" },
    .{ "Macmini", "Mac mini" },
    .{ "MacPro", "Mac Pro" },
    .{ "iMacPro", "iMac Pro" },
    .{ "iMac", "iMac" },
    .{ "Mac", "Mac" },
    .{ "RealityDevice", "Apple Vision Pro" },
});

/// Identifiers of devices that run the players (iOS 18 and tvOS 18 or
/// later), and the reference devices, by name.
const names: std.StaticStringMap([]const u8) = .initComptime(.{
    .{ "iPhone11,2", "iPhone XS" },
    .{ "iPhone11,4", "iPhone XS Max" },
    .{ "iPhone11,6", "iPhone XS Max" },
    .{ "iPhone11,8", "iPhone XR" },
    .{ "iPhone12,1", "iPhone 11" },
    .{ "iPhone12,3", "iPhone 11 Pro" },
    .{ "iPhone12,5", "iPhone 11 Pro Max" },
    .{ "iPhone12,8", "iPhone SE (2nd generation)" },
    .{ "iPhone13,1", "iPhone 12 mini" },
    .{ "iPhone13,2", "iPhone 12" },
    .{ "iPhone13,3", "iPhone 12 Pro" },
    .{ "iPhone13,4", "iPhone 12 Pro Max" },
    .{ "iPhone14,2", "iPhone 13 Pro" },
    .{ "iPhone14,3", "iPhone 13 Pro Max" },
    .{ "iPhone14,4", "iPhone 13 mini" },
    .{ "iPhone14,5", "iPhone 13" },
    .{ "iPhone14,6", "iPhone SE (3rd generation)" },
    .{ "iPhone14,7", "iPhone 14" },
    .{ "iPhone14,8", "iPhone 14 Plus" },
    .{ "iPhone15,2", "iPhone 14 Pro" },
    .{ "iPhone15,3", "iPhone 14 Pro Max" },
    .{ "iPhone15,4", "iPhone 15" },
    .{ "iPhone15,5", "iPhone 15 Plus" },
    .{ "iPhone16,1", "iPhone 15 Pro" },
    .{ "iPhone16,2", "iPhone 15 Pro Max" },
    .{ "iPhone17,1", "iPhone 16 Pro" },
    .{ "iPhone17,2", "iPhone 16 Pro Max" },
    .{ "iPhone17,3", "iPhone 16" },
    .{ "iPhone17,4", "iPhone 16 Plus" },
    .{ "iPhone17,5", "iPhone 16e" },
    .{ "iPhone18,1", "iPhone 17 Pro" },
    .{ "iPhone18,2", "iPhone 17 Pro Max" },
    .{ "iPhone18,3", "iPhone 17" },
    .{ "iPhone18,4", "iPhone Air" },
    .{ "iPod9,1", "iPod touch (7th generation)" },
    .{ "iPad14,1", "iPad mini (6th generation)" },
    .{ "iPad14,2", "iPad mini (6th generation)" },
    .{ "iPad15,7", "iPad (A16)" },
    .{ "iPad15,8", "iPad (A16)" },
    .{ "AppleTV5,3", "Apple TV HD" },
    .{ "AppleTV6,2", "Apple TV 4K" },
    .{ "AppleTV11,1", "Apple TV 4K (2nd generation)" },
    .{ "AppleTV14,1", "Apple TV 4K (3rd generation)" },
});

test "shown" {
    try std.testing.expectEqualStrings("iPhone 13 mini", shown("iPhone14,4"));
    try std.testing.expectEqualStrings("Apple TV 4K (3rd generation)", shown("AppleTV14,1"));
    // Newer than the table: its family.
    try std.testing.expectEqualStrings("iPhone", shown("iPhone99,1"));
    try std.testing.expectEqualStrings("MacBook Pro", shown("MacBookPro18,3"));
    try std.testing.expectEqualStrings("Mac", shown("Mac14,2"));
    // Not an identifier: as it is.
    try std.testing.expectEqualStrings("MacBook Pro (14-inch, 2021)", shown("MacBook Pro (14-inch, 2021)"));
    try std.testing.expectEqualStrings("ThinkPad X1", shown("ThinkPad X1"));
    try std.testing.expectEqualStrings("Unknown9,1", shown("Unknown9,1"));
}
