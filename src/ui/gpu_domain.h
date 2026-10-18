#ifndef ZIGGURAT_GPU_DOMAIN_H
#define ZIGGURAT_GPU_DOMAIN_H
#include <stddef.h>

/* Prefixes match the pure drawing resource ABI; ownership remains in Zig. */
typedef struct GpuDomainEpoch {uint64_t identity,generation;uint32_t status,reserved;} GpuDomainEpoch;
typedef struct GpuTextureToken {uint64_t identity,generation;uint32_t width,height,levels,reserved;} GpuTextureToken;
typedef struct DomainTexture {GpuTextureToken token;ID2D1Bitmap *bitmaps[ZI_IMAGE_LEVELS];} DomainTexture;
typedef struct DomainStats {uint32_t objects,devices,losses,reserved;uint64_t bitmaps;} DomainStats;
struct GpuDomain {
    GpuDomainEpoch *epoch;
    void *callback_context;
    void (*release_callback)(void *,int);
    ID3D11Device *d3d;
    ID2D1Factory1 *factory;
    ID2D1Device *device;
    ID2D1DeviceContext *upload;
    State *renderers;
    DomainTexture textures[ZI_IMAGE_SLOTS];
    uint32_t device_creations,device_losses;
    uint64_t bitmap_creations;
    int driver;
};
_Static_assert(sizeof(GpuDomainEpoch)==24,"GPU epoch ABI");
_Static_assert(sizeof(GpuTextureToken)==32,"GPU texture token ABI");
_Static_assert(offsetof(DomainTexture,token)==0,"GPU token prefix");

static void domain_drop_texture(DomainTexture *texture){
    for(unsigned i=0;i<ZI_IMAGE_LEVELS;i++)DROP(texture->bitmaps[i]);
}
static void domain_drop_device(GpuDomain *domain){
    for(unsigned i=0;i<ZI_IMAGE_SLOTS;i++)domain_drop_texture(&domain->textures[i]);
    DROP(domain->upload);DROP(domain->device);DROP(domain->d3d);
}
static HRESULT domain_create_device(GpuDomain *domain){
    IDXGIDevice *dxgi=NULL;D3D_FEATURE_LEVEL selected;
    const D3D_FEATURE_LEVEL levels[]={D3D_FEATURE_LEVEL_11_0,D3D_FEATURE_LEVEL_10_1,D3D_FEATURE_LEVEL_10_0};
    HRESULT hr=D3D11CreateDevice(NULL,domain->driver?D3D_DRIVER_TYPE_WARP:D3D_DRIVER_TYPE_HARDWARE,NULL,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT|D3D11_CREATE_DEVICE_SINGLETHREADED,levels,3,D3D11_SDK_VERSION,&domain->d3d,&selected,NULL);
    OWN(domain->d3d);if(FAILED(hr))goto failed;
    hr=ID3D11Device_QueryInterface(domain->d3d,&IID_IDXGIDevice,(void **)&dxgi);OWN(dxgi);if(FAILED(hr))goto failed;
    hr=domain->factory->lpVtbl->CreateDevice(domain->factory,dxgi,&domain->device);OWN(domain->device);if(FAILED(hr))goto failed;
    hr=domain->device->lpVtbl->CreateDeviceContext(domain->device,D2D1_DEVICE_CONTEXT_OPTIONS_NONE,&domain->upload);OWN(domain->upload);if(FAILED(hr))goto failed;
    DROP(dxgi);domain->device_creations++;return S_OK;
failed:
    DROP(dxgi);domain_drop_device(domain);return hr;
}
static void gpu_domain_lose(GpuDomain *domain){
    if(!domain||domain->epoch->status!=1)return;
    domain->epoch->status=2;
    if(domain->epoch->generation==UINT64_MAX)domain->epoch->status=4;else domain->epoch->generation++;
    domain->device_losses++;
    /* The owner cancels every borrowed wait before any DXGI handle is closed.
       The gate spans native release too, including synchronous window messages. */
    domain->release_callback(domain->callback_context,1);
    for(State *s=domain->renderers;s;s=s->domain_next){s->device_losses++;release_device(s);}
    domain_drop_device(domain);
    domain->release_callback(domain->callback_context,0);
}
size_t zgpu_domain_size(void){return sizeof(GpuDomain);}
GpuDomain *zgpu_domain_create(GpuDomainEpoch *epoch,int driver,void *context,void (*callback)(void *,int),HRESULT *out){
    GpuDomain *domain=calloc(1,sizeof(*domain));
    if(!domain){*out=E_OUTOFMEMORY;return NULL;}
    InterlockedIncrement(&live_resources);
    domain->epoch=epoch;domain->driver=driver;domain->callback_context=context;domain->release_callback=callback;
    const D2D1_FACTORY_OPTIONS options={D2D1_DEBUG_LEVEL_NONE};
    *out=D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,&IID_ID2D1Factory1,&options,(void **)&domain->factory);OWN(domain->factory);
    if(FAILED(*out))goto failed;
    *out=register_gradient(domain->factory);if(FAILED(*out))goto failed;
    *out=domain_create_device(domain);if(FAILED(*out))goto failed;
    epoch->status=1;return domain;
