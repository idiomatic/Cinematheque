# Development

Unbuilt work and open design questions, in the terms [AGENTS.md](AGENTS.md) defines. Each item moves into [AGENTS.md](AGENTS.md) when it ships. The measurements cited here are in [ARCHITECTURE.md](ARCHITECTURE.md#measurements).

## Practice

How work keeps the code from growing faster than it earns, to be softened where it chafes.

* **One in, one out:** a feature's commit simplifies something near it too, and each commit's net change in lines is reported with it. A split is exempt, as each part repeats its imports; its count is still reported.
* **Checks:** [tools/debt.py](tools/debt.py) reports declarations nothing uses (and fails on them), files over 1,600 lines, and the spec's length; it runs before each push.
* **Splits:** a file past 1,600 lines is split by what its parts do, with nothing else changed, never cutting a type in two.
* **The system's own:** controls and containers are the platform's (forms, rows, pickers, lockups, players), built by hand only where none exists or it can't do what's needed, saying why in a comment.
* **One copy:** what every player decides alike (names, what plays next, how qualities rank) is the core's, not each player's.
* **Pruning:** before a push, what the work since the last left unreached goes.

## Next

* **macOS:** serving (folders on this Mac included) and refreshing in the background, when the app isn't running (a launch agent can't reach the LAN; see below), real artwork for its placeholder icon, lists beyond the watchlist, and signing for distribution.
* **Command-line app:** commands to name the person and the device, so command-line apps show by name rather than as someone's device; and `library leave` removing this device first (`cq_remove_self`, then syncing), as the Apple TV's Leave This Library does, rather than only forgetting, as a removed device must.
* **Settings:** when each device was last seen.
* **Watching folders:** a device's own folders crawled as they change, rather than only when a crawl comes due or on Refresh Library: on the Mac, FSEvents on its folders and its downloads folder, crawling just that source once changes settle for a few seconds, regardless of the library's interval (which spares a NAS's disks, as a local disk needs no sparing), so other devices learn of new titles at their next sync without crawling; a folder on a network volume (`volumeIsLocalKey` false, as a mounted NAS share) isn't watched, as FSEvents misses changes other machines make, and keeps to the interval. On Linux, the command-line app's `serve --media` likewise, by inotify through `Io` where it can, rebuilding its `INDEX` and crawling its own source.
* **Linux:** running the other device itself there (its experiments ran in a VM).
* **Known issues:**
  * Tests that reach this Mac by its own `.local` name through mDNS (copy racing's in the core, and [cli/test.sh](cli/test.sh)'s discovery) fail while mDNS doesn't answer for it, as after VMs come and go; they pass again once it does.
  * macOS's Local Network privacy blocks the other device from the LAN (`HostUnreachable`) when run as a launch agent or started by another app, so the command-line app can't run in the background as one (its `agent` command was removed for that); Terminal and SSH sessions and system daemons are exempt (TN3179). The fix is to run it from a signed app bundle whose `Info.plist` says why it needs the local network, so macOS can ask once (the Mac app serves only while it runs). Until then, a test device runs in Terminal.

## Libraries

* **Hierarchy:** bracketed levels of library → kind → title [→ season] [→ episode] [→ version/cut/extra] [→ part] → quality often have one child; where one does, the UI may skip navigating it.
* **Qualities:** {720p, 1080p, 4K} H.264 or H.265 in MP4, MKV, or ISO; Apple players can't play MKV or ISO, so the transcoder makes MP4 qualities of them.
* **People:** each has any number of named lists.
  * A list's type is watchlist (or "borrowlist," of titles not yet held), smart playlist, or transcode queue.
  * A list's sharing is private,[^private] public, or collaborative, independent of its type.
  * Several people may pair a shared player.
* **Outside metadata** (plots, images, cast, ratings, trailer links, outside IDs) is provided to Cinematheque, never fetched by it: as JSON, or by a command it invokes with a title's identity, which answers in JSON. The provider is delivered separately, and the JSON's form is yet to be specified. Local trailer files come from sources.
* **Correlation:** a file maps to an outside title by, in order: an ID tag in its path, an NFO sidecar's `<uniqueid>`, then whatever the provider makes of its parsed title, year, and episode; doubtful matches go to the person. An outside ID, once known, is recorded beside the title, and titles whose keys differ but whose IDs match are merged.
* **Outside data:** IDs and correlations replicate freely; what providers supply may be bound by its sources' terms, so it replicates only among the players of the person whose provider supplied it.
* **Trust:** each source and transcoder decides whose edits it takes.
  * A source is the canonical store of its metadata; each library's edits are an overlay that the source adopts or ignores, by a per-library switch, decided by the Cinematheque code that manages it.
  * A transcoder likewise chooses which libraries' transcode queues it accepts.
* **Availability:** the library distinguishes what is reachable now from what is merely known, since desktop devices come and go (sleep, shutdown, travel) and sources may mount removable media.

Open:

* **Read-only members:** whether a per-library flag keeps some members (e.g., children) from editing the library's overlay and collaborative lists.

[^private]: Private data is masked from other people, not hardened against them: anyone with access to a player that holds it may recover it.

## Sync

* **Uninterruptible connects on tvOS:** in the Apple TV app, a blocking connect through `Io` wasn't interrupted when its task was canceled (copy racing waited out a dropped connection's TCP timeout, some 20 seconds; on macOS, the same connect is interrupted). Copy racing connects without blocking now; syncing, and pairing by address, still connect through `Io`, so a device that drops connections may hold a sync as long. Find why (whether the app's signal handling keeps `Io`'s `SIGIO` from interrupting it), or connect without blocking there too.
* **Pairing:** by address in the apps, for a new device off the network (it would show its address with its code, as the command-line app prints its port); a QR code carrying the code, for a phone app.
* **Partial replicas:** tvOS players have only purgeable cache storage, so they may be thin, holding part of a library fetched on demand (by a title's prefix, with shared proofs, as repair fetches fields; a prefix fetch was built and dropped unused after commit `ae9f1d6`) and its facet bitmaps, if rebuilding a whole replica after a purge (see [Apple TV player](#apple-tv-player)) proves too slow.
* **Repair:** range-based set reconciliation, if catching up by version vectors proves insufficient.
* **Members' powers, bounded:** a member may still cut a device off at 0 (dropping all it wrote), claim a stream's vector past what it holds (so devices skip its writes; send the latest batch's header with each entry, a protocol change), and, with a crafted early clock, a handover's generation. Check cutoffs against what the writer could have seen. And pairing: anyone on the network can spend an offer's 3 attempts, closing it.
* **Downloads' sources:** let only a downloads source's own device set `managed` on it.
* **Time limits:** nothing reads with one (crawls, MP4s, covers, downloads, syncs, the server), so a server sending a byte at a time holds a worker, or a connection, indefinitely, and 256 idle connections shut a device's server; give reads deadlines through `Io`, and the server a limit per address. Encrypt syncs (Noise, or TLS between device keys), as anyone listening on the network reads what one sends.
* **Compaction:** emptied fields stay as tombstones, so a device that missed the emptying can't revive an older value, and they grow with churn: in a reference library, emptied copies (from removed sources, and keys that parser fixes changed) outnumbered live ones, over a quarter of all winners. Drop a tombstone once every member device's version vector covers it, which needs devices to share the vectors they've seen of others; a device not heard from in long enough could be set aside, at the cost of its stale writes being refused. Sooner and with no coordination, a batch none of whose writes still wins (as progress saves are overtaken by later ones) is never sent again nor needed for a proof, so it, and its leaves (32 bytes a write, kept for good now), can be deleted as its last winner goes.

Open:

* **Connectivity beyond the LAN:** sync runs both ways, so a device behind a NAT syncs with a device it can reach (a hosted server, say), but two devices both behind NATs still can't reach each other, which the direct-connection rule for private data depends on; and sync isn't encrypted, so beyond the LAN it wants a TLS proxy in front of `serve`, or a VPN. Explored in other projects.
* **CloudKit:** an alternative to the CRDT, if non-Apple players can use it without a Developer subscription, and if it honors the direct-connection rule for private data.

## Sources

* **Qualities from files:** read a file's quality from the file itself (e.g., an MP4's tracks), for names that don't show it.
* **Listings:** also WebDAV `PROPFIND`, and the dates Apache and nginx print in HTML listings, so re-crawls can skip their unchanged directories; an occasional full sweep for files rewritten in place.
* **Moved files:** matched by size and modification time, which a rename keeps, so progress and lists follow them; where listings lack those, by hashes of files' first and last 64 KiB, taken by byte ranges when first seen.
* **Crawl intervals:** one per source, if the library's one doesn't suit (a web server daily, a NAS only when asked); and crawling at a time of day (overnight), if even a daily crawl spins a NAS's disks up when people mind.
* **Range probe:** flag sources that don't answer `Range: bytes=0-0` with 206 (e.g., Python's `http.server`), since players can't stream from them.
* **Discovery:** suggest static servers advertising `_http._tcp` or `_webdav._tcp`, and add sources with HTTP person and password.
* **Management:** by desktop devices, on a source's host or with network filesystem access to it: renaming and checksums; subtitles, cover art (slow to extract and bulky to cache), and text. To libraries, a static server is read-only until Cinematheque code reaches its files.

