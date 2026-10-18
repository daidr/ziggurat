/* Separate executable only: compile these same products with ZDA_POINT_TESTING.
 * Do not also link the ordinary DA objects or provider probe in that target. */
#ifndef ZDA_POINT_TESTING
#error "The point latch requires its isolated test build"
#endif
#include "document_accessibility_provider_probe.c"
#include <stdio.h>

typedef int (__cdecl *RootPost)(void *,uint32_t);
typedef struct RootLatch {
    PointSpy spy; /* First: the ordinary independent COM lifetime implementation. */
    RootPost post;void *context;
    HANDLE resume;
    ZdaNative *native;
    ZdaGeometry *next;
    /* Keep unrelated live Text retirements out of the cross-thread allocator
       observer. These pins do not retain the old Geometry being measured. */
    ZdaText *texts[2];
    ZdaAuxPlan *plan;
    IRawElementProviderSimple *simple;
    IRawElementProviderFragmentRoot *root;
    DWORD main_thread;
    uint32_t mode,close_during_free;
    volatile LONG entered,completed,worker_failure;
    int owner_result;
    HRESULT result;
    BOOL returned_null;
    BOOL registered;
} RootLatch;
static PVOID volatile active_root_latch;

static BOOL root_latch_post_wait(RootLatch *self,uint32_t phase) {
    if(!self->post(self->context,phase)) { InterlockedExchange(&self->worker_failure,1);return FALSE; }
    if(WaitForSingleObject(self->resume,10000)!=WAIT_OBJECT_0) { InterlockedExchange(&self->worker_failure,2);return FALSE; }
    return TRUE;
}
void zda_point_test_snapshot(ZdaNative *native,IRawElementProviderFragmentRoot *root) {
    RootLatch *self=InterlockedCompareExchangePointer(&active_root_latch,NULL,NULL);
    if(!self || self->native!=native || self->root!=root || self->spy.owner!=GetCurrentThreadId())return;
    if(InterlockedCompareExchange(&self->entered,1,0)!=0)return;
    /* Only this MTA worker waits. Its posted owner callback mutates the actual
       front after the first guard and before real snapshot retirement. */
    (void)root_latch_post_wait(self,0);
}
static void * STDMETHODCALLTYPE root_latch_pre_free(IMallocSpy *pointer,void *request,BOOL tracked) {
    RootLatch *self=(RootLatch *)pointer;
    const BOOL watched=GetCurrentThreadId()==self->spy.owner && self->spy.state && request==self->spy.retired_block;
    void *actual=spy_pre_free(pointer,request,tracked);
    if(watched)(void)root_latch_post_wait(self,1);
    return actual;
}
static const IMallocSpyVtbl root_latch_vtable={spy_query,spy_add,spy_release,spy_pre_alloc,spy_post_alloc,root_latch_pre_free,spy_post_free,spy_pre_realloc,spy_post_realloc,spy_pre_size,spy_post_size,spy_pre_did,spy_post_did,spy_heap,spy_heap};

int zda_root_latch_create(void *hwnd,uint32_t mode,uint32_t close_during_free,RootPost post,void *context,void **out) {
    if(!out||!post||mode>2||close_during_free>1)return __LINE__;
    *out=NULL;
    RootLatch *self=HeapAlloc(GetProcessHeap(),HEAP_ZERO_MEMORY,sizeof(*self));
    if(!self)return __LINE__;
    self->spy.iface.lpVtbl=&root_latch_vtable;self->spy.refs=1;
    self->main_thread=GetCurrentThreadId();self->mode=mode;self->close_during_free=close_during_free;
    self->post=post;self->context=context;
    ZdaGeometry *old=NULL;int failure=0;
#define INIT(value) do { if(!(value)){failure=__LINE__;goto failed;} } while(0)
    self->resume=CreateEventW(NULL,FALSE,FALSE,NULL);INIT(self->resume);
    const ZdaSource specs[2]={{L"A",1,1,0,0,0},{L"B",1,1,0,0,0}};ZdaError error;
    INIT(zda_native_create(hwnd,specs,2,262144,32,128,NULL,NULL,&error,&self->native)==ZDA_OK);
    INIT(zda_native_enable_presentation(self->native)==ZDA_OK);
    INIT(zda_native_enable_auxiliary(self->native,2)==ZDA_OK);
    const uint16_t units[]={'a','b'};const uint32_t scalars[]={0,1,2},paragraphs[]={0,2};
    const ZdaTextInput input={1,units,scalars,paragraphs,2,3,2};
    ZdaText **texts=self->texts;
    for(unsigned i=0;i<2;++i){
        INIT(zda_native_text(self->native,&input,&texts[i])==ZDA_OK);
    }
    const ZdaSelection selection={0,0};const ZdaMetadata metadata[2]={{1,1,&selection,1,0,0,1,0},{1,1,&selection,1,0,0,1,0}};
    int published=zda_native_publish(self->native,texts,metadata,2);
    INIT(published==ZDA_OK);
    const ZdaCaret carets[]={{0,1,{0,0,0,20}},{1,1,{10,0,0,20}},{2,1,{20,0,0,20}}};
    const ZdaLine line={0,3,{0,0,80,20}};
    const ZdaGeometryInput visible={1,1,{0,0,80,40},NULL,0,1,carets,3,&line,1};
    INIT(fixture_hit(self->native,0,&visible,&old)==ZDA_OK);
    INIT(fixture_hit(self->native,0,&visible,&self->next)==ZDA_OK);
    const ZdaAuxNode nodes[]={{{71,1,0,0,0},80,UINT32_MAX,0,5,0},{{71,1,1,1,0},81,0,5,6,0}};
    INIT(zda_native_auxiliary(self->native,nodes,2,(const uint16_t *)L"ToolsAction",11,&self->plan)==ZDA_OK);
    const ZdaAuxGeometry rects[]={{100,0,40,20,5,0},{100,0,40,20,5,0}};
    ZdaGeometry *bank[]={old,NULL};
    INIT(zda_native_publish_auxiliary(self->native,bank,2,1,self->plan,rects,2,1)==ZDA_OK);
    self->simple=zda_native_provider(self->native,UINT32_MAX);INIT(self->simple);
    INIT(SUCCEEDED(IRawElementProviderSimple_QueryInterface(self->simple,&IID_IRawElementProviderFragmentRoot,(void **)&self->root)));
    self->spy.state=self->native;
    self->spy.retired_block=(char *)old-zda_storage_footprint(0);
    zda_geometry_release(old);old=NULL;
    InterlockedExchangePointer(&active_root_latch,self);
    *out=self;return 0;
failed:
    zda_geometry_release(old);
    if(self->native){zda_native_begin_close(self->native);(void)zda_native_disconnect(self->native);}
    zda_geometry_release(self->next);zda_auxiliary_release(self->plan);
    for(unsigned i=0;i<2;++i)zda_text_release(self->texts[i]);
    if(self->root)IRawElementProviderFragmentRoot_Release(self->root);
    if(self->simple)IRawElementProviderSimple_Release(self->simple);
    if(self->resume)CloseHandle(self->resume);
    self->spy.state=NULL;self->spy.retired_block=NULL;
    spy_release(&self->spy.iface);return failure;
#undef INIT
}

