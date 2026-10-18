/* Optional trusted future-document registrations. Included after ZwkState and
 * its C-only pin helpers. No GSource, worker, engine ACK or Zig allocator. */
typedef struct ZwkInitializerBudget {
    atomic_uint refs;
    size_t limit;
    _Atomic size_t used,peak;
} ZwkInitializerBudget;
typedef struct ZwkInitializerOperation ZwkInitializerOperation;
typedef struct ZwkInitializerState {
    ZwkInitializerBudget *budget;
    WebKitUserScript *current;
    ZwkInitializerOperation *pending;
    gboolean blocked;
} ZwkInitializerState;
struct ZwkInitializerOperation {
    ZwkState *state;
    ZwkInitializerBudget *budget;
    ZwkInitializerNotify notify;
    uint64_t token;
    char *source;
    size_t bytes;
    gboolean submitted,cancelled;
};
static atomic_uint initializer_budgets,initializer_owners,initializer_operations;
static _Atomic size_t initializer_bytes;

void zwk_initializer_budget_retain(void *context) {
    ZwkInitializerBudget *budget=context;g_assert(atomic_fetch_add(&budget->refs,1));
}
void zwk_initializer_budget_unref(void *context) {
    ZwkInitializerBudget *budget=context;
    if(atomic_fetch_sub(&budget->refs,1)!=1)return;
    g_assert(atomic_load(&budget->used)==sizeof(*budget));
    atomic_fetch_sub(&initializer_bytes,sizeof(*budget));free(budget);atomic_fetch_sub(&initializer_budgets,1);
}
_Bool zwk_initializer_budget_reserve(void *context,size_t bytes) {
    ZwkInitializerBudget *budget=context;size_t used=atomic_load(&budget->used),next;
    do {
        if(bytes>budget->limit || used>budget->limit-bytes)return FALSE;
        next=used+bytes;
    }while(!atomic_compare_exchange_weak(&budget->used,&used,next));
    size_t peak=atomic_load(&budget->peak);
    while(peak<next && !atomic_compare_exchange_weak(&budget->peak,&peak,next)){}
    atomic_fetch_add(&initializer_bytes,bytes);return TRUE;
}
void zwk_initializer_budget_release(void *context,size_t bytes) {
    ZwkInitializerBudget *budget=context;size_t before=atomic_fetch_sub(&budget->used,bytes);
    g_assert(before>=sizeof(*budget) && bytes<=before-sizeof(*budget));atomic_fetch_sub(&initializer_bytes,bytes);
}
void *zwk_initializer_budget_create(size_t limit,int32_t *status) {
    *status=ZWK_INVALID;
    if(!limit || limit>8u*1024u*1024u)return NULL;
    if(limit<sizeof(ZwkInitializerBudget)){*status=ZWK_INITIALIZER_BUDGET;return NULL;}
    ZwkInitializerBudget *budget=calloc(1,sizeof(*budget));if(!budget){*status=ZWK_OOM;return NULL;}
    atomic_init(&budget->refs,1);budget->limit=limit;atomic_init(&budget->used,sizeof(*budget));atomic_init(&budget->peak,sizeof(*budget));
    atomic_fetch_add(&initializer_budgets,1);atomic_fetch_add(&initializer_bytes,sizeof(*budget));*status=ZWK_OK;return budget;
}
size_t zwk_initializer_budget_limit(void *context) { return ((ZwkInitializerBudget *)context)->limit; }
void zwk_initializer_counts(uint32_t *budgets,uint32_t *owners,uint32_t *operations,uint64_t *bytes) {
    *budgets=atomic_load(&initializer_budgets);*owners=atomic_load(&initializer_owners);*operations=atomic_load(&initializer_operations);*bytes=atomic_load(&initializer_bytes);
}
static void initializers_free(ZwkInitializerState *owner) {
    if(!owner)return;
    g_assert(!owner->pending);ZwkInitializerBudget *budget=owner->budget;
    if(owner->current)webkit_user_script_unref(owner->current);
    free(owner);zwk_initializer_budget_release(budget,sizeof(*owner));atomic_fetch_sub(&initializer_owners,1);zwk_initializer_budget_unref(budget);
}
static int initializers_owner(ZwkState *s,ZwkInitializerBudget *budget) {
    if(s->initializers)return s->initializers->budget==budget?ZWK_OK:ZWK_INVALID;
    if(!zwk_initializer_budget_reserve(budget,sizeof(ZwkInitializerState)))return ZWK_INITIALIZER_BUDGET;
    ZwkInitializerState *owner=calloc(1,sizeof(*owner));
    if(!owner){zwk_initializer_budget_release(budget,sizeof(*owner));return ZWK_OOM;}
    zwk_initializer_budget_retain(budget);owner->budget=budget;s->initializers=owner;atomic_fetch_add(&initializer_owners,1);return ZWK_OK;
}
static gboolean initializers_allow_navigation(ZwkState *s) {
    return !s->initializers || (!s->initializers->pending && !s->initializers->blocked);
}
_Bool zwk_initializers_blocked(ZwkState *s) { return s->initializers && s->initializers->blocked; }
static void initializer_operation_free(ZwkInitializerOperation *op) {
    ZwkState *s=op->state;ZwkInitializerBudget *budget=op->budget;size_t bytes=op->bytes;
    free(op->source);free(op);zwk_initializer_budget_release(budget,bytes);atomic_fetch_sub(&initializer_operations,1);
    release(s);zwk_initializer_budget_unref(budget);
}
/* A bounded exact conversion of the existing compiler's UTF-16, including
 * surrogate pairs. No locale conversion, replacement character or new guard. */
