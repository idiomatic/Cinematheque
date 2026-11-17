// Cinematheque's core, for apps in C and languages that call it (Swift).
// Results are JSON strings, freed with cq_free; on failure, functions
// return NULL and cq_error says why. See src/capi.zig.

#ifndef CINEMATHEQUE_H
#define CINEMATHEQUE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cq_library cq_library;

// Opens the library in the peer home peer_home; if NULL, in
// $CINEMATHEQUE_HOME, or else in the default home.
cq_library *cq_open(const char *peer_home);
void cq_close(cq_library *library);

// Every title, as a JSON array.
char *cq_titles(cq_library *library);

// One title by key, as a JSON object, with each copy's playable URL.
char *cq_title(cq_library *library, const char *key);

// This user's playhead in an item (e.g., "t/m/alien/1979/v/-"), private to
// the user's devices. Return 0, or -1 on failure.
int cq_set_playhead(cq_library *library, const char *item_key, unsigned long long position_ms, unsigned long long duration_ms);
int cq_set_watched(cq_library *library, const char *item_key, int watched);

void cq_free(char *text);

// Why the last call on this thread failed.
const char *cq_error(void);

#ifdef __cplusplus
}
#endif

#endif
