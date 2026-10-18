#include "linux_internal.h"
#include <assert.h>
#include <stddef.h>
#include <string.h>

struct ZdaAccount {
    atomic_uint refs;
    atomic_bool closed;
    uint64_t limit;
    atomic_uint_fast64_t bytes, peak, host_bytes;
    atomic_uint counts[ZDA_KIND_COUNT];
    uint32_t range_limit;
};
typedef union LinuxBlock {
    struct { ZdaAccount *account; size_t bytes; uint32_t kind; } value;
    max_align_t alignment;
} LinuxBlock;
static atomic_uint live_accounts, live_blocks;
static atomic_uint_fast64_t live_bytes;
#ifdef ZDA_LINUX_TESTING
static int fail_after=-1;
void zda_linux_test_fail_after(int value) { fail_after=value; }
#endif
void *zda_linux_allocate(size_t bytes) {
#ifdef ZDA_LINUX_TESTING
    if (fail_after==0) { fail_after=-1; return NULL; }
    if (fail_after>0) --fail_after;
#endif
    return g_try_malloc(bytes);
}
static void peak(ZdaAccount *account, uint64_t bytes) {
    uint_fast64_t previous=atomic_load(&account->peak);
    while (previous<bytes && !atomic_compare_exchange_weak(&account->peak,&previous,bytes)) {}
}
static int reserve(ZdaAccount *account, size_t bytes) {
    uint_fast64_t previous=atomic_load(&account->bytes);
    do {
        if (previous>account->limit || bytes>account->limit-previous) return ZDA_CAPACITY;
    } while (!atomic_compare_exchange_weak(&account->bytes,&previous,previous+bytes));
    peak(account,previous+bytes);
    return ZDA_OK;
}
int zda_account_create(uint64_t limit, uint32_t ranges, ZdaAccount **out) {
    if (!out) return ZDA_INVALID;
    *out=NULL;
    if (limit<sizeof(ZdaAccount) || limit>UINT64_C(1073741824) || !ranges || ranges>65536) return ZDA_INVALID;
    ZdaAccount *account=zda_linux_allocate(sizeof(*account));
    if (!account) return ZDA_OOM;
    memset(account,0,sizeof(*account));
    atomic_init(&account->refs,1); atomic_init(&account->closed,false);
    atomic_init(&account->bytes,sizeof(*account)); atomic_init(&account->peak,sizeof(*account));
    atomic_init(&account->host_bytes,0);
    for (unsigned i=0;i<ZDA_KIND_COUNT;++i) atomic_init(&account->counts[i],0);
    account->limit=limit; account->range_limit=ranges;
    atomic_fetch_add(&live_accounts,1); atomic_fetch_add(&live_bytes,sizeof(*account));
    *out=account; return ZDA_OK;
}
void zda_account_retain(ZdaAccount *account) { atomic_fetch_add(&account->refs,1); }
void zda_account_close(ZdaAccount *account) { atomic_store(&account->closed,true); }
void zda_account_release(ZdaAccount *account) {
    if (atomic_fetch_sub(&account->refs,1)!=1) return;
    assert(atomic_load(&account->bytes)==sizeof(*account));
    g_free(account); atomic_fetch_sub(&live_accounts,1); atomic_fetch_sub(&live_bytes,sizeof(ZdaAccount));
}
void zda_account_stats(ZdaAccount *account, ZdaStats *out) {
    out->bytes=atomic_load(&account->bytes); out->peak_bytes=atomic_load(&account->peak);
    out->byte_limit=account->limit; out->host_bytes=atomic_load(&account->host_bytes);
    out->states=atomic_load(&account->counts[ZDA_STATE]); out->providers=atomic_load(&account->counts[ZDA_PROVIDER]);
    out->ranges=0; out->blobs=atomic_load(&account->counts[ZDA_BLOB]); out->range_limit=account->range_limit;
}
size_t zda_storage_footprint(size_t bytes) { return bytes>SIZE_MAX-sizeof(LinuxBlock)?0:sizeof(LinuxBlock)+bytes; }
int zda_account_reserve_host(ZdaAccount *account, size_t bytes) {
    if (!bytes) return ZDA_INVALID;
    zda_account_retain(account);
    if (atomic_load(&account->closed)) { zda_account_release(account); return ZDA_CLOSED; }
    int result=reserve(account,bytes);
    if (result) { zda_account_release(account); return result; }
    atomic_fetch_add(&account->host_bytes,bytes); atomic_fetch_add(&live_bytes,bytes);
    return ZDA_OK;
}
void zda_account_release_host(ZdaAccount *account, size_t bytes) {
    assert(bytes);
    atomic_fetch_sub(&account->host_bytes,bytes); atomic_fetch_sub(&account->bytes,bytes);
    atomic_fetch_sub(&live_bytes,bytes); zda_account_release(account);
}
int zda_storage_create(ZdaAccount *account, uint32_t kind, size_t payload, void **out) {
    if (!out) return ZDA_INVALID;
    *out=NULL;
    if (kind>=ZDA_KIND_COUNT || kind==ZDA_RANGE) return ZDA_INVALID;
    size_t bytes=zda_storage_footprint(payload);
    if (!bytes) return ZDA_CAPACITY;
    zda_account_retain(account);
    if (atomic_load(&account->closed)) { zda_account_release(account); return ZDA_CLOSED; }
    int result=reserve(account,bytes);
    if (result) { zda_account_release(account); return result; }
    LinuxBlock *block=zda_linux_allocate(bytes);
    if (!block) { atomic_fetch_sub(&account->bytes,bytes); zda_account_release(account); return ZDA_OOM; }
    block->value.account=account; block->value.bytes=bytes; block->value.kind=kind;
    atomic_fetch_add(&account->counts[kind],1); atomic_fetch_add(&live_blocks,1); atomic_fetch_add(&live_bytes,bytes);
    *out=block+1; return ZDA_OK;
}
void zda_storage_release(void *ptr) {
    if (!ptr) return;
    LinuxBlock *block=(LinuxBlock *)ptr-1;
    ZdaAccount *account=block->value.account;
    size_t bytes=block->value.bytes; uint32_t kind=block->value.kind;
    g_free(block); atomic_fetch_sub(&account->bytes,bytes); atomic_fetch_sub(&account->counts[kind],1);
    atomic_fetch_sub(&live_blocks,1); atomic_fetch_sub(&live_bytes,bytes); zda_account_release(account);
}
/* A GObject is not allocated by our fallible block allocator. Charge the known
 * instance size once, report its two roles, and keep physical block counts
 * separate. SDK private data/name/relations/class metadata remain SDK costs. */
int zda_linux_object_reserve(ZdaAccount *account, size_t bytes) {
    if (atomic_load(&account->closed)) return ZDA_CLOSED;
    int result=reserve(account,bytes);
    if (result) return result;
    atomic_fetch_add(&account->counts[ZDA_STATE],1); atomic_fetch_add(&account->counts[ZDA_PROVIDER],1);
    atomic_fetch_add(&live_bytes,bytes); return ZDA_OK;
}
void zda_linux_object_release(ZdaAccount *account, size_t bytes) {
    atomic_fetch_sub(&account->counts[ZDA_STATE],1); atomic_fetch_sub(&account->counts[ZDA_PROVIDER],1);
    atomic_fetch_sub(&account->bytes,bytes); atomic_fetch_sub(&live_bytes,bytes);
}
void zda_ledger_counts(uint32_t *accounts, uint32_t *blocks, uint64_t *bytes) {
    *accounts=atomic_load(&live_accounts); *blocks=atomic_load(&live_blocks); *bytes=atomic_load(&live_bytes);
}
