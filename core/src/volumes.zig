//! The computer's volumes: whether they've changed (a drive plugged in or
//! unplugged, a share mounted), for a server whose media holds them to
//! look again at once rather than at its next crawl.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

/// A digest of the mount table: changes as a volume mounts or unmounts.
/// One small read, however many volumes (`/proc/self/mountinfo` on Linux,
/// `getfsstat` on macOS); 0 where it can't be told.
pub fn signature(io: Io, gpa: std.mem.Allocator) u64 {
    switch (builtin.os.tag) {
        .linux => {
            const text = Io.Dir.cwd().readFileAlloc(io, "/proc/self/mountinfo", gpa, .limited(4 << 20)) catch return 0;
            defer gpa.free(text);
            return std.hash.Wyhash.hash(0, text);
        },
        .macos => {
            const count = getfsstat(null, 0, mnt_nowait);
            if (count <= 0) return 0;
            // Room for a few more, as one may mount between the calls.
            const all = gpa.alloc(Statfs, @intCast(count + 4)) catch return 0;
            defer gpa.free(all);
            const got = getfsstat(all.ptr, @intCast(all.len * @sizeOf(Statfs)), mnt_nowait);
            if (got <= 0) return 0;
            var h = std.hash.Wyhash.init(0);
            for (all[0..@intCast(got)]) |*v| {
                h.update(std.mem.sliceTo(&v.f_mntonname, 0));
                h.update(std.mem.sliceTo(&v.f_mntfromname, 0));
            }
            return h.final();
        },
        else => return 0,
    }
}

/// macOS's `struct statfs` (64-bit inodes).
pub const Statfs = extern struct {
    f_bsize: u32,
    f_iosize: i32,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_owner: u32,
    f_type: u32,
    f_flags: u32,
    f_fssubtype: u32,
    f_fstypename: [16]u8,
    f_mntonname: [1024]u8,
    f_mntfromname: [1024]u8,
    f_flags_ext: u32,
    f_reserved: [7]u32,
};
pub const statfs = @extern(*const fn ([*:0]const u8, *Statfs) callconv(.c) c_int, .{
    .name = if (builtin.cpu.arch == .x86_64) "statfs$INODE64" else "statfs",
});
const getfsstat = @extern(*const fn (?[*]Statfs, c_int, c_int) callconv(.c) c_int, .{
    .name = if (builtin.cpu.arch == .x86_64) "getfsstat$INODE64" else "getfsstat",
});
/// Without asking each file system afresh, which a hung share would hold.
const mnt_nowait = 2;

test "the mount table has a signature, the same while nothing mounts" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    const a = signature(io, std.testing.allocator);
    try std.testing.expect(a != 0);
    try std.testing.expectEqual(a, signature(io, std.testing.allocator));
}
