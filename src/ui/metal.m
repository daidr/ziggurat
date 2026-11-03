/* The macOS GPU renderer: the content's commands drawn with Metal into a
   CAMetalLayer under the view's subviews. The view's own drawing (the
   software renderer's frames) shows while the layer is hidden.

   Every command becomes one instance of a quad. Instances accumulate on the
   CPU while the frame replays and are drawn in one render pass at the end,
   in batches that share a texture. Shapes, gradients and clips are
   computed per pixel in the fragment shader with the same coverage the
   software renderer gives (area coverage of axis-aligned edges, distance
   for rounded corners), so a frame looks the same whichever draws it.

   Text is laid out with Core Text exactly as the software renderer lays it
   out (macos_font.h); its glyphs are drawn once into an atlas at the
   window's scale, each sampled from mip level 0 explicitly. */
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <CoreText/CoreText.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include "brushes.h"
#include "image_resource.h"
#include "coverage_resource.h"
#include "macos_font.h"

/* Layout shared with the shader below. */
typedef struct ZmInstance {float rect[4],clip[4],color[4],params[4],uv[4];} ZmInstance;
typedef struct ZmBrush {float head[4],ab[4],offsets[16],colors[16][4];} ZmBrush;
typedef struct ZmUniforms {float width,height,scale,pad;} ZmUniforms;
_Static_assert(sizeof(ZmInstance)==80,"instance layout");
_Static_assert(sizeof(ZmBrush)==352,"brush layout");

enum {KIND_RECT,KIND_SHAPE,KIND_GRADIENT,KIND_MASK,KIND_GLYPH,KIND_IMAGE};
enum {BIND_NONE,BIND_ATLAS,BIND_TEXTURE};

static NSString *const shader_source=@
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct Inst{float4 rect;float4 clip;float4 color;float4 p;float4 uv;};\n"
"struct Brush{float4 head;float4 ab;float4 offsets[4];float4 colors[16];};\n"
"struct Uniforms{float width;float height;float scale;float pad;};\n"
"struct VOut{float4 pos[[position]];float2 uv;uint inst[[flat]];};\n"
"vertex VOut zm_vertex(uint vid[[vertex_id]],uint iid[[instance_id]],constant Uniforms&u[[buffer(0)]],const device Inst*insts[[buffer(1)]]){\n"
"  Inst i=insts[iid];uint kind=uint(i.p.z);\n"
"  float grow=(kind<=2u||kind==5u)?1.0:0.0;\n"
"  float4 q=float4(max(i.rect.xy-grow,floor(i.clip.xy)),min(i.rect.zw+grow,ceil(i.clip.zw)));\n"
"  q.zw=max(q.zw,q.xy);\n"
"  float2 corner=float2(float(vid&1u),float(vid>>1));\n"
"  float2 p=mix(q.xy,q.zw,corner);\n"
"  VOut o;o.pos=float4(p.x/u.width*2.0-1.0,1.0-p.y/u.height*2.0,0.0,1.0);\n"
"  float2 t=(p-i.rect.xy)/max(i.rect.zw-i.rect.xy,float2(1e-6));\n"
"  o.uv=mix(i.uv.xy,i.uv.zw,t);o.inst=iid;return o;\n"
"}\n"
"static float span(float c,float a,float b){return clamp(min(c+0.5,b)-max(c-0.5,a),0.0,1.0);}\n"
"static float box(float2 p,float4 r){return span(p.x,r.x,r.z)*span(p.y,r.y,r.w);}\n"
"static float rounded(float2 p,float4 r,float radius){\n"
"  if(r.z<=r.x||r.w<=r.y)return 0.0;\n"
"  if(radius<0.5)return box(p,r);\n"
"  float2 c=(r.xy+r.zw)*0.5;float2 h=(r.zw-r.xy)*0.5;\n"
"  float2 q=abs(p-c)-(h-radius);\n"
"  float d=length(max(q,float2(0.0)))+min(max(q.x,q.y),0.0)-radius;\n"
"  return clamp(0.5-d,0.0,1.0);\n"
"}\n"
"static float shape(float2 p,Inst i){\n"
"  float4 r=i.rect;float radius=i.p.x;float stroke=i.p.y;\n"
"  float outer=rounded(p,r,radius);\n"
"  float w=r.z-r.x;float h=r.w-r.y;\n"
"  if(stroke>0.0&&w>stroke*2.0&&h>stroke*2.0)outer=max(outer-rounded(p,r+float4(stroke,stroke,-stroke,-stroke),max(0.0,radius-stroke)),0.0);\n"
"  return outer;\n"
"}\n"
"static float4 gradient(const device Brush&b,float2 p){\n"
"  uint kind=uint(b.head.x);uint spread=uint(b.head.y);uint len=uint(b.head.z);\n"
"  float2 a=b.ab.xy;float2 v=b.ab.zw;float2 d=p-a;float t;\n"
"  if(kind==0u){float2 s=v-a;t=dot(d,s)/dot(s,s);}\n"
"  else if(kind==1u){float2 n=d/v;t=sqrt(dot(n,n));}\n"
"  else{if(d.x==0.0&&d.y==0.0)t=0.0;else{float turns=(precise::atan2(d.y,d.x)-v.x)*(v.y/(2.0*M_PI_F));t=turns-floor(turns);}}\n"
"  if(spread==1u)t=t-floor(t);else if(spread==2u){float m=t-2.0*floor(t*0.5);t=m>1.0?2.0-m:m;}\n"
"  uint low=0u;for(uint k=0u;k<len;k++)if(b.offsets[k/4u][k%4u]<=t)low=k+1u;\n"
"  if(low==0u)return b.colors[0];if(low>=len)return b.colors[len-1u];\n"
"  float o0=b.offsets[(low-1u)/4u][(low-1u)%4u];float o1=b.offsets[low/4u][low%4u];\n"
"  float w=o1>o0?(t-o0)/(o1-o0):0.0;\n"
"  return mix(b.colors[low-1u],b.colors[low],w);\n"
"}\n"
"fragment float4 zm_fragment(VOut in[[stage_in]],constant Uniforms&u[[buffer(0)]],const device Inst*insts[[buffer(1)]],const device Brush*brushes[[buffer(2)]],texture2d<float>tex[[texture(0)]],sampler linear_sampler[[sampler(0)]],sampler nearest_sampler[[sampler(1)]]){\n"
"  Inst i=insts[in.inst];float2 p=in.pos.xy;uint kind=uint(i.p.z);\n"
"  float cov=box(p,i.clip);float4 color=i.color;\n"
"  if(kind==0u)cov*=box(p,i.rect);\n"
"  else if(kind==1u)cov*=shape(p,i);\n"
"  else if(kind==2u){cov*=shape(p,i);color=gradient(brushes[uint(i.p.w)],p/u.scale);}\n"
"  else if(kind==3u)cov*=tex.sample(linear_sampler,in.uv,level(0.0)).r;\n"
"  else if(kind==4u){float4 t=tex.sample(nearest_sampler,in.uv,level(0.0));if(i.p.w>0.5)return t*(color.a*cov);cov*=t.a;}\n"
"  else{float lod=i.p.x;float4 t=i.p.w>0.5?tex.sample(linear_sampler,in.uv,level(lod)):tex.sample(nearest_sampler,in.uv,level(lod));return t*(color.a*cov*box(p,i.rect));}\n"
"  return color*cov;\n"
"}\n";

