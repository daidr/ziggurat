#include <libsoup/soup.h>
#include <string.h>
typedef struct Fixture { SoupServer *server,*other;char origin[96],other_origin[96];unsigned requests,forbidden; } Fixture;
static void serve(SoupServer *server,SoupServerMessage *message,const char *path,GHashTable *query,gpointer data){
    (void)query;Fixture *fixture=data;++fixture->requests;
    const char *text=NULL;
    if(server==fixture->other)text="<!doctype html><title>IPC disabled</title><script>addEventListener('DOMContentLoaded',()=>chrome.webview.postMessage('denied'));</script>";
    else if(!strcmp(path,"/"))text="<!doctype html><title>first remote page</title><script>addEventListener('DOMContentLoaded',()=>chrome.webview.postMessage('first'));</script>";
    else if(!strcmp(path,"/second"))text="<!doctype html><title>second remote page</title><script>addEventListener('DOMContentLoaded',()=>chrome.webview.postMessage('second'));</script>";
    else{++fixture->forbidden;soup_server_message_set_status(message,403,NULL);return;}
    soup_server_message_set_status(message,200,NULL);soup_server_message_set_response(message,"text/html",SOUP_MEMORY_STATIC,text,strlen(text));
}
void *ztest_remote_fixture_new(void){
    Fixture *fixture=g_try_new0(Fixture,1);if(!fixture)return NULL;
    fixture->server=soup_server_new(NULL,NULL);soup_server_add_handler(fixture->server,NULL,serve,fixture,NULL);
    if(!soup_server_listen_local(fixture->server,0,SOUP_SERVER_LISTEN_IPV4_ONLY,NULL)){g_object_unref(fixture->server);g_free(fixture);return NULL;}
    GSList *uris=soup_server_get_uris(fixture->server);GUri *uri=uris?uris->data:NULL;
    if(!uri){soup_server_disconnect(fixture->server);g_object_unref(fixture->server);g_free(fixture);return NULL;}
    g_snprintf(fixture->origin,sizeof(fixture->origin),"http://127.0.0.1:%d",g_uri_get_port(uri));g_slist_free_full(uris,(GDestroyNotify)g_uri_unref);return fixture;
}
int ztest_remote_fixture_other(Fixture *fixture){
    fixture->other=soup_server_new(NULL,NULL);soup_server_add_handler(fixture->other,NULL,serve,fixture,NULL);
    if(!soup_server_listen_local(fixture->other,0,SOUP_SERVER_LISTEN_IPV4_ONLY,NULL))return 0;
    GSList *uris=soup_server_get_uris(fixture->other);GUri *uri=uris?uris->data:NULL;
    if(!uri)return 0;g_snprintf(fixture->other_origin,sizeof(fixture->other_origin),"http://127.0.0.1:%d",g_uri_get_port(uri));g_slist_free_full(uris,(GDestroyNotify)g_uri_unref);return 1;
}
const char *ztest_remote_fixture_other_origin(Fixture *fixture){return fixture->other_origin;}
const char *ztest_remote_fixture_origin(Fixture *fixture){return fixture->origin;}
void ztest_remote_fixture_counts(Fixture *fixture,unsigned *requests,unsigned *forbidden){*requests=fixture->requests;*forbidden=fixture->forbidden;}
void ztest_remote_fixture_free(Fixture *fixture){soup_server_disconnect(fixture->server);g_object_unref(fixture->server);if(fixture->other){soup_server_disconnect(fixture->other);g_object_unref(fixture->other);}g_free(fixture);}
