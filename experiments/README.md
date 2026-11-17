# Experiments

The prototypes the [core](../core/README.md) grew from, and their measurements, kept for reference. Each has its own README with its method and results; figures below are from an Apple M2 unless noted.

| Experiment | What it measured | Headline |
|---|---|---|
| [crdt](crdt/README.md) | The replica: signed operations in SQLite, sync, membership, thin fetches | 409,500 operations (100,000 renditions): 1.1 s to build, 1.1 s to sync cold, in memory or over HTTP, 24.5 MB on the wire (4.0 MB with Zig's gzip, 2.4 MB with zstd), 56 MB on disk; one series fetched thin in 3 ms and 51 KB. Signing each operation instead of each batch took 17 s, and verifying 21 s. |
| [repository](repository/README.md) | Crawling listings, the repository server, re-crawls | 100,000 files: one `INDEX` request, 8 ms; JSON or HTML from Cinematheque's server, 8,503 requests, 0.2 s; rclone 1.5 s; Python 3.3 s (and no byte ranges); Apache 9–18 s. At a 4 ms round trip, 31 s with one worker, 0.9 s with 32. An unchanged re-crawl took 503 requests instead of 8,503, and every one of 800 changes was found. A real Caddy NAS over Wi-Fi: 20,000 files in 0.24 s with 32 workers. |
| [naming](naming/README.md) | The filename parser | 100,000 paths in 80 ms; on a real library of 40,000 videos, 77 left for review once compact episode codes were read. |
| [transcoder](transcoder/README.md) | Remux-first transcoding over HTTP | 60-second remuxes in 0.1–0.4 s, converting DTS and SubRip; an MPEG-2 re-encode in 8.5 s; AVFoundation plays every output, but not MKV, nor HEVC tagged `hev1`. |
| [discovery](discovery/README.md) | DNS-SD from Zig | Bonjour on macOS and Avahi on Linux, which found each other. |
| [browse](browse/README.md) | Facet intersections | A four-facet query and its refinement menu over 4,500 titles: 13 ms in SQLite, 43 µs with 105 KB of bitmaps. |
