# Peer

The command-line desktop peer, `cinematheque`, for macOS and Linux, on the [core](../core/README.md).

```sh
zig build --release=fast
./zig-out/bin/cinematheque [--home DIR] NOUN VERB [ARGUMENTS]
./test.sh       # peers, a generated repository, sync, and every command
```

[usage.txt](src/usage.txt) lists the commands, and is also their help. The peer's home (by default `~/Library/Application Support/Cinematheque` on macOS, and `$XDG_DATA_HOME/cinematheque` or `~/.local/share/cinematheque` on Linux) holds the device's identity (its seed, and its user's seed if linked), the library's founder key, and the replica, whose `local` state keeps what's this device's alone: crawl snapshots and added peers.

## Sources

* [main.zig](src/main.zig): parsing the command line, help, and dispatch to a function per noun or action.
* [commands.zig](src/commands.zig): the state nouns (`user`, `library`, `member`, `repo`, `title`, `alias`, `playhead`, `agent`), and `crawl` and `refresh`.
* [network.zig](src/network.zig): `serve`, `sync`, and `peer`: serving on 8008 or a free port, discovery, and peers added by URL.
* [agent.zig](src/agent.zig): the macOS launch agents.
* [test.sh](test.sh) and [test/gen.zig](test/gen.zig): the end-to-end test, on a generated repository of sparse files (`zig build gen` builds the generator), which a peer serves as media.

## A session

```sh
# on hal
cinematheque library create
cinematheque repo add "http://nas/Video/Movies/Very Fast 720p30/" --rendition "Very Fast 720p30"
cinematheque crawl
cinematheque title review
cinematheque serve &

# on perihelion
cinematheque library join HAL_KEY
cinematheque user show

# on hal
cinematheque member add PERIHELION_KEY

# on perihelion
cinematheque sync
```

## On a real repository

Crawling a Caddy server on a NAS over Wi-Fi, four renditions of movies and TV (50,000 files, 4,000 of them in housekeeping folders the repository skips), took under a second with 32 workers and ingested 40,000 holdings of 5,000 titles; a second crawl took 11 requests instead of 790. Review found 12 close matches (7 years off by one, 4 years missing, 1 spelling) and 39 duplicate files: `.m4v` and `.mp4` copies, episode codes used twice, and a part beside its whole. A second peer synced the library (90,000 operations) in 0.4 s, and an alias reached it as one operation.
