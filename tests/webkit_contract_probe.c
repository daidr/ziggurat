#include <webkit2/webkit2.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>

/* Standalone hidden GTK integration probe, not the public WebView backend. */
typedef struct Server { int fd; unsigned port; pthread_t thread; atomic_int requests, stop; } Server;
static void *serve(void *data) {
    Server *s=data;
    while (!atomic_load(&s->stop)) {
        int fd=accept(s->fd,NULL,NULL);
        if(fd<0) break;
        struct timeval timeout={.tv_sec=1};
        (void)setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
        char input[1024];
        if(recv(fd,input,sizeof(input),0)>0) {
            atomic_fetch_add(&s->requests,1);
            const char reply[]="HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok";
            (void)send(fd,reply,sizeof(reply)-1,MSG_NOSIGNAL);
        }
        close(fd);
    }
    return NULL;
}
static int server_start(Server *s) {
    memset(s,0,sizeof(*s));
    atomic_init(&s->requests,0); atomic_init(&s->stop,0);
    s->fd=socket(AF_INET,SOCK_STREAM,0);
    struct sockaddr_in address={.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    if(s->fd<0 || bind(s->fd,(struct sockaddr*)&address,sizeof(address)) || listen(s->fd,8)) return 0;
    socklen_t n=sizeof(address);
    if(getsockname(s->fd,(struct sockaddr*)&address,&n)) return 0;
    s->port=ntohs(address.sin_port);
    return pthread_create(&s->thread,NULL,serve,s)==0;
}
static void server_stop(Server *s) {
    atomic_store(&s->stop,1);
    shutdown(s->fd,SHUT_RDWR);
    close(s->fd);
    pthread_join(s->thread,NULL);
}
typedef struct Probe {
    GMainLoop *loop;
    GThread *owner;
    GtkWidget *window;
    WebKitWebView *view;
    WebKitUserContentManager *manager;
    WebKitWebContext *context;
    GCancellable *cancel;
    Server *server;
    unsigned refs, pending, late, messages, denied;
    gboolean strict, active, finalized, failed, csp_ready;
    guint watchdog;
} Probe;
static void maybe_done(Probe *s) {
    if(!s->active && s->finalized && s->pending==0 && s->refs==1) g_main_loop_quit(s->loop);
}
static void retain(Probe *s) { g_assert(s->owner==g_thread_self()); ++s->refs; }
static void release(Probe *s) { g_assert(s->owner==g_thread_self() && s->refs>1); --s->refs; maybe_done(s); }
static void close_view(Probe *s) {
    if(!s->active) return;
    s->active=FALSE;
    g_signal_handlers_disconnect_by_data(s->manager,s);
    WebKitWebView *view=s->view;
    s->view=NULL;
    g_signal_handlers_disconnect_by_data(view,s);
    g_cancellable_cancel(s->cancel);
    gtk_widget_destroy(GTK_WIDGET(view));
    g_object_unref(view);
    gtk_widget_destroy(s->window);
    g_clear_object(&s->window);
    maybe_done(s);
}
static void fail(Probe *s,const char *message) {
    s->failed=TRUE;
    fprintf(stderr,"webkit probe strict=%d: %s\n",s->strict,message);
    close_view(s);
}
static gboolean timeout(gpointer data) {
    Probe *s=data; s->watchdog=0;
    fail(s,"deadline expired");
    /* The process must report failure even if a broken engine keeps refs. */
    g_main_loop_quit(s->loop);
    return G_SOURCE_REMOVE;
}
static void finalized(gpointer data,GObject *object) {
    (void)object; Probe *s=data; s->finalized=TRUE; release(s);
}
static void evaluation_done(GObject *object,GAsyncResult *result,gpointer data) {
    Probe *s=data;
    GError *error=NULL;
    JSCValue *value=webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(object),result,&error);
    if(!s->active) ++s->late;
    if(value) g_object_unref(value);
    if(error) g_error_free(error);
    --s->pending;
    release(s);
}
static void close_with_pending(Probe *s) {
    for(int i=0;i<2;++i) {
        ++s->pending; retain(s);
        webkit_web_view_evaluate_javascript(s->view,"({answer:42})",-1,NULL,NULL,s->cancel,evaluation_done,s);
    }
    close_view(s);
}
static gboolean policy(WebKitWebView *view,WebKitPolicyDecision *decision,WebKitPolicyDecisionType type,gpointer data) {
    (void)view; Probe *s=data; retain(s);
    if(type==WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) {
        WebKitNavigationAction *action=webkit_navigation_policy_decision_get_navigation_action(WEBKIT_NAVIGATION_POLICY_DECISION(decision));
        const char *uri=webkit_uri_request_get_uri(webkit_navigation_action_get_request(action));
        if(uri && g_str_has_prefix(uri,"http:")) {
            ++s->denied; webkit_policy_decision_ignore(decision);
            if(s->strict && s->csp_ready) close_with_pending(s);
            release(s); return TRUE;
        }
    }
    release(s); return FALSE;
}
static void message(WebKitUserContentManager *manager,WebKitJavascriptResult *result,gpointer data) {
    (void)manager; Probe *s=data; retain(s);
    JSCValue *value=webkit_javascript_result_get_js_value(result);
    char *text=jsc_value_is_string(value)?jsc_value_to_string(value):NULL;
    if(!s->active) { g_free(text); release(s); return; }
    const char *uri=webkit_web_view_get_uri(s->view);
    if(!text || strlen(text)>4096 || !uri || strcmp(uri,"about:blank")) fail(s,"message source was not about:blank");
    else if(!strcmp(text,"private-probe-nonce|about:blank|top-ready") && !s->strict) {
        ++s->messages;
        close_with_pending(s);
    } else if(!strcmp(text,"private-probe-nonce|about:blank|csp-ready") && s->strict) {
        ++s->messages; s->csp_ready=TRUE;
        if(s->denied) close_with_pending(s);
    } else fail(s,text);
    g_free(text); release(s);
}
static gboolean load_failed(WebKitWebView *view,WebKitLoadEvent event,const char *uri,GError *error,gpointer data) {
    (void)view;(void)event;(void)uri;
    Probe *s=data;
    if(s->active) fail(s,error->message);
    return TRUE;
}
static void process_failed(WebKitWebView *view,WebKitWebProcessTerminationReason reason,gpointer data) {
    (void)view;(void)reason; fail(data,"web process terminated");
}
static const char private_script[]=
    "addEventListener('message',e=>{if(e.isTrusted&&e.source===window&&window===top&&e.data&&e.data.probe==='native')"
    "window.webkit.messageHandlers.probe.postMessage('private-probe-nonce|'+location.href+'|'+e.data.body)});";
