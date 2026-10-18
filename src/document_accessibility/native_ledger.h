#ifndef ZIGGURAT_DOCUMENT_ACCESSIBILITY_LEDGER_H
#define ZIGGURAT_DOCUMENT_ACCESSIBILITY_LEDGER_H
#include <stdint.h>
#include <stddef.h>
enum { ZDA_OK, ZDA_CAPACITY, ZDA_CLOSED, ZDA_OOM, ZDA_INVALID, ZDA_UNAVAILABLE };
enum { ZDA_STATE, ZDA_PROVIDER, ZDA_RANGE, ZDA_BLOB, ZDA_KIND_COUNT };
typedef struct ZdaAccount ZdaAccount;
typedef struct ZdaStats {
    uint64_t bytes, peak_bytes, byte_limit, host_bytes;
    uint32_t states, providers, ranges, blobs;
    uint32_t range_limit;
} ZdaStats;
/* System COM storage is explicit, thread-safe native ownership. No callback,
   allocator context, App, Document or Zig owner is retained by this ledger. */
int zda_account_create(uint64_t byte_limit, uint32_t range_limit, ZdaAccount **out);
void zda_account_close(ZdaAccount *);
void zda_account_retain(ZdaAccount *);
void zda_account_release(ZdaAccount *);
void zda_account_stats(ZdaAccount *, ZdaStats *);
/* Host staging shares the same atomic ceiling with MTA-created metadata. Each
   successful reservation retains only this native account, never its caller. */
int zda_account_reserve_host(ZdaAccount *, size_t bytes);
void zda_account_release_host(ZdaAccount *, size_t bytes);
int zda_storage_create(ZdaAccount *, uint32_t kind, size_t payload_bytes, void **out);
void zda_storage_release(void *);
/* Borrow only while holding an owning reference to this valid ledger blob.
   Each native State has its own account; blobs pin that issuer across MTA. */
ZdaAccount *zda_storage_account(const void *);
size_t zda_storage_footprint(size_t payload_bytes);
/* Test/diagnostic counts describe native allocations, including shells and
   getters still releasing after their owner has closed. */
void zda_ledger_counts(uint32_t *accounts, uint32_t *blocks, uint64_t *bytes);
#endif
