/* The Linux GPU renderer: the content's commands drawn with OpenGL 3.3.
   Browsers build it too, on a canvas's WebGL2 (src/ui/gl_web.h): there a
   window's context is the canvas's, a frame is copied to the canvas's own
   framebuffer at its end, and text is drawn by the page as src/ui/web.c
   draws it; the rest below is the same.

   A window's frames are drawn as GtkGLArea draws its own: with a GDK
   OpenGL context of the area's GdkWindow, into a framebuffer the renderer
   keeps, which gdk_cairo_draw_from_gl shows in the area's draw signal.
   The framebuffer is kept between frames, so a frame may draw again only
   the device pixels that changed (src/ui/damage.zig); a new size makes a
   new one. Whether a window draws with OpenGL at all is decided before it
   has a context, with a context GDK makes for a hidden window of its own
   (zglr_probe): only where OpenGL draws on a GPU, unless asked to draw on
   a software rasterizer too (llvmpipe). Once a window has a GL context,
   GTK 3 on Wayland composites it with OpenGL and tells the compositor what
   changed in the wrong units at a scale of 2 or more: the toplevel's draw
   signal then adds the area GTK repaints as wl_surface.damage.

   A renderer in a device domain (src/ui/gpu_resources.zig), or one that
   draws only offscreen frames, draws with a surfaceless EGL context
   instead: the domain's, which its renderers and textures share. A window
   frame drawn so is read back into memory and painted with cairo, as the
   software renderer paints its own.

   Every command becomes one instance of a quad. Instances accumulate while
   the frame replays and are drawn at its end in batches that share a
   texture; their data (instances, gradient brushes) is read from texture
   buffers. Shapes, gradients and clips are computed per pixel in the
   fragment shader with the coverage the software renderer gives (area
   coverage of axis-aligned edges, distance for rounded corners).

   Text is laid out and drawn with Pango exactly as the software renderer
   draws it, once per text, its box and its position within a device pixel,
   into a texture kept for later frames; prepared text and coverage masks
   are uploaded as they are.

   Groups, Gaussian groups and raster transforms capture their content in
   textures of their own for the frame, as the software planes do: a
   group's pixels composite at its opacity through its mask, a Gaussian
   group's capture is filtered first with the software renderer's integer
   kernel, and a transform's source (with a transparent guard texel around
   it) is sampled back through its inverse with the software renderer's
   bilinear taps, rounded to bytes.

   Shader effects run their programs (src/ui/gpu_effect_host.zig, linked
   outside frames) over textures of the frame too: an element effect over
   its capture, a backdrop shader over a copy of the target beneath it.
   Backdrop effects (blur, glass, scroll edges) copy the target beneath
   them, blur the copy with the software planes' float kernel a level at a
   time, and shade it back; loading indicators evaluate their scenes per
   pixel. An opacity (Command.push_opacity) draws each drawing of its batch
   at that opacity, as if it multiplied its colors; a capture composites at
   the opacity open around it.

   Render targets are stored bottom row first, as OpenGL draws; uploaded
   images and masks top row first. */
#ifdef __wasm__
/* In a browser the OpenGL is the page's WebGL2 (src/ui/gl_web.h): a
   window's canvas has the context, text comes from the page as
   src/ui/web.c draws it, and there is no EGL, GTK, cairo or Pango. */
#include "gl_web.h"
#include <limits.h>
#else
#define _GNU_SOURCE
#include <gtk/gtk.h>
#include <epoxy/egl.h>
#include <epoxy/gl.h>
#include <pango/pangocairo.h>
#include <dlfcn.h>
#endif
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "brushes.h"
#include "image_resource.h"
#include "coverage_resource.h"
#include "layer_resource.h"

typedef struct ZlInstance {float rect[4],clip[4],color[4],params[4],uv[4];} ZlInstance;
typedef struct ZlBrush {float head[4],ab[4],offsets[16],colors[16][4];} ZlBrush;
_Static_assert(sizeof(ZlInstance)==80,"instance layout");
_Static_assert(sizeof(ZlBrush)==352,"brush layout");
enum {KIND_RECT,KIND_SHAPE,KIND_GRADIENT,KIND_MASK,KIND_TEXT,KIND_IMAGE,KIND_LAYER,KIND_TRANSFORM,KIND_INDICATOR};
enum {OP_DRAW,OP_CAPTURE,OP_CLOSE,OP_BACKDROP,OP_GLASS};
/* Run kinds: what a capture does when it closes, or a backdrop's pass. */
enum {RUN_GROUP,RUN_GAUSSIAN,RUN_TRANSFORM,RUN_EFFECT};
#define ZL_CLIPS 33
#define ZL_DEPTH 8
#define ZL_TEXTURE_LIMIT 16384
#define ZL_TEXT_ENTRIES 512
#define ZL_TEXT_BYTES (64u*1024*1024)
#define ZL_PREPARED 128
#define ZL_FREE_TARGETS 24
#define ZL_EFFECT_SLOTS 16
#define ZL_EFFECT_WORDS 4096

typedef struct GpuDomainEpoch {uint64_t identity,generation;uint32_t status,reserved;} GpuDomainEpoch;
typedef struct GpuTextureToken {uint64_t identity,generation;uint32_t width,height,levels,reserved;} GpuTextureToken;
typedef struct DomainStats {uint32_t objects,devices,losses,reserved;uint64_t bitmaps;} DomainStats;
_Static_assert(sizeof(GpuDomainEpoch)==24,"GPU epoch ABI");
_Static_assert(sizeof(GpuTextureToken)==32,"GPU texture token ABI");
/* Results as src/ui/gpu_resources.zig reads them (HRESULT values). */
#define ZL_OK 0
#define ZL_INVALID ((int32_t)0x80070057)
#define ZL_NO_MEMORY ((int32_t)0x8007000E)
#define ZL_UNEXPECTED ((int32_t)0x8000FFFF)
#define ZL_DEVICE_REMOVED ((int32_t)0x887A0005)

/* A render target: a texture and its framebuffer. */
typedef struct ZlTarget {GLuint texture,framebuffer;uint32_t width,height;} ZlTarget;
/* A draw batch's instances share a texture (and a group's mask);
   replace batches overwrite the target rather than blend. */
typedef struct ZlBatch {uint32_t first,count,op,run;GLuint texture,mask;int textured,replace;float opacity;} ZlBatch;
/* A capture: its texture (texel 0 at device pixel origin of its parent),
   what closing it runs, and the Gaussian kernel it filters with. */
/* An effect pass, as src/ui/gpu_effect_host.zig's Params lays it out. */
typedef struct ZlEffectParams {float a[4],b[4],shape[4],clip[4],c[4],d[4];uint32_t plane[4];} ZlEffectParams;
typedef struct ZlEffectPass {const uint32_t *words;uint32_t word_count,slot;ZlEffectParams params;} ZlEffectPass;
_Static_assert(sizeof(ZlEffectParams)==112,"effect parameter layout");
/* Where the current target's pixels are: physical pixel = DIP * scale +
   origin; the clip is physical and inside width x height. */
typedef struct ZlEffectGeometry {double clip[4];float scale,origin[2];uint32_t width,height,transparent;} ZlEffectGeometry;
/* A backdrop effect as src/ui/gl.zig plans it (src/ui/backdrop.zig), in
   physical pixels of the current target: misc is radius, refraction, bezel
   and noise; misc2 rim, kind (0 blur, 1 glass, 2 scroll edge, 3 the opaque
   fill), transparent and whether the blur is progressive; line and line2
   the progressive blur's line (x, y, dx, dy; length, from, to);
   background.w the opacity it shades at. */
typedef struct ZlGlass {float box[4],clip[4],tone[4],tint[4],line[4],line2[4],misc[4],misc2[4],background[4],fill[4];uint32_t region[4],out[4];} ZlGlass;
typedef struct ZlGlassLevel {uint32_t radius;float lo,hi;uint32_t weights;} ZlGlassLevel;
_Static_assert(sizeof(ZlGlass)==192,"backdrop layout");
/* An element effect's capture runs its program into output; a backdrop
   shader's or backdrop effect's copy (source) of region of the target is
   run or blurred and shaded back over out; the effect's words (and a
   backdrop effect's levels) are among the frame's. */
typedef struct ZlRun {uint32_t kind,radius;float origin[2];ZlTarget source,temp,output,extra[3];uint32_t weights[257];
    uint32_t slot,word_offset,word_count,has_pass,region[4],out[4],levels,level_offset;ZlEffectParams params;} ZlRun;
/* A capture while it records: the clips it began under and how it
   composites when it closes. */
typedef struct ZlCapture {float clips[ZL_CLIPS][4];uint32_t clip_depth,run,kind,empty,opacity,mask;float bounds[4],mask_rect[4];float faded;uint32_t fades;} ZlCapture;
typedef struct ZlImage {GLuint texture;uint32_t width,height,levels;int coverage;} ZlImage;
/* A text drawn once, by what it draws (its bytes, font, color, box and
   where within a device pixel it starts). */
typedef struct ZlText {uint64_t hash,used;char *bytes;uint32_t len,rgb,width,height;float size,box[2],offset[2],scale;uint16_t weight;int italic,monospace;char family[64];GLuint texture;} ZlText;
typedef struct ZlStats {uint32_t device_creations,context_creations,resizes,presents,memory_presents,busy_presents,text_rasters,text_entries;uint64_t frames,instances,batches,layers,filter_passes,partial_frames,text_hits,offscreen_targets,device_losses,damage_submissions,effect_passes,backdrops,indicators;} ZlStats;

typedef struct ZlRenderer ZlRenderer;
/* A device domain: one surfaceless EGL context that its renderers draw
   with and its textures live in. */
typedef struct ZlDomain {
    GpuDomainEpoch *epoch;void *callback_context;void (*release_callback)(void *,int);
    EGLContext context;int driver,software;
    ZlImage textures[ZI_IMAGE_SLOTS];GpuTextureToken tokens[ZI_IMAGE_SLOTS];
    ZlRenderer *renderers;
    uint32_t device_creations,device_losses;uint64_t texture_creations;
} ZlDomain;

/* The shaders. */
typedef struct ZlProgram {GLuint program;GLint insts,brushes,tex,tex_nearest,mask,base,frame,scale;} ZlProgram;
typedef struct ZlFilter {GLuint program;GLint source,header,weights;} ZlFilter;
/* A shader effect's program, and the backdrop effect passes. */
typedef struct ZlEffect {GLuint program;GLint frame;} ZlEffect;
typedef struct ZlGlassPrograms {GLuint filter,blend,shade;GLint filter_source,filter_header,filter_weights,blend_glass,blend_region,blend_out,blend_level,blend_result,blend_current,shade_glass,shade_region,shade_out,shade_height,shade_dst,shade_res;} ZlGlassPrograms;

struct ZlRenderer {
    /* 1 GDK context of a window, 2 EGL context (own or the domain's). */
    int backend;
    GdkGLContext *gdk;GdkWindow *gdk_window;
    EGLContext egl;int owns_egl;
    ZlDomain *domain;ZlRenderer *domain_next;int lost,loss_fault;
    int allow_software,software,failed;
    ZlProgram main;ZlFilter filter;GLint main_words,main_opacity;
    ZlEffect effects[ZL_EFFECT_SLOTS];ZlGlassPrograms glass;GLuint effect_vertex,effect_buffers[2];
    GLuint vertex_array,instance_buffer,instance_texture,brush_buffer,brush_texture,blank,words_buffer,words_texture;
    GLuint linear_sampler,nearest_sampler,mask_sampler;
    GLint max_texture,max_texels;
    uint32_t width,height;float scale;int transparent,drawing,offscreen;
    /* The window's frame as last drawn; generation names its contents. */
    ZlTarget back;uint64_t generation;int back_valid,partial;
    /* Offscreen surfaces: the work target and the committed front. */
    ZlTarget offscreen_target,front;
    /* A frame read back into memory and painted with cairo. */
    cairo_surface_t *memory;
    ZlInstance *instances;uint32_t instance_len,instance_capacity;
    ZlBatch *batches;uint32_t batch_len,batch_capacity;
    ZlBrush brushes[ZG_BRUSH_CAPACITY];uint32_t brush_len;
    ZlRun *runs;uint32_t run_len,run_capacity;
    ZlCapture captures[ZL_DEPTH];uint32_t capture_depth;
    float clips[ZL_CLIPS][4];uint32_t clip_depth;
    /* Effects' words and backdrop effects' kernels, and indicators'
       elements, of the frame. */
    uint32_t *words;uint32_t word_len,word_capacity;
    /* The opacity drawings draw at now (Command.push_opacity), and those
       the opacities open saved. */
    float faded,fades[ZL_CLIPS];uint32_t fade_depth;
    /* Capture targets of this frame and those free for later frames. */
    ZlTarget frame_targets[160];uint32_t frame_target_len;
    ZlTarget free_targets[ZL_FREE_TARGETS];uint32_t free_target_len;
    ZlImage *slots;uint32_t slot_len;ZlImage candidate;
    void *prepared_keys[ZL_PREPARED];GLuint prepared_textures[ZL_PREPARED];uint32_t prepared_len;
    ZlText texts[ZL_TEXT_ENTRIES];uint32_t text_len;size_t text_bytes;uint64_t frame_serial;
    PangoLayout *layout;PangoFontDescription *font;float layout_scale;
    /* The toplevel whose draw signal adds GTK's repaint to the Wayland
       surface's damage. */
    GtkWidget *toplevel;gulong damage_handler;
    int capture,shown;uint32_t *captured;uint32_t captured_width,captured_height;
    ZlStats stats;
    /* A browser window's canvas, and the restorations of its context the
       renderer's objects were made after. */
    uint32_t web_window,web_generation;
};

static int live_objects;
uint32_t zglr_live_objects(void){return (uint32_t)live_objects;}

