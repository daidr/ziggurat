#ifndef ZIGGURAT_WINDOWS_ISTREAM_H
#define ZIGGURAT_WINDOWS_ISTREAM_H
#include <objidl.h>
#include <stdlib.h>
#include <string.h>
#include "windows_physical.h"
#define FILE_STREAM_LIMIT ZWS_CONSUMER_LIMIT
#define FILE_STREAM_PROCESS_LIMIT ZWS_PROCESS_LIMIT
#define FILE_STREAM_MAX_BYTES ZWS_MAX_BYTES
typedef ZwsBudget FileBudget;
typedef struct FileControl FileControl;
typedef struct FileStream {
    IStream iface;
    ZwsPhysical physical;
    SRWLOCK lock;
    HANDLE file,io_event;
    uint64_t size,position;
    IUnknown *marshaler;
} FileStream;
static const IID file_agile_iid={0x94ea2b94,0xe9cc,0x49e0,{0xc0,0xff,0xee,0x64,0xca,0x8f,0x5b,0x90}};
HRESULT zwv_file_prepare(HANDLE borrowed,uint64_t maximum,HANDLE *output,uint64_t *length) {
    if(!output||!length)return E_POINTER;*output=NULL;*length=0;
    if(!maximum||maximum>FILE_STREAM_MAX_BYTES)return E_INVALIDARG;
    HANDLE file=ReOpenFile(borrowed,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_DELETE,FILE_FLAG_OVERLAPPED);
    if(file==INVALID_HANDLE_VALUE)return HRESULT_FROM_WIN32(GetLastError());
    HRESULT hr=S_OK;BY_HANDLE_FILE_INFORMATION info;LARGE_INTEGER size;
    if(GetFileType(file)!=FILE_TYPE_DISK)hr=HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED);
    else if(!GetFileInformationByHandle(file,&info))hr=HRESULT_FROM_WIN32(GetLastError());
    else if(info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)hr=HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED);
    else if(!GetFileSizeEx(file,&size))hr=HRESULT_FROM_WIN32(GetLastError());
    else if(size.QuadPart<0||(uint64_t)size.QuadPart>maximum)hr=HRESULT_FROM_WIN32(ERROR_FILE_TOO_LARGE);
    if(FAILED(hr)){CloseHandle(file);return hr;}
    *length=(uint64_t)size.QuadPart;*output=file;return S_OK;
}
void zwv_file_close(HANDLE file) { CloseHandle(file); }
FileBudget *zwv_file_budget_create(uint32_t limit){return zws_budget_create(limit);}
void zwv_file_budget_limit(FileBudget *budget,uint32_t limit){(void)zws_budget_limit(budget,limit);}
void zwv_file_budget_release(FileBudget *budget){zws_budget_release(budget);}
void zwv_file_control_add(FileControl *control){zws_control_add(control);}
void zwv_file_control_release(FileControl *control){zws_control_release(control);}
void zwv_file_control_cancel(FileControl *control){zws_control_cancel(control);}
static ULONG STDMETHODCALLTYPE file_stream_add(IStream *iface){return (ULONG)InterlockedIncrement(&((FileStream *)iface)->physical.refs);}
static ULONG STDMETHODCALLTYPE file_stream_release(IStream *iface){
    FileStream *stream=(FileStream *)iface;LONG refs=InterlockedDecrement(&stream->physical.refs);
    if(!refs){
        ZwsRetirement retired=zws_physical_withdraw(&stream->physical);
        IUnknown *marshaler=stream->marshaler;stream->marshaler=NULL;
        HANDLE file=stream->file,event=stream->io_event;stream->file=stream->io_event=NULL;
        IUnknown_Release(marshaler);CloseHandle(file);CloseHandle(event);
        free(stream);zws_physical_retire(retired);
    }return (ULONG)refs;
}
static HRESULT STDMETHODCALLTYPE file_stream_query(IStream *iface,REFIID iid,void **out) {
    if(!out)return E_POINTER;*out=NULL;
    if(IsEqualIID(iid,&IID_IUnknown)||IsEqualIID(iid,&IID_ISequentialStream)||IsEqualIID(iid,&IID_IStream)||IsEqualIID(iid,&file_agile_iid)){
        *out=iface;file_stream_add(iface);return S_OK;
    }
    if(IsEqualIID(iid,&IID_IMarshal)&&((FileStream *)iface)->marshaler)return IUnknown_QueryInterface(((FileStream *)iface)->marshaler,iid,out);
    return E_NOINTERFACE;
}
/* An overlapped operation keeps its stack OVERLAPPED and caller buffer alive
 * until the kernel confirms completion, including after cancellation. This
 * entire path is forbidden on the creator/UI thread. */
