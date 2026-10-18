#ifndef ZUA_COLLECTION_STORE_H
#define ZUA_COLLECTION_STORE_H
#include "accessibility_catalog.h"
#include "accessibility_collection_geometry.h"
#include <math.h>

typedef struct CollectionRegistration { uint64_t epoch, serial, id; uint32_t slot, kind; } CollectionRegistration;
typedef struct CollectionRowAuthority {
    uint64_t owner, generation, model, publication, row, incarnation;
} CollectionRowAuthority;
typedef struct CollectionRowRequest {
    CollectionRowAuthority authority;
    uint32_t kind, reserved;
} CollectionRowRequest;
typedef struct CollectionStore CollectionStore;
typedef struct CollectionLedger {
    _Atomic(uint32_t) refs;
    _Atomic(size_t) used;
    size_t limit;
} CollectionLedger;
typedef struct CollectionModel {
    _Atomic(uint32_t) refs;
    CollectionCatalog *catalog;
    CollectionSelection *selection;
    size_t owned_bytes;
    CollectionLedger *ledger;
    CollectionStore *store;
    uint32_t store_holds;
} CollectionModel;
typedef struct CollectionViewport {
    double x, y, width, height, scroll;
    uint32_t space, clip;
    uint64_t caret, caret_incarnation;
} CollectionViewport;
typedef struct CollectionBinding {
    CollectionRegistration registration;
    CollectionModel *pending, *front, *staged;
    CollectionViewport staged_viewport, front_viewport;
    CollectionMapping staged_mapping, front_mapping;
    uint64_t staged_frame, staged_revision, front_publication;
} CollectionBinding;
struct CollectionStore {
    uint32_t capacity, frame_open;
    uint64_t frame;
    size_t metadata_bytes, held_model_bytes;
    CollectionLedger *ledger;
    size_t provider_limit, provider_bytes, request_limit, request_bytes;
    CollectionRowRequest requests[16];
    CollectionBinding *bindings;
    /* Native adapters keep only currently outstanding row provider objects.
       Portable ownership tests do not inspect this platform-private chain. */
    void *provider_head;
};
_Static_assert(sizeof(CollectionRegistration) == 32, "collection registration ABI");
_Static_assert(sizeof(CollectionRowAuthority) == 48, "collection request authority ABI");
_Static_assert(sizeof(CollectionRowRequest) == 56, "collection request payload ABI");
_Static_assert(ATOMIC_POINTER_LOCK_FREE == 2, "native physical ledger requires lock-free size_t atomics");

static void collection_ledger_release(CollectionLedger *ledger) {
    if (atomic_fetch_sub_explicit(&ledger->refs, 1, memory_order_acq_rel) == 1) ZUA_COLLECTION_FREE(ledger);
}
static enum CollectionStatus collection_ledger_charge(CollectionLedger *ledger, size_t bytes) {
    uint32_t refs = atomic_load_explicit(&ledger->refs, memory_order_relaxed);
    for (;;) {
        if (!refs || refs == UINT32_MAX) return COLLECTION_EXHAUSTED;
        if (atomic_compare_exchange_weak_explicit(&ledger->refs, &refs, refs + 1,
                memory_order_relaxed, memory_order_relaxed)) break;
    }
    size_t used = atomic_load_explicit(&ledger->used, memory_order_relaxed);
    for (;;) {
        if (bytes > ledger->limit - used) { collection_ledger_release(ledger); return COLLECTION_BUDGET; }
        if (atomic_compare_exchange_weak_explicit(&ledger->used, &used, used + bytes,
                memory_order_relaxed, memory_order_relaxed)) return COLLECTION_OK;
    }
}

