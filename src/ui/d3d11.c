#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define D2D_USE_C_DEFINITIONS
#include <windows.h>
#include <initguid.h>
#include <d3d10.h>
#include <d3d11.h>
#include <d3d11_1.h>
#include <dxgi1_3.h>
#include <dxgi1_5.h>
#include <d2d1_1.h>
#include <dwrite.h>
#include <dwrite_1.h>
#include <stdlib.h>
#include "pacing.h"
#include <stdint.h>
#include <string.h>
#include <math.h>
static void han_language(WCHAR out[86]);
#include "brushes.h"
#include "image_resource.h"
#include "coverage_resource.h"
#include "gradient_interpolation_native.h"
#include "gaussian_gpu_native.h"
#include "text_symbols_windows.h"
#define ZG_EFFECT_SLOTS 16

/* Native graphics resources only; command storage and rendering policy live in Zig. */
#define GEOMETRY_CAPACITY 32
typedef struct ShapeGeometry {
    ID2D1PathGeometry *path;
    float width,height,radius,stroke;
    uint64_t used;
    /* The frame that last drew it, for the sweep (gpu_sweep.h). */
    uint64_t frame;
} ShapeGeometry;
/* An image, or a frame of video a decoder shares (video, its texture's
   identity, and handle): opened by that identity when drawn. */
typedef struct CachedImage {ID2D1Bitmap *bitmaps[2][ZI_IMAGE_LEVELS];const ZiImageLevel *levels;ZiImageLevel coverage_level;uint32_t count,dynamic,active,is_coverage,video;HANDLE video_handle;} CachedImage;
/* A texture a decoder shares, opened on the renderer's device, and whether
   the frame drawing holds its keyed mutex. */
typedef struct SharedVideo {uint32_t id;ID2D1Bitmap1 *bitmap;IDXGIKeyedMutex *mutex;uint64_t used;int acquired;} SharedVideo;
#define SHARED_VIDEOS 8
typedef struct GpuLayers GpuLayers;
typedef struct GpuDomain GpuDomain;
typedef struct State {
    GpuDomain *domain;
    struct State *domain_previous, *domain_next;
    ID3D11Device *d3d;
    int shares_device;
    ID2D1Factory1 *factory;
    ID2D1Device *device;
    ID2D1DeviceContext *context;
    IDXGISwapChain1 *swapchain;
    IDXGISwapChain2 *swapchain2;
    HANDLE frame_ready;
    /* Uncapped (ZIGGURAT_UNCAPPED): the swap chain's buffers and flags, and
       whether its frames may show torn (DXGI_FEATURE_PRESENT_ALLOW_TEARING),
       which only a swap chain of a window's own does. */
    UINT buffers, swap_flags;
    int tearing;
    /* Uncapped, a live resize presents paced, as without ZIGGURAT_UNCAPPED:
       from the first change of size until settle_ms after the last, frames
       show untorn and one frame waits for the swap chain, not two. Frames
       queued for DWM faster than it composes, while it resizes the window,
       hold back the frame of the next size behind them. */
    int paced;
    ULONGLONG resized_at;
    ID2D1Bitmap1 *target;
    /* The window's kept frame: a frame drawn while keep_plane is set draws
       into it, only where it changed when plane_valid says it holds the
       last frame presented, and copies it to the swap chain, whose back
       buffer holds a frame two before. plane_serial changes whenever it is
       made again; plane_touched, once a frame began drawing into it. */
    ID2D1Bitmap1 *plane;
    UINT plane_width, plane_height;
    FLOAT plane_dpi;
    int keep_plane, plane_drawing, plane_valid, plane_touched, plane_composed;
    SharedVideo videos[SHARED_VIDEOS];
    uint64_t video_clock, video_opens;
    uint64_t plane_serial, plane_partial_frames;
    ID2D1SolidColorBrush *brush;
    IDWriteFactory *text_factory;
    IDWriteTextFormat *format;
    IDWriteInlineObject *ellipsis;
    /* The language of Han characters, which the default locale would draw
       in another language's font: the first of the user's preferred
       languages that writes them, when the locale does not; empty else. */
    WCHAR han[86];
    /* Formats for fonts other than the default, created on first use and
       replaced oldest first. */
    IDWriteTextFormat *variants[8];
    uint32_t variant_keys[8], variant_next;
    /* The system's fonts and the application's, made again when a font is
       registered; NULL while none is. */
    IDWriteFontCollection *font_collection;
    uint64_t font_generation;
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
    /* Frames ended, and the one that last swept the shapes no frame drew
       for a while (gpu_sweep.h). */
    uint64_t frame_serial,swept,sweeps;
    ID2D1Effect *gradient;
    uint64_t gradient_previous_uploads;
    uint32_t gradient_creations,gradient_draws,gradient_restores;
    CachedImage *images,image_candidate;
    uint32_t image_capacity;
    uint32_t image_fault;
    BOOL image_loss_fault;
    uint32_t image_update_loss_mip;
    uint64_t image_restores;
    uint64_t image_creations;
    uint64_t coverage_creations,coverage_restores;
    size_t coverage_scratch_peak;
    ZgInterpolation *interpolation;
    /* Shader effects: the shared vertex shader, the installed pixel
       shaders, their constants and the copy a backdrop shader reads. */
    ID3D11VertexShader *effect_vertex;
    ID3D11PixelShader *effect_pixels[ZG_EFFECT_SLOTS];
    ID3D11Buffer *effect_constants[2];
    ID3D11RasterizerState *effect_raster;
    ID3D11Texture2D *backdrop_copy,*backdrop_output;
    ID3D11ShaderResourceView *backdrop_view;
    ID3D11RenderTargetView *backdrop_target;
    UINT backdrop_width,backdrop_height;
    uint64_t effect_passes;
    /* Composed frames (Paint.transparent) show on the parent window through
       DirectComposition with their premultiplied alpha. */
    int composed;
    void *dcomp, *dcomp_target, *dcomp_visual;
    /* The content's opaque background (0xRRGGBB) while has_background:
       an unscaled swap chain shows it beyond a frame of an older size. */
    int has_background, unscaled;
    UINT background;
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
static void release_shared_device(State *s,BOOL lost);
static void release_videos(State *s);
static void drop_videos(State *s);
static void release_composition(State *s);
static HRESULT failure(State *s,HRESULT hr);
static D2D1_RECT_F rectangle(float x,float y,float width,float height);
static HRESULT end_frame(State *s,int offscreen);
static void clear_frame(State *s);
/* Raster scopes retain their transparent guard through final sampling. */
#include "gpu_layers.h"
#include "gpu_effects.h"
#include "gpu_domain.h"
#include "gpu_sweep.h"
/* Once ZG_SWEEP_EVERY frames went by since the last sweep, however each was
   drawn, the shapes no frame drew in ZG_SWEEP_IDLE frames go. */
static void sweep(State *s){
    s->frame_serial++;
    if(!zg_sweep_due(s->frame_serial,&s->swept))return;
    for(unsigned i=0;i<GEOMETRY_CAPACITY;i++)if(s->shapes[i].path&&zg_sweep_idle(s->frame_serial,s->shapes[i].frame,ZG_SWEEP_IDLE)){DROP(s->shapes[i].path);memset(&s->shapes[i],0,sizeof(s->shapes[i]));}
    s->sweeps++;
}

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
    release_videos(s);
    /* A frame given up after it drew in the plane leaves it neither. */
    if (s->plane_drawing && s->plane_touched) s->plane_valid = 0;
    s->plane_drawing = 0;
    gpu_layer_abort_metadata(s);
    if(s->context&&s->target)s->context->lpVtbl->SetTarget(s->context,(ID2D1Image *)s->target);
}
static void drop_plane(State *s) {
    if (s->plane) s->plane_serial++;
    DROP(s->plane); s->plane_valid = 0;
}
static void release_target(State *s) {
    if (s->context) s->context->lpVtbl->SetTarget(s->context, NULL);
    DROP(s->target);
    drop_plane(s);
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
    gpu_effect_drop_objects(s);
    gpu_layer_drop_objects(s->layers);
    for (unsigned i=0;i<GEOMETRY_CAPACITY;i++) { DROP(s->shapes[i].path); s->shapes[i].used=0; }
    s->gradient_previous_uploads+=gradient_uploads(s->gradient);DROP(s->gradient);
    for (unsigned i=0;i<s->image_capacity;i++)drop_image_objects(&s->images[i]);
    drop_image(&s->image_candidate);
    DROP(s->brush);
    DROP(s->context);
    DROP(s->device);
    if (s->frame_ready) { CloseHandle(s->frame_ready); s->frame_ready=NULL; InterlockedDecrement(&live_resources); }
    DROP(s->swapchain2);
    release_composition(s);
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
    drop_videos(s);
    release_shared_device(s,FALSE);
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
        else {s->device_losses++; release_shared_device(s,TRUE); release_device(s);}
    }
    return hr;
}
/* The windows' renderers share one Direct3D 11 device for each driver: a
   device costs the driver tens of megabytes, which a window each would
   multiply. Each renderer keeps its own Direct2D factory, device and context
   on it, its swap chain and what its frames change; the device goes with
   the last renderer holding it, as each holds a reference. They draw on the
   window thread; the device is multithread protected all the same, so that
   DXGI's calls on a swap chain from another thread are serialized with the
   immediate context's. A renderer that loses the device takes it out of the
   slot, so the next one made makes another; those still holding the old one
   fail their next frame and make their device again on the new one. */
