#include <webkit2/webkit2.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#define ZWK_POLICY_ABI 2u

/* Private transport discovery probe. No public backend capability is enabled. */
typedef struct Server {
    int fd; unsigned port,redirect_port;
    pthread_t thread;
    atomic_int stop,total,allowed,head,redirect,custom,post,worker,socket,other;
} Server;
static void send_all(int fd,const char *text,size_t length) {
    while (length) { ssize_t n=send(fd,text,length,MSG_NOSIGNAL); if (n<=0) return; text+=n; length-=(size_t)n; }
}
static void *serve(void *data) {
    Server *s=data;
    while (!atomic_load(&s->stop)) {
        int fd=accept(s->fd,NULL,NULL);
        if (fd<0) break;
        struct timeval timeout={.tv_sec=1};
        (void)setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
        (void)setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
        char request[8192]; ssize_t received=recv(fd,request,sizeof(request)-1,0);
        if (received>0) {
            request[received]=0; char method[16]={0},path[256]={0};
            (void)sscanf(request,"%15s %255s",method,path); atomic_fetch_add(&s->total,1);
            if (!strcmp(path,"/allowed")) atomic_fetch_add(&s->allowed,1);
            else if (!strcmp(path,"/head")) atomic_fetch_add(&s->head,1);
            else if (!strcmp(path,"/redirect")) atomic_fetch_add(&s->redirect,1);
            else if (!strcmp(path,"/custom") && strcmp(method,"OPTIONS")) atomic_fetch_add(&s->custom,1);
            else if (!strcmp(path,"/post")) atomic_fetch_add(&s->post,1);
            else if (!strcmp(path,"/worker")) atomic_fetch_add(&s->worker,1);
            else if (!strcmp(path,"/socket")) atomic_fetch_add(&s->socket,1);
            else if (strcmp(path,"/custom") || strcmp(method,"OPTIONS")) atomic_fetch_add(&s->other,1);
            char reply[1024];
            int n;
            if (!strcmp(path,"/redirect")) n=snprintf(reply,sizeof(reply),"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:%u/redirect-target\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",s->redirect_port);
            else n=snprintf(reply,sizeof(reply),"HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Not-X-Custom\r\nAccess-Control-Allow-Methods: GET, HEAD, POST, OPTIONS\r\nCache-Control: no-store\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\n%s",!strcmp(method,"HEAD")?"":"ok");
            if (n>0 && (size_t)n<sizeof(reply)) send_all(fd,reply,(size_t)n);
        }
        close(fd);
    }
    return NULL;
}
static gboolean server_start(Server *s) {
    memset(s,0,sizeof(*s)); s->fd=-1;
    s->fd=socket(AF_INET,SOCK_STREAM,0);
    struct sockaddr_in address={.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    if (s->fd<0 || bind(s->fd,(struct sockaddr *)&address,sizeof(address)) || listen(s->fd,16)) return FALSE;
    socklen_t size=sizeof(address);
    if (getsockname(s->fd,(struct sockaddr *)&address,&size)) return FALSE;
    s->port=ntohs(address.sin_port);
    return pthread_create(&s->thread,NULL,serve,s)==0;
}
static void server_stop(Server *s) {
    atomic_store(&s->stop,1); shutdown(s->fd,SHUT_RDWR); close(s->fd); pthread_join(s->thread,NULL);
}
typedef struct Runner Runner;
typedef struct Probe {
    Runner *runner;
    WebKitWebContext *context;
    WebKitUserContentManager *manager;
    WebKitWebView *view;
    GtkWidget *window;
    guint64 policy_id;
    Server *allowed,*blocked;
    gboolean ready,submitted,closed,finalized,stats,bad;
    guint64 allow_count,deny_count,redirect_count;
    unsigned pending;
} Probe;
struct Runner { GMainLoop *loop; Probe probes[2]; unsigned count; gboolean failed,missing,bad,strict; guint watchdog; };
static void maybe_done(Runner *s) {
    for (unsigned i=0;i<s->count;++i) if (!s->probes[i].closed || !s->probes[i].finalized || s->probes[i].pending) return;
    g_main_loop_quit(s->loop);
}
static void close_probe(Probe *s) {
    if (s->closed) return;
    s->closed=TRUE;
    g_signal_handlers_disconnect_by_data(s->view,s);
    g_signal_handlers_disconnect_by_data(s->manager,s);
    gtk_widget_destroy(s->window); g_clear_object(&s->window);
    g_clear_object(&s->view); maybe_done(s->runner);
}
static void fail(Probe *s,const char *message) {
    fprintf(stderr,"request probe id=%llu: %s\n",(unsigned long long)s->policy_id,message);
    s->runner->failed=TRUE;
    for (unsigned i=0;i<s->runner->count;++i) close_probe(&s->runner->probes[i]);
}
static void finalized(gpointer data,GObject *object) { (void)object; Probe *s=data; s->finalized=TRUE; maybe_done(s->runner); }
static gboolean timeout(gpointer data) {
    Runner *s=data; s->watchdog=0;
    if (!s->missing) { s->failed=TRUE; fprintf(stderr,"request probe deadline expired\n"); }
    for (unsigned i=0;i<s->count;++i) close_probe(&s->probes[i]);
    if (s->failed) g_main_loop_quit(s->loop);
    return G_SOURCE_REMOVE;
}
static void stats_done(GObject *object,GAsyncResult *result,gpointer data) {
    Probe *s=data; GError *error=NULL;
    WebKitUserMessage *reply=webkit_web_view_send_message_to_page_finish(WEBKIT_WEB_VIEW(object),result,&error);
    --s->pending;
    if (!reply || error || strcmp(webkit_user_message_get_name(reply),"ziggurat-request-policy-stats")) fail(s,error?error->message:"invalid stats reply");
    else {
        GVariant *value=webkit_user_message_get_parameters(reply);
        if (!value || !g_variant_is_of_type(value,G_VARIANT_TYPE("(ttt)"))) fail(s,"invalid stats data");
        else { g_variant_get(value,"(ttt)",&s->allow_count,&s->deny_count,&s->redirect_count); s->stats=TRUE; close_probe(s); }
    }
    g_clear_object(&reply); g_clear_error(&error); maybe_done(s->runner);
}
static void page_done(WebKitUserContentManager *manager,WebKitJavascriptResult *result,gpointer data) {
    (void)manager; Probe *s=data;
    JSCValue *value=webkit_javascript_result_get_js_value(result);
    char *text=jsc_value_to_string(value);
    if (!text || strcmp(text,"done")) fail(s,text?text:"invalid completion");
    else { ++s->pending; webkit_web_view_send_message_to_page(s->view,webkit_user_message_new("ziggurat-request-policy-stats",NULL),NULL,stats_done,s); }
    g_free(text);
}
static void submit_document(Probe *s) {
    if (s->submitted || s->closed) { fail(s,"duplicate/closed submission"); return; }
    s->submitted=TRUE;
    char *html=g_strdup_printf("<!doctype html><script>"
        "const a='http://127.0.0.1:%u',b='http://127.0.0.1:%u';"
        "const tasks=[fetch(a+'/allowed'),fetch(a+'/head',{method:'HEAD'}),fetch(a+'/redirect'),"
        "fetch(a+'/custom',{headers:{'Not-X-Custom':'denied'}}),fetch(a+'/post',{method:'POST'}),fetch(b+'/fetch')];"
        "navigator.sendBeacon(b+'/beacon','denied');"
        "tasks.push(new Promise(resolve=>{const i=new Image;i.onload=i.onerror=resolve;i.src=b+'/image'}));"
        "const frame=document.createElement('iframe');frame.name='sink';frame.src=b+'/frame';document.documentElement.append(frame);"
        "const form=document.createElement('form');form.method='POST';form.action=b+'/form';form.target='sink';document.documentElement.append(form);form.submit();"
        "tasks.push(new Promise(resolve=>{try{const socket=new WebSocket('ws://127.0.0.1:%u/socket');"
        "socket.onerror=socket.onopen=()=>{socket.close();resolve()};setTimeout(()=>{socket.close();resolve()},600)}catch{resolve()}}));"
        "tasks.push(new Promise(resolve=>{try{const worker=new Worker(URL.createObjectURL(new Blob(["
        "'fetch(\"'+b+'/worker\").then(()=>postMessage(1),()=>postMessage(0))'],{type:'text/javascript'})));"
        "worker.onmessage=worker.onerror=()=>{worker.terminate();resolve()};setTimeout(()=>{worker.terminate();resolve()},900)}catch{resolve()}}));"
        "Promise.allSettled(tasks).then(()=>setTimeout(()=>webkit.messageHandlers.done.postMessage('done'),50));"
        "</script>",s->allowed->port,s->blocked->port,s->blocked->port);
    webkit_web_view_load_html(s->view,html,NULL); g_free(html);
}
static gboolean host_message(WebKitWebView *view,WebKitUserMessage *message,gpointer data) {
    Probe *s=data;
    if (strcmp(webkit_user_message_get_name(message),"ziggurat-request-policy-ready")) return FALSE;
    GVariant *value=webkit_user_message_get_parameters(message); guint abi=0; guint64 id=0,page_id=0; gboolean valid=FALSE;
    if (!value || !g_variant_is_of_type(value,G_VARIANT_TYPE("(uttb)"))) { fail(s,"invalid handshake data"); return TRUE; }
    g_variant_get(value,"(uttb)",&abi,&id,&page_id,&valid);
    if (abi!=ZWK_POLICY_ABI || page_id!=webkit_web_view_get_page_id(view) || s->ready) fail(s,"handshake identity mismatch");
    else if (s->bad) { if (valid || id) fail(s,"bad ABI accepted"); else { s->ready=TRUE; close_probe(s); } }
    else if (!valid || id!=s->policy_id) fail(s,"policy identity mismatch");
    else { s->ready=TRUE; submit_document(s); }
    return TRUE;
}
static GVariant *config(Probe *s) {
    GVariantBuilder origins,headers;
    g_variant_builder_init(&origins,G_VARIANT_TYPE("a(sua(sbs)ay)"));
    g_variant_builder_init(&headers,G_VARIANT_TYPE("a(sbs)"));
    char origin[64]; g_snprintf(origin,sizeof(origin),"http://127.0.0.1:%u",s->allowed->port);
    g_variant_builder_add(&origins,"(su@a(sbs)@ay)",origin,67u,g_variant_builder_end(&headers),g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE,NULL,0,1));
    return g_variant_ref_sink(g_variant_new("(utb@a(sua(sbs)ay))",s->bad?99u:ZWK_POLICY_ABI,s->policy_id,TRUE,g_variant_builder_end(&origins)));
}
static gboolean run(const char *directory,Server *a,Server *b,gboolean missing,gboolean bad,gboolean strict) {
    Runner s={.count=(missing || bad)?1:2,.missing=missing,.bad=bad,.strict=strict};
    s.loop=g_main_loop_new(NULL,FALSE);
    for (unsigned i=0;i<s.count;++i) {
        Probe *p=&s.probes[i]; p->runner=&s; p->policy_id=101+i; p->bad=bad;
        p->allowed=i?b:a; p->blocked=i?a:b;
        p->context=webkit_web_context_new_ephemeral(); p->manager=webkit_user_content_manager_new();
        webkit_web_context_set_web_extensions_directory(p->context,directory);
        GVariant *value=config(p); webkit_web_context_set_web_extensions_initialization_user_data(p->context,value); g_variant_unref(value);
        const char *csp=strict?
            "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; connect-src http://127.0.0.1:*; img-src http://127.0.0.1:*; frame-src http://127.0.0.1:*; worker-src 'none'; form-action http://127.0.0.1:*":
            "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; connect-src http://127.0.0.1:* ws://127.0.0.1:*; img-src http://127.0.0.1:*; frame-src http://127.0.0.1:*; worker-src blob:; form-action http://127.0.0.1:*";
        p->view=WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW,"web-context",p->context,"user-content-manager",p->manager,
            "default-content-security-policy",csp,NULL));
        g_object_ref_sink(p->view); g_object_weak_ref(G_OBJECT(p->view),finalized,p);
        g_signal_connect(p->view,"user-message-received",G_CALLBACK(host_message),p);
        g_signal_connect(p->manager,"script-message-received::done",G_CALLBACK(page_done),p);
        if (!webkit_user_content_manager_register_script_message_handler(p->manager,"done")) return FALSE;
        p->window=gtk_window_new(GTK_WINDOW_TOPLEVEL); g_object_ref_sink(p->window);
        gtk_container_add(GTK_CONTAINER(p->window),GTK_WIDGET(p->view)); gtk_widget_show(GTK_WIDGET(p->view)); gtk_widget_realize(p->window);
        webkit_web_view_load_uri(p->view,"about:blank");
    }
    s.watchdog=g_timeout_add(missing?1000:15000,timeout,&s);
    g_main_loop_run(s.loop);
    if (s.watchdog) g_source_remove(s.watchdog);
    gboolean success=!s.failed;
    for (unsigned i=0;i<s.count;++i) {
        Probe *p=&s.probes[i];
        if (!p->closed || !p->finalized || p->pending || (missing?p->ready:!p->ready) || ((missing || bad)?p->submitted:!p->stats)) success=FALSE;
        if (!missing && !bad && (p->allow_count<3 || p->deny_count<6 || !p->redirect_count)) success=FALSE;
        fprintf(stderr,"request extension policy=%llu handshake=%d submitted=%d allow=%llu deny=%llu redirect=%llu finalized=%d\n",(unsigned long long)p->policy_id,p->ready,p->submitted,(unsigned long long)p->allow_count,(unsigned long long)p->deny_count,(unsigned long long)p->redirect_count,p->finalized);
        g_clear_object(&p->manager); g_clear_object(&p->context);
    }
    g_main_loop_unref(s.loop); return success;
}
int main(int argc,char **argv) {
    gtk_init(&argc,&argv); if (argc!=3 && (argc!=4 || strcmp(argv[3],"strict"))) return 2;
    gboolean strict=argc==4;
    Server a,b;
    if (!server_start(&a) || !server_start(&b)) return 2;
    a.redirect_port=b.port; b.redirect_port=a.port;
    gboolean ok=run(argv[2],&a,&b,TRUE,FALSE,strict) && run(argv[1],&a,&b,FALSE,TRUE,strict) && run(argv[1],&a,&b,FALSE,FALSE,strict);
    server_stop(&a); server_stop(&b);
    for (unsigned i=0;i<2;++i) {
        Server *s=i?&b:&a;
        fprintf(stderr,"request server%u total=%d allowed=%d head=%d redirect=%d forbidden-custom=%d forbidden-post=%d worker=%d ws=%d forbidden-other=%d\n",i,atomic_load(&s->total),atomic_load(&s->allowed),atomic_load(&s->head),atomic_load(&s->redirect),atomic_load(&s->custom),atomic_load(&s->post),atomic_load(&s->worker),atomic_load(&s->socket),atomic_load(&s->other));
        if (atomic_load(&s->allowed)!=1 || atomic_load(&s->head)!=1 || atomic_load(&s->redirect)!=1 || atomic_load(&s->custom) || atomic_load(&s->post) || atomic_load(&s->other)) ok=FALSE;
        if (strict && (atomic_load(&s->socket) || atomic_load(&s->worker))) ok=FALSE;
    }
    puts(strict?"Fixed CSP + request extension: HTTP request boundaries and denied worker/WebSocket routes verified; no public remote capability enabled.":"Discovery only: worker/WebSocket observations do not enable a public remote capability.");
    return ok?0:1;
}
