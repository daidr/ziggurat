/* Explicit worker-owned HTTPS reactor. No hidden worker, queue, store or UI wait. */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include "windows_driver.h"
#include "windows_tls_provider.h"
#include "../file_stream/windows_core.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>

enum { CONNECTIONS=8,HEAD_BYTES=24576,RESPONSE_HEAD_BYTES=9216,CHUNK=16384 };
enum { PENDING,ACCEPTED,FINISHED,CANCELLED };
enum { HANDSHAKE,REQUEST,WAIT_RESPONSE,RESPONSE,SHUTDOWN };
typedef struct Worker Worker;
typedef struct Connection Connection;
struct ZhtwServer {
    LONG refs,sealed,cancelled,adopted,running,done;
    DWORD main_thread,worker_thread;
    SRWLOCK lock;
    HANDLE wake;
    uint16_t port;
    unsigned connection_limit;
    size_t limit,bytes,metadata_peak,peak,tls_live,tls_peak;
    void *app;
    ZhtwPost post;
    ZhtwFormat format;
    Worker *worker; /* Original worker only. Never read by main or late refs. */
    ZhtwEnvelope *slots[CONNECTIONS]; /* Borrowed until envelope's actual free. */
    unsigned reserved[CONNECTIONS]; /* Includes final-free tail after withdrawal. */
    ZhrOwner *owners[CONNECTIONS]; /* Main-owned registration, no strong cycle. */
};
struct ZhrOwner {
    LONG refs;
    ZhtwServer *server;
    void *context;
    ZhrFilter filter;
    ZhrOffer offer;
    size_t limit,bytes,peak,borrowed;
    unsigned max_pending,pending,file_streams;
    uint16_t port;
    int bound,sealed,closed;
    char prefix[257];
    size_t prefix_length;
    ZwsBudget *file_budget;
};
struct ZhtwEnvelope {
    LONG refs,phase;
    ZhtwServer *server;
    ZhrOwner *owner; /* Independent C-only ref, only main initially publishes. */
    ZhrCandidate *candidate; /* lock; unready candidate may outlive worker. */
    unsigned slot,deny;
    int alive,dispatched,head,handled,preparing;
    size_t head_length;
    unsigned char request_head[HEAD_BYTES];
};
struct ZhrBorrow { ZhtwEnvelope *envelope; };
struct ZhrTicket { LONG refs; ZhtwEnvelope *envelope; };
struct ZhrCandidate {
    ZhtwEnvelope *envelope;
    ZwsCandidate *file_candidate;
    ZwsReader *reader;
    ZwsControl *control;
    size_t allocation,head_length,memory_length;
    uint64_t length;
    int admitted,ready,head,source_admitted;
    /* One charged allocation: formatted immutable head, then optional body. */
    unsigned char bytes[];
};
struct Connection {
    SOCKET socket;
    WSAEVENT event;
    ZhtpConnection *tls;
    ZhtwEnvelope *envelope;
    ZhrCandidate *response;
    int state,want,header_done,body_done,source_wait,finish_wait;
    const unsigned char *write_pointer;
    size_t write_length,write_offset;
    uint64_t body_sent,source_received;
    unsigned char body[CHUNK];
};
struct Worker {
    ZhtpProvider *provider;
    SOCKET listener;
    WSAEVENT listener_event;
    int winsock,accept_ready;
    Connection connections[CONNECTIONS];
};
static LONG servers,payloads,envelopes,connection_count,owners,tickets,candidates;
static SRWLOCK totals_lock=SRWLOCK_INIT;
static size_t total_bytes,endpoint_bytes;
#ifdef ZHTW_TESTING
static LONG allocations=-1;
static HANDLE test_write_wait,test_connection_closed,test_accepted,test_request_byte;
void zhtw_test_fail_after(int n){InterlockedExchange(&allocations,n);}
void zhtw_test_backpressure(void *wait,void *closed){test_write_wait=wait;test_connection_closed=closed;}
void zhtw_test_ingress(void *accepted,void *request_byte){test_accepted=accepted;test_request_byte=request_byte;}
void zhtw_test_sizes(size_t *server,size_t *worker,size_t *envelope,size_t *candidate){*server=sizeof(ZhtwServer);*worker=sizeof(Worker);*envelope=sizeof(ZhtwEnvelope);*candidate=sizeof(ZhrCandidate);}
#endif
static LONG load(LONG *p){return InterlockedCompareExchange(p,0,0);}
static void *zero(size_t n){
#ifdef ZHTW_TESTING
    LONG left=load(&allocations);if(!left)return NULL;if(left>0)InterlockedDecrement(&allocations);
#endif
    return calloc(1,n);
}
static void total_add(size_t n,int endpoint){AcquireSRWLockExclusive(&totals_lock);if(endpoint)endpoint_bytes+=n;else total_bytes+=n;ReleaseSRWLockExclusive(&totals_lock);}
static void total_sub(size_t n,int endpoint){AcquireSRWLockExclusive(&totals_lock);size_t *p=endpoint?&endpoint_bytes:&total_bytes;assert(*p>=n);*p-=n;ReleaseSRWLockExclusive(&totals_lock);}
static void failure(ZhtwFailure *f,unsigned domain,int code){if(f)*f=(ZhtwFailure){domain,code};}
static void wake(ZhtwServer *s){SetEvent(s->wake);}
static int main_thread(ZhtwServer *s){return s->main_thread==GetCurrentThreadId();}
static int alive_server(ZhtwServer *s){return load(&s->adopted)&&!load(&s->cancelled)&&!load(&s->done);}
static int open_server(ZhtwServer *s){return alive_server(s)&&!load(&s->sealed);}
/* Conservative envelope, not a claim of simultaneous peaks: each component is
 * exact in its own allocator, and their sum remains within the fixed metadata
 * reservation plus the independent provider limit. */
