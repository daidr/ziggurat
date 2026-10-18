#ifndef ZIGGURAT_WINDOWS_PROFILE_H
#define ZIGGURAT_WINDOWS_PROFILE_H

#ifndef COBJMACROS
#define COBJMACROS
#endif
#include "windows_profile_lifetime.h"
#include <WebView2.h>

typedef struct ZwpwProfile ZwpwProfile;
typedef struct ZwpwContext ZwpwContext;
/* Prefix layouts intentionally match the existing private Linux descriptors.
   Result values below match the existing neutral Zig profile status mapping. */
typedef struct ZwpwProfileOptions { uint32_t contexts;size_t bytes;uint32_t leases; } ZwpwProfileOptions;
typedef struct ZwpwProfileTls { const char *certificate_pem;size_t certificate_length,temporary_bytes; } ZwpwProfileTls;
typedef struct ZwpwProfileStats {
    size_t owned_bytes,peak_bytes;
    uint32_t contexts,context_capacity;
    int accepting;
    uint32_t leases,lease_capacity;
} ZwpwProfileStats;
enum {
    ZWPW_PROFILE_OK=0,ZWPW_PROFILE_CLOSED=1,ZWPW_PROFILE_FULL=2,
    ZWPW_PROFILE_OOM=3,ZWPW_PROFILE_INVALID=4,ZWPW_PROFILE_WRONG_THREAD=5,
    ZWPW_PROFILE_NATIVE=6,ZWPW_PROFILE_SYSTEM=7,ZWPW_PROFILE_CAPACITY=8,
    ZWPW_PROFILE_TLS=9,ZWPW_PROFILE_UNAVAILABLE=10
};

typedef HRESULT (STDAPICALLTYPE *ZwpwCreateEnvironment)(PCWSTR,PCWSTR,
    ICoreWebView2EnvironmentOptions *,ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *);
/* begin consumes one independently retained State pin only on success.
   environment is borrowed during ready; State retains before foreign work.
   revoke is an initialization failure exactly once for a pending Context.
   release owns that saved C pin; none of these functions receive Zig objects. */
typedef struct ZwpwContextStart {
    void *context;
    void (*environment)(void *,HRESULT,ICoreWebView2Environment *);
    void (*revoke)(void *,HRESULT);
    void (*release)(void *);
} ZwpwContextStart;

int zwpw_profile_measure(const WCHAR *canonical_udf,const ZwpwProfileTls *,size_t *bytes,HRESULT *failure);
/* Main identity is checked before reading path/options/certificate or
   allocating. domain/path/certificate are independently retained/copied before
   return. Caller owns a valid domain reference throughout the call. */
int zwpw_profile_create(ZwpwLifetime *,const WCHAR *canonical_udf,
                        const ZwpwProfileOptions *,const ZwpwProfileTls *,
                        ZwpwProfile **out,HRESULT *failure);
int zwpw_profile_seal(ZwpwProfile *);
int zwpw_profile_close(ZwpwProfile *);
int zwpw_profile_stats(ZwpwProfile *,ZwpwProfileStats *);
int zwpw_profile_lease_retain(ZwpwProfile *);
int zwpw_profile_lease_check(ZwpwProfile *);
int zwpw_profile_lease_release(ZwpwProfile *);
int zwpw_profile_context_create(ZwpwProfile *,ZwpwContext **out);
int zwpw_profile_context_admit(ZwpwContext *);
int zwpw_profile_context_close(ZwpwContext *);

/* Private C adapter pins, independent of the caller's linear Context token. */
void zwpw_context_ref(ZwpwContext *);
void zwpw_context_unref(ZwpwContext *);
int zwpw_context_begin(ZwpwContext *,ZwpwCreateEnvironment,const ZwpwContextStart *);
/* Publish the actual browser process before active/ready/navigation. If this
   fails, process remains owned by caller and Context stays non-active. */
int zwpw_context_publish_process(ZwpwContext *,HANDLE *process);
/* Only the pending->active commit ends seal's right to revoke initialization.
   Handler installation must have completed, and process must be published. */
int zwpw_context_activate(ZwpwContext *);
int zwpw_context_is_pending(ZwpwContext *);
/* Withdraw an adapter initialization failure exactly once. */
void zwpw_context_fail(ZwpwContext *,HRESULT);
/* State.close withdraws its authorization first. Late State/SDK pins retain
   only metadata after this call, and cannot activate or allow a certificate. */
void zwpw_context_detach(ZwpwContext *);
int zwpw_context_is_active(ZwpwContext *);
/* Called only after RequestUri has passed the existing native HTTPS origin
   parser and exact 127.0.0.1 host check. Exact DER equality; no hash shortcut.
   This never grants navigation, origin, request or port authority. */
int zwpw_context_certificate_matches(ZwpwContext *,const WCHAR *certificate_pem);
void zwpw_profile_counts(uint32_t *profiles,uint32_t *contexts,size_t *bytes);

#ifdef ZWPW_PROFILE_TESTING
void zwpw_profile_test_fail_after(int allocation);
#endif
#endif