typedef struct ZmBatch {uint32_t first,count;int bind;__unsafe_unretained id<MTLTexture> texture;} ZmBatch;
typedef struct ZmStats {uint32_t device_creations,layer_creations,resizes,presents,transaction_presents,busy_presents,atlas_pages,glyphs;uint64_t frames,instances,batches;} ZmStats;
typedef struct ZmGlyph {float x,y,width,height,left,top;uint32_t color;} ZmGlyph;
#define ZM_CLIPS 33
#define ZM_ATLAS 2048

static atomic_int live_objects;

@interface ZigMetalRenderer : NSObject {
@public
    id<MTLDevice> device;id<MTLCommandQueue> queue;id<MTLRenderPipelineState> pipeline;
    id<MTLSamplerState> linear_sampler,nearest_sampler,mask_sampler;id<MTLTexture> blank;
    CAMetalLayer *layer;__weak NSView *view;__weak NSWindow *window;
    uint32_t width,height;float scale;int transparent,drawing,offscreen,layer_changed,capture,hidden;
    id<MTLTexture> offscreen_target,captured;
    ZmInstance *instances;uint32_t instance_len,instance_capacity;
    ZmBatch *batches;uint32_t batch_len,batch_capacity;
    ZmBrush brushes[ZG_BRUSH_CAPACITY];uint32_t brush_len;
    NSMutableArray *frame_textures;
    float clips[ZM_CLIPS][4];uint32_t clip_depth;
    /* Instance buffers the GPU no longer reads, reused for later frames. */
    NSMutableArray<id<MTLBuffer>> *free_buffers;
    /* Glyph atlas: the current page, its shelf packer and what it holds. */
    id<MTLTexture> atlas;uint32_t shelf_x,shelf_y,shelf_height;
    NSMutableDictionary<NSNumber *,NSValue *> *glyphs;
    NSMutableArray *fonts,*font_sources;NSMutableArray<NSNumber *> *font_scales;
    CTFontRef font;char font_family[256];float font_size;uint16_t font_weight;int font_italic,font_monospace;
    /* Uploaded images and coverage by slot, and a candidate before commit. */
    NSMutableArray *slots;id candidate;
    /* Prepared text coverage by the CGImage it was made from (retained). */
    NSMutableArray *prepared_keys,*prepared_textures;
    ZmStats stats;
}
@end
@implementation ZigMetalRenderer
- (void)dealloc{
    free(instances);free(batches);
    if(font)CFRelease(font);
    atomic_fetch_sub(&live_objects,1);
}
@end

static ZigMetalRenderer *R(void *p){return (__bridge ZigMetalRenderer *)p;}

static int create_pipeline(ZigMetalRenderer *s){
    NSError *error=nil;
    id<MTLLibrary> library=[s->device newLibraryWithSource:shader_source options:nil error:&error];
    if(!library){NSLog(@"Ziggurat Metal shaders: %@",error);return 0;}
    MTLRenderPipelineDescriptor *d=[[MTLRenderPipelineDescriptor alloc] init];
    d.vertexFunction=[library newFunctionWithName:@"zm_vertex"];d.fragmentFunction=[library newFunctionWithName:@"zm_fragment"];
    MTLRenderPipelineColorAttachmentDescriptor *color=d.colorAttachments[0];
    color.pixelFormat=MTLPixelFormatBGRA8Unorm;color.blendingEnabled=YES;
    color.rgbBlendOperation=color.alphaBlendOperation=MTLBlendOperationAdd;
    color.sourceRGBBlendFactor=color.sourceAlphaBlendFactor=MTLBlendFactorOne;
    color.destinationRGBBlendFactor=color.destinationAlphaBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
    s->pipeline=[s->device newRenderPipelineStateWithDescriptor:d error:&error];
    if(!s->pipeline){NSLog(@"Ziggurat Metal pipeline: %@",error);return 0;}
    MTLSamplerDescriptor *sd=[[MTLSamplerDescriptor alloc] init];
    sd.minFilter=sd.magFilter=MTLSamplerMinMagFilterLinear;sd.mipFilter=MTLSamplerMipFilterNotMipmapped;
    sd.sAddressMode=sd.tAddressMode=MTLSamplerAddressModeClampToEdge;
    s->linear_sampler=[s->device newSamplerStateWithDescriptor:sd];
    sd.minFilter=sd.magFilter=MTLSamplerMinMagFilterNearest;
    s->nearest_sampler=[s->device newSamplerStateWithDescriptor:sd];
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:1 height:1 mipmapped:NO];
    s->blank=[s->device newTextureWithDescriptor:td];
    uint32_t white=0xffffffff;[s->blank replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:&white bytesPerRow:4];
    return s->linear_sampler&&s->nearest_sampler&&s->blank;
}

