# Architecture

How a Cinematheque library is made of operations: what one is, how devices write, sign, merge, and exchange them, the HTTP endpoints devices answer, and the keys and fields the library writes. [AGENTS.md](AGENTS.md) states the requirements; this explains how the [core](core/README.md) meets them. The code has the final word: [op.zig](core/src/op.zig), [hlc.zig](core/src/hlc.zig), [merkle.zig](core/src/merkle.zig), [replica.zig](core/src/replica.zig), [sync.zig](core/src/sync.zig), [pair.zig](core/src/pair.zig), and [serve.zig](core/src/serve.zig).

## Operations

An operation is one device's write of one field of one key. Everything that replicates is an operation (a title's name, a position, a device's certificate, the library's members), so one mechanism carries it all.

| Part | Size | Meaning |
|---|---|---|
| library | 16 bytes | The library's ID: the first 16 bytes of the BLAKE3 hash of its founder's person key |
| device | 32 bytes | The Ed25519 public key of the stream that wrote it |
| seq | u64 | Its place in that stream, from 1, without gaps |
| hlc | u64 | When it was written, by hybrid logical clock |
| kind | u8 | How it merges: `0`, last writer wins; `1`, causal length |
| key | u16 length, then bytes | What it's about, e.g., `t/m/alien/1979` |
| field | u16 length, then bytes | Which of the key's fields, e.g., `name` |
| value | u32 length, then bytes | The field's new value; empty means none |

Its canonical encoding is those parts in that order, integers little-endian. The encoding is what's hashed and signed; storage and the wire carry the parts and rebuild it.

Values are bytes, mostly UTF-8 text: numbers in decimal, flags as `1` and `0` (or empty), records as tab-separated parts. Nothing is deleted: a field is emptied, and an empty value reads as unavailable.

### Kinds

* **Last writer wins** (`lww`), for everything but `members`: of two operations on one field, the later clock wins; on a tie, the greater device key. Handovers (`founders`) are the exception: the earliest wins, so a handover stands once made.
* **Causal length** (`causal_length`), for `members` alone: the field is the element, and the value a u32 count: 1 once added, even once removed. A removal outranks any addition, whatever the clocks, so it's for good: a person removed comes back as someone new. (Otherwise a count could be written so high that no removal outranked it.)

### Clocks

A hybrid logical clock packs wall-clock milliseconds into the high 48 bits and a counter into the low 16. Writing ticks it to the wall clock if that's later than the last value, else to the last value plus one, so a device's clocks always rise, even if its wall clock stalls or steps back. Receiving an operation folds its clock in, so what the device writes next orders after it. An operation dated more than a day past the receiver's wall clock is refused; else it would hold its field for good and drag every clock to its end. A clock at its end stays there rather than wrapping. Clocks stay close to real time, so the newest write wins, as people expect, without trusting any one device's clock.

## Streams

Each device writes two streams, each with a key pair and numbering of its own:

* **Its own stream,** under its device key, for everything shared with the library.
* **Its private stream,** under a key derived from the device's seed (`"cinematheque private"`), for its person's private data (`p/<person>/...`): progress and lists.

A stream's first operation must be a certificate (see [Admission](#admission)). Its numbering has no gaps, so a version vector (the highest number seen from each stream) says exactly what a replica holds.

## Batches

A device signs batches of operations, not each one. A transaction's writes (a crawl's, a title's details, progress's fields) form batches of up to 1,024 consecutive operations of one stream, a new one every 1,024; a write outside a transaction is a batch of its own. To sign one:

* Each operation's encoding is hashed with BLAKE3, prefixed `0`, as a leaf.
* Pairs of hashes are hashed, prefixed `1`, up to one root. An odd node at a level's end is promoted unpaired. The two prefixes keep a leaf from posing as an inner node.
* The stream's key signs `"cinematheque batch"`, the library ID, the stream key, the batch's first sequence number (u64) and count (u32), and the root, with Ed25519, so a batch can't be presented as another range of the stream.

So one signature covers 1,024 writes, and any operation, or set of them, can be proved part of the batch by the sibling hashes along its path.

## Storage

