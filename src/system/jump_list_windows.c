#define WIN32_LEAN_AND_MEAN
#define NO_STRICT
#define COBJMACROS
#include <windows.h>
#include <objbase.h>
#include <objectarray.h>
#include <propsys.h>
#include <shlobj.h>
#include <shobjidl.h>

static const CLSID destination_list_class = {0x77F10CF0, 0x3DB5, 0x4966, {0xB5, 0x20, 0xB7, 0xC5, 0x4F, 0xD3, 0x5E, 0xD6}};
static const IID destination_list_interface = {0x6332DEBF, 0x87B5, 0x4670, {0x90, 0xC0, 0x5E, 0x57, 0xB4, 0x08, 0xA4, 0x9E}};
static const CLSID collection_class = {0x2D3468C1, 0x36A7, 0x43B6, {0xAC, 0x24, 0xD3, 0xF0, 0x2F, 0xD9, 0x60, 0x7A}};
static const IID collection_interface = {0x5632B1A4, 0xE38A, 0x400A, {0x92, 0x8A, 0xD4, 0xCD, 0x63, 0x23, 0x02, 0x95}};
static const IID object_array_interface = {0x92CA9DCD, 0x5622, 0x4BBA, {0xA8, 0x05, 0x5E, 0x9F, 0x54, 0x1B, 0xD8, 0xC9}};
static const CLSID shell_link_class = {0x00021401, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
static const IID shell_link_interface = {0x000214F9, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
static const IID property_store_interface = {0x886D8EEB, 0x8CF2, 0x4446, {0x8D, 0x02, 0xCD, 0xBA, 0x1D, 0xBD, 0xCF, 0x99}};
static const PROPERTYKEY title_key = {{0xF29F85E0, 0x4FF9, 0x1068, {0xAB, 0x91, 0x08, 0x00, 0x2B, 0x27, 0xB3, 0xD9}}, 2};

typedef struct {
    ICustomDestinationList *list;
    IObjectCollection *tasks;
    int apartment;
} JumpList;

static void release(JumpList *self) {
    if (self->tasks) IObjectCollection_Release(self->tasks);
    if (self->list) ICustomDestinationList_Release(self->list);
    if (self->apartment) CoUninitialize();
}

/* Starts a list replacing the application's whole jump list. The apartment
 * is balanced by finish only when this call initialized it. */
HRESULT ziggurat_system_jump_list_begin(const wchar_t *app_id, void **out) {
    *out = NULL;
    JumpList *self = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(JumpList));
    if (!self) return E_OUTOFMEMORY;
    HRESULT result = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (SUCCEEDED(result)) self->apartment = 1;
    else if (result != RPC_E_CHANGED_MODE) goto failed;
    result = CoCreateInstance(&destination_list_class, NULL, CLSCTX_INPROC_SERVER, &destination_list_interface, (void **)&self->list);
    if (FAILED(result)) goto failed;
    if (app_id) {
        result = ICustomDestinationList_SetAppID(self->list, app_id);
        if (FAILED(result)) goto failed;
    }
    UINT slots = 0;
    IObjectArray *removed = NULL;
    result = ICustomDestinationList_BeginList(self->list, &slots, &object_array_interface, (void **)&removed);
    if (FAILED(result)) goto failed;
    IObjectArray_Release(removed);
    result = CoCreateInstance(&collection_class, NULL, CLSCTX_INPROC_SERVER, &collection_interface, (void **)&self->tasks);
    if (FAILED(result)) {
        ICustomDestinationList_AbortList(self->list);
        goto failed;
    }
    *out = self;
    return S_OK;
failed:
    release(self);
    HeapFree(GetProcessHeap(), 0, self);
    return result;
}

HRESULT ziggurat_system_jump_list_add(void *handle, const wchar_t *title, const wchar_t *description, const wchar_t *path, const wchar_t *arguments, const wchar_t *directory, const wchar_t *icon, int icon_index) {
    JumpList *self = handle;
    IShellLinkW *link = NULL;
    IPropertyStore *store = NULL;
    HRESULT result = CoCreateInstance(&shell_link_class, NULL, CLSCTX_INPROC_SERVER, &shell_link_interface, (void **)&link);
    if (FAILED(result)) return result;
    result = IShellLinkW_SetPath(link, path);
    if (SUCCEEDED(result)) result = IShellLinkW_SetArguments(link, arguments);
    if (SUCCEEDED(result) && description[0]) result = IShellLinkW_SetDescription(link, description);
    if (SUCCEEDED(result) && directory[0]) result = IShellLinkW_SetWorkingDirectory(link, directory);
    if (SUCCEEDED(result) && icon[0]) result = IShellLinkW_SetIconLocation(link, icon, icon_index);
    if (SUCCEEDED(result)) result = IShellLinkW_QueryInterface(link, &property_store_interface, (void **)&store);
    if (SUCCEEDED(result)) {
        /* The title is a property of the link, not its description. */
        PROPVARIANT value;
        PropVariantInit(&value);
        size_t bytes = (lstrlenW(title) + 1) * sizeof(wchar_t);
        value.vt = VT_LPWSTR;
        value.pwszVal = CoTaskMemAlloc(bytes);
        if (!value.pwszVal) result = E_OUTOFMEMORY;
        else {
            CopyMemory(value.pwszVal, title, bytes);
            result = IPropertyStore_SetValue(store, &title_key, &value);
            if (SUCCEEDED(result)) result = IPropertyStore_Commit(store);
            PropVariantClear(&value);
        }
        IPropertyStore_Release(store);
    }
    if (SUCCEEDED(result)) result = IObjectCollection_AddObject(self->tasks, (IUnknown *)link);
    IShellLinkW_Release(link);
    return result;
}

/* Commits the tasks, with the Recent category when asked, or abandons the
 * list. Either way the handle is released. */
HRESULT ziggurat_system_jump_list_finish(void *handle, int commit, int recent) {
    JumpList *self = handle;
    HRESULT result = S_OK;
    if (commit) {
        if (recent) result = ICustomDestinationList_AppendKnownCategory(self->list, KDC_RECENT);
        UINT count = 0;
        if (SUCCEEDED(result)) result = IObjectCollection_GetCount(self->tasks, &count);
        if (SUCCEEDED(result) && count) {
            IObjectArray *array = NULL;
            result = IObjectCollection_QueryInterface(self->tasks, &object_array_interface, (void **)&array);
            if (SUCCEEDED(result)) {
                result = ICustomDestinationList_AddUserTasks(self->list, array);
                IObjectArray_Release(array);
            }
        }
        if (SUCCEEDED(result)) result = ICustomDestinationList_CommitList(self->list);
        else ICustomDestinationList_AbortList(self->list);
    } else ICustomDestinationList_AbortList(self->list);
    release(self);
    HeapFree(GetProcessHeap(), 0, self);
    return result;
}

/* Removes the application's custom jump list. */
HRESULT ziggurat_system_jump_list_delete(const wchar_t *app_id) {
    int apartment = 0;
    HRESULT result = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (SUCCEEDED(result)) apartment = 1;
    else if (result != RPC_E_CHANGED_MODE) return result;
    ICustomDestinationList *list = NULL;
    result = CoCreateInstance(&destination_list_class, NULL, CLSCTX_INPROC_SERVER, &destination_list_interface, (void **)&list);
    if (SUCCEEDED(result)) {
        result = ICustomDestinationList_DeleteList(list, app_id);
        ICustomDestinationList_Release(list);
    }
    if (apartment) CoUninitialize();
    return result;
}

/* Records a file in the shell's recent documents and, through them, in the
 * Recent category of the application's jump list. */
void ziggurat_system_recent_add(const wchar_t *path) {
    SHAddToRecentDocs(SHARD_PATHW, path);
}
