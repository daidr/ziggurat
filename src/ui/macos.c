/* The macOS software renderer: the same `zlc_*` ABI as linux.c, drawn with
   Core Graphics into owned premultiplied BGRA bitmaps. Every context's user
   space is y-down; images are drawn through draw_image, which undoes the
   bottom-up image orientation. CPU stages (gradients, Gaussian filters,
   transforms) read and write the bitmap memory directly: bitmap contexts
   draw synchronously, so no flush or dirty marking is needed. */
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <float.h>
#include <string.h>
#include "brushes.h"
#include "image_resource.h"
#include "coverage_resource.h"
#include "layer_resource.h"
#include "gaussian_scope.h"

typedef struct GradientSurface {uint32_t *pixels;uint32_t width,height,stride;float scale;double clip[4],origin[2];} GradientSurface;
#if UINTPTR_MAX == UINT64_MAX
_Static_assert(sizeof(GradientSurface)==72,"software plane ABI");
_Static_assert(offsetof(GradientSurface,clip)==24&&offsetof(GradientSurface,origin)==56,"software plane offsets");
#endif
#define BITMAP_INFO ((CGBitmapInfo)kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little)

static CGColorSpaceRef rgb_space(void){static CGColorSpaceRef space;if(!space)space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);return space;}
static CGColorSpaceRef gray_space(void){static CGColorSpaceRef space;if(!space)space=CGColorSpaceCreateDeviceGray();return space;}

/* An owned bitmap and its context. The context keeps one saved base state
   (identity transform, no clip) that target_reset returns to. */
typedef struct Target {CGContextRef context;uint8_t *pixels;uint32_t width,height;size_t stride;uint32_t saves;double origin[2];} Target;
static int target_create(Target *t,uint32_t width,uint32_t height){
    memset(t,0,sizeof(*t));
    if(!width||!height||width>32768||height>32768)return 1;
    t->stride=((size_t)width*4+15)&~(size_t)15;
    t->pixels=calloc(height,t->stride);if(!t->pixels)return 2;
    t->context=CGBitmapContextCreate(t->pixels,width,height,8,t->stride,rgb_space(),BITMAP_INFO);
    if(!t->context){free(t->pixels);t->pixels=NULL;return 2;}
    t->width=width;t->height=height;CGContextSaveGState(t->context);return 0;
}
static void target_drop(Target *t){
    if(t->context){while(t->saves){CGContextRestoreGState(t->context);t->saves--;}CGContextRestoreGState(t->context);CGContextRelease(t->context);}
    free(t->pixels);memset(t,0,sizeof(*t));
}
static void target_reset(Target *t){while(t->saves){CGContextRestoreGState(t->context);t->saves--;}CGContextRestoreGState(t->context);CGContextSaveGState(t->context);}
/* User space maps to y-down device pixels as scale*p+origin. */
static void target_matrix(Target *t,double scale,double x,double y){
    CGContextConcatCTM(t->context,CGAffineTransformInvert(CGContextGetCTM(t->context)));
    CGContextTranslateCTM(t->context,0,t->height);CGContextScaleCTM(t->context,1,-1);
    CGContextTranslateCTM(t->context,x,y);CGContextScaleCTM(t->context,scale,scale);
    t->origin[0]=x;t->origin[1]=y;
}
static void target_clear(Target *t,uint32_t left,uint32_t top,uint32_t right,uint32_t bottom,uint8_t value){
    if(right>t->width)right=t->width;if(bottom>t->height)bottom=t->height;
    for(uint32_t y=top;y<bottom&&left<right;y++)memset(t->pixels+(size_t)y*t->stride+(size_t)left*4,value,(size_t)(right-left)*4);
}
static void draw_image(CGContextRef context,CGImageRef image,CGRect rect){
    CGContextSaveGState(context);CGContextTranslateCTM(context,rect.origin.x,rect.origin.y+rect.size.height);CGContextScaleCTM(context,1,-1);
    CGContextDrawImage(context,CGRectMake(0,0,rect.size.width,rect.size.height),image);CGContextRestoreGState(context);
}
/* Clips to the gray mask's samples over rect; the clip lasts until the
   caller restores its saved state. */
static void clip_mask(CGContextRef context,CGImageRef mask,CGRect rect){
    CGContextTranslateCTM(context,rect.origin.x,rect.origin.y+rect.size.height);CGContextScaleCTM(context,1,-1);
    CGContextClipToMask(context,CGRectMake(0,0,rect.size.width,rect.size.height),mask);
    CGContextScaleCTM(context,1,-1);CGContextTranslateCTM(context,-rect.origin.x,-(rect.origin.y+rect.size.height));
}
static void set_rgba(CGContextRef context,uint32_t rgba){CGContextSetRGBFillColor(context,(double)(rgba>>24)/255,(double)((rgba>>16)&255)/255,(double)((rgba>>8)&255)/255,(double)(rgba&255)/255);}

typedef struct CachedImage {CGImageRef images[2][ZI_IMAGE_LEVELS];uint8_t *pool[2];const ZiImageLevel *levels;ZiImageLevel coverage_level;uint32_t count,dynamic,active,is_coverage;} CachedImage;
static uint32_t live_image_objects;
static CGImageRef make_image(const uint8_t *pixels,uint32_t width,uint32_t height,size_t stride,int coverage){
    CGDataProviderRef provider=CGDataProviderCreateWithData(NULL,pixels,stride*height,NULL);if(!provider)return NULL;
    CGImageRef image=CGImageCreate(width,height,8,coverage?8:32,stride,coverage?gray_space():rgb_space(),coverage?(CGBitmapInfo)kCGImageAlphaNone:BITMAP_INFO,provider,NULL,false,kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);if(image)live_image_objects++;return image;
}
static void drop_image(CachedImage *image){for(unsigned bank=0;bank<2;bank++){for(uint32_t i=0;i<image->count;i++)if(image->images[bank][i]){CGImageRelease(image->images[bank][i]);live_image_objects--;}free(image->pool[bank]);}memset(image,0,sizeof(*image));}

typedef struct Layers Layers;
typedef struct Renderer {
    Target own;
    Target *target;
    CTFontRef font;
    char font_family[128];
    float font_size;
    uint16_t font_weight;
    int font_italic,font_monospace;
    uint32_t width,height;
    float scale;
    double origin[2];
    uint32_t generation;
    double gradient_clips[33][4];
    uint32_t gradient_clip_depth;
    CachedImage *images;
    uint32_t image_capacity;
    CachedImage image_candidate;
    uint32_t image_fault;
    uint64_t image_creations;
    uint64_t coverage_creations;
    Layers *layers;
    /* The window frame starts transparent and is presented with its alpha
       (Paint.transparent), not over an opaque white plane. */
    int window_transparent,keep_plane;
} Renderer;

