#ifndef ZIGGURAT_HTTPS_RESOURCES_LINUX_H
#define ZIGGURAT_HTTPS_RESOURCES_LINUX_H
#include <stddef.h>
#include <stdint.h>
#include "../file_stream/linux.h"

typedef struct ZhrOwner ZhrOwner;
typedef struct ZhrBorrow ZhrBorrow;
typedef struct ZhrTicket ZhrTicket;
typedef struct ZhrCandidate ZhrCandidate;
#include "endpoint_abi.h"

/* Filter is pure owner-side admission, before receiving a body or offering a
 * request. It uses the shared Zig policy. Both callbacks run on process main. */
typedef int (*ZhrFilter)(void *,const ZhrRequest *);
typedef void (*ZhrOffer)(void *,const ZhrRequest *,ZhrBorrow *);
enum ZhrResult { ZHR_OK=0,ZHR_CLOSED=1,ZHR_FULL=2,ZHR_OOM=3,ZHR_INVALID=4,ZHR_WRONG_THREAD=5,ZHR_NATIVE=6,ZHR_STALE=7,ZHR_CAPACITY=8 };

/* The host owns and starts SoupServer/listener/TLS/default main context. This
 * adapter owns only a strong server reference and its exclusive prefix. */
int zhr_server_pin(void *server,void **out);
void zhr_server_unpin(void *server);
int zhr_create(void *server,const ZhrOptions *,ZhrOwner **out);
int zhr_bind(ZhrOwner *,void *,ZhrFilter,ZhrOffer);
int zhr_check(ZhrOwner *);
int zhr_borrow_input(ZhrOwner *,size_t bytes);
void zhr_return_input(ZhrOwner *);
void zhr_seal(ZhrOwner *);
void zhr_close(ZhrOwner *);
void zhr_owner_release(ZhrOwner *);
size_t zhr_owner_size(void);
int zhr_stats(ZhrOwner *,ZhrStats *);
void zhr_counts(ZhrCounts *);

/* A borrow exists only on the callback stack. A successful defer publishes an
 * independent linear C ticket, never a pointer to Zig/App/allocator storage. */
int zhr_defer(ZhrBorrow *,ZhrTicket **out);
int zhr_ticket_owner(ZhrTicket *,void **out);
void zhr_ticket_release(ZhrTicket *); /* any thread; never performs native UI */
void zhr_ticket_consume(ZhrTicket *); /* accepted owning ref; no cancellation */
int zhr_ticket_cancel(ZhrTicket *); /* atomic cancellation, owner retires HTTP */

/* Inputs have passed the shared HTTP validator. Bounds are checked again at
 * the native copy boundary. Every setup error/abort retains caller sources. */
int zhr_prepare_memory(ZhrTarget,const ZhrResponse *,ZhrCandidate **out);
int zhr_prepare_head(ZhrTarget,const ZhrResponse *,ZhrCandidate **out);
int zhr_prepare_file(ZhrTarget,const ZhrResponse *,ZwkFile *,ZhrCandidate **out);
int zhr_candidate_check(ZhrCandidate *,void *owner);
void zhr_candidate_abort(ZhrCandidate *);
/* Pure publication: the consumer irrevocably owns once. Source and Ticket
 * caller references are released only after this point. Source admission and
 * all infallible native cleanup happen in start (or reentrant close), with
 * native pins. 1 means accepted_cancelled, never retry or peer-consumption ACK. */
int zhr_candidate_admit(ZhrCandidate *,int want_control,ZwkFileControl **control);
/* Infallible accepted-source activation, before releasing the withdrawn
 * prepared source reference. This may perform native foreign cleanup. */
void zhr_candidate_admit_source(ZhrCandidate *);
/* May reenter close. Called after caller owning fields are withdrawn and their
 * final foreign cleanup has returned. Candidate holds native-only pins. */
int zhr_candidate_start(ZhrCandidate *);
#ifdef ZHR_TESTING
void zhr_test_allocation_limit(int successful_allocations);
#endif

#endif
