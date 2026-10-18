#include "bounded_stream.h"
#define TOOL_LIMIT_HR HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER)
static LONG owned_tool_pending;
static void browser_tools_close(State *s);
typedef struct NativeFind { int32_t matches,active_index; } NativeFind;
typedef struct NativeCookie { WCHAR *name,*value,*domain,*path; double expires; uint32_t flags,same_site; } NativeCookie;
typedef struct NativeToolRequest { uint32_t kind,flags; uint64_t token; const WCHAR *text; uint32_t first_page,last_page; } NativeToolRequest;
typedef struct NativeCookieWrite { const WCHAR *name,*value,*path; double expires; uint32_t flags,same_site; } NativeCookieWrite;
struct ToolOperation {
    const void *vtable;
    LONG refs;
    State *state;
    ToolOperation *next;
    uint64_t token;
    uint32_t kind;
    BOOL cancelled,completed,pending;
    BoundedStream *stream;
    WCHAR *path;
};
static void tool_unlink(ToolOperation *op) {
    if (!op->pending) return;
    ToolOperation **link=&op->state->tools;
    while (*link && *link!=op) link=&(*link)->next;
    if (*link) { *link=op->next; op->state->tool_count--; InterlockedDecrement(&owned_tool_pending); }
    op->pending=FALSE;
}
static ULONG tool_release(ToolOperation *op) {
    LONG refs=InterlockedDecrement(&op->refs);
    if (!refs) {
        State *s=op->state; tool_unlink(op);
        if (op->stream) IStream_Release(&op->stream->iface);
        free(op->path); free(op); InterlockedDecrement(&live_handlers); release(s);
    }
    return refs;
}
static void tool_complete(ToolOperation *op,HRESULT hr,const void *data,uint32_t count) {
    if (op->completed) return;
    op->completed=TRUE; tool_unlink(op);
    State *s=op->state; InterlockedIncrement(&op->refs);
    if (!op->cancelled && !s->closed && !s->recovering && s->tool_notify) s->tool_notify(s->context,op->token,op->kind,hr,data,count);
    tool_release(op);
}
static ToolOperation *tool_new(State *s,const void *vtable,uint32_t kind,uint64_t token) {
    ToolOperation *op=calloc(1,sizeof(*op)); if (!op) return NULL;
    op->vtable=vtable; op->refs=1; op->state=s; op->kind=kind; op->token=token; op->pending=TRUE;
    op->next=s->tools; s->tools=op; s->tool_count++; retain(s); InterlockedIncrement(&live_handlers); InterlockedIncrement(&owned_tool_pending); return op;
}
#define TOOL_COM(Name,Interface,Id) \
    static HRESULT STDMETHODCALLTYPE Name##_query(Interface *p,REFIID iid,void **out) { if (!out) return E_POINTER; *out=NULL; if (!IsEqualIID(iid,&IID_IUnknown)&&!IsEqualIID(iid,&Id)) return E_NOINTERFACE; *out=p; InterlockedIncrement(&((ToolOperation *)p)->refs); return S_OK; } \
    static ULONG STDMETHODCALLTYPE Name##_add(Interface *p) { return InterlockedIncrement(&((ToolOperation *)p)->refs); } \
    static ULONG STDMETHODCALLTYPE Name##_release(Interface *p) { return tool_release((ToolOperation *)p); }