static void server_peak(ZhtwServer *s){if(s->bytes>s->metadata_peak)s->metadata_peak=s->bytes;size_t value=s->metadata_peak+s->tls_peak;if(value>s->peak)s->peak=value;}
void zhtw_ref(ZhtwServer *s){InterlockedIncrement(&s->refs);}
void zhtw_unref(ZhtwServer *s){
    if(InterlockedDecrement(&s->refs))return;
    assert(load(&s->done)&&!s->worker);for(unsigned i=0;i<CONNECTIONS;i++)assert(!s->slots[i]&&!s->reserved[i]&&!s->owners[i]);
    HANDLE event=s->wake;size_t bytes=sizeof(*s);s->wake=NULL;
    CloseHandle(event);SecureZeroMemory(s,sizeof(*s));free(s);total_sub(bytes,0);InterlockedDecrement(&servers);
}
static void owner_add(ZhrOwner *s){InterlockedIncrement(&s->refs);}
static void owner_release(ZhrOwner *s){
    if(InterlockedDecrement(&s->refs))return;
    assert(s->closed&&!s->pending&&!s->borrowed&&s->bytes==sizeof(*s));
    ZhtwServer *server=s->server;ZwsBudget *budget=s->file_budget;s->server=NULL;s->file_budget=NULL;
    if(budget)zws_budget_release(budget);size_t n=sizeof(*s);SecureZeroMemory(s,n);free(s);total_sub(n,1);InterlockedDecrement(&owners);zhtw_unref(server);
}
static void envelope_add(ZhtwEnvelope *e){InterlockedIncrement(&e->refs);}
void zhtw_envelope_release(ZhtwEnvelope *e){
    if(InterlockedDecrement(&e->refs))return;
    ZhtwServer *s=e->server;ZhrOwner *owner=e->owner;unsigned slot=e->slot;size_t n=sizeof(*e);
    assert(!e->candidate&&!e->alive);
    /* Withdraw the borrowed pointer before free, while retaining the physical
     * slot/byte credit through actual cleanup. Close cannot see freed storage. */
    AcquireSRWLockExclusive(&s->lock);assert(s->slots[slot]==e&&s->reserved[slot]);s->slots[slot]=NULL;ReleaseSRWLockExclusive(&s->lock);
    SecureZeroMemory(e,n);free(e);
    AcquireSRWLockExclusive(&s->lock);assert(!s->slots[slot]&&s->reserved[slot]);s->reserved[slot]=0;assert(s->bytes>=n);s->bytes-=n;if(owner){assert(owner->pending);--owner->pending;}ReleaseSRWLockExclusive(&s->lock);
    total_sub(n,0);InterlockedDecrement(&envelopes);wake(s);if(owner)owner_release(owner);zhtw_unref(s);
}
static void cancel_envelope(ZhtwEnvelope *e){InterlockedCompareExchange(&e->phase,CANCELLED,PENDING);InterlockedCompareExchange(&e->phase,CANCELLED,ACCEPTED);wake(e->server);}
ZhrSlice zhtw_envelope_head(ZhtwEnvelope *e){return (ZhrSlice){e->request_head,e->head_length};}
uint16_t zhtw_envelope_port(ZhtwEnvelope *e){return e->server->port;}
void zhtw_reject(ZhtwEnvelope *e,unsigned status){
    ZhtwServer *s=e->server;if(!main_thread(s))return;
    AcquireSRWLockExclusive(&s->lock);if(e->alive&&!e->handled&&load(&e->phase)==PENDING){e->deny=status>=400&&status<=599?status:400;e->handled=1;}ReleaseSRWLockExclusive(&s->lock);wake(s);
}

/* ---------- Endpoint main-thread owner and C-only late responsibilities. ---------- */
int zhr_server_pin(void *value,void **out){
    if(!out)return ZHR_INVALID;*out=NULL;ZhtwServer *s=value;if(!s)return ZHR_INVALID;if(!main_thread(s))return ZHR_WRONG_THREAD;
    if(!open_server(s))return ZHR_CLOSED;zhtw_ref(s);*out=s;return ZHR_OK;
}
void zhr_server_unpin(void *s){if(s)zhtw_unref(s);}
size_t zhr_owner_size(void){return sizeof(ZhrOwner);}
int zhr_create(void *value,const ZhrOptions *options,ZhrOwner **out){
    if(!out)return ZHR_INVALID;*out=NULL;ZhtwServer *server=value;
    if(!server||!options||options->port!=server->port||!options->pending||options->pending>CONNECTIONS||!options->file_streams||options->file_streams>8||
        options->prefix.length==0||options->prefix.length>256||!options->prefix.ptr||options->bytes<=sizeof(ZhrOwner))return ZHR_INVALID;
    void *pin=NULL;int result=zhr_server_pin(server,&pin);if(result)return result;
    ZhrOwner *s=zero(sizeof(*s));if(!s){zhtw_unref(server);return ZHR_OOM;}
    s->refs=1;s->server=server;s->port=(uint16_t)options->port;s->limit=options->bytes;s->bytes=s->peak=sizeof(*s);s->max_pending=options->pending;s->file_streams=options->file_streams;
    s->prefix_length=options->prefix.length;memcpy(s->prefix,options->prefix.ptr,s->prefix_length);s->prefix[s->prefix_length]=0;
    InterlockedIncrement(&owners);total_add(sizeof(*s),1);*out=s;return ZHR_OK;
}
int zhr_bind(ZhrOwner *s,void *context,ZhrFilter filter,ZhrOffer offer){
    if(!s||!context||!filter||!offer)return ZHR_INVALID;ZhtwServer *server=s->server;if(!main_thread(server))return ZHR_WRONG_THREAD;
    AcquireSRWLockExclusive(&server->lock);int result=ZHR_OK;unsigned free_slot=CONNECTIONS;
    if(s->bound||s->closed||s->sealed||!open_server(server))result=ZHR_CLOSED;
    for(unsigned i=0;!result&&i<CONNECTIONS;i++){
        ZhrOwner *old=server->owners[i];if(!old){if(free_slot==CONNECTIONS)free_slot=i;continue;}
        size_t n=old->prefix_length<s->prefix_length?old->prefix_length:s->prefix_length;
        if(!memcmp(old->prefix,s->prefix,n))result=ZHR_INVALID;
    }
    if(!result&&free_slot==CONNECTIONS)result=ZHR_FULL;
    if(!result){s->context=context;s->filter=filter;s->offer=offer;s->bound=1;server->owners[free_slot]=s;}
    ReleaseSRWLockExclusive(&server->lock);return result;
}
int zhr_check(ZhrOwner *s){if(!s)return ZHR_CLOSED;if(!main_thread(s->server))return ZHR_WRONG_THREAD;return s->bound&&!s->sealed&&!s->closed&&alive_server(s->server)?ZHR_OK:ZHR_CLOSED;}
int zhr_borrow_input(ZhrOwner *s,size_t n){int result=zhr_check(s);if(result)return result;AcquireSRWLockExclusive(&s->server->lock);if(s->borrowed||s->bytes>s->limit||n>s->limit-s->bytes)result=ZHR_CAPACITY;else{s->borrowed=n;if(s->bytes+n>s->peak)s->peak=s->bytes+n;}ReleaseSRWLockExclusive(&s->server->lock);return result;}
void zhr_return_input(ZhrOwner *s){assert(s&&main_thread(s->server));AcquireSRWLockExclusive(&s->server->lock);s->borrowed=0;ReleaseSRWLockExclusive(&s->server->lock);}
void zhr_seal(ZhrOwner *s){
    if(!s)return;assert(main_thread(s->server));ZhtwServer *server=s->server;
    AcquireSRWLockExclusive(&server->lock);s->sealed=1;s->context=NULL;s->filter=NULL;s->offer=NULL;
    for(unsigned i=0;i<CONNECTIONS;i++){if(server->owners[i]==s)server->owners[i]=NULL;ZhtwEnvelope *e=server->slots[i];if(e&&e->owner==s)cancel_envelope(e);}
    ReleaseSRWLockExclusive(&server->lock);wake(server);
}
void zhr_close(ZhrOwner *s){if(!s)return;zhr_seal(s);s->closed=1;}
void zhr_owner_release(ZhrOwner *s){if(s)owner_release(s);}
int zhr_stats(ZhrOwner *s,ZhrStats *out){if(!s||!out)return ZHR_INVALID;if(!main_thread(s->server))return ZHR_WRONG_THREAD;AcquireSRWLockShared(&s->server->lock);*out=(ZhrStats){s->bytes,s->peak,0,s->pending,!s->sealed&&!s->closed&&open_server(s->server)};ReleaseSRWLockShared(&s->server->lock);return ZHR_OK;}
void zhr_counts(ZhrCounts *out){AcquireSRWLockShared(&totals_lock);*out=(ZhrCounts){(uint32_t)load(&owners),0,(uint32_t)load(&envelopes),(uint32_t)load(&tickets),endpoint_bytes,0};ReleaseSRWLockShared(&totals_lock);}