static int collection_registration_equal(CollectionRegistration a, CollectionRegistration b) {
    return a.epoch == b.epoch && a.serial == b.serial && a.id == b.id && a.slot == b.slot && a.kind == b.kind;
}
static int collection_registration_valid(CollectionRegistration key) {
    return key.epoch && key.serial && key.id && key.slot < 32 && key.kind == 1;
}
static enum CollectionStatus collection_model_retain(CollectionModel *model) {
    if (!model) return COLLECTION_INVALID;
    uint32_t refs = atomic_load_explicit(&model->refs, memory_order_relaxed);
    for (;;) {
        if (!refs || refs == UINT32_MAX) return COLLECTION_EXHAUSTED;
        if (atomic_compare_exchange_weak_explicit(&model->refs, &refs, refs + 1,
                memory_order_relaxed, memory_order_relaxed)) return COLLECTION_OK;
    }
}
static void collection_model_release(CollectionModel *model) {
    if (model && atomic_fetch_sub_explicit(&model->refs, 1, memory_order_acq_rel) == 1) {
        CollectionLedger *ledger = model->ledger;
        const size_t bytes = model->owned_bytes;
        collection_catalog_release(model->catalog);
        collection_selection_release(model->selection);
        ZUA_COLLECTION_FREE(model);
        if (ledger) {
            atomic_fetch_sub_explicit(&ledger->used, bytes, memory_order_relaxed);
            collection_ledger_release(ledger);
        }
    }
}
static enum CollectionStatus collection_model_create_impl(CollectionCatalog *catalog, uint64_t revision,
    const uint64_t *bits, uint32_t word_count, size_t budget, int empty, CollectionModel **out) {
    if (!out) return COLLECTION_INVALID;
    *out = NULL;
    if (!catalog) return COLLECTION_INVALID;
    size_t selection_bytes;
    enum CollectionStatus status = collection_selection_bytes(catalog->count, &selection_bytes);
    if (status) return status;
    if (catalog->owned_bytes > SIZE_MAX - sizeof(CollectionModel) ||
        selection_bytes > SIZE_MAX - sizeof(CollectionModel) - catalog->owned_bytes) return COLLECTION_BUDGET;
    const size_t bytes = sizeof(CollectionModel) + catalog->owned_bytes + selection_bytes;
    if (budget > 65 * 1024 * 1024 || bytes > budget) return COLLECTION_BUDGET;
    CollectionSelection *selection = NULL;
    status = collection_selection_create_impl(catalog->count, revision, bits, word_count, selection_bytes, empty, &selection);
    if (status) return status;
    CollectionModel *model = ZUA_COLLECTION_CALLOC(1, sizeof(*model));
    if (!model) { collection_selection_release(selection); return COLLECTION_OUT_OF_MEMORY; }
    status = collection_catalog_retain(catalog);
    if (status) { collection_selection_release(selection); ZUA_COLLECTION_FREE(model); return status; }
    atomic_init(&model->refs, 1);
    model->catalog = catalog;
    model->selection = selection;
    model->owned_bytes = bytes;
    *out = model;
    return COLLECTION_OK;
}
static enum CollectionStatus collection_model_create(CollectionCatalog *catalog, uint64_t revision,
    const uint64_t *bits, uint32_t word_count, size_t budget, CollectionModel **out) {
    return collection_model_create_impl(catalog, revision, bits, word_count, budget, 0, out);
}
static enum CollectionStatus collection_store_bytes(uint32_t capacity, size_t *out) {
    if (!out || !capacity || capacity > 32) return COLLECTION_INVALID;
    *out = sizeof(CollectionStore) + sizeof(CollectionLedger) + capacity * sizeof(CollectionBinding);
    return COLLECTION_OK;
}
static enum CollectionStatus collection_store_create(uint32_t capacity, size_t metadata_budget,
    size_t model_budget, CollectionStore **out) {
    if (!out) return COLLECTION_INVALID;
    *out = NULL;
    if (!capacity || capacity > 32 || !model_budget || model_budget > 128 * 1024 * 1024)
        return COLLECTION_INVALID;
    size_t bytes;
    enum CollectionStatus status = collection_store_bytes(capacity, &bytes);
    if (status) return status;
    if (bytes > metadata_budget) return COLLECTION_BUDGET;
    CollectionStore *store = ZUA_COLLECTION_CALLOC(1, bytes - sizeof(CollectionLedger));
    if (!store) return COLLECTION_OUT_OF_MEMORY;
    CollectionLedger *ledger = ZUA_COLLECTION_CALLOC(1, sizeof(*ledger));
    if (!ledger) { ZUA_COLLECTION_FREE(store); return COLLECTION_OUT_OF_MEMORY; }
    atomic_init(&ledger->refs, 1);
    atomic_init(&ledger->used, 0);
    ledger->limit = model_budget;
    store->capacity = capacity;
    store->metadata_bytes = bytes;
    store->ledger = ledger;
    store->bindings = (CollectionBinding *)(store + 1);
    *out = store;
    return COLLECTION_OK;
}
static enum CollectionStatus collection_store_hold(CollectionStore *store, CollectionModel *model) {
    if (model->store && model->store != store) return COLLECTION_STALE;
    if (model->ledger && model->ledger != store->ledger) return COLLECTION_STALE;
    if (model->store_holds == UINT32_MAX) return COLLECTION_EXHAUSTED;
    enum CollectionStatus status = collection_model_retain(model);
    if (status) return status;
    if (!model->ledger) {
        status = collection_ledger_charge(store->ledger, model->owned_bytes);
        if (status) { collection_model_release(model); return status; }
        model->ledger = store->ledger;
    }
    if (!model->store_holds) { model->store = store; store->held_model_bytes += model->owned_bytes; }
    ++model->store_holds;
    return COLLECTION_OK;
}
static void collection_store_drop(CollectionStore *store, CollectionModel *model) {
    if (!model) return;
    if (!--model->store_holds) { store->held_model_bytes -= model->owned_bytes; model->store = NULL; }
    collection_model_release(model);
}
static void collection_store_clear(CollectionStore *store) {
    if (!store) return;
    for (uint32_t i = 0; i < store->capacity; ++i) {
        CollectionBinding *binding = &store->bindings[i];
        CollectionModel *pending = binding->pending, *front = binding->front, *staged = binding->staged;
        memset(binding, 0, sizeof(*binding));
        collection_store_drop(store, pending);
        collection_store_drop(store, front);
        collection_store_drop(store, staged);
    }
    store->frame_open = 0;
}
static void collection_store_release(CollectionStore *store) {
    if (!store) return;
    collection_store_clear(store);
    collection_ledger_release(store->ledger);
    ZUA_COLLECTION_FREE(store);
}
static CollectionBinding *collection_store_find(CollectionStore *store, CollectionRegistration key) {
    for (uint32_t i = 0; i < store->capacity; ++i)
        if (collection_registration_equal(store->bindings[i].registration, key)) return &store->bindings[i];
    return NULL;
}
/* This is an explicit preparation/event operation, never a paint operation.
   A previous successful front remains independently owned until commit or
   withdrawal. Models cannot be attached to two native stores simultaneously. */
