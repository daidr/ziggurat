#include <glib-object.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include "../src/webview/webkit_native.h"

/* Controlled public-signal double. It never adds an SDK request identity. */
typedef GObject WebKitFindController;
typedef GObject WebKitWebView;
typedef GObject GtkWidget;
#define WEBKIT_WEB_VIEW(value) ((WebKitWebView *)(value))
enum { WEBKIT_FIND_OPTIONS_CASE_INSENSITIVE=1,WEBKIT_FIND_OPTIONS_WRAP_AROUND=16 };
struct ZwkState { GThread *thread;GObject *view;void *owner;ZwkFindGate *find;uint64_t generation;unsigned refs;gboolean closed,ready; };
static unsigned state_count,allocation_index,fail_allocation=UINT32_MAX,connect_index,fail_connection;
static unsigned native_search,native_next,native_previous,native_finish;
static gboolean synchronous,finish_terminal;
static guint native_count=3;
static char captured_term[4097];
static void (*allocation_hook)(void),(*getter_hook)(void),(*after_free_hook)(void);
static void (*document_hook)(ZwkState *);
static void close_state(ZwkState *);
static void retain(ZwkState *s) { g_assert(s->refs);++s->refs; }
static void release(gpointer data) {
    ZwkState *s=data;g_assert(s->refs);if (--s->refs) return;
    g_assert(s->closed && !s->view && !s->find);free(s);--state_count;
}
static gboolean live(ZwkState *s) { return !s->closed && s->owner; }
static gboolean document(ZwkState *s) {
    gboolean ready=live(s) && s->ready;
    if (document_hook) { void (*hook)(ZwkState *)=document_hook;document_hook=NULL;hook(s); }
    return ready;
}
static void *find_test_calloc(size_t count,size_t bytes) {
    unsigned index=allocation_index++;
    if (allocation_hook) { void (*hook)(void)=allocation_hook;allocation_hook=NULL;hook(); }
    return index==fail_allocation?NULL:calloc(count,bytes);
}
static void find_test_free(void *pointer) {
    free(pointer);
    if (after_free_hook) { void (*hook)(void)=after_free_hook;after_free_hook=NULL;hook(); }
}
static gulong find_test_connect(gpointer object,const gchar *name,GClosure *closure,gboolean after) {
    if (++connect_index==fail_connection) return 0;
    return g_signal_connect_closure(object,name,closure,after);
}
static WebKitFindController *webkit_web_view_get_find_controller(WebKitWebView *view) {
    WebKitFindController *controller=g_object_get_data(view,"test-controller");
    if (getter_hook) { void (*hook)(void)=getter_hook;getter_hook=NULL;hook(); }
    return controller;
}
static void webkit_find_controller_search(WebKitFindController *controller,const char *term,uint32_t options,guint maximum) {
    g_assert(options&WEBKIT_FIND_OPTIONS_WRAP_AROUND);g_assert(maximum==INT32_MAX);
    ++native_search;g_assert(strlen(term)<sizeof(captured_term));strcpy(captured_term,term);
    if (synchronous) g_signal_emit_by_name(controller,"found-text",native_count);
}
static void webkit_find_controller_search_next(WebKitFindController *controller) { ++native_next;if (synchronous) g_signal_emit_by_name(controller,"found-text",1u); }
static void webkit_find_controller_search_previous(WebKitFindController *controller) { ++native_previous;if (synchronous) g_signal_emit_by_name(controller,"found-text",1u); }
static void webkit_find_controller_search_finish(WebKitFindController *controller) { ++native_finish;if (finish_terminal) g_signal_emit_by_name(controller,"found-text",native_count); }
#define calloc find_test_calloc
#define free find_test_free
#define g_signal_connect_closure find_test_connect
#include "../src/webview/webkit_find_impl.h"
#undef g_signal_connect_closure
#undef free
#undef calloc

