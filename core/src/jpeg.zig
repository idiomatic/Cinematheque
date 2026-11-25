//! A JPEG's dimensions, from its frame header (SOF), for a cover's shape
//! before players load it.

const std = @import("std");

pub const Size = struct { width: u16, height: u16 };

/// `bytes`' width and height, as its first frame header declares them.
pub fn size(bytes: []const u8) error{ NotJpeg, Corrupt }!Size {
    if (bytes.len < 4 or bytes[0] != 0xff or bytes[1] != 0xd8) return error.NotJpeg;
    var pos: usize = 2;
    while (pos + 4 <= bytes.len) {
        if (bytes[pos] != 0xff) return error.Corrupt;
        const marker = bytes[pos + 1];
        if (marker == 0xff) {
            pos += 1;
            continue;
        }
        const len = std.mem.readInt(u16, bytes[pos + 2 ..][0..2], .big);
        if (len < 2 or pos + 2 + len > bytes.len) return error.Corrupt;
        const seg = bytes[pos + 4 .. pos + 2 + len];
        pos += 2 + len;
        // SOF0 to SOF15, but DHT (c4), JPG (c8), and DAC (cc).
        if (marker >= 0xc0 and marker <= 0xcf and marker != 0xc4 and marker != 0xc8 and marker != 0xcc) {
            if (seg.len < 5) return error.Corrupt;
            const s: Size = .{ .height = std.mem.readInt(u16, seg[1..3], .big), .width = std.mem.readInt(u16, seg[3..5], .big) };
            if (s.width == 0 or s.height == 0) return error.Corrupt;
            return s;
        }
        if (marker == 0xda or marker == 0xd9) break;
    }
    return error.Corrupt;
}

test "a JPEG's size, baseline or progressive" {
    // ffmpeg's test pattern, 80×120, by cjpeg (the second with -progressive).
    try std.testing.expectEqual(Size{ .width = 80, .height = 120 }, try size(@embedFile("testdata/pattern.jpg")));
    try std.testing.expectEqual(Size{ .width = 80, .height = 120 }, try size(@embedFile("testdata/pattern-progressive.jpg")));
    try std.testing.expectError(error.NotJpeg, size("\x89PNG\r\n"));
    try std.testing.expectError(error.Corrupt, size("\xff\xd8\xff\xc0\x00\x11\x08\x00\x00"));
}
