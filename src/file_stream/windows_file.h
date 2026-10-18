#ifndef ZIGGURAT_WINDOWS_PUMP_FILE_H
#define ZIGGURAT_WINDOWS_PUMP_FILE_H
#include "windows_core.h"
typedef struct ZwsFilePump ZwsFilePump;
/* Explicit worker setup. Reopens one regular file, checks the WHOLE file hard
 * maximum first, then the exact selected window. Borrowed cursor is untouched.
 * Source and Pump are separate linear owning references on success only. */
int zws_file_prepare(uint64_t main_thread,HANDLE borrowed,uint64_t maximum,
    int window,uint64_t offset,uint64_t length,ZwsChannel **source,ZwsFilePump **pump,
    uint32_t *win32_error);
/* Explicit chosen producer worker; BODY reads at most16KiB per operation,
 * HEAD reads zero. Cancellation drains the actual overlapped I/O before its
 * stack OVERLAPPED/output buffer may leave this call. No App/thread owner. */
int zws_file_pump(ZwsFilePump *,uint32_t *win32_error);
void zws_file_pump_add(ZwsFilePump *);
void zws_file_pump_release(ZwsFilePump *);
#ifdef ZWS_TESTING
uint32_t zws_file_pump_count(void);
uint64_t zws_file_read_count(void);
#endif
#endif
