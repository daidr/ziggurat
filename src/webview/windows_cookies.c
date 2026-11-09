/* The independent CookieStore on Windows. WebView2 has a cookie manager only
   through a web view, so a store makes a hidden web view of its Profile on
   its first call, in a hidden window of its own, and serves its calls one
   after the other through that web view's manager. The view goes once no
   call has needed it for five seconds, unless it alone keeps session
   cookies, which the browser processes drop when their last web view goes,
   or once the store closes. Main thread only. */
#define COBJMACROS
#include <windows.h>
#include <WebView2.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "webkit_cookies.h"
#include "windows_profile.h"

#define COOKIE_PENDING 8u
#define COOKIE_ROWS 128u
#define COOKIE_BYTES (4u*1024u*1024u)
#define COOKIE_INPUT (32u*1024u)
#define PUMP_MESSAGE (WM_APP+0x43)
#define IDLE_TIMER 1
/* How long the hidden web view stays once no call needs it: calls coming
   one after the other use the same one, rather than each starting the
   browser processes again. */
#define IDLE_MS 5000
/* How long a change may take to show in GetCookies: WebView2 changes
   cookies after its calls return. */
#define SETTLE_MS 2000

typedef struct CookieOp CookieOp;
typedef enum { VIEW_NONE,VIEW_STARTING,VIEW_READY } ViewPhase;
typedef enum { STEP_QUEUED,STEP_LISTING,STEP_SETTLING,STEP_DONE } Step;

struct ZwkCookies {
    DWORD thread;
    ZwpwProfile *profile;
    void *owner;
    ZwkCookiesComplete complete;
    CookieOp *ops[COOKIE_PENDING];
    size_t bytes,peak_bytes,limit;
    uint32_t capacity,rows,pending;
    LONG refs;
    BOOL sealed,closed;
    HWND hwnd;
    ViewPhase phase;
    ZwpwContext *context;
    ICoreWebView2Controller *controller;
    ICoreWebView2 *view;
    ICoreWebView2CookieManager *manager;
    BOOL view_failed,pump_posted,checking,idle_close;
    HRESULT view_failure;
    /* calls counts accepted calls; checked is calls when the idle check
       began: a call since keeps the view. */
    uint64_t sequence,calls,checked;
};
struct CookieOp {
    ZwkCookies *store;
    uint64_t token,sequence;
    uint32_t kind,filter_flags,index;
    size_t bytes;
    Step step;
    BOOL cancelled,busy;
    int status;
    HRESULT failure;
    ULONGLONG deadline;
    ICoreWebView2CookieList *list;
    uint64_t *old;
    size_t old_count;
    char *url,*name,*value,*domain,*path;
    int64_t expires;
    uint32_t flags,same_site;
    ZwkCookieRow *rows;
    size_t count;
};

static volatile LONG live_stores,live_ops;
static volatile LONG64 live_bytes;
static ATOM window_class;

static int owner(ZwkCookies *s) {
    if (!s) return ZWK_COOKIES_INVALID;
    return s->thread==GetCurrentThreadId()?ZWK_COOKIES_OK:ZWK_COOKIES_WRONG_THREAD;
}
static void store_ref(ZwkCookies *s) { ++s->refs; }
static void store_unref(ZwkCookies *s) {
    if (--s->refs) return;
    /* Only native storage remains. Never revisit Zig/App/caller allocators.
       The view pins the store: none is open here. */
    if (s->hwnd) { SetWindowLongPtrW(s->hwnd,GWLP_USERDATA,0);DestroyWindow(s->hwnd); }
    zwpw_profile_lease_release(s->profile);
    InterlockedDecrement(&live_stores);
    InterlockedAdd64(&live_bytes,-(LONG64)sizeof(*s));
    free(s);
}
static void post_pump(ZwkCookies *s) {
    if (s->pump_posted||!s->hwnd) return;
    s->pump_posted=PostMessageW(s->hwnd,PUMP_MESSAGE,0,0)!=0;
}

/* UTF-8 and UTF-16. */
static int valid_slice(ZwkCookieSlice value) {
    if (value.len>COOKIE_INPUT) return FALSE;
    if (!value.len) return TRUE;
    if (!value.ptr||memchr(value.ptr,0,value.len)) return FALSE;
    return MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,(const char *)value.ptr,(int)value.len,NULL,0)>0;
}
static WCHAR *wide(const char *text) {
    int length=MultiByteToWideChar(CP_UTF8,0,text,-1,NULL,0);
    if (length<=0) return NULL;
    WCHAR *out=malloc((size_t)length*sizeof(WCHAR));
    if (out&&MultiByteToWideChar(CP_UTF8,0,text,-1,out,length)<=0) { free(out);return NULL; }
    return out;
}
static char *narrow(const WCHAR *text) {
    if (!text) text=L"";
    int length=WideCharToMultiByte(CP_UTF8,0,text,-1,NULL,0,NULL,NULL);
    if (length<=0) return NULL;
    char *out=malloc((size_t)length);
    if (out&&WideCharToMultiByte(CP_UTF8,0,text,-1,out,length,NULL,NULL)<=0) { free(out);return NULL; }
    return out;
}
static void lower(char *text) { for (;*text;++text) if (*text>='A'&&*text<='Z') *text=(char)(*text-'A'+'a'); }
static const char *undotted(const char *domain) { return *domain=='.'?domain+1:domain; }

