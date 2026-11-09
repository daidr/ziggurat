/* On Windows, Media Foundation plays the video: an IMFMediaEngine in
   frame-server mode, which decodes on a Direct3D 11 device of the engine's
   own (in hardware, through DXVA, where the GPU has it), plays the sound and
   keeps the clock. As each frame of the window builds, the engine converts
   the picture due into a BGRA texture (TransferVideoFrame, on the GPU),
   which is read back into a ring of three pictures in memory that every
   renderer draws. The engine's events come on Media Foundation's threads,
   through one notify object of each engine, and wake the player. */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define CINTERFACE
#include <windows.h>
#include <ole2.h>
#include <d3d10.h>
#include <d3d11.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfmediaengine.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

#define RING 3

static const GUID clsid_factory = {0xb44392da, 0x499b, 0x446b, {0xa4, 0xcb, 0x00, 0x5f, 0xea, 0xd0, 0xe6, 0xd5}};
static const GUID iid_factory = {0x4d645ace, 0x26aa, 0x4688, {0x9b, 0xe1, 0xdf, 0x35, 0x16, 0x99, 0x0b, 0x93}};
static const GUID iid_notify = {0xfee7c112, 0xe776, 0x42b5, {0x9b, 0xbf, 0x00, 0x48, 0x52, 0x4e, 0x2b, 0xd5}};
static const GUID iid_engine_ex = {0x83015ead, 0xb1e6, 0x40d0, {0xa9, 0x8a, 0x37, 0x14, 0x5f, 0xfe, 0x1a, 0xd1}};
static const GUID iid_unknown = {0, 0, 0, {0xc0, 0, 0, 0, 0, 0, 0, 0x46}};
static const GUID iid_multithread = {0x9b7e4e00, 0x342c, 0x4106, {0xa1, 0x9f, 0x4f, 0x27, 0x04, 0xf6, 0x89, 0xf0}};
static const GUID attr_callback = {0xc60381b8, 0x83a4, 0x41f8, {0xa3, 0xd0, 0xde, 0x05, 0x07, 0x68, 0x49, 0xa9}};
static const GUID attr_dxgi_manager = {0x065702da, 0x1094, 0x486d, {0x86, 0x17, 0xee, 0x7c, 0xc4, 0xee, 0x46, 0x48}};
static const GUID attr_output_format = {0x5066893c, 0x8cf9, 0x42bc, {0x8b, 0x8a, 0x47, 0x22, 0x12, 0xe5, 0x27, 0x26}};

typedef HRESULT(WINAPI *Startup)(ULONG, DWORD);
typedef HRESULT(WINAPI *CreateManager)(UINT *, IMFDXGIDeviceManager **);
typedef HRESULT(WINAPI *CreateAttributes)(IMFAttributes **, UINT32);
typedef HRESULT(WINAPI *CreateByteStream)(IStream *, IMFByteStream **);
typedef IStream *(WINAPI *CreateMemStream)(const BYTE *, UINT);
typedef HRESULT(WINAPI *CreateDevice)(IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT, const D3D_FEATURE_LEVEL *, UINT, UINT, ID3D11Device **, D3D_FEATURE_LEVEL *, ID3D11DeviceContext **);

static INIT_ONCE loaded = INIT_ONCE_STATIC_INIT;
static int load_failed;
static CreateManager create_manager;
static CreateAttributes create_attributes;
static CreateByteStream create_byte_stream;
static CreateMemStream create_mem_stream;
static CreateDevice create_device;

