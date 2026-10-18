#define WIN32_LEAN_AND_MEAN 1
#define NO_STRICT 1
#include <windows.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

/* Test-executable imports only. Framework and DLL code are not rewritten.
 * A named COFF import is shared by callers linked into this executable. */
typedef UINT (WINAPI *DoubleClickFn)(void);
typedef int (WINAPI *MetricsFn)(int);
typedef SHORT (WINAPI *KeyStateFn)(int);
extern DoubleClickFn __imp_GetDoubleClickTime;
extern MetricsFn __imp_GetSystemMetrics;
extern KeyStateFn __imp_GetKeyState;

typedef struct PointerCostCounts {
    uint64_t double_click_time;
    uint64_t metrics_total, metrics_cx, metrics_cy;
    uint64_t key_state_total, key_shift, key_control, key_alt, key_super;
    uint64_t other_thread;
} PointerCostCounts;
_Static_assert(sizeof(PointerCostCounts) == 80, "pointer cost counter ABI");
_Static_assert(sizeof(DoubleClickFn) == sizeof(void *), "Windows function pointer ABI");
_Static_assert(sizeof(MetricsFn) == sizeof(void *), "Windows function pointer ABI");
_Static_assert(sizeof(KeyStateFn) == sizeof(void *), "Windows function pointer ABI");

typedef struct Slot { void **address; void *original, *replacement; int patched; } Slot;
static Slot slots[3];
static volatile PointerCostCounts counts;
static volatile LONG active;
static DWORD owner_thread, native_error;
static int installed;

static void increment(volatile uint64_t *value) {
    InterlockedIncrement64((volatile LONG64 *)value);
}
static int observe(void) {
    if (!InterlockedCompareExchange(&active, 0, 0)) return 0;
    if (GetCurrentThreadId() != owner_thread) {
        increment(&counts.other_thread);
        return 0;
    }
    return 1;
}
static UINT WINAPI counted_double_click(void) {
    if (observe()) increment(&counts.double_click_time);
    return ((DoubleClickFn)slots[0].original)();
}
static int WINAPI counted_metrics(int index) {
    if (observe()) {
        increment(&counts.metrics_total);
        if (index == SM_CXDOUBLECLK) increment(&counts.metrics_cx);
        if (index == SM_CYDOUBLECLK) increment(&counts.metrics_cy);
    }
    return ((MetricsFn)slots[1].original)(index);
}
static SHORT WINAPI counted_key_state(int key) {
    if (observe()) {
        increment(&counts.key_state_total);
        if (key == VK_SHIFT) increment(&counts.key_shift);
        if (key == VK_CONTROL) increment(&counts.key_control);
        if (key == VK_MENU) increment(&counts.key_alt);
        if (key == VK_LWIN || key == VK_RWIN) increment(&counts.key_super);
    }
    return ((KeyStateFn)slots[2].original)(key);
}

/* Refuse to patch a DLL, an arbitrary address, or a non-IAT data slot. No import
 * name scan, address discovery outside this module, or global hook is used. */
static int own_iat_slot(void **slot) {
    const unsigned char *base = (const unsigned char *)GetModuleHandleW(NULL);
    if (!base) return 0;
    const IMAGE_DOS_HEADER *dos = (const IMAGE_DOS_HEADER *)base;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0) return 0;
    const IMAGE_NT_HEADERS *nt = (const IMAGE_NT_HEADERS *)(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE ||
        nt->OptionalHeader.NumberOfRvaAndSizes <= IMAGE_DIRECTORY_ENTRY_IAT) return 0;
    const IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IAT];
    const uintptr_t image = (uintptr_t)base, address = (uintptr_t)slot;
    if (!dir.VirtualAddress || dir.Size < sizeof(void *) ||
        dir.VirtualAddress >= nt->OptionalHeader.SizeOfImage ||
        dir.Size > nt->OptionalHeader.SizeOfImage - dir.VirtualAddress) return 0;
    const uintptr_t first = image + dir.VirtualAddress;
    if (first < image || address < first || address - first > dir.Size - sizeof(void *)) return 0;
    return address % sizeof(void *) == 0;
}

