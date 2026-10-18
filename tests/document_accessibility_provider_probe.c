#include "native_internal.h"
#include <string.h>
#include <limits.h>
#include <math.h>
#include <objidl.h>
#define CHECK(value) do { if (!(value)) return __LINE__; } while (0)
typedef struct Pending { void *actions[16]; uint32_t count; } Pending;
static int enqueue(void *pointer, void *action) {
    Pending *queue = pointer;
    if (queue->count == 16) return 0;
    queue->actions[queue->count++] = action; return 1;
}
static HRESULT full_range(IRawElementProviderSimple *simple, ITextProvider **text, ITextRangeProvider **range) {
    IUnknown *pattern = NULL;
    HRESULT hr = IRawElementProviderSimple_GetPatternProvider(simple, UIA_TextPatternId, &pattern);
    if (FAILED(hr) || !pattern) return FAILED(hr) ? hr : E_NOINTERFACE;
    hr = IUnknown_QueryInterface(pattern, &IID_ITextProvider, (void **)text); IUnknown_Release(pattern);
    if (FAILED(hr)) return hr;
    return ITextProvider_get_DocumentRange(*text, range);
}
static int word_offsets(ITextRangeProvider *range,ITextRangeProvider *full,int start,int end) {
    int actual=-1;
    CHECK(SUCCEEDED(ITextRangeProvider_CompareEndpoints(range,TextPatternRangeEndpoint_Start,full,TextPatternRangeEndpoint_Start,&actual)) && actual==start);
    CHECK(SUCCEEDED(ITextRangeProvider_CompareEndpoints(range,TextPatternRangeEndpoint_End,full,TextPatternRangeEndpoint_Start,&actual)) && actual==end);return 0;
}
typedef struct LateWordRange { ITextRangeProvider *range;int failed; } LateWordRange;
static DWORD WINAPI late_word_range(void *pointer) {
    LateWordRange *late=pointer;
    HRESULT initialized=CoInitializeEx(NULL,COINIT_MULTITHREADED);
    if(FAILED(initialized)){late->failed=1;ITextRangeProvider_Release(late->range);return 0;}
    int moved=99;IUnknown *identity=NULL;
    if(ITextRangeProvider_Move(late->range,TextUnit_Word,1,&moved)!=(HRESULT)UIA_E_ELEMENTNOTAVAILABLE || moved)late->failed=1;
    if(FAILED(ITextRangeProvider_QueryInterface(late->range,&IID_IUnknown,(void **)&identity)))late->failed=1;
    if(identity)IUnknown_Release(identity);
    ITextRangeProvider_Release(late->range);CoUninitialize();return 0;
}
int zda_test_word_units(void) {
    CHECK(SUCCEEDED(CoInitializeEx(NULL,COINIT_APARTMENTTHREADED)));
    uint32_t accounts,blocks;uint64_t bytes;zda_ledger_counts(&accounts,&blocks,&bytes);
    HWND hwnd=CreateWindowExW(0,L"STATIC",L"Document word units",WS_OVERLAPPEDWINDOW,0,0,200,100,NULL,NULL,GetModuleHandleW(NULL),NULL);CHECK(hwnd);
    const ZdaSource source={L"Words",5,0,1,1,0};ZdaError error;
    const uint16_t units[]={' ','\t','h','e','l','l','o',',',' ','w','o','r','l','d','!',' ','\r','\n'};
    uint32_t scalars[19];for(uint32_t i=0;i<19;++i)scalars[i]=i;
    const uint32_t paragraphs[]={0,18,18};const ZdaTextInput input={1,units,scalars,paragraphs,18,19,3};
    for(unsigned enabled=0;enabled<2;++enabled) {
        ZdaNative *native=NULL;CHECK(zda_native_create(hwnd,&source,1,65536,64,128,NULL,NULL,&error,&native)==ZDA_OK);
        if(enabled)CHECK(zda_native_enable_words(native)==ZDA_OK);
        ZdaText *candidate=NULL;CHECK(zda_native_text(native,&input,&candidate)==ZDA_OK);
        const ZdaSelection selection={2,2};const ZdaMetadata metadata={1,1,&selection,1,0,0,1,0};
        CHECK(zda_native_publish(native,&candidate,&metadata,1)==ZDA_OK);zda_text_release(candidate);
        IRawElementProviderSimple *simple=zda_native_provider(native,0);CHECK(simple);
        ITextProvider *provider=NULL;ITextRangeProvider *full=NULL,*cursor=NULL;
        CHECK(SUCCEEDED(full_range(simple,&provider,&full)));
        BSTR needle=SysAllocString(L"hello");CHECK(needle);
        CHECK(SUCCEEDED(ITextRangeProvider_FindText(full,needle,FALSE,FALSE,&cursor)) && cursor);SysFreeString(needle);
        CHECK(SUCCEEDED(ITextRangeProvider_ExpandToEnclosingUnit(cursor,TextUnit_Word)));
        CHECK(!word_offsets(cursor,full,enabled?2:0,enabled?9:18));
        if(enabled) {
            ZdaStats before;zda_native_stats(native,&before);
            CHECK(SUCCEEDED(ITextRangeProvider_ExpandToEnclosingUnit(cursor,TextUnit_Format)) && !word_offsets(cursor,full,2,9));
            int moved=0;CHECK(SUCCEEDED(ITextRangeProvider_Move(cursor,TextUnit_Word,1,&moved)) && moved==1 && !word_offsets(cursor,full,9,18));
            CHECK(SUCCEEDED(ITextRangeProvider_Move(cursor,TextUnit_Word,-1,&moved)) && moved==-1 && !word_offsets(cursor,full,2,9));
            CHECK(SUCCEEDED(ITextRangeProvider_MoveEndpointByUnit(cursor,TextPatternRangeEndpoint_End,TextUnit_Word,-1,&moved)) && moved==-1 && !word_offsets(cursor,full,2,2));
            CHECK(SUCCEEDED(ITextRangeProvider_Move(cursor,TextUnit_Word,INT_MAX,&moved)) && moved==2 && !word_offsets(cursor,full,18,18));
            CHECK(SUCCEEDED(ITextRangeProvider_ExpandToEnclosingUnit(cursor,TextUnit_Word)) && !word_offsets(cursor,full,9,18));
            CHECK(SUCCEEDED(ITextRangeProvider_MoveEndpointByRange(cursor,TextPatternRangeEndpoint_Start,cursor,TextPatternRangeEndpoint_End)));
            CHECK(SUCCEEDED(ITextRangeProvider_ExpandToEnclosingUnit(cursor,TextUnit_Line)) && !word_offsets(cursor,full,18,18));
            CHECK(SUCCEEDED(ITextRangeProvider_ExpandToEnclosingUnit(cursor,TextUnit_Document)) && !word_offsets(cursor,full,0,18));
            CHECK(SUCCEEDED(ITextRangeProvider_Move(cursor,TextUnit_Word,1,&moved)) && moved==1 && !word_offsets(cursor,full,2,9));
            CHECK(SUCCEEDED(ITextRangeProvider_Move(cursor,TextUnit_Word,INT_MIN,&moved)) && !word_offsets(cursor,full,0,2));
            ZdaStats after;zda_native_stats(native,&after);CHECK(before.bytes==after.bytes && before.blobs==after.blobs && before.ranges==after.ranges);
        }
        zda_native_begin_close(native);CHECK(SUCCEEDED(zda_native_disconnect(native)));
        int moved=99;CHECK(ITextRangeProvider_Move(cursor,TextUnit_Word,1,&moved)==(HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !moved);
        IUnknown *identity=NULL;CHECK(SUCCEEDED(ITextRangeProvider_QueryInterface(cursor,&IID_IUnknown,(void **)&identity)));IUnknown_Release(identity);
        ITextRangeProvider_Release(full);ITextProvider_Release(provider);IRawElementProviderSimple_Release(simple);
        LateWordRange late={cursor,0};HANDLE thread=CreateThread(NULL,0,late_word_range,&late,0,NULL);CHECK(thread);
        CHECK(WaitForSingleObject(thread,5000)==WAIT_OBJECT_0);CloseHandle(thread);CHECK(!late.failed);
    }
    DestroyWindow(hwnd);
    uint32_t final_accounts,final_blocks;uint64_t final_bytes;zda_ledger_counts(&final_accounts,&final_blocks,&final_bytes);
    CHECK(final_accounts==accounts && final_blocks==blocks && final_bytes==bytes);CoUninitialize();return 0;
}
static DWORD WINAPI late_release(void *provider) {
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    IRawElementProviderSimple_Release((IRawElementProviderSimple *)provider);
    CoUninitialize(); return 0;
}
typedef struct AuxWorker { IRawElementProviderSimple *button; HRESULT result; } AuxWorker;
static DWORD WINAPI auxiliary_worker(void *pointer){
    AuxWorker*w=pointer;w->result=CoInitializeEx(NULL,COINIT_MULTITHREADED);if(FAILED(w->result))return 0;
    VARIANT name;VariantInit(&name);w->result=IRawElementProviderSimple_GetPropertyValue(w->button,UIA_NamePropertyId,&name);
    if(SUCCEEDED(w->result)&&(!(name.vt==VT_BSTR)||wcscmp(name.bstrVal,L"Revert")))w->result=E_FAIL;VariantClear(&name);
    IInvokeProvider*invoke=NULL;if(SUCCEEDED(w->result))w->result=IRawElementProviderSimple_QueryInterface(w->button,&IID_IInvokeProvider,(void**)&invoke);
    if(SUCCEEDED(w->result))w->result=IInvokeProvider_Invoke(invoke);if(invoke)IInvokeProvider_Release(invoke);CoUninitialize();return 0;
}
int zda_test_auxiliary(void){
    CHECK(SUCCEEDED(CoInitializeEx(NULL,COINIT_APARTMENTTHREADED)));
    uint32_t accounts,blocks;uint64_t bytes;zda_ledger_counts(&accounts,&blocks,&bytes);
    HWND hwnd=CreateWindowExW(0,L"STATIC",L"Auxiliary subtree",WS_OVERLAPPEDWINDOW,0,0,200,100,NULL,NULL,GetModuleHandleW(NULL),NULL);CHECK(hwnd);
    const ZdaSource specs[2]={{L"Original",8,1,0,0,0},{L"Modified",8,0,1,1,0}};
    Pending queue={0};ZdaNative*s=NULL;ZdaError error;
    CHECK(zda_native_create(hwnd,specs,2,131072,16,1024,enqueue,&queue,&error,&s)==ZDA_OK);
    CHECK(zda_native_enable_presentation(s)==ZDA_OK);CHECK(zda_native_enable_auxiliary(s,4)==ZDA_OK);
    const uint16_t text[]={'a'};const uint32_t scalar[]={0,1},paragraph[]={0,1};const ZdaTextInput input={1,text,scalar,paragraph,1,2,2};
    ZdaText*texts[2]={0};for(unsigned i=0;i<2;++i)CHECK(zda_native_text(s,&input,&texts[i])==ZDA_OK);
    const ZdaSelection selected={0,0};const ZdaMetadata meta[2]={{1,1,&selected,1,0,0,1,0},{1,1,&selected,1,0,0,1,0}};
    CHECK(zda_native_publish(s,texts,meta,2)==ZDA_OK);for(unsigned i=0;i<2;++i)zda_text_release(texts[i]);
    const ZdaAuxNode nodes[]={
        {{UINT64_C(0x123456789abcdef0),UINT64_C(0xfedcba9876543210),0,0,0},80,UINT32_MAX,0,8,0},
        {{UINT64_C(0x123456789abcdef0),UINT64_C(0xfedcba9876543210),UINT64_C(0x100000002),1,7},81,0,8,6,0},
        {{UINT64_C(0x123456789abcdef0),UINT64_C(0xfedcba9876543210),UINT64_C(0x100000002),2,8},82,0,14,7,0},
    };
    const uint16_t names[]=L"ControlsRevertContext";ZdaAuxPlan*plan=NULL;
    ZdaAuxNode bad_flags[3];memcpy(bad_flags,nodes,sizeof(bad_flags));bad_flags[1].expanded=4;
    CHECK(zda_native_auxiliary(s,bad_flags,3,names,21,&plan)==ZDA_INVALID&&!plan);
    ZdaStats before;zda_native_stats(s,&before);size_t remaining=(size_t)(before.byte_limit-before.bytes);
    CHECK(zda_account_reserve_host(s->account,remaining)==ZDA_OK);CHECK(zda_native_auxiliary(s,nodes,3,names,21,&plan)==ZDA_CAPACITY&&!plan);zda_account_release_host(s->account,remaining);
    CHECK(zda_native_auxiliary(s,nodes,3,names,21,&plan)==ZDA_OK);
    ZdaStats complete;zda_native_stats(s,&complete);
    const size_t plan_bytes=zda_storage_footprint(sizeof(ZdaAuxPlan)+3*sizeof(ZdaAuxEntry)+21*sizeof(WCHAR));
    const size_t provider_bytes=(size_t)(complete.bytes-before.bytes-plan_bytes)/3;
    remaining=(size_t)(complete.byte_limit-complete.bytes);
    CHECK(remaining>plan_bytes+provider_bytes);
    CHECK(zda_account_reserve_host(s->account,remaining-plan_bytes-provider_bytes)==ZDA_OK);
    ZdaAuxPlan *partial=NULL;CHECK(zda_native_auxiliary(s,nodes,3,names,21,&partial)==ZDA_CAPACITY&&!partial);
    zda_account_release_host(s->account,remaining-plan_bytes-provider_bytes);
    ZdaStats rolled_back;zda_native_stats(s,&rolled_back);CHECK(rolled_back.bytes==complete.bytes&&rolled_back.providers==complete.providers&&rolled_back.blobs==complete.blobs);
    /* An unpublished candidate is independently releasable. */
    ZdaAuxPlan*unused=NULL;CHECK(zda_native_auxiliary(s,nodes,3,names,21,&unused)==ZDA_OK);zda_auxiliary_release(unused);
    const ZdaAuxGeometry geometry[]={{2,3,100,20,5,0},{3,4,30,18,5,0},{40,4,40,18,5,0}};
    ZdaGeometry*empty[2]={0};CHECK(zda_native_publish_auxiliary(s,empty,2,1,plan,geometry,3,2)==ZDA_OK);
    ZdaStats warm;zda_native_stats(s,&warm);for(unsigned i=0;i<8;++i)CHECK(zda_native_publish_auxiliary(s,empty,2,1,plan,geometry,3,2)==ZDA_OK);
    ZdaStats replayed;zda_native_stats(s,&replayed);CHECK(warm.bytes==replayed.bytes&&warm.providers==replayed.providers&&warm.blobs==replayed.blobs);
    IRawElementProviderSimple*button=zda_native_auxiliary_provider(s,&nodes[1].key),*disclosure=zda_native_auxiliary_provider(s,&nodes[2].key),*root=zda_native_provider(s,UINT32_MAX);CHECK(button&&disclosure&&root);
    IRawElementProviderFragment *fragment=NULL,*parent=NULL,*last=NULL,*prior=NULL;IRawElementProviderFragmentRoot*fragment_root=NULL;
    CHECK(SUCCEEDED(IRawElementProviderSimple_QueryInterface(button,&IID_IRawElementProviderFragment,(void**)&fragment)));
    CHECK(IRawElementProviderFragment_SetFocus(fragment)==(HRESULT)UIA_E_NOTSUPPORTED);
    ZdaAuxAccepted accepted;CHECK(zda_native_auxiliary_accepted(s,81,&accepted)==ZDA_OK&&accepted.presentation_epoch==1&&accepted.key.item==nodes[1].key.item&&!(accepted.flags&8));
    CHECK(SUCCEEDED(IRawElementProviderFragment_Navigate(fragment,NavigateDirection_Parent,&parent))&&parent);
    CHECK(SUCCEEDED(IRawElementProviderFragment_Navigate(parent,NavigateDirection_PreviousSibling,&prior))&&prior);IRawElementProviderFragment_Release(prior);
    CHECK(SUCCEEDED(IRawElementProviderSimple_QueryInterface(root,&IID_IRawElementProviderFragmentRoot,(void**)&fragment_root)));
    IRawElementProviderFragment*root_fragment=NULL;CHECK(SUCCEEDED(IRawElementProviderSimple_QueryInterface(root,&IID_IRawElementProviderFragment,(void**)&root_fragment)));
    CHECK(SUCCEEDED(IRawElementProviderFragment_Navigate(root_fragment,NavigateDirection_LastChild,&last))&&last==parent);IRawElementProviderFragment_Release(last);
    SAFEARRAY*runtime=NULL;CHECK(SUCCEEDED(IRawElementProviderFragment_GetRuntimeId(fragment,&runtime)));LONG upper;CHECK(SUCCEEDED(SafeArrayGetUBound(runtime,1,&upper))&&upper==9);
    LONG index=3,value;CHECK(SUCCEEDED(SafeArrayGetElement(runtime,&index,&value))&&(uint32_t)value==0x12345678);index=7;CHECK(SUCCEEDED(SafeArrayGetElement(runtime,&index,&value))&&value==1);SafeArrayDestroy(runtime);
    struct UiaRect rect;CHECK(SUCCEEDED(IRawElementProviderFragment_get_BoundingRectangle(fragment,&rect))&&rect.left==6&&rect.top==8&&rect.width==60&&rect.height==36);
    CHECK(zda_native_position(s,10,20,2)==ZDA_OK);CHECK(SUCCEEDED(IRawElementProviderFragment_get_BoundingRectangle(fragment,&rect))&&rect.left==16&&rect.top==28);CHECK(zda_native_position(s,0,0,2)==ZDA_OK);
    IRawElementProviderFragment*hit=NULL;CHECK(SUCCEEDED(IRawElementProviderFragmentRoot_ElementProviderFromPoint(fragment_root,10,12,&hit))&&hit==fragment);IRawElementProviderFragment_Release(hit);
    AuxWorker worker={button,E_FAIL};HANDLE thread=CreateThread(NULL,0,auxiliary_worker,&worker,0,NULL);CHECK(thread);CHECK(WaitForSingleObject(thread,5000)==WAIT_OBJECT_0);CloseHandle(thread);CHECK(SUCCEEDED(worker.result)&&queue.count==1);
    ZdaAuxAction action;CHECK(zda_native_take_auxiliary_action(queue.actions[0],&action)&&action.key.item==UINT64_C(0x100000002)&&action.key.variant==7&&action.presentation_epoch==1);
    ZdaActionView old_action;CHECK(!zda_native_take_action(queue.actions[0],&old_action));
    CHECK(zda_native_publish_auxiliary(s,empty,2,2,plan,geometry,3,2)==ZDA_OK);CHECK(!zda_native_take_auxiliary_action(queue.actions[0],&action));zda_native_finish_action(queue.actions[0]);queue.count=0;
    IExpandCollapseProvider*expand=NULL;CHECK(SUCCEEDED(IRawElementProviderSimple_QueryInterface(disclosure,&IID_IExpandCollapseProvider,(void**)&expand)));enum ExpandCollapseState expanded;
    CHECK(SUCCEEDED(IExpandCollapseProvider_get_ExpandCollapseState(expand,&expanded))&&expanded==ExpandCollapseState_Collapsed);
    CHECK(SUCCEEDED(IExpandCollapseProvider_Expand(expand))&&queue.count==1);CHECK(zda_native_take_auxiliary_action(queue.actions[0],&action)&&action.kind==2);zda_native_finish_action(queue.actions[0]);queue.count=0;
    ZdaAuxGeometry invalid[3];memcpy(invalid,geometry,sizeof(invalid));invalid[1].x=NAN;CHECK(zda_native_publish_auxiliary(s,empty,2,3,plan,invalid,3,2)==ZDA_INVALID);
    uint64_t serial=s->geometry_serial;s->geometry_serial=UINT64_MAX;CHECK(zda_native_publish_auxiliary(s,empty,2,3,plan,geometry,3,2)==ZDA_CAPACITY);s->geometry_serial=serial;
    CHECK(SUCCEEDED(IRawElementProviderFragment_get_BoundingRectangle(fragment,&rect))&&rect.left==6);
    CHECK(zda_native_publish_auxiliary(s,empty,2,3,NULL,NULL,0,2)==ZDA_OK);
    CHECK(zda_native_auxiliary_accepted(s,81,&accepted)==ZDA_UNAVAILABLE);
    IInvokeProvider*invoke=NULL;CHECK(SUCCEEDED(IRawElementProviderSimple_QueryInterface(button,&IID_IInvokeProvider,(void**)&invoke)));CHECK(IInvokeProvider_Invoke(invoke)==(HRESULT)UIA_E_ELEMENTNOTAVAILABLE);IInvokeProvider_Release(invoke);
    CHECK(IExpandCollapseProvider_get_ExpandCollapseState(expand,&expanded)==(HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    CHECK(zda_native_publish_auxiliary(s,empty,2,4,plan,geometry,3,2)==ZDA_OK);CHECK(SUCCEEDED(IExpandCollapseProvider_Collapse(expand))&&queue.count==1);
    ZdaAuxNode replaced[3];memcpy(replaced,nodes,sizeof(replaced));for(unsigned i=0;i<3;++i)++replaced[i].key.comparison;
    replaced[1].expanded=2;replaced[2].expanded=3;
    ZdaAuxPlan *replacement=NULL;CHECK(zda_native_auxiliary(s,replaced,3,names,21,&replacement)==ZDA_OK);
    CHECK(zda_native_publish_auxiliary(s,empty,2,5,replacement,geometry,3,2)==ZDA_OK);zda_auxiliary_release(plan);zda_auxiliary_release(replacement);
    CHECK(zda_native_auxiliary_accepted(s,81,&accepted)==ZDA_OK&&accepted.presentation_epoch==5&&(accepted.flags&8));
    CHECK(!zda_native_take_auxiliary_action(queue.actions[0],&action));zda_native_finish_action(queue.actions[0]);queue.count=0;
    CHECK(SUCCEEDED(IRawElementProviderSimple_QueryInterface(button,&IID_IInvokeProvider,(void**)&invoke)));CHECK(IInvokeProvider_Invoke(invoke)==(HRESULT)UIA_E_ELEMENTNOTAVAILABLE);IInvokeProvider_Release(invoke);
    IRawElementProviderSimple *new_button=zda_native_auxiliary_provider(s,&replaced[1].key);CHECK(new_button);
    IRawElementProviderFragment *new_focus=NULL;CHECK(SUCCEEDED(IRawElementProviderSimple_QueryInterface(new_button,&IID_IRawElementProviderFragment,(void**)&new_focus)));
    CHECK(SUCCEEDED(IRawElementProviderFragment_SetFocus(new_focus))&&queue.count==1);
    CHECK(zda_native_take_auxiliary_action(queue.actions[0],&action)&&action.kind==4&&action.presentation_epoch==5);
    zda_native_finish_action(queue.actions[0]);queue.count=0;IRawElementProviderFragment_Release(new_focus);
    CHECK(SUCCEEDED(IRawElementProviderSimple_QueryInterface(new_button,&IID_IInvokeProvider,(void**)&invoke)));CHECK(SUCCEEDED(IInvokeProvider_Invoke(invoke))&&queue.count==1);IInvokeProvider_Release(invoke);IRawElementProviderSimple_Release(new_button);
    zda_native_begin_close(s);CHECK(!zda_native_take_auxiliary_action(queue.actions[0],&action));
    CHECK(SUCCEEDED(IRawElementProviderSimple_QueryInterface(button,&IID_IInvokeProvider,(void**)&invoke)));CHECK(IInvokeProvider_Invoke(invoke)==(HRESULT)UIA_E_ELEMENTNOTAVAILABLE);IInvokeProvider_Release(invoke);
    CHECK(SUCCEEDED(zda_native_disconnect(s)));DestroyWindow(hwnd);zda_native_finish_action(queue.actions[0]);
    IExpandCollapseProvider_Release(expand);IRawElementProviderSimple_Release(disclosure);IRawElementProviderFragment_Release(fragment);IRawElementProviderFragment_Release(parent);IRawElementProviderFragment_Release(root_fragment);IRawElementProviderFragmentRoot_Release(fragment_root);IRawElementProviderSimple_Release(root);
    thread=CreateThread(NULL,0,late_release,button,0,NULL);CHECK(thread);CHECK(WaitForSingleObject(thread,5000)==WAIT_OBJECT_0);CloseHandle(thread);
    uint32_t final_accounts,final_blocks;uint64_t final_bytes;zda_ledger_counts(&final_accounts,&final_blocks,&final_bytes);CHECK(accounts==final_accounts&&blocks==final_blocks&&bytes==final_bytes);
    CoUninitialize();return 0;
}
int zda_test_presentation(void) {
    CHECK(SUCCEEDED(CoInitializeEx(NULL,COINIT_APARTMENTTHREADED)));
    uint32_t before_accounts,before_blocks;uint64_t before_bytes;
    zda_ledger_counts(&before_accounts,&before_blocks,&before_bytes);
    HWND hwnd=CreateWindowExW(0,L"STATIC",L"Presentation epoch",WS_OVERLAPPEDWINDOW,0,0,100,100,NULL,NULL,GetModuleHandleW(NULL),NULL);CHECK(hwnd);
    const ZdaSource source={L"Source",6,0,1,1,1};Pending queue={0};ZdaNative *native=NULL;ZdaError error;
    CHECK(zda_native_create(hwnd,&source,1,32768,16,128,enqueue,&queue,&error,&native)==ZDA_OK);
    CHECK(zda_native_enable_presentation(native)==ZDA_OK);
    const uint16_t units[]={'a','b'};const uint32_t scalars[]={0,1,2},paragraphs[]={0,2};
    const ZdaTextInput input={1,units,scalars,paragraphs,2,3,2};ZdaText *text=NULL;
    CHECK(zda_native_text(native,&input,&text)==ZDA_OK);
    const ZdaSelection selected={0,0};const ZdaMetadata metadata={1,1,&selected,1,0,0,1,0};
    CHECK(zda_native_publish(native,&text,&metadata,1)==ZDA_OK);zda_text_release(text);
    IRawElementProviderSimple *provider=zda_native_provider(native,0);CHECK(provider);
    ITextProvider *pattern=NULL;ITextRangeProvider *range=NULL;CHECK(SUCCEEDED(full_range(provider,&pattern,&range)));
    CHECK(ITextRangeProvider_Select(range)==(HRESULT)UIA_E_NOTSUPPORTED&&queue.count==0);
    ZdaGeometry *empty[1]={NULL};
    CHECK(zda_native_publish_presented(native,empty,NULL,1,1)==ZDA_OK);
    CHECK(SUCCEEDED(ITextRangeProvider_Select(range))&&queue.count==1);
    CHECK(zda_native_publish_presented(native,empty,NULL,1,2)==ZDA_OK);
    ZdaActionView action;CHECK(!zda_native_take_action(queue.actions[0],&action));zda_native_finish_action(queue.actions[0]);queue.count=0;
    CHECK(SUCCEEDED(ITextRangeProvider_Select(range))&&queue.count==1);
    CHECK(zda_native_take_action(queue.actions[0],&action)&&action.presentation_epoch==2);
    zda_native_finish_action(queue.actions[0]);queue.count=0;
    CHECK(zda_native_publish_presented(native,empty,NULL,1,0)==ZDA_OK);
    CHECK(ITextRangeProvider_Select(range)==(HRESULT)UIA_E_NOTSUPPORTED&&queue.count==0);
    zda_native_begin_close(native);
    ITextRangeProvider_Release(range);ITextProvider_Release(pattern);IRawElementProviderSimple_Release(provider);
    CHECK(SUCCEEDED(zda_native_disconnect(native)));DestroyWindow(hwnd);
    uint32_t accounts,blocks;uint64_t bytes;zda_ledger_counts(&accounts,&blocks,&bytes);
    CHECK(accounts==before_accounts&&blocks==before_blocks&&bytes==before_bytes);
    CoUninitialize();return 0;
}
static int point_offset(ITextProvider *text, ITextRangeProvider *full, double x, double y, int expected) {
    ITextRangeProvider *range = NULL;
    CHECK(SUCCEEDED(ITextProvider_RangeFromPoint(text, ((struct UiaPoint){ x, y }), &range)) && range);
    int offset = -1, width = -1;
    CHECK(SUCCEEDED(ITextRangeProvider_CompareEndpoints(range, TextPatternRangeEndpoint_Start, full, TextPatternRangeEndpoint_Start, &offset)) && offset == expected);
    CHECK(SUCCEEDED(ITextRangeProvider_CompareEndpoints(range, TextPatternRangeEndpoint_End, range, TextPatternRangeEndpoint_Start, &width)) && width == 0);
    BSTR value = NULL;
    CHECK(SUCCEEDED(ITextRangeProvider_GetText(range, -1, &value)) && SysStringLen(value) == 0);
    SysFreeString(value);
    SAFEARRAY *rectangles = NULL; LONG last;
    CHECK(SUCCEEDED(ITextRangeProvider_GetBoundingRectangles(range, &rectangles)));
    CHECK(SUCCEEDED(SafeArrayGetUBound(rectangles, 1, &last)) && last == -1);
    SafeArrayDestroy(rectangles); ITextRangeProvider_Release(range); return 0;
}
/* These two old C fixtures explicitly describe a native layout with bounds at
   zero. Keep its independent, hand-authored line/X order, now with owned POD;
   production never reconstructs input from the visible export this way. */
static int fixture_hit(ZdaNative *native,uint32_t source,const ZdaGeometryInput *input,ZdaGeometry **out) {
    if(input->bounds.x || input->bounds.y || !input->line_count || input->line_count>8 || input->caret_count>64)return ZDA_INVALID;
    ZdeHitBlock block={0,input->line_count,0,0};ZdeHitLine lines[8];ZdeHitStop stops[64];
    for(uint32_t i=0;i<input->line_count;++i){const ZdaLine *line=&input->lines[i];lines[i]=(ZdeHitLine){(float)line->rectangle.y,(float)line->rectangle.height,line->first,line->count};block.end=line->rectangle.y+line->rectangle.height;}
    for(uint32_t i=0;i<input->caret_count;++i)stops[i]=(ZdeHitStop){(float)input->carets[i].rectangle.x,input->carets[i].affinity,input->carets[i].position};
    ZdaHitInput hit={.revision=1,.text_version=input->text_version,.projection_version=input->projection_version,.geometry_generation=1,.scale=input->scale,
        .packet={.bounds={0,0,(float)input->bounds.width,(float)input->bounds.height},.block_count=1,.line_count=input->line_count,.stop_count=input->caret_count,.blocks=&block,.lines=lines,.stops=stops}};
    return zda_native_geometry_hit(native,source,input,&hit,out);
}
int zda_test_provider(void) {
    CHECK(SUCCEEDED(CoInitializeEx(NULL, COINIT_APARTMENTTHREADED)));
    uint32_t before_accounts, before_blocks; uint64_t before_bytes;
    zda_ledger_counts(&before_accounts, &before_blocks, &before_bytes);
    HWND hwnd = CreateWindowExW(0, L"STATIC", L"Document provider", WS_OVERLAPPEDWINDOW, 0, 0, 430, 270, NULL, NULL, GetModuleHandleW(NULL), NULL);
    CHECK(hwnd != NULL);
    const WCHAR a_name[] = L"Original", b_name[] = L"Modified";
    const ZdaSource specs[] = { { a_name, 8, 1, 0, 0, 0 }, { b_name, 8, 0, 1, 1, 0 } };
    Pending queue = {0}; ZdaNative *native = NULL; ZdaError error;
    CHECK(zda_native_create(hwnd, specs, 2, 16384, 64, 4096, enqueue, &queue, &error, &native) == ZDA_OK);
    const uint16_t units[] = { 'a', 0xd83d, 0xde00, 'e', 0x301, '\n' };
    const uint32_t scalars[] = { 0, 1, 3, 4, 5, 6 }, paragraphs[] = { 0, 6, 6 };
    ZdaTextInput inputs[2] = { { 1, units, scalars, paragraphs, 6, 6, 3 }, { 2, units, scalars, paragraphs, 6, 6, 3 } };
    ZdaText *candidate[2] = {0};
    for (int i = 0; i < 2; ++i) CHECK(zda_native_text(native, &inputs[i], &candidate[i]) == ZDA_OK);
    const ZdaSelection selected[] = { { 0, 0 }, { 3, 5 } };
    ZdaMetadata meta[2] = { { 1, 10, selected, 1, 0, 0, 1, 0 }, { 2, 20, selected, 2, 1, 1, 1, 0 } };
    CHECK(zda_native_publish(native, candidate, meta, 2) == ZDA_OK);
    for (int i = 0; i < 2; ++i) zda_text_release(candidate[i]);
    CHECK(zda_native_position(native, 100, 200, 2) == ZDA_OK);
    const ZdaCell cell = { 1, 3, { 4, 5, 8, 16 } };
    const ZdaCaret carets[] = {
        { 0, 1, { 4, 5, 0, 16 } }, { 1, 1, { 12, 5, 0, 16 } },
        { 3, 1, { 28, 5, 0, 16 } }, { 3, 0, { 28, 5, 0, 16 } },
        { 5, 1, { 28, 5, 0, 16 } }, { 5, 1, { 36, 5, 0, 16 } },
        { 6, 1, { 4, 21, 0, 16 } }, { 6, 0, { 4, 21, 0, 16 } }
    };
    const ZdaLine visual_lines[] = { { 0, 6, { 0, 5, 200, 16 } }, { 6, 2, { 0, 21, 200, 16 } } };
    ZdaGeometryInput geometry_input[2] = {
        { 1, 1, { 0, 0, 200, 100 }, &cell, 1, 2, carets, 8, visual_lines, 2 },
        { 2, 1, { 0, 0, 200, 100 }, &cell, 1, 2, carets, 8, visual_lines, 2 }
    };
    ZdaGeometry *geometry[2] = {0};
    for (int i = 0; i < 2; ++i) CHECK(fixture_hit(native, (uint32_t)i, &geometry_input[i], &geometry[i]) == ZDA_OK);
    CHECK(zda_native_publish_geometry(native, geometry, 2) == ZDA_OK);
    for (int i = 0; i < 2; ++i) zda_geometry_release(geometry[i]);
    IRawElementProviderSimple *a = zda_native_provider(native, 0), *b = zda_native_provider(native, 1), *root = zda_native_provider(native, UINT32_MAX);
    CHECK(a && b && root);
    ITextProvider *a_text = NULL, *b_text = NULL; ITextRangeProvider *a_range = NULL, *b_range = NULL;
    CHECK(SUCCEEDED(full_range(a, &a_text, &a_range)));
    CHECK(SUCCEEDED(full_range(b, &b_text, &b_range)));
    VARIANT availability;VariantInit(&availability);
    CHECK(SUCCEEDED(IRawElementProviderSimple_GetPropertyValue(b,UIA_IsTextPattern2AvailablePropertyId,&availability)) && availability.vt==VT_BOOL && availability.boolVal==VARIANT_TRUE);
    CHECK(SUCCEEDED(IRawElementProviderSimple_GetPropertyValue(root,UIA_IsTextPattern2AvailablePropertyId,&availability)) && availability.vt==VT_BOOL && availability.boolVal==VARIANT_FALSE);
    ITextProvider2 *a_text2 = NULL, *b_text2 = NULL;
    CHECK(SUCCEEDED(ITextProvider_QueryInterface(a_text, &IID_ITextProvider2, (void **)&a_text2)));
    CHECK(SUCCEEDED(ITextProvider_QueryInterface(b_text, &IID_ITextProvider2, (void **)&b_text2)));
    CHECK(ITextProvider2_AddRef(b_text2) > 1); CHECK(ITextProvider2_Release(b_text2) > 0);
    ITextProvider *back_to_base = NULL;
    CHECK(SUCCEEDED(ITextProvider2_QueryInterface(b_text2, &IID_ITextProvider, (void **)&back_to_base)) && back_to_base == b_text);
    ITextProvider_Release(back_to_base);
    IUnknown *group_text = NULL;
    CHECK(IRawElementProviderSimple_QueryInterface(root, &IID_ITextProvider2, (void **)&group_text) == E_NOINTERFACE && !group_text);
    IUnknown *base_identity = NULL, *extended_identity = NULL;
    CHECK(SUCCEEDED(ITextProvider_QueryInterface(b_text, &IID_IUnknown, (void **)&base_identity)));
    CHECK(SUCCEEDED(ITextProvider2_QueryInterface(b_text2, &IID_IUnknown, (void **)&extended_identity)) && base_identity == extended_identity);
    IUnknown_Release(base_identity); IUnknown_Release(extended_identity);
    ITextRangeProvider *extended_range = NULL;
    CHECK(SUCCEEDED(ITextProvider2_get_DocumentRange(b_text2, &extended_range)) && extended_range);
    ITextRangeProvider_Release(extended_range); extended_range = NULL;
    enum SupportedTextSelection extended_supported;
    CHECK(SUCCEEDED(ITextProvider2_get_SupportedTextSelection(b_text2, &extended_supported)) && extended_supported == SupportedTextSelection_Multiple);
    SAFEARRAY *extended_ranges = NULL;
    CHECK(SUCCEEDED(ITextProvider2_GetSelection(b_text2, &extended_ranges)) && extended_ranges); SafeArrayDestroy(extended_ranges);
    CHECK(SUCCEEDED(ITextProvider2_GetVisibleRanges(b_text2, &extended_ranges)) && extended_ranges); SafeArrayDestroy(extended_ranges);
    CHECK(SUCCEEDED(ITextProvider2_RangeFromPoint(b_text2, ((struct UiaPoint){ 124, 220 }), &extended_range)) && extended_range);
    ITextRangeProvider_Release(extended_range); extended_range = NULL;
    CHECK(ITextProvider2_RangeFromChild(b_text2, a, &extended_range) == E_INVALIDARG && !extended_range);
    CHECK(ITextProvider2_RangeFromAnnotation(b_text2, a, &extended_range) == (HRESULT)UIA_E_NOTSUPPORTED && !extended_range);
    WINBOOL caret_active = FALSE;
    CHECK(SUCCEEDED(ITextProvider2_GetCaretRange(b_text2, &caret_active, &extended_range)) && caret_active && extended_range);
    int caret_offset = -1, caret_width = -1;
    CHECK(SUCCEEDED(ITextRangeProvider_CompareEndpoints(extended_range, TextPatternRangeEndpoint_Start, b_range, TextPatternRangeEndpoint_Start, &caret_offset)) && caret_offset == 5);
    CHECK(SUCCEEDED(ITextRangeProvider_CompareEndpoints(extended_range, TextPatternRangeEndpoint_End, extended_range, TextPatternRangeEndpoint_Start, &caret_width)) && caret_width == 0);
    ITextRangeProvider_Release(extended_range); extended_range = NULL;
    CHECK(SUCCEEDED(ITextProvider2_GetCaretRange(a_text2, &caret_active, &extended_range)) && !caret_active && extended_range);
    ITextRangeProvider_Release(extended_range); extended_range = NULL;
    CHECK(point_offset(b_text, b_range, 124, 220, 1) == 0);
    CHECK(point_offset(b_text, b_range, 140, 220, 1) == 0);
    CHECK(point_offset(b_text, b_range, 156, 220, 3) == 0);
    CHECK(point_offset(b_text, b_range, 158, 220, 5) == 0);
    CHECK(point_offset(b_text, b_range, 172, 220, 5) == 0);
    CHECK(point_offset(b_text, b_range, 108, 250, 6) == 0);
    CHECK(point_offset(b_text, b_range, 108, 242, 6) == 0);
    ITextRangeProvider *missing = NULL;
    CHECK(ITextProvider_RangeFromPoint(b_text, ((struct UiaPoint){ 501, 250 }), &missing) == E_INVALIDARG && !missing);
    ZdaStats full_stats; zda_native_stats(native, &full_stats);
    const size_t remaining = (size_t)(full_stats.byte_limit - full_stats.bytes);
    CHECK(zda_account_reserve_host(native->account, remaining) == ZDA_OK);
    CHECK(ITextProvider_RangeFromPoint(b_text, ((struct UiaPoint){ 124, 220 }), &missing) == HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA) && !missing);
    zda_account_release_host(native->account, remaining);
    BSTR text = NULL; CHECK(SUCCEEDED(ITextRangeProvider_GetText(a_range, -1, &text)));
    CHECK(SysStringLen(text) == 6 && !memcmp(text, units, sizeof(units))); SysFreeString(text);
    CHECK(SUCCEEDED(ITextRangeProvider_GetText(b_range, 2, &text)));
    CHECK(SysStringLen(text) == 1 && text[0] == 'a'); SysFreeString(text);
    CHECK(ITextRangeProvider_GetText(b_range, -2, &text) == E_INVALIDARG && !text);
    WINBOOL same = TRUE; CHECK(SUCCEEDED(ITextRangeProvider_Compare(a_range, b_range, &same)) && !same);
    int difference; CHECK(ITextRangeProvider_CompareEndpoints(a_range, TextPatternRangeEndpoint_Start, b_range, TextPatternRangeEndpoint_Start, &difference) == E_INVALIDARG);
    enum SupportedTextSelection supported;
    CHECK(SUCCEEDED(ITextProvider_get_SupportedTextSelection(a_text, &supported)) && supported == SupportedTextSelection_None);
    CHECK(SUCCEEDED(ITextProvider_get_SupportedTextSelection(b_text, &supported)) && supported == SupportedTextSelection_Multiple);
    SAFEARRAY *ranges = NULL; CHECK(SUCCEEDED(ITextProvider_GetSelection(b_text, &ranges)));
    LONG last; CHECK(SUCCEEDED(SafeArrayGetUBound(ranges, 1, &last)) && last == 1); SafeArrayDestroy(ranges);
    CHECK(SUCCEEDED(ITextProvider_GetSelection(b_text, &ranges)));
    LONG first = 0; IUnknown *selection_unknown = NULL; ITextRangeProvider *selection_range = NULL;
    CHECK(SUCCEEDED(SafeArrayGetElement(ranges, &first, &selection_unknown)) && selection_unknown);
    CHECK(SUCCEEDED(IUnknown_QueryInterface(selection_unknown, &IID_ITextRangeProvider, (void **)&selection_range)));
    IUnknown *selection_identity = NULL;
    CHECK(SUCCEEDED(ITextRangeProvider_QueryInterface(selection_range, &IID_IUnknown, (void **)&selection_identity)) && selection_identity == selection_unknown);
    IUnknown_Release(selection_identity); ITextRangeProvider_Release(selection_range); IUnknown_Release(selection_unknown); SafeArrayDestroy(ranges);
    CHECK(ITextRangeProvider_Select(a_range) == (HRESULT)UIA_E_NOTSUPPORTED && queue.count == 0);
    ITextRangeProvider *cursor = NULL; CHECK(SUCCEEDED(ITextRangeProvider_Clone(b_range, &cursor)));
    CHECK(SUCCEEDED(ITextRangeProvider_MoveEndpointByRange(cursor, TextPatternRangeEndpoint_End, cursor, TextPatternRangeEndpoint_Start)));
    int moved; CHECK(SUCCEEDED(ITextRangeProvider_Move(cursor, TextUnit_Character, 1, &moved)) && moved == 1);
    CHECK(SUCCEEDED(ITextRangeProvider_ExpandToEnclosingUnit(cursor, TextUnit_Character)));
    CHECK(SUCCEEDED(ITextRangeProvider_GetText(cursor, -1, &text)));
    CHECK(SysStringLen(text) == 2 && text[0] == 0xd83d && text[1] == 0xde00); SysFreeString(text);
    CHECK(SUCCEEDED(ITextRangeProvider_Select(cursor)) && queue.count == 1);
    ZdaActionView action; CHECK(zda_native_take_action(queue.actions[0], &action));
    CHECK(action.source == 1 && action.text_version == 2 && action.revision == 20 && action.start == 1 && action.end == 3);
    zda_native_finish_action(queue.actions[0]); queue.count = 0;
    SAFEARRAY *rects = NULL; CHECK(SUCCEEDED(ITextRangeProvider_GetBoundingRectangles(cursor, &rects)));
    CHECK(SUCCEEDED(SafeArrayGetUBound(rects, 1, &last)) && last == 3);
    double expected_rect[] = { 108, 210, 16, 32 };
    for (LONG i = 0; i < 4; ++i) { double value; CHECK(SUCCEEDED(SafeArrayGetElement(rects, &i, &value)) && value == expected_rect[i]); }
    SafeArrayDestroy(rects);
    CHECK(zda_native_position(native, 300, 400, 2) == ZDA_OK);
    CHECK(SUCCEEDED(ITextRangeProvider_GetBoundingRectangles(cursor, &rects)));
    LONG zero = 0; double x; CHECK(SUCCEEDED(SafeArrayGetElement(rects, &zero, &x)) && x == 308); SafeArrayDestroy(rects);
    // Failed candidate storage cannot replace the currently queryable source.
    uint16_t large[2000]; uint32_t boundaries[2001], lines[] = { 0, 2000 };
    for (int i = 0; i < 2000; ++i) large[i] = 'x';
    for (int i = 0; i <= 2000; ++i) boundaries[i] = (uint32_t)i;
    ZdaTextInput too_large = { 3, large, boundaries, lines, 2000, 2001, 2 };
    ZdaText *rejected = NULL; CHECK(zda_native_text(native, &too_large, &rejected) == ZDA_CAPACITY && !rejected);
    CHECK(SUCCEEDED(ITextRangeProvider_GetText(a_range, -1, &text)) && SysStringLen(text) == 6); SysFreeString(text);
    ZdaStats stats; zda_native_stats(native, &stats); CHECK(stats.blobs == 4);
    CHECK(SUCCEEDED(ITextRangeProvider_Select(cursor)) && queue.count == 1);
    ZdaText *published[2] = {0};
    ZdaTextInput replacement = inputs[0]; replacement.text_version = 3;
    CHECK(zda_native_text(native, &replacement, &published[0]) == ZDA_OK);
    CHECK(SUCCEEDED(zda_acquire(native, 1, 2, &published[1], NULL, NULL)));
    meta[0].text_version = 3; meta[0].revision = 11;
    meta[1].revision = 21; meta[1].composing = 1;
    CHECK(zda_native_publish(native, published, meta, 2) == ZDA_OK);
    zda_text_release(published[0]); zda_text_release(published[1]);
    CHECK(ITextRangeProvider_GetText(a_range, -1, &text) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !text);
    CHECK(ITextProvider2_RangeFromPoint(a_text2, ((struct UiaPoint){ 324, 420 }), &extended_range) == (HRESULT)UIA_E_NOTSUPPORTED && !extended_range);
    CHECK(ITextProvider2_GetCaretRange(b_text2, &caret_active, &extended_range) == (HRESULT)UIA_E_NOTSUPPORTED && !extended_range && !caret_active);
    CHECK(SUCCEEDED(ITextProvider2_GetCaretRange(a_text2, &caret_active, &extended_range)) && extended_range && !caret_active);
    ITextRangeProvider_Release(extended_range); extended_range = NULL;
    IRawElementProviderFragmentRoot *root_interface = NULL;
    CHECK(SUCCEEDED(IRawElementProviderSimple_QueryInterface(root, &IID_IRawElementProviderFragmentRoot, (void **)&root_interface)));
    zda_native_begin_close(native);
    CHECK(ITextProvider2_GetCaretRange(b_text2, &caret_active, &extended_range) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !extended_range && !caret_active);
    CHECK(ITextProvider_RangeFromPoint(b_text, ((struct UiaPoint){ 124, 220 }), &missing) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !missing);
    CHECK(ITextRangeProvider_GetText(cursor, -1, &text) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE && !text);
    CHECK(!zda_native_take_action(queue.actions[0], &action));
    HRESULT disconnected = zda_native_disconnect(native);
    CHECK(SUCCEEDED(disconnected));
    DestroyWindow(hwnd);
    void *immutable_interface = NULL;
    CHECK(SUCCEEDED(IRawElementProviderSimple_QueryInterface(root, &IID_IRawElementProviderFragmentRoot, &immutable_interface)));
    IRawElementProviderFragmentRoot_Release((IRawElementProviderFragmentRoot *)immutable_interface);
    immutable_interface = NULL;
    CHECK(SUCCEEDED(ITextProvider_QueryInterface(b_text, &IID_ITextProvider2, &immutable_interface)));
    ITextProvider2_Release((ITextProvider2 *)immutable_interface);
    IRawElementProviderFragmentRoot_Release(root_interface);
    ITextRangeProvider_Release(cursor); ITextRangeProvider_Release(a_range); ITextRangeProvider_Release(b_range);
    ITextProvider_Release(a_text); ITextProvider_Release(b_text);
    ITextProvider2_Release(a_text2); ITextProvider2_Release(b_text2);
    IRawElementProviderSimple_Release(a); IRawElementProviderSimple_Release(b);
    zda_native_finish_action(queue.actions[0]);
    HANDLE thread = CreateThread(NULL, 0, late_release, root, 0, NULL); CHECK(thread != NULL);
    CHECK(WaitForSingleObject(thread, 5000) == WAIT_OBJECT_0); CloseHandle(thread);
    uint32_t after_accounts, after_blocks; uint64_t after_bytes;
    zda_ledger_counts(&after_accounts, &after_blocks, &after_bytes);
    CHECK(after_accounts == before_accounts && after_blocks == before_blocks && after_bytes == before_bytes);
    CoUninitialize(); return 0;
}

int zda_test_mapping(void) {
    CHECK(SUCCEEDED(CoInitializeEx(NULL,COINIT_APARTMENTTHREADED)));
    uint32_t accounts,blocks;uint64_t bytes;zda_ledger_counts(&accounts,&blocks,&bytes);
    const WCHAR name[]=L"Affine";
    const ZdaSource spec={name,6,0,1,1,0};
    HWND hwnd=CreateWindowExW(0,L"STATIC",L"Affine provider",WS_OVERLAPPEDWINDOW,0,0,430,270,NULL,NULL,GetModuleHandleW(NULL),NULL);CHECK(hwnd);
    Pending queue={0};ZdaNative *native=NULL;ZdaError error;
    CHECK(zda_native_create(hwnd,&spec,1,65536,64,4096,enqueue,&queue,&error,&native)==ZDA_OK);
    const uint16_t units[]={'a','b'};const uint32_t scalars[]={0,1,2},paragraphs[]={0,2};
    const ZdaTextInput input={1,units,scalars,paragraphs,2,3,2};
    ZdaText *text=NULL;CHECK(zda_native_text(native,&input,&text)==ZDA_OK);
    const ZdaSelection selection={0,0};const ZdaMetadata meta={1,1,&selection,1,0,0,1,0};
    CHECK(zda_native_publish(native,&text,&meta,1)==ZDA_OK);zda_text_release(text);
    CHECK(zda_native_position(native,100,200,2)==ZDA_OK);
    const ZdaCell cells[]={ {0,1,{10,0,20,20}}, {1,2,{40,0,10,20}} };
    const ZdaCaret carets[]={ {0,1,{10,0,0,20}}, {1,1,{30,0,0,20}}, {1,1,{50,0,0,20}}, {2,1,{50,0,0,20}} };
    const ZdaLine line={0,4,{0,0,100,20}};
    const ZdaGeometryInput geometry_input={1,1,{0,0,100,50},cells,2,2,carets,4,&line,1};
    ZdaGeometry *geometry=NULL;CHECK(fixture_hit(native,0,&geometry_input,&geometry)==ZDA_OK);
    CHECK(zda_native_publish_geometry(native,&geometry,1)==ZDA_OK);
    ZdaStats before;zda_native_stats(native,&before);
    const size_t remaining=(size_t)(before.byte_limit-before.bytes);
    CHECK(zda_account_reserve_host(native->account,remaining)==ZDA_OK);
    CHECK(zda_native_enable_mapping(native)==ZDA_CAPACITY);
    zda_account_release_host(native->account,remaining);
    CHECK(zda_native_enable_mapping(native)==ZDA_OK);
    CHECK(zda_native_enable_mapping(native)==ZDA_INVALID);
    ZdaMapping map={.forward={1,0,0.5,1,40,20},.inverse={1,0,-0.5,1,-30,-20},.polygon={{40,20},{100,20},{100,70},{65,70}},.count=4};
    CHECK(zda_native_publish_mapped(native,&geometry,&map,1)==ZDA_OK);
    IRawElementProviderSimple *provider=zda_native_provider(native,0);CHECK(provider);
    ITextProvider *pattern=NULL;ITextRangeProvider *full=NULL;CHECK(SUCCEEDED(full_range(provider,&pattern,&full)));
    CHECK(point_offset(pattern,full,250,260,1)==0);
    ITextRangeProvider *rejected=NULL;
    /* Inside the viewport AABB but outside its actual sheared polygon. */
    CHECK(ITextProvider_RangeFromPoint(pattern,((struct UiaPoint){182,320}),&rejected)==E_INVALIDARG && !rejected);
    SAFEARRAY *rects=NULL;CHECK(SUCCEEDED(ITextRangeProvider_GetBoundingRectangles(full,&rects)));
    LONG last;CHECK(SUCCEEDED(SafeArrayGetUBound(rects,1,&last)) && last==7);
    const double expected[]={200,240,60,40};
    for(LONG i=0;i<4;++i){double value;CHECK(SUCCEEDED(SafeArrayGetElement(rects,&i,&value)) && value==expected[i]);}SafeArrayDestroy(rects);
    /* Candidate failures never replace the existing mapping or blob. */
    ZdaMapping invalid=map;invalid.inverse[0]=0;
    CHECK(zda_native_publish_mapped(native,&geometry,&invalid,1)==ZDA_INVALID);
    invalid=map;invalid.forward[0]=1e12;invalid.forward[1]=1e12;invalid.forward[2]=-1e12;invalid.forward[3]=-1e12;
    invalid.inverse[0]=1e12;invalid.inverse[1]=1e12;invalid.inverse[2]=-1e12;invalid.inverse[3]=-1e12;
    CHECK(zda_native_publish_mapped(native,&geometry,&invalid,1)==ZDA_INVALID);
    invalid=map;invalid.reserved=1;CHECK(zda_native_publish_mapped(native,&geometry,&invalid,1)==ZDA_INVALID);
    invalid=map;invalid.count=133;CHECK(zda_native_publish_mapped(native,&geometry,&invalid,1)==ZDA_INVALID);
    invalid=map;invalid.polygon[1].x=NAN;CHECK(zda_native_publish_mapped(native,&geometry,&invalid,1)==ZDA_INVALID);
    invalid=map;invalid.polygon[1]=(ZdaPoint){50,30};CHECK(zda_native_publish_mapped(native,&geometry,&invalid,1)==ZDA_INVALID);
    CHECK(point_offset(pattern,full,250,260,1)==0);
    /* A narrower parent clip removes cell 2 and clips cell 1 to a triangle. */
    map.polygon[1]=(ZdaPoint){60,20};map.polygon[2]=(ZdaPoint){60,40};map.count=3;
    CHECK(zda_native_publish_mapped(native,&geometry,&map,1)==ZDA_OK);
    CHECK(SUCCEEDED(ITextRangeProvider_GetBoundingRectangles(full,&rects)));
    CHECK(SUCCEEDED(SafeArrayGetUBound(rects,1,&last)) && last==3);
    const double clipped[]={200,240,20,40};
    for(LONG i=0;i<4;++i){double value;CHECK(SUCCEEDED(SafeArrayGetElement(rects,&i,&value)) && value==clipped[i]);}SafeArrayDestroy(rects);
    SAFEARRAY *visible=NULL;CHECK(SUCCEEDED(ITextProvider_GetVisibleRanges(pattern,&visible)));
    CHECK(SUCCEEDED(SafeArrayGetUBound(visible,1,&last)) && last==0);SafeArrayDestroy(visible);
    /* A narrow visible piece of a glyph can have both real caret segments
       outside the clip. Return the true nearest endpoint, never invent one. */
    map=(ZdaMapping){.forward={1,0,0,1,0,0},.inverse={1,0,0,1,0,0},.polygon={{15,0},{16,0},{16,20},{15,20}},.count=4};
    CHECK(zda_native_publish_mapped(native,&geometry,&map,1)==ZDA_OK);
    CHECK(point_offset(pattern,full,131,220,0)==0);
    /* Reflection has opposite winding, not an AABB hit shortcut. */
    map=(ZdaMapping){.forward={-1,0,0,1,100,0},.inverse={-1,0,0,1,100,0},.polygon={{100,0},{0,0},{0,50},{100,50}},.count=4};
    CHECK(zda_native_publish_mapped(native,&geometry,&map,1)==ZDA_OK);
    CHECK(point_offset(pattern,full,240,220,1)==0);
    CHECK(point_offset(pattern,full,180,220,1)==0);
    ZdaStats stable;zda_native_stats(native,&stable);
    for(unsigned i=0;i<16;++i)CHECK(zda_native_publish_mapped(native,&geometry,&map,1)==ZDA_OK);
    ZdaStats after;zda_native_stats(native,&after);CHECK(after.bytes==stable.bytes && after.blobs==stable.blobs);
    map.count=0;CHECK(zda_native_publish_mapped(native,&geometry,&map,1)==ZDA_OK);
    CHECK(ITextProvider_RangeFromPoint(pattern,((struct UiaPoint){240,220}),&rejected)==E_INVALIDARG && !rejected);
    CHECK(SUCCEEDED(ITextRangeProvider_GetBoundingRectangles(full,&rects)));
    CHECK(SUCCEEDED(SafeArrayGetUBound(rects,1,&last)) && last==-1);SafeArrayDestroy(rects);
    /* Identity publication explicitly revokes a previous transformed map. */
    CHECK(zda_native_publish_geometry(native,&geometry,1)==ZDA_OK);
    CHECK(point_offset(pattern,full,160,220,1)==0);
    zda_geometry_release(geometry);zda_native_begin_close(native);
    CHECK(ITextProvider_RangeFromPoint(pattern,((struct UiaPoint){160,220}),&rejected)==(HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    CHECK(SUCCEEDED(zda_native_disconnect(native)));
    DestroyWindow(hwnd);
    ITextRangeProvider_Release(full);ITextProvider_Release(pattern);IRawElementProviderSimple_Release(provider);
    uint32_t final_accounts,final_blocks;uint64_t final_bytes;zda_ledger_counts(&final_accounts,&final_blocks,&final_bytes);
    CHECK(final_accounts==accounts && final_blocks==blocks && final_bytes==bytes);
    CoUninitialize();return 0;
}

int zda_test_hit_identity(void) {
    CHECK(SUCCEEDED(CoInitializeEx(NULL,COINIT_APARTMENTTHREADED)));
    uint32_t accounts,blocks;uint64_t bytes;zda_ledger_counts(&accounts,&blocks,&bytes);
    HWND hwnd=CreateWindowExW(0,L"STATIC",L"Owned hit identity",WS_OVERLAPPEDWINDOW,0,0,200,100,NULL,NULL,GetModuleHandleW(NULL),NULL);CHECK(hwnd);
    const ZdaSource specs[2]={{L"A",1,1,0,0,0},{L"B",1,1,0,0,0}};
    ZdaNative *first=NULL,*other=NULL;ZdaError error;
    CHECK(zda_native_create(hwnd,specs,2,131072,32,128,NULL,NULL,&error,&first)==ZDA_OK);
    CHECK(zda_native_create(hwnd,specs,1,131072,32,128,NULL,NULL,&error,&other)==ZDA_OK);
    const uint16_t units[]={'a','b'},changed[]={'x','y'};
    const uint32_t scalars[]={0,1,2},paragraphs[]={0,2};
    ZdaTextInput input={1,units,scalars,paragraphs,2,3,2};
    ZdaText *texts[2]={0},*foreign=NULL;
    for(unsigned i=0;i<2;++i)CHECK(zda_native_text(first,&input,&texts[i])==ZDA_OK);
    CHECK(zda_native_text(other,&input,&foreign)==ZDA_OK);
    const ZdaSelection selection={0,0};const ZdaMetadata meta[2]={{1,1,&selection,1,0,0,1,0},{1,1,&selection,1,0,0,1,0}};
    CHECK(zda_native_publish(first,texts,meta,2)==ZDA_OK);
    CHECK(zda_native_publish(other,&foreign,meta,1)==ZDA_OK);
    CHECK(zda_native_publish(other,texts,meta,1)==ZDA_INVALID && other->sources[0].text==foreign);
    const ZdaCaret carets[]={{0,1,{0,0,0,20}},{1,1,{10,0,0,20}},{2,1,{20,0,0,20}}};
    const ZdaLine line={0,3,{0,0,80,20}};
    const ZdaGeometryInput visible={1,1,{0,0,80,40},NULL,0,1,carets,3,&line,1};
    ZdaGeometry *geometry[2]={0},*other_geometry=NULL;
    for(unsigned i=0;i<2;++i)CHECK(fixture_hit(first,i,&visible,&geometry[i])==ZDA_OK);
    CHECK(fixture_hit(other,0,&visible,&other_geometry)==ZDA_OK);
    CHECK(zda_native_publish_geometry(first,geometry,2)==ZDA_OK);
    CHECK(zda_native_publish_geometry(other,&other_geometry,1)==ZDA_OK);
    CHECK(zda_storage_account(geometry[0])==first->account && zda_storage_account(geometry[0])!=other->account);
    CHECK(geometry[0]->hit->source==0 && geometry[0]->hit->text==texts[0]);
    CHECK(zda_native_publish_geometry(other,geometry,1)==ZDA_INVALID && other->sources[0].geometry==other_geometry);
    ZdaGeometry *wrong_slot[]={geometry[0],geometry[0]};
    CHECK(zda_native_publish_geometry(first,wrong_slot,2)==ZDA_INVALID && first->sources[1].geometry==geometry[1]);
    ZdaGeometry *legacy=NULL;CHECK(zda_native_geometry(first,&visible,&legacy)==ZDA_OK);
    CHECK(zda_native_publish_geometry(other,&legacy,1)==ZDA_INVALID);
    zda_geometry_release(legacy);
    input.text=changed;ZdaText *replacement=NULL;
    CHECK(zda_native_text(first,&input,&replacement)==ZDA_OK);
    ZdaText *next[]={replacement,texts[1]};
    CHECK(zda_native_publish(first,next,meta,2)==ZDA_OK);
    CHECK(first->sources[0].geometry==NULL && first->sources[1].geometry==geometry[1]);
    CHECK(geometry[0]->hit->text==texts[0]); /* The retired mirror remains owned. */
    CHECK(zda_native_publish_geometry(first,geometry,2)==ZDA_INVALID);
    ZdaGeometry *fresh=NULL;CHECK(fixture_hit(first,0,&visible,&fresh)==ZDA_OK);
    ZdaGeometry *new_bank[]={fresh,geometry[1]};CHECK(zda_native_publish_geometry(first,new_bank,2)==ZDA_OK);
    /* Even identical content with the same version is a different Text issuer. */
    ZdaText *clone=NULL;CHECK(zda_native_text(first,&input,&clone)==ZDA_OK);
    next[0]=clone;CHECK(zda_native_publish(first,next,meta,2)==ZDA_OK);
    CHECK(!first->sources[0].geometry && zda_native_publish_geometry(first,new_bank,2)==ZDA_INVALID);
    ZdaGeometry *clone_geometry=NULL;CHECK(fixture_hit(first,0,&visible,&clone_geometry)==ZDA_OK);
    new_bank[0]=clone_geometry;CHECK(zda_native_publish_geometry(first,new_bank,2)==ZDA_OK);
    first->geometry_serial=UINT64_MAX;
    CHECK(zda_native_publish_geometry(first,new_bank,2)==ZDA_CAPACITY);
    zda_native_withdraw_geometry(first,0);
    CHECK(!first->sources[0].geometry && !first->sources[1].geometry && first->sources[0].text==clone);
    CHECK(first->geometry_serial==UINT64_MAX);
    zda_native_withdraw_geometry(first,1);
    CHECK(!first->sources[0].text && first->sources[1].text==texts[1]);
    zda_native_begin_close(first);zda_native_begin_close(other);
    CHECK(SUCCEEDED(zda_native_disconnect(first)));CHECK(SUCCEEDED(zda_native_disconnect(other)));
    /* Late Geometry owns exact Text/account, not the retired NativeState. */
    CHECK(clone_geometry->hit->text==clone && clone_geometry->hit->input.packet.stops[1].position==1);
    zda_geometry_release(clone_geometry);zda_geometry_release(fresh);
    for(unsigned i=0;i<2;++i){zda_geometry_release(geometry[i]);zda_text_release(texts[i]);}
    zda_geometry_release(other_geometry);zda_text_release(foreign);zda_text_release(replacement);zda_text_release(clone);
    DestroyWindow(hwnd);
    uint32_t final_accounts,final_blocks;uint64_t final_bytes;zda_ledger_counts(&final_accounts,&final_blocks,&final_bytes);
    CHECK(final_accounts==accounts && final_blocks==blocks && final_bytes==bytes);
    CoUninitialize();return 0;
}

typedef struct PointSpy {
    IMallocSpy iface;LONG refs;DWORD owner;
    ZdaNative *state;ZdaGeometry *next;
    void *retired_block;
    BOOL allocation_armed,close_on_free;
    unsigned allocations,final_frees;
    int publish_result;
} PointSpy;
static ULONG STDMETHODCALLTYPE spy_add(IMallocSpy *p){return (ULONG)InterlockedIncrement(&((PointSpy *)p)->refs);}
static ULONG STDMETHODCALLTYPE spy_release(IMallocSpy *p){
    PointSpy *spy=(PointSpy *)p;LONG refs=InterlockedDecrement(&spy->refs);
    if(!refs)HeapFree(GetProcessHeap(),0,spy);
    return (ULONG)refs;
}
static HRESULT STDMETHODCALLTYPE spy_query(IMallocSpy *p,REFIID iid,void **out){
    if(!out)return E_POINTER;*out=NULL;
    if(!IsEqualIID(iid,&IID_IUnknown)&&!IsEqualIID(iid,&IID_IMallocSpy))return E_NOINTERFACE;
    *out=p;spy_add(p);return S_OK;
}
static SIZE_T STDMETHODCALLTYPE spy_pre_alloc(IMallocSpy *p,SIZE_T bytes){(void)p;return bytes;}
static void * STDMETHODCALLTYPE spy_post_alloc(IMallocSpy *p,void *actual){
    PointSpy *spy=(PointSpy *)p;
    /* COM observes process-wide allocations. Only the fixture owner may touch
       its NativeState or the mutable arming fields. */
    if(GetCurrentThreadId()==spy->owner&&spy->state&&actual&&spy->allocation_armed){
        spy->allocation_armed=FALSE;spy->allocations++;
        spy->publish_result=zda_native_publish_geometry(spy->state,&spy->next,1);
    }
    return actual;
}
static void * STDMETHODCALLTYPE spy_pre_free(IMallocSpy *p,void *request,BOOL tracked){
    (void)tracked;PointSpy *spy=(PointSpy *)p;
    if(GetCurrentThreadId()==spy->owner&&spy->state&&request==spy->retired_block){
        spy->retired_block=NULL;spy->final_frees++;
        if(spy->close_on_free)zda_native_begin_close(spy->state);
    }
    return request;
}
static void STDMETHODCALLTYPE spy_post_free(IMallocSpy *p,BOOL tracked){(void)p;(void)tracked;}
static SIZE_T STDMETHODCALLTYPE spy_pre_realloc(IMallocSpy *p,void *request,SIZE_T bytes,void **replacement,BOOL tracked){(void)p;(void)tracked;*replacement=request;return bytes;}
static void * STDMETHODCALLTYPE spy_post_realloc(IMallocSpy *p,void *actual,BOOL tracked){(void)p;(void)tracked;return actual;}
static void * STDMETHODCALLTYPE spy_pre_size(IMallocSpy *p,void *request,BOOL tracked){(void)p;(void)tracked;return request;}
static SIZE_T STDMETHODCALLTYPE spy_post_size(IMallocSpy *p,SIZE_T actual,BOOL tracked){(void)p;(void)tracked;return actual;}
static void * STDMETHODCALLTYPE spy_pre_did(IMallocSpy *p,void *request,BOOL tracked){(void)p;(void)tracked;return request;}
static int STDMETHODCALLTYPE spy_post_did(IMallocSpy *p,void *request,BOOL tracked,int actual){(void)p;(void)request;(void)tracked;return actual;}
static void STDMETHODCALLTYPE spy_heap(IMallocSpy *p){(void)p;}
static const IMallocSpyVtbl point_spy_vtable={spy_query,spy_add,spy_release,spy_pre_alloc,spy_post_alloc,spy_pre_free,spy_post_free,spy_pre_realloc,spy_post_realloc,spy_pre_size,spy_post_size,spy_pre_did,spy_post_did,spy_heap,spy_heap};

int zda_test_hit_foreign(void) {
    CHECK(SUCCEEDED(CoInitializeEx(NULL,COINIT_APARTMENTTHREADED)));
    uint32_t accounts,blocks;uint64_t bytes;zda_ledger_counts(&accounts,&blocks,&bytes);
    HWND hwnd=CreateWindowExW(0,L"STATIC",L"Point foreign release",WS_OVERLAPPEDWINDOW,0,0,200,100,NULL,NULL,GetModuleHandleW(NULL),NULL);CHECK(hwnd);
    for(unsigned close=0;close<2;++close){
        const ZdaSource spec={L"Point",5,1,0,0,0};ZdaNative *state=NULL;ZdaError error;
        CHECK(zda_native_create(hwnd,&spec,1,131072,32,128,NULL,NULL,&error,&state)==ZDA_OK);
        const uint16_t units[]={'a','b'};const uint32_t scalars[]={0,1,2},paragraphs[]={0,2};
        const ZdaTextInput input={1,units,scalars,paragraphs,2,3,2};ZdaText *text=NULL;
        CHECK(zda_native_text(state,&input,&text)==ZDA_OK);
        const ZdaSelection selection={0,0};const ZdaMetadata metadata={1,1,&selection,1,0,0,1,0};
        CHECK(zda_native_publish(state,&text,&metadata,1)==ZDA_OK);zda_text_release(text);
        const ZdaCaret carets[]={{0,1,{0,0,0,20}},{1,1,{10,0,0,20}},{2,1,{20,0,0,20}}};
        const ZdaLine line={0,3,{0,0,80,20}};
        const ZdaGeometryInput visible={1,1,{0,0,80,40},NULL,0,1,carets,3,&line,1};
        ZdaGeometry *old=NULL,*next=NULL;
        CHECK(fixture_hit(state,0,&visible,&old)==ZDA_OK && fixture_hit(state,0,&visible,&next)==ZDA_OK);
        CHECK(zda_native_publish_geometry(state,&old,1)==ZDA_OK);
        IRawElementProviderSimple *simple=zda_native_provider(state,0);CHECK(simple);
        ITextProvider *provider=NULL;ITextRangeProvider *full=NULL;
        CHECK(SUCCEEDED(full_range(simple,&provider,&full)));
        IRawElementProviderFragmentRoot *root=NULL;
        CHECK(SUCCEEDED(IRawElementProviderSimple_QueryInterface(simple,&IID_IRawElementProviderFragmentRoot,(void **)&root)));
        IRawElementProviderFragment *miss=(void *)1;
        CHECK(IRawElementProviderFragmentRoot_ElementProviderFromPoint(root,1000,1000,&miss)==S_OK && !miss);
        /* Drop the normal caller ref; the front owns old until PostAlloc swaps
           it, then the real in-flight getter is its sole Geometry pin. */
        PointSpy *spy=HeapAlloc(GetProcessHeap(),HEAP_ZERO_MEMORY,sizeof(*spy));CHECK(spy);
        spy->iface.lpVtbl=&point_spy_vtable;spy->refs=1;spy->owner=GetCurrentThreadId();
        spy->state=state;spy->next=next;spy->retired_block=(char *)old-zda_storage_footprint(0);
        spy->close_on_free=(BOOL)close;spy->publish_result=-1;
        zda_geometry_release(old);
        int failure=0;
        HRESULT registered=CoRegisterMallocSpy(&spy->iface);
        if(FAILED(registered))failure=__LINE__;
        else {
            spy->allocation_armed=TRUE;
            ITextRangeProvider *result=(void *)1;
            HRESULT hr=ITextProvider_RangeFromPoint(provider,((struct UiaPoint){1,10}),&result);
            if(hr!=(HRESULT)UIA_E_ELEMENTNOTAVAILABLE || result)failure=__LINE__;
            /* A controlled RED may return an unexpected owning range. Retire
               it before revoking the process-wide observer. */
            if(result&&result!=(void *)1)ITextRangeProvider_Release(result);
            if(!failure&&(spy->allocations!=1 || spy->publish_result!=ZDA_OK || spy->final_frees!=1))failure=__LINE__;
        }
        spy->allocation_armed=FALSE;spy->retired_block=NULL;spy->state=NULL;spy->next=NULL;
        if(SUCCEEDED(registered)){
            HRESULT revoked=CoRevokeMallocSpy();
            if(!failure&&(FAILED(revoked)||InterlockedCompareExchange(&spy->refs,0,0)!=1))failure=__LINE__;
        }
        /* A failed revoke can retain COM's registration reference. The inert
           heap object then outlives this stack and every fixture owner. */
        spy_release(&spy->iface);
        zda_geometry_release(next);zda_native_begin_close(state);
        HRESULT disconnected=zda_native_disconnect(state);
        IRawElementProviderFragmentRoot_Release(root);ITextRangeProvider_Release(full);ITextProvider_Release(provider);IRawElementProviderSimple_Release(simple);
        if(!failure&&FAILED(disconnected))failure=__LINE__;
        if(failure){DestroyWindow(hwnd);CoUninitialize();return failure;}
    }
    DestroyWindow(hwnd);
    uint32_t final_accounts,final_blocks;uint64_t final_bytes;zda_ledger_counts(&final_accounts,&final_blocks,&final_bytes);
    CHECK(final_accounts==accounts && final_blocks==blocks && final_bytes==bytes);
    CoUninitialize();return 0;
}