static BOOL CALLBACK load(PINIT_ONCE once, PVOID parameter, PVOID *context) {
    (void)once; (void)parameter; (void)context;
    /* Windows Server without its Media Foundation feature, or an N edition
       without the Media Feature Pack, has no mfplat.dll. */
    HMODULE mfplat = LoadLibraryExW(L"mfplat.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    HMODULE shlwapi = LoadLibraryExW(L"shlwapi.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    HMODULE d3d11 = LoadLibraryExW(L"d3d11.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!mfplat || !shlwapi || !d3d11) { load_failed = 1; return TRUE; }
    Startup startup = (Startup)(void *)GetProcAddress(mfplat, "MFStartup");
    create_manager = (CreateManager)(void *)GetProcAddress(mfplat, "MFCreateDXGIDeviceManager");
    create_attributes = (CreateAttributes)(void *)GetProcAddress(mfplat, "MFCreateAttributes");
    create_byte_stream = (CreateByteStream)(void *)GetProcAddress(mfplat, "MFCreateMFByteStreamOnStream");
    /* SHCreateMemStream is exported by ordinal 12 before Windows Vista's name. */
    create_mem_stream = (CreateMemStream)(void *)GetProcAddress(shlwapi, "SHCreateMemStream");
    if (!create_mem_stream) create_mem_stream = (CreateMemStream)(void *)GetProcAddress(shlwapi, (LPCSTR)12);
    create_device = (CreateDevice)(void *)GetProcAddress(d3d11, "D3D11CreateDevice");
    if (!startup || !create_manager || !create_attributes || !create_byte_stream || !create_mem_stream || !create_device) { load_failed = 1; return TRUE; }
    if (FAILED(startup(0x00020070 /* MF_VERSION */, 0 /* MFSTARTUP_FULL */))) load_failed = 1;
    return TRUE;
}

enum { LOADING = 0, READY = 1, BUFFERING = 2, ENDED = 3, FAILED_STATE = 4 };

typedef struct Picture { uint8_t *pixels; uint32_t width, height; } Picture;

typedef struct ZvMf ZvMf;
typedef struct Notify { IMFMediaEngineNotifyVtbl *lpVtbl; ZvMf *owner; } Notify;

struct ZvMf {
    Notify notify;
    IMFMediaEngine *engine;
    IMFMediaEngineEx *ex;
    ID3D11Device *device;
    ID3D11DeviceContext *context;
    IMFDXGIDeviceManager *manager;
    ID3D11Texture2D *target, *staging;
    uint32_t target_width, target_height;
    Picture ring[RING];
    int shown;
    uint32_t width, height;
    SRWLOCK lock;
    void (*wake)(void *);
    void *wake_context;
    int state;
    int32_t error_code;
    int looping, closed;
    uint64_t seek_to;
    int seeking;
    /* A seek landed with no picture since it. */
    int landed;
};

static HRESULT STDMETHODCALLTYPE notify_query(IMFMediaEngineNotify *self, REFIID id, void **out) {
    if (!out) return E_POINTER;
    if (IsEqualGUID(id, &iid_unknown) || IsEqualGUID(id, &iid_notify)) { *out = self; return S_OK; }
    *out = NULL;
    return E_NOINTERFACE;
}
/* The engine holds the notify object, which lives as long as its ZvMf. */
static ULONG STDMETHODCALLTYPE notify_add(IMFMediaEngineNotify *self) { (void)self; return 1; }
static ULONG STDMETHODCALLTYPE notify_release(IMFMediaEngineNotify *self) { (void)self; return 1; }
static HRESULT STDMETHODCALLTYPE notify_event(IMFMediaEngineNotify *iface, DWORD event, DWORD_PTR param1, DWORD param2) {
    ZvMf *s = ((Notify *)iface)->owner;
    (void)param2;
    AcquireSRWLockExclusive(&s->lock);
    switch (event) {
    case MF_MEDIA_ENGINE_EVENT_ERROR:
        s->state = FAILED_STATE;
        s->error_code = (int32_t)param1;
        break;
    case MF_MEDIA_ENGINE_EVENT_ENDED:
        if (!s->looping) s->state = ENDED;
        break;
    case MF_MEDIA_ENGINE_EVENT_WAITING:
        if (s->state == READY) s->state = BUFFERING;
        break;
    case MF_MEDIA_ENGINE_EVENT_PLAYING:
    case MF_MEDIA_ENGINE_EVENT_CANPLAY:
        if (s->state == BUFFERING) s->state = READY;
        break;
    case MF_MEDIA_ENGINE_EVENT_SEEKED:
        s->seeking = 0;
        s->landed = 1;
        break;
    case MF_MEDIA_ENGINE_EVENT_LOADEDMETADATA:
    case MF_MEDIA_ENGINE_EVENT_LOADEDDATA:
    case MF_MEDIA_ENGINE_EVENT_DURATIONCHANGE:
    case 1007: /* MF_MEDIA_ENGINE_EVENT_FRAMESTEPCOMPLETED */
        break;
    default:
        ReleaseSRWLockExclusive(&s->lock);
        return S_OK;
    }
    void (*wake)(void *) = s->wake;
    void *context = s->wake_context;
    ReleaseSRWLockExclusive(&s->lock);
    if (wake) wake(context);
    return S_OK;
}
static IMFMediaEngineNotifyVtbl notify_vtbl = {notify_query, notify_add, notify_release, notify_event};

#define DROP(p) do { if (p) { IUnknown_Release((IUnknown *)(p)); (p) = NULL; } } while (0)

static void release(ZvMf *s) {
    DROP(s->ex);
    DROP(s->engine);
    DROP(s->staging);
    DROP(s->target);
    DROP(s->manager);
    DROP(s->context);
    DROP(s->device);
    for (int i = 0; i < RING; i++) HeapFree(GetProcessHeap(), 0, s->ring[i].pixels);
    HeapFree(GetProcessHeap(), 0, s);
}

static HRESULT new_device(ZvMf *s) {
    static const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0, D3D_FEATURE_LEVEL_9_3};
    const UINT flags = D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    HRESULT hr = create_device(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, flags, levels, 5, D3D11_SDK_VERSION, &s->device, NULL, &s->context);
    /* WARP decodes in software where the machine has no GPU of its own. */
    if (FAILED(hr)) hr = create_device(NULL, D3D_DRIVER_TYPE_WARP, NULL, flags, levels, 5, D3D11_SDK_VERSION, &s->device, NULL, &s->context);
    if (FAILED(hr)) return hr;
    /* The engine decodes on the device from threads of its own. */
    ID3D10Multithread *multithread = NULL;
    if (SUCCEEDED(ID3D11Device_QueryInterface(s->device, &iid_multithread, (void **)&multithread)) && multithread) {
        ID3D10Multithread_SetMultithreadProtected(multithread, TRUE);
        ID3D10Multithread_Release(multithread);
    }
    return S_OK;
}

/* The source's name for a video in memory: only its type, for the engine
   to choose a source by. */
static const WCHAR *data_name(const uint8_t *bytes, size_t length) {
    if (length >= 12 && memcmp(bytes + 4, "ftyp", 4) == 0 && memcmp(bytes + 8, "qt  ", 4) == 0) return L"data.mov";
    if (length >= 4 && memcmp(bytes, "\x1a\x45\xdf\xa3", 4) == 0) return L"data.webm";
    return L"data.mp4";
}

/* 0 when the engine opened, 1 when the system has no media engine, 2 when
   the source could not be opened. */
int zv_mf_open(const WCHAR *url, const uint8_t *bytes, size_t length, ZvMf **out) {
    *out = NULL;
    InitOnceExecuteOnce(&loaded, load, NULL, NULL);
    if (load_failed) return 1;
    /* COM on this thread: the app's thread may have it already, in its own
       mode, which serves. */
    (void)CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    ZvMf *s = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*s));
    if (!s) return 2;
    InitializeSRWLock(&s->lock);
    s->shown = -1;
    s->notify.lpVtbl = &notify_vtbl;
    s->notify.owner = s;
    if (FAILED(new_device(s))) { release(s); return 1; }
    UINT token = 0;
    if (FAILED(create_manager(&token, &s->manager)) || FAILED(IMFDXGIDeviceManager_ResetDevice(s->manager, (IUnknown *)s->device, token))) { release(s); return 1; }
    IMFAttributes *attributes = NULL;
    IMFMediaEngineClassFactory *factory = NULL;
    HRESULT hr = create_attributes(&attributes, 3);
    if (SUCCEEDED(hr)) hr = IMFAttributes_SetUnknown(attributes, &attr_callback, (IUnknown *)&s->notify);
    if (SUCCEEDED(hr)) hr = IMFAttributes_SetUnknown(attributes, &attr_dxgi_manager, (IUnknown *)s->manager);
    if (SUCCEEDED(hr)) hr = IMFAttributes_SetUINT32(attributes, &attr_output_format, DXGI_FORMAT_B8G8R8A8_UNORM);
    if (FAILED(hr)) { DROP(attributes); release(s); return 2; }
    hr = CoCreateInstance(&clsid_factory, NULL, CLSCTX_INPROC_SERVER, &iid_factory, (void **)&factory);
    if (FAILED(hr)) { DROP(attributes); release(s); return 1; }
    hr = IMFMediaEngineClassFactory_CreateInstance(factory, 0, attributes, &s->engine);
    DROP(factory);
    DROP(attributes);
    if (FAILED(hr)) { release(s); return 1; }
    (void)IMFMediaEngine_QueryInterface(s->engine, &iid_engine_ex, (void **)&s->ex);
    if (bytes) {
        if (!s->ex) { IMFMediaEngine_Shutdown(s->engine); release(s); return 1; }
        IStream *stream = create_mem_stream(bytes, (UINT)length);
        IMFByteStream *byte_stream = NULL;
        hr = stream ? create_byte_stream(stream, &byte_stream) : E_OUTOFMEMORY;
        DROP(stream);
        BSTR name = SUCCEEDED(hr) ? SysAllocString(data_name(bytes, length)) : NULL;
        if (SUCCEEDED(hr)) hr = name ? IMFMediaEngineEx_SetSourceFromByteStream(s->ex, byte_stream, name) : E_OUTOFMEMORY;
        SysFreeString(name);
        DROP(byte_stream);
    } else {
        BSTR source = SysAllocString(url);
        hr = source ? IMFMediaEngine_SetSource(s->engine, source) : E_OUTOFMEMORY;
        SysFreeString(source);
    }
    if (FAILED(hr)) { IMFMediaEngine_Shutdown(s->engine); release(s); return 2; }
    *out = s;
    return 0;
}

