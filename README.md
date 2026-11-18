# Cinematheque

Cinematheque is a video library for your household. It catalogs the movies and TV shows you already keep at home, on your own disks and NAS, and plays them on the family's devices straight from where they're stored, over your home network. It isn't a streaming service or a store: there's nothing to subscribe to or buy, and no account. The catalog is shared directly among your household's devices, and with the family and friends you invite.

Every device keeps its own copy of the catalog: the titles, their episodes and versions, where each file is, and what you've watched, but not the videos themselves. So each device can browse while offline, and catches up with the others when they meet, on your home network or wherever else they can reach each other. The videos stay where they are, on servers you already run, such as a NAS's web server, Caddy, nginx, or Apache, and play from there over plain HTTP.

> **Status:** early. Today Cinematheque is players for the Mac and the Apple TV, and a command-line peer for macOS and Linux that builds and shares a library. Players for other Apple devices, Linux, and Windows, outside metadata beyond what video files carry, and the transcoder are planned; see [DEVELOPMENT.md](DEVELOPMENT.md).

## Ideas

* **Library:** the shared catalog of titles (movies and series), their episodes and versions, and where each file is.
* **Repository:** anywhere your videos are served over HTTP. Cinematheque never changes a repository's files; it only reads its listings.
* **Rendition:** one encoding of a title (e.g., 720p H.264, or 4K HEVC). The same rendition may sit in several repositories, and players use whichever is reachable.
* **Peer:** a device that keeps a copy of the library's catalog (not of its videos). Peers sync directly with each other; there is no server in the middle.
* **Founder and members:** whoever creates a library founds it, and members add others. The founder can hand the library over to a successor; members can remove others, but not the founder.

## Getting it

* **On a Mac or an Apple TV,** build the app; [apple/README.md](apple/README.md) says how. It needs Xcode 27 or later.
* **On the command line,** on macOS or Linux, build the peer; [peer/README.md](peer/README.md) says how, and how to use it. It builds and shares a library, and run in the background, keeps it available to your other devices.

## Preparing a repository

Any web server that lists directories will do. Cinematheque works out which kind of listing a repository gives: an `INDEX` file if there is one (below), JSON listings from Caddy and nginx, or HTML listings from most others. The server must answer byte-range requests, so players can seek; Python's built-in `http.server` doesn't, so Cinematheque can catalog its files but players can't stream them.

If your server doesn't list directories, put a file named `INDEX` in the served folder, listing its files. Make it there with:

```sh
find . -type f ! -name INDEX > INDEX
```

and remake it whenever the files change. It works the same on Linux, macOS, BSD, and most NAS shells. An `INDEX` is also the fastest way to catalog a large repository: one request instead of one per folder.

Crawling a repository reads its listings, recognizes titles from file and folder names, and records each file as a rendition. Later crawls are quick, rereading only the folders that changed. A file you rename or move keeps its place in the library, as long as its name still says the same title.

### Renditions

A title's renditions are its copies in different encodings, such as a 720p one and a 4K one. Each file's rendition comes from its name, as media servers put it there, so copies of a title can sit side by side:

```
Movies/All Systems Red (2017)/All Systems Red (2017) - 1080p.mkv
Movies/All Systems Red (2017)/All Systems Red (2017) - 4K HDR.mkv
Movies/Network.Effect.2020.1080p.BluRay.x264-GROUP.mkv
```

The names give the resolution, source, codec, and dynamic range; a file whose name says none of these has an unknown rendition.

If a folder holds copies of one rendition whose names don't say which (say, everything one encoder preset made), add that folder as a repository of its own, and name its rendition: in the Mac app, under Advanced in Settings › Sources, or with `repo add --rendition` on the command line. A repository can also skip names beginning with a prefix, by default `,`, for folders like `,obsolete` that hold files you don't want cataloged. Removing a repository makes every peer forget its copies, so titles it alone held stop showing.

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

Names aren't always consistent: a year off by one, a title spelled two ways, or a file copied twice. The command-line peer's review lists what looks related, and an alias, recorded once, tells every peer that two entries are the same title; see [peer/README.md](peer/README.md#titles).

## Watching

The apps browse the library by cover art: movies, and each series by season. Choose one for its details, and play it straight from its repository, resuming where you left off on any of your devices; a season plays on from the episode you're partway through, or else its next unwatched one. Covers and descriptions come from your repositories: a `poster.jpg` beside a movie, or a `season01-poster.jpg` beside a series, if you keep them, or else the cover and details your MP4 files carry (as HandBrake, iTunes, and tagging tools write them). Until a cover loads, its tile shows a blurred likeness of it, which travels with the library, so even a newly paired device shows one at once. Star titles for your watchlist, which, like what you've watched, is yours alone. Stopping within the first 10 seconds forgets where you were, so going back to the start sticks.

On first run, an app creates a library, or pairs with one of your devices or someone's library by a code it shows; the Mac's Settings manage repositories, people, and devices, so a household needs no command line. The Mac app uses the same home as the command-line peer on that Mac, so either can manage the library.

## Sharing a library

A library is shared by pairing: the new device shows a 6-digit code, and someone already in the library enters it, in the Mac app under Settings › Devices › New Devices, or with the command-line peer. Pair as another of your own devices to use the library as yourself, with your playheads and watchlist; or as someone new, who joins as a member. The code seals what's sent, so only the device showing it can open it, and the new device stops after 3 wrong tries. [peer/README.md](peer/README.md#sharing-a-library) covers the command line, and pairing from off your network.

Peers find each other on your network, and while an app runs, it serves the library to your other devices, and syncs with them every minute and whenever you make a change. Each peer checks, by signature, that every change comes from a member, so a peer that relays the library can't alter it, and it serves the library only to members' devices. Removing a member stops their later changes everywhere, while what they did before stands; removing one of your devices does the same for that device.

## Privacy

Cinematheque has no accounts and no central server, and nothing leaves your devices except to the peers you sync with and the repositories you add. What you've watched, and where you stopped, syncs only among your own devices, directly, never through anyone else's. It's kept from other users, not hardened against someone with access to a device that holds it.

## For developers

* [AGENTS.md](AGENTS.md) specifies what's built; [DEVELOPMENT.md](DEVELOPMENT.md) holds the plans, open questions, and known issues.
* [ARCHITECTURE.md](ARCHITECTURE.md) explains operations: how devices write, sign, merge, and sync them, and every key and field the library writes.
* [core](core/README.md) is the Zig library, [peer](peer/README.md) the command-line peer, and [apple](apple/README.md) the Apple players.
* [experiments](experiments/README.md) hold the measurements behind the design.
* [docs/specifications](docs/specifications/README.md) indexes the outside specifications and papers Cinematheque relies on.

## How it was made

Cinematheque was written with [Claude](https://claude.com).

## License

Cinematheque is licensed under the BSD 3-Clause License; see [LICENSE](LICENSE).
