# Command-line app

The command-line app, `cinematheque`, for macOS and Linux, on the [core](../core/README.md). It does everything a player does but play: it founds or joins a library, pairs devices, crawls sources, reviews what it found, records progress, and serves and syncs with other devices. Run in the background, it's a library's always-on hub.

## Building

It needs [Zig](https://ziglang.org) 0.17 or later and SQLite (built into macOS; on Linux, your distribution's package). On Linux, finding other devices on your network needs Avahi and its Bonjour compatibility library (`libdns_sd`; e.g., `avahi` and `avahi-compat-libdns_sd` on Alpine).

```sh
zig build --release=safe
cp zig-out/bin/cinematheque ~/bin/   # or anywhere on your PATH
./test.sh       # devices, a generated source, sync, and every command
```

[build.zig](build.zig) builds the command-line app and, with `zig build gen`, the test source's generator.

## Getting started

Create a library, add a source, and see what's in it:

```sh
cinematheque library create
cinematheque source add http://nas.local/Video/Movies/
cinematheque crawl
cinematheque ls "All Systems Red"
cinematheque show t/m/all-systems-red/2017
```

`ls` prints each title's key, such as `t/m/all-systems-red/2017`, and `show` prints everything about one: its versions or episodes, and where each copy is. What a source needs, and how to name files so titles are recognized, are in the [README](../README.md#preparing-a-source).

## Data directory

The command-line app keeps its state in a directory of its own, its data directory. By default that's `~/Library/Application Support/Cinematheque` on macOS, the same one the Mac app uses, so both act as one device. On Linux it's `$XDG_DATA_HOME/cinematheque`, or `~/.local/share/cinematheque`. `--data DIR` or `CINEMATHEQUE_DATA` names another, which is how one computer runs several devices, as [test.sh](test.sh) does. The data directory is created on first use.

| File | Holds |
|---|---|
| `identity` | The device's random seed, from which its keys derive |
| `user` | The person's seed, once this device is paired as another of the person's; until then, the person's seed derives from the device's |
| `library` | The library's founder's person key, once this device has a library |
| `replica.db` | The replica: the library's operations, and in its `local` table, what's this device's alone (crawl snapshots, and devices added by URL) |

`identity` and `user` are secrets: anyone with the person's seed can act as the person. Don't copy a data directory to another device, since each device needs its own identity; pair the other device instead.

## The command line

State commands are `NOUN VERB [ARGUMENTS]`, over the nouns `person`, `library`, `member`, `source`, `title`, `alias`, `progress`, and `device`. Actions on the whole app are single words: `crawl`, `sync`, `serve`, and `refresh`. `ls` and `show` are shortcuts for `title list` and `title show`.

* **Options** are named and may come anywhere: `--port PORT`, `--media DIR`, `--quality NAME`, `--quality-by folder|name`, `--skip PREFIX`, and `--workers WORKERS` take a value. `--leave`, `--watched`, and `--unwatched` are flags. `--data DIR` works with every command.
* **Help:** [usage.txt](src/usage.txt) lists every command, and is the help, built into the binary. `-h` or `--help` prints it all. With a noun or action (`cinematheque source -h`), or for a noun alone, only that one's commands are printed.
* **Arguments:** keys are 64 hexadecimal digits, as `person show` prints them. Titles and items are keys, as `title list` and `title show` print them (`t/m/alien/1979`, `t/s/firefly/-/e/s01e01`). A source is its ID (16 hexadecimal digits) or its URL.
* **Exit status:** 0 on success. A command line that isn't one prints the help for its noun (or all of it) and exits with status 2. Any other failure prints `error:` and the error's name (e.g., `error: NoLibrary`, before there's a library), and exits with status 1. Debug builds add a stack trace.

## Commands

[usage.txt](src/usage.txt) has their syntax; this says what each does and prints.

### People and libraries

* `person show` prints this person's key, as `member remove` and `library handover` take it.
* `person pair`, on a new device without a library, prints a 6-digit code, and the port it listens on, and waits. Meanwhile it serves `/pair` on that port and advertises itself (`pair=new`, named by the computer's host name). On a member's device, `person pair CODE` finds it nearby, or at the URL given, and adds it as another of this person's devices, sending it the person's seed and the library's founder, sealed by the code (see [pair.zig](../core/src/pair.zig)). The new device then prints whose it is and exits. A sender that found it nearby names it, as it advertised itself, under its person.
* `library create` founds a library with this person as founder, and prints its ID. `library join` offers a code, as `person pair` does. A code is the only way in, so the person's seed is never shown.
* `library show` prints the library's ID, founder, member count, and digest. The digest is a hash of every field's winning value, so two devices that have synced fully print the same one.
* `library handover PERSON` makes a member the founder; this person stays a member unless `--leave`. Only the founder may.

### Members

* `member list` prints the members' keys, marking the founder and you.
* `member pair CODE [URL]` adds a new device offering a code as a new member's, admitting its person, and sends it the library's founder.
* `device list` prints this person's devices (named or not), and `device remove DEVICE` removes one: its later writes are refused, and when it next syncs it's told so, signed, and prints that it should `library leave`, which forgets the library and its identity so it can pair again as a new device.
* `member remove PERSON` removes a member, except the founder. Their devices' writes up to what this device has seen stand; later ones are refused everywhere.

### Sources and crawling

* `source add URL` adds a source. The URL is percent-encoded as typed, and given a trailing slash. `--quality NAME` names its files' quality (e.g., a HandBrake preset's), or `--quality-by folder` takes each file's from the first folder within the source (`Movies/HQ 1080p30 Surround/Alien (1979).m4v`), as one folder of qualities holds them all, and `--skip PREFIX` skips names beginning with it (default `,`). It prints the source's ID, a hash of its URL.
* `source list` and `source show SOURCE` print sources' settings; `show` adds how many copies of files the source holds.
* `source set SOURCE` changes `--quality`, `--quality-by` (`folder` or `name`), or `--skip`; the next crawl applies it. `source remove SOURCE` removes the source and every copy it had, for every device.
* A directory that held files and lists none now, as an unplugged drive's mount point does, is unavailable: its copies stay, `crawl` counts it, and `source show` lists it (`unavailable     /archive0001, since 3 days ago`). It clears once the drive is back. `source remove SOURCE --unavailable DIR` removes its copies as if it were deleted, as they go on their own after a year.
* `crawl [SOURCE]` crawls every source, or one, with 16 concurrent workers unless `--workers` says otherwise. It reuses the last crawl's listing of any directory whose files haven't changed. Each source gets a line of requests, files, titles added, copies changed, and duplicates. Then covers and metadata are described, with one line of totals.

### Titles

* `title list [TEXT]` (`ls`) prints each title held by some source whose name contains the text, ignoring case. Each line gives its year, kind, episodes or versions, qualities, and key, with `-> TARGET` if it's an alias. A count ends the list.
* `title show TITLE` (`show`) prints a title's fields, its aliases, and each item: the item's fields, your progress, and per quality, every copy's size, modification time, and URL.
* `title download TITLE` fetches a title's files (or a season's, `TITLE/e/s01`, or an item's) into the current directory or `--to DIR`, under their paths in the source, so the directory can be served and added as a source of its own. It takes `--quality NAME`, else the quality most of the items have, tries the copy whose server answers first, then the others, and resumes a file cut short (`<path>.part`) by a range request. Mind the size: a 2160p remux runs to 60 GB.
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
* `progress set ITEM POSITION DURATION` records a position, in seconds. The core's rules apply: within the last 5% marks the item watched, and within the first 10 seconds clears the position. `progress set ITEM --watched` (or `--unwatched`) marks it by hand, and `progress remove ITEM` forgets it.

Progress is private: it's written on this device's private stream, and travels only directly between the person's devices.

### Devices, syncing, and serving

* `serve` answers other devices' syncs (`/sync`) until stopped. It listens on `--port`, or else on 8008, falling back to any free port if 8008 is taken. It advertises the port it got by DNS-SD, with the library, the person, and the names of this device and person. `--media DIR` also serves a directory of videos at `/media/`, so this device is a source too (added as `http://<host>:8008/media/`): byte ranges, listings as JSON or HTML, and an `INDEX` of every file and directory, built at start and again once a minute old when asked for. `--web` serves a web client at the root, for browsing and playing in a browser (see below). `--downloads DIR` keeps this device's downloads in DIR, as the Mac app keeps its own, served at `/downloads/`, so other devices play from them; the web client chooses what's kept. It prints a line once listening, and with `--web`, the web client's address.
* `sync [URL]` syncs both ways with one device, or with every device of this library found nearby or added: it pulls what this device lacks, then pushes what the other does. Each prints a line: operations pulled, how many were new, lost (older than what's held), known, rejected (from a device not yet admitted), and refused (past a cutoff), then batches and size, how many were pushed, and time. A device that can't be reached prints its error, and the rest go on.
* `refresh` syncs with every device, then crawls every source no device crawled within the library's interval (every day unless `library set --crawl` says 1, 3, or 168 hours, or `manually`, give or take a 24th of it): the catalog others have already described arrives first, so the crawl finds little to do, and a NAS's disks spin up for crawling no more than chosen, not at every refresh. `--jitter SECONDS` waits a random time up to that first, so devices on timers don't refresh together; `crawl` crawls every source, however lately.
* `device list` then prints devices found nearby (with their libraries) and addresses added. `device add URL` adds the address of a device that can't be found, such as one beyond a NAT, on this device only; `device forget URL` forgets it. A URL may be a device's base or its `/sync`.

Since `sync` pushes as well as pulls, a device behind a NAT keeps a server it can reach in step both ways, and `serve` on the server takes pushes as it answers pulls.

### In a browser

`serve --web` serves a web client at the root (`http://<host>:8008/`): Home, Movies, Series, Lists, In Progress, and Watched, with search; each title's page, with its seasons and episodes (read from their files as a season's shown, as the apps do); and a player that resumes where you left off and goes on to the next episode. A browser has no keys of its own, so it acts as this device's person: what you watch there, and their lists, are theirs, and reach their other devices a few seconds later, as the server syncs with them once your changes stop. Videos play straight from their sources (the server picks the copy whose server answers first); browsers play MP4, M4V, and MOV files, but not MKV or ISO. Covers come through the server, since a source's server won't let another site's page read its files. Download brings an episode or movie to the browser's own computer, through the server, so it works when the browser can't reach the sources itself. With `--downloads DIR`, Keep has the server keep a title (as the Mac app downloads to the Mac), so other devices play it from the server. Anyone who can reach the port can use it, as they can the media it serves, so it's off unless `--web` is given.

On macOS, Local Network privacy decides whether the command-line app may reach other devices (a NAS, for covers, copy racing, and syncing): macOS asks it of the app that started it, so start it from one that's allowed it, as Terminal can be, in System Settings › Privacy & Security › Local Network. Some apps' built-in terminals (OpenCode's, say) run it under a helper of their own, which isn't allowed even when the app is; started there, every connection to another device fails at once with `HostUnreachable`.

### In the background

Run `serve` with systemd on Linux (or keep it running however you like), and `refresh --jitter 600` hourly with a timer or cron: each refresh waits a random time of up to 10 minutes first, so devices don't refresh together, syncs every time, and crawls as often as the library says. On macOS, a launch agent can't reach the local network (see [DEVELOPMENT.md](../DEVELOPMENT.md)), so run them in Terminal.

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

`serve --web` serves one at the root (embedded in the app: plain HTML, CSS, and JavaScript, no framework), off unless asked for, since anyone who can reach the port can use it. A browser acts as this device's person, having no keys.

* **Shelves:** Home (Continue Watching, then each list), Movies, Series, Lists (each list in turn, with New List, and Rename and Delete beside its name, asked and confirmed with the browser's own prompt and confirm), In Progress, and Watched, as the Mac's sidebar has them, on one line (search narrowing first, then the line scrolling sideways, faded at an edge only where more is hidden past it, and scrolled to show the shelf chosen), the shelf shown underlined with a thin line of the accent, searchable, sorted by a menu beside search (Title, A to Z or Z to A; Newest or Oldest released; Recently or Earliest Added; Recently or Earliest Watched; as wide as the order shown, by `field-sizing`, so the shelves keep their room), each shelf's choice kept in the browser (`localStorage`), Home's rows in orders of their own, each laid out as the Mac's grid (its movies, then each series' seasons under its name, so each shape has rows of its own, room above the first). A tab shows chosen at once, its shelf built a screenful first and the rest a slice a frame, each tile's cover and placeholder fetched only as it nears the screen: its placeholder at once, its cover in turn, three at most at a time, nearest the screen first (a tile that leaves before its turn gives it up, and a page left behind stops its covers), since a source's disks waking can hold covers for seconds, and they mustn't take every connection the browser opens to the server (six), which pages and playing need meanwhile.
* **Tiles:** the apps' tiles with their marks, drawn as the Mac's (white on a yellow circle for the star, a green one for the check), over the cover.
* **Status line:** each shelf's counts, as the Mac's status bar says them (a series' shelf counting its seasons and episodes too), fading out 3 seconds after they last changed and back when the pointer nears it, as the Mac's does; a problem stays until something replaces it.
* **Title page,** as the Mac's inspector is laid out: Quality in a row of its own above Play, so choosing it changes only what's below (a pop-up of what browsers play: MP4, M4V, or MOV, HEVC only where supported, best first, by the apps' short names; a title of one quality saying it as text, so every title says what it plays in); Play or Resume, filled, Start Over before Resume, Lists (a menu of every list, each checked if the title's on it, then New List…, anchored under its button, named Lists whatever it's on) and the watched mark quieter beside it; a movie's progress, and each episode's in its row, with what's left; then the description, and an Episodes heading with a Season pop-up (the season named there, not in the facts), or a Versions heading. The cover's column narrows with the window before Play's row would wrap. A season's episodes are described as it's shown, each once a page load.
* **Playing,** as the apps do: full height with nothing over the video but the browser's own controls (the browser's Back or Escape leaving it, as a history entry; what's playing as the window's title); fading, resuming 4 seconds before where it was left, saving every 10 seconds past the first 10 and where it's paused or left, marking it watched at its end, going on to the next, and trying the next copy when one doesn't load.
* **API:** under `/api/`, the apps' tile and title JSON (shared with the C interface, in `views.zig`), covers (a source's byte range, fetched by the server, since sources answer other sites' scripts nothing, and cached for good), placeholders (ThumbHashes drawn as small BMPs), copy racing (`race`, `lost`), describing an episode (`describe`), this person's writes (`progress`, `watched`, `listed`, `list-create`, `list-rename`, `list-remove`), this device's downloads (`downloads`, the core's report, as `cq_downloads` gives it, with whether there are any and this device's name; `download-sizes`; and `download`, `download-remove`, and `download-next`, which ask reconciling to run), and a copy's file to save (`file`, streamed from its source as it comes, with its name, passing a `Range` on, under the core's download deadlines). It fetches and races only URLs within the library's sources.
* **Keep,** with `serve --downloads DIR`: the server's downloads, called kept, as "download" means coming to the computer in hand; the server named only in tooltips. Kept and reconciled as the Mac's downloads are (`download.zig`), on a task beside serving, asked to run by a page's change and every 10 minutes, as what's watched elsewhere moves a series' next episodes along; served at its first hostname label `.local` (a DHCP server's `firefly.localdomain` being a name other computers can't look up), the same directory at a new address taking its source over. Title pages show it as the Mac's inspector shows Download, in a row below Play: a movie's Keep (the version Play plays) and a season's Keep choice of episodes (Nothing, Next, Next 3, Next 10, All, each with its size), with sizes fetched before the page is drawn, so none arrives to move what's beside it; and each episode's or version's own, smaller, in its row. Keep is one button through its turns, its size throughout, as the Mac's download rows hold their places (nothing appears or disappears): Keep (orange, with what's available on the server, if it wouldn't fit); then Keeping, a round gauge in its slot while the file comes (turning while it waits its turn), which under the pointer is Cancel; then Kept, tinted with the accent and checked, which under the pointer is ✕ Delete, in red. Its labels are stacked in one place, so it's as wide as the widest. Deleting the only copy is confirmed first, as is any on a screen with no pointer to show Delete first; deleting what a series' choice asks for sets it to Nothing (the core's rule, as the Mac's). A Kept shelf lists it, and the status line says how far keeping has come while it runs, polled every 2 seconds while anything is coming.
* **Download** (a movie's, of one file, beside Keep; an episode's or version's, a smaller button in its row) asks the server for the file of the chosen quality's copy whose server answers first, as an attachment named as in its source, so the browser keeps it. It says nothing of space, which is the browser's computer's own business.
* **Its own page alone:** pages and the API answer only an address no other site can take (an IP address, `localhost`, a `.local` or single-label name, or this computer's own), so a site that rebinds its name to this device is refused; a change must be JSON from the same origin (not cross-site), which another site's page can't send without asking first; and every answer forbids framing and type sniffing. Open it by address or `.local` name.
* **Syncing:** a second after a browser's last change of this person's (not an episode described), it syncs with every device found or added, as the apps do after theirs.

## Limits

What's planned for them is in [DEVELOPMENT.md](../DEVELOPMENT.md).

* The other device can't name people or devices; the apps do, and the names reach the other device by sync.
* There's no Windows build yet.

## Sources

* [main.zig](src/main.zig): the command line. `Args` parses words and options (an option not among the flags takes the next word as its value) and expands the `ls` and `show` shortcuts. `Command.is` matches a verb, its arity, and the options it allows. The nouns and actions are tables of functions, and `help` prints a noun's or action's part of [usage.txt](src/usage.txt), which it embeds. It opens the data directory and the `App` every command acts with (the store, the output, and the clock), and turns `error.Usage` into help and status 2.
* [commands.zig](src/commands.zig): the state nouns, a function each (`person`, `library`, `member`, `device`, `source`, `title`, `alias`, `progress`), sending pairing codes (`pairWith`, which finds the one device offering nearby), and `crawl` and `refresh`, which crawl sources and then describe them.
* [network.zig](src/network.zig): `serve`, which advertises once it knows its port; `sync`, which with `syncAll` finds devices by DNS-SD and in `local` (`address:URL`), and pulls from each; the listing and adding of addresses behind `device`; and `offerPairing`, which serves a pairing offer until it's taken, or until 3 wrong codes.
* [usage.txt](src/usage.txt): the commands and the help.
* [test.sh](test.sh): the end-to-end test. Devices on one computer, each with a data directory of its own, found a library and serve a generated source as media. They crawl, pair (to join, and to be another of a person's devices) at the ports their offers print, and sync until their digests match, and the test checks that a removed member is refused and that progress travels only between the person's devices.
* [test/gen.zig](test/gen.zig): the test source's generator (`gen DIR [DIVISOR]`): a media tree at the library's full scale, or a fraction of it, named as Plex and Jellyfin expect, of sparse files that take no disk space.

The library itself, from parsing names to syncing, is the [core](../core/README.md)'s; how its operations work is in [ARCHITECTURE.md](../ARCHITECTURE.md).

## On a real source

Crawling a Caddy server on a NAS over Wi-Fi, with a folder per quality (each added as a source, its quality named) and tens of thousands of files, took under a second with 32 workers; a second crawl, with nothing changed, took about 1% of the first's requests. Review found a few dozen close matches (mostly years off by one or missing) and duplicate files: `.m4v` and `.mp4` copies, episode codes used twice, and a part beside its whole. A second device synced the library (about 100,000 operations) in under half a second, and an alias reached it as one operation.
