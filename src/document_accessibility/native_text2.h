#ifndef ZIGGURAT_DOCUMENT_ACCESSIBILITY_TEXT2_H
#define ZIGGURAT_DOCUMENT_ACCESSIBILITY_TEXT2_H
/* Included after the base Text provider. Every inherited slot has its true
   ITextProvider2 signature; the two interface pointers share only IUnknown. */
static HRESULT STDMETHODCALLTYPE text2_selection(ITextProvider2 *iface, SAFEARRAY **out) {
    return text_selection(&text2_self(iface)->text, out);
}
static HRESULT STDMETHODCALLTYPE text2_visible(ITextProvider2 *iface, SAFEARRAY **out) {
    return text_visible(&text2_self(iface)->text, out);
}
static HRESULT STDMETHODCALLTYPE text2_child(ITextProvider2 *iface, IRawElementProviderSimple *child, ITextRangeProvider **out) {
    return text_child(&text2_self(iface)->text, child, out);
}
static HRESULT STDMETHODCALLTYPE text2_point(ITextProvider2 *iface, struct UiaPoint point, ITextRangeProvider **out) {
    return text_point(&text2_self(iface)->text, point, out);
}
static HRESULT STDMETHODCALLTYPE text2_document(ITextProvider2 *iface, ITextRangeProvider **out) {
    return text_document(&text2_self(iface)->text, out);
}
static HRESULT STDMETHODCALLTYPE text2_supported(ITextProvider2 *iface, enum SupportedTextSelection *out) {
    return text_supported(&text2_self(iface)->text, out);
}
static HRESULT STDMETHODCALLTYPE text2_annotation(ITextProvider2 *iface, IRawElementProviderSimple *annotation, ITextRangeProvider **out) {
    (void)annotation;
    if (!out) return E_POINTER;
    *out = NULL;
    HRESULT hr = alive(text2_self(iface));
    return FAILED(hr) ? hr : UIA_E_NOTSUPPORTED;
}
static HRESULT STDMETHODCALLTYPE text2_caret(ITextProvider2 *iface, WINBOOL *active, ITextRangeProvider **out) {
    if (!active || !out) return E_POINTER;
    *active = FALSE; *out = NULL;
    ZdaProvider *provider = text2_self(iface);
    ZdaText *text = NULL; ZdaCurrent current;
    HRESULT hr = zda_acquire(provider->state, provider->source, UINT64_MAX, &text, NULL, &current);
    if (FAILED(hr)) return hr;
    if (current.composing) { zda_text_release(text); return UIA_E_NOTSUPPORTED; }
    const uint32_t caret = current.selections[current.primary].caret;
    ZdaRange *range = NULL;
    hr = create_range(provider->state, provider->source, text->version, caret, caret, &range);
    if (SUCCEEDED(hr)) { *active = current.focused ? TRUE : FALSE; *out = &range->iface; }
    zda_text_release(text); return hr;
}
static const ITextProvider2Vtbl text2_vtable = {
    text2_query, text2_add, text2_release, text2_selection, text2_visible,
    text2_child, text2_point, text2_document, text2_supported,
    text2_annotation, text2_caret
};
#endif