typedef struct LayerGaussian {ZgGaussianCapacity capacity;ZgGaussianFrame frames[4];uint32_t *scratch;uint64_t visits;} LayerGaussian;
typedef struct LayerGroup {ZgLayerGroup group;ZgTransform transform;double clips[33][4];uint32_t clip_depth,kind;} LayerGroup;
struct Layers {
    uint32_t width,height,pool_width,pool_height,capacity,depth,front,work,active,transparent_root,front_transparent;
    float scale;
    Target targets[6];
    LayerGroup groups[4];
    ZgLayerStats stats;
    LayerGaussian *gaussian;
};
static uint32_t live_layer_objects;
static void layer_target_drop(Target *target){if(target->context)live_layer_objects-=2;target_drop(target);}
void zlc_layer_free(Layers *layer){
    if(!layer)return;
    for(unsigned i=0;i<6;i++)layer_target_drop(&layer->targets[i]);
    if(layer->gaussian){free(layer->gaussian->scratch);free(layer->gaussian);}
    free(layer);
}
Layers *zlc_layer_create(uint32_t width,uint32_t height,float scale,uint32_t capacity,uint32_t fault,uint32_t pool_width,uint32_t pool_height){
    Layers *layer=calloc(1,sizeof(Layers));if(!layer)return NULL;
    layer->width=width;layer->height=height;layer->scale=scale;layer->capacity=capacity;layer->work=1;
    layer->pool_width=pool_width;layer->pool_height=pool_height;
    if(!width||!height||capacity==0||capacity>4||!isfinite(scale)||scale<=0)goto failed;
    for(unsigned i=0;i<capacity+2;i++){
        if(fault==i+1)goto failed;
        Target *target=&layer->targets[i];
        if(target_create(target,i<2?width:pool_width,i<2?height:pool_height))goto failed;
        live_layer_objects+=2;layer->stats.native_creations+=2;target_matrix(target,scale,0,0);
    }
    target_clear(&layer->targets[0],0,0,width,height,255);
    layer->stats.native_objects=(capacity+2)*2;layer->stats.metadata_bytes=sizeof(*layer);return layer;
failed:zlc_layer_free(layer);return NULL;
}
static Target *layer_current(Layers *layer){return &layer->targets[layer->depth?layer->depth+1:layer->work];}
static void layer_alias(Renderer *s,Target *target){s->target=target;memcpy(s->origin,target->origin,sizeof(s->origin));}
static void layer_origin(Layers *layer,Target *target,double x,double y){target_matrix(target,layer->scale,x,y);}
static void layer_reset_gradient_clip(Renderer *s){s->gradient_clip_depth=0;s->gradient_clips[0][0]=s->gradient_clips[0][1]=0;s->gradient_clips[0][2]=s->width;s->gradient_clips[0][3]=s->height;}
static void layer_abort(Renderer *s){
    Layers *layer=s->layers;if(!layer||!layer->active)return;
    for(unsigned i=0;i<layer->capacity+2;i++)target_reset(&layer->targets[i]);
    layer->active=0;layer->depth=0;layer->stats.aborted_frames++;layer_alias(s,&layer->targets[layer->front]);layer_reset_gradient_clip(s);
}
static int layer_begin_mode(Renderer *s,uint32_t width,uint32_t height,float scale,int transparent_root){
    Layers *layer=s->layers;if(width!=layer->width||height!=layer->height||scale!=layer->scale)return 3;
    if(layer->active)return layer->transparent_root==(uint32_t)transparent_root?0:4;
    layer->active=1;layer->depth=0;layer->transparent_root=transparent_root;Target *target=layer_current(layer);target_reset(target);layer_origin(layer,target,0,0);layer_alias(s,target);layer_reset_gradient_clip(s);
    if(layer->gaussian)layer->gaussian->visits=0;
    target_clear(target,0,0,target->width,target->height,transparent_root||s->window_transparent?0:255);
    layer->stats.clear_pixels+=(uint64_t)width*height;return 0;
}
static int layer_begin(Renderer *s,uint32_t width,uint32_t height,float scale){return layer_begin_mode(s,width,height,scale,0);}
static void layer_box(Renderer *s,const double *rect,uint32_t *box){
    const double width=s->target->width,height=s->target->height;
    box[0]=(uint32_t)fmin(width,fmax(0,floor(rect[0])));box[1]=(uint32_t)fmin(height,fmax(0,floor(rect[1])));
    box[2]=(uint32_t)fmax(box[0],fmin(width,ceil(rect[2])));box[3]=(uint32_t)fmax(box[1],fmin(height,ceil(rect[3])));
}
/* Composites child over parent in parent user space, as the child's
   pixels map to device pixels through its own origin. */
