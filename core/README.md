# Core

Cinematheque's core, a Zig library: the replicated library and what devices need to fill and share it.

```sh
zig build test
```

It links the system's SQLite and, on Linux, Avahi's `libdns_sd`. `zig build` also makes a static library, `libcinematheque.a`, with a C interface ([cinematheque.h](include/cinematheque.h), [capi.zig](src/capi.zig), documented in [include/README.md](include/README.md)) whose results are JSON, for apps in other languages. Swift imports it as `CCinematheque`, by its [module map](include/module.modulemap).

## Modules

| Module | What it does |
|---|---|
| [op](src/op.zig) | An operation: one write of one field, by one device, and its encoding |
| [hlc](src/hlc.zig) | The hybrid logical clock, packed into 64 bits |
| [merkle](src/merkle.zig) | Merkle trees over a batch of up to 1,024 operations, so one signature covers it and each operation is provable alone |
| [sqlite](src/sqlite.zig) | Minimal SQLite bindings |
| [replica](src/replica.zig) | Operations in SQLite, signed in Merkle batches; membership, handover, and removal; private streams; the device's own state (`local`); its tests in [replica_tests.zig](src/replica_tests.zig) |
| [frames](src/frames.zig) | The sync frame protocol: version vectors, and a sync's operations by batch, written and checked (re-exported by replica) |
| [repair](src/repair.zig) | Repair: fetching the fields a removal dropped, with shared proofs (re-exported by replica) |
| [sync](src/sync.zig) | Sync over HTTP, gzipped: requests signed by the device and certified by its person, served only to members, without other people's private streams |
| [seal](src/seal.zig) | Sealing a sync's bodies so only the two devices read them: a key pair for the request alone, ChaCha20-Poly1305 in numbered chunks |
| [deadline](src/deadline.zig) | Deadlines for what waits on another host, as `Io`'s reads have none |
| [crawl](src/crawl.zig) | Listings, detected per source (`INDEX`, Caddy's or nginx's JSON, HTML), and re-crawls that reuse unchanged directories |
| [naming](src/naming.zig) | The filename parser |
| [mp4](src/mp4.zig) | An MP4's cover (as a byte range) and metadata, read by range requests that walk atom headers |
| [jpeg](src/jpeg.zig) | A JPEG's DC coefficients alone: an eighth-size image, for placeholders |
| [thumbhash](src/thumbhash.zig) | ThumbHash placeholders, encoded and rendered; a port of the MIT-licensed reference |
| [art](src/art.zig) | Covers and metadata for movies and seasons, from sidecar images or MP4s, planned across sources and described by concurrent workers, prioritized titles first; the browsing grid's tiles, with this person's progress and whether begun |
| [library](src/library.zig) | Keys from titles' parsed identities; sources, crawled into copies; titles, a title's details, facets, close matches, duplicates, aliases, and progress |
| [lists](src/lists.zig) | A person's lists (a Watchlist, Favorites), placeholders for titles not in the library yet, and lists shared with every member |
| [order](src/order.zig) | The orders shelves sort in, each tile's place in each |
| [views](src/views.zig) | What players show, as JSON: the grid's tiles and a title's detail, for the C interface and the web client alike |
| [json](src/json.zig) | JSON with every string valid UTF-8 |
| [url](src/url.zig) | Percent-encoding of path segments |
| [serve](src/serve.zig) | The source server, with a hook for other requests, such as syncs |
| [download](src/download.zig) | Downloads: a title's, season's, or item's files, raced among their copies, resumed, into a directory under their sources' paths; a player's downloads kept as a managed source (what's wanted by hand, kept until deleted, and series' next episodes, the watched ones deleted as space is needed once held elsewhere), reconciled, with 20 GB kept free |
| [race](src/race.zig) | Copy racing: an item's copies in the order to try them, each one's server asked at once, briefly, over `Io`'s networking, and those lately unanswered last |
| [host](src/host.zig) | A server on a task of its own, advertised by DNS-SD once it listens, and reliably stopped: the apps' serving and pairing, and the command-line app's |
| [discover](src/discover.zig) | DNS-SD: advertising and browsing devices |
| [store](src/store.zig) | A device's data directory: its identity, its library's founder, and its replica |
| [pair](src/pair.zig) | Pairing a new device by a 6-digit code it shows: CPace over the code, then the person's secret and the library's founder sealed with the key it derives |
| [capi](src/capi.zig) | The C interface: the library's handle, errors, and JSON results, its parts in [capi/](src/capi) (serving, identity and membership, pairing, names and devices, sources, downloads, long operations on their own connections, browsing, and private data), each imported so its exports are kept |
| [version](src/version.zig) | What the build is (its version, from [Version.xcconfig](../Version.xcconfig); `git describe --tags`; its optimizing; its Zig), served at `/version`; stamped by [stamp.zig](stamp.zig), a tool every build runs, as Zig caches its build scripts' configuring |

## Keys and operations

[ARCHITECTURE.md](../ARCHITECTURE.md) explains how the replica writes, signs, merges, and syncs operations, lists every key and field the library writes, and gives the [measurements](../ARCHITECTURE.md#measurements) behind its design. [library.zig](src/library.zig) documents its keys beside the code that derives them from titles' parsed identities.
