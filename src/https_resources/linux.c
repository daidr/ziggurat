#define _GNU_SOURCE
#include "linux.h"
#include <libsoup/soup.h>
#if !SOUP_CHECK_VERSION(3,2,0)
#error "HTTPS resources require libsoup 3.2 or later"
#endif
#include <gio/gio.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

enum { CAPACITY=8,PROCESS_CAPACITY=32,CHUNK=16384,HEADER_CAPACITY=64,HEADER_BYTES=16384 };
enum TicketPhase { T_PENDING,T_ACCEPTED,T_FINISHED,T_CANCELLED,T_CLOSED };
typedef struct ZhrOp ZhrOp;
typedef struct ZhrGate { ZhrOwner *owner; uint64_t identity; GUri *uri; } ZhrGate;
struct ZhrOwner {
    atomic_uint refs;
    GThread *thread;
    GMainContext *context;
    SoupServer *server;
    void *owner;
    ZhrFilter filter;
    ZhrOffer offer;
    size_t limit;
    atomic_size_t bytes,peak_bytes,queued;
    size_t borrowed;
    uint32_t limit_pending,file_streams;
    uint16_t port;
    char prefix[257];
    uint64_t identity,generations[CAPACITY];
    ZhrOp *slots[CAPACITY];
    ZwkFileBudget *file_budget;
    unsigned pending;
    gboolean bound,sealed,closed,handlers;
};
struct ZhrTicket {
    atomic_uint refs;
    atomic_int phase;
    ZhrOwner *owner;
    uint64_t identity,generation;
    unsigned slot;
    GCancellable *cancel;
};
struct ZhrOp {
    unsigned refs,slot;
    ZhrOwner *owner;
    uint64_t generation;
    SoupServerMessage *message;
    ZhrTicket *ticket;
    GSource *cancel_source,*credit_source;
    ZhrCandidate *candidate;
    struct ZhrBorrow *borrow;
    GInputStream *input;
    ZwkFileCandidate *file_candidate;
    ZwkFileControl *file_control;
    uint8_t *memory,*buffer;
    size_t memory_size,sent;
    uint64_t length;
    gboolean table_ref,deferred,terminal,connection_active,accepted,reading,queued,head,complete,reservation;
};
struct ZhrBorrow {
    ZhrOwner *owner;
    SoupServerMessage *message;
    ZhrOp *op;
    gboolean head,handled;
};
struct ZhrCandidate {
    ZhrOp *op;
    ZhrBorrow *borrow;
    ZhrResponse response;
    ZhrHeader rows[16];
    size_t allocation,memory_size;
    uint8_t *memory,*buffer;
    GInputStream *input;
    ZwkFileCandidate *file_candidate;
    ZwkFileControl *file_control;
    gboolean direct,admitted,head,reservation;
};

