#define WIN32_LEAN_AND_MEAN
#define NO_STRICT
#define COBJMACROS
#define CONST_VTABLE
#include <windows.h>
#include <roapi.h>
#include <winstring.h>
#include <inspectable.h>
#include <asyncinfo.h>
#include <stdlib.h>

/* Minimal typed Windows Runtime ABI declarations. No C++ runtime is needed. */
#define Z_UNKNOWN(T) \
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(T *, REFIID, void **); \
    ULONG (STDMETHODCALLTYPE *AddRef)(T *); \
    ULONG (STDMETHODCALLTYPE *Release)(T *)
#define Z_INSPECTABLE(T) \
    Z_UNKNOWN(T); \
    HRESULT (STDMETHODCALLTYPE *GetIids)(T *, ULONG *, IID **); \
    HRESULT (STDMETHODCALLTYPE *GetRuntimeClassName)(T *, HSTRING *); \
    HRESULT (STDMETHODCALLTYPE *GetTrustLevel)(T *, TrustLevel *)

typedef struct Picker Picker;
typedef struct Vector Vector;
typedef struct Operation Operation;
typedef struct Completion Completion;
typedef struct StorageItem StorageItem;
typedef struct InitializeWindow InitializeWindow;
typedef struct SavePicker SavePicker;
typedef struct ChoiceMap ChoiceMap;
typedef struct FileView FileView;

