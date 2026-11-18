# Peer

The command-line desktop peer, `cinematheque`, for macOS and Linux, on the [core](../core/README.md). It does everything a player does but play: it founds or joins a library, pairs devices, crawls repositories, reviews what it found, records playheads, and serves and syncs with other peers. Run in the background, it's a library's always-on hub.

## Building

It needs [Zig](https://ziglang.org) 0.17 or later and SQLite (built into macOS; on Linux, your distribution's package). On Linux, finding other peers on your network needs Avahi and its Bonjour compatibility library (`libdns_sd`; e.g., `avahi` and `avahi-compat-libdns_sd` on Alpine).

```sh
zig build --release=fast
cp zig-out/bin/cinematheque ~/bin/   # or anywhere on your PATH
./test.sh       # peers, a generated repository, sync, and every command
```

[build.zig](build.zig) builds the peer and, with `zig build gen`, the test repository's generator.

## Getting started

Create a library, add a repository, and see what's in it:

```sh
cinematheque library create
cinematheque repo add http://nas.local/Video/Movies/
cinematheque crawl
cinematheque ls "All Systems Red"
cinematheque show t/m/all-systems-red/2017
```

`ls` prints each title's key, such as `t/m/all-systems-red/2017`, and `show` prints everything about one: its versions or episodes, and where each copy is. What a repository needs, and how to name files so titles are recognized, are in the [README](../README.md#preparing-a-repository).

## Home

The peer keeps its state in a directory of its own, its home. By default that's `~/Library/Application Support/Cinematheque` on macOS, the same home the Mac app uses, so both act as one device. On Linux it's `$XDG_DATA_HOME/cinematheque`, or `~/.local/share/cinematheque`. `--home DIR` or `CINEMATHEQUE_HOME` names another, which is how one computer runs several peers, as [test.sh](test.sh) does. The home is created on first use.

| File | Holds |
|---|---|
| `identity` | The device's random seed, from which its keys derive |
| `user` | The user's seed, once this device is linked to another of the user's; until then, the user's seed derives from the device's |
| `library` | The library's founder's user key, once this device has a library |
| `replica.db` | The replica: the library's operations, and in its `local` table, what's this device's alone (crawl snapshots, and peers added by URL) |

`identity` and `user` are secrets: anyone with the user's seed can act as the user. Don't copy a home to another device, since each device needs its own identity; pair the other device instead.

## The command line

State commands are `NOUN VERB [ARGUMENTS]`, over the nouns `user`, `library`, `member`, `repo`, `title`, `alias`, `playhead`, `peer`, and `agent`. Actions on the whole peer are single words: `crawl`, `sync`, `serve`, and `refresh`. `ls` and `show` are shortcuts for `title list` and `title show`.

* **Options** are named and may come anywhere: `--port PORT`, `--media DIR`, `--rendition NAME`, `--skip PREFIX`, and `--workers WORKERS` take a value. `--leave`, `--watched`, and `--unwatched` are flags. `--home DIR` works with every command.
* **Help:** [usage.txt](src/usage.txt) lists every command, and is the help, built into the binary. `-h` or `--help` prints it all. With a noun or action (`cinematheque repo -h`), or for a noun alone, only that one's commands are printed.
* **Arguments:** keys are 64 hexadecimal digits, as `user show` prints them. Titles and items are keys, as `title list` and `title show` print them (`t/m/alien/1979`, `t/s/firefly/-/e/s01e01`). A repository is its ID (16 hexadecimal digits) or its URL.
* **Exit status:** 0 on success. A command line that isn't one prints the help for its noun (or all of it) and exits with status 2. Any other failure prints `error:` and the error's name (e.g., `error: NoLibrary`, before there's a library), and exits with status 1. Debug builds add a stack trace.

## Commands

[usage.txt](src/usage.txt) has their syntax; this says what each does and prints.

### Users and libraries

* `user show` prints this user's key, as `member remove` and `library handover` take it.
* `user pair`, on a new device without a library, prints a 6-digit code, and the port it listens on, and waits. Meanwhile it serves `/pair` on that port and advertises itself (`pair=link`, named by `$HOST`). `user pair CODE` on one of the user's devices finds it nearby, or at the URL given, and sends it the user's seed and the library's founder, sealed by the code (see [pair.zig](../core/src/pair.zig)). The new device then prints whose it is and exits. A sender that found it nearby names it, as it advertised itself, under its user.
* `library create` founds a library with this user as founder, and prints its ID. `library join` offers a code, as `user pair` does, for a member's `member pair CODE`. Pairing is the only way to join or link, so the user's seed is never shown.
* `library show` prints the library's ID, founder, member count, and digest. The digest is a hash of every field's winning value, so two peers that have synced fully print the same one.
* `library handover USER` makes a member the founder; this user stays a member unless `--leave`. Only the founder may.

### Members

* `member list` prints the members' keys, marking the founder and you.
* `member pair CODE [URL]` admits the user of a new device offering to join, and sends it the library's founder.
* `device list` prints this user's devices (named or not), and `device remove DEVICE` removes one: its later writes are refused, and when it next syncs it's told so, signed, and prints that it should `library leave`, which forgets the library and its identity so it can pair again as a new device.
* `member remove USER` removes a member, except the founder. Their devices' writes up to what this peer has seen stand; later ones are refused everywhere.

### Repositories and crawling

* `repo add URL` adds a repository. The URL is percent-encoded as typed, and given a trailing slash. `--rendition NAME` names its files' rendition (e.g., a HandBrake preset's), and `--skip PREFIX` skips names beginning with it (default `,`). It prints the repository's ID, a hash of its URL.
* `repo list` and `repo show REPO` print repositories' settings; `show` adds how many copies of files the repository holds.
* `repo set REPO` changes `--rendition` or `--skip`; the next crawl applies it. `repo remove REPO` removes the repository and every holding it had, for every peer.
* A directory that held files and lists none now, as an unplugged drive's mount point does, is absent: its holdings stay, `crawl` counts it, and `repo show` lists it (`absent     /archive0001, since 3 days ago`). It clears once the drive is back. `repo forget REPO DIR` forgets one as if it were deleted, and its holdings go, as they do on their own after a year.
* `crawl [REPO]` crawls every repository, or one, with 16 concurrent workers unless `--workers` says otherwise. It reuses the last crawl's listing of any directory whose files haven't changed. Each repository gets a line of requests, files, titles added, holdings changed, and duplicates. Then covers and metadata are described, with one line of totals.

### Titles

* `title list [TEXT]` (`ls`) prints each title held by some repository whose name contains the text, ignoring case. Each line gives its year, kind, episodes or versions, renditions, and key, with `-> TARGET` if it's an alias. A count ends the list.
* `title show TITLE` (`show`) prints a title's fields, its aliases, and each item: the item's fields, your playhead, and per rendition, every copy's size, modification time, and URL.
* `title download TITLE` fetches a title's files (or a season's, `TITLE/e/s01`, or an item's) into the current directory or `--to DIR`, under their paths in the repository, so the directory can be served and added as a repository of its own. It takes `--rendition NAME`, else the rendition most of the items have, tries the copy whose server answers first, then the others, and resumes a file cut short (`<path>.part`) by a range request. Mind the size: a 2160p remux runs to 60 GB.
* `title review` prints close matches and duplicate files, tab-separated: the reason, then the two titles or files. A summary ends it.

  ```
  year off by one   t/m/rogue-protocol/2018   t/m/rogue-protocol/2019
  year missing      t/s/worldhoppers/-        t/s/worldhoppers/2024
  duplicate         .../Worldhoppers 105.m4v  .../Worldhoppers 105.mp4
  ```

  Some are mistakes to fix in the repository; others are different titles (a series and its reboot may share a name). `alias add TITLE TARGET` records that two are the same, `alias remove TITLE` undoes it, and `alias list` prints them. Aliases replicate, so one peer records each once for everyone.
* `title facets` counts titles by kind, decade, and rendition, tab-separated.

### Playheads

* `playhead list [TITLE]` prints this user's playheads, or a title's: each item, whether watched, and where it's at.
* `playhead set ITEM POSITION DURATION` records a position, in seconds. The core's rules apply: within the last 5% marks the item watched, and within the first 10 seconds clears the position. `playhead set ITEM --watched` (or `--unwatched`) marks it by hand, and `playhead remove ITEM` forgets it.

Playheads are private: they're written on this device's private stream, and travel only directly between the user's devices.

### Peers, syncing, and serving

* `serve` answers other peers' syncs (`/sync`) until stopped. It listens on `--port`, or else on 8008, falling back to any free port if 8008 is taken. It advertises the port it got by DNS-SD, with the library, the user, and the names of this device and user. `--media DIR` also serves a directory of videos at the root, so the peer is a repository too: byte ranges, listings as JSON or HTML, and an `INDEX` of every file and directory, built at start and again once a minute old when asked for. It prints a line once listening.
* `sync [URL]` syncs both ways with one peer, or with every peer of this library found nearby or added: it pulls what this peer lacks, then pushes what the other does. Each prints a line: operations pulled, how many were new, lost (older than what's held), known, rejected (from a device not yet admitted), and refused (past a cutoff), then batches and size, how many were pushed, and time. A peer that can't be reached prints its error, and the rest go on.
* `refresh` syncs with every peer, then crawls every repository: the catalog others have already described arrives first, so the crawl finds little to do.
* `peer list` prints peers found nearby (with their libraries) and peers added. `peer add URL` adds a peer that can't be found, such as one beyond a NAT, on this device only; `peer remove URL` forgets it. A URL may be a peer's base or its `/sync`.

Since `sync` pushes as well as pulls, a peer behind a NAT keeps a server it can reach in step both ways, and `serve` on the server takes pushes as it answers pulls.

### In the background

On macOS, `agent add` installs and starts two launch agents in `~/Library/LaunchAgents`, run with this home:
* `com.rbrian.cinematheque.serve`, kept running: `serve`, on `--port` if given.
* `com.rbrian.cinematheque.refresh`: `refresh`, at load and hourly.

Both log to `~/Library/Logs/Cinematheque` (`serve.log`, `refresh.log`). `agent add` needs a library first, and replaces agents already running; `agent show` prints their property lists without installing them, and `agent remove` stops and removes them. On Linux, run `serve` and `refresh` with systemd or cron instead.

## Sharing a library

```sh
# on hal: found a library, and fill it
cinematheque library create
cinematheque repo add http://nas.local/Video/
cinematheque crawl
cinematheque title review
cinematheque agent add            # serve, and refresh hourly

# on perihelion, another of your devices
cinematheque user pair            # prints a code, waits
# on hal
cinematheque user pair CODE

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

Then sync from a peer by URL, and add it, so later syncs and refreshes reach it too:

```sh
cinematheque sync http://hal.example.net:8008
cinematheque peer add http://hal.example.net:8008
```

## Limits

What's planned for them is in [DEVELOPMENT.md](../DEVELOPMENT.md).

* The peer can't name users or devices; the apps do, and the names reach the peer by sync.
* There's no Windows build yet.

## Sources

* [main.zig](src/main.zig): the command line. `Args` parses words and options (an option not among the flags takes the next word as its value) and expands the `ls` and `show` shortcuts. `Command.is` matches a verb, its arity, and the options it allows. The nouns and actions are tables of functions, and `help` prints a noun's or action's part of [usage.txt](src/usage.txt), which it embeds. It opens the home and the `Peer` every command acts with (the store, the output, and the clock), and turns `error.Usage` into help and status 2.
* [commands.zig](src/commands.zig): the state nouns, a function each (`user`, `library`, `member`, `repo`, `title`, `alias`, `playhead`, `agent`), sending pairing codes (`pairWith`, which finds the one device offering nearby), and `crawl` and `refresh`, which crawl repositories and then describe them.
* [network.zig](src/network.zig): `serve`, which advertises once it knows its port; `sync` and `pullAll`, which find peers by DNS-SD and in `local` (`peer:URL`); `peer`; and `offerPairing`, which serves a pairing offer until it's taken, or until 3 wrong codes.
* [agent.zig](src/agent.zig): the launch agents' property lists, installed and removed by `launchctl bootstrap` and `bootout`.
* [usage.txt](src/usage.txt): the commands and the help.
* [test.sh](test.sh): the end-to-end test. Peers on one computer, each with a home of its own, found a library and serve a generated repository as media. They crawl, pair (to join, and to link one to another's user) at the ports their offers print, and sync until their digests match, and the test checks that a removed member is refused and that playheads travel only between the user's devices.
* [test/gen.zig](test/gen.zig): the test repository's generator (`gen DIR [DIVISOR]`): a media tree at the library's full scale, or a fraction of it, named as Plex and Jellyfin expect, of sparse files that take no disk space.

The library itself, from parsing names to syncing, is the [core](../core/README.md)'s; how its operations work is in [ARCHITECTURE.md](../ARCHITECTURE.md).

## On a real repository

Crawling a Caddy server on a NAS over Wi-Fi, organized by its owner's convention of a folder per rendition (each added as a repository, its rendition named), four renditions of movies and TV (50,000 files, 4,000 of them in housekeeping folders the repository skips), took under a second with 32 workers and ingested 40,000 holdings of 5,000 titles; a second crawl took 11 requests instead of 790. Review found 12 close matches (7 years off by one, 4 years missing, 1 spelling) and 39 duplicate files: `.m4v` and `.mp4` copies, episode codes used twice, and a part beside its whole. A second peer synced the library (90,000 operations) in 0.4 s, and an alias reached it as one operation.