static enum CollectionStatus collection_store_bind(CollectionStore *store,
    CollectionRegistration key, CollectionModel *model) {
    if (!store || !model || !collection_registration_valid(key)) return COLLECTION_INVALID;
    CollectionBinding *binding = collection_store_find(store, key), *empty = NULL;
    for (uint32_t i = 0; i < store->capacity; ++i) {
        CollectionBinding *candidate = &store->bindings[i];
        if (!candidate->registration.serial) empty = candidate;
        if (candidate != binding && candidate->registration.id == key.id) return COLLECTION_STALE;
        if (candidate != binding && (candidate->pending == model || candidate->front == model)) return COLLECTION_STALE;
    }
    if (!binding) binding = empty;
    if (!binding) return COLLECTION_BUDGET;
    if (binding->pending == model) return COLLECTION_OK;
    enum CollectionStatus status = collection_store_hold(store, model);
    if (status) return status;
    CollectionModel *previous = binding->pending;
    binding->registration = key;
    binding->pending = model;
    binding->staged_frame = 0;
    collection_store_drop(store, binding->staged);
    binding->staged = NULL;
    collection_store_drop(store, previous);
    return COLLECTION_OK;
}
/* Installation is cold main-thread work. The freshly prepared product is
   private to its owner until all validation and budget checks have succeeded.
   Selection is seeded from the one current UI authority at publication time,
   so worker preparation cannot overwrite newer keyboard selections. */
