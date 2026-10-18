#ifndef ZUA_COLLECTION_PROVIDER_H
#define ZUA_COLLECTION_PROVIDER_H
/* Included by accessibility.c after its ordinary Provider helpers. Virtual
   rows own one State ref and lightweight immutable identity only. They never
   own labels, a Zig context, a selection bitmap or a separate focus table. */
typedef struct CollectionProvider {
    IRawElementProviderSimple simple;
    IRawElementProviderFragment fragment;
    ISelectionItemProvider selection;
    IScrollItemProvider scroll;
    IVirtualizedItemProvider virtualized;
    LONG refs;
    State *state;
    CollectionRegistration registration;
    uint64_t row, incarnation;
    struct CollectionProvider *previous, *next;
    BOOL listed;
} CollectionProvider;

enum CollectionActionKind { COLLECTION_SELECT = 1, COLLECTION_ADD, COLLECTION_REMOVE, COLLECTION_FOCUS, COLLECTION_REVEAL };
static HRESULT collection_request(State *, CollectionRegistration, uint64_t, uint64_t, uint32_t);
static HRESULT collection_provider_new(State *, CollectionRegistration, uint64_t, uint64_t, CollectionProvider **);
static LONG live_collection_providers;

static CollectionBinding *collection_native_binding_locked(State *state, CollectionRegistration key, Node **node) {
    if (!state->collections || !state->collections->virtuals) return NULL;
    Node *anchor = find(state, key.id);
    if (!anchor || anchor->role != ROLE_LIST) return NULL;
    const RecipientAuthority *native = &state->collections->front[anchor - state->nodes];
    if (native->epoch != key.epoch || native->serial != key.serial || native->id != key.id ||
        native->slot != key.slot || native->kind != key.kind) return NULL;
    CollectionBinding *binding = collection_store_find(state->collections->virtuals, key);
    if (!binding || !binding->front || !binding->front_publication || binding->front_publication != native->publication) return NULL;
    if (node) *node = anchor;
    return binding;
}
static HRESULT collection_provider_read(CollectionProvider *provider, CollectionReadSnapshot *read,
    CollectionMapping *mapping, uint32_t *flags, double *origin_x, double *origin_y, double *scale) {
    State *state = provider->state;
    AcquireSRWLockShared(&state->lock);
    Node *node = NULL;
    CollectionBinding *binding = collection_native_binding_locked(state, provider->registration, &node);
    enum CollectionStatus status = binding ? collection_binding_read(binding, provider->row, provider->incarnation, read, mapping) : COLLECTION_STALE;
    if (status == COLLECTION_OK) {
        if (flags) *flags = node->flags;
        if (mapping) {
            if (!state->geometry_active || !state->geometry) {
                collection_read_release(read);
                status = COLLECTION_STALE;
            } else {
                *origin_x = state->geometry->origin_x;
                *origin_y = state->geometry->origin_y;
                *scale = state->geometry->scale;
            }
        }
    }
    ReleaseSRWLockShared(&state->lock);
    return status == COLLECTION_OK ? S_OK : status == COLLECTION_EXHAUSTED ? E_OUTOFMEMORY : UIA_E_ELEMENTNOTAVAILABLE;
}
static ULONG collection_provider_add(CollectionProvider *provider) { return (ULONG)InterlockedIncrement(&provider->refs); }
static void collection_provider_unlink(State *state, CollectionProvider *provider) {
    if (!provider->listed) return;
    CollectionStore *store = state->collections->virtuals;
    if (provider->previous) provider->previous->next = provider->next;
    else store->provider_head = provider->next;
    if (provider->next) provider->next->previous = provider->previous;
    provider->previous = provider->next = NULL;
    provider->listed = FALSE;
}
static ULONG collection_provider_release(CollectionProvider *provider) {
    State *state = provider->state;
    AcquireSRWLockExclusive(&state->lock);
    const LONG refs = InterlockedDecrement(&provider->refs);
    if (!refs) collection_provider_unlink(state, provider);
    ReleaseSRWLockExclusive(&state->lock);
    if (!refs) {
        free(provider);
        AcquireSRWLockExclusive(&state->lock);
        state->collections->virtuals->provider_bytes -= sizeof(*provider);
        ReleaseSRWLockExclusive(&state->lock);
        InterlockedDecrement(&live_collection_providers);
        release(state);
    }
    return (ULONG)refs;
}
static HRESULT collection_provider_query(CollectionProvider *provider, REFIID iid, void **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    if (IsEqualIID(iid, &IID_IUnknown) || IsEqualIID(iid, &IID_IRawElementProviderSimple)) *out = &provider->simple;
    else if (IsEqualIID(iid, &IID_IRawElementProviderFragment)) *out = &provider->fragment;
    else if (IsEqualIID(iid, &IID_ISelectionItemProvider)) *out = &provider->selection;
    else if (IsEqualIID(iid, &IID_IScrollItemProvider)) *out = &provider->scroll;
    else if (IsEqualIID(iid, &IID_IVirtualizedItemProvider)) *out = &provider->virtualized;
    else return E_NOINTERFACE;
    collection_provider_add(provider);
    return S_OK;
}
#define COLLECTION_INTERFACE(prefix, type, member) \
static CollectionProvider *prefix##_self(type *iface) { return (CollectionProvider *)((char *)iface - offsetof(CollectionProvider, member)); } \
static HRESULT STDMETHODCALLTYPE prefix##_query(type *iface, REFIID iid, void **out) { return collection_provider_query(prefix##_self(iface), iid, out); } \
static ULONG STDMETHODCALLTYPE prefix##_add(type *iface) { return collection_provider_add(prefix##_self(iface)); } \
static ULONG STDMETHODCALLTYPE prefix##_release(type *iface) { return collection_provider_release(prefix##_self(iface)); }
COLLECTION_INTERFACE(collection_simple, IRawElementProviderSimple, simple)
COLLECTION_INTERFACE(collection_fragment, IRawElementProviderFragment, fragment)
COLLECTION_INTERFACE(collection_item, ISelectionItemProvider, selection)
COLLECTION_INTERFACE(collection_scroll, IScrollItemProvider, scroll)
COLLECTION_INTERFACE(collection_virtualized, IVirtualizedItemProvider, virtualized)
#undef COLLECTION_INTERFACE

