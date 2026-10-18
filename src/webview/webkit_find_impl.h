#ifndef ZIGGURAT_WEBKIT_FIND_IMPL_H
#define ZIGGURAT_WEBKIT_FIND_IMPL_H

#define FIND_LIMIT 8u
#define FIND_TERM_BYTES 4096u
enum { FIND_START, FIND_NEXT, FIND_PREVIOUS };
struct ZwkFindBudget {
    GThread *thread;
    ZwkFindGate *gates;
    unsigned refs,limit,gate_count,command_count;
    size_t bytes,peak;
    gboolean closed;
};
struct ZwkFindGate {
    ZwkFindGate *next;
    ZwkFindBudget *budget;
    ZwkState *state; /* Borrowed only while State owns its Gate ref. */
    WebKitFindController *controller; /* No reverse owning edge to qdata. */
    ZwkFindNotify notify;
    ZwkFindCommand *pending;
    ZwkFindSnapshot snapshot;
    gulong found,failed;
    uint64_t token;
    unsigned refs;
    gboolean closed,initializing,in_list,finish_requested;
};
struct ZwkFindCommand {
    ZwkFindGate *gate;
    ZwkState *state;
    ZwkFindBudget *budget;
    uint64_t token;
    size_t bytes;
    uint32_t flags;
    unsigned refs,kind;
    gboolean cancelled;
    /* Start owns the UTF-8 query directly after this record. */
};
static _Atomic uint32_t find_budgets,find_gates,find_commands;
static _Atomic size_t find_bytes,find_peak;
static void find_gate_close(ZwkFindGate *);
static void find_command_unref(ZwkFindCommand *);
static GQuark find_key(void) { return g_quark_from_static_string("ziggurat-find-gate-v1"); }
static void find_account(ZwkFindBudget *b,size_t bytes) {
    b->bytes+=bytes;if (b->bytes>b->peak) b->peak=b->bytes;
    size_t current=atomic_fetch_add_explicit(&find_bytes,bytes,memory_order_relaxed)+bytes;
    size_t peak=atomic_load_explicit(&find_peak,memory_order_relaxed);
    while (peak<current && !atomic_compare_exchange_weak_explicit(&find_peak,&peak,current,memory_order_relaxed,memory_order_relaxed)) { }
}
static void find_credit(ZwkFindBudget *b,size_t bytes) {
    g_assert(b->bytes>=bytes);b->bytes-=bytes;
    atomic_fetch_sub_explicit(&find_bytes,bytes,memory_order_relaxed);
}
static void find_budget_ref(ZwkFindBudget *b) { g_assert(b->thread==g_thread_self() && b->refs);++b->refs; }
void zwk_find_budget_release(ZwkFindBudget *b) {
    g_assert(b->thread==g_thread_self() && b->refs);
    if (--b->refs) return;
    g_assert(!b->gates && !b->gate_count && !b->command_count && b->bytes==sizeof(*b));
    size_t bytes=sizeof(*b);free(b);
    atomic_fetch_sub_explicit(&find_budgets,1,memory_order_relaxed);
    atomic_fetch_sub_explicit(&find_bytes,bytes,memory_order_relaxed);
}
ZwkFindBudget *zwk_find_budget_new(uint32_t limit) {
    if (!limit || limit>FIND_LIMIT) return NULL;
    ZwkFindBudget *b=calloc(1,sizeof(*b));if (!b) return NULL;
    b->thread=g_thread_self();b->refs=1;b->limit=limit;
    atomic_fetch_add_explicit(&find_budgets,1,memory_order_relaxed);find_account(b,sizeof(*b));return b;
}
int zwk_find_budget_limit(ZwkFindBudget *b,uint32_t limit) {
    if (!b || b->thread!=g_thread_self() || !limit || limit>FIND_LIMIT) return ZWK_INVALID;
    if (b->closed) return ZWK_CLOSED;b->limit=limit;return ZWK_OK;
}
static void find_gate_ref(ZwkFindGate *g) { g_assert(g->refs);++g->refs; }
static void find_gate_unlink(ZwkFindGate *g) {
    if (!g->in_list) return;
    ZwkFindGate **link=&g->budget->gates;
    while (*link && *link!=g) link=&(*link)->next;
    g_assert(*link==g);*link=g->next;g->in_list=FALSE;
}
static void find_gate_unref(ZwkFindGate *g) {
    g_assert(g->refs);if (--g->refs) return;
    g_assert(g->closed && !g->pending && !g->state && !g->controller && !g->found && !g->failed);
    ZwkFindBudget *b=g->budget;find_gate_unlink(g);
    /* Keep this Gate's credit and independent domain ref through foreign free. */
    free(g);--b->gate_count;find_credit(b,sizeof(*g));
    atomic_fetch_sub_explicit(&find_gates,1,memory_order_relaxed);zwk_find_budget_release(b);
}
static void find_command_ref(ZwkFindCommand *command) { g_assert(command->refs);++command->refs; }
static void find_command_unref(ZwkFindCommand *command) {
    g_assert(command->refs);if (--command->refs) return;
    ZwkFindBudget *b=command->budget;ZwkFindGate *g=command->gate;ZwkState *s=command->state;size_t bytes=command->bytes;
    /* No Gate or State slot still owns this record. All pins survive the actual
     * deallocator return; neither App nor a retired Zig View is consulted. */
    free(command);--b->command_count;find_credit(b,bytes);
    atomic_fetch_sub_explicit(&find_commands,1,memory_order_relaxed);
    find_gate_unref(g);release(s);zwk_find_budget_release(b);
}
static void find_closure_destroy(gpointer data,GClosure *closure) { (void)closure;find_gate_unref(data); }
static void find_qdata_destroy(gpointer data) {
    ZwkFindGate *g=data;
    g_assert(g->closed && !g->state && !g->controller && !g->found && !g->failed);
    /* Break pending Command -> Gate -> pending Command before releasing qdata.
     * This is C storage retirement, never a query completion notification. */
    find_gate_unlink(g);ZwkFindCommand *command=g->pending;g->pending=NULL;
    if (command) find_command_unref(command);
    find_gate_unref(g);
}
static void find_terminal(ZwkFindGate *g,gboolean found,guint count) {
    find_gate_ref(g);
    if (g->closed || !g->pending) { find_gate_unref(g);return; }
    ZwkFindCommand *command=g->pending;g->pending=NULL;
    ZwkState *s=command->state;
    ZwkFindSnapshot snapshot={0,0,0};int status=0;
    if (command->kind==FIND_START) {
        if (found && count>INT32_MAX) status=1;
        else { snapshot.known=1;snapshot.matches=found?(int32_t)count:0; }
    }
    g->snapshot=snapshot;
    if (!command->cancelled && !g->budget->closed && live(s) && g->state==s && g->token==command->token && g->notify) {
        ZwkFindNotify notify=g->notify;void *owner=s->owner;
        notify(owner,command->token,command->kind==FIND_START?0:1,status,&snapshot);
    }
    /* Completion may have replaced the scene or destroyed its parent. */
    find_command_unref(command);find_gate_unref(g);
}
static void find_found(WebKitFindController *controller,guint count,gpointer data) {
    g_object_ref(controller);find_terminal(data,TRUE,count);g_object_unref(controller);
}
static void find_failed(WebKitFindController *controller,gpointer data) {
    g_object_ref(controller);find_terminal(data,FALSE,0);g_object_unref(controller);
}
static gulong find_connect(ZwkFindGate *g,WebKitFindController *controller,const char *name,GCallback callback) {
    find_gate_ref(g);
    GClosure *closure=g_cclosure_new(callback,g,find_closure_destroy);
    g_closure_ref(closure);g_closure_sink(closure);
    gulong id=g_signal_connect_closure(controller,name,closure,FALSE);
    g_closure_unref(closure);return id;
}
static void find_gate_close(ZwkFindGate *g) {
    find_gate_ref(g);
    if (g->closed) { find_gate_unref(g);return; }
    g->closed=TRUE;g->notify=NULL;
    ZwkState *s=g->state;g->state=NULL;
    gboolean state_owned=s && s->find==g;
    if (state_owned) s->find=NULL;
    WebKitFindController *controller=g->controller;g->controller=NULL;
    if (controller) g_object_ref(controller);
    gboolean stop=g->token && !g->finish_requested;g->token=0;g->finish_requested=TRUE;
    if (g->pending) g->pending->cancelled=TRUE;
    gulong found=g->found,failed=g->failed;g->found=g->failed=0;
    if (controller) {
        if (stop) webkit_find_controller_search_finish(controller);
        if (found) g_signal_handler_disconnect(controller,found);
        if (failed) g_signal_handler_disconnect(controller,failed);
        g_object_unref(controller);
    }
    if (state_owned) find_gate_unref(g);
    find_gate_unref(g);
}
static void find_state_close(ZwkState *s) { if (s->find) find_gate_close(s->find); }
/* Caller holds State and, when supplied, Gate pins. document() consumes the
 * SDK's borrowed URI while the saved WebView still has this independent ref.
 * Its last foreign unref may close/replace the scene, so inspect only pinned
 * C records afterward; never keep URI bytes beyond that boundary. */
