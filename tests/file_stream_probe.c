/* Isolated Runtime experiment; this translation unit replaces the ordinary
 * adapter only for this executable. No production stream API is exposed. */
#include "../src/webview/webview2.c"
#include <objidl.h>
#include <limits.h>

typedef struct ProbeStream {
    IStream iface;
    LONG refs, cancelled;
    SRWLOCK lock;
    HANDLE file;
    uint64_t size, position;
    DWORD ui_thread;
    IUnknown *marshaler;
    HANDLE cancel_event, read_entered;
    LONG block_once;
} ProbeStream;
typedef struct ProbeStats {
    uint32_t live, reads, ui_reads, worker_reads, max_request, max_disk_read;
    uint64_t bytes;
    uint32_t last_read_thread, last_release_thread;
} ProbeStats;
static LONG probe_live, probe_reads, probe_ui_reads, probe_worker_reads;
static LONG probe_max_request, probe_max_disk_read, probe_last_read_thread, probe_last_release_thread;
static LONG64 probe_bytes;
static const IID probe_agile = {0x94ea2b94,0xe9cc,0x49e0,{0xc0,0xff,0xee,0x64,0xca,0x8f,0x5b,0x90}};
static void probe_max(LONG *target,ULONG value) {
    LONG desired=(LONG)(value>LONG_MAX?LONG_MAX:value),old=InterlockedCompareExchange(target,0,0);
    while (desired>old) { LONG observed=InterlockedCompareExchange(target,desired,old);if (observed==old) break;old=observed; }
}
static ULONG STDMETHODCALLTYPE probe_add(IStream *iface) {
    return (ULONG)InterlockedIncrement(&((ProbeStream *)iface)->refs);
}
static ULONG STDMETHODCALLTYPE probe_release(IStream *iface) {
    ProbeStream *stream=(ProbeStream *)iface;
    LONG refs=InterlockedDecrement(&stream->refs);
    if (!refs) {
        if (stream->marshaler) IUnknown_Release(stream->marshaler);
        if (stream->read_entered) CloseHandle(stream->read_entered);
        CloseHandle(stream->cancel_event);
        CloseHandle(stream->file);
        free(stream);
        InterlockedExchange(&probe_last_release_thread,(LONG)GetCurrentThreadId());
        InterlockedDecrement(&probe_live);
    }
    return (ULONG)refs;
}
static HRESULT STDMETHODCALLTYPE probe_query(IStream *iface,REFIID iid,void **out) {
    if (!out) return E_POINTER;
    *out=NULL;
    if (IsEqualIID(iid,&IID_IUnknown)||IsEqualIID(iid,&IID_ISequentialStream)||IsEqualIID(iid,&IID_IStream)||IsEqualIID(iid,&probe_agile)) {
        *out=iface;probe_add(iface);return S_OK;
    }
    ProbeStream *stream=(ProbeStream *)iface;
    if (IsEqualIID(iid,&IID_IMarshal)&&stream->marshaler) return IUnknown_QueryInterface(stream->marshaler,iid,out);
    return E_NOINTERFACE;
}
static HRESULT STDMETHODCALLTYPE probe_read(IStream *iface,void *buffer,ULONG count,ULONG *read) {
    ProbeStream *stream=(ProbeStream *)iface;
    if (read) *read=0;
    if (!count) return S_OK;
    if (!buffer) return STG_E_INVALIDPOINTER;
    DWORD thread=GetCurrentThreadId();
    InterlockedIncrement(&probe_reads);probe_max(&probe_max_request,count);
    InterlockedExchange(&probe_last_read_thread,(LONG)thread);
    if (thread==stream->ui_thread) { InterlockedIncrement(&probe_ui_reads);return E_UNEXPECTED; }
    InterlockedIncrement(&probe_worker_reads);
    if (InterlockedExchange(&stream->block_once,0)) {
        SetEvent(stream->read_entered);
        if (WaitForSingleObject(stream->cancel_event,10000)!=WAIT_OBJECT_0) return STG_E_READFAULT;
    }
    AcquireSRWLockExclusive(&stream->lock);
    HRESULT hr=S_OK;ULONG done=0;
    while (done<count) {
        if (InterlockedCompareExchange(&stream->cancelled,0,0)) { hr=STG_E_REVERTED;break; }
        if (stream->position>=stream->size) { hr=S_FALSE;break; }
        ULONG chunk=(ULONG)((stream->size-stream->position)>65536?65536:(stream->size-stream->position));
        if (chunk>count-done) chunk=count-done;
        LARGE_INTEGER offset;offset.QuadPart=(LONGLONG)stream->position;
        if (!SetFilePointerEx(stream->file,offset,NULL,FILE_BEGIN)) { hr=HRESULT_FROM_WIN32(GetLastError());break; }
        DWORD got=0;probe_max(&probe_max_disk_read,chunk);
        if (!ReadFile(stream->file,(BYTE *)buffer+done,chunk,&got,NULL)) { hr=HRESULT_FROM_WIN32(GetLastError());break; }
        if (!got) { hr=STG_E_READFAULT;break; }
        stream->position+=got;done+=got;InterlockedAdd64(&probe_bytes,got);
    }
    ReleaseSRWLockExclusive(&stream->lock);
    if (read) *read=done;
    return hr;
}
static HRESULT STDMETHODCALLTYPE probe_write(IStream *p,const void *b,ULONG n,ULONG *w) { (void)p;(void)b;(void)n;if(w)*w=0;return STG_E_ACCESSDENIED; }
static HRESULT STDMETHODCALLTYPE probe_seek(IStream *iface,LARGE_INTEGER move,DWORD origin,ULARGE_INTEGER *position) {
    ProbeStream *stream=(ProbeStream *)iface;
    if (origin>STREAM_SEEK_END) return STG_E_INVALIDFUNCTION;
    if (GetCurrentThreadId()==stream->ui_thread) {
        if (!TryAcquireSRWLockExclusive(&stream->lock)) return E_PENDING;
    } else AcquireSRWLockExclusive(&stream->lock);
    uint64_t base=origin==STREAM_SEEK_SET?0:origin==STREAM_SEEK_CUR?stream->position:stream->size;
    HRESULT hr=S_OK;uint64_t next=base;
    if (move.QuadPart<0) {
        uint64_t amount=(uint64_t)(-(move.QuadPart+1))+1;
        if (amount>base) hr=STG_E_INVALIDFUNCTION;else next=base-amount;
    } else if ((uint64_t)move.QuadPart>UINT64_MAX-base) hr=STG_E_INVALIDFUNCTION;
    else next=base+(uint64_t)move.QuadPart;
    if (SUCCEEDED(hr)) { stream->position=next;if(position)position->QuadPart=next; }
    ReleaseSRWLockExclusive(&stream->lock);return hr;
}
static HRESULT STDMETHODCALLTYPE probe_resize(IStream *p,ULARGE_INTEGER s) { (void)p;(void)s;return STG_E_ACCESSDENIED; }
static HRESULT STDMETHODCALLTYPE probe_copy(IStream *p,IStream *q,ULARGE_INTEGER n,ULARGE_INTEGER *r,ULARGE_INTEGER *w) { (void)p;(void)q;(void)n;if(r)r->QuadPart=0;if(w)w->QuadPart=0;return STG_E_INVALIDFUNCTION; }
static HRESULT STDMETHODCALLTYPE probe_commit(IStream *p,DWORD f) { (void)p;(void)f;return STG_E_ACCESSDENIED; }
static HRESULT STDMETHODCALLTYPE probe_revert(IStream *p) { (void)p;return STG_E_ACCESSDENIED; }
static HRESULT STDMETHODCALLTYPE probe_region(IStream *p,ULARGE_INTEGER a,ULARGE_INTEGER b,DWORD f) { (void)p;(void)a;(void)b;(void)f;return STG_E_INVALIDFUNCTION; }
static HRESULT STDMETHODCALLTYPE probe_stat(IStream *iface,STATSTG *stat,DWORD flags) {
    (void)flags;if(!stat)return STG_E_INVALIDPOINTER;
    ProbeStream *stream=(ProbeStream *)iface;memset(stat,0,sizeof(*stat));
    stat->type=STGTY_STREAM;stat->cbSize.QuadPart=stream->size;stat->grfMode=STGM_READ;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE probe_clone(IStream *p,IStream **out) { (void)p;if(out)*out=NULL;return STG_E_INVALIDFUNCTION; }
static IStreamVtbl probe_vtable={probe_query,probe_add,probe_release,probe_read,probe_write,probe_seek,probe_resize,probe_copy,probe_commit,probe_revert,probe_region,probe_region,probe_stat,probe_clone};

/* Takes the prepared private file handle only on success. No file operation is
 * performed here: length and contents were established by the explicit worker. */
HRESULT zwv_probe_file_create(HANDLE file,uint64_t size,IStream **out) {
    if (!out) return E_POINTER;*out=NULL;
    if (!file||file==INVALID_HANDLE_VALUE||!size||size>16u*1024u*1024u) return E_INVALIDARG;
    ProbeStream *stream=calloc(1,sizeof(*stream));if(!stream)return E_OUTOFMEMORY;
    stream->iface.lpVtbl=&probe_vtable;stream->refs=1;stream->file=file;stream->size=size;stream->ui_thread=GetCurrentThreadId();InitializeSRWLock(&stream->lock);
    stream->cancel_event=CreateEventW(NULL,TRUE,FALSE,NULL);
    if (!stream->cancel_event) { HRESULT hr=HRESULT_FROM_WIN32(GetLastError());free(stream);return hr; }
    HRESULT hr=CoCreateFreeThreadedMarshaler((IUnknown *)&stream->iface,&stream->marshaler);
    if (FAILED(hr)) { CloseHandle(stream->cancel_event);free(stream);return hr; }
    InterlockedIncrement(&probe_live);*out=&stream->iface;return S_OK;
}
HRESULT zwv_probe_respond(ResourceCall *call,IStream *stream,uint64_t size) {
    if (!call||call->responded||call->state->closed||!stream) return E_ABORT;
    WCHAR headers[256];_snwprintf(headers,256,L"Content-Type: application/octet-stream\r\nContent-Length: %llu\r\nCache-Control: no-store\r\n",(unsigned long long)size);
    ICoreWebView2WebResourceResponse *response=NULL;
    HRESULT hr=ICoreWebView2Environment_CreateWebResourceResponse(call->state->environment,stream,200,L"OK",headers,&response);
    if (SUCCEEDED(hr)) {
        hr=ICoreWebView2WebResourceRequestedEventArgs_put_Response(call->args,response);
        ICoreWebView2WebResourceResponse_Release(response);
        if(SUCCEEDED(hr))call->responded=TRUE;
    }
    return hr;
}
HRESULT zwv_probe_marshal(IStream *stream,IStream **marshal) { return CoMarshalInterThreadInterfaceInStream(&IID_IStream,(IUnknown *)stream,marshal); }
/* The explicit MTA owns the unmarshaled reference before detach and keeps it
 * until its caller opens the test gate. No application pointer crosses COM. */
HRESULT zwv_probe_mta_enter(IStream *marshal,IStream **out) {
    HRESULT hr=CoInitializeEx(NULL,COINIT_MULTITHREADED);if(FAILED(hr))return hr;
    hr=CoGetInterfaceAndReleaseStream(marshal,&IID_IStream,(void **)out);
    if(FAILED(hr))CoUninitialize();
    return hr;
}
HRESULT zwv_probe_mta_finish(IStream *stream) {
    LARGE_INTEGER zero;zero.QuadPart=0;HRESULT hr=IStream_Seek(stream,zero,STREAM_SEEK_SET,NULL);
    if(SUCCEEDED(hr)) { BYTE byte;ULONG got=123;hr=IStream_Read(stream,&byte,1,&got);if(hr==STG_E_REVERTED&&got==0)hr=S_OK;else hr=E_UNEXPECTED; }
    IStream_Release(stream);CoUninitialize();return hr;
}
HRESULT zwv_probe_block_read(IStream *iface,HANDLE entered) {
    ProbeStream *stream=(ProbeStream *)iface;
    if (!DuplicateHandle(GetCurrentProcess(),entered,GetCurrentProcess(),&stream->read_entered,EVENT_MODIFY_STATE,FALSE,0)) return HRESULT_FROM_WIN32(GetLastError());
    InterlockedExchange(&stream->block_once,1);return S_OK;
}
void zwv_probe_cancel(IStream *iface) {
    ProbeStream *stream=(ProbeStream *)iface;
    InterlockedExchange(&stream->cancelled,1);SetEvent(stream->cancel_event);
}
void zwv_probe_release(IStream *iface) { IStream_Release(iface); }
HRESULT zwv_probe_reset(void) {
    if(InterlockedCompareExchange(&probe_live,0,0))return E_UNEXPECTED;
    probe_reads=probe_ui_reads=probe_worker_reads=probe_max_request=probe_max_disk_read=probe_last_read_thread=probe_last_release_thread=0;probe_bytes=0;return S_OK;
}
void zwv_probe_stats(ProbeStats *out) {
    *out=(ProbeStats){(uint32_t)InterlockedCompareExchange(&probe_live,0,0),(uint32_t)InterlockedCompareExchange(&probe_reads,0,0),(uint32_t)InterlockedCompareExchange(&probe_ui_reads,0,0),(uint32_t)InterlockedCompareExchange(&probe_worker_reads,0,0),(uint32_t)InterlockedCompareExchange(&probe_max_request,0,0),(uint32_t)InterlockedCompareExchange(&probe_max_disk_read,0,0),(uint64_t)InterlockedCompareExchange64(&probe_bytes,0,0),(uint32_t)InterlockedCompareExchange(&probe_last_read_thread,0,0),(uint32_t)InterlockedCompareExchange(&probe_last_release_thread,0,0)};
}