/* A cookie as GetCookies lists it, its domain in lower case. */
typedef struct Text { char *name,*value,*domain,*path; } Text;
static void text_free(Text *t) { free(t->name);free(t->value);free(t->domain);free(t->path);*t=(Text){0}; }
static HRESULT text_of(ICoreWebView2Cookie *cookie,Text *out) {
    *out=(Text){0};
    LPWSTR fields[4]={0};
    HRESULT hr=ICoreWebView2Cookie_get_Name(cookie,&fields[0]);
    if (SUCCEEDED(hr)) hr=ICoreWebView2Cookie_get_Value(cookie,&fields[1]);
    if (SUCCEEDED(hr)) hr=ICoreWebView2Cookie_get_Domain(cookie,&fields[2]);
    if (SUCCEEDED(hr)) hr=ICoreWebView2Cookie_get_Path(cookie,&fields[3]);
    if (SUCCEEDED(hr)) {
        out->name=narrow(fields[0]);out->value=narrow(fields[1]);out->domain=narrow(fields[2]);out->path=narrow(fields[3]);
        if (!out->name||!out->value||!out->domain||!out->path) { text_free(out);hr=E_OUTOFMEMORY; }
        else lower(out->domain);
    }
    for (int i=0;i<4;++i) CoTaskMemFree(fields[i]);
    return hr;
}
/* What tells a stored cookie apart from a page's newer one. */
static uint64_t identity(const char *name,const char *domain,const char *path,const char *value) {
    uint64_t hash=1469598103934665603ull;
    const char *parts[4]={name,undotted(domain),path,value};
    for (int i=0;i<4;++i) {
        for (const unsigned char *at=(const unsigned char *)parts[i];*at;++at) {
            unsigned char c=*at;if (i==1&&c>='A'&&c<='Z') c=(unsigned char)(c-'A'+'a');
            hash=(hash^c)*1099511628211ull;
        }
        hash=(hash^0xffu)*1099511628211ull;
    }
    return hash;
}
static int same_key(const CookieOp *op,const Text *t) {
    char domain[COOKIE_INPUT/8];
    size_t length=strlen(op->domain);
    if (length>=sizeof domain) return FALSE;
    memcpy(domain,op->domain,length+1);lower(domain);
    return !strcmp(op->name,t->name)&&!strcmp(undotted(domain),undotted(t->domain))&&!strcmp(op->path,t->path);
}
static int has(const uint64_t *set,size_t count,uint64_t value) {
    for (size_t i=0;i<count;++i) if (set[i]==value) return TRUE;
    return FALSE;
}

/* The completion of GetCookies: for a call (op) or the idle check (none). */
typedef struct CookiesHandler { ICoreWebView2GetCookiesCompletedHandler iface; LONG refs; ZwkCookies *store; CookieOp *op; } CookiesHandler;
typedef struct ControllerHandler { ICoreWebView2CreateCoreWebView2ControllerCompletedHandler iface; LONG refs; ZwkCookies *store; } ControllerHandler;
static HRESULT STDMETHODCALLTYPE cookies_query(ICoreWebView2GetCookiesCompletedHandler *p,REFIID iid,void **out) {
    if (!out) return E_POINTER;*out=NULL;
    if (!IsEqualIID(iid,&IID_IUnknown)&&!IsEqualIID(iid,&IID_ICoreWebView2GetCookiesCompletedHandler)) return E_NOINTERFACE;
    *out=p;InterlockedIncrement(&((CookiesHandler *)p)->refs);return S_OK;
}
static ULONG STDMETHODCALLTYPE cookies_add(ICoreWebView2GetCookiesCompletedHandler *p) { return (ULONG)InterlockedIncrement(&((CookiesHandler *)p)->refs); }
static ULONG STDMETHODCALLTYPE cookies_release(ICoreWebView2GetCookiesCompletedHandler *p) {
    CookiesHandler *h=(CookiesHandler *)p;LONG refs=InterlockedDecrement(&h->refs);
    if (!refs) { ZwkCookies *s=h->store;free(h);store_unref(s); }
    return (ULONG)refs;
}
static HRESULT STDMETHODCALLTYPE cookies_invoke(ICoreWebView2GetCookiesCompletedHandler *,HRESULT,ICoreWebView2CookieList *);
static ICoreWebView2GetCookiesCompletedHandlerVtbl cookies_vtable={cookies_query,cookies_add,cookies_release,cookies_invoke};
static HRESULT STDMETHODCALLTYPE controller_query(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *p,REFIID iid,void **out) {
    if (!out) return E_POINTER;*out=NULL;
    if (!IsEqualIID(iid,&IID_IUnknown)&&!IsEqualIID(iid,&IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler)) return E_NOINTERFACE;
    *out=p;InterlockedIncrement(&((ControllerHandler *)p)->refs);return S_OK;
}
static ULONG STDMETHODCALLTYPE controller_add(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *p) { return (ULONG)InterlockedIncrement(&((ControllerHandler *)p)->refs); }
static ULONG STDMETHODCALLTYPE controller_release(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *p) {
    ControllerHandler *h=(ControllerHandler *)p;LONG refs=InterlockedDecrement(&h->refs);
    if (!refs) { ZwkCookies *s=h->store;free(h);store_unref(s); }
    return (ULONG)refs;
}
static HRESULT STDMETHODCALLTYPE controller_invoke(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *,HRESULT,ICoreWebView2Controller *);
static ICoreWebView2CreateCoreWebView2ControllerCompletedHandlerVtbl controller_vtable={controller_query,controller_add,controller_release,controller_invoke};

static HRESULT get_cookies(ZwkCookies *s,CookieOp *op,const WCHAR *uri) {
    CookiesHandler *h=calloc(1,sizeof(*h));
    if (!h) return E_OUTOFMEMORY;
    h->iface.lpVtbl=&cookies_vtable;h->refs=1;h->store=s;h->op=op;store_ref(s);
    if (op) op->busy=TRUE;
    HRESULT hr=ICoreWebView2CookieManager_GetCookies(s->manager,uri,&h->iface);
    if (FAILED(hr)&&op) op->busy=FALSE;
    cookies_release(&h->iface);
    return hr;
}

