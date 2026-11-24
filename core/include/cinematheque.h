// Cinematheque's core, for apps in C and languages that call it (Swift).
// Results are JSON strings, freed with cq_free; on failure, functions
// return NULL or -1, and cq_error says why. Arrays go in as a pointer and
// a count; optional pointers may be NULL, and optional integers are -1
// when absent. See README.md beside this file, which documents each
// function and result's form.
//
// Functions belong to one thread, the app's main one, except the long ones
// (crawling, syncing, describing, pairing, looking for devices, and
// downloads' configuring, deleting, and reconciling) and those marked "any
// thread", which may run on any thread. While a
// long one runs, other changes to the library fail with "Busy"; progress
// and private lists don't wait.

#ifndef CINEMATHEQUE_H
#define CINEMATHEQUE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cq_library cq_library;

// A title's kind, as its key has it (t/m/..., t/s/...).
typedef enum { CQ_MOVIE = 'm', CQ_SERIES = 's' } cq_title_kind;

// A folder to serve as a source: the path it's served at, and the folder.
typedef struct {
    const char *prefix;
    const char *path;
} cq_folder;

// What a download's size is of: a key's own files, or a series' choice of
// episodes (the next count, or all).
typedef enum { CQ_DOWNLOAD_OWN = 0, CQ_DOWNLOAD_NEXT = 1, CQ_DOWNLOAD_ALL = 2 } cq_download_kind;
typedef struct {
    cq_download_kind kind;
    unsigned int count; // CQ_DOWNLOAD_NEXT's, at least 1; else ignored
} cq_download_choice;

// A placeholder for a title not in the library yet.
typedef struct {
    cq_title_kind kind;
    const char *name;
    int year;         // -1: none
    int season;       // a series'; -1: the first
    const char *note; // NULL: none
} cq_want;

// Opens this device's data directory data_dir; if NULL, $CINEMATHEQUE_DATA, or
// else the
// default. It may hold no library yet.
cq_library *cq_open(const char *data_dir);
void cq_close(cq_library *library);

// Identity and membership.
char *cq_status(cq_library *library);
// Creates a library, founded by this person; joining one is by pairing.
int cq_found(cq_library *library);
// Leaves the library, as a device removed from it does (a sync's error is
// "Removed"), forgetting it and this device's identity, to pair afresh.
int cq_leave(cq_library *library);
// Pairing: on a new device, before it has a library, offering to be added
// (serving and advertising as name, and model: an Apple identifier, shown
// by its name, or a name, or empty), with a code to show; and checking
// whether it's paired (taking the library, and if added as a member's
// device, the person's secret) or closed (too many wrong codes). On a
// member's device, long, adding the one offering at url (a pairing
// device's) given its code, as another of this person's devices
// (cq_pair_person) or a new member's (cq_pair_member), which returns its
// keys (person, to add a new member by, and device, to name it by with
// cq_name).
char *cq_pair_offer(cq_library *library, const char *name, const char *model);
char *cq_pair_check(cq_library *library);
void cq_pair_stop(cq_library *library);
char *cq_pair_person(cq_library *library, const char *url, const char *code);
char *cq_pair_member(cq_library *library, const char *url, const char *code);
char *cq_members(cq_library *library);
int cq_member_add(cq_library *library, const char *person_key);
// For good: a person removed comes back only as someone new.
int cq_member_remove(cq_library *library, const char *person_key);

// Sources; cq_repo_add's skip may be NULL, for the default.
char *cq_repos(cq_library *library); // any thread
int cq_repo_add(cq_library *library, const char *url, const char *skip);
int cq_repo_skip(cq_library *library, const char *source, const char *skip);
// Where a source's files take their quality from: their names, the first
// folder within it, or one name for all.
int cq_repo_quality_from_names(cq_library *library, const char *source);
int cq_repo_quality_from_folder(cq_library *library, const char *source);
int cq_repo_quality_named(cq_library *library, const char *source, const char *name);
int cq_repo_remove(cq_library *library, const char *source);
// Forgets an unavailable directory of a source, as if deleted.
int cq_remove_unavailable(cq_library *library, const char *source, const char *dir);
// Looks up the names of the servers of urls, so copy racing's first race
// finds them answered. Long; any thread.
void cq_race_warm(cq_library *library, const char *const *urls, size_t count);
// Long (up to 1.5 s), any thread: copy racing. An item's copies' URLs in,
// a JSON array of them out, in the order to try them: those whose servers
// answer first. cq_race_lost notes a copy that didn't load.
char *cq_race(cq_library *library, const char *const *urls, size_t count);
void cq_race_lost(cq_library *library, const char *url);

