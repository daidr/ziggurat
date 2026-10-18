/* Test-only arguments exercise the adapter's actual deferral ownership paths. */
typedef struct PermissionProbe {
    ICoreWebView2PermissionRequestedEventArgs3 iface;
    ICoreWebView2Deferral deferral;
    ULONG refs,deferral_refs,completes,sets;
    HRESULT defer_result,complete_result,state_result;
    COREWEBVIEW2_PERMISSION_STATE value;
    State *reenter;
    BOOL reenter_defer,reenter_set;
} PermissionProbe;
static ULONG STDMETHODCALLTYPE permission_probe_add(ICoreWebView2PermissionRequestedEventArgs3 *p) { return ++((PermissionProbe *)p)->refs; }
static ULONG STDMETHODCALLTYPE permission_probe_release(ICoreWebView2PermissionRequestedEventArgs3 *p) { return --((PermissionProbe *)p)->refs; }
static HRESULT STDMETHODCALLTYPE permission_probe_state(ICoreWebView2PermissionRequestedEventArgs3 *p,COREWEBVIEW2_PERMISSION_STATE value) {
    PermissionProbe *probe=(PermissionProbe *)p;probe->sets++;probe->value=value;
    if (probe->reenter_set) { probe->reenter_set=FALSE;probe->reenter->navigation_id++; }
    return probe->state_result;
}
static PermissionProbe *permission_deferral_self(ICoreWebView2Deferral *p) { return (PermissionProbe *)((char *)p - offsetof(PermissionProbe,deferral)); }
static ULONG STDMETHODCALLTYPE permission_deferral_add(ICoreWebView2Deferral *p) { return ++permission_deferral_self(p)->deferral_refs; }
static ULONG STDMETHODCALLTYPE permission_deferral_release(ICoreWebView2Deferral *p) { return --permission_deferral_self(p)->deferral_refs; }
static HRESULT STDMETHODCALLTYPE permission_deferral_complete(ICoreWebView2Deferral *p) { PermissionProbe *probe=permission_deferral_self(p);probe->completes++;return probe->complete_result; }
static HRESULT STDMETHODCALLTYPE permission_probe_defer(ICoreWebView2PermissionRequestedEventArgs3 *p,ICoreWebView2Deferral **out) {
    PermissionProbe *probe=(PermissionProbe *)p;*out=NULL;
    if (FAILED(probe->defer_result)) return probe->defer_result;
    *out=&probe->deferral;permission_deferral_add(*out);
    if (probe->reenter_defer) probe->reenter->navigation_id++;
    return S_OK;
}
static ICoreWebView2PermissionRequestedEventArgs3Vtbl permission_probe_vtable={.AddRef=permission_probe_add,.Release=permission_probe_release,.put_State=permission_probe_state,.GetDeferral=permission_probe_defer};
static ICoreWebView2DeferralVtbl permission_deferral_vtable={.AddRef=permission_deferral_add,.Release=permission_deferral_release,.Complete=permission_deferral_complete};
static void permission_probe_offer(void *context,const WCHAR *origin,uint32_t kind,_Bool user,void *call) { (void)context;(void)origin;(void)kind;(void)user;(void)call; }
static int permission_abi_cases(void) {
    int failed=0;
    ActionBudget *budget=zwv_action_budget_create(1,0);if (!budget) return 1;
    State *s=calloc(1,sizeof(*s));if (!s) { zwv_action_budget_release(budget);return 1; }
    s->refs=1;InterlockedIncrement(&live_states);s->has_document=TRUE;s->committed=TRUE;s->navigation_id=42;
    s->document_source=_wcsdup(L"https://permission.example/current");
    PermissionGrantInput grant={L"https://permission.example",1u<<3};
    ActionInput input={.budget=budget,.permissions=&grant,.permission_count=1,.permission_gesture=TRUE,.permission_offer=permission_probe_offer};
    if (!s->document_source||FAILED(action_policy_new(&input,&s->actions))) { zwv_close(s);zwv_action_budget_release(budget);return 1; }
    if (!permission_offer_origin(s,L"https://permission.example/request",4,TRUE)||permission_offer_origin(s,L"https://permission.example/request",4,FALSE)||permission_offer_origin(s,L"https://permission.example.evil/request",4,TRUE)||permission_offer_origin(s,L"https://other.example/request",4,TRUE)||permission_offer_origin(s,L"https://permission.example/request",14,TRUE)||permission_offer_origin(s,L"https://permission.example/request",1,TRUE)) failed++;
    for (int scenario=0;scenario<7;scenario++) {
        PermissionProbe probe={.iface={&permission_probe_vtable},.deferral={&permission_deferral_vtable},.refs=1,.deferral_refs=1,.reenter=s};
        PermissionCall call={s,&probe.iface,s->navigation_id,FALSE};
        if (scenario==0) probe.defer_result=E_ACCESSDENIED;
        if (scenario==1) probe.reenter_defer=TRUE;
        HRESULT hr=zwv_permission_defer(&call,100+(uint64_t)scenario);
        if (scenario<2) {
            HRESULT expected=scenario==0?E_ACCESSDENIED:E_ABORT;
            if (hr!=expected||call.captured||s->permission_requests||probe.refs!=1||probe.deferral_refs!=1||probe.completes!=(scenario==1)) failed++;
        } else {
            PermissionCall second={s,&probe.iface,s->navigation_id,FALSE};
            if (FAILED(hr)||!call.captured||zwv_permission_defer(&second,200)!=E_PENDING||budget->permissions!=1||probe.refs!=2||probe.deferral_refs!=2) failed++;
            if (scenario==3) probe.complete_result=E_FAIL;
            if (scenario==4) s->navigation_id++;
            if (scenario==5) probe.reenter_set=TRUE;
            if (scenario==6) { permission_requests_close(s);hr=S_OK; }
            else hr=zwv_permission_decide(s,100+(uint64_t)scenario,TRUE);
            HRESULT expected=scenario==3?E_FAIL:((scenario==4||scenario==5)?E_ABORT:S_OK);
            if (hr!=expected||s->permission_requests||probe.refs!=1||probe.deferral_refs!=1||probe.completes!=1||budget->permissions||zwv_permission_cancel(s,100+(uint64_t)scenario)!=S_FALSE) failed++;
            if ((scenario==4||scenario==5||scenario==6)&&probe.value!=COREWEBVIEW2_PERMISSION_STATE_DENY) failed++;
            if (scenario==5&&probe.sets!=2) failed++;
        }
    }
    if (permission_request_live) failed++;
    zwv_close(s);zwv_action_budget_release(budget);
    if (action_budget_live||permission_request_live) failed++;
    if (failed) fprintf(stderr,"permission ABI failures=%d\n",failed);
    return failed;
}
