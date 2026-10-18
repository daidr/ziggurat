/* Isolated native protocol test. No App/Window/event loop is running: the test
 * driver joins only its own explicit workers. This is not WebView2 evidence. */
#include "../src/file_stream/windows_core.h"
#include <stdio.h>
#include <string.h>
#define CHECK(x) do{if(!(x)){fprintf(stderr,"channel check line %d: %s\n",__LINE__,#x);fflush(stderr);ExitProcess(1);}}while(0)
typedef struct Job {
    DWORD main_thread;
    uint64_t length;
    unsigned kind;
    HANDLE ready,go,done,retire;
    ZwsChannel *source,*producer;
    int prepare,result,head,hold,mode;
    uint32_t error;
} Job;
static unsigned char byte_at(uint64_t offset){return (unsigned char)(offset*37+11);}
static DWORD WINAPI produce(void *pointer){
    Job *j=pointer;j->prepare=zws_channel_prepare(j->main_thread,j->length,ZWS_MAX_BYTES,j->kind,&j->source,&j->producer,&j->error);
    SetEvent(j->ready);if(j->prepare)return 0;
    if(WaitForSingleObject(j->go,5000)!=WAIT_OBJECT_0){j->result=-1;goto finished;}
    j->result=zws_writer_begin(j->producer,&j->head,&j->error);
    if(j->result)goto finished;
    if(j->mode==2){j->result=zws_writer_finish(j->producer,&j->error);goto finished;}
    if(j->mode==3){j->result=zws_writer_write(j->producer,"too long",8,&j->error);goto finished;}
    if(j->mode==4){j->result=zws_writer_write(j->producer,"",0,&j->error);goto finished;}
    if(!j->head){
        unsigned char bytes[ZWS_CHUNK_BYTES];uint64_t sent=0;
        while(sent<j->length){
            size_t count=(size_t)(j->length-sent);if(count>sizeof(bytes))count=sizeof(bytes);
            for(size_t i=0;i<count;i++)bytes[i]=byte_at(sent+i);
            j->result=zws_writer_write(j->producer,bytes,count,&j->error);if(j->result)break;sent+=count;
        }
    }
    if(!j->result)j->result=zws_writer_finish(j->producer,&j->error);
finished:
    SetEvent(j->done);
    if(j->hold)WaitForSingleObject(j->retire,5000);
    zws_producer_release(j->producer);j->producer=NULL;return 0;
}
static int init(Job *j,uint64_t length,unsigned kind,int hold,HANDLE *thread){
    memset(j,0,sizeof(*j));j->main_thread=GetCurrentThreadId();j->length=length;j->kind=kind;j->hold=hold;
    j->ready=CreateEventW(NULL,TRUE,FALSE,NULL);j->go=CreateEventW(NULL,TRUE,FALSE,NULL);
    j->done=CreateEventW(NULL,TRUE,FALSE,NULL);j->retire=CreateEventW(NULL,TRUE,FALSE,NULL);
    if(!j->ready||!j->go||!j->done||!j->retire)goto failed;
    *thread=CreateThread(NULL,0,produce,j,0,NULL);if(!*thread)goto failed;
    /* A failure after worker creation retains the Job/handles until process
     * exit rather than freeing memory still borrowed by that worker. */
    CHECK(WaitForSingleObject(j->ready,5000)==WAIT_OBJECT_0);return 0;
failed:
    if(j->ready)CloseHandle(j->ready);if(j->go)CloseHandle(j->go);
    if(j->done)CloseHandle(j->done);if(j->retire)CloseHandle(j->retire);return 1;
}
static int join(Job *j,HANDLE thread){
    SetEvent(j->retire);CHECK(WaitForSingleObject(thread,5000)==WAIT_OBJECT_0);CloseHandle(thread);
    CloseHandle(j->ready);CloseHandle(j->go);CloseHandle(j->done);CloseHandle(j->retire);return 0;
}
typedef struct ReadJob {ZwsReader *reader;uint64_t expected;int result;} ReadJob;
static DWORD WINAPI consume(void *pointer){
    ReadJob *j=pointer;uint64_t offset=0;unsigned char bytes[11003];HANDLE events[2];
    zws_reader_wait_handles(j->reader,&events[1],&events[0]);
    for(;;){
        size_t n=0;uint32_t error=0;int result=zws_reader_try_read(j->reader,bytes,sizeof(bytes),&n,&error);
        if(result==ZWS_PENDING){if(WaitForMultipleObjects(2,events,FALSE,5000)>=WAIT_OBJECT_0+2){j->result=-1;return 0;}continue;}
        if(result==ZWS_EOF){j->result=offset==j->expected?0:-2;return 0;}
        if(result){j->result=result;return 0;}
        if(!n){j->result=-3;return 0;}
        for(size_t i=0;i<n;i++)if(bytes[i]!=byte_at(offset+i)){j->result=-4;return 0;}
        offset+=n;if(offset>j->expected){j->result=-5;return 0;}
    }
}
static DWORD WINAPI misuse(void *pointer){
    Job *j=pointer;int head=0;uint32_t error=0;
    if(zws_writer_begin(j->producer,&head,&error)!=ZWS_THREAD||
       zws_writer_write(j->producer,"x",1,&error)!=ZWS_THREAD||
       zws_writer_finish(j->producer,&error)!=ZWS_THREAD)j->result=-6;
    return 0;
}
static int roundtrip(uint64_t length,int head,int hold){
    Job job;HANDLE writer;CHECK(init(&job,length,ZWS_GENERATED,hold,&writer)==0);CHECK(job.prepare==ZWS_OK);
    ZwsBudget *budget=zws_budget_create(1);CHECK(budget);ZwsCandidate *candidate=NULL;
    CHECK(zws_candidate_prepare(job.source,budget,head,&candidate)==ZWS_OK);
    ZwsReader *reader=zws_candidate_reader(candidate);zws_reader_add(reader);
    ZwsControl *control=NULL;zws_candidate_admit(candidate,0,&control);zws_source_release(job.source);job.source=NULL;
    unsigned char probe;size_t n=1;uint32_t error=42;
    CHECK(zws_reader_try_read(reader,&probe,1,&n,&error)==ZWS_UI_THREAD&&n==0&&error==0);
    SetEvent(job.go);
    if(hold){
        CHECK(WaitForSingleObject(job.done,5000)==WAIT_OBJECT_0);CHECK(job.result==ZWS_OK);
        HANDLE wrong=CreateThread(NULL,0,misuse,&job,0,NULL);CHECK(wrong);
        CHECK(WaitForSingleObject(wrong,5000)==WAIT_OBJECT_0);CloseHandle(wrong);CHECK(job.result==ZWS_OK);
        CHECK(zws_writer_write(job.producer,"x",1,&error)==ZWS_UI_THREAD);
    }
    ReadJob read={reader,head?0:length,0};HANDLE reading=CreateThread(NULL,0,consume,&read,0,NULL);CHECK(reading);
    CHECK(WaitForSingleObject(reading,10000)==WAIT_OBJECT_0);CloseHandle(reading);CHECK(read.result==0);
    CHECK(WaitForSingleObject(job.done,5000)==WAIT_OBJECT_0);CHECK(job.result==ZWS_OK);CHECK(job.head==head);
    zws_reader_release(reader);
    if(hold){CHECK(zws_budget_live(budget)==1);CHECK(zws_control_alive(control));}
    CHECK(join(&job,writer)==0);CHECK(zws_budget_live(budget)==0);CHECK(!zws_control_alive(control));
    zws_control_release(control);zws_budget_release(budget);return 0;
}
static int rollback(void){
    Job job;HANDLE thread;CHECK(init(&job,7,ZWS_GENERATED,0,&thread)==0);CHECK(job.prepare==0);
    ZwsBudget *budget=zws_budget_create(1);CHECK(budget);ZwsCandidate *candidate=NULL;
    CHECK(zws_candidate_prepare(job.source,budget,0,&candidate)==0);
    ZwsCandidate *other=NULL;CHECK(zws_candidate_prepare(job.source,budget,0,&other)==ZWS_BUSY&&other==NULL);
    zws_candidate_abort(candidate);CHECK(zws_budget_live(budget)==0);
    for(int fail=0;fail<2;fail++){
        zws_test_fail_after(fail);CHECK(zws_candidate_prepare(job.source,budget,0,&candidate)==ZWS_OOM&&candidate==NULL);
        CHECK(zws_budget_live(budget)==0);
    }
    zws_test_fail_after(-1);CHECK(zws_candidate_prepare(job.source,budget,0,&candidate)==0);
    ZwsReader *reader=zws_candidate_reader(candidate);zws_reader_add(reader);zws_candidate_admit(candidate,0,NULL);
    zws_source_release(job.source);job.source=NULL;SetEvent(job.go);
    ReadJob read={reader,7,0};HANDLE consuming=CreateThread(NULL,0,consume,&read,0,NULL);CHECK(consuming);
    CHECK(WaitForSingleObject(consuming,5000)==WAIT_OBJECT_0);CloseHandle(consuming);CHECK(read.result==0);
    CHECK(join(&job,thread)==0);CHECK(job.result==0);zws_reader_release(reader);zws_budget_release(budget);return 0;
}
static int preparation_oom(void){
    for(int fail=0;fail<3;fail++){
        zws_test_fail_after(fail);Job job;HANDLE thread;CHECK(init(&job,1,ZWS_GENERATED,0,&thread)==0);
        CHECK(job.prepare==ZWS_OOM&&job.source==NULL&&job.producer==NULL&&job.error==0);
        CHECK(join(&job,thread)==0);ZwsCounts counts;zws_counts(&counts);CHECK(!counts.physical&&!counts.controls);
    }
    zws_test_fail_after(-1);return 0;
}
static int blocked_cancel(void){
    Job job;HANDLE thread;CHECK(init(&job,4*1024*1024,ZWS_GENERATED,1,&thread)==0);CHECK(job.prepare==0);
    ZwsBudget *budget=zws_budget_create(1);CHECK(budget);ZwsCandidate *candidate=NULL;
    CHECK(zws_candidate_prepare(job.source,budget,0,&candidate)==0);
    ZwsReader *reader=zws_candidate_reader(candidate);zws_reader_add(reader);
    ZwsControl *control=NULL;zws_candidate_admit(candidate,0,&control);zws_source_release(job.source);job.source=NULL;
    HANDLE waiting=CreateEventW(NULL,TRUE,FALSE,NULL);CHECK(waiting);zws_test_capacity_wait(waiting);
    SetEvent(job.go);CHECK(WaitForSingleObject(waiting,5000)==WAIT_OBJECT_0);
    CHECK(zws_test_waiting_writers()==1&&WaitForSingleObject(job.done,0)==WAIT_TIMEOUT);
    zws_control_cancel(control);CHECK(WaitForSingleObject(job.done,5000)==WAIT_OBJECT_0);CHECK(job.result==ZWS_CANCELLED);
    zws_test_capacity_wait(NULL);CloseHandle(waiting);zws_reader_release(reader);
    CHECK(zws_budget_live(budget)==1&&zws_control_alive(control));
    CHECK(join(&job,thread)==0);CHECK(zws_budget_live(budget)==0&&!zws_control_alive(control));
    zws_control_release(control);zws_budget_release(budget);return 0;
}
typedef struct Many {DWORD main_thread;ZwsChannel *sources[33],*producers[33];int result;} Many;
static DWORD WINAPI prepare_many(void *pointer){
    Many *m=pointer;
    for(unsigned i=0;i<33;i++){
        uint32_t error=0;int result=zws_channel_prepare(m->main_thread,1,ZWS_MAX_BYTES,ZWS_GENERATED,&m->sources[i],&m->producers[i],&error);
        if((i<32&&result!=ZWS_OK)||(i==32&&(result!=ZWS_FULL||m->sources[i]||m->producers[i]||error)))m->result=1;
    }
    return 0;
}
static int capacity(void){
    Many many={0};many.main_thread=GetCurrentThreadId();
    HANDLE thread=CreateThread(NULL,0,prepare_many,&many,0,NULL);CHECK(thread);
    CHECK(WaitForSingleObject(thread,5000)==WAIT_OBJECT_0);CloseHandle(thread);CHECK(many.result==0);
    ZwsCounts counts;zws_counts(&counts);CHECK(counts.physical==32&&counts.controls==32);
    ZwsBudget *budget=zws_budget_create(1);CHECK(budget);ZwsCandidate *first=NULL,*second=NULL;
    CHECK(zws_candidate_prepare(many.sources[0],budget,0,&first)==0);
    CHECK(zws_candidate_prepare(many.sources[1],budget,0,&second)==ZWS_FULL&&second==NULL);
    zws_candidate_abort(first);CHECK(zws_budget_live(budget)==0);
    CHECK(zws_candidate_prepare(many.sources[1],budget,0,&second)==0);zws_candidate_abort(second);
    for(unsigned i=0;i<32;i++){zws_source_release(many.sources[i]);zws_producer_release(many.producers[i]);}
    zws_budget_release(budget);return 0;
}
static int terminal_failure(int mode,int expected){
    Job job;HANDLE thread;CHECK(init(&job,7,ZWS_GENERATED,1,&thread)==0);CHECK(job.prepare==0);job.mode=mode;
    ZwsBudget *budget=zws_budget_create(1);CHECK(budget);ZwsCandidate *candidate=NULL;
    CHECK(zws_candidate_prepare(job.source,budget,0,&candidate)==0);
    ZwsReader *reader=zws_candidate_reader(candidate);zws_reader_add(reader);zws_candidate_admit(candidate,0,NULL);
    zws_source_release(job.source);job.source=NULL;SetEvent(job.go);
    CHECK(WaitForSingleObject(job.done,5000)==WAIT_OBJECT_0&&job.result==expected);
    int terminal=0;uint32_t error=42;CHECK(zws_reader_terminal(reader,&terminal,&error)==0&&terminal==expected&&error==0);
    zws_reader_release(reader);CHECK(join(&job,thread)==0);zws_budget_release(budget);return 0;
}
static int all_zero(void){ZwsCounts c;zws_counts(&c);CHECK(!c.physical&&!c.controls&&!c.budgets&&!c.readers&&!c.candidates&&!c.rings);return 0;}
int zws_test_core(void){
    CHECK(all_zero()==0);
    CHECK(roundtrip(4*1024*1024,0,0)==0);CHECK(all_zero()==0);
    CHECK(roundtrip(17,0,1)==0);CHECK(all_zero()==0);
    CHECK(roundtrip(0,0,1)==0);CHECK(all_zero()==0);
    CHECK(roundtrip(1024,1,1)==0);CHECK(all_zero()==0);
    CHECK(rollback()==0);CHECK(all_zero()==0);
    CHECK(preparation_oom()==0);CHECK(all_zero()==0);
    CHECK(blocked_cancel()==0);CHECK(all_zero()==0);
    CHECK(capacity()==0);CHECK(all_zero()==0);
    CHECK(terminal_failure(2,ZWS_LENGTH)==0);CHECK(all_zero()==0);
    CHECK(terminal_failure(3,ZWS_LENGTH)==0);CHECK(all_zero()==0);
    CHECK(terminal_failure(4,ZWS_CHUNK)==0);CHECK(all_zero()==0);
    uint32_t p,c,r;zws_test_layout(&p,&c,&r);
    fprintf(stderr,"Windows shared channel: 11 groups; physical=%u control=%u reader=%u ring=%u; final refs=0\n",p,c,r,ZWS_RING_BYTES);
    return 0;
}