static int layer_composite(Layers *layer,Target *child,Target *parent){
    CGImageRef image=CGBitmapContextCreateImage(child->context);if(!image)return 2;
    draw_image(parent->context,image,CGRectMake(-child->origin[0]/layer->scale,-child->origin[1]/layer->scale,(double)child->width/layer->scale,(double)child->height/layer->scale));
    CGImageRelease(image);return 0;
}
int zlc_layer_begin_group(Renderer *s,const ZgLayerGroup *group){
    Layers *layer=s->layers;if(!layer||!layer->active||layer->depth>=layer->capacity)return 1;
    LayerGroup *frame=&layer->groups[layer->depth];frame->kind=0;frame->group=*group;frame->clip_depth=s->gradient_clip_depth;memcpy(frame->clips,s->gradient_clips,sizeof(frame->clips));
    const double ox=s->origin[0],oy=s->origin[1];
    const double *parent=s->gradient_clips[s->gradient_clip_depth];double visible[4]={fmax(parent[0],(double)group->x*layer->scale+ox),fmax(parent[1],(double)group->y*layer->scale+oy),fmin(parent[2],((double)group->x+group->width)*layer->scale+ox),fmin(parent[3],((double)group->y+group->height)*layer->scale+oy)};
    uint32_t box[4];layer_box(s,visible,box);layer->depth++;Target *target=layer_current(layer);target_reset(target);layer_origin(layer,target,ox,oy);layer_alias(s,target);
    CGContextClipToRect(target->context,CGRectMake(((double)box[0]-ox)/layer->scale,((double)box[1]-oy)/layer->scale,(double)(box[2]-box[0])/layer->scale,(double)(box[3]-box[1])/layer->scale));
    target_clear(target,box[0],box[1],box[2],box[3],0);
    s->gradient_clip_depth=0;for(unsigned i=0;i<4;i++)s->gradient_clips[0][i]=box[i];
    layer->stats.groups++;layer->stats.clear_pixels+=(uint64_t)(box[2]-box[0])*(box[3]-box[1]);return 0;
}
int zlc_layer_end_group(Renderer *s){
    Layers *layer=s->layers;if(!layer||!layer->depth||s->gradient_clip_depth||(layer->groups[layer->depth-1].kind!=0&&layer->groups[layer->depth-1].kind!=2))return 1;
    Target *child=layer_current(layer);LayerGroup *frame=&layer->groups[layer->depth-1];ZgLayerGroup *group=&frame->group;
    double x=group->x,y=group->y,width=group->width,height=group->height;
    if(frame->kind==2){const ZgGaussianCapture *c=&layer->gaussian->frames[layer->depth-1].capture;x=((double)c->left-c->radius)/c->scale;y=((double)c->top-c->radius)/c->scale;width=(double)(c->width+2*c->radius)/c->scale;height=(double)(c->height+2*c->radius)/c->scale;target_reset(child);layer_origin(layer,child,child->origin[0],child->origin[1]);}
    if(group->opacity!=255){CGContextSaveGState(child->context);CGContextSetBlendMode(child->context,kCGBlendModeDestinationIn);CGContextSetRGBFillColor(child->context,0,0,0,(double)group->opacity/255);CGContextFillRect(child->context,CGContextGetClipBoundingBox(child->context));CGContextRestoreGState(child->context);}
    if(group->mask_slot!=UINT32_MAX&&(group->mask_slot>=s->image_capacity||!s->images[group->mask_slot].is_coverage))return 1;
    layer->depth--;Target *parent=layer_current(layer);layer_alias(s,parent);s->gradient_clip_depth=frame->clip_depth;memcpy(s->gradient_clips,frame->clips,sizeof(frame->clips));
    CGContextSaveGState(parent->context);CGContextClipToRect(parent->context,CGRectMake(x,y,width,height));
    if(group->mask_slot!=UINT32_MAX){
        CGImageRef mask=s->images[group->mask_slot].images[0][0];
        clip_mask(parent->context,mask,CGRectMake((double)group->mask_x+(double)group->mask_left/group->mask_scale,(double)group->mask_y+(double)group->mask_top/group->mask_scale,(double)CGImageGetWidth(mask)/group->mask_scale,(double)CGImageGetHeight(mask)/group->mask_scale));
    }
    int status=layer_composite(layer,child,parent);
    CGContextRestoreGState(parent->context);
    double region[4]={fmax(s->gradient_clips[s->gradient_clip_depth][0],x*layer->scale+s->origin[0]),fmax(s->gradient_clips[s->gradient_clip_depth][1],y*layer->scale+s->origin[1]),fmin(s->gradient_clips[s->gradient_clip_depth][2],(x+width)*layer->scale+s->origin[0]),fmin(s->gradient_clips[s->gradient_clip_depth][3],(y+height)*layer->scale+s->origin[1])};uint32_t box[4];layer_box(s,region,box);layer->stats.composite_pixels+=(uint64_t)(box[2]-box[0])*(box[3]-box[1]);
    return status;
}
size_t zlc_gaussian_metadata_bytes(void){return sizeof(LayerGaussian);}
int zlc_layer_release_gaussian(Renderer *s){Layers *layer=s->layers;if(!layer)return 0;if(layer->active)return 1;LayerGaussian *owner=layer->gaussian;if(!owner)return 0;layer->gaussian=NULL;layer->stats.metadata_bytes-=sizeof(*owner);free(owner->scratch);free(owner);return 0;}
int zlc_layer_prepare_gaussian(Layers *layer,const ZgGaussianCapacity *capacity){
    if(!layer||layer->active||layer->gaussian||!capacity||capacity->scale!=layer->scale||capacity->max_radius>128||capacity->source_width+2*capacity->max_radius>layer->pool_width||capacity->source_height+2*capacity->max_radius>layer->pool_height)return 1;
    LayerGaussian *value=calloc(1,sizeof(LayerGaussian));if(!value)return 2;
    value->scratch=calloc((size_t)layer->pool_width*layer->pool_height,4);if(!value->scratch){free(value);return 2;}
    value->capacity=*capacity;layer->gaussian=value;layer->stats.metadata_bytes+=sizeof(*value);return 0;
}
int zlc_layer_gaussian_capacity(Renderer *s,ZgGaussianCapacity *out){if(!s->layers||!s->layers->gaussian)return 0;*out=s->layers->gaussian->capacity;return 1;}
int zlc_layer_gaussian_active(Renderer *s){return s->layers&&s->layers->depth&&s->layers->groups[s->layers->depth-1].kind==2;}
int zlc_layer_begin_gaussian(Renderer *s,const ZgLayerGroup *group,const ZgGaussianCapture *capture,const ZgGaussianKernel *kernel){
    Layers *layer=s->layers;if(!layer||!layer->active||!layer->gaussian||layer->depth>=layer->capacity||!zg_filter_check(&layer->gaussian->capacity,capture)||capture->radius!=kernel->radius||kernel->scale!=capture->scale)return 1;
    const uint64_t work=zg_filter_samples(capture);if(layer->gaussian->visits>layer->gaussian->capacity.filter_samples-work)return 1;
    const uint32_t depth=layer->depth;LayerGroup *frame=&layer->groups[depth];frame->kind=2;frame->group=*group;frame->clip_depth=s->gradient_clip_depth;memcpy(frame->clips,s->gradient_clips,sizeof(frame->clips));
    layer->gaussian->frames[depth]=(ZgGaussianFrame){*capture,*kernel};layer->gaussian->visits+=work;
    layer->depth++;Target *target=layer_current(layer);target_reset(target);
    target_clear(target,0,0,capture->width+2*capture->radius,capture->height+2*capture->radius,0);
    const double ox=(double)capture->radius-capture->left,oy=(double)capture->radius-capture->top;layer_origin(layer,target,ox,oy);layer_alias(s,target);
    CGContextClipToRect(target->context,CGRectMake((double)capture->left/layer->scale,(double)capture->top/layer->scale,(double)capture->width/layer->scale,(double)capture->height/layer->scale));
    s->gradient_clip_depth=0;s->gradient_clips[0][0]=s->gradient_clips[0][1]=capture->radius;s->gradient_clips[0][2]=capture->radius+capture->width;s->gradient_clips[0][3]=capture->radius+capture->height;
    layer->stats.groups++;layer->stats.clear_pixels+=(uint64_t)(capture->width+2*capture->radius)*(capture->height+2*capture->radius);return 0;
}
int zlc_layer_gaussian_planes(Renderer *s,GradientSurface *source,GradientSurface *scratch,const ZgGaussianKernel **kernel){
    if(!zlc_layer_gaussian_active(s)||s->gradient_clip_depth)return 1;
    Layers *layer=s->layers;Target *target=layer_current(layer);
    const ZgGaussianFrame *frame=&layer->gaussian->frames[layer->depth-1];const uint32_t width=frame->capture.width+2*frame->capture.radius,height=frame->capture.height+2*frame->capture.radius;
    if(target->stride/4<width||target->height<height)return 2;
    *source=(GradientSurface){.pixels=(uint32_t *)target->pixels,.width=width,.height=height,.stride=(uint32_t)(target->stride/4),.scale=layer->scale};
    *scratch=(GradientSurface){.pixels=layer->gaussian->scratch,.width=width,.height=height,.stride=layer->pool_width,.scale=layer->scale};*kernel=&frame->kernel;return 0;
}
static int layer_end(Renderer *s,CGContextRef destination){
    Layers *layer=s->layers;if(!layer->active)return 1;if(layer->transparent_root)return 4;if(layer->depth){layer_abort(s);return 1;}
    Target *work=layer_current(layer);
    CGImageRef image=CGBitmapContextCreateImage(work->context);if(!image){layer_abort(s);return 2;}
    draw_image(destination,image,CGRectMake(0,0,(double)work->width/layer->scale,(double)work->height/layer->scale));CGImageRelease(image);
    uint32_t previous=layer->front;layer->front=layer->work;layer->work=previous;layer->active=0;layer->front_transparent=0;layer->stats.committed_frames++;layer_alias(s,&layer->targets[layer->front]);return 0;
}
int zlc_layer_begin_transform(Renderer *s,const ZgTransform *value){
    Layers *layer=s->layers;if(!layer||!layer->active||layer->depth>=layer->capacity||value->pixel_width+2>layer->pool_width||value->pixel_height+2>layer->pool_height)return 1;
    LayerGroup *frame=&layer->groups[layer->depth];frame->kind=1;frame->transform=*value;frame->clip_depth=s->gradient_clip_depth;memcpy(frame->clips,s->gradient_clips,sizeof(frame->clips));
    layer->depth++;Target *target=layer_current(layer);target_reset(target);
    target_clear(target,0,0,value->pixel_width+2,value->pixel_height+2,0);
    layer_origin(layer,target,1,1);layer_alias(s,target);CGContextClipToRect(target->context,CGRectMake(0,0,value->source_width,value->source_height));
    s->gradient_clip_depth=0;s->gradient_clips[0][0]=s->gradient_clips[0][1]=1;s->gradient_clips[0][2]=1+(double)value->source_width*layer->scale;s->gradient_clips[0][3]=1+(double)value->source_height*layer->scale;
    layer->stats.clear_pixels+=(uint64_t)(value->pixel_width+2)*(value->pixel_height+2);return 0;
}
/* A borrow is synchronous and leaves depth/alias/clips untouched on failure.
   The only intervening operation is the pure bounded Zig raster sampler. */
