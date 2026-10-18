#include "windows_physical.h"
#include "windows_producer_internal.h"
#include <stdlib.h>
#include <string.h>

struct ZwsChannel {
    ZwsPhysical physical;
    LONG terminal,result,producer_thread;
    uint32_t error;
    SRWLOCK lock;
    uint64_t length,produced,received;
    size_t start,used;
    LONG gate;
    HANDLE accepted,data,space;
    unsigned char *ring;
};
struct ZwsReader { LONG refs,active; ZwsChannel *channel; };
struct ZwsCandidate { ZwsChannel *channel; ZwsBudget *budget; ZwsReader *reader; int head; };
static LONG physical_count,control_count,budget_count,reader_count,candidate_count,ring_count;
#ifdef ZWS_TESTING
static LONG fail_after=-1;
static HANDLE capacity_wait_event;
static LONG waiting_writers;
void zws_test_fail_after(int n){InterlockedExchange(&fail_after,n);}
void zws_test_capacity_wait(HANDLE event){capacity_wait_event=event;}
uint32_t zws_test_waiting_writers(void){return (uint32_t)InterlockedCompareExchange(&waiting_writers,0,0);}
static int allocation_allowed(void){
    LONG n=InterlockedCompareExchange(&fail_after,0,0);
    if(n<0)return 1;if(!n)return 0;InterlockedDecrement(&fail_after);return 1;
}
void zws_test_layout(uint32_t *p,uint32_t *c,uint32_t *r){*p=sizeof(ZwsChannel);*c=sizeof(ZwsControl);*r=sizeof(ZwsReader);}
#else
static int allocation_allowed(void){return 1;}
#endif
static void *zero_alloc(size_t bytes){return allocation_allowed()?calloc(1,bytes):NULL;}
void *zws_native_alloc(size_t bytes){return zero_alloc(bytes);}
static LONG load(LONG *p){return InterlockedCompareExchange(p,0,0);}
static int reserve(LONG *p,LONG maximum){
    LONG n=load(p);while(n<maximum){LONG old=InterlockedCompareExchange(p,n+1,n);if(old==n)return 1;n=old;}return 0;
}
int zws_physical_reserve(void){return reserve(&physical_count,ZWS_PROCESS_LIMIT);}
void zws_physical_unreserve(void){InterlockedDecrement(&physical_count);}
int zws_control_create(ZwsControl **out,uint32_t *error){
    *out=NULL;if(error)*error=0;ZwsControl *c=zero_alloc(sizeof(*c));if(!c)return ZWS_OOM;
    c->cancel_event=CreateEventW(NULL,TRUE,FALSE,NULL);
    if(!c->cancel_event){if(error)*error=GetLastError();free(c);return ZWS_IO;}
    c->refs=1;c->alive=1;InterlockedIncrement(&control_count);*out=c;return ZWS_OK;
}
ZwsBudget *zws_budget_create(uint32_t limit){
    if(!limit||limit>ZWS_CONSUMER_LIMIT)return NULL;
    ZwsBudget *b=zero_alloc(sizeof(*b));if(!b)return NULL;
    b->refs=1;b->limit=(LONG)limit;InterlockedIncrement(&budget_count);return b;
}
void zws_budget_add(ZwsBudget *b){InterlockedIncrement(&b->refs);}
void zws_budget_release(ZwsBudget *b){if(b&&!InterlockedDecrement(&b->refs)){free(b);InterlockedDecrement(&budget_count);}}
int zws_budget_limit(ZwsBudget *b,uint32_t limit){if(!b||!limit||limit>ZWS_CONSUMER_LIMIT)return ZWS_INVALID;InterlockedExchange(&b->limit,(LONG)limit);return ZWS_OK;}
uint32_t zws_budget_live(ZwsBudget *b){return (uint32_t)load(&b->live);}
int zws_budget_reserve(ZwsBudget *b){
    if(!b||!reserve(&b->live,load(&b->limit)))return 0;zws_budget_add(b);return 1;
}
void zws_budget_unreserve(ZwsBudget *b){InterlockedDecrement(&b->live);zws_budget_release(b);}
void zws_control_add(ZwsControl *c){InterlockedIncrement(&c->refs);}
void zws_control_release(ZwsControl *c){if(c&&!InterlockedDecrement(&c->refs)){CloseHandle(c->cancel_event);free(c);InterlockedDecrement(&control_count);}}
void zws_control_cancel(ZwsControl *c){if(c&&!InterlockedExchange(&c->cancelled,1))SetEvent(c->cancel_event);}
int zws_control_alive(ZwsControl *c){return c&&load(&c->alive)!=0;}
static void channel_add(ZwsChannel *c){InterlockedIncrement(&c->physical.refs);}
ZwsRetirement zws_physical_withdraw(ZwsPhysical *p){
    ZwsRetirement retired={p->control,p->budget};p->control=NULL;p->budget=NULL;
    InterlockedExchange(&retired.control->alive,0);return retired;
}
void zws_physical_retire(ZwsRetirement retired){
    zws_control_release(retired.control);zws_physical_unreserve();
    if(retired.budget)zws_budget_unreserve(retired.budget);
}
static void channel_release(ZwsChannel *c){
    if(!c||InterlockedDecrement(&c->physical.refs))return;
    ZwsRetirement retired=zws_physical_withdraw(&c->physical);
    CloseHandle(c->accepted);CloseHandle(c->data);CloseHandle(c->space);
    SecureZeroMemory(c->ring,ZWS_RING_BYTES);free(c->ring);
    InterlockedDecrement(&ring_count);
    SecureZeroMemory(c,sizeof(*c));free(c);
    /* Credit remains reserved through actual storage retirement. */
    zws_physical_retire(retired);
}
void zws_source_release(ZwsChannel *c){if(c){if(load(&c->physical.binding)!=2)zws_control_cancel(c->physical.control);channel_release(c);}}
void zws_channel_cancel(ZwsChannel *c){zws_control_cancel(c->physical.control);}
HANDLE zws_channel_cancel_event(ZwsChannel *c){return c->physical.control->cancel_event;}
void zws_producer_cancel_unfinished(ZwsChannel *c){
    AcquireSRWLockExclusive(&c->lock);
    if(load(&c->terminal)!=1)zws_control_cancel(c->physical.control);
    ReleaseSRWLockExclusive(&c->lock);
}
void zws_producer_release(ZwsChannel *c){if(c){zws_producer_cancel_unfinished(c);channel_release(c);}}
uint64_t zws_channel_length(ZwsChannel *c){return c->length;}
int zws_channel_prepare(uint64_t main_thread,uint64_t length,uint64_t maximum,unsigned kind,
    ZwsChannel **source,ZwsChannel **producer,uint32_t *error){
    if(error)*error=0;if(!source||!producer)return ZWS_INVALID;*source=NULL;*producer=NULL;
    if(GetCurrentThreadId()==main_thread)return ZWS_UI_THREAD;
    if(!maximum||maximum>ZWS_MAX_BYTES||main_thread>UINT32_MAX||(kind!=ZWS_GENERATED&&kind!=ZWS_FILE_PUMP))return ZWS_INVALID;
    if(length>maximum)return ZWS_TOO_LARGE;
    if(!zws_physical_reserve())return ZWS_FULL;
    int status=ZWS_OOM;ZwsChannel *c=zero_alloc(sizeof(*c));ZwsControl *control=NULL;
    if(!c)goto failed;
    status=zws_control_create(&control,error);if(status)goto failed;
    c->ring=zero_alloc(ZWS_RING_BYTES);if(!c->ring){status=ZWS_OOM;goto failed;}
    InterlockedIncrement(&ring_count);
    c->accepted=CreateEventW(NULL,TRUE,FALSE,NULL);c->data=CreateEventW(NULL,TRUE,FALSE,NULL);c->space=CreateEventW(NULL,TRUE,TRUE,NULL);
    if(!c->accepted||!c->data||!c->space){status=ZWS_IO;if(error)*error=GetLastError();goto failed;}
    c->physical.refs=2;c->length=length;c->physical.ui_thread=(DWORD)main_thread;c->physical.kind=kind;c->physical.control=control;
    InitializeSRWLock(&c->lock);*source=c;*producer=c;return ZWS_OK;
failed:
    if(c){if(c->accepted)CloseHandle(c->accepted);if(c->data)CloseHandle(c->data);if(c->space)CloseHandle(c->space);if(c->ring){SecureZeroMemory(c->ring,ZWS_RING_BYTES);free(c->ring);InterlockedDecrement(&ring_count);}free(c);}
    if(control)zws_control_release(control);zws_physical_unreserve();return status;
}
static int terminal(ZwsChannel *c,int result,uint32_t error){
    AcquireSRWLockExclusive(&c->lock);
    if(InterlockedCompareExchange(&c->terminal,2,0)!=0){ReleaseSRWLockExclusive(&c->lock);return ZWS_FINISHED;}
    c->error=error;InterlockedExchange(&c->result,(LONG)result);InterlockedExchange(&c->terminal,1);
    if(result)zws_control_cancel(c->physical.control);SetEvent(c->data);
    ReleaseSRWLockExclusive(&c->lock);return result;
}
static int current_producer(ZwsChannel *c,unsigned kind,uint32_t *error){
    if(error)*error=0;if(!c)return ZWS_INVALID;if(c->physical.kind!=kind)return ZWS_KIND;
    DWORD tid=GetCurrentThreadId();if(tid==c->physical.ui_thread)return ZWS_UI_THREAD;
    LONG old=InterlockedCompareExchange(&c->producer_thread,(LONG)tid,0);
    if(old&&(DWORD)old!=tid)return ZWS_THREAD;
    if(load(&c->terminal))return ZWS_FINISHED;
    if(load(&c->physical.control->cancelled))return terminal(c,ZWS_CANCELLED,0);
    HANDLE events[2]={c->physical.control->cancel_event,c->accepted};
    DWORD waited=WaitForMultipleObjects(2,events,FALSE,INFINITE);
    if(waited==WAIT_FAILED){uint32_t code=GetLastError();if(error)*error=code;return terminal(c,ZWS_IO,code);}
    if(waited==WAIT_OBJECT_0||load(&c->physical.control->cancelled))return terminal(c,ZWS_CANCELLED,0);
    return ZWS_OK;
}
int zws_producer_begin_kind(ZwsChannel *c,unsigned kind,int *head,uint32_t *error){
    int result=current_producer(c,kind,error);if(result)return result;
    if(!head)return terminal(c,ZWS_INVALID,0);*head=load(&c->gate)==2;return ZWS_OK;
}
int zws_producer_write_kind(ZwsChannel *c,unsigned kind,const void *bytes,size_t count,uint32_t *error){
    int result=current_producer(c,kind,error);if(result)return result;
    if(load(&c->gate)==2)return terminal(c,ZWS_HEAD_BODY,0);
    if(!bytes||!count||count>ZWS_CHUNK_BYTES)return terminal(c,ZWS_CHUNK,0);
    if(count>c->length-c->produced)return terminal(c,ZWS_LENGTH,0);
    size_t sent=0;
    while(sent<count){
        if(load(&c->physical.control->cancelled))return terminal(c,ZWS_CANCELLED,0);
        AcquireSRWLockExclusive(&c->lock);
        size_t space=ZWS_RING_BYTES-c->used,n=count-sent;if(n>space)n=space;
        size_t end=(c->start+c->used)%ZWS_RING_BYTES,first=ZWS_RING_BYTES-end;if(first>n)first=n;
        memcpy(c->ring+end,(const unsigned char *)bytes+sent,first);
        memcpy(c->ring,(const unsigned char *)bytes+sent+first,n-first);
        c->used+=n;c->produced+=n;sent+=n;
        if(c->used)SetEvent(c->data);if(c->used==ZWS_RING_BYTES)ResetEvent(c->space);
        ReleaseSRWLockExclusive(&c->lock);
        if(sent==count)break;
        HANDLE events[2]={c->physical.control->cancel_event,c->space};
#ifdef ZWS_TESTING
        InterlockedIncrement(&waiting_writers);if(capacity_wait_event)SetEvent(capacity_wait_event);
#endif
        DWORD waited=WaitForMultipleObjects(2,events,FALSE,INFINITE);
#ifdef ZWS_TESTING
        InterlockedDecrement(&waiting_writers);
#endif
        if(waited==WAIT_FAILED){uint32_t code=GetLastError();if(error)*error=code;return terminal(c,ZWS_IO,code);}
        if(waited==WAIT_OBJECT_0)return terminal(c,ZWS_CANCELLED,0);
    }
    return ZWS_OK;
}
int zws_producer_finish_kind(ZwsChannel *c,unsigned kind,uint32_t *error){
    int result=current_producer(c,kind,error);if(result)return result;
    if(load(&c->gate)!=2&&c->produced!=c->length)return terminal(c,ZWS_LENGTH,0);
    return terminal(c,ZWS_OK,0);
}
int zws_producer_fail_kind(ZwsChannel *c,unsigned kind,int failure,uint32_t native_error){
    uint32_t ignored=0;int result=current_producer(c,kind,&ignored);if(result)return result;
    return terminal(c,failure,native_error);
}
int zws_writer_begin(ZwsChannel *c,int *head,uint32_t *error){return zws_producer_begin_kind(c,ZWS_GENERATED,head,error);}
int zws_writer_write(ZwsChannel *c,const void *bytes,size_t n,uint32_t *error){return zws_producer_write_kind(c,ZWS_GENERATED,bytes,n,error);}
int zws_writer_finish(ZwsChannel *c,uint32_t *error){return zws_producer_finish_kind(c,ZWS_GENERATED,error);}
void zws_reader_add(ZwsReader *r){InterlockedIncrement(&r->refs);}
void zws_reader_release(ZwsReader *r){
    if(!r||InterlockedDecrement(&r->refs))return;
    ZwsChannel *c=r->channel;if(load(&r->active))zws_control_cancel(c->physical.control);
    free(r);InterlockedDecrement(&reader_count);channel_release(c);
}
int zws_candidate_prepare(ZwsChannel *c,ZwsBudget *b,int head,ZwsCandidate **out){
    if(!out)return ZWS_INVALID;*out=NULL;if(!c||!b)return ZWS_INVALID;
    if(GetCurrentThreadId()!=c->physical.ui_thread)return ZWS_THREAD;
    if(load(&c->physical.control->cancelled))return ZWS_CANCELLED;
    LONG old=InterlockedCompareExchange(&c->physical.binding,1,0);if(old)return ZWS_BUSY;
    if(!zws_budget_reserve(b)){InterlockedExchange(&c->physical.binding,0);return ZWS_FULL;}
    ZwsCandidate *candidate=zero_alloc(sizeof(*candidate));ZwsReader *reader=zero_alloc(sizeof(*reader));
    if(!candidate||!reader){free(candidate);free(reader);zws_budget_unreserve(b);InterlockedExchange(&c->physical.binding,0);return ZWS_OOM;}
    channel_add(c);channel_add(c);reader->refs=1;reader->channel=c;
    candidate->channel=c;candidate->reader=reader;candidate->budget=b;candidate->head=!!head;
    InterlockedIncrement(&reader_count);InterlockedIncrement(&candidate_count);*out=candidate;return ZWS_OK;
}
ZwsReader *zws_candidate_reader(ZwsCandidate *c){return c->reader;}
ZwsControl *zws_candidate_control(ZwsCandidate *c){return c->channel->physical.control;}
void zws_candidate_abort(ZwsCandidate *candidate){
    if(!candidate)return;ZwsChannel *c=candidate->channel;
    zws_reader_release(candidate->reader);zws_budget_unreserve(candidate->budget);
    InterlockedExchange(&c->physical.binding,0);free(candidate);InterlockedDecrement(&candidate_count);channel_release(c);
}
void zws_candidate_admit(ZwsCandidate *candidate,int cancelled,ZwsControl **out){
    ZwsChannel *c=candidate->channel;c->physical.budget=candidate->budget;
    InterlockedExchange(&candidate->reader->active,1);InterlockedExchange(&c->physical.binding,2);
    if(cancelled)zws_control_cancel(c->physical.control);
    if(out){zws_control_add(c->physical.control);*out=c->physical.control;}
    InterlockedExchange(&c->gate,candidate->head?2:1);SetEvent(c->accepted);
    zws_reader_release(candidate->reader);free(candidate);InterlockedDecrement(&candidate_count);channel_release(c);
}
int zws_reader_try_read(ZwsReader *r,void *buffer,size_t maximum,size_t *count,uint32_t *error){
    if(error)*error=0;if(count)*count=0;if(!r||!count||(!buffer&&maximum))return ZWS_INVALID;
    ZwsChannel *c=r->channel;if(GetCurrentThreadId()==c->physical.ui_thread)return ZWS_UI_THREAD;
    if(!load(&r->active))return ZWS_PENDING;
    if(load(&c->physical.control->cancelled))return ZWS_CANCELLED;
    if(load(&c->gate)==2)return ZWS_EOF;
    AcquireSRWLockExclusive(&c->lock);
    size_t n=maximum;if(n>c->used)n=c->used;
    size_t first=ZWS_RING_BYTES-c->start;if(first>n)first=n;
    if(n){memcpy(buffer,c->ring+c->start,first);memcpy((unsigned char *)buffer+first,c->ring,n-first);}
    c->start=(c->start+n)%ZWS_RING_BYTES;c->used-=n;c->received+=n;
    if(!c->used&&!load(&c->terminal))ResetEvent(c->data);if(c->used<ZWS_RING_BYTES)SetEvent(c->space);
    int done=load(&c->terminal)==1,result=(int)load(&c->result);
    ReleaseSRWLockExclusive(&c->lock);*count=n;
    if(n||!maximum)return ZWS_OK;
    if(done){if(error)*error=c->error;return result?result:ZWS_EOF;}return ZWS_PENDING;
}
int zws_reader_terminal(ZwsReader *r,int *result,uint32_t *error){
    if(!r||!result||!error)return ZWS_INVALID;*result=0;*error=0;
    ZwsChannel *c=r->channel;if(load(&c->terminal)!=1)return ZWS_PENDING;
    *result=(int)load(&c->result);*error=c->error;return ZWS_OK;
}
void zws_reader_wait_handles(ZwsReader *r,HANDLE *data,HANDLE *cancel){*data=r->channel->data;*cancel=r->channel->physical.control->cancel_event;}
void zws_counts(ZwsCounts *out){*out=(ZwsCounts){(uint32_t)load(&physical_count),(uint32_t)load(&control_count),(uint32_t)load(&budget_count),(uint32_t)load(&reader_count),(uint32_t)load(&candidate_count),(uint32_t)load(&ring_count)};}
