#define _GNU_SOURCE
/* This test host explicitly creates its server, TLS listener, main loop and
 * workers. The production consumer creates none of those resources. */
#include "../src/https_resources/linux.h"
#include <libsoup/soup.h>
#include <curl/curl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>

enum Mode { MEMORY,HEAD_MEMORY,FILE_BODY,HEAD_FILE,CANCEL_TICKET,CLOSE_TICKET,SHORT_FILE,IO_FILE,UNSTARTED_FILE,LATE_CLOSE,OOM_MEMORY,DENY_BODY,SLOW_FILE,OOM_FILE,OOM_GATE,MODE_COUNT };
static const char *names[]={"memory","head_memory","file","head_file","worker_cancel","close_late_ticket","short_file","eio_file","unstarted_file","accepted_close","oom_memory","early_deny_body","slow_file","oom_file","oom_early_gate"};
enum { BODY_LENGTH=2*1024*1024+37 };
typedef struct Case {
    enum Mode mode;GMainLoop *loop;SoupServer *server;ZhrOwner *owner;
    ZwkFile *source,*pump;ZhrTicket *ticket;
    pthread_t producer,client;int has_producer,fd;
    pthread_mutex_t mutex;pthread_cond_t condition;int admitted;
    atomic_uint failures;atomic_size_t received;
    size_t length;uint16_t port;char url[128];const char *ca;
    unsigned requests,filters,got_body_bytes,client_done,pump_done,weak_messages;
    unsigned wrote_chunks,max_write,accumulated;
    int client_result,pump_result,pump_errno;long status;
    uint64_t reads;guint watchdog;
    SoupServerMessage *held_message;
} Case;
static void require(Case *c,int condition,const char *text) {
    if(!condition){atomic_fetch_add(&c->failures,1);fprintf(stderr,"FAIL %s: %s\n",names[c->mode],text);}
}
static ZhrSlice text(const char *value) { return (ZhrSlice){(const uint8_t *)value,strlen(value)}; }
static void schedule(GSourceFunc call,void *data) {
    GSource *source=g_idle_source_new();g_source_set_callback(source,call,data,NULL);g_source_attach(source,NULL);g_source_unref(source);
}
static gboolean watchdog(gpointer data) {
    Case *c=data;c->watchdog=0;require(c,0,"test watchdog, not cancellation success");g_main_loop_quit(c->loop);return G_SOURCE_REMOVE;
}
static void maybe_done(Case *c) {
    if(c->client_done && c->pump_done)g_main_loop_quit(c->loop);
}
static gboolean producer_done(gpointer data) { Case *c=data;c->pump_done=1;maybe_done(c);return G_SOURCE_REMOVE; }
static gboolean client_done(gpointer data) { Case *c=data;c->client_done=1;maybe_done(c);return G_SOURCE_REMOVE; }
static size_t receive(char *bytes,size_t width,size_t count,void *data) {
    Case *c=data;size_t size=width*count,offset=atomic_load(&c->received);
    if(c->mode!=DENY_BODY)for(size_t i=0;i<size;i++)if((unsigned char)bytes[i]!=(unsigned char)((offset+i)%251)){require(c,0,"payload differs");break;}
    atomic_fetch_add(&c->received,size);return size;
}
static void *client(void *data) {
    Case *c=data;CURL *curl=curl_easy_init();g_assert(curl);
    curl_easy_setopt(curl,CURLOPT_URL,c->url);curl_easy_setopt(curl,CURLOPT_HTTP_VERSION,CURL_HTTP_VERSION_1_1);
    curl_easy_setopt(curl,CURLOPT_CAINFO,c->ca);curl_easy_setopt(curl,CURLOPT_NOPROXY,"*");
    curl_easy_setopt(curl,CURLOPT_NOSIGNAL,1L);curl_easy_setopt(curl,CURLOPT_TIMEOUT,8L);
    curl_easy_setopt(curl,CURLOPT_WRITEFUNCTION,receive);curl_easy_setopt(curl,CURLOPT_WRITEDATA,c);
    if(c->mode==SLOW_FILE)curl_easy_setopt(curl,CURLOPT_MAX_RECV_SPEED_LARGE,(curl_off_t)(2*1024*1024));
    if(c->mode==HEAD_MEMORY || c->mode==HEAD_FILE)curl_easy_setopt(curl,CURLOPT_NOBODY,1L);
    struct curl_slist *headers=NULL;
    headers=curl_slist_append(headers,"Authorization: Bearer host-test");
    if(c->mode==DENY_BODY) {
        headers=curl_slist_append(headers,"Expect: 100-continue");
        curl_easy_setopt(curl,CURLOPT_POSTFIELDS,"body-not-authorized");
    }
    curl_easy_setopt(curl,CURLOPT_HTTPHEADER,headers);
    c->client_result=curl_easy_perform(curl);curl_easy_getinfo(curl,CURLINFO_RESPONSE_CODE,&c->status);
    curl_slist_free_all(headers);curl_easy_cleanup(curl);schedule(client_done,c);return NULL;
}
static void *producer(void *data) {
    Case *c=data;
    if(c->mode==CANCEL_TICKET) { zhr_ticket_release(c->ticket);c->ticket=NULL;schedule(producer_done,c);return NULL; }
    if(c->mode==UNSTARTED_FILE) {
        pthread_mutex_lock(&c->mutex);while(!c->admitted)pthread_cond_wait(&c->condition,&c->mutex);pthread_mutex_unlock(&c->mutex);
        zwk_file_pump_release(c->pump);
    }
    else {
        if(c->mode==SHORT_FILE)g_assert(ftruncate(c->fd,1)==0);
        c->pump_result=zwk_file_pump(c->pump,&c->pump_errno);zwk_file_pump_release(c->pump);
    }
    c->pump=NULL;schedule(producer_done,c);return NULL;
}
static gboolean begin_client(gpointer data) {
    Case *c=data;g_assert(pthread_create(&c->client,NULL,client,c)==0);return G_SOURCE_REMOVE;
}
static void *prepare_file(void *data) {
    Case *c=data;int code=0;
    c->fd=memfd_create("https-resource-fixture",MFD_CLOEXEC);g_assert(c->fd>=0);
    unsigned char block[16384];size_t done=0;
    while(done<c->length) {
        size_t count=MIN(sizeof(block),c->length-done);
        for(size_t i=0;i<count;i++)block[i]=(unsigned char)((done+i)%251);
        g_assert(write(c->fd,block,count)==(ssize_t)count);done+=count;
    }
    uint64_t length=0;g_assert(zwk_file_prepare(c->fd,(uint64_t)getpid(),ZWK_FILE_MAX_BYTES,&c->source,&c->pump,&length,&code)==ZWK_FILE_OK);
    g_assert(length==c->length);schedule(begin_client,c);
    return producer(c);
}
static void weak_message(gpointer data,GObject *object) { (void)object;Case *c=data;++c->weak_messages; }
static void got_chunk(SoupServerMessage *message,GBytes *bytes,gpointer data) { (void)message;Case *c=data;c->got_body_bytes+=(unsigned)g_bytes_get_size(bytes); }
static void wrote_chunk(SoupServerMessage *message,gpointer data) { (void)message;Case *c=data;++c->wrote_chunks; }
static void wrote_data(SoupServerMessage *message,guint count,gpointer data) { (void)message;Case *c=data;c->max_write=MAX(c->max_write,count); }
static void finished_body(SoupServerMessage *message,gpointer data) { Case *c=data;c->accumulated=soup_server_message_get_response_body(message)->data!=NULL; }
static void request_started(SoupServer *server,SoupServerMessage *message,gpointer data) {
    (void)server;Case *c=data;g_signal_connect(message,"got-chunk",G_CALLBACK(got_chunk),data);g_object_weak_ref(G_OBJECT(message),weak_message,data);
    g_signal_connect(message,"wrote-chunk",G_CALLBACK(wrote_chunk),data);g_signal_connect(message,"wrote-body-data",G_CALLBACK(wrote_data),data);g_signal_connect(message,"finished",G_CALLBACK(finished_body),data);
    if(c->mode==CLOSE_TICKET)c->held_message=g_object_ref(message);
}
static int filter(void *data,const ZhrRequest *request) {
    Case *c=data;++c->filters;
    /* The native-order test deliberately uses a trivial host policy. Exact
     * authority/header/credential semantics have separate shared Zig tests. */
    return c->mode!=DENY_BODY && request->flags&1;
}
static void offer(void *data,const ZhrRequest *request,ZhrBorrow *borrow) {
    (void)request;Case *c=data;++c->requests;
    if(c->mode==CANCEL_TICKET || c->mode==CLOSE_TICKET) {
        require(c,zhr_defer(borrow,&c->ticket)==ZHR_OK,"defer");
        if(c->mode==CLOSE_TICKET) { zhr_close(c->owner);zhr_owner_release(c->owner);c->owner=NULL;c->pump_done=1; }
        else { c->has_producer=1;g_assert(pthread_create(&c->producer,NULL,producer,c)==0); }
        return;
    }
    ZhrResponse response={.status=200,.mime=text("application/octet-stream"),.length=c->length};
    unsigned char *memory=NULL;
    const int file=c->mode==FILE_BODY || c->mode==HEAD_FILE || c->mode==SHORT_FILE || c->mode==IO_FILE || c->mode==UNSTARTED_FILE || c->mode==LATE_CLOSE || c->mode==SLOW_FILE || c->mode==OOM_FILE;
    if(!file && c->mode!=HEAD_MEMORY) {
        memory=malloc(c->length);g_assert(memory);
        for(size_t i=0;i<c->length;i++)memory[i]=(unsigned char)(i%251);
        response.body=(ZhrSlice){memory,c->length};
    }
    ZhrCandidate *candidate=NULL;ZhrTarget target={.borrow=borrow};int result;
    if(c->mode==OOM_FILE) {
        unsigned limit=0;
        for(;limit<8;limit++) {
            zwk_file_test_allocation_limit((int)limit);
            result=zhr_prepare_file(target,&response,c->source,&candidate);
            zwk_file_test_allocation_limit(-1);
            if(result==ZHR_OK)break;
            require(c,result==ZHR_OOM,"neutral budget/candidate allocation fails without taking source");
        }
        require(c,limit>0 && limit<8,"neutral allocation failure sweep");
        if(candidate){zhr_candidate_abort(candidate);candidate=NULL;}
    }
    if(c->mode==OOM_MEMORY || c->mode==OOM_FILE) {
        unsigned limit=0;
        for(;limit<16;limit++) {
            zhr_test_allocation_limit((int)limit);
            result=c->mode==OOM_FILE?zhr_prepare_file(target,&response,c->source,&candidate):zhr_prepare_memory(target,&response,&candidate);
            zhr_test_allocation_limit(-1);
            if(result==ZHR_OK)break;
            require(c,result==ZHR_OOM,"injected allocation fails before admission");
            ZhrCounts counts;zhr_counts(&counts);require(c,!counts.operations && !counts.tickets,"failed candidate releases physical slots");
        }
        require(c,limit>0 && limit<16,"every project allocation until first success");
    } else if(file)result=zhr_prepare_file(target,&response,c->source,&candidate);
    else if(c->mode==HEAD_MEMORY)result=zhr_prepare_head(target,&response,&candidate);
    else result=zhr_prepare_memory(target,&response,&candidate);
    require(c,result==ZHR_OK && candidate,"prepare");
    if(!candidate){free(memory);return;}
    require(c,zhr_candidate_check(candidate,c)==ZHR_OK,"final candidate gate");
    require(c,!zhr_candidate_admit(candidate,0,NULL),"pure acceptance");
    pthread_mutex_lock(&c->mutex);c->admitted=1;pthread_cond_broadcast(&c->condition);pthread_mutex_unlock(&c->mutex);
    free(memory);
    if(file){ZwkFile *source=c->source;c->source=NULL;zhr_candidate_admit_source(candidate);zwk_file_response_release(source);}
    if(c->mode==LATE_CLOSE){zhr_close(c->owner);zhr_owner_release(c->owner);c->owner=NULL;}
    const int cancelled=zhr_candidate_start(candidate);
    require(c,cancelled==(c->mode==LATE_CLOSE),"acceptance receipt");
}
static int run_case(const char *certificate_path,const char *key_path,enum Mode mode) {
    Case c={.mode=mode,.length=BODY_LENGTH,.fd=-1,.ca=certificate_path};
    pthread_mutex_init(&c.mutex,NULL);pthread_cond_init(&c.condition,NULL);
    atomic_init(&c.failures,0);atomic_init(&c.received,0);
    const int file=mode==FILE_BODY || mode==HEAD_FILE || mode==SHORT_FILE || mode==IO_FILE || mode==UNSTARTED_FILE || mode==LATE_CLOSE || mode==SLOW_FILE || mode==OOM_FILE;
    c.pump_done=!file && mode!=CANCEL_TICKET;
    c.loop=g_main_loop_new(NULL,FALSE);GError *error=NULL;
    GTlsCertificate *certificate=g_tls_certificate_new_from_files(certificate_path,key_path,&error);g_assert_no_error(error);g_assert(certificate);
    c.server=soup_server_new("tls-certificate",certificate,"raw-paths",TRUE,NULL);g_object_unref(certificate);
    GInetAddress *ip=g_inet_address_new_from_string("127.0.0.1");GSocketAddress *address=g_inet_socket_address_new(ip,0);g_object_unref(ip);
    g_assert(soup_server_listen(c.server,address,SOUP_SERVER_LISTEN_HTTPS,&error));g_assert_no_error(error);g_object_unref(address);
    GSList *uris=soup_server_get_uris(c.server);g_assert(uris && !uris->next);c.port=(uint16_t)g_uri_get_port(uris->data);g_slist_free_full(uris,(GDestroyNotify)g_uri_unref);
    snprintf(c.url,sizeof(c.url),"https://127.0.0.1:%u/private/body",c.port);
    g_signal_connect(c.server,"request-started",G_CALLBACK(request_started),&c);
    ZhrOptions options={.bytes=32u*1024u*1024u,.pending=8,.port=c.port,.file_streams=8,.prefix=text("/private/")};
    zhr_test_allocation_limit(0);
    require(&c,zhr_create(c.server,&options,&c.owner)==ZHR_OOM && !c.owner,"owner allocation failure takes no server ownership");
    zhr_test_allocation_limit(-1);
    require(&c,zhr_create(c.server,&options,&c.owner)==ZHR_OK,"owner validates actual single TLS listener");
    require(&c,zhr_bind(c.owner,&c,filter,offer)==ZHR_OK,"bind");
    if(mode==OOM_GATE)zhr_test_allocation_limit(0);
    c.reads=zwk_file_pread_count();
    if(mode==IO_FILE)zwk_file_test_pread_error(EIO);
    c.watchdog=g_timeout_add_seconds(10,watchdog,&c);
    if(file){c.has_producer=1;g_assert(pthread_create(&c.producer,NULL,prepare_file,&c)==0);}
    else g_assert(pthread_create(&c.client,NULL,client,&c)==0);
    g_main_loop_run(c.loop);
    if(c.owner){zhr_close(c.owner);zhr_owner_release(c.owner);c.owner=NULL;}
    if(c.held_message) {
        ZhrCounts held;zhr_counts(&held);require(&c,held.operations==1 && held.owners==1,"logical close cannot return Soup-held physical Op");
        g_object_unref(c.held_message);c.held_message=NULL;
    }
    if(c.ticket){void *out=NULL;require(&c,zhr_ticket_owner(c.ticket,&out)==ZHR_CLOSED && !out,"late C-only ticket Closed");zhr_ticket_release(c.ticket);c.ticket=NULL;}
    pthread_join(c.client,NULL);if(c.has_producer)pthread_join(c.producer,NULL);
    if(mode==OOM_GATE)zhr_test_allocation_limit(-1);
    soup_server_disconnect(c.server);g_object_unref(c.server);c.server=NULL;
    /* Explicit test-only final drain, never a production polling facility. A
     * watchdog makes leaked physical callbacks a failure rather than success. */
    ZhrCounts counts;zhr_counts(&counts);
    while(c.watchdog && (counts.owners || counts.operations || counts.gates || counts.tickets)) {
        g_main_context_iteration(NULL,TRUE);zhr_counts(&counts);
    }
    if(c.watchdog)g_source_remove(c.watchdog);
    if(mode==IO_FILE)zwk_file_test_pread_error(0);
    require(&c,c.client_done && c.pump_done,"explicit workers complete");
    if(mode==DENY_BODY || mode==OOM_GATE)require(&c,c.status==(mode==OOM_GATE?503:403) && !c.requests && !c.got_body_bytes,"early denial precedes body and offer");
    else require(&c,c.requests==1,"one approved offer");
    const int success=mode==MEMORY || mode==HEAD_MEMORY || mode==FILE_BODY || mode==HEAD_FILE || mode==OOM_MEMORY || mode==SLOW_FILE || mode==OOM_FILE;
    if(success)require(&c,c.client_result==CURLE_OK && c.status==200,"real TLS HTTP success");
    else if(mode!=DENY_BODY && mode!=OOM_GATE)require(&c,c.client_result!=CURLE_OK,"cancel/short/EIO is transport failure, not short success");
    if(success)require(&c,atomic_load(&c.received)==((mode==HEAD_MEMORY || mode==HEAD_FILE)?0:c.length),"authoritative response length");
    require(&c,c.max_write<=16384 && !c.accumulated,"bounded network chunk and accumulate=false");
    if(success && mode!=HEAD_MEMORY && mode!=HEAD_FILE)require(&c,c.wrote_chunks>=(c.length+16383)/16384,"real wrote-chunk credit for every body segment");
    if(mode==HEAD_MEMORY || mode==HEAD_FILE || mode==UNSTARTED_FILE || mode==DENY_BODY)require(&c,c.reads==zwk_file_pread_count(),"HEAD/unstarted/denied zero pread");
    uint32_t physical,controls,budgets,candidates;zwk_file_counts(&physical,&controls,&budgets,&candidates);
    require(&c,!counts.owners && !counts.operations && !counts.gates && !counts.tickets && !counts.bytes && !counts.queued_payload_reservation,"all HTTP native references and reservation returned");
    require(&c,!physical && !controls && !budgets && !candidates,"all shared file physical references returned");
    fprintf(stdout,"endpoint=%s result=%s curl=%d status=%ld bytes=%zu requests=%u filters=%u body_received=%u pread=%llu pump=%d/%d credit=%u max_write=%u accumulated=%u http=%u/%u/%u/%u file=%u/%u/%u/%u\n",names[mode],atomic_load(&c.failures)?"FAIL":"PASS",c.client_result,c.status,atomic_load(&c.received),c.requests,c.filters,c.got_body_bytes,(unsigned long long)(zwk_file_pread_count()-c.reads),c.pump_result,c.pump_errno,c.wrote_chunks,c.max_write,c.accumulated,counts.owners,counts.operations,counts.gates,counts.tickets,physical,controls,budgets,candidates);
    if(c.fd>=0)close(c.fd);g_main_loop_unref(c.loop);pthread_cond_destroy(&c.condition);pthread_mutex_destroy(&c.mutex);return atomic_load(&c.failures)?1:0;
}
static int capacity_case(const char *,const char *);
int zhr_test_native(const char *certificate_path,const char *key_path) {
    g_assert(curl_global_init(CURL_GLOBAL_DEFAULT)==CURLE_OK);int failed=0;
    for(enum Mode mode=0;mode<MODE_COUNT;mode++)failed|=run_case(certificate_path,key_path,mode);
    failed|=capacity_case(certificate_path,key_path);curl_global_cleanup();return failed;
}

