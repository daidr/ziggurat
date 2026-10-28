/* Explicit, device-bound workspace. Switching targets never changes logical
   parent clip coverage; only the final composite consumes that clip. */
#include "layer_resource.h"
typedef struct GpuGroup {ZgLayerGroup group;ZgTransform transform;D2D1_MATRIX_3X2_F parent_transform;D2D1_RECT_F clips[33];UINT count;uint32_t kind;} GpuGroup;
struct GpuLayers {
    uint32_t width,height,pool_width,pool_height,capacity,depth,front,work,active;
    float scale;
    ID2D1Bitmap1 *targets[6];
    ID2D1BitmapBrush *brushes[6];
    float origins[6][2];
    GpuGroup groups[4];
    ZgLayerStats stats;
    ZgGaussianGpu *gaussian;
};
static void gpu_layer_drop_objects(GpuLayers *layer){if(layer){for(unsigned i=0;i<6;i++)DROP(layer->brushes[i]);for(unsigned i=0;i<6;i++)DROP(layer->targets[i]);if(layer->gaussian)layer->gaussian->ops->lose(layer->gaussian);layer->stats.native_objects=0;}}
void zgpu_layer_free(GpuLayers *layer){if(layer){gpu_layer_drop_objects(layer);if(layer->gaussian)layer->gaussian->ops->destroy(layer->gaussian);free(layer);InterlockedDecrement(&live_resources);}}
static HRESULT gpu_layer_objects(State *s,GpuLayers *layer,uint32_t fault){
    D2D1_BITMAP_PROPERTIES1 properties={0};properties.pixelFormat.format=DXGI_FORMAT_B8G8R8A8_UNORM;properties.pixelFormat.alphaMode=D2D1_ALPHA_MODE_PREMULTIPLIED;properties.dpiX=properties.dpiY=96*layer->scale;properties.bitmapOptions=D2D1_BITMAP_OPTIONS_TARGET;
    D2D1_SIZE_U size={layer->width,layer->height};HRESULT hr=S_OK;
    for(unsigned i=0;i<layer->capacity+2;i++){
        size=(D2D1_SIZE_U){i<2?layer->width:layer->pool_width,i<2?layer->height:layer->pool_height};
        if(fault==i+1){hr=E_OUTOFMEMORY;goto failed;}
        if(i>=2&&layer->gaussian&&layer->gaussian->ready){layer->targets[i]=layer->gaussian->ops->bitmap(layer->gaussian,i-2);if(!layer->targets[i]){hr=E_UNEXPECTED;goto failed;}IUnknown_AddRef((IUnknown *)layer->targets[i]);OWN(layer->targets[i]);}
        else{hr=s->context->lpVtbl->CreateBitmap(s->context,size,NULL,0,&properties,&layer->targets[i]);OWN(layer->targets[i]);if(layer->targets[i])layer->stats.native_creations++;if(FAILED(hr))goto failed;}
        if(i>=2){
            D2D1_BITMAP_BRUSH_PROPERTIES brush={D2D1_EXTEND_MODE_CLAMP,D2D1_EXTEND_MODE_CLAMP,D2D1_BITMAP_INTERPOLATION_MODE_LINEAR};
            hr=RT(s)->lpVtbl->CreateBitmapBrush(RT(s),(ID2D1Bitmap *)layer->targets[i],&brush,NULL,&layer->brushes[i]);OWN(layer->brushes[i]);if(layer->brushes[i])layer->stats.native_creations++;if(FAILED(hr))goto failed;
        }
    }
    ID2D1Image *previous=NULL;s->context->lpVtbl->GetTarget(s->context,&previous);OWN(previous);
    s->context->lpVtbl->SetTarget(s->context,(ID2D1Image *)layer->targets[layer->front]);
    ID2D1RenderTarget_BeginDraw(RT(s));const D2D1_COLOR_F initial=s->offscreen?(D2D1_COLOR_F){0,0,0,0}:(D2D1_COLOR_F){1,1,1,1};ID2D1RenderTarget_Clear(RT(s),&initial);hr=ID2D1RenderTarget_EndDraw(RT(s),NULL,NULL);
    s->context->lpVtbl->SetTarget(s->context,previous);DROP(previous);
    if(FAILED(hr))goto failed;
    layer->stats.native_objects=layer->capacity*2+2+(layer->gaussian?layer->gaussian->objects:0);return S_OK;
failed:gpu_layer_drop_objects(layer);return hr;
}
static GpuLayers *gpu_layer_create(State *s,uint32_t width,uint32_t height,float scale,uint32_t capacity,uint32_t pool_width,uint32_t pool_height,ZgGaussianGpu *gaussian,HRESULT *out){
    *out=E_INVALIDARG;if(s->drawing||!width||!height||capacity==0||capacity>4||!isfinite(scale)||scale<=0){if(gaussian)gaussian->ops->destroy(gaussian);return NULL;}
    if(!s->context){*out=create_device(s);if(FAILED(*out)){if(gaussian)gaussian->ops->destroy(gaussian);return NULL;}}
    GpuLayers *layer=calloc(1,sizeof(*layer));if(!layer){if(gaussian)gaussian->ops->destroy(gaussian);*out=E_OUTOFMEMORY;return NULL;}InterlockedIncrement(&live_resources);
    layer->gaussian=gaussian;
    layer->width=width;layer->height=height;layer->scale=scale;layer->capacity=capacity;layer->work=1;layer->stats.metadata_bytes=sizeof(*layer)+(gaussian?gaussian->metadata_bytes:0);layer->stats.native_creations=gaussian?gaussian->objects:0;
    layer->pool_width=pool_width;layer->pool_height=pool_height;
    uint32_t fault=s->layer_fault;s->layer_fault=0;
    *out=gpu_layer_objects(s,layer,fault);if(FAILED(*out)){zgpu_layer_free(layer);failure(s,*out);return NULL;}
    /* A prepared front is independent of flip-buffer preservation. Candidate
       construction copies it before replacing any old workspace. */
    if(s->layers&&s->layers->width==width&&s->layers->height==height&&s->layers->scale==scale){
        *out=ID2D1Bitmap_CopyFromBitmap((ID2D1Bitmap *)layer->targets[layer->front],NULL,(ID2D1Bitmap *)s->layers->targets[s->layers->front],NULL);
        if(FAILED(*out)){zgpu_layer_free(layer);failure(s,*out);return NULL;}
    }
    return layer;
}
GpuLayers *zgpu_layer_create(State *s,uint32_t width,uint32_t height,float scale,uint32_t capacity,uint32_t pool_width,uint32_t pool_height,HRESULT *out){return gpu_layer_create(s,width,height,scale,capacity,pool_width,pool_height,NULL,out);}
/* Ownership of program is consumed on every return, including failure. No
   temporary duplicate pool is allocated alongside its explicit SRV targets. */
