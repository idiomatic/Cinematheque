# The C interface

The core's interface for apps in other languages: [cinematheque.h](cinematheque.h), exported by [capi.zig](../src/capi.zig) and its parts in [capi/](../src/capi), built into `libcinematheque.a` by `zig build`. Swift imports it as `CCinematheque`, by its [module map](module.modulemap). [AGENTS.md](../../AGENTS.md#core-interface) specifies what it does; this is how to call it.

## Conventions

* **The handle:** `cq_open` returns a `cq_library *` (or NULL); `cq_close` stops serving and pairing and frees it. Until `cq_found` or pairing, `cq_status`'s `library` is null.
* **One function per action:** no argument chooses among actions; a caller holding a state picks the function.
* **Strings in:** NUL-terminated UTF-8, copied if kept. Keys are lowercase hex (64 digits for a person's or device's).
* **Arrays and records in:** an array is a pointer and a count (NULL and 0 for none); a record, a struct in [cinematheque.h](cinematheque.h), by pointer; a kind, a C enum, an unnamed value failing with `InvalidArgument`. An absent pointer is NULL, an absent integer -1.
* **Results:** JSON, every string valid UTF-8 (bad bytes as U+FFFD), possibly `null`; each `char *` is the caller's, freed by `cq_free` (which takes NULL).
* **Failure:** `char *` functions return NULL, `int` ones -1 (else 0, or a count or port), and `cq_error` names why (a Zig error's name), per thread: read it on the failing thread before its next call. `void` functions can't fail, or fail silently where nothing hangs on them.
* **Threads:** functions belong to the app's main thread, on the library's own connection, unless marked:
  * *Any:* any thread.
  * *Long:* blocks until done, so call it off the main thread; on a connection of its own. The main connection catches up with others' writes before acting.
  * *Own:* any thread, on a connection of its own, but brief.
* **Writing:** one connection writes as this device at a time. While a long one writes, most changes fail with `Busy`; retry once it's done. Progress and a private list's changes neither wait nor fail (but this device's first private write, certifying its private stream). `cq_downloads_configure`, `cq_download_remove`, and `cq_describe` wait their turn.
* **Reloading:** long operations commit as they go; poll `cq_data_version` and reload (`cq_tiles`, `cq_title`) when it changes, as it does on another connection's commit or a device's push. `cq_steps` tells how far one has come.
* **Leaving:** `cq_leave` refuses with `Busy` while another connection is open, and none opens while it leaves, so stop reconciling (`cq_reconcile_stop`) and wait out long operations first.

## Errors

| Error | Meaning |
|---|---|
| `Busy` | Another connection writes as this device, or one is open while leaving |
| `NoLibrary` | No library yet |
| `LibraryExists` | One already (creating, or offering to pair) |
| `WrongCode` | Pairing: the code doesn't match |
| `Closed` | Pairing: the new device stopped offering after too many wrong codes |
| `Removed` | Sync: this device was removed; call `cq_leave` |
| `NotAMember` | Sync: the other device refused this one as no member |
| `Refused` | The other device refused a request |
| `Stale` | The devices' clocks are over ten minutes apart |
| `WrongRecipient` | Another device answered at that address |
| `PathTaken` | Downloading: another file is where this one would go |
| `BadAddress` | Not an http(s) address with a host and no query or fragment |
| `TooMany`, `TooDeep` | Crawling: a source lists more than any library holds, or nests too deeply |
| `InvalidArgument` | An argument isn't of the form taken |
| `NoSuchTitle` | `cq_title`: no such key |
| `UnknownQualitySetting` | Crawling: a newer device set a source's quality in a way this one can't read |

Others are the system's or network's (`ConnectionRefused`, `Timeout`, `UnknownHostName`, `AccessDenied`, ...).

## Opening and the build

| Function | |
|---|---|
| `cq_open(data_dir)` | Opens `data_dir`, else `$CINEMATHEQUE_DATA`, else the [default](../../AGENTS.md#identity-and-membership) |
| `cq_close(library)` | Stops serving and pairing; frees the handle |
| `cq_version()` | *Any.* `/version`'s `{app, version, revision, mode, zig}`: `app` `macOS app`, `tvOS app`, or `iOS app` for the Apple app; `version` from its builder ([Version.xcconfig](../../apple/Version.xcconfig)); `revision` by `git describe --tags`; `mode`, its optimizing |
| `cq_error()` | Why this thread's last call failed (not freed) |
| `cq_free(text)` | Frees a result |

## Identity and membership

| Function | |
|---|---|
| `cq_status(library)` | `{person, device, paired, library, members, others, crawl_every}`: keys (`device` for `cqdevice://<key>/<path>`); `paired`, acting as another of its person's devices; the library's ID or null; member count; its person's other devices, not removed; the interval in hours, 0 for Manually |
| `cq_found(library)` | Creates a library, this person its first member |
| `cq_members(library)` | `[{key, name, you}]`, `name` null if unset |
| `cq_member_add(library, person_key)` | Adds a member |
| `cq_member_remove(library, person_key)` | Removes a member, for good |
| `cq_remove_device(library, device_key)` | Removes another device, its streams cut where this one saw them, and its downloads |
| `cq_remove_self(library)` | Removes this device, its streams cut just past this; sync, then `cq_leave` |
| `cq_leave(library)` | Forgets the library, seeds, and replica, stopping serving and pairing |

## Pairing

| Function | |
|---|---|
| `cq_pair_offer(library, name, model)` | On a device without a library: serves `/pair` and advertises it as `name`, with `model` (an Apple identifier such as `iPhone14,4`, a name, or empty), until paired or stopped. Returns `cq_pair_check`'s state with a new code; offering again starts over |
| `cq_pair_check(library)` | `{code, paired, closed}`: the code while offering (else null); whether it has the library (and its person, if another's device); whether it stopped after too many wrong codes. Poll while showing the code |
| `cq_pair_stop(library)` | Stops offering |
| `cq_pair_person(library, url, code)` | *Long.* Adds the device offering at `url` (a `cq_nearby` result with `pairing`) as this person's, sending its seed. Returns `{person, device}`, the device to name by `cq_name`. Fails with `WrongCode` or `Closed` |
| `cq_pair_member(library, url, code)` | *Long.* As `cq_pair_person`, as a new member's device, sending only the library's key; add `person` by `cq_member_add` |

## Names and devices

| Function | |
|---|---|
| `cq_set_person_name(library, name)` | Names this person |
| `cq_set_device_name(library, name)` | Names this device |
| `cq_set_device_model(library, model)` | Records this device's model (as `cq_pair_offer` takes it), unless recorded already |
| `cq_shown_name(library, name, host)` | A JSON string: what this device calls itself, told `name` by its platform at `host` (`lint.local`): `name` unless generic ("iPhone", "Apple TV"), then the host's (`lint`), else `null`, keeping pairing's name |
| `cq_name(library, device_key, person_key, name)` | Names another device, as `person_key`'s |
| `cq_devices(library)` | This person's named devices, not removed: `[{key, name, you, model, kind}]`, `kind` for a symbol: `iphone`, `ipad`, `ipod`, `appletv`, `vision`, `macbook`, `imac`, `mac_mini`, `mac_studio`, `mac_pro`, `mac`, `pc`, or null |
| `cq_nearby(library)` | *Long* (2 seconds). Devices found by DNS-SD, then those added by address: `[{url, device, model, host, person, person_key, ours, member, added, pairing}]`: `device` as advertised, or its host's where generic; `host` as resolved; `ours`, of this library; `member`, its person is one; `added`, by address; `pairing`, `"new"` for a device offering, else null |

## Sources

| Function | |
|---|---|
| `cq_repos(library)` | *Own.* Sources by shown path, devices' downloads last: `[{id, url, address, path, owner, quality_from, quality, skip, copies, managed, unavailable}]`: `url` (a device's folder's `cqdevice://…`); `address`, where it's reached now (null until its device says); `path`, segments to join with " › " ([shown](../../AGENTS.md#sources)); `owner`, the device that wrote it; `quality_from`, `"path"`, `"named"` (with `quality`), or `"unknown"` (a newer device's, uncrawled); `managed`, a device's downloads; `unavailable`, `[{dir, since}]` (`dir` relative, empty for all of it; `since` in epoch ms) |
| `cq_repo_add(library, url, skip)` | Adds a source as typed (percent-encoded, `/` appended), skipping names with `skip` (NULL for the default); quality from names |
| `cq_repo_skip(library, source, skip)` | Sets the prefix to skip, from the next crawl |
| `cq_repo_quality_from_path(library, source)` | Quality from names and folders ([Qualities](../../AGENTS.md#library)), from the next crawl |
| `cq_repo_quality_named(library, source, name)` | One quality for all its files |
| `cq_repo_name(library, source, name)` | Names a source (by ID) as its owner calls it ("TV Shows" for `/tv-shows/`), ending `path`; only its owner's counts |
| `cq_repo_remove(library, source)` | Removes a source (by ID or URL) and its copies everywhere |
| `cq_set_served(library, served)` | Records where this device serves its folders now (`http://firefly.local:58275/`) |
| `cq_remove_unavailable(library, source, dir)` | Removes an unavailable directory's copies |

## Crawling, syncing, and describing

| Function | |
|---|---|
| `cq_crawl(library)` | *Long.* Crawls every source but downloads, committing as it goes, then describes, prioritized titles first. Returns per source `[{url, files, titles, covers, error, crawl_ms, total_ms, requests, reused, changed, skipped}]`: `error` or null; `skipped` null, `"lately"`, `"manual"`, `"downloads"`, or `"away"` (its device hasn't said where it serves); titles added; `covers` always 0; listing and total times; listings read and reused; copies changed |
| `cq_crawl_full(library)` | *Long.* As `cq_crawl`, every directory listed afresh |
| `cq_crawl_source(library, source)` | *Long.* As `cq_crawl`, one source (ID or URL), as a volume comes or goes |
| `cq_describe_all(library)` | *Long,* on a connection of its own, beside other long operations. Describes every item no describing has read (an episode's title, description, and duration), each from an MP4 copy (a server's first, none unavailable): titles this person has begun first, those `cq_prioritize` names before all; 4 workers, none beginning while downloads are held (a stream playing); committing as it goes. Returns `{described, failed}`; one out of reach is tried at the next sweep |
| `cq_describe_steps(library)` | *Any thread.* How far the sweep has come, as `cq_steps` tells other operations (`phase` `episodes`, or null) |
| `cq_describe_stop(library)` | *Any thread.* Stops the sweep: no more items begin, and it returns once those under way are done (before leaving) |
| `cq_crawl_due(library)` | *Long.* As `cq_crawl`, for a refresh not asked for: skips sources crawled within the interval (`"lately"`), or all if Manually (`"manual"`) |
| `cq_crawl_every(library, hours)` | Sets the interval: 1, 3, 24 (default), 168, or 0 for Manually |
| `cq_sync(library)` | *Long.* Syncs with every device found or added: `[{url, name, new, sent, error}]`, operations won and pushed, `error` null or why (`Removed`: this device was) |
| `cq_sync_with(library, url)` | *Long.* As `cq_sync`, with one device |
| `cq_sync_known(library)` | *Long.* As `cq_sync`, with those the last sync found and those added, looking again only if none |
| `cq_describe(library, item_key)` | *Long.* Reads an item's metadata from its first copy, if an MP4 |
| `cq_prioritize(library, title_keys, count)` | *Any.* Titles a crawl describes first (those on screen) |
| `cq_data_version(library)` | Changes on another connection's commit; -1 without a library |
| `cq_steps(library)` | *Any.* `{phase, done, total}`, `phase` `"crawling"`, `"describing"`, `"syncing"`, or null |

## Serving

| Function | |
|---|---|
| `cq_serve(library, port, folders, count)` | Serves the library, and folders (`cq_folder`, `{prefix, path}`) as sources, on `port`, else 8008, else any, advertised, until stopped or closed. Returns the port once listening; serving again restarts |
| `cq_stop_serving(library)` | Stops serving |

## Browsing

| Function | |
|---|---|
| `cq_tiles(library)` | *Own* (reads the whole catalog). The tiles |
| `cq_title(library, key)` | One title |

A **tile**, a movie or season with this person's progress ([views.zig](../src/views.zig)):

| Field | |
|---|---|
| `key`, `name`, `year` | The title's; `year` or null |
| `kind`, `season` | `"movie"` or `"series"`; a season's number, else null |
| `cover` | Null or `{url, offset, length, stamp}`: a byte range, and what changes with it |
| `aspect` | Null or the cover's width over height |
| `watched`, `progress`, `elapsed`, `runtime`, `started` | All watched; share played (0 to 1); ms played, of how many; any item begun |
| `items`, `unavailable` | Item count; every copy unavailable |
| `order` | `{title, released, added, modified, watched}`, places from each order's start, null for none ([orders](../../AGENTS.md#library)) |

A **title:** `key`, `name`, `year`, `fields` (`description`, `genre`, `released`, ...), `covers` (by field, `art`, `art:s01`..., each a tile's `cover`), `seasons` (in order, specials, 0, last), and `items` in order, each:

| Field | |
|---|---|
| `key` | The item's |
| `season`, `number`, `aired` | An episode's (a special's `number` null; a dated one's season its year, number its month and day, `aired` `YYYY-MM-DD`) |
| `label`, `name`, `version` | "Episode 3", "Special", "March 12", or a version's name; "3. Title"; a movie's version ("Extended"), empty for an episode |
| `fields` | `title`, `description`, `duration` |
| `position`, `duration`, `watched` | This person's progress, in ms |
| `next` | Play plays it |
| `described` | Described from its file as it is now; else `cq_describe` it when shown |
| `qualities` | `[{label, name, short, height, copies}]`: as keyed, as named, short ("4K HDR"), lines or null; `copies` `[{url, size, mtime, source, unavailable}]` |

## Copy racing

| Function | |
|---|---|
| `cq_race(library, urls, count)` | *Long* (up to 1.5 seconds), *any.* An item's copies' URLs in order to try: fastest servers first, lately failed last |
| `cq_race_lost(library, url)` | *Any.* A copy didn't load; its server goes last for a while |
| `cq_race_warm(library, urls, count)` | *Long, any.* Looks up the sources' servers' names ahead |

## Downloads

This device's own, served as a source no device crawls.

| Function | |
|---|---|
| `cq_downloads_configure(library, dir, served_at)` | *Long.* Sets the folder and its URL |
| `cq_download(library, key, quality)` | Wants a title's, season's (`<title key>/e/s01`), or item's files, items as of now, in `quality` (NULL or empty: most items'), until deleted |
| `cq_download_next(library, title_key, choice)` | A series' choice: `"3"` (the next N), `"all"`, or `""`/`"0"` (none) |
| `cq_download_remove(library, key)` | *Long.* Deletes a title's, season's, or item's files here and stops wanting them |
| `cq_download_sizes(library, key, choices, count, quality)` | Per `cq_download_choice` (`CQ_DOWNLOAD_NEXT` with `count` ≥ 1, `CQ_DOWNLOAD_ALL`, or `CQ_DOWNLOAD_OWN`, `key`'s own in `quality`): `[{choice, size, needed}]` in bytes, `choice` as `cq_download_next` takes it (`""` for own), `needed` not here yet |
| `cq_downloads(library)` | `{dir, source, held, wanted, next, ahead, free, floor, running, done_mb, total_mb, fetching}`: folder and source ID (null if unset); `held` `[{item, size, only}]`; `wanted` `[{key, quality}]`; `next` `[{title, choice}]`; `ahead`, items the choices come to; free bytes (or null) and floor; reconciling, MB done of total; `fetching` `{item, done, size}` or null |
| `cq_reconcile(library)` | *Long.* Fetches, records, and deletes to match what's kept: `{fetched, kept, deleted, failed, away, no_room, held, error, busy}` (`away`: copies all away, for next time; `no_room`: left to keep the floor; `held`: waiting on a hold). If one runs, asks it to rerun and returns `busy` |
| `cq_reconcile_stop(library)` | *Any.* Stops reconciling: the file under way at its next mebibyte (`.part` kept), none after |
| `cq_downloads_hold(library)` | *Any.* Holds new downloads while a stream plays |
| `cq_downloads_resume(library)` | *Any.* Releases them for `cq_reconcile` |

## Progress and lists

This person's, on this device's [private stream](../../AGENTS.md#library).

| Function | |
|---|---|
| `cq_set_progress(library, item_key, position_ms, duration_ms)` | Records where this person stopped; the first 10 seconds empties it |
| `cq_mark_watched(library, item_key)` | Marks watched |
| `cq_mark_unwatched(library, item_key)` | Marks unwatched, emptying the position |
| `cq_remove_progress(library, item_key)` | Removes position and mark |
| `cq_lists(library)` | This person's lists, then others' shared ones, by name: `[{id, name, owner, ownerName, mine, mode, titles, wanted}]`: another's `id` `<owner>/<id>`, the Watchlist's `watchlist`; `ownerName` if set; `mode` `"private"` or `"shared"`; `titles`, movies' keys and seasons' `<title key>#<season>`; `wanted`, placeholders `[{key, name, note}]` |
| `cq_list_create(library, name)` | Makes a list; returns its ID as a JSON string |
| `cq_list_rename(library, id, name)` | Renames one of this person's |
| `cq_list_remove(library, id)` | Deletes one, for good |
| `cq_list_add_title(library, id, title_key)` | Adds a movie or season (keyed as `cq_lists` has them) |
| `cq_list_remove_title(library, id, title_key)` | Takes one off |
| `cq_list_share(library, id)` | Shares with every member |
| `cq_list_stop_sharing(library, id)` | Makes private again |
