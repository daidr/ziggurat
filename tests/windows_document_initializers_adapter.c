/* This isolated test object reuses the fixed-certificate TLS observer and
   compiles the real adapter exactly once. Production never links this file. */
#include "windows_request_credentials_adapter.c"

static HRESULT STDMETHODCALLTYPE initializer_network_record(ICoreWebView2WebResourceRequestedEventHandler *iface,ICoreWebView2 *sender,ICoreWebView2WebResourceRequestedEventArgs *args) {
    ICoreWebView2WebResourceRequest *request=NULL;WCHAR *uri=NULL;
    HRESULT hr=ICoreWebView2WebResourceRequestedEventArgs_get_Request(args,&request);
    if (SUCCEEDED(hr)) hr=request?ICoreWebView2WebResourceRequest_get_Uri(request,&uri):E_POINTER;
    BOOL network=SUCCEEDED(hr)&&uri&&(!_wcsnicmp(uri,L"https://",8)||!_wcsnicmp(uri,L"http://",7));
    CoTaskMemFree(uri);if(request)ICoreWebView2WebResourceRequest_Release(request);
    if (FAILED(hr)) { resource_probe(iface)->overflow=TRUE;return S_OK; }
    /* NavigateToString and blank child documents can have non-network URIs.
       The independent wire comparison concerns actual HTTP(S), with every
       such callback still passed to the original bounded observer. */
    return network?probe_resource_invoke(iface,sender,args):S_OK;
}
static ICoreWebView2WebResourceRequestedEventHandlerVtbl initializer_network_vtable={probe_resource_query,probe_resource_add,probe_resource_release,initializer_network_record};
HRESULT zwv_test_initializer_probe_install(State *s,const WCHAR **origins,uint32_t count,int trust,void **output) {
    if (!output) return E_POINTER;*output=NULL;
    CredentialProbe *probe=NULL;HRESULT hr=zwv_test_credential_probe_install(s,origins,count,trust,&probe);
    if (SUCCEEDED(hr)) { probe->resource.lpVtbl=&initializer_network_vtable;*output=probe; }
    return hr;
}

typedef struct InitializerRetirementObserver {
    InitializerNotify original;
    void *context;
    uint64_t token;
    HANDLE event;
} InitializerRetirementObserver;
static SRWLOCK initializer_observer_lock=SRWLOCK_INIT;
static InitializerRetirementObserver initializer_observer;
static void observed_initializer_retirement(void *context,uint64_t token,uint32_t kind,HRESULT hr) {
    InitializerRetirementObserver taken={0};
    AcquireSRWLockExclusive(&initializer_observer_lock);
    if (initializer_observer.context==context && initializer_observer.token==token) {
        taken=initializer_observer;memset(&initializer_observer,0,sizeof(initializer_observer));
    }
    ReleaseSRWLockExclusive(&initializer_observer_lock);
    /* The production callback gate invokes this function only while State is
       attached. Withdraw before forwarding; the original can close/reload. */
    if (taken.original) taken.original(context,token,kind,hr);
    /* Only independently owned C handles remain after the foreign callback. */
    if (taken.event) { SetEvent(taken.event);CloseHandle(taken.event); }
}
HRESULT zwv_test_initializer_observe_retirement(State *s,uint64_t token,HANDLE borrowed_event) {
    if (s->closed || !s->initializers) return E_ABORT;
    InitializerHandler *pending=s->initializers->pending;
    if (!pending || pending->token!=token || !pending->submitted || pending->invoked || !pending->notify) return E_PENDING;
    HANDLE event=NULL;
    if (!DuplicateHandle(GetCurrentProcess(),borrowed_event,GetCurrentProcess(),&event,0,FALSE,DUPLICATE_SAME_ACCESS)) return HRESULT_FROM_WIN32(GetLastError());
    AcquireSRWLockExclusive(&initializer_observer_lock);
    if (initializer_observer.event) {
        ReleaseSRWLockExclusive(&initializer_observer_lock);CloseHandle(event);return E_PENDING;
    }
    initializer_observer=(InitializerRetirementObserver){pending->notify,s->context,token,event};
    pending->notify=observed_initializer_retirement;
    ReleaseSRWLockExclusive(&initializer_observer_lock);return S_OK;
}
/* Explicit driver cleanup only after App.run/App.deinit have closed every
   native State. It neither dereferences the old context nor restores a handler
   that may already have retired. Late production callbacks fail closed. */
void zwv_test_initializer_observer_clear(void) {
    HANDLE event=NULL;
    AcquireSRWLockExclusive(&initializer_observer_lock);
    event=initializer_observer.event;memset(&initializer_observer,0,sizeof(initializer_observer));
    ReleaseSRWLockExclusive(&initializer_observer_lock);
    if (event) CloseHandle(event);
}
uint32_t zwv_test_initializer_observer_count(void) {
    AcquireSRWLockShared(&initializer_observer_lock);
    uint32_t count=initializer_observer.event?1u:0u;
    ReleaseSRWLockShared(&initializer_observer_lock);return count;
}

