#define WIN32_LEAN_AND_MEAN
#define NO_STRICT
#define COBJMACROS
#define CONST_VTABLE
#include <windows.h>
#include <roapi.h>
#include <winstring.h>
#include <inspectable.h>
#include <asyncinfo.h>
#include <stdint.h>
#include <stdlib.h>

/* Minimal typed Windows Runtime ABI for Windows.UI.Popups.MessageDialog. */
#define Z_UNKNOWN(T) \
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(T *, REFIID, void **); \
    ULONG (STDMETHODCALLTYPE *AddRef)(T *); \
    ULONG (STDMETHODCALLTYPE *Release)(T *)
#define Z_INSPECTABLE(T) \
    Z_UNKNOWN(T); \
    HRESULT (STDMETHODCALLTYPE *GetIids)(T *, ULONG *, IID **); \
    HRESULT (STDMETHODCALLTYPE *GetRuntimeClassName)(T *, HSTRING *); \
    HRESULT (STDMETHODCALLTYPE *GetTrustLevel)(T *, TrustLevel *)

typedef struct Dialog Dialog;
typedef struct DialogFactory DialogFactory;
typedef struct Command Command;
typedef struct Commands Commands;
typedef struct Operation Operation;
typedef struct Completion Completion;
typedef struct InitializeWindow InitializeWindow;

typedef struct DialogVtbl {
    Z_INSPECTABLE(Dialog);
    HRESULT (STDMETHODCALLTYPE *get_Title)(Dialog *, HSTRING *);
    HRESULT (STDMETHODCALLTYPE *put_Title)(Dialog *, HSTRING);
    HRESULT (STDMETHODCALLTYPE *get_Commands)(Dialog *, Commands **);
    HRESULT (STDMETHODCALLTYPE *get_DefaultCommandIndex)(Dialog *, UINT32 *);
    HRESULT (STDMETHODCALLTYPE *put_DefaultCommandIndex)(Dialog *, UINT32);
    HRESULT (STDMETHODCALLTYPE *get_CancelCommandIndex)(Dialog *, UINT32 *);
    HRESULT (STDMETHODCALLTYPE *put_CancelCommandIndex)(Dialog *, UINT32);
    HRESULT (STDMETHODCALLTYPE *get_Content)(Dialog *, HSTRING *);
    HRESULT (STDMETHODCALLTYPE *put_Content)(Dialog *, HSTRING);
    HRESULT (STDMETHODCALLTYPE *ShowAsync)(Dialog *, Operation **);
} DialogVtbl;
struct Dialog { const DialogVtbl *lpVtbl; };
typedef struct DialogFactoryVtbl {
    Z_INSPECTABLE(DialogFactory);
    HRESULT (STDMETHODCALLTYPE *Create)(DialogFactory *, HSTRING, Dialog **);
    HRESULT (STDMETHODCALLTYPE *CreateWithTitle)(DialogFactory *, HSTRING, HSTRING, Dialog **);
} DialogFactoryVtbl;
struct DialogFactory { const DialogFactoryVtbl *lpVtbl; };
typedef struct CommandVtbl {
    Z_INSPECTABLE(Command);
    HRESULT (STDMETHODCALLTYPE *get_Label)(Command *, HSTRING *);
    HRESULT (STDMETHODCALLTYPE *put_Label)(Command *, HSTRING);
} CommandVtbl;
struct Command { const CommandVtbl *lpVtbl; };
typedef struct CommandsVtbl {
    Z_INSPECTABLE(Commands);
    HRESULT (STDMETHODCALLTYPE *GetAt)(Commands *, UINT32, Command **);
    HRESULT (STDMETHODCALLTYPE *get_Size)(Commands *, UINT32 *);
    HRESULT (STDMETHODCALLTYPE *GetView)(Commands *, void **);
    HRESULT (STDMETHODCALLTYPE *IndexOf)(Commands *, Command *, UINT32 *, unsigned char *);
    HRESULT (STDMETHODCALLTYPE *SetAt)(Commands *, UINT32, Command *);
    HRESULT (STDMETHODCALLTYPE *InsertAt)(Commands *, UINT32, Command *);
    HRESULT (STDMETHODCALLTYPE *RemoveAt)(Commands *, UINT32);
    HRESULT (STDMETHODCALLTYPE *Append)(Commands *, Command *);
} CommandsVtbl;
struct Commands { const CommandsVtbl *lpVtbl; };
typedef struct OperationVtbl {
    Z_INSPECTABLE(Operation);
    HRESULT (STDMETHODCALLTYPE *put_Completed)(Operation *, Completion *);
    HRESULT (STDMETHODCALLTYPE *get_Completed)(Operation *, Completion **);
    HRESULT (STDMETHODCALLTYPE *GetResults)(Operation *, Command **);
} OperationVtbl;
struct Operation { const OperationVtbl *lpVtbl; };
typedef struct CompletionVtbl {
    Z_UNKNOWN(Completion);
    HRESULT (STDMETHODCALLTYPE *Invoke)(Completion *, Operation *, AsyncStatus);
} CompletionVtbl;
struct Completion { const CompletionVtbl *lpVtbl; };
typedef struct InitializeWindowVtbl {
    Z_UNKNOWN(InitializeWindow);
    HRESULT (STDMETHODCALLTYPE *Initialize)(InitializeWindow *, HWND);
} InitializeWindowVtbl;
struct InitializeWindow { const InitializeWindowVtbl *lpVtbl; };

