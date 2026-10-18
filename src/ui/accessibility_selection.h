#ifndef ZUA_COLLECTION_SELECTION_H
#define ZUA_COLLECTION_SELECTION_H
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#ifndef ZUA_COLLECTION_CALLOC
#define ZUA_COLLECTION_CALLOC calloc
#define ZUA_COLLECTION_FREE free
#endif

enum CollectionStatus {
    COLLECTION_OK, COLLECTION_INVALID, COLLECTION_BUDGET,
    COLLECTION_OUT_OF_MEMORY, COLLECTION_STALE, COLLECTION_EXHAUSTED
};
typedef struct CollectionWordChange {
    uint32_t word, reserved;
    uint64_t before, after;
} CollectionWordChange;
_Static_assert(sizeof(CollectionWordChange) == 24, "collection word change ABI");

/* One native value copy, not a second UI selection authority. Only owner-thread
   event handling applies deltas. COM readers use the front bitmap under the
   enclosing State lock. A failed paint never publishes pending values. */
typedef struct CollectionSelection {
    uint32_t count, word_count, selected, front_selected, dirty_count;
    uint64_t revision, front_revision, validation_epoch;
    size_t owned_bytes;
    uint64_t *pending, *front, *validation_seen;
    uint32_t *dirty, *dirty_positions;
} CollectionSelection;

static uint32_t collection_popcount(uint64_t value) {
    uint32_t count = 0;
    while (value) { value &= value - 1; ++count; }
    return count;
}
static uint64_t collection_last_mask(uint32_t count) {
    return count % 64 ? (UINT64_C(1) << (count % 64)) - 1 : UINT64_MAX;
}
static enum CollectionStatus collection_selection_bytes(uint32_t count, size_t *out) {
    if (!out || count > 1000000) return COLLECTION_INVALID;
    const size_t words = count / 64 + (count % 64 != 0);
    const size_t width = 3 * sizeof(uint64_t) + 2 * sizeof(uint32_t);
    if (words > (SIZE_MAX - sizeof(CollectionSelection)) / width) return COLLECTION_BUDGET;
    *out = sizeof(CollectionSelection) + words * width;
    return COLLECTION_OK;
}
static enum CollectionStatus collection_selection_create_impl(uint32_t count,
    uint64_t revision, const uint64_t *bits, uint32_t word_count, size_t budget,
    int empty, CollectionSelection **out) {
    if (!out) return COLLECTION_INVALID;
    *out = NULL;
    if (!revision || word_count != count / 64 + (count % 64 != 0) ||
        (word_count && !bits && !empty)) return COLLECTION_INVALID;
    size_t bytes;
    enum CollectionStatus status = collection_selection_bytes(count, &bytes);
    if (status) return status;
    if (budget > 1024 * 1024 || bytes > budget) return COLLECTION_BUDGET;
    if (word_count && bits && (bits[word_count - 1] & ~collection_last_mask(count))) return COLLECTION_INVALID;
    uint32_t selected = 0;
    if (bits) for (uint32_t i = 0; i < word_count; ++i) selected += collection_popcount(bits[i]);
    CollectionSelection *selection = ZUA_COLLECTION_CALLOC(1, bytes);
    if (!selection) return COLLECTION_OUT_OF_MEMORY;
    selection->count = count;
    selection->word_count = word_count;
    selection->selected = selection->front_selected = selected;
    selection->revision = selection->front_revision = revision;
    selection->owned_bytes = bytes;
    selection->pending = (uint64_t *)(selection + 1);
    selection->front = selection->pending + word_count;
    selection->validation_seen = selection->front + word_count;
    selection->dirty = (uint32_t *)(selection->validation_seen + word_count);
    selection->dirty_positions = selection->dirty + word_count;
    if (word_count && bits) {
        memcpy(selection->pending, bits, word_count * sizeof(*bits));
        memcpy(selection->front, bits, word_count * sizeof(*bits));
    }
    *out = selection;
    return COLLECTION_OK;
}
static enum CollectionStatus collection_selection_create(uint32_t count,
    uint64_t revision, const uint64_t *bits, uint32_t word_count, size_t budget,
    CollectionSelection **out) {
    return collection_selection_create_impl(count, revision, bits, word_count, budget, 0, out);
}
static enum CollectionStatus collection_selection_seed_preflight(const CollectionSelection *selection,
    uint64_t revision, const uint64_t *bits, uint32_t word_count, uint32_t *selected) {
    if (!selection || !selected || !revision || word_count != selection->word_count ||
        (word_count && !bits) || (word_count && (bits[word_count - 1] & ~collection_last_mask(selection->count)))) return COLLECTION_INVALID;
    uint32_t count = 0;
    for (uint32_t i = 0; i < word_count; ++i) count += collection_popcount(bits[i]);
    *selected = count;
    return COLLECTION_OK;
}
/* Only a newly prepared, not-yet-adopted model may be seeded. The caller has
   already validated all bytes and completed the failable store adoption. */
