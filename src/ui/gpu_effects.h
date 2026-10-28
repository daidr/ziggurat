/* Shader effects on Direct3D 11. Zig translates a program to HLSL,
   compiles it (or loads the bytecode from the disk cache) and installs it
   in one of ZG_EFFECT_SLOTS pixel shaders. A pass uploads the words the
   program's prologue computed on the CPU and the pass geometry, then runs
   the shader between EndDraw and BeginDraw: over an element effect's
   capture in place of its filter, or over a copy of the target beneath a
   backdrop shader. */
typedef struct ZgEffectParams {float a[4],b[4],shape[4],clip[4],c[4],d[4];uint32_t plane[4];} ZgEffectParams;
_Static_assert(sizeof(ZgEffectParams)==112,"effect parameter packing");
typedef struct ZgEffectPass {const uint32_t *words;uint32_t word_count,slot;ZgEffectParams params;} ZgEffectPass;
/* Where the current target's pixels are: physical pixel = DIP * scale +
   origin; the clip is physical and inside width x height. */
typedef struct ZgEffectGeometry {double clip[4];float scale,origin[2];uint32_t width,height,transparent;} ZgEffectGeometry;
#define ZG_EFFECT_WORDS 4096
#define ZG_EFFECT_TEXTURE_LIMIT 16384

const unsigned char *zgpu_effect_vertex_code(size_t *len);
static void gpu_effect_drop_objects(State *s){
    DROP(s->effect_vertex);for(unsigned i=0;i<ZG_EFFECT_SLOTS;i++)DROP(s->effect_pixels[i]);
    DROP(s->effect_constants[0]);DROP(s->effect_constants[1]);DROP(s->effect_raster);
    DROP(s->backdrop_view);DROP(s->backdrop_target);DROP(s->backdrop_copy);DROP(s->backdrop_output);s->backdrop_width=s->backdrop_height=0;
}
static HRESULT gpu_effect_objects(State *s){
    if(!s->d3d)return E_UNEXPECTED;HRESULT hr=S_OK;
    if(!s->effect_vertex){size_t len;const unsigned char *code=zgpu_effect_vertex_code(&len);hr=ID3D11Device_CreateVertexShader(s->d3d,code,len,NULL,&s->effect_vertex);OWN(s->effect_vertex);if(FAILED(hr))return hr;}
    for(unsigned i=0;i<2;i++)if(!s->effect_constants[i]){
        D3D11_BUFFER_DESC desc={.ByteWidth=i?(UINT)sizeof(ZgEffectParams):ZG_EFFECT_WORDS*4,.Usage=D3D11_USAGE_DYNAMIC,.BindFlags=D3D11_BIND_CONSTANT_BUFFER,.CPUAccessFlags=D3D11_CPU_ACCESS_WRITE};
        hr=ID3D11Device_CreateBuffer(s->d3d,&desc,NULL,&s->effect_constants[i]);OWN(s->effect_constants[i]);if(FAILED(hr))return hr;
    }
    if(!s->effect_raster){D3D11_RASTERIZER_DESC desc={.FillMode=D3D11_FILL_SOLID,.CullMode=D3D11_CULL_NONE,.DepthClipEnable=TRUE};hr=ID3D11Device_CreateRasterizerState(s->d3d,&desc,&s->effect_raster);OWN(s->effect_raster);}
    return hr;
}
/* Install compiled pixel shader bytecode in `slot`, replacing what it held. */
HRESULT zgpu_effect_install(State *s,uint32_t slot,const uint8_t *code,size_t len){
    if(!s||slot>=ZG_EFFECT_SLOTS||!code||!len)return E_INVALIDARG;
    if(!s->context){if(s->drawing)return E_UNEXPECTED;HRESULT hr=create_device(s);if(FAILED(hr))return failure(s,hr);}
    HRESULT hr=gpu_effect_objects(s);if(FAILED(hr))return failure(s,hr);
    ID3D11PixelShader *shader=NULL;hr=ID3D11Device_CreatePixelShader(s->d3d,code,len,NULL,&shader);OWN(shader);if(FAILED(hr))return failure(s,hr);
    DROP(s->effect_pixels[slot]);s->effect_pixels[slot]=shader;return S_OK;
}
int zgpu_effect_installed(State *s,uint32_t slot){return s&&slot<ZG_EFFECT_SLOTS&&s->effect_pixels[slot]&&s->effect_vertex;}
void zgpu_effect_uninstall(State *s,uint32_t slot){if(s&&slot<ZG_EFFECT_SLOTS)DROP(s->effect_pixels[slot]);}
uint64_t zgpu_effect_passes(State *s){return s?s->effect_passes:0;}
static int gpu_effect_valid(State *s,const ZgEffectPass *pass){return pass->slot<ZG_EFFECT_SLOTS&&s->effect_pixels[pass->slot]&&s->effect_vertex&&pass->word_count<=ZG_EFFECT_WORDS&&(pass->words||!pass->word_count);}
static HRESULT gpu_effect_upload(State *s,ID3D11DeviceContext *context,const ZgEffectPass *pass){
    D3D11_MAPPED_SUBRESOURCE map;HRESULT hr=ID3D11DeviceContext_Map(context,(ID3D11Resource *)s->effect_constants[0],0,D3D11_MAP_WRITE_DISCARD,0,&map);if(FAILED(hr))return hr;
    if(pass->word_count)memcpy(map.pData,pass->words,(size_t)pass->word_count*4);ID3D11DeviceContext_Unmap(context,(ID3D11Resource *)s->effect_constants[0],0);
    hr=ID3D11DeviceContext_Map(context,(ID3D11Resource *)s->effect_constants[1],0,D3D11_MAP_WRITE_DISCARD,0,&map);if(FAILED(hr))return hr;
    memcpy(map.pData,&pass->params,sizeof(pass->params));ID3D11DeviceContext_Unmap(context,(ID3D11Resource *)s->effect_constants[1],0);return S_OK;
}