typedef struct PickerVtbl {
    Z_INSPECTABLE(Picker);
    HRESULT (STDMETHODCALLTYPE *get_ViewMode)(Picker *, int *);
    HRESULT (STDMETHODCALLTYPE *put_ViewMode)(Picker *, int);
    HRESULT (STDMETHODCALLTYPE *get_SettingsIdentifier)(Picker *, HSTRING *);
    HRESULT (STDMETHODCALLTYPE *put_SettingsIdentifier)(Picker *, HSTRING);
    HRESULT (STDMETHODCALLTYPE *get_SuggestedStartLocation)(Picker *, int *);
    HRESULT (STDMETHODCALLTYPE *put_SuggestedStartLocation)(Picker *, int);
    HRESULT (STDMETHODCALLTYPE *get_CommitButtonText)(Picker *, HSTRING *);
    HRESULT (STDMETHODCALLTYPE *put_CommitButtonText)(Picker *, HSTRING);
    HRESULT (STDMETHODCALLTYPE *get_FileTypeFilter)(Picker *, Vector **);
    HRESULT (STDMETHODCALLTYPE *PickSingleFileAsync)(Picker *, Operation **);
    HRESULT (STDMETHODCALLTYPE *PickMultipleFilesAsync)(Picker *, void **);
} PickerVtbl;
struct Picker { const PickerVtbl *lpVtbl; };
typedef struct VectorVtbl {
    Z_INSPECTABLE(Vector);
    HRESULT (STDMETHODCALLTYPE *GetAt)(Vector *, UINT32, HSTRING *);
    HRESULT (STDMETHODCALLTYPE *get_Size)(Vector *, UINT32 *);
    HRESULT (STDMETHODCALLTYPE *GetView)(Vector *, void **);
    HRESULT (STDMETHODCALLTYPE *IndexOf)(Vector *, HSTRING, UINT32 *, unsigned char *);
    HRESULT (STDMETHODCALLTYPE *SetAt)(Vector *, UINT32, HSTRING);
    HRESULT (STDMETHODCALLTYPE *InsertAt)(Vector *, UINT32, HSTRING);
    HRESULT (STDMETHODCALLTYPE *RemoveAt)(Vector *, UINT32);
    HRESULT (STDMETHODCALLTYPE *Append)(Vector *, HSTRING);
} VectorVtbl;
struct Vector { const VectorVtbl *lpVtbl; };
typedef struct OperationVtbl {
    Z_INSPECTABLE(Operation);
    HRESULT (STDMETHODCALLTYPE *put_Completed)(Operation *, Completion *);
    HRESULT (STDMETHODCALLTYPE *get_Completed)(Operation *, Completion **);
    HRESULT (STDMETHODCALLTYPE *GetResults)(Operation *, IUnknown **);
} OperationVtbl;
struct Operation { const OperationVtbl *lpVtbl; };
typedef struct CompletionVtbl {
    Z_UNKNOWN(Completion);
    HRESULT (STDMETHODCALLTYPE *Invoke)(Completion *, Operation *, AsyncStatus);
} CompletionVtbl;
struct Completion { const CompletionVtbl *lpVtbl; };
typedef struct StorageItemVtbl {
    Z_INSPECTABLE(StorageItem);
    HRESULT (STDMETHODCALLTYPE *RenameDefault)(StorageItem *, HSTRING, void **);
    HRESULT (STDMETHODCALLTYPE *Rename)(StorageItem *, HSTRING, int, void **);
    HRESULT (STDMETHODCALLTYPE *DeleteDefault)(StorageItem *, void **);
    HRESULT (STDMETHODCALLTYPE *Delete)(StorageItem *, int, void **);
    HRESULT (STDMETHODCALLTYPE *GetBasicPropertiesAsync)(StorageItem *, void **);
    HRESULT (STDMETHODCALLTYPE *get_Name)(StorageItem *, HSTRING *);
    HRESULT (STDMETHODCALLTYPE *get_Path)(StorageItem *, HSTRING *);
} StorageItemVtbl;
struct StorageItem { const StorageItemVtbl *lpVtbl; };
typedef struct InitializeWindowVtbl {
    Z_UNKNOWN(InitializeWindow);
    HRESULT (STDMETHODCALLTYPE *Initialize)(InitializeWindow *, HWND);
} InitializeWindowVtbl;
struct InitializeWindow { const InitializeWindowVtbl *lpVtbl; };
typedef struct SavePickerVtbl {
    Z_INSPECTABLE(SavePicker);
    HRESULT (STDMETHODCALLTYPE *get_SettingsIdentifier)(SavePicker *, HSTRING *);
    HRESULT (STDMETHODCALLTYPE *put_SettingsIdentifier)(SavePicker *, HSTRING);
    HRESULT (STDMETHODCALLTYPE *get_SuggestedStartLocation)(SavePicker *, int *);
    HRESULT (STDMETHODCALLTYPE *put_SuggestedStartLocation)(SavePicker *, int);
    HRESULT (STDMETHODCALLTYPE *get_CommitButtonText)(SavePicker *, HSTRING *);
    HRESULT (STDMETHODCALLTYPE *put_CommitButtonText)(SavePicker *, HSTRING);
    HRESULT (STDMETHODCALLTYPE *get_FileTypeChoices)(SavePicker *, ChoiceMap **);
    HRESULT (STDMETHODCALLTYPE *get_DefaultFileExtension)(SavePicker *, HSTRING *);
    HRESULT (STDMETHODCALLTYPE *put_DefaultFileExtension)(SavePicker *, HSTRING);
    HRESULT (STDMETHODCALLTYPE *get_SuggestedSaveFile)(SavePicker *, void **);
    HRESULT (STDMETHODCALLTYPE *put_SuggestedSaveFile)(SavePicker *, void *);
    HRESULT (STDMETHODCALLTYPE *get_SuggestedFileName)(SavePicker *, HSTRING *);
    HRESULT (STDMETHODCALLTYPE *put_SuggestedFileName)(SavePicker *, HSTRING);
    HRESULT (STDMETHODCALLTYPE *PickSaveFileAsync)(SavePicker *, Operation **);
} SavePickerVtbl;
struct SavePicker { const SavePickerVtbl *lpVtbl; };
typedef struct ChoiceMapVtbl {
    Z_INSPECTABLE(ChoiceMap);
    HRESULT (STDMETHODCALLTYPE *Lookup)(ChoiceMap *, HSTRING, Vector **);
    HRESULT (STDMETHODCALLTYPE *get_Size)(ChoiceMap *, UINT32 *);
    HRESULT (STDMETHODCALLTYPE *HasKey)(ChoiceMap *, HSTRING, unsigned char *);
    HRESULT (STDMETHODCALLTYPE *GetView)(ChoiceMap *, void **);
    HRESULT (STDMETHODCALLTYPE *Insert)(ChoiceMap *, HSTRING, Vector *, unsigned char *);
} ChoiceMapVtbl;
struct ChoiceMap { const ChoiceMapVtbl *lpVtbl; };
typedef struct FileViewVtbl {
    Z_INSPECTABLE(FileView);
    HRESULT (STDMETHODCALLTYPE *GetAt)(FileView *, UINT32, IUnknown **);
    HRESULT (STDMETHODCALLTYPE *get_Size)(FileView *, UINT32 *);
} FileViewVtbl;
struct FileView { const FileViewVtbl *lpVtbl; };

