//! The library's domain on top of the replica: keys derived from titles'
//! parsed identities, sources and their layouts, copies ingested
//! from crawls, and progress.
//!
//! Keys:
//! * `t/<kind>/<title>/<year>`: a title; kind `m` (movie) or `s` (series),
//!   title normalized, year or `-`. Fields `name`, `year`.
//! * below a movie, `/v/<edition>` (`-` for none), then `/p/<part>` if any;
//!   below a series, `/e/s03e17` (`-e18` for a range), then `/v/<edition>`
//!   for a version other than the plain one, then `/p/<part>`.
//! * below either, `/r/<quality>`, named by the source or else by the
//!   file's name, or `-` if unknown: field `held:<source>` is the
//!   source's path, size, and modification time, tab-separated, or
//!   empty once no longer held.
//! * `r/<source>`: fields `url`, `quality` (its files' quality, or
//!   empty if unknown), `skip` (the prefix of names to skip), and
//!   `absent:<directory>` (when it was noticed, in milliseconds), for each
//!   directory that held files and lists none now, its copies kept.
//! * `u/<path>`: files that didn't parse, with `held:<source>`.
//! * `p/<person>/<item key>`: a person's progress in an item (a version,
//!   episode, or part), private to that person's devices: fields `position`
//!   and `duration` (milliseconds) and `watched` (`1` or `0`).

const std = @import("std");
const Io = std.Io;
const ascii = std.ascii;
const Replica = @import("replica.zig").Replica;
const crawl = @import("crawl.zig");
const naming = @import("naming.zig");
const url = @import("url.zig");
const Blake3 = std.crypto.hash.Blake3;

pub const Layout = struct {
    /// Where its files' quality comes from: by default, the nearest of the
    /// file's name and its folders that says one.
    quality: QualityFrom = .path,
    /// Names starting with this are skipped (e.g., housekeeping folders), or
    /// none if empty, as by default: a prefix skips titles that start with
    /// it too, so no default suits every library.
    skip: []const u8 = "",
};

/// Where a source's files' quality comes from. Stored as its `quality-by`
/// field (`folder`, else empty) and its `rendition` field (the name, kept
/// as data), as older devices read them.
pub const QualityFrom = union(enum) {
    /// The files' names' technical tokens (`2160p hevc hdr`), else unknown.
    names,
    /// The first folder within the source, named as it is
    /// (`Movies/HQ 1080p30 Surround/Alien (1979).m4v`); that folder isn't
    /// read as part of the file's name.
    folder,
    /// The nearest that says one, of the file's name and its folders up to
    /// the source (`D/C/B/A.m4v`: A, then B, C, D): the name by its tokens,
    /// canonically (`2160p hevc hdr`); a folder by its whole name
    /// (`HQ 1080p30 Surround`, `1080p`), which isn't read as part of the
    /// file's, unless it reads as a title's (`30 Rock (2006) 1080p`), which
    /// gives its tokens alone. The name counts only if it says a resolution,
    /// as a word such as "Web" may be its title's. `names` and `folder` in
    /// one, by default.
    path,
    /// One name for every file (e.g., a HandBrake preset's).
    named: []const u8,
    /// A `quality-by` a newer device wrote, which this one can't apply (as
    /// reading the files' own, to come), so it doesn't crawl the source
    /// rather than record its copies under other qualities.
    unknown,

    /// As stored: its `quality-by` and `rendition`.
    fn fromFields(by: []const u8, rendition: []const u8) QualityFrom {
        if (std.mem.eql(u8, by, "folder")) return .folder;
        if (std.mem.eql(u8, by, "path")) return .path;
        if (by.len > 0) return .unknown;
        return if (rendition.len > 0) .{ .named = rendition } else .names;
    }

    /// Its `quality-by` and `rendition` fields, to store.
    fn fields(q: QualityFrom) ?[2][]const u8 {
        return switch (q) {
            .names => .{ "", "" },
            .folder => .{ "folder", "" },
            .path => .{ "path", "" },
            .named => |n| .{ "", n },
            .unknown => null,
        };
    }
};

/// How a source's file is read: the path to parse, less its quality
/// folder, if its quality is a folder's whole name.
pub const Named = struct { path: []const u8, folder: ?[]const u8 };

pub fn named(arena: std.mem.Allocator, layout: Layout, rel: []const u8) !Named {
    const whole: Named = .{ .path = rel, .folder = null };
    switch (layout.quality) {
        .folder => {
            const slash = std.mem.indexOfScalar(u8, rel, '/') orelse return whole;
            return .{ .path = rel[slash + 1 ..], .folder = rel[0..slash] };
        },
        .path => {
            const file_at = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |s| s + 1 else return whole;
            var scratch: [1024]u8 = undefined;
            // The file's own name first, if it says a resolution: a word
            // such as "Web" alone may be its title's ("Madame Web").
            if (naming.parse(rel[file_at..], &scratch).quality) |q| if (naming.hasResolution(q)) return whole;
            var end = file_at - 1;
            while (true) {
                const start = if (std.mem.lastIndexOfScalar(u8, rel[0..end], '/')) |s| s + 1 else 0;
                const folder = rel[start..end];
                if (naming.namesQuality(folder)) {
                    // A title's folder's quality is its tokens', as the
                    // file's would be (`naming.parse`).
                    if (naming.readsAsTitle(folder)) return whole;
                    return .{ .path = try std.mem.concat(arena, u8, &.{ rel[0..start], rel[end + 1 ..] }), .folder = folder };
                }
                if (start == 0) return whole;
                end = start - 1;
            }
        },
        .names, .named, .unknown => return whole,
    }
}

pub const Source = struct {
    id: [16]u8,
    url: []const u8,
    layout: Layout,
    /// A device's downloads (`managed`, see download.zig): its copies are
    /// written as files are fetched, onto the qualities they came from, so
    /// it isn't crawled.
    managed: bool = false,
    /// The device that wrote its address, whose it is (and whose downloads,
    /// if `managed`).
    owner: ?[32]u8 = null,
    /// When a device last crawled it whole (`crawled`, wall-clock
    /// milliseconds), so others who've synced since needn't again soon.
    crawled_ms: u64 = 0,
    /// What its owner calls it (`name`), as a folder's own name ("TV
    /// Shows") its address had to put otherwise (`/tv-shows/`); empty if
    /// none. Taken only from its owner, as its address is.
    name: []const u8 = "",
    /// Where it's reached: its `url`, or for a device's own source
    /// (`cqdevice://`), where its device serves it now; null if that device
    /// hasn't said, so it can't be reached (crawled, played, fetched).
    address: ?[]const u8 = null,

    /// Where it's reached now: its address; or, read without one, its URL
    /// if that's an ordinary one; null for a device's own source its device
    /// hasn't said where it serves.
    pub fn at(source: Source) ?[]const u8 {
        return source.address orelse if (url.device(source.url) == null) source.url else null;
    }

    /// Whether a device crawled it within `window_ms` of `wall_ms` (see
    /// `crawlWindow`): a refresh, having synced, skips it, as its copies
    /// are here already.
    pub fn crawledLately(source: Source, wall_ms: u64, window_ms: u64) bool {
        return source.crawled_ms > 0 and wall_ms -| source.crawled_ms < window_ms;
    }
};

/// How often refreshes not asked for (at launch, on a timer) look for new
/// videos, in hours, for the whole library (`settings`' `crawl`): 1, 3, 24
/// (unset), or 168; null, never (Manually), as a consumer NAS's disks spin
/// up for each crawl, and Refresh Library crawls whenever a person knows
/// there's something new.
pub fn crawlEvery(replica: *Replica, arena: std.mem.Allocator) !?u64 {
    const s = try replica.db.prepare("SELECT value FROM winners WHERE key = 'settings' AND field = 'crawl'");
    defer s.finalize();
    const value = if (try s.step()) try arena.dupe(u8, s.blob(0)) else "";
    if (value.len == 0) return default_crawl_hours;
    const hours = std.fmt.parseInt(u64, value, 10) catch return default_crawl_hours;
    return if (hours == 0) null else hours;
}

pub const default_crawl_hours: u64 = 24;

/// Sets how often refreshes not asked for look for new videos (see
/// `crawlEvery`): hours, or 0 for Manually.
pub fn setCrawlEvery(replica: *Replica, wall_ms: u64, hours: u64) !void {
    var buf: [20]u8 = undefined;
    try replica.write(wall_ms, "settings", "crawl", try std.fmt.bufPrint(&buf, "{d}", .{hours}));
}

/// How lately a crawl spares refreshes not asked for theirs: `hours`, give
/// or take a 24th of it (a day's, an hour), drawn afresh each time so
/// devices that crawled together don't come due together.
pub fn crawlWindow(io: Io, hours: u64) u64 {
    const span = hours * 3600 * 1000;
    const spread = span / 24;
    var n: u64 = undefined;
    io.random(std.mem.asBytes(&n));
    return span - spread + n % (2 * spread + 1);
}

/// Lowercases ASCII letters, drops apostrophes and periods, turns other
/// ASCII punctuation and spaces into single hyphens, and keeps other bytes
/// (letters with diacritics, other scripts) as they are.
pub fn normalize(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var hyphen = false;
    for (text) |ch| {
        if (ch == '\'' or ch == '.') continue;
        if (ch >= 0x80 or std.ascii.isAlphanumeric(ch)) {
            if (hyphen and out.items.len > 0) try out.append(arena, '-');
            hyphen = false;
            try out.append(arena, std.ascii.toLower(ch));
        } else hyphen = true;
    }
    return out.items;
}

