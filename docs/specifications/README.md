# Specifications

External specifications and papers Cinematheque relies on. They're linked rather than collected, since their licenses don't clearly permit redistribution.

## Sync

| Title | Source | Why it applies |
|---|---|---|
| Logical Physical Clocks and Consistent Snapshots in Globally Distributed Databases (Kulkarni et al.) | https://cse.buffalo.edu/tech-reports/2014-04.pdf | Hybrid logical clocks timestamp last-writer-wins fields close to wall time. |
| A Comprehensive Study of Convergent and Commutative Replicated Data Types (Shapiro et al.) | https://inria.hal.science/inria-00555588 | Defines the registers and sets the replicated data uses. |
| Delta State Replicated Data Types (Almeida, Shoker, Baquero) | https://arxiv.org/abs/1603.01529 | Shipping winning operations is a delta-state design. |
| Conflict-Free Replicated Relations, causal-length sets (Yu, Rostad) | https://dl.acm.org/doi/10.1145/3380787.3393678 | Delete and re-add of set elements, such as list entries, with one integer per element. |
| Making CRDTs Byzantine Fault Tolerant (Kleppmann) | https://martin.kleppmann.com/papers/bft-crdt-papoc22.pdf | Signed, hash-identified operations converge despite untrusted peers. |
| Byzantine Eventual Consistency and the Fundamental Limits of Peer-to-Peer Databases (Kleppmann, Howard) | https://arxiv.org/abs/2012.00472 | Sync protocol for signed operations. |
| Range-Based Set Reconciliation (Meyer) | https://arxiv.org/abs/2212.13567 | Repair sync when version vectors aren't enough. |
| Negentropy | https://github.com/hoytech/negentropy | Protocol and test vectors for range-based set reconciliation. |
| Partial Replication of CRDTs (Briot, Urso, Shapiro) | https://hal.science/hal-01287738 | Partial replicas for thin tvOS players. |
| The Art of the Fugue (Weidner, Kleppmann) | https://arxiv.org/abs/2305.00583 | Ordering collaborative lists without interleaving. |
| A Highly-Available Move Operation for Replicated Trees (Kleppmann et al.) | https://martin.kleppmann.com/papers/move-op.pdf | Moving titles within the hierarchy without cycles. |
| cr-sqlite | https://github.com/vlcn-io/cr-sqlite | Clock-table storage of CRDT state in SQLite, borrowed as a design. |
| Corrosion | https://github.com/superfly/corrosion | Gap-free per-device sequences for catch-up. |
| Keyhive | https://www.inkandswitch.com/project/keyhive/ | Prior art on access control as a CRDT. |
| p2panda | https://p2panda.org | Prior art on signed per-author logs. |

## Repositories

| Title | Source | Why it applies |
|---|---|---|
| RFC 9110, HTTP Semantics | https://www.rfc-editor.org/rfc/rfc9110 | Range requests, `If-Range`, ETags, and conditional requests. |
| RFC 4918, WebDAV | https://www.rfc-editor.org/rfc/rfc4918 | `PROPFIND` listings of a whole tree. |
| RFC 6762, Multicast DNS | https://www.rfc-editor.org/rfc/rfc6762 | LAN discovery. |
| RFC 6763, DNS-Based Service Discovery | https://www.rfc-editor.org/rfc/rfc6763 | Advertising and browsing `_cinematheque._tcp`. |
| nginx `ngx_http_autoindex_module` | https://nginx.org/en/docs/http/ngx_http_autoindex_module.html | HTML, JSON, and XML listings. |
| Caddy `file_server` | https://caddyserver.com/docs/caddyfile/directives/file_server | Browse listings, as JSON on request. |
| Apache `mod_autoindex` | https://httpd.apache.org/docs/2.4/mod/mod_autoindex.html | HTML listings and their options. |

## Naming

| Title | Source | Why it applies |
|---|---|---|
| Plex: naming and organizing movie files | https://support.plex.tv/articles/naming-and-organizing-your-movie-media-files/ | Naming conventions the parser reads. |
| Jellyfin: movies | https://jellyfin.org/docs/general/server/media/movies/ | Naming conventions, versions, and extras. |
| Kodi: naming episodes | https://kodi.wiki/view/Naming_video_files/Episodes | Episode naming conventions. |
| parse-torrent-title (MIT) | https://github.com/TheBeastLT/parse-torrent-title | Model and test fixtures for the filename parser. |

## Cover art

| Title | Source | Why it applies |
|---|---|---|
| ITU-T T.81, JPEG | https://www.w3.org/Graphics/JPEG/itu-t81.pdf | Huffman-coded sequential and progressive scans, whose DC coefficients the core decodes for placeholders. |
| ThumbHash (MIT) | https://github.com/evanw/thumbhash | The placeholder format, and the reference implementation the core's port reproduces. |
| QuickTime File Format: metadata | https://developer.apple.com/documentation/quicktime-file-format | Atom layout, and the `ilst` items (`covr`, `©nam`, `ldes`) MP4 covers and metadata come from. |

## Transcoding

| Title | Source | Why it applies |
|---|---|---|
| HLS authoring specification for Apple devices | https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices | Codecs and tags Apple players accept, such as `hvc1`. |
| HandBrake command-line guide | https://handbrake.fr/docs/en/latest/cli/command-line-reference.html | `HandBrakeCLI`'s presets, JSON jobs (`--queue-import-file`), and JSON progress (`--json`). |
| FFmpeg license and legal considerations | https://ffmpeg.org/legal.html | LGPL and GPL builds, and how to stay separate. |
| GPL FAQ: mere aggregation | https://www.gnu.org/licenses/gpl-faq.html#MereAggregation | Why separate processes keep Cinematheque's license. |
