#ifndef ZIGGURAT_FILE_STREAM_LINUX_H
#define ZIGGURAT_FILE_STREAM_LINUX_H
#include <gio/gio.h>
#include <stdint.h>

#define ZWK_FILE_MAX_BYTES (256ull*1024ull*1024ull)
#define ZWK_FILE_PROCESS_LIMIT 32u
#define ZWK_FILE_CONSUMER_LIMIT 8u
#define ZWK_FILE_VIEW_LIMIT ZWK_FILE_CONSUMER_LIMIT
#define ZWK_FILE_CHUNK_BYTES 16384u
#define ZWK_FILE_HAS_WINDOW 1
typedef struct ZwkFile ZwkFile;
typedef struct ZwkFileControl ZwkFileControl;
typedef struct ZwkFileBudget ZwkFileBudget;
typedef struct ZwkFileCandidate ZwkFileCandidate;
enum ZwkFileResult {
    ZWK_FILE_OK=0, ZWK_FILE_CLOSED=1, ZWK_FILE_FULL=2,
    ZWK_FILE_OOM=3, ZWK_FILE_INVALID=4, ZWK_FILE_IO=5,
    ZWK_FILE_CANCELLED=6, ZWK_FILE_TOO_LARGE=7,
    ZWK_FILE_REGULAR_REQUIRED=8, ZWK_FILE_UI_THREAD=9,
    ZWK_FILE_BUSY=10, ZWK_FILE_ALREADY_COMMITTED=11,
    ZWK_FILE_SOURCE_CHANGED=12, ZWK_FILE_WINDOW_INVALID=13,
    ZWK_FILE_LENGTH_MISMATCH=14, ZWK_FILE_INVALID_CHUNK=15,
    ZWK_FILE_WRONG_PRODUCER=16, ZWK_FILE_SOURCE_KIND=17,
    ZWK_FILE_FINISHED=18, ZWK_FILE_UNEXPECTED_BODY=19
};
/* Worker only. Takes no source ownership and never changes its seek position.
   Returns two independent owning Physical refs: response and explicit pump.
   Source bytes must remain private and immutable until the pump completes. */
int zwk_file_prepare(int source_fd,uint64_t ui_thread,uint64_t maximum,
    ZwkFile **response,ZwkFile **pump,uint64_t *length,int *native_errno);
/* Same worker ownership/maximum as prepare; represents exactly this window.
   The whole regular file must fit maximum. offset<=size and count<=size-offset;
   zero count is an empty representation, including at EOF. No clamping, HTTP
   Range parsing, stat/read on the owner, or caller seek-position change. */
int zwk_file_prepare_window(int source_fd,uint64_t ui_thread,uint64_t maximum,
    uint64_t offset,uint64_t count,ZwkFile **response,ZwkFile **pump,
    uint64_t *length,int *native_errno);
void zwk_file_response_release(ZwkFile *);
uint64_t zwk_file_length(ZwkFile *); /* prepare-time length; no IO */
/* Linear explicit worker operation. Waits for accepted commit/cancellation;
   HEAD performs no pread. Poll waits only on socket readiness and eventfd. */
int zwk_file_pump(ZwkFile *,int *native_errno);
void zwk_file_pump_release(ZwkFile *);

/* Worker-only known-length byte production. Same Source/candidate/ledger as
   files; independent linear Writer ref. No file, allocator or App is borrowed.
   The immutable kind rejects file Pump/generated Writer interchange. */
int zwk_stream_prepare(uint64_t ui_thread,uint64_t length,uint64_t maximum,
    ZwkFile **source,ZwkFile **writer,int *native_errno);
/* First call fixes the explicit worker identity. Waits for accepted GET/HEAD
   or cancellation. HEAD never permits body production. */
int zwk_stream_writer_begin(ZwkFile *,int *head,int *native_errno);
/* Borrows <=16KiB until return. Production failures are terminal, including
   partial OS writes: cancel, never retry the complete input. Wrong kind/thread
   is an authority refusal and cannot mutate a previously published result. */
int zwk_stream_writer_write(ZwkFile *,const void *,size_t,int *native_errno);
/* Exact body length (or accepted HEAD) only. Release via pump_release. */
int zwk_stream_writer_finish(ZwkFile *,int *native_errno);

ZwkFileBudget *zwk_file_budget_create(uint32_t limit);
void zwk_file_budget_limit(ZwkFileBudget *,uint32_t limit);
void zwk_file_budget_release(ZwkFileBudget *);
uint32_t zwk_file_budget_live(ZwkFileBudget *);

/* Owner setup transaction. On failure outputs NULL and retains the prepared
   response/pump. Candidate owns stream + provisional per-consumer reservation.
   Stream is a private socket-backed GInputStream with known pollability,
   never a regular-file GInputStream. No read/stat/pollability probe or implicit
   worker at this stage. GLib's GObject allocation itself is process-fatal OOM. */
int zwk_file_prepare_stream(ZwkFile *,ZwkFileBudget *,int head,
    ZwkFileCandidate **candidate,int *native_errno);
GInputStream *zwk_file_candidate_stream(ZwkFileCandidate *); /* borrowed */
ZwkFileControl *zwk_file_candidate_control(ZwkFileCandidate *); /* borrowed */
/* Both consume Candidate. Abort cannot cancel the original prepared pump.
   Admit is infallible and follows the consumer's irrevocable acceptance of one
   response responsibility. A close/cancel at that acceptance boundary is
   accepted_cancelled, never a retry. Acceptance is not a peer consumption ACK.
   Admit transfers the reservation to Physical, wakes the explicit pump, and
   optionally returns an independent owning cancellation ticket. The consumer
   must retain the borrowed stream before admission if it will read it later. */
void zwk_file_candidate_abort(ZwkFileCandidate *);
void zwk_file_candidate_admit(ZwkFileCandidate *,int accepted_cancelled,
    int want_ticket,ZwkFileControl **ticket);
/* Compatibility entry; identical to admit, retaining its existing ABI. */
void zwk_file_candidate_commit(ZwkFileCandidate *,int accepted_cancelled,
    int want_ticket,ZwkFileControl **ticket);
void zwk_file_control_add(ZwkFileControl *);
void zwk_file_control_release(ZwkFileControl *);
void zwk_file_control_cancel(ZwkFileControl *);
int zwk_file_control_alive(ZwkFileControl *);
/* Physical slots only leave on final response/pump/actual stream reference.
   Tickets do not retain Physical or budget slots. Native-only late lifetime. */
void zwk_file_counts(uint32_t *physical,uint32_t *controls,uint32_t *budgets,uint32_t *candidates);
uint64_t zwk_file_pread_count(void);
#ifdef ZWK_FILE_TESTING
/* Only the module's recoverable native metadata allocations, not GLib's
   process-fatal allocator. Negative disables the fault injection. */
void zwk_file_test_allocation_limit(int successful_allocations);
void zwk_file_test_pread_error(int native_errno);
/* Isolated native tests only; install/clear observer outside writer lifetime.
   Stage 0 is waiting for acceptance, 1 follows actual socket EAGAIN. */
void zwk_stream_test_wait_observer(void (*observer)(int,void *),void *context);
void zwk_stream_test_send_error_after(long bytes);
uint64_t zwk_stream_test_sent(void);
void zwk_stream_test_layout(uint32_t *bytes,uint32_t *kind,uint32_t *thread,uint32_t *produced);
#endif
#endif
