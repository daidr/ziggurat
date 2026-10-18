#ifndef ZIGGURAT_GPU_OFFSCREEN_H
#define ZIGGURAT_GPU_OFFSCREEN_H

/* Dedicated transparent targets. They never create an HWND, swapchain,
   waitable object, or CPU staging resource. Command replay remains shared. */
size_t zgpu_offscreen_metadata_size(void){return sizeof(State)+sizeof(GpuLayers);}
State *zgpu_create_offscreen(GpuDomain *domain,HRESULT *out){
    if(!domain||domain->epoch->status!=1){*out=E_INVALIDARG;return NULL;}
    return create_renderer(domain->driver,domain,1,out);
}
HRESULT zgpu_begin_offscreen(State *s){
    if(!s||!s->offscreen||s->drawing||!s->layers)return E_UNEXPECTED;
    HRESULT hr=S_OK;if(!s->d3d){hr=create_device(s);if(FAILED(hr))return hr;}
    GpuLayers *layer=s->layers;
    gpu_layer_begin(s);
    ID2D1RenderTarget_SetDpi(RT(s),96*layer->scale,96*layer->scale);
    s->dpi=96*layer->scale;s->width=layer->width;s->height=layer->height;s->clips=0;
    ID2D1RenderTarget_BeginDraw(RT(s));s->drawing=TRUE;
    const D2D1_COLOR_F transparent={0,0,0,0};ID2D1RenderTarget_Clear(RT(s),&transparent);
    return S_OK;
}
HRESULT zgpu_end_offscreen(State *s){return end_frame(s,1);}
void zgpu_commit_offscreen(State *s){
    GpuLayers *layer=s->layers;unsigned previous=layer->front;layer->front=layer->work;layer->work=previous;layer->active=0;layer->stats.committed_frames++;
}

const GpuTextureToken *zgpu_snapshot_offscreen(GpuDomain *domain,State *s,uint32_t slot,uint64_t identity,uint32_t width,uint32_t height,uint32_t fault,HRESULT *out){
    *out=E_INVALIDARG;
    if(!domain||domain->epoch->status!=1||!s||!s->offscreen||s->domain!=domain||s->drawing||!s->layers||s->layers->active||s->layers->width!=width||s->layers->height!=height||!s->layers->targets[s->layers->front]||slot>=ZI_IMAGE_SLOTS||domain->textures[slot].token.identity||!identity)return NULL;
    DomainTexture candidate={0};
    const D2D1_SIZE_U size={s->layers->width,s->layers->height};
    const D2D1_BITMAP_PROPERTIES properties={{DXGI_FORMAT_B8G8R8A8_UNORM,D2D1_ALPHA_MODE_PREMULTIPLIED},96,96};
    if(fault==1){*out=E_OUTOFMEMORY;goto failed;}
    *out=ID2D1RenderTarget_CreateBitmap((ID2D1RenderTarget *)domain->upload,size,NULL,0,&properties,&candidate.bitmaps[0]);OWN(candidate.bitmaps[0]);
    if(candidate.bitmaps[0])domain->bitmap_creations++;
    if(FAILED(*out))goto failed;
    if(fault==2){*out=E_OUTOFMEMORY;goto failed;}
    *out=ID2D1Bitmap_CopyFromBitmap(candidate.bitmaps[0],NULL,(ID2D1Bitmap *)s->layers->targets[s->layers->front],NULL);
    if(FAILED(*out))goto failed;
    if(fault==3){*out=DXGI_ERROR_DEVICE_REMOVED;goto failed;}
    candidate.token=(GpuTextureToken){identity,domain->epoch->generation,size.width,size.height,1,0};
    domain->textures[slot]=candidate;*out=S_OK;return &domain->textures[slot].token;
failed:
    domain_drop_texture(&candidate);
    if(device_lost(*out))gpu_domain_lose(domain);
    return NULL;
}
#endif
