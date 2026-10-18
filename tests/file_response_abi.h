static ZwsCounts file_fixture_counts(void){ZwsCounts counts;zws_counts(&counts);return counts;}
/* Private fixture, included after the ordinary response/deferral fakes. */
typedef struct FileFixture {
    WCHAR path[MAX_PATH];HANDLE file,borrowed;uint64_t size;HRESULT result;BOOL cleanup;
} FileFixture;
static DWORD WINAPI file_fixture_worker(void *context) {
    FileFixture *fixture=context;fixture->result=S_OK;
    if(fixture->cleanup){
        LARGE_INTEGER zero={0},position;
        if(fixture->file&&!SetFilePointerEx(fixture->file,zero,&position,FILE_CURRENT))fixture->result=E_FAIL;
        else if(fixture->file&&position.QuadPart!=0)fixture->result=E_FAIL;
        if(fixture->borrowed&&(!SetFilePointerEx(fixture->borrowed,zero,&position,FILE_CURRENT)||position.QuadPart!=3))fixture->result=E_FAIL;
        if(fixture->file)CloseHandle(fixture->file);if(fixture->borrowed)CloseHandle(fixture->borrowed);
        fixture->file=fixture->borrowed=NULL;
        if(fixture->path[0]&&!DeleteFileW(fixture->path))fixture->result=E_FAIL;
        return 0;
    }
    WCHAR directory[MAX_PATH];if(!GetTempPathW(MAX_PATH,directory)||!GetTempFileNameW(directory,L"zfs",0,fixture->path)){fixture->result=E_FAIL;return 0;}
    HANDLE writer=CreateFileW(fixture->path,GENERIC_WRITE,0,NULL,TRUNCATE_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
    if(writer==INVALID_HANDLE_VALUE){fixture->result=E_FAIL;return 0;}
    BYTE data[4096];for(unsigned i=0;i<sizeof(data);i++)data[i]=(BYTE)(i%251);
    DWORD wrote=0;BOOL ok=WriteFile(writer,data,sizeof(data),&wrote,NULL);CloseHandle(writer);
    if(!ok||wrote!=sizeof(data)){fixture->result=E_FAIL;return 0;}
    fixture->borrowed=CreateFileW(fixture->path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
    if(fixture->borrowed==INVALID_HANDLE_VALUE){fixture->borrowed=NULL;fixture->result=E_FAIL;return 0;}
    LARGE_INTEGER three;three.QuadPart=3;SetFilePointerEx(fixture->borrowed,three,NULL,FILE_BEGIN);
    fixture->result=zwv_file_prepare(fixture->borrowed,4096,&fixture->file,&fixture->size);return 0;
}
typedef struct FileReadFixture { IStream *first,*second;HRESULT result; } FileReadFixture;
static DWORD WINAPI file_read_worker(void *context) {
    FileReadFixture *fixture=context;fixture->result=CoInitializeEx(NULL,COINIT_MULTITHREADED);
    if(FAILED(fixture->result))return 0;
    IStream *a=NULL,*b=NULL;HRESULT hr=CoGetInterfaceAndReleaseStream(fixture->first,&IID_IStream,(void **)&a);
    if(SUCCEEDED(hr))hr=CoGetInterfaceAndReleaseStream(fixture->second,&IID_IStream,(void **)&b);
    else { CoReleaseMarshalData(fixture->second);IStream_Release(fixture->second); }
    BYTE data[4097];ULONG got=0;
    if(SUCCEEDED(hr)){
        hr=IStream_Read(a,data,sizeof(data),&got);
        if(hr!=S_FALSE||got!=4096)hr=E_FAIL;
        else for(unsigned i=0;i<got;i++)if(data[i]!=(BYTE)(i%251)){hr=E_FAIL;break;}
    }
    if(SUCCEEDED(hr)){
        got=0;hr=IStream_Read(b,data,32,&got);
        if(hr!=S_OK||got!=32)hr=E_FAIL;
        else for(unsigned i=0;i<got;i++)if(data[i]!=(BYTE)(i%251)){hr=E_FAIL;break;}
    }
    if(a)IStream_Release(a);if(b)IStream_Release(b);fixture->result=hr;CoUninitialize();return 0;
}
static int file_capacity_cases(FileFixture *fixture) {
    int failed=0;FileBudget *budgets[5]={0};IStream *streams[32]={0};unsigned made=0;
    for(unsigned i=0;i<5;i++)if(!(budgets[i]=zwv_file_budget_create(8)))failed++;
    if(!failed)for(unsigned i=0;i<32;i++){
        HRESULT hr=file_stream_create(fixture->file,fixture->size,budgets[i/8],&streams[i]);
        if(FAILED(hr)){failed++;break;}made++;
    }
    if(made==32){
        BYTE byte;ULONG got=9;if(IStream_Read(streams[0],&byte,1,&got)!=E_UNEXPECTED||got)failed++;
        LARGE_INTEGER zero={0};FileStream *first=(FileStream *)streams[0];AcquireSRWLockExclusive(&first->lock);
        if(IStream_Seek(streams[0],zero,STREAM_SEEK_SET,NULL)!=E_PENDING)failed++;
        ReleaseSRWLockExclusive(&first->lock);
        IStream *full=NULL;
        if(file_stream_create(fixture->file,fixture->size,budgets[0],&full)!=E_PENDING||full)failed++;
        if(file_stream_create(fixture->file,fixture->size,budgets[4],&full)!=E_PENDING||full)failed++;
        FileReadFixture read={0};
        HRESULT hr=CoMarshalInterThreadInterfaceInStream(&IID_IStream,(IUnknown *)streams[0],&read.first);
        if(SUCCEEDED(hr))hr=CoMarshalInterThreadInterfaceInStream(&IID_IStream,(IUnknown *)streams[1],&read.second);
        if(FAILED(hr))failed++;
        else {
            HANDLE worker=CreateThread(NULL,0,file_read_worker,&read,0,NULL);
            if(!worker){CoReleaseMarshalData(read.first);IStream_Release(read.first);CoReleaseMarshalData(read.second);IStream_Release(read.second);failed++;}
            else {if(WaitForSingleObject(worker,10000)!=WAIT_OBJECT_0)abort();CloseHandle(worker);if(FAILED(read.result))failed++;}
        }
        /* EOF, logical cancellation, and released Budget owners do not return
           physical slots while these COM references are still retained. */
        for(unsigned i=0;i<32;i++)zwv_file_control_cancel(((FileStream *)streams[i])->physical.control);
        if(file_fixture_counts().physical!=32||file_stream_create(fixture->file,fixture->size,budgets[4],&full)!=E_PENDING||full)failed++;
        zwv_file_budget_limit(budgets[0],4);
        FileControl *ticket=((FileStream *)streams[0])->physical.control;zwv_file_control_add(ticket);
        IStream_Release(streams[0]);streams[0]=NULL;
        if(InterlockedCompareExchange(&ticket->alive,0,0)||file_stream_create(fixture->file,fixture->size,budgets[0],&full)!=E_PENDING||full)failed++;
        zwv_file_control_cancel(ticket);zwv_file_control_release(ticket);
        for(unsigned i=1;i<8;i++){IStream_Release(streams[i]);streams[i]=NULL;}
        if(FAILED(file_stream_create(fixture->file,fixture->size,budgets[0],&full)))failed++;
        if(full)IStream_Release(full);
        for(unsigned i=0;i<5;i++){zwv_file_budget_release(budgets[i]);budgets[i]=NULL;}
        if(file_fixture_counts().physical!=24||file_fixture_counts().budgets!=3)failed++;
    }
    for(unsigned i=0;i<32;i++)if(streams[i])IStream_Release(streams[i]);
    for(unsigned i=0;i<5;i++)if(budgets[i])zwv_file_budget_release(budgets[i]);
    if(file_fixture_counts().physical||file_fixture_counts().controls||file_fixture_counts().budgets)failed++;
    return failed;
}
typedef struct FileCancelFixture { IStream *packet;HRESULT result;ULONG got; } FileCancelFixture;
static DWORD WINAPI file_cancel_worker(void *context) {
    FileCancelFixture *fixture=context;HRESULT hr=CoInitializeEx(NULL,COINIT_MULTITHREADED);fixture->result=hr;
    if(FAILED(hr))return 0;
    IStream *stream=NULL;hr=CoGetInterfaceAndReleaseStream(fixture->packet,&IID_IStream,(void **)&stream);
    if(SUCCEEDED(hr)){BYTE output[4096];fixture->result=IStream_Read(stream,output,sizeof(output),&fixture->got);IStream_Release(stream);}
    else fixture->result=hr;
    CoUninitialize();return 0;
}
static int file_pending_cancel_case(FileFixture *fixture) {
    int failed=0;FileBudget *budget=zwv_file_budget_create(1);if(!budget)return 1;
    IStream *stream=NULL;HRESULT hr=file_stream_create(fixture->file,fixture->size,budget,&stream);
    if(FAILED(hr)){zwv_file_budget_release(budget);return 1;}
    file_io_entered=CreateEventW(NULL,TRUE,FALSE,NULL);file_io_gate=CreateEventW(NULL,TRUE,FALSE,NULL);
    if(!file_io_entered||!file_io_gate)abort();
    FileCancelFixture read={0};hr=CoMarshalInterThreadInterfaceInStream(&IID_IStream,(IUnknown *)stream,&read.packet);
    if(FAILED(hr))abort();
    InterlockedExchange(&file_io_gate_enabled,1);
    HANDLE worker=CreateThread(NULL,0,file_cancel_worker,&read,0,NULL);if(!worker)abort();
    if(WaitForSingleObject(file_io_entered,10000)!=WAIT_OBJECT_0)abort();
    zwv_file_control_cancel(((FileStream *)stream)->physical.control);
    if(file_fixture_counts().physical!=1||file_io_drained)failed++;
    SetEvent(file_io_gate);
    if(WaitForSingleObject(worker,10000)!=WAIT_OBJECT_0)abort();CloseHandle(worker);
    if(read.result!=STG_E_REVERTED||file_io_pending_path!=1||file_io_drained!=1||read.got>fixture->size)failed++;
    fprintf(stderr,"file pending-read cancel: actual IO_PENDING=%ld, pending-path=%ld, completion-drained=%ld, completed bytes=%lu\n",file_io_actual_pending,file_io_pending_path,file_io_drained,(unsigned long)read.got);
    CloseHandle(file_io_entered);CloseHandle(file_io_gate);file_io_entered=file_io_gate=NULL;
    IStream_Release(stream);zwv_file_budget_release(budget);
    if(file_fixture_counts().physical||file_fixture_counts().controls||file_fixture_counts().budgets)failed++;
    return failed;
}
typedef struct FileReentryEnvironment { RequestProbeEnvironment base;State *state;unsigned kind; } FileReentryEnvironment;
static HRESULT STDMETHODCALLTYPE file_reentry_response(ICoreWebView2Environment *p,IStream *content,int status,LPCWSTR reason,LPCWSTR headers,ICoreWebView2WebResourceResponse **out) {
    HRESULT hr=request_create_response(p,content,status,reason,headers,out);
    FileReentryEnvironment *environment=(FileReentryEnvironment *)p;
    if(SUCCEEDED(hr)){
        file_controls_close(environment->state);
        if(environment->kind==1)environment->state->closed=TRUE;else environment->state->navigation_id++;
    }
    return hr;
}
static ICoreWebView2EnvironmentVtbl file_reentry_vtable={.CreateWebResourceResponse=file_reentry_response};
static HRESULT STDMETHODCALLTYPE file_complete_failure(ICoreWebView2Deferral *p) { ((RequestProbeDeferral *)p)->completed++;return E_FAIL; }
static int file_response_cases(FileFixture *fixture) {
    int failed=0;UriProbe probe={0};State *s=uri_state(&probe,TRUE);if(!s)return 1;
    RequestProbeResponse denied={{&request_response_vtable},1};
    RequestProbeEnvironment environment={0};environment.iface.lpVtbl=&request_environment_vtable;environment.response.iface.lpVtbl=&request_response_vtable;environment.response.refs=1;
    s->environment=&environment.iface;s->denied_response=&denied.iface;
    FileBudget *budget=zwv_file_budget_create(1);if(!budget){s->environment=NULL;s->denied_response=NULL;release(s);return 1;}
    RequestProbeArgs args;request_args_init(&args);ResourceCall call={s,&args.iface,FALSE,FALSE};FileControl *ticket=NULL;
    if(FAILED(zwv_defer_resource(&call,777)))failed++;
    environment.result=E_OUTOFMEMORY;
    if(zwv_respond_file_deferred(s,777,fixture->file,fixture->size,budget,200,"text/plain",10,NULL,0,TRUE,&ticket)!=E_OUTOFMEMORY||ticket||args.deferral.completed!=1||args.response!=&denied.iface||file_fixture_counts().physical||file_fixture_counts().controls)failed++;
    environment.result=S_OK;call.responded=FALSE;args.put_hr=E_FAIL;
    if(zwv_respond_file(&call,fixture->file,fixture->size,budget,200,"text/plain",10,NULL,0,TRUE,&ticket)!=E_FAIL||ticket||call.responded||args.response!=&denied.iface||file_fixture_counts().physical||file_fixture_counts().controls)failed++;
    args.put_hr=S_OK;request_args_clear(&args);request_args_init(&args);call.responded=FALSE;
    ICoreWebView2DeferralVtbl complete_failure=request_deferral_vtable;complete_failure.Complete=file_complete_failure;args.deferral.iface.lpVtbl=&complete_failure;
    if(FAILED(zwv_defer_resource(&call,778)))failed++;
    if(zwv_respond_file_deferred(s,778,fixture->file,fixture->size,budget,200,"text/plain",10,NULL,0,TRUE,&ticket)!=E_FAIL||ticket||args.deferral.completed!=1||owned_resource_deferrals||file_fixture_counts().physical)failed++;
    file_controls_close(s);
    request_args_clear(&args);request_args_init(&args);call.responded=FALSE;args.deferral.iface.lpVtbl=&complete_failure;
    if(FAILED(zwv_defer_resource(&call,779)))failed++;
    if(zwv_respond_file_deferred(s,779,fixture->file,fixture->size,budget,200,"text/plain",10,NULL,0,FALSE,&ticket)!=E_FAIL||ticket||args.deferral.completed!=1||owned_resource_deferrals||file_fixture_counts().physical)failed++;
    if(!s->file_controls[0]||!InterlockedCompareExchange(&s->file_controls[0]->cancelled,0,0))failed++;
    file_controls_close(s);
    environment.result=S_OK;call.responded=FALSE;call.head=TRUE;
    if(FAILED(zwv_respond_file(&call,fixture->file,fixture->size,budget,200,"text/plain",10,NULL,0,TRUE,&ticket))||ticket||environment.body_size||!wcsstr(environment.headers,L"Content-Length: 4096\r\n"))failed++;
    call.responded=FALSE;call.head=FALSE;
    if(zwv_respond_file(&call,fixture->file,fixture->size,budget,204,"text/plain",10,NULL,0,FALSE,&ticket)!=E_INVALIDARG||call.responded)failed++;
    for(unsigned status=204;status<=304;status+=100){
        call.responded=FALSE;
        if(FAILED(zwv_respond_file(&call,fixture->file,0,budget,status,"text/plain",10,NULL,0,FALSE,&ticket))||wcsstr(environment.headers,L"Content-Length:"))failed++;
    }
    for(unsigned i=0;i<20;i++){
        call.responded=FALSE;
        if(FAILED(zwv_respond_file(&call,fixture->file,fixture->size,budget,200,"text/plain",10,NULL,0,FALSE,&ticket))||file_fixture_counts().physical||file_fixture_counts().controls!=1)failed++;
    }
    request_args_clear(&args);file_controls_close(s);
    FileReentryEnvironment reentry={0};reentry.base.iface.lpVtbl=&file_reentry_vtable;reentry.base.response.iface.lpVtbl=&request_response_vtable;reentry.base.response.refs=1;reentry.state=s;
    s->environment=&reentry.base.iface;
    for(unsigned kind=1;kind<=2;kind++){
        reentry.kind=kind;s->closed=FALSE;call.responded=FALSE;
        if(zwv_respond_file(&call,fixture->file,fixture->size,budget,200,"text/plain",10,NULL,0,TRUE,&ticket)!=E_ABORT||call.responded||ticket||args.response||file_fixture_counts().physical||file_fixture_counts().controls)failed++;
    }
    file_controls_close(s);request_args_clear(&args);zwv_file_budget_release(budget);
    s->environment=NULL;s->denied_response=NULL;release(s);
    if(file_fixture_counts().physical||file_fixture_counts().controls||file_fixture_counts().budgets)failed++;
    return failed;
}
static int file_stream_abi_cases(void) {
    FileFixture fixture={0};HANDLE worker=CreateThread(NULL,0,file_fixture_worker,&fixture,0,NULL);if(!worker)return 1;
    if(WaitForSingleObject(worker,10000)!=WAIT_OBJECT_0)abort();CloseHandle(worker);
    int failed=FAILED(fixture.result)?1:0;HRESULT initialized=CoInitializeEx(NULL,COINIT_APARTMENTTHREADED);
    if(FAILED(initialized))failed++;
    else {if(!failed){failed+=file_capacity_cases(&fixture);failed+=file_pending_cancel_case(&fixture);failed+=file_response_cases(&fixture);}CoUninitialize();}
    fixture.cleanup=TRUE;worker=CreateThread(NULL,0,file_fixture_worker,&fixture,0,NULL);if(!worker)abort();
    if(WaitForSingleObject(worker,10000)!=WAIT_OBJECT_0)abort();CloseHandle(worker);if(FAILED(fixture.result))failed++;
    if(failed)fprintf(stderr,"file stream physical-capacity/EOF/cancel/cursor/response ABI failures=%d\n",failed);
    return failed;
}
