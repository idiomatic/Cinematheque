# Development

Unbuilt work and open design questions, in the terms [AGENTS.md](AGENTS.md) defines. Each item moves into [AGENTS.md](AGENTS.md) when it ships. The [experiments](experiments/README.md) hold the measurements cited here.

## Next

* **macOS:** serving (folders on this Mac included) and refreshing in the background, when the app isn't running (the command-line peer's agents can't reach the LAN; see below), an app icon, lists beyond the watchlist, and signing for distribution.
* **Command-line peer:** commands to name the user and the device, so command-line peers show by name rather than as someone's device.
* **Settings:** when each device was last seen.
* **Linux:** running the peer itself there (its experiments ran in a VM).
* **Known issues:**
  * macOS's Local Network privacy blocks the peer from the LAN (`HostUnreachable`) when run as a launch agent or started by another app, so `agent add`'s agents can't reach a NAS; Terminal and SSH sessions and system daemons are exempt (TN3179). The fix is to run it from a signed app bundle whose `Info.plist` says why it needs the local network, so macOS can ask once (the Mac app serves only while it runs). Until then, a test peer runs in Terminal.

## Libraries

* **Hierarchy:** bracketed levels of library → kind → title [→ season] [→ episode] [→ version/cut/extra] [→ part] → rendition often have one child; where one does, the UI may skip navigating it.
* **Renditions:** {720p, 1080p, 4K} H.264 or H.265 in MP4, MKV, or ISO; Apple players can't play MKV or ISO, so the transcoder makes MP4 renditions of them.
* **Users:** each has any number of named lists.
  * A list's type is watchlist (or "borrowlist," of titles not yet held), smart playlist, or transcode queue.
  * A list's sharing is private,[^private] public, or collaborative, independent of its type.
  * Several users may link a shared player.
* **Outside metadata** (plots, images, cast, ratings, trailer links, outside IDs) is provided to Cinematheque, never fetched by it: as JSON, or by a command it invokes with a title's identity, which answers in JSON. The provider is delivered separately, and the JSON's form is yet to be specified. Local trailer files come from repositories.
* **Correlation:** a file maps to an outside title by, in order: an ID tag in its path, an NFO sidecar's `<uniqueid>`, then whatever the provider makes of its parsed title, year, and episode; doubtful matches go to the user. An outside ID, once known, is recorded beside the title, and titles whose keys differ but whose IDs match are merged.
* **Outside data:** IDs and correlations replicate freely; what providers supply may be bound by its sources' terms, so it replicates only among the players of the user whose provider supplied it.
* **Trust:** each repository and transcoder decides whose edits it takes.
  * A repository is the canonical store of its metadata; each library's edits are an overlay that the repository adopts or ignores, by a per-library switch, decided by the Cinematheque code that manages it.
  * A transcoder likewise chooses which libraries' transcode queues it accepts.
* **Availability:** the library distinguishes what is reachable now from what is merely known, since desktop peers come and go (sleep, shutdown, travel) and repositories may mount removable media.

Open:

* **Read-only members:** whether a per-library flag keeps some members (e.g., children) from editing the library's overlay and collaborative lists.

[^private]: Private data is masked from other users, not hardened against them: anyone with access to a player that holds it may recover it.

## Sync

