#define _GNU_SOURCE
#include "webkit_profile.h"
#include <webkit2/webkit2.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#define ZWK_PROFILE_PATH 4096u
#define ZWK_PROFILE_CONTEXTS 64u
#define ZWK_PROFILE_LEASES 256u
#define ZWK_PROFILE_BYTES (1024u*1024u)
#define ZWK_PROFILE_PEM (16u*1024u)

typedef struct ProfileTls {
    GTlsCertificate *certificate;
    char pem[];
} ProfileTls;

struct ZwkProfile {
    GThread *thread;
    WebKitWebsiteDataManager *manager;
    char *data, *cache, *cookies;
    size_t owned_bytes, peak_bytes, limit, allocation_bytes;
    guint contexts, capacity, leases, lease_capacity;
    gint refs;
    int lock_fd;
    gboolean accepting, owner_closed;
    ProfileTls *tls;
};
struct ZwkProfileContext {
    ZwkProfile *profile;
    WebKitWebContext *context;
    gint refs;
    gboolean owner_closed, admitted;
};
static _Atomic uint32_t live_profiles, live_contexts;
static _Atomic size_t live_bytes;
#ifdef ZWK_PROFILE_TESTING
static int fail_after=-1;
void zwk_profile_test_fail_after(int n) { fail_after=n; }
static void *profile_malloc(size_t bytes) {
    if (fail_after==0) return NULL;
    if (fail_after>0) --fail_after;
    return malloc(bytes);
}
#else
#define profile_malloc malloc
#endif

