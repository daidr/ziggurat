#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <initguid.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <stdint.h>
#include <stdlib.h>

/* Presents software frames on a window without a redirection bitmap, where
   GDI shows nothing: a composition swap chain of premultiplied BGRA shown by
   DirectComposition, filled from the frame's pixels. The system libraries are
   loaded on first use, so windows that never compose pay nothing. */

/* DirectComposition declares C++ interfaces only; these are the vtable slots
   of IDCompositionDevice, IDCompositionTarget and IDCompositionVisual. */
#define DCOMP_COMMIT 3
#define DCOMP_CREATE_TARGET_FOR_HWND 6
#define DCOMP_CREATE_VISUAL 7
#define DCOMP_TARGET_SET_ROOT 3
#define DCOMP_VISUAL_SET_CONTENT 15
static const GUID iid_dcomposition_device={0xc37ea93a,0xe7aa,0x450d,{0xb1,0x6f,0x97,0x46,0xcb,0x04,0x07,0xf3}};

typedef struct Composed {
    HWND hwnd;
    ID3D11Device *device;
    ID3D11DeviceContext *context;
    IDXGISwapChain1 *swapchain;
    IUnknown *dcomp, *target, *visual;
    UINT width, height;
} Composed;

static void **vtbl(void *object){return *(void ***)object;}
#define RELEASE(p) do { if (p) { IUnknown_Release((IUnknown *)(p)); (p) = NULL; } } while (0)

static void release_all(Composed *s){
    RELEASE(s->visual);RELEASE(s->target);RELEASE(s->dcomp);RELEASE(s->swapchain);
    if(s->context){ID3D11DeviceContext_ClearState(s->context);ID3D11DeviceContext_Flush(s->context);}
    RELEASE(s->context);RELEASE(s->device);
    s->width=s->height=0;
}

static HMODULE system_library(const WCHAR *name){
    HMODULE module=GetModuleHandleW(name);
    return module?module:LoadLibraryExW(name,NULL,LOAD_LIBRARY_SEARCH_SYSTEM32);
}

static HRESULT create_device(Composed *s){
    typedef HRESULT (WINAPI *CreateDevice)(IDXGIAdapter *,D3D_DRIVER_TYPE,HMODULE,UINT,const D3D_FEATURE_LEVEL *,UINT,UINT,ID3D11Device **,D3D_FEATURE_LEVEL *,ID3D11DeviceContext **);
    HMODULE d3d=system_library(L"d3d11.dll");
    CreateDevice create=d3d?(CreateDevice)(void *)GetProcAddress(d3d,"D3D11CreateDevice"):NULL;
    if(!create)return HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
    /* Copying a frame needs no more than any adapter has; WARP covers a
       machine without one. */
    HRESULT hr=create(NULL,D3D_DRIVER_TYPE_HARDWARE,NULL,D3D11_CREATE_DEVICE_BGRA_SUPPORT,NULL,0,D3D11_SDK_VERSION,&s->device,NULL,&s->context);
    if(FAILED(hr))hr=create(NULL,D3D_DRIVER_TYPE_WARP,NULL,D3D11_CREATE_DEVICE_BGRA_SUPPORT,NULL,0,D3D11_SDK_VERSION,&s->device,NULL,&s->context);
    return hr;
}