// Downloads, this device's: kept in dir, served at served_at (a source
// of its own, never crawled). cq_download wants a title, season
// (TITLE/e/s01), or item kept, in a quality (null: the commonest), until
// deleted; cq_download_next chooses which of a series' episodes download
// as it's watched: the next N ("3"), whose watched ones go as their space
// is needed (if another source holds them), or "all", kept however watched
// ("" or "0" stops); cq_download_remove deletes and stops wanting;
// cq_downloads is all of it as JSON; cq_reconcile fetches and deletes to
// match, returning at once with "busy" if one runs, which then runs again,
// and cq_reconcile_stop (any thread) stops it, keeping the file under way
// to resume. Configuring, deleting, and reconciling are long, each on a
// connection of its own, waiting their turn to write.
int cq_downloads_configure(cq_library *library, const char *dir, const char *served_at);
int cq_download(cq_library *library, const char *key, const char *quality);
int cq_download_remove(cq_library *library, const char *key);
int cq_download_next(cq_library *library, const char *title_key, const char *choice);
// What downloading would come to, as JSON: per choice, a series' (key its
// title) or key's own files in quality (NULL for the commonest), its total
// size and what of it isn't here yet (needed), in bytes.
char *cq_download_sizes(cq_library *library, const char *key, const cq_download_choice *choices, size_t count, const char *quality);
char *cq_downloads(cq_library *library);
char *cq_reconcile(cq_library *library);
void cq_reconcile_stop(cq_library *library);
// Holds downloads back while a stream plays: none begins; resuming lets
// them go. Any thread.
void cq_downloads_hold(cq_library *library);
void cq_downloads_resume(cq_library *library);

// Long: crawling every source and describing what's new (committing
// as it goes, so reload when cq_data_version changes), syncing with every
// device found or added (or with one, cq_sync_with), and reading an item's
// metadata from its file.
char *cq_crawl(cq_library *library);
// As cq_crawl, listing every directory afresh, so files rewritten in place
// (retagged), whose directories' times don't change, are seen.
char *cq_crawl_full(cq_library *library);
// As cq_crawl, for a refresh not asked for (at launch, on a timer), once
// synced: skips sources a device crawled within the library's interval
// (±1/24 of it), or all of them if it's 0 (only when asked).
char *cq_crawl_due(cq_library *library);
// Sets that interval, for every device: 1, 3, 24 (the default), or 168
// hours, or 0, only when asked (Refresh Library); cq_status gives it.
int cq_crawl_every(cq_library *library, int hours);
char *cq_sync(cq_library *library);
char *cq_sync_with(cq_library *library, const char *url);
// As cq_sync with every device, but with those the last such sync found
// nearby (and those added), without looking again (two seconds); if none
// has, it looks. For a change to reach other devices at once.
char *cq_sync_known(cq_library *library);
// The last sync this device served, while serving: which device asked, and
// how many operations it was sent.
char *cq_served(cq_library *library);
// The last push this device took, while serving: from which device, and how
// many of its operations won.
char *cq_received(cq_library *library);
int cq_describe(cq_library *library, const char *item_key);

// While a crawl describes, which titles to take first (title keys, e.g.,
// the tiles on screen); any thread. And a number that changes when a long
// operation has committed changes, to know when to reload.
int cq_prioritize(cq_library *library, const char *const *title_keys, size_t count);
long long cq_data_version(cq_library *library);

// How far the long operation running has come: a JSON object with
// "phase" ("crawling", "describing", "syncing", or null), and "done" and
// "total" steps of it. Any thread.
char *cq_steps(cq_library *library);

// Browsing: the grid's tiles, with their covers' byte ranges (any
// thread, as cq_repos: each reads on a connection of its own, so apps
// read them off the main thread while a long operation commits), and one
// title, with its metadata and each copy's playable URL.
char *cq_tiles(cq_library *library);
char *cq_title(cq_library *library, const char *key);