GpuLayers *zgpu_layer_create_gaussian(State *s,uint32_t width,uint32_t height,float scale,uint32_t capacity,uint32_t pool_width,uint32_t pool_height,ZgGaussianGpu *program,HRESULT *out){return gpu_layer_create(s,width,height,scale,capacity,pool_width,pool_height,program,out);}
void zgpu_layer_commit(State *s,GpuLayers *candidate){zgpu_layer_free(s->layers);s->layers=candidate;}
void zgpu_layer_release(State *s){zgpu_layer_free(s->layers);s->layers=NULL;}
static ID2D1Bitmap1 *gpu_layer_current(GpuLayers *layer){return layer->targets[layer->depth?layer->depth+1:layer->work];}
static void gpu_layer_pop_clips(State *s){while(s->clips){ID2D1RenderTarget_PopAxisAlignedClip(RT(s));s->clips--;}}
static void gpu_layer_restore_clips(State *s,const D2D1_RECT_F *clips,UINT count){for(UINT i=0;i<count;i++){s->clip_rects[s->clips]=clips[i];const int source=i==0&&s->layers->depth&&s->layers->groups[s->layers->depth-1].kind==1;ID2D1RenderTarget_PushAxisAlignedClip(RT(s),&clips[i],source?D2D1_ANTIALIAS_MODE_PER_PRIMITIVE:D2D1_ANTIALIAS_MODE_ALIASED);s->clips++;}}
static void gpu_layer_abort_metadata(State *s){if(s->layers&&s->layers->active){s->layers->active=0;s->layers->depth=0;s->layers->stats.aborted_frames++;}}
static void gpu_layer_begin(State *s){
    GpuLayers *layer=s->layers;layer->active=1;layer->depth=0;s->context->lpVtbl->SetTarget(s->context,(ID2D1Image *)gpu_layer_current(layer));
    if(layer->gaussian)layer->gaussian->visits=0;
    layer->origins[layer->work][0]=layer->origins[layer->work][1]=0;const D2D1_MATRIX_3X2_F identity={1,0,0,1,0,0};ID2D1RenderTarget_SetTransform(RT(s),&identity);
    ID2D1RenderTarget_SetTextAntialiasMode(RT(s),D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);layer->stats.clear_pixels+=(uint64_t)layer->width*layer->height;
}
static void gpu_layer_box(GpuLayers *layer,const D2D1_RECT_F *rect,D2D1_RECT_F *dip,uint64_t *pixels){
    const unsigned slot=layer->depth?layer->depth+1:layer->work;const double ox=layer->origins[slot][0],oy=layer->origins[slot][1],width=layer->depth?layer->pool_width:layer->width,height=layer->depth?layer->pool_height:layer->height;
    double left=fmin(width,fmax(0,floor((double)rect->left*layer->scale+ox))),top=fmin(height,fmax(0,floor((double)rect->top*layer->scale+oy)));
    double right=fmax(left,fmin(width,ceil((double)rect->right*layer->scale+ox))),bottom=fmax(top,fmin(height,ceil((double)rect->bottom*layer->scale+oy)));
    *dip=(D2D1_RECT_F){(float)((left-ox)/layer->scale),(float)((top-oy)/layer->scale),(float)((right-ox)/layer->scale),(float)((bottom-oy)/layer->scale)};*pixels=(uint64_t)(right-left)*(uint64_t)(bottom-top);
}
HRESULT zgpu_layer_begin_group(State *s,const ZgLayerGroup *group){
    GpuLayers *layer=s->layers;if(!s->drawing||!layer||!layer->active||layer->depth>=layer->capacity)return E_UNEXPECTED;
    GpuGroup *frame=&layer->groups[layer->depth];frame->kind=0;frame->group=*group;frame->count=s->clips;memcpy(frame->clips,s->clip_rects,sizeof(frame->clips));ID2D1RenderTarget_GetTransform(RT(s),&frame->parent_transform);
    D2D1_RECT_F visible=rectangle(group->x,group->y,group->width,group->height);
    for(UINT i=0;i<s->clips;i++){visible.left=fmaxf(visible.left,s->clip_rects[i].left);visible.top=fmaxf(visible.top,s->clip_rects[i].top);visible.right=fminf(visible.right,s->clip_rects[i].right);visible.bottom=fminf(visible.bottom,s->clip_rects[i].bottom);}
    gpu_layer_pop_clips(s);
    /* A later same-depth group mutates this target. Flush earlier consumers
       before switching, without a blocking GPU wait or a new effect/bitmap. */
    HRESULT hr=ID2D1RenderTarget_Flush(RT(s),NULL,NULL);if(FAILED(hr))return failure(s,hr);
    const unsigned parent=layer->depth?layer->depth+1:layer->work;
    layer->depth++;memcpy(layer->origins[layer->depth+1],layer->origins[parent],sizeof(layer->origins[parent]));s->context->lpVtbl->SetTarget(s->context,(ID2D1Image *)gpu_layer_current(layer));
    uint64_t pixels;D2D1_RECT_F box;gpu_layer_box(layer,&visible,&box,&pixels);gpu_layer_restore_clips(s,&box,1);
    const D2D1_COLOR_F transparent={0,0,0,0};ID2D1RenderTarget_Clear(RT(s),&transparent);
    layer->stats.groups++;layer->stats.clear_pixels+=pixels;return S_OK;
}
/* A pass that replaces a capture's filter, run between EndDraw and the
   composite; NULL `run` composites the capture as drawn. */