void *zmtl_create(int *error){
    @autoreleasepool{
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        if(!device){*error=1;return NULL;}
        ZigMetalRenderer *s=[[ZigMetalRenderer alloc] init];atomic_fetch_add(&live_objects,1);
        s->device=device;s->queue=[device newCommandQueue];
        if(!s->queue||!create_pipeline(s)){*error=2;return NULL;}
        s->free_buffers=[NSMutableArray array];s->frame_textures=[NSMutableArray array];
        s->glyphs=[NSMutableDictionary dictionary];s->fonts=[NSMutableArray array];s->font_sources=[NSMutableArray array];s->font_scales=[NSMutableArray array];
        s->slots=[NSMutableArray array];s->prepared_keys=[NSMutableArray array];s->prepared_textures=[NSMutableArray array];
        s->hidden=1;s->stats.device_creations=1;*error=0;
        return (__bridge_retained void *)s;
    }
}
static void drop_layer(ZigMetalRenderer *s){
    if(s->layer){[CATransaction begin];[CATransaction setDisableActions:YES];[s->layer removeFromSuperlayer];[CATransaction commit];s->layer=nil;}
}
void zmtl_destroy(void *p){
    if(!p)return;
    @autoreleasepool{ZigMetalRenderer *s=(__bridge_transfer ZigMetalRenderer *)p;drop_layer(s);s=nil;}
}
uint32_t zmtl_live_objects(void){return (uint32_t)atomic_load(&live_objects);}

/* The window's content view (src/platform/macos.m), which paints the frames. */
static NSView *find_view(NSView *root){
    static Class zig_view;if(!zig_view)zig_view=NSClassFromString(@"ZigView");
    if(!root)return nil;if(zig_view&&[root isKindOfClass:zig_view])return root;
    for(NSView *child in [root subviews]){NSView *found=find_view(child);if(found)return found;}
    return nil;
}
static void reset_frame(ZigMetalRenderer *s){
    s->instance_len=0;s->batch_len=0;s->brush_len=0;s->clip_depth=0;
    s->clips[0][0]=0;s->clips[0][1]=0;s->clips[0][2]=(float)s->width;s->clips[0][3]=(float)s->height;
    [s->frame_textures removeAllObjects];
}
static int attach_layer(ZigMetalRenderer *s,NSWindow *window){
    NSView *view=s->view;
    if(!view||s->window!=window){view=find_view([window contentView]);s->view=view;s->window=window;}
    if(!view)return 1;
    if(!s->layer||[s->layer superlayer]!=[view layer]){
        drop_layer(s);
        [view setWantsLayer:YES];
        CALayer *host=[view layer];if(!host)return 1;
        CAMetalLayer *layer=[CAMetalLayer layer];
        layer.device=s->device;layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.framebufferOnly=NO;
        layer.maximumDrawableCount=3;layer.allowsNextDrawableTimeout=YES;
        CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);layer.colorspace=space;CGColorSpaceRelease(space);
        layer.anchorPoint=CGPointZero;layer.hidden=YES;layer.needsDisplayOnBoundsChange=NO;
        layer.autoresizingMask=kCALayerWidthSizable|kCALayerHeightSizable;
        /* Under the subviews' layers (an embedded page), over the view's
           own drawing. */
        [CATransaction begin];[CATransaction setDisableActions:YES];
        [host insertSublayer:layer atIndex:0];
        /* The flipped view's layer flips its sublayers' geometry; the
           drawable's first row is the top either way. */
        if([layer contentsAreFlipped])layer.geometryFlipped=YES;
        [CATransaction commit];
        s->layer=layer;s->hidden=1;s->layer_changed=1;s->stats.layer_creations++;
    }
    return 0;
}
/* 0 drawing, 1 no view, 2 failed, 4 the view is drawn into something other
   than the screen (a capture): the software renderer draws that one, and
   the layer stays as it is. */
int zmtl_begin(void *p,void *native_window,uint32_t width,uint32_t height,float scale,int transparent){
    ZigMetalRenderer *s=R(p);if(s->drawing)return 1;
    @autoreleasepool{
        NSGraphicsContext *current=[NSGraphicsContext currentContext];
        if(current&&![current isDrawingToScreen])return 4;
        if(attach_layer(s,(__bridge NSWindow *)native_window))return 1;
        CAMetalLayer *layer=s->layer;
        int changed=s->width!=width||s->height!=height||s->scale!=scale||s->transparent!=transparent;
        if(changed||!CGRectEqualToRect(layer.frame,[s->view bounds])){
            [CATransaction begin];[CATransaction setDisableActions:YES];
            layer.frame=[s->view bounds];layer.contentsScale=scale;layer.drawableSize=CGSizeMake(width,height);layer.opaque=!transparent;
            [CATransaction commit];
            if(s->width||s->height)s->stats.resizes++;
            s->layer_changed=1;
        }
    }
    s->width=width;s->height=height;s->scale=scale;s->transparent=transparent;s->offscreen=0;
    reset_frame(s);s->drawing=1;return 0;
}
int zmtl_begin_offscreen(void *p,uint32_t width,uint32_t height,float scale,int transparent){
    ZigMetalRenderer *s=R(p);if(s->drawing||!width||!height)return 1;
    if(!s->offscreen_target||s->offscreen_target.width!=width||s->offscreen_target.height!=height){
        MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
        d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;d.storageMode=MTLStorageModeShared;
        s->offscreen_target=[s->device newTextureWithDescriptor:d];if(!s->offscreen_target)return 2;
    }
    s->width=width;s->height=height;s->scale=scale;s->transparent=transparent;s->offscreen=1;
    reset_frame(s);s->drawing=1;return 0;
}
float zmtl_scale(void *p){return R(p)->scale;}