static const IID iid_unknown = {0,0,0,{0xc0,0,0,0,0,0,0,0x46}};
static const IID iid_agile = {0x94ea2b94,0xe9cc,0x49e0,{0xc0,0xff,0xee,0x64,0xca,0x8f,0x5b,0x90}};
static const IID iid_window = {0x3e68d4bd,0x7135,0x4d10,{0x80,0x18,0x9f,0xb6,0xd9,0xf3,0x3f,0xa1}};
static const IID iid_info = {0x36,0,0,{0xc0,0,0,0,0,0,0,0x46}};
static const IID iid_dialog_factory = {0x2d161777,0xa66f,0x4ea5,{0xbb,0x87,0x79,0x3f,0xfa,0x49,0x41,0xf2}};
static const IID iid_command = {0x4ff93a75,0x4145,0x47ff,{0xac,0x7f,0xdf,0xf1,0xc1,0xfa,0x5b,0x0f}};
/* Parameterized IIDs for IAsyncOperationCompletedHandler<IUICommand>. */
static const IID iid_completed = {0xdd33fd5b,0xa24d,0x5a44,{0x91,0xfe,0xdd,0x64,0x41,0x77,0x01,0x03}};

typedef struct Text { const WCHAR *text; UINT32 length; } Text;
typedef struct RuntimeApi {
    HRESULT (WINAPI *initialize)(RO_INIT_TYPE);
    void (WINAPI *uninitialize)(void);
    HRESULT (WINAPI *activate)(HSTRING, IInspectable **);
    HRESULT (WINAPI *factory)(HSTRING, REFIID, void **);
    HRESULT (WINAPI *create_string)(PCNZWCH, UINT32, HSTRING *);
    HRESULT (WINAPI *delete_string)(HSTRING);
} RuntimeApi;
typedef struct State {
    Completion completion;
    LONG refs;
    HANDLE event;
    Dialog *dialog;
    IUnknown *commands[3];
    UINT32 command_count;
    Operation *operation;
    IAsyncInfo *info;
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
    if (!IsEqualIID(iid, &iid_unknown) && !IsEqualIID(iid, &iid_completed) && !IsEqualIID(iid, &iid_agile)) return E_NOINTERFACE;
    *out = value;
    completion_add(value);
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE completion_invoke(Completion *value, Operation *operation, AsyncStatus status) {
    (void)operation; (void)status;
    /* Only the independently owned event is touched off the owner thread. */
    return SetEvent(from_completion(value)->event) ? S_OK : HRESULT_FROM_WIN32(GetLastError());
}
static const CompletionVtbl completion_vtable = {completion_query, completion_add, completion_release, completion_invoke};

void zmd_close(State *s) {
    if (!s) return;
    if (s->owner_thread != GetCurrentThreadId()) abort();
    if (s->info) {
        IAsyncInfo_Cancel(s->info);
        IAsyncInfo_Close(s->info);
        IAsyncInfo_Release(s->info);
        s->info = NULL;
    }
    if (s->operation) { s->operation->lpVtbl->Release(s->operation); s->operation = NULL; }
    for (UINT32 i = 0; i < s->command_count; ++i) IUnknown_Release(s->commands[i]);
    s->command_count = 0;
    if (s->dialog) { s->dialog->lpVtbl->Release(s->dialog); s->dialog = NULL; }
    if (s->initialized) { s->initialized = FALSE; s->api.uninitialize(); }
    if (s->runtime) { FreeLibrary(s->runtime); s->runtime = NULL; }
    completion_release(&s->completion);
}

/* Builds the dialog without showing it. Every string is copied into an
   HSTRING before return. cancel_index/default_index are UINT32_MAX when unset. */
State *zmd_create(HWND hwnd, Text title, Text message, const Text *buttons, UINT32 count, UINT32 default_index, UINT32 cancel_index, HRESULT *error, HANDLE *event) {
    State *s = calloc(1, sizeof(*s));
    DialogFactory *factory = NULL;
    InitializeWindow *initialize = NULL;
    Commands *commands = NULL;
    IInspectable *instance = NULL;
    Command *command = NULL;
    HSTRING name = NULL, text = NULL, heading = NULL;
    HRESULT hr = E_OUTOFMEMORY;
    if (!s) goto done;
    s->completion.lpVtbl = &completion_vtable;
    s->refs = 1;
    s->owner_thread = GetCurrentThreadId();
    InterlockedIncrement(&live_states);
    if (count == 0 || count > ARRAYSIZE(s->commands)) { hr = E_INVALIDARG; goto done; }
    s->event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!s->event) { hr = HRESULT_FROM_WIN32(GetLastError()); goto done; }
    s->runtime = LoadLibraryExW(L"combase.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!s->runtime) { hr = HRESULT_FROM_WIN32(GetLastError()); goto done; }
#define Z_LOAD(member, symbol) do { \
    FARPROC address = GetProcAddress(s->runtime, symbol); \
    if (!address) { hr = HRESULT_FROM_WIN32(GetLastError()); goto done; } \
    memcpy(&s->api.member, &address, sizeof(address)); \
} while (0)
    Z_LOAD(initialize, "RoInitialize");
    Z_LOAD(uninitialize, "RoUninitialize");
    Z_LOAD(activate, "RoActivateInstance");
    Z_LOAD(factory, "RoGetActivationFactory");
    Z_LOAD(create_string, "WindowsCreateString");
    Z_LOAD(delete_string, "WindowsDeleteString");
#undef Z_LOAD
    hr = s->api.initialize(RO_INIT_SINGLETHREADED);
    if (FAILED(hr)) goto done;
    s->initialized = TRUE;
    static const WCHAR dialog_class[] = L"Windows.UI.Popups.MessageDialog";
    hr = s->api.create_string(dialog_class, ARRAYSIZE(dialog_class) - 1, &name);
    if (FAILED(hr)) goto done;
    hr = s->api.factory(name, &iid_dialog_factory, (void **)&factory);
    if (FAILED(hr)) goto done;
    s->api.delete_string(name); name = NULL;
    hr = s->api.create_string(message.text, message.length, &text);
    if (FAILED(hr)) goto done;
    hr = s->api.create_string(title.text, title.length, &heading);
    if (FAILED(hr)) goto done;
    hr = factory->lpVtbl->CreateWithTitle(factory, text, heading, &s->dialog);
    if (FAILED(hr)) goto done;
    hr = s->dialog->lpVtbl->QueryInterface(s->dialog, &iid_window, (void **)&initialize);
    if (FAILED(hr)) goto done;
    hr = initialize->lpVtbl->Initialize(initialize, hwnd);
    if (FAILED(hr)) goto done;
    hr = s->dialog->lpVtbl->get_Commands(s->dialog, &commands);
    if (FAILED(hr)) goto done;
    static const WCHAR command_class[] = L"Windows.UI.Popups.UICommand";
    hr = s->api.create_string(command_class, ARRAYSIZE(command_class) - 1, &name);
    if (FAILED(hr)) goto done;
    for (UINT32 i = 0; i < count; ++i) {
        hr = s->api.activate(name, &instance);
        if (FAILED(hr)) goto done;
        hr = IInspectable_QueryInterface(instance, &iid_command, (void **)&command);
        if (FAILED(hr)) goto done;
        s->api.delete_string(text); text = NULL;
        hr = s->api.create_string(buttons[i].text, buttons[i].length, &text);
        if (FAILED(hr)) goto done;
        hr = command->lpVtbl->put_Label(command, text);
        if (FAILED(hr)) goto done;
        hr = commands->lpVtbl->Append(commands, command);
        if (FAILED(hr)) goto done;
        /* COM identity: the result is compared with this IUnknown pointer. */
        hr = IInspectable_QueryInterface(instance, &iid_unknown, (void **)&s->commands[s->command_count]);
        if (FAILED(hr)) goto done;
        ++s->command_count;
        command->lpVtbl->Release(command); command = NULL;
        IInspectable_Release(instance); instance = NULL;
    }
    if (default_index != UINT32_MAX) {
        hr = s->dialog->lpVtbl->put_DefaultCommandIndex(s->dialog, default_index);
        if (FAILED(hr)) goto done;
    }
    if (cancel_index != UINT32_MAX) {
        hr = s->dialog->lpVtbl->put_CancelCommandIndex(s->dialog, cancel_index);
        if (FAILED(hr)) goto done;
    }
done:
    if (command) command->lpVtbl->Release(command);
    if (instance) IInspectable_Release(instance);
    if (commands) commands->lpVtbl->Release(commands);
    if (initialize) initialize->lpVtbl->Release(initialize);
    if (factory) factory->lpVtbl->Release(factory);
    if (heading) s->api.delete_string(heading);
    if (text) s->api.delete_string(text);
    if (name) s->api.delete_string(name);
    *error = hr;
    if (FAILED(hr)) { zmd_close(s); return NULL; }
    *event = s->event;
    return s;
}

