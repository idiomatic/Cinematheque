# Architecture

How a library is made of operations, how devices sign, merge, and exchange them, the HTTP endpoints they answer, and the keys and fields the library writes. [AGENTS.md](AGENTS.md) states the requirements; the code ([op.zig](core/src/op.zig), [hlc.zig](core/src/hlc.zig), [merkle.zig](core/src/merkle.zig), [replica.zig](core/src/replica.zig), [frames.zig](core/src/frames.zig), [sync.zig](core/src/sync.zig), [seal.zig](core/src/seal.zig), [pair.zig](core/src/pair.zig), [serve.zig](core/src/serve.zig)) has the final word.

## Operations

One device's write of one field of one key; everything that replicates is one (a title's name, a position, a certificate, the members).

| Part | Size | Meaning |
|---|---|---|
| library | 16 | The first 16 bytes of the BLAKE3 hash of its creator's person key |
| device | 32 | The Ed25519 public key of the stream that wrote it |
| seq | u64 | Its place in that stream, from 1, without gaps |
| hlc | u64 | Its hybrid logical clock |
| kind | u8 | `0`, last writer wins; `1`, causal length |
| key, field | u16 length, bytes | What it's about (`t/m/alien/1979`, `name`) |
| value | u32 length, bytes | The new value; empty means none |

Its canonical encoding is those parts in order, integers little-endian; that's what's hashed and signed. Values are mostly UTF-8: numbers in decimal, flags `1` and `0`, records tab-separated. Nothing is deleted; a field is emptied.

* **Last writer wins**, for all but `members`: the later clock wins, a tie the greater device key; but between two `revoked` cutoffs, the lower.
* **Causal length**, for `members`: the value a u32 count, odd while present. A removal (even) outranks any addition, whatever the counts, so it's for good.
* **Clocks:** wall-clock milliseconds in the high 48 bits, a counter in the low 16. Writing ticks to the wall clock if later, else the last value plus one; receiving folds the operation's clock in. One more than a day past the receiver's wall clock is refused, as it would hold its field for good. A clock at its end stays there.

## Streams, batches, and storage

Each device writes two streams, each with its own key and numbering: its own, under its device key, and its private stream, under a key derived from its seed (`"cinematheque private"`), for its person's `p/<person>/...`. A stream's first operation is a certificate; its numbering has no gaps, so a version vector (the highest number seen per stream) says exactly what a replica holds.

A transaction's writes form batches of up to 1,024 consecutive operations; a write outside one is a batch of its own. Each encoding hashed with BLAKE3, prefixed `0`, is a leaf; pairs hash, prefixed `1`, up to a root, an odd node promoted. The stream's key signs `"cinematheque batch"`, the library ID, the stream key, the first sequence number (u64), the count (u32), and the root, so a batch can't pose as another range.

SQLite holds only winners: `winners` (per key and field: kind, clock, device, sequence number, value, from which the encoding is rebuilt); `batches` (device, range, root, signature, and every leaf, so a winner can be sent under its batch's signature after the batch's other operations lost); `devices` (keys interned as integers); `version_vector`; and `local`, the device's own state, never replicated (crawl snapshots, `refill`, addresses added, and downloads: `downloads/dir`, `downloads/source`, `downloads/want/<item>`, `downloads/next/<title>`, `downloads/at/<item>`, `downloads/file/<item>`).

Receiving an operation: one the vector covers is known and skipped; one refused is counted and skipped; else its clock is observed and it's merged by its kind, `won` or `lost`. Replicas converge whatever the order. A winning `revoked` drops the stream's winners past its cutoff (see Refill).

## Admission

A batch applies only if its stream may write it, decided by operations that replicate like any other:

* **Certificates** (`c/<stream hex>`): `user` for a device's own stream, `private` for its private stream: the person's key and their signature over `"cinematheque device "` (or `"cinematheque private"`), the library ID, and the stream key. A batch may carry its own.
* **Members** (`members`): person keys by causal length; the creator counts 1 without a write, until removed.
* **Removals** (`revoked`): per stream, the last sequence number that stands.

A stream is admitted whole if its certificate names a member, up to its cutoff if removed, else not yet. Within it, refused: private data not on its person's private stream, and anything else on a private stream; the wrong kind for a key, or a `members` count but 1 or an even one; anything a day ahead; a source's `url` its ID doesn't hash, or not from the device whose `url` is held, and its `managed` from any other (a `cqdevice://` source, and a device's `served`, are ignored on reading unless from that device); a shared list's field (`l/<owner>/<id>`) not from its owner's devices, or not its `name`, a mode, or a title; a cutoff not 8 bytes; a certificate but a device's own `user` one, or a `private` one naming its writer's person where none held names another. A batch overlapping a held batch's range (but itself) is refused. A device always admits its own streams.

