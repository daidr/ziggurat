#ifndef ZIGGURAT_WINDOWS_STREAM_CORE_H
#define ZIGGURAT_WINDOWS_STREAM_CORE_H
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stddef.h>

enum { ZWS_OK=0,ZWS_CLOSED=1,ZWS_FULL=2,ZWS_OOM=3,ZWS_INVALID=4,
    ZWS_IO=5,ZWS_CANCELLED=6,ZWS_TOO_LARGE=7,ZWS_REGULAR=8,ZWS_UI_THREAD=9,ZWS_BUSY=10,
    ZWS_SOURCE_CHANGED=12,ZWS_WINDOW=13,
    ZWS_LENGTH=14,ZWS_CHUNK=15,ZWS_THREAD=16,ZWS_KIND=17,ZWS_FINISHED=18,
    ZWS_HEAD_BODY=19,ZWS_PENDING=20,ZWS_EOF=21 };
enum { ZWS_GENERATED=1,ZWS_FILE_PUMP=2,ZWS_DIRECT_FILE=3 };
enum { ZWS_PROCESS_LIMIT=32,ZWS_CONSUMER_LIMIT=8,ZWS_CHUNK_BYTES=16384,
    ZWS_RING_BYTES=32768 };
#define ZWS_MAX_BYTES (256ull*1024ull*1024ull)
typedef struct ZwsChannel ZwsChannel;
typedef struct FileControl ZwsControl;
typedef struct ZwsBudget ZwsBudget;
typedef struct ZwsReader ZwsReader;
typedef struct ZwsCandidate ZwsCandidate;
typedef struct ZwsCounts { uint32_t physical,controls,budgets,readers,candidates,rings; } ZwsCounts;

/* Private native channel primitive, not a public source constructor. Kind is
 * immutable. Returns independent source/producer refs; creates no worker/App.
 * The file constructor must validate/own its regular-file producer separately. */
int zws_channel_prepare(uint64_t main_thread,uint64_t length,uint64_t maximum,
    unsigned kind,ZwsChannel **source,ZwsChannel **producer,uint32_t *win32_error);
uint64_t zws_channel_length(ZwsChannel *);
void zws_source_release(ZwsChannel *);
void zws_producer_release(ZwsChannel *);
int zws_writer_begin(ZwsChannel *,int *head,uint32_t *win32_error);
int zws_writer_write(ZwsChannel *,const void *,size_t,uint32_t *win32_error);
int zws_writer_finish(ZwsChannel *,uint32_t *win32_error);

ZwsBudget *zws_budget_create(uint32_t limit);
void zws_budget_add(ZwsBudget *);
void zws_budget_release(ZwsBudget *);
int zws_budget_limit(ZwsBudget *,uint32_t);
uint32_t zws_budget_live(ZwsBudget *);
void zws_control_add(ZwsControl *);
void zws_control_release(ZwsControl *);
void zws_control_cancel(ZwsControl *);
int zws_control_alive(ZwsControl *);

/* Candidate abort preserves both original refs. A consumer retains its own
 * borrowed Reader before irrevocable admission. Admission consumes candidate,
 * never allocates/calls application code, and opens BODY/HEAD even if cancelled. */
int zws_candidate_prepare(ZwsChannel *,ZwsBudget *,int head,ZwsCandidate **);
ZwsReader *zws_candidate_reader(ZwsCandidate *);
ZwsControl *zws_candidate_control(ZwsCandidate *); /* borrowed */
void zws_candidate_abort(ZwsCandidate *);
void zws_candidate_admit(ZwsCandidate *,int cancelled,ZwsControl **optional_control);
void zws_reader_add(ZwsReader *);
void zws_reader_release(ZwsReader *);
/* Nonblocking, no buffer retained, no source generation or file I/O. Workers
 * wait on BOTH borrowed handles while retaining Reader. No UI-thread read. */
int zws_reader_try_read(ZwsReader *,void *,size_t,size_t *,uint32_t *win32_error);
int zws_reader_terminal(ZwsReader *,int *result,uint32_t *win32_error);
void zws_reader_wait_handles(ZwsReader *,HANDLE *data,HANDLE *cancel);
void zws_counts(ZwsCounts *);
#ifdef ZWS_TESTING
void zws_test_fail_after(int);
void zws_test_layout(uint32_t *physical,uint32_t *control,uint32_t *reader);
void zws_test_capacity_wait(HANDLE borrowed_event);
uint32_t zws_test_waiting_writers(void);
#endif
#endif