#ifdef __wasm__
static EGLDisplay egl_display=EGL_NO_DISPLAY;
static EGLContext egl_create(void){return EGL_NO_CONTEXT;}
static int egl_current(EGLContext context){(void)context;return 0;}
static void egl_release(void){}
static void eglDestroyContext(EGLDisplay display,EGLContext context){(void)display;(void)context;}
#else
/* EGL: one display for the process. */
static EGLDisplay egl_display=EGL_NO_DISPLAY;
static EGLConfig egl_config;
static int egl_ready(void){
    static int tried;
    if(tried)return egl_display!=EGL_NO_DISPLAY;
    tried=1;
    if(!epoxy_has_egl())return 0;
    PFNEGLGETPLATFORMDISPLAYEXTPROC get_display=(PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    EGLDisplay display=EGL_NO_DISPLAY;
    if(get_display)display=get_display(EGL_PLATFORM_SURFACELESS_MESA,EGL_DEFAULT_DISPLAY,NULL);
    if(display==EGL_NO_DISPLAY)display=eglGetDisplay(EGL_DEFAULT_DISPLAY);
    EGLint major,minor;
    if(display==EGL_NO_DISPLAY||!eglInitialize(display,&major,&minor)||!eglBindAPI(EGL_OPENGL_API))return 0;
    const EGLint config_attributes[]={EGL_RENDERABLE_TYPE,EGL_OPENGL_BIT,EGL_NONE};
    EGLint count=0;
    if(!eglChooseConfig(display,config_attributes,&egl_config,1,&count)||count==0)egl_config=NULL;
    egl_display=display;return 1;
}
static EGLContext egl_create(void){
    if(!egl_ready())return EGL_NO_CONTEXT;
    const EGLint attributes[]={EGL_CONTEXT_MAJOR_VERSION,3,EGL_CONTEXT_MINOR_VERSION,3,EGL_CONTEXT_OPENGL_PROFILE_MASK,EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,EGL_NONE};
    return eglCreateContext(egl_display,egl_config,EGL_NO_CONTEXT,attributes);
}
/* GDK caches the context it made current: one made current behind its
   back leaves it believing its own still is, so it is told first. */
static int egl_current(EGLContext context){
    if(gdk_gl_context_get_current())gdk_gl_context_clear_current();
    return context!=EGL_NO_CONTEXT&&eglMakeCurrent(egl_display,EGL_NO_SURFACE,EGL_NO_SURFACE,context);
}
static void egl_release(void){if(egl_display!=EGL_NO_DISPLAY)eglMakeCurrent(egl_display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);}
#endif
static int software_name(const char *name){
    if(!name)return 0;
    char lower[256];size_t n=0;for(;name[n]&&n+1<sizeof(lower);n++)lower[n]=(char)(name[n]>='A'&&name[n]<='Z'?name[n]+32:name[n]);lower[n]=0;
    return strstr(lower,"llvmpipe")||strstr(lower,"softpipe")||strstr(lower,"swrast")||strstr(lower,"software rasterizer");
}

/* Makes the renderer's context current: 0, or 1 when it has none. A GDK
   context is made current again every time, as anything else drawing with
   OpenGL in between (GDK's own paint, effects on EGL) leaves another. */
static int current(ZlRenderer *s){
#ifdef __wasm__
    if(s->backend==1){uint32_t generation=0;return zgl_current(s->web_window,&generation)!=0||generation!=s->web_generation;}
#else
    if(s->backend==1){
        if(!s->gdk)return 1;
        gdk_gl_context_clear_current();gdk_gl_context_make_current(s->gdk);return 0;
    }
#endif
    if(s->backend==2){
        EGLContext context=s->domain?s->domain->context:s->egl;
        return egl_current(context)?0:1;
    }
    return 1;
}
static void leave(ZlRenderer *s){if(s->backend==2)egl_release();}

static const char *vertex_source=
"#version 330 core\n"
"uniform samplerBuffer insts;uniform int base;uniform vec4 frame;\n"
"flat out int inst;out vec2 uv;\n"
"void main(){\n"
"  int id=base+gl_InstanceID;\n"
"  vec4 rect=texelFetch(insts,id*5),clip=texelFetch(insts,id*5+1),p=texelFetch(insts,id*5+3),uvr=texelFetch(insts,id*5+4);\n"
"  int kind=int(p.z);\n"
"  float grow=(kind<=2||kind==5||kind==6)?1.0:0.0;\n"
"  vec4 q=vec4(max(rect.xy-grow,floor(clip.xy)),min(rect.zw+grow,ceil(clip.zw)));\n"
"  q.zw=max(q.zw,q.xy);\n"
"  vec2 corner=vec2(float(gl_VertexID&1),float(gl_VertexID>>1));\n"
"  vec2 pt=mix(q.xy,q.zw,corner);\n"
"  vec2 d=pt-frame.zw;\n"
"  gl_Position=vec4(d.x/frame.x*2.0-1.0,1.0-d.y/frame.y*2.0,0.0,1.0);\n"
"  vec2 t=(pt-rect.xy)/max(rect.zw-rect.xy,vec2(1e-6));\n"
"  uv=mix(uvr.xy,uvr.zw,t);inst=id;\n"
"}\n";
static const char *fragment_source=
"#version 330 core\n"
"uniform samplerBuffer insts;uniform samplerBuffer brushes;uniform sampler2D tex;uniform sampler2D tex_nearest;uniform sampler2D mask;\n"
"uniform vec4 frame;uniform float scale;uniform samplerBuffer words;uniform float opacity;\n"
"flat in int inst;in vec2 uv;out vec4 result;\n"
"const float PI=3.14159265358979323846;\n"
"float span(float c,float a,float b){return clamp(min(c+0.5,b)-max(c-0.5,a),0.0,1.0);}\n"
"float box(vec2 p,vec4 r){return span(p.x,r.x,r.z)*span(p.y,r.y,r.w);}\n"
"float rounded(vec2 p,vec4 r,float radius){\n"
"  if(r.z<=r.x||r.w<=r.y)return 0.0;\n"
"  if(radius<0.5)return box(p,r);\n"
"  vec2 c=(r.xy+r.zw)*0.5;vec2 h=(r.zw-r.xy)*0.5;\n"
"  vec2 q=abs(p-c)-(h-radius);\n"
"  float d=length(max(q,vec2(0.0)))+min(max(q.x,q.y),0.0)-radius;\n"
"  return clamp(0.5-d,0.0,1.0);\n"
"}\n"
"float shape(vec2 p,vec4 r,vec4 params){\n"
"  float radius=params.x;float stroke=params.y;\n"
"  float outer=rounded(p,r,radius);\n"
"  float w=r.z-r.x;float h=r.w-r.y;\n"
"  if(stroke>0.0&&w>stroke*2.0&&h>stroke*2.0)outer=max(outer-rounded(p,r+vec4(stroke,stroke,-stroke,-stroke),max(0.0,radius-stroke)),0.0);\n"
"  return outer;\n"
"}\n"
"float stop_offset(int b,int k){vec4 o=texelFetch(brushes,b*22+2+k/4);int m=k-(k/4)*4;return m==0?o.x:m==1?o.y:m==2?o.z:o.w;}\n"
"vec4 gradient(int b,vec2 p){\n"
"  vec4 head=texelFetch(brushes,b*22),ab=texelFetch(brushes,b*22+1);\n"
"  int kind=int(head.x),spread=int(head.y),len=int(head.z);\n"
"  vec2 a=ab.xy;vec2 v=ab.zw;vec2 d=p-a;float t;\n"
"  if(kind==0){vec2 s=v-a;t=dot(d,s)/dot(s,s);}\n"
"  else if(kind==1){vec2 n=d/v;t=sqrt(dot(n,n));}\n"
"  else{if(d.x==0.0&&d.y==0.0)t=0.0;else{float turns=(atan(d.y,d.x)-v.x)*(v.y/(2.0*PI));t=turns-floor(turns);}}\n"
"  if(spread==1)t=t-floor(t);else if(spread==2){float m=t-2.0*floor(t*0.5);t=m>1.0?2.0-m:m;}\n"
"  int low=0;for(int k=0;k<len;k++)if(stop_offset(b,k)<=t)low=k+1;\n"
"  vec4 c;\n"
"  if(low==0)c=texelFetch(brushes,b*22+6);else if(low>=len)c=texelFetch(brushes,b*22+6+len-1);\n"
"  else{float o0=stop_offset(b,low-1);float o1=stop_offset(b,low);\n"
"    float w=o1>o0?(t-o0)/(o1-o0):0.0;c=mix(texelFetch(brushes,b*22+6+low-1),texelFetch(brushes,b*22+6+low),w);}\n"
"  int space=int(head.w);if(space==0)return c;if(c.a<=0.0)return vec4(0.0);\n"
"  vec3 u=c.rgb/c.a;\n"
"  if(space==2){float l=u.x+0.3963377774*u.y+0.2158037573*u.z,m=u.x-0.1055613458*u.y-0.0638541728*u.z,q=u.x-0.0894841775*u.y-1.2914855480*u.z;\n"
"    l=l*l*l;m=m*m*m;q=q*q*q;u=vec3(4.0767416621*l-3.3077115913*m+0.2309699292*q,-1.2684380046*l+2.6097574011*m-0.3413193965*q,-0.0041960863*l-0.7034186147*m+1.7076147010*q);}\n"
"  u=clamp(u,0.0,1.0);\n"
"  vec3 e=mix(1.055*pow(u,vec3(1.0/2.4))-0.055,u*12.92,lessThanEqual(u,vec3(0.0031308)));e=mix(e,vec3(1.0),equal(u,vec3(1.0)));\n"
"  return vec4(e*c.a,c.a);\n"
"}\n"
/* A render target's texel, by device row from its top. */
"vec4 texel(ivec2 q){ivec2 size=textureSize(tex,0);return (q.x>=0&&q.y>=0&&q.x<size.x&&q.y<size.y)?texelFetch(tex,ivec2(q.x,size.y-1-q.y),0):vec4(0.0);}\n"
"vec4 bilinear(vec2 s){\n"
"  ivec2 size=textureSize(tex,0);\n"
"  if(s.x<=-1.0||s.y<=-1.0||s.x>=float(size.x)||s.y>=float(size.y))return vec4(0.0);\n"
"  vec2 f=floor(s);vec2 w=s-f;ivec2 q=ivec2(f);\n"
"  vec4 sum=texel(q)*((1.0-w.x)*(1.0-w.y))+texel(q+ivec2(1,0))*(w.x*(1.0-w.y))+texel(q+ivec2(0,1))*((1.0-w.x)*w.y)+texel(q+ivec2(1,1))*(w.x*w.y);\n"
"  return floor(clamp(sum*255.0,0.0,255.0)+0.5)/255.0;\n"
"}\n"
/* Loading indicators (src/ui/loading.zig): elements of 12 floats among the
   frame's words, evaluated per pixel as the software planes rasterize. */
"float W(int i){return texelFetch(words,i).r;}\n"
"float hyp(float x,float y){return sqrt(x*x+y*y);}\n"
"vec2 rot(float x,float y,float a){float c=cos(a),s=sin(a);return vec2(x*c+y*s,-x*s+y*c);}\n"
"float rbox(float x,float y,float hw,float hh,float r){r=min(r,min(hw,hh));float qx=abs(x)-(hw-r),qy=abs(y)-(hh-r);float mx=max(qx,0.0),my=max(qy,0.0);return sqrt(mx*mx+my*my)+min(max(qx,qy),0.0)-r;}\n"
"float seg(float px,float py,float x0,float y0,float x1,float y1){float dx=x1-x0,dy=y1-y0,l=dx*dx+dy*dy;float h=l>0.0?clamp(((px-x0)*dx+(py-y0)*dy)/l,0.0,1.0):0.0;return hyp(px-x0-dx*h,py-y0-dy*h);}\n"
"float turned(float start,float a){float t=(a-start)/(2.0*PI);return (t-floor(t))*(2.0*PI);}\n"
"vec2 element(int e,float px,float py){\n"
"  int k=int(W(e));\n"
"  if(k==0)return vec2(hyp(px-W(e+2),py-W(e+3))-W(e+4),1.0);\n"
"  if(k==1)return vec2(abs(hyp(px-W(e+2),py-W(e+3))-W(e+4))-W(e+5)*0.5,1.0);\n"
"  if(k==2){float dx=px-W(e+2),dy=py-W(e+3);float ring=abs(hyp(dx,dy)-W(e+4))-W(e+5)*0.5;float off=turned(W(e+6),atan(dy,dx));float sw=min(W(e+7),2.0*PI);bool fade=W(e+9)>0.5;\n"
"    if(off<=sw)return vec2(ring,fade?clamp(off/max(sw,1e-6),0.0,1.0):1.0);\n"
"    float best=1e30;for(int n=0;n<2;n++){float a=n==0?W(e+6):W(e+6)+sw;float ex=W(e+2)+W(e+4)*cos(a),ey=W(e+3)+W(e+4)*sin(a);\n"
"      if(W(e+8)<0.5)best=min(best,hyp(px-ex,py-ey)-W(e+5)*0.5);else{float nx=cos(a)*W(e+5)*0.5,ny=sin(a)*W(e+5)*0.5;best=min(best,seg(px,py,ex-nx,ey-ny,ex+nx,ey+ny));}}\n"
"    return vec2(best,fade?(off-sw<(2.0*PI-sw)*0.5?1.0:0.0):1.0);}\n"
"  if(k==3){vec2 q=rot(px-W(e+2),py-W(e+3),W(e+7));return vec2(rbox(q.x,q.y,W(e+4),W(e+5),W(e+6)),1.0);}\n"
"  if(k==4){if(W(e+7)<0.5)return vec2(seg(px,py,W(e+2),W(e+3),W(e+4),W(e+5))-W(e+6)*0.5,1.0);\n"
"    float dx=W(e+4)-W(e+2),dy=W(e+5)-W(e+3);float len=hyp(dx,dy);if(len==0.0)return vec2(1e30,1.0);\n"
"    vec2 q=rot(px-(W(e+2)+W(e+4))*0.5,py-(W(e+3)+W(e+5))*0.5,atan(dy,dx));return vec2(rbox(q.x,q.y,len*0.5,W(e+6)*0.5,0.0),1.0);}\n"
"  if(k==5){vec2 q=rot(px-W(e+2),py-W(e+3),W(e+7));float ry=max(abs(W(e+5)),0.2);float qx=q.x/W(e+4),qy=q.y/ry;float n=hyp(qx,qy);\n"
"    if(n==0.0)return vec2(min(W(e+4),ry)-W(e+6)*0.5,1.0);return vec2(abs((n-1.0)/hyp(qx/(W(e+4)*n),qy/(ry*n)))-W(e+6)*0.5,1.0);}\n"
"  float dx=px-W(e+2),dy=py-W(e+3);float behind=turned(atan(dy,dx),W(e+5));return vec2(hyp(dx,dy)-W(e+4),behind<=W(e+6)?1.0-behind/W(e+6):0.0);\n"
"}\n"
"vec4 shade(){\n"
"  vec4 rect=texelFetch(insts,inst*5),clip=texelFetch(insts,inst*5+1),color=texelFetch(insts,inst*5+2),params=texelFetch(insts,inst*5+3),uvr=texelFetch(insts,inst*5+4);\n"
"  vec2 p=vec2(gl_FragCoord.x,frame.y-gl_FragCoord.y)+frame.zw;int kind=int(params.z);\n"
"  float cov=box(p,clip);\n"
"  if(kind==0)cov*=box(p,rect);\n"
"  else if(kind==1)cov*=shape(p,rect,params);\n"
"  else if(kind==2){cov*=shape(p,rect,params);color=gradient(int(params.w),p/scale);}\n"
"  else if(kind==3)cov*=textureLod(tex,uv,0.0).r;\n"
"  else if(kind==4){ivec2 q=ivec2(floor(p-rect.xy));ivec2 size=textureSize(tex,0);return (q.x>=0&&q.y>=0&&q.x<size.x&&q.y<size.y)?texelFetch(tex,q,0)*cov:vec4(0.0);}\n"
"  else if(kind==6){float m=1.0;if(params.w>0.5)m=texture(mask,(p-uvr.xy)/(uvr.zw-uvr.xy)).r;return texel(ivec2(floor(p-params.xy)))*(color.a*cov*box(p,rect)*m);}\n"
"  else if(kind==7){vec2 s=vec2(uvr.x*p.x+uvr.y*p.y+params.x,uvr.z*p.x+uvr.w*p.y+params.y);return bilinear(s)*cov;}\n"
"  else if(kind==5){float lod=params.x;vec4 t=params.w>0.5?textureLod(tex,uv,lod):textureLod(tex_nearest,uv,lod);return t*(color.a*cov*box(p,rect));}\n"
"  else if(kind==8){int e=int(params.x);int n=int(params.y);float k=uvr.z;float px=(p.x-uvr.x)/k,py=(p.y-uvr.y)/k;float aa=1.0/k;float total=0.0;\n"
"    for(int j=0;j<n;j++){vec2 v=element(e+j*12,px,py);float a=clamp(0.5-v.x/aa,0.0,1.0)*W(e+j*12+1)*v.y;total=a+total*(1.0-a);}\n"
"    float alpha=floor(clamp(total*color.a*cov,0.0,1.0)*255.0+0.5);if(alpha==0.0)return vec4(0.0);\n"
"    return vec4(floor((floor(color.rgb*255.0+0.5)*alpha+127.0)/255.0),alpha)/255.0;}\n"
"  return color*cov;\n"
"}\n"
/* Each drawing at the opacity of its batch, as if it multiplied its
   colors (Command.push_opacity). */
"void main(){result=shade()*opacity;}\n";
static const char *filter_vertex_source=
"#version 330 core\n"
"void main(){vec2 c=vec2(float(gl_VertexID&1),float(gl_VertexID>>1));gl_Position=vec4(c.x*2.0-1.0,1.0-c.y*2.0,0.0,1.0);}\n";
static const char *filter_fragment_source=
"#version 330 core\n"
"uniform sampler2D source;uniform uvec4 header;uniform uint weights[257];out vec4 result;\n"
"void main(){\n"
"  ivec2 at=ivec2(gl_FragCoord.xy);uvec4 total=uvec4(0u);int r=int(header.z);\n"
"  for(int tap=-r;tap<=r;tap++){\n"
"    ivec2 q=at+(header.w!=0u?ivec2(0,tap):ivec2(tap,0));\n"
"    if(q.x>=0&&q.y>=0&&q.x<int(header.x)&&q.y<int(header.y))total+=uvec4(floor(texelFetch(source,q,0)*255.0+0.5))*weights[tap+r];\n"
"  }\n"
"  result=vec4((total+8388608u)>>24)/255.0;\n"
"}\n";

/* Backdrop effects (src/ui/backdrop.zig): the copy of the target beneath
   the effect is blurred with the software planes' float kernel, rounded to
   bytes each pass (in its own texels: the kernel is symmetric), blended
   level by level for a progressive blur, and shaded inside the rounded
   box over out, as the software planes do. G holds ZlGlass's floats;
   rd reads a texture by its row from the top. */
static const char *glass_common=
"#version 330 core\n"
"const float PI=3.14159265358979323846;\n"
"vec4 rd(sampler2D t,ivec2 q){return texelFetch(t,ivec2(q.x,textureSize(t,0).y-1-q.y),0);}\n"
"vec4 blend_bytes(vec4 a,vec4 b,float t){return t>=1.0?b:floor(clamp(a+(b-a)*t,0.0,255.0)+0.5);}\n";
static const char *glass_filter_source=
"uniform sampler2D source;uniform uvec4 header;uniform float weights[257];out vec4 result;\n"
"void main(){\n"
"  ivec2 at=ivec2(gl_FragCoord.xy);int r=int(header.x);vec4 acc=vec4(0.0);ivec2 hi=ivec2(header.zw)-1;\n"
"  for(int tap=-r;tap<=r;tap++){ivec2 q=clamp(at+(header.y!=0u?ivec2(0,tap):ivec2(tap,0)),ivec2(0),hi);acc+=floor(texelFetch(source,q,0)*255.0+0.5)*weights[tap+r];}\n"
"  result=floor(clamp(acc,0.0,255.0)+0.5)/255.0;\n"
"}\n";
static const char *glass_blend_source=
"uniform vec4 G[10];uniform uvec4 region,outr;uniform vec2 level;uniform sampler2D result_texture,current;out vec4 result;\n"
"float blur_at(float px,float py){vec4 line=G[4],line2=G[5];float d=(px-line.x)*line.z+(py-line.y)*line.w;float t=line2.x>0.0?clamp(d/line2.x,0.0,1.0):(d>=0.0?1.0:0.0);return line2.y+(line2.z-line2.y)*t;}\n"
"void main(){\n"
"  ivec2 at=ivec2(gl_FragCoord.xy);vec4 a=floor(texelFetch(result_texture,at,0)*255.0+0.5);\n"
"  uint x=region.x+uint(at.x),y=region.y+uint(textureSize(current,0).y-1-at.y);\n"
"  if(x<outr.x||y<outr.y||x>=outr.z||y>=outr.w){result=a/255.0;return;}\n"
"  float weight=clamp((blur_at(float(x)+0.5,float(y)+0.5)-level.x)/(level.y-level.x),0.0,1.0);\n"
"  if(weight==0.0){result=a/255.0;return;}\n"
"  result=blend_bytes(a,floor(texelFetch(current,at,0)*255.0+0.5),weight)/255.0;\n"
"}\n";
static const char *glass_shade_source=
"uniform vec4 G[10];uniform uvec4 region,outr;uniform float height;uniform sampler2D dst,res;out vec4 result;\n"
"float rounded_distance(vec4 b,float radius,float x,float y){float hx=(b.z-b.x)*0.5,hy=(b.w-b.y)*0.5;float qx=abs(x-(b.x+hx))-(hx-radius),qy=abs(y-(b.y+hy))-(hy-radius);float ox=max(qx,0.0),oy=max(qy,0.0);return sqrt(ox*ox+oy*oy)+min(max(qx,qy),0.0)-radius;}\n"
"vec3 straight(vec4 c){if(c.a==0.0)return vec3(0.0);return min(vec3(1.0),c.rgb/c.a);}\n"
"float luma(vec3 c){return 0.2126*c.r+0.7152*c.g+0.0722*c.b;}\n"
"vec3 toned(vec3 c,float saturation,float offset){float l=luma(c);return clamp(l+(c-l)*saturation+offset,0.0,1.0);}\n"
"vec4 pack(vec3 c){return vec4(floor(clamp(c,0.0,1.0)*255.0+0.5),255.0);}\n"
"float lens(float t,float bezel){if(bezel<=0.0||t>=bezel)return 0.0;float u=1.0-max(t,0.0)/bezel;float v=1.0-u*u*u*u;float a=sqrt(v*sqrt(v));float b=u*u*u;float n=sqrt(a*a+b*b);float s=b/n,c=a/n;float st=s/1.5;float ct=sqrt(1.0-st*st);return ((s*ct-c*st)/(c*ct+s*st))/1.1180339887498949;}\n"
"float sgn(float v){return v>0.0?1.0:(v<0.0?-1.0:0.0);}\n"
"vec2 edge_normal(vec4 b,float radius,float px,float py){float hx=(b.z-b.x)*0.5,hy=(b.w-b.y)*0.5;float cx=px-b.x-hx,cy=py-b.y-hy;float rad=min(1.5*radius,min(hx,hy));float qx=abs(cx)-(hx-rad),qy=abs(cy)-(hy-rad);\n"
"  if(qx>0.0||qy>0.0){float mx=max(qx,0.0),my=max(qy,0.0);float n=sqrt(mx*mx+my*my);return vec2(sgn(cx)*mx/n,sgn(cy)*my/n);}\n"
"  return qx>qy?vec2(sgn(cx),0.0):vec2(0.0,sgn(cy));}\n"
"vec4 bilinear_clamped(sampler2D t,vec2 origin,float x,float y){vec2 size=vec2(textureSize(t,0));float w=size.x,h=size.y;\n"
"  float lx=clamp(x-0.5-origin.x,0.0,w-1.0),ly=clamp(y-0.5-origin.y,0.0,h-1.0);int ix=int(floor(lx)),iy=int(floor(ly));int jx=min(ix+1,int(w)-1),jy=min(iy+1,int(h)-1);float tx=lx-floor(lx),ty=ly-floor(ly);\n"
"  vec4 a=floor(rd(t,ivec2(ix,iy))*255.0+0.5),b=floor(rd(t,ivec2(jx,iy))*255.0+0.5),c=floor(rd(t,ivec2(ix,jy))*255.0+0.5),d=floor(rd(t,ivec2(jx,jy))*255.0+0.5);\n"
"  return (a*(1.0-tx)+b*tx)*(1.0-ty)+(c*(1.0-tx)+d*tx)*ty;}\n"
"float grain(uint x,uint y){uint v=x*73856093u^y*19349663u;v^=v>>16;v*=0x7feb352du;v^=v>>15;v*=0x846ca68bu;v^=v>>16;return float(v)/4294967296.0;}\n"
"void main(){\n"
"  vec4 box=G[0],clip=G[1],tone=G[2],tint=G[3],misc=G[6],misc2=G[7],background=G[8],fill=G[9];\n"
"  uvec2 xy=uvec2(uint(gl_FragCoord.x),uint(height-gl_FragCoord.y));ivec2 local=ivec2(xy-region.xy);float px=float(xy.x)+0.5,py=float(xy.y)+0.5;vec4 d=floor(rd(dst,local)*255.0+0.5);\n"
"  float radius=misc.x;float sd=rounded_distance(box,radius,px,py);\n"
"  float fx=float(xy.x),fy=float(xy.y);float cover=max(0.0,min(fx+1.0,clip.z)-max(fx,clip.x))*max(0.0,min(fy+1.0,clip.w)-max(fy,clip.y));\n"
"  uint kind=uint(misc2.y);float amount=clamp(0.5-sd,0.0,1.0)*cover*background.w;if(kind==3u)amount*=fill.a;\n"
"  if(amount==0.0){result=d/255.0;return;}\n"
"  vec4 color;\n"
"  if(kind==3u)color=pack(fill.rgb);\n"
"  else if(kind==0u)color=floor(rd(res,local)*255.0+0.5);\n"
"  else if(kind==2u){vec3 c=toned(straight(floor(rd(res,local)*255.0+0.5)),0.25,0.03);color=pack(c+(background.rgb-c)*0.8245);}\n"
"  else{float depth=max(-sd,0.0);float bezel=misc.z;vec2 n=vec2(0.0);if(depth<bezel||depth<3.0)n=edge_normal(box,radius,px,py);\n"
"    float sx=px,sy=py;if(depth<bezel){float k=misc.y*lens(depth,bezel);sx-=n.x*k;sy-=n.y*k;}\n"
"    vec3 c=straight(bilinear_clamped(res,vec2(region.xy),sx,sy));\n"
"    float l=luma(c);float target=tone.x+(tone.y-tone.x)*(1.0-pow(max(1.0-l,0.0),tone.z));c=clamp(target+(c-l)*((tone.y-tone.x)*tone.w),0.0,1.0);\n"
"    if(tint.a>0.0)c+=(tint.rgb-c)*tint.a;\n"
"    if(depth<3.0){float a=misc2.x*exp(-depth*depth);c+=(abs(n.y)-c)*a;}\n"
"    if(misc.w>0.0)c+=(grain(xy.x,xy.y)-0.5)*misc.w*0.08;\n"
"    color=pack(c);}\n"
"  vec4 r=blend_bytes(d,color,amount);if(misc2.z==0.0)r.a=255.0;\n"
"  result=r/255.0;\n"
"}\n";
/* Shader effect programs draw a triangle over their whole target, cut to
   what they write by the scissor. */
static const char *effect_vertex_source=
"#version 330 core\n"
"void main(){vec2 p=vec2(gl_VertexID==1?3.0:-1.0,gl_VertexID==2?3.0:-1.0);gl_Position=vec4(p,0.0,1.0);}\n";
static GLuint compile(GLenum kind,const char *source){
    GLuint shader=glCreateShader(kind);glShaderSource(shader,1,&source,NULL);glCompileShader(shader);
    GLint ok=0;glGetShaderiv(shader,GL_COMPILE_STATUS,&ok);
    if(!ok){char log[2048];glGetShaderInfoLog(shader,sizeof(log),NULL,log);fprintf(stderr,"ziggurat OpenGL shader: %s\n",log);glDeleteShader(shader);return 0;}
    return shader;
}
static GLuint compile_two(GLenum kind,const char *first,const char *second,int quiet){
    GLuint shader=glCreateShader(kind);const char *sources[2]={first,second};glShaderSource(shader,2,sources,NULL);glCompileShader(shader);
    GLint ok=0;glGetShaderiv(shader,GL_COMPILE_STATUS,&ok);
    if(!ok){if(!quiet){char log[2048];glGetShaderInfoLog(shader,sizeof(log),NULL,log);fprintf(stderr,"ziggurat OpenGL shader: %s\n",log);}glDeleteShader(shader);return 0;}
    return shader;
}
static GLuint link_shaders(GLuint v,GLuint f){
    GLuint program=glCreateProgram();glAttachShader(program,v);glAttachShader(program,f);glLinkProgram(program);
    GLint ok=0;glGetProgramiv(program,GL_LINK_STATUS,&ok);
    if(!ok){glDeleteProgram(program);return 0;}
    return program;
}
static GLuint link_program(const char *vertex,const char *fragment){
    GLuint v=compile(GL_VERTEX_SHADER,vertex),f=v?compile(GL_FRAGMENT_SHADER,fragment):0;
    if(!v||!f){if(v)glDeleteShader(v);return 0;}
    GLuint program=glCreateProgram();glAttachShader(program,v);glAttachShader(program,f);glLinkProgram(program);
    glDeleteShader(v);glDeleteShader(f);
    GLint ok=0;glGetProgramiv(program,GL_LINK_STATUS,&ok);
    if(!ok){char log[2048];glGetProgramInfoLog(program,sizeof(log),NULL,log);fprintf(stderr,"ziggurat OpenGL program: %s\n",log);glDeleteProgram(program);return 0;}
    return program;
}
static void drop_target(ZlTarget *t){
    if(t->framebuffer)glDeleteFramebuffers(1,&t->framebuffer);
    if(t->texture)glDeleteTextures(1,&t->texture);
    memset(t,0,sizeof(*t));
}
static int make_target(ZlTarget *t,uint32_t width,uint32_t height){
    memset(t,0,sizeof(*t));
    glGenTextures(1,&t->texture);glBindTexture(GL_TEXTURE_2D,t->texture);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAX_LEVEL,0);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,(GLsizei)width,(GLsizei)height,0,GL_RGBA,GL_UNSIGNED_BYTE,NULL);
    glGenFramebuffers(1,&t->framebuffer);glBindFramebuffer(GL_FRAMEBUFFER,t->framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,t->texture,0);
    int ok=glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE&&glGetError()==GL_NO_ERROR;
    if(!ok){drop_target(t);return 0;}
    t->width=width;t->height=height;return 1;
}
static void drop_image(ZlImage *image){if(image->texture)glDeleteTextures(1,&image->texture);memset(image,0,sizeof(*image));}
static void drop_text(ZlRenderer *s,ZlText *t){
    if(t->texture)glDeleteTextures(1,&t->texture);
    s->text_bytes-=(size_t)t->width*t->height*4;free(t->bytes);memset(t,0,sizeof(*t));
}