/* The hidden web view. */
static void view_fail(ZwkCookies *s,HRESULT hr) {
    if (s->phase==VIEW_NONE&&!s->context) return;
    s->view_failed=TRUE;s->view_failure=FAILED(hr)?hr:E_FAIL;
    post_pump(s);
}
static void drop_view(ZwkCookies *s) {
    if (s->hwnd) KillTimer(s->hwnd,IDLE_TIMER);
    ICoreWebView2CookieManager *manager=s->manager;ICoreWebView2 *view=s->view;ICoreWebView2Controller *controller=s->controller;ZwpwContext *context=s->context;
    BOOL pinned=s->phase!=VIEW_NONE;
    s->manager=NULL;s->view=NULL;s->controller=NULL;s->context=NULL;s->phase=VIEW_NONE;s->checking=FALSE;s->idle_close=FALSE;
    if (manager) ICoreWebView2CookieManager_Release(manager);
    if (view) ICoreWebView2_Release(view);
    if (controller) { ICoreWebView2Controller_Close(controller);ICoreWebView2Controller_Release(controller); }
    if (context) { zwpw_context_detach(context);zwpw_profile_context_close(context); }
    if (pinned) store_unref(s);
}
static void start_release(void *context) { store_unref(context); }
static void start_revoke(void *context,HRESULT reason) { view_fail(context,reason); }
static void start_environment(void *context,HRESULT hr,ICoreWebView2Environment *environment) {
    ZwkCookies *s=context;
    if (s->phase!=VIEW_STARTING||s->closed) return;
    if (FAILED(hr)||!environment) { view_fail(s,hr);return; }
    ControllerHandler *h=calloc(1,sizeof(*h));
    if (!h) { view_fail(s,E_OUTOFMEMORY);return; }
    h->iface.lpVtbl=&controller_vtable;h->refs=1;h->store=s;store_ref(s);
    hr=ICoreWebView2Environment_CreateCoreWebView2Controller(environment,s->hwnd,&h->iface);
    controller_release(&h->iface);
    if (FAILED(hr)) view_fail(s,hr);
}
static HRESULT STDMETHODCALLTYPE controller_invoke(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *p,HRESULT hr,ICoreWebView2Controller *controller) {
    ZwkCookies *s=((ControllerHandler *)p)->store;store_ref(s);
    if (s->phase!=VIEW_STARTING||s->view_failed||s->closed||!s->context) {
        if (controller) ICoreWebView2Controller_Close(controller);
        store_unref(s);return S_OK;
    }
    if (FAILED(hr)||!controller) { view_fail(s,hr);store_unref(s);return S_OK; }
    ICoreWebView2Controller_AddRef(controller);s->controller=controller;
    ICoreWebView2Controller_put_IsVisible(controller,FALSE);
    ICoreWebView2 *view=NULL;ICoreWebView2_2 *view2=NULL;ICoreWebView2CookieManager *manager=NULL;
    UINT32 pid=0;HANDLE process=NULL;
    hr=ICoreWebView2Controller_get_CoreWebView2(controller,&view);
    if (SUCCEEDED(hr)&&!view) hr=E_POINTER;
    if (SUCCEEDED(hr)) { s->view=view;hr=ICoreWebView2_get_BrowserProcessId(view,&pid); }
    if (SUCCEEDED(hr)&&!pid) hr=E_ABORT;
    if (SUCCEEDED(hr)) { process=OpenProcess(SYNCHRONIZE,FALSE,pid);if (!process) hr=HRESULT_FROM_WIN32(GetLastError()); }
    if (SUCCEEDED(hr)) {
        /* The Profile keeps its directory until the browser exits. */
        int result=zwpw_context_publish_process(s->context,&process);
        if (result!=ZWPW_PROFILE_OK) hr=result==ZWPW_PROFILE_FULL?HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA):E_ABORT;
    }
    if (process) CloseHandle(process);
    if (SUCCEEDED(hr)&&zwpw_context_activate(s->context)!=ZWPW_PROFILE_OK) hr=E_ABORT;
    if (SUCCEEDED(hr)) hr=ICoreWebView2_QueryInterface(view,&IID_ICoreWebView2_2,(void **)&view2);
    if (SUCCEEDED(hr)&&!view2) hr=E_NOINTERFACE;
    if (SUCCEEDED(hr)) hr=ICoreWebView2_2_get_CookieManager(view2,&manager);
    if (SUCCEEDED(hr)&&!manager) hr=E_POINTER;
    if (view2) ICoreWebView2_2_Release(view2);
    if (SUCCEEDED(hr)&&s->phase==VIEW_STARTING&&!s->view_failed) { s->manager=manager;s->phase=VIEW_READY;post_pump(s); }
    else { if (manager) ICoreWebView2CookieManager_Release(manager);view_fail(s,FAILED(hr)?hr:E_ABORT); }
    store_unref(s);return S_OK;
}
typedef HRESULT (STDAPICALLTYPE *CreateEnvironment)(PCWSTR,PCWSTR,ICoreWebView2EnvironmentOptions *,ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *);
static CreateEnvironment environment_creator(HRESULT *hr) {
    HMODULE loader=GetModuleHandleW(L"WebView2Loader.dll");
    if (!loader) {
        WCHAR *path=calloc(32768,sizeof(WCHAR));
        if (!path) { *hr=E_OUTOFMEMORY;return NULL; }
        DWORD length=GetModuleFileNameW(NULL,path,32768);
        WCHAR *slash=wcsrchr(path,L'\\');
        if (!length||length>=32768||!slash||(slash-path)+20>=32768) { free(path);*hr=E_FAIL;return NULL; }
        wcscpy(slash+1,L"WebView2Loader.dll");
        loader=LoadLibraryExW(path,NULL,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_SYSTEM32);
        DWORD error=GetLastError();free(path);
        if (!loader) { *hr=HRESULT_FROM_WIN32(error);return NULL; }
    }
    CreateEnvironment create=(CreateEnvironment)(void *)GetProcAddress(loader,"CreateCoreWebView2EnvironmentWithOptions");
    *hr=create?S_OK:HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
    return create;
}
static void start_view(ZwkCookies *s) {
    if (s->phase!=VIEW_NONE||s->view_failed) return;
    HRESULT hr=S_OK;
    CreateEnvironment create=environment_creator(&hr);
    if (!create) { s->view_failed=TRUE;s->view_failure=hr;return; }
    ZwpwContext *context=NULL;
    int result=zwpw_profile_context_create(s->profile,&context);
    if (result==ZWPW_PROFILE_OK) {
        result=zwpw_profile_context_admit(context);
        if (result!=ZWPW_PROFILE_OK) { zwpw_profile_context_close(context);context=NULL; }
    }
    if (result!=ZWPW_PROFILE_OK) { s->view_failed=TRUE;s->view_failure=result==ZWPW_PROFILE_FULL?HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA):E_ABORT;return; }
    /* The view pins the store until drop_view, from the message loop. */
    s->context=context;s->phase=VIEW_STARTING;store_ref(s);
    ZwpwContextStart start={s,start_environment,start_revoke,start_release};
    store_ref(s);
    result=zwpw_context_begin(context,create,&start);
    if (result!=ZWPW_PROFILE_OK) {
        store_unref(s);
        s->view_failed=TRUE;s->view_failure=result==ZWPW_PROFILE_FULL?HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA):E_ABORT;
    }
}