static const char top_document[]=
    "<!doctype html><script>"
    "addEventListener('message',e=>{if(e.data&&e.data.child===true){if(e.data.direct!==false)throw Error('child-native-channel');"
    "window.postMessage({probe:'native',body:'top-ready'},'*')}});"
    "dispatchEvent(new MessageEvent('message',{data:{probe:'native',body:'synthetic-forgery'},source:window}));"
    "const f=document.createElement('iframe');"
    "f.src='data:text/html,'+encodeURIComponent(`<script>"
    "let direct=false;try{window.webkit.messageHandlers.probe.postMessage('child-native');direct=true}catch{};"
    "parent.postMessage({probe:'native',body:'child-forgery'},'*');"
    "parent.postMessage({child:true,direct},'*')<`+'/script>');"
    "document.documentElement.append(f);</script>";
static char *strict_document(unsigned port) {
    return g_strdup_printf(
        "<!doctype html><script>"
        "let seen=new Set();addEventListener('securitypolicyviolation',e=>{seen.add(e.effectiveDirective);"
        "if(['connect-src','frame-src','worker-src','img-src'].every(x=>seen.has(x)))"
        "postMessage({probe:'native',body:'csp-ready'},'*')});"
        "fetch('http://127.0.0.1:%u/fetch').catch(()=>{});"
        "let img=new Image;img.src='http://127.0.0.1:%u/image';"
        "let f=document.createElement('iframe');f.src='http://127.0.0.1:%u/frame';document.documentElement.append(f);"
        "try{new Worker(URL.createObjectURL(new Blob(['postMessage(1)'],{type:'text/javascript'})))}catch{}"
        "location.href='http://127.0.0.1:%u/navigation';"
        "</script>",port,port,port,port);
}
static int run(Server *server,gboolean strict) {
    Probe s={.owner=g_thread_self(),.server=server,.refs=1,.strict=strict,.active=TRUE};
    s.loop=g_main_loop_new(NULL,FALSE);
    s.context=webkit_web_context_new_ephemeral();
    s.manager=webkit_user_content_manager_new();
    s.cancel=g_cancellable_new();
    g_signal_connect(s.manager,"script-message-received::probe",G_CALLBACK(message),&s);
    if(!webkit_user_content_manager_register_script_message_handler_in_world(s.manager,"probe","private-probe-world")) return 1;
    WebKitUserScript *script=webkit_user_script_new_for_world(private_script,WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,"private-probe-world",NULL,NULL);
    webkit_user_content_manager_add_script(s.manager,script); webkit_user_script_unref(script);
    const char *csp=strict?
        "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; img-src data: blob:; connect-src 'none'; frame-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'":
        "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; frame-src data:; connect-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'";
    s.view=WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW,"web-context",s.context,"user-content-manager",s.manager,"default-content-security-policy",csp,NULL));
    g_object_ref_sink(s.view);
    retain(&s); g_object_weak_ref(G_OBJECT(s.view),finalized,&s);
    s.window=gtk_window_new(GTK_WINDOW_TOPLEVEL); g_object_ref_sink(s.window);
    gtk_container_add(GTK_CONTAINER(s.window),GTK_WIDGET(s.view));
    gtk_widget_show(GTK_WIDGET(s.view)); gtk_widget_realize(s.window);
    g_signal_connect(s.view,"decide-policy",G_CALLBACK(policy),&s);
    g_signal_connect(s.view,"load-failed",G_CALLBACK(load_failed),&s);
    g_signal_connect(s.view,"web-process-terminated",G_CALLBACK(process_failed),&s);
    char *document=strict?strict_document(server->port):NULL;
    webkit_web_view_load_html(s.view,strict?document:top_document,NULL);
    g_free(document);
    s.watchdog=g_timeout_add_seconds(15,timeout,&s);
    g_main_loop_run(s.loop);
    if(s.watchdog) g_source_remove(s.watchdog);
    if(s.active) close_view(&s);
    if(s.pending || !s.finalized || s.refs!=1) { fprintf(stderr,"native late ownership did not drain pending=%u finalized=%d refs=%u\n",s.pending,s.finalized,s.refs); return 1; }
    g_clear_object(&s.cancel); g_clear_object(&s.manager); g_clear_object(&s.context); g_main_loop_unref(s.loop);
    fprintf(stderr,"webkit probe strict=%d: messages=%u denied=%u late-finish=%u finalized=%d HTTP=%d\n",strict,s.messages,s.denied,s.late,s.finalized,atomic_load(&server->requests));
    return s.failed || s.messages!=1 || s.late!=2 || (strict && s.denied==0) || atomic_load(&server->requests)!=0;
}
int main(int argc,char **argv) {
    gtk_init(&argc,&argv);
    Server server;
    if(!server_start(&server)) return 2;
    int result=run(&server,FALSE);
    if(!result) result=run(&server,TRUE);
    server_stop(&server);
    return result;
}