static atomic_uint owners,gates,operations,tickets;
static atomic_size_t requested_bytes,queued_payloads;
static uint64_t next_identity=1;
static GQuark gate_key,op_key;
#ifdef ZHR_TESTING
static int allocations=-1;
void zhr_test_allocation_limit(int value) { allocations=value; }
#endif
static void *try_zero(size_t size) {
#ifdef ZHR_TESTING
    if (!allocations) return NULL;
    if (allocations>0) --allocations;
#endif
    return calloc(1,size);
}
static void owner_ref(ZhrOwner *s) { atomic_fetch_add_explicit(&s->refs,1,memory_order_relaxed); }
static void owner_unref(ZhrOwner *s) {
    if (atomic_fetch_sub_explicit(&s->refs,1,memory_order_acq_rel)!=1) return;
    g_assert(s->closed && !s->server && !s->context && !s->pending && !s->file_budget && !s->borrowed);
    g_assert(atomic_load_explicit(&s->bytes,memory_order_relaxed)==sizeof(*s));
    g_assert(!atomic_load_explicit(&s->queued,memory_order_relaxed));
    atomic_fetch_sub_explicit(&requested_bytes,sizeof(*s),memory_order_relaxed);
    atomic_fetch_sub_explicit(&owners,1,memory_order_relaxed);
    free(s);
}
static int on_owner(ZhrOwner *s) { return s->thread==g_thread_self()?ZHR_OK:ZHR_WRONG_THREAD; }
static gboolean open_owner(ZhrOwner *s) { return !s->sealed && !s->closed && s->bound && s->owner; }
static void peak(ZhrOwner *s) {
    const size_t value=atomic_load_explicit(&s->bytes,memory_order_relaxed)+atomic_load_explicit(&s->queued,memory_order_relaxed)+s->borrowed;
    size_t prior=atomic_load_explicit(&s->peak_bytes,memory_order_relaxed);
    while (prior<value && !atomic_compare_exchange_weak_explicit(&s->peak_bytes,&prior,value,memory_order_relaxed,memory_order_relaxed)) {}
}
static gboolean reserve_bytes(ZhrOwner *s,size_t size) {
    size_t prior=atomic_load_explicit(&s->bytes,memory_order_acquire);
    for (;;) {
        const size_t queued=atomic_load_explicit(&s->queued,memory_order_acquire);
        if (prior>s->limit || queued>s->limit-prior || s->borrowed>s->limit-prior-queued || size>s->limit-prior-queued-s->borrowed) return FALSE;
        if (atomic_compare_exchange_weak_explicit(&s->bytes,&prior,prior+size,memory_order_acq_rel,memory_order_acquire)) break;
    }
    atomic_fetch_add_explicit(&requested_bytes,size,memory_order_relaxed); peak(s); return TRUE;
}
static void uncharge(ZhrOwner *s,size_t size) {
    g_assert(atomic_fetch_sub_explicit(&s->bytes,size,memory_order_acq_rel)>=size);
    atomic_fetch_sub_explicit(&requested_bytes,size,memory_order_relaxed);
}
static void *allocate(ZhrOwner *s,size_t size) {
    if (!reserve_bytes(s,size)) return NULL;
    void *value=try_zero(size);
    if (!value) uncharge(s,size);
    return value;
}
static void release_bytes(ZhrOwner *s,void *value,size_t size) { if(value){uncharge(s,size);free(value);} }
static gboolean reserve_queue(ZhrOwner *s) {
    const size_t bytes=atomic_load_explicit(&s->bytes,memory_order_acquire);
    const size_t queued=atomic_load_explicit(&s->queued,memory_order_relaxed);
    if (bytes>s->limit || queued>s->limit-bytes || s->borrowed>s->limit-bytes-queued || CHUNK>s->limit-bytes-queued-s->borrowed) return FALSE;
    atomic_fetch_add_explicit(&s->queued,CHUNK,memory_order_relaxed);
    atomic_fetch_add_explicit(&queued_payloads,CHUNK,memory_order_relaxed);peak(s);return TRUE;
}
static void release_queue(ZhrOwner *s) {
    g_assert(atomic_fetch_sub_explicit(&s->queued,CHUNK,memory_order_relaxed)>=CHUNK);
    atomic_fetch_sub_explicit(&queued_payloads,CHUNK,memory_order_relaxed);
}
void zhr_counts(ZhrCounts *out) {
    *out=(ZhrCounts){atomic_load(&owners),atomic_load(&gates),atomic_load(&operations),atomic_load(&tickets),atomic_load(&requested_bytes),atomic_load(&queued_payloads)};
}
size_t zhr_owner_size(void) { return sizeof(ZhrOwner); }
int zhr_stats(ZhrOwner *s,ZhrStats *out) {
    if (!s || !out) return ZHR_INVALID;
    if (on_owner(s)) return ZHR_WRONG_THREAD;
    *out=(ZhrStats){atomic_load(&s->bytes),atomic_load(&s->peak_bytes),atomic_load(&s->queued),s->pending,open_owner(s)};
    return ZHR_OK;
}
int zhr_check(ZhrOwner *s) { return !s?ZHR_CLOSED:on_owner(s)?ZHR_WRONG_THREAD:open_owner(s)?ZHR_OK:ZHR_CLOSED; }
int zhr_borrow_input(ZhrOwner *s,size_t bytes) {
    int result=zhr_check(s);if(result)return result;
    const size_t requested=atomic_load(&s->bytes),queued=atomic_load(&s->queued);
    if(s->borrowed || requested>s->limit || queued>s->limit-requested || bytes>s->limit-requested-queued)return ZHR_CAPACITY;
    s->borrowed=bytes;peak(s);return ZHR_OK;
}
void zhr_return_input(ZhrOwner *s) { g_assert(s && !on_owner(s));s->borrowed=0; }
static size_t bounded(const char *text,size_t maximum) {
    size_t length=0;if(!text)return 0;
    while(length<maximum && text[length])++length;
    return length;
}
static gboolean slice(const char *text,size_t maximum,ZhrSlice *out) {
    const size_t length=bounded(text,maximum+1);
    if(length>maximum)return FALSE;
    *out=(ZhrSlice){(const uint8_t *)text,length};return TRUE;
}
static gboolean address(GSocketAddress *value,uint8_t ip[4],uint16_t *port) {
    if(!G_IS_INET_SOCKET_ADDRESS(value))return FALSE;
    GInetAddress *host=g_inet_socket_address_get_address(G_INET_SOCKET_ADDRESS(value));
    if(g_inet_address_get_family(host)!=G_SOCKET_FAMILY_IPV4)return FALSE;
    memcpy(ip,g_inet_address_to_bytes(host),4);
    if(port)*port=g_inet_socket_address_get_port(G_INET_SOCKET_ADDRESS(value));
    return TRUE;
}
static gboolean request_view(SoupServerMessage *message,ZhrRequest *out,ZhrHeader rows[HEADER_CAPACITY]) {
    memset(out,0,sizeof(*out));
    GUri *uri=soup_server_message_get_uri(message);
    if(!uri || !address(soup_server_message_get_local_address(message),out->local_ip,&out->local_port) ||
        !address(soup_server_message_get_remote_address(message),out->peer_ip,NULL))return FALSE;
    if(!slice(g_uri_get_scheme(uri),5,&out->scheme) || !slice(g_uri_get_host(uri),256,&out->host) ||
        !slice(g_uri_get_path(uri),4096,&out->path) || !slice(g_uri_get_query(uri),4096,&out->query) ||
        !slice(soup_server_message_get_method(message),8,&out->method))return FALSE;
    int port=g_uri_get_port(uri);if(port==-1 && g_uri_get_scheme(uri) && !strcmp(g_uri_get_scheme(uri),"https"))port=443;
    if(port<=0 || port>65535)return FALSE;
    size_t authority=out->host.length;
    if(port!=443){authority++;for(unsigned n=(unsigned)port;n;n/=10)authority++;}
    if(8+authority+out->path.length+(g_uri_get_query(uri)?1+out->query.length:0)>4096)return FALSE;
    out->port=(uint16_t)port;
    out->flags=(soup_server_message_get_http_version(message)==SOUP_HTTP_1_1?1u:0u)|
        (g_uri_get_userinfo(uri)?2u:0u)|(g_uri_get_fragment(uri)?4u:0u)|(g_uri_get_query(uri)?8u:0u);
    SoupMessageHeadersIter iterator;const char *name,*value;size_t count=0,bytes=0;
    soup_message_headers_iter_init(&iterator,soup_server_message_get_request_headers(message));
    while(soup_message_headers_iter_next(&iterator,&name,&value)) {
        if(count==HEADER_CAPACITY || !slice(name,64,&rows[count].name) || !slice(value,2048,&rows[count].value))return FALSE;
        bytes+=rows[count].name.length+rows[count].value.length;
        if(bytes>HEADER_BYTES)return FALSE;
        ++count;
    }
    out->headers=rows;out->header_count=count;return TRUE;
}
static gboolean listener_matches(SoupServer *server,uint16_t port) {
    if(!soup_server_is_https(server))return FALSE;
    GSList *uris=soup_server_get_uris(server),*listeners=soup_server_get_listeners(server);
    gboolean valid=uris && !uris->next && listeners && !listeners->next;
    if(valid) {
        GUri *uri=uris->data;const char *scheme=g_uri_get_scheme(uri),*host=g_uri_get_host(uri);
        const int actual=g_uri_get_port(uri)<0?443:g_uri_get_port(uri);
        valid=scheme && !strcmp(scheme,"https") && host && !strcmp(host,"127.0.0.1") && actual==port;
        GError *error=NULL;GSocketAddress *local=g_socket_get_local_address(G_SOCKET(listeners->data),&error);
        uint8_t ip[4];uint16_t bound_port=0;
        valid=valid && !error && address(local,ip,&bound_port) && !memcmp(ip,"\177\0\0\1",4) && bound_port==port;
        g_clear_object(&local);g_clear_error(&error);
    }
    g_slist_free_full(uris,(GDestroyNotify)g_uri_unref);g_slist_free(listeners);return valid;
}
static void op_ref(ZhrOp *);
static void op_unref(gpointer);
static void op_retire(ZhrOp *,int);
static void handler_unref(gpointer data) { owner_unref(data); }
static void gate_free(gpointer data) {
    ZhrGate *gate=data;ZhrOwner *s=gate->owner;
    g_uri_unref(gate->uri);
    atomic_fetch_sub_explicit(&gates,1,memory_order_relaxed);release_bytes(s,gate,sizeof(*gate));owner_unref(s);
}
static void deny(SoupServerMessage *message,unsigned status) {
    soup_server_message_set_status(message,status,NULL);
    SoupMessageHeaders *headers=soup_server_message_get_response_headers(message);
    soup_message_headers_set_content_length(headers,0);soup_message_headers_append(headers,"Connection","close");
}
static void early(SoupServer *server,SoupServerMessage *message,const char *path,GHashTable *query,gpointer data) {
    (void)server;(void)path;(void)query;ZhrOwner *s=data;owner_ref(s);
    g_assert(!on_owner(s));
    ZhrRequest request;ZhrHeader rows[HEADER_CAPACITY];
    if(!open_owner(s) || !request_view(message,&request,rows) || !s->filter(s->owner,&request) || !open_owner(s)) { deny(message,403);owner_unref(s);return; }
    ZhrGate *gate=allocate(s,sizeof(*gate));
    if(!gate){deny(message,503);owner_unref(s);return;}
    gate->owner=s;gate->identity=s->identity;gate->uri=g_uri_ref(soup_server_message_get_uri(message));owner_ref(s);atomic_fetch_add(&gates,1);
    g_assert(!g_object_get_qdata(G_OBJECT(message),gate_key));
    g_object_set_qdata_full(G_OBJECT(message),gate_key,gate,gate_free);
    owner_unref(s);
}
static void serve(SoupServer *server,SoupServerMessage *message,const char *path,GHashTable *query,gpointer data) {
    (void)server;(void)path;(void)query;ZhrOwner *s=data;owner_ref(s);g_assert(!on_owner(s));
    ZhrGate *gate=g_object_steal_qdata(G_OBJECT(message),gate_key);
    ZhrRequest request;ZhrHeader rows[HEADER_CAPACITY];
    if(!gate || gate->owner!=s || gate->identity!=s->identity || gate->uri!=soup_server_message_get_uri(message) || !open_owner(s) || !request_view(message,&request,rows)) {
        if(gate)gate_free(gate);deny(message,403);owner_unref(s);return;
    }
    /* Keep the approved native gate through the entire foreign offer. */
    g_object_ref(message);soup_server_message_pause(message);
    ZhrBorrow borrow={s,message,NULL,request.method.length==4 && !memcmp(request.method.ptr,"HEAD",4),FALSE};
    s->offer(s->owner,&request,&borrow);
    if(borrow.op)borrow.op->borrow=NULL;
    if(!borrow.handled) { deny(message,403);soup_server_message_unpause(message); }
    g_object_unref(message);gate_free(gate);owner_unref(s);
}
/* Constructor-only lease. No handler, context, listener or caller allocator;
 * it protects a composite owner's preparation across foreign allocation. */
