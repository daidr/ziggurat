#ifndef ZIGGURAT_WEBKIT_PROFILE_H
#define ZIGGURAT_WEBKIT_PROFILE_H
#include <stddef.h>
#include <stdint.h>

typedef struct ZwkProfile ZwkProfile;
typedef struct ZwkProfileContext ZwkProfileContext;
typedef struct ZwkProfileOptions {
    uint32_t contexts;
    size_t bytes;
    uint32_t leases;
} ZwkProfileOptions;
/* Optional creation-only exception for certificate errors on 127.0.0.1.
 * The manager uses NO_PROXY and TLS_ERRORS_POLICY_FAIL. No port isolation,
 * mandatory pinning, dynamic mutation or revocation is provided. */
typedef struct ZwkProfileTls {
    const char *certificate_pem;
    size_t certificate_length, temporary_bytes;
} ZwkProfileTls;
typedef struct ZwkProfileGlibFailure { uint32_t domain; int32_t code; } ZwkProfileGlibFailure;
typedef struct ZwkProfileStats {
    size_t owned_bytes, peak_bytes;
    uint32_t contexts, context_capacity;
    int accepting;
    uint32_t leases, lease_capacity;
} ZwkProfileStats;
enum ZwkProfileResult {
    ZWK_PROFILE_OK=0, ZWK_PROFILE_CLOSED=1, ZWK_PROFILE_FULL=2,
    ZWK_PROFILE_OOM=3, ZWK_PROFILE_INVALID=4, ZWK_PROFILE_WRONG_THREAD=5,
    ZWK_PROFILE_NATIVE_FAILED=6, ZWK_PROFILE_SYSTEM=7,
    ZWK_PROFILE_CAPACITY=8, ZWK_PROFILE_TLS=9, ZWK_PROFILE_TLS_UNAVAILABLE=10
};

/* These are private owner-thread APIs. All retained WebKit GObject references,
 * including their last unref, remain on that process main thread. A GObject
 * destroy notifier runs on the releasing thread; there is no implicit dispatch.
 * Late C-only storage is not permission to use WebKit objects from a worker.
 * Adapter qdata keys are private: callers must not overwrite or steal them.
 * Construction requires the Prepared's exclusive, unconsumed NativeClaim;
 * duplicating one open-file-description cannot detect an incorrectly reused
 * claim. No callback or allocator from Zig is
 * stored. The root's exclusive lock is duplicated with F_DUPFD_CLOEXEC; no
 * owner calls LOCK_UN. Paths are copied before the prepared lease is released.
 * No function is an engine fsync or NetworkProcess exit barrier. */
int zwk_profile_measure(const char *data,const char *cache,const char *cookies,
                       size_t *bytes);
int zwk_profile_create(int borrowed_lock,const char *data,const char *cache,
                       const char *cookies,const ZwkProfileOptions *,
                       ZwkProfile **out,int *system_errno);
int zwk_profile_measure_tls(const char *data,const char *cache,const char *cookies,
                           const ZwkProfileTls *,size_t *bytes);
int zwk_profile_create_tls(int borrowed_lock,const char *data,const char *cache,
                          const char *cookies,const ZwkProfileOptions *,const ZwkProfileTls *,
                          ZwkProfile **out,int *system_errno,ZwkProfileGlibFailure *);
int zwk_profile_seal(ZwkProfile *);
int zwk_profile_stats(ZwkProfile *,ZwkProfileStats *);
/* Withdraws all new-context ingress, then releases the owner's reference.
 * Existing WebContext/manager references retain only native storage and the
 * duplicate lock. The pointer cannot be used again after this call. */
int zwk_profile_close(ZwkProfile *);
/* Linear Config references: no per-reference allocation or Zig backpointer.
 * retain requires an open owner; release works after seal/owner close. */
int zwk_profile_lease_retain(ZwkProfile *);
int zwk_profile_lease_check(ZwkProfile *);
int zwk_profile_lease_release(ZwkProfile *);
/* A new independent subsystem captures this strong manager reference while
 * ingress is open. It must also hold its own C-only profile lease. */
int zwk_profile_manager_ref(ZwkProfile *,void **out);
int zwk_profile_context_create(ZwkProfile *,ZwkProfileContext **out);
/* Once admitted, an existing candidate is accepted work. A later seal blocks
 * new candidates but does not revoke this Context. Admission is one-shot. */
int zwk_profile_context_admit(ZwkProfileContext *);
/* A borrowed WebKitWebContext pointer, never a shared per-profile context.
 * The caller must retain the GObject before any callback may close the token.
 * A sealed profile no longer permits a new attachment to acquire this borrow. */
int zwk_profile_context_get(ZwkProfileContext *,void **out);
int zwk_profile_context_close(ZwkProfileContext *);
/* Counts only this adapter's live native owners/tokens/requested malloc bytes.
 * WebKit/GLib internal allocation and engine processes are not included. */
void zwk_profile_counts(uint32_t *profiles,uint32_t *contexts,size_t *bytes);

#ifdef ZWK_PROFILE_TESTING
void zwk_profile_test_fail_after(int allocations);
#endif
#endif
