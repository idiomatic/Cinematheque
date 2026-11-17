# Naming experiment

Tests what is now **Naming** in [AGENTS.md](../../AGENTS.md), toward **Correlation** in [DEVELOPMENT.md](../../DEVELOPMENT.md): a Zig-native parser that turns a repository path into what a search for its title needs, following the Plex, Jellyfin, and Kodi naming guides and common scene names (see [docs/specifications](../../docs/specifications/README.md)).

## Running

```sh
zig build test                                  # fixtures
zig build --release=fast
curl -s http://127.0.0.1:8090/INDEX > /tmp/cinematheque-INDEX   # from the repository experiment
./zig-out/bin/names /tmp/cinematheque-INDEX
```

## Design

[src/parse.zig](src/parse.zig) uses hand-written scanners, not regular expressions:

* **Tags:** `{tmdb-…}`, `{imdb-…}`, `{tvdb-…}`, `{edition-…}`, and Jellyfin's `[imdbid-…]`, `[tmdbid-…]`, `[tvdbid-…]`, in file or folder names.
* **Episodes:** `S01E02`, `S01E02E03`, `S01E02-E03`, `1x02`, a bare `E02` inside a season folder, and air dates (`2026.11.16`); seasons also come from `Season 01` and `Specials` folders, and the series from the folder above.
* **Movies:** title and year from the movie's folder when it has a year, else from the file; only the last year ends the title ("Blade Runner 2049 (2017)"), and a leading number stays in it ("2001 A Space Odyssey (1968)", "1917 (2019)"); versions after ` - ` (Jellyfin); parts (`part1`, `cd2`, `disc 1`).
* **Extras:** Jellyfin's folders (`Trailers`, `Featurettes`, and others) and suffixes (`-trailer`, `-deleted`, and others).
* **Scene names:** dots and underscores become spaces except in acronyms ("S.W.A.T"), and the title ends at the first scene token (`1080p`, `BluRay`, `x264`, `WEB-DL`, and others).

[src/tests.zig](src/tests.zig) holds 39 fixtures drawn from the naming guides and scene names.

## Results

* All 39 fixtures pass.
* Over the [repository experiment](../repository/README.md)'s 100,000 paths: 80 ms (0.8 µs a path) on an Apple M2, finding 4,000 distinct movies and 96,000 episodes of 500 series, every one with a year.
* The first run merged 118 movies whose titles held a year-like number ("Movie 1950 (1950)" became "Movie"); taking only the last year fixed it.

### A real library

The 40,000 videos of four renditions on a real repository (see the [repository experiment](../repository/README.md)), named `Movies/<rendition>/Title (Year)[ - Edition].m4v` and `TV Shows/<rendition>/Show/Show 317 Episode Title.m4v`:

* The first run took nearly every episode for a movie: this library uses Kodi's compact episode code (`317` for season 3, episode 17; `1213` for 12 and 13), which the parser didn't read. It now reads one right after the series' title from the enclosing folder, compared on letters and digits only, past punctuation and a repeated year ("Show (2020) 101"), even when it looks like a year ("South Park 1908" is season 19); a folder note like "(from DVD)" no longer cuts the title short.
* After that, 77 files (0.18%) didn't parse: specials with no code or with code `100` or `300`, camera files named only by number, and episodes filed in another series' folder, which the title mismatch exposed.
* All 7,000 movies parsed with years, 226 with editions; they're 4,000 titles, 2,000 of them in two or more renditions. The 40,000 episodes are 20,000 episodes of 370 series, 10,000 of them in two or more renditions.
* 0.6 µs a path, as before.

## Findings

* **Parsing is cheap and local:** the whole library parses in a tenth of a second, so it can run on every crawl, on any peer; outside lookups are the cost.
* **Folders carry the best evidence:** Plex-style folders give the title and year, and season folders give seasons and series even when files are badly named.
* **Real libraries have house styles** the guides don't cover, and context (the enclosing folder) resolves most of them; what remains is few enough for the user to review, and it surfaces misfiled files.
* **Numbers are the hard part:** years inside titles, leading numbers, and episode-like tokens need ordered rules and fixtures; MIT-licensed parse-torrent-title's test corpus would broaden these.
* **Not yet tested:** real-world libraries, anime numbering (absolute episodes), multi-language titles, and searching TMDB with the results.