static const IID iid_unknown = {0,0,0,{0xc0,0,0,0,0,0,0,0x46}};
static const IID iid_agile = {0x94ea2b94,0xe9cc,0x49e0,{0xc0,0xff,0xee,0x64,0xca,0x8f,0x5b,0x90}};
static const IID iid_picker = {0x2ca8278a,0x12c5,0x4c5f,{0x89,0x77,0x94,0x54,0x77,0x93,0xc2,0x41}};
static const IID iid_save_picker = {0x3286ffcb,0x617f,0x4cc5,{0xaf,0x6a,0xb3,0xfd,0xf2,0x9a,0xd1,0x45}};
static const IID iid_folder_picker = {0x084f7799,0xf3fb,0x400a,{0x99,0xb1,0x7b,0x4a,0x77,0x2f,0xd6,0x0d}};
static const IID iid_window = {0x3e68d4bd,0x7135,0x4d10,{0x80,0x18,0x9f,0xb6,0xd9,0xf3,0x3f,0xa1}};
static const IID iid_item = {0x4207a996,0xca2f,0x42f7,{0xbd,0xe8,0x8b,0x10,0x45,0x7a,0x7f,0x30}};
static const IID iid_info = {0x36,0,0,{0xc0,0,0,0,0,0,0,0x46}};
static const IID iid_completed = {0xe521c894,0x2c26,0x5946,{0x9e,0x61,0x2b,0x5e,0x18,0x8d,0x01,0xed}};
static const IID iid_completed_multiple = {0xcb4206c5,0x0988,0x5104,{0xaf,0xa9,0x25,0x3c,0x29,0x8f,0x86,0xfd}};
static const IID iid_completed_folder = {0xc211026e,0x9e63,0x5452,{0xba,0x54,0x3a,0x07,0xd6,0xa9,0x68,0x74}};

typedef struct Filter { const WCHAR *text; UINT32 length; } Filter;
typedef struct RuntimeApi {
    HRESULT (WINAPI *initialize)(RO_INIT_TYPE);
    void (WINAPI *uninitialize)(void);
    HRESULT (WINAPI *activate)(HSTRING, IInspectable **);
    HRESULT (WINAPI *create_string)(PCNZWCH, UINT32, HSTRING *);
    HRESULT (WINAPI *delete_string)(HSTRING);
    PCWSTR (WINAPI *string_buffer)(HSTRING, UINT32 *);
} RuntimeApi;
typedef struct State {
    Completion completion;
    LONG refs;
    HANDLE event;
    IUnknown *picker;
    Picker *filter_source;
    Operation *operation;
    IAsyncInfo *info;
    HSTRING paths[128];
    UINT32 path_count;
    UINT32 kind;
    HMODULE runtime;
    RuntimeApi api;
    DWORD owner_thread;
    BOOL initialized;
} State;
static LONG live_states;

