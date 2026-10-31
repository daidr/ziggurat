/* Included by webview2.c after the handler vtables. Page audio through
   ICoreWebView2_8, and the content rules' hiding script.

   WebView2 may lose an IsMuted put that follows another before IsMutedChanged
   told the first, or apply them out of order, so one put is in flight at a
   time: muted is the state wanted, and IsMutedChanged puts it again when the
   view reports another. A put no event follows (nothing changed) holds the
   next one back for MUTE_PUT_TIMEOUT only. */
#define MUTE_PUT_TIMEOUT 1000
static void mute_put(State *s) {
    s->mute_put=0;
    if (s->closed||!s->webview8) return;
    BOOL current=FALSE;
    if (FAILED(ICoreWebView2_8_get_IsMuted(s->webview8,&current))||(current!=0)!=(s->muted!=0)) s->mute_put=GetTickCount64();
    ICoreWebView2_8_put_IsMuted(s->webview8,s->muted?TRUE:FALSE);
}
static HRESULT STDMETHODCALLTYPE muted_invoke(ICoreWebView2IsMutedChangedEventHandler *p,ICoreWebView2 *sender,IUnknown *args) {
    (void)sender;(void)args;
    State *s=((MutedHandler *)p)->state;retain(s);
    if (!s->closed&&s->webview8) {
        s->mute_put=0;
        BOOL current=FALSE;
        if (FAILED(ICoreWebView2_8_get_IsMuted(s->webview8,&current))||(current!=0)!=(s->muted!=0)) mute_put(s);
    }
    release(s);return S_OK;
}
static HRESULT STDMETHODCALLTYPE audible_invoke(ICoreWebView2IsDocumentPlayingAudioChangedEventHandler *p,ICoreWebView2 *sender,IUnknown *args) {
    (void)sender;(void)args;
    State *s=((AudibleHandler *)p)->state;retain(s);
    BOOL audible=FALSE;
    if (!s->closed&&!s->recovering&&s->webview8&&SUCCEEDED(ICoreWebView2_8_get_IsDocumentPlayingAudio(s->webview8,&audible)))
        page_notify(s,7,s->navigation_id,audible?1u:0u,0,NULL);
    release(s);return S_OK;
}
/* op 0 reads muted, 1 sets it from *value, 2 reads whether the page plays
   audio. Before the view exists the wanted state is kept and reported. */
HRESULT zwv_audio(State *s,int op,int *value) {
    if (s->closed||s->recovering) return E_ABORT;
    BOOL flag=FALSE;HRESULT hr=S_OK;
    switch (op) {
    case 0:
        if (!s->webview) { *value=s->muted?1:0;return S_OK; }
        if (!s->webview8) { *value=0;return S_OK; }
        hr=ICoreWebView2_8_get_IsMuted(s->webview8,&flag);
        *value=SUCCEEDED(hr)&&flag?1:0;return hr;
    case 1:
        s->muted=*value!=0;
        if (s->webview8&&(!s->mute_put||GetTickCount64()-s->mute_put>=MUTE_PUT_TIMEOUT)) mute_put(s);
        return S_OK;
    case 2:
        if (!s->webview8) { *value=0;return S_OK; }
        hr=ICoreWebView2_8_get_IsDocumentPlayingAudio(s->webview8,&flag);
        *value=SUCCEEDED(hr)&&flag?1:0;return hr;
    }
    return E_INVALIDARG;
}

/* The hiding script is added to every document, frames included, apart from
   the ordered document initializers. A script whose Add completes after
   another replaced it is removed again. */
typedef struct StyleHandler {
    ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler iface;
    LONG refs;
    State *state;
    ICoreWebView2 *webview;
    uint64_t serial;
} StyleHandler;
static HRESULT STDMETHODCALLTYPE style_query(ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler *p,REFIID iid,void **out) {
    if (!out) return E_POINTER;*out=NULL;
    if (!IsEqualIID(iid,&IID_IUnknown)&&!IsEqualIID(iid,&IID_ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler)) return E_NOINTERFACE;
    *out=p;InterlockedIncrement(&((StyleHandler *)p)->refs);return S_OK;
}
static ULONG STDMETHODCALLTYPE style_add(ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler *p) {
    return InterlockedIncrement(&((StyleHandler *)p)->refs);
}
static ULONG STDMETHODCALLTYPE style_release(ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler *p) {
    StyleHandler *h=(StyleHandler *)p;LONG refs=InterlockedDecrement(&h->refs);
    if (!refs) {
        ICoreWebView2_Release(h->webview);
        release(h->state);free(h);InterlockedDecrement(&live_handlers);
    }
    return refs;
}
static HRESULT STDMETHODCALLTYPE style_invoke(ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler *p,HRESULT hr,LPCWSTR id) {
    StyleHandler *h=(StyleHandler *)p;State *s=h->state;
    if (FAILED(hr)||!id) return S_OK;
    if (s->closed||h->serial!=s->style_serial||s->webview!=h->webview) {
        ICoreWebView2_RemoveScriptToExecuteOnDocumentCreated(h->webview,id);
        return S_OK;
    }
    WCHAR *copy=_wcsdup(id);
    if (!copy) { ICoreWebView2_RemoveScriptToExecuteOnDocumentCreated(h->webview,id);return S_OK; }
    free(s->style_id);s->style_id=copy;
    return S_OK;
}
static ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandlerVtbl style_vtable={style_query,style_add,style_release,style_invoke};
/* Replaces the added hiding script with content_style, once the view exists. */
static HRESULT style_apply(State *s) {
    if (s->closed||!s->webview) return S_OK;
    s->style_serial++;
    if (s->style_id) {
        WCHAR *old=s->style_id;s->style_id=NULL;
        ICoreWebView2_RemoveScriptToExecuteOnDocumentCreated(s->webview,old);
        free(old);
    }
    if (!s->content_style) return S_OK;
    StyleHandler *h=calloc(1,sizeof(*h));
    if (!h) return E_OUTOFMEMORY;
    h->iface.lpVtbl=&style_vtable;h->refs=1;h->state=s;retain(s);h->serial=s->style_serial;
    h->webview=s->webview;ICoreWebView2_AddRef(h->webview);InterlockedIncrement(&live_handlers);
    HRESULT hr=ICoreWebView2_AddScriptToExecuteOnDocumentCreated(s->webview,s->content_style,&h->iface);
    style_release(&h->iface);
    return hr;
}
/* Replaces the content rules: verdict decides loads from now on, style is
   copied and added to every document from the next one. */
HRESULT zwv_content_rules(State *s,ContentVerdict verdict,const WCHAR *style) {
    if (s->closed||s->recovering) return E_ABORT;
    WCHAR *copy=NULL;
    if (style) { copy=_wcsdup(style);if (!copy) return E_OUTOFMEMORY; }
    free(s->content_style);s->content_style=copy;
    s->content_verdict=verdict;
    return style_apply(s);
}