## Players

* **Windows:** two POSIX calls remain outside `Io`, each where Zig 0.17's `Io` can't yet do the job, and each needs a Windows path: the server's socket setup (`listen` in serve.zig, since `Io`'s `reuse_address` also sets `SO_REUSEPORT`), and peeking at DNS-SD's socket (`poll` with no wait, in discover.zig, since `Io` can't wait on a foreign socket). Zig 0.17's `Io` also has no connect timeout (it panics), so connecting relies on deadlines around it, as copy racing's.
* **Platforms:** iOS and iPadOS; Linux and Windows; later Wayland.
* **Web client** (`serve --web` is built; see [AGENTS.md](AGENTS.md)), still to come: a code once per browser, for networks where anyone reaching the port shouldn't. Later, the player's own controls (play, a scrubber, the time, volume, full screen, picture in picture) drawn with what's playing in one row that shows as the pointer moves, as the Mac player's, in place of the browser's. Once browsers need it, `--web` can be on by default (it's off for now, as anyone reaching the port could read and change the person's progress and watchlist).
* **Browsing:** by intersections of facets (e.g., new releases, thrillers or mysteries, starring A-listers, English audio), along the title hierarchy, since set-top remotes make typing slow and a library runs to thousands of titles. Full devices query facets in SQLite; thin players hold a bitmap per small facet's value, and posting lists for people.
* **Cover art, still to come** (what's built is in [AGENTS.md](AGENTS.md)):
  * **PNG placeholders:** PNG covers (a fraction of a percent, in a reference library) have none; `std.compress.flate` would decode them.
  * **Thumbnails from devices:** desktop devices make thumbnails (about 300×450, 20 KB) and serve them by hash (`/art/<hash>/<size>`), so players with no device near scale originals only as a fallback; and prefetching two screens ahead.
  * **Scale:** on a Mac with over 4,000 movies, flicking scrolls smoothly, and jumping with the scroll bar loads the covers in view in about half a second; at 6,000 and on iOS and tvOS, fall back to AppKit's and UIKit's collection views if SwiftUI's lazy grids drop frames.
  * **Thumbnail caches** (open): their size per platform (all of them on a Mac, about 120 MB; a budget on iPhone and iPad; purgeable storage on tvOS), and how Linux and Windows decode and scale images.
  * **Other sources:** the outside-metadata provider's art, and covers in Matroska files.
* **Who's watching:** set-top players are often shared, laptops and handhelds seldom; a shared player holds each of its people's private data, and hides it while several people are watching.
* **Watching together:** on one screen, offer titles every viewer will accept; apart, offer what the others would avoid.
* **Bulk actions:** selecting several tiles at once in the Mac's grid (⌘-click, ⇧-click, ⌘A), and episodes in the inspector, for what a tile's context menu does one at a time: Delete Download, Mark as Watched or Unwatched, and the watchlist; and clearing watched marks in bulk (the selection's, a series' or season's whole, or every one on the Watched shelf), so titles can be watched afresh. Only copies are deleted only once confirmed, as one alone is.
* **Downloads** (the command-line app's and the Mac's are built; see [AGENTS.md](AGENTS.md)), still to come: iOS and iPadOS, and Linux and Windows, whose free space the core can't yet read (only macOS's `statfs`); moving files when the folder changes, rather than fetching them again; downloading while the app is closed (with background serving); and keeping a series' next episodes in a quality of its own, rather than the commonest.

Open:

* **Linux and Windows players:** UI toolkit and playback engine. Explored in other projects.

## Apple TV player

What's built is in [AGENTS.md](AGENTS.md); still to come:

* **Movies:** an alphabetical jump, and filters by decade and genre (facets), since 4,000 covers are a long way by remote; Home's recently added titles.
* **People:** tvOS's profiles as library people (Who's watching, under Players).
* **Icon:** real artwork for the placeholder icons (the Mac's, and tvOS's layered brand assets with the Top Shelf), from [draw-icons.swift](apple/draw-icons.swift).

