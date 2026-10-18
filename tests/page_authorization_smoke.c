/* Test-only translation unit exercises the production navigation callback.
   It links instead of the ordinary adapter, never alongside it. No Runtime,
   browser profile, HWND or production fake/fault hook is required. */
#include <stdlib.h>
#include "file_io_instrumentation.h"
#include "../src/webview/webview2.c"
#undef ReadFile
#undef GetOverlappedResult
#include <stddef.h>
#include "permissions_abi.h"
#include "downloads_abi.h"
#include "../src/webview/bounded_stream.h"

typedef struct ProbeArgs {
    ICoreWebView2NavigationStartingEventArgs iface;
    ICoreWebView2NavigationStartingEventArgs3 extended;
    ULONG refs;
    const WCHAR *uri;
    COREWEBVIEW2_NAVIGATION_KIND kind;
    HRESULT query_result, kind_result;
    BOOL redirected, cancelled;
} ProbeArgs;
static ULONG STDMETHODCALLTYPE probe_add(ICoreWebView2NavigationStartingEventArgs *p) { return ++((ProbeArgs *)p)->refs; }
static ULONG STDMETHODCALLTYPE probe_release(ICoreWebView2NavigationStartingEventArgs *p) { return --((ProbeArgs *)p)->refs; }
static HRESULT STDMETHODCALLTYPE probe_query(ICoreWebView2NavigationStartingEventArgs *p, REFIID iid, void **out) {
    ProbeArgs *args=(ProbeArgs *)p; *out=NULL;
    if (FAILED(args->query_result)) return args->query_result;
    if (!IsEqualIID(iid,&IID_IUnknown) && !IsEqualIID(iid,&IID_ICoreWebView2NavigationStartingEventArgs) && !IsEqualIID(iid,&IID_ICoreWebView2NavigationStartingEventArgs3)) return E_NOINTERFACE;
    *out=IsEqualIID(iid,&IID_ICoreWebView2NavigationStartingEventArgs3)?(void *)&args->extended:(void *)p;
    probe_add(p); return S_OK;
}
static HRESULT STDMETHODCALLTYPE probe_uri(ICoreWebView2NavigationStartingEventArgs *p, LPWSTR *out) {
    const WCHAR *uri=((ProbeArgs *)p)->uri; size_t bytes=(wcslen(uri)+1)*sizeof(WCHAR);
    *out=CoTaskMemAlloc(bytes); if (!*out) return E_OUTOFMEMORY;
    memcpy(*out,uri,bytes); return S_OK;
}
static HRESULT STDMETHODCALLTYPE probe_user(ICoreWebView2NavigationStartingEventArgs *p, BOOL *out) { (void)p; *out=FALSE; return S_OK; }
static HRESULT STDMETHODCALLTYPE probe_redirect(ICoreWebView2NavigationStartingEventArgs *p, BOOL *out) { *out=((ProbeArgs *)p)->redirected; return S_OK; }
static HRESULT STDMETHODCALLTYPE probe_cancel(ICoreWebView2NavigationStartingEventArgs *p, BOOL cancel) { ((ProbeArgs *)p)->cancelled=cancel; return S_OK; }
static HRESULT STDMETHODCALLTYPE probe_id(ICoreWebView2NavigationStartingEventArgs *p, UINT64 *out) { (void)p; *out=42; return S_OK; }
static ProbeArgs *extended_self(ICoreWebView2NavigationStartingEventArgs3 *p) { return (ProbeArgs *)((char *)p - offsetof(ProbeArgs,extended)); }
static HRESULT STDMETHODCALLTYPE extended_query(ICoreWebView2NavigationStartingEventArgs3 *p, REFIID iid, void **out) { return probe_query(&extended_self(p)->iface,iid,out); }
static ULONG STDMETHODCALLTYPE extended_add(ICoreWebView2NavigationStartingEventArgs3 *p) { return probe_add(&extended_self(p)->iface); }
static ULONG STDMETHODCALLTYPE extended_release(ICoreWebView2NavigationStartingEventArgs3 *p) { return probe_release(&extended_self(p)->iface); }
static HRESULT STDMETHODCALLTYPE probe_kind(ICoreWebView2NavigationStartingEventArgs3 *p, COREWEBVIEW2_NAVIGATION_KIND *out) {
    ProbeArgs *args=extended_self(p);
    if (SUCCEEDED(args->kind_result)) *out=args->kind;
    return args->kind_result;
}
static ICoreWebView2NavigationStartingEventArgsVtbl probe_vtable={
    .QueryInterface=probe_query,.AddRef=probe_add,.Release=probe_release,
    .get_Uri=probe_uri,.get_IsUserInitiated=probe_user,.get_IsRedirected=probe_redirect,
    .put_Cancel=probe_cancel,.get_NavigationId=probe_id
};
static ICoreWebView2NavigationStartingEventArgs3Vtbl extended_vtable={.QueryInterface=extended_query,.AddRef=extended_add,.Release=extended_release,.get_NavigationKind=probe_kind};
static int probe_accept(void *context, const PageEvent *event) { (void)context;(void)event;return 1; }

