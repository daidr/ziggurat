#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define NO_STRICT
#define D2D_USE_C_DEFINITIONS
#include <windows.h>
#include <initguid.h>
#include <d3d11.h>
#include <dxgi.h>
#include <d2d1_1.h>
#include <d2d1effectauthor.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include "gradient_probe_shader.h"

/* The bundled C headers leave these interfaces forward declared. Only the
   actually called slots are typed; their inherited positions are asserted. */
typedef struct ID2D1Image ID2D1Image;
typedef struct EffectVtable {
    void *query,*add,*release,*count,*name,*name_length,*type,*index,*set_by_name;
    HRESULT (STDMETHODCALLTYPE *SetValue)(ID2D1Effect *,UINT32,D2D1_PROPERTY_TYPE,const BYTE *,UINT32);
    void *get_by_name,*get,*value_size,*sub_properties,*set_input,*input_count,*get_input,*get_input_count;
    void (STDMETHODCALLTYPE *GetOutput)(ID2D1Effect *,ID2D1Image **);
} EffectVtable;
struct ID2D1Effect {const EffectVtable *lpVtbl;};
typedef struct DrawInfoVtable {
    HRESULT (STDMETHODCALLTYPE *query)(ID2D1DrawInfo *,REFIID,void **);
    ULONG (STDMETHODCALLTYPE *add)(ID2D1DrawInfo *);
    ULONG (STDMETHODCALLTYPE *release)(ID2D1DrawInfo *);
    void *input_description,*output_buffer,*cached,*instruction_count;
    HRESULT (STDMETHODCALLTYPE *constants)(ID2D1DrawInfo *,const BYTE *,UINT32);
    void *texture,*vertex_constants;
    HRESULT (STDMETHODCALLTYPE *shader)(ID2D1DrawInfo *,REFGUID,D2D1_PIXEL_OPTIONS);
} DrawInfoVtable;
struct ID2D1DrawInfo {const DrawInfoVtable *lpVtbl;};
typedef struct EffectContextVtable {
    void *query,*add,*release,*dpi,*effect,*feature,*node,*blend,*border,*offset,*bounds;
    HRESULT (STDMETHODCALLTYPE *load_pixel_shader)(ID2D1EffectContext *,REFGUID,const BYTE *,UINT32);
} EffectContextVtable;
struct ID2D1EffectContext {const EffectContextVtable *lpVtbl;};
typedef struct GraphVtable {
    void *query,*add,*release,*inputs;
    HRESULT (STDMETHODCALLTYPE *single)(ID2D1TransformGraph *,ID2D1TransformNode *);
} GraphVtable;
struct ID2D1TransformGraph {const GraphVtable *lpVtbl;};
typedef struct DrawTransformVtable {
    HRESULT (STDMETHODCALLTYPE *query)(ID2D1DrawTransform *,REFIID,void **);
    ULONG (STDMETHODCALLTYPE *add)(ID2D1DrawTransform *);
    ULONG (STDMETHODCALLTYPE *release)(ID2D1DrawTransform *);
    UINT32 (STDMETHODCALLTYPE *inputs)(ID2D1DrawTransform *);
    HRESULT (STDMETHODCALLTYPE *output_to_inputs)(ID2D1DrawTransform *,const D2D1_RECT_L *,D2D1_RECT_L *,UINT32);
    HRESULT (STDMETHODCALLTYPE *inputs_to_output)(ID2D1DrawTransform *,const D2D1_RECT_L *,const D2D1_RECT_L *,UINT32,D2D1_RECT_L *,D2D1_RECT_L *);
    HRESULT (STDMETHODCALLTYPE *invalid)(ID2D1DrawTransform *,UINT32,D2D1_RECT_L,D2D1_RECT_L *);
    HRESULT (STDMETHODCALLTYPE *info)(ID2D1DrawTransform *,ID2D1DrawInfo *);
} DrawTransformVtable;
struct ID2D1DrawTransform {const DrawTransformVtable *lpVtbl;};
_Static_assert(sizeof(void *)==sizeof(void (*)(void)),"COM slot size");
_Static_assert(offsetof(EffectVtable,SetValue)==9*sizeof(void *),"effect set value slot");
_Static_assert(offsetof(EffectVtable,GetOutput)==18*sizeof(void *),"effect output slot");
_Static_assert(offsetof(DrawInfoVtable,constants)==7*sizeof(void *),"draw info constants slot");
_Static_assert(offsetof(DrawInfoVtable,shader)==10*sizeof(void *),"draw info shader slot");
_Static_assert(offsetof(EffectContextVtable,load_pixel_shader)==11*sizeof(void *),"effect shader slot");
_Static_assert(offsetof(GraphVtable,single)==4*sizeof(void *),"graph node slot");
_Static_assert(offsetof(DrawTransformVtable,info)==7*sizeof(void *),"draw transform info slot");