void zv_mf_set_wake(ZvMf *s, void (*wake)(void *), void *context) {
    AcquireSRWLockExclusive(&s->lock);
    s->wake = wake;
    s->wake_context = context;
    ReleaseSRWLockExclusive(&s->lock);
}

/* Converts the picture due into picture i of the ring, through the BGRA
   texture the engine draws into and a staging copy read back. */
static int transfer(ZvMf *s, int i, uint32_t width, uint32_t height) {
    if (!s->target || s->target_width != width || s->target_height != height) {
        DROP(s->target);
        DROP(s->staging);
        D3D11_TEXTURE2D_DESC desc = {width, height, 1, 1, DXGI_FORMAT_B8G8R8A8_UNORM, {1, 0}, D3D11_USAGE_DEFAULT, D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE, 0, 0};
        if (FAILED(ID3D11Device_CreateTexture2D(s->device, &desc, NULL, &s->target))) return 0;
        desc.Usage = D3D11_USAGE_STAGING;
        desc.BindFlags = 0;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        if (FAILED(ID3D11Device_CreateTexture2D(s->device, &desc, NULL, &s->staging))) { DROP(s->target); return 0; }
        s->target_width = width;
        s->target_height = height;
    }
    RECT rect = {0, 0, (LONG)width, (LONG)height};
    MFARGB border = {0, 0, 0, 255}; /* opaque black */
    if (FAILED(IMFMediaEngine_TransferVideoFrame(s->engine, (IUnknown *)s->target, NULL, &rect, &border))) return 0;
    ID3D11DeviceContext_CopyResource(s->context, (ID3D11Resource *)s->staging, (ID3D11Resource *)s->target);
    Picture *p = &s->ring[i];
    if (!p->pixels || p->width != width || p->height != height) {
        HeapFree(GetProcessHeap(), 0, p->pixels);
        p->pixels = HeapAlloc(GetProcessHeap(), 0, (size_t)width * height * 4);
        p->width = p->pixels ? width : 0;
        p->height = p->pixels ? height : 0;
        if (!p->pixels) return 0;
    }
    D3D11_MAPPED_SUBRESOURCE mapped;
    if (FAILED(ID3D11DeviceContext_Map(s->context, (ID3D11Resource *)s->staging, 0, D3D11_MAP_READ, 0, &mapped))) return 0;
    for (uint32_t y = 0; y < height; y++) {
        const uint8_t *row = (const uint8_t *)mapped.pData + (size_t)y * mapped.RowPitch;
        uint8_t *to = p->pixels + (size_t)y * width * 4;
        memcpy(to, row, (size_t)width * 4);
        for (uint32_t x = 0; x < width; x++) to[x * 4 + 3] = 255;
    }
    ID3D11DeviceContext_Unmap(s->context, (ID3D11Resource *)s->staging, 0);
    return 1;
}

