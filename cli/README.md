# Command-line app

The command-line app, `cinematheque`, for macOS and Linux, built on the [core](../core/README.md). It does everything a player does but play: it creates or joins a library, pairs devices, crawls sources, records progress, and serves and syncs with other devices. Run in the background, it's a library's always-on hub.

## Building

It needs [Zig](https://ziglang.org) 0.17 or later and SQLite (built into macOS; on Linux, your distribution's package). On Linux, finding other devices needs Avahi and its Bonjour compatibility library (`libdns_sd`; e.g., `avahi` and `avahi-compat-libdns_sd` on Alpine).

```sh
zig build --release=safe
cp zig-out/bin/cinematheque ~/bin/   # or anywhere on your PATH
./test.sh       # devices, a generated source, sync, and every command
```

[build.zig](build.zig) builds the app and, with `zig build gen`, the test source's generator. `cinematheque --version` prints the version [Version.xcconfig](../apple/Version.xcconfig) sets, then what it was built from (`git describe`), its optimizing, and its Zig.

## Getting started

Create a library, add a source, and see what's in it:

```sh
cinematheque library create
cinematheque source add http://nas.local/Video/Movies/
cinematheque crawl
cinematheque ls "All Systems Red"
cinematheque show t/m/all-systems-red/2017
```

`ls` prints each title's key; `show` prints everything about one: its versions or episodes, and where each copy is. What a source needs, and how to name files so titles are recognized, are in the [guide](../docs/guide.md#sources).

## Data directory

Created on first use. On macOS it's the Mac app's too, so both act as one device; `--data DIR` or `CINEMATHEQUE_DATA` names another, so one computer can run several devices, as [test.sh](test.sh) does.

| File | Holds |
|---|---|
| `identity` | The device's random seed, from which its keys derive |
| `user` | The person's seed, once this device is paired as another of the person's; until then, the person's seed derives from the device's |
| `library` | The library's creator's person key, once this device has a library |
| `replica.db` | The replica: the library's operations, and in its `local` table, what's this device's alone (crawl snapshots, and devices added by URL) |

`identity` and `user` are secrets: anyone with the person's seed can act as the person. Don't copy a data directory to another device; pair it instead.

## Commands

[usage.txt](src/usage.txt) is the full help, built into the binary (`-h`, or `cinematheque source -h` for one noun's). Options are named and may come anywhere. Keys are 64 hexadecimal digits; titles and items are keys as `ls` and `show` print them (`t/s/firefly/-/e/s01e01`); a source is its ID or URL. A failure prints `error:` and what to do, e.g., `error: this device has no library: create one (library create), or join one (library join)`.

### People, members, and devices

```sh
cinematheque person show                 # this person's key
cinematheque person set --name Avery
cinematheque device set --name hal
cinematheque member list
cinematheque device remove KEY           # it's told so at its next sync
cinematheque library leave               # remove this device, sync, forget
```

`library show` prints the library's digest, a hash of every field's winning value, the same on two devices that have synced fully. Pairing is under [Sharing a library](#sharing-a-library).

### Sources and crawling

```sh
cinematheque source add http://nas.local/Video/ --skip ,
cinematheque source add http://nas.local/HQ/ --quality "HQ 1080p30 Surround"
cinematheque source show SOURCE
cinematheque crawl --full
```

Without `--quality`, each file's quality is read from its name and folders: `Video/TV Shows/1080p/30 Rock/30 Rock 101 Pilot.mkv` is `1080p`. `--full` lists every directory afresh, as a file retagged in place doesn't change its directory's time. `crawl` prints a line per source (requests, files, titles added, copies changed, and duplicates), then one of describing's totals.

`source show` lists unavailable folders (`unavailable     /archive0001, since 3 days ago`); `source remove SOURCE --unavailable DIR` drops their copies at once.

### Titles and progress

```sh
cinematheque ls alien
cinematheque progress set t/m/alien/1979 3600 7020   # seconds
cinematheque progress set t/s/firefly/-/e/s01e01 --watched
cinematheque progress list t/s/firefly/-
```

### Placeholders

A placeholder puts a title not in the library yet on one of your lists; its file's tile takes its place when it comes, if named as the placeholder is (see [the guide](../docs/guide.md#naming)). A list is named, ignoring case, or given by ID.

```sh
cinematheque want add "Coming Soon" "Pendulum" --year 2027
cinematheque want add "Coming Soon" "Silo" --season 3 --note "Apple TV"
```

`want list` prints them tab-separated (list, key, name, note); `want remove LIST KEY` takes one off by key (`t/s/silo/-#3`).

### Syncing and serving

```sh
cinematheque serve --media ~/Movies     # until stopped
cinematheque sync                        # every device found or added
cinematheque sync http://hal.local:8008  # one
cinematheque refresh --jitter 600
cinematheque library set --crawl 3       # hours, for every device
```

`sync` prints a line per device: operations pulled, new, lost (older than what's held), known, rejected (from a device not yet admitted), and refused (past a cutoff); then batches, size, how many were pushed, and time. An unreachable device prints its error and the rest go on.

`serve --media DIR` makes this device a source; the web client's Settings adds it as `cqdevice://<device key>/media/`.

### In a browser

`serve` serves a web client at `http://<host>:8008/`. On a device with no library, it starts anyway and the web client sets one up, so `serve --media DIR` and a browser on the same computer make a working library with no other device: create it, add the served folder as a source, and Refresh Library.

It browses, plays (MP4, M4V, and MOV, straight from the sources, the server racing copies), downloads to the browser's computer through the server, and has the apps' Settings. Covers come through the server, as a source's server won't let another site's page read its files.

A browser has no keys, so it acts as this device's person, and only one on this computer may: `localhost`, or an SSH tunnel's end (`ssh -L 8008:localhost:8008 hal`). `serve --permissive` is for a network where everyone reaching the port may. A proxy on the same computer would be taken for a local browser, so put none in front of it.

On macOS, Local Network privacy is asked of the app that started `cinematheque`, so start it from one allowed in System Settings › Privacy & Security › Local Network, as Terminal can be. Some apps' built-in terminals (OpenCode's, say) run it under a helper that isn't allowed even when the app is; every connection to another device then fails at once (`HostUnreachable`).

### In the background

Run `serve` with systemd on Linux (or however you like), and `refresh --jitter 600` hourly by a timer or cron: each refresh waits up to 10 minutes, so devices don't refresh together, syncs every time, and crawls as often as the library says. On macOS, a launch agent can't reach the local network (see [DEVELOPMENT.md](../DEVELOPMENT.md)), so run them in Terminal.

## Sharing a library

```sh
# on hal: found a library, and fill it
cinematheque library create
cinematheque source add http://nas.local/Video/
cinematheque crawl
cinematheque serve &              # share it while it runs

# on perihelion, another of your devices
cinematheque person pair            # prints a code, waits
# on hal
cinematheque person pair CODE

# on art, someone else's device
cinematheque library join         # prints a code, waits
# on hal
cinematheque member pair CODE

# on perihelion or art
cinematheque sync
```

Without DNS-SD between them (across networks), pass the new device's pairing URL after the code: the port it prints, at `/pair`, on an address the sender can reach.

```sh
# on art: prints a code, and "listening for it on port 49152"
cinematheque library join
# on hal
cinematheque member pair CODE http://art.example.net:49152/pair
```

Then sync from a device by URL, and add it, so later syncs and refreshes reach it too:

```sh
cinematheque sync http://hal.example.net:8008
cinematheque device add http://hal.example.net:8008
```

## The web client in detail

Plain HTML, CSS, and JavaScript embedded in the app, no framework; what it must do is in [AGENTS.md](../AGENTS.md#command-line-app).

* **Layouts** switch at 768 pixels, by a media query and `wide` in [app.js](src/web/app.js); crossing it shows the page again, as search then applies or doesn't. Wide has no Home (an empty address shows Movies); search filters the shelf shown, and typed on a title's page goes back to its shelf. Narrow, Search shows movies, then a tile per series, as the Apple TV's. `#in-progress` redirects to `#watching`.
* **Carousels:** every cover one height, its width by `--shape`: the tile's `aspect` (so rows lay out before covers load), else 2:3 or square, then the loaded cover's own if different, snapped to 2:3, square, 4:3, or 16:9. A season's cover of another shape fits whole in its grid cell.
* **Lists:** Rename, Share, and Delete use the browser's own prompt and confirm. The shared mark is an SVG in the text's color, as an emoji would keep its own.
* **Order:** a menu beside search, sized to the order shown (`field-sizing`), kept per shelf and list in `localStorage`.
* **Group by Series:** a checkbox on the Series shelf, kept in the browser (the Search tab's always grouped). A series' tile shows its first season's cover; its year wraps by `flex-wrap`, without measuring. Its band (`toggleBand`) follows the last tile of its row, its point placed again as the window resizes, and grows by `grid-template-rows` from `0fr` to `1fr`, none under Reduce Motion.
* **Place:** a shelf left is kept (`kept`) whole, with its scroll and open series. Shown again, a trial run of its builder that draws no tiles (`makeup`, `fill` noting its items) finds its makeup: its headings, and its tiles' identities in order. If it matches, the kept page is put back and only tiles whose data changed are drawn again (`patch`: each tile keeps the identity and look it was drawn from), as React or SwiftUI diffs a view; covers still loading load again as they near the screen. Else it's built anew and put back where it was (`places`: the series reopened without growing, and scrolled there once enough is built, a slice a frame). A page's late `route()` landing on a shelf patches it rather than resetting it. `history.scrollRestoration` is off, as the browser scrolled before a shelf was rebuilt. A new search, order, or grouping calls `route({ fromTop: true })`.
* **Loading:** a screenful first, the rest a slice a frame. Covers are fetched as tiles near the screen, three at a time, nearest first; a tile leaving before its turn gives it up, and a page left stops its covers, as a source's disks waking can hold covers for seconds, and they mustn't take the browser's six connections to the server, which pages and playing need.
* **Tiles:** `marksView` draws the marks, `watchedMark` the check in an item's row.
* **Status line:** the shelf's counts (a series shelf's seasons and episodes too), fading 3 seconds after changing and back as the pointer nears; a problem stays until replaced.
* **Title page:** laid out as the Mac's inspector. The quality pop-up lists what the browser plays, best first, and is text for one. The cover's column narrows before Play's row would wrap. A season's episodes are described as it's shown, each once a page load.
* **Playing:** a history entry, so Back or Escape leaves it; the window's title names what's playing.
* **API,** under `/api/`:
  * the apps' tile and title JSON (shared with the C interface, in [views.zig](../core/src/views.zig));
  * covers (a source's byte range, fetched by the server and cached for good);
  * copy racing (`race`, `lost`), and describing an episode (`describe`);
  * this person's writes (`progress`, `watched`, `listed`, `list-create`, `list-rename`, `list-remove`, and `list-share`);
  * a copy's file to save (`file`, streamed from its source as an attachment named as there, passing a `Range` on, under the core's download deadlines). Download says nothing of space, the browser's computer's business.
* **Its own page alone:** the host check refuses a site rebinding its name to this device; changes must be same-origin JSON, which another site's page can't send without asking first. Open it by address or `.local` name.

## Limits

What's planned for them is in [DEVELOPMENT.md](../DEVELOPMENT.md).

* There's no Windows build yet.

## Code

* [main.zig](src/main.zig): the command line. `Args` parses words and options (an option not among the flags takes the next word) and expands `ls` and `show`. `Command.is` matches a verb, its arity, and its options. Nouns and actions are tables of functions; `help` prints a part of the embedded [usage.txt](src/usage.txt). It opens the data directory and the `App` every command acts with (store, output, clock), and turns `error.Usage` into help and status 2.
* [commands.zig](src/commands.zig): the state nouns, a function each; sending pairing codes (`pairWith`, finding the one device offering nearby); and `crawl` and `refresh`.
* [network.zig](src/network.zig): `serve`, advertising once it knows its port; `sync`, with the device given or every one found by DNS-SD and in `local` (`address:URL`), as `syncEvery` does for `refresh`, through `exchangeAll`; `device`'s addresses; and `offerPairing`, serving an offer until taken or 3 wrong codes.
* [web.zig](src/web.zig): the web client's server: its embedded files; which browser acts as this device (`local`); syncs answered as this device is now (`snapshot`); and the API.
* [setup.zig](src/setup.zig): setup (creating, or offering to join at `/pair` on the same port, advertising afresh as it changes), Settings' API, and `keepRefreshed`, running Refresh Library on a task of its own.
* [web/](src/web): the page (its `favicon.ico` drawn by [draw-icons.swift](../apple/draw-icons.swift)), as classic scripts sharing one scope: [settings.js](src/web/settings.js) (setup, the refusal of a browser elsewhere, and Settings), [app.js](src/web/app.js) (shelves, title pages, downloads, and playing), and [route.js](src/web/route.js) (addresses, and starting the app past setup).
* [test.sh](test.sh): the end-to-end test. Devices on one computer, each with its own data directory, found a library and serve a generated source as media; they crawl, pair at the ports their offers print, and sync until their digests match. It checks that a removed member is refused and that progress travels only between the person's devices.
* [test/gen.zig](test/gen.zig): the test source's generator (`gen DIR [DIVISOR]`): a media tree at the library's full scale, or a fraction, named as Plex and Jellyfin expect, of sparse files.

The library itself, from parsing names to syncing, is the [core](../core/README.md)'s; how its operations work is in [ARCHITECTURE.md](../ARCHITECTURE.md).

## On a real source

Crawling a Caddy server on a NAS over Wi-Fi, with a folder per quality (each added as a source, its quality named) and tens of thousands of files, took under a second with 32 workers; a second crawl, with nothing changed, took about 1% of the first's requests. Review found a few dozen close matches (mostly years off by one or missing) and duplicate files: `.m4v` and `.mp4` copies, episode codes used twice, and a part beside its whole. A second device synced the library (about 100,000 operations) in under half a second, and an alias reached it as one operation.