void zhtw_dispatch(ZhtwEnvelope *e,const ZhrRequest *request){
    ZhtwServer *server=e->server;assert(main_thread(server));ZhrOwner *owner=NULL;
    AcquireSRWLockExclusive(&server->lock);
    if(!e->alive||e->dispatched||load(&e->phase)!=PENDING){ReleaseSRWLockExclusive(&server->lock);return;}
    if(!open_server(server)){cancel_envelope(e);ReleaseSRWLockExclusive(&server->lock);return;}
    e->dispatched=1;
    if(request&&request->header_count<=64){
        for(unsigned i=0;i<CONNECTIONS;i++){ZhrOwner *s=server->owners[i];if(s&&s->prefix_length<=request->path.length&&!memcmp(s->prefix,request->path.ptr,s->prefix_length)){owner=s;break;}}
    }
    if(owner&&owner->pending<owner->max_pending){owner_add(owner);e->owner=owner;++owner->pending;e->head=request->method.length==4&&!memcmp(request->method.ptr,"HEAD",4);}else{e->deny=owner?503:404;e->handled=1;owner=NULL;}
    ReleaseSRWLockExclusive(&server->lock);
    if(!owner){wake(server);return;}
    /* Main callbacks may close owner; the envelope's independent C ref pins it. */
    if(!owner->filter||!owner->filter(owner->context,request)){zhtw_reject(e,403);return;}
    if(zhr_check(owner)){cancel_envelope(e);return;}
    ZhrBorrow borrow={e};owner->offer(owner->context,request,&borrow);
    AcquireSRWLockExclusive(&server->lock);if(!e->handled&&e->alive&&load(&e->phase)==PENDING){e->deny=500;e->handled=1;}ReleaseSRWLockExclusive(&server->lock);wake(server);
}
static int target(ZhrTarget target,ZhtwEnvelope **out){
    *out=NULL;if((target.borrow!=NULL)==(target.ticket!=NULL))return ZHR_INVALID;
    ZhtwEnvelope *e=target.borrow?target.borrow->envelope:target.ticket->envelope;
    if(!e||!e->owner)return ZHR_STALE;int status=zhr_check(e->owner);if(status)return status;
    AcquireSRWLockShared(&e->server->lock);int valid=e->alive&&!e->candidate&&!e->preparing&&load(&e->phase)==PENDING&&(!target.borrow||!e->handled);ReleaseSRWLockShared(&e->server->lock);
    if(!valid)return ZHR_STALE;*out=e;return ZHR_OK;
}
int zhr_defer(ZhrBorrow *borrow,ZhrTicket **out){
    if(!out)return ZHR_INVALID;*out=NULL;ZhtwEnvelope *e=NULL;int result=target((ZhrTarget){borrow,NULL},&e);if(result)return result;
    /* Reserve before allocation. Failed preparation leaves the borrow unhandled,
     * and credit is returned only after the actual temporary free has returned. */
    ZhrOwner *owner=e->owner;AcquireSRWLockExclusive(&e->server->lock);
    if(!e->alive||load(&e->phase)!=PENDING){ReleaseSRWLockExclusive(&e->server->lock);return ZHR_CLOSED;}
    if(owner->bytes>owner->limit||owner->borrowed>owner->limit-owner->bytes||sizeof(ZhrTicket)>owner->limit-owner->bytes-owner->borrowed){ReleaseSRWLockExclusive(&e->server->lock);return ZHR_CAPACITY;}
    owner->bytes+=sizeof(ZhrTicket);if(owner->bytes+owner->borrowed>owner->peak)owner->peak=owner->bytes+owner->borrowed;ReleaseSRWLockExclusive(&e->server->lock);
    ZhrTicket *ticket=zero(sizeof(*ticket));
    if(!ticket){AcquireSRWLockExclusive(&e->server->lock);owner->bytes-=sizeof(ZhrTicket);ReleaseSRWLockExclusive(&e->server->lock);return ZHR_OOM;}
    AcquireSRWLockExclusive(&e->server->lock);
    if(!e->alive||load(&e->phase)!=PENDING||owner->sealed||owner->closed||!alive_server(e->server)){
        ReleaseSRWLockExclusive(&e->server->lock);SecureZeroMemory(ticket,sizeof(*ticket));free(ticket);
        AcquireSRWLockExclusive(&e->server->lock);owner->bytes-=sizeof(ZhrTicket);ReleaseSRWLockExclusive(&e->server->lock);return ZHR_CLOSED;
    }
    e->handled=1;ticket->refs=1;ticket->envelope=e;envelope_add(e);ReleaseSRWLockExclusive(&e->server->lock);
    total_add(sizeof(*ticket),1);InterlockedIncrement(&tickets);*out=ticket;return ZHR_OK;
}
int zhr_ticket_owner(ZhrTicket *ticket,void **out){
    if(!out)return ZHR_INVALID;*out=NULL;if(!ticket||!ticket->envelope)return ZHR_STALE;ZhtwEnvelope *e=ticket->envelope;
    if(!main_thread(e->server))return ZHR_WRONG_THREAD;if(!e->owner)return ZHR_STALE;int status=zhr_check(e->owner);if(status)return status;
    AcquireSRWLockShared(&e->server->lock);int valid=e->alive&&load(&e->phase)==PENDING;void *context=e->owner->context;ReleaseSRWLockShared(&e->server->lock);
    if(!valid)return ZHR_STALE;*out=context;return ZHR_OK;
}
static void ticket_drop(ZhrTicket *t,int cancel){
    if(!t)return;if(cancel)cancel_envelope(t->envelope);if(InterlockedDecrement(&t->refs))return;
    ZhtwEnvelope *e=t->envelope;ZhrOwner *owner=e->owner;size_t n=sizeof(*t);SecureZeroMemory(t,n);free(t);
    AcquireSRWLockExclusive(&e->server->lock);assert(owner->bytes>=n);owner->bytes-=n;ReleaseSRWLockExclusive(&e->server->lock);total_sub(n,1);InterlockedDecrement(&tickets);zhtw_envelope_release(e);
}
void zhr_ticket_release(ZhrTicket *ticket){ticket_drop(ticket,1);}
void zhr_ticket_consume(ZhrTicket *ticket){ticket_drop(ticket,0);}
int zhr_ticket_cancel(ZhrTicket *ticket){if(!ticket)return ZHR_STALE;cancel_envelope(ticket->envelope);return ZHR_OK;}