/* What a renderer made with its context. */
static void drop_objects(ZlRenderer *s){
    for(uint32_t k=0;k<s->text_len;k++)drop_text(s,&s->texts[k]);
    s->text_len=0;s->text_bytes=0;
    for(uint32_t k=0;k<s->prepared_len;k++)glDeleteTextures(1,&s->prepared_textures[k]);
    s->prepared_len=0;
    for(uint32_t k=0;k<s->slot_len;k++)drop_image(&s->slots[k]);
    drop_image(&s->candidate);
    for(uint32_t k=0;k<s->frame_target_len;k++)drop_target(&s->frame_targets[k]);
    s->frame_target_len=0;
    for(uint32_t k=0;k<s->free_target_len;k++)drop_target(&s->free_targets[k]);
    s->free_target_len=0;
    drop_target(&s->back);drop_target(&s->offscreen_target);drop_target(&s->front);
    s->back_valid=0;s->generation++;
    if(s->main.program)glDeleteProgram(s->main.program);
    if(s->filter.program)glDeleteProgram(s->filter.program);
    for(int k=0;k<ZL_EFFECT_SLOTS;k++)if(s->effects[k].program)glDeleteProgram(s->effects[k].program);
    memset(s->effects,0,sizeof(s->effects));
    if(s->glass.filter)glDeleteProgram(s->glass.filter);
    if(s->glass.blend)glDeleteProgram(s->glass.blend);
    if(s->glass.shade)glDeleteProgram(s->glass.shade);
    memset(&s->glass,0,sizeof(s->glass));
    if(s->effect_vertex)glDeleteShader(s->effect_vertex);
    s->effect_vertex=0;
    glDeleteBuffers(2,s->effect_buffers);s->effect_buffers[0]=s->effect_buffers[1]=0;
    if(s->words_texture)glDeleteTextures(1,&s->words_texture);
    if(s->words_buffer)glDeleteBuffers(1,&s->words_buffer);
    s->words_texture=s->words_buffer=0;
    memset(&s->main,0,sizeof(s->main));memset(&s->filter,0,sizeof(s->filter));
    GLuint textures[3]={s->instance_texture,s->brush_texture,s->blank},buffers[2]={s->instance_buffer,s->brush_buffer},samplers[3]={s->linear_sampler,s->nearest_sampler,s->mask_sampler};
    glDeleteTextures(3,textures);glDeleteBuffers(2,buffers);glDeleteSamplers(3,samplers);
    if(s->vertex_array)glDeleteVertexArrays(1,&s->vertex_array);
    s->instance_texture=s->brush_texture=s->blank=s->instance_buffer=s->brush_buffer=s->linear_sampler=s->nearest_sampler=s->mask_sampler=s->vertex_array=0;
}
/* The programs and objects every frame uses, in the current context. */
static int create_objects(ZlRenderer *s){
#ifdef __wasm__
    char name[128];name[zgl_renderer(name,sizeof(name)-1)]=0;
#else
    const char *name=(const char *)glGetString(GL_RENDERER);
#endif
    s->software=software_name(name);
    glGetIntegerv(GL_MAX_TEXTURE_SIZE,&s->max_texture);glGetIntegerv(GL_MAX_TEXTURE_BUFFER_SIZE,&s->max_texels);
    s->main.program=link_program(vertex_source,fragment_source);
    s->filter.program=s->main.program?link_program(filter_vertex_source,filter_fragment_source):0;
    if(!s->main.program||!s->filter.program)return 0;
    GLuint p=s->main.program;
    s->main.insts=glGetUniformLocation(p,"insts");s->main.brushes=glGetUniformLocation(p,"brushes");s->main.tex=glGetUniformLocation(p,"tex");
    s->main.tex_nearest=glGetUniformLocation(p,"tex_nearest");s->main.mask=glGetUniformLocation(p,"mask");s->main.base=glGetUniformLocation(p,"base");
    s->main.frame=glGetUniformLocation(p,"frame");s->main.scale=glGetUniformLocation(p,"scale");
    s->main_words=glGetUniformLocation(p,"words");s->main_opacity=glGetUniformLocation(p,"opacity");
    {
        /* The backdrop effect passes and the effects' vertex shader. */
        GLuint v=compile(GL_VERTEX_SHADER,filter_vertex_source);if(!v)return 0;
        GLuint f=compile_two(GL_FRAGMENT_SHADER,glass_common,glass_filter_source,0);
        GLuint b=compile_two(GL_FRAGMENT_SHADER,glass_common,glass_blend_source,0);
        GLuint h=compile_two(GL_FRAGMENT_SHADER,glass_common,glass_shade_source,0);
        if(f)s->glass.filter=link_shaders(v,f);
        if(b)s->glass.blend=link_shaders(v,b);
        if(h)s->glass.shade=link_shaders(v,h);
        glDeleteShader(v);if(f)glDeleteShader(f);if(b)glDeleteShader(b);if(h)glDeleteShader(h);
        if(!s->glass.filter||!s->glass.blend||!s->glass.shade)return 0;
        ZlGlassPrograms *g=&s->glass;
        g->filter_source=glGetUniformLocation(g->filter,"source");g->filter_header=glGetUniformLocation(g->filter,"header");g->filter_weights=glGetUniformLocation(g->filter,"weights");
        g->blend_glass=glGetUniformLocation(g->blend,"G");g->blend_region=glGetUniformLocation(g->blend,"region");g->blend_out=glGetUniformLocation(g->blend,"outr");g->blend_level=glGetUniformLocation(g->blend,"level");
        g->blend_result=glGetUniformLocation(g->blend,"result_texture");g->blend_current=glGetUniformLocation(g->blend,"current");
        g->shade_glass=glGetUniformLocation(g->shade,"G");g->shade_region=glGetUniformLocation(g->shade,"region");g->shade_out=glGetUniformLocation(g->shade,"outr");g->shade_height=glGetUniformLocation(g->shade,"height");
        g->shade_dst=glGetUniformLocation(g->shade,"dst");g->shade_res=glGetUniformLocation(g->shade,"res");
        s->effect_vertex=compile(GL_VERTEX_SHADER,effect_vertex_source);if(!s->effect_vertex)return 0;
        glGenBuffers(2,s->effect_buffers);
        glBindBuffer(GL_UNIFORM_BUFFER,s->effect_buffers[0]);glBufferData(GL_UNIFORM_BUFFER,ZL_EFFECT_WORDS*4,NULL,GL_STREAM_DRAW);
        glBindBuffer(GL_UNIFORM_BUFFER,s->effect_buffers[1]);glBufferData(GL_UNIFORM_BUFFER,sizeof(ZlEffectParams),NULL,GL_STREAM_DRAW);
        glBindBuffer(GL_UNIFORM_BUFFER,0);
        glGenBuffers(1,&s->words_buffer);glGenTextures(1,&s->words_texture);
        glBindBuffer(GL_TEXTURE_BUFFER,s->words_buffer);glBufferData(GL_TEXTURE_BUFFER,16,NULL,GL_STREAM_DRAW);
        glBindTexture(GL_TEXTURE_BUFFER,s->words_texture);glTexBuffer(GL_TEXTURE_BUFFER,GL_R32F,s->words_buffer);
        glBindTexture(GL_TEXTURE_BUFFER,0);glBindBuffer(GL_TEXTURE_BUFFER,0);
    }
    s->filter.source=glGetUniformLocation(s->filter.program,"source");s->filter.header=glGetUniformLocation(s->filter.program,"header");s->filter.weights=glGetUniformLocation(s->filter.program,"weights");
    glGenVertexArrays(1,&s->vertex_array);
    glGenBuffers(1,&s->instance_buffer);glGenBuffers(1,&s->brush_buffer);
    glGenTextures(1,&s->instance_texture);glGenTextures(1,&s->brush_texture);glGenTextures(1,&s->blank);
    glBindBuffer(GL_TEXTURE_BUFFER,s->instance_buffer);glBufferData(GL_TEXTURE_BUFFER,sizeof(ZlInstance),NULL,GL_STREAM_DRAW);
    glBindTexture(GL_TEXTURE_BUFFER,s->instance_texture);glTexBuffer(GL_TEXTURE_BUFFER,GL_RGBA32F,s->instance_buffer);
    glBindBuffer(GL_TEXTURE_BUFFER,s->brush_buffer);glBufferData(GL_TEXTURE_BUFFER,sizeof(ZlBrush),NULL,GL_STREAM_DRAW);
    glBindTexture(GL_TEXTURE_BUFFER,s->brush_texture);glTexBuffer(GL_TEXTURE_BUFFER,GL_RGBA32F,s->brush_buffer);
    glBindTexture(GL_TEXTURE_BUFFER,0);glBindBuffer(GL_TEXTURE_BUFFER,0);
    uint32_t white=0xffffffff;
    glBindTexture(GL_TEXTURE_2D,s->blank);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAX_LEVEL,0);
    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,1,1,0,GL_BGRA,GL_UNSIGNED_BYTE,&white);
    glGenSamplers(1,&s->linear_sampler);glGenSamplers(1,&s->nearest_sampler);glGenSamplers(1,&s->mask_sampler);
    /* Images pick their level on the CPU and pass it as an explicit lod. */
    glSamplerParameteri(s->linear_sampler,GL_TEXTURE_MIN_FILTER,GL_LINEAR_MIPMAP_NEAREST);glSamplerParameteri(s->linear_sampler,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    glSamplerParameteri(s->nearest_sampler,GL_TEXTURE_MIN_FILTER,GL_NEAREST_MIPMAP_NEAREST);glSamplerParameteri(s->nearest_sampler,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
    GLuint edge[2]={s->linear_sampler,s->nearest_sampler};
    for(int k=0;k<2;k++){glSamplerParameteri(edge[k],GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glSamplerParameteri(edge[k],GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);}
    const float zero[4]={0,0,0,0};
    glSamplerParameteri(s->mask_sampler,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glSamplerParameteri(s->mask_sampler,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    glSamplerParameteri(s->mask_sampler,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_BORDER);glSamplerParameteri(s->mask_sampler,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_BORDER);
    glSamplerParameterfv(s->mask_sampler,GL_TEXTURE_BORDER_COLOR,zero);
    return glGetError()==GL_NO_ERROR;
}

static ZlRenderer *new_renderer(void){
    ZlRenderer *s=calloc(1,sizeof(*s));if(!s)return NULL;
    live_objects++;return s;
}
/* A renderer for a window, whose context it makes at its first frame.
   allow_software: draw on a software rasterizer too. */
void *zglr_create(int allow_software){
    ZlRenderer *s=new_renderer();if(!s)return NULL;
    s->allow_software=allow_software;return s;
}
static int own_context(ZlRenderer *s);
void zglr_destroy(void *p);
/* A renderer of offscreen frames alone, with an EGL context of its own. */
void *zglr_create_own(int allow_software,int *error){
    ZlRenderer *s=new_renderer();if(!s){*error=2;return NULL;}
    s->allow_software=allow_software;
    if(own_context(s)){zglr_destroy(s);*error=1;return NULL;}
    leave(s);
    if(s->software&&!allow_software){zglr_destroy(s);*error=1;return NULL;}
    *error=0;return s;
}
/* Whether the renderer has a context: a window's makes one at its first
   frame, and uploads before it wait for the frames that draw them. */
int zglr_ready(void *p){ZlRenderer *s=p;return s->backend!=0&&!s->lost;}
static void disconnect_damage(ZlRenderer *s);
void zglr_destroy(void *p){
    ZlRenderer *s=p;if(!s)return;
    disconnect_damage(s);
    if(s->backend&&!s->lost&&current(s)==0)drop_objects(s);
    leave(s);
    if(s->domain){ZlRenderer **link=&s->domain->renderers;while(*link&&*link!=s)link=&(*link)->domain_next;if(*link)*link=s->domain_next;}
    if(s->owns_egl&&s->egl!=EGL_NO_CONTEXT)eglDestroyContext(egl_display,s->egl);
#ifndef __wasm__
    if(s->gdk){if(gdk_gl_context_get_current()==s->gdk)gdk_gl_context_clear_current();g_object_unref(s->gdk);}
    if(s->gdk_window)g_object_remove_weak_pointer(G_OBJECT(s->gdk_window),(gpointer *)&s->gdk_window);
    if(s->memory)cairo_surface_destroy(s->memory);
    if(s->layout)g_object_unref(s->layout);
    if(s->font)pango_font_description_free(s->font);
#endif
    free(s->instances);free(s->batches);free(s->runs);free(s->slots);free(s->captured);free(s->words);
    free(s);live_objects--;
}

#ifdef __wasm__
/* A browser draws with WebGL2 wherever the page has it: what it runs on
   is the browser's to choose. */
int zglr_probe(void){return 1;}
const char *zglr_probe_renderer(void){return "WebGL2";}
static void disconnect_damage(ZlRenderer *s){(void)s;}
uint64_t zglr_test_damage(int32_t *out){memset(out,0,4*sizeof(int32_t));return 0;}
/* The window's context, made at its first frame and made again once the
   page restores it after a loss. 0, 2 failed or lost, 5 the frame draws in
   memory (the page has no WebGL2). */
static int window_context(ZlRenderer *s,void *native_window){
    uint32_t id=(uint32_t)(uintptr_t)native_window;
    if(s->failed)return 5;
    if(s->backend==1&&s->web_window==id){
        uint32_t generation=0;
        if(zgl_current(id,&generation))return 2;
        if(generation==s->web_generation)return 0;
        /* Restored after a loss: the old objects are gone with it. */
        drop_objects(s);
        s->web_generation=generation;s->lost=0;
        if(!create_objects(s)){drop_objects(s);s->failed=1;return 5;}
        s->stats.device_creations++;s->stats.device_losses++;
        return 0;
    }
    if(!zgl_attach(id)){s->failed=1;return 5;}
    uint32_t generation=0;
    if(zgl_current(id,&generation))return 2;
    s->backend=1;s->web_window=id;s->web_generation=generation;
    if(!create_objects(s)){drop_objects(s);s->backend=0;s->failed=1;return 5;}
    s->stats.context_creations++;s->stats.device_creations++;
    return 0;
}
#else
/* Whether OpenGL contexts GDK makes draw on a GPU: asked once, with a
   context of a window of GDK's own that never shows, as a window drawing
   with OpenGL composites with it from its first context. 1 a GPU, 0 a
   software rasterizer, -1 no context. */
static int probe_result=-2;
static char probe_renderer[128];
int zglr_probe(void){
    if(probe_result!=-2)return probe_result;
    /* Before GTK opens its display, ask again later. */
    GdkScreen *screen=gdk_screen_get_default();if(!screen)return -1;
    probe_result=-1;
    GdkWindowAttr attributes={0};
    attributes.width=1;attributes.height=1;attributes.wclass=GDK_INPUT_OUTPUT;attributes.window_type=GDK_WINDOW_TOPLEVEL;
    GdkWindow *window=gdk_window_new(NULL,&attributes,0);if(!window)return probe_result;
    GError *error=NULL;GdkGLContext *context=gdk_window_create_gl_context(window,&error);
    if(context){
        gdk_gl_context_set_required_version(context,3,3);
        if(gdk_gl_context_realize(context,&error)&&!gdk_gl_context_get_use_es(context)){
            gdk_gl_context_make_current(context);
            const char *name=(const char *)glGetString(GL_RENDERER);
            snprintf(probe_renderer,sizeof(probe_renderer),"%s",name?name:"");
            probe_result=software_name(probe_renderer)?0:1;
            gdk_gl_context_clear_current();
        }
        g_object_unref(context);
    }
    if(error)g_error_free(error);
    gdk_window_destroy(window);
    return probe_result;
}
const char *zglr_probe_renderer(void){return probe_renderer;}

/* Wayland: GTK 3, compositing a window with OpenGL, passes what a paint
   changed to eglSwapBuffersWithDamageEXT unscaled and flipped with the
   window's unscaled height, where EGL takes buffer pixels; at a scale of 2
   or more the compositor learns of changes in the wrong place. The area
   GTK repaints (cairo's clip in the toplevel's draw signal) is added as
   wl_surface.damage, in surface coordinates, to the commit of the swap
   that follows. */
typedef void *(*WaylandSurfaceFn)(GdkWindow *);
typedef void (*MarshalFn)(void *,uint32_t,void *);
static WaylandSurfaceFn wayland_surface;static MarshalFn wayland_marshal;
static int32_t damage_test[4];static uint64_t damage_count;
static gboolean toplevel_draw(GtkWidget *widget,cairo_t *cr,gpointer data){
    ZlRenderer *s=data;
    if(gtk_widget_get_scale_factor(widget)<2)return FALSE;
    GdkWindow *window=gtk_widget_get_window(widget);void *surface=window?wayland_surface(window):NULL;
    if(!surface)return FALSE;
    double x0,y0,x1,y1;cairo_clip_extents(cr,&x0,&y0,&x1,&y1);
    int32_t r[4]={(int32_t)floor(x0),(int32_t)floor(y0),(int32_t)ceil(x1),(int32_t)ceil(y1)};
    if(r[2]<=r[0]||r[3]<=r[1])return FALSE;
    memcpy(damage_test,r,sizeof(r));damage_count++;s->stats.damage_submissions++;
    /* wl_argument is a union of 8 bytes; wl_surface.damage is request 2. */
    union {int32_t i;uint64_t pad;} args[4];memset(args,0,sizeof(args));
    args[0].i=r[0];args[1].i=r[1];args[2].i=r[2]-r[0];args[3].i=r[3]-r[1];
    wayland_marshal(surface,2,args);
    return FALSE;
}
static void connect_damage(ZlRenderer *s,GtkWidget *toplevel){
    if(s->damage_handler||!toplevel)return;
    GdkDisplay *display=gtk_widget_get_display(toplevel);
    if(!display||strcmp(G_OBJECT_TYPE_NAME(display),"GdkWaylandDisplay")!=0)return;
    if(!wayland_surface)wayland_surface=(WaylandSurfaceFn)dlsym(RTLD_DEFAULT,"gdk_wayland_window_get_wl_surface");
    if(!wayland_marshal){void *library=dlopen("libwayland-client.so.0",RTLD_NOW|RTLD_GLOBAL);if(library)wayland_marshal=(MarshalFn)dlsym(library,"wl_proxy_marshal_array");}
    if(!wayland_surface||!wayland_marshal)return;
    s->toplevel=toplevel;g_object_add_weak_pointer(G_OBJECT(toplevel),(gpointer *)&s->toplevel);
    s->damage_handler=g_signal_connect(toplevel,"draw",G_CALLBACK(toplevel_draw),s);
}
static void disconnect_damage(ZlRenderer *s){
    if(s->toplevel){
        if(s->damage_handler)g_signal_handler_disconnect(s->toplevel,s->damage_handler);
        g_object_remove_weak_pointer(G_OBJECT(s->toplevel),(gpointer *)&s->toplevel);
    }
    s->toplevel=NULL;s->damage_handler=0;
}
/* The damage last added on Wayland, for tests: 0 when none was. */
uint64_t zglr_test_damage(int32_t *out){memcpy(out,damage_test,sizeof(damage_test));return damage_count;}

static GtkWidget *area_of(GtkWidget *toplevel){
    if(!toplevel||!GTK_IS_BIN(toplevel))return NULL;
    return gtk_bin_get_child(GTK_BIN(toplevel));
}
/* The window's context, made at its first frame. 0, 1 no window, 2
   failed, 5 the frame draws in memory (no context, or a software
   rasterizer not allowed). */
static int window_context(ZlRenderer *s,GtkWidget *toplevel){
    if(s->backend==2)return 0;
    if(s->failed)return 5;
    GtkWidget *area=area_of(toplevel);
    GdkWindow *window=area?gtk_widget_get_window(area):NULL;
    if(!window)return 1;
    if(s->gdk&&s->gdk_window==window)return 0;
    if(!s->allow_software&&zglr_probe()!=1){s->failed=1;return 5;}
    GError *error=NULL;GdkGLContext *context=gdk_window_create_gl_context(window,&error);
    if(context){
        gdk_gl_context_set_required_version(context,3,3);
        if(!gdk_gl_context_realize(context,&error)||gdk_gl_context_get_use_es(context)){g_object_unref(context);context=NULL;}
    }
    if(error)g_error_free(error);
    if(!context){s->failed=1;return 5;}
    if(s->gdk){
        /* The area has a new window: what the old context held is gone. */
        if(current(s)==0)drop_objects(s);
        g_object_unref(s->gdk);s->gdk=NULL;
        if(s->gdk_window)g_object_remove_weak_pointer(G_OBJECT(s->gdk_window),(gpointer *)&s->gdk_window);
    }
    s->backend=1;s->gdk=context;s->gdk_window=window;g_object_add_weak_pointer(G_OBJECT(window),(gpointer *)&s->gdk_window);
    current(s);
    if(!create_objects(s)){drop_objects(s);g_object_unref(s->gdk);s->gdk=NULL;s->backend=0;s->failed=1;return 5;}
    if(s->software&&!s->allow_software){drop_objects(s);gdk_gl_context_clear_current();g_object_unref(s->gdk);s->gdk=NULL;s->backend=0;s->failed=1;return 5;}
    s->stats.context_creations++;s->stats.device_creations++;
    connect_damage(s,toplevel);
    return 0;
}
#endif
/* An offscreen renderer's own EGL context, made at its first use. */
static int own_context(ZlRenderer *s){
    if(s->backend)return current(s);
    EGLContext context=egl_create();if(context==EGL_NO_CONTEXT)return 1;
    s->backend=2;s->egl=context;s->owns_egl=1;
    if(!egl_current(context)||!create_objects(s)){drop_objects(s);egl_release();eglDestroyContext(egl_display,context);s->egl=EGL_NO_CONTEXT;s->backend=0;s->owns_egl=0;return 1;}
    s->stats.context_creations++;s->stats.device_creations++;
    return 0;
}
int zglr_software(void *p){return ((ZlRenderer *)p)->software;}

static void reset_frame(ZlRenderer *s){
    s->instance_len=0;s->batch_len=0;s->brush_len=0;s->clip_depth=0;s->run_len=0;s->capture_depth=0;s->partial=0;s->word_len=0;
    s->faded=1;s->fade_depth=0;
    s->clips[0][0]=0;s->clips[0][1]=0;s->clips[0][2]=(float)s->width;s->clips[0][3]=(float)s->height;
    /* Called with the context current: texts drawn for one frame and
       masks evicted during it go, capture targets wait for later frames. */
    for(uint32_t k=0;k<s->frame_target_len;k++){
        ZlTarget *t=&s->frame_targets[k];
        if(t->framebuffer&&s->free_target_len<ZL_FREE_TARGETS)s->free_targets[s->free_target_len++]=*t;
        else if(t->framebuffer)drop_target(t);
        else if(t->texture)glDeleteTextures(1,&t->texture);
    }
    s->frame_target_len=0;
}
#ifdef __wasm__
static void layout_for(ZlRenderer *s){(void)s;}
#else
static void layout_for(ZlRenderer *s){
    if(s->layout&&s->layout_scale==s->scale)return;
    if(s->layout)g_object_unref(s->layout);
    if(!s->font){
        s->font=pango_font_description_new();pango_font_description_set_family(s->font,"Sans");
        pango_font_description_set_absolute_size(s->font,16*PANGO_SCALE);
    }
    /* Laid out at the frame's scale, as the software renderer lays out. */
    cairo_surface_t *scratch=cairo_image_surface_create(CAIRO_FORMAT_ARGB32,1,1);cairo_t *cr=cairo_create(scratch);
    cairo_scale(cr,s->scale,s->scale);
    s->layout=pango_cairo_create_layout(cr);
    cairo_destroy(cr);cairo_surface_destroy(scratch);
    pango_layout_set_font_description(s->layout,s->font);
    pango_layout_set_single_paragraph_mode(s->layout,TRUE);pango_layout_set_ellipsize(s->layout,PANGO_ELLIPSIZE_END);
    pango_layout_set_height(s->layout,-1);
    s->layout_scale=s->scale;
}
#endif
static int start_frame(ZlRenderer *s,uint32_t width,uint32_t height,float scale,int transparent){
    s->width=width;s->height=height;s->scale=scale;s->transparent=transparent;
    reset_frame(s);s->frame_serial++;s->drawing=1;layout_for(s);
    return 0;
}
/* 0 drawing, 1 no window, 2 failed, 5 the frame draws in memory. */
int zglr_begin(void *p,void *native_window,uint32_t width,uint32_t height,float scale,int transparent){
    ZlRenderer *s=p;if(s->drawing||!width||!height)return 1;if(s->lost)return 2;
    int status=s->domain?0:window_context(s,native_window);if(status)return status;
    if(current(s))return 2;
    if(width>(uint32_t)s->max_texture||height>(uint32_t)s->max_texture){leave(s);return 2;}
    if(!s->back.texture||s->back.width!=width||s->back.height!=height){
        if(s->back.texture)s->stats.resizes++;
        drop_target(&s->back);
        if(!make_target(&s->back,width,height)){leave(s);return 2;}
        s->back_valid=0;s->generation++;
    }
    if(s->transparent!=transparent&&s->back_valid){s->back_valid=0;s->generation++;}
    s->offscreen=0;return start_frame(s,width,height,scale,transparent);
}
int zglr_begin_offscreen(void *p,uint32_t width,uint32_t height,float scale,int transparent){
    ZlRenderer *s=p;if(s->drawing||!width||!height)return 1;if(s->lost)return 2;
    if(s->domain?current(s):own_context(s))return 2;
    if(width>(uint32_t)s->max_texture||height>(uint32_t)s->max_texture){leave(s);return 2;}
    if(!s->offscreen_target.texture||s->offscreen_target.width!=width||s->offscreen_target.height!=height){
        drop_target(&s->offscreen_target);
        if(!make_target(&s->offscreen_target,width,height)){leave(s);return 2;}
        s->stats.offscreen_targets++;
    }
    s->offscreen=1;return start_frame(s,width,height,scale,transparent);
}
/* Whether the kept frame holds the last frame presented at this size. */
int zglr_plane(void *p,uint64_t *generation){ZlRenderer *s=p;*generation=s->generation;return s->drawing&&!s->offscreen&&s->back_valid;}
void zglr_set_partial(void *p,int partial){ZlRenderer *s=p;if(s->drawing&&!s->offscreen&&s->back_valid){s->partial=partial?1:0;if(partial)s->stats.partial_frames++;}}
float zglr_scale(void *p){return ((ZlRenderer *)p)->scale;}
void zglr_forget_plane(void *p){ZlRenderer *s=p;s->back_valid=0;s->generation++;}

static ZlInstance *push_with(ZlRenderer *s,GLuint texture,GLuint mask,int replace){
    if(s->instance_len==s->instance_capacity){
        uint32_t capacity=s->instance_capacity?s->instance_capacity*2:1024;
        ZlInstance *grown=realloc(s->instances,(size_t)capacity*sizeof(ZlInstance));if(!grown)return NULL;
        s->instances=grown;s->instance_capacity=capacity;
    }
    ZlBatch *last=s->batch_len?&s->batches[s->batch_len-1]:NULL;
    int textured=texture!=0;
    int joins=last&&last->op==OP_DRAW&&last->replace==replace&&last->opacity==s->faded&&((!textured&&!mask)||(last->textured&&last->texture==texture&&last->mask==mask)||(!last->textured&&!last->mask));
    if(joins){
        if(textured&&!last->textured){last->textured=1;last->texture=texture;last->mask=mask;}
        last->count++;
    }else{
        if(s->batch_len==s->batch_capacity){
            uint32_t capacity=s->batch_capacity?s->batch_capacity*2:64;
            ZlBatch *grown=realloc(s->batches,(size_t)capacity*sizeof(ZlBatch));if(!grown)return NULL;
            s->batches=grown;s->batch_capacity=capacity;
        }
        s->batches[s->batch_len++]=(ZlBatch){s->instance_len,1,OP_DRAW,0,texture,mask,textured,replace,s->faded};
    }
    ZlInstance *i=&s->instances[s->instance_len++];memset(i,0,sizeof(*i));
    memcpy(i->clip,s->clips[s->clip_depth],sizeof(i->clip));
    return i;
}
static ZlInstance *push(ZlRenderer *s,GLuint texture){return push_with(s,texture,0,0);}
static void device_rect(ZlRenderer *s,float *out,double x,double y,double width,double height){
    double k=s->scale;out[0]=(float)(x*k);out[1]=(float)(y*k);out[2]=(float)((x+width)*k);out[3]=(float)((y+height)*k);
}
static void rgba_color(float *out,uint32_t rgba){
    float a=(float)(rgba&255)/255.0f;
    out[0]=(float)(rgba>>24)/255.0f*a;out[1]=(float)((rgba>>16)&255)/255.0f*a;out[2]=(float)((rgba>>8)&255)/255.0f*a;out[3]=a;
}
static void rgb_color(float *out,uint32_t rgb){rgba_color(out,(rgb<<8)|255);}
static int visible(ZlRenderer *s){const float *c=s->clips[s->clip_depth];return c[2]>c[0]&&c[3]>c[1];}
void zglr_clear_box(void *p,int32_t x0,int32_t y0,int32_t x1,int32_t y1){
    ZlRenderer *s=p;if(!visible(s))return;
    ZlInstance *i=push_with(s,0,0,1);if(!i)return;
    i->rect[0]=(float)x0;i->rect[1]=(float)y0;i->rect[2]=(float)x1;i->rect[3]=(float)y1;i->params[2]=KIND_RECT;
}
void zglr_push_device_clip(void *p,int32_t x0,int32_t y0,int32_t x1,int32_t y1){
    ZlRenderer *s=p;if(s->clip_depth+1>=ZL_CLIPS)return;
    const float *b=s->clips[s->clip_depth];float *a=s->clips[++s->clip_depth];
    a[0]=fmaxf(b[0],(float)x0);a[1]=fmaxf(b[1],(float)y0);a[2]=fminf(b[2],(float)x1);a[3]=fminf(b[3],(float)y1);
}
void zglr_push_clip(void *p,float x,float y,float width,float height){
    ZlRenderer *s=p;if(s->clip_depth+1>=ZL_CLIPS)return;
    float r[4];device_rect(s,r,x,y,width,height);const float *b=s->clips[s->clip_depth];float *a=s->clips[++s->clip_depth];
    a[0]=fmaxf(b[0],r[0]);a[1]=fmaxf(b[1],r[1]);a[2]=fminf(b[2],r[2]);a[3]=fminf(b[3],r[3]);
}
void zglr_pop_clip(void *p){ZlRenderer *s=p;if(s->clip_depth)s->clip_depth--;}
/* Draw what follows at alpha (of 255) more, each drawing by itself, until
   zglr_pop_opacity (Command.push_opacity). */
void zglr_push_opacity(void *p,uint32_t alpha){
    ZlRenderer *s=p;if(s->fade_depth==ZL_CLIPS)return;
    s->fades[s->fade_depth++]=s->faded;s->faded*=(float)(alpha>255?255:alpha)/255.0f;
}
void zglr_pop_opacity(void *p){ZlRenderer *s=p;if(s->fade_depth)s->faded=s->fades[--s->fade_depth];}
static void narrow_clip(ZlRenderer *s,double x,double y,double width,double height,float *saved){
    float *c=s->clips[s->clip_depth];memcpy(saved,c,4*sizeof(float));
    float r[4];device_rect(s,r,x,y,width,height);
    c[0]=fmaxf(c[0],r[0]);c[1]=fmaxf(c[1],r[1]);c[2]=fminf(c[2],r[2]);c[3]=fminf(c[3],r[3]);
}
static void restore_clip(ZlRenderer *s,const float *saved){memcpy(s->clips[s->clip_depth],saved,4*sizeof(float));}

void zglr_fill(void *p,float x,float y,float width,float height,uint32_t rgb){
    ZlRenderer *s=p;if(!visible(s))return;
    ZlInstance *i=push(s,0);if(!i)return;
    device_rect(s,i->rect,x,y,width,height);rgb_color(i->color,rgb);i->params[2]=KIND_RECT;
}
static void normalize_rect(double *x,double *y,double *w,double *h){if(*w<0){*x+=*w;*w=-*w;}if(*h<0){*y+=*h;*h=-*h;}}
int zglr_shape(void *p,float x,float y,float width,float height,float radius,float stroke,uint32_t rgba){
    ZlRenderer *s=p;
    if(width==0||height==0||(rgba&255)==0||!visible(s))return 0;
    double dx=x,dy=y,dw=width,dh=height;normalize_rect(&dx,&dy,&dw,&dh);
    ZlInstance *i=push(s,0);if(!i)return 1;
    device_rect(s,i->rect,dx,dy,dw,dh);rgba_color(i->color,rgba);
    i->params[0]=(float)(fmin(radius,fmin(dw,dh)/2)*s->scale);i->params[1]=(float)(stroke*s->scale);i->params[2]=KIND_SHAPE;
    return 0;
}
/* A stop's premultiplied coordinates in the space its gradient mixes in
   (src/ui/gradient_color.zig): encoded sRGB, linear sRGB or Oklab. */
static double srgb_decode(double v){return v<=0.04045?v/12.92:pow((v+0.055)/1.055,2.4);}
static void stop_color(float *out,uint32_t rgba,uint32_t space){
    if(space==0){rgba_color(out,rgba);return;}
    double a=(double)(rgba&255)/255.0;
    if(a==0){out[0]=out[1]=out[2]=out[3]=0;return;}
    double c[3]={srgb_decode((double)(rgba>>24)/255.0),srgb_decode((double)((rgba>>16)&255)/255.0),srgb_decode((double)((rgba>>8)&255)/255.0)};
    if(space==2){
        double l=cbrt(0.4122214708*c[0]+0.5363325363*c[1]+0.0514459929*c[2]),m=cbrt(0.2119034982*c[0]+0.6806995451*c[1]+0.1073969566*c[2]),q=cbrt(0.0883024619*c[0]+0.2817188376*c[1]+0.6299787005*c[2]);
        c[0]=0.2104542553*l+0.7936177850*m-0.0040720468*q;c[1]=1.9779984951*l-2.4285922050*m+0.4505937099*q;c[2]=0.0259040371*l+0.7827717662*m-0.8086757660*q;
    }
    for(int k=0;k<3;k++)out[k]=(float)(c[k]*a);
    out[3]=(float)a;
}
/* spread: 0 pad, 1 repeat, 2 reflect; space: 0 sRGB, 1 linear sRGB, 2 Oklab. */
int zglr_gradient(void *p,float x,float y,float width,float height,float radius,float stroke,const ZgBrush *brush,uint32_t spread,uint32_t space){
    ZlRenderer *s=p;
    if(width==0||height==0||!visible(s))return 0;
    if(brush->len==0||brush->len>ZG_STOP_CAPACITY||s->brush_len==ZG_BRUSH_CAPACITY||space>2)return 1;
    ZlBrush *b=&s->brushes[s->brush_len];memset(b,0,sizeof(*b));
    b->head[0]=(float)brush->kind;b->head[1]=(float)spread;b->head[2]=(float)brush->len;b->head[3]=(float)space;
    b->ab[0]=brush->x0;b->ab[1]=brush->y0;b->ab[2]=brush->x1;b->ab[3]=brush->y1;
    for(uint32_t k=0;k<brush->len;k++){b->offsets[k]=brush->stops[k].offset;stop_color(b->colors[k],brush->stops[k].rgba,space);}
    double dx=x,dy=y,dw=width,dh=height;normalize_rect(&dx,&dy,&dw,&dh);
    ZlInstance *i=push(s,0);if(!i)return 1;
    device_rect(s,i->rect,dx,dy,dw,dh);i->color[3]=1;
    i->params[0]=(float)(fmin(radius,fmin(dw,dh)/2)*s->scale);i->params[1]=(float)(stroke*s->scale);i->params[2]=KIND_GRADIENT;i->params[3]=(float)s->brush_len;
    s->brush_len++;return 0;
}

/* Text. */
#ifdef __wasm__
/* The CSS font of a text command, as src/ui/web.c names it. */
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
/* Draws a text into box (bw x bh device pixels at bx0, by0) as src/ui/web.c
   draws it: the page lays out and draws the run, its baseline on a device
   pixel, and the run's pixels are cut to the box. */
static uint32_t *web_text(ZlRenderer *s,double bx0,double by0,uint32_t bw,uint32_t bh,float x,float y,float width,float height,const char *text,uint32_t length,uint32_t rgb,float size,uint16_t weight,int italic,int monospace,const char *family){
    double k=s->scale;
    uint32_t *box=calloc((size_t)bw*bh,4);if(!box)return NULL;
    if(!length)return box;
    char font[512];const size_t font_length=css_font(font,sizeof(font),family,size*(float)k,weight,italic,monospace);if(!font_length){free(box);return NULL;}
    const double pen_x=(double)x*k,fraction=pen_x-floor(pen_x);
    double info[6]={0};
    if(zw_text_draw(text,length,font,(uint32_t)font_length,(double)size*k,(double)width*k,fraction,rgb&0xffffff,info)){free(box);return NULL;}
    const uint32_t w=(uint32_t)info[0],h=(uint32_t)info[1];if(!w||!h)return box;
    uint32_t *run=malloc((size_t)w*h*4);if(!run){free(box);return NULL;}
    zw_text_copy(run);
    const double ascent=info[4],descent=info[5];
    const double baseline=round((double)y*k+((double)height*k-(ascent+descent))/2+ascent);
    const long left=(long)(floor(pen_x)+info[2]-bx0),top=(long)(baseline+info[3]-by0);
    /* Cut to the text's rectangle, as the clip of the software renderer. */
    const long cx0=(long)floor((double)x*k-bx0),cy0=(long)floor((double)y*k-by0),cx1=(long)ceil(((double)x+width)*k-bx0),cy1=(long)ceil(((double)y+height)*k-by0);
    for(uint32_t row=0;row<h;row++){
        long ty=top+(long)row;if(ty<0||ty>=(long)bh||ty<cy0||ty>=cy1)continue;
        for(uint32_t col=0;col<w;col++){
            long tx=left+(long)col;if(tx<0||tx>=(long)bw||tx<cx0||tx>=cx1)continue;
            box[(size_t)ty*bw+(size_t)tx]=run[(size_t)row*w+col];
        }
    }
    free(run);return box;
}
#else
static void use_font(ZlRenderer *s,const char *named,float size,uint16_t weight,int italic,int monospace){
    const char *family=named&&named[0]?named:monospace?"Monospace":"Sans";
    gint absolute=(gint)(size*PANGO_SCALE+0.5f);
    PangoStyle style=italic?PANGO_STYLE_ITALIC:PANGO_STYLE_NORMAL;
    const char *current_family=pango_font_description_get_family(s->font);
    if(current_family&&strcmp(current_family,family)==0&&pango_font_description_get_size(s->font)==absolute&&pango_font_description_get_size_is_absolute(s->font)&&
       pango_font_description_get_weight(s->font)==(PangoWeight)weight&&pango_font_description_get_style(s->font)==style)return;
    pango_font_description_set_family(s->font,family);pango_font_description_set_absolute_size(s->font,absolute);
    pango_font_description_set_weight(s->font,(PangoWeight)weight);pango_font_description_set_style(s->font,style);
    pango_layout_set_font_description(s->layout,s->font);
}
#endif
static uint64_t hash_bytes(uint64_t h,const void *data,size_t len){const uint8_t *b=data;for(size_t k=0;k<len;k++){h^=b[k];h*=1099511628211ull;}return h;}
static GLuint upload_bgra(const uint8_t *pixels,uint32_t width,uint32_t height,uint32_t stride){
    GLuint texture=0;glGenTextures(1,&texture);glBindTexture(GL_TEXTURE_2D,texture);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAX_LEVEL,0);
    glPixelStorei(GL_UNPACK_ALIGNMENT,4);glPixelStorei(GL_UNPACK_ROW_LENGTH,(GLint)(stride/4));
    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,(GLsizei)width,(GLsizei)height,0,GL_BGRA,GL_UNSIGNED_BYTE,pixels);
    glPixelStorei(GL_UNPACK_ROW_LENGTH,0);
    if(glGetError()!=GL_NO_ERROR){glDeleteTextures(1,&texture);return 0;}
    return texture;
}
/* Room for one more text, dropping those no frame drew for longest; the
   frame's own stay, which its batches draw. */
static ZlText *text_slot(ZlRenderer *s,size_t bytes){
    while(s->text_len&&(s->text_len==ZL_TEXT_ENTRIES||s->text_bytes+bytes>ZL_TEXT_BYTES)){
        uint32_t oldest=UINT32_MAX;
        for(uint32_t k=0;k<s->text_len;k++)if(s->texts[k].used!=s->frame_serial&&(oldest==UINT32_MAX||s->texts[k].used<s->texts[oldest].used))oldest=k;
        if(oldest==UINT32_MAX)break;
        drop_text(s,&s->texts[oldest]);s->texts[oldest]=s->texts[--s->text_len];memset(&s->texts[s->text_len],0,sizeof(ZlText));
    }
    if(s->text_len==ZL_TEXT_ENTRIES)return NULL;
    return &s->texts[s->text_len++];
}
int zglr_text(void *p,float x,float y,float width,float height,const char *text,uint32_t length,uint32_t rgb,float size,uint16_t weight,int italic,int monospace,const char *family){
    ZlRenderer *s=p;
#ifdef __wasm__
    if(!(width>=0)||width>INT_MAX/1024||length>INT_MAX||!(size>=1&&size<=1024))return 1;
#else
    if(!(width>=0)||width>G_MAXINT/PANGO_SCALE||length>G_MAXINT||!(size>=1&&size<=1024))return 1;
#endif
    if(!visible(s)||width<=0||height<=0)return 0;
    double k=s->scale;
    double bx0=floor((double)x*k),by0=floor((double)y*k),bx1=ceil(((double)x+width)*k),by1=ceil(((double)y+height)*k);
    /* A box larger than a texture draws only what the clip shows of it. */
    int whole=bx1-bx0<=4096&&by1-by0<=4096;
    if(!whole){
        const float *c=s->clips[s->clip_depth];
        bx0=fmax(bx0,floor(c[0]));by0=fmax(by0,floor(c[1]));bx1=fmin(bx1,ceil(c[2]));by1=fmin(by1,ceil(c[3]));
        if(bx1<=bx0||by1<=by0)return 0;
        if(bx1-bx0>ZL_TEXTURE_LIMIT||by1-by0>ZL_TEXTURE_LIMIT)return 1;
    }
    uint32_t bw=(uint32_t)(bx1-bx0),bh=(uint32_t)(by1-by0);
    float offset[2]={(float)((double)x*k-bx0),(float)((double)y*k-by0)};
    const char *named=family?family:"";
    uint64_t h=hash_bytes(1469598103934665603ull,text,length);
    h=hash_bytes(h,&rgb,4);h=hash_bytes(h,&size,4);h=hash_bytes(h,&weight,2);h=hash_bytes(h,&width,4);h=hash_bytes(h,&height,4);h=hash_bytes(h,offset,8);h=hash_bytes(h,named,strlen(named));
    ZlText *entry=NULL;
    if(whole)for(uint32_t n=0;n<s->text_len;n++){
        ZlText *t=&s->texts[n];
        if(t->hash==h&&t->len==length&&t->rgb==rgb&&t->size==size&&t->weight==weight&&t->italic==italic&&t->monospace==monospace&&t->box[0]==width&&t->box[1]==height&&
           t->offset[0]==offset[0]&&t->offset[1]==offset[1]&&t->scale==s->scale&&t->width==bw&&t->height==bh&&strncmp(t->family,named,sizeof(t->family))==0&&memcmp(t->bytes,text,length)==0){entry=t;break;}
    }
    if(entry)s->stats.text_hits++;
    else{
#ifdef __wasm__
        uint32_t *pixels=web_text(s,bx0,by0,bw,bh,x,y,width,height,text,length,rgb,size,weight,italic,monospace,family);
        if(!pixels)return 2;
        GLuint texture=upload_bgra((const uint8_t *)pixels,bw,bh,bw*4);
        free(pixels);
#else
        cairo_surface_t *surface=cairo_image_surface_create(CAIRO_FORMAT_ARGB32,(int)bw,(int)bh);
        if(cairo_surface_status(surface)!=CAIRO_STATUS_SUCCESS){cairo_surface_destroy(surface);return 2;}
        cairo_t *cr=cairo_create(surface);
        /* The software renderer's drawing, moved by whole device pixels. */
        cairo_translate(cr,-bx0,-by0);cairo_scale(cr,k,k);
        use_font(s,family,size,weight,italic,monospace);
        pango_layout_set_text(s->layout,text,(int)length);pango_layout_set_width(s->layout,(int)(width*PANGO_SCALE));
        int layout_width,layout_height;pango_layout_get_size(s->layout,&layout_width,&layout_height);
        cairo_rectangle(cr,x,y,width,height);cairo_clip(cr);
        cairo_set_source_rgb(cr,(double)((rgb>>16)&255)/255,(double)((rgb>>8)&255)/255,(double)(rgb&255)/255);
        cairo_move_to(cr,x,y+(height-(double)layout_height/PANGO_SCALE)/2);pango_cairo_show_layout(cr,s->layout);
        int failed=cairo_status(cr)!=CAIRO_STATUS_SUCCESS;
        cairo_destroy(cr);cairo_surface_flush(surface);
        GLuint texture=failed?0:upload_bgra(cairo_image_surface_get_data(surface),bw,bh,(uint32_t)cairo_image_surface_get_stride(surface));
        cairo_surface_destroy(surface);
#endif
        if(!texture)return 2;
        s->stats.text_rasters++;
        if(whole)entry=text_slot(s,(size_t)bw*bh*4);
        if(!entry){
            /* Kept for this frame only, as a capture target is. */
            if(s->frame_target_len==sizeof(s->frame_targets)/sizeof(s->frame_targets[0])){glDeleteTextures(1,&texture);return 2;}
            s->frame_targets[s->frame_target_len++]=(ZlTarget){texture,0,bw,bh};
            ZlInstance *i=push(s,texture);if(!i)return 2;
            i->rect[0]=(float)bx0;i->rect[1]=(float)by0;i->rect[2]=(float)bx1;i->rect[3]=(float)by1;i->params[2]=KIND_TEXT;i->color[3]=1;
            return 0;
        }
        entry->hash=h;entry->bytes=malloc(length?length:1);if(entry->bytes)memcpy(entry->bytes,text,length);entry->len=length;entry->rgb=rgb;entry->size=size;entry->weight=weight;entry->italic=italic;entry->monospace=monospace;
        entry->box[0]=width;entry->box[1]=height;entry->offset[0]=offset[0];entry->offset[1]=offset[1];entry->scale=s->scale;entry->width=bw;entry->height=bh;
        snprintf(entry->family,sizeof(entry->family),"%s",named);entry->texture=texture;s->text_bytes+=(size_t)bw*bh*4;
        s->stats.text_entries=s->text_len;
    }
    entry->used=s->frame_serial;
    ZlInstance *i=push(s,entry->texture);if(!i)return 2;
    i->rect[0]=(float)bx0;i->rect[1]=(float)by0;i->rect[2]=(float)bx1;i->rect[3]=(float)by1;i->params[2]=KIND_TEXT;i->color[3]=1;
    return 0;
}
/* Texts kept, and how many frames drew them from memory. */
void zglr_text_stats(void *p,uint32_t *entries,uint64_t *rasters,uint64_t *hits){ZlRenderer *s=p;*entries=s->text_len;*rasters=s->stats.text_rasters;*hits=s->stats.text_hits;}

/* Masks: coverage (A8) drawn in a color. */
static GLuint mask_texture(const ZgCoverage *coverage){
    GLuint texture=0;glGenTextures(1,&texture);glBindTexture(GL_TEXTURE_2D,texture);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAX_LEVEL,0);
    glPixelStorei(GL_UNPACK_ALIGNMENT,1);glPixelStorei(GL_UNPACK_ROW_LENGTH,(GLint)coverage->stride);
    glTexImage2D(GL_TEXTURE_2D,0,GL_R8,(GLsizei)coverage->width,(GLsizei)coverage->height,0,GL_RED,GL_UNSIGNED_BYTE,coverage->pixels);
    glPixelStorei(GL_UNPACK_ROW_LENGTH,0);glPixelStorei(GL_UNPACK_ALIGNMENT,4);
    if(glGetError()!=GL_NO_ERROR){glDeleteTextures(1,&texture);return 0;}
    return texture;
}
static int draw_mask(ZlRenderer *s,GLuint texture,uint32_t width,uint32_t height,double left,double top,uint32_t rgba){
    if(!visible(s)||(rgba&255)==0)return 0;
    ZlInstance *i=push(s,texture);if(!i)return 1;
    i->rect[0]=(float)left;i->rect[1]=(float)top;i->rect[2]=(float)(left+width);i->rect[3]=(float)(top+height);
    rgba_color(i->color,rgba);i->params[2]=KIND_MASK;i->uv[2]=1;i->uv[3]=1;
    return 0;
}
/* key is the prepared text's coverage, which names it while it lives. */
int zglr_prepared(void *p,void *key,const ZgCoverage *coverage,float x,float y,const float *clip,uint32_t rgba){
    ZlRenderer *s=p;GLuint texture=0;
    for(uint32_t k=0;k<s->prepared_len;k++)if(s->prepared_keys[k]==key){texture=s->prepared_textures[k];break;}
    if(!texture){
        texture=mask_texture(coverage);if(!texture)return 2;
        if(s->prepared_len==ZL_PREPARED){
            /* The oldest goes once this frame no longer draws it. */
            if(s->frame_target_len<sizeof(s->frame_targets)/sizeof(s->frame_targets[0]))s->frame_targets[s->frame_target_len++]=(ZlTarget){s->prepared_textures[0],0,0,0};
            else glDeleteTextures(1,&s->prepared_textures[0]);
            memmove(s->prepared_keys,s->prepared_keys+1,(ZL_PREPARED-1)*sizeof(void *));memmove(s->prepared_textures,s->prepared_textures+1,(ZL_PREPARED-1)*sizeof(GLuint));
            s->prepared_len--;
        }
        s->prepared_keys[s->prepared_len]=key;s->prepared_textures[s->prepared_len++]=texture;
    }
    float saved[4];
    if(clip)narrow_clip(s,(double)x+clip[0],(double)y+clip[1],clip[2],clip[3],saved);
    int result=draw_mask(s,texture,coverage->width,coverage->height,(double)x*s->scale+coverage->origin_x,(double)y*s->scale+coverage->origin_y,rgba);
    if(clip)restore_clip(s,saved);
    return result;
}
void zglr_forget_prepared(void *p){ZlRenderer *s=p;if(current(s)==0){for(uint32_t k=0;k<s->prepared_len;k++)glDeleteTextures(1,&s->prepared_textures[k]);}s->prepared_len=0;leave(s);}

/* Image and coverage slots. Uploads happen outside frames: each makes the
   context current itself. */
static int enter(ZlRenderer *s){
    if(s->lost||!s->backend)return 1;
    return current(s);
}
int zglr_reserve_images(void *p,uint32_t capacity){
    ZlRenderer *s=p;if(capacity<=s->slot_len)return 0;
    ZlImage *grown=realloc(s->slots,(size_t)capacity*sizeof(ZlImage));if(!grown)return 1;
    memset(grown+s->slot_len,0,(size_t)(capacity-s->slot_len)*sizeof(ZlImage));
    s->slots=grown;s->slot_len=capacity;return 0;
}
static GLuint image_texture(const ZiImageLevel *levels,uint32_t count){
    GLuint texture=0;glGenTextures(1,&texture);glBindTexture(GL_TEXTURE_2D,texture);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_BASE_LEVEL,0);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAX_LEVEL,(GLint)count-1);
    glPixelStorei(GL_UNPACK_ALIGNMENT,4);
    for(uint32_t k=0;k<count;k++){
        glPixelStorei(GL_UNPACK_ROW_LENGTH,(GLint)(levels[k].stride/4));
        glTexImage2D(GL_TEXTURE_2D,(GLint)k,GL_RGBA8,(GLsizei)levels[k].width,(GLsizei)levels[k].height,0,GL_BGRA,GL_UNSIGNED_BYTE,levels[k].pixels);
    }
    glPixelStorei(GL_UNPACK_ROW_LENGTH,0);
    if(glGetError()!=GL_NO_ERROR){glDeleteTextures(1,&texture);return 0;}
    return texture;
}
int zglr_prepare_image(void *p,const ZiImageLevel *levels,uint32_t count){
    ZlRenderer *s=p;if(s->candidate.texture||count==0||count>ZI_IMAGE_LEVELS)return 1;
    if(enter(s))return 2;
    if(levels[0].width>(uint32_t)s->max_texture||levels[0].height>(uint32_t)s->max_texture){leave(s);return 2;}
    GLuint texture=image_texture(levels,count);leave(s);
    if(!texture)return 2;
    s->candidate=(ZlImage){texture,levels[0].width,levels[0].height,count,0};return 0;
}
int zglr_prepare_coverage(void *p,const ZgCoverage *coverage){
    ZlRenderer *s=p;if(s->candidate.texture||!coverage->width||!coverage->height||coverage->stride<coverage->width)return 1;
    if(enter(s))return 2;
    GLuint texture=mask_texture(coverage);leave(s);
    if(!texture)return 2;
    s->candidate=(ZlImage){texture,coverage->width,coverage->height,1,1};return 0;
}
void zglr_commit_image(void *p,uint32_t slot){
    ZlRenderer *s=p;
    if(slot<s->slot_len&&s->candidate.texture){
        if(s->slots[slot].texture&&enter(s)==0){drop_image(&s->slots[slot]);leave(s);}
        s->slots[slot]=s->candidate;
    }else if(s->candidate.texture&&enter(s)==0){drop_image(&s->candidate);leave(s);}
    memset(&s->candidate,0,sizeof(s->candidate));
}
void zglr_release_image(void *p,uint32_t slot){
    ZlRenderer *s=p;if(slot>=s->slot_len||!s->slots[slot].texture)return;
    if(enter(s)==0){drop_image(&s->slots[slot]);leave(s);}else memset(&s->slots[slot],0,sizeof(ZlImage));
}
int zglr_update_image(void *p,uint32_t slot,const ZiImageLevel *levels,uint32_t count){
    ZlRenderer *s=p;if(slot>=s->slot_len||!s->slots[slot].texture||s->slots[slot].coverage||s->slots[slot].levels!=count)return 1;
    if(levels[0].width!=s->slots[slot].width||levels[0].height!=s->slots[slot].height)return 1;
    if(enter(s))return 2;
    glBindTexture(GL_TEXTURE_2D,s->slots[slot].texture);glPixelStorei(GL_UNPACK_ALIGNMENT,4);
    for(uint32_t k=0;k<count;k++){
        glPixelStorei(GL_UNPACK_ROW_LENGTH,(GLint)(levels[k].stride/4));
        glTexSubImage2D(GL_TEXTURE_2D,(GLint)k,0,0,(GLsizei)levels[k].width,(GLsizei)levels[k].height,GL_BGRA,GL_UNSIGNED_BYTE,levels[k].pixels);
    }
    glPixelStorei(GL_UNPACK_ROW_LENGTH,0);
    int failed=glGetError()!=GL_NO_ERROR;leave(s);
    return failed?2:0;
}
static ZlImage *slot_image(ZlRenderer *s,uint32_t slot){return slot<s->slot_len&&s->slots[slot].texture?&s->slots[slot]:NULL;}
int zglr_coverage(void *p,uint32_t slot,float x,float y,uint32_t rgba){
    ZlRenderer *s=p;ZlImage *image=slot_image(s,slot);if(!image||!image->coverage)return 1;
    return draw_mask(s,image->texture,image->width,image->height,(double)x*s->scale,(double)y*s->scale,rgba);
}
static int draw_image(ZlRenderer *s,const ZlImage *image,const ZiImagePlan *plan){
    if(!image||image->coverage||plan->level>=image->levels)return 1;
    const ZiImageRect *d=&plan->destination,*r=&plan->source;
    if(d->width<=0||d->height<=0||plan->opacity<=0||!visible(s))return 0;
    if(!(r->width>0&&r->height>0))return 1;
    double lw=(double)(image->width>>plan->level?image->width>>plan->level:1),lh=(double)(image->height>>plan->level?image->height>>plan->level:1);
    ZlInstance *i=push(s,image->texture);if(!i)return 1;
    device_rect(s,i->rect,d->x,d->y,d->width,d->height);
    float opacity=plan->opacity>1?1:plan->opacity;i->color[0]=i->color[1]=i->color[2]=i->color[3]=opacity;
    i->params[0]=(float)plan->level;i->params[2]=KIND_IMAGE;i->params[3]=plan->sampling?1:0;
    i->uv[0]=(float)(r->x/lw);i->uv[1]=(float)(r->y/lh);i->uv[2]=(float)((r->x+r->width)/lw);i->uv[3]=(float)((r->y+r->height)/lh);
    return 0;
}
int zglr_image(void *p,uint32_t slot,const ZiImagePlan *plan){ZlRenderer *s=p;return draw_image(s,slot_image(s,slot),plan);}

