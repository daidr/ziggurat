#ifndef ZUA_COLLECTION_ROOT_H
#define ZUA_COLLECTION_ROOT_H
static HRESULT collection_identity_fragment(State *state, CollectionRegistration key,
    uint64_t row, uint64_t incarnation, IRawElementProviderFragment **out) {
    CollectionProvider *provider = NULL;
    HRESULT hr = collection_provider_new(state, key, row, incarnation, &provider);
    if (SUCCEEDED(hr)) *out = &provider->fragment;
    return hr;
}
static HRESULT collection_child_fragment(State *state, CollectionRegistration key,
    enum NavigateDirection direction, IRawElementProviderFragment **out) {
    AcquireSRWLockShared(&state->lock);
    CollectionBinding *binding = collection_native_binding_locked(state, key, NULL);
    if (!binding) { ReleaseSRWLockShared(&state->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    const CollectionCatalog *catalog = binding->front->catalog;
    CollectionRow row = {0};
    if (catalog->count) row = catalog->rows[direction == NavigateDirection_LastChild ? catalog->count - 1 : 0];
    ReleaseSRWLockShared(&state->lock);
    return row.id ? collection_identity_fragment(state, key, row.id, row.incarnation, out) : S_OK;
}
static HRESULT collection_focus_fragment(State *state, CollectionRegistration key, IRawElementProviderFragment **out) {
    AcquireSRWLockShared(&state->lock);
    Node *node = NULL;
    CollectionBinding *binding = collection_native_binding_locked(state, key, &node);
    CollectionRow row = {0};
    if (binding && (node->flags & FOCUSED) && binding->front_viewport.caret) {
        uint32_t index;
        const CollectionRow *candidate = collection_catalog_find(binding->front->catalog, binding->front_viewport.caret, &index);
        if (candidate && candidate->incarnation == binding->front_viewport.caret_incarnation) row = *candidate;
    }
    ReleaseSRWLockShared(&state->lock);
    return row.id ? collection_identity_fragment(state, key, row.id, row.incarnation, out) : S_OK;
}
static HRESULT collection_point_fragment(State *state, CollectionRegistration key,
    double x, double y, IRawElementProviderFragment **out) {
    AcquireSRWLockShared(&state->lock);
    Node *node = NULL;
    CollectionBinding *binding = collection_native_binding_locked(state, key, &node);
    if (!binding || !state->geometry_active || !state->geometry) {
        ReleaseSRWLockShared(&state->lock); return UIA_E_ELEMENTNOTAVAILABLE;
    }
    const Geometry *geometry = state->geometry;
    const double wx = (x - geometry->origin_x) / geometry->scale, wy = (y - geometry->origin_y) / geometry->scale;
    const GeometryRef *reference = &geometry->nodes[node - state->nodes];
    const GeometrySpace *space = &geometry->spaces[reference->space];
    const double local_x = space->xx * wx + space->xy * wy + space->x0;
    const double local_y = space->yx * wx + space->yy * wy + space->y0;
    const CollectionViewport viewport = binding->front_viewport;
    BOOL inside = local_x >= viewport.x && local_y >= viewport.y &&
        local_x < viewport.x + viewport.width && local_y < viewport.y + viewport.height;
    uint32_t clip = reference->clip;
    while (inside && clip != UINT32_MAX) {
        reference = &geometry->clips[clip]; space = &geometry->spaces[reference->space];
        const double cx = space->xx * wx + space->xy * wy + space->x0;
        const double cy = space->yx * wx + space->yy * wy + space->y0;
        inside = cx >= reference->x && cy >= reference->y && cx < reference->x + reference->width && cy < reference->y + reference->height;
        clip = reference->clip;
    }
    CollectionRow row = {0};
    if (inside) {
        const CollectionCatalog *catalog = binding->front->catalog;
        const double position = (viewport.scroll + (local_y - viewport.y)) * 64;
        if (isfinite(position) && position >= 0 && position < (double)catalog->tops[catalog->count]) {
            const uint64_t tick = (uint64_t)floor(position);
            uint32_t low = 0, high = catalog->count;
            while (low < high) {
                const uint32_t middle = low + (high - low) / 2;
                if (catalog->tops[middle + 1] <= tick) low = middle + 1;
                else high = middle;
            }
            if (low < catalog->count) row = catalog->rows[low];
        }
    }
    ReleaseSRWLockShared(&state->lock);
    return row.id ? collection_identity_fragment(state, key, row.id, row.incarnation, out) : S_OK;
}
static void collection_begin_close_locked(State *state) {
    CollectionStore *store = state->collections ? state->collections->virtuals : NULL;
    if (!store) return;
    for (CollectionProvider *provider = store->provider_head; provider; provider = provider->next) collection_provider_add(provider);
    collection_store_clear(store);
}
static HRESULT collection_disconnect_rows(State *state) {
    HRESULT result = S_OK;
    for (;;) {
        AcquireSRWLockExclusive(&state->lock);
        CollectionStore *store = state->collections ? state->collections->virtuals : NULL;
        CollectionProvider *provider = store ? store->provider_head : NULL;
        if (provider) collection_provider_unlink(state, provider);
        ReleaseSRWLockExclusive(&state->lock);
        if (!provider) break;
        const HRESULT hr = UiaDisconnectProvider(&provider->simple);
        if (FAILED(hr) && SUCCEEDED(result)) result = hr;
        collection_provider_release(provider);
    }
    return result;
}
#endif
