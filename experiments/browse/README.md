# Browse experiment

Tests **Browsing** in [DEVELOPMENT.md](../../DEVELOPMENT.md): intersections of facets at the scale in [AGENTS.md](../../AGENTS.md), answered by SQLite, as a full peer's replica would, and by in-memory bitmaps, as a thin player might hold.

## Running

```sh
zig build --release=fast
./zig-out/bin/browse [database path]     # default /tmp/cinematheque-browse.db
```

It uses the SQLite bindings of the [CRDT experiment](../crdt/README.md).

## Design

[src/main.zig](src/main.zig) generates 4,000 movies and 500 series, each with a year (skewed recent), one to three of 20 genres (skewed toward drama), a cast of 8 from 20,000 people (heavy-tailed, so a few appear often), and one or two of 25 audio languages (85% English). The 300 people in the most titles are the A-listers.

The query is "thrillers or mysteries, starring an A-lister, with English audio, from 2010 on": first the matching titles, then the refinement menu, meaning the count for every remaining genre, language, decade, and kind, and the 20 people in the most matches.

* **SQLite:** a facet table of (facet, value, title) rows, indexed both ways, with an `INTERSECT` per facet and a `GROUP BY` for the menu.
* **Bitmaps:** a bit per title for each of the 58 small facets' values, unions within a facet and intersections across facets, and posting lists for people, who are too many for bitmaps.

## Results

Apple M2, ReleaseFast, averaged over 200 runs; both found the same 395 titles and 69 menu values:

| | Selection | Refinement menu |
|---|---|---|
| SQLite (58,594 facet rows, 2.6 MB) | 3.7 ms | 9.3 ms |
| Bitmaps (33 KB, plus 72 KB of posting lists) | 30 µs | 13 µs |

## Findings

* **SQLite is fast enough for a full peer:** 13 ms for the selection and its menu fits within a frame or two, so every facet change can refresh the menu as the user moves.
* **Bitmaps are 300 to 700 times faster and tiny:** 105 KB covers the whole library's facets, so a thin tvOS player can hold them in memory, fetch them whole, and browse with no queries at all, fetching titles' details only as they come on screen.
* **People are the large facet:** 20,000 values make bitmaps wasteful, so posting lists and a precomputed A-list serve them.
* **Not yet tested:** text facets (search by name), sorting, and keeping bitmaps current as the library syncs.
