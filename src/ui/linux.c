#include <pango/pangocairo.h>
#include <stdint.h>
#include <math.h>
#include <float.h>
#include <string.h>
#include "brushes.h"
#include "image_resource.h"
#include "coverage_resource.h"

typedef struct GradientSurface {uint32_t *pixels;uint32_t width,height,stride;float scale;double clip[4],origin[2];} GradientSurface;
#if UINTPTR_MAX == UINT64_MAX
_Static_assert(sizeof(GradientSurface)==72,"software plane ABI");
_Static_assert(offsetof(GradientSurface,clip)==24&&offsetof(GradientSurface,origin)==56,"software plane offsets");
#endif

typedef struct CachedImage {cairo_surface_t *surfaces[2][ZI_IMAGE_LEVELS];cairo_pattern_t *patterns[2][ZI_IMAGE_LEVELS];uint8_t *pool[2];const ZiImageLevel *levels;ZiImageLevel coverage_level;uint32_t count,dynamic,active,is_coverage;} CachedImage;
static uint32_t live_image_objects;
static void drop_image(CachedImage *image){for(unsigned bank=0;bank<2;bank++){for(uint32_t i=0;i<image->count;i++){if(image->patterns[bank][i]){cairo_pattern_destroy(image->patterns[bank][i]);live_image_objects--;}if(image->surfaces[bank][i]){cairo_surface_destroy(image->surfaces[bank][i]);live_image_objects--;}}g_free(image->pool[bank]);}memset(image,0,sizeof(*image));}

typedef struct CairoLayers CairoLayers;
typedef struct Renderer {
    cairo_surface_t *surface;
    cairo_t *context;
    PangoLayout *layout;
    PangoFontDescription *font;
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
    CairoLayers *layers;
    /* The window frame starts transparent and is presented with its alpha
       (Paint.transparent), not over an opaque white plane. */
    int window_transparent;
} Renderer;
#include "linux_layers.h"
static void destroy(Renderer *s) {
    if(s->layers){zlc_layer_free(s->layers);s->layers=NULL;s->layout=NULL;s->font=NULL;s->context=NULL;s->surface=NULL;return;}
    if(s->layout)g_object_unref(s->layout);
    if(s->font)pango_font_description_free(s->font);
    if(s->context)cairo_destroy(s->context);
    if(s->surface)cairo_surface_destroy(s->surface);
    s->layout=NULL;s->font=NULL;s->context=NULL;s->surface=NULL;
}
int zlc_layer_copy_front(Renderer *s,CairoLayers *candidate){
    if(!s->surface||s->width!=candidate->width||s->height!=candidate->height||s->scale!=candidate->scale)return 0;
    cairo_t *target=candidate->targets[candidate->front].context;
    cairo_save(target);cairo_identity_matrix(target);cairo_set_operator(target,CAIRO_OPERATOR_SOURCE);cairo_set_source_surface(target,s->surface,0,0);cairo_paint(target);cairo_restore(target);
    candidate->front_transparent=s->layers?s->layers->front_transparent:0;
    return cairo_status(target)==CAIRO_STATUS_SUCCESS?0:1;
}
void zlc_layer_commit(Renderer *s,CairoLayers *candidate){destroy(s);s->layers=candidate;s->width=candidate->width;s->height=candidate->height;s->scale=candidate->scale;s->generation++;layer_alias(s,&candidate->targets[candidate->front]);layer_reset_gradient_clip(s);}
int zlc_layer_release(Renderer *s){
    CairoLayers *layer=s->layers;if(!layer)return 0;if(layer->active)return 1;if(layer->front_transparent)return 2;
    CairoTarget front=layer->targets[layer->front];layer_reset_target(&front);memset(&layer->targets[layer->front],0,sizeof(front));
    if(front.pattern){cairo_pattern_destroy(front.pattern);live_layer_objects--;}
    s->surface=front.surface;s->context=front.context;s->layout=layer->layout;s->font=layer->font;
    /* These four references become the ordinary renderer's existing front. */
    live_layer_objects-=4;layer->layout=NULL;layer->font=NULL;s->layers=NULL;zlc_layer_free(layer);layer_reset_gradient_clip(s);return 0;
}
void zlc_layer_abort(Renderer *s){layer_abort(s);}
Renderer *zlc_create(void) { return g_try_new0(Renderer,1); }
int zlc_has_surface(Renderer *s) {return s && s->surface && s->context;}
static void clear_transparent(Renderer *s){
    cairo_save(s->context);cairo_identity_matrix(s->context);cairo_set_operator(s->context,CAIRO_OPERATOR_CLEAR);cairo_paint(s->context);cairo_restore(s->context);
}
/* transparent: 0 opaque, 1 transparent and cleared, 2 transparent with the
   last frame's pixels kept (the caller clears what it draws again). */
