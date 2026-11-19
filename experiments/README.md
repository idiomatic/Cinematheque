# Experiments

The prototypes the [core](../core/README.md) grew from, and their measurements, kept for reference; figures are from an Apple M2 unless noted. Two keep their code, since their work isn't built yet: [browse](browse/README.md) and [transcoder](transcoder/README.md), each with a README of its own. The other four grew into the core, and their code was removed after commit `92243e1`; this file keeps their methods, results, and findings, and `git checkout 92243e1 -- experiments/<name>` restores one to rerun it.

| Experiment | What it measured | Headline |
|---|---|---|
| [CRDT](#crdt) | The replica: signed operations in SQLite, sync, membership, thin fetches | 409,500 operations (100,000 renditions): 1.1 s to build, 1.1 s to sync cold, in memory or over HTTP, 24.5 MB on the wire (4.0 MB with Zig's gzip, 2.4 MB with zstd), 56 MB on disk; one series fetched thin in 3 ms and 51 KB. Signing each operation instead of each batch took 17 s, and verifying 21 s. |
| [Repository](#repository) | Crawling listings, the repository server, re-crawls | 100,000 files: one `INDEX` request, 8 ms; JSON or HTML from Cinematheque's server, 8,503 requests, 0.2 s; rclone 1.5 s; Python 3.3 s (and no byte ranges); Apache 9–18 s. At a 4 ms round trip, 31 s with one worker, 0.9 s with 32. An unchanged re-crawl took 503 requests instead of 8,503, and every one of 800 changes was found. A real Caddy NAS over Wi-Fi: 20,000 files in 0.24 s with 32 workers. |
| [Naming](#naming) | The filename parser | 100,000 paths in 80 ms; on a real library of tens of thousands of videos, under 0.2% left for review once compact episode codes were read. |
| [Discovery](#discovery) | DNS-SD from Zig | Bonjour on macOS and Avahi on Linux, which found each other. |
| [browse](browse/README.md) | Facet intersections | A four-facet query and its refinement menu over 4,500 titles: 13 ms in SQLite, 43 µs with 105 KB of bitmaps. |
| [transcoder](transcoder/README.md) | Remux-first transcoding over HTTP | 60-second remuxes in 0.1–0.4 s, converting DTS and SubRip; an MPEG-2 re-encode in 8.5 s; AVFoundation plays every output, but not MKV, nor HEVC tagged `hev1`. |

## CRDT

Grew into the core's [replica](../core/src/replica.zig) and [sync](../core/src/sync.zig); [ARCHITECTURE.md](../ARCHITECTURE.md) explains the design it tested: last-writer-wins operations and causal-length sets in SQLite, signed in batches by devices that users certify, admitted by membership (with handovers and removals), caught up by version vectors in memory or over HTTP, and fetched by title into a thin replica.

The library was 4,000 movies and 500 series of 8 seasons of 24 episodes: 100,000 renditions, each with a path, a resolution, and a holding, for 409,500 operations. The divergence step had each peer rename about 0.5% as many episodes, 100 of them the same ones. ReleaseFast, Zig 0.17.1, peers in one process; transfer sizes count what a network would carry.

| Step | Time | Operations | Transfer | Database |
|---|---|---|---|---|
| Build on laptop (sign) | 1.1 s | 409,500 | | 55 MB |
| Cold sync (verify) | 1.1 s | 409,502 | 24.5 MB (2.4 MB with zstd), 402 batches | 56 MB |
| Cold sync over HTTP, loopback | 1.1 s | 409,502 | 24.5 MB | 56 MB |
| 1% divergence, both ways | 0.12 s | 4,045 | 256 KB | |
| Thin fetch: one movie, with certificates and members | 1 ms | 9 | 1.8 KB | |
| Thin fetch: one series | 3 ms | 771 | 51 KB | 0.1 MB |

On Linux (Alpine 3.24, aarch64, in a 4-CPU VM, databases on tmpfs), cross-compiled from macOS against Alpine's SQLite, the numbers matched: 0.9 s to build, 1.1 s to sync cold, 0.87 s over HTTP. Both peers converged, and the replica synced over HTTP matched its source. Its tests, now the core's, cover conflicts, relays through a third peer, batch limits, tampering, concurrent set changes, thin fetches, and membership: admission, invitations later in a response, removal and repair, and handovers, forged or out of order.

* **The design works at scale:** catch-up costs what's missing, not the library's size, and a thin replica verifies a title on its own, with no history.
* **Sign batches, not operations.** The first version signed each operation: 17 s to build, 21 s to sync cold, 150 MB on disk. Signing per batch made both over 10 times faster (now bound by SQLite) and storage 2.7 times smaller. On their own (409,500 operations of 110 bytes):

  | Scheme | Sign | Verify |
  |---|---|---|
  | One signature per operation | 37.5 µs/op | 46.3 µs/op |
  | The same, verified in batches of 64 (`Ed25519.verifyBatch`) | 37.5 µs/op | 22.0 µs/op |
  | One signature per 1,024 operations, over a Merkle tree | 0.34 µs/op | 0.35 µs/op |

* **Batches follow writes:** a batch is whatever a device writes in one transaction, so an import signs once per 1,024 operations, while a single edit signs alone, which is cheap at human pace.
* **Compress with Zig's own gzip:** its fastest level shrinks a cold sync from 24.5 MB to 4.0 MB in 0.14 s, and its default to 3.3 MB in 0.48 s. The `zstd` tool's fastest level makes 2.3 MB in 0.06 s, but Zig's standard library only decompresses zstd, so a sender would need the C library; gzip needs nothing.
* **Send operations, not their hashes:** sending every batch's leaves made a cold sync 37.5 MB, of which 13 MB were hashes that only compress to themselves (15 MB with zstd). Since the receiver can rebuild the leaves of the operations it gets, sending only superseded operations' leaves cut it to 24.5 MB, and 2.4 MB with zstd at its fastest.
* **Shared proofs pay:** with a proof per operation, a series took 296 KB, mostly 10 hashes per operation; one shared proof per batch cut it to 51 KB, since a title's operations were written together and their proofs overlap.
* **Membership costs one certificate check per batch,** too little to measure.
* **Removal needs no history, but can lose a write:** repair restores what a peer that refused the later writes holds, so a write that only the repairing peer held, and that lost to a refused write, is gone.
* **Since tested:** syncs over real networks (Macs and an Apple TV, over Wi-Fi), gzipped. **Not yet tested:** concurrent removals of the same member with different cutoffs.

## Repository

Grew into the core's [crawl](../core/src/crawl.zig), [serve](../core/src/serve.zig), and [url](../core/src/url.zig), and the peer's test repository generator, [gen.zig](../cli/test/gen.zig). It tested how peers learn a repository's contents (**Listings**, **Crawls**, and **Serving** in [AGENTS.md](../AGENTS.md)): a repository server on Zig's `std.http.Server`, and a breadth-first crawler of concurrent workers on `std.http.Client`, run against it and against static servers (rclone, Python, and Apache, whose `mod_autoindex` it configured) holding the same tree. The tree was 4,000 movies and 500 series of 8 seasons of 24 episodes, of sparse files: 100,000 files in 8,502 directories, some names needing escaping or running past 50 bytes. A mutation step renamed 500 episodes, moved 100 movie folders, deleted 100 episodes, and added 100 files, logging the truth, and a diff of two crawls matched vanished files to new ones by size and modification time, breaking ties by the longest shared name suffix.

macOS 27.2, ReleaseFast, everything on one machine over loopback, 8 workers unless noted:

| Server | Listing | Time | Requests | Listing bytes | Sizes? | Range probe |
|---|---|---|---|---|---|---|
| This server | `INDEX` | 8 ms | 1 | 9.1 MB (1.1 MB gzipped) | yes | 206 |
| This server | JSON | 0.22 s | 8,503 | 18.4 MB | yes | 206 |
| This server | HTML | 0.21 s | 8,503 | 12.3 MB | no | 206 |
| rclone 1.76 `serve http` | HTML | 1.5 s | 8,503 | 156 MB | no | 206 |
| Python 3.15 `http.server` | HTML | 3.3 s | 8,503 | 14.1 MB | no | **200** (no ranges) |
| Apache 2.4.67 `mod_autoindex` | HTML | 15.8 s (8.7 s with 32 workers; 18 s with 1) | 8,503 | 30.3 MB | no | 206 |

Building the `INDEX` (walking and statting the tree) took 0.34 s. Re-crawls by JSON against this server, 8 workers:

| Re-crawl | Requests | Listing bytes | Time |
|---|---|---|---|
| Full | 8,503 | 18.4 MB | 0.36 s |
| Incremental, nothing changed | 503 (8,000 directories reused) | 1.0 MB | 48 ms |
| Incremental, after 800 changes | 1,254 (7,250 reused) | 3.7 MB | 75 ms |

Across a network, with the server on Linux (Alpine 3.24 in a VM, cross-compiled from macOS) and the crawler on the Mac, 8 workers unless noted:

| Round trip | `INDEX` | JSON, 1 worker | JSON, 8 workers | JSON, 32 workers | Incremental, unchanged |
|---|---|---|---|---|---|
| 0.6 ms (virtual network) | 23 ms | | 0.20 s | 0.13 s | |
| 4 ms (2.5 ms added each way, like Wi-Fi) | 54 ms | 31 s | 4.3 s | 0.94 s | 1.8 s (503 requests) |

The incremental snapshot after the changes was identical to a full crawl's. Diffing it against the first took 26 ms and found all 800 true changes: 600 moves (500 renames and the files of 100 moved folders), 100 deletions, and 100 additions, none ambiguous. With one worker, this server's JSON crawl took 0.74 s, and with 4, 0.23 s.

A real repository: a Caddy server on a NAS, over Wi-Fi (about 5 ms round trip), crawled by JSON, read-only, with a folder per rendition: tens of thousands of videos in several hundred directories.

| Crawl | Requests | Time |
|---|---|---|
| One rendition of TV, about 20,000 files, 1 worker | 424 | 2.6 s |
| The same, 8 workers | 424 | 0.43 s |
| The same, 32 workers | 424 | 0.24 s |
| The same, incremental, unchanged | 2 (422 directories reused) | 46 ms |

Every range probe answered 206. Caddy's JSON gives sizes and modification times to the nanosecond, ends directories' names with a slash (the crawler first mis-encoded it), and paginates only on request. The repository keeps housekeeping folders and files whose names start with a comma, which crawls should skip. Fewer than 0.05% of files shared an exact size with another.

* **`INDEX` wins by orders of magnitude:** one request, sizes and times included, and an unchanged library costs one 304. Gzipped, it's 11 bytes per file. Repositories that run Cinematheque code should always publish one.
* **Static servers vary 70-fold** on the same tree. Apache's fancy index spends 0.64 s on one 4,000-entry directory, so on a consumer NAS a full crawl could take minutes. Re-crawls that reuse unchanged leaf directories cut requests 17-fold here, but need listings with times: JSON, or the minute-precision dates Apache and nginx print beside each link, which the crawler doesn't yet read.
* **Apache's `TrackModified` sends `ETag` and `Last-Modified` on listings but still answers 200** to `If-None-Match` and `If-Modified-Since`, so conditional requests save nothing there; only modification times in parent listings help.
* **Python's `http.server` can't serve ranges**, so the probe matters: such a repository can't stream to Apple players, only be copied from.
* **HTML parsing needs care:** rclone links to `..` and to `?download=zip` variants of each folder; Apache escapes `&` as `&amp;` in links and adds sort links; links are relative with or without `./`. Reading only link targets handled all four servers.
* **Zig's HTTP client doesn't retry** a pooled connection the server has closed (`HttpConnectionClosing`), so the crawler must.
* **Size and modification time identify moved files:** a rename or move keeps both, and video files' exact sizes rarely collide, so no file needed hashing; the suffix tie-break covers copies. Listings without times (Python's, or HTML read for links only) allow neither the skip nor the match, so they must re-crawl fully and fall back to names.
* **Latency dominates listing crawls:** at a Wi-Fi-like 4 ms round trip, one worker took 31 s and 32 took under a second, so crawlers need many concurrent requests (as many as a weak NAS tolerates), and an `INDEX` stays one request either way.
* **Layouts are per repository:** here the rendition is the folder under the area, there it may be a file suffix or absent, and housekeeping names follow local conventions, so a repository's settings say where renditions sit and what to skip.
* **Since tested:** Caddy, on the NAS above. **Not yet tested:** other NAS hardware, nginx, WebDAV, files rewritten in place, and changes within the same second as a crawl (listings give times to the second).

## Naming

Grew into the core's [naming](../core/src/naming.zig) and its [tests](../core/src/naming_tests.zig): a parser, of hand-written scanners rather than regular expressions, that turns a repository path into what a search for its title needs, following the Plex, Jellyfin, and Kodi naming guides and common scene names (see [docs/specifications](../docs/specifications/README.md)). It read ID tags (`{tmdb-…}`, Jellyfin's `[imdbid-…]`), episodes (`S01E02`, ranges, `1x02`, a bare `E02` in a season folder, air dates), movies' titles and years (from the folder when it has a year; only the last year ends a title, and a leading number stays in it), versions, parts, extras, and scene names (dots and underscores as spaces but in acronyms, ending at the first scene token), against 39 fixtures from the guides and scene names.

* All 39 fixtures passed.
* Over the repository experiment's 100,000 paths: 80 ms (0.8 µs a path), finding 4,000 distinct movies and 96,000 episodes of 500 series, every one with a year.
* The first run merged 118 movies whose titles held a year-like number ("Movie 1950 (1950)" became "Movie"); taking only the last year fixed it.

A real library: the videos on the repository experiment's NAS, movies named `Title (Year)[ - Edition].m4v` and episodes `Show/Show 317 Episode Title.m4v`, under a folder per rendition.

* The first run took nearly every episode for a movie: these episodes use Kodi's compact episode code (`317` for season 3, episode 17; `1213` for 12 and 13), which the parser didn't read. It now reads one right after the series' title from the enclosing folder, compared on letters and digits only, past punctuation and a repeated year ("Show (2020) 101"), even when it looks like a year ("South Park 1908" is season 19); a folder note like "(from DVD)" no longer cuts the title short.
* After that, under 0.2% of files didn't parse: specials with no code or with code `100` or `300`, camera files named only by number, and episodes filed in another series' folder, which the title mismatch exposed.
* Every movie parsed with a year, a few percent with editions; more than half the titles, and of the episodes, were in two or more renditions.
* 0.6 µs a path, as before.

Findings:

* **Parsing is cheap and local:** the whole library parses in a tenth of a second, so it can run on every crawl, on any peer; outside lookups are the cost.
* **Folders carry the best evidence:** Plex-style folders give the title and year, and season folders give seasons and series even when files are badly named.
* **Real libraries have house styles** the guides don't cover, and context (the enclosing folder) resolves most of them; what remains is few enough for the user to review, and it surfaces misfiled files.
* **Numbers are the hard part:** years inside titles, leading numbers, and episode-like tokens need ordered rules and fixtures; MIT-licensed parse-torrent-title's test corpus would broaden these.
* **Since tested:** a real library (above). **Not yet tested:** anime numbering (absolute episodes), multi-language titles, and searching TMDB with the results.

## Discovery

Grew into the core's [discover](../core/src/discover.zig): advertising and finding peers on the LAN through the system's own DNS-SD service, from Zig, with no dependencies (**Discovery** in [AGENTS.md](../AGENTS.md)). It declared the half-dozen `dns_sd.h` functions it needed (`DNSServiceRegister`, `DNSServiceBrowse`, `DNSServiceResolve`, and the socket and dispatch calls), registered a service as `_cinematheque._tcp` with a TXT record, browsed it and `_http._tcp` and `_webdav._tcp`, and resolved each Cinematheque service found. On macOS the functions are in libSystem; on Linux, Avahi's compatibility library (`libdns_sd`) provides them. Windows has a different API (`DnsServiceRegister` and `DnsServiceBrowse` in `windns.h`).

On macOS 27.2, the service registered, was found on both loopback and Wi-Fi, and resolved to the host's `.local` name, its port, and the TXT record intact; no `_http._tcp` or `_webdav._tcp` services were on that network. On Linux (Alpine 3.24 in a VM, with `avahi-daemon` and Avahi's `libdns_sd`), the same code, cross-compiled from macOS, registered, browsed, and resolved alike, and the Mac's `dns-sd -L` found the VM's service across the virtual network, TXT record and all. Avahi prints a warning to use its native API instead of the compatibility library.

* **The system service is enough:** about 120 lines of Zig, no library, and no fight over the multicast port with the system's own responder.
* **TXT records must be exact:** each string is length-prefixed, and one wrong length made registration fail with no detail, so build them in code, not by hand.
* **A service appears once per interface,** so peers should deduplicate by name before resolving.
* **Bonjour and Avahi interoperate,** so a Linux peer is found from a Mac and the reverse; Avahi's warning suggests binding its native API on Linux eventually.
* **Since tested:** tvOS, in the simulator and on an Apple TV. **Not yet tested:** Windows, iOS, and finding a NAS's own web server.