/// Folds Latin letters with diacritics to plain ones, for spotting close
/// matches ("amélie" and "amelie").
pub fn fold(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    // A name needn't be UTF-8 (a Latin-1 file's): then it's left as it is.
    var it = (std.unicode.Utf8View.init(text) catch return text).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x80) {
            try out.append(arena, @intCast(cp));
        } else if (foldLatin(cp)) |plain| {
            try out.appendSlice(arena, plain);
        } else {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch continue;
            try out.appendSlice(arena, buf[0..n]);
        }
    }
    return out.items;
}

fn foldLatin(cp: u21) ?[]const u8 {
    // Latin-1 Supplement and Latin Extended-A, lowercase and uppercase.
    const table = [_]struct { u21, u21, []const u8 }{
        .{ 0xC0, 0xC5, "a" },
        .{ 0xE0, 0xE5, "a" },
        .{ 0xC6, 0xC6, "ae" },
        .{ 0xE6, 0xE6, "ae" },
        .{ 0xC7, 0xC7, "c" },
        .{ 0xE7, 0xE7, "c" },
        .{ 0xC8, 0xCB, "e" },
        .{ 0xE8, 0xEB, "e" },
        .{ 0xCC, 0xCF, "i" },
        .{ 0xEC, 0xEF, "i" },
        .{ 0xD1, 0xD1, "n" },
        .{ 0xF1, 0xF1, "n" },
        .{ 0xD2, 0xD6, "o" },
        .{ 0xF2, 0xF6, "o" },
        .{ 0xD8, 0xD8, "o" },
        .{ 0xF8, 0xF8, "o" },
        .{ 0xD9, 0xDC, "u" },
        .{ 0xF9, 0xFC, "u" },
        .{ 0xDD, 0xDD, "y" },
        .{ 0xFD, 0xFD, "y" },
        .{ 0xFF, 0xFF, "y" },
        .{ 0xDF, 0xDF, "ss" },
        .{ 0x100, 0x105, "a" },
        .{ 0x106, 0x10D, "c" },
        .{ 0x10E, 0x111, "d" },
        .{ 0x112, 0x11B, "e" },
        .{ 0x11C, 0x123, "g" },
        .{ 0x124, 0x127, "h" },
        .{ 0x128, 0x131, "i" },
        .{ 0x134, 0x135, "j" },
        .{ 0x136, 0x138, "k" },
        .{ 0x139, 0x142, "l" },
        .{ 0x143, 0x14B, "n" },
        .{ 0x14C, 0x151, "o" },
        .{ 0x152, 0x153, "oe" },
        .{ 0x154, 0x159, "r" },
        .{ 0x15A, 0x161, "s" },
        .{ 0x162, 0x167, "t" },
        .{ 0x168, 0x173, "u" },
        .{ 0x174, 0x175, "w" },
        .{ 0x176, 0x178, "y" },
        .{ 0x179, 0x17E, "z" },
    };
    for (table) |row| if (cp >= row[0] and cp <= row[1]) return row[2];
    return null;
}

/// The keys a parsed path maps to.
pub const Keys = struct {
    title: []const u8,
    item: []const u8,
};

/// Each folder's series, from the episodes in it or in its season folders,
/// so a special without an episode number can be told from a movie.
pub const SeriesByFolder = std.StringHashMapUnmanaged(struct { title: []const u8, year: ?u16 });

pub fn seriesByFolder(arena: std.mem.Allocator, base: []const u8, layout: Layout, entries: []const crawl.Entry) !SeriesByFolder {
    var out: SeriesByFolder = .empty;
    var scratch: [1024]u8 = undefined;
    for (entries) |entry| {
        if (entry.is_dir) continue;
        const rel = (try named(arena, layout, relativeOrNull(arena, base, entry.url) orelse continue)).path;
        if (!naming.isVideo(rel)) continue;
        const p = naming.parse(rel, &scratch);
        if (p.kind != .episode or p.title.len == 0) continue;
        var dir = std.fs.path.dirname(rel) orelse continue;
        if (naming.isSeasonFolder(std.fs.path.basename(dir))) dir = std.fs.path.dirname(dir) orelse continue;
        const gop = try out.getOrPut(arena, dir);
        if (!gop.found_existing) gop.value_ptr.* = .{ .title = try arena.dupe(u8, p.title), .year = p.year };
    }
    return out;
}

/// Parses a source's file, taking as a series' special (season 0) a
/// "movie" in the series' folder whose title extends the series' (e.g.,
/// "Babylon 5 The Gathering" beside Babylon 5's episodes), or an episode
/// without a number in a "Specials" folder. Strings are the arena's.
pub fn parseFile(arena: std.mem.Allocator, rel: []const u8, series: *const SeriesByFolder) !naming.Parsed {
    var scratch: [1024]u8 = undefined;
    var p = naming.parse(rel, &scratch);
    p.title = try arena.dupe(u8, p.title);
    if (p.quality) |r| p.quality = try arena.dupe(u8, r);
    if (p.edition) |e| p.edition = try arena.dupe(u8, e);
    const dir = std.fs.path.dirname(rel) orelse return p;
    const numberless = p.kind == .episode and p.episode == null and p.date == null and p.season == 0;
    if (!(p.kind == .movie and p.year == null) and !numberless) return p;
    var series_dir = dir;
    if (naming.isSeasonFolder(std.fs.path.basename(dir))) series_dir = std.fs.path.dirname(dir) orelse return p;
    const s = series.get(series_dir) orelse return p;
    // The file's own title, less the series'.
    const own = naming.parse(std.fs.path.basename(rel), &scratch).title;
    const n_own = try normalize(arena, own);
    const n_series = try normalize(arena, s.title);
    if (!std.mem.startsWith(u8, n_own, n_series)) return p;
    const rest = if (ascii.startsWithIgnoreCase(own, s.title)) std.mem.trim(u8, own[s.title.len..], " -:,.") else std.mem.trim(u8, n_own[n_series.len..], "-");
    if (rest.len == 0) return p;
    p.kind = .episode;
    p.title = s.title;
    p.year = s.year;
    p.season = 0;
    p.special = try arena.dupe(u8, rest);
    return p;
}

pub fn keys(arena: std.mem.Allocator, p: naming.Parsed) !Keys {
    const kind: u8 = if (p.kind == .episode) 's' else 'm';
    const year = if (p.year) |y| try std.fmt.allocPrint(arena, "{d}", .{y}) else "-";
    const title = try std.fmt.allocPrint(arena, "t/{c}/{s}/{s}", .{ kind, try normalize(arena, p.title), year });
    var item: std.ArrayList(u8) = .empty;
    try item.appendSlice(arena, title);
    if (p.kind == .episode) {
        if (p.special) |name| {
            try item.print(arena, "/e/s00-{s}", .{try normalize(arena, name)});
        } else if (p.date) |d| {
            // A season a year (see `naming.parse`): `/e/s2024e0312`.
            try item.print(arena, "/e/s{s}e{s}{s}", .{ d[0..4], d[5..7], d[8..10] });
        } else {
            try item.print(arena, "/e/s{d:0>2}e{d:0>2}", .{ p.season orelse 0, p.episode orelse 0 });
            if (p.last_episode) |last| try item.print(arena, "-e{d:0>2}", .{last});
        }
        if (p.edition) |e| try item.print(arena, "/v/{s}", .{try normalize(arena, e)});
    } else {
        try item.print(arena, "/v/{s}", .{if (p.edition) |e| try normalize(arena, e) else "-"});
    }
    if (p.part) |part| try item.print(arena, "/p/{d}", .{part});
    return .{ .title = title, .item = item.items };
}

