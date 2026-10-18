#ifndef ZUA_COLLECTION_NATIVE_API_H
#define ZUA_COLLECTION_NATIVE_API_H
uint32_t zua_collection_model_prepare(uint64_t owner, uint64_t generation, uint64_t model_revision,
    const CollectionRow *rows, const CollectionIdentity *ids, const uint64_t *tops, uint32_t count,
    const char *text, uint32_t text_length, size_t budget, CollectionModel **out) {
    if (!out) return COLLECTION_INVALID;
    *out = NULL;
    size_t catalog_bytes, selection_bytes;
    enum CollectionStatus status = collection_catalog_bytes(count, text_length, &catalog_bytes);
    if (status) return status;
    status = collection_selection_bytes(count, &selection_bytes);
    if (status) return status;
    if (budget > 65 * 1024 * 1024 || catalog_bytes > SIZE_MAX - sizeof(CollectionModel) ||
        selection_bytes > SIZE_MAX - sizeof(CollectionModel) - catalog_bytes ||
        sizeof(CollectionModel) + catalog_bytes + selection_bytes > budget) return COLLECTION_BUDGET;
    CollectionCatalog *catalog = NULL;
    status = collection_catalog_create(owner, generation, model_revision, rows, ids, tops, count, text, text_length, catalog_bytes, &catalog);
    if (status) return status;
    status = collection_model_create_impl(catalog, 1, NULL, count / 64 + (count % 64 != 0), budget, 1, out);
    collection_catalog_release(catalog);
    return status;
}
void zua_collection_model_release(CollectionModel *model) { collection_model_release(model); }
size_t zua_collection_model_bytes(const CollectionModel *model) { return model ? model->owned_bytes : 0; }
typedef struct CollectionModelInfo {
    uint64_t owner, generation, model;
    uint32_t rows, reserved;
    size_t bytes;
} CollectionModelInfo;
uint32_t zua_collection_model_info(const CollectionModel *model, CollectionModelInfo *out) {
    if (!model || !out) return COLLECTION_INVALID;
    const CollectionCatalog *catalog = model->catalog;
    *out = (CollectionModelInfo){ catalog->owner, catalog->generation, catalog->model, catalog->count, 0, model->owned_bytes };
    return COLLECTION_OK;
}
typedef struct CollectionStats {
    size_t metadata, physical_models, held_models, providers, requests;
    size_t model_limit, provider_limit, request_limit;
    uint32_t capacity, reserved;
} CollectionStats;
uint32_t zua_virtuals_stats(State *state, CollectionStats *out) {
    if (!state || !out || GetCurrentThreadId() != state->owner) return COLLECTION_INVALID;
    AcquireSRWLockShared(&state->lock);
    CollectionStore *store = !state->closed && state->collections ? state->collections->virtuals : NULL;
    if (store) *out = (CollectionStats){ store->metadata_bytes, atomic_load_explicit(&store->ledger->used, memory_order_relaxed),
        store->held_model_bytes, store->provider_bytes, store->request_bytes, store->ledger->limit,
        store->provider_limit, store->request_limit, store->capacity, 0 };
    ReleaseSRWLockShared(&state->lock);
    return store ? COLLECTION_OK : COLLECTION_STALE;
}
uint32_t zua_virtuals_metadata_size(uint32_t capacity, size_t *out) { return collection_store_bytes(capacity, out); }
uint32_t zua_virtuals_create(uint32_t capacity, size_t metadata_budget, size_t model_budget,
    size_t provider_budget, size_t request_budget, CollectionStore **out) {
    if (!out) return COLLECTION_INVALID;
    *out = NULL;
    if (!provider_budget || provider_budget > 256 * 1024 * 1024 || !request_budget || request_budget > 16 * 1024 * 1024) return COLLECTION_INVALID;
    enum CollectionStatus status = collection_store_create(capacity, metadata_budget, model_budget, out);
    if (!status) { (*out)->provider_limit = provider_budget; (*out)->request_limit = request_budget; }
    return status;
}
void zua_virtuals_free(CollectionStore *store) { collection_store_release(store); }
uint32_t zua_virtuals_commit(State *state, CollectionStore *candidate) {
    if (!state || !candidate || GetCurrentThreadId() != state->owner) return COLLECTION_INVALID;
    AcquireSRWLockExclusive(&state->lock);
    enum CollectionStatus status = state->closed ? COLLECTION_STALE :
        !state->collections || state->collections->virtuals ? COLLECTION_INVALID : COLLECTION_OK;
    if (!status) state->collections->virtuals = candidate;
    ReleaseSRWLockExclusive(&state->lock);
    return status;
}
uint32_t zua_virtuals_prepared(State *state) {
    if (!state) return 0;
    AcquireSRWLockShared(&state->lock);
    const uint32_t prepared = !state->closed && state->collections && state->collections->virtuals;
    ReleaseSRWLockShared(&state->lock);
    return prepared;
}
uint32_t zua_virtuals_install(State *state, const CollectionRegistration *key, CollectionModel *model,
    uint64_t revision, const uint64_t *bits, uint32_t words) {
    if (!state || !key || GetCurrentThreadId() != state->owner) return COLLECTION_INVALID;
    AcquireSRWLockExclusive(&state->lock);
    CollectionStore *store = !state->closed && state->collections ? state->collections->virtuals : NULL;
    enum CollectionStatus status = store ? collection_store_install(store, *key, model, revision, bits, words) : COLLECTION_STALE;
    ReleaseSRWLockExclusive(&state->lock);
    return status;
}
uint32_t zua_virtuals_selection(State *state, const CollectionRegistration *key,
    uint64_t model, uint64_t base, uint64_t revision, const CollectionWordChange *changes, uint32_t count) {
    if (!state || !key || GetCurrentThreadId() != state->owner) return COLLECTION_INVALID;
    AcquireSRWLockExclusive(&state->lock);
    CollectionStore *store = !state->closed && state->collections ? state->collections->virtuals : NULL;
    enum CollectionStatus status = collection_store_apply(store, *key, model, base, revision, changes, count);
    ReleaseSRWLockExclusive(&state->lock);
    return status;
}
void zua_virtuals_withdraw(State *state, const CollectionRegistration *key) {
    if (!state || GetCurrentThreadId() != state->owner) return;
    AcquireSRWLockExclusive(&state->lock);
    CollectionStore *store = state->collections ? state->collections->virtuals : NULL;
    if (store) {
        if (key) collection_store_withdraw(store, *key);
        else collection_store_clear(store);
    }
    ReleaseSRWLockExclusive(&state->lock);
}
uint32_t zua_virtuals_begin_frame(State *state) {
    if (!state || GetCurrentThreadId() != state->owner) return COLLECTION_INVALID;
    AcquireSRWLockExclusive(&state->lock);
    CollectionStore *store = !state->closed && state->collections ? state->collections->virtuals : NULL;
    uint64_t frame;
    enum CollectionStatus status = store ? collection_store_begin_frame(store, &frame) : COLLECTION_OK;
    ReleaseSRWLockExclusive(&state->lock);
    return status;
}
uint32_t zua_virtuals_stage(State *state, const CollectionRegistration *key,
    uint64_t model, uint64_t selection, const CollectionViewport *viewport, const CollectionMapping *mapping) {
    if (!state || !key || !viewport || !mapping || GetCurrentThreadId() != state->owner) return COLLECTION_INVALID;
    AcquireSRWLockExclusive(&state->lock);
    CollectionStore *store = !state->closed && state->collections ? state->collections->virtuals : NULL;
    enum CollectionStatus status = store ? collection_store_stage_mapped(store, *key, store->frame, model, selection, *viewport, mapping) : COLLECTION_STALE;
    ReleaseSRWLockExclusive(&state->lock);
    return status;
}
uint32_t zua_virtuals_validate_frame(State *state) {
    if (!state || GetCurrentThreadId() != state->owner) return COLLECTION_INVALID;
    AcquireSRWLockShared(&state->lock);
    CollectionStore *store = !state->closed && state->collections ? state->collections->virtuals : NULL;
    enum CollectionStatus status = store ? collection_store_preflight(store, store->frame) : COLLECTION_OK;
    ReleaseSRWLockShared(&state->lock);
    return status;
}
static enum CollectionStatus collection_native_preflight_locked(State *state, const Node *nodes,
    uint32_t count, const RecipientAuthority *recipients, uint64_t *publication) {
    CollectionStore *store = state->collections ? state->collections->virtuals : NULL;
    if (!store) return COLLECTION_OK;
    enum CollectionStatus status = collection_store_preflight(store, store->frame);
    if (status) return status;
    uint64_t accepted = 0;
    for (uint32_t index = 0; index < count; ++index) {
        if (recipients && recipients[index].serial) {
            if (accepted && accepted != recipients[index].publication) return COLLECTION_INVALID;
            accepted = recipients[index].publication;
        }
        if (nodes[index].role != ROLE_LIST) continue;
        if (!recipients || !recipients[index].serial || recipients[index].kind != 1) return COLLECTION_INVALID;
        const RecipientAuthority native = recipients[index];
        const CollectionRegistration key = { native.epoch, native.serial, native.id, native.slot, native.kind };
        CollectionBinding *binding = collection_store_find(store, key);
        if (!binding || binding->staged_frame != store->frame) return COLLECTION_STALE;
    }
    for (uint32_t slot = 0; slot < store->capacity; ++slot) {
        const CollectionBinding *binding = &store->bindings[slot];
        if (binding->staged_frame != store->frame) continue;
        BOOL found = FALSE;
        for (uint32_t index = 0; index < count; ++index) if (nodes[index].role == ROLE_LIST && nodes[index].id == binding->registration.id) { found = TRUE; break; }
        if (!found) return COLLECTION_INVALID;
    }
    /* Even a successful frame with no marked recipients must withdraw all
       omitted native fronts. It requires no invented recipient publication. */
    if (publication) *publication = accepted;
    return COLLECTION_OK;
}
#endif
