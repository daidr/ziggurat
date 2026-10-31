/* Included after State and start_document. A single operation owns the native
   mutation slot until Add and any compensating Remove have retired. */
typedef struct InitializerHandler InitializerHandler;
struct InitializerState {
    InitializerBudget *budget;
    WCHAR *id;
    size_t id_bytes;
    InitializerHandler *pending; /* borrowed: constructor/SDK owns the handler */
    BOOL blocked;
};
struct InitializerHandler {
    ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler iface;
    LONG refs;
    State *state;
    InitializerBudget *budget;
    ICoreWebView2 *webview;
    InitializerNotify notify;
    uint64_t token;
    size_t bytes;
    BOOL submitted,cancelled,initial,invoked;
    WCHAR source[];
};
static void initializers_free(InitializerState *owner) {
    if (!owner) return;
    InitializerBudget *budget=owner->budget;
    size_t bytes=owner->id_bytes;
    free(owner->id);zwv_initializer_budget_release(budget,bytes);
    free(owner);zwv_initializer_budget_release(budget,sizeof(*owner));
    InterlockedDecrement(&initializer_owners);zwv_initializer_budget_unref(budget);
}
static HRESULT initializers_owner(State *s,InitializerBudget *budget) {
    if (!budget) return E_INVALIDARG;
    if (s->initializers) return s->initializers->budget==budget?S_OK:E_INVALIDARG;
    zwv_initializer_budget_retain(budget);
    if (!zwv_initializer_budget_reserve(budget,sizeof(InitializerState))) {
        zwv_initializer_budget_unref(budget);return HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA);
    }
    InitializerState *owner=calloc(1,sizeof(*owner));
    if (!owner) {
        zwv_initializer_budget_release(budget,sizeof(*owner));zwv_initializer_budget_unref(budget);return E_OUTOFMEMORY;
    }
    owner->budget=budget;s->initializers=owner;InterlockedIncrement(&initializer_owners);return S_OK;
}
static BOOL initializers_allow_navigation(State *s) {
    return !s->initializers || (!s->initializers->pending && !s->initializers->blocked);
}
_Bool zwv_initializers_blocked(State *s) { return s->initializers && s->initializers->blocked; }
static HRESULT STDMETHODCALLTYPE initializer_query(ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler *p,REFIID iid,void **out) {
    if (!out) return E_POINTER;*out=NULL;
    if (!IsEqualIID(iid,&IID_IUnknown) && !IsEqualIID(iid,&IID_ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler)) return E_NOINTERFACE;
    *out=p;InterlockedIncrement(&((InitializerHandler *)p)->refs);return S_OK;
}
static ULONG STDMETHODCALLTYPE initializer_add(ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler *p) {
    return InterlockedIncrement(&((InitializerHandler *)p)->refs);
}
static ULONG STDMETHODCALLTYPE initializer_release(ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler *p) {
    InitializerHandler *h=(InitializerHandler *)p;LONG refs=InterlockedDecrement(&h->refs);
    if (!refs) {
        State *s=h->state;InitializerBudget *budget=h->budget;size_t bytes=h->bytes;
        if (s->initializers && s->initializers->pending==h) {
            s->initializers->pending=NULL;s->initializers->blocked=TRUE;
        }
        if (h->webview) ICoreWebView2_Release(h->webview);
        free(h);zwv_initializer_budget_release(budget,bytes);
        InterlockedDecrement(&initializer_handlers);
        release(s); /* may free the manager; the handler still pins the domain */
        zwv_initializer_budget_unref(budget);
    }
    return refs;
}
static void initializer_retire(InitializerHandler *h,uint32_t kind,HRESULT hr) {
    State *s=h->state;
    InitializerState *owner=s->initializers;
    if (owner->pending!=h) return;
    owner->pending=NULL;
    if (kind==3) owner->blocked=TRUE;
    /* Withdraw all mutation responsibility before crossing into Zig. The
       callback can close/reload, so only the independently pinned C state is
       touched after this call. Initial creation has no public transaction. */
    if (h->initial) {
        if (!s->closed && !s->recovering) {
            if (kind==0) { HRESULT start=start_document(s);if (FAILED(start)) notify(s,2,NULL,start); }
            else notify(s,2,NULL,hr);
        }
    } else if (!s->closed && !s->recovering && h->notify) h->notify(s->context,h->token,kind,hr);
}
static HRESULT STDMETHODCALLTYPE initializer_invoke(ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler *p,HRESULT hr,LPCWSTR id) {
    InitializerHandler *h=(InitializerHandler *)p;
    if (h->invoked) return S_OK;
    h->invoked=TRUE;initializer_add(p);
    State *s=h->state;InitializerState *owner=s->initializers;
    BOOL registered=SUCCEEDED(hr);
    if (SUCCEEDED(hr) && (!id || !id[0] || wcsnlen(id,1025)>1024)) hr=E_INVALIDARG;
    if (FAILED(hr)) {
        /* A successful Add with an unusable ID cannot be undone reliably. */
        initializer_retire(h,registered?3u:2u,hr);
    } else if (s->closed || s->recovering || h->cancelled) {
        HRESULT removed=ICoreWebView2_RemoveScriptToExecuteOnDocumentCreated(h->webview,id);
        initializer_retire(h,FAILED(removed)?3u:1u,removed);
    } else {
        size_t id_bytes=(wcslen(id)+1)*sizeof(WCHAR);
        WCHAR *copy=NULL;
        if (!zwv_initializer_budget_reserve(h->budget,id_bytes)) hr=HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA);
        else {
            copy=malloc(id_bytes);
            if (!copy) { zwv_initializer_budget_release(h->budget,id_bytes);hr=E_OUTOFMEMORY; }
            else memcpy(copy,id,id_bytes);
        }
        if (SUCCEEDED(hr) && owner->id) hr=ICoreWebView2_RemoveScriptToExecuteOnDocumentCreated(h->webview,owner->id);
        if (FAILED(hr)) {
            HRESULT removed=ICoreWebView2_RemoveScriptToExecuteOnDocumentCreated(h->webview,id);
            /* An attempted old-ID Remove with a failed result is uncertain
               even if compensating removal of the candidate succeeds. */
            BOOL uncertain=(copy && owner->id) || FAILED(removed);
            if (copy) { free(copy);zwv_initializer_budget_release(h->budget,id_bytes); }
            initializer_retire(h,uncertain?3u:2u,FAILED(removed)?removed:hr);
        } else {
            WCHAR *old=owner->id;size_t old_bytes=owner->id_bytes;
            owner->id=copy;owner->id_bytes=id_bytes;
            free(old);zwv_initializer_budget_release(h->budget,old_bytes);
            initializer_retire(h,0,S_OK);
        }
    }
    initializer_release(p);return S_OK;
}
static ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandlerVtbl initializer_vtable={initializer_query,initializer_add,initializer_release,initializer_invoke};

