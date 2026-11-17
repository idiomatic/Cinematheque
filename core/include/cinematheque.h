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
char *cq_members(cq_library *library);
int cq_member(cq_library *library, const char *user_key, int add);

// Repositories; rendition and skip may be NULL, for the default or no
// change.
char *cq_repos(cq_library *library);
int cq_repo_add(cq_library *library, const char *url, const char *rendition, const char *skip);
int cq_repo_set(cq_library *library, const char *repo, const char *rendition, const char *skip);
int cq_repo_remove(cq_library *library, const char *repo);

// Long: crawling and describing every repository, syncing with a peer (or,
// if url is NULL, every peer found or added), and reading an item's
// metadata from its file.
char *cq_crawl(cq_library *library);
char *cq_sync(cq_library *library, const char *url);
int cq_describe(cq_library *library, const char *item_key);

// Browsing: the grid's tiles, with their covers' byte ranges, and one
// title, with its metadata and each copy's playable URL.
char *cq_tiles(cq_library *library);
char *cq_title(cq_library *library, const char *key);

// This user's private data: playheads in items (e.g.,
// "t/m/alien/1979/v/-"), and the watchlist of titles.
int cq_set_playhead(cq_library *library, const char *item_key, unsigned long long position_ms, unsigned long long duration_ms);
int cq_set_watched(cq_library *library, const char *item_key, int watched);
char *cq_watchlist(cq_library *library);
int cq_set_watchlisted(cq_library *library, const char *title_key, int on);

void cq_free(char *text);

// Why the last call on this thread failed.
const char *cq_error(void);

#ifdef __cplusplus
}
#endif

#endif