int zlc_layer_transform_planes(Renderer *s,GradientSurface *source,GradientSurface *destination,ZgTransform *value){
    Layers *layer=s->layers;if(!layer||!layer->active||!layer->depth||s->gradient_clip_depth||layer->groups[layer->depth-1].kind!=1)return 1;
    Target *child=layer_current(layer),*parent=&layer->targets[layer->depth>1?layer->depth:layer->work];
    const LayerGroup *frame=&layer->groups[layer->depth-1];const ZgTransform *transform=&frame->transform;
    if(frame->clip_depth>32||!child->pixels||!parent->pixels||child==parent||transform->pixel_width+2>child->width||transform->pixel_height+2>child->height)return 2;
    GradientSurface src={.pixels=(uint32_t *)child->pixels,.width=transform->pixel_width+2,.height=transform->pixel_height+2,.stride=(uint32_t)(child->stride/4),.scale=layer->scale,.origin={child->origin[0],child->origin[1]}};
    GradientSurface dst={.pixels=(uint32_t *)parent->pixels,.width=parent->width,.height=parent->height,.stride=(uint32_t)(parent->stride/4),.scale=layer->scale,.origin={parent->origin[0],parent->origin[1]}};
    memcpy(dst.clip,frame->clips[frame->clip_depth],sizeof(dst.clip));
    *source=src;*destination=dst;*value=*transform;return 0;
}
int zlc_layer_finish_transform(Renderer *s,uint64_t visits,uint32_t left,uint32_t top,uint32_t width,uint32_t height){
    Layers *layer=s->layers;if(!layer||!layer->active||!layer->depth||s->gradient_clip_depth||layer->groups[layer->depth-1].kind!=1)return 1;
    Target *parent=&layer->targets[layer->depth>1?layer->depth:layer->work];
    if(left>parent->width||top>parent->height||width>parent->width-left||height>parent->height-top||visits!=(uint64_t)width*height)return 1;
    const LayerGroup *frame=&layer->groups[layer->depth-1];layer->depth--;layer_alias(s,parent);s->gradient_clip_depth=frame->clip_depth;memcpy(s->gradient_clips,frame->clips,sizeof(frame->clips));
    layer->stats.composite_pixels+=visits;return 0;
}
void zlc_layer_stats(Renderer *s,ZgLayerStats *out){*out=s->layers?s->layers->stats:(ZgLayerStats){0};}
int zlc_layer_transparent(Renderer *s){return s->layers&&s->layers->active?(s->layers->depth||s->layers->transparent_root||s->window_transparent):s->window_transparent;}
size_t zlc_layer_metadata_bytes(void){return sizeof(Renderer)+sizeof(Layers);}
int zlc_offscreen_prepare(Renderer *s){
    if(!s->layers||s->layers->active)return 1;
    for(uint32_t i=0;i<s->layers->capacity+2;i++){CGContextSetAllowsFontSmoothing(s->layers->targets[i].context,false);CGContextSetShouldSmoothFonts(s->layers->targets[i].context,false);}
    return 0;
}
int zlc_offscreen_begin(Renderer *s){
    if(!s->layers||s->layers->active)return 1;
    return layer_begin_mode(s,s->width,s->height,s->scale,1);
}
int zlc_offscreen_end(Renderer *s,uint8_t *output,size_t length){
    Layers *layer=s->layers;if(!layer||!layer->active)return 1;if(!layer->transparent_root)return 4;if(layer->depth||s->gradient_clip_depth)return 1;
    if(length!=(size_t)s->width*s->height*4)return 1;
    Target *work=layer_current(layer);
    for(uint32_t y=0;y<s->height;y++)memcpy(output+(size_t)y*s->width*4,work->pixels+(size_t)y*work->stride,(size_t)s->width*4);
    uint32_t previous=layer->front;layer->front=layer->work;layer->work=previous;layer->active=0;layer->front_transparent=1;layer->stats.committed_frames++;layer_alias(s,&layer->targets[layer->front]);return 0;
}
uint32_t zlc_test_live_layer_objects(void){return live_layer_objects;}
uint32_t zlc_layer_test_pixel(Renderer *s,int front,uint32_t x,uint32_t y){
    if(!s->layers||x>=s->width||y>=s->height)return 0;
    Target *target=front?&s->layers->targets[s->layers->front]:layer_current(s->layers);
    uint32_t result;memcpy(&result,target->pixels+(size_t)y*target->stride+(size_t)x*4,4);return result;
}
uint32_t zlc_layer_live_objects(void){return live_layer_objects;}