int zlc_begin_mode(Renderer *s,uint32_t width,uint32_t height,float scale,int transparent) {
    s->window_transparent=transparent!=0;
    if(s->layers)return layer_begin(s,width,height,scale);
    if(!width||!height||!isfinite(scale)||scale<=0)return 1;
    if(s->surface && s->width==width && s->height==height && s->scale==scale){if(transparent==1)clear_transparent(s);return 0;}
    destroy(s);
    s->surface=cairo_image_surface_create(CAIRO_FORMAT_ARGB32,width,height);
    if(cairo_surface_status(s->surface)!=CAIRO_STATUS_SUCCESS) { destroy(s);return 2; }
    s->context=cairo_create(s->surface);
    if(cairo_status(s->context)!=CAIRO_STATUS_SUCCESS) { destroy(s);return 2; }
    /* The renderer owns an opaque window plane. Initialize it once, including
       when the first frame contains only translucent shapes or gradients. */
    if(s->window_transparent)clear_transparent(s);else{cairo_set_source_rgb(s->context,1,1,1);cairo_paint(s->context);}
    cairo_scale(s->context,scale,scale);
    s->layout=pango_cairo_create_layout(s->context);
    s->font=pango_font_description_new();pango_font_description_set_family(s->font,"Sans");
    pango_font_description_set_absolute_size(s->font,16*PANGO_SCALE);
    pango_layout_set_font_description(s->layout,s->font);
    pango_layout_set_single_paragraph_mode(s->layout,TRUE);pango_layout_set_ellipsize(s->layout,PANGO_ELLIPSIZE_END);
    pango_layout_set_height(s->layout,-1);
    s->width=width;s->height=height;s->scale=scale;s->generation++;
    s->gradient_clip_depth=0;s->gradient_clips[0][0]=s->gradient_clips[0][1]=0;s->gradient_clips[0][2]=width;s->gradient_clips[0][3]=height;return 0;
}
void zlc_fill(Renderer *s,float x,float y,float width,float height,uint32_t color) {
    cairo_set_source_rgb(s->context,(double)((color>>16)&255)/255,(double)((color>>8)&255)/255,(double)(color&255)/255);
    cairo_rectangle(s->context,x,y,width,height);cairo_fill(s->context);
}
static void rounded_path(cairo_t *cr,double x,double y,double w,double h,double r) {
    if(r<=0) {cairo_rectangle(cr,x,y,w,h);return;}
    const double pi=3.14159265358979323846;
    cairo_new_sub_path(cr);
    cairo_arc(cr,x+w-r,y+r,r,-pi/2,0);cairo_arc(cr,x+w-r,y+h-r,r,0,pi/2);
    cairo_arc(cr,x+r,y+h-r,r,pi/2,pi);cairo_arc(cr,x+r,y+r,r,pi,pi*1.5);cairo_close_path(cr);
}
int zlc_shape(Renderer *s,float x,float y,float width,float height,float radius,float stroke,uint32_t rgba) {
    if(width==0||height==0||(rgba&255)==0)return 0;
    cairo_save(s->context);cairo_new_path(s->context);
    cairo_set_source_rgba(s->context,(double)(rgba>>24)/255,(double)((rgba>>16)&255)/255,(double)((rgba>>8)&255)/255,(double)(rgba&255)/255);
    cairo_set_fill_rule(s->context,CAIRO_FILL_RULE_EVEN_ODD);
    rounded_path(s->context,x,y,width,height,radius);
    if(stroke>0&&width>stroke*2&&height>stroke*2)rounded_path(s->context,x+stroke,y+stroke,width-stroke*2,height-stroke*2,MAX(0,radius-stroke));
    cairo_fill(s->context);cairo_restore(s->context);
    return cairo_status(s->context)==CAIRO_STATUS_SUCCESS?0:1;
}
int zlc_gradient_surface(Renderer *s,GradientSurface *out){
    if(cairo_status(s->context)!=CAIRO_STATUS_SUCCESS)return 1;
    cairo_surface_flush(s->surface);
    *out=(GradientSurface){.pixels=(uint32_t *)cairo_image_surface_get_data(s->surface),.width=(uint32_t)cairo_image_surface_get_width(s->surface),.height=(uint32_t)cairo_image_surface_get_height(s->surface),.stride=(uint32_t)cairo_image_surface_get_stride(s->surface)/4,.scale=s->scale,.origin={s->origin[0],s->origin[1]}};
    /* Cairo clip_extents returns a raster bounding box, losing fractional
       rectangle coverage. Keep the exact bounded geometric intersection. */
    memcpy(out->clip,s->gradient_clips[s->gradient_clip_depth],sizeof(out->clip));
    return 0;
}
void zlc_gradient_dirty(Renderer *s,uint32_t left,uint32_t top,uint32_t width,uint32_t height){if(width&&height)cairo_surface_mark_dirty_rectangle(s->surface,left,top,width,height);}
void zlc_brush_stats(Renderer *s,uint32_t *created,uint32_t *evicted,uint32_t *cached){(void)s;*created=*evicted=*cached=0;}
uint32_t zlc_test_live_patterns(void){return 0;}
int zlc_test_opaque(Renderer *s) {
    cairo_surface_flush(s->surface);unsigned char *data=cairo_image_surface_get_data(s->surface);int stride=cairo_image_surface_get_stride(s->surface);
    for(uint32_t y=0;y<s->height;y++)for(uint32_t x=0;x<s->width;x++)if(data[y*stride+x*4+3]!=255)return 0;
    return 1;
}
/* Points the shared description at the requested font, touching the
   layout only when something differs from the last text drawn. A family
   given by name stays valid for the process. */
