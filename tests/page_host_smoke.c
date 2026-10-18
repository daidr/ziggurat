/* Independent Win32 subtree/ownership check. This fixture does not create a
   WebView controller and does not establish DOM, focus or rendering behavior. */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "../src/webview/page_host.h"

static unsigned parent_calls, position_calls, destroy_calls;
static unsigned fail_parent, fail_position, fail_position_again, fail_destroy;
static unsigned create_calls, fail_create;
static unsigned allocate_calls, fail_allocate;
static HWND destroy_during_position;
static ZwvPageHost **close_during_position;
static HRESULT reentrant_close_result;
static HWND WINAPI test_set_parent(HWND child, HWND parent) {
    if (++parent_calls == fail_parent) { SetLastError(ERROR_ACCESS_DENIED); return NULL; }
    return SetParent(child, parent);
}
static BOOL WINAPI test_set_position(HWND hwnd, HWND after, int x, int y, int width, int height, UINT flags) {
    ++position_calls;
    if (position_calls == fail_position || position_calls == fail_position_again) { SetLastError(ERROR_INVALID_PARAMETER); return FALSE; }
    BOOL result = SetWindowPos(hwnd, after, x, y, width, height, flags);
    if (destroy_during_position) {
        HWND parent = destroy_during_position;
        destroy_during_position = NULL;
        DestroyWindow(parent);
    }
    if (close_during_position) {
        ZwvPageHost **host = close_during_position;
        close_during_position = NULL;
        reentrant_close_result = zwv_page_host_close(host);
    }
    return result;
}
static BOOL WINAPI test_destroy_window(HWND hwnd) {
    if (++destroy_calls == fail_destroy) { SetLastError(ERROR_ACCESS_DENIED); return FALSE; }
    return DestroyWindow(hwnd);
}
static HWND WINAPI test_create_window(DWORD ex_style, LPCWSTR cls, LPCWSTR name, DWORD style, int x, int y, int width, int height, HWND parent, HMENU menu, HINSTANCE instance, LPVOID data) {
    if (++create_calls == fail_create) { SetLastError(ERROR_NOT_ENOUGH_MEMORY); return NULL; }
    return CreateWindowExW(ex_style, cls, name, style, x, y, width, height, parent, menu, instance, data);
}
static void *test_calloc(size_t count, size_t size) {
    if (++allocate_calls == fail_allocate) return NULL;
    return calloc(count, size);
}
#define SetParent test_set_parent
#define SetWindowPos test_set_position
#define DestroyWindow test_destroy_window
#define CreateWindowExW test_create_window
#define calloc test_calloc
#include "../src/webview/page_host.c"
#undef SetParent
#undef SetWindowPos
#undef DestroyWindow
#undef CreateWindowExW
#undef calloc

