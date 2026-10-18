/* Only this test translation unit interposes the operating-system calls. It
 * still completes a real overlapped file read. A gate makes the pending-read
 * stack lifetime observable while cancellation races completion. */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static LONG file_io_gate_enabled,file_io_pending_path,file_io_actual_pending,file_io_drained;
static HANDLE file_io_entered,file_io_gate;
static BOOL file_fixture_read_file(HANDLE file,LPVOID buffer,DWORD length,LPDWORD read,LPOVERLAPPED operation) {
    BOOL ok=ReadFile(file,buffer,length,read,operation);DWORD error=ok?ERROR_SUCCESS:GetLastError();
    if(operation&&InterlockedCompareExchange(&file_io_gate_enabled,0,0)){
        if(!ok&&error==ERROR_IO_PENDING)InterlockedIncrement(&file_io_actual_pending);
        /* An immediately completed operation is also a legal pending result
           after its event has signalled. This makes the test independent of
           cache latency, without inventing an unfinished kernel operation. */
        if(ok){SetEvent(operation->hEvent);error=ERROR_IO_PENDING;ok=FALSE;}
        if(error==ERROR_IO_PENDING)InterlockedIncrement(&file_io_pending_path);
    }
    if(!ok)SetLastError(error);return ok;
}
static BOOL file_fixture_overlapped_result(HANDLE file,LPOVERLAPPED operation,LPDWORD read,BOOL wait) {
    BOOL held=wait&&InterlockedCompareExchange(&file_io_gate_enabled,0,1)==1;
    if(held){SetEvent(file_io_entered);if(WaitForSingleObject(file_io_gate,10000)!=WAIT_OBJECT_0)abort();}
    BOOL ok=GetOverlappedResult(file,operation,read,wait);DWORD error=ok?ERROR_SUCCESS:GetLastError();
    if(held)InterlockedIncrement(&file_io_drained);
    if(!ok)SetLastError(error);return ok;
}
#define ReadFile file_fixture_read_file
#define GetOverlappedResult file_fixture_overlapped_result
