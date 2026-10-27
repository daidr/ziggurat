#ifndef ZIGGURAT_WEBKIT_CAPTURE_IMPL_H
#define ZIGGURAT_WEBKIT_CAPTURE_IMPL_H

#define CAPTURE_PENDING 8u
#define CAPTURE_BYTES (16u*1024u*1024u)
typedef struct CaptureOp CaptureOp;
struct ZwkCaptureBudget {
    GThread *thread;
    CaptureOp *ops;
    ZwkCaptureNotify notify;
    size_t bytes,peak;
    unsigned refs,pending,limit,capacity;
    gboolean closed;
};
struct CaptureOp {
    CaptureOp *next;
    ZwkState *state;
    GCancellable *cancel;
    uint64_t token;
    size_t capacity,used;
    gboolean cancelled,overflow;
    /* PDF: the print operation, its failure, and the backgrounds setting it
     * replaced for its run. */
    WebKitPrintOperation *print;
    GError *failure;
    gboolean backgrounds;
};
/* Whole-data clear shares this physical owner: same pending quota, Zig owner
 * revocation and GTask-lifetime pinning, with no PNG capacity. */
static _Atomic uint32_t capture_budgets,capture_operations;
static _Atomic size_t capture_bytes,capture_peak;
static void capture_account(size_t amount) {
    size_t current=atomic_fetch_add_explicit(&capture_bytes,amount,memory_order_relaxed)+amount;
    size_t peak=atomic_load_explicit(&capture_peak,memory_order_relaxed);
    while (peak<current && !atomic_compare_exchange_weak_explicit(&capture_peak,&peak,current,memory_order_relaxed,memory_order_relaxed)) { }
}
static void capture_budget_ref(ZwkCaptureBudget *b) { g_assert(b->thread==g_thread_self() && b->refs);++b->refs; }
void zwk_capture_budget_release(ZwkCaptureBudget *b) {
    g_assert(b->thread==g_thread_self() && b->refs);
    if (--b->refs) return;
    g_assert(!b->ops && !b->pending && b->bytes==sizeof(*b));
    atomic_fetch_sub_explicit(&capture_budgets,1,memory_order_relaxed);
    atomic_fetch_sub_explicit(&capture_bytes,sizeof(*b),memory_order_relaxed);free(b);
}
ZwkCaptureBudget *zwk_capture_budget_new(uint32_t pending,uint32_t bytes,ZwkCaptureNotify notify) {
    if (!pending || pending>CAPTURE_PENDING || !bytes || bytes>CAPTURE_BYTES || !notify) return NULL;
    ZwkCaptureBudget *b=calloc(1,sizeof(*b));if (!b) return NULL;
    b->thread=g_thread_self();b->refs=1;b->limit=pending;b->capacity=bytes;b->notify=notify;b->bytes=b->peak=sizeof(*b);
    atomic_fetch_add_explicit(&capture_budgets,1,memory_order_relaxed);capture_account(sizeof(*b));return b;
}
int zwk_capture_budget_limit(ZwkCaptureBudget *b,uint32_t pending,uint32_t bytes) {
    if (!b || b->thread!=g_thread_self() || !pending || pending>CAPTURE_PENDING || !bytes || bytes>CAPTURE_BYTES) return ZWK_INVALID;
    if (b->closed) return ZWK_CLOSED;
    b->limit=pending;b->capacity=bytes;return ZWK_OK;
}
static void capture_cancel_budget(ZwkCaptureBudget *b,ZwkState *state,uint64_t token) {
    GCancellable *cancels[CAPTURE_PENDING];unsigned count=0;
    capture_budget_ref(b);
    /* Revoke the whole selected set before calling foreign cancellation. No Op
     * pointer is used after that boundary, even if finish runs synchronously. */
    for (CaptureOp *op=b->ops;op;op=op->next) if ((!state || op->state==state) && (!token || op->token==token)) {
        op->cancelled=TRUE;cancels[count++]=g_object_ref(op->cancel);
    }
    for (unsigned i=0;i<count;++i) { g_cancellable_cancel(cancels[i]);g_object_unref(cancels[i]); }
    zwk_capture_budget_release(b);
}
void zwk_capture_budget_close(ZwkCaptureBudget *b) {
    g_assert(b->thread==g_thread_self());b->closed=TRUE;capture_cancel_budget(b,NULL,0);
}
int zwk_capture_enable(ZwkState *s,ZwkCaptureBudget *b) {
    if (!s || !b || s->thread!=g_thread_self() || b->thread!=s->thread) return ZWK_INVALID;
    if (!live(s) || b->closed) return ZWK_CLOSED;
    if (s->capture) return ZWK_INVALID;
    capture_budget_ref(b);s->capture=b;return ZWK_OK;
}
static void capture_state_clear(ZwkState *s) {
    ZwkCaptureBudget *b=s->capture;s->capture=NULL;if (b) zwk_capture_budget_release(b);
}
static void capture_cancel_all(ZwkState *s) {
    if (s->capture) capture_cancel_budget(s->capture,s,0);
}
void zwk_capture_cancel(ZwkState *s,uint64_t token) {
    g_assert(s->thread==g_thread_self());if (s->capture) capture_cancel_budget(s->capture,s,token);
}
static void capture_finalized(gpointer data) {
    CaptureOp *op=data;ZwkState *s=op->state;ZwkCaptureBudget *b=s->capture;
    g_assert(s->thread==g_thread_self() && b && b->pending);
    CaptureOp **link=&b->ops;while (*link && *link!=op) link=&(*link)->next;
    g_assert(*link==op);*link=op->next;--b->pending;
    const size_t bytes=sizeof(*op)+op->capacity;b->bytes-=bytes;
    atomic_fetch_sub_explicit(&capture_operations,1,memory_order_relaxed);
    atomic_fetch_sub_explicit(&capture_bytes,bytes,memory_order_relaxed);
    g_object_unref(op->cancel);free(op);release(s);
}
static cairo_status_t capture_write(void *raw,const unsigned char *data,unsigned int length) {
    CaptureOp *op=raw;
    if ((size_t)length>op->capacity-op->used) { op->overflow=TRUE;return CAIRO_STATUS_WRITE_ERROR; }
    memcpy((unsigned char *)(op+1)+op->used,data,length);op->used+=length;return CAIRO_STATUS_SUCCESS;
}
static void capture_finished(GObject *object,GAsyncResult *result,gpointer data) {
    CaptureOp *op=data;ZwkState *s=op->state;ZwkCaptureBudget *b=s->capture;
    g_assert(s->thread==g_thread_self() && G_IS_TASK(result));
    GError *error=NULL;
    cairo_surface_t *surface=webkit_web_view_get_snapshot_finish(WEBKIT_WEB_VIEW(object),result,&error);
    int status=ZWK_CAPTURE_OK;
    if (error) status=ZWK_CAPTURE_NATIVE;
    else if (!surface || cairo_surface_status(surface)!=CAIRO_STATUS_SUCCESS) status=ZWK_CAPTURE_INVALID;
    /* A cancelled result is still finished/destroyed, but never encoded. */
    if (!op->cancelled && !b->closed && live(s) && status==ZWK_CAPTURE_OK) {
        const cairo_status_t encoded=cairo_surface_write_to_png_stream(surface,capture_write,op);
        if (op->overflow) status=ZWK_CAPTURE_LIMIT;
        else if (encoded==CAIRO_STATUS_NO_MEMORY) status=ZWK_CAPTURE_OOM;
        else if (encoded!=CAIRO_STATUS_SUCCESS) status=ZWK_CAPTURE_INVALID;
    }
    if (surface) cairo_surface_destroy(surface);
    if (!op->cancelled && !b->closed && live(s) && b->notify) {
        const ZwkFailure failure=error?(ZwkFailure){error->domain,error->code}:(ZwkFailure){0};
        b->notify(s->owner,op->token,status,(const unsigned char *)(op+1),status==ZWK_CAPTURE_OK?op->used:0,error?&failure:NULL);
    }
    if (error) g_error_free(error);
    /* GTask retains its WebView source until after this callback. Keep the Op,
     * stable budget and C state until result finalization, with no Zig owner. */
    GQuark key=g_quark_from_static_string("ziggurat-capture-operation-result");
    g_assert(!g_object_get_qdata(G_OBJECT(result),key));
    g_object_set_qdata_full(G_OBJECT(result),key,op,capture_finalized);
}
int zwk_capture_start(ZwkState *s,uint64_t token) {
    if (!s || s->thread!=g_thread_self() || !token) return ZWK_INVALID;
    if (!live(s)) return ZWK_CLOSED;
    ZwkCaptureBudget *b=s->capture;
    if (!b || b->closed) return ZWK_CLOSED;
    if (!document(s)) return ZWK_NOT_READY;
    if (b->pending>=b->limit || atomic_load_explicit(&capture_operations,memory_order_relaxed)>=CAPTURE_PENDING) return ZWK_FULL;
    for (CaptureOp *at=b->ops;at;at=at->next) if (at->token==token) return ZWK_INVALID;
    const size_t bytes=sizeof(CaptureOp)+b->capacity;
    CaptureOp *op=malloc(bytes);if (!op) return ZWK_OOM;
    memset(op,0,sizeof(*op));op->state=s;op->token=token;op->capacity=b->capacity;op->cancel=g_cancellable_new();
    /* Publish both physical quotas before a potentially synchronous callback.
     * No Op read or failing branch follows the native acceptance boundary. */
    op->next=b->ops;b->ops=op;++b->pending;b->bytes+=bytes;if (b->bytes>b->peak) b->peak=b->bytes;
    atomic_fetch_add_explicit(&capture_operations,1,memory_order_relaxed);capture_account(bytes);retain(s);
    retain(s);
    webkit_web_view_get_snapshot(WEBKIT_WEB_VIEW(s->view),WEBKIT_SNAPSHOT_REGION_VISIBLE,WEBKIT_SNAPSHOT_OPTIONS_NONE,op->cancel,capture_finished,op);
    release(s);return ZWK_OK;
}
static void clear_finished(GObject *object,GAsyncResult *result,gpointer data) {
    CaptureOp *op=data;ZwkState *s=op->state;ZwkCaptureBudget *b=s->capture;
    g_assert(s->thread==g_thread_self() && G_IS_TASK(result));
    GError *error=NULL;
    const gboolean cleared=webkit_website_data_manager_clear_finish(WEBKIT_WEBSITE_DATA_MANAGER(object),result,&error);
    const int status=error?ZWK_CAPTURE_NATIVE:cleared?ZWK_CAPTURE_OK:ZWK_CAPTURE_INVALID;
    if (!op->cancelled && !b->closed && live(s) && b->notify) {
        const ZwkFailure failure=error?(ZwkFailure){error->domain,error->code}:(ZwkFailure){0};
        b->notify(s->owner,op->token,status,(const unsigned char *)(op+1),0,error?&failure:NULL);
    }
    if (error) g_error_free(error);
    GQuark key=g_quark_from_static_string("ziggurat-capture-operation-result");
    g_assert(!g_object_get_qdata(G_OBJECT(result),key));
    g_object_set_qdata_full(G_OBJECT(result),key,op,capture_finalized);
}
/* Clears every data type of the WebView's own data manager, for all time. A
 * persistent Profile is shared with every View and Store using it. */
