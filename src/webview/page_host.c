#include "page_host.h"
#include <limits.h>
#include <stdlib.h>

typedef struct HostWindow { ZwvPageHost *host; BOOL bridge; } HostWindow;
struct ZwvPageHost {
    DWORD thread;
    DPI_AWARENESS_CONTEXT dpi;
    HWND parking, bridge, parent;
    RECT bounds;
    uint64_t epoch;
    ZwvPageHostPhase phase;
    BOOL visible, closing, busy, evacuating, interrupted;
    HWND candidate_parent;
    uint64_t candidate_epoch;
    HRESULT failure, rollback_failure;
    HostWindow parking_context, bridge_context;
};

static const WCHAR host_class[] = L"Ziggurat.PageHost.Native.1";
static LONG live_hosts, live_parking, live_bridges;

static HRESULT host_win32_failure(void) {
    DWORD code = GetLastError();
    return code ? HRESULT_FROM_WIN32(code) : E_FAIL;
}
static HRESULT host_owner(ZwvPageHost *host) {
    if (!host) return E_POINTER;
    return GetCurrentThreadId() == host->thread ? S_OK : RPC_E_WRONG_THREAD;
}
static void host_lost(ZwvPageHost *host) {
    host->phase = ZWV_PAGE_HOST_LOST;
    host->parent = NULL;
    host->visible = FALSE;
}
static LRESULT CALLBACK host_proc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp) {
    HostWindow *window = (HostWindow *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (message == WM_NCCREATE) {
        window = (HostWindow *)((CREATESTRUCTW *)lp)->lpCreateParams;
        if (!window || !window->host) return FALSE;
        SetLastError(0);
        if (!SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)window) && GetLastError()) return FALSE;
        if (window->bridge) { window->host->bridge = hwnd; InterlockedIncrement(&live_bridges); }
        else { window->host->parking = hwnd; InterlockedIncrement(&live_parking); }
    }
    if (message == WM_NCDESTROY && window) {
        ZwvPageHost *host = window->host;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        if (window->bridge) { host->bridge = NULL; InterlockedDecrement(&live_bridges); }
        else { host->parking = NULL; InterlockedDecrement(&live_parking); }
        if (!host->closing) host_lost(host);
    }
    return DefWindowProcW(hwnd, message, wp, lp);
}
static HRESULT host_register(void) {
    HINSTANCE instance = GetModuleHandleW(NULL);
    WNDCLASSEXW cls = {0};
    cls.cbSize = sizeof(cls);
    cls.hInstance = instance;
    cls.lpfnWndProc = host_proc;
    cls.lpszClassName = host_class;
    if (RegisterClassExW(&cls)) return S_OK;
    HRESULT failure = host_win32_failure();
    if (failure != HRESULT_FROM_WIN32(ERROR_CLASS_ALREADY_EXISTS)) return failure;
    WNDCLASSEXW existing = {0};
    existing.cbSize = sizeof(existing);
    if (!GetClassInfoExW(instance, host_class, &existing)) return host_win32_failure();
    return existing.lpfnWndProc == host_proc && existing.hInstance == instance ? S_OK : failure;
}
static BOOL host_rect_valid(RECT bounds) {
    int64_t width = (int64_t)bounds.right - bounds.left;
    int64_t height = (int64_t)bounds.bottom - bounds.top;
    return width >= 0 && width <= INT_MAX && height >= 0 && height <= INT_MAX;
}
static HRESULT host_parent_valid(ZwvPageHost *host, HWND parent) {
    if (!parent) return E_INVALIDARG;
    DWORD process = 0;
    SetLastError(0);
    DWORD thread = GetWindowThreadProcessId(parent, &process);
    if (!thread) return host_win32_failure();
    if (thread != host->thread || process != GetCurrentProcessId() || parent == host->bridge || parent == host->parking || IsChild(host->bridge, parent)) return E_INVALIDARG;
    if (!AreDpiAwarenessContextsEqual(host->dpi, GetWindowDpiAwarenessContext(parent))) return E_INVALIDARG;
    return S_OK;
}
static HRESULT host_reparent(ZwvPageHost *host, HWND parent) {
    if (GetParent(host->bridge) == parent) return S_OK;
    SetLastError(0);
    if (!SetParent(host->bridge, parent)) return host_win32_failure();
    return S_OK;
}
static HRESULT host_position(ZwvPageHost *host, HWND parent, RECT bounds, BOOL visible) {
    UINT flags = SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER | (visible ? SWP_SHOWWINDOW : SWP_HIDEWINDOW);
    if (!SetWindowPos(host->bridge, NULL, bounds.left, bounds.top, bounds.right - bounds.left, bounds.bottom - bounds.top, flags)) return host_win32_failure();
    if (host->interrupted || !host->bridge || host->phase == ZWV_PAGE_HOST_LOST) return E_ABORT;
    RECT client, actual;
    if (!GetClientRect(host->bridge, &client)) return host_win32_failure();
    if (!GetWindowRect(host->bridge, &actual)) return host_win32_failure();
    SetLastError(0);
    if (!MapWindowPoints(NULL, parent, (POINT *)&actual, 2) && GetLastError()) return host_win32_failure();
    if (!EqualRect(&actual, &bounds) || client.right != bounds.right - bounds.left || client.bottom != bounds.bottom - bounds.top) return ZWV_PAGE_HOST_GEOMETRY_MISMATCH;
    return S_OK;
}
static BOOL host_interrupted(ZwvPageHost *host) {
    return host->interrupted || !host->bridge || !host->parking || host->phase == ZWV_PAGE_HOST_LOST;
}
static HRESULT host_parked_size(ZwvPageHost *host) {
    RECT bounds;
    if (!GetClientRect(host->bridge, &bounds)) {
        HRESULT hr = host_win32_failure();
        host_lost(host);
        return hr;
    }
    host->bounds = bounds;
    return S_OK;
}
static HRESULT host_rollback(ZwvPageHost *host, ZwvPageHostSnapshot old) {
    HRESULT hr = host_reparent(host, old.parent);
    if (SUCCEEDED(hr) && !host_interrupted(host)) hr = host_position(host, old.parent, old.bounds, old.visible);
    if (host_interrupted(host)) return E_ABORT;
    if (FAILED(hr)) {
        if (host->bridge) ShowWindow(host->bridge, SW_HIDE);
        host_lost(host);
        return hr;
    }
    host->parent = old.parent;
    host->bounds = old.bounds;
    host->epoch = old.epoch;
    host->visible = old.visible;
    host->phase = old.phase;
    return S_OK;
}
static HRESULT host_move(ZwvPageHost *host, HWND parent, RECT bounds, BOOL visible, uint64_t epoch, ZwvPageHostPhase phase) {
    ZwvPageHostSnapshot old = {host->parking, host->bridge, host->parent, host->bounds, host->epoch, host->phase, host->visible, S_OK, S_OK};
    host->busy = TRUE;
    host->interrupted = FALSE;
    host->candidate_parent = parent;
    host->candidate_epoch = epoch;
    host->failure = S_OK;
    host->rollback_failure = S_OK;
    ShowWindow(host->bridge, SW_HIDE);
    HRESULT hr = host_interrupted(host) ? E_ABORT : host_reparent(host, parent);
    if (SUCCEEDED(hr) && !host_interrupted(host)) hr = host_position(host, parent, bounds, visible);
    if (host_interrupted(host)) {
        hr = E_ABORT;
        /* A parent can be destroyed inside SetWindowPos. Evacuation happens
           before that outer operation finishes, so re-read its final size. */
        if (host->phase == ZWV_PAGE_PARKED) {
            HRESULT size_hr = host_parked_size(host);
            if (FAILED(size_hr)) hr = size_hr;
        }
    }
    if (FAILED(hr)) {
        if (!host_interrupted(host)) host->rollback_failure = host_rollback(host, old);
        host->failure = hr;
    } else {
        host->parent = parent;
        host->bounds = bounds;
        host->epoch = epoch;
        host->visible = visible;
        host->phase = phase;
        /* Match the parent UI state during ordinary mounting, outside raw
           parent destruction. Controller/COM state is deliberately untouched. */
        if (phase == ZWV_PAGE_MOUNTED) {
            UINT state = (UINT)SendMessageW(parent, WM_QUERYUISTATE, 0, 0);
            if (!host_interrupted(host)) SendMessageW(host->bridge, WM_CHANGEUISTATE, MAKEWPARAM(UIS_SET, state), 0);
            if (!host_interrupted(host)) SendMessageW(host->bridge, WM_CHANGEUISTATE, MAKEWPARAM(UIS_CLEAR, (UISF_HIDEFOCUS | UISF_HIDEACCEL | UISF_ACTIVE) & ~state), 0);
            if (host_interrupted(host)) { hr = E_ABORT; host->failure = hr; }
        }
    }
    host->candidate_parent = NULL;
    host->candidate_epoch = 0;
    host->busy = FALSE;
    return hr;
}

