#define COBJMACROS
#define CONST_VTABLE
#define WIN32_LEAN_AND_MEAN
#define NO_STRICT
#include <windows.h>
#include <uiautomation.h>
#include <oleauto.h>
#include <string.h>
#include <stdint.h>
static HRESULT full(IRawElementProviderSimple *provider, ITextProvider **text, ITextRangeProvider **range) {
    IUnknown *pattern = NULL;
    HRESULT hr = IRawElementProviderSimple_GetPatternProvider(provider, UIA_TextPatternId, &pattern);
    if (FAILED(hr) || !pattern) return FAILED(hr) ? hr : E_NOINTERFACE;
    hr = IUnknown_QueryInterface(pattern, &IID_ITextProvider, (void **)text);
    IUnknown_Release(pattern);
    if (SUCCEEDED(hr)) hr = ITextProvider_get_DocumentRange(*text, range);
    return hr;
}
int32_t zda_probe_read(void *pointer, uint16_t *output, uint32_t capacity, uint32_t *length) {
    ITextProvider *text = NULL; ITextRangeProvider *range = NULL;
    HRESULT hr = full(pointer, &text, &range);
    BSTR value = NULL;
    if (SUCCEEDED(hr)) hr = ITextRangeProvider_GetText(range, -1, &value);
    if (SUCCEEDED(hr)) {
        *length = SysStringLen(value);
        if (*length > capacity) hr = HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA);
        else if (*length) memcpy(output, value, *length * sizeof(uint16_t));
    }
    SysFreeString(value);
    if (range) ITextRangeProvider_Release(range);
    if (text) ITextProvider_Release(text);
    return hr;
}
int32_t zda_probe_word_text(void *pointer,const uint16_t *needle,uint32_t needle_length,uint16_t *output,uint32_t capacity,uint32_t *length) {
    ITextProvider *text=NULL;ITextRangeProvider *range=NULL,*found=NULL;
    HRESULT hr=full(pointer,&text,&range);
    BSTR query=SysAllocStringLen(needle,needle_length),value=NULL;
    if(!query)hr=E_OUTOFMEMORY;
    if(SUCCEEDED(hr))hr=ITextRangeProvider_FindText(range,query,FALSE,FALSE,&found);
    if(SUCCEEDED(hr))hr=found?ITextRangeProvider_ExpandToEnclosingUnit(found,TextUnit_Word):E_FAIL;
    if(SUCCEEDED(hr))hr=ITextRangeProvider_GetText(found,-1,&value);
    if(SUCCEEDED(hr)) {
        *length=SysStringLen(value);
        if(*length>capacity)hr=HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA);
        else if(*length)memcpy(output,value,*length*sizeof(uint16_t));
    }
    SysFreeString(value);SysFreeString(query);
    if(found)ITextRangeProvider_Release(found);
    if(range)ITextRangeProvider_Release(range);
    if(text)ITextProvider_Release(text);return hr;
}
int32_t zda_probe_select(void *pointer, const uint16_t *needle, uint32_t length) {
    ITextProvider *text = NULL; ITextRangeProvider *range = NULL, *found = NULL;
    HRESULT hr = full(pointer, &text, &range);
    BSTR query = SysAllocStringLen(needle, length);
    if (!query) hr = E_OUTOFMEMORY;
    if (SUCCEEDED(hr)) hr = ITextRangeProvider_FindText(range, query, FALSE, FALSE, &found);
    if (SUCCEEDED(hr)) hr = found ? ITextRangeProvider_Select(found) : E_FAIL;
    SysFreeString(query);
    if (found) ITextRangeProvider_Release(found);
    if (range) ITextRangeProvider_Release(range);
    if (text) ITextProvider_Release(text);
    return hr;
}
int32_t zda_probe_match_rectangles(void *pointer, const uint16_t *needle, uint32_t length, uint32_t *count) {
    ITextProvider *text = NULL; ITextRangeProvider *range = NULL, *found = NULL;
    HRESULT hr = full(pointer, &text, &range);
    BSTR query = SysAllocStringLen(needle, length);
    SAFEARRAY *array = NULL; *count = 0;
    if (!query) hr = E_OUTOFMEMORY;
    if (SUCCEEDED(hr)) hr = ITextRangeProvider_FindText(range, query, FALSE, FALSE, &found);
    if (SUCCEEDED(hr)) hr = found ? ITextRangeProvider_GetBoundingRectangles(found, &array) : E_FAIL;
    if (SUCCEEDED(hr)) { LONG end = -1; hr = SafeArrayGetUBound(array, 1, &end); if (SUCCEEDED(hr)) *count = (uint32_t)(end + 1) / 4; }
    if (array) SafeArrayDestroy(array);
    SysFreeString(query);
    if (found) ITextRangeProvider_Release(found);
    if (range) ITextRangeProvider_Release(range);
    if (text) ITextProvider_Release(text);
    return hr;
}
int32_t zda_probe_selection(void *pointer, uint16_t *output, uint32_t capacity, uint32_t *length) {
    ITextProvider *text = NULL; ITextRangeProvider *document = NULL, *range = NULL;
    HRESULT hr = full(pointer, &text, &document);
    SAFEARRAY *array = NULL; IUnknown *unknown = NULL; BSTR value = NULL;
    if (SUCCEEDED(hr)) hr = ITextProvider_GetSelection(text, &array);
    LONG first = 0;
    if (SUCCEEDED(hr)) hr = SafeArrayGetElement(array, &first, &unknown);
    if (SUCCEEDED(hr)) hr = IUnknown_QueryInterface(unknown, &IID_ITextRangeProvider, (void **)&range);
    if (SUCCEEDED(hr)) hr = ITextRangeProvider_GetText(range, -1, &value);
    if (SUCCEEDED(hr)) {
        *length = SysStringLen(value);
        if (*length > capacity) hr = HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA);
        else if (*length) memcpy(output, value, *length * sizeof(uint16_t));
    }
    SysFreeString(value);
    if (range) ITextRangeProvider_Release(range);
    if (unknown) IUnknown_Release(unknown);
    if (array) SafeArrayDestroy(array);
    if (document) ITextRangeProvider_Release(document);
    if (text) ITextProvider_Release(text);
    return hr;
}
int32_t zda_probe_rectangles(void *pointer, uint32_t *count, double *x, double *y) {
    ITextProvider *text = NULL; ITextRangeProvider *range = NULL;
    HRESULT hr = full(pointer, &text, &range);
    SAFEARRAY *array = NULL;
    if (SUCCEEDED(hr)) hr = ITextRangeProvider_GetBoundingRectangles(range, &array);
    *count = 0;
    if (SUCCEEDED(hr) && array) {
        LONG end = -1, at = 0;
        hr = SafeArrayGetUBound(array, 1, &end);
        if (SUCCEEDED(hr)) *count = (uint32_t)(end + 1) / 4;
        if (SUCCEEDED(hr) && *count) {
            hr = SafeArrayGetElement(array, &at, x); ++at;
            if (SUCCEEDED(hr)) hr = SafeArrayGetElement(array, &at, y);
        }
    }
    if (array) SafeArrayDestroy(array);
    if (range) ITextRangeProvider_Release(range);
    if (text) ITextProvider_Release(text);
    return hr;
}
int32_t zda_probe_all_rectangles(void *pointer, double *values, uint32_t capacity, uint32_t *count) {
    ITextProvider *text=NULL;ITextRangeProvider *range=NULL;SAFEARRAY *array=NULL;
    HRESULT hr=full(pointer,&text,&range);*count=0;
    if(SUCCEEDED(hr))hr=ITextRangeProvider_GetBoundingRectangles(range,&array);
    LONG last=-1;
    if(SUCCEEDED(hr))hr=SafeArrayGetUBound(array,1,&last);
    if(SUCCEEDED(hr) && (uint32_t)(last+1)>capacity)hr=HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER);
    if(SUCCEEDED(hr))for(LONG i=0;i<=last;++i){hr=SafeArrayGetElement(array,&i,&values[i]);if(FAILED(hr))break;}
    if(SUCCEEDED(hr))*count=(uint32_t)(last+1);
    if(array)SafeArrayDestroy(array);
    if(range)ITextRangeProvider_Release(range);
    if(text)ITextProvider_Release(text);
    return hr;
}
int32_t zda_probe_point(void *pointer, double x, double y, uint32_t *position) {
    ITextProvider *text = NULL; ITextRangeProvider *document = NULL, *range = NULL;
    HRESULT hr = full(pointer, &text, &document);
    if (SUCCEEDED(hr)) hr = ITextProvider_RangeFromPoint(text, ((struct UiaPoint){ x, y }), &range);
    int offset = -1, width = -1;
    if (SUCCEEDED(hr)) hr = ITextRangeProvider_CompareEndpoints(range, TextPatternRangeEndpoint_Start, document, TextPatternRangeEndpoint_Start, &offset);
    if (SUCCEEDED(hr)) hr = ITextRangeProvider_CompareEndpoints(range, TextPatternRangeEndpoint_End, range, TextPatternRangeEndpoint_Start, &width);
    if (SUCCEEDED(hr) && (offset < 0 || width != 0)) hr = E_FAIL;
    if (SUCCEEDED(hr)) *position = (uint32_t)offset;
    if (range) ITextRangeProvider_Release(range);
    if (document) ITextRangeProvider_Release(document);
    if (text) ITextProvider_Release(text);
    return hr;
}
int32_t zda_probe_caret(void *pointer, uint32_t *position, int32_t *active) {
    ITextProvider *text = NULL; ITextProvider2 *extended = NULL;
    ITextRangeProvider *document = NULL, *range = NULL;
    HRESULT hr = full(pointer, &text, &document);
    if (SUCCEEDED(hr)) hr = ITextProvider_QueryInterface(text, &IID_ITextProvider2, (void **)&extended);
    WINBOOL focused = FALSE;
    if (SUCCEEDED(hr)) hr = ITextProvider2_GetCaretRange(extended, &focused, &range);
    int offset = -1;
    if (SUCCEEDED(hr)) hr = ITextRangeProvider_CompareEndpoints(range, TextPatternRangeEndpoint_Start, document, TextPatternRangeEndpoint_Start, &offset);
    if (SUCCEEDED(hr) && offset < 0) hr = E_FAIL;
    if (SUCCEEDED(hr)) { *position = (uint32_t)offset; *active = focused; }
    if (range) ITextRangeProvider_Release(range);
    if (document) ITextRangeProvider_Release(document);
    if (extended) ITextProvider2_Release(extended);
    if (text) ITextProvider_Release(text);
    return hr;
}
int32_t zda_probe_bounds(void *pointer, double *bounds, double x, double y) {
    IRawElementProviderFragment *fragment = NULL, *hit = NULL;
    IRawElementProviderFragmentRoot *root = NULL;
    HRESULT hr = IRawElementProviderSimple_QueryInterface((IRawElementProviderSimple *)pointer, &IID_IRawElementProviderFragment, (void **)&fragment);
    struct UiaRect rectangle;
    if (SUCCEEDED(hr)) hr = IRawElementProviderFragment_get_BoundingRectangle(fragment, &rectangle);
    if (SUCCEEDED(hr)) { bounds[0] = rectangle.left; bounds[1] = rectangle.top; bounds[2] = rectangle.width; bounds[3] = rectangle.height; }
    if (SUCCEEDED(hr)) hr = IRawElementProviderFragment_get_FragmentRoot(fragment, &root);
    if (SUCCEEDED(hr)) hr = IRawElementProviderFragmentRoot_ElementProviderFromPoint(root, x, y, &hit);
    if (SUCCEEDED(hr) && !hit) hr = E_FAIL;
    if (hit) IRawElementProviderFragment_Release(hit);
    if (root) IRawElementProviderFragmentRoot_Release(root);
    if (fragment) IRawElementProviderFragment_Release(fragment);
    return hr;
}
int32_t zda_probe_empty_visible(void *pointer, uint32_t expected) {
    ITextProvider *text = NULL; ITextRangeProvider *document = NULL, *range = NULL;
    HRESULT hr = full(pointer, &text, &document);
    SAFEARRAY *array = NULL; IUnknown *unknown = NULL;
    LONG first = 0, last = -1;
    if (SUCCEEDED(hr)) hr = ITextProvider_GetVisibleRanges(text, &array);
    if (SUCCEEDED(hr)) hr = SafeArrayGetUBound(array, 1, &last);
    if (SUCCEEDED(hr) && last != 0) hr = E_FAIL;
    if (SUCCEEDED(hr)) hr = SafeArrayGetElement(array, &first, &unknown);
    if (SUCCEEDED(hr)) hr = IUnknown_QueryInterface(unknown, &IID_ITextRangeProvider, (void **)&range);
    int offset = -1, width = -1;
    if (SUCCEEDED(hr)) hr = ITextRangeProvider_CompareEndpoints(range, TextPatternRangeEndpoint_Start, document, TextPatternRangeEndpoint_Start, &offset);
    if (SUCCEEDED(hr)) hr = ITextRangeProvider_CompareEndpoints(range, TextPatternRangeEndpoint_End, range, TextPatternRangeEndpoint_Start, &width);
    if (SUCCEEDED(hr) && (offset < 0 || (uint32_t)offset != expected || width != 0)) hr = E_FAIL;
    if (range) ITextRangeProvider_Release(range);
    if (unknown) IUnknown_Release(unknown);
    if (array) SafeArrayDestroy(array);
    if (document) ITextRangeProvider_Release(document);
    if (text) ITextProvider_Release(text);
    return hr;
}
void zda_probe_release(void *pointer) { IRawElementProviderSimple_Release((IRawElementProviderSimple *)pointer); }
int32_t zda_probe_read_mta(void *pointer, uint16_t *output, uint32_t capacity, uint32_t *length) {
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr)) return hr;
    hr = zda_probe_read(pointer, output, capacity, length);
    CoUninitialize(); return hr;
}
