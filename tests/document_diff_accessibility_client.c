#define COBJMACROS
#define CONST_VTABLE
#define WIN32_LEAN_AND_MEAN
#define NO_STRICT
#include <windows.h>
#include <uiautomation.h>
#include <oleauto.h>
#include <stdint.h>
static HRESULT text_range(void *pointer,ITextProvider **text,ITextRangeProvider **range) {
    IUnknown *pattern=NULL;
    HRESULT hr=IRawElementProviderSimple_GetPatternProvider((IRawElementProviderSimple *)pointer,UIA_TextPatternId,&pattern);
    if(SUCCEEDED(hr)&&!pattern)hr=E_NOINTERFACE;
    if(SUCCEEDED(hr)){hr=IUnknown_QueryInterface(pattern,&IID_ITextProvider,(void **)text);IUnknown_Release(pattern);}
    if(SUCCEEDED(hr))hr=ITextProvider_get_DocumentRange(*text,range);
    return hr;
}
int32_t zdd_probe_action(void *pointer,uint32_t kind,const uint16_t *needle,uint32_t length) {
    HRESULT initialized=CoInitializeEx(NULL,COINIT_MULTITHREADED);if(FAILED(initialized))return initialized;
    HRESULT hr;
    if(kind==0){IRawElementProviderFragment *fragment=NULL;hr=IRawElementProviderSimple_QueryInterface((IRawElementProviderSimple *)pointer,&IID_IRawElementProviderFragment,(void **)&fragment);if(SUCCEEDED(hr)){hr=IRawElementProviderFragment_SetFocus(fragment);IRawElementProviderFragment_Release(fragment);}}
    else {
        ITextProvider *text=NULL;ITextRangeProvider *range=NULL,*found=NULL;BSTR query=SysAllocStringLen(needle,length);
        hr=query?text_range(pointer,&text,&range):E_OUTOFMEMORY;
        if(SUCCEEDED(hr))hr=ITextRangeProvider_FindText(range,query,FALSE,FALSE,&found);
        if(SUCCEEDED(hr))hr=found?(kind==1?ITextRangeProvider_Select(found):(kind==4?ITextRangeProvider_AddToSelection(found):ITextRangeProvider_ScrollIntoView(found,kind==2))):E_FAIL;
        if(found)ITextRangeProvider_Release(found);if(range)ITextRangeProvider_Release(range);if(text)ITextProvider_Release(text);SysFreeString(query);
    }
    CoUninitialize();return hr;
}
int32_t zdd_probe_identity(void *a,void *b) {
    ITextProvider *ta=NULL,*tb=NULL;ITextRangeProvider *ra=NULL,*rb=NULL;
    HRESULT hr=text_range(a,&ta,&ra);if(SUCCEEDED(hr))hr=text_range(b,&tb,&rb);
    int distance=0;if(SUCCEEDED(hr))hr=ITextRangeProvider_CompareEndpoints(ra,TextPatternRangeEndpoint_Start,rb,TextPatternRangeEndpoint_Start,&distance);
    if(ra)ITextRangeProvider_Release(ra);if(rb)ITextRangeProvider_Release(rb);if(ta)ITextProvider_Release(ta);if(tb)ITextProvider_Release(tb);return hr;
}
int32_t zdd_probe_hit(void *root,void *wanted,const uint16_t *needle,uint32_t length) {
    ITextProvider *text=NULL;ITextRangeProvider *range=NULL,*found=NULL;SAFEARRAY *rects=NULL;BSTR query=SysAllocStringLen(needle,length);
    HRESULT hr=query?text_range(wanted,&text,&range):E_OUTOFMEMORY;
    if(SUCCEEDED(hr))hr=ITextRangeProvider_FindText(range,query,FALSE,FALSE,&found);
    if(SUCCEEDED(hr))hr=found?ITextRangeProvider_GetBoundingRectangles(found,&rects):E_FAIL;
    LONG last=-1;if(SUCCEEDED(hr))hr=SafeArrayGetUBound(rects,1,&last);
    IRawElementProviderFragmentRoot *fragment_root=NULL;IRawElementProviderFragment *hit=NULL;IUnknown *a=NULL,*b=NULL;
    if(SUCCEEDED(hr)&&last<3)hr=E_FAIL;
    if(SUCCEEDED(hr))hr=IRawElementProviderSimple_QueryInterface((IRawElementProviderSimple *)root,&IID_IRawElementProviderFragmentRoot,(void **)&fragment_root);
    if(SUCCEEDED(hr)){double *values=NULL;hr=SafeArrayAccessData(rects,(void **)&values);if(SUCCEEDED(hr)){hr=IRawElementProviderFragmentRoot_ElementProviderFromPoint(fragment_root,values[0]+values[2]*.5,values[1]+values[3]*.5,&hit);SafeArrayUnaccessData(rects);}}
    if(SUCCEEDED(hr)&&!hit)hr=E_FAIL;
    if(SUCCEEDED(hr))hr=IRawElementProviderFragment_QueryInterface(hit,&IID_IUnknown,(void **)&a);
    if(SUCCEEDED(hr))hr=IRawElementProviderSimple_QueryInterface((IRawElementProviderSimple *)wanted,&IID_IUnknown,(void **)&b);
    if(SUCCEEDED(hr)&&a!=b)hr=E_FAIL;
    if(a)IUnknown_Release(a);if(b)IUnknown_Release(b);if(hit)IRawElementProviderFragment_Release(hit);if(fragment_root)IRawElementProviderFragmentRoot_Release(fragment_root);
    if(rects)SafeArrayDestroy(rects);if(found)ITextRangeProvider_Release(found);if(range)ITextRangeProvider_Release(range);if(text)ITextProvider_Release(text);SysFreeString(query);return hr;
}
int32_t zdd_probe_point(void *pointer,const uint16_t *needle,uint32_t length,uint32_t *offset,uint32_t *rect_count) {
    ITextProvider *text=NULL;ITextRangeProvider *range=NULL,*found=NULL,*point=NULL;SAFEARRAY *rects=NULL;BSTR query=SysAllocStringLen(needle,length);
    HRESULT hr=query?text_range(pointer,&text,&range):E_OUTOFMEMORY;
    if(SUCCEEDED(hr))hr=ITextRangeProvider_FindText(range,query,FALSE,FALSE,&found);
    if(SUCCEEDED(hr))hr=found?ITextRangeProvider_GetBoundingRectangles(found,&rects):E_FAIL;
    LONG last=-1;*rect_count=0;
    if(SUCCEEDED(hr))hr=SafeArrayGetUBound(rects,1,&last);
    if(SUCCEEDED(hr)){*rect_count=(uint32_t)(last+1)/4;if(last>=3){double *values=NULL;hr=SafeArrayAccessData(rects,(void **)&values);if(SUCCEEDED(hr)){struct UiaPoint p={values[0]+values[2]*0.25,values[1]+values[3]*0.5};hr=ITextProvider_RangeFromPoint(text,p,&point);SafeArrayUnaccessData(rects);if(SUCCEEDED(hr)){int distance=0;hr=ITextRangeProvider_CompareEndpoints(point,TextPatternRangeEndpoint_Start,range,TextPatternRangeEndpoint_Start,&distance);*offset=(uint32_t)distance;}}}}
    if(rects)SafeArrayDestroy(rects);if(point)ITextRangeProvider_Release(point);if(found)ITextRangeProvider_Release(found);if(range)ITextRangeProvider_Release(range);if(text)ITextProvider_Release(text);SysFreeString(query);return hr;
}
int32_t zdd_probe_point_hit_mta(void *root,void *source,const uint16_t *needle,uint32_t length,uint32_t *offset,uint32_t *rect_count) {
    HRESULT initialized=CoInitializeEx(NULL,COINIT_MULTITHREADED);if(FAILED(initialized))return initialized;
    HRESULT hr=zdd_probe_point(source,needle,length,offset,rect_count);
    if(SUCCEEDED(hr))hr=zdd_probe_hit(root,source,needle,length);
    CoUninitialize();return hr;
}
int32_t zdd_probe_auxiliary(void *pointer,uint32_t kind,double *x) {
    HRESULT initialized=CoInitializeEx(NULL,COINIT_MULTITHREADED);if(FAILED(initialized))return initialized;
    IRawElementProviderSimple*p=pointer;HRESULT hr=S_OK;
    if(kind==0){
        VARIANT name;VariantInit(&name);hr=IRawElementProviderSimple_GetPropertyValue(p,UIA_NamePropertyId,&name);
        if(SUCCEEDED(hr)&&(name.vt!=VT_BSTR||wcscmp(name.bstrVal,L"Action")))hr=E_FAIL;VariantClear(&name);
        IRawElementProviderFragment*f=NULL;struct UiaRect r;
        if(SUCCEEDED(hr))hr=IRawElementProviderSimple_QueryInterface(p,&IID_IRawElementProviderFragment,(void**)&f);
        if(SUCCEEDED(hr))hr=IRawElementProviderFragment_get_BoundingRectangle(f,&r);
        if(SUCCEEDED(hr))*x=r.left;if(f)IRawElementProviderFragment_Release(f);
    }else if(kind==1){IInvokeProvider*invoke=NULL;hr=IRawElementProviderSimple_QueryInterface(p,&IID_IInvokeProvider,(void**)&invoke);if(SUCCEEDED(hr)){hr=IInvokeProvider_Invoke(invoke);IInvokeProvider_Release(invoke);}}
    else if(kind==4){IRawElementProviderFragment*f=NULL;hr=IRawElementProviderSimple_QueryInterface(p,&IID_IRawElementProviderFragment,(void**)&f);if(SUCCEEDED(hr)){hr=IRawElementProviderFragment_SetFocus(f);IRawElementProviderFragment_Release(f);}}
    else{IExpandCollapseProvider*expand=NULL;hr=IRawElementProviderSimple_QueryInterface(p,&IID_IExpandCollapseProvider,(void**)&expand);if(SUCCEEDED(hr)){hr=kind==2?IExpandCollapseProvider_Expand(expand):IExpandCollapseProvider_Collapse(expand);IExpandCollapseProvider_Release(expand);}}
    CoUninitialize();return hr;
}
int32_t zdd_probe_auxiliary_hit_mta(void *root,void *expected,double x,double y){
    HRESULT hr=CoInitializeEx(NULL,COINIT_MULTITHREADED);if(FAILED(hr))return hr;
    IRawElementProviderFragmentRoot*r=NULL;IRawElementProviderFragment*hit=NULL;IUnknown*a=NULL,*b=NULL;
    hr=IRawElementProviderSimple_QueryInterface((IRawElementProviderSimple*)root,&IID_IRawElementProviderFragmentRoot,(void**)&r);
    if(SUCCEEDED(hr))hr=IRawElementProviderFragmentRoot_ElementProviderFromPoint(r,x,y,&hit);
    if(SUCCEEDED(hr)&&!hit)hr=E_FAIL;
    if(SUCCEEDED(hr))hr=IRawElementProviderFragment_QueryInterface(hit,&IID_IUnknown,(void**)&a);
    if(SUCCEEDED(hr))hr=IRawElementProviderSimple_QueryInterface((IRawElementProviderSimple*)expected,&IID_IUnknown,(void**)&b);
    if(SUCCEEDED(hr)&&a!=b)hr=E_FAIL;
    if(a)IUnknown_Release(a);if(b)IUnknown_Release(b);if(hit)IRawElementProviderFragment_Release(hit);if(r)IRawElementProviderFragmentRoot_Release(r);
    CoUninitialize();return hr;
}
static HRESULT auxiliary_find(IUIAutomation *api,IUIAutomationElement *root,const WCHAR *name,IUIAutomationElement **out){
    VARIANT value;VariantInit(&value);value.vt=VT_BSTR;value.bstrVal=SysAllocString(name);if(!value.bstrVal)return E_OUTOFMEMORY;
    IUIAutomationCondition *condition=NULL;HRESULT hr=IUIAutomation_CreatePropertyCondition(api,UIA_NamePropertyId,value,&condition);VariantClear(&value);
    if(SUCCEEDED(hr))hr=IUIAutomationElement_FindFirst(root,TreeScope_Descendants,condition,out);
    if(condition)IUIAutomationCondition_Release(condition);return SUCCEEDED(hr)&&!*out?E_FAIL:hr;
}
int32_t zdd_probe_auxiliary_window(void *hwnd){
    HRESULT hr=CoInitializeEx(NULL,COINIT_MULTITHREADED);if(FAILED(hr))return hr;
    IUIAutomation*api=NULL;IUIAutomation2*api2=NULL;IUIAutomationElement *root=NULL,*tools=NULL,*button=NULL,*original=NULL,*modified=NULL;
    IUIAutomationInvokePattern*invoke=NULL;IUIAutomationTextPattern*text=NULL;IUIAutomationTextRange*range=NULL;BSTR contents=NULL;
    hr=CoCreateInstance(&CLSID_CUIAutomation8,NULL,CLSCTX_INPROC_SERVER,&IID_IUIAutomation,(void**)&api);
    if(SUCCEEDED(hr))hr=IUIAutomation_QueryInterface(api,&IID_IUIAutomation2,(void**)&api2);
    if(SUCCEEDED(hr))hr=IUIAutomation2_put_ConnectionTimeout(api2,2000);
    if(SUCCEEDED(hr))hr=IUIAutomation2_put_TransactionTimeout(api2,2000);
    if(SUCCEEDED(hr))hr=IUIAutomation_ElementFromHandle(api,(HWND)hwnd,&root);
    if(SUCCEEDED(hr))hr=auxiliary_find(api,root,L"Tools",&tools);
    if(SUCCEEDED(hr))hr=auxiliary_find(api,tools,L"Action",&button);
    if(SUCCEEDED(hr))hr=IUIAutomationElement_GetCurrentPatternAs(button,UIA_InvokePatternId,&IID_IUIAutomationInvokePattern,(void**)&invoke);
    if(SUCCEEDED(hr))hr=auxiliary_find(api,root,L"Original",&original);
    if(SUCCEEDED(hr))hr=auxiliary_find(api,root,L"Modified",&modified);
    if(SUCCEEDED(hr))hr=IUIAutomationElement_GetCurrentPatternAs(original,UIA_TextPatternId,&IID_IUIAutomationTextPattern,(void**)&text);
    if(SUCCEEDED(hr))hr=IUIAutomationTextPattern_get_DocumentRange(text,&range);
    if(SUCCEEDED(hr))hr=IUIAutomationTextRange_GetText(range,-1,&contents);
    if(SUCCEEDED(hr)&&(!contents||!wcsstr(contents,L"removed")))hr=E_FAIL;
    SysFreeString(contents);if(range)IUIAutomationTextRange_Release(range);if(text)IUIAutomationTextPattern_Release(text);
    if(invoke)IUIAutomationInvokePattern_Release(invoke);if(modified)IUIAutomationElement_Release(modified);if(original)IUIAutomationElement_Release(original);if(button)IUIAutomationElement_Release(button);if(tools)IUIAutomationElement_Release(tools);if(root)IUIAutomationElement_Release(root);if(api2)IUIAutomation2_Release(api2);if(api)IUIAutomation_Release(api);
    CoUninitialize();return hr;
}