A replica keeps, in SQLite, each field's winning operation and nothing else of the operations it saw:

* **`winners`:** per key and field, the winner's kind, clock, device, sequence number, and value, from which its encoding is rebuilt.
* **`batches`:** per batch, its device, first sequence number, count, root, signature, and every leaf hash, so it can prove the winners it holds after the batch's other operations have lost their fields.
* **`devices`:** device keys, interned as small integers.
* **`version_vector`:** per stream, the highest sequence number covered.
* **`repair`:** fields a removal dropped, to refetch.
* **`local`:** the device's own state, which never replicates (crawl snapshots, devices added by address, and downloads: `downloads/dir`, `downloads/source`, `downloads/want/<item>` (a quality), `downloads/next/<title>` (a count, or `all`), and `downloads/at/<item>` (when fetched, in ms; the watched mark's clock past it means "watched since")).

A losing operation is dropped and never sent again, as it can't change anything.

## Merging

Receiving an operation:

1. If the version vector already covers its sequence number, it's known, and skipped.
2. If it's refused (see [Admission](#admission)), it's counted and skipped.
3. Otherwise its clock is observed, and it's compared with the field's winner by its kind: if newer, it replaces the winner (`won`); else it's dropped (`lost`).

In whatever order operations arrive, every replica ends with the same winners, so devices converge without coordinating.

Two keys act when they win: `revoked` (a removal) drops the removed stream's later writes and notes their fields for repair, and `founders` (a handover) moves the founder along the chain.

## Admission

A batch is applied only if its stream may write it, as decided by operations that replicate like any other:

* **Certificates** (`c/<stream key>`): field `user` for a device's own stream, `private` for its private stream. The value is the person's key and the person's signature over `"cinematheque device "` (or `"cinematheque private"`), the library ID, and the stream key. A batch may carry its own certificate.
* **Members** (`members`): a set of person keys, by causal length. The founder is always a member.
* **Removals** (`revoked`): per removed stream (a removed device's, or each of a removed member's devices'), the last sequence number that stands.
* **Handovers** (`founders`): fields numbered from `000001`, each naming the next founder, and counting only if written by a device of the founder before it.

So a stream's batches are admitted if its certificate names a member: whole, or up to its cutoff if the stream was removed; otherwise not yet. Within an admitted stream, these operations are refused:

* a handover not from the previous founder;
* private data (`p/<person>/...`) not on that person's private stream;
* anything but its person's private data on a private stream;
* an operation of the wrong kind for its key, or a `members` count but 1 or an even one;
* an operation dated more than a day ahead;
* a source's `url` that its ID doesn't hash, or not from the device whose `url` is held; its `managed` but from that device (and a device's own folder, `cqdevice://<key>/…`, is no source but from that device, as any member could otherwise aim devices at another's paths; nor is its `served` but its own, both ignored as read, not refused);
* a shared list's field (`l/<owner>/<id>`) not from one of its owner's devices, or not its `name`, a mode change, or a title;
* a cutoff (`revoked`) of the founder's devices but from the founder's own, or the device itself, else not 8 bytes; and between cutoffs, the lower wins, so a removal can't be undone;
* a certificate (`c/<stream key>`) but a device's own `user` one, or a `private` one naming its writer's person when the receiver holds none naming another, so no member can claim another's private stream and be sent its data.

A batch overlapping a range a held batch covers (but that same batch) is refused, as a stream numbers each write once.

A device always admits its own streams, so one whose replica was lost gets its private data back before its certificate arrives.

A response is applied in one transaction. A batch whose stream isn't admitted yet waits until the response's end, which may bring the certificate or membership that admits it. If nothing has by then, it's rejected, and its stream isn't advanced in the version vector, so a later sync offers it again. Held batches count against the response's limit by all they hold (text, leaves, and operations).

The version vector a response ends with is taken only from a member's device (a member before the response or after it, as a founder handing over and leaving is), and never for the receiver's own streams, which only it numbers. Else a stranger who answered could make a device skip any stream's writes, or number its own past what any device accepts.

## Sync

Sync runs both ways, started by either side: a device asks the other for what it lacks, then sends what the other lacks. So a device that can reach another that can't reach it (behind a NAT) still syncs both ways; only one need accept connections.

* **Request:** first `GET /sync`, which names the other device (its device key and certificate, in headers); then `POST /sync` with the device key, its certificate, the time, the other device's key, and the version vector, signed by the device (the bytes are in [HTTP endpoints](#post-sync)). The other device refuses a request meant for another device, and the device refuses a response from any but the one asked, so a request sent to one (a host posing as a device of the library, say) can't be replayed to another to read what it would be sent. The other device answers only a member's device that isn't removed, within ten minutes of its own clock.
* **Response,** gzipped, as frames:
  * `B`, a batch: device, first sequence number, count, signature, a bitmap of which operations follow, and the leaf hashes of those that don't: enough to rebuild the root and check the signature from only what's sent.
  * `O`, one per operation sent: its sequence number, clock, kind, key, field, and value. The library and device are the batch's.
  * `V`, one per stream: the sender's version vector entry, which the receiver adopts once `S` verifies.
  * `S`, the sender's signature over `"cinematheque frames"` and the BLAKE3 hash of: the library ID, the signature of the request the frames answer (a pull's, or a push's own), the sender's device key, then each `B` frame's device, first sequence number, count, signature, and bitmap, and each `V` entry, in order. A receiver takes the frames only if it verifies against the device claiming to send them, so a host that merely copied a device's public certificate can't make a device adopt its vector or take private streams from it, and no batch can be dropped on the way.
  * `E`: the end, only after `S`.
* **What's sent:** for each stream, the winners above the receiver's vector, grouped by batch. Other people's private streams are left out, frames and vector entries alike, so private data never reaches another person's devices.
* **Push:** the response also names the other device, by its device key and certificate. The device then sends what the other lacks by the vector the response ended with: a second `POST /sync` of a signed request and frames as above, leaving out private streams not the other device's person's, which the other device applies as it would a response. A device too old to take pushes refuses one, and is only pulled from.

As only winners are sent, a sync carries the current state of what changed, not its history: progress moved ten times since the last sync is one operation per field.

* **Repair:** a removal drops winners past its cutoff. Its dropped fields are refetched from a device that refused those writes: just those fields' winners, with one shared proof per batch (the sibling hashes covering all the operations taken from it), so they're verified without the batch's other leaves. A device asks each device it syncs with for them, after pulling, until none await (see [`POST /sync`](#post-sync)'s repair).