## Transcoder

A backend device on macOS, Linux, or Windows, also a source.

* **Engines:** `ffmpeg` for remuxes and `HandBrakeCLI` for re-encodes, each run as a separate process and never linked, since HandBrake and GPL builds of FFmpeg are GPL, which would bind the players and the shared core, which stay BSD and fit for the App Store. The transcoder drives `HandBrakeCLI` with JSON jobs (`--queue-import-file`) and reads its JSON progress (`--json`), one process per job, so canceling is killing and a crash spares the queue.
* **Remux first:** when every chosen stream already plays on Apple players, `ffmpeg` copies the streams into MP4, reading the input over HTTP; when only audio or subtitles don't, it copies the video and converts the rest; only a video re-encode, or disc-image input, goes to `HandBrakeCLI`.
  * Apple players take H.264 up to High 8-bit, HEVC Main and Main10 tagged `hvc1`, HDR10, HLG, and Dolby Vision profiles 5 and 8; AAC, ALAC, AC-3, E-AC-3, MP3, and FLAC audio; and text subtitles as `mov_text`. DTS and TrueHD audio and image subtitles (PGS, VobSub) must be converted.
  * Output is written with its index first (`-movflags +faststart`), for progressive playback.
* **MP4 in place:** inspecting MP4s and fixing them without a remux (retagging `hev1` as `hvc1`, moving the index first, editing metadata) come from a separate MP4 parsing and modification project.
* **Laziness:** transcodes under the person's supervision from transcode queues, so qualities needn't be made in advance (which takes compute and storage a legacy NAS was sized for).
* **Input and output:** reads input from any source over HTTP, and serves its output as a source. `HandBrakeCLI` reads only local paths, so its input, including disc images, is first copied to a cache by resumable range requests, which also serves several qualities. Input is often offline, on removable media.

