/* Each physical operation keeps its budget and State until the last native
   event-handler Release. Removing/cancelling never returns that capacity early. */
struct DownloadPending {
    LONG refs;
    DownloadPending *next;
    State *state;
    ActionBudget *budget;
    uint64_t token;
    ICoreWebView2DownloadOperation *operation;
    ICoreWebView2DownloadStartingEventArgs *args;
    ICoreWebView2Deferral *deferral;
    EventRegistrationToken bytes_token,state_token;
    BOOL has_bytes,has_state,linked,ready,accepting;
};
typedef struct DownloadCall { State *state;ICoreWebView2DownloadStartingEventArgs *args;ICoreWebView2DownloadOperation *operation;BOOL captured; } DownloadCall;
static void download_add(DownloadPending *request) { InterlockedIncrement(&request->refs); }
static void download_release(DownloadPending *request) {
    if (InterlockedDecrement(&request->refs)) return;
    State *s=request->state;ActionBudget *budget=request->budget;
    free(request);InterlockedDecrement(&budget->downloads);InterlockedDecrement(&download_request_live);zwv_action_budget_release(budget);release(s);
}
static DownloadPending *download_find(State *s,uint64_t token) {
    for (DownloadPending *p=s->download_requests;p;p=p->next) if (p->token==token) return p;
    return NULL;
}
static void download_unlink(DownloadPending *request) {
    if (!request->linked) return;
    DownloadPending **link=&request->state->download_requests;
    while (*link&&*link!=request) link=&(*link)->next;
    if (*link) *link=request->next;
    request->next=NULL;request->linked=FALSE;request->ready=FALSE;
}
static HRESULT download_native_close(DownloadPending *request,BOOL cancel) {
    request->ready=FALSE;
    HRESULT hr=S_OK;
    if (request->operation) {
        if (request->has_bytes) { request->has_bytes=FALSE;ICoreWebView2DownloadOperation_remove_BytesReceivedChanged(request->operation,request->bytes_token); }
        if (request->has_state) { request->has_state=FALSE;ICoreWebView2DownloadOperation_remove_StateChanged(request->operation,request->state_token); }
        if (cancel) hr=ICoreWebView2DownloadOperation_Cancel(request->operation);
    }
    if (request->deferral) {
        ICoreWebView2Deferral *deferral=request->deferral;request->deferral=NULL;
        HRESULT complete=ICoreWebView2Deferral_Complete(deferral);ICoreWebView2Deferral_Release(deferral);
        if (SUCCEEDED(hr)) hr=complete;
    }
    if (request->args) { ICoreWebView2DownloadStartingEventArgs_Release(request->args);request->args=NULL; }
    if (request->operation) { ICoreWebView2DownloadOperation_Release(request->operation);request->operation=NULL; }
    return hr;
}
static HRESULT download_snapshot(DownloadPending *request,uint64_t *received,int64_t *total,COREWEBVIEW2_DOWNLOAD_STATE *state,COREWEBVIEW2_DOWNLOAD_INTERRUPT_REASON *reason) {
    ICoreWebView2DownloadOperation *operation=request->operation;
    if (!operation) return E_ABORT;
    ICoreWebView2DownloadOperation_AddRef(operation);
    INT64 bytes=0;*total=-1;*received=0;*state=COREWEBVIEW2_DOWNLOAD_STATE_IN_PROGRESS;*reason=COREWEBVIEW2_DOWNLOAD_INTERRUPT_REASON_NONE;
    HRESULT hr=ICoreWebView2DownloadOperation_get_BytesReceived(operation,&bytes);
    if (SUCCEEDED(hr)&&bytes<0) hr=E_UNEXPECTED;
    if (SUCCEEDED(hr)) { *received=(uint64_t)bytes;hr=ICoreWebView2DownloadOperation_get_TotalBytesToReceive(operation,total); }
    if (SUCCEEDED(hr)) hr=ICoreWebView2DownloadOperation_get_State(operation,state);
    if (SUCCEEDED(hr)&&*state==COREWEBVIEW2_DOWNLOAD_STATE_INTERRUPTED) hr=ICoreWebView2DownloadOperation_get_InterruptReason(operation,reason);
    ICoreWebView2DownloadOperation_Release(operation);
    return hr;
}
static void download_emit(DownloadPending *request) {
    download_add(request);State *s=request->state;
    if (!request->ready||!request->linked||s->closed||s->recovering||!s->actions||!s->actions->download_notify) { download_release(request);return; }
    uint64_t received;int64_t total;COREWEBVIEW2_DOWNLOAD_STATE state;COREWEBVIEW2_DOWNLOAD_INTERRUPT_REASON reason;
    HRESULT hr=download_snapshot(request,&received,&total,&state,&reason);
    if (!request->linked||s->closed||s->recovering) { download_release(request);return; }
    uint32_t kind=0;int32_t code=(int32_t)reason;
    if (FAILED(hr)) { kind=4;code=hr; }
    else if (received>s->actions->download_received_limit) kind=3;
    else if (state==COREWEBVIEW2_DOWNLOAD_STATE_COMPLETED) kind=1;
    else if (state==COREWEBVIEW2_DOWNLOAD_STATE_INTERRUPTED&&reason!=COREWEBVIEW2_DOWNLOAD_INTERRUPT_REASON_USER_PAUSED) kind=2;
    DownloadNotifyCallback callback=s->actions->download_notify;void *context=s->context;
    if (kind) {
        download_unlink(request);download_native_close(request,kind!=1);download_release(request);
    }
    if (!s->closed&&!s->recovering&&s->context==context&&s->actions&&s->actions->download_notify==callback) callback(context,request->token,kind,received,total,code);
    download_release(request);
}
#define DOWNLOAD_EVENT(Name,Interface) \
typedef struct Name { Interface iface;LONG refs;DownloadPending *request; } Name; \
static ULONG STDMETHODCALLTYPE Name##_add(Interface *p) { return InterlockedIncrement(&((Name *)p)->refs); } \
static ULONG STDMETHODCALLTYPE Name##_release(Interface *p) { Name *h=(Name *)p;ULONG n=InterlockedDecrement(&h->refs);if (!n) { DownloadPending *r=h->request;free(h);InterlockedDecrement(&live_handlers);download_release(r); }return n; } \
static HRESULT STDMETHODCALLTYPE Name##_query(Interface *p,REFIID iid,void **out) { if (!out) return E_POINTER;*out=NULL;if (!IsEqualIID(iid,&IID_IUnknown)&&!IsEqualIID(iid,&IID_##Interface)) return E_NOINTERFACE;*out=p;Name##_add(p);return S_OK; } \
static HRESULT STDMETHODCALLTYPE Name##_invoke(Interface *p,ICoreWebView2DownloadOperation *sender,IUnknown *args) { (void)sender;(void)args;download_emit(((Name *)p)->request);return S_OK; } \
static Interface##Vtbl Name##_vtable={Name##_query,Name##_add,Name##_release,Name##_invoke}; \
static Name *Name##_new(DownloadPending *request) { Name *h=calloc(1,sizeof(*h));if (!h) return NULL;h->iface.lpVtbl=&Name##_vtable;h->refs=1;h->request=request;download_add(request);InterlockedIncrement(&live_handlers);return h; }
DOWNLOAD_EVENT(DownloadBytes,ICoreWebView2BytesReceivedChangedEventHandler)
DOWNLOAD_EVENT(DownloadState,ICoreWebView2StateChangedEventHandler)
#undef DOWNLOAD_EVENT
static BOOL download_origin_allowed(State *s,const WCHAR *uri,int64_t total) {
    if (!s->actions||!s->actions->download_offer||!bounded_uri(uri)) return FALSE;
    if (total<0&&!s->actions->download_unknown) return FALSE;
    if (total>=0&&(uint64_t)total>s->actions->download_known_limit) return FALSE;
    NetOrigin actual,grant;if (FAILED(parse_net_origin(uri,FALSE,TRUE,TRUE,&actual))) return FALSE;
    for (uint32_t i=0;i<s->actions->download_origin_count;i++) if (SUCCEEDED(parse_net_origin(s->actions->download_origins[i],TRUE,TRUE,TRUE,&grant))&&origin_equal(&actual,&grant)) return TRUE;
    return FALSE;
}
HRESULT zwv_download_defer(void *opaque,uint64_t token) {
    DownloadCall *call=opaque;State *s=call->state;
    if (call->captured||s->closed||s->recovering||!s->actions) return E_ABORT;
    ActionBudget *budget=s->actions->budget;
    LONG live=InterlockedIncrement(&budget->downloads);
    if (live>InterlockedCompareExchange(&budget->download_limit,0,0)) { InterlockedDecrement(&budget->downloads);return E_PENDING; }
    if (InterlockedIncrement(&download_request_live)>16) { InterlockedDecrement(&download_request_live);InterlockedDecrement(&budget->downloads);return E_PENDING; }
    DownloadPending *request=calloc(1,sizeof(*request));
    if (!request) { InterlockedDecrement(&download_request_live);InterlockedDecrement(&budget->downloads);return E_OUTOFMEMORY; }
    request->refs=1;request->state=s;retain(s);request->budget=budget;action_budget_add(budget);request->token=token;
    request->operation=call->operation;ICoreWebView2DownloadOperation_AddRef(request->operation);
    request->args=call->args;ICoreWebView2DownloadStartingEventArgs_AddRef(request->args);
    HRESULT hr=ICoreWebView2DownloadStartingEventArgs_GetDeferral(request->args,&request->deferral);
    if (SUCCEEDED(hr)&&!request->deferral) hr=E_POINTER;
    DownloadBytes *bytes=NULL;DownloadState *state=NULL;
    if (SUCCEEDED(hr)) { bytes=DownloadBytes_new(request);if (!bytes) hr=E_OUTOFMEMORY; }
    if (SUCCEEDED(hr)) { hr=ICoreWebView2DownloadOperation_add_BytesReceivedChanged(request->operation,&bytes->iface,&request->bytes_token);request->has_bytes=SUCCEEDED(hr); }
    if (bytes) DownloadBytes_release(&bytes->iface);
    if (SUCCEEDED(hr)) { state=DownloadState_new(request);if (!state) hr=E_OUTOFMEMORY; }
    if (SUCCEEDED(hr)) { hr=ICoreWebView2DownloadOperation_add_StateChanged(request->operation,&state->iface,&request->state_token);request->has_state=SUCCEEDED(hr); }
    if (state) DownloadState_release(&state->iface);
    if (FAILED(hr)||s->closed||s->recovering) { download_native_close(request,TRUE);download_release(request);return FAILED(hr)?hr:E_ABORT; }
    request->next=s->download_requests;s->download_requests=request;request->linked=TRUE;call->captured=TRUE;return S_OK;
}
HRESULT zwv_download_accept(State *s,uint64_t token,const WCHAR *path) {
    DownloadPending *request=download_find(s,token);
    if (!request||request->ready||request->accepting||!request->args||!path||!*path||wcsnlen(path,32767)>32766) return E_INVALIDARG;
    download_add(request);request->accepting=TRUE;
    ICoreWebView2DownloadOperation *operation=request->operation;ICoreWebView2DownloadOperation_AddRef(operation);
    ICoreWebView2DownloadStartingEventArgs *args=request->args;ICoreWebView2DownloadStartingEventArgs_AddRef(args);
    INT64 total=-1;HRESULT hr=ICoreWebView2DownloadOperation_get_TotalBytesToReceive(operation,&total);
    if (SUCCEEDED(hr)&&((total<0&&!s->actions->download_unknown)||(total>=0&&(uint64_t)total>s->actions->download_known_limit))) hr=E_ACCESSDENIED;
    if (SUCCEEDED(hr)&&request->linked&&!s->closed&&!s->recovering) hr=ICoreWebView2DownloadStartingEventArgs_put_ResultFilePath(args,path);
    if (SUCCEEDED(hr)&&request->linked&&!s->closed&&!s->recovering) hr=ICoreWebView2DownloadStartingEventArgs_put_Cancel(args,FALSE);
    if (SUCCEEDED(hr)&&request->linked&&!s->closed&&!s->recovering&&request->deferral) {
        ICoreWebView2Deferral *deferral=request->deferral;request->deferral=NULL;
        hr=ICoreWebView2Deferral_Complete(deferral);ICoreWebView2Deferral_Release(deferral);
    }
    if (!request->linked||s->closed||s->recovering) hr=E_ABORT;
    if (request->args) { ICoreWebView2DownloadStartingEventArgs_Release(request->args);request->args=NULL; }
    ICoreWebView2DownloadStartingEventArgs_Release(args);ICoreWebView2DownloadOperation_Release(operation);
    request->accepting=FALSE;download_release(request);return hr;
}
void zwv_download_activate(State *s,uint64_t token) { DownloadPending *request=download_find(s,token);if (request) { request->ready=TRUE;download_emit(request); } }
HRESULT zwv_download_snapshot(State *s,uint64_t token,uint64_t *received,int64_t *total,_Bool *paused) {
    DownloadPending *request=download_find(s,token);if (!request||!request->ready) return E_INVALIDARG;
    download_add(request);COREWEBVIEW2_DOWNLOAD_STATE state;COREWEBVIEW2_DOWNLOAD_INTERRUPT_REASON reason;
    HRESULT hr=download_snapshot(request,received,total,&state,&reason);
    if (!request->linked||s->closed||s->recovering) hr=E_ABORT;
    if (SUCCEEDED(hr)) *paused=state==COREWEBVIEW2_DOWNLOAD_STATE_INTERRUPTED&&reason==COREWEBVIEW2_DOWNLOAD_INTERRUPT_REASON_USER_PAUSED;
    download_release(request);return hr;
}
HRESULT zwv_download_cancel(State *s,uint64_t token) {
    DownloadPending *request=download_find(s,token);if (!request) return S_FALSE;
    download_unlink(request);HRESULT hr=download_native_close(request,TRUE);download_release(request);return hr;
}
HRESULT zwv_download_pause(State *s,uint64_t token,_Bool pause) {
    DownloadPending *request=download_find(s,token);if (!request||!request->ready) return E_INVALIDARG;
    download_add(request);ICoreWebView2DownloadOperation *operation=request->operation;ICoreWebView2DownloadOperation_AddRef(operation);
    HRESULT hr=pause?ICoreWebView2DownloadOperation_Pause(operation):ICoreWebView2DownloadOperation_Resume(operation);
    ICoreWebView2DownloadOperation_Release(operation);
    if (SUCCEEDED(hr)&&request->linked) download_emit(request);
    download_release(request);return hr;
}
static void download_requests_close(State *s) {
    DownloadPending *snapshot=s->download_requests;s->download_requests=NULL;
    for (DownloadPending *p=snapshot;p;p=p->next) { p->linked=FALSE;p->ready=FALSE; }
    while (snapshot) { DownloadPending *next=snapshot->next;snapshot->next=NULL;download_native_close(snapshot,TRUE);download_release(snapshot);snapshot=next; }
}