HRESULT zmd_start(State *s) {
    HRESULT hr = s->dialog->lpVtbl->ShowAsync(s->dialog, &s->operation);
    if (FAILED(hr)) return hr;
    hr = s->operation->lpVtbl->QueryInterface(s->operation, &iid_info, (void **)&s->info);
    if (FAILED(hr)) return hr;
    return s->operation->lpVtbl->put_Completed(s->operation, &s->completion);
}
HRESULT zmd_cancel(State *s) { return s->info ? IAsyncInfo_Cancel(s->info) : E_UNEXPECTED; }

/* Called on the owner thread after the core one-shot wait fires. index is
   UINT32_MAX when no command of ours was chosen; cancelled reports Cancel(). */
HRESULT zmd_collect(State *s, UINT32 *index, int *cancelled) {
    AsyncStatus status;
    Command *chosen = NULL;
    IUnknown *identity = NULL;
    *index = UINT32_MAX;
    *cancelled = 0;
    HRESULT hr = IAsyncInfo_get_Status(s->info, &status);
    if (FAILED(hr)) return hr;
    if (status == Canceled) { *cancelled = 1; return S_OK; }
    if (status == Error) {
        HRESULT code = E_FAIL;
        hr = IAsyncInfo_get_ErrorCode(s->info, &code);
        return FAILED(hr) ? hr : FAILED(code) ? code : E_FAIL;
    }
    if (status != Completed) return E_PENDING;
    hr = s->operation->lpVtbl->GetResults(s->operation, &chosen);
    if (FAILED(hr) || !chosen) return hr;
    hr = chosen->lpVtbl->QueryInterface(chosen, &iid_unknown, (void **)&identity);
    chosen->lpVtbl->Release(chosen);
    if (FAILED(hr)) return hr;
    for (UINT32 i = 0; i < s->command_count; ++i) if (s->commands[i] == identity) *index = i;
    IUnknown_Release(identity);
    return S_OK;
}
UINT32 zmd_resource_count(void) { return InterlockedCompareExchange(&live_states, 0, 0); }
