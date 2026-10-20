/* Controlled GTask scheduling exercises the production capture owner. Actual
 * WebKit/PNG integration is a separate public-Zig hidden-window fixture. */
#include <webkit2/webkit2.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include "../src/webview/webkit_native.h"

struct ZwkState {
    unsigned refs;
    GThread *thread;
    GtkWidget *view;
    void *owner;
    ZwkCaptureBudget *capture;
    gboolean closed,ready;
};
static unsigned states,finishes,submissions,notifications;
static int allocation_fail=-1;
static gboolean synchronous,fail_native,close_in_notify,reenter_in_notify,expect_clear;
static int last_status;
static uint64_t last_token;
static GTask *held[16];
static unsigned held_count;
static void settle(void) { for (unsigned i=0;i<32 && g_main_context_pending(NULL);++i) g_main_context_iteration(NULL,FALSE); }
static void capture_state_clear(ZwkState *);
static gboolean live(ZwkState *s) { return !s->closed && s->owner; }
static gboolean document(ZwkState *s) { return live(s) && s->ready; }
static void retain(ZwkState *s) { g_assert(s->refs);++s->refs; }
static void release(ZwkState *s) {
    g_assert(s->refs);
    if (--s->refs) return;
    g_assert(s->closed);capture_state_clear(s);g_object_unref(s->view);free(s);--states;
}
static void *test_malloc(size_t n) { if (allocation_fail==0) return NULL;if (allocation_fail>0)--allocation_fail;return malloc(n); }
static void *test_calloc(size_t n,size_t size) { if (allocation_fail==0) return NULL;if (allocation_fail>0)--allocation_fail;return calloc(n,size); }
static void fake_snapshot(WebKitWebView *,WebKitSnapshotRegion,WebKitSnapshotOptions,GCancellable *,GAsyncReadyCallback,gpointer);
static cairo_surface_t *fake_finish(WebKitWebView *view,GAsyncResult *result,GError **error) {
    g_assert(g_task_is_valid(result,view));++finishes;
    return g_task_propagate_pointer(G_TASK(result),error);
}
static void fake_clear(WebKitWebsiteDataManager *,WebKitWebsiteDataTypes,GTimeSpan,GCancellable *,GAsyncReadyCallback,gpointer);
static gboolean fake_clear_finish(WebKitWebsiteDataManager *manager,GAsyncResult *result,GError **error) {
    g_assert(g_task_is_valid(result,manager));++finishes;
    return g_task_propagate_boolean(G_TASK(result),error);
}
static WebKitWebsiteDataManager *fake_manager(WebKitWebView *view) { return (WebKitWebsiteDataManager *)view; }
#undef WEBKIT_WEBSITE_DATA_MANAGER
#define WEBKIT_WEBSITE_DATA_MANAGER(p) ((WebKitWebsiteDataManager *)(p))
#define webkit_web_view_get_website_data_manager fake_manager
#define webkit_website_data_manager_clear fake_clear
#define webkit_website_data_manager_clear_finish fake_clear_finish
#undef WEBKIT_WEB_VIEW
#define WEBKIT_WEB_VIEW(p) ((WebKitWebView *)(p))
#define webkit_web_view_get_snapshot fake_snapshot
#define webkit_web_view_get_snapshot_finish fake_finish
#define malloc test_malloc
#define calloc test_calloc
#include "../src/webview/webkit_capture_impl.h"
#undef malloc
#undef calloc

