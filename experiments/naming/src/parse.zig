//! Parses a repository path into what correlation needs: kind, title, year,
//! season and episodes, outside IDs, edition, part, and extra type.
//! Follows Plex, Jellyfin, and Kodi conventions and common scene names,
//! with hand-written scanners instead of regular expressions.

const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;

pub const Kind = enum { movie, episode, extra };

pub const Parsed = struct {
    kind: Kind = .movie,
    /// The movie's or series' title, with separators turned to spaces.
    title: []const u8 = "",
    year: ?u16 = null,
    season: ?u16 = null,
    episode: ?u16 = null,
    /// The last episode of a multi-episode file (e.g., S01E01-E03).
    last_episode: ?u16 = null,
    /// For daily shows named by air date.
    date: ?[10]u8 = null,
    tmdb: ?[]const u8 = null,
    imdb: ?[]const u8 = null,
    tvdb: ?[]const u8 = null,
    edition: ?[]const u8 = null,
    part: ?u16 = null,
    resolution: ?[]const u8 = null,
    extra: ?[]const u8 = null,
};

const video_extensions = [_][]const u8{ ".mkv", ".mp4", ".m4v", ".avi", ".mov", ".ts", ".m2ts", ".iso", ".wmv", ".webm", ".mpg" };

/// Folder names that hold extras, and suffixes that mark them (Jellyfin).
const extra_folders = [_][]const u8{ "behind the scenes", "deleted scenes", "interviews", "scenes", "samples", "shorts", "featurettes", "clips", "other", "extras", "trailers" };
const extra_suffixes = [_][]const u8{ "-trailer", "-featurette", "-behindthescenes", "-deleted", "-deletedscene", "-interview", "-scene", "-short", "-sample", "-clip", "-other", "-extra" };

/// Tokens that end a scene name's title.
const scene_tokens = [_][]const u8{
    "2160p",  "1080p",  "1080i",  "720p",   "576p",   "480p",  "4k",     "uhd",    "bluray", "blu-ray", "bdrip",  "brrip",
    "web-dl", "webdl",  "webrip", "web",    "hdtv",   "dvdrip", "dvd",   "remux",  "x264",   "x265",    "h264",   "h.264",
    "h265",   "h.265",  "hevc",   "av1",    "xvid",   "hdr",    "hdr10", "dv",     "dts",    "truehd",  "atmos",  "aac",
    "ac3",    "dd5.1",  "ddp5.1", "proper", "repack", "internal", "limited", "extended", "unrated", "imax", "multi", "10bit",
};

