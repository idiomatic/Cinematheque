# Repository experiment

> This experiment grew into the core's [crawl](../../core/src/crawl.zig), [serve](../../core/src/serve.zig), and [url](../../core/src/url.zig), and the peer's test repository generator, [gen.zig](../../peer/test/gen.zig). Its code was removed after commit `92243e1`; `git checkout 92243e1 -- experiments/repository` restores it, to rerun the measurements below.

Tests how peers learn a repository's contents, per what are now **Listings**, **Crawls**, and **Serving** in [AGENTS.md](../../AGENTS.md): a repository server on Zig's `std.http.Server`, and a crawler on `std.http.Client`, run against it and against static servers holding the same 100,000 files.

## Running

```sh
zig build test
zig build --release=fast
./zig-out/bin/repo gen /tmp/cinematheque-media          # sparse files, no disk space
./zig-out/bin/repo serve /tmp/cinematheque-media 8090
./zig-out/bin/repo crawl http://127.0.0.1:8090/ index|json|html [workers]
./zig-out/bin/repo recrawl http://127.0.0.1:8090/ - snap0.tsv               # full, saved
./zig-out/bin/repo mutate /tmp/cinematheque-media truth.tsv                 # change the tree
./zig-out/bin/repo recrawl http://127.0.0.1:8090/ snap0.tsv snap1.tsv      # incremental
./zig-out/bin/repo changes http://127.0.0.1:8090/ snap0.tsv snap1.tsv truth.tsv
```

`apache.conf` serves the same tree with Apache's `mod_autoindex`: `httpd -f "$PWD/apache.conf" -C "Define ROOT /tmp/cinematheque-media" -k start`.

## Design

* [src/gen.zig](../../peer/test/gen.zig): 4,000 movies (`Movies/Title (Year)/Title (Year).mkv`) and 500 series of 8 seasons of 24 episodes (`TV/Series (Year)/Season 01/Series - S01E01 - Episode 1.mkv`), with some names needing escaping or running past 50 bytes; 100,000 files in 8,502 directories.
* `src/server.zig`: files with single byte ranges, `If-Range`, and `mtime-size` ETags; listings as JSON in Caddy's form (on `Accept: application/json`) or HTML; and an `INDEX` of `path<TAB>size<TAB>mtime` lines with an ETag, answering a matching `If-None-Match` with 304.
* [src/gen.zig](../../peer/test/gen.zig) `mutate`: renames 500 episodes in place, moves 100 movie folders into `Movies/Collection`, deletes 100 episodes, and adds 100 files, logging the truth.
* `src/changes.zig`: diffs two crawls, matching vanished files to new ones by size and modification time (which a rename keeps), breaking ties by the longest shared name suffix.
* `src/crawl.zig`: can save a crawl as a snapshot and, given one, reuse the listing of any directory whose modification time (from its parent's listing) is unchanged and that held only files. breadth-first, a level at a time, split among concurrent workers sharing the client's keep-alive connections; reads JSON, HTML (links' targets only, skipping sort, download, and parent links, and undoing entities like Apache's `&amp;`), or `INDEX`; retries requests whose pooled connection the server closed; then probes one file with `Range: bytes=0-0`.

## Results

Apple M2, macOS 27.2, ReleaseFast, everything on one machine over loopback, 8 workers unless noted:

| Server | Listing | Time | Requests | Listing bytes | Sizes? | Range probe |
|---|---|---|---|---|---|---|
| This server | `INDEX` | 8 ms | 1 | 9.1 MB (1.1 MB gzipped) | yes | 206 |
| This server | JSON | 0.22 s | 8,503 | 18.4 MB | yes | 206 |
| This server | HTML | 0.21 s | 8,503 | 12.3 MB | no | 206 |
| rclone 1.76 `serve http` | HTML | 1.5 s | 8,503 | 156 MB | no | 206 |
| Python 3.15 `http.server` | HTML | 3.3 s | 8,503 | 14.1 MB | no | **200** (no ranges) |
| Apache 2.4.67 `mod_autoindex` | HTML | 15.8 s (8.7 s with 32 workers; 18 s with 1) | 8,503 | 30.3 MB | no | 206 |

Building the `INDEX` (walking and statting the tree) took 0.34 s.

Re-crawls by JSON against this server, 8 workers:

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

### A real repository

A Caddy server on a NAS, over Wi-Fi (about 5 ms round trip), crawled by JSON, read-only. Its layout puts the rendition (a HandBrake preset's name) directly under `Movies` and `TV Shows`, and only four renditions were crawled: 40,000 videos, tens of TB, in 790 directories.

| Crawl | Requests | Time |
|---|---|---|
| One rendition of TV, 20,000 files, 1 worker | 424 | 2.6 s |
| The same, 8 workers | 424 | 0.43 s |
| The same, 32 workers | 424 | 0.24 s |
| The same, incremental, unchanged | 2 (422 directories reused) | 46 ms |

Every range probe answered 206. Caddy's JSON gives sizes and modification times to the nanosecond, ends directories' names with a slash (the crawler first mis-encoded it), and paginates only on request. The repository keeps housekeeping folders and files whose names start with a comma, which crawls should skip. 18 of 40,000 files shared an exact size with another.

## Findings

* **`INDEX` wins by orders of magnitude:** one request, sizes and times included, and an unchanged library costs one 304. Gzipped, it's 11 bytes per file. Repositories that run Cinematheque code should always publish one.
* **Static servers vary 70-fold** on the same tree. Apache's fancy index spends 0.64 s on one 4,000-entry directory, so on a consumer NAS a full crawl could take minutes. Re-crawls that reuse unchanged leaf directories cut requests 17-fold here, but need listings with times: JSON, or the minute-precision dates Apache and nginx print beside each link, which this crawler doesn't yet read.
* **Apache's `TrackModified` sends `ETag` and `Last-Modified` on listings but still answers 200** to `If-None-Match` and `If-Modified-Since`, so conditional requests save nothing there; only modification times in parent listings help.
* **Python's `http.server` can't serve ranges**, so the probe matters: such a repository can't stream to Apple players, only be copied from.
* **HTML parsing needs care:** rclone links to `..` and to `?download=zip` variants of each folder; Apache escapes `&` as `&amp;` in links and adds sort links; links are relative with or without `./`. Reading only link targets handled all four servers.
* **Zig's HTTP client doesn't retry** a pooled connection the server has closed (`HttpConnectionClosing`), so the crawler must.
* **Size and modification time identify moved files:** a rename or move keeps both, and video files' exact sizes rarely collide, so no file needed hashing; the suffix tie-break covers copies. Listings without times (Python's, or HTML read for links only, as here) allow neither the skip nor the match, so they must re-crawl fully and fall back to names.
* **Latency dominates listing crawls:** at a Wi-Fi-like 4 ms round trip, one worker took 31 s and 32 took under a second, so crawlers need many concurrent requests (as many as a weak NAS tolerates), and an `INDEX` stays one request either way.
* **Layouts are per repository:** here the rendition is the folder under the area, there it may be a file suffix or absent, and housekeeping names follow local conventions, so a repository's settings say where renditions sit and what to skip.
* **Not yet tested:** other NAS hardware, nginx and Caddy (not installed here), WebDAV, files rewritten in place, and changes within the same second as a crawl (listings give times to the second).
