#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define D2D_USE_C_DEFINITIONS
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <d2d1_1.h>
#include <stdint.h>
#include <string.h>
#include "gaussian_gpu_native.h"
#include "shaders/gaussian_shader.h"
#define OWN(p) do{if(p)zgpu_gaussian_account(1);}while(0)
#define DROP(p) do{if(p){IUnknown_Release((IUnknown *)(p));(p)=NULL;zgpu_gaussian_account(-1);}}while(0)
typedef struct GaussianConstants {uint32_t width,height,radius,vertical,weights[260];} GaussianConstants;
_Static_assert(sizeof(GaussianConstants)==1056,"Gaussian constant packing");
typedef struct GaussianTarget {ID3D11Texture2D *texture;ID3D11ShaderResourceView *source;ID3D11RenderTargetView *destination;ID2D1Bitmap1 *bitmap;} GaussianTarget;
typedef struct Program {
    ZgGaussianGpu bridge;
    ID3D11Device *device;
    ID3D11DeviceContext *context;
    ID3D11VertexShader *vertex;
    ID3D11PixelShader *pixel;
    ID3D11Buffer *constants;
    ID3D11RasterizerState *raster;
    GaussianTarget targets[5];
    uint32_t capacity,pool_width,pool_height;
} Program;
static void target_drop(GaussianTarget *target){DROP(target->bitmap);DROP(target->source);DROP(target->destination);DROP(target->texture);}
static void program_lose(ZgGaussianGpu *bridge){
    Program *p=(Program *)bridge;bridge->ready=0;
    for(unsigned i=0;i<5;i++)target_drop(&p->targets[i]);
    DROP(p->vertex);DROP(p->pixel);DROP(p->constants);DROP(p->raster);DROP(p->context);DROP(p->device);bridge->objects=0;
}
static void program_destroy(ZgGaussianGpu *bridge){program_lose(bridge);HeapFree(GetProcessHeap(),0,bridge);zgpu_gaussian_account(-1);}
static ID2D1Bitmap1 *program_bitmap(ZgGaussianGpu *bridge,uint32_t slot){Program *p=(Program *)bridge;return bridge->ready&&slot<p->capacity?p->targets[slot].bitmap:NULL;}
static HRESULT target_create(Program *p,GaussianTarget *target,ID2D1DeviceContext *d2d,int bitmap){
    D3D11_TEXTURE2D_DESC desc={0};desc.Width=p->pool_width;desc.Height=p->pool_height;desc.MipLevels=desc.ArraySize=desc.SampleDesc.Count=1;desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.Usage=D3D11_USAGE_DEFAULT;desc.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_RENDER_TARGET;
    HRESULT hr=ID3D11Device_CreateTexture2D(p->device,&desc,NULL,&target->texture);OWN(target->texture);if(FAILED(hr))return hr;
    hr=ID3D11Device_CreateShaderResourceView(p->device,(ID3D11Resource *)target->texture,NULL,&target->source);OWN(target->source);if(FAILED(hr))return hr;
    hr=ID3D11Device_CreateRenderTargetView(p->device,(ID3D11Resource *)target->texture,NULL,&target->destination);OWN(target->destination);if(FAILED(hr))return hr;
    if(bitmap){
        IDXGISurface *surface=NULL;hr=IUnknown_QueryInterface((IUnknown *)target->texture,&IID_IDXGISurface,(void **)&surface);OWN(surface);if(FAILED(hr))return hr;
        const D2D1_BITMAP_PROPERTIES1 properties={.pixelFormat={DXGI_FORMAT_B8G8R8A8_UNORM,D2D1_ALPHA_MODE_PREMULTIPLIED},.dpiX=96*p->bridge.capacity.scale,.dpiY=96*p->bridge.capacity.scale,.bitmapOptions=D2D1_BITMAP_OPTIONS_TARGET};
        hr=d2d->lpVtbl->CreateBitmapFromDxgiSurface(d2d,surface,&properties,&target->bitmap);OWN(target->bitmap);DROP(surface);if(FAILED(hr))return hr;
    }
    return S_OK;
}
static HRESULT program_filter(ZgGaussianGpu *bridge,uint32_t slot,const ZgGaussianCapture *capture,const ZgGaussianKernel *kernel){
    Program *p=(Program *)bridge;if(!bridge->ready||slot>=p->capacity||!zg_filter_check(&bridge->capacity,capture)||capture->radius!=kernel->radius)return ZG_E_GAUSSIAN_PRECISION;
    GaussianConstants constants={.width=capture->width+2*capture->radius,.height=capture->height+2*capture->radius,.radius=capture->radius};memcpy(constants.weights,kernel->weights,sizeof(kernel->weights));
    ID3D11DeviceContext_ClearState(p->context);
    const D3D11_VIEWPORT viewport={0,0,(float)constants.width,(float)constants.height,0,1};
    ID3D11DeviceContext_RSSetViewports(p->context,1,&viewport);ID3D11DeviceContext_RSSetState(p->context,p->raster);
    ID3D11DeviceContext_IASetPrimitiveTopology(p->context,D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(p->context,p->vertex,NULL,0);ID3D11DeviceContext_PSSetShader(p->context,p->pixel,NULL,0);
    ID3D11DeviceContext_PSSetConstantBuffers(p->context,0,1,&p->constants);
    for(unsigned pass=0;pass<2;pass++){
        const unsigned input=pass?p->capacity:slot,output=pass?slot:p->capacity;
        constants.vertical=pass;D3D11_MAPPED_SUBRESOURCE map;
        HRESULT hr=ID3D11DeviceContext_Map(p->context,(ID3D11Resource *)p->constants,0,D3D11_MAP_WRITE_DISCARD,0,&map);
        if(FAILED(hr)){ID3D11DeviceContext_ClearState(p->context);return hr;}
        memcpy(map.pData,&constants,sizeof(constants));ID3D11DeviceContext_Unmap(p->context,(ID3D11Resource *)p->constants,0);
        ID3D11DeviceContext_OMSetRenderTargets(p->context,1,&p->targets[output].destination,NULL);
        ID3D11DeviceContext_PSSetShaderResources(p->context,0,1,&p->targets[input].source);
        ID3D11DeviceContext_Draw(p->context,3,0);
        ID3D11ShaderResourceView *none=NULL;ID3D11DeviceContext_PSSetShaderResources(p->context,0,1,&none);ID3D11DeviceContext_OMSetRenderTargets(p->context,0,NULL,NULL);
        bridge->passes++;
    }
    ID3D11DeviceContext_ClearState(p->context);
    return ID3D11Device_GetDeviceRemovedReason(p->device);
}
static HRESULT program_effect(ZgGaussianGpu *bridge,uint32_t slot,uint32_t width,uint32_t height,ID3D11VertexShader *vertex,ID3D11PixelShader *pixel,ID3D11Buffer *const *constants){
    Program *p=(Program *)bridge;if(!bridge->ready||slot>=p->capacity||!width||!height||width>p->pool_width||height>p->pool_height||!vertex||!pixel)return E_INVALIDARG;
    ID3D11DeviceContext_ClearState(p->context);
    const D3D11_VIEWPORT viewport={0,0,(float)width,(float)height,0,1};
    ID3D11DeviceContext_RSSetViewports(p->context,1,&viewport);ID3D11DeviceContext_RSSetState(p->context,p->raster);
    ID3D11DeviceContext_IASetPrimitiveTopology(p->context,D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(p->context,vertex,NULL,0);ID3D11DeviceContext_PSSetShader(p->context,pixel,NULL,0);
    ID3D11DeviceContext_PSSetConstantBuffers(p->context,0,2,constants);
    ID3D11DeviceContext_OMSetRenderTargets(p->context,1,&p->targets[p->capacity].destination,NULL);
    ID3D11DeviceContext_PSSetShaderResources(p->context,0,1,&p->targets[slot].source);
    ID3D11DeviceContext_Draw(p->context,3,0);
    ID3D11ShaderResourceView *none=NULL;ID3D11DeviceContext_PSSetShaderResources(p->context,0,1,&none);ID3D11DeviceContext_OMSetRenderTargets(p->context,0,NULL,NULL);
    const D3D11_BOX box={0,0,0,width,height,1};
    ID3D11DeviceContext_CopySubresourceRegion(p->context,(ID3D11Resource *)p->targets[slot].texture,0,0,0,0,(ID3D11Resource *)p->targets[p->capacity].texture,0,&box);
    ID3D11DeviceContext_ClearState(p->context);bridge->passes++;
    return ID3D11Device_GetDeviceRemovedReason(p->device);
}
static const ZgGaussianGpuOps ops={program_lose,program_destroy,program_bitmap,program_filter,program_effect};
/* The full-target triangle effects draw with. */
const unsigned char *zgpu_effect_vertex_code(size_t *len){*len=sizeof(zg_gaussian_vertex);return zg_gaussian_vertex;}
size_t zgpu_gaussian_metadata_size(void){return sizeof(Program)+sizeof(GaussianConstants);}
ZgGaussianGpu *zgpu_gaussian_create_candidate(ID3D11Device *device,ID2D1DeviceContext *d2d,const ZgGaussianCapacity *capacity,uint32_t pool_width,uint32_t pool_height,uint32_t depth,uint32_t fault,HRESULT *out){
    *out=E_INVALIDARG;if(!device||!d2d||!capacity||!depth||depth>4||!pool_width||!pool_height)return NULL;
    if(fault==1){*out=E_OUTOFMEMORY;return NULL;}
    Program *p=HeapAlloc(GetProcessHeap(),HEAP_ZERO_MEMORY,sizeof(*p));if(!p){*out=E_OUTOFMEMORY;return NULL;}zgpu_gaussian_account(1);
    p->bridge.ops=&ops;p->bridge.capacity=*capacity;p->bridge.metadata_bytes=zgpu_gaussian_metadata_size();p->capacity=depth;p->pool_width=pool_width;p->pool_height=pool_height;
    p->device=device;IUnknown_AddRef((IUnknown *)device);OWN(p->device);ID3D11Device_GetImmediateContext(device,&p->context);OWN(p->context);
    *out=fault==2?E_OUTOFMEMORY:ID3D11Device_CreateVertexShader(device,zg_gaussian_vertex,sizeof(zg_gaussian_vertex),NULL,&p->vertex);OWN(p->vertex);if(FAILED(*out))goto failed;
    *out=fault==3?E_OUTOFMEMORY:ID3D11Device_CreatePixelShader(device,zg_gaussian_pixel,sizeof(zg_gaussian_pixel),NULL,&p->pixel);OWN(p->pixel);if(FAILED(*out))goto failed;
    const D3D11_BUFFER_DESC buffer={.ByteWidth=sizeof(GaussianConstants),.Usage=D3D11_USAGE_DYNAMIC,.BindFlags=D3D11_BIND_CONSTANT_BUFFER,.CPUAccessFlags=D3D11_CPU_ACCESS_WRITE};
    *out=ID3D11Device_CreateBuffer(device,&buffer,NULL,&p->constants);OWN(p->constants);if(FAILED(*out))goto failed;
    const D3D11_RASTERIZER_DESC raster={.FillMode=D3D11_FILL_SOLID,.CullMode=D3D11_CULL_NONE,.DepthClipEnable=TRUE};
    *out=ID3D11Device_CreateRasterizerState(device,&raster,&p->raster);OWN(p->raster);if(FAILED(*out))goto failed;
    for(unsigned i=0;i<=depth;i++){*out=fault==i+4?E_OUTOFMEMORY:target_create(p,&p->targets[i],d2d,i<depth);if(FAILED(*out))goto failed;}
    p->bridge.objects=6+depth*4+3;p->bridge.ready=1;*out=S_OK;return &p->bridge;
failed:program_destroy(&p->bridge);return NULL;
}
