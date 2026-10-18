#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define D2D_USE_C_DEFINITIONS
#include <windows.h>
#include <initguid.h>
#include <d3d11.h>
#include <dxgi1_3.h>
#include <d2d1_1.h>
#include <dwrite.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include "brushes.h"
#include "image_resource.h"
#include "coverage_resource.h"
#include "gradient_interpolation_native.h"
#include "gaussian_gpu_native.h"

/* Native graphics resources only; command storage and rendering policy live in Zig. */
#define GEOMETRY_CAPACITY 32
typedef struct ShapeGeometry {
    ID2D1PathGeometry *path;
    float width,height,radius,stroke;
    uint64_t used;
} ShapeGeometry;
typedef struct CachedImage {ID2D1Bitmap *bitmaps[2][ZI_IMAGE_LEVELS];const ZiImageLevel *levels;ZiImageLevel coverage_level;uint32_t count,dynamic,active,is_coverage;} CachedImage;
typedef struct GpuLayers GpuLayers;
typedef struct GpuDomain GpuDomain;
typedef struct State {
    GpuDomain *domain;
    struct State *domain_previous, *domain_next;
    ID3D11Device *d3d;
    ID2D1Factory1 *factory;
    ID2D1Device *device;
    ID2D1DeviceContext *context;
    IDXGISwapChain1 *swapchain;
    IDXGISwapChain2 *swapchain2;
    HANDLE frame_ready;
    ID2D1Bitmap1 *target;
    ID2D1SolidColorBrush *brush;
    IDWriteFactory *text_factory;
    IDWriteTextFormat *format;
    IDWriteInlineObject *ellipsis;
    HWND parent, surface;
    UINT width, height, clips;
    D2D1_RECT_F clip_rects[33];
    GpuLayers *layers;
    uint32_t layer_fault;
    FLOAT dpi;
    int driver, fault, offscreen, class_owned;
    BOOL drawing;
    uint32_t device_creations, target_creations, resizes, presents, device_losses, busy_presents;
    ShapeGeometry shapes[GEOMETRY_CAPACITY];
    uint64_t geometry_clock;
    uint32_t geometry_creations,geometry_evictions;
    ID2D1Effect *gradient;
    uint64_t gradient_previous_uploads;
    uint32_t gradient_creations,gradient_draws,gradient_restores;
    CachedImage images[ZI_IMAGE_SLOTS],image_candidate;
    uint32_t image_fault;
    BOOL image_loss_fault;
    uint32_t image_update_loss_mip;
    uint64_t image_restores;
    uint64_t image_creations;
    uint64_t coverage_creations,coverage_restores;
    size_t coverage_scratch_peak;
    ZgInterpolation *interpolation;
} State;
static LONG live_resources;
static unsigned class_owners;
static const WCHAR surface_class[] = L"Ziggurat.Graphics.Surface.0";
#define OWN(p) do { if (p) InterlockedIncrement(&live_resources); } while (0)
#define DROP(p) do { if (p) { IUnknown_Release((IUnknown *)(p)); (p) = NULL; InterlockedDecrement(&live_resources); } } while (0)
#define RT(s) ((ID2D1RenderTarget *)(s)->context)
#include "gradient_effect.h"
static HRESULT create_device(State *s);
static void release_device(State *s);
static HRESULT failure(State *s,HRESULT hr);
static D2D1_RECT_F rectangle(float x,float y,float width,float height);
static HRESULT end_frame(State *s,int offscreen);
/* Raster scopes retain their transparent guard through final sampling. */
#include "gpu_layers.h"
#include "gpu_domain.h"

uint32_t zgpu_resource_count(void) { return (uint32_t)InterlockedCompareExchange(&live_resources, 0, 0); }
void zgpu_interpolation_account(int delta){InterlockedExchangeAdd(&live_resources,delta);}
void zgpu_gaussian_account(int delta){InterlockedExchangeAdd(&live_resources,delta);}
void zgpu_gaussian_dispose(ZgGaussianGpu *owner){if(owner)owner->ops->destroy(owner);}
HRESULT zgpu_gaussian_environment(State *s,ID3D11Device **device,ID2D1DeviceContext **context){
    *device=NULL;*context=NULL;if(!s||s->drawing)return E_UNEXPECTED;
    if(!s->context){HRESULT hr=create_device(s);if(FAILED(hr))return hr;}
    *device=s->d3d;*context=s->context;return S_OK;
}

