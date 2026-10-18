#include <webkit2/webkit2.h>
#include <stdio.h>
#include <string.h>

/* This hidden, ephemeral engine probe deliberately has no adapter policy. It
 * establishes native ordering and document identity before policy is wired. */
typedef struct Probe {
    GMainLoop *loop;
    GtkWidget *window;
    WebKitWebView *view;
    WebKitUserContentManager *manager;
    WebKitWebContext *context;
    WebKitBackForwardListItem *path_item,*fragment_item;
    guint drive,watchdog;
    unsigned step,started,finished,documents,pops,baseline_pops,baseline_finished;
    unsigned token_a,token_b,token_c,token_d,token_e,last_token,pop_token;
    gboolean evaluating,failed,closing;
    unsigned objects;
} Probe;
static const char *const a_uri="asset://app.ziggurat.invalid/a";
static const char *const b_uri="asset://app.ziggurat.invalid/b";
static const char *const path_uri="asset://app.ziggurat.invalid/pushed?q=1";
static const char *const fragment_uri="asset://app.ziggurat.invalid/pushed?q=1#fragment";
static gboolean advance(gpointer);
static void schedule(Probe *s) {
    if (!s->drive) s->drive=g_idle_add(advance,s);
}
static void fail(Probe *s,const char *reason) {
    fprintf(stderr,"history events failure step=%u: %s\n",s->step,reason);
    s->failed=TRUE; schedule(s);
}
static void trace(Probe *s,const char *event,WebKitBackForwardListItem *added,unsigned removed) {
    WebKitBackForwardList *list=webkit_web_view_get_back_forward_list(s->view);
    fprintf(stderr,"history event step=%u %s uri=%s item=%p added=%p removed=%u starts=%u finishes=%u loading=%d\n",
        s->step,event,webkit_web_view_get_uri(s->view),
        (void *)webkit_back_forward_list_get_current_item(list),(void *)added,removed,
        s->started,s->finished,webkit_web_view_is_loading(s->view));
}
static void changed(WebKitBackForwardList *list,WebKitBackForwardListItem *added,GList *removed,gpointer data) {
    (void)list; Probe *s=data; trace(s,"list",added,g_list_length(removed)); schedule(s);
}
static void uri_changed(GObject *view,GParamSpec *property,gpointer data) {
    (void)view; (void)property; Probe *s=data; trace(s,"uri",NULL,0); schedule(s);
}
static void loading_changed(GObject *view,GParamSpec *property,gpointer data) {
    (void)view; (void)property; Probe *s=data; trace(s,"loading",NULL,0); schedule(s);
}
static void loaded(WebKitWebView *view,WebKitLoadEvent event,gpointer data) {
    (void)view; Probe *s=data;
    if (event==WEBKIT_LOAD_STARTED) ++s->started;
    if (event==WEBKIT_LOAD_FINISHED) ++s->finished;
    const char *name=event==WEBKIT_LOAD_STARTED?"started":event==WEBKIT_LOAD_REDIRECTED?"redirected":event==WEBKIT_LOAD_COMMITTED?"committed":"finished";
    trace(s,name,NULL,0); schedule(s);
}
static gboolean failed(WebKitWebView *view,WebKitLoadEvent event,const char *uri,GError *error,gpointer data) {
    (void)view; (void)event; (void)uri; fail(data,error->message); return TRUE;
}
static gboolean policy(WebKitWebView *view,WebKitPolicyDecision *decision,WebKitPolicyDecisionType type,gpointer data) {
    (void)view; Probe *s=data;
    if (type==WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) {
        WebKitNavigationAction *action=webkit_navigation_policy_decision_get_navigation_action(WEBKIT_NAVIGATION_POLICY_DECISION(decision));
        fprintf(stderr,"history policy step=%u kind=%d redirect=%d uri=%s\n",s->step,
            webkit_navigation_action_get_navigation_type(action),webkit_navigation_action_is_redirect(action),
            webkit_uri_request_get_uri(webkit_navigation_action_get_request(action)));
    }
    webkit_policy_decision_use(decision); return TRUE;
}
static void resource(WebKitURISchemeRequest *request,gpointer data) {
    Probe *s=data;
    char *body=g_strdup_printf("<!doctype html><script>window.token=%u;addEventListener('popstate',()=>webkit.messageHandlers.probe.postMessage(token))</script>",++s->documents);
    fprintf(stderr,"history resource document=%u uri=%s\n",s->documents,webkit_uri_scheme_request_get_uri(request));
    GInputStream *stream=g_memory_input_stream_new_from_data(body,(gssize)strlen(body),g_free);
    webkit_uri_scheme_request_finish(request,stream,(gint64)strlen(body),"text/html");
    g_object_unref(stream);
}
static void popped(WebKitUserContentManager *manager,WebKitJavascriptResult *result,gpointer data) {
    (void)manager; Probe *s=data;
    s->pop_token=(unsigned)jsc_value_to_int32(webkit_javascript_result_get_js_value(result));
    ++s->pops;
    fprintf(stderr,"history pop step=%u token=%u count=%u\n",s->step,s->pop_token,s->pops);
    schedule(s);
}
static void evaluated(GObject *view,GAsyncResult *result,gpointer data) {
    Probe *s=data; GError *error=NULL;
    JSCValue *value=webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(view),result,&error);
    s->evaluating=FALSE;
    if (error || !value || !jsc_value_is_number(value)) fail(s,error?error->message:"token result is not a number");
    else {
        unsigned token=(unsigned)jsc_value_to_int32(value);
        fprintf(stderr,"history token step=%u token=%u started=%u finished=%u\n",s->step,token,s->started,s->finished);
        switch (s->step) {
        case 0: s->token_a=token; break;
        case 1: case 2: case 4: case 6:
            if (token!=s->token_a || s->started!=1 || s->documents!=1) fail(s,"same-document action reloaded the document");
            break;
        case 8: s->token_b=token; if (token==s->token_a) fail(s,"second document reused the DOM"); break;
        case 10: s->token_c=token; if (token==s->token_a || token==s->token_b) fail(s,"back-forward cache was not disabled"); break;
        case 12:
            fprintf(stderr,"history observation restored-group inner-back same-dom=%d\n",token==s->token_c);
            break;
        case 14: s->token_d=token; if (token==s->last_token) fail(s,"refresh reused the DOM"); break;
        case 16:
            fprintf(stderr,"history observation refreshed-group inner-forward same-dom=%d\n",token==s->token_d);
            break;
        case 18: s->token_e=token; if (token==s->last_token) fail(s,"same-URI load reused the DOM"); break;
        case 20:
            fprintf(stderr,"history observation same-uri-reload inner-back same-dom=%d\n",token==s->token_e);
            break;
        default: fail(s,"unexpected evaluation step"); break;
        }
        s->last_token=token; ++s->step;
    }
    g_clear_error(&error); if (value) g_object_unref(value); schedule(s);
}
static void evaluate(Probe *s,const char *script) {
    s->evaluating=TRUE;
    webkit_web_view_evaluate_javascript(s->view,script,-1,NULL,NULL,NULL,evaluated,s);
}
static gboolean at(Probe *s,const char *uri) {
    return !g_strcmp0(webkit_web_view_get_uri(s->view),uri);
}
static gboolean arrived(Probe *s,const char *uri) {
    return at(s,uri) && !webkit_web_view_is_loading(s->view) &&
        (s->finished>s->baseline_finished || s->pops>s->baseline_pops);
}
static void baseline(Probe *s) { s->baseline_pops=s->pops; s->baseline_finished=s->finished; }
static void finalized(gpointer data,GObject *object) {
    (void)object; Probe *s=data; --s->objects; schedule(s);
}
static void close_probe(Probe *s) {
    if (s->closing) return;
    s->closing=TRUE;
    g_clear_object(&s->path_item); g_clear_object(&s->fragment_item);
    g_signal_handlers_disconnect_by_data(webkit_web_view_get_back_forward_list(s->view),s);
    g_signal_handlers_disconnect_by_data(s->view,s);
    g_signal_handlers_disconnect_by_data(s->manager,s);
    gtk_widget_destroy(s->window); s->window=NULL; s->view=NULL;
    g_clear_object(&s->manager); g_clear_object(&s->context);
}
static gboolean advance(gpointer data) {
    Probe *s=data; s->drive=0;
    if (s->failed || s->step==21) close_probe(s);
    if (s->closing) {
        if (!s->objects) g_main_loop_quit(s->loop);
        return G_SOURCE_REMOVE;
    }
    if (s->evaluating) return G_SOURCE_REMOVE;
    switch (s->step) {
    case 0: if (s->finished==1 && at(s,a_uri)) evaluate(s,"token"); break;
    case 1: evaluate(s,"history.pushState({test:1},'', '/pushed?q=1');token"); break;
    case 2:
        if (at(s,path_uri)) {
            s->path_item=g_object_ref(webkit_back_forward_list_get_current_item(webkit_web_view_get_back_forward_list(s->view)));
            evaluate(s,"history.pushState({test:2},'', '#fragment');token");
        }
        break;
    case 3:
        if (at(s,fragment_uri)) {
            s->fragment_item=g_object_ref(webkit_back_forward_list_get_current_item(webkit_web_view_get_back_forward_list(s->view)));
            baseline(s); s->step=4; webkit_web_view_go_to_back_forward_list_item(s->view,s->path_item);
        }
        break;
    case 4: if (arrived(s,path_uri)) evaluate(s,"token"); break;
    case 5: baseline(s); s->step=6; webkit_web_view_go_to_back_forward_list_item(s->view,s->fragment_item); break;
    case 6: if (arrived(s,fragment_uri)) evaluate(s,"token"); break;
    case 7: baseline(s); s->step=8; webkit_web_view_load_uri(s->view,b_uri); break;
    case 8: if (s->finished>s->baseline_finished && at(s,b_uri)) evaluate(s,"token"); break;
    case 9: baseline(s); s->step=10; webkit_web_view_go_to_back_forward_list_item(s->view,s->fragment_item); break;
    case 10: if (s->finished>s->baseline_finished && at(s,fragment_uri)) evaluate(s,"token"); break;
    case 11: baseline(s); s->step=12; webkit_web_view_go_to_back_forward_list_item(s->view,s->path_item); break;
    case 12: if (arrived(s,path_uri)) evaluate(s,"token"); break;
    case 13: baseline(s); s->step=14; webkit_web_view_reload(s->view); break;
    case 14: if (s->finished>s->baseline_finished && at(s,path_uri)) evaluate(s,"token"); break;
    case 15: baseline(s); s->step=16; webkit_web_view_go_to_back_forward_list_item(s->view,s->fragment_item); break;
    case 16: if (arrived(s,fragment_uri)) evaluate(s,"token"); break;
    case 17: baseline(s); s->step=18; webkit_web_view_load_uri(s->view,fragment_uri); break;
    case 18: if (s->finished>s->baseline_finished && at(s,fragment_uri)) evaluate(s,"token"); break;
    case 19: baseline(s); s->step=20; webkit_web_view_go_to_back_forward_list_item(s->view,s->path_item); break;
    case 20: if (arrived(s,path_uri)) evaluate(s,"token"); break;
    default: fail(s,"invalid stage"); break;
    }
    return G_SOURCE_REMOVE;
}
static gboolean timeout(gpointer data) {
    Probe *s=data; s->watchdog=0; fail(s,"watchdog expired"); return G_SOURCE_REMOVE;
}
int main(void) {
    gtk_init(NULL,NULL);
    Probe s={0}; s.loop=g_main_loop_new(NULL,FALSE);
    s.context=webkit_web_context_new_ephemeral();
    webkit_web_context_register_uri_scheme(s.context,"asset",resource,&s,NULL);
    webkit_security_manager_register_uri_scheme_as_secure(webkit_web_context_get_security_manager(s.context),"asset");
    webkit_security_manager_register_uri_scheme_as_cors_enabled(webkit_web_context_get_security_manager(s.context),"asset");
    s.manager=webkit_user_content_manager_new();
    webkit_user_content_manager_register_script_message_handler(s.manager,"probe");
    g_signal_connect(s.manager,"script-message-received::probe",G_CALLBACK(popped),&s);
    s.view=WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW,"web-context",s.context,"user-content-manager",s.manager,NULL));
    WebKitSettings *settings=webkit_web_view_get_settings(s.view);
    webkit_settings_set_enable_page_cache(settings,FALSE);
    g_signal_connect(s.view,"decide-policy",G_CALLBACK(policy),&s);
    g_signal_connect(s.view,"load-changed",G_CALLBACK(loaded),&s);
    g_signal_connect(s.view,"load-failed",G_CALLBACK(failed),&s);
    g_signal_connect(s.view,"notify::uri",G_CALLBACK(uri_changed),&s);
    g_signal_connect(s.view,"notify::is-loading",G_CALLBACK(loading_changed),&s);
    g_signal_connect(webkit_web_view_get_back_forward_list(s.view),"changed",G_CALLBACK(changed),&s);
    s.window=gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_container_add(GTK_CONTAINER(s.window),GTK_WIDGET(s.view)); gtk_widget_realize(s.window);
    s.objects=3;
    g_object_weak_ref(G_OBJECT(s.view),finalized,&s);
    g_object_weak_ref(G_OBJECT(s.manager),finalized,&s);
    g_object_weak_ref(G_OBJECT(s.context),finalized,&s);
    s.watchdog=g_timeout_add_seconds(15,timeout,&s);
    webkit_web_view_load_uri(s.view,a_uri);
    g_main_loop_run(s.loop);
    close_probe(&s);
    if (s.drive) g_source_remove(s.drive);
    if (s.watchdog) g_source_remove(s.watchdog);
    fprintf(stderr,"history events result step=%u documents=%u starts=%u finishes=%u native-objects=%u\n",s.step,s.documents,s.started,s.finished,s.objects);
    g_main_loop_unref(s.loop);
    return !s.failed && s.step==21 && !s.objects?0:1;
}
