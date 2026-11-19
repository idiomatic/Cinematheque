# Architecture

How a Cinematheque library is made of operations: what one is, how devices write, sign, and merge them, how they travel between devices, the HTTP endpoints devices answer, and which keys and fields the library writes. [AGENTS.md](AGENTS.md) states the requirements; this explains how the [core](core/README.md) meets them. The code is the final word: [op.zig](core/src/op.zig), [hlc.zig](core/src/hlc.zig), [merkle.zig](core/src/merkle.zig), [replica.zig](core/src/replica.zig), [sync.zig](core/src/sync.zig), [pair.zig](core/src/pair.zig), and [serve.zig](core/src/serve.zig).

## Operations

An operation writes one field of one key, by one device. Everything that replicates is an operation, from a title's name to progress's position, a device's certificate, and the library's members, so one mechanism carries all of it.

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

Its canonical encoding is those parts in that order, integers little-endian. The encoding is what's hashed and signed; storage and the wire carry the parts separately and rebuild it.

Values are bytes, mostly UTF-8 text: numbers in decimal, flags as `1` and `0` (or empty), and records as tab-separated parts. There are no deletions: a field is emptied, and an empty value reads as unavailable.

### Kinds

* **Last writer wins** (`lww`), for nearly everything: of two operations on one field, the later clock wins, and on a tie, the greater device key.
* **Causal length** (`causal_length`), for set elements (`members`): the field is the element and the value a u32 count of its additions and removals, odd while present. Adding an unavailable element, or removing a present one, writes the next count; the longer count wins. So a removal beats the addition it saw, and an addition after it beats both, whatever the clocks say.

### Clocks

A hybrid logical clock packs wall-clock milliseconds into the high 48 bits and a counter into the low 16. Writing ticks it: the wall clock, if that's later than the last value, else the last value plus one, so a device's clocks always rise, even if its wall clock stalls or steps back. Receiving an operation folds its clock in, so what a device writes after it orders after it. Clocks stay close to real time, which lets the newest write win as people expect, without trusting any one device's clock to be right.

## Streams

Each device writes two streams, each with its own key pair and numbering:

* **Its own stream,** under its device key, for everything shared with the library.
* **Its private stream,** under a key derived from the device's seed (`"cinematheque private"`), for its person's private data (`p/<person>/...`): progress and the watchlist.

A stream's first operation must be a certificate (see [Admission](#admission)), and its numbering has no gaps, so a version vector, the highest number seen from each stream, says exactly what a replica holds.

## Batches

A device signs batches of operations, not each one. Writes inside one transaction (a crawl's, a title's details, progress's fields) form one batch of up to 1,024 consecutive operations of one stream; a write outside a transaction is a batch of its own. Signing works like this:

* Each operation's encoding is hashed with BLAKE3, prefixed `0`, as a leaf.
* Pairs of hashes are hashed, prefixed `1`, up to one root. An odd node at the end of a level is promoted unpaired, and the two prefixes keep a leaf from posing as an inner node.
* The stream's key signs `"cinematheque batch"`, the library ID, the stream key, the batch's first sequence number (u64) and count (u32), and the root, with Ed25519, so a signed batch can't be presented as another range of the stream.

One signature thus covers 1,024 writes, and any operation, or any set of them, can still be proved part of the batch with the sibling hashes along its path.

## Storage

A replica keeps each field's winning operation, in SQLite, and nothing else of the operations it saw:

* **`winners`:** per key and field, the winner's kind, clock, device, sequence number, and value. Its encoding can be rebuilt from those.
* **`batches`:** per batch, its device, first sequence number, count, root, signature, and every leaf hash. The leaves let it prove the winners it still holds, even after other operations of the batch lost their fields.
* **`devices`:** device keys, interned as small integers.
* **`version_vector`:** per stream, the highest sequence number covered.
* **`repair`:** fields a removal dropped, to refetch.
* **`local`:** the device's own state, which never replicates (crawl snapshots, devices added by address, and downloads: `downloads/dir`, `downloads/source`, `downloads/drop-watched`, `downloads/want/<item>` (a quality), `downloads/next/<title>` (a count), `downloads/keep/<item>`, and `downloads/at/<item>` (when fetched, in ms, against which the watched mark's clock tells "watched since")).

A losing operation is dropped and never sent again, since it can't change anything.

## Merging

Receiving an operation:

1. If the version vector already covers its sequence number, it's known, and skipped.
2. If it's refused (see [Admission](#admission)), it's counted and skipped.
3. Otherwise its clock is observed, and it's compared with the field's winner by its kind: if it's newer, it replaces the winner (`won`); else it's dropped (`lost`).

Whatever the order operations arrive in, every replica ends with the same winners, so devices converge without coordinating.

Two keys act on winning: `revoked` (a removal) drops the removed stream's later writes and notes their fields for repair, and `founders` (a handover) moves the founder along the chain.

## Admission

A batch is applied only if its stream may write it. That's decided from operations that replicate like any other:

* **Certificates** (`c/<stream key>`): field `user` for a device's own stream, `private` for its private stream. The value is the person's key and the person's signature over `"cinematheque device "` (or `"cinematheque private"`), the library ID, and the stream key. A batch may carry its own certificate.
* **Members** (`members`): a set of person keys, by causal length. The founder is always a member.
* **Removals** (`revoked`): per removed stream (a removed device's, or each of a removed member's devices'), its last sequence number that stands.
* **Handovers** (`founders`): fields numbered from `000001`, each naming the next founder. Each counts only if a device of the founder before it wrote it.

So a stream's batches are admitted whole if its certificate names a member. They're admitted up to its cutoff if the stream was removed, and otherwise not yet. Within a stream that's admitted, these operations are refused:

* a handover not from the previous founder;
* private data (`p/<person>/...`) not on that person's private stream;
* anything but its person's private data on a private stream.

A device always admits its own streams, so one whose replica was lost gets its private data back before its certificate arrives.

A response is applied in one transaction. A batch whose stream isn't admitted yet waits until the end of the response, since the response may also hold the certificate or membership that admits it. If nothing admits it by then, it's rejected, and its stream isn't advanced in the version vector, so a later sync offers it again.

## Sync

Sync runs both ways, started by either side: a device asks a device for what it lacks, then sends the other device what it lacks. So a device that can reach another, though that one can't reach it (behind a NAT), still syncs both ways, and only one of them need accept connections.

* **Request:** `POST /sync` with the device key, its certificate, the time, and the version vector, signed by the device (the bytes are in [HTTP endpoints](#post-sync)). The other device answers only a member's device that isn't removed, and only within ten minutes of its own clock.
* **Response,** gzipped, as frames:
  * `B`, a batch: device, first sequence number, count, signature, a bitmap of which operations follow, and the leaf hashes of those that don't. That's enough to rebuild the root and check the signature against only what's sent.
  * `O`, one per operation sent: its sequence number, clock, kind, key, field, and value. The library and device are the batch's.
  * `V`, one per stream: the sender's version vector entry, which the receiver adopts once `S` verifies.
  * `S`, the sender's signature over `"cinematheque frames"` and the BLAKE3 hash of: the library ID, the signature of the request the frames answer (a pull's, or a push's own), the sender's device key, then each `B` frame's device, first sequence number, count, signature, and bitmap, and each `V` entry, in order. A receiver takes the frames only if it verifies against the device that claims to send them, so a host that merely copied a device's public certificate can't make a device adopt its vector, or take private streams from it, and no batch can be dropped on the way.
  * `E`: the end, only after `S`.
* **What's sent:** for each stream, the winners above the receiver's vector, grouped by batch. Other people's private streams are left out, frames and vector entries alike, so private data never reaches another person's devices.
* **Push:** the response also names the other device, by its device key and certificate. The device then sends what the other device lacks, by the vector the response ended with: a second `POST /sync`, of a signed request and the same frames, leaving out private streams not the other device's person's, which the other device applies as it would a response. A device too old to take pushes refuses one, and is only pulled from.

Since only winners are sent, a sync carries the current state of what changed, not its history: progress moved ten times since the last sync is one operation per field.

* **Repair:** a removal drops winners past its cutoff. The fields it dropped are refetched from a device that refused those writes: just those fields' winners, with one shared proof per batch (the sibling hashes covering all the operations taken from it), so they're verified without the batch's other leaves. A device asks for them in each sync, after pulling, of each device it syncs with, until none await (see [`POST /sync`](#post-sync)'s repair).

The apps' status line ("Received 3 changes from firefly") counts operations: received, the operations that won their fields, and sent, the operations a response or a push carried.

## HTTP endpoints

Devices speak plain HTTP/1.1, without TLS: operations are signed, and pairing seals what it sends. Integers are little-endian, keys are 32 bytes, and signatures are Ed25519's 64.

| Endpoint | Answered by | For |
|---|---|---|
| `POST /sync` | Every device that serves | Pulling operations, and pushing them |
| `GET` and `POST /pair` | A new device offering to pair | Pairing by code |
| `GET` and `HEAD` of any other path | A device serving media | Files, listings, and `INDEX` |

A device serves on the port given (an app's, the one it got last), else on 8008, or on any free port if that's taken, and advertises `_cinematheque._tcp` by DNS-SD with a TXT record of `library` (its ID, hex), `path` (`/sync`), `user` (hex), `name` (the device's), and `person` (the person's). A new device offering to pair runs a server of its own, on a free port, answering only `/pair`, and advertises `pair` (`pair` or `join`), `path` (`/pair`), and `name` instead.

### `POST /sync`

The request's body, up to 1 MiB:

| Part | Size |
|---|---|
| Device key | 32 |
| Certificate: the person's key, and the person's signature | 96 |
| Time, in milliseconds since the epoch | u64 |
| Version vector: a count (u32), then per stream its key (32) and highest sequence number (u64) | 4 + 40 per stream |
| The device's signature over everything before it | 64 |

Answers:
* **200,** `application/octet-stream` with `Content-Encoding: gzip`: frames, each starting with a tag byte, until `E`.
  * `B`, a batch: device key (32), first sequence number (u64), count (u32, 1 to 1,024), signature (64), a bitmap of `(count + 7) / 8` bytes, whose bit *i* is set if operation *first + i* follows, and a leaf hash (32) for each bit not set. Then an `O` frame for each bit set, in order.
  * `O`, an operation: sequence number (u64), clock (u64), kind (u8), then the key, field, and value, each its length (u16, u16, and u32) and bytes.
  * `V`, a version vector entry: stream key (32) and sequence number (u64).
  * `S`, the sender's signature (64), as above.
  * `E`: the end.
  With it, two headers name the other device: `x-cinematheque-device`, its device key, and `x-cinematheque-certificate`, its certificate, each in hex.
* **400,** the error's name as text: `Malformed`, `BadSignature`, `BadCertificate` (one that doesn't verify for this library), or `Stale` (a time more than ten minutes from the other device's).
* **403,** `not a member`: the certificate's person isn't a member. Or `removed`, for a device that was removed, with `x-cinematheque-device` and `x-cinematheque-certificate` as above and `x-cinematheque-signature`, the other device's signature (hex) over `cinematheque removed`, the library ID, the asking device's key, and its request's time (u64): proof enough, from a member's device, for the device to leave.

A push is a `POST /sync` with `Content-Type: application/x-cinematheque-push`: the request's length (u32) and a request, as above (its vector unused), then frames, as a response's, gzipped. It's answered with 204, once applied, or 400 or 403 as above. A device too old to take pushes reads the whole body as a request, and refuses it as `BadSignature`.

A repair is a `POST /sync` with `Content-Type: application/x-cinematheque-repair`: the request's length (u32) and a request, as a push's, then, gzipped, the fields wanted: a count (u32), then each one's key and field, each its length (u16) and bytes. It's answered, after the same checks, with 200 and gzipped frames: per batch the fields come from, `R`, device key (32), first sequence number (u64), count (u32), signature (64), the number of operations (u16) and their indices in the batch (u16 each), the number of proof hashes (u16) and the hashes (32 each), then an `O` frame for each operation; then `E`. One shared proof covers a batch's operations, which the receiver verifies against its signed root. Private streams not the requester's person's are left out. There's no `S`: nothing is adopted into the version vector.

### `/pair`

Only while a new device offers to pair, for a kind (`pair` or `join`) and the 6-digit code it shows. Both sides derive the session's generator, a ristretto255 point, from SHA-512 over, each prefixed by its length in a byte: `CPaceRistretto255`, the code, `Cinematheque pairing`, the kind, and the session ID. The key is the first 32 bytes of SHA-512 over, prefixed likewise: `CPaceRistretto255_ISK`, the session ID, the shared point, the sender's share, and the new device's share.

* **`GET`** starts an attempt, ending any other: 200 with the session ID (16) and the new device's share (32). Once paired, or after 3 wrong codes, 410, `Closed`.
* **`POST`** answers the attempt: the session ID (16), the sender's share (32), and the sealed secrets (80): the person's seed (zeros when joining) and the founder's key, sealed with ChaCha20-Poly1305 under the key, nonce 0, and associated data `Cinematheque pairing secrets`. 200 answers with the sealed reply (80): the new device's person key and device key, under the key, nonce 1, and `Cinematheque pairing reply`. A wrong code is 403, `WrongCode`, and counts toward the 3; an attempt that isn't the current one, or a body of the wrong size, is 400; a closed offer is 410.

### Media

Any other `GET` or `HEAD`, on a device serving media: the command-line app's `--media` directory at `/media/`, or each of an app's folders at `/<folder>/`. Paths are percent-decoded, a query is ignored, and a `..` segment is 403. A path outside them all is 404.

* **Files:** 200 with `Content-Type` (`video/mp4` for `.mp4` and `.m4v`, `video/x-matroska` for `.mkv`, else `application/octet-stream`), `Accept-Ranges: bytes`, and an `ETag` of the modification time and size, in hex (`"<mtime>-<size>"`). A single `Range` (`bytes=a-b`, `bytes=a-`, or `bytes=-n`) is answered with 206 and `Content-Range`; several ranges, or one past the end, with 416 and `Content-Range: bytes */<size>`. An `If-Range` that isn't the current `ETag` gets the whole file.
* **Directories:** without a trailing slash, 301 to the path with one. With `Accept: application/json`, a listing in Caddy's form: an array of `name`, `size`, `url` (`./` and the percent-encoded name, `/` after a directory's), `mod_time` (RFC 3339, UTC), and `is_dir`; otherwise an HTML `<pre>` of links. Names beginning with `.` are left out.
* **`INDEX`,** at the top of the command-line app's media (`/media/INDEX`) (the apps' folders have none, since they change while served): `text/plain`, a line per file of its path, size, and modification time (Unix seconds), tab-separated, and per directory of its path and `/`, so an empty one (an unplugged drive's mount point) shows it's still there; built when the server starts, and again on a request once it's a minute old; with an `ETag`, so `If-None-Match` gets 304.

## Keys and fields

The library ([library.zig](core/src/library.zig), [art.zig](core/src/art.zig)) writes these. Hex means lowercase hexadecimal of a 32-byte key.

| Key | Fields | Written by |
|---|---|---|
| `t/<m\|s>/<title>/<year or ->` | `name`, `year`; `description`, `genre`, `released`, `network`; `art`, `art:s01`..., the cover as a byte range (source, path, offset, length, and the file's stamp, tab-separated); `thumb`, `thumb:s01`..., its ThumbHash in base64 or `-` | Crawls and describing |
| `.../v/<edition or ->`, `.../e/s03e17`, `.../e/s00-<title>`, `.../p/<n>` | An item's `edition`, `season`, `episode`, `title`, `description`, `duration` (ms) | Crawls and describing |
| `.../r/<quality>` | `held:<source>`: path, size, and modification time, tab-separated, or empty once gone | Crawls |
| `u/<path>` | `held:<source>`, as above, for files that didn't parse | Crawls |
| `r/<source>` | `url`, `rendition` (its files' quality, the field's name kept as data), `skip`; `managed` (`1` for a device's downloads, which no one crawls); `crawled`, when a device last crawled it whole, in ms (refreshes not asked for skip it for a day, ±1 hour); `absent:<directory>` (relative to it, empty for the whole of it), when a directory that held files was found empty (an unplugged drive's mount point), in ms, or empty once it's back, deleted, forgotten, or a year on | Adding or changing a source; crawls; forgetting |
| `settings` | `crawl`: how often refreshes not asked for crawl the sources, in hours (`1`, `3`, `24`, `168`; empty, 24), or `0`, only when asked | Settings |
| `aliases` | `<title key>`: the title key it's an alias of, or empty | Review |
| `n/<hex>` | `name`; for a device, `user` (its person's key, hex) | Naming |
| `p/<person hex>/<item key>` | `position`, `duration` (ms; empty in the first 10 seconds), `watched` (`1`, `0`, or empty) | Playing, by hand (private) |
| `p/<person hex>/watchlist` | `<title key>` or `<title key>#<season>`: `1`, or empty | The watchlist (private) |
| `c/<stream hex>` | `user` or `private`: a certificate | Each device, first |
| `members` | `<person hex>`: causal length | Adding and removing members |
| `revoked` | `<stream hex>`: the last sequence number that stands, u64 | Removing a device, or a member |
| `founders` | `000001`...: the next founder's key | Handing over |

Title and item keys derive from a file's parsed identity, so devices that crawl the same files write the same keys, and their operations merge field by field instead of duplicating titles.
