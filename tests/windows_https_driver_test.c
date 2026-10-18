/* Isolated real loopback TCP/TLS reactor oracle. This has no App/Window: its
 * explicit test driver may join its own workers. The later public fixture
 * separately verifies App.post and actual browser integration. */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include "../src/https_resources/windows_driver.h"
#include "../src/https_resources/windows_tls_provider.h"
#include "../src/file_stream/windows_core.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define REQUIRE(x) do{if(!(x)){fprintf(stderr,"HTTPS reactor line %d: %s\n",__LINE__,#x);fflush(stderr);ExitProcess(1);}}while(0)
typedef void (*Dispatch)(void *);
typedef struct Material {unsigned char certificate[16384],key[16384];size_t certificate_length,key_length;} Material;
enum { MEMORY,GENERATED,ZERO,HEAD,SHORT_BODY,ORIGIN_DENIED,RANGE_DENIED,BODY_DENIED,HOST_DENIED,POST_FULL,POST_CLOSED,LATE_TICKET,WRONG_CERT,ABANDONED,SEAL_BEFORE_DISPATCH,SEAL_AFTER_DEFER,CANCEL_SOURCE,SEAL_HANDSHAKE,SEAL_PARTIAL_REQUEST,SEAL_PARSE_REJECT,SEAL_NO_ROUTE,TICKET_BUDGET,TICKET_OOM,CASES };
static const char *names[]={"memory","generated","zero","head","short","origin_denied","range_denied","body_denied","host_denied","post_full","post_closed","late_ticket","wrong_cert","never_run","seal_before_dispatch","seal_after_defer","cancel_source_WANT_WRITE","seal_half_handshake","seal_partial_request","seal_parse_reject","seal_no_route","ticket_preallocation_budget","ticket_OOM_preserves_borrow"};
static int memory_mode(unsigned mode){return mode==MEMORY||mode==SEAL_AFTER_DEFER||mode==TICKET_BUDGET||mode==TICKET_OOM;}
typedef struct Test Test;
typedef struct Producer {
    DWORD main;HANDLE ready,retire;ZwsChannel *source,*writer;uint64_t length;
    int prepare,begin,head,finish;uint32_t error;size_t writes;int short_body;
} Producer;
struct Test {
    DWORD main;Material *material,*other;unsigned mode;uint16_t port;
    HANDLE ready,go,post_event,client_done,write_wait,connection_closed,allow_client_read,ingress,allow_post_return;
    SRWLOCK post_lock;ZhtwEnvelope *posted;
    ZhtwServer *prepared,*driver;ZhrOwner *owner;ZhrTicket *ticket;
    ZhtwPost post;ZhtwFormat format;Dispatch dispatch;ZhrFilter filter;
    Producer producer;HANDLE producer_thread;
    int prepare_result,run_result,client_result,client_status;ZhtwFailure failure;
    unsigned posts,offers;size_t body_bytes;ZwsControl *control;
};
static unsigned char pattern(size_t i){return (unsigned char)(i*37+11);}
static int read_material(const char *directory,const char *name,unsigned char *bytes,size_t *length){
    char path[2048];int n=snprintf(path,sizeof(path),"%s/%s",directory,name);if(n<0||(size_t)n>=sizeof(path))return 1;
    FILE *file=fopen(path,"rb");if(!file)return 1;*length=fread(bytes,1,16384,file);int result=ferror(file)||!*length||!feof(file);fclose(file);return result;
}
static DWORD WINAPI produce(void *context){
    Producer *p=context;p->prepare=zws_channel_prepare(p->main,p->length,ZWS_MAX_BYTES,ZWS_GENERATED,&p->source,&p->writer,&p->error);SetEvent(p->ready);if(p->prepare)return 0;
    p->begin=zws_writer_begin(p->writer,&p->head,&p->error);
    if(p->begin==ZWS_OK){
        if(!p->head){unsigned char bytes[16384];uint64_t offset=0,maximum=p->short_body?1:p->length;
            while(offset<maximum){size_t n=(size_t)(maximum-offset);if(n>sizeof(bytes))n=sizeof(bytes);for(size_t i=0;i<n;i++)bytes[i]=pattern((size_t)offset+i);
                int result=zws_writer_write(p->writer,bytes,n,&p->error);if(result){p->finish=result;goto retired;}++p->writes;offset+=n;}
        }
        p->finish=zws_writer_finish(p->writer,&p->error);
    }else p->finish=p->begin;
retired:
    REQUIRE(WaitForSingleObject(p->retire,30000)==WAIT_OBJECT_0);zws_producer_release(p->writer);p->writer=NULL;return 0;
}
static int post(void *context,ZhtwEnvelope *envelope){
    Test *t=context;InterlockedIncrement((LONG *)&t->posts);
    if(t->mode==POST_FULL||t->mode==POST_CLOSED)return 1;
    AcquireSRWLockExclusive(&t->post_lock);REQUIRE(!t->posted);t->posted=envelope;ReleaseSRWLockExclusive(&t->post_lock);SetEvent(t->post_event);
    /* A native test-only rendezvous makes the ownerless WAIT_RESPONSE state
     * deterministic. The production post callback contains no worker wait. */
    if(t->allow_post_return)REQUIRE(WaitForSingleObject(t->allow_post_return,30000)==WAIT_OBJECT_0);return 0;
}
static DWORD WINAPI driver(void *context){
    Test *t=context;ZhtwLimits limits={4u*1024u*1024u,8};
    t->prepare_result=zhtw_prepare(t->main,t->material->certificate,t->material->certificate_length,t->material->key,t->material->key_length,&limits,&t->prepared,&t->driver,&t->failure);
    SetEvent(t->ready);if(t->prepare_result)return 0;REQUIRE(WaitForSingleObject(t->go,30000)==WAIT_OBJECT_0);
    if(t->mode!=ABANDONED)t->run_result=zhtw_run(t->driver,&t->failure);
    REQUIRE(zhtw_release_driver(&t->driver)==0&&!t->driver);return 0;
}
typedef struct Client {SOCKET socket;unsigned fragment;} Client;
static int client_send(void *context,const unsigned char *bytes,size_t n){Client *c=context;if(n>c->fragment)n=c->fragment;int result=send(c->socket,(const char *)bytes,(int)n,0);return result==SOCKET_ERROR?ZHTP_IO_FAILED:result;}
static int client_receive(void *context,unsigned char *bytes,size_t n){Client *c=context;if(n>c->fragment)n=c->fragment;int result=recv(c->socket,(char *)bytes,(int)n,0);return result==SOCKET_ERROR?ZHTP_IO_FAILED:result;}
static DWORD WINAPI client(void *context){
    Test *t=context;int error=0;ZhtpProvider *provider=NULL;ZhtpConnection *tls=NULL;Client port={INVALID_SOCKET,13};int failed=1;
    REQUIRE(zhtp_client_create(t->main,1024u*1024u,&provider,&error)==0);
    port.socket=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);REQUIRE(port.socket!=INVALID_SOCKET);
    if(t->mode==CANCEL_SOURCE){int bytes=1024;REQUIRE(!setsockopt(port.socket,SOL_SOCKET,SO_RCVBUF,(const char *)&bytes,sizeof(bytes)));}
    DWORD timeout=15000;REQUIRE(!setsockopt(port.socket,SOL_SOCKET,SO_RCVTIMEO,(const char *)&timeout,sizeof(timeout)));REQUIRE(!setsockopt(port.socket,SOL_SOCKET,SO_SNDTIMEO,(const char *)&timeout,sizeof(timeout)));
    struct sockaddr_in address;memset(&address,0,sizeof(address));address.sin_family=AF_INET;address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);address.sin_port=htons(t->port);
    REQUIRE(!connect(port.socket,(const struct sockaddr *)&address,sizeof(address)));
    if(t->mode==SEAL_HANDSHAKE){
        REQUIRE(WaitForSingleObject(t->connection_closed,20000)==WAIT_OBJECT_0);
        unsigned char byte;REQUIRE(recv(port.socket,(char *)&byte,1,0)<=0);failed=0;goto done;
    }
    REQUIRE(zhtp_connection_create(provider,(ZhtpIO){&port,client_send,client_receive},&tls,&error)==0);
    int status=zhtp_handshake(tls,&error);REQUIRE(status==ZHTP_OK);
    REQUIRE(zhtp_peer_matches(tls,t->material->certificate,t->material->certificate_length));
    REQUIRE(!zhtp_peer_matches(tls,t->other->certificate,t->other->certificate_length));
    if(t->mode==WRONG_CERT){failed=0;goto done;}
    char request[1024],extra[192]={0},authority[40];snprintf(authority,sizeof(authority),"127.0.0.1:%u",t->port);
    if(t->mode==ORIGIN_DENIED)strcpy(extra,"Origin: null\r\n");
    else if(t->mode==RANGE_DENIED)strcpy(extra,"Range: bytes=1-2\r\n");
    else if(t->mode==BODY_DENIED)strcpy(extra,"Content-Length: 1\r\n");
    else snprintf(extra,sizeof(extra),"Origin: https://127.0.0.1:%u\r\n",t->port);
    const char *secret="a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7";
    int n;
    if(t->mode==SEAL_PARTIAL_REQUEST)n=snprintf(request,sizeof(request),"GET /private/body HTTP/1.1\r\nHost: ");
    else if(t->mode==SEAL_PARSE_REJECT)n=snprintf(request,sizeof(request),"GET /private/body HTTP/1.2\r\nHost: %s\r\n\r\n",authority);
    else n=snprintf(request,sizeof(request),"%s %s HTTP/1.1\r\nHost: %s\r\nAuthorization: Bearer %s\r\n%sConnection: close\r\n\r\n",t->mode==HEAD?"HEAD":"GET",t->mode==SEAL_NO_ROUTE?"/outside":"/private/body",t->mode==HOST_DENIED?"127.0.0.1:1":authority,secret,extra);REQUIRE(n>0&&(size_t)n<sizeof(request));
    size_t count=0;REQUIRE(zhtp_write(tls,(const unsigned char *)request,(size_t)n,&count,&error)==0&&count==(size_t)n);
    if(t->mode==CANCEL_SOURCE)REQUIRE(WaitForSingleObject(t->allow_client_read,20000)==WAIT_OBJECT_0);
    unsigned char head[9216],bytes[1997];size_t head_length=0,received=0;int headers=0,final_status=0,ended=0;
    for(;;){
        unsigned char *output=headers?bytes:head+head_length;size_t maximum=headers?sizeof(bytes):1;count=0;
        status=zhtp_read(tls,output,maximum,&count,&error);
        if(status!=ZHTP_OK){ended=status;break;}REQUIRE(count>0);
        if(!headers){head_length+=count;REQUIRE(head_length<sizeof(head));if(head_length>=4&&!memcmp(head+head_length-4,"\r\n\r\n",4)){headers=1;head[head_length]=0;REQUIRE(sscanf((char *)head,"HTTP/1.1 %d",&final_status)==1);}}
        else{for(size_t i=0;i<count;i++){
            if(t->mode==GENERATED||t->mode==SHORT_BODY||t->mode==CANCEL_SOURCE)REQUIRE(bytes[i]==pattern(received+i));else REQUIRE(memory_mode(t->mode)&&received+i<14&&bytes[i]==(unsigned char)"owned response"[received+i]);}
            received+=count;
        }
    }
    t->client_status=final_status;t->body_bytes=received;
    if(t->mode==POST_FULL||t->mode==POST_CLOSED||t->mode==LATE_TICKET||t->mode==SEAL_BEFORE_DISPATCH||t->mode==SEAL_PARTIAL_REQUEST||t->mode==SEAL_PARSE_REJECT||t->mode==SEAL_NO_ROUTE){REQUIRE(!headers&&received==0);}
    else if(t->mode==CANCEL_SOURCE){REQUIRE(headers&&final_status==200&&received<4u*1024u*1024u&&ended!=ZHTP_OK);}
    else if(t->mode==SHORT_BODY){REQUIRE(!headers||final_status==200);REQUIRE(received<4096&&ended!=ZHTP_OK);}
    else if(t->mode>=ORIGIN_DENIED&&t->mode<=HOST_DENIED){REQUIRE(headers&&final_status==403&&!received&&ended==ZHTP_EOF);}
    else{size_t expected=memory_mode(t->mode)?14:t->mode==GENERATED?4u*1024u*1024u:0;REQUIRE(headers&&final_status==200&&received==expected&&ended==ZHTP_EOF);}
    failed=0;
