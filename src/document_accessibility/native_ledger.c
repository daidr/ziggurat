#define WIN32_LEAN_AND_MEAN
#define NO_STRICT
#include <windows.h>
#include <objbase.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <assert.h>
#include "native_ledger.h"

struct ZdaAccount {
    volatile LONG refs, closed;
    uint64_t limit;
    volatile LONG64 bytes, peak, host_bytes;
    volatile LONG counts[ZDA_KIND_COUNT];
    uint32_t range_limit;
};
typedef union Block {
    struct { ZdaAccount *account; size_t bytes; uint32_t kind; } value;
    max_align_t alignment;
} Block;
static volatile LONG live_accounts, live_blocks;
static volatile LONG64 live_bytes;
static uint64_t load64(volatile LONG64 *value) {
    return (uint64_t)InterlockedCompareExchange64(value, 0, 0);
}
static void peak(ZdaAccount *account, uint64_t bytes) {
    uint64_t previous = load64(&account->peak);
    while (previous < bytes) {
        uint64_t observed = (uint64_t)InterlockedCompareExchange64(&account->peak, (LONG64)bytes, (LONG64)previous);
        if (observed == previous) break;
        previous = observed;
    }
}
int zda_account_create(uint64_t limit, uint32_t ranges, ZdaAccount **out) {
    if (!out) return ZDA_INVALID;
    *out = NULL;
    if (limit < sizeof(ZdaAccount) || limit > UINT64_C(1073741824) || !ranges || ranges > 65536) return ZDA_INVALID;
    ZdaAccount *account = CoTaskMemAlloc(sizeof(*account));
    if (!account) return ZDA_OOM;
    memset(account, 0, sizeof(*account));
    account->refs = 1;
    account->limit = limit;
    account->bytes = account->peak = sizeof(*account);
    account->range_limit = ranges;
    InterlockedIncrement(&live_accounts);
    InterlockedExchangeAdd64(&live_bytes, sizeof(*account));
    *out = account;
    return ZDA_OK;
}
void zda_account_close(ZdaAccount *account) { InterlockedExchange(&account->closed, 1); }
void zda_account_retain(ZdaAccount *account) { InterlockedIncrement(&account->refs); }
void zda_account_release(ZdaAccount *account) {
    if (!InterlockedDecrement(&account->refs)) {
        assert(load64(&account->bytes) == sizeof(*account));
        CoTaskMemFree(account);
        InterlockedDecrement(&live_accounts);
        InterlockedExchangeAdd64(&live_bytes, -(LONG64)sizeof(ZdaAccount));
    }
}
void zda_account_stats(ZdaAccount *account, ZdaStats *out) {
    out->bytes = load64(&account->bytes);
    out->peak_bytes = load64(&account->peak);
    out->byte_limit = account->limit;
    out->host_bytes = load64(&account->host_bytes);
    out->states = (uint32_t)InterlockedCompareExchange(&account->counts[ZDA_STATE], 0, 0);
    out->providers = (uint32_t)InterlockedCompareExchange(&account->counts[ZDA_PROVIDER], 0, 0);
    out->ranges = (uint32_t)InterlockedCompareExchange(&account->counts[ZDA_RANGE], 0, 0);
    out->blobs = (uint32_t)InterlockedCompareExchange(&account->counts[ZDA_BLOB], 0, 0);
    out->range_limit = account->range_limit;
}
size_t zda_storage_footprint(size_t bytes) { return bytes > SIZE_MAX - sizeof(Block) ? 0 : sizeof(Block) + bytes; }
ZdaAccount *zda_storage_account(const void *pointer) {
    return pointer?((const Block *)pointer-1)->value.account:NULL;
}
static BOOL reserve_bytes(ZdaAccount *account, size_t bytes) {
    uint64_t previous = load64(&account->bytes);
    for (;;) {
        if (previous > account->limit || bytes > account->limit - previous) return FALSE;
        uint64_t observed = (uint64_t)InterlockedCompareExchange64(&account->bytes, (LONG64)(previous + bytes), (LONG64)previous);
        if (observed == previous) break;
        previous = observed;
    }
    peak(account, previous + bytes);
    return TRUE;
}
int zda_account_reserve_host(ZdaAccount *account, size_t bytes) {
    if (!bytes) return ZDA_INVALID;
    zda_account_retain(account);
    if (InterlockedCompareExchange(&account->closed, 0, 0)) { zda_account_release(account); return ZDA_CLOSED; }
    if (!reserve_bytes(account, bytes)) { zda_account_release(account); return ZDA_CAPACITY; }
    InterlockedExchangeAdd64(&account->host_bytes, (LONG64)bytes);
    InterlockedExchangeAdd64(&live_bytes, (LONG64)bytes);
    return ZDA_OK;
}
void zda_account_release_host(ZdaAccount *account, size_t bytes) {
    assert(bytes != 0);
    InterlockedExchangeAdd64(&account->host_bytes, -(LONG64)bytes);
    InterlockedExchangeAdd64(&account->bytes, -(LONG64)bytes);
    InterlockedExchangeAdd64(&live_bytes, -(LONG64)bytes);
    zda_account_release(account);
}
int zda_storage_create(ZdaAccount *account, uint32_t kind, size_t payload_bytes, void **out) {
    if (!out) return ZDA_INVALID;
    *out = NULL;
    if (kind >= ZDA_KIND_COUNT) return ZDA_INVALID;
    const size_t bytes = zda_storage_footprint(payload_bytes);
    if (!bytes) return ZDA_CAPACITY;
    zda_account_retain(account);
    if (InterlockedCompareExchange(&account->closed, 0, 0)) { zda_account_release(account); return ZDA_CLOSED; }
    LONG count = InterlockedIncrement(&account->counts[kind]);
    if (kind == ZDA_RANGE && (uint32_t)count > account->range_limit) {
        InterlockedDecrement(&account->counts[kind]); zda_account_release(account); return ZDA_CAPACITY;
    }
    if (!reserve_bytes(account, bytes)) {
        InterlockedDecrement(&account->counts[kind]); zda_account_release(account); return ZDA_CAPACITY;
    }
    Block *block = CoTaskMemAlloc(bytes);
    if (!block) {
        InterlockedExchangeAdd64(&account->bytes, -(LONG64)bytes);
        InterlockedDecrement(&account->counts[kind]); zda_account_release(account); return ZDA_OOM;
    }
    memset(block, 0, sizeof(*block));
    block->value.account = account;
    block->value.bytes = bytes;
    block->value.kind = kind;
    InterlockedIncrement(&live_blocks);
    InterlockedExchangeAdd64(&live_bytes, (LONG64)bytes);
    *out = block + 1;
    return ZDA_OK;
}
void zda_storage_release(void *storage) {
    if (!storage) return;
    Block *block = (Block *)storage - 1;
    ZdaAccount *account = block->value.account;
    const size_t bytes = block->value.bytes;
    const uint32_t kind = block->value.kind;
    CoTaskMemFree(block);
    InterlockedExchangeAdd64(&account->bytes, -(LONG64)bytes);
    InterlockedDecrement(&account->counts[kind]);
    InterlockedDecrement(&live_blocks);
    InterlockedExchangeAdd64(&live_bytes, -(LONG64)bytes);
    zda_account_release(account);
}
void zda_ledger_counts(uint32_t *accounts, uint32_t *blocks, uint64_t *bytes) {
    *accounts = (uint32_t)InterlockedCompareExchange(&live_accounts, 0, 0);
    *blocks = (uint32_t)InterlockedCompareExchange(&live_blocks, 0, 0);
    *bytes = load64(&live_bytes);
}