/* Captures: groups, Gaussian groups and raster transforms. */
static ZlBatch *push_op(ZlRenderer *s,uint32_t op,uint32_t run){
    if(s->batch_len==s->batch_capacity){
        uint32_t capacity=s->batch_capacity?s->batch_capacity*2:64;
        ZlBatch *grown=realloc(s->batches,(size_t)capacity*sizeof(ZlBatch));if(!grown)return NULL;
        s->batches=grown;s->batch_capacity=capacity;
    }
    ZlBatch *b=&s->batches[s->batch_len++];*b=(ZlBatch){s->instance_len,0,op,run,0,0,0,0,1};
    return b;
}
static ZlRun *new_run(ZlRenderer *s,uint32_t *index){
    if(s->run_len==s->run_capacity){
        uint32_t capacity=s->run_capacity?s->run_capacity*2:8;
        ZlRun *grown=realloc(s->runs,(size_t)capacity*sizeof(ZlRun));if(!grown)return NULL;
        s->runs=grown;s->run_capacity=capacity;
    }
    *index=s->run_len;ZlRun *run=&s->runs[s->run_len++];memset(run,0,sizeof(*run));return run;
}
/* A target for this frame, from those earlier frames left. */
static int frame_target(ZlRenderer *s,uint32_t width,uint32_t height,ZlTarget *out){
    if(s->frame_target_len==sizeof(s->frame_targets)/sizeof(s->frame_targets[0]))return 0;
    for(uint32_t k=0;k<s->free_target_len;k++)if(s->free_targets[k].width==width&&s->free_targets[k].height==height&&s->free_targets[k].framebuffer){
        *out=s->free_targets[k];s->free_targets[k]=s->free_targets[--s->free_target_len];
        s->frame_targets[s->frame_target_len++]=*out;return 1;
    }
    if(!make_target(out,width,height))return 0;
    s->frame_targets[s->frame_target_len++]=*out;return 1;
}
static int open_capture(ZlRenderer *s,uint32_t kind,uint64_t width,uint64_t height,double ox,double oy,const float clip[4],ZlCapture **out){
    if(!s->drawing||s->capture_depth==ZL_DEPTH)return 1;
    if(!width||!height||width>ZL_TEXTURE_LIMIT||height>ZL_TEXTURE_LIMIT||width>(uint64_t)s->max_texture||height>(uint64_t)s->max_texture)return 1;
    uint32_t index;ZlRun *run=new_run(s,&index);if(!run)return 2;
    run->kind=kind;
    if(!frame_target(s,(uint32_t)width,(uint32_t)height,&run->source))return 2;
    run->origin[0]=(float)ox;run->origin[1]=(float)oy;
    if(!push_op(s,OP_CAPTURE,index))return 2;
    ZlCapture *c=&s->captures[s->capture_depth++];
    memcpy(c->clips,s->clips,sizeof(c->clips));c->clip_depth=s->clip_depth;c->run=index;
    c->kind=kind;c->empty=0;c->opacity=255;c->mask=UINT32_MAX;
    /* Opacities opened outside fade the capture as one drawing. */
    c->faded=s->faded;c->fades=s->fade_depth;s->faded=1;
    s->clip_depth=0;memcpy(s->clips[0],clip,sizeof(s->clips[0]));
    *out=c;return 0;
}
static void keep_group(ZlRenderer *s,ZlCapture *c,const ZgLayerGroup *group){
    c->opacity=group->opacity>255?255:group->opacity;c->mask=group->mask_slot;
    if(group->mask_slot!=UINT32_MAX){
        ZlImage *mask=slot_image(s,group->mask_slot);
        double x=(double)group->mask_x*s->scale+group->mask_left,y=(double)group->mask_y*s->scale+group->mask_top;
        c->mask_rect[0]=(float)x;c->mask_rect[1]=(float)y;c->mask_rect[2]=(float)(x+(mask?mask->width:1));c->mask_rect[3]=(float)(y+(mask?mask->height:1));
    }
}
int zglr_begin_group(void *p,const ZgLayerGroup *group){
    ZlRenderer *s=p;if(!s->drawing)return 1;
    if(group->mask_slot!=UINT32_MAX){ZlImage *mask=slot_image(s,group->mask_slot);if(!mask||!mask->coverage)return 1;}
    float r[4];device_rect(s,r,group->x,group->y,group->width,group->height);
    const float *clip=s->clips[s->clip_depth];
    double b[4]={floor(fmax(r[0],clip[0])),floor(fmax(r[1],clip[1])),ceil(fmin(r[2],clip[2])),ceil(fmin(r[3],clip[3]))};
    int empty=!(b[2]>b[0]&&b[3]>b[1]);
    if(empty){b[2]=b[0]+1;b[3]=b[1]+1;}
    float inner[4]={(float)b[0],(float)b[1],(float)b[2],(float)b[3]};
    if(empty)inner[2]=inner[0],inner[3]=inner[1];
    ZlCapture *c;int status=open_capture(s,RUN_GROUP,(uint64_t)(b[2]-b[0]),(uint64_t)(b[3]-b[1]),b[0],b[1],inner,&c);if(status)return status;
    c->empty=empty;memcpy(c->bounds,r,sizeof(r));keep_group(s,c,group);
    return 0;
}
int zglr_begin_gaussian(void *p,const ZgLayerGroup *group,int32_t left,int32_t top,uint32_t width,uint32_t height,uint32_t radius,const uint32_t *weights){
    ZlRenderer *s=p;if(!s->drawing||radius>128)return 1;
    if(group->mask_slot!=UINT32_MAX){ZlImage *mask=slot_image(s,group->mask_slot);if(!mask||!mask->coverage)return 1;}
    const uint64_t pw=(uint64_t)width+2*(uint64_t)radius,ph=(uint64_t)height+2*(uint64_t)radius;
    const float clip[4]={(float)left,(float)top,(float)((double)left+width),(float)((double)top+height)};
    ZlCapture *c;int status=open_capture(s,RUN_GAUSSIAN,pw,ph,(double)left-radius,(double)top-radius,clip,&c);if(status)return status;
    ZlRun *run=&s->runs[c->run];run->radius=radius;memcpy(run->weights,weights,sizeof(run->weights));
    c->bounds[0]=(float)((double)left-radius);c->bounds[1]=(float)((double)top-radius);c->bounds[2]=(float)((double)left+width+radius);c->bounds[3]=(float)((double)top+height+radius);
    keep_group(s,c,group);
    return 0;
}
int zglr_end_group(void *p){
    ZlRenderer *s=p;if(!s->drawing||!s->capture_depth)return 1;
    ZlCapture *c=&s->captures[s->capture_depth-1];if(c->kind!=RUN_GROUP&&c->kind!=RUN_GAUSSIAN)return 1;
    s->capture_depth--;
    memcpy(s->clips,c->clips,sizeof(s->clips));s->clip_depth=c->clip_depth;s->faded=c->faded;s->fade_depth=c->fades;
    ZlRun *run=&s->runs[c->run];
    if(c->kind==RUN_GAUSSIAN){
        if(!frame_target(s,run->source.width,run->source.height,&run->temp)||!frame_target(s,run->source.width,run->source.height,&run->output))return 2;
    }
    if(!push_op(s,OP_CLOSE,c->run))return 2;
    s->stats.layers++;
    if(c->empty||!visible(s)||c->opacity==0)return 0;
    ZlImage *mask=c->mask==UINT32_MAX?NULL:slot_image(s,c->mask);
    if(c->mask!=UINT32_MAX&&!mask)return 1;
    ZlInstance *i=push_with(s,run->output.texture?run->output.texture:run->source.texture,mask?mask->texture:0,0);if(!i)return 2;
    memcpy(i->rect,c->bounds,sizeof(i->rect));
    float alpha=(float)c->opacity/255.0f;i->color[0]=i->color[1]=i->color[2]=i->color[3]=alpha;
    i->params[0]=run->origin[0];i->params[1]=run->origin[1];i->params[2]=KIND_LAYER;i->params[3]=mask?1:0;
    memcpy(i->uv,c->mask_rect,sizeof(i->uv));
    return 0;
}
int zglr_begin_transform(void *p,uint32_t pixel_width,uint32_t pixel_height,float source_width,float source_height){
    ZlRenderer *s=p;if(!s->drawing)return 1;
    const float clip[4]={0,0,(float)((double)source_width*s->scale),(float)((double)source_height*s->scale)};
    ZlCapture *c;return open_capture(s,RUN_TRANSFORM,(uint64_t)pixel_width+2,(uint64_t)pixel_height+2,-1,-1,clip,&c);
}
/* Samples the source back through inverse (local DIP of parent DIP: xx,
   yx, xy, yy, x0, y0) over bounds (device pixels of the parent). */
