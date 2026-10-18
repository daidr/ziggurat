#define _GNU_SOURCE
#include "transport_linux.h"
#include <libsoup/soup.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

enum { PROCESS_CAPACITY=16,PEM_CAPACITY=32769 };
struct ZhtOwner {
    atomic_uint refs;
    GThread *thread;
    SoupServer *server;
    size_t peak_bytes;
    uint16_t port;
    gboolean sealed,closed;
};
static atomic_uint owners,servers;
static atomic_size_t requested_bytes;
static GQuark owner_key;
#ifdef ZHT_TESTING
static int allocations=-1;
void zht_test_allocation_limit(int count) { allocations=count; }
#endif
static void *try_zero(size_t bytes) {
#ifdef ZHT_TESTING
    if(!allocations)return NULL;
    if(allocations>0)--allocations;
#endif
    return calloc(1,bytes);
}
void zht_ref(ZhtOwner *s) { atomic_fetch_add_explicit(&s->refs,1,memory_order_relaxed); }
void zht_unref(ZhtOwner *s) {
    if(atomic_fetch_sub_explicit(&s->refs,1,memory_order_acq_rel)!=1)return;
    g_assert(s->closed && !s->server);
    atomic_fetch_sub_explicit(&requested_bytes,sizeof(*s),memory_order_relaxed);
    atomic_fetch_sub_explicit(&owners,1,memory_order_relaxed);
    free(s);
}
static int on_owner(ZhtOwner *s) { return s->thread==g_thread_self()?ZHT_OK:ZHT_WRONG_THREAD; }
static gboolean accepting(ZhtOwner *s) { return !s->sealed && !s->closed && s->server; }
static void server_final(gpointer pointer) {
    ZhtOwner *s=pointer;
    atomic_fetch_sub_explicit(&servers,1,memory_order_relaxed);
    zht_unref(s);
}
static void failure_take(ZhtFailure *out,GError *error) {
    if(error){out->domain=error->domain;out->code=error->code;g_error_free(error);}
}
static gboolean actual_port(SoupServer *server,uint16_t *port) {
    GSList *uris=soup_server_get_uris(server),*listeners=soup_server_get_listeners(server);
    gboolean valid=soup_server_is_https(server) && uris && !uris->next && listeners && !listeners->next;
    if(valid) {
        GUri *uri=uris->data;
        const char *scheme=g_uri_get_scheme(uri),*host=g_uri_get_host(uri);
        const int value=g_uri_get_port(uri);
        valid=scheme && !strcmp(scheme,"https") && host && !strcmp(host,"127.0.0.1") && value>0 && value<=65535;
        GError *error=NULL;
        GSocketAddress *local=g_socket_get_local_address(G_SOCKET(listeners->data),&error);
        valid=valid && !error && G_IS_INET_SOCKET_ADDRESS(local);
        if(valid) {
            GInetAddress *ip=g_inet_socket_address_get_address(G_INET_SOCKET_ADDRESS(local));
            const uint8_t expected[4]={127,0,0,1};
            valid=g_inet_address_get_family(ip)==G_SOCKET_FAMILY_IPV4 && !memcmp(g_inet_address_to_bytes(ip),expected,4) && g_inet_socket_address_get_port(G_INET_SOCKET_ADDRESS(local))==value;
        }
        if(valid)*port=(uint16_t)value;
        g_clear_object(&local);g_clear_error(&error);
    }
    g_slist_free_full(uris,(GDestroyNotify)g_uri_unref);g_slist_free(listeners);
    return valid;
}
int zht_create(const ZhtOptions *options,ZhtOwner **out,ZhtFailure *failure) {
    if(!out || !failure)return ZHT_INVALID;
    *out=NULL;*failure=(ZhtFailure){0};
    if(!options || !options->pem || !options->length || options->length>PEM_CAPACITY || memchr(options->pem,0,options->length))return ZHT_INVALID;
    GMainContext *thread_default=g_main_context_get_thread_default();
    if(thread_default && thread_default!=g_main_context_default())return ZHT_INVALID;
    if(options->zig_bytes>options->bytes || options->temporary_bytes>options->bytes-options->zig_bytes || sizeof(ZhtOwner)>options->bytes-options->zig_bytes-options->temporary_bytes)return ZHT_CAPACITY;
    if(atomic_load_explicit(&owners,memory_order_relaxed)>=PROCESS_CAPACITY)return ZHT_FULL;
    ZhtOwner *s=try_zero(sizeof(*s));
    if(!s)return ZHT_OOM;
    atomic_init(&s->refs,1);s->thread=g_thread_self();
    s->peak_bytes=sizeof(*s)+options->zig_bytes+options->temporary_bytes;
    atomic_fetch_add_explicit(&owners,1,memory_order_relaxed);
    atomic_fetch_add_explicit(&requested_bytes,sizeof(*s),memory_order_relaxed);
    GError *error=NULL;
    GTlsCertificate *certificate=g_tls_certificate_new_from_pem((const char *)options->pem,(gssize)options->length,&error);
    if(!certificate){failure_take(failure,error);zht_close(s);zht_unref(s);return ZHT_NATIVE;}
    s->server=soup_server_new("tls-certificate",certificate,"raw-paths",TRUE,NULL);
    g_object_unref(certificate);
    if(!owner_key)owner_key=g_quark_from_static_string("ziggurat-owned-https-transport");
    zht_ref(s);atomic_fetch_add_explicit(&servers,1,memory_order_relaxed);
    g_object_set_qdata_full(G_OBJECT(s->server),owner_key,s,server_final);
    GInetAddress *ip=g_inet_address_new_from_string("127.0.0.1");
    GSocketAddress *address=g_inet_socket_address_new(ip,0);g_object_unref(ip);
    gboolean ok=soup_server_listen(s->server,address,SOUP_SERVER_LISTEN_HTTPS,&error);
    g_object_unref(address);
    if(!ok){failure_take(failure,error);zht_close(s);zht_unref(s);return ZHT_NATIVE;}
    g_clear_error(&error);
    if(!actual_port(s->server,&s->port)){zht_close(s);zht_unref(s);return ZHT_INVALID;}
    *out=s;return ZHT_OK;
}
/* SDK disconnect closes listening sockets only. In-progress messages continue;
 * their Endpoint is independently sealed by Stop/close and owns late refs. */
