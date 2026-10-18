#include <webkit2/webkit2.h>
#include <stdio.h>
#include <string.h>
#include "../src/platform/linux_content.h"

typedef struct NativeEvent {
    int kind,key,flags; void *context,*window; double x,y,dx,dy;
    uint32_t width,height,scale; const char *text; size_t length,selection;
} NativeEvent;
extern void *zlg_app_create(void *,void (*)(void *),int *);
extern void zlg_app_destroy(void *);
extern NativeWindow *zlg_window_create(void *,int (*)(void *,const NativeEvent *),const char *,uint32_t,uint32_t,uint32_t,uint32_t,NativeWindow *,int,int,int,int *);
extern void *zlg_window_handle(NativeWindow *);
extern uint32_t zlg_resource_count(void);

/* No native toplevel or parking widget is created by this probe. */
typedef struct Probe {
    GMainLoop *loop;
    GtkWidget *view;
    WebKitWebContext *context;
    WebKitUserContentManager *manager;
    guint drive, watchdog;
    unsigned objects, loaded, messages;
    void *app;
    NativeWindow *window;
    ZlgRegionHost *region;
    unsigned parent_closes;
    gboolean evaluating, evaluated, failed, closing, relationships;
} Probe;
static gboolean advance(gpointer);
static void schedule(Probe *s) { if (!s->drive) s->drive=g_idle_add(advance,s); }
static void fail(Probe *s,const char *reason) {
    fprintf(stderr,"unparented session failure: %s\n",reason);
    s->failed=TRUE; schedule(s);
}
static void finalized(gpointer data,GObject *object) {
    (void)object; Probe *s=data; g_assert(s->objects); --s->objects; schedule(s);
}
static void track(Probe *s,GObject *object) { ++s->objects; g_object_weak_ref(object,finalized,s); }
static void dispatch(void *unused) { (void)unused; }
static int native_event(void *data,const NativeEvent *event) {
    Probe *s=data;
    if (event->kind==11) {
        ++s->parent_closes;
        s->window=NULL;
        /* This is native-only early withdrawal. Ordinary detach follows the
         * original mount call's return, never the destruction notification. */
        if (s->region) zlg_region_parent_destroying(s->region);
    }
    return 0;
}
static void close_parent(GtkWidget *child,GtkWidget *previous,gpointer data) {
    (void)previous; Probe *s=data;
    if (gtk_widget_get_parent(child) && s->window)
        gtk_widget_destroy(zlg_window_handle(s->window));
}
static void close_when_unparented(GtkWidget *child,GtkWidget *previous,gpointer data) {
    (void)child; (void)previous; Probe *s=data;
    if (s->window) gtk_widget_destroy(zlg_window_handle(s->window));
}
static void close_when_added(GtkContainer *parent,GtkWidget *child,gpointer data) {
    (void)child; (void)data; gtk_widget_destroy(GTK_WIDGET(parent));
}
static gboolean relationships(Probe *s) {
    int error=0;
    s->app=zlg_app_create(NULL,dispatch,&error);
    if (!s->app || error) { fail(s,"App construction failed"); return FALSE; }
    const unsigned baseline=zlg_resource_count();
    for (unsigned mode=0;mode<2;++mode) {
        s->window=zlg_window_create(s,native_event,"session first layer",640,480,0,0,NULL,0,0,1,&error);
        if (!s->window || error) { fail(s,"first Window construction failed"); return FALSE; }
        GtkWidget *window=g_object_ref(zlg_window_handle(s->window));
        GtkWidget *area=g_object_ref(gtk_bin_get_child(GTK_BIN(window)));
        gulong handler=mode==0?g_signal_connect(area,"parent-set",G_CALLBACK(close_when_unparented),s):
            g_signal_connect(window,"add",G_CALLBACK(close_when_added),s);
        int result=zlg_region_prepare(s->window,s->view,&s->region);
        if (g_signal_handler_is_connected(mode==0?area:window,handler))
            g_signal_handler_disconnect(mode==0?area:window,handler);
        g_object_unref(area); g_object_unref(window);
        if (result!=ZLG_CONTENT_CLOSED || s->region || s->window ||
            gtk_widget_get_parent(s->view) || gtk_widget_in_destruction(s->view) ||
            zlg_region_count() || zlg_resource_count()!=baseline) {
            fail(s,"first layer close changed the unparented page or leaked"); return FALSE;
        }
    }
    s->parent_closes=0;
    for (unsigned i=0;i<12;++i) {
        s->window=zlg_window_create(s,native_event,"session provisional host",640,480,0,0,NULL,0,0,1,&error);
        if (!s->window || error) { fail(s,"Window construction failed"); return FALSE; }
        GtkWidget *peer=gtk_drawing_area_new(); g_object_ref_sink(peer);
        ZlgRegionHost *peer_host=NULL;
        if (zlg_region_attach(s->window,peer,&peer_host)!=ZLG_CONTENT_OK) { fail(s,"peer attach failed"); return FALSE; }
        if (zlg_region_prepare(s->window,s->view,&s->region)!=ZLG_CONTENT_OK ||
            zlg_region_mount(s->region)!=ZLG_CONTENT_OK) { fail(s,"ordinary mount failed"); return FALSE; }
        GtkWidget *shared=gtk_widget_get_parent(peer);
        zlg_region_detach(s->region); s->region=NULL;
        if (gtk_widget_get_parent(s->view) || gtk_widget_get_parent(peer)!=shared ||
            gtk_widget_in_destruction(peer) || zlg_region_count()!=2) {
            fail(s,"ordinary park disturbed a peer"); return FALSE;
        }
        if (zlg_region_prepare(s->window,s->view,&s->region)!=ZLG_CONTENT_OK || !s->region || gtk_widget_get_parent(s->view)) {
            fail(s,"provisional prepare parented the widget"); return FALSE;
        }
        gulong handler=g_signal_connect(s->view,"parent-set",G_CALLBACK(close_parent),s);
        int result=zlg_region_mount(s->region);
        g_signal_handler_disconnect(s->view,handler);
        if (result!=ZLG_CONTENT_CLOSED || s->window || s->parent_closes!=i+1 ||
            !gtk_widget_get_parent(s->view) || gtk_widget_in_destruction(s->view)) {
            fail(s,"early withdrawal did not preserve the provisional widget"); return FALSE;
        }
        zlg_region_detach(s->region); s->region=NULL;
        if (gtk_widget_get_parent(peer)!=shared || gtk_widget_in_destruction(peer) || zlg_region_count()!=2) {
            fail(s,"early layer did not retain its peer until ordinary detach"); return FALSE;
        }
        zlg_region_detach(peer_host);
        gtk_widget_destroy(peer); g_object_unref(peer);
        if (zlg_region_count() || zlg_resource_count()!=baseline) {
            fail(s,"provisional physical resources leaked"); return FALSE;
        }
    }
    zlg_app_destroy(s->app); s->app=NULL;
    if (zlg_resource_count()) { fail(s,"native App resources leaked"); return FALSE; }
    GtkAllocation size={0,0,731,419}; gtk_widget_show(s->view); gtk_widget_size_allocate(s->view,&size);
    s->relationships=TRUE; s->evaluated=FALSE;
    return TRUE;
}
static void loaded(WebKitWebView *view,WebKitLoadEvent event,gpointer data) {
    (void)view; Probe *s=data;
    if (event==WEBKIT_LOAD_FINISHED) { ++s->loaded; schedule(s); }
}
static gboolean load_failed(WebKitWebView *view,WebKitLoadEvent event,const char *uri,GError *error,gpointer data) {
    (void)view; (void)event; (void)uri; fail(data,error->message); return TRUE;
}
static void message(WebKitUserContentManager *manager,WebKitJavascriptResult *result,gpointer data) {
    (void)manager; Probe *s=data;
    char *value=jsc_value_to_string(webkit_javascript_result_get_js_value(result));
    if (g_strcmp0(value,"unparented-commit")) fail(s,"wrong native IPC result");
    else ++s->messages;
    g_free(value); schedule(s);
}
static void evaluated(GObject *view,GAsyncResult *result,gpointer data) {
    Probe *s=data; GError *error=NULL;
    JSCValue *value=webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(view),result,&error);
    s->evaluating=FALSE; s->evaluated=TRUE;
    if (error || !value) fail(s,error?error->message:"no evaluation result");
    else {
        char *text=jsc_value_to_string(value);
        fprintf(stderr,"unparented session actual=%s allocated=%dx%d scale=%d realized=%d mapped=%d\n",text,
            gtk_widget_get_allocated_width(s->view),gtk_widget_get_allocated_height(s->view),
            gtk_widget_get_scale_factor(s->view),gtk_widget_get_realized(s->view),gtk_widget_get_mapped(s->view));
        if (g_strcmp0(text,"true|731|419|731|419|17")) fail(s,"DOM or exact unparented viewport differs");
        g_free(text);
    }
    g_clear_error(&error); if (value) g_object_unref(value); schedule(s);
}
static gboolean advance(gpointer data) {
    Probe *s=data; s->drive=0;
    if (!s->failed && s->evaluated && s->messages==1 && !s->relationships) {
        if (!relationships(s)) return G_SOURCE_REMOVE;
    }
    if (s->failed || (s->evaluated && s->messages==1)) {
        if (!s->closing) {
            s->closing=TRUE;
            g_signal_handlers_disconnect_by_data(s->view,s);
            g_signal_handlers_disconnect_by_data(s->manager,s);
            gtk_widget_destroy(s->view); g_clear_object(&s->view);
            g_clear_object(&s->manager); g_clear_object(&s->context);
        }
        if (!s->objects) g_main_loop_quit(s->loop);
        return G_SOURCE_REMOVE;
    }
    if (s->loaded && !s->evaluating && !s->evaluated) {
        s->evaluating=TRUE;
        webkit_web_view_evaluate_javascript(WEBKIT_WEB_VIEW(s->view),
            "[!!window.token,innerWidth,innerHeight,document.documentElement.clientWidth,document.documentElement.clientHeight,token].join('|')",
            -1,NULL,NULL,NULL,evaluated,s);
    }
    return G_SOURCE_REMOVE;
}
static gboolean timed_out(gpointer data) {
    Probe *s=data; s->watchdog=0;
    fprintf(stderr,"unparented timeout loaded=%u messages=%u objects=%u\n",s->loaded,s->messages,s->objects);
    s->failed=TRUE; g_main_loop_quit(s->loop); return G_SOURCE_REMOVE;
}
int main(void) {
    if (!gtk_init_check(NULL,NULL)) return 2;
    Probe s={0}; s.loop=g_main_loop_new(NULL,FALSE);
    s.context=webkit_web_context_new_ephemeral(); track(&s,G_OBJECT(s.context));
    s.manager=webkit_user_content_manager_new(); track(&s,G_OBJECT(s.manager));
    if (!webkit_user_content_manager_register_script_message_handler(s.manager,"probe")) return 3;
    s.view=g_object_new(WEBKIT_TYPE_WEB_VIEW,"web-context",s.context,"user-content-manager",s.manager,NULL);
    g_object_ref_sink(s.view); track(&s,G_OBJECT(s.view));
    g_signal_connect(s.view,"load-changed",G_CALLBACK(loaded),&s);
    g_signal_connect(s.view,"load-failed",G_CALLBACK(load_failed),&s);
    g_signal_connect(s.manager,"script-message-received::probe",G_CALLBACK(message),&s);
    gtk_widget_show(s.view);
    GtkAllocation size={0,0,731,419}; gtk_widget_size_allocate(s.view,&size);
    g_assert(!gtk_widget_get_parent(s.view));
    GList *toplevels=gtk_window_list_toplevels(); g_assert(toplevels==NULL); g_list_free(toplevels);
    s.watchdog=g_timeout_add_seconds(20,timed_out,&s);
    webkit_web_view_load_html(WEBKIT_WEB_VIEW(s.view),
        "<!doctype html><style>html,body{margin:0}</style><script>window.token=17;webkit.messageHandlers.probe.postMessage('unparented-commit')</script>",
        "about:blank");
    g_main_loop_run(s.loop);
    if (s.watchdog) g_source_remove(s.watchdog);
    if (s.drive) g_source_remove(s.drive);
    g_main_loop_unref(s.loop);
    if (!s.failed) puts("unparented load/DOM/IPC, exact viewport, first-layer close and 12 provisional raw-parent closures, same DOM, physical resources=0");
    return s.failed || s.objects || !s.evaluated || s.messages!=1;
}