pub fn isVideo(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    for (video_extensions) |e| if (ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

/// `path` is relative to the repository's root, with `/` separators.
/// Returned slices point into `path` or `scratch`.
pub fn parse(path: []const u8, scratch: []u8) Parsed {
    var p: Parsed = .{};
    var segments: [16][]const u8 = undefined;
    var n: usize = 0;
    var it = mem.splitScalar(u8, path, '/');
    while (it.next()) |s| {
        if (s.len == 0) continue;
        if (n == segments.len) break;
        segments[n] = s;
        n += 1;
    }
    if (n == 0) return p;
    const file = segments[n - 1];
    const stem = file[0 .. file.len - std.fs.path.extension(file).len];
    const folders = segments[0 .. n - 1];

    // Extras, by folder or suffix.
    for (folders) |f| for (extra_folders) |e| if (ascii.eqlIgnoreCase(f, e)) {
        p.kind = .extra;
        p.extra = f;
    };
    for (extra_suffixes) |suffix| if (stem.len > suffix.len and ascii.endsWithIgnoreCase(stem, suffix)) {
        p.kind = .extra;
        p.extra = suffix[1..];
    };

    // Season from a "Season 01" or "Specials" folder.
    var season_folder: ?usize = null;
    for (folders, 0..) |f, i| {
        if (seasonFolder(f)) |s| {
            p.season = s;
            season_folder = i;
        }
    }

    var used: usize = 0;
    scanName(&p, stem, scratch, &used);

    // Kodi's compact episode code, `Show 317 Title` for season 3, episode
    // 17 (`1213` for 12 and 13), read only right after the series' title
    // from the enclosing folder, since elsewhere such numbers are years or
    // part of titles.
    if (p.episode == null and p.date == null and folders.len > 0) {
        var folder: Parsed = .{};
        scanName(&folder, folders[folders.len - 1], scratch, &used);
        // Right after the series' title, a number is the code even when it
        // looks like a year ("South Park 1908", season 19), unless it's the
        // folder's own year.
        if (compactEpisode(stem, folder.title)) |code| if (code != folder.year) {
            p.kind = .episode;
            p.season = code / 100;
            p.episode = code % 100;
            p.title = folder.title;
            p.year = folder.year;
            p.edition = null;
            p.part = null;
            return p;
        };
    }

    // A file in a season folder, or with an episode number, is an episode
    // of the series named by the folder above the season's.
    if (p.kind != .extra and p.episode != null or p.date != null) p.kind = .episode;
    if (p.kind == .episode or season_folder != null) {
        const series_index = if (season_folder) |i| (if (i > 0) i - 1 else null) else if (folders.len > 0) folders.len - 1 else null;
        if (series_index) |i| {
            if (p.kind != .extra) p.kind = .episode;
            var folder: Parsed = .{};
            scanName(&folder, folders[i], scratch, &used);
            if (folder.title.len > 0) p.title = folder.title;
            p.year = folder.year orelse p.year;
            p.tmdb = folder.tmdb orelse p.tmdb;
            p.imdb = folder.imdb orelse p.imdb;
            p.tvdb = folder.tvdb orelse p.tvdb;
        }
    } else if (folders.len > 0) {
        // A movie (or its extra) in its own folder: a folder with a year
        // names it better than a scene file name or an extra's own name.
        var i = folders.len - 1;
        while (i > 0 and isExtraFolder(folders[i])) i -= 1;
        var folder: Parsed = .{};
        scanName(&folder, folders[i], scratch, &used);
        if (folder.year != null or p.title.len == 0) {
            p.title = folder.title;
            p.year = folder.year orelse p.year;
        }
        p.tmdb = p.tmdb orelse folder.tmdb;
        p.imdb = p.imdb orelse folder.imdb;
        p.tvdb = p.tvdb orelse folder.tvdb;
        p.edition = p.edition orelse folder.edition;
    }
    return p;
}

/// The 3- or 4-digit code following `title` at the start of `stem`,
/// comparing letters and digits only ("House, M.D. 212" follows "House, MD").
fn compactEpisode(stem: []const u8, title: []const u8) ?u16 {
    if (title.len == 0) return null;
    var i: usize = 0;
    for (title) |c| {
        if (!ascii.isAlphanumeric(c)) continue;
        while (i < stem.len and !ascii.isAlphanumeric(stem[i])) i += 1;
        if (i == stem.len or ascii.toLower(stem[i]) != ascii.toLower(c)) return null;
        i += 1;
    }
    if (i == stem.len or ascii.isAlphanumeric(stem[i])) return null;
    // Punctuation may end the title: "Penn & Teller Bullshit! 101".
    while (i < stem.len and !ascii.isAlphanumeric(stem[i]) and stem[i] != '(') i += 1;
    // The series' year may come between: "Show (2020) 101 Title".
    if (i + 6 <= stem.len and stem[i] == '(' and stem[i + 5] == ')' and yearAt(stem[i + 1 ..]) != null) i += 6;
    // Otherwise a parenthesized number is a year: "Inception (2010)".
    while (i < stem.len and isSeparator(stem[i])) : (i += 1) if (stem[i] == '(') return null;
    const start = i;
    while (i < stem.len and ascii.isDigit(stem[i])) i += 1;
    const digits = i - start;
    if (digits < 3 or digits > 4 or (i < stem.len and !isSeparator(stem[i]))) return null;
    const code = std.fmt.parseInt(u16, stem[start..i], 10) catch return null;
    if (code % 100 == 0) return null;
    return code;
}

fn isExtraFolder(name: []const u8) bool {
    for (extra_folders) |e| if (ascii.eqlIgnoreCase(name, e)) return true;
    return false;
}

fn seasonFolder(name: []const u8) ?u16 {
    if (ascii.eqlIgnoreCase(name, "specials")) return 0;
    for ([_][]const u8{ "season ", "season.", "season_", "season", "s" }) |prefix| {
        if (name.len > prefix.len and ascii.startsWithIgnoreCase(name, prefix)) {
            return std.fmt.parseInt(u16, name[prefix.len..], 10) catch continue;
        }
    }
    return null;
}

/// Scans one file or folder name: tags, episode markers, year, part, and
/// scene tokens; the title is what precedes the first of them.
fn scanName(p: *Parsed, name: []const u8, scratch: []u8, used: *usize) void {
    var title_end = name.len;
    // Only the last year ends the title: "Blade Runner 2049 (2017)".
    var year_at: ?usize = null;
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        const c = name[i];
        const at_word = i == 0 or isSeparator(name[i - 1]);
        // {tmdb-123}, {imdb-tt123}, {tvdb-123}, {edition-…}; [imdbid-…] etc.
        if (c == '{' or c == '[') {
            const close: u8 = if (c == '{') '}' else ']';
            if (mem.indexOfScalarPos(u8, name, i, close)) |end| {
                if (tag(p, name[i + 1 .. end])) {
                    title_end = @min(title_end, i);
                    i = end;
                    continue;
                }
            }
        }
        if (!at_word) continue;
        const rest = name[i..];
        if (episodeMarker(p, rest)) |len| {
            title_end = @min(title_end, i);
            i += len - 1;
            continue;
        }
        if (airDate(p, rest)) |len| {
            title_end = @min(title_end, i);
            i += len - 1;
            continue;
        }
        if (yearAt(rest)) |y| {
            // A year at the very start is part of the title (e.g., "2001: A
            // Space Odyssey (1968)"), unless nothing follows.
            if (i > 0 or wordEnd(rest) == rest.len) {
                p.year = y;
                year_at = if (i > 0 and name[i - 1] == '(') i - 1 else i;
            }
            continue;
        }
        if (partMarker(rest)) |part| {
            p.part = part.number;
            title_end = @min(title_end, i);
            i += part.len - 1;
            continue;
        }
        const word = rest[0..wordEnd(rest)];
        for (scene_tokens) |t| if (ascii.eqlIgnoreCase(word, t)) {
            if (word[0] >= '0' and word[0] <= '9' and ascii.endsWithIgnoreCase(word, "p") or ascii.eqlIgnoreCase(word, "4k"))
                p.resolution = word;
            title_end = @min(title_end, i);
            break;
        };
    }
    if (year_at) |at| title_end = @min(title_end, at);
    // Jellyfin's version label: "Title (2010) - Director's Cut".
    if (p.edition == null) if (mem.indexOf(u8, name, " - ")) |dash| if (dash >= title_end) {
        const label = mem.trim(u8, name[dash + 3 ..], " ");
        if (label.len > 0 and p.episode == null and p.part == null) p.edition = label;
    };
    p.title = cleanTitle(name[0..title_end], scratch, used);
}

fn tag(p: *Parsed, body: []const u8) bool {
    const dash = mem.indexOfAny(u8, body, "-=") orelse return false;
    const key = body[0..dash];
    const value = body[dash + 1 ..];
    if (value.len == 0) return false;
    if (ascii.eqlIgnoreCase(key, "tmdb") or ascii.eqlIgnoreCase(key, "tmdbid")) p.tmdb = value //
    else if (ascii.eqlIgnoreCase(key, "imdb") or ascii.eqlIgnoreCase(key, "imdbid")) p.imdb = value //
    else if (ascii.eqlIgnoreCase(key, "tvdb") or ascii.eqlIgnoreCase(key, "tvdbid")) p.tvdb = value //
    else if (ascii.eqlIgnoreCase(key, "edition")) p.edition = value //
    else return false;
    return true;
}

/// `S01E02`, `S01E02E03`, `S01E02-E03`, `S01E02-03`, `1x02`, or `E02`
/// (when a season folder gives the season).
fn episodeMarker(p: *Parsed, s: []const u8) ?usize {
    var i: usize = 0;
    var season: ?u16 = null;
    if (s.len > 1 and (s[0] == 'S' or s[0] == 's') and ascii.isDigit(s[1])) {
        i = 1;
        season = number(s, &i, 4) orelse return null;
        if (i >= s.len or (s[i] != 'E' and s[i] != 'e')) return null;
    } else if (s.len > 2 and ascii.isDigit(s[0])) {
        var j: usize = 0;
        const n = number(s, &j, 2) orelse return null;
        if (j + 1 >= s.len or (s[j] != 'x' and s[j] != 'X') or !ascii.isDigit(s[j + 1])) return null;
        season = n;
        i = j + 1;
        var k = i;
        const e = number(s, &k, 3) orelse return null;
        if (k < s.len and !isSeparator(s[k])) return null;
        p.season = season;
        p.episode = e;
        return k;
    } else if (s.len > 1 and (s[0] == 'E' or s[0] == 'e') and ascii.isDigit(s[1]) and p.season != null) {
        // Bare E02, only within a season folder.
    } else return null;

    i += 1; // past 'E'
    const first = number(s, &i, 4) orelse return null;
    var last: ?u16 = null;
    while (i < s.len) {
        var j = i;
        if (s[j] == '-') j += 1;
        if (j < s.len and (s[j] == 'E' or s[j] == 'e')) j += 1;
        if (j == i) break;
        last = number(s, &j, 4) orelse break;
        i = j;
    }
    if (i < s.len and !isSeparator(s[i])) return null;
    if (season) |n| p.season = n;
    p.episode = first;
    p.last_episode = last;
    return i;
}

/// `2026.11.16` or `2026-11-16`, for daily shows.
fn airDate(p: *Parsed, s: []const u8) ?usize {
    if (s.len < 10) return null;
    const sep = s[4];
    if ((sep != '.' and sep != '-') or s[7] != sep) return null;
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9 }) |k| if (!ascii.isDigit(s[k])) return null;
    if (s.len > 10 and !isSeparator(s[10])) return null;
    var date: [10]u8 = s[0..10].*;
    date[4] = '-';
    date[7] = '-';
    p.date = date;
    return 10;
}

