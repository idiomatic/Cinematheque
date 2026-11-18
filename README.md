# Cinematheque

Cinematheque is a video library for your household. It catalogs the movies and TV shows you already keep at home, on your own disks and NAS, and plays them on the family's devices straight from where they're stored, over your home network. It isn't a streaming service or a store: there's nothing to subscribe to or buy, and no account. The catalog is shared directly among your household's devices, and with the family and friends you invite.

Every device keeps its own copy of the catalog: the titles, their episodes and versions, where each file is, and what you've watched, but not the videos themselves. So each device can browse while offline, and catches up with the others when they meet, on your home network or wherever else they can reach each other. The videos stay where they are, on servers you already run, such as a NAS's web server, Caddy, nginx, or Apache, and play from there over plain HTTP.

> **Status:** early. Today Cinematheque is a command-line peer for macOS and Linux that builds and shares a library, and a first macOS player that browses it and plays from your repositories. Players for other Apple devices, Linux, and Windows, outside metadata beyond what video files carry, and the transcoder are planned; see [DEVELOPMENT.md](DEVELOPMENT.md).

## Ideas

* **Library:** the shared catalog of titles (movies and series), their episodes and versions, and where each file is.
* **Repository:** anywhere your videos are served over HTTP. Cinematheque never changes a repository's files; it only reads its listings.
* **Rendition:** one encoding of a title (e.g., 720p H.264, or 4K HEVC). The same rendition may sit in several repositories, and players use whichever is reachable.
* **Peer:** a device that keeps a copy of the library's catalog (not of its videos). Peers sync directly with each other; there is no server in the middle.
* **Founder and members:** whoever creates a library founds it, and members add others. The founder can hand the library over to a successor; members can remove others, but not the founder.

## Getting it

