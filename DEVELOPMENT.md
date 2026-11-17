# Development

Unbuilt work and open design questions, in the terms [AGENTS.md](AGENTS.md) defines. Each item moves into [AGENTS.md](AGENTS.md) when it ships. The [experiments](experiments/README.md) hold the measurements cited here.

## Next

* **macOS:** serving from the app and its background agent (both need the command-line peer today), an app icon, lists beyond the watchlist, and signing for distribution.
* **Linux:** running the peer itself there (its experiments ran in a VM).
* **Experiments:** merge the READMEs of experiments whose code is gone (crdt, naming, discovery, repository) into [experiments/README.md](experiments/README.md), keeping their methods and results.
* **Known issues:**
  * macOS's Local Network privacy can block the peer from reaching the LAN (`HostUnreachable`, as Python's `No route to host`) when it's started by a program without that permission, while Apple's own tools, such as `curl`, get through; check the launch agents, and how the peer asks.

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

* **Pairing:** a user links a new player by QR code, or by typing a code, instead of copying the user's secret.
* **Partial replicas:** tvOS players have only purgeable cache storage, so they may be thin, holding part of a library fetched on demand (the core's thin fetches) and its facet bitmaps.
* **Repair:** range-based set reconciliation, if catching up by version vectors proves insufficient.

Open:

* **Connectivity beyond the LAN:** how peers reach each other across NATs, which the direct-connection rule for private data depends on. Explored in other projects.
* **CloudKit:** an alternative to the CRDT, if non-Apple players can use it without a Developer subscription, and if it honors the direct-connection rule for private data.

## Repositories

* **Renditions from files:** read a file's rendition from the file itself (e.g., an MP4's tracks), for names that don't show it.
* **Listings:** also WebDAV `PROPFIND`, and the dates Apache and nginx print in HTML listings, so re-crawls can skip their unchanged directories; an occasional full sweep for files rewritten in place.
* **Moved files:** matched by size and modification time, which a rename keeps, so playheads and lists follow them; where listings lack those, by hashes of files' first and last 64 KiB, taken by byte ranges when first seen.
* **Range probe:** flag repositories that don't answer `Range: bytes=0-0` with 206 (e.g., Python's `http.server`), since players can't stream from them.
* **Discovery:** suggest static servers advertising `_http._tcp` or `_webdav._tcp`, and add repositories with HTTP user and password.
* **Management:** by desktop peers, on a repository's host or with network filesystem access to it: renaming and checksums; subtitles, cover art (slow to extract and bulky to cache), and text. To libraries, a static server is read-only until Cinematheque code reaches its files.

## Players

* **Platforms:** iOS, iPadOS, and tvOS; Linux and Windows; a web player for low-capacity hosts (e.g., a Raspberry Pi); later Wayland.
* **Browsing:** by intersections of facets (e.g., new releases, thrillers or mysteries, starring A-listers, English audio), along the title hierarchy, since set-top remotes make typing slow and a library runs to thousands of titles. Full peers query facets in SQLite; thin players hold a bitmap per small facet's value, and posting lists for people.
* **Cover art, still to come** (what's built is in [AGENTS.md](AGENTS.md)):
  * **Placeholders:** a ThumbHash (about 25 bytes) per cover in the catalog, so a tile shows a blurred likeness at once rather than a color; decoding images in the core, given in-project code over dependencies, is the question.
  * **Thumbnails from peers:** desktop peers make thumbnails (about 300×450, 20 KB) and serve them by hash (`/art/<hash>/<size>`), so players with no peer near scale originals only as a fallback; and prefetching two screens ahead.
  * **Scale:** on a Mac with 4,000 movies, flicking scrolls smoothly, and jumping with the scroll bar loads the covers in view in about half a second; at 6,000 and on iOS and tvOS, fall back to AppKit's and UIKit's collection views if SwiftUI's lazy grids drop frames.
  * **Thumbnail caches** (open): their size per platform (all of them on a Mac, about 120 MB; a budget on iPhone and iPad; purgeable storage on tvOS), and how Linux and Windows decode and scale images.
  * **Other sources:** the outside-metadata provider's art, and covers in Matroska files.
* **Who's watching:** set-top players are often shared, laptops and handhelds seldom; a shared player holds each of its users' private data, and hides it while several users are watching.
* **Watching together:** on one screen, offer titles every viewer will accept; apart, offer what the others would avoid.
* **Downloads:** for poor connections (e.g., a flight), where the platform permits, including podcast-like prefetching of a series' next N episodes in a chosen rendition; downloads play offline and, on desktop peers, are served to peers nearby.

Open:

* **Linux and Windows players:** UI toolkit and playback engine. Explored in other projects.

## Transcoder

A backend peer on macOS, Linux, or Windows, also a repository.

* **Engines:** `ffmpeg` for remuxes and `HandBrakeCLI` for re-encodes, each run as a separate process and never linked, since HandBrake and GPL builds of FFmpeg are GPL, which would bind the players and the shared core, which stay BSD and fit for the App Store. The transcoder drives `HandBrakeCLI` with JSON jobs (`--queue-import-file`) and reads its JSON progress (`--json`), one process per job, so canceling is killing and a crash spares the queue.
* **Remux first:** when every chosen stream already plays on Apple players, `ffmpeg` copies the streams into MP4, reading the input over HTTP; when only audio or subtitles don't, it copies the video and converts the rest; only a video re-encode, or disc-image input, goes to `HandBrakeCLI`.
  * Apple players take H.264 up to High 8-bit, HEVC Main and Main10 tagged `hvc1`, HDR10, HLG, and Dolby Vision profiles 5 and 8; AAC, ALAC, AC-3, E-AC-3, MP3, and FLAC audio; and text subtitles as `mov_text`. DTS and TrueHD audio and image subtitles (PGS, VobSub) must be converted.
  * Output is written with its index first (`-movflags +faststart`), for progressive playback.
* **MP4 in place:** inspecting MP4s and fixing them without a remux (retagging `hev1` as `hvc1`, moving the index first, editing metadata) come from a separate MP4 parsing and modification project.
* **Laziness:** transcodes under the user's supervision from transcode queues, so renditions needn't be made in advance (which takes compute and storage a legacy NAS was sized for).
* **Input and output:** reads input from any repository over HTTP, and serves its output as a repository. `HandBrakeCLI` reads only local paths, so its input, including disc images, is first copied to a cache by resumable range requests, which also serves several renditions. Input is often offline, on removable media.