A response applies in one transaction. A batch not admitted yet waits to its end, which may bring what admits it; else it's rejected and its stream left unadvanced, to be offered again. Held batches count against the response's size limit by all they hold. The vector a response ends with is taken only from a member's device, and never for the receiver's own streams.

## Sync

A device asks the other which device it is (`GET /sync`: its device key and certificate in headers), then pulls (`POST /sync`), then pushes what the other lacks by the vector the pull ended with. Only winners above the vector are sent, grouped by batch, so a sync carries current state, not history; other people's private streams are left out, frames and vector entries alike.

**Refill:** a cutoff drops winners whose predecessors are long gone, and the vector already covers them. So a device whose cut dropped any sends its next pull with an empty vector, merges every winner the other holds, covered or not (what it holds loses or ties), and clears `refill`. A value neither held is lost.

## HTTP endpoints

Plain HTTP/1.1: operations are signed, and pairing and syncs sealed. Integers little-endian, keys 32 bytes, signatures 64.

| Endpoint | Answered by | For |
|---|---|---|
| `GET /sync`, `POST /sync` | Every device serving | Naming itself; pulls and pushes |
| `GET`, `POST /pair` | A new device offering to pair | Pairing by code |
| `GET`, `HEAD` of other paths | A device serving media | Files, listings, `INDEX` |

A device advertises `_cinematheque._tcp` with TXT `library` (hex ID), `path` (`/sync`), `user` (person hex), `name`, and `person`; a new device offering to pair serves only `/pair`, on a free port, advertising `pair` (`new`), `path`, and `name`.

### `POST /sync`

**Sealing:** the asking device makes an X25519 key pair for the request, agrees a secret with the other's key (its Ed25519 key as X25519), and derives a key each way by BLAKE3 (`cinematheque sync keys`, library ID, its public key, the other's key, the secret). Sealed data is chunks of up to 64 KiB: length (u32, top bit on the last), ChaCha20-Poly1305 ciphertext, tag, nonced by part (1 request, 2 rest, 3 answer) and chunk number. The body: the public key (32), the sealed request's length (u32) and it, then for a push the rest. The request must arrive within 30 seconds, the rest a mebibyte a minute, and the replica opens only once the request checks out. An answer's key is salted afresh: BLAKE3 keyed with it over `cinematheque response` and 32 random bytes, sent in hex as `x-cinematheque-salt`.

**Request** (up to 1 MiB): device key (32); certificate (96: person key and signature); time (u64 ms); the recipient's key (32); version vector (u32 count, then per stream key and u64; none while refilling); the device's signature (64) over `cinematheque request`, the library ID, and the rest. It's refused if for another device, more than ten minutes off, or not a member's.

**200**, sealed, gzipped frames, each a tag byte:
* `B`: device (32), first (u64), count (u32, 1–1,024), signature (64), a bitmap of `(count + 7) / 8` bytes whose bit *i* means operation *first + i* follows, and a leaf (32) per unset bit; then an `O` per set bit.
* `O`: seq (u64), hlc (u64), kind (u8), key, field, and value (u16, u16, u32 lengths).
* `V`: stream key (32) and u64, adopted once `S` verifies.
* `S`: the sender's signature (64) over `"cinematheque frames"` and the BLAKE3 hash of the library ID, the request's signature, the sender's key, each `B`'s header and bitmap, and each `V`, in order; so frames are believed only from the device asked, for that request, with no batch dropped.
* `E`: the end.

Headers name the answerer: `x-cinematheque-device` and `x-cinematheque-certificate` (hex), and the salt.

**400** names the error (`Malformed`, `BadSignature`, `BadCertificate`, `Stale`, `WrongRecipient`, `BadSeal`). **403** is `not a member`, or `removed`, with the answerer's device and certificate and `x-cinematheque-signature` over `cinematheque removed`, the library ID, the asker's key, and its request's time: proof, from a member's device, for it to leave.

**Push:** `Content-Type: application/x-cinematheque-push`, the request (its vector unused), then frames as a response's, sealed. 204 once applied; 400 or 403 fails the sync.

### `/pair`

