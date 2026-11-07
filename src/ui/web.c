/* The browser's software renderer: the same `zlc_*` ABI as linux.c and
   macos.c, drawn in memory into owned premultiplied BGRA planes by a small
   rasterizer of its own (rectangles, rounded rectangles, images and masks,
   with antialiased clips), and shown on the window's canvas through its 2D
   context (zw_present). Text comes from the browser: the page draws each
   text run on a canvas of its own, which finds the fonts, falls back and
   shapes as for its pages, and hands back the run's pixels (zw_text_*).
   CPU stages (gradients, Gaussian filters, transforms, masks) read and
   write the planes directly, as on the other systems. */
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include <float.h>
#include <string.h>
#include "brushes.h"
#include "image_resource.h"
#include "coverage_resource.h"
#include "layer_resource.h"
#include "gaussian_scope.h"

typedef struct GradientSurface {uint32_t *pixels;uint32_t width,height,stride;float scale;double clip[4],origin[2];} GradientSurface;

#define IMPORT(name) __attribute__((import_module("ziggurat"),import_name(#name)))
/* Shows w*h premultiplied BGRA pixels (stride bytes a row) on the canvas of
   window `id`, the rectangle x0..x1, y0..y1 of them at least. */
IMPORT(zw_present) void zw_present(uint32_t id,const uint32_t *pixels,uint32_t width,uint32_t height,uint32_t stride,uint32_t transparent);
/* Draws a run of text on the page's text canvas: font is a CSS font, size
   and widths in device pixels; returns 0 when it drew, writing the pixels'
   width, height, and where their origin is from the pen at the baseline
   (left, top), and the font's ascent and descent. */
IMPORT(zw_text_draw) int zw_text_draw(const char *text,uint32_t length,const char *font,uint32_t font_length,double size,double max_width,double offset,uint32_t rgb,double spacing,double *out);
/* Copies the pixels the last zw_text_draw drew, premultiplied BGRA. */
IMPORT(zw_text_copy) void zw_text_copy(uint32_t *pixels);

/* A mask a clip multiplies coverage by: A8 samples mapped to device pixels
   as x = left + u/sx. */
typedef struct Mask {const uint8_t *pixels;uint32_t width,height,stride;double left,top,sx,sy;} Mask;
#define MASKS 4
typedef struct State {double clip[4];Mask masks[MASKS];uint32_t mask_count;} State;
#define STATES 48
/* An owned plane. User space maps to device pixels as scale*p+origin; the
   state stack holds clips, which saves push and restores pop. */