/* Hold the real SDK result before the production callback starts processing
   it. The SDK has registered a real candidate ID, while production's native
   pending gate remains set. This proves page-script navigation denial during
   that interval without a production fault hook or a timing-dependent sleep. */
typedef struct HeldInitializer {
    InitializerHandler *handler;
    HANDLE entered;
    WCHAR *id;
    HRESULT result;
    BOOL invoked;
} HeldInitializer;
static HeldInitializer held_initializer;
static HRESULT STDMETHODCALLTYPE held_initializer_invoke(ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler *p,HRESULT hr,LPCWSTR id) {
    InitializerHandler *handler=(InitializerHandler *)p;
    const HRESULT sdk_result=hr;
    WCHAR *copy=NULL;
    if (SUCCEEDED(hr)) {
        size_t length=id?wcsnlen(id,1025):0;
        if (!length || length>1024) hr=E_INVALIDARG;
        else { copy=malloc((length+1)*sizeof(WCHAR));if (!copy) hr=E_OUTOFMEMORY;else memcpy(copy,id,(length+1)*sizeof(WCHAR)); }
    }
    HANDLE entered=NULL;BOOL captured=FALSE;
    AcquireSRWLockExclusive(&initializer_observer_lock);
    if (held_initializer.handler==handler && !held_initializer.invoked && !handler->state->closed && (FAILED(sdk_result)||copy)) {
        held_initializer.invoked=TRUE;held_initializer.result=hr;held_initializer.id=copy;copy=NULL;
        entered=held_initializer.entered;held_initializer.entered=NULL;captured=TRUE;
    }
    ReleaseSRWLockExclusive(&initializer_observer_lock);
    free(copy);
    if (captured) {
        if (entered) { SetEvent(entered);CloseHandle(entered); }
        return S_OK;
    }
    /* Closed/cleared observers never call a test context. The production
       callback receives its original borrowed SDK result while it is valid. */
    return initializer_invoke(p,sdk_result,id);
}
static ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandlerVtbl held_initializer_vtable={initializer_query,initializer_add,initializer_release,held_initializer_invoke};
HRESULT zwv_test_initializer_hold(State *s,uint64_t token,HANDLE borrowed_event) {
    InitializerHandler *handler=s->initializers?s->initializers->pending:NULL;
    if (s->closed || !handler || handler->token!=token || !handler->submitted || handler->invoked) return E_PENDING;
    HANDLE event=NULL;
    if (!DuplicateHandle(GetCurrentProcess(),borrowed_event,GetCurrentProcess(),&event,0,FALSE,DUPLICATE_SAME_ACCESS)) return HRESULT_FROM_WIN32(GetLastError());
    AcquireSRWLockExclusive(&initializer_observer_lock);
    if (held_initializer.handler) { ReleaseSRWLockExclusive(&initializer_observer_lock);CloseHandle(event);return E_PENDING; }
    initializer_add(&handler->iface);
    held_initializer=(HeldInitializer){.handler=handler,.entered=event};
    handler->iface.lpVtbl=&held_initializer_vtable;
    ReleaseSRWLockExclusive(&initializer_observer_lock);return S_OK;
}
_Bool zwv_test_initializer_held_success(void) {
    AcquireSRWLockShared(&initializer_observer_lock);
    BOOL ready=held_initializer.handler && held_initializer.invoked && SUCCEEDED(held_initializer.result) && held_initializer.id;
    ReleaseSRWLockShared(&initializer_observer_lock);return ready!=FALSE;
}
void zwv_test_initializer_resume(void) {
    HeldInitializer taken={0};
    AcquireSRWLockExclusive(&initializer_observer_lock);
    if (held_initializer.invoked) { taken=held_initializer;memset(&held_initializer,0,sizeof(held_initializer)); }
    ReleaseSRWLockExclusive(&initializer_observer_lock);
    if (!taken.handler) return;
    initializer_invoke(&taken.handler->iface,taken.result,taken.id);
    free(taken.id);
    if (taken.entered) CloseHandle(taken.entered);
    initializer_release(&taken.handler->iface);
}
void zwv_test_initializer_hold_clear(void) {
    HeldInitializer taken;
    AcquireSRWLockExclusive(&initializer_observer_lock);
    taken=held_initializer;memset(&held_initializer,0,sizeof(held_initializer));
    if (taken.handler) taken.handler->iface.lpVtbl=&initializer_vtable;
    ReleaseSRWLockExclusive(&initializer_observer_lock);
    /* Explicit driver cleanup occurs after App.deinit: State is closed and
       processing a captured result can only remove its C-owned candidate. */
    if (taken.handler && taken.invoked) initializer_invoke(&taken.handler->iface,taken.result,taken.id);
    free(taken.id);
    if (taken.entered) CloseHandle(taken.entered);
    if (taken.handler) initializer_release(&taken.handler->iface);
}