static gboolean initializer_scalar(const uint16_t *source,uint32_t units,uint32_t *index,uint32_t *scalar) {
    uint32_t value=source[(*index)++];
    if(!value || (value>=0xdc00 && value<=0xdfff))return FALSE;
    if(value>=0xd800 && value<=0xdbff){
        if(*index==units)return FALSE;
        uint32_t low=source[(*index)++];if(low<0xdc00 || low>0xdfff)return FALSE;
        value=0x10000+((value-0xd800)<<10)+(low-0xdc00);
    }
    *scalar=value;return TRUE;
}
int zwk_initializers_prepare(ZwkState *s,const ZwkInitializerInput *input,uint64_t token,ZwkInitializerNotify done) {
    if(!live(s))return ZWK_CLOSED;
    if(!input || !input->budget)return ZWK_INVALID;
    if(!initializers_allow_navigation(s))return ZWK_NAVIGATION_PENDING;
    if(token && (!s->view || !s->manager || s->navigation || s->load_started || webkit_web_view_is_loading(WEBKIT_WEB_VIEW(s->view))))return ZWK_NAVIGATION_PENDING;
    if(input->units>512u*1024u || (!input->source && input->units))return ZWK_INVALID;
    size_t length=0;
    if(input->source){
        if(input->source[input->units])return ZWK_INVALID;
        for(uint32_t index=0;index<input->units;){
            uint32_t scalar;if(!initializer_scalar(input->source,input->units,&index,&scalar))return ZWK_INVALID;
            length+=scalar<0x80?1:scalar<0x800?2:scalar<0x10000?3:4;
        }
        ++length;
    }
    int result=initializers_owner(s,input->budget);if(result!=ZWK_OK)return result;
    size_t bytes=sizeof(ZwkInitializerOperation)+length;
    if(!zwk_initializer_budget_reserve(input->budget,bytes))return ZWK_INITIALIZER_BUDGET;
    ZwkInitializerOperation *op=calloc(1,sizeof(*op));
    if(!op){zwk_initializer_budget_release(input->budget,bytes);return ZWK_OOM;}
    if(length){
        op->source=malloc(length);
        if(!op->source){free(op);zwk_initializer_budget_release(input->budget,bytes);return ZWK_OOM;}
        char *out=op->source;
        for(uint32_t index=0;index<input->units;){
            uint32_t scalar;gboolean valid=initializer_scalar(input->source,input->units,&index,&scalar);g_assert(valid);
            if(scalar<0x80)*out++=(char)scalar;
            else if(scalar<0x800){*out++=(char)(0xc0|(scalar>>6));*out++=(char)(0x80|(scalar&63));}
            else if(scalar<0x10000){*out++=(char)(0xe0|(scalar>>12));*out++=(char)(0x80|((scalar>>6)&63));*out++=(char)(0x80|(scalar&63));}
            else {*out++=(char)(0xf0|(scalar>>18));*out++=(char)(0x80|((scalar>>12)&63));*out++=(char)(0x80|((scalar>>6)&63));*out++=(char)(0x80|(scalar&63));}
        }
        *out=0;g_assert((size_t)(out-op->source)+1==length);
    }
    op->state=s;op->budget=input->budget;op->token=token;op->notify=done;op->bytes=bytes;
    retain(s);zwk_initializer_budget_retain(op->budget);s->initializers->pending=op;atomic_fetch_add(&initializer_operations,1);return ZWK_OK;
}
void zwk_initializers_abandon(ZwkState *s) {
    ZwkInitializerOperation *op=s->initializers?s->initializers->pending:NULL;
    if(!op || op->submitted)return;
    s->initializers->pending=NULL;initializer_operation_free(op);
}
void zwk_initializers_cancel(ZwkState *s,uint64_t token) {
    ZwkInitializerOperation *op=s->initializers?s->initializers->pending:NULL;
    if(op && op->token==token)op->cancelled=TRUE;
}
_Bool zwk_initializers_try_cancel(ZwkState *s,uint64_t token) {
    ZwkInitializerOperation *op=s->initializers?s->initializers->pending:NULL;
    if(!op || op->token!=token || op->submitted || op->cancelled)return FALSE;
    op->cancelled=TRUE;return TRUE;
}
static void initializers_cancel_all(ZwkState *s) {
    ZwkInitializerOperation *op=s->initializers?s->initializers->pending:NULL;
    if(!op)return;
    op->cancelled=TRUE;
    if(!op->submitted){s->initializers->pending=NULL;initializer_operation_free(op);}
}
void zwk_initializers_activate(ZwkState *s) {
    ZwkInitializerOperation *op=s->initializers?s->initializers->pending:NULL;
    if(!op || op->submitted)return;
    retain(s);ZwkInitializerState *owner=s->initializers;uint32_t kind=1;int32_t result=ZWK_OK;
    WebKitUserScript *candidate=NULL;WebKitUserContentManager *manager=NULL;
    if(live(s) && !op->cancelled){
        manager=g_object_ref(s->manager);
        if(op->source)candidate=webkit_user_script_new(op->source,WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,NULL,NULL);
        if(op->source && !candidate){kind=2;result=ZWK_NATIVE_FAILED;}
        else {
            /* Both Add and individual Remove are synchronous void calls. The
             * irreversible registration boundary precedes their first call. */
            op->submitted=TRUE;
            if(candidate)webkit_user_content_manager_add_script(manager,candidate);
            if(live(s) && !op->cancelled){
                WebKitUserScript *old=owner->current;owner->current=candidate;candidate=NULL;
                if(old){webkit_user_content_manager_remove_script(manager,old);webkit_user_script_unref(old);}
                kind=0;
            }else if(candidate)webkit_user_content_manager_remove_script(manager,candidate);
        }
    }
    if(candidate)webkit_user_script_unref(candidate);
    if(manager)g_object_unref(manager);
    owner->pending=NULL;
    const uint64_t token=op->token;ZwkInitializerNotify done=op->notify;
    /* Retire the physical source and slot before a completion can close or
     * synchronously replace again. Only this C state pin spans the callback. */
    initializer_operation_free(op);
    if(live(s) && token && done)done(s->owner,token,kind,result);
    else if(!token && kind!=0 && live(s))owner->blocked=TRUE;
    release(s);
}