static void destroy(Renderer *s){
    if(s->layers){zlc_layer_free(s->layers);s->layers=NULL;s->target=NULL;return;}
    target_drop(&s->own);s->target=NULL;
}
int zlc_layer_copy_front(Renderer *s,Layers *candidate){
    if(!s->target||s->width!=candidate->width||s->height!=candidate->height||s->scale!=candidate->scale)return 0;
    Target *target=&candidate->targets[candidate->front];
    for(uint32_t y=0;y<s->height;y++)memcpy(target->pixels+(size_t)y*target->stride,s->target->pixels+(size_t)y*s->target->stride,(size_t)s->width*4);
    candidate->front_transparent=s->layers?s->layers->front_transparent:0;
    return 0;
}
void zlc_layer_commit(Renderer *s,Layers *candidate){destroy(s);s->layers=candidate;s->width=candidate->width;s->height=candidate->height;s->scale=candidate->scale;s->generation++;layer_alias(s,&candidate->targets[candidate->front]);layer_reset_gradient_clip(s);}
int zlc_layer_release(Renderer *s){
    Layers *layer=s->layers;if(!layer)return 0;if(layer->active)return 1;if(layer->front_transparent)return 2;
    Target front=layer->targets[layer->front];target_reset(&front);front.saves=0;memset(&layer->targets[layer->front],0,sizeof(front));
    /* The front bitmap and context become the ordinary renderer's plane. */
    live_layer_objects-=2;s->own=front;s->target=&s->own;s->layers=NULL;zlc_layer_free(layer);
    target_matrix(&s->own,s->scale,0,0);memcpy(s->origin,s->own.origin,sizeof(s->origin));layer_reset_gradient_clip(s);return 0;
}
void zlc_layer_abort(Renderer *s){layer_abort(s);}
Renderer *zlc_create(void){return calloc(1,sizeof(Renderer));}
int zlc_has_surface(Renderer *s){return s&&s->target&&s->target->context;}
static int begin_plane(Renderer *s,uint32_t width,uint32_t height,float scale){
    if(s->layers)return layer_begin(s,width,height,scale);
    if(!width||!height||!isfinite(scale)||scale<=0)return 1;
    if(s->target&&s->width==width&&s->height==height&&s->scale==scale){
        /* A transparent frame starts clear, unless it redraws only the
           damaged rectangles of the plane it keeps (mode 2). */
        if(s->window_transparent&&!s->keep_plane)target_clear(&s->own,0,0,width,height,0);
        return 0;
    }
    destroy(s);
    if(target_create(&s->own,width,height)){destroy(s);return 2;}
    s->target=&s->own;
    /* The renderer owns an opaque window plane. Initialize it once, including
       when the first frame contains only translucent shapes or gradients. A
       transparent one starts clear. */
    target_clear(&s->own,0,0,width,height,s->window_transparent?0:255);
    target_matrix(&s->own,scale,0,0);
    s->width=width;s->height=height;s->scale=scale;s->generation++;s->origin[0]=s->origin[1]=0;
    s->gradient_clip_depth=0;s->gradient_clips[0][0]=s->gradient_clips[0][1]=0;s->gradient_clips[0][2]=width;s->gradient_clips[0][3]=height;return 0;
}
/* A transparent window plane starts clear and is drawn over what the view
   shows behind it, which AppKit clears: the desktop through a clear
   window, or a material. */
/* transparent: 0 opaque, 1 transparent and cleared, 2 transparent with the
   plane's pixels kept for a redraw of its damaged rectangles. */
int zlc_begin_mode(Renderer *s,uint32_t width,uint32_t height,float scale,int transparent){
    s->window_transparent=transparent!=0;s->keep_plane=transparent==2;
    return begin_plane(s,width,height,scale);
}
int zlc_begin(Renderer *s,uint32_t width,uint32_t height,float scale){return zlc_begin_mode(s,width,height,scale,0);}
void zlc_fill(Renderer *s,float x,float y,float width,float height,uint32_t color){
    CGContextRef c=s->target->context;
    CGContextSetRGBFillColor(c,(double)((color>>16)&255)/255,(double)((color>>8)&255)/255,(double)(color&255)/255,1);
    CGContextFillRect(c,CGRectMake(x,y,width,height));
}
static void rounded_path(CGMutablePathRef path,double x,double y,double w,double h,double r){
    if(w<0){x+=w;w=-w;}if(h<0){y+=h;h=-h;}
    r=fmin(r,fmin(w,h)/2);
    if(r<=0)CGPathAddRect(path,NULL,CGRectMake(x,y,w,h));else CGPathAddRoundedRect(path,NULL,CGRectMake(x,y,w,h),r,r);
}
int zlc_shape(Renderer *s,float x,float y,float width,float height,float radius,float stroke,uint32_t rgba){
    if(width==0||height==0||(rgba&255)==0)return 0;
    CGContextRef c=s->target->context;CGMutablePathRef path=CGPathCreateMutable();if(!path)return 1;
    rounded_path(path,x,y,width,height,radius);
    if(stroke>0&&width>stroke*2&&height>stroke*2)rounded_path(path,x+stroke,y+stroke,width-stroke*2,height-stroke*2,fmax(0,radius-stroke));
    CGContextSaveGState(c);set_rgba(c,rgba);CGContextAddPath(c,path);CGContextEOFillPath(c);CGContextRestoreGState(c);
    CGPathRelease(path);return 0;
}
int zlc_gradient_surface(Renderer *s,GradientSurface *out){
    Target *t=s->target;if(!t||!t->pixels)return 1;
    *out=(GradientSurface){.pixels=(uint32_t *)t->pixels,.width=t->width,.height=t->height,.stride=(uint32_t)(t->stride/4),.scale=s->scale,.origin={s->origin[0],s->origin[1]}};
    memcpy(out->clip,s->gradient_clips[s->gradient_clip_depth],sizeof(out->clip));
    return 0;
}
void zlc_gradient_dirty(Renderer *s,uint32_t left,uint32_t top,uint32_t width,uint32_t height){(void)s;(void)left;(void)top;(void)width;(void)height;}
void zlc_brush_stats(Renderer *s,uint32_t *created,uint32_t *evicted,uint32_t *cached){(void)s;*created=*evicted=*cached=0;}
uint32_t zlc_test_live_patterns(void){return 0;}
int zlc_test_opaque(Renderer *s){
    Target *t=s->target;
    for(uint32_t y=0;y<t->height;y++)for(uint32_t x=0;x<t->width;x++)if(t->pixels[(size_t)y*t->stride+(size_t)x*4+3]!=255)return 0;
    return 1;
}