static enum CollectionStatus collection_store_install(CollectionStore *store, CollectionRegistration key,
    CollectionModel *model, uint64_t revision, const uint64_t *bits, uint32_t word_count) {
    if (!store || !model || !collection_registration_valid(key) || model->ledger || model->store_holds ||
        atomic_load_explicit(&model->refs, memory_order_relaxed) != 1 ||
        model->catalog->owner != key.epoch || model->catalog->generation != key.serial) return COLLECTION_STALE;
    uint32_t selected;
    enum CollectionStatus status = collection_selection_seed_preflight(model->selection, revision, bits, word_count, &selected);
    if (status) return status;
    status = collection_store_bind(store, key, model);
    if (status) return status;
    collection_selection_seed_commit(model->selection, revision, bits, selected);
    return COLLECTION_OK;
}
static enum CollectionStatus collection_store_apply(CollectionStore *store, CollectionRegistration key,
    uint64_t model_revision, uint64_t base, uint64_t revision,
    const CollectionWordChange *changes, uint32_t count) {
    CollectionBinding *binding = store ? collection_store_find(store, key) : NULL;
    if (!binding || !binding->pending || binding->pending->catalog->model != model_revision) return COLLECTION_STALE;
    return collection_selection_apply(binding->pending->selection, base, revision, changes, count);
}
static void collection_store_withdraw(CollectionStore *store, CollectionRegistration key) {
    CollectionBinding *binding = collection_store_find(store, key);
    if (!binding) return;
    CollectionModel *pending = binding->pending, *front = binding->front, *staged = binding->staged;
    memset(binding, 0, sizeof(*binding));
    collection_store_drop(store, pending);
    collection_store_drop(store, front);
    collection_store_drop(store, staged);
}
static enum CollectionStatus collection_store_begin_frame(CollectionStore *store, uint64_t *frame) {
    if (!store || !frame) return COLLECTION_INVALID;
    if (store->frame == UINT64_MAX) return COLLECTION_EXHAUSTED;
    for (uint32_t i = 0; i < store->capacity; ++i) {
        CollectionBinding *binding = &store->bindings[i];
        collection_store_drop(store, binding->staged);
        binding->staged = NULL;
        binding->staged_frame = 0;
    }
    *frame = ++store->frame;
    store->frame_open = 1;
    return COLLECTION_OK;
}
static enum CollectionStatus collection_store_stage(CollectionStore *store, CollectionRegistration key,
    uint64_t frame, uint64_t model_revision, uint64_t selection_revision, CollectionViewport viewport) {
    if (!store || !frame || frame != store->frame || !store->frame_open) return COLLECTION_STALE;
    CollectionBinding *binding = collection_store_find(store, key);
    if (!binding || !binding->pending || binding->pending->catalog->model != model_revision ||
        binding->pending->selection->revision != selection_revision) return COLLECTION_STALE;
    if (binding->staged_frame == frame) return COLLECTION_INVALID;
    if (!isfinite(viewport.x) || !isfinite(viewport.y) || !isfinite(viewport.width) || !isfinite(viewport.height) ||
        !isfinite(viewport.scroll) || viewport.width < 0 || viewport.height < 0 || viewport.scroll < 0 ||
        !isfinite(viewport.x + viewport.width) || !isfinite(viewport.y + viewport.height)) return COLLECTION_INVALID;
    const CollectionCatalog *catalog = binding->pending->catalog;
    const double total = (double)catalog->tops[catalog->count] / 64;
    const double maximum_scroll = total > viewport.height ? total - viewport.height : 0;
    if (viewport.scroll > maximum_scroll || (!viewport.caret && viewport.caret_incarnation)) return COLLECTION_INVALID;
    if (viewport.caret) {
        uint32_t index;
        const CollectionRow *row = collection_catalog_find(catalog, viewport.caret, &index);
        if (!row || row->incarnation != viewport.caret_incarnation) return COLLECTION_STALE;
    }
    enum CollectionStatus status = collection_store_hold(store, binding->pending);
    if (status) return status;
    /* Geometry is checked by the native adapter against the candidate Frame's
       spaces/clips before this staging record can become a native front. */
    binding->staged_frame = frame;
    binding->staged = binding->pending;
    binding->staged_revision = selection_revision;
    binding->staged_viewport = viewport;
    binding->staged_mapping = (CollectionMapping){
        .forward = { 1, 0, 0, 1, 0, 0 },
        .viewport = { viewport.x, viewport.y, viewport.width, viewport.height },
        .polygon = { { viewport.x, viewport.y }, { viewport.x + viewport.width, viewport.y },
            { viewport.x + viewport.width, viewport.y + viewport.height }, { viewport.x, viewport.y + viewport.height } },
        .count = viewport.width > 0 && viewport.height > 0 ? 4 : 0
    };
    return COLLECTION_OK;
}
/* `mapping` comes from the affine adapter's fully validated prepare product.
   It is copied immediately; no caller pointer enters either native bank. */
static enum CollectionStatus collection_store_stage_mapped(CollectionStore *store, CollectionRegistration key,
    uint64_t frame, uint64_t model_revision, uint64_t selection_revision,
    CollectionViewport viewport, const CollectionMapping *mapping) {
    if (!mapping || mapping->reserved || mapping->count > 132 || mapping->viewport.x != viewport.x ||
        mapping->viewport.y != viewport.y || mapping->viewport.width != viewport.width || mapping->viewport.height != viewport.height)
        return COLLECTION_INVALID;
    for (uint32_t i = 0; i < 6; ++i) if (!isfinite(mapping->forward[i])) return COLLECTION_INVALID;
    for (uint32_t i = 0; i < mapping->count; ++i)
        if (!isfinite(mapping->polygon[i].x) || !isfinite(mapping->polygon[i].y)) return COLLECTION_INVALID;
    enum CollectionStatus status = collection_store_stage(store, key, frame, model_revision, selection_revision, viewport);
    if (status) return status;
    collection_store_find(store, key)->staged_mapping = *mapping;
    return COLLECTION_OK;
}
static enum CollectionStatus collection_store_preflight(CollectionStore *store, uint64_t frame) {
    if (!store || !frame || frame != store->frame || !store->frame_open) return COLLECTION_STALE;
    for (uint32_t i = 0; i < store->capacity; ++i) {
        CollectionBinding *binding = &store->bindings[i];
        if (binding->staged_frame != frame) continue;
        if (!binding->pending || binding->staged != binding->pending ||
            binding->staged_revision != binding->pending->selection->revision) return COLLECTION_STALE;
    }
    return COLLECTION_OK;
}
/* The adapter validates semantic keys, geometry and publication before calling
   this function, then holds one exclusive native State lock for all commits.
   It must not call foreign code between preflight and this non-failing write. */