void zda_root_latch_owner(void *pointer,uint32_t phase) {
    RootLatch *self=pointer;
    if(GetCurrentThreadId()!=self->main_thread){self->owner_result=ZDA_INVALID;SetEvent(self->resume);return;}
    if(phase==0){
        const ZdaAuxGeometry rects[]={{100,0,40,20,5,0},{100,0,40,20,5,0}};
        ZdaGeometry *bank[]={self->next,NULL};
        self->owner_result=zda_native_publish_auxiliary(self->native,bank,2,2,self->plan,rects,2,1);
    } else if(phase==1){
        if(self->close_during_free)zda_native_begin_close(self->native);
    } else self->owner_result=ZDA_INVALID;
    SetEvent(self->resume);
}
void zda_root_latch_worker(void *pointer) {
    RootLatch *self=pointer;
    self->spy.owner=GetCurrentThreadId();
    HRESULT initialized=CoInitializeEx(NULL,COINIT_MULTITHREADED);
    if(FAILED(initialized)){self->result=initialized;InterlockedExchange(&self->completed,1);(void)self->post(self->context,2);return;}
    HRESULT registered=CoRegisterMallocSpy(&self->spy.iface);
    if(FAILED(registered)){self->result=registered;CoUninitialize();InterlockedExchange(&self->completed,1);(void)self->post(self->context,2);return;}
    self->registered=TRUE;
    IRawElementProviderFragment *result=(void *)1;
    const double x=self->mode==0?1:self->mode==1?110:1000;
    self->result=IRawElementProviderFragmentRoot_ElementProviderFromPoint(self->root,x,self->mode==2?1000:10,&result);
    self->returned_null=result==NULL;
    if(result&&result!=(void *)1)IRawElementProviderFragment_Release(result);
    CoUninitialize();InterlockedExchange(&self->completed,1);
    (void)self->post(self->context,2);
}
int zda_root_latch_finish(void *pointer) {
    RootLatch *self=pointer;
    int failure=0;
    if(GetCurrentThreadId()!=self->main_thread || !self->completed)return __LINE__;
    if(self->result!=(HRESULT)UIA_E_ELEMENTNOTAVAILABLE || !self->returned_null)failure=__LINE__;
    if(!failure&&(self->entered!=1||self->spy.final_frees!=1||self->owner_result!=ZDA_OK||self->worker_failure))failure=__LINE__;
    fprintf(stderr,"root point latch mode=%u close=%u hr=0x%08lx null=%d entered=%ld actual_final_free=%u owner=%d worker=%ld\n",self->mode,self->close_during_free,(unsigned long)self->result,self->returned_null,self->entered,self->spy.final_frees,self->owner_result,self->worker_failure);
    InterlockedCompareExchangePointer(&active_root_latch,NULL,self);
    self->spy.state=NULL;self->spy.retired_block=NULL;self->spy.allocation_armed=FALSE;
    HRESULT revoked=self->registered?CoRevokeMallocSpy():S_OK;
    if(!failure&&FAILED(revoked))failure=__LINE__;
    zda_native_begin_close(self->native);
    HRESULT disconnected=zda_native_disconnect(self->native);
    zda_geometry_release(self->next);zda_auxiliary_release(self->plan);
    for(unsigned i=0;i<2;++i)zda_text_release(self->texts[i]);
    IRawElementProviderFragmentRoot_Release(self->root);IRawElementProviderSimple_Release(self->simple);
    CloseHandle(self->resume);self->resume=NULL;self->native=NULL;self->post=NULL;self->context=NULL;
    if(!failure&&FAILED(disconnected))failure=__LINE__;
    spy_release(&self->spy.iface);
    return failure;
}
int zda_root_latch_abort(void *pointer) {
    /* Only before a worker has been started. No registered observer exists. */
    RootLatch *self=pointer;InterlockedExchange(&self->completed,1);
    return zda_root_latch_finish(pointer);
}