/* CSS-style weights to Core Text weight traits. */
static double weight_trait(uint16_t weight){
    static const double traits[9]={-0.8,-0.6,-0.4,0,0.23,0.3,0.4,0.56,0.62};
    int index=(int)lround((double)weight/100)-1;if(index<0)index=0;if(index>8)index=8;return traits[index];
}
static CTFontRef create_font(const char *named,float size,uint16_t weight,int italic,int monospace){
    if(named&&(!strcmp(named,"Serif")||!strcmp(named,"serif")||!strcmp(named,"ui-serif")))named="Times New Roman";
    int system=!named||!named[0]||!strcmp(named,"Sans")||!strcmp(named,"sans-serif")||!strcmp(named,"system-ui");
    int fixed=monospace&&(!named||!named[0]||!strcmp(named,"Monospace")||!strcmp(named,"monospace"));
    if(named&&(!strcmp(named,"Monospace")||!strcmp(named,"monospace")||!strcmp(named,"ui-monospace"))){system=1;fixed=1;}
    CFMutableDictionaryRef attributes=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef traits=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    if(!attributes||!traits){if(attributes)CFRelease(attributes);if(traits)CFRelease(traits);return NULL;}
    double trait=weight_trait(weight);CFNumberRef weight_number=CFNumberCreate(NULL,kCFNumberDoubleType,&trait);
    uint32_t symbolic=italic?kCTFontItalicTrait:0;CFNumberRef symbolic_number=CFNumberCreate(NULL,kCFNumberSInt32Type,&symbolic);
    if(weight_number){CFDictionarySetValue(traits,kCTFontWeightTrait,weight_number);CFRelease(weight_number);}
    if(symbolic_number){CFDictionarySetValue(traits,kCTFontSymbolicTrait,symbolic_number);CFRelease(symbolic_number);}
    CFDictionarySetValue(attributes,kCTFontTraitsAttribute,traits);CFRelease(traits);
    CTFontDescriptorRef descriptor=NULL;
    if(system){
        CTFontRef base=CTFontCreateUIFontForLanguage(fixed||monospace?kCTFontUIFontUserFixedPitch:kCTFontUIFontSystem,size,NULL);
        if(base){CTFontDescriptorRef from=CTFontCopyFontDescriptor(base);CFRelease(base);if(from){descriptor=CTFontDescriptorCreateCopyWithAttributes(from,attributes);CFRelease(from);}}
    }else{
        CFStringRef family=CFStringCreateWithCString(NULL,named,kCFStringEncodingUTF8);
        if(family){CFDictionarySetValue(attributes,kCTFontFamilyNameAttribute,family);CFRelease(family);descriptor=CTFontDescriptorCreateWithAttributes(attributes);}
    }
    CFRelease(attributes);if(!descriptor)return NULL;
    CTFontRef font=CTFontCreateWithFontDescriptor(descriptor,size,NULL);CFRelease(descriptor);return font;
}
/* Keeps the last font, recreating it only when something differs from the
   last text drawn. */