// A tile's placeholder (its `thumb`, a ThumbHash in base64) as RGBA
// pixels, not premultiplied, 32 on the longer side, into 32*32*4 bytes;
// 0, or -1 if it isn't one. Any thread.
int cq_thumbhash(const char *hash_base64, unsigned char *rgba, int *width, int *height);

// This person's private data: progress in items (e.g.,
// "t/m/alien/1979/v/-"), and lists of titles (movies' title keys, seasons'
// tiles, "<title key>#<season>"): cq_lists is them all, by name, then
// other members' shared lists, each with "id" (another member's,
// "<owner>/<id>"), "name", "owner" (its person's key, in hex), "ownerName"
// (another member's name, if set), "mine" (only its owner changes it), "mode"
// ("private", its owner's alone, or "shared", every member sees it), "titles", and "wanted" (placeholders among the
// titles, not in the library when listed: "key", "name", "note"); the
// Watchlist's ID is "watchlist", whatever it's named. cq_list_share shares
// a list of this person's with every member; cq_list_stop_sharing makes it
// theirs alone again. cq_list_create returns a new list's ID
// as a JSON string; cq_list_want puts a placeholder on one, returning its
// key, as its file will be keyed when it comes, and cq_list_edit_want
// changes one (keyed afresh, the old key taken off in the same change).
int cq_set_progress(cq_library *library, const char *item_key, unsigned long long position_ms, unsigned long long duration_ms);
int cq_mark_watched(cq_library *library, const char *item_key);
// Forgets where this person stopped too, so it plays from the beginning.
int cq_mark_unwatched(cq_library *library, const char *item_key);
int cq_remove_progress(cq_library *library, const char *item_key);
char *cq_lists(cq_library *library);
char *cq_list_create(cq_library *library, const char *name);
int cq_list_rename(cq_library *library, const char *id, const char *name);
int cq_list_remove(cq_library *library, const char *id);
int cq_list_add_title(cq_library *library, const char *id, const char *title_key);
int cq_list_remove_title(cq_library *library, const char *id, const char *title_key);
char *cq_list_want(cq_library *library, const char *id, const cq_want *want);
char *cq_list_edit_want(cq_library *library, const char *id, const char *key, const cq_want *want);
int cq_list_share(cq_library *library, const char *id);
int cq_list_stop_sharing(cq_library *library, const char *id);

// Long, but returns once listening: serves this library to devices and
// folders as sources, on the port given, else 8008, else any free port,
// advertised by DNS-SD, until stopped or closed. Returns the port, or -1.
int cq_serve(cq_library *library, int port, const cq_folder *folders, size_t count);
void cq_stop_serving(cq_library *library);

// Names, shown in place of keys: this person's or this device's; this
// person's named devices; devices found nearby (long: it
// listens for 2 seconds) and added by address, with their names, whether
// they're of this library and their people members; and adding a device
// by address, or forgetting one, on this device only.
int cq_name(cq_library *library, const char *device_key, const char *person_key, const char *name);
int cq_remove_device(cq_library *library, const char *device_key);
// Removes this device from the library, as it leaves: handing it over to
// successor (a person's key; NULL for none) first, if this person founded
// it; other devices take the removal once synced with. Then cq_leave.
int cq_remove_self(cq_library *library, const char *successor);
int cq_set_person_name(cq_library *library, const char *name);
int cq_set_device_name(cq_library *library, const char *name);
// What this device names itself as, told name by its platform, at host: a
// JSON string, or null if both are generic ("iPhone", "localhost").
char *cq_shown_name(cq_library *library, const char *name, const char *host);
char *cq_devices(cq_library *library);
char *cq_nearby(cq_library *library);
int cq_device_address_add(cq_library *library, const char *url);
int cq_device_address_forget(cq_library *library, const char *url);

// What this build is: {"version", "revision", "mode", "zig"}, as /version
// serves it.
// Any thread.
char *cq_version(void);

void cq_free(char *text);

// Why the last call on this thread failed.
const char *cq_error(void);

#ifdef __cplusplus
}
#endif

#endif
