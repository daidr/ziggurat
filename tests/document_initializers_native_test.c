/* Pure native regression: the real initializer adapter against a bounded SDK
   double. This does not create a window, browser, worker or nested message loop. */
#include "../src/webview/webview2.c"
#include <assert.h>

typedef struct FakeWebView {
    ICoreWebView2 iface;
    LONG refs;
    HRESULT add_result;
    unsigned adds,removes,remove_fail_at,navigations;
    State *state;
    uint64_t reentrant_token;
    unsigned remove_action,remove_actions;
    BOOL cancel_result;
    ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler *pending;
} FakeWebView;
typedef struct Probe {
    State *state;
    unsigned calls,readies,failures,pages;
    uint64_t token;
    uint32_t kind;
    HRESULT result;
    BOOL close;
} Probe;
static ULONG STDMETHODCALLTYPE fake_add(ICoreWebView2 *p) { return (ULONG)InterlockedIncrement(&((FakeWebView *)p)->refs); }
static ULONG STDMETHODCALLTYPE fake_release(ICoreWebView2 *p) { return (ULONG)InterlockedDecrement(&((FakeWebView *)p)->refs); }
static HRESULT STDMETHODCALLTYPE fake_script(ICoreWebView2 *p,LPCWSTR source,ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler *handler) {
    FakeWebView *fake=(FakeWebView *)p;fake->adds++;
    assert(source && source[0]);
    if (FAILED(fake->add_result)) return fake->add_result;
    assert(!fake->pending);fake->pending=handler;
    ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler_AddRef(handler);return S_OK;
}
static HRESULT STDMETHODCALLTYPE fake_remove(ICoreWebView2 *p,LPCWSTR id) {
    FakeWebView *fake=(FakeWebView *)p;assert(id && id[0]);fake->removes++;
    unsigned action=fake->remove_action;fake->remove_action=0;
    if (action) {
        fake->remove_actions++;
        if (action==1) fake->cancel_result=zwv_initializers_try_cancel(fake->state,fake->reentrant_token);
        else zwv_close(fake->state);
    }
    return fake->remove_fail_at==fake->removes?E_FAIL:S_OK;
}
static HRESULT STDMETHODCALLTYPE fake_navigate_html(ICoreWebView2 *p,LPCWSTR html) {
    assert(html);((FakeWebView *)p)->navigations++;return S_OK;
}
static ICoreWebView2Vtbl fake_vtable={ .AddRef=fake_add,.Release=fake_release,.NavigateToString=fake_navigate_html,.AddScriptToExecuteOnDocumentCreated=fake_script,.RemoveScriptToExecuteOnDocumentCreated=fake_remove };
static void native_notify(void *context,int kind,const WCHAR *value,HRESULT hr) {
    (void)value;(void)hr;Probe *probe=context;
    if (kind==0) probe->readies++;
    else if (kind==2) probe->failures++;
}
static int native_page(void *context,const PageEvent *event) {
    if (!event->kind) ((Probe *)context)->pages++;return 1;
}
static State *state_new(FakeWebView *fake,Probe *probe) {
    memset(fake,0,sizeof(*fake));fake->iface.lpVtbl=&fake_vtable;fake->refs=1;
    State *s=calloc(1,sizeof(*s));assert(s);s->refs=1;s->webview=&fake->iface;s->context=probe;s->notify=native_notify;s->page_notify=native_page;
    InterlockedIncrement(&live_states);probe->state=s;fake->state=s;return s;
}
static void completed(void *context,uint64_t token,uint32_t kind,HRESULT hr) {
    Probe *probe=context;probe->calls++;probe->token=token;probe->kind=kind;probe->result=hr;
    assert(!probe->state->initializers->pending);
    if (probe->close) zwv_close(probe->state);
}
static ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler *flush(FakeWebView *fake,HRESULT hr,LPCWSTR id,BOOL keep) {
    ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler *handler=fake->pending;
    assert(handler);fake->pending=NULL;
    assert(SUCCEEDED(ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler_Invoke(handler,hr,id)));
    if (!keep) { ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler_Release(handler);return NULL; }
    return handler;
}
static InitializerInput input(InitializerBudget *budget,const WCHAR *body) {
    InitializerInput value={budget,body,body?(uint32_t)wcslen(body):0,0};return value;
}
static void counts_zero(void) {
    uint32_t states,handlers,controllers,budgets,owners,initializers;uint64_t bytes;
    zwv_resource_counts(&states,&handlers,&controllers);zwv_initializer_counts(&budgets,&owners,&initializers,&bytes);
    assert(!states && !handlers && !controllers && !budgets && !owners && !initializers && !bytes);
}
static InitializerBudget *budget_new(void) {
    HRESULT hr=E_FAIL;InitializerBudget *budget=zwv_initializer_budget_create(4u*1024u*1024u,&hr);
    assert(budget && hr==S_OK);return budget;
}
typedef struct FakeNavigation { ICoreWebView2NavigationStartingEventArgs iface;BOOL cancelled; } FakeNavigation;
static HRESULT STDMETHODCALLTYPE nav_query(ICoreWebView2NavigationStartingEventArgs *p,REFIID id,void **out) { (void)p;(void)id;*out=NULL;return E_NOINTERFACE; }
static HRESULT STDMETHODCALLTYPE nav_uri(ICoreWebView2NavigationStartingEventArgs *p,LPWSTR *out) {
    (void)p;const WCHAR uri[]=L"https://example.test/next";
    *out=CoTaskMemAlloc(sizeof(uri));assert(*out);memcpy(*out,uri,sizeof(uri));return S_OK;
}
static HRESULT STDMETHODCALLTYPE nav_false(ICoreWebView2NavigationStartingEventArgs *p,BOOL *out) { (void)p;*out=FALSE;return S_OK; }
static HRESULT STDMETHODCALLTYPE nav_id(ICoreWebView2NavigationStartingEventArgs *p,UINT64 *out) { (void)p;*out=11;return S_OK; }
static HRESULT STDMETHODCALLTYPE nav_cancel(ICoreWebView2NavigationStartingEventArgs *p,BOOL value) { ((FakeNavigation *)p)->cancelled=value;return S_OK; }
static ICoreWebView2NavigationStartingEventArgsVtbl nav_vtable={.QueryInterface=nav_query,.get_Uri=nav_uri,.get_IsUserInitiated=nav_false,.get_IsRedirected=nav_false,.get_NavigationId=nav_id,.put_Cancel=nav_cancel};
static void navigation_gate(State *s,Probe *probe,BOOL allowed) {
    if (!s->local_prefix) s->local_prefix=_wcsdup(L"https://example.test/");
    s->allow_local_navigation=TRUE;
    FakeNavigation args={.iface={.lpVtbl=&nav_vtable}};
    NavigationHandler *handler=NavigationHandler_new(s);assert(handler);
    unsigned before=probe->pages;
    assert(SUCCEEDED(navigation_invoke(&handler->iface,s->webview,&args.iface)));
    NavigationHandler_release(&handler->iface);
    assert(args.cancelled==!allowed && probe->pages==before+(allowed?1u:0u));
}
static void tiny_budget_and_initial_start(void) {
    HRESULT hr=E_FAIL;assert(!zwv_initializer_budget_create(1,&hr) && hr==HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA));counts_zero();
    InitializerBudget *exact=zwv_initializer_budget_create(sizeof(InitializerBudget),&hr);assert(exact && hr==S_OK);
    assert(!zwv_initializer_budget_reserve(exact,1));zwv_initializer_budget_unref(exact);counts_zero();
    FakeWebView fake;Probe probe={0};State *s=state_new(&fake,&probe);
    s->html=_wcsdup(L"");assert(s->html);
    InitializerBudget *budget=budget_new();InitializerInput value=input(budget,L"window.initial=1;");
    assert(SUCCEEDED(zwv_initializers_prepare(s,&value,0,NULL)));
    assert(SUCCEEDED(initializers_start(s)) && fake.adds==1 && !fake.navigations && !probe.readies);
    navigation_gate(s,&probe,FALSE);
    flush(&fake,S_OK,L"initial-id",FALSE);
    assert(fake.navigations==1 && probe.readies==1 && !probe.calls);
    zwv_close(s);zwv_initializer_budget_unref(budget);counts_zero();

    memset(&probe,0,sizeof(probe));s=state_new(&fake,&probe);budget=budget_new();value=input(budget,L"window.initial=2;");
    assert(SUCCEEDED(zwv_initializers_prepare(s,&value,0,NULL)));
    notify(s,2,NULL,E_FAIL);assert(probe.failures==1 && !s->initializers->pending && !initializer_handlers);
    zwv_close(s);zwv_initializer_budget_unref(budget);counts_zero();
}
static void prepare_and_sync_failure(void) {
    FakeWebView fake;Probe probe={0};State *s=state_new(&fake,&probe);
    InitializerBudget *budget=budget_new();assert(budget);
    WCHAR body[]=L"window.original=1;";InitializerInput value=input(budget,body);
    assert(SUCCEEDED(zwv_initializers_prepare(s,&value,1,completed)));
    body[0]=L'?';assert(s->initializers->pending->source[0]==L'w');
    assert(!initializers_allow_navigation(s) && !fake.adds && !probe.calls);
    assert(zwv_initializers_prepare(s,&value,2,completed)==E_PENDING);
    zwv_initializers_abandon(s);assert(initializers_allow_navigation(s) && !probe.calls);
    value=input(budget,L"window.original=2;");fake.add_result=E_FAIL;
    assert(SUCCEEDED(zwv_initializers_prepare(s,&value,2,completed)));zwv_initializers_activate(s);
    assert(probe.calls==1 && probe.token==2 && probe.kind==2 && probe.result==E_FAIL);
    assert(initializers_allow_navigation(s) && !s->initializers->id);
    zwv_close(s);assert(!fake.refs);zwv_initializer_budget_unref(budget);counts_zero();
}
static void replace_and_clear(void) {
    FakeWebView fake;Probe probe={0};State *s=state_new(&fake,&probe);
    InitializerBudget *budget=budget_new();assert(budget);
    InitializerInput value=input(budget,L"window.first=1;");
    assert(SUCCEEDED(zwv_initializers_prepare(s,&value,1,completed)));zwv_initializers_activate(s);
    assert(!initializers_allow_navigation(s) && !probe.calls);flush(&fake,S_OK,L"first-id",FALSE);
    assert(probe.calls==1 && probe.kind==0 && wcscmp(s->initializers->id,L"first-id")==0);
    value=input(budget,L"window.second=1;");
    assert(SUCCEEDED(zwv_initializers_prepare(s,&value,2,completed)));zwv_initializers_activate(s);flush(&fake,E_FAIL,NULL,FALSE);
    assert(probe.calls==2 && probe.kind==2 && !fake.removes && wcscmp(s->initializers->id,L"first-id")==0);
    assert(SUCCEEDED(zwv_initializers_prepare(s,&value,3,completed)));zwv_initializers_activate(s);flush(&fake,S_OK,L"second-id",FALSE);
    assert(probe.calls==3 && probe.kind==0 && fake.removes==1 && wcscmp(s->initializers->id,L"second-id")==0);
    value=input(budget,NULL);assert(SUCCEEDED(zwv_initializers_prepare(s,&value,4,completed)));zwv_initializers_activate(s);
    assert(probe.calls==4 && probe.kind==0 && fake.removes==2 && !s->initializers->id && initializers_allow_navigation(s));
    zwv_close(s);assert(!fake.refs);zwv_initializer_budget_unref(budget);counts_zero();
}
static void cancel_late_and_last_reference(void) {
    FakeWebView fake;Probe probe={0};State *s=state_new(&fake,&probe);
    InitializerBudget *budget=budget_new();assert(budget);
    InitializerInput value=input(budget,L"window.cancelled=1;");
    assert(SUCCEEDED(zwv_initializers_prepare(s,&value,7,completed)));zwv_initializers_activate(s);
    zwv_initializers_cancel(s,7);assert(!initializers_allow_navigation(s));
    navigation_gate(s,&probe,FALSE);
    size_t retained=budget->used;
    ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler *extra=flush(&fake,S_OK,L"cancelled-id",TRUE);
    assert(probe.calls==1 && probe.kind==1 && fake.removes==1 && !s->initializers->id && initializers_allow_navigation(s));
    assert(budget->used==retained); /* SDK's last ref still owns encoded source */
    navigation_gate(s,&probe,TRUE);
    zwv_close(s);zwv_initializer_budget_unref(budget);
    assert(live_states==1 && initializer_budgets==1 && initializer_handlers==1 && fake.refs==1);
    ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler_Release(extra);
    assert(!fake.refs);counts_zero();

    memset(&probe,0,sizeof(probe));s=state_new(&fake,&probe);budget=budget_new();value=input(budget,L"window.late=1;");
    assert(SUCCEEDED(zwv_initializers_prepare(s,&value,8,completed)));zwv_initializers_activate(s);
    zwv_close(s);zwv_initializer_budget_unref(budget);flush(&fake,S_OK,L"after-close-id",FALSE);
    assert(!probe.calls && fake.removes==1 && !fake.refs);counts_zero();
}
static void uncertainty_and_budget_rollback(void) {
    FakeWebView fake;Probe probe={0};State *s=state_new(&fake,&probe);
    InitializerBudget *budget=budget_new();assert(budget);
    InitializerInput value=input(budget,L"window.test=1;");
    assert(SUCCEEDED(zwv_initializers_prepare(s,&value,1,completed)));zwv_initializers_activate(s);flush(&fake,S_OK,L"old-id",FALSE);
    assert(SUCCEEDED(zwv_initializers_prepare(s,&value,2,completed)));zwv_initializers_activate(s);
    budget->limit=budget->used;flush(&fake,S_OK,L"over-budget-id",FALSE);
    assert(probe.calls==2 && probe.kind==2 && initializers_allow_navigation(s) && fake.removes==1 && wcscmp(s->initializers->id,L"old-id")==0);
    budget->limit=4u*1024u*1024u;fake.remove_fail_at=2;
    assert(SUCCEEDED(zwv_initializers_prepare(s,&value,3,completed)));zwv_initializers_activate(s);flush(&fake,S_OK,L"new-id",FALSE);
    assert(probe.calls==3 && probe.kind==3 && !initializers_allow_navigation(s) && fake.removes==3 && wcscmp(s->initializers->id,L"old-id")==0);
    navigation_gate(s,&probe,FALSE);
    assert(zwv_initializers_prepare(s,&value,4,completed)==E_PENDING);
    zwv_close(s);assert(!fake.refs);zwv_initializer_budget_unref(budget);counts_zero();

    memset(&probe,0,sizeof(probe));s=state_new(&fake,&probe);budget=budget_new();value=input(budget,L"window.unknown=1;");
    assert(SUCCEEDED(zwv_initializers_prepare(s,&value,1,completed)));zwv_initializers_activate(s);flush(&fake,S_OK,NULL,FALSE);
    assert(probe.calls==1 && probe.kind==3 && !initializers_allow_navigation(s));
    zwv_close(s);zwv_initializer_budget_unref(budget);counts_zero();
}
static void callback_close(void) {
    FakeWebView fake;Probe probe={.close=TRUE};State *s=state_new(&fake,&probe);
    InitializerBudget *budget=budget_new();assert(budget);
    InitializerInput value=input(budget,L"window.close=1;");
    assert(SUCCEEDED(zwv_initializers_prepare(s,&value,1,completed)));zwv_initializers_activate(s);flush(&fake,S_OK,L"close-id",FALSE);
    assert(probe.calls==1 && probe.kind==0 && !fake.refs);zwv_initializer_budget_unref(budget);counts_zero();
}
static void remove_reentry_commit(void) {
    FakeWebView fake;Probe probe={0};State *s=state_new(&fake,&probe);InitializerBudget *budget=budget_new();
    InitializerInput value=input(budget,L"window.old=1;");
    assert(SUCCEEDED(zwv_initializers_prepare(s,&value,1,completed)));zwv_initializers_activate(s);flush(&fake,S_OK,L"old-id",FALSE);
    value=input(budget,L"window.new=1;");fake.remove_action=1;fake.reentrant_token=2;
    assert(SUCCEEDED(zwv_initializers_prepare(s,&value,2,completed)));zwv_initializers_activate(s);flush(&fake,S_OK,L"new-id",FALSE);
    assert(fake.remove_actions==1 && !fake.cancel_result);
    assert(probe.calls==2 && probe.kind==0 && initializers_allow_navigation(s) && wcscmp(s->initializers->id,L"new-id")==0);
    value=input(budget,NULL);fake.remove_action=1;fake.reentrant_token=3;
    assert(SUCCEEDED(zwv_initializers_prepare(s,&value,3,completed)));zwv_initializers_activate(s);
    assert(fake.remove_actions==2 && !fake.cancel_result && probe.calls==3 && probe.kind==0 && !s->initializers->id);
    value=input(budget,L"window.close=1;");
    assert(SUCCEEDED(zwv_initializers_prepare(s,&value,4,completed)));zwv_initializers_activate(s);flush(&fake,S_OK,L"close-old-id",FALSE);
    fake.remove_action=2;value=input(budget,L"window.close_new=1;");
    assert(SUCCEEDED(zwv_initializers_prepare(s,&value,5,completed)));zwv_initializers_activate(s);flush(&fake,S_OK,L"close-new-id",FALSE);
    assert(fake.remove_actions==3 && probe.calls==4 && !fake.refs);zwv_initializer_budget_unref(budget);counts_zero();
}
static void old_sdk_reference_and_new_owner_share_budget(void) {
    FakeWebView old_fake,new_fake;Probe old_probe={0},new_probe={0};
    State *old_state=state_new(&old_fake,&old_probe);InitializerBudget *budget=budget_new();
    InitializerInput value=input(budget,L"window.retained=1;");
    assert(SUCCEEDED(zwv_initializers_prepare(old_state,&value,1,completed)));zwv_initializers_activate(old_state);
    ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler *extra=flush(&old_fake,S_OK,L"retained-id",TRUE);
    zwv_close(old_state);assert(live_states==1 && initializer_handlers==1);
    /* The empty replacement browser has no initializer owner. A late old SDK
       ref must still debit the same domain when a later candidate is prepared. */
    budget->limit=(size_t)budget->used;
    State *new_state=state_new(&new_fake,&new_probe);
    assert(zwv_initializers_prepare(new_state,&value,2,completed)==HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA));
    assert(!new_state->initializers && initializer_budgets==1 && !new_probe.calls);
    zwv_close(new_state);assert(!new_fake.refs);
    ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler_Release(extra);
    assert(!old_fake.refs && !live_states && budget->used==(LONGLONG)sizeof(*budget));
    budget->limit=4u*1024u*1024u;
    new_state=state_new(&new_fake,&new_probe);
    assert(SUCCEEDED(zwv_initializers_prepare(new_state,&value,3,completed)));zwv_initializers_activate(new_state);flush(&new_fake,S_OK,L"after-release-id",FALSE);
    assert(new_probe.calls==1 && new_probe.kind==0);
    zwv_close(new_state);zwv_initializer_budget_unref(budget);assert(!new_fake.refs);counts_zero();
}
int main(void) {
    counts_zero();tiny_budget_and_initial_start();prepare_and_sync_failure();replace_and_clear();cancel_late_and_last_reference();uncertainty_and_budget_rollback();callback_close();remove_reentry_commit();old_sdk_reference_and_new_owner_share_budget();
    puts("document initializers native ownership/transaction regression passed: 8 groups");return 0;
}