static struct {ID3D11Device *d3d;unsigned users;} shared_devices[2];
static LONG shared_device_creations;
static HRESULT acquire_shared_device(int driver,ID3D11Device **out){
    *out=NULL;
    if(shared_devices[driver].d3d){
        if(SUCCEEDED(ID3D11Device_GetDeviceRemovedReason(shared_devices[driver].d3d))){
            *out=shared_devices[driver].d3d;ID3D11Device_AddRef(*out);shared_devices[driver].users++;return S_OK;
        }
        shared_devices[driver].d3d=NULL;shared_devices[driver].users=0;
    }
    D3D_FEATURE_LEVEL level;
    const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
    HRESULT hr = D3D11CreateDevice(NULL, driver ? D3D_DRIVER_TYPE_WARP : D3D_DRIVER_TYPE_HARDWARE,
        NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        levels, sizeof(levels)/sizeof(levels[0]), D3D11_SDK_VERSION, out, &level, NULL);
    if(FAILED(hr)){if(*out){ID3D11Device_Release(*out);*out=NULL;}return hr;}
    ID3D10Multithread *multithread=NULL;
    if(SUCCEEDED(ID3D11Device_QueryInterface(*out,&IID_ID3D10Multithread,(void **)&multithread))&&multithread){
        ID3D10Multithread_SetMultithreadProtected(multithread,TRUE);ID3D10Multithread_Release(multithread);
    }
    shared_devices[driver].d3d=*out;shared_devices[driver].users=1;
    InterlockedIncrement(&shared_device_creations);
    return S_OK;
}
/* Gives back a renderer's share of the device; the slot forgets a device
   lost, or one no renderer holds any longer. */
static void release_shared_device(State *s,BOOL lost){
    if(s->domain||!s->d3d||!s->shares_device)return;
    s->shares_device=0;
    const int d=s->driver;
    if(shared_devices[d].d3d!=s->d3d)return;
    if(lost||--shared_devices[d].users==0){shared_devices[d].d3d=NULL;shared_devices[d].users=0;}
}
unsigned zgpu_shared_device_users(int driver){return driver==0||driver==1?shared_devices[driver].users:0;}
long zgpu_shared_device_creations(void){return shared_device_creations;}
int zgpu_shares_device(State *a,State *b){return a&&b&&a->d3d&&a->d3d==b->d3d;}

