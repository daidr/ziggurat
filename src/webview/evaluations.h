/* Each accepted native completion owns its own State reference. Logical
   cancellation suppresses delivery; it never claims to interrupt JavaScript. */
struct ScriptHandler {
    ICoreWebView2ExecuteScriptCompletedHandler iface;
    LONG refs;
    State *state;
    ScriptHandler *next;
    uint64_t token;
    BOOL cancelled, completed, pending;
};
static void script_unlink(ScriptHandler *handler) {
    if (!handler->pending) return;
    State *s=handler->state;
    ScriptHandler **link=&s->scripts;
    while (*link && *link!=handler) link=&(*link)->next;
    if (*link) { *link=handler->next; s->script_count--; }
    handler->pending=FALSE;
}
static HRESULT STDMETHODCALLTYPE script_query(ICoreWebView2ExecuteScriptCompletedHandler *p,REFIID iid,void **out) {
    if (!out) return E_POINTER; *out=NULL;
    if (!IsEqualIID(iid,&IID_IUnknown) && !IsEqualIID(iid,&IID_ICoreWebView2ExecuteScriptCompletedHandler)) return E_NOINTERFACE;
    *out=p; InterlockedIncrement(&((ScriptHandler *)p)->refs); return S_OK;
}
static ULONG STDMETHODCALLTYPE script_add(ICoreWebView2ExecuteScriptCompletedHandler *p) { return InterlockedIncrement(&((ScriptHandler *)p)->refs); }
static ULONG STDMETHODCALLTYPE script_release(ICoreWebView2ExecuteScriptCompletedHandler *p) {
    ScriptHandler *handler=(ScriptHandler *)p; LONG refs=InterlockedDecrement(&handler->refs);
    if (!refs) {
        State *s=handler->state;
        script_unlink(handler);
        free(handler); InterlockedDecrement(&live_handlers); release(s);
    }
    return refs;
}
static HRESULT STDMETHODCALLTYPE script_invoke(ICoreWebView2ExecuteScriptCompletedHandler *p,HRESULT hr,LPCWSTR json) {
    ScriptHandler *handler=(ScriptHandler *)p;
    if (handler->completed) return S_OK;
    handler->completed=TRUE;
    State *s=handler->state; retain(s);
    uint64_t token=handler->token;
    script_unlink(handler);
    if (!handler->cancelled && !s->closed && !s->recovering && s->script_notify) s->script_notify(s->context,token,hr,json);
    release(s); return S_OK;
}
static ICoreWebView2ExecuteScriptCompletedHandlerVtbl script_vtable={script_query,script_add,script_release,script_invoke};
HRESULT zwv_evaluate(State *s,const WCHAR *script,uint64_t token) {
    if (s->closed || s->recovering || !s->webview) return E_ABORT;
    if (s->script_count>=s->script_limit) return E_PENDING;
    ScriptHandler *handler=calloc(1,sizeof(*handler));
    if (!handler) return E_OUTOFMEMORY;
    handler->iface.lpVtbl=&script_vtable; handler->refs=1; handler->state=s; handler->token=token;
    handler->pending=TRUE;
    handler->next=s->scripts; s->scripts=handler; s->script_count++;
    retain(s); InterlockedIncrement(&live_handlers);
    HRESULT hr=ICoreWebView2_ExecuteScript(s->webview,script,&handler->iface);
    script_release(&handler->iface);
    return hr;
}
void zwv_evaluate_cancel(State *s,uint64_t token) {
    for (ScriptHandler *handler=s->scripts;handler;handler=handler->next) if (handler->token==token) { handler->cancelled=TRUE; return; }
}
HRESULT zwv_eval_timer_create(HANDLE *out) {
    *out=CreateWaitableTimerW(NULL,TRUE,NULL);
    return *out?S_OK:HRESULT_FROM_WIN32(GetLastError());
}
HRESULT zwv_eval_timer_arm(HANDLE timer,uint64_t ns) {
    uint64_t units=ns/100+(ns%100!=0); if (!units) units=1;
    if (units>INT64_MAX) return E_INVALIDARG;
    LARGE_INTEGER due; due.QuadPart=-(int64_t)units;
    return SetWaitableTimer(timer,&due,0,NULL,NULL,FALSE)?S_OK:HRESULT_FROM_WIN32(GetLastError());
}
void zwv_eval_timer_close(HANDLE timer) { CancelWaitableTimer(timer); CloseHandle(timer); }