static ZmInstance *push(ZigMetalRenderer *s,int bind,id<MTLTexture> texture){
    if(s->instance_len==s->instance_capacity){
        uint32_t capacity=s->instance_capacity?s->instance_capacity*2:1024;
        ZmInstance *grown=realloc(s->instances,(size_t)capacity*sizeof(ZmInstance));if(!grown)return NULL;
        s->instances=grown;s->instance_capacity=capacity;
    }
    ZmBatch *last=s->batch_len?&s->batches[s->batch_len-1]:NULL;
    /* Untextured instances join any batch; a textured one needs its own. */
    int joins=last&&(bind==BIND_NONE||(last->bind==bind&&last->texture==texture)||last->bind==BIND_NONE);
    if(joins){
        if(bind!=BIND_NONE&&last->bind==BIND_NONE){last->bind=bind;last->texture=texture;[s->frame_textures addObject:texture];}
        last->count++;
    }else{
        if(s->batch_len==s->batch_capacity){
            uint32_t capacity=s->batch_capacity?s->batch_capacity*2:64;
            ZmBatch *grown=realloc(s->batches,(size_t)capacity*sizeof(ZmBatch));if(!grown)return NULL;
            s->batches=grown;s->batch_capacity=capacity;
        }
        s->batches[s->batch_len++]=(ZmBatch){s->instance_len,1,bind,texture};
        if(texture)[s->frame_textures addObject:texture];
    }
    ZmInstance *i=&s->instances[s->instance_len++];memset(i,0,sizeof(*i));
    memcpy(i->clip,s->clips[s->clip_depth],sizeof(i->clip));
    return i;
}
static void device_rect(ZigMetalRenderer *s,float *out,double x,double y,double width,double height){
    double k=s->scale;out[0]=(float)(x*k);out[1]=(float)(y*k);out[2]=(float)((x+width)*k);out[3]=(float)((y+height)*k);
}
static void rgba_color(float *out,uint32_t rgba){
    float a=(float)(rgba&255)/255.0f;
    out[0]=(float)(rgba>>24)/255.0f*a;out[1]=(float)((rgba>>16)&255)/255.0f*a;out[2]=(float)((rgba>>8)&255)/255.0f*a;out[3]=a;
}
static void rgb_color(float *out,uint32_t rgb){rgba_color(out,(rgb<<8)|255);}
static int visible(ZigMetalRenderer *s){const float *c=s->clips[s->clip_depth];return c[2]>c[0]&&c[3]>c[1];}

void zmtl_fill(void *p,float x,float y,float width,float height,uint32_t rgb){
    ZigMetalRenderer *s=R(p);if(!visible(s))return;
    ZmInstance *i=push(s,BIND_NONE,nil);if(!i)return;
    device_rect(s,i->rect,x,y,width,height);rgb_color(i->color,rgb);i->params[2]=KIND_RECT;
}
static void normalize_rect(double *x,double *y,double *w,double *h){if(*w<0){*x+=*w;*w=-*w;}if(*h<0){*y+=*h;*h=-*h;}}
int zmtl_shape(void *p,float x,float y,float width,float height,float radius,float stroke,uint32_t rgba){
    ZigMetalRenderer *s=R(p);
    if(width==0||height==0||(rgba&255)==0||!visible(s))return 0;
    double dx=x,dy=y,dw=width,dh=height;normalize_rect(&dx,&dy,&dw,&dh);
    ZmInstance *i=push(s,BIND_NONE,nil);if(!i)return 1;
    device_rect(s,i->rect,dx,dy,dw,dh);rgba_color(i->color,rgba);
    i->params[0]=(float)(fmin(radius,fmin(dw,dh)/2)*s->scale);i->params[1]=(float)(stroke*s->scale);i->params[2]=KIND_SHAPE;
    return 0;
}
/* spread: 0 pad, 1 repeat, 2 reflect. */
int zmtl_gradient(void *p,float x,float y,float width,float height,float radius,float stroke,const ZgBrush *brush,uint32_t spread){
    ZigMetalRenderer *s=R(p);
    if(width==0||height==0||!visible(s))return 0;
    if(brush->len==0||brush->len>ZG_STOP_CAPACITY||s->brush_len==ZG_BRUSH_CAPACITY)return 1;
    ZmBrush *b=&s->brushes[s->brush_len];memset(b,0,sizeof(*b));
    b->head[0]=(float)brush->kind;b->head[1]=(float)spread;b->head[2]=(float)brush->len;
    b->ab[0]=brush->x0;b->ab[1]=brush->y0;b->ab[2]=brush->x1;b->ab[3]=brush->y1;
    for(uint32_t k=0;k<brush->len;k++){b->offsets[k]=brush->stops[k].offset;rgba_color(b->colors[k],brush->stops[k].rgba);}
    double dx=x,dy=y,dw=width,dh=height;normalize_rect(&dx,&dy,&dw,&dh);
    ZmInstance *i=push(s,BIND_NONE,nil);if(!i)return 1;
    device_rect(s,i->rect,dx,dy,dw,dh);i->color[3]=1;
    i->params[0]=(float)(fmin(radius,fmin(dw,dh)/2)*s->scale);i->params[1]=(float)(stroke*s->scale);i->params[2]=KIND_GRADIENT;i->params[3]=(float)s->brush_len;
    s->brush_len++;return 0;
}
void zmtl_push_clip(void *p,float x,float y,float width,float height){
    ZigMetalRenderer *s=R(p);if(s->clip_depth+1>=ZM_CLIPS)return;
    float r[4];device_rect(s,r,x,y,width,height);const float *b=s->clips[s->clip_depth];float *a=s->clips[++s->clip_depth];
    a[0]=fmaxf(b[0],r[0]);a[1]=fmaxf(b[1],r[1]);a[2]=fminf(b[2],r[2]);a[3]=fminf(b[3],r[3]);
}
void zmtl_pop_clip(void *p){ZigMetalRenderer *s=R(p);if(s->clip_depth)s->clip_depth--;}
/* Narrows the current clip for one command; restore_clip puts it back. */
static void narrow_clip(ZigMetalRenderer *s,double x,double y,double width,double height,float *saved){
    float *c=s->clips[s->clip_depth];memcpy(saved,c,4*sizeof(float));
    float r[4];device_rect(s,r,x,y,width,height);
    c[0]=fmaxf(c[0],r[0]);c[1]=fmaxf(c[1],r[1]);c[2]=fminf(c[2],r[2]);c[3]=fminf(c[3],r[3]);
}
static void restore_clip(ZigMetalRenderer *s,const float *saved){memcpy(s->clips[s->clip_depth],saved,4*sizeof(float));}

/* Glyphs. */
static int new_atlas(ZigMetalRenderer *s){
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:ZM_ATLAS height:ZM_ATLAS mipmapped:NO];
    d.usage=MTLTextureUsageShaderRead;d.storageMode=MTLStorageModeShared;
    id<MTLTexture> atlas=[s->device newTextureWithDescriptor:d];if(!atlas)return 0;
    s->atlas=atlas;s->shelf_x=s->shelf_y=s->shelf_height=0;[s->glyphs removeAllObjects];s->stats.atlas_pages++;
    return 1;
}
/* Room for a w x h glyph with a clear pixel around it, on a new page when
   the current one is full; the frame keeps the pages it draws from. */