int zwk_clear_start(ZwkState *s,uint64_t token) {
    if (!s || s->thread!=g_thread_self() || !token) return ZWK_INVALID;
    if (!live(s)) return ZWK_CLOSED;
    ZwkCaptureBudget *b=s->capture;
    if (!b || b->closed) return ZWK_CLOSED;
    if (b->pending>=b->limit || atomic_load_explicit(&capture_operations,memory_order_relaxed)>=CAPTURE_PENDING) return ZWK_FULL;
    for (CaptureOp *at=b->ops;at;at=at->next) if (at->token==token) return ZWK_INVALID;
    WebKitWebsiteDataManager *manager=webkit_web_view_get_website_data_manager(WEBKIT_WEB_VIEW(s->view));
    if (!manager) return ZWK_NATIVE_FAILED;
    CaptureOp *op=malloc(sizeof(CaptureOp));if (!op) return ZWK_OOM;
    memset(op,0,sizeof(*op));op->state=s;op->token=token;op->cancel=g_cancellable_new();
    op->next=b->ops;b->ops=op;++b->pending;b->bytes+=sizeof(*op);if (b->bytes>b->peak) b->peak=b->bytes;
    atomic_fetch_add_explicit(&capture_operations,1,memory_order_relaxed);capture_account(sizeof(*op));retain(s);
    retain(s);
    webkit_website_data_manager_clear(manager,WEBKIT_WEBSITE_DATA_ALL,0,op->cancel,clear_finished,op);
    release(s);return ZWK_OK;
}
static const unsigned char pdf_empty=0;
static gboolean pdf_release(gpointer print) {
    g_object_unref(print);return G_SOURCE_REMOVE;
}
static void pdf_failed(WebKitPrintOperation *print,GError *error,gpointer data) {
    CaptureOp *op=data;(void)print;
    if (!op->failure) op->failure=g_error_copy(error);
}
static void pdf_finished(WebKitPrintOperation *print,gpointer data) {
    CaptureOp *op=data;ZwkState *s=op->state;ZwkCaptureBudget *b=s->capture;
    g_assert(s->thread==g_thread_self());
    g_signal_handlers_disconnect_by_data(print,op);
    WebKitSettings *settings=live(s)?webkit_web_view_get_settings(WEBKIT_WEB_VIEW(s->view)):NULL;
    if (settings) webkit_settings_set_print_backgrounds(settings,op->backgrounds);
    /* The file is complete, so the Op ends before the notification and the
     * caller may start another PDF from it. */
    const uint64_t token=op->token;const gboolean cancelled=op->cancelled;GError *error=op->failure;
    retain(s);capture_budget_ref(b);capture_finalized(op);
    if (!cancelled && !b->closed && live(s) && b->notify) {
        const ZwkFailure failure=error?(ZwkFailure){error->domain,error->code}:(ZwkFailure){0};
        b->notify(s->owner,token,error?ZWK_CAPTURE_NATIVE:ZWK_CAPTURE_OK,&pdf_empty,0,error?&failure:NULL);
    }
    if (error) g_error_free(error);
    zwk_capture_budget_release(b);release(s);
    /* The operation is still emitting; drop it afterwards. */
    g_idle_add_full(G_PRIORITY_DEFAULT,pdf_release,print,NULL);
}
/* Prints through GTK's file printer, which writes the PDF itself. One PDF runs
 * at a time per WebView, since it changes the shared backgrounds setting. */