The apps' status line ("Received 3 changes from firefly") counts operations: received, those that won their fields; sent, those a response or a push carried.

## HTTP endpoints

Devices speak plain HTTP/1.1, without TLS: operations are signed, and pairing and syncs seal what they send. Integers are little-endian, keys are 32 bytes, and signatures are Ed25519's 64.

| Endpoint | Answered by | For |
|---|---|---|
| `GET /sync` | Every device that serves | Naming itself, for a request to be for it alone |
| `POST /sync` | Every device that serves | Pulling operations, and pushing them |
| `GET` and `POST /pair` | A new device offering to pair | Pairing by code |
| `GET` and `HEAD` of any other path | A device serving media | Files, listings, and `INDEX` |

A device serves on the port given (an app's, the one it got last), else on 8008, or any free port if that's taken, and advertises `_cinematheque._tcp` by DNS-SD with a TXT record of `library` (its ID, hex), `path` (`/sync`), `user` (hex), `name` (the device's), and `person` (the person's). A new device offering to pair runs a server of its own, on a free port, answering only `/pair`, and advertises `pair` (`new`), `path` (`/pair`), and `name` instead.

### `POST /sync`

The body is sealed ([seal.zig](core/src/seal.zig)), so only the device it's for reads it, and only the asking device reads the answer. The asking device makes an X25519 key pair for the request alone, agrees a secret with the other device's key (from `GET /sync`, its Ed25519 key as X25519), and derives a key each way by BLAKE3 (`cinematheque sync keys`, the library ID, its public key, the other device's key, and the secret). Sealed data is chunks of up to 64 KiB, each its length (u32, its top bit set on the last), its ChaCha20-Poly1305 ciphertext, and its tag, with a nonce of the part (1, the request; 2, the rest; 3, the answer) and the chunk's number, so no chunk can be dropped, moved, or cut off. The body: its public key (32), the sealed request's length (u32) and the sealed request, then for a push or repair the rest, sealed. The sealed request must arrive within the 30 seconds a request's head has, and the rest a mebibyte a minute, and the other device opens its replica only once the request checks out, so no one holds a connection, or costs it work, without being a member's device. An answer to a request that asks (as every device's does) is sealed under the answer's key salted afresh, BLAKE3 keyed with it over `cinematheque response` and 32 random bytes, sent in hex as `x-cinematheque-salt`: so a request replayed is answered under a new key, never another plaintext under the same key and nonces. The request, up to 1 MiB, before sealing:

| Part | Size |
|---|---|
| Device key | 32 |
| Certificate: the person's key, and the person's signature | 96 |
| Time, in milliseconds since the epoch | u64 |
| The other device's key, whom it's for (from `GET /sync`) | 32 |
| A repair's field list's BLAKE3 hash (of its encoding, below), else zeros | 32 |
| Version vector: a count (u32), then per stream its key (32) and highest sequence number (u64) | 4 + 40 per stream |
| Flags (u8): 1, the answer salted; left out by older devices, and ignored by older ones answering | 1 |
| The device's signature over `cinematheque request`, the library ID, and everything before it | 64 |

Answers:
* **200,** `application/octet-stream`, sealed: frames, gzipped, each starting with a tag byte, until `E`.
  * `B`, a batch: device key (32), first sequence number (u64), count (u32, 1 to 1,024), signature (64), a bitmap of `(count + 7) / 8` bytes, whose bit *i* is set if operation *first + i* follows, and a leaf hash (32) for each bit not set. Then an `O` frame for each bit set, in order.
  * `O`, an operation: sequence number (u64), clock (u64), kind (u8), then the key, field, and value, each its length (u16, u16, and u32) and bytes.
  * `V`, a version vector entry: stream key (32) and sequence number (u64).
  * `S`, the sender's signature (64), as above.
  * `E`: the end.
  With it, two headers name the other device: `x-cinematheque-device`, its device key, and `x-cinematheque-certificate`, its certificate, each in hex; and `x-cinematheque-salt`, if salted.
* **400,** the error's name as text: `Malformed`, `BadSignature`, `BadCertificate` (one that doesn't verify for this library), `Stale` (a time more than ten minutes from the other device's), `WrongRecipient` (a request for another device), or `BadSeal` (one it can't open).
* **403,** `not a member`: the certificate's person isn't a member. Or `removed`, for a device that was removed, with `x-cinematheque-device` and `x-cinematheque-certificate` as above and `x-cinematheque-signature`, the other device's signature (hex) over `cinematheque removed`, the library ID, the asking device's key, and its request's time (u64): proof enough, from a member's device, for the device to leave.