int zhr_server_pin(void *server,void **out) {
    if(!out)return ZHR_INVALID;*out=NULL;
    if(!SOUP_IS_SERVER(server))return ZHR_INVALID;
    *out=g_object_ref(server);return ZHR_OK;
}
void zhr_server_unpin(void *server) { if(server)g_object_unref(server); }
static gboolean server_configuration_matches(SoupServer *server,uint16_t port) {
    gboolean raw_paths=FALSE;g_object_get(server,"raw-paths",&raw_paths,NULL);
    return raw_paths && listener_matches(server,port);
}
int zhr_create(void *server_value,const ZhrOptions *options,ZhrOwner **out) {
    if(!out)return ZHR_INVALID;*out=NULL;
    if(!SOUP_IS_SERVER(server_value) || !options || options->pending==0 || options->pending>CAPACITY || options->port==0 || options->port>65535 ||
        !options->prefix.ptr || !options->prefix.length || options->prefix.length>256 || options->bytes<sizeof(ZhrOwner) ||
        options->file_streams==0 || options->file_streams>ZWK_FILE_CONSUMER_LIMIT)return ZHR_INVALID;
    SoupServer *server=g_object_ref(server_value);GMainContext *context=g_main_context_ref_thread_default();
    if(context!=g_main_context_default() || !server_configuration_matches(server,(uint16_t)options->port)) { g_main_context_unref(context);g_object_unref(server);return ZHR_INVALID; }
    if(next_identity==UINT64_MAX){g_main_context_unref(context);g_object_unref(server);return ZHR_FULL;}
    ZhrOwner *s=try_zero(sizeof(*s));
    if(!s){g_main_context_unref(context);g_object_unref(server);return ZHR_OOM;}
    atomic_init(&s->refs,1);atomic_init(&s->bytes,sizeof(*s));atomic_init(&s->peak_bytes,sizeof(*s));atomic_init(&s->queued,0);
    s->thread=g_thread_self();s->server=server;s->context=context;s->limit=options->bytes;s->port=(uint16_t)options->port;
    s->limit_pending=options->pending;s->file_streams=options->file_streams;s->identity=next_identity++;
    memcpy(s->prefix,options->prefix.ptr,options->prefix.length);s->prefix[options->prefix.length]=0;
    for(unsigned i=0;i<CAPACITY;i++)s->generations[i]=1;
    atomic_fetch_add(&owners,1);atomic_fetch_add(&requested_bytes,sizeof(*s));
    if(!gate_key)gate_key=g_quark_from_static_string("ziggurat-https-approved-request");
    if(!op_key)op_key=g_quark_from_static_string("ziggurat-https-physical-response");
    *out=s;return ZHR_OK;
}
int zhr_bind(ZhrOwner *s,void *owner,ZhrFilter filter,ZhrOffer offer) {
    if(!s || !owner || !filter || !offer)return ZHR_INVALID;
    if(on_owner(s))return ZHR_WRONG_THREAD;
    if(s->sealed || s->closed)return ZHR_CLOSED;
    if(s->bound)return ZHR_INVALID;
    /* Caller allocation and replaced native handlers can revoke the listener
     * after create's first check. Revalidate only at constructor publication. */
    if(!server_configuration_matches(s->server,s->port))return ZHR_INVALID;
    owner_ref(s);SoupServer *server=g_object_ref(s->server);
    s->owner=owner;s->filter=filter;s->offer=offer;s->bound=TRUE;s->handlers=TRUE;
    owner_ref(s);soup_server_add_early_handler(server,s->prefix,early,s,handler_unref);
    if(open_owner(s)){owner_ref(s);soup_server_add_handler(server,s->prefix,serve,s,handler_unref);}
    if(!open_owner(s))soup_server_remove_handler(server,s->prefix);
    g_object_unref(server);
    const int result=!open_owner(s)?ZHR_CLOSED:server_configuration_matches(s->server,s->port)?ZHR_OK:ZHR_INVALID;
    owner_unref(s);return result;
}
void zhr_seal(ZhrOwner *s) {
    if(!s)return;g_assert(!on_owner(s));owner_ref(s);
    s->sealed=TRUE;s->owner=NULL;s->filter=NULL;s->offer=NULL;
    if(s->handlers){s->handlers=FALSE;SoupServer *server=g_object_ref(s->server);soup_server_remove_handler(server,s->prefix);g_object_unref(server);}
    /* Slots remain reserved until the last native Op reference is released. */
    for(unsigned i=0;i<CAPACITY;i++){ZhrOp *op=s->slots[i];if(op){op_ref(op);op_retire(op,T_CLOSED);op_unref(op);}}
    owner_unref(s);
}
void zhr_close(ZhrOwner *s) {
    if(!s)return;g_assert(!on_owner(s));if(s->closed)return;owner_ref(s);
    s->closed=TRUE;zhr_seal(s);
    SoupServer *server=s->server;s->server=NULL;GMainContext *context=s->context;s->context=NULL;
    ZwkFileBudget *budget=s->file_budget;s->file_budget=NULL;
    if(budget)zwk_file_budget_release(budget);
    if(server)g_object_unref(server);if(context)g_main_context_unref(context);
    owner_unref(s);
}
void zhr_owner_release(ZhrOwner *s) { if(s)owner_unref(s); }