static HRESULT create_device(State *s) {
    IDXGIDevice *dxgi = NULL;
    HRESULT hr;
    if(s->domain){
        if(s->domain->epoch->status!=1)return DXGI_ERROR_DEVICE_REMOVED;
        s->d3d=s->domain->d3d;ID3D11Device_AddRef(s->d3d);OWN(s->d3d);
        s->device=s->domain->device;IUnknown_AddRef((IUnknown *)s->device);OWN(s->device);
        hr=S_OK;
    }else{
    hr = acquire_shared_device(s->driver, &s->d3d);
    OWN(s->d3d);
    if (FAILED(hr)) goto failed;
    s->shares_device = 1;
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
    for(unsigned i=0;i<s->image_capacity;i++)if(s->images[i].count&&!s->images[i].video){hr=create_image_objects(s,&s->images[i],0);if(FAILED(hr))goto failed;if(s->images[i].is_coverage)s->coverage_restores++;else s->image_restores++;}
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
    han_language(s->han);
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

/* DirectComposition declares C++ interfaces only; these are the vtable
   slots of IDCompositionDevice, IDCompositionTarget and IDCompositionVisual
   that a composed swap chain needs. */
#define DCOMP_COMMIT 3
#define DCOMP_CREATE_TARGET_FOR_HWND 6
#define DCOMP_CREATE_VISUAL 7
#define DCOMP_TARGET_SET_ROOT 3
#define DCOMP_VISUAL_SET_CONTENT 15
static const GUID iid_dcomposition_device={0xc37ea93a,0xe7aa,0x450d,{0xb1,0x6f,0x97,0x46,0xcb,0x04,0x07,0xf3}};
static void **dcomp_vtbl(void *object){return *(void ***)object;}
static void release_composition(State *s){
    DROP(s->dcomp_visual);DROP(s->dcomp_target);DROP(s->dcomp);
}
static HRESULT create_composition(State *s, IDXGIDevice *dxgi){
    typedef HRESULT (WINAPI *Create)(IDXGIDevice *,REFIID,void **);
    HMODULE module=GetModuleHandleW(L"dcomp.dll");
    if(!module)module=LoadLibraryExW(L"dcomp.dll",NULL,LOAD_LIBRARY_SEARCH_SYSTEM32);
    Create create=module?(Create)(void *)GetProcAddress(module,"DCompositionCreateDevice"):NULL;
    if(!create)return HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
    HRESULT hr=create(dxgi,&iid_dcomposition_device,&s->dcomp);OWN(s->dcomp);
    if(FAILED(hr))return hr;
    hr=((HRESULT (STDMETHODCALLTYPE *)(void *,HWND,BOOL,void **))dcomp_vtbl(s->dcomp)[DCOMP_CREATE_TARGET_FOR_HWND])(s->dcomp,s->parent,TRUE,&s->dcomp_target);OWN(s->dcomp_target);
    if(FAILED(hr))return hr;
    hr=((HRESULT (STDMETHODCALLTYPE *)(void *,void **))dcomp_vtbl(s->dcomp)[DCOMP_CREATE_VISUAL])(s->dcomp,&s->dcomp_visual);OWN(s->dcomp_visual);
    if(FAILED(hr))return hr;
    hr=((HRESULT (STDMETHODCALLTYPE *)(void *,IUnknown *))dcomp_vtbl(s->dcomp_visual)[DCOMP_VISUAL_SET_CONTENT])(s->dcomp_visual,(IUnknown *)s->swapchain);
    if(FAILED(hr))return hr;
    hr=((HRESULT (STDMETHODCALLTYPE *)(void *,void *))dcomp_vtbl(s->dcomp_target)[DCOMP_TARGET_SET_ROOT])(s->dcomp_target,s->dcomp_visual);
    if(FAILED(hr))return hr;
    return ((HRESULT (STDMETHODCALLTYPE *)(void *))dcomp_vtbl(s->dcomp)[DCOMP_COMMIT])(s->dcomp);
}
static void apply_background(State *s) {
    if (!s->swapchain || s->composed || !s->has_background) return;
    DXGI_RGBA color = { ((s->background >> 16) & 0xff) / 255.0f, ((s->background >> 8) & 0xff) / 255.0f, (s->background & 0xff) / 255.0f, 1.0f };
    IDXGISwapChain1_SetBackgroundColor(s->swapchain, &color);
}
void zgpu_set_background(State *s, int has, UINT rgb) {
    if (!s) return;
    has = has != 0;
    if (s->has_background == has && (!has || s->background == rgb)) return;
    s->has_background = has; s->background = rgb;
    apply_background(s);
}
int zgpu_test_unscaled(State *s) { return s && s->unscaled; }
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
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL; desc.AlphaMode = s->composed ? DXGI_ALPHA_MODE_PREMULTIPLIED : DXGI_ALPHA_MODE_IGNORE;
    desc.Flags=DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;
    /* Uncapped, frames present with sync interval 0 into three buffers, and
       where DXGI allows it, torn rather than at the next composition: the
       next frame starts as soon as the last was presented. */
    s->tearing=0;
    if (zpacing_uncapped()) {
        desc.BufferCount = 3;
        IDXGIFactory5 *factory5 = NULL;
        BOOL allow = FALSE;
        if (!s->composed && SUCCEEDED(IDXGIFactory2_QueryInterface(factory, &IID_IDXGIFactory5, (void **)&factory5)) && factory5) {
            if (SUCCEEDED(IDXGIFactory5_CheckFeatureSupport(factory5, DXGI_FEATURE_PRESENT_ALLOW_TEARING, &allow, sizeof allow)) && allow) {
                desc.Flags |= DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING;
                s->tearing = 1;
            }
            IDXGIFactory5_Release(factory5);
        }
    }
    s->buffers = desc.BufferCount; s->swap_flags = desc.Flags;
    if (s->composed) {
        /* A window without a redirection bitmap shows its material where the
           composed frames are transparent. */
        hr = IDXGIFactory2_CreateSwapChainForComposition(factory, (IUnknown *)s->d3d, &desc, NULL, &s->swapchain);
        OWN(s->swapchain);
        if (FAILED(hr)) goto done;
        hr = create_composition(s, dxgi);
        if (FAILED(hr)) goto done;
    } else {
        /* The parent remains a GDI window. Flip presentation targets only this child.
           Frames show unscaled, the background beyond them, so a surface that
           grew shows that rather than its last frame stretched until the frame
           of its size presents; stretching is the fallback where refused. */
        desc.Scaling = DXGI_SCALING_NONE;
        hr = IDXGIFactory2_CreateSwapChainForHwnd(factory, (IUnknown *)s->d3d, s->surface, &desc, NULL, NULL, &s->swapchain);
        s->unscaled = SUCCEEDED(hr);
        if (FAILED(hr)) {
            desc.Scaling = DXGI_SCALING_STRETCH;
            hr = IDXGIFactory2_CreateSwapChainForHwnd(factory, (IUnknown *)s->d3d, s->surface, &desc, NULL, NULL, &s->swapchain);
        }
        OWN(s->swapchain);
        if (FAILED(hr)) goto done;
        apply_background(s);
    }
    hr=IDXGISwapChain1_QueryInterface(s->swapchain,&IID_IDXGISwapChain2,(void **)&s->swapchain2); OWN(s->swapchain2);
    if (FAILED(hr)) goto done;
    s->paced=0;
    hr=IDXGISwapChain2_SetMaximumFrameLatency(s->swapchain2,zpacing_uncapped()?2:1);
    if (FAILED(hr)) goto done;
    s->frame_ready=IDXGISwapChain2_GetFrameLatencyWaitableObject(s->swapchain2);
    if (!s->frame_ready) {hr=E_FAIL;goto done;}
    InterlockedIncrement(&live_resources);
    s->width = width; s->height = height; IDXGIFactory2_MakeWindowAssociation(factory, s->surface, DXGI_MWA_NO_ALT_ENTER);
done:
    DROP(factory); DROP(adapter); DROP(dxgi);
    if(FAILED(hr)) { if(s->frame_ready){CloseHandle(s->frame_ready);s->frame_ready=NULL;InterlockedDecrement(&live_resources);} DROP(s->swapchain2);release_composition(s);DROP(s->swapchain); }
    return hr;
}

HRESULT zgpu_begin_composed(State *s, HWND hwnd, UINT width, UINT height, FLOAT dpi, int composed) {
    if (!s || s->drawing || s->offscreen) return E_UNEXPECTED;
    if (!hwnd || !IsWindow(hwnd) || !width || !height || !(dpi > 0)) return E_INVALIDARG;
    HRESULT hr = S_OK;
    if (!s->d3d) { hr = create_device(s); if (FAILED(hr)) return hr; }
    composed = composed != 0;
    if (s->parent != hwnd || !s->surface || s->composed != composed) {
        release_target(s);
        if(s->frame_ready){CloseHandle(s->frame_ready);s->frame_ready=NULL;InterlockedDecrement(&live_resources);}
        DROP(s->swapchain2);release_composition(s);DROP(s->swapchain); destroy_surface(s);
        s->composed = composed;
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
        hr = IDXGISwapChain1_ResizeBuffers(s->swapchain, s->buffers ? s->buffers : 2, width, height, DXGI_FORMAT_B8G8R8A8_UNORM, s->swap_flags ? s->swap_flags : DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT);
        if (FAILED(hr)) return failure(s, hr);
        s->width = width; s->height = height; s->resizes++;
        if (zpacing_uncapped()) {
            s->resized_at = GetTickCount64();
            if (!s->paced && s->swapchain2 && SUCCEEDED(IDXGISwapChain2_SetMaximumFrameLatency(s->swapchain2, 1))) s->paced = 1;
        }
    }
    if (s->dpi != dpi) release_target(s);
    if (!s->target) {
        IDXGISurface *surface = NULL;
        hr = IDXGISwapChain1_GetBuffer(s->swapchain, 0, &IID_IDXGISurface, (void **)&surface); OWN(surface);
        if (FAILED(hr)) { DROP(surface); return failure(s, hr); }
        D2D1_BITMAP_PROPERTIES1 properties = {0};
        properties.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
        properties.pixelFormat.alphaMode = s->composed ? D2D1_ALPHA_MODE_PREMULTIPLIED : D2D1_ALPHA_MODE_IGNORE;
        properties.dpiX = properties.dpiY = dpi;
        properties.bitmapOptions = D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW;
        hr = s->context->lpVtbl->CreateBitmapFromDxgiSurface(s->context, surface, &properties, &s->target); OWN(s->target);
        DROP(surface);
        if (FAILED(hr)) return failure(s, hr);
        s->target_creations++;
    }
    const int use_plane = s->keep_plane && !s->layers;
    if (s->plane && (!use_plane || s->plane_width != width || s->plane_height != height || s->plane_dpi != dpi || s->plane_composed != composed)) drop_plane(s);
    if (use_plane && !s->plane) {
        D2D1_BITMAP_PROPERTIES1 properties = {0};
        properties.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
        properties.pixelFormat.alphaMode = composed ? D2D1_ALPHA_MODE_PREMULTIPLIED : D2D1_ALPHA_MODE_IGNORE;
        properties.dpiX = properties.dpiY = dpi;
        properties.bitmapOptions = D2D1_BITMAP_OPTIONS_TARGET;
        const D2D1_SIZE_U size = {width, height};
        hr = s->context->lpVtbl->CreateBitmap(s->context, size, NULL, 0, &properties, &s->plane); OWN(s->plane);
        if (FAILED(hr)) return failure(s, hr);
        s->plane_width = width; s->plane_height = height; s->plane_dpi = dpi; s->plane_composed = composed;
        s->plane_valid = 0; s->plane_serial++;
    }
    s->plane_drawing = use_plane; s->plane_touched = 0;
    s->context->lpVtbl->SetTarget(s->context, (struct ID2D1Image *)(use_plane ? s->plane : s->target));
    if(s->layers)gpu_layer_begin(s);
    else ID2D1RenderTarget_SetTextAntialiasMode(RT(s),D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE);
    ID2D1RenderTarget_SetDpi(RT(s), dpi, dpi);
    s->dpi = dpi; s->clips = 0;
    ID2D1RenderTarget_BeginDraw(RT(s)); s->drawing = TRUE;
    /* The kept plane is cleared by the frame drawn whole (zgpu_plane_whole)
       and keeps its pixels for one drawn in part (zgpu_plane_part). */
    if (!use_plane) clear_frame(s);
    return S_OK;
}
static void clear_frame(State *s) {
    const D2D1_COLOR_F background = {1,1,1,1}, clear = {0,0,0,0};
    ID2D1RenderTarget_Clear(RT(s), s->composed ? &clear : &background);
}
/* Whether the frame drawing keeps the last one: it may draw only what
   changed. */
int zgpu_plane_kept(State *s, uint64_t *generation) {
    *generation = s ? s->plane_serial : 0;
    return s && s->drawing && s->plane_drawing && s->plane_valid;
}
void zgpu_set_keep_plane(State *s, int keep) { if (s) s->keep_plane = keep != 0; }
/* The frame is drawn whole: clear the plane first. */
void zgpu_plane_whole(State *s) {
    if (!s || !s->drawing) return;
    s->plane_touched = 1;
    clear_frame(s);
}
/* The frame draws only where it changed, over the last one. */
void zgpu_plane_part(State *s) {
    if (!s || !s->drawing) return;
    s->plane_touched = 1;
    s->plane_partial_frames++;
}
/* Clears a transparent plane within the clip pushed around a box of it. */
void zgpu_plane_clear_box(State *s) {
    if (!s || !s->drawing) return;
    const D2D1_COLOR_F clear = {0,0,0,0};
    ID2D1RenderTarget_Clear(RT(s), &clear);
}
uint64_t zgpu_plane_partial_frames(State *s) { return s ? s->plane_partial_frames : 0; }
/* Shows the plane drawn in the swap chain's back buffer. */
static HRESULT plane_copy_window(State *s) {
    s->context->lpVtbl->SetTarget(s->context, (ID2D1Image *)s->target);
    ID2D1RenderTarget_BeginDraw(RT(s));
    const D2D1_MATRIX_3X2_F identity = {1,0,0,1,0,0};
    ID2D1RenderTarget_SetTransform(RT(s), &identity);
    const D2D1_COLOR_F clear = {0,0,0,0};
    ID2D1RenderTarget_Clear(RT(s), &clear);
    ID2D1RenderTarget_DrawBitmap(RT(s), (ID2D1Bitmap *)s->plane, NULL, 1, D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR, NULL);
    return ID2D1RenderTarget_EndDraw(RT(s), NULL, NULL);
}
HRESULT zgpu_begin(State *s, HWND hwnd, UINT width, UINT height, FLOAT dpi) {return zgpu_begin_composed(s,hwnd,width,height,dpi,0);}

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
        if(entry->path&&entry->width==w&&entry->height==h&&entry->radius==r&&entry->stroke==stroke) {entry->used=now;entry->frame=s->frame_serial;*out=entry->path;return S_OK;}
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
    s->shapes[victim]=(ShapeGeometry){path,w,h,r,stroke,now,s->frame_serial};path=NULL;
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
/* Whether a language writes Han characters: Chinese, with its languages of
   other codes, Japanese and Korean (ziggurat_text_layout's han.writesHan). */
static int writes_han(const WCHAR *lang){
    static const char *names[]={"zh","ja","ko","yue","cmn","wuu","hak","nan","gan","hsn","lzh","cjy","cpx","czh","czo","mnp","cdo"};
    uint32_t end=0;while(lang[end]&&lang[end]!='-'&&lang[end]!='_')end++;
    for(uint32_t i=0;i<sizeof names/sizeof names[0];i++){
        const char *name=names[i];uint32_t k=0;
        while(k<end&&name[k]&&(lang[k]|0x20)==name[k])k++;
        if(k==end&&!name[k])return 1;
    }
    return 0;
}
/* A Han character, or a mark of punctuation or a full-width form that the
   languages writing Han draw apart (han.isCjk). */
static int is_han(uint32_t r){
    return (r>=0x3000&&r<=0x303f)||(r>=0xff00&&r<=0xffef)||(r>=0x2e80&&r<=0x2fdf)||(r>=0x31c0&&r<=0x31ef)||(r>=0x3400&&r<=0x4dbf)||(r>=0x4e00&&r<=0x9fff)||(r>=0xf900&&r<=0xfaff)||r==0x16fe2||r==0x16fe3||r==0x16ff0||r==0x16ff1||(r>=0x20000&&r<=0x3134f);
}
static uint32_t scalar_at(const WCHAR *text,uint32_t len,uint32_t i,uint32_t *units){
    *units=1;
    if(text[i]>=0xd800&&text[i]<0xdc00&&i+1<len&&text[i+1]>=0xdc00&&text[i+1]<0xe000){*units=2;return 0x10000+(((uint32_t)text[i]-0xd800)<<10)+((uint32_t)text[i+1]-0xdc00);}
    return text[i];
}
static int has_han(const WCHAR *text,uint32_t len){
    for(uint32_t i=0;i<len;){uint32_t k=1;if(is_han(scalar_at(text,len,i,&k)))return 1;i+=k;}
    return 0;
}
/* The first of the user's preferred languages that writes Han characters,
   when the locale of their regional formats, which text formats without a
   locale fall back by, does not (han.userLanguage); empty else. */
static void han_language(WCHAR out[86]){
    out[0]=0;
    WCHAR locale[LOCALE_NAME_MAX_LENGTH];
    if(GetUserDefaultLocaleName(locale,LOCALE_NAME_MAX_LENGTH)>0&&writes_han(locale))return;
    ULONG count=0,size=0;
    if(!GetUserPreferredUILanguages(MUI_LANGUAGE_NAME,&count,NULL,&size)||!size||size>4096)return;
    WCHAR *list=HeapAlloc(GetProcessHeap(),0,size*sizeof(WCHAR));if(!list)return;
    if(GetUserPreferredUILanguages(MUI_LANGUAGE_NAME,&count,list,&size)){
        for(WCHAR *lang=list;*lang;lang+=wcslen(lang)+1)if(writes_han(lang)){size_t n=wcslen(lang);if(n<86){memcpy(out,lang,(n+1)*sizeof(WCHAR));}break;}
    }
    HeapFree(GetProcessHeap(),0,list);
}
static void release_variants(State *s){for(uint32_t i=0;i<8;i++){DROP(s->variants[i]);s->variant_keys[i]=0;}s->variant_next=0;}
IDWriteFontCollection *zfont_collection(IDWriteFactory *factory,uint64_t *seen,IDWriteFontCollection **cache);
/* The text format for a font key (see commands.FontKey); the default format
   when the key is the default or a variant cannot be made. */
static IDWriteTextFormat *variant_format(State *s,uint32_t key,float size,uint16_t weight,int italic,int monospace,const WCHAR *family){
    if(key==0)return s->format;
    /* A registered font changes what a family name resolves to. */
    uint64_t seen=s->font_generation;
    IDWriteFontCollection *collection=zfont_collection(s->text_factory,&s->font_generation,&s->font_collection);
    if(seen!=s->font_generation)release_variants(s);
    for(uint32_t i=0;i<8;i++)if(s->variants[i]&&s->variant_keys[i]==key)return s->variants[i];
    IDWriteTextFormat *format=NULL;
    HRESULT hr=IDWriteFactory_CreateTextFormat(s->text_factory,family?family:monospace?L"Consolas":L"Segoe UI",collection,(DWRITE_FONT_WEIGHT)weight,
        italic?DWRITE_FONT_STYLE_ITALIC:DWRITE_FONT_STYLE_NORMAL,DWRITE_FONT_STRETCH_NORMAL,size,L"",&format);
    if(FAILED(hr)||!format)return s->format;
    OWN(format);
    const DWRITE_TRIMMING trimming={DWRITE_TRIMMING_GRANULARITY_CHARACTER,0,0};
    if(FAILED(IDWriteTextFormat_SetParagraphAlignment(format,DWRITE_PARAGRAPH_ALIGNMENT_CENTER))||FAILED(IDWriteTextFormat_SetWordWrapping(format,DWRITE_WORD_WRAPPING_NO_WRAP))||
       FAILED(IDWriteTextFormat_SetTrimming(format,&trimming,s->ellipsis))){DROP(format);return s->format;}
    uint32_t slot=s->variant_next;s->variant_next=(slot+1)%8;
    DROP(s->variants[slot]);s->variants[slot]=format;s->variant_keys[slot]=key;
    return format;
}
void zgpu_text(State *s, float x, float y, float width, float height, uint32_t rgb, const WCHAR *text, uint32_t len, uint32_t key, float size, uint16_t weight, int italic, int monospace, const WCHAR *family, float spacing) {
    const D2D1_RECT_F r = rectangle(x,y,width,height);
    brush_color(s, rgb);
    IDWriteTextFormat *format=variant_format(s,key,size,weight,italic,monospace,family);
    /* Han characters in the locale, when it does not write them, take the
       user's language for them: DirectWrite's fallback for English draws
       Chinese in a Japanese font where it has the characters and in a
       Traditional Chinese one where it lacks them. Letter spacing goes
       after each character (IDWriteTextLayout1's trailing spacing). */
    const int han=s->han[0]&&has_han(text,len),symbols=zsym_any(text,len);
    if(han||symbols||(spacing!=0&&isfinite(spacing))){
        IDWriteTextLayout *layout=NULL;
        if(SUCCEEDED(IDWriteFactory_CreateTextLayout(s->text_factory,text,len,format,r.right-r.left,r.bottom-r.top,&layout))&&layout){
            /* Symbols presented as text draw in the text's color, as the
               layouts that measured them (text_symbols_windows.h). */
            if(symbols)(void)zsym_apply(s->text_factory,key?s->font_collection:NULL,layout,text,len,family?family:monospace?L"Consolas":L"Segoe UI",key?(DWRITE_FONT_WEIGHT)weight:DWRITE_FONT_WEIGHT_NORMAL,key&&italic?DWRITE_FONT_STYLE_ITALIC:DWRITE_FONT_STYLE_NORMAL);
            for(uint32_t i=0;han&&i<len;){
                uint32_t n=0;while(i+n<len){uint32_t k=1,cp=scalar_at(text,len,i+n,&k);if(!is_han(cp))break;n+=k;}
                if(n){DWRITE_TEXT_RANGE range={i,n};IDWriteTextLayout_SetLocaleName(layout,s->han,range);i+=n;continue;}
                uint32_t k=1;(void)scalar_at(text,len,i,&k);i+=k;
            }
            if(spacing!=0){
                IDWriteTextLayout1 *spaced=NULL;
                if(SUCCEEDED(IDWriteTextLayout_QueryInterface(layout,&IID_IDWriteTextLayout1,(void **)&spaced))&&spaced){
                    DWRITE_TEXT_RANGE all={0,len};IDWriteTextLayout1_SetCharacterSpacing(spaced,0,spacing,0,all);IDWriteTextLayout1_Release(spaced);
                }
            }
            D2D1_POINT_2F origin={r.left,r.top};
            ID2D1RenderTarget_DrawTextLayout(RT(s),origin,layout,(ID2D1Brush *)s->brush,D2D1_DRAW_TEXT_OPTIONS_CLIP|D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
            IDWriteTextLayout_Release(layout);
            return;
        }
        if(layout)IDWriteTextLayout_Release(layout);
    }
    /* Emoji draw in their own colors. */
    ID2D1RenderTarget_DrawText(RT(s), text, len, format, &r, (ID2D1Brush *)s->brush, D2D1_DRAW_TEXT_OPTIONS_CLIP|D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT, DWRITE_MEASURING_MODE_NATURAL);
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
    /* A frame of video shared before: another kind of image, uploaded anew. */
    if(!s->drawing&&slot<s->image_capacity&&s->images[slot].video)return S_FALSE;
    if(s->drawing||slot>=s->image_capacity||!s->images[slot].dynamic||s->images[slot].count!=count)return E_INVALIDARG;
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
/* Grow the slot table; coverage entries point at their own level, so moved
   entries are pointed at it again. */
HRESULT zgpu_reserve_images(State *s,uint32_t capacity){
    if(s->drawing)return E_INVALIDARG;
    if(capacity<=s->image_capacity)return S_OK;
    CachedImage *images=realloc(s->images,(size_t)capacity*sizeof(*images));if(!images)return E_OUTOFMEMORY;
    memset(images+s->image_capacity,0,(size_t)(capacity-s->image_capacity)*sizeof(*images));
    for(uint32_t i=0;i<s->image_capacity;i++)if(images[i].is_coverage)images[i].levels=&images[i].coverage_level;
    s->images=images;s->image_capacity=capacity;return S_OK;
}
void zgpu_commit_image(State *s,uint32_t slot){drop_image(&s->images[slot]);s->images[slot]=s->image_candidate;if(s->images[slot].is_coverage)s->images[slot].levels=&s->images[slot].coverage_level;memset(&s->image_candidate,0,sizeof(s->image_candidate));}
void zgpu_release_image(State *s,uint32_t slot){if(slot<s->image_capacity)drop_image(&s->images[slot]);}
void zgpu_image_fault(State *s,uint32_t mip){s->image_fault=mip;}
void zgpu_image_loss_fault(State *s){s->image_loss_fault=TRUE;}
void zgpu_image_update_loss_at(State *s,uint32_t mip){s->image_update_loss_mip=mip;}
static void drop_video(SharedVideo *v){
    if(v->acquired){IDXGIKeyedMutex_ReleaseSync(v->mutex,0);v->acquired=0;}
    DROP(v->bitmap);DROP(v->mutex);v->id=0;
}
static void drop_videos(State *s){for(unsigned i=0;i<SHARED_VIDEOS;i++)drop_video(&s->videos[i]);}
/* After the frame's draws are issued: the decoder may write them again. */
static void release_videos(State *s){
    for(unsigned i=0;i<SHARED_VIDEOS;i++)if(s->videos[i].acquired){IDXGIKeyedMutex_ReleaseSync(s->videos[i].mutex,0);s->videos[i].acquired=0;}
}
/* The decoder's texture `id`, opened on this device once by its handle. */
static SharedVideo *open_video(State *s,uint32_t id,HANDLE handle){
    SharedVideo *slot=NULL;
    for(unsigned i=0;i<SHARED_VIDEOS;i++){
        SharedVideo *v=&s->videos[i];
        if(v->id==id&&v->bitmap){v->used=++s->video_clock;return v;}
        if(v->acquired)continue;
        if(!slot||!v->id||(slot->id&&v->used<slot->used))slot=v;
    }
    if(!slot||!handle)return NULL;
    drop_video(slot);
    ID3D11Device1 *device1=NULL;ID3D11Texture2D *texture=NULL;IDXGISurface *surface=NULL;
    HRESULT hr=ID3D11Device_QueryInterface(s->d3d,&IID_ID3D11Device1,(void **)&device1);
    if(SUCCEEDED(hr))hr=ID3D11Device1_OpenSharedResource1(device1,handle,&IID_ID3D11Texture2D,(void **)&texture);
    if(SUCCEEDED(hr))hr=ID3D11Texture2D_QueryInterface(texture,&IID_IDXGIKeyedMutex,(void **)&slot->mutex);OWN(slot->mutex);
    if(SUCCEEDED(hr))hr=ID3D11Texture2D_QueryInterface(texture,&IID_IDXGISurface,(void **)&surface);
    if(SUCCEEDED(hr)){
        D2D1_BITMAP_PROPERTIES1 properties={0};
        properties.pixelFormat.format=DXGI_FORMAT_B8G8R8A8_UNORM;properties.pixelFormat.alphaMode=D2D1_ALPHA_MODE_IGNORE;
        properties.dpiX=properties.dpiY=96;
        hr=s->context->lpVtbl->CreateBitmapFromDxgiSurface(s->context,surface,&properties,&slot->bitmap);OWN(slot->bitmap);
    }
    if(surface)IDXGISurface_Release(surface);
    if(texture)ID3D11Texture2D_Release(texture);
    if(device1)ID3D11Device1_Release(device1);
    if(FAILED(hr)){drop_video(slot);return NULL;}
    slot->id=id;slot->used=++s->video_clock;s->video_opens++;
    return slot;
}
int zgpu_takes_video(const ZiVideoPicture *v){return v->native&&v->native_id?1:0;}
HRESULT zgpu_prepare_video(State *s,const ZiVideoPicture *v){
    if(s->drawing||s->image_candidate.count||!zgpu_takes_video(v))return E_INVALIDARG;
    HRESULT hr=S_OK;if(!s->context){hr=create_device(s);if(FAILED(hr))return hr;}
    CachedImage candidate={0};candidate.count=1;candidate.dynamic=1;candidate.video=v->native_id;candidate.video_handle=v->native;
    s->image_candidate=candidate;return S_OK;
}
/* 0 when the slot shows the picture now, 1 when it is another kind of
   image, to upload anew. */
int zgpu_update_video(State *s,uint32_t slot,const ZiVideoPicture *v){
    if(s->drawing||slot>=s->image_capacity||!s->images[slot].video||!zgpu_takes_video(v))return 1;
    s->images[slot].video=v->native_id;s->images[slot].video_handle=v->native;return 0;
}
uint64_t zgpu_video_opens(State *s){return s?s->video_opens:0;}
static HRESULT draw_video(State *s,const CachedImage *image,const ZiImagePlan *plan){
    SharedVideo *v=open_video(s,image->video,image->video_handle);
    /* A picture that cannot be opened, or that the decoder holds past the
       wait, leaves its place empty this frame. */
    if(!v)return S_OK;
    if(!v->acquired){
        if(IDXGIKeyedMutex_AcquireSync(v->mutex,0,100)!=S_OK)return S_OK;
        v->acquired=1;
    }
    const D2D1_RECT_F destination=rectangle(plan->destination.x,plan->destination.y,plan->destination.width,plan->destination.height),source=rectangle(plan->source.x,plan->source.y,plan->source.width,plan->source.height);
    ID2D1RenderTarget_DrawBitmap(RT(s),(ID2D1Bitmap *)v->bitmap,&destination,plan->opacity,plan->sampling?D2D1_BITMAP_INTERPOLATION_MODE_LINEAR:D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR,&source);
    return S_OK;
}
HRESULT zgpu_image(State *s,uint32_t slot,const ZiImagePlan *plan){
    if(s->drawing&&slot<s->image_capacity&&s->images[slot].video&&plan->level==0)return draw_video(s,&s->images[slot],plan);
    if(!s->drawing||slot>=s->image_capacity||plan->level>=s->images[slot].count||!s->images[slot].bitmaps[s->images[slot].active][plan->level])return E_INVALIDARG;
    const D2D1_RECT_F destination=rectangle(plan->destination.x,plan->destination.y,plan->destination.width,plan->destination.height),source=rectangle(plan->source.x,plan->source.y,plan->source.width,plan->source.height);
    ID2D1RenderTarget_DrawBitmap(RT(s),s->images[slot].bitmaps[s->images[slot].active][plan->level],&destination,plan->opacity,plan->sampling?D2D1_BITMAP_INTERPOLATION_MODE_LINEAR:D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR,&source);return S_OK;
}
static uint32_t raster_objects(State *s,int coverage){uint32_t n=0;for(unsigned i=0;i<s->image_capacity;i++)if(s->images[i].is_coverage==(uint32_t)coverage)for(unsigned bank=0;bank<2;bank++)for(unsigned j=0;j<s->images[i].count;j++)if(s->images[i].bitmaps[bank][j])n++;return n;}
void zgpu_image_stats(State *s,uint64_t *restores,uint32_t *objects,uint64_t *creations){*restores=s->image_restores;*creations=s->image_creations;*objects=raster_objects(s,0);}
void zgpu_coverage_stats(State *s,uint64_t *restores,uint32_t *objects,uint64_t *creations){*restores=s->coverage_restores;*creations=s->coverage_creations;*objects=raster_objects(s,1);}
size_t zgpu_coverage_scratch_peak(State *s){return s->coverage_scratch_peak;}
HRESULT zgpu_coverage(State *s,uint32_t slot,float x,float y,float scale,uint32_t rgba){
    if(!s->drawing||slot>=s->image_capacity||!s->images[slot].is_coverage||!s->images[slot].bitmaps[0][0])return E_INVALIDARG;
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
    const D2D1_POINT_2F origin={x,y};ID2D1RenderTarget_DrawTextLayout(RT(s),origin,layout,(ID2D1Brush *)s->brush,D2D1_DRAW_TEXT_OPTIONS_NO_SNAP|D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
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

/* The swap chain settles once its size held settle_ms: frames present
   uncapped again, two of them waiting for it. */
enum { settle_ms = 500 };
static void settle_pacing(State *s) {
    if (!s->paced || GetTickCount64() - s->resized_at < settle_ms) return;
    if (s->swapchain2 && SUCCEEDED(IDXGISwapChain2_SetMaximumFrameLatency(s->swapchain2, 2))) s->paced = 0;
}
int zgpu_paced(State *s) { return s ? s->paced : 0; }

static HRESULT end_frame(State *s,int offscreen) {
    if (!s || !s->drawing || s->offscreen!=offscreen) return E_UNEXPECTED;
    if(s->layers&&s->layers->depth){finish_draw(s);return E_UNEXPECTED;}
    while (s->clips) { ID2D1RenderTarget_PopAxisAlignedClip(RT(s)); s->clips--; }
    HRESULT hr = ID2D1RenderTarget_EndDraw(RT(s), NULL, NULL); s->drawing = FALSE;
    release_videos(s);
    sweep(s);
    const int from_plane = s->plane_drawing; s->plane_drawing = 0;
    /* Until it is presented, the plane holds a frame the tracker did not
       see drawn. */
    if (from_plane) s->plane_valid = 0;
    if(s->layers||from_plane)s->context->lpVtbl->SetTarget(s->context,(ID2D1Image *)s->target);
    if (FAILED(hr)) {gpu_layer_abort_metadata(s);return failure(s, hr);}
    if (s->fault == 1) { s->fault = 0;gpu_layer_abort_metadata(s);return failure(s, DXGI_ERROR_DEVICE_REMOVED); }
    if(offscreen)return S_OK;
    if (s->fault == 3) { s->fault=0;s->busy_presents++;gpu_layer_abort_metadata(s);return DXGI_ERROR_WAS_STILL_DRAWING; }
    if(s->layers){hr=gpu_layer_copy_window(s);if(FAILED(hr)){gpu_layer_abort_metadata(s);return failure(s,hr);}}
    if(from_plane){hr=plane_copy_window(s);if(FAILED(hr))return failure(s,hr);}
    BOOL was_visible=(GetWindowLongW(s->surface,GWL_STYLE)&WS_VISIBLE)!=0;
    if (!was_visible) ShowWindow(s->surface, SW_SHOWNOACTIVATE);
    hr = IDXGISwapChain1_Present(s->swapchain, 0, DXGI_PRESENT_DO_NOT_WAIT | (s->tearing && !s->paced ? DXGI_PRESENT_ALLOW_TEARING : 0));
    settle_pacing(s);
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
    if(from_plane)s->plane_valid=1;
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
    for(unsigned i=0;i<s->image_capacity;i++)drop_image(&s->images[i]);
    free(s->images);s->images=NULL;s->image_capacity=0;
    zgpu_interpolation_dispose(zgpu_interpolation_take(s));
    if(s->domain){
        if(s->domain_previous)s->domain_previous->domain_next=s->domain_next;else s->domain->renderers=s->domain_next;
        if(s->domain_next)s->domain_next->domain_previous=s->domain_previous;
        s->domain=NULL;
    }
    zgpu_layer_release(s);
    destroy_surface(s);
    release_variants(s);
    if(s->font_collection){IDWriteFontCollection_Release(s->font_collection);s->font_collection=NULL;}
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

/* The texture the frame drawing draws in: the kept plane, or the swap
   chain's back buffer. */
static HRESULT frame_texture(State *s, ID3D11Texture2D **out) {
    *out = NULL;
    if (!s->plane_drawing || !s->plane) return IDXGISwapChain1_GetBuffer(s->swapchain, 0, &IID_ID3D11Texture2D, (void **)out);
    IDXGISurface *surface = NULL;
    HRESULT hr = ID2D1Bitmap1_GetSurface(s->plane, &surface);
    if (SUCCEEDED(hr)) hr = IUnknown_QueryInterface((IUnknown *)surface, &IID_ID3D11Texture2D, (void **)out);
    if (surface) IDXGISurface_Release(surface);
    return hr;
}
/* Explicit synchronous readback for hidden integration tests only. */
HRESULT zgpu_test_pixels(State *s,UINT width,UINT height,uint32_t *rgb){
    if(!s||!s->drawing||width!=s->width||height!=s->height||!rgb)return E_INVALIDARG;
    HRESULT hr=ID2D1RenderTarget_Flush(RT(s),NULL,NULL);if(FAILED(hr))return failure(s,hr);
    ID3D11Texture2D *back=NULL,*staging=NULL;ID3D11DeviceContext *context=NULL;
    hr=frame_texture(s,&back);OWN(back);if(FAILED(hr))goto done;
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
/* The kept plane's pixel, between frames; tests only. */
HRESULT zgpu_test_plane_pixel(State *s, UINT x, UINT y, uint32_t *rgb) {
    if (!s || s->drawing || !s->plane || x >= s->plane_width || y >= s->plane_height) return E_INVALIDARG;
    s->plane_drawing = 1;
    ID3D11Texture2D *plane = NULL, *staging = NULL;
    ID3D11DeviceContext *context = NULL;
    HRESULT hr = frame_texture(s, &plane); OWN(plane);
    s->plane_drawing = 0;
    if (FAILED(hr)) goto done;
    D3D11_TEXTURE2D_DESC desc = {0};
    desc.Width=desc.Height=desc.MipLevels=desc.ArraySize=desc.SampleDesc.Count=1;
    desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM; desc.Usage=D3D11_USAGE_STAGING; desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    hr = ID3D11Device_CreateTexture2D(s->d3d, &desc, NULL, &staging); OWN(staging);
    if (FAILED(hr)) goto done;
    ID3D11Device_GetImmediateContext(s->d3d, &context); OWN(context);
    const D3D11_BOX box = {x,y,0,x+1,y+1,1};
    ID3D11DeviceContext_CopySubresourceRegion(context, (ID3D11Resource *)staging, 0,0,0,0,(ID3D11Resource *)plane,0,&box);
    D3D11_MAPPED_SUBRESOURCE mapped;
    hr = ID3D11DeviceContext_Map(context,(ID3D11Resource *)staging,0,D3D11_MAP_READ,0,&mapped);
    if (SUCCEEDED(hr)) {
        const unsigned char *pixel = mapped.pData;
        *rgb = ((uint32_t)pixel[2]<<16) | ((uint32_t)pixel[1]<<8) | pixel[0];
        ID3D11DeviceContext_Unmap(context,(ID3D11Resource *)staging,0);
    }
done:
    DROP(context); DROP(staging); DROP(plane); return hr;
}
HRESULT zgpu_test_pixel(State *s, UINT x, UINT y, uint32_t *rgb) {
    if (!s || !s->drawing || x >= s->width || y >= s->height) return E_INVALIDARG;
    HRESULT hr = ID2D1RenderTarget_Flush(RT(s), NULL, NULL);
    if (FAILED(hr)) return failure(s, hr);
    ID3D11Texture2D *back = NULL, *staging = NULL;
    ID3D11DeviceContext *context = NULL;
    hr = frame_texture(s, &back); OWN(back);
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
    hr = frame_texture(s, &back); OWN(back);
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