static int atlas_place(ZigMetalRenderer *s,uint32_t w,uint32_t h,uint32_t *x,uint32_t *y){
    if(w+2>ZM_ATLAS||h+2>ZM_ATLAS)return 0;
    if(!s->atlas&&!new_atlas(s))return 0;
    if(s->shelf_x+w+2>ZM_ATLAS){s->shelf_y+=s->shelf_height;s->shelf_x=0;s->shelf_height=0;}
    if(s->shelf_y+h+2>ZM_ATLAS){if(!new_atlas(s))return 0;}
    *x=s->shelf_x+1;*y=s->shelf_y+1;s->shelf_x+=w+2;if(h+2>s->shelf_height)s->shelf_height=h+2;
    return 1;
}
/* A font at the window's scale, kept while the atlas holds its glyphs:
   fonts compare as Core Text compares them (descriptor, variations and
   size), so weights of one variable font stay apart. */
static uint32_t scaled_font(ZigMetalRenderer *s,CTFontRef font,CTFontRef *out){
    double scale=s->scale;
    NSUInteger count=[s->fonts count];
    for(NSUInteger k=0;k<count;k++){
        if([s->font_scales[k] doubleValue]==scale&&CFEqual((__bridge CFTypeRef)s->font_sources[k],font)){*out=(__bridge CTFontRef)s->fonts[k];return (uint32_t)k;}
    }
    if(count>=64){
        /* The glyphs name fonts by index: start over on a new page. */
        if(!new_atlas(s))return UINT32_MAX;
        [s->fonts removeAllObjects];[s->font_sources removeAllObjects];[s->font_scales removeAllObjects];count=0;
    }
    CTFontRef copy=CTFontCreateCopyWithAttributes(font,CTFontGetSize(font)*scale,NULL,NULL);if(!copy)return UINT32_MAX;
    [s->fonts addObject:(__bridge_transfer id)copy];[s->font_sources addObject:(__bridge id)font];[s->font_scales addObject:@(scale)];
    *out=copy;return (uint32_t)count;
}
static int glyph_entry(ZigMetalRenderer *s,CTFontRef font,uint32_t font_index,CGGlyph glyph,uint32_t sub,ZmGlyph *out){
    uint64_t key=((uint64_t)font_index<<24)|((uint64_t)glyph<<2)|sub;
    NSValue *known=s->glyphs[@(key)];
    if(known){[known getValue:out size:sizeof(*out)];return 1;}
    CGRect bounds=CTFontGetBoundingRectsForGlyphs(font,kCTFontOrientationHorizontal,&glyph,NULL,1);
    ZmGlyph entry={0};
    double fx=sub/4.0;
    if(!CGRectIsEmpty(bounds)&&bounds.size.width>0&&bounds.size.height>0){
        int left=(int)floor(bounds.origin.x+fx)-1,right=(int)ceil(CGRectGetMaxX(bounds)+fx)+1;
        int bottom=(int)floor(bounds.origin.y)-1,top=(int)ceil(CGRectGetMaxY(bounds))+1;
        uint32_t w=(uint32_t)(right-left),h=(uint32_t)(top-bottom);
        uint32_t ax,ay;
        if(!atlas_place(s,w,h,&ax,&ay))return 0;
        size_t stride=(size_t)w*4;uint8_t *pixels=calloc((size_t)h,stride);if(!pixels)return 0;
        CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef c=CGBitmapContextCreate(pixels,w,h,8,stride,space,(CGBitmapInfo)kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little);
        CGColorSpaceRelease(space);
        if(!c){free(pixels);return 0;}
        CGContextSetRGBFillColor(c,1,1,1,1);
        CGPoint position=CGPointMake(fx-left,-bottom);
        CTFontDrawGlyphs(font,&glyph,&position,1,c);CGContextRelease(c);
        /* A glyph drawn in white is a mask; one with any other color is a
           color glyph (emoji), drawn as it is. */
        uint32_t color=0;
        for(size_t k=0;k<(size_t)w*h&&!color;k++){const uint8_t *px=pixels+k*4;if(px[0]!=px[3]||px[1]!=px[3]||px[2]!=px[3])color=1;}
        [s->atlas replaceRegion:MTLRegionMake2D(ax,ay,w,h) mipmapLevel:0 withBytes:pixels bytesPerRow:stride];
        free(pixels);
        entry=(ZmGlyph){(float)ax,(float)ay,(float)w,(float)h,(float)left,(float)top,color};
        s->stats.glyphs++;
    }
    s->glyphs[@(key)]=[NSValue valueWithBytes:&entry objCType:@encode(ZmGlyph)];
    *out=entry;return 1;
}
static CTFontRef use_font(ZigMetalRenderer *s,const char *named,float size,uint16_t weight,int italic,int monospace){
    const char *family=named?named:"";
    if(s->font&&s->font_size==size&&s->font_weight==weight&&s->font_italic==italic&&s->font_monospace==monospace&&!strncmp(s->font_family,family,sizeof(s->font_family)))return s->font;
    CTFontRef font=create_font(named,size,weight,italic,monospace);if(!font)return NULL;
    if(s->font)CFRelease(s->font);s->font=font;
    strncpy(s->font_family,family,sizeof(s->font_family)-1);s->font_family[sizeof(s->font_family)-1]=0;
    s->font_size=size;s->font_weight=weight;s->font_italic=italic;s->font_monospace=monospace;return font;
}
int zmtl_text(void *p,float x,float y,float width,float height,const char *text,uint32_t length,uint32_t rgb,float size,uint16_t weight,int italic,int monospace,const char *family){
    ZigMetalRenderer *s=R(p);
    if(!(width>=0)||length>INT32_MAX||!(size>=1&&size<=1024))return 1;
    @autoreleasepool{
        CTFontRef font=use_font(s,family,size,weight,italic,monospace);if(!font)return 2;
        CGFloat ascent=0,descent=0;int failed=0;
        CTLineRef line=text_line(font,text,length,width,&ascent,&descent,&failed);
        if(!line)return failed?2:0;
        float saved[4];narrow_clip(s,x,y,width,height,saved);
        int result=0;
        if(visible(s)){
            double baseline=(double)y+((double)height-(ascent+descent))/2+ascent;
            float color[4];rgb_color(color,rgb);
            CFArrayRef runs=CTLineGetGlyphRuns(line);
            for(CFIndex r=0;r<CFArrayGetCount(runs)&&!result;r++){
                CTRunRef run=CFArrayGetValueAtIndex(runs,r);CFIndex count=CTRunGetGlyphCount(run);if(!count)continue;
                CTFontRef run_font=CFDictionaryGetValue(CTRunGetAttributes(run),kCTFontAttributeName);if(!run_font)run_font=font;
                CTFontRef device_font=NULL;uint32_t font_index=scaled_font(s,run_font,&device_font);if(font_index==UINT32_MAX){result=2;break;}
                CGGlyph glyphs[256];CGPoint positions[256];
                for(CFIndex start=0;start<count&&!result;start+=256){
                    CFIndex n=count-start<256?count-start:256;
                    CTRunGetGlyphs(run,CFRangeMake(start,n),glyphs);CTRunGetPositions(run,CFRangeMake(start,n),positions);
                    for(CFIndex g=0;g<n;g++){
                        double px=((double)x+positions[g].x)*s->scale,py=(baseline-positions[g].y)*s->scale;
                        double ix=floor(px);uint32_t sub=(uint32_t)floor((px-ix)*4+0.5);if(sub==4){sub=0;ix+=1;}
                        double iy=floor(py+0.5);
                        ZmGlyph entry;if(!glyph_entry(s,device_font,font_index,glyphs[g],sub,&entry)){result=2;break;}
                        if(entry.width==0)continue;
                        ZmInstance *i=push(s,BIND_ATLAS,s->atlas);if(!i){result=2;break;}
                        i->rect[0]=(float)(ix+entry.left);i->rect[1]=(float)(iy-entry.top);i->rect[2]=i->rect[0]+entry.width;i->rect[3]=i->rect[1]+entry.height;
                        memcpy(i->color,color,sizeof(color));i->params[2]=KIND_GLYPH;i->params[3]=(float)entry.color;
                        i->uv[0]=entry.x/ZM_ATLAS;i->uv[1]=entry.y/ZM_ATLAS;i->uv[2]=(entry.x+entry.width)/ZM_ATLAS;i->uv[3]=(entry.y+entry.height)/ZM_ATLAS;
                    }
                }
            }
        }
        restore_clip(s,saved);
        CFRelease(line);return result;
    }
}

