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
   window's scale, each sampled from mip level 0 explicitly.

   Shader effects (src/ui/gpu_effect_host.zig) split the pass. An element
   effect draws its content into a capture texture of its own, runs the
   program over it into another and composites that at its opacity under
   the clip it began in; a backdrop shader copies the target beneath it and
   runs the program over that copy, writing every pixel it shades.

   Groups, Gaussian groups and raster transforms capture their content the
   same way, in a texture of their own for the frame, as the software
   planes do: a group's pixels (its bounds under the clip) composite at its
   opacity through its mask, a Gaussian group's capture is filtered first
   with the software renderer's integer kernel, and a transform's source
   (with a transparent guard texel around it) is sampled back through its
   inverse with the software renderer's bilinear taps, rounded to bytes.

   Gradients interpolated in linear sRGB or Oklab mix their stops in that
   space, premultiplied, and encode the result to sRGB as the CPU does.

   The window's frame is drawn into a texture the renderer keeps, then
   copied to the drawable, so that a frame may draw again only the device
   pixels that changed since the last one (src/ui/damage.zig). */
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
// MTLCommandBufferErrorDeviceRemoved (11) is deprecated in newer SDKs because it
// cannot occur on Apple Silicon; Intel Macs with removable GPUs can still report it.
#define ZM_MTL_ERROR_DEVICE_REMOVED ((NSInteger)11)
#include <CoreText/CoreText.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include "brushes.h"
#include "gpu_sweep.h"
#include "image_resource.h"
#include "coverage_resource.h"
#include "macos_font.h"
#include "layer_resource.h"

/* Layout shared with the shader below. */
typedef struct ZmInstance {float rect[4],clip[4],color[4],params[4],uv[4];} ZmInstance;
typedef struct ZmBrush {float head[4],ab[4],offsets[16],colors[16][4];} ZmBrush;
typedef struct ZmUniforms {float width,height,scale,pad,origin[2],pad2[2];} ZmUniforms;
/* An effect pass, as src/ui/gpu_effect_host.zig's Params lays it out. */
typedef struct ZmEffectParams {float a[4],b[4],shape[4],clip[4],c[4],d[4];uint32_t plane[4];} ZmEffectParams;
typedef struct ZmEffectPass {const uint32_t *words;uint32_t word_count,slot;ZmEffectParams params;} ZmEffectPass;
/* Where the current target's pixels are: physical pixel = DIP * scale +
   origin; the clip is physical and inside width x height. */
typedef struct ZmEffectGeometry {double clip[4];float scale,origin[2];uint32_t width,height,transparent;} ZmEffectGeometry;
_Static_assert(sizeof(ZmEffectParams)==112,"effect parameter layout");
/* A backdrop effect as src/ui/metal.zig plans it (src/ui/backdrop.zig):
   physical coordinates of the current target. misc is radius, refraction,
   bezel and noise; misc2 rim, kind (0 blur, 1 glass, 2 scroll edge, 3 the
   opaque fill), transparent and whether the blur is progressive; line and
   line2 the progressive blur's line (x, y, dx, dy; length, from, to). */
typedef struct ZmGlass {float box[4],clip[4],tone[4],tint[4],line[4],line2[4],misc[4],misc2[4],background[4],fill[4];uint32_t region[4],out[4];} ZmGlass;
typedef struct ZmGlassLevel {uint32_t radius;float lo,hi;uint32_t weights;} ZmGlassLevel;
_Static_assert(sizeof(ZmGlass)==192,"backdrop layout");
_Static_assert(sizeof(ZmInstance)==80,"instance layout");
_Static_assert(sizeof(ZmBrush)==352,"brush layout");

enum {KIND_RECT,KIND_SHAPE,KIND_GRADIENT,KIND_MASK,KIND_GLYPH,KIND_IMAGE,KIND_LAYER,KIND_TRANSFORM,KIND_INDICATOR};
enum {BIND_NONE,BIND_ATLAS,BIND_TEXTURE};

static NSString *const shader_source=@
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct Inst{float4 rect;float4 clip;float4 color;float4 p;float4 uv;};\n"
"struct Brush{float4 head;float4 ab;float4 offsets[4];float4 colors[16];};\n"
"struct Uniforms{float width;float height;float scale;float pad;float2 origin;float2 pad2;};\n"
"struct VOut{float4 pos[[position]];float2 uv;uint inst[[flat]];};\n"
"vertex VOut zm_vertex(uint vid[[vertex_id]],uint iid[[instance_id]],constant Uniforms&u[[buffer(0)]],const device Inst*insts[[buffer(1)]]){\n"
"  Inst i=insts[iid];uint kind=uint(i.p.z);\n"
"  float grow=(kind<=2u||kind==5u||kind==6u)?1.0:0.0;\n"
"  float4 q=float4(max(i.rect.xy-grow,floor(i.clip.xy)),min(i.rect.zw+grow,ceil(i.clip.zw)));\n"
"  q.zw=max(q.zw,q.xy);\n"
"  float2 corner=float2(float(vid&1u),float(vid>>1));\n"
"  float2 p=mix(q.xy,q.zw,corner);\n"
"  float2 d=p-u.origin;\n"
"  VOut o;o.pos=float4(d.x/u.width*2.0-1.0,1.0-d.y/u.height*2.0,0.0,1.0);\n"
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
"  float4 c;\n"
"  if(low==0u)c=b.colors[0];else if(low>=len)c=b.colors[len-1u];\n"
"  else{float o0=b.offsets[(low-1u)/4u][(low-1u)%4u];float o1=b.offsets[low/4u][low%4u];\n"
"    float w=o1>o0?(t-o0)/(o1-o0):0.0;c=mix(b.colors[low-1u],b.colors[low],w);}\n"
"  uint space=uint(b.head.w);if(space==0u||c.a<=0.0)return space==0u?c:float4(0.0);\n"
"  float3 u=c.rgb/c.a;\n"
"  if(space==2u){float l=u.x+0.3963377774*u.y+0.2158037573*u.z,m=u.x-0.1055613458*u.y-0.0638541728*u.z,q=u.x-0.0894841775*u.y-1.2914855480*u.z;\n"
"    l=l*l*l;m=m*m*m;q=q*q*q;u=float3(4.0767416621*l-3.3077115913*m+0.2309699292*q,-1.2684380046*l+2.6097574011*m-0.3413193965*q,-0.0041960863*l-0.7034186147*m+1.7076147010*q);}\n"
"  u=clamp(u,0.0,1.0);\n"
"  float3 e=select(1.055*powr(u,float3(1.0/2.4))-0.055,u*12.92,u<=0.0031308);e=select(e,float3(1.0),u==1.0);\n"
"  return float4(e*c.a,c.a);\n"
"}\n"
"static float4 texel(texture2d<float>t,int2 q){return (q.x>=0&&q.y>=0&&q.x<int(t.get_width())&&q.y<int(t.get_height()))?t.read(uint2(q)):float4(0.0);}\n"
"static float4 bilinear(texture2d<float>t,float2 s){\n"
"  if(s.x<=-1.0||s.y<=-1.0||s.x>=float(t.get_width())||s.y>=float(t.get_height()))return float4(0.0);\n"
"  float2 f=floor(s);float2 w=s-f;int2 q=int2(f);\n"
"  float4 sum=texel(t,q)*((1.0-w.x)*(1.0-w.y))+texel(t,q+int2(1,0))*(w.x*(1.0-w.y))+texel(t,q+int2(0,1))*((1.0-w.x)*w.y)+texel(t,q+int2(1,1))*(w.x*w.y);\n"
"  return round(clamp(sum*255.0,0.0,255.0))/255.0;\n"
"}\n"
"static float hyp(float x,float y){return precise::sqrt(x*x+y*y);}\n"
"static float2 rot(float x,float y,float a){float c=precise::cos(a),s=precise::sin(a);return float2(x*c+y*s,-x*s+y*c);}\n"
"static float rbox(float x,float y,float hw,float hh,float r){r=min(r,min(hw,hh));float qx=abs(x)-(hw-r),qy=abs(y)-(hh-r);float mx=max(qx,0.0),my=max(qy,0.0);return precise::sqrt(mx*mx+my*my)+min(max(qx,qy),0.0)-r;}\n"
"static float seg(float px,float py,float x0,float y0,float x1,float y1){float dx=x1-x0,dy=y1-y0,l=dx*dx+dy*dy;float h=l>0.0?clamp(((px-x0)*dx+(py-y0)*dy)/l,0.0,1.0):0.0;return hyp(px-x0-dx*h,py-y0-dy*h);}\n"
"static float turned(float start,float a){float t=(a-start)/(2.0*M_PI_F);return (t-floor(t))*(2.0*M_PI_F);}\n"
"static float2 element(const device float*e,float px,float py){\n"
"  uint k=uint(e[0]);\n"
"  if(k==0u)return float2(hyp(px-e[2],py-e[3])-e[4],1.0);\n"
"  if(k==1u)return float2(abs(hyp(px-e[2],py-e[3])-e[4])-e[5]*0.5,1.0);\n"
"  if(k==2u){float dx=px-e[2],dy=py-e[3];float ring=abs(hyp(dx,dy)-e[4])-e[5]*0.5;float off=turned(e[6],precise::atan2(dy,dx));float sw=min(e[7],2.0*M_PI_F);bool fade=e[9]>0.5;\n"
"    if(off<=sw)return float2(ring,fade?clamp(off/max(sw,1e-6),0.0,1.0):1.0);\n"
"    float best=1e30;for(int n=0;n<2;n++){float a=n==0?e[6]:e[6]+sw;float ex=e[2]+e[4]*precise::cos(a),ey=e[3]+e[4]*precise::sin(a);\n"
"      if(e[8]<0.5)best=min(best,hyp(px-ex,py-ey)-e[5]*0.5);else{float nx=precise::cos(a)*e[5]*0.5,ny=precise::sin(a)*e[5]*0.5;best=min(best,seg(px,py,ex-nx,ey-ny,ex+nx,ey+ny));}}\n"
"    return float2(best,fade?(off-sw<(2.0*M_PI_F-sw)*0.5?1.0:0.0):1.0);}\n"
"  if(k==3u){float2 q=rot(px-e[2],py-e[3],e[7]);return float2(rbox(q.x,q.y,e[4],e[5],e[6]),1.0);}\n"
"  if(k==4u){if(e[7]<0.5)return float2(seg(px,py,e[2],e[3],e[4],e[5])-e[6]*0.5,1.0);\n"
"    float dx=e[4]-e[2],dy=e[5]-e[3];float len=hyp(dx,dy);if(len==0.0)return float2(1e30,1.0);\n"
"    float2 q=rot(px-(e[2]+e[4])*0.5,py-(e[3]+e[5])*0.5,precise::atan2(dy,dx));return float2(rbox(q.x,q.y,len*0.5,e[6]*0.5,0.0),1.0);}\n"
"  if(k==5u){float2 q=rot(px-e[2],py-e[3],e[7]);float ry=max(abs(e[5]),0.2);float qx=q.x/e[4],qy=q.y/ry;float n=hyp(qx,qy);\n"
"    if(n==0.0)return float2(min(e[4],ry)-e[6]*0.5,1.0);return float2(abs((n-1.0)/hyp(qx/(e[4]*n),qy/(ry*n)))-e[6]*0.5,1.0);}\n"
"  float dx=px-e[2],dy=py-e[3];float behind=turned(precise::atan2(dy,dx),e[5]);return float2(hyp(dx,dy)-e[4],behind<=e[6]?1.0-behind/e[6]:0.0);\n"
"}\n"
"static float4 zm_shade(VOut in,constant Uniforms&u,const device Inst*insts,const device Brush*brushes,const device float*words,texture2d<float>tex,texture2d<float>mask,sampler linear_sampler,sampler nearest_sampler,sampler mask_sampler){\n"
"  Inst i=insts[in.inst];float2 p=in.pos.xy+u.origin;uint kind=uint(i.p.z);\n"
"  float cov=box(p,i.clip);float4 color=i.color;\n"
"  if(kind==0u)cov*=box(p,i.rect);\n"
"  else if(kind==1u)cov*=shape(p,i);\n"
"  else if(kind==2u){cov*=shape(p,i);color=gradient(brushes[uint(i.p.w)],p/u.scale);}\n"
"  else if(kind==3u)cov*=tex.sample(linear_sampler,in.uv,level(0.0)).r;\n"
"  else if(kind==4u){float4 t=tex.sample(nearest_sampler,in.uv,level(0.0));if(i.p.w>0.5)return t*(color.a*cov);cov*=t.a;}\n"
"  else if(kind==6u){float m=1.0;if(i.p.w>0.5)m=mask.sample(mask_sampler,(p-i.uv.xy)/(i.uv.zw-i.uv.xy),level(0.0)).r;return texel(tex,int2(floor(p-i.p.xy)))*(color.a*cov*box(p,i.rect)*m);}\n"
"  else if(kind==7u){float2 s=float2(i.uv.x*p.x+i.uv.y*p.y+i.p.x,i.uv.z*p.x+i.uv.w*p.y+i.p.y);return bilinear(tex,s)*cov;}\n"
"  else if(kind==8u){const device float*e=words+uint(i.p.x);uint n=uint(i.p.y);float k=i.uv.z;float px=(p.x-i.uv.x)/k,py=(p.y-i.uv.y)/k;float aa=1.0/k;float total=0.0;\n"
"    for(uint j=0u;j<n;j++){float2 v=element(e+j*12u,px,py);float a=clamp(0.5-v.x/aa,0.0,1.0)*e[j*12u+1u]*v.y;total=a+total*(1.0-a);}\n"
"    float alpha=round(clamp(total*i.color.a*cov,0.0,1.0)*255.0);if(alpha==0.0)return float4(0.0);\n"
"    return float4(floor((round(i.color.rgb*255.0)*alpha+127.0)/255.0),alpha)/255.0;}\n"
"  else{float lod=i.p.x;float4 t=i.p.w>0.5?tex.sample(linear_sampler,in.uv,level(lod)):tex.sample(nearest_sampler,in.uv,level(lod));return t*(color.a*cov*box(p,i.rect));}\n"
"  return color*cov;\n"
"}\n"
/* Each drawing at the opacity of its batch (Uniforms.pad), as if it
   multiplied its colors (Command.push_opacity). */