static void collection_store_commit(CollectionStore *store, uint64_t frame, uint64_t publication) {
    for (uint32_t i = 0; i < store->capacity; ++i) {
        CollectionBinding *binding = &store->bindings[i];
        CollectionModel *previous = binding->front;
        if (binding->staged_frame != frame) {
            binding->front = NULL;
            binding->front_publication = 0;
            collection_store_drop(store, previous);
            continue;
        }
        binding->front = binding->staged;
        binding->staged = NULL;
        binding->staged_frame = 0;
        uint32_t written;
        collection_selection_commit(binding->front->selection, &written);
        binding->front_viewport = binding->staged_viewport;
        binding->front_mapping = binding->staged_mapping;
        binding->front_publication = publication;
        collection_store_drop(store, previous);
    }
    store->frame_open = 0;
}
static enum CollectionStatus collection_binding_capture(const CollectionBinding *binding,
    uint32_t index, CollectionRowAuthority *out) {
    if (!binding || !out || !binding->front || !binding->front_publication) return COLLECTION_STALE;
    const CollectionCatalog *catalog = binding->front->catalog;
    if (index >= catalog->count || !catalog->rows[index].enabled) return COLLECTION_INVALID;
    const CollectionRow *row = &catalog->rows[index];
    *out = (CollectionRowAuthority){ catalog->owner, catalog->generation, catalog->model,
        binding->front_publication, row->id, row->incarnation };
    return COLLECTION_OK;
}
static int collection_binding_accepts(const CollectionBinding *binding, CollectionRowAuthority authority) {
    if (!binding || !binding->front || binding->front_publication != authority.publication) return 0;
    const CollectionCatalog *catalog = binding->front->catalog;
    if (catalog->owner != authority.owner || catalog->generation != authority.generation || catalog->model != authority.model) return 0;
    uint32_t index;
    const CollectionRow *row = collection_catalog_find(catalog, authority.row, &index);
    return row && row->incarnation == authority.incarnation && row->enabled;
}

typedef struct CollectionReadSnapshot {
    CollectionModel *model;
    CollectionRow row;
    CollectionViewport viewport;
    uint64_t top_ticks, publication;
    uint32_t selected, caret;
} CollectionReadSnapshot;
/* The caller holds State's shared lock. Mutable front selection and viewport
   are copied here, never read after unlock through the retained Model. Only
   that Model's immutable Catalog/labels may be borrowed outside the lock.
   Geometry is copied only for a getter which requested it. */
static enum CollectionStatus collection_binding_read(const CollectionBinding *binding,
    uint64_t row_id, uint64_t incarnation, CollectionReadSnapshot *out, CollectionMapping *mapping) {
    if (!binding || !out || !binding->front || !binding->front_publication) return COLLECTION_STALE;
    CollectionModel *model = binding->front;
    uint32_t index;
    const CollectionRow *row = collection_catalog_find(model->catalog, row_id, &index);
    if (!row || row->incarnation != incarnation) return COLLECTION_STALE;
    enum CollectionStatus status = collection_model_retain(model);
    if (status) return status;
    const CollectionReadSnapshot candidate = {
        .model = model, .row = *row, .viewport = binding->front_viewport,
        .top_ticks = model->catalog->tops[index], .publication = binding->front_publication,
        .selected = (uint32_t)((model->selection->front[index / 64] >> (index % 64)) & 1),
        .caret = binding->front_viewport.caret == row_id && binding->front_viewport.caret_incarnation == incarnation
    };
    if (mapping) *mapping = binding->front_mapping;
    *out = candidate;
    return COLLECTION_OK;
}
static void collection_read_release(CollectionReadSnapshot *snapshot) {
    CollectionModel *model = snapshot->model;
    snapshot->model = NULL;
    collection_model_release(model);
}
#endif
