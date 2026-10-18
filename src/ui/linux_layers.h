/* Included after Renderer. All objects are created by explicit layer prepare;
   ordinary replay only clears and composites these owned targets. */
#include "layer_resource.h"
#include "gaussian_scope.h"
typedef struct CairoGaussian {ZgGaussianCapacity capacity;ZgGaussianFrame frames[4];uint32_t *scratch;uint64_t visits;} CairoGaussian;
typedef struct CairoTarget {cairo_surface_t *surface;cairo_t *context;cairo_pattern_t *pattern;uint32_t saves;double origin[2];} CairoTarget;
typedef struct CairoGroup {ZgLayerGroup group;ZgTransform transform;double clips[33][4];uint32_t clip_depth,kind;} CairoGroup;
struct CairoLayers {
    uint32_t width,height,pool_width,pool_height,capacity,depth,front,work,active,transparent_root,front_transparent;
    float scale;
    CairoTarget targets[6];
    CairoGroup groups[4];
    PangoLayout *layout;
    PangoFontDescription *font;
    ZgLayerStats stats;
    CairoGaussian *gaussian;
};
static uint32_t live_layer_objects;
static void layer_target_drop(CairoTarget *target){
    while(target->saves){cairo_restore(target->context);target->saves--;}
    if(target->pattern){cairo_pattern_destroy(target->pattern);live_layer_objects--;}
    if(target->context){cairo_destroy(target->context);live_layer_objects--;}
    if(target->surface){cairo_surface_destroy(target->surface);live_layer_objects--;}
    memset(target,0,sizeof(*target));
}
void zlc_layer_free(CairoLayers *layer){
    if(!layer)return;
    for(unsigned i=0;i<6;i++)layer_target_drop(&layer->targets[i]);
    if(layer->layout){g_object_unref(layer->layout);live_layer_objects--;}
    if(layer->font){pango_font_description_free(layer->font);live_layer_objects--;}
    if(layer->gaussian){g_free(layer->gaussian->scratch);g_free(layer->gaussian);}
    g_free(layer);
}
static void layer_pattern_scale(CairoLayers *layer,cairo_pattern_t *pattern){cairo_matrix_t matrix;cairo_matrix_init_scale(&matrix,layer->scale,layer->scale);cairo_pattern_set_matrix(pattern,&matrix);}
CairoLayers *zlc_layer_create(uint32_t width,uint32_t height,float scale,uint32_t capacity,uint32_t fault,uint32_t pool_width,uint32_t pool_height){
    CairoLayers *layer=g_try_new0(CairoLayers,1);if(!layer)return NULL;
    layer->width=width;layer->height=height;layer->scale=scale;layer->capacity=capacity;layer->work=1;
    layer->pool_width=pool_width;layer->pool_height=pool_height;
    if(!width||!height||capacity==0||capacity>4||!isfinite(scale)||scale<=0)goto failed;
    for(unsigned i=0;i<capacity+2;i++){
        if(fault==i+1)goto failed;
        CairoTarget *target=&layer->targets[i];
        target->surface=cairo_image_surface_create(CAIRO_FORMAT_ARGB32,(int)(i<2?width:pool_width),(int)(i<2?height:pool_height));live_layer_objects++;layer->stats.native_creations++;
        if(cairo_surface_status(target->surface)!=CAIRO_STATUS_SUCCESS)goto failed;
        target->context=cairo_create(target->surface);live_layer_objects++;layer->stats.native_creations++;
        if(cairo_status(target->context)!=CAIRO_STATUS_SUCCESS)goto failed;
        cairo_scale(target->context,scale,scale);
        target->pattern=cairo_pattern_create_for_surface(target->surface);live_layer_objects++;layer->stats.native_creations++;
        if(cairo_pattern_status(target->pattern)!=CAIRO_STATUS_SUCCESS)goto failed;
        cairo_pattern_set_extend(target->pattern,CAIRO_EXTEND_NONE);layer_pattern_scale(layer,target->pattern);
    }
    layer->layout=pango_cairo_create_layout(layer->targets[0].context);if(!layer->layout)goto failed;live_layer_objects++;layer->stats.native_creations++;
    layer->font=pango_font_description_new();if(!layer->font)goto failed;live_layer_objects++;layer->stats.native_creations++;
    pango_font_description_set_family(layer->font,"Sans");pango_font_description_set_absolute_size(layer->font,16*PANGO_SCALE);
    pango_layout_set_font_description(layer->layout,layer->font);pango_layout_set_single_paragraph_mode(layer->layout,TRUE);pango_layout_set_ellipsize(layer->layout,PANGO_ELLIPSIZE_END);pango_layout_set_height(layer->layout,-1);
    cairo_set_source_rgb(layer->targets[0].context,1,1,1);cairo_paint(layer->targets[0].context);
    layer->stats.native_objects=(capacity+2)*3+2;layer->stats.metadata_bytes=sizeof(*layer);return layer;
failed:zlc_layer_free(layer);return NULL;
}
static CairoTarget *layer_current(CairoLayers *layer){return &layer->targets[layer->depth?layer->depth+1:layer->work];}
static void layer_alias(Renderer *s,CairoTarget *target){s->surface=target->surface;s->context=target->context;s->font=s->layers->font;s->layout=s->layers->layout;memcpy(s->origin,target->origin,sizeof(s->origin));}
static void layer_reset_target(CairoTarget *target){while(target->saves){cairo_restore(target->context);target->saves--;}cairo_reset_clip(target->context);}
static void layer_origin(CairoLayers *layer,CairoTarget *target,double x,double y){
    target->origin[0]=x;target->origin[1]=y;cairo_matrix_t matrix;cairo_matrix_init(&matrix,layer->scale,0,0,layer->scale,x,y);cairo_set_matrix(target->context,&matrix);cairo_pattern_set_matrix(target->pattern,&matrix);
}
static void layer_reset_gradient_clip(Renderer *s){s->gradient_clip_depth=0;s->gradient_clips[0][0]=s->gradient_clips[0][1]=0;s->gradient_clips[0][2]=s->width;s->gradient_clips[0][3]=s->height;}
static void layer_abort(Renderer *s){
    CairoLayers *layer=s->layers;if(!layer||!layer->active)return;
    for(unsigned i=0;i<layer->capacity+2;i++)layer_reset_target(&layer->targets[i]);
    layer->active=0;layer->depth=0;layer->stats.aborted_frames++;layer_alias(s,&layer->targets[layer->front]);layer_reset_gradient_clip(s);
}
static int layer_begin_mode(Renderer *s,uint32_t width,uint32_t height,float scale,int transparent_root){
    CairoLayers *layer=s->layers;if(width!=layer->width||height!=layer->height||scale!=layer->scale)return 3;
    if(layer->active)return layer->transparent_root==(uint32_t)transparent_root?0:4;
    layer->active=1;layer->depth=0;layer->transparent_root=transparent_root;CairoTarget *target=layer_current(layer);layer_reset_target(target);layer_origin(layer,target,0,0);layer_alias(s,target);layer_reset_gradient_clip(s);
    if(layer->gaussian)layer->gaussian->visits=0;
    cairo_save(target->context);cairo_set_operator(target->context,CAIRO_OPERATOR_SOURCE);if(transparent_root)cairo_set_source_rgba(target->context,0,0,0,0);else cairo_set_source_rgb(target->context,1,1,1);cairo_paint(target->context);cairo_restore(target->context);
    layer->stats.clear_pixels+=(uint64_t)width*height;return cairo_status(target->context)==CAIRO_STATUS_SUCCESS?0:2;
}
static int layer_begin(Renderer *s,uint32_t width,uint32_t height,float scale){return layer_begin_mode(s,width,height,scale,0);}
static void layer_box(Renderer *s,const double *rect,uint32_t *box){
    const double width=cairo_image_surface_get_width(s->surface),height=cairo_image_surface_get_height(s->surface);
    box[0]=(uint32_t)fmin(width,fmax(0,floor(rect[0])));box[1]=(uint32_t)fmin(height,fmax(0,floor(rect[1])));
    box[2]=(uint32_t)fmax(box[0],fmin(width,ceil(rect[2])));box[3]=(uint32_t)fmax(box[1],fmin(height,ceil(rect[3])));
}
int zlc_layer_begin_group(Renderer *s,const ZgLayerGroup *group){
    CairoLayers *layer=s->layers;if(!layer||!layer->active||layer->depth>=layer->capacity)return 1;
    CairoGroup *frame=&layer->groups[layer->depth];frame->kind=0;frame->group=*group;frame->clip_depth=s->gradient_clip_depth;memcpy(frame->clips,s->gradient_clips,sizeof(frame->clips));
    const double ox=s->origin[0],oy=s->origin[1];
    const double *parent=s->gradient_clips[s->gradient_clip_depth];double visible[4]={fmax(parent[0],(double)group->x*layer->scale+ox),fmax(parent[1],(double)group->y*layer->scale+oy),fmin(parent[2],((double)group->x+group->width)*layer->scale+ox),fmin(parent[3],((double)group->y+group->height)*layer->scale+oy)};
    uint32_t box[4];layer_box(s,visible,box);layer->depth++;CairoTarget *target=layer_current(layer);layer_reset_target(target);layer_origin(layer,target,ox,oy);layer_alias(s,target);
    cairo_rectangle(target->context,((double)box[0]-ox)/layer->scale,((double)box[1]-oy)/layer->scale,(double)(box[2]-box[0])/layer->scale,(double)(box[3]-box[1])/layer->scale);cairo_clip(target->context);
    cairo_save(target->context);cairo_set_operator(target->context,CAIRO_OPERATOR_SOURCE);cairo_set_source_rgba(target->context,0,0,0,0);cairo_paint(target->context);cairo_restore(target->context);
    s->gradient_clip_depth=0;for(unsigned i=0;i<4;i++)s->gradient_clips[0][i]=box[i];
    layer->stats.groups++;layer->stats.clear_pixels+=(uint64_t)(box[2]-box[0])*(box[3]-box[1]);return cairo_status(target->context)==CAIRO_STATUS_SUCCESS?0:2;
}
int zlc_layer_end_group(Renderer *s){
    CairoLayers *layer=s->layers;if(!layer||!layer->depth||s->gradient_clip_depth||(layer->groups[layer->depth-1].kind!=0&&layer->groups[layer->depth-1].kind!=2))return 1;
    CairoTarget *child=layer_current(layer);CairoGroup *frame=&layer->groups[layer->depth-1];ZgLayerGroup *group=&frame->group;
    double x=group->x,y=group->y,width=group->width,height=group->height;
    if(frame->kind==2){const ZgGaussianCapture *c=&layer->gaussian->frames[layer->depth-1].capture;x=((double)c->left-c->radius)/c->scale;y=((double)c->top-c->radius)/c->scale;width=(double)(c->width+2*c->radius)/c->scale;height=(double)(c->height+2*c->radius)/c->scale;layer_reset_target(child);cairo_surface_mark_dirty_rectangle(child->surface,0,0,(int)(c->width+2*c->radius),(int)(c->height+2*c->radius));}
    if(group->opacity!=255){cairo_save(child->context);cairo_set_operator(child->context,CAIRO_OPERATOR_DEST_IN);cairo_set_source_rgba(child->context,0,0,0,(double)group->opacity/255);cairo_paint(child->context);cairo_restore(child->context);}
    if(cairo_status(child->context)!=CAIRO_STATUS_SUCCESS)return 2;
    layer->depth--;CairoTarget *parent=layer_current(layer);layer_alias(s,parent);s->gradient_clip_depth=frame->clip_depth;memcpy(s->gradient_clips,frame->clips,sizeof(frame->clips));
    cairo_save(parent->context);cairo_rectangle(parent->context,x,y,width,height);cairo_clip(parent->context);cairo_set_source(parent->context,child->pattern);
    if(group->mask_slot!=UINT32_MAX){
        if(group->mask_slot>=ZI_IMAGE_SLOTS||!s->images[group->mask_slot].is_coverage){cairo_restore(parent->context);return 1;}
        cairo_pattern_t *mask=s->images[group->mask_slot].patterns[0][0];cairo_matrix_t matrix;
        cairo_matrix_init(&matrix,group->mask_scale,0,0,group->mask_scale,-(double)group->mask_x*group->mask_scale-group->mask_left,-(double)group->mask_y*group->mask_scale-group->mask_top);cairo_pattern_set_matrix(mask,&matrix);cairo_mask(parent->context,mask);cairo_matrix_init_identity(&matrix);cairo_pattern_set_matrix(mask,&matrix);
    }else cairo_paint(parent->context);
    cairo_restore(parent->context);
    double region[4]={fmax(s->gradient_clips[s->gradient_clip_depth][0],x*layer->scale+s->origin[0]),fmax(s->gradient_clips[s->gradient_clip_depth][1],y*layer->scale+s->origin[1]),fmin(s->gradient_clips[s->gradient_clip_depth][2],(x+width)*layer->scale+s->origin[0]),fmin(s->gradient_clips[s->gradient_clip_depth][3],(y+height)*layer->scale+s->origin[1])};uint32_t box[4];layer_box(s,region,box);layer->stats.composite_pixels+=(uint64_t)(box[2]-box[0])*(box[3]-box[1]);
    return cairo_status(parent->context)==CAIRO_STATUS_SUCCESS?0:2;
}
size_t zlc_gaussian_metadata_bytes(void){return sizeof(CairoGaussian);}
int zlc_layer_release_gaussian(Renderer *s){CairoLayers *layer=s->layers;if(!layer)return 0;if(layer->active)return 1;CairoGaussian *owner=layer->gaussian;if(!owner)return 0;layer->gaussian=NULL;layer->stats.metadata_bytes-=sizeof(*owner);g_free(owner->scratch);g_free(owner);return 0;}
int zlc_layer_prepare_gaussian(CairoLayers *layer,const ZgGaussianCapacity *capacity){
    if(!layer||layer->active||layer->gaussian||!capacity||capacity->scale!=layer->scale||capacity->max_radius>128||capacity->source_width+2*capacity->max_radius>layer->pool_width||capacity->source_height+2*capacity->max_radius>layer->pool_height)return 1;
    CairoGaussian *value=g_try_new0(CairoGaussian,1);if(!value)return 2;
    value->scratch=g_try_malloc_n((size_t)layer->pool_width*layer->pool_height,4);if(!value->scratch){g_free(value);return 2;}
    value->capacity=*capacity;layer->gaussian=value;layer->stats.metadata_bytes+=sizeof(*value);return 0;
}
int zlc_layer_gaussian_capacity(Renderer *s,ZgGaussianCapacity *out){if(!s->layers||!s->layers->gaussian)return 0;*out=s->layers->gaussian->capacity;return 1;}
int zlc_layer_gaussian_active(Renderer *s){return s->layers&&s->layers->depth&&s->layers->groups[s->layers->depth-1].kind==2;}
int zlc_layer_begin_gaussian(Renderer *s,const ZgLayerGroup *group,const ZgGaussianCapture *capture,const ZgGaussianKernel *kernel){
    CairoLayers *layer=s->layers;if(!layer||!layer->active||!layer->gaussian||layer->depth>=layer->capacity||!zg_filter_check(&layer->gaussian->capacity,capture)||capture->radius!=kernel->radius||kernel->scale!=capture->scale)return 1;
    const uint64_t work=zg_filter_samples(capture);if(layer->gaussian->visits>layer->gaussian->capacity.filter_samples-work)return 1;
    const uint32_t depth=layer->depth;CairoGroup *frame=&layer->groups[depth];frame->kind=2;frame->group=*group;frame->clip_depth=s->gradient_clip_depth;memcpy(frame->clips,s->gradient_clips,sizeof(frame->clips));
    layer->gaussian->frames[depth]=(ZgGaussianFrame){*capture,*kernel};layer->gaussian->visits+=work;
    layer->depth++;CairoTarget *target=layer_current(layer);layer_reset_target(target);
    cairo_save(target->context);cairo_identity_matrix(target->context);cairo_set_operator(target->context,CAIRO_OPERATOR_SOURCE);cairo_set_source_rgba(target->context,0,0,0,0);cairo_rectangle(target->context,0,0,capture->width+2*capture->radius,capture->height+2*capture->radius);cairo_fill(target->context);cairo_restore(target->context);
    const double ox=(double)capture->radius-capture->left,oy=(double)capture->radius-capture->top;layer_origin(layer,target,ox,oy);layer_alias(s,target);
    cairo_rectangle(target->context,(double)capture->left/layer->scale,(double)capture->top/layer->scale,(double)capture->width/layer->scale,(double)capture->height/layer->scale);cairo_clip(target->context);
    s->gradient_clip_depth=0;s->gradient_clips[0][0]=s->gradient_clips[0][1]=capture->radius;s->gradient_clips[0][2]=capture->radius+capture->width;s->gradient_clips[0][3]=capture->radius+capture->height;
    layer->stats.groups++;layer->stats.clear_pixels+=(uint64_t)(capture->width+2*capture->radius)*(capture->height+2*capture->radius);return cairo_status(target->context)==CAIRO_STATUS_SUCCESS?0:2;
}
int zlc_layer_gaussian_planes(Renderer *s,GradientSurface *source,GradientSurface *scratch,const ZgGaussianKernel **kernel){
    if(!zlc_layer_gaussian_active(s)||s->gradient_clip_depth)return 1;
    CairoLayers *layer=s->layers;CairoTarget *target=layer_current(layer);cairo_surface_flush(target->surface);if(cairo_surface_status(target->surface)!=CAIRO_STATUS_SUCCESS)return 2;
    const ZgGaussianFrame *frame=&layer->gaussian->frames[layer->depth-1];const uint32_t width=frame->capture.width+2*frame->capture.radius,height=frame->capture.height+2*frame->capture.radius;
    const int stride=cairo_image_surface_get_stride(target->surface);uint8_t *pixels=cairo_image_surface_get_data(target->surface);if(!pixels||stride<=0||stride%4||(uint32_t)(stride/4)<width)return 2;
    *source=(GradientSurface){.pixels=(uint32_t *)pixels,.width=width,.height=height,.stride=(uint32_t)stride/4,.scale=layer->scale};
    *scratch=(GradientSurface){.pixels=layer->gaussian->scratch,.width=width,.height=height,.stride=layer->pool_width,.scale=layer->scale};*kernel=&frame->kernel;return 0;
}
static int layer_end(Renderer *s,cairo_t *destination){
    CairoLayers *layer=s->layers;if(!layer->active)return 1;if(layer->transparent_root)return 4;if(layer->depth){layer_abort(s);return 1;}
    CairoTarget *work=layer_current(layer);if(cairo_status(work->context)!=CAIRO_STATUS_SUCCESS){layer_abort(s);return 2;}
    cairo_save(destination);cairo_scale(destination,1.0/layer->scale,1.0/layer->scale);cairo_matrix_t identity;cairo_matrix_init_identity(&identity);cairo_pattern_set_matrix(work->pattern,&identity);cairo_set_source(destination,work->pattern);cairo_paint(destination);layer_pattern_scale(layer,work->pattern);cairo_restore(destination);
    if(cairo_status(destination)!=CAIRO_STATUS_SUCCESS){layer_abort(s);return 2;}
    uint32_t previous=layer->front;layer->front=layer->work;layer->work=previous;layer->active=0;layer->front_transparent=0;layer->stats.committed_frames++;layer_alias(s,&layer->targets[layer->front]);return 0;
}
int zlc_layer_begin_transform(Renderer *s,const ZgTransform *value){
    CairoLayers *layer=s->layers;if(!layer||!layer->active||layer->depth>=layer->capacity||value->pixel_width+2>layer->pool_width||value->pixel_height+2>layer->pool_height)return 1;
    CairoGroup *frame=&layer->groups[layer->depth];frame->kind=1;frame->transform=*value;frame->clip_depth=s->gradient_clip_depth;memcpy(frame->clips,s->gradient_clips,sizeof(frame->clips));
    layer->depth++;CairoTarget *target=layer_current(layer);layer_reset_target(target);
    cairo_save(target->context);cairo_identity_matrix(target->context);cairo_set_operator(target->context,CAIRO_OPERATOR_SOURCE);cairo_set_source_rgba(target->context,0,0,0,0);cairo_rectangle(target->context,0,0,value->pixel_width+2,value->pixel_height+2);cairo_fill(target->context);cairo_restore(target->context);
    layer_origin(layer,target,1,1);layer_alias(s,target);cairo_rectangle(target->context,0,0,value->source_width,value->source_height);cairo_clip(target->context);
    s->gradient_clip_depth=0;s->gradient_clips[0][0]=s->gradient_clips[0][1]=1;s->gradient_clips[0][2]=1+(double)value->source_width*layer->scale;s->gradient_clips[0][3]=1+(double)value->source_height*layer->scale;
    layer->stats.clear_pixels+=(uint64_t)(value->pixel_width+2)*(value->pixel_height+2);return cairo_status(target->context)==CAIRO_STATUS_SUCCESS?0:2;
}
/* A borrow is synchronous and leaves depth/alias/clips untouched on failure.
   The only intervening operation is the pure bounded Zig raster sampler. */