static void use_font(Renderer *s,const char *named,float size,uint16_t weight,int italic,int monospace){
    const char *family=named&&named[0]?named:monospace?"Monospace":"Sans";
    gint absolute=(gint)(size*PANGO_SCALE+0.5f);
    PangoStyle style=italic?PANGO_STYLE_ITALIC:PANGO_STYLE_NORMAL;
    const char *current=pango_font_description_get_family(s->font);
    if(current&&strcmp(current,family)==0&&pango_font_description_get_size(s->font)==absolute&&pango_font_description_get_size_is_absolute(s->font)&&
       pango_font_description_get_weight(s->font)==(PangoWeight)weight&&pango_font_description_get_style(s->font)==style)return;
    pango_font_description_set_family_static(s->font,family);pango_font_description_set_absolute_size(s->font,absolute);
    pango_font_description_set_weight(s->font,(PangoWeight)weight);pango_font_description_set_style(s->font,style);
    pango_layout_set_font_description(s->layout,s->font);
}
int zlc_text(Renderer *s,float x,float y,float width,float height,const char *text,uint32_t length,uint32_t color,float size,uint16_t weight,int italic,int monospace,const char *family) {
    if(width>G_MAXINT/PANGO_SCALE || length>G_MAXINT || !(size>=1&&size<=1024))return 1;
    use_font(s,family,size,weight,italic,monospace);
    pango_layout_set_text(s->layout,text,length);pango_layout_set_width(s->layout,(int)(width*PANGO_SCALE));
    int layout_width,layout_height;pango_layout_get_size(s->layout,&layout_width,&layout_height);
    cairo_save(s->context);cairo_rectangle(s->context,x,y,width,height);cairo_clip(s->context);
    cairo_set_source_rgb(s->context,(double)((color>>16)&255)/255,(double)((color>>8)&255)/255,(double)(color&255)/255);
    cairo_move_to(s->context,x,y+(height-(double)layout_height/PANGO_SCALE)/2);pango_cairo_show_layout(s->context,s->layout);cairo_restore(s->context);
    return cairo_status(s->context)==CAIRO_STATUS_SUCCESS?0:2;
}
typedef struct PreparedClip {float x,y,width,height;} PreparedClip;
float zlc_scale(Renderer *s){return s->scale;}
int zlc_prepared(Renderer *s,cairo_pattern_t *mask,float x,float y,float scale,int32_t left,int32_t top,const PreparedClip *clip,uint32_t rgba){
    cairo_save(s->context);
    if(clip){cairo_rectangle(s->context,(double)x+clip->x,(double)y+clip->y,clip->width,clip->height);cairo_clip(s->context);}
    cairo_translate(s->context,(double)x+(double)left/scale,(double)y+(double)top/scale);cairo_scale(s->context,1.0/scale,1.0/scale);
    cairo_set_source_rgba(s->context,(double)(rgba>>24)/255,(double)((rgba>>16)&255)/255,(double)((rgba>>8)&255)/255,(double)(rgba&255)/255);
    cairo_mask(s->context,mask);cairo_restore(s->context);return cairo_status(s->context)==CAIRO_STATUS_SUCCESS?0:1;
}
void zlc_push_clip(Renderer *s,float x,float y,float width,float height) {
    if(s->gradient_clip_depth>=32)return;
    double *before=s->gradient_clips[s->gradient_clip_depth],*after=s->gradient_clips[++s->gradient_clip_depth];
    after[0]=fmax(before[0],(double)x*s->scale+s->origin[0]);after[1]=fmax(before[1],(double)y*s->scale+s->origin[1]);
    after[2]=fmin(before[2],((double)x+width)*s->scale+s->origin[0]);after[3]=fmin(before[3],((double)y+height)*s->scale+s->origin[1]);
    cairo_save(s->context);cairo_rectangle(s->context,x,y,width,height);cairo_clip(s->context);
    if(s->layers&&s->layers->active)layer_current(s->layers)->saves++;
}
/* Clips to device pixels x0..x1, y0..y1 of the plane, exactly on pixel
   edges whatever the scale; popped by zlc_pop_clip. */