* **Pairing:** by address in the apps, for a new device off the network (it would show its address with its code, as the command-line peer prints its port); a QR code carrying the code, for a phone app.
* **Partial replicas:** tvOS players have only purgeable cache storage, so they may be thin, holding part of a library fetched on demand (by a title's prefix, with shared proofs, as repair fetches fields; a prefix fetch was built and dropped unused after commit `ae9f1d6`) and its facet bitmaps, if rebuilding a whole replica after a purge (see [Apple TV player](#apple-tv-player)) proves too slow.
* **Repair:** range-based set reconciliation, if catching up by version vectors proves insufficient.
* **Compaction:** emptied fields stay as tombstones, so a peer that missed the emptying can't revive an older value, and they grow with churn: in a reference library, 40,000 emptied holdings (from removed repositories, and keys that parser fixes changed) outnumbered 20,000 live ones, 28% of all winners. Drop a tombstone once every member device's version vector covers it, which needs peers to share the vectors they've seen of others; a device not heard from in long enough could be set aside, at the cost of its stale writes being refused.

Open:

* **Connectivity beyond the LAN:** sync runs both ways, so a device behind a NAT syncs with a peer it can reach (a hosted server, say), but two devices both behind NATs still can't reach each other, which the direct-connection rule for private data depends on; and sync isn't encrypted, so beyond the LAN it wants a TLS proxy in front of `serve`, or a VPN. Explored in other projects.
* **CloudKit:** an alternative to the CRDT, if non-Apple players can use it without a Developer subscription, and if it honors the direct-connection rule for private data.

## Repositories

* **Renditions from files:** read a file's rendition from the file itself (e.g., an MP4's tracks), for names that don't show it.
* **Listings:** also WebDAV `PROPFIND`, and the dates Apache and nginx print in HTML listings, so re-crawls can skip their unchanged directories; an occasional full sweep for files rewritten in place.
* **Moved files:** matched by size and modification time, which a rename keeps, so playheads and lists follow them; where listings lack those, by hashes of files' first and last 64 KiB, taken by byte ranges when first seen.
* **Range probe:** flag repositories that don't answer `Range: bytes=0-0` with 206 (e.g., Python's `http.server`), since players can't stream from them.
* **Discovery:** suggest static servers advertising `_http._tcp` or `_webdav._tcp`, and add repositories with HTTP user and password.
* **Management:** by desktop peers, on a repository's host or with network filesystem access to it: renaming and checksums; subtitles, cover art (slow to extract and bulky to cache), and text. To libraries, a static server is read-only until Cinematheque code reaches its files.

## Players

* **Windows:** two POSIX calls remain outside `Io`, each where Zig 0.17's `Io` can't yet do the job, and each needs a Windows path: the server's socket setup (`listen` in serve.zig, since `Io`'s `reuse_address` also sets `SO_REUSEPORT`), and peeking at DNS-SD's socket (`poll` with no wait, in discover.zig, since `Io` can't wait on a foreign socket). Zig 0.17's `Io` also has no connect timeout (it panics), so connecting relies on deadlines around it, as copy racing's.
* **Platforms:** iOS and iPadOS; Linux and Windows; a web player for low-capacity hosts (e.g., a Raspberry Pi); later Wayland.
* **Browsing:** by intersections of facets (e.g., new releases, thrillers or mysteries, starring A-listers, English audio), along the title hierarchy, since set-top remotes make typing slow and a library runs to thousands of titles. Full peers query facets in SQLite; thin players hold a bitmap per small facet's value, and posting lists for people.
* **Cover art, still to come** (what's built is in [AGENTS.md](AGENTS.md)):
  * **PNG placeholders:** PNG covers (7 of 5,000 in a reference library) have none; `std.compress.flate` would decode them.
  * **Thumbnails from peers:** desktop peers make thumbnails (about 300×450, 20 KB) and serve them by hash (`/art/<hash>/<size>`), so players with no peer near scale originals only as a fallback; and prefetching two screens ahead.
  * **Scale:** on a Mac with 4,000 movies, flicking scrolls smoothly, and jumping with the scroll bar loads the covers in view in about half a second; at 6,000 and on iOS and tvOS, fall back to AppKit's and UIKit's collection views if SwiftUI's lazy grids drop frames.
  * **Thumbnail caches** (open): their size per platform (all of them on a Mac, about 120 MB; a budget on iPhone and iPad; purgeable storage on tvOS), and how Linux and Windows decode and scale images.
  * **Other sources:** the outside-metadata provider's art, and covers in Matroska files.
* **Who's watching:** set-top players are often shared, laptops and handhelds seldom; a shared player holds each of its users' private data, and hides it while several users are watching.
* **Watching together:** on one screen, offer titles every viewer will accept; apart, offer what the others would avoid.
* **Downloads:** for poor connections (e.g., a flight), where the platform permits, including podcast-like prefetching of a series' next N episodes in a chosen rendition; downloads play offline and, on desktop peers, are served to peers nearby.

Open:

* **Linux and Windows players:** UI toolkit and playback engine. Explored in other projects.

## Apple TV player

What's built is in [AGENTS.md](AGENTS.md); still to come:

* **Movies:** an alphabetical jump, and filters by decade and genre (facets), since 4,000 covers are a long way by remote; Home's recently added titles.
* **Purges:** check that a purged replica comes back by syncing and crawling, with the seeds from the Keychain.
* **Users:** tvOS's profiles as library users (Who's watching, under Players).
* **Later:** a Top Shelf of Continue Watching; covers as artwork in the player's info panel.

## Transcoder

A backend peer on macOS, Linux, or Windows, also a repository.