int zlc_layer_transform_planes(Renderer *s,GradientSurface *source,GradientSurface *destination,ZgTransform *value){
    CairoLayers *layer=s->layers;if(!layer||!layer->active||!layer->depth||s->gradient_clip_depth||layer->groups[layer->depth-1].kind!=1)return 1;
    CairoTarget *child=layer_current(layer),*parent=&layer->targets[layer->depth>1?layer->depth:layer->work];
    const CairoGroup *frame=&layer->groups[layer->depth-1];const ZgTransform *transform=&frame->transform;
    if(frame->clip_depth>32||cairo_status(child->context)!=CAIRO_STATUS_SUCCESS||cairo_status(parent->context)!=CAIRO_STATUS_SUCCESS)return 2;
    cairo_surface_flush(child->surface);cairo_surface_flush(parent->surface);
    if(cairo_surface_status(child->surface)!=CAIRO_STATUS_SUCCESS||cairo_surface_status(parent->surface)!=CAIRO_STATUS_SUCCESS)return 2;
    const int sw=cairo_image_surface_get_width(child->surface),sh=cairo_image_surface_get_height(child->surface),ss=cairo_image_surface_get_stride(child->surface);
    const int dw=cairo_image_surface_get_width(parent->surface),dh=cairo_image_surface_get_height(parent->surface),ds=cairo_image_surface_get_stride(parent->surface);
    uint8_t *sp=cairo_image_surface_get_data(child->surface),*dp=cairo_image_surface_get_data(parent->surface);
    if(!sp||!dp||sp==dp||sw<0||sh<0||dw<=0||dh<=0||ss<=0||ds<=0||ss%4||ds%4||ss/4<sw||ds/4<dw||transform->pixel_width+2>(uint32_t)sw||transform->pixel_height+2>(uint32_t)sh)return 2;
    GradientSurface src={.pixels=(uint32_t *)sp,.width=transform->pixel_width+2,.height=transform->pixel_height+2,.stride=(uint32_t)ss/4,.scale=layer->scale,.origin={child->origin[0],child->origin[1]}};
    GradientSurface dst={.pixels=(uint32_t *)dp,.width=(uint32_t)dw,.height=(uint32_t)dh,.stride=(uint32_t)ds/4,.scale=layer->scale,.origin={parent->origin[0],parent->origin[1]}};
    memcpy(dst.clip,frame->clips[frame->clip_depth],sizeof(dst.clip));
    *source=src;*destination=dst;*value=*transform;return 0;
}
int zlc_layer_finish_transform(Renderer *s,uint64_t visits,uint32_t left,uint32_t top,uint32_t width,uint32_t height){
    CairoLayers *layer=s->layers;if(!layer||!layer->active||!layer->depth||s->gradient_clip_depth||layer->groups[layer->depth-1].kind!=1)return 1;
    CairoTarget *parent=&layer->targets[layer->depth>1?layer->depth:layer->work];
    const uint32_t dw=(uint32_t)cairo_image_surface_get_width(parent->surface),dh=(uint32_t)cairo_image_surface_get_height(parent->surface);
    if(left>dw||top>dh||width>dw-left||height>dh-top||visits!=(uint64_t)width*height)return 1;
    if(width&&height)cairo_surface_mark_dirty_rectangle(parent->surface,(int)left,(int)top,(int)width,(int)height);
    if(cairo_surface_status(parent->surface)!=CAIRO_STATUS_SUCCESS)return 2;
    const CairoGroup *frame=&layer->groups[layer->depth-1];layer->depth--;layer_alias(s,parent);s->gradient_clip_depth=frame->clip_depth;memcpy(s->gradient_clips,frame->clips,sizeof(frame->clips));
    layer->stats.composite_pixels+=visits;return 0;
}
void zlc_layer_stats(Renderer *s,ZgLayerStats *out){*out=s->layers?s->layers->stats:(ZgLayerStats){0};}
int zlc_layer_transparent(Renderer *s){return s->layers&&s->layers->active&&(s->layers->depth||s->layers->transparent_root);}
size_t zlc_layer_metadata_bytes(void){return sizeof(Renderer)+sizeof(CairoLayers);}
int zlc_offscreen_prepare(Renderer *s){
    if(!s->layers||s->layers->active)return 1;
    cairo_font_options_t *options=cairo_font_options_create();if(cairo_font_options_status(options)!=CAIRO_STATUS_SUCCESS){cairo_font_options_destroy(options);return 2;}
    cairo_font_options_set_antialias(options,CAIRO_ANTIALIAS_GRAY);
    for(uint32_t i=0;i<s->layers->capacity+2;i++)cairo_set_font_options(s->layers->targets[i].context,options);
    pango_cairo_context_set_font_options(pango_layout_get_context(s->layers->layout),options);pango_layout_context_changed(s->layers->layout);cairo_font_options_destroy(options);return 0;
}
int zlc_offscreen_begin(Renderer *s){
    if(!s->layers||s->layers->active)return 1;
    return layer_begin_mode(s,s->width,s->height,s->scale,1);
}
int zlc_offscreen_end(Renderer *s,uint8_t *output,size_t length){
    CairoLayers *layer=s->layers;if(!layer||!layer->active)return 1;if(!layer->transparent_root)return 4;if(layer->depth||s->gradient_clip_depth)return 1;
    if(length!=(size_t)s->width*s->height*4)return 1;
    CairoTarget *work=layer_current(layer);if(cairo_status(work->context)!=CAIRO_STATUS_SUCCESS){layer_abort(s);return 2;}
    cairo_surface_flush(work->surface);if(cairo_surface_status(work->surface)!=CAIRO_STATUS_SUCCESS){layer_abort(s);return 2;}
    const unsigned char *data=cairo_image_surface_get_data(work->surface);size_t stride=(size_t)cairo_image_surface_get_stride(work->surface);
    for(uint32_t y=0;y<s->height;y++)memcpy(output+(size_t)y*s->width*4,data+(size_t)y*stride,(size_t)s->width*4);
    uint32_t previous=layer->front;layer->front=layer->work;layer->work=previous;layer->active=0;layer->front_transparent=1;layer->stats.committed_frames++;layer_alias(s,&layer->targets[layer->front]);return 0;
}
uint32_t zlc_test_live_layer_objects(void){return live_layer_objects;}

uint32_t zlc_layer_test_pixel(Renderer *s,int front,uint32_t x,uint32_t y){
    if(!s->layers||x>=s->width||y>=s->height)return 0;
    CairoTarget *target=front?&s->layers->targets[s->layers->front]:layer_current(s->layers);
    cairo_surface_flush(target->surface);const unsigned char *data=cairo_image_surface_get_data(target->surface);int stride=cairo_image_surface_get_stride(target->surface);uint32_t result;memcpy(&result,data+(size_t)y*stride+(size_t)x*4,4);return result;
}
uint32_t zlc_layer_live_objects(void){return live_layer_objects;}
