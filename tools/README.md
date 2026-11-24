# Tools

Scripts that work alongside Cinematheque, outside the apps.

## Code debt

[debt.py](debt.py) reports declarations nothing uses (exiting 1 if any), files over 1,600 lines, and the spec's length in words, as [DEVELOPMENT.md](../DEVELOPMENT.md#practice)'s Practice asks before each push.

## Release notes

[release-notes.sh](release-notes.sh) prints a version's section of [CHANGELOG.md](../CHANGELOG.md) (`tools/release-notes.sh 0.1`), failing if there's none, for the [release workflow](../.github/workflows/release.yml)'s notes.

## A mock library

[mock-library.sh](mock-library.sh) makes a library folder for screenshots and demos, the same every run. Its titles are named for the serials Murderbot watches in Martha Wells's [Murderbot Diaries](https://murderbot.fandom.com/wiki/Category:Serials), and a few made-up movies in their spirit. Only the serials' names come from the books; every episode title, description, and genre is the script's own.

```sh
tools/mock-library.sh /tmp/cq-mock
tools/mock-library.sh --data /tmp/cq-mock-data /tmp/cq-mock
```

It refuses a directory that isn't empty unless it made it (marked by a hidden `.cinematheque-mock`), and clears one it did. It needs FFmpeg, and Swift (a Mac's) to set the covers' titles, by [mock-covers.swift](mock-covers.swift) in CoreText, as Homebrew's FFmpeg lacks `drawtext`; without Swift, the covers are plain gradients.

