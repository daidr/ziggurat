#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define NO_STRICT
#include <windows.h>
#include <uiautomation.h>
#include <oleauto.h>
#include <stdint.h>
#include <wchar.h>

void zvl_release(void *object) { if (object) IUnknown_Release((IUnknown *)object); }

HRESULT zvl_row_status(void *object, const WCHAR *name, int offscreen) {
    IRawElementProviderSimple *row = object;
    VARIANT value;
    VariantInit(&value);
    HRESULT hr = IRawElementProviderSimple_GetPropertyValue(row, UIA_NamePropertyId, &value);
    if (SUCCEEDED(hr) && (value.vt != VT_BSTR || wcscmp(value.bstrVal, name))) hr = E_FAIL;
    VariantClear(&value);
    if (FAILED(hr)) return hr;
    hr = IRawElementProviderSimple_GetPropertyValue(row, UIA_IsOffscreenPropertyId, &value);
    if (SUCCEEDED(hr) && (value.vt != VT_BOOL || (value.boolVal != VARIANT_FALSE) != !!offscreen)) hr = E_FAIL;
    VariantClear(&value);
    if (FAILED(hr)) return hr;
    IRawElementProviderFragment *fragment = NULL;
    hr = IRawElementProviderSimple_QueryInterface(row, &IID_IRawElementProviderFragment, (void **)&fragment);
    if (FAILED(hr)) return hr;
    struct UiaRect bounds;
    hr = IRawElementProviderFragment_get_BoundingRectangle(fragment, &bounds);
    if (SUCCEEDED(hr) && (offscreen ? bounds.width != 0 || bounds.height != 0 : bounds.width <= 0 || bounds.height <= 0)) hr = E_FAIL;
    SAFEARRAY *runtime = NULL;
    if (SUCCEEDED(hr)) hr = IRawElementProviderFragment_GetRuntimeId(fragment, &runtime);
    if (SUCCEEDED(hr)) {
        LONG lower, upper;
        hr = SafeArrayGetLBound(runtime, 1, &lower);
        if (SUCCEEDED(hr)) hr = SafeArrayGetUBound(runtime, 1, &upper);
        if (SUCCEEDED(hr) && (lower != 0 || upper != 10)) hr = E_FAIL;
    }
    if (runtime) SafeArrayDestroy(runtime);
    IRawElementProviderFragment_Release(fragment);
    return hr;
}

HRESULT zvl_catalog_probe(void *object, uint32_t count, void **last) {
    *last = NULL;
    IRawElementProviderSimple *anchor = object;
    IItemContainerProvider *items = NULL;
    IRawElementProviderFragment *fragment = NULL, *current = NULL;
    IRawElementProviderSimple *found = NULL;
    HRESULT hr = IRawElementProviderSimple_QueryInterface(anchor, &IID_IItemContainerProvider, (void **)&items);
    if (FAILED(hr)) goto done;
    VARIANT query;
    VariantInit(&query);
    query.vt = VT_BSTR;
    query.bstrVal = SysAllocString(L"row 257");
    if (!query.bstrVal) { hr = E_OUTOFMEMORY; goto done; }
    hr = IItemContainerProvider_FindItemByProperty(items, NULL, UIA_NamePropertyId, query, &found);
    VariantClear(&query);
    if (FAILED(hr) || !found) { if (SUCCEEDED(hr)) hr = E_FAIL; goto done; }
    hr = zvl_row_status(found, L"row 257", 1);
    if (FAILED(hr)) goto done;
    hr = IRawElementProviderSimple_QueryInterface(anchor, &IID_IRawElementProviderFragment, (void **)&fragment);
    if (FAILED(hr)) goto done;
    hr = IRawElementProviderFragment_Navigate(fragment, NavigateDirection_FirstChild, &current);
    uint32_t visited = 0;
    while (SUCCEEDED(hr) && current) {
        IRawElementProviderFragment *next = NULL;
        ++visited;
        hr = IRawElementProviderFragment_Navigate(current, NavigateDirection_NextSibling, &next);
        IRawElementProviderFragment_Release(current);
        current = next;
    }
    if (SUCCEEDED(hr) && visited != count) hr = E_FAIL;
    if (SUCCEEDED(hr)) { *last = found; found = NULL; }
done:
    if (found) IRawElementProviderSimple_Release(found);
    if (current) IRawElementProviderFragment_Release(current);
    if (fragment) IRawElementProviderFragment_Release(fragment);
    if (items) IItemContainerProvider_Release(items);
    return hr;
}