fn sourceId(target: []const u8) [16]u8 {
    var hash: [8]u8 = undefined;
    Blake3.hash(target, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

pub fn addSource(replica: *Replica, wall_ms: u64, target: []const u8, layout: Layout) ![16]u8 {
    if (!url.fitForSource(target)) return error.BadAddress;
    const id = sourceId(target);
    var key_buf: [18]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "r/{s}", .{id});
    try replica.begin();
    errdefer replica.rollback();
    try replica.write(wall_ms, key, "url", target);
    const quality = layout.quality.fields() orelse return error.InvalidArgument;
    try replica.write(wall_ms, key, "rendition", quality[1]);
    try replica.write(wall_ms, key, "skip", layout.skip);
    if (quality[0].len > 0) try replica.write(wall_ms, key, "quality-by", quality[0]);
    try replica.commit();
    return id;
}

/// A source, by ID or URL as typed.
pub fn findSource(replica: *Replica, arena: std.mem.Allocator, which: []const u8) !Source {
    var escaped: std.ArrayList(u8) = .empty;
    try url.escape(arena, &escaped, which);
    if (!std.mem.endsWith(u8, escaped.items, "/")) try escaped.append(arena, '/');
    for (try sources(replica, arena)) |r| {
        if (std.mem.eql(u8, &r.id, which) or std.mem.eql(u8, r.url, escaped.items)) return r;
    }
    return error.NoSuchSource;
}

/// Sets where a source's files' quality comes from. Copies move to their
/// new qualities at the next crawl.
pub fn setQualityFrom(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, which: []const u8, quality: QualityFrom) !Source {
    var source = try findSource(replica, arena, which);
    const stored = quality.fields() orelse return error.InvalidArgument;
    const key = try std.fmt.allocPrint(arena, "r/{s}", .{source.id});
    try replica.begin();
    errdefer replica.rollback();
    try replica.write(wall_ms, key, "quality-by", stored[0]);
    try replica.write(wall_ms, key, "rendition", stored[1]);
    try replica.commit();
    source.layout.quality = quality;
    return source;
}

/// Sets the prefix of names a source's crawls skip, applied at the next.
pub fn setSkip(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, which: []const u8, skip: []const u8) !Source {
    var source = try findSource(replica, arena, which);
    try replica.write(wall_ms, try std.fmt.allocPrint(arena, "r/{s}", .{source.id}), "skip", skip);
    source.layout.skip = skip;
    return source;
}

/// Removes a source, by ID or URL, from the library, for every device:
/// its settings and every copy it held, and this device's last crawl of it.
/// Returns how many copies it held.
pub fn removeSource(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, which: []const u8) !usize {
    const source = try findSource(replica, arena, which);

    const field = try std.fmt.allocPrint(arena, "held:{s}", .{source.id});
    var held: std.ArrayList([]const u8) = .empty;
    {
        const s = try replica.db.prepare("SELECT key FROM winners WHERE field = ?1 AND length(value) > 0");
        defer s.finalize();
        try s.bindText(1, field);
        while (try s.step()) try held.append(arena, try arena.dupe(u8, s.blob(0)));
    }
    const key = try std.fmt.allocPrint(arena, "r/{s}", .{source.id});
    try replica.begin();
    errdefer replica.rollback();
    for (held.items) |k| try replica.write(wall_ms, k, field, "");
    // An empty URL marks the source removed.
    for ([_][]const u8{ "url", "rendition", "skip" }) |f| try replica.write(wall_ms, key, f, "");
    try replica.commit();
    try replica.removeLocal(try snapshotKey(arena, source.id));
    return held.items.len;
}

/// Moves a source (by ID or URL) to another address: the new takes its
/// settings (but `managed`, which a device's downloads' configuring marks
/// again), name, crawl time, unavailable directories, every copy, and the
/// crawl snapshot, and the old is removed, in one transaction; so its
/// videos stay where they are, unavailable ones too. It writes every copy
/// twice, so it's for once, as a device's own sources move to their
/// port-free address (`cqdevice://`), which then stays as its port changes.
/// Returns the new ID; moving to where it is changes nothing.
pub fn moveSource(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, which: []const u8, to: []const u8) ![16]u8 {
    const source = try findSource(replica, arena, which);
    var escaped: std.ArrayList(u8) = .empty;
    try url.escape(arena, &escaped, to);
    if (!std.mem.endsWith(u8, escaped.items, "/")) try escaped.append(arena, '/');
    const target = escaped.items;
    if (!url.fitForSource(target)) return error.BadAddress;
    const id = sourceId(target);
    if (std.mem.eql(u8, &id, &source.id)) return id;
    const old_key = try std.fmt.allocPrint(arena, "r/{s}", .{source.id});
    const new_key = try std.fmt.allocPrint(arena, "r/{s}", .{id});
    const Field = struct { name: []const u8, value: []const u8 };
    var settings: std.ArrayList(Field) = .empty;
    {
        const s = try replica.db.prepare("SELECT field, value FROM winners WHERE key = ?1 AND length(value) > 0");
        defer s.finalize();
        try s.bindText(1, old_key);
        while (try s.step()) {
            const name = s.blob(0);
            if (std.mem.eql(u8, name, "url") or std.mem.eql(u8, name, "managed")) continue;
            try settings.append(arena, .{ .name = try arena.dupe(u8, name), .value = try arena.dupe(u8, s.blob(1)) });
        }
    }
    const old_field = try std.fmt.allocPrint(arena, "held:{s}", .{source.id});
    const new_field = try std.fmt.allocPrint(arena, "held:{s}", .{id});
    var copies: std.ArrayList(Field) = .empty;
    {
        const s = try replica.db.prepare("SELECT key, value FROM winners WHERE field = ?1 AND length(value) > 0");
        defer s.finalize();
        try s.bindText(1, old_field);
        while (try s.step()) try copies.append(arena, .{ .name = try arena.dupe(u8, s.blob(0)), .value = try arena.dupe(u8, s.blob(1)) });
    }
    try replica.begin();
    errdefer replica.rollback();
    try replica.write(wall_ms, new_key, "url", target);
    for (settings.items) |f| try replica.write(wall_ms, new_key, f.name, f.value);
    for (copies.items) |c| {
        try replica.write(wall_ms, c.name, new_field, c.value);
        try replica.write(wall_ms, c.name, old_field, "");
    }
    for ([_][]const u8{ "url", "rendition", "skip" }) |f| try replica.write(wall_ms, old_key, f, "");
    try replica.commit();
    if (try replica.local(arena, try snapshotKey(arena, source.id))) |snapshot| {
        try replica.setLocal(try snapshotKey(arena, id), snapshot);
        try replica.removeLocal(try snapshotKey(arena, source.id));
    }
    return id;
}

/// This device's own source served at `path` (`/Archive1841/`) by its
/// `.local` name and port, as the apps wrote them before port-free
/// addresses (`cqdevice://`), if there is one: to move there once
/// (`moveSource`). One added by hand at another host (an IP address,
/// `localhost`) is the person's choice, and stays.
pub fn portBound(replica: *Replica, arena: std.mem.Allocator, device: [32]u8, path: []const u8) !?Source {
    for (try sources(replica, arena)) |s| {
        if (s.owner == null or !std.mem.eql(u8, &s.owner.?, &device) or url.device(s.url) != null) continue;
        const uri = std.Uri.parse(s.url) catch continue;
        const host = try (uri.host orelse continue).toRawMaybeAlloc(arena);
        if (!std.ascii.endsWithIgnoreCase(host, ".local")) continue;
        if (std.mem.eql(u8, try uri.path.toRawMaybeAlloc(arena), path)) return s;
    }
    return null;
}

/// Brings this device's own source served at `path` to its port-free
/// address (`cqdevice://` and its key), moving one written with a host and
/// port there once; returns the address.
pub fn ownSource(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, device: [32]u8, path: []const u8) ![]const u8 {
    const address = try url.deviceSource(arena, device, path);
    if (try portBound(replica, arena, device, path)) |old| _ = try moveSource(replica, arena, wall_ms, &old.id, address);
    return address;
}

/// How many copies a source holds.
pub fn countCopies(replica: *Replica, arena: std.mem.Allocator, source: Source) !i64 {
    return (try copyCounts(replica, arena)).get(&source.id) orelse 0;
}

/// How many copies each source holds, by its ID, in one pass (a field
/// has no index of its own, so each count alone is a pass of its own).
pub fn copyCounts(replica: *Replica, arena: std.mem.Allocator) !std.StringHashMapUnmanaged(i64) {
    var out: std.StringHashMapUnmanaged(i64) = .empty;
    const s = try replica.db.prepare("SELECT field, count(*) FROM winners WHERE field >= 'held:' AND field < 'held;' AND length(value) > 0 GROUP BY field");
    defer s.finalize();
    while (try s.step()) try out.put(arena, try arena.dupe(u8, s.blob(0)["held:".len..]), s.int(1));
    return out;
}

fn snapshotKey(arena: std.mem.Allocator, id: [16]u8) ![]u8 {
    return std.fmt.allocPrint(arena, "snapshot:{s}", .{id});
}

pub const CrawlStats = struct {
    crawl: crawl.Result,
    ingest: IngestStats,
    /// What the crawl found, for describing (see `art.plan`).
    entries: []const crawl.Entry,
    crawl_ms: i64,
    total_ms: i64,
};

/// A title's kind, as its key's letter has it (`t/m/...`, `t/s/...`), and
/// as JSON names it (`movie`, `series`).
pub const TitleKind = enum(u8) { movie = 'm', series = 's' };

/// Crawls a source, reusing this device's last crawl of it where its
/// directories haven't changed, brings the library's copies in line with
/// what it found, and keeps the crawl for next time. Describing what it
/// found is separate (see `art.plan` and `art.run`), so its titles show
/// before their covers.
pub fn crawlSource(replica: *Replica, io: Io, arena: std.mem.Allocator, client: *std.http.Client, wall_ms: u64, source: Source, workers: usize) !CrawlStats {
    var prev: ?crawl.Snapshot = null;
    if (try replica.local(arena, try snapshotKey(arena, source.id))) |saved| {
        prev = try crawl.Snapshot.init(arena, try crawl.Snapshot.load(arena, saved));
    }
    return crawlFrom(replica, io, arena, client, wall_ms, source, workers, if (prev) |*p| p else null);
}

/// As `crawlSource`, but listing every directory afresh, reusing none of
/// the last crawl, as a directory's time doesn't change as a file in it is
/// rewritten in place (retagged).
pub fn crawlSourceAfresh(replica: *Replica, io: Io, arena: std.mem.Allocator, client: *std.http.Client, wall_ms: u64, source: Source, workers: usize) !CrawlStats {
    return crawlFrom(replica, io, arena, client, wall_ms, source, workers, null);
}

/// Crawls a source, reusing `prev`'s listings where they're unchanged.
fn crawlFrom(replica: *Replica, io: Io, arena: std.mem.Allocator, client: *std.http.Client, wall_ms: u64, source: Source, workers: usize, prev: ?*const crawl.Snapshot) !CrawlStats {
    if (source.layout.quality == .unknown) return error.UnknownQualitySetting;
    const key = try snapshotKey(arena, source.id);
    var entries: std.ArrayList(crawl.Entry) = .empty;
    const start = Io.Timestamp.now(io, .awake);
    const result = try crawl.crawl(io, arena, client, source.at() orelse return error.DeviceAway, .{
        .workers = workers,
        .prev = prev,
        .entries = &entries,
    });
    const crawled = Io.Timestamp.now(io, .awake);
    const stats = try ingest(replica, arena, wall_ms, source, entries.items);
    var saved: Io.Writer.Allocating = .init(arena);
    try crawl.Snapshot.save(entries.items, &saved.writer);
    try replica.setLocal(key, saved.written());
    var crawled_at: [20]u8 = undefined;
    try replica.write(wall_ms, try std.fmt.allocPrint(arena, "r/{s}", .{&source.id}), "crawled", try std.fmt.bufPrint(&crawled_at, "{d}", .{wall_ms}));
    return .{
        .crawl = result,
        .ingest = stats,
        .entries = entries.items,
        .crawl_ms = start.durationTo(crawled).toMilliseconds(),
        .total_ms = start.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds(),
    };
}

/// The sources, as players list them: by the path they show
/// (`sourcePath`), devices' downloads last.
pub fn sources(replica: *Replica, arena: std.mem.Allocator) ![]Source {
    var out: std.ArrayList(Source) = .empty;
    // Each one's `quality-by` and `rendition`, read together once all are;
    // and its name's writer, checked against its owner once it's read.
    var stored: std.ArrayList([2][]const u8) = .empty;
    var namers: std.ArrayList(?[32]u8) = .empty;
    const s = try replica.db.prepare("SELECT key, field, value, device FROM winners WHERE key >= 'r/' AND key < 'r0' ORDER BY key");
    defer s.finalize();
    while (try s.step()) {
        const key = s.blob(0);
        if (key.len != 18) continue;
        if (out.items.len == 0 or !std.mem.eql(u8, &out.items[out.items.len - 1].id, key[2..18])) {
            try out.append(arena, .{ .id = key[2..18].*, .url = "", .layout = .{} });
            try stored.append(arena, .{ "", "" });
            try namers.append(arena, null);
        }
        const r = &out.items[out.items.len - 1];
        const quality = &stored.items[stored.items.len - 1];
        const field = s.blob(1);
        const value = try arena.dupe(u8, s.blob(2));
        if (std.mem.eql(u8, field, "url")) {
            r.url = value;
            r.owner = try replica.keyOf(s.int(3));
        } //
        else if (std.mem.eql(u8, field, "rendition")) quality[1] = value //
        else if (std.mem.eql(u8, field, "skip")) r.layout.skip = value //
        else if (std.mem.eql(u8, field, "quality-by")) quality[0] = value //
        else if (std.mem.eql(u8, field, "managed")) r.managed = value.len > 0 //
        else if (std.mem.eql(u8, field, "name")) {
            r.name = value;
            namers.items[namers.items.len - 1] = try replica.keyOf(s.int(3));
        } //
        else if (std.mem.eql(u8, field, "crawled")) r.crawled_ms = std.fmt.parseInt(u64, value, 10) catch 0;
    }
    for (out.items, stored.items, namers.items) |*r, q, namer| {
        r.layout.quality = .fromFields(q[0], q[1]);
        const owned = r.owner != null and namer != null and std.mem.eql(u8, &r.owner.?, &namer.?);
        if (!owned) r.name = "";
    }
    // Dropped sources have no URL, and one whose URL isn't fit to fetch
    // from (as any member could write) is none.
    var kept: std.ArrayList(Source) = .empty;
    var shown: std.ArrayList([]const u8) = .empty;
    // Devices' own sources reached where each serves them now; one is
    // only its device's to write, as any member could otherwise aim
    // devices at another's paths.
    var served: ?[]const Name = null;
    for (out.items) |*r| if (url.fitForSource(r.url)) {
        if (url.device(r.url)) |d| {
            if (r.owner == null or !std.mem.eql(u8, &r.owner.?, &d.key)) continue;
            if (served == null) served = try names(replica, arena);
            const hex = std.fmt.bytesToHex(d.key, .lower);
            r.address = for (served.?) |n| {
                if (std.mem.eql(u8, n.key, &hex)) break if (n.served) |at| try url.reach(arena, at, d.path) else null;
            } else null;
        } else r.address = r.url;
        try kept.append(arena, r.*);
        try shown.append(arena, try std.ascii.allocLowerString(arena, try std.mem.join(arena, " › ", try shownPath(arena, r.*))));
    };
    const Order = struct {
        list: []const Source,
        shown: []const []const u8,
        pub fn lessThan(o: @This(), a: usize, b: usize) bool {
            if (o.list[a].managed != o.list[b].managed) return !o.list[a].managed;
            return std.mem.order(u8, o.shown[a], o.shown[b]) == .lt;
        }
    };
    const order = try arena.alloc(usize, kept.items.len);
    for (order, 0..) |*i, n| i.* = n;
    std.mem.sort(usize, order, Order{ .list = kept.items, .shown = shown.items }, Order.lessThan);
    const sorted = try arena.alloc(Source, order.len);
    for (order, sorted) |i, *o| o.* = kept.items[i];
    return sorted;
}

/// A source's server and folders as a person reads them ("art", "Movies",
/// "2160p", to join with " › "): its host without `.local` (or its port),
/// then its folders, decoded, but a NAS's shared folder (as `Video`), seldom
/// worth showing, where there are more than two.
pub fn sourcePath(arena: std.mem.Allocator, u: []const u8) ![]const []const u8 {
    const uri = std.Uri.parse(u) catch return arena.dupe([]const u8, &.{u});
    const host_raw = uri.host orelse return arena.dupe([]const u8, &.{u});
    var host = try host_raw.toRawMaybeAlloc(arena);
    if (std.ascii.endsWithIgnoreCase(host, ".local")) host = host[0 .. host.len - ".local".len];
    var parts: std.ArrayList([]const u8) = .empty;
    var folders = std.mem.tokenizeScalar(u8, try uri.path.toRawMaybeAlloc(arena), '/');
    while (folders.next()) |f| try parts.append(arena, url.decode(try arena.dupe(u8, f)) catch f);
    const shown = if (parts.items.len > 2) parts.items[1..] else parts.items;
    return std.mem.concat(arena, []const u8, &.{ &.{host}, shown });
}

/// A source's path as players show it: `sourcePath`, its last folder named
/// as its owner calls it, if it does (`firefly › Archive1841`, not
/// `archive1841`).
pub fn shownPath(arena: std.mem.Allocator, source: Source) ![]const []const u8 {
    // A device's own source by where it's served now, its host's name.
    const parts = try sourcePath(arena, source.address orelse source.url);
    if (source.name.len == 0 or parts.len < 2) return parts;
    const out = try arena.dupe([]const u8, parts);
    out[out.len - 1] = source.name;
    return out;
}

/// Names a source as its owner calls it (see `Source.name`), unless it's
/// named so already.
pub fn setSourceName(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, id: []const u8, name: []const u8) !void {
    if (name.len > 255) return error.Invalid;
    for (try sources(replica, arena)) |s| if (std.mem.eql(u8, &s.id, id)) {
        if (std.mem.eql(u8, s.name, name)) return;
        return replica.write(wall_ms, try std.fmt.allocPrint(arena, "r/{s}", .{id}), "name", name);
    };
    return error.NotFound;
}

test "a source's path, as a person reads it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const join = struct {
        fn of(a: std.mem.Allocator, u: []const u8) ![]const u8 {
            return std.mem.join(a, " › ", try sourcePath(a, u));
        }
    }.of;
    try std.testing.expectEqualStrings("sulaco › Video › TV Shows", try join(arena, "http://sulaco/Video/TV%20Shows/"));
    try std.testing.expectEqualStrings("art › Movies › 2160p", try join(arena, "http://art.local/Video/Movies/2160p/"));
    try std.testing.expectEqualStrings("firefly › youtube", try join(arena, "http://firefly.local:58208/youtube/"));
    // Its last folder as its owner calls it, where its address couldn't.
    const folder: Source = .{ .id = @splat('0'), .url = "http://firefly.local:8008/archive1841/", .layout = .{}, .name = "Archive1841" };
    try std.testing.expectEqualStrings("firefly › Archive1841", try std.mem.join(arena, " › ", try shownPath(arena, folder)));
}

