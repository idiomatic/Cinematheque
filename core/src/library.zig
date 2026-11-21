//! The library's domain on top of the replica: keys derived from titles'
//! parsed identities, sources and their layouts, copies ingested
//! from crawls, the review of close matches and aliases, and progress.
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
//! * `aliases`: field `<title key>`, value the title key it's an alias of,
//!   or empty if none.
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
    /// The quality of every file in the source (e.g., a HandBrake
    /// preset's name), or empty if unknown. Reading it from the files
    /// themselves (e.g., an MP4's tracks) is to come. Stored as the
    /// source's `rendition` field, its name kept as data.
    quality: []const u8 = "",
    /// Names starting with this are skipped (e.g., housekeeping folders), or
    /// none if empty.
    skip: []const u8 = ",",
    /// Each file's quality is the first folder within the source, named as
    /// it is (`Movies/HQ 1080p30 Surround/Alien (1979).m4v`), and that
    /// folder isn't read as part of the file's name. Stored as the source's
    /// `quality-by` field, `folder`.
    by_folder: bool = false,
};

/// How a source's file is read: the path to parse, and its quality folder,
/// if the source names qualities by folder.
pub const Named = struct { path: []const u8, folder: ?[]const u8 };

pub fn named(layout: Layout, rel: []const u8) Named {
    if (!layout.by_folder) return .{ .path = rel, .folder = null };
    const slash = std.mem.indexOfScalar(u8, rel, '/') orelse return .{ .path = rel, .folder = null };
    return .{ .path = rel[slash + 1 ..], .folder = rel[0..slash] };
}