fn yearAt(s: []const u8) ?u16 {
    if (s.len < 4) return null;
    const y = std.fmt.parseInt(u16, s[0..4], 10) catch return null;
    if (y < 1880 or y > 2100) return null;
    if (s.len > 4 and !isSeparator(s[4]) and s[4] != ')') return null;
    return y;
}

const Part = struct { number: u16, len: usize };

fn partMarker(s: []const u8) ?Part {
    for ([_][]const u8{ "part", "cd", "disc", "disk", "dvd", "pt" }) |prefix| {
        if (s.len > prefix.len and ascii.startsWithIgnoreCase(s, prefix)) {
            var i = prefix.len;
            if (i < s.len and (s[i] == ' ' or s[i] == '.' or s[i] == '_')) i += 1;
            const n = number(s, &i, 2) orelse continue;
            if (i < s.len and !isSeparator(s[i])) continue;
            return .{ .number = n, .len = i };
        }
    }
    return null;
}

fn number(s: []const u8, i: *usize, max_digits: usize) ?u16 {
    const start = i.*;
    while (i.* < s.len and i.* - start < max_digits and ascii.isDigit(s[i.*])) i.* += 1;
    if (i.* == start) return null;
    return std.fmt.parseInt(u16, s[start..i.*], 10) catch null;
}