static HRESULT STDMETHODCALLTYPE collection_simple_options(IRawElementProviderSimple *iface, enum ProviderOptions *out) {
    (void)iface;
    if (!out) return E_POINTER;
    *out = ProviderOptions_ServerSideProvider | ProviderOptions_UseComThreading;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE collection_simple_pattern(IRawElementProviderSimple *iface, PATTERNID id, IUnknown **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    CollectionProvider *provider = collection_simple_self(iface);
    CollectionReadSnapshot read;
    HRESULT hr = collection_provider_read(provider, &read, NULL, NULL, NULL, NULL, NULL);
    if (FAILED(hr)) return hr;
    collection_read_release(&read);
    if (id == UIA_SelectionItemPatternId) *out = (IUnknown *)&provider->selection;
    else if (id == UIA_ScrollItemPatternId) *out = (IUnknown *)&provider->scroll;
    else if (id == UIA_VirtualizedItemPatternId) *out = (IUnknown *)&provider->virtualized;
    if (*out) collection_provider_add(provider);
    return S_OK;
}
static HRESULT collection_provider_bounds(CollectionProvider *provider, struct UiaRect *out, BOOL *visible) {
    CollectionReadSnapshot read;
    CollectionMapping mapping;
    uint32_t flags;
    double origin_x, origin_y, scale;
    HRESULT hr = collection_provider_read(provider, &read, &mapping, &flags, &origin_x, &origin_y, &scale);
    if (FAILED(hr)) return hr;
    /* All mutable data was copied while locked; only pure math runs here. */
    const double top = read.viewport.y + (double)read.top_ticks / 64 - read.viewport.scroll;
    const double height = (double)read.row.height / 64;
    collection_read_release(&read);
    CollectionBounds bounds;
    if (zua_collection_row_bounds(&mapping, top, height, origin_x, origin_y, scale, &bounds)) return E_FAIL;
    *visible = bounds.visible && !(flags & OFFSCREEN);
    *out = *visible ? (struct UiaRect){ bounds.rect.x, bounds.rect.y, bounds.rect.width, bounds.rect.height } : (struct UiaRect){0};
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE collection_simple_property(IRawElementProviderSimple *iface, PROPERTYID id, VARIANT *out) {
    if (!out) return E_POINTER;
    VariantInit(out);
    CollectionProvider *provider = collection_simple_self(iface);
    if (id == UIA_IsOffscreenPropertyId) {
        struct UiaRect ignored;
        BOOL visible;
        HRESULT hr = collection_provider_bounds(provider, &ignored, &visible);
        if (FAILED(hr)) return hr;
        out->vt = VT_BOOL; out->boolVal = visible ? VARIANT_FALSE : VARIANT_TRUE;
        return S_OK;
    }
    CollectionReadSnapshot read;
    uint32_t flags;
    HRESULT hr = collection_provider_read(provider, &read, NULL, &flags, NULL, NULL, NULL);
    if (FAILED(hr)) return hr;
    const BOOL enabled = (flags & ENABLED) && read.row.enabled;
    switch (id) {
        case UIA_NamePropertyId: {
            const char *text = read.model->catalog->text + read.row.start;
            const int length = read.row.length ? MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, (int)read.row.length, NULL, 0) : 0;
            if (read.row.length && !length) { hr = E_FAIL; break; }
            BSTR name = SysAllocStringLen(NULL, (UINT)length);
            if (!name) { hr = E_OUTOFMEMORY; break; }
            if (length) MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, (int)read.row.length, name, length);
            out->vt = VT_BSTR; out->bstrVal = name;
            break;
        }
        case UIA_AutomationIdPropertyId: {
            WCHAR text[34];
            _snwprintf(text, 34, L"%016llx:%016llx", (unsigned long long)provider->row, (unsigned long long)provider->incarnation);
            out->vt = VT_BSTR; out->bstrVal = SysAllocStringLen(text, 33);
            if (!out->bstrVal) hr = E_OUTOFMEMORY;
            break;
        }
        case UIA_ControlTypePropertyId: out->vt = VT_I4; out->lVal = UIA_ListItemControlTypeId; break;
        case UIA_IsEnabledPropertyId: out->vt = VT_BOOL; out->boolVal = enabled ? VARIANT_TRUE : VARIANT_FALSE; break;
        case UIA_HasKeyboardFocusPropertyId: out->vt = VT_BOOL; out->boolVal = (flags & FOCUSED) && read.caret ? VARIANT_TRUE : VARIANT_FALSE; break;
        case UIA_IsKeyboardFocusablePropertyId: out->vt = VT_BOOL; out->boolVal = enabled ? VARIANT_TRUE : VARIANT_FALSE; break;
        case UIA_IsControlElementPropertyId: case UIA_IsContentElementPropertyId:
        case UIA_IsSelectionItemPatternAvailablePropertyId: case UIA_IsScrollItemPatternAvailablePropertyId:
        case UIA_IsVirtualizedItemPatternAvailablePropertyId: out->vt = VT_BOOL; out->boolVal = VARIANT_TRUE; break;
        case UIA_SelectionItemIsSelectedPropertyId: out->vt = VT_BOOL; out->boolVal = read.selected ? VARIANT_TRUE : VARIANT_FALSE; break;
        default: break;
    }
    collection_read_release(&read);
    return hr;
}
static HRESULT STDMETHODCALLTYPE collection_simple_host(IRawElementProviderSimple *iface, IRawElementProviderSimple **out) {
    (void)iface;
    if (!out) return E_POINTER;
    *out = NULL;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE collection_fragment_navigate(IRawElementProviderFragment *iface,
    enum NavigateDirection direction, IRawElementProviderFragment **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    CollectionProvider *provider = collection_fragment_self(iface);
    CollectionReadSnapshot read;
    HRESULT hr = collection_provider_read(provider, &read, NULL, NULL, NULL, NULL, NULL);
    if (FAILED(hr)) return hr;
    if (direction == NavigateDirection_Parent) {
        collection_read_release(&read);
        Provider *parent = NULL;
        hr = collection_anchor_new_for(provider->state, provider->registration.id, &provider->registration, &parent);
        if (SUCCEEDED(hr)) *out = &parent->fragment;
        return hr;
    }
    if (direction != NavigateDirection_NextSibling && direction != NavigateDirection_PreviousSibling) {
        collection_read_release(&read);
        return S_OK;
    }
    uint32_t index;
    collection_catalog_find(read.model->catalog, provider->row, &index);
    const BOOL found = direction == NavigateDirection_NextSibling ? index + 1 < read.model->catalog->count : index != 0;
    CollectionRow row = {0};
    if (found) row = read.model->catalog->rows[direction == NavigateDirection_NextSibling ? index + 1 : index - 1];
    collection_read_release(&read);
    if (!found) return S_OK;
    CollectionProvider *next = NULL;
    hr = collection_provider_new(provider->state, provider->registration, row.id, row.incarnation, &next);
    if (SUCCEEDED(hr)) *out = &next->fragment;
    return hr;
}
static HRESULT STDMETHODCALLTYPE collection_fragment_runtime(IRawElementProviderFragment *iface, SAFEARRAY **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    CollectionProvider *provider = collection_fragment_self(iface);
    SAFEARRAY *array = SafeArrayCreateVector(VT_I4, 0, 11);
    if (!array) return E_OUTOFMEMORY;
    LONG values[11] = { UiaAppendRuntimeId };
    const uint64_t keys[] = { provider->registration.epoch, provider->registration.serial, provider->registration.id, provider->row, provider->incarnation };
    for (uint32_t i = 0; i < 5; ++i) {
        values[1 + 2 * i] = (LONG)(uint32_t)keys[i];
        values[2 + 2 * i] = (LONG)(uint32_t)(keys[i] >> 32);
    }
    for (LONG i = 0; i < 11; ++i) {
        HRESULT hr = SafeArrayPutElement(array, &i, &values[i]);
        if (FAILED(hr)) { SafeArrayDestroy(array); return hr; }
    }
    *out = array;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE collection_fragment_bounds(IRawElementProviderFragment *iface, struct UiaRect *out) {
    if (!out) return E_POINTER;
    BOOL visible;
    return collection_provider_bounds(collection_fragment_self(iface), out, &visible);
}
static HRESULT STDMETHODCALLTYPE collection_fragment_embedded(IRawElementProviderFragment *iface, SAFEARRAY **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    CollectionReadSnapshot read;
    const HRESULT hr = collection_provider_read(collection_fragment_self(iface), &read, NULL, NULL, NULL, NULL, NULL);
    if (SUCCEEDED(hr)) collection_read_release(&read);
    return hr;
}
static HRESULT STDMETHODCALLTYPE collection_fragment_focus(IRawElementProviderFragment *iface) {
    CollectionProvider *provider = collection_fragment_self(iface);
    return collection_request(provider->state, provider->registration, provider->row, provider->incarnation, COLLECTION_FOCUS);
}
static HRESULT STDMETHODCALLTYPE collection_fragment_root(IRawElementProviderFragment *iface, IRawElementProviderFragmentRoot **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    CollectionProvider *provider = collection_fragment_self(iface);
    State *state = provider->state;
    AcquireSRWLockShared(&state->lock);
    /* Disconnect still queries COM identity after semantic bindings retire. */
    if (state->root) { provider_add(state->root); *out = &state->root->root; }
    ReleaseSRWLockShared(&state->lock);
    return *out ? S_OK : UIA_E_ELEMENTNOTAVAILABLE;
}
static HRESULT STDMETHODCALLTYPE collection_selection_select(ISelectionItemProvider *iface) {
    CollectionProvider *provider = collection_item_self(iface);
    return collection_request(provider->state, provider->registration, provider->row, provider->incarnation, COLLECTION_SELECT);
}
static HRESULT STDMETHODCALLTYPE collection_item_add_item(ISelectionItemProvider *iface) {
    CollectionProvider *provider = collection_item_self(iface);
    return collection_request(provider->state, provider->registration, provider->row, provider->incarnation, COLLECTION_ADD);
}
static HRESULT STDMETHODCALLTYPE collection_selection_remove_item(ISelectionItemProvider *iface) {
    CollectionProvider *provider = collection_item_self(iface);
    return collection_request(provider->state, provider->registration, provider->row, provider->incarnation, COLLECTION_REMOVE);
}
static HRESULT STDMETHODCALLTYPE collection_selection_selected(ISelectionItemProvider *iface, WINBOOL *out) {
    if (!out) return E_POINTER;
    CollectionReadSnapshot read;
    HRESULT hr = collection_provider_read(collection_item_self(iface), &read, NULL, NULL, NULL, NULL, NULL);
    if (FAILED(hr)) return hr;
    *out = read.selected != 0;
    collection_read_release(&read);
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE collection_selection_container(ISelectionItemProvider *iface, IRawElementProviderSimple **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    CollectionProvider *provider = collection_item_self(iface);
    CollectionReadSnapshot read;
    HRESULT hr = collection_provider_read(provider, &read, NULL, NULL, NULL, NULL, NULL);
    if (FAILED(hr)) return hr;
    collection_read_release(&read);
    Provider *container = NULL;
    hr = collection_anchor_new_for(provider->state, provider->registration.id, &provider->registration, &container);
    if (SUCCEEDED(hr)) *out = &container->simple;
    return hr;
}
static HRESULT STDMETHODCALLTYPE collection_scroll_reveal(IScrollItemProvider *iface) {
    CollectionProvider *provider = collection_scroll_self(iface);
    return collection_request(provider->state, provider->registration, provider->row, provider->incarnation, COLLECTION_REVEAL);
}
static HRESULT STDMETHODCALLTYPE collection_virtualized_realize(IVirtualizedItemProvider *iface) {
    CollectionReadSnapshot read;
    HRESULT hr = collection_provider_read(collection_virtualized_self(iface), &read, NULL, NULL, NULL, NULL, NULL);
    if (SUCCEEDED(hr)) collection_read_release(&read);
    /* Catalog providers already expose their complete properties and patterns.
       Realize is idempotent; ScrollItem is the separate request to reveal. */
    return hr;
}
static const IRawElementProviderSimpleVtbl collection_simple_vtable = {
    collection_simple_query, collection_simple_add, collection_simple_release, collection_simple_options,
    collection_simple_pattern, collection_simple_property, collection_simple_host
};
static const IRawElementProviderFragmentVtbl collection_fragment_vtable = {
    collection_fragment_query, collection_fragment_add, collection_fragment_release, collection_fragment_navigate,
    collection_fragment_runtime, collection_fragment_bounds, collection_fragment_embedded, collection_fragment_focus, collection_fragment_root
};
static const ISelectionItemProviderVtbl collection_selection_vtable = {
    collection_item_query, collection_item_add, collection_item_release,
    collection_selection_select, collection_item_add_item, collection_selection_remove_item,
    collection_selection_selected, collection_selection_container
};
static const IScrollItemProviderVtbl collection_scroll_vtable = {
    collection_scroll_query, collection_scroll_add, collection_scroll_release, collection_scroll_reveal
};
static const IVirtualizedItemProviderVtbl collection_virtualized_vtable = {
    collection_virtualized_query, collection_virtualized_add, collection_virtualized_release, collection_virtualized_realize
};
static HRESULT collection_provider_new(State *state, CollectionRegistration key,
    uint64_t id, uint64_t incarnation, CollectionProvider **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    AcquireSRWLockExclusive(&state->lock);
    CollectionBinding *binding = collection_native_binding_locked(state, key, NULL);
    uint32_t index;
    const CollectionRow *row = binding ? collection_catalog_find(binding->front->catalog, id, &index) : NULL;
    if (!row || row->incarnation != incarnation) { ReleaseSRWLockExclusive(&state->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    CollectionStore *store = state->collections->virtuals;
    if (store->provider_bytes > store->provider_limit || sizeof(CollectionProvider) > store->provider_limit - store->provider_bytes) {
        ReleaseSRWLockExclusive(&state->lock); return HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA);
    }
    store->provider_bytes += sizeof(CollectionProvider);
    retain(state);
    ReleaseSRWLockExclusive(&state->lock);
    CollectionProvider *provider = calloc(1, sizeof(*provider));
    HRESULT failure = E_OUTOFMEMORY;
    if (provider) {
        provider->simple.lpVtbl = &collection_simple_vtable;
        provider->fragment.lpVtbl = &collection_fragment_vtable;
        provider->selection.lpVtbl = &collection_selection_vtable;
        provider->scroll.lpVtbl = &collection_scroll_vtable;
        provider->virtualized.lpVtbl = &collection_virtualized_vtable;
        provider->refs = 1; provider->state = state; provider->registration = key;
        provider->row = id; provider->incarnation = incarnation;
        CollectionReadSnapshot read;
        HRESULT hr = collection_provider_read(provider, &read, NULL, NULL, NULL, NULL, NULL);
        if (SUCCEEDED(hr)) {
            collection_read_release(&read);
            AcquireSRWLockExclusive(&state->lock);
            binding = collection_native_binding_locked(state, key, NULL);
            row = binding ? collection_catalog_find(binding->front->catalog, id, &index) : NULL;
            if (row && row->incarnation == incarnation) {
                provider->listed = TRUE;
                provider->next = store->provider_head;
                if (provider->next) provider->next->previous = provider;
                store->provider_head = provider;
                InterlockedIncrement(&live_collection_providers);
                *out = provider;
                ReleaseSRWLockExclusive(&state->lock);
                return S_OK;
            }
            ReleaseSRWLockExclusive(&state->lock);
            hr = UIA_E_ELEMENTNOTAVAILABLE;
        }
        failure = hr;
        free(provider);
    }
    AcquireSRWLockExclusive(&state->lock);
    store->provider_bytes -= sizeof(CollectionProvider);
    ReleaseSRWLockExclusive(&state->lock);
    release(state);
    return failure;
}
#endif
