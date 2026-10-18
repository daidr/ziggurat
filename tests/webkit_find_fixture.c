#include <webkit2/webkit2.h>
#include <stdint.h>
#include <stdlib.h>

/* Test-only signal observer. It neither supplies request IDs nor changes the
 * engine result. The borrowed Zig context is revoked before any foreign free. */
typedef void (*FindObserved)(void *,int,uint32_t);
typedef struct FindObserver {
    WebKitFindController *controller;
    FindObserved notify;
    void *context;
    gulong found,failed;
    unsigned refs;
    gboolean closed;
} FindObserver;
static unsigned observer_count;
static void observer_ref(FindObserver *p) { g_assert(p->refs);++p->refs; }
static void observer_unref(FindObserver *p) {
    g_assert(p->refs);if (--p->refs) return;
    g_assert(p->closed && !p->controller && !p->context && !p->notify && !p->found && !p->failed);
    free(p);--observer_count;
}
static void closure_free(gpointer data,GClosure *closure) { (void)closure;observer_unref(data); }
static void observed(FindObserver *p,int found,uint32_t count) {
    observer_ref(p);
    if (!p->closed && p->notify) {
        FindObserved call=p->notify;void *context=p->context;call(context,found,count);
    }
    observer_unref(p);
}
static void found_text(WebKitFindController *sender,guint count,gpointer data) {
    g_object_ref(sender);observed(data,1,count);g_object_unref(sender);
}
static void failed_text(WebKitFindController *sender,gpointer data) {
    g_object_ref(sender);observed(data,0,0);g_object_unref(sender);
}
static gulong observe_connect(FindObserver *p,const char *name,GCallback callback) {
    observer_ref(p);GClosure *closure=g_cclosure_new(callback,p,closure_free);
    g_closure_ref(closure);g_closure_sink(closure);
    gulong id=g_signal_connect_closure(p->controller,name,closure,FALSE);
    g_closure_unref(closure);return id;
}
void zfind_test_observer_release(FindObserver *p) {
    g_assert(p && !p->closed);p->closed=TRUE;p->context=NULL;p->notify=NULL;
    WebKitFindController *controller=p->controller;p->controller=NULL;
    gulong found=p->found,failed=p->failed;p->found=p->failed=0;
    if (found) g_signal_handler_disconnect(controller,found);
    if (failed) g_signal_handler_disconnect(controller,failed);
    g_object_unref(controller);observer_unref(p);
}
FindObserver *zfind_test_observer_new(WebKitWebView *view,void *context,FindObserved notify) {
    if (!WEBKIT_IS_WEB_VIEW(view) || !context || !notify) return NULL;
    FindObserver *p=calloc(1,sizeof(*p));if (!p) return NULL;
    ++observer_count;p->refs=1;p->context=context;p->notify=notify;
    WebKitFindController *controller=webkit_web_view_get_find_controller(view);
    if (!controller) { p->closed=TRUE;p->context=NULL;p->notify=NULL;observer_unref(p);return NULL; }
    p->controller=g_object_ref(controller);
    p->found=observe_connect(p,"found-text",G_CALLBACK(found_text));
    p->failed=observe_connect(p,"failed-to-find-text",G_CALLBACK(failed_text));
    if (!p->found || !p->failed) { zfind_test_observer_release(p);return NULL; }
    return p;
}
uint32_t zfind_test_observers(void) { return observer_count; }
