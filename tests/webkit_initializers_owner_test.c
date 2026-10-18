/* Production C owner with controlled SDK registration; this is not an engine
 * injection oracle. The public Zig/TLS fixture separately checks real pages. */
#include <webkit2/webkit2.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include "../src/webview/webkit_native.h"

typedef struct ZwkInitializerState ZwkInitializerState;
struct ZwkState {
    unsigned refs;
    GThread *thread;
    GtkWidget *view;
    WebKitUserContentManager *manager;
    void *owner;
    ZwkInitializerState *initializers;
    void *navigation;
    gboolean closed,recovering,load_started;
};
static unsigned states,adds,removes,notifications;
static int allocation_fail=-1;
static gboolean fail_script,close_on_add,cancel_on_mutation,close_on_notify,reenter_on_notify;
static uint64_t current_token,last_token;
static uint32_t last_kind;
static WebKitUserScript *registered[8];
static unsigned registered_count;
static void initializers_free(ZwkInitializerState *);
static gboolean live(ZwkState *s) { return !s->closed && !s->recovering && s->owner; }
static void retain(ZwkState *s) { g_assert(s->refs);++s->refs; }
static void release(gpointer data) {
    ZwkState *s=data;g_assert(s->refs);
    if(--s->refs)return;
    g_assert(s->closed);initializers_free(s->initializers);
    g_clear_object(&s->manager);free(s);--states;
}
static void *test_malloc(size_t n) { if(allocation_fail==0)return NULL;if(allocation_fail>0)--allocation_fail;return malloc(n); }
static void *test_calloc(size_t n,size_t size) { if(allocation_fail==0)return NULL;if(allocation_fail>0)--allocation_fail;return calloc(n,size); }
static void close_state(ZwkState *s);
static WebKitUserScript *fake_new(const char *source,WebKitUserContentInjectedFrames frames,WebKitUserScriptInjectionTime time,const char *const *allow,const char *const *block) {
    g_assert(source && frames==WEBKIT_USER_CONTENT_INJECT_TOP_FRAME && time==WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START && !allow && !block);
    return fail_script?NULL:webkit_user_script_new(source,frames,time,allow,block);
}
static void fake_add(WebKitUserContentManager *,WebKitUserScript *);
static void fake_remove(WebKitUserContentManager *,WebKitUserScript *);
static gboolean fake_loading(WebKitWebView *view) { (void)view;return FALSE; }
#undef WEBKIT_WEB_VIEW
#define WEBKIT_WEB_VIEW(p) ((WebKitWebView *)(p))
#define webkit_web_view_is_loading fake_loading
#define webkit_user_script_new fake_new
#define webkit_user_content_manager_add_script fake_add
#define webkit_user_content_manager_remove_script fake_remove
#define malloc test_malloc
#define calloc test_calloc
#include "../src/webview/webkit_initializers_impl.h"
#undef malloc
#undef calloc
#undef webkit_user_script_new