static void candidate_free(ZhrCandidate *candidate){
    ZhtwEnvelope *e=candidate->envelope;ZhrOwner *owner=e->owner;size_t n=candidate->allocation;
    if(candidate->file_candidate)zws_candidate_abort(candidate->file_candidate);
    if(candidate->reader)zws_reader_release(candidate->reader);
    if(candidate->control)zws_control_release(candidate->control);
    SecureZeroMemory(candidate,n);free(candidate);
    AcquireSRWLockExclusive(&e->server->lock);assert(owner->bytes>=n);owner->bytes-=n;ReleaseSRWLockExclusive(&e->server->lock);total_sub(n,1);InterlockedDecrement(&candidates);zhtw_envelope_release(e);
}
static int file_result(int status){return status==ZWS_FULL?ZHR_FULL:status==ZWS_OOM?ZHR_OOM:status==ZWS_CLOSED||status==ZWS_CANCELLED?ZHR_CLOSED:status?ZHR_INVALID:ZHR_OK;}
static int prepare_response(ZhrTarget target_value,const ZhrResponse *response,ZwsChannel *file,int mode,ZhrCandidate **out){
    if(!out)return ZHR_INVALID;*out=NULL;ZhtwEnvelope *e=NULL;int result=target(target_value,&e);if(result)return result;
    if(!response||response->body.length>16u*1024u*1024u||(response->body.length&&!response->body.ptr)||response->header_count>16||(!response->headers&&response->header_count)||(mode==2&&!file))return ZHR_INVALID;
    if(mode==1&&!e->head)return ZHR_INVALID;
    uint64_t length=mode==2?zws_channel_length(file):mode==0?response->body.length:response->length;
    if(length>ZWS_MAX_BYTES)return ZHR_CAPACITY;
    ZhtwServer *server=e->server;ZhrOwner *owner=e->owner;
    unsigned char head[RESPONSE_HEAD_BYTES];size_t head_length=0;
    if(!server->format||server->format(response,length,head,sizeof(head),&head_length)||head_length>sizeof(head))return ZHR_INVALID;
    size_t body=mode==0&&!e->head?response->body.length:0;
    size_t n=sizeof(ZhrCandidate)+head_length+body;
    AcquireSRWLockExclusive(&server->lock);
    if(!e->alive||e->candidate||e->preparing||load(&e->phase)!=PENDING){ReleaseSRWLockExclusive(&server->lock);return ZHR_STALE;}
    if(owner->bytes>owner->limit||owner->borrowed>owner->limit-owner->bytes||n>owner->limit-owner->bytes-owner->borrowed){ReleaseSRWLockExclusive(&server->lock);return ZHR_CAPACITY;}
    e->preparing=1;owner->bytes+=n;if(owner->bytes+owner->borrowed>owner->peak)owner->peak=owner->bytes+owner->borrowed;ReleaseSRWLockExclusive(&server->lock);
    ZhrCandidate *candidate=zero(n);
    if(!candidate){AcquireSRWLockExclusive(&server->lock);e->preparing=0;owner->bytes-=n;ReleaseSRWLockExclusive(&server->lock);return ZHR_OOM;}
    candidate->allocation=n;candidate->envelope=e;envelope_add(e);candidate->head_length=head_length;candidate->memory_length=body;candidate->length=length;candidate->head=e->head;
    memcpy(candidate->bytes,head,head_length);if(body)memcpy(candidate->bytes+head_length,response->body.ptr,body);
    total_add(n,1);InterlockedIncrement(&candidates);
    if(mode==2){
        if(!owner->file_budget){owner->file_budget=zws_budget_create(owner->file_streams);if(!owner->file_budget){result=ZHR_OOM;goto fail;}}
        result=file_result(zws_candidate_prepare(file,owner->file_budget,e->head,&candidate->file_candidate));if(result)goto fail;
        candidate->reader=zws_candidate_reader(candidate->file_candidate);zws_reader_add(candidate->reader);
        candidate->control=zws_candidate_control(candidate->file_candidate);zws_control_add(candidate->control);
    }
    AcquireSRWLockExclusive(&server->lock);e->preparing=0;
    if(!e->alive||load(&e->phase)!=PENDING||owner->sealed||owner->closed||!alive_server(server)){ReleaseSRWLockExclusive(&server->lock);result=ZHR_CLOSED;goto fail;}
    e->candidate=candidate;ReleaseSRWLockExclusive(&server->lock);*out=candidate;return ZHR_OK;
fail:
    AcquireSRWLockExclusive(&server->lock);e->preparing=0;ReleaseSRWLockExclusive(&server->lock);candidate_free(candidate);return result;
}
int zhr_prepare_memory(ZhrTarget t,const ZhrResponse *r,ZhrCandidate **out){return prepare_response(t,r,NULL,0,out);}
int zhr_prepare_head(ZhrTarget t,const ZhrResponse *r,ZhrCandidate **out){return prepare_response(t,r,NULL,1,out);}
int zhr_prepare_file(ZhrTarget t,const ZhrResponse *r,void *f,ZhrCandidate **out){return prepare_response(t,r,f,2,out);}
void zhr_candidate_abort(ZhrCandidate *c){if(!c)return;assert(!c->admitted);ZhtwEnvelope *e=c->envelope;AcquireSRWLockExclusive(&e->server->lock);if(e->candidate==c)e->candidate=NULL;ReleaseSRWLockExclusive(&e->server->lock);candidate_free(c);}
int zhr_candidate_check(ZhrCandidate *c,void *context){if(!c||c->admitted)return ZHR_STALE;ZhtwEnvelope *e=c->envelope;int result=zhr_check(e->owner);if(result)return result;AcquireSRWLockShared(&e->server->lock);int valid=e->alive&&e->candidate==c&&e->owner->context==context&&load(&e->phase)==PENDING;ReleaseSRWLockShared(&e->server->lock);return valid?ZHR_OK:ZHR_STALE;}
int zhr_candidate_admit(ZhrCandidate *c,int want_control,void **out){
    if(out)*out=NULL;assert(c&&!c->admitted);ZhtwEnvelope *e=c->envelope;ZhtwServer *s=e->server;assert(main_thread(s));
    AcquireSRWLockExclusive(&s->lock);c->admitted=1;e->handled=1;int accepted=InterlockedCompareExchange(&e->phase,ACCEPTED,PENDING)==PENDING;
    int cancelled=!accepted||!e->alive||e->owner->sealed||!alive_server(s);ReleaseSRWLockExclusive(&s->lock);
    if(want_control&&out&&c->control){zws_control_add(c->control);*out=c->control;}return cancelled;
}
void zhr_candidate_admit_source(ZhrCandidate *c){
    assert(c&&c->admitted);if(c->source_admitted)return;c->source_admitted=1;
    if(c->file_candidate){ZwsCandidate *source=c->file_candidate;c->file_candidate=NULL;ZhtwEnvelope *e=c->envelope;
        AcquireSRWLockShared(&e->server->lock);int cancelled=!e->alive||e->owner->sealed||load(&e->phase)!=ACCEPTED;ReleaseSRWLockShared(&e->server->lock);zws_candidate_admit(source,cancelled,NULL);}
}
int zhr_candidate_start(ZhrCandidate *c){
    assert(c&&c->admitted);zhr_candidate_admit_source(c);ZhtwEnvelope *e=c->envelope;ZhtwServer *s=e->server;
    AcquireSRWLockExclusive(&s->lock);int cancelled=!e->alive||e->owner->sealed||!alive_server(s)||load(&e->phase)!=ACCEPTED;
    if(cancelled){InterlockedCompareExchange(&e->phase,CANCELLED,PENDING);InterlockedCompareExchange(&e->phase,CANCELLED,ACCEPTED);}
    c->ready=1;int detached=!e->alive;if(detached){assert(e->candidate==c);e->candidate=NULL;}
    /* Publishing ready transfers the candidate to the worker. Signal while
     * its independent envelope/server pin is still protected by this lock;
     * after unlock a live worker may free every candidate field immediately. */
    wake(s);ReleaseSRWLockExclusive(&s->lock);
    if(detached)candidate_free(c);return cancelled;
}

