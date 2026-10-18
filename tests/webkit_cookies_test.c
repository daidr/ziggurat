#include "../src/webview/webkit_cookies.h"
#include <webkit2/webkit2.h>
#include <string.h>

#define REQUIRE(value) do { if (!(value)) { g_printerr("cookie native assertion %s:%d: %s\n",__FILE__,__LINE__,#value);return __LINE__; } } while (0)
typedef struct Probe { ZwkCookies *store;unsigned called;int bad; } Probe;
static ZwkCookieSlice input(const char *p) { return (ZwkCookieSlice){(const unsigned char *)p,strlen(p)}; }
static int empty(void) {uint32_t stores=1,ops=1;size_t bytes=1;zwk_cookies_counts(&stores,&ops,&bytes);return !stores && !ops && !bytes;}
static void complete(void *raw,uint64_t token,int result,uint32_t domain,int32_t code,const ZwkCookieRow *rows,size_t count) {
    (void)rows;
    Probe *p=raw;++p->called;
    if(token!=3 || result || domain || code || count) p->bad=1;
    ZwkCookiesStats stats;
    if(zwk_cookies_stats(p->store,&stats) || stats.pending!=1) p->bad=1;
    /* Reentrant close can consume the owner in a synchronous completion. The
     * physical Op and the submit stack each retain C-only storage. */
    if(zwk_cookies_close(p->store)) p->bad=1;
    p->store=NULL;
}
static gpointer wrong_thread(gpointer data) {
    ZwkCookieRequest request={0};request.kind=ZWK_COOKIE_LIST_ALL;
    if (zwk_cookies_replace(data,8,(const ZwkCookieRow *)(uintptr_t)4096,1)!=ZWK_COOKIES_WRONG_THREAD) return GINT_TO_POINTER(-1);
    ZwkCookieRequest key={0};key.kind=ZWK_COOKIE_DELETE_KEY;key.name=(ZwkCookieSlice){(const unsigned char *)(uintptr_t)4096,1};
    if (zwk_cookies_submit(data,9,&key)!=ZWK_COOKIES_WRONG_THREAD) return GINT_TO_POINTER(-1);
    return GINT_TO_POINTER(zwk_cookies_submit(data,7,&request));
}
typedef struct Preservation { ZwkCookies *store;GMainLoop *loop;unsigned stage,called;int bad; } Preservation;
static gboolean preservation_drive(gpointer raw);
static void preservation_complete(void *raw,uint64_t token,int result,uint32_t domain,int32_t code,const ZwkCookieRow *rows,size_t count) {
    Preservation *p=raw;++p->called;
    if(result || domain || code || token!=p->stage+20) p->bad=1;
    if(p->stage==0) { if(count) p->bad=1; }
    else if(p->stage==1) {
        if(count!=1 || rows[0].name.len!=3 || memcmp(rows[0].name.ptr,"old",3) || rows[0].value.len!=8 || memcmp(rows[0].value.ptr,"original",8)) p->bad=1;
    } else p->bad=1;
    ++p->stage;g_idle_add(preservation_drive,p);
}
static gboolean preservation_timeout(gpointer raw) {
    Preservation *p=raw;p->bad=1;g_main_loop_quit(p->loop);return G_SOURCE_CONTINUE;
}
static gboolean preservation_drive(gpointer raw) {
    Preservation *p=raw;
    if(p->stage==0) {
        ZwkCookieRequest old={0};old.kind=ZWK_COOKIE_SET;old.same_site=1;old.name=input("old");old.value=input("original");old.domain=input("preserve-replace.test");old.path=input("/");
        if(zwk_cookies_submit(p->store,20,&old)) {p->bad=1;g_main_loop_quit(p->loop);}
    } else if(p->stage==1) {
        const ZwkCookieRow rows[]={
            {input("new"),input("candidate"),input("preserve-replace.test"),input("/"),0,0,1},
            {input("other"),input("candidate"),input("preserve-replace.test"),input("/nested"),0,0,1}
        };
        ZwkCookiesStats before,after;
        if(zwk_cookies_stats(p->store,&before) || before.pending) p->bad=1;
        zwk_cookies_test_fail_after(0);
        ZwkCookieRow oversized=rows[0];oversized.value=(ZwkCookieSlice){(const unsigned char *)(uintptr_t)4096,32u*1024u};
        if(zwk_cookies_replace(p->store,30,&oversized,1)!=ZWK_COOKIES_CAPACITY) p->bad=1;
        if(zwk_cookies_replace(p->store,30,rows,2)!=ZWK_COOKIES_OOM) p->bad=1;
        zwk_cookies_test_fail_after(-1);
        for(int at=0;at<2;++at) {
            zwk_cookies_test_cookie_fail_after(at);
            if(zwk_cookies_replace(p->store,30,rows,2)!=ZWK_COOKIES_OOM) p->bad=1;
        }
        zwk_cookies_test_cookie_fail_after(-1);
        ZwkCookieRequest key={0};key.kind=ZWK_COOKIE_DELETE_KEY;key.name=input("old");key.domain=input("preserve-replace.test");key.path=input("/");
        zwk_cookies_test_fail_after(0);
        if(zwk_cookies_submit(p->store,30,&key)!=ZWK_COOKIES_OOM) p->bad=1;
        zwk_cookies_test_fail_after(-1);
        zwk_cookies_test_cookie_fail_after(0);
        if(zwk_cookies_submit(p->store,30,&key)!=ZWK_COOKIES_OOM) p->bad=1;
        zwk_cookies_test_cookie_fail_after(-1);
        size_t candidate=zwk_cookies_test_op_size()+2*(sizeof(ZwkCookieRow)+sizeof(GList));
        for(size_t i=0;i<2;++i) candidate+=rows[i].name.len+rows[i].value.len+rows[i].domain.len+rows[i].path.len+4;
        size_t expected_peak=before.bytes+candidate;
        if(expected_peak<before.peak_bytes) expected_peak=before.peak_bytes;
        if(zwk_cookies_stats(p->store,&after) || after.pending || before.bytes!=after.bytes || expected_peak!=after.peak_bytes || p->called!=1) p->bad=1;
        ZwkCookieRequest query={0};query.kind=ZWK_COOKIE_QUERY;query.url=input("http://preserve-replace.test/");
        if(zwk_cookies_submit(p->store,21,&query)) {p->bad=1;g_main_loop_quit(p->loop);}
    } else g_main_loop_quit(p->loop);
    return G_SOURCE_REMOVE;
}
static int replacement_preserves_before_acceptance(ZwkProfile *profile) {
    Preservation p={0};ZwkCookiesOptions options={65536,1,2};
    REQUIRE(zwk_cookies_create(profile,&options,&p.store)==ZWK_COOKIES_OK);
    REQUIRE(zwk_cookies_bind(p.store,&p,preservation_complete)==ZWK_COOKIES_OK);
    p.loop=g_main_loop_new(NULL,FALSE);
    guint timer=g_timeout_add_seconds(8,preservation_timeout,&p);
    g_idle_add(preservation_drive,&p);
    // The independent fixture owns this top-level GLib loop. Production has
    // no synchronous wait or nested application event loop.
    g_main_loop_run(p.loop);
    g_source_remove(timer);g_main_loop_unref(p.loop);
    REQUIRE(!p.bad && p.called==2 && p.stage==2);
    REQUIRE(zwk_cookies_close(p.store)==ZWK_COOKIES_OK && empty());
    return 0;
}
int test_cookies_init_gtk(void) {return gtk_init_check(NULL,NULL);}
int test_cookies_native(void *raw_profile) {
    ZwkProfile *profile=raw_profile;
    REQUIRE(empty());
    ZwkCookiesOptions options={65536,1,1};ZwkCookies *store=NULL;
    zwk_cookies_test_fail_after(0);
    REQUIRE(zwk_cookies_create(profile,&options,&store)==ZWK_COOKIES_OOM && !store && empty());
    zwk_cookies_test_fail_after(-1);
    REQUIRE(zwk_cookies_create(profile,&options,&store)==ZWK_COOKIES_OK);
    Probe probe={store,0,0};
    REQUIRE(zwk_cookies_bind(store,&probe,complete)==ZWK_COOKIES_OK);
    ZwkCookieRequest request={0};request.kind=ZWK_COOKIE_QUERY;request.url=input("https://cold-cookie.test/");
    zwk_cookies_test_fail_after(0);
    REQUIRE(zwk_cookies_submit(store,1,&request)==ZWK_COOKIES_OOM && !probe.called);
    zwk_cookies_test_fail_after(-1);
    ZwkCookiesStats stats;REQUIRE(zwk_cookies_stats(store,&stats)==ZWK_COOKIES_OK && !stats.pending);
    ZwkCookieRequest invalid={0};
    REQUIRE(zwk_cookies_submit(store,2,&invalid)==ZWK_COOKIES_INVALID && !probe.called);
    const ZwkCookieRow replacement[]={
        {input("one"),input("first"),input("native-replace.test"),input("/"),0,0,1},
        {input("two"),input("second"),input("native-replace.test"),input("/nested"),0,0,2}
    };
    for(unsigned kind=0;kind<3;++kind) {
        if(kind) {
            REQUIRE(zwk_cookies_create(profile,&options,&store)==ZWK_COOKIES_OK);
            probe=(Probe){store,0,0};
            REQUIRE(zwk_cookies_bind(store,&probe,complete)==ZWK_COOKIES_OK);
            request=(ZwkCookieRequest){0};request.kind=ZWK_COOKIE_LIST_ALL;
            if (kind==2) {
                // This Store's native row ceiling also bounds replacement input.
                REQUIRE(zwk_cookies_close(store)==ZWK_COOKIES_OK);
                options.rows=2;REQUIRE(zwk_cookies_create(profile,&options,&store)==ZWK_COOKIES_OK);
                probe=(Probe){store,0,0};REQUIRE(zwk_cookies_bind(store,&probe,complete)==ZWK_COOKIES_OK);
            }
            for(unsigned missing=1;missing<=3;++missing) {
                if(kind==2) zwk_cookies_test_missing_replace_api(missing); else zwk_cookies_test_missing_list_api(missing);
                /* If submit reaches malloc this becomes OOM. Neither a slot,
                 * allocation nor completion may be acquired by an absent pair. */
                zwk_cookies_test_fail_after(0);
                REQUIRE((kind==2?zwk_cookies_replace(store,6,replacement,2):zwk_cookies_submit(store,6,&request))==ZWK_COOKIES_UNSUPPORTED);
                REQUIRE(zwk_cookies_stats(store,&stats)==ZWK_COOKIES_OK && !stats.pending && stats.bytes==zwk_cookies_owner_size() && !probe.called);
            }
            GThread *thread=g_thread_new("cookie-owner-probe",wrong_thread,store);
            REQUIRE(GPOINTER_TO_INT(g_thread_join(thread))==ZWK_COOKIES_WRONG_THREAD);
            zwk_cookies_test_missing_list_api(0);
            zwk_cookies_test_missing_replace_api(0);
            if(kind==2) {
                REQUIRE(zwk_cookies_replace(store,6,replacement,2)==ZWK_COOKIES_OOM);
                zwk_cookies_test_fail_after(-1);
                for(int before_failure=0;before_failure<2;++before_failure) {
                    zwk_cookies_test_cookie_fail_after(before_failure);
                    REQUIRE(zwk_cookies_replace(store,6,replacement,2)==ZWK_COOKIES_OOM);
                    REQUIRE(zwk_cookies_stats(store,&stats)==ZWK_COOKIES_OK && !stats.pending && stats.bytes==zwk_cookies_owner_size() && !probe.called);
                }
                zwk_cookies_test_cookie_fail_after(-1);
            }
            zwk_cookies_test_fail_after(-1);
        }
        zwk_cookies_test_synchronous_query(1);
        REQUIRE((kind==2?zwk_cookies_replace(store,3,replacement,2):zwk_cookies_submit(store,3,&request))==ZWK_COOKIES_OK);
        zwk_cookies_test_synchronous_query(0);
        REQUIRE(probe.called==1 && !probe.bad && !probe.store);
        /* g_task_return_pointer also schedules its completed notification.
         * Only immediately-ready fixture sources are drained here. */
        for(unsigned i=0;i<64 && !empty();++i) g_main_context_iteration(NULL,FALSE);
        REQUIRE(empty());
    }
    REQUIRE(zwk_cookies_create(profile,&options,&store)==ZWK_COOKIES_OK);
    probe=(Probe){store,0,0};REQUIRE(zwk_cookies_bind(store,&probe,complete)==ZWK_COOKIES_OK);
    ZwkCookieRequest key={0};key.kind=ZWK_COOKIE_DELETE_KEY;key.name=input("__Host-native");key.domain=input("native-delete.test");key.path=input("/");
    ZwkCookiesStats before;
    REQUIRE(zwk_cookies_stats(store,&before)==ZWK_COOKIES_OK);
    ZwkCookieRequest invalid_key=key;invalid_key.value=input("not-key-only");
    REQUIRE(zwk_cookies_submit(store,3,&invalid_key)==ZWK_COOKIES_INVALID);
    zwk_cookies_test_fail_after(0);
    REQUIRE(zwk_cookies_submit(store,3,&key)==ZWK_COOKIES_OOM);
    zwk_cookies_test_fail_after(-1);
    zwk_cookies_test_cookie_fail_after(0);
    REQUIRE(zwk_cookies_submit(store,3,&key)==ZWK_COOKIES_OOM);
    zwk_cookies_test_cookie_fail_after(-1);
    REQUIRE(zwk_cookies_stats(store,&stats)==ZWK_COOKIES_OK && !stats.pending && stats.bytes==before.bytes && stats.peak_bytes==before.peak_bytes && !probe.called);
    zwk_cookies_test_synchronous_query(1);
    REQUIRE(zwk_cookies_submit(store,3,&key)==ZWK_COOKIES_OK);
    zwk_cookies_test_synchronous_query(0);
    REQUIRE(probe.called==1 && !probe.bad && !probe.store);
    for(unsigned i=0;i<64 && !empty();++i) g_main_context_iteration(NULL,FALSE);
    REQUIRE(empty());
    g_printerr("CookieStore native records: Store=%zu Op=%zu Row=%zu; deleteKey malloc/cookie failure before acceptance and synchronous close\n",zwk_cookies_owner_size(),zwk_cookies_test_op_size(),sizeof(ZwkCookieRow));
    options.bytes=zwk_cookies_owner_size()+1;
    REQUIRE(zwk_cookies_create(profile,&options,&store)==ZWK_COOKIES_OK);
    probe=(Probe){store,0,0};REQUIRE(zwk_cookies_bind(store,&probe,complete)==ZWK_COOKIES_OK);
    REQUIRE(zwk_cookies_submit(store,4,&request)==ZWK_COOKIES_CAPACITY && !probe.called);
    REQUIRE(zwk_cookies_submit(store,4,&key)==ZWK_COOKIES_CAPACITY && !probe.called);
    REQUIRE(zwk_cookies_seal(store)==ZWK_COOKIES_OK);
    REQUIRE(zwk_cookies_submit(store,5,&request)==ZWK_COOKIES_CLOSED);
    zwk_cookies_test_missing_list_api(3);
    REQUIRE(zwk_cookies_submit(store,5,&request)==ZWK_COOKIES_CLOSED);
    zwk_cookies_test_missing_list_api(0);
    REQUIRE(zwk_cookies_close(store)==ZWK_COOKIES_OK && empty());
    REQUIRE(replacement_preserves_before_acceptance(profile)==0);
    return 0;
}
