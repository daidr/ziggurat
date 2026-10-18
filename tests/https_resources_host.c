#define _GNU_SOURCE
#include <libsoup/soup.h>
#include <curl/curl.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "../src/https_resources/linux.h"

typedef struct ZhrTestHost {
    SoupServer *server;
    pthread_t client;
    unsigned port,started,got_body;
    char url[8192],authorization[96],origin[80],host[80];
    char range[320],extra_range[320],condition[320],extra_condition[320];
    const char *certificate;
    void (*done)(void *);void *context;
    void (*replaced)(void *);void *replace_context;
    int head,post,result,borrowed,borrowed_bad,borrowed_header;long status;size_t received;curl_off_t representation_length;
} ZhrTestHost;
static void body_chunk(SoupServerMessage *message,GBytes *chunk,gpointer data) {
    (void)message;ZhrTestHost *host=data;host->got_body+=(unsigned)g_bytes_get_size(chunk);
}
static void started(SoupServer *server,SoupServerMessage *message,gpointer data) {
    (void)server;g_signal_connect(message,"got-chunk",G_CALLBACK(body_chunk),data);
}
static void *create_host(const char *certificate_path,const char *key_path,unsigned *port,int raw) {
    GError *error=NULL;GTlsCertificate *certificate=g_tls_certificate_new_from_files(certificate_path,key_path,&error);
    if(error){g_printerr("host TLS: %s\n",error->message);g_error_free(error);return NULL;}
    ZhrTestHost *host=calloc(1,sizeof(*host));if(!host){g_object_unref(certificate);return NULL;}
    host->certificate=certificate_path;host->server=soup_server_new("tls-certificate",certificate,"raw-paths",raw,NULL);g_object_unref(certificate);
    GInetAddress *ip=g_inet_address_new_from_string("127.0.0.1");GSocketAddress *address=g_inet_socket_address_new(ip,0);g_object_unref(ip);
    if(!soup_server_listen(host->server,address,SOUP_SERVER_LISTEN_HTTPS,&error)) {
        g_printerr("host listener: %s\n",error->message);g_error_free(error);g_object_unref(address);g_object_unref(host->server);free(host);return NULL;
    }
    g_object_unref(address);GSList *uris=soup_server_get_uris(host->server);g_assert(uris && !uris->next);
    host->port=(unsigned)g_uri_get_port(uris->data);g_slist_free_full(uris,(GDestroyNotify)g_uri_unref);*port=host->port;
    g_signal_connect(host->server,"request-started",G_CALLBACK(started),host);return host;
}
void *zhr_test_host_create(const char *certificate,const char *key,unsigned *port) { return create_host(certificate,key,port,TRUE); }
void *zhr_test_host_decoded(const char *certificate,const char *key,unsigned *port) { return create_host(certificate,key,port,FALSE); }
void *zhr_test_host_server(void *value) { return ((ZhrTestHost *)value)->server; }
typedef struct ZhrServerWatch { GObject *server;int finalized; } ZhrServerWatch;
static void server_finalized(void *data,GObject *server) {
    (void)server;ZhrServerWatch *watch=data;watch->server=NULL;watch->finalized=1;
}
void *zhr_test_host_watch(void *value) {
    ZhrServerWatch *watch=calloc(1,sizeof(*watch));if(!watch)return NULL;
    watch->server=G_OBJECT(((ZhrTestHost *)value)->server);
    g_object_weak_ref(watch->server,server_finalized,watch);return watch;
}
int zhr_test_host_finalized(void *value) { return ((ZhrServerWatch *)value)->finalized; }
void zhr_test_host_watch_close(void *value) {
    ZhrServerWatch *watch=value;
    if(watch->server)g_object_weak_unref(watch->server,server_finalized,watch);
    free(watch);
}
static void unused_handler(SoupServer *server,SoupServerMessage *message,const char *path,GHashTable *query,gpointer data) {
    (void)server;(void)path;(void)query;(void)data;soup_server_message_set_status(message,404,NULL);
}
static void replaced(gpointer data) { ZhrTestHost *host=data;if(host->replaced){void (*call)(void *)=host->replaced;host->replaced=NULL;call(host->replace_context);} }
void zhr_test_host_replace(void *value,void (*call)(void *),void *context) {
    ZhrTestHost *host=value;host->replaced=call;host->replace_context=context;
    soup_server_add_handler(host->server,"/private/",unused_handler,host,replaced);
}
static size_t receive(char *bytes,size_t size,size_t count,void *data) {
    ZhrTestHost *host=data;const size_t length=size*count;
    if(host->borrowed)for(size_t i=0;i<length;i++)if(bytes[i]!='b')host->borrowed_bad=1;
    host->received+=length;return length;
}
static size_t receive_header(char *bytes,size_t size,size_t count,void *data) {
    ZhrTestHost *host=data;const size_t length=size*count;
    static const char expected[]="X-Borrowed: independently copied\r\n";
    if(length==sizeof(expected)-1 && !strncasecmp(bytes,expected,length))host->borrowed_header=1;
    return length;
}
static void *run_client(void *data) {
    ZhrTestHost *host=data;CURL *curl=curl_easy_init();g_assert(curl);
    curl_easy_setopt(curl,CURLOPT_URL,host->url);curl_easy_setopt(curl,CURLOPT_HTTP_VERSION,CURL_HTTP_VERSION_1_1);curl_easy_setopt(curl,CURLOPT_PATH_AS_IS,1L);
    curl_easy_setopt(curl,CURLOPT_CAINFO,host->certificate);curl_easy_setopt(curl,CURLOPT_NOPROXY,"*");curl_easy_setopt(curl,CURLOPT_NOSIGNAL,1L);
    curl_easy_setopt(curl,CURLOPT_TIMEOUT,10L);curl_easy_setopt(curl,CURLOPT_WRITEFUNCTION,receive);curl_easy_setopt(curl,CURLOPT_WRITEDATA,host);
    curl_easy_setopt(curl,CURLOPT_HEADERFUNCTION,receive_header);curl_easy_setopt(curl,CURLOPT_HEADERDATA,host);
    struct curl_slist *headers=NULL;
    if(host->authorization[0])headers=curl_slist_append(headers,host->authorization);
    if(host->origin[0])headers=curl_slist_append(headers,host->origin);
    if(host->host[0])headers=curl_slist_append(headers,host->host);
    if(host->range[0])headers=curl_slist_append(headers,host->range);
    if(host->extra_range[0])headers=curl_slist_append(headers,host->extra_range);
    if(host->condition[0])headers=curl_slist_append(headers,host->condition);
    if(host->extra_condition[0])headers=curl_slist_append(headers,host->extra_condition);
    if(host->head)curl_easy_setopt(curl,CURLOPT_NOBODY,1L);
    if(host->post){headers=curl_slist_append(headers,"Expect: 100-continue");curl_easy_setopt(curl,CURLOPT_POSTFIELDS,"not-authorized-body");}
    curl_easy_setopt(curl,CURLOPT_HTTPHEADER,headers);host->result=curl_easy_perform(curl);curl_easy_getinfo(curl,CURLINFO_RESPONSE_CODE,&host->status);
    curl_easy_getinfo(curl,CURLINFO_CONTENT_LENGTH_DOWNLOAD_T,&host->representation_length);
    curl_slist_free_all(headers);curl_easy_cleanup(curl);host->done(host->context);return NULL;
}
/* Literal test rows, including duplicate lines; never CURLOPT_RANGE rewriting. */
int zhr_test_host_ranges(void *value,const char *range,const char *extra_range,const char *condition,const char *extra_condition) {
    ZhrTestHost *host=value;
    if(host->started)return 0;
    const char *source[]={range,extra_range,condition,extra_condition};
    char *target[]={host->range,host->extra_range,host->condition,host->extra_condition};
    for(unsigned i=0;i<4;i++)if(source[i] && strlen(source[i])>=sizeof(host->range))return 0;
    for(unsigned i=0;i<4;i++)snprintf(target[i],sizeof(host->range),"%s",source[i]?source[i]:"");
    return 1;
}
int zhr_test_host_start(void *value,const char *authorization,int mode,void (*done)(void *),void *context) {
    ZhrTestHost *host=value;if(host->started)return 0;
    host->done=done;host->context=context;host->head=mode==1||mode==13;host->post=mode==5;host->borrowed=mode==12||mode==13;
    snprintf(host->url,sizeof(host->url),"https://127.0.0.1:%u/private/body",host->port);
    const char *route=mode==6?"/%70rivate/body":mode==7?"/private/one%2ftwo":mode==8?"/private/../other":mode==10?"/private/%2e%2e/other":mode==11?"/private/body?q=%2f":NULL;
    if(route)snprintf(host->url,sizeof(host->url),"https://127.0.0.1:%u%s",host->port,route);
    if(mode==9){size_t end=strlen(host->url);host->url[end++]='?';memset(host->url+end,'q',4096);host->url[end+4096]=0;}
    if(mode!=2)snprintf(host->authorization,sizeof(host->authorization),"Authorization: %s",authorization);
    if(mode==3)snprintf(host->origin,sizeof(host->origin),"Origin: https://127.0.0.1:%u",host->port==65535?65534:host->port+1);
    if(mode==4)snprintf(host->host,sizeof(host->host),"Host: localhost:%u",host->port);
    if(pthread_create(&host->client,NULL,run_client,host))return 0;host->started=1;return 1;
}
void zhr_test_host_join(void *value) { ZhrTestHost *host=value;if(host->started){pthread_join(host->client,NULL);host->started=0;} }
void zhr_test_host_result(void *value,int *result,long *status,size_t *received,unsigned *body) {
    ZhrTestHost *host=value;*result=host->result;*status=host->status;*received=host->received;*body=host->got_body;
}
uint64_t zhr_test_host_length(void *value) {ZhrTestHost *host=value;return host->representation_length<0?UINT64_MAX:(uint64_t)host->representation_length;}
int zhr_test_host_borrowed_good(void *value) { ZhrTestHost *host=value;return !host->borrowed_bad && host->borrowed_header; }
void zhr_test_host_close(void *value) {
    ZhrTestHost *host=value;g_assert(!host->started);soup_server_disconnect(host->server);g_object_unref(host->server);free(host);
}
/* Explicit test-only draining after worker joins. No production loop is added. */
int zhr_test_context_iteration(void) { return g_main_context_iteration(NULL,FALSE); }
static gboolean drain_timeout(gpointer data) { *(int *)data=1;return G_SOURCE_REMOVE; }
int zhr_test_host_drain(void) {
    int expired=0;guint timeout=g_timeout_add_seconds(5,drain_timeout,&expired);
    for(;;) {
        ZhrCounts counts;zhr_counts(&counts);
        if(!counts.owners && !counts.gates && !counts.operations && !counts.tickets)break;
        if(expired)return 0;
        g_main_context_iteration(NULL,TRUE);
    }
    g_source_remove(timeout);return 1;
}
int zhr_test_host_file(void) {
    int descriptor=memfd_create("https-resource-app-fixture",MFD_CLOEXEC);if(descriptor<0)return -1;
    unsigned char bytes[4096];memset(bytes,'f',sizeof(bytes));
    for(unsigned i=0;i<80;i++)if(write(descriptor,bytes,sizeof(bytes))!=(ssize_t)sizeof(bytes)){close(descriptor);return -1;}
    return descriptor;
}
