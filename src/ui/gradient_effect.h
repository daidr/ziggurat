#ifndef ZIGGURAT_GRADIENT_EFFECT_H
#define ZIGGURAT_GRADIENT_EFFECT_H
#include <d2d1effectauthor.h>
#include <stddef.h>
#include "shaders/gradient_shader.h"
/* The bundled C headers leave these interfaces forward declared. Only the
   actually called slots are typed; their inherited positions are asserted. */
typedef struct ID2D1Image ID2D1Image;
typedef struct EffectVtable {
    void *query,*add,*release,*count,*name,*name_length,*type,*index,*set_by_name;
    HRESULT (STDMETHODCALLTYPE *SetValue)(ID2D1Effect *,UINT32,D2D1_PROPERTY_TYPE,const BYTE *,UINT32);
    void *get_by_name;
    HRESULT (STDMETHODCALLTYPE *GetValue)(ID2D1Effect *,UINT32,D2D1_PROPERTY_TYPE,BYTE *,UINT32);
    void *value_size,*sub_properties,*set_input,*input_count,*get_input,*get_input_count;
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
_Static_assert(offsetof(EffectVtable,GetValue)==11*sizeof(void *),"effect get value slot");
_Static_assert(offsetof(EffectVtable,GetOutput)==18*sizeof(void *),"effect output slot");
_Static_assert(offsetof(DrawInfoVtable,constants)==7*sizeof(void *),"draw info constants slot");
_Static_assert(offsetof(DrawInfoVtable,shader)==10*sizeof(void *),"draw info shader slot");
_Static_assert(offsetof(EffectContextVtable,load_pixel_shader)==11*sizeof(void *),"effect shader slot");
_Static_assert(offsetof(GraphVtable,single)==4*sizeof(void *),"graph node slot");
_Static_assert(offsetof(DrawTransformVtable,info)==7*sizeof(void *),"draw transform info slot");

static const GUID effect_id={0xce1b78ab,0x6e78,0x45ee,{0xac,0x45,0xd8,0x7b,0x41,0x21,0xa0,0xa4}};
static const GUID shader_id={0x47d8054a,0x09e5,0x42b9,{0x9b,0xe7,0x24,0x1d,0xcb,0xce,0x18,0xf1}};
#include "gradient_geometry.h"
typedef struct Analytic {ID2D1EffectImpl effect;ID2D1DrawTransform draw;LONG refs;ID2D1DrawInfo *info;Constants values;uint64_t uploads;} Analytic;
static Analytic *from_draw(ID2D1DrawTransform *draw){return (Analytic *)((char *)draw - offsetof(Analytic,draw));}
static HRESULT query(Analytic *s,REFIID iid,void **out){
    if(!out)return E_POINTER;*out=NULL;
    if(IsEqualIID(iid,&IID_IUnknown)||IsEqualIID(iid,&IID_ID2D1EffectImpl))*out=&s->effect;
    else if(IsEqualIID(iid,&IID_ID2D1DrawTransform)||IsEqualIID(iid,&IID_ID2D1Transform)||IsEqualIID(iid,&IID_ID2D1TransformNode))*out=&s->draw;
    else return E_NOINTERFACE;InterlockedIncrement(&s->refs);return S_OK;
}
static ULONG release(Analytic *s){ULONG refs=InterlockedDecrement(&s->refs);if(!refs){DROP(s->info);HeapFree(GetProcessHeap(),0,s);InterlockedDecrement(&live_resources);}return refs;}
static HRESULT STDMETHODCALLTYPE effect_query(IUnknown *self,REFIID iid,void **out){return query((Analytic *)self,iid,out);}
static ULONG STDMETHODCALLTYPE effect_add(IUnknown *self){return InterlockedIncrement(&((Analytic *)self)->refs);}
static ULONG STDMETHODCALLTYPE effect_release(IUnknown *self){return release((Analytic *)self);}
static HRESULT STDMETHODCALLTYPE draw_query(ID2D1DrawTransform *self,REFIID iid,void **out){return query(from_draw(self),iid,out);}
static ULONG STDMETHODCALLTYPE draw_add(ID2D1DrawTransform *self){return InterlockedIncrement(&from_draw(self)->refs);}
static ULONG STDMETHODCALLTYPE draw_release(ID2D1DrawTransform *self){return release(from_draw(self));}
static UINT32 STDMETHODCALLTYPE draw_inputs(ID2D1DrawTransform *self){(void)self;return 0;}
static HRESULT STDMETHODCALLTYPE output_to_inputs(ID2D1DrawTransform *self,const D2D1_RECT_L *out,D2D1_RECT_L *inputs,UINT32 count){(void)self;(void)out;(void)inputs;return count?E_INVALIDARG:S_OK;}
static HRESULT STDMETHODCALLTYPE inputs_to_output(ID2D1DrawTransform *self,const D2D1_RECT_L *inputs,const D2D1_RECT_L *opaque,UINT32 count,D2D1_RECT_L *out,D2D1_RECT_L *out_opaque){
    (void)inputs;(void)opaque;if(count)return E_INVALIDARG;Constants *v=&from_draw(self)->values;*out=(D2D1_RECT_L){v->output_bounds[0],v->output_bounds[1],v->output_bounds[2],v->output_bounds[3]};*out_opaque=(D2D1_RECT_L){0};return S_OK;
}
static HRESULT STDMETHODCALLTYPE invalid_rect(ID2D1DrawTransform *self,UINT32 index,D2D1_RECT_L in,D2D1_RECT_L *out){(void)self;(void)index;(void)in;(void)out;return E_INVALIDARG;}
static HRESULT STDMETHODCALLTYPE draw_info(ID2D1DrawTransform *self,ID2D1DrawInfo *info){
    Analytic *s=from_draw(self);DROP(s->info);s->info=info;info->lpVtbl->add(info);OWN(s->info);
    return info->lpVtbl->shader(info,&shader_id,D2D1_PIXEL_OPTIONS_NONE);
}
static const DrawTransformVtable draw_vtable={draw_query,draw_add,draw_release,draw_inputs,output_to_inputs,inputs_to_output,invalid_rect,draw_info};
static HRESULT STDMETHODCALLTYPE initialize(ID2D1EffectImpl *self,ID2D1EffectContext *context,ID2D1TransformGraph *graph){
    HRESULT hr=context->lpVtbl->load_pixel_shader(context,&shader_id,zg_gradient_shader,sizeof(zg_gradient_shader));
    if(FAILED(hr))return hr;return graph->lpVtbl->single(graph,(ID2D1TransformNode *)&((Analytic *)self)->draw);
}
static HRESULT STDMETHODCALLTYPE prepare(ID2D1EffectImpl *self,D2D1_CHANGE_TYPE change){
    (void)change;Analytic *s=(Analytic *)self;if(!s->info)return E_UNEXPECTED;s->uploads++;
    return s->info->lpVtbl->constants(s->info,(const BYTE *)&s->values,sizeof(s->values));
}
static HRESULT STDMETHODCALLTYPE set_graph(ID2D1EffectImpl *self,ID2D1TransformGraph *graph){(void)self;(void)graph;return E_NOTIMPL;}
static const ID2D1EffectImplVtbl effect_vtable={{effect_query,effect_add,effect_release},initialize,prepare,set_graph};
static HRESULT CALLBACK create_effect(IUnknown **out){
    Analytic *s=HeapAlloc(GetProcessHeap(),HEAP_ZERO_MEMORY,sizeof(*s));if(!s)return E_OUTOFMEMORY;
    s->effect.lpVtbl=&effect_vtable;s->draw.lpVtbl=&draw_vtable;s->refs=1;
    *out=(IUnknown *)&s->effect;InterlockedIncrement(&live_resources);return S_OK;
}
static HRESULT CALLBACK set_values(IUnknown *self,const BYTE *bytes,UINT32 size){
    if(!bytes||size!=sizeof(Constants))return E_INVALIDARG;Constants value;memcpy(&value,bytes,sizeof(value));
    if(value.control[0]<2||value.control[0]>16||(value.frame[3]!=0&&value.frame[3]!=1&&value.frame[3]!=2))return E_INVALIDARG;
    ((Analytic *)self)->values=value;return S_OK;
}
static HRESULT CALLBACK get_values(const IUnknown *self,BYTE *bytes,UINT32 capacity,UINT32 *size){
    if(size)*size=sizeof(Constants);if(bytes){if(capacity<sizeof(Constants))return E_NOT_SUFFICIENT_BUFFER;memcpy(bytes,&((const Analytic *)self)->values,sizeof(Constants));}return S_OK;
}
static const WCHAR effect_xml[]=L"<?xml version='1.0'?><Effect><Property name='DisplayName' type='string' value='Analytic gradient'/><Property name='Author' type='string' value='Ziggurat'/><Property name='Category' type='string' value='Drawing'/><Property name='Description' type='string' value='Bounded analytic gradients'/><Inputs/><Property name='Config' type='blob'><Property name='DisplayName' type='string' value='Config'/></Property><Property name='Uploads' type='blob'><Property name='DisplayName' type='string' value='Uploads'/></Property></Effect>";
static HRESULT CALLBACK get_uploads(const IUnknown *self,BYTE *bytes,UINT32 capacity,UINT32 *size){
    if(size)*size=sizeof(uint64_t);if(bytes){if(capacity<sizeof(uint64_t))return E_NOT_SUFFICIENT_BUFFER;memcpy(bytes,&((const Analytic *)self)->uploads,sizeof(uint64_t));}return S_OK;
}
static HRESULT register_gradient(ID2D1Factory1 *factory){
    const D2D1_PROPERTY_BINDING bindings[]={{L"Config",set_values,get_values},{L"Uploads",NULL,get_uploads}};
    return factory->lpVtbl->RegisterEffectFromString(factory,&effect_id,effect_xml,bindings,2,create_effect);
}
static uint64_t gradient_uploads(ID2D1Effect *effect){
    uint64_t uploads=0;if(effect)effect->lpVtbl->GetValue(effect,1,D2D1_PROPERTY_TYPE_BLOB,(BYTE *)&uploads,sizeof(uploads));return uploads;
}
#endif