/* Calls. */
static void op_free(CookieOp *op) {
    ZwkCookies *s=op->store;
    s->ops[op->index]=NULL;--s->pending;s->bytes-=op->bytes;
    if (op->list) ICoreWebView2CookieList_Release(op->list);
    free(op->old);
    InterlockedDecrement(&live_ops);
    InterlockedAdd64(&live_bytes,-(LONG64)op->bytes);
    free(op);store_unref(s);
}
static int match(const CookieOp *op,const Text *t) {
    if ((op->filter_flags&1)&&strcmp(op->name,t->name)) return FALSE;
    if ((op->filter_flags&2)&&strcmp(op->domain,t->domain)) return FALSE;
    if ((op->filter_flags&4)&&strcmp(op->path,t->path)) return FALSE;
    return TRUE;
}
/* Completes op, at most once, and frees it. */
static void finish(CookieOp *op) {
    ZwkCookies *s=op->store;
    int status=op->cancelled?ZWK_COOKIES_CANCELLED:op->status;
    ZwkCookieRow rows[COOKIE_ROWS];Text texts[COOKIE_ROWS];size_t count=0;
    if (!status&&op->list&&(op->kind==ZWK_COOKIE_QUERY||op->kind==ZWK_COOKIE_LIST_ALL)) {
        UINT total=0;HRESULT hr=ICoreWebView2CookieList_get_Count(op->list,&total);
        for (UINT i=0;SUCCEEDED(hr)&&i<total;++i) {
            ICoreWebView2Cookie *cookie=NULL;Text t={0};
            hr=ICoreWebView2CookieList_GetValueAtIndex(op->list,i,&cookie);
            if (SUCCEEDED(hr)&&!cookie) hr=E_POINTER;
            if (SUCCEEDED(hr)) hr=text_of(cookie,&t);
            if (SUCCEEDED(hr)&&!match(op,&t)) { text_free(&t);ICoreWebView2Cookie_Release(cookie);continue; }
            BOOL secure=FALSE,http_only=FALSE,session=TRUE;COREWEBVIEW2_COOKIE_SAME_SITE_KIND same_site=COREWEBVIEW2_COOKIE_SAME_SITE_KIND_LAX;double expires=-1;
            if (SUCCEEDED(hr)) hr=ICoreWebView2Cookie_get_IsSecure(cookie,&secure);
            if (SUCCEEDED(hr)) hr=ICoreWebView2Cookie_get_IsHttpOnly(cookie,&http_only);
            if (SUCCEEDED(hr)) hr=ICoreWebView2Cookie_get_IsSession(cookie,&session);
            if (SUCCEEDED(hr)) hr=ICoreWebView2Cookie_get_SameSite(cookie,&same_site);
            if (SUCCEEDED(hr)&&!session) {
                hr=ICoreWebView2Cookie_get_Expires(cookie,&expires);
                if (SUCCEEDED(hr)&&(isnan(expires)||isinf(expires)||expires<0||expires>253402300799.0)) hr=E_UNEXPECTED;
            }
            if (cookie) ICoreWebView2Cookie_Release(cookie);
            if (FAILED(hr)) { text_free(&t);break; }
            if (count==s->rows) { text_free(&t);status=ZWK_COOKIES_CAPACITY;break; }
            texts[count]=t;
            rows[count]=(ZwkCookieRow){{(const unsigned char *)t.name,strlen(t.name)},{(const unsigned char *)t.value,strlen(t.value)},{(const unsigned char *)t.domain,strlen(t.domain)},{(const unsigned char *)t.path,strlen(t.path)},
                session?0:(int64_t)expires,(secure?ZWK_COOKIE_SECURE:0)|(http_only?ZWK_COOKIE_HTTP_ONLY:0)|(session?0:ZWK_COOKIE_EXPIRES),(uint32_t)same_site>2?1u:(uint32_t)same_site};
            ++count;
        }
        if (FAILED(hr)) { status=ZWK_COOKIES_NATIVE;op->failure=hr; }
        if (status) { for (size_t i=0;i<count;++i) text_free(&texts[i]);count=0; }
    }
    /* s stays pinned by op across the owner's completion and close. */
    if (s->owner) s->complete(s->owner,op->token,status,status==ZWK_COOKIES_NATIVE?7u:0u,status==ZWK_COOKIES_NATIVE?(int32_t)op->failure:0,count?rows:NULL,count);
    for (size_t i=0;i<count;++i) text_free(&texts[i]);
    op_free(op);
}
static void done(CookieOp *op,int status,HRESULT failure) {
    op->step=STEP_DONE;op->status=status;op->failure=failure;
}
static HRESULT make_cookie(ZwkCookies *s,const char *name,const char *value,const char *domain,const char *path,int64_t expires,uint32_t flags,uint32_t same_site,ICoreWebView2Cookie **out) {
    *out=NULL;
    WCHAR *n=wide(name),*v=wide(value),*d=wide(domain),*p=wide(path);
    HRESULT hr=n&&v&&d&&p?ICoreWebView2CookieManager_CreateCookie(s->manager,n,v,d,p,out):E_OUTOFMEMORY;
    free(n);free(v);free(d);free(p);
    if (SUCCEEDED(hr)&&!*out) hr=E_POINTER;
    if (SUCCEEDED(hr)) hr=ICoreWebView2Cookie_put_Expires(*out,flags&ZWK_COOKIE_EXPIRES?(double)expires:-1.0);
    if (SUCCEEDED(hr)) hr=ICoreWebView2Cookie_put_IsSecure(*out,(flags&ZWK_COOKIE_SECURE)!=0);
    if (SUCCEEDED(hr)) hr=ICoreWebView2Cookie_put_IsHttpOnly(*out,(flags&ZWK_COOKIE_HTTP_ONLY)!=0);
    if (SUCCEEDED(hr)) hr=ICoreWebView2Cookie_put_SameSite(*out,(COREWEBVIEW2_COOKIE_SAME_SITE_KIND)same_site);
    if (FAILED(hr)&&*out) { ICoreWebView2Cookie_Release(*out);*out=NULL; }
    return hr;
}
static HRESULT add(ZwkCookies *s,const char *name,const char *value,const char *domain,const char *path,int64_t expires,uint32_t flags,uint32_t same_site) {
    ICoreWebView2Cookie *cookie=NULL;
    HRESULT hr=make_cookie(s,name,value,domain,path,expires,flags,same_site,&cookie);
    if (SUCCEEDED(hr)) { hr=ICoreWebView2CookieManager_AddOrUpdateCookie(s->manager,cookie);ICoreWebView2Cookie_Release(cookie); }
    return hr;
}
static void settle(CookieOp *op) {
    op->step=STEP_SETTLING;op->deadline=GetTickCount64()+SETTLE_MS;
    HRESULT hr=get_cookies(op->store,op,L"");
    if (FAILED(hr)) done(op,ZWK_COOKIES_NATIVE,hr);
}
static void run(CookieOp *op) {
    ZwkCookies *s=op->store;HRESULT hr=S_OK;
    switch (op->kind) {
    case ZWK_COOKIE_QUERY: {
        WCHAR *url=wide(op->url);
        op->step=STEP_LISTING;hr=url?get_cookies(s,op,url):E_OUTOFMEMORY;free(url);break;
    }
    case ZWK_COOKIE_LIST_ALL:case ZWK_COOKIE_DELETE:case ZWK_COOKIE_DELETE_KEY:case ZWK_COOKIE_CLEAR:
        /* Every cookie, HttpOnly ones included; the deletions first find
           those there are now, which must go. */
        op->step=STEP_LISTING;hr=get_cookies(s,op,L"");break;
    case ZWK_COOKIE_SET:
        hr=add(s,op->name,op->value,op->domain,op->path,op->expires,op->flags,op->same_site);
        if (SUCCEEDED(hr)) { settle(op);return; }
        break;
    case ZWK_COOKIE_REPLACE_ALL:
        hr=ICoreWebView2CookieManager_DeleteAllCookies(s->manager);
        for (size_t i=0;SUCCEEDED(hr)&&i<op->count;++i) {
            const ZwkCookieRow *row=&op->rows[i];
            hr=add(s,(const char *)row->name.ptr,(const char *)row->value.ptr,(const char *)row->domain.ptr,(const char *)row->path.ptr,row->expires,row->flags,row->same_site);
        }
        if (SUCCEEDED(hr)) { settle(op);return; }
        break;
    default:hr=E_INVALIDARG;break;
    }
    if (FAILED(hr)) done(op,ZWK_COOKIES_NATIVE,hr);
}
/* After the listing of every cookie, a deletion deletes those it names. */
static HRESULT delete_listed(CookieOp *op,ICoreWebView2CookieList *list) {
    ZwkCookies *s=op->store;
    UINT total=0;HRESULT hr=ICoreWebView2CookieList_get_Count(list,&total);
    if (FAILED(hr)) return hr;
    if (total) { op->old=calloc(total,sizeof(*op->old));if (!op->old) return E_OUTOFMEMORY; }
    for (UINT i=0;SUCCEEDED(hr)&&i<total;++i) {
        ICoreWebView2Cookie *cookie=NULL;Text t={0};
        hr=ICoreWebView2CookieList_GetValueAtIndex(list,i,&cookie);
        if (SUCCEEDED(hr)&&!cookie) hr=E_POINTER;
        if (SUCCEEDED(hr)) hr=text_of(cookie,&t);
        if (SUCCEEDED(hr)) {
            BOOL named=op->kind==ZWK_COOKIE_CLEAR||(same_key(op,&t)&&(op->kind==ZWK_COOKIE_DELETE_KEY||!strcmp(op->value,t.value)));
            if (named) {
                op->old[op->old_count++]=identity(t.name,t.domain,t.path,t.value);
                if (op->kind==ZWK_COOKIE_DELETE) hr=ICoreWebView2CookieManager_DeleteCookie(s->manager,cookie);
            }
            text_free(&t);
        }
        if (cookie) ICoreWebView2Cookie_Release(cookie);
    }
    if (FAILED(hr)||!op->old_count) return hr;
    if (op->kind==ZWK_COOKIE_DELETE_KEY) {
        WCHAR *n=wide(op->name),*d=wide(op->domain),*p=wide(op->path);
        hr=n&&d&&p?ICoreWebView2CookieManager_DeleteCookiesWithDomainAndPath(s->manager,n,d,p):E_OUTOFMEMORY;
        free(n);free(d);free(p);
    } else if (op->kind==ZWK_COOKIE_CLEAR) hr=ICoreWebView2CookieManager_DeleteAllCookies(s->manager);
    return hr;
}
/* Whether the change of op shows in the listing. */
static HRESULT settled(CookieOp *op,ICoreWebView2CookieList *list,BOOL *out) {
    UINT total=0;HRESULT hr=ICoreWebView2CookieList_get_Count(list,&total);
    size_t wanted=op->kind==ZWK_COOKIE_SET?1:op->kind==ZWK_COOKIE_REPLACE_ALL?op->count:0;
    size_t found=0;BOOL left=FALSE;
    for (UINT i=0;SUCCEEDED(hr)&&i<total;++i) {
        ICoreWebView2Cookie *cookie=NULL;Text t={0};
        hr=ICoreWebView2CookieList_GetValueAtIndex(list,i,&cookie);
        if (SUCCEEDED(hr)&&!cookie) hr=E_POINTER;
        if (SUCCEEDED(hr)) hr=text_of(cookie,&t);
        if (SUCCEEDED(hr)) {
            uint64_t id=identity(t.name,t.domain,t.path,t.value);
            if (op->kind==ZWK_COOKIE_SET) { if (id==identity(op->name,op->domain,op->path,op->value)) ++found; }
            else if (op->kind==ZWK_COOKIE_REPLACE_ALL) {
                for (size_t r=0;r<op->count;++r) if (id==identity((const char *)op->rows[r].name.ptr,(const char *)op->rows[r].domain.ptr,(const char *)op->rows[r].path.ptr,(const char *)op->rows[r].value.ptr)) { ++found;break; }
            } else if (has(op->old,op->old_count,id)) left=TRUE;
            text_free(&t);
        }
        if (cookie) ICoreWebView2Cookie_Release(cookie);
    }
    *out=wanted?found>=wanted:!left;
    return hr;
}
static HRESULT STDMETHODCALLTYPE cookies_invoke(ICoreWebView2GetCookiesCompletedHandler *p,HRESULT hr,ICoreWebView2CookieList *list) {
    CookiesHandler *h=(CookiesHandler *)p;ZwkCookies *s=h->store;CookieOp *op=h->op;
    store_ref(s);
    if (SUCCEEDED(hr)&&!list) hr=E_POINTER;
    if (!op) {
        /* The idle check: close the view unless a call came since, or it
           alone keeps cookies the browser drops with its processes. */
        BOOL lossless=SUCCEEDED(hr);
        UINT total=0;
        if (lossless&&FAILED(ICoreWebView2CookieList_get_Count(list,&total))) lossless=FALSE;
        for (UINT i=0;lossless&&i<total;++i) {
            ICoreWebView2Cookie *cookie=NULL;BOOL session=TRUE;
            if (FAILED(ICoreWebView2CookieList_GetValueAtIndex(list,i,&cookie))||!cookie||FAILED(ICoreWebView2Cookie_get_IsSession(cookie,&session))||session) lossless=FALSE;
            if (cookie) ICoreWebView2Cookie_Release(cookie);
        }
        s->checking=FALSE;
        if (lossless&&s->checked==s->calls&&!s->pending&&s->phase==VIEW_READY) { s->idle_close=TRUE;post_pump(s); }
        store_unref(s);return S_OK;
    }
    op->busy=FALSE;
    if (op->cancelled) done(op,ZWK_COOKIES_CANCELLED,S_OK);
    else if (FAILED(hr)) done(op,ZWK_COOKIES_NATIVE,hr);
    else if (op->step==STEP_LISTING&&(op->kind==ZWK_COOKIE_QUERY||op->kind==ZWK_COOKIE_LIST_ALL)) {
        ICoreWebView2CookieList_AddRef(list);op->list=list;done(op,ZWK_COOKIES_OK,S_OK);
    } else if (op->step==STEP_LISTING) {
        hr=delete_listed(op,list);
        if (FAILED(hr)) done(op,ZWK_COOKIES_NATIVE,hr);
        else if (!op->old_count) done(op,ZWK_COOKIES_OK,S_OK);
        else settle(op);
    } else if (op->step==STEP_SETTLING) {
        BOOL ok=FALSE;hr=settled(op,list,&ok);
        if (FAILED(hr)) done(op,ZWK_COOKIES_NATIVE,hr);
        else if (ok) done(op,ZWK_COOKIES_OK,S_OK);
        else if (GetTickCount64()<op->deadline) {
            hr=get_cookies(s,op,L"");
            if (FAILED(hr)) done(op,ZWK_COOKIES_NATIVE,hr);
        } else done(op,ZWK_COOKIES_NATIVE,E_FAIL);
    }
    post_pump(s);
    store_unref(s);return S_OK;
}
static CookieOp *next_op(ZwkCookies *s) {
    CookieOp *next=NULL;
    for (uint32_t i=0;i<s->capacity;++i) if (s->ops[i]&&(!next||s->ops[i]->sequence<next->sequence)) next=s->ops[i];
    return next;
}
/* Serves the calls in order, from the message loop: closing the view from
   inside a completion of it crashes the loop. */