/* The picture to show: 1 with it in `pixels`, `width` and `height`, and
   `changed` when it is new; 0 while there is none yet. */
int zv_mf_frame(ZvMf *s, const uint8_t **pixels, uint32_t *width, uint32_t *height, int *changed) {
    *changed = 0;
    LONGLONG pts = 0;
    const int fresh = IMFMediaEngine_OnVideoStreamTick(s->engine, &pts) == S_OK;
    AcquireSRWLockExclusive(&s->lock);
    const int landed = s->landed;
    ReleaseSRWLockExclusive(&s->lock);
    if (landed && (fresh || !IMFMediaEngine_IsSeeking(s->engine))) {
        AcquireSRWLockExclusive(&s->lock);
        s->landed = 0;
        ReleaseSRWLockExclusive(&s->lock);
        /* A seek of a paused video that landed with no picture, which then
           never comes on some systems: a step forward shows the one there,
           and keeps the position. */
        if (!fresh && pts == INT64_MIN && s->ex && IMFMediaEngine_IsPaused(s->engine)) IMFMediaEngineEx_FrameStep(s->ex, TRUE);
    }
    if (fresh) {
        DWORD w = 0, h = 0;
        if (SUCCEEDED(IMFMediaEngine_GetNativeVideoSize(s->engine, &w, &h)) && w > 0 && h > 0 && w <= 16384 && h <= 16384) {
            const int i = (s->shown + 1) % RING;
            if (transfer(s, i, w, h)) {
                s->shown = i;
                *changed = 1;
                AcquireSRWLockExclusive(&s->lock);
                s->width = w;
                s->height = h;
                if (s->state == LOADING) s->state = READY;
                ReleaseSRWLockExclusive(&s->lock);
            }
        }
    }
    if (s->shown < 0) return 0;
    *pixels = s->ring[s->shown].pixels;
    *width = s->ring[s->shown].width;
    *height = s->ring[s->shown].height;
    return 1;
}

