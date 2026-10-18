/* Test-only controller exercises production viewport commit and rollback. */
typedef struct ViewportProbe {
    ICoreWebView2Controller iface;
    ULONG refs;
    RECT bounds;
    BOOL visible;
    State *state;
    unsigned bounds_calls, visibility_calls, closes, notifications;
    unsigned fail_bounds, fail_visibility, close_bounds;
    HRESULT read_result;
    HRESULT position_result;
    unsigned positions;
    BOOL close_position;
} ViewportProbe;
static ULONG STDMETHODCALLTYPE viewport_probe_add(ICoreWebView2Controller *p) { return ++((ViewportProbe *)p)->refs; }
static ULONG STDMETHODCALLTYPE viewport_probe_release(ICoreWebView2Controller *p) { return --((ViewportProbe *)p)->refs; }
static HRESULT STDMETHODCALLTYPE viewport_probe_bounds(ICoreWebView2Controller *p,RECT *out) {
    ViewportProbe *v=(ViewportProbe *)p; *out=v->bounds; return v->read_result;
}
static HRESULT STDMETHODCALLTYPE viewport_probe_visible(ICoreWebView2Controller *p,BOOL *out) {
    ViewportProbe *v=(ViewportProbe *)p; *out=v->visible; return S_OK;
}
static HRESULT STDMETHODCALLTYPE viewport_probe_put_bounds(ICoreWebView2Controller *p,RECT value) {
    ViewportProbe *v=(ViewportProbe *)p; v->bounds_calls++; v->bounds=value;
    if (v->close_bounds==v->bounds_calls) v->state->closed=TRUE;
    return v->fail_bounds==v->bounds_calls?E_FAIL:S_OK;
}
static HRESULT STDMETHODCALLTYPE viewport_probe_put_visible(ICoreWebView2Controller *p,BOOL value) {
    ViewportProbe *v=(ViewportProbe *)p; v->visibility_calls++; v->visible=value;
    return v->fail_visibility==v->visibility_calls?E_FAIL:S_OK;
}
static HRESULT STDMETHODCALLTYPE viewport_probe_close(ICoreWebView2Controller *p) { ((ViewportProbe *)p)->closes++; return S_OK; }
static HRESULT STDMETHODCALLTYPE viewport_probe_position(ICoreWebView2Controller *p) {
    ViewportProbe *v=(ViewportProbe *)p; v->positions++;
    if (v->close_position) v->state->closed=TRUE;
    return v->position_result;
}
static ICoreWebView2ControllerVtbl viewport_probe_vtable={
    .AddRef=viewport_probe_add,.Release=viewport_probe_release,.get_Bounds=viewport_probe_bounds,
    .put_Bounds=viewport_probe_put_bounds,.get_IsVisible=viewport_probe_visible,
    .put_IsVisible=viewport_probe_put_visible,.Close=viewport_probe_close,
    .NotifyParentWindowPositionChanged=viewport_probe_position
};
static void viewport_probe_notify(void *context,int kind,const WCHAR *value,HRESULT hr) {
    (void)value; ViewportProbe *v=context;
    if (kind==2 && FAILED(hr)) v->notifications++;
}
static int viewport_abi_cases(void) {
    int failed=0;
    for (unsigned test=0;test<6;test++) {
        ViewportProbe v={0};v.iface.lpVtbl=&viewport_probe_vtable;v.refs=1;
        v.bounds=(RECT){1,2,11,22};v.visible=TRUE;
        State *s=calloc(1,sizeof(*s));if (!s) return failed+1;
        s->refs=1;InterlockedIncrement(&live_states);s->context=&v;s->notify=viewport_probe_notify;v.state=s;
        RECT original=v.bounds, target={20,30,60,80};
        if (FAILED(zwv_viewport(s,original.left,original.top,original.right,original.bottom,TRUE))) failed++;
        s->controller=&v.iface;
        if (test==1) v.read_result=E_ACCESSDENIED;
        if (test==2) v.fail_bounds=1;
        if (test==3 || test==4) v.fail_visibility=1;
        if (test==4) v.fail_bounds=2;
        if (test==5) v.close_bounds=1;
        HRESULT hr=zwv_viewport(s,target.left,target.top,target.right,target.bottom,FALSE);
        if (test==0) {
            if (FAILED(hr)||!EqualRect(&v.bounds,&target)||v.visible||!EqualRect(&s->viewport,&target)||s->viewport_visible) failed++;
        } else {
            if (SUCCEEDED(hr)||!EqualRect(&s->viewport,&original)||!s->viewport_visible) failed++;
            if (test<=3 && (!EqualRect(&v.bounds,&original)||!v.visible)) failed++;
            if (test==4 && (v.closes!=1||v.notifications!=1)) failed++;
            if (test==5 && (hr!=HRESULT_FROM_WIN32(ERROR_INVALID_WINDOW_HANDLE)||v.visibility_calls!=0)) failed++;
        }
        if (v.refs!=1||s->refs!=1) failed++;
        s->controller=NULL;release(s);
    }
    for (unsigned test=0;test<3;test++) {
        ViewportProbe v={0};v.iface.lpVtbl=&viewport_probe_vtable;v.refs=1;
        State *s=calloc(1,sizeof(*s));if (!s) return failed+1;
        s->refs=1;InterlockedIncrement(&live_states);v.state=s;s->controller=&v.iface;
        if (test==1) v.position_result=E_ACCESSDENIED;
        if (test==2) v.close_position=TRUE;
        HRESULT hr=zwv_parent_position(s);
        if ((test==0 && hr!=S_OK)||(test==1 && hr!=E_ACCESSDENIED)||(test==2 && hr!=HRESULT_FROM_WIN32(ERROR_INVALID_WINDOW_HANDLE))) failed++;
        if (v.positions!=1||v.refs!=1||s->refs!=1) failed++;
        s->controller=NULL;release(s);
    }
    for (unsigned test=0;test<4;test++) {
        ViewportProbe v={0};v.iface.lpVtbl=&viewport_probe_vtable;v.refs=1;
        State *s=calloc(1,sizeof(*s));if (!s) return failed+1;
        s->refs=1;InterlockedIncrement(&live_states);v.state=s;s->controller=&v.iface;
        if (test==1) v.fail_bounds=1;
        if (test==2) v.position_result=E_ACCESSDENIED;
        if (test==3) v.close_position=TRUE;
        HRESULT hr=zwv_session_viewport(s,120,80,TRUE);
        HRESULT expected=test==0?S_OK:test==1?E_FAIL:test==2?E_ACCESSDENIED:HRESULT_FROM_WIN32(ERROR_INVALID_WINDOW_HANDLE);
        if (hr!=expected || v.positions!=(test==1?0u:1u) || v.refs!=1 || s->refs!=1) failed++;
        if (test!=1 && (v.bounds.right!=120 || v.bounds.bottom!=80 || !v.visible)) failed++;
        s->controller=NULL;release(s);
    }
    if (failed) fprintf(stderr,"viewport commit/rollback/reentry ABI failures=%d\n",failed);
    return failed;
}