The command-line peer needs [Zig](https://ziglang.org) 0.17 or later, and SQLite (built into macOS; on Linux, your distribution's SQLite package). On Linux, finding other peers on your network needs Avahi and its Bonjour compatibility library (e.g., `avahi` and `avahi-compat-libdns_sd` on Alpine).

```sh
cd peer
zig build --release=fast
cp zig-out/bin/cinematheque ~/bin/      # or anywhere on your PATH
```

The Mac app needs Xcode 27 or later too; see [Watching on a Mac](#watching-on-a-mac).

## Getting started

Create a library, add a repository, and see what's in it:

```sh
cinematheque library create
cinematheque repo add http://nas.local/Video/Movies/
cinematheque crawl
cinematheque ls "All Systems Red"
cinematheque show t/m/all-systems-red/2017
```

`crawl` reads the repository's listings, recognizes titles from file and folder names, and records each file as a rendition. Later crawls are quick, rereading only the folders that changed. A file you rename or move keeps its place in the library, as long as its name still says the same title.

`ls` prints each title's key, such as `t/m/all-systems-red/2017`, and `show` prints everything about one: its versions or episodes, and where each copy is.

Most commands name a thing, then what to do with it: `list`, `show`, `add`, `set`, or `remove`, as in `repo list` or `playhead remove`; `ls` and `show` are shortcuts for `title list` and `title show`. `cinematheque -h` lists every command (also in [peer/src/usage.txt](peer/src/usage.txt)), and `cinematheque repo -h`, or just `cinematheque repo`, those of one kind of thing.

The peer keeps its identity and its copy of the catalog in its home directory: `~/Library/Application Support/Cinematheque` on macOS, and `~/.local/share/cinematheque` (or `$XDG_DATA_HOME/cinematheque`) on Linux. To use another, such as for a second library or a test, pass `--home DIR` or set `CINEMATHEQUE_HOME`. Don't copy a home to another device: each device needs its own identity.

## Preparing a repository

Any web server that lists directories will do. Cinematheque works out which kind of listing a repository gives: an `INDEX` file if there is one (below), JSON listings from Caddy and nginx, or HTML listings from most others. The server must answer byte-range requests, so players can seek; Python's built-in `http.server` doesn't, so Cinematheque can catalog its files but players can't stream them.

If your server doesn't list directories, put a file named `INDEX` in the served folder, listing its files. Make it there with:

```sh
find . -type f ! -name INDEX > INDEX
```

and remake it whenever the files change. It works the same on Linux, macOS, BSD, and most NAS shells. An `INDEX` is also the fastest way to catalog a large repository: one request instead of one per folder.

### Renditions

A title's renditions are its copies in different encodings, such as a 720p one and a 4K one. Each file's rendition comes from its name, as media servers put it there, so copies of a title can sit side by side:

```
Movies/All Systems Red (2017)/All Systems Red (2017) - 1080p.mkv
Movies/All Systems Red (2017)/All Systems Red (2017) - 4K HDR.mkv
Movies/Network.Effect.2020.1080p.BluRay.x264-GROUP.mkv
```

The names give the resolution, source, codec, and dynamic range; a file whose name says none of these has an unknown rendition.

If a folder holds copies of one rendition whose names don't say which (say, everything one encoder preset made), add that folder as a repository of its own, and name its rendition:

```sh
cinematheque repo add "http://nas.local/Video/Fast 720p/" --rendition "Fast 720p"
```

`--skip` sets the prefix of folder and file names to leave out, by default `,`, for folders like `,obsolete` that hold files you don't want cataloged.

`repo set` changes a repository's rendition or skipped names; the next crawl applies it. `repo remove` stops using a repository, by its URL or by the ID `repo list` shows: every peer forgets its copies, and titles it alone held stop showing.

```sh
cinematheque repo remove "http://nas.local/Video/Fast 720p/"
```

### Naming

Cinematheque understands the naming conventions of Plex, Jellyfin, and Kodi, and common download names. Titles are recognized best with the year, and series by their folders:

```
Movies/All Systems Red (2017).mkv
Movies/All Systems Red (2017) - Director's Cut.mkv
Movies/Network Effect (2020) {tmdb-12345}/Network Effect (2020).mkv
TV Shows/Worldhoppers/Worldhoppers 102 The Wormhole.m4v
TV Shows/Sanctuary Moon (2019)/Season 01/Sanctuary Moon - S01E01 - Pilot.mkv
TV Shows/Worldhoppers/Worldhoppers The Lost Signal.m4v
```

A file without an episode number beside a series' episodes, named for the series (as `Worldhoppers The Lost Signal`), or in a `Specials` folder, is one of the series' specials.

## Reviewing matches

Names aren't always consistent: a year off by one, a title spelled two ways, or a file copied twice. `title review` lists what looks related, among titles some repository holds:

```sh
cinematheque title review
```

```
year off by one   t/m/rogue-protocol/2018   t/m/rogue-protocol/2019
year missing      t/s/worldhoppers/-        t/s/worldhoppers/2024
duplicate         .../Worldhoppers 105.m4v  .../Worldhoppers 105.mp4
```

Some are mistakes to fix in the repository; others are different titles (a series and its reboot may share a name). When two entries are the same title, record one as an alias of the other:

```sh
cinematheque alias add t/m/rogue-protocol/2019 t/m/rogue-protocol/2018
```

Aliases are shared with every peer, so you only do it once; `alias list` shows them, and `alias remove` undoes one.

## Watching on a Mac

The Mac app browses the library by cover art: movies, and each series by season. Select one for its details, and play it straight from its repository, resuming where you left off on any of your devices; a season plays on from its next unwatched episode. Covers and descriptions come from your repositories: a `poster.jpg` beside a movie, or a `season01-poster.jpg` beside a series, if you keep them, or else the cover and details your MP4 files carry (as HandBrake, iTunes, and tagging tools write them). Until a cover loads, its tile shows a blurred likeness of it, which travels with the library, so even a newly linked Mac shows one at once. Star titles for your watchlist, which, like what you've watched, is yours alone.

On first run, the app creates a library, or joins one; its Settings manage repositories, members, and syncing, so a household needs no command line. Open [apple/Cinematheque.xcodeproj](apple/Cinematheque.xcodeproj) in Xcode and run it, or build it from the command line:

```sh
cd apple
xcodebuild -scheme Cinematheque -configuration Release build
open "$(xcodebuild -scheme Cinematheque -configuration Release \
  -showBuildSettings | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p')/Cinematheque.app"
```

It uses the same home as the command-line peer, so either can manage the library. Serving, so others can sync from this Mac, and the background agent still take the command-line peer.

From the command line, `playhead list` shows what you're partway through or have watched, `playhead set` records it, and `playhead remove` forgets it.

## Sharing a library

On a device that has the library, let other peers reach it:

```sh
cinematheque serve
```

It answers on port 8008, or on any free port if that one's taken, and announces itself on your network; `--port` fixes the port, for peers others add by URL. On another device, or for another person, join the library and print the new peer's key:

```sh
cinematheque library join FOUNDER_KEY
cinematheque user show
```

A member adds that key:

```sh
cinematheque member add NEW_USER_KEY
```

Then the new peer syncs, from every peer found on the network, or from one by its URL:

```sh
cinematheque sync
cinematheque sync http://hal.local:8008
```

A peer that discovery can't find, such as one away from your network, can be added by URL with `peer add`; `sync` then syncs with it too.

Each peer checks, by signature, that every change comes from a member, so a peer that relays the library can't alter it, and it serves the library only to members' devices. `member list` shows who belongs. Removing a member (`member remove`) stops their later changes everywhere, while what they did before stands.

## Your other devices

To use the library on another of your own devices as yourself, with your playheads, link it before it joins. On a device you already use:

```sh
cinematheque user secret
```

and on the new one:

```sh
cinematheque user link SECRET
cinematheque library join FOUNDER_KEY
```

The secret lets a device act as you, so keep it to yourself.

## Running in the background

On a Mac, the peer can keep serving, and crawl and sync every hour, on its own:

```sh
cinematheque agent add
```

`agent show` shows what it would install, and `agent remove` removes it. Its logs are in `~/Library/Logs/Cinematheque`.

## Privacy

Cinematheque has no accounts and no central server, and nothing leaves your devices except to the peers you sync with and the repositories you add. What you've watched, and where you stopped, syncs only among your own devices, directly, never through anyone else's. It's kept from other users, not hardened against someone with access to a device that holds it.

## For developers

* [AGENTS.md](AGENTS.md) specifies what's built; [DEVELOPMENT.md](DEVELOPMENT.md) holds the plans, open questions, and known issues.
* [core](core/README.md) is the Zig library, [peer](peer/README.md) the command-line peer, and [apple](apple/README.md) the Apple players.
* [experiments](experiments/README.md) hold the measurements behind the design.
* [docs/specifications](docs/specifications/README.md) indexes the outside specifications and papers Cinematheque relies on.

## How it was made

Cinematheque was written with [Claude](https://claude.com).

## License

Cinematheque is licensed under the BSD 3-Clause License; see [LICENSE](LICENSE).