"fragment float4 zm_fragment(VOut in[[stage_in]],constant Uniforms&u[[buffer(0)]],const device Inst*insts[[buffer(1)]],const device Brush*brushes[[buffer(2)]],const device float*words[[buffer(3)]],texture2d<float>tex[[texture(0)]],texture2d<float>mask[[texture(1)]],sampler linear_sampler[[sampler(0)]],sampler nearest_sampler[[sampler(1)]],sampler mask_sampler[[sampler(2)]]){\n"
"  return zm_shade(in,u,insts,brushes,words,tex,mask,linear_sampler,nearest_sampler,mask_sampler)*u.pad;\n"
"}\n"
"struct Filter{uint width;uint height;uint radius;uint vertical;uint weights[257];};\n"
"vertex float4 zm_full_vertex(uint vid[[vertex_id]]){float2 c=float2(float(vid&1u),float(vid>>1));return float4(c.x*2.0-1.0,1.0-c.y*2.0,0.0,1.0);}\n"
"fragment float4 zm_filter(float4 pos[[position]],constant Filter&f[[buffer(0)]],constant uint4&pass[[buffer(1)]],texture2d<float>src[[texture(0)]]){\n"
"  int2 at=int2(pos.xy);uint4 total=uint4(0);int r=int(f.radius);\n"
"  for(int tap=-r;tap<=r;tap++){\n"
"    int2 q=at+(pass.w!=0u?int2(0,tap):int2(tap,0));\n"
"    if(q.x>=0&&q.y>=0&&q.x<int(f.width)&&q.y<int(f.height))total+=uint4(round(src.read(uint2(q))*255.0))*f.weights[tap+r];\n"
"  }\n"
"  return float4((total+8388608u)>>24)/255.0;\n"
"}\n"
/* Backdrop effects (src/ui/backdrop.zig): the target beneath the effect is
   copied (region), blurred with the CPU's float kernel, rounded to bytes
   each pass, blended level by level for a progressive blur, and shaded
   inside the rounded box over out, as the software planes do. */
"struct Glass{float4 box;float4 clip;float4 tone;float4 tint;float4 line;float4 line2;float4 misc;float4 misc2;float4 background;float4 fill;uint4 region;uint4 out;};\n"
"vertex float4 zm_quad_vertex(uint vid[[vertex_id]],constant float4&q[[buffer(0)]]){float2 c=float2(float(vid&1u),float(vid>>1));return float4(mix(q.x,q.z,c.x),mix(q.y,q.w,c.y),0.0,1.0);}\n"
"fragment float4 zm_glass_filter(float4 pos[[position]],constant uint4&f[[buffer(0)]],const device float*w[[buffer(1)]],texture2d<float>src[[texture(0)]]){\n"
"  int2 at=int2(pos.xy);int r=int(f.x);float4 acc=float4(0.0);int2 hi=int2(f.zw)-1;\n"
"  for(int tap=-r;tap<=r;tap++){int2 q=clamp(at+(f.y!=0u?int2(0,tap):int2(tap,0)),int2(0),hi);acc+=round(src.read(uint2(q))*255.0)*w[tap+r];}\n"
"  return round(clamp(acc,0.0,255.0))/255.0;\n"
"}\n"
"static float4 blend_bytes(float4 a,float4 b,float t){return t>=1.0?b:round(clamp(a+(b-a)*t,0.0,255.0));}\n"
"static float blur_at(constant Glass&g,float px,float py){float d=(px-g.line.x)*g.line.z+(py-g.line.y)*g.line.w;float t=g.line2.x>0.0?clamp(d/g.line2.x,0.0,1.0):(d>=0.0?1.0:0.0);return g.line2.y+(g.line2.z-g.line2.y)*t;}\n"
"fragment float4 zm_glass_blend(float4 pos[[position]],constant Glass&g[[buffer(0)]],constant float2&level[[buffer(1)]],texture2d<float>result[[texture(0)]],texture2d<float>cur[[texture(1)]]){\n"
"  uint2 at=uint2(pos.xy);float4 a=round(result.read(at)*255.0);uint x=g.region.x+at.x,y=g.region.y+at.y;\n"
"  if(x<g.out.x||y<g.out.y||x>=g.out.z||y>=g.out.w)return a/255.0;\n"
"  float weight=clamp((blur_at(g,float(x)+0.5,float(y)+0.5)-level.x)/(level.y-level.x),0.0,1.0);\n"
"  if(weight==0.0)return a/255.0;\n"
"  return blend_bytes(a,round(cur.read(at)*255.0),weight)/255.0;\n"
"}\n"
"static float rounded_distance(float4 b,float radius,float x,float y){float hx=(b.z-b.x)*0.5,hy=(b.w-b.y)*0.5;float qx=abs(x-(b.x+hx))-(hx-radius),qy=abs(y-(b.y+hy))-(hy-radius);float ox=max(qx,0.0),oy=max(qy,0.0);return precise::sqrt(ox*ox+oy*oy)+min(max(qx,qy),0.0)-radius;}\n"
"static float3 straight(float4 c){if(c.a==0.0)return float3(0.0);return min(float3(1.0),c.rgb/c.a);}\n"
"static float luma(float3 c){return 0.2126*c.r+0.7152*c.g+0.0722*c.b;}\n"
"static float3 toned(float3 c,float saturation,float offset){float l=luma(c);return clamp(l+(c-l)*saturation+offset,0.0,1.0);}\n"
"static float4 pack(float3 c){return float4(round(clamp(c,0.0,1.0)*255.0),255.0);}\n"
"static float lens(float t,float bezel){if(bezel<=0.0||t>=bezel)return 0.0;float u=1.0-max(t,0.0)/bezel;float v=1.0-u*u*u*u;float a=precise::sqrt(v*precise::sqrt(v));float b=u*u*u;float n=precise::sqrt(a*a+b*b);float s=b/n,c=a/n;float st=s/1.5;float ct=precise::sqrt(1.0-st*st);return ((s*ct-c*st)/(c*ct+s*st))/1.1180339887498949;}\n"
"static float sgn(float v){return v>0.0?1.0:(v<0.0?-1.0:0.0);}\n"
"static float2 edge_normal(float4 b,float radius,float px,float py){float hx=(b.z-b.x)*0.5,hy=(b.w-b.y)*0.5;float cx=px-b.x-hx,cy=py-b.y-hy;float rad=min(1.5*radius,min(hx,hy));float qx=abs(cx)-(hx-rad),qy=abs(cy)-(hy-rad);\n"
"  if(qx>0.0||qy>0.0){float mx=max(qx,0.0),my=max(qy,0.0);float n=precise::sqrt(mx*mx+my*my);return float2(sgn(cx)*mx/n,sgn(cy)*my/n);}\n"
"  return qx>qy?float2(sgn(cx),0.0):float2(0.0,sgn(cy));}\n"
"static float4 bilinear_clamped(texture2d<float>t,float2 origin,float x,float y){float w=float(t.get_width()),h=float(t.get_height());\n"
"  float lx=clamp(x-0.5-origin.x,0.0,w-1.0),ly=clamp(y-0.5-origin.y,0.0,h-1.0);uint ix=uint(floor(lx)),iy=uint(floor(ly));uint jx=min(ix+1u,uint(w)-1u),jy=min(iy+1u,uint(h)-1u);float tx=lx-floor(lx),ty=ly-floor(ly);\n"
"  float4 a=round(t.read(uint2(ix,iy))*255.0),b=round(t.read(uint2(jx,iy))*255.0),c=round(t.read(uint2(ix,jy))*255.0),d=round(t.read(uint2(jx,jy))*255.0);\n"
"  return (a*(1.0-tx)+b*tx)*(1.0-ty)+(c*(1.0-tx)+d*tx)*ty;}\n"
"static float grain(uint x,uint y){uint v=x*73856093u^y*19349663u;v^=v>>16;v*=0x7feb352du;v^=v>>15;v*=0x846ca68bu;v^=v>>16;return float(v)/4294967296.0;}\n"
"fragment float4 zm_glass_shade(float4 pos[[position]],constant Glass&g[[buffer(0)]],texture2d<float>dst[[texture(0)]],texture2d<float>res[[texture(1)]]){\n"
"  uint2 xy=uint2(pos.xy);uint2 local=xy-g.region.xy;float px=float(xy.x)+0.5,py=float(xy.y)+0.5;float4 d=round(dst.read(local)*255.0);\n"
"  float radius=g.misc.x;float sd=rounded_distance(g.box,radius,px,py);\n"
"  float fx=float(xy.x),fy=float(xy.y);float cover=max(0.0,min(fx+1.0,g.clip.z)-max(fx,g.clip.x))*max(0.0,min(fy+1.0,g.clip.w)-max(fy,g.clip.y));\n"
"  uint kind=uint(g.misc2.y);float amount=clamp(0.5-sd,0.0,1.0)*cover*g.background.w;if(kind==3u)amount*=g.fill.a;\n"
"  if(amount==0.0)return d/255.0;\n"
"  float4 color;\n"
"  if(kind==3u)color=pack(g.fill.rgb);\n"
"  else if(kind==0u)color=round(res.read(local)*255.0);\n"
"  else if(kind==2u){float3 c=toned(straight(round(res.read(local)*255.0)),0.25,0.03);color=pack(c+(g.background.rgb-c)*0.8245);}\n"
"  else{float depth=max(-sd,0.0);float bezel=g.misc.z;float2 n=float2(0.0);if(depth<bezel||depth<3.0)n=edge_normal(g.box,radius,px,py);\n"
"    float sx=px,sy=py;if(depth<bezel){float k=g.misc.y*lens(depth,bezel);sx-=n.x*k;sy-=n.y*k;}\n"
"    float3 c=straight(bilinear_clamped(res,float2(g.region.xy),sx,sy));\n"
"    float l=luma(c);float target=g.tone.x+(g.tone.y-g.tone.x)*(1.0-precise::pow(max(1.0-l,0.0),g.tone.z));c=clamp(target+(c-l)*((g.tone.y-g.tone.x)*g.tone.w),0.0,1.0);\n"
"    if(g.tint.a>0.0)c+=(g.tint.rgb-c)*g.tint.a;\n"
"    if(depth<3.0){float a=g.misc2.x*precise::exp(-depth*depth);c+=(abs(n.y)-c)*a;}\n"
"    if(g.misc.w>0.0)c+=(grain(xy.x,xy.y)-0.5)*g.misc.w*0.08;\n"
"    color=pack(c);}\n"
"  float4 result=blend_bytes(d,color,amount);if(g.misc2.z==0.0)result.a=255.0;\n"
"  return result/255.0;\n"
"}\n";

/* What the frame does, in order: draw instances, or (op) begin an element
   effect's capture, end one, or run a backdrop shader; run indexes runs. */
enum {OP_DRAW,OP_CAPTURE,OP_EFFECT,OP_BACKDROP,OP_GLASS};
/* A draw batch's instances share a texture and a mask (group composites);
   replace batches overwrite the target (a transparent frame's damage
   cleared) rather than blend. */
typedef struct ZmBatch {uint32_t first,count;int bind,replace;__unsafe_unretained id<MTLTexture> texture,mask;uint32_t op,run;float opacity;} ZmBatch;
/* One effect: a capture (source, at physical origin) and what its program
   writes (output), or a backdrop shader's copy (source) of region and the
   pixels it writes (out). The frame keeps the textures. */
/* What closing a capture runs: an element effect's program, a Gaussian
   group's filter (its kernel among the words, through temp), or nothing. */
