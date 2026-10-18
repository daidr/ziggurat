#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#include "../src/webview/webkit_native.h"
#include "../src/platform/linux_content.h"
#include <stdio.h>
#include <string.h>
typedef struct NativeEvent { int kind,key,flags;void *context,*window;double x,y,dx,dy;uint32_t width,height,scale;const char *text;size_t length,selection; } NativeEvent;
extern void *zlg_app_create(void *,void (*)(void *),int *);
extern void zlg_app_destroy(void *);
extern NativeWindow *zlg_window_create(void *,int (*)(void *,const NativeEvent *),const char *,uint32_t,uint32_t,uint32_t,uint32_t,NativeWindow *,int,int,int,int *);
extern int zlg_window_destroy(NativeWindow *);
extern uint32_t zlg_resource_count(void);
typedef struct Probe {
    GMainLoop *loop;NativeWindow *window;ZwkState *view;
    SoupServer *allowed,*blocked;char origin[96],other[96],url[128];
    unsigned ready,started,finished,messages,requests,head,safe,forbidden,blocked_requests,failures;
    gboolean closed,failed,missing,navigation_requested,navigation_submitted;unsigned redirect_mode;int expected_failure;guint watchdog,drain;
} Probe;
static void fail(Probe *s,const char *text){fprintf(stderr,"remote backend: %s\n",text);s->failed=TRUE;g_main_loop_quit(s->loop);}
#define CHECK(s,x) do{if(!(x)){fail(s,#x);return;}}while(0)
static void close_view(Probe *s){
    if(s->closed)return;s->closed=TRUE;
    ZwkState *view=s->view;s->view=NULL;if(view)zwk_close(view);
    NativeWindow *window=s->window;s->window=NULL;if(window)zlg_window_destroy(window);
}
static gboolean drained(gpointer p){
    Probe *s=p;uint32_t a,b,c;zwk_counts(&a,&b,&c);
    if(s->closed&&!a&&!b&&!c&&!zlg_content_count()){s->drain=0;g_main_loop_quit(s->loop);return G_SOURCE_REMOVE;}return G_SOURCE_CONTINUE;
}
static gboolean timeout(gpointer p){Probe *s=p;s->watchdog=0;fail(s,"watchdog");return G_SOURCE_REMOVE;}
static int event(void *p,const NativeEvent *value){Probe *s=p;if(value->kind==11){s->window=NULL;if(!s->closed)close_view(s);}return 0;}
static void dispatch(void *p){(void)p;}
static void deadline(void *p){fail(p,"unexpected script deadline");}
static void script(void *p,uint64_t token,int status,int32_t code,const uint16_t *value,const ZwkFailure *failure){
    (void)code;(void)failure;Probe *s=p;CHECK(s,status==0&&value);
    char *text=g_utf16_to_utf8((const gunichar2 *)value,-1,NULL,NULL,NULL);gboolean ok=text&&!strcmp(text,token==2?"0":"42");g_free(text);CHECK(s,ok);
    if(token==2)return;
    close_view(s);
}
static void navigate(Probe *s){
    if(s->navigation_submitted||!s->navigation_requested||s->finished!=1)return;
    s->navigation_submitted=TRUE;CHECK(s,zwk_evaluate(s->view,"location.href='/target';0",2)==ZWK_OK);
}
static int page(void *p,const ZwkPageEvent *value){
    Probe *s=p;if(s->closed){fail(s,"late page callback");return 0;}
    if(value->kind==0)++s->started;
    if(value->kind==1){
        ++s->finished;
        if(s->redirect_mode==1){if(value->flags&1)fail(s,"disabled redirect committed");close_view(s);}
        else if(!(value->flags&1))fail(s,"failed remote document");
        if(s->redirect_mode>=3)navigate(s);
    }
    return !s->closed;
}
static void notified(void *p,int kind,const uint16_t *value,int32_t code,const ZwkFailure *failure){
    Probe *s=p;(void)code;CHECK(s,!s->closed);
    if(kind==0){++s->ready;CHECK(s,!s->missing&&s->requests==0);CHECK(s,zwk_post(s->view,"early")==ZWK_NOT_READY);return;}
    if(kind==2){++s->failures;CHECK(s,s->missing&&failure&&failure->domain&&failure->code==s->expected_failure&&s->ready==0&&s->requests==0);close_view(s);return;}
    if(kind==3){CHECK(s,s->redirect_mode==3&&s->requests==1&&s->navigation_submitted);close_view(s);return;}
    CHECK(s,kind==1&&value&&!s->missing);
    char *text=g_utf16_to_utf8((const gunichar2 *)value,-1,NULL,NULL,NULL);
    gboolean requested=text&&!strcmp(text,"navigate"),done=text&&!strcmp(text,"done");g_free(text);
    if(requested){CHECK(s,s->redirect_mode>=3);s->navigation_requested=TRUE;navigate(s);return;}
    CHECK(s,done);++s->messages;
    CHECK(s,zwk_evaluate(s->view,"6*7",1)==ZWK_OK);
}
static void serve(SoupServer *server,SoupServerMessage *message,const char *path,GHashTable *query,gpointer p){
    (void)query;Probe *s=p;
    if(server==s->blocked){++s->blocked_requests;soup_server_message_set_status(message,403,NULL);return;}
    ++s->requests;const char *method=soup_server_message_get_method(message);
    if(!strcmp(path,"/navigate")){
        const char body[]="<!doctype html><script>addEventListener('DOMContentLoaded',()=>chrome.webview.postMessage('navigate'));</script>";
        soup_server_message_set_status(message,200,NULL);soup_server_message_set_response(message,"text/html",SOUP_MEMORY_COPY,body,sizeof(body)-1);return;
    }
    if(!strcmp(path,"/redirect")){
        char target[128];g_snprintf(target,sizeof(target),"%s/target",s->origin);
        soup_message_headers_append(soup_server_message_get_response_headers(message),"Location",target);soup_server_message_set_status(message,302,NULL);return;
    }
    if(!strcmp(path,"/target")){
        const char body[]="<!doctype html><script>addEventListener('DOMContentLoaded',()=>chrome.webview.postMessage('done'));</script>";
        soup_server_message_set_status(message,200,NULL);soup_server_message_set_response(message,"text/html",SOUP_MEMORY_COPY,body,sizeof(body)-1);return;
    }
    if(!strcmp(path,"/")){
        char *body=g_strdup_printf("<!doctype html><title>remote policy</title><script>"
            "addEventListener('DOMContentLoaded',async()=>{const a=[];"
            "a.push(fetch('/get'));a.push(fetch('/head',{method:'HEAD'}));"
            "a.push(fetch('/safe',{headers:{'X-Safe':'yes'}}));"
            "a.push(fetch('/post',{method:'POST'}));a.push(fetch('/header',{headers:{'X-Denied':'no'}}));"
            "a.push(fetch('%s/blocked'));"
            "a.push(new Promise(r=>{try{const w=new WebSocket('%s/socket'.replace('http:','ws:'));w.onerror=r;w.onopen=()=>{w.close();r()}}catch{r()}}));"
            "a.push(new Promise(r=>{try{const w=new Worker(URL.createObjectURL(new Blob(['fetch(\"/worker\")'])));w.onerror=()=>{w.terminate();r()};w.onmessage=r}catch{r()}}));"
            "await Promise.allSettled(a);chrome.webview.postMessage('done')});</script>",s->other,s->origin);
        /* A response policy must remain additive to the fixed View policy. */
        soup_message_headers_append(soup_server_message_get_response_headers(message),"Content-Security-Policy","default-src * data: blob: 'unsafe-inline' 'unsafe-eval'; connect-src * ws: wss:; worker-src blob:");
        soup_server_message_set_status(message,200,NULL);soup_server_message_set_response(message,"text/html",SOUP_MEMORY_TAKE,body,strlen(body));return;
    }
    if(!strcmp(path,"/head")&&!strcmp(method,"HEAD"))++s->head;
    else if(!strcmp(path,"/safe")&&!g_strcmp0(soup_message_headers_get_one(soup_server_message_get_request_headers(message),"X-Safe"),"yes"))++s->safe;
    else if(strcmp(path,"/get"))++s->forbidden;
    soup_server_message_set_status(message,200,NULL);soup_server_message_set_response(message,"text/plain",SOUP_MEMORY_STATIC,"ok",2);
}
static gboolean start_server(Probe *s,SoupServer **out,char *origin,size_t capacity){
    *out=soup_server_new(NULL,NULL);soup_server_add_handler(*out,NULL,serve,s,NULL);
    if(!soup_server_listen_local(*out,0,SOUP_SERVER_LISTEN_IPV4_ONLY,NULL))return FALSE;
    GSList *uris=soup_server_get_uris(*out);GUri *uri=uris?uris->data:NULL;
    if(!uri)return FALSE;g_snprintf(origin,capacity,"http://127.0.0.1:%d",g_uri_get_port(uri));g_slist_free_full(uris,(GDestroyNotify)g_uri_unref);return TRUE;
}
static int run(const char *directory,int expected_failure,unsigned redirect_mode){
    gboolean missing=expected_failure!=0;
    Probe s={.missing=missing,.redirect_mode=redirect_mode,.expected_failure=expected_failure};s.loop=g_main_loop_new(NULL,FALSE);int error=0;
    if(!start_server(&s,&s.allowed,s.origin,sizeof(s.origin))||!start_server(&s,&s.blocked,s.other,sizeof(s.other)))return 2;
    g_snprintf(s.url,sizeof(s.url),"%s/%s",s.origin,redirect_mode>=3?"navigate":(redirect_mode?"redirect":""));
    s.window=zlg_window_create(&s,event,"hidden remote page",320,200,0,0,NULL,0,0,1,&error);if(!s.window||error)return 2;
    ZwkRemoteHeader header={"X-Safe","yes"};ZwkRemoteOrigin origin={s.origin,7u,3u,&header,1,NULL};
    ZwkRemoteOptions remote={s.url,directory,&origin,1,missing?300u:5000u,1,redirect_mode==4,redirect_mode==2};
    ZwkOptions options={.html="",.zoom=1,.max_pending=2,.max_result_bytes=65536,.policy_flags=redirect_mode==3?1u:0u,.remote=&remote};
    if(zwk_create(s.window,&options,notified,page,script,deadline,&s,&s.view)!=ZWK_OK)return 2;
    s.watchdog=g_timeout_add_seconds(15,timeout,&s);s.drain=g_timeout_add(10,drained,&s);g_main_loop_run(s.loop);
    close_view(&s);if(s.watchdog)g_source_remove(s.watchdog);if(s.drain)g_source_remove(s.drain);
    uint32_t a,b,c;zwk_counts(&a,&b,&c);
    gboolean okay=!s.failed&&!a&&!b&&!c&&!zlg_content_count()&&!s.forbidden&&!s.blocked_requests&&
        (missing?(s.failures==1&&!s.ready&&!s.started&&!s.requests):(redirect_mode?(s.ready==1&&s.started==(redirect_mode==4?2u:1u)&&s.finished==(redirect_mode==4?2u:1u)&&s.messages==((redirect_mode==2||redirect_mode==4)?1u:0u)&&s.requests==((redirect_mode==2||redirect_mode==4)?2u:1u)):(s.ready==1&&s.started==1&&s.finished==1&&s.messages==1&&s.requests==4&&s.head==1&&s.safe==1)));
    printf("remote backend missing=%d redirect=%u ready=%u page=%u/%u messages=%u requests=%u head=%u safe=%u forbidden=%u blocked=%u failures=%u refs=%u/%u/%u\n",missing,redirect_mode,s.ready,s.started,s.finished,s.messages,s.requests,s.head,s.safe,s.forbidden,s.blocked_requests,s.failures,a,b,c);
    soup_server_disconnect(s.allowed);soup_server_disconnect(s.blocked);g_object_unref(s.allowed);g_object_unref(s.blocked);g_main_loop_unref(s.loop);return okay?0:1;
}
int main(int argc,char **argv){
    if(argc!=4)return 2;int error=0;void *app=zlg_app_create(NULL,dispatch,&error);if(!app||error)return 2;
    unsigned baseline=zlg_resource_count();int result=run(argv[2],ZWK_POLICY_TIMEOUT,0);if(!result)result=run(argv[3],ZWK_POLICY_MISMATCH,0);if(!result)result=run(argv[1],0,0);
    if(!result)result=run(argv[1],FALSE,1);if(!result)result=run(argv[1],FALSE,2);
    if(!result)result=run(argv[1],FALSE,3);if(!result)result=run(argv[1],FALSE,4);
    if(zlg_resource_count()!=baseline)result=1;zlg_app_destroy(app);return result;
}