typedef struct Case {
    const char *name;
    int permit; /* 0=none, 1=history, 2=refresh, 3=explicit, 4=local policy. */
    COREWEBVIEW2_NAVIGATION_KIND kind;
    HRESULT query_result, kind_result;
    BOOL redirected, remote, accepted;
} Case;
static int run_case(const Case *test) {
    State *s=calloc(1,sizeof(*s)); if (!s) return 1;
    s->refs=1; InterlockedIncrement(&live_states);
    s->local_prefix=_wcsdup(L"https://app.ziggurat.invalid/");
    s->document_source=_wcsdup(L"https://app.ziggurat.invalid/current");
    if (test->permit==3) s->expected_url=_wcsdup(L"https://app.ziggurat.invalid/current");
    if (!s->local_prefix || !s->document_source || (test->permit==3 && !s->expected_url)) { release(s); return 1; }
    s->expected_history=test->permit==1; s->expected_refresh=test->permit==2;
    s->allow_local_navigation=test->permit==4;
    s->has_document=TRUE; s->navigation_id=41; s->page_notify=probe_accept;
    NavigationHandler handler={0}; handler.state=s;
    ProbeArgs args={0}; args.iface.lpVtbl=&probe_vtable; args.extended.lpVtbl=&extended_vtable; args.refs=1;
    args.uri=test->remote?L"https://remote.invalid/current":L"https://app.ziggurat.invalid/current";
    args.kind=test->kind; args.query_result=test->query_result; args.kind_result=test->kind_result; args.redirected=test->redirected;
    HRESULT hr=navigation_invoke(&handler.iface,NULL,&args.iface);
    int failed=FAILED(hr) || (!args.cancelled)!=test->accepted || args.refs!=1;
    if (failed) fprintf(stderr,"page authorization %s: accepted=%d expected=%d refs=%lu\n",test->name,!args.cancelled,test->accepted,args.refs);
    release(s); return failed;
}

