#define WIN32_LEAN_AND_MEAN
#define NO_STRICT
#define COBJMACROS
#include <windows.h>
#include <shobjidl.h>

static const CLSID taskbar_class = {0x56FDF344, 0xFD6D, 0x11D0, {0x95, 0x8A, 0x00, 0x60, 0x97, 0xC9, 0xA0, 0x90}};
static const IID taskbar_interface = {0xEA1AFB91, 0x9E28, 0x4B86, {0x90, 0xE9, 0x9E, 0x9F, 0x8A, 0x5E, 0xEF, 0xAF}};

/* Creates ITaskbarList3 on the calling thread. The apartment is balanced by
 * release only when this call initialized it. */
HRESULT ziggurat_system_taskbar_create(void **out, int *apartment) {
    *out = NULL;
    *apartment = 0;
    HRESULT result = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (SUCCEEDED(result)) *apartment = 1;
    else if (result != RPC_E_CHANGED_MODE) return result;
    ITaskbarList3 *taskbar = NULL;
    result = CoCreateInstance(&taskbar_class, NULL, CLSCTX_INPROC_SERVER, &taskbar_interface, (void **)&taskbar);
    if (SUCCEEDED(result)) {
        result = ITaskbarList3_HrInit(taskbar);
        if (FAILED(result)) {
            ITaskbarList3_Release(taskbar);
            taskbar = NULL;
        }
    }
    if (FAILED(result)) {
        if (*apartment) CoUninitialize();
        *apartment = 0;
        return result;
    }
    *out = taskbar;
    return S_OK;
}

HRESULT ziggurat_system_taskbar_progress(void *taskbar, void *window, int state, unsigned long long completed, unsigned long long total) {
    ITaskbarList3 *list = taskbar;
    HRESULT result = ITaskbarList3_SetProgressState(list, (HWND)window, (TBPFLAG)state);
    if (FAILED(result) || state == TBPF_NOPROGRESS || state == TBPF_INDETERMINATE) return result;
    return ITaskbarList3_SetProgressValue(list, (HWND)window, completed, total);
}

HRESULT ziggurat_system_taskbar_overlay(void *taskbar, void *window, void *icon, const wchar_t *description) {
    return ITaskbarList3_SetOverlayIcon((ITaskbarList3 *)taskbar, (HWND)window, (HICON)icon, description);
}

void ziggurat_system_taskbar_release(void *taskbar, int apartment) {
    ITaskbarList3_Release((ITaskbarList3 *)taskbar);
    if (apartment) CoUninitialize();
}