static void pump(ZwkCookies *s) {
    s->pump_posted=FALSE;
    store_ref(s);
    if (s->view_failed&&s->phase!=VIEW_NONE) drop_view(s);
    for (;;) {
        CookieOp *op=next_op(s);
        if (!op||op->busy) break;
        if (op->step==STEP_DONE||op->cancelled) { finish(op);continue; }
        if (!s->view_failed&&zwpw_profile_lease_check(s->profile)!=ZWPW_PROFILE_OK) { done(op,ZWK_COOKIES_CLOSED,S_OK);continue; }
        if (s->view_failed) { done(op,ZWK_COOKIES_NATIVE,s->view_failure);continue; }
        if (s->phase==VIEW_NONE) start_view(s);
        if (s->view_failed) { if (s->phase!=VIEW_NONE) drop_view(s);continue; }
        if (s->phase!=VIEW_READY) break;
        KillTimer(s->hwnd,IDLE_TIMER);s->idle_close=FALSE;
        run(op);
    }
    if (!s->pending) {
        /* A later call tries again. */
        s->view_failed=FALSE;
        if (s->phase!=VIEW_NONE&&(s->closed||s->idle_close)) drop_view(s);
        else if (s->phase==VIEW_READY&&!s->checking) SetTimer(s->hwnd,IDLE_TIMER,IDLE_MS,NULL);
    }
    store_unref(s);
}
static void idle(ZwkCookies *s) {
    KillTimer(s->hwnd,IDLE_TIMER);
    if (s->pending||s->phase!=VIEW_READY||s->checking||s->closed) return;
    store_ref(s);
    s->checking=TRUE;s->checked=s->calls;
    if (FAILED(get_cookies(s,NULL,L""))) s->checking=FALSE;
    store_unref(s);
}
static LRESULT CALLBACK cookie_window(HWND hwnd,UINT message,WPARAM wp,LPARAM lp) {
    ZwkCookies *s=(ZwkCookies *)GetWindowLongPtrW(hwnd,GWLP_USERDATA);
    if (s&&message==PUMP_MESSAGE) { pump(s);return 0; }
    if (s&&message==WM_TIMER&&wp==IDLE_TIMER) { idle(s);return 0; }
    return DefWindowProcW(hwnd,message,wp,lp);
}