typedef struct Completion { GAsyncReadyCallback call;gpointer data; } Completion;
static void finish_task(GTask *task) {
    Completion *completion=g_object_get_data(G_OBJECT(task),"test-completion");
    if (fail_native) g_task_return_new_error(task,G_IO_ERROR,G_IO_ERROR_FAILED,"controlled snapshot failure");
    else if (g_object_get_data(G_OBJECT(task),"test-clear")) g_task_return_boolean(task,TRUE);
    else {
        cairo_surface_t *surface=cairo_image_surface_create(CAIRO_FORMAT_ARGB32,8,8);
        g_task_return_pointer(task,surface,(GDestroyNotify)cairo_surface_destroy);
    }
    completion->call(g_task_get_source_object(task),G_ASYNC_RESULT(task),completion->data);
}
static void fake_snapshot(WebKitWebView *view,WebKitSnapshotRegion region,WebKitSnapshotOptions options,GCancellable *cancel,GAsyncReadyCallback callback,gpointer data) {
    g_assert_cmpint(region,==,WEBKIT_SNAPSHOT_REGION_VISIBLE);g_assert_cmpint(options,==,WEBKIT_SNAPSHOT_OPTIONS_NONE);++submissions;
    GTask *task=g_task_new(view,cancel,NULL,NULL);
    Completion *completion=g_new(Completion,1);*completion=(Completion){callback,data};
    g_object_set_data_full(G_OBJECT(task),"test-completion",completion,g_free);
    if (synchronous) { finish_task(task);g_object_unref(task); }
    else { g_assert(held_count<G_N_ELEMENTS(held));held[held_count++]=task; }
}
static void fake_clear(WebKitWebsiteDataManager *manager,WebKitWebsiteDataTypes types,GTimeSpan timespan,GCancellable *cancel,GAsyncReadyCallback callback,gpointer data) {
    g_assert_cmpint(types,==,WEBKIT_WEBSITE_DATA_ALL);g_assert_cmpint(timespan,==,0);++submissions;
    GTask *task=g_task_new(manager,cancel,NULL,NULL);
    Completion *completion=g_new(Completion,1);*completion=(Completion){callback,data};
    g_object_set_data_full(G_OBJECT(task),"test-completion",completion,g_free);
    g_object_set_data(G_OBJECT(task),"test-clear",GINT_TO_POINTER(1));
    if (synchronous) { finish_task(task);g_object_unref(task); }
    else { g_assert(held_count<G_N_ELEMENTS(held));held[held_count++]=task; }
}
static void complete_held(void) { for (unsigned i=0;i<held_count;++i) { finish_task(held[i]);g_object_unref(held[i]); }held_count=0;settle(); }
static void close_state(ZwkState *s) { if (s->closed)return;s->closed=TRUE;s->owner=NULL;capture_cancel_all(s);release(s); }
static void notify(void *owner,uint64_t token,int status,const unsigned char *data,size_t size,const ZwkFailure *failure) {
    ZwkState *s=owner;++notifications;last_status=status;last_token=token;
    if (status==ZWK_CAPTURE_OK && !expect_clear) g_assert(size>8 && data[0]==137 && data[1]=='P');else g_assert(size==0);
    if (status==ZWK_CAPTURE_NATIVE) g_assert(failure && failure->domain==G_IO_ERROR && failure->code==G_IO_ERROR_FAILED);
    if (reenter_in_notify) g_assert_cmpint(zwk_capture_start(s,token+100),==,ZWK_FULL);
    if (close_in_notify) { zwk_capture_budget_close(s->capture);close_state(s); }
}
static ZwkState *new_state(ZwkCaptureBudget *b) {
    ZwkState *s=calloc(1,sizeof(*s));s->refs=1;s->thread=g_thread_self();s->view=(GtkWidget *)g_object_new(G_TYPE_OBJECT,NULL);s->owner=s;s->ready=TRUE;++states;
    g_assert_cmpint(zwk_capture_enable(s,b),==,ZWK_OK);return s;
}
static void reset(void) {
    g_assert(!states && !held_count);uint32_t budgets,ops;size_t bytes,peak;zwk_capture_counts(&budgets,&ops,&bytes,&peak);
    g_assert(!budgets && !ops && !bytes);finishes=submissions=notifications=0;allocation_fail=-1;synchronous=fail_native=close_in_notify=reenter_in_notify=expect_clear=FALSE;last_status=-1;last_token=0;
}
static void cold_and_failures(void) {
    reset();allocation_fail=0;g_assert(!zwk_capture_budget_new(1,4096,notify));allocation_fail=-1;
    ZwkCaptureBudget *b=zwk_capture_budget_new(1,4096,notify);ZwkState *s=new_state(b);
    s->ready=FALSE;g_assert_cmpint(zwk_capture_start(s,1),==,ZWK_NOT_READY);s->ready=TRUE;
    allocation_fail=0;g_assert_cmpint(zwk_capture_start(s,1),==,ZWK_OOM);allocation_fail=-1;
    g_assert(!submissions && !notifications && !b->pending && b->bytes==sizeof(*b));
    zwk_capture_budget_close(b);g_assert_cmpint(zwk_capture_start(s,1),==,ZWK_CLOSED);
    ZwkState *fresh=calloc(1,sizeof(*fresh));fresh->thread=g_thread_self();fresh->owner=fresh;
    g_assert_cmpint(zwk_capture_enable(fresh,b),==,ZWK_CLOSED);free(fresh);
    close_state(s);zwk_capture_budget_release(b);reset();
}
static void synchronous_close(void) {
    reset();ZwkCaptureBudget *b=zwk_capture_budget_new(1,4096,notify);ZwkState *s=new_state(b);
    synchronous=close_in_notify=reenter_in_notify=TRUE;
    g_assert_cmpint(zwk_capture_start(s,1),==,ZWK_OK);
    g_assert(finishes==1 && notifications==1);settle();g_assert(!states && !b->pending);
    zwk_capture_budget_release(b);reset();
}
static void quota_and_restart(void) {
    reset();ZwkCaptureBudget *b=zwk_capture_budget_new(1,4096,notify);ZwkState *old=new_state(b);
    g_assert_cmpint(zwk_capture_start(old,1),==,ZWK_OK);zwk_capture_cancel(old,1);
    g_assert_cmpint(zwk_capture_start(old,2),==,ZWK_FULL);
    close_state(old);ZwkState *fresh=new_state(b);
    g_assert_cmpint(zwk_capture_start(fresh,2),==,ZWK_FULL);
    finish_task(held[0]);g_assert(finishes==1 && !notifications && b->pending==1 && b->ops->used==0);
    g_assert_cmpint(zwk_capture_start(fresh,2),==,ZWK_FULL);
    g_object_unref(held[0]);held_count=0;settle();g_assert(!b->pending && states==1);
    synchronous=TRUE;g_assert_cmpint(zwk_capture_start(fresh,2),==,ZWK_OK);g_assert(notifications==1 && last_token==2);settle();
    close_state(fresh);zwk_capture_budget_release(b);reset();
}
static void stream_errors(void) {
    reset();synchronous=TRUE;ZwkCaptureBudget *b=zwk_capture_budget_new(1,8,notify);ZwkState *s=new_state(b);
    g_assert_cmpint(zwk_capture_start(s,1),==,ZWK_OK);g_assert(notifications==1 && last_status==ZWK_CAPTURE_LIMIT);settle();
    g_assert_cmpint(zwk_capture_budget_limit(b,1,4096),==,ZWK_OK);fail_native=TRUE;
    g_assert_cmpint(zwk_capture_start(s,2),==,ZWK_OK);g_assert(notifications==2 && last_status==ZWK_CAPTURE_NATIVE);settle();
    close_state(s);zwk_capture_budget_release(b);reset();
}
static void global_quota_and_close(void) {
    reset();ZwkCaptureBudget *a=zwk_capture_budget_new(8,4096,notify),*b=zwk_capture_budget_new(8,4096,notify);
    ZwkState *old=new_state(a),*fresh=new_state(b);
    for (unsigned i=0;i<8;++i) g_assert_cmpint(zwk_capture_start(old,i+1),==,ZWK_OK);
    zwk_capture_budget_close(a);close_state(old);zwk_capture_budget_release(a);
    g_assert_cmpint(zwk_capture_start(fresh,1),==,ZWK_FULL);
    complete_held();g_assert(finishes==8 && !notifications && states==1);
    synchronous=TRUE;g_assert_cmpint(zwk_capture_start(fresh,1),==,ZWK_OK);g_assert(notifications==1);settle();
    close_state(fresh);zwk_capture_budget_release(b);reset();
}
static void clear_shares_owner(void) {
    reset();expect_clear=TRUE;ZwkCaptureBudget *b=zwk_capture_budget_new(1,4096,notify);ZwkState *s=new_state(b);
    s->ready=FALSE;allocation_fail=0;g_assert_cmpint(zwk_clear_start(s,1),==,ZWK_OOM);allocation_fail=-1;
    g_assert_cmpint(zwk_clear_start(s,1),==,ZWK_OK);g_assert(submissions==1 && b->bytes==sizeof(*b)+sizeof(CaptureOp));
    s->ready=TRUE;g_assert_cmpint(zwk_capture_start(s,2),==,ZWK_FULL);g_assert_cmpint(zwk_clear_start(s,3),==,ZWK_FULL);
    zwk_capture_cancel(s,1);complete_held();g_assert(finishes==1 && !notifications && !b->pending);
    synchronous=TRUE;g_assert_cmpint(zwk_clear_start(s,4),==,ZWK_OK);g_assert(notifications==1 && last_token==4 && last_status==ZWK_CAPTURE_OK);settle();
    fail_native=TRUE;g_assert_cmpint(zwk_clear_start(s,5),==,ZWK_OK);g_assert(notifications==2 && last_status==ZWK_CAPTURE_NATIVE);settle();
    fail_native=FALSE;close_in_notify=TRUE;g_assert_cmpint(zwk_clear_start(s,6),==,ZWK_OK);g_assert(notifications==3);settle();
    g_assert(!states && !b->pending);zwk_capture_budget_release(b);reset();
}
int main(int argc,char **argv) {
    g_test_init(&argc,&argv,NULL);
    g_test_add_func("/capture/cold-allocation-failure",cold_and_failures);
    g_test_add_func("/capture/synchronous-close-reentry",synchronous_close);
    g_test_add_func("/capture/cancel-finalizer-restart",quota_and_restart);
    g_test_add_func("/capture/bounded-stream-real-error",stream_errors);
    g_test_add_func("/capture/process-quota-closed-budget",global_quota_and_close);
    g_test_add_func("/capture/clear-shares-owner",clear_shares_owner);
    return g_test_run();
}
