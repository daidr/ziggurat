/* Explicit private TLS oracle. It serves only this fixture's bounded HTML and
   never reads a host-selected path or modifies process proxy/certificate state. */
#include <libsoup/soup.h>
#include <stdlib.h>
#include <string.h>
typedef struct InitializerHttps {
    SoupServer *servers[2];
    char origins[2][80];
    unsigned requests[2];
} InitializerHttps;
static void serve_initializer(SoupServer *server,SoupServerMessage *message,const char *path,GHashTable *query,gpointer data) {
    (void)query;InitializerHttps *self=data;
    unsigned index=server==self->servers[0]?0u:1u;++self->requests[index];
    static const char html[]="<!doctype html><meta charset='utf-8'><title>initializer oracle</title>"
        "<body><script>const trace=Array.isArray(window.__zigInitializer)?window.__zigInitializer.slice():[];"
        "const child=document.createElement('iframe');child.onload=()=>{"
        "chrome.webview.postMessage(JSON.stringify({trace,origin:location.origin,path:location.pathname,"
        "frame:child.contentWindow.location.href==='about:blank'&&typeof child.contentWindow.__zigInitializer==='undefined'}))};document.body.appendChild(child)</script>";
    g_assert(path && path[0]=='/');
    soup_server_message_set_status(message,200,NULL);
    soup_message_headers_append(soup_server_message_get_response_headers(message),"Cache-Control","no-store");
    soup_server_message_set_response(message,"text/html",SOUP_MEMORY_STATIC,html,sizeof(html)-1);
}
void zinit_https_free(InitializerHttps *self) {
    if(!self)return;
    for(unsigned i=0;i<2;++i)if(self->servers[i]){soup_server_disconnect(self->servers[i]);g_object_unref(self->servers[i]);}
    free(self);
}
InitializerHttps *zinit_https_new(const char *pem_and_key) {
    InitializerHttps *self=calloc(1,sizeof(*self));if(!self)return NULL;
    GError *error=NULL;GTlsCertificate *certificate=g_tls_certificate_new_from_pem(pem_and_key,-1,&error);
    if(!certificate){g_clear_error(&error);free(self);return NULL;}
    for(unsigned i=0;i<2;++i){
        self->servers[i]=soup_server_new(NULL,NULL);soup_server_set_tls_certificate(self->servers[i],certificate);
        soup_server_add_handler(self->servers[i],NULL,serve_initializer,self,NULL);
        if(!soup_server_listen_local(self->servers[i],0,SOUP_SERVER_LISTEN_IPV4_ONLY|SOUP_SERVER_LISTEN_HTTPS,&error)){
            g_clear_error(&error);g_object_unref(certificate);zinit_https_free(self);return NULL;
        }
        GSList *uris=soup_server_get_uris(self->servers[i]);
        if(!uris){g_object_unref(certificate);zinit_https_free(self);return NULL;}
        g_snprintf(self->origins[i],sizeof(self->origins[i]),"https://127.0.0.1:%d",g_uri_get_port(uris->data));
        g_slist_free_full(uris,(GDestroyNotify)g_uri_unref);
    }
    g_object_unref(certificate);return self;
}
const char *zinit_https_origin(InitializerHttps *self,unsigned index){return index<2?self->origins[index]:NULL;}
unsigned zinit_https_requests(InitializerHttps *self,unsigned index){return index<2?self->requests[index]:0;}
