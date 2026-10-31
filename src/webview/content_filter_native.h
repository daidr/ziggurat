/* Included by webview2.c before resource_invoke. WebView2 has no content
   blockers: a page applying content rules has the View match each request
   WebResourceRequested shows (all of them: the view filters "*").

   WebView2 cannot fail a request from WebResourceRequested, and a fetch or an
   XMLHttpRequest takes any response, a 403 too, where a blocked load is a
   network error pages tell apart. A redirect to a data: URL is one, as the
   engine follows none from a subresource load. A page itself gets the empty
   403, as a navigation would follow a redirect. WebSockets go unblocked:
   WebView2 does not show their requests. */
static HRESULT content_respond(State *s,ResourceCall *call,int status,const WCHAR *location) {
    size_t units=wcslen(location)+64;
    WCHAR *headers=malloc(units*sizeof(WCHAR));
    if (!headers) return E_OUTOFMEMORY;
    int used=_snwprintf(headers,units,L"Location: %ls\r\nCache-Control: no-store\r\n",location);
    ICoreWebView2WebResourceResponse *response=NULL;
    HRESULT hr=used<0?E_INVALIDARG:ICoreWebView2Environment_CreateWebResourceResponse(s->environment,NULL,status,L"Temporary Redirect",headers,&response);
    free(headers);
    if (SUCCEEDED(hr)) {
        hr=ICoreWebView2WebResourceRequestedEventArgs_put_Response(call->args,response);
        ICoreWebView2WebResourceResponse_Release(response);
        if (SUCCEEDED(hr)) call->responded=TRUE;
    }
    return hr;
}
/* Applies the rules to a request, and reports whether that answered it. */
static BOOL content_filter(State *s,ICoreWebView2 *sender,ICoreWebView2WebResourceRequestedEventArgs *args,ICoreWebView2WebResourceRequest *request,const WCHAR *uri,ResourceCall *call) {
    if (!s->content_verdict||!uri||!bounded_uri(uri)) return FALSE;
    COREWEBVIEW2_WEB_RESOURCE_CONTEXT context=COREWEBVIEW2_WEB_RESOURCE_CONTEXT_OTHER;
    ICoreWebView2WebResourceRequestedEventArgs_get_ResourceContext(args,&context);
    WCHAR *top=NULL;
    ICoreWebView2_get_Source(sender,&top);
    /* The page being navigated to is the page of its own load. */
    BOOL own_page=!top||!top[0]||wcscmp(top,L"about:blank")==0||
        (context==COREWEBVIEW2_WEB_RESOURCE_CONTEXT_DOCUMENT&&s->navigating&&s->document_source&&remote_url_equal(uri,s->document_source,TRUE));
    uint32_t verdict=s->content_verdict(s->context,uri,own_page?NULL:top,(int)context);
    CoTaskMemFree(top);
    if (s->closed) return TRUE;
    if (verdict&1) {
        if (context==COREWEBVIEW2_WEB_RESOURCE_CONTEXT_DOCUMENT) {
            if (s->denied_response&&SUCCEEDED(ICoreWebView2WebResourceRequestedEventArgs_put_Response(args,s->denied_response))) call->responded=TRUE;
        } else content_respond(s,call,307,L"data:,");
        return TRUE;
    }
    if ((verdict&4)&&_wcsnicmp(uri,L"http:",5)==0) {
        size_t units=wcslen(uri)+2;
        WCHAR *secure=malloc(units*sizeof(WCHAR));
        if (!secure) return TRUE;
        _snwprintf(secure,units,L"https:%ls",uri+5);
        secure[units-1]=0;
        content_respond(s,call,307,secure);
        free(secure);
        return TRUE;
    }
    if (verdict&2) {
        ICoreWebView2HttpRequestHeaders *headers=NULL;
        if (SUCCEEDED(ICoreWebView2WebResourceRequest_get_Headers(request,&headers))&&headers) {
            ICoreWebView2HttpRequestHeaders_RemoveHeader(headers,L"Cookie");
            ICoreWebView2HttpRequestHeaders_Release(headers);
        }
    }
    return FALSE;
}