/* A Ticket has no native message pointer. Its last reference may be returned
 * by a worker; only atomics, thread-safe GCancellable and plain C storage are
 * touched there. The attached cancellation source performs native retirement. */
static void ticket_ref(ZhrTicket *ticket) { atomic_fetch_add_explicit(&ticket->refs,1,memory_order_relaxed); }
static void ticket_unref(ZhrTicket *ticket) {
    if(atomic_fetch_sub_explicit(&ticket->refs,1,memory_order_acq_rel)!=1)return;
    ZhrOwner *s=ticket->owner;
    g_object_unref(ticket->cancel);
    atomic_fetch_sub_explicit(&tickets,1,memory_order_relaxed);
    release_bytes(s,ticket,sizeof(*ticket));owner_unref(s);
}
int zhr_ticket_cancel(ZhrTicket *ticket) {
    if(!ticket)return ZHR_STALE;
    int phase=atomic_load_explicit(&ticket->phase,memory_order_acquire);
    while(phase==T_PENDING || phase==T_ACCEPTED) {
        if(atomic_compare_exchange_weak_explicit(&ticket->phase,&phase,T_CANCELLED,memory_order_acq_rel,memory_order_acquire)) {
            g_cancellable_cancel(ticket->cancel);return ZHR_OK;
        }
    }
    return phase==T_CLOSED?ZHR_CLOSED:ZHR_STALE;
}
void zhr_ticket_release(ZhrTicket *ticket) {
    if(!ticket)return;
    (void)zhr_ticket_cancel(ticket);ticket_unref(ticket);
}
void zhr_ticket_consume(ZhrTicket *ticket) { if(ticket)ticket_unref(ticket); }
int zhr_ticket_owner(ZhrTicket *ticket,void **out) {
    if(!out)return ZHR_INVALID;*out=NULL;
    if(!ticket)return ZHR_STALE;
    ZhrOwner *s=ticket->owner;
    if(on_owner(s))return ZHR_WRONG_THREAD;
    if(!open_owner(s))return ZHR_CLOSED;
    if(ticket->identity!=s->identity || ticket->slot>=CAPACITY || s->generations[ticket->slot]!=ticket->generation ||
        !s->slots[ticket->slot] || atomic_load_explicit(&ticket->phase,memory_order_acquire)!=T_PENDING)return ZHR_STALE;
    *out=s->owner;return ZHR_OK;
}
static void op_ref(ZhrOp *op) { g_assert(!on_owner(op->owner));++op->refs; }
static void op_unref(gpointer data) {
    ZhrOp *op=data;ZhrOwner *s=op->owner;g_assert(!on_owner(s));
    g_assert(op->refs);if(--op->refs)return;
    g_assert(op->terminal && !op->message && !op->cancel_source && !op->credit_source && !op->candidate && !op->reading);
    g_assert(s->slots[op->slot]==op && s->generations[op->slot]==op->generation);
    s->slots[op->slot]=NULL;--s->pending;
    if(s->generations[op->slot]!=UINT64_MAX)++s->generations[op->slot];
    if(op->file_candidate)zwk_file_candidate_abort(op->file_candidate);
    if(op->file_control)zwk_file_control_release(op->file_control);
    if(op->input)g_object_unref(op->input);
    release_bytes(s,op->memory,op->memory_size);release_bytes(s,op->buffer,op->buffer?CHUNK:0);
    if(op->reservation)release_queue(s);
    ticket_unref(op->ticket);
    atomic_fetch_sub_explicit(&operations,1,memory_order_acq_rel);
    release_bytes(s,op,sizeof(*op));owner_unref(s);
}
static void destroy_source(GSource **field) {
    GSource *source=*field;*field=NULL;
    if(source){g_source_destroy(source);g_source_unref(source);}
}
static void admit_file(ZhrOp *op,int cancelled) {
    ZwkFileCandidate *candidate=op->file_candidate;op->file_candidate=NULL;
    if(candidate)zwk_file_candidate_admit(candidate,cancelled,0,NULL);
}
static void op_retire(ZhrOp *op,int phase) {
    if(op->terminal)return;
    op_ref(op);op->terminal=TRUE;
    atomic_store_explicit(&op->ticket->phase,phase,memory_order_release);
    if(op->borrow){op->borrow->op=NULL;op->borrow->handled=TRUE;op->borrow=NULL;}
    g_cancellable_cancel(op->ticket->cancel);
    if(op->file_control)zwk_file_control_cancel(op->file_control);
    /* A published response consumed the prepared source. Even reentrant close
     * before start must admit-cancel it, not abort and leave its pump waiting. */
    if(op->accepted)admit_file(op,TRUE);
    destroy_source(&op->cancel_source);destroy_source(&op->credit_source);
    SoupServerMessage *message=op->message;op->message=NULL;
    const gboolean active=op->connection_active;op->connection_active=FALSE;
    if(message) {
        g_signal_handlers_disconnect_by_data(message,op);
        if(active && phase!=T_FINISHED) {
            GSocket *socket=soup_server_message_get_socket(message);if(socket)g_object_ref(socket);
            GIOStream *connection=soup_server_message_steal_connection(message);
            if(socket){GError *error=NULL;g_socket_close(socket,&error);g_clear_error(&error);g_object_unref(socket);}
            if(connection)g_object_unref(connection);
        }
        /* The private qdata pin remains until Soup's last native message ref,
         * even after our strong entry has gone. No Zig pointer is in qdata. */
        g_object_unref(message);
    }
    if(op->table_ref){op->table_ref=FALSE;op_unref(op);}
    op_unref(op);
}
static gboolean cancelled(GCancellable *cancel,gpointer data) {
    (void)cancel;ZhrOp *op=data;op_ref(op);op_retire(op,T_CANCELLED);op_unref(op);return G_SOURCE_REMOVE;
}
static void advance(ZhrOp *);
static gboolean credit(gpointer data) {
    ZhrOp *op=data;op_ref(op);
    if(op->credit_source)g_source_set_ready_time(op->credit_source,-1);
    if(!op->terminal)advance(op);
    op_unref(op);return G_SOURCE_CONTINUE;
}
static gboolean credit_dispatch(GSource *source,GSourceFunc callback,gpointer data) {
    (void)source;return callback(data);
}
static GSourceFuncs credit_functions={NULL,NULL,credit_dispatch,NULL,NULL,NULL};
static void wrote_chunk(SoupServerMessage *message,gpointer data) {
    (void)message;ZhrOp *op=data;op_ref(op);
    if(!op->terminal && op->queued) {
        op->queued=FALSE;
        soup_server_message_pause(op->message);
        if(!op->terminal && op->credit_source)g_source_set_ready_time(op->credit_source,0);
    }
    op_unref(op);
}
static void message_finished(SoupServerMessage *message,gpointer data) {
    (void)message;ZhrOp *op=data;op_ref(op);op->connection_active=FALSE;op_retire(op,T_FINISHED);op_unref(op);
}
static void message_disconnected(SoupServerMessage *message,gpointer data) {
    (void)message;ZhrOp *op=data;op_ref(op);op->connection_active=FALSE;op_retire(op,T_CANCELLED);op_unref(op);
}
static void *allocated(ZhrOwner *s,size_t size,int *result) {
    *result=ZHR_CAPACITY;if(!reserve_bytes(s,size))return NULL;
    void *value=try_zero(size);if(!value){uncharge(s,size);*result=ZHR_OOM;return NULL;}*result=ZHR_OK;return value;
}
static int op_create(ZhrBorrow *borrow,ZhrOp **out) {
    *out=NULL;ZhrOwner *s=borrow->owner;
    int result=zhr_check(s);if(result)return result;
    if(borrow->handled || borrow->op)return ZHR_STALE;
    unsigned slot=0;
    while(slot<s->limit_pending && (s->slots[slot] || s->generations[slot]==UINT64_MAX))++slot;
    if(slot==s->limit_pending)return ZHR_FULL;
    unsigned count=atomic_load_explicit(&operations,memory_order_acquire);
    do { if(count==PROCESS_CAPACITY)return ZHR_FULL; }
    while(!atomic_compare_exchange_weak_explicit(&operations,&count,count+1,memory_order_acq_rel,memory_order_acquire));
    ZhrOp *op=allocated(s,sizeof(*op),&result);
    if(result){atomic_fetch_sub(&operations,1);return result;}
    ZhrTicket *ticket=allocated(s,sizeof(*ticket),&result);
    if(result){release_bytes(s,op,sizeof(*op));atomic_fetch_sub(&operations,1);return result;}
    atomic_init(&ticket->refs,1);atomic_init(&ticket->phase,T_PENDING);
    ticket->owner=s;ticket->identity=s->identity;ticket->generation=s->generations[slot];ticket->slot=slot;ticket->cancel=g_cancellable_new();
    owner_ref(s);atomic_fetch_add(&tickets,1);
    op->owner=s;owner_ref(s);op->refs=1;op->slot=slot;op->generation=s->generations[slot];op->ticket=ticket;op->table_ref=TRUE;
    op->message=g_object_ref(borrow->message);op->connection_active=TRUE;op->head=borrow->head;op->borrow=borrow;
    s->slots[slot]=op;++s->pending;borrow->op=op;
    g_assert(!g_object_get_qdata(G_OBJECT(op->message),op_key));
    op_ref(op);g_object_set_qdata_full(G_OBJECT(op->message),op_key,op,op_unref);
    g_signal_connect(op->message,"wrote-chunk",G_CALLBACK(wrote_chunk),op);
    g_signal_connect(op->message,"finished",G_CALLBACK(message_finished),op);
    g_signal_connect(op->message,"disconnected",G_CALLBACK(message_disconnected),op);
    op->cancel_source=g_cancellable_source_new(ticket->cancel);op_ref(op);
    g_source_set_callback(op->cancel_source,G_SOURCE_FUNC(cancelled),op,op_unref);g_source_attach(op->cancel_source,s->context);
    op->credit_source=g_source_new(&credit_functions,sizeof(GSource));op_ref(op);
    g_source_set_callback(op->credit_source,credit,op,op_unref);g_source_set_ready_time(op->credit_source,-1);g_source_attach(op->credit_source,s->context);
    *out=op;return ZHR_OK;
}
int zhr_defer(ZhrBorrow *borrow,ZhrTicket **out) {
    if(!out)return ZHR_INVALID;*out=NULL;if(!borrow)return ZHR_INVALID;
    ZhrOp *op=NULL;const int result=op_create(borrow,&op);if(result)return result;
    op->deferred=TRUE;borrow->handled=TRUE;ticket_ref(op->ticket);*out=op->ticket;return ZHR_OK;
}
static int target_op(ZhrTarget target,ZhrOp **out,int *direct) {
    *out=NULL;*direct=0;
    if((target.borrow!=NULL)==(target.ticket!=NULL))return ZHR_INVALID;
    if(target.borrow) { *direct=1;return op_create(target.borrow,out); }
    void *ctx=NULL;int result=zhr_ticket_owner(target.ticket,&ctx);if(result)return result;
    (void)ctx;ZhrOwner *s=target.ticket->owner;ZhrOp *op=s->slots[target.ticket->slot];
    if(op->candidate || op->accepted || op->terminal)return ZHR_STALE;
    *out=op;return ZHR_OK;
}
/* Abort of a provisional direct response must leave the live callback borrow
 * usable. It removes only this adapter's pins and does not close the request. */