/* Masks: coverage (A8) drawn in a color. */
static id<MTLTexture> mask_texture(ZigMetalRenderer *s,const ZgCoverage *coverage){
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:coverage->width height:coverage->height mipmapped:NO];
    d.usage=MTLTextureUsageShaderRead;d.storageMode=MTLStorageModeShared;
    id<MTLTexture> texture=[s->device newTextureWithDescriptor:d];if(!texture)return nil;
    [texture replaceRegion:MTLRegionMake2D(0,0,coverage->width,coverage->height) mipmapLevel:0 withBytes:coverage->pixels bytesPerRow:coverage->stride];
    return texture;
}
static int draw_mask(ZigMetalRenderer *s,id<MTLTexture> texture,double left,double top,uint32_t rgba){
    if(!visible(s)||(rgba&255)==0)return 0;
    ZmInstance *i=push(s,BIND_TEXTURE,texture);if(!i)return 1;
    i->rect[0]=(float)left;i->rect[1]=(float)top;i->rect[2]=(float)(left+texture.width);i->rect[3]=(float)(top+texture.height);
    rgba_color(i->color,rgba);i->params[2]=KIND_MASK;i->uv[2]=1;i->uv[3]=1;
    return 0;
}
/* key is the prepared text's coverage image, retained while cached. */
int zmtl_prepared(void *p,void *key,const ZgCoverage *coverage,float x,float y,const float *clip,uint32_t rgba){
    ZigMetalRenderer *s=R(p);
    id texture=nil;NSUInteger count=[s->prepared_keys count];
    for(NSUInteger k=0;k<count;k++)if((__bridge void *)s->prepared_keys[k]==key){texture=s->prepared_textures[k];break;}
    if(!texture){
        texture=mask_texture(s,coverage);if(!texture)return 2;
        if(count>=128){[s->prepared_keys removeObjectAtIndex:0];[s->prepared_textures removeObjectAtIndex:0];}
        [s->prepared_keys addObject:(__bridge id)key];[s->prepared_textures addObject:texture];
    }
    float saved[4];
    if(clip)narrow_clip(s,(double)x+clip[0],(double)y+clip[1],clip[2],clip[3],saved);
    int result=draw_mask(s,texture,(double)x*s->scale+coverage->origin_x,(double)y*s->scale+coverage->origin_y,rgba);
    if(clip)restore_clip(s,saved);
    return result;
}
void zmtl_forget_prepared(void *p){ZigMetalRenderer *s=R(p);[s->prepared_keys removeAllObjects];[s->prepared_textures removeAllObjects];}

/* Image and coverage slots. */
int zmtl_reserve_images(void *p,uint32_t capacity){ZigMetalRenderer *s=R(p);while([s->slots count]<capacity)[s->slots addObject:[NSNull null]];return 0;}
static id<MTLTexture> image_texture(ZigMetalRenderer *s,const ZiImageLevel *levels,uint32_t count){
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:levels[0].width height:levels[0].height mipmapped:count>1];
    d.mipmapLevelCount=count;d.usage=MTLTextureUsageShaderRead;d.storageMode=MTLStorageModeShared;
    id<MTLTexture> texture=[s->device newTextureWithDescriptor:d];if(!texture)return nil;
    for(uint32_t k=0;k<count;k++)[texture replaceRegion:MTLRegionMake2D(0,0,levels[k].width,levels[k].height) mipmapLevel:k withBytes:levels[k].pixels bytesPerRow:levels[k].stride];
    return texture;
}
int zmtl_prepare_image(void *p,const ZiImageLevel *levels,uint32_t count){
    ZigMetalRenderer *s=R(p);if(s->candidate||count==0||count>ZI_IMAGE_LEVELS)return 1;
    @autoreleasepool{s->candidate=image_texture(s,levels,count);}
    return s->candidate?0:2;
}
int zmtl_prepare_coverage(void *p,const ZgCoverage *coverage){
    ZigMetalRenderer *s=R(p);if(s->candidate||!coverage->width||!coverage->height||coverage->stride<coverage->width)return 1;
    s->candidate=mask_texture(s,coverage);return s->candidate?0:2;
}
void zmtl_commit_image(void *p,uint32_t slot){ZigMetalRenderer *s=R(p);if(slot<[s->slots count]&&s->candidate){s->slots[slot]=s->candidate;}s->candidate=nil;}
void zmtl_release_image(void *p,uint32_t slot){ZigMetalRenderer *s=R(p);if(slot<[s->slots count])s->slots[slot]=[NSNull null];}
/* A dynamic image's new pixels go into a new texture: the old one may be
   in a frame the GPU still draws. */