int zglr_end_transform(void *p,const double inverse[6],const float bounds[4]){
    ZlRenderer *s=p;if(!s->drawing||!s->capture_depth)return 1;
    ZlCapture *c=&s->captures[s->capture_depth-1];if(c->kind!=RUN_TRANSFORM)return 1;
    s->capture_depth--;
    memcpy(s->clips,c->clips,sizeof(s->clips));s->clip_depth=c->clip_depth;s->faded=c->faded;s->fade_depth=c->fades;
    ZlRun *run=&s->runs[c->run];
    if(!push_op(s,OP_CLOSE,c->run))return 2;
    s->stats.layers++;
    if(!visible(s)||!(bounds[2]>bounds[0]&&bounds[3]>bounds[1]))return 0;
    ZlInstance *i=push(s,run->source.texture);if(!i)return 2;
    memcpy(i->rect,bounds,sizeof(i->rect));
    i->uv[0]=(float)inverse[0];i->uv[1]=(float)inverse[2];i->uv[2]=(float)inverse[1];i->uv[3]=(float)inverse[3];
    i->params[0]=(float)(inverse[4]*s->scale+0.5);i->params[1]=(float)(inverse[5]*s->scale+0.5);i->params[2]=KIND_TRANSFORM;
    i->color[3]=1;
    return 0;
}

