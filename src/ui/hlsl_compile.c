/* HLSL compilation with the system's compiler (d3dcompiler_47.dll, part of
   Windows 10 and later), loaded on first use. Effects compile their
   translated programs here; the bytecode is cached on disk by the caller. */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3dcommon.h>
#include <stdint.h>
#include <string.h>

typedef HRESULT(WINAPI *ZgD3DCompile)(LPCVOID, SIZE_T, LPCSTR, const D3D_SHADER_MACRO *, ID3DInclude *, LPCSTR, LPCSTR, UINT, UINT, ID3DBlob **, ID3DBlob **);

static INIT_ONCE compiler_once = INIT_ONCE_STATIC_INIT;
static ZgD3DCompile compiler;

static BOOL CALLBACK load_compiler(PINIT_ONCE once, PVOID parameter, PVOID *context) {
    (void)once;
    (void)parameter;
    (void)context;
    wchar_t path[MAX_PATH];
    UINT len = GetSystemDirectoryW(path, MAX_PATH);
    static const wchar_t name[] = L"\\d3dcompiler_47.dll";
    if (len == 0 || len + sizeof(name) / sizeof(name[0]) > MAX_PATH) return TRUE;
    memcpy(path + len, name, sizeof(name));
    HMODULE module = LoadLibraryExW(path, NULL, 0);
    if (module) compiler = (ZgD3DCompile)(void *)GetProcAddress(module, "D3DCompile");
    return TRUE;
}

/* Optimization level 3 with IEEE strictness, so NaN and infinity behave
   as on the CPU. */
#define ZG_HLSL_FLAGS ((1u << 15) | (1u << 13))

/* Compile `source` for `target` at `entry`. On success *code is a
   HeapAlloc'd copy of the bytecode the caller frees with
   zgpu_hlsl_free. On failure the compiler's message, if any, is copied
   into `log`. Returns 0, 1 without a compiler, or 2 on a compile error. */
int zgpu_hlsl_compile(const char *source, size_t source_len, const char *entry, const char *target, uint8_t **code, size_t *code_len, char *log, size_t log_len) {
    *code = NULL;
    *code_len = 0;
    if (log_len) log[0] = 0;
    InitOnceExecuteOnce(&compiler_once, load_compiler, NULL, NULL);
    if (!compiler) return 1;
    ID3DBlob *blob = NULL, *errors = NULL;
    HRESULT hr = compiler(source, source_len, "effect.hlsl", NULL, NULL, entry, target, ZG_HLSL_FLAGS, 0, &blob, &errors);
    if (errors) {
        size_t n = ID3D10Blob_GetBufferSize(errors);
        if (log_len) {
            if (n >= log_len) n = log_len - 1;
            memcpy(log, ID3D10Blob_GetBufferPointer(errors), n);
            log[n] = 0;
        }
        ID3D10Blob_Release(errors);
    }
    if (FAILED(hr) || !blob) {
        if (blob) ID3D10Blob_Release(blob);
        return 2;
    }
    size_t n = ID3D10Blob_GetBufferSize(blob);
    uint8_t *copy = HeapAlloc(GetProcessHeap(), 0, n ? n : 1);
    if (!copy) {
        ID3D10Blob_Release(blob);
        return 3;
    }
    memcpy(copy, ID3D10Blob_GetBufferPointer(blob), n);
    ID3D10Blob_Release(blob);
    *code = copy;
    *code_len = n;
    return 0;
}

void zgpu_hlsl_free(uint8_t *code) {
    if (code) HeapFree(GetProcessHeap(), 0, code);
}

/* The flags as the cache names them. */
const char *zgpu_hlsl_flags(void) { return "O3 IEEE"; }