static CTFontRef use_font(Renderer *s,const char *named,float size,uint16_t weight,int italic,int monospace){
    const char *family=named?named:"";
    if(s->font&&s->font_size==size&&s->font_weight==weight&&s->font_italic==italic&&s->font_monospace==monospace&&!strncmp(s->font_family,family,sizeof(s->font_family)))return s->font;
    CTFontRef font=create_font(named,size,weight,italic,monospace);if(!font)return NULL;
    if(s->font)CFRelease(s->font);s->font=font;
    strncpy(s->font_family,family,sizeof(s->font_family)-1);s->font_family[sizeof(s->font_family)-1]=0;
    s->font_size=size;s->font_weight=weight;s->font_italic=italic;s->font_monospace=monospace;return font;
}
int zlc_text(Renderer *s,float x,float y,float width,float height,const char *text,uint32_t length,uint32_t color,float size,uint16_t weight,int italic,int monospace,const char *family){
    if(!(width>=0)||length>INT32_MAX||!(size>=1&&size<=1024))return 1;
    CTFontRef font=use_font(s,family,size,weight,italic,monospace);if(!font)return 2;
    CFStringRef string=CFStringCreateWithBytes(NULL,(const UInt8 *)text,length,kCFStringEncodingUTF8,false);if(!string)return 2;
    const void *keys[2]={kCTFontAttributeName,kCTForegroundColorFromContextAttributeName};const void *values[2]={font,kCFBooleanTrue};
    CFDictionaryRef attributes=CFDictionaryCreate(NULL,keys,values,2,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef attributed=attributes?CFAttributedStringCreate(NULL,string,attributes):NULL;CFRelease(string);
    CTLineRef line=attributed?CTLineCreateWithAttributedString(attributed):NULL;if(attributed)CFRelease(attributed);
    if(!line){if(attributes)CFRelease(attributes);return 2;}
    CGFloat ascent=0,descent=0,leading=0;double advance=CTLineGetTypographicBounds(line,&ascent,&descent,&leading);
    if(advance>width){
        CFAttributedStringRef ellipsis=CFAttributedStringCreate(NULL,CFSTR("…"),attributes);
        CTLineRef token=ellipsis?CTLineCreateWithAttributedString(ellipsis):NULL;if(ellipsis)CFRelease(ellipsis);
        CTLineRef truncated=token?CTLineCreateTruncatedLine(line,width,kCTLineTruncationEnd,token):NULL;if(token)CFRelease(token);
        CFRelease(line);line=truncated;
    }
    CFRelease(attributes);if(!line)return 0;
    CGContextRef c=s->target->context;
    CGContextSaveGState(c);CGContextClipToRect(c,CGRectMake(x,y,width,height));
    CGContextSetRGBFillColor(c,(double)((color>>16)&255)/255,(double)((color>>8)&255)/255,(double)(color&255)/255,1);
    CGContextSetTextMatrix(c,CGAffineTransformMakeScale(1,-1));
    CGContextSetTextPosition(c,x,(double)y+((double)height-(ascent+descent))/2+ascent);
    CTLineDraw(line,c);CGContextRestoreGState(c);CFRelease(line);
    return 0;
}
typedef struct PreparedClip {float x,y,width,height;} PreparedClip;
float zlc_scale(Renderer *s){return s->scale;}
/* mask is the gray coverage image of prepared text. */
int zlc_prepared(Renderer *s,CGImageRef mask,float x,float y,float scale,int32_t left,int32_t top,const PreparedClip *clip,uint32_t rgba){
    CGContextRef c=s->target->context;CGContextSaveGState(c);
    if(clip)CGContextClipToRect(c,CGRectMake((double)x+clip->x,(double)y+clip->y,clip->width,clip->height));
    CGRect rect=CGRectMake((double)x+(double)left/scale,(double)y+(double)top/scale,(double)CGImageGetWidth(mask)/scale,(double)CGImageGetHeight(mask)/scale);
    clip_mask(c,mask,rect);set_rgba(c,rgba);CGContextFillRect(c,rect);CGContextRestoreGState(c);return 0;
}
void zlc_push_clip(Renderer *s,float x,float y,float width,float height){
    if(s->gradient_clip_depth>=32)return;
    double *before=s->gradient_clips[s->gradient_clip_depth],*after=s->gradient_clips[++s->gradient_clip_depth];
    after[0]=fmax(before[0],(double)x*s->scale+s->origin[0]);after[1]=fmax(before[1],(double)y*s->scale+s->origin[1]);
    after[2]=fmin(before[2],((double)x+width)*s->scale+s->origin[0]);after[3]=fmin(before[3],((double)y+height)*s->scale+s->origin[1]);
    CGContextSaveGState(s->target->context);CGContextClipToRect(s->target->context,CGRectMake(x,y,width,height));s->target->saves++;
}
/* Clips to device pixels x0..x1, y0..y1 of the plane, exactly on pixel
   edges whatever the scale; popped by zlc_pop_clip. */
void zlc_push_device_clip(Renderer *s,int32_t x0,int32_t y0,int32_t x1,int32_t y1){
    if(s->gradient_clip_depth>=32)return;
    double *before=s->gradient_clips[s->gradient_clip_depth],*after=s->gradient_clips[++s->gradient_clip_depth];
    after[0]=fmax(before[0],(double)x0+s->origin[0]);after[1]=fmax(before[1],(double)y0+s->origin[1]);
    after[2]=fmin(before[2],(double)x1+s->origin[0]);after[3]=fmin(before[3],(double)y1+s->origin[1]);
    double scale=s->scale;
    CGContextSaveGState(s->target->context);CGContextClipToRect(s->target->context,CGRectMake((double)x0/scale,(double)y0/scale,(double)(x1-x0)/scale,(double)(y1-y0)/scale));s->target->saves++;
}
/* Clears a rectangle in DIP to transparent, within the current clip. */
void zlc_clear_rect(Renderer *s,float x,float y,float width,float height){
    CGContextRef c=s->target->context;
    if(width>=FLT_MAX){target_clear(s->target,0,0,s->target->width,s->target->height,0);return;}
    CGContextClearRect(c,CGRectMake(x,y,width,height));
}
void zlc_pop_clip(Renderer *s){if(s->gradient_clip_depth){s->gradient_clip_depth--;CGContextRestoreGState(s->target->context);s->target->saves--;}}
/* destination is a y-down context in points, such as a flipped view's. */
int zlc_end_checked(Renderer *s,CGContextRef destination){
    if(s->layers)return layer_end(s,destination);
    CGImageRef image=CGBitmapContextCreateImage(s->target->context);if(!image)return 2;
    draw_image(destination,image,CGRectMake(0,0,(double)s->width/s->scale,(double)s->height/s->scale));CGImageRelease(image);return 0;
}
void zlc_end(Renderer *s,CGContextRef destination){(void)zlc_end_checked(s,destination);}
void zlc_destroy(Renderer *s){if(s){destroy(s);for(unsigned i=0;i<s->image_capacity;i++)drop_image(&s->images[i]);free(s->images);drop_image(&s->image_candidate);if(s->font)CFRelease(s->font);free(s);}}
static int prepare_image(Renderer *s,const ZiImageLevel *levels,uint32_t count,int dynamic){
    if(count==0||count>ZI_IMAGE_LEVELS||s->image_candidate.count)return 1;
    uint32_t fault=s->image_fault;s->image_fault=0;
    CachedImage image={0};image.count=count;image.dynamic=dynamic;image.levels=levels;
    size_t bytes=0;for(uint32_t i=0;i<count;i++)bytes+=levels[i].byte_len;
    for(unsigned bank=0;bank<(dynamic?2u:1u);bank++){
      if(dynamic){image.pool[bank]=malloc(bytes?bytes:1);if(!image.pool[bank])goto failed;}
      size_t offset=0;
      for(uint32_t i=0;i<count;i++){
        if(fault==bank*count+i+1)goto failed;
        uint8_t *pixels=dynamic?image.pool[bank]+offset:(uint8_t *)levels[i].pixels;
        if(dynamic)memcpy(pixels,levels[i].pixels,levels[i].byte_len);
        image.images[bank][i]=make_image(pixels,levels[i].width,levels[i].height,levels[i].stride,0);s->image_creations++;
        if(!image.images[bank][i])goto failed;
        offset+=levels[i].byte_len;
      }
    }
    s->image_candidate=image;return 0;
failed:drop_image(&image);return 2;
}
int zlc_prepare_image(Renderer *s,const ZiImageLevel *levels,uint32_t count){return prepare_image(s,levels,count,0);}
int zlc_prepare_dynamic_image(Renderer *s,const ZiImageLevel *levels,uint32_t count){return prepare_image(s,levels,count,1);}
int zlc_prepare_coverage(Renderer *s,const ZgCoverage *coverage){
    if(s->image_candidate.count)return 1;
    if(!coverage->width||!coverage->height||coverage->stride<coverage->width)return 1;
    uint32_t fault=s->image_fault;s->image_fault=0;
    CachedImage image={0};image.count=1;image.is_coverage=1;
    image.coverage_level=(ZiImageLevel){coverage->pixels,(size_t)coverage->stride*coverage->height,coverage->width,coverage->height,coverage->stride};
    if(fault==1)goto failed;
    image.images[0][0]=make_image(coverage->pixels,coverage->width,coverage->height,coverage->stride,1);s->coverage_creations++;
    if(!image.images[0][0])goto failed;
    if(fault==2)goto failed;
    s->image_candidate=image;s->image_candidate.levels=&s->image_candidate.coverage_level;return 0;
failed:drop_image(&image);return 2;
}
int zlc_update_image(Renderer *s,uint32_t slot,const ZiImageLevel *levels,uint32_t count){
    if(slot>=s->image_capacity||!s->images[slot].dynamic||s->images[slot].count!=count)return 1;
    CachedImage *image=&s->images[slot];unsigned bank=1-image->active;uint32_t fault=s->image_fault;s->image_fault=0;
    size_t offset=0;
    for(uint32_t i=0;i<count;i++){
        if(fault==i+1)return 2;
        memcpy(image->pool[bank]+offset,levels[i].pixels,levels[i].byte_len);
        /* A new image over the same memory, so no cached decode of the
           previous contents is drawn. */
        CGImageRef replacement=make_image(image->pool[bank]+offset,levels[i].width,levels[i].height,levels[i].stride,0);if(!replacement)return 2;
        CGImageRelease(image->images[bank][i]);live_image_objects--;image->images[bank][i]=replacement;s->image_creations++;
        offset+=levels[i].byte_len;
    }
    image->active=bank;image->levels=levels;return 0;
}
/* Grow the slot table; coverage entries point at their own level, so moved
   entries are pointed at it again. */
int zlc_reserve_images(Renderer *s,uint32_t capacity){
    if(capacity<=s->image_capacity)return 0;
    CachedImage *images=realloc(s->images,(size_t)capacity*sizeof(*images));if(!images)return 1;
    memset(images+s->image_capacity,0,(size_t)(capacity-s->image_capacity)*sizeof(*images));
    for(uint32_t i=0;i<s->image_capacity;i++)if(images[i].is_coverage)images[i].levels=&images[i].coverage_level;
    s->images=images;s->image_capacity=capacity;return 0;
}
void zlc_commit_image(Renderer *s,uint32_t slot){drop_image(&s->images[slot]);s->images[slot]=s->image_candidate;if(s->images[slot].is_coverage)s->images[slot].levels=&s->images[slot].coverage_level;memset(&s->image_candidate,0,sizeof(s->image_candidate));}
void zlc_image_fault(Renderer *s,uint32_t mip){s->image_fault=mip;}
void zlc_release_image(Renderer *s,uint32_t slot){if(slot<s->image_capacity)drop_image(&s->images[slot]);}
int zlc_image(Renderer *s,uint32_t slot,const ZiImagePlan *plan){
    if(slot>=s->image_capacity||plan->level>=s->images[slot].count||s->images[slot].is_coverage)return 1;
    CGImageRef image=s->images[slot].images[s->images[slot].active][plan->level];const ZiImageRect *d=&plan->destination,*r=&plan->source;
    if(d->width<=0||d->height<=0||plan->opacity<=0)return 0;
    if(!(r->width>0&&r->height>0))return 1;
    const double sx=(double)d->width/r->width,sy=(double)d->height/r->height;
    CGContextRef c=s->target->context;CGContextSaveGState(c);CGContextClipToRect(c,CGRectMake(d->x,d->y,d->width,d->height));
    CGContextSetAlpha(c,plan->opacity>1?1:plan->opacity);CGContextSetInterpolationQuality(c,plan->sampling?kCGInterpolationDefault:kCGInterpolationNone);
    draw_image(c,image,CGRectMake((double)d->x-(double)r->x*sx,(double)d->y-(double)r->y*sy,(double)CGImageGetWidth(image)*sx,(double)CGImageGetHeight(image)*sy));
    CGContextRestoreGState(c);return 0;
}
int zlc_coverage(Renderer *s,uint32_t slot,float x,float y,float scale,int32_t left,int32_t top,uint32_t rgba){
    if(slot>=s->image_capacity||!s->images[slot].is_coverage)return 1;
    return zlc_prepared(s,s->images[slot].images[0][0],x,y,scale,left,top,NULL,rgba);
}
static uint32_t raster_objects(Renderer *s,int coverage){uint32_t n=0;for(unsigned i=0;i<s->image_capacity;i++)if(s->images[i].is_coverage==(uint32_t)coverage)for(unsigned bank=0;bank<2;bank++)for(unsigned j=0;j<s->images[i].count;j++)if(s->images[i].images[bank][j])n++;return n;}
uint32_t zlc_image_objects(Renderer *s){return raster_objects(s,0);}
uint64_t zlc_image_creations(Renderer *s){return s->image_creations;}
uint32_t zlc_coverage_objects(Renderer *s){return raster_objects(s,1);}
uint64_t zlc_coverage_creations(Renderer *s){return s->coverage_creations;}
uint32_t zlc_test_live_image_objects(void){return live_image_objects;}
uint32_t zlc_test_pixel(Renderer *s,uint32_t x,uint32_t y){
    x=(uint32_t)(x*s->scale);y=(uint32_t)(y*s->scale);
    if(x>=s->width||y>=s->height)return 0xffffffff;
    const uint8_t *pixel=s->target->pixels+(size_t)y*s->target->stride+(size_t)x*4;
    return ((uint32_t)pixel[2]<<16)|((uint32_t)pixel[1]<<8)|pixel[0];
}
uint32_t zlc_test_raw_pixel(Renderer *s,uint32_t x,uint32_t y){
    if(x>=s->width||y>=s->height)return 0xffffffff;
    const uint8_t *pixel=s->target->pixels+(size_t)y*s->target->stride+(size_t)x*4;
    return ((uint32_t)pixel[2]<<16)|((uint32_t)pixel[1]<<8)|pixel[0];
}
uint32_t zlc_test_text_pixels(Renderer *s){
    uint32_t count=0;
    for(uint32_t y=8;y<48;y++)for(uint32_t x=8;x<288;x++)if(zlc_test_pixel(s,x,y)!=0xffffff)count++;
    return count;
}
uint32_t zlc_test_generation(Renderer *s){return s->generation;}
size_t zlc_surface_bytes(Renderer *s){return s->target?(size_t)s->width*s->height*4:0;}

/* Shader effects run on OpenGL only on Linux; macOS draws them on the CPU. */
void *zgl_effects_create(int force,char *log,size_t log_len){(void)force;if(log_len)snprintf(log,log_len,"no OpenGL effects on macOS");return NULL;}
void zgl_effects_destroy(void *gl){(void)gl;}
int zgl_effects_install(void *gl,uint32_t slot,const char *source,char *log,size_t log_len){(void)gl;(void)slot;(void)source;if(log_len)log[0]=0;return 1;}
int zgl_effects_run(void *gl,uint32_t slot,const uint32_t *words,uint32_t word_count,const void *params,const uint32_t *content,uint32_t content_width,uint32_t content_height,size_t content_stride,uint32_t *out,uint32_t out_width,uint32_t out_height,size_t out_stride){
    (void)gl;(void)slot;(void)words;(void)word_count;(void)params;(void)content;(void)content_width;(void)content_height;(void)content_stride;(void)out;(void)out_width;(void)out_height;(void)out_stride;return 1;
}
uint64_t zgl_effects_passes(void *gl){(void)gl;return 0;}