void zlc_push_device_clip(Renderer *s,int32_t x0,int32_t y0,int32_t x1,int32_t y1){
    if(s->gradient_clip_depth>=32)return;
    double *before=s->gradient_clips[s->gradient_clip_depth],*after=s->gradient_clips[++s->gradient_clip_depth];
    after[0]=fmax(before[0],(double)x0+s->origin[0]);after[1]=fmax(before[1],(double)y0+s->origin[1]);
    after[2]=fmin(before[2],(double)x1+s->origin[0]);after[3]=fmin(before[3],(double)y1+s->origin[1]);
    cairo_save(s->context);cairo_matrix_t matrix;cairo_get_matrix(s->context,&matrix);cairo_identity_matrix(s->context);
    cairo_new_path(s->context);cairo_rectangle(s->context,(double)x0+s->origin[0],(double)y0+s->origin[1],(double)x1-x0,(double)y1-y0);cairo_clip(s->context);
    cairo_set_matrix(s->context,&matrix);
    if(s->layers&&s->layers->active)layer_current(s->layers)->saves++;
}
/* Clears a rectangle in DIP to transparent, within the current clip. */
void zlc_clear_rect(Renderer *s,float x,float y,float width,float height){
    if(width>=FLT_MAX){clear_transparent(s);return;}
    cairo_save(s->context);cairo_new_path(s->context);cairo_rectangle(s->context,x,y,width,height);cairo_clip(s->context);
    cairo_set_operator(s->context,CAIRO_OPERATOR_CLEAR);cairo_paint(s->context);cairo_restore(s->context);
}
void zlc_pop_clip(Renderer *s) { if(s->gradient_clip_depth){s->gradient_clip_depth--;cairo_restore(s->context);if(s->layers&&s->layers->active)layer_current(s->layers)->saves--;} }
int zlc_end_checked(Renderer *s,cairo_t *destination){
    if(s->layers)return layer_end(s,destination);
    cairo_save(destination);if(s->window_transparent)cairo_set_operator(destination,CAIRO_OPERATOR_SOURCE);cairo_scale(destination,1.0/s->scale,1.0/s->scale);cairo_set_source_surface(destination,s->surface,0,0);cairo_paint(destination);cairo_restore(destination);return cairo_status(destination)==CAIRO_STATUS_SUCCESS?0:2;
}
int zlc_begin(Renderer *s,uint32_t width,uint32_t height,float scale) {return zlc_begin_mode(s,width,height,scale,0);}
void zlc_end(Renderer *s,cairo_t *destination) {
    (void)zlc_end_checked(s,destination);
}
void zlc_destroy(Renderer *s) { if(s){destroy(s);for(unsigned i=0;i<s->image_capacity;i++)drop_image(&s->images[i]);g_free(s->images);drop_image(&s->image_candidate);g_free(s);} }
static int prepare_image(Renderer *s,const ZiImageLevel *levels,uint32_t count,int dynamic){
    if(count==0||count>ZI_IMAGE_LEVELS||s->image_candidate.count)return 1;
    uint32_t fault=s->image_fault;s->image_fault=0;
    CachedImage image={0};image.count=count;image.dynamic=dynamic;image.levels=levels;
    size_t bytes=0;for(uint32_t i=0;i<count;i++)bytes+=levels[i].byte_len;
    for(unsigned bank=0;bank<(dynamic?2u:1u);bank++){
      if(dynamic){image.pool[bank]=g_try_malloc(bytes);if(!image.pool[bank])goto failed;}
      size_t offset=0;
      for(uint32_t i=0;i<count;i++){
        if(fault==bank*count+i+1)goto failed;
        uint8_t *pixels=dynamic?image.pool[bank]+offset:(uint8_t *)levels[i].pixels;
        if(dynamic)memcpy(pixels,levels[i].pixels,levels[i].byte_len);
        image.surfaces[bank][i]=cairo_image_surface_create_for_data(pixels,CAIRO_FORMAT_ARGB32,(int)levels[i].width,(int)levels[i].height,(int)levels[i].stride);live_image_objects++;s->image_creations++;
        if(cairo_surface_status(image.surfaces[bank][i])!=CAIRO_STATUS_SUCCESS)goto failed;
        image.patterns[bank][i]=cairo_pattern_create_for_surface(image.surfaces[bank][i]);live_image_objects++;s->image_creations++;
        if(cairo_pattern_status(image.patterns[bank][i])!=CAIRO_STATUS_SUCCESS)goto failed;
        cairo_pattern_set_extend(image.patterns[bank][i],CAIRO_EXTEND_PAD);offset+=levels[i].byte_len;
      }
    }
    s->image_candidate=image;return 0;
failed:drop_image(&image);return 2;
}
int zlc_prepare_image(Renderer *s,const ZiImageLevel *levels,uint32_t count){return prepare_image(s,levels,count,0);}
int zlc_prepare_dynamic_image(Renderer *s,const ZiImageLevel *levels,uint32_t count){return prepare_image(s,levels,count,1);}
int zlc_prepare_coverage(Renderer *s,const ZgCoverage *coverage){
    if(s->image_candidate.count)return 1;
    uint32_t fault=s->image_fault;s->image_fault=0;
    CachedImage image={0};image.count=1;image.is_coverage=1;
    int stride=cairo_format_stride_for_width(CAIRO_FORMAT_A8,(int)coverage->width);
    if(stride<0)return 1;
    uint8_t *pixels=(uint8_t *)coverage->pixels;
    if(coverage->stride!=(uint32_t)stride){
        image.pool[0]=g_try_malloc0((size_t)stride*coverage->height);if(!image.pool[0])goto failed;
        pixels=image.pool[0];for(uint32_t y=0;y<coverage->height;y++)memcpy(pixels+(size_t)y*stride,coverage->pixels+(size_t)y*coverage->stride,coverage->width);
    }
    image.coverage_level=(ZiImageLevel){pixels,(size_t)stride*coverage->height,coverage->width,coverage->height,(uint32_t)stride};
    if(fault==1)goto failed;
    image.surfaces[0][0]=cairo_image_surface_create_for_data(pixels,CAIRO_FORMAT_A8,(int)coverage->width,(int)coverage->height,stride);live_image_objects++;s->coverage_creations++;
    if(cairo_surface_status(image.surfaces[0][0])!=CAIRO_STATUS_SUCCESS)goto failed;
    if(fault==2)goto failed;
    image.patterns[0][0]=cairo_pattern_create_for_surface(image.surfaces[0][0]);live_image_objects++;s->coverage_creations++;
    if(cairo_pattern_status(image.patterns[0][0])!=CAIRO_STATUS_SUCCESS)goto failed;
    cairo_pattern_set_extend(image.patterns[0][0],CAIRO_EXTEND_NONE);cairo_pattern_set_filter(image.patterns[0][0],CAIRO_FILTER_BILINEAR);
    s->image_candidate=image;s->image_candidate.levels=&s->image_candidate.coverage_level;return 0;
failed:drop_image(&image);return 2;
}
int zlc_update_image(Renderer *s,uint32_t slot,const ZiImageLevel *levels,uint32_t count){
    if(slot>=s->image_capacity||!s->images[slot].dynamic||s->images[slot].count!=count)return 1;
    CachedImage *image=&s->images[slot];unsigned bank=1-image->active;uint32_t fault=s->image_fault;s->image_fault=0;
    for(uint32_t i=0;i<count;i++){
        if(fault==i+1)return 2;
        cairo_surface_t *surface=image->surfaces[bank][i];cairo_surface_flush(surface);
        if(cairo_surface_status(surface)!=CAIRO_STATUS_SUCCESS)return 2;
        memcpy(cairo_image_surface_get_data(surface),levels[i].pixels,levels[i].byte_len);
        cairo_surface_mark_dirty(surface);if(cairo_surface_status(surface)!=CAIRO_STATUS_SUCCESS)return 2;
    }
    image->active=bank;image->levels=levels;return 0;
}
/* Grow the slot table; coverage entries point at their own level, so moved
   entries are pointed at it again. */
