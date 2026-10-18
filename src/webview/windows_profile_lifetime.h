#ifndef ZIGGURAT_WINDOWS_PROFILE_LIFETIME_H
#define ZIGGURAT_WINDOWS_PROFILE_LIFETIME_H

/* Private session authorization lifetime. No COM, App, callback or allocator
   pointer is stored. The explicit preparing worker owns wait and process-handle
   retirement; main only publishes handles and admission changes. */
#include <stdint.h>
#include <stddef.h>
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#define ZWPW_PROCESS_CAPACITY 63u
typedef struct ZwpwLifetime ZwpwLifetime;
enum {
    ZWPW_OK=0, ZWPW_CLOSED=1, ZWPW_FULL=2, ZWPW_OUT_OF_MEMORY=3,
    ZWPW_INVALID=4, ZWPW_WRONG_THREAD=5, ZWPW_NATIVE_FAILED=6,
    ZWPW_BUDGET_EXCEEDED=7, ZWPW_PROCESS_EXIT_PENDING=8, ZWPW_BUSY=9
};
typedef struct ZwpwLifetimeStats {
    size_t bytes;
    uint32_t processes, admissions, accepting, running;
} ZwpwLifetimeStats;
typedef struct ZwpwLifetimeCounts {
    uint32_t domains, processes;
    size_t bytes;
} ZwpwLifetimeCounts;

/* Worker only. A successful call independently duplicates lock_handle. The
   caller keeps its original. On any failure out remains NULL. */
int zwpw_lifetime_create(uint32_t main_thread, size_t bytes, HANDLE lock_handle,
                         ZwpwLifetime **out, uint32_t *system_error);
void zwpw_lifetime_ref(ZwpwLifetime *);
/* Metadata-only last release is allowed on either owner thread after worker
   retirement. It never waits, releases COM or closes an active process handle. */
void zwpw_lifetime_unref(ZwpwLifetime *);
/* Pure identity check, before a main-only owner reads further input or
   allocates. It never reserves admission or changes the wake event. */
int zwpw_lifetime_check_main(ZwpwLifetime *);
/* Preparing worker only, for an unclaimed/failed preparation. The linear
   Prepared owner must first exclude successful Profile adoption. */
int zwpw_lifetime_abandon(ZwpwLifetime *);

/* Main only. Existing admissions survive seal; each must be withdrawn once
   before the worker may finish. Context owns that linear responsibility. */
int zwpw_lifetime_admit(ZwpwLifetime *);
int zwpw_lifetime_withdraw(ZwpwLifetime *);
int zwpw_lifetime_seal(ZwpwLifetime *);

/* Main only. Consume handle only on success, including a same-object cache
   hit. Caller obtained an actual SYNCHRONIZE browser-process handle before any
   document/ALLOW. Tokens are not PIDs and never repeat within this domain. */
int zwpw_lifetime_publish(ZwpwLifetime *, HANDLE *handle, uint64_t *token);
int zwpw_lifetime_matches(ZwpwLifetime *, uint64_t token);

/* Original explicit worker only. No main-thread wait or message dispatch.
   Timeout/failure retain all outstanding physical responsibilities. */
int zwpw_lifetime_run(ZwpwLifetime *, uint32_t timeout_ms, uint32_t *system_error);
int zwpw_lifetime_stats(ZwpwLifetime *, ZwpwLifetimeStats *);
void zwpw_lifetime_counts(ZwpwLifetimeCounts *);
size_t zwpw_lifetime_size(void);

#endif
