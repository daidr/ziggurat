#ifndef ZIGGURAT_PAGE_HOST_H
#define ZIGGURAT_PAGE_HOST_H

#include <windows.h>
#include <stdint.h>

typedef struct ZwvPageHost ZwvPageHost;
/* Adapter validation result, not a Win32 GetLastError code: SetWindowPos
   returned success but the OS did not apply the requested client geometry. */
#define ZWV_PAGE_HOST_GEOMETRY_MISMATCH ((HRESULT)0x8004A101L)
typedef enum ZwvPageHostPhase {
    ZWV_PAGE_PARKED,
    ZWV_PAGE_MOUNTED,
    ZWV_PAGE_HOST_LOST
} ZwvPageHostPhase;

typedef struct ZwvPageHostSnapshot {
    HWND parking, bridge, parent;
    RECT bounds;
    uint64_t epoch;
    ZwvPageHostPhase phase;
    BOOL visible;
    HRESULT failure, rollback_failure;
} ZwvPageHostSnapshot;

/* Explicit opt-in native owner. The caller supplies its process UI thread ID.
   These functions do not initialize COM, pump messages or invoke Zig callbacks.
   The host exclusively owns bridge/parking HWNDs; mounted parent HWNDs are
   borrowed and must forward their synchronous destruction notification below.
   Storage remains owned until close succeeds and clears *host. A creation
   failure normally leaves *host null; if native rollback itself fails, a
   nonnull *host retains cleanup responsibility and must be closed explicitly. */
HRESULT zwv_page_host_create(DWORD ui_thread, ZwvPageHost **host);
HRESULT zwv_page_host_snapshot(ZwvPageHost *host, ZwvPageHostSnapshot *snapshot);

/* Nonzero, increasing attachment epochs are never reused after a successful
   mount. The same mounted epoch permits geometry updates on the same parent.
   Failed candidates keep the previous attachment unless rollback also fails.
   Native geometry is verified before publishing, including silent OS clamps.
   HostLost rejects subsequent mount/park; only close remains available. */
HRESULT zwv_page_host_mount(ZwvPageHost *host, HWND parent, RECT bounds, BOOL visible, uint64_t epoch);
HRESULT zwv_page_host_park(ZwvPageHost *host, uint64_t expected_epoch);
/* Applies an explicit initial layout size, or restores a failed attachment's
   previous parked size. The current epoch is retained rather than rewound. */
HRESULT zwv_page_host_resize_parked(ZwvPageHost *host, LONG width, LONG height, uint64_t expected_epoch);
/* Transaction rollback only. Restores geometry/parent while retaining the
   CURRENT epoch; an old mounted identity may not be revived after a new mount. */
HRESULT zwv_page_host_restore(ZwvPageHost *host, const ZwvPageHostSnapshot *saved, uint64_t expected_epoch);

/* Called synchronously while parent WM_DESTROY still has live children.
   Only Win32 evacuation occurs. Stale parent/epoch pairs return S_FALSE.
   Failure marks HostLost and never reparents back into the dying parent. */
HRESULT zwv_page_host_parent_destroying(ZwvPageHost *host, HWND parent, uint64_t expected_epoch);

/* Call only after closing the controller whose fixed parent is bridge.
   A reentrant close returns E_PENDING and retains all storage. Native destroy
   failure also retains storage and surviving HWNDs for an explicit retry. */
HRESULT zwv_page_host_close(ZwvPageHost **host);
/* Physical adapter allocations/windows, including failed-construction cleanup
   owners. Counts return to baseline only after actual native destruction. */
void zwv_page_host_counts(uint32_t *hosts, uint32_t *parking, uint32_t *bridges);

#endif