typedef struct Target {uint32_t *pixels;uint32_t width,height;size_t stride;uint32_t saves,depth;double scale,origin[2];State states[STATES];} Target;
static State *state_of(Target *t){return &t->states[t->depth];}
static int target_create(Target *t,uint32_t width,uint32_t height){
    memset(t,0,sizeof(*t));
    if(!width||!height||width>32768||height>32768)return 1;
    t->stride=(size_t)width*4;
    t->pixels=calloc(height,t->stride);if(!t->pixels)return 2;
    t->width=width;t->height=height;t->scale=1;
    State *s=state_of(t);s->clip[0]=s->clip[1]=0;s->clip[2]=width;s->clip[3]=height;
    return 0;
}
static void target_drop(Target *t){free(t->pixels);memset(t,0,sizeof(*t));}
static void target_reset(Target *t){t->saves=0;t->depth=0;State *s=state_of(t);memset(s,0,sizeof(*s));s->clip[2]=t->width;s->clip[3]=t->height;}
static void target_matrix(Target *t,double scale,double x,double y){t->scale=scale;t->origin[0]=x;t->origin[1]=y;}
static void target_save(Target *t){if(t->depth+1>=STATES){t->depth++;return;}t->states[t->depth+1]=t->states[t->depth];t->depth++;}
static void target_restore(Target *t){if(t->depth)t->depth--;}
static double dx(const Target *t,double x){return x*t->scale+t->origin[0];}
static double dy(const Target *t,double y){return y*t->scale+t->origin[1];}
static void clip_device(Target *t,double x0,double y0,double x1,double y1){
    if(t->depth>=STATES)return;State *s=state_of(t);
    s->clip[0]=fmax(s->clip[0],x0);s->clip[1]=fmax(s->clip[1],y0);s->clip[2]=fmin(s->clip[2],x1);s->clip[3]=fmin(s->clip[3],y1);
}
static void clip_user(Target *t,double x,double y,double width,double height){
    if(width<0){x+=width;width=-width;}if(height<0){y+=height;height=-height;}
    clip_device(t,dx(t,x),dy(t,y),dx(t,x+width),dy(t,y+height));
}
/* Clips to an A8 mask over a user-space rectangle. */
static void clip_mask(Target *t,const uint8_t *pixels,uint32_t width,uint32_t height,uint32_t stride,double x,double y,double w,double h){
    if(t->depth>=STATES)return;State *s=state_of(t);
    clip_user(t,x,y,w,h);
    if(s->mask_count>=MASKS||!width||!height)return;
    s->masks[s->mask_count++]=(Mask){pixels,width,height,stride,dx(t,x),dy(t,y),(double)width/(w*t->scale),(double)height/(h*t->scale)};
}
static void target_clear(Target *t,uint32_t left,uint32_t top,uint32_t right,uint32_t bottom,uint8_t value){
    if(right>t->width)right=t->width;if(bottom>t->height)bottom=t->height;
    for(uint32_t y=top;y<bottom&&left<right;y++)memset((uint8_t *)t->pixels+(size_t)y*t->stride+(size_t)left*4,value,(size_t)(right-left)*4);
}
static double span(double a0,double a1,double p){double lo=fmax(a0,p),hi=fmin(a1,p+1);return hi>lo?hi-lo:0;}
static double sample_mask(const Mask *m,double x,double y){
    double u=(x-m->left)*m->sx-0.5,v=(y-m->top)*m->sy-0.5;
    double fu=floor(u),fv=floor(v);int u0=(int)fu,v0=(int)fv;double au=u-fu,av=v-fv;double sum=0;
    for(int j=0;j<2;j++)for(int i=0;i<2;i++){
        int uu=u0+i,vv=v0+j;if(uu<0||vv<0||uu>=(int)m->width||vv>=(int)m->height)continue;
        sum+=(i?au:1-au)*(j?av:1-av)*m->pixels[(size_t)vv*m->stride+(size_t)uu];
    }
    return sum/255;
}
static double mask_coverage(const State *s,double x,double y){double c=1;for(uint32_t i=0;i<s->mask_count&&c>0;i++)c*=sample_mask(&s->masks[i],x+0.5,y+0.5);return c;}
/* Premultiplied color, channels 0..1. */
typedef struct Color {float b,g,r,a;} Color;
static Color rgba_color(uint32_t rgba,double alpha){float a=(float)((rgba&255)/255.0*alpha);return (Color){(float)(((rgba>>8)&255)/255.0)*a,(float)(((rgba>>16)&255)/255.0)*a,(float)((rgba>>24)/255.0)*a,a};}
static Color rgb_color(uint32_t rgb){return (Color){(float)((rgb&255)/255.0),(float)(((rgb>>8)&255)/255.0),(float)(((rgb>>16)&255)/255.0),1};}
static inline uint32_t clamp8(float v){int x=(int)lrintf(v*255);return (uint32_t)(x<0?0:x>255?255:x);}
static inline void blend(uint32_t *p,Color c,float coverage){
    if(coverage<=0)return;
    uint32_t d=*p;float k=1-c.a*coverage;
    float db=(float)(d&255)/255,dg=(float)((d>>8)&255)/255,dr=(float)((d>>16)&255)/255,da=(float)(d>>24)/255;
    *p=clamp8(c.b*coverage+db*k)|clamp8(c.g*coverage+dg*k)<<8|clamp8(c.r*coverage+dr*k)<<16|clamp8(c.a*coverage+da*k)<<24;
}
static inline void blend_pixel(uint32_t *p,uint32_t s,float coverage){
    if(coverage<=0||!s)return;
    Color c={(float)(s&255)/255,(float)((s>>8)&255)/255,(float)((s>>16)&255)/255,(float)(s>>24)/255};blend(p,c,coverage);
}
/* The device pixels a drawing over the device rectangle may touch. */
static int bounds_of(const Target *t,const State *s,double x0,double y0,double x1,double y1,int *box){
    x0=fmax(x0,s->clip[0]);y0=fmax(y0,s->clip[1]);x1=fmin(x1,s->clip[2]);y1=fmin(y1,s->clip[3]);
    box[0]=(int)fmax(0,floor(x0));box[1]=(int)fmax(0,floor(y0));box[2]=(int)fmin(t->width,ceil(x1));box[3]=(int)fmin(t->height,ceil(y1));
    return box[2]>box[0]&&box[3]>box[1];
}
static void fill_device(Target *t,double x0,double y0,double x1,double y1,Color c){
    if(t->depth>=STATES||c.a<=0)return;
    const State *s=state_of(t);int box[4];if(!bounds_of(t,s,x0,y0,x1,y1,box))return;
    const double l=fmax(x0,s->clip[0]),r=fmin(x1,s->clip[2]),u=fmax(y0,s->clip[1]),d=fmin(y1,s->clip[3]);
    for(int y=box[1];y<box[3];y++){
        const double cy=span(u,d,y);uint32_t *row=(uint32_t *)((uint8_t *)t->pixels+(size_t)y*t->stride);
        for(int x=box[0];x<box[2];x++){
            double cov=cy*span(l,r,x);if(s->mask_count&&cov>0)cov*=mask_coverage(s,x,y);
            blend(row+x,c,(float)cov);
        }
    }
}
static void fill_user(Target *t,double x,double y,double width,double height,Color c){
    if(width<0){x+=width;width=-width;}if(height<0){y+=height;height=-height;}
    fill_device(t,dx(t,x),dy(t,y),dx(t,x+width),dy(t,y+height),c);
}
/* Coverage of a device pixel by a rounded rectangle in device pixels. */
static double rounded_coverage(double x0,double y0,double x1,double y1,double r,int px,int py){
    double c=span(x0,x1,px)*span(y0,y1,py);if(c<=0||r<=0)return c;
    const double cx=px+0.5,cy=py+0.5;double ox,oy;
    if(cx<x0+r)ox=x0+r;else if(cx>x1-r)ox=x1-r;else return c;
    if(cy<y0+r)oy=y0+r;else if(cy>y1-r)oy=y1-r;else return c;
    const double distance=hypot(cx-ox,cy-oy);
    const double edge=r+0.5-distance;return edge<=0?0:edge>=1?c:fmin(c,edge);
}
static void fill_rounded(Target *t,double x,double y,double w,double h,double r,int ring,double ix,double iy,double iw,double ih,double ir,Color c){
    if(t->depth>=STATES||c.a<=0)return;
    const State *s=state_of(t);
    const double x0=dx(t,x),y0=dy(t,y),x1=dx(t,x+w),y1=dy(t,y+h),rr=r*t->scale;
    const double i0=dx(t,ix),j0=dy(t,iy),i1=dx(t,ix+iw),j1=dy(t,iy+ih),irr=ir*t->scale;
    int box[4];if(!bounds_of(t,s,x0,y0,x1,y1,box))return;
    for(int py=box[1];py<box[3];py++){
        const double cy=span(s->clip[1],s->clip[3],py);uint32_t *row=(uint32_t *)((uint8_t *)t->pixels+(size_t)py*t->stride);
        for(int px=box[0];px<box[2];px++){
            double cov=rounded_coverage(x0,y0,x1,y1,rr,px,py);
            if(ring&&cov>0)cov=fmax(0,cov-rounded_coverage(i0,j0,i1,j1,irr,px,py));
            if(cov<=0)continue;
            cov*=cy*span(s->clip[0],s->clip[2],px);if(s->mask_count&&cov>0)cov*=mask_coverage(s,px,py);
            blend(row+px,c,(float)cov);
        }
    }
}
/* Multiplies the plane's pixels inside the clip by alpha, weighted by the
   clip's coverage (CG's DestinationIn with a translucent fill). */