fn isSeparator(c: u8) bool {
    return switch (c) {
        ' ', '.', '_', '-', '(', ')', '[', ']', '{', '}', ',' => true,
        else => false,
    };
}

fn wordEnd(s: []const u8) usize {
    var i: usize = 0;
    // Keep dots and hyphens inside tokens like "H.264", "WEB-DL", "DD5.1".
    while (i < s.len and s[i] != ' ' and s[i] != '_' and s[i] != '(' and s[i] != ')' and s[i] != '[' and s[i] != ']') : (i += 1) {
        if (s[i] == '.' and !(i + 1 < s.len and ascii.isDigit(s[i + 1]) and i > 0 and ascii.isAlphanumeric(s[i - 1]))) break;
        if (s[i] == '-' and !(i + 1 < s.len and ascii.isAlphabetic(s[i + 1]) and i > 0 and ascii.isAlphabetic(s[i - 1]))) break;
    }
    return i;
}

/// Turns scene separators into spaces (keeping dots in acronyms like
/// "S.W.A.T." and hyphens inside words), and trims what's left.
fn cleanTitle(raw: []const u8, scratch: []u8, used: *usize) []const u8 {
    // A parenthesis left open, as in "House, MD (from DVD)" cut at "DVD",
    // goes with what followed it.
    var cut = raw;
    if (mem.lastIndexOfScalar(u8, cut, '(')) |open| if (mem.indexOfScalarPos(u8, cut, open, ')') == null) {
        cut = cut[0..open];
    };
    const trimmed = mem.trim(u8, cut, " ._-([");
    const dotted = mem.indexOfScalar(u8, trimmed, ' ') == null;
    if (!dotted or used.* + trimmed.len > scratch.len) return trimmed;
    const out = scratch[used.*..][0..trimmed.len];
    for (trimmed, 0..) |c, i| {
        const acronym = c == '.' and i >= 1 and ascii.isUpper(trimmed[i - 1]) and (i < 2 or trimmed[i - 2] == '.' or i + 2 < trimmed.len and trimmed[i + 2] == '.');
        out[i] = if ((c == '.' and !acronym) or c == '_') ' ' else c;
    }
    used.* += trimmed.len;
    return mem.trim(u8, out, " ");
}