static void close_state(ZwkState *s) {
    if(s->closed)return;
    s->closed=TRUE;s->owner=NULL;initializers_cancel_all(s);release(s);
}
static void mutation_probe(WebKitUserContentManager *manager) {
    ZwkState *s=g_object_get_data(G_OBJECT(manager),"test-state");
    if(cancel_on_mutation)g_assert(!zwk_initializers_try_cancel(s,current_token));
    if(close_on_add){close_on_add=FALSE;close_state(s);}
}
static void fake_add(WebKitUserContentManager *manager,WebKitUserScript *script) {
    g_assert(registered_count<G_N_ELEMENTS(registered));
    for(unsigned i=0;i<registered_count;++i)g_assert(registered[i]!=script);
    registered[registered_count++]=webkit_user_script_ref(script);++adds;mutation_probe(manager);
}
static void fake_remove(WebKitUserContentManager *manager,WebKitUserScript *script) {
    unsigned index=0;while(index<registered_count && registered[index]!=script)++index;
    g_assert(index<registered_count);webkit_user_script_unref(registered[index]);
    memmove(registered+index,registered+index+1,(registered_count-index-1)*sizeof(*registered));--registered_count;++removes;mutation_probe(manager);
}
static ZwkState *new_state(void) {
    ZwkState *s=calloc(1,sizeof(*s));s->refs=1;s->thread=g_thread_self();s->owner=s;s->view=(GtkWidget *)s;
    s->manager=(WebKitUserContentManager *)g_object_new(G_TYPE_OBJECT,NULL);g_object_set_data(G_OBJECT(s->manager),"test-state",s);++states;return s;
}
static const uint16_t alpha[]={0x41,0xd83d,0xde00,0x7532,0};
static void done(void *ptr,uint64_t token,uint32_t kind,int32_t code) {
    ZwkState *s=ptr;++notifications;last_token=token;last_kind=kind;
    g_assert(code==ZWK_OK || code==ZWK_NATIVE_FAILED);
    g_assert(!s->initializers->pending);
    if(reenter_on_notify){
        reenter_on_notify=FALSE;
        ZwkInitializerInput input={s->initializers->budget,alpha,4};
        g_assert_cmpint(zwk_initializers_prepare(s,&input,token+1,done),==,ZWK_OK);
        zwk_initializers_activate(s);
    }
    if(close_on_notify){close_on_notify=FALSE;close_state(s);}
}
static void reset(void) {
    g_assert(!states);
    while(registered_count)webkit_user_script_unref(registered[--registered_count]);
    uint32_t budgets,owners,operations;uint64_t bytes;zwk_initializer_counts(&budgets,&owners,&operations,&bytes);
    g_assert(!budgets && !owners && !operations && !bytes);
    adds=removes=notifications=0;allocation_fail=-1;fail_script=close_on_add=cancel_on_mutation=close_on_notify=reenter_on_notify=FALSE;current_token=last_token=0;last_kind=99;
}
static void cold_and_input(void) {
    reset();ZwkState *s=new_state();g_assert(initializers_allow_navigation(s) && !zwk_initializers_blocked(s));close_state(s);reset();
    int32_t status;allocation_fail=0;g_assert(!zwk_initializer_budget_create(4096,&status) && status==ZWK_OOM);allocation_fail=-1;
    g_assert(!zwk_initializer_budget_create(1,&status) && status==ZWK_INITIALIZER_BUDGET);
    void *budget=zwk_initializer_budget_create(4096,&status);g_assert(budget && status==ZWK_OK);s=new_state();
    uint16_t invalid[]={0xd800,0};ZwkInitializerInput input={budget,invalid,1};
    g_assert_cmpint(zwk_initializers_prepare(s,&input,1,done),==,ZWK_INVALID);g_assert(!s->initializers && !adds);
    input=(ZwkInitializerInput){budget,(void *)(uintptr_t)4096,512u*1024u+1};
    g_assert_cmpint(zwk_initializers_prepare(s,&input,1,done),==,ZWK_INVALID);
    close_state(s);zwk_initializer_budget_unref(budget);reset();
}
static void allocation_failures(void) {
    for(int failure=0;failure<3;++failure){
        reset();int32_t status;void *budget=zwk_initializer_budget_create(4096,&status);ZwkState *s=new_state();
        ZwkInitializerInput input={budget,alpha,4};allocation_fail=failure;
        int result=zwk_initializers_prepare(s,&input,1,done);allocation_fail=-1;
        g_assert_cmpint(result,==,ZWK_OOM);g_assert(!adds && !notifications && initializers_allow_navigation(s));
        close_state(s);zwk_initializer_budget_unref(budget);reset();
    }
}
static void capture_cancel_and_clear(void) {
    reset();int32_t status;void *budget=zwk_initializer_budget_create(4096,&status);ZwkState *s=new_state();
    uint16_t text[]={0x41,0xd83d,0xde00,0x7532,0};ZwkInitializerInput input={budget,text,4};
    g_assert_cmpint(zwk_initializers_prepare(s,&input,1,done),==,ZWK_OK);memset(text,0,sizeof(text));
    g_assert_cmpstr(s->initializers->pending->source,==,"A\xf0\x9f\x98\x80\xe7\x94\xb2");
    g_assert(!adds && !notifications && !initializers_allow_navigation(s));
    g_assert_cmpint(zwk_initializers_prepare(s,&input,2,done),==,ZWK_NAVIGATION_PENDING);
    g_assert(zwk_initializers_try_cancel(s,1));zwk_initializers_activate(s);
    g_assert(notifications==1 && last_kind==1 && !adds && initializers_allow_navigation(s));
    input=(ZwkInitializerInput){budget,alpha,4};g_assert_cmpint(zwk_initializers_prepare(s,&input,2,done),==,ZWK_OK);zwk_initializers_activate(s);
    g_assert(notifications==2 && last_kind==0 && adds==1 && registered_count==1);
    input.source=NULL;input.units=0;current_token=3;cancel_on_mutation=TRUE;
    g_assert_cmpint(zwk_initializers_prepare(s,&input,3,done),==,ZWK_OK);zwk_initializers_activate(s);
    g_assert(notifications==3 && last_kind==0 && removes==1 && !registered_count);close_state(s);zwk_initializer_budget_unref(budget);reset();
}
static void install_failure_and_abandon(void) {
    reset();int32_t status;void *budget=zwk_initializer_budget_create(4096,&status);ZwkState *s=new_state();ZwkInitializerInput input={budget,alpha,4};
    g_assert_cmpint(zwk_initializers_prepare(s,&input,1,done),==,ZWK_OK);zwk_initializers_abandon(s);g_assert(!notifications && initializers_allow_navigation(s));
    g_assert_cmpint(zwk_initializers_prepare(s,&input,2,done),==,ZWK_OK);zwk_initializers_activate(s);WebKitUserScript *old=s->initializers->current;
    g_assert_cmpint(zwk_initializers_prepare(s,&input,3,done),==,ZWK_OK);fail_script=TRUE;zwk_initializers_activate(s);fail_script=FALSE;
    g_assert(notifications==2 && last_kind==2 && s->initializers->current==old && registered_count==1 && !removes);
    close_state(s);zwk_initializer_budget_unref(budget);reset();
}
static void mutation_close(void) {
    reset();int32_t status;void *budget=zwk_initializer_budget_create(4096,&status);ZwkState *s=new_state();ZwkInitializerInput input={budget,alpha,4};
    g_assert_cmpint(zwk_initializers_prepare(s,&input,1,done),==,ZWK_OK);close_on_add=TRUE;cancel_on_mutation=TRUE;current_token=1;zwk_initializers_activate(s);
    g_assert(!states && !notifications && adds==1 && removes==1 && !registered_count);zwk_initializer_budget_unref(budget);reset();
}
static void synchronous_reentry_close(void) {
    reset();int32_t status;void *budget=zwk_initializer_budget_create(4096,&status);ZwkState *s=new_state();ZwkInitializerInput input={budget,alpha,4};
    g_assert_cmpint(zwk_initializers_prepare(s,&input,1,done),==,ZWK_OK);reenter_on_notify=close_on_notify=TRUE;zwk_initializers_activate(s);
    g_assert(!states && notifications==2 && last_token==2 && last_kind==0);zwk_initializer_budget_unref(budget);reset();
}
static void shared_budget_and_initial_close(void) {
    reset();int32_t status;ZwkInitializerBudget *budget=zwk_initializer_budget_create(512,&status);ZwkState *s=new_state();
    ZwkInitializerInput input={budget,alpha,4};g_assert_cmpint(zwk_initializers_prepare(s,&input,0,NULL),==,ZWK_OK);
    close_state(s);g_assert(!states && !adds && !notifications && atomic_load(&budget->used)==sizeof(*budget));
    size_t held=budget->limit-sizeof(*budget);g_assert(zwk_initializer_budget_reserve(budget,held));
    s=new_state();g_assert_cmpint(zwk_initializers_prepare(s,&input,1,done),==,ZWK_INITIALIZER_BUDGET);
    g_assert(!s->initializers && !adds && !notifications);close_state(s);zwk_initializer_budget_release(budget,held);
    s=new_state();g_assert_cmpint(zwk_initializers_prepare(s,&input,0,NULL),==,ZWK_OK);fail_script=TRUE;zwk_initializers_activate(s);fail_script=FALSE;
    g_assert(zwk_initializers_blocked(s) && !initializers_allow_navigation(s) && !notifications && !adds);
    close_state(s);zwk_initializer_budget_unref(budget);reset();
}
int main(void) {
    cold_and_input();allocation_failures();capture_cancel_and_clear();install_failure_and_abandon();mutation_close();synchronous_reentry_close();shared_budget_and_initial_close();
    g_print("Linux initializer C owner 7/7 groups: exact UTF conversion, budget/OOM, commit/cancel, individual identity and reentry/close\n");
    g_print("Initializer native layout: budget=%zu owner=%zu operation=%zu input=%zu (SDK script storage excluded)\n",sizeof(ZwkInitializerBudget),sizeof(ZwkInitializerState),sizeof(ZwkInitializerOperation),sizeof(ZwkInitializerInput));return 0;
}
