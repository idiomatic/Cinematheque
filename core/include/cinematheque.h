// Cinematheque's core, for apps in C and languages that call it (Swift).
// Results are JSON strings, freed with cq_free; on failure, functions
// return NULL or -1, and cq_error says why. See src/capi.zig, which
// documents each result's form.
//
// Functions belong to one thread, the app's main one, except the long ones
// (cq_crawl, cq_sync, cq_describe), which may run on any thread. While a
// long one runs, other changes to the library fail with "Busy"; playheads
// and the watchlist don't wait.

#ifndef CINEMATHEQUE_H
#define CINEMATHEQUE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cq_library cq_library;

// Opens the peer's home peer_home; if NULL, $CINEMATHEQUE_HOME, or else the
// default. It may hold no library yet.
cq_library *cq_open(const char *peer_home);
void cq_close(cq_library *library);

// Identity and membership.
char *cq_status(cq_library *library);
char *cq_secret(cq_library *library);
int cq_link(cq_library *library, const char *secret);
// Creates a library (founder NULL), or joins the one founder founded.
int cq_found(cq_library *library, const char *founder);
// Pairing: on a new device, before it has a library, offering to pair
// (serving and advertising as name), to link it to a member's user or (join
// nonzero) to join as a new member, with a code to show; and checking
// whether it's paired (taking the library, and if linking, the user's
// secret) or closed (too many wrong codes). On a member's device, long,
// pairing the one offering at url (a pairing peer's) given its code, which
// returns its keys (user, to add a new member by, and device, to name it
// by with cq_name).
char *cq_pair_offer(cq_library *library, const char *name, int join);
char *cq_pair_check(cq_library *library);
void cq_pair_stop(cq_library *library);
char *cq_pair(cq_library *library, const char *url, int join, const char *code);
char *cq_members(cq_library *library);
int cq_member(cq_library *library, const char *user_key, int add);

// Repositories; rendition and skip may be NULL, for the default or no
// change.
char *cq_repos(cq_library *library);
int cq_repo_add(cq_library *library, const char *url, const char *rendition, const char *skip);
int cq_repo_set(cq_library *library, const char *repo, const char *rendition, const char *skip);
int cq_repo_remove(cq_library *library, const char *repo);

// Long: crawling every repository and describing what's new (committing
// as it goes, so reload when cq_data_version changes), syncing with a peer (or,
// if url is NULL, every peer found or added), and reading an item's
// metadata from its file.
char *cq_crawl(cq_library *library);
char *cq_sync(cq_library *library, const char *url);
// The last sync this peer served, while serving: which device asked, and
// how many operations it was sent.
char *cq_served(cq_library *library);
// Long: asks every peer this one syncs with to pull from it soon, as after
// a change of its own.
int cq_nudge(cq_library *library);
// When a peer last nudged this one, in milliseconds since the epoch, or 0.
// Any thread.
unsigned long long cq_nudged(cq_library *library);
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
char *cq_progress(cq_library *library);

// Browsing: the grid's tiles, with their covers' byte ranges, and one
// title, with its metadata and each copy's playable URL.
char *cq_tiles(cq_library *library);
char *cq_title(cq_library *library, const char *key);

// A tile's placeholder (its `thumb`, a ThumbHash in base64) as RGBA
// pixels, not premultiplied, 32 on the longer side, into 32*32*4 bytes;
// 0, or -1 if it isn't one. Any thread.
int cq_thumbhash(const char *hash_base64, unsigned char *rgba, int *width, int *height);

// This user's private data: playheads in items (e.g.,
// "t/m/alien/1979/v/-"), and the watchlist of titles.
int cq_set_playhead(cq_library *library, const char *item_key, unsigned long long position_ms, unsigned long long duration_ms);
int cq_set_watched(cq_library *library, const char *item_key, int watched);
int cq_remove_playhead(cq_library *library, const char *item_key);
char *cq_watchlist(cq_library *library);
int cq_set_watchlisted(cq_library *library, const char *title_key, int on);

// Long, but returns once listening: serves this library to peers and
// folders as repositories (a JSON array of objects with "prefix", the path
// each is served at, and "path"), on the port given, else 8008, else any
// free port, advertised by DNS-SD, until stopped or closed. Returns the
// port, or -1.
int cq_serve(cq_library *library, int port, const char *folders_json);
void cq_stop_serving(cq_library *library);

// Names, shown in place of keys: this user's ("user") or this device's
// ("device"); this user's named devices; peers found nearby (long: it
// listens for 2 seconds) and added by address, with their names, whether
// they're of this library and their users members; and adding (nonzero
// add) or removing a peer by address, on this device only.
int cq_name(cq_library *library, const char *device_key, const char *user_key, const char *name);
int cq_remove_device(cq_library *library, const char *device_key);
int cq_set_name(cq_library *library, const char *which, const char *name);
char *cq_devices(cq_library *library);
char *cq_peers(cq_library *library);
int cq_peer(cq_library *library, const char *url, int add);

void cq_free(char *text);

// Why the last call on this thread failed.
const char *cq_error(void);

#ifdef __cplusplus
}
#endif

#endif