_Static_assert(sizeof(ZwkFindSnapshot)==12,"Find mask ABI");
typedef struct Probe { ZwkState *state;ZwkFindBudget *budget;unsigned calls,kind;int status;uint64_t token;ZwkFindSnapshot snapshot;void (*hook)(struct Probe *);int nested; } Probe;
static GType controller_type;
static Probe *active;
static void notify(void *raw,uint64_t token,int kind,int status,const ZwkFindSnapshot *snapshot) {
    Probe *p=raw;++p->calls;p->kind=(unsigned)kind;p->status=status;p->token=token;p->snapshot=*snapshot;
    if (p->hook) { void (*hook)(Probe *)=p->hook;p->hook=NULL;hook(p); }
}
static ZwkState *new_state(Probe *p) {
    ZwkState *s=calloc(1,sizeof(*s));g_assert(s);++state_count;
    s->thread=g_thread_self();s->refs=1;s->ready=TRUE;s->owner=p;s->generation=1;
    s->view=g_object_new(G_TYPE_OBJECT,NULL);
    g_object_set_data_full(s->view,"test-controller",g_object_new(controller_type,NULL),g_object_unref);
    p->state=s;return s;
}
static WebKitFindController *controller(ZwkState *s) { return g_object_get_data(s->view,"test-controller"); }
static void close_state(ZwkState *s) {
    if (s->closed) return;
    s->closed=TRUE;s->owner=NULL;find_state_close(s);
    GObject *view=s->view;s->view=NULL;g_object_unref(view);release(s);
}
static ZwkFindCommand *prepare(Probe *p) {
    ZwkFindCommand *command=NULL;
    g_assert_cmpint(zwk_find_prepare(p->state,p->budget,notify,"needle",6,5,&command),==,ZWK_OK);return command;
}
static void clean(Probe *p) {
    if (p->state) { close_state(p->state);p->state=NULL; }
    if (p->budget) { zwk_find_budget_close(p->budget);zwk_find_budget_release(p->budget);p->budget=NULL; }
    uint32_t budgets,gates,commands;size_t bytes,peak;zwk_find_counts(&budgets,&gates,&commands,&bytes,&peak);
    g_assert(!budgets && !gates && !commands && !bytes && !state_count);
    synchronous=FALSE;finish_terminal=FALSE;native_count=3;fail_allocation=UINT32_MAX;fail_connection=0;allocation_hook=getter_hook=after_free_hook=NULL;document_hook=NULL;
}
static void baseline(void) {
    Probe p={0};p.budget=zwk_find_budget_new(2);new_state(&p);
    char term[]="needle";ZwkFindCommand *command=NULL;
    g_assert_cmpint(zwk_find_prepare(p.state,p.budget,notify,term,6,5,&command),==,ZWK_OK);term[0]='X';
    synchronous=TRUE;g_assert_cmpint(zwk_find_commit(command,1),==,ZWK_OK);
    g_assert_cmpstr(captured_term,==,"needle");g_assert(p.calls==1 && p.snapshot.known==1 && p.snapshot.matches==3);
    g_assert_cmpint(zwk_find_action(p.state,1,&p.snapshot),==,ZWK_OK);g_assert(p.calls==2 && p.kind==1 && p.snapshot.known==0);
    g_assert_cmpint(zwk_find_action(p.state,2,&p.snapshot),==,ZWK_OK);g_assert(p.calls==3 && p.snapshot.known==0);
    zwk_find_cancel(p.state,1);g_assert(p.state->find->token==0);clean(&p);
}
static void pending_cancel(void) {
    Probe p={0};p.budget=zwk_find_budget_new(2);new_state(&p);
    g_assert_cmpint(zwk_find_commit(prepare(&p),10),==,ZWK_OK);zwk_find_cancel(p.state,10);
    ZwkFindCommand *candidate=NULL;
    g_assert_cmpint(zwk_find_prepare(p.state,p.budget,notify,"next",4,5,&candidate),==,ZWK_FULL);g_assert(!candidate && p.calls==0);
    g_assert(p.budget->command_count==1 && p.state->find->pending);
    g_signal_emit_by_name(controller(p.state),"found-text",3u);
    g_assert(!p.state->find->pending && p.budget->command_count==0 && p.calls==0);
    candidate=prepare(&p);zwk_find_abort(candidate);clean(&p);
}
static void pending_close(void) {
    Probe p={0};p.budget=zwk_find_budget_new(1);new_state(&p);
    g_assert_cmpint(zwk_find_commit(prepare(&p),20),==,ZWK_OK);
    WebKitFindController *extra=g_object_ref(controller(p.state));close_state(p.state);p.state=NULL;
    g_assert(p.budget->gate_count==1 && p.budget->command_count==1);
    g_signal_emit_by_name(extra,"found-text",3u);g_assert(p.calls==0 && p.budget->command_count==1);
    zwk_find_budget_close(p.budget);zwk_find_budget_release(p.budget);p.budget=NULL;
    g_object_unref(extra);clean(&p);
}
static void idle_restart_quota(void) {
    Probe p={0};p.budget=zwk_find_budget_new(1);new_state(&p);synchronous=TRUE;
    g_assert_cmpint(zwk_find_commit(prepare(&p),30),==,ZWK_OK);
    WebKitFindController *extra=g_object_ref(controller(p.state));close_state(p.state);p.state=NULL;
    g_assert(p.budget->gate_count==1 && p.budget->command_count==0);new_state(&p);
    ZwkFindCommand *candidate=NULL;
    g_assert_cmpint(zwk_find_prepare(p.state,p.budget,notify,"next",4,5,&candidate),==,ZWK_FULL);
    g_object_unref(extra);candidate=prepare(&p);zwk_find_abort(candidate);clean(&p);
}
static void close_active(void) { ZwkState *s=active->state;active->state=NULL;close_state(s); }
static void provisional_reentry(void) {
    ZwkFindCommand *candidate=NULL;
    active->nested=zwk_find_prepare(active->state,active->budget,notify,"nested",6,5,&candidate);g_assert(!candidate);
}
static void construction(void) {
    Probe p={0};p.budget=zwk_find_budget_new(2);new_state(&p);active=&p;getter_hook=provisional_reentry;
    ZwkFindCommand *candidate=prepare(&p);g_assert_cmpint(p.nested,==,ZWK_FULL);zwk_find_abort(candidate);clean(&p);
    p=(Probe){0};p.budget=zwk_find_budget_new(2);new_state(&p);active=&p;getter_hook=close_active;
    candidate=NULL;g_assert_cmpint(zwk_find_prepare(p.state,p.budget,notify,"needle",6,5,&candidate),==,ZWK_CLOSED);
    g_assert(!candidate && !state_count);clean(&p);
}
static void failures(void) {
    for (unsigned index=0;index<2;++index) {
        Probe p={0};p.budget=zwk_find_budget_new(2);new_state(&p);allocation_index=0;fail_allocation=index;
        ZwkFindCommand *candidate=NULL;g_assert_cmpint(zwk_find_prepare(p.state,p.budget,notify,"needle",6,5,&candidate),==,ZWK_OOM);
        g_assert(!candidate && !p.calls);clean(&p);
    }
    for (unsigned index=1;index<=2;++index) {
        Probe p={0};p.budget=zwk_find_budget_new(2);new_state(&p);connect_index=0;fail_connection=index;
        ZwkFindCommand *candidate=NULL;g_assert_cmpint(zwk_find_prepare(p.state,p.budget,notify,"needle",6,5,&candidate),==,ZWK_NATIVE_FAILED);
        g_assert(!candidate && !p.calls && !p.state->find);clean(&p);
    }
    Probe p={0};p.budget=zwk_find_budget_new(2);new_state(&p);active=&p;allocation_hook=close_active;
    ZwkFindCommand *candidate=NULL;g_assert_cmpint(zwk_find_prepare(p.state,p.budget,notify,"needle",6,5,&candidate),==,ZWK_CLOSED);g_assert(!candidate);clean(&p);
}
static void try_nested(Probe *p) {
    ZwkFindCommand *candidate=NULL;p->nested=zwk_find_prepare(p->state,p->budget,notify,"nested",6,5,&candidate);g_assert(!candidate);
}
static void close_from_notify(Probe *p) { ZwkState *s=p->state;p->state=NULL;close_state(s); }
static void sync_reentry(void) {
    Probe p={0};p.budget=zwk_find_budget_new(1);new_state(&p);synchronous=TRUE;p.hook=try_nested;
    g_assert_cmpint(zwk_find_commit(prepare(&p),40),==,ZWK_OK);g_assert_cmpint(p.nested,==,ZWK_FULL);
    ZwkFindCommand *candidate=prepare(&p);zwk_find_abort(candidate);clean(&p);
    p=(Probe){0};p.budget=zwk_find_budget_new(2);new_state(&p);synchronous=TRUE;p.hook=close_from_notify;
    g_assert_cmpint(zwk_find_commit(prepare(&p),41),==,ZWK_OK);g_assert(p.calls==1 && !state_count);clean(&p);
}
static void competing_candidates(void) {
    Probe p={0};p.budget=zwk_find_budget_new(3);new_state(&p);
    ZwkFindCommand *old=prepare(&p),*current=prepare(&p);
    g_assert_cmpint(zwk_find_commit(current,51),==,ZWK_OK);
    g_assert_cmpint(zwk_find_commit(old,50),==,ZWK_FULL);g_assert(p.state->find->token==51);
    g_signal_emit_by_name(controller(p.state),"failed-to-find-text");g_assert(p.calls==1 && p.token==51 && p.snapshot.known==1 && p.snapshot.matches==0);
    ZwkFindCommand *candidate=prepare(&p);close_state(p.state);p.state=NULL;
    g_assert_cmpint(zwk_find_commit(candidate,52),==,ZWK_CLOSED);clean(&p);
}
static void free_reentry(void) {
    /* The actual allocation is gone, but the deallocator has not returned.
     * Both its credit and its independent pins must still be in force. */
    g_assert(active->budget->command_count==1);
    try_nested(active);g_assert_cmpint(active->nested,==,ZWK_FULL);
    close_active();
    ZwkFindBudget *budget=active->budget;active->budget=NULL;
    zwk_find_budget_close(budget);zwk_find_budget_release(budget);
}
static void last_free_pins(void) {
    Probe p={0};p.budget=zwk_find_budget_new(1);new_state(&p);active=&p;
    ZwkFindCommand *candidate=prepare(&p);after_free_hook=free_reentry;
    zwk_find_abort(candidate);g_assert(!p.state && !p.budget);clean(&p);
}
static void terminal_edges(void) {
    Probe p={0};p.budget=zwk_find_budget_new(1);new_state(&p);
    g_assert_cmpint(zwk_find_commit(prepare(&p),60),==,ZWK_OK);
    finish_terminal=TRUE;zwk_find_cancel(p.state,60);
    g_assert(!p.calls && !p.state->find->pending && !p.budget->command_count);
    g_signal_emit_by_name(controller(p.state),"failed-to-find-text");g_assert(!p.calls);
    ZwkFindCommand *candidate=prepare(&p);zwk_find_abort(candidate);clean(&p);
    p=(Probe){0};p.budget=zwk_find_budget_new(1);new_state(&p);synchronous=TRUE;native_count=G_MAXUINT;
    g_assert_cmpint(zwk_find_commit(prepare(&p),61),==,ZWK_OK);
    g_assert(p.calls==1 && p.status==1 && p.snapshot.known==0 && p.budget->command_count==0);
    clean(&p);
    allocation_index=0;fail_allocation=0;g_assert(!zwk_find_budget_new(1));fail_allocation=UINT32_MAX;
    g_assert(!zwk_find_budget_new(0) && !zwk_find_budget_new(9));clean(&p);
}
static void close_from_document(ZwkState *s) {
    /* The SDK getter may return bytes borrowing this WebView. Its caller must
     * own both objects through the getter, close, and final view unref. */
    g_assert(s->refs>=2);g_assert(G_OBJECT(s->view)->ref_count>=2);close_active();
}
static void document_ownership(void) {
    Probe p={0};p.budget=zwk_find_budget_new(2);new_state(&p);active=&p;document_hook=close_from_document;
    ZwkFindCommand *candidate=NULL;
    g_assert_cmpint(zwk_find_prepare(p.state,p.budget,notify,"needle",6,5,&candidate),==,ZWK_CLOSED);
    g_assert(!candidate && !p.calls);clean(&p);
    p=(Probe){0};p.budget=zwk_find_budget_new(2);new_state(&p);active=&p;synchronous=TRUE;
    g_assert_cmpint(zwk_find_commit(prepare(&p),70),==,ZWK_OK);document_hook=close_from_document;
    g_assert_cmpint(zwk_find_action(p.state,0,&p.snapshot),==,ZWK_CLOSED);clean(&p);
    p=(Probe){0};p.budget=zwk_find_budget_new(2);new_state(&p);active=&p;
    candidate=prepare(&p);document_hook=close_from_document;
    g_assert_cmpint(zwk_find_commit(candidate,71),==,ZWK_CLOSED);g_assert(!p.calls);clean(&p);
}
int main(void) {
    controller_type=g_type_register_static_simple(G_TYPE_OBJECT,"ZigguratFindDouble",sizeof(GObjectClass),NULL,sizeof(GObject),NULL,0);
    g_signal_new("found-text",controller_type,G_SIGNAL_RUN_LAST,0,NULL,NULL,g_cclosure_marshal_VOID__UINT,G_TYPE_NONE,1,G_TYPE_UINT);
    g_signal_new("failed-to-find-text",controller_type,G_SIGNAL_RUN_LAST,0,NULL,NULL,g_cclosure_marshal_VOID__VOID,G_TYPE_NONE,0);
    baseline();pending_cancel();pending_close();idle_restart_quota();construction();failures();sync_reentry();competing_candidates();last_free_pins();terminal_edges();document_ownership();
    printf("WebKit Find controlled double: 11 groups, owning query/one physical command/cancel/closed last refs/reentry/OOM/partial connect/free-return credit/overflow/document getter pins, resources=0; ABI snapshot=%zu budget=%zu gate=%zu command=%zu\n",sizeof(ZwkFindSnapshot),sizeof(ZwkFindBudget),sizeof(ZwkFindGate),sizeof(ZwkFindCommand));
    return 0;
}