enum {RUN_EFFECT,RUN_GROUP,RUN_GAUSSIAN,RUN_TRANSFORM};
typedef struct ZmRun {uint32_t kind,slot,word_offset,word_count,has_pass,region[4],out[4];float origin[2];ZmEffectParams params;__unsafe_unretained id<MTLTexture> source,output,temp,extra[3];uint32_t levels,level_offset;} ZmRun;
typedef struct ZmStats {uint32_t device_creations,layer_creations,resizes,presents,transaction_presents,busy_presents,atlas_pages,glyphs;uint64_t frames,instances,batches,effect_passes,layers,filter_passes,partial_frames,cached_pipelines,backdrops,indicators,offscreen_targets,device_losses,sweeps;} ZmStats;
typedef struct ZmGlyph {float x,y,width,height,left,top;uint32_t color;} ZmGlyph;
#define ZM_CLIPS 33
#define ZM_ATLAS 2048
#define ZM_EFFECT_SLOTS 16
#define ZM_EFFECT_DEPTH 8
#define ZM_EFFECT_WORDS 4096
#define ZM_TEXTURE_LIMIT 16384
/* A capture while it records: the clips it began under, where its texture
   is, and how it composites when it closes: a group's bounds (device
   pixels), opacity and mask (a coverage slot at device rectangle), or a
   transform's map to its parent (DIP) and source in physical pixels. */
typedef struct ZmCapture {float clips[ZM_CLIPS][4];uint32_t clip_depth,run,width,height,kind,empty,opacity,mask;float bounds[4],mask_rect[4];double matrix[6];float faded;uint32_t fades;} ZmCapture;

static atomic_int live_objects;

/* A device domain (src/ui/gpu_resources.zig): one Metal device that
   renderers and immutable textures share. The epoch and token layouts
   are those of the drawing resource ABI; ownership stays in Zig. */
typedef struct GpuDomainEpoch {uint64_t identity,generation;uint32_t status,reserved;} GpuDomainEpoch;
typedef struct GpuTextureToken {uint64_t identity,generation;uint32_t width,height,levels,reserved;} GpuTextureToken;
typedef struct DomainStats {uint32_t objects,devices,losses,reserved;uint64_t bitmaps;} DomainStats;
_Static_assert(sizeof(GpuDomainEpoch)==24,"GPU epoch ABI");
_Static_assert(sizeof(GpuTextureToken)==32,"GPU texture token ABI");
/* Results as src/ui/gpu_resources.zig reads them (HRESULT values). */
#define ZM_OK 0
#define ZM_INVALID ((int32_t)0x80070057)
#define ZM_NO_MEMORY ((int32_t)0x8007000E)
#define ZM_UNEXPECTED ((int32_t)0x8000FFFF)
#define ZM_DEVICE_REMOVED ((int32_t)0x887A0005)
@class ZigMetalRenderer;
@interface ZigMetalDomain : NSObject {
@public
    GpuDomainEpoch *epoch;void *callback_context;void (*release_callback)(void *,int);
    id<MTLDevice> device;id<MTLCommandQueue> queue;
    /* Textures by slot; their tokens stay where they are while the slot
       holds them, as the Zig shells point at them. */
    id<MTLTexture> textures[ZI_IMAGE_SLOTS];GpuTextureToken tokens[ZI_IMAGE_SLOTS];
    NSHashTable<ZigMetalRenderer *> *renderers;
    uint32_t device_creations,device_losses;uint64_t texture_creations;
}
@end
@implementation ZigMetalDomain
- (void)dealloc{atomic_fetch_sub(&live_objects,1);}
@end
static void domain_lose(ZigMetalDomain *domain);

@interface ZigMetalRenderer : NSObject {
@public
    id<MTLDevice> device;id<MTLCommandQueue> queue;id<MTLRenderPipelineState> pipeline,replace_pipeline,filter_pipeline,glass_filter,glass_blend,glass_shade;
    id<MTLSamplerState> linear_sampler,nearest_sampler,mask_sampler;id<MTLTexture> blank;
    CAMetalLayer *layer;__weak NSView *view;__weak NSWindow *window;
    uint32_t width,height;float scale;int transparent,drawing,offscreen,layer_changed,capture,hidden;
    id<MTLTexture> offscreen_target,captured;
    /* The window's frame as last drawn, kept for the next frame to draw
       only what changed; generation names its contents. */
    id<MTLTexture> back;uint64_t generation;int back_valid,partial;
    ZmInstance *instances;uint32_t instance_len,instance_capacity;
    ZmBatch *batches;uint32_t batch_len,batch_capacity;
    ZmBrush brushes[ZG_BRUSH_CAPACITY];uint32_t brush_len;
    NSMutableArray *frame_textures;
    /* Capture textures of this frame, and those no frame the GPU draws
       still uses, for later frames' captures of the same size. */
    NSMutableArray<id<MTLTexture>> *frame_captures,*free_captures;
    /* The frame of the last sweep, and the pooled captures and instance
       buffers it found, which go at the next unless a frame took them. */
    uint64_t swept;NSMutableSet *idle_pooled;
    float clips[ZM_CLIPS][4];uint32_t clip_depth;
    /* The opacity drawings draw at now (Command.push_opacity), and those
       the opacities open saved. */
    float faded,fades[ZM_CLIPS];uint32_t fade_depth;
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
    /* Shader effects: the installed programs, this frame's runs, their
       words and the captures open while recording. */
    id<MTLRenderPipelineState> effect_pipelines[ZM_EFFECT_SLOTS];
    ZmRun *runs;uint32_t run_len,run_capacity;
    uint32_t *words;uint32_t word_len,word_capacity;
    ZmCapture captures[ZM_EFFECT_DEPTH];uint32_t capture_depth;
    /* Compiled pipelines kept on disk across runs (MTLBinaryArchive). */
    id archive;NSURL *archive_url;int archive_dirty;
    /* The domain whose device this renderer draws with, if any; lost while
       that device is gone (zmtl_rebuild takes the new one). front is an
       offscreen surface's last committed frame; loss_fault makes the next
       offscreen frame fail as a removed device does. */
    __weak ZigMetalDomain *domain;int lost,loss_fault;
    id<MTLTexture> front;
    ZmStats stats;
}
@end
@implementation ZigMetalRenderer
- (void)dealloc{
    free(instances);free(batches);free(runs);free(words);
    if(font)CFRelease(font);
    atomic_fetch_sub(&live_objects,1);
}
@end

static ZigMetalRenderer *R(void *p){return (__bridge ZigMetalRenderer *)p;}

/* The pipeline archive of this device and system, in the shader cache the
   other GPU renderers use: $XDG_CACHE_HOME/ziggurat/shader-cache, or
   ~/.cache/ziggurat/shader-cache. An archive grown past 32 MiB starts over. */
static void open_archive(ZigMetalRenderer *s){
    if(@available(macOS 11.0,*)){
        const char *xdg=getenv("XDG_CACHE_HOME"),*home=getenv("HOME");
        NSString *base=xdg&&*xdg?[NSString stringWithUTF8String:xdg]:home&&*home?[[NSString stringWithUTF8String:home] stringByAppendingPathComponent:@".cache"]:nil;
        NSURL *url=nil;
        if(base){
            NSString *dir=[base stringByAppendingPathComponent:@"ziggurat/shader-cache"];
            NSFileManager *files=[NSFileManager defaultManager];
            if([files createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]){
                NSString *key=[NSString stringWithFormat:@"%@|%llx|%@",s->device.name,(unsigned long long)s->device.registryID,[[NSProcessInfo processInfo] operatingSystemVersionString]];
                uint64_t hash=1469598103934665603ull;
                for(const char *c=[key UTF8String];c&&*c;c++){hash^=(uint8_t)*c;hash*=1099511628211ull;}
                NSString *path=[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"metal-%016llx.binarchive",(unsigned long long)hash]];
                NSDictionary *attributes=[files attributesOfItemAtPath:path error:nil];
                if(attributes&&[attributes fileSize]>32ull*1024*1024)[files removeItemAtPath:path error:nil];
                url=[NSURL fileURLWithPath:path];
            }
        }
        MTLBinaryArchiveDescriptor *d=[[MTLBinaryArchiveDescriptor alloc] init];
        if(url&&[[NSFileManager defaultManager] fileExistsAtPath:url.path])d.url=url;
        NSError *error=nil;id<MTLBinaryArchive> archive=[s->device newBinaryArchiveWithDescriptor:d error:&error];
        /* One another system or GPU wrote, or damaged: start over. */
        if(!archive&&d.url){d.url=nil;archive=[s->device newBinaryArchiveWithDescriptor:d error:&error];}
        s->archive=archive;s->archive_url=url;
    }
}
/* A pipeline the archive holds compiled when it does; otherwise compiled
   now and added to it, for save_archive to keep. */
static id<MTLRenderPipelineState> make_pipeline(ZigMetalRenderer *s,MTLRenderPipelineDescriptor *d,NSError **error){
    if(@available(macOS 11.0,*)){
        id<MTLBinaryArchive> archive=s->archive;
        if(archive){
            d.binaryArchives=@[archive];
            id<MTLRenderPipelineState> cached=[s->device newRenderPipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:nil];
            if(cached){s->stats.cached_pipelines++;return cached;}
            d.binaryArchives=nil;
            id<MTLRenderPipelineState> made=[s->device newRenderPipelineStateWithDescriptor:d error:error];
            if(made&&[archive addRenderPipelineFunctionsWithDescriptor:d error:nil])s->archive_dirty=1;
            return made;
        }
    }
    return [s->device newRenderPipelineStateWithDescriptor:d error:error];
}
/* Writes the archive beside its file and moves it over, so a reader never
   sees half of one. */
static void save_archive(ZigMetalRenderer *s){
    if(!s->archive_dirty||!s->archive_url)return;
    s->archive_dirty=0;
    if(@available(macOS 11.0,*)){
        id<MTLBinaryArchive> archive=s->archive;
        NSString *path=s->archive_url.path;
        NSString *temporary=[path stringByAppendingFormat:@".%d.tmp",(int)getpid()];
        if([archive serializeToURL:[NSURL fileURLWithPath:temporary] error:nil])rename([temporary fileSystemRepresentation],[path fileSystemRepresentation]);
        else unlink([temporary fileSystemRepresentation]);
    }
}
static MTLRenderPipelineDescriptor *blended(id<MTLLibrary> library,NSString *vertex,NSString *fragment,int blend){
    MTLRenderPipelineDescriptor *d=[[MTLRenderPipelineDescriptor alloc] init];
    d.vertexFunction=[library newFunctionWithName:vertex];d.fragmentFunction=[library newFunctionWithName:fragment];
    MTLRenderPipelineColorAttachmentDescriptor *color=d.colorAttachments[0];
    color.pixelFormat=MTLPixelFormatBGRA8Unorm;color.blendingEnabled=blend?YES:NO;
    color.rgbBlendOperation=color.alphaBlendOperation=MTLBlendOperationAdd;
    color.sourceRGBBlendFactor=color.sourceAlphaBlendFactor=MTLBlendFactorOne;
    color.destinationRGBBlendFactor=color.destinationAlphaBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
    return d;
}
static int create_pipeline(ZigMetalRenderer *s){
    NSError *error=nil;
    id<MTLLibrary> library=[s->device newLibraryWithSource:shader_source options:nil error:&error];
    if(!library){NSLog(@"Ziggurat Metal shaders: %@",error);return 0;}
    open_archive(s);
    s->pipeline=make_pipeline(s,blended(library,@"zm_vertex",@"zm_fragment",1),&error);
    if(s->pipeline)s->replace_pipeline=make_pipeline(s,blended(library,@"zm_vertex",@"zm_fragment",0),&error);
    if(s->replace_pipeline)s->filter_pipeline=make_pipeline(s,blended(library,@"zm_full_vertex",@"zm_filter",0),&error);
    if(s->filter_pipeline)s->glass_filter=make_pipeline(s,blended(library,@"zm_full_vertex",@"zm_glass_filter",0),&error);
    if(s->glass_filter)s->glass_blend=make_pipeline(s,blended(library,@"zm_full_vertex",@"zm_glass_blend",0),&error);
    if(s->glass_blend)s->glass_shade=make_pipeline(s,blended(library,@"zm_quad_vertex",@"zm_glass_shade",0),&error);
    if(!s->glass_shade){NSLog(@"Ziggurat Metal pipeline: %@",error);return 0;}
    save_archive(s);
    MTLSamplerDescriptor *sd=[[MTLSamplerDescriptor alloc] init];
    sd.minFilter=sd.magFilter=MTLSamplerMinMagFilterLinear;sd.mipFilter=MTLSamplerMipFilterNotMipmapped;
    sd.sAddressMode=sd.tAddressMode=MTLSamplerAddressModeClampToZero;
    s->mask_sampler=[s->device newSamplerStateWithDescriptor:sd];
    sd.sAddressMode=sd.tAddressMode=MTLSamplerAddressModeClampToEdge;
    // Images pick their mip level on the CPU and pass it as an explicit lod;
    // a NotMipmapped sampler would ignore it and always read level 0.
    sd.mipFilter=MTLSamplerMipFilterNearest;
    s->linear_sampler=[s->device newSamplerStateWithDescriptor:sd];
    sd.minFilter=sd.magFilter=MTLSamplerMinMagFilterNearest;
    s->nearest_sampler=[s->device newSamplerStateWithDescriptor:sd];
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:1 height:1 mipmapped:NO];
    s->blank=[s->device newTextureWithDescriptor:td];
    uint32_t white=0xffffffff;[s->blank replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:&white bytesPerRow:4];
    return s->linear_sampler&&s->nearest_sampler&&s->mask_sampler&&s->blank;
}

