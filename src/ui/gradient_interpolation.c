#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define D2D_USE_C_DEFINITIONS
#include <windows.h>
#include <d2d1_1.h>
#include <math.h>
#include <string.h>
#include "brushes.h"
#include "gradient_interpolation_native.h"
#define OWN(p) do { if(p)zgpu_interpolation_account(1); } while(0)
#define DROP(p) do { if(p){IUnknown_Release((IUnknown *)(p));(p)=NULL;zgpu_interpolation_account(-1);} } while(0)
#define ZG_INTERPOLATION_VALUES 1
#include "gradient_interpolation_effect.h"

typedef struct Program {
    ZgInterpolation bridge;
    ID2D1Factory1 *factory;
    ID2D1DeviceContext *context;
    ID2D1Effect *effect;
    int registered;
} Program;
static void program_lose(ZgInterpolation *bridge){
    Program *program=(Program *)bridge;
    if(!bridge->stats.ready&&!program->effect&&!program->context)return;
    bridge->stats.ready=0;
    bridge->stats.constant_uploads+=gradient_uploads(program->effect);
    DROP(program->effect);DROP(program->context);
    bridge->stats.metadata_actual=sizeof(*program);
    bridge->stats.device_losses++;
}
static void program_destroy(ZgInterpolation *bridge){
    Program *program=(Program *)bridge;
    bridge->stats.ready=0;
    DROP(program->effect);DROP(program->context);
    if(program->registered){
        /* Every successful registration owns exactly one matching reference.
           S_OK is guaranteed for this registered factory/class pair. */
        program->factory->lpVtbl->UnregisterEffect(program->factory,&effect_id);
        program->registered=0;
    }
    DROP(program->factory);
    HeapFree(GetProcessHeap(),0,program);zgpu_interpolation_account(-1);
}
static HRESULT program_draw(ZgInterpolation *bridge,ID2D1DeviceContext *context,
    float x,float y,float width,float height,float radius,float stroke,double scale,
    uint32_t target_width,uint32_t target_height,const ZgBrush *key,const ZgInterpolationPacket *packet){
    Program *program=(Program *)bridge;
    if(!bridge->stats.ready||context!=program->context)return ZG_E_GRADIENT_PRECISION;
    if(!key||!packet||key->kind>ZG_BRUSH_CONIC||key->len<2||key->len>16||packet->len!=key->len||
       (packet->space!=1&&packet->space!=2)||packet->reserved[0]||packet->reserved[1])return E_INVALIDARG;
    for(unsigned i=0;i<key->len;i++){
        float alpha=(float)((key->stops[i].rgba&255)/255.0);
        for(unsigned channel=0;channel<4;channel++){
            float value=packet->colors[i][channel];
            if(!isfinite(value)||fabsf(value)>2||
               (channel==3&&value!=alpha)||(alpha==0&&value!=0))return E_INVALIDARG;
        }
    }
    Constants values;
    HRESULT prepared=gradient_values(&values,x,y,width,height,radius,stroke,scale,target_width,target_height,key,packet);
    if(prepared!=S_OK)return prepared==S_FALSE?S_OK:prepared;
    HRESULT hr=program->effect->lpVtbl->SetValue(program->effect,0,D2D1_PROPERTY_TYPE_BLOB,(const BYTE *)&values,sizeof(values));
    if(FAILED(hr))return hr;
    ID2D1Image *output=NULL;program->effect->lpVtbl->GetOutput(program->effect,&output);OWN(output);
    if(!output)return E_UNEXPECTED;
    context->lpVtbl->DrawImage(context,output,NULL,NULL,D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR,D2D1_COMPOSITE_MODE_SOURCE_OVER);
    DROP(output);bridge->stats.draws++;
    return S_OK;
}
static void program_stats(ZgInterpolation *bridge,ZgInterpolationStats *out){
    *out=bridge->stats;
    out->constant_uploads+=gradient_uploads(((Program *)bridge)->effect);
}
static const ZgInterpolationOps program_ops={program_lose,program_destroy,program_stats,program_draw};

/* Only an explicit Zig prepare references these archive exports. */
size_t zgpu_interpolation_metadata_size(void){return sizeof(Program)+sizeof(Analytic);}
ZgInterpolation *zgpu_interpolation_create_candidate(ID2D1Factory1 *factory,ID2D1DeviceContext *context,uint32_t fault,HRESULT *out){
    *out=E_INVALIDARG;if(!factory||!context)return NULL;
    if(fault==1){*out=E_OUTOFMEMORY;return NULL;}
    Program *program=HeapAlloc(GetProcessHeap(),HEAP_ZERO_MEMORY,sizeof(*program));
    if(!program){*out=E_OUTOFMEMORY;return NULL;}
    zgpu_interpolation_account(1);
    program->bridge.ops=&program_ops;
    program->bridge.stats.metadata_reserved=zgpu_interpolation_metadata_size();
    program->factory=factory;IUnknown_AddRef((IUnknown *)factory);OWN(program->factory);
    program->context=context;IUnknown_AddRef((IUnknown *)context);OWN(program->context);
    *out=fault==2?E_OUTOFMEMORY:register_gradient(factory);
    if(FAILED(*out))goto failed;
    program->registered=1;
    *out=fault==3?E_OUTOFMEMORY:context->lpVtbl->CreateEffect(context,&effect_id,&program->effect);OWN(program->effect);
    if(FAILED(*out))goto failed;
    if(fault==4){*out=E_OUTOFMEMORY;goto failed;}
    program->bridge.stats.metadata_actual=zgpu_interpolation_metadata_size();
    program->bridge.stats.effect_creations=1;
    program->bridge.stats.ready=1;
    return &program->bridge;
failed:
    program_destroy(&program->bridge);return NULL;
}
