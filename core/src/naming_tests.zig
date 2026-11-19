//! Fixtures from the Plex, Jellyfin, and Kodi naming guides, and scene names.

const std = @import("std");
const parse_ = @import("naming.zig");
const Kind = parse_.Kind;

const Case = struct {
    path: []const u8,
    kind: Kind,
    title: []const u8,
    year: ?u16 = null,
    season: ?u16 = null,
    episode: ?u16 = null,
    last_episode: ?u16 = null,
    date: ?[]const u8 = null,
    tmdb: ?[]const u8 = null,
    imdb: ?[]const u8 = null,
    tvdb: ?[]const u8 = null,
    edition: ?[]const u8 = null,
    part: ?u16 = null,
    resolution: ?[]const u8 = null,
    quality: ?[]const u8 = null,
    extra: ?[]const u8 = null,
};

const cases = [_]Case{
    // Movies
    .{ .path = "TV Shows/11.22.63/11.22.63 101 The Rabbit Hole.m4v", .kind = .episode, .title = "11.22.63", .season = 1, .episode = 1 },
    .{ .path = "Super.8.2011.1080p.BluRay.x264.mkv", .kind = .movie, .title = "Super 8", .year = 2011, .resolution = "1080p", .quality = "1080p bluray h264" },
    .{ .path = "Camera/00501.mp4", .kind = .movie, .title = "" },
    .{ .path = "Camera/99 00511.mp4", .kind = .movie, .title = "" },
    .{ .path = "Movies/Inception (2010)/Inception (2010).mkv", .kind = .movie, .title = "Inception", .year = 2010 },
    .{ .path = "Movies/Inception (2010) {tmdb-27205}/Inception (2010) {tmdb-27205}.mkv", .kind = .movie, .title = "Inception", .year = 2010, .tmdb = "27205" },
    .{ .path = "Movies/Blade Runner (1982) {edition-Final Cut}/Blade Runner (1982) {edition-Final Cut}.mkv", .kind = .movie, .title = "Blade Runner", .year = 1982, .edition = "Final Cut" },
    .{ .path = "Movies/Alien (1979) [imdbid-tt0078748]/Alien (1979) - Director's Cut.mkv", .kind = .movie, .title = "Alien", .year = 1979, .imdb = "tt0078748", .edition = "Director's Cut" },
    .{ .path = "Movies/Alien (1979)/Alien (1979) - 2160p.mkv", .kind = .movie, .title = "Alien", .year = 1979, .resolution = "2160p", .quality = "2160p" },
    .{ .path = "Movies/2001 A Space Odyssey (1968)/2001 A Space Odyssey (1968).mkv", .kind = .movie, .title = "2001 A Space Odyssey", .year = 1968 },
    .{ .path = "Movies/Blade Runner 2049 (2017)/Blade Runner 2049 (2017).mkv", .kind = .movie, .title = "Blade Runner 2049", .year = 2017 },
    .{ .path = "Blade.Runner.2049.2017.1080p.BluRay.x264.mkv", .kind = .movie, .title = "Blade Runner 2049", .year = 2017, .resolution = "1080p", .quality = "1080p bluray h264" },
    .{ .path = "Movies/2012 (2009)/2012 (2009).mkv", .kind = .movie, .title = "2012", .year = 2009 },
    .{ .path = "Movies/1917 (2019)/1917 (2019).mkv", .kind = .movie, .title = "1917", .year = 2019 },
    .{ .path = "Movies/The Lord of the Rings (2001)/The Lord of the Rings (2001) - part1.mkv", .kind = .movie, .title = "The Lord of the Rings", .year = 2001, .part = 1 },
    .{ .path = "Movies/Gone with the Wind (1939)/Gone with the Wind (1939) cd2.avi", .kind = .movie, .title = "Gone with the Wind", .year = 1939, .part = 2 },
    .{ .path = "Inception.2010.1080p.BluRay.x264-SPARKS.mkv", .kind = .movie, .title = "Inception", .year = 2010, .resolution = "1080p", .quality = "1080p bluray h264" },
    .{ .path = "Movies/Some Movie (2015)/Some.Movie.2015.2160p.UHD.BluRay.REMUX.HDR.HEVC.Atmos-GROUP.mkv", .kind = .movie, .title = "Some Movie", .year = 2015, .resolution = "2160p", .quality = "2160p remux hevc hdr" },
    .{ .path = "Movies/S.W.A.T. (2003)/S.W.A.T. (2003).mkv", .kind = .movie, .title = "S.W.A.T", .year = 2003 },
    .{ .path = "Movies/Amélie (2001)/Amélie (2001).mkv", .kind = .movie, .title = "Amélie", .year = 2001 },
    .{ .path = "Movies/Spider-Man (2002)/Spider-Man (2002).mkv", .kind = .movie, .title = "Spider-Man", .year = 2002 },
    // Extras
    .{ .path = "Movies/Avatar (2009)/Trailers/Avatar Trailer.mp4", .kind = .extra, .title = "Avatar", .year = 2009, .extra = "Trailers" },
    .{ .path = "Movies/Avatar (2009)/Avatar (2009)-trailer.mkv", .kind = .extra, .title = "Avatar", .year = 2009, .extra = "trailer" },
    .{ .path = "TV/Lost (2004)/Featurettes/Making Lost.mkv", .kind = .extra, .title = "Lost", .year = 2004, .extra = "Featurettes" },
    // Episodes
    .{ .path = "TV/Breaking Bad (2008)/Season 01/Breaking Bad - S01E01 - Pilot.mkv", .kind = .episode, .title = "Breaking Bad", .year = 2008, .season = 1, .episode = 1 },
    .{ .path = "TV/Breaking Bad (2008) {tvdb-81189}/Season 02/Breaking Bad S02E03E04.mkv", .kind = .episode, .title = "Breaking Bad", .year = 2008, .season = 2, .episode = 3, .last_episode = 4, .tvdb = "81189" },
    .{ .path = "TV/The Office (US)/Season 3/The.Office.US.S03E05-E06.720p.WEB-DL.mkv", .kind = .episode, .title = "The Office (US)", .season = 3, .episode = 5, .last_episode = 6, .resolution = "720p", .quality = "720p web" },
    .{ .path = "TV/Doctor Who (2005)/Specials/Doctor Who - S00E01 - The Christmas Invasion.mkv", .kind = .episode, .title = "Doctor Who", .year = 2005, .season = 0, .episode = 1 },
    .{ .path = "TV/Firefly/Firefly 1x02 The Train Job.avi", .kind = .episode, .title = "Firefly", .season = 1, .episode = 2 },
    .{ .path = "TV/The Daily Show/The Daily Show 2026.11.16.mkv", .kind = .episode, .title = "The Daily Show", .date = "2026-11-16" },
    .{ .path = "TV/Lost (2004)/Season 01/E05.mkv", .kind = .episode, .title = "Lost", .year = 2004, .season = 1, .episode = 5 },
    .{ .path = "TV/Lost (2004)/Season 01/Lost S01E05 part2.mkv", .kind = .episode, .title = "Lost", .year = 2004, .season = 1, .episode = 5, .part = 2 },
    .{ .path = "Game.of.Thrones.S08E06.1080p.WEB.H264-MEMENTO.mkv", .kind = .episode, .title = "Game of Thrones", .season = 8, .episode = 6, .resolution = "1080p", .quality = "1080p web h264" },
    .{ .path = "Friends/Friends 423 The One with Ross's Wedding.m4v", .kind = .episode, .title = "Friends", .season = 4, .episode = 23 },
    .{ .path = "The Big Bang Theory/The Big Bang Theory 1213 The Confirmation Polarization.m4v", .kind = .episode, .title = "The Big Bang Theory", .season = 12, .episode = 13 },
    .{ .path = "Entourage (2004)/Entourage 317 Return of the King.m4v", .kind = .episode, .title = "Entourage", .year = 2004, .season = 3, .episode = 17 },
    .{ .path = "House, MD (from DVD)/House, M.D. 212 Distractions.m4v", .kind = .episode, .title = "House, MD", .season = 2, .episode = 12 },
    .{ .path = "Call the Midwife/Call the Midwife 609 Christmas Special 2017.m4v", .kind = .episode, .title = "Call the Midwife", .season = 6, .episode = 9 },
    .{ .path = "All Creatures Great and Small (2020)/All Creatures Great and Small (2020) 101 You've Got to Dream.m4v", .kind = .episode, .title = "All Creatures Great and Small", .year = 2020, .season = 1, .episode = 1 },
    .{ .path = "South Park/South Park 1908 Sponsored Content.m4v", .kind = .episode, .title = "South Park", .season = 19, .episode = 8 },
    .{ .path = "Penn & Teller Bullshit!/Penn & Teller Bullshit! 305 Holier than Thou.m4v", .kind = .episode, .title = "Penn & Teller Bullshit!", .season = 3, .episode = 5 },
    .{ .path = "The Twilight Saga Breaking Dawn - Part 1 (2011).m4v", .kind = .movie, .title = "The Twilight Saga Breaking Dawn - Part 1", .year = 2011 },
    .{ .path = "Friday the 13th Part 2 (1981).m4v", .kind = .movie, .title = "Friday the 13th Part 2", .year = 1981 },
    .{ .path = "24/24 804 Day 8 7pm - 8pm (Extended).m4v", .kind = .episode, .title = "24", .season = 8, .episode = 4, .edition = "Extended" },
    .{ .path = "Fight Club (1999) Unrated.m4v", .kind = .movie, .title = "Fight Club", .year = 1999, .edition = "Unrated" },
    .{ .path = "Star Trek Discovery/Star Trek Discovery 213 Such Sweet Sorrow (Part 2).m4v", .kind = .episode, .title = "Star Trek Discovery", .season = 2, .episode = 13, .part = 2 },
    .{ .path = "Battlestar Galactica Razor (Extended).m4v", .kind = .movie, .title = "Battlestar Galactica Razor", .edition = "Extended" },
    .{ .path = "Movies/Alien (1979)/Alien (1979) - 4K HDR.mkv", .kind = .movie, .title = "Alien", .year = 1979, .resolution = "4K", .quality = "2160p hdr" },
    .{ .path = "Movies/Alien (1979)/Alien (1979) - Director's Cut - 1080p.mkv", .kind = .movie, .title = "Alien", .year = 1979, .resolution = "1080p", .edition = "Director's Cut", .quality = "1080p" },
    .{ .path = "Inception.2010.2160p.UHD.BluRay.REMUX.HDR.HEVC-GROUP.mkv", .kind = .movie, .title = "Inception", .year = 2010, .resolution = "2160p", .quality = "2160p remux hevc hdr" },
    .{ .path = "Blade.Runner.1982.Final.Cut.2160p.UHD.BluRay.x265.DV.HDR.mkv", .kind = .movie, .title = "Blade Runner", .year = 1982, .resolution = "2160p", .quality = "2160p bluray hevc dv" },
    .{ .path = "Salt (2010) - Director's Cut.m4v", .kind = .movie, .title = "Salt", .year = 2010, .edition = "Director's Cut" },
    .{ .path = "TV/Series 0001 (1951)/Season 01/Series 0001 - S01E01 - Episode 1.mkv", .kind = .episode, .title = "Series 0001", .year = 1951, .season = 1, .episode = 1 },
};