done:
    if(tls)REQUIRE(zhtp_connection_destroy(&tls)==0);if(provider)REQUIRE(zhtp_destroy(&provider)==0);if(port.socket!=INVALID_SOCKET)closesocket(port.socket);
    t->client_result=failed;SetEvent(t->client_done);return 0;
}
static void offer(void *context,const ZhrRequest *request,ZhrBorrow *borrow){
    (void)request;Test *t=context;++t->offers;
    if(t->mode==TICKET_BUDGET||t->mode==TICKET_OOM){
        ZhrStats before,after;REQUIRE(zhr_stats(t->owner,&before)==0);
        if(t->mode==TICKET_BUDGET)REQUIRE(zhr_borrow_input(t->owner,2u*1024u*1024u-before.bytes-1)==0);
        ZhrTicket *not_taken=(ZhrTicket *)(uintptr_t)1;zhtw_test_fail_after(0);
        REQUIRE(zhr_defer(borrow,&not_taken)==(t->mode==TICKET_BUDGET?ZHR_CAPACITY:ZHR_OOM)&&!not_taken);
        zhtw_test_fail_after(-1);if(t->mode==TICKET_BUDGET)zhr_return_input(t->owner);
        REQUIRE(zhr_stats(t->owner,&after)==0&&after.bytes==before.bytes&&after.physical_pending==before.physical_pending);
        /* The unchanged live borrow is now used for the one accepted response. */
    }
    if(t->mode==LATE_TICKET){REQUIRE(zhr_defer(borrow,&t->ticket)==0);zhr_close(t->owner);zhtw_cancel(t->prepared);return;}
    ZhrTarget target={borrow,NULL};ZhrCandidate *candidate=NULL;
    if(t->mode==SEAL_AFTER_DEFER){REQUIRE(zhr_defer(borrow,&t->ticket)==0);target=(ZhrTarget){NULL,t->ticket};REQUIRE(zhtw_seal(t->prepared)==0);}
    ZhrResponse response={0};response.status=200;response.mime=(ZhrSlice){(const uint8_t *)"application/octet-stream",24};
    if(memory_mode(t->mode)){response.body=(ZhrSlice){(const uint8_t *)"owned response",14};response.length=14;REQUIRE(zhr_prepare_memory(target,&response,&candidate)==0);}
    else{response.length=t->producer.length;REQUIRE(zhr_prepare_file(target,&response,t->producer.source,&candidate)==0);}
    REQUIRE(zhr_candidate_check(candidate,t)==0);REQUIRE(zhr_candidate_admit(candidate,1,(void **)&t->control)==0);
    if(!memory_mode(t->mode)){zhr_candidate_admit_source(candidate);ZwsChannel *source=t->producer.source;t->producer.source=NULL;zws_source_release(source);}
    if(t->mode==SEAL_AFTER_DEFER){zhr_ticket_consume(t->ticket);t->ticket=NULL;}
    REQUIRE(zhr_candidate_start(candidate)==0);
}
static void zero(void){ZhtwCounts network;zhtw_counts(&network);ZhrCounts endpoint;zhr_counts(&endpoint);ZwsCounts channel;zws_counts(&channel);
    REQUIRE(!network.servers&&!network.payloads&&!network.envelopes&&!network.connections&&!network.bytes);
    REQUIRE(!endpoint.owners&&!endpoint.gates&&!endpoint.operations&&!endpoint.tickets&&!endpoint.bytes&&!endpoint.queued_payload_reservation);
    REQUIRE(!channel.physical&&!channel.controls&&!channel.budgets&&!channel.readers&&!channel.candidates&&!channel.rings);
    REQUIRE(!zhtp_provider_count()&&!zhtp_domain_count());
}
static void scenario(unsigned mode,Material *material,Material *other,Dispatch dispatch,ZhtwFormat format,ZhrFilter filter){
    Test t;memset(&t,0,sizeof(t));t.mode=mode;t.main=GetCurrentThreadId();t.material=material;t.other=other;t.dispatch=dispatch;t.format=format;t.filter=filter;
    t.ready=CreateEventW(NULL,TRUE,FALSE,NULL);t.go=CreateEventW(NULL,TRUE,FALSE,NULL);t.post_event=CreateEventW(NULL,TRUE,FALSE,NULL);t.client_done=CreateEventW(NULL,TRUE,FALSE,NULL);REQUIRE(t.ready&&t.go&&t.post_event&&t.client_done);InitializeSRWLock(&t.post_lock);
    if(mode==CANCEL_SOURCE){t.write_wait=CreateEventW(NULL,TRUE,FALSE,NULL);t.connection_closed=CreateEventW(NULL,TRUE,FALSE,NULL);t.allow_client_read=CreateEventW(NULL,TRUE,FALSE,NULL);REQUIRE(t.write_wait&&t.connection_closed&&t.allow_client_read);zhtw_test_backpressure(t.write_wait,t.connection_closed);}
    if(mode==SEAL_HANDSHAKE||mode==SEAL_PARTIAL_REQUEST){
        t.ingress=CreateEventW(NULL,TRUE,FALSE,NULL);t.connection_closed=CreateEventW(NULL,TRUE,FALSE,NULL);REQUIRE(t.ingress&&t.connection_closed);
        zhtw_test_ingress(mode==SEAL_HANDSHAKE?t.ingress:NULL,mode==SEAL_PARTIAL_REQUEST?t.ingress:NULL);zhtw_test_backpressure(NULL,t.connection_closed);
    }
    if(mode==SEAL_PARSE_REJECT||mode==SEAL_NO_ROUTE){t.allow_post_return=CreateEventW(NULL,TRUE,FALSE,NULL);REQUIRE(t.allow_post_return);}
    HANDLE worker=CreateThread(NULL,0,driver,&t,0,NULL);REQUIRE(worker);REQUIRE(WaitForSingleObject(t.ready,30000)==WAIT_OBJECT_0);
    if(t.prepare_result)fprintf(stderr,"reactor prepare result=%d domain=%u code=0x%08lx\n",t.prepare_result,t.failure.domain,(unsigned long)(uint32_t)t.failure.code);
    REQUIRE(t.prepare_result==0&&t.prepared&&t.driver);
    ZhtwServer *wrong=t.driver;REQUIRE(zhtw_release_driver(&wrong)==ZHR_WRONG_THREAD&&wrong==t.driver);
    if(mode==ABANDONED){zhtw_cancel(t.prepared);zhtw_unref(t.prepared);t.prepared=NULL;SetEvent(t.go);REQUIRE(WaitForSingleObject(worker,30000)==WAIT_OBJECT_0);goto done;}
    REQUIRE(zhtw_adopt(t.prepared,&t,post,format)==0);ZhtwStats stats;REQUIRE(zhtw_stats(t.prepared,&stats)==0&&stats.accepting&&stats.bytes+stats.tls_live<=4u*1024u*1024u);t.port=(uint16_t)stats.port;
    ZhrOptions options={2u*1024u*1024u,8,t.port,8,{(const uint8_t *)"/private/",9}};REQUIRE(zhr_create(t.prepared,&options,&t.owner)==0);REQUIRE(zhr_bind(t.owner,&t,filter,offer)==0);
    if(mode==GENERATED||mode==ZERO||mode==HEAD||mode==SHORT_BODY||mode==CANCEL_SOURCE){
        Producer *p=&t.producer;p->main=t.main;p->length=(mode==GENERATED||mode==CANCEL_SOURCE)?4u*1024u*1024u:mode==ZERO?0:4096;p->short_body=mode==SHORT_BODY;
        p->ready=CreateEventW(NULL,TRUE,FALSE,NULL);p->retire=CreateEventW(NULL,TRUE,FALSE,NULL);REQUIRE(p->ready&&p->retire);
        t.producer_thread=CreateThread(NULL,0,produce,p,0,NULL);REQUIRE(t.producer_thread);REQUIRE(WaitForSingleObject(p->ready,15000)==WAIT_OBJECT_0&&p->prepare==0);
    }
    SetEvent(t.go);HANDLE client_thread=CreateThread(NULL,0,client,&t,0,NULL);REQUIRE(client_thread);
    if(t.ingress){
        REQUIRE(WaitForSingleObject(t.ingress,20000)==WAIT_OBJECT_0);REQUIRE(zhtw_seal(t.prepared)==0);
        /* The peer is still open and supplies no missing handshake/header data.
         * Seal itself must retire the worker-owned socket/TLS payload. */
        REQUIRE(WaitForSingleObject(worker,20000)==WAIT_OBJECT_0&&t.run_result==0);
        REQUIRE(WaitForSingleObject(client_thread,15000)==WAIT_OBJECT_0&&t.client_result==0);CloseHandle(client_thread);
        REQUIRE(!t.posts&&!t.offers);goto finished_client;
    }
    HANDLE events[]={t.client_done,t.post_event,t.write_wait};unsigned event_count=mode==CANCEL_SOURCE?3:2;
    for(;;){DWORD selected=WaitForMultipleObjects(event_count,events,FALSE,30000);REQUIRE(selected>=WAIT_OBJECT_0&&selected<WAIT_OBJECT_0+event_count);if(selected==WAIT_OBJECT_0)break;
        if(selected==WAIT_OBJECT_0+2){
            REQUIRE(t.control);zws_control_cancel(t.control);
            /* Keep the client unable to receive until the worker has actually
             * retired the socket/TLS connection. A permanent signaled cancel
             * event must not turn the outstanding WANT_WRITE into a hot loop. */
            REQUIRE(WaitForSingleObject(t.connection_closed,10000)==WAIT_OBJECT_0);
            ResetEvent(t.write_wait);event_count=2;SetEvent(t.allow_client_read);continue;
        }
        AcquireSRWLockExclusive(&t.post_lock);ZhtwEnvelope *envelope=t.posted;t.posted=NULL;ResetEvent(t.post_event);ReleaseSRWLockExclusive(&t.post_lock);REQUIRE(envelope);
        if(mode==SEAL_BEFORE_DISPATCH||mode==SEAL_PARSE_REJECT)REQUIRE(zhtw_seal(t.prepared)==0);
        t.dispatch(envelope);zhtw_envelope_release(envelope);
        if(mode==SEAL_NO_ROUTE)REQUIRE(zhtw_seal(t.prepared)==0);
        if(t.allow_post_return)SetEvent(t.allow_post_return);
    }
    REQUIRE(WaitForSingleObject(client_thread,15000)==WAIT_OBJECT_0&&t.client_result==0);CloseHandle(client_thread);
    REQUIRE(t.offers==((mode<=SHORT_BODY||mode==LATE_TICKET||mode==SEAL_AFTER_DEFER||mode==CANCEL_SOURCE||mode==TICKET_BUDGET||mode==TICKET_OOM)?1u:0u));
    if(mode==SEAL_BEFORE_DISPATCH||mode==SEAL_AFTER_DEFER||mode==SEAL_PARSE_REJECT||mode==SEAL_NO_ROUTE)REQUIRE(WaitForSingleObject(worker,10000)==WAIT_OBJECT_0&&t.run_result==0);
finished_client:
    zhr_close(t.owner);zhr_owner_release(t.owner);t.owner=NULL;zhtw_cancel(t.prepared);
    REQUIRE(WaitForSingleObject(worker,30000)==WAIT_OBJECT_0&&t.run_result==0);
    zhtw_unref(t.prepared);t.prepared=NULL;
    if(t.ticket){void *owner=(void *)1;REQUIRE(zhr_ticket_owner(t.ticket,&owner)==ZHR_CLOSED&&owner==NULL);REQUIRE(zhr_ticket_cancel(t.ticket)==0);zhr_ticket_release(t.ticket);t.ticket=NULL;}
    if(t.producer_thread){
        /* Network teardown cannot return physical producer credit early. */
        ZwsCounts counts;zws_counts(&counts);REQUIRE(counts.physical==1&&counts.rings==1&&t.control&&zws_control_alive(t.control));
        SetEvent(t.producer.retire);REQUIRE(WaitForSingleObject(t.producer_thread,15000)==WAIT_OBJECT_0);CloseHandle(t.producer_thread);
        if(mode==HEAD)REQUIRE(!t.producer.writes&&(t.producer.begin==0||t.producer.begin==ZWS_CANCELLED)&&(t.producer.finish==0||t.producer.finish==ZWS_CANCELLED));
        else if(mode==SHORT_BODY)REQUIRE(t.producer.begin==0&&t.producer.finish==ZWS_LENGTH);
        else if(mode==CANCEL_SOURCE)REQUIRE(t.producer.begin==0&&t.producer.finish==ZWS_CANCELLED);
        else REQUIRE(t.producer.begin==0&&t.producer.finish==0);
        REQUIRE(!zws_control_alive(t.control));CloseHandle(t.producer.ready);CloseHandle(t.producer.retire);
    }
    if(t.control)zws_control_release(t.control);
done:
    CloseHandle(worker);CloseHandle(t.ready);CloseHandle(t.go);CloseHandle(t.post_event);CloseHandle(t.client_done);zero();
    if(mode==CANCEL_SOURCE){zhtw_test_backpressure(NULL,NULL);CloseHandle(t.write_wait);CloseHandle(t.connection_closed);CloseHandle(t.allow_client_read);}
    if(t.ingress){zhtw_test_ingress(NULL,NULL);zhtw_test_backpressure(NULL,NULL);CloseHandle(t.ingress);CloseHandle(t.connection_closed);}
    if(t.allow_post_return)CloseHandle(t.allow_post_return);
    fprintf(stderr,"real HTTPS reactor %s PASS: offers=%u posts=%u status=%d bytes=%zu final_refs=0\n",names[mode],t.offers,t.posts,t.client_status,t.body_bytes);
}
int zhtw_test_reactor(Dispatch dispatch,ZhtwFormat format,ZhrFilter filter){
    size_t server,worker,envelope,candidate;zhtw_test_sizes(&server,&worker,&envelope,&candidate);
    fprintf(stderr,"reactor actual C sizes: server=%zu worker=%zu envelope=%zu candidate=%zu owner=%zu\n",server,worker,envelope,candidate,zhr_owner_size());
    Material first={0},other={0};const char *directory=getenv("ZIGGURAT_HTTPS_TEST_ROOT");if(!directory)directory="tests/fixtures/profile-https";
    REQUIRE(!read_material(directory,"server-cert.pem",first.certificate,&first.certificate_length));REQUIRE(!read_material(directory,"server-key.pem",first.key,&first.key_length));
    REQUIRE(!read_material(directory,"other-cert.pem",other.certificate,&other.certificate_length));REQUIRE(!read_material(directory,"other-key.pem",other.key,&other.key_length));
    for(unsigned mode=0;mode<CASES;mode++)scenario(mode,&first,&other,dispatch,format,filter);
    SecureZeroMemory(&first,sizeof(first));SecureZeroMemory(&other,sizeof(other));return 0;
}