static HRESULT STDMETHODCALLTYPE file_stream_read(IStream *iface,void *buffer,ULONG count,ULONG *read) {
    FileStream *stream=(FileStream *)iface;if(read)*read=0;
    if(!count)return S_OK;if(!buffer)return STG_E_INVALIDPOINTER;
    if(GetCurrentThreadId()==stream->physical.ui_thread)return E_UNEXPECTED;
    AcquireSRWLockExclusive(&stream->lock);
    ULONG done=0;HRESULT hr=S_OK;
    while(done<count){
        if(InterlockedCompareExchange(&stream->physical.control->cancelled,0,0)){hr=STG_E_REVERTED;break;}
        if(stream->position>=stream->size){hr=S_FALSE;break;}
        DWORD chunk=(DWORD)((stream->size-stream->position)>65536?65536:stream->size-stream->position);
        if(chunk>count-done)chunk=count-done;
        OVERLAPPED operation;memset(&operation,0,sizeof(operation));
        operation.Offset=(DWORD)stream->position;operation.OffsetHigh=(DWORD)(stream->position>>32);operation.hEvent=stream->io_event;
        ResetEvent(stream->io_event);
        DWORD got=0;BOOL ok=ReadFile(stream->file,(BYTE *)buffer+done,chunk,NULL,&operation);
        DWORD error=ok?ERROR_SUCCESS:GetLastError(),wait_error=0;BOOL was_cancelled=FALSE;
        if(ok){ok=GetOverlappedResult(stream->file,&operation,&got,FALSE);error=ok?ERROR_SUCCESS:GetLastError();}
        if(!ok&&(error==ERROR_IO_PENDING||error==ERROR_IO_INCOMPLETE)){
            HANDLE events[2]={stream->physical.control->cancel_event,stream->io_event};
            DWORD waited=WaitForMultipleObjects(2,events,FALSE,INFINITE);
            if(waited==WAIT_FAILED)wait_error=GetLastError();
            was_cancelled=waited==WAIT_OBJECT_0;
            if(was_cancelled||waited==WAIT_FAILED)CancelIoEx(stream->file,&operation);
            /* Even a failed wait/cancel must drain the actual IO before its
               OVERLAPPED or caller-owned output memory can leave this frame. */
            ok=GetOverlappedResult(stream->file,&operation,&got,TRUE);error=ok?ERROR_SUCCESS:GetLastError();
        }
        if(ok){stream->position+=got;done+=got;}
        if(wait_error){hr=HRESULT_FROM_WIN32(wait_error);break;}
        if(was_cancelled||InterlockedCompareExchange(&stream->physical.control->cancelled,0,0)){hr=STG_E_REVERTED;break;}
        if(!ok){hr=error==ERROR_HANDLE_EOF?S_FALSE:HRESULT_FROM_WIN32(error);break;}
        if(!got){hr=STG_E_READFAULT;break;}
    }
    ReleaseSRWLockExclusive(&stream->lock);if(read)*read=done;return hr;
}
static HRESULT STDMETHODCALLTYPE file_stream_write(IStream *p,const void *b,ULONG n,ULONG *w){(void)p;(void)b;(void)n;if(w)*w=0;return STG_E_ACCESSDENIED;}
static HRESULT STDMETHODCALLTYPE file_stream_seek(IStream *iface,LARGE_INTEGER move,DWORD origin,ULARGE_INTEGER *position) {
    FileStream *stream=(FileStream *)iface;if(origin>STREAM_SEEK_END)return STG_E_INVALIDFUNCTION;
    if(GetCurrentThreadId()==stream->physical.ui_thread){if(!TryAcquireSRWLockExclusive(&stream->lock))return E_PENDING;}
    else AcquireSRWLockExclusive(&stream->lock);
    uint64_t base=origin==STREAM_SEEK_SET?0:origin==STREAM_SEEK_CUR?stream->position:stream->size,next=base;HRESULT hr=S_OK;
    if(move.QuadPart<0){uint64_t amount=(uint64_t)(-(move.QuadPart+1))+1;if(amount>base)hr=STG_E_INVALIDFUNCTION;else next=base-amount;}
    else if((uint64_t)move.QuadPart>INT64_MAX-base||base>INT64_MAX)hr=STG_E_INVALIDFUNCTION;
    else next=base+(uint64_t)move.QuadPart;
    if(SUCCEEDED(hr)){stream->position=next;if(position)position->QuadPart=next;}
    ReleaseSRWLockExclusive(&stream->lock);return hr;
}
static HRESULT STDMETHODCALLTYPE file_stream_resize(IStream *p,ULARGE_INTEGER n){(void)p;(void)n;return STG_E_ACCESSDENIED;}
static HRESULT STDMETHODCALLTYPE file_stream_copy(IStream *p,IStream *q,ULARGE_INTEGER n,ULARGE_INTEGER *r,ULARGE_INTEGER *w){(void)p;(void)q;(void)n;if(r)r->QuadPart=0;if(w)w->QuadPart=0;return STG_E_INVALIDFUNCTION;}
static HRESULT STDMETHODCALLTYPE file_stream_commit(IStream *p,DWORD f){(void)p;(void)f;return STG_E_ACCESSDENIED;}
static HRESULT STDMETHODCALLTYPE file_stream_revert(IStream *p){(void)p;return STG_E_ACCESSDENIED;}
static HRESULT STDMETHODCALLTYPE file_stream_region(IStream *p,ULARGE_INTEGER a,ULARGE_INTEGER b,DWORD f){(void)p;(void)a;(void)b;(void)f;return STG_E_INVALIDFUNCTION;}
static HRESULT STDMETHODCALLTYPE file_stream_stat(IStream *iface,STATSTG *stat,DWORD flags){(void)flags;if(!stat)return STG_E_INVALIDPOINTER;memset(stat,0,sizeof(*stat));stat->type=STGTY_STREAM;stat->cbSize.QuadPart=((FileStream *)iface)->size;stat->grfMode=STGM_READ;return S_OK;}
static HRESULT STDMETHODCALLTYPE file_stream_clone(IStream *p,IStream **out){(void)p;if(out)*out=NULL;return STG_E_INVALIDFUNCTION;}
static IStreamVtbl file_stream_vtable={file_stream_query,file_stream_add,file_stream_release,file_stream_read,file_stream_write,file_stream_seek,file_stream_resize,file_stream_copy,file_stream_commit,file_stream_revert,file_stream_region,file_stream_region,file_stream_stat,file_stream_clone};

