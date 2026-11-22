# Tools

Scripts that work alongside Cinematheque, outside the apps.

## Code debt

[debt.py](debt.py) reports declarations nothing uses (exiting 1 if any), files over 1,600 lines, and the spec's length in words, as [DEVELOPMENT.md](../DEVELOPMENT.md#practice)'s Practice asks before each push.

## A mock library

[mock-library.sh](mock-library.sh) makes a library folder for screenshots and demos, the same every run. Its titles are named for the serials Murderbot watches in Martha Wells's [Murderbot Diaries](https://murderbot.fandom.com/wiki/Category:Serials), and a few made-up movies in their spirit. Only the serials' names come from the books; every episode title, description, and genre is the script's own.

```sh
tools/mock-library.sh /tmp/cq-mock
tools/mock-library.sh --data /tmp/cq-mock-data /tmp/cq-mock
```

It refuses a directory that isn't empty unless it made it (marked by a hidden `.cinematheque-mock`), and clears one it did. It needs FFmpeg, and Swift (a Mac's) to set the covers' titles, by [mock-covers.swift](mock-covers.swift) in CoreText, as Homebrew's FFmpeg lacks `drawtext`; without Swift, the covers are plain gradients.

* **Movies,** each in a folder of its own, as Plex lays them out (`Movies/Title (Year)/Title (Year) 1080p.mp4`, beside its `poster.jpg`): Hostile Survey (2021) and its Director's Cut; Wormhole Drift (2024) in `1080p` and `2160p HDR`; The Last Gate Station (2019), its cover embedded in the MP4 (`covr`); The Long Haul Contract (2025); Hold the Corridor (2020); and Quiet Orbit (2022).
* **Series:**
  * The Rise and Fall of Sanctuary Moon: three seasons and a special. Season 1's cover is beside the season (`season01-poster.jpg`), season 2's in its folder, and season 3 and the special take the series'.
  * Worldhoppers: two seasons, with square covers.
  * Timestream Defenders Orion: a miniseries, its cover square.
  * Lineages of the Sun: two seasons, both with the series' cover.
  * Ring Station Tonight: a dated series, `Ring Station Tonight 2025-11-03 720p.mp4`, so a season a year, its cover square.
* **Videos:** silent H.264 MP4s, each a still of its title's color for a believable length (a movie's 95 to 126 minutes, an episode's 22 to 55). At one frame a second, each is under 250 KB, and progress, which isn't kept in a video's first 10 seconds, can stand partway. Each is tagged as describing reads MP4s (`©nam`, `desc`, `ldes`, `©gen`, `©day`, `tvsh`, `tvnn`). Its date is its release or air date, so Date Added and Date Modified sort the shelves. FFmpeg can't write the sort tags (`sonm`, `sosn`), so none sorts by another name.
* **Covers:** gradients with a pale disc and the title set large, portrait (2:3) or square, never landscape, as JPEGs named as Plex, Jellyfin, and Kodi name them (a movie's folder's `poster.jpg`, `season01-poster.jpg`, a season's or a series' `poster.jpg`).
* **`--data DATA`** also makes a data directory, building the command-line app if need be. It founds a library, serves the folder on `--port` (8642), adds it as a source, and crawls it. Then it sets progress: Sanctuary Moon watched into its second season, partway through its third episode; Hostile Survey and an episode of Worldhoppers partway; Wormhole Drift and all of Timestream Defenders Orion watched. And it makes lists through the web client's API, as the command-line app makes none: the Watchlist (two titles, a season, and two placeholders, a Worldhoppers season 3 and a movie, Station Siege), and Favorites. It prints how to serve it again.