HRESULT zgpu_effect_geometry(State *s,ZgEffectGeometry *out){
    if(!s||!s->drawing)return E_UNEXPECTED;
    GpuLayers *layer=s->layers;
    if(layer&&layer->active){const unsigned slot=layer->depth?layer->depth+1:layer->work;out->scale=layer->scale;out->origin[0]=layer->origins[slot][0];out->origin[1]=layer->origins[slot][1];out->width=layer->depth?layer->pool_width:layer->width;out->height=layer->depth?layer->pool_height:layer->height;out->transparent=layer->depth!=0||s->offscreen;}
    else{out->scale=s->dpi/96.0f;out->origin[0]=out->origin[1]=0;out->width=s->width;out->height=s->height;out->transparent=s->offscreen!=0;}
    double clip[4]={0,0,out->width,out->height};
    for(UINT i=0;i<s->clips;i++){
        const D2D1_RECT_F *r=&s->clip_rects[i];
        clip[0]=fmax(clip[0],(double)r->left*out->scale+out->origin[0]);clip[1]=fmax(clip[1],(double)r->top*out->scale+out->origin[1]);
        clip[2]=fmin(clip[2],(double)r->right*out->scale+out->origin[0]);clip[3]=fmin(clip[3],(double)r->bottom*out->scale+out->origin[1]);
    }
    if(clip[2]<clip[0])clip[2]=clip[0];if(clip[3]<clip[1])clip[3]=clip[1];
    memcpy(out->clip,clip,sizeof(clip));return S_OK;
}

static HRESULT gpu_effect_capture(State *s,uint32_t slot,const ZgGaussianCapture *capture,const void *context){
    const ZgEffectPass *pass=context;ZgGaussianGpu *program=s->layers->gaussian;
    ID3D11DeviceContext *device_context=NULL;ID3D11Device_GetImmediateContext(s->d3d,&device_context);OWN(device_context);
    HRESULT hr=gpu_effect_upload(s,device_context,pass);DROP(device_context);
    if(SUCCEEDED(hr))hr=program->ops->effect(program,slot,capture->width+2*capture->radius,capture->height+2*capture->radius,s->effect_vertex,s->effect_pixels[pass->slot],s->effect_constants);
    if(SUCCEEDED(hr))s->effect_passes++;
    return hr;
}
/* Close an element effect's capture: run `pass` over it, or with NULL
   composite the content as drawn. */
