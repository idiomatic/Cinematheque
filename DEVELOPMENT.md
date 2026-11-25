# Development

Unbuilt work and open design questions, in the terms [AGENTS.md](AGENTS.md) defines; each item moves there when it ships. Measurements cited are in [ARCHITECTURE.md](ARCHITECTURE.md#measurements).

## Routine

When each routine task was last done, and the commit it looked at (or made), so the next covers what came after.

| Task | Done | Commit | Notes |
| --- | --- | --- | --- |
| Security audit | 2026-11-20 | `8d96a14` | Its fixes through `8fc7843`; the limits it left under [What members are trusted with](#sync) |
| Code review | 2026-11-22 | `1f012f1` | Since the audit; its high and medium findings fixed through `a18e45d`, its low ones since, one left as a limit under [What members are trusted with](#sync) |
| Screenshots | 2026-11-24 | `bc0fcd4` | [tools/screenshots.sh](tools/screenshots.sh): every player and the hero, on the mock library's 28 seasons; the loop (`video`) as of `773bebf` |

## Practice

How work keeps the code from growing faster than it earns; soften these where they chafe.

* **One in, one out:** a feature's commit also simplifies something near it, and each commit reports its net change in lines; a split is exempt, as each part repeats its imports, but still reports its count.
* **Checks:** [tools/debt.py](tools/debt.py), run before each push, reports declarations nothing uses, files over 1,600 lines, and the specs' lengths, failing on an unused declaration or a spec over its budget ([AGENTS.md](AGENTS.md) 8,000 words, [ARCHITECTURE.md](ARCHITECTURE.md) 2,300), so the specs stay terse: a requirement once, rationale in a clause, history in commits.
* **Splits:** a file past 1,600 lines is split by what its parts do, nothing else changed, never cutting a type in two.
* **The system's own:** controls and containers are the platform's (forms, rows, pickers, lockups, players); one is built by hand only where none exists or it can't do what's needed, with a comment saying why.
* **One copy:** what every player decides alike (names, what plays next, how qualities rank) is the core's.
* **Pruning:** before a push, remove what the work since the last push left unreached.
* **Workarounds:** one needing more than a line to justify is a design to fix; an outside bug's gets one line and a Known issues entry, removed with the bug.

## Next

* **macOS:** serving and refreshing in the background while the app isn't running (blocked by Local Network privacy; see Known issues), and signing for distribution. Icon under [Apple TV player](#apple-tv-player).
* **Choosing the external player** (VLC is built): per device, in Settings (kept in `local`). On the Mac, any app opening the copy's type (`NSWorkspace`, by bundle ID); on the iPhone and Apple TV, known link schemes declared in `LSApplicationQueriesSchemes`, shown if `canOpenURL` finds them, the first installed the default. Infuse's (`infuse://x-callback-url/play?url=`) and IINA's (`iina://weblink?url=`) are from memory, to check.
* **A person's own sources:** seen only by its person, so housemates don't learn what someone watches. Everything crawling it writes (source, titles, items, copies, descriptions, covers' ranges, placeholders; a title's key alone says what it is) travels only on the private stream, so crawling, describing, views, and racing read a private overlay beside the shared catalog, merging a title held both ways. Other members' devices never crawl it. To decide: whether its server, reachable by anyone on the network, needs credentials; whether it can be shared with chosen members, as lists are; and that it's added only from one of its person's devices, as private streams sync only directly.
* **Playlists** (lists and Shared are built): a list's own order by hand, played through in order from where each entry was left. Each entry's place is a fractional index between its neighbors', merged last-writer-wins without a sequence CRDT.
  * **Collaborative:** every member sees and changes the list and its mode. Admission takes any member's write to `l/<owner>/<id>` if the list was collaborative as of the write's clock, by the latest entry at or before it in the existing `mode:<random>` log, so devices agree however changes arrive. A write arriving before the change allowing it is turned away unclaimed, to come again next sync. A collaborator making it private hands it back to its owner and loses sight of it, so the menu says so first.
* **Debug builds' connecting:** Zig 0.17.1's `connectMany` cancels racing attempts by signal, and an interrupted attempt calls `connect` again, getting `EISCONN`, which `posixConnect` panics on in Debug. The fix is `std`'s (after `EINTR`, wait for writability and read `SO_ERROR`); to report to Zig. Then the apps' debug builds can drop ReleaseSafe (52-second core rebuilds, against 7); the command-line app's still panic.
* **Companions** (after collaborative lists): outside programs working a list's placeholders (fetching a channel's videos, a library hold). Each is a member of its own, never a person's device (which would get the person's seed), working a list shared with it collaboratively; it syncs, reads `cq_lists`' wanted entries (C interface or web API), and polls. Placeholders gain, beside the note:
  * **What's wanted:** a title, or an upgrade to a quality, met once a copy of it is crawled.
  * **Where from:** an address to fetch.
  * **Status:** the companion's last word ("On hold, 3rd in line"), in its own field, shown under Not in library.
  * **Matching:** a companion making the file names it from the placeholder's key (see [the guide](docs/guide.md#naming)); one that only watches relies on the usual match.
* **Date Added by creation time:** files' creation times from this app's own server (in its `INDEX` and listings), better than modification times on a first crawl.
* **Showing it in the README** (hero, row of four, and loop built; see [tools/README.md](tools/README.md#screenshots)), always on the mock library, never anyone's own:
  * **Sanctuary Moon at length:** 397+ episodes (now three seasons and a special), so lists look lived in; about 50 MB and an FFmpeg run each, as each file carries its tags.
  * **Decided:** screenshots committed with the README; dark first, light too, by `<picture>` and `prefers-color-scheme`; the hero scripted at a person's pace, so it looks used, not staged.
* **Heuristics review:** find rules fitted to one library's or the test data's quirks. Parser: Kodi compact codes from the enclosing folder, numberless files extending a series' name as specials, dots between digits. Short names: options only to tell two apart. Apps: a season of 1000+ as a year, nothing said of a lone first season, a series' year from its folder. Each stays only if it serves a deliberate convention ([the guide](docs/guide.md#naming)).
* **Timers review:** every sleep, delay, poll, and debounce in the core, command-line app, web client, and apps either becomes the event it waits on (an `Io` future, a notification, an observation, a callback) or gets a comment saying why time is the right signal.
* **One structure, each platform's chrome** (mostly built): sketches, interpretations rather than mockups, are [the four](docs/design/home.svg), flows for [Apple TV](docs/design/flow-tvos.svg), [Mac](docs/design/flow-mac.svg), [web](docs/design/flow-web.svg), and [iPhone](docs/design/flow-iphone.svg), and [covers' shapes](docs/design/tiles.svg); their worded buttons become symbols with tooltips, but Settings'. Left:
  * **Apple TV:** a Top Shelf title pushed like any page rather than presented over the app (to try on a device); focus starting on Continue Watching's first cover (in the simulator, `defaultFocus` and `prefersDefaultFocus` were passed over).
  * **Mac:** Open in New Window for a title (context menu, Option-click); every action reachable by a button or the menu bar (to check). An idea: forgetting each finished title a week after it's watched, in place of Forget Watched…, if bulk forgetting proves its only use.
  * **iPhone:** its own setup (by code, as the Apple TV's), downloading, and checking on a device.
  * **Open:** acting on several titles at once (see [Bulk actions](#players)).
* **Nothing only in a context menu:** review the Mac, Apple TV, and web client so every feature (a list's renaming, sharing, and deleting; Lists on a tile; marking watched; downloads) has another way in; context menus stay as shortcuts.
* **Quality from the file itself:** a file whose name, folders, and source say nothing is Other; describing already reads `moov`, whose video track gives resolution, codec, and color. As quality is part of a copy's key, learning it on describing means re-keying the copy (or a range read per file at crawl time), and every device must name it alike from the same bytes.
* **Channels' playlists apart from their channels:**
  * **As a list** (preferred): each playlist a list of the channel's episodes in its order, nothing fetched twice. Needs lists of episodes, a list's own order (under Playlists), and the tool saying what each playlist holds: a sidecar file a crawl reads, or a list written through the C interface, as a companion would.
  * **As a series of its own:** a folder per playlist, numbered by place, but a video in two playlists needs a link or fetching twice.
* **Full crawls by themselves** (postponed until Refresh Library Fully shows a need): an unasked refresh fully crawls a source not fully crawled in a week, catching files retagged in place.
* **Watching folders:** a device's own folders crawled as they change. On the Mac, FSEvents on its folders and downloads, crawling that source once changes settle, regardless of the interval; network volumes (`volumeIsLocalKey` false) aren't watched, as FSEvents misses other machines' changes. On Linux, `serve --media` likewise by inotify through `Io`.
* **Linux:** running the command-line app there for real; release builds for Alpine (musl) and Fedora, as each links its own SQLite and Avahi.
* **Releases:** the Mac app notarized under a Developer ID; the others through TestFlight.
* **Next major release:** remove `CINEMATHEQUE_DNSSD` and `_cinemock._tcp` from `NSBonjourServices`, a stopgap for testing beside a live library.
* **Known issues:**
  * Tests reaching this Mac by its `.local` name (copy racing's, [cli/test.sh](cli/test.sh)'s discovery) fail while mDNS doesn't answer for it, as after VMs come and go.
  * On the Mac, search collapses to a button for a moment as the inspector opens: SwiftUI moves it into the inspector's narrow, animating toolbar section, and `DefaultToolbarItem(kind: .search)` doesn't keep it.
  * Local Network privacy blocks the command-line app as a launch agent or when started by another app (`HostUnreachable`); Terminal, SSH, and system daemons are exempt (TN3179). The fix is a signed app bundle whose `Info.plist` says why; until then, test devices run in Terminal.
  * `pair CODE URL` needs the URL's `/pair` path; without it, it fails as `BadStatus`. It should add `/pair` itself, and say what went wrong.

## Sync

* **Uninterruptible connects on tvOS:** canceling doesn't interrupt a blocking connect through `Io` there (it does on macOS), so a dropped connection holds a sync or pairing by address some 20 seconds; copy racing already connects without blocking. Find why (the app's signal handling and `Io`'s `SIGIO`?), or do likewise. Sleeps and reads are uninterruptible too, so [deadline.zig](core/src/deadline.zig) stops waiting only once a read returns.
* **Pairing:** by address in the apps, for a device off the network; a QR code for a phone.
* **Partial replicas:** if rebuilding a purged tvOS replica proves too slow, thin players holding part of a library, fetched on demand by title prefix with shared Merkle proofs (both built once and dropped unused, after `ae9f1d6`), plus facet bitmaps.
* **Syncing in parallel:** exchanges on connections of their own, the writer taken only to apply, so a slow device holds up none.
* **Set reconciliation:** range-based, if version vectors prove insufficient.
* **What members are trusted with:** a cheating member's device may still cut a device off at 0, and claim to hold writes it left out (only winners are sent). Closing these needs proofs of what a remover had seen and what a sender's vector covers. Any member may remove all others, as none outranks another.
* **Compaction:** tombstones grow with churn (over a quarter of winners in a reference library). Drop one once every member device's vector covers it, which needs devices to share the vectors they've seen; a long-silent device could be set aside, its stale writes refused. Sooner, with no coordination: delete a batch, with its leaves (32 bytes a write), once none of its writes still wins.

Open:

* **Beyond the LAN:** two devices behind NATs can't reach each other, which private data's direct syncing depends on; media isn't sealed, so it wants a TLS proxy before `serve`, or a VPN. Explored in other projects.
* **HTTP/2 or HTTP/3 alone,** for multiplexing and compressed headers: both need TLS in browsers and AVFoundation, so it waits on certificates players trust on the LAN (pinned keys in the apps; browsers harder) and on `std.http`, which has neither.
* **CloudKit** instead of the CRDT, if non-Apple players can use it without a Developer subscription and it honors private data's direct syncing.

## Sources

* **Listings:** WebDAV `PROPFIND`, and Apache's and nginx's HTML dates, so re-crawls skip unchanged directories.
* **Moved files:** matched by size and modification time, else by hashes of the first and last 64 KiB, so progress and lists follow them.
* **Crawl intervals:** per source, and at a time of day (overnight).
* **Range probe:** flag sources not answering `Range: bytes=0-0` with 206 (as Python's `http.server`), which players can't stream from.
* **Discovery:** suggest static servers advertising `_http._tcp` or `_webdav._tcp`; sources with an HTTP user name and password.
* **Management:** by desktop devices with access to a source's files: renaming, checksums, subtitles, cover art, and text. A static server is otherwise read-only.

## Players

* **Windows:** two POSIX calls outside `Io` need Windows paths: `listen` in [serve.zig](core/src/serve.zig) (`Io`'s `reuse_address` also sets `SO_REUSEPORT`) and a no-wait `poll` of DNS-SD's socket in [discover.zig](core/src/discover.zig). `Io` has no connect timeout, so connecting relies on deadlines around it.
* **Platforms:** iPadOS, Linux, Windows; later Wayland.
* **Web client** (built for a browser on the server's computer), to come:
  * **Browsers elsewhere as devices:** one shows a code, a member's device adds it as Yours or Someone New, and it's a device with keys, a stream, and progress, known by an `HttpOnly`, `SameSite=Strict` cookie. Its keys stay on the server (simple, but a sniffed cookie acts as it until removed) or in the browser (requests signed, but 1,000 to 2,000 lines of JavaScript Ed25519 and CPace, and the person's seed in browser storage). Either way, one replica must host several people's private streams.
  * **Passkeys** in place of the cookie, where the server has HTTPS (WebAuthn needs a secure context).
  * **Its own player controls** in one row over the video, shown as the pointer moves, as the Mac's.
* **Browsing by facets** (new releases, thrillers, English audio) intersected, as remotes make typing slow: SQLite queries on full devices, bitmaps per value on thin players.
* **Cover art:**
  * **PNG shapes** from `IHDR`.
  * **Thumbnails from devices** (about 300×450, 20 KB) served by hash (`/art/<hash>/<size>`), originals scaled only as a fallback; prefetching two screens ahead.
  * **Scale:** at 6,000 movies, or on iOS and tvOS, collection views if SwiftUI's lazy grids drop frames.
  * **Caches** (open): size per platform (all on a Mac, about 120 MB; a budget on iPhone; purgeable on tvOS), and decoding on Linux and Windows.
  * **Other sources:** a metadata provider's art; Matroska's covers.
* **Who's watching:** a shared set-top player holds each of its people's private data, hidden while several watch.
* **Watching together:** together, titles all accept; apart, what others would avoid.
* **Bulk actions:** selecting several tiles in the Mac's grid (⌘-click, ⇧-click, ⌘A) and episodes in the inspector, for Delete Download, Mark as Watched or Unwatched, and Lists; and clearing watched marks of a selection, series, or season. Deleting only copies is confirmed.
* **Downloads** (built on the Mac and command-line app), to come: iOS, Linux, and Windows (the core reads free space only by macOS's `statfs`); moving files when the folder changes; downloading while the app is closed; a series' own quality rather than the commonest; on Apple platforms, Finder's free space (`volumeAvailableCapacityForImportantUsage`, counting purgeable space) in place of `f_bavail`.

Open:

* **Linux and Windows players:** UI toolkit and playback engine. Explored in other projects.

## Apple TV player

To come:

* **Lists as a grid,** if a row per list proves unwieldy: square tiles as Music's playlists, each a 2×2 mosaic of its first four covers, held to rename or delete, New List last; the focused tile may cycle its covers, stopping under Reduce Motion.
* **Movies:** an alphabetical jump, filters by decade and genre, and Home's recently added.
* **People:** tvOS profiles as people (`runs-as-current-user`), each a device of its own person, joining as Someone New by another member's device entering its code, as one profile's app is terminated while another's runs; they catch up through other devices. To check: whether the app group container is per profile, and whether the simulator switches profiles. Without profiles, see Who's watching under [Players](#players).
* **Icon:** real artwork for the placeholders (the Mac's too, and tvOS's layered assets and Top Shelf), from [draw-icons.swift](apple/draw-icons.swift).

## Someday

* **Libraries:** a hierarchy (library → kind → title → season → episode → version → part → quality) whose single-child levels the UI may skip; lists typed as watchlist, smart playlist, or transcode queue, any of them private, shared, or collaborative; several people on a shared player. Private data is masked from other people, not hardened: anyone with a player holding it may recover it.
* **Outside metadata** (plots, images, cast, ratings, IDs) is provided, never fetched: as JSON, or by a command given a title's identity (format to specify). Files map to outside titles by an ID tag, then an NFO's `<uniqueid>`, then the provider's guess, doubtful ones asked; titles with matching IDs merge. IDs replicate freely; provided data only among its person's devices, as its sources' terms may bind it.
* **Trust overlay:** a source is its metadata's canonical store, each library's edits an overlay it adopts or ignores per library; a transcoder likewise chooses whose queues it takes. Open: read-only members (children) by a per-library flag.
* **Transcoder:** a desktop device and source, making MP4s of what Apple's players can't play, lazily from transcode queues. Remux first with `ffmpeg` (copying streams that play, converting DTS, TrueHD, and image subtitles; `+faststart`); only video re-encodes and disc images go to `HandBrakeCLI`, by JSON jobs, a process each. Both run as separate processes, never linked, as GPL would bind the BSD core and App Store players. Input is copied from any source by resumable ranges to a cache; MP4 fixes in place (`hev1` to `hvc1`, index first) come from a separate project.
* **Other media:** a media-neutral core (identity, membership, sync, discovery, serving, crawling, private streams, lists, progress, covers, downloads), each kind a module of parser, hierarchy, metadata, and qualities: books (EPUB, PDF, CBZ; progress as a locator), audiobooks (M4B, MP3 folders), and music (FLAC, ALAC, AAC, MP3; play counts). Pairing and setup as a shared SwiftUI package, one pairing per device for every app (an app group and Keychain group); ordered collaborative playlists by a sequence CRDT (Fugue, in [specifications](docs/specifications/README.md)); the core as an XCFramework. Open: one app or library per kind or one for all; how progress generalizes across units.
