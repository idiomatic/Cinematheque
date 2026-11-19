// Cinematheque's core, for apps in C and languages that call it (Swift).
// Results are JSON strings, freed with cq_free; on failure, functions
// return NULL or -1, and cq_error says why. See src/capi.zig, which
// documents each result's form.
//
// Functions belong to one thread, the app's main one, except the long ones
// (cq_crawl, cq_sync, cq_describe), which may run on any thread. While a
// long one runs, other changes to the library fail with "Busy"; progress
// and the watchlist don't wait.

#ifndef CINEMATHEQUE_H
#define CINEMATHEQUE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cq_library cq_library;

// Opens this device's home home_dir; if NULL, $CINEMATHEQUE_HOME, or else the
// default. It may hold no library yet.
cq_library *cq_open(const char *home_dir);
void cq_close(cq_library *library);

// Identity and membership.
char *cq_status(cq_library *library);
// Creates a library, founded by this person; joining one is by pairing.
int cq_found(cq_library *library);
// Leaves the library, as a device removed from it does (a sync's error is
// "Removed"), forgetting it and this device's identity, to pair afresh.
int cq_leave(cq_library *library);
// Pairing: on a new device, before it has a library, offering to pair
// (serving and advertising as name), to pair it to a member's person or (join
// nonzero) to join as a new member, with a code to show; and checking
// whether it's paired (taking the library, and if pairingAsYours, the person's
// secret) or closed (too many wrong codes). On a member's device, long,
// pairing the one offering at url (a pairing device's) given its code, which
// returns its keys (person, to add a new member by, and device, to name it
// by with cq_name).
char *cq_pair_offer(cq_library *library, const char *name, int join);
char *cq_pair_check(cq_library *library);
void cq_pair_stop(cq_library *library);
char *cq_pair(cq_library *library, const char *url, int join, const char *code);
char *cq_members(cq_library *library);
int cq_member(cq_library *library, const char *person_key, int add);

// Sources; rendition and skip may be NULL, for the default or no
// change.
char *cq_repos(cq_library *library);
int cq_repo_add(cq_library *library, const char *url, const char *rendition, const char *skip);
int cq_repo_set(cq_library *library, const char *source, const char *rendition, const char *skip);
int cq_repo_remove(cq_library *library, const char *source);
// Forgets an unavailable directory of a source, as if deleted.
int cq_remove_unavailable(cq_library *library, const char *source, const char *dir);
// Long (up to 1.5 s), any thread: copy racing. A JSON array of an item's
// copies' URLs in, in the order to try them out: those whose servers answer
// first. cq_race_lost notes a copy that didn't load.
char *cq_race(cq_library *library, const char *urls_json);
void cq_race_lost(cq_library *library, const char *url);

// Downloads, this device's: kept in dir, served at served_at (a source
// of its own, never crawled). drop_watched deletes downloads watched since
// fetched at once, else only as space is needed; either way only once
// another source holds them, and never kept ones (cq_keep).
// cq_download wants a title, season
// (TITLE/e/s01), or item kept, in a rendition (null: the commonest);
// cq_download_next downloads a series' next episodes as it's watched (0
// stops); cq_download_remove
// deletes and stops wanting; cq_downloads is all of it as JSON;
// cq_reconcile (long, its own connection) fetches and deletes to
// match, returning at once with "busy" if one runs, which then runs again.
int cq_downloads_configure(cq_library *library, const char *dir, const char *served_at, int drop_watched);
int cq_download(cq_library *library, const char *key, const char *rendition);
int cq_download_remove(cq_library *library, const char *key);
int cq_download_next(cq_library *library, const char *title_key, int episodes);
// Keeps a download (an item), so it's never deleted as watched; 0 lets it
// go.
int cq_keep(cq_library *library, const char *item_key, int on);
char *cq_downloads(cq_library *library);
char *cq_reconcile(cq_library *library);
// Holds downloads back (nonzero) while a stream plays: none begins; 0
// lets them go. Any thread.
void cq_downloads_hold(cq_library *library, int on);

// Long: crawling every source and describing what's new (committing
// as it goes, so reload when cq_data_version changes), syncing with a device (or,
// if url is NULL, every device found or added), and reading an item's
// metadata from its file.
char *cq_crawl(cq_library *library);
char *cq_sync(cq_library *library, const char *url);
// The last sync this device served, while serving: which device asked, and
// how many operations it was sent.
char *cq_served(cq_library *library);
// The last push this device took, while serving: from which device, and how
// many of its operations won.
char *cq_received(cq_library *library);
int cq_describe(cq_library *library, const char *item_key);

// While a crawl describes, which titles to take first (a JSON array of
// title keys, e.g., the tiles on screen); any thread. And a number that
// changes when a long operation has committed changes, to know when to
// reload.
int cq_prioritize(cq_library *library, const char *title_keys_json);
long long cq_data_version(cq_library *library);

// How far the long operation running has come: a JSON object with
// "phase" ("crawling", "describing", "syncing", or null), and "done" and
// "total" steps of it. Any thread.
char *cq_steps(cq_library *library);

// Browsing: the grid's tiles, with their covers' byte ranges, and one
// title, with its metadata and each copy's playable URL.
char *cq_tiles(cq_library *library);
char *cq_title(cq_library *library, const char *key);

// A tile's placeholder (its `thumb`, a ThumbHash in base64) as RGBA
// pixels, not premultiplied, 32 on the longer side, into 32*32*4 bytes;
// 0, or -1 if it isn't one. Any thread.
int cq_thumbhash(const char *hash_base64, unsigned char *rgba, int *width, int *height);

// This person's private data: progress in items (e.g.,
// "t/m/alien/1979/v/-"), and the watchlist of titles.
int cq_set_progress(cq_library *library, const char *item_key, unsigned long long position_ms, unsigned long long duration_ms);
int cq_set_watched(cq_library *library, const char *item_key, int watched);
int cq_remove_progress(cq_library *library, const char *item_key);
char *cq_watchlist(cq_library *library);
int cq_set_watchlisted(cq_library *library, const char *title_key, int on);

// Long, but returns once listening: serves this library to devices and
// folders as sources (a JSON array of objects with "prefix", the path
// each is served at, and "path"), on the port given, else 8008, else any
// free port, advertised by DNS-SD, until stopped or closed. Returns the
// port, or -1.
int cq_serve(cq_library *library, int port, const char *folders_json);
void cq_stop_serving(cq_library *library);

// Names, shown in place of keys: this person's ("user") or this device's
// ("device"); this person's named devices; devices found nearby (long: it
// listens for 2 seconds) and added by address, with their names, whether
// they're of this library and their people members; and adding (nonzero
// add) or removing a device by address, on this device only.
int cq_name(cq_library *library, const char *device_key, const char *person_key, const char *name);
int cq_remove_device(cq_library *library, const char *device_key);
int cq_set_name(cq_library *library, const char *which, const char *name);
char *cq_devices(cq_library *library);
char *cq_nearby(cq_library *library);
int cq_device_address(cq_library *library, const char *url, int add);

void cq_free(char *text);

// Why the last call on this thread failed.
const char *cq_error(void);

#ifdef __cplusplus
}
#endif

#endif
