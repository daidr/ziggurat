#include "windows_file.h"
#include "windows_physical.h"
#include "windows_producer_internal.h"
#include <stdlib.h>
#include <string.h>
struct ZwsFilePump {LONG refs;ZwsChannel *channel;HANDLE file,event;uint64_t offset;};
#ifdef ZWS_TESTING
static LONG pumps;
static LONG64 reads;
uint32_t zws_file_pump_count(void){return (uint32_t)InterlockedCompareExchange(&pumps,0,0);}
uint64_t zws_file_read_count(void){return (uint64_t)InterlockedCompareExchange64(&reads,0,0);}
#endif
int zws_file_prepare(uint64_t main_thread,HANDLE borrowed,uint64_t maximum,
    int window,uint64_t offset,uint64_t length,ZwsChannel **source,ZwsFilePump **pump,uint32_t *error){
    if(error)*error=0;if(!source||!pump)return ZWS_INVALID;*source=NULL;*pump=NULL;
    if(GetCurrentThreadId()==main_thread)return ZWS_UI_THREAD;
    if(main_thread>UINT32_MAX||!maximum||maximum>ZWS_MAX_BYTES)return ZWS_INVALID;
    HANDLE file=ReOpenFile(borrowed,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_DELETE,FILE_FLAG_OVERLAPPED);
    if(file==INVALID_HANDLE_VALUE){if(error)*error=GetLastError();return ZWS_IO;}
    int result=ZWS_OK;BY_HANDLE_FILE_INFORMATION info;LARGE_INTEGER actual;
    if(GetFileType(file)!=FILE_TYPE_DISK){result=ZWS_REGULAR;goto failed_file;}
    if(!GetFileInformationByHandle(file,&info)){if(error)*error=GetLastError();result=ZWS_IO;goto failed_file;}
    if(info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY){result=ZWS_REGULAR;goto failed_file;}
    if(!GetFileSizeEx(file,&actual)){if(error)*error=GetLastError();result=ZWS_IO;goto failed_file;}
    if(actual.QuadPart<0||(uint64_t)actual.QuadPart>maximum){result=ZWS_TOO_LARGE;goto failed_file;}
    uint64_t whole=(uint64_t)actual.QuadPart;
    if(!window){offset=0;length=whole;}
    if(offset>whole||length>whole-offset){result=ZWS_WINDOW;goto failed_file;}
    ZwsFilePump *p=zws_native_alloc(sizeof(*p));if(!p){result=ZWS_OOM;goto failed_file;}
    p->file=file;p->offset=offset;p->refs=1;p->event=CreateEventW(NULL,TRUE,FALSE,NULL);
    if(!p->event){if(error)*error=GetLastError();result=ZWS_IO;goto failed_pump;}
    result=zws_channel_prepare(main_thread,length,maximum,ZWS_FILE_PUMP,source,&p->channel,error);
    if(result)goto failed_pump;
#ifdef ZWS_TESTING
    InterlockedIncrement(&pumps);
#endif
    *pump=p;return ZWS_OK;
failed_pump:
    if(p->event)CloseHandle(p->event);SecureZeroMemory(p,sizeof(*p));free(p);
failed_file:
    CloseHandle(file);return result;
}
void zws_file_pump_add(ZwsFilePump *p){InterlockedIncrement(&p->refs);}
static void release(ZwsFilePump *p){
    if(InterlockedDecrement(&p->refs))return;
    ZwsChannel *channel=p->channel;p->channel=NULL;
    CloseHandle(p->file);CloseHandle(p->event);SecureZeroMemory(p,sizeof(*p));free(p);
#ifdef ZWS_TESTING
    InterlockedDecrement(&pumps);
#endif
    /* The physical pin covers actual file/event/wrapper retirement. Source
     * late references retain only the channel and never this file payload. */
    zws_producer_release(channel);
}
void zws_file_pump_release(ZwsFilePump *p){if(p){zws_producer_cancel_unfinished(p->channel);release(p);}}
int zws_file_pump(ZwsFilePump *p,uint32_t *error){
    if(error)*error=0;if(!p)return ZWS_INVALID;zws_file_pump_add(p);
    int head=0,result=zws_producer_begin_kind(p->channel,ZWS_FILE_PUMP,&head,error);
    if(result)goto finished;
    if(head){result=zws_producer_finish_kind(p->channel,ZWS_FILE_PUMP,error);goto finished;}
    uint64_t length=zws_channel_length(p->channel),done=0;unsigned char bytes[ZWS_CHUNK_BYTES];
    while(done<length){
        DWORD cancellation=WaitForSingleObject(zws_channel_cancel_event(p->channel),0);
        if(cancellation==WAIT_OBJECT_0){result=zws_producer_fail_kind(p->channel,ZWS_FILE_PUMP,ZWS_CANCELLED,0);break;}
        if(cancellation==WAIT_FAILED){DWORD code=GetLastError();if(error)*error=code;result=zws_producer_fail_kind(p->channel,ZWS_FILE_PUMP,ZWS_IO,code);break;}
        DWORD chunk=(DWORD)(length-done);if(chunk>sizeof(bytes))chunk=sizeof(bytes);
        OVERLAPPED operation={0};uint64_t position=p->offset+done;
        operation.Offset=(DWORD)position;operation.OffsetHigh=(DWORD)(position>>32);operation.hEvent=p->event;ResetEvent(p->event);
        DWORD got=0;
#ifdef ZWS_TESTING
        InterlockedIncrement64(&reads);
#endif
        BOOL ok=ReadFile(p->file,bytes,chunk,NULL,&operation);DWORD code=ok?ERROR_SUCCESS:GetLastError(),wait_error=0;int cancelled=0;
        if(ok){ok=GetOverlappedResult(p->file,&operation,&got,FALSE);code=ok?ERROR_SUCCESS:GetLastError();}
        if(!ok&&(code==ERROR_IO_PENDING||code==ERROR_IO_INCOMPLETE)){
            HANDLE events[2]={zws_channel_cancel_event(p->channel),p->event};DWORD waited=WaitForMultipleObjects(2,events,FALSE,INFINITE);
            if(waited==WAIT_FAILED)wait_error=GetLastError();cancelled=waited==WAIT_OBJECT_0;
            if(cancelled||wait_error)CancelIoEx(p->file,&operation);
            ok=GetOverlappedResult(p->file,&operation,&got,TRUE);code=ok?ERROR_SUCCESS:GetLastError();
        }
        if(wait_error){if(error)*error=wait_error;result=zws_producer_fail_kind(p->channel,ZWS_FILE_PUMP,ZWS_IO,wait_error);break;}
        if(cancelled){result=zws_producer_fail_kind(p->channel,ZWS_FILE_PUMP,ZWS_CANCELLED,0);break;}
        if(!ok){
            if(code==ERROR_HANDLE_EOF)result=zws_producer_fail_kind(p->channel,ZWS_FILE_PUMP,ZWS_SOURCE_CHANGED,0);
            else{if(error)*error=code;result=zws_producer_fail_kind(p->channel,ZWS_FILE_PUMP,ZWS_IO,code);}break;
        }
        if(!got){result=zws_producer_fail_kind(p->channel,ZWS_FILE_PUMP,ZWS_SOURCE_CHANGED,0);break;}
        result=zws_producer_write_kind(p->channel,ZWS_FILE_PUMP,bytes,got,error);if(result)break;done+=got;
    }
    if(!result)result=zws_producer_finish_kind(p->channel,ZWS_FILE_PUMP,error);
    SecureZeroMemory(bytes,sizeof(bytes));
finished:
    release(p);return result;
}