static void scale_alpha(Target *t,double alpha){
    if(t->depth>=STATES)return;
    const State *s=state_of(t);int box[4];if(!bounds_of(t,s,s->clip[0],s->clip[1],s->clip[2],s->clip[3],box))return;
    for(int y=box[1];y<box[3];y++){
        const double cy=span(s->clip[1],s->clip[3],y);uint32_t *row=(uint32_t *)((uint8_t *)t->pixels+(size_t)y*t->stride);
        for(int x=box[0];x<box[2];x++){
            double cov=cy*span(s->clip[0],s->clip[2],x);if(s->mask_count&&cov>0)cov*=mask_coverage(s,x,y);
            const float k=(float)(1-cov+cov*alpha);uint32_t p=row[x];if(!p||k>=1)continue;
            row[x]=clamp8((float)(p&255)/255*k)|clamp8((float)((p>>8)&255)/255*k)<<8|clamp8((float)((p>>16)&255)/255*k)<<16|clamp8((float)(p>>24)/255*k)<<24;
        }
    }
}
static void clear_user(Target *t,double x,double y,double w,double h){
    if(t->depth>=STATES)return;
    if(w<0){x+=w;w=-w;}if(h<0){y+=h;h=-h;}
    const State *s=state_of(t);const double x0=dx(t,x),y0=dy(t,y),x1=dx(t,x+w),y1=dy(t,y+h);
    int box[4];if(!bounds_of(t,s,x0,y0,x1,y1,box))return;
    const double l=fmax(x0,s->clip[0]),r=fmin(x1,s->clip[2]),u=fmax(y0,s->clip[1]),d=fmin(y1,s->clip[3]);
    for(int py=box[1];py<box[3];py++){
        const double cy=span(u,d,py);uint32_t *row=(uint32_t *)((uint8_t *)t->pixels+(size_t)py*t->stride);
        for(int px=box[0];px<box[2];px++){
            double cov=cy*span(l,r,px);if(s->mask_count&&cov>0)cov*=mask_coverage(s,px,py);
            if(cov<=0)continue;const float k=(float)(1-cov);uint32_t p=row[px];
            row[px]=clamp8((float)(p&255)/255*k)|clamp8((float)((p>>8)&255)/255*k)<<8|clamp8((float)((p>>16)&255)/255*k)<<16|clamp8((float)(p>>24)/255*k)<<24;
        }
    }
}
/* Draws premultiplied BGRA pixels mapped to device pixels as
   x = left + u*sx, y = top + v*sy, over the device rectangle they cover,
   bilinear (smooth) or nearest, at alpha. */
static uint32_t sample_bilinear(const uint32_t *pixels,uint32_t width,uint32_t height,size_t stride,double u,double v){
    u-=0.5;v-=0.5;double fu=floor(u),fv=floor(v);int u0=(int)fu,v0=(int)fv;double au=u-fu,av=v-fv;
    double acc[4]={0,0,0,0};
    for(int j=0;j<2;j++)for(int i=0;i<2;i++){
        int uu=u0+i,vv=v0+j;if(uu<0)uu=0;if(vv<0)vv=0;if(uu>=(int)width)uu=(int)width-1;if(vv>=(int)height)vv=(int)height-1;
        const uint32_t p=*(const uint32_t *)((const uint8_t *)pixels+(size_t)vv*stride+(size_t)uu*4);const double w=(i?au:1-au)*(j?av:1-av);
        acc[0]+=w*(p&255);acc[1]+=w*((p>>8)&255);acc[2]+=w*((p>>16)&255);acc[3]+=w*(p>>24);
    }
    return (uint32_t)lrint(acc[0])|(uint32_t)lrint(acc[1])<<8|(uint32_t)lrint(acc[2])<<16|(uint32_t)lrint(acc[3])<<24;
}
static void draw_pixels(Target *t,const uint32_t *pixels,uint32_t width,uint32_t height,size_t stride,double left,double top,double sx,double sy,double alpha,int smooth){
    if(t->depth>=STATES||alpha<=0||!width||!height||!(sx>0)||!(sy>0))return;
    const State *s=state_of(t);const double x1=left+width*sx,y1=top+height*sy;
    int box[4];if(!bounds_of(t,s,left,top,x1,y1,box))return;
    const int exact=fabs(sx-1)<1e-9&&fabs(sy-1)<1e-9&&fabs(left-round(left))<1e-9&&fabs(top-round(top))<1e-9;
    for(int y=box[1];y<box[3];y++){
        const double cy=span(s->clip[1],s->clip[3],y)*span(top,y1,y);uint32_t *row=(uint32_t *)((uint8_t *)t->pixels+(size_t)y*t->stride);
        for(int x=box[0];x<box[2];x++){
            double cov=cy*span(s->clip[0],s->clip[2],x)*span(left,x1,x);if(cov<=0)continue;
            if(s->mask_count)cov*=mask_coverage(s,x,y);
            uint32_t p;
            if(exact){const int u=x-(int)lround(left),v=y-(int)lround(top);p=*(const uint32_t *)((const uint8_t *)pixels+(size_t)v*stride+(size_t)u*4);}
            else{const double u=(x+0.5-left)/sx,v=(y+0.5-top)/sy;
                if(smooth)p=sample_bilinear(pixels,width,height,stride,u,v);
                else{int uu=(int)floor(u),vv=(int)floor(v);if(uu<0)uu=0;if(vv<0)vv=0;if(uu>=(int)width)uu=(int)width-1;if(vv>=(int)height)vv=(int)height-1;p=*(const uint32_t *)((const uint8_t *)pixels+(size_t)vv*stride+(size_t)uu*4);}}
            blend_pixel(row+x,p,(float)(cov*alpha));
        }
    }
}
/* Fills color through an A8 coverage over a device rectangle. */
static void fill_coverage(Target *t,const uint8_t *pixels,uint32_t width,uint32_t height,uint32_t stride,double left,double top,double sx,double sy,Color c){
    if(t->depth>=STATES||c.a<=0||!width||!height)return;
    const State *s=state_of(t);const double x1=left+width*sx,y1=top+height*sy;
    int box[4];if(!bounds_of(t,s,left,top,x1,y1,box))return;
    const Mask m={pixels,width,height,stride,left,top,1/sx,1/sy};
    const int exact=fabs(sx-1)<1e-9&&fabs(sy-1)<1e-9&&fabs(left-round(left))<1e-9&&fabs(top-round(top))<1e-9;
    for(int y=box[1];y<box[3];y++){
        const double cy=span(s->clip[1],s->clip[3],y);uint32_t *row=(uint32_t *)((uint8_t *)t->pixels+(size_t)y*t->stride);
        for(int x=box[0];x<box[2];x++){
            double cov=cy*span(s->clip[0],s->clip[2],x);if(cov<=0)continue;
            if(exact){const int u=x-(int)lround(left),v=y-(int)lround(top);cov*=(u>=0&&v>=0&&u<(int)width&&v<(int)height)?pixels[(size_t)v*stride+(size_t)u]/255.0:0;}
            else cov*=sample_mask(&m,x+0.5,y+0.5);
            if(s->mask_count&&cov>0)cov*=mask_coverage(s,x,y);
            blend(row+x,c,(float)cov);
        }
    }
}