static int find_document_status(ZwkState *s,ZwkFindGate *g) {
    if (!live(s) || !s->view || (g && (g->closed || g->budget->closed || s->find!=g))) return ZWK_CLOSED;
    const uint64_t generation=s->generation;
    WebKitWebView *view=g_object_ref(WEBKIT_WEB_VIEW(s->view));
    gboolean ready=document(s);
    g_object_unref(view);
    if (!live(s) || s->view!=(GtkWidget *)view || (g && (g->closed || g->budget->closed || s->find!=g))) return ZWK_CLOSED;
    return ready && s->generation==generation?ZWK_OK:ZWK_NOT_READY;
}
void zwk_find_budget_close(ZwkFindBudget *b) {
    g_assert(b->thread==g_thread_self());find_budget_ref(b);b->closed=TRUE;
    ZwkFindGate *gates[FIND_LIMIT];unsigned count=0;
    for (ZwkFindGate *g=b->gates;g;g=g->next) { g_assert(count<FIND_LIMIT);find_gate_ref(g);gates[count++]=g; }
    for (unsigned i=0;i<count;++i) { find_gate_close(gates[i]);find_gate_unref(gates[i]); }
    zwk_find_budget_release(b);
}
static int find_gate_get(ZwkState *s,ZwkFindBudget *b,ZwkFindNotify notify,ZwkFindGate **out) {
    if (s->find) {
        ZwkFindGate *g=s->find;
        if (g->initializing) return ZWK_FULL;
        if (g->budget!=b || g->notify!=notify) return ZWK_INVALID;
        if (g->closed) return ZWK_CLOSED;
        find_gate_ref(g);*out=g;return ZWK_OK;
    }
    if (b->gate_count>=b->limit) return ZWK_FULL;
    ++b->gate_count;find_budget_ref(b);
    ZwkFindGate *g=calloc(1,sizeof(*g));
    if (!g) { --b->gate_count;zwk_find_budget_release(b);return ZWK_OOM; }
    g->budget=b;g->refs=1;g->closed=TRUE;
    g->next=b->gates;b->gates=g;g->in_list=TRUE;
    atomic_fetch_add_explicit(&find_gates,1,memory_order_relaxed);find_account(b,sizeof(*g));
    if (!live(s) || b->closed || s->find) { find_gate_unref(g);return live(s)&&!b->closed?ZWK_FULL:ZWK_CLOSED; }
    g->closed=FALSE;g->initializing=TRUE;g->state=s;g->notify=notify;s->find=g;
    find_gate_ref(g); /* Constructor pin, distinct from State ownership. */
    WebKitWebView *view=g_object_ref(WEBKIT_WEB_VIEW(s->view));
    WebKitFindController *controller=webkit_web_view_get_find_controller(view);
    if (controller) g_object_ref(controller);
    g_object_unref(view);
    int status=ZWK_OK;
    if (!controller) status=ZWK_NATIVE_FAILED;
    else if (g->closed || !live(s) || s->find!=g || b->closed) status=ZWK_CLOSED;
    else if (g_object_get_qdata(G_OBJECT(controller),find_key())) status=ZWK_INVALID;
    if (status==ZWK_OK) {
        g->controller=controller;find_gate_ref(g);
        g_object_set_qdata_full(G_OBJECT(controller),find_key(),g,find_qdata_destroy);
        gulong id=find_connect(g,controller,"found-text",G_CALLBACK(find_found));
        if (g->closed || !live(s) || s->find!=g || b->closed) {
            if (id) g_signal_handler_disconnect(controller,id);status=ZWK_CLOSED;
        } else if (!id) status=ZWK_NATIVE_FAILED;
        else g->found=id;
        if (status==ZWK_OK) {
            id=find_connect(g,controller,"failed-to-find-text",G_CALLBACK(find_failed));
            if (g->closed || !live(s) || s->find!=g || b->closed) {
                if (id) g_signal_handler_disconnect(controller,id);status=ZWK_CLOSED;
            } else if (!id) status=ZWK_NATIVE_FAILED;
            else g->failed=id;
        }
    }
    if (status!=ZWK_OK) {
        find_gate_close(g);
        if (controller && g_object_get_qdata(G_OBJECT(controller),find_key())==g) {
            g_object_steal_qdata(G_OBJECT(controller),find_key());find_qdata_destroy(g);
        }
    } else { g->initializing=FALSE;*out=g; }
    if (controller) g_object_unref(controller);
    if (status!=ZWK_OK) find_gate_unref(g);
    /* Success transfers the constructor pin to the caller, including across
     * the foreign controller unref above. Caller must recheck closed state. */
    return status;
}
static int find_command_new(ZwkState *s,ZwkFindGate *g,const char *term,size_t length,uint32_t flags,unsigned kind,ZwkFindCommand **out) {
    ZwkFindBudget *b=g->budget;
    if (g->closed || b->closed || !live(s) || s->find!=g) return ZWK_CLOSED;
    if (g->pending || b->command_count>=b->limit) return ZWK_FULL;
    ++b->command_count;find_budget_ref(b);find_gate_ref(g);retain(s);
    const size_t bytes=sizeof(ZwkFindCommand)+(kind==FIND_START?length+1:0);
    ZwkFindCommand *command=calloc(1,bytes);
    if (!command) { --b->command_count;find_gate_unref(g);release(s);zwk_find_budget_release(b);return ZWK_OOM; }
    command->gate=g;command->state=s;command->budget=b;command->refs=1;command->bytes=bytes;command->flags=flags;command->kind=kind;
    if (kind==FIND_START) memcpy(command+1,term,length);
    atomic_fetch_add_explicit(&find_commands,1,memory_order_relaxed);find_account(b,bytes);
    if (g->closed || b->closed || !live(s) || s->find!=g) { find_command_unref(command);return ZWK_CLOSED; }
    if (g->pending) { find_command_unref(command);return ZWK_FULL; }
    *out=command;return ZWK_OK;
}
int zwk_find_prepare(ZwkState *s,ZwkFindBudget *b,ZwkFindNotify notify,const char *term,size_t length,uint32_t flags,ZwkFindCommand **out) {
    if (!s || !b || !out || !notify || s->thread!=g_thread_self() || b->thread!=s->thread) return ZWK_INVALID;
    *out=NULL;
    if (!live(s) || b->closed) return ZWK_CLOSED;
    if (!term || !length || length>FIND_TERM_BYTES || memchr(term,0,length) || !g_utf8_validate(term,(gssize)length,NULL) || (flags&~7u) || (flags&2u) || !(flags&4u)) return ZWK_INVALID;
    retain(s);find_budget_ref(b);
    ZwkFindGate *g=NULL;int status=find_document_status(s,NULL);
    if (status==ZWK_OK && b->closed) status=ZWK_CLOSED;
    if (status==ZWK_OK) status=find_gate_get(s,b,notify,&g);
    if (status==ZWK_OK) {
        status=find_command_new(s,g,term,length,flags,FIND_START,out);
        find_gate_unref(g);
    }
    release(s);zwk_find_budget_release(b);return status;
}
void zwk_find_abort(ZwkFindCommand *command) { find_command_unref(command); }
int zwk_find_commit(ZwkFindCommand *command,uint64_t token) {
    ZwkFindGate *g=command->gate;ZwkState *s=command->state;
    int status=ZWK_OK;
    if (!token) status=ZWK_INVALID;
    else if (g->closed || command->budget->closed || !live(s) || s->find!=g) status=ZWK_CLOSED;
    else status=find_document_status(s,g);
    if (status==ZWK_OK && g->pending) status=ZWK_FULL;
    if (status==ZWK_OK && command->kind!=FIND_START && g->token!=token) status=ZWK_NOT_READY;
    if (status!=ZWK_OK) { find_command_unref(command);return status; }
    command->token=token;g->pending=command;g->snapshot=(ZwkFindSnapshot){0,0,0};
    if (command->kind==FIND_START) { g->token=token;g->finish_requested=FALSE; }
    find_command_ref(command);
    WebKitFindController *controller=g_object_ref(g->controller);
    if (command->kind==FIND_START) {
        uint32_t options=WEBKIT_FIND_OPTIONS_WRAP_AROUND;
        if (!(command->flags&1u)) options|=WEBKIT_FIND_OPTIONS_CASE_INSENSITIVE;
        webkit_find_controller_search(controller,(const char *)(command+1),options,INT32_MAX);
    } else if (command->kind==FIND_NEXT) webkit_find_controller_search_next(controller);
    else webkit_find_controller_search_previous(controller);
    g_object_unref(controller);find_command_unref(command);return ZWK_OK;
}
int zwk_find_action(ZwkState *s,int action,ZwkFindSnapshot *out) {
    if (!s || s->thread!=g_thread_self() || action<0 || action>2) return ZWK_INVALID;
    if (!live(s)) return ZWK_CLOSED;
    ZwkFindGate *g=s->find;
    if (!g || g->closed || !g->token) return ZWK_NOT_READY;
    retain(s);find_gate_ref(g);
    uint64_t token=g->token;
    int status=find_document_status(s,g);
    if (status==ZWK_OK && g->token!=token) status=ZWK_NOT_READY;
    if (status==ZWK_OK && action==0) {
        if (!out) status=ZWK_INVALID;else *out=g->snapshot;
    } else if (status==ZWK_OK) {
        ZwkFindCommand *command=NULL;status=find_command_new(s,g,NULL,0,0,action==1?FIND_NEXT:FIND_PREVIOUS,&command);
        if (status==ZWK_OK) status=zwk_find_commit(command,token);
    }
    find_gate_unref(g);release(s);return status;
}
void zwk_find_cancel(ZwkState *s,uint64_t token) {
    g_assert(s->thread==g_thread_self());ZwkFindGate *g=s->find;
    if (!g || g->closed || g->token!=token || !token) return;
    find_gate_ref(g);g->token=0;g->snapshot=(ZwkFindSnapshot){0,0,0};
    if (g->pending && g->pending->token==token) g->pending->cancelled=TRUE;
    gboolean stop=!g->finish_requested;g->finish_requested=TRUE;
    WebKitFindController *controller=g_object_ref(g->controller);
    if (stop) webkit_find_controller_search_finish(controller);
    g_object_unref(controller);find_gate_unref(g);
}
void zwk_find_counts(uint32_t *budgets,uint32_t *gates,uint32_t *commands,size_t *bytes,size_t *peak) {
    if (budgets) *budgets=atomic_load_explicit(&find_budgets,memory_order_relaxed);
    if (gates) *gates=atomic_load_explicit(&find_gates,memory_order_relaxed);
    if (commands) *commands=atomic_load_explicit(&find_commands,memory_order_relaxed);
    if (bytes) *bytes=atomic_load_explicit(&find_bytes,memory_order_relaxed);
    if (peak) *peak=atomic_load_explicit(&find_peak,memory_order_relaxed);
}
#endif