Both sides derive a ristretto255 generator from SHA-512 over, each prefixed by its length in a byte, `CPaceRistretto255`, the code, `Cinematheque pairing`, `pair`, and the session ID; the key is the first 32 bytes of SHA-512 over `CPaceRistretto255_ISK`, the session ID, the shared point, the sender's share, and the new device's share, prefixed likewise.

* **`GET`** starts an attempt, ending any other: the session ID (16) and the new device's share (32). Once paired, or after 3 wrong codes from the address or 30 in all, 410.
* **`POST`**: session ID (16), the sender's share (32), and sealed secrets (80: the person's seed, or zeros for a new member, and the library's key; ChaCha20-Poly1305, nonce 0, AD `Cinematheque pairing secrets`). 200 with the sealed reply (80: the new device's person key and device key; nonce 1, AD `Cinematheque pairing reply`). A wrong code is 403 `WrongCode`; a stale attempt or wrong size, 400; a closed offer, 410.

### Media

From `--media` at `/media/`, or an app's folders at `/<folder>/`; paths percent-decoded, queries ignored, a `..` segment 403, anything else 404.

* **Files:** `Content-Type` (`video/mp4`, `video/x-matroska`, else octet-stream), `Accept-Ranges: bytes`, `ETag` `"<mtime>-<size>"` in hex. One `Range` gets 206; several, or past the end, 416; an `If-Range` not matching gets the whole.
* **Directories:** without a trailing slash, 301. With `Accept: application/json`, Caddy's form (`name`, `size`, `url`, `mod_time` in RFC 3339, `is_dir`); else an HTML `<pre>` of links. Names starting with `.` left out.
* **`INDEX`** (the command-line app's only): `text/plain`, per file its path, size, and Unix time, tab-separated, per directory its path and `/`; with an `ETag` for `If-None-Match`.

## Keys and fields

Written by [library.zig](core/src/library.zig), [art.zig](core/src/art.zig), and [lists.zig](core/src/lists.zig); hex is a 32-byte key's.

| Key | Fields |
|---|---|
| `t/<m\|s>/<title>/<year or ->` | `name`, `year`, `description`, `genre`, `released`, `network`, `sort`, `added`; `art`, `art:s01`... (source, path, offset, length, stamp, tab-separated); `shape`, `shape:s01`... (`667x1000` or `-`) |
| `.../v/<edition>`, `.../e/s03e17`, `.../e/s00-<title>`, `.../p/<n>` | `edition`, `season`, `episode`, `title`, `description`, `duration` (ms), `read` |
| `.../r/<quality>`, `u/<path>` (unparsed) | `held:<source>`: path, size, time, tab-separated; empty once gone |
| `r/<source>` | `url`, `name`, `rendition`, `quality-by` (`path`, or empty with `rendition`), `skip`, `managed`, `crawled` (ms), `absent:<dir>` (ms; empty once back) |
| `settings` | `crawl`: hours (`1`, `3`, `24`, `168`; empty, 24) or `0`, only when asked |
| `n/<hex>` | `name`; a device's `user` (person hex), `model`, `served` |
| `p/<person hex>/<item key>` | `position`, `duration` (ms), `watched` |
| `p/<person hex>/lists` | per list ID its name, empty once deleted |
| `p/<person hex>/watchlist`, `.../list/<ID>` | per `<title key>` or `<title key>#<season>`: `1`, a placeholder (`w`, name, note, tab-separated), or empty |
| `l/<owner hex>/<ID>` | `name`; `mode:<16 hex>` (`shared` or `private`); titles, as a list's |
| `c/<stream hex>` | `user` or `private`: a certificate |
| `members` | per person hex: a causal length |
| `revoked` | per stream hex: the last sequence number that stands (u64) |

## Measurements

The prototypes the core grew from (on an Apple M2; retired after commit `436e5ea`, restored by `git checkout 436e5ea -- experiments`) found: 409,500 operations (100,000 copies) built and synced cold in 1.1 s each, 4.0 MB gzipped on the wire, 56 MB on disk, where signing each operation took 17 s; 100,000 files listed by one `INDEX` request in 8 ms, or 8,503 listings in 0.2 s, 0.9 s with 32 workers at a 4 ms round trip, and an unchanged re-crawl in 503 requests; 100,000 paths parsed in 80 ms; Bonjour and Avahi finding each other; a four-facet query over 4,500 titles in 13 ms in SQLite, 43 µs with bitmaps; and remuxes of a minute's video in 0.1–0.4 s, which AVFoundation plays (not MKV, nor HEVC tagged `hev1`).