/// Removes `device`'s downloads (sources it marked as its own), as it's
/// removed from the library: no one would serve them again.
pub fn removeDownloadsOf(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, device: [32]u8) !void {
    for (try sources(replica, arena)) |s| {
        if (s.managed and s.owner != null and std.mem.eql(u8, &s.owner.?, &device)) _ = try removeSource(replica, arena, wall_ms, &s.id);
    }
}

pub const IngestStats = struct {
    files: usize = 0,
    skipped: usize = 0,
    unparsed: usize = 0,
    extras: usize = 0,
    titles_added: usize = 0,
    copies_added: usize = 0,
    copies_changed: usize = 0,
    copies_removed: usize = 0,
    /// Files whose quality another file of the same source already
    /// had.
    duplicates: usize = 0,
    /// Directories that held files and list none now, their copies kept.
    unavailable: usize = 0,
    duplicate_example: ?[]const u8 = null,
};

/// Brings the library's copies for `source` in line with a crawl of it.
pub fn ingest(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, source: Source, entries: []const crawl.Entry) !IngestStats {
    var stats: IngestStats = .{};
    const held_field = try std.fmt.allocPrint(arena, "held:{s}", .{source.id});

    // What the source holds now: quality key -> path, size, time.
    var wanted: std.StringHashMapUnmanaged([]const u8) = .empty;
    var fields: std.StringHashMapUnmanaged(void) = .empty; // title and item fields to ensure
    var titles_seen: std.ArrayList(struct { key: []const u8, name: []const u8, year: ?u16 }) = .empty;
    var items_seen: std.ArrayList(struct { key: []const u8, p: naming.Parsed }) = .empty;
    // The entries are as crawled, where it's reached.
    const base = source.at() orelse return error.DeviceAway;
    const series = try seriesByFolder(arena, base, source.layout, entries);
    for (entries) |entry| {
        if (entry.is_dir) continue;
        stats.files += 1;
        const rel = relativeOrNull(arena, base, entry.url) orelse continue;
        if (skipped(rel, source.layout.skip)) {
            stats.skipped += 1;
            continue;
        }
        const as = try named(arena, source.layout, rel);
        const path = as.path;
        if (!naming.isVideo(path)) {
            stats.skipped += 1;
            continue;
        }
        const value = try std.fmt.allocPrint(arena, "{s}\t{d}\t{s}", .{ rel, entry.size, entry.mtime });
        const p = try parseFile(arena, path, &series);
        if (p.kind == .extra) {
            stats.extras += 1;
            continue;
        }
        if (p.title.len == 0 or (p.kind == .episode and p.episode == null and p.date == null and p.special == null)) {
            stats.unparsed += 1;
            try wanted.put(arena, try std.fmt.allocPrint(arena, "u/{s}", .{try normalize(arena, rel)}), value);
            continue;
        }
        const owned = p;
        const k = try keys(arena, owned);
        var quality = try std.fmt.allocPrint(arena, "{s}/r/{s}", .{ k.item, try qualityOf(arena, source.layout, owned, as.folder) });
        // Two files of one quality in one source are duplicates (or
        // misnamed); keep both, numbered.
        if (wanted.contains(quality)) {
            stats.duplicates += 1;
            var n: usize = 2;
            while (wanted.contains(try std.fmt.allocPrint(arena, "{s}~{d}", .{ quality, n }))) n += 1;
            quality = try std.fmt.allocPrint(arena, "{s}~{d}", .{ quality, n });
            if (stats.duplicate_example == null) stats.duplicate_example = rel;
        }
        try wanted.put(arena, quality, value);
        const gop = try fields.getOrPut(arena, k.title);
        if (!gop.found_existing) try titles_seen.append(arena, .{ .key = k.title, .name = owned.title, .year = owned.year });
        const item_gop = try fields.getOrPut(arena, k.item);
        if (!item_gop.found_existing) try items_seen.append(arena, .{ .key = k.item, .p = owned });
    }

    // What the library says the source holds.
    var current: std.StringHashMapUnmanaged([]const u8) = .empty;
    {
        const s = try replica.db.prepare("SELECT key, value FROM winners WHERE field = ?1 AND length(value) > 0");
        defer s.finalize();
        try s.bindText(1, held_field);
        while (try s.step()) try current.put(arena, try arena.dupe(u8, s.blob(0)), try arena.dupe(u8, s.blob(1)));
    }

    // Directories listed now, and those with files beneath.
    var listed: std.StringHashMapUnmanaged(void) = .empty;
    var with_files: std.StringHashMapUnmanaged(void) = .empty;
    try listed.put(arena, "", {});
    for (entries) |entry| {
        const rel = relativeOrNull(arena, base, entry.url) orelse continue;
        if (entry.is_dir) {
            try listed.put(arena, std.mem.trimEnd(u8, rel, "/"), {});
        } else {
            var parents = parentsOf(rel);
            while (parents.next()) |dir| try with_files.put(arena, dir, {});
        }
    }
    // A directory that held files and is still listed but holds none (an
    // unplugged drive's empty mount point) is unavailable, its copies kept;
    // one gone from its parent's listing was deleted. Only the topmost of an
    // unavailable subtree is noted.
    var unavailable_now: std.StringArrayHashMapUnmanaged(void) = .empty;
    var held = current.valueIterator();
    while (held.next()) |value| {
        var parents = parentsOf(copyPath(value.*));
        while (parents.next()) |dir| {
            if (!listed.contains(dir)) break;
            if (with_files.contains(dir)) continue;
            try unavailable_now.put(arena, dir, {});
            break;
        }
    }
    var marked: std.StringHashMapUnmanaged(u64) = .empty;
    for (try unavailableDirs(replica, arena, &source.id)) |a| try marked.put(arena, a.dir, a.since_ms);
    // Kept until it comes back, is deleted, is forgotten, or a year passes.
    var kept: std.ArrayList([]const u8) = .empty;
    for (unavailable_now.keys()) |dir| {
        const since = marked.get(dir) orelse wall_ms;
        if (wall_ms -| since < unavailable_expiry_ms) try kept.append(arena, dir);
    }
    stats.unavailable = kept.items.len;

    try replica.begin();
    errdefer replica.rollback();
    for (titles_seen.items) |t| {
        if (try exists(replica, t.key, "name")) continue;
        stats.titles_added += 1;
        try replica.write(wall_ms, t.key, "name", t.name);
        // When it came, for Date Added; a source's first crawl finds what
        // was there all along, so its titles go by their files' times.
        if (source.crawled_ms > 0) try replica.write(wall_ms, t.key, "added", try std.fmt.allocPrint(arena, "{d}", .{wall_ms}));
        if (t.year) |y| try replica.write(wall_ms, t.key, "year", try std.fmt.allocPrint(arena, "{d}", .{y}));
    }
    for (items_seen.items) |it| {
        if (it.p.kind == .episode and !try exists(replica, it.key, "season")) {
            if (it.p.season) |n| try replica.write(wall_ms, it.key, "season", try std.fmt.allocPrint(arena, "{d}", .{n}));
            if (it.p.episode) |e| try replica.write(wall_ms, it.key, "episode", try std.fmt.allocPrint(arena, "{d}", .{e}));
            // A special's own name, until its file says otherwise.
            if (it.p.special) |name| try replica.write(wall_ms, it.key, "title", name);
        }
        // An edition's name as written ("Director's Cut"), which its key
        // ("directors-cut") loses.
        if (it.p.edition) |e| if (!try exists(replica, it.key, "edition")) try replica.write(wall_ms, it.key, "edition", e);
    }
    var it = wanted.iterator();
    while (it.next()) |e| {
        const old = current.get(e.key_ptr.*);
        if (old != null and std.mem.eql(u8, old.?, e.value_ptr.*)) continue;
        if (old == null) stats.copies_added += 1 else stats.copies_changed += 1;
        try replica.write(wall_ms, e.key_ptr.*, held_field, e.value_ptr.*);
    }
    var cur = current.iterator();
    removing: while (cur.next()) |e| {
        if (wanted.contains(e.key_ptr.*)) continue;
        for (kept.items) |dir| if (under(copyPath(e.value_ptr.*), dir)) continue :removing;
        stats.copies_removed += 1;
        try replica.write(wall_ms, e.key_ptr.*, held_field, "");
    }
    const source_key = try std.fmt.allocPrint(arena, "r/{s}", .{source.id});
    for (kept.items) |dir| if (!marked.contains(dir))
        try replica.write(wall_ms, source_key, try unavailableField(arena, dir), try std.fmt.allocPrint(arena, "{d}", .{wall_ms}));
    var was = marked.keyIterator();
    clearing: while (was.next()) |dir| {
        for (kept.items) |k| if (std.mem.eql(u8, k, dir.*)) continue :clearing;
        try replica.write(wall_ms, source_key, try unavailableField(arena, dir.*), "");
    }
    try replica.commit();
    return stats;
}