static HRESULT create_chain(Composed *s, UINT width, UINT height){
    IDXGIDevice *dxgi=NULL;IDXGIAdapter *adapter=NULL;IDXGIFactory2 *factory=NULL;
    HRESULT hr=ID3D11Device_QueryInterface(s->device,&IID_IDXGIDevice,(void **)&dxgi);
    if(SUCCEEDED(hr))hr=IDXGIDevice_GetAdapter(dxgi,&adapter);
    if(SUCCEEDED(hr))hr=IDXGIAdapter_GetParent(adapter,&IID_IDXGIFactory2,(void **)&factory);
    if(SUCCEEDED(hr)){
        DXGI_SWAP_CHAIN_DESC1 desc={0};
        desc.Width=width;desc.Height=height;desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count=1;desc.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT;desc.BufferCount=2;
        desc.Scaling=DXGI_SCALING_STRETCH;desc.SwapEffect=DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;desc.AlphaMode=DXGI_ALPHA_MODE_PREMULTIPLIED;
        hr=IDXGIFactory2_CreateSwapChainForComposition(factory,(IUnknown *)s->device,&desc,NULL,&s->swapchain);
    }
    if(SUCCEEDED(hr)){
        typedef HRESULT (WINAPI *CreateComposition)(IDXGIDevice *,REFIID,void **);
        HMODULE module=system_library(L"dcomp.dll");
        CreateComposition create=module?(CreateComposition)(void *)GetProcAddress(module,"DCompositionCreateDevice"):NULL;
        hr=create?create(dxgi,&iid_dcomposition_device,(void **)&s->dcomp):HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
    }
    if(SUCCEEDED(hr))hr=((HRESULT (STDMETHODCALLTYPE *)(void *,HWND,BOOL,void **))vtbl(s->dcomp)[DCOMP_CREATE_TARGET_FOR_HWND])(s->dcomp,s->hwnd,TRUE,(void **)&s->target);
    if(SUCCEEDED(hr))hr=((HRESULT (STDMETHODCALLTYPE *)(void *,void **))vtbl(s->dcomp)[DCOMP_CREATE_VISUAL])(s->dcomp,(void **)&s->visual);
    if(SUCCEEDED(hr))hr=((HRESULT (STDMETHODCALLTYPE *)(void *,IUnknown *))vtbl(s->visual)[DCOMP_VISUAL_SET_CONTENT])(s->visual,(IUnknown *)s->swapchain);
    if(SUCCEEDED(hr))hr=((HRESULT (STDMETHODCALLTYPE *)(void *,void *))vtbl(s->target)[DCOMP_TARGET_SET_ROOT])(s->target,s->visual);
    if(SUCCEEDED(hr))hr=((HRESULT (STDMETHODCALLTYPE *)(void *))vtbl(s->dcomp)[DCOMP_COMMIT])(s->dcomp);
    RELEASE(factory);RELEASE(adapter);RELEASE(dxgi);
    if(SUCCEEDED(hr)){s->width=width;s->height=height;}
    return hr;
}

Composed *zwc_create(HWND hwnd){
    Composed *s=calloc(1,sizeof(Composed));
    if(s)s->hwnd=hwnd;
    return s;
}

/* pixels: premultiplied BGRA rows of width*4 bytes. A lost device is made
   again by the next frame. */
HRESULT zwc_present(Composed *s, const uint32_t *pixels, UINT width, UINT height){
    if(!s||!pixels||!width||!height)return E_INVALIDARG;
    HRESULT hr=S_OK;
    if(!s->device){hr=create_device(s);if(FAILED(hr)){release_all(s);return hr;}}
    if(!s->swapchain){hr=create_chain(s,width,height);if(FAILED(hr)){release_all(s);return hr;}}
    else if(s->width!=width||s->height!=height){
        hr=IDXGISwapChain1_ResizeBuffers(s->swapchain,2,width,height,DXGI_FORMAT_B8G8R8A8_UNORM,0);
        if(FAILED(hr)){release_all(s);return hr;}
        s->width=width;s->height=height;
    }
    ID3D11Texture2D *buffer=NULL;
    hr=IDXGISwapChain1_GetBuffer(s->swapchain,0,&IID_ID3D11Texture2D,(void **)&buffer);
    if(FAILED(hr)){release_all(s);return hr;}
    ID3D11DeviceContext_UpdateSubresource(s->context,(ID3D11Resource *)buffer,0,NULL,pixels,width*4,0);
    RELEASE(buffer);
    hr=IDXGISwapChain1_Present(s->swapchain,0,0);
    if(FAILED(hr))release_all(s);
    return hr;
}

void zwc_destroy(Composed *s){
    if(!s)return;
    release_all(s);
    free(s);
}
