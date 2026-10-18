/* Host-owned TLS servers for the explicit profile integration fixture.
 * Keys under fixtures/profile-https are public test data, never credentials. */
#include <webkit2/webkit2.h>
#include <libsoup/soup.h>
#include <stdlib.h>
#include <string.h>

typedef struct HttpsFixture {
    SoupServer *server,*other,*proxy;
    char origin[96],other_origin[96],proxy_origin[96];
    unsigned requests,forbidden,proxy_requests,first_cookie,heads,connections,peer_requests,peer_cookie;
    gboolean peer_enabled;
    gboolean credential_mode;
    char authorization[72];
    unsigned authenticated,credential_peer,credential_redirects;
} HttpsFixture;

static void request_started(SoupServer *server,SoupServerMessage *message,gpointer data) {
    (void)message;
    HttpsFixture *f=data;
    /* For libsoup 3.4 the initial message is emitted on acceptance, before
     * g_tls_connection_handshake_async. HTTP handlers remain a separate count. */
    if (server==f->server) ++f->connections;
}

static void serve(SoupServer *server,SoupServerMessage *message,const char *path,GHashTable *query,gpointer data) {
    (void)query;
    HttpsFixture *f=data;
    if (server==f->proxy) {
        ++f->proxy_requests;soup_server_message_set_status(message,502,NULL);return;
    }
    const gboolean credential_peer=server==f->other&&f->credential_mode&&(!strcmp(path,"/credential-public")||!strcmp(path,"/credential-back"));
    if (server==f->other && !credential_peer && (!f->peer_enabled || strcmp(path,"/storage"))) {
        ++f->forbidden;soup_server_message_set_status(message,403,NULL);return;
    }
    const char *method=soup_server_message_get_method(message);
    if (!strcmp(method,"HEAD")) ++f->heads;
    const char *cookie=soup_message_headers_get_one(soup_server_message_get_request_headers(message),"Cookie");
    if (server==f->other && !f->peer_requests++) f->peer_cookie=cookie && strstr(cookie,"tls_seed=present");
    if (!f->requests) f->first_cookie=cookie && strstr(cookie,"tls_seed=present");
    ++f->requests;
    const char *authorization=soup_message_headers_get_one(soup_server_message_get_request_headers(message),"Authorization");
    if(f->credential_mode&&g_getenv("ZIGGURAT_CREDENTIAL_TRACE"))g_printerr("credential wire peer=%d path=%s method=%s auth=%d\n",server==f->other,path,method,authorization!=NULL);
    if((credential_peer&&authorization)||(!credential_peer&&f->credential_mode&&
       (f->authorization[0]?(!authorization||strcmp(authorization,f->authorization)):authorization!=NULL))){
        ++f->forbidden;soup_server_message_set_status(message,403,NULL);return;
    }
    if(credential_peer)++f->credential_peer;
    else if(f->credential_mode&&authorization)++f->authenticated;
    const char *request_origin=soup_message_headers_get_one(soup_server_message_get_request_headers(message),"Origin");
    soup_message_headers_append(soup_server_message_get_response_headers(message),"Access-Control-Allow-Origin",request_origin?request_origin:"*");
    soup_message_headers_append(soup_server_message_get_response_headers(message),"Access-Control-Allow-Credentials","true");
    if (strcmp(method,"GET") && strcmp(method,"HEAD")) {++f->forbidden;soup_server_message_set_status(message,403,NULL);return;}
    if(!strcmp(path,"/credential-same")||!strcmp(path,"/credential-peer")||!strcmp(path,"/credential-back")){
        char target[160];
        g_snprintf(target,sizeof(target),"%s/%s",!strcmp(path,"/credential-peer")?f->other_origin:f->origin,!strcmp(path,"/credential-peer")?"credential-back":"ok");
        ++f->credential_redirects;
        soup_server_message_set_status(message,302,NULL);
        soup_message_headers_append(soup_server_message_get_response_headers(message),"Location",target);
    }else if(!strcmp(path,"/credentials")){
        char body[4096];
        int n=g_snprintf(body,sizeof(body),"<!doctype html><meta charset='utf-8'><script>"
            "addEventListener('DOMContentLoaded',async()=>{let step=0;try{"
            "await fetch('/ok');step=1;await fetch('/head',{method:'HEAD'});step=2;"
            "await fetch('/credential-same');step=3;await fetch('/credential-peer');step=4;"
            "await fetch('%s/credential-public');step=5;%s"
            "chrome.webview.postMessage(JSON.stringify({secure:isSecureContext,origin:location.origin,hidden:!document.cookie.includes('tls_seed='),credential:true}));"
            "}catch(e){chrome.webview.postMessage(JSON.stringify({error:String(e),step}))}});</script>",
            f->other_origin,f->authorization[0]?"await fetch('/ok',{headers:{Authorization:'page-value'}});":"");
        if(n<0||(size_t)n>=sizeof(body))abort();
        soup_server_message_set_status(message,200,NULL);
        soup_message_headers_append(soup_server_message_get_response_headers(message),"Cache-Control","no-store");
        soup_server_message_set_response(message,"text/html",SOUP_MEMORY_COPY,body,(gsize)n);
    } else if (!strcmp(path,"/storage")) {
        const char *site=server==f->other?"b":"a";
        char body[768];
        int n=g_snprintf(body,sizeof(body),"<!doctype html><meta charset='utf-8'><script>"
            "let stored=localStorage.getItem('tls_scope'),before=stored===null?'absent':stored;localStorage.setItem('tls_scope','%s');"
            "chrome.webview.postMessage(JSON.stringify({site:'%s',before,origin:location.origin,secure:isSecureContext,hidden:!document.cookie.includes('tls_seed=')}));"
            "</script>",site,site);
        if (n<0 || (size_t)n>=sizeof(body)) abort();
        soup_server_message_set_status(message,200,NULL);
        soup_message_headers_append(soup_server_message_get_response_headers(message),"Cache-Control","no-store");
        soup_server_message_set_response(message,"text/html",SOUP_MEMORY_COPY,body,(gsize)n);
    } else if (!strcmp(path,"/start")) {
        char body[4096];
        int n=g_snprintf(body,sizeof(body),"<!doctype html><meta charset='utf-8'><title>HTTPS profile</title><script>"
            "addEventListener('DOMContentLoaded',async()=>{let a=0;"
            "await fetch('/ok');await fetch('/head',{method:'HEAD'});"
            "try{await fetch('/denied',{method:'POST'})}catch(e){a++}"
            "try{await fetch('/denied',{headers:{'X-Denied':'yes'}})}catch(e){a++}"
            "try{await fetch('%s/denied')}catch(e){a++}"
            "chrome.webview.postMessage(JSON.stringify({secure:isSecureContext,origin:location.origin,denied:a,hidden:!document.cookie.includes('tls_seed=')}));});"
            "</script>",f->other_origin);
        if (n<0 || (size_t)n>=sizeof(body)) abort();
        soup_server_message_set_status(message,200,NULL);
        soup_message_headers_append(soup_server_message_get_response_headers(message),"Cache-Control","no-store");
        soup_server_message_set_response(message,"text/html",SOUP_MEMORY_COPY,body,(gsize)n);
    } else if (!strcmp(path,"/ok") || !strcmp(path,"/head") || !strcmp(path,"/credential-public")) {
        soup_server_message_set_status(message,200,NULL);
        soup_server_message_set_response(message,"text/plain",SOUP_MEMORY_STATIC,"ok",2);
    } else {
        ++f->forbidden;soup_server_message_set_status(message,403,NULL);
    }
}
static gboolean listen_server(HttpsFixture *f,SoupServer **out,char *origin,size_t capacity,GTlsCertificate *certificate) {
    *out=soup_server_new(NULL,NULL);
    if (certificate) soup_server_set_tls_certificate(*out,certificate);
    g_signal_connect(*out,"request-started",G_CALLBACK(request_started),f);
    soup_server_add_handler(*out,NULL,serve,f,NULL);
    SoupServerListenOptions options=SOUP_SERVER_LISTEN_IPV4_ONLY;
    if (certificate) options|=SOUP_SERVER_LISTEN_HTTPS;
    if (!soup_server_listen_local(*out,0,options,NULL)) return FALSE;
    GSList *uris=soup_server_get_uris(*out);
    if (!uris) return FALSE;
    const int port=g_uri_get_port(uris->data);
    g_snprintf(origin,capacity,"%s://127.0.0.1:%d",certificate?"https":"http",port);
    g_slist_free_full(uris,(GDestroyNotify)g_uri_unref);return TRUE;
}
void ztest_https_free(HttpsFixture *f) {
    if (!f) return;
    SoupServer *servers[]={f->server,f->other,f->proxy};
    for (unsigned i=0;i<3;++i) if (servers[i]) {soup_server_disconnect(servers[i]);g_object_unref(servers[i]);}
    free(f);
}
HttpsFixture *ztest_https_new(const char *public_test_pem_and_key) {
    HttpsFixture *f=calloc(1,sizeof(*f));if (!f) return NULL;
    GError *error=NULL;
    GTlsCertificate *certificate=g_tls_certificate_new_from_pem(public_test_pem_and_key,-1,&error);
    if (!certificate) {g_clear_error(&error);free(f);return NULL;}
    gboolean ok=listen_server(f,&f->server,f->origin,sizeof(f->origin),certificate) &&
        listen_server(f,&f->other,f->other_origin,sizeof(f->other_origin),certificate) &&
        listen_server(f,&f->proxy,f->proxy_origin,sizeof(f->proxy_origin),NULL);
    g_object_unref(certificate);
    if (!ok) {ztest_https_free(f);return NULL;}
    /* Inherited by the actual test-owned NetworkProcess. The opt-in Profile
     * must explicitly select NO_PROXY rather than changing these globals. */
    g_setenv("http_proxy",f->proxy_origin,TRUE);g_setenv("https_proxy",f->proxy_origin,TRUE);
    g_setenv("HTTP_PROXY",f->proxy_origin,TRUE);g_setenv("HTTPS_PROXY",f->proxy_origin,TRUE);
    g_setenv("all_proxy",f->proxy_origin,TRUE);g_setenv("no_proxy","",TRUE);g_setenv("NO_PROXY","",TRUE);
    return f;
}
const char *ztest_https_origin(HttpsFixture *f) { return f->origin; }
void ztest_https_counts(HttpsFixture *f,unsigned *requests,unsigned *forbidden,unsigned *proxy,unsigned *cookie,unsigned *heads) {
    *requests=f->requests;*forbidden=f->forbidden;*proxy=f->proxy_requests;*cookie=f->first_cookie;*heads=f->heads;
}
unsigned ztest_https_connections(HttpsFixture *f) { return f->connections; }
const char *ztest_https_peer_origin(HttpsFixture *f) { return f->other_origin; }
void ztest_https_enable_peer(HttpsFixture *f) { f->peer_enabled=TRUE; }
int ztest_https_peer_cookie(HttpsFixture *f) { return f->peer_requests==1 && f->peer_cookie; }
void ztest_https_stop_server(HttpsFixture *f) { soup_server_disconnect(f->server); }
void ztest_https_credentials(HttpsFixture *f,unsigned byte){
    static const char hex[]="0123456789abcdef";
    f->credential_mode=TRUE;f->authorization[0]=0;
    if(byte){memcpy(f->authorization,"Bearer ",7);for(unsigned i=0;i<32;++i){f->authorization[7+i*2]=hex[byte>>4];f->authorization[8+i*2]=hex[byte&15];}f->authorization[71]=0;}
}
int ztest_https_credential_counts(HttpsFixture *f,unsigned documents){
    /* Two decorated documents plus recovery, then a credential-free reload. */
    return f->forbidden==0&&f->authenticated==8u*(documents<3?documents:3)&&
        f->credential_peer==2u*documents&&f->credential_redirects==3u*documents;
}
/* Isolate default certificate verification from the process proxy decoy.
 * This is fixture-only: it adds no trust or production Profile option. */
void ztest_https_direct(void *context) {
    WebKitWebsiteDataManager *manager=webkit_web_context_get_website_data_manager(WEBKIT_WEB_CONTEXT(context));
    webkit_website_data_manager_set_network_proxy_settings(manager,WEBKIT_NETWORK_PROXY_MODE_NO_PROXY,NULL);
}
int ztest_https_is_certificate_error(uint32_t domain,int32_t code) {
    return domain==G_TLS_ERROR && code==G_TLS_ERROR_BAD_CERTIFICATE;
}
