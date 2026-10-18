/* Isolated benchmark of the previous native pattern path. Never linked into UI. */
#include <cairo.h>
#include <stdint.h>
#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include "../src/ui/brushes.h"
#define MAX(a,b) ((a)>(b)?(a):(b))
typedef struct GradientBrush {ZgBrush key;cairo_pattern_t *alpha,*color;uint64_t used;} GradientBrush;
typedef struct Bench {cairo_surface_t *surface;cairo_t *context;GradientBrush brushes[ZG_BRUSH_CAPACITY];uint64_t brush_clock;uint32_t brush_creations,brush_evictions;} Bench;
static uint32_t live_patterns;
static void drop_pattern(cairo_pattern_t **pattern){if(*pattern){cairo_pattern_destroy(*pattern);*pattern=NULL;live_patterns--;}}
static void rounded_path(cairo_t *cr,double x,double y,double w,double h,double r) {
    if(r<=0) {cairo_rectangle(cr,x,y,w,h);return;}
    const double pi=3.14159265358979323846;
    cairo_new_sub_path(cr);
    cairo_arc(cr,x+w-r,y+r,r,-pi/2,0);cairo_arc(cr,x+w-r,y+h-r,r,0,pi/2);
    cairo_arc(cr,x+r,y+h-r,r,pi/2,pi);cairo_arc(cr,x+r,y+r,r,pi,pi*1.5);cairo_close_path(cr);
}
static cairo_pattern_t *gradient_pattern(const ZgBrush *brush,int alpha) {
    cairo_pattern_t *pattern;
    if(brush->kind==0)pattern=cairo_pattern_create_linear(0,0,1,0);
    else pattern=cairo_pattern_create_radial(0,0,0,0,0,1);
    live_patterns++;
    cairo_pattern_set_extend(pattern,CAIRO_EXTEND_PAD);
    for(unsigned i=0;i<brush->len;i++) {
        uint32_t rgba=brush->stops[i].rgba;double a=(double)(rgba&255)/255;
        cairo_pattern_add_color_stop_rgba(pattern,brush->stops[i].offset,
            alpha?0:(double)(rgba>>24)/255*a,alpha?0:(double)((rgba>>16)&255)/255*a,alpha?0:(double)((rgba>>8)&255)/255*a,alpha?a:1);
    }
    return pattern;
}
static GradientBrush *cached_brush(Bench *s,const ZgBrush *key) {
    if(s->brush_clock==UINT64_MAX){s->brush_clock=0;for(unsigned i=0;i<ZG_BRUSH_CAPACITY;i++)s->brushes[i].used=0;}
    uint64_t now=++s->brush_clock;unsigned victim=0;
    for(unsigned i=0;i<ZG_BRUSH_CAPACITY;i++) {
        GradientBrush *entry=&s->brushes[i];
        if(entry->alpha&&entry->key.kind==key->kind&&entry->key.len==key->len&&!memcmp(entry->key.stops,key->stops,key->len*sizeof(ZgStop))){entry->used=now;return entry;}
        if(!entry->alpha||(s->brushes[victim].alpha&&entry->used<s->brushes[victim].used))victim=i;
    }
    cairo_pattern_t *alpha=gradient_pattern(key,1),*color=gradient_pattern(key,0);
    if(cairo_pattern_status(alpha)!=CAIRO_STATUS_SUCCESS||cairo_pattern_status(color)!=CAIRO_STATUS_SUCCESS){drop_pattern(&alpha);drop_pattern(&color);return NULL;}
    GradientBrush *entry=&s->brushes[victim];
    if(entry->alpha){drop_pattern(&entry->alpha);drop_pattern(&entry->color);s->brush_evictions++;}
    *entry=(GradientBrush){*key,alpha,color,now};s->brush_creations++;return entry;
}
int zbench_gradient_draw(Bench *s,float x,float y,float width,float height,float radius,float stroke,const ZgBrush *brush) {
    if(width==0||height==0)return 0;
    GradientBrush *entry=cached_brush(s,brush);if(!entry)return 1;
    cairo_matrix_t matrix;
    if(brush->kind==0){
        double dx=(double)brush->x1-brush->x0,dy=(double)brush->y1-brush->y0,length=dx*dx+dy*dy;
        cairo_matrix_init(&matrix,dx/length,-dy/length,dy/length,dx/length,-((double)brush->x0*dx+(double)brush->y0*dy)/length,((double)brush->x0*dy-(double)brush->y0*dx)/length);
    }else cairo_matrix_init(&matrix,1.0/brush->x1,0,0,1.0/brush->y1,-(double)brush->x0/brush->x1,-(double)brush->y0/brush->y1);
    cairo_pattern_set_matrix(entry->alpha,&matrix);cairo_pattern_set_matrix(entry->color,&matrix);
    cairo_save(s->context);cairo_new_path(s->context);cairo_set_fill_rule(s->context,CAIRO_FILL_RULE_EVEN_ODD);
    rounded_path(s->context,x,y,width,height,radius);
    if(stroke>0&&width>stroke*2&&height>stroke*2)rounded_path(s->context,x+stroke,y+stroke,width-stroke*2,height-stroke*2,MAX(0,radius-stroke));
    /* The target stays opaque. Two identical coverage masks give
       dst*(1-alpha*coverage) + premultipliedRGB*coverage exactly; Cairo's
       ordinary gradient otherwise interpolates straight RGB and alpha. */
    cairo_set_operator(s->context,CAIRO_OPERATOR_DEST_OUT);cairo_set_source(s->context,entry->alpha);cairo_fill_preserve(s->context);
    cairo_set_operator(s->context,CAIRO_OPERATOR_ADD);cairo_set_source(s->context,entry->color);cairo_fill(s->context);
    cairo_restore(s->context);return cairo_status(s->context)==CAIRO_STATUS_SUCCESS?0:2;
}
void *zbench_gradient_create(uint32_t width,uint32_t height,float scale){
    Bench *s=calloc(1,sizeof(*s));if(!s)return NULL;
    s->surface=cairo_image_surface_create(CAIRO_FORMAT_ARGB32,width,height);s->context=cairo_create(s->surface);
    if(cairo_surface_status(s->surface)||cairo_status(s->context)){cairo_destroy(s->context);cairo_surface_destroy(s->surface);free(s);return NULL;}
    cairo_set_source_rgb(s->context,1,1,1);cairo_paint(s->context);cairo_scale(s->context,scale,scale);return s;
}
void zbench_gradient_destroy(void *value){Bench *s=value;if(!s)return;for(unsigned i=0;i<ZG_BRUSH_CAPACITY;i++){drop_pattern(&s->brushes[i].alpha);drop_pattern(&s->brushes[i].color);}cairo_destroy(s->context);cairo_surface_destroy(s->surface);free(s);}