size_t zwk_cookies_owner_size(void) { return sizeof(ZwkCookies); }
int zwk_cookies_create(ZwkProfile *profile,const ZwkCookiesOptions *options,ZwkCookies **out) {
    if (!out) return ZWK_COOKIES_INVALID;
    *out=NULL;
    if (!options||!options->pending||options->pending>COOKIE_PENDING||!options->rows||options->rows>COOKIE_ROWS||options->bytes<sizeof(ZwkCookies)||options->bytes>COOKIE_BYTES) return ZWK_COOKIES_INVALID;
    ZwpwProfile *p=(ZwpwProfile *)profile;
    int status=zwpw_profile_lease_retain(p);
    if (status) return status;
    HINSTANCE instance=GetModuleHandleW(NULL);
    if (!window_class) {
        WNDCLASSEXW wc={sizeof(wc)};wc.lpfnWndProc=cookie_window;wc.hInstance=instance;wc.lpszClassName=L"ZigguratCookieView";
        window_class=RegisterClassExW(&wc);
        if (!window_class&&GetLastError()!=ERROR_CLASS_ALREADY_EXISTS) { zwpw_profile_lease_release(p);return ZWK_COOKIES_NATIVE; }
        if (!window_class) window_class=1;
    }
    ZwkCookies *s=calloc(1,sizeof(*s));
    if (!s) { zwpw_profile_lease_release(p);return ZWK_COOKIES_OOM; }
    /* A hidden tool window that never shows hosts the hidden web view. */
    s->hwnd=CreateWindowExW(WS_EX_TOOLWINDOW,L"ZigguratCookieView",L"",WS_POPUP,0,0,1,1,NULL,NULL,instance,NULL);
    if (!s->hwnd) { free(s);zwpw_profile_lease_release(p);return ZWK_COOKIES_NATIVE; }
    SetWindowLongPtrW(s->hwnd,GWLP_USERDATA,(LONG_PTR)s);
    s->thread=GetCurrentThreadId();s->refs=1;s->profile=p;
    s->bytes=s->peak_bytes=sizeof(*s);s->limit=options->bytes;
    s->capacity=options->pending;s->rows=options->rows;
    InterlockedIncrement(&live_stores);
    InterlockedAdd64(&live_bytes,sizeof(*s));
    *out=s;return ZWK_COOKIES_OK;
}
int zwk_cookies_check(ZwkCookies *s) {
    int status=owner(s);if (status) return status;
    if (s->sealed||s->closed) return ZWK_COOKIES_CLOSED;
    return zwpw_profile_lease_check(s->profile);
}
int zwk_cookies_bind(ZwkCookies *s,void *ctx,ZwkCookiesComplete complete) {
    int status=zwk_cookies_check(s);if (status) return status;
    if (s->owner||!ctx||!complete) return ZWK_COOKIES_INVALID;
    s->owner=ctx;s->complete=complete;return ZWK_COOKIES_OK;
}
static char *copy_slice(char **at,ZwkCookieSlice input) {
    char *out=*at;if (input.len) memcpy(out,input.ptr,input.len);
    out[input.len]=0;*at+=input.len+1;return out;
}
static int slot(ZwkCookies *s,uint64_t token,size_t *out) {
    size_t index=0;while (index<s->capacity&&s->ops[index]) ++index;
    if (index==s->capacity) return ZWK_COOKIES_FULL;
    for (size_t i=0;i<s->capacity;++i) if (s->ops[i]&&s->ops[i]->token==token) return ZWK_COOKIES_INVALID;
    *out=index;return ZWK_COOKIES_OK;
}
/* Publishes op; it completes later, from the message loop. */
static int start(CookieOp *op) {
    ZwkCookies *s=op->store;
    s->ops[op->index]=op;++s->pending;s->bytes+=op->bytes;store_ref(s);
    if (s->bytes>s->peak_bytes) s->peak_bytes=s->bytes;
    op->sequence=++s->sequence;++s->calls;
    InterlockedIncrement(&live_ops);
    InterlockedAdd64(&live_bytes,(LONG64)op->bytes);
    post_pump(s);
    return ZWK_COOKIES_OK;
}
int zwk_cookies_submit(ZwkCookies *s,uint64_t token,const ZwkCookieRequest *request) {
    int status=zwk_cookies_check(s);if (status) return status;
    if (!s->owner||!token||!request||request->kind>ZWK_COOKIE_DELETE_KEY||request->kind==ZWK_COOKIE_REPLACE_ALL||request->filter_flags>7||request->same_site>2||request->flags>7) return ZWK_COOKIES_INVALID;
    if (request->kind==ZWK_COOKIE_LIST_ALL&&(request->filter_flags||request->url.len||request->name.len||request->value.len||request->domain.len||request->path.len||request->flags)) return ZWK_COOKIES_INVALID;
    if (request->kind==ZWK_COOKIE_DELETE_KEY&&(request->filter_flags||request->url.len||request->value.len||request->flags||request->same_site||request->expires)) return ZWK_COOKIES_INVALID;
    if ((request->kind==ZWK_COOKIE_QUERY&&!request->url.len)||
        ((request->kind==ZWK_COOKIE_SET||request->kind==ZWK_COOKIE_DELETE||request->kind==ZWK_COOKIE_DELETE_KEY)&&
         (!request->name.len||!request->domain.len||!request->path.len))) return ZWK_COOKIES_INVALID;
    size_t index=0;status=slot(s,token,&index);if (status) return status;
    const ZwkCookieSlice inputs[]={request->url,request->name,request->value,request->domain,request->path};
    size_t bytes=sizeof(CookieOp);
    for (size_t i=0;i<5;++i) { if (!valid_slice(inputs[i])) return ZWK_COOKIES_INVALID;bytes+=inputs[i].len+1; }
    if (bytes-sizeof(CookieOp)>COOKIE_INPUT||bytes>s->limit-s->bytes) return ZWK_COOKIES_CAPACITY;
    CookieOp *op=calloc(1,bytes);if (!op) return ZWK_COOKIES_OOM;
    op->store=s;op->token=token;op->kind=request->kind;op->filter_flags=request->filter_flags;op->index=(uint32_t)index;op->bytes=bytes;
    op->expires=request->expires;op->flags=request->flags;op->same_site=request->same_site;
    char *at=(char *)(op+1);op->url=copy_slice(&at,request->url);op->name=copy_slice(&at,request->name);op->value=copy_slice(&at,request->value);op->domain=copy_slice(&at,request->domain);op->path=copy_slice(&at,request->path);
    return start(op);
}
int zwk_cookies_replace(ZwkCookies *s,uint64_t token,const ZwkCookieRow *input,size_t count) {
    int status=zwk_cookies_check(s);if (status) return status;
    if (!s->owner||!token||!input||!count||count>s->rows) return ZWK_COOKIES_INVALID;
    size_t index=0;status=slot(s,token,&index);if (status) return status;
    ZwkCookieRow captured[COOKIE_ROWS];memcpy(captured,input,count*sizeof(*captured));
    size_t bytes=sizeof(CookieOp)+count*sizeof(ZwkCookieRow);
    for (size_t i=0;i<count;++i) {
        const ZwkCookieRow *row=&captured[i];
        if (!row->name.len||!row->domain.len||!row->path.len||row->flags>7||row->same_site>2) return ZWK_COOKIES_INVALID;
        const ZwkCookieSlice fields[]={row->name,row->value,row->domain,row->path};
        for (size_t field=0;field<4;++field) {
            if (fields[field].len>=COOKIE_INPUT||bytes-sizeof(CookieOp)>COOKIE_INPUT-fields[field].len-1) return ZWK_COOKIES_CAPACITY;
            bytes+=fields[field].len+1;
        }
    }
    if (bytes-sizeof(CookieOp)>COOKIE_INPUT||bytes>s->limit-s->bytes) return ZWK_COOKIES_CAPACITY;
    for (size_t i=0;i<count;++i) {
        const ZwkCookieSlice fields[]={captured[i].name,captured[i].value,captured[i].domain,captured[i].path};
        for (size_t field=0;field<4;++field) if (!valid_slice(fields[field])) return ZWK_COOKIES_INVALID;
    }
    CookieOp *op=calloc(1,bytes);if (!op) return ZWK_COOKIES_OOM;
    op->store=s;op->token=token;op->kind=ZWK_COOKIE_REPLACE_ALL;op->index=(uint32_t)index;op->bytes=bytes;
    op->name=op->value=op->domain=op->path=op->url="";
    ZwkCookieRow *rows=(ZwkCookieRow *)(op+1);
    char *at=(char *)(rows+count);
    for (size_t i=0;i<count;++i) {
        rows[i]=captured[i];
        rows[i].name.ptr=(const unsigned char *)copy_slice(&at,captured[i].name);
        rows[i].value.ptr=(const unsigned char *)copy_slice(&at,captured[i].value);
        rows[i].domain.ptr=(const unsigned char *)copy_slice(&at,captured[i].domain);
        rows[i].path.ptr=(const unsigned char *)copy_slice(&at,captured[i].path);
    }
    op->rows=rows;op->count=count;
    return start(op);
}
int zwk_cookies_cancel(ZwkCookies *s,uint64_t token) {
    int status=owner(s);if (status) return status;
    for (size_t i=0;i<s->capacity;++i) if (s->ops[i]&&s->ops[i]->token==token) { s->ops[i]->cancelled=TRUE;post_pump(s);break; }
    return ZWK_COOKIES_OK;
}
int zwk_cookies_seal(ZwkCookies *s) {
    int status=owner(s);if (status) return status;
    s->sealed=TRUE;s->owner=NULL;s->complete=NULL;
    return ZWK_COOKIES_OK;
}
int zwk_cookies_cancel_all(ZwkCookies *s) {
    int status=owner(s);if (status) return status;
    for (size_t i=0;i<s->capacity;++i) if (s->ops[i]) s->ops[i]->cancelled=TRUE;
    post_pump(s);
    return ZWK_COOKIES_OK;
}
int zwk_cookies_close(ZwkCookies *s) {
    int status=owner(s);if (status) return status;
    if (s->closed) return ZWK_COOKIES_CLOSED;
    zwk_cookies_seal(s);zwk_cookies_cancel_all(s);s->closed=TRUE;
    /* The view goes from the message loop once no call needs it. */
    post_pump(s);
    store_unref(s);return ZWK_COOKIES_OK;
}
int zwk_cookies_stats(ZwkCookies *s,ZwkCookiesStats *out) {
    int status=owner(s);if (status) return status;
    if (!out) return ZWK_COOKIES_INVALID;
    *out=(ZwkCookiesStats){s->bytes,s->peak_bytes,s->pending,!zwk_cookies_check(s)};
    return ZWK_COOKIES_OK;
}
void zwk_cookies_counts(uint32_t *stores,uint32_t *ops,size_t *bytes) {
    if (stores) *stores=(uint32_t)InterlockedCompareExchange(&live_stores,0,0);
    if (ops) *ops=(uint32_t)InterlockedCompareExchange(&live_ops,0,0);
    if (bytes) *bytes=(size_t)InterlockedCompareExchange64(&live_bytes,0,0);
}
/* Whether a store's hidden web view is open, for tests. */
int zwk_cookies_view_open(ZwkCookies *s) { return owner(s)==ZWK_COOKIES_OK&&s->phase!=VIEW_NONE; }