/* Return status, preserving the actual Win32 error separately. Changing page
 * permission and the pointer is limited to the already validated own IAT slot. */
static int exchange_slot(Slot *slot, void *expected, void *replacement) {
    DWORD protection = 0, ignored = 0;
    if (!VirtualProtect(slot->address, sizeof(void *), PAGE_READWRITE, &protection)) {
        native_error = GetLastError();
        return 3;
    }
    void *previous = InterlockedCompareExchangePointer((void *volatile *)slot->address, replacement, expected);
    if (previous == expected) slot->patched = replacement == slot->replacement;
    if (!VirtualProtect(slot->address, sizeof(void *), protection, &ignored)) {
        native_error = GetLastError();
        return 5;
    }
    return previous == expected ? 0 : 4;
}

int zpc_restore(void) {
    InterlockedExchange(&active, 0);
    int status = 0;
    for (int i = 2; i >= 0; --i) if (slots[i].patched) {
        int result = exchange_slot(&slots[i], slots[i].replacement, slots[i].original);
        if (!status) status = result;
    }
    installed = slots[0].patched || slots[1].patched || slots[2].patched;
    return status;
}

int zpc_install(void) {
    if (installed) return 2;
    native_error = 0;
    slots[0] = (Slot){ (void **)&__imp_GetDoubleClickTime, (void *)__imp_GetDoubleClickTime, (void *)counted_double_click, 0 };
    slots[1] = (Slot){ (void **)&__imp_GetSystemMetrics, (void *)__imp_GetSystemMetrics, (void *)counted_metrics, 0 };
    slots[2] = (Slot){ (void **)&__imp_GetKeyState, (void *)__imp_GetKeyState, (void *)counted_key_state, 0 };
    HMODULE user32 = GetModuleHandleW(L"user32.dll");
    const char *names[3] = { "GetDoubleClickTime", "GetSystemMetrics", "GetKeyState" };
    for (unsigned i = 0; i < 3; ++i)
        if (!own_iat_slot(slots[i].address) || !slots[i].original ||
            !user32 || slots[i].original != (void *)GetProcAddress(user32, names[i])) return 1;
    for (unsigned i = 0; i < 3; ++i) {
        int status = exchange_slot(&slots[i], slots[i].original, slots[i].replacement);
        if (status) {
            DWORD saved_error = native_error;
            int rollback = zpc_restore();
            native_error = saved_error;
            return rollback ? rollback : status;
        }
    }
    installed = 1;
    return 0;
}

int zpc_begin(void) {
    if (!installed) return 6;
    if (InterlockedCompareExchange(&active, 0, 0)) return 7;
    memset((void *)&counts, 0, sizeof(counts));
    owner_thread = GetCurrentThreadId();
    InterlockedExchange(&active, 1);
    return 0;
}
int zpc_end(PointerCostCounts *out) {
    if (!out || !InterlockedCompareExchange(&active, 0, 0)) return 7;
    if (GetCurrentThreadId() != owner_thread) return 8;
    InterlockedExchange(&active, 0);
#define COPY(Field) out->Field = (uint64_t)InterlockedCompareExchange64((volatile LONG64 *)&counts.Field, 0, 0)
    COPY(double_click_time);
    COPY(metrics_total); COPY(metrics_cx); COPY(metrics_cy);
    COPY(key_state_total); COPY(key_shift); COPY(key_control); COPY(key_alt); COPY(key_super);
    COPY(other_thread);
#undef COPY
    return 0;
}
uint32_t zpc_last_error(void) { return native_error; }
size_t zpc_counts_size(void) { return sizeof(PointerCostCounts); }

/* Separate positive-control interval. Actual Window phase counters are reset
 * afterward and must independently observe the framework's queued down. */
int zpc_self_test(PointerCostCounts *out) {
    int status = zpc_begin();
    if (status) return status;
    (void)GetDoubleClickTime();
    (void)GetSystemMetrics(SM_CXDOUBLECLK);
    (void)GetSystemMetrics(SM_CYDOUBLECLK);
    (void)GetKeyState(VK_SHIFT);
    return zpc_end(out);
}