pub const Source = struct {
    id: [16]u8,
    url: []const u8,
    layout: Layout,
    /// A device's downloads (`managed`, see download.zig): its copies are
    /// written as files are fetched, onto the qualities they came from, so
    /// it isn't crawled.
    managed: bool = false,
    /// When a device last crawled it whole (`crawled`, wall-clock
    /// milliseconds), so others who've synced since needn't again soon.
    crawled_ms: u64 = 0,

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
        const rel = named(layout, relativeOrNull(arena, base, entry.url) orelse continue).path;
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
    try replica.write(wall_ms, key, "rendition", layout.quality);
    try replica.write(wall_ms, key, "skip", layout.skip);
    if (layout.by_folder) try replica.write(wall_ms, key, "quality-by", "folder");
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

/// Changes a source's settings, those given. Copies move to a new
/// quality at the next crawl.
pub fn setSource(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, which: []const u8, quality: ?[]const u8, skip: ?[]const u8, by_folder: ?bool) !Source {
    var source = try findSource(replica, arena, which);
    const key = try std.fmt.allocPrint(arena, "r/{s}", .{source.id});
    try replica.begin();
    errdefer replica.rollback();
    if (quality) |v| {
        try replica.write(wall_ms, key, "rendition", v);
        source.layout.quality = v;
    }
    if (skip) |v| {
        try replica.write(wall_ms, key, "skip", v);
        source.layout.skip = v;
    }
    if (by_folder) |v| {
        try replica.write(wall_ms, key, "quality-by", if (v) "folder" else "");
        source.layout.by_folder = v;
    }
    try replica.commit();
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

/// Crawls a source, reusing this device's last crawl of it where its
/// directories haven't changed, brings the library's copies in line with
/// what it found, and keeps the crawl for next time. Describing what it
/// found is separate (see `art.plan` and `art.run`), so its titles show
/// before their covers.
pub fn crawlSource(replica: *Replica, io: Io, arena: std.mem.Allocator, client: *std.http.Client, wall_ms: u64, source: Source, workers: usize) !CrawlStats {
    const key = try snapshotKey(arena, source.id);
    var prev: ?crawl.Snapshot = null;
    if (try replica.local(arena, key)) |saved| prev = try crawl.Snapshot.init(arena, try crawl.Snapshot.load(arena, saved));
    var entries: std.ArrayList(crawl.Entry) = .empty;
    const start = Io.Timestamp.now(io, .awake);
    const result = try crawl.crawl(io, arena, client, source.url, .{
        .workers = workers,
        .prev = if (prev) |*p| p else null,
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

pub fn sources(replica: *Replica, arena: std.mem.Allocator) ![]Source {
    var out: std.ArrayList(Source) = .empty;
    const s = try replica.db.prepare("SELECT key, field, value FROM winners WHERE key >= 'r/' AND key < 'r0' ORDER BY key");
    defer s.finalize();
    while (try s.step()) {
        const key = s.blob(0);
        if (key.len != 18) continue;
        if (out.items.len == 0 or !std.mem.eql(u8, &out.items[out.items.len - 1].id, key[2..18]))
            try out.append(arena, .{ .id = key[2..18].*, .url = "", .layout = .{} });
        const r = &out.items[out.items.len - 1];
        const field = s.blob(1);
        const value = try arena.dupe(u8, s.blob(2));
        if (std.mem.eql(u8, field, "url")) r.url = value //
        else if (std.mem.eql(u8, field, "rendition")) r.layout.quality = value //
        else if (std.mem.eql(u8, field, "skip")) r.layout.skip = value //
        else if (std.mem.eql(u8, field, "quality-by")) r.layout.by_folder = std.mem.eql(u8, value, "folder") //
        else if (std.mem.eql(u8, field, "managed")) r.managed = value.len > 0 //
        else if (std.mem.eql(u8, field, "crawled")) r.crawled_ms = std.fmt.parseInt(u64, value, 10) catch 0;
    }
    // Dropped sources have no URL, and one whose URL isn't fit to fetch
    // from (as any member could write) is none.
    var kept: std.ArrayList(Source) = .empty;
    for (out.items) |r| if (url.fitForSource(r.url)) try kept.append(arena, r);
    return kept.items;
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
    const series = try seriesByFolder(arena, source.url, source.layout, entries);
    for (entries) |entry| {
        if (entry.is_dir) continue;
        stats.files += 1;
        const rel = relativeOrNull(arena, source.url, entry.url) orelse continue;
        if (skipped(rel, source.layout.skip)) {
            stats.skipped += 1;
            continue;
        }
        const as = named(source.layout, rel);
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
        // misnamed); keep both, numbered, and count them for review.
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
        const rel = relativeOrNull(arena, source.url, entry.url) orelse continue;
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
    if (folder) |f| return normalize(arena, f);
    if (layout.quality.len > 0) return normalize(arena, layout.quality);
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
    kind: u8,
    name: []const u8,
    year: ?u16,
    /// Episodes or versions below it.
    items: usize = 0,
    /// Qualities held by at least one source.
    qualities: usize = 0,
    /// Distinct quality labels held.
    labels: std.ArrayList([]const u8) = .empty,
    /// The title it's an alias of, if any.
    alias: ?[]const u8 = null,
};

/// Every title, with counts of its items and held qualities.
pub fn titles(replica: *Replica, arena: std.mem.Allocator) ![]Title {
    var alias_of: std.StringHashMapUnmanaged([]const u8) = .empty;
    {
        const s = try replica.db.prepare("SELECT field, value FROM winners WHERE key = 'aliases' AND length(value) > 0");
        defer s.finalize();
        while (try s.step()) try alias_of.put(arena, try arena.dupe(u8, s.blob(0)), try arena.dupe(u8, s.blob(1)));
    }
    var out: std.ArrayList(Title) = .empty;
    var last_item: []const u8 = "";
    const s = try replica.db.prepare("SELECT key, field, value FROM winners WHERE key >= 't/' AND key < 't0' ORDER BY key");
    defer s.finalize();
    while (try s.step()) {
        const key = s.blob(0);
        const title_len = prefixSegments(key, 4) orelse continue;
        if (out.items.len == 0 or !std.mem.eql(u8, out.items[out.items.len - 1].key, key[0..title_len])) {
            const tk = try arena.dupe(u8, key[0..title_len]);
            try out.append(arena, .{ .key = tk, .kind = key[2], .name = "", .year = null, .alias = alias_of.get(tk) });
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

/// Marks an item watched or not, by hand.
/// Marks an item watched, or not; unwatched forgets where this person
/// stopped too, so it plays from the beginning.
pub fn setWatched(replica: *Replica, arena: std.mem.Allocator, wall_ms: u64, item_key: []const u8, watched: bool) !void {
    const key = try progressKey(replica, arena, item_key);
    if (watched) return replica.writePrivate(wall_ms, key, &.{.{ "watched", "1" }});
    try replica.writePrivate(wall_ms, key, &.{ .{ "position", "" }, .{ "duration", "" }, .{ "watched", "0" } });
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
    /// The title this one is an alias of, if any.
    alias_of: ?[]const u8 = null,
    /// Titles that are aliases of this one.
    aliases: std.ArrayList([]const u8) = .empty,
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
    {
        const s = try replica.db.prepare("SELECT field, value FROM winners WHERE key = 'aliases' AND length(value) > 0 AND (field = ?1 OR value = CAST(?1 AS BLOB))");
        defer s.finalize();
        try s.bindText(1, key);
        while (try s.step()) {
            if (std.mem.eql(u8, s.blob(0), key)) d.alias_of = try arena.dupe(u8, s.blob(1)) //
            else try d.aliases.append(arena, try arena.dupe(u8, s.blob(0)));
        }
    }
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

pub const Match = struct {
    a: []const u8,
    b: []const u8,
    reason: []const u8,
};

/// Pairs of titles whose keys nearly agree: the same title with a year off
/// by one, with transposed digits, or missing; or the same year with a
/// title spelled slightly differently, or differing only in diacritics.
pub fn closeMatches(arena: std.mem.Allocator, all: []const Title) ![]Match {
    const Info = struct { t: *const Title, norm: []const u8, folded: []const u8 };
    var infos: std.ArrayList(Info) = .empty;
    for (all) |*t| {
        // Titles aliased already, or held by no source (e.g., one
        // dropped), aren't for review.
        if (t.alias != null or t.qualities == 0) continue;
        const parts = std.mem.splitScalar(u8, t.key, '/');
        var it = parts;
        _ = it.next();
        _ = it.next();
        const norm = it.next() orelse continue;
        try infos.append(arena, .{ .t = t, .norm = norm, .folded = try fold(arena, norm) });
    }
    var by_folded: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty;
    var by_year: std.AutoHashMapUnmanaged(u32, std.ArrayList(usize)) = .empty;
    for (infos.items, 0..) |info, i| {
        const f = try by_folded.getOrPut(arena, info.folded);
        if (!f.found_existing) f.value_ptr.* = .empty;
        try f.value_ptr.append(arena, i);
        const y = try by_year.getOrPut(arena, (@as(u32, info.t.kind) << 16) | (info.t.year orelse 0));
        if (!y.found_existing) y.value_ptr.* = .empty;
        try y.value_ptr.append(arena, i);
    }
    var out: std.ArrayList(Match) = .empty;
    var fit = by_folded.valueIterator();
    while (fit.next()) |group| for (group.items, 0..) |i, n| for (group.items[n + 1 ..]) |j| {
        const a = infos.items[i];
        const b = infos.items[j];
        if (a.t.kind != b.t.kind) continue;
        const reason = if (!std.mem.eql(u8, a.norm, b.norm) and a.t.year == b.t.year)
            "diacritics"
        else
            yearReason(a.t.year, b.t.year) orelse continue;
        try out.append(arena, .{ .a = a.t.key, .b = b.t.key, .reason = reason });
    };
    var yit = by_year.valueIterator();
    while (yit.next()) |group| for (group.items, 0..) |i, n| for (group.items[n + 1 ..]) |j| {
        const a = infos.items[i];
        const b = infos.items[j];
        if (std.mem.eql(u8, a.folded, b.folded) or @min(a.folded.len, b.folded.len) < 6) continue;
        // Numbers tell sequels and seasons apart ("rocky-2", "rocky-3").
        if (!sameDigits(a.folded, b.folded)) continue;
        if (editDistance(a.folded, b.folded, 2) <= 2) try out.append(arena, .{ .a = a.t.key, .b = b.t.key, .reason = "spelling" });
    };
    return out.items;
}

fn sameDigits(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and !std.ascii.isDigit(a[i])) i += 1;
        while (j < b.len and !std.ascii.isDigit(b[j])) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (a[i] != b[j]) return false;
        i += 1;
        j += 1;
    }
}

fn yearReason(a: ?u16, b: ?u16) ?[]const u8 {
    const x = a orelse return if (b != null) "year missing" else null;
    const y = b orelse return "year missing";
    if (x == y) return null;
    if (@max(x, y) - @min(x, y) == 1) return "year off by one";
    var xs: [4]u8 = undefined;
    var ys: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&xs, "{d:0>4}", .{x}) catch return null;
    _ = std.fmt.bufPrint(&ys, "{d:0>4}", .{y}) catch return null;
    var diffs: [4]usize = undefined;
    var n: usize = 0;
    for (0..4) |i| if (xs[i] != ys[i]) {
        diffs[n] = i;
        n += 1;
    };
    if (n == 2 and diffs[1] == diffs[0] + 1 and xs[diffs[0]] == ys[diffs[1]] and xs[diffs[1]] == ys[diffs[0]]) return "year digits transposed";
    return null;
}

/// Levenshtein distance, giving up past `limit`.
fn editDistance(a: []const u8, b: []const u8, limit: usize) usize {
    if (@max(a.len, b.len) - @min(a.len, b.len) > limit) return limit + 1;
    if (b.len > 255) return limit + 1;
    var prev: [256]usize = undefined;
    var cur: [256]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        var best = cur[0];
        for (b, 0..) |cb, j| {
            cur[j + 1] = @min(@min(prev[j + 1] + 1, cur[j] + 1), prev[j] + @intFromBool(ca != cb));
            best = @min(best, cur[j + 1]);
        }
        if (best > limit) return limit + 1;
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

/// Qualities held twice by one source: two files that parsed alike,
/// such as a mislabeled episode or a copy, as `key` and `value` pairs.
pub fn duplicates(replica: *Replica, arena: std.mem.Allocator) ![]Match {
    var out: std.ArrayList(Match) = .empty;
    const s = try replica.db.prepare(
        \\SELECT d.key, d.value, o.value FROM winners d
        \\JOIN winners o ON o.key = substr(d.key, 1, instr(d.key, '~') - 1) AND o.field = d.field
        \\WHERE d.key LIKE 't/%~%' AND d.field LIKE 'held:%' AND length(d.value) > 0
        \\ORDER BY d.key
    );
    defer s.finalize();
    while (try s.step()) {
        const first = s.blob(2);
        const second = s.blob(1);
        try out.append(arena, .{
            .reason = "duplicate",
            .a = try arena.dupe(u8, first[0 .. std.mem.indexOfScalar(u8, first, '\t') orelse first.len]),
            .b = try arena.dupe(u8, second[0 .. std.mem.indexOfScalar(u8, second, '\t') orelse second.len]),
        });
    }
    return out.items;
}

/// Records `from` as an alias of `to`, so every device merges them alike.
/// Records `from` as an alias of `to`: two names of one title.
pub fn addAlias(replica: *Replica, wall_ms: u64, from: []const u8, to: []const u8) !void {
    if (std.mem.eql(u8, from, to)) return error.SameTitle;
    try replica.write(wall_ms, "aliases", from, to);
}

/// Stops `from` being an alias of another title.
pub fn removeAlias(replica: *Replica, wall_ms: u64, from: []const u8) !void {
    try replica.write(wall_ms, "aliases", from, "");
}

pub const Alias = struct { from: []const u8, to: []const u8 };

pub fn aliases(replica: *Replica, arena: std.mem.Allocator) ![]Alias {
    var out: std.ArrayList(Alias) = .empty;
    const s = try replica.db.prepare("SELECT field, value FROM winners WHERE key = 'aliases' AND length(value) > 0 ORDER BY field");
    defer s.finalize();
    while (try s.step()) try out.append(arena, .{ .from = try arena.dupe(u8, s.blob(0)), .to = try arena.dupe(u8, s.blob(1)) });
    return out.items;
}

pub const Facet = struct { facet: []const u8, value: []const u8, count: usize };

/// Counts of titles by kind, decade, and quality held.
pub fn facets(arena: std.mem.Allocator, all: []const Title) ![]Facet {
    var counts: std.StringArrayHashMapUnmanaged(usize) = .empty;
    for (all) |t| {
        if (t.alias != null or t.qualities == 0) continue;
        try bump(arena, &counts, if (t.kind == 's') "kind\tseries" else "kind\tmovie");
        if (t.year) |y| try bump(arena, &counts, try std.fmt.allocPrint(arena, "decade\t{d}s", .{y / 10 * 10}));
        for (t.labels.items) |l| try bump(arena, &counts, try std.fmt.allocPrint(arena, "quality\t{s}", .{l}));
    }
    var out: std.ArrayList(Facet) = .empty;
    var it = counts.iterator();
    while (it.next()) |e| {
        const tab = std.mem.indexOfScalar(u8, e.key_ptr.*, '\t').?;
        try out.append(arena, .{ .facet = e.key_ptr.*[0..tab], .value = e.key_ptr.*[tab + 1 ..], .count = e.value_ptr.* });
    }
    std.mem.sort(Facet, out.items, {}, struct {
        fn lessThan(_: void, a: Facet, b: Facet) bool {
            const o = std.mem.order(u8, a.facet, b.facet);
            return if (o != .eq) o == .lt else std.mem.order(u8, a.value, b.value) == .lt;
        }
    }.lessThan);
    return out.items;
}

fn bump(arena: std.mem.Allocator, counts: *std.StringArrayHashMapUnmanaged(usize), key: []const u8) !void {
    const gop = try counts.getOrPut(arena, key);
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* += 1;
}

const testing = std.testing;

test "a crawl records when it was, so refreshes not asked for skip it for a day" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "Alien (1979).mp4", .data = "x" });
    var server: @import("host.zig").Host = .{ .io = io, .gpa = gpa, .options = .{ .port = 0, .mounts = &.{.{ .path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path}), .index = false }} } };
    try server.start();
    defer server.stop();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const founder: [32]u8 = (try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(1))).public_key.toBytes();
    var r = try Replica.open(gpa, io, ":memory:", founder, .from(@splat(1)));
    defer r.close();
    _ = try addSource(&r, 1, try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/", .{server.port}), .{});
    try std.testing.expectEqual(@as(?u64, 24), try crawlEvery(&r, arena));
    try setCrawlEvery(&r, 2, 0);
    try std.testing.expectEqual(@as(?u64, null), try crawlEvery(&r, arena));
    try setCrawlEvery(&r, 3, 3);
    try std.testing.expectEqual(@as(?u64, 3), try crawlEvery(&r, arena));
    const window = crawlWindow(io, 24);
    try std.testing.expect(window >= 23 * 3600 * 1000 and window <= 25 * 3600 * 1000);
    try std.testing.expect(!(try sources(&r, arena))[0].crawledLately(1000, window));
    const at: u64 = 1_000_000;
    _ = try crawlSource(&r, io, arena, &client, at, (try sources(&r, arena))[0], 4);
    const source = (try sources(&r, arena))[0];
    try std.testing.expectEqual(at, source.crawled_ms);
    try std.testing.expect(source.crawledLately(at + window - 1, window));
    try std.testing.expect(!source.crawledLately(at + window, window));
}

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

test "qualities come from the source, or else from the file's name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Parses share nothing with each other but their scratch space.
    var scratch: [3][512]u8 = undefined;
    const sd = naming.parse("Movies/Alien (1979)/Alien (1979) - 720p.mkv", &scratch[0]);
    const uhd = naming.parse("Movies/Alien (1979)/Alien (1979) - 4K HDR.mkv", &scratch[1]);
    try testing.expectEqualStrings((try keys(a, sd)).item, (try keys(a, uhd)).item);
    try testing.expectEqualStrings("720p", try qualityOf(a, .{}, sd, null));
    try testing.expectEqualStrings("2160p-hdr", try qualityOf(a, .{}, uhd, null));
    try testing.expectEqualStrings("very-fast-720p30", try qualityOf(a, .{ .quality = "Very Fast 720p30" }, uhd, null));
    try testing.expectEqualStrings("-", try qualityOf(a, .{}, naming.parse("Alien (1979).mkv", &scratch[2]), null));
    // A source naming qualities by folder: the first folder is the quality,
    // and isn't read as the file's name.
    const by_folder: Layout = .{ .by_folder = true };
    const as = named(by_folder, "HQ 1080p30 Surround/Firefly/Season 01/Firefly S01E02.m4v");
    try testing.expectEqualStrings("Firefly/Season 01/Firefly S01E02.m4v", as.path);
    try testing.expectEqualStrings("hq-1080p30-surround", try qualityOf(a, by_folder, naming.parse(as.path, &scratch[2]), as.folder));
    try testing.expectEqual(@as(?[]const u8, null), named(by_folder, "Alien (1979).m4v").folder);
    try testing.expectEqual(@as(?[]const u8, null), named(.{}, "HQ/Alien (1979).m4v").folder);
}

test "close matches" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const all = [_]Title{
        .{ .key = "t/m/amélie/2001", .kind = 'm', .name = "Amélie", .year = 2001, .qualities = 1 },
        .{ .key = "t/m/amelie/2001", .kind = 'm', .name = "Amelie", .year = 2001, .qualities = 1 },
        .{ .key = "t/m/heat/1995", .kind = 'm', .name = "Heat", .year = 1995, .qualities = 1 },
        .{ .key = "t/m/heat/1959", .kind = 'm', .name = "Heat", .year = 1959, .qualities = 1 },
        .{ .key = "t/m/gattaca/1997", .kind = 'm', .name = "Gattaca", .year = 1997, .qualities = 1 },
        .{ .key = "t/m/gatacca/1997", .kind = 'm', .name = "Gatacca", .year = 1997, .qualities = 1 },
        .{ .key = "t/m/alien/1979", .kind = 'm', .name = "Alien", .year = 1979, .qualities = 1 },
        .{ .key = "t/m/alien/1980", .kind = 'm', .name = "Alien", .year = 1980, .qualities = 1 },
        .{ .key = "t/m/aliens/1986", .kind = 'm', .name = "Aliens", .year = 1986, .qualities = 1 },
        .{ .key = "t/m/rocky-2/1979", .kind = 'm', .name = "Rocky 2", .year = 1979, .qualities = 1 },
        .{ .key = "t/m/rocky-3/1979", .kind = 'm', .name = "Rocky 3", .year = 1979, .qualities = 1 },
    };
    const matches = try closeMatches(a, &all);
    // Held by no source, so not for review.
    const unheld = [_]Title{ all[2], .{ .key = "t/m/heat/1996", .kind = 'm', .name = "Heat", .year = 1996 } };
    try testing.expectEqual(@as(usize, 0), (try closeMatches(a, &unheld)).len);
    var reasons: std.StringHashMapUnmanaged(void) = .empty;
    for (matches) |m| try reasons.put(a, m.reason, {});
    try testing.expectEqual(@as(usize, 4), matches.len);
    for ([_][]const u8{ "diacritics", "year digits transposed", "spelling", "year off by one" }) |r| try testing.expect(reasons.contains(r));
}

test "year reasons" {
    try testing.expectEqualStrings("year off by one", yearReason(1999, 2000).?);
    try testing.expectEqualStrings("year digits transposed", yearReason(1995, 1959).?);
    try testing.expect(yearReason(1995, 1975) == null);
}

test "an unplugged directory is unavailable, its copies kept; a deleted one's go" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const replica_ = @import("replica.zig");
    const founder = (try replica_.personKeyPair(@splat(1))).public_key.toBytes();
    var r = try Replica.open(gpa, io, ":memory:", founder, .from(@splat(1)));
    defer r.close();

    // Two drives' mount points, served without an INDEX, so listings stay live.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "a");
    try tmp.dir.createDirPath(io, "b");
    try tmp.dir.writeFile(io, .{ .sub_path = "a/Alien (1979).mp4", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b/Brazil (1985).mp4", .data = "x" });
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var server: @import("host.zig").Host = .{ .io = io, .gpa = gpa, .options = .{ .port = 0, .mounts = &.{.{ .path = root, .index = false }} } };
    try server.start();
    defer server.stop();
    _ = try addSource(&r, 1000, try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/", .{server.port}), .{});
    const source = (try sources(&r, arena))[0];
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const t = std.testing;
    // Each crawl reads every listing afresh: within one second, a reused
    // one would look unchanged.
    const Fresh = struct {
        fn crawl(rr: *Replica, io_: Io, a: std.mem.Allocator, c: *std.http.Client, wall: u64, rp: Source) !CrawlStats {
            try rr.removeLocal(try snapshotKey(a, rp.id));
            return crawlSource(rr, io_, a, c, wall, rp, 1);
        }
    };

    _ = try Fresh.crawl(&r, io, arena, &client, 2000, source);
    try t.expectEqual(@as(i64, 2), try countCopies(&r, arena, source));
    // b unplugged: its mount point lists empty. One marker; its copy kept.
    try tmp.dir.deleteFile(io, "b/Brazil (1985).mp4");
    var stats = (try Fresh.crawl(&r, io, arena, &client, 3000, source)).ingest;
    try t.expectEqual(@as(usize, 1), stats.unavailable);
    try t.expectEqual(@as(usize, 0), stats.copies_removed);
    try t.expectEqual(@as(i64, 2), try countCopies(&r, arena, source));
    var gone = try unavailableDirs(&r, arena, &source.id);
    try t.expectEqual(@as(usize, 1), gone.len);
    try t.expectEqualStrings("b", gone[0].dir);
    try t.expectEqual(@as(u64, 3000), gone[0].since_ms);
    const shown = (try detail(&r, arena, "t/m/brazil/1985")).?;
    try t.expect(shown.items.items[0].qualities.items[0].copies.items[0].unavailable);
    // Plugged back in: the marker goes, and nothing else changes.
    try tmp.dir.writeFile(io, .{ .sub_path = "b/Brazil (1985).mp4", .data = "x" });
    stats = (try Fresh.crawl(&r, io, arena, &client, 4000, source)).ingest;
    try t.expectEqual(@as(usize, 0), stats.unavailable);
    try t.expectEqual(@as(usize, 0), stats.copies_added + stats.copies_changed);
    try t.expectEqual(@as(usize, 0), (try unavailableDirs(&r, arena, &source.id)).len);
    // Deleted, b leaves its parent's listing, and its copy goes.
    try tmp.dir.deleteFile(io, "b/Brazil (1985).mp4");
    try tmp.dir.deleteDir(io, "b");
    stats = (try Fresh.crawl(&r, io, arena, &client, 5000, source)).ingest;
    try t.expectEqual(@as(usize, 1), stats.copies_removed);
    try t.expectEqual(@as(i64, 1), try countCopies(&r, arena, source));
    // The whole source listing nothing is the root unavailable.
    try tmp.dir.deleteFile(io, "a/Alien (1979).mp4");
    stats = (try Fresh.crawl(&r, io, arena, &client, 6000, source)).ingest;
    gone = try unavailableDirs(&r, arena, &source.id);
    try t.expectEqual(@as(usize, 1), gone.len);
    try t.expectEqualStrings("", gone[0].dir);
    try t.expectEqual(@as(i64, 1), try countCopies(&r, arena, source));
    // A year on, it's as if deleted.
    stats = (try Fresh.crawl(&r, io, arena, &client, 6000 + unavailable_expiry_ms, source)).ingest;
    try t.expectEqual(@as(usize, 1), stats.copies_removed);
    try t.expectEqual(@as(usize, 0), (try unavailableDirs(&r, arena, &source.id)).len);
    // Forgotten by hand, too.
    try tmp.dir.writeFile(io, .{ .sub_path = "a/Alien (1979).mp4", .data = "x" });
    _ = try Fresh.crawl(&r, io, arena, &client, 7000 + unavailable_expiry_ms, source);
    try tmp.dir.deleteFile(io, "a/Alien (1979).mp4");
    _ = try Fresh.crawl(&r, io, arena, &client, 8000 + unavailable_expiry_ms, source);
    try t.expectEqual(@as(usize, 1), try removeUnavailable(&r, arena, 9000 + unavailable_expiry_ms, source, "/"));
    try t.expectEqual(@as(i64, 0), try countCopies(&r, arena, source));
    try t.expectEqual(@as(usize, 0), (try unavailableDirs(&r, arena, &source.id)).len);

    // A folder served at a path of its own (as the apps serve theirs) that
    // goes altogether, as a share unmounted: it lists empty, so it's
    // unavailable, its copies kept, and back again once it returns.
    try tmp.dir.createDirPath(io, "share");
    try tmp.dir.writeFile(io, .{ .sub_path = "share/Casablanca (1942).mp4", .data = "x" });
    var folder: @import("host.zig").Host = .{ .io = io, .gpa = gpa, .options = .{ .port = 0, .mounts = &.{.{ .prefix = "movies", .path = try std.fmt.allocPrint(arena, "{s}/share", .{root}), .index = false }} } };
    try folder.start();
    defer folder.stop();
    _ = try addSource(&r, 9000, try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/movies/", .{folder.port}), .{});
    const share = for (try sources(&r, arena)) |rp| {
        if (std.mem.endsWith(u8, rp.url, "/movies/")) break rp;
    } else unreachable;
    _ = try Fresh.crawl(&r, io, arena, &client, 10_000, share);
    try t.expectEqual(@as(i64, 1), try countCopies(&r, arena, share));
    try tmp.dir.rename("share", tmp.dir, "share-away", io);
    stats = (try Fresh.crawl(&r, io, arena, &client, 11_000, share)).ingest;
    try t.expectEqual(@as(usize, 1), stats.unavailable);
    try t.expectEqual(@as(i64, 1), try countCopies(&r, arena, share));
    try t.expectEqualStrings("", (try unavailableDirs(&r, arena, &share.id))[0].dir);
    try tmp.dir.rename("share-away", tmp.dir, "share", io);
    stats = (try Fresh.crawl(&r, io, arena, &client, 12_000, share)).ingest;
    try t.expectEqual(@as(usize, 0), stats.unavailable);
    try t.expectEqual(@as(usize, 0), (try unavailableDirs(&r, arena, &share.id)).len);
}

test "state: sources, aliases, progress, and members can be listed, set, and removed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const replica_ = @import("replica.zig");
    const founder = (try replica_.personKeyPair(@splat(1))).public_key.toBytes();
    var r = try Replica.open(std.testing.allocator, std.testing.io, ":memory:", founder, .from(@splat(1)));
    defer r.close();

    const id = try addSource(&r, 1000, "http://nas.local/Movies/", .{});
    const changed = try setSource(&r, arena, 2000, "http://nas.local/Movies", "4K HEVC", null, null);
    try std.testing.expectEqualStrings("4K HEVC", changed.layout.quality);
    try std.testing.expectEqualStrings("4K HEVC", (try findSource(&r, arena, &id)).layout.quality);
    try std.testing.expectEqualStrings(",", (try findSource(&r, arena, &id)).layout.skip);

    try addAlias(&r, 3000, "t/m/rogue-protocol/2019", "t/m/rogue-protocol/2018");
    try std.testing.expectEqual(@as(usize, 1), (try aliases(&r, arena)).len);
    try removeAlias(&r, 4000, "t/m/rogue-protocol/2019");
    try std.testing.expectEqual(@as(usize, 0), (try aliases(&r, arena)).len);

    try setProgress(&r, arena, 5000, "t/m/network-effect/2020/v/-", 60_000, 6_000_000);
    try setWatched(&r, arena, 6000, "t/s/worldhoppers/-/e/s01e02", true);
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
    try setWatched(&r, arena, 7200, "t/m/network-effect/2020/v/-", false);
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
};

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
        }
    }
    return out.items;
}

/// Whether `person` (hex) is the one `writer` acts for, or the one the
/// certificate of `device` (hex) names.
fn ownedBy(replica: *Replica, writer: [32]u8, device: []const u8, person: []const u8) !bool {
    var claimed: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&claimed, person) catch return false;
    if (try replica.certifiedPerson(writer, &.{})) |p| if (std.mem.eql(u8, &p, &claimed)) return true;
    var key: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&key, device) catch return false;
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