int zv_mf_state(ZvMf *s, int32_t *code) {
    AcquireSRWLockShared(&s->lock);
    const int state = s->state;
    if (code) *code = s->error_code;
    ReleaseSRWLockShared(&s->lock);
    return state;
}
void zv_mf_size(ZvMf *s, uint32_t size[2]) {
    AcquireSRWLockShared(&s->lock);
    size[0] = s->width;
    size[1] = s->height;
    ReleaseSRWLockShared(&s->lock);
}
static uint64_t nanoseconds(double seconds) {
    if (isnan(seconds) || isinf(seconds) || seconds <= 0) return 0;
    return (uint64_t)(seconds * 1e9);
}
uint64_t zv_mf_duration(ZvMf *s) { return nanoseconds(IMFMediaEngine_GetDuration(s->engine)); }
uint64_t zv_mf_position(ZvMf *s) {
    AcquireSRWLockShared(&s->lock);
    const int seeking = s->seeking;
    const uint64_t to = s->seek_to;
    ReleaseSRWLockShared(&s->lock);
    if (seeking) return to;
    return nanoseconds(IMFMediaEngine_GetCurrentTime(s->engine));
}
void zv_mf_play(ZvMf *s) {
    AcquireSRWLockExclusive(&s->lock);
    if (s->state == ENDED) s->state = READY;
    ReleaseSRWLockExclusive(&s->lock);
    IMFMediaEngine_Play(s->engine);
}
void zv_mf_pause(ZvMf *s) { IMFMediaEngine_Pause(s->engine); }
void zv_mf_seek(ZvMf *s, uint64_t at) {
    AcquireSRWLockExclusive(&s->lock);
    if (s->state == ENDED) s->state = READY;
    s->seek_to = at;
    s->seeking = 1;
    s->landed = 0;
    ReleaseSRWLockExclusive(&s->lock);
    IMFMediaEngine_SetCurrentTime(s->engine, (double)at / 1e9);
}
void zv_mf_set_loop(ZvMf *s, int looping) {
    AcquireSRWLockExclusive(&s->lock);
    s->looping = looping;
    ReleaseSRWLockExclusive(&s->lock);
    IMFMediaEngine_SetLoop(s->engine, looping ? TRUE : FALSE);
}
void zv_mf_set_rate(ZvMf *s, double rate) {
    IMFMediaEngine_SetDefaultPlaybackRate(s->engine, rate);
    IMFMediaEngine_SetPlaybackRate(s->engine, rate);
}
void zv_mf_set_volume(ZvMf *s, double volume) { IMFMediaEngine_SetVolume(s->engine, volume); }
void zv_mf_set_muted(ZvMf *s, int muted) { IMFMediaEngine_SetMuted(s->engine, muted ? TRUE : FALSE); }
/* Shuts the engine down, which stops its events, then frees it. */
void zv_mf_close(ZvMf *s) {
    AcquireSRWLockExclusive(&s->lock);
    s->closed = 1;
    s->wake = NULL;
    ReleaseSRWLockExclusive(&s->lock);
    IMFMediaEngine_Shutdown(s->engine);
    release(s);
}