failed:
    domain_drop_device(domain);DROP(domain->factory);free(domain);InterlockedDecrement(&live_resources);return NULL;
}
void zgpu_domain_stop(GpuDomain *domain){
    if(!domain||domain->epoch->status==3)return;
    domain->epoch->status=3;
    domain->release_callback(domain->callback_context,1);
    for(State *s=domain->renderers;s;s=s->domain_next)release_device(s);
    domain_drop_device(domain);DROP(domain->factory);
    domain->release_callback(domain->callback_context,0);
}
void zgpu_domain_destroy(GpuDomain *domain){
    if(!domain)return;
    zgpu_domain_stop(domain);
    free(domain);InterlockedDecrement(&live_resources);
}
HRESULT zgpu_domain_recreate(GpuDomain *domain){
    if(!domain||domain->epoch->status!=2)return E_UNEXPECTED;
    HRESULT hr=domain_create_device(domain);
    if(SUCCEEDED(hr))domain->epoch->status=1;
    return hr;
}
const GpuTextureToken *zgpu_domain_upload(GpuDomain *domain,uint32_t slot,uint64_t identity,const ZiImageLevel *levels,uint32_t count,uint32_t fault,HRESULT *out){
    if(!domain||domain->epoch->status!=1||slot>=ZI_IMAGE_SLOTS||domain->textures[slot].token.identity||!identity||!count||count>ZI_IMAGE_LEVELS){*out=E_INVALIDARG;return NULL;}
    DomainTexture candidate={0};
    const D2D1_BITMAP_PROPERTIES properties={{DXGI_FORMAT_B8G8R8A8_UNORM,D2D1_ALPHA_MODE_PREMULTIPLIED},96,96};
    for(uint32_t i=0;i<count;i++){
        if(fault==i+1){*out=E_OUTOFMEMORY;goto failed;}
        const D2D1_SIZE_U size={levels[i].width,levels[i].height};
        if(size.width>ID2D1RenderTarget_GetMaximumBitmapSize((ID2D1RenderTarget *)domain->upload)||size.height>ID2D1RenderTarget_GetMaximumBitmapSize((ID2D1RenderTarget *)domain->upload)){*out=E_INVALIDARG;goto failed;}
        *out=ID2D1RenderTarget_CreateBitmap((ID2D1RenderTarget *)domain->upload,size,levels[i].pixels,levels[i].stride,&properties,&candidate.bitmaps[i]);OWN(candidate.bitmaps[i]);
        if(candidate.bitmaps[i])domain->bitmap_creations++;
        if(FAILED(*out))goto failed;
    }
    candidate.token=(GpuTextureToken){identity,domain->epoch->generation,levels[0].width,levels[0].height,count,0};
    domain->textures[slot]=candidate;*out=S_OK;return &domain->textures[slot].token;
failed:
    domain_drop_texture(&candidate);
    if(*out==DXGI_ERROR_DEVICE_REMOVED||*out==DXGI_ERROR_DEVICE_RESET||*out==DXGI_ERROR_DEVICE_HUNG||*out==DXGI_ERROR_DRIVER_INTERNAL_ERROR||*out==D2DERR_RECREATE_TARGET)gpu_domain_lose(domain);
    return NULL;
}
void zgpu_domain_release_texture(GpuDomain *domain,uint32_t slot){
    if(!domain||slot>=ZI_IMAGE_SLOTS)return;
    domain->textures[slot].token.identity=0;
    domain_drop_texture(&domain->textures[slot]);
    memset(&domain->textures[slot],0,sizeof(domain->textures[slot]));
}
void zgpu_domain_stats(GpuDomain *domain,DomainStats *stats){
    memset(stats,0,sizeof(*stats));if(!domain)return;
    stats->objects=(domain->d3d!=NULL)+(domain->factory!=NULL)+(domain->device!=NULL)+(domain->upload!=NULL);
    for(unsigned i=0;i<ZI_IMAGE_SLOTS;i++)for(unsigned j=0;j<ZI_IMAGE_LEVELS;j++)stats->objects+=domain->textures[i].bitmaps[j]!=NULL;
    stats->devices=domain->device_creations;stats->losses=domain->device_losses;stats->bitmaps=domain->bitmap_creations;
}
void zgpu_domain_inject_loss(GpuDomain *domain){gpu_domain_lose(domain);}
HRESULT zgpu_texture(State *s,const GpuTextureToken *token,const ZiImagePlan *plan){
    if(!s||!s->drawing||!s->domain||s->domain->epoch->status!=1||!token||!token->identity||token->generation!=s->domain->epoch->generation)return E_INVALIDARG;
    const DomainTexture *texture=NULL;
    for(unsigned i=0;i<ZI_IMAGE_SLOTS;i++)if(&s->domain->textures[i].token==token){texture=&s->domain->textures[i];break;}
    if(!texture||plan->level>=token->levels||!texture->bitmaps[plan->level])return E_INVALIDARG;
    const D2D1_RECT_F destination=rectangle(plan->destination.x,plan->destination.y,plan->destination.width,plan->destination.height),source=rectangle(plan->source.x,plan->source.y,plan->source.width,plan->source.height);
    ID2D1RenderTarget_DrawBitmap(RT(s),texture->bitmaps[plan->level],&destination,plan->opacity,plan->sampling?D2D1_BITMAP_INTERPOLATION_MODE_LINEAR:D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR,&source);
    return S_OK;
}
#endif