A push is a `POST /sync` with `Content-Type: application/x-cinematheque-push`: the request, as above (its vector unused), then frames, as a response's, gzipped, the rest sealed. It's answered with 204, once applied, or 400 or 403 as above; a refusal fails the sync, as a pull's does.

A repair is a `POST /sync` with `Content-Type: application/x-cinematheque-repair`: the request, as a push's, then, gzipped and sealed, the fields wanted: a count (u32), then each one's key and field, each its length (u16) and bytes. After the same checks, and that the fields are those whose hash the request signs, it's answered with 200 and frames, gzipped and sealed (and salted, as above): per batch the fields come from, `R`, device key (32), first sequence number (u64), count (u32), signature (64), the number of operations (u16) and their indices in the batch (u16 each), the number of proof hashes (u16) and the hashes (32 each), then an `O` frame for each operation; then `E`. One shared proof covers a batch's operations, verified against its signed root. Private streams not the requester's person's are left out. There's no `S`: nothing is adopted into the version vector.

### `/pair`

Answered only while a new device offers to be added, by the 6-digit code it shows. The member's device decides what it is, sending the person's seed (another of its person's devices) or zeros (a new member's). Both sides derive the session's generator, a ristretto255 point, from SHA-512 over, each prefixed by its length in a byte: `CPaceRistretto255`, the code, `Cinematheque pairing`, `pair` (once the offer's kind, now fixed, so older offers still pair), and the session ID. The key is the first 32 bytes of SHA-512 over, prefixed likewise: `CPaceRistretto255_ISK`, the session ID, the shared point, the sender's share, and the new device's share.