## Other media

The decentralized library generalized for other apps, of books, audiobooks, and music, with Cinematheque one client of it.

* **Split:** a media-neutral core (identity, membership, pairing, replication and sync, discovery, serving, sources and crawling, private streams, lists, progress, covers and placeholders, downloads), with each kind of media a module supplying its names' parser, hierarchy, metadata readers, and qualities. Video's conventions (Plex, Jellyfin, and Kodi naming; editions; the transcoder) become one such module.
* **Kinds:** each under a key prefix of its own (`t/<kind>/...`, as movies and series are), with progress in its own units.
  * **Books:** EPUB, PDF, and comics (CBZ); author → series → book → format; progress as a locator (an EPUB CFI, or a page), not milliseconds; metadata from EPUB's OPF and Calibre's `metadata.opf` sidecars.
  * **Audiobooks:** M4B (with chapters), and folders of MP3s; author → series → book → part; progress in milliseconds across parts; the narrator as metadata.
  * **Music:** artist → album → disc → track; FLAC, ALAC or AAC (M4A), and MP3; tags from Vorbis comments, MP4 atoms, and ID3; play counts and when last played, in place of progress; lossless and lossy as qualities.
* **Pairing UX:** pairing by code, New Devices, and setup as a shared SwiftUI package. Pairing once covers every app on a device: its identity and data directory are shared among the apps (an app group, and a Keychain access group for the seeds).
* **Lists:** the watchlist generalized, per [Libraries](#libraries): private, shared (read by members), and collaborative (written by members) lists of any kind's titles: reading lists, want-to-hear, and playlists. Playlists are ordered, so collaborative ones need an ordered sequence (Fugue, in [specifications](docs/specifications/README.md)); smart lists are queries over facets.
* **Covers:** extraction generalized from MP4's `covr`, by range requests, each with its ThumbHash placeholder: ID3's `APIC`, FLAC's `PICTURE` blocks, EPUB's OPF cover item, a comic's first page; and each kind's sidecars (`cover.jpg`, `folder.jpg`, Calibre's `cover.jpg`). PDFs, which need rendering, take a sidecar or none.
* **Downloads:** generalized from [Players](#players): offline copies per device in a chosen quality, served to devices nearby from desktop devices; whole albums and audiobooks, and a book's file.
* **Packaging:** the core as an XCFramework with a Swift package over it (the model, the cover cache, pairing and setup views) for each app; the command-line app crawls and serves every kind.

Open:

* **Apps and libraries:** one app per kind or one for all, and one library a household shares across kinds or one per kind; a library across kinds lets one source (a NAS) be crawled once for everything.
* **Units:** how progress generalizes across kinds without each player knowing every unit.