/* ---------- The sole explicit worker owns all Winsock/TLS payload. ---------- */
static int socket_send(void *context,const unsigned char *bytes,size_t length){Connection *c=context;int n=send(c->socket,(const char *)bytes,(int)length,0);if(n>=0)return n;return WSAGetLastError()==WSAEWOULDBLOCK?ZHTP_IO_AGAIN:ZHTP_IO_FAILED;}
static int socket_receive(void *context,unsigned char *bytes,size_t length){Connection *c=context;int n=recv(c->socket,(char *)bytes,(int)length,0);if(n>=0)return n;return WSAGetLastError()==WSAEWOULDBLOCK?ZHTP_IO_AGAIN:ZHTP_IO_FAILED;}
static void tls_snapshot(ZhtwServer *s){ZhtpStats stats={0};if(s->worker&&s->worker->provider)zhtp_stats(s->worker->provider,&stats);AcquireSRWLockExclusive(&s->lock);s->tls_live=stats.live;if(stats.peak>s->tls_peak)s->tls_peak=stats.peak;server_peak(s);ReleaseSRWLockExclusive(&s->lock);}
static void connection_close(ZhtwServer *s,Connection *c){
    if(!c->envelope)return;ZhtwEnvelope *e=c->envelope;ZhrCandidate *response=NULL;
    AcquireSRWLockExclusive(&s->lock);e->alive=0;InterlockedCompareExchange(&e->phase,CANCELLED,PENDING);InterlockedCompareExchange(&e->phase,CANCELLED,ACCEPTED);
    if(e->candidate&&e->candidate->ready){response=e->candidate;e->candidate=NULL;}ReleaseSRWLockExclusive(&s->lock);
    if(c->tls)zhtp_connection_destroy(&c->tls);if(c->socket!=INVALID_SOCKET)closesocket(c->socket);if(c->event!=WSA_INVALID_EVENT)WSACloseEvent(c->event);
    SecureZeroMemory(c,sizeof(*c));c->socket=INVALID_SOCKET;c->event=WSA_INVALID_EVENT;
    if(response)candidate_free(response);InterlockedDecrement(&connection_count);zhtw_envelope_release(e);
#ifdef ZHTW_TESTING
    if(test_connection_closed)SetEvent(test_connection_closed);
#endif
}
static int perform_write(Connection *c,int *native_error){
    size_t n=0;int result=zhtp_write(c->tls,c->write_pointer+c->write_offset,c->write_length-c->write_offset,&n,native_error);
    c->want=result;
#ifdef ZHTW_TESTING
    if(result==ZHTP_WRITE&&test_write_wait&&c->response&&c->response->reader&&c->write_pointer==c->body&&c->source_received<c->response->length)SetEvent(test_write_wait);
#endif
    if(result==ZHTP_READ||result==ZHTP_WRITE)return 0;if(result!=ZHTP_OK||!n||n>c->write_length-c->write_offset)return -1;
    c->write_offset+=n;return c->write_offset==c->write_length?1:0;
}
static void write_begin(Connection *c,const unsigned char *p,size_t n){assert(n);c->write_pointer=p;c->write_length=n;c->write_offset=0;}
static void response_step(ZhtwServer *s,Connection *c){
    ZhtwEnvelope *e=c->envelope;int error=0;c->source_wait=c->finish_wait=0;
    if(!c->response&&c->state==WAIT_RESPONSE){
        AcquireSRWLockShared(&s->lock);ZhrCandidate *response=e->candidate;unsigned deny=e->deny;int ready=response&&response->ready;ReleaseSRWLockShared(&s->lock);
        if(deny){int n=snprintf((char *)c->body,sizeof(c->body),"HTTP/1.1 %u Rejected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",deny);if(n<=0||(size_t)n>=sizeof(c->body)){connection_close(s,c);return;}write_begin(c,c->body,(size_t)n);c->header_done=c->body_done=1;c->state=RESPONSE;}
        else if(!ready)return;
        else{c->response=response;c->state=RESPONSE;}
    }
    ZhrCandidate *response=c->response;
    if(response&&response->reader){
        HANDLE data,cancel;zws_reader_wait_handles(response->reader,&data,&cancel);
        /* The cancel handle is level-triggered. Consume its meaning before a
         * possible TLS WANT retry, otherwise it could wake that retry forever. */
        DWORD cancelled=WaitForSingleObject(cancel,0);
        if(cancelled==WAIT_OBJECT_0||cancelled==WAIT_FAILED){connection_close(s,c);return;}
    }
    /* A 0-byte generated body has no final record to withhold: withhold its
     * headers until the producer has actually finished successfully. */
    if(response&&!response->head&&response->reader&&response->length==0&&!c->header_done){
        int result=0;uint32_t code=0;int status=zws_reader_terminal(response->reader,&result,&code);
        if(status==ZWS_PENDING){c->finish_wait=1;return;}if(status!=ZWS_OK||result){connection_close(s,c);return;}
    }
    if(!c->write_length){
        if(!c->header_done){assert(response);write_begin(c,response->bytes,response->head_length);c->header_done=1;}
        else if(!c->body_done){
            if(response->head){c->body_done=1;}
            else if(response->reader){
                if(c->source_received==response->length){
                    int result=0;uint32_t code=0;int status=zws_reader_terminal(response->reader,&result,&code);
                    if(status==ZWS_PENDING){c->finish_wait=1;return;}if(status!=ZWS_OK||result){connection_close(s,c);return;}c->body_done=1;
                }else{
                    size_t count=0;uint32_t code=0;int status=zws_reader_try_read(response->reader,c->body,sizeof(c->body),&count,&code);
                    if(status==ZWS_PENDING){c->source_wait=1;return;}
                    if(status!=ZWS_OK||!count||count>response->length-c->source_received){connection_close(s,c);return;}
                    c->source_received+=count;write_begin(c,c->body,count);
                }
            }else{
                if(c->body_sent==response->memory_length)c->body_done=1;
                else{size_t count=response->memory_length-(size_t)c->body_sent;if(count>CHUNK)count=CHUNK;write_begin(c,response->bytes+response->head_length+(size_t)c->body_sent,count);}
            }
        }
        if(c->body_done&&!c->write_length)c->state=SHUTDOWN;
    }
    /* Last plaintext chunk is stable and withheld until exact producer finish.
     * A library WANT retry always uses the identical pointer and length. */
    if(response&&response->reader&&!response->head&&c->write_length&&c->write_pointer==c->body&&c->source_received==response->length&&c->write_offset==0){
        int result=0;uint32_t code=0;int status=zws_reader_terminal(response->reader,&result,&code);
        if(status==ZWS_PENDING){c->finish_wait=1;return;}if(status!=ZWS_OK||result){connection_close(s,c);return;}
    }
    if(c->write_length){
        int done=perform_write(c,&error);if(done<0){connection_close(s,c);return;}
        if(done){if(response&&c->write_pointer!=response->bytes)c->body_sent+=c->write_length;c->write_length=c->write_offset=0;c->write_pointer=NULL;c->want=ZHTP_OK;wake(s);}
    }
    if(c->state==SHUTDOWN){int status=zhtp_shutdown(c->tls,&error);c->want=status;if(status==ZHTP_READ||status==ZHTP_WRITE)return;if(status==ZHTP_OK)InterlockedCompareExchange(&e->phase,FINISHED,ACCEPTED);connection_close(s,c);}
}
static void connection_step(ZhtwServer *s,Connection *c){
    if(!c->envelope)return;ZhtwEnvelope *e=c->envelope;
    if(load(&s->cancelled)||load(&e->phase)==CANCELLED){connection_close(s,c);return;}
    if(load(&s->sealed)){
        /* No new owner may be acquired after seal. An accepted App post still
         * owns its own envelope ref and must execute/release even if this worker
         * has already retired an unclaimed socket. Owner publication is protected
         * by the same lock as dispatch, including malformed/404/503 responses. */
        int unclaimed=c->state==HANDSHAKE||c->state==REQUEST;
        if(!unclaimed){AcquireSRWLockShared(&s->lock);unclaimed=e->owner==NULL;ReleaseSRWLockShared(&s->lock);}
        if(unclaimed){connection_close(s,c);return;}
    }
    int error=0;
    if(c->state==HANDSHAKE){int status=zhtp_handshake(c->tls,&error);c->want=status;if(status==ZHTP_READ||status==ZHTP_WRITE)return;if(status!=ZHTP_OK){connection_close(s,c);return;}c->state=REQUEST;}
    if(c->state==REQUEST){
        /* Request bodies are never exposed/read. Read through the exact head
         * delimiter, one plaintext byte at a time; no over-read into a body. */
        while(e->head_length<HEAD_BYTES){
            size_t n=0;int status=zhtp_read(c->tls,e->request_head+e->head_length,1,&n,&error);c->want=status;
            if(status==ZHTP_READ||status==ZHTP_WRITE)return;
            if(status!=ZHTP_OK||n!=1){connection_close(s,c);return;}++e->head_length;
#ifdef ZHTW_TESTING
            if(e->head_length==1&&test_request_byte)SetEvent(test_request_byte);
#endif
            if(e->head_length>=4&&!memcmp(e->request_head+e->head_length-4,"\r\n\r\n",4)){
                c->state=WAIT_RESPONSE;envelope_add(e);
                /* Copy the App-only post gate under lock. App outlives this
                 * in-flight call even if main seals/frees its Transport. */
                AcquireSRWLockShared(&s->lock);ZhtwPost post=s->post;void *app=s->app;int allowed=open_server(s);ReleaseSRWLockShared(&s->lock);
                if(!allowed||!post||post(app,e)){zhtw_envelope_release(e);connection_close(s,c);}return;
            }
        }
        connection_close(s,c);return;
    }
    if(c->state==WAIT_RESPONSE||c->state==RESPONSE||c->state==SHUTDOWN)response_step(s,c);
}
static int accept_one(ZhtwServer *s,ZhtwFailure *failure_out){
    Worker *worker=s->worker;struct sockaddr_in peer;int size=sizeof(peer);SOCKET socket=accept(worker->listener,(struct sockaddr *)&peer,&size);
    if(socket==INVALID_SOCKET){int code=WSAGetLastError();if(code==WSAEWOULDBLOCK)return 0;failure(failure_out,1,code);return -1;}
    if(size!=sizeof(peer)||peer.sin_family!=AF_INET||ntohl(peer.sin_addr.s_addr)!=INADDR_LOOPBACK){closesocket(socket);return 1;}
#ifdef ZHTW_TESTING
    if(test_write_wait){int bytes=4096;if(setsockopt(socket,SOL_SOCKET,SO_SNDBUF,(const char *)&bytes,sizeof(bytes))){closesocket(socket);return 1;}}
#endif
    unsigned slot=CONNECTIONS;AcquireSRWLockShared(&s->lock);for(unsigned i=0;i<s->connection_limit;i++)if(!s->reserved[i]){slot=i;break;}ReleaseSRWLockShared(&s->lock);
    if(slot==CONNECTIONS){closesocket(socket);return 1;}
    LONG prior=load(&envelopes);for(;;){if(prior>=32){closesocket(socket);return 1;}LONG observed=InterlockedCompareExchange(&envelopes,prior+1,prior);if(observed==prior)break;prior=observed;}
    ZhtwEnvelope *e=zero(sizeof(*e));if(!e){InterlockedDecrement(&envelopes);closesocket(socket);return 1;}
    e->refs=1;e->server=s;e->slot=slot;e->alive=1;zhtw_ref(s);
    AcquireSRWLockExclusive(&s->lock);assert(!s->slots[slot]&&!s->reserved[slot]);s->slots[slot]=e;s->reserved[slot]=1;s->bytes+=sizeof(*e);server_peak(s);ReleaseSRWLockExclusive(&s->lock);total_add(sizeof(*e),0);
    Connection *c=&worker->connections[slot];assert(!c->envelope);memset(c,0,sizeof(*c));c->socket=socket;c->event=WSACreateEvent();c->envelope=e;c->state=HANDSHAKE;InterlockedIncrement(&connection_count);
    if(c->event==WSA_INVALID_EVENT||WSAEventSelect(socket,c->event,FD_READ|FD_WRITE|FD_CLOSE)){connection_close(s,c);return 1;}
    int code=0;int result=zhtp_connection_create(worker->provider,(ZhtpIO){c,socket_send,socket_receive},&c->tls,&code);
    if(result){connection_close(s,c);return 1;}
#ifdef ZHTW_TESTING
    if(test_accepted)SetEvent(test_accepted);
#endif
    connection_step(s,c);return 1;
}
static void close_listener(Worker *worker){if(worker->listener!=INVALID_SOCKET){closesocket(worker->listener);worker->listener=INVALID_SOCKET;}if(worker->listener_event!=WSA_INVALID_EVENT){WSACloseEvent(worker->listener_event);worker->listener_event=WSA_INVALID_EVENT;}}
static void worker_destroy(ZhtwServer *s){
    Worker *worker=s->worker;if(!worker)return;assert(GetCurrentThreadId()==s->worker_thread);
    close_listener(worker);for(unsigned i=0;i<CONNECTIONS;i++)connection_close(s,&worker->connections[i]);
    if(worker->provider){int result=zhtp_destroy(&worker->provider);assert(result==ZHTP_OK);}
    if(worker->winsock)WSACleanup();size_t n=sizeof(*worker);s->worker=NULL;SecureZeroMemory(worker,n);free(worker);
    AcquireSRWLockExclusive(&s->lock);assert(s->bytes>=n);s->bytes-=n;s->tls_live=0;InterlockedExchange(&s->done,1);ReleaseSRWLockExclusive(&s->lock);total_sub(n,0);InterlockedDecrement(&payloads);
}
int zhtw_prepare(uint64_t main_id,const uint8_t *cert,size_t cert_length,const uint8_t *key,size_t key_length,const ZhtwLimits *limits,ZhtwServer **prepared,ZhtwServer **driver,ZhtwFailure *error){
    if(prepared)*prepared=NULL;if(driver)*driver=NULL;if(error)*error=(ZhtwFailure){0,0};
    if(!prepared||!driver||!limits||!main_id||main_id>UINT32_MAX||!cert||!key||!limits->connections||limits->connections>CONNECTIONS||limits->bytes>64u*1024u*1024u)return ZHR_INVALID;
    if(main_id==GetCurrentThreadId())return ZHR_WRONG_THREAD;
    size_t reservation=sizeof(ZhtwServer)+sizeof(Worker)+limits->connections*sizeof(ZhtwEnvelope);
    if(limits->bytes<reservation+256u*1024u)return ZHR_CAPACITY;
    ZhtwServer *s=zero(sizeof(*s));if(!s)return ZHR_OOM;
    s->refs=1;s->worker_thread=GetCurrentThreadId();s->main_thread=(DWORD)main_id;s->connection_limit=limits->connections;s->limit=limits->bytes;s->bytes=s->metadata_peak=s->peak=sizeof(*s);
    InitializeSRWLock(&s->lock);s->wake=CreateEventW(NULL,TRUE,FALSE,NULL);
    if(!s->wake){failure(error,1,(int)GetLastError());free(s);return ZHR_NATIVE;}
    InterlockedIncrement(&servers);total_add(sizeof(*s),0);
    Worker *worker=zero(sizeof(*worker));if(!worker){InterlockedExchange(&s->done,1);zhtw_unref(s);return ZHR_OOM;}
    worker->listener=INVALID_SOCKET;worker->listener_event=WSA_INVALID_EVENT;for(unsigned i=0;i<CONNECTIONS;i++){worker->connections[i].socket=INVALID_SOCKET;worker->connections[i].event=WSA_INVALID_EVENT;}
    s->worker=worker;s->bytes+=sizeof(*worker);server_peak(s);InterlockedIncrement(&payloads);total_add(sizeof(*worker),0);
    int native_error=0;int tls=zhtp_create(main_id,cert,cert_length,key,key_length,limits->bytes-reservation,&worker->provider,&native_error);
    int result=ZHR_NATIVE;
    if(tls){failure(error,2,native_error);result=tls==ZHTP_OOM?ZHR_OOM:tls==ZHTP_BUDGET?ZHR_CAPACITY:ZHR_NATIVE;goto fail;}
    tls_snapshot(s);WSADATA data;int winsock=WSAStartup(MAKEWORD(2,2),&data);if(winsock){failure(error,1,winsock);goto fail;}worker->winsock=1;
    worker->listener=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);if(worker->listener==INVALID_SOCKET){failure(error,1,WSAGetLastError());goto fail;}
    BOOL exclusive=TRUE;if(setsockopt(worker->listener,SOL_SOCKET,SO_EXCLUSIVEADDRUSE,(const char *)&exclusive,sizeof(exclusive))){failure(error,1,WSAGetLastError());goto fail;}
    struct sockaddr_in local;memset(&local,0,sizeof(local));local.sin_family=AF_INET;local.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    if(bind(worker->listener,(const struct sockaddr *)&local,sizeof(local))||listen(worker->listener,SOMAXCONN)){failure(error,1,WSAGetLastError());goto fail;}
    int length=sizeof(local);if(getsockname(worker->listener,(struct sockaddr *)&local,&length)||length!=sizeof(local)||!local.sin_port){failure(error,1,WSAGetLastError());goto fail;}s->port=ntohs(local.sin_port);
    worker->listener_event=WSACreateEvent();if(worker->listener_event==WSA_INVALID_EVENT||WSAEventSelect(worker->listener,worker->listener_event,FD_ACCEPT|FD_CLOSE)){failure(error,1,WSAGetLastError());goto fail;}
    zhtw_ref(s);*prepared=s;*driver=s;return ZHR_OK;
