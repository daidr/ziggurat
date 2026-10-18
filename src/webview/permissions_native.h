struct PermissionPending {
    PermissionPending *next;
    State *state;
    uint64_t token,navigation_id;
    ICoreWebView2PermissionRequestedEventArgs3 *args;
    ICoreWebView2Deferral *deferral;
    ActionBudget *budget;
};
typedef struct PermissionCall {
    State *state;
    ICoreWebView2PermissionRequestedEventArgs3 *args;
    uint64_t navigation_id;
    BOOL captured;
} PermissionCall;
static BOOL permission_same_origin(const WCHAR *a,const WCHAR *b) {
    NetOrigin left,right;
    if (SUCCEEDED(parse_net_origin(a,FALSE,TRUE,TRUE,&left))&&SUCCEEDED(parse_net_origin(b,TRUE,TRUE,TRUE,&right))) return origin_equal(&left,&right);
    WCHAR prefix[1026];size_t length=wcsnlen(b,1025);
    if (!length||length>1024||!wcsstr(b,L"://")) return FALSE;
    memcpy(prefix,b,length*sizeof(WCHAR));prefix[length]=L'/';prefix[length+1]=0;
    return scheme_uri_matches(a,prefix);
}
static const WCHAR *permission_offer_origin(State *s,const WCHAR *uri,uint32_t kind,BOOL user) {
    if (!s->actions||!s->actions->permission_offer||kind<1||kind>13||!s->has_document||!s->committed||!bounded_uri(uri)||!s->document_source) return NULL;
    if (s->actions->permission_gesture&&!user) return NULL;
    for (uint32_t i=0;i<s->actions->permission_count;i++) {
        PermissionGrantInput *grant=&s->actions->permissions[i];
        if ((grant->kinds&(1u<<(kind-1)))&&permission_same_origin(uri,grant->origin)&&permission_same_origin(s->document_source,grant->origin)) return grant->origin;
    }
    return NULL;
}
static void permission_pending_free(PermissionPending *request) {
    State *s=request->state;ActionBudget *budget=request->budget;
    if (request->deferral) ICoreWebView2Deferral_Release(request->deferral);
    if (request->args) ICoreWebView2PermissionRequestedEventArgs3_Release(request->args);
    free(request);InterlockedDecrement(&budget->permissions);InterlockedDecrement(&permission_request_live);zwv_action_budget_release(budget);release(s);
}
HRESULT zwv_permission_defer(void *opaque,uint64_t token) {
    PermissionCall *call=opaque;State *s=call->state;
    if (call->captured||s->closed||s->recovering||!s->actions||!s->committed||s->navigation_id!=call->navigation_id) return E_ABORT;
    ActionBudget *budget=s->actions->budget;
    LONG live=InterlockedIncrement(&budget->permissions);
    if (live>InterlockedCompareExchange(&budget->permission_limit,0,0)) { InterlockedDecrement(&budget->permissions);return E_PENDING; }
    if (InterlockedIncrement(&permission_request_live)>32) { InterlockedDecrement(&permission_request_live);InterlockedDecrement(&budget->permissions);return E_PENDING; }
    PermissionPending *request=calloc(1,sizeof(*request));
    if (!request) { InterlockedDecrement(&permission_request_live);InterlockedDecrement(&budget->permissions);return E_OUTOFMEMORY; }
    request->state=s;retain(s);request->budget=budget;action_budget_add(budget);request->token=token;request->navigation_id=call->navigation_id;
    request->args=call->args;ICoreWebView2PermissionRequestedEventArgs3_AddRef(request->args);
    HRESULT hr=ICoreWebView2PermissionRequestedEventArgs3_GetDeferral(request->args,&request->deferral);
    if (SUCCEEDED(hr)&&!request->deferral) hr=E_POINTER;
    if (FAILED(hr)||s->closed||s->recovering||!s->committed||s->navigation_id!=call->navigation_id) {
        if (request->deferral) ICoreWebView2Deferral_Complete(request->deferral);
        permission_pending_free(request);return FAILED(hr)?hr:E_ABORT;
    }
    request->next=s->permission_requests;s->permission_requests=request;call->captured=TRUE;return S_OK;
}
static PermissionPending *permission_take(State *s,uint64_t token) {
    PermissionPending **link=&s->permission_requests;
    while (*link) {
        PermissionPending *request=*link;
        if (request->token==token) { *link=request->next;request->next=NULL;return request; }
        link=&request->next;
    }
    return NULL;
}
static HRESULT permission_finish(PermissionPending *request,BOOL allow) {
    State *s=request->state;
    BOOL stale=allow&&(s->closed||s->recovering||!s->committed||s->navigation_id!=request->navigation_id);
    if (stale) allow=FALSE;
    HRESULT hr=ICoreWebView2PermissionRequestedEventArgs3_put_State(request->args,allow?COREWEBVIEW2_PERMISSION_STATE_ALLOW:COREWEBVIEW2_PERMISSION_STATE_DENY);
    if (allow&&(s->closed||s->recovering||!s->committed||s->navigation_id!=request->navigation_id)) {
        HRESULT denied=ICoreWebView2PermissionRequestedEventArgs3_put_State(request->args,COREWEBVIEW2_PERMISSION_STATE_DENY);
        hr=FAILED(denied)?denied:E_ABORT;
    }
    HRESULT complete=ICoreWebView2Deferral_Complete(request->deferral);
    permission_pending_free(request);return FAILED(hr)?hr:(FAILED(complete)?complete:(stale?E_ABORT:S_OK));
}
HRESULT zwv_permission_decide(State *s,uint64_t token,_Bool allow) {
    PermissionPending *request=permission_take(s,token);if (!request) return E_INVALIDARG;
    return permission_finish(request,allow);
}
HRESULT zwv_permission_cancel(State *s,uint64_t token) {
    PermissionPending *request=permission_take(s,token);if (!request) return S_FALSE;
    return permission_finish(request,FALSE);
}
static void permission_requests_close(State *s) {
    PermissionPending *snapshot=s->permission_requests;s->permission_requests=NULL;
    while (snapshot) { PermissionPending *next=snapshot->next;snapshot->next=NULL;permission_finish(snapshot,FALSE);snapshot=next; }
}
