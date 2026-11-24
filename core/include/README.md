# The C interface

The core's interface for apps in other languages: [cinematheque.h](cinematheque.h), exported by [capi.zig](../src/capi.zig) and its parts in [capi/](../src/capi), built into `libcinematheque.a` by `zig build`. Swift imports it as `CCinematheque`, by its [module map](module.modulemap). [AGENTS.md](../../AGENTS.md#core-interface) specifies what it does; this is how to call it.

## Conventions

* **The handle:** `cq_open` opens a device's data directory and returns a `cq_library *`, or NULL; `cq_close` stops serving and pairing and frees it. The directory may hold no library yet: `cq_status`'s `library` is null until `cq_found` creates one or pairing joins one.
* **One function per action:** each does one thing, with no argument choosing among actions (adding or removing, sharing or not); a caller with a state in hand picks the function.
* **Strings in** are NUL-terminated UTF-8, copied if kept, so the caller may free them once a call returns. Keys are lowercase hex (64 digits for a person's or a device's).
* **Arrays and records in:** an array is a pointer and a count (`const char *const *urls, size_t count`; NULL with a count of 0 for none); a record is a struct in [cinematheque.h](cinematheque.h), passed by pointer; a kind is a C enum, and a value it doesn't name fails with `InvalidArgument`.
* **Optional arguments:** a pointer (a string, a record's string) is NULL when absent; an integer is -1.
* **Results** are JSON, every string valid UTF-8 (a name that isn't, from a Latin-1 file, gets U+FFFD for its bad bytes). Each `char *` returned is the caller's, freed with `cq_free` (which takes NULL). A result may be JSON `null`, as `cq_served`'s before any sync.
* **Failure:** a function returning `char *` returns NULL, one returning `int` returns -1 (else 0, or a count or port as said), and `cq_error` says why: a Zig error's name, such as `Busy`, `NoLibrary`, or `WrongCode`. It's per thread, so read it on the thread that failed, before its next call. Functions returning `void` can't fail, or fail silently where nothing hangs on them (`cq_race_warm`, `cq_race_lost`).
* **Threads:** functions belong to one thread, the app's main one, on the library's own connection, unless marked *any thread* or *long* below. A long one (crawling, syncing, describing, pairing, looking for devices, reconciling downloads) blocks until done, so call it off the main thread; each runs on a connection of its own. The main connection catches up with other connections' writes before it acts.
* **Writing:** one connection writes as this device at a time. While a long operation writes, most other changes fail with `Busy` rather than wait: try again once it's done. Progress, and changes to a list of this person's that isn't shared, don't need to wait, and don't fail (but for this device's first private write, which certifies its private stream). Long ones that change little (`cq_downloads_configure`, `cq_download_remove`, `cq_describe`) wait their turn instead.
* **Reloading:** a long operation commits as it goes. `cq_data_version` changes once another connection has committed, so poll it and reload (`cq_tiles`, `cq_title`) when it does; `cq_steps` says how far the operation has come. A device that pushes to this one changes `cq_received`.
* **Leaving:** `cq_leave` refuses with `Busy` while another thread has a connection open; none opens while it leaves. So an app stops reconciling (`cq_reconcile_stop`), starts no long operation, and waits out those under way first.

## Errors

The names the apps put in words, and what they mean:

| Error | Meaning |
|---|---|
| `Busy` | Another connection is writing as this device (a long operation), or one is open while leaving |
| `NoLibrary` | This device has no library yet |
| `LibraryExists` | It has one already (founding, or offering to pair) |
| `WrongCode` | Pairing: the code doesn't match the one shown |
| `Closed` | Pairing: the new device stopped offering, after too many wrong codes |
| `Removed` | A sync: this device was removed from the library; call `cq_leave` |
| `NotAMember` | A sync: the other device refused this one as not a member |
| `Refused` | The other device refused a request (it may be too old) |
| `Stale` | The two devices' clocks are more than ten minutes apart |
| `WrongRecipient` | Another device answered at that address |
| `FoundersDevice` | Only the founder's devices may remove the founder's devices |
| `PathTaken` | Downloading: another file is where this one would go |
| `BadAddress` | Not a web address (http or https, with a host, and no query or fragment) |
| `TooMany`, `TooDeep` | Crawling: a source lists more than any library holds, or nests too deeply |
| `InvalidArgument` | An argument isn't of the form the function takes |
| `UnknownQualitySetting` | Crawling: a newer device set where a source's quality comes from in a way this one can't read |

Others are the system's or the network's (`ConnectionRefused`, `ConnectionTimedOut`, `Timeout`, `UnknownHostName`, `HostUnreachable`, `NetworkUnreachable`, `AccessDenied`, ...).

## Opening and the build

| Function | What it does |
|---|---|
| `cq_open(data_dir)` | Opens `data_dir`; if NULL, `$CINEMATHEQUE_DATA`, else the default (see [AGENTS.md](../../AGENTS.md#identity-and-membership)) |
| `cq_close(library)` | Stops serving and pairing, and frees the handle |
| `cq_version()` | *Any thread.* What the build is, as `/version` serves it: `{"app", "version", "revision", "mode", "zig"}` (which app: `macOS app`, `tvOS app`, or `iOS app` for the Apple app's core; its version, as its builder gives it, the Apple app [Version.xcconfig](../../apple/Version.xcconfig)'s; what it was built from, as `git describe --tags` gives it; its optimizing; and Zig's version) |
| `cq_error()` | Why the last call on this thread failed (not freed) |
| `cq_free(text)` | Frees a result |

## Identity and membership

| Function | What it does |
|---|---|
| `cq_status(library)` | This device: `person` (its person's key), `paired` (acting as another of its person's devices), `library` (the library's ID, or null), `founder` (the founder's person key, or null), `members` (how many), `others` (how many other devices its person has, not removed), and `crawl_every` (the library's interval in hours, 0 for only when asked) |
| `cq_found(library)` | Creates a library, founded by this person |
| `cq_members(library)` | The members: an array of `{key, name, founder, you}`, `name` null if unset |
| `cq_member_add(library, person_key)` | Adds a person as a member |
| `cq_member_remove(library, person_key)` | Removes a member, for good: they come back only as someone new |
| `cq_remove_device(library, device_key)` | Removes another device: its writes past where this one has seen them are refused everywhere, and it's served no more; its downloads (a source it marked as its own) are removed too, as no one would serve them again |
| `cq_remove_self(library, successor)` | Removes this device, as it leaves: first handing the library over to `successor` (a person's key, or NULL), if this person founded it; then cutting off its streams just past these writes. Sync so another device takes the removal, then `cq_leave` |
| `cq_leave(library)` | Forgets the library and this device's identity (seeds and replica), stopping serving and pairing, so it can pair again as a new device |

## Pairing

A new device offers to be added and shows a code; a member's device, given the code, adds it.

| Function | What it does |
|---|---|
| `cq_pair_offer(library, name, model)` | On a device with no library: offers to be added, serving `/pair` and advertising it by DNS-SD as `name`, with `model` (an Apple identifier, as `iPhone14,4`, shown by its name, "iPhone 13 mini"; or a name; or empty) for the member's device to show under it, until paired or stopped. Returns its state, as `cq_pair_check` does, with a new code; offering again starts over with another |
| `cq_pair_check(library)` | The offer's state: `{code, paired, closed}`: `code` to show while offering (else null); `paired` once it has the library (and, if added as another of a person's devices, that person); `closed` once it stopped after too many wrong codes. Poll it while showing the code |
| `cq_pair_stop(library)` | Stops offering |
| `cq_pair_person(library, url, code)` | *Long.* On a member's device: adds the device offering at `url` (a `cq_nearby` result whose `pairing` is set), given its code, as another of this person's devices, sending it this person's secret. Returns `{person, device}`: this person's key, and the new device's (to name by `cq_name`). Fails with `WrongCode` or `Closed` |
| `cq_pair_member(library, url, code)` | *Long.* As `cq_pair_person`, but adds the device as a new member's, sending it only the library's founder's key; `person` is the new member's, to add by `cq_member_add` |

## Names and devices

| Function | What it does |
|---|---|
| `cq_set_person_name(library, name)` | Names this person, for every device to show in place of their key |
| `cq_set_device_name(library, name)` | Names this device, as its person's |
| `cq_set_device_model(library, model)` | Records this device's model (an Apple identifier, as `iPhone14,4`, shown by its name; or a name), beside its name, for its person's other devices to show it by; writes nothing if it's recorded already |
| `cq_shown_name(library, name, host)` | What this device names itself as, told `name` by its platform, at `host` (its own, as `lint.local`): `name`, unless generic ("iPhone", "Apple TV", as iOS and tvOS tell apps); then its host's, as other devices show it (`lint`); else null, so it keeps the name pairing gave it. A JSON string, or `null` |
| `cq_name(library, device_key, person_key, name)` | Names another device, as `person_key`'s (one just paired, until it names itself) |
| `cq_devices(library)` | This person's named devices, not removed: an array of `{key, name, you, model, kind}`: `model` as the device recorded it (or null), and `kind`, what kind of device that is, for a symbol to show it by: `iphone`, `ipad`, `ipod`, `appletv`, `vision`, `macbook`, `imac`, `mac_mini`, `mac_studio`, `mac_pro`, `mac`, or `pc` (or null) |
| `cq_nearby(library)` | *Long* (it listens for 2 seconds). Devices found by DNS-SD, other than this one, then those added by address: an array of `{url, device, model, host, person, person_key, ours, member, added, pairing}`: `url` to sync or pair with; `model`, what kind of device, as one offering to be added says (or null); `device` and `person`, their names (or null): the device's as it advertised itself, or by its host where that's generic (an iPhone's "iPhone", at `lint.local.`, as "lint"); `host`, as DNS-SD resolved it (an Apple TV's own name, as tvOS tells apps only "Apple TV"); `person_key`; `ours` (of this library); `member` (its person is one); `added` (by address); and `pairing` (`"new"` for a new device offering to be added, else null) |
| `cq_device_address_add(library, url)` | Adds a device's address, such as one off the network, which syncing then reaches too; on this device only |
| `cq_device_address_forget(library, url)` | Forgets an address added |

## Sources

| Function | What it does |
|---|---|
| `cq_repos(library)` | *Any thread,* on a connection of its own (counting copies reads every one). The sources, by the path they show, devices' downloads last: an array of `{id, url, path, owner, quality_from, quality, skip, copies, managed, unavailable}`: `path`, its server and folders as a person reads them, to join with " › " (the host without `.local` or its port, then its folders, a NAS's shared one left out where there are more than two); `owner`, the key of the device that wrote its address (whose downloads, if `managed`); `quality_from` where its files' quality comes from (`"names"`, `"folder"`, `"named"`, or `"unknown"`, a newer device's setting, by which this one doesn't crawl it), and `quality` the name, if named; `managed` for a device's downloads; `unavailable` its unavailable directories, `{dir, since}` (`dir` relative to the source, empty for the whole of it; `since` in milliseconds since the epoch) |
| `cq_repo_add(library, url, skip)` | Adds a source by URL, as typed (percent-encoded, a `/` added at its end), with a prefix of names to skip (NULL for the default); its files' quality is from their names until set |
| `cq_repo_skip(library, source, skip)` | Sets the prefix of names to skip; applied at the next crawl |
| `cq_repo_quality_from_names(library, source)` | Takes a source's files' quality from their names; copies move at the next crawl |
| `cq_repo_quality_from_folder(library, source)` | Takes it from the first folder within the source |
| `cq_repo_quality_named(library, source, name)` | Names one quality for all its files |
| `cq_repo_name(library, source, name)` | Names a source (by ID) as its owner calls it, as a folder's own name ("TV Shows", "Archive1841") its address had to put otherwise (`/tv-shows/`); `cq_repos`' `path` ends with it. Only its owner's naming counts; nothing's written if it's named so already |
| `cq_repo_remove(library, source)` | Removes a source (by ID or URL) and its copies, for every device |
| `cq_remove_unavailable(library, source, dir)` | Removes an unavailable directory's copies, as if deleted |

## Crawling, syncing, and describing

| Function | What it does |
|---|---|
| `cq_crawl(library)` | *Long.* Crawls every source but devices' downloads, committing each as it goes, then describes what's new (covers and metadata), prioritized titles first. Returns an array, one per source, of `{url, files, titles, covers, error, crawl_ms, total_ms, requests, reused, changed, skipped}`: `error` null or why its crawl failed; `skipped` null, or why it wasn't crawled (`"lately"`, `"manual"`, or `"downloads"`, a device's own); `titles` added; `covers` always 0; listing's and the whole crawl's times; listings read and reused; copies added, changed, or removed |
| `cq_crawl_full(library)` | *Long.* As `cq_crawl`, listing every directory afresh, so files rewritten in place (retagged) are seen |
| `cq_crawl_due(library)` | *Long.* As `cq_crawl`, for a refresh not asked for, once synced: skips sources a device crawled within the library's interval, give or take a 24th of it (`skipped` `"lately"`), or every source, if it's crawled only when asked (`"manual"`) |
| `cq_crawl_every(library, hours)` | Sets the library's interval, for every device: 1, 3, 24 (the default), or 168 hours, or 0 for only when asked |
| `cq_sync(library)` | *Long.* Syncs with every device of this library found or added. Returns an array of `{url, name, new, sent, error}`: the device's advertised name, operations won and pushed, and `error` (null, or why; `Removed` means this device was) |
| `cq_sync_with(library, url)` | *Long.* As `cq_sync`, with the device at `url` alone |
| `cq_sync_known(library)` | *Long.* As `cq_sync` with every device, but with those the last such sync found (and those added), without looking for them again, unless none has; for a change to reach other devices at once |
| `cq_describe(library, item_key)` | *Long.* Reads an item's metadata (an episode's title, description, and duration) from its first copy, if an MP4 |
| `cq_prioritize(library, title_keys, count)` | *Any thread.* The titles a crawl describes first, by their keys (those on screen) |
| `cq_data_version(library)` | A number that changes when another connection has committed; -1 with no library |
| `cq_steps(library)` | *Any thread.* How far the long operation running has come: `{phase, done, total}`, `phase` `"crawling"`, `"describing"`, `"syncing"`, or null |

## Serving

| Function | What it does |
|---|---|
| `cq_serve(library, port, folders, count)` | Serves the library to devices and folders as sources (each a `cq_folder`, `{prefix, path}`: the path it's served at, and the folder), on `port`, else 8008, else any free port, advertised by DNS-SD, on a task of its own until stopped or closed. Returns once listening, with the port; serving again restarts it |
| `cq_stop_serving(library)` | Stops serving |
| `cq_served(library)` | The last sync served: `{device, name, operations, at}` (the device's key and name, operations sent, and when, in milliseconds since the epoch), or `null` |
| `cq_received(library)` | The last push taken, in the same form (operations won); reload when it changes |

## Browsing

| Function | What it does |
|---|---|
| `cq_tiles(library)` | *Any thread,* on a connection of its own (it reads the whole catalog). The tiles, below |
| `cq_title(library, key)` | One title, below; fails with `NoSuchTitle` |
| `cq_thumbhash(hash_base64, rgba, width, height)` | *Any thread.* Renders a tile's `thumb` into `rgba` (32×32×4 bytes: RGBA, not premultiplied, 32 pixels on its longer side), setting `width` and `height`. Returns 0, or -1 if it isn't a ThumbHash |

A **tile** is a movie or a season, with this person's progress ([views.zig](../src/views.zig)):

| Field | |
|---|---|
| `key`, `name`, `year` | The title's key, name, and year (or null) |
| `kind`, `season` | `"movie"` or `"series"`; a season's number, else null |
| `cover` | Null, or `{url, offset, length, stamp}`: a byte range to fetch, and what changes when it does |
| `thumb` | Null, or the cover's placeholder, a ThumbHash in base64 (`"-"` for a cover not a JPEG) |
| `watched`, `progress`, `elapsed`, `runtime`, `started` | Every item watched; the share of its running time played (0 to 1); milliseconds played, of how many; whether any item has progress |
| `items`, `unavailable` | How many items it holds; whether every copy it has is unavailable |
| `order` | Its title's place in each order, `{title, released, added, modified, watched}`, each counted from what comes first in the order's usual direction, null for no place (see [AGENTS.md](../../AGENTS.md#library)) |

A **title**: `key`, `name`, `year`, `aliasOf` (the key it's an alias of, or null), `aliases`, `fields` (its metadata: `description`, `genre`, `released`, ...), `covers` (by field, `art` or `art:s01`..., each as a tile's `cover`), `seasons` (a series', in order, specials, 0, last), and `items`, in order (each season's episodes by number, specials last), each with:

| Field | |
|---|---|
| `key` | The item's key |
| `season`, `number`, `aired` | An episode's season and number (a special's number null; a dated one's season its year, its number its month and day, and `aired` its date, `YYYY-MM-DD`) |
| `label`, `name`, `version` | What to call it: "Episode 3", "Special", "March 12", or a version's name; its name in a list ("3. Title"); a movie's item's version ("Standard", "Extended"), empty for an episode |
| `fields` | Its metadata (an episode's `title`, `description`, `duration`) |
| `position`, `duration`, `watched` | This person's progress, in milliseconds |
| `next` | Whether Play plays it, of its season or of the movie's versions |
| `described` | Whether it was described from one of its files as that file is now; else describe it (`cq_describe`) as it's shown |
| `qualities` | Each `{label, name, short, height, copies}`: as keyed, as its sources name it, for a picker ("4K HDR"), its resolution's lines (or null); `copies` each `{url, size, mtime, source, unavailable}`, `url` ready to play |

## Copy racing

| Function | What it does |
|---|---|
| `cq_race(library, urls, count)` | *Long* (up to 1.5 seconds), *any thread.* Takes an item's copies' URLs, in the order a player would try them, and returns them, a JSON array, in the order to try: those whose servers answer first; one that failed lately, last |
| `cq_race_lost(library, url)` | *Any thread.* Notes that a copy didn't load, so its server goes last for a while |
| `cq_race_warm(library, urls, count)` | *Long, any thread.* Looks up the names of the servers of URLs (the sources'), so the first race finds them answered |

## Downloads

This device's own: kept in a folder, and served as a source of its own that no device crawls.

| Function | What it does |
|---|---|
| `cq_downloads_configure(library, dir, served_at)` | *Long,* on a connection of its own. Sets the folder and the URL it's served at |
| `cq_download(library, key, quality)` | Wants a title's, a season's (`<title key>/e/s01`), or an item's files kept, each item as of now, in `quality` (NULL or empty: the one most items have), until deleted |
| `cq_download_next(library, title_key, choice)` | A series' choice of episodes: the next N after where this person is (`"3"`), the watched going as their space is needed; `"all"`, kept however watched; or `""` or `"0"`, none |
| `cq_download_remove(library, key)` | *Long,* on a connection of its own. Deletes a title's, season's, or item's files held here, and stops wanting them |
| `cq_download_sizes(library, key, choices, count, quality)` | What downloading would come to, for each `cq_download_choice`: `CQ_DOWNLOAD_NEXT` with a `count` of at least 1, or `CQ_DOWNLOAD_ALL`, a series' choice for `key`, its title; or `CQ_DOWNLOAD_OWN`, `key`'s own files in `quality`. Returns an array of `{choice, size, needed}`, in bytes, `choice` as `cq_download_next` takes it (`""` for `key`'s own), `needed` what isn't here yet |
| `cq_downloads(library)` | All of it: `{dir, source, held, wanted, next, ahead, free, floor, running, done_mb, total_mb, fetching}`: the folder and its source's ID (null if unset); `held`, each `{item, size, only}` (the only copy); `wanted`, `{key, quality}`; `next`, each series' `{title, choice}`; `ahead`, the items those choices come to now; free bytes (or null) and the floor kept free; whether reconciling runs, and its megabytes done of how many; and the file under way, `{item, done, size}`, or null |
| `cq_reconcile(library)` | *Long,* on a connection of its own. Fetches, records, and deletes to match what's kept, then returns `{fetched, kept, deleted, failed, no_room, held, error, busy}` (`no_room`: files left to keep the floor free; `held`: files waiting while downloads are held). If one runs already, asks it to run again and returns at once with `busy` |
| `cq_reconcile_stop(library)` | *Any thread.* Stops reconciling under way: the file coming at its next mebibyte (its `.part` kept, to resume), and none after; the next `cq_reconcile` runs afresh. As before leaving, which refuses while it runs |
| `cq_downloads_hold(library)` | *Any thread.* Holds new downloads back while a stream plays; one under way finishes |
| `cq_downloads_resume(library)` | *Any thread.* Lets them go; `cq_reconcile` then fetches what waited |

## Progress and lists

This person's own, written on this device's private stream (see [AGENTS.md](../../AGENTS.md#library)).

| Function | What it does |
|---|---|
| `cq_set_progress(library, item_key, position_ms, duration_ms)` | Records where this person stopped in an item (e.g., `t/m/alien/1979/v/-`); a position in the first 10 seconds empties it |
| `cq_mark_watched(library, item_key)` | Marks an item watched |
| `cq_mark_unwatched(library, item_key)` | Marks an item unwatched, emptying its position too, so it plays from the beginning |
| `cq_remove_progress(library, item_key)` | Removes this person's progress in an item: its position and watched mark |
| `cq_lists(library)` | This person's lists, then other members' shared ones, each by name: an array of `{id, name, owner, ownerName, mine, mode, titles, wanted}`: another member's `id` is `<owner>/<id>`, and the Watchlist's `watchlist`; `owner`, its person's key; `ownerName`, another member's name, if set; `mine` (only its owner changes it); `mode`, `"private"` (its owner's alone) or `"shared"` (every member sees it); `titles`, movies' title keys and seasons' tiles (`<title key>#<season>`); `wanted`, the placeholders among them, `{key, name, note}` |
| `cq_list_create(library, name)` | Makes a list; returns its ID, as a JSON string |
| `cq_list_rename(library, id, name)` | Renames a list of this person's |
| `cq_list_remove(library, id)` | Deletes a list, for good |
| `cq_list_add_title(library, id, title_key)` | Puts a movie or season (keyed as `cq_lists` has them) on a list |
| `cq_list_remove_title(library, id, title_key)` | Takes one off |
| `cq_list_want(library, id, want)` | Puts a title not in the library yet on a list, as a placeholder: `want` is a `cq_want`, its `kind` (`CQ_MOVIE` or `CQ_SERIES`) and `name`, with `year`, `season` (a series', else the first), and `note` optional. Returns its key, as a JSON string, keyed as its file will be |
| `cq_list_edit_want(library, id, key, want)` | Changes the placeholder keyed `key` on a list, as `want` gives it anew: keyed afresh, its old key taken off in the same change. Returns its key, as a JSON string |
| `cq_list_share(library, id)` | Shares a list of this person's with every member |
| `cq_list_stop_sharing(library, id)` | Makes it theirs alone again |
