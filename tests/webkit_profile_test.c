#define _GNU_SOURCE
#include "../src/webview/webkit_profile.h"
#include <webkit2/webkit2.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/file.h>
#include <unistd.h>

#define REQUIRE(value) do { if (!(value)) { g_printerr("profile native assertion %s:%d: %s\n",__FILE__,__LINE__,#value);return __LINE__; } } while (0)

static int require_counts(uint32_t profiles,uint32_t contexts) {
    uint32_t a=0,b=0;size_t bytes=0;
    zwk_profile_counts(&a,&b,&bytes);
    return a==profiles && b==contexts && ((a!=0)==(bytes!=0));
}
typedef struct FinalThread { GThread *thread;unsigned count; } FinalThread;
static void final_thread(gpointer raw) {
    FinalThread *value=raw;
    g_assert(value->thread==g_thread_self());
    ++value->count;
}
int test_profile_init_gtk(void) { return gtk_init_check(NULL,NULL); }
/* No WebView or native window is constructed. A private main context supplies
 * the manager's owner loop without running a nested application event loop. */
int test_profile_native(int borrowed_lock,const char *data,const char *cache,const char *cookies) {
    REQUIRE(gtk_init_check(NULL,NULL));
    REQUIRE(require_counts(0,0));
    GMainContext *main=g_main_context_new();
    g_main_context_push_thread_default(main);
    ZwkProfileOptions options={.contexts=2,.bytes=65536,.leases=2};
    size_t base=0;
    REQUIRE(zwk_profile_measure(data,cache,cookies,&base)==ZWK_PROFILE_OK && base);
    ZwkProfile *p=NULL;int code=71;
    REQUIRE(zwk_profile_create(-1,data,cache,cookies,&options,&p,&code)==ZWK_PROFILE_SYSTEM && code==EBADF && !p);
    options.bytes=base-1;
    REQUIRE(zwk_profile_create(borrowed_lock,data,cache,cookies,&options,&p,&code)==ZWK_PROFILE_CAPACITY && !code && !p);
    options.bytes=65536;
    zwk_profile_test_fail_after(0);
    REQUIRE(zwk_profile_create(borrowed_lock,data,cache,cookies,&options,&p,&code)==ZWK_PROFILE_OOM && !code && !p);
    zwk_profile_test_fail_after(-1);
    REQUIRE(require_counts(0,0));
    REQUIRE(zwk_profile_create(borrowed_lock,data,cache,cookies,&options,&p,&code)==ZWK_PROFILE_OK && !code);
    ZwkProfileContext *a=NULL,*b=NULL,*third=NULL;void *va=NULL,*vb=NULL;
    zwk_profile_test_fail_after(0);
    REQUIRE(zwk_profile_context_create(p,&a)==ZWK_PROFILE_OOM && !a);
    zwk_profile_test_fail_after(-1);
    REQUIRE(zwk_profile_context_create(p,&a)==ZWK_PROFILE_OK);
    REQUIRE(zwk_profile_context_create(p,&b)==ZWK_PROFILE_OK);
    REQUIRE(zwk_profile_context_create(p,&third)==ZWK_PROFILE_FULL && !third);
    REQUIRE(zwk_profile_context_get(a,&va)==ZWK_PROFILE_OK);
    REQUIRE(zwk_profile_context_get(b,&vb)==ZWK_PROFILE_OK && va!=vb);
    WebKitWebsiteDataManager *ma=webkit_web_context_get_website_data_manager(va);
    WebKitWebsiteDataManager *mb=webkit_web_context_get_website_data_manager(vb);
    REQUIRE(ma==mb && !webkit_website_data_manager_is_ephemeral(ma));
    REQUIRE(!strcmp(webkit_website_data_manager_get_base_data_directory(ma),data));
    REQUIRE(!strcmp(webkit_website_data_manager_get_base_cache_directory(ma),cache));
    REQUIRE(!webkit_website_data_manager_get_persistent_credential_storage_enabled(ma));
    REQUIRE(webkit_website_data_manager_get_tls_errors_policy(ma)==WEBKIT_TLS_ERRORS_POLICY_FAIL);
    ZwkProfileStats stats;
    REQUIRE(zwk_profile_stats(p,&stats)==ZWK_PROFILE_OK && stats.contexts==2 && stats.context_capacity==2);
    REQUIRE(stats.owned_bytes>base && stats.owned_bytes==stats.peak_bytes);
    FinalThread finalized={g_thread_self(),0};
    g_object_set_data_full(G_OBJECT(ma),"profile-test-thread",&finalized,final_thread);
    /* Closing a logical token does not release the physical slot while another
     * subsystem still owns the actual GObject. */
    g_object_ref(va);
    REQUIRE(zwk_profile_context_close(a)==ZWK_PROFILE_OK);
    REQUIRE(zwk_profile_context_create(p,&third)==ZWK_PROFILE_FULL && !third);
    g_object_unref(va);
    REQUIRE(zwk_profile_context_create(p,&third)==ZWK_PROFILE_OK);
    REQUIRE(zwk_profile_context_close(third)==ZWK_PROFILE_OK);
    g_object_ref(vb);g_object_ref(ma);
    REQUIRE(zwk_profile_seal(p)==ZWK_PROFILE_OK);
    REQUIRE(zwk_profile_context_create(p,&third)==ZWK_PROFILE_CLOSED && !third);
    REQUIRE(zwk_profile_context_get(b,&va)==ZWK_PROFILE_CLOSED && !va);
    REQUIRE(zwk_profile_close(p)==ZWK_PROFILE_OK);
    REQUIRE(require_counts(1,1));
    REQUIRE(zwk_profile_context_close(b)==ZWK_PROFILE_OK);
    REQUIRE(require_counts(1,1));
    g_object_unref(vb);
    REQUIRE(require_counts(1,0));
    /* Final manager ref contains no Zig object and may be released after every
     * logical Profile/Context owner has gone. */
    g_object_unref(ma);
    REQUIRE(require_counts(0,0));
    REQUIRE(finalized.count==1);
    /* Dispose is not finalization. Accounting and locking remain physically
     * owned through actual last unref, including a previously disposed object. */
    REQUIRE(zwk_profile_create(borrowed_lock,data,cache,cookies,&options,&p,&code)==ZWK_PROFILE_OK);
    REQUIRE(zwk_profile_context_create(p,&a)==ZWK_PROFILE_OK);
    REQUIRE(zwk_profile_context_get(a,&va)==ZWK_PROFILE_OK);
    ma=webkit_web_context_get_website_data_manager(va);
    g_object_ref(va);g_object_ref(ma);
    g_object_set_data_full(G_OBJECT(va),"profile-test-thread",&finalized,final_thread);
    g_object_run_dispose(G_OBJECT(va));
    REQUIRE(zwk_profile_close(p)==ZWK_PROFILE_OK);
    REQUIRE(zwk_profile_context_close(a)==ZWK_PROFILE_OK);
    REQUIRE(require_counts(1,1));
    g_object_unref(va);
    REQUIRE(require_counts(1,0) && finalized.count==2);
    g_object_run_dispose(G_OBJECT(ma));
    REQUIRE(require_counts(1,0));
    g_object_unref(ma);
    REQUIRE(require_counts(0,0));
    /* Native metadata capacity is independent from context count. */
    options.bytes=base;
    REQUIRE(zwk_profile_create(borrowed_lock,data,cache,cookies,&options,&p,&code)==ZWK_PROFILE_OK);
    REQUIRE(zwk_profile_context_create(p,&a)==ZWK_PROFILE_CAPACITY && !a);
    REQUIRE(zwk_profile_close(p)==ZWK_PROFILE_OK);
    REQUIRE(require_counts(0,0));
    g_main_context_pop_thread_default(main);
    g_main_context_unref(main);
    return 0;
}

/* Retain an engine object after all Zig storage is released. The caller later
 * invokes drop_native; this API deliberately has no Zig callback/context. */
void *test_profile_retain_context(void *raw) { return g_object_ref(raw); }
void test_profile_drop_native(void *raw) { g_object_unref(raw); }
int test_profile_lock_busy(const char *root) {
    char path[4096];
    int length=g_snprintf(path,sizeof(path),"%s/.ziggurat-profile.lock",root);
    if (length<0 || (size_t)length>=sizeof(path)) return -1;
    int fd=open(path,O_RDWR|O_CLOEXEC|O_NOFOLLOW);
    if (fd<0) return -1;
    int result=flock(fd,LOCK_EX|LOCK_NB);
    int code=errno;
    close(fd);
    return result==0?0:code==EWOULDBLOCK?1:-1;
}