HRESULT zgpu_layer_end_effect(State *s,const ZgEffectPass *pass){
    if(!s||(pass&&!gpu_effect_valid(s,pass)))return E_INVALIDARG;
    const GpuCapturePass capture={pass?gpu_effect_capture:NULL,pass};
    return gpu_layer_end(s,&capture);
}

static HRESULT gpu_backdrop_textures(State *s,UINT width,UINT height){
    if(s->backdrop_copy&&width<=s->backdrop_width&&height<=s->backdrop_height)return S_OK;
    width=width>s->backdrop_width?width:s->backdrop_width;height=height>s->backdrop_height?height:s->backdrop_height;
    DROP(s->backdrop_view);DROP(s->backdrop_target);DROP(s->backdrop_copy);DROP(s->backdrop_output);s->backdrop_width=s->backdrop_height=0;
    D3D11_TEXTURE2D_DESC desc={0};desc.Width=width;desc.Height=height;desc.MipLevels=desc.ArraySize=desc.SampleDesc.Count=1;desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.Usage=D3D11_USAGE_DEFAULT;
    desc.BindFlags=D3D11_BIND_SHADER_RESOURCE;HRESULT hr=ID3D11Device_CreateTexture2D(s->d3d,&desc,NULL,&s->backdrop_copy);OWN(s->backdrop_copy);if(FAILED(hr))return hr;
    hr=ID3D11Device_CreateShaderResourceView(s->d3d,(ID3D11Resource *)s->backdrop_copy,NULL,&s->backdrop_view);OWN(s->backdrop_view);if(FAILED(hr))return hr;
    desc.BindFlags=D3D11_BIND_RENDER_TARGET;hr=ID3D11Device_CreateTexture2D(s->d3d,&desc,NULL,&s->backdrop_output);OWN(s->backdrop_output);if(FAILED(hr))return hr;
    hr=ID3D11Device_CreateRenderTargetView(s->d3d,(ID3D11Resource *)s->backdrop_output,NULL,&s->backdrop_target);OWN(s->backdrop_target);if(FAILED(hr))return hr;
    s->backdrop_width=width;s->backdrop_height=height;return S_OK;
}
static HRESULT gpu_backdrop_pass(State *s,ID3D11Texture2D *target,const ZgEffectPass *pass,const uint32_t *region,const uint32_t *out){
    HRESULT hr=gpu_backdrop_textures(s,region[2]-region[0],region[3]-region[1]);if(FAILED(hr))return hr;
    ID3D11DeviceContext *context=NULL;ID3D11Device_GetImmediateContext(s->d3d,&context);OWN(context);
    const D3D11_BOX source={region[0],region[1],0,region[2],region[3],1};
    ID3D11DeviceContext_CopySubresourceRegion(context,(ID3D11Resource *)s->backdrop_copy,0,0,0,0,(ID3D11Resource *)target,0,&source);
    hr=gpu_effect_upload(s,context,pass);
    if(SUCCEEDED(hr)){
        const UINT width=out[2]-out[0],height=out[3]-out[1];
        ID3D11DeviceContext_ClearState(context);
        const D3D11_VIEWPORT viewport={0,0,(float)width,(float)height,0,1};
        ID3D11DeviceContext_RSSetViewports(context,1,&viewport);ID3D11DeviceContext_RSSetState(context,s->effect_raster);
        ID3D11DeviceContext_IASetPrimitiveTopology(context,D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ID3D11DeviceContext_VSSetShader(context,s->effect_vertex,NULL,0);ID3D11DeviceContext_PSSetShader(context,s->effect_pixels[pass->slot],NULL,0);
        ID3D11DeviceContext_PSSetConstantBuffers(context,0,2,s->effect_constants);
        ID3D11DeviceContext_OMSetRenderTargets(context,1,&s->backdrop_target,NULL);
        ID3D11DeviceContext_PSSetShaderResources(context,0,1,&s->backdrop_view);
        ID3D11DeviceContext_Draw(context,3,0);
        ID3D11ShaderResourceView *none=NULL;ID3D11DeviceContext_PSSetShaderResources(context,0,1,&none);ID3D11DeviceContext_OMSetRenderTargets(context,0,NULL,NULL);
        const D3D11_BOX shaded={0,0,0,width,height,1};
        ID3D11DeviceContext_CopySubresourceRegion(context,(ID3D11Resource *)target,0,out[0],out[1],0,(ID3D11Resource *)s->backdrop_output,0,&shaded);
        ID3D11DeviceContext_ClearState(context);s->effect_passes++;
        hr=ID3D11Device_GetDeviceRemovedReason(s->d3d);
    }
    DROP(context);return hr;
}
/* Run a backdrop shader over `out` (physical x0, y0, x1, y1 of the current
   target), reading the target as drawn so far across `region`, which
   contains `out`. */
HRESULT zgpu_backdrop_shader(State *s,const ZgEffectPass *pass,const uint32_t region[4],const uint32_t out[4]){
    if(!s||!s->drawing)return E_UNEXPECTED;
    if(!gpu_effect_valid(s,pass)||!s->effect_raster||!s->effect_constants[0]||!s->effect_constants[1])return E_INVALIDARG;
    ZgEffectGeometry geometry;HRESULT hr=zgpu_effect_geometry(s,&geometry);if(FAILED(hr))return hr;
    if(!(region[0]<=out[0]&&region[1]<=out[1]&&out[0]<out[2]&&out[1]<out[3]&&out[2]<=region[2]&&out[3]<=region[3]&&region[2]<=geometry.width&&region[3]<=geometry.height&&region[2]-region[0]<=ZG_EFFECT_TEXTURE_LIMIT&&region[3]-region[1]<=ZG_EFFECT_TEXTURE_LIMIT))return E_INVALIDARG;
    D2D1_RECT_F clips[33];const UINT count=s->clips;memcpy(clips,s->clip_rects,sizeof(clips));
    D2D1_MATRIX_3X2_F transform;ID2D1RenderTarget_GetTransform(RT(s),&transform);
    gpu_layer_pop_clips(s);
    hr=ID2D1RenderTarget_EndDraw(RT(s),NULL,NULL);s->drawing=FALSE;
    if(FAILED(hr)){gpu_layer_abort_metadata(s);return failure(s,hr);}
    ID2D1Image *image=NULL;ID2D1Bitmap1 *bitmap=NULL;IDXGISurface *surface=NULL;ID3D11Texture2D *target=NULL;
    s->context->lpVtbl->GetTarget(s->context,&image);OWN(image);
    hr=image?IUnknown_QueryInterface((IUnknown *)image,&IID_ID2D1Bitmap1,(void **)&bitmap):E_UNEXPECTED;OWN(bitmap);
    if(SUCCEEDED(hr)){hr=ID2D1Bitmap1_GetSurface(bitmap,&surface);OWN(surface);}
    if(SUCCEEDED(hr)){hr=IUnknown_QueryInterface((IUnknown *)surface,&IID_ID3D11Texture2D,(void **)&target);OWN(target);}
    if(SUCCEEDED(hr))hr=gpu_backdrop_pass(s,target,pass,region,out);
    DROP(target);DROP(surface);DROP(bitmap);DROP(image);
    if(FAILED(hr)){gpu_layer_abort_metadata(s);return failure(s,hr);}
    ID2D1RenderTarget_BeginDraw(RT(s));s->drawing=TRUE;ID2D1RenderTarget_SetTransform(RT(s),&transform);
    if(s->layers)gpu_layer_restore_clips(s,clips,count);
    else for(UINT i=0;i<count;i++){s->clip_rects[s->clips]=clips[i];ID2D1RenderTarget_PushAxisAlignedClip(RT(s),&clips[i],D2D1_ANTIALIAS_MODE_ALIASED);s->clips++;}
    return S_OK;
}