/* Shader effects. */
/* Link one program's fragment shader (src/ui/gpu_effect_host.zig, GLSL
   with rows bottom up, without #version) into slot. 0 installed, 1
   invalid, 2 the compiler rejects it, 3 failed. Needs the renderer's
   context: a window renderer has one once it drew a frame. */
int zglr_effect_install(void *p,uint32_t slot,const char *source,size_t len){
    ZlRenderer *s=p;if(slot>=ZL_EFFECT_SLOTS||!source||!len||s->drawing||!s->backend||s->lost)return 1;
    (void)len;
    if(current(s))return 3;
    int status=0;
    GLuint f=compile_two(GL_FRAGMENT_SHADER,"#version 330 core\n",source,1);
    if(!f){status=2;goto out;}
    GLuint program=glCreateProgram();glAttachShader(program,s->effect_vertex);glAttachShader(program,f);
    glBindFragDataLocation(program,0,"zs_out");glLinkProgram(program);glDeleteShader(f);
    GLint ok=0;glGetProgramiv(program,GL_LINK_STATUS,&ok);
    if(!ok){glDeleteProgram(program);status=2;goto out;}
    GLuint block=glGetUniformBlockIndex(program,"ZsWords");if(block!=GL_INVALID_INDEX)glUniformBlockBinding(program,block,0);
    block=glGetUniformBlockIndex(program,"ZsParams");if(block!=GL_INVALID_INDEX)glUniformBlockBinding(program,block,1);
    glUseProgram(program);glUniform1i(glGetUniformLocation(program,"zs_content"),0);glUseProgram(0);
    if(s->effects[slot].program)glDeleteProgram(s->effects[slot].program);
    s->effects[slot].program=program;s->effects[slot].frame=glGetUniformLocation(program,"zs_frame");
    if(glGetError()!=GL_NO_ERROR)status=3;
out:
    leave(s);return status;
}
int zglr_effect_installed(void *p,uint32_t slot){ZlRenderer *s=p;return slot<ZL_EFFECT_SLOTS&&s->effects[slot].program!=0;}
/* Whether effect programs can be installed now (the renderer has its
   context). */
int zglr_effect_ready(void *p){ZlRenderer *s=p;return s->backend!=0&&!s->lost&&s->effect_vertex!=0;}
/* Words appended to the frame's; their index, or UINT32_MAX. */
static uint32_t append_words(ZlRenderer *s,const void *data,size_t count){
    uint32_t start=s->word_len;uint64_t end=(uint64_t)start+count;
    if(end>UINT32_MAX/2)return UINT32_MAX;
    if(end>s->word_capacity){
        uint32_t capacity=s->word_capacity?s->word_capacity:1024;while(capacity<end)capacity*=2;
        uint32_t *grown=realloc(s->words,(size_t)capacity*4);if(!grown)return UINT32_MAX;
        s->words=grown;s->word_capacity=capacity;
    }
    if(count)memcpy(s->words+start,data,count*4);
    s->word_len=(uint32_t)end;return start;
}
static int keep_words(ZlRenderer *s,ZlRun *run,const ZlEffectPass *pass){
    if(pass->word_count>ZL_EFFECT_WORDS||(pass->word_count&&!pass->words))return 0;
    uint32_t at=append_words(s,pass->words,pass->word_count);if(at==UINT32_MAX)return 0;
    run->slot=pass->slot;run->word_offset=at;run->word_count=pass->word_count;run->params=pass->params;run->has_pass=1;
    return 1;
}
int zglr_effect_geometry(void *p,ZlEffectGeometry *out){
    ZlRenderer *s=p;if(!s->drawing)return 1;
    out->scale=s->scale;
    if(s->capture_depth){
        const ZlRun *run=&s->runs[s->captures[s->capture_depth-1].run];
        out->origin[0]=-run->origin[0];out->origin[1]=-run->origin[1];
        out->width=run->source.width;out->height=run->source.height;out->transparent=1;
    }else{out->origin[0]=out->origin[1]=0;out->width=s->width;out->height=s->height;out->transparent=s->transparent!=0;}
    const float *c=s->clips[s->clip_depth];
    double clip[4]={fmax(0,(double)c[0]+out->origin[0]),fmax(0,(double)c[1]+out->origin[1]),fmin(out->width,(double)c[2]+out->origin[0]),fmin(out->height,(double)c[3]+out->origin[1])};
    if(clip[2]<clip[0])clip[2]=clip[0];if(clip[3]<clip[1])clip[3]=clip[1];
    memcpy(out->clip,clip,sizeof(clip));return 0;
}
/* Begin an element effect's capture of width x height physical pixels at
   left, top with a transparent margin of radius around them: what follows
   draws into it, clipped to those pixels alone. 0, 1 too deep or not
   drawing, 2 failed. */
int zglr_begin_effect(void *p,int32_t left,int32_t top,uint32_t width,uint32_t height,uint32_t radius){
    ZlRenderer *s=p;
    const float clip[4]={(float)left,(float)top,(float)((double)left+width),(float)((double)top+height)};
    ZlCapture *c;
    return open_capture(s,RUN_EFFECT,(uint64_t)width+2*(uint64_t)radius,(uint64_t)height+2*(uint64_t)radius,(double)left-radius,(double)top-radius,clip,&c);
}
/* Close the innermost element effect: run pass over it (NULL composites
   the content as drawn) and composite the result at opacity under the
   clip the capture began in. */
int zglr_end_effect(void *p,const ZlEffectPass *pass,uint32_t opacity){
    ZlRenderer *s=p;if(!s->drawing||!s->capture_depth||s->captures[s->capture_depth-1].kind!=RUN_EFFECT)return 1;
    if(pass&&(pass->slot>=ZL_EFFECT_SLOTS||!s->effects[pass->slot].program))return 1;
    ZlCapture *c=&s->captures[--s->capture_depth];
    memcpy(s->clips,c->clips,sizeof(s->clips));s->clip_depth=c->clip_depth;s->faded=c->faded;s->fade_depth=c->fades;
    ZlRun *run=&s->runs[c->run];
    if(pass){
        if(!keep_words(s,run,pass))return 2;
        if(!frame_target(s,run->source.width,run->source.height,&run->output))return 2;
    }
    if(!push_op(s,OP_CLOSE,c->run))return 2;
    if(!visible(s)||opacity==0)return 0;
    ZlInstance *i=push(s,pass?run->output.texture:run->source.texture);if(!i)return 2;
    i->rect[0]=run->origin[0];i->rect[1]=run->origin[1];i->rect[2]=run->origin[0]+(float)run->source.width;i->rect[3]=run->origin[1]+(float)run->source.height;
    float alpha=(float)(opacity>255?255:opacity)/255.0f;i->color[0]=i->color[1]=i->color[2]=i->color[3]=alpha;
    i->params[0]=run->origin[0];i->params[1]=run->origin[1];i->params[2]=KIND_LAYER;i->params[3]=0;
    return 0;
}
static int region_fits(ZlRenderer *s,const uint32_t region[4],const uint32_t out[4]){
    ZlEffectGeometry geometry;zglr_effect_geometry(s,&geometry);
    return region[0]<=out[0]&&region[1]<=out[1]&&out[0]<out[2]&&out[1]<out[3]&&out[2]<=region[2]&&out[3]<=region[3]&&region[2]<=geometry.width&&region[3]<=geometry.height&&region[2]-region[0]<=ZL_TEXTURE_LIMIT&&region[3]-region[1]<=ZL_TEXTURE_LIMIT;
}
/* Run a backdrop shader over out (physical x0, y0, x1, y1 of the current
   target), reading the target as drawn so far across region, which
   contains out. */