typedef struct UriProbe {
    unsigned pages, messages, reads;
    int kind;
    uint32_t flags;
    size_t value_units;
} UriProbe;
static int uri_page(void *context, const PageEvent *event) {
    UriProbe *probe=context;
    probe->pages++; probe->kind=event->kind; probe->flags=event->flags;
    probe->value_units=event->value?wcslen(event->value):0;
    return 1;
}
static void uri_notify(void *context, int kind, const WCHAR *value, HRESULT hr) {
    (void)value; (void)hr;
    if (kind==1) ((UriProbe *)context)->messages++;
}
static State *uri_state(UriProbe *probe, BOOL html) {
    State *s=calloc(1,sizeof(*s)); if (!s) return NULL;
    s->refs=1; InterlockedIncrement(&live_states);
    if (!html) s->local_prefix=_wcsdup(L"https://app.ziggurat.invalid/");
    s->document_source=_wcsdup(html?L"about:blank":L"https://app.ziggurat.invalid/current");
    if ((!html && !s->local_prefix) || !s->document_source) { release(s); return NULL; }
    s->has_document=TRUE; s->committed=TRUE; s->navigation_id=41;
    s->context=probe; s->page_notify=uri_page; s->notify=uri_notify;
    return s;
}
static WCHAR *long_uri(const WCHAR *prefix, size_t units) {
    size_t prefix_units=wcslen(prefix);
    if (prefix_units>units) return NULL;
    WCHAR *uri=malloc((units+1)*sizeof(*uri)); if (!uri) return NULL;
    memcpy(uri,prefix,prefix_units*sizeof(*uri));
    for (size_t i=prefix_units;i<units;i++) uri[i]=L'a';
    uri[units]=0; return uri;
}
static int uri_navigation(size_t units, BOOL html, BOOL refresh, BOOL accepted) {
    UriProbe probe={0}; State *s=uri_state(&probe,html); if (!s) return 1;
    WCHAR *uri=long_uri(html?L"data:text/html; charset=utf-8,":L"https://app.ziggurat.invalid/",units);
    if (!uri) { release(s); return 1; }
    s->allow_local_navigation=!html; s->initial_navigation=html && !refresh;
    s->expected_refresh=refresh;
    NavigationHandler handler={0}; handler.state=s;
    ProbeArgs args={0}; args.iface.lpVtbl=&probe_vtable; args.extended.lpVtbl=&extended_vtable; args.refs=1;
    args.uri=uri; args.kind=refresh?COREWEBVIEW2_NAVIGATION_KIND_RELOAD:COREWEBVIEW2_NAVIGATION_KIND_NEW_DOCUMENT;
    args.query_result=S_OK; args.kind_result=S_OK;
    HRESULT hr=navigation_invoke(&handler.iface,NULL,&args.iface);
    BOOL source_correct=accepted?(html?wcscmp(s->document_source,L"about:blank")==0:wcscmp(s->document_source,uri)==0):wcscmp(s->document_source,L"https://app.ziggurat.invalid/current")==0;
    int failed=FAILED(hr) || (!args.cancelled)!=accepted || args.refs!=1 || !source_correct || probe.pages!=(accepted?1u:0u);
    if (accepted && (probe.kind!=0 || probe.value_units!=units || s->committed)) failed=1;
    if (failed) fprintf(stderr,"page URI navigation units=%zu html=%d refresh=%d accepted=%d expected=%d source=%d\n",units,html,refresh,!args.cancelled,accepted,source_correct);
    free(uri); release(s); return failed;
}
typedef struct ProbeSender { ICoreWebView2 iface; const WCHAR *source; } ProbeSender;
static HRESULT copy_uri(const WCHAR *uri, LPWSTR *out) {
    size_t bytes=(wcslen(uri)+1)*sizeof(WCHAR);
    *out=CoTaskMemAlloc(bytes); if (!*out) return E_OUTOFMEMORY;
    memcpy(*out,uri,bytes); return S_OK;
}
static HRESULT STDMETHODCALLTYPE sender_source(ICoreWebView2 *p, LPWSTR *out) { return copy_uri(((ProbeSender *)p)->source,out); }
static ICoreWebView2Vtbl sender_vtable={.get_Source=sender_source};
static int uri_source(size_t units, BOOL remote, BOOL trusted) {
    UriProbe probe={0}; State *s=uri_state(&probe,FALSE); if (!s) return 1;
    WCHAR *uri=long_uri(remote?L"https://remote.invalid/":L"https://app.ziggurat.invalid/",units);
    if (!uri) { release(s); return 1; }
    ProbeSender sender={{&sender_vtable},uri}; SourceHandler handler={0}; handler.state=s;
    HRESULT hr=source_invoke(&handler.iface,&sender.iface,NULL);
    BOOL source_correct=trusted?(s->document_source && wcscmp(s->document_source,uri)==0):s->document_source==NULL;
    int failed=FAILED(hr) || !source_correct || s->committed!=trusted || probe.pages!=1 || probe.kind!=3 || probe.flags!=(trusted?1u:0u) || probe.value_units!=units;
    if (failed) fprintf(stderr,"page URI source units=%zu remote=%d trusted=%d source=%d committed=%d\n",units,remote,trusted,source_correct,s->committed);
    free(uri); release(s); return failed;
}
typedef struct ProbeMessage {
    ICoreWebView2WebMessageReceivedEventArgs iface;
    const WCHAR *source;
    UriProbe *probe;
} ProbeMessage;
static HRESULT STDMETHODCALLTYPE message_source(ICoreWebView2WebMessageReceivedEventArgs *p, LPWSTR *out) { return copy_uri(((ProbeMessage *)p)->source,out); }
static HRESULT STDMETHODCALLTYPE message_text(ICoreWebView2WebMessageReceivedEventArgs *p, LPWSTR *out) {
    ((ProbeMessage *)p)->probe->reads++; return copy_uri(L"bounded message",out);
}
static ICoreWebView2WebMessageReceivedEventArgsVtbl message_vtable={.get_Source=message_source,.TryGetWebMessageAsString=message_text};
static int uri_message(size_t source_units, size_t current_units, BOOL accepted) {
    UriProbe probe={0}; State *s=uri_state(&probe,FALSE); if (!s) return 1;
    WCHAR *source=long_uri(L"https://app.ziggurat.invalid/",source_units);
    WCHAR *current=long_uri(L"https://app.ziggurat.invalid/",current_units);
    WCHAR *document=long_uri(L"https://app.ziggurat.invalid/",16384);
    if (!source || !current || !document) { free(source); free(current); free(document); release(s); return 1; }
    free(s->document_source); s->document_source=document;
    ProbeSender sender={{&sender_vtable},current}; ProbeMessage args={{&message_vtable},source,&probe};
    MessageHandler handler={0}; handler.state=s;
    HRESULT hr=message_invoke(&handler.iface,&sender.iface,&args.iface);
    int failed=FAILED(hr) || probe.reads!=(accepted?1u:0u) || probe.messages!=(accepted?1u:0u);
    if (failed) fprintf(stderr,"page URI message source=%zu current=%zu reads=%u messages=%u expected=%d\n",source_units,current_units,probe.reads,probe.messages,accepted);
    free(source); free(current); release(s); return failed;
}
static int remote_policy_cases(void) {
    const struct { const WCHAR *text; BOOL only,loopback,accepted; } cases[]={
        {L"https://Example.COM",TRUE,FALSE,TRUE},
        {L"https://example.com:443/",TRUE,FALSE,TRUE},
        {L"https://example.com:8443/a?q=1#f",FALSE,FALSE,TRUE},
        {L"https://example.com/a",TRUE,FALSE,FALSE},
        {L"https://example.com/?q=1",TRUE,FALSE,FALSE},
        {L"https://example.com/#f",TRUE,FALSE,FALSE},
        {L"https://u:p@example.com/",FALSE,FALSE,FALSE},
        {L"https://@example.com/",FALSE,FALSE,FALSE},
        {L"https://example.com.evil.invalid/",FALSE,FALSE,TRUE},
        {L"https://example.com:0/",FALSE,FALSE,FALSE},
        {L"https://example.com:65536/",FALSE,FALSE,FALSE},
        {L"https://example.com\\@evil.invalid/",FALSE,FALSE,FALSE},
        {L"https://example.com\r\n/",FALSE,FALSE,FALSE},
        {L"https://example.com./",FALSE,FALSE,FALSE},
        {L"https://%65xample.com/",FALSE,FALSE,FALSE},
        {L"http://example.com/",FALSE,TRUE,FALSE},
        {L"http://127.0.0.1:8000/",FALSE,FALSE,FALSE},
        {L"http://127.0.0.1:8000/",FALSE,TRUE,TRUE},
        {L"http://2130706433:8000/",FALSE,TRUE,FALSE},
        {L"http://127.1:8000/",FALSE,TRUE,FALSE},
        {L"http://0x7f000001:8000/",FALSE,TRUE,FALSE},
        {L"http://127.000.0.1:8000/",FALSE,TRUE,FALSE},
        {L"https://127.0.0.1/",FALSE,FALSE,FALSE},
        {L"http://[::1]:8000/",FALSE,TRUE,TRUE},
        {L"http://localhost:8000/",FALSE,TRUE,TRUE},
        {L"http://dev.localhost:8000/",FALSE,TRUE,TRUE},
        {L"https://app.ziggurat.invalid/",FALSE,TRUE,FALSE},
        {L"file:///C:/private.html",FALSE,TRUE,FALSE},
        {L"data:text/html,private",FALSE,TRUE,FALSE},
        {L"blob:https://example.com/id",FALSE,TRUE,FALSE}
    };
    int failed=0;
    for (size_t i=0;i<sizeof(cases)/sizeof(cases[0]);i++) {
        NetOrigin origin;
        HRESULT hr=net_origin(cases[i].text,cases[i].only,cases[i].loopback,&origin);
        if (SUCCEEDED(hr)!=cases[i].accepted) { fprintf(stderr,"remote URI parse case %zu hr=%lx\n",i,(unsigned long)hr); failed++; }
    }
    RemoteOriginInput input[]={ {L"https://example.com",REMOTE_NAVIGATE|REMOTE_REQUESTS,3}, {L"https://cdn.example.com:8443",REMOTE_REQUESTS,3} };
    RemoteInput config={L"https://example.com/start",input,2,FALSE,FALSE,FALSE,NULL,0};
    RemotePolicy policy;
    if (FAILED(remote_init(&policy,&config))) return failed+1;
    if (remote_grants(&policy,L"HTTPS://EXAMPLE.COM:443/next")!=3 || remote_grants(&policy,L"https://example.com:444/next") ||
        remote_grants(&policy,L"https://example.com.evil.invalid/next") || remote_grants(&policy,L"https://cdn.example.com:8443/app.js")!=REMOTE_REQUESTS ||
        remote_grants(&policy,L"http://example.com/")) failed++;
    remote_deinit(&policy);
    RemoteOriginInput duplicate[]={ {L"https://example.com",3,3}, {L"https://EXAMPLE.COM:443/",3,3} };
    config.origins=duplicate;
    if (SUCCEEDED(remote_init(&policy,&config))) failed++;
    input[0].flags=REMOTE_IPC; config.origins=input;
    if (SUCCEEDED(remote_init(&policy,&config))) failed++;
    return failed;
}
static int request_policy_cases(void) {
    HeaderGrantInput headers[]={ {"Content-Type",12,"text/plain",10,TRUE}, {"Authorization",13,"Bearer private",14,TRUE}, {"Unusual",7,NULL,0,FALSE} };
    RemoteOriginInput origins[]={ {L"https://example.com",3,3u|(1u<<2)|(1u<<6),headers,3}, {L"https://other.example",2,3,NULL,0} };
    RemoteInput input={L"https://example.com/start",origins,2,FALSE,FALSE,FALSE,NULL,0};RemotePolicy policy;
    if (FAILED(remote_init(&policy,&input))) return 1;
    NativeHeader allowed[]={ {L"Accept",L"*/*"},{L"Content-Type",L"text/plain"},{L"aUtHoRiZaTiOn",L"Bearer private"},{L"uNuSuAl",L"explicit any value"} };
    int failed=0;
    if (!remote_request_allowed(&policy,L"https://example.com/resource",2,allowed,4)) failed++;
    if (remote_request_allowed(&policy,L"https://other.example/resource",2,NULL,0)) failed++;
    if (!remote_request_allowed(&policy,L"https://example.com/resource",6,NULL,0)) failed++;
    if (remote_request_allowed(&policy,L"https://example.com/resource",3,NULL,0)) failed++;
    allowed[2].value=L"Bearer PRIVATE";
    if (remote_request_allowed(&policy,L"https://example.com/resource",2,allowed,4)) failed++;
    allowed[2].value=L"Bearer private";allowed[3].name=L"Not-X-Unknown";
    if (remote_request_allowed(&policy,L"https://example.com/resource",2,allowed,4)) failed++;
    allowed[3].name=L"Range";
    if (remote_request_allowed(&policy,L"https://example.com/resource",0,allowed,4)) failed++;
    remote_deinit(&policy);
    if (failed) fprintf(stderr,"request method/header grant ABI failures=%d\n",failed);
    return failed;
}
static int remote_navigation_case(BOOL script,BOOL redirects,BOOL redirected,int permit,const WCHAR *target,BOOL accepted) {
    UriProbe probe={0}; State *s=uri_state(&probe,TRUE); if (!s) return 1;
    RemoteOriginInput input[]={ {L"https://remote.example",3,3}, {L"https://other.example",3,3} };
    RemoteInput config={L"https://remote.example/start",input,2,FALSE,script,redirects,NULL,0};
    if (FAILED(remote_init(&s->remote,&config))) { release(s); return 1; }
    s->initial_url=_wcsdup(config.url);
    if (permit==1) s->initial_navigation=TRUE;
    if (permit==2) s->expected_url=_wcsdup(target);
    if (permit==3) s->expected_history=TRUE;
    if (redirected && permit==2) { free(s->expected_url); s->expected_url=NULL; s->navigating=TRUE; s->navigation_id=42; }
    ProbeArgs args={0}; args.iface.lpVtbl=&probe_vtable; args.extended.lpVtbl=&extended_vtable; args.refs=1;
    args.uri=target; args.kind=permit==3?COREWEBVIEW2_NAVIGATION_KIND_BACK_OR_FORWARD:COREWEBVIEW2_NAVIGATION_KIND_NEW_DOCUMENT;
    args.query_result=S_OK; args.kind_result=S_OK; args.redirected=redirected;
    NavigationHandler handler={0}; handler.state=s;
    HRESULT hr=navigation_invoke(&handler.iface,NULL,&args.iface);
    int failed=FAILED(hr)||(!args.cancelled)!=accepted||args.refs!=1||probe.pages!=(accepted?1u:0u);
    if (failed) fprintf(stderr,"remote navigation script=%d redirects=%d redirected=%d permit=%d accepted=%d expected=%d\n",script,redirects,redirected,permit,!args.cancelled,accepted);
    release(s); return failed;
}
static HRESULT STDMETHODCALLTYPE sender_post(ICoreWebView2 *p,LPCWSTR message) { (void)p;(void)message;return S_OK; }
static int remote_ipc_case(BOOL trusted,BOOL committed,BOOL closed) {
    UriProbe probe={0}; State *s=uri_state(&probe,TRUE); if (!s) return 1;
    RemoteOriginInput input[]={ {L"https://trusted.example",7,3}, {L"https://untrusted.example",3,3} };
    RemoteInput config={L"https://trusted.example/start",input,2,FALSE,FALSE,FALSE,NULL,0};
    if (FAILED(remote_init(&s->remote,&config))) { release(s); return 1; }
    const WCHAR *uri=trusted?L"https://trusted.example/start":L"https://untrusted.example/start";
    s->initial_url=_wcsdup(config.url);
    free(s->document_source); s->document_source=_wcsdup(uri);
    if (!s->initial_url || !s->document_source) { release(s); return 1; }
    s->closed=closed; s->committed=committed;
    ICoreWebView2Vtbl vtable={.get_Source=sender_source,.PostWebMessageAsString=sender_post};
    ProbeSender sender={{&vtable},uri}; ProbeMessage args={{&message_vtable},uri,&probe};
    MessageHandler handler={0}; handler.state=s; s->webview=&sender.iface;
    BOOL expected=trusted && committed && !closed;
    HRESULT hr=message_invoke(&handler.iface,&sender.iface,&args.iface);
    HRESULT post=zwv_post(s,L"private reply");
    int failed=FAILED(hr) || probe.reads!=(expected?1u:0u) || probe.messages!=(expected?1u:0u) || SUCCEEDED(post)!=expected;
    if (failed) fprintf(stderr,"remote IPC trusted=%d committed=%d closed=%d received=%u post=%lx\n",trusted,committed,closed,probe.messages,(unsigned long)post);
    s->webview=NULL; release(s); return failed;
}
typedef struct ScriptProbeSender {
    ICoreWebView2 iface;
    HRESULT result;
    ICoreWebView2ExecuteScriptCompletedHandler *completion;
} ScriptProbeSender;
static HRESULT STDMETHODCALLTYPE probe_execute(ICoreWebView2 *p,LPCWSTR script,ICoreWebView2ExecuteScriptCompletedHandler *completion) {
    (void)script; ScriptProbeSender *sender=(ScriptProbeSender *)p;
    if (SUCCEEDED(sender->result)) { sender->completion=completion; ICoreWebView2ExecuteScriptCompletedHandler_AddRef(completion); }
    return sender->result;
}
static void probe_script_notify(void *context,uint64_t token,HRESULT hr,const WCHAR *json) {
    (void)token;(void)hr;(void)json; ((UriProbe *)context)->messages++;
}
static int script_abi_cases(void) {
    UriProbe probe={0}; State *s=uri_state(&probe,TRUE); if (!s) return 1;
    ICoreWebView2Vtbl vtable={.ExecuteScript=probe_execute};
    ScriptProbeSender sender={{&vtable},E_FAIL,NULL};
    s->webview=&sender.iface; s->script_limit=1; s->script_notify=probe_script_notify;
    int failed=0;
    if (zwv_evaluate(s,L"42",1)!=E_FAIL || s->script_count || s->scripts || live_handlers || probe.messages) failed++;
    sender.result=S_OK;
    if (FAILED(zwv_evaluate(s,L"42",2)) || s->script_count!=1 || !sender.completion) failed++;
    if (zwv_evaluate(s,L"43",3)!=E_PENDING) failed++;
    zwv_evaluate_cancel(s,2);
    if (s->script_count!=1 || zwv_evaluate(s,L"43",3)!=E_PENDING) failed++;
    ICoreWebView2ExecuteScriptCompletedHandler_Invoke(sender.completion,S_OK,L"42");
    ICoreWebView2ExecuteScriptCompletedHandler_Invoke(sender.completion,S_OK,L"42");
    if (s->script_count || s->scripts || probe.messages) failed++;
    ICoreWebView2ExecuteScriptCompletedHandler_Release(sender.completion); sender.completion=NULL;
    if (FAILED(zwv_evaluate(s,L"43",4))) failed++;
    ICoreWebView2ExecuteScriptCompletedHandler_Invoke(sender.completion,S_OK,L"43");
    ICoreWebView2ExecuteScriptCompletedHandler_Invoke(sender.completion,S_OK,L"43");
    if (s->script_count || s->scripts || probe.messages!=1) failed++;
    ICoreWebView2ExecuteScriptCompletedHandler_Release(sender.completion); sender.completion=NULL;
    if (FAILED(zwv_evaluate(s,L"44",5))) failed++;
    s->closed=TRUE;
    ICoreWebView2ExecuteScriptCompletedHandler_Invoke(sender.completion,S_OK,L"44");
    if (probe.messages!=1 || s->script_count) failed++;
    ICoreWebView2ExecuteScriptCompletedHandler_Release(sender.completion);
    s->webview=NULL; release(s);
    if (failed) fprintf(stderr,"script native ABI failure/hold/cancel/duplicate/close checks failed=%d\n",failed);
    return failed;
}
static int bounded_stream_cases(void) {
    BoundedStream *stream=bounded_stream_new(16); if (!stream) return 1;
    int failed=0; ULONG actual=99; LARGE_INTEGER offset={0}; ULARGE_INTEGER position={0},size={0};
    void *queried=NULL;
    if (FAILED(IStream_QueryInterface(&stream->iface,&IID_IStream,&queried)) || queried!=&stream->iface) failed++;
    if (queried) IStream_Release((IStream *)queried);
    if (FAILED(IStream_Write(&stream->iface,"test",4,&actual)) || actual!=4) failed++;
    offset.QuadPart=8;
    if (FAILED(IStream_Seek(&stream->iface,offset,STREAM_SEEK_SET,&position)) || position.QuadPart!=8) failed++;
    if (FAILED(IStream_Write(&stream->iface,"x",1,&actual))) failed++;
    offset.QuadPart=0; IStream_Seek(&stream->iface,offset,STREAM_SEEK_SET,NULL);
    unsigned char bytes[16]; memset(bytes,0xff,sizeof(bytes));
    if (IStream_Read(&stream->iface,bytes,16,&actual)!=S_FALSE || actual!=9 || memcmp(bytes,"test\0\0\0\0x",9)!=0) failed++;
    offset.QuadPart=INT64_MIN; position.QuadPart=123;
    if (SUCCEEDED(IStream_Seek(&stream->iface,offset,STREAM_SEEK_CUR,&position)) || position.QuadPart!=123) failed++;
    size.QuadPart=12;
    if (FAILED(IStream_SetSize(&stream->iface,size)) || stream->length!=12 || stream->bytes[9] || stream->bytes[10] || stream->bytes[11]) failed++;
    if (FAILED(bounded_stream_seal(stream)) || IStream_Write(&stream->iface,"x",1,&actual)!=STG_E_ACCESSDENIED || actual!=0) failed++;
    IStream_Release(&stream->iface);
    stream=bounded_stream_new(4); if (!stream) return failed+1;
    if (IStream_Write(&stream->iface,"oversize",8,&actual)!=STG_E_MEDIUMFULL || actual!=0 || stream->length || bounded_stream_seal(stream)!=STG_E_MEDIUMFULL) failed++;
    IStream_Release(&stream->iface);
    if (owned_tool_streams) failed++;
    if (failed) fprintf(stderr,"bounded stream ABI failures=%d\n",failed);
    return failed;
}
typedef struct ToolProbe { State *state; unsigned calls,failures; } ToolProbe;
static void probe_tool_notify(void *context,uint64_t token,uint32_t kind,HRESULT hr,const void *data,uint32_t count) {
    (void)token;(void)kind;(void)hr;(void)data;(void)count;
    ToolProbe *probe=context; probe->calls++;
    if (probe->state->tool_count || probe->state->tools || owned_tool_pending) probe->failures++;
}
static int tool_abi_cases(void) {
    UriProbe uri={0}; State *s=uri_state(&uri,TRUE); if (!s) return 1;
    ToolProbe probe={.state=s}; s->context=&probe; s->tool_notify=probe_tool_notify;
    int failed=0;
    ToolOperation *op=tool_new(s,&tool_clear_vtable,1,1);
    if (!op) { release(s);return 1; }
    tool_release(op);
    if (s->tool_count || s->tools || owned_tool_pending || live_handlers || probe.calls) failed++;
    op=tool_new(s,&tool_clear_vtable,1,2);
    if (!op) { release(s);return failed+1; }
    zwv_tool_cancel(s,2);
    if (s->tool_count!=1 || !owned_tool_pending) failed++;
    tool_clear_invoke((ICoreWebView2ClearBrowsingDataCompletedHandler *)op,S_OK);
    tool_clear_invoke((ICoreWebView2ClearBrowsingDataCompletedHandler *)op,S_OK);
    if (s->tool_count || s->tools || owned_tool_pending || probe.calls) failed++;
    tool_release(op);
    op=tool_new(s,&tool_clear_vtable,1,3);
    if (!op) { release(s);return failed+1; }
    tool_clear_invoke((ICoreWebView2ClearBrowsingDataCompletedHandler *)op,S_OK);
    tool_clear_invoke((ICoreWebView2ClearBrowsingDataCompletedHandler *)op,S_OK);
    if (probe.calls!=1 || probe.failures) failed++;
    tool_release(op);
    op=tool_new(s,&tool_clear_vtable,1,4);
    if (!op) { release(s);return failed+1; }
    s->closed=TRUE;
    tool_clear_invoke((ICoreWebView2ClearBrowsingDataCompletedHandler *)op,S_OK);
    tool_release(op);
    if (probe.calls!=1 || live_handlers || owned_tool_pending) failed++;
    release(s);
    if (failed) fprintf(stderr,"tool native ABI cancel/unlink/duplicate/close failures=%d\n",failed);
    return failed;
}
typedef struct RequestProbeResponse { ICoreWebView2WebResourceResponse iface; LONG refs; } RequestProbeResponse;
typedef struct RequestProbeDeferral { ICoreWebView2Deferral iface; LONG refs; unsigned completed; } RequestProbeDeferral;
typedef struct RequestProbeArgs {
    ICoreWebView2WebResourceRequestedEventArgs iface;
    LONG refs;
    RequestProbeDeferral deferral;
    ICoreWebView2WebResourceResponse *response;
    HRESULT defer_hr,put_hr;
} RequestProbeArgs;
typedef struct RequestProbeEnvironment {
    ICoreWebView2Environment iface;
    RequestProbeResponse response;
    HRESULT result;
    WCHAR headers[8704];
    unsigned status;
    uint64_t body_size;
} RequestProbeEnvironment;
#define REQUEST_PROBE_REFS(Name,Interface,Type) \
    static HRESULT STDMETHODCALLTYPE Name##_query(Interface *p,REFIID iid,void **out) { (void)iid;if (!out)return E_POINTER;*out=p;InterlockedIncrement(&((Type *)p)->refs);return S_OK; } \
    static ULONG STDMETHODCALLTYPE Name##_add(Interface *p) { return InterlockedIncrement(&((Type *)p)->refs); } \
    static ULONG STDMETHODCALLTYPE Name##_release(Interface *p) { return InterlockedDecrement(&((Type *)p)->refs); }
