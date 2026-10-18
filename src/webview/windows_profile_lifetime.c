#include "windows_profile_lifetime.h"
#include <assert.h>
#include <stdlib.h>

typedef BOOL (WINAPI *CompareHandles)(HANDLE,HANDLE);
typedef struct ProcessRecord { HANDLE handle; uint64_t token; BOOL retiring; } ProcessRecord;
struct ZwpwLifetime {
    LONG refs;
    DWORD main_thread, worker_thread;
    SRWLOCK lock;
    HANDLE wake, storage_lock;
    CompareHandles compare;
    ProcessRecord processes[ZWPW_PROCESS_CAPACITY];
    uint64_t next_token;
    uint32_t count, admissions;
    BOOL accepting, running, retired;
};
static volatile LONG live_domains, live_processes;
static volatile LONG64 live_bytes;
#ifdef ZWPW_LIFETIME_TESTING
/* Test-only explicit scheduling gate, absent from production code/layout. */
extern void zwpw_test_lifetime_retired(ZwpwLifetime *);
#endif

size_t zwpw_lifetime_size(void) { return sizeof(ZwpwLifetime); }
int zwpw_lifetime_create(uint32_t main_thread,size_t bytes,HANDLE lock_handle,
                         ZwpwLifetime **out,uint32_t *error) {
    if (error) *error=0;
    if (!out) return ZWPW_INVALID;
    *out=NULL;
    DWORD worker=GetCurrentThreadId();
    if (worker==main_thread) return ZWPW_WRONG_THREAD;
    if (!main_thread||!lock_handle||lock_handle==INVALID_HANDLE_VALUE) return ZWPW_INVALID;
    if (bytes<sizeof(ZwpwLifetime)) return ZWPW_BUDGET_EXCEEDED;
    HMODULE base=GetModuleHandleW(L"kernelbase.dll");
    CompareHandles compare=base?(CompareHandles)(void *)GetProcAddress(base,"CompareObjectHandles"):NULL;
    if (!compare) { if (error) *error=ERROR_PROC_NOT_FOUND;return ZWPW_NATIVE_FAILED; }
    ZwpwLifetime *s=calloc(1,sizeof(*s));
    if (!s) return ZWPW_OUT_OF_MEMORY;
    s->refs=1;s->main_thread=main_thread;s->worker_thread=worker;
    s->compare=compare;s->accepting=TRUE;s->next_token=1;
    s->wake=CreateEventW(NULL,TRUE,FALSE,NULL);
    DWORD code=0;
    if (!s->wake) code=GetLastError();
    if (!code&&!DuplicateHandle(GetCurrentProcess(),lock_handle,GetCurrentProcess(),
                               &s->storage_lock,0,FALSE,DUPLICATE_SAME_ACCESS)) code=GetLastError();
    if (code) {
        if (s->wake) CloseHandle(s->wake);
        free(s);if (error) *error=code;return ZWPW_NATIVE_FAILED;
    }
    InterlockedIncrement(&live_domains);
    InterlockedAdd64(&live_bytes,(LONG64)sizeof(*s));
    *out=s;return ZWPW_OK;
}
void zwpw_lifetime_ref(ZwpwLifetime *s) { InterlockedIncrement(&s->refs); }
void zwpw_lifetime_unref(ZwpwLifetime *s) {
    if (InterlockedDecrement(&s->refs)) return;
    assert(!s->running&&!s->count&&!s->admissions);
    HANDLE wake=s->wake,storage_lock=s->storage_lock;
    s->wake=NULL;s->storage_lock=NULL;
    CloseHandle(wake);CloseHandle(storage_lock);
    size_t bytes=sizeof(*s);
    free(s);
    /* Credit includes each actual foreign release and allocator free above. */
    InterlockedAdd64(&live_bytes,-(LONG64)bytes);
    InterlockedDecrement(&live_domains);
}
static int main_owner(ZwpwLifetime *s) {
    return GetCurrentThreadId()==s->main_thread?ZWPW_OK:ZWPW_WRONG_THREAD;
}
int zwpw_lifetime_check_main(ZwpwLifetime *s) { return main_owner(s); }
int zwpw_lifetime_abandon(ZwpwLifetime *s) {
    if (GetCurrentThreadId()!=s->worker_thread) return ZWPW_WRONG_THREAD;
    int result=ZWPW_OK;
    AcquireSRWLockExclusive(&s->lock);
    if (s->running||s->count||s->admissions) result=ZWPW_BUSY;
    else { s->accepting=FALSE;SetEvent(s->wake); }
    ReleaseSRWLockExclusive(&s->lock);return result;
}
int zwpw_lifetime_admit(ZwpwLifetime *s) {
    int result=main_owner(s);if (result) return result;
    AcquireSRWLockExclusive(&s->lock);
    if (!s->accepting||s->retired) result=ZWPW_CLOSED;
    else if (s->admissions==UINT32_MAX) result=ZWPW_FULL;
    else { ++s->admissions;SetEvent(s->wake); }
    ReleaseSRWLockExclusive(&s->lock);return result;
}
int zwpw_lifetime_withdraw(ZwpwLifetime *s) {
    int result=main_owner(s);if (result) return result;
    AcquireSRWLockExclusive(&s->lock);
    if (!s->admissions) result=ZWPW_INVALID;
    else { --s->admissions;SetEvent(s->wake); }
    ReleaseSRWLockExclusive(&s->lock);return result;
}
int zwpw_lifetime_seal(ZwpwLifetime *s) {
    int result=main_owner(s);if (result) return result;
    AcquireSRWLockExclusive(&s->lock);
    s->accepting=FALSE;SetEvent(s->wake);
    ReleaseSRWLockExclusive(&s->lock);return ZWPW_OK;
}
int zwpw_lifetime_publish(ZwpwLifetime *s,HANDLE *input,uint64_t *token) {
    if (token) *token=0;
    int result=main_owner(s);if (result) return result;
    if (!input||!*input||*input==INVALID_HANDLE_VALUE||!token) return ZWPW_INVALID;
    HANDLE handle=*input,duplicate=NULL;
    AcquireSRWLockExclusive(&s->lock);
    if (!s->accepting||s->retired) result=ZWPW_CLOSED;
    else {
        uint32_t empty=ZWPW_PROCESS_CAPACITY;
        for (uint32_t i=0;i<ZWPW_PROCESS_CAPACITY;++i) {
            ProcessRecord *p=&s->processes[i];
            if (!p->handle) { if (empty==ZWPW_PROCESS_CAPACITY) empty=i;continue; }
            if (p->retiring) continue;
            if (s->compare(p->handle,handle)) { *token=p->token;duplicate=handle;break; }
        }
        if (!*token) {
            if (empty==ZWPW_PROCESS_CAPACITY||s->next_token==UINT64_MAX) result=ZWPW_FULL;
            else {
                ProcessRecord *p=&s->processes[empty];
                p->handle=handle;p->token=s->next_token++;
                *token=p->token;++s->count;
                InterlockedIncrement(&live_processes);
            }
        }
        if (!result) { *input=NULL;SetEvent(s->wake); }
    }
    ReleaseSRWLockExclusive(&s->lock);
    /* Only this un-published duplicate is closed on main. The worker alone
       closes handles that might already be in a pending native wait set. */
    if (duplicate) CloseHandle(duplicate);
    return result;
}
int zwpw_lifetime_matches(ZwpwLifetime *s,uint64_t token) {
    int result=main_owner(s);if (result) return result;
    if (!token) return ZWPW_INVALID;
    result=ZWPW_CLOSED;
    AcquireSRWLockShared(&s->lock);
    for (uint32_t i=0;i<ZWPW_PROCESS_CAPACITY;++i)
        if (s->processes[i].handle&&!s->processes[i].retiring&&s->processes[i].token==token) { result=ZWPW_OK;break; }
    ReleaseSRWLockShared(&s->lock);return result;
}
int zwpw_lifetime_run(ZwpwLifetime *s,uint32_t timeout_ms,uint32_t *error) {
    if (error) *error=0;
    if (GetCurrentThreadId()!=s->worker_thread) return ZWPW_WRONG_THREAD;
    AcquireSRWLockExclusive(&s->lock);
    if (s->running) { ReleaseSRWLockExclusive(&s->lock);return ZWPW_BUSY; }
    if (s->retired) { ReleaseSRWLockExclusive(&s->lock);return ZWPW_OK; }
    s->running=TRUE;
    ReleaseSRWLockExclusive(&s->lock);
    ULONGLONG began=GetTickCount64();
    int result=ZWPW_OK;
    for (;;) {
        HANDLE handles[MAXIMUM_WAIT_OBJECTS];
        uint64_t tokens[MAXIMUM_WAIT_OBJECTS];
        DWORD length=1;
        handles[0]=s->wake;tokens[0]=0;
        AcquireSRWLockExclusive(&s->lock);
        /* Main publishes and signals under this same lock; resetting before
           taking the snapshot cannot lose an interleaved publication. */
        ResetEvent(s->wake);
        if (!s->accepting&&!s->admissions&&!s->count) {
            s->retired=TRUE;ReleaseSRWLockExclusive(&s->lock);break;
        }
        for (uint32_t i=0;i<ZWPW_PROCESS_CAPACITY;++i) if (s->processes[i].handle) {
            handles[length]=s->processes[i].handle;tokens[length]=s->processes[i].token;++length;
        }
        ReleaseSRWLockExclusive(&s->lock);
        DWORD remaining=timeout_ms;
        if (timeout_ms!=INFINITE) {
            ULONGLONG elapsed=GetTickCount64()-began;
            if (elapsed>=timeout_ms) { result=ZWPW_PROCESS_EXIT_PENDING;break; }
            remaining=timeout_ms-(DWORD)elapsed;
        }
        DWORD waited=WaitForMultipleObjects(length,handles,FALSE,remaining);
        if (waited==WAIT_TIMEOUT) { result=ZWPW_PROCESS_EXIT_PENDING;break; }
        if (waited==WAIT_FAILED) { if (error) *error=GetLastError();result=ZWPW_NATIVE_FAILED;break; }
        if (waited>=WAIT_OBJECT_0+length) { result=ZWPW_NATIVE_FAILED;break; }
        DWORD index=waited-WAIT_OBJECT_0;
        if (!index) continue;
        HANDLE released=NULL;
        uint32_t slot=ZWPW_PROCESS_CAPACITY;
        AcquireSRWLockExclusive(&s->lock);
        for (uint32_t i=0;i<ZWPW_PROCESS_CAPACITY;++i)
            if (s->processes[i].handle==handles[index]&&s->processes[i].token==tokens[index]) {
                /* Leave this occupied through actual CloseHandle. Main can
                   neither reuse it nor publish a new object under this token. */
                released=s->processes[i].handle;s->processes[i].retiring=TRUE;slot=i;break;
            }
        ReleaseSRWLockExclusive(&s->lock);
        assert(released);
        if (!CloseHandle(released)) {
            if (error) *error=GetLastError();
            AcquireSRWLockExclusive(&s->lock);
            s->processes[slot].retiring=FALSE;
            ReleaseSRWLockExclusive(&s->lock);
            result=ZWPW_NATIVE_FAILED;break;
        }
        AcquireSRWLockExclusive(&s->lock);
        s->processes[slot]=(ProcessRecord){0};--s->count;
        ReleaseSRWLockExclusive(&s->lock);
        InterlockedDecrement(&live_processes);
#ifdef ZWPW_LIFETIME_TESTING
        zwpw_test_lifetime_retired(s);
#endif
    }
    AcquireSRWLockExclusive(&s->lock);
    s->running=FALSE;
    ReleaseSRWLockExclusive(&s->lock);return result;
}
int zwpw_lifetime_stats(ZwpwLifetime *s,ZwpwLifetimeStats *out) {
    if (!out) return ZWPW_INVALID;
    AcquireSRWLockShared(&s->lock);
    *out=(ZwpwLifetimeStats){sizeof(*s),s->count,s->admissions,s->accepting!=FALSE,s->running!=FALSE};
    ReleaseSRWLockShared(&s->lock);return ZWPW_OK;
}
void zwpw_lifetime_counts(ZwpwLifetimeCounts *out) {
    out->domains=(uint32_t)InterlockedCompareExchange(&live_domains,0,0);
    out->processes=(uint32_t)InterlockedCompareExchange(&live_processes,0,0);
    out->bytes=(size_t)InterlockedCompareExchange64(&live_bytes,0,0);
}
