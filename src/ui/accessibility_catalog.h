#ifndef ZUA_COLLECTION_CATALOG_H
#define ZUA_COLLECTION_CATALOG_H
#include <stdatomic.h>
#include "accessibility_selection.h"

typedef struct CollectionRow {
    uint64_t id, incarnation;
    uint32_t height, start, length, enabled;
} CollectionRow;
typedef struct CollectionIdentity { uint64_t id, index; } CollectionIdentity;
typedef struct CollectionCatalog {
    _Atomic(uint32_t) refs;
    uint32_t count, text_length;
    uint64_t owner, generation, model;
    size_t owned_bytes;
    CollectionRow *rows;
    CollectionIdentity *ids;
    uint64_t *tops;
    char *text;
} CollectionCatalog;
_Static_assert(sizeof(CollectionRow) == 32, "collection row ABI");
_Static_assert(sizeof(CollectionIdentity) == 16, "collection identity ABI");
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "catalog ownership requires lock-free 32-bit atomics");

static int collection_utf8_valid(const char *bytes, size_t length) {
    const unsigned char *text = (const unsigned char *)bytes;
    size_t i = 0;
    while (i < length) {
        const unsigned char a = text[i++];
        if (!a) return 0;
        if (a < 0x80) continue;
        if (a < 0xc2 || a > 0xf4) return 0;
        const uint32_t trailing = a < 0xe0 ? 1 : a < 0xf0 ? 2 : 3;
        if (trailing > length - i) return 0;
        const unsigned char b = text[i];
        if ((a == 0xe0 && b < 0xa0) || (a == 0xed && b > 0x9f) ||
            (a == 0xf0 && b < 0x90) || (a == 0xf4 && b > 0x8f)) return 0;
        for (uint32_t j = 0; j < trailing; ++j) if ((text[i++] & 0xc0) != 0x80) return 0;
    }
    return 1;
}
static enum CollectionStatus collection_catalog_bytes(uint32_t count, uint32_t text_length, size_t *out) {
    if (!out || count > 1000000 || text_length > 8 * 1024 * 1024) return COLLECTION_INVALID;
    const size_t width = sizeof(CollectionRow) + sizeof(CollectionIdentity) + sizeof(uint64_t);
    size_t bytes = sizeof(CollectionCatalog) + sizeof(uint64_t);
    if (count > (SIZE_MAX - bytes) / width) return COLLECTION_BUDGET;
    bytes += (size_t)count * width;
    if (text_length > SIZE_MAX - bytes) return COLLECTION_BUDGET;
    *out = bytes + text_length;
    return COLLECTION_OK;
}

/* Sources are immutable for this explicit call. Preparation can run on a
   caller-managed worker; the product owns all labels and row identities and
   never retains any input address. Label slices form one packed UTF-8 stream,
   bounding validation by row count plus actual text bytes. */
static enum CollectionStatus collection_catalog_create(uint64_t owner, uint64_t generation,
    uint64_t model, const CollectionRow *rows, const CollectionIdentity *ids,
    const uint64_t *tops, uint32_t count, const char *text, uint32_t text_length,
    size_t budget, CollectionCatalog **out) {
    if (!out) return COLLECTION_INVALID;
    *out = NULL;
    if (!owner || !generation || !model || !tops || tops[0] ||
        (count && (!rows || !ids)) || (text_length && !text)) return COLLECTION_INVALID;
    size_t bytes;
    enum CollectionStatus status = collection_catalog_bytes(count, text_length, &bytes);
    if (status) return status;
    if (budget > 64 * 1024 * 1024 || bytes > budget) return COLLECTION_BUDGET;
    uint32_t text_used = 0;
    for (uint32_t i = 0; i < count; ++i) {
        const CollectionRow *row = &rows[i];
        if (!row->id || !row->incarnation || !row->height || row->height > 64000000 || row->enabled > 1 ||
            row->start != text_used || row->length > text_length - text_used || row->length > 4096 ||
            UINT64_MAX - tops[i] < row->height || tops[i + 1] != tops[i] + row->height ||
            ids[i].index >= count || ids[i].id != rows[ids[i].index].id ||
            (i && ids[i - 1].id >= ids[i].id)) return COLLECTION_INVALID;
        if (row->length && !collection_utf8_valid(text + row->start, row->length)) return COLLECTION_INVALID;
        text_used += row->length;
    }
    if (text_used != text_length) return COLLECTION_INVALID;
    CollectionCatalog *catalog = ZUA_COLLECTION_CALLOC(1, bytes);
    if (!catalog) return COLLECTION_OUT_OF_MEMORY;
    atomic_init(&catalog->refs, 1);
    catalog->owner = owner; catalog->generation = generation; catalog->model = model;
    catalog->count = count; catalog->text_length = text_length; catalog->owned_bytes = bytes;
    catalog->rows = (CollectionRow *)(catalog + 1);
    catalog->ids = (CollectionIdentity *)(catalog->rows + count);
    catalog->tops = (uint64_t *)(catalog->ids + count);
    catalog->text = (char *)(catalog->tops + (size_t)count + 1);
    if (count) { memcpy(catalog->rows, rows, count * sizeof(*rows)); memcpy(catalog->ids, ids, count * sizeof(*ids)); }
    memcpy(catalog->tops, tops, ((size_t)count + 1) * sizeof(*tops));
    if (text_length) memcpy(catalog->text, text, text_length);
    *out = catalog;
    return COLLECTION_OK;
}
static enum CollectionStatus collection_catalog_retain(CollectionCatalog *catalog) {
    if (!catalog) return COLLECTION_INVALID;
    uint32_t refs = atomic_load_explicit(&catalog->refs, memory_order_relaxed);
    for (;;) {
        if (!refs || refs == UINT32_MAX) return COLLECTION_EXHAUSTED;
        if (atomic_compare_exchange_weak_explicit(&catalog->refs, &refs, refs + 1,
                memory_order_relaxed, memory_order_relaxed)) return COLLECTION_OK;
    }
}
static void collection_catalog_release(CollectionCatalog *catalog) {
    if (catalog && atomic_fetch_sub_explicit(&catalog->refs, 1, memory_order_acq_rel) == 1)
        ZUA_COLLECTION_FREE(catalog);
}
static const CollectionRow *collection_catalog_find(const CollectionCatalog *catalog, uint64_t id, uint32_t *index) {
    uint32_t low = 0, high = catalog->count;
    while (low < high) {
        const uint32_t middle = low + (high - low) / 2;
        if (catalog->ids[middle].id < id) low = middle + 1; else high = middle;
    }
    if (low == catalog->count || catalog->ids[low].id != id) return NULL;
    *index = (uint32_t)catalog->ids[low].index;
    return &catalog->rows[*index];
}
#endif
