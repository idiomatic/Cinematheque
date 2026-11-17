# CRDT experiment

> This experiment grew into the core's [replica](../../core/src/replica.zig) and [sync](../../core/src/sync.zig). Its code was removed after commit `92243e1`; `git checkout 92243e1 -- experiments/crdt` restores it, to rerun the measurements below.

Tests the replica design, now **Replication** in [AGENTS.md](../../AGENTS.md), at its scale: last-writer-wins operations and causal-length sets in SQLite, signed in batches by devices that users certify, admitted by library membership, caught up by version vectors in memory or over HTTP, and fetched by title into a thin replica.

## Running

```sh
zig build test
zig build run --release=fast            # full scale
zig build run --release=fast -- 10      # a tenth of it
zig build sigbench --release=fast       # signing schemes alone
```

The benchmark writes its databases to `bench/`, under 200 MB at full scale, and replaces it on each run.

## Design

* `src/op.zig`: an operation writes one field of one key, either a value (last writer wins) or a set element's causal length (odd while present; the longer wins).
* `src/merkle.zig`: a device signs each batch of up to 1,024 consecutive writes once, with Ed25519, over a BLAKE3 Merkle tree of their encodings; a proof of 10 hashes ties any one operation to the signed root, and one shared proof ties any set of them, needing few hashes for neighbors.
* `src/hlc.zig`: a 64-bit hybrid logical clock timestamps each operation.
* `src/replica.zig`: SQLite keeps each field's winning operation, as columns from which its encoding is rebuilt; interned device keys; signed batches with their leaves; and a version vector of each device's highest sequence number covered.
  * **Sync:** the receiver sends its version vector; the sender returns its winning operations above it, grouped by batch, each batch's header carrying its signature, a bitmap of the operations sent, and only the leaves of those not sent (superseded ones), since the receiver rebuilds the rest from the operations. The receiver checks each batch's signature, then adopts the sender's vector, since it now holds everything the sender does. The frame format is documented above `writeVector`.
  * **Membership:** a library's ID derives from its founder's user key. A device's first write is its certificate, its user's signature over the library and the device key. Members invite users into a causal-length set. A batch is applied only if its device's certificate names a member; batches that aren't yet admitted wait for the rest of the response, which may hold their invitation, and if still not admitted are rejected without being claimed in the receiver's version vector, so they're accepted once the invitation arrives.
  * **Handover:** the founder may hand the library over to a successor, staying a member or leaving. Handovers are a numbered chain (`founders`, fields `000001` on), each valid only if written by a device of the previous generation's founder; a batch whose generation's predecessor hasn't arrived waits like an uninvited one, so the chain is followed in any order.
  * **Removal:** any member may remove another, except the current founder. The removal records, per device of the removed user, the last sequence number the remover had seen; peers accept those devices' writes through it and refuse later ones. A peer that took later writes before hearing of the removal drops them when it does, noting the fields, and `repair` refetches those fields, with shared proofs, from a peer that refused them.
  * **Thin fetch:** a tvOS-style replica takes the winning operations under one title's key prefix, with, for each batch they come from, the operations' indices and one shared proof (the sibling hashes the operations can't derive), and verifies each batch's signature once, keeping no batches or vector. Its first fetch also takes the certificates and members that admit devices.
* `src/net.zig`: the same sync over HTTP: the receiver POSTs its vector to `/sync` and reads the frames from a chunked response.
* `src/sqlite.zig`: hand-written bindings to the system SQLite.
* `src/sigbench.zig`: compares signing schemes on their own.

The library is 4,000 movies and 500 series of 8 seasons of 24 episodes: 100,000 renditions, each with a path, a resolution, and a holding, for 409,500 operations. The divergence step has each peer rename about 0.5% as many episodes, 100 of them the same ones.

## Results

Apple M2, ReleaseFast, Zig 0.17.1, peers in one process; transfer sizes count what a network would carry.

| Step | Time | Operations | Transfer | Database |
|---|---|---|---|---|
| Build on laptop (sign) | 1.1 s | 409,500 | | 55 MB |
| Cold sync (verify) | 1.1 s | 409,502 | 24.5 MB (2.4 MB with zstd), 402 batches | 56 MB |
| Cold sync over HTTP, loopback | 1.1 s | 409,502 | 24.5 MB | 56 MB |
| 1% divergence, both ways | 0.12 s | 4,045 | 256 KB | |
| Thin fetch: one movie, with certificates and members | 1 ms | 9 | 1.8 KB | |
| Thin fetch: one series | 3 ms | 771 | 51 KB | 0.1 MB |

On Linux (Alpine 3.24, aarch64, in a 4-CPU VM, databases on tmpfs), cross-compiled from macOS against Alpine's SQLite, all tests passed and the numbers matched: 0.9 s to build, 1.1 s to sync cold, 0.87 s over HTTP.

Both peers converged, and the replica synced over HTTP matched its source. The unit tests cover conflicts, relays through a third peer, batch limits, tampered operations and signatures, concurrent set additions and removals, thin fetches, and membership: rejecting a device whose user isn't a member, accepting it once invited, admitting batches that arrive before their invitation in the same response, keeping the founder, refusing a removed member's later writes, repairing a peer that took them, handing over, refusing a forged handover, and following a chain of handovers received out of order.

## Findings

* **The design works at scale:** catch-up costs what's missing, not the library's size, and a thin replica verifies a title on its own, with no history.
* **Sign batches, not operations.** The first version signed each operation: 17 s to build, 21 s to sync cold, 150 MB on disk. Signing per batch made both over 10 times faster (now bound by SQLite) and storage 2.7 times smaller. On their own (`src/sigbench.zig`, 409,500 operations of 110 bytes):

  | Scheme | Sign | Verify |
  |---|---|---|
  | One signature per operation | 37.5 µs/op | 46.3 µs/op |
  | The same, verified in batches of 64 (`Ed25519.verifyBatch`) | 37.5 µs/op | 22.0 µs/op |
  | One signature per 1,024 operations, over a Merkle tree | 0.34 µs/op | 0.35 µs/op |

* **Batches follow writes:** a batch is whatever a device writes in one transaction, so an import signs once per 1,024 operations, while a single edit signs alone, which is cheap at human pace.
* **Compress with Zig's own gzip:** its fastest level shrinks a cold sync from 24.5 MB to 4.0 MB in 0.14 s, and its default to 3.3 MB in 0.48 s. The `zstd` tool's fastest level makes 2.3 MB in 0.06 s, but Zig's standard library only decompresses zstd, so a sender would need the C library; gzip needs nothing.
* **Send operations, not their hashes:** sending every batch's leaves made a cold sync 37.5 MB, of which 13 MB were hashes that only compress to themselves (15 MB with zstd). Since the receiver can rebuild the leaves of the operations it gets, sending only superseded operations' leaves cut it to 24.5 MB, and 2.4 MB with zstd at its fastest settings, so compressing sync responses is worth it.
* **Shared proofs pay:** with a proof per operation, a series took 296 KB, mostly 10 hashes per operation; one shared proof per batch cut it to 51 KB, since a title's operations were written together and their proofs overlap.
* **Membership costs one certificate check per batch,** too little to measure.
* **Removal needs no history, but can lose a write:** repair restores what a peer that refused the later writes holds, so a write that only the repairing peer held, and that lost to a refused write, is gone.
* **Not yet tested:** a real network, compression in the HTTP exchange itself, and concurrent removals of the same member with different cutoffs.
