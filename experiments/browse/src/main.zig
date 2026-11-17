//! Compares two ways to browse by intersections of facets at the scale in
//! AGENTS.md: SQLite over a facet table, and in-memory bitmaps (a bit per
//! title per facet value), as a thin player might hold. The query is "new
//! thrillers or mysteries starring A-listers, with English audio", plus the
//! counts a refinement menu shows for every remaining facet value.
//!
//! Usage: browse [database path]

const std = @import("std");
const Io = std.Io;
const sqlite = @import("sqlite");

const movies = 4000;
const series = 500;
const titles = movies + series;
const people = 20_000;
const cast_size = 8;
const a_listers = 300;
const reps = 200;

const genres = [_][]const u8{
    "Drama",  "Comedy",    "Thriller", "Mystery", "Action",  "Romance",     "Horror", "Science Fiction", "Fantasy", "Documentary",
    "Crime",  "Animation", "Family",   "War",     "Western", "Music",       "History", "Adventure",      "Biography", "Sport",
};
const languages = [_][]const u8{
    "en", "fr", "es", "de", "it", "ja", "ko", "zh", "hi", "ru", "pt", "sv", "da", "no", "fi",
    "nl", "pl", "tr", "ar", "he", "th", "cs", "hu", "el", "fa",
};

/// Up to three small values, such as a title's genres.
const Three = struct {
    items: [3]u8 = undefined,
    len: u8 = 0,

    fn slice(t: *const Three) []const u8 {
        return t.items[0..t.len];
    }

    fn append(t: *Three, v: u8) void {
        t.items[t.len] = v;
        t.len += 1;
    }
};

const Title = struct {
    series: bool,
    year: u16,
    genres: Three = .{},
    cast: [cast_size]u16,
    audio: Three = .{},
};

fn generate(random: std.Random) [titles]Title {
    var out: [titles]Title = undefined;
    for (&out, 0..) |*t, i| {
        // Years skew recent; genres skew toward drama and comedy; casts
        // follow a heavy-tailed popularity, so a few people appear often.
        t.* = .{ .series = i >= movies, .year = 1920 + @as(u16, @intFromFloat(106.0 * @sqrt(random.float(f64)))), .cast = undefined };
        const n_genres = 1 + random.uintLessThan(usize, 3);
        while (t.genres.len < n_genres) {
            const g: u8 = @intFromFloat(@as(f64, genres.len) * random.float(f64) * random.float(f64));
            if (std.mem.indexOfScalar(u8, t.genres.slice(), g) == null) t.genres.append(g);
        }
        for (&t.cast) |*person| person.* = @intFromFloat(@floor(std.math.pow(f64, people, random.float(f64))) - 1);
        t.audio.append(if (random.float(f64) < 0.85) 0 else @intCast(1 + random.uintLessThan(usize, languages.len - 1)));
        if (random.float(f64) < 0.3) {
            const extra: u8 = @intCast(random.uintLessThan(usize, languages.len));
            if (extra != t.audio.items[0]) t.audio.append(extra);
        }
    }
    return out;
}