fail:
    worker_destroy(s);zhtw_unref(s);return result;
}
int zhtw_adopt(ZhtwServer *s,void *app,ZhtwPost post,ZhtwFormat format){
    if(!s||!app||!post||!format)return ZHR_INVALID;if(!main_thread(s))return ZHR_WRONG_THREAD;
    AcquireSRWLockExclusive(&s->lock);int result=ZHR_OK;if(load(&s->sealed)||load(&s->done)||load(&s->adopted))result=ZHR_CLOSED;else{s->app=app;s->post=post;s->format=format;InterlockedExchange(&s->adopted,1);}ReleaseSRWLockExclusive(&s->lock);wake(s);return result;
}
int zhtw_seal(ZhtwServer *s){if(!s)return ZHR_INVALID;if(!main_thread(s))return ZHR_WRONG_THREAD;InterlockedExchange(&s->sealed,1);wake(s);return ZHR_OK;}
void zhtw_cancel(ZhtwServer *s){if(!s)return;InterlockedExchange(&s->sealed,1);InterlockedExchange(&s->cancelled,1);wake(s);}
int zhtw_run(ZhtwServer *s,ZhtwFailure *error){
    if(error)*error=(ZhtwFailure){0,0};if(!s)return ZHR_INVALID;if(GetCurrentThreadId()!=s->worker_thread)return ZHR_WRONG_THREAD;
    if(load(&s->done)||!load(&s->adopted)||InterlockedCompareExchange(&s->running,1,0))return ZHR_INVALID;
    Worker *worker=s->worker;int result=ZHR_OK;
    for(;;){
        AcquireSRWLockExclusive(&s->lock);ResetEvent(s->wake);ReleaseSRWLockExclusive(&s->lock);
        if(load(&s->sealed))close_listener(worker);
        unsigned active=0;for(unsigned i=0;i<s->connection_limit;i++){Connection *c=&worker->connections[i];connection_step(s,c);if(c->envelope)++active;}
        /* An arbitrary incoming burst cannot monopolize this thread ahead of
         * its existing eight TLS/source connections. Remaining accept work
         * stays explicit and yields through the common event-loop boundary. */
        if(worker->listener!=INVALID_SOCKET&&worker->accept_ready){
            for(unsigned burst=0;burst<16;burst++){
                int accepted=accept_one(s,error);
                if(accepted<0){result=ZHR_NATIVE;break;}
                if(!accepted){worker->accept_ready=0;break;}
                if(load(&s->sealed)){worker->accept_ready=0;break;}
            }
            if(result)break;if(worker->accept_ready)wake(s);
            active=0;for(unsigned i=0;i<s->connection_limit;i++)if(worker->connections[i].envelope)++active;
        }
        tls_snapshot(s);if(worker->listener==INVALID_SOCKET&&!active)break;
        HANDLE handles[2+CONNECTIONS*3];Connection *socket_owner[2+CONNECTIONS*3];unsigned type[2+CONNECTIONS*3],count=0;
        handles[count]=s->wake;socket_owner[count]=NULL;type[count++]=0;
        if(worker->listener!=INVALID_SOCKET){handles[count]=worker->listener_event;socket_owner[count]=NULL;type[count++]=1;}
        for(unsigned i=0;i<s->connection_limit;i++){
            Connection *c=&worker->connections[i];if(!c->envelope)continue;
            handles[count]=c->event;socket_owner[count]=c;type[count++]=2;
            if(c->response&&c->response->reader){HANDLE data,cancel;zws_reader_wait_handles(c->response->reader,&data,&cancel);
                handles[count]=cancel;socket_owner[count]=c;type[count++]=3;
                /* Never wait on perpetually readable source data while TLS is
                 * backpressured or a stable record is awaiting a WANT retry. */
                if(c->source_wait||c->finish_wait){handles[count]=data;socket_owner[count]=c;type[count++]=3;}
            }
        }
        assert(count<=MAXIMUM_WAIT_OBJECTS);DWORD selected=WaitForMultipleObjects(count,handles,FALSE,INFINITE);
        if(selected<WAIT_OBJECT_0||selected>=WAIT_OBJECT_0+count){failure(error,1,(int)GetLastError());result=ZHR_NATIVE;break;}
        unsigned index=selected-WAIT_OBJECT_0;
        if(type[index]==1){WSANETWORKEVENTS events;if(WSAEnumNetworkEvents(worker->listener,worker->listener_event,&events)){failure(error,1,WSAGetLastError());result=ZHR_NATIVE;break;}
            if(events.lNetworkEvents&FD_CLOSE){failure(error,1,events.iErrorCode[FD_CLOSE_BIT]);result=ZHR_NATIVE;break;}
            if(events.lNetworkEvents&FD_ACCEPT){worker->accept_ready=1;wake(s);}
        }else if(type[index]==2){Connection *c=socket_owner[index];WSANETWORKEVENTS events;
            if(WSAEnumNetworkEvents(c->socket,c->event,&events)||(events.lNetworkEvents&FD_CLOSE))connection_close(s,c);
        }
    }
    InterlockedExchange(&s->sealed,1);worker_destroy(s);InterlockedExchange(&s->running,0);return result;
}
int zhtw_release_driver(ZhtwServer **token){
    if(!token||!*token)return ZHR_INVALID;ZhtwServer *s=*token;if(GetCurrentThreadId()!=s->worker_thread)return ZHR_WRONG_THREAD;if(load(&s->running))return ZHR_INVALID;
    *token=NULL;zhtw_cancel(s);worker_destroy(s);zhtw_unref(s);return ZHR_OK;
}
int zhtw_stats(ZhtwServer *s,ZhtwStats *out){if(!s||!out)return ZHR_INVALID;if(!main_thread(s))return ZHR_WRONG_THREAD;AcquireSRWLockShared(&s->lock);unsigned count=0;for(unsigned i=0;i<s->connection_limit;i++)if(s->slots[i])++count;*out=(ZhtwStats){s->bytes,s->peak,s->tls_live,s->tls_peak,count,open_server(s),s->port,(uint32_t)load(&s->running)};ReleaseSRWLockShared(&s->lock);return ZHR_OK;}
int zhtw_lease_begin(ZhtwServer *s,ZhtwServer **out,uint16_t *port){if(!out||!port)return ZHR_INVALID;*out=NULL;void *pin=NULL;int result=zhr_server_pin(s,&pin);if(result)return result;*out=pin;*port=s->port;return ZHR_OK;}
int zhtw_lease_finish(ZhtwServer **lease){if(!lease||!*lease)return ZHR_INVALID;ZhtwServer *s=*lease;*lease=NULL;int result=main_thread(s)?open_server(s)?ZHR_OK:ZHR_CLOSED:ZHR_WRONG_THREAD;zhtw_unref(s);return result;}
void zhtw_counts(ZhtwCounts *out){AcquireSRWLockShared(&totals_lock);*out=(ZhtwCounts){(uint32_t)load(&servers),(uint32_t)load(&payloads),(uint32_t)load(&envelopes),(uint32_t)load(&connection_count),total_bytes};ReleaseSRWLockShared(&totals_lock);}
