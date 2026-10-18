#ifndef ZIGGURAT_RESOURCE_DEFERRALS_H
#define ZIGGURAT_RESOURCE_DEFERRALS_H
static LONG owned_resource_deferrals;
struct DeferredResource {
    State *state;
    DeferredResource *next;
    ICoreWebView2WebResourceRequestedEventArgs *args;
    ICoreWebView2Deferral *deferral;
    uint64_t token;
    BOOL head;
};
static void deferred_release(DeferredResource *pending) {
    ICoreWebView2Deferral_Release(pending->deferral);
    ICoreWebView2WebResourceRequestedEventArgs_Release(pending->args);
    State *s=pending->state;free(pending);InterlockedDecrement(&owned_resource_deferrals);release(s);
}
static DeferredResource *deferred_take(State *s,uint64_t token) {
    DeferredResource **link=&s->resources;
    while (*link) {
        DeferredResource *pending=*link;
        if (pending->token==token) { *link=pending->next;s->resource_count--;return pending; }
        link=&pending->next;
    }
    return NULL;
}
HRESULT zwv_defer_resource(ResourceCall *call,uint64_t token) {
    if (!call||call->responded||call->state->closed||call->state->recovering) return E_ABORT;
    State *s=call->state;
    if (s->resource_count>=8) return E_PENDING;
    DeferredResource *pending=calloc(1,sizeof(*pending)); if (!pending) return E_OUTOFMEMORY;
    HRESULT hr=ICoreWebView2WebResourceRequestedEventArgs_GetDeferral(call->args,&pending->deferral);
    if (SUCCEEDED(hr)&&!pending->deferral) hr=E_POINTER;
    if (SUCCEEDED(hr)) hr=s->denied_response?ICoreWebView2WebResourceRequestedEventArgs_put_Response(call->args,s->denied_response):E_UNEXPECTED;
    if (FAILED(hr)||s->closed||s->recovering) {
        if (pending->deferral) { ICoreWebView2Deferral_Complete(pending->deferral);ICoreWebView2Deferral_Release(pending->deferral); }
        free(pending);return FAILED(hr)?hr:E_ABORT;
    }
    pending->state=s;retain(s);pending->args=call->args;ICoreWebView2WebResourceRequestedEventArgs_AddRef(call->args);
    pending->token=token;pending->head=call->head;
    pending->next=s->resources;s->resources=pending;s->resource_count++;
    InterlockedIncrement(&owned_resource_deferrals);call->responded=TRUE;return S_OK;
}
HRESULT zwv_respond_deferred(State *s,uint64_t token,unsigned status,const char *mime,size_t mime_len,const unsigned char *body,size_t body_len,const ResponseHeader *headers,uint32_t count) {
    DeferredResource *pending=deferred_take(s,token);if (!pending) return E_ABORT;
    ResourceCall call={s,pending->args,FALSE,pending->head};
    HRESULT hr=zwv_respond(&call,status,mime,mime_len,body,body_len,headers,count);
    HRESULT completed=ICoreWebView2Deferral_Complete(pending->deferral);
    deferred_release(pending);
    return FAILED(hr)?hr:completed;
}
void zwv_cancel_resource(State *s,uint64_t token) {
    DeferredResource *pending=deferred_take(s,token);if (!pending) return;
    ICoreWebView2Deferral_Complete(pending->deferral);deferred_release(pending);
}
static void resource_deferrals_close(State *s) {
    while (s->resources) zwv_cancel_resource(s,s->resources->token);
}
uint32_t zwv_resource_pending(void) { return (uint32_t)InterlockedCompareExchange(&owned_resource_deferrals,0,0); }
#endif