static const GUID effect_id={0xce1b78ab,0x6e78,0x45ee,{0xac,0x45,0xd8,0x7b,0x41,0x21,0xa0,0xa4}};
static const GUID shader_id={0x47d8054a,0x09e5,0x42b9,{0x9b,0xe7,0x24,0x1d,0xcb,0xce,0x18,0xf1}};
typedef struct Constants {float frame[4],axis[4],radial[4];uint32_t control[4];float positions[16][4],colors[16][4];} Constants;
_Static_assert(sizeof(Constants)==576,"HLSL cbuffer packing");
typedef struct Analytic {ID2D1EffectImpl effect;ID2D1DrawTransform draw;LONG refs;ID2D1DrawInfo *info;Constants values;} Analytic;
static LONG resources,instances;
static uint64_t creations,uploads;
#define OWN(value) do{if(value)InterlockedIncrement(&resources);}while(0)
#define DROP(value) do{if(value){IUnknown_Release((IUnknown *)(value));(value)=NULL;InterlockedDecrement(&resources);}}while(0)
static Analytic *from_draw(ID2D1DrawTransform *draw){return (Analytic *)((char *)draw - offsetof(Analytic,draw));}
static HRESULT query(Analytic *s,REFIID iid,void **out){
    if(!out)return E_POINTER;*out=NULL;
    if(IsEqualIID(iid,&IID_IUnknown)||IsEqualIID(iid,&IID_ID2D1EffectImpl))*out=&s->effect;
    else if(IsEqualIID(iid,&IID_ID2D1DrawTransform)||IsEqualIID(iid,&IID_ID2D1Transform)||IsEqualIID(iid,&IID_ID2D1TransformNode))*out=&s->draw;
    else return E_NOINTERFACE;InterlockedIncrement(&s->refs);return S_OK;
}
static ULONG release(Analytic *s){ULONG refs=InterlockedDecrement(&s->refs);if(!refs){DROP(s->info);HeapFree(GetProcessHeap(),0,s);InterlockedDecrement(&instances);}return refs;}
static HRESULT STDMETHODCALLTYPE effect_query(IUnknown *self,REFIID iid,void **out){return query((Analytic *)self,iid,out);}
static ULONG STDMETHODCALLTYPE effect_add(IUnknown *self){return InterlockedIncrement(&((Analytic *)self)->refs);}
static ULONG STDMETHODCALLTYPE effect_release(IUnknown *self){return release((Analytic *)self);}
static HRESULT STDMETHODCALLTYPE draw_query(ID2D1DrawTransform *self,REFIID iid,void **out){return query(from_draw(self),iid,out);}
static ULONG STDMETHODCALLTYPE draw_add(ID2D1DrawTransform *self){return InterlockedIncrement(&from_draw(self)->refs);}
static ULONG STDMETHODCALLTYPE draw_release(ID2D1DrawTransform *self){return release(from_draw(self));}
static UINT32 STDMETHODCALLTYPE draw_inputs(ID2D1DrawTransform *self){(void)self;return 0;}
static HRESULT STDMETHODCALLTYPE output_to_inputs(ID2D1DrawTransform *self,const D2D1_RECT_L *out,D2D1_RECT_L *inputs,UINT32 count){(void)self;(void)out;(void)inputs;return count?E_INVALIDARG:S_OK;}
static HRESULT STDMETHODCALLTYPE inputs_to_output(ID2D1DrawTransform *self,const D2D1_RECT_L *inputs,const D2D1_RECT_L *opaque,UINT32 count,D2D1_RECT_L *out,D2D1_RECT_L *out_opaque){
    (void)inputs;(void)opaque;if(count)return E_INVALIDARG;Constants *v=&from_draw(self)->values;*out=(D2D1_RECT_L){0,0,(LONG)v->control[1],(LONG)v->control[2]};*out_opaque=(D2D1_RECT_L){0};return S_OK;
}
static HRESULT STDMETHODCALLTYPE invalid_rect(ID2D1DrawTransform *self,UINT32 index,D2D1_RECT_L in,D2D1_RECT_L *out){(void)self;(void)index;(void)in;(void)out;return E_INVALIDARG;}
static HRESULT STDMETHODCALLTYPE draw_info(ID2D1DrawTransform *self,ID2D1DrawInfo *info){
    Analytic *s=from_draw(self);DROP(s->info);s->info=info;info->lpVtbl->add(info);OWN(s->info);
    return info->lpVtbl->shader(info,&shader_id,D2D1_PIXEL_OPTIONS_NONE);
}
static const DrawTransformVtable draw_vtable={draw_query,draw_add,draw_release,draw_inputs,output_to_inputs,inputs_to_output,invalid_rect,draw_info};
static HRESULT STDMETHODCALLTYPE initialize(ID2D1EffectImpl *self,ID2D1EffectContext *context,ID2D1TransformGraph *graph){
    HRESULT hr=context->lpVtbl->load_pixel_shader(context,&shader_id,gradient_probe_shader,sizeof(gradient_probe_shader));
    if(FAILED(hr))return hr;return graph->lpVtbl->single(graph,(ID2D1TransformNode *)&((Analytic *)self)->draw);
}
static HRESULT STDMETHODCALLTYPE prepare(ID2D1EffectImpl *self,D2D1_CHANGE_TYPE change){
    (void)change;Analytic *s=(Analytic *)self;if(!s->info)return E_UNEXPECTED;uploads++;
    return s->info->lpVtbl->constants(s->info,(const BYTE *)&s->values,sizeof(s->values));
}
static HRESULT STDMETHODCALLTYPE set_graph(ID2D1EffectImpl *self,ID2D1TransformGraph *graph){(void)self;(void)graph;return E_NOTIMPL;}
static const ID2D1EffectImplVtbl effect_vtable={{effect_query,effect_add,effect_release},initialize,prepare,set_graph};
static HRESULT CALLBACK create_effect(IUnknown **out){
    Analytic *s=HeapAlloc(GetProcessHeap(),HEAP_ZERO_MEMORY,sizeof(*s));if(!s)return E_OUTOFMEMORY;
    s->effect.lpVtbl=&effect_vtable;s->draw.lpVtbl=&draw_vtable;s->refs=1;s->values.control[1]=512;s->values.control[2]=256;
    *out=(IUnknown *)&s->effect;InterlockedIncrement(&instances);creations++;return S_OK;
}
static HRESULT CALLBACK set_values(IUnknown *self,const BYTE *bytes,UINT32 size){
    if(!bytes||size!=sizeof(Constants))return E_INVALIDARG;Constants value;memcpy(&value,bytes,sizeof(value));
    if(value.control[0]<2||value.control[0]>16||value.control[1]>32768||value.control[2]>32768)return E_INVALIDARG;
    ((Analytic *)self)->values=value;return S_OK;
}
static HRESULT CALLBACK get_values(const IUnknown *self,BYTE *bytes,UINT32 capacity,UINT32 *size){
    if(size)*size=sizeof(Constants);if(bytes){if(capacity<sizeof(Constants))return E_NOT_SUFFICIENT_BUFFER;memcpy(bytes,&((const Analytic *)self)->values,sizeof(Constants));}return S_OK;
}
static const WCHAR effect_xml[]=L"<?xml version='1.0'?><Effect><Property name='DisplayName' type='string' value='Analytic gradient probe'/><Property name='Author' type='string' value='Ziggurat'/><Property name='Category' type='string' value='Drawing'/><Property name='Description' type='string' value='Independent bounded shader experiment'/><Inputs/><Property name='Config' type='blob'><Property name='DisplayName' type='string' value='Config'/></Property></Effect>";
typedef struct Device {ID3D11Device *d3d;IDXGIDevice *dxgi;ID2D1Factory1 *factory;ID2D1Device *device;ID2D1DeviceContext *context;ID2D1Effect *effect;ID2D1Bitmap1 *target,*readback;} Device;
static void destroy(Device *s){
    if(s->context)s->context->lpVtbl->SetTarget(s->context,NULL);DROP(s->readback);DROP(s->target);DROP(s->effect);DROP(s->context);DROP(s->device);
    if(s->factory)s->factory->lpVtbl->UnregisterEffect(s->factory,&effect_id);DROP(s->factory);DROP(s->dxgi);DROP(s->d3d);
}
#define TRY(call) do{HRESULT _hr=(call);if(FAILED(_hr)){printf("native failure %s:%d HRESULT=%08lx\n",#call,__LINE__,(unsigned long)_hr);return _hr;}}while(0)
static HRESULT device_init(Device *s,int warp){
    D3D_FEATURE_LEVEL level;TRY(D3D11CreateDevice(NULL,warp?D3D_DRIVER_TYPE_WARP:D3D_DRIVER_TYPE_HARDWARE,NULL,D3D11_CREATE_DEVICE_BGRA_SUPPORT|D3D11_CREATE_DEVICE_SINGLETHREADED,NULL,0,D3D11_SDK_VERSION,&s->d3d,&level,NULL));OWN(s->d3d);
    TRY(ID3D11Device_QueryInterface(s->d3d,&IID_IDXGIDevice,(void **)&s->dxgi));OWN(s->dxgi);
    D2D1_FACTORY_OPTIONS options={0};TRY(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,&IID_ID2D1Factory1,&options,(void **)&s->factory));OWN(s->factory);
    TRY(s->factory->lpVtbl->CreateDevice(s->factory,s->dxgi,&s->device));OWN(s->device);
    TRY(s->device->lpVtbl->CreateDeviceContext(s->device,D2D1_DEVICE_CONTEXT_OPTIONS_NONE,&s->context));OWN(s->context);
    const D2D1_PROPERTY_BINDING binding={L"Config",set_values,get_values};TRY(s->factory->lpVtbl->RegisterEffectFromString(s->factory,&effect_id,effect_xml,&binding,1,create_effect));
    TRY(s->context->lpVtbl->CreateEffect(s->context,&effect_id,&s->effect));OWN(s->effect);return S_OK;
}
static HRESULT surface(Device *s,UINT width,UINT height,float scale){
    s->context->lpVtbl->SetTarget(s->context,NULL);DROP(s->readback);DROP(s->target);
    D2D1_BITMAP_PROPERTIES1 properties={{DXGI_FORMAT_B8G8R8A8_UNORM,D2D1_ALPHA_MODE_PREMULTIPLIED},96*scale,96*scale,D2D1_BITMAP_OPTIONS_TARGET,NULL};
    const D2D1_SIZE_U size={width,height};TRY(s->context->lpVtbl->CreateBitmap(s->context,size,NULL,0,&properties,&s->target));OWN(s->target);
    properties.bitmapOptions=D2D1_BITMAP_OPTIONS_CPU_READ|D2D1_BITMAP_OPTIONS_CANNOT_DRAW;
    TRY(s->context->lpVtbl->CreateBitmap(s->context,size,NULL,0,&properties,&s->readback));OWN(s->readback);
    ID2D1RenderTarget_SetDpi((ID2D1RenderTarget *)s->context,96*scale,96*scale);s->context->lpVtbl->SetTarget(s->context,(ID2D1Image *)s->target);return S_OK;
}
typedef struct Stop {float offset;uint32_t rgba;} Stop;
typedef struct Fixture {const char *name;int radial;float x0,y0,x1,y1;Stop stops[16];unsigned count;} Fixture;
static Constants configuration(const Fixture *f,float scale,unsigned width,unsigned height){
    Constants v={0};v.frame[0]=(float)width/(2*scale);v.frame[1]=(float)height/(2*scale);v.frame[2]=1/scale;v.frame[3]=(float)f->radial;
    v.control[0]=f->count;v.control[1]=width;v.control[2]=height;
    double dx=(double)f->x1-f->x0,dy=(double)f->y1-f->y0,length=hypot(dx,dy),q0=0;
    if(!f->radial){v.axis[0]=(float)(dx/length);v.axis[1]=(float)(dy/length);}
    else{
        double rx=1.0/f->x1,ry=1.0/f->y1,cx=(double)f->x0-v.frame[0],cy=(double)f->y0-v.frame[1];
        v.axis[2]=(float)(rx*rx);v.axis[3]=(float)(ry*ry);v.radial[0]=(float)(-2*cx*rx*rx);v.radial[1]=(float)(-2*cy*ry*ry);q0=(cx*rx)*(cx*rx)+(cy*ry)*(cy*ry);
    }
    for(unsigned i=0;i<f->count;i++){
        double offset=f->stops[i].offset;
        if(f->radial){v.positions[i][0]=(float)(q0-offset*offset);v.positions[i][1]=(float)offset;}
        else{
            double sx=(1-offset)*(double)f->x0+offset*(double)f->x1,sy=(1-offset)*(double)f->y0+offset*(double)f->y1;
            v.positions[i][0]=(float)((sx-v.frame[0])*v.axis[0]+(sy-v.frame[1])*v.axis[1]);
        }
        uint32_t color=f->stops[i].rgba;double alpha=(color&255)/255.0;
        v.colors[i][0]=(float)((color>>24)/255.0*alpha);v.colors[i][1]=(float)(((color>>16)&255)/255.0*alpha);v.colors[i][2]=(float)(((color>>8)&255)/255.0*alpha);v.colors[i][3]=(float)alpha;
    }
    return v;
}
static void rgba(uint32_t value,double out[4]){out[3]=(value&255)/255.0;out[0]=(value>>24)/255.0*out[3];out[1]=((value>>16)&255)/255.0*out[3];out[2]=((value>>8)&255)/255.0*out[3];}
static double parameter(const Fixture *f,double x,double y){
    double dx=x-f->x0,dy=y-f->y0,t;
    if(f->radial)t=hypot(dx/f->x1,dy/f->y1);else{double vx=(double)f->x1-f->x0,vy=(double)f->y1-f->y0;t=(dx*vx+dy*vy)/(vx*vx+vy*vy);}
    return t;
}
static void oracle_parameter(const Fixture *f,double t,double out[4]){
    unsigned upper=0;while(upper<f->count&&f->stops[upper].offset<=t)upper++;
    if(!upper)rgba(f->stops[0].rgba,out);else if(upper==f->count)rgba(f->stops[f->count-1].rgba,out);else{
        double a[4],b[4],weight=(t-f->stops[upper-1].offset)/((double)f->stops[upper].offset-f->stops[upper-1].offset);
        rgba(f->stops[upper-1].rgba,a);rgba(f->stops[upper].rgba,b);for(unsigned c=0;c<4;c++)out[c]=a[c]+(b[c]-a[c])*weight;
    }
    for(unsigned c=0;c<3;c++)out[c]=round((out[c]+1-out[3])*255);out[3]=255;
}
static int boundary_mix(const Fixture *f,unsigned x,unsigned y,float scale,const uint8_t *pixel){
    double left=x/(double)scale,top=y/(double)scale,right=(x+1)/(double)scale,bottom=(y+1)/(double)scale;
    double low=INFINITY,high=-INFINITY;
    for(unsigned iy=0;iy<2;iy++)for(unsigned ix=0;ix<2;ix++){double t=parameter(f,ix?right:left,iy?bottom:top);low=fmin(low,t);high=fmax(high,t);}
    if(f->radial)low=fmin(low,parameter(f,fmax(left,fmin(right,f->x0)),fmax(top,fmin(bottom,f->y0))));
    double colors[18][4];unsigned count=0;int crossed=0;
    oracle_parameter(f,low,colors[count++]);oracle_parameter(f,high,colors[count++]);
    for(unsigned i=0;i<f->count;i++)if(low<=f->stops[i].offset&&f->stops[i].offset<=high){
        crossed=1;rgba(f->stops[i].rgba,colors[count]);for(unsigned c=0;c<3;c++)colors[count][c]=round((colors[count][c]+1-colors[count][3])*255);count++;
    }
    if(!crossed)return 0;
    const double actual[3]={pixel[2],pixel[1],pixel[0]};
    for(unsigned a=0;a<count;a++)for(unsigned b=a;b<count;b++){
        double dot=0,norm=0;for(unsigned c=0;c<3;c++){double d=colors[b][c]-colors[a][c];dot+=(actual[c]-colors[a][c])*d;norm+=d*d;}
        double weight=norm?fmax(0,fmin(1,dot/norm)):0;int valid=1;
        for(unsigned c=0;c<3;c++)if(fabs(actual[c]-(colors[a][c]+(colors[b][c]-colors[a][c])*weight))>3)valid=0;
        if(valid)return 1;
    }
    return 0;
}
static HRESULT run_fixture(Device *s,const Fixture *f,float scale,int clip){
    unsigned width=(unsigned)(256*scale),height=(unsigned)(96*scale);TRY(surface(s,width,height,scale));
    Constants values=configuration(f,scale,width,height);TRY(s->effect->lpVtbl->SetValue(s->effect,0,D2D1_PROPERTY_TYPE_BLOB,(const BYTE *)&values,sizeof(values)));
    ID2D1RenderTarget_BeginDraw((ID2D1RenderTarget *)s->context);const D2D1_COLOR_F white={1,1,1,1};ID2D1RenderTarget_Clear((ID2D1RenderTarget *)s->context,&white);
    const D2D1_RECT_F clip_bounds={32,16,208,80};if(clip)ID2D1RenderTarget_PushAxisAlignedClip((ID2D1RenderTarget *)s->context,&clip_bounds,D2D1_ANTIALIAS_MODE_ALIASED);
    ID2D1Image *image=NULL;s->effect->lpVtbl->GetOutput(s->effect,&image);OWN(image);
    s->context->lpVtbl->DrawImage(s->context,image,NULL,NULL,D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR,D2D1_COMPOSITE_MODE_SOURCE_OVER);DROP(image);
    if(clip)ID2D1RenderTarget_PopAxisAlignedClip((ID2D1RenderTarget *)s->context);
    TRY(ID2D1RenderTarget_EndDraw((ID2D1RenderTarget *)s->context,NULL,NULL));
    TRY(ID2D1Bitmap_CopyFromBitmap((ID2D1Bitmap *)s->readback,NULL,(ID2D1Bitmap *)s->target,NULL));
    D2D1_MAPPED_RECT mapped;TRY(s->readback->lpVtbl->Map(s->readback,D2D1_MAP_OPTIONS_READ,&mapped));
    unsigned mismatches=0,boundary_pixels=0;
    for(unsigned y=0;y<height;y++)for(unsigned x=0;x<width;x++){
        double expected[4];oracle_parameter(f,parameter(f,(x+0.5)/scale,(y+0.5)/scale),expected);const uint8_t *pixel=mapped.bits+y*mapped.pitch+x*4;
        int outside=clip&&((x+0.5)/scale<32||(x+0.5)/scale>=208||(y+0.5)/scale<16||(y+0.5)/scale>=80);if(outside)expected[0]=expected[1]=expected[2]=255;
        int error=abs((int)pixel[2]-(int)expected[0])>3||abs((int)pixel[1]-(int)expected[1])>3||abs((int)pixel[0]-(int)expected[2])>3;
        if(error||pixel[3]!=255){if(!outside&&pixel[3]==255&&boundary_mix(f,x,y,scale,pixel))boundary_pixels++;else if(mismatches++<3)printf("mismatch %s scale=%g pixel=%u,%u actual=%u,%u,%u,%u expected=%g,%g,%g\n",f->name,scale,x,y,pixel[2],pixel[1],pixel[0],pixel[3],expected[0],expected[1],expected[2]);}
    }
    TRY(s->readback->lpVtbl->Unmap(s->readback));if(mismatches){printf("FAIL %s mismatches=%u\n",f->name,mismatches);return E_FAIL;}
    printf("PASS %s scale=%g clip=%d pixels=%u boundary_mixtures=%u\n",f->name,scale,clip,width*height,boundary_pixels);return S_OK;
}
static HRESULT multiple_draws(Device *s){
    TRY(surface(s,128,64,1));
    const Fixture red={"state-red",0,0,0,128,0,{{0,0xff0000ff},{1,0xff0000ff}},2};
    const Fixture blue={"state-blue",0,0,0,128,0,{{0,0x0000ffff},{1,0x0000ffff}},2};
    Constants a=configuration(&red,1,128,64),b=configuration(&blue,1,128,64);
    ID2D1RenderTarget_BeginDraw((ID2D1RenderTarget *)s->context);const D2D1_COLOR_F white={1,1,1,1};ID2D1RenderTarget_Clear((ID2D1RenderTarget *)s->context,&white);
    ID2D1Image *image=NULL;s->effect->lpVtbl->GetOutput(s->effect,&image);OWN(image);
    const D2D1_RECT_F source={0,0,32,32};const D2D1_POINT_2F left={0,0},right={32,0};uint64_t before=uploads;
    TRY(s->effect->lpVtbl->SetValue(s->effect,0,D2D1_PROPERTY_TYPE_BLOB,(const BYTE *)&a,sizeof(a)));
    s->context->lpVtbl->DrawImage(s->context,image,&left,&source,D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR,D2D1_COMPOSITE_MODE_SOURCE_OVER);uint64_t first=uploads;
    TRY(s->effect->lpVtbl->SetValue(s->effect,0,D2D1_PROPERTY_TYPE_BLOB,(const BYTE *)&b,sizeof(b)));
    s->context->lpVtbl->DrawImage(s->context,image,&right,&source,D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR,D2D1_COMPOSITE_MODE_SOURCE_OVER);uint64_t second=uploads;DROP(image);
    TRY(ID2D1RenderTarget_EndDraw((ID2D1RenderTarget *)s->context,NULL,NULL));TRY(ID2D1Bitmap_CopyFromBitmap((ID2D1Bitmap *)s->readback,NULL,(ID2D1Bitmap *)s->target,NULL));
    D2D1_MAPPED_RECT map;TRY(s->readback->lpVtbl->Map(s->readback,D2D1_MAP_OPTIONS_READ,&map));const uint8_t *x=map.bits+16*map.pitch+16*4,*y=map.bits+16*map.pitch+48*4;
    int valid=x[2]==255&&x[1]==0&&x[0]==0&&y[2]==0&&y[1]==0&&y[0]==255;TRY(s->readback->lpVtbl->Unmap(s->readback));
    printf("multiple DrawImage snapshots: valid=%d PrepareForRender uploads before=%llu after-first=%llu after-second=%llu end=%llu\n",valid,(unsigned long long)before,(unsigned long long)first,(unsigned long long)second,(unsigned long long)uploads);
    return valid?S_OK:E_FAIL;
}
int main(void){
    Fixture fixtures[]={
        {"linear-hard",0,-3968,0,4224,0,{{0,0xff0000ff},{.5f,0xff0000ff},{.5f,0x0000ffff},{1,0x0000ffff}},4},
        {"linear-steep",0,-3968,0,4224,0,{{0,0xff0000ff},{.5f,0xff0000ff},{.500001f,0x0000ffff},{1,0x0000ffff}},4},
        {"linear-premultiplied",0,0,0,256,0,{{0,0xff000000},{.5f,0x00ff0080},{1,0x0000ffff}},3},
        {"radial-hard",1,-3968,48,8192,8192,{{0,0xff0000ff},{.5f,0xff0000ff},{.5f,0x0000ffff},{1,0x0000ffff}},4},
        {"radial-steep",1,-3968,48,8192,8192,{{0,0xff0000ff},{.5f,0xff0000ff},{.500001f,0x0000ffff},{1,0x0000ffff}},4},
        {"radial-premultiplied",1,128,48,128,48,{{0,0xff000000},{.5f,0x00ff0080},{1,0x0000ffff}},3},
        {"linear-reversed",0,4224,0,-3968,0,{{0,0xff0000ff},{.5f,0xff0000ff},{.5f,0x0000ffff},{1,0x0000ffff}},4},
        {"linear-diagonal",0,-3968,-4048,4224,4144,{{0,0xff000000},{.5f,0xff000080},{.5f,0x00ff0080},{1,0x0000ffff}},4},
        {"linear-large",0,-524160,0,524416,0,{{0,0xff0000ff},{.5f,0xff0000ff},{.500001f,0x0000ffff},{1,0x0000ffff}},4},
        {"radial-large",1,-524160,48,1048576,1048576,{{0,0xff0000ff},{.5f,0xff0000ff},{.500001f,0x0000ffff},{1,0x0000ffff}},4},
        {"radial-tiny",1,128.5f,48.5f,.125f,.0009765625f,{{0,0xff000000},{.5f,0x00ff0080},{1,0x0000ffff}},3},
        {"linear-16-stops",0,0,0,256,0,{{0}},16},
        {"radial-16-stops",1,128,48,128,48,{{0}},16},
    };
    for(unsigned fi=11;fi<13;fi++)for(unsigned i=0;i<16;i++)fixtures[fi].stops[i]=(Stop){(float)(i/2)/7,(i%3==0?0xff000000u:(i%3==1?0x00ff0080u:0x0000ffffu))};
    for(int warp=0;warp<2;warp++){
        Device device={0};HRESULT hr=device_init(&device,warp);if(FAILED(hr)){destroy(&device);return 1;}
        uint64_t created=creations;
        for(unsigned i=0;i<sizeof(fixtures)/sizeof(fixtures[0]);i++)for(unsigned si=0;si<3;si++){
            float scales[]={1,1.5f,2};for(int clip=0;clip<2;clip++){hr=run_fixture(&device,&fixtures[i],scales[si],clip);if(FAILED(hr)){destroy(&device);return 2;}}
        }
        hr=multiple_draws(&device);if(FAILED(hr)){destroy(&device);return 5;}
        if(creations!=created){puts("effect recreated during draw");destroy(&device);return 3;}
        destroy(&device);if(resources||instances){printf("leak resources=%ld instances=%ld\n",resources,instances);return 4;}
        printf("analytic gradient driver=%s effect_creations=%llu constant_uploads=%llu resources=0\n",warp?"warp":"hardware",(unsigned long long)creations,(unsigned long long)uploads);
    }
    return 0;
}
