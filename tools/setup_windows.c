// Shell link creation for the setup program. COM is initialized and released
// within the call; the setup program runs no UI or message loop.
#define COBJMACROS
#include <windows.h>
#include <shlobj.h>
#include <objbase.h>

long zsetup_create_shortcut(const wchar_t *link, const wchar_t *target, const wchar_t *directory, const wchar_t *description) {
    HRESULT init = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (FAILED(init) && init != RPC_E_CHANGED_MODE) return init;
    IShellLinkW *shell = NULL;
    HRESULT hr = CoCreateInstance(&CLSID_ShellLink, NULL, CLSCTX_INPROC_SERVER, &IID_IShellLinkW, (void **)&shell);
    if (SUCCEEDED(hr)) hr = IShellLinkW_SetPath(shell, target);
    if (SUCCEEDED(hr)) hr = IShellLinkW_SetWorkingDirectory(shell, directory);
    if (SUCCEEDED(hr)) hr = IShellLinkW_SetDescription(shell, description);
    if (SUCCEEDED(hr)) hr = IShellLinkW_SetIconLocation(shell, target, 0);
    IPersistFile *file = NULL;
    if (SUCCEEDED(hr)) hr = IShellLinkW_QueryInterface(shell, &IID_IPersistFile, (void **)&file);
    if (SUCCEEDED(hr)) hr = IPersistFile_Save(file, link, TRUE);
    if (file) IPersistFile_Release(file);
    if (shell) IShellLinkW_Release(shell);
    if (SUCCEEDED(init)) CoUninitialize();
    return hr;
}