typedef struct GpuCapturePass {HRESULT (*run)(State *,uint32_t,const ZgGaussianCapture *,const void *);const void *context;} GpuCapturePass;
static HRESULT gpu_layer_end(State *s,const GpuCapturePass *pass){
    GpuLayers *layer=s->layers;if(!s->drawing||!layer||!layer->depth||s->clips!=1||(layer->groups[layer->depth-1].kind!=0&&layer->groups[layer->depth-1].kind!=2))return E_UNEXPECTED;
    if(pass&&layer->groups[layer->depth-1].kind!=2)return E_UNEXPECTED;
    unsigned child=layer->depth+1;GpuGroup *frame=&layer->groups[layer->depth-1];const ZgLayerGroup *group=&frame->group;
    const int filtered=frame->kind==2;
    gpu_layer_pop_clips(s);HRESULT hr;
    if(filtered){
        hr=ID2D1RenderTarget_EndDraw(RT(s),NULL,NULL);s->drawing=FALSE;
        if(SUCCEEDED(hr)){
            s->context->lpVtbl->SetTarget(s->context,NULL);const ZgGaussianFrame *filter=&layer->gaussian->frames[layer->depth-1];
            if(!pass)hr=layer->gaussian->ops->filter(layer->gaussian,layer->depth-1,&filter->capture,&filter->kernel);
            else if(pass->run)hr=pass->run(s,layer->depth-1,&filter->capture,pass->context);
        }
        if(FAILED(hr)){gpu_layer_abort_metadata(s);return failure(s,hr);}
    }else{hr=ID2D1RenderTarget_Flush(RT(s),NULL,NULL);if(FAILED(hr))return failure(s,hr);}
    layer->depth--;s->context->lpVtbl->SetTarget(s->context,(ID2D1Image *)gpu_layer_current(layer));
    if(filtered){ID2D1RenderTarget_BeginDraw(RT(s));s->drawing=TRUE;}
    ID2D1RenderTarget_SetTransform(RT(s),&frame->parent_transform);
    D2D1_RECT_F bounds=rectangle(group->x,group->y,group->width,group->height);
    if(filtered){const ZgGaussianCapture *c=&layer->gaussian->frames[layer->depth].capture;bounds=rectangle((float)(((double)c->left-c->radius)/c->scale),(float)(((double)c->top-c->radius)/c->scale),(float)((double)(c->width+2*c->radius)/c->scale),(float)((double)(c->height+2*c->radius)/c->scale));}
    for(UINT i=0;i<frame->count;i++){bounds.left=fmaxf(bounds.left,frame->clips[i].left);bounds.top=fmaxf(bounds.top,frame->clips[i].top);bounds.right=fminf(bounds.right,frame->clips[i].right);bounds.bottom=fminf(bounds.bottom,frame->clips[i].bottom);}
    ID2D1RenderTarget_PushAxisAlignedClip(RT(s),&bounds,D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
    const float opacity=(float)group->opacity/255.0f;
    const float ox=layer->origins[child][0]/layer->scale,oy=layer->origins[child][1]/layer->scale;const D2D1_RECT_F child_destination=rectangle(-ox,-oy,(float)layer->pool_width/layer->scale,(float)layer->pool_height/layer->scale);
    if(group->mask_slot==UINT32_MAX)ID2D1RenderTarget_DrawBitmap(RT(s),(ID2D1Bitmap *)layer->targets[child],&child_destination,opacity,D2D1_BITMAP_INTERPOLATION_MODE_LINEAR,NULL);
    else{
        if(group->mask_slot>=s->image_capacity||!s->images[group->mask_slot].is_coverage){ID2D1RenderTarget_PopAxisAlignedClip(RT(s));return E_INVALIDARG;}
        CachedImage *mask=&s->images[group->mask_slot];const ZiImageLevel *level=&mask->coverage_level;
        const D2D1_RECT_F destination=rectangle((float)((double)group->mask_x+((double)group->mask_left-1)/group->mask_scale),(float)((double)group->mask_y+((double)group->mask_top-1)/group->mask_scale),(level->width+2)/group->mask_scale,(level->height+2)/group->mask_scale),source=rectangle(0,0,(float)(level->width+2),(float)(level->height+2));
        ID2D1Brush_SetOpacity((ID2D1Brush *)layer->brushes[child],opacity);
        const D2D1_MATRIX_3X2_F brush_matrix={1,0,0,1,-ox,-oy};ID2D1Brush_SetTransform((ID2D1Brush *)layer->brushes[child],&brush_matrix);
        D2D1_ANTIALIAS_MODE previous=ID2D1RenderTarget_GetAntialiasMode(RT(s));ID2D1RenderTarget_SetAntialiasMode(RT(s),D2D1_ANTIALIAS_MODE_ALIASED);
        ID2D1RenderTarget_FillOpacityMask(RT(s),mask->bitmaps[0][0],(ID2D1Brush *)layer->brushes[child],D2D1_OPACITY_MASK_CONTENT_GRAPHICS,&destination,&source);ID2D1RenderTarget_SetAntialiasMode(RT(s),previous);
    }
    ID2D1RenderTarget_PopAxisAlignedClip(RT(s));
    gpu_layer_restore_clips(s,frame->clips,frame->count);
    for(UINT i=0;i<s->clips;i++){bounds.left=fmaxf(bounds.left,s->clip_rects[i].left);bounds.top=fmaxf(bounds.top,s->clip_rects[i].top);bounds.right=fminf(bounds.right,s->clip_rects[i].right);bounds.bottom=fminf(bounds.bottom,s->clip_rects[i].bottom);}uint64_t pixels;D2D1_RECT_F box;gpu_layer_box(layer,&bounds,&box,&pixels);layer->stats.composite_pixels+=pixels;return S_OK;
}
HRESULT zgpu_layer_end_group(State *s){return gpu_layer_end(s,NULL);}
size_t zgpu_layer_metadata_size(void){return sizeof(GpuLayers);}
int zgpu_layer_gaussian_capacity(State *s,ZgGaussianCapacity *out){if(!s->layers||!s->layers->gaussian||!s->layers->gaussian->ready)return 0;*out=s->layers->gaussian->capacity;return 1;}
size_t zgpu_layer_gaussian_reserved(State *s){return s->layers&&s->layers->gaussian?s->layers->gaussian->metadata_bytes:0;}
size_t zgpu_layer_candidate_gaussian_reserved(GpuLayers *layers){return layers&&layers->gaussian?layers->gaussian->metadata_bytes:0;}
uint64_t zgpu_layer_gaussian_passes(State *s){return s->layers&&s->layers->gaussian?s->layers->gaussian->passes:0;}
HRESULT zgpu_layer_release_gaussian(State *s){
    if(s->drawing)return E_UNEXPECTED;if(!s->layers||!s->layers->gaussian)return S_OK;
    /* Layer bitmap references keep the prepared group planes alive. */
    ZgGaussianGpu *owner=s->layers->gaussian;s->layers->gaussian=NULL;s->layers->stats.metadata_bytes-=owner->metadata_bytes;s->layers->stats.native_objects-=owner->objects;owner->ops->destroy(owner);return S_OK;
}
HRESULT zgpu_layer_begin_gaussian(State *s,const ZgLayerGroup *group,const ZgGaussianCapture *capture,const ZgGaussianKernel *kernel){
    GpuLayers *layer=s->layers;if(!s->drawing||!layer||!layer->active||!layer->gaussian||!layer->gaussian->ready||layer->depth>=layer->capacity||!zg_filter_check(&layer->gaussian->capacity,capture)||capture->radius!=kernel->radius)return ZG_E_GAUSSIAN_PRECISION;
    const uint64_t work=zg_filter_samples(capture);if(layer->gaussian->visits>layer->gaussian->capacity.filter_samples-work)return ZG_E_GAUSSIAN_PRECISION;
    const unsigned depth=layer->depth;GpuGroup *frame=&layer->groups[depth];frame->kind=2;frame->group=*group;frame->count=s->clips;memcpy(frame->clips,s->clip_rects,sizeof(frame->clips));ID2D1RenderTarget_GetTransform(RT(s),&frame->parent_transform);
    layer->gaussian->frames[depth]=(ZgGaussianFrame){*capture,*kernel};layer->gaussian->visits+=work;
    gpu_layer_pop_clips(s);HRESULT hr=ID2D1RenderTarget_Flush(RT(s),NULL,NULL);if(FAILED(hr))return failure(s,hr);
    layer->depth++;const unsigned slot=layer->depth+1;const float ox=(float)((double)capture->radius-capture->left),oy=(float)((double)capture->radius-capture->top);layer->origins[slot][0]=ox;layer->origins[slot][1]=oy;
    s->context->lpVtbl->SetTarget(s->context,(ID2D1Image *)gpu_layer_current(layer));const D2D1_MATRIX_3X2_F identity={1,0,0,1,0,0};ID2D1RenderTarget_SetTransform(RT(s),&identity);
    const D2D1_RECT_F padded=rectangle(0,0,(float)(capture->width+2*capture->radius)/layer->scale,(float)(capture->height+2*capture->radius)/layer->scale);ID2D1RenderTarget_PushAxisAlignedClip(RT(s),&padded,D2D1_ANTIALIAS_MODE_ALIASED);const D2D1_COLOR_F clear={0,0,0,0};ID2D1RenderTarget_Clear(RT(s),&clear);ID2D1RenderTarget_PopAxisAlignedClip(RT(s));
    const D2D1_MATRIX_3X2_F translated={1,0,0,1,ox/layer->scale,oy/layer->scale};ID2D1RenderTarget_SetTransform(RT(s),&translated);
    const D2D1_RECT_F source=rectangle((float)((double)capture->left/layer->scale),(float)((double)capture->top/layer->scale),(float)((double)capture->width/layer->scale),(float)((double)capture->height/layer->scale));gpu_layer_restore_clips(s,&source,1);
    layer->stats.groups++;layer->stats.clear_pixels+=(uint64_t)(capture->width+2*capture->radius)*(capture->height+2*capture->radius);return S_OK;
}
void zgpu_layer_stats(State *s,ZgLayerStats *out){*out=s->layers?s->layers->stats:(ZgLayerStats){0};}
HRESULT zgpu_layer_begin_transform(State *s,const ZgTransform *value){
    GpuLayers *layer=s->layers;if(!s->drawing||!layer||!layer->active||layer->depth>=layer->capacity||value->pixel_width+2>layer->pool_width||value->pixel_height+2>layer->pool_height)return E_UNEXPECTED;
    GpuGroup *frame=&layer->groups[layer->depth];frame->kind=1;frame->transform=*value;frame->count=s->clips;memcpy(frame->clips,s->clip_rects,sizeof(frame->clips));ID2D1RenderTarget_GetTransform(RT(s),&frame->parent_transform);
    gpu_layer_pop_clips(s);HRESULT hr=ID2D1RenderTarget_Flush(RT(s),NULL,NULL);if(FAILED(hr))return failure(s,hr);
    layer->depth++;const unsigned slot=layer->depth+1;layer->origins[slot][0]=layer->origins[slot][1]=1;s->context->lpVtbl->SetTarget(s->context,(ID2D1Image *)gpu_layer_current(layer));
    const D2D1_MATRIX_3X2_F identity={1,0,0,1,0,0};ID2D1RenderTarget_SetTransform(RT(s),&identity);
    const D2D1_RECT_F guard=rectangle(0,0,(float)(value->pixel_width+2)/layer->scale,(float)(value->pixel_height+2)/layer->scale);ID2D1RenderTarget_PushAxisAlignedClip(RT(s),&guard,D2D1_ANTIALIAS_MODE_ALIASED);
    const D2D1_COLOR_F transparent={0,0,0,0};ID2D1RenderTarget_Clear(RT(s),&transparent);ID2D1RenderTarget_PopAxisAlignedClip(RT(s));
    const D2D1_MATRIX_3X2_F child={1,0,0,1,1/layer->scale,1/layer->scale};ID2D1RenderTarget_SetTransform(RT(s),&child);const D2D1_RECT_F source=rectangle(0,0,value->source_width,value->source_height);gpu_layer_restore_clips(s,&source,1);
    layer->stats.clear_pixels+=(uint64_t)(value->pixel_width+2)*(value->pixel_height+2);return S_OK;
}
HRESULT zgpu_layer_end_transform(State *s){
    GpuLayers *layer=s->layers;if(!s->drawing||!layer||!layer->depth||s->clips!=1||layer->groups[layer->depth-1].kind!=1)return E_UNEXPECTED;
    const unsigned child=layer->depth+1;GpuGroup *frame=&layer->groups[layer->depth-1];const ZgTransform *value=&frame->transform;
    gpu_layer_pop_clips(s);HRESULT hr=ID2D1RenderTarget_Flush(RT(s),NULL,NULL);if(FAILED(hr))return failure(s,hr);
    layer->depth--;s->context->lpVtbl->SetTarget(s->context,(ID2D1Image *)gpu_layer_current(layer));ID2D1RenderTarget_SetTransform(RT(s),&frame->parent_transform);
    if(frame->count){D2D1_RECT_F clip=frame->clips[0];for(UINT i=1;i<frame->count;i++){clip.left=fmaxf(clip.left,frame->clips[i].left);clip.top=fmaxf(clip.top,frame->clips[i].top);clip.right=fminf(clip.right,frame->clips[i].right);clip.bottom=fminf(clip.bottom,frame->clips[i].bottom);}ID2D1RenderTarget_PushAxisAlignedClip(RT(s),&clip,D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);}
    const D2D1_MATRIX_3X2_F *parent=&frame->parent_transform;
    const D2D1_MATRIX_3X2_F matrix={(float)(value->xx*parent->_11+value->yx*parent->_21),(float)(value->xx*parent->_12+value->yx*parent->_22),(float)(value->xy*parent->_11+value->yy*parent->_21),(float)(value->xy*parent->_12+value->yy*parent->_22),(float)(value->x0*parent->_11+value->y0*parent->_21+parent->_31),(float)(value->x0*parent->_12+value->y0*parent->_22+parent->_32)};
    ID2D1RenderTarget_SetTransform(RT(s),&matrix);
    const D2D1_RECT_F source=rectangle(0,0,(float)(value->pixel_width+2)/layer->scale,(float)(value->pixel_height+2)/layer->scale),destination=rectangle(-1/layer->scale,-1/layer->scale,(float)(value->pixel_width+2)/layer->scale,(float)(value->pixel_height+2)/layer->scale);
    /* Alpha is already filtered through transparent guard texels. Primitive
       edge AA would multiply those samples again at a skewed bitmap quad. */
    D2D1_ANTIALIAS_MODE previous=ID2D1RenderTarget_GetAntialiasMode(RT(s));
    ID2D1RenderTarget_SetAntialiasMode(RT(s),D2D1_ANTIALIAS_MODE_ALIASED);
    ID2D1RenderTarget_DrawBitmap(RT(s),(ID2D1Bitmap *)layer->targets[child],&destination,1,D2D1_BITMAP_INTERPOLATION_MODE_LINEAR,&source);
    ID2D1RenderTarget_SetAntialiasMode(RT(s),previous);
    ID2D1RenderTarget_SetTransform(RT(s),parent);if(frame->count)ID2D1RenderTarget_PopAxisAlignedClip(RT(s));gpu_layer_restore_clips(s,frame->clips,frame->count);
    layer->stats.composite_pixels+=(uint64_t)(layer->depth?layer->pool_width:layer->width)*(layer->depth?layer->pool_height:layer->height);return S_OK;
}
static HRESULT gpu_layer_copy_window(State *s){
    ID2D1RenderTarget_BeginDraw(RT(s));ID2D1RenderTarget_DrawBitmap(RT(s),(ID2D1Bitmap *)s->layers->targets[s->layers->work],NULL,1,D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR,NULL);return ID2D1RenderTarget_EndDraw(RT(s),NULL,NULL);
}

/* Test-only readback. It is deliberately separate from normal replay costs. */
HRESULT zgpu_layer_pixels(State *s,int front,uint32_t *pixels,uint32_t width,uint32_t height){
    if(!s->layers||width!=s->layers->width||height!=s->layers->height)return E_INVALIDARG;
    if(!front&&!s->drawing)return E_UNEXPECTED;
    HRESULT hr=S_OK;if(s->drawing){hr=ID2D1RenderTarget_Flush(RT(s),NULL,NULL);if(FAILED(hr))return failure(s,hr);}
    IDXGISurface *surface=NULL;ID3D11Texture2D *source=NULL,*staging=NULL;ID3D11DeviceContext *context=NULL;
    ID2D1Bitmap1 *bitmap=front?s->layers->targets[s->layers->front]:gpu_layer_current(s->layers);
    hr=ID2D1Bitmap1_GetSurface(bitmap,&surface);OWN(surface);if(FAILED(hr))goto done;
    hr=IUnknown_QueryInterface((IUnknown *)surface,&IID_ID3D11Texture2D,(void **)&source);OWN(source);if(FAILED(hr))goto done;
    D3D11_TEXTURE2D_DESC desc={0};desc.Width=width;desc.Height=height;desc.MipLevels=desc.ArraySize=desc.SampleDesc.Count=1;
    desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.Usage=D3D11_USAGE_STAGING;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    hr=ID3D11Device_CreateTexture2D(s->d3d,&desc,NULL,&staging);OWN(staging);if(FAILED(hr))goto done;
    ID3D11Device_GetImmediateContext(s->d3d,&context);OWN(context);
    ID3D11DeviceContext_CopyResource(context,(ID3D11Resource *)staging,(ID3D11Resource *)source);
    D3D11_MAPPED_SUBRESOURCE mapped;hr=ID3D11DeviceContext_Map(context,(ID3D11Resource *)staging,0,D3D11_MAP_READ,0,&mapped);
    if(SUCCEEDED(hr)){for(UINT y=0;y<height;y++)memcpy(pixels+(size_t)y*width,(const uint8_t *)mapped.pData+(size_t)y*mapped.RowPitch,(size_t)width*4);ID3D11DeviceContext_Unmap(context,(ID3D11Resource *)staging,0);}
 done:DROP(context);DROP(staging);DROP(source);DROP(surface);return failure(s,hr);
}

void zgpu_layer_fault(State *s,uint32_t plane){s->layer_fault=plane;}