REQUEST_PROBE_REFS(request_response,ICoreWebView2WebResourceResponse,RequestProbeResponse)
REQUEST_PROBE_REFS(request_deferral,ICoreWebView2Deferral,RequestProbeDeferral)
REQUEST_PROBE_REFS(request_args,ICoreWebView2WebResourceRequestedEventArgs,RequestProbeArgs)
static HRESULT STDMETHODCALLTYPE request_complete(ICoreWebView2Deferral *p) { ((RequestProbeDeferral *)p)->completed++;return S_OK; }
static HRESULT STDMETHODCALLTYPE request_get_deferral(ICoreWebView2WebResourceRequestedEventArgs *p,ICoreWebView2Deferral **out) {
    RequestProbeArgs *args=(RequestProbeArgs *)p;*out=NULL;
    if (FAILED(args->defer_hr)) return args->defer_hr;
    *out=&args->deferral.iface;ICoreWebView2Deferral_AddRef(*out);return S_OK;
}
static HRESULT STDMETHODCALLTYPE request_put_response(ICoreWebView2WebResourceRequestedEventArgs *p,ICoreWebView2WebResourceResponse *response) {
    RequestProbeArgs *args=(RequestProbeArgs *)p;
    if (FAILED(args->put_hr)) return args->put_hr;
    if (args->response) ICoreWebView2WebResourceResponse_Release(args->response);
    args->response=response;if (response) ICoreWebView2WebResourceResponse_AddRef(response);return S_OK;
}
static HRESULT STDMETHODCALLTYPE request_create_response(ICoreWebView2Environment *p,IStream *content,int status,LPCWSTR reason,LPCWSTR headers,ICoreWebView2WebResourceResponse **out) {
    (void)reason;RequestProbeEnvironment *environment=(RequestProbeEnvironment *)p;*out=NULL;
    if (FAILED(environment->result)) return environment->result;
    wcscpy(environment->headers,headers);environment->status=(unsigned)status;
    STATSTG stat={0};if (content) IStream_Stat(content,&stat,STATFLAG_NONAME);environment->body_size=stat.cbSize.QuadPart;
    *out=&environment->response.iface;ICoreWebView2WebResourceResponse_AddRef(*out);return S_OK;
}
static ICoreWebView2WebResourceResponseVtbl request_response_vtable={.QueryInterface=request_response_query,.AddRef=request_response_add,.Release=request_response_release};
static ICoreWebView2DeferralVtbl request_deferral_vtable={.QueryInterface=request_deferral_query,.AddRef=request_deferral_add,.Release=request_deferral_release,.Complete=request_complete};
static ICoreWebView2WebResourceRequestedEventArgsVtbl request_args_vtable={.QueryInterface=request_args_query,.AddRef=request_args_add,.Release=request_args_release,.put_Response=request_put_response,.GetDeferral=request_get_deferral};
static ICoreWebView2EnvironmentVtbl request_environment_vtable={.CreateWebResourceResponse=request_create_response};
static void request_args_init(RequestProbeArgs *args) {
    memset(args,0,sizeof(*args));args->iface.lpVtbl=&request_args_vtable;args->refs=1;args->deferral.iface.lpVtbl=&request_deferral_vtable;args->deferral.refs=1;
}
static void request_args_clear(RequestProbeArgs *args) { if (args->response) { ICoreWebView2WebResourceResponse_Release(args->response);args->response=NULL; } }
static int resource_abi_cases(void) {
    UriProbe probe={0};State *s=uri_state(&probe,TRUE);if (!s) return 1;
    RequestProbeResponse denied={{&request_response_vtable},1};
    RequestProbeEnvironment environment={0};environment.iface.lpVtbl=&request_environment_vtable;environment.response.iface.lpVtbl=&request_response_vtable;environment.response.refs=1;
    s->denied_response=&denied.iface;s->environment=&environment.iface;
    RequestProbeArgs args;request_args_init(&args);ResourceCall call={s,&args.iface,FALSE,FALSE};int failed=0;
    args.defer_hr=E_FAIL;
    if (zwv_defer_resource(&call,1)!=E_FAIL||args.refs!=1||args.deferral.completed||owned_resource_deferrals) failed++;
    args.defer_hr=S_OK;args.put_hr=E_FAIL;
    if (zwv_defer_resource(&call,2)!=E_FAIL||args.deferral.refs!=1||args.deferral.completed!=1||owned_resource_deferrals) failed++;
    request_args_init(&args);call.responded=FALSE;
    if (FAILED(zwv_defer_resource(&call,3))||!call.responded||args.refs!=2||args.deferral.refs!=2||args.response!=&denied.iface||owned_resource_deferrals!=1) failed++;
    environment.result=E_OUTOFMEMORY;
    if (zwv_respond_deferred(s,3,200,"text/plain",10,(const unsigned char *)"body",4,NULL,0)!=E_OUTOFMEMORY||args.deferral.completed!=1||args.refs!=1||args.deferral.refs!=1||args.response!=&denied.iface||owned_resource_deferrals) failed++;
    zwv_cancel_resource(s,3);
    if (args.deferral.completed!=1) failed++;
    request_args_clear(&args);request_args_init(&args);call.responded=FALSE;call.head=TRUE;environment.result=S_OK;
    if (FAILED(zwv_respond(&call,200,"text/plain",10,(const unsigned char *)"representation",14,NULL,0))||environment.body_size||!wcsstr(environment.headers,L"Content-Length: 14\r\n")) failed++;
    call.responded=FALSE;call.head=FALSE;
    if (FAILED(zwv_respond(&call,204,"text/plain",10,NULL,0,NULL,0))||wcsstr(environment.headers,L"Content-Length:")) failed++;
    call.responded=FALSE;
    if (FAILED(zwv_respond(&call,304,"text/plain",10,NULL,0,NULL,0))||wcsstr(environment.headers,L"Content-Length:")) failed++;
    ResponseHeader reserved={"Content-Length",14,"999",3};call.responded=FALSE;
    if (zwv_respond(&call,200,"text/plain",10,NULL,0,&reserved,1)!=E_INVALIDARG||call.responded) failed++;
    if (zwv_respond(&call,200,"text/plain",10,(const unsigned char *)"not-read",16u*1024u*1024u+1,NULL,0)!=E_INVALIDARG||call.responded) failed++;
    request_args_clear(&args);
    RequestProbeArgs pending[9];
    for (unsigned i=0;i<9;i++) request_args_init(&pending[i]);
    for (unsigned i=0;i<8;i++) {
        ResourceCall next={s,&pending[i].iface,FALSE,FALSE};
        if (FAILED(zwv_defer_resource(&next,10+i))) failed++;
    }
    ResourceCall full={s,&pending[8].iface,FALSE,FALSE};
    if (zwv_defer_resource(&full,18)!=E_PENDING||pending[8].deferral.completed||pending[8].refs!=1) failed++;
    s->closed=TRUE;resource_deferrals_close(s);
    for (unsigned i=0;i<9;i++) {
        if (pending[i].refs!=1||pending[i].deferral.refs!=1||pending[i].deferral.completed!=(i<8?1u:0u)) failed++;
        request_args_clear(&pending[i]);
    }
    if (s->resources||s->resource_count||owned_resource_deferrals||s->refs!=1||denied.refs!=1||environment.response.refs!=1) failed++;
    s->denied_response=NULL;s->environment=NULL;release(s);
    if (failed) fprintf(stderr,"resource deferral failure/OOM/header/Complete/close ABI failures=%d\n",failed);
    return failed;
}
#include "file_response_abi.h"
#include "schemes_abi.h"
#include "viewport_abi.h"
int zpa_run(void) {
    const COREWEBVIEW2_NAVIGATION_KIND doc=COREWEBVIEW2_NAVIGATION_KIND_NEW_DOCUMENT;
    const COREWEBVIEW2_NAVIGATION_KIND reload=COREWEBVIEW2_NAVIGATION_KIND_RELOAD;
    const COREWEBVIEW2_NAVIGATION_KIND history=COREWEBVIEW2_NAVIGATION_KIND_BACK_OR_FORWARD;
    const Case cases[]={
        {"default document",0,doc,S_OK,S_OK,FALSE,FALSE,FALSE},
        {"history document",1,doc,S_OK,S_OK,FALSE,FALSE,FALSE},
        {"history backward",1,history,S_OK,S_OK,FALSE,FALSE,TRUE},
        {"history reload",1,reload,S_OK,S_OK,FALSE,FALSE,FALSE},
        {"history redirected",1,history,S_OK,S_OK,TRUE,FALSE,FALSE},
        {"history missing interface",1,history,E_NOINTERFACE,S_OK,FALSE,FALSE,FALSE},
        {"history failed query",1,history,S_OK,E_FAIL,FALSE,FALSE,FALSE},
        {"history remote",1,history,S_OK,S_OK,FALSE,TRUE,FALSE},
        {"refresh reload",2,reload,S_OK,S_OK,FALSE,FALSE,TRUE},
        {"refresh document",2,doc,S_OK,S_OK,FALSE,FALSE,FALSE},
        {"refresh history",2,history,S_OK,S_OK,FALSE,FALSE,FALSE},
        {"refresh redirected",2,reload,S_OK,S_OK,TRUE,FALSE,FALSE},
        {"refresh missing interface",2,reload,E_NOINTERFACE,S_OK,FALSE,FALSE,FALSE},
        {"explicit document",3,doc,S_OK,S_OK,FALSE,FALSE,TRUE},
        {"explicit history",3,history,S_OK,S_OK,FALSE,FALSE,FALSE},
        {"explicit reload",3,reload,S_OK,S_OK,FALSE,FALSE,FALSE},
        {"explicit redirected",3,doc,S_OK,S_OK,TRUE,FALSE,FALSE},
        {"explicit remote",3,doc,S_OK,S_OK,FALSE,TRUE,FALSE},
        {"explicit failed query",3,doc,S_OK,E_FAIL,FALSE,FALSE,FALSE},
        {"local policy document",4,doc,S_OK,S_OK,FALSE,FALSE,TRUE},
        {"local policy missing interface",4,doc,E_NOINTERFACE,S_OK,FALSE,FALSE,TRUE},
        {"local policy remote",4,doc,S_OK,S_OK,FALSE,TRUE,FALSE}
    };
    int failed=0;
    for (size_t index=0;index<sizeof(cases)/sizeof(cases[0]);index++) failed+=run_case(&cases[index]);
    failed+=uri_navigation(16384,FALSE,FALSE,TRUE);
    failed+=uri_navigation(16385,FALSE,FALSE,FALSE);
    failed+=uri_navigation(65536,TRUE,FALSE,TRUE);
    failed+=uri_navigation(65536,TRUE,TRUE,TRUE);
    failed+=uri_source(16384,FALSE,TRUE);
    failed+=uri_source(16385,FALSE,FALSE);
    failed+=uri_source(128,TRUE,FALSE);
    failed+=uri_message(16384,16384,TRUE);
    failed+=uri_message(16385,16384,FALSE);
    failed+=uri_message(16384,16385,FALSE);
    failed+=remote_policy_cases();
    failed+=request_policy_cases();
    failed+=remote_navigation_case(FALSE,FALSE,FALSE,1,L"https://remote.example/start",TRUE);
    failed+=remote_navigation_case(FALSE,FALSE,FALSE,0,L"https://remote.example/next",FALSE);
    failed+=remote_navigation_case(TRUE,FALSE,FALSE,0,L"https://remote.example/next",TRUE);
    failed+=remote_navigation_case(FALSE,FALSE,FALSE,2,L"https://remote.example/next",TRUE);
    failed+=remote_navigation_case(FALSE,FALSE,TRUE,2,L"https://remote.example/next",FALSE);
    failed+=remote_navigation_case(FALSE,TRUE,TRUE,2,L"https://other.example/next",TRUE);
    failed+=remote_navigation_case(FALSE,TRUE,TRUE,2,L"https://unlisted.example/next",FALSE);
    failed+=remote_navigation_case(FALSE,TRUE,TRUE,0,L"https://other.example/next",FALSE);
    failed+=remote_navigation_case(FALSE,FALSE,FALSE,3,L"https://other.example/previous",TRUE);
    failed+=remote_ipc_case(TRUE,TRUE,FALSE);
    failed+=remote_ipc_case(FALSE,TRUE,FALSE);
    failed+=remote_ipc_case(TRUE,FALSE,FALSE);
    failed+=remote_ipc_case(TRUE,TRUE,TRUE);
    failed+=script_abi_cases();
    failed+=bounded_stream_cases();
    failed+=tool_abi_cases();
    failed+=resource_abi_cases();
    failed+=file_stream_abi_cases();
    failed+=scheme_abi_cases();
    failed+=permission_abi_cases();
    failed+=download_abi_cases();
    failed+=viewport_abi_cases();
    if (live_states || live_handlers || owned_controllers) failed++;
    return failed;
}
