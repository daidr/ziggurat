#include <webkit2/webkit2.h>
#include <stdio.h>
#include <string.h>

/* Direct SDK diagnostic only. This does not exercise or enable View.find.
 * Issued sequence numbers are test records, never SDK request identities. */
typedef enum Mode { ORDERED, RAPID, FINISH, NAVIGATE, CLOSE_PENDING } Mode;
typedef struct Probe Probe;
typedef struct Weak { Probe *probe; const char *name; gboolean finalized; } Weak;
struct Probe {
    GThread *owner;
    GMainLoop *loop;
    GtkWidget *window;
    WebKitWebContext *context;
    WebKitWebView *view;
    WebKitFindController *controller;
    Weak weak[4];
    Mode mode;
    guint drive,settle,watchdog;
    unsigned stage,issued,found,failed_text,counted,loads,weak_count,signals,after_close;
    gboolean failed,closing,done,have_new_result,extra_released,awaiting;
};
static const char page[]=
    "<!doctype html><meta http-equiv='Content-Security-Policy' content=\"default-src 'none';style-src 'unsafe-inline'\">"
    "<style>body{font-size:20px}</style><p>needle needlework needle NEEDLE</p>"
    "<p>alpha alpha beta beta beta</p><p>caf\303\251 caf\303\251</p>";
static const char next_page[]=
    "<!doctype html><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'\">"
    "<p>gamma gamma gamma gamma</p>";
