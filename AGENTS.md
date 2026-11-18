# Cinematheque

Local-first video libraries. Players on Apple devices, macOS, Linux, and Windows browse shared libraries and play each video from any repository that holds it. There is no central server: each library's titles, metadata, and user data replicate among peers, so every peer works offline and catches up when it reconnects.

This file specifies what's built. Plans and open questions are in [DEVELOPMENT.md](DEVELOPMENT.md); the measurements behind the design are in [experiments](experiments/README.md); outside specifications are indexed in [docs/specifications](docs/specifications/README.md).

## Components

* [core](core/README.md): the Zig library, and a static library with a C interface ([cinematheque.h](core/include/cinematheque.h), a Swift module by its [module map](core/include/module.modulemap)) whose results are JSON. Its functions belong to one thread but for long ones (crawling, syncing, describing), each on a connection of its own; only one connection writes as the device at a time, and the main one catches up (`Replica.refresh`) before acting. Long operations commit as they go; `cq_data_version` changes when they have, `cq_progress` tells how far one has come (its phase, and steps done of how many), and `cq_prioritize` names titles (e.g., those on screen) for a crawl to describe first.
* [peer](peer/README.md): the command-line desktop peer, `cinematheque`, for macOS and Linux.
* [apple](apple/README.md): the Apple players, in SwiftUI; so far a macOS player (macOS 15 or later), bundled as `Cinematheque.app` (`com.rbrian.cinematheque`) by its Xcode project (Xcode 27's `project.xcproj` format), whose build phase builds the core for each architecture and links it into one object exporting only the C interface, so the compiler runtime Zig bundles can't clash with Xcode's.
* [experiments](experiments/README.md): the prototypes the components grew from, kept for reference.

## Peers

* **Players:** every client. iOS and tvOS players only play.
* **Repositories:** anything that serves videos over HTTP.
* **Static servers:** repositories running no Cinematheque code, such as a consumer-grade NAS or a web server (Caddy, nginx, Apache).
* **Desktop peers:** macOS, Linux, and Windows players. They are repositories too, serving their local and downloaded videos, and differ from static servers only in what they hold and how long they stay online.

## Identity and membership

* **Home:** the peer's own directory ("home," so it isn't taken for media): `~/Library/Application Support/Cinematheque` on macOS, `$XDG_DATA_HOME/cinematheque` (`~/.local/share/cinematheque`) elsewhere, or another by `--home` or `CINEMATHEQUE_HOME`, which the C interface, and so the app, honors too. It holds `identity` (the device's random seed), `user` (the user's seed, if linked), `library` (the founder's user key), and `replica.db`.
* **Keys:** a device's keys derive from its seed, and its user's from the user's seed, which the user's devices share; a device not linked derives its user's seed from its own. Linking a device means giving it the user's seed (`user secret`, then `user link`), which is a secret.
* **Certificates:** a device's first write is its certificate, its user's signature over the library and the device key. A device's private stream has a certificate of its own.
* **Library:** its ID derives from its founder's user key. Members add users to a set; any member may remove another, except the current founder.
* **Handover:** the founder may hand the library over to a member, staying or leaving. Handovers are a numbered chain, each valid only if written by the previous generation's founder, so peers agree in any order.
* **Removal:** a removal records, per device of the removed user, the last sequence number the remover had seen; writes through it stand, and later ones are refused. A peer that took later writes before hearing of the removal drops them, notes their fields, and repairs them from a peer that refused them; a write only it held, which lost to a refused one, is lost.

## Replication

* **Operations:** each writes one field of one key. Fields merge last-writer-wins by hybrid logical clock, ties broken by device key; set elements merge by causal length.
* **Batches:** a device signs each batch of up to 1,024 consecutive writes (a transaction's) once, with Ed25519, over a BLAKE3 Merkle tree of their encodings, so any operation, or set of them, is verifiable by proof.
* **Storage:** SQLite holds each field's winning operation (as columns, from which its encoding is rebuilt), interned device keys, signed batches, a version vector of each device's highest sequence number covered, fields awaiting repair, and state of the peer's own (`local`, e.g., crawl snapshots). It runs in WAL mode, and connections wait up to 10 seconds for one another's writes, since a peer's `serve` and `refresh` share its replica.
* **Sync:** the receiver POSTs to `/sync` a request signed by its device, with its certificate, the time, and its version vector. The sender answers members only, within ten minutes of its own clock, with frames: per device, its winning operations above the vector, grouped by batch, each batch with its signature and the leaves of operations not sent; then its vector, which the receiver adopts. Responses are gzipped.
* **Admission:** a receiver applies a batch only if its device's certificate names a member, else holds it until the end of the response, then rejects it without claiming it in its vector. It refuses operations past a removed member's cutoff, handovers not from the previous founder, and private data not from its user's private stream.
* **Private data:** a user's playheads (`p/<user>/...`) are written on each device's private stream, with its own key and numbering. Peers send private streams only to their users' devices, and leave them out of the vectors they send others, so private data travels only directly between a user's devices.
* **Thin fetches:** the core can fetch a title's winning operations with one shared proof per batch, for players that hold part of a library.

## Library

* **Keys:** `t/<m|s>/<normalized title>/<year or ->` for a title; below it `/v/<edition or ->` for a movie's version (its `edition` field naming it as written) or `/e/s03e17` for an episode (then `/v/<edition>` for an episode's version; `/e/s00-<normalized title>` for a special without a number, its `title` field naming it), `/p/<n>` for a part, and `/r/<rendition>`, whose `held:<repository>` field records the file's path, size, and modification time, empty when no longer held. A title's key derives from its parsed identity, so peers crawling independently agree.
* **Naming:** the parser reads Plex, Jellyfin, and Kodi conventions and download names: ID tags, years (the last year ends a title), editions, parts (after the year), extras, `S01E02`, `1x02`, air dates, season folders, and Kodi's compact codes (`Show 317 Title`) right after the series' title from the enclosing folder. Dots between digits are a title's own (`11.22.63`); a name of numbers alone without a year (e.g., a camera's) goes to review. A numberless file beside a series' episodes whose name extends the series' (`Babylon 5 The Gathering`), or in a `Specials` folder, is a special (season 0).
* **Renditions:** a file's rendition is its repository's, if named; else its name's technical tokens, canonically (resolution, source, codec, dynamic range, e.g., `2160p remux hevc hdr`); else unknown (`-`). Two files of one rendition in one repository are numbered (`~2`) as duplicates.
* **Review:** among titles some repository holds, close matches (a year off by one, missing, or with transposed digits; the same year, the same digits, and a spelling within two edits; or only diacritics differ) and duplicates. An alias (`aliases`) records that one title key is another's; it replicates, and an empty one undoes it.
* **Playheads:** per user and item (version, episode, or part), above renditions: position and duration in milliseconds, and watched, set on reaching the last 5% or by hand. Removing a playhead empties all three.
* **Covers and metadata:** after each crawl, one file per movie and per season, across every repository, describes it, unless the file that last did is unchanged; else the best (a sidecar, then an MP4, then another file; a movie's standard version before its editions). Describing runs after crawling, so titles show before covers, with 16 workers, prioritized titles first, committing every 24 jobs or 750 ms. A network failure is retried next crawl; a file that isn't a readable MP4 records an empty cover, so it isn't reread until it changes. The cover comes from a sidecar image by Plex, Jellyfin, and Kodi convention (`poster.jpg`, `folder.jpg`, `<movie>-poster.jpg`, `season01-poster.jpg`, a season folder's `poster.jpg`), else an MP4's, read by range requests that walk atom headers to `moov` and read `udta` whole (about 8 requests). The cover is recorded as a byte range of the file (`art`, or `art:s01`... for seasons, on the title's key), so players fetch it with one range request; images don't replicate. Each cover's placeholder replicates: `thumb` (or `thumb:s01`...), a ThumbHash in base64 of its JPEG's DC coefficients (an eighth-size image, decoded without a full decode), or `-` for another format; players render it with `cq_thumbhash`. A cover described without one gets one from a single range request. MP4 metadata fills a title's `description`, `genre`, `released`, and `network`, and an item's `title` (an episode's), `description`, and `duration`; other episodes are described on demand.
* **Tiles:** for browsing, a movie or a season (a season without a cover takes its series'), with this user's progress: watched if every item is, else a movie's position or the share of a season watched.
* **Watchlist:** per user, private like playheads (`p/<user>/watchlist`, a field per title key).
* **Facets:** titles held by some repository, counted by kind, decade, and rendition.

## Repositories

* **Settings:** a repository is a URL (percent-encoded as typed), with an optional rendition name and a prefix of names to skip (default `,`), changeable later (applied at the next crawl). Its ID is a hash of the URL. Removing it clears its settings and copies for every peer, and the remover's crawl snapshot.
* **Listings:** a crawl reads an `INDEX` if there is one (a path per line, as `find . -type f ! -name INDEX > INDEX` writes them, optionally followed by tab-separated size and modification time), else JSON listings (Caddy's or nginx's), else HTML, reading only links' targets.
* **Crawls:** breadth-first with concurrent workers (16 by default), reusing a previous crawl's listing of any directory with only files whose modification time hasn't changed, then bringing the repository's holdings in line with what was found.
* **Serving:** `serve` listens on the port given, else on 8008 or, if that's taken, any free port, and advertises the port it got. It binds with `SO_REUSEADDR` alone, never `SO_REUSEPORT`, so no two processes share a port. It answers `/sync`, and optionally serves a media directory: files with single byte ranges, `If-Range`, and `mtime-size` ETags; listings as JSON (Caddy's form, on `Accept: application/json`) or HTML; and an `INDEX` with sizes and times.
* **Discovery:** peers advertise `_cinematheque._tcp` by DNS-SD (Bonjour on macOS, Avahi's compatibility library on Linux), with the library's ID and the sync path in the TXT record.

## Peer

* **Commands:** [usage.txt](peer/src/usage.txt) lists them, and is their help. State commands are `NOUN VERB`, with verbs `list`, `show`, `add`, `set`, and `remove` where they apply, over nouns `user`, `library`, `member`, `repo`, `title`, `alias`, `playhead`, `peer`, and `agent`; whole-peer actions are single words (`crawl`, `sync`, `serve`, `refresh`). Options are named (`--port`, `--leave`); `ls` and `show` are shortcuts for `title list` and `title show`.
* **Usage:** placeholders are in capitals, named for what they mean rather than their type (`URL`, `--port PORT`). `-h` or `--help` shows usage, of one noun or action if given, as does a noun alone; a command line that isn't one shows the same and exits with status 2.
* **Added peers:** peers added by URL are kept in `local`, on that device only; `sync` without a URL, and `refresh`, pull from every peer discovered or added.
* **Background:** on macOS, `agent add` loads two launch agents (`com.rbrian.cinematheque.serve`, keeping `serve` running, and `.refresh`, crawling and syncing with peers discovered or added hourly), logging to `~/Library/Logs/Cinematheque`.

## macOS player

* **Setup:** with no library, creating one, joining one by its founder's key (showing this user's key to be added), or linking this device by the user's secret first.
* **Browsing:** shelves (Movies, Series, Watchlist; no All), searchable; a grid of covers in fixed cells, movies 2:3 and each series' seasons square under its name, each with a watched mark or progress bar; a cover shows its placeholder until loaded (without one, a color with its title), then replaces it at once, without a fade. Each shelf has its own scroll view, and returns to its topmost title when shown again; the grid keeps that title at the top as its width changes (e.g., the inspector opening or closing) and its rows reflow. A title, not an offset, which a change in width would move; the topmost is the first at least half on screen. Covers are fetched by range request, scaled with ImageIO off the main thread, and cached in memory and in the app's caches.
* **Inspector:** for the selected tile, a larger cover, Play or Resume (a movie, or a season's next unwatched episode, with the rest of the season queued), a rendition picker, the watchlist and watched marks, metadata, a movie's versions, and a season's episodes, each playable, described on demand. Season 0 is Specials.
* **Crawling:** while a crawl runs, the grid reloads as it commits (polling `cq_data_version` each second), and the tiles on screen are described first.
* **Playing:** a window per queue, an `AVQueuePlayer` in AppKit's `AVPlayerView`, streaming from the repository, starting at the playhead unless watched, saving it every 10 seconds, marking an item watched at its end, and going on to the next.
* **Managing,** in Settings: repositories (adding, editing, removing, crawling), members (adding and removing; this user's key), and this device (its keys, the user's secret, syncing with peers found or by address). Long operations run off the main thread.
* **Toolbar:** the sidebar's toggle and the shelf's title at the leading edge; the inspector's toggle (⌥⌘I) and search at the trailing. Refresh Library (⌘R, in the View menu) crawls, then syncs; the app refreshes so once at launch, if the library has repositories.
* **Status bar:** along the bottom of the grid, floating over it: the shelf's counts ("4,000 movies"; "12 of 4,000 movies match …" while searching), or what went wrong, at the leading edge; what a long operation is doing and how far it has come, with a progress bar, at the trailing. It fades out 3 seconds after it last changed, unless something is running or wrong, and comes back when the pointer nears it; floating, so fading moves nothing.
* **Modelessness:** no modal alerts, after the original Macintosh guidelines. What goes wrong shows in the status bar (and in a bar along the bottom of Settings), in words (e.g., "Crawling failed for art (and 5 more): connection refused."), until dismissed or until the next action of its kind (refreshing, changing the library, reading it) succeeds.
* The project follows Xcode's recommended settings but for script sandboxing (the core's build phase), the App Sandbox (the home it shares with the peer), the hardened runtime (until signing for distribution), and its macOS 15 minimum. A developer's signing settings stay in an ignored `Local.xcconfig`.
* The bundle's `Info.plist` allows plain HTTP on the local network. Debug builds take launch options for driving them unattended (`CINEMATHEQUE_SELECT`, a tile, e.g. `t/s/firefly/-#1`; `CINEMATHEQUE_PLAY`; and `CINEMATHEQUE_ITEM`).

## Implementation

* Zig 0.17+ for the core and the peer, with no dependencies beyond the system's SQLite and DNS-SD.
* SwiftUI for Apple players.
* SQLite for each peer's replica.
* Tests: the core's unit tests (`zig build test`), [peer/test.sh](peer/test.sh) (two peers and more, end to end), and screenshots of the player in a macOS VM (terrarium's `macos-27.2-quiet`).

## Scale

100,000+ video files: 4,000+ movies, and 500+ TV series of up to 30 seasons of up to 50 episodes.

## Risks

* App Review may resist publishing a library that encroaches on Apple's own, all the more so one that serves media.
* Outside metadata comes from providers outside Cinematheque, whose sources' terms (e.g., TMDB's charge for commercial use, IMDb's datasets for personal use only) bind them, not Cinematheque.
* GPL tools (`HandBrakeCLI`, GPL builds of FFmpeg) must run as separate processes, never linked, or they bind the license of the players and the shared core.

## References

* [Local-first software](https://en.wikipedia.org/wiki/Local-first_software)