static State *from_completion(Completion *value) { return (State *)value; }
static ULONG STDMETHODCALLTYPE completion_add(Completion *value) { return InterlockedIncrement(&from_completion(value)->refs); }
static ULONG STDMETHODCALLTYPE completion_release(Completion *value) {
    State *s = from_completion(value);
    LONG refs = InterlockedDecrement(&s->refs);
    if (!refs) {
        CloseHandle(s->event);
        InterlockedDecrement(&live_states);
        free(s);
    }
    return refs;
}
static HRESULT STDMETHODCALLTYPE completion_query(Completion *value, REFIID iid, void **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    State *s = from_completion(value);
    const IID *completed = s->kind == 2 ? &iid_completed_multiple : s->kind == 3 ? &iid_completed_folder : &iid_completed;
    if (!IsEqualIID(iid, &iid_unknown) && !IsEqualIID(iid, completed) && !IsEqualIID(iid, &iid_agile)) return E_NOINTERFACE;
    *out = value;
    completion_add(value);
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE completion_invoke(Completion *value, Operation *operation, AsyncStatus status) {
    (void)operation; (void)status;
    /* Runtime threads touch no Zig/App context or apartment-bound interfaces.
       Their COM reference owns the signal handle until this call returns. */
    return SetEvent(from_completion(value)->event) ? S_OK : HRESULT_FROM_WIN32(GetLastError());
}
static const CompletionVtbl completion_vtable = {completion_query, completion_add, completion_release, completion_invoke};

void zfp_close(State *s) {
    if (!s) return;
    if (s->owner_thread != GetCurrentThreadId()) abort();
    if (s->info) {
        IAsyncInfo_Cancel(s->info);
        IAsyncInfo_Close(s->info);
        IAsyncInfo_Release(s->info);
        s->info = NULL;
    }
    if (s->operation) { s->operation->lpVtbl->Release(s->operation); s->operation = NULL; }
    if (s->picker) { IUnknown_Release(s->picker); s->picker = NULL; }
    if (s->filter_source) { s->filter_source->lpVtbl->Release(s->filter_source); s->filter_source = NULL; }
    for (UINT32 i = 0; i < s->path_count; ++i) s->api.delete_string(s->paths[i]);
    s->path_count = 0;
    if (s->initialized) { s->initialized = FALSE; s->api.uninitialize(); }
    if (s->runtime) { FreeLibrary(s->runtime); s->runtime = NULL; }
    completion_release(&s->completion);
}

State *zfp_create(HWND hwnd, UINT32 kind, const Filter *filters, UINT32 count, const WCHAR *suggested_name, UINT32 suggested_len, HRESULT *error, HANDLE *event) {
    State *s = calloc(1, sizeof(*s));
    IInspectable *instance = NULL;
    InitializeWindow *initialize = NULL;
    Vector *vector = NULL;
    ChoiceMap *choices = NULL;
    HSTRING name = NULL, extension = NULL;
    HRESULT hr = E_OUTOFMEMORY;
    if (!s) goto done;
    s->completion.lpVtbl = &completion_vtable;
    s->refs = 1;
    s->owner_thread = GetCurrentThreadId();
    s->kind = kind;
    InterlockedIncrement(&live_states);
    s->event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!s->event) { hr = HRESULT_FROM_WIN32(GetLastError()); goto done; }
    s->runtime = LoadLibraryExW(L"combase.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!s->runtime) { hr = HRESULT_FROM_WIN32(GetLastError()); goto done; }
#define Z_LOAD(member, name) do { \
    FARPROC address = GetProcAddress(s->runtime, name); \
    if (!address) { hr = HRESULT_FROM_WIN32(GetLastError()); goto done; } \
    memcpy(&s->api.member, &address, sizeof(address)); \
} while (0)
    Z_LOAD(initialize, "RoInitialize");
    Z_LOAD(uninitialize, "RoUninitialize");
    Z_LOAD(activate, "RoActivateInstance");
    Z_LOAD(create_string, "WindowsCreateString");
    Z_LOAD(delete_string, "WindowsDeleteString");
    Z_LOAD(string_buffer, "WindowsGetStringRawBuffer");
#undef Z_LOAD
    hr = s->api.initialize(RO_INIT_SINGLETHREADED);
    if (FAILED(hr)) goto done;
    s->initialized = TRUE;
    const WCHAR *class_name = kind == 1 ? L"Windows.Storage.Pickers.FileSavePicker" : kind == 3 ? L"Windows.Storage.Pickers.FolderPicker" : L"Windows.Storage.Pickers.FileOpenPicker";
    hr = s->api.create_string(class_name, (UINT32)wcslen(class_name), &name);
    if (FAILED(hr)) goto done;
    hr = s->api.activate(name, &instance);
    if (FAILED(hr)) goto done;
    const IID *picker_id = kind == 1 ? &iid_save_picker : kind == 3 ? &iid_folder_picker : &iid_picker;
    hr = IInspectable_QueryInterface(instance, picker_id, (void **)&s->picker);
    if (FAILED(hr)) goto done;
    hr = IInspectable_QueryInterface(instance, &iid_window, (void **)&initialize);
    if (FAILED(hr)) goto done;
    hr = initialize->lpVtbl->Initialize(initialize, hwnd);
    if (FAILED(hr)) goto done;
    if (kind == 1) {
        IInspectable_Release(instance); instance = NULL;
        s->api.delete_string(name); name = NULL;
        static const WCHAR filter_class[] = L"Windows.Storage.Pickers.FileOpenPicker";
        hr = s->api.create_string(filter_class, ARRAYSIZE(filter_class) - 1, &name);
        if (FAILED(hr)) goto done;
        hr = s->api.activate(name, &instance);
        if (FAILED(hr)) goto done;
        hr = IInspectable_QueryInterface(instance, &iid_picker, (void **)&s->filter_source);
        if (FAILED(hr)) goto done;
        hr = s->filter_source->lpVtbl->get_FileTypeFilter(s->filter_source, &vector);
    } else hr = ((Picker *)s->picker)->lpVtbl->get_FileTypeFilter((Picker *)s->picker, &vector);
    if (FAILED(hr)) goto done;
    for (UINT32 i = 0; i < count; ++i) {
        hr = s->api.create_string(filters[i].text, filters[i].length, &extension);
        if (FAILED(hr)) goto done;
        hr = vector->lpVtbl->Append(vector, extension);
        s->api.delete_string(extension); extension = NULL;
        if (FAILED(hr)) goto done;
    }
    if (kind == 1) {
        SavePicker *save = (SavePicker *)s->picker;
        hr = save->lpVtbl->get_FileTypeChoices(save, &choices);
        if (FAILED(hr)) goto done;
        hr = s->api.create_string(L"Files", 5, &extension);
        if (FAILED(hr)) goto done;
        unsigned char replaced;
        hr = choices->lpVtbl->Insert(choices, extension, vector, &replaced);
        s->api.delete_string(extension); extension = NULL;
        if (FAILED(hr)) goto done;
        hr = s->api.create_string(suggested_name, suggested_len, &extension);
        if (FAILED(hr)) goto done;
        hr = save->lpVtbl->put_SuggestedFileName(save, extension);
    }
done:
    if (extension) s->api.delete_string(extension);
    if (name) s->api.delete_string(name);
    if (vector) vector->lpVtbl->Release(vector);
    if (choices) choices->lpVtbl->Release(choices);
    if (initialize) initialize->lpVtbl->Release(initialize);
    if (instance) IInspectable_Release(instance);
    *error = hr;
    if (FAILED(hr)) { zfp_close(s); return NULL; }
    *event = s->event;
    return s;
}