int zlc_reserve_images(Renderer *s,uint32_t capacity){
    if(capacity<=s->image_capacity)return 0;
    CachedImage *images=g_try_realloc_n(s->images,capacity,sizeof(*images));if(!images)return 1;
    memset(images+s->image_capacity,0,(size_t)(capacity-s->image_capacity)*sizeof(*images));
    for(uint32_t i=0;i<s->image_capacity;i++)if(images[i].is_coverage)images[i].levels=&images[i].coverage_level;
    s->images=images;s->image_capacity=capacity;return 0;
}
void zlc_commit_image(Renderer *s,uint32_t slot){drop_image(&s->images[slot]);s->images[slot]=s->image_candidate;if(s->images[slot].is_coverage)s->images[slot].levels=&s->images[slot].coverage_level;memset(&s->image_candidate,0,sizeof(s->image_candidate));}
void zlc_image_fault(Renderer *s,uint32_t mip){s->image_fault=mip;}
void zlc_release_image(Renderer *s,uint32_t slot){if(slot<s->image_capacity)drop_image(&s->images[slot]);}
int zlc_image(Renderer *s,uint32_t slot,const ZiImagePlan *plan){
    if(slot>=s->image_capacity||plan->level>=s->images[slot].count)return 1;
    cairo_pattern_t *pattern=s->images[slot].patterns[s->images[slot].active][plan->level];const ZiImageRect *d=&plan->destination,*r=&plan->source;
    if(d->width<=0||d->height<=0||plan->opacity<=0)return 0;
    cairo_matrix_t matrix;cairo_matrix_init(&matrix,(double)r->width/d->width,0,0,(double)r->height/d->height,(double)r->x-(double)d->x*r->width/d->width,(double)r->y-(double)d->y*r->height/d->height);
    cairo_pattern_set_matrix(pattern,&matrix);cairo_pattern_set_filter(pattern,plan->sampling?CAIRO_FILTER_BILINEAR:CAIRO_FILTER_NEAREST);
    cairo_save(s->context);cairo_rectangle(s->context,d->x,d->y,d->width,d->height);cairo_clip(s->context);
    cairo_set_source(s->context,pattern);cairo_paint_with_alpha(s->context,plan->opacity);cairo_restore(s->context);
    return cairo_status(s->context)==CAIRO_STATUS_SUCCESS?0:2;
}
int zlc_coverage(Renderer *s,uint32_t slot,float x,float y,float scale,int32_t left,int32_t top,uint32_t rgba){
    if(slot>=s->image_capacity||!s->images[slot].is_coverage)return 1;
    return zlc_prepared(s,s->images[slot].patterns[0][0],x,y,scale,left,top,NULL,rgba);
}
static uint32_t raster_objects(Renderer *s,int coverage){uint32_t n=0;for(unsigned i=0;i<s->image_capacity;i++)if(s->images[i].is_coverage==(uint32_t)coverage)for(unsigned bank=0;bank<2;bank++)for(unsigned j=0;j<s->images[i].count;j++){if(s->images[i].surfaces[bank][j])n++;if(s->images[i].patterns[bank][j])n++;}return n;}
uint32_t zlc_image_objects(Renderer *s){return raster_objects(s,0);}
uint64_t zlc_image_creations(Renderer *s){return s->image_creations;}
uint32_t zlc_coverage_objects(Renderer *s){return raster_objects(s,1);}
uint64_t zlc_coverage_creations(Renderer *s){return s->coverage_creations;}
uint32_t zlc_test_live_image_objects(void){return live_image_objects;}
uint32_t zlc_test_pixel(Renderer *s,uint32_t x,uint32_t y) {
    x=(uint32_t)(x*s->scale);y=(uint32_t)(y*s->scale);
    if(x>=s->width||y>=s->height)return 0xffffffff;
    cairo_surface_flush(s->surface);
    const unsigned char *pixel=cairo_image_surface_get_data(s->surface)+y*cairo_image_surface_get_stride(s->surface)+x*4;
    return ((uint32_t)pixel[2]<<16)|((uint32_t)pixel[1]<<8)|pixel[0];
}
uint32_t zlc_test_raw_argb(Renderer *s,uint32_t x,uint32_t y) {
    if(!s->surface||x>=s->width||y>=s->height)return 0;cairo_surface_flush(s->surface);
    const unsigned char *pixel=cairo_image_surface_get_data(s->surface)+y*cairo_image_surface_get_stride(s->surface)+x*4;
    return ((uint32_t)pixel[3]<<24)|((uint32_t)pixel[2]<<16)|((uint32_t)pixel[1]<<8)|pixel[0];
}
uint32_t zlc_test_raw_pixel(Renderer *s,uint32_t x,uint32_t y) {
    if(x>=s->width||y>=s->height)return 0xffffffff;cairo_surface_flush(s->surface);
    const unsigned char *pixel=cairo_image_surface_get_data(s->surface)+y*cairo_image_surface_get_stride(s->surface)+x*4;
    return ((uint32_t)pixel[2]<<16)|((uint32_t)pixel[1]<<8)|pixel[0];
}
uint32_t zlc_test_text_pixels(Renderer *s) {
    uint32_t count=0;
    for(uint32_t y=8;y<48;y++)for(uint32_t x=8;x<288;x++)if(zlc_test_pixel(s,x,y)!=0xffffff)count++;
    return count;
}
uint32_t zlc_test_generation(Renderer *s) {return s->generation;}

size_t zlc_surface_bytes(Renderer *s){return s->surface?(size_t)s->width*s->height*4:0;}