typedef struct Capacity Capacity;
typedef struct EndpointSlot { Capacity *test;unsigned index,count;ZhrOwner *owner; } EndpointSlot;
typedef struct Transfer { CURL *curl;unsigned index;char url[128]; } Transfer;
struct Capacity {
    GMainLoop *loop;SoupServer *server;EndpointSlot endpoints[5];ZhrTicket *tickets[32];
    pthread_t client;const char *certificate;unsigned port;
    atomic_uint offered,errors;unsigned rejected,released,client_done;guint watchdog;
};
static void cap_require(Capacity *test,int condition,const char *message) {
    if(!condition){atomic_fetch_add(&test->errors,1);fprintf(stderr,"FAIL capacity: %s\n",message);}
}
static void cap_release(Capacity *test) {
    if(test->released)return;test->released=1;
    for(unsigned i=0;i<5;i++)if(test->endpoints[i].owner){ZhrOwner *owner=test->endpoints[i].owner;test->endpoints[i].owner=NULL;zhr_close(owner);zhr_owner_release(owner);}
    for(unsigned i=0;i<32;i++)if(test->tickets[i]){zhr_ticket_release(test->tickets[i]);test->tickets[i]=NULL;}
}
static gboolean cap_release_post(gpointer data) { cap_release(data);return G_SOURCE_REMOVE; }
static gboolean cap_done(gpointer data) { Capacity *test=data;test->client_done=1;g_main_loop_quit(test->loop);return G_SOURCE_REMOVE; }
static gboolean cap_timeout(gpointer data) { Capacity *test=data;test->watchdog=0;cap_require(test,0,"watchdog");cap_release(test);g_main_loop_quit(test->loop);return G_SOURCE_REMOVE; }
static int cap_filter(void *data,const ZhrRequest *request) { (void)data;return request->flags&1; }
static void cap_offer(void *data,const ZhrRequest *request,ZhrBorrow *borrow) {
    (void)request;EndpointSlot *slot=data;Capacity *test=slot->test;
    const unsigned index=atomic_load_explicit(&test->offered,memory_order_acquire);
    if(index<32) {
        cap_require(test,slot->index<4 && slot->count<8,"first four consumers each admit eight");
        if(slot->index>=4 || slot->count>=8)return;
        const unsigned target=slot->index*8+slot->count++;
        cap_require(test,zhr_defer(borrow,&test->tickets[target])==ZHR_OK,"bounded deferred request");
        atomic_fetch_add_explicit(&test->offered,1,memory_order_release);
    } else {
        ZhrCounts counts;zhr_counts(&counts);cap_require(test,counts.operations==32,"physical process cap remains occupied");
        ZhrTicket *ticket=NULL;cap_require(test,zhr_defer(borrow,&ticket)==ZHR_FULL && !ticket,"per-consumer and process cap reject without take");
        ++test->rejected;
    }
}
static size_t cap_bytes(char *bytes,size_t size,size_t count,void *data) { (void)bytes;(void)data;return size*count; }
static void add_transfer(Capacity *test,CURLM *multi,Transfer *transfer,unsigned index) {
    transfer->index=index;transfer->curl=curl_easy_init();g_assert(transfer->curl);
    const unsigned owner=index<32?index/8:index==32?0:4;
    snprintf(transfer->url,sizeof(transfer->url),"https://127.0.0.1:%u/e%u/item%u",test->port,owner,index);
    curl_easy_setopt(transfer->curl,CURLOPT_URL,transfer->url);curl_easy_setopt(transfer->curl,CURLOPT_HTTP_VERSION,CURL_HTTP_VERSION_1_1);
    curl_easy_setopt(transfer->curl,CURLOPT_CAINFO,test->certificate);curl_easy_setopt(transfer->curl,CURLOPT_NOPROXY,"*");
    curl_easy_setopt(transfer->curl,CURLOPT_NOSIGNAL,1L);curl_easy_setopt(transfer->curl,CURLOPT_TIMEOUT,8L);
    curl_easy_setopt(transfer->curl,CURLOPT_WRITEFUNCTION,cap_bytes);curl_easy_setopt(transfer->curl,CURLOPT_PRIVATE,transfer);
    g_assert(curl_multi_add_handle(multi,transfer->curl)==CURLM_OK);
}
static void *cap_client(void *data) {
    Capacity *test=data;CURLM *multi=curl_multi_init();g_assert(multi);
    Transfer transfers[34]={0};for(unsigned i=0;i<32;i++)add_transfer(test,multi,&transfers[i],i);
    unsigned total=32,completed=0,full_done=0;int active=0;
    while(completed<total) {
        cap_require(test,curl_multi_perform(multi,&active)==CURLM_OK,"explicit client progress");
        if(total==32 && atomic_load_explicit(&test->offered,memory_order_acquire)==32) {
            add_transfer(test,multi,&transfers[32],32);add_transfer(test,multi,&transfers[33],33);total=34;
        }
        int remaining=0;CURLMsg *message;
        while((message=curl_multi_info_read(multi,&remaining)))if(message->msg==CURLMSG_DONE) {
            Transfer *transfer=NULL;curl_easy_getinfo(message->easy_handle,CURLINFO_PRIVATE,&transfer);long status=0;curl_easy_getinfo(message->easy_handle,CURLINFO_RESPONSE_CODE,&status);
            if(transfer->index>=32){cap_require(test,message->data.result==CURLE_OK && status==403,"Full request remains unhandled and denied");if(++full_done==2)schedule(cap_release_post,test);}
            else cap_require(test,message->data.result!=CURLE_OK,"all retained requests explicitly cancelled");
            curl_multi_remove_handle(multi,message->easy_handle);curl_easy_cleanup(message->easy_handle);transfer->curl=NULL;++completed;
        }
        if(completed<total){int ready=0;cap_require(test,curl_multi_poll(multi,NULL,0,1000,&ready)==CURLM_OK,"explicit client socket wait");}
    }
    curl_multi_cleanup(multi);schedule(cap_done,test);return NULL;
}
static int capacity_case(const char *certificate_path,const char *key_path) {
    Capacity test={.certificate=certificate_path};atomic_init(&test.offered,0);atomic_init(&test.errors,0);
    test.loop=g_main_loop_new(NULL,FALSE);GError *error=NULL;GTlsCertificate *certificate=g_tls_certificate_new_from_files(certificate_path,key_path,&error);g_assert_no_error(error);
    test.server=soup_server_new("tls-certificate",certificate,"raw-paths",TRUE,NULL);g_object_unref(certificate);
    GInetAddress *ip=g_inet_address_new_from_string("127.0.0.1");GSocketAddress *address=g_inet_socket_address_new(ip,0);g_object_unref(ip);
    g_assert(soup_server_listen(test.server,address,SOUP_SERVER_LISTEN_HTTPS,&error));g_assert_no_error(error);g_object_unref(address);
    GSList *uris=soup_server_get_uris(test.server);test.port=(unsigned)g_uri_get_port(uris->data);g_slist_free_full(uris,(GDestroyNotify)g_uri_unref);
    for(unsigned i=0;i<5;i++) {
        EndpointSlot *slot=&test.endpoints[i];slot->test=&test;slot->index=i;char prefix[8];snprintf(prefix,sizeof(prefix),"/e%u/",i);
        ZhrOptions options={.bytes=1024*1024,.pending=8,.port=test.port,.file_streams=8,.prefix=text(prefix)};
        cap_require(&test,zhr_create(test.server,&options,&slot->owner)==ZHR_OK,"owner");cap_require(&test,zhr_bind(slot->owner,slot,cap_filter,cap_offer)==ZHR_OK,"bind");
    }
    test.watchdog=g_timeout_add_seconds(12,cap_timeout,&test);g_assert(pthread_create(&test.client,NULL,cap_client,&test)==0);g_main_loop_run(test.loop);
    cap_release(&test);pthread_join(test.client,NULL);soup_server_disconnect(test.server);g_object_unref(test.server);
    ZhrCounts counts;zhr_counts(&counts);
    while(test.watchdog && counts.owners){g_main_context_iteration(NULL,TRUE);zhr_counts(&counts);}
    if(test.watchdog)g_source_remove(test.watchdog);
    cap_require(&test,test.client_done && atomic_load(&test.offered)==32 && test.rejected==2,"exact accepted/rejected responsibility");
    cap_require(&test,!counts.owners && !counts.operations && !counts.tickets && !counts.gates && !counts.bytes,"all physical and logical refs returned");
    fprintf(stdout,"endpoint=capacity32 result=%s accepted=%u rejected=%u http=%u/%u/%u/%u bytes=%zu\n",atomic_load(&test.errors)?"FAIL":"PASS",atomic_load(&test.offered),test.rejected,counts.owners,counts.operations,counts.tickets,counts.gates,counts.bytes);
    g_main_loop_unref(test.loop);return atomic_load(&test.errors)?1:0;
}
