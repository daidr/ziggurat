#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define D2D_USE_C_DEFINITIONS
#include <windows.h>
#include <d2d1_1.h>
#include "../src/ui/brushes.h"
#include "../src/ui/gradient_interpolation_native.h"

extern HRESULT zgpu_interpolation_environment(void *,ID2D1Factory1 **,ID2D1DeviceContext **);
extern ZgInterpolation *zgpu_interpolation_take(void *);
extern HRESULT zgpu_interpolation_install(void *,ZgInterpolation *,ID2D1DeviceContext *);
extern size_t zgpu_interpolation_dispose(ZgInterpolation *);
static const GUID test_effect_id={0x95091f4e,0xf110,0x4257,{0x92,0x5d,0xcd,0xa6,0xbe,0x12,0x9b,0xb4}};

HRESULT zgi_registered(void *native,uint32_t *found){
    ID2D1Factory1 *factory=NULL;ID2D1DeviceContext *context=NULL;
    HRESULT hr=zgpu_interpolation_environment(native,&factory,&context);if(FAILED(hr))return hr;
    GUID classes[512];UINT32 count=0,total=0;*found=0;
    hr=factory->lpVtbl->GetRegisteredEffects(factory,classes,512,&count,&total);
    if(FAILED(hr))return hr;
    if(total>512)return E_NOT_SUFFICIENT_BUFFER;
    for(UINT32 i=0;i<count;i++)if(IsEqualGUID(&classes[i],&test_effect_id))(*found)++;
    return S_OK;
}
/* One fixture-owned synchronous hook after the owner's real final COM/free
   sequence. It stores no input, text, other HWND, or asynchronous callback. */
static const ZgInterpolationOps *original_ops;
static ZgInterpolation *hooked;
static void *hook_context;
static void (*after_free)(void *);
/* Repeated native cleanup of one payload must not count two invalidations. */
static void hook_lose(ZgInterpolation *value){original_ops->lose(value);original_ops->lose(value);}
static void hook_stats(ZgInterpolation *value,ZgInterpolationStats *out){original_ops->stats(value,out);}
static HRESULT hook_draw(ZgInterpolation *value,ID2D1DeviceContext *context,
    float x,float y,float width,float height,float radius,float stroke,double scale,
    uint32_t target_width,uint32_t target_height,const ZgBrush *brush,const ZgInterpolationPacket *packet){
    return original_ops->draw(value,context,x,y,width,height,radius,stroke,scale,target_width,target_height,brush,packet);
}
static void hook_destroy(ZgInterpolation *value){
    const ZgInterpolationOps *ops=original_ops;
    void *context=hook_context;void (*callback)(void *)=after_free;
    value->ops=ops;hooked=NULL;original_ops=NULL;hook_context=NULL;after_free=NULL;
    ops->destroy(value);
    callback(context);
}
static const ZgInterpolationOps hook_ops={hook_lose,hook_destroy,hook_stats,hook_draw};
HRESULT zgi_after_program_free(void *native,void *context,void (*callback)(void *)){
    if(hooked||!callback)return E_UNEXPECTED;
    ID2D1Factory1 *factory=NULL;ID2D1DeviceContext *device_context=NULL;
    HRESULT hr=zgpu_interpolation_environment(native,&factory,&device_context);if(FAILED(hr))return hr;
    ZgInterpolation *value=zgpu_interpolation_take(native);if(!value)return E_UNEXPECTED;
    hooked=value;original_ops=value->ops;hook_context=context;after_free=callback;value->ops=&hook_ops;
    hr=zgpu_interpolation_install(native,value,device_context);
    if(FAILED(hr)){value->ops=original_ops;hooked=NULL;original_ops=NULL;hook_context=NULL;after_free=NULL;zgpu_interpolation_dispose(value);}
    return hr;
}
int zgi_hook_pending(void){return hooked!=NULL;}