TOOL_COM(tool_cookie,ICoreWebView2GetCookiesCompletedHandler,IID_ICoreWebView2GetCookiesCompletedHandler)
TOOL_COM(tool_clear,ICoreWebView2ClearBrowsingDataCompletedHandler,IID_ICoreWebView2ClearBrowsingDataCompletedHandler)
TOOL_COM(tool_find,ICoreWebView2FindStartCompletedHandler,IID_ICoreWebView2FindStartCompletedHandler)
TOOL_COM(tool_capture,ICoreWebView2CapturePreviewCompletedHandler,IID_ICoreWebView2CapturePreviewCompletedHandler)
TOOL_COM(tool_pdf,ICoreWebView2PrintToPdfCompletedHandler,IID_ICoreWebView2PrintToPdfCompletedHandler)
static HRESULT STDMETHODCALLTYPE tool_cookie_invoke(ICoreWebView2GetCookiesCompletedHandler *p,HRESULT hr,ICoreWebView2CookieList *list) {
    ToolOperation *op=(ToolOperation *)p; State *s=op->state;
    NativeCookie cookies[128]; memset(cookies,0,sizeof(cookies));
    uint32_t count=0; size_t budget=0;
    if (SUCCEEDED(hr)) hr=list?ICoreWebView2CookieList_get_Count(list,&count):E_POINTER;
    if (SUCCEEDED(hr) && count>s->max_cookies) hr=TOOL_LIMIT_HR;
    for (uint32_t i=0;SUCCEEDED(hr)&&i<count;i++) {
        ICoreWebView2Cookie *cookie=NULL;
        hr=ICoreWebView2CookieList_GetValueAtIndex(list,i,&cookie);
        if (SUCCEEDED(hr) && !cookie) hr=E_POINTER;
        if (SUCCEEDED(hr)) hr=ICoreWebView2Cookie_get_Name(cookie,&cookies[i].name);
        if (SUCCEEDED(hr)) hr=ICoreWebView2Cookie_get_Value(cookie,&cookies[i].value);
        if (SUCCEEDED(hr)) hr=ICoreWebView2Cookie_get_Domain(cookie,&cookies[i].domain);
        if (SUCCEEDED(hr)) hr=ICoreWebView2Cookie_get_Path(cookie,&cookies[i].path);
        if (SUCCEEDED(hr)) hr=ICoreWebView2Cookie_get_Expires(cookie,&cookies[i].expires);
        BOOL secure=FALSE,http=FALSE,session=FALSE; COREWEBVIEW2_COOKIE_SAME_SITE_KIND same=COREWEBVIEW2_COOKIE_SAME_SITE_KIND_LAX;
        if (SUCCEEDED(hr)) hr=ICoreWebView2Cookie_get_IsSecure(cookie,&secure);
        if (SUCCEEDED(hr)) hr=ICoreWebView2Cookie_get_IsHttpOnly(cookie,&http);
        if (SUCCEEDED(hr)) hr=ICoreWebView2Cookie_get_IsSession(cookie,&session);
        if (SUCCEEDED(hr)) hr=ICoreWebView2Cookie_get_SameSite(cookie,&same);
        cookies[i].flags=(secure?1:0)|(http?2:0)|(session?4:0); cookies[i].same_site=(uint32_t)same;
        if (cookie) ICoreWebView2Cookie_Release(cookie);
        WCHAR *strings[]={cookies[i].name,cookies[i].value,cookies[i].domain,cookies[i].path};
        for (unsigned j=0;SUCCEEDED(hr)&&j<4;j++) {
            if (!strings[j]) { hr=E_POINTER; break; }
            size_t units=wcsnlen(strings[j],4097);
            if (units>4096 || (budget+=units*sizeof(WCHAR))>s->max_cookie_bytes) hr=TOOL_LIMIT_HR;
        }
    }
    tool_complete(op,hr,cookies,SUCCEEDED(hr)?count:0);
    for (unsigned i=0;i<128;i++) { CoTaskMemFree(cookies[i].name);CoTaskMemFree(cookies[i].value);CoTaskMemFree(cookies[i].domain);CoTaskMemFree(cookies[i].path); }
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE tool_clear_invoke(ICoreWebView2ClearBrowsingDataCompletedHandler *p,HRESULT hr) { tool_complete((ToolOperation *)p,hr,NULL,0);return S_OK; }
static HRESULT find_snapshot(State *s,NativeFind *out) {
    if (!s->find || !s->find_token) return E_ABORT;
    HRESULT hr=ICoreWebView2Find_get_MatchCount(s->find,&out->matches);
    if (SUCCEEDED(hr)) hr=ICoreWebView2Find_get_ActiveMatchIndex(s->find,&out->active_index);
    return hr;
}
static HRESULT STDMETHODCALLTYPE tool_find_invoke(ICoreWebView2FindStartCompletedHandler *p,HRESULT hr) {
    ToolOperation *op=(ToolOperation *)p; NativeFind snapshot={0,-1};
    if (SUCCEEDED(hr)) hr=find_snapshot(op->state,&snapshot);
    if (SUCCEEDED(hr) && op->state->find_token==op->token) op->state->find_ready=TRUE;
    tool_complete(op,hr,&snapshot,1);return S_OK;
}
static HRESULT STDMETHODCALLTYPE tool_capture_invoke(ICoreWebView2CapturePreviewCompletedHandler *p,HRESULT hr) {
    ToolOperation *op=(ToolOperation *)p;
    HRESULT sink=bounded_stream_seal(op->stream);
    if (FAILED(sink)) hr=sink;
    tool_complete(op,hr,op->stream->bytes,(uint32_t)op->stream->length);return S_OK;
}
static HRESULT STDMETHODCALLTYPE tool_pdf_invoke(ICoreWebView2PrintToPdfCompletedHandler *p,HRESULT hr,BOOL success) {
    tool_complete((ToolOperation *)p,SUCCEEDED(hr)&&!success?E_FAIL:hr,NULL,0);return S_OK;
}
static ICoreWebView2GetCookiesCompletedHandlerVtbl tool_cookie_vtable={tool_cookie_query,tool_cookie_add,tool_cookie_release,tool_cookie_invoke};
static ICoreWebView2ClearBrowsingDataCompletedHandlerVtbl tool_clear_vtable={tool_clear_query,tool_clear_add,tool_clear_release,tool_clear_invoke};
static ICoreWebView2FindStartCompletedHandlerVtbl tool_find_vtable={tool_find_query,tool_find_add,tool_find_release,tool_find_invoke};
static ICoreWebView2CapturePreviewCompletedHandlerVtbl tool_capture_vtable={tool_capture_query,tool_capture_add,tool_capture_release,tool_capture_invoke};
static ICoreWebView2PrintToPdfCompletedHandlerVtbl tool_pdf_vtable={tool_pdf_query,tool_pdf_add,tool_pdf_release,tool_pdf_invoke};
static HRESULT cookie_origin(State *s,const WCHAR *uri,NetOrigin *out) {
    if (s->remote.enabled) {
        if (!(remote_grants(&s->remote,uri)&REMOTE_NAVIGATE)) return E_ACCESSDENIED;
        return net_origin(uri,FALSE,s->remote.allow_loopback,out);
    }
    if (!s->local_prefix) return E_ACCESSDENIED;
    NetOrigin local;
    HRESULT hr=parse_net_origin(s->local_prefix,FALSE,TRUE,TRUE,&local);
    if (SUCCEEDED(hr)) hr=parse_net_origin(uri,FALSE,TRUE,TRUE,out);
    return SUCCEEDED(hr)&&origin_equal(&local,out)?S_OK:E_ACCESSDENIED;
}
static HRESULT cookie_manager(State *s,ICoreWebView2CookieManager **out) {
    ICoreWebView2_2 *view=NULL;
    HRESULT hr=ICoreWebView2_QueryInterface(s->webview,&IID_ICoreWebView2_2,(void **)&view);
    if (SUCCEEDED(hr)) { hr=ICoreWebView2_2_get_CookieManager(view,out);ICoreWebView2_2_Release(view); }
    return hr;
}
HRESULT zwv_cookie_write(State *s,const WCHAR *uri,const NativeCookieWrite *input,_Bool remove) {
    if (s->closed||s->recovering||!s->webview) return E_ABORT;
    if (!(s->tool_flags&1)) return E_ACCESSDENIED;
    NetOrigin origin; HRESULT hr=cookie_origin(s,uri,&origin); if (FAILED(hr)) return hr;
    ICoreWebView2CookieManager *manager=NULL; ICoreWebView2Cookie *cookie=NULL;
    hr=cookie_manager(s,&manager);
    if (SUCCEEDED(hr) && remove) hr=ICoreWebView2CookieManager_DeleteCookiesWithDomainAndPath(manager,input->name,origin.host,input->path);
    else if (SUCCEEDED(hr)) {
        hr=ICoreWebView2CookieManager_CreateCookie(manager,input->name,input->value,origin.host,input->path,&cookie);
        if (SUCCEEDED(hr)) hr=ICoreWebView2Cookie_put_IsSecure(cookie,(input->flags&1)!=0);
        if (SUCCEEDED(hr)) hr=ICoreWebView2Cookie_put_IsHttpOnly(cookie,(input->flags&2)!=0);
        if (SUCCEEDED(hr)) hr=ICoreWebView2Cookie_put_SameSite(cookie,(COREWEBVIEW2_COOKIE_SAME_SITE_KIND)input->same_site);
        if (SUCCEEDED(hr) && !(input->flags&4)) hr=ICoreWebView2Cookie_put_Expires(cookie,input->expires);
        if (SUCCEEDED(hr)) hr=ICoreWebView2CookieManager_AddOrUpdateCookie(manager,cookie);
    }
    if (cookie) ICoreWebView2Cookie_Release(cookie);
    if (manager) ICoreWebView2CookieManager_Release(manager);
    return hr;
}
static void find_changed(State *s) {
    retain(s); NativeFind snapshot={0,-1};
    if (!s->closed&&!s->recovering&&s->find_ready&&s->find_token&&s->tool_notify&&SUCCEEDED(find_snapshot(s,&snapshot))) s->tool_notify(s->context,s->find_token,5,S_OK,&snapshot,1);
    release(s);
}
static HRESULT STDMETHODCALLTYPE find_match_invoke(ICoreWebView2FindMatchCountChangedEventHandler *p,ICoreWebView2Find *sender,IUnknown *args) { (void)sender;(void)args;find_changed(((FindMatchHandler *)p)->state);return S_OK; }
static HRESULT STDMETHODCALLTYPE find_index_invoke(ICoreWebView2FindActiveMatchIndexChangedEventHandler *p,ICoreWebView2Find *sender,IUnknown *args) { (void)sender;(void)args;find_changed(((FindIndexHandler *)p)->state);return S_OK; }
static HRESULT prepare_find(State *s) {
    if (s->find) return S_OK;
    ICoreWebView2_28 *view=NULL;
    HRESULT hr=ICoreWebView2_QueryInterface(s->webview,&IID_ICoreWebView2_28,(void **)&view);
    if (SUCCEEDED(hr)) { hr=ICoreWebView2_28_get_Find(view,&s->find);ICoreWebView2_28_Release(view); }
    if (FAILED(hr)) return hr;
    FindMatchHandler *match=FindMatchHandler_new(s); if (!match) { browser_tools_close(s);return E_OUTOFMEMORY; }
    hr=ICoreWebView2Find_add_MatchCountChanged(s->find,&match->iface,&s->find_match_token);FindMatchHandler_release(&match->iface);
    if (FAILED(hr)) { browser_tools_close(s);return hr; } s->has_find_match=TRUE;
    FindIndexHandler *index=FindIndexHandler_new(s); if (!index) { browser_tools_close(s);return E_OUTOFMEMORY; }
    hr=ICoreWebView2Find_add_ActiveMatchIndexChanged(s->find,&index->iface,&s->find_index_token);FindIndexHandler_release(&index->iface);
    if (SUCCEEDED(hr)) s->has_find_index=TRUE;
    else browser_tools_close(s);
    return hr;
}
HRESULT zwv_tool_start(State *s,const NativeToolRequest *request) {
    if (s->closed||s->recovering||!s->webview) return E_ABORT;
    if (request->kind>4 || !(s->tool_flags&(1u<<request->kind))) return E_ACCESSDENIED;
    if (s->tool_count>=s->tool_limit) return E_PENDING;
    HRESULT hr=E_INVALIDARG; ToolOperation *op=NULL;
    if (request->kind==0) {
        NetOrigin origin; hr=cookie_origin(s,request->text,&origin); if (FAILED(hr)) return hr;
        ICoreWebView2CookieManager *manager=NULL; hr=cookie_manager(s,&manager); if (FAILED(hr)) return hr;
        op=tool_new(s,&tool_cookie_vtable,0,request->token);
        hr=op?ICoreWebView2CookieManager_GetCookies(manager,request->text,(ICoreWebView2GetCookiesCompletedHandler *)op):E_OUTOFMEMORY;
        ICoreWebView2CookieManager_Release(manager);
    } else if (request->kind==1) {
        op=tool_new(s,&tool_clear_vtable,1,request->token);
        hr=op?ICoreWebView2Profile4_ClearBrowsingDataAll(s->profile,(ICoreWebView2ClearBrowsingDataCompletedHandler *)op):E_OUTOFMEMORY;
    } else if (request->kind==2) {
        hr=prepare_find(s); if (FAILED(hr)) return hr;
        ICoreWebView2Environment15 *environment=NULL; ICoreWebView2FindOptions *options=NULL;
        hr=ICoreWebView2Environment_QueryInterface(s->environment,&IID_ICoreWebView2Environment15,(void **)&environment);
        if (SUCCEEDED(hr)) { hr=ICoreWebView2Environment15_CreateFindOptions(environment,&options);ICoreWebView2Environment15_Release(environment); }
        if (SUCCEEDED(hr)) hr=ICoreWebView2FindOptions_put_FindTerm(options,request->text);
        if (SUCCEEDED(hr)) hr=ICoreWebView2FindOptions_put_IsCaseSensitive(options,(request->flags&1)!=0);
        if (SUCCEEDED(hr)) hr=ICoreWebView2FindOptions_put_ShouldMatchWord(options,(request->flags&2)!=0);
        if (SUCCEEDED(hr)) hr=ICoreWebView2FindOptions_put_ShouldHighlightAllMatches(options,(request->flags&4)!=0);
        if (SUCCEEDED(hr)) hr=ICoreWebView2FindOptions_put_SuppressDefaultFindDialog(options,TRUE);
        if (SUCCEEDED(hr)) {
            op=tool_new(s,&tool_find_vtable,2,request->token); s->find_token=request->token; s->find_ready=FALSE;
            hr=op?ICoreWebView2Find_Start(s->find,options,(ICoreWebView2FindStartCompletedHandler *)op):E_OUTOFMEMORY;
            if (FAILED(hr)) s->find_token=0;
        }
        if (options) ICoreWebView2FindOptions_Release(options);
    } else if (request->kind==3) {
        op=tool_new(s,&tool_capture_vtable,3,request->token);
        if (op) op->stream=bounded_stream_new(s->max_capture_bytes);
        hr=op&&op->stream?ICoreWebView2_CapturePreview(s->webview,COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_PNG,&op->stream->iface,(ICoreWebView2CapturePreviewCompletedHandler *)op):E_OUTOFMEMORY;
    } else if (request->kind==4) {
        ICoreWebView2_7 *view=NULL; ICoreWebView2Environment6 *environment=NULL; ICoreWebView2PrintSettings *settings=NULL; ICoreWebView2PrintSettings2 *settings2=NULL;
        hr=ICoreWebView2_QueryInterface(s->webview,&IID_ICoreWebView2_7,(void **)&view);
        if (SUCCEEDED(hr)) hr=ICoreWebView2Environment_QueryInterface(s->environment,&IID_ICoreWebView2Environment6,(void **)&environment);
        if (SUCCEEDED(hr)) hr=ICoreWebView2Environment6_CreatePrintSettings(environment,&settings);
        if (SUCCEEDED(hr)) hr=ICoreWebView2PrintSettings_QueryInterface(settings,&IID_ICoreWebView2PrintSettings2,(void **)&settings2);
        WCHAR pages[32]; _snwprintf(pages,32,L"%u-%u",request->first_page,request->last_page);
        if (SUCCEEDED(hr)) hr=ICoreWebView2PrintSettings2_put_PageRanges(settings2,pages);
        if (SUCCEEDED(hr)) hr=ICoreWebView2PrintSettings_put_Orientation(settings,(request->flags&1)?COREWEBVIEW2_PRINT_ORIENTATION_LANDSCAPE:COREWEBVIEW2_PRINT_ORIENTATION_PORTRAIT);
        if (SUCCEEDED(hr)) hr=ICoreWebView2PrintSettings_put_ShouldPrintBackgrounds(settings,(request->flags&2)!=0);
        if (SUCCEEDED(hr)) {
            op=tool_new(s,&tool_pdf_vtable,4,request->token);
            if (op) op->path=_wcsdup(request->text);
            hr=op&&op->path?ICoreWebView2_7_PrintToPdf(view,op->path,settings,(ICoreWebView2PrintToPdfCompletedHandler *)op):E_OUTOFMEMORY;
        }
        if (settings2) ICoreWebView2PrintSettings2_Release(settings2);
        if (settings) ICoreWebView2PrintSettings_Release(settings);
        if (environment) ICoreWebView2Environment6_Release(environment);
        if (view) ICoreWebView2_7_Release(view);
    }
    if (op) tool_release(op);
    return hr;
}
HRESULT zwv_find_action(State *s,int action,NativeFind *out) {
    if (s->closed||s->recovering||!s->find||!s->find_token) return E_ABORT;
    if (action==0) return find_snapshot(s,out);
    if (action==1) return ICoreWebView2Find_FindNext(s->find);
    if (action==2) return ICoreWebView2Find_FindPrevious(s->find);
    if (action==3) { s->find_token=0; s->find_ready=FALSE; return ICoreWebView2Find_Stop(s->find); }
    return E_INVALIDARG;
}
void zwv_tool_cancel(State *s,uint64_t token) {
    for (ToolOperation *op=s->tools;op;op=op->next) if (op->token==token) { op->cancelled=TRUE;break; }
    if (s->find && s->find_token==token) { s->find_token=0;s->find_ready=FALSE;ICoreWebView2Find_Stop(s->find); }
}
static void browser_tools_close(State *s) {
    if (s->find) {
        s->find_token=0; s->find_ready=FALSE;
        if (s->has_find_match) ICoreWebView2Find_remove_MatchCountChanged(s->find,s->find_match_token);
        if (s->has_find_index) ICoreWebView2Find_remove_ActiveMatchIndexChanged(s->find,s->find_index_token);
        ICoreWebView2Find_Stop(s->find); ICoreWebView2Find_Release(s->find); s->find=NULL;
        s->has_find_match=FALSE; s->has_find_index=FALSE;
    }
}
void zwv_tool_counts(uint32_t *streams,uint32_t *pending) {
    *streams=(uint32_t)InterlockedCompareExchange(&owned_tool_streams,0,0);
    *pending=(uint32_t)InterlockedCompareExchange(&owned_tool_pending,0,0);
}
