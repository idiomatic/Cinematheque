# Tools

Scripts that work alongside Cinematheque, outside the apps.

## Code debt

[debt.py](debt.py) reports declarations nothing uses (exiting 1 if any), files over 1,600 lines, and the specs' lengths in words (exiting 1 if one's over its budget), as [DEVELOPMENT.md](../DEVELOPMENT.md#practice)'s Practice asks before each push.

## Release notes

[release-notes.sh](release-notes.sh) prints a version's section of [CHANGELOG.md](../CHANGELOG.md) (`tools/release-notes.sh 0.1`), failing if there's none, for the [release workflow](../.github/workflows/release.yml)'s notes.

## A mock library

[mock-library.sh](mock-library.sh) makes a library folder for screenshots and demos, the same every run. Its series are named for the serials in Martha Wells's [Murderbot Diaries](https://murderbot.fandom.com/wiki/Category:Serials), its movies made up; every episode title, description, and genre is the script's own.

```sh
tools/mock-library.sh /tmp/cq-mock
tools/mock-library.sh --data /tmp/cq-mock-data /tmp/cq-mock
```

It refuses a directory that isn't empty unless it made it (marked by a hidden `.cinematheque-mock`), and clears one it did. It needs FFmpeg, and Swift (a Mac's) to set the covers' titles, by [mock-covers.swift](mock-covers.swift) in CoreText, as Homebrew's FFmpeg lacks `drawtext`; without Swift, the covers are plain gradients.

* **Movies,** each in a folder of its own, as Plex lays them out (`Movies/Title (Year)/Title (Year) 1080p.mp4`, beside its `poster.jpg`): Hostile Survey (2021) and its Director's Cut; Wormhole Drift (2024) in `1080p` and `2160p HDR`; The Last Gate Station (2019), its cover embedded in the MP4 (`covr`); The Long Haul Contract (2025); Hold the Corridor (2020); and Quiet Orbit (2022).
* **Series:**
  * The Rise and Fall of Sanctuary Moon: 28 seasons of 419 weekly episodes from late 2018, and a special; a few episodes named, the rest by number. Its first twelve seasons have covers, the odd ones beside them (`season01-poster.jpg`), the even ones and the special in their folders; the rest take the series'.
  * Worldhoppers: two seasons of 12, with square covers.
  * Timestream Defenders Orion: a miniseries, its cover square.
  * Lineages of the Sun: two seasons, both with the series' cover.
  * Ring Station Tonight: a dated series, `Ring Station Tonight 2025-11-03 720p.mp4`, so a season a year, its cover square.
* **Videos:** silent H.264 MP4s, each one still for a believable length (a movie's 95 to 126 minutes, an episode's 22 to 55), so progress can stand partway: a movie's, a 720p band of its art; an episode's, its title's color. One frame a second at a constant quantizer (rate control would add detail to a still frame, ten times the bytes) keeps a movie's to about a megabyte. Each is tagged as describing reads MP4s (`©nam`, `desc`, `ldes`, `©gen`, `©day`, `tvsh`, `tvnn`; FFmpeg can't write `sonm` or `sosn`), and dated by its release or air date, so Date Added and Date Modified sort.
* **Covers:** the title set large over its art from [mock-art/](mock-art/prompts.md) (FLUX.1 [schnell], prompts and seeds recorded there), else a gradient; 2:3 or square JPEGs, named as Plex, Jellyfin, and Kodi name them.
* **`--data DATA`** also makes a data directory (building the command-line app if need be): it creates a library, serves the folder on `--port` (8642), adds and crawls it, sets some progress (titles watched, partway, and untouched), and makes the Watchlist (titles, a season, and two placeholders by `want add`) and Favorites through the web client's API, as the command-line app makes no lists. It prints how to serve it again.

Simulators named `Mockup …` run the mock library; `Production …` ones are a developer's own, untouched here. Everything on the mock library uses `_cinemock._tcp` (`CINEMATHEQUE_DNSSD`; `SIMCTL_CHILD_CINEMATHEQUE_DNSSD` for a simulator, `open --env` for the Mac app), so it and a person's own devices never see each other. For the simulators, it lives in `~/Library/Application Support/Cinematheque-mock/` (`media`, `data`, and a `serve` data directory with its own `bin/cinematheque`), served at `http://127.0.0.1:8642/media/`, the source its library names, while it runs:

```sh
M=~/Library/Application\ Support/Cinematheque-mock
CINEMATHEQUE_DNSSD=_cinemock._tcp "$M/bin/cinematheque" --data "$M/serve" serve --port 8642 --media "$M/media"
```

A debug build runs on a copy of its data, `SIMCTL_CHILD_CINEMATHEQUE_DATA=/tmp/cq-data xcrun simctl launch booted com.rbrian.cinematheque`, or a copy in the app's own data directory (`Library/Application Support/Cinematheque` in `xcrun simctl get_app_container booted com.rbrian.cinematheque data` on iOS; `Library/Caches/Cinematheque` on tvOS) runs on it at every launch.

## Screenshots

[screenshots.sh](screenshots.sh) takes the README's pictures of every player, in dark and light appearance, into [docs/screenshots](../docs/screenshots): `tools/screenshots.sh`, or some of `mac`, `tv`, `iphone`, and `web`; `video` (only when named, as it takes longer) also records the loop. It makes a fresh mock library (above), serves it on port 8649 (so a developer's 8642 is left alone), and builds the apps, Debug, for their launch options ([AGENTS.md](../AGENTS.md#debugging)).

* **The iPhone** (`Mockup iPhone 17`): Home, the Series tab, and a season's page, side by side by [side.swift](screenshots/side.swift), as one tall screen would stand far above the README's row; its status bar at 9:41.
* **The Apple TV** (the `Mockup Apple TV 4K` simulator, a 3rd generation one, scaled to 1080p): a season's page, opened by its Top Shelf link so Resume is focused.
* **The web client:** Movies, 960×720 points, rendered by [web.swift](screenshots/web.swift) in WebKit once every cover on screen has loaded, in a clear window on screen, as WebKit runs no animation frames off screen.
* **The Mac,** in a terrarium VM (`macos-27.2-quiet`, 4 GB; the command is `$TERRARIUM`, else `terrarium`): the Series shelf, a band open, the inspector on that season. It answers the Local Network prompt (shooting again if it was up), sizes the window by dragging it (SwiftUI resizes one the app sizes), and crops to the window by [frame.swift](screenshots/frame.swift), found by [windows.swift](screenshots/windows.swift) in the guest. A Retina display (`--retina`), 1440×900 points.

* **The hero,** when the Mac's and the Apple TV's are both taken: the Mac's window, and in front of its lower right, the Apple TV's Home in a thin black bezel, by [hero.swift](screenshots/hero.swift).
* **The loop** (`video`): Hold the Corridor played on the Mac, skipped ahead 30 seconds, and left (Escape), then, once the Mac's sync has reached it, resumed on the Apple TV, from its Home. The Apple TV is another of the mock person's devices, paired by the command-line app before either app starts; the Mac reaches it by DNS-SD or the host's address, added. The Mac is driven at a person's pace in a 16:9 window, recorded by terrarium's `record`; the Apple TV plays by its Top Shelf link (`&play=1`), recorded by `simctl io recordVideo`. Each half is cut to 1280×720 at 15 frames a second with half-second fades, and both made a looping WebP by `img2webp` at quality 85 (lower leaves blocks in fades), as GitHub shows one inline; dark appearance only.

A shot is taken once the screen holds still for three frames in a row, not after a fixed wait. Each PNG is squeezed by `pngquant`, then `oxipng`, each if installed.

