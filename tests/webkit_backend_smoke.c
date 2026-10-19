#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#include "../src/webview/webkit_native.h"
#include "../src/platform/linux_content.h"
#include <stdio.h>
#include <string.h>

typedef struct NativeEvent {
    int kind,key,flags;
    void *context,*window;
    double x,y,dx,dy;
    uint32_t width,height,scale;
    const char *text;
    size_t length,selection;
} NativeEvent;
extern void *zlg_app_create(void *,void (*)(void *),int *);
extern void zlg_app_destroy(void *);
extern NativeWindow *zlg_window_create(void *,int (*)(void *,const NativeEvent *),const char *,uint32_t,uint32_t,uint32_t,uint32_t,NativeWindow *,int,int,int,int *);
extern int zlg_window_destroy(NativeWindow *);
extern uint32_t zlg_resource_count(void);

typedef struct Probe {
    GMainLoop *loop;
    NativeWindow *window;
    ZwkState *view;
    gboolean closed,failed,loaded,boot,reject_page,stop_page,resume_page,close_page,prior_failure_page,repeat_load_failure,native_probe_started,native_probe_done,expect_unowned_commit;
    unsigned ready,started,completed,scripts,messages,child_messages,deadline,boundaries,native_pending;
    unsigned native_started,native_committed,published_sources,published_dom,unowned_commits;
    ZwkFailure prior_failure,load_failure,last_load_failure;
    WebKitWebView *observed_view;
    guint watchdog,drain;
} Probe;
static void fail(Probe *s,const char *message) { fprintf(stderr,"webkit backend: %s\n",message); s->failed=TRUE; g_main_loop_quit(s->loop); }
#define EXPECT(s,test) do { if (!(test)) { fail(s,#test); return; } } while (0)
static void close_view(Probe *s) {
    if (s->closed) return;
    s->closed=TRUE;
    ZwkState *view=s->view; s->view=NULL;
    if (view) zwk_close(view);
    NativeWindow *window=s->window; s->window=NULL;
    if (window) zlg_window_destroy(window);
}
static gboolean drained(gpointer data) {
    Probe *s=data;
    uint32_t states,callbacks,views; zwk_counts(&states,&callbacks,&views);
    if (s->closed && !states && !callbacks && !views && !zlg_content_count() && !s->native_pending) {
        s->drain=0; g_main_loop_quit(s->loop); return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}
static gboolean timeout(gpointer data) { Probe *s=data; s->watchdog=0; fail(s,"deadline expired"); return G_SOURCE_REMOVE; }
static GtkWidget *find_view(GtkWidget *widget) {
    if (WEBKIT_IS_WEB_VIEW(widget)) return widget;
    if (!GTK_IS_CONTAINER(widget)) return NULL;
    GList *children=gtk_container_get_children(GTK_CONTAINER(widget));
    GtkWidget *found=NULL;
    for (GList *item=children;item && !found;item=item->next) found=find_view(item->data);
    g_list_free(children); return found;
}
static GtkWidget *current_native(void) {
    GList *windows=gtk_window_list_toplevels(); GtkWidget *view=NULL;
    for (GList *item=windows;item && !view;item=item->next) view=find_view(item->data);
    g_list_free(windows); return view;
}
static void native_probe_finished(GObject *source,GAsyncResult *result,gpointer data) {
    Probe *s=data; GError *error=NULL;
    JSCValue *value=webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(source),result,&error);
    --s->native_pending;
    if (error || !value) {
        fprintf(stderr,"private probe error: %s\n",error?error->message:"no result");
        fail(s,"private native-boundary probe failed");
    }
    if (value) g_object_unref(value);
    g_clear_error(&error);
}
static void begin(Probe *s) {
    if (!s->loaded || !s->boot || s->scripts) return;
    if (!s->native_probe_started) {
        GList *windows=gtk_window_list_toplevels(); GtkWidget *view=NULL;
        for (GList *item=windows;item && !view;item=item->next) view=find_view(item->data);
        g_list_free(windows);
        if (!view) { fail(s,"native WebView missing"); return; }
        s->native_probe_started=TRUE; ++s->native_pending;
        webkit_web_view_evaluate_javascript(WEBKIT_WEB_VIEW(view),
            "webkit.messageHandlers.ziggurat.postMessage('1|Mnative-prefix\\0suffix');"
            "webkit.messageHandlers.ziggurat.postMessage('1|M'+('中'.repeat(21845)+'ab'));"
            "webkit.messageHandlers.ziggurat.postMessage('1|Mnative-check');true",-1,"ziggurat-private",NULL,NULL,native_probe_finished,s);
        return;
    }
    if (!s->native_probe_done) return;
    if (zwk_evaluate(s->view,"({answer:42,text:'你好'})",1)!=ZWK_OK) fail(s,"first evaluation rejected");
}
static int native_event(void *data,const NativeEvent *value) {
    Probe *s=data;
    if (value->kind==11) {
        s->window=NULL;
        if (!s->closed) close_view(s);
    }
    return 0;
}
static char *utf8(const uint16_t *value) { return value?g_utf16_to_utf8((const gunichar2 *)value,-1,NULL,NULL,NULL):NULL; }
static void notified(void *data,int kind,const uint16_t *value,int32_t code,const ZwkFailure *failure) {
    Probe *s=data;
    EXPECT(s,!s->closed);
    if (kind==2 && s->expect_unowned_commit) {
        s->expect_unowned_commit=FALSE; ++s->unowned_commits;
        EXPECT(s,code==ZWK_POLICY_PREPARATION && failure && failure->code==ZWK_POLICY_PREPARATION &&
            !g_strcmp0(g_quark_to_string(failure->domain),"ziggurat-webkit-navigation"));
        EXPECT(s,zwk_post(s->view,"unowned") == ZWK_NOT_READY);
        close_view(s); return;
    }
    if (kind==0) {
        ++s->ready;
        EXPECT(s,zwk_refresh(s->view)==ZWK_NAVIGATION_PENDING);
        EXPECT(s,zwk_post(s->view,"not committed")==ZWK_NOT_READY);
        return;
    }
    char *text=utf8(value);
    if (kind==1 && text) {
        if (strlen(text)==65536 && !memcmp(text,"boundary:",9)) { ++s->boundaries; g_free(text); return; }
        if (!strcmp(text,"native-check")) { s->native_probe_done=TRUE; begin(s); g_free(text); return; }
        ++s->messages;
        if (!strcmp(text,"boot")) { s->boot=TRUE; begin(s); }
        else if (!strcmp(text,"replied")) {
            EXPECT(s,zwk_deadline_arm(s->view,1000000)==ZWK_OK);
            EXPECT(s,zwk_evaluate(s->view,"(()=>{const end=Date.now()+60;while(Date.now()<end){};return 5})()",3)==ZWK_OK);
        } else { ++s->child_messages; fprintf(stderr,"unexpected sender packet: %s\n",text); }
    } else {
        fprintf(stderr,"native event kind=%d code=%d domain=%u\n",kind,code,failure?failure->domain:0);
        fail(s,"unexpected native event");
    }
    g_free(text);
}
static int page_event(void *data,const ZwkPageEvent *value) {
    Probe *s=data;
    if (s->closed) { fail(s,"late page callback"); return 0; }
    if (value->kind==0) ++s->started;
    if (value->kind==0 && s->close_page) { close_view(s); return 0; }
    if (value->kind==0 && s->resume_page && s->started==1) return 0;
    if (value->kind==0 && s->reject_page) return 0;
    if (value->kind==0 && s->prior_failure_page && s->started==2 && s->repeat_load_failure) {
        /* Injected first-error preservation, distinct from the real JS-error
         * and no-load-failed cancellation case. No SDK occurrence is claimed. */
        GError *first=g_error_new_literal(s->prior_failure.domain,s->prior_failure.code,"injected copy of the prior real script error");
        GError *later=g_error_new_literal(G_IO_ERROR,G_IO_ERROR_CANCELLED,"injected later cancellation");
        gboolean handled=FALSE;
        g_signal_emit_by_name(s->observed_view,"load-failed",WEBKIT_LOAD_STARTED,webkit_web_view_get_uri(s->observed_view),first,&handled);
        if (!handled) fail(s,"injected first error was not handled");
        g_signal_emit_by_name(s->observed_view,"load-failed",WEBKIT_LOAD_STARTED,webkit_web_view_get_uri(s->observed_view),later,&handled);
        g_error_free(later); g_error_free(first);
    }
    if (value->kind==0 && (s->stop_page || (s->prior_failure_page && s->started==2))) {
        if (zwk_stop(s->view)!=ZWK_OK) fail(s,"stop during Starting failed");
    }
    if (value->kind==3) ++s->published_sources;
    if (value->kind==2) ++s->published_dom;
    if (value->kind==1) {
        ++s->completed;
        if (s->prior_failure_page) {
            if (s->completed==1) {
                if (!(value->flags&1) || zwk_evaluate(s->view,"throw Error('prior real script failure')",50)!=ZWK_OK)
                    fail(s,"prior-error evaluation was not submitted");
            } else {
                ZwkFailure last={0}; zwk_last_failure(s->view,&last);
                if (s->completed!=2 || (value->flags&1) || value->status!=s->load_failure.code) {
                    fprintf(stderr,"cancel status=%d load_failure=%u/%d prior_script=%u/%d\n",value->status,s->load_failure.domain,s->load_failure.code,s->prior_failure.domain,s->prior_failure.code);
                    fail(s,"cancel completion inherited another operation's failure");
                }
                const ZwkFailure expected=s->last_load_failure.domain?s->last_load_failure:s->prior_failure;
                if (last.domain!=expected.domain || last.code!=expected.code)
                    fail(s,"lastNativeFailure did not preserve the latest native diagnostic");
                close_view(s);
            }
            return !s->closed;
        }
        if (s->resume_page) {
            if (s->completed==1) {
                if ((value->flags&1) || zwk_post(s->view,"revoked")!=ZWK_NOT_READY ||
                    zwk_navigate_local(s->view,"/next")!=ZWK_OK ||
                    zwk_navigate_local(s->view,"/document")!=ZWK_NAVIGATION_PENDING)
                    fail(s,"completion did not release the revoked navigation");
            } else {
                if (s->completed!=2 || !(value->flags&1)) fail(s,"replacement navigation failed");
                close_view(s);
            }
            return !s->closed;
        }
        if (s->reject_page || s->stop_page) {
            if (value->flags&1) fail(s,"rejected Starting committed");
            if (s->stop_page) {
                /* FINISHED consumed the exact revoked-load marker. A new
                 * unowned COMMITTED must still report the original failure. */
                s->expect_unowned_commit=TRUE;
                g_signal_emit_by_name(current_native(),"load-changed",WEBKIT_LOAD_COMMITTED);
                if (!s->closed || s->expect_unowned_commit) fail(s,"unowned commit was silently accepted");
                return 0;
            }
            close_view(s);
            return 0;
        }
        if (!(value->flags&1)) fail(s,"document failed");
        s->loaded=TRUE; begin(s);
    }
    return !s->closed;
}
static void observed_load(WebKitWebView *view,WebKitLoadEvent event,gpointer data) {
    (void)view;
    Probe *s=data;
    if (event==WEBKIT_LOAD_STARTED) ++s->native_started;
    if (event==WEBKIT_LOAD_COMMITTED) {
        ++s->native_committed;
        if (!s->closed && (zwk_post(s->view,"revoked")!=ZWK_NOT_READY ||
            zwk_evaluate(s->view,"1",99)!=ZWK_NOT_READY || zwk_refresh(s->view)!=ZWK_NAVIGATION_PENDING))
            fail(s,"revoked commit reopened document or navigation");
    }
}
static gboolean observed_failure(GSignalInvocationHint *hint,guint count,const GValue *values,gpointer data) {
    (void)hint;
    Probe *s=data;
    if (count==4 && g_value_get_object(&values[0])==s->observed_view && s->started==2) {
        const GError *error=g_value_get_boxed(&values[3]);
        if (error) {
            s->last_load_failure=(ZwkFailure){error->domain,error->code};
            if (!s->load_failure.domain) s->load_failure=s->last_load_failure;
        }
    }
    return TRUE;
}
static void script_done(void *data,uint64_t token,int status,int32_t code,const uint16_t *value,const ZwkFailure *failure) {
    Probe *s=data;
    if (s->prior_failure_page) {
        EXPECT(s,!s->closed && token==50 && status==1 && failure && failure->domain && code && failure->code==code);
        s->prior_failure=*failure; ++s->scripts;
        EXPECT(s,zwk_refresh(s->view)==ZWK_OK); return;
    }
    EXPECT(s,!s->closed && status==0);
    char *text=utf8(value);
    EXPECT(s,text!=NULL);
    ++s->scripts;
    if (token==1) {
        EXPECT(s,!strcmp(text,"{\"answer\":42,\"text\":\"你好\"}"));
        EXPECT(s,zwk_evaluate(s->view,"(()=>{alert('denied');if(confirm('denied'))throw Error('confirm');if(prompt('denied')!==null)throw Error('prompt');print();return 42})()",2)==ZWK_OK);
    } else if (token==2) {
        EXPECT(s,!strcmp(text,"42"));
        double zoom=1.25; EXPECT(s,zwk_zoom(s->view,&zoom,1)==ZWK_OK);
        zoom=0; EXPECT(s,zwk_zoom(s->view,&zoom,0)==ZWK_OK && zoom==1.25);
        EXPECT(s,zwk_user_agent(s->view,"Ziggurat isolated integration",NULL)==ZWK_OK);
        char *agent=NULL; EXPECT(s,zwk_user_agent(s->view,NULL,&agent)==ZWK_OK);
        EXPECT(s,agent && !strcmp(agent,"Ziggurat isolated integration")); zwk_string_free(agent);
        int enabled=1,visible=1; EXPECT(s,zwk_devtools(s->view,0,&enabled,&visible)==ZWK_OK && !enabled && !visible);
        EXPECT(s,zwk_devtools(s->view,3,NULL,NULL)==ZWK_DEVTOOLS_DISABLED && zwk_devtools(s->view,4,NULL,NULL)==ZWK_INVALID);
        uint32_t shown=0; zwk_devtools_counts(&shown); EXPECT(s,shown==0);
        EXPECT(s,zwk_devtools(s->view,1,NULL,NULL)==ZWK_OK && zwk_devtools(s->view,3,&enabled,&visible)==ZWK_OK && enabled && visible);
        zwk_devtools_counts(&shown); EXPECT(s,shown==1);
        EXPECT(s,zwk_devtools(s->view,2,&enabled,&visible)==ZWK_OK && !enabled && !visible);
        zwk_devtools_counts(&shown); EXPECT(s,shown==0);
        EXPECT(s,zwk_post(s->view,"pong")==ZWK_OK);
    } else fail(s,"cancelled evaluation delivered business callback");
    g_free(text);
}
static void deadline(void *data) {
    Probe *s=data; ++s->deadline;
    zwk_evaluate_cancel(s->view,3);
    close_view(s);
}
static void dispatch(void *unused) { (void)unused; }
int main(void) {
    int error=0;
    void *app=zlg_app_create(NULL,dispatch,&error);
    if (!app || error) return 2;
    unsigned baseline=zlg_resource_count();
    Probe s={0}; s.loop=g_main_loop_new(NULL,FALSE);
    s.window=zlg_window_create(&s,native_event,"hidden engine adapter",320,200,0,0,NULL,0,0,1,&error);
    if (!s.window || error) return 2;
    const char html[]="<!doctype html><title>isolated document</title><script>"
        "chrome.webview.addEventListener('message',e=>{if(e.data==='pong')chrome.webview.postMessage('replied')});"
        "addEventListener('DOMContentLoaded',()=>{"
        "dispatchEvent(new MessageEvent('message',{data:{__ziggurat:'synthetic'},source:window}));"
        "window.postMessage({__ziggurat:'prefix\\0suffix'},'*');"
        "const boundary='boundary:'+'中'.repeat(21842)+'a';"
        "if(new TextEncoder().encode(boundary).length!==65536)throw Error('fixture boundary');"
        "window.postMessage({__ziggurat:boundary},'*');"
        "window.postMessage({__ziggurat:boundary+'b'},'*');"
        "const f=document.createElement('iframe');document.documentElement.append(f);"
        "f.contentWindow.eval(`parent.postMessage({__ziggurat:'child-message'},'*');"
        "try{webkit.messageHandlers.ziggurat.postMessage('1|Mchild-direct')}catch{}`);"
        "chrome.webview.postMessage('boot')});</script>";
    ZwkOptions options={.html=html,.zoom=1.0,.max_pending=1,.max_result_bytes=65536};
    if (zwk_create(s.window,&options,notified,page_event,script_done,deadline,&s,&s.view)!=ZWK_OK) return 2;
    s.watchdog=g_timeout_add_seconds(15,timeout,&s);
    s.drain=g_timeout_add(10,drained,&s);
    g_main_loop_run(s.loop);
    close_view(&s);
    if (s.watchdog) g_source_remove(s.watchdog);
    if (s.drain) g_source_remove(s.drain);
    uint32_t states,callbacks,views; zwk_counts(&states,&callbacks,&views);
    if (s.failed || s.ready!=1 || s.started!=1 || s.completed!=1 || s.scripts!=2 || s.deadline!=1 || s.messages!=2 || s.child_messages || s.boundaries!=1 ||
        !s.native_probe_done || s.native_pending || states || callbacks || views || zlg_content_count() || zlg_resource_count()!=baseline) {
        fprintf(stderr,"webkit backend: ready=%u page=%u/%u scripts=%u messages=%u child=%u deadline=%u resources=%u/%u/%u/%u\n",
            s.ready,s.started,s.completed,s.scripts,s.messages,s.child_messages,s.deadline,states,callbacks,views,zlg_resource_count());
        return 1;
    }
    g_main_loop_unref(s.loop);
    Probe rejected={.reject_page=TRUE}; rejected.loop=g_main_loop_new(NULL,FALSE);
    rejected.window=zlg_window_create(&rejected,native_event,"rejected page",320,200,0,0,NULL,0,0,1,&error);
    options.html="<script>chrome.webview.postMessage('must-not-arrive')</script>";
    if (!rejected.window || zwk_create(rejected.window,&options,notified,page_event,script_done,deadline,&rejected,&rejected.view)!=ZWK_OK) return 2;
    GtkWidget *rejected_native=current_native();
    if (!rejected_native) return 2;
    g_signal_connect(rejected_native,"load-changed",G_CALLBACK(observed_load),&rejected);
    rejected.watchdog=g_timeout_add_seconds(15,timeout,&rejected);
    rejected.drain=g_timeout_add(10,drained,&rejected);
    g_main_loop_run(rejected.loop); close_view(&rejected);
    if (rejected.watchdog) g_source_remove(rejected.watchdog);
    if (rejected.drain) g_source_remove(rejected.drain);
    zwk_counts(&states,&callbacks,&views);
    if (rejected.failed || rejected.ready!=1 || rejected.started!=1 || rejected.completed!=1 || rejected.messages ||
        rejected.native_started!=1 || rejected.native_committed!=1 || rejected.published_sources || rejected.published_dom ||
        states || callbacks || views || zlg_content_count() || zlg_resource_count()!=baseline) return 1;
    g_main_loop_unref(rejected.loop);
    Probe stopped={.stop_page=TRUE}; stopped.loop=g_main_loop_new(NULL,FALSE);
    stopped.window=zlg_window_create(&stopped,native_event,"stopped page",320,200,0,0,NULL,0,0,1,&error);
    if (!stopped.window || zwk_create(stopped.window,&options,notified,page_event,script_done,deadline,&stopped,&stopped.view)!=ZWK_OK) return 2;
    GtkWidget *stopped_native=current_native();
    if (!stopped_native) return 2;
    g_signal_connect(stopped_native,"load-changed",G_CALLBACK(observed_load),&stopped);
    stopped.watchdog=g_timeout_add_seconds(15,timeout,&stopped);
    stopped.drain=g_timeout_add(10,drained,&stopped);
    g_main_loop_run(stopped.loop); close_view(&stopped);
    if (stopped.watchdog) g_source_remove(stopped.watchdog);
    if (stopped.drain) g_source_remove(stopped.drain);
    zwk_counts(&states,&callbacks,&views);
    if (stopped.failed || stopped.ready!=1 || stopped.started!=1 || stopped.completed!=1 || stopped.messages ||
        stopped.native_started!=1 || stopped.native_committed!=1 || stopped.unowned_commits!=1 || stopped.published_sources || stopped.published_dom ||
        states || callbacks || views || zlg_content_count() || zlg_resource_count()!=baseline) return 1;
    g_main_loop_unref(stopped.loop);
    Probe resumed={.resume_page=TRUE}; resumed.loop=g_main_loop_new(NULL,FALSE);
    resumed.window=zlg_window_create(&resumed,native_event,"resumed page",320,200,0,0,NULL,0,0,1,&error);
    ZwkLocalBudget *budget=zwk_local_budget_new(8,1024*1024);
    const char next[]="<!doctype html><title>replacement</title>";
    const ZwkLocalResource resource={.path="/next",.path_length=5,.mime="text/html",.mime_length=9,.bytes=(const uint8_t *)next,.length=sizeof(next)-1};
    const ZwkLocalOptions local={.scheme="asset",.host="app.ziggurat.invalid",.start_path="/document",.resources=&resource,.count=1,.max_response_bytes=65536,.budget=budget,.secure=1};
    options.local=&local;
    if (!resumed.window || !budget || zwk_create(resumed.window,&options,notified,page_event,script_done,deadline,&resumed,&resumed.view)!=ZWK_OK) return 2;
    resumed.watchdog=g_timeout_add_seconds(15,timeout,&resumed);
    resumed.drain=g_timeout_add(10,drained,&resumed);
    g_main_loop_run(resumed.loop); close_view(&resumed);
    if (resumed.watchdog) g_source_remove(resumed.watchdog);
    if (resumed.drain) g_source_remove(resumed.drain);
    zwk_local_budget_release(budget);
    zwk_counts(&states,&callbacks,&views);
    uint32_t budgets,streams,bytes; zwk_local_counts(&budgets,&streams,&bytes);
    if (resumed.failed || resumed.ready!=1 || resumed.started!=2 || resumed.completed!=2 || resumed.messages ||
        states || callbacks || views || budgets || streams || bytes || zlg_content_count() || zlg_resource_count()!=baseline) return 1;
    g_main_loop_unref(resumed.loop);
    Probe closed={.close_page=TRUE}; closed.loop=g_main_loop_new(NULL,FALSE);
    closed.window=zlg_window_create(&closed,native_event,"closed Starting",320,200,0,0,NULL,0,0,1,&error);
    options.local=NULL;
    if (!closed.window || zwk_create(closed.window,&options,notified,page_event,script_done,deadline,&closed,&closed.view)!=ZWK_OK) return 2;
    closed.watchdog=g_timeout_add_seconds(15,timeout,&closed);
    closed.drain=g_timeout_add(10,drained,&closed);
    g_main_loop_run(closed.loop); close_view(&closed);
    if (closed.watchdog) g_source_remove(closed.watchdog);
    if (closed.drain) g_source_remove(closed.drain);
    zwk_counts(&states,&callbacks,&views);
    if (closed.failed || closed.ready!=1 || closed.started!=1 || closed.completed || closed.messages ||
        states || callbacks || views || zlg_content_count() || zlg_resource_count()!=baseline) return 1;
    g_main_loop_unref(closed.loop);
    for (unsigned repeated=0;repeated<2;++repeated) {
        Probe prior={.prior_failure_page=TRUE,.repeat_load_failure=repeated!=0}; prior.loop=g_main_loop_new(NULL,FALSE);
        prior.window=zlg_window_create(&prior,native_event,"per-load failure",320,200,0,0,NULL,0,0,1,&error);
        options.html="<!doctype html><title>per-load failure</title>";
        if (!prior.window || zwk_create(prior.window,&options,notified,page_event,script_done,deadline,&prior,&prior.view)!=ZWK_OK) return 2;
        prior.observed_view=WEBKIT_WEB_VIEW(current_native());
        const guint failure_signal=g_signal_lookup("load-failed",WEBKIT_TYPE_WEB_VIEW);
        const gulong failure_hook=g_signal_add_emission_hook(failure_signal,0,observed_failure,&prior,NULL);
        if (!prior.observed_view || !failure_hook) return 2;
        prior.watchdog=g_timeout_add_seconds(15,timeout,&prior);
        prior.drain=g_timeout_add(10,drained,&prior);
        g_main_loop_run(prior.loop); close_view(&prior);
        g_signal_remove_emission_hook(failure_signal,failure_hook);
        if (prior.watchdog) g_source_remove(prior.watchdog);
        if (prior.drain) g_source_remove(prior.drain);
        zwk_counts(&states,&callbacks,&views);
        if (prior.failed || prior.ready!=1 || prior.started!=2 || prior.completed!=2 || prior.scripts!=1 || !prior.prior_failure.domain || prior.messages ||
            states || callbacks || views || zlg_content_count() || zlg_resource_count()!=baseline) return 1;
        if (repeated && (prior.load_failure.domain!=prior.prior_failure.domain || prior.load_failure.code!=prior.prior_failure.code)) return 1;
        g_main_loop_unref(prior.loop);
        }
    zlg_app_destroy(app);
    if (zlg_resource_count()) return 1;
    puts("webkit backend: top-only IPC, NUL/UTF-8 boundaries, chained scripts, properties, deadline close, rejected/stopped STARTED with late COMMITTED, completion reentry/close, real prior error and injected first-error preservation, resources=0");
    return 0;
}
