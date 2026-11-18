# Core

Cinematheque's core, a Zig library: the replicated library and what peers need to fill and share it.

```sh
zig build test
```

It links the system's SQLite, and on Linux Avahi's `libdns_sd`. `zig build` also makes a static library, `libcinematheque.a`, with a C interface ([cinematheque.h](include/cinematheque.h), [capi.zig](src/capi.zig)) whose results are JSON, for apps in other languages; Swift imports it as `CCinematheque`, by its [module map](include/module.modulemap).

## Modules

| Module | What it does |
|---|---|
| [replica](src/replica.zig) | Operations in SQLite, signed in Merkle batches; membership, handover, and removal with repair; private streams; the sync frame protocol; repair's fetches with shared proofs; the peer's own state (`local`) |
| [sync](src/sync.zig) | Sync over HTTP, gzipped: requests signed by the device and certified by its user, served only to members, without other users' private streams |
| [crawl](src/crawl.zig) | Listings, detected per repository (`INDEX`, Caddy's or nginx's JSON, HTML), and re-crawls that reuse unchanged directories |
| [naming](src/naming.zig) | The filename parser |
| [mp4](src/mp4.zig) | An MP4's cover (as a byte range) and metadata, read by range requests that walk atom headers |
| [jpeg](src/jpeg.zig) | A JPEG's DC coefficients alone: an eighth-size image, for placeholders |
| [thumbhash](src/thumbhash.zig) | ThumbHash placeholders, encoded and rendered; a port of the MIT-licensed reference |
| [art](src/art.zig) | Covers and metadata for movies and seasons, from sidecar images or MP4s, planned across repositories and described by concurrent workers, prioritized titles first; the browsing grid's tiles, with this user's progress and whether begun; the watchlist |
| [library](src/library.zig) | Keys from titles' parsed identities; repositories, crawled into holdings; titles, a title's details, facets, close matches, duplicates, aliases, and playheads |
| [serve](src/serve.zig) | The repository server, with a hook for other requests, such as syncs |
| [discover](src/discover.zig) | DNS-SD: advertising and browsing peers |
| [store](src/store.zig) | A peer's home: its identity, its library's founder, and its replica |
| [pair](src/pair.zig) | Pairing a new device by a 6-digit code it shows: CPace over the code, then the user's secret and the library's founder sealed with the key it derives |
| [capi](src/capi.zig) | The C interface: setup, management, long operations on their own connections, browsing, and private data |

## Keys and operations

[ARCHITECTURE.md](../ARCHITECTURE.md) explains how the replica writes, signs, merges, and syncs operations, and lists every key and field the library writes; [library.zig](src/library.zig) documents its keys beside the code that derives them from titles' parsed identities.

The measurements behind its design are in the [experiments](../experiments/README.md).