HRESULT zfp_start(State *s) {
    Picker *open = (Picker *)s->picker;
    SavePicker *save = (SavePicker *)s->picker;
    HRESULT hr = s->kind == 1 ? save->lpVtbl->PickSaveFileAsync(save, &s->operation) :
        s->kind == 2 ? open->lpVtbl->PickMultipleFilesAsync(open, (void **)&s->operation) :
        open->lpVtbl->PickSingleFileAsync(open, &s->operation);
    if (FAILED(hr)) return hr;
    hr = s->operation->lpVtbl->QueryInterface(s->operation, &iid_info, (void **)&s->info);
    if (FAILED(hr)) return hr;
    return s->operation->lpVtbl->put_Completed(s->operation, &s->completion);
}
HRESULT zfp_cancel(State *s) { return s->info ? IAsyncInfo_Cancel(s->info) : E_UNEXPECTED; }

/* Called only after the core one-shot event has returned to the owning STA.
   A NULL result is normal user cancellation. The HSTRING remains native-owned
   until zfp_close; Zig copies into the caller's explicit bounded destination. */
HRESULT zfp_collect(State *s, UINT32 *count, int *cancelled) {
    AsyncStatus status;
    IUnknown *file = NULL;
    StorageItem *item = NULL;
    FileView *files = NULL;
    HRESULT hr = IAsyncInfo_get_Status(s->info, &status);
    *count = 0; *cancelled = 0;
    if (FAILED(hr)) return hr;
    if (status == Canceled) { *cancelled = 1; return S_OK; }
    if (status == Error) {
        HRESULT code = E_FAIL;
        hr = IAsyncInfo_get_ErrorCode(s->info, &code);
        return FAILED(hr) ? hr : FAILED(code) ? code : E_FAIL;
    }
    if (status != Completed) return E_PENDING;
    hr = s->operation->lpVtbl->GetResults(s->operation, &file);
    if (FAILED(hr)) return hr;
    if (!file) { *cancelled = 1; return S_OK; }
    UINT32 result_count = 1;
    if (s->kind == 2) {
        files = (FileView *)file;
        file = NULL;
        hr = files->lpVtbl->get_Size(files, &result_count);
        if (FAILED(hr)) goto done;
        if (result_count > ARRAYSIZE(s->paths)) { hr = E_BOUNDS; goto done; }
    }
    for (UINT32 index = 0; index < result_count; ++index) {
        if (files) {
            hr = files->lpVtbl->GetAt(files, index, &file);
            if (FAILED(hr)) goto done;
        }
        hr = IUnknown_QueryInterface(file, &iid_item, (void **)&item);
        IUnknown_Release(file); file = NULL;
        if (FAILED(hr)) goto done;
        hr = item->lpVtbl->get_Path(item, &s->paths[s->path_count]);
        item->lpVtbl->Release(item); item = NULL;
        if (FAILED(hr)) {
            if (s->paths[s->path_count]) { s->api.delete_string(s->paths[s->path_count]); s->paths[s->path_count] = NULL; }
            goto done;
        }
        ++s->path_count;
    }
    *count = s->path_count;
    if (!*count) *cancelled = 1;
done:
    if (file) IUnknown_Release(file);
    if (files) files->lpVtbl->Release(files);
    return hr;
}
void zfp_path(State *s, UINT32 index, const WCHAR **path, UINT32 *length) { *path = s->api.string_buffer(s->paths[index], length); }
UINT32 zfp_resource_count(void) { return InterlockedCompareExchange(&live_states, 0, 0); }