/// How long a directory may be unavailable before its copies go, as if it
/// were deleted: a year.
pub const unavailable_expiry_ms: u64 = 365 * 24 * 60 * 60 * 1000;

/// A directory of a source that held files and lists none now (an
/// unplugged drive's mount point, say): `dir` relative to the source,
/// empty for the whole of it, and when it was noticed.
pub const Unavailable = struct { dir: []const u8, since_ms: u64 };

fn unavailableField(arena: std.mem.Allocator, dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "absent:{s}", .{dir});
}

/// A source's unavailable directories.
pub fn unavailableDirs(replica: *Replica, arena: std.mem.Allocator, source_id: []const u8) ![]Unavailable {
    var out: std.ArrayList(Unavailable) = .empty;
    const s = try replica.db.prepare("SELECT field, value FROM winners WHERE key = ?1 AND field LIKE 'absent:%' AND length(value) > 0 ORDER BY field");
    defer s.finalize();
    try s.bindText(1, try std.fmt.allocPrint(arena, "r/{s}", .{source_id}));
    while (try s.step()) try out.append(arena, .{
        .dir = try arena.dupe(u8, s.blob(0)["absent:".len..]),
        .since_ms = std.fmt.parseInt(u64, s.blob(1), 10) catch 0,
    });
    return out.items;
}

/// Every source's unavailable directories, to tell which copies are under
/// one.
pub const UnavailableDirs = struct {
    by_repo: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,

    pub fn load(replica: *Replica, arena: std.mem.Allocator) !UnavailableDirs {
        var a: UnavailableDirs = .{};
        const s = try replica.db.prepare("SELECT key, field FROM winners WHERE key >= 'r/' AND key < 'r0' AND field LIKE 'absent:%' AND length(value) > 0");
        defer s.finalize();
        while (try s.step()) {
            const key = s.blob(0);
            if (key.len != 18) continue;
            const gop = try a.by_repo.getOrPut(arena, try arena.dupe(u8, key[2..]));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, try arena.dupe(u8, s.blob(1)["absent:".len..]));
        }
        return a;
    }

    /// Whether a copy (`value`, as `held:<source>` holds it) is under one of
    /// its source's unavailable directories.
    pub fn has(a: *const UnavailableDirs, source_id: []const u8, value: []const u8) bool {
        const dirs = a.by_repo.get(source_id) orelse return false;
        for (dirs.items) |dir| if (under(copyPath(value), dir)) return true;
        return false;
    }
};

