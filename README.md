# Cinematheque

Cinematheque is a video library for your household. It catalogs the movies and TV shows you already keep at home, on your own disks and NAS, and plays them on the family's devices straight from where they're stored, over your home network. It isn't a streaming service or a store: there's nothing to subscribe to or buy, and no account. The catalog is shared directly among your household's devices, and with the family and friends you invite.

Every device keeps its own copy of the catalog: the titles, their episodes and versions, where each file is, and what you've watched, but not the videos themselves. So each device can browse while offline, and catches up with the others when they meet, on your home network or wherever else they can reach each other. The videos stay where they are, on servers you already run, such as a NAS's web server, Caddy, nginx, or Apache, and play from there over plain HTTP.

> **Status:** early. Today Cinematheque is players for the Mac and the Apple TV, and a command-line app for macOS and Linux that builds and shares a library. Players for other Apple devices, Linux, and Windows, outside metadata beyond what video files carry, and the transcoder are planned; see [DEVELOPMENT.md](DEVELOPMENT.md).

## Ideas

* **Library:** the shared catalog of titles (movies and series), their episodes and versions, and where each file is.
* **Source:** anywhere your videos are served over HTTP. Cinematheque never changes a source's files; it only reads its listings.
* **Quality:** one encoding of a title (e.g., 720p H.264, or 4K HEVC). The same quality may have copies in several sources; when one copy doesn't load, players try the next.
* **Device:** anything running Cinematheque (an app, or the command-line app), each keeping a copy of the library's catalog (not of its videos). Devices sync directly with each other; there is no server in the middle.
* **Founder and members:** whoever creates a library founds it, and members add others. The founder can hand the library over to a successor; members can remove others, but not the founder.

## Getting it

* **On a Mac or an Apple TV,** build the app; [apple/README.md](apple/README.md) says how. It needs Xcode 27 or later.
* **On the command line,** on macOS or Linux, build the command-line app; [cli/README.md](cli/README.md) says how, and how to use it. It builds and shares a library, and run in the background, keeps it available to your other devices, and to browsers.

## Preparing a source

A source is a folder of videos your devices can reach over your network. The easiest is one you already have.

### A folder

* **On a Mac,** choose Add Folder… in the app's Settings > Sources: a folder on the Mac, on a drive plugged into it, or on a NAS share mounted in Finder. While the app runs, it shares the folder with your other devices (an Apple TV, say), which play from it. If the drive is unplugged or the share unmounted, its videos stay in the library, dimmed, until it's back.
* **Anywhere else,** on macOS or Linux (a home server, or a NAS that runs Linux), the command-line app shares a folder, then adds it:

```sh
cinematheque serve --media /srv/videos
cinematheque source add http://hal.local:8008/media/
```

Either way, the folder needs nothing done to it: Cinematheque reads it as it is, and never changes its files.

### A web server

If your videos are on a server that already serves files, such as a NAS's web server, Caddy, nginx, or Apache, add its address instead (with Add Server… on the Mac). Any web server that lists its folders will do, as long as it lets players seek within a file, as nearly all do (Python's built-in `http.server` doesn't: its videos are listed, but won't play).

If your server doesn't list directories, put a file named `INDEX` in the served folder, listing its files. Make it there with:

```sh
find . -type f ! -name INDEX > INDEX
```

and remake it whenever the files change. The command works the same on Linux, macOS, BSD, and most NAS shells. An `INDEX` is also the fastest way to read a large source: one request instead of one per folder. The command-line app's server serves one for you.

Refresh Library (⌘R on the Mac) looks for new videos (catching up with your other devices first, as they do on their own anyway): it reads each source's listings, recognizes titles from file and folder names, and records each file as a copy of its title, in its quality. Later looks are quick, rereading only the folders that changed. A file you rename or move keeps its place in the library, as long as its name still says the same title. When a folder's drive is unplugged or its share unmounted, its videos stay in the library, dimmed, until it's back, a year passes, or you remove them in Settings > Sources.

A source skips names beginning with a prefix, by default `,`, for folders like `,obsolete` that hold files you don't want in the library. Removing a source removes its copies on every device, so titles it alone held stop showing; its files stay where they are.

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

