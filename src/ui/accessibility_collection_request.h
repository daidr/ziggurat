#ifndef ZUA_COLLECTION_REQUEST_H
#define ZUA_COLLECTION_REQUEST_H
/* Native request preparation uses the existing Action[16] slots. The caller
   passes the provider's immutable registration/row incarnation, not a current
   integer ID to be rebound at a later dispatch. */
static HRESULT collection_request(State *state, CollectionRegistration key,
    uint64_t row_id, uint64_t incarnation, uint32_t kind) {
    if (kind < COLLECTION_SELECT || kind > COLLECTION_REVEAL) return E_INVALIDARG;
    AcquireSRWLockExclusive(&state->lock);
    Node *node = NULL;
    CollectionBinding *binding = collection_native_binding_locked(state, key, &node);
    if (!binding || !state->context) { ReleaseSRWLockExclusive(&state->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    if (!(node->flags & ENABLED)) { ReleaseSRWLockExclusive(&state->lock); return UIA_E_ELEMENTNOTENABLED; }
    uint32_t row_index;
    const CollectionRow *row = collection_catalog_find(binding->front->catalog, row_id, &row_index);
    if (!row || row->incarnation != incarnation) { ReleaseSRWLockExclusive(&state->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    if (!row->enabled) { ReleaseSRWLockExclusive(&state->lock); return UIA_E_ELEMENTNOTENABLED; }
    CollectionRowAuthority authority;
    if (collection_binding_capture(binding, row_index, &authority) != COLLECTION_OK) {
        ReleaseSRWLockExclusive(&state->lock); return UIA_E_ELEMENTNOTAVAILABLE;
    }
    Action *action = NULL;
    for (uint32_t i = 0; i < ACTION_CAP; ++i) if (!state->actions[i].used) { action = &state->actions[i]; break; }
    if (!action) { ReleaseSRWLockExclusive(&state->lock); return HRESULT_FROM_WIN32(ERROR_BUSY); }
    const size_t index = (size_t)(action - state->actions);
    action->state = state; action->used = TRUE; action->kind = 6; action->id = key.id;
    action->value_len = action->start = action->end = 0; action->number = 0;
    state->collections->requests[index] = state->collections->front[node - state->nodes];
    state->collections->virtuals->requests[index] = (CollectionRowRequest){ .authority = authority, .kind = kind };
    retain(state);
    InterlockedIncrement(&live_actions);
    int (*hook)(void *) = state->collections->before_enqueue;
    void *hook_context = state->collections->before_enqueue_context;
    state->collections->before_enqueue = NULL;
    state->collections->before_enqueue_context = NULL;
    if (hook) {
        ReleaseSRWLockExclusive(&state->lock);
        const int scheduled = hook(hook_context);
        AcquireSRWLockExclusive(&state->lock);
        if (!scheduled || state->closed || !state->context) {
            action->used = FALSE;
            state->collections->requests[index] = (RecipientAuthority){0};
            state->collections->virtuals->requests[index] = (CollectionRowRequest){0};
            ReleaseSRWLockExclusive(&state->lock);
            InterlockedDecrement(&live_actions); release(state);
            return UIA_E_ELEMENTNOTAVAILABLE;
        }
    }
    const BOOL owner = GetCurrentThreadId() == state->owner;
    const Enqueue enqueue = state->enqueue;
    void *context = state->context;
    if (owner) ReleaseSRWLockExclusive(&state->lock);
    const int accepted = enqueue(context, action);
    if (!owner) ReleaseSRWLockExclusive(&state->lock);
    if (!accepted) {
        AcquireSRWLockExclusive(&state->lock);
        action->used = FALSE;
        state->collections->requests[index] = (RecipientAuthority){0};
        state->collections->virtuals->requests[index] = (CollectionRowRequest){0};
        ReleaseSRWLockExclusive(&state->lock);
        InterlockedDecrement(&live_actions); release(state);
        return UIA_E_ELEMENTNOTAVAILABLE;
    }
    return S_OK;
}
#endif