/// Forgets an unavailable directory, as if it were deleted: its copies go,
/// for every device. Returns how many.
pub fn removeUnavailable(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, source: Source, dir: []const u8) !usize {
    const d = std.mem.trim(u8, dir, "/");
    const held_field = try std.fmt.allocPrint(arena, "held:{s}", .{source.id});
    var gone: std.ArrayList([]const u8) = .empty;
    {
        const s = try replica.db.prepare("SELECT key, value FROM winners WHERE field = ?1 AND length(value) > 0");
        defer s.finalize();
        try s.bindText(1, held_field);
        while (try s.step()) if (under(copyPath(s.blob(1)), d)) try gone.append(arena, try arena.dupe(u8, s.blob(0)));
    }
    try replica.begin();
    errdefer replica.rollback();
    for (gone.items) |key| try replica.write(wall_ms, key, held_field, "");
    try replica.write(wall_ms, try std.fmt.allocPrint(arena, "r/{s}", .{source.id}), try unavailableField(arena, d), "");
    try replica.commit();
    return gone.items.len;
}

/// A copy's path, before its size and time.
fn copyPath(value: []const u8) []const u8 {
    return value[0 .. std.mem.indexOfScalar(u8, value, '\t') orelse value.len];
}

/// Whether `path` is within `dir` (empty for the root).
fn under(path: []const u8, dir: []const u8) bool {
    return dir.len == 0 or (path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/');
}

/// The directories a path is within, from the root (empty) down.
fn parentsOf(path: []const u8) Parents {
    return .{ .path = path };
}

const Parents = struct {
    path: []const u8,
    at: ?usize = 0,

    fn next(p: *Parents) ?[]const u8 {
        const at = p.at orelse return null;
        if (at == 0) {
            p.at = std.mem.indexOfScalar(u8, p.path, '/');
            return "";
        }
        const dir = p.path[0..at];
        p.at = if (std.mem.indexOfScalarPos(u8, p.path, at + 1, '/')) |i| i else null;
        return dir;
    }
};

/// A file's quality label: its quality folder's, if the source names
/// qualities by folder; else the source's, if it names one; else what the
/// file's name says (e.g., `2160p-hevc-hdr`); else `-`, unknown.
pub fn qualityOf(arena: std.mem.Allocator, layout: Layout, p: naming.Parsed, folder: ?[]const u8) ![]const u8 {
    switch (layout.quality) {
        .folder, .path => if (folder) |f| return normalize(arena, f),
        .named => |n| return normalize(arena, n),
        .names, .unknown => {},
    }
    if (p.quality) |r| return normalize(arena, r);
    return "-";
}

fn relativeOrNull(arena: std.mem.Allocator, base: []const u8, target: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, target, base)) return null;
    return url.decode(arena.dupe(u8, target[base.len..]) catch return null) catch null;
}

fn skipped(rel: []const u8, skip: []const u8) bool {
    if (skip.len == 0) return false;
    var segments = std.mem.splitScalar(u8, rel, '/');
    while (segments.next()) |s| if (std.mem.startsWith(u8, s, skip)) return true;
    return false;
}

/// A field's value, if set and not empty.
pub fn fieldValue(replica: *Replica, arena: std.mem.Allocator, key: []const u8, field: []const u8) !?[]u8 {
    const s = try replica.db.prepare("SELECT value FROM winners WHERE key = ?1 AND field = ?2 AND length(value) > 0");
    defer s.finalize();
    try s.bindText(1, key);
    try s.bindText(2, field);
    return if (try s.step()) try arena.dupe(u8, s.blob(0)) else null;
}

fn exists(replica: *Replica, key: []const u8, field: []const u8) !bool {
    const s = try replica.db.prepare("SELECT 1 FROM winners WHERE key = ?1 AND field = ?2");
    defer s.finalize();
    try s.bindText(1, key);
    try s.bindText(2, field);
    return s.step();
}

pub const Title = struct {
    key: []const u8,
    kind: TitleKind,
    name: []const u8,
    year: ?u16,
    /// Episodes or versions below it.
    items: usize = 0,
    /// Qualities held by at least one source.
    qualities: usize = 0,
    /// Distinct quality labels held.
    labels: std.ArrayList([]const u8) = .empty,
};

/// Every title, with counts of its items and held qualities.
pub fn titles(replica: *Replica, arena: std.mem.Allocator) ![]Title {
    var out: std.ArrayList(Title) = .empty;
    var last_item: []const u8 = "";
    const s = try replica.db.prepare("SELECT key, field, value FROM winners WHERE key >= 't/' AND key < 't0' ORDER BY key");
    defer s.finalize();
    while (try s.step()) {
        const key = s.blob(0);
        const title_len = prefixSegments(key, 4) orelse continue;
        if (out.items.len == 0 or !std.mem.eql(u8, out.items[out.items.len - 1].key, key[0..title_len])) {
            // A kind this build doesn't know (a newer device's) isn't shown.
            const kind = std.enums.fromInt(TitleKind, key[2]) orelse continue;
            const tk = try arena.dupe(u8, key[0..title_len]);
            try out.append(arena, .{ .key = tk, .kind = kind, .name = "", .year = null });
        }
        const t = &out.items[out.items.len - 1];
        const field = s.blob(1);
        const value = s.blob(2);
        if (key.len == title_len) {
            if (std.mem.eql(u8, field, "name")) t.name = try arena.dupe(u8, value);
            if (std.mem.eql(u8, field, "year")) t.year = std.fmt.parseInt(u16, value, 10) catch null;
            continue;
        }
        const item_len = prefixSegments(key, 6) orelse key.len;
        if (!std.mem.eql(u8, last_item, key[0..item_len])) {
            last_item = try arena.dupe(u8, key[0..item_len]);
            t.items += 1;
        }
        if (std.mem.startsWith(u8, field, "held:") and value.len > 0) {
            if (pastTitle(key, "/r/")) |r| {
                t.qualities += 1;
                const label = key[r + 3 ..];
                for (t.labels.items) |l| {
                    if (std.mem.eql(u8, l, label)) break;
                } else try t.labels.append(arena, try arena.dupe(u8, label));
            }
        }
    }
    return out.items;
}

/// The length of `key`'s first `n` slash-separated segments.
/// Where `needle` (as `/r/`) first falls in a title's key or one below it,
/// past the title's own segments, which may hold it too (a film named "R",
/// `t/m/r/2010`).
pub fn pastTitle(key: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOfPos(u8, key, prefixSegments(key, 4) orelse key.len, needle);
}

test "a title's own name isn't taken for what's below it" {
    try std.testing.expectEqual(@as(?usize, 14), pastTitle("t/m/r/2010/v/-/r/-", "/r/"));
    try std.testing.expectEqual(@as(?usize, 10), pastTitle("t/s/e/2010/e/s01e02", "/e/"));
    try std.testing.expectEqual(@as(?usize, null), pastTitle("t/m/v/2010", "/v/"));
}

pub fn prefixSegments(key: []const u8, n: usize) ?usize {
    var count: usize = 0;
    for (key, 0..) |ch, i| if (ch == '/') {
        count += 1;
        if (count == n) return i;
    };
    return if (count == n - 1) key.len else null;
}

pub const Copy = struct {
    source: []const u8,
    path: []const u8,
    size: u64,
    mtime: []const u8,
    /// Under an unavailable directory of its source.
    unavailable: bool = false,
};

pub const Quality = struct {
    label: []const u8,
    copies: std.ArrayList(Copy) = .empty,
};

pub const Item = struct {
    /// The key below the title's (e.g., `e/s03e17`, `v/directors-cut`).
    key: []const u8,
    qualities: std.ArrayList(Quality) = .empty,
    /// This person's.
    progress: Progress = .{},
    /// Metadata: an episode's `title`, `description`, and `duration`.
    fields: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
};

/// Positions before this aren't kept as progress.
pub const kept_after_ms = 10_000;

pub const Progress = struct {
    position_ms: u64 = 0,
    duration_ms: u64 = 0,
    watched: bool = false,
};

pub fn progressKey(replica: *Replica, arena: std.mem.Allocator, item_key: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "p/{s}/{s}", .{ std.fmt.bytesToHex(replica.personKey(), .lower), item_key });
}

/// Records how far this person has played an item (its full key, e.g.,
/// `t/m/alien/1979/v/-`). Reaching the last 5% marks it watched, since end
/// credits aren't known yet; a position in the first 10 seconds isn't kept,
/// clearing any earlier one (but not the watched mark), so the item plays
/// from the start.
pub fn setProgress(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, item_key: []const u8, position_ms: u64, duration_ms: u64) !void {
    const key = try progressKey(replica, arena, item_key);
    if (position_ms < kept_after_ms)
        return replica.writePrivate(wall_ms, key, &.{ .{ "position", "" }, .{ "duration", "" } });
    const position = try std.fmt.allocPrint(arena, "{d}", .{position_ms});
    const duration = try std.fmt.allocPrint(arena, "{d}", .{duration_ms});
    if (duration_ms > 0 and position_ms * 100 >= duration_ms * 95)
        try replica.writePrivate(wall_ms, key, &.{ .{ "position", position }, .{ "duration", duration }, .{ "watched", "1" } })
    else
        try replica.writePrivate(wall_ms, key, &.{ .{ "position", position }, .{ "duration", duration } });
}

/// Marks an item watched, by hand.
pub fn markWatched(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, item_key: []const u8) !void {
    try replica.writePrivate(wall_ms, try progressKey(replica, arena, item_key), &.{.{ "watched", "1" }});
}

/// Marks an item unwatched, emptying where this person stopped too, so it
/// plays from the beginning.
pub fn markUnwatched(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, item_key: []const u8) !void {
    try replica.writePrivate(wall_ms, try progressKey(replica, arena, item_key), &.{ .{ "position", "" }, .{ "duration", "" }, .{ "watched", "0" } });
}