static HRESULT file_stream_create(HANDLE source,uint64_t size,FileBudget *budget,IStream **out){
    *out=NULL;if(!source||!budget||size>FILE_STREAM_MAX_BYTES)return E_INVALIDARG;
    if(!zws_budget_reserve(budget))return E_PENDING;
    if(!zws_physical_reserve()){zws_budget_unreserve(budget);return E_PENDING;}
    HRESULT hr=E_OUTOFMEMORY;FileStream *stream=zws_native_alloc(sizeof(*stream));FileControl *control=NULL;
    if(!stream)goto failed;
    uint32_t error=0;int status=zws_control_create(&control,&error);
    if(status){if(status==ZWS_IO)hr=HRESULT_FROM_WIN32(error);goto failed;}
    stream->iface.lpVtbl=&file_stream_vtable;stream->physical.refs=1;stream->physical.binding=2;
    stream->physical.kind=ZWS_DIRECT_FILE;stream->physical.ui_thread=GetCurrentThreadId();
    stream->physical.control=control;stream->physical.budget=budget;
    stream->size=size;InitializeSRWLock(&stream->lock);
    stream->io_event=CreateEventW(NULL,TRUE,FALSE,NULL);
    if(!stream->io_event){hr=HRESULT_FROM_WIN32(GetLastError());goto failed;}
    if(!DuplicateHandle(GetCurrentProcess(),source,GetCurrentProcess(),&stream->file,0,FALSE,DUPLICATE_SAME_ACCESS)){hr=HRESULT_FROM_WIN32(GetLastError());goto failed;}
    hr=CoCreateFreeThreadedMarshaler((IUnknown *)&stream->iface,&stream->marshaler);
    if(FAILED(hr))goto failed;*out=&stream->iface;return S_OK;
failed:
    if(control)InterlockedExchange(&control->alive,0);
    if(stream){if(stream->marshaler)IUnknown_Release(stream->marshaler);if(stream->file)CloseHandle(stream->file);if(stream->io_event)CloseHandle(stream->io_event);free(stream);}
    if(control)zws_control_release(control);zws_physical_unreserve();zws_budget_unreserve(budget);return hr;
}
#endif