HRESULT zwv_page_host_create(DWORD ui_thread, ZwvPageHost **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    if (!ui_thread || GetCurrentThreadId() != ui_thread) return RPC_E_WRONG_THREAD;
    HRESULT hr = host_register();
    if (FAILED(hr)) return hr;
    ZwvPageHost *host = calloc(1, sizeof(*host));
    if (!host) return E_OUTOFMEMORY;
    InterlockedIncrement(&live_hosts);
    host->thread = ui_thread;
    host->phase = ZWV_PAGE_PARKED;
    host->bounds = (RECT){0, 0, 1, 1};
    host->parking_context = (HostWindow){host, FALSE};
    host->bridge_context = (HostWindow){host, TRUE};
    HINSTANCE instance = GetModuleHandleW(NULL);
    if (!CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, host_class, L"", WS_POPUP | WS_CLIPCHILDREN | WS_CLIPSIBLINGS, 0, 0, 1, 1, NULL, NULL, instance, &host->parking_context)) {
        hr = host_win32_failure(); goto failed;
    }
    if (!CreateWindowExW(0, host_class, L"", WS_CHILD | WS_CLIPCHILDREN | WS_CLIPSIBLINGS, 0, 0, 1, 1, host->parking, NULL, instance, &host->bridge_context)) {
        hr = host_win32_failure(); goto failed;
    }
    host->parent = host->parking;
    host->dpi = GetWindowDpiAwarenessContext(host->bridge);
    *out = host;
    return S_OK;