int zmtl_update_image(void *p,uint32_t slot,const ZiImageLevel *levels,uint32_t count){
    ZigMetalRenderer *s=R(p);if(slot>=[s->slots count]||[s->slots[slot] isKindOfClass:[NSNull class]])return 1;
    id<MTLTexture> old=s->slots[slot];if(old.mipmapLevelCount!=count)return 1;
    id<MTLTexture> texture=image_texture(s,levels,count);if(!texture)return 2;
    s->slots[slot]=texture;return 0;
}
static id<MTLTexture> slot_texture(ZigMetalRenderer *s,uint32_t slot){
    if(slot>=[s->slots count])return nil;id value=s->slots[slot];return [value isKindOfClass:[NSNull class]]?nil:value;
}
int zmtl_coverage(void *p,uint32_t slot,float x,float y,uint32_t rgba){
    ZigMetalRenderer *s=R(p);id<MTLTexture> texture=slot_texture(s,slot);if(!texture||texture.pixelFormat!=MTLPixelFormatR8Unorm)return 1;
    return draw_mask(s,texture,(double)x*s->scale,(double)y*s->scale,rgba);
}
int zmtl_image(void *p,uint32_t slot,const ZiImagePlan *plan){
    ZigMetalRenderer *s=R(p);id<MTLTexture> texture=slot_texture(s,slot);
    if(!texture||texture.pixelFormat!=MTLPixelFormatBGRA8Unorm||plan->level>=texture.mipmapLevelCount)return 1;
    const ZiImageRect *d=&plan->destination,*r=&plan->source;
    if(d->width<=0||d->height<=0||plan->opacity<=0||!visible(s))return 0;
    if(!(r->width>0&&r->height>0))return 1;
    double lw=(double)(texture.width>>plan->level?texture.width>>plan->level:1),lh=(double)(texture.height>>plan->level?texture.height>>plan->level:1);
    ZmInstance *i=push(s,BIND_TEXTURE,texture);if(!i)return 1;
    device_rect(s,i->rect,d->x,d->y,d->width,d->height);
    float opacity=plan->opacity>1?1:plan->opacity;i->color[0]=i->color[1]=i->color[2]=i->color[3]=opacity;
    i->params[0]=(float)plan->level;i->params[2]=KIND_IMAGE;i->params[3]=plan->sampling?1:0;
    i->uv[0]=(float)(r->x/lw);i->uv[1]=(float)(r->y/lh);i->uv[2]=(float)((r->x+r->width)/lw);i->uv[3]=(float)((r->y+r->height)/lh);
    return 0;
}

/* The frame's instances and brushes in a buffer the GPU reads; buffers come
   back to the free list once their command buffer completes. */
