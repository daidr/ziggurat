/* Synthetic COM arguments only in this test TU; production entry points and
   physical-budget/late-handler logic are exercised without a browser. */
typedef struct DownloadProbe DownloadProbe;
struct DownloadProbe {
    ICoreWebView2DownloadOperation operation;
    ICoreWebView2DownloadStartingEventArgs args;
    ICoreWebView2Deferral deferral;
    ULONG op_refs,arg_refs,deferral_refs,completes,cancels,calls;
    HRESULT defer_hr,state_add_hr,path_hr,complete_hr,bytes_hr;
    ICoreWebView2BytesReceivedChangedEventHandler *bytes,*late_bytes;
    ICoreWebView2StateChangedEventHandler *state,*late_state;
    COREWEBVIEW2_DOWNLOAD_STATE status;
    COREWEBVIEW2_DOWNLOAD_INTERRUPT_REASON reason;
    INT64 received,total;
    BOOL late,complete_in_deferral,cancel_on_read,cancel_in_notify;
    State *owner;
    uint64_t token;
    uint32_t last_kind;
    int32_t last_code;
};
static DownloadProbe *download_probe_args(ICoreWebView2DownloadStartingEventArgs *p) { return (DownloadProbe *)((char *)p - offsetof(DownloadProbe,args)); }
static DownloadProbe *download_probe_deferral(ICoreWebView2Deferral *p) { return (DownloadProbe *)((char *)p - offsetof(DownloadProbe,deferral)); }
static ULONG STDMETHODCALLTYPE download_probe_op_add(ICoreWebView2DownloadOperation *p) { return ++((DownloadProbe *)p)->op_refs; }
static ULONG STDMETHODCALLTYPE download_probe_op_release(ICoreWebView2DownloadOperation *p) { return --((DownloadProbe *)p)->op_refs; }
static ULONG STDMETHODCALLTYPE download_probe_arg_add(ICoreWebView2DownloadStartingEventArgs *p) { return ++download_probe_args(p)->arg_refs; }
static ULONG STDMETHODCALLTYPE download_probe_arg_release(ICoreWebView2DownloadStartingEventArgs *p) { return --download_probe_args(p)->arg_refs; }
static ULONG STDMETHODCALLTYPE download_probe_deferral_add(ICoreWebView2Deferral *p) { return ++download_probe_deferral(p)->deferral_refs; }
static ULONG STDMETHODCALLTYPE download_probe_deferral_release(ICoreWebView2Deferral *p) { return --download_probe_deferral(p)->deferral_refs; }
static void download_probe_event(DownloadProbe *probe) {
    ICoreWebView2StateChangedEventHandler *handler=probe->state;
    if (handler) { ICoreWebView2StateChangedEventHandler_AddRef(handler);ICoreWebView2StateChangedEventHandler_Invoke(handler,&probe->operation,NULL);ICoreWebView2StateChangedEventHandler_Release(handler); }
}
static HRESULT STDMETHODCALLTYPE download_probe_complete(ICoreWebView2Deferral *p) {
    DownloadProbe *probe=download_probe_deferral(p);probe->completes++;
    if (probe->complete_in_deferral) { probe->status=COREWEBVIEW2_DOWNLOAD_STATE_COMPLETED;probe->received=probe->total;download_probe_event(probe); }
    return probe->complete_hr;
}
static HRESULT STDMETHODCALLTYPE download_probe_defer(ICoreWebView2DownloadStartingEventArgs *p,ICoreWebView2Deferral **out) {
    DownloadProbe *probe=download_probe_args(p);*out=NULL;if (FAILED(probe->defer_hr)) return probe->defer_hr;
    *out=&probe->deferral;download_probe_deferral_add(*out);return S_OK;
}
static HRESULT STDMETHODCALLTYPE download_probe_path(ICoreWebView2DownloadStartingEventArgs *p,LPCWSTR path) { (void)path;return download_probe_args(p)->path_hr; }
static HRESULT STDMETHODCALLTYPE download_probe_arg_cancel(ICoreWebView2DownloadStartingEventArgs *p,BOOL value) { (void)p;(void)value;return S_OK; }
static HRESULT STDMETHODCALLTYPE download_probe_add_bytes(ICoreWebView2DownloadOperation *p,ICoreWebView2BytesReceivedChangedEventHandler *handler,EventRegistrationToken *token) {
    DownloadProbe *probe=(DownloadProbe *)p;probe->bytes=handler;ICoreWebView2BytesReceivedChangedEventHandler_AddRef(handler);token->value=1;
    if (probe->late) { probe->late_bytes=handler;ICoreWebView2BytesReceivedChangedEventHandler_AddRef(handler); }return S_OK;
}
static HRESULT STDMETHODCALLTYPE download_probe_remove_bytes(ICoreWebView2DownloadOperation *p,EventRegistrationToken token) {
    (void)token;DownloadProbe *probe=(DownloadProbe *)p;ICoreWebView2BytesReceivedChangedEventHandler *handler=probe->bytes;probe->bytes=NULL;if (handler) ICoreWebView2BytesReceivedChangedEventHandler_Release(handler);return S_OK;
}
static HRESULT STDMETHODCALLTYPE download_probe_add_state(ICoreWebView2DownloadOperation *p,ICoreWebView2StateChangedEventHandler *handler,EventRegistrationToken *token) {
    DownloadProbe *probe=(DownloadProbe *)p;if (FAILED(probe->state_add_hr)) return probe->state_add_hr;
    probe->state=handler;ICoreWebView2StateChangedEventHandler_AddRef(handler);token->value=2;
    if (probe->late) { probe->late_state=handler;ICoreWebView2StateChangedEventHandler_AddRef(handler); }return S_OK;
}
static HRESULT STDMETHODCALLTYPE download_probe_remove_state(ICoreWebView2DownloadOperation *p,EventRegistrationToken token) {
    (void)token;DownloadProbe *probe=(DownloadProbe *)p;ICoreWebView2StateChangedEventHandler *handler=probe->state;probe->state=NULL;if (handler) ICoreWebView2StateChangedEventHandler_Release(handler);return S_OK;
}
static HRESULT STDMETHODCALLTYPE download_probe_received(ICoreWebView2DownloadOperation *p,INT64 *out) {
    DownloadProbe *probe=(DownloadProbe *)p;*out=probe->received;
    if (probe->cancel_on_read) { probe->cancel_on_read=FALSE;zwv_download_cancel(probe->owner,probe->token); }
    return probe->bytes_hr;
}
static HRESULT STDMETHODCALLTYPE download_probe_total(ICoreWebView2DownloadOperation *p,INT64 *out) { *out=((DownloadProbe *)p)->total;return S_OK; }
static HRESULT STDMETHODCALLTYPE download_probe_status(ICoreWebView2DownloadOperation *p,COREWEBVIEW2_DOWNLOAD_STATE *out) { *out=((DownloadProbe *)p)->status;return S_OK; }
static HRESULT STDMETHODCALLTYPE download_probe_reason(ICoreWebView2DownloadOperation *p,COREWEBVIEW2_DOWNLOAD_INTERRUPT_REASON *out) { *out=((DownloadProbe *)p)->reason;return S_OK; }
static HRESULT STDMETHODCALLTYPE download_probe_cancel(ICoreWebView2DownloadOperation *p) { ((DownloadProbe *)p)->cancels++;return S_OK; }
static HRESULT STDMETHODCALLTYPE download_probe_pause(ICoreWebView2DownloadOperation *p) { DownloadProbe *probe=(DownloadProbe *)p;probe->status=COREWEBVIEW2_DOWNLOAD_STATE_INTERRUPTED;probe->reason=COREWEBVIEW2_DOWNLOAD_INTERRUPT_REASON_USER_PAUSED;download_probe_event(probe);return S_OK; }
static HRESULT STDMETHODCALLTYPE download_probe_resume(ICoreWebView2DownloadOperation *p) { DownloadProbe *probe=(DownloadProbe *)p;probe->status=COREWEBVIEW2_DOWNLOAD_STATE_IN_PROGRESS;probe->reason=COREWEBVIEW2_DOWNLOAD_INTERRUPT_REASON_NONE;download_probe_event(probe);return S_OK; }
static ICoreWebView2DownloadOperationVtbl download_probe_operation_vtable={.AddRef=download_probe_op_add,.Release=download_probe_op_release,.add_BytesReceivedChanged=download_probe_add_bytes,.remove_BytesReceivedChanged=download_probe_remove_bytes,.add_StateChanged=download_probe_add_state,.remove_StateChanged=download_probe_remove_state,.get_BytesReceived=download_probe_received,.get_TotalBytesToReceive=download_probe_total,.get_State=download_probe_status,.get_InterruptReason=download_probe_reason,.Cancel=download_probe_cancel,.Pause=download_probe_pause,.Resume=download_probe_resume};
static ICoreWebView2DownloadStartingEventArgsVtbl download_probe_args_vtable={.AddRef=download_probe_arg_add,.Release=download_probe_arg_release,.GetDeferral=download_probe_defer,.put_ResultFilePath=download_probe_path,.put_Cancel=download_probe_arg_cancel};
static ICoreWebView2DeferralVtbl download_probe_deferral_vtable={.AddRef=download_probe_deferral_add,.Release=download_probe_deferral_release,.Complete=download_probe_complete};
static void download_probe_offer(void *context,const WCHAR *uri,const WCHAR *mime,const WCHAR *name,int64_t total,void *call) { (void)context;(void)uri;(void)mime;(void)name;(void)total;(void)call; }
static void download_probe_notify(void *context,uint64_t token,uint32_t kind,uint64_t received,int64_t total,int32_t code) {
    (void)received;(void)total;DownloadProbe *probe=context;probe->calls++;probe->last_kind=kind;probe->last_code=code;
    if (probe->cancel_in_notify) { probe->cancel_in_notify=FALSE;zwv_download_cancel(probe->owner,token); }
}
static State *download_probe_state(ActionBudget *budget,DownloadProbe *probe) {
    State *s=calloc(1,sizeof(*s));if (!s) return NULL;s->refs=1;InterlockedIncrement(&live_states);s->context=probe;
    const WCHAR *origins[]={L"https://download.example"};
    ActionInput input={.budget=budget,.download_origins=origins,.download_origin_count=1,.download_known_limit=1024,.download_received_limit=1024,.download_offer=download_probe_offer,.download_notify=download_probe_notify};
    if (FAILED(action_policy_new(&input,&s->actions))) { release(s);return NULL; }return s;
}
static int download_abi_cases(void) {
    int failed=0;
    for (int scenario=0;scenario<10;scenario++) {
        ActionBudget *budget=zwv_action_budget_create(0,1);if (!budget) return 1;
        DownloadProbe probe={.operation={&download_probe_operation_vtable},.args={&download_probe_args_vtable},.deferral={&download_probe_deferral_vtable},.op_refs=1,.arg_refs=1,.deferral_refs=1,.total=100,.token=42};
        State *s=download_probe_state(budget,&probe);if (!s) { zwv_action_budget_release(budget);return 1; }probe.owner=s;
        if (!download_origin_allowed(s,L"https://download.example/file",100)||download_origin_allowed(s,L"https://download.example.evil/file",100)||download_origin_allowed(s,L"https://download.example/file",-1)||download_origin_allowed(s,L"https://download.example/file",1025)||download_origin_allowed(s,L"file:///private",100)) failed++;
        if (scenario==0) probe.defer_hr=E_ACCESSDENIED;
        if (scenario==1) probe.state_add_hr=E_FAIL;
        if (scenario==6) probe.late=TRUE;
        DownloadCall call={s,&probe.args,&probe.operation,FALSE};HRESULT hr=zwv_download_defer(&call,probe.token);
        if (scenario<2) {
            if (hr!=(scenario==0?E_ACCESSDENIED:E_FAIL)||call.captured||s->download_requests||probe.completes!=(scenario==1)) failed++;
        } else {
            if (FAILED(hr)||!call.captured||budget->downloads!=1) failed++;
            DownloadCall full={s,&probe.args,&probe.operation,FALSE};if (zwv_download_defer(&full,100)!=E_PENDING) failed++;
            if (scenario==2) probe.path_hr=E_ACCESSDENIED;
            if (scenario==3) probe.complete_hr=E_FAIL;
            if (scenario==4) probe.complete_in_deferral=TRUE;
            if (scenario==6) {
                zwv_download_cancel(s,probe.token);zwv_close(s);s=NULL;
                if (budget->downloads!=1||download_request_live!=1||probe.calls) failed++;
                State *replacement=download_probe_state(budget,&probe);
                if (!replacement) failed++;
                else { DownloadCall next={replacement,&probe.args,&probe.operation,FALSE};if (zwv_download_defer(&next,101)!=E_PENDING) failed++;zwv_close(replacement); }
                ICoreWebView2BytesReceivedChangedEventHandler_Invoke(probe.late_bytes,&probe.operation,NULL);
                ICoreWebView2StateChangedEventHandler_Invoke(probe.late_state,&probe.operation,NULL);
                if (probe.calls) failed++;
                ICoreWebView2BytesReceivedChangedEventHandler_Release(probe.late_bytes);ICoreWebView2StateChangedEventHandler_Release(probe.late_state);
            } else {
                hr=zwv_download_accept(s,probe.token,L"C:\\private\\output.bin");
                if (probe.calls) failed++; /* Completion during Complete is muted. */
                if (scenario==2||scenario==3) { if (hr!=(scenario==2?E_ACCESSDENIED:E_FAIL)) failed++;zwv_download_cancel(s,probe.token); }
                else {
                    if (FAILED(hr)) failed++;
                    if (scenario==7) probe.cancel_on_read=TRUE;
                    if (scenario==8) probe.bytes_hr=E_ACCESSDENIED;
                    if (scenario==9) probe.cancel_in_notify=TRUE;
                    zwv_download_activate(s,probe.token);
                    if (scenario==4&&(probe.calls!=1||probe.last_kind!=1||s->download_requests)) failed++;
                    if (scenario==5) {
                        if (FAILED(zwv_download_pause(s,probe.token,TRUE))) failed++;
                        uint64_t received;int64_t total;_Bool paused=FALSE;
                        if (FAILED(zwv_download_snapshot(s,probe.token,&received,&total,&paused))||!paused) failed++;
                        if (FAILED(zwv_download_pause(s,probe.token,FALSE))) failed++;
                        zwv_download_cancel(s,probe.token);
                    }
                    if (scenario==7&&(probe.calls||s->download_requests)) failed++;
                    if (scenario==8&&(probe.calls!=1||probe.last_kind!=4||probe.last_code!=E_ACCESSDENIED||s->download_requests)) failed++;
                    if (scenario==9&&(probe.calls!=1||s->download_requests)) failed++;
                }
            }
        }
        if (s) zwv_close(s);
        if (probe.op_refs!=1||probe.arg_refs!=1||probe.deferral_refs!=1||budget->downloads||download_request_live||live_handlers) { fprintf(stderr,"download ABI scenario=%d refs=%lu/%lu/%lu physical=%ld/%ld handlers=%ld\n",scenario,probe.op_refs,probe.arg_refs,probe.deferral_refs,budget->downloads,download_request_live,live_handlers);failed++; }
        zwv_action_budget_release(budget);
    }
    if (action_budget_live) failed++;
    if (failed) fprintf(stderr,"download ABI failures=%d\n",failed);
    return failed;
}