HRESULT zvl_selection_probe(void *object, int expected) {
    ISelectionProvider2 *selection = NULL;
    HRESULT hr = IUnknown_QueryInterface((IUnknown *)object, &IID_ISelectionProvider2, (void **)&selection);
    if (FAILED(hr)) return hr;
    int count = -1;
    BOOL multiple = FALSE, required = TRUE;
    hr = ISelectionProvider2_get_ItemCount(selection, &count);
    if (SUCCEEDED(hr) && count != expected) hr = E_FAIL;
    if (SUCCEEDED(hr)) hr = ISelectionProvider2_get_CanSelectMultiple(selection, &multiple);
    if (SUCCEEDED(hr)) hr = ISelectionProvider2_get_IsSelectionRequired(selection, &required);
    if (SUCCEEDED(hr) && (!multiple || required)) hr = E_FAIL;
    SAFEARRAY *selected = NULL;
    if (SUCCEEDED(hr)) hr = ISelectionProvider2_GetSelection(selection, &selected);
    if (SUCCEEDED(hr)) {
        LONG lower, upper;
        hr = SafeArrayGetLBound(selected, 1, &lower);
        if (SUCCEEDED(hr)) hr = SafeArrayGetUBound(selected, 1, &upper);
        if (SUCCEEDED(hr) && upper - lower + 1 != expected) hr = E_FAIL;
    }
    if (selected) SafeArrayDestroy(selected);
    ISelectionProvider2_Release(selection);
    return hr;
}

HRESULT zvl_row_request(void *object, int action) {
    IRawElementProviderSimple *row = object;
    if (action == 0) {
        ISelectionItemProvider *selection = NULL;
        HRESULT hr = IRawElementProviderSimple_QueryInterface(row, &IID_ISelectionItemProvider, (void **)&selection);
        if (FAILED(hr)) return hr;
        hr = ISelectionItemProvider_Select(selection);
        ISelectionItemProvider_Release(selection);
        return hr;
    }
    if (action == 1) {
        IScrollItemProvider *scroll = NULL;
        HRESULT hr = IRawElementProviderSimple_QueryInterface(row, &IID_IScrollItemProvider, (void **)&scroll);
        if (FAILED(hr)) return hr;
        hr = IScrollItemProvider_ScrollIntoView(scroll);
        IScrollItemProvider_Release(scroll);
        return hr;
    }
    IRawElementProviderFragment *fragment = NULL;
    HRESULT hr = IRawElementProviderSimple_QueryInterface(row, &IID_IRawElementProviderFragment, (void **)&fragment);
    if (FAILED(hr)) return hr;
    hr = IRawElementProviderFragment_SetFocus(fragment);
    IRawElementProviderFragment_Release(fragment);
    return hr;
}

HRESULT zvl_stale(void *object) {
    VARIANT value;
    VariantInit(&value);
    HRESULT hr = IRawElementProviderSimple_GetPropertyValue((IRawElementProviderSimple *)object, UIA_NamePropertyId, &value);
    VariantClear(&value);
    return hr;
}

HRESULT zvl_late_identity(void *object) {
    IRawElementProviderSimple *simple = object;
    IRawElementProviderFragment *fragment = NULL;
    IRawElementProviderFragmentRoot *root = NULL;
    SAFEARRAY *runtime = NULL;
    enum ProviderOptions options = 0;
    HRESULT hr = IRawElementProviderSimple_get_ProviderOptions(simple, &options);
    if (SUCCEEDED(hr) && !(options & ProviderOptions_ServerSideProvider)) hr = E_FAIL;
    if (SUCCEEDED(hr)) hr = IRawElementProviderSimple_QueryInterface(simple, &IID_IRawElementProviderFragment, (void **)&fragment);
    if (SUCCEEDED(hr)) hr = IRawElementProviderFragment_GetRuntimeId(fragment, &runtime);
    if (SUCCEEDED(hr)) hr = IRawElementProviderFragment_get_FragmentRoot(fragment, &root);
    if (SUCCEEDED(hr) && (!root || !runtime)) hr = E_FAIL;
    if (root) IRawElementProviderFragmentRoot_Release(root);
    if (runtime) SafeArrayDestroy(runtime);
    if (fragment) IRawElementProviderFragment_Release(fragment);
    return hr;
}