static id<MTLBuffer> frame_buffer(ZigMetalRenderer *s,size_t bytes){
    @synchronized(s->free_buffers){
        for(NSUInteger k=0;k<[s->free_buffers count];k++){
            id<MTLBuffer> buffer=s->free_buffers[k];
            if(buffer.length>=bytes){[s->free_buffers removeObjectAtIndex:k];return buffer;}
        }
        if([s->free_buffers count]>4)[s->free_buffers removeObjectAtIndex:0];
    }
    size_t size=4096;while(size<bytes)size*=2;
    return [s->device newBufferWithLength:size options:MTLResourceStorageModeShared|MTLResourceCPUCacheModeWriteCombined];
}
static int encode(ZigMetalRenderer *s,id<MTLCommandBuffer> commands,id<MTLTexture> target){
    size_t brush_offset=((size_t)s->instance_len*sizeof(ZmInstance)+255)&~(size_t)255;
    size_t bytes=brush_offset+sizeof(ZmBrush)*(s->brush_len?s->brush_len:1);
    id<MTLBuffer> buffer=frame_buffer(s,bytes);if(!buffer)return 2;
    if(s->instance_len)memcpy(buffer.contents,s->instances,(size_t)s->instance_len*sizeof(ZmInstance));
    if(s->brush_len)memcpy((uint8_t *)buffer.contents+brush_offset,s->brushes,sizeof(ZmBrush)*s->brush_len);
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    /* An opaque frame starts white, as the software plane does. */
    pass.colorAttachments[0].clearColor=s->transparent?MTLClearColorMake(0,0,0,0):MTLClearColorMake(1,1,1,1);
    id<MTLRenderCommandEncoder> encoder=[commands renderCommandEncoderWithDescriptor:pass];if(!encoder)return 2;
    [encoder setRenderPipelineState:s->pipeline];
    ZmUniforms uniforms={(float)s->width,(float)s->height,s->scale,0};
    [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:0];[encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentBuffer:buffer offset:brush_offset atIndex:2];
    [encoder setFragmentSamplerState:s->linear_sampler atIndex:0];[encoder setFragmentSamplerState:s->nearest_sampler atIndex:1];
    for(uint32_t k=0;k<s->batch_len;k++){
        const ZmBatch *b=&s->batches[k];
        size_t offset=(size_t)b->first*sizeof(ZmInstance);
        [encoder setVertexBuffer:buffer offset:offset atIndex:1];[encoder setFragmentBuffer:buffer offset:offset atIndex:1];
        [encoder setFragmentTexture:b->texture?b->texture:s->blank atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:b->count];
    }
    [encoder endEncoding];
    NSMutableArray *free_buffers=s->free_buffers;
    [commands addCompletedHandler:^(id<MTLCommandBuffer> done){(void)done;@synchronized(free_buffers){[free_buffers addObject:buffer];}}];
    s->stats.frames++;s->stats.instances+=s->instance_len;s->stats.batches+=s->batch_len;
    return 0;
}
static void set_hidden(ZigMetalRenderer *s,int hidden){
    if(!s->layer||s->hidden==hidden)return;
    [CATransaction begin];[CATransaction setDisableActions:YES];s->layer.hidden=hidden?YES:NO;[CATransaction commit];
    s->hidden=hidden;
}
static void capture_texture(ZigMetalRenderer *s,id<MTLCommandBuffer> commands,id<MTLTexture> source){
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:source.width height:source.height mipmapped:NO];
    d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> copy=[s->device newTextureWithDescriptor:d];if(!copy)return;
    id<MTLBlitCommandEncoder> blit=[commands blitCommandEncoder];
    [blit copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(source.width,source.height,1) toTexture:copy destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [blit endEncoding];s->captured=copy;
}
/* 0 presented, 1 not drawing, 2 failed, 3 no drawable came (busy). */
int zmtl_end(void *p){
    ZigMetalRenderer *s=R(p);if(!s->drawing||s->offscreen)return 1;
    s->drawing=0;
    @autoreleasepool{
        CAMetalLayer *layer=s->layer;if(!layer)return 2;
        NSView *view=s->view;
        /* Frames that change the layer, and those of a live resize, show
           with the window's own change in the same Core Animation
           transaction; the others present as soon as the GPU has them. */
        int with_transaction=s->layer_changed||(view&&[view inLiveResize]);
        layer.presentsWithTransaction=with_transaction?YES:NO;
        id<CAMetalDrawable> drawable=[layer nextDrawable];
        if(!drawable){s->stats.busy_presents++;reset_frame(s);return 3;}
        id<MTLCommandBuffer> commands=[s->queue commandBuffer];if(!commands)return 2;
        if(encode(s,commands,drawable.texture)){reset_frame(s);return 2;}
        if(s->capture)capture_texture(s,commands,drawable.texture);
        int was_hidden=s->hidden;
        if(with_transaction){
            [commands commit];[commands waitUntilScheduled];[drawable present];
            s->stats.transaction_presents++;
        }else{[commands presentDrawable:drawable];[commands commit];}
        set_hidden(s,0);
        s->layer_changed=0;s->stats.presents++;
        if(s->capture)[commands waitUntilCompleted];
        reset_frame(s);
        /* A resize's frame presented with the transaction outside a live
           resize may not show once AppKit has displayed the view: draw
           again at the next turn of the run loop, presented at once. The
           view's own drawing shows under a transparent frame, so a frame
           that takes over from the software renderer clears it. */
        if(view&&((with_transaction&&![view inLiveResize])||(was_hidden&&s->transparent))){
            __weak NSView *weak=view;
            dispatch_async(dispatch_get_main_queue(),^{[weak setNeedsDisplay:YES];});
        }
    }
    return 0;
}
/* Draws the offscreen frame and copies its premultiplied BGRA pixels. */
int zmtl_end_offscreen(void *p,uint8_t *pixels,size_t stride){
    ZigMetalRenderer *s=R(p);if(!s->drawing||!s->offscreen)return 1;
    s->drawing=0;
    @autoreleasepool{
        id<MTLCommandBuffer> commands=[s->queue commandBuffer];if(!commands)return 2;
        if(encode(s,commands,s->offscreen_target)){reset_frame(s);return 2;}
        [commands commit];[commands waitUntilCompleted];
        reset_frame(s);
        if(commands.status!=MTLCommandBufferStatusCompleted)return 2;
        if(pixels)[s->offscreen_target getBytes:pixels bytesPerRow:stride fromRegion:MTLRegionMake2D(0,0,s->width,s->height) mipmapLevel:0];
    }
    return 0;
}
void zmtl_abort(void *p){ZigMetalRenderer *s=R(p);s->drawing=0;reset_frame(s);}
/* The software renderer draws the next frame: hide the layer over it. */
int zmtl_suspend(void *p){
    ZigMetalRenderer *s=R(p);if(!s->layer||s->hidden)return 0;set_hidden(s,1);
    /* The view kept no drawing of its own under the layer: a frame that
       redraws only part of it is followed by one of all of it. */
    __weak NSView *weak=s->view;
    dispatch_async(dispatch_get_main_queue(),^{[weak setNeedsDisplay:YES];});
    return 1;
}
void zmtl_restore(void *p){set_hidden(R(p),0);}
void zmtl_stats(void *p,ZmStats *out){*out=R(p)->stats;}

/* Test hooks. */
void zmtl_test_capture(void *p,int enable){ZigMetalRenderer *s=R(p);s->capture=enable;if(!enable)s->captured=nil;}
/* 0xAARRGGBB of the last frame presented while capturing. */
uint32_t zmtl_test_pixel(void *p,uint32_t x,uint32_t y){
    ZigMetalRenderer *s=R(p);id<MTLTexture> t=s->captured;if(!t||x>=t.width||y>=t.height)return 0;
    uint8_t px[4];[t getBytes:px bytesPerRow:4 fromRegion:MTLRegionMake2D(x,y,1,1) mipmapLevel:0];
    return ((uint32_t)px[3]<<24)|((uint32_t)px[2]<<16)|((uint32_t)px[1]<<8)|px[0];
}
/* Displays the view of the window titled title now, as AppKit's display
   cycle would. */
void zmtl_test_display(const char *title){
    @autoreleasepool{
        NSString *wanted=[NSString stringWithUTF8String:title];
        for(NSWindow *window in [NSApp windows])if([[window title] isEqualToString:wanted]){
            NSView *view=find_view([window contentView]);[view setNeedsDisplay:YES];[view displayIfNeeded];[CATransaction flush];
        }
    }
}
int zmtl_test_layer_flipped(void *p){ZigMetalRenderer *s=R(p);return s->layer?[s->layer contentsAreFlipped]:-1;}
int zmtl_test_layer_shown(void *p){ZigMetalRenderer *s=R(p);return s->layer&&!s->layer.hidden&&s->layer.superlayer;}
int zmtl_test_layer_under_subviews(void *p){
    ZigMetalRenderer *s=R(p);if(!s->layer)return 0;NSArray *sublayers=s->layer.superlayer.sublayers;
    return [sublayers count]&&sublayers[0]==s->layer;
}
uint32_t zmtl_test_atlas_levels(void *p){ZigMetalRenderer *s=R(p);return s->atlas?(uint32_t)s->atlas.mipmapLevelCount:0;}