typedef struct Parent {
    ZwvPageHost *host;
    uint64_t epoch;
    HRESULT evacuation;
    unsigned destroying;
} Parent;
static unsigned descendant_destroyed;
static LRESULT CALLBACK parent_proc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp) {
    Parent *parent = (Parent *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (message == WM_NCCREATE) {
        parent = ((CREATESTRUCTW *)lp)->lpCreateParams;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)parent);
    }
    if (message == WM_DESTROY && parent) {
        ++parent->destroying;
        if (parent->host) parent->evacuation = zwv_page_host_parent_destroying(parent->host, hwnd, parent->epoch);
    }
    return DefWindowProcW(hwnd, message, wp, lp);
}
static LRESULT CALLBACK descendant_proc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp) {
    if (message == WM_NCDESTROY) ++descendant_destroyed;
    return DefWindowProcW(hwnd, message, wp, lp);
}
static int fail_at(const char *condition, int line) {
    fprintf(stderr, "page-host check failed at line %d: %s (last=%lu)\n", line, condition, (unsigned long)GetLastError());
    return 1;
}
#define CHECK(value) do { if (!(value)) return fail_at(#value, __LINE__); } while (0)
static void faults_reset(void) {
    parent_calls = position_calls = destroy_calls = create_calls = 0;
    fail_parent = fail_position = fail_position_again = fail_destroy = 0;
    fail_create = 0;
    allocate_calls = fail_allocate = 0;
    destroy_during_position = NULL;
    close_during_position = NULL;
}
static HWND parent_create(Parent *context) {
    return CreateWindowExW(0, L"Ziggurat.PageHost.TestParent", L"", WS_OVERLAPPEDWINDOW, 10, 20, 400, 300, NULL, NULL, GetModuleHandleW(NULL), context);
}
static int ordinary(void) {
    faults_reset();
    ZwvPageHost *host = NULL;
    CHECK(zwv_page_host_create(GetCurrentThreadId(), &host) == S_OK);
    ZwvPageHostSnapshot initial;
    CHECK(zwv_page_host_snapshot(host, &initial) == S_OK);
    CHECK(initial.phase == ZWV_PAGE_PARKED && initial.epoch == 0 && !initial.visible);
    CHECK(GetParent(initial.bridge) == initial.parking && !IsWindowVisible(initial.parking));
    CHECK((GetWindowLongPtrW(initial.bridge, GWL_STYLE) & WS_CHILD) != 0);
    CHECK(GetParent(initial.parking) != HWND_MESSAGE);
    CHECK(zwv_page_host_resize_parked(host, 620, 310, 0) == S_OK);
    ZwvPageHostSnapshot sized;
    CHECK(zwv_page_host_snapshot(host, &sized) == S_OK && sized.bounds.right == 620 && sized.bounds.bottom == 310 && sized.epoch == 0);
    HWND descendant = CreateWindowExW(0, L"Ziggurat.PageHost.TestDescendant", L"", WS_CHILD, 0, 0, 20, 20, initial.bridge, NULL, GetModuleHandleW(NULL), NULL);
    CHECK(descendant != NULL);
    Parent first = {.host = host, .epoch = 1}, second = {.host = host, .epoch = 2};
    HWND a = parent_create(&first), b = parent_create(&second);
    CHECK(a && b);
    RECT bounds = {10, 20, 210, 140};
    CHECK(zwv_page_host_mount(host, a, bounds, TRUE, 1) == S_OK);
    CHECK(GetParent(initial.bridge) == a && GetParent(descendant) == initial.bridge);
    RECT actual;
    CHECK(GetWindowRect(initial.bridge, &actual));
    MapWindowPoints(NULL, a, (POINT *)&actual, 2);
    CHECK(EqualRect(&actual, &bounds));
    CHECK((GetWindowLongPtrW(initial.bridge, GWL_STYLE) & WS_VISIBLE) != 0);
    CHECK(zwv_page_host_mount(host, b, bounds, TRUE, 2) == E_UNEXPECTED);
    CHECK(zwv_page_host_park(host, 0) == S_FALSE);
    CHECK(zwv_page_host_park(host, 1) == S_OK);
    CHECK(GetParent(initial.bridge) == initial.parking && !IsWindowVisible(initial.bridge));
    CHECK(zwv_page_host_mount(host, b, bounds, FALSE, 1) == S_FALSE);
    CHECK(zwv_page_host_mount(host, b, bounds, FALSE, 2) == S_OK);
    ZwvPageHostSnapshot mounted;
    CHECK(zwv_page_host_snapshot(host, &mounted) == S_OK);
    CHECK(zwv_page_host_park(host, 2) == S_OK);
    CHECK(zwv_page_host_restore(host, &mounted, 2) == S_OK && GetParent(initial.bridge) == b);
    CHECK(zwv_page_host_restore(host, &sized, 2) == S_OK && GetParent(initial.bridge) == initial.parking);
    CHECK(zwv_page_host_snapshot(host, &sized) == S_OK && sized.epoch == 2 && sized.bounds.right == 620);
    CHECK(zwv_page_host_mount(host, b, bounds, FALSE, 3) == S_OK);
    second.epoch = 3;
    CHECK(zwv_page_host_restore(host, &mounted, 3) == E_INVALIDARG);
    CHECK(zwv_page_host_mount(host, b, bounds, FALSE, 2) == S_FALSE);
    CHECK(zwv_page_host_mount(host, b, (RECT){0, 0, 0, 0}, TRUE, 3) == S_OK);
    CHECK((GetWindowLongPtrW(initial.bridge, GWL_STYLE) & WS_VISIBLE) == 0);
    CHECK(DestroyWindow(a) && first.evacuation == S_FALSE);
    CHECK(GetParent(initial.bridge) == b && IsWindow(descendant));
    bounds = (RECT){-5, 8, 295, 188};
    CHECK(zwv_page_host_mount(host, b, bounds, TRUE, 3) == S_OK);
    CHECK(DestroyWindow(b) && second.evacuation == S_OK && second.destroying == 1);
    CHECK(GetParent(initial.bridge) == initial.parking && IsWindow(descendant));
    CHECK(descendant_destroyed == 0);
    ZwvPageHostSnapshot parked;
    CHECK(zwv_page_host_snapshot(host, &parked) == S_OK && parked.phase == ZWV_PAGE_PARKED && parked.epoch == 3);
    CHECK(parked.bounds.right == 300 && parked.bounds.bottom == 180);
    CHECK(zwv_page_host_close(&host) == S_OK && host == NULL);
    CHECK(!IsWindow(initial.bridge) && !IsWindow(initial.parking) && !IsWindow(descendant));
    CHECK(descendant_destroyed == 1);
    CHECK(zwv_page_host_close(&host) == S_FALSE);
    return 0;
}
static int failed_candidates(void) {
    faults_reset();
    ZwvPageHost *host = NULL;
    CHECK(zwv_page_host_create(GetCurrentThreadId(), &host) == S_OK);
    ZwvPageHostSnapshot initial, snapshot;
    CHECK(zwv_page_host_snapshot(host, &initial) == S_OK);
    Parent context = {.host = host, .epoch = 1};
    HWND parent = parent_create(&context);
    CHECK(parent);
    RECT bounds = {5, 6, 205, 126};
    fail_parent = 1;
    CHECK(zwv_page_host_mount(host, parent, bounds, TRUE, 1) == HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED));
    CHECK(zwv_page_host_snapshot(host, &snapshot) == S_OK && snapshot.phase == ZWV_PAGE_PARKED && snapshot.epoch == 0);
    CHECK(snapshot.failure == HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED) && snapshot.rollback_failure == S_OK);
    CHECK(GetParent(initial.bridge) == initial.parking);
    faults_reset(); fail_position = 1;
    CHECK(zwv_page_host_mount(host, parent, bounds, TRUE, 1) == HRESULT_FROM_WIN32(ERROR_INVALID_PARAMETER));
    CHECK(zwv_page_host_snapshot(host, &snapshot) == S_OK && snapshot.phase == ZWV_PAGE_PARKED);
    CHECK(snapshot.failure == HRESULT_FROM_WIN32(ERROR_INVALID_PARAMETER) && snapshot.rollback_failure == S_OK);
    CHECK(GetParent(initial.bridge) == initial.parking);
    faults_reset();
    CHECK(zwv_page_host_mount(host, parent, bounds, TRUE, 1) == S_OK);
    fail_position = position_calls + 1; fail_position_again = position_calls + 2;
    CHECK(zwv_page_host_mount(host, parent, (RECT){0, 0, 210, 150}, TRUE, 1) == HRESULT_FROM_WIN32(ERROR_INVALID_PARAMETER));
    CHECK(zwv_page_host_snapshot(host, &snapshot) == S_OK && snapshot.phase == ZWV_PAGE_HOST_LOST);
    CHECK(snapshot.rollback_failure == HRESULT_FROM_WIN32(ERROR_INVALID_PARAMETER));
    CHECK(zwv_page_host_mount(host, parent, bounds, TRUE, 1) == E_ABORT);
    faults_reset();
    CHECK(zwv_page_host_close(&host) == S_OK);
    context.host = NULL;
    CHECK(DestroyWindow(parent));
    return 0;
}
static int raw_failure(void) {
    faults_reset();
    ZwvPageHost *host = NULL;
    CHECK(zwv_page_host_create(GetCurrentThreadId(), &host) == S_OK);
    ZwvPageHostSnapshot snapshot;
    CHECK(zwv_page_host_snapshot(host, &snapshot) == S_OK);
    HWND bridge = snapshot.bridge, parking = snapshot.parking;
    Parent context = {.host = host, .epoch = 4};
    HWND parent = parent_create(&context);
    CHECK(parent && zwv_page_host_mount(host, parent, (RECT){0, 0, 200, 100}, TRUE, 4) == S_OK);
    fail_parent = parent_calls + 1;
    CHECK(DestroyWindow(parent));
    CHECK(context.evacuation == HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED));
    CHECK(zwv_page_host_snapshot(host, &snapshot) == S_OK && snapshot.phase == ZWV_PAGE_HOST_LOST);
    CHECK(snapshot.failure == HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED));
    CHECK(!IsWindow(bridge) && IsWindow(parking));
    CHECK(zwv_page_host_close(&host) == S_OK && host == NULL && !IsWindow(parking));
    return 0;
}
static int reentry(void) {
    faults_reset();
    ZwvPageHost *host = NULL;
    CHECK(zwv_page_host_create(GetCurrentThreadId(), &host) == S_OK);
    ZwvPageHostSnapshot snapshot;
    CHECK(zwv_page_host_snapshot(host, &snapshot) == S_OK);
    HWND bridge = snapshot.bridge;
    Parent context = {.host = host, .epoch = 8};
    HWND parent = parent_create(&context);
    CHECK(parent);
    destroy_during_position = parent;
    CHECK(zwv_page_host_mount(host, parent, (RECT){0, 0, 200, 100}, TRUE, 8) == E_ABORT);
    CHECK(context.evacuation == S_OK && IsWindow(bridge));
    CHECK(zwv_page_host_snapshot(host, &snapshot) == S_OK && snapshot.phase == ZWV_PAGE_PARKED && snapshot.epoch == 8);
    CHECK(GetParent(bridge) == snapshot.parking);
    CHECK(snapshot.bounds.right == 200 && snapshot.bounds.bottom == 100);
    Parent next = {.host = host, .epoch = 9};
    HWND second = parent_create(&next);
    CHECK(second);
    close_during_position = &host;
    CHECK(zwv_page_host_mount(host, second, (RECT){0, 0, 300, 120}, TRUE, 9) == S_OK);
    CHECK(reentrant_close_result == E_PENDING && host != NULL);
    fail_destroy = destroy_calls + 1;
    CHECK(zwv_page_host_close(&host) == HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED) && host != NULL);
    CHECK(zwv_page_host_snapshot(host, &snapshot) == S_OK && snapshot.phase == ZWV_PAGE_HOST_LOST && IsWindow(bridge));
    faults_reset();
    CHECK(zwv_page_host_close(&host) == S_OK && host == NULL);
    next.host = NULL;
    CHECK(DestroyWindow(second));
    CHECK(zwv_page_host_create(GetCurrentThreadId(), &host) == S_OK);
    CHECK(zwv_page_host_snapshot(host, &snapshot) == S_OK);
    HWND parking = snapshot.parking;
    bridge = snapshot.bridge;
    faults_reset(); fail_destroy = 2;
    CHECK(zwv_page_host_close(&host) == HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED) && host != NULL);
    CHECK(zwv_page_host_snapshot(host, &snapshot) == S_OK && snapshot.phase == ZWV_PAGE_HOST_LOST && snapshot.bridge == NULL && snapshot.parking == parking);
    CHECK(!IsWindow(bridge) && IsWindow(parking));
    faults_reset();
    CHECK(zwv_page_host_close(&host) == S_OK && host == NULL && !IsWindow(parking));
    return 0;
}
static int invalid_inputs(void) {
    faults_reset();
    ZwvPageHost *host = NULL;
    CHECK(zwv_page_host_create(0, &host) == RPC_E_WRONG_THREAD && host == NULL);
    CHECK(zwv_page_host_create(GetCurrentThreadId(), &host) == S_OK);
    ZwvPageHostSnapshot snapshot;
    CHECK(zwv_page_host_snapshot(host, &snapshot) == S_OK);
    CHECK(zwv_page_host_mount(host, snapshot.bridge, (RECT){0, 0, 1, 1}, TRUE, 1) == E_INVALIDARG);
    CHECK(zwv_page_host_mount(host, snapshot.parking, (RECT){0, 0, 1, 1}, TRUE, 1) == E_INVALIDARG);
    CHECK(zwv_page_host_mount(host, NULL, (RECT){0, 0, 1, 1}, TRUE, 1) == E_INVALIDARG);
    CHECK(zwv_page_host_mount(host, snapshot.parking, (RECT){INT_MIN, 0, INT_MAX, 1}, TRUE, 1) == E_INVALIDARG);
    CHECK(zwv_page_host_mount(host, snapshot.parking, (RECT){0, 0, 1, 1}, TRUE, 0) == E_INVALIDARG);
    DPI_AWARENESS_CONTEXT different = AreDpiAwarenessContextsEqual(GetWindowDpiAwarenessContext(snapshot.bridge), DPI_AWARENESS_CONTEXT_UNAWARE) ? DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 : DPI_AWARENESS_CONTEXT_UNAWARE;
    DPI_AWARENESS_CONTEXT previous = SetThreadDpiAwarenessContext(different);
    CHECK(previous != NULL);
    Parent context = {0};
    HWND other_dpi = parent_create(&context);
    CHECK(SetThreadDpiAwarenessContext(previous) != NULL && other_dpi != NULL);
    CHECK(!AreDpiAwarenessContextsEqual(GetWindowDpiAwarenessContext(other_dpi), GetWindowDpiAwarenessContext(snapshot.bridge)));
    CHECK(zwv_page_host_mount(host, other_dpi, (RECT){0, 0, 20, 20}, TRUE, 1) == E_INVALIDARG);
    CHECK(DestroyWindow(other_dpi));
    CHECK(zwv_page_host_close(&host) == S_OK);
    return 0;
}
static int construction_cleanup(void) {
    faults_reset();
    ZwvPageHost *host = NULL;
    fail_allocate = 1;
    CHECK(zwv_page_host_create(GetCurrentThreadId(), &host) == E_OUTOFMEMORY && host == NULL);
    CHECK(create_calls == 0);
    uint32_t hosts, parking_count, bridges;
    zwv_page_host_counts(&hosts, &parking_count, &bridges);
    CHECK(hosts == 0 && parking_count == 0 && bridges == 0);
    faults_reset();
    fail_create = 1;
    CHECK(zwv_page_host_create(GetCurrentThreadId(), &host) == HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_MEMORY) && host == NULL);
    faults_reset(); fail_create = 2;
    CHECK(zwv_page_host_create(GetCurrentThreadId(), &host) == HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_MEMORY) && host == NULL);
    faults_reset(); fail_create = 2; fail_destroy = 1;
    CHECK(zwv_page_host_create(GetCurrentThreadId(), &host) == HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_MEMORY) && host != NULL);
    ZwvPageHostSnapshot snapshot;
    CHECK(zwv_page_host_snapshot(host, &snapshot) == S_OK && snapshot.phase == ZWV_PAGE_HOST_LOST);
    CHECK(snapshot.parking != NULL && snapshot.bridge == NULL && IsWindow(snapshot.parking));
    CHECK(snapshot.failure == HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_MEMORY) && snapshot.rollback_failure == HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED));
    zwv_page_host_counts(&hosts, &parking_count, &bridges);
    CHECK(hosts == 1 && parking_count == 1 && bridges == 0);
    HWND parking = snapshot.parking;
    faults_reset();
    CHECK(zwv_page_host_close(&host) == S_OK && host == NULL && !IsWindow(parking));
    return 0;
}
static int geometry_clamp(void) {
    faults_reset();
    ZwvPageHost *host = NULL;
    CHECK(zwv_page_host_create(GetCurrentThreadId(), &host) == S_OK);
    ZwvPageHostSnapshot initial, snapshot;
    CHECK(zwv_page_host_snapshot(host, &initial) == S_OK);
    Parent context = {.host = host, .epoch = 1};
    HWND parent = parent_create(&context);
    CHECK(parent != NULL);
    const LONG large[] = {100000, 1000000};
    for (unsigned i = 0; i < sizeof(large) / sizeof(large[0]); ++i) {
        CHECK(zwv_page_host_mount(host, parent, (RECT){0, 0, large[i], large[i]}, FALSE, 1) == ZWV_PAGE_HOST_GEOMETRY_MISMATCH);
        CHECK(zwv_page_host_snapshot(host, &snapshot) == S_OK && snapshot.phase == ZWV_PAGE_PARKED && snapshot.epoch == 0);
        CHECK(EqualRect(&snapshot.bounds, &initial.bounds) && GetParent(initial.bridge) == initial.parking);
        CHECK(snapshot.failure == ZWV_PAGE_HOST_GEOMETRY_MISMATCH && snapshot.rollback_failure == S_OK);
        RECT actual;
        CHECK(GetClientRect(initial.bridge, &actual) && actual.right == 1 && actual.bottom == 1);
    }
    RECT bounds = {10, 20, 210, 120};
    CHECK(zwv_page_host_mount(host, parent, bounds, FALSE, 1) == S_OK);
    CHECK(zwv_page_host_mount(host, parent, (RECT){0, 0, 1000000, 1000000}, TRUE, 1) == ZWV_PAGE_HOST_GEOMETRY_MISMATCH);
    CHECK(zwv_page_host_snapshot(host, &snapshot) == S_OK && snapshot.phase == ZWV_PAGE_MOUNTED && snapshot.epoch == 1 && !snapshot.visible);
    CHECK(EqualRect(&snapshot.bounds, &bounds) && GetParent(initial.bridge) == parent);
    CHECK(zwv_page_host_close(&host) == S_OK);
    context.host = NULL;
    CHECK(DestroyWindow(parent));
    return 0;
}
int main(void) {
    WNDCLASSW parent = {0}, descendant = {0};
    parent.hInstance = descendant.hInstance = GetModuleHandleW(NULL);
    parent.lpfnWndProc = parent_proc; parent.lpszClassName = L"Ziggurat.PageHost.TestParent";
    descendant.lpfnWndProc = descendant_proc; descendant.lpszClassName = L"Ziggurat.PageHost.TestDescendant";
    CHECK(RegisterClassW(&parent) && RegisterClassW(&descendant));
    CHECK(!ordinary());
    CHECK(!failed_candidates());
    CHECK(!raw_failure());
    CHECK(!reentry());
    CHECK(!invalid_inputs());
    CHECK(!construction_cleanup());
    CHECK(!geometry_clamp());
    uint32_t hosts, parking, bridges;
    zwv_page_host_counts(&hosts, &parking, &bridges);
    CHECK(hosts == 0 && parking == 0 && bridges == 0);
    puts("page-host native: parent/bridge/parking, epochs, raw destruction, rollback, reentry and retry passed; no COM/DOM validation");
    return 0;
}