fn expectOptional(comptime T: type, expected: ?T, actual: ?T) !void {
    if (T == []const u8) {
        if (expected) |e| try std.testing.expectEqualStrings(e, actual orelse return error.TestExpectedValue) //
        else if (actual) |a| {
            std.debug.print("unexpected {s}\n", .{a});
            return error.TestUnexpectedValue;
        }
    } else try std.testing.expectEqual(expected, actual);
}

test "naming fixtures" {
    var failures: usize = 0;
    for (cases) |case| {
        var scratch: [512]u8 = undefined;
        const p = parse_.parse(case.path, &scratch);
        check(case, p) catch |err| {
            failures += 1;
            std.debug.print("{s}: {t}\n  got {any}\n", .{ case.path, err, p });
        };
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "a year's unclosed parenthesis ends the name without a crash" {
    var scratch: [512]u8 = undefined;
    _ = parse_.parse("Movies/Alien (1979", &scratch);
    _ = parse_.parse("Movies/Alien (1979.mkv", &scratch);
}

test "a deep path keeps its file, not its first folders" {
    var scratch: [512]u8 = undefined;
    const p = parse_.parse("a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r/Alien (1979).mkv", &scratch);
    try std.testing.expectEqualStrings("Alien", p.title);
    try std.testing.expectEqual(@as(?u16, 1979), p.year);
}

fn check(case: Case, p: parse_.Parsed) !void {
    try std.testing.expectEqual(case.kind, p.kind);
    try std.testing.expectEqualStrings(case.title, p.title);
    try expectOptional(u16, case.year, p.year);
    try expectOptional(u16, case.season, p.season);
    try expectOptional(u16, case.episode, p.episode);
    try expectOptional(u16, case.last_episode, p.last_episode);
    try expectOptional([]const u8, case.date, if (p.date) |*d| d else null);
    try expectOptional([]const u8, case.tmdb, p.tmdb);
    try expectOptional([]const u8, case.imdb, p.imdb);
    try expectOptional([]const u8, case.tvdb, p.tvdb);
    try expectOptional([]const u8, case.edition, p.edition);
    try expectOptional(u16, case.part, p.part);
    try expectOptional([]const u8, case.resolution, p.resolution);
    try expectOptional([]const u8, case.quality, p.quality);
    try expectOptional([]const u8, case.extra, p.extra);
}