static void rollback_direct(ZhrOp *op) {
    op_ref(op);op->connection_active=FALSE;
    SoupServerMessage *message=op->message;
    if(message) {
        g_object_ref(message);
        gpointer pin=g_object_steal_qdata(G_OBJECT(message),op_key);
        if(pin)op_unref(pin);
    }
    if(op->borrow){op->borrow->op=NULL;op->borrow=NULL;}
    op_retire(op,T_CANCELLED);if(message)g_object_unref(message);op_unref(op);
}
static void candidate_free(ZhrCandidate *candidate) {
    ZhrOp *op=candidate->op;ZhrOwner *s=op->owner;
    if(op->candidate==candidate)op->candidate=NULL;
    if(candidate->file_candidate)zwk_file_candidate_abort(candidate->file_candidate);
    if(candidate->file_control)zwk_file_control_release(candidate->file_control);
    if(candidate->input)g_object_unref(candidate->input);
    release_bytes(s,candidate->memory,candidate->memory_size);release_bytes(s,candidate->buffer,candidate->buffer?CHUNK:0);
    if(candidate->reservation)release_queue(s);
    release_bytes(s,candidate,candidate->allocation);op_unref(op);
}
void zhr_candidate_abort(ZhrCandidate *candidate) {
    if(!candidate)return;g_assert(!candidate->admitted);ZhrOp *op=candidate->op;op_ref(op);
    const gboolean direct=candidate->direct;candidate_free(candidate);
    if(direct && !op->terminal)rollback_direct(op);
    op_unref(op);
}
static int file_error(int result) {
    switch(result) {
        case ZWK_FILE_OK:return ZHR_OK;case ZWK_FILE_FULL:return ZHR_FULL;
        case ZWK_FILE_OOM:return ZHR_OOM;case ZWK_FILE_CLOSED:case ZWK_FILE_CANCELLED:return ZHR_CLOSED;
        default:return ZHR_INVALID;
    }
}
static int prepare(ZhrTarget target,const ZhrResponse *response,ZwkFile *file,int mode,ZhrCandidate **out) {
    if(!out)return ZHR_INVALID;*out=NULL;
    if(!response || response->status<200 || response->status>599 || !response->mime.ptr || !response->mime.length || response->mime.length>127 ||
        response->header_count>16 || (response->header_count && !response->headers) || response->body.length>16u*1024u*1024u ||
        (response->body.length && !response->body.ptr) || (mode==2 && !file))return ZHR_INVALID;
    size_t total=sizeof(ZhrCandidate)+response->mime.length+1,header_bytes=0;
    for(size_t i=0;i<response->header_count;i++) {
        const ZhrHeader *row=&response->headers[i];
        if(!row->name.ptr || !row->name.length || row->name.length>64 || !row->value.ptr || row->value.length>2048)return ZHR_INVALID;
        header_bytes+=row->name.length+row->value.length+4;
        if(header_bytes>8192)return ZHR_INVALID;
        total+=row->name.length+row->value.length+2;
    }
    ZhrOp *op=NULL;int direct=0,result=target_op(target,&op,&direct);if(result)return result;
    op_ref(op);ZhrOwner *s=op->owner;ZhrCandidate *candidate=NULL;
    candidate=allocated(s,total,&result);
    if(result){if(direct)rollback_direct(op);op_unref(op);return result;}
    candidate->op=op;op_ref(op);op->candidate=candidate;candidate->borrow=target.borrow;
    candidate->allocation=total;candidate->direct=direct;candidate->head=op->head;candidate->response=*response;
    char *cursor=(char *)(candidate+1);
    memcpy(cursor,response->mime.ptr,response->mime.length);cursor[response->mime.length]=0;
    candidate->response.mime=(ZhrSlice){(uint8_t *)cursor,response->mime.length};cursor+=response->mime.length+1;
    for(size_t i=0;i<response->header_count;i++) {
        const ZhrHeader row=response->headers[i];
        memcpy(cursor,row.name.ptr,row.name.length);cursor[row.name.length]=0;
        candidate->rows[i].name=(ZhrSlice){(uint8_t *)cursor,row.name.length};cursor+=row.name.length+1;
        memcpy(cursor,row.value.ptr,row.value.length);cursor[row.value.length]=0;
        candidate->rows[i].value=(ZhrSlice){(uint8_t *)cursor,row.value.length};cursor+=row.value.length+1;
    }
    candidate->response.headers=candidate->rows;candidate->response.body=(ZhrSlice){NULL,0};
    candidate->response.length=mode==2?zwk_file_length(file):mode==0?response->body.length:response->length;
    if(mode==1 && !candidate->head){result=ZHR_INVALID;goto fail;}
    if(candidate->response.length>ZWK_FILE_MAX_BYTES){result=ZHR_CAPACITY;goto fail;}
    if(!candidate->head) {
        if(!reserve_queue(s)){result=ZHR_CAPACITY;goto fail;}candidate->reservation=TRUE;
        if(mode==0 && response->body.length) {
            candidate->memory=allocated(s,response->body.length,&result);if(result)goto fail;
            candidate->memory_size=response->body.length;memcpy(candidate->memory,response->body.ptr,response->body.length);
        }
        if(mode==2){candidate->buffer=allocated(s,CHUNK,&result);if(result)goto fail;}
    }
    if(mode==2) {
        if(!s->file_budget){s->file_budget=zwk_file_budget_create(s->file_streams);if(!s->file_budget){result=ZHR_OOM;goto fail;}}
        int native_errno=0;result=file_error(zwk_file_prepare_stream(file,s->file_budget,candidate->head,&candidate->file_candidate,&native_errno));
        if(result)goto fail;
        candidate->input=g_object_ref(zwk_file_candidate_stream(candidate->file_candidate));
        candidate->file_control=zwk_file_candidate_control(candidate->file_candidate);zwk_file_control_add(candidate->file_control);
    }
    if(op->terminal || !open_owner(s) || atomic_load_explicit(&op->ticket->phase,memory_order_acquire)!=T_PENDING){result=ZHR_CLOSED;goto fail;}
    *out=candidate;op_unref(op);return ZHR_OK;
fail:
    zhr_candidate_abort(candidate);op_unref(op);return result;
}
int zhr_prepare_memory(ZhrTarget target,const ZhrResponse *response,ZhrCandidate **out) { return prepare(target,response,NULL,0,out); }
int zhr_prepare_head(ZhrTarget target,const ZhrResponse *response,ZhrCandidate **out) { return prepare(target,response,NULL,1,out); }
int zhr_prepare_file(ZhrTarget target,const ZhrResponse *response,ZwkFile *file,ZhrCandidate **out) { return prepare(target,response,file,2,out); }
int zhr_candidate_check(ZhrCandidate *candidate,void *owner) {
    if(!candidate || candidate->admitted)return ZHR_STALE;
    ZhrOp *op=candidate->op;int result=zhr_check(op->owner);if(result)return result;
    if(op->owner->owner!=owner || op->terminal || op->candidate!=candidate || atomic_load_explicit(&op->ticket->phase,memory_order_acquire)!=T_PENDING)return ZHR_STALE;
    return ZHR_OK;
}
int zhr_candidate_admit(ZhrCandidate *candidate,int want_control,ZwkFileControl **control) {
    if(control)*control=NULL;
    g_assert(candidate && !candidate->admitted);ZhrOp *op=candidate->op;g_assert(!on_owner(op->owner));
    candidate->admitted=TRUE;op->accepted=TRUE;
    op->memory=candidate->memory;candidate->memory=NULL;op->memory_size=candidate->memory_size;candidate->memory_size=0;
    op->buffer=candidate->buffer;candidate->buffer=NULL;op->input=candidate->input;candidate->input=NULL;
    op->file_candidate=candidate->file_candidate;candidate->file_candidate=NULL;
    op->file_control=candidate->file_control;candidate->file_control=NULL;
    op->reservation=candidate->reservation;candidate->reservation=FALSE;op->length=candidate->response.length;
    if(candidate->borrow){candidate->borrow->handled=TRUE;op->borrow=NULL;candidate->borrow=NULL;}
    if(want_control && control && op->file_control){zwk_file_control_add(op->file_control);*control=op->file_control;}
    int prior=T_PENDING;
    const gboolean accepted=atomic_compare_exchange_strong_explicit(&op->ticket->phase,&prior,T_ACCEPTED,memory_order_acq_rel,memory_order_acquire);
    return !accepted || op->terminal || !open_owner(op->owner);
}
void zhr_candidate_admit_source(ZhrCandidate *candidate) {
    g_assert(candidate && candidate->admitted);
    ZhrOp *op=candidate->op;op_ref(op);
    admit_file(op,op->terminal || !open_owner(op->owner) || atomic_load_explicit(&op->ticket->phase,memory_order_acquire)!=T_ACCEPTED);
    op_unref(op);
}
static void read_ready(GObject *object,GAsyncResult *result,gpointer data) {
    ZhrOp *op=data;g_assert(!on_owner(op->owner) && op->reading);op->reading=FALSE;
    GError *error=NULL;const gssize count=g_input_stream_read_finish(G_INPUT_STREAM(object),result,&error);
    if(!op->terminal) {
        if(count<0 || (count==0 && op->sent!=op->length) || (count>0 && (uint64_t)count>op->length-op->sent))op_retire(op,T_CANCELLED);
        else if(count==0) {
            op->complete=TRUE;soup_message_body_complete(soup_server_message_get_response_body(op->message));
            if(!op->terminal)soup_server_message_unpause(op->message);
        } else {
            op->sent+=(size_t)count;op->queued=TRUE;
            soup_message_body_append(soup_server_message_get_response_body(op->message),SOUP_MEMORY_COPY,(char *)op->buffer,(gsize)count);
            if(!op->terminal)soup_server_message_unpause(op->message);
        }
    }
    g_clear_error(&error);op_unref(op);
}
static void advance(ZhrOp *op) {
    if(op->terminal || !op->accepted || op->reading || op->queued || op->complete)return;
    if(atomic_load_explicit(&op->ticket->phase,memory_order_acquire)!=T_ACCEPTED){op_retire(op,T_CANCELLED);return;}
    if(op->input) {
        op->reading=TRUE;op_ref(op);
        /* Only the neutral socket-backed class, whose async implementation is
         * pollable and never creates a regular-file GTask worker, reaches here. */
        g_input_stream_read_async(op->input,op->buffer,CHUNK,G_PRIORITY_DEFAULT,op->ticket->cancel,read_ready,op);return;
    }
    if(op->sent==op->length) {
        op->complete=TRUE;soup_message_body_complete(soup_server_message_get_response_body(op->message));
        if(!op->terminal)soup_server_message_unpause(op->message);return;
    }
    const size_t count=MIN((size_t)(op->length-op->sent),(size_t)CHUNK);
    op->queued=TRUE;size_t offset=op->sent;op->sent+=count;
    soup_message_body_append(soup_server_message_get_response_body(op->message),SOUP_MEMORY_COPY,(char *)op->memory+offset,count);
    if(!op->terminal)soup_server_message_unpause(op->message);
}
int zhr_candidate_start(ZhrCandidate *candidate) {
    g_assert(candidate && candidate->admitted);ZhrOp *op=candidate->op;op_ref(op);
    gboolean cancelled_now=op->terminal || !open_owner(op->owner) || atomic_load_explicit(&op->ticket->phase,memory_order_acquire)!=T_ACCEPTED;
    if(cancelled_now)op_retire(op,T_CANCELLED);
    else {
        admit_file(op,FALSE);
        if(!op->terminal) {
            SoupServerMessage *message=g_object_ref(op->message);
            soup_server_message_set_status(message,candidate->response.status,NULL);
            SoupMessageHeaders *headers=soup_server_message_get_response_headers(message);
            soup_message_headers_set_content_type(headers,(const char *)candidate->response.mime.ptr,NULL);
            soup_message_headers_set_content_length(headers,(goffset)op->length);soup_message_headers_append(headers,"Connection","close");
            for(size_t i=0;i<candidate->response.header_count;i++)soup_message_headers_append(headers,(const char *)candidate->rows[i].name.ptr,(const char *)candidate->rows[i].value.ptr);
            soup_message_body_set_accumulate(soup_server_message_get_response_body(message),FALSE);
            if(!op->terminal) {
                if(op->head){op->complete=TRUE;soup_message_body_complete(soup_server_message_get_response_body(message));if(!op->terminal)soup_server_message_unpause(message);}
                else advance(op);
            }
            g_object_unref(message);
        }
    }
    cancelled_now=cancelled_now || (op->terminal && atomic_load_explicit(&op->ticket->phase,memory_order_acquire)!=T_FINISHED);
    candidate_free(candidate);op_unref(op);return cancelled_now;
}