failed:
    {
        HRESULT rollback = zwv_page_host_close(&host);
        if (FAILED(rollback)) {
            host->failure = hr;
            host->rollback_failure = rollback;
            *out = host;
        }
    }
    return hr;
}
HRESULT zwv_page_host_snapshot(ZwvPageHost *host, ZwvPageHostSnapshot *out) {
    HRESULT hr = host_owner(host);
    if (FAILED(hr)) return hr;
    if (!out) return E_POINTER;
    *out = (ZwvPageHostSnapshot){host->parking, host->bridge, host->parent, host->bounds, host->epoch, host->phase, host->visible, host->failure, host->rollback_failure};
    return S_OK;
}
HRESULT zwv_page_host_mount(ZwvPageHost *host, HWND parent, RECT bounds, BOOL visible, uint64_t epoch) {
    HRESULT hr = host_owner(host);
    if (FAILED(hr)) return hr;
    if (host->closing || host->phase == ZWV_PAGE_HOST_LOST) return E_ABORT;
    if (host->busy || host->evacuating) return E_PENDING;
    if (!epoch || !host_rect_valid(bounds)) return E_INVALIDARG;
    if (epoch < host->epoch) return S_FALSE;
    if (host->phase == ZWV_PAGE_MOUNTED && (epoch != host->epoch || parent != host->parent)) return E_UNEXPECTED;
    if (host->phase == ZWV_PAGE_PARKED && epoch == host->epoch) return S_FALSE;
    hr = host_parent_valid(host, parent);
    if (FAILED(hr)) return hr;
    visible = visible && bounds.right > bounds.left && bounds.bottom > bounds.top;
    return host_move(host, parent, bounds, visible, epoch, ZWV_PAGE_MOUNTED);
}
HRESULT zwv_page_host_park(ZwvPageHost *host, uint64_t epoch) {
    HRESULT hr = host_owner(host);
    if (FAILED(hr)) return hr;
    if (host->closing || host->phase == ZWV_PAGE_HOST_LOST) return E_ABORT;
    if (host->busy || host->evacuating) return E_PENDING;
    if (host->phase != ZWV_PAGE_MOUNTED || host->epoch != epoch) return S_FALSE;
    RECT bounds = {0, 0, host->bounds.right - host->bounds.left, host->bounds.bottom - host->bounds.top};
    return host_move(host, host->parking, bounds, FALSE, epoch, ZWV_PAGE_PARKED);
}
HRESULT zwv_page_host_resize_parked(ZwvPageHost *host, LONG width, LONG height, uint64_t epoch) {
    HRESULT hr = host_owner(host);
    if (FAILED(hr)) return hr;
    if (host->closing || host->phase == ZWV_PAGE_HOST_LOST) return E_ABORT;
    if (host->busy || host->evacuating) return E_PENDING;
    if (width < 0 || height < 0) return E_INVALIDARG;
    if (host->phase != ZWV_PAGE_PARKED || host->epoch != epoch) return S_FALSE;
    return host_move(host, host->parking, (RECT){0, 0, width, height}, FALSE, epoch, ZWV_PAGE_PARKED);
}
HRESULT zwv_page_host_restore(ZwvPageHost *host, const ZwvPageHostSnapshot *saved, uint64_t epoch) {
    HRESULT hr = host_owner(host);
    if (FAILED(hr)) return hr;
    if (!saved) return E_POINTER;
    if (host->closing || host->phase == ZWV_PAGE_HOST_LOST) return E_ABORT;
    if (host->busy || host->evacuating) return E_PENDING;
    if (host->epoch != epoch) return S_FALSE;
    if (saved->bridge != host->bridge || saved->parking != host->parking || !host_rect_valid(saved->bounds)) return E_INVALIDARG;
    if (saved->phase == ZWV_PAGE_MOUNTED) {
        if (saved->epoch != epoch) return E_INVALIDARG;
        hr = host_parent_valid(host, saved->parent);
        if (FAILED(hr)) return hr;
    } else if (saved->phase != ZWV_PAGE_PARKED || saved->parent != host->parking || saved->visible) return E_INVALIDARG;
    return host_move(host, saved->parent, saved->bounds, saved->visible, epoch, saved->phase);
}
HRESULT zwv_page_host_parent_destroying(ZwvPageHost *host, HWND parent, uint64_t epoch) {
    HRESULT hr = host_owner(host);
    if (FAILED(hr)) return hr;
    if (host->closing || host->evacuating || host->phase == ZWV_PAGE_HOST_LOST) return S_FALSE;
    BOOL candidate = host->busy && host->candidate_parent == parent && host->candidate_epoch == epoch;
    if (!candidate && !(host->phase == ZWV_PAGE_MOUNTED && host->parent == parent && host->epoch == epoch)) return S_FALSE;
    host->evacuating = TRUE;
    if (host->busy) host->interrupted = TRUE;
    host->parent = NULL;
    host->visible = FALSE;
    if (candidate) host->epoch = epoch;
    if (host->bridge) ShowWindow(host->bridge, SW_HIDE);
    hr = host->bridge && host->parking ? host_reparent(host, host->parking) : E_ABORT;
    if (FAILED(hr) || !host->bridge || !host->parking) {
        if (SUCCEEDED(hr)) hr = E_ABORT;
        host_lost(host);
        host->failure = hr;
    } else {
        host->parent = host->parking;
        host->phase = ZWV_PAGE_PARKED;
        hr = host_parked_size(host);
        if (FAILED(hr)) host->failure = hr;
    }
    host->evacuating = FALSE;
    return hr;
}
HRESULT zwv_page_host_close(ZwvPageHost **owner) {
    if (!owner) return E_POINTER;
    ZwvPageHost *host = *owner;
    if (!host) return S_FALSE;
    HRESULT hr = host_owner(host);
    if (FAILED(hr)) return hr;
    if (host->busy || host->evacuating || host->closing) return E_PENDING;
    host->closing = TRUE;
    host->parent = NULL;
    host->visible = FALSE;
    if (host->bridge && !DestroyWindow(host->bridge)) hr = host_win32_failure();
    if (SUCCEEDED(hr) && host->parking && !DestroyWindow(host->parking)) hr = host_win32_failure();
    if (FAILED(hr)) {
        host->failure = hr;
        host_lost(host);
        if (host->bridge) ShowWindow(host->bridge, SW_HIDE);
        host->closing = FALSE;
        return hr;
    }
    *owner = NULL;
    free(host);
    InterlockedDecrement(&live_hosts);
    return S_OK;
}
void zwv_page_host_counts(uint32_t *hosts, uint32_t *parking, uint32_t *bridges) {
    if (hosts) *hosts = (uint32_t)InterlockedCompareExchange(&live_hosts, 0, 0);
    if (parking) *parking = (uint32_t)InterlockedCompareExchange(&live_parking, 0, 0);
    if (bridges) *bridges = (uint32_t)InterlockedCompareExchange(&live_bridges, 0, 0);
}