/* Preparation performs no SDK call and takes no callback context. It owns the
   encoded source and installs the native navigation gate before acceptance. */
HRESULT zwv_initializers_prepare(State *s,const InitializerInput *input,uint64_t token,InitializerNotify done) {
    if (s->closed || s->recovering || !input || !input->budget) return E_ABORT;
    if (s->initializers && (s->initializers->pending || s->initializers->blocked)) return E_PENDING;
    if (token && (!s->webview || s->navigating || s->expected_url || s->expected_refresh || s->expected_history)) return E_PENDING;
    if (input->units>512u*1024u || (!input->source && input->units) || (input->source && input->source[input->units]!=0)) return E_INVALIDARG;
    HRESULT hr=initializers_owner(s,input->budget);if (FAILED(hr)) return hr;
    size_t source_bytes=input->source?((size_t)input->units+1)*sizeof(WCHAR):0;
    size_t bytes=sizeof(InitializerHandler)+source_bytes;
    zwv_initializer_budget_retain(input->budget);
    if (!zwv_initializer_budget_reserve(input->budget,bytes)) {
        zwv_initializer_budget_unref(input->budget);return HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA);
    }
    InitializerHandler *h=calloc(1,bytes);
    if (!h) { zwv_initializer_budget_release(input->budget,bytes);zwv_initializer_budget_unref(input->budget);return E_OUTOFMEMORY; }
    h->iface.lpVtbl=&initializer_vtable;h->refs=1;h->state=s;h->budget=input->budget;h->bytes=bytes;
    h->notify=done;h->token=token;h->initial=token==0;retain(s);
    if (source_bytes) memcpy(h->source,input->source,source_bytes);
    s->initializers->pending=h;InterlockedIncrement(&initializer_handlers);return S_OK;
}
void zwv_initializers_abandon(State *s) {
    InitializerHandler *h=s->initializers?s->initializers->pending:NULL;
    if (!h || h->submitted) return;
    s->initializers->pending=NULL;initializer_release(&h->iface);
}
void zwv_initializers_activate(State *s) {
    InitializerHandler *h=s->initializers?s->initializers->pending:NULL;
    if (!h || h->submitted) return;
    h->submitted=TRUE;
    if (s->closed || !s->webview) { initializer_retire(h,1,E_ABORT);initializer_release(&h->iface);return; }
    h->webview=s->webview;ICoreWebView2_AddRef(h->webview);
    if (h->bytes==sizeof(*h)) {
        /* Clearing commits before its first destructive foreign COM call.
           Reentrant public cancellation must leave completion with this op. */
        h->invoked=TRUE;
        HRESULT hr=S_OK;InitializerState *owner=s->initializers;
        if (owner->id) hr=ICoreWebView2_RemoveScriptToExecuteOnDocumentCreated(h->webview,owner->id);
        if (SUCCEEDED(hr)) {
            WCHAR *old=owner->id;size_t old_bytes=owner->id_bytes;owner->id=NULL;owner->id_bytes=0;
            free(old);zwv_initializer_budget_release(h->budget,old_bytes);
        }
        initializer_retire(h,FAILED(hr)?3u:0u,hr);
    } else {
        HRESULT hr=ICoreWebView2_AddScriptToExecuteOnDocumentCreated(h->webview,h->source,&h->iface);
        if (FAILED(hr) && !h->invoked) { h->invoked=TRUE;initializer_retire(h,2,hr); }
    }
    initializer_release(&h->iface);
}
void zwv_initializers_cancel(State *s,uint64_t token) {
    InitializerHandler *h=s->initializers?s->initializers->pending:NULL;
    if (h && h->token==token) h->cancelled=TRUE;
}
_Bool zwv_initializers_try_cancel(State *s,uint64_t token) {
    InitializerHandler *h=s->initializers?s->initializers->pending:NULL;
    /* Add commits when its completion handler starts processing the result;
       clear commits before Remove. No cancellation can report success after
       the old native ID may have been removed. */
    if (!h || h->token!=token || h->cancelled || h->invoked) return 0;
    h->cancelled=TRUE;return 1;
}
static void initializers_close(State *s) {
    InitializerHandler *h=s->initializers?s->initializers->pending:NULL;
    if (!h) return;
    h->cancelled=TRUE;h->notify=NULL;
    if (!h->submitted) zwv_initializers_abandon(s);
}
static void initializers_fail_before_submit(State *s) {
    InitializerHandler *h=s->initializers?s->initializers->pending:NULL;
    if (h && h->initial && !h->submitted) zwv_initializers_abandon(s);
}
/* The page-facts script is registered before initializers and the first
   document, and stays for the controller's life. */
static HRESULT facts_start(State *s) {
    FactsHandler *handler=FactsHandler_new(s);
    if (!handler) return E_OUTOFMEMORY;
    HRESULT hr=ICoreWebView2_AddScriptToExecuteOnDocumentCreated(s->webview,s->facts_script,&handler->iface);
    FactsHandler_release(&handler->iface);
    return hr;
}
static HRESULT initializers_start(State *s);
static HRESULT STDMETHODCALLTYPE facts_invoke(ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler *p,HRESULT hr,LPCWSTR id) {
    (void)id;State *s=((FactsHandler *)p)->state;retain(s);
    if (!s->closed && !s->facts_added) {
        if (SUCCEEDED(hr)) { s->facts_added=TRUE;hr=initializers_start(s); }
        if (FAILED(hr) && !s->closed) owned_initialization_failed(s,hr);
    }
    release(s);return S_OK;
}
static HRESULT initializers_start(State *s) {
    if (s->facts_script && !s->facts_added) return facts_start(s);
    if (s->initializers && s->initializers->pending) { zwv_initializers_activate(s);return S_OK; }
    return start_document(s);
}