typedef struct CachedImage {uint32_t *pixels[2][ZI_IMAGE_LEVELS];uint8_t *pool[2];const ZiImageLevel *levels;ZiImageLevel coverage_level;ZiImageLevel stored[2][ZI_IMAGE_LEVELS];uint32_t count,dynamic,active,is_coverage,objects;} CachedImage;
static uint32_t live_image_objects;
static void drop_image(CachedImage *image){live_image_objects-=image->objects;for(unsigned bank=0;bank<2;bank++)free(image->pool[bank]);memset(image,0,sizeof(*image));}

typedef struct Layers Layers;
typedef struct Renderer {
    Target own;
    Target *target;
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
    int window_transparent,keep_plane;
    uint32_t *text_pixels;
    size_t text_capacity;
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
static void layer_target_drop(Target *target){if(target->pixels)live_layer_objects-=2;target_drop(target);}
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
/* Composites child over parent: the child's pixels map to the parent's
   device pixels through the difference of their origins. */
static void layer_composite(Target *child,Target *parent){
    draw_pixels(parent,child->pixels,child->width,child->height,child->stride,parent->origin[0]-child->origin[0],parent->origin[1]-child->origin[1],1,1,1,0);
}
int zlc_layer_begin_group(Renderer *s,const ZgLayerGroup *group){
    Layers *layer=s->layers;if(!layer||!layer->active||layer->depth>=layer->capacity)return 1;
    LayerGroup *frame=&layer->groups[layer->depth];frame->kind=0;frame->group=*group;frame->clip_depth=s->gradient_clip_depth;memcpy(frame->clips,s->gradient_clips,sizeof(frame->clips));
    const double ox=s->origin[0],oy=s->origin[1];
    const double *parent=s->gradient_clips[s->gradient_clip_depth];double visible[4]={fmax(parent[0],(double)group->x*layer->scale+ox),fmax(parent[1],(double)group->y*layer->scale+oy),fmin(parent[2],((double)group->x+group->width)*layer->scale+ox),fmin(parent[3],((double)group->y+group->height)*layer->scale+oy)};
    uint32_t box[4];layer_box(s,visible,box);layer->depth++;Target *target=layer_current(layer);target_reset(target);layer_origin(layer,target,ox,oy);layer_alias(s,target);
    clip_device(target,box[0],box[1],box[2],box[3]);
    target_clear(target,box[0],box[1],box[2],box[3],0);
    s->gradient_clip_depth=0;for(unsigned i=0;i<4;i++)s->gradient_clips[0][i]=box[i];
    layer->stats.groups++;layer->stats.clear_pixels+=(uint64_t)(box[2]-box[0])*(box[3]-box[1]);return 0;
}
int zlc_layer_end_group(Renderer *s){
    Layers *layer=s->layers;if(!layer||!layer->depth||s->gradient_clip_depth||(layer->groups[layer->depth-1].kind!=0&&layer->groups[layer->depth-1].kind!=2))return 1;
    Target *child=layer_current(layer);LayerGroup *frame=&layer->groups[layer->depth-1];ZgLayerGroup *group=&frame->group;
    double x=group->x,y=group->y,width=group->width,height=group->height;
    if(frame->kind==2){const ZgGaussianCapture *c=&layer->gaussian->frames[layer->depth-1].capture;x=((double)c->left-c->radius)/c->scale;y=((double)c->top-c->radius)/c->scale;width=(double)(c->width+2*c->radius)/c->scale;height=(double)(c->height+2*c->radius)/c->scale;target_reset(child);layer_origin(layer,child,child->origin[0],child->origin[1]);}
    if(group->opacity!=255){target_save(child);clip_user(child,x,y,width,height);scale_alpha(child,(double)group->opacity/255);target_restore(child);}
    if(group->mask_slot!=UINT32_MAX&&(group->mask_slot>=s->image_capacity||!s->images[group->mask_slot].is_coverage))return 1;
    layer->depth--;Target *parent=layer_current(layer);layer_alias(s,parent);s->gradient_clip_depth=frame->clip_depth;memcpy(s->gradient_clips,frame->clips,sizeof(frame->clips));
    target_save(parent);clip_user(parent,x,y,width,height);
    if(group->mask_slot!=UINT32_MAX){
        const ZiImageLevel *mask=&s->images[group->mask_slot].coverage_level;
        clip_mask(parent,mask->pixels,mask->width,mask->height,mask->stride,(double)group->mask_x+(double)group->mask_left/group->mask_scale,(double)group->mask_y+(double)group->mask_top/group->mask_scale,(double)mask->width/group->mask_scale,(double)mask->height/group->mask_scale);
    }
    layer_composite(child,parent);
    target_restore(parent);
    double region[4]={fmax(s->gradient_clips[s->gradient_clip_depth][0],x*layer->scale+s->origin[0]),fmax(s->gradient_clips[s->gradient_clip_depth][1],y*layer->scale+s->origin[1]),fmin(s->gradient_clips[s->gradient_clip_depth][2],(x+width)*layer->scale+s->origin[0]),fmin(s->gradient_clips[s->gradient_clip_depth][3],(y+height)*layer->scale+s->origin[1])};uint32_t box[4];layer_box(s,region,box);layer->stats.composite_pixels+=(uint64_t)(box[2]-box[0])*(box[3]-box[1]);
    return 0;
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
    clip_user(target,(double)capture->left/layer->scale,(double)capture->top/layer->scale,(double)capture->width/layer->scale,(double)capture->height/layer->scale);
    s->gradient_clip_depth=0;s->gradient_clips[0][0]=s->gradient_clips[0][1]=capture->radius;s->gradient_clips[0][2]=capture->radius+capture->width;s->gradient_clips[0][3]=capture->radius+capture->height;
    layer->stats.groups++;layer->stats.clear_pixels+=(uint64_t)(capture->width+2*capture->radius)*(capture->height+2*capture->radius);return 0;
}
int zlc_layer_gaussian_planes(Renderer *s,GradientSurface *source,GradientSurface *scratch,const ZgGaussianKernel **kernel){
    if(!zlc_layer_gaussian_active(s)||s->gradient_clip_depth)return 1;
    Layers *layer=s->layers;Target *target=layer_current(layer);
    const ZgGaussianFrame *frame=&layer->gaussian->frames[layer->depth-1];const uint32_t width=frame->capture.width+2*frame->capture.radius,height=frame->capture.height+2*frame->capture.radius;
    if(target->stride/4<width||target->height<height)return 2;
    *source=(GradientSurface){.pixels=target->pixels,.width=width,.height=height,.stride=(uint32_t)(target->stride/4),.scale=layer->scale};
    *scratch=(GradientSurface){.pixels=layer->gaussian->scratch,.width=width,.height=height,.stride=layer->pool_width,.scale=layer->scale};*kernel=&frame->kernel;return 0;
}
static int present(Renderer *s,Target *work,void *destination){
    zw_present((uint32_t)(uintptr_t)destination,work->pixels,work->width,work->height,(uint32_t)work->stride,(uint32_t)s->window_transparent);
    return 0;
}
static int layer_end(Renderer *s,void *destination){
    Layers *layer=s->layers;if(!layer->active)return 1;if(layer->transparent_root)return 4;if(layer->depth){layer_abort(s);return 1;}
    Target *work=layer_current(layer);
    present(s,work,destination);
    uint32_t previous=layer->front;layer->front=layer->work;layer->work=previous;layer->active=0;layer->front_transparent=0;layer->stats.committed_frames++;layer_alias(s,&layer->targets[layer->front]);return 0;
}
int zlc_layer_begin_transform(Renderer *s,const ZgTransform *value){
    Layers *layer=s->layers;if(!layer||!layer->active||layer->depth>=layer->capacity||value->pixel_width+2>layer->pool_width||value->pixel_height+2>layer->pool_height)return 1;
    LayerGroup *frame=&layer->groups[layer->depth];frame->kind=1;frame->transform=*value;frame->clip_depth=s->gradient_clip_depth;memcpy(frame->clips,s->gradient_clips,sizeof(frame->clips));
    layer->depth++;Target *target=layer_current(layer);target_reset(target);
    target_clear(target,0,0,value->pixel_width+2,value->pixel_height+2,0);
    layer_origin(layer,target,1,1);layer_alias(s,target);clip_user(target,0,0,value->source_width,value->source_height);
    s->gradient_clip_depth=0;s->gradient_clips[0][0]=s->gradient_clips[0][1]=1;s->gradient_clips[0][2]=1+(double)value->source_width*layer->scale;s->gradient_clips[0][3]=1+(double)value->source_height*layer->scale;
    layer->stats.clear_pixels+=(uint64_t)(value->pixel_width+2)*(value->pixel_height+2);return 0;
}
int zlc_layer_transform_planes(Renderer *s,GradientSurface *source,GradientSurface *destination,ZgTransform *value){
    Layers *layer=s->layers;if(!layer||!layer->active||!layer->depth||s->gradient_clip_depth||layer->groups[layer->depth-1].kind!=1)return 1;
    Target *child=layer_current(layer),*parent=&layer->targets[layer->depth>1?layer->depth:layer->work];
    const LayerGroup *frame=&layer->groups[layer->depth-1];const ZgTransform *transform=&frame->transform;
    if(frame->clip_depth>32||!child->pixels||!parent->pixels||child==parent||transform->pixel_width+2>child->width||transform->pixel_height+2>child->height)return 2;
    GradientSurface src={.pixels=child->pixels,.width=transform->pixel_width+2,.height=transform->pixel_height+2,.stride=(uint32_t)(child->stride/4),.scale=layer->scale,.origin={child->origin[0],child->origin[1]}};
    GradientSurface dst={.pixels=parent->pixels,.width=parent->width,.height=parent->height,.stride=(uint32_t)(parent->stride/4),.scale=layer->scale,.origin={parent->origin[0],parent->origin[1]}};
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
int zlc_offscreen_prepare(Renderer *s){return !s->layers||s->layers->active;}
int zlc_offscreen_begin(Renderer *s){
    if(!s->layers||s->layers->active)return 1;
    return layer_begin_mode(s,s->width,s->height,s->scale,1);
}
int zlc_offscreen_end(Renderer *s,uint8_t *output,size_t length){
    Layers *layer=s->layers;if(!layer||!layer->active)return 1;if(!layer->transparent_root)return 4;if(layer->depth||s->gradient_clip_depth)return 1;
    if(length!=(size_t)s->width*s->height*4)return 1;
    Target *work=layer_current(layer);
    for(uint32_t y=0;y<s->height;y++)memcpy(output+(size_t)y*s->width*4,(uint8_t *)work->pixels+(size_t)y*work->stride,(size_t)s->width*4);
    uint32_t previous=layer->front;layer->front=layer->work;layer->work=previous;layer->active=0;layer->front_transparent=1;layer->stats.committed_frames++;layer_alias(s,&layer->targets[layer->front]);return 0;
}
uint32_t zlc_test_live_layer_objects(void){return live_layer_objects;}
uint32_t zlc_layer_test_pixel(Renderer *s,int front,uint32_t x,uint32_t y){
    if(!s->layers||x>=s->width||y>=s->height)return 0;
    Target *target=front?&s->layers->targets[s->layers->front]:layer_current(s->layers);
    return target->pixels[(size_t)y*(target->stride/4)+x];
}
uint32_t zlc_layer_live_objects(void){return live_layer_objects;}

static void destroy(Renderer *s){
    if(s->layers){zlc_layer_free(s->layers);s->layers=NULL;s->target=NULL;return;}
    target_drop(&s->own);s->target=NULL;
}
int zlc_layer_copy_front(Renderer *s,Layers *candidate){
    if(!s->target||s->width!=candidate->width||s->height!=candidate->height||s->scale!=candidate->scale)return 0;
    Target *target=&candidate->targets[candidate->front];
    for(uint32_t y=0;y<s->height;y++)memcpy((uint8_t *)target->pixels+(size_t)y*target->stride,(uint8_t *)s->target->pixels+(size_t)y*s->target->stride,(size_t)s->width*4);
    candidate->front_transparent=s->layers?s->layers->front_transparent:0;
    return 0;
}
void zlc_layer_commit(Renderer *s,Layers *candidate){destroy(s);s->layers=candidate;s->width=candidate->width;s->height=candidate->height;s->scale=candidate->scale;s->generation++;layer_alias(s,&candidate->targets[candidate->front]);layer_reset_gradient_clip(s);}
int zlc_layer_release(Renderer *s){
    Layers *layer=s->layers;if(!layer)return 0;if(layer->active)return 1;if(layer->front_transparent)return 2;
    Target front=layer->targets[layer->front];target_reset(&front);memset(&layer->targets[layer->front],0,sizeof(front));
    /* The front plane becomes the ordinary renderer's plane. */
    live_layer_objects-=2;s->own=front;s->target=&s->own;s->layers=NULL;zlc_layer_free(layer);
    target_matrix(&s->own,s->scale,0,0);memcpy(s->origin,s->own.origin,sizeof(s->origin));layer_reset_gradient_clip(s);return 0;
}
void zlc_layer_abort(Renderer *s){layer_abort(s);}
Renderer *zlc_create(void){return calloc(1,sizeof(Renderer));}
int zlc_has_surface(Renderer *s){return s&&s->target&&s->target->pixels;}
static int begin_plane(Renderer *s,uint32_t width,uint32_t height,float scale){
    if(s->layers)return layer_begin(s,width,height,scale);
    if(!width||!height||!isfinite(scale)||scale<=0)return 1;
    if(s->target&&s->width==width&&s->height==height&&s->scale==scale){
        target_reset(&s->own);
        /* A transparent frame starts clear, unless it redraws only the
           damaged rectangles of the plane it keeps (mode 2). */
        if(s->window_transparent&&!s->keep_plane)target_clear(&s->own,0,0,width,height,0);
        return 0;
    }
    destroy(s);
    if(target_create(&s->own,width,height)){destroy(s);return 2;}
    s->target=&s->own;
    target_clear(&s->own,0,0,width,height,s->window_transparent?0:255);
    target_matrix(&s->own,scale,0,0);
    s->width=width;s->height=height;s->scale=scale;s->generation++;s->origin[0]=s->origin[1]=0;
    s->gradient_clip_depth=0;s->gradient_clips[0][0]=s->gradient_clips[0][1]=0;s->gradient_clips[0][2]=width;s->gradient_clips[0][3]=height;return 0;
}
/* transparent: 0 opaque, 1 transparent and cleared, 2 transparent with the
   plane's pixels kept for a redraw of its damaged rectangles. */
int zlc_begin_mode(Renderer *s,uint32_t width,uint32_t height,float scale,int transparent){
    s->window_transparent=transparent!=0;s->keep_plane=transparent==2;
    return begin_plane(s,width,height,scale);
}
int zlc_begin(Renderer *s,uint32_t width,uint32_t height,float scale){return zlc_begin_mode(s,width,height,scale,0);}
void zlc_fill(Renderer *s,float x,float y,float width,float height,uint32_t color){fill_user(s->target,x,y,width,height,rgb_color(color));}
int zlc_shape(Renderer *s,float x,float y,float width,float height,float radius,float stroke,uint32_t rgba){
    if(width==0||height==0||(rgba&255)==0)return 0;
    double fx=x,fy=y,fw=width,fh=height;if(fw<0){fx+=fw;fw=-fw;}if(fh<0){fy+=fh;fh=-fh;}
    const double r=fmin(radius,fmin(fw,fh)/2);
    const int ring=stroke>0&&fw>stroke*2&&fh>stroke*2;
    fill_rounded(s->target,fx,fy,fw,fh,fmax(0,r),ring,fx+stroke,fy+stroke,fw-stroke*2,fh-stroke*2,fmax(0,fmin(radius-stroke,fmin(fw-stroke*2,fh-stroke*2)/2)),rgba_color(rgba,1));
    return 0;
}
int zlc_gradient_surface(Renderer *s,GradientSurface *out){
    Target *t=s->target;if(!t||!t->pixels)return 1;
    *out=(GradientSurface){.pixels=t->pixels,.width=t->width,.height=t->height,.stride=(uint32_t)(t->stride/4),.scale=s->scale,.origin={s->origin[0],s->origin[1]}};
    memcpy(out->clip,s->gradient_clips[s->gradient_clip_depth],sizeof(out->clip));
    return 0;
}
void zlc_gradient_dirty(Renderer *s,uint32_t left,uint32_t top,uint32_t width,uint32_t height){(void)s;(void)left;(void)top;(void)width;(void)height;}
void zlc_brush_stats(Renderer *s,uint32_t *created,uint32_t *evicted,uint32_t *cached){(void)s;*created=*evicted=*cached=0;}
uint32_t zlc_test_live_patterns(void){return 0;}
int zlc_test_opaque(Renderer *s){
    Target *t=s->target;
    for(uint32_t y=0;y<t->height;y++)for(uint32_t x=0;x<t->width;x++)if((t->pixels[(size_t)y*(t->stride/4)+x]>>24)!=255)return 0;
    return 1;
}

/* The CSS font of a text command: the families as the system's, or the
   named one with the system's after it for what it lacks. */
static size_t css_font(char *out,size_t capacity,const char *named,float size,uint16_t weight,int italic,int monospace){
    static const char sans[]="system-ui, -apple-system, \"Segoe UI\", Roboto, \"Helvetica Neue\", Arial, \"Noto Sans\", sans-serif, \"Apple Color Emoji\", \"Segoe UI Emoji\"";
    static const char mono[]="ui-monospace, SFMono-Regular, Menlo, Consolas, \"Liberation Mono\", monospace";
    const int system=!named||!named[0]||!strcmp(named,"Sans")||!strcmp(named,"sans-serif")||!strcmp(named,"system-ui");
    const int fixed=(monospace&&system)||(named&&(!strcmp(named,"Monospace")||!strcmp(named,"monospace")||!strcmp(named,"ui-monospace")));
    const int serif=named&&(!strcmp(named,"Serif")||!strcmp(named,"serif")||!strcmp(named,"ui-serif"));
    const char *families=fixed?mono:serif?"ui-serif, Georgia, \"Times New Roman\", serif":sans;
    char quoted[160]="";
    if(!fixed&&!serif&&!system){size_t q=0;quoted[q++]='"';for(const char *c=named;*c&&q+4<sizeof(quoted);c++)if(*c!='"'&&*c!='\\')quoted[q++]=*c;quoted[q++]='"';quoted[q++]=',';quoted[q++]=' ';quoted[q]=0;}
    const int n=snprintf(out,capacity,"%s%u %.2fpx %s%s",italic?"italic ":"",(unsigned)(weight?weight:400),(double)size,quoted,families);
    return n>0&&(size_t)n<capacity?(size_t)n:0;
}
/* A text command: one line in the rectangle, centered on it vertically by
   the font's ascent and descent, cut with an ellipsis to its width. The
   page draws it at device pixels, with the pen's fraction of a pixel. */
int zlc_text(Renderer *s,float x,float y,float width,float height,const char *text,uint32_t length,uint32_t color,float size,uint16_t weight,int italic,int monospace,const char *family,float spacing){
    if(!(width>=0)||!(size>=1&&size<=1024)||!(spacing>=-1024&&spacing<=1024))return 1;
    if(!length)return 0;
    char font[512];const size_t font_length=css_font(font,sizeof(font),family,size*s->scale,weight,italic,monospace);if(!font_length)return 2;
    Target *t=s->target;
    const double pen_x=dx(t,x),fraction=pen_x-floor(pen_x);
    double info[6]={0};
    if(zw_text_draw(text,length,font,(uint32_t)font_length,(double)size*s->scale,(double)width*s->scale,fraction,color&0xffffff,(double)spacing*s->scale,info))return 2;
    const uint32_t w=(uint32_t)info[0],h=(uint32_t)info[1];if(!w||!h)return 0;
    const size_t need=(size_t)w*h;
    if(need>s->text_capacity){uint32_t *grown=realloc(s->text_pixels,need*4);if(!grown)return 2;s->text_pixels=grown;s->text_capacity=need;}
    zw_text_copy(s->text_pixels);
    const double ascent=info[4],descent=info[5];
    /* The baseline on a device pixel, as browsers place a page's text. */
    const double baseline=round(dy(t,y)+((double)height*s->scale-(ascent+descent))/2+ascent);
    target_save(t);clip_user(t,x,y,width,height);
    draw_pixels(t,s->text_pixels,w,h,(size_t)w*4,floor(pen_x)+info[2],baseline+info[3],1,1,1,0);
    target_restore(t);return 0;
}
typedef struct PreparedClip {float x,y,width,height;} PreparedClip;
float zlc_scale(Renderer *s){return s->scale;}
/* mask is the A8 coverage of prepared text. */
int zlc_prepared(Renderer *s,const ZgCoverage *mask,float x,float y,float scale,int32_t left,int32_t top,const PreparedClip *clip,uint32_t rgba){
    Target *t=s->target;target_save(t);
    if(clip)clip_user(t,(double)x+clip->x,(double)y+clip->y,clip->width,clip->height);
    fill_coverage(t,mask->pixels,mask->width,mask->height,mask->stride,dx(t,(double)x+(double)left/scale),dy(t,(double)y+(double)top/scale),t->scale/scale,t->scale/scale,rgba_color(rgba,1));
    target_restore(t);return 0;
}
void zlc_push_clip(Renderer *s,float x,float y,float width,float height){
    if(s->gradient_clip_depth>=32)return;
    double *before=s->gradient_clips[s->gradient_clip_depth],*after=s->gradient_clips[++s->gradient_clip_depth];
    after[0]=fmax(before[0],(double)x*s->scale+s->origin[0]);after[1]=fmax(before[1],(double)y*s->scale+s->origin[1]);
    after[2]=fmin(before[2],((double)x+width)*s->scale+s->origin[0]);after[3]=fmin(before[3],((double)y+height)*s->scale+s->origin[1]);
    target_save(s->target);clip_user(s->target,x,y,width,height);s->target->saves++;
}
/* Clips to device pixels x0..x1, y0..y1 of the plane, exactly on pixel
   edges whatever the scale; popped by zlc_pop_clip. */
void zlc_push_device_clip(Renderer *s,int32_t x0,int32_t y0,int32_t x1,int32_t y1){
    if(s->gradient_clip_depth>=32)return;
    double *before=s->gradient_clips[s->gradient_clip_depth],*after=s->gradient_clips[++s->gradient_clip_depth];
    after[0]=fmax(before[0],(double)x0+s->origin[0]);after[1]=fmax(before[1],(double)y0+s->origin[1]);
    after[2]=fmin(before[2],(double)x1+s->origin[0]);after[3]=fmin(before[3],(double)y1+s->origin[1]);
    target_save(s->target);clip_device(s->target,(double)x0+s->target->origin[0],(double)y0+s->target->origin[1],(double)x1+s->target->origin[0],(double)y1+s->target->origin[1]);s->target->saves++;
}
/* Clears a rectangle in DIP to transparent, within the current clip. */
void zlc_clear_rect(Renderer *s,float x,float y,float width,float height){
    if(width>=FLT_MAX){target_clear(s->target,0,0,s->target->width,s->target->height,0);return;}
    clear_user(s->target,x,y,width,height);
}
void zlc_pop_clip(Renderer *s){if(s->gradient_clip_depth){s->gradient_clip_depth--;target_restore(s->target);if(s->target->saves)s->target->saves--;}}
/* A clip level that cuts nothing more (an opacity's); popped by
   zlc_pop_clip. */
void zlc_push_keep(Renderer *s){
    if(s->gradient_clip_depth>=32)return;
    memcpy(s->gradient_clips[s->gradient_clip_depth+1],s->gradient_clips[s->gradient_clip_depth],sizeof(s->gradient_clips[0]));s->gradient_clip_depth++;
    target_save(s->target);s->target->saves++;
}
/* destination is the window's ID: the frame goes to its canvas. */
int zlc_end_checked(Renderer *s,void *destination){
    if(s->layers)return layer_end(s,destination);
    return present(s,s->target,destination);
}
void zlc_end(Renderer *s,void *destination){(void)zlc_end_checked(s,destination);}
void zlc_destroy(Renderer *s){if(s){destroy(s);for(unsigned i=0;i<s->image_capacity;i++)drop_image(&s->images[i]);free(s->images);drop_image(&s->image_candidate);free(s->text_pixels);free(s);}}
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
        image.pixels[bank][i]=(uint32_t *)pixels;image.stored[bank][i]=levels[i];image.stored[bank][i].pixels=pixels;
        image.objects++;live_image_objects++;s->image_creations++;
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
    if(fault==1||fault==2)return 2;
    CachedImage image={0};image.count=1;image.is_coverage=1;
    image.coverage_level=(ZiImageLevel){coverage->pixels,(size_t)coverage->stride*coverage->height,coverage->width,coverage->height,coverage->stride};
    image.objects=1;live_image_objects++;s->coverage_creations++;
    s->image_candidate=image;s->image_candidate.levels=&s->image_candidate.coverage_level;return 0;
}
int zlc_update_image(Renderer *s,uint32_t slot,const ZiImageLevel *levels,uint32_t count){
    if(slot>=s->image_capacity||!s->images[slot].dynamic||s->images[slot].count!=count)return 1;
    CachedImage *image=&s->images[slot];unsigned bank=1-image->active;uint32_t fault=s->image_fault;s->image_fault=0;
    size_t offset=0;
    for(uint32_t i=0;i<count;i++){
        if(fault==i+1)return 2;
        memcpy(image->pool[bank]+offset,levels[i].pixels,levels[i].byte_len);
        image->stored[bank][i]=levels[i];image->stored[bank][i].pixels=image->pool[bank]+offset;s->image_creations++;
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
    const ZiImageLevel *level=&s->images[slot].stored[s->images[slot].active][plan->level];const ZiImageRect *d=&plan->destination,*r=&plan->source;
    if(d->width<=0||d->height<=0||plan->opacity<=0)return 0;
    if(!(r->width>0&&r->height>0))return 1;
    const double sx=(double)d->width/r->width,sy=(double)d->height/r->height;
    Target *t=s->target;target_save(t);clip_user(t,d->x,d->y,d->width,d->height);
    draw_pixels(t,(const uint32_t *)level->pixels,level->width,level->height,level->stride,dx(t,(double)d->x-(double)r->x*sx),dy(t,(double)d->y-(double)r->y*sy),sx*t->scale,sy*t->scale,plan->opacity>1?1:plan->opacity,plan->sampling!=0);
    target_restore(t);return 0;
}
int zlc_coverage(Renderer *s,uint32_t slot,float x,float y,float scale,int32_t left,int32_t top,uint32_t rgba){
    if(slot>=s->image_capacity||!s->images[slot].is_coverage)return 1;
    const ZiImageLevel *level=&s->images[slot].coverage_level;
    const ZgCoverage mask={level->pixels,level->byte_len,level->width,level->height,level->stride,left,top,scale};
    return zlc_prepared(s,&mask,x,y,scale,left,top,NULL,rgba);
}
static uint32_t raster_objects(Renderer *s,int coverage){uint32_t n=0;for(unsigned i=0;i<s->image_capacity;i++)if(s->images[i].is_coverage==(uint32_t)coverage)n+=s->images[i].objects;return n;}
uint32_t zlc_image_objects(Renderer *s){return raster_objects(s,0);}
uint64_t zlc_image_creations(Renderer *s){return s->image_creations;}
uint32_t zlc_coverage_objects(Renderer *s){return raster_objects(s,1);}
uint64_t zlc_coverage_creations(Renderer *s){return s->coverage_creations;}
uint32_t zlc_test_live_image_objects(void){return live_image_objects;}
uint32_t zlc_test_pixel(Renderer *s,uint32_t x,uint32_t y){
    x=(uint32_t)(x*s->scale);y=(uint32_t)(y*s->scale);
    if(x>=s->width||y>=s->height)return 0xffffffff;
    return s->target->pixels[(size_t)y*(s->target->stride/4)+x]&0xffffff;
}
uint32_t zlc_test_raw_pixel(Renderer *s,uint32_t x,uint32_t y){
    if(x>=s->width||y>=s->height)return 0xffffffff;
    return s->target->pixels[(size_t)y*(s->target->stride/4)+x]&0xffffff;
}
uint32_t zlc_test_text_pixels(Renderer *s){
    uint32_t count=0;
    for(uint32_t y=8;y<48;y++)for(uint32_t x=8;x<288;x++)if(zlc_test_pixel(s,x,y)!=0xffffff)count++;
    return count;
}
uint32_t zlc_test_generation(Renderer *s){return s->generation;}
size_t zlc_surface_bytes(Renderer *s){return s->target?(size_t)s->width*s->height*4:0;}

/* Shader effects run on OpenGL only on Linux desktops; browsers draw them
   on the CPU, in the software plane. */
void *zgl_effects_create(int force,char *log,size_t log_len){(void)force;if(log_len){const char m[]="no OpenGL effects in browsers";size_t n=sizeof(m)<log_len?sizeof(m):log_len;memcpy(log,m,n);log[n-1]=0;}return NULL;}
void zgl_effects_destroy(void *gl){(void)gl;}
int zgl_effects_install(void *gl,uint32_t slot,const char *source,char *log,size_t log_len){(void)gl;(void)slot;(void)source;if(log_len)log[0]=0;return 1;}
int zgl_effects_run(void *gl,uint32_t slot,const uint32_t *words,uint32_t word_count,const void *params,const uint32_t *content,uint32_t content_width,uint32_t content_height,size_t content_stride,uint32_t *out,uint32_t out_width,uint32_t out_height,size_t out_stride){
    (void)gl;(void)slot;(void)words;(void)word_count;(void)params;(void)content;(void)content_width;(void)content_height;(void)content_stride;(void)out;(void)out_width;(void)out_height;(void)out_stride;return 1;
}
uint64_t zgl_effects_passes(void *gl){(void)gl;return 0;}