static LRESULT CALLBACK surface_proc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp) {
    if (message == WM_NCCREATE) {
        const CREATESTRUCTW *cs = (const CREATESTRUCTW *)lp;
        State *s = cs->lpCreateParams;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)s);
        s->surface = hwnd; InterlockedIncrement(&live_resources);
    }
    if (message == WM_NCHITTEST) return HTTRANSPARENT;
    if (message == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
    if (message == WM_ERASEBKGND) return 1;
    if (message == WM_PAINT) {
        PAINTSTRUCT paint; BeginPaint(hwnd, &paint); EndPaint(hwnd, &paint); return 0;
    }
    if (message == WM_NCDESTROY) {
        State *s = (State *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        if (s && s->surface == hwnd) { s->surface = NULL; InterlockedDecrement(&live_resources); }
    }
    return DefWindowProcW(hwnd, message, wp, lp);
}
static HRESULT acquire_surface_class(void) {
    if (!class_owners) {
        WNDCLASSEXW wc = {0}; wc.cbSize=sizeof(wc); wc.hInstance=GetModuleHandleW(NULL);
        wc.lpfnWndProc=surface_proc; wc.lpszClassName=surface_class;
        if (!RegisterClassExW(&wc)) return HRESULT_FROM_WIN32(GetLastError());
        InterlockedIncrement(&live_resources);
    }
    class_owners++; return S_OK;
}
static void release_surface_class(void) {
    if (!--class_owners) {
        UnregisterClassW(surface_class, GetModuleHandleW(NULL));
        InterlockedDecrement(&live_resources);
    }
}
static void hide_surface(State *s) { if (s->surface) ShowWindow(s->surface, SW_HIDE); }
static void destroy_surface(State *s) { if (s->surface) DestroyWindow(s->surface); s->parent=NULL; }

static void finish_draw(State *s) {
    if (!s->drawing) return;
    while (s->clips) { ID2D1RenderTarget_PopAxisAlignedClip(RT(s)); s->clips--; }
    ID2D1RenderTarget_EndDraw(RT(s), NULL, NULL);
    s->drawing = FALSE;
    gpu_layer_abort_metadata(s);
    if(s->context&&s->target)s->context->lpVtbl->SetTarget(s->context,(ID2D1Image *)s->target);
}
static void release_target(State *s) {
    if (s->context) s->context->lpVtbl->SetTarget(s->context, NULL);
    DROP(s->target);
}
static void drop_image_objects(CachedImage *image){for(unsigned bank=0;bank<2;bank++)for(uint32_t i=0;i<image->count;i++)DROP(image->bitmaps[bank][i]);}
static void drop_image(CachedImage *image){drop_image_objects(image);memset(image,0,sizeof(*image));}
static HRESULT create_image_objects(State *s,CachedImage *image,uint32_t fault){
    for(unsigned bank=0;bank<(image->dynamic?2u:1u);bank++)for(uint32_t i=0;i<image->count;i++){
        if(fault==bank*image->count+i+1){drop_image_objects(image);return E_OUTOFMEMORY;}
        const ZiImageLevel *level=&image->levels[i];
        D2D1_SIZE_U size={level->width,level->height};uint32_t stride=level->stride;const uint8_t *pixels=level->pixels;uint8_t *padding=NULL;
        if(image->is_coverage){size.width+=2;size.height+=2;stride=size.width;}
        if(size.width>ID2D1RenderTarget_GetMaximumBitmapSize(RT(s))||size.height>ID2D1RenderTarget_GetMaximumBitmapSize(RT(s))){drop_image_objects(image);return E_INVALIDARG;}
        /* FillOpacityMask clips to its destination rectangle and clamps the
           bitmap boundary. Explicit transparent texels preserve outside-zero
           bilinear sampling even for a mask whose first/last texel is nonzero.
           This temporary plane exists only during upload/device restoration. */
        if(image->is_coverage){
            padding=calloc((size_t)size.height,stride);if(!padding){drop_image_objects(image);return E_OUTOFMEMORY;}
            size_t scratch=(size_t)size.height*stride;if(scratch>s->coverage_scratch_peak)s->coverage_scratch_peak=scratch;
            for(uint32_t y=0;y<level->height;y++)memcpy(padding+(size_t)(y+1)*stride+1,level->pixels+(size_t)y*level->stride,level->width);
            pixels=padding;
        }
        const D2D1_BITMAP_PROPERTIES properties={{image->is_coverage?DXGI_FORMAT_A8_UNORM:DXGI_FORMAT_B8G8R8A8_UNORM,D2D1_ALPHA_MODE_PREMULTIPLIED},96,96};
        HRESULT hr=ID2D1RenderTarget_CreateBitmap(RT(s),size,pixels,stride,&properties,&image->bitmaps[bank][i]);free(padding);OWN(image->bitmaps[bank][i]);if(image->bitmaps[bank][i]){if(image->is_coverage)s->coverage_creations++;else s->image_creations++;}
        if(FAILED(hr)){drop_image_objects(image);return hr;}
    }
    return S_OK;
}
static void release_device(State *s) {
    hide_surface(s);
    finish_draw(s);
    release_target(s);
    if(s->interpolation)s->interpolation->ops->lose(s->interpolation);
    gpu_layer_drop_objects(s->layers);
    for (unsigned i=0;i<GEOMETRY_CAPACITY;i++) { DROP(s->shapes[i].path); s->shapes[i].used=0; }
    s->gradient_previous_uploads+=gradient_uploads(s->gradient);DROP(s->gradient);
    for (unsigned i=0;i<ZI_IMAGE_SLOTS;i++)drop_image_objects(&s->images[i]);
    drop_image(&s->image_candidate);
    DROP(s->brush);
    DROP(s->context);
    DROP(s->device);
    if (s->frame_ready) { CloseHandle(s->frame_ready); s->frame_ready=NULL; InterlockedDecrement(&live_resources); }
    DROP(s->swapchain2);
    DROP(s->swapchain);
    if (s->d3d) {
        ID3D11DeviceContext *context = NULL;
        ID3D11Device_GetImmediateContext(s->d3d, &context);
        if (context) {
            ID3D11DeviceContext_ClearState(context);
            ID3D11DeviceContext_Flush(context);
            ID3D11DeviceContext_Release(context);
        }
    }
    DROP(s->d3d);
    s->width = s->height = 0; s->dpi = 0;
}
static BOOL device_lost(HRESULT hr) {
    return hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET ||
        hr == DXGI_ERROR_DEVICE_HUNG || hr == DXGI_ERROR_DRIVER_INTERNAL_ERROR || hr == D2DERR_RECREATE_TARGET;
}
static HRESULT failure(State *s, HRESULT hr) {
    if (device_lost(hr)) {
        if(s->domain) gpu_domain_lose(s->domain);
        else {s->device_losses++; release_device(s);}
    }
    return hr;
}
static HRESULT create_device(State *s) {
    IDXGIDevice *dxgi = NULL;
    D3D_FEATURE_LEVEL level;
    const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
    HRESULT hr;
    if(s->domain){
        if(s->domain->epoch->status!=1)return DXGI_ERROR_DEVICE_REMOVED;
        s->d3d=s->domain->d3d;ID3D11Device_AddRef(s->d3d);OWN(s->d3d);
        s->device=s->domain->device;IUnknown_AddRef((IUnknown *)s->device);OWN(s->device);
        hr=S_OK;
    }else{
    hr = D3D11CreateDevice(NULL, s->driver ? D3D_DRIVER_TYPE_WARP : D3D_DRIVER_TYPE_HARDWARE,
        NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_SINGLETHREADED,
        levels, sizeof(levels)/sizeof(levels[0]), D3D11_SDK_VERSION, &s->d3d, &level, NULL);
    OWN(s->d3d);
    if (FAILED(hr)) goto failed;
    hr = ID3D11Device_QueryInterface(s->d3d, &IID_IDXGIDevice, (void **)&dxgi);
    OWN(dxgi);
    if (FAILED(hr)) goto failed;
    hr = s->factory->lpVtbl->CreateDevice(s->factory, dxgi, &s->device);
    OWN(s->device);
    if (FAILED(hr)) goto failed;
    }
    hr = s->device->lpVtbl->CreateDeviceContext(s->device, D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &s->context);
    OWN(s->context);
    if (FAILED(hr)) goto failed;
    const D2D1_COLOR_F color = {0,0,0,1};
    hr = ID2D1RenderTarget_CreateSolidColorBrush(RT(s), &color, NULL, &s->brush);
    OWN(s->brush);
    if (FAILED(hr)) goto failed;
    ID2D1RenderTarget_SetTextAntialiasMode(RT(s), D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE);
    hr=s->context->lpVtbl->CreateEffect(s->context,&effect_id,&s->gradient);OWN(s->gradient);
    if(FAILED(hr))goto failed;
    if(s->gradient_creations)s->gradient_restores++;
    s->gradient_creations++;
    /* Explicit residency retains bounded CPU descriptors across device loss.
       Recovery rebuilds that resident set; ordinary draws never upload. */
    for(unsigned i=0;i<ZI_IMAGE_SLOTS;i++)if(s->images[i].count){hr=create_image_objects(s,&s->images[i],0);if(FAILED(hr))goto failed;if(s->images[i].is_coverage)s->coverage_restores++;else s->image_restores++;}
    if(s->layers){hr=gpu_layer_objects(s,s->layers,0);if(FAILED(hr))goto failed;s->layers->stats.native_restores++;}
    DROP(dxgi);
    s->device_creations++;
    return S_OK;
failed:
    DROP(dxgi);
    release_device(s);
    if(s->domain&&device_lost(hr))gpu_domain_lose(s->domain);
    return hr;
}

static State *create_renderer(int driver,GpuDomain *domain,int offscreen,HRESULT *out) {
    if (driver != 0 && driver != 1) { *out = E_INVALIDARG; return NULL; }
    State *s = calloc(1, sizeof(*s));
    if (!s) { *out = E_OUTOFMEMORY; return NULL; }
    InterlockedIncrement(&live_resources);
    s->driver = driver;
    s->domain=domain;
    s->offscreen=offscreen;
    if(!offscreen){
        *out = acquire_surface_class();
        if (FAILED(*out)) { free(s); InterlockedDecrement(&live_resources); return NULL; }
        s->class_owned=1;
    }
    D2D1_FACTORY_OPTIONS options = {D2D1_DEBUG_LEVEL_NONE};
    if(domain){s->factory=domain->factory;IUnknown_AddRef((IUnknown *)s->factory);*out=S_OK;}
    else *out = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &IID_ID2D1Factory1, &options, (void **)&s->factory);
    OWN(s->factory);
    if (FAILED(*out)) goto failed;
    *out=domain?S_OK:register_gradient(s->factory);
    if(FAILED(*out))goto failed;
    *out = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, &IID_IDWriteFactory, (IUnknown **)&s->text_factory);
    OWN(s->text_factory);
    if (FAILED(*out)) goto failed;
    *out = IDWriteFactory_CreateTextFormat(s->text_factory, L"Segoe UI", NULL, DWRITE_FONT_WEIGHT_NORMAL,
        DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, 16.0f, L"", &s->format);
    OWN(s->format);
    if (FAILED(*out)) goto failed;
    *out = IDWriteTextFormat_SetParagraphAlignment(s->format, DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    if (FAILED(*out)) goto failed;
    *out = IDWriteTextFormat_SetWordWrapping(s->format, DWRITE_WORD_WRAPPING_NO_WRAP);
    if (FAILED(*out)) goto failed;
    *out = IDWriteFactory_CreateEllipsisTrimmingSign(s->text_factory, s->format, &s->ellipsis);
    OWN(s->ellipsis);
    if (FAILED(*out)) goto failed;
    const DWRITE_TRIMMING trimming = {DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
    *out = IDWriteTextFormat_SetTrimming(s->format, &trimming, s->ellipsis);
    if (FAILED(*out)) goto failed;
    *out = create_device(s);
    if (FAILED(*out)) goto failed;
    if(domain){s->domain_next=domain->renderers;if(domain->renderers)domain->renderers->domain_previous=s;domain->renderers=s;}
    return s;
failed:
    release_device(s);
    DROP(s->format); DROP(s->ellipsis); DROP(s->text_factory); DROP(s->factory);
    if(s->class_owned)release_surface_class();
    free(s); InterlockedDecrement(&live_resources); return NULL;
}
State *zgpu_create(int driver,HRESULT *out){return create_renderer(driver,NULL,0,out);}
HRESULT zgpu_interpolation_environment(State *s,ID2D1Factory1 **factory,ID2D1DeviceContext **context){
    *factory=NULL;*context=NULL;if(!s||s->drawing)return E_UNEXPECTED;
    if(!s->context){HRESULT hr=create_device(s);if(FAILED(hr))return hr;}
    *factory=s->factory;*context=s->context;return S_OK;
}
int zgpu_interpolation_context_current(State *s,ID2D1DeviceContext *context){return s&&s->context==context;}
void zgpu_interpolation_stats(State *s,ZgInterpolationStats *out){
    memset(out,0,sizeof(*out));if(s&&s->interpolation)s->interpolation->ops->stats(s->interpolation,out);
}
ZgInterpolation *zgpu_interpolation_take(State *s){ZgInterpolation *old=s->interpolation;s->interpolation=NULL;return old;}
size_t zgpu_interpolation_dispose(ZgInterpolation *value){
    if(!value)return 0;size_t reserved=(size_t)value->stats.metadata_reserved;value->ops->destroy(value);return reserved;
}
int zgpu_interpolation_ready(State *s){return s&&s->interpolation&&s->interpolation->stats.ready;}
int zgpu_interpolation_target_supported(State *s){return s&&s->width&&s->height;}
HRESULT zgpu_interpolation_failure(State *s,HRESULT hr){return failure(s,hr);}
HRESULT zgpu_interpolation_install(State *s,ZgInterpolation *value,ID2D1DeviceContext *context){
    if(!s||s->drawing||s->interpolation||!value||!value->stats.ready)return E_UNEXPECTED;
    if(s->context!=context)return DXGI_ERROR_DEVICE_REMOVED;
    s->interpolation=value;return S_OK;
}
HRESULT zgpu_gradient_interpolated(State *s,float x,float y,float width,float height,float radius,float stroke,const ZgBrush *key,const ZgInterpolationPacket *packet){
    if(!s||!s->drawing||!s->interpolation||!s->interpolation->stats.ready)return ZG_E_GRADIENT_PRECISION;
    return failure(s,s->interpolation->ops->draw(s->interpolation,s->context,x,y,width,height,radius,stroke,s->dpi/96.0,
        s->layers&&s->layers->depth?s->layers->pool_width:s->width,
        s->layers&&s->layers->depth?s->layers->pool_height:s->height,key,packet));
}
State *zgpu_create_in_domain(GpuDomain *domain,HRESULT *out){
    if(!domain||domain->epoch->status!=1){*out=E_INVALIDARG;return NULL;}
    return create_renderer(domain->driver,domain,0,out);
}
#include "gpu_offscreen.h"

static HRESULT create_swapchain(State *s, UINT width, UINT height) {
    IDXGIDevice *dxgi = NULL;
    IDXGIAdapter *adapter = NULL;
    IDXGIFactory2 *factory = NULL;
    HRESULT hr = ID3D11Device_QueryInterface(s->d3d, &IID_IDXGIDevice, (void **)&dxgi);
    OWN(dxgi);
    if (FAILED(hr)) goto done;
    hr = IDXGIDevice_GetAdapter(dxgi, &adapter); OWN(adapter);
    if (FAILED(hr)) goto done;
    hr = IDXGIAdapter_GetParent(adapter, &IID_IDXGIFactory2, (void **)&factory); OWN(factory);
    if (FAILED(hr)) goto done;
    DXGI_SWAP_CHAIN_DESC1 desc = {0};
    desc.Width = width; desc.Height = height; desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1; desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2; desc.Scaling = DXGI_SCALING_STRETCH;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL; desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
    desc.Flags=DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;
    /* The parent remains a GDI window. Flip presentation targets only this child. */
    hr = IDXGIFactory2_CreateSwapChainForHwnd(factory, (IUnknown *)s->d3d, s->surface, &desc, NULL, NULL, &s->swapchain);
    OWN(s->swapchain);
    if (FAILED(hr)) goto done;
    hr=IDXGISwapChain1_QueryInterface(s->swapchain,&IID_IDXGISwapChain2,(void **)&s->swapchain2); OWN(s->swapchain2);
    if (FAILED(hr)) goto done;
    hr=IDXGISwapChain2_SetMaximumFrameLatency(s->swapchain2,1);
    if (FAILED(hr)) goto done;
    s->frame_ready=IDXGISwapChain2_GetFrameLatencyWaitableObject(s->swapchain2);
    if (!s->frame_ready) {hr=E_FAIL;goto done;}
    InterlockedIncrement(&live_resources);
    s->width = width; s->height = height; IDXGIFactory2_MakeWindowAssociation(factory, s->surface, DXGI_MWA_NO_ALT_ENTER);
done:
    DROP(factory); DROP(adapter); DROP(dxgi);
    if(FAILED(hr)) { if(s->frame_ready){CloseHandle(s->frame_ready);s->frame_ready=NULL;InterlockedDecrement(&live_resources);} DROP(s->swapchain2);DROP(s->swapchain); }
    return hr;
}

HRESULT zgpu_begin(State *s, HWND hwnd, UINT width, UINT height, FLOAT dpi) {
    if (!s || s->drawing || s->offscreen) return E_UNEXPECTED;
    if (!hwnd || !IsWindow(hwnd) || !width || !height || !(dpi > 0)) return E_INVALIDARG;
    HRESULT hr = S_OK;
    if (!s->d3d) { hr = create_device(s); if (FAILED(hr)) return hr; }
    if (s->parent != hwnd || !s->surface) {
        release_target(s);
        if(s->frame_ready){CloseHandle(s->frame_ready);s->frame_ready=NULL;InterlockedDecrement(&live_resources);}
        DROP(s->swapchain2);DROP(s->swapchain); destroy_surface(s);
        s->parent = hwnd;
        s->surface = CreateWindowExW(WS_EX_NOPARENTNOTIFY | WS_EX_NOACTIVATE, surface_class, NULL,
            WS_CHILD | WS_DISABLED, 0,0,width,height,hwnd,NULL,GetModuleHandleW(NULL),s);
        if (!s->surface) return HRESULT_FROM_WIN32(GetLastError());
    }
    if ((s->width != width || s->height != height) &&
        !SetWindowPos(s->surface,NULL,0,0,width,height,SWP_NOZORDER|SWP_NOACTIVATE)) return HRESULT_FROM_WIN32(GetLastError());
    if (!s->swapchain) {
        hr = create_swapchain(s, width, height);
        if (FAILED(hr)) return failure(s, hr);
    } else if (s->width != width || s->height != height) {
        release_target(s);
        if (s->fault == 2) { s->fault = 0; return failure(s, DXGI_ERROR_DEVICE_REMOVED); }
        hr = IDXGISwapChain1_ResizeBuffers(s->swapchain, 2, width, height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT);
        if (FAILED(hr)) return failure(s, hr);
        s->width = width; s->height = height; s->resizes++;
    }
    if (s->dpi != dpi) release_target(s);
    if (!s->target) {
        IDXGISurface *surface = NULL;
        hr = IDXGISwapChain1_GetBuffer(s->swapchain, 0, &IID_IDXGISurface, (void **)&surface); OWN(surface);
        if (FAILED(hr)) { DROP(surface); return failure(s, hr); }
        D2D1_BITMAP_PROPERTIES1 properties = {0};
        properties.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
        properties.pixelFormat.alphaMode = D2D1_ALPHA_MODE_IGNORE;
        properties.dpiX = properties.dpiY = dpi;
        properties.bitmapOptions = D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW;
        hr = s->context->lpVtbl->CreateBitmapFromDxgiSurface(s->context, surface, &properties, &s->target); OWN(s->target);
        DROP(surface);
        if (FAILED(hr)) return failure(s, hr);
        s->target_creations++;
    }
    s->context->lpVtbl->SetTarget(s->context, (struct ID2D1Image *)s->target);
    if(s->layers)gpu_layer_begin(s);
    else ID2D1RenderTarget_SetTextAntialiasMode(RT(s),D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE);
    ID2D1RenderTarget_SetDpi(RT(s), dpi, dpi);
    s->dpi = dpi; s->clips = 0;
    ID2D1RenderTarget_BeginDraw(RT(s)); s->drawing = TRUE;
    const D2D1_COLOR_F background = {1,1,1,1};
    ID2D1RenderTarget_Clear(RT(s), &background);
    return S_OK;
}

static D2D1_RECT_F rectangle(float x, float y, float width, float height) {
    const D2D1_RECT_F r = {x,y,x+width,y+height}; return r;
}
static void brush_color(State *s, uint32_t rgb) {
    const D2D1_COLOR_F color = {(float)((rgb >> 16) & 255)/255, (float)((rgb >> 8)&255)/255, (float)(rgb&255)/255, 1};
    s->brush->lpVtbl->SetColor(s->brush, &color);
}
void zgpu_fill(State *s, float x, float y, float width, float height, uint32_t rgb) {
    const D2D1_RECT_F r = rectangle(x,y,width,height);
    brush_color(s, rgb); ID2D1RenderTarget_FillRectangle(RT(s), &r, (ID2D1Brush *)s->brush);
}
static void shape_contour(ID2D1GeometrySink *sink,float x,float y,float w,float h,float r) {
    const D2D1_POINT_2F start={x+r,y};
    ID2D1GeometrySink_BeginFigure(sink,start,D2D1_FIGURE_BEGIN_FILLED);
    const D2D1_POINT_2F corners[4]={{x+w-r,y},{x+w,y+h-r},{x+r,y+h},{x,y+r}};
    const D2D1_POINT_2F ends[4]={{x+w,y+r},{x+w-r,y+h},{x,y+h-r},{x+r,y}};
    for(unsigned i=0;i<4;i++) {
        ID2D1GeometrySink_AddLine(sink,corners[i]);
        if(r>0) {const D2D1_ARC_SEGMENT arc={ends[i],{r,r},0,D2D1_SWEEP_DIRECTION_CLOCKWISE,D2D1_ARC_SIZE_SMALL};ID2D1GeometrySink_AddArc(sink,&arc);}
        else ID2D1GeometrySink_AddLine(sink,ends[i]);
    }
    ID2D1GeometrySink_EndFigure(sink,D2D1_FIGURE_END_CLOSED);
}
static HRESULT cached_shape(State *s,float w,float h,float r,float stroke,ID2D1PathGeometry **out) {
    if(s->geometry_clock==UINT64_MAX) {s->geometry_clock=0;for(unsigned i=0;i<GEOMETRY_CAPACITY;i++)s->shapes[i].used=0;}
    const uint64_t now=++s->geometry_clock;
    unsigned victim=0;
    for(unsigned i=0;i<GEOMETRY_CAPACITY;i++) {
        ShapeGeometry *entry=&s->shapes[i];
        if(entry->path&&entry->width==w&&entry->height==h&&entry->radius==r&&entry->stroke==stroke) {entry->used=now;*out=entry->path;return S_OK;}
        if(!entry->path || (s->shapes[victim].path && entry->used<s->shapes[victim].used))victim=i;
    }
    ID2D1PathGeometry *path=NULL;ID2D1GeometrySink *sink=NULL;
    HRESULT hr=ID2D1Factory_CreatePathGeometry((ID2D1Factory *)s->factory,&path);OWN(path);
    if(FAILED(hr))goto done;
    hr=ID2D1PathGeometry_Open(path,&sink);OWN(sink);if(FAILED(hr))goto done;
    ID2D1GeometrySink_SetFillMode(sink,D2D1_FILL_MODE_ALTERNATE);
    shape_contour(sink,0,0,w,h,r);
    if(w>stroke*2&&h>stroke*2)shape_contour(sink,stroke,stroke,w-stroke*2,h-stroke*2,r>stroke?r-stroke:0);
    hr=ID2D1GeometrySink_Close(sink);if(FAILED(hr))goto done;
    if(s->shapes[victim].path){DROP(s->shapes[victim].path);s->geometry_evictions++;}
    s->shapes[victim]=(ShapeGeometry){path,w,h,r,stroke,now};path=NULL;
    s->geometry_creations++;*out=s->shapes[victim].path;
done:
    DROP(sink);DROP(path);return hr;
}
static HRESULT draw_shape(State *s,float x,float y,float width,float height,float radius,float stroke,ID2D1Brush *brush) {
    if(stroke==0||width<=stroke*2||height<=stroke*2) {
        const D2D1_ROUNDED_RECT rr={rectangle(x,y,width,height),radius,radius};
        ID2D1RenderTarget_FillRoundedRectangle(RT(s),&rr,brush);return S_OK;
    }
    if(radius==0) {
        const D2D1_RECT_F r=rectangle(x+stroke/2,y+stroke/2,width-stroke,height-stroke);
        ID2D1RenderTarget_DrawRectangle(RT(s),&r,brush,stroke,NULL);return S_OK;
    }
    ID2D1PathGeometry *path=NULL;HRESULT hr=cached_shape(s,width,height,radius,stroke,&path);if(FAILED(hr))return hr;
    D2D1_MATRIX_3X2_F before,translated;ID2D1RenderTarget_GetTransform(RT(s),&before);translated=before;
    translated._31+=x*before._11+y*before._21;translated._32+=x*before._12+y*before._22;
    ID2D1RenderTarget_SetTransform(RT(s),&translated);
    ID2D1RenderTarget_FillGeometry(RT(s),(ID2D1Geometry *)path,brush,NULL);
    ID2D1RenderTarget_SetTransform(RT(s),&before);return S_OK;
}
HRESULT zgpu_shape(State *s,float x,float y,float width,float height,float radius,float stroke,uint32_t rgba) {
    if(width==0||height==0||(rgba&255)==0)return S_OK;
    const D2D1_COLOR_F color={(float)(rgba>>24)/255,(float)((rgba>>16)&255)/255,(float)((rgba>>8)&255)/255,(float)(rgba&255)/255};
    s->brush->lpVtbl->SetColor(s->brush,&color);
    return failure(s,draw_shape(s,x,y,width,height,radius,stroke,(ID2D1Brush *)s->brush));
}
/* The shader uses physical, viewport-local coordinates. Beyond this tested
   float envelope the complete frame uses the existing software fallback. */
#define ZG_E_GRADIENT_PRECISION ((HRESULT)0x88995001u)
HRESULT zgpu_gradient(State *s,float x,float y,float width,float height,float radius,float stroke,const ZgBrush *key) {
    Constants v;
    HRESULT prepared=gradient_values(&v,x,y,width,height,radius,stroke,s->dpi/96.0,
        s->layers&&s->layers->depth?s->layers->pool_width:s->width,
        s->layers&&s->layers->depth?s->layers->pool_height:s->height,key);
    if(prepared!=S_OK)return prepared==S_FALSE?S_OK:prepared;
    HRESULT hr=s->gradient->lpVtbl->SetValue(s->gradient,0,D2D1_PROPERTY_TYPE_BLOB,(const BYTE *)&v,sizeof(v));if(FAILED(hr))return failure(s,hr);
    ID2D1Image *image=NULL;s->gradient->lpVtbl->GetOutput(s->gradient,&image);OWN(image);
    if(!image)return E_UNEXPECTED;
    s->context->lpVtbl->DrawImage(s->context,image,NULL,NULL,D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR,D2D1_COMPOSITE_MODE_SOURCE_OVER);DROP(image);s->gradient_draws++;
    return S_OK;
}
void zgpu_brush_stats(State *s,uint32_t *created,uint32_t *evicted,uint32_t *cached) {(void)s;*created=*evicted=*cached=0;}
void zgpu_gradient_stats(State *s,uint32_t *created,uint32_t *draws,uint64_t *uploads,uint32_t *restores){
    *created=s->gradient_creations;*draws=s->gradient_draws;*uploads=s->gradient_previous_uploads+gradient_uploads(s->gradient);*restores=s->gradient_restores;
}
void zgpu_geometry_stats(State *s,uint32_t *creations,uint32_t *evictions,uint32_t *cached) {
    *creations=s->geometry_creations;*evictions=s->geometry_evictions;*cached=0;
    for(unsigned i=0;i<GEOMETRY_CAPACITY;i++)if(s->shapes[i].path)(*cached)++;
}
void zgpu_text(State *s, float x, float y, float width, float height, uint32_t rgb, const WCHAR *text, uint32_t len) {
    const D2D1_RECT_F r = rectangle(x,y,width,height);
    brush_color(s, rgb);
    ID2D1RenderTarget_DrawText(RT(s), text, len, s->format, &r, (ID2D1Brush *)s->brush, D2D1_DRAW_TEXT_OPTIONS_CLIP, DWRITE_MEASURING_MODE_NATURAL);
}
typedef struct PreparedClip {float x,y,width,height;} PreparedClip;
float zgpu_scale(State *s){return s->dpi/96.0f;}
static HRESULT prepare_image(State *s,const ZiImageLevel *levels,uint32_t count,int dynamic){
    if(s->drawing||s->image_candidate.count||!count||count>ZI_IMAGE_LEVELS)return E_INVALIDARG;
    if(s->image_loss_fault){s->image_loss_fault=FALSE;return failure(s,DXGI_ERROR_DEVICE_REMOVED);}
    HRESULT hr=S_OK;if(!s->context){hr=create_device(s);if(FAILED(hr))return hr;}
    CachedImage candidate={0};candidate.levels=levels;candidate.count=count;candidate.dynamic=dynamic;uint32_t fault=s->image_fault;s->image_fault=0;
    hr=create_image_objects(s,&candidate,fault);if(FAILED(hr)){drop_image(&candidate);return failure(s,hr);}
    s->image_candidate=candidate;return S_OK;
}
HRESULT zgpu_prepare_image(State *s,const ZiImageLevel *levels,uint32_t count){return prepare_image(s,levels,count,0);}
HRESULT zgpu_prepare_dynamic_image(State *s,const ZiImageLevel *levels,uint32_t count){return prepare_image(s,levels,count,1);}
HRESULT zgpu_prepare_coverage(State *s,const ZgCoverage *coverage){
    if(s->drawing||s->image_candidate.count)return E_INVALIDARG;
    if(s->image_loss_fault){s->image_loss_fault=FALSE;return failure(s,DXGI_ERROR_DEVICE_REMOVED);}
    HRESULT hr=S_OK;if(!s->context){hr=create_device(s);if(FAILED(hr))return hr;}
    CachedImage candidate={0};candidate.count=1;candidate.is_coverage=1;
    candidate.coverage_level=(ZiImageLevel){coverage->pixels,coverage->byte_len,coverage->width,coverage->height,coverage->stride};candidate.levels=&candidate.coverage_level;
    uint32_t fault=s->image_fault;s->image_fault=0;
    hr=create_image_objects(s,&candidate,fault);if(FAILED(hr)){drop_image(&candidate);return failure(s,hr);}
    s->image_candidate=candidate;s->image_candidate.levels=&s->image_candidate.coverage_level;return S_OK;
}
HRESULT zgpu_update_image(State *s,uint32_t slot,const ZiImageLevel *levels,uint32_t count){
    if(s->drawing||slot>=ZI_IMAGE_SLOTS||!s->images[slot].dynamic||s->images[slot].count!=count)return E_INVALIDARG;
    if(s->image_loss_fault){s->image_loss_fault=FALSE;return failure(s,DXGI_ERROR_DEVICE_REMOVED);}
    HRESULT hr=S_OK;if(!s->context){hr=create_device(s);if(FAILED(hr))return hr;}
    CachedImage *image=&s->images[slot];unsigned bank=1-image->active;uint32_t fault=s->image_fault,loss_mip=s->image_update_loss_mip;s->image_fault=0;s->image_update_loss_mip=0;
    for(uint32_t i=0;i<count;i++){
        if(fault==i+1)return E_OUTOFMEMORY;
        if(loss_mip==i+1)return failure(s,DXGI_ERROR_DEVICE_REMOVED);
        hr=ID2D1Bitmap_CopyFromMemory(image->bitmaps[bank][i],NULL,levels[i].pixels,levels[i].stride);if(FAILED(hr))return failure(s,hr);
    }
    image->active=bank;image->levels=levels;return S_OK;
}
void zgpu_commit_image(State *s,uint32_t slot){drop_image(&s->images[slot]);s->images[slot]=s->image_candidate;if(s->images[slot].is_coverage)s->images[slot].levels=&s->images[slot].coverage_level;memset(&s->image_candidate,0,sizeof(s->image_candidate));}
void zgpu_release_image(State *s,uint32_t slot){if(slot<ZI_IMAGE_SLOTS)drop_image(&s->images[slot]);}
void zgpu_image_fault(State *s,uint32_t mip){s->image_fault=mip;}
void zgpu_image_loss_fault(State *s){s->image_loss_fault=TRUE;}
void zgpu_image_update_loss_at(State *s,uint32_t mip){s->image_update_loss_mip=mip;}
HRESULT zgpu_image(State *s,uint32_t slot,const ZiImagePlan *plan){
    if(!s->drawing||slot>=ZI_IMAGE_SLOTS||plan->level>=s->images[slot].count||!s->images[slot].bitmaps[s->images[slot].active][plan->level])return E_INVALIDARG;
    const D2D1_RECT_F destination=rectangle(plan->destination.x,plan->destination.y,plan->destination.width,plan->destination.height),source=rectangle(plan->source.x,plan->source.y,plan->source.width,plan->source.height);
    ID2D1RenderTarget_DrawBitmap(RT(s),s->images[slot].bitmaps[s->images[slot].active][plan->level],&destination,plan->opacity,plan->sampling?D2D1_BITMAP_INTERPOLATION_MODE_LINEAR:D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR,&source);return S_OK;
}
static uint32_t raster_objects(State *s,int coverage){uint32_t n=0;for(unsigned i=0;i<ZI_IMAGE_SLOTS;i++)if(s->images[i].is_coverage==(uint32_t)coverage)for(unsigned bank=0;bank<2;bank++)for(unsigned j=0;j<s->images[i].count;j++)if(s->images[i].bitmaps[bank][j])n++;return n;}
void zgpu_image_stats(State *s,uint64_t *restores,uint32_t *objects,uint64_t *creations){*restores=s->image_restores;*creations=s->image_creations;*objects=raster_objects(s,0);}
void zgpu_coverage_stats(State *s,uint64_t *restores,uint32_t *objects,uint64_t *creations){*restores=s->coverage_restores;*creations=s->coverage_creations;*objects=raster_objects(s,1);}
size_t zgpu_coverage_scratch_peak(State *s){return s->coverage_scratch_peak;}
HRESULT zgpu_coverage(State *s,uint32_t slot,float x,float y,float scale,uint32_t rgba){
    if(!s->drawing||slot>=ZI_IMAGE_SLOTS||!s->images[slot].is_coverage||!s->images[slot].bitmaps[0][0])return E_INVALIDARG;
    const ZiImageLevel *level=&s->images[slot].coverage_level;
    const D2D1_RECT_F destination=rectangle(x-1.0f/scale,y-1.0f/scale,(level->width+2)/scale,(level->height+2)/scale),source=rectangle(0,0,(float)(level->width+2),(float)(level->height+2));
    const D2D1_COLOR_F color={(float)(rgba>>24)/255.0f,(float)((rgba>>16)&255)/255.0f,(float)((rgba>>8)&255)/255.0f,(float)(rgba&255)/255.0f};
    s->brush->lpVtbl->SetColor(s->brush,&color);
    D2D1_ANTIALIAS_MODE previous=ID2D1RenderTarget_GetAntialiasMode(RT(s));ID2D1RenderTarget_SetAntialiasMode(RT(s),D2D1_ANTIALIAS_MODE_ALIASED);
    ID2D1RenderTarget_FillOpacityMask(RT(s),s->images[slot].bitmaps[0][0],(ID2D1Brush *)s->brush,D2D1_OPACITY_MASK_CONTENT_GRAPHICS,&destination,&source);
    ID2D1RenderTarget_SetAntialiasMode(RT(s),previous);return S_OK;
}
void zgpu_prepared(State *s,IDWriteTextLayout *layout,float x,float y,const PreparedClip *clip,uint32_t rgba){
    const D2D1_COLOR_F color={(float)(rgba>>24)/255.0f,(float)((rgba>>16)&255)/255.0f,(float)((rgba>>8)&255)/255.0f,(float)(rgba&255)/255.0f};
    s->brush->lpVtbl->SetColor(s->brush,&color);
    D2D1_TEXT_ANTIALIAS_MODE previous=ID2D1RenderTarget_GetTextAntialiasMode(RT(s));
    ID2D1RenderTarget_SetTextAntialiasMode(RT(s),D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    if(clip){D2D1_RECT_F r=rectangle(x+clip->x,y+clip->y,clip->width,clip->height);ID2D1RenderTarget_PushAxisAlignedClip(RT(s),&r,D2D1_ANTIALIAS_MODE_ALIASED);}
    const D2D1_POINT_2F origin={x,y};ID2D1RenderTarget_DrawTextLayout(RT(s),origin,layout,(ID2D1Brush *)s->brush,D2D1_DRAW_TEXT_OPTIONS_NO_SNAP);
    if(clip)ID2D1RenderTarget_PopAxisAlignedClip(RT(s));
    ID2D1RenderTarget_SetTextAntialiasMode(RT(s),previous);
}
void zgpu_push_clip(State *s, float x, float y, float width, float height) {
    const D2D1_RECT_F r = rectangle(x,y,width,height);
    s->clip_rects[s->clips]=r;
    ID2D1RenderTarget_PushAxisAlignedClip(RT(s), &r, D2D1_ANTIALIAS_MODE_ALIASED); s->clips++;
}
void zgpu_pop_clip(State *s) { ID2D1RenderTarget_PopAxisAlignedClip(RT(s)); s->clips--; }
void zgpu_abort(State *s) { if (s) { finish_draw(s); hide_surface(s); } }
void zgpu_discard(State *s) {if(s)finish_draw(s);}
int zgpu_suspend_surface(State *s){int shown=s&&s->surface&&(GetWindowLongW(s->surface,GWL_STYLE)&WS_VISIBLE)!=0;if(shown)hide_surface(s);return shown;}
void zgpu_restore_surface(State *s){if(s&&s->surface&&s->target&&s->swapchain)ShowWindow(s->surface,SW_SHOWNOACTIVATE);}

static HRESULT end_frame(State *s,int offscreen) {
    if (!s || !s->drawing || s->offscreen!=offscreen) return E_UNEXPECTED;
    if(s->layers&&s->layers->depth){finish_draw(s);return E_UNEXPECTED;}
    while (s->clips) { ID2D1RenderTarget_PopAxisAlignedClip(RT(s)); s->clips--; }
    HRESULT hr = ID2D1RenderTarget_EndDraw(RT(s), NULL, NULL); s->drawing = FALSE;
    if(s->layers)s->context->lpVtbl->SetTarget(s->context,(ID2D1Image *)s->target);
    if (FAILED(hr)) {gpu_layer_abort_metadata(s);return failure(s, hr);}
    if (s->fault == 1) { s->fault = 0;gpu_layer_abort_metadata(s);return failure(s, DXGI_ERROR_DEVICE_REMOVED); }
    if(offscreen)return S_OK;
    if (s->fault == 3) { s->fault=0;s->busy_presents++;gpu_layer_abort_metadata(s);return DXGI_ERROR_WAS_STILL_DRAWING; }
    if(s->layers){hr=gpu_layer_copy_window(s);if(FAILED(hr)){gpu_layer_abort_metadata(s);return failure(s,hr);}}
    BOOL was_visible=(GetWindowLongW(s->surface,GWL_STYLE)&WS_VISIBLE)!=0;
    if (!was_visible) ShowWindow(s->surface, SW_SHOWNOACTIVATE);
    hr = IDXGISwapChain1_Present(s->swapchain, 0, DXGI_PRESENT_DO_NOT_WAIT);
    if (FAILED(hr)) {
        gpu_layer_abort_metadata(s);
        if (hr == DXGI_ERROR_WAS_STILL_DRAWING) {
            s->busy_presents++;
            if(!was_visible)hide_surface(s);
            return hr;
        }
        if(!s->layers)hide_surface(s); return failure(s, hr);
    }
    if(s->layers){GpuLayers *l=s->layers;unsigned previous=l->front;l->front=l->work;l->work=previous;l->active=0;l->stats.committed_frames++;}
    s->presents++;
    return hr;
}
HRESULT zgpu_end(State *s){return end_frame(s,0);}
void zgpu_inject_loss(State *s, int during_resize) { if (s) s->fault = during_resize ? 2 : 1; }
void zgpu_inject_busy(State *s) {if(s)s->fault=3;}
void zgpu_stats(State *s, uint32_t *creations, uint32_t *targets, uint32_t *resizes, uint32_t *presents, uint32_t *losses, uint32_t *busy) {
    *creations=s->device_creations; *targets=s->target_creations; *resizes=s->resizes; *presents=s->presents; *losses=s->device_losses; *busy=s->busy_presents;
}
void zgpu_destroy(State *s) {
    if (!s) return;
    release_device(s);
    zgpu_interpolation_dispose(zgpu_interpolation_take(s));
    if(s->domain){
        if(s->domain_previous)s->domain_previous->domain_next=s->domain_next;else s->domain->renderers=s->domain_next;
        if(s->domain_next)s->domain_next->domain_previous=s->domain_previous;
        s->domain=NULL;
    }
    zgpu_layer_release(s);
    destroy_surface(s);
    DROP(s->format); DROP(s->ellipsis); DROP(s->text_factory); DROP(s->factory);
    if(s->class_owned)release_surface_class();
    free(s); InterlockedDecrement(&live_resources);
}
HWND zgpu_test_surface(State *s) { return s ? s->surface : NULL; }
HANDLE zgpu_frame_ready(State *s) {return s?s->frame_ready:NULL;}
HWND zgpu_test_swapchain_window(State *s) {
    HWND hwnd = NULL;
    if (s && s->swapchain) IDXGISwapChain1_GetHwnd(s->swapchain, &hwnd);
    return hwnd;
}

/* Explicit synchronous readback for hidden integration tests only. */
HRESULT zgpu_test_pixels(State *s,UINT width,UINT height,uint32_t *rgb){
    if(!s||!s->drawing||width!=s->width||height!=s->height||!rgb)return E_INVALIDARG;
    HRESULT hr=ID2D1RenderTarget_Flush(RT(s),NULL,NULL);if(FAILED(hr))return failure(s,hr);
    ID3D11Texture2D *back=NULL,*staging=NULL;ID3D11DeviceContext *context=NULL;
    hr=IDXGISwapChain1_GetBuffer(s->swapchain,0,&IID_ID3D11Texture2D,(void **)&back);OWN(back);if(FAILED(hr))goto done;
    D3D11_TEXTURE2D_DESC desc={0};desc.Width=width;desc.Height=height;desc.MipLevels=desc.ArraySize=desc.SampleDesc.Count=1;
    desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.Usage=D3D11_USAGE_STAGING;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    hr=ID3D11Device_CreateTexture2D(s->d3d,&desc,NULL,&staging);OWN(staging);if(FAILED(hr))goto done;
    ID3D11Device_GetImmediateContext(s->d3d,&context);OWN(context);
    ID3D11DeviceContext_CopyResource(context,(ID3D11Resource *)staging,(ID3D11Resource *)back);
    D3D11_MAPPED_SUBRESOURCE mapped;hr=ID3D11DeviceContext_Map(context,(ID3D11Resource *)staging,0,D3D11_MAP_READ,0,&mapped);
    if(SUCCEEDED(hr)){
        for(UINT y=0;y<height;y++)for(UINT x=0;x<width;x++){
            const uint8_t *pixel=(const uint8_t *)mapped.pData+y*mapped.RowPitch+x*4;
            rgb[(size_t)y*width+x]=((uint32_t)pixel[2]<<16)|((uint32_t)pixel[1]<<8)|pixel[0];
        }
        ID3D11DeviceContext_Unmap(context,(ID3D11Resource *)staging,0);
    }
done:DROP(context);DROP(staging);DROP(back);return failure(s,hr);
}
HRESULT zgpu_test_pixel(State *s, UINT x, UINT y, uint32_t *rgb) {
    if (!s || !s->drawing || x >= s->width || y >= s->height) return E_INVALIDARG;
    HRESULT hr = ID2D1RenderTarget_Flush(RT(s), NULL, NULL);
    if (FAILED(hr)) return failure(s, hr);
    ID3D11Texture2D *back = NULL, *staging = NULL;
    ID3D11DeviceContext *context = NULL;
    hr = IDXGISwapChain1_GetBuffer(s->swapchain, 0, &IID_ID3D11Texture2D, (void **)&back); OWN(back);
    if (FAILED(hr)) goto done;
    D3D11_TEXTURE2D_DESC desc = {0};
    desc.Width=desc.Height=desc.MipLevels=desc.ArraySize=desc.SampleDesc.Count=1;
    desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM; desc.Usage=D3D11_USAGE_STAGING; desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    hr = ID3D11Device_CreateTexture2D(s->d3d, &desc, NULL, &staging); OWN(staging);
    if (FAILED(hr)) goto done;
    ID3D11Device_GetImmediateContext(s->d3d, &context); OWN(context);
    const D3D11_BOX box = {x,y,0,x+1,y+1,1};
    ID3D11DeviceContext_CopySubresourceRegion(context, (ID3D11Resource *)staging, 0,0,0,0,(ID3D11Resource *)back,0,&box);
    D3D11_MAPPED_SUBRESOURCE mapped;
    hr = ID3D11DeviceContext_Map(context,(ID3D11Resource *)staging,0,D3D11_MAP_READ,0,&mapped);
    if (SUCCEEDED(hr)) {
        const unsigned char *pixel = mapped.pData;
        *rgb = ((uint32_t)pixel[2]<<16) | ((uint32_t)pixel[1]<<8) | pixel[0];
        ID3D11DeviceContext_Unmap(context,(ID3D11Resource *)staging,0);
    }
done:
    DROP(context); DROP(staging); DROP(back); return failure(s, hr);
}

HRESULT zgpu_test_text_pixels(State *s, UINT x, UINT y, UINT width, UINT height, uint32_t background, uint32_t *different) {
    if (!s || !s->drawing || !width || !height || x > s->width || y > s->height || width > s->width-x || height > s->height-y) return E_INVALIDARG;
    HRESULT hr = ID2D1RenderTarget_Flush(RT(s), NULL, NULL);
    if (FAILED(hr)) return failure(s, hr);
    ID3D11Texture2D *back = NULL, *staging = NULL;
    ID3D11DeviceContext *context = NULL;
    hr = IDXGISwapChain1_GetBuffer(s->swapchain, 0, &IID_ID3D11Texture2D, (void **)&back); OWN(back);
    if (FAILED(hr)) goto done;
    D3D11_TEXTURE2D_DESC desc = {0};
    desc.Width=width; desc.Height=height; desc.MipLevels=desc.ArraySize=desc.SampleDesc.Count=1;
    desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM; desc.Usage=D3D11_USAGE_STAGING; desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    hr = ID3D11Device_CreateTexture2D(s->d3d, &desc, NULL, &staging); OWN(staging);
    if (FAILED(hr)) goto done;
    ID3D11Device_GetImmediateContext(s->d3d, &context); OWN(context);
    const D3D11_BOX box = {x,y,0,x+width,y+height,1};
    ID3D11DeviceContext_CopySubresourceRegion(context,(ID3D11Resource *)staging,0,0,0,0,(ID3D11Resource *)back,0,&box);
    D3D11_MAPPED_SUBRESOURCE mapped;
    hr = ID3D11DeviceContext_Map(context,(ID3D11Resource *)staging,0,D3D11_MAP_READ,0,&mapped);
    if (SUCCEEDED(hr)) {
        *different = 0;
        for (UINT row=0; row<height; row++) for (UINT col=0; col<width; col++) {
            const unsigned char *pixel = (const unsigned char *)mapped.pData + row*mapped.RowPitch + col*4;
            uint32_t rgb = ((uint32_t)pixel[2]<<16) | ((uint32_t)pixel[1]<<8) | pixel[0];
            if (rgb != background) (*different)++;
        }
        ID3D11DeviceContext_Unmap(context,(ID3D11Resource *)staging,0);
    }
done:
    DROP(context); DROP(staging); DROP(back); return failure(s, hr);
}