Names aren't always consistent: a year off by one, a title spelled two ways, or a file copied twice. The command-line app's review lists what looks related, and an alias, recorded once, tells every device that two entries are the same title; see [cli/README.md](cli/README.md#titles).

### Quality

A title may come in more than one quality, such as 1080p and 4K HDR, and each may have copies in several sources; the apps' Quality picker chooses which to play, and when one copy doesn't load (on a device that's asleep, say), players try the next. A file's quality comes from its name, as media servers put it there, so a title's files can sit side by side:

```
Movies/All Systems Red (2017)/All Systems Red (2017) - 1080p.mkv
Movies/All Systems Red (2017)/All Systems Red (2017) - 4K HDR.mkv
Movies/Network.Effect.2020.1080p.BluRay.x264-GROUP.mkv
```

Names give the resolution, origin (Blu-ray, web, DVD, or HDTV), codec, and dynamic range; a file whose name says none of these is of unknown quality.

If a folder holds files of one quality whose names don't say which (say, everything one encoder preset made), add that folder as a source of its own and name its quality: under Advanced in Settings > Sources on the Mac, or with `source add --quality` on the command line.

## Watching

The apps browse the library by cover art: movies, and each series by season. Choose one for its details, and play it straight from its source, resuming where you left off on any of your devices; a season plays on from the episode you're partway through, or else its next unwatched one. Covers and descriptions come from your sources: a `poster.jpg` beside a movie, or a `season01-poster.jpg` beside a series, if you keep them, or else the cover and details your MP4 files carry (as HandBrake, iTunes, and tagging tools write them). Until a cover loads, its tile shows a blurred likeness of it, which travels with the library, so even a newly paired device shows one at once. Star titles for your watchlist, which, like what you've watched, is yours alone. Stopping within the first 10 seconds forgets where you were, so going back to the start sticks.

In a browser, `cinematheque serve --web` offers the library at `http://<host>:8008/`, to browse and play from any computer on your network, as the person whose device it is; see [cli/README.md](cli/README.md#in-a-browser).

On first run, an app creates a library, or pairs with one of your devices or someone's library by a code it shows; the Mac's Settings manage sources, people, and devices, so a household needs no command line. The Mac app uses the same data directory as the command-line app on that Mac, so either can manage the library.

## Downloading

On a Mac, you can download what you'll watch away from home, or keep on hand when the network is slow. A movie's Download button says its size. A season's Download menu chooses which of the series' episodes the Mac keeps as you watch: the Next one or few, or All of them. The menu gives each choice's size, and the space free, in orange when a choice wouldn't fit.

Downloads go to `~/Movies/Cinematheque` (Settings > Downloads changes it), wait while something streams so as not to slow it, and are shared with your other devices like any source. What you download yourself stays until you delete it. A series' episodes you've watched are deleted when their space is needed (unless you chose All), but only if a source still holds the same file, and never if it's the only copy. The trash button beside the Download controls deletes them yourself, and asks first if any is the only copy. Cinematheque always leaves 20 GB free.

## Sharing a library

A library is shared by pairing: the new device shows a 6-digit code, and someone already in the library enters it, in the Mac app under Settings > Devices › New Devices, or with the command-line app. Pair as another of your own devices to use the library as yourself, with your progress and watchlist; or as someone new, who joins as a member. The code seals what's sent, so only the device showing it can open it, and the new device stops after 3 wrong tries. [cli/README.md](cli/README.md#sharing-a-library) covers the command line, and pairing from off your network.

Devices find each other on your network, and while an app runs, it shares the library with your other devices, and syncs with them every minute and whenever you make a change. Each device checks, by signature, that every change comes from a member, so a device that relays the library can't alter it, and it serves the library only to members' devices. Removing a member stops their later changes everywhere, while what they did before stands; removing one of your devices does the same for that device.

## Privacy

Cinematheque has no accounts and no central server, and nothing leaves your devices except to the devices you sync with and the sources you add. What you've watched, and where you stopped, syncs only among your own devices, directly, never through anyone else's. It's kept from other people, not hardened against someone with access to a device that holds it.

## For developers

* [AGENTS.md](AGENTS.md) specifies what's built; [DEVELOPMENT.md](DEVELOPMENT.md) holds the plans, open questions, and known issues.
* [ARCHITECTURE.md](ARCHITECTURE.md) explains operations: how devices write, sign, merge, and sync them, and every key and field the library writes.
* [core](core/README.md) is the Zig library, [cli](cli/README.md) the command-line app, and [apple](apple/README.md) the Apple players.
* [docs/specifications](docs/specifications/README.md) indexes the outside specifications and papers Cinematheque relies on.

## How it was made

Cinematheque was written with [Claude](https://claude.com).

## License

Cinematheque is licensed under the BSD 3-Clause License; see [LICENSE](LICENSE).
