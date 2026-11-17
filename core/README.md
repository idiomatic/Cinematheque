# Core

Cinematheque's core, a Zig library: the replicated library and what peers need to fill and share it.

```sh
zig build test
```

It links the system's SQLite, and on Linux Avahi's `libdns_sd`. `zig build` also makes a static library, `libcinematheque.a`, with a C interface ([cinematheque.h](include/cinematheque.h), [capi.zig](src/capi.zig)) whose results are JSON, for apps in other languages; Swift imports it as `CCinematheque`, by its [module map](include/module.modulemap).

## Modules

| Module | What it does |
|---|---|
| [replica](src/replica.zig) | Operations in SQLite, signed in Merkle batches; membership, handover, and removal with repair; private streams; the sync frame protocol; thin fetches with shared proofs; the peer's own state (`local`) |
| [sync](src/sync.zig) | Sync over HTTP, gzipped: requests signed by the device and certified by its user, served only to members, without other users' private streams |
| [crawl](src/crawl.zig) | Listings, detected per repository (`INDEX`, Caddy's or nginx's JSON, HTML), and re-crawls that reuse unchanged directories |
| [naming](src/naming.zig) | The filename parser |
| [mp4](src/mp4.zig) | An MP4's cover (as a byte range) and metadata, read by range requests that walk atom headers |
| [art](src/art.zig) | Covers and metadata for movies and seasons, from sidecar images or MP4s; the browsing grid's tiles, with this user's progress; the watchlist |
| [library](src/library.zig) | Keys from titles' parsed identities; repositories, crawled into holdings; titles, a title's details, facets, close matches, duplicates, aliases, and playheads |
| [serve](src/serve.zig) | The repository server, with a hook for other requests, such as syncs |
| [discover](src/discover.zig) | DNS-SD: advertising and browsing peers |
| [store](src/store.zig) | A peer's home: its identity, its library's founder, and its replica |
| [capi](src/capi.zig) | The C interface: setup, management, long operations on their own connections, browsing, and private data |

## Keys

[library.zig](src/library.zig) documents them. A title's key derives from its parsed identity, `t/<kind>/<normalized title>/<year>`, so peers that crawl the same repository independently agree, and a renamed file that parses the same stays where it was. Below a title come episodes (`/e/s03e17`), versions (`/v/<edition>`), parts (`/p/<n>`), and renditions (`/r/<label>`), whose `held:<repository>` fields record where each file is.

A user's playheads (`p/<user>/<item>`) are private: each device writes them on a private stream of its own, with its own key and numbering, which peers send only to that user's devices, so other users' peers never hold them, nor claim to in their version vectors.

Titles whose keys nearly agree (a year off by one, missing, or with transposed digits; a title spelled slightly differently, or with other diacritics, but with the same numbers) are close matches for review, as are two files of one rendition in one repository. An alias records that one title is another, and replicates like anything else.

The measurements behind its design are in the [experiments](../experiments/README.md).
