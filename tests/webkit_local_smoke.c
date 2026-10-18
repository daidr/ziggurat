#include <webkit2/webkit2.h>
#include "../src/webview/webkit_native.h"
#include "../src/platform/linux_content.h"
#include <arpa/inet.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
typedef struct NativeEvent { int kind,key,flags; void *context,*window; double x,y,dx,dy; uint32_t width,height,scale; const char *text; size_t length,selection; } NativeEvent;
extern void *zlg_app_create(void *,void (*)(void *),int *);
extern void zlg_app_destroy(void *);
extern NativeWindow *zlg_window_create(void *,int (*)(void *,const NativeEvent *),const char *,uint32_t,uint32_t,uint32_t,uint32_t,NativeWindow *,int,int,int,int *);
extern int zlg_window_destroy(NativeWindow *);
extern uint32_t zlg_resource_count(void);
typedef struct Server { int fd; unsigned port; pthread_t thread; atomic_int stop,requests; } Server;
static void *serve(void *data) {
    Server *s=data;
    while (!atomic_load(&s->stop)) {
        int fd=accept(s->fd,NULL,NULL); if (fd<0) break;
        atomic_fetch_add(&s->requests,1);
        const char response[]="HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        (void)send(fd,response,sizeof(response)-1,MSG_NOSIGNAL); close(fd);
    }
    return NULL;
}
typedef struct Probe {
    GMainLoop *loop; NativeWindow *window; ZwkState *view; ZwkLocalBudget *budget;
    gboolean closed,failed,completed,done,ipc;
    guint watchdog,drain;
    unsigned ready,started,messages,scripts;
} Probe;
static void fail(Probe *s,const char *error) { fprintf(stderr,"custom local: %s\n",error); s->failed=TRUE; g_main_loop_quit(s->loop); }
static void close_probe(Probe *s) {
    if (s->closed) return;
    s->closed=TRUE; ZwkState *view=s->view; s->view=NULL;
    if (view) zwk_close(view);
    NativeWindow *window=s->window; s->window=NULL;
    if (window) zlg_window_destroy(window);
    if (s->budget) zwk_local_budget_release(s->budget);
    s->budget=NULL;
}
static gboolean drained(gpointer data) {
    Probe *s=data; uint32_t states,callbacks,views,budgets,streams,bytes;
    zwk_counts(&states,&callbacks,&views); zwk_local_counts(&budgets,&streams,&bytes);
    if (s->closed && !states && !callbacks && !views && !budgets && !streams && !bytes && !zlg_content_count()) {
        s->drain=0; g_main_loop_quit(s->loop); return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}
static gboolean timeout(gpointer data) { Probe *s=data; s->watchdog=0; fail(s,"deadline expired"); return G_SOURCE_REMOVE; }
static int native_event(void *data,const NativeEvent *event) {
    Probe *s=data;
    if (event->kind==11) { s->window=NULL; close_probe(s); }
    return 0;
}
static void notified(void *data,int kind,const uint16_t *wide,int32_t code,const ZwkFailure *failure) {
    (void)code; (void)failure; Probe *s=data;
    if (s->closed) { fail(s,"late callback"); return; }
    if (kind==0) { ++s->ready; return; }
    char *value=wide?g_utf16_to_utf8((const gunichar2 *)wide,-1,NULL,NULL,NULL):NULL;
    if (kind!=1 || !value || strcmp(value,"done")) fail(s,value?value:"unexpected native event");
    else { ++s->messages; s->done=TRUE; if (s->completed) close_probe(s); }
    g_free(value);
}
static int page_event(void *data,const ZwkPageEvent *event) {
    Probe *s=data;
    if (s->closed) { fail(s,"late page event"); return 0; }
    if (event->kind==0) ++s->started;
    if (event->kind==1) {
        if (!(event->flags&1)) { fail(s,"initial custom document failed"); return 0; }
        s->completed=TRUE;
        if (s->ipc) { if (s->done) close_probe(s); }
        else if (zwk_evaluate(s->view,"location.protocol+'|'+location.hostname+'|'+location.port",1)!=ZWK_OK) fail(s,"default IPC evaluation rejected");
    }
    return !s->closed;
}
static void script_done(void *data,uint64_t token,int status,int32_t code,const uint16_t *wide,const ZwkFailure *failure) {
    (void)code; (void)failure; Probe *s=data;
    char *value=wide?g_utf16_to_utf8((const gunichar2 *)wide,-1,NULL,NULL,NULL):NULL;
    if (s->closed || token!=1 || status || !value || strcmp(value,"\"asset:|app.ziggurat.invalid|\"") || zwk_post(s->view,"denied")!=8) fail(s,value?value:"script failed");
    else { ++s->scripts; close_probe(s); }
    g_free(value);
}
static void deadline(void *data) { fail(data,"unexpected adapter deadline"); }
static void dispatch(void *data) { (void)data; }
static gboolean run(Server *server,gboolean ipc) {
    Probe s={.ipc=ipc}; s.loop=g_main_loop_new(NULL,FALSE);
    int error=0;
    s.window=zlg_window_create(&s,native_event,"hidden custom local",320,200,0,0,NULL,0,0,1,&error);
    s.budget=zwk_local_budget_new(8,32*1024*1024);
    if (!s.window || error || !s.budget) { fprintf(stderr,"custom window/budget failed: window=%p error=%d budget=%p\n",(void *)s.window,error,(void *)s.budget); return FALSE; }
    const char script[]="window.externalResource=7";
    const ZwkLocalResource resources[]={
        {.path="/script.js",.path_length=10,.mime="text/javascript",.mime_length=15,.bytes=(const uint8_t *)script,.length=sizeof(script)-1},
        {.path="/value",.path_length=6,.mime="text/plain",.mime_length=10,.bytes=(const uint8_t *)"private",.length=7}};
    ZwkLocalOptions local={.scheme="asset",.host="app.ziggurat.invalid",.start_path="/document",.resources=resources,.count=2,.max_response_bytes=65536,.budget=s.budget,.secure=1,.ipc=ipc};
    char *html=ipc?g_strdup_printf("<!doctype html><script>window.violations=[];addEventListener('securitypolicyviolation',e=>violations.push(e.blockedURI+'|'+e.effectiveDirective))</script><script src='/script.js'></script><script>"
        "addEventListener('DOMContentLoaded',async()=>{try{"
        "if(window.externalResource!==7)throw Error('external script '+document.querySelector('script[src]').src+' '+JSON.stringify(violations));"
        "if(location.protocol!=='asset:'||location.hostname!=='app.ziggurat.invalid'||location.port!=='')throw Error('custom authority');"
        "const value=await fetch('/value?query=1#fragment');if(await value.text()!=='private')throw Error('resource');"
        "const head=await fetch('/value',{method:'HEAD'});if(await head.text()!==''||head.headers.get('Content-Length')!=='7')throw Error('HEAD');"
        "const missing=await fetch('/missing');if(missing.status!==404||await missing.text()!=='Not found')throw Error('404');"
        "const reject=async p=>{try{await p;throw Error('unexpected success')}catch(e){if(e.message==='unexpected success')throw e}};"
        "await reject(fetch('/value',{method:'POST'}));"
        "await reject(fetch('/value',{headers:{Unlisted:'denied'}}));"
        "await reject(fetch('asset://other.ziggurat.invalid/value'));"
        "await reject(fetch('/%%2fvalue'));"
        "await Promise.allSettled(Array.from({length:20},()=>fetch('/%%00denied')));"
        "await reject(fetch('http://127.0.0.1:%u/forbidden'));"
        "try{new WebSocket('ws://127.0.0.1:%u/forbidden');throw Error('WebSocket permitted')}catch(e){if(e.message==='WebSocket permitted')throw e}"
        "await new Promise((resolve,reject)=>{try{const w=new Worker(URL.createObjectURL(new Blob(['postMessage(1);fetch(\"http://127.0.0.1:%u/worker\")'])));"
        "w.onmessage=()=>{w.terminate();reject(Error('worker executed'))};w.onerror=()=>{w.terminate();resolve()};"
        "setTimeout(()=>{w.terminate();reject(Error('worker denial missing'))},1000)}catch{resolve()}});"
        "chrome.webview.postMessage('done')}catch(e){chrome.webview.postMessage('error:'+e.message)}})</script>",server->port,server->port,server->port):g_strdup("<script>chrome.webview.postMessage('must-not-arrive')</script>");
    ZwkOptions options={.html=html,.zoom=1.0,.max_pending=2,.max_result_bytes=65536,.local=&local};
    int creation=zwk_create(s.window,&options,notified,page_event,script_done,deadline,&s,&s.view);
    if (creation!=ZWK_OK) { fprintf(stderr,"custom create failed: %d\n",creation); return FALSE; }
    g_free(html);
    s.watchdog=g_timeout_add_seconds(15,timeout,&s); s.drain=g_timeout_add(10,drained,&s);
    g_main_loop_run(s.loop); close_probe(&s);
    if (s.watchdog) g_source_remove(s.watchdog);
    if (s.drain) g_source_remove(s.drain);
    uint32_t states,callbacks,views,budgets,streams,bytes;
    zwk_counts(&states,&callbacks,&views); zwk_local_counts(&budgets,&streams,&bytes);
    gboolean success=!s.failed && s.ready==1 && s.started==1 && s.completed && (ipc?s.messages==1:s.messages==0 && s.scripts==1) && !states && !callbacks && !views && !budgets && !streams && !bytes;
    fprintf(stderr,"custom local IPC=%d ready=%u started=%u messages=%u scripts=%u states=%u streams=%u bytes=%u HTTP=%d\n",ipc,s.ready,s.started,s.messages,s.scripts,states,streams,bytes,atomic_load(&server->requests));
    g_main_loop_unref(s.loop); return success;
}
int main(void) {
    int error=0; void *app=zlg_app_create(NULL,dispatch,&error); if (!app || error) { fprintf(stderr,"custom app failed: %d\n",error); return 2; }
    Server server={0}; server.fd=socket(AF_INET,SOCK_STREAM,0);
    struct sockaddr_in address={.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    if (server.fd<0 || bind(server.fd,(struct sockaddr *)&address,sizeof(address)) || listen(server.fd,8)) return 2;
    socklen_t size=sizeof(address); if (getsockname(server.fd,(struct sockaddr *)&address,&size)) return 2;
    server.port=ntohs(address.sin_port); if (pthread_create(&server.thread,NULL,serve,&server)) return 2;
    gboolean success=run(&server,TRUE) && run(&server,FALSE);
    atomic_store(&server.stop,1); shutdown(server.fd,SHUT_RDWR); close(server.fd); pthread_join(server.thread,NULL);
    zlg_app_destroy(app);
    return success && !atomic_load(&server.requests) && !zlg_resource_count()?0:1;
}