/// The `a_listers` people in the most titles.
fn aList(all: []const Title) [a_listers]u16 {
    var counts: [people]u32 = @splat(0);
    for (all) |t| for (t.cast) |p| {
        counts[p] += 1;
    };
    var order: [people]u16 = undefined;
    for (&order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u16, &order, &counts, struct {
        fn lessThan(c: *const [people]u32, a: u16, b: u16) bool {
            return c[a] > c[b];
        }
    }.lessThan);
    return order[0..a_listers].*;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const path = if (args.len > 1) args[1] else "/tmp/cinematheque-browse.db";
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    var prng = std.Random.DefaultPrng.init(3);
    const all = generate(prng.random());
    const stars = aList(&all);

    // SQLite: one row per title per facet value, indexed both ways.
    Io.Dir.cwd().deleteFile(io, path) catch {};
    const db = try sqlite.Db.open(try arena.dupeSentinel(u8, path, 0));
    defer db.close();
    try db.exec(
        \\CREATE TABLE titles (id INTEGER PRIMARY KEY, year INTEGER NOT NULL);
        \\CREATE TABLE facets (
        \\  facet TEXT NOT NULL, value TEXT NOT NULL, title INTEGER NOT NULL,
        \\  PRIMARY KEY (facet, value, title)
        \\) WITHOUT ROWID;
        \\CREATE INDEX facets_by_title ON facets (title, facet, value);
        \\CREATE TABLE a_list (value TEXT PRIMARY KEY) WITHOUT ROWID;
        \\BEGIN;
    );
    {
        const t_stmt = try db.prepare("INSERT INTO titles VALUES (?1, ?2)");
        defer t_stmt.finalize();
        const f_stmt = try db.prepare("INSERT OR IGNORE INTO facets VALUES (?1, ?2, ?3)");
        defer f_stmt.finalize();
        var value: [16]u8 = undefined;
        for (all, 0..) |t, i| {
            try t_stmt.bindInt(1, @intCast(i));
            try t_stmt.bindInt(2, t.year);
            _ = try t_stmt.step();
            t_stmt.reset();
            const Row = struct { []const u8, []const u8 };
            var rows: std.ArrayList(Row) = .empty;
            try rows.append(arena, .{ "kind", if (t.series) "series" else "movie" });
            try rows.append(arena, .{ "decade", try std.fmt.allocPrint(arena, "{d}s", .{t.year / 10 * 10}) });
            for (t.genres.slice()) |g| try rows.append(arena, .{ "genre", genres[g] });
            for (t.audio.slice()) |a| try rows.append(arena, .{ "audio", languages[a] });
            for (t.cast) |p| try rows.append(arena, .{ "person", try arena.dupe(u8, try std.fmt.bufPrint(&value, "p{d}", .{p})) });
            for (rows.items) |r| {
                try f_stmt.bindText(1, r[0]);
                try f_stmt.bindText(2, r[1]);
                try f_stmt.bindInt(3, @intCast(i));
                _ = try f_stmt.step();
                f_stmt.reset();
            }
        }
        const a_stmt = try db.prepare("INSERT INTO a_list VALUES (?1)");
        defer a_stmt.finalize();
        for (stars) |p| {
            try a_stmt.bindText(1, try std.fmt.bufPrint(&value, "p{d}", .{p}));
            _ = try a_stmt.step();
            a_stmt.reset();
        }
    }
    try db.exec("COMMIT; ANALYZE;");
    const rows = try db.scalar("SELECT count(*) FROM facets");
    const db_bytes = try db.scalar("PRAGMA page_count") * try db.scalar("PRAGMA page_size");
    try out.print("{d} titles, {d} facet rows, {d:.1} MB in SQLite\n\n", .{ titles, rows, @as(f64, @floatFromInt(db_bytes)) / 1e6 });

    const selection =
        \\SELECT title FROM facets WHERE facet = 'genre' AND value IN ('Thriller', 'Mystery')
        \\INTERSECT SELECT title FROM facets WHERE facet = 'person' AND value IN (SELECT value FROM a_list)
        \\INTERSECT SELECT title FROM facets WHERE facet = 'audio' AND value = 'en'
        \\INTERSECT SELECT id FROM titles WHERE year >= 2010
    ;
    const count_sql = "SELECT count(*) FROM (" ++ selection ++ ")";
    const menu_sql = "SELECT facet, value, count(*) FROM facets WHERE facet != 'person' AND title IN (" ++ selection ++ ") GROUP BY facet, value";
    const people_sql = "SELECT value, count(*) AS n FROM facets WHERE facet = 'person' AND title IN (" ++ selection ++ ") GROUP BY value ORDER BY n DESC LIMIT 20";

    var sql_matches: i64 = 0;
    var timer = Timer.start(io);
    for (0..reps) |_| sql_matches = try db.scalar(count_sql);
    const sql_count_us = timer.lapUs() / reps;
    var sql_menu_values: usize = 0;
    timer = Timer.start(io);
    for (0..reps) |_| {
        sql_menu_values = 0;
        inline for (.{ menu_sql, people_sql }) |sql| {
            const s = try db.prepare(sql);
            defer s.finalize();
            while (try s.step()) sql_menu_values += 1;
        }
    }
    const sql_menu_us = timer.lapUs() / reps;

    // Bitmaps: a bit per title for each small facet's values, and posting
    // lists for people, too many to keep as bitmaps.
    const Bits = std.StaticBitSet(titles);
    var genre_bits: [genres.len]Bits = @splat(.empty);
    var audio_bits: [languages.len]Bits = @splat(.empty);
    var decade_bits: [11]Bits = @splat(.empty);
    var kind_bits: [2]Bits = @splat(.empty);
    var postings = try gpa.alloc(std.ArrayList(u16), people);
    defer {
        for (postings) |*p| p.deinit(gpa);
        gpa.free(postings);
    }
    for (postings) |*p| p.* = .empty;
    for (all, 0..) |t, i| {
        for (t.genres.slice()) |g| genre_bits[g].set(i);
        for (t.audio.slice()) |a| audio_bits[a].set(i);
        decade_bits[(t.year - 1920) / 10].set(i);
        kind_bits[@intFromBool(t.series)].set(i);
        for (t.cast) |p| try postings[p].append(gpa, @intCast(i));
    }

    var bit_matches: usize = 0;
    var selected: Bits = .empty;
    timer = Timer.start(io);
    for (0..reps) |_| {
        selected = genre_bits[2].unionWith(genre_bits[3]); // thrillers or mysteries
        var starring: Bits = .empty;
        for (stars) |p| for (postings[p].items) |t| starring.set(t);
        selected = selected.intersectWith(starring).intersectWith(audio_bits[0]);
        var recent: Bits = .empty;
        for (9..11) |d| recent = recent.unionWith(decade_bits[d]);
        selected = selected.intersectWith(recent);
        bit_matches = selected.count();
    }
    const bit_count_us = timer.lapUs() / reps;
    var bit_menu_values: usize = 0;
    var person_counts = try gpa.alloc(u32, people);
    defer gpa.free(person_counts);
    timer = Timer.start(io);
    for (0..reps) |_| {
        bit_menu_values = 0;
        for ([_][]const Bits{ &genre_bits, &audio_bits, &decade_bits, &kind_bits }) |facet| {
            for (facet) |v| if (selected.intersectWith(v).count() > 0) {
                bit_menu_values += 1;
            };
        }
        @memset(person_counts, 0);
        var it = selected.iterator(.{});
        while (it.next()) |t| for (all[t].cast) |p| {
            person_counts[p] += 1;
        };
        var top: usize = 0;
        for (person_counts) |c| if (c > 0) {
            top += 1;
        };
        bit_menu_values += @min(top, 20);
    }
    const bit_menu_us = timer.lapUs() / reps;

    const bitmap_bytes = (genres.len + languages.len + 11 + 2) * @sizeOf(Bits);
    var posting_bytes: usize = 0;
    for (postings) |p| posting_bytes += 2 * p.items.len;

    try out.print("{s:<10} {s:>12} {s:>14} {s:>8} {s:>12}\n", .{ "", "selection", "refinement", "matches", "menu values" });
    try out.print("{s:<10} {d:>9} µs {d:>11} µs {d:>8} {d:>12}\n", .{ "SQLite", sql_count_us, sql_menu_us, @as(u64, @intCast(sql_matches)), sql_menu_values });
    try out.print("{s:<10} {d:>9} µs {d:>11} µs {d:>8} {d:>12}\n", .{ "bitmaps", bit_count_us, bit_menu_us, bit_matches, bit_menu_values });
    try out.print("\nbitmaps for {d} small facet values: {d:.1} KB; people's posting lists: {d:.1} KB\n", .{
        genres.len + languages.len + 11 + 2, @as(f64, @floatFromInt(bitmap_bytes)) / 1e3, @as(f64, @floatFromInt(posting_bytes)) / 1e3,
    });
    if (sql_matches != bit_matches) return error.Mismatch;
}

const Timer = struct {
    io: Io,
    start_at: Io.Timestamp,

    fn start(io: Io) Timer {
        return .{ .io = io, .start_at = Io.Timestamp.now(io, .awake) };
    }

    fn lapUs(timer: Timer) u64 {
        return @intCast(timer.start_at.durationTo(Io.Timestamp.now(timer.io, .awake)).toMicroseconds());
    }
};
