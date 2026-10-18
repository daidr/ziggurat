#ifndef ZUA_COLLECTIONS_H
#define ZUA_COLLECTIONS_H
typedef struct RecipientAuthority { uint64_t epoch, serial, id, publication; uint32_t slot, kind; } RecipientAuthority;
_Static_assert(sizeof(RecipientAuthority) == 40, "recipient authority ABI");
#include "accessibility_collection_store.h"
typedef struct Collections {
    RecipientAuthority front[NODE_CAP], requests[ACTION_CAP];
    int (*before_enqueue)(void *);
    void *before_enqueue_context;
    CollectionStore *virtuals;
} Collections;
static BOOL recipient_equal(const RecipientAuthority *a, const RecipientAuthority *b) {
    return a->epoch == b->epoch && a->serial == b->serial && a->id == b->id && a->publication == b->publication && a->slot == b->slot && a->kind == b->kind;
}
static BOOL recipient_valid(const RecipientAuthority *key, uint64_t id, uint32_t role) {
    if (!key->serial) return !key->epoch && !key->id && !key->publication && !key->slot && !key->kind;
    if (!key->epoch || !key->publication || key->id != id || key->slot >= 32 || key->kind > 1) return FALSE;
    return key->kind != 0 || role == ROLE_TEXT_BOX;
}
#endif