static gboolean advance(gpointer);
static void schedule(Probe *s) { if (!s->drive) s->drive=g_idle_add(advance,s); }
static void fail(Probe *s,const char *why) {
    s->failed=TRUE;
    fprintf(stderr,"find_probe failure mode=%d stage=%u reason=%s\n",s->mode,s->stage,why);
    schedule(s);
}
static void issued(Probe *s,const char *action,const char *term) {
    g_assert(s->owner==g_thread_self());
    fprintf(stderr,"find_probe issued=%u action=%s term=%s controller=%p stage=%u note=test-sequence-not-sdk-id\n",
        ++s->issued,action,term?term:"(current)",(void *)s->controller,s->stage);
}
static void search(Probe *s,const char *term,guint32 flags) {
    issued(s,"search",term);
    webkit_find_controller_search(s->controller,term,flags,1024);
}
static void finish(Probe *s) {
    issued(s,"finish-no-terminal",NULL);
    webkit_find_controller_search_finish(s->controller);
}
static gboolean settled(gpointer data) {
    Probe *s=data;s->settle=0;
    fprintf(stderr,"find_probe diagnostic-window-ended signals=%u found=%u failed=%u counted=%u note=no-absence-or-latency-guarantee\n",
        s->signals,s->found,s->failed_text,s->counted);
    if ((s->mode==FINISH || s->mode==NAVIGATE) && !s->have_new_result) fail(s,"new query result absent in diagnostic window");
    s->done=TRUE;schedule(s);return G_SOURCE_REMOVE;
}
static void settle(Probe *s) { if (!s->settle) s->settle=g_timeout_add(500,settled,s); }
static void observe(Probe *s,const char *name,guint count) {
    g_assert(s->owner==g_thread_self());
    ++s->signals;if (s->closing) ++s->after_close;
    const char *current=webkit_find_controller_get_search_text(s->controller);
    fprintf(stderr,"find_probe signal=%s count=%u current_getter=%s options=%u issued_so_far=%u controller=%p stage=%u closing=%d\n",
        name,count,current?current:"(null)",webkit_find_controller_get_options(s->controller),s->issued,(void *)s->controller,s->stage,s->closing);
    if (s->signals>32) fail(s,"bounded diagnostic signal storage exceeded");
}
static void found(WebKitFindController *sender,guint count,gpointer data) {
    Probe *s=data;g_assert(sender==s->controller);++s->found;observe(s,"found",count);
    if (s->mode==ORDERED) {
        const guint expected[]={3,0,0,0,4,2,0};
        if (s->stage>=7 || s->stage==3 || s->stage==6) return fail(s,"unexpected ordered found");
        if (expected[s->stage] && expected[s->stage]!=count) return fail(s,"wrong static page match count");
        s->awaiting=FALSE;++s->stage;schedule(s);
    } else if (s->mode==RAPID) {
        if (s->signals>3) fail(s,"more terminals than issued rapid search commands");
        if (s->signals==3) settle(s);
    } else if ((s->mode==FINISH && count==3) || (s->mode==NAVIGATE && s->loads==2 && count==4)) s->have_new_result=TRUE;
}
static void not_found(WebKitFindController *sender,gpointer data) {
    Probe *s=data;g_assert(sender==s->controller);++s->failed_text;observe(s,"failed",0);
    if (s->mode==ORDERED) {
        if (s->stage!=3) return fail(s,"unexpected ordered failed");
        s->awaiting=FALSE;++s->stage;schedule(s);
    } else if (s->mode==RAPID) {
        /* Overlapping no-wrap requests share engine selection state. A real
         * failed signal is an observation, not evidence that text was absent. */
        if (s->signals>3) fail(s,"more terminals than issued rapid search commands");
        if (s->signals==3) settle(s);
    }
}
static void counted(WebKitFindController *sender,guint count,gpointer data) {
    Probe *s=data;g_assert(sender==s->controller);++s->counted;observe(s,"counted",count);
    if (s->mode!=ORDERED || s->stage!=6 || count!=2) return fail(s,"unexpected count result");
    s->awaiting=FALSE;++s->stage;schedule(s);
}
static void finalized(gpointer data,GObject *object) {
    Weak *weak=data;Probe *s=weak->probe;
    g_assert(s->owner==g_thread_self() && !weak->finalized);
    weak->finalized=TRUE;++s->weak_count;
    fprintf(stderr,"find_probe weak-finalized object=%s pointer=%p count=%u extra_released=%d\n",weak->name,(void *)object,s->weak_count,s->extra_released);
    if (!strcmp(weak->name,"controller") && !s->extra_released) fail(s,"controller finalized while explicit extra ref held");
    schedule(s);
}
static gboolean release_extra(gpointer data) {
    Probe *s=data;
    g_assert(s->closing && s->controller && !s->extra_released);
    WebKitFindController *controller=s->controller;s->controller=NULL;s->extra_released=TRUE;
    fprintf(stderr,"find_probe release-explicit-controller-ref pointer=%p weak_before_release=%d\n",(void *)controller,s->weak[1].finalized);
    g_object_unref(controller);schedule(s);return G_SOURCE_REMOVE;
}
static void close_probe(Probe *s) {
    if (s->closing) return;
    s->closing=TRUE;
    if (s->settle) { g_source_remove(s->settle);s->settle=0; }
    /* Disconnect before releasing the Gtk/WebView tree. Its later results must
     * not retain this test's signal callback context. Keep an explicit native
     * controller ref through a separate main-loop turn to observe real refs. */
    g_signal_handlers_disconnect_by_data(s->controller,s);
    g_signal_handlers_disconnect_by_data(s->view,s);
    fprintf(stderr,"find_probe close-disconnected controller=%p issued=%u signals=%u\n",(void *)s->controller,s->issued,s->signals);
    gtk_widget_destroy(s->window);s->window=NULL;
    WebKitWebView *view=s->view;s->view=NULL;g_object_unref(view);
    g_clear_object(&s->context);
    g_idle_add(release_extra,s);
}
static gboolean advance(gpointer data) {
    Probe *s=data;s->drive=0;
    if (s->failed || s->done) close_probe(s);
    if (s->closing) {
        if (s->weak_count==4 && s->extra_released) g_main_loop_quit(s->loop);
        return G_SOURCE_REMOVE;
    }
    if (s->loads!=1 && !(s->mode==NAVIGATE && s->loads==2)) return G_SOURCE_REMOVE;
    if (s->mode==ORDERED) {
        if (s->awaiting) return G_SOURCE_REMOVE;
        s->awaiting=TRUE;
        switch (s->stage) {
        case 0: search(s,"needle",WEBKIT_FIND_OPTIONS_WRAP_AROUND);break;
        case 1: issued(s,"next",NULL);webkit_find_controller_search_next(s->controller);break;
        case 2: issued(s,"previous",NULL);webkit_find_controller_search_previous(s->controller);break;
        case 3: search(s,"not-present",WEBKIT_FIND_OPTIONS_WRAP_AROUND);break;
        case 4: search(s,"needle",WEBKIT_FIND_OPTIONS_WRAP_AROUND|WEBKIT_FIND_OPTIONS_CASE_INSENSITIVE);break;
        case 5: search(s,"caf\303\251",WEBKIT_FIND_OPTIONS_WRAP_AROUND);break;
        case 6: issued(s,"count", "alpha");webkit_find_controller_count_matches(s->controller,"alpha",0,1024);break;
        case 7: finish(s);++s->stage;settle(s);break;
        case 8:break;
        default:fail(s,"invalid ordered stage");break;
        }
    } else if (s->stage==0) {
        s->stage=1;
        if (s->mode==RAPID) {
            search(s,"alpha",0);search(s,"beta",0);search(s,"alpha",0);
        } else if (s->mode==FINISH) {
            search(s,"alpha",0);finish(s);search(s,"beta",0);settle(s);
        } else if (s->mode==NAVIGATE) {
            search(s,"alpha",0);finish(s);
            fprintf(stderr,"find_probe issued-navigation new-self-owned-html same-controller=%p\n",(void *)s->controller);
            webkit_web_view_load_html(s->view,next_page,"about:blank");
        } else {
            search(s,"alpha",0);s->done=TRUE;close_probe(s);
        }
    } else if (s->mode==NAVIGATE && s->loads==2 && s->stage==1) {
        s->stage=2;search(s,"gamma",0);settle(s);
    }
    return G_SOURCE_REMOVE;
}
static void loaded(WebKitWebView *view,WebKitLoadEvent event,gpointer data) {
    Probe *s=data;g_assert(view==s->view);
    fprintf(stderr,"find_probe load-event=%d finished=%u controller=%p\n",event,s->loads,(void *)s->controller);
    if (event==WEBKIT_LOAD_FINISHED) { ++s->loads;schedule(s); }
}
static gboolean load_failed(WebKitWebView *view,WebKitLoadEvent event,const char *uri,GError *error,gpointer data) {
    (void)view;(void)event;(void)uri;
    fprintf(stderr,"find_probe load-error domain=%s code=%d message=%s\n",g_quark_to_string(error->domain),error->code,error->message);
    fail(data,"self-owned HTML failed");return TRUE;
}
static gboolean watchdog(gpointer data) {
    Probe *s=data;s->watchdog=0;
    fail(s,"diagnostic watchdog expired; no guaranteed terminal inferred");
    close_probe(s);g_main_loop_quit(s->loop);return G_SOURCE_REMOVE;
}
int main(int argc,char **argv) {
    if (argc!=2) return 2;
    Probe s={0};
    const char *modes[]={"ordered","rapid","finish","navigate","close-pending"};
    gboolean selected=FALSE;
    for (unsigned i=0;i<5;++i) if (!strcmp(argv[1],modes[i])) { s.mode=(Mode)i;selected=TRUE; }
    if (!selected) return 2;
    gtk_init(NULL,NULL);s.owner=g_thread_self();s.loop=g_main_loop_new(NULL,FALSE);
    fprintf(stderr,"find_probe standalone-sdk mode=%s loaded-version=%u.%u.%u no-framework-capability-claim=1\n",argv[1],webkit_get_major_version(),webkit_get_minor_version(),webkit_get_micro_version());
    s.context=webkit_web_context_new_ephemeral();
    s.view=WEBKIT_WEB_VIEW(webkit_web_view_new_with_context(s.context));g_object_ref_sink(s.view);
    s.controller=g_object_ref(webkit_web_view_get_find_controller(s.view));
    s.window=gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_container_add(GTK_CONTAINER(s.window),GTK_WIDGET(s.view));gtk_widget_realize(s.window);
    GObject *objects[]={G_OBJECT(s.view),G_OBJECT(s.controller),G_OBJECT(s.context),G_OBJECT(s.window)};
    const char *names[]={"view","controller","context","window"};
    for (unsigned i=0;i<4;++i) { s.weak[i]=(Weak){&s,names[i],FALSE};g_object_weak_ref(objects[i],finalized,&s.weak[i]); }
    g_signal_connect(s.controller,"found-text",G_CALLBACK(found),&s);
    g_signal_connect(s.controller,"failed-to-find-text",G_CALLBACK(not_found),&s);
    g_signal_connect(s.controller,"counted-matches",G_CALLBACK(counted),&s);
    g_signal_connect(s.view,"load-changed",G_CALLBACK(loaded),&s);
    g_signal_connect(s.view,"load-failed",G_CALLBACK(load_failed),&s);
    s.watchdog=g_timeout_add_seconds(20,watchdog,&s);
    webkit_web_view_load_html(s.view,page,"about:blank");
    g_main_loop_run(s.loop);
    if (s.watchdog) g_source_remove(s.watchdog);
    if (s.drive) g_source_remove(s.drive);
    if (s.settle) g_source_remove(s.settle);
    if (s.weak_count!=4 || s.after_close || !s.extra_released) s.failed=TRUE;
    fprintf(stderr,"find_probe end mode=%s issued=%u found=%u failed=%u counted=%u weak=%u after_close=%u result=%s\n",argv[1],s.issued,s.found,s.failed_text,s.counted,s.weak_count,s.after_close,s.failed?"FAIL":"OK");
    /* On an engine leak the process reports failure; no context is freed then
     * reused by another iteration. Every scenario is its own OS process. */
    g_main_loop_unref(s.loop);return s.failed?1:0;
}
