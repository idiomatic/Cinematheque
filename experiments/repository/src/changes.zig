//! Tells what changed between two crawls: files that vanished and
//! appeared are matched as moves by size and modification time (a rename
//! keeps both), breaking ties by the longest shared name suffix; the rest
//! are deletions and additions.

const std = @import("std");
const crawl = @import("crawl.zig");
const url = @import("url.zig");

pub const Change = struct {
    old: ?[]const u8,
    new: ?[]const u8,
};

const Key = struct { size: u64, mtime: []const u8 };

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: Key) u64 {
        return std.hash.Wyhash.hash(k.size, k.mtime);
    }
    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return a.size == b.size and std.mem.eql(u8, a.mtime, b.mtime);
    }
};

pub const Report = struct {
    changes: []const Change,
    /// Vanished files whose size and time matched more than one new file.
    ambiguous: usize,
};

pub fn diff(arena: std.mem.Allocator, old: []const crawl.Entry, new: []const crawl.Entry) !Report {
    var new_urls: std.StringHashMapUnmanaged(void) = .empty;
    for (new) |e| if (!e.is_dir) try new_urls.put(arena, e.url, {});
    var old_urls: std.StringHashMapUnmanaged(void) = .empty;
    for (old) |e| if (!e.is_dir) try old_urls.put(arena, e.url, {});

    var appeared: std.HashMapUnmanaged(Key, std.ArrayList(usize), KeyContext, 80) = .empty;
    for (new, 0..) |e, i| {
        if (e.is_dir or old_urls.contains(e.url)) continue;
        const gop = try appeared.getOrPut(arena, .{ .size = e.size, .mtime = e.mtime });
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, i);
    }
    var taken = try std.DynamicBitSetUnmanaged.initEmpty(arena, new.len);
    var changes: std.ArrayList(Change) = .empty;
    var ambiguous: usize = 0;
    for (old) |e| {
        if (e.is_dir or new_urls.contains(e.url)) continue;
        var best: ?usize = null;
        var best_score: usize = 0;
        var candidates: usize = 0;
        if (e.mtime.len > 0) if (appeared.get(.{ .size = e.size, .mtime = e.mtime })) |list| {
            for (list.items) |i| {
                if (taken.isSet(i)) continue;
                candidates += 1;
                const score = sharedSuffix(e.url, new[i].url);
                if (best == null or score > best_score) {
                    best = i;
                    best_score = score;
                }
            }
        };
        if (candidates > 1) ambiguous += 1;
        if (best) |i| {
            taken.set(i);
            try changes.append(arena, .{ .old = e.url, .new = new[i].url });
        } else try changes.append(arena, .{ .old = e.url, .new = null });
    }
    for (new, 0..) |e, i| {
        if (e.is_dir or old_urls.contains(e.url) or taken.isSet(i)) continue;
        try changes.append(arena, .{ .old = null, .new = e.url });
    }
    return .{ .changes = changes.items, .ambiguous = ambiguous };
}

fn sharedSuffix(a: []const u8, b: []const u8) usize {
    var n: usize = 0;
    while (n < a.len and n < b.len and a[a.len - 1 - n] == b[b.len - 1 - n]) n += 1;
    return n;
}

/// A crawl URL as a path relative to `base`, percent-decoded.
pub fn relative(arena: std.mem.Allocator, base: []const u8, target: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, target, base)) return error.OutsideBase;
    return url.decode(try arena.dupe(u8, target[base.len..]));
}