* **`GET`** starts an attempt, ending any other: 200 with the session ID (16) and the new device's share (32). Once paired, or after 3 wrong codes from the asking address, or 30 from all, 410, `Closed`.
* **`POST`** answers the attempt: the session ID (16), the sender's share (32), and the sealed secrets (80): the person's seed (zeros when joining) and the founder's key, sealed with ChaCha20-Poly1305 under the key, nonce 0, and associated data `Cinematheque pairing secrets`. 200 answers with the sealed reply (80): the new device's person key and device key, under the key, nonce 1, and `Cinematheque pairing reply`. A wrong code is 403, `WrongCode`, and counts toward the 3; an attempt that isn't the current one, or a body of the wrong size, is 400; a closed offer is 410.

### Media

Any other `GET` or `HEAD`, on a device serving media, is served from the command-line app's `--media` directory at `/media/`, or an app's folders, each at `/<folder>/`. Paths are percent-decoded, a query is ignored, and a `..` segment is 403. A path outside them all is 404.

* **Files:** 200 with `Content-Type` (`video/mp4` for `.mp4` and `.m4v`, `video/x-matroska` for `.mkv`, else `application/octet-stream`), `Accept-Ranges: bytes`, and an `ETag` of the modification time and size, in hex (`"<mtime>-<size>"`). A single `Range` (`bytes=a-b`, `bytes=a-`, or `bytes=-n`) is answered with 206 and `Content-Range`; several ranges, or one past the end, with 416 and `Content-Range: bytes */<size>`. An `If-Range` that isn't the current `ETag` gets the whole file.
* **Directories:** without a trailing slash, 301 to the path with one. With `Accept: application/json`, a listing in Caddy's form: an array of `name`, `size`, `url` (`./` and the percent-encoded name, `/` after a directory's), `mod_time` (RFC 3339, UTC), and `is_dir`; otherwise an HTML `<pre>` of links. Names beginning with `.` are left out.
* **`INDEX`,** at the top of the command-line app's media (`/media/INDEX`) (the apps' folders have none, since they change while served): `text/plain`, a line per file of its path, size, and modification time (Unix seconds), tab-separated, and per directory of its path and `/`, so an empty one (an unplugged drive's mount point) shows it's still there; built when the server starts, and again on a request once it's a minute old; with an `ETag`, so `If-None-Match` gets 304.

## Keys and fields

The library ([library.zig](core/src/library.zig), [art.zig](core/src/art.zig)) writes these. Hex means lowercase hexadecimal of a 32-byte key.

| Key | Fields | Written by |
|---|---|---|
| `t/<m\|s>/<title>/<year or ->` | `name`, `year`; `description`, `genre`, `released`, `network`; `art`, `art:s01`..., the cover as a byte range (source, path, offset, length, and the file's stamp, tab-separated); `shape`, `shape:s01`..., its width and height (`667x1000`) or `-` | Crawls and describing |
| `.../v/<edition or ->`, `.../e/s03e17` (`.../e/s2024e0312` by air date), `.../e/s00-<title>`, `.../p/<n>` | An item's `edition`, `season`, `episode`, `title`, `description`, `duration` (ms) | Crawls and describing |
| `.../r/<quality>` | `held:<source>`: path, size, and modification time, tab-separated, or empty once gone | Crawls |
| `u/<path>` | `held:<source>`, as above, for files that didn't parse | Crawls |
| `r/<source>` | `url`, `rendition` (its files' quality, the field's name kept as data), `quality-by` (`path`: each file's quality is the nearest of its name and folders that says one, a folder by its whole name; `folder`: the first folder within the source; empty: the file's name's tokens, else its folders'), `skip`; `managed` (`1` for a device's downloads, which no one crawls); `crawled`, when a device last crawled it whole, in ms (refreshes not asked for skip it within the library's interval, `settings`' `crawl`, give or take a 24th of it); `absent:<directory>` (relative to it, empty for the whole of it), when a directory that held files was found empty (an unplugged drive's mount point), in ms, or empty once it's back, deleted, forgotten, or a year on | Adding or changing a source; crawls; forgetting |
| `settings` | `crawl`: how often refreshes not asked for crawl the sources, in hours (`1`, `3`, `24`, `168`; empty, 24), or `0`, only when asked | Settings |
| `n/<hex>` | `name`; for a device, `user` (its person's key, hex), `model` (its own), and `served` (its own: where it serves its own folders, `cqdevice://<hex>/…`, now, `http://firefly.local:58275/`) | Naming; serving |
| `p/<person hex>/<item key>` | `position`, `duration` (ms; empty in the first 10 seconds), `watched` (`1`, `0`, or empty) | Playing, by hand (private) |
| `p/<person hex>/watchlist` | `<title key>` or `<title key>#<season>`: `1`, a placeholder (`w`, its name, its note, tab-separated), or empty | The watchlist (private) |
| `p/<person hex>/lists` | `<list ID>`: its name, or empty once deleted | Lists (private) |
| `p/<person hex>/list/<ID>` | as the watchlist's | A list's titles (private) |
| `l/<owner hex>/<ID>` | `name`; `mode:<16 hex>`: `shared` or `private`, each written once, the latest current; titles, as the watchlist's | A list shared with every member, by its owner's devices |
| `c/<stream hex>` | `user` or `private`: a certificate | Each device, first |
| `members` | `<person hex>`: causal length | Adding and removing members |
| `revoked` | `<stream hex>`: the last sequence number that stands, u64 | Removing a device, or a member |
| `founders` | `000001`...: the next founder's key | Handing over |

Title and item keys derive from a file's parsed identity, so devices crawling the same files write the same keys, whose operations merge field by field rather than duplicating titles.

## Measurements

The prototypes the core grew from measured what the design rests on, on an Apple M2. Their writeups, and the browse and transcoder prototypes' code (for work not built yet; see [DEVELOPMENT.md](DEVELOPMENT.md)), were retired after commit `436e5ea`; `git checkout 436e5ea -- experiments` restores them.

| Experiment | What it measured | Headline |
|---|---|---|
| CRDT | The replica: signed operations in SQLite, sync, membership, thin fetches | 409,500 operations (100,000 copies): 1.1 s to build, 1.1 s to sync cold, in memory or over HTTP, 24.5 MB on the wire (4.0 MB with Zig's gzip, 2.4 MB with zstd), 56 MB on disk; one series fetched thin in 3 ms and 51 KB. Signing each operation instead of each batch took 17 s, and verifying 21 s. |
| Repository | Crawling listings, Cinematheque's server, re-crawls | 100,000 files: one `INDEX` request, 8 ms; JSON or HTML from Cinematheque's server, 8,503 requests, 0.2 s; rclone 1.5 s; Python 3.3 s (and no byte ranges); Apache 9–18 s. At a 4 ms round trip, 31 s with one worker, 0.9 s with 32. An unchanged re-crawl took 503 requests instead of 8,503, and every one of 800 changes was found. A real Caddy NAS over Wi-Fi: 20,000 files in 0.24 s with 32 workers. |
| Naming | The filename parser | 100,000 paths in 80 ms; on a real library of tens of thousands of videos, under 0.2% left for review once compact episode codes were read. |
| Discovery | DNS-SD from Zig | Bonjour on macOS and Avahi on Linux, which found each other. |
| browse | Facet intersections | A four-facet query and its refinement menu over 4,500 titles: 13 ms in SQLite, 43 µs with 105 KB of bitmaps. |
| transcoder | Remux-first transcoding over HTTP | 60-second remuxes in 0.1–0.4 s, converting DTS and SubRip; an MPEG-2 re-encode in 8.5 s; AVFoundation plays every output, but not MKV, nor HEVC tagged `hev1`. |