/// Removes this person's progress in an item: its position and watched mark.
pub fn removeProgress(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, item_key: []const u8) !void {
    try replica.writePrivate(wall_ms, try progressKey(replica, arena, item_key), &.{ .{ "position", "" }, .{ "duration", "" }, .{ "watched", "" } });
}

pub const ItemProgress = struct { item: []const u8, progress: Progress };

/// This person's progress, in progress or watched, by full item key, under
/// `title_key` if given.
pub fn progressOf(replica: *Replica, arena: std.mem.Allocator, title_key: ?[]const u8) ![]ItemProgress {
    var out: std.ArrayList(ItemProgress) = .empty;
    const prefix = try progressKey(replica, arena, title_key orelse "");
    const base = prefix.len - (if (title_key) |k| k.len else 0);
    const s = try replica.db.prepare("SELECT key, field, value FROM winners WHERE key >= ?1 AND key < ?2 ORDER BY key");
    defer s.finalize();
    try s.bindText(1, prefix);
    try s.bindText(2, try std.fmt.allocPrint(arena, "{s}\xff", .{prefix}));
    while (try s.step()) {
        const item = s.blob(0)[base..];
        if (title_key) |k| if (item.len <= k.len or item[k.len] != '/') continue;
        if (out.items.len == 0 or !std.mem.eql(u8, out.items[out.items.len - 1].item, item))
            try out.append(arena, .{ .item = try arena.dupe(u8, item), .progress = .{} });
        const h = &out.items[out.items.len - 1].progress;
        const field = s.blob(1);
        const value = s.blob(2);
        if (std.mem.eql(u8, field, "position")) h.position_ms = std.fmt.parseInt(u64, value, 10) catch 0;
        if (std.mem.eql(u8, field, "duration")) h.duration_ms = std.fmt.parseInt(u64, value, 10) catch 0;
        if (std.mem.eql(u8, field, "watched")) h.watched = std.mem.eql(u8, value, "1");
    }
    var kept: std.ArrayList(ItemProgress) = .empty;
    for (out.items) |e| if (e.progress.watched or e.progress.position_ms > 0) try kept.append(arena, e);
    return kept.items;
}

/// This person's progress under a title, by item key below the title's.
fn titleProgress(replica: *Replica, arena: std.mem.Allocator, title_key: []const u8) !std.StringHashMapUnmanaged(Progress) {
    var out: std.StringHashMapUnmanaged(Progress) = .empty;
    const prefix = try progressKey(replica, arena, title_key);
    const s = try replica.db.prepare("SELECT key, field, value FROM winners WHERE key > ?1 AND key < ?2");
    defer s.finalize();
    try s.bindText(1, try std.fmt.allocPrint(arena, "{s}/", .{prefix}));
    try s.bindText(2, try std.fmt.allocPrint(arena, "{s}0", .{prefix}));
    while (try s.step()) {
        const item = try arena.dupe(u8, s.blob(0)[prefix.len + 1 ..]);
        const gop = try out.getOrPut(arena, item);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const field = s.blob(1);
        const value = s.blob(2);
        if (std.mem.eql(u8, field, "position")) gop.value_ptr.position_ms = std.fmt.parseInt(u64, value, 10) catch 0;
        if (std.mem.eql(u8, field, "duration")) gop.value_ptr.duration_ms = std.fmt.parseInt(u64, value, 10) catch 0;
        if (std.mem.eql(u8, field, "watched")) gop.value_ptr.watched = std.mem.eql(u8, value, "1");
    }
    return out;
}

pub const Detail = struct {
    key: []const u8,
    name: []const u8 = "",
    year: ?u16 = null,
    items: std.ArrayList(Item) = .empty,
    /// Metadata and covers (see art.zig): `description`, `genre`,
    /// `released`, `network`, `art`, `art:s01`, and so on.
    fields: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
};

/// Everything the library holds about one title.
pub fn detail(replica: *Replica, arena: std.mem.Allocator, key: []const u8) !?Detail {
    var d: Detail = .{ .key = key };
    var found = false;
    const unavailable = try UnavailableDirs.load(replica, arena);
    var item_fields: std.StringHashMapUnmanaged(std.StringArrayHashMapUnmanaged([]const u8)) = .empty;
    const lower = try std.fmt.allocPrint(arena, "{s}/", .{key});
    const upper = try std.fmt.allocPrint(arena, "{s}0", .{key});
    const s = try replica.db.prepare("SELECT key, field, value FROM winners WHERE key = ?1 OR (key >= ?2 AND key < ?3) ORDER BY key, field");
    defer s.finalize();
    try s.bindText(1, key);
    try s.bindText(2, lower);
    try s.bindText(3, upper);
    while (try s.step()) {
        found = true;
        const k = s.blob(0);
        const field = s.blob(1);
        const value = s.blob(2);
        if (k.len == key.len) {
            if (std.mem.eql(u8, field, "name")) d.name = try arena.dupe(u8, value) //
            else if (std.mem.eql(u8, field, "year")) d.year = std.fmt.parseInt(u16, value, 10) catch null //
            else if (value.len > 0) try d.fields.put(arena, try arena.dupe(u8, field), try arena.dupe(u8, value));
            continue;
        }
        const r = pastTitle(k, "/r/") orelse {
            if (value.len > 0) {
                const gop = try item_fields.getOrPut(arena, try arena.dupe(u8, k[key.len + 1 ..]));
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.put(arena, try arena.dupe(u8, field), try arena.dupe(u8, value));
            }
            continue;
        };
        if (!std.mem.startsWith(u8, field, "held:") or value.len == 0) continue;
        const item_key = k[key.len + 1 .. r];
        if (d.items.items.len == 0 or !std.mem.eql(u8, d.items.items[d.items.items.len - 1].key, item_key))
            try d.items.append(arena, .{ .key = try arena.dupe(u8, item_key) });
        const item = &d.items.items[d.items.items.len - 1];
        const label = k[r + 3 ..];
        if (item.qualities.items.len == 0 or !std.mem.eql(u8, item.qualities.items[item.qualities.items.len - 1].label, label))
            try item.qualities.append(arena, .{ .label = try arena.dupe(u8, label) });
        var parts = std.mem.splitScalar(u8, value, '\t');
        const path = parts.first();
        const size = std.fmt.parseInt(u64, parts.next() orelse "0", 10) catch 0;
        const source = field["held:".len..];
        try item.qualities.items[item.qualities.items.len - 1].copies.append(arena, .{
            .source = try arena.dupe(u8, source),
            .path = try arena.dupe(u8, path),
            .size = size,
            .mtime = try arena.dupe(u8, parts.next() orelse ""),
            .unavailable = unavailable.has(source, value),
        });
    }
    if (!found) return null;
    const heads = try titleProgress(replica, arena, key);
    for (d.items.items) |*item| {
        if (heads.get(item.key)) |h| item.progress = h;
        if (item_fields.get(item.key)) |f| item.fields = f;
    }
    return d;
}

const testing = std.testing;

test "normalize and fold" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("house-md", try normalize(a, "House, M.D."));
    try testing.expectEqualStrings("house-md", try normalize(a, "House, MD"));
    try testing.expectEqualStrings("oceans-eleven", try normalize(a, "Ocean's Eleven"));
    try testing.expectEqualStrings("amélie", try normalize(a, "Amélie"));
    try testing.expectEqualStrings("amelie", try fold(a, "amélie"));
    try testing.expectEqualStrings("leon-1", try fold(a, try normalize(a, "Léon #1")));
}

test "keys follow parsed identity" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var scratch: [256]u8 = undefined;
    const movie = try keys(a, naming.parse("Salt (2010) - Director's Cut.m4v", &scratch));
    try testing.expectEqualStrings("t/m/salt/2010", movie.title);
    try testing.expectEqualStrings("t/m/salt/2010/v/directors-cut", movie.item);
    const episode = try keys(a, naming.parse("Friends/Friends 423 The One with Ross's Wedding.m4v", &scratch));
    try testing.expectEqualStrings("t/s/friends/-/e/s04e23", episode.item);
}