static int on_main(void) { return (pid_t)syscall(SYS_gettid)==getpid(); }
static int owner(ZwkProfile *p) {
    if (!p) return ZWK_PROFILE_INVALID;
    return p->thread==g_thread_self()?ZWK_PROFILE_OK:ZWK_PROFILE_WRONG_THREAD;
}
static int path_size(const char *path,size_t *size) {
    if (!path || path[0]!='/') return ZWK_PROFILE_INVALID;
    size_t n=strnlen(path,ZWK_PROFILE_PATH);
    if (!n || n==ZWK_PROFILE_PATH || !g_utf8_validate(path,(gssize)n,NULL)) return ZWK_PROFILE_INVALID;
    *size=n+1;
    return ZWK_PROFILE_OK;
}
int zwk_profile_measure(const char *data,const char *cache,const char *cookies,size_t *bytes) {
    if (!bytes) return ZWK_PROFILE_INVALID;
    *bytes=0;
    size_t a,b,c;
    if (path_size(data,&a) || path_size(cache,&b) || path_size(cookies,&c)) return ZWK_PROFILE_INVALID;
    *bytes=sizeof(ZwkProfile)+a+b+c;
    return ZWK_PROFILE_OK;
}
int zwk_profile_measure_tls(const char *data,const char *cache,const char *cookies,
                           const ZwkProfileTls *tls,size_t *bytes) {
    int result=zwk_profile_measure(data,cache,cookies,bytes);
    if (result || !tls) return result;
    if (!tls->certificate_pem || !tls->certificate_length || tls->certificate_length>ZWK_PROFILE_PEM ||
        strnlen(tls->certificate_pem,tls->certificate_length+1)!=tls->certificate_length ||
        tls->temporary_bytes>ZWK_PROFILE_BYTES) return ZWK_PROFILE_INVALID;
    *bytes=(*bytes+_Alignof(ProfileTls)-1)&~(size_t)(_Alignof(ProfileTls)-1);
    *bytes+=sizeof(ProfileTls)+tls->certificate_length+1;
    return ZWK_PROFILE_OK;
}
static void profile_ref(ZwkProfile *p) { g_atomic_int_inc(&p->refs); }
static void profile_unref(ZwkProfile *p) {
    if (!g_atomic_int_dec_and_test(&p->refs)) return;
    g_assert(p->owner_closed && !p->manager && !p->contexts && !p->leases);
    g_assert(!p->tls || !p->tls->certificate);
    /* Final native-only release: no GObject, App, Zig context or allocator. */
    int fd=p->lock_fd;
    size_t bytes=p->allocation_bytes;
    p->lock_fd=-1;
    if (fd>=0) close(fd);
    free(p);
    atomic_fetch_sub_explicit(&live_bytes,bytes,memory_order_relaxed);
    atomic_fetch_sub_explicit(&live_profiles,1,memory_order_relaxed);
}
static void manager_gone(gpointer data) {
    ZwkProfile *p=data;
    g_assert(p->thread==g_thread_self());
    profile_unref(p);
}
static int create(int borrowed_lock,const char *data,const char *cache,
                  const char *cookies,const ZwkProfileOptions *options,const ZwkProfileTls *tls,
                  ZwkProfile **out,int *system_errno,ZwkProfileGlibFailure *failure) {
    if (system_errno) *system_errno=0;
    if (failure) *failure=(ZwkProfileGlibFailure){0,0};
    if (!out) return ZWK_PROFILE_INVALID;
    *out=NULL;
    if (!on_main()) return ZWK_PROFILE_WRONG_THREAD;
    size_t bytes;
    if (!options || !options->contexts || options->contexts>ZWK_PROFILE_CONTEXTS ||
        !options->leases || options->leases>ZWK_PROFILE_LEASES ||
        !options->bytes || options->bytes>ZWK_PROFILE_BYTES ||
        zwk_profile_measure_tls(data,cache,cookies,tls,&bytes)) return ZWK_PROFILE_INVALID;
    const size_t temporary=tls?tls->temporary_bytes:0;
    if (bytes>options->bytes || temporary>options->bytes-bytes) return ZWK_PROFILE_CAPACITY;
    int lock_fd=fcntl(borrowed_lock,F_DUPFD_CLOEXEC,0);
    if (lock_fd<0) {
        if (system_errno) *system_errno=errno;
        return ZWK_PROFILE_SYSTEM;
    }
    ZwkProfile *p=profile_malloc(bytes);
    if (!p) { close(lock_fd);return ZWK_PROFILE_OOM; }
    memset(p,0,sizeof(*p));
    p->thread=g_thread_self();p->refs=1;p->lock_fd=lock_fd;
    p->allocation_bytes=p->owned_bytes=bytes;p->peak_bytes=bytes+temporary;
    p->capacity=options->contexts;p->lease_capacity=options->leases;
    p->limit=options->bytes;p->accepting=TRUE;
    char *at=(char *)(p+1);
    size_t n=strlen(data)+1;p->data=at;memcpy(at,data,n);at+=n;
    n=strlen(cache)+1;p->cache=at;memcpy(at,cache,n);at+=n;
    n=strlen(cookies)+1;p->cookies=at;memcpy(at,cookies,n);at+=n;
    if (tls) {
        size_t offset=((size_t)(at-(char *)p)+_Alignof(ProfileTls)-1)&~(size_t)(_Alignof(ProfileTls)-1);
        p->tls=(ProfileTls *)((char *)p+offset);
        p->tls->certificate=NULL;
        memcpy(p->tls->pem,tls->certificate_pem,tls->certificate_length+1);
    }
    atomic_fetch_add_explicit(&live_profiles,1,memory_order_relaxed);
    atomic_fetch_add_explicit(&live_bytes,bytes,memory_order_relaxed);
    if (p->tls) {
        GError *error=NULL;
        p->tls->certificate=g_tls_certificate_new_from_pem(p->tls->pem,(gssize)tls->certificate_length,&error);
        if (!p->tls->certificate) {
            const int result=error && g_error_matches(error,G_TLS_ERROR,G_TLS_ERROR_UNAVAILABLE)?ZWK_PROFILE_TLS_UNAVAILABLE:ZWK_PROFILE_TLS;
            if (failure && error) *failure=(ZwkProfileGlibFailure){error->domain,error->code};
            g_clear_error(&error);p->owner_closed=TRUE;profile_unref(p);
            return result;
        }
    }
    /* GLib/WebKit object allocation is system-owned and can be fatal on OOM;
     * only this adapter's requested malloc storage is recoverably budgeted. */
    p->manager=webkit_website_data_manager_new("base-data-directory",p->data,
                                              "base-cache-directory",p->cache,NULL);
    if (!p->manager) {
        if (p->tls) g_clear_object(&p->tls->certificate);
        p->owner_closed=TRUE;profile_unref(p);
        return ZWK_PROFILE_NATIVE_FAILED;
    }
    profile_ref(p);
    /* qdata survives dispose; weak notifications do not. Keep physical storage
     * through finalization even if run_dispose precedes the last GObject ref. */
    g_object_set_qdata_full(G_OBJECT(p->manager),g_quark_from_static_string("ziggurat-profile-manager-owner"),p,manager_gone);
    webkit_website_data_manager_set_persistent_credential_storage_enabled(p->manager,FALSE);
    webkit_website_data_manager_set_tls_errors_policy(p->manager,WEBKIT_TLS_ERRORS_POLICY_FAIL);
    if (p->tls) webkit_website_data_manager_set_network_proxy_settings(p->manager,WEBKIT_NETWORK_PROXY_MODE_NO_PROXY,NULL);
    WebKitCookieManager *cookie_manager=webkit_website_data_manager_get_cookie_manager(p->manager);
    webkit_cookie_manager_set_persistent_storage(cookie_manager,p->cookies,WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE);
    *out=p;
    return ZWK_PROFILE_OK;
}
int zwk_profile_create(int borrowed_lock,const char *data,const char *cache,
                       const char *cookies,const ZwkProfileOptions *options,
                       ZwkProfile **out,int *system_errno) {
    return create(borrowed_lock,data,cache,cookies,options,NULL,out,system_errno,NULL);
}
int zwk_profile_create_tls(int borrowed_lock,const char *data,const char *cache,
                          const char *cookies,const ZwkProfileOptions *options,const ZwkProfileTls *tls,
                          ZwkProfile **out,int *system_errno,ZwkProfileGlibFailure *failure) {
    if (!tls) return ZWK_PROFILE_INVALID;
    return create(borrowed_lock,data,cache,cookies,options,tls,out,system_errno,failure);
}
int zwk_profile_seal(ZwkProfile *p) {
    int result=owner(p);if (result) return result;
    p->accepting=FALSE;
    return ZWK_PROFILE_OK;
}
int zwk_profile_stats(ZwkProfile *p,ZwkProfileStats *stats) {
    int result=owner(p);if (result) return result;
    if (!stats) return ZWK_PROFILE_INVALID;
    *stats=(ZwkProfileStats){p->owned_bytes,p->peak_bytes,p->contexts,p->capacity,p->accepting,p->leases,p->lease_capacity};
    return ZWK_PROFILE_OK;
}
int zwk_profile_close(ZwkProfile *p) {
    int result=owner(p);if (result) return result;
    if (p->owner_closed) return ZWK_PROFILE_CLOSED;
    p->accepting=FALSE;p->owner_closed=TRUE;
    WebKitWebsiteDataManager *manager=p->manager;
    p->manager=NULL;
    if (p->tls) g_clear_object(&p->tls->certificate);
    if (manager) g_object_unref(manager);
    profile_unref(p);
    return ZWK_PROFILE_OK;
}
int zwk_profile_lease_check(ZwkProfile *p) {
    int result=owner(p);if (result) return result;
    return p->accepting && !p->owner_closed?ZWK_PROFILE_OK:ZWK_PROFILE_CLOSED;
}
int zwk_profile_lease_retain(ZwkProfile *p) {
    int result=zwk_profile_lease_check(p);if (result) return result;
    if (p->leases==p->lease_capacity) return ZWK_PROFILE_FULL;
    ++p->leases;profile_ref(p);
    return ZWK_PROFILE_OK;
}
int zwk_profile_lease_release(ZwkProfile *p) {
    int result=owner(p);if (result) return result;
    if (!p->leases) return ZWK_PROFILE_INVALID;
    --p->leases;profile_unref(p);
    return ZWK_PROFILE_OK;
}
int zwk_profile_manager_ref(ZwkProfile *p,void **out) {
    if (!out) return ZWK_PROFILE_INVALID;
    *out=NULL;
    int result=zwk_profile_lease_check(p);if (result) return result;
    *out=g_object_ref(p->manager);
    return ZWK_PROFILE_OK;
}
static void context_unref(ZwkProfileContext *c) {
    g_assert(c->profile->thread==g_thread_self());
    if (!g_atomic_int_dec_and_test(&c->refs)) return;
    ZwkProfile *p=c->profile;
    g_assert(c->owner_closed && !c->context);
    --p->contexts;p->owned_bytes-=sizeof(*c);
    free(c);
    atomic_fetch_sub_explicit(&live_bytes,sizeof(ZwkProfileContext),memory_order_relaxed);
    atomic_fetch_sub_explicit(&live_contexts,1,memory_order_relaxed);
    profile_unref(p);
}
static void context_gone(gpointer data) {
    context_unref(data);
}
int zwk_profile_context_create(ZwkProfile *p,ZwkProfileContext **out) {
    if (!out) return ZWK_PROFILE_INVALID;
    *out=NULL;
    int result=owner(p);if (result) return result;
    if (!p->accepting || p->owner_closed) return ZWK_PROFILE_CLOSED;
    if (p->contexts==p->capacity) return ZWK_PROFILE_FULL;
    if (sizeof(ZwkProfileContext)>p->limit-p->owned_bytes) return ZWK_PROFILE_CAPACITY;
    ZwkProfileContext *c=profile_malloc(sizeof(*c));
    if (!c) return ZWK_PROFILE_OOM;
    *c=(ZwkProfileContext){p,NULL,1,FALSE,FALSE};
    /* Keep the physical profile/lock through the actual Context finalizer,
     * independently of the owner's Context token and Profile.close. */
    profile_ref(p);++p->contexts;p->owned_bytes+=sizeof(*c);
    if (p->peak_bytes<p->owned_bytes) p->peak_bytes=p->owned_bytes;
    atomic_fetch_add_explicit(&live_contexts,1,memory_order_relaxed);
    atomic_fetch_add_explicit(&live_bytes,sizeof(*c),memory_order_relaxed);
    WebKitWebsiteDataManager *manager=g_object_ref(p->manager);
    c->context=webkit_web_context_new_with_website_data_manager(manager);
    g_object_unref(manager);
    if (!c->context) {
        c->owner_closed=TRUE;context_unref(c);
        return ZWK_PROFILE_NATIVE_FAILED;
    }
    g_atomic_int_inc(&c->refs);
    g_object_set_qdata_full(G_OBJECT(c->context),g_quark_from_static_string("ziggurat-profile-context-owner"),c,context_gone);
    if (p->tls && p->tls->certificate)
        webkit_web_context_allow_tls_certificate_for_host(c->context,p->tls->certificate,"127.0.0.1");
    if (!p->accepting || p->owner_closed) {
        zwk_profile_context_close(c);
        return ZWK_PROFILE_CLOSED;
    }
    *out=c;
    return ZWK_PROFILE_OK;
}
int zwk_profile_context_get(ZwkProfileContext *c,void **out) {
    if (!out || !c) return ZWK_PROFILE_INVALID;
    *out=NULL;
    int result=owner(c->profile);if (result) return result;
    if (c->owner_closed || (!c->profile->accepting && !c->admitted)) return ZWK_PROFILE_CLOSED;
    *out=c->context;
    return ZWK_PROFILE_OK;
}
int zwk_profile_context_admit(ZwkProfileContext *c) {
    if (!c) return ZWK_PROFILE_INVALID;
    int result=owner(c->profile);if (result) return result;
    if (c->owner_closed || !c->profile->accepting) return ZWK_PROFILE_CLOSED;
    if (c->admitted) return ZWK_PROFILE_INVALID;
    c->admitted=TRUE;
    return ZWK_PROFILE_OK;
}
int zwk_profile_context_close(ZwkProfileContext *c) {
    if (!c) return ZWK_PROFILE_INVALID;
    int result=owner(c->profile);if (result) return result;
    if (c->owner_closed) return ZWK_PROFILE_CLOSED;
    c->owner_closed=TRUE;
    WebKitWebContext *context=c->context;c->context=NULL;
    if (context) g_object_unref(context);
    context_unref(c);
    return ZWK_PROFILE_OK;
}
void zwk_profile_counts(uint32_t *profiles,uint32_t *contexts,size_t *bytes) {
    if (profiles) *profiles=atomic_load_explicit(&live_profiles,memory_order_relaxed);
    if (contexts) *contexts=atomic_load_explicit(&live_contexts,memory_order_relaxed);
    if (bytes) *bytes=atomic_load_explicit(&live_bytes,memory_order_relaxed);
}