int zglr_backdrop_shader(void *p,const ZlEffectPass *pass,const uint32_t region[4],const uint32_t out[4]){
    ZlRenderer *s=p;if(!s->drawing||pass->slot>=ZL_EFFECT_SLOTS||!s->effects[pass->slot].program)return 1;
    if(!region_fits(s,region,out))return 1;
    uint32_t index;ZlRun *run=new_run(s,&index);if(!run)return 2;
    run->kind=RUN_EFFECT;
    if(!keep_words(s,run,pass))return 2;
    /* The opacity the shader's result mixes in at (gpu_effect_host.zig). */
    run->params.d[2]=1-s->faded;
    memcpy(run->region,region,sizeof(run->region));memcpy(run->out,out,sizeof(run->out));
    if(!frame_target(s,region[2]-region[0],region[3]-region[1],&run->source))return 2;
    return push_op(s,OP_BACKDROP,index)?0:2;
}
/* A loading indicator (src/ui/loading.zig): count elements of 12 floats
   each, its view box at ox, oy (device pixels) scaled by k, drawn over
   device pixels x0, y0 to x1, y1 in rgb at opacity, under the clip. */
int zglr_indicator(void *p,const float *elements,uint32_t count,float ox,float oy,float k,const int32_t box[4],uint32_t rgb,float opacity){
    ZlRenderer *s=p;if(!s->drawing||count>64)return 1;
    if(!visible(s)||!count)return 0;
    uint32_t at=append_words(s,elements,(size_t)count*12);if(at==UINT32_MAX)return 2;
    ZlInstance *i=push(s,0);if(!i)return 2;
    i->rect[0]=(float)box[0];i->rect[1]=(float)box[1];i->rect[2]=(float)box[2];i->rect[3]=(float)box[3];
    i->color[0]=(float)(rgb>>16&255)/255.0f;i->color[1]=(float)(rgb>>8&255)/255.0f;i->color[2]=(float)(rgb&255)/255.0f;i->color[3]=opacity;
    i->params[0]=(float)at;i->params[1]=(float)count;i->params[2]=KIND_INDICATOR;
    i->uv[0]=ox;i->uv[1]=oy;i->uv[2]=k;
    s->stats.indicators++;return 0;
}
/* A backdrop effect over glass->out of the current target, reading it as
   drawn so far across glass->region: levels blur passes (one for a uniform
   blur, the progressive blur's levels otherwise), each a Gaussian of its
   radius whose 2 * radius + 1 weights start at weights[level.weights]. */
int zglr_backdrop(void *p,const ZlGlass *glass,uint32_t levels,const ZlGlassLevel *level,const float *weights,uint32_t weight_count){
    ZlRenderer *s=p;if(!s->drawing||levels>16)return 1;
    const uint32_t *region=glass->region,*out=glass->out;
    if(!region_fits(s,region,out))return 1;
    for(uint32_t k=0;k<levels;k++)if(level[k].radius>128||(uint64_t)level[k].weights+2*level[k].radius+1>weight_count)return 1;
    uint32_t index;ZlRun *run=new_run(s,&index);if(!run)return 2;
    run->kind=RUN_GAUSSIAN;
    /* The opacity it shades at (background.w). */
    ZlGlass faded=*glass;faded.background[3]=s->faded;
    run->word_offset=append_words(s,&faded,sizeof(faded)/4);if(run->word_offset==UINT32_MAX)return 2;
    ZlGlassLevel placed[16];
    for(uint32_t k=0;k<levels;k++){
        placed[k]=level[k];
        placed[k].weights=append_words(s,weights+level[k].weights,2*level[k].radius+1);if(placed[k].weights==UINT32_MAX)return 2;
    }
    run->level_offset=append_words(s,placed,levels*sizeof(ZlGlassLevel)/4);if(run->level_offset==UINT32_MAX)return 2;
    run->levels=levels;
    memcpy(run->region,region,sizeof(run->region));memcpy(run->out,out,sizeof(run->out));
    uint32_t w=region[2]-region[0],h=region[3]-region[1];
    if(!frame_target(s,w,h,&run->source))return 2;
    int kind=(int)glass->misc2[1],progressive=glass->misc2[3]!=0;
    if(kind!=3&&levels){
        if(!frame_target(s,w,h,&run->temp)||!frame_target(s,w,h,&run->extra[0]))return 2;
        if(progressive&&(!frame_target(s,w,h,&run->extra[1])||!frame_target(s,w,h,&run->extra[2])||!frame_target(s,w,h,&run->output)))return 2;
    }
    s->stats.backdrops++;
    return push_op(s,OP_GLASS,index)?0:2;
}

/* Drawing the frame. */
typedef struct ZlLevel {GLuint framebuffer;uint32_t width,height;float origin[2];int started;} ZlLevel;
static void open_level(ZlRenderer *s,ZlLevel *level,int root){
    glBindFramebuffer(GL_FRAMEBUFFER,level->framebuffer);glViewport(0,0,(GLsizei)level->width,(GLsizei)level->height);
    if(!level->started&&!(root&&s->partial)){
        /* An opaque frame starts white, as the software plane does;
           captures start transparent. */
        if(root&&!s->transparent)glClearColor(1,1,1,1);else glClearColor(0,0,0,0);
        glClear(GL_COLOR_BUFFER_BIT);
    }
    level->started=1;
    glUseProgram(s->main.program);
    glUniform4f(s->main.frame,(float)level->width,(float)level->height,level->origin[0],level->origin[1]);
}
static void filter_pass(ZlRenderer *s,const ZlRun *run,const ZlTarget *source,const ZlTarget *target,uint32_t vertical){
    glBindFramebuffer(GL_FRAMEBUFFER,target->framebuffer);glViewport(0,0,(GLsizei)target->width,(GLsizei)target->height);
    glDisable(GL_BLEND);
    glUseProgram(s->filter.program);
    glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,source->texture);glBindSampler(0,0);
    glUniform1i(s->filter.source,0);
    glUniform4ui(s->filter.header,source->width,source->height,run->radius,vertical);
    glUniform1uiv(s->filter.weights,257,run->weights);
    glDrawArrays(GL_TRIANGLE_STRIP,0,4);
    s->stats.filter_passes++;
}
/* Copies region of the level's target (device rows from its top) into
   target, which stores it bottom row first as the level does. */
static void copy_region(const ZlLevel *level,const uint32_t region[4],const ZlTarget *target){
    glBindFramebuffer(GL_READ_FRAMEBUFFER,level->framebuffer);
    glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,target->texture);
    glCopyTexSubImage2D(GL_TEXTURE_2D,0,0,0,(GLint)region[0],(GLint)(level->height-region[3]),(GLsizei)(region[2]-region[0]),(GLsizei)(region[3]-region[1]));
    glBindFramebuffer(GL_READ_FRAMEBUFFER,0);
}
/* Scissors device pixels out (x0, y0, x1, y1 from the top) of a target of
   height rows. */
static void scissor_out(const uint32_t out[4],uint32_t height){
    glEnable(GL_SCISSOR_TEST);glScissor((GLint)out[0],(GLint)(height-out[3]),(GLsizei)(out[2]-out[0]),(GLsizei)(out[3]-out[1]));
}
/* Run run's program into target (framebuffer of width x height), its
   fragment positions relative to device pixel origin, reading content. */
static int run_effect(ZlRenderer *s,const ZlRun *run,GLuint framebuffer,uint32_t width,uint32_t height,const float origin[2],GLuint content){
    const ZlEffect *e=&s->effects[run->slot];if(!e->program)return 2;
    glBindFramebuffer(GL_FRAMEBUFFER,framebuffer);glViewport(0,0,(GLsizei)width,(GLsizei)height);
    glDisable(GL_BLEND);
    glUseProgram(e->program);
    if(e->frame>=0)glUniform3f(e->frame,origin[0],origin[1],(float)height);
    uint32_t words[ZL_EFFECT_WORDS];uint32_t count=run->word_count;
    if(count)memcpy(words,s->words+run->word_offset,(size_t)count*4);
    uint32_t padded=(count+3)&~3u;if(!padded)padded=4;
    memset(words+count,0,(size_t)(padded-count)*4);
    glBindBuffer(GL_UNIFORM_BUFFER,s->effect_buffers[0]);glBufferSubData(GL_UNIFORM_BUFFER,0,(GLsizeiptr)padded*4,words);
    glBindBuffer(GL_UNIFORM_BUFFER,s->effect_buffers[1]);glBufferSubData(GL_UNIFORM_BUFFER,0,sizeof(run->params),&run->params);
    glBindBuffer(GL_UNIFORM_BUFFER,0);
    glBindBufferBase(GL_UNIFORM_BUFFER,0,s->effect_buffers[0]);glBindBufferBase(GL_UNIFORM_BUFFER,1,s->effect_buffers[1]);
    glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,content);glBindSampler(0,0);
    glDrawArrays(GL_TRIANGLES,0,3);
    s->stats.effect_passes++;
    return 0;
}
static void glass_target(const ZlTarget *target){
    glBindFramebuffer(GL_FRAMEBUFFER,target->framebuffer);glViewport(0,0,(GLsizei)target->width,(GLsizei)target->height);
}
static void glass_blur(ZlRenderer *s,const ZlGlassLevel *level,const ZlTarget *source,const ZlTarget *temp,const ZlTarget *target){
    const ZlGlassPrograms *g=&s->glass;
    glUseProgram(g->filter);glUniform1i(g->filter_source,0);
    glUniform1fv(g->filter_weights,(GLsizei)(2*level->radius+1),(const float *)(s->words+level->weights));
    for(uint32_t vertical=0;vertical<2;vertical++){
        glass_target(vertical?target:temp);
        glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,(vertical?temp:source)->texture);
        glUniform4ui(g->filter_header,level->radius,vertical,source->width,source->height);
        glDrawArrays(GL_TRIANGLE_STRIP,0,4);
        s->stats.filter_passes++;
    }
}
/* Runs a backdrop effect into the level: copy, blur (and blend), shade. */
static void encode_glass(ZlRenderer *s,const ZlRun *run,const ZlLevel *level){
    copy_region(level,run->region,&run->source);
    const ZlGlass *glass=(const ZlGlass *)(s->words+run->word_offset);
    const ZlGlassLevel *levels=(const ZlGlassLevel *)(s->words+run->level_offset);
    const ZlGlassPrograms *g=&s->glass;
    glDisable(GL_BLEND);glBindSampler(0,0);glBindSampler(1,0);
    const ZlTarget *result=&run->source;
    if(run->temp.texture){
        if(glass->misc2[3]!=0){
            /* Each level blurs the last further; the result leans toward it
               where the line asks for at least that level's blur. */
            const ZlTarget *cur=&run->source,*res=&run->source;
            const ZlTarget *blurs[2]={&run->extra[0],&run->extra[1]},*results[2]={&run->extra[2],&run->output};
            for(uint32_t k=0;k<run->levels;k++){
                const ZlTarget *next=cur==blurs[0]?blurs[1]:blurs[0];
                if(levels[k].radius){glass_blur(s,&levels[k],cur,&run->temp,next);cur=next;}
                const ZlTarget *blended=res==results[0]?results[1]:results[0];
                glass_target(blended);
                glUseProgram(g->blend);
                glUniform4fv(g->blend_glass,10,(const float *)glass);
                glUniform4uiv(g->blend_region,1,glass->region);glUniform4uiv(g->blend_out,1,glass->out);
                glUniform2f(g->blend_level,levels[k].lo,levels[k].hi);
                glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,res->texture);glUniform1i(g->blend_result,0);
                glActiveTexture(GL_TEXTURE1);glBindTexture(GL_TEXTURE_2D,cur->texture);glUniform1i(g->blend_current,1);
                glDrawArrays(GL_TRIANGLE_STRIP,0,4);
                res=blended;
            }
            result=res;
        }else if(run->levels&&levels[0].radius){
            glass_blur(s,&levels[0],&run->source,&run->temp,&run->extra[0]);
            result=&run->extra[0];
        }
    }
    glBindFramebuffer(GL_FRAMEBUFFER,level->framebuffer);glViewport(0,0,(GLsizei)level->width,(GLsizei)level->height);
    scissor_out(run->out,level->height);
    glUseProgram(g->shade);
    glUniform4fv(g->shade_glass,10,(const float *)glass);
    glUniform4uiv(g->shade_region,1,glass->region);glUniform4uiv(g->shade_out,1,glass->out);
    glUniform1f(g->shade_height,(float)level->height);
    glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,run->source.texture);glUniform1i(g->shade_dst,0);
    glActiveTexture(GL_TEXTURE1);glBindTexture(GL_TEXTURE_2D,result->texture);glUniform1i(g->shade_res,1);
    glDrawArrays(GL_TRIANGLE_STRIP,0,4);
    glDisable(GL_SCISSOR_TEST);
    s->stats.effect_passes++;
}
static int encode(ZlRenderer *s,GLuint target,uint32_t width,uint32_t height){
    if(s->capture_depth)return 2;
    if((uint64_t)s->instance_len*5>(uint64_t)s->max_texels||(uint64_t)s->brush_len*22>(uint64_t)s->max_texels)return 2;
    glBindBuffer(GL_TEXTURE_BUFFER,s->instance_buffer);
    glBufferData(GL_TEXTURE_BUFFER,(GLsizeiptr)((s->instance_len?s->instance_len:1)*sizeof(ZlInstance)),s->instance_len?s->instances:NULL,GL_STREAM_DRAW);
    glBindBuffer(GL_TEXTURE_BUFFER,s->brush_buffer);
    glBufferData(GL_TEXTURE_BUFFER,(GLsizeiptr)((s->brush_len?s->brush_len:1)*sizeof(ZlBrush)),s->brush_len?s->brushes:NULL,GL_STREAM_DRAW);
    glBindBuffer(GL_TEXTURE_BUFFER,s->words_buffer);
    glBufferData(GL_TEXTURE_BUFFER,(GLsizeiptr)((s->word_len?s->word_len:1)*4),s->word_len?s->words:NULL,GL_STREAM_DRAW);
    glBindBuffer(GL_TEXTURE_BUFFER,0);
    glBindVertexArray(s->vertex_array);
    glDisable(GL_DEPTH_TEST);glDisable(GL_SCISSOR_TEST);glDisable(GL_CULL_FACE);glDisable(GL_DITHER);
    glUseProgram(s->main.program);
    glActiveTexture(GL_TEXTURE3);glBindTexture(GL_TEXTURE_BUFFER,s->instance_texture);
    glActiveTexture(GL_TEXTURE4);glBindTexture(GL_TEXTURE_BUFFER,s->brush_texture);
    glActiveTexture(GL_TEXTURE5);glBindTexture(GL_TEXTURE_BUFFER,s->words_texture);
    glUniform1i(s->main_words,5);glUniform1f(s->main_opacity,1);
    glUniform1i(s->main.insts,3);glUniform1i(s->main.brushes,4);glUniform1i(s->main.tex,0);glUniform1i(s->main.mask,1);glUniform1i(s->main.tex_nearest,2);
    glUniform1f(s->main.scale,s->scale);
    glBlendFuncSeparate(GL_ONE,GL_ONE_MINUS_SRC_ALPHA,GL_ONE,GL_ONE_MINUS_SRC_ALPHA);glBlendEquation(GL_FUNC_ADD);
    ZlLevel levels[ZL_DEPTH+1];uint32_t depth=0;
    levels[0]=(ZlLevel){target,width,height,{0,0},0};
    int open=0;
    for(uint32_t k=0;k<s->batch_len;k++){
        const ZlBatch *b=&s->batches[k];
        switch(b->op){
        case OP_DRAW:{
            if(!open){open_level(s,&levels[depth],depth==0);open=1;}
            if(b->replace)glDisable(GL_BLEND);else glEnable(GL_BLEND);
            GLuint texture=b->texture?b->texture:s->blank;
            glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,texture);glBindSampler(0,s->linear_sampler);
            glActiveTexture(GL_TEXTURE2);glBindTexture(GL_TEXTURE_2D,texture);glBindSampler(2,s->nearest_sampler);
            glActiveTexture(GL_TEXTURE1);glBindTexture(GL_TEXTURE_2D,b->mask?b->mask:s->blank);glBindSampler(1,s->mask_sampler);
            glUniform1i(s->main.base,(GLint)b->first);glUniform1f(s->main_opacity,b->opacity);
            glDrawArraysInstanced(GL_TRIANGLE_STRIP,0,4,(GLsizei)b->count);
            break;
        }
        case OP_CAPTURE:{
            if(depth==ZL_DEPTH)return 2;
            const ZlRun *run=&s->runs[b->run];
            levels[++depth]=(ZlLevel){run->source.framebuffer,run->source.width,run->source.height,{run->origin[0],run->origin[1]},0};
            open=0;
            break;
        }
        case OP_CLOSE:{
            /* A capture nothing drew into is still cleared. */
            if(!open)open_level(s,&levels[depth],0);
            if(depth==0)return 2;
            const ZlRun *run=&s->runs[b->run];
            if(run->kind==RUN_GAUSSIAN){
                filter_pass(s,run,&run->source,&run->temp,0);filter_pass(s,run,&run->temp,&run->output,1);
                glUseProgram(s->main.program);
            }else if(run->kind==RUN_EFFECT&&run->has_pass){
                const float origin[2]={0,0};
                if(run_effect(s,run,run->output.framebuffer,run->output.width,run->output.height,origin,run->source.texture))return 2;
                glUseProgram(s->main.program);
            }
            depth--;open=0;
            break;
        }
        case OP_BACKDROP:{
            if(!open)open_level(s,&levels[depth],depth==0);
            const ZlRun *run=&s->runs[b->run];const ZlLevel *level=&levels[depth];
            copy_region(level,run->region,&run->source);
            scissor_out(run->out,level->height);
            const float origin[2]={(float)run->out[0],(float)run->out[1]};
            int failed=run_effect(s,run,level->framebuffer,level->width,level->height,origin,run->source.texture);
            glDisable(GL_SCISSOR_TEST);
            if(failed)return 2;
            open=0;
            break;
        }
        case OP_GLASS:{
            if(!open)open_level(s,&levels[depth],depth==0);
            encode_glass(s,&s->runs[b->run],&levels[depth]);
            open=0;
            break;
        }
        }
    }
    if(depth!=0)return 2;
    if(!open)open_level(s,&levels[0],1);
    for(int unit=0;unit<3;unit++)glBindSampler((GLuint)unit,0);
    glActiveTexture(GL_TEXTURE0);
    glDisable(GL_BLEND);glBindVertexArray(0);
    if(glGetError()!=GL_NO_ERROR)return 2;
    s->stats.frames++;s->stats.instances+=s->instance_len;s->stats.batches+=s->batch_len;
    return 0;
}
/* Rows of target from its bottom, as OpenGL reads them, into a top-down
   premultiplied BGRA copy of stride bytes per row. */
static void read_rows(const ZlTarget *target,uint8_t *pixels,size_t stride,uint32_t x,uint32_t y,uint32_t width,uint32_t height){
    glBindFramebuffer(GL_READ_FRAMEBUFFER,target->framebuffer);
    glPixelStorei(GL_PACK_ALIGNMENT,4);glPixelStorei(GL_PACK_ROW_LENGTH,(GLint)(stride/4));
    for(uint32_t row=0;row<height;row++){
        uint32_t device=y+row;
        glReadPixels((GLint)x,(GLint)(target->height-1-device),(GLsizei)width,1,GL_BGRA,GL_UNSIGNED_BYTE,pixels+(size_t)device*stride+(size_t)x*4);
    }
    glPixelStorei(GL_PACK_ROW_LENGTH,0);
    glBindFramebuffer(GL_READ_FRAMEBUFFER,0);
}
static void keep_capture(ZlRenderer *s,const ZlTarget *target){
    if(!s->capture)return;
    size_t bytes=(size_t)target->width*target->height*4;
    uint32_t *copy=realloc(s->captured,bytes);if(!copy)return;
    s->captured=copy;s->captured_width=target->width;s->captured_height=target->height;
    read_rows(target,(uint8_t *)copy,(size_t)target->width*4,0,0,target->width,target->height);
}
/* Shows the frame in the area's draw signal (cr): with GDK, as GtkGLArea
   shows its framebuffer; with a context of EGL, read back into memory and
   painted with cairo. 0 presented, 1 not drawing, 2 failed. */
