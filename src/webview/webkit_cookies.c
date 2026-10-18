#include "webkit_cookies.h"
#include <webkit2/webkit2.h>
#include <libsoup/soup.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>

/* These APIs first appeared in 2.42. ELF weak references let a module built
 * against 2.40 headers keep its old runtime requirement. Both members must be
 * present before accepting an operation. Existing strong WebKit references
 * retain the loaded library through every late finish; no loader is opened. */
extern void webkit_cookie_manager_get_all_cookies(WebKitCookieManager *,GCancellable *,GAsyncReadyCallback,gpointer) __attribute__((weak));
extern GList *webkit_cookie_manager_get_all_cookies_finish(WebKitCookieManager *,GAsyncResult *,GError **) __attribute__((weak));
extern void webkit_cookie_manager_replace_cookies(WebKitCookieManager *,GList *,GCancellable *,GAsyncReadyCallback,gpointer) __attribute__((weak));
extern gboolean webkit_cookie_manager_replace_cookies_finish(WebKitCookieManager *,GAsyncResult *,GError **) __attribute__((weak));

#define COOKIE_PENDING 8u
#define COOKIE_ROWS 128u
#define COOKIE_BYTES (4u*1024u*1024u)
#define COOKIE_INPUT (32u*1024u)
typedef struct CookieOp CookieOp;
struct ZwkCookies {
    GThread *thread;
    ZwkProfile *profile;
    WebKitWebsiteDataManager *manager;
    WebKitCookieManager *cookies;
    void *owner;
    ZwkCookiesComplete complete;
    CookieOp *ops[COOKIE_PENDING];
    size_t bytes,peak_bytes,limit;
    uint32_t capacity,rows,pending;
    unsigned refs;
    gboolean sealed,closed;
};
struct CookieOp {
    ZwkCookies *store;
    GCancellable *cancel;
    union { SoupCookie *single; GList *replacement; } input;
    uint64_t token;
    uint32_t kind,filter_flags,index;
    size_t bytes;
    char *url,*name,*value,*domain,*path;
};
_Static_assert(sizeof(CookieOp)%_Alignof(ZwkCookieRow)==0,"Cookie row alignment");
_Static_assert(sizeof(ZwkCookieRow)%_Alignof(GList)==0,"Embedded list alignment");
_Static_assert(sizeof(GList)==3*sizeof(void *),"Cookie input list descriptor ABI");
static _Atomic uint32_t live_stores,live_ops;
static _Atomic size_t live_bytes;
#ifdef ZWK_COOKIES_TESTING
static int fail_after=-1;
static int synchronous_query;
static unsigned missing_list_api;
static unsigned missing_replace_api;
static int cookie_fail_after=-1;
void zwk_cookies_test_fail_after(int n) { fail_after=n; }
void zwk_cookies_test_synchronous_query(int enabled) { synchronous_query=enabled; }
void zwk_cookies_test_missing_list_api(unsigned missing) { missing_list_api=missing; }
void zwk_cookies_test_missing_replace_api(unsigned missing) { missing_replace_api=missing; }
void zwk_cookies_test_cookie_fail_after(int n) { cookie_fail_after=n; }
size_t zwk_cookies_test_op_size(void) { return sizeof(CookieOp); }
static void *cookie_malloc(size_t n) {
    if (fail_after==0) return NULL;
    if (fail_after>0) --fail_after;
    return malloc(n);
}
#else
#define cookie_malloc malloc
#endif
static int list_api_available(void) {
#ifdef ZWK_COOKIES_TESTING
    if (missing_list_api&3u) return FALSE;
#endif
    return webkit_cookie_manager_get_all_cookies && webkit_cookie_manager_get_all_cookies_finish;
}
static int replace_api_available(void) {
#ifdef ZWK_COOKIES_TESTING
    if (missing_replace_api&3u) return FALSE;
#endif
    return webkit_cookie_manager_replace_cookies && webkit_cookie_manager_replace_cookies_finish;
}
static int owner(ZwkCookies *s) {
    if (!s) return ZWK_COOKIES_INVALID;
    return s->thread==g_thread_self()?ZWK_COOKIES_OK:ZWK_COOKIES_WRONG_THREAD;
}
static void store_ref(ZwkCookies *s) { ++s->refs; }
static void store_unref(ZwkCookies *s) {
    g_assert(s->thread==g_thread_self() && s->refs);
    if (--s->refs) return;
    g_assert(s->closed && !s->pending && !s->owner);
    /* Only native storage remains. Never revisit Zig/App/caller allocators. */
    g_object_unref(s->cookies);
    g_object_unref(s->manager);
    zwk_profile_lease_release(s->profile);
    atomic_fetch_sub_explicit(&live_stores,1,memory_order_relaxed);
    atomic_fetch_sub_explicit(&live_bytes,sizeof(*s),memory_order_relaxed);
    free(s);
}
size_t zwk_cookies_owner_size(void) { return sizeof(ZwkCookies); }
int zwk_cookies_create(ZwkProfile *p,const ZwkCookiesOptions *options,ZwkCookies **out) {
    if (!out) return ZWK_COOKIES_INVALID;
    *out=NULL;
    if (!options || !options->pending || options->pending>COOKIE_PENDING || !options->rows || options->rows>COOKIE_ROWS || options->bytes<sizeof(ZwkCookies) || options->bytes>COOKIE_BYTES) return ZWK_COOKIES_INVALID;
    int status=zwk_profile_lease_retain(p);
    if (status) return status;
    void *raw_manager=NULL;
    status=zwk_profile_manager_ref(p,&raw_manager);
    if (status) { zwk_profile_lease_release(p);return status; }
    WebKitWebsiteDataManager *manager=raw_manager;
    ZwkCookies *s=cookie_malloc(sizeof(*s));
    if (!s) { g_object_unref(manager);zwk_profile_lease_release(p);return ZWK_COOKIES_OOM; }
    memset(s,0,sizeof(*s));
    s->thread=g_thread_self();s->refs=1;s->profile=p;s->manager=manager;
    s->cookies=g_object_ref(webkit_website_data_manager_get_cookie_manager(manager));
    s->bytes=s->peak_bytes=sizeof(*s);s->limit=options->bytes;
    s->capacity=options->pending;s->rows=options->rows;
    atomic_fetch_add_explicit(&live_stores,1,memory_order_relaxed);
    atomic_fetch_add_explicit(&live_bytes,sizeof(*s),memory_order_relaxed);
    *out=s;return ZWK_COOKIES_OK;
}
int zwk_cookies_check(ZwkCookies *s) {
    int status=owner(s);if (status) return status;
    if (s->sealed || s->closed) return ZWK_COOKIES_CLOSED;
    return zwk_profile_lease_check(s->profile);
}
int zwk_cookies_bind(ZwkCookies *s,void *ctx,ZwkCookiesComplete complete) {
    int status=zwk_cookies_check(s);if (status) return status;
    if (s->owner || !ctx || !complete) return ZWK_COOKIES_INVALID;
    s->owner=ctx;s->complete=complete;return ZWK_COOKIES_OK;
}
static void input_clear(CookieOp *op) {
    if (op->kind==ZWK_COOKIE_REPLACE_ALL) {
        // GList nodes are embedded in the Op allocation, never GLib-owned.
        for (GList *at=op->input.replacement;at;at=at->next) if (at->data) soup_cookie_free(at->data);
    } else if (op->input.single) soup_cookie_free(op->input.single);
}
static void op_free(CookieOp *op) {
    ZwkCookies *s=op->store;
    g_assert(s->thread==g_thread_self());
    g_assert(s->ops[op->index]==op);
    s->ops[op->index]=NULL;--s->pending;s->bytes-=op->bytes;
    input_clear(op);
    g_object_unref(op->cancel);
    atomic_fetch_sub_explicit(&live_ops,1,memory_order_relaxed);
    atomic_fetch_sub_explicit(&live_bytes,op->bytes,memory_order_relaxed);
    free(op);store_unref(s);
}
static void result_finalized(gpointer data) { op_free(data); }
static ZwkCookieSlice slice(const char *p) {
    return (ZwkCookieSlice){(const unsigned char *)(p?p:""),p?strlen(p):0};
}
static int match(CookieOp *op,SoupCookie *cookie) {
    if ((op->filter_flags&1) && strcmp(op->name,soup_cookie_get_name(cookie))) return FALSE;
    if ((op->filter_flags&2) && strcmp(op->domain,soup_cookie_get_domain(cookie))) return FALSE;
    if ((op->filter_flags&4) && strcmp(op->path,soup_cookie_get_path(cookie))) return FALSE;
    return TRUE;
}
static void finished(GObject *object,GAsyncResult *result,gpointer data) {
    CookieOp *op=data;ZwkCookies *s=op->store;
    g_assert(s->thread==g_thread_self());
    g_assert(G_IS_TASK(result));
    GError *error=NULL;GList *list=NULL;gboolean ok=FALSE;
    switch (op->kind) {
    case ZWK_COOKIE_QUERY:list=webkit_cookie_manager_get_cookies_finish(WEBKIT_COOKIE_MANAGER(object),result,&error);ok=!error;break;
    case ZWK_COOKIE_LIST_ALL:list=webkit_cookie_manager_get_all_cookies_finish(WEBKIT_COOKIE_MANAGER(object),result,&error);ok=!error;break;
    case ZWK_COOKIE_SET:ok=webkit_cookie_manager_add_cookie_finish(WEBKIT_COOKIE_MANAGER(object),result,&error);break;
    case ZWK_COOKIE_DELETE_KEY:ok=webkit_cookie_manager_add_cookie_finish(WEBKIT_COOKIE_MANAGER(object),result,&error);break;
    case ZWK_COOKIE_DELETE:ok=webkit_cookie_manager_delete_cookie_finish(WEBKIT_COOKIE_MANAGER(object),result,&error);break;
    case ZWK_COOKIE_REPLACE_ALL:ok=webkit_cookie_manager_replace_cookies_finish(WEBKIT_COOKIE_MANAGER(object),result,&error);break;
    default:ok=webkit_website_data_manager_clear_finish(WEBKIT_WEBSITE_DATA_MANAGER(object),result,&error);break;
    }
    int status=ok?ZWK_COOKIES_OK:ZWK_COOKIES_NATIVE;
    if (error && g_error_matches(error,G_IO_ERROR,G_IO_ERROR_CANCELLED)) status=ZWK_COOKIES_CANCELLED;
    ZwkCookieRow rows[COOKIE_ROWS];size_t count=0;
    if (ok && (op->kind==ZWK_COOKIE_QUERY || op->kind==ZWK_COOKIE_LIST_ALL)) for (GList *at=list;at;at=at->next) {
        SoupCookie *cookie=at->data;if (!match(op,cookie)) continue;
        if (count==s->rows) { status=ZWK_COOKIES_CAPACITY;count=0;break; }
        GDateTime *expires=soup_cookie_get_expires(cookie);
        rows[count++]=(ZwkCookieRow){slice(soup_cookie_get_name(cookie)),slice(soup_cookie_get_value(cookie)),slice(soup_cookie_get_domain(cookie)),slice(soup_cookie_get_path(cookie)),expires?g_date_time_to_unix(expires):0,
            (soup_cookie_get_secure(cookie)?ZWK_COOKIE_SECURE:0)|(soup_cookie_get_http_only(cookie)?ZWK_COOKIE_HTTP_ONLY:0)|(expires?ZWK_COOKIE_EXPIRES:0),(uint32_t)soup_cookie_get_same_site_policy(cookie)};
    }
    /* s remains pinned by op across arbitrary owner completion/close. */
    if (s->owner) s->complete(s->owner,op->token,status,error?(uint32_t)error->domain:0,error?error->code:0,rows,count);
    if (list) g_list_free_full(list,(GDestroyNotify)soup_cookie_free);
    if (error) g_error_free(error);
    /* GTask still owns its source CookieManager after this callback returns.
     * That object's destructor borrows WebsiteDataManager. Release this native
     * owner only at result finalization, after GTask drops its source object;
     * otherwise cancelling after Zig/App close can leave a dangling manager.
     * This private qdata is never replaced/stolen and has no Zig backpointer. */
    GQuark key=g_quark_from_static_string("ziggurat-cookie-operation-result");
    g_assert(!g_object_get_qdata(G_OBJECT(result),key));
    g_object_set_qdata_full(G_OBJECT(result),key,op,result_finalized);
}
static int valid_slice(ZwkCookieSlice value) {
    return value.len<=COOKIE_INPUT && (!value.len || (value.ptr && !memchr(value.ptr,0,value.len) && g_utf8_validate((const char *)value.ptr,(gssize)value.len,NULL)));
}
static char *copy_slice(char **at,ZwkCookieSlice input) {
    char *out=*at;if (input.len) memcpy(out,input.ptr,input.len);
    out[input.len]=0;*at+=input.len+1;return out;
}
static int make_cookie(const ZwkCookieRow *row,SoupCookie **out) {
    *out=NULL;
    if (row->flags>7 || row->same_site>2) return ZWK_COOKIES_INVALID;
#ifdef ZWK_COOKIES_TESTING
    if (cookie_fail_after==0) return ZWK_COOKIES_OOM;
    if (cookie_fail_after>0) --cookie_fail_after;
#endif
    SoupCookie *cookie=soup_cookie_new((const char *)row->name.ptr,(const char *)row->value.ptr,(const char *)row->domain.ptr,(const char *)row->path.ptr,-1);
    if (!cookie) return ZWK_COOKIES_INVALID;
    soup_cookie_set_secure(cookie,(row->flags&ZWK_COOKIE_SECURE)!=0);
    soup_cookie_set_http_only(cookie,(row->flags&ZWK_COOKIE_HTTP_ONLY)!=0);
    soup_cookie_set_same_site_policy(cookie,(SoupSameSitePolicy)row->same_site);
    if (row->flags&ZWK_COOKIE_EXPIRES) {
        GDateTime *date=g_date_time_new_from_unix_utc(row->expires);
        if (!date) { soup_cookie_free(cookie);return ZWK_COOKIES_INVALID; }
        soup_cookie_set_expires(cookie,date);g_date_time_unref(date);
    }
    *out=cookie;return ZWK_COOKIES_OK;
}
static int start(CookieOp *op) {
    ZwkCookies *s=op->store;
    op->cancel=g_cancellable_new();
    int status=zwk_cookies_check(s);
    if (status) { input_clear(op);g_object_unref(op->cancel);free(op);return status; }
    // Publish physical ownership before a possibly synchronous completion.
    // No op read and no failing branch may follow the engine call.
    s->ops[op->index]=op;++s->pending;s->bytes+=op->bytes;store_ref(s);
    if (s->bytes>s->peak_bytes) s->peak_bytes=s->bytes;
    atomic_fetch_add_explicit(&live_ops,1,memory_order_relaxed);
    atomic_fetch_add_explicit(&live_bytes,op->bytes,memory_order_relaxed);
    store_ref(s);
#ifdef ZWK_COOKIES_TESTING
    if ((op->kind==ZWK_COOKIE_QUERY || op->kind==ZWK_COOKIE_LIST_ALL || op->kind==ZWK_COOKIE_REPLACE_ALL || op->kind==ZWK_COOKIE_DELETE_KEY) && synchronous_query) {
        GTask *task=g_task_new(s->cookies,op->cancel,NULL,NULL);
        if (op->kind==ZWK_COOKIE_REPLACE_ALL || op->kind==ZWK_COOKIE_DELETE_KEY) g_task_return_boolean(task,TRUE); else g_task_return_pointer(task,NULL,NULL);
        finished(G_OBJECT(s->cookies),G_ASYNC_RESULT(task),op);
        g_object_unref(task);store_unref(s);return ZWK_COOKIES_OK;
    }
#endif
    switch (op->kind) {
    case ZWK_COOKIE_QUERY:webkit_cookie_manager_get_cookies(s->cookies,op->url,op->cancel,finished,op);break;
    case ZWK_COOKIE_LIST_ALL:webkit_cookie_manager_get_all_cookies(s->cookies,op->cancel,finished,op);break;
    case ZWK_COOKIE_SET:webkit_cookie_manager_add_cookie(s->cookies,op->input.single,op->cancel,finished,op);break;
    case ZWK_COOKIE_DELETE_KEY:webkit_cookie_manager_add_cookie(s->cookies,op->input.single,op->cancel,finished,op);break;
    case ZWK_COOKIE_DELETE:webkit_cookie_manager_delete_cookie(s->cookies,op->input.single,op->cancel,finished,op);break;
    case ZWK_COOKIE_REPLACE_ALL:webkit_cookie_manager_replace_cookies(s->cookies,op->input.replacement,op->cancel,finished,op);break;
    default:webkit_website_data_manager_clear(s->manager,WEBKIT_WEBSITE_DATA_COOKIES,0,op->cancel,finished,op);break;
    }
    store_unref(s);return ZWK_COOKIES_OK;
}
int zwk_cookies_submit(ZwkCookies *s,uint64_t token,const ZwkCookieRequest *request) {
    int status=zwk_cookies_check(s);if (status) return status;
    if (!s->owner || !token || !request || request->kind>ZWK_COOKIE_DELETE_KEY || request->kind==ZWK_COOKIE_REPLACE_ALL || request->filter_flags>7 || request->same_site>2 || request->flags>7) return ZWK_COOKIES_INVALID;
    if (request->kind==ZWK_COOKIE_LIST_ALL && (request->filter_flags || request->url.len || request->name.len || request->value.len || request->domain.len || request->path.len || request->flags)) return ZWK_COOKIES_INVALID;
    if (request->kind==ZWK_COOKIE_DELETE_KEY && (request->filter_flags || request->url.len || request->value.len || request->flags || request->same_site || request->expires)) return ZWK_COOKIES_INVALID;
    if (request->kind==ZWK_COOKIE_LIST_ALL && !list_api_available()) return ZWK_COOKIES_UNSUPPORTED;
    if ((request->kind==ZWK_COOKIE_QUERY && !request->url.len) ||
        ((request->kind==ZWK_COOKIE_SET || request->kind==ZWK_COOKIE_DELETE || request->kind==ZWK_COOKIE_DELETE_KEY) &&
         (!request->name.len || !request->domain.len || !request->path.len))) return ZWK_COOKIES_INVALID;
    size_t index=0;while(index<s->capacity && s->ops[index]) ++index;
    if (index==s->capacity) return ZWK_COOKIES_FULL;
    for (size_t i=0;i<s->capacity;++i) if (s->ops[i] && s->ops[i]->token==token) return ZWK_COOKIES_INVALID;
    const ZwkCookieSlice inputs[]={request->url,request->name,request->value,request->domain,request->path};
    size_t bytes=sizeof(CookieOp);
    for (size_t i=0;i<5;++i) { if (!valid_slice(inputs[i])) return ZWK_COOKIES_INVALID;bytes+=inputs[i].len+1; }
    if (bytes-sizeof(CookieOp)>COOKIE_INPUT || bytes>s->limit-s->bytes) return ZWK_COOKIES_CAPACITY;
    CookieOp *op=cookie_malloc(bytes);if (!op) return ZWK_COOKIES_OOM;
    memset(op,0,sizeof(*op));op->store=s;op->token=token;op->kind=request->kind;op->filter_flags=request->filter_flags;op->index=(uint32_t)index;op->bytes=bytes;
    char *at=(char *)(op+1);op->url=copy_slice(&at,request->url);op->name=copy_slice(&at,request->name);op->value=copy_slice(&at,request->value);op->domain=copy_slice(&at,request->domain);op->path=copy_slice(&at,request->path);
    if (request->kind==ZWK_COOKIE_SET || request->kind==ZWK_COOKIE_DELETE || request->kind==ZWK_COOKIE_DELETE_KEY) {
        /* A single expired add matches native domain/name/path without the
         * old value. Secure+HttpOnly covers valid prefixed cookies; no URL or
         * first-party policy is introduced. Native prefix/domain policy can
         * still reject legacy-invalid identities, just as an ordinary add. */
        const int key_only=request->kind==ZWK_COOKIE_DELETE_KEY;
        const ZwkCookieRow row={slice(op->name),slice(op->value),slice(op->domain),slice(op->path),key_only?0:request->expires,key_only?(ZWK_COOKIE_SECURE|ZWK_COOKIE_HTTP_ONLY|ZWK_COOKIE_EXPIRES):request->flags,key_only?SOUP_SAME_SITE_POLICY_LAX:request->same_site};
        status=make_cookie(&row,&op->input.single);
        if (status) { free(op);return status; }
    }
    return start(op);
}
int zwk_cookies_replace(ZwkCookies *s,uint64_t token,const ZwkCookieRow *input,size_t count) {
    int status=zwk_cookies_check(s);if (status) return status;
    if (!s->owner || !token || !input || !count || count>s->rows) return ZWK_COOKIES_INVALID;
    if (!replace_api_available()) return ZWK_COOKIES_UNSUPPORTED;
    size_t index=0;while (index<s->capacity && s->ops[index]) ++index;
    if (index==s->capacity) return ZWK_COOKIES_FULL;
    for (size_t i=0;i<s->capacity;++i) if (s->ops[i] && s->ops[i]->token==token) return ZWK_COOKIES_INVALID;
    // Capture all descriptors before malloc, then copy every string before
    // constructing the first SoupCookie. No borrowed pointer reaches the SDK.
    ZwkCookieRow captured[COOKIE_ROWS];memcpy(captured,input,count*sizeof(*captured));
    size_t bytes=sizeof(CookieOp)+count*(sizeof(ZwkCookieRow)+sizeof(GList));
    for (size_t i=0;i<count;++i) {
        const ZwkCookieRow *row=&captured[i];
        if (!row->name.len || !row->domain.len || !row->path.len || row->flags>7 || row->same_site>2) return ZWK_COOKIES_INVALID;
        const ZwkCookieSlice fields[]={row->name,row->value,row->domain,row->path};
        for (size_t field=0;field<4;++field) {
            if (fields[field].len>=COOKIE_INPUT || bytes-sizeof(CookieOp)>COOKIE_INPUT-fields[field].len-1) return ZWK_COOKIES_CAPACITY;
            bytes+=fields[field].len+1;
        }
    }
    if (bytes-sizeof(CookieOp)>COOKIE_INPUT || bytes>s->limit-s->bytes) return ZWK_COOKIES_CAPACITY;
    for (size_t i=0;i<count;++i) {
        const ZwkCookieSlice fields[]={captured[i].name,captured[i].value,captured[i].domain,captured[i].path};
        for (size_t field=0;field<4;++field) if (!valid_slice(fields[field])) return ZWK_COOKIES_INVALID;
    }
    if (s->bytes+bytes>s->peak_bytes) s->peak_bytes=s->bytes+bytes;
    CookieOp *op=cookie_malloc(bytes);if (!op) return ZWK_COOKIES_OOM;
    memset(op,0,sizeof(*op));op->store=s;op->token=token;op->kind=ZWK_COOKIE_REPLACE_ALL;op->index=(uint32_t)index;op->bytes=bytes;
    ZwkCookieRow *rows=(ZwkCookieRow *)(op+1);
    GList *nodes=(GList *)(rows+count);memset(nodes,0,count*sizeof(*nodes));
    op->input.replacement=nodes;
    char *at=(char *)(nodes+count);
    for (size_t i=0;i<count;++i) {
        rows[i]=captured[i];
        rows[i].name=slice(copy_slice(&at,captured[i].name));
        rows[i].value=slice(copy_slice(&at,captured[i].value));
        rows[i].domain=slice(copy_slice(&at,captured[i].domain));
        rows[i].path=slice(copy_slice(&at,captured[i].path));
        nodes[i].prev=i?&nodes[i-1]:NULL;nodes[i].next=i+1<count?&nodes[i+1]:NULL;
    }
    for (size_t i=0;i<count;++i) {
        SoupCookie *cookie=NULL;status=make_cookie(&rows[i],&cookie);
        if (status) { input_clear(op);free(op);return status; }
        nodes[i].data=cookie;
    }
    return start(op);
}
int zwk_cookies_cancel(ZwkCookies *s,uint64_t token) {
    int status=owner(s);if (status) return status;
    store_ref(s);
    for (size_t i=0;i<s->capacity;++i) if (s->ops[i] && s->ops[i]->token==token) {
        GCancellable *cancel=g_object_ref(s->ops[i]->cancel);
        g_cancellable_cancel(cancel);g_object_unref(cancel);break;
    }
    store_unref(s);return ZWK_COOKIES_OK;
}
int zwk_cookies_seal(ZwkCookies *s) {
    int status=owner(s);if (status) return status;
    s->sealed=TRUE;s->owner=NULL;s->complete=NULL;
    return ZWK_COOKIES_OK;
}
int zwk_cookies_cancel_all(ZwkCookies *s) {
    int status=owner(s);if (status) return status;
    store_ref(s);
    for (size_t i=0;i<s->capacity;++i) if (s->ops[i]) {
        GCancellable *cancel=g_object_ref(s->ops[i]->cancel);
        g_cancellable_cancel(cancel);g_object_unref(cancel);
    }
    store_unref(s);return ZWK_COOKIES_OK;
}
int zwk_cookies_close(ZwkCookies *s) {
    int status=owner(s);if (status) return status;
    if (s->closed) return ZWK_COOKIES_CLOSED;
    zwk_cookies_seal(s);zwk_cookies_cancel_all(s);s->closed=TRUE;store_unref(s);return ZWK_COOKIES_OK;
}
int zwk_cookies_stats(ZwkCookies *s,ZwkCookiesStats *out) {
    int status=owner(s);if (status) return status;
    if (!out) return ZWK_COOKIES_INVALID;
    *out=(ZwkCookiesStats){s->bytes,s->peak_bytes,s->pending,!zwk_cookies_check(s)};
    return ZWK_COOKIES_OK;
}
void zwk_cookies_counts(uint32_t *stores,uint32_t *ops,size_t *bytes) {
    if (stores) *stores=atomic_load_explicit(&live_stores,memory_order_relaxed);
    if (ops) *ops=atomic_load_explicit(&live_ops,memory_order_relaxed);
    if (bytes) *bytes=atomic_load_explicit(&live_bytes,memory_order_relaxed);
}