* **Engines:** `ffmpeg` for remuxes and `HandBrakeCLI` for re-encodes, each run as a separate process and never linked, since HandBrake and GPL builds of FFmpeg are GPL, which would bind the players and the shared core, which stay BSD and fit for the App Store. The transcoder drives `HandBrakeCLI` with JSON jobs (`--queue-import-file`) and reads its JSON progress (`--json`), one process per job, so canceling is killing and a crash spares the queue.
* **Remux first:** when every chosen stream already plays on Apple players, `ffmpeg` copies the streams into MP4, reading the input over HTTP; when only audio or subtitles don't, it copies the video and converts the rest; only a video re-encode, or disc-image input, goes to `HandBrakeCLI`.
  * Apple players take H.264 up to High 8-bit, HEVC Main and Main10 tagged `hvc1`, HDR10, HLG, and Dolby Vision profiles 5 and 8; AAC, ALAC, AC-3, E-AC-3, MP3, and FLAC audio; and text subtitles as `mov_text`. DTS and TrueHD audio and image subtitles (PGS, VobSub) must be converted.
  * Output is written with its index first (`-movflags +faststart`), for progressive playback.
* **MP4 in place:** inspecting MP4s and fixing them without a remux (retagging `hev1` as `hvc1`, moving the index first, editing metadata) come from a separate MP4 parsing and modification project.
* **Laziness:** transcodes under the user's supervision from transcode queues, so renditions needn't be made in advance (which takes compute and storage a legacy NAS was sized for).
* **Input and output:** reads input from any repository over HTTP, and serves its output as a repository. `HandBrakeCLI` reads only local paths, so its input, including disc images, is first copied to a cache by resumable range requests, which also serves several renditions. Input is often offline, on removable media.

## Other media

The decentralized library generalized for other apps, of books, audiobooks, and music, with Cinematheque one client of it.

* **Split:** a media-neutral core (identity, membership, pairing, replication and sync, discovery, serving, repositories and crawling, private streams, lists, progress, covers and placeholders, downloads), with each kind of media a module supplying its names' parser, hierarchy, metadata readers, and renditions. Video's conventions (Plex, Jellyfin, and Kodi naming; editions; the transcoder) become one such module.
* **Kinds:** each under a key prefix of its own (`t/<kind>/...`, as movies and series are), with progress in its own units.
  * **Books:** EPUB, PDF, and comics (CBZ); author → series → book → format; progress as a locator (an EPUB CFI, or a page), not milliseconds; metadata from EPUB's OPF and Calibre's `metadata.opf` sidecars.
  * **Audiobooks:** M4B (with chapters), and folders of MP3s; author → series → book → part; progress in milliseconds across parts; the narrator as metadata.
  * **Music:** artist → album → disc → track; FLAC, ALAC or AAC (M4A), and MP3; tags from Vorbis comments, MP4 atoms, and ID3; play counts and when last played, in place of playheads; lossless and lossy as renditions.
* **Pairing UX:** pairing by code, New Devices, and setup as a shared SwiftUI package. Pairing once covers every app on a device: its identity and home are shared among the apps (an app group, and a Keychain access group for the seeds).
* **Lists:** the watchlist generalized, per [Libraries](#libraries): private, shared (read by members), and collaborative (written by members) lists of any kind's titles: reading lists, want-to-hear, and playlists. Playlists are ordered, so collaborative ones need an ordered sequence (Fugue, in [specifications](docs/specifications/README.md)); smart lists are queries over facets.
* **Covers:** extraction generalized from MP4's `covr`, by range requests, each with its ThumbHash placeholder: ID3's `APIC`, FLAC's `PICTURE` blocks, EPUB's OPF cover item, a comic's first page; and each kind's sidecars (`cover.jpg`, `folder.jpg`, Calibre's `cover.jpg`). PDFs, which need rendering, take a sidecar or none.
* **Downloads:** generalized from [Players](#players): offline copies per device in a chosen rendition, served to peers nearby from desktop peers; whole albums and audiobooks, and a book's file.
* **Packaging:** the core as an XCFramework with a Swift package over it (the model, the cover cache, pairing and setup views) for each app; the command-line peer crawls and serves every kind.

Open:

* **Apps and libraries:** one app per kind or one for all, and one library a household shares across kinds or one per kind; a library across kinds lets one repository (a NAS) be crawled once for everything.
* **Units:** how progress generalizes across kinds without each player knowing every unit.