#ifdef __wasm__
/* Shows the frame on the window's canvas: the kept framebuffer copied to
   the canvas's own, both bottom row first. */
int zglr_end(void *p,cairo_t *cr){
    (void)cr;ZlRenderer *s=p;if(!s->drawing||s->offscreen)return 1;
    s->drawing=0;
    int failed=encode(s,s->back.framebuffer,s->width,s->height);
    reset_frame(s);
    if(failed){s->back_valid=0;s->generation++;return 2;}
    s->back_valid=1;
    keep_capture(s,&s->back);
    glBindFramebuffer(GL_READ_FRAMEBUFFER,s->back.framebuffer);glBindFramebuffer(GL_DRAW_FRAMEBUFFER,0);
    glDisable(GL_SCISSOR_TEST);
    glBlitFramebuffer(0,0,(GLint)s->width,(GLint)s->height,0,0,(GLint)s->width,(GLint)s->height,GL_COLOR_BUFFER_BIT,GL_NEAREST);
    glBindFramebuffer(GL_FRAMEBUFFER,0);
    if(glGetError()!=GL_NO_ERROR)return 2;
    s->shown=1;s->stats.presents++;
    return 0;
}
#else
int zglr_end(void *p,cairo_t *cr){
    ZlRenderer *s=p;if(!s->drawing||s->offscreen)return 1;
    s->drawing=0;
    int failed=encode(s,s->back.framebuffer,s->width,s->height);
    reset_frame(s);
    if(failed){s->back_valid=0;s->generation++;leave(s);return 2;}
    s->back_valid=1;
    keep_capture(s,&s->back);
    if(!cr){leave(s);return 2;}
    s->shown=1;
    if(s->backend==1&&s->gdk_window){
        glFlush();
        cairo_save(cr);
        if(s->transparent){cairo_set_operator(cr,CAIRO_OPERATOR_CLEAR);cairo_paint(cr);}
        cairo_restore(cr);
        gdk_cairo_draw_from_gl(cr,s->gdk_window,(int)s->back.texture,GL_TEXTURE,(int)s->scale,0,0,(int)s->width,(int)s->height);
        s->stats.presents++;
        return cairo_status(cr)==CAIRO_STATUS_SUCCESS?0:2;
    }
    if(!s->memory||cairo_image_surface_get_width(s->memory)!=(int)s->width||cairo_image_surface_get_height(s->memory)!=(int)s->height){
        if(s->memory)cairo_surface_destroy(s->memory);
        s->memory=cairo_image_surface_create(CAIRO_FORMAT_ARGB32,(int)s->width,(int)s->height);
    }
    if(cairo_surface_status(s->memory)!=CAIRO_STATUS_SUCCESS){leave(s);return 2;}
    cairo_surface_flush(s->memory);
    read_rows(&s->back,cairo_image_surface_get_data(s->memory),(size_t)cairo_image_surface_get_stride(s->memory),0,0,s->width,s->height);
    cairo_surface_mark_dirty(s->memory);
    leave(s);
    cairo_save(cr);if(s->transparent)cairo_set_operator(cr,CAIRO_OPERATOR_SOURCE);
    cairo_scale(cr,1.0/s->scale,1.0/s->scale);cairo_set_source_surface(cr,s->memory,0,0);cairo_paint(cr);cairo_restore(cr);
    s->stats.presents++;s->stats.memory_presents++;
    return cairo_status(cr)==CAIRO_STATUS_SUCCESS?0:2;
}
#endif
/* Whether the window's context was restored after a loss since the
   renderer's objects were made: images it uploaded must be again. */
int zglr_restored(void *p){
#ifdef __wasm__
    ZlRenderer *s=p;if(s->backend!=1)return 0;
    uint32_t generation=0;if(zgl_current(s->web_window,&generation))return 0;
    return generation!=s->web_generation;
#else
    (void)p;return 0;
#endif
}
/* 0 drawn, 1 not drawing, 2 failed, 3 the device was lost. */
static void domain_lose(ZlDomain *d);
int zglr_end_offscreen(void *p,uint8_t *pixels,size_t stride){
    ZlRenderer *s=p;if(!s->drawing||!s->offscreen)return 1;
    s->drawing=0;
    if(s->lost){reset_frame(s);return 2;}
    int failed=encode(s,s->offscreen_target.framebuffer,s->width,s->height);
    reset_frame(s);
    if(s->loss_fault){s->loss_fault=0;leave(s);if(s->domain)domain_lose(s->domain);return 3;}
    if(failed){leave(s);return 2;}
    if(pixels)read_rows(&s->offscreen_target,pixels,stride,0,0,s->width,s->height);
    leave(s);
    return 0;
}
void zglr_abort(void *p){ZlRenderer *s=p;if(s->drawing){s->drawing=0;if(current(s)==0)reset_frame(s);else s->frame_target_len=0;leave(s);}}
void zglr_stats(void *p,ZlStats *out){*out=((ZlRenderer *)p)->stats;}

/* Device domains. A domain's renderers draw with its EGL context; its
   textures are uploaded once and drawn by any of them (zglr_texture).
   Losing the device (a test's injection) drops every texture and every
   renderer's objects at once and bumps the epoch's generation;
   zgpu_domain_recreate makes a new context, and each renderer makes its
   objects again in zglr_rebuild. Stop drops them for good. */
size_t zgpu_domain_size(void){return sizeof(ZlDomain);}
static int domain_create_device(ZlDomain *d){
    EGLContext context=egl_create();if(context==EGL_NO_CONTEXT)return 0;
    if(!egl_current(context)){eglDestroyContext(egl_display,context);return 0;}
#ifdef __wasm__
    d->software=0;
#else
    d->software=software_name((const char *)glGetString(GL_RENDERER));
#endif
    egl_release();
    /* A hardware domain takes a GPU; the software one takes any. */
    if(d->software&&!d->driver){
#ifdef __wasm__
        int forced=0;
#else
        const char *force=getenv("ZIGGURAT_GL");
        int forced=force&&(!g_ascii_strcasecmp(force,"1")||!g_ascii_strcasecmp(force,"on")||!g_ascii_strcasecmp(force,"true")||!g_ascii_strcasecmp(force,"yes"));
#endif
        if(!forced){eglDestroyContext(egl_display,context);return 0;}
    }
    d->context=context;d->device_creations++;return 1;
}
static void renderer_drop_device(ZlRenderer *s){
    if(s->lost)return;
    if(current(s)==0)drop_objects(s);
    s->lost=1;s->stats.device_losses++;s->drawing=0;
    reset_frame(s);s->frame_target_len=0;
    s->back_valid=0;s->generation++;
}
static void domain_drop_device(ZlDomain *d){
    if(d->context==EGL_NO_CONTEXT)return;
    if(egl_current(d->context)){for(unsigned i=0;i<ZI_IMAGE_SLOTS;i++)drop_image(&d->textures[i]);}
    else memset(d->textures,0,sizeof(d->textures));
    egl_release();
    eglDestroyContext(egl_display,d->context);d->context=EGL_NO_CONTEXT;
}
static void domain_lose(ZlDomain *d){
    if(!d||d->epoch->status!=1)return;
    d->epoch->status=2;
    if(d->epoch->generation==UINT64_MAX)d->epoch->status=4;else d->epoch->generation++;
    d->device_losses++;
    d->release_callback(d->callback_context,1);
    for(ZlRenderer *s=d->renderers;s;s=s->domain_next)renderer_drop_device(s);
    domain_drop_device(d);
    d->release_callback(d->callback_context,0);
}
void *zgpu_domain_create(GpuDomainEpoch *epoch,int driver,void *context,void (*callback)(void *,int),int32_t *out){
    ZlDomain *d=calloc(1,sizeof(*d));if(!d){*out=ZL_NO_MEMORY;return NULL;}
    d->epoch=epoch;d->driver=driver;d->callback_context=context;d->release_callback=callback;d->context=EGL_NO_CONTEXT;
    if(!domain_create_device(d)){free(d);*out=ZL_UNEXPECTED;return NULL;}
    live_objects++;epoch->status=1;*out=ZL_OK;return d;
}
void zgpu_domain_stop(void *p){
    ZlDomain *d=p;if(!d||d->epoch->status==3)return;
    d->epoch->status=3;
    d->release_callback(d->callback_context,1);
    for(ZlRenderer *s=d->renderers;s;s=s->domain_next)renderer_drop_device(s);
    domain_drop_device(d);
    d->release_callback(d->callback_context,0);
}
void zgpu_domain_destroy(void *p){
    if(!p)return;
    zgpu_domain_stop(p);
    ZlDomain *d=p;for(ZlRenderer *s=d->renderers;s;s=s->domain_next)s->domain=NULL;
    free(p);live_objects--;
}
int32_t zgpu_domain_recreate(void *p){
    ZlDomain *d=p;if(!d||d->epoch->status!=2)return ZL_UNEXPECTED;
    if(!domain_create_device(d))return ZL_DEVICE_REMOVED;
    d->epoch->status=1;return ZL_OK;
}
const GpuTextureToken *zgpu_domain_upload(void *p,uint32_t slot,uint64_t identity,const ZiImageLevel *levels,uint32_t count,uint32_t fault,int32_t *out){
    ZlDomain *d=p;
    if(!d||d->epoch->status!=1||slot>=ZI_IMAGE_SLOTS||d->tokens[slot].identity||!identity||!count||count>ZI_IMAGE_LEVELS||levels[0].width>ZL_TEXTURE_LIMIT||levels[0].height>ZL_TEXTURE_LIMIT){*out=ZL_INVALID;return NULL;}
    if(!egl_current(d->context)){*out=ZL_UNEXPECTED;return NULL;}
    GLuint texture=0;
    if(fault){
        /* A level's copy fails, for tests: nothing is kept. */
        egl_release();*out=ZL_NO_MEMORY;return NULL;
    }
    texture=image_texture(levels,count);
    egl_release();
    if(!texture){*out=ZL_NO_MEMORY;return NULL;}
    d->textures[slot]=(ZlImage){texture,levels[0].width,levels[0].height,count,0};d->texture_creations++;
    d->tokens[slot]=(GpuTextureToken){identity,d->epoch->generation,levels[0].width,levels[0].height,count,0};
    *out=ZL_OK;return &d->tokens[slot];
}
void zgpu_domain_release_texture(void *p,uint32_t slot){
    ZlDomain *d=p;if(!d||slot>=ZI_IMAGE_SLOTS)return;
    if(d->textures[slot].texture&&d->context!=EGL_NO_CONTEXT&&egl_current(d->context)){drop_image(&d->textures[slot]);egl_release();}
    memset(&d->textures[slot],0,sizeof(d->textures[slot]));memset(&d->tokens[slot],0,sizeof(d->tokens[slot]));
}
void zgpu_domain_stats(void *p,DomainStats *stats){
    memset(stats,0,sizeof(*stats));ZlDomain *d=p;if(!d)return;
    stats->objects=d->context!=EGL_NO_CONTEXT;
    for(unsigned i=0;i<ZI_IMAGE_SLOTS;i++)stats->objects+=d->textures[i].texture!=0;
    stats->devices=d->device_creations;stats->losses=d->device_losses;stats->bitmaps=d->texture_creations;
}
void zgpu_domain_inject_loss(void *p){domain_lose(p);}
/* A renderer drawing with the domain's context. */
void *zglr_create_in_domain(void *p,int *error){
    ZlDomain *d=p;if(!d||d->epoch->status!=1||d->context==EGL_NO_CONTEXT){*error=3;return NULL;}
    ZlRenderer *s=new_renderer();if(!s){*error=2;return NULL;}
    s->backend=2;s->domain=d;s->allow_software=1;
    if(!egl_current(d->context)||!create_objects(s)){drop_objects(s);egl_release();free(s);live_objects--;*error=2;return NULL;}
    egl_release();
    s->stats.device_creations=1;s->stats.context_creations=1;
    s->domain_next=d->renderers;d->renderers=s;*error=0;
    return s;
}
/* Makes the objects again in the domain's new context after a loss. 0
   ready, 1 no domain, 2 the domain has no device, 3 failed. */
int zglr_rebuild(void *p){
    ZlRenderer *s=p;ZlDomain *d=s->domain;if(!d)return 1;
    if(!s->lost)return 0;
    if(d->epoch->status!=1||d->context==EGL_NO_CONTEXT)return 2;
    if(!egl_current(d->context))return 3;
    int ok=create_objects(s);
    if(!ok)drop_objects(s);
    egl_release();
    if(!ok)return 3;
    s->lost=0;s->stats.device_creations++;return 0;
}
int zglr_texture(void *p,const GpuTextureToken *token,const ZiImagePlan *plan){
    ZlRenderer *s=p;ZlDomain *d=s->domain;
    if(!d||!s->drawing||d->epoch->status!=1||!token||!token->identity||token->generation!=d->epoch->generation)return 1;
    for(unsigned i=0;i<ZI_IMAGE_SLOTS;i++)if(&d->tokens[i]==token){
        if(plan->level>=token->levels)return 1;
        return draw_image(s,&d->textures[i],plan);
    }
    return 1;
}
void zglr_inject_loss(void *p){((ZlRenderer *)p)->loss_fault=1;}

/* Offscreen surfaces (src/ui/gpu_offscreen_native.zig): a frame drawn
   into the work target becomes the front, which snapshots copy. */
void zglr_offscreen_commit(void *p){
    ZlRenderer *s=p;ZlTarget work=s->front;s->front=s->offscreen_target;s->offscreen_target=work;
    if(!s->offscreen_target.texture&&s->front.texture&&enter(s)==0){
        if(make_target(&s->offscreen_target,s->front.width,s->front.height))s->stats.offscreen_targets++;
        leave(s);
    }
}
int zglr_offscreen_prepare(void *p,uint32_t width,uint32_t height){
    ZlRenderer *s=p;if(s->drawing||s->lost||!width||!height)return 1;
    if(enter(s))return 1;
    int ok=1;
    if(!s->offscreen_target.texture||s->offscreen_target.width!=width||s->offscreen_target.height!=height){
        drop_target(&s->offscreen_target);ok=make_target(&s->offscreen_target,width,height);if(ok)s->stats.offscreen_targets++;
    }
    if(ok&&(!s->front.texture||s->front.width!=width||s->front.height!=height)){
        drop_target(&s->front);ok=make_target(&s->front,width,height);if(ok)s->stats.offscreen_targets++;
    }
    leave(s);return ok?0:1;
}
uint32_t zglr_offscreen_objects(void *p){ZlRenderer *s=p;return (s->front.texture!=0)+(s->offscreen_target.texture!=0);}
int zglr_read_front(void *p,uint32_t *pixels,uint32_t width,uint32_t height){
    ZlRenderer *s=p;if(!s->front.texture||s->front.width!=width||s->front.height!=height)return 1;
    if(enter(s))return 1;
    read_rows(&s->front,(uint8_t *)pixels,(size_t)width*4,0,0,width,height);leave(s);
    return 0;
}
/* Copies the surface's front into a new texture in slot, top row first.
   fault: 1 fails before the texture is made, 2 after, 3 as a lost device. */
const GpuTextureToken *zgpu_snapshot_offscreen(void *domain,void *renderer,uint32_t slot,uint64_t identity,uint32_t width,uint32_t height,uint32_t fault,int32_t *out){
    ZlDomain *d=domain;ZlRenderer *s=renderer;*out=ZL_INVALID;
    if(!d||d->epoch->status!=1||!s||s->domain!=d||s->lost||s->drawing||!s->front.texture||s->front.width!=width||s->front.height!=height||slot>=ZI_IMAGE_SLOTS||d->tokens[slot].identity||!identity)return NULL;
    if(fault==1){*out=ZL_NO_MEMORY;return NULL;}
    if(fault==3){*out=ZL_DEVICE_REMOVED;domain_lose(d);return NULL;}
    if(!egl_current(d->context)){*out=ZL_UNEXPECTED;return NULL;}
    ZlTarget copy;
    if(!make_target(&copy,width,height)||fault==2){if(copy.texture)drop_target(&copy);egl_release();*out=ZL_NO_MEMORY;return NULL;}
    glBindFramebuffer(GL_READ_FRAMEBUFFER,s->front.framebuffer);glBindFramebuffer(GL_DRAW_FRAMEBUFFER,copy.framebuffer);
    glBlitFramebuffer(0,0,(GLint)width,(GLint)height,0,(GLint)height,(GLint)width,0,GL_COLOR_BUFFER_BIT,GL_NEAREST);
    glBindFramebuffer(GL_FRAMEBUFFER,0);
    GLuint texture=copy.texture;glDeleteFramebuffers(1,&copy.framebuffer);
    int failed=glGetError()!=GL_NO_ERROR;
    if(failed){glDeleteTextures(1,&texture);egl_release();*out=ZL_UNEXPECTED;return NULL;}
    egl_release();
    d->textures[slot]=(ZlImage){texture,width,height,1,0};d->texture_creations++;
    d->tokens[slot]=(GpuTextureToken){identity,d->epoch->generation,width,height,1,0};
    *out=ZL_OK;return &d->tokens[slot];
}

/* Test hooks. */
void zglr_test_capture(void *p,int enable){ZlRenderer *s=p;s->capture=enable;if(!enable){free(s->captured);s->captured=NULL;s->captured_width=s->captured_height=0;}}
uint32_t zglr_test_pixel(void *p,uint32_t x,uint32_t y){ZlRenderer *s=p;if(!s->captured||x>=s->captured_width||y>=s->captured_height)return 0;return s->captured[(size_t)y*s->captured_width+x];}
int zglr_test_pixels(void *p,uint32_t *out,uint32_t width,uint32_t height){
    ZlRenderer *s=p;if(!s->captured||width!=s->captured_width||height!=s->captured_height)return 0;
    memcpy(out,s->captured,(size_t)width*height*4);return 1;
}
/* The software renderer paints the next frame in the draw signal. */
int zglr_suspend(void *p){((ZlRenderer *)p)->shown=0;return 0;}
/* Whether the last frame the window showed was OpenGL's. */
int zglr_test_shown(void *p){return ((ZlRenderer *)p)->shown;}
/* Emits the draw signal of the window titled title's area now, into an
   image as large as it, as GTK would paint it. */
#ifdef __wasm__
void zglr_test_display(const char *title){(void)title;}
#else
void zglr_test_display(const char *title){
    GList *windows=gtk_window_list_toplevels();
    for(GList *l=windows;l;l=l->next){
        GtkWindow *window=l->data;const char *named=gtk_window_get_title(window);
        if(!named||strcmp(named,title)!=0)continue;
        GtkWidget *area=area_of(GTK_WIDGET(window));if(!area)break;
        int scale=gtk_widget_get_scale_factor(area);if(scale<1)scale=1;
        int width=gtk_widget_get_allocated_width(area),height=gtk_widget_get_allocated_height(area);
        if(width<1||height<1)break;
        cairo_surface_t *surface=cairo_image_surface_create(CAIRO_FORMAT_ARGB32,width*scale,height*scale);
        cairo_surface_set_device_scale(surface,scale,scale);
        cairo_t *cr=cairo_create(surface);gboolean handled=FALSE;
        g_signal_emit_by_name(area,"draw",cr,&handled);
        cairo_destroy(cr);cairo_surface_destroy(surface);
        break;
    }
    g_list_free(windows);
}
#endif
/* 1 GDK's context of the window, 2 EGL, 0 none yet. */
int zglr_test_backend(void *p){return ((ZlRenderer *)p)->backend;}