int zwk_pdf_start(ZwkState *s,uint64_t token,const char *path,const ZwkPdfRequest *request) {
    if (!s || s->thread!=g_thread_self() || !token || !path || !g_path_is_absolute(path) || !request || !request->first_page) return ZWK_INVALID;
    if (request->last_page && request->last_page<request->first_page) return ZWK_INVALID;
    if (!live(s)) return ZWK_CLOSED;
    ZwkCaptureBudget *b=s->capture;
    if (!b || b->closed) return ZWK_CLOSED;
    if (!document(s)) return ZWK_NOT_READY;
    if (b->pending>=b->limit || atomic_load_explicit(&capture_operations,memory_order_relaxed)>=CAPTURE_PENDING) return ZWK_FULL;
    for (CaptureOp *at=b->ops;at;at=at->next) {
        if (at->token==token) return ZWK_INVALID;
        if (at->state==s && at->print) return ZWK_FULL;
    }
    WebKitSettings *settings=webkit_web_view_get_settings(WEBKIT_WEB_VIEW(s->view));
    if (!settings) return ZWK_NATIVE_FAILED;
    char *uri=g_filename_to_uri(path,NULL,NULL);if (!uri) return ZWK_INVALID;
    GtkPrintSettings *print_settings=gtk_print_settings_new();
    gtk_print_settings_set_printer(print_settings,"Print to File");
    gtk_print_settings_set(print_settings,GTK_PRINT_SETTINGS_OUTPUT_FILE_FORMAT,"pdf");
    gtk_print_settings_set(print_settings,GTK_PRINT_SETTINGS_OUTPUT_URI,uri);g_free(uri);
    if (request->first_page>1 || request->last_page) {
        GtkPageRange range={(gint)request->first_page-1,request->last_page?(gint)request->last_page-1:G_MAXINT/2};
        gtk_print_settings_set_print_pages(print_settings,GTK_PRINT_PAGES_RANGES);
        gtk_print_settings_set_page_ranges(print_settings,&range,1);
    }
    GtkPaperSize *paper=gtk_paper_size_new_custom("ziggurat","Custom",request->page[0],request->page[1],GTK_UNIT_INCH);
    GtkPageSetup *setup=gtk_page_setup_new();
    gtk_page_setup_set_paper_size(setup,paper);
    gtk_print_settings_set_paper_size(print_settings,paper);gtk_paper_size_free(paper);
    const GtkPageOrientation orientation=(request->flags&1)?GTK_PAGE_ORIENTATION_LANDSCAPE:GTK_PAGE_ORIENTATION_PORTRAIT;
    gtk_page_setup_set_orientation(setup,orientation);gtk_print_settings_set_orientation(print_settings,orientation);
    gtk_page_setup_set_top_margin(setup,request->page[2],GTK_UNIT_INCH);
    gtk_page_setup_set_right_margin(setup,request->page[3],GTK_UNIT_INCH);
    gtk_page_setup_set_bottom_margin(setup,request->page[4],GTK_UNIT_INCH);
    gtk_page_setup_set_left_margin(setup,request->page[5],GTK_UNIT_INCH);
    CaptureOp *op=malloc(sizeof(CaptureOp));
    if (!op) { g_object_unref(setup);g_object_unref(print_settings);return ZWK_OOM; }
    memset(op,0,sizeof(*op));op->state=s;op->token=token;op->cancel=g_cancellable_new();
    op->print=webkit_print_operation_new(WEBKIT_WEB_VIEW(s->view));
    webkit_print_operation_set_print_settings(op->print,print_settings);
    webkit_print_operation_set_page_setup(op->print,setup);
    g_object_unref(setup);g_object_unref(print_settings);
    g_signal_connect(op->print,"failed",G_CALLBACK(pdf_failed),op);
    g_signal_connect(op->print,"finished",G_CALLBACK(pdf_finished),op);
    op->backgrounds=webkit_settings_get_print_backgrounds(settings);
    webkit_settings_set_print_backgrounds(settings,(request->flags&2)!=0);
    op->next=b->ops;b->ops=op;++b->pending;b->bytes+=sizeof(*op);if (b->bytes>b->peak) b->peak=b->bytes;
    atomic_fetch_add_explicit(&capture_operations,1,memory_order_relaxed);capture_account(sizeof(*op));retain(s);
    retain(s);
    webkit_print_operation_print(op->print);
    release(s);return ZWK_OK;
}
void zwk_capture_counts(uint32_t *budgets,uint32_t *operations,size_t *bytes,size_t *peak) {
    if (budgets) *budgets=atomic_load_explicit(&capture_budgets,memory_order_relaxed);
    if (operations) *operations=atomic_load_explicit(&capture_operations,memory_order_relaxed);
    if (bytes) *bytes=atomic_load_explicit(&capture_bytes,memory_order_relaxed);
    if (peak) *peak=atomic_load_explicit(&capture_peak,memory_order_relaxed);
}
#endif
