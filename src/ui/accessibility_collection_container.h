#ifndef ZUA_COLLECTION_CONTAINER_H
#define ZUA_COLLECTION_CONTAINER_H
typedef struct CollectionContainer {
    IItemContainerProvider items;
    ISelectionProvider2 selection;
    LONG refs;
    Provider *owner;
    CollectionRegistration registration;
} CollectionContainer;
typedef struct CollectionIdentityPair { uint64_t id, incarnation; } CollectionIdentityPair;
static HRESULT collection_container_new(Provider *, REFIID, void **);

static HRESULT collection_scratch_reserve(State *state, size_t bytes) {
    AcquireSRWLockExclusive(&state->lock);
    CollectionStore *store = state->collections ? state->collections->virtuals : NULL;
    HRESULT hr = !store || state->closed ? UIA_E_ELEMENTNOTAVAILABLE :
        store->request_bytes > store->request_limit || bytes > store->request_limit - store->request_bytes ? HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA) : S_OK;
    if (SUCCEEDED(hr)) { store->request_bytes += bytes; retain(state); }
    ReleaseSRWLockExclusive(&state->lock);
    return hr;
}
static void collection_scratch_refund(State *state, size_t bytes) {
    AcquireSRWLockExclusive(&state->lock);
    state->collections->virtuals->request_bytes -= bytes;
    ReleaseSRWLockExclusive(&state->lock);
    release(state);
}
static HRESULT collection_native_selection(State *state, CollectionRegistration key, SAFEARRAY **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    AcquireSRWLockShared(&state->lock);
    CollectionBinding *binding = collection_native_binding_locked(state, key, NULL);
    if (!binding) { ReleaseSRWLockShared(&state->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    CollectionModel *model = binding->front;
    const uint32_t count = model->selection->front_selected;
    const uint64_t publication = binding->front_publication, revision = model->selection->front_revision;
    const size_t bytes = (size_t)count * sizeof(CollectionIdentityPair);
    CollectionStore *store = state->collections->virtuals;
    if (store->provider_bytes > store->provider_limit || count > (store->provider_limit - store->provider_bytes) / sizeof(CollectionProvider)) {
        ReleaseSRWLockShared(&state->lock); return HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA);
    }
    const enum CollectionStatus status = collection_model_retain(model);
    ReleaseSRWLockShared(&state->lock);
    if (status != COLLECTION_OK) return E_OUTOFMEMORY;
    HRESULT hr = collection_scratch_reserve(state, bytes);
    if (FAILED(hr)) { collection_model_release(model); return hr; }
    CollectionIdentityPair *rows = bytes ? calloc(count, sizeof(*rows)) : NULL;
    if (bytes && !rows) { collection_scratch_refund(state, bytes); collection_model_release(model); return E_OUTOFMEMORY; }
    AcquireSRWLockShared(&state->lock);
    binding = collection_native_binding_locked(state, key, NULL);
    BOOL current = binding && binding->front == model && binding->front_publication == publication && model->selection->front_revision == revision;
    uint32_t written = 0;
    if (current) for (uint32_t word = 0; word < model->selection->word_count; ++word) {
        uint64_t bits = model->selection->front[word];
        while (bits) {
            uint32_t bit = 0;
            while (!(bits & (UINT64_C(1) << bit))) ++bit;
            const uint32_t index = word * 64 + bit;
            if (written == count || index >= model->catalog->count) { current = FALSE; break; }
            const CollectionRow *row = &model->catalog->rows[index];
            rows[written++] = (CollectionIdentityPair){ row->id, row->incarnation };
            bits &= bits - 1;
        }
        if (!current) break;
    }
    ReleaseSRWLockShared(&state->lock);
    collection_model_release(model);
    if (!current || written != count) {
        free(rows); collection_scratch_refund(state, bytes); return UIA_E_ELEMENTNOTAVAILABLE;
    }
    SAFEARRAY *array = SafeArrayCreateVector(VT_UNKNOWN, 0, count);
    if (!array) { free(rows); collection_scratch_refund(state, bytes); return E_OUTOFMEMORY; }
    for (LONG i = 0; i < (LONG)count; ++i) {
        CollectionProvider *provider = NULL;
        hr = collection_provider_new(state, key, rows[i].id, rows[i].incarnation, &provider);
        if (FAILED(hr)) break;
        hr = SafeArrayPutElement(array, &i, &provider->simple);
        collection_provider_release(provider);
        if (FAILED(hr)) break;
    }
    free(rows);
    collection_scratch_refund(state, bytes);
    if (FAILED(hr)) { SafeArrayDestroy(array); return hr; }
    *out = array;
    return S_OK;
}
static ULONG collection_container_add(CollectionContainer *container) { return (ULONG)InterlockedIncrement(&container->refs); }
static ULONG collection_container_release(CollectionContainer *container) {
    const LONG refs = InterlockedDecrement(&container->refs);
    if (!refs) {
        Provider *owner = container->owner;
        State *state = owner->state;
        free(container);
        AcquireSRWLockExclusive(&state->lock);
        state->collections->virtuals->provider_bytes -= sizeof(*container);
        ReleaseSRWLockExclusive(&state->lock);
        provider_release(owner);
    }
    return (ULONG)refs;
}
static HRESULT collection_container_query(CollectionContainer *container, REFIID iid, void **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    if (IsEqualIID(iid, &IID_IItemContainerProvider)) *out = &container->items;
    else if (IsEqualIID(iid, &IID_ISelectionProvider) || IsEqualIID(iid, &IID_ISelectionProvider2)) *out = &container->selection;
    else return provider_query(container->owner, iid, out);
    collection_container_add(container);
    return S_OK;
}
#define COLLECTION_CONTAINER_INTERFACE(prefix, type, member) \
static CollectionContainer *prefix##_self(type *iface) { return (CollectionContainer *)((char *)iface - offsetof(CollectionContainer, member)); } \
static HRESULT STDMETHODCALLTYPE prefix##_query(type *iface, REFIID iid, void **out) { return collection_container_query(prefix##_self(iface), iid, out); } \
static ULONG STDMETHODCALLTYPE prefix##_add(type *iface) { return collection_container_add(prefix##_self(iface)); } \
static ULONG STDMETHODCALLTYPE prefix##_release(type *iface) { return collection_container_release(prefix##_self(iface)); }
COLLECTION_CONTAINER_INTERFACE(collection_items, IItemContainerProvider, items)
COLLECTION_CONTAINER_INTERFACE(collection_selection2, ISelectionProvider2, selection)
#undef COLLECTION_CONTAINER_INTERFACE

static HRESULT STDMETHODCALLTYPE collection_selection2_get(ISelectionProvider2 *iface, SAFEARRAY **out) {
    CollectionContainer *container = collection_selection2_self(iface);
    return collection_native_selection(container->owner->state, container->registration, out);
}
static HRESULT collection_container_probe(CollectionContainer *container) {
    State *state = container->owner->state;
    AcquireSRWLockShared(&state->lock);
    const BOOL available = collection_native_binding_locked(state, container->registration, NULL) != NULL;
    ReleaseSRWLockShared(&state->lock);
    return available ? S_OK : UIA_E_ELEMENTNOTAVAILABLE;
}
static HRESULT STDMETHODCALLTYPE collection_selection2_multiple(ISelectionProvider2 *iface, WINBOOL *out) {
    if (!out) return E_POINTER;
    HRESULT hr = collection_container_probe(collection_selection2_self(iface));
    if (SUCCEEDED(hr)) *out = TRUE;
    return hr;
}
static HRESULT STDMETHODCALLTYPE collection_selection2_required(ISelectionProvider2 *iface, WINBOOL *out) {
    if (!out) return E_POINTER;
    HRESULT hr = collection_container_probe(collection_selection2_self(iface));
    if (SUCCEEDED(hr)) *out = FALSE;
    return hr;
}
static HRESULT collection_selection_edge(CollectionContainer *container, int direction, IRawElementProviderSimple **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    State *state = container->owner->state;
    AcquireSRWLockShared(&state->lock);
    CollectionBinding *binding = collection_native_binding_locked(state, container->registration, NULL);
    if (!binding) { ReleaseSRWLockShared(&state->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    CollectionModel *model = binding->front;
    uint32_t index = UINT32_MAX;
    if (!direction && binding->front_viewport.caret) {
        const CollectionRow *caret = collection_catalog_find(model->catalog, binding->front_viewport.caret, &index);
        if (!caret || caret->incarnation != binding->front_viewport.caret_incarnation ||
            !(model->selection->front[index / 64] & (UINT64_C(1) << (index % 64)))) index = UINT32_MAX;
    }
    if (index == UINT32_MAX) {
        for (uint32_t next = 0; next < model->selection->word_count; ++next) {
            const uint32_t word = direction > 0 ? model->selection->word_count - next - 1 : next;
            const uint64_t bits = model->selection->front[word];
            if (!bits) continue;
            uint32_t bit = direction > 0 ? 63 : 0;
            while (!(bits & (UINT64_C(1) << bit))) { if (direction > 0) --bit; else ++bit; }
            index = word * 64 + bit;
            break;
        }
    }
    CollectionRow row = {0};
    if (index < model->catalog->count) row = model->catalog->rows[index];
    ReleaseSRWLockShared(&state->lock);
    if (!row.id) return S_OK;
    CollectionProvider *provider = NULL;
    HRESULT hr = collection_provider_new(state, container->registration, row.id, row.incarnation, &provider);
    if (SUCCEEDED(hr)) *out = &provider->simple;
    return hr;
}
static HRESULT STDMETHODCALLTYPE collection_selection2_first(ISelectionProvider2 *iface, IRawElementProviderSimple **out) { return collection_selection_edge(collection_selection2_self(iface), -1, out); }
static HRESULT STDMETHODCALLTYPE collection_selection2_last(ISelectionProvider2 *iface, IRawElementProviderSimple **out) { return collection_selection_edge(collection_selection2_self(iface), 1, out); }
static HRESULT STDMETHODCALLTYPE collection_selection2_current(ISelectionProvider2 *iface, IRawElementProviderSimple **out) { return collection_selection_edge(collection_selection2_self(iface), 0, out); }
static HRESULT STDMETHODCALLTYPE collection_selection2_count(ISelectionProvider2 *iface, int *out) {
    if (!out) return E_POINTER;
    CollectionContainer *container = collection_selection2_self(iface);
    State *state = container->owner->state;
    AcquireSRWLockShared(&state->lock);
    CollectionBinding *binding = collection_native_binding_locked(state, container->registration, NULL);
    if (binding) *out = (int)binding->front->selection->front_selected;
    ReleaseSRWLockShared(&state->lock);
    return binding ? S_OK : UIA_E_ELEMENTNOTAVAILABLE;
}
static int collection_hex(WCHAR value) {
    return value >= L'0' && value <= L'9' ? value - L'0' : value >= L'a' && value <= L'f' ? value - L'a' + 10 : value >= L'A' && value <= L'F' ? value - L'A' + 10 : -1;
}
static BOOL collection_automation_identity(BSTR value, CollectionIdentityPair *out) {
    if (!value || SysStringLen(value) != 33 || value[16] != L':') return FALSE;
    CollectionIdentityPair result = {0};
    for (uint32_t i = 0; i < 16; ++i) {
        const int a = collection_hex(value[i]), b = collection_hex(value[17 + i]);
        if (a < 0 || b < 0) return FALSE;
        result.id = (result.id << 4) | (uint32_t)a;
        result.incarnation = (result.incarnation << 4) | (uint32_t)b;
    }
    *out = result;
    return TRUE;
}
static HRESULT STDMETHODCALLTYPE collection_items_find(IItemContainerProvider *iface, IRawElementProviderSimple *after,
    PROPERTYID property, VARIANT value, IRawElementProviderSimple **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    if (property != 0 && property != UIA_NamePropertyId && property != UIA_AutomationIdPropertyId && property != UIA_SelectionItemIsSelectedPropertyId)
        return UIA_E_NOTSUPPORTED;
    if (((property == UIA_NamePropertyId || property == UIA_AutomationIdPropertyId) && value.vt != VT_BSTR) ||
        (property == UIA_SelectionItemIsSelectedPropertyId && value.vt != VT_BOOL)) return E_INVALIDARG;
    CollectionContainer *container = collection_items_self(iface);
    State *state = container->owner->state;
    CollectionProvider *start = NULL;
    if (after) {
        if (after->lpVtbl != &collection_simple_vtable) return E_INVALIDARG;
        start = collection_simple_self(after);
        if (start->state != state || !collection_registration_equal(start->registration, container->registration)) return E_INVALIDARG;
    }
    char needle[4096];
    int needle_length = 0;
    CollectionIdentityPair target = {0};
    if (property == UIA_NamePropertyId && value.bstrVal) {
        const UINT length = SysStringLen(value.bstrVal);
        if (length > 4096) return S_OK;
        if (length) {
            needle_length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.bstrVal, (int)length, needle, sizeof(needle), NULL, NULL);
            if (!needle_length) return GetLastError() == ERROR_INSUFFICIENT_BUFFER ? S_OK : E_INVALIDARG;
        }
    }
    if (property == UIA_AutomationIdPropertyId && !collection_automation_identity(value.bstrVal, &target)) return S_OK;
    AcquireSRWLockShared(&state->lock);
    CollectionBinding *binding = collection_native_binding_locked(state, container->registration, NULL);
    if (!binding) { ReleaseSRWLockShared(&state->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    CollectionModel *model = binding->front;
    uint32_t first = 0;
    if (start) {
        const CollectionRow *row = collection_catalog_find(model->catalog, start->row, &first);
        if (!row || row->incarnation != start->incarnation) { ReleaseSRWLockShared(&state->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
        ++first;
    }
    uint32_t found = model->catalog->count;
    const enum CollectionStatus status = collection_model_retain(model);
    if (status != COLLECTION_OK) { ReleaseSRWLockShared(&state->lock); return E_OUTOFMEMORY; }
    if (!property) found = first;
    else if (property == UIA_SelectionItemIsSelectedPropertyId) {
        /* At most 15,625 word reads, not a scan of one million row records.
           Copy only the resulting immutable identity before unlocking. */
        for (uint32_t word = first / 64; word < model->selection->word_count; ++word) {
            uint64_t bits = value.boolVal != VARIANT_FALSE ? model->selection->front[word] : ~model->selection->front[word];
            if (word == first / 64) bits &= UINT64_MAX << (first % 64);
            if (word + 1 == model->selection->word_count) bits &= collection_last_mask(model->catalog->count);
            if (!bits) continue;
            uint32_t bit = 0;
            while (!(bits & (UINT64_C(1) << bit))) ++bit;
            found = word * 64 + bit;
            break;
        }
    } else if (property == UIA_AutomationIdPropertyId) {
        const CollectionRow *row = collection_catalog_find(model->catalog, target.id, &found);
        if (!row || row->incarnation != target.incarnation || found < first) found = model->catalog->count;
    }
    ReleaseSRWLockShared(&state->lock);
    if (property == UIA_NamePropertyId) {
        /* Full labels are immutable and ledger-pinned; a million-row lookup
           does not hold State's lock or allocate a label per candidate. */
        for (uint32_t index = first; index < model->catalog->count; ++index) {
            const CollectionRow *row = &model->catalog->rows[index];
            if (row->length == (uint32_t)needle_length && !memcmp(model->catalog->text + row->start, needle, (size_t)needle_length)) { found = index; break; }
        }
    }
    CollectionRow row = {0};
    if (found < model->catalog->count) row = model->catalog->rows[found];
    collection_model_release(model);
    if (!row.id) return S_OK;
    CollectionProvider *provider = NULL;
    HRESULT hr = collection_provider_new(state, container->registration, row.id, row.incarnation, &provider);
    if (SUCCEEDED(hr)) *out = &provider->simple;
    return hr;
}
static const IItemContainerProviderVtbl collection_items_vtable = {
    collection_items_query, collection_items_add, collection_items_release, collection_items_find
};
static const ISelectionProvider2Vtbl collection_selection2_vtable = {
    collection_selection2_query, collection_selection2_add, collection_selection2_release,
    collection_selection2_get, collection_selection2_multiple, collection_selection2_required,
    collection_selection2_first, collection_selection2_last, collection_selection2_current, collection_selection2_count
};
static HRESULT collection_container_new(Provider *owner, REFIID iid, void **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    State *state = owner->state;
    if (!(owner->patterns & PATTERN_COLLECTION)) return E_NOINTERFACE;
    const CollectionRegistration key = ((CollectionAnchor *)owner)->registration;
    AcquireSRWLockExclusive(&state->lock);
    /* QI's interface set is immutable. A retired anchor can still return its
       original tearoff, whose actual operations reject the retired key. */
    CollectionStore *store = state->collections ? state->collections->virtuals : NULL;
    if (!store) { ReleaseSRWLockExclusive(&state->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    if (store->provider_bytes > store->provider_limit || sizeof(CollectionContainer) > store->provider_limit - store->provider_bytes) {
        ReleaseSRWLockExclusive(&state->lock); return HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA);
    }
    store->provider_bytes += sizeof(CollectionContainer);
    provider_add(owner);
    ReleaseSRWLockExclusive(&state->lock);
    CollectionContainer *container = calloc(1, sizeof(*container));
    if (!container) {
        AcquireSRWLockExclusive(&state->lock); store->provider_bytes -= sizeof(CollectionContainer); ReleaseSRWLockExclusive(&state->lock);
        provider_release(owner); return E_OUTOFMEMORY;
    }
    container->items.lpVtbl = &collection_items_vtable;
    container->selection.lpVtbl = &collection_selection2_vtable;
    container->refs = 1; container->owner = owner; container->registration = key;
    if (IsEqualIID(iid, &IID_IItemContainerProvider)) *out = &container->items;
    else if (IsEqualIID(iid, &IID_ISelectionProvider) || IsEqualIID(iid, &IID_ISelectionProvider2)) *out = &container->selection;
    else { collection_container_release(container); return E_NOINTERFACE; }
    return S_OK;
}

static HRESULT collection_anchor_new_for(State *state, uint64_t id, const CollectionRegistration *expected, Provider **out) {
    AcquireSRWLockExclusive(&state->lock);
    Node *node = find(state, id);
    RecipientAuthority native = node && state->collections ? state->collections->front[node - state->nodes] : (RecipientAuthority){0};
    const CollectionRegistration key = { native.epoch, native.serial, native.id, native.slot, native.kind };
    if (expected && !collection_registration_equal(key, *expected)) { ReleaseSRWLockExclusive(&state->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    CollectionBinding *binding = collection_native_binding_locked(state, key, NULL);
    if (!binding) { ReleaseSRWLockExclusive(&state->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    CollectionStore *store = state->collections->virtuals;
    if (store->provider_bytes > store->provider_limit || sizeof(CollectionAnchor) > store->provider_limit - store->provider_bytes) {
        ReleaseSRWLockExclusive(&state->lock); return HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA);
    }
    store->provider_bytes += sizeof(CollectionAnchor);
    retain(state);
    ReleaseSRWLockExclusive(&state->lock);
    CollectionAnchor *anchor = calloc(1, sizeof(*anchor));
    HRESULT hr = E_OUTOFMEMORY;
    if (anchor) {
        AcquireSRWLockExclusive(&state->lock);
        binding = collection_native_binding_locked(state, key, NULL);
        if (binding) {
            anchor->registration = key;
            provider_initialize_locked(state, id, ROLE_LIST, &anchor->provider);
            *out = &anchor->provider;
            hr = S_OK;
        } else hr = UIA_E_ELEMENTNOTAVAILABLE;
        ReleaseSRWLockExclusive(&state->lock);
    }
    if (FAILED(hr)) {
        free(anchor);
        AcquireSRWLockExclusive(&state->lock); store->provider_bytes -= sizeof(CollectionAnchor); ReleaseSRWLockExclusive(&state->lock);
    }
    release(state);
    return hr;
}
static HRESULT collection_anchor_new(State *state, uint64_t id, Provider **out) {
    return collection_anchor_new_for(state, id, NULL, out);
}
#endif
