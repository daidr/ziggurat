/* Optional document-initializer ownership. All callbacks below are C-only;
   no late COM release borrows a Zig allocator or application context. */
#ifndef ZW_INITIALIZERS_TYPES_H
#define ZW_INITIALIZERS_TYPES_H
#include <stddef.h>
#include <stdint.h>
typedef struct InitializerBudget {
    LONG refs;
    size_t limit;
    LONGLONG used, peak;
} InitializerBudget;
static LONG initializer_budgets, initializer_owners, initializer_handlers;
static LONGLONG initializer_bytes;
void zwv_initializer_budget_retain(void *context) {
    InitializerBudget *b=context; InterlockedIncrement(&b->refs);
}
void zwv_initializer_budget_unref(void *context) {
    InitializerBudget *b=context;
    if (!InterlockedDecrement(&b->refs)) {
        /* Every charge has its own owning reference. The domain's own record
           is the final physical allocation, released only at the last ref. */
        if (InterlockedCompareExchange64(&b->used,0,0)!=(LONGLONG)sizeof(*b)) abort();
        InterlockedExchangeAdd64(&initializer_bytes,-(LONGLONG)sizeof(*b));
        free(b); InterlockedDecrement(&initializer_budgets);
    }
}
_Bool zwv_initializer_budget_reserve(void *context,size_t bytes) {
    InitializerBudget *b=context;
    LONGLONG used=InterlockedCompareExchange64(&b->used,0,0),next;
    do {
        if (bytes>b->limit || (uint64_t)used>b->limit-bytes) return 0;
        next=used+(LONGLONG)bytes;
        LONGLONG observed=InterlockedCompareExchange64(&b->used,next,used);
        if (observed==used) break;
        used=observed;
    } while (1);
    LONGLONG peak=InterlockedCompareExchange64(&b->peak,0,0);
    while (peak<next) {
        LONGLONG observed=InterlockedCompareExchange64(&b->peak,next,peak);
        if (observed==peak) break;
        peak=observed;
    }
    InterlockedExchangeAdd64(&initializer_bytes,(LONGLONG)bytes); return 1;
}
void zwv_initializer_budget_release(void *context,size_t bytes) {
    InitializerBudget *b=context;
    LONGLONG previous=InterlockedExchangeAdd64(&b->used,-(LONGLONG)bytes);
    if (previous<(LONGLONG)sizeof(*b) || bytes>(uint64_t)previous-sizeof(*b)) abort();
    InterlockedExchangeAdd64(&initializer_bytes,-(LONGLONG)bytes);
}
void *zwv_initializer_budget_create(size_t limit,HRESULT *out) {
    *out=E_INVALIDARG;
    if (!limit || limit>8u*1024u*1024u) return NULL;
    if (limit<sizeof(InitializerBudget)) { *out=HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA);return NULL; }
    InitializerBudget *b=calloc(1,sizeof(*b)); if (!b) { *out=E_OUTOFMEMORY;return NULL; }
    b->refs=1;b->limit=limit;b->used=sizeof(*b);b->peak=b->used;
    InterlockedIncrement(&initializer_budgets);
    InterlockedExchangeAdd64(&initializer_bytes,(LONGLONG)sizeof(*b));*out=S_OK;return b;
}
size_t zwv_initializer_budget_limit(void *context) { return ((InitializerBudget *)context)->limit; }
void zwv_initializer_counts(uint32_t *budgets,uint32_t *owners,uint32_t *handlers,uint64_t *bytes) {
    *budgets=(uint32_t)InterlockedCompareExchange(&initializer_budgets,0,0);
    *owners=(uint32_t)InterlockedCompareExchange(&initializer_owners,0,0);
    *handlers=(uint32_t)InterlockedCompareExchange(&initializer_handlers,0,0);
    *bytes=(uint64_t)InterlockedCompareExchange64(&initializer_bytes,0,0);
}
/* kind: installed=0, discarded=1, failed=2, removal_uncertain=3.
   Notification occurs only after the physical operation has retired. Extra
   COM refs can retain charged handler/source storage after that notification. */
typedef void (*InitializerNotify)(void *,uint64_t,uint32_t,HRESULT);
typedef struct InitializerInput {
    InitializerBudget *budget;
    const WCHAR *source;
    uint32_t units;
    uint32_t frames;
} InitializerInput;
typedef struct InitializerState InitializerState;
static void initializers_free(InitializerState *);
#endif
