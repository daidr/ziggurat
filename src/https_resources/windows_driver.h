#ifndef ZIGGURAT_HTTPS_WINDOWS_DRIVER_H
#define ZIGGURAT_HTTPS_WINDOWS_DRIVER_H
#include <stddef.h>
#include <stdint.h>
typedef struct ZhrOwner ZhrOwner;
typedef struct ZhrBorrow ZhrBorrow;
typedef struct ZhrTicket ZhrTicket;
typedef struct ZhrCandidate ZhrCandidate;
#include "endpoint_abi.h"

typedef struct ZhtwServer ZhtwServer;
typedef struct ZhtwEnvelope ZhtwEnvelope;
typedef struct ZhtwFailure { uint32_t domain; int32_t code; } ZhtwFailure;
typedef struct ZhtwLimits { size_t bytes; uint32_t connections; } ZhtwLimits;
/* peak_bytes is the conservative metadata-peak + TLS-peak envelope, rather than
 * an assertion that those two peaks occurred simultaneously. */
typedef struct ZhtwStats { size_t bytes,peak_bytes,tls_live,tls_peak; uint32_t connections,accepting,port,running; } ZhtwStats;
typedef struct ZhtwCounts { uint32_t servers,payloads,envelopes,connections; size_t bytes; } ZhtwCounts;
/* post returns 0 only after the explicit host App.post accepts exactly once.
 * It consumes this envelope ref on success. Full/Closed must not consume it.
 * context is the host App, which outlives Driver.run and every accepted post. */
typedef int (*ZhtwPost)(void *,ZhtwEnvelope *);
/* Pure bounded formatter; no allocation, App callbacks or retained pointers.
 * It returns 0 and writes length on success, otherwise output is unchanged. */
typedef int (*ZhtwFormat)(const ZhrResponse *,uint64_t,uint8_t *,size_t,size_t *);
enum { ZHR_OK=0,ZHR_CLOSED=1,ZHR_FULL=2,ZHR_OOM=3,ZHR_INVALID=4,
    ZHR_WRONG_THREAD=5,ZHR_NATIVE=6,ZHR_STALE=7,ZHR_CAPACITY=8 };
typedef int (*ZhrFilter)(void *,const ZhrRequest *);
typedef void (*ZhrOffer)(void *,const ZhrRequest *,ZhrBorrow *);

/* prepare/run/release_driver execute on the SAME explicit worker. Preparation
 * returns two independent refs: a main-thread prepared token and a Driver.
 * No thread, App post, credential persistence or listener dispatch is hidden. */
int zhtw_prepare(uint64_t main_thread,const uint8_t *cert,size_t cert_length,
    const uint8_t *key,size_t key_length,const ZhtwLimits *,
    ZhtwServer **prepared,ZhtwServer **driver,ZhtwFailure *);
int zhtw_adopt(ZhtwServer *,void *app,ZhtwPost,ZhtwFormat);
int zhtw_run(ZhtwServer *,ZhtwFailure *);
int zhtw_release_driver(ZhtwServer **); /* WrongThread retains the token. */
void zhtw_ref(ZhtwServer *);
void zhtw_unref(ZhtwServer *); /* C-only metadata cleanup, any thread. */
/* Reject new admission and retire unclaimed connections; already claimed
 * Endpoint/Ticket duties may finish. This never waits for worker retirement. */
int zhtw_seal(ZhtwServer *);
void zhtw_cancel(ZhtwServer *); /* any thread, signals all outstanding work. */
int zhtw_stats(ZhtwServer *,ZhtwStats *);
int zhtw_lease_begin(ZhtwServer *,ZhtwServer **,uint16_t *);
int zhtw_lease_finish(ZhtwServer **);
void zhtw_counts(ZhtwCounts *);

/* One accepted post calls dispatch/reject and then release on main. The raw
 * bytes remain immutable until that ref is released, even after Driver exits.
 * dispatch owns no pointers into the caller's parsed descriptor stack. */
ZhrSlice zhtw_envelope_head(ZhtwEnvelope *);
uint16_t zhtw_envelope_port(ZhtwEnvelope *);
void zhtw_dispatch(ZhtwEnvelope *,const ZhrRequest *);
void zhtw_reject(ZhtwEnvelope *,unsigned status);
void zhtw_envelope_release(ZhtwEnvelope *);

int zhr_server_pin(void *,void **);
void zhr_server_unpin(void *);
int zhr_create(void *,const ZhrOptions *,ZhrOwner **);
int zhr_bind(ZhrOwner *,void *,ZhrFilter,ZhrOffer);
int zhr_check(ZhrOwner *);
int zhr_borrow_input(ZhrOwner *,size_t);
void zhr_return_input(ZhrOwner *);
void zhr_seal(ZhrOwner *);
void zhr_close(ZhrOwner *);
void zhr_owner_release(ZhrOwner *);
size_t zhr_owner_size(void);
int zhr_stats(ZhrOwner *,ZhrStats *);
void zhr_counts(ZhrCounts *);
int zhr_defer(ZhrBorrow *,ZhrTicket **);
int zhr_ticket_owner(ZhrTicket *,void **);
void zhr_ticket_release(ZhrTicket *);
void zhr_ticket_consume(ZhrTicket *);
int zhr_ticket_cancel(ZhrTicket *);
int zhr_prepare_memory(ZhrTarget,const ZhrResponse *,ZhrCandidate **);
int zhr_prepare_head(ZhrTarget,const ZhrResponse *,ZhrCandidate **);
int zhr_prepare_file(ZhrTarget,const ZhrResponse *,void *,ZhrCandidate **);
int zhr_candidate_check(ZhrCandidate *,void *);
void zhr_candidate_abort(ZhrCandidate *);
int zhr_candidate_admit(ZhrCandidate *,int,void **);
void zhr_candidate_admit_source(ZhrCandidate *);
int zhr_candidate_start(ZhrCandidate *);
#ifdef ZHTW_TESTING
void zhtw_test_fail_after(int);
/* Borrowed oracle events, reset by the test and valid until Driver is joined.
 * Only this test configuration constrains SO_SNDBUF to exercise real WANT. */
void zhtw_test_backpressure(void *write_wait,void *connection_closed);
void zhtw_test_ingress(void *accepted,void *request_byte);
void zhtw_test_sizes(size_t *server,size_t *worker,size_t *envelope,size_t *candidate);
#endif
#endif
