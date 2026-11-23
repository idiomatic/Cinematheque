# Command-line app

The command-line app, `cinematheque`, for macOS and Linux, built on the [core](../core/README.md). It does everything a player does but play: it founds or joins a library, pairs devices, crawls sources, reviews what it found, records progress, and serves and syncs with other devices. Run in the background, it's a library's always-on hub.

## Building

It needs [Zig](https://ziglang.org) 0.17 or later and SQLite (built into macOS; on Linux, your distribution's package). On Linux, finding other devices on your network needs Avahi and its Bonjour compatibility library (`libdns_sd`; e.g., `avahi` and `avahi-compat-libdns_sd` on Alpine).

```sh
zig build --release=safe
cp zig-out/bin/cinematheque ~/bin/   # or anywhere on your PATH
./test.sh       # devices, a generated source, sync, and every command
```

[build.zig](build.zig) builds the command-line app and, with `zig build gen`, the test source's generator. `cinematheque --version` prints its version, as [Version.xcconfig](../apple/Version.xcconfig) sets it, then what it was built from (`git describe`), its optimizing, and its Zig.

## Getting started

Create a library, add a source, and see what's in it:

```sh
cinematheque library create
cinematheque source add http://nas.local/Video/Movies/
cinematheque crawl
cinematheque ls "All Systems Red"
cinematheque show t/m/all-systems-red/2017
```

`ls` prints each title's key, such as `t/m/all-systems-red/2017`; `show` prints everything about one: its versions or episodes, and where each copy is. What a source needs, and how to name files so titles are recognized, are in the [README](../README.md#preparing-a-source).

## Data directory

The app keeps its state in its data directory, created on first use: by default `~/Library/Application Support/Cinematheque` on macOS (the Mac app's too, so both act as one device), and `$XDG_DATA_HOME/cinematheque` or `~/.local/share/cinematheque` on Linux. `--data DIR` or `CINEMATHEQUE_DATA` names another, so one computer can run several devices, as [test.sh](test.sh) does.

| File | Holds |
|---|---|
| `identity` | The device's random seed, from which its keys derive |
| `user` | The person's seed, once this device is paired as another of the person's; until then, the person's seed derives from the device's |
| `library` | The library's founder's person key, once this device has a library |
| `replica.db` | The replica: the library's operations, and in its `local` table, what's this device's alone (crawl snapshots, and devices added by URL) |

`identity` and `user` are secrets: anyone with the person's seed can act as the person. Don't copy a data directory to another device, as each device needs its own identity; pair the other device instead.

## The command line

State commands are `NOUN VERB [ARGUMENTS]`, over the nouns `person`, `library`, `member`, `source`, `title`, `alias`, `progress`, and `device`. Whole-app actions are single words: `crawl`, `sync`, `serve`, and `refresh`. `ls` and `show` are shortcuts for `title list` and `title show`.

* **Options** are named and may come anywhere. `--port PORT`, `--media DIR`, `--downloads DIR`, `--to DIR`, `--quality NAME`, `--quality-by folder|name`, `--skip PREFIX`, `--unavailable DIR`, `--crawl EVERY`, `--jitter SECONDS`, and `--workers WORKERS` take a value; `--web`, `--full`, `--leave`, `--watched`, and `--unwatched` are flags. `--data DIR` works with every command.
* **Help:** [usage.txt](src/usage.txt) lists every command and is the help, built into the binary. `-h` or `--help` prints it all; with a noun or action (`cinematheque source -h`), or a noun alone, only that one's commands.
* **Arguments:** keys are 64 hexadecimal digits, as `person show` prints them. Titles and items are keys, as `title list` and `title show` print them (`t/m/alien/1979`, `t/s/firefly/-/e/s01e01`). A source is its ID (16 hexadecimal digits) or its URL.
* **Exit status:** 0 on success. A command line that isn't one prints the help for its noun (or all of it) and exits with status 2. Any other failure says why in words after `error:` (e.g., `error: this device has no library: create one (library create), or join one (library join)`), with no trace, and exits with status 1.

## Commands

[usage.txt](src/usage.txt) has their syntax; this says what each does and prints.

### People and libraries

* `person show` prints this person's key, as `member remove` and `library handover` take it.
* `person pair`, on a new device without a library, prints a 6-digit code and the port it listens on, and waits, serving `/pair` on that port and advertising itself (`pair=new`, named by the computer's host name). On a member's device, `person pair CODE` finds it nearby, or at the URL given, and adds it as another of this person's devices, sending it the person's seed and the library's founder, sealed by the code (see [pair.zig](../core/src/pair.zig)). The new device prints whose it is and exits. A sender that found it nearby names it as it advertised itself, under its person.
* `library create` founds a library with this person as founder, and prints its ID. `library join` offers a code, as `person pair` does. A code is the only way in, so the person's seed is never shown.
* `library show` prints the library's ID, founder, member count, and digest: a hash of every field's winning value, the same on two devices that have synced fully.
* `library handover PERSON` makes a member the founder; this person stays a member unless `--leave`. Only the founder may.

### Members

* `member list` prints the members' keys, marking the founder and you.
* `member pair CODE [URL]` adds a new device offering a code as a new member's, admitting its person, and sends it the library's founder.
* `device list` prints this person's devices (named or not). `device remove DEVICE` removes one: its later writes are refused, and when it next syncs it's told so, signed, and prints that it should `library leave`, which forgets the library and its identity so it can pair again as a new device.
* `member remove PERSON` removes a member, but not the founder. Their devices' writes up to what this device has seen stand; later ones are refused everywhere.

### Sources and crawling

* `source add URL` adds a source, its URL percent-encoded as typed and given a trailing slash, and prints its ID, a hash of the URL. `--quality NAME` names its files' quality (e.g., a HandBrake preset's); `--quality-by folder` takes each file's from the first folder within the source, for one folder of qualities holding them all (`Movies/HQ 1080p30 Surround/Alien (1979).m4v`); `--skip PREFIX` skips names beginning with it (default `,`).
* `source list` and `source show SOURCE` print sources' settings; `show` adds how many copies the source holds.
* `source set SOURCE` changes `--quality`, `--quality-by` (`folder` or `name`), or `--skip`, applied at the next crawl. `source remove SOURCE` removes the source and every copy it had, for every device.
* A directory that held files and lists none now (an unplugged drive's mount point) is unavailable: its copies stay, `crawl` counts it, and `source show` lists it (`unavailable     /archive0001, since 3 days ago`). It clears once the drive is back. Its copies go on their own after a year, or at once, as if deleted, by `source remove SOURCE --unavailable DIR`.
* `crawl [SOURCE]` crawls every source, or one, with 16 concurrent workers unless `--workers` says otherwise. It reuses the last crawl's listing of any directory whose modification time hasn't changed; a file rewritten in place (retagged) doesn't change it, so `--full` lists every directory afresh. It prints a line per source (requests, files, titles added, copies changed, and duplicates), then describes covers and metadata, with one line of totals.

### Titles

* `title list [TEXT]` (`ls`) prints each title some source holds whose name contains the text, ignoring case: its year, kind, episodes or versions, qualities, and key, with `-> TARGET` if it's an alias. A count ends the list.
* `title show TITLE` (`show`) prints a title's fields, its aliases, and each item: its fields, your progress, and per quality, every copy's size, modification time, and URL.
* `title download TITLE` fetches a title's files (or a season's, `TITLE/e/s01`, or an item's) into the current directory or `--to DIR`, under their paths in the source, so the directory can be served and added as a source of its own. It takes `--quality NAME`, else the quality most of the items have; tries the copy whose server answers first, then the others; and resumes a file cut short (`<path>.part`) by a range request. Mind the size: a 2160p remux runs to 60 GB.
* `title review` prints close matches and duplicate files, tab-separated: the reason, then the two titles or files. A summary ends it.

  ```
  year off by one   t/m/rogue-protocol/2018   t/m/rogue-protocol/2019
  year missing      t/s/worldhoppers/-        t/s/worldhoppers/2024
  duplicate         .../Worldhoppers 105.m4v  .../Worldhoppers 105.mp4
  ```

  Some are mistakes to fix in the source; others are different titles (a series and its reboot may share a name). `alias add TITLE TARGET` records that two are the same, `alias remove TITLE` undoes it, and `alias list` prints them. Aliases replicate, so one device records each once for everyone.
* `title facets` counts titles by kind, decade, and quality, tab-separated.

### Progress

* `progress list [TITLE]` prints this person's progress, or a title's: each item, whether watched, and where it's at.
* `progress set ITEM POSITION DURATION` records a position, in seconds, by the core's rules: within the last 5% marks the item watched, and within the first 10 seconds clears the position. `progress set ITEM --watched` (or `--unwatched`) marks it by hand, and `progress remove ITEM` forgets it.

Progress is private: it's written on this device's private stream, and travels only directly between the person's devices.

### Devices, syncing, and serving

* `serve` answers other devices' syncs (`/sync`) until stopped, and prints a line once listening, with the web client's address. It listens on `--port`, else on 8008, or any free port if 8008 is taken, and advertises the port it got by DNS-SD, with the library, the person, and the names of this device and person.
  * `--media DIR` serves a directory of videos at `/media/`, making this device a source too (added as `http://<host>:8008/media/`): byte ranges, listings as JSON or HTML, and an `INDEX` of every file and directory, built at start and again on a request once it's a minute old.
  * The web client is served at the root (see [In a browser](#in-a-browser)), unless `--no-web`; `--permissive` lets every browser that reaches the port act as this device, not only one on this computer.
  * `--downloads DIR` keeps this device's downloads in DIR, as the Mac app keeps its own, served at `/downloads/` for other devices to play from; the web client chooses what's kept.
* `sync [URL]` syncs both ways with one device, or with every device of this library found nearby or added: it pulls what this device lacks, then pushes what the other lacks. Each prints a line: operations pulled, how many were new, lost (older than what's held), known, rejected (from a device not yet admitted), and refused (past a cutoff); then batches and size, how many were pushed, and time. A device that can't be reached prints its error, and the rest go on. Since it pushes too, a device behind a NAT keeps a server it can reach in step both ways, and `serve` on the server takes pushes as it answers pulls.
* `refresh` syncs with every device, then crawls every source no device crawled within the library's interval: every day unless `library set --crawl` says 1, 3, or 168 hours, or `manually`, give or take a 24th of it. The catalog others have described arrives first, so the crawl finds little to do, and a NAS's disks spin up for crawling no more than chosen, not at every refresh. `--jitter SECONDS` first waits a random time up to that, so devices on timers don't refresh together. `crawl` crawls every source, however lately.
* `device list` then prints devices found nearby (with their libraries) and addresses added. `device add URL` adds, on this device only, the address of a device that can't be found, such as one beyond a NAT; `device forget URL` forgets it. A URL may be a device's base or its `/sync`.

### In a browser

`serve` serves a web client at the root (`http://<host>:8008/`). On a device with no library yet, it starts anyway, and the web client sets one up: Create a Library, or Join a Library, showing a code for a member's device to add it by (as `person pair` offers, at `/pair` on the same port, advertised as a new device). So one command, `serve --media DIR`, then a browser on the same computer, makes a working library with no other device: create it, add the served folder as a source, and Refresh Library.

* Settings, as the Mac's panes have them: names; people (removing them, and adding someone new by the code their device shows); this person's devices (renaming, removing, and adding them by their codes, from those offering nearby, listed as they're found, one after another until the panel's × or Escape closes it, or by the address one prints); sources (adding a server's address, or the folder `--media` serves, but no other folder, so a browser can't share one of this computer's; removing one, or an unavailable folder's videos); how often sources are looked through, and Refresh Library (or Fully); devices added by address; and Leave This Library, removing this device and syncing that before forgetting, as the apps do (asking who takes it over if this person founded it and has no other device).
* Movies, Series, Watching, Watched, and your lists in a sidebar, with search, as the Mac app has them; in a narrow window, a tab bar of Home, Movies, Series, Lists, and Search, as an iPhone's.
* Each title's page, with its seasons and episodes (read from their files as a season's shown, as the apps do).
* A player that resumes where you left off and goes on to the next episode. Videos play straight from their sources (the server picks the copy whose server answers first). Browsers play MP4, M4V, and MOV files, not MKV or ISO.
* Covers through the server, since a source's server won't let another site's page read its files.
* Download, bringing an episode or movie to the browser's own computer through the server, so it works when the browser can't reach the sources.
* With `--downloads DIR`, Keep, having the server keep a title (as the Mac app downloads to the Mac), so other devices play it from the server.

A browser has no keys, so it acts as this device's person: what you watch there, and the lists, are theirs, and reach their other devices a few seconds after your changes stop, as the server syncs with them. So only a browser on the server's own computer may (by its loopback address: `localhost`, or an SSH tunnel's end, `ssh -L 8008:localhost:8008 hal`); any other is told to open it there, unless `serve --permissive`, for a network where everyone reaching the port may act as this device's person. (A proxy on the same computer passing others' requests on would be taken for it, so put none in front of it.)

On macOS, Local Network privacy decides whether the app may reach other devices (a NAS, for covers, copy racing, and syncing), and macOS asks it of the app that started it. So start it from one allowed it in System Settings › Privacy & Security › Local Network, as Terminal can be. Some apps' built-in terminals (OpenCode's, say) run it under a helper of their own, which isn't allowed even when the app is; started there, every connection to another device fails at once (`HostUnreachable`).

### In the background

Run `serve` with systemd on Linux (or keep it running however you like), and `refresh --jitter 600` hourly by a timer or cron: each refresh first waits up to 10 minutes, so devices don't refresh together, syncs every time, and crawls as often as the library says. On macOS, a launch agent can't reach the local network (see [DEVELOPMENT.md](../DEVELOPMENT.md)), so run them in Terminal.

## Sharing a library

```sh
# on hal: found a library, and fill it
cinematheque library create
cinematheque source add http://nas.local/Video/
cinematheque crawl
cinematheque title review
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

It's embedded in the app: plain HTML, CSS, and JavaScript, no framework. What it is, and why it's off unless asked for, are [above](#in-a-browser) and in [AGENTS.md](../AGENTS.md#command-line-app).

* **Layouts,** by the window's width (a media query, 768 pixels, as `wide` in [app.js](src/web/app.js) has it too), not the device. Crossing the width shows the page again, as search then applies or doesn't.
  * **Wide:** a sidebar, as the Mac's: Movies, Series, Watching (titles partway through), Watched, and Kept (with `--downloads`); then a Lists heading, its ⊕ at its right (always shown) asking a new list's name with the browser's prompt and showing the list; then each of this person's lists, then other members' shared ones. The shelf shown is filled, as a sidebar's selection; a title's page marks the shelf it was opened from. Over the content is a sticky header of the shelf's name, its order, and search at the top right, which filters whatever shelf is shown (typed on a title's page, it goes back to the shelf it came from). There's no Home: an empty address shows Movies.
  * **Narrow:** a tab bar at the bottom, as the iPhone's, of Home, Movies, Series, Lists, and Search: a symbol over each name, the tab shown in the accent, a list's page belonging to the Lists tab, and Watching's, Watched's, and Kept's to Home. Search shows on its tab alone (focused as it's chosen empty), with movies, then a tile per series, as the Apple TV's. A title's or a list's page names itself, without the header. Home is Watched and Kept, as links, then Continue Watching and a row per list. Lists is New List, then every list's row (one with nothing on it saying so). Each row is under its name, with See All (how many titles it holds) to its shelf, `#watching` or the list's page.
  * **Addresses:** every page has its own (`#home`, `#movies`, `#series`, `#watching` (`#in-progress` going there, its order kept), `#watched`, `#kept`, `#lists`, `#lists/<id>`, `#search`, `#title/<key>[/<season>]`), so Back retraces them, and a tile, a real link, opens in a new tab with ⌘-click or the middle button, or is bookmarked.
* **Carousels** (the rows): every cover one height, each its own width by its shape (`--shape`), scrolling sideways and snapping to covers' starts. The shape is its placeholder's (a ThumbHash keeps its image's approximate width over height, read in the browser without a request, so the row's laid out before covers load), else a movie's 2:3 or a season's square, then its cover's own once loaded, if that differs; each snapped to the nearest of 2:3, square, 4:3, and 16:9, so a placeholder's approximation doesn't crop a cover. Grids give every cell the column's width, a season's cover of another shape fit whole in its square, as the Mac's.
* **Shelves:**
  * **Lists:** a list's page (`#lists/<id>`) has Rename, Share (Shared while it is, sharing confirmed first), and Delete beside its name, asked and confirmed with the browser's own prompt and confirm; deleting goes to Lists. Another member's shared list is read-only, by name only. A shared list's name is marked with two people, an SVG in the text's color (an emoji would keep its own).
  * **Order:** every shelf but Home and Lists is sorted by a menu beside search: Title, A to Z or Z to A; Newest or Oldest released; Recently or Earliest Added; Recently or Earliest Modified; Recently or Earliest Watched. It's as wide as the order shown (`field-sizing`), so the shelf's name keeps its room. Each shelf's choice, and each list's, is kept in the browser (`localStorage`). Home's and Lists' rows are in their shelves' orders, Continue Watching the latest watched first.
  * **Grid,** as the Mac's: its movies, then each series' seasons under its name, so each shape has rows of its own, with room above the first. A dated series' seasons are named by their years ("2026"), as the apps name them.
  * **Group by Series,** on the Series shelf and its search: a checkbox beside the order, shown on that shelf alone, kept in the browser, on at first (the Search tab's always grouped, without it). It shows a tile per series instead, as the Mac's: its first season's cover, marked for the whole series; its name, and under it what its seasons come to ("3 seasons", "2024–2026", "Season 7", or nothing for a first alone), with its year at that line's end, or beside its name where the line's blank, wrapping below where there's no room (CSS's `flex-wrap`, no measuring). A series of one season opens that season's page. The others open their seasons in place, one at a time, the open series outlined, clicked again to close: on a band (`toggleBand`) after the last tile of the series' row, its seasons in full-size cells spanning the grid's own columns, its point centered under the series and placed again as the window resizes. It grows from nothing (`grid-template-rows` from `0fr` to `1fr`) as the rows after it move down, and shrinks back; none under Reduce Motion.
  * **Place:** each shelf keeps its place as it's left, or shown again as its data changes (a page's late `route()`, after its requests, landing on the shelf gone back to, patched it rather than resetting it). The page left is kept (`kept`) whole, with where it was scrolled and the series open. Shown again, the shelf's makeup (its headings, and its tiles' identities in order) is found by a trial run of its builder that draws no tiles (`makeup`, `fill` noting its items). If it matches the kept page's, that page is put back as it was, and only the tiles whose data changed are drawn again (`patch`: each tile keeps the identity and the look it was drawn from, its name, cover, marks, and lists), as React or SwiftUI diffs a view; covers still loading when it was left load again as they near the screen. Else it's built anew and put back where it was (`places`: the series opened again at once, without growing, and scrolled there once enough is built, as it's built a slice a frame). The browser's own restoring is off (`history.scrollRestoration`), as it scrolled before a shelf was rebuilt. A new search, order, or grouping starts at the top (`route({ fromTop: true })`), as the Mac's.
  * **Loading:** a shelf chosen in the sidebar or the tab bar shows at once, a screenful built first and the rest a slice a frame. Each tile's placeholder and cover are fetched only as it nears the screen: its placeholder at once, its cover in turn, three at most at a time, nearest the screen first. A tile that leaves before its turn gives it up, and a page left behind stops its covers: a source's disks waking can hold covers for seconds, and they mustn't take every connection the browser opens to the server (six), which pages and playing need meanwhile.
* **Tiles:** the apps' tiles: progress a thin bar along the cover's foot, white on a translucent track, and the marks at the end of the name's line under it (`marksView`: a yellow star, on a list; a white check on a green circle, watched), leaving the cover's corners to the art.
* **Status line:** each shelf's counts, as the Mac's status bar says them (a series' shelf counting its seasons and episodes too), fading out 3 seconds after they last changed and back when the pointer nears it, as the Mac's; a problem stays until something replaces it.
* **Title page,** laid out as the Mac's inspector:
  * Quality in a row of its own above Play, so choosing it changes only what's below: a pop-up of what browsers play (MP4, M4V, or MOV, HEVC only where supported), best first, by the apps' short names; a title of one quality saying it as text, so every title says what it plays in.
  * Play or Resume, filled, with Start Over before Resume, and quieter beside it, Lists (a menu of every list, each checked if the title's on it, then New List…, anchored under its button, named Lists whatever it's on) and the watched mark.
  * A movie's progress, and each episode's in its row, with what's left; a watched version's or episode's row the tiles' check (`watchedMark`) before its runtime, as the apps'; then the description, and an Episodes heading with a Season pop-up (the season named there, not in the facts), or a Versions heading.
  * The cover's column narrows with the window before Play's row would wrap. A season's episodes are described as it's shown, each once a page load.
* **Playing,** as the apps do: full height, with nothing over the video but the browser's own controls; the browser's Back or Escape leaving it, as a history entry; what's playing as the window's title. It fades, resumes 4 seconds before where it was left, saves every 10 seconds past the first 10 and where it's paused or left, marks it watched at its end, goes on to the next, and tries the next copy when one doesn't load.
* **API,** under `/api/`:
  * the apps' tile and title JSON (shared with the C interface, in `views.zig`);
  * covers (a source's byte range, fetched by the server, since sources answer other sites' scripts nothing, and cached for good), and placeholders (ThumbHashes drawn as small BMPs);
  * copy racing (`race`, `lost`), and describing an episode (`describe`);
  * this person's writes (`progress`, `watched`, `listed`, `list-create`, `list-rename`, `list-remove`, `list-share`, and `list-want` and `list-want-edit`, a title not in the library yet put on a list, or changed);
  * this device's downloads: `downloads` (the core's report, as `cq_downloads` gives it, with whether there are any and this device's name), `download-sizes`, and `download`, `download-remove`, and `download-next`, which ask reconciling to run;
  * a copy's file to save (`file`, streamed from its source as it comes, with its name, passing a `Range` on, under the core's download deadlines).

  It fetches and races only URLs within the library's sources.
* **Keep,** with `serve --downloads DIR`: the server's downloads, called kept, as "download" means coming to the computer in hand; the server is named only in tooltips.
  * They're kept and reconciled as the Mac's downloads are (`download.zig`), on a task beside serving, run when a page changes them and every 10 minutes, as what's watched elsewhere moves a series' next episodes along. They're served at the first hostname label `.local` (a DHCP server's `firefly.localdomain` is a name other computers can't look up); the same directory at a new address takes its source over.
  * Title pages show Keep as the Mac's inspector shows Download, in a row below Play: a movie's Keep (the version Play plays), and a season's Keep choice of episodes (Nothing, Next, Next 3, Next 10, All, each with its size), with sizes fetched before the page is drawn, so none arrives to move what's beside it; and each episode's or version's own, smaller, in its row.
  * Keep is one button through its turns, its size throughout, as the Mac's download rows hold their places (nothing appears or disappears): Keep (orange, with what's available on the server, if it wouldn't fit); then Keeping, a round gauge in its slot while the file comes (turning while it waits its turn), Cancel under the pointer; then Kept, tinted with the accent and checked, ✕ Delete in red under the pointer. Its labels are stacked in one place, so it's as wide as the widest.
  * Deleting the only copy is confirmed first, as is any deleting on a screen with no pointer to show Delete first. Deleting what a series' choice asks for sets it to Nothing (the core's rule, as the Mac's).
  * A Kept shelf lists them, and the status line says how far keeping has come while it runs, polled every 2 seconds while anything is coming.
* **Download** (a movie's, of one file, beside Keep; an episode's or version's, a smaller button in its row) asks the server for the file of the chosen quality's copy whose server answers first, as an attachment named as in its source, so the browser keeps it. It says nothing of space, the browser's computer's own business.
* **Its own page alone:** pages and the API answer only an address no other site can take (an IP address, `localhost`, a `.local` or single-label name, or this computer's own), so a site that rebinds its name to this device is refused. A change must be JSON from the same origin, which another site's page can't send without asking first, and every answer forbids framing and type sniffing. Open it by address or `.local` name.
* **Syncing:** a second after a browser's last change of this person's (not an episode described), it syncs with every device found or added, as the apps do after theirs.

## Limits

What's planned for them is in [DEVELOPMENT.md](../DEVELOPMENT.md).

* Its commands can't name people or devices; the web client's Settings and the apps do, and the names reach it by sync.
* There's no Windows build yet.

## Sources

* [main.zig](src/main.zig): the command line. `Args` parses words and options (an option not among the flags takes the next word as its value) and expands the `ls` and `show` shortcuts. `Command.is` matches a verb, its arity, and the options it allows. The nouns and actions are tables of functions; `help` prints a noun's or action's part of [usage.txt](src/usage.txt), which it embeds. It opens the data directory and the `App` every command acts with (the store, the output, and the clock), and turns `error.Usage` into help and status 2.
* [commands.zig](src/commands.zig): the state nouns, a function each (`person`, `library`, `member`, `device`, `source`, `title`, `alias`, `progress`); sending pairing codes (`pairWith`, which finds the one device offering nearby); and `crawl` and `refresh`, which crawl sources and then describe them.
* [network.zig](src/network.zig): `serve`, which advertises once it knows its port; `sync`, which syncs with the device given, or with every device found by DNS-SD and in `local` (`address:URL`), as `syncEvery` does for `refresh`, through `exchangeAll`; the listing and adding of addresses behind `device`; and `offerPairing`, which serves a pairing offer until it's taken, or until 3 wrong codes.
* [web.zig](src/web.zig): the web client's server: its files, embedded; which browser acts as this device (`local`, by its loopback address, or any with `--permissive`); syncs answered as this device is now (`snapshot`); and the API for browsing, playing, lists, and downloads.
* [setup.zig](src/setup.zig): setup (creating a library, or offering to join one at `/pair` on the same port, and advertising afresh as it changes) and settings' API, and `keepRefreshed`, which runs Refresh Library on a task of its own.
* [web/](src/web): the page (its icon, `favicon.ico`, drawn by [draw-icons.swift](../apple/draw-icons.swift)), as classic scripts sharing one scope: [settings.js](src/web/settings.js) (setup, why a browser elsewhere can't act as this device, and Settings), [app.js](src/web/app.js) (shelves, title pages, downloads, and playing), and [route.js](src/web/route.js) (each page's address, and starting the app, past setup).
* [usage.txt](src/usage.txt): the commands and the help.
* [test.sh](test.sh): the end-to-end test. Devices on one computer, each with its own data directory, found a library and serve a generated source as media. They crawl, pair (to join, and as another of a person's devices) at the ports their offers print, and sync until their digests match; the test checks that a removed member is refused and that progress travels only between the person's devices.
* [test/gen.zig](test/gen.zig): the test source's generator (`gen DIR [DIVISOR]`): a media tree at the library's full scale, or a fraction of it, named as Plex and Jellyfin expect, of sparse files that take no disk space.

The library itself, from parsing names to syncing, is the [core](../core/README.md)'s; how its operations work is in [ARCHITECTURE.md](../ARCHITECTURE.md).

## On a real source

Crawling a Caddy server on a NAS over Wi-Fi, with a folder per quality (each added as a source, its quality named) and tens of thousands of files, took under a second with 32 workers; a second crawl, with nothing changed, took about 1% of the first's requests. Review found a few dozen close matches (mostly years off by one or missing) and duplicate files: `.m4v` and `.mp4` copies, episode codes used twice, and a part beside its whole. A second device synced the library (about 100,000 operations) in under half a second, and an alias reached it as one operation.