static void collection_selection_seed_commit(CollectionSelection *selection, uint64_t revision,
    const uint64_t *bits, uint32_t selected) {
    const size_t bytes = (size_t)selection->word_count * sizeof(*bits);
    if (bytes) { memcpy(selection->pending, bits, bytes); memcpy(selection->front, bits, bytes); }
    selection->selected = selection->front_selected = selected;
    selection->revision = selection->front_revision = revision;
    selection->dirty_count = 0;
    memset(selection->dirty_positions, 0, (size_t)selection->word_count * sizeof(*selection->dirty_positions));
}
static void collection_selection_release(CollectionSelection *selection) {
    ZUA_COLLECTION_FREE(selection);
}

/* Validate the entire request before changing any semantic value. Validation
   epochs are private duplicate-detection scratch; rejected patches cannot
   change either bitmap, either revision, selected count or dirty journal. */
static enum CollectionStatus collection_selection_apply(CollectionSelection *selection,
    uint64_t base, uint64_t revision, const CollectionWordChange *changes,
    uint32_t change_count) {
    if (!selection || (change_count && !changes) || change_count > selection->word_count)
        return COLLECTION_INVALID;
    if (base != selection->revision) return COLLECTION_STALE;
    if ((!change_count && revision != base) || (change_count &&
        (base == UINT64_MAX || revision != base + 1))) return COLLECTION_INVALID;
    if (selection->validation_epoch == UINT64_MAX) return COLLECTION_EXHAUSTED;
    const uint64_t epoch = ++selection->validation_epoch;
    uint32_t selected = selection->selected;
    for (uint32_t i = 0; i < change_count; ++i) {
        const CollectionWordChange *change = &changes[i];
        if (change->reserved || change->word >= selection->word_count ||
            change->before == change->after || selection->validation_seen[change->word] == epoch ||
            selection->pending[change->word] != change->before ||
            (change->word + 1 == selection->word_count && (change->after & ~collection_last_mask(selection->count))))
            return COLLECTION_INVALID;
        selection->validation_seen[change->word] = epoch;
        selected -= collection_popcount(change->before);
        selected += collection_popcount(change->after);
    }
    for (uint32_t i = 0; i < change_count; ++i) {
        const CollectionWordChange *change = &changes[i];
        const uint32_t word = change->word;
        if (!selection->dirty_positions[word]) {
            selection->dirty[selection->dirty_count++] = word;
            selection->dirty_positions[word] = selection->dirty_count;
        }
        selection->pending[word] = change->after;
    }
    selection->selected = selected;
    selection->revision = revision;
    return COLLECTION_OK;
}

/* This is called only after every frame input has passed preflight, while the
   State lock excludes COM readers. No allocation, labels or N-row pass occurs.
   The returned work count is the number of unique words touched since the
   preceding accepted publication, including changes which cancel out. */
static void collection_selection_commit(CollectionSelection *selection, uint32_t *words_written) {
    const uint32_t written = selection->dirty_count;
    for (uint32_t i = 0; i < written; ++i) {
        const uint32_t word = selection->dirty[i];
        selection->front[word] = selection->pending[word];
        selection->dirty_positions[word] = 0;
    }
    selection->dirty_count = 0;
    selection->front_selected = selection->selected;
    selection->front_revision = selection->revision;
    *words_written = written;
}
static enum CollectionStatus collection_selection_publish(CollectionSelection *selection,
    uint64_t expected_revision, uint32_t *words_written) {
    if (!selection || !words_written) return COLLECTION_INVALID;
    if (selection->revision != expected_revision) return COLLECTION_STALE;
    collection_selection_commit(selection, words_written);
    return COLLECTION_OK;
}
#endif
