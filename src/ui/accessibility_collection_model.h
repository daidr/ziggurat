#ifndef ZUA_COLLECTION_MODEL_H
#define ZUA_COLLECTION_MODEL_H
/* The platform-neutral exports of complete lists: immutable models, which
   a caller-managed worker may prepare, and native stores before a host
   adopts one. Each native host includes this after the collection store
   and defines the host-bound zua_virtuals_* exports itself. */
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
#endif