int zht_seal(ZhtOwner *s) {
    if(!s)return ZHT_CLOSED;
    if(on_owner(s))return ZHT_WRONG_THREAD;
    zht_ref(s);s->sealed=TRUE;
    SoupServer *server=s->server?g_object_ref(s->server):NULL;
    if(server){soup_server_disconnect(server);g_object_unref(server);}
    zht_unref(s);return ZHT_OK;
}
void zht_close(ZhtOwner *s) {
    if(!s || s->closed)return;
    g_assert(!on_owner(s));zht_ref(s);
    s->closed=TRUE;s->sealed=TRUE;
    SoupServer *server=s->server;s->server=NULL;
    if(server){soup_server_disconnect(server);g_object_unref(server);}
    zht_unref(s);
}
int zht_stats(ZhtOwner *s,ZhtStats *out) {
    if(!s || !out)return ZHT_INVALID;
    if(on_owner(s))return ZHT_WRONG_THREAD;
    *out=(ZhtStats){sizeof(*s),s->peak_bytes,accepting(s),s->port};return ZHT_OK;
}
int zht_lease_begin(ZhtOwner *s,ZhtLease *out) {
    if(!out)return ZHT_INVALID;*out=(ZhtLease){0};
    if(!s)return ZHT_CLOSED;
    if(on_owner(s))return ZHT_WRONG_THREAD;
    if(!accepting(s))return ZHT_CLOSED;
    zht_ref(s);
    SoupServer *server=g_object_ref(s->server);
    if(!accepting(s) || s->server!=server){g_object_unref(server);zht_unref(s);return ZHT_CLOSED;}
    *out=(ZhtLease){s,server,s->port};return ZHT_OK;
}
int zht_lease_finish(ZhtLease *input) {
    if(!input || !input->owner || !input->server)return ZHT_INVALID;
    ZhtLease lease=*input;*input=(ZhtLease){0};
    g_assert(!on_owner(lease.owner));
    g_object_unref(lease.server);
    const int result=accepting(lease.owner)?ZHT_OK:ZHT_CLOSED;
    /* Final project free has no foreign/user callbacks. */
    zht_unref(lease.owner);return result;
}
size_t zht_owner_size(void) { return sizeof(ZhtOwner); }
void zht_counts(ZhtCounts *out) { *out=(ZhtCounts){atomic_load(&owners),atomic_load(&servers),atomic_load(&requested_bytes)}; }
