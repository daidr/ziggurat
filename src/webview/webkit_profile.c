#define _GNU_SOURCE
#include "webkit_profile.h"
#include <webkit2/webkit2.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <glib/gstdio.h>
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
    zwk_dmabuf_prepare();
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

/* WebKitGTK draws pages with its DMA-BUF renderer where it can, and that
   renderer shows blank windows on NVIDIA's driver, in virtual machines and
   in containers. So it is off (WEBKIT_DISABLE_DMABUF_RENDERER=1) unless the
   app leaves it on everywhere (1) or where the host is known to draw with
   it (2): GTK opens a Wayland display and OpenGL runs on a GPU of Mesa's,
   outside containers, WSL and virtual machines. The user's variable always
   wins. It is decided once, before the first web context. */
static int dmabuf_mode;
static gboolean dmabuf_decided;
void zwk_set_dmabuf_renderer(int mode) { dmabuf_mode=mode; }

static gboolean exists_in(const char *root,const char *path) {
    gchar *full=g_build_filename(root,path,NULL);
    gboolean found=g_file_test(full,G_FILE_TEST_EXISTS);
    g_free(full); return found;
}
/* DRM drivers that only show what the CPU drew. */
static gboolean display_only(const char *driver) {
    static const char *const names[]={"simpledrm","simple-framebuffer","bochs","bochs-drm","cirrus","cirrus-qemu","vboxvideo","hyperv_drm","ast","mgag200","udl","vkms"};
    for (size_t i=0;i<G_N_ELEMENTS(names);i++) if (!strcmp(driver,names[i])) return TRUE;
    return FALSE;
}
/* A render node of a driver with 3D, under root's /sys/class/drm. */
static gboolean gpu_device_in(const char *root,const char *gallium) {
    gchar *drm=g_build_filename(root,"sys/class/drm",NULL);
    GDir *dir=g_dir_open(drm,0,NULL);
    gboolean found=FALSE;
    if (dir) {
        for (const char *name;!found && (name=g_dir_read_name(dir));) {
            if (strncmp(name,"renderD",7)) continue;
            gchar *link=g_build_filename(drm,name,"device","driver",NULL);
            gchar *target=g_file_read_link(link,NULL);
            gchar *driver=target?g_path_get_basename(target):NULL;
            found=!driver || !display_only(driver);
            g_free(driver); g_free(target); g_free(link);
        }
        g_dir_close(dir);
    }
    g_free(drm);
    if (!found && exists_in(root,"dev/dxg")) found=gallium && !strcmp(gallium,"d3d12");
    return found;
}
static const char *env(const char *const *environment,const char *name) {
    if (!environment) return g_getenv(name);
    return g_environ_getenv((gchar **)environment,name);
}
/* Whether the host draws with the renderer: environment as g_get_environ
   gives it (NULL for the process's own), root the file system's root. */
int zwk_dmabuf_safe(const char *const *environment,const char *root) {
    /* GDK_BACKEND lists the backends GTK tries, Wayland first by default. */
    const char *backends=env(environment,"GDK_BACKEND");
    if (backends && backends[0]) {
        size_t first=strcspn(backends,",");
        if (!(first==1 && backends[0]=='*') && !(first==7 && !strncmp(backends,"wayland",7)) && first>0) return 0;
    }
    /* A display whose socket is gone, as a stale variable's, does not count. */
    const char *display=env(environment,"WAYLAND_DISPLAY");
    if (!display || !display[0]) return 0;
    gchar *socket=NULL;
    if (g_path_is_absolute(display)) socket=g_strdup(display);
    else {
        const char *runtime=env(environment,"XDG_RUNTIME_DIR");
        if (!runtime || !runtime[0]) return 0;
        socket=g_build_filename(runtime,display,NULL);
    }
    GStatBuf st;
    gboolean listening=g_stat(socket,&st)==0 && S_ISSOCK(st.st_mode);
    g_free(socket);
    if (!listening) return 0;
    /* Software OpenGL (llvmpipe). */
    const char *software=env(environment,"LIBGL_ALWAYS_SOFTWARE");
    if (software && software[0] && strcmp(software,"0") && g_ascii_strcasecmp(software,"false")) return 0;
    const char *gallium=env(environment,"GALLIUM_DRIVER");
    if (gallium && (!strcmp(gallium,"llvmpipe") || !strcmp(gallium,"softpipe"))) return 0;
    /* NVIDIA's driver, a container, WSL. */
    static const char *const unsafe[]={"sys/module/nvidia","proc/driver/nvidia/version","dev/nvidiactl",".dockerenv","run/.containerenv","dev/dxg"};
    for (size_t i=0;i<G_N_ELEMENTS(unsafe);i++) if (exists_in(root,unsafe[i])) return 0;
    /* A virtual machine, by its firmware's product or vendor. */
    static const char *const fields[]={"sys/class/dmi/id/product_name","sys/class/dmi/id/sys_vendor"};
    static const char *const machines[]={"virtualbox","vmware","qemu","kvm","bochs","parallels","xen","hyper-v","virtual machine","bhyve"};
    for (size_t i=0;i<G_N_ELEMENTS(fields);i++) {
        gchar *path=g_build_filename(root,fields[i],NULL), *text=NULL;
        if (g_file_get_contents(path,&text,NULL,NULL)) {
            gchar *lower=g_ascii_strdown(text,-1);
            gboolean vm=FALSE;
            for (size_t m=0;m<G_N_ELEMENTS(machines);m++) vm=vm || strstr(lower,machines[m])!=NULL;
            g_free(lower); g_free(text); g_free(path);
            if (vm) return 0;
        } else g_free(path);
    }
    return gpu_device_in(root,gallium)?1:0;
}
/* Whether to set WEBKIT_DISABLE_DMABUF_RENDERER=1 for mode. */
int zwk_dmabuf_disables(int mode,const char *const *environment,const char *root) {
    const char *user=env(environment,"WEBKIT_DISABLE_DMABUF_RENDERER");
    if (user && user[0]) return 0;
    if (mode==1) return 0;
    if (mode==2) return !zwk_dmabuf_safe(environment,root);
    return 1;
}
void zwk_dmabuf_prepare(void) {
    if (dmabuf_decided) return;
    dmabuf_decided=TRUE;
    if (zwk_dmabuf_disables(dmabuf_mode,NULL,"/")) g_setenv("WEBKIT_DISABLE_DMABUF_RENDERER","1",FALSE);
}