static ZigMetalRenderer *new_renderer(id<MTLDevice> device,int *error){
    ZigMetalRenderer *s=[[ZigMetalRenderer alloc] init];atomic_fetch_add(&live_objects,1);
    s->device=device;s->queue=[device newCommandQueue];
    if(!s->queue||!create_pipeline(s)){*error=2;return nil;}
    s->free_buffers=[NSMutableArray array];s->frame_textures=[NSMutableArray array];
    s->frame_captures=[NSMutableArray array];s->free_captures=[NSMutableArray array];s->idle_pooled=[NSMutableSet set];
    s->glyphs=[NSMutableDictionary dictionary];s->fonts=[NSMutableArray array];s->font_sources=[NSMutableArray array];s->font_scales=[NSMutableArray array];
    s->slots=[NSMutableArray array];s->prepared_keys=[NSMutableArray array];s->prepared_textures=[NSMutableArray array];
    s->hidden=1;s->stats.device_creations=1;*error=0;
    return s;
}
void *zmtl_create(int *error){
    @autoreleasepool{
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        if(!device){*error=1;return NULL;}
        ZigMetalRenderer *s=new_renderer(device,error);
        return s?(__bridge_retained void *)s:NULL;
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
    s->instance_len=0;s->batch_len=0;s->brush_len=0;s->clip_depth=0;s->run_len=0;s->word_len=0;s->capture_depth=0;s->partial=0;
    s->faded=1;s->fade_depth=0;
    s->clips[0][0]=0;s->clips[0][1]=0;s->clips[0][2]=(float)s->width;s->clips[0][3]=(float)s->height;
    [s->frame_textures removeAllObjects];
    /* A frame not encoded leaves its captures unused. */
    if([s->frame_captures count]){@synchronized(s->free_captures){[s->free_captures addObjectsFromArray:s->frame_captures];}[s->frame_captures removeAllObjects];}
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
    ZigMetalRenderer *s=R(p);if(s->drawing)return 1;if(s->lost)return 2;
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
    if(!s->back||s->back.width!=width||s->back.height!=height){
        MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
        d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;d.storageMode=MTLStorageModePrivate;
        s->back=[s->device newTextureWithDescriptor:d];
        s->back_valid=0;s->generation++;
        if(!s->back)return 2;
    }
    reset_frame(s);s->drawing=1;return 0;
}
/* Whether the kept frame holds the last frame presented at this size,
   and which: a frame may then draw only its damage over it. */
int zmtl_plane(void *p,uint64_t *generation){ZigMetalRenderer *s=R(p);*generation=s->generation;return s->drawing&&!s->offscreen&&s->back_valid;}
/* This frame draws over the last one (its damage): the window's target
   is not cleared first. */
void zmtl_set_partial(void *p,int partial){ZigMetalRenderer *s=R(p);if(s->drawing&&!s->offscreen&&s->back_valid){s->partial=partial?1:0;if(partial)s->stats.partial_frames++;}}
float zmtl_scale(void *p){return R(p)->scale;}

static ZmInstance *push_with(ZigMetalRenderer *s,int bind,id<MTLTexture> texture,id<MTLTexture> mask,int replace){
    if(s->instance_len==s->instance_capacity){
        uint32_t capacity=s->instance_capacity?s->instance_capacity*2:1024;
        ZmInstance *grown=realloc(s->instances,(size_t)capacity*sizeof(ZmInstance));if(!grown)return NULL;
        s->instances=grown;s->instance_capacity=capacity;
    }
    ZmBatch *last=s->batch_len?&s->batches[s->batch_len-1]:NULL;
    /* Untextured instances join any batch that blends as they do; a
       textured one needs its own. */
    int joins=last&&last->op==OP_DRAW&&last->replace==replace&&last->opacity==s->faded&&((bind==BIND_NONE&&!mask)||(last->bind==bind&&last->texture==texture&&last->mask==mask)||(last->bind==BIND_NONE&&!last->mask));
    if(joins){
        if(bind!=BIND_NONE&&last->bind==BIND_NONE){last->bind=bind;last->texture=texture;last->mask=mask;[s->frame_textures addObject:texture];if(mask)[s->frame_textures addObject:mask];}
        last->count++;
    }else{
        if(s->batch_len==s->batch_capacity){
            uint32_t capacity=s->batch_capacity?s->batch_capacity*2:64;
            ZmBatch *grown=realloc(s->batches,(size_t)capacity*sizeof(ZmBatch));if(!grown)return NULL;
            s->batches=grown;s->batch_capacity=capacity;
        }
        s->batches[s->batch_len++]=(ZmBatch){s->instance_len,1,bind,replace,texture,mask,OP_DRAW,0,s->faded};
        if(texture)[s->frame_textures addObject:texture];
        if(mask)[s->frame_textures addObject:mask];
    }
    ZmInstance *i=&s->instances[s->instance_len++];memset(i,0,sizeof(*i));
    memcpy(i->clip,s->clips[s->clip_depth],sizeof(i->clip));
    return i;
}
static ZmInstance *push(ZigMetalRenderer *s,int bind,id<MTLTexture> texture){return push_with(s,bind,texture,nil,0);}
static void device_rect(ZigMetalRenderer *s,float *out,double x,double y,double width,double height){
    double k=s->scale;out[0]=(float)(x*k);out[1]=(float)(y*k);out[2]=(float)((x+width)*k);out[3]=(float)((y+height)*k);
}
static void rgba_color(float *out,uint32_t rgba){
    float a=(float)(rgba&255)/255.0f;
    out[0]=(float)(rgba>>24)/255.0f*a;out[1]=(float)((rgba>>16)&255)/255.0f*a;out[2]=(float)((rgba>>8)&255)/255.0f*a;out[3]=a;
}
static void rgb_color(float *out,uint32_t rgb){rgba_color(out,(rgb<<8)|255);}
static int visible(ZigMetalRenderer *s){const float *c=s->clips[s->clip_depth];return c[2]>c[0]&&c[3]>c[1];}
/* Makes device pixels x0, y0 to x1, y1 (under the clip) transparent. */
void zmtl_clear_box(void *p,int32_t x0,int32_t y0,int32_t x1,int32_t y1){
    ZigMetalRenderer *s=R(p);if(!visible(s))return;
    ZmInstance *i=push_with(s,BIND_NONE,nil,nil,1);if(!i)return;
    i->rect[0]=(float)x0;i->rect[1]=(float)y0;i->rect[2]=(float)x1;i->rect[3]=(float)y1;i->params[2]=KIND_RECT;
}
/* Clips to device pixels x0, y0 to x1, y1, as zmtl_push_clip does to DIP. */
void zmtl_push_device_clip(void *p,int32_t x0,int32_t y0,int32_t x1,int32_t y1){
    ZigMetalRenderer *s=R(p);if(s->clip_depth+1>=ZM_CLIPS)return;
    const float *b=s->clips[s->clip_depth];float *a=s->clips[++s->clip_depth];
    a[0]=fmaxf(b[0],(float)x0);a[1]=fmaxf(b[1],(float)y0);a[2]=fminf(b[2],(float)x1);a[3]=fminf(b[3],(float)y1);
}
int zmtl_begin_offscreen(void *p,uint32_t width,uint32_t height,float scale,int transparent){
    ZigMetalRenderer *s=R(p);if(s->drawing||!width||!height)return 1;if(s->lost)return 2;
    if(!s->offscreen_target||s->offscreen_target.width!=width||s->offscreen_target.height!=height){
        MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
        d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;d.storageMode=MTLStorageModeShared;
        s->offscreen_target=[s->device newTextureWithDescriptor:d];if(!s->offscreen_target)return 2;
        s->stats.offscreen_targets++;
    }
    s->width=width;s->height=height;s->scale=scale;s->transparent=transparent;s->offscreen=1;
    reset_frame(s);s->drawing=1;return 0;
}

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
int zmtl_gradient(void *p,float x,float y,float width,float height,float radius,float stroke,const ZgBrush *brush,uint32_t spread,uint32_t space){
    ZigMetalRenderer *s=R(p);
    if(width==0||height==0||!visible(s))return 0;
    if(brush->len==0||brush->len>ZG_STOP_CAPACITY||s->brush_len==ZG_BRUSH_CAPACITY)return 1;
    ZmBrush *b=&s->brushes[s->brush_len];memset(b,0,sizeof(*b));
    if(space>2)return 1;
    b->head[0]=(float)brush->kind;b->head[1]=(float)spread;b->head[2]=(float)brush->len;b->head[3]=(float)space;
    b->ab[0]=brush->x0;b->ab[1]=brush->y0;b->ab[2]=brush->x1;b->ab[3]=brush->y1;
    for(uint32_t k=0;k<brush->len;k++){b->offsets[k]=brush->stops[k].offset;stop_color(b->colors[k],brush->stops[k].rgba,space);}
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
/* Draw what follows at alpha (of 255) more, each drawing by itself, until
   zmtl_pop_opacity (Command.push_opacity). */
void zmtl_push_opacity(void *p,uint32_t alpha){
    ZigMetalRenderer *s=R(p);if(s->fade_depth==ZM_CLIPS)return;
    s->fades[s->fade_depth++]=s->faded;s->faded*=(float)(alpha>255?255:alpha)/255.0f;
}
void zmtl_pop_opacity(void *p){ZigMetalRenderer *s=R(p);if(s->fade_depth)s->faded=s->fades[--s->fade_depth];}
/* Narrows the current clip for one command; restore_clip puts it back. */
static void narrow_clip(ZigMetalRenderer *s,double x,double y,double width,double height,float *saved){
    float *c=s->clips[s->clip_depth];memcpy(saved,c,4*sizeof(float));
    float r[4];device_rect(s,r,x,y,width,height);
    c[0]=fmaxf(c[0],r[0]);c[1]=fmaxf(c[1],r[1]);c[2]=fminf(c[2],r[2]);c[3]=fminf(c[3],r[3]);
}
static void restore_clip(ZigMetalRenderer *s,const float *saved){memcpy(s->clips[s->clip_depth],saved,4*sizeof(float));}

/* Glyphs. */
/* Once ZG_SWEEP_EVERY frames went by since the last sweep, the capture
   textures and instance buffers pooled for later frames that no frame took
   since the sweep before go (gpu_sweep.h): an animation's frames of one
   size and then another leave none behind. */
static void sweep_if_due(ZigMetalRenderer *s){
    if(!zg_sweep_due(s->stats.frames,&s->swept))return;
    NSMutableSet *seen=[NSMutableSet set];
    @synchronized(s->free_captures){
        NSMutableArray *kept=[NSMutableArray array];
        for(id texture in s->free_captures)if(![s->idle_pooled containsObject:texture]){[kept addObject:texture];[seen addObject:texture];}
        [s->free_captures setArray:kept];
    }
    @synchronized(s->free_buffers){
        NSMutableArray *kept=[NSMutableArray array];
        for(id buffer in s->free_buffers)if(![s->idle_pooled containsObject:buffer]){[kept addObject:buffer];[seen addObject:buffer];}
        [s->free_buffers setArray:kept];
    }
    s->idle_pooled=seen;s->stats.sweeps++;
}
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
static int draw_image(ZigMetalRenderer *s,id<MTLTexture> texture,const ZiImagePlan *plan);
int zmtl_image(void *p,uint32_t slot,const ZiImagePlan *plan){return draw_image(R(p),slot_texture(R(p),slot),plan);}
/* An image's level drawn over plan's destination at its opacity. */
static int draw_image(ZigMetalRenderer *s,id<MTLTexture> texture,const ZiImagePlan *plan){
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

/* Shader effects. */
/* Compile one program's library (src/ui/gpu_effect_host.zig) without fast
   math, so non-finite values fault as on the CPU, and install it in slot.
   0 installed, 1 invalid, 2 the compiler rejects it, 3 failed. */
int zmtl_effect_install(void *p,uint32_t slot,const char *source,size_t len){
    ZigMetalRenderer *s=R(p);if(slot>=ZM_EFFECT_SLOTS||!source||!len||s->drawing)return 1;
    @autoreleasepool{
        NSString *text=[[NSString alloc] initWithBytes:source length:len encoding:NSUTF8StringEncoding];if(!text)return 1;
        MTLCompileOptions *options=[[MTLCompileOptions alloc] init];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        options.fastMathEnabled=NO;
#pragma clang diagnostic pop
        NSError *error=nil;
        id<MTLLibrary> library=[s->device newLibraryWithSource:text options:options error:&error];
        if(!library)return 2;
        id<MTLFunction> vertex=[library newFunctionWithName:@"zs_vertex"],fragment=[library newFunctionWithName:@"zs_fragment"];
        if(!vertex||!fragment)return 2;
        MTLRenderPipelineDescriptor *d=[[MTLRenderPipelineDescriptor alloc] init];
        d.vertexFunction=vertex;d.fragmentFunction=fragment;d.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
        id<MTLRenderPipelineState> pipeline=make_pipeline(s,d,&error);
        if(!pipeline)return 3;
        s->effect_pipelines[slot]=pipeline;
        save_archive(s);
    }
    return 0;
}
int zmtl_effect_installed(void *p,uint32_t slot){ZigMetalRenderer *s=R(p);return slot<ZM_EFFECT_SLOTS&&s->effect_pipelines[slot]!=nil;}
uint64_t zmtl_effect_passes(void *p){return R(p)->stats.effect_passes;}
static ZmBatch *push_op(ZigMetalRenderer *s,uint32_t op,uint32_t run){
    if(s->batch_len==s->batch_capacity){
        uint32_t capacity=s->batch_capacity?s->batch_capacity*2:64;
        ZmBatch *grown=realloc(s->batches,(size_t)capacity*sizeof(ZmBatch));if(!grown)return NULL;
        s->batches=grown;s->batch_capacity=capacity;
    }
    ZmBatch *b=&s->batches[s->batch_len++];*b=(ZmBatch){s->instance_len,0,BIND_NONE,0,nil,nil,op,run,1};
    return b;
}
static ZmRun *new_run(ZigMetalRenderer *s,uint32_t *index){
    if(s->run_len==s->run_capacity){
        uint32_t capacity=s->run_capacity?s->run_capacity*2:8;
        ZmRun *grown=realloc(s->runs,(size_t)capacity*sizeof(ZmRun));if(!grown)return NULL;
        s->runs=grown;s->run_capacity=capacity;
    }
    *index=s->run_len;ZmRun *r=&s->runs[s->run_len++];memset(r,0,sizeof(*r));return r;
}
/* The pass's words, each run's starting on a 256-byte boundary as the
   constant buffer offsets need. */
static int keep_words(ZigMetalRenderer *s,ZmRun *run,const ZmEffectPass *pass){
    if(pass->word_count>ZM_EFFECT_WORDS||(pass->word_count&&!pass->words))return 0;
    uint32_t start=(s->word_len+63)&~63u,end=start+(pass->word_count?pass->word_count:4);
    if(end>s->word_capacity){
        uint32_t capacity=s->word_capacity?s->word_capacity:1024;while(capacity<end)capacity*=2;
        uint32_t *grown=realloc(s->words,(size_t)capacity*4);if(!grown)return 0;
        s->words=grown;s->word_capacity=capacity;
    }
    memset(s->words+s->word_len,0,(size_t)(end-s->word_len)*4);
    if(pass->word_count)memcpy(s->words+start,pass->words,(size_t)pass->word_count*4);
    run->slot=pass->slot;run->word_offset=start;run->word_count=pass->word_count;run->params=pass->params;run->has_pass=1;
    s->word_len=end;return 1;
}
/* A texture for one of the frame's captures, reused from an earlier
   frame's of the same size and use when one is free. */
static id<MTLTexture> effect_texture(ZigMetalRenderer *s,uint32_t width,uint32_t height,MTLTextureUsage usage){
    id<MTLTexture> texture=nil;
    @synchronized(s->free_captures){
        NSUInteger count=[s->free_captures count];
        for(NSUInteger k=0;k<count;k++){
            id<MTLTexture> candidate=s->free_captures[k];
            if(candidate.width==width&&candidate.height==height&&candidate.usage==usage){texture=candidate;[s->free_captures removeObjectAtIndex:k];break;}
        }
        /* Keep a few frames' worth. */
        while([s->free_captures count]>24)[s->free_captures removeObjectAtIndex:0];
    }
    if(!texture){
        MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
        d.usage=usage;d.storageMode=MTLStorageModePrivate;
        texture=[s->device newTextureWithDescriptor:d];
    }
    if(texture)[s->frame_captures addObject:texture];
    return texture;
}
int zmtl_effect_geometry(void *p,ZmEffectGeometry *out){
    ZigMetalRenderer *s=R(p);if(!s->drawing)return 1;
    out->scale=s->scale;
    if(s->capture_depth){
        const ZmRun *run=&s->runs[s->captures[s->capture_depth-1].run];
        out->origin[0]=-run->origin[0];out->origin[1]=-run->origin[1];
        out->width=(uint32_t)run->source.width;out->height=(uint32_t)run->source.height;out->transparent=1;
    }else{out->origin[0]=out->origin[1]=0;out->width=s->width;out->height=s->height;out->transparent=s->transparent!=0;}
    const float *c=s->clips[s->clip_depth];
    double clip[4]={fmax(0,(double)c[0]+out->origin[0]),fmax(0,(double)c[1]+out->origin[1]),fmin(out->width,(double)c[2]+out->origin[0]),fmin(out->height,(double)c[3]+out->origin[1])};
    if(clip[2]<clip[0])clip[2]=clip[0];if(clip[3]<clip[1])clip[3]=clip[1];
    memcpy(out->clip,clip,sizeof(clip));return 0;
}
/* Opens a capture of width x height texels, texel 0 at device pixel
   (ox, oy) of the current target's coordinates, drawn under clip alone
   (device pixels). 0, 1 too deep or not drawing, 2 failed. */
static int open_capture(ZigMetalRenderer *s,uint32_t kind,uint64_t width,uint64_t height,double ox,double oy,const float clip[4],ZmCapture **out){
    if(!s->drawing||s->capture_depth==ZM_EFFECT_DEPTH)return 1;
    if(!width||!height||width>ZM_TEXTURE_LIMIT||height>ZM_TEXTURE_LIMIT)return 1;
    uint32_t index;ZmRun *run=new_run(s,&index);if(!run)return 2;
    run->kind=kind;
    run->source=effect_texture(s,(uint32_t)width,(uint32_t)height,MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead);if(!run->source)return 2;
    run->origin[0]=(float)ox;run->origin[1]=(float)oy;
    if(!push_op(s,OP_CAPTURE,index))return 2;
    ZmCapture *c=&s->captures[s->capture_depth++];
    memcpy(c->clips,s->clips,sizeof(c->clips));c->clip_depth=s->clip_depth;c->run=index;c->width=(uint32_t)width;c->height=(uint32_t)height;
    c->kind=kind;c->empty=0;c->opacity=255;c->mask=UINT32_MAX;
    /* Opacities opened outside fade the capture as one drawing. */
    c->faded=s->faded;c->fades=s->fade_depth;s->faded=1;
    s->clip_depth=0;memcpy(s->clips[0],clip,sizeof(s->clips[0]));
    *out=c;return 0;
}
/* Begin an element effect's capture of width x height physical pixels at
   left, top with a transparent margin of radius around them: what follows
   draws into it, clipped to those pixels alone. 0, 1 too deep or not
   drawing, 2 failed. */
int zmtl_begin_effect(void *p,int32_t left,int32_t top,uint32_t width,uint32_t height,uint32_t radius){
    ZigMetalRenderer *s=R(p);
    const float clip[4]={(float)left,(float)top,(float)((double)left+width),(float)((double)top+height)};
    ZmCapture *c;
    return open_capture(s,RUN_EFFECT,(uint64_t)width+2*(uint64_t)radius,(uint64_t)height+2*(uint64_t)radius,(double)left-radius,(double)top-radius,clip,&c);
}
/* Composites group (opacity, mask) of c, whose bounds are in device pixels. */
static void keep_group(ZigMetalRenderer *s,ZmCapture *c,const ZgLayerGroup *group){
    c->opacity=group->opacity>255?255:group->opacity;c->mask=group->mask_slot;
    if(group->mask_slot!=UINT32_MAX){
        id<MTLTexture> mask=slot_texture(s,group->mask_slot);
        double x=(double)group->mask_x*s->scale+group->mask_left,y=(double)group->mask_y*s->scale+group->mask_top;
        c->mask_rect[0]=(float)x;c->mask_rect[1]=(float)y;c->mask_rect[2]=(float)(x+(mask?mask.width:1));c->mask_rect[3]=(float)(y+(mask?mask.height:1));
    }
}
/* Begin a group: its pixels under the clip (whole device pixels), drawn
   in the current target's coordinates. 0, 1 too deep, invalid or not
   drawing, 2 failed. */
int zmtl_begin_group(void *p,const ZgLayerGroup *group){
    ZigMetalRenderer *s=R(p);if(!s->drawing)return 1;
    if(group->mask_slot!=UINT32_MAX){id<MTLTexture> mask=slot_texture(s,group->mask_slot);if(!mask||mask.pixelFormat!=MTLPixelFormatR8Unorm)return 1;}
    float r[4];device_rect(s,r,group->x,group->y,group->width,group->height);
    const float *clip=s->clips[s->clip_depth];
    double box[4]={floor(fmax(r[0],clip[0])),floor(fmax(r[1],clip[1])),ceil(fmin(r[2],clip[2])),ceil(fmin(r[3],clip[3]))};
    int empty=!(box[2]>box[0]&&box[3]>box[1]);
    if(empty){box[2]=box[0]+1;box[3]=box[1]+1;}
    float inner[4]={(float)box[0],(float)box[1],(float)box[2],(float)box[3]};
    if(empty)inner[2]=inner[0],inner[3]=inner[1];
    ZmCapture *c;int status=open_capture(s,RUN_GROUP,(uint64_t)(box[2]-box[0]),(uint64_t)(box[3]-box[1]),box[0],box[1],inner,&c);if(status)return status;
    c->empty=empty;memcpy(c->bounds,r,sizeof(r));keep_group(s,c,group);
    return 0;
}
/* Begin a Gaussian group: its capture (physical pixels, as
   src/ui/gaussian_scope.zig plans it) with a transparent margin of the
   kernel's radius, filtered when it closes. */
int zmtl_begin_gaussian(void *p,const ZgLayerGroup *group,int32_t left,int32_t top,uint32_t width,uint32_t height,uint32_t radius,const uint32_t *weights){
    ZigMetalRenderer *s=R(p);if(!s->drawing||radius>128)return 1;
    if(group->mask_slot!=UINT32_MAX){id<MTLTexture> mask=slot_texture(s,group->mask_slot);if(!mask||mask.pixelFormat!=MTLPixelFormatR8Unorm)return 1;}
    const uint64_t pw=(uint64_t)width+2*(uint64_t)radius,ph=(uint64_t)height+2*(uint64_t)radius;
    const float clip[4]={(float)left,(float)top,(float)((double)left+width),(float)((double)top+height)};
    ZmCapture *c;int status=open_capture(s,RUN_GAUSSIAN,pw,ph,(double)left-radius,(double)top-radius,clip,&c);if(status)return status;
    ZmRun *run=&s->runs[c->run];
    uint32_t filter[4+257]={(uint32_t)pw,(uint32_t)ph,radius,0};memcpy(filter+4,weights,257*sizeof(uint32_t));
    const ZmEffectPass pass={.words=filter,.word_count=4+257};
    if(!keep_words(s,run,&pass))return 2;
    run->has_pass=0;
    c->bounds[0]=(float)((double)left-radius);c->bounds[1]=(float)((double)top-radius);c->bounds[2]=(float)((double)left+width+radius);c->bounds[3]=(float)((double)top+height+radius);
    keep_group(s,c,group);
    return 0;
}
/* Close the innermost group: filter a Gaussian group's capture, then
   composite it at its opacity through its mask under the clip it began in,
   inside its bounds. */
int zmtl_end_group(void *p){
    ZigMetalRenderer *s=R(p);if(!s->drawing||!s->capture_depth)return 1;
    ZmCapture *c=&s->captures[s->capture_depth-1];if(c->kind!=RUN_GROUP&&c->kind!=RUN_GAUSSIAN)return 1;
    s->capture_depth--;
    memcpy(s->clips,c->clips,sizeof(s->clips));s->clip_depth=c->clip_depth;s->faded=c->faded;s->fade_depth=c->fades;
    ZmRun *run=&s->runs[c->run];
    if(c->kind==RUN_GAUSSIAN){
        run->temp=effect_texture(s,c->width,c->height,MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead);
        run->output=effect_texture(s,c->width,c->height,MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead);
        if(!run->temp||!run->output)return 2;
    }
    if(!push_op(s,OP_EFFECT,c->run))return 2;
    s->stats.layers++;
    if(c->empty||!visible(s)||c->opacity==0)return 0;
    id<MTLTexture> mask=c->mask==UINT32_MAX?nil:slot_texture(s,c->mask);
    if(c->mask!=UINT32_MAX&&!mask)return 1;
    ZmInstance *i=push_with(s,BIND_TEXTURE,run->output?run->output:run->source,mask,0);if(!i)return 2;
    memcpy(i->rect,c->bounds,sizeof(i->rect));
    float alpha=(float)c->opacity/255.0f;i->color[0]=i->color[1]=i->color[2]=i->color[3]=alpha;
    i->params[0]=run->origin[0];i->params[1]=run->origin[1];i->params[2]=KIND_LAYER;i->params[3]=mask?1:0;
    memcpy(i->uv,c->mask_rect,sizeof(i->uv));
    return 0;
}
/* Begin a raster transform's source: pixel_width x pixel_height physical
   pixels of local coordinates with a transparent guard texel around them,
   local zero at texel (1, 1), clipped to the source rectangle. */
int zmtl_begin_transform(void *p,uint32_t pixel_width,uint32_t pixel_height,float source_width,float source_height){
    ZigMetalRenderer *s=R(p);if(!s->drawing)return 1;
    const float clip[4]={0,0,(float)((double)source_width*s->scale),(float)((double)source_height*s->scale)};
    ZmCapture *c;return open_capture(s,RUN_TRANSFORM,(uint64_t)pixel_width+2,(uint64_t)pixel_height+2,-1,-1,clip,&c);
}
/* Close the innermost transform: sample its source back through inverse
   (local DIP of parent DIP: xx, yx, xy, yy, x0, y0) over bounds (device
   pixels of the parent) under the clip it began in. */
int zmtl_end_transform(void *p,const double inverse[6],const float bounds[4]){
    ZigMetalRenderer *s=R(p);if(!s->drawing||!s->capture_depth)return 1;
    ZmCapture *c=&s->captures[s->capture_depth-1];if(c->kind!=RUN_TRANSFORM)return 1;
    s->capture_depth--;
    memcpy(s->clips,c->clips,sizeof(s->clips));s->clip_depth=c->clip_depth;s->faded=c->faded;s->fade_depth=c->fades;
    ZmRun *run=&s->runs[c->run];
    if(!push_op(s,OP_EFFECT,c->run))return 2;
    s->stats.layers++;
    if(!visible(s)||!(bounds[2]>bounds[0]&&bounds[3]>bounds[1]))return 0;
    ZmInstance *i=push(s,BIND_TEXTURE,run->source);if(!i)return 2;
    memcpy(i->rect,bounds,sizeof(i->rect));
    /* Texel coordinates of a device pixel: the inverse in DIP, the scales
       cancelling, local zero at texel (1, 1) and texel centers at .5. */
    i->uv[0]=(float)inverse[0];i->uv[1]=(float)inverse[2];i->uv[2]=(float)inverse[1];i->uv[3]=(float)inverse[3];
    i->params[0]=(float)(inverse[4]*s->scale+0.5);i->params[1]=(float)(inverse[5]*s->scale+0.5);i->params[2]=KIND_TRANSFORM;
    i->color[3]=1;
    return 0;
}
/* Close the innermost capture: run pass over it (NULL composites the
   content as drawn) and composite the result at opacity under the clip
   the capture began in. */
int zmtl_end_effect(void *p,const ZmEffectPass *pass,uint32_t opacity){
    ZigMetalRenderer *s=R(p);if(!s->drawing||!s->capture_depth||s->captures[s->capture_depth-1].kind!=RUN_EFFECT)return 1;
    if(pass&&(pass->slot>=ZM_EFFECT_SLOTS||!s->effect_pipelines[pass->slot]))return 1;
    ZmCapture *c=&s->captures[--s->capture_depth];
    memcpy(s->clips,c->clips,sizeof(s->clips));s->clip_depth=c->clip_depth;s->faded=c->faded;s->fade_depth=c->fades;
    ZmRun *run=&s->runs[c->run];
    if(pass){
        if(!keep_words(s,run,pass))return 2;
        run->output=effect_texture(s,c->width,c->height,MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead);if(!run->output)return 2;
    }
    if(!push_op(s,OP_EFFECT,c->run))return 2;
    if(!visible(s)||opacity==0)return 0;
    id<MTLTexture> result=pass?run->output:run->source;
    ZmInstance *i=push(s,BIND_TEXTURE,result);if(!i)return 2;
    i->rect[0]=run->origin[0];i->rect[1]=run->origin[1];i->rect[2]=run->origin[0]+(float)c->width;i->rect[3]=run->origin[1]+(float)c->height;
    float alpha=(float)(opacity>255?255:opacity)/255.0f;i->color[0]=i->color[1]=i->color[2]=i->color[3]=alpha;
    i->params[2]=KIND_IMAGE;i->uv[2]=1;i->uv[3]=1;
    return 0;
}
/* Run a backdrop shader over out (physical x0, y0, x1, y1 of the current
   target), reading the target as drawn so far across region, which
   contains out. */
int zmtl_backdrop_shader(void *p,const ZmEffectPass *pass,const uint32_t region[4],const uint32_t out[4]){
    ZigMetalRenderer *s=R(p);if(!s->drawing||pass->slot>=ZM_EFFECT_SLOTS||!s->effect_pipelines[pass->slot])return 1;
    ZmEffectGeometry geometry;zmtl_effect_geometry(p,&geometry);
    if(!(region[0]<=out[0]&&region[1]<=out[1]&&out[0]<out[2]&&out[1]<out[3]&&out[2]<=region[2]&&out[3]<=region[3]&&region[2]<=geometry.width&&region[3]<=geometry.height&&region[2]-region[0]<=ZM_TEXTURE_LIMIT&&region[3]-region[1]<=ZM_TEXTURE_LIMIT))return 1;
    uint32_t index;ZmRun *run=new_run(s,&index);if(!run)return 2;
    if(!keep_words(s,run,pass))return 2;
    /* The opacity the shader's result mixes in at (gpu_effect_host.zig). */
    run->params.d[2]=1-s->faded;
    memcpy(run->region,region,sizeof(run->region));memcpy(run->out,out,sizeof(run->out));
    run->source=effect_texture(s,region[2]-region[0],region[3]-region[1],MTLTextureUsageShaderRead);if(!run->source)return 2;
    return push_op(s,OP_BACKDROP,index)?0:2;
}

/* Words appended to the frame's, starting on a 256-byte boundary as
   constant buffer offsets need; their index, or UINT32_MAX. */
static uint32_t append_words(ZigMetalRenderer *s,const void *data,size_t count){
    uint32_t start=(s->word_len+63)&~63u;uint64_t end=(uint64_t)start+(count?count:1);
    if(end>UINT32_MAX/2)return UINT32_MAX;
    if(end>s->word_capacity){
        uint32_t capacity=s->word_capacity?s->word_capacity:1024;while(capacity<end)capacity*=2;
        uint32_t *grown=realloc(s->words,(size_t)capacity*4);if(!grown)return UINT32_MAX;
        s->words=grown;s->word_capacity=capacity;
    }
    memset(s->words+s->word_len,0,(size_t)(end-s->word_len)*4);
    if(count)memcpy(s->words+start,data,count*4);
    s->word_len=(uint32_t)end;return start;
}
/* A loading indicator (src/ui/loading.zig): count elements of 12 floats
   each, its view box at ox, oy (device pixels) scaled by k, drawn over
   device pixels x0, y0 to x1, y1 in rgb at opacity, under the clip. */
int zmtl_indicator(void *p,const float *elements,uint32_t count,float ox,float oy,float k,const int32_t box[4],uint32_t rgb,float opacity){
    ZigMetalRenderer *s=R(p);if(!s->drawing||count>64)return 1;
    if(!visible(s)||!count)return 0;
    uint32_t at=append_words(s,elements,(size_t)count*12);if(at==UINT32_MAX)return 2;
    ZmInstance *i=push(s,BIND_NONE,nil);if(!i)return 2;
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
int zmtl_backdrop(void *p,const ZmGlass *glass,uint32_t levels,const ZmGlassLevel *level,const float *weights,uint32_t weight_count){
    ZigMetalRenderer *s=R(p);if(!s->drawing||levels>16)return 1;
    ZmEffectGeometry geometry;zmtl_effect_geometry(p,&geometry);
    const uint32_t *region=glass->region,*out=glass->out;
    if(!(region[0]<=out[0]&&region[1]<=out[1]&&out[0]<out[2]&&out[1]<out[3]&&out[2]<=region[2]&&out[3]<=region[3]&&region[2]<=geometry.width&&region[3]<=geometry.height&&region[2]-region[0]<=ZM_TEXTURE_LIMIT&&region[3]-region[1]<=ZM_TEXTURE_LIMIT))return 1;
    for(uint32_t k=0;k<levels;k++)if(level[k].radius>128||(uint64_t)level[k].weights+2*level[k].radius+1>weight_count)return 1;
    uint32_t index;ZmRun *run=new_run(s,&index);if(!run)return 2;
    /* The opacity it shades at (background.w). */
    ZmGlass faded=*glass;faded.background[3]=s->faded;
    run->word_offset=append_words(s,&faded,sizeof(faded)/4);if(run->word_offset==UINT32_MAX)return 2;
    /* Each level's weights on a boundary of their own. */
    ZmGlassLevel placed[16];
    for(uint32_t k=0;k<levels;k++){
        placed[k]=level[k];
        placed[k].weights=append_words(s,weights+level[k].weights,2*level[k].radius+1);if(placed[k].weights==UINT32_MAX)return 2;
    }
    run->level_offset=append_words(s,placed,levels*sizeof(ZmGlassLevel)/4);if(run->level_offset==UINT32_MAX)return 2;
    run->levels=levels;
    memcpy(run->region,region,sizeof(run->region));memcpy(run->out,out,sizeof(run->out));
    uint32_t w=region[2]-region[0],h=region[3]-region[1];
    const MTLTextureUsage usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
    run->source=effect_texture(s,w,h,MTLTextureUsageShaderRead);if(!run->source)return 2;
    int kind=(int)glass->misc2[1],progressive=glass->misc2[3]!=0;
    if(kind!=3&&levels){
        run->temp=effect_texture(s,w,h,usage);run->extra[0]=effect_texture(s,w,h,usage);
        if(!run->temp||!run->extra[0])return 2;
        if(progressive){
            run->extra[1]=effect_texture(s,w,h,usage);run->extra[2]=effect_texture(s,w,h,usage);run->output=effect_texture(s,w,h,usage);
            if(!run->extra[1]||!run->extra[2]||!run->output)return 2;
        }
    }
    s->stats.backdrops++;
    return push_op(s,OP_GLASS,index)?0:2;
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
/* A target the frame draws into: the window's (or offscreen) texture, or an
   element effect's capture at its physical origin. */
typedef struct ZmLevel {__unsafe_unretained id<MTLTexture> texture;float origin[2];int started;} ZmLevel;
static id<MTLRenderCommandEncoder> open_level(ZigMetalRenderer *s,id<MTLCommandBuffer> commands,ZmLevel *level,int root,id<MTLBuffer> buffer,size_t brush_offset,size_t word_offset){
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=level->texture;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    /* A frame drawing only its damage starts from the last one. */
    pass.colorAttachments[0].loadAction=level->started||(root&&s->partial)?MTLLoadActionLoad:MTLLoadActionClear;
    /* An opaque frame starts white, as the software plane does; captures
       start transparent. */
    pass.colorAttachments[0].clearColor=root&&!s->transparent?MTLClearColorMake(1,1,1,1):MTLClearColorMake(0,0,0,0);
    level->started=1;
    id<MTLRenderCommandEncoder> encoder=[commands renderCommandEncoderWithDescriptor:pass];if(!encoder)return nil;
    [encoder setRenderPipelineState:s->pipeline];
    ZmUniforms uniforms={(float)level->texture.width,(float)level->texture.height,s->scale,1,{level->origin[0],level->origin[1]},{0,0}};
    [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:0];[encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentBuffer:buffer offset:brush_offset atIndex:2];
    [encoder setFragmentBuffer:buffer offset:word_offset atIndex:3];
    [encoder setFragmentSamplerState:s->linear_sampler atIndex:0];[encoder setFragmentSamplerState:s->nearest_sampler atIndex:1];[encoder setFragmentSamplerState:s->mask_sampler atIndex:2];
    return encoder;
}
/* Run run's program into target over quad (normalized device x0, y0, x1,
   y1), its fragment positions relative to origin, reading content. */
static int run_effect(ZigMetalRenderer *s,id<MTLCommandBuffer> commands,const ZmRun *run,id<MTLTexture> target,MTLLoadAction load,const float quad[4],const float origin[2],id<MTLTexture> content,id<MTLBuffer> buffer,size_t word_offset){
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=load;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
    id<MTLRenderCommandEncoder> encoder=[commands renderCommandEncoderWithDescriptor:pass];if(!encoder)return 2;
    [encoder setRenderPipelineState:s->effect_pipelines[run->slot]];
    [encoder setVertexBytes:quad length:4*sizeof(float) atIndex:0];
    [encoder setFragmentBuffer:buffer offset:word_offset+(size_t)run->word_offset*4 atIndex:0];
    [encoder setFragmentBytes:&run->params length:sizeof(run->params) atIndex:1];
    [encoder setFragmentBytes:origin length:2*sizeof(float) atIndex:2];
    [encoder setFragmentTexture:content atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    s->stats.effect_passes++;
    return 0;
}
/* One pass of a Gaussian group's integer filter (src/ui/gaussian_kernel.zig)
   from source to target, the kernel at offset of buffer. */
static int filter_pass(ZigMetalRenderer *s,id<MTLCommandBuffer> commands,id<MTLTexture> source,id<MTLTexture> target,uint32_t vertical,id<MTLBuffer> buffer,size_t offset){
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=MTLLoadActionDontCare;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder=[commands renderCommandEncoderWithDescriptor:pass];if(!encoder)return 2;
    [encoder setRenderPipelineState:s->filter_pipeline];
    /* The kernel's words, with vertical in the fourth. */
    uint32_t *words=(uint32_t *)((uint8_t *)buffer.contents+offset);
    uint32_t header[4]={words[0],words[1],words[2],vertical};
    [encoder setFragmentBuffer:buffer offset:offset atIndex:0];
    [encoder setFragmentBytes:header length:sizeof(header) atIndex:1];
    [encoder setFragmentTexture:source atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    s->stats.filter_passes++;
    return 0;
}
/* A full-texture pass of pipeline into target, reading first and second. */
static id<MTLRenderCommandEncoder> glass_pass(id<MTLCommandBuffer> commands,id<MTLRenderPipelineState> pipeline,id<MTLTexture> target,id<MTLTexture> first,id<MTLTexture> second){
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=MTLLoadActionDontCare;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder=[commands renderCommandEncoderWithDescriptor:pass];if(!encoder)return nil;
    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentTexture:first atIndex:0];if(second)[encoder setFragmentTexture:second atIndex:1];
    return encoder;
}
static int glass_blur(ZigMetalRenderer *s,id<MTLCommandBuffer> commands,const ZmGlassLevel *level,id<MTLTexture> source,id<MTLTexture> temp,id<MTLTexture> target,id<MTLBuffer> buffer,size_t word_offset){
    for(uint32_t vertical=0;vertical<2;vertical++){
        id<MTLRenderCommandEncoder> encoder=glass_pass(commands,s->glass_filter,vertical?target:temp,vertical?temp:source,nil);if(!encoder)return 2;
        uint32_t header[4]={level->radius,vertical,(uint32_t)source.width,(uint32_t)source.height};
        [encoder setFragmentBytes:header length:sizeof(header) atIndex:0];
        [encoder setFragmentBuffer:buffer offset:word_offset+(size_t)level->weights*4 atIndex:1];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [encoder endEncoding];
        s->stats.filter_passes++;
    }
    return 0;
}
/* Runs a backdrop effect into current: copy, blur (and blend), shade. */
static int encode_glass(ZigMetalRenderer *s,id<MTLCommandBuffer> commands,const ZmRun *run,id<MTLTexture> current,id<MTLBuffer> buffer,size_t word_offset){
    id<MTLBlitCommandEncoder> blit=[commands blitCommandEncoder];if(!blit)return 2;
    [blit copyFromTexture:current sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(run->region[0],run->region[1],0) sourceSize:MTLSizeMake(run->region[2]-run->region[0],run->region[3]-run->region[1],1) toTexture:run->source destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [blit endEncoding];
    const ZmGlass *glass=(const ZmGlass *)(s->words+run->word_offset);
    const ZmGlassLevel *levels=(const ZmGlassLevel *)(s->words+run->level_offset);
    const size_t glass_offset=word_offset+(size_t)run->word_offset*4;
    id<MTLTexture> result=run->source;
    if(run->temp){
        if(glass->misc2[3]!=0){
            /* Each level blurs the last further; the result leans toward it
               where the line asks for at least that level's blur. */
            id<MTLTexture> cur=run->source,res=run->source;
            id<MTLTexture> blurs[2]={run->extra[0],run->extra[1]},results[2]={run->extra[2],run->output};
            for(uint32_t k=0;k<run->levels;k++){
                id<MTLTexture> next=cur==blurs[0]?blurs[1]:blurs[0];
                if(levels[k].radius){if(glass_blur(s,commands,&levels[k],cur,run->temp,next,buffer,word_offset))return 2;cur=next;}
                id<MTLTexture> blended=res==results[0]?results[1]:results[0];
                id<MTLRenderCommandEncoder> encoder=glass_pass(commands,s->glass_blend,blended,res,cur);if(!encoder)return 2;
                const float range[2]={levels[k].lo,levels[k].hi};
                [encoder setFragmentBuffer:buffer offset:glass_offset atIndex:0];
                [encoder setFragmentBytes:range length:sizeof(range) atIndex:1];
                [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
                [encoder endEncoding];
                res=blended;
            }
            result=res;
        }else if(run->levels&&levels[0].radius){
            if(glass_blur(s,commands,&levels[0],run->source,run->temp,run->extra[0],buffer,word_offset))return 2;
            result=run->extra[0];
        }
    }
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=current;pass.colorAttachments[0].loadAction=MTLLoadActionLoad;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder=[commands renderCommandEncoderWithDescriptor:pass];if(!encoder)return 2;
    [encoder setRenderPipelineState:s->glass_shade];
    float w=(float)current.width,h=(float)current.height;
    const float quad[4]={run->out[0]/w*2-1,1-run->out[1]/h*2,run->out[2]/w*2-1,1-run->out[3]/h*2};
    [encoder setVertexBytes:quad length:sizeof(quad) atIndex:0];
    [encoder setFragmentBuffer:buffer offset:glass_offset atIndex:0];
    [encoder setFragmentTexture:run->source atIndex:0];[encoder setFragmentTexture:result atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    s->stats.effect_passes++;
    return 0;
}
static int encode(ZigMetalRenderer *s,id<MTLCommandBuffer> commands,id<MTLTexture> target){
    if(s->capture_depth)return 2;
    size_t brush_offset=((size_t)s->instance_len*sizeof(ZmInstance)+255)&~(size_t)255;
    size_t word_offset=(brush_offset+sizeof(ZmBrush)*(s->brush_len?s->brush_len:1)+255)&~(size_t)255;
    size_t bytes=word_offset+(size_t)(s->word_len?s->word_len:4)*4;
    id<MTLBuffer> buffer=frame_buffer(s,bytes);if(!buffer)return 2;
    if(s->instance_len)memcpy(buffer.contents,s->instances,(size_t)s->instance_len*sizeof(ZmInstance));
    if(s->brush_len)memcpy((uint8_t *)buffer.contents+brush_offset,s->brushes,sizeof(ZmBrush)*s->brush_len);
    if(s->word_len)memcpy((uint8_t *)buffer.contents+word_offset,s->words,(size_t)s->word_len*4);
    ZmLevel levels[ZM_EFFECT_DEPTH+1];uint32_t depth=0;
    levels[0]=(ZmLevel){target,{0,0},0};
    id<MTLRenderCommandEncoder> encoder=nil;
    int failed=0;
#define ZM_OPEN() do{if(!encoder){encoder=open_level(s,commands,&levels[depth],depth==0,buffer,brush_offset,word_offset);if(!encoder){failed=1;goto done;}}}while(0)
#define ZM_CLOSE() do{if(encoder){[encoder endEncoding];encoder=nil;}}while(0)
    for(uint32_t k=0;k<s->batch_len;k++){
        const ZmBatch *b=&s->batches[k];
        switch(b->op){
        case OP_DRAW:{
            ZM_OPEN();
            size_t offset=(size_t)b->first*sizeof(ZmInstance);
            [encoder setVertexBuffer:buffer offset:offset atIndex:1];[encoder setFragmentBuffer:buffer offset:offset atIndex:1];
            [encoder setRenderPipelineState:b->replace?s->replace_pipeline:s->pipeline];
            ZmUniforms uniforms={(float)levels[depth].texture.width,(float)levels[depth].texture.height,s->scale,b->opacity,{levels[depth].origin[0],levels[depth].origin[1]},{0,0}};
            [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
            [encoder setFragmentTexture:b->texture?b->texture:s->blank atIndex:0];[encoder setFragmentTexture:b->mask?b->mask:s->blank atIndex:1];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:b->count];
            break;
        }
        case OP_CAPTURE:{
            ZM_CLOSE();
            if(depth==ZM_EFFECT_DEPTH){failed=1;goto done;}
            const ZmRun *run=&s->runs[b->run];
            levels[++depth]=(ZmLevel){run->source,{run->origin[0],run->origin[1]},0};
            break;
        }
        case OP_EFFECT:{
            /* A capture nothing drew into is still cleared. */
            ZM_OPEN();ZM_CLOSE();
            if(depth==0){failed=1;goto done;}
            const ZmRun *run=&s->runs[b->run];
            if(run->kind==RUN_EFFECT&&run->has_pass){
                const float quad[4]={-1,1,1,-1},origin[2]={0,0};
                if(run_effect(s,commands,run,run->output,MTLLoadActionDontCare,quad,origin,run->source,buffer,word_offset)){failed=1;goto done;}
            }else if(run->kind==RUN_GAUSSIAN){
                /* Horizontal into temp, vertical into the output. */
                if(filter_pass(s,commands,run->source,run->temp,0,buffer,word_offset+(size_t)run->word_offset*4)||filter_pass(s,commands,run->temp,run->output,1,buffer,word_offset+(size_t)run->word_offset*4)){failed=1;goto done;}
            }
            depth--;
            break;
        }
        case OP_BACKDROP:{
            ZM_OPEN();ZM_CLOSE();
            const ZmRun *run=&s->runs[b->run];id<MTLTexture> current=levels[depth].texture;
            id<MTLBlitCommandEncoder> blit=[commands blitCommandEncoder];if(!blit){failed=1;goto done;}
            [blit copyFromTexture:current sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(run->region[0],run->region[1],0) sourceSize:MTLSizeMake(run->region[2]-run->region[0],run->region[3]-run->region[1],1) toTexture:run->source destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
            [blit endEncoding];
            float w=(float)current.width,h=(float)current.height;
            const float quad[4]={run->out[0]/w*2-1,1-run->out[1]/h*2,run->out[2]/w*2-1,1-run->out[3]/h*2};
            const float origin[2]={(float)run->out[0],(float)run->out[1]};
            if(run_effect(s,commands,run,current,MTLLoadActionLoad,quad,origin,run->source,buffer,word_offset)){failed=1;goto done;}
            break;
        }
        case OP_GLASS:{
            ZM_OPEN();ZM_CLOSE();
            if(encode_glass(s,commands,&s->runs[b->run],levels[depth].texture,buffer,word_offset)){failed=1;goto done;}
            break;
        }
        }
    }
    if(depth!=0)failed=1;
    /* A frame that drew nothing is still cleared. */
    else ZM_OPEN();
done:
    ZM_CLOSE();
#undef ZM_OPEN
#undef ZM_CLOSE
    NSMutableArray *free_buffers=s->free_buffers,*free_captures=s->free_captures;
    NSArray *captures=[s->frame_captures copy];[s->frame_captures removeAllObjects];
    [commands addCompletedHandler:^(id<MTLCommandBuffer> done){
        (void)done;
        @synchronized(free_buffers){[free_buffers addObject:buffer];}
        if([captures count])@synchronized(free_captures){[free_captures addObjectsFromArray:captures];}
    }];
    if(failed)return 2;
    s->stats.frames++;s->stats.instances+=s->instance_len;s->stats.batches+=s->batch_len;
    sweep_if_due(s);
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
        id<MTLCommandBuffer> commands=[s->queue commandBuffer];if(!commands){s->back_valid=0;s->generation++;reset_frame(s);return 2;}
        if(encode(s,commands,s->back)){s->back_valid=0;s->generation++;reset_frame(s);return 2;}
        id<MTLBlitCommandEncoder> blit=[commands blitCommandEncoder];
        if(!blit||drawable.texture.width!=s->back.width||drawable.texture.height!=s->back.height){[blit endEncoding];s->back_valid=0;s->generation++;reset_frame(s);return 2;}
        [blit copyFromTexture:s->back sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(s->width,s->height,1) toTexture:drawable.texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
        [blit endEncoding];
        s->back_valid=1;
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
        if(s->lost){reset_frame(s);return 2;}
        id<MTLCommandBuffer> commands=[s->queue commandBuffer];if(!commands)return 2;
        if(encode(s,commands,s->offscreen_target)){reset_frame(s);return 2;}
        [commands commit];[commands waitUntilCompleted];
        reset_frame(s);
        /* A removed device loses the domain's, as a frame of another
           renderer of it would find. */
        int removed=s->loss_fault||(commands.status==MTLCommandBufferStatusError&&commands.error.code==ZM_MTL_ERROR_DEVICE_REMOVED);
        s->loss_fault=0;
        if(removed){ZigMetalDomain *domain=s->domain;if(domain)domain_lose(domain);return 3;}
        if(commands.status!=MTLCommandBufferStatusCompleted)return 2;
        if(pixels)[s->offscreen_target getBytes:pixels bytesPerRow:stride fromRegion:MTLRegionMake2D(0,0,s->width,s->height) mipmapLevel:0];
    }
    return 0;
}
void zmtl_abort(void *p){ZigMetalRenderer *s=R(p);s->drawing=0;reset_frame(s);}
/* The kept frame no longer holds what a frame expects to draw over. */
void zmtl_forget_plane(void *p){ZigMetalRenderer *s=R(p);s->back_valid=0;s->generation++;}
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

/* Device domains. A domain's renderers draw with its device; its textures
   are uploaded once and drawn by any of them (zmtl_texture). Losing the
   device (a removed GPU, or a test's injection) drops every texture and
   every renderer's objects of that device at once, and bumps the epoch's
   generation; zgpu_domain_recreate takes the system's device again, and
   each renderer takes it in zmtl_rebuild. Stop drops them for good. */
size_t zgpu_domain_size(void){return class_getInstanceSize([ZigMetalDomain class]);}
static ZigMetalDomain *D(void *p){return (__bridge ZigMetalDomain *)p;}
static int domain_create_device(ZigMetalDomain *d){
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();if(!device)return 0;
    id<MTLCommandQueue> queue=[device newCommandQueue];if(!queue)return 0;
    d->device=device;d->queue=queue;d->device_creations++;return 1;
}
/* What a renderer made with its device goes with it; the layer too, as
   one names its device. */
static void renderer_drop_device(ZigMetalRenderer *s){
    s->lost=1;s->stats.device_losses++;
    drop_layer(s);s->hidden=1;
    s->queue=nil;s->pipeline=s->replace_pipeline=s->filter_pipeline=s->glass_filter=s->glass_blend=s->glass_shade=nil;
    s->linear_sampler=s->nearest_sampler=s->mask_sampler=nil;s->blank=nil;
    s->back=nil;s->back_valid=0;s->generation++;s->offscreen_target=nil;s->front=nil;s->captured=nil;
    reset_frame(s);
    @synchronized(s->free_captures){[s->free_captures removeAllObjects];}
    @synchronized(s->free_buffers){[s->free_buffers removeAllObjects];}
    s->atlas=nil;[s->glyphs removeAllObjects];
    for(NSUInteger k=0;k<[s->slots count];k++)s->slots[k]=[NSNull null];
    s->candidate=nil;[s->prepared_keys removeAllObjects];[s->prepared_textures removeAllObjects];
    for(int k=0;k<ZM_EFFECT_SLOTS;k++)s->effect_pipelines[k]=nil;
    s->archive=nil;s->archive_dirty=0;
    s->device=nil;
}
static void domain_drop_device(ZigMetalDomain *d){
    for(unsigned i=0;i<ZI_IMAGE_SLOTS;i++)d->textures[i]=nil;
    d->queue=nil;d->device=nil;
}
static void domain_lose(ZigMetalDomain *d){
    if(!d||d->epoch->status!=1)return;
    d->epoch->status=2;
    if(d->epoch->generation==UINT64_MAX)d->epoch->status=4;else d->epoch->generation++;
    d->device_losses++;
    /* The owner revokes what it lent out before anything is dropped. */
    d->release_callback(d->callback_context,1);
    @autoreleasepool{
        for(ZigMetalRenderer *s in [d->renderers allObjects])renderer_drop_device(s);
        domain_drop_device(d);
    }
    d->release_callback(d->callback_context,0);
}
void *zgpu_domain_create(GpuDomainEpoch *epoch,int driver,void *context,void (*callback)(void *,int),int32_t *out){
    /* Metal has no software device. */
    if(driver){*out=ZM_INVALID;return NULL;}
    @autoreleasepool{
        ZigMetalDomain *d=[[ZigMetalDomain alloc] init];atomic_fetch_add(&live_objects,1);
        d->epoch=epoch;d->callback_context=context;d->release_callback=callback;
        d->renderers=[NSHashTable weakObjectsHashTable];
        if(!domain_create_device(d)){*out=ZM_UNEXPECTED;return NULL;}
        epoch->status=1;*out=ZM_OK;
        return (__bridge_retained void *)d;
    }
}
void zgpu_domain_stop(void *p){
    ZigMetalDomain *d=D(p);if(!d||d->epoch->status==3)return;
    d->epoch->status=3;
    d->release_callback(d->callback_context,1);
    @autoreleasepool{
        for(ZigMetalRenderer *s in [d->renderers allObjects])renderer_drop_device(s);
        domain_drop_device(d);
    }
    d->release_callback(d->callback_context,0);
}
void zgpu_domain_destroy(void *p){
    if(!p)return;
    zgpu_domain_stop(p);
    @autoreleasepool{(void)(__bridge_transfer ZigMetalDomain *)p;}
}
int32_t zgpu_domain_recreate(void *p){
    ZigMetalDomain *d=D(p);if(!d||d->epoch->status!=2)return ZM_UNEXPECTED;
    @autoreleasepool{if(!domain_create_device(d))return ZM_DEVICE_REMOVED;}
    d->epoch->status=1;return ZM_OK;
}
static id<MTLTexture> domain_texture(ZigMetalDomain *d,uint32_t width,uint32_t height,uint32_t levels){
    MTLTextureDescriptor *t=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:levels>1];
    t.mipmapLevelCount=levels;t.usage=MTLTextureUsageShaderRead;t.storageMode=MTLStorageModeShared;
    id<MTLTexture> texture=[d->device newTextureWithDescriptor:t];
    if(texture)d->texture_creations++;
    return texture;
}
/* Copies the levels into a new texture in slot. fault (one-based) fails
   that level's copy, for tests. */
const GpuTextureToken *zgpu_domain_upload(void *p,uint32_t slot,uint64_t identity,const ZiImageLevel *levels,uint32_t count,uint32_t fault,int32_t *out){
    ZigMetalDomain *d=D(p);
    if(!d||d->epoch->status!=1||slot>=ZI_IMAGE_SLOTS||d->tokens[slot].identity||!identity||!count||count>ZI_IMAGE_LEVELS||levels[0].width>ZM_TEXTURE_LIMIT||levels[0].height>ZM_TEXTURE_LIMIT){*out=ZM_INVALID;return NULL;}
    @autoreleasepool{
        id<MTLTexture> texture=domain_texture(d,levels[0].width,levels[0].height,count);
        if(!texture){*out=ZM_NO_MEMORY;return NULL;}
        for(uint32_t i=0;i<count;i++){
            if(fault==i+1){*out=ZM_NO_MEMORY;return NULL;}
            [texture replaceRegion:MTLRegionMake2D(0,0,levels[i].width,levels[i].height) mipmapLevel:i withBytes:levels[i].pixels bytesPerRow:levels[i].stride];
        }
        d->textures[slot]=texture;
    }
    d->tokens[slot]=(GpuTextureToken){identity,d->epoch->generation,levels[0].width,levels[0].height,count,0};
    *out=ZM_OK;return &d->tokens[slot];
}
void zgpu_domain_release_texture(void *p,uint32_t slot){
    ZigMetalDomain *d=D(p);if(!d||slot>=ZI_IMAGE_SLOTS)return;
    d->textures[slot]=nil;memset(&d->tokens[slot],0,sizeof(d->tokens[slot]));
}
void zgpu_domain_stats(void *p,DomainStats *stats){
    memset(stats,0,sizeof(*stats));ZigMetalDomain *d=D(p);if(!d)return;
    stats->objects=(d->device!=nil)+(d->queue!=nil);
    for(unsigned i=0;i<ZI_IMAGE_SLOTS;i++)stats->objects+=d->textures[i]!=nil;
    stats->devices=d->device_creations;stats->losses=d->device_losses;stats->bitmaps=d->texture_creations;
}
void zgpu_domain_inject_loss(void *p){domain_lose(D(p));}

/* A renderer drawing with the domain's device. */
void *zmtl_create_in_domain(void *p,int *error){
    ZigMetalDomain *d=D(p);if(!d||d->epoch->status!=1||!d->device){*error=3;return NULL;}
    @autoreleasepool{
        ZigMetalRenderer *s=new_renderer(d->device,error);if(!s)return NULL;
        s->domain=d;[d->renderers addObject:s];
        return (__bridge_retained void *)s;
    }
}
/* Takes the domain's device again after a loss. 0 ready, 1 no domain, 2
   the domain has no device, 3 failed. */
int zmtl_rebuild(void *p){
    ZigMetalRenderer *s=R(p);ZigMetalDomain *d=s->domain;if(!d)return 1;
    if(!s->lost)return 0;
    if(d->epoch->status!=1||!d->device)return 2;
    @autoreleasepool{
        s->device=d->device;s->queue=[s->device newCommandQueue];
        if(!s->queue||!create_pipeline(s)){s->device=nil;s->queue=nil;return 3;}
    }
    s->lost=0;s->stats.device_creations++;return 0;
}
/* A domain texture, by its token, drawn as an image is. */
int zmtl_texture(void *p,const GpuTextureToken *token,const ZiImagePlan *plan){
    ZigMetalRenderer *s=R(p);ZigMetalDomain *d=s->domain;
    if(!d||!s->drawing||d->epoch->status!=1||!token||!token->identity||token->generation!=d->epoch->generation)return 1;
    for(unsigned i=0;i<ZI_IMAGE_SLOTS;i++)if(&d->tokens[i]==token){
        if(plan->level>=token->levels)return 1;
        return draw_image(s,d->textures[i],plan);
    }
    return 1;
}
void zmtl_inject_loss(void *p){R(p)->loss_fault=1;}

/* Offscreen surfaces (src/ui/gpu_offscreen_native.zig): a frame drawn
   into the work target becomes the front, which snapshots copy. */
void zmtl_offscreen_commit(void *p){
    ZigMetalRenderer *s=R(p);id<MTLTexture> work=s->front;s->front=s->offscreen_target;s->offscreen_target=work;
    /* The next frame's target is made now, so that frames after the
       first make none. */
    if(!s->offscreen_target&&s->front&&s->device){
        MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:s->front.width height:s->front.height mipmapped:NO];
        d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;d.storageMode=MTLStorageModeShared;
        s->offscreen_target=[s->device newTextureWithDescriptor:d];
        if(s->offscreen_target)s->stats.offscreen_targets++;
    }
}
/* Both targets of a surface made up front, so that rendering makes none:
   the first frame draws into one and the other waits as the next. */
int zmtl_offscreen_prepare(void *p,uint32_t width,uint32_t height){
    ZigMetalRenderer *s=R(p);if(s->drawing||s->lost||!s->device||!width||!height)return 1;
    @autoreleasepool{
        MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
        d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;d.storageMode=MTLStorageModeShared;
        if(!s->offscreen_target||s->offscreen_target.width!=width||s->offscreen_target.height!=height){
            s->offscreen_target=[s->device newTextureWithDescriptor:d];if(!s->offscreen_target)return 1;
            s->stats.offscreen_targets++;
        }
        if(!s->front||s->front.width!=width||s->front.height!=height){
            s->front=[s->device newTextureWithDescriptor:d];if(!s->front)return 1;
            s->stats.offscreen_targets++;
        }
    }
    return 0;
}
uint32_t zmtl_offscreen_objects(void *p){ZigMetalRenderer *s=R(p);return (s->front!=nil)+(s->offscreen_target!=nil);}
int zmtl_read_front(void *p,uint32_t *pixels,uint32_t width,uint32_t height){
    ZigMetalRenderer *s=R(p);id<MTLTexture> t=s->front;if(!t||t.width!=width||t.height!=height)return 1;
    [t getBytes:pixels bytesPerRow:(NSUInteger)width*4 fromRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0];
    return 0;
}
/* Copies the surface's front into a new texture in slot. fault: 1 fails
   before the texture is made, 2 after, 3 as a removed device. */
const GpuTextureToken *zgpu_snapshot_offscreen(void *domain,void *renderer,uint32_t slot,uint64_t identity,uint32_t width,uint32_t height,uint32_t fault,int32_t *out){
    ZigMetalDomain *d=D(domain);ZigMetalRenderer *s=R(renderer);*out=ZM_INVALID;
    if(!d||d->epoch->status!=1||!s||s->domain!=d||s->lost||s->drawing||!s->front||s->front.width!=width||s->front.height!=height||slot>=ZI_IMAGE_SLOTS||d->tokens[slot].identity||!identity)return NULL;
    @autoreleasepool{
        if(fault==1){*out=ZM_NO_MEMORY;return NULL;}
        id<MTLTexture> texture=domain_texture(d,width,height,1);
        if(!texture||fault==2){*out=ZM_NO_MEMORY;return NULL;}
        id<MTLCommandBuffer> commands=[d->queue commandBuffer];
        id<MTLBlitCommandEncoder> blit=[commands blitCommandEncoder];
        if(!commands||!blit){*out=ZM_UNEXPECTED;return NULL;}
        [blit copyFromTexture:s->front sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(width,height,1) toTexture:texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
        [blit endEncoding];[commands commit];[commands waitUntilCompleted];
        if(fault==3||(commands.status==MTLCommandBufferStatusError&&commands.error.code==ZM_MTL_ERROR_DEVICE_REMOVED)){*out=ZM_DEVICE_REMOVED;domain_lose(d);return NULL;}
        if(commands.status!=MTLCommandBufferStatusCompleted){*out=ZM_UNEXPECTED;return NULL;}
        d->textures[slot]=texture;
    }
    d->tokens[slot]=(GpuTextureToken){identity,d->epoch->generation,width,height,1,0};
    *out=ZM_OK;return &d->tokens[slot];
}

/* Test hooks. */
void zmtl_test_capture(void *p,int enable){ZigMetalRenderer *s=R(p);s->capture=enable;if(!enable)s->captured=nil;}
/* 0xAARRGGBB of the last frame presented while capturing. */
uint32_t zmtl_test_pixel(void *p,uint32_t x,uint32_t y){
    ZigMetalRenderer *s=R(p);id<MTLTexture> t=s->captured;if(!t||x>=t.width||y>=t.height)return 0;
    uint8_t px[4];[t getBytes:px bytesPerRow:4 fromRegion:MTLRegionMake2D(x,y,1,1) mipmapLevel:0];
    return ((uint32_t)px[3]<<24)|((uint32_t)px[2]<<16)|((uint32_t)px[1]<<8)|px[0];
}
/* The last frame presented while capturing, width x height 0xAARRGGBB
   pixels; 0 when it has another size. */
int zmtl_test_pixels(void *p,uint32_t *out,uint32_t width,uint32_t height){
    ZigMetalRenderer *s=R(p);id<MTLTexture> t=s->captured;if(!t||t.width!=width||t.height!=height)return 0;
    [t getBytes:out bytesPerRow:(NSUInteger)width*4 fromRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0];
    return 1;
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
