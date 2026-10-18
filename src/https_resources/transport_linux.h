#ifndef ZIGGURAT_HTTPS_TRANSPORT_LINUX_H
#define ZIGGURAT_HTTPS_TRANSPORT_LINUX_H
#include <stddef.h>
#include <stdint.h>
typedef struct ZhtOwner ZhtOwner;
typedef struct ZhtFailure { uint32_t domain; int32_t code; } ZhtFailure;
typedef struct ZhtOptions { size_t bytes,zig_bytes,temporary_bytes; const uint8_t *pem; size_t length; } ZhtOptions;
typedef struct ZhtStats { size_t bytes,peak_bytes; uint32_t accepting,port; } ZhtStats;
typedef struct ZhtCounts { uint32_t owners,servers; size_t bytes; } ZhtCounts;
/* Only this stack value borrows a server. State and server have independent
 * native refs; finish takes both before its last foreign unref/check. */
typedef struct ZhtLease { ZhtOwner *owner; void *server; uint32_t port; } ZhtLease;
enum { ZHT_OK=0,ZHT_CLOSED=1,ZHT_FULL=2,ZHT_OOM=3,ZHT_INVALID=4,ZHT_WRONG_THREAD=5,ZHT_NATIVE=6,ZHT_CAPACITY=8 };
int zht_create(const ZhtOptions *,ZhtOwner **,ZhtFailure *);
void zht_ref(ZhtOwner *);
void zht_unref(ZhtOwner *);
int zht_seal(ZhtOwner *);
void zht_close(ZhtOwner *);
int zht_stats(ZhtOwner *,ZhtStats *);
int zht_lease_begin(ZhtOwner *,ZhtLease *);
int zht_lease_finish(ZhtLease *);
void zht_counts(ZhtCounts *);
size_t zht_owner_size(void);
#ifdef ZHT_TESTING
void zht_test_allocation_limit(int);
#endif
#endif