test "state: sources, progress, and members can be listed, set, and removed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const replica_ = @import("replica.zig");
    const founder = (try replica_.personKeyPair(@splat(1))).public_key.toBytes();
    var r = try Replica.open(std.testing.allocator, std.testing.io, ":memory:", founder, .from(@splat(1)));
    defer r.close();

    const id = try addSource(&r, 1000, "http://nas.local/Movies/", .{});
    const changed = try setQualityFrom(&r, arena, 2000, "http://nas.local/Movies", .{ .named = "4K HEVC" });
    try std.testing.expectEqualStrings("4K HEVC", changed.layout.quality.named);
    try std.testing.expectEqualStrings("4K HEVC", (try findSource(&r, arena, &id)).layout.quality.named);
    // By folder, the name goes; a newer device's setting is kept, unapplied.
    _ = try setQualityFrom(&r, arena, 3000, &id, .folder);
    try std.testing.expectEqual(QualityFrom.folder, (try findSource(&r, arena, &id)).layout.quality);
    try r.write(4000, try std.fmt.allocPrint(arena, "r/{s}", .{&id}), "quality-by", "file");
    try std.testing.expectEqual(QualityFrom.unknown, (try findSource(&r, arena, &id)).layout.quality);
    try std.testing.expectEqualStrings("", (try findSource(&r, arena, &id)).layout.skip);

    try setProgress(&r, arena, 5000, "t/m/network-effect/2020/v/-", 60_000, 6_000_000);
    try markWatched(&r, arena, 6000, "t/s/worldhoppers/-/e/s01e02");
    try std.testing.expectEqual(@as(usize, 2), (try progressOf(&r, arena, null)).len);
    const one = try progressOf(&r, arena, "t/m/network-effect/2020");
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqualStrings("t/m/network-effect/2020/v/-", one[0].item);
    try std.testing.expectEqual(@as(u64, 60_000), one[0].progress.position_ms);
    try std.testing.expectEqual(@as(usize, 0), (try progressOf(&r, arena, "t/m/network")).len);
    // Back within the first 10 seconds: the progress isn't kept.
    try setProgress(&r, arena, 6500, "t/m/network-effect/2020/v/-", 9_000, 6_000_000);
    try std.testing.expectEqual(@as(usize, 0), (try progressOf(&r, arena, "t/m/network-effect/2020")).len);
    try removeProgress(&r, arena, 7000, "t/m/network-effect/2020/v/-");
    try std.testing.expectEqual(@as(usize, 1), (try progressOf(&r, arena, null)).len);
    // Marked unwatched: where it stopped is forgotten too.
    try setProgress(&r, arena, 7100, "t/m/network-effect/2020/v/-", 600_000, 6_000_000);
    try markUnwatched(&r, arena, 7200, "t/m/network-effect/2020/v/-");
    try std.testing.expectEqual(@as(usize, 0), (try progressOf(&r, arena, "t/m/network-effect/2020")).len);

    const other = (try replica_.personKeyPair(@splat(2))).public_key.toBytes();
    try r.addMember(8000, other);
    try std.testing.expectEqual(@as(usize, 2), (try r.members(arena)).len);
    try r.removeMember(9000, other);
    try std.testing.expectEqual(@as(usize, 1), (try r.members(arena)).len);
}

test "a numberless file beside a series' episodes is its special, not a movie" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = "http://nas/";
    const entries = [_]crawl.Entry{
        .{ .url = "http://nas/Babylon%205/Babylon%205%20101%20Midnight.m4v", .parent = "http://nas/Babylon%205/", .is_dir = false, .size = 1, .mtime = "" },
        .{ .url = "http://nas/Babylon%205/Babylon%205%20The%20Gathering.m4v", .parent = "http://nas/Babylon%205/", .is_dir = false, .size = 1, .mtime = "" },
        .{ .url = "http://nas/Firefly/Season%2001/Firefly%20-%20S01E01.mkv", .parent = "http://nas/Firefly/Season%2001/", .is_dir = false, .size = 1, .mtime = "" },
    };
    const series = try seriesByFolder(arena, base, .{}, &entries);
    const special = try parseFile(arena, "Babylon 5/Babylon 5 The Gathering.m4v", &series);
    try std.testing.expectEqual(naming.Kind.episode, special.kind);
    try std.testing.expectEqualStrings("The Gathering", special.special.?);
    try std.testing.expectEqualStrings("t/s/babylon-5/-/e/s00-the-gathering", (try keys(arena, special)).item);
    const dated = try parseFile(arena, "Kurzgesagt/Kurzgesagt 2024-03-12 [youtube-ab_2019-xyz].mp4", &series);
    try std.testing.expectEqualStrings("t/s/kurzgesagt/-/e/s2024e0312", (try keys(arena, dated)).item);
    const specials_folder = try parseFile(arena, "Firefly/Specials/Firefly Here Is How It Was.mkv", &series);
    try std.testing.expectEqualStrings("Here Is How It Was", specials_folder.special.?);
    // A movie in its own folder stays one.
    const movie = try parseFile(arena, "Movies/Alien (1979)/Alien (1979).mkv", &series);
    try std.testing.expectEqual(naming.Kind.movie, movie.kind);
}

/// A person's or device's name: `n/<key>`'s `name`, and for a device, `person`,
/// its person's key. Any member may set one; devices show names, not keys.
pub const Name = struct {
    key: []const u8,
    name: []const u8,
    /// A device's person; null for a person's own name.
    person: ?[]const u8 = null,
    /// A device's model, as it says ("iPhone 13 mini"), if it has.
    model: ?[]const u8 = null,
    /// Where a device serves its own sources (`cqdevice://`, see url.zig)
    /// now, as it says (`http://firefly.local:58275/`): one field, written
    /// again as its port changes, rather than every copy of theirs.
    served: ?[]const u8 = null,
};

/// Records device `key`'s model (`model.shown`'s), beside its name,
/// unless it's recorded so already, as a device does as it starts.
pub fn recordModel(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, key: [32]u8, model: []const u8) !void {
    if (model.len == 0 or model.len > 200) return;
    const hex = std.fmt.bytesToHex(key, .lower);
    for (try names(replica, arena)) |n| if (std.mem.eql(u8, n.key, &hex)) if (n.model) |m| if (std.mem.eql(u8, m, model)) return;
    try replica.write(wall_ms, try std.fmt.allocPrint(arena, "n/{s}", .{hex}), "model", model);
}

/// Records where device `key` serves its own sources now (`Name.served`),
/// unless it's recorded so already, as a device does as it starts serving:
/// one field as its port changes, its sources' addresses unchanged.
pub fn recordServed(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, key: [32]u8, served: []const u8) !void {
    if (!url.fitForSource(served) or url.device(served) != null or !std.mem.endsWith(u8, served, "/")) return error.BadAddress;
    const hex = std.fmt.bytesToHex(key, .lower);
    for (try names(replica, arena)) |n| if (std.mem.eql(u8, n.key, &hex)) if (n.served) |s| if (std.mem.eql(u8, s, served)) return;
    try replica.write(wall_ms, try std.fmt.allocPrint(arena, "n/{s}", .{hex}), "served", served);
}

/// Names a person, or a device (with its person's key).
pub fn setName(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, key: [32]u8, name: []const u8, person: ?[32]u8) !void {
    const k = try std.fmt.allocPrint(arena, "n/{s}", .{std.fmt.bytesToHex(key, .lower)});
    try replica.write(wall_ms, k, "name", std.mem.trim(u8, name, " \t\n"));
    if (person) |u| try replica.write(wall_ms, k, "user", &std.fmt.bytesToHex(u, .lower));
}

/// Every name set, people's and devices'. A device's person (`user`) is
/// taken only as one of that person's own devices wrote it, or its
/// certificate says: any member may write a name, and a device counted as
/// someone's could keep them from handing the library over as they leave.
pub fn names(replica: *Replica, arena: std.mem.Allocator) ![]Name {
    var out: std.ArrayList(Name) = .empty;
    const s = try replica.db.prepare("SELECT key, field, value, device FROM winners WHERE key >= 'n/' AND key < 'n0' AND length(value) > 0 ORDER BY key");
    defer s.finalize();
    while (try s.step()) {
        const key = s.blob(0)["n/".len..];
        if (out.items.len == 0 or !std.mem.eql(u8, out.items[out.items.len - 1].key, key))
            try out.append(arena, .{ .key = try arena.dupe(u8, key), .name = "" });
        const n = &out.items[out.items.len - 1];
        const value = try arena.dupe(u8, s.blob(2));
        if (std.mem.eql(u8, s.blob(1), "name")) {
            n.name = value;
        } else if (std.mem.eql(u8, s.blob(1), "user")) {
            if (try ownedBy(replica, try replica.keyOf(s.int(3)), key, value)) n.person = value;
        } else if (std.mem.eql(u8, s.blob(1), "model")) {
            // As the device says of itself, as no other knows it.
            if (std.mem.eql(u8, &std.fmt.bytesToHex(try replica.keyOf(s.int(3)), .lower), key)) n.model = value;
        } else if (std.mem.eql(u8, s.blob(1), "served")) {
            // Its own word alone, as another's could aim its sources
            // anywhere.
            if (std.mem.eql(u8, &std.fmt.bytesToHex(try replica.keyOf(s.int(3)), .lower), key)) n.served = value;
        }
    }
    return out.items;
}

/// Whether `person` (hex) is the one `writer` acts for, or the one the
/// certificate of `device` (hex) names.
fn ownedBy(replica: *Replica, writer: [32]u8, device: []const u8, person: []const u8) !bool {
    // Whole keys alone: a short one would leave bytes unwritten.
    var claimed: [32]u8 = undefined;
    if ((std.fmt.hexToBytes(&claimed, person) catch return false).len != claimed.len) return false;
    if (try replica.certifiedPerson(writer, &.{})) |p| if (std.mem.eql(u8, &p, &claimed)) return true;
    var key: [32]u8 = undefined;
    if ((std.fmt.hexToBytes(&key, device) catch return false).len != key.len) return false;
    const p = try replica.certifiedPerson(key, &.{}) orelse return false;
    return std.mem.eql(u8, &p, &claimed);
}

/// The name of `key` (hex), if set.
pub fn nameOf(list: []const Name, key: []const u8) ?[]const u8 {
    for (list) |n| if (std.mem.eql(u8, n.key, key) and n.name.len > 0) return n.name;
    return null;
}

test "people and devices are named, a device with its person" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const founder = (try @import("replica.zig").personKeyPair(@splat(1))).public_key.toBytes();
    var r = try Replica.open(std.testing.allocator, std.testing.io, ":memory:", founder, .from(@splat(1)));
    defer r.close();
    try setName(&r, arena, 1, founder, " Brian ", null);
    try setName(&r, arena, 2, r.device(), "Brian's MacBook Pro", founder);
    const list = try names(&r, arena);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("Brian", nameOf(list, &std.fmt.bytesToHex(founder, .lower)).?);
    const device = std.fmt.bytesToHex(r.device(), .lower);
    for (list) |n| if (std.mem.eql(u8, n.key, &device)) try std.testing.expectEqualStrings(&std.fmt.bytesToHex(founder, .lower), n.person.?);
}