* **Movies,** each in a folder of its own, as Plex lays them out (`Movies/Title (Year)/Title (Year) 1080p.mp4`, beside its `poster.jpg`): Hostile Survey (2021) and its Director's Cut; Wormhole Drift (2024) in `1080p` and `2160p HDR`; The Last Gate Station (2019), its cover embedded in the MP4 (`covr`); The Long Haul Contract (2025); Hold the Corridor (2020); and Quiet Orbit (2022).
* **Series:**
  * The Rise and Fall of Sanctuary Moon: as long as the Murderbot Diaries have it, 28 seasons (Murderbot's favorite arc is the 28th's) of 419 weekly episodes from late 2018 (the books reach episode 397; the TV series' Murderbot is missing 420 on), 15 a season and the last 14, and a special; the first four of the first three seasons named, the rest by number. Its first twelve seasons have covers, the odd ones beside them (`season01-poster.jpg`), the even ones and the special in their folders, and the rest take the series'.
  * Worldhoppers: two seasons of 12, so its 20th and 24th episodes are there (a major character's death and return, in *Artificial Condition*), with square covers.
  * Timestream Defenders Orion: a miniseries, its cover square.
  * Lineages of the Sun: two seasons, both with the series' cover.
  * Ring Station Tonight: a dated series, `Ring Station Tonight 2025-11-03 720p.mp4`, so a season a year, its cover square.
* **Videos:** silent H.264 MP4s, each one still for a believable length (a movie's 95 to 126 minutes, an episode's 22 to 55): a movie's, a 720p band of its art from `mock-art/`, so playing one looks like a scene; an episode's, its title's color. At one frame a second, and a constant quantizer (x264's rate control otherwise adds detail to a still frame after frame, ten times the bytes), a movie's is about a megabyte and an episode's under 250 KB, and progress, which isn't kept in a video's first 10 seconds, can stand partway. Each is tagged as describing reads MP4s (`©nam`, `desc`, `ldes`, `©gen`, `©day`, `tvsh`, `tvnn`). Its date is its release or air date, so Date Added and Date Modified sort the shelves. FFmpeg can't write the sort tags (`sonm`, `sosn`), so none sorts by another name.
* **Covers:** the title set large over each title's art from [mock-art/](mock-art/prompts.md) (made with FLUX.1 [schnell], one per title and season, text-free, their prompts and seeds recorded there), darkened under the type; where there's none, a gradient with a pale disc; portrait (2:3) or square, never landscape, as JPEGs named as Plex, Jellyfin, and Kodi name them (a movie's folder's `poster.jpg`, `season01-poster.jpg`, a season's or a series' `poster.jpg`).
* **`--data DATA`** also makes a data directory, building the command-line app if need be. It founds a library, serves the folder on `--port` (8642), adds it as a source, and crawls it. Then it sets progress: Sanctuary Moon's first season watched, and into its second, partway through its third episode; Hostile Survey and an episode of Worldhoppers partway; Wormhole Drift and all of Timestream Defenders Orion watched. And it makes lists through the web client's API, as the command-line app makes none: the Watchlist (two titles, a season, and two placeholders, a Worldhoppers season 3 and a movie, Station Siege), and Favorites. It prints how to serve it again.

Simulators named `Mockup …` (`Mockup iPhone 17`, `Mockup iPhone 13 mini`, `Mockup Apple TV 4K`) run the mock library; those named `Production …` are a developer's own, on their own library, and nothing here touches them. Everything on the mock library announces and looks for `_cinemock._tcp` (`CINEMATHEQUE_DNSSD`, which these scripts set, as must anything else run on it: `SIMCTL_CHILD_CINEMATHEQUE_DNSSD` for a simulator, `open --env` for the Mac app), so it never sees a person's own devices, nor they it. For the simulators, the mock library lives in `~/Library/Application Support/Cinematheque-mock/` (`media`, `data`, and a `serve` data directory with its own `bin/cinematheque`), served at `http://127.0.0.1:8642/media/`, the source its library names, while it runs:

```sh
M=~/Library/Application\ Support/Cinematheque-mock
CINEMATHEQUE_DNSSD=_cinemock._tcp "$M/bin/cinematheque" --data "$M/serve" serve --port 8642 --media "$M/media"
```

A debug build runs on a copy of its data, `SIMCTL_CHILD_CINEMATHEQUE_DATA=/tmp/cq-data xcrun simctl launch booted com.rbrian.cinematheque`, or a copy in the app's own data directory (`Library/Application Support/Cinematheque` in `xcrun simctl get_app_container booted com.rbrian.cinematheque data` on iOS; `Library/Caches/Cinematheque` on tvOS) runs on it at every launch.

## Screenshots

[screenshots.sh](screenshots.sh) takes the README's pictures of every player, in dark and light appearance, into [docs/screenshots](../docs/screenshots): `tools/screenshots.sh`, or some of `mac`, `tv`, `iphone`, and `web`; `video` (only when named, as it takes longer) also records the loop. It makes a fresh mock library (above), serves it on port 8649 (so a developer's 8642 is left alone), and builds the apps, Debug, for their launch options ([AGENTS.md](../AGENTS.md#debugging)).

* **The iPhone** (the `Mockup iPhone 17` simulator): Home, the Series tab, and that season's page, side by side by [side.swift](screenshots/side.swift), each with the iPhone's rounded corners, as one tall screen stood far taller than the others in the README's row; its status bar at 9:41.
* **The Apple TV** (the `Mockup Apple TV 4K` simulator, a 3rd generation one, scaled to 1080p): a season's page, opened by its Top Shelf link, as a person's press opens it, Resume focused (pushed by `CINEMATHEQUE_SELECT` at launch, focus went to Start Over).
* **The web client:** Movies, 960×720 points, rendered by [web.swift](screenshots/web.swift) in WebKit once every cover on screen has loaded, in a clear window on screen, as WebKit runs no animation frames off screen.
* **The Mac,** in a terrarium VM (`macos-27.2-quiet`, 4 GB; the command is `$TERRARIUM`, else `terrarium`): the Series shelf, a band open, the inspector on that season. It answers the Local Network prompt whenever it comes, shooting again if it was up, sizes the window by dragging it as a person would (SwiftUI sizes it again after the app could), and crops the shot to the window, its corners clear, by [frame.swift](screenshots/frame.swift), finding it by [windows.swift](screenshots/windows.swift) in the guest (`screencapture` can't there, without Screen Recording permission). A Retina display (`--retina`), 1440×900 points, as the others are 2× or more.

* **The hero,** when the Mac's and the Apple TV's are both taken: the Mac's window, and in front of its lower right, the Apple TV's Home in a thin black bezel, by [hero.swift](screenshots/hero.swift).
* **The loop** (`video`): Hold the Corridor played on the Mac, skipped ahead 30 seconds, and left (Escape), then, once the Mac's sync has reached it, resumed on the Apple TV, from its Home. The Apple TV's device is another of the mock person's, paired by the command-line app and caught up from the Mac's before either app starts; the Mac reaches it by DNS-SD, or by the host's address on the VM's network, added. The Mac is driven at a person's pace (the pointer gliding, pauses between steps) in a 16:9 window, recorded by terrarium's `record`; the Apple TV, its remote out of a script's reach, plays it by its Top Shelf link (`&play=1`), recorded by `simctl io recordVideo`. Each half is cut to 1280×720 at 15 frames a second, fading in from black and out to it (half a second each, as the apps fade playing), and the two are made a looping, lossy WebP by `img2webp` (at quality 85, as at lower ones it takes a fade's small changes for none, leaving blocks of the frames before) (GitHub shows one inline, not a video committed beside the README); dark appearance only.

A shot is taken once the screen holds still for three frames in a row, not after a fixed wait. Each PNG is squeezed by `pngquant` (to a palette, about a quarter the bytes, alike at a README's sizes), then `oxipng`, each if it's installed (`brew install pngquant`).

