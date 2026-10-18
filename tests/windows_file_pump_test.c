#define COBJMACROS
#include "../src/file_stream/windows_istream.h"
#include "../src/file_stream/windows_file.h"
#include <stdio.h>
#define REQUIRE(x) do{if(!(x)){fprintf(stderr,"file pump line %d: %s\n",__LINE__,#x);fflush(stderr);ExitProcess(1);}}while(0)
#include "windows_file_fixture.h"
typedef struct Job {
    DWORD main;HANDLE borrowed,ready,go,done,retire;
    uint64_t maximum,offset,length;int window,hold,prepared,result;
    uint32_t error;ZwsChannel *source;ZwsFilePump *pump;
} Job;
static DWORD WINAPI produce_file(void *context){
    Job *j=context;j->prepared=zws_file_prepare(j->main,j->borrowed,j->maximum,j->window,j->offset,j->length,&j->source,&j->pump,&j->error);
    SetEvent(j->ready);if(j->prepared){SetEvent(j->done);return 0;}
    REQUIRE(WaitForSingleObject(j->go,10000)==WAIT_OBJECT_0);
    j->result=zws_file_pump(j->pump,&j->error);SetEvent(j->done);
    if(j->hold)REQUIRE(WaitForSingleObject(j->retire,10000)==WAIT_OBJECT_0);
    zws_file_pump_release(j->pump);j->pump=NULL;return 0;
}
static HANDLE start(Job *j,HANDLE borrowed,int window,uint64_t offset,uint64_t length,uint64_t maximum,int hold){
    memset(j,0,sizeof(*j));j->main=GetCurrentThreadId();j->borrowed=borrowed;j->window=window;j->offset=offset;j->length=length;j->maximum=maximum;j->hold=hold;
    j->ready=CreateEventW(NULL,TRUE,FALSE,NULL);j->go=CreateEventW(NULL,TRUE,FALSE,NULL);
    j->done=CreateEventW(NULL,TRUE,FALSE,NULL);j->retire=CreateEventW(NULL,TRUE,FALSE,NULL);REQUIRE(j->ready&&j->go&&j->done&&j->retire);
    HANDLE thread=CreateThread(NULL,0,produce_file,j,0,NULL);REQUIRE(thread);
    REQUIRE(WaitForSingleObject(j->ready,10000)==WAIT_OBJECT_0);return thread;
}
static void join(Job *j,HANDLE thread){
    SetEvent(j->retire);REQUIRE(WaitForSingleObject(thread,10000)==WAIT_OBJECT_0);CloseHandle(thread);
    CloseHandle(j->ready);CloseHandle(j->go);CloseHandle(j->done);CloseHandle(j->retire);
}
typedef struct Read {ZwsReader *reader;uint64_t offset,length;int result;} Read;
static DWORD WINAPI read_channel(void *context){
    Read *r=context;unsigned char bytes[9937];uint64_t at=0;HANDLE events[2];r->result=1;
    zws_reader_wait_handles(r->reader,&events[1],&events[0]);
    for(;;){
        size_t n=0;uint32_t error=0;int result=zws_reader_try_read(r->reader,bytes,sizeof(bytes),&n,&error);
        if(result==ZWS_PENDING){REQUIRE(WaitForMultipleObjects(2,events,FALSE,10000)<WAIT_OBJECT_0+2);continue;}
        if(result==ZWS_EOF){if(at==r->length)r->result=0;return 0;}
        if(result||!n||n>r->length-at)return 0;
        for(size_t i=0;i<n;i++)if(bytes[i]!=pattern(r->offset+at+i))return 0;at+=n;
    }
}
static void zero(void){ZwsCounts c;zws_counts(&c);REQUIRE(!c.physical&&!c.controls&&!c.budgets&&!c.readers&&!c.candidates&&!c.rings&&!zws_file_pump_count());}
static void roundtrip(Fixture *f,int window,uint64_t offset,uint64_t length,int head){
    uint64_t before=zws_file_read_count();Job j;HANDLE thread=start(&j,f->borrowed,window,offset,length,ZWS_MAX_BYTES,1);REQUIRE(j.prepared==0);
    uint64_t expected=window?length:f->length;REQUIRE(zws_channel_length(j.source)==expected);
    ZwsBudget *budget=zws_budget_create(1);REQUIRE(budget);ZwsCandidate *candidate=NULL;
    REQUIRE(zws_candidate_prepare(j.source,budget,head,&candidate)==0);ZwsReader *reader=zws_candidate_reader(candidate);zws_reader_add(reader);
    ZwsControl *control=NULL;zws_candidate_admit(candidate,0,&control);zws_source_release(j.source);j.source=NULL;SetEvent(j.go);
    if(head)REQUIRE(WaitForSingleObject(j.done,10000)==WAIT_OBJECT_0);
    Read reading={reader,window?offset:0,head?0:expected,1};run_worker(read_channel,&reading);REQUIRE(!reading.result);
    REQUIRE(WaitForSingleObject(j.done,10000)==WAIT_OBJECT_0&&j.result==0&&j.error==0);
    zws_reader_release(reader);REQUIRE(zws_budget_live(budget)==1&&zws_control_alive(control)&&zws_file_pump_count()==1);
    join(&j,thread);REQUIRE(zws_budget_live(budget)==0&&!zws_control_alive(control));
    zws_control_release(control);zws_budget_release(budget);
    uint64_t reads=zws_file_read_count()-before;
    if(head||!expected)REQUIRE(reads==0);else REQUIRE(reads>0);
    fprintf(stderr,"Windows file pump: window=%d offset=%llu length=%llu HEAD=%d reads=%llu held producer quota ->0\n",window,(unsigned long long)offset,(unsigned long long)expected,head,(unsigned long long)reads);zero();
}
static void failures(Fixture *f){
    ZwsChannel *source=NULL;ZwsFilePump *pump=NULL;uint32_t error=42;
    REQUIRE(zws_file_prepare(GetCurrentThreadId(),INVALID_HANDLE_VALUE,0,1,UINT64_MAX,1,&source,&pump,&error)==ZWS_UI_THREAD&&!source&&!pump&&!error);
    Job j;HANDLE thread=start(&j,f->borrowed,1,UINT64_MAX,1,ZWS_MAX_BYTES,0);
    REQUIRE(j.prepared==ZWS_WINDOW&&!j.source&&!j.pump&&!j.error);join(&j,thread);zero();
    thread=start(&j,f->borrowed,1,0,0,7,0);
    REQUIRE(j.prepared==ZWS_TOO_LARGE&&!j.source&&!j.pump&&!j.error);join(&j,thread);zero();
    for(int i=0;i<4;i++){
        zws_test_fail_after(i);thread=start(&j,f->borrowed,0,0,0,ZWS_MAX_BYTES,0);
        REQUIRE(j.prepared==ZWS_OOM&&!j.source&&!j.pump&&!j.error);join(&j,thread);zero();
    }zws_test_fail_after(-1);
}
static void blocked_cancel(Fixture *f){
    Job j;HANDLE thread=start(&j,f->borrowed,0,0,0,ZWS_MAX_BYTES,1);REQUIRE(j.prepared==0);
    ZwsBudget *budget=zws_budget_create(1);REQUIRE(budget);ZwsCandidate *candidate=NULL;
    REQUIRE(zws_candidate_prepare(j.source,budget,0,&candidate)==0);ZwsReader *reader=zws_candidate_reader(candidate);zws_reader_add(reader);
    ZwsControl *control=NULL;zws_candidate_admit(candidate,0,&control);zws_source_release(j.source);j.source=NULL;
    HANDLE waiting=CreateEventW(NULL,TRUE,FALSE,NULL);REQUIRE(waiting);zws_test_capacity_wait(waiting);SetEvent(j.go);
    REQUIRE(WaitForSingleObject(waiting,10000)==WAIT_OBJECT_0&&zws_test_waiting_writers()==1);
    zws_control_cancel(control);REQUIRE(WaitForSingleObject(j.done,10000)==WAIT_OBJECT_0&&j.result==ZWS_CANCELLED);
    zws_test_capacity_wait(NULL);CloseHandle(waiting);zws_reader_release(reader);
    REQUIRE(zws_budget_live(budget)==1&&zws_control_alive(control)&&zws_file_pump_count()==1);
    join(&j,thread);REQUIRE(!zws_budget_live(budget)&&!zws_control_alive(control));zws_control_release(control);zws_budget_release(budget);zero();
}
int zws_test_file_pump(void){
    zero();Fixture fixture={0};run_worker(file_worker,&fixture);REQUIRE(fixture.result==S_OK);
    roundtrip(&fixture,0,0,0,0);roundtrip(&fixture,1,7,111113,0);
    roundtrip(&fixture,1,fixture.length,0,0);roundtrip(&fixture,1,7,2048,1);
    failures(&fixture);blocked_cancel(&fixture);
    fixture.cleanup=1;run_worker(file_worker,&fixture);REQUIRE(fixture.result==S_OK);zero();
    fprintf(stderr,"Windows file pump: 6 groups; regular/window/whole maximum/HEAD0/empty0/OOM/block cancel/last refs all0\n");return 0;
}
