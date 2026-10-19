/* Native COM identities own copied semantic snapshots, never borrowed Zig data. */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define NO_STRICT
#define INITGUID
#define CONST_VTABLE
#include <windows.h>
#include <uiautomation.h>
#include <oleauto.h>
#include <stdint.h>
#include <stdlib.h>
#include <stddef.h>
#include <wchar.h>
#include <math.h>
#include <string.h>

#define NODE_CAP 128
#define TEXT_CAP 32768
#define ACTION_CAP 16
#define VALUE_CAP 4096
#define SPACE_CAP 129
#define CLIP_CAP 128
#define CLIP_DEPTH 32
#define ENABLED 1
#define FOCUSED 2
#define READ_ONLY 4
#define OFFSCREEN 8
#define CHECKED 16
#define INVALID 32
#define REQUIRED 64
#define MULTIPLE 128
#define EXPANDABLE 256
#define EXPANDED 512
enum { ROLE_WINDOW, ROLE_GROUP, ROLE_BUTTON, ROLE_TEXT, ROLE_TEXT_BOX, ROLE_CHECKBOX, ROLE_RADIO, ROLE_SWITCH, ROLE_PROGRESS, ROLE_RADIO_GROUP, ROLE_SLIDER, ROLE_STEPPER, ROLE_LIST, ROLE_TAB_LIST, ROLE_TAB, ROLE_TOOLBAR, ROLE_SPLITTER, ROLE_LINK, ROLE_DISCLOSURE, ROLE_METER, ROLE_NAVIGATION, ROLE_LIST_BOX, ROLE_LIST_ITEM, ROLE_COMBO_BOX, ROLE_TOOLTIP, ROLE_STATUS, ROLE_SEARCH, ROLE_IMAGE, ROLE_TREE, ROLE_TREE_ITEM, ROLE_TABLE, ROLE_TABLE_HEADER, ROLE_COLUMN_HEADER, ROLE_TABLE_ROW, ROLE_TOKEN_FIELD, ROLE_TOKEN };
enum { PATTERN_INVOKE = 1, PATTERN_VALUE = 2, PATTERN_TEXT = 4, PATTERN_TOGGLE = 8, PATTERN_SELECTION_ITEM = 16, PATTERN_SELECTION = 32, PATTERN_RANGE_VALUE = 64, PATTERN_COLLECTION = 128, PATTERN_EXPAND_COLLAPSE = 256 };

typedef struct Node {
    uint64_t id, parent;
    uint32_t role, flags, name_start, name_len, value_start, value_len;
    uint32_t selection_start, selection_end, description_start, description_len;
    double x, y, width, height, range_value;
    double range_minimum, range_maximum, range_small_change, range_large_change;
} Node;
typedef struct GeometrySpace { double xx,yx,xy,yy,x0,y0; } GeometrySpace;
typedef struct GeometryRef { double x,y,width,height; uint32_t space,clip; } GeometryRef;
typedef struct Geometry {
    GeometrySpace spaces[SPACE_CAP];
    GeometryRef clips[CLIP_CAP],nodes[NODE_CAP];
    uint32_t space_count,clip_count,node_count;
    double origin_x,origin_y,scale;
} Geometry;
_Static_assert(sizeof(GeometrySpace)==48,"semantic space ABI");
_Static_assert(sizeof(GeometryRef)==40,"semantic clip ABI");
_Static_assert(sizeof(Geometry)==16472,"semantic geometry ABI");
typedef struct State State;
typedef struct Provider Provider;
typedef struct Range Range;
#include "accessibility_collections.h"
typedef int (*Enqueue)(void *, void *);
typedef struct Action {
    State *state;
    BOOL used;
    uint32_t kind;
    uint64_t id;
    uint32_t value_len, start, end;
    double number;
    WCHAR value[VALUE_CAP];
} Action;
typedef struct ActionView {
    void *context;
    uint32_t kind;
    uint64_t id;
    const WCHAR *value;
    uint32_t value_len, start, end;
    double number;
    RecipientAuthority recipient;
} ActionView;
_Static_assert(sizeof(void *) != 8 || sizeof(ActionView) == 96, "captured native action ABI");
struct State {
    LONG refs;
    SRWLOCK lock;
    BOOL closed;
    HWND hwnd;
    IRawElementProviderSimple *host;
    DWORD owner;
    Enqueue enqueue;
    void *context;
    Provider *root;
    Provider *providers;
    uint32_t count, text_len;
    Node nodes[NODE_CAP];
    WCHAR text[TEXT_CAP];
    Action actions[ACTION_CAP];
    Geometry *geometry;
    BOOL geometry_active;
    Collections *collections;
};
struct Provider {
    IRawElementProviderSimple simple;
    IRawElementProviderFragment fragment;
    IRawElementProviderFragmentRoot root;
    IInvokeProvider invoke;
    IValueProvider value;
    ITextProvider text;
    IToggleProvider toggle;
    ISelectionItemProvider selection_item;
    ISelectionProvider selection;
    IRangeValueProvider range_value;
    IExpandCollapseProvider expand_collapse;
    LONG refs;
    State *state;
    uint64_t id;
    uint32_t patterns;
    Provider *previous, *next;
    BOOL listed;
};
struct Range {
    ITextRangeProvider iface;
    LONG refs;
    State *state;
    uint64_t id;
    uint32_t start, end;
};
/* Only list anchors allocate this tail. The ordinary Provider ABI is intact. */
typedef struct CollectionAnchor { Provider provider; CollectionRegistration registration; } CollectionAnchor;
static HRESULT collection_anchor_new(State *, uint64_t, Provider **);
static HRESULT collection_anchor_new_for(State *, uint64_t, const CollectionRegistration *, Provider **);
static HRESULT collection_container_new(Provider *, REFIID, void **);
static HRESULT collection_child_fragment(State *, CollectionRegistration, enum NavigateDirection, IRawElementProviderFragment **);
static HRESULT collection_focus_fragment(State *, CollectionRegistration, IRawElementProviderFragment **);
static HRESULT collection_point_fragment(State *, CollectionRegistration, double, double, IRawElementProviderFragment **);
static LONG live_states, live_providers, live_ranges, live_actions,live_geometries,live_collections;
void zua_collections_free(Collections *);
uint32_t zua_geometry_count(void) { return (uint32_t)InterlockedCompareExchange(&live_geometries,0,0); }
Geometry *zua_geometry_create(void) {
    Geometry *geometry=calloc(1,sizeof(*geometry));
    if(geometry)InterlockedIncrement(&live_geometries);
    return geometry;
}
void zua_geometry_free(Geometry *geometry) {
    if(geometry){free(geometry);InterlockedDecrement(&live_geometries);}
}
void zua_resource_counts(uint32_t *states, uint32_t *providers, uint32_t *ranges, uint32_t *actions) {
    *states = (uint32_t)InterlockedCompareExchange(&live_states, 0, 0);
    *providers = (uint32_t)InterlockedCompareExchange(&live_providers, 0, 0);
    *ranges = (uint32_t)InterlockedCompareExchange(&live_ranges, 0, 0);
    *actions = (uint32_t)InterlockedCompareExchange(&live_actions, 0, 0);
}
static void retain(State *s) { InterlockedIncrement(&s->refs); }
static void release(State *s) { if (!InterlockedDecrement(&s->refs)) { if (s->host) IRawElementProviderSimple_Release(s->host); zua_geometry_free(s->geometry); zua_collections_free(s->collections); free(s); InterlockedDecrement(&live_states); } }
static Node *find(State *s, uint64_t id) {
    if (s->closed) return NULL;
    for (uint32_t i = 0; i < s->count; ++i) if (s->nodes[i].id == id) return &s->nodes[i];
    return NULL;
}
static Node *provider_find_locked(Provider *provider) {
    State *state = provider->state;
    Node *node = find(state, provider->id);
    if (!node || !(provider->patterns & PATTERN_COLLECTION)) return node;
    const CollectionRegistration key = ((CollectionAnchor *)provider)->registration;
    if (node->role != ROLE_LIST || !state->collections || !state->collections->virtuals) return NULL;
    const RecipientAuthority *current = &state->collections->front[node - state->nodes];
    if (current->epoch != key.epoch || current->serial != key.serial || current->id != key.id ||
        current->slot != key.slot || current->kind != key.kind) return NULL;
    CollectionBinding *binding = collection_store_find(state->collections->virtuals, key);
    return binding && binding->front && binding->front_publication == current->publication ? node : NULL;
}
static HRESULT read_provider_node(Provider *provider, Node *out) {
    AcquireSRWLockShared(&provider->state->lock);
    Node *node = provider_find_locked(provider);
    if (node) *out = *node;
    ReleaseSRWLockShared(&provider->state->lock);
    return node ? S_OK : UIA_E_ELEMENTNOTAVAILABLE;
}
static HRESULT read_node(State *s, uint64_t id, Node *out) {
    AcquireSRWLockShared(&s->lock);
    Node *n = find(s, id);
    if (n) *out = *n;
    ReleaseSRWLockShared(&s->lock);
    return n ? S_OK : UIA_E_ELEMENTNOTAVAILABLE;
}
static ULONG provider_add(Provider *p) { return InterlockedIncrement(&p->refs); }
static void unlink_provider(State *s, Provider *p) {
    if (!p->listed) return;
    if (p->previous) p->previous->next = p->next; else s->providers = p->next;
    if (p->next) p->next->previous = p->previous;
    p->previous = p->next = NULL; p->listed = FALSE;
}
static ULONG provider_release(Provider *p) {
    State *s = p->state;
    AcquireSRWLockExclusive(&s->lock);
    LONG refs = InterlockedDecrement(&p->refs);
    if (!refs) unlink_provider(s, p);
    ReleaseSRWLockExclusive(&s->lock);
    if (!refs) {
        const BOOL collection = (p->patterns & PATTERN_COLLECTION) != 0;
        free(p);
        if (collection) {
            AcquireSRWLockExclusive(&s->lock);
            s->collections->virtuals->provider_bytes -= sizeof(CollectionAnchor);
            ReleaseSRWLockExclusive(&s->lock);
        }
        release(s); InterlockedDecrement(&live_providers);
    }
    return refs;
}
static HRESULT provider_new(State *, uint64_t, Provider **);
static Range *range_new(State *, uint64_t, uint32_t, uint32_t);
static const ITextRangeProviderVtbl range_vtable;
static BOOL toggle_role(uint32_t role) { return role == ROLE_CHECKBOX || role == ROLE_SWITCH; }
/* Tabs and list box options select like radios: one selected item per
   chooser container. Trees and tables may allow several (MULTIPLE). */
static BOOL item_role(uint32_t role) { return role == ROLE_RADIO || role == ROLE_TAB || role == ROLE_LIST_ITEM || role == ROLE_TREE_ITEM || role == ROLE_TABLE_ROW; }
static BOOL chooser_role(uint32_t role) { return role == ROLE_RADIO_GROUP || role == ROLE_TAB_LIST || role == ROLE_LIST_BOX || role == ROLE_TREE || role == ROLE_TABLE; }
static BOOL invoke_role(uint32_t role) { return role == ROLE_BUTTON || role == ROLE_LINK || role == ROLE_COLUMN_HEADER; }
/* A combo box expands and collapses its list like a disclosure. */
static BOOL expander_role(uint32_t role) { return role == ROLE_DISCLOSURE || role == ROLE_COMBO_BOX; }
static BOOL actionable(uint32_t role) { return invoke_role(role) || item_role(role) || toggle_role(role) || expander_role(role); }
/* Progress and meters report a value no client may set. */
static BOOL fixed_range(uint32_t role) { return role == ROLE_PROGRESS || role == ROLE_METER; }
static BOOL range_role(uint32_t role) { return fixed_range(role) || role == ROLE_SLIDER || role == ROLE_STEPPER || role == ROLE_SPLITTER; }
static BOOL focusable(uint32_t role) { return actionable(role) || role == ROLE_TOKEN || role == ROLE_TEXT_BOX || role == ROLE_SLIDER || role == ROLE_STEPPER || role == ROLE_SPLITTER || role == ROLE_LIST; }
static uint32_t patterns_for_role(uint32_t role) {
    if (invoke_role(role)) return PATTERN_INVOKE;
    if (role == ROLE_DISCLOSURE) return PATTERN_EXPAND_COLLAPSE;
    if (role == ROLE_TREE_ITEM) return PATTERN_SELECTION_ITEM | PATTERN_EXPAND_COLLAPSE;
    if (role == ROLE_COMBO_BOX) return PATTERN_EXPAND_COLLAPSE | PATTERN_VALUE;
    if (role == ROLE_TEXT_BOX) return PATTERN_VALUE | PATTERN_TEXT;
    if (toggle_role(role)) return PATTERN_TOGGLE;
    if (item_role(role)) return PATTERN_SELECTION_ITEM;
    if (chooser_role(role)) return PATTERN_SELECTION;
    if (range_role(role)) return PATTERN_RANGE_VALUE;
    if (role == ROLE_LIST) return PATTERN_COLLECTION;
    return 0;
}
static HRESULT provider_query(Provider *p, REFIID iid, void **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    if (IsEqualIID(iid, &IID_IUnknown) || IsEqualIID(iid, &IID_IRawElementProviderSimple)) *out = &p->simple;
    else if (IsEqualIID(iid, &IID_IRawElementProviderFragment)) *out = &p->fragment;
    else if (p->id == 0 && IsEqualIID(iid, &IID_IRawElementProviderFragmentRoot)) *out = &p->root;
    else if ((p->patterns & PATTERN_COLLECTION) && (IsEqualIID(iid, &IID_IItemContainerProvider) || IsEqualIID(iid, &IID_ISelectionProvider) || IsEqualIID(iid, &IID_ISelectionProvider2))) return collection_container_new(p, iid, out);
    else {
        /* COM's interface set is immutable even after the semantic node leaves
           the tree. Only actual pattern operations depend on a live node. */
        if ((p->patterns & PATTERN_INVOKE) && IsEqualIID(iid, &IID_IInvokeProvider)) *out = &p->invoke;
        else if ((p->patterns & PATTERN_VALUE) && IsEqualIID(iid, &IID_IValueProvider)) *out = &p->value;
        else if ((p->patterns & PATTERN_TEXT) && IsEqualIID(iid, &IID_ITextProvider)) *out = &p->text;
        else if ((p->patterns & PATTERN_TOGGLE) && IsEqualIID(iid, &IID_IToggleProvider)) *out = &p->toggle;
        else if ((p->patterns & PATTERN_SELECTION_ITEM) && IsEqualIID(iid, &IID_ISelectionItemProvider)) *out = &p->selection_item;
        else if ((p->patterns & PATTERN_SELECTION) && IsEqualIID(iid, &IID_ISelectionProvider)) *out = &p->selection;
        else if ((p->patterns & PATTERN_RANGE_VALUE) && IsEqualIID(iid, &IID_IRangeValueProvider)) *out = &p->range_value;
        else if ((p->patterns & PATTERN_EXPAND_COLLAPSE) && IsEqualIID(iid, &IID_IExpandCollapseProvider)) *out = &p->expand_collapse;
    }
    if (!*out) return E_NOINTERFACE;
    provider_add(p);
    return S_OK;
}
#define PROVIDER_UNKNOWN(Prefix, Interface, Member) \
    static Provider *Prefix##_self(Interface *p) { return (Provider *)((char *)p - offsetof(Provider, Member)); } \
    static HRESULT STDMETHODCALLTYPE Prefix##_query(Interface *p, REFIID iid, void **out) { return provider_query(Prefix##_self(p), iid, out); } \
    static ULONG STDMETHODCALLTYPE Prefix##_add(Interface *p) { return provider_add(Prefix##_self(p)); } \
    static ULONG STDMETHODCALLTYPE Prefix##_release(Interface *p) { return provider_release(Prefix##_self(p)); }
PROVIDER_UNKNOWN(simple, IRawElementProviderSimple, simple)
PROVIDER_UNKNOWN(fragment, IRawElementProviderFragment, fragment)
PROVIDER_UNKNOWN(root, IRawElementProviderFragmentRoot, root)
PROVIDER_UNKNOWN(invoke, IInvokeProvider, invoke)
PROVIDER_UNKNOWN(value, IValueProvider, value)
PROVIDER_UNKNOWN(text, ITextProvider, text)
PROVIDER_UNKNOWN(toggle, IToggleProvider, toggle)
PROVIDER_UNKNOWN(selection_item, ISelectionItemProvider, selection_item)
PROVIDER_UNKNOWN(selection, ISelectionProvider, selection)
PROVIDER_UNKNOWN(range_value, IRangeValueProvider, range_value)
PROVIDER_UNKNOWN(expand_collapse, IExpandCollapseProvider, expand_collapse)

static HRESULT request_registered(State *s, uint64_t id, uint32_t kind, const WCHAR *value, uint32_t start, uint32_t end, double number, const CollectionRegistration *expected) {
    AcquireSRWLockExclusive(&s->lock);
    Node *n = find(s, id);
    if (!n || !s->context) { ReleaseSRWLockExclusive(&s->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    if (expected) {
        const RecipientAuthority *current = s->collections ? &s->collections->front[n - s->nodes] : NULL;
        if (!current || current->epoch != expected->epoch || current->serial != expected->serial ||
            current->id != expected->id || current->slot != expected->slot || current->kind != expected->kind) {
            ReleaseSRWLockExclusive(&s->lock); return UIA_E_ELEMENTNOTAVAILABLE;
        }
    }
    if (!(n->flags & ENABLED)) { ReleaseSRWLockExclusive(&s->lock); return UIA_E_ELEMENTNOTENABLED; }
    if ((kind == 1 && !actionable(n->role)) || (kind == 2 && !focusable(n->role)) || ((kind == 3 || kind == 4) && n->role != ROLE_TEXT_BOX) || (kind == 5 && !range_role(n->role))) {
        ReleaseSRWLockExclusive(&s->lock); return UIA_E_NOTSUPPORTED;
    }
    if (kind == 3 && (n->flags & READ_ONLY)) { ReleaseSRWLockExclusive(&s->lock); return UIA_E_INVALIDOPERATION; }
    if (kind == 5 && (fixed_range(n->role) || (n->flags & READ_ONLY))) { ReleaseSRWLockExclusive(&s->lock); return UIA_E_INVALIDOPERATION; }
    if (kind == 5 && (!isfinite(number) || number < n->range_minimum || number > n->range_maximum)) { ReleaseSRWLockExclusive(&s->lock); return E_INVALIDARG; }
    uint32_t length = 0;
    if (kind == 3) {
        if (!value) { ReleaseSRWLockExclusive(&s->lock); return E_INVALIDARG; }
        while (length < VALUE_CAP && value[length]) ++length;
        if (length == VALUE_CAP) { ReleaseSRWLockExclusive(&s->lock); return E_INVALIDARG; }
        for (uint32_t i = 0; i < length; ++i) {
            if (value[i] >= 0xd800 && value[i] <= 0xdbff) {
                if (++i == length || value[i] < 0xdc00 || value[i] > 0xdfff) { ReleaseSRWLockExclusive(&s->lock); return E_INVALIDARG; }
            } else if (value[i] >= 0xdc00 && value[i] <= 0xdfff) { ReleaseSRWLockExclusive(&s->lock); return E_INVALIDARG; }
        }
    }
    Action *a = NULL;
    for (uint32_t i = 0; i < ACTION_CAP; ++i) if (!s->actions[i].used) { a = &s->actions[i]; break; }
    if (!a) { ReleaseSRWLockExclusive(&s->lock); return HRESULT_FROM_WIN32(ERROR_BUSY); }
    a->state = s; a->used = TRUE; a->kind = kind; a->id = id;
    a->value_len = length; a->start = start; a->end = end;
    a->number = number;
    if (s->collections) s->collections->requests[a - s->actions] = s->collections->front[n - s->nodes];
    if (s->collections && s->collections->virtuals) s->collections->virtuals->requests[a - s->actions] = (CollectionRowRequest){0};
    if (length) memcpy(a->value, value, length * sizeof(WCHAR));
    retain(s); InterlockedIncrement(&live_actions);
    int (*before_enqueue)(void *) = NULL;
    void *before_enqueue_context = NULL;
    if (s->collections) {
        before_enqueue = s->collections->before_enqueue;
        before_enqueue_context = s->collections->before_enqueue_context;
        s->collections->before_enqueue = NULL;
        s->collections->before_enqueue_context = NULL;
    }
    if (before_enqueue) {
        /* The request ref pins State and its optional copied store. No native
           lock is held across this private one-shot test scheduler seam. */
        ReleaseSRWLockExclusive(&s->lock);
        int scheduled = before_enqueue(before_enqueue_context);
        AcquireSRWLockExclusive(&s->lock);
        if (!scheduled || s->closed || !s->context) {
            a->used = FALSE;
            if (s->collections) s->collections->requests[a - s->actions] = (RecipientAuthority){0};
            ReleaseSRWLockExclusive(&s->lock);
            InterlockedDecrement(&live_actions); release(s);
            return UIA_E_ELEMENTNOTAVAILABLE;
        }
    }
    Enqueue enqueue = s->enqueue;
    void *context = s->context;
    BOOL owner = GetCurrentThreadId() == s->owner;
    if (owner) ReleaseSRWLockExclusive(&s->lock);
    /* On the owner thread, no other owner can detach between unlock and enqueue.
       Other threads hold the short native lock until App.post has returned. */
    int accepted = enqueue(context, a);
    if (!owner) ReleaseSRWLockExclusive(&s->lock);
    if (!accepted) {
        AcquireSRWLockExclusive(&s->lock); a->used = FALSE; ReleaseSRWLockExclusive(&s->lock);
        InterlockedDecrement(&live_actions); release(s);
        return UIA_E_ELEMENTNOTAVAILABLE;
    }
    return S_OK;
}
static HRESULT request(State *s, uint64_t id, uint32_t kind, const WCHAR *value, uint32_t start, uint32_t end, double number) {
    return request_registered(s, id, kind, value, start, end, number, NULL);
}
int zua_take_action(Action *a, ActionView *out) {
    State *s = a->state;
    AcquireSRWLockShared(&s->lock);
    Node *n = find(s, a->id);
    BOOL available = !s->closed && a->used && s->context && n && (n->flags & ENABLED);
    RecipientAuthority captured = {0};
    if (available && s->collections) {
        captured = s->collections->requests[a - s->actions];
        const RecipientAuthority *current = &s->collections->front[n - s->nodes];
        /* Zero -> registered is also an authority change. An older legacy
           request must not become an action on a newly registered recipient. */
        if (!recipient_equal(&captured, current)) available = FALSE;
    }
    if (available && a->kind == 6) {
        CollectionStore *store = s->collections ? s->collections->virtuals : NULL;
        const CollectionRegistration key = { captured.epoch, captured.serial, captured.id, captured.slot, captured.kind };
        CollectionBinding *binding = store ? collection_store_find(store, key) : NULL;
        const CollectionRowRequest *row = store ? &store->requests[a - s->actions] : NULL;
        if (!binding || !row || n->role != ROLE_LIST || row->kind < 1 || row->kind > 5 || row->reserved || !collection_binding_accepts(binding, row->authority)) available = FALSE;
    }
    if (available && a->kind == 5 && ((n->flags & READ_ONLY) || fixed_range(n->role) || a->number < n->range_minimum || a->number > n->range_maximum)) available = FALSE;
    if (available) *out = (ActionView){ s->context, a->kind, a->id, a->value, a->value_len, a->start, a->end, a->number, captured };
    ReleaseSRWLockShared(&s->lock);
    return available;
}
/* Called only from the noinline collection dispatch branch. Common native
   actions keep their original 96-byte view and never allocate row scratch. */
int zua_take_collection_action(Action *action, CollectionRowRequest *out) {
    if (!action || !out) return 0;
    State *state = action->state;
    AcquireSRWLockShared(&state->lock);
    Node *node = find(state, action->id);
    BOOL available = action->used && action->kind == 6 && state->context && node &&
        node->role == ROLE_LIST && (node->flags & ENABLED) && state->collections && state->collections->virtuals;
    if (available) {
        const RecipientAuthority captured = state->collections->requests[action - state->actions];
        const RecipientAuthority *current = &state->collections->front[node - state->nodes];
        const CollectionRegistration key = { captured.epoch, captured.serial, captured.id, captured.slot, captured.kind };
        CollectionStore *store = state->collections->virtuals;
        const CollectionRowRequest *row = &store->requests[action - state->actions];
        CollectionBinding *binding = collection_store_find(store, key);
        available = recipient_equal(&captured, current) && row->kind >= 1 && row->kind <= 5 && !row->reserved && collection_binding_accepts(binding, row->authority);
        if (available) *out = *row;
    }
    ReleaseSRWLockShared(&state->lock);
    return available;
}
void zua_finish_action(Action *a) {
    State *s = a->state;
    AcquireSRWLockExclusive(&s->lock);
    a->used = FALSE;
    if (s->collections) s->collections->requests[a - s->actions] = (RecipientAuthority){0};
    if (s->collections && s->collections->virtuals) s->collections->virtuals->requests[a - s->actions] = (CollectionRowRequest){0};
    ReleaseSRWLockExclusive(&s->lock);
    InterlockedDecrement(&live_actions); release(s);
}

static HRESULT STDMETHODCALLTYPE simple_options(IRawElementProviderSimple *iface, enum ProviderOptions *out) {
    (void)iface;
    if (!out) return E_POINTER;
    /* UI Automation still queries this immutable COM metadata to disconnect a
       closed provider. It never needs a live semantic node or Zig context. */
    *out = ProviderOptions_ServerSideProvider | ProviderOptions_UseComThreading;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE simple_pattern(IRawElementProviderSimple *iface, PATTERNID id, IUnknown **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    Provider *p = simple_self(iface);
    Node n; HRESULT hr = read_provider_node(p, &n); if (FAILED(hr)) return hr;
    if (n.role == ROLE_LIST && (p->patterns & PATTERN_COLLECTION)) {
        if (id == UIA_ItemContainerPatternId) return collection_container_new(p, &IID_IItemContainerProvider, (void **)out);
        if (id == UIA_SelectionPatternId) return collection_container_new(p, &IID_ISelectionProvider2, (void **)out);
    }
    if (id == UIA_InvokePatternId && invoke_role(n.role)) *out = (IUnknown *)&p->invoke;
    if (id == UIA_ExpandCollapsePatternId && (expander_role(n.role) || n.role == ROLE_TREE_ITEM)) *out = (IUnknown *)&p->expand_collapse;
    if (id == UIA_ValuePatternId && (n.role == ROLE_TEXT_BOX || n.role == ROLE_COMBO_BOX)) *out = (IUnknown *)&p->value;
    if (id == UIA_TextPatternId && n.role == ROLE_TEXT_BOX) *out = (IUnknown *)&p->text;
    if (id == UIA_TogglePatternId && toggle_role(n.role)) *out = (IUnknown *)&p->toggle;
    if (id == UIA_SelectionItemPatternId && item_role(n.role)) *out = (IUnknown *)&p->selection_item;
    if (id == UIA_SelectionPatternId && chooser_role(n.role)) *out = (IUnknown *)&p->selection;
    if (id == UIA_RangeValuePatternId && range_role(n.role)) *out = (IUnknown *)&p->range_value;
    if (*out) provider_add(p);
    return S_OK;
}
/* A tree item keeps its selection in CHECKED and its expansion in its own
   flags; a disclosure or combo box is expanded while CHECKED. */
static enum ExpandCollapseState expand_state(const Node *n) {
    if (n->role == ROLE_TREE_ITEM) {
        if (!(n->flags & EXPANDABLE)) return ExpandCollapseState_LeafNode;
        return (n->flags & EXPANDED) ? ExpandCollapseState_Expanded : ExpandCollapseState_Collapsed;
    }
    return (n->flags & CHECKED) ? ExpandCollapseState_Expanded : ExpandCollapseState_Collapsed;
}
/* The chooser that holds an item's selection: its parent, or for a nested
   tree item the nearest tree above it. Call with the lock held. */
static Node *selection_owner(State *s, const Node *n) {
    Node *parent = find(s, n->parent);
    for (uint32_t depth = 0; parent && depth < NODE_CAP; ++depth) {
        if (chooser_role(parent->role)) return parent;
        if (parent->role != ROLE_TREE_ITEM || parent->id == 0) return NULL;
        parent = find(s, parent->parent);
    }
    return NULL;
}
static int control_type(uint32_t role) {
    switch (role) {
        case ROLE_WINDOW: return UIA_WindowControlTypeId;
        case ROLE_GROUP: return UIA_GroupControlTypeId;
        case ROLE_BUTTON: return UIA_ButtonControlTypeId;
        case ROLE_TEXT: return UIA_TextControlTypeId;
        case ROLE_CHECKBOX: case ROLE_SWITCH: return UIA_CheckBoxControlTypeId;
        case ROLE_RADIO: return UIA_RadioButtonControlTypeId;
        case ROLE_PROGRESS: return UIA_ProgressBarControlTypeId;
        case ROLE_RADIO_GROUP: return UIA_GroupControlTypeId;
        case ROLE_SLIDER: return UIA_SliderControlTypeId;
        case ROLE_STEPPER: return UIA_SpinnerControlTypeId;
        case ROLE_LIST: return UIA_ListControlTypeId;
        case ROLE_TAB_LIST: return UIA_TabControlTypeId;
        case ROLE_TAB: return UIA_TabItemControlTypeId;
        case ROLE_TOOLBAR: return UIA_ToolBarControlTypeId;
        case ROLE_SPLITTER: return UIA_ThumbControlTypeId;
        case ROLE_LINK: return UIA_HyperlinkControlTypeId;
        case ROLE_DISCLOSURE: return UIA_ButtonControlTypeId;
        case ROLE_METER: return UIA_ProgressBarControlTypeId;
        case ROLE_NAVIGATION: return UIA_GroupControlTypeId;
        case ROLE_LIST_BOX: return UIA_ListControlTypeId;
        case ROLE_LIST_ITEM: return UIA_ListItemControlTypeId;
        case ROLE_COMBO_BOX: return UIA_ComboBoxControlTypeId;
        case ROLE_TOOLTIP: return UIA_ToolTipControlTypeId;
        case ROLE_STATUS: return UIA_GroupControlTypeId;
        case ROLE_SEARCH: return UIA_GroupControlTypeId;
        case ROLE_IMAGE: return UIA_ImageControlTypeId;
        case ROLE_TREE: return UIA_TreeControlTypeId;
        case ROLE_TREE_ITEM: return UIA_TreeItemControlTypeId;
        case ROLE_TABLE: return UIA_DataGridControlTypeId;
        case ROLE_TABLE_HEADER: return UIA_HeaderControlTypeId;
        case ROLE_COLUMN_HEADER: return UIA_HeaderItemControlTypeId;
        case ROLE_TABLE_ROW: return UIA_DataItemControlTypeId;
        case ROLE_TOKEN_FIELD: return UIA_ListControlTypeId;
        case ROLE_TOKEN: return UIA_ListItemControlTypeId;
        default: return UIA_EditControlTypeId;
    }
}
static HRESULT STDMETHODCALLTYPE simple_property(IRawElementProviderSimple *iface, PROPERTYID id, VARIANT *out) {
    if (!out) return E_POINTER;
    VariantInit(out);
    Provider *p = simple_self(iface); State *s = p->state;
    AcquireSRWLockShared(&s->lock); Node *n = provider_find_locked(p);
    if (!n) { ReleaseSRWLockShared(&s->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    HRESULT hr = S_OK;
    switch (id) {
        case UIA_NamePropertyId: case UIA_ValueValuePropertyId: {
            BOOL name = id == UIA_NamePropertyId;
            out->vt = VT_BSTR;
            out->bstrVal = SysAllocStringLen(s->text + (name ? n->name_start : n->value_start), name ? n->name_len : n->value_len);
            if (!out->bstrVal) hr = E_OUTOFMEMORY;
            break;
        }
        case UIA_HelpTextPropertyId:
            if (n->description_len) { out->vt = VT_BSTR; out->bstrVal = SysAllocStringLen(s->text + n->description_start, n->description_len); if (!out->bstrVal) hr = E_OUTOFMEMORY; }
            break;
        case UIA_IsDataValidForFormPropertyId: out->vt = VT_BOOL; out->boolVal = (n->flags & INVALID) ? VARIANT_FALSE : VARIANT_TRUE; break;
        case UIA_IsRequiredForFormPropertyId: out->vt = VT_BOOL; out->boolVal = (n->flags & REQUIRED) ? VARIANT_TRUE : VARIANT_FALSE; break;
        case UIA_AutomationIdPropertyId: {
            WCHAR id_text[24]; _snwprintf(id_text, 24, L"%llu", (unsigned long long)n->id);
            out->vt = VT_BSTR; out->bstrVal = SysAllocString(id_text); if (!out->bstrVal) hr = E_OUTOFMEMORY; break;
        }
        case UIA_ControlTypePropertyId: out->vt = VT_I4; out->lVal = control_type(n->role); break;
        case UIA_LocalizedControlTypePropertyId:
            /* A meter shares the progress bar control type but is not progress. */
            if (n->role == ROLE_METER || n->role == ROLE_STATUS || n->role == ROLE_TOKEN_FIELD || n->role == ROLE_TOKEN) {
                out->vt = VT_BSTR;
                out->bstrVal = SysAllocString(n->role == ROLE_METER ? L"meter" : n->role == ROLE_STATUS ? L"status" : n->role == ROLE_TOKEN ? L"token" : L"token field");
                if (!out->bstrVal) hr = E_OUTOFMEMORY;
            }
            break;
        /* A column header reports its sort direction as item status. */
        case UIA_ItemStatusPropertyId:
            if (n->role == ROLE_COLUMN_HEADER && n->value_len) { out->vt = VT_BSTR; out->bstrVal = SysAllocStringLen(s->text + n->value_start, n->value_len); if (!out->bstrVal) hr = E_OUTOFMEMORY; }
            break;
        case UIA_LandmarkTypePropertyId:
            if (n->role == ROLE_NAVIGATION) { out->vt = VT_I4; out->lVal = UIA_NavigationLandmarkTypeId; }
            if (n->role == ROLE_SEARCH) { out->vt = VT_I4; out->lVal = UIA_SearchLandmarkTypeId; }
            break;
        /* A status message is announced politely when it appears. */
        case UIA_LiveSettingPropertyId: if (n->role == ROLE_STATUS) { out->vt = VT_I4; out->lVal = Polite; } break;
        case UIA_IsEnabledPropertyId: out->vt = VT_BOOL; out->boolVal = (n->flags & ENABLED) ? VARIANT_TRUE : VARIANT_FALSE; break;
        case UIA_HasKeyboardFocusPropertyId: out->vt = VT_BOOL; out->boolVal = (n->flags & FOCUSED) ? VARIANT_TRUE : VARIANT_FALSE; break;
        case UIA_IsKeyboardFocusablePropertyId: out->vt = VT_BOOL; out->boolVal = focusable(n->role) && (n->flags & ENABLED) && n->width > 0 && n->height > 0 ? VARIANT_TRUE : VARIANT_FALSE; break;
        case UIA_IsControlElementPropertyId: case UIA_IsContentElementPropertyId: out->vt = VT_BOOL; out->boolVal = VARIANT_TRUE; break;
        case UIA_IsOffscreenPropertyId: out->vt = VT_BOOL; out->boolVal = (n->flags & OFFSCREEN) ? VARIANT_TRUE : VARIANT_FALSE; break;
        case UIA_IsInvokePatternAvailablePropertyId: out->vt = VT_BOOL; out->boolVal = invoke_role(n->role) ? VARIANT_TRUE : VARIANT_FALSE; break;
        case UIA_IsExpandCollapsePatternAvailablePropertyId: out->vt = VT_BOOL; out->boolVal = expander_role(n->role) || n->role == ROLE_TREE_ITEM ? VARIANT_TRUE : VARIANT_FALSE; break;
        case UIA_ExpandCollapseExpandCollapseStatePropertyId: out->vt = VT_I4; out->lVal = expand_state(n); break;
        case UIA_IsValuePatternAvailablePropertyId: out->vt = VT_BOOL; out->boolVal = n->role == ROLE_TEXT_BOX || n->role == ROLE_COMBO_BOX ? VARIANT_TRUE : VARIANT_FALSE; break;
        case UIA_IsTextPatternAvailablePropertyId: out->vt = VT_BOOL; out->boolVal = n->role == ROLE_TEXT_BOX ? VARIANT_TRUE : VARIANT_FALSE; break;
        case UIA_ValueIsReadOnlyPropertyId: out->vt = VT_BOOL; out->boolVal = (n->flags & READ_ONLY) ? VARIANT_TRUE : VARIANT_FALSE; break;
        case UIA_IsTogglePatternAvailablePropertyId: out->vt = VT_BOOL; out->boolVal = toggle_role(n->role) ? VARIANT_TRUE : VARIANT_FALSE; break;
        case UIA_ToggleToggleStatePropertyId: out->vt = VT_I4; out->lVal = (n->flags & CHECKED) ? ToggleState_On : ToggleState_Off; break;
        case UIA_IsSelectionItemPatternAvailablePropertyId: out->vt = VT_BOOL; out->boolVal = item_role(n->role) ? VARIANT_TRUE : VARIANT_FALSE; break;
        case UIA_SelectionItemIsSelectedPropertyId: out->vt = VT_BOOL; out->boolVal = (n->flags & CHECKED) ? VARIANT_TRUE : VARIANT_FALSE; break;
        case UIA_IsSelectionPatternAvailablePropertyId: out->vt = VT_BOOL; out->boolVal = chooser_role(n->role) || n->role == ROLE_LIST ? VARIANT_TRUE : VARIANT_FALSE; break;
        case UIA_IsSelectionPattern2AvailablePropertyId: case UIA_IsItemContainerPatternAvailablePropertyId: out->vt = VT_BOOL; out->boolVal = n->role == ROLE_LIST ? VARIANT_TRUE : VARIANT_FALSE; break;
        case UIA_SelectionCanSelectMultiplePropertyId: out->vt = VT_BOOL; out->boolVal = n->role == ROLE_LIST || (chooser_role(n->role) && (n->flags & MULTIPLE)) ? VARIANT_TRUE : VARIANT_FALSE; break;
        case UIA_SelectionIsSelectionRequiredPropertyId: out->vt = VT_BOOL; out->boolVal = VARIANT_FALSE; break;
        case UIA_IsRangeValuePatternAvailablePropertyId: out->vt = VT_BOOL; out->boolVal = range_role(n->role) ? VARIANT_TRUE : VARIANT_FALSE; break;
        case UIA_RangeValueIsReadOnlyPropertyId: out->vt = VT_BOOL; out->boolVal = fixed_range(n->role) || (n->flags & READ_ONLY) ? VARIANT_TRUE : VARIANT_FALSE; break;
        case UIA_RangeValueValuePropertyId: out->vt = VT_R8; out->dblVal = n->range_value; break;
        case UIA_RangeValueMinimumPropertyId: out->vt = VT_R8; out->dblVal = n->range_minimum; break;
        case UIA_RangeValueMaximumPropertyId: out->vt = VT_R8; out->dblVal = n->range_maximum; break;
        case UIA_RangeValueSmallChangePropertyId: out->vt = VT_R8; out->dblVal = n->range_small_change; break;
        case UIA_RangeValueLargeChangePropertyId: out->vt = VT_R8; out->dblVal = n->range_large_change; break;
        default: break;
    }
    ReleaseSRWLockShared(&s->lock);
    return hr;
}
static HRESULT STDMETHODCALLTYPE simple_host(IRawElementProviderSimple *iface, IRawElementProviderSimple **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    Provider *p = simple_self(iface);
    /* Host identity must survive HWND destruction and remains available to
       UiaDisconnectProvider after semantic getters have become unavailable. */
    if (p->id == 0) { *out = p->state->host; IRawElementProviderSimple_AddRef(*out); }
    return S_OK;
}
static HRESULT make_fragment(State *s, uint64_t id, IRawElementProviderFragment **out) {
    if (id == 0) {
        AcquireSRWLockShared(&s->lock);
        Provider *root = s->closed ? NULL : s->root;
        if (root) { provider_add(root); *out = &root->fragment; }
        ReleaseSRWLockShared(&s->lock);
        return root ? S_OK : UIA_E_ELEMENTNOTAVAILABLE;
    }
    Provider *p = NULL; HRESULT hr = provider_new(s, id, &p); if (FAILED(hr)) return hr;
    *out = &p->fragment; return S_OK;
}
static HRESULT STDMETHODCALLTYPE fragment_navigate(IRawElementProviderFragment *iface, enum NavigateDirection direction, IRawElementProviderFragment **out) {
    if (!out) return E_POINTER;
    *out = NULL; Provider *p = fragment_self(iface); State *s = p->state;
    if ((p->patterns & PATTERN_COLLECTION) && (direction == NavigateDirection_FirstChild || direction == NavigateDirection_LastChild))
        return collection_child_fragment(s, ((CollectionAnchor *)p)->registration, direction, out);
    AcquireSRWLockShared(&s->lock); Node *n = provider_find_locked(p);
    if (!n) { ReleaseSRWLockShared(&s->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    BOOL found = FALSE; uint64_t id = 0;
    if (direction == NavigateDirection_Parent && p->id != 0) { id = n->parent; found = TRUE; }
    else if (direction == NavigateDirection_FirstChild || direction == NavigateDirection_LastChild) {
        for (uint32_t i = 1; i < s->count; ++i) if (s->nodes[i].parent == p->id) {
            id = s->nodes[i].id; found = TRUE; if (direction == NavigateDirection_FirstChild) break;
        }
    } else if (direction == NavigateDirection_NextSibling || direction == NavigateDirection_PreviousSibling) {
        int index = (int)(n - s->nodes), step = direction == NavigateDirection_NextSibling ? 1 : -1;
        for (index += step; index > 0 && index < (int)s->count; index += step) if (s->nodes[index].parent == n->parent) { id = s->nodes[index].id; found = TRUE; break; }
    }
    ReleaseSRWLockShared(&s->lock);
    return found ? make_fragment(s, id, out) : S_OK;
}
static HRESULT STDMETHODCALLTYPE fragment_runtime(IRawElementProviderFragment *iface, SAFEARRAY **out) {
    if (!out) return E_POINTER;
    /* Runtime identity is immutable, including during native disconnection. */
    *out = NULL; Provider *p = fragment_self(iface);
    if (p->id == 0) return S_OK;
    const BOOL collection = (p->patterns & PATTERN_COLLECTION) != 0;
    const CollectionRegistration key = collection ? ((CollectionAnchor *)p)->registration : (CollectionRegistration){0};
    const LONG count = collection ? 7 : 3;
    SAFEARRAY *array = SafeArrayCreateVector(VT_I4, 0, (ULONG)count); if (!array) return E_OUTOFMEMORY;
    LONG values[7] = { UiaAppendRuntimeId, (LONG)(uint32_t)p->id, (LONG)(uint32_t)(p->id >> 32),
        (LONG)(uint32_t)key.epoch, (LONG)(uint32_t)(key.epoch >> 32), (LONG)(uint32_t)key.serial, (LONG)(uint32_t)(key.serial >> 32) };
    for (LONG i = 0; i < count; ++i) {
        const HRESULT hr = SafeArrayPutElement(array, &i, &values[i]);
        if (FAILED(hr)) { SafeArrayDestroy(array); return hr; }
    }
    *out = array; return S_OK;
}
static HRESULT STDMETHODCALLTYPE fragment_bounds(IRawElementProviderFragment *iface, struct UiaRect *out) {
    if (!out) return E_POINTER;
    Provider *p = fragment_self(iface); Node n;
    HRESULT hr = read_provider_node(p, &n); if (FAILED(hr)) return hr;
    *out = (struct UiaRect){ n.x, n.y, n.width, n.height }; return S_OK;
}
static HRESULT STDMETHODCALLTYPE fragment_embedded(IRawElementProviderFragment *iface, SAFEARRAY **out) {
    if (!out) return E_POINTER; *out = NULL; Node n; Provider *p = fragment_self(iface); return read_provider_node(p, &n);
}
static HRESULT STDMETHODCALLTYPE fragment_focus(IRawElementProviderFragment *iface) {
    Provider *p = fragment_self(iface);
    const CollectionRegistration *key = p->patterns & PATTERN_COLLECTION ? &((CollectionAnchor *)p)->registration : NULL;
    return request_registered(p->state, p->id, 2, NULL, 0, 0, 0, key);
}
static HRESULT STDMETHODCALLTYPE fragment_root(IRawElementProviderFragment *iface, IRawElementProviderFragmentRoot **out) {
    if (!out) return E_POINTER; *out = NULL; Provider *p = fragment_self(iface);
    AcquireSRWLockShared(&p->state->lock);
    Provider *root = p->state->root;
    if (root) { provider_add(root); *out = &root->root; }
    ReleaseSRWLockShared(&p->state->lock);
    return root ? S_OK : UIA_E_ELEMENTNOTAVAILABLE;
}
static HRESULT STDMETHODCALLTYPE root_point(IRawElementProviderFragmentRoot *iface, double x, double y, IRawElementProviderFragment **out) {
    if (!out) return E_POINTER; *out = NULL; Provider *p = root_self(iface); State *s = p->state;
    AcquireSRWLockShared(&s->lock); if (!find(s, 0)) { ReleaseSRWLockShared(&s->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    uint64_t id = 0; CollectionRegistration collection = {0};
    for (uint32_t i = s->count; i > 0; --i) {
        Node *n = &s->nodes[i - 1];
        if (!(x >= n->x && y >= n->y && x < n->x + n->width && y < n->y + n->height)) continue;
        if (s->geometry_active) {
            const Geometry *g=s->geometry;
            double wx=(x-g->origin_x)/g->scale,wy=(y-g->origin_y)/g->scale;
            const GeometryRef *ref=&g->nodes[i-1];
            const GeometrySpace *space=&g->spaces[ref->space];
            double local_x=space->xx*wx+space->xy*wy+space->x0,local_y=space->yx*wx+space->yy*wy+space->y0;
            if(!(local_x>=ref->x&&local_y>=ref->y&&local_x<ref->x+ref->width&&local_y<ref->y+ref->height))continue;
            uint32_t clip=ref->clip;BOOL inside=TRUE;
            while(clip!=UINT32_MAX){
                ref=&g->clips[clip];space=&g->spaces[ref->space];
                local_x=space->xx*wx+space->xy*wy+space->x0;local_y=space->yx*wx+space->yy*wy+space->y0;
                if(!(local_x>=ref->x&&local_y>=ref->y&&local_x<ref->x+ref->width&&local_y<ref->y+ref->height)){inside=FALSE;break;}
                clip=ref->clip;
            }
            if(!inside)continue;
        }
        id=n->id;
        if (n->role == ROLE_LIST && s->collections) {
            const RecipientAuthority native = s->collections->front[n - s->nodes];
            collection = (CollectionRegistration){ native.epoch, native.serial, native.id, native.slot, native.kind };
        }
        break;
    }
    ReleaseSRWLockShared(&s->lock);
    if (collection.serial) {
        const HRESULT hr = collection_point_fragment(s, collection, x, y, out);
        if (FAILED(hr) || *out) return hr;
    }
    return make_fragment(s, id, out);
}
static HRESULT STDMETHODCALLTYPE root_focus(IRawElementProviderFragmentRoot *iface, IRawElementProviderFragment **out) {
    if (!out) return E_POINTER; *out = NULL; Provider *p = root_self(iface); State *s = p->state;
    AcquireSRWLockShared(&s->lock); if (!find(s, 0)) { ReleaseSRWLockShared(&s->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    BOOL found = FALSE; uint64_t id = 0; CollectionRegistration collection = {0};
    for (uint32_t i = 0; i < s->count; ++i) if (s->nodes[i].flags & FOCUSED) {
        id = s->nodes[i].id; found = TRUE;
        if (s->nodes[i].role == ROLE_LIST && s->collections) {
            const RecipientAuthority native = s->collections->front[i];
            collection = (CollectionRegistration){ native.epoch, native.serial, native.id, native.slot, native.kind };
        }
        break;
    }
    ReleaseSRWLockShared(&s->lock);
    if (collection.serial) {
        const HRESULT hr = collection_focus_fragment(s, collection, out);
        if (FAILED(hr) || *out) return hr;
    }
    return found ? make_fragment(s, id, out) : S_OK;
}
static HRESULT STDMETHODCALLTYPE invoke_call(IInvokeProvider *iface) { Provider *p = invoke_self(iface); return request(p->state, p->id, 1, NULL, 0, 0, 0); }
static HRESULT STDMETHODCALLTYPE value_set(IValueProvider *iface, LPCWSTR value) {
    Provider *p = value_self(iface); Node n;
    HRESULT hr = read_provider_node(p, &n); if (FAILED(hr)) return hr;
    /* A combo box value is its current choice, changed only through its list. */
    if (n.role != ROLE_TEXT_BOX) return UIA_E_INVALIDOPERATION;
    return request(p->state, p->id, 3, value, 0, 0, 0);
}
static HRESULT STDMETHODCALLTYPE value_get(IValueProvider *iface, BSTR *out) {
    if (!out) return E_POINTER; *out = NULL; Provider *p = value_self(iface); State *s = p->state;
    AcquireSRWLockShared(&s->lock); Node *n = provider_find_locked(p);
    if (n) *out = SysAllocStringLen(s->text + n->value_start, n->value_len);
    ReleaseSRWLockShared(&s->lock); return n ? (*out ? S_OK : E_OUTOFMEMORY) : UIA_E_ELEMENTNOTAVAILABLE;
}
static HRESULT STDMETHODCALLTYPE value_readonly(IValueProvider *iface, WINBOOL *out) {
    if (!out) return E_POINTER; Provider *p = value_self(iface); Node n;
    HRESULT hr = read_provider_node(p, &n); if (SUCCEEDED(hr)) *out = (n.flags & READ_ONLY) != 0; return hr;
}

static HRESULT STDMETHODCALLTYPE toggle_call(IToggleProvider *iface) {
    Provider *p = toggle_self(iface); return request(p->state, p->id, 1, NULL, 0, 0, 0);
}
static HRESULT STDMETHODCALLTYPE toggle_state(IToggleProvider *iface, enum ToggleState *out) {
    if (!out) return E_POINTER; Provider *p = toggle_self(iface); Node n;
    HRESULT hr = read_provider_node(p, &n);
    if (SUCCEEDED(hr)) *out = (n.flags & CHECKED) ? ToggleState_On : ToggleState_Off; return hr;
}
/* A disclosure's or combo box's checked flag is its expanded state; one
   activation flips it. */
static HRESULT expand_collapse_to(IExpandCollapseProvider *iface, BOOL expanded) {
    Provider *p = expand_collapse_self(iface); Node n;
    HRESULT hr = read_provider_node(p, &n); if (FAILED(hr)) return hr;
    if (!(n.flags & ENABLED)) return UIA_E_ELEMENTNOTENABLED;
    /* A tree item's activation selects it, so expansion is a value request
       (ItemRequest expand = 3, collapse = 2 in widgets.zig). */
    if (n.role == ROLE_TREE_ITEM) {
        if (!(n.flags & EXPANDABLE)) return UIA_E_INVALIDOPERATION;
        return ((n.flags & EXPANDED) != 0) == expanded ? S_OK : request(p->state, p->id, 5, NULL, 0, 0, expanded ? 3 : 2);
    }
    return ((n.flags & CHECKED) != 0) == expanded ? S_OK : request(p->state, p->id, 1, NULL, 0, 0, 0);
}
static HRESULT STDMETHODCALLTYPE expand_collapse_expand(IExpandCollapseProvider *iface) { return expand_collapse_to(iface, TRUE); }
static HRESULT STDMETHODCALLTYPE expand_collapse_collapse(IExpandCollapseProvider *iface) { return expand_collapse_to(iface, FALSE); }
static HRESULT STDMETHODCALLTYPE expand_collapse_state(IExpandCollapseProvider *iface, enum ExpandCollapseState *out) {
    if (!out) return E_POINTER; Provider *p = expand_collapse_self(iface); Node n;
    HRESULT hr = read_provider_node(p, &n);
    if (SUCCEEDED(hr)) *out = expand_state(&n); return hr;
}
/* Reads an item, whether its chooser allows several selected items, and
   whether another item of that chooser is selected. */
static HRESULT read_selection_item(Provider *p, Node *out, BOOL *multiple, BOOL *others) {
    State *s = p->state;
    AcquireSRWLockShared(&s->lock); Node *n = provider_find_locked(p);
    HRESULT hr = n ? S_OK : UIA_E_ELEMENTNOTAVAILABLE;
    *multiple = FALSE; *others = FALSE;
    if (n) {
        *out = *n;
        Node *owner = selection_owner(s, n);
        *multiple = owner && (owner->flags & MULTIPLE);
        for (uint32_t i = 0; i < s->count && owner; ++i)
            if (s->nodes[i].id != n->id && item_role(s->nodes[i].role) && (s->nodes[i].flags & CHECKED) && selection_owner(s, &s->nodes[i]) == owner) { *others = TRUE; break; }
    }
    ReleaseSRWLockShared(&s->lock);
    return hr;
}
static HRESULT STDMETHODCALLTYPE selection_item_select(ISelectionItemProvider *iface) {
    Provider *p = selection_item_self(iface); Node n; BOOL multiple, others;
    HRESULT hr = read_selection_item(p, &n, &multiple, &others); if (FAILED(hr)) return hr;
    if (!(n.flags & ENABLED)) return UIA_E_ELEMENTNOTENABLED;
    /* Activation selects only this item, also clearing other selected ones. */
    return (n.flags & CHECKED) && !(multiple && others) ? S_OK : request(p->state, p->id, 1, NULL, 0, 0, 0);
}
static HRESULT STDMETHODCALLTYPE selection_item_add_selection(ISelectionItemProvider *iface) {
    Provider *p = selection_item_self(iface); Node n; BOOL multiple, others;
    HRESULT hr = read_selection_item(p, &n, &multiple, &others); if (FAILED(hr)) return hr;
    if (!(n.flags & ENABLED)) return UIA_E_ELEMENTNOTENABLED;
    if (n.flags & CHECKED) return S_OK;
    /* ItemRequest add = 1 in widgets.zig. */
    if (multiple) return request(p->state, p->id, 5, NULL, 0, 0, 1);
    return others ? UIA_E_INVALIDOPERATION : request(p->state, p->id, 1, NULL, 0, 0, 0);
}
static HRESULT STDMETHODCALLTYPE selection_item_remove_selection(ISelectionItemProvider *iface) {
    Provider *p = selection_item_self(iface); Node n; BOOL multiple, others;
    HRESULT hr = read_selection_item(p, &n, &multiple, &others); if (FAILED(hr)) return hr;
    if (!(n.flags & ENABLED)) return UIA_E_ELEMENTNOTENABLED;
    if (!(n.flags & CHECKED)) return S_OK;
    /* ItemRequest deselect = 0 in widgets.zig. */
    return multiple ? request(p->state, p->id, 5, NULL, 0, 0, 0) : UIA_E_INVALIDOPERATION;
}
static HRESULT STDMETHODCALLTYPE selection_item_selected(ISelectionItemProvider *iface, WINBOOL *out) {
    if (!out) return E_POINTER; Provider *p = selection_item_self(iface); Node n;
    HRESULT hr = read_provider_node(p, &n); if (SUCCEEDED(hr)) *out = (n.flags & CHECKED) != 0; return hr;
}
static HRESULT STDMETHODCALLTYPE selection_item_container(ISelectionItemProvider *iface, IRawElementProviderSimple **out) {
    if (!out) return E_POINTER; *out = NULL;
    Provider *p = selection_item_self(iface); State *s = p->state;
    AcquireSRWLockShared(&s->lock); Node *n = provider_find_locked(p);
    Node *owner = n ? selection_owner(s, n) : NULL;
    uint64_t id = owner ? owner->id : 0;
    BOOL found = owner != NULL;
    HRESULT hr = n ? S_OK : UIA_E_ELEMENTNOTAVAILABLE;
    ReleaseSRWLockShared(&s->lock);
    if (SUCCEEDED(hr) && found) { Provider *container = NULL; hr = provider_new(s, id, &container); if (SUCCEEDED(hr)) *out = &container->simple; }
    return hr;
}
static HRESULT STDMETHODCALLTYPE selection_get(ISelectionProvider *iface, SAFEARRAY **out) {
    if (!out) return E_POINTER; *out = NULL;
    Provider *p = selection_self(iface); State *s = p->state;
    uint64_t ids[NODE_CAP]; uint32_t count = 0;
    AcquireSRWLockShared(&s->lock);
    if (!find(s, p->id)) { ReleaseSRWLockShared(&s->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    Node *self = find(s, p->id);
    for (uint32_t i = 0; i < s->count; ++i) if (item_role(s->nodes[i].role) && (s->nodes[i].flags & CHECKED) && selection_owner(s, &s->nodes[i]) == self) ids[count++] = s->nodes[i].id;
    ReleaseSRWLockShared(&s->lock);
    SAFEARRAY *array = SafeArrayCreateVector(VT_UNKNOWN, 0, count); if (!array) return E_OUTOFMEMORY;
    for (LONG i = 0; i < (LONG)count; ++i) {
        Provider *item = NULL; HRESULT hr = provider_new(s, ids[i], &item);
        if (FAILED(hr)) { SafeArrayDestroy(array); return hr; }
        hr = SafeArrayPutElement(array, &i, &item->simple); provider_release(item);
        if (FAILED(hr)) { SafeArrayDestroy(array); return hr; }
    }
    *out = array; return S_OK;
}
static HRESULT STDMETHODCALLTYPE selection_multiple(ISelectionProvider *iface, WINBOOL *out) {
    if (!out) return E_POINTER; Provider *p = selection_self(iface); Node n;
    HRESULT hr = read_provider_node(p, &n); if (SUCCEEDED(hr)) *out = (n.flags & MULTIPLE) != 0; return hr;
}
static HRESULT STDMETHODCALLTYPE selection_required(ISelectionProvider *iface, WINBOOL *out) {
    if (!out) return E_POINTER; Provider *p = selection_self(iface); Node n;
    HRESULT hr = read_provider_node(p, &n); if (SUCCEEDED(hr)) *out = FALSE; return hr;
}
static HRESULT STDMETHODCALLTYPE range_value_set(IRangeValueProvider *iface, double value) {
    Provider *p = range_value_self(iface); return request(p->state, p->id, 5, NULL, 0, 0, value);
}
static HRESULT STDMETHODCALLTYPE range_value_get(IRangeValueProvider *iface, double *out) {
    if (!out) return E_POINTER; Provider *p = range_value_self(iface); Node n;
    HRESULT hr = read_provider_node(p, &n); if (SUCCEEDED(hr)) *out = n.range_value; return hr;
}
static HRESULT STDMETHODCALLTYPE range_value_readonly(IRangeValueProvider *iface, WINBOOL *out) {
    if (!out) return E_POINTER; Provider *p = range_value_self(iface); Node n;
    HRESULT hr = read_provider_node(p, &n); if (SUCCEEDED(hr)) *out = fixed_range(n.role) || (n.flags & READ_ONLY); return hr;
}
static HRESULT range_value_metadata(IRangeValueProvider *iface, double *out, int field) {
    if (!out) return E_POINTER; Provider *p = range_value_self(iface); Node n;
    HRESULT hr = read_provider_node(p, &n);
    if (SUCCEEDED(hr)) *out = field == 0 ? n.range_minimum : field == 1 ? n.range_maximum : field == 2 ? n.range_large_change : n.range_small_change; return hr;
}
static HRESULT STDMETHODCALLTYPE range_value_min(IRangeValueProvider *iface, double *out) { return range_value_metadata(iface, out, 0); }
static HRESULT STDMETHODCALLTYPE range_value_max(IRangeValueProvider *iface, double *out) { return range_value_metadata(iface, out, 1); }
static HRESULT STDMETHODCALLTYPE range_value_large(IRangeValueProvider *iface, double *out) { return range_value_metadata(iface, out, 2); }
static HRESULT STDMETHODCALLTYPE range_value_small(IRangeValueProvider *iface, double *out) { return range_value_metadata(iface, out, 3); }

static const IRawElementProviderSimpleVtbl simple_vtable = { simple_query, simple_add, simple_release, simple_options, simple_pattern, simple_property, simple_host };
static const IRawElementProviderFragmentVtbl fragment_vtable = { fragment_query, fragment_add, fragment_release, fragment_navigate, fragment_runtime, fragment_bounds, fragment_embedded, fragment_focus, fragment_root };
static const IRawElementProviderFragmentRootVtbl root_vtable = { root_query, root_add, root_release, root_point, root_focus };
static const IInvokeProviderVtbl invoke_vtable = { invoke_query, invoke_add, invoke_release, invoke_call };
static const IValueProviderVtbl value_vtable = { value_query, value_add, value_release, value_set, value_get, value_readonly };
static const IToggleProviderVtbl toggle_vtable = { toggle_query, toggle_add, toggle_release, toggle_call, toggle_state };
static const ISelectionItemProviderVtbl selection_item_vtable = { selection_item_query, selection_item_add, selection_item_release, selection_item_select, selection_item_add_selection, selection_item_remove_selection, selection_item_selected, selection_item_container };
static const ISelectionProviderVtbl selection_vtable = { selection_query, selection_add, selection_release, selection_get, selection_multiple, selection_required };
static const IRangeValueProviderVtbl range_value_vtable = { range_value_query, range_value_add, range_value_release, range_value_set, range_value_get, range_value_readonly, range_value_max, range_value_min, range_value_large, range_value_small };
static const IExpandCollapseProviderVtbl expand_collapse_vtable = { expand_collapse_query, expand_collapse_add, expand_collapse_release, expand_collapse_expand, expand_collapse_collapse, expand_collapse_state };
static const ITextProviderVtbl text_vtable;
static void provider_initialize_locked(State *s, uint64_t id, uint32_t role, Provider *p) {
    p->simple.lpVtbl = &simple_vtable; p->fragment.lpVtbl = &fragment_vtable; p->root.lpVtbl = &root_vtable;
    p->invoke.lpVtbl = &invoke_vtable; p->value.lpVtbl = &value_vtable; p->text.lpVtbl = &text_vtable;
    p->toggle.lpVtbl = &toggle_vtable; p->selection_item.lpVtbl = &selection_item_vtable;
    p->selection.lpVtbl = &selection_vtable; p->range_value.lpVtbl = &range_value_vtable; p->expand_collapse.lpVtbl = &expand_collapse_vtable;
    p->refs = 1; p->state = s; p->id = id;
    p->patterns = patterns_for_role(role);
    p->listed = TRUE; p->next = s->providers; if (p->next) p->next->previous = p; s->providers = p;
    retain(s); InterlockedIncrement(&live_providers);
}
/* Takes ownership of nullable storage. Snapshot removal is distinguished from
   allocation failure, including between navigation's read and this creation. */
static HRESULT provider_from_storage(State *s, uint64_t id, Provider *p, Provider **out) {
    *out = NULL;
    AcquireSRWLockExclusive(&s->lock);
    Node *node = find(s, id);
    if (!node) { ReleaseSRWLockExclusive(&s->lock); free(p); return UIA_E_ELEMENTNOTAVAILABLE; }
    if (!p) { ReleaseSRWLockExclusive(&s->lock); return E_OUTOFMEMORY; }
    if (node->role == ROLE_LIST) { ReleaseSRWLockExclusive(&s->lock); free(p); return UIA_E_ELEMENTNOTAVAILABLE; }
    provider_initialize_locked(s, id, node->role, p);
    ReleaseSRWLockExclusive(&s->lock); *out = p; return S_OK;
}
static HRESULT provider_new(State *s, uint64_t id, Provider **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    AcquireSRWLockShared(&s->lock);
    const Node *node = find(s, id);
    const BOOL collection = node && node->role == ROLE_LIST;
    ReleaseSRWLockShared(&s->lock);
    if (collection) return collection_anchor_new(s, id, out);
    return provider_from_storage(s, id, calloc(1, sizeof(Provider)), out);
}
/* Narrow smoke probe: fail only this allocation, without process-global hooks. */
HRESULT zua_test_provider_status(State *s, uint64_t id, int fail_allocation) {
    Provider *p = NULL;
    HRESULT hr = provider_from_storage(s, id, fail_allocation ? NULL : calloc(1, sizeof(Provider)), &p);
    if (p) provider_release(p);
    return hr;
}

#include "accessibility_collection_provider.h"
#include "accessibility_collection_container.h"
#include "accessibility_collection_request.h"
#include "accessibility_collection_root.h"
#include "accessibility_collection_api.h"
State *zua_create(HWND hwnd, Enqueue enqueue, void *context) {
    State *s = calloc(1, sizeof(*s)); if (!s) return NULL;
    s->refs = 1; InitializeSRWLock(&s->lock); s->hwnd = hwnd; s->owner = GetCurrentThreadId(); s->enqueue = enqueue; s->context = context;
    InterlockedIncrement(&live_states);
    if (FAILED(UiaHostProviderFromHwnd(hwnd, &s->host)) || !s->host) { release(s); return NULL; }
    s->nodes[0] = (Node){ .role = ROLE_WINDOW, .flags = ENABLED }; s->count = 1;
    if (FAILED(provider_new(s, 0, &s->root))) { release(s); return NULL; }
    return s;
}
static BOOL geometry_ref_valid(const Geometry *geometry,const GeometryRef *ref,uint32_t max_clip){
    return ref->space<geometry->space_count&&(ref->clip==UINT32_MAX||ref->clip<max_clip)&&isfinite(ref->x)&&isfinite(ref->y)&&isfinite(ref->width)&&isfinite(ref->height)&&ref->width>=0&&ref->height>=0&&isfinite(ref->x+ref->width)&&isfinite(ref->y+ref->height);
}
static BOOL geometry_valid(const Geometry *geometry,uint32_t count){
    if(!geometry->space_count||geometry->space_count>SPACE_CAP||geometry->clip_count>CLIP_CAP||geometry->node_count!=count||!isfinite(geometry->origin_x)||!isfinite(geometry->origin_y)||!isfinite(geometry->scale)||geometry->scale<=0)return FALSE;
    for(uint32_t i=0;i<geometry->space_count;i++){
        const GeometrySpace *space=&geometry->spaces[i];
        if(!isfinite(space->xx)||!isfinite(space->yx)||!isfinite(space->xy)||!isfinite(space->yy)||!isfinite(space->x0)||!isfinite(space->y0))return FALSE;
    }
    for(uint32_t i=0;i<geometry->clip_count;i++){
        if(!geometry_ref_valid(geometry,&geometry->clips[i],i))return FALSE;
        uint32_t parent=geometry->clips[i].clip,depth=1;
        while(parent!=UINT32_MAX){if(++depth>CLIP_DEPTH)return FALSE;parent=geometry->clips[parent].clip;}
    }
    for(uint32_t i=0;i<count;i++)if(!geometry_ref_valid(geometry,&geometry->nodes[i],geometry->clip_count))return FALSE;
    return TRUE;
}
HRESULT zua_geometry_commit(State *s,Geometry *candidate){
    if(!candidate)return E_INVALIDARG;
    AcquireSRWLockExclusive(&s->lock);
    if(s->closed||s->geometry){HRESULT hr=s->closed?UIA_E_ELEMENTNOTAVAILABLE:E_UNEXPECTED;ReleaseSRWLockExclusive(&s->lock);return hr;}
    s->geometry=candidate;s->geometry_active=FALSE;ReleaseSRWLockExclusive(&s->lock);return S_OK;
}
void zua_geometry_release(State *s){
    AcquireSRWLockExclusive(&s->lock);Geometry *geometry=s->geometry;s->geometry=NULL;s->geometry_active=FALSE;ReleaseSRWLockExclusive(&s->lock);zua_geometry_free(geometry);
}
size_t zua_collections_metadata_size(void) { return sizeof(Collections); }
uint32_t zua_collections_count(void) { return (uint32_t)InterlockedCompareExchange(&live_collections, 0, 0); }
Collections *zua_collections_create(void) {
    Collections *candidate = calloc(1, sizeof(Collections));
    if (candidate) InterlockedIncrement(&live_collections);
    return candidate;
}
HRESULT zua_test_before_enqueue(State *s, int (*hook)(void *), void *context) {
    if (!hook || !context) return E_INVALIDARG;
    AcquireSRWLockExclusive(&s->lock);
    HRESULT hr = s->closed ? UIA_E_ELEMENTNOTAVAILABLE : !s->collections || s->collections->before_enqueue ? E_UNEXPECTED : S_OK;
    if (SUCCEEDED(hr)) { s->collections->before_enqueue = hook; s->collections->before_enqueue_context = context; }
    ReleaseSRWLockExclusive(&s->lock);
    return hr;
}
void zua_collections_free(Collections *candidate) {
    if (candidate) { collection_store_release(candidate->virtuals); free(candidate); InterlockedDecrement(&live_collections); }
}
HRESULT zua_collections_commit(State *s, Collections *candidate) {
    if (!candidate) return E_INVALIDARG;
    AcquireSRWLockExclusive(&s->lock);
    HRESULT hr = s->closed ? UIA_E_ELEMENTNOTAVAILABLE : s->collections ? E_UNEXPECTED : S_OK;
    if (SUCCEEDED(hr)) s->collections = candidate;
    ReleaseSRWLockExclusive(&s->lock);
    return hr;
}
static HRESULT publish(State *s,const Node *nodes,uint32_t count,const WCHAR *text,uint32_t length,const Geometry *geometry,const RecipientAuthority *recipients){
    if (!count || count > NODE_CAP || length > TEXT_CAP || nodes[0].id != 0) return E_INVALIDARG;
    for (uint32_t i = 0; i < count; ++i) if (nodes[i].name_start > length || nodes[i].name_len > length - nodes[i].name_start || nodes[i].value_start > length || nodes[i].value_len > length - nodes[i].value_start || nodes[i].selection_start > nodes[i].value_len || nodes[i].selection_end > nodes[i].value_len || nodes[i].description_start > length || nodes[i].description_len > length - nodes[i].description_start) return E_INVALIDARG;
    if (recipients) for (uint32_t i = 0; i < count; ++i) if (!recipient_valid(&recipients[i], nodes[i].id, nodes[i].role)) return E_INVALIDARG;
    if(geometry&&!geometry_valid(geometry,count))return E_INVALIDARG;
    AcquireSRWLockExclusive(&s->lock);
    if (s->closed) { ReleaseSRWLockExclusive(&s->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    if(geometry&&!s->geometry){ReleaseSRWLockExclusive(&s->lock);return E_UNEXPECTED;}
    if(recipients&&!s->collections){ReleaseSRWLockExclusive(&s->lock);return E_UNEXPECTED;}
    uint64_t publication = 0;
    if (s->collections && s->collections->virtuals) {
        const enum CollectionStatus status = collection_native_preflight_locked(s, nodes, count, recipients, &publication);
        if (status) { ReleaseSRWLockExclusive(&s->lock); return status == COLLECTION_STALE ? UIA_E_ELEMENTNOTAVAILABLE : E_INVALIDARG; }
        for (uint32_t index = 0; index < count; ++index) if (nodes[index].role == ROLE_LIST && !geometry) {
            ReleaseSRWLockExclusive(&s->lock); return E_INVALIDARG;
        }
    }
    /* A status message absent from the previous tree announces itself once. */
    uint64_t announce[8]; uint32_t announced = 0;
    for (uint32_t i = 0; i < count && announced < 8; ++i) if (nodes[i].role == ROLE_STATUS) {
        BOOL seen = FALSE;
        for (uint32_t j = 0; j < s->count; ++j) if (s->nodes[j].id == nodes[i].id && s->nodes[j].role == ROLE_STATUS) { seen = TRUE; break; }
        if (!seen) announce[announced++] = nodes[i].id;
    }
    memcpy(s->nodes, nodes, count * sizeof(Node)); memcpy(s->text, text, length * sizeof(WCHAR)); s->count = count; s->text_len = length;
    if(geometry)memcpy(s->geometry,geometry,sizeof(*geometry));s->geometry_active=geometry!=NULL;
    if (s->collections) {
        memset(s->collections->front, 0, sizeof(s->collections->front));
        if (recipients) memcpy(s->collections->front, recipients, count * sizeof(*recipients));
        if (s->collections->virtuals) collection_store_commit(s->collections->virtuals, s->collections->virtuals->frame, publication);
    }
    ReleaseSRWLockExclusive(&s->lock);
    /* Raised after the new tree is visible and outside the lock, because
       UI Automation may read the provider back synchronously. */
    for (uint32_t i = 0; i < announced && UiaClientsAreListening(); ++i) {
        Provider *p = NULL;
        if (SUCCEEDED(provider_new(s, announce[i], &p))) { UiaRaiseAutomationEvent(&p->simple, UIA_LiveRegionChangedEventId); provider_release(p); }
    }
    return S_OK;
}
HRESULT zua_publish(State *s,const Node *nodes,uint32_t count,const WCHAR *text,uint32_t length){return publish(s,nodes,count,text,length,NULL,NULL);}
HRESULT zua_publish_geometry(State *s,const Node *nodes,uint32_t count,const WCHAR *text,uint32_t length,const Geometry *geometry){if(!geometry)return E_INVALIDARG;return publish(s,nodes,count,text,length,geometry,NULL);}
HRESULT zua_publish_registered(State *s,const Node *nodes,uint32_t count,const WCHAR *text,uint32_t length,const RecipientAuthority *recipients){if(!recipients)return E_INVALIDARG;return publish(s,nodes,count,text,length,NULL,recipients);}
HRESULT zua_publish_geometry_registered(State *s,const Node *nodes,uint32_t count,const WCHAR *text,uint32_t length,const Geometry *geometry,const RecipientAuthority *recipients){if(!geometry||!recipients)return E_INVALIDARG;return publish(s,nodes,count,text,length,geometry,recipients);}
HRESULT zua_position_changed(State *s,double dx,double dy){
    if(!isfinite(dx)||!isfinite(dy))return E_INVALIDARG;
    AcquireSRWLockExclusive(&s->lock);if(s->closed){ReleaseSRWLockExclusive(&s->lock);return UIA_E_ELEMENTNOTAVAILABLE;}
    for(uint32_t i=0;i<s->count;i++)if(!isfinite(s->nodes[i].x+dx)||!isfinite(s->nodes[i].y+dy)){ReleaseSRWLockExclusive(&s->lock);return E_INVALIDARG;}
    if(s->geometry_active&&(!isfinite(s->geometry->origin_x+dx)||!isfinite(s->geometry->origin_y+dy))){ReleaseSRWLockExclusive(&s->lock);return E_INVALIDARG;}
    for(uint32_t i=0;i<s->count;i++){s->nodes[i].x+=dx;s->nodes[i].y+=dy;}
    if(s->geometry_active){s->geometry->origin_x+=dx;s->geometry->origin_y+=dy;}
    ReleaseSRWLockExclusive(&s->lock);return S_OK;
}
LRESULT zua_get_object(State *s, WPARAM wp, LPARAM lp) {
    if (lp != UiaRootObjectId) return 0;
    AcquireSRWLockShared(&s->lock);
    Provider *root = s->closed ? NULL : s->root;
    if (root) provider_add(root);
    ReleaseSRWLockShared(&s->lock);
    if (!root) return 0;
    LRESULT result = UiaReturnRawElementProvider(s->hwnd, wp, lp, &root->simple);
    provider_release(root);
    return result;
}
void *zua_retain_provider(State *s, uint64_t id) {
    AcquireSRWLockShared(&s->lock);
    Node *n = find(s, id);
    if (!n) { ReleaseSRWLockShared(&s->lock); return NULL; }
    if (id == 0) { provider_add(s->root); Provider *p = s->root; ReleaseSRWLockShared(&s->lock); return &p->simple; }
    ReleaseSRWLockShared(&s->lock);
    Provider *p = NULL; HRESULT hr = provider_new(s, id, &p); return SUCCEEDED(hr) ? &p->simple : NULL;
}
void zua_begin_close(State *s) {
    AcquireSRWLockExclusive(&s->lock);
    if (s->closed) { ReleaseSRWLockExclusive(&s->lock); return; }
    s->closed = TRUE; s->context = NULL;
    Geometry *geometry=s->geometry;s->geometry=NULL;s->geometry_active=FALSE;
    /* The owner cleanup runs later. Pin the whole list before client threads
       can drop its nodes, without making an outbound COM call while locked. */
    for (Provider *p = s->providers; p; p = p->next) provider_add(p);
    collection_begin_close_locked(s);
    ReleaseSRWLockExclusive(&s->lock);zua_geometry_free(geometry);
}
HRESULT zua_disconnect(State *s) {
    HRESULT result = collection_disconnect_rows(s);
    /* Every fragment can have its own UI Automation connection. Disconnecting
       only the root leaves cached child pattern connections in the client. */
    for (;;) {
        AcquireSRWLockExclusive(&s->lock);
        Provider *p = s->providers;
        if (p) unlink_provider(s, p);
        ReleaseSRWLockExclusive(&s->lock);
        if (!p) break;
        HRESULT hr = UiaDisconnectProvider(&p->simple);
        if (FAILED(hr) && SUCCEEDED(result)) result = hr;
        provider_release(p);
    }
    AcquireSRWLockExclusive(&s->lock);
    Provider *root = s->root; s->root = NULL;
    ReleaseSRWLockExclusive(&s->lock);
    provider_release(root); release(s);
    return result;
}

/* Text ranges use UTF-16 offsets at scalar boundaries. Geometry, formatting,
   bidi navigation and grapheme segmentation are not synthesized from bounds. */
static ULONG STDMETHODCALLTYPE range_add(ITextRangeProvider *iface) { return InterlockedIncrement(&((Range *)iface)->refs); }
static ULONG STDMETHODCALLTYPE range_release(ITextRangeProvider *iface) {
    Range *r = (Range *)iface; LONG refs = InterlockedDecrement(&r->refs);
    if (!refs) { release(r->state); free(r); InterlockedDecrement(&live_ranges); } return refs;
}
static HRESULT STDMETHODCALLTYPE range_query(ITextRangeProvider *iface, REFIID iid, void **out) {
    if (!out) return E_POINTER; *out = NULL;
    if (!IsEqualIID(iid, &IID_IUnknown) && !IsEqualIID(iid, &IID_ITextRangeProvider)) return E_NOINTERFACE;
    *out = iface; range_add(iface); return S_OK;
}
static uint32_t previous_scalar(const WCHAR *text, uint32_t position) {
    if (!position) return 0; --position;
    if (position && text[position] >= 0xdc00 && text[position] <= 0xdfff && text[position - 1] >= 0xd800 && text[position - 1] <= 0xdbff) --position;
    return position;
}
static uint32_t next_scalar(const WCHAR *text, uint32_t length, uint32_t position) {
    if (position >= length) return length;
    if (text[position] >= 0xd800 && text[position] <= 0xdbff && position + 1 < length && text[position + 1] >= 0xdc00 && text[position + 1] <= 0xdfff) return position + 2;
    return position + 1;
}
static void clamp_range(Range *r, Node *n, const WCHAR *text) {
    if (r->start > n->value_len) r->start = n->value_len;
    if (r->end > n->value_len) r->end = n->value_len;
    if (r->start && r->start < n->value_len && text[r->start] >= 0xdc00 && text[r->start] <= 0xdfff) --r->start;
    if (r->end && r->end < n->value_len && text[r->end] >= 0xdc00 && text[r->end] <= 0xdfff) --r->end;
    if (r->start > r->end) r->end = r->start;
}
static Node *range_lock(Range *r) {
    AcquireSRWLockExclusive(&r->state->lock);
    Node *n = find(r->state, r->id);
    if (!n) { ReleaseSRWLockExclusive(&r->state->lock); return NULL; }
    clamp_range(r, n, r->state->text + n->value_start); return n;
}
static void range_unlock(Range *r) { ReleaseSRWLockExclusive(&r->state->lock); }
static Range *range_new(State *s, uint64_t id, uint32_t start, uint32_t end) {
    Range *r = calloc(1, sizeof(*r)); if (!r) return NULL;
    r->iface.lpVtbl = &range_vtable; r->refs = 1; r->state = s; r->id = id;
    r->start = start < end ? start : end; r->end = start < end ? end : start;
    retain(s); InterlockedIncrement(&live_ranges); return r;
}
static HRESULT array_range(State *s, uint64_t id, uint32_t start, uint32_t end, SAFEARRAY **out) {
    SAFEARRAY *array = SafeArrayCreateVector(VT_UNKNOWN, 0, 1); if (!array) return E_OUTOFMEMORY;
    Range *range = range_new(s, id, start, end); if (!range) { SafeArrayDestroy(array); return E_OUTOFMEMORY; }
    LONG index = 0; HRESULT hr = SafeArrayPutElement(array, &index, &range->iface); range_release(&range->iface);
    if (FAILED(hr)) { SafeArrayDestroy(array); return hr; }
    *out = array; return S_OK;
}
static HRESULT STDMETHODCALLTYPE text_selection(ITextProvider *iface, SAFEARRAY **out) {
    if (!out) return E_POINTER; *out = NULL; Provider *p = text_self(iface); Node n;
    HRESULT hr = read_provider_node(p, &n); if (FAILED(hr)) return hr;
    return array_range(p->state, p->id, n.selection_start, n.selection_end, out);
}
static HRESULT STDMETHODCALLTYPE text_visible(ITextProvider *iface, SAFEARRAY **out) {
    if (!out) return E_POINTER; *out = NULL; Provider *p = text_self(iface); Node n;
    HRESULT hr = read_provider_node(p, &n); return FAILED(hr) ? hr : E_NOTIMPL;
}
static HRESULT STDMETHODCALLTYPE text_child(ITextProvider *iface, IRawElementProviderSimple *child, ITextRangeProvider **out) {
    (void)child; if (!out) return E_POINTER; *out = NULL; Provider *p = text_self(iface); Node n;
    HRESULT hr = read_provider_node(p, &n); return FAILED(hr) ? hr : E_INVALIDARG;
}
static HRESULT STDMETHODCALLTYPE text_point(ITextProvider *iface, struct UiaPoint point, ITextRangeProvider **out) {
    (void)point; if (!out) return E_POINTER; *out = NULL; Provider *p = text_self(iface); Node n;
    HRESULT hr = read_provider_node(p, &n); return FAILED(hr) ? hr : E_NOTIMPL;
}
static HRESULT STDMETHODCALLTYPE text_document(ITextProvider *iface, ITextRangeProvider **out) {
    if (!out) return E_POINTER; *out = NULL; Provider *p = text_self(iface); Node n;
    HRESULT hr = read_provider_node(p, &n); if (FAILED(hr)) return hr;
    Range *range = range_new(p->state, p->id, 0, n.value_len); if (!range) return E_OUTOFMEMORY;
    *out = &range->iface; return S_OK;
}
static HRESULT STDMETHODCALLTYPE text_supported(ITextProvider *iface, enum SupportedTextSelection *out) {
    if (!out) return E_POINTER; Provider *p = text_self(iface); Node n;
    HRESULT hr = read_provider_node(p, &n); if (SUCCEEDED(hr)) *out = SupportedTextSelection_Single; return hr;
}
static const ITextProviderVtbl text_vtable = { text_query, text_add, text_release, text_selection, text_visible, text_child, text_point, text_document, text_supported };

static HRESULT STDMETHODCALLTYPE range_clone(ITextRangeProvider *iface, ITextRangeProvider **out) {
    if (!out) return E_POINTER; *out = NULL; Range *r = (Range *)iface;
    if (!range_lock(r)) return UIA_E_ELEMENTNOTAVAILABLE;
    Range *copy = range_new(r->state, r->id, r->start, r->end); range_unlock(r);
    if (!copy) return E_OUTOFMEMORY; *out = &copy->iface; return S_OK;
}
static Range *compatible_range(Range *r, ITextRangeProvider *iface) {
    if (!iface || iface->lpVtbl != &range_vtable) return NULL;
    Range *other = (Range *)iface;
    return r->state == other->state && r->id == other->id ? other : NULL;
}
static HRESULT STDMETHODCALLTYPE range_compare(ITextRangeProvider *iface, ITextRangeProvider *other_iface, WINBOOL *out) {
    if (!out) return E_POINTER; Range *r = (Range *)iface; Range *other = compatible_range(r, other_iface);
    if (!other) { *out = FALSE; return S_OK; }
    Node *n = range_lock(r); if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
    clamp_range(other, n, r->state->text + n->value_start);
    *out = r->start == other->start && r->end == other->end; range_unlock(r); return S_OK;
}
static HRESULT STDMETHODCALLTYPE range_compare_endpoints(ITextRangeProvider *iface, enum TextPatternRangeEndpoint endpoint, ITextRangeProvider *other_iface, enum TextPatternRangeEndpoint other_endpoint, int *out) {
    if (!out) return E_POINTER; Range *r = (Range *)iface; Range *other = compatible_range(r, other_iface); if (!other) return E_INVALIDARG;
    Node *n = range_lock(r); if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
    clamp_range(other, n, r->state->text + n->value_start);
    *out = (int)(endpoint == TextPatternRangeEndpoint_Start ? r->start : r->end) - (int)(other_endpoint == TextPatternRangeEndpoint_Start ? other->start : other->end);
    range_unlock(r); return S_OK;
}
static BOOL whitespace(WCHAR value) { return value == L' ' || value == L'\t' || value == L'\r' || value == L'\n'; }
static uint32_t step_unit(const WCHAR *text, uint32_t length, uint32_t position, enum TextUnit unit, BOOL backward) {
    if (unit == TextUnit_Character) return backward ? previous_scalar(text, position) : next_scalar(text, length, position);
    if (unit == TextUnit_Document || unit == TextUnit_Page || unit == TextUnit_Format) return backward ? 0 : length;
    if (unit == TextUnit_Word) {
        if (backward) {
            while (position && whitespace(text[previous_scalar(text, position)])) position = previous_scalar(text, position);
            while (position && !whitespace(text[previous_scalar(text, position)])) position = previous_scalar(text, position);
        } else {
            while (position < length && !whitespace(text[position])) position = next_scalar(text, length, position);
            while (position < length && whitespace(text[position])) position = next_scalar(text, length, position);
        }
        return position;
    }
    if (backward) {
        if (position) position = previous_scalar(text, position);
        while (position && text[position - 1] != L'\n') position = previous_scalar(text, position);
    } else {
        while (position < length && text[position] != L'\n') position = next_scalar(text, length, position);
        if (position < length) ++position;
    }
    return position;
}
static void expand_unit(Range *r, const WCHAR *text, uint32_t length, enum TextUnit unit) {
    if (unit == TextUnit_Document || unit == TextUnit_Page || unit == TextUnit_Format) { r->start = 0; r->end = length; return; }
    if (unit == TextUnit_Character) { r->end = next_scalar(text, length, r->start); return; }
    if (unit == TextUnit_Word) {
        if (r->start == length && length) r->start = previous_scalar(text, length);
        BOOL space = r->start < length && whitespace(text[r->start]);
        while (r->start && whitespace(text[previous_scalar(text, r->start)]) == space) r->start = previous_scalar(text, r->start);
        r->end = r->start; while (r->end < length && whitespace(text[r->end]) == space) r->end = next_scalar(text, length, r->end);
        return;
    }
    while (r->start && text[r->start - 1] != L'\n') r->start = previous_scalar(text, r->start);
    r->end = r->start; while (r->end < length && text[r->end] != L'\n') r->end = next_scalar(text, length, r->end);
    if (r->end < length) ++r->end;
}
static HRESULT STDMETHODCALLTYPE range_expand(ITextRangeProvider *iface, enum TextUnit unit) {
    Range *r = (Range *)iface; Node *n = range_lock(r); if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
    expand_unit(r, r->state->text + n->value_start, n->value_len, unit); range_unlock(r); return S_OK;
}
static HRESULT STDMETHODCALLTYPE range_find_attribute(ITextRangeProvider *iface, TEXTATTRIBUTEID attribute, VARIANT value, WINBOOL backward, ITextRangeProvider **out) {
    (void)backward; if (!out) return E_POINTER; *out = NULL; Range *r = (Range *)iface;
    Node *n = range_lock(r); if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
    Range *found = NULL;
    if (attribute == UIA_IsReadOnlyAttributeId && value.vt == VT_BOOL && ((value.boolVal != VARIANT_FALSE) == ((n->flags & READ_ONLY) != 0))) found = range_new(r->state, r->id, r->start, r->end);
    range_unlock(r); if (found) *out = &found->iface; return S_OK;
}
static HRESULT STDMETHODCALLTYPE range_find_text(ITextRangeProvider *iface, BSTR needle, WINBOOL backward, WINBOOL ignore_case, ITextRangeProvider **out) {
    if (!out) return E_POINTER; *out = NULL; Range *r = (Range *)iface; uint32_t needle_len = SysStringLen(needle);
    Node *n = range_lock(r); if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
    const WCHAR *value = r->state->text + n->value_start;
    Range *found = NULL;
    if (needle_len <= r->end - r->start) {
        uint32_t last = r->end - needle_len;
        for (uint32_t step = 0; step <= last - r->start; ++step) {
            uint32_t start = backward ? last - step : r->start + step;
            if (start && start < n->value_len && value[start] >= 0xdc00 && value[start] <= 0xdfff) continue;
            if (!needle_len || CompareStringOrdinal(value + start, (int)needle_len, needle, (int)needle_len, ignore_case) == CSTR_EQUAL) { found = range_new(r->state, r->id, start, start + needle_len); break; }
        }
    }
    range_unlock(r); if (found) *out = &found->iface; return S_OK;
}
static HRESULT STDMETHODCALLTYPE range_attribute(ITextRangeProvider *iface, TEXTATTRIBUTEID attribute, VARIANT *out) {
    if (!out) return E_POINTER; VariantInit(out); Range *r = (Range *)iface; Node *n = range_lock(r); if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
    if (attribute == UIA_IsReadOnlyAttributeId) { out->vt = VT_BOOL; out->boolVal = n->flags & READ_ONLY ? VARIANT_TRUE : VARIANT_FALSE; range_unlock(r); return S_OK; }
    range_unlock(r); out->vt = VT_UNKNOWN; return UiaGetReservedNotSupportedValue(&out->punkVal);
}
static HRESULT STDMETHODCALLTYPE range_rectangles(ITextRangeProvider *iface, SAFEARRAY **out) {
    if (!out) return E_POINTER; *out = NULL; Range *r = (Range *)iface;
    if (!range_lock(r)) return UIA_E_ELEMENTNOTAVAILABLE; range_unlock(r); return E_NOTIMPL;
}
static HRESULT STDMETHODCALLTYPE range_element(ITextRangeProvider *iface, IRawElementProviderSimple **out) {
    if (!out) return E_POINTER; *out = NULL; Range *r = (Range *)iface;
    if (!range_lock(r)) return UIA_E_ELEMENTNOTAVAILABLE; range_unlock(r);
    Provider *p = NULL; HRESULT hr = provider_new(r->state, r->id, &p); if (FAILED(hr)) return hr; *out = &p->simple; return S_OK;
}
static HRESULT STDMETHODCALLTYPE range_text(ITextRangeProvider *iface, int maximum, BSTR *out) {
    if (!out) return E_POINTER; *out = NULL; Range *r = (Range *)iface; Node *n = range_lock(r); if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
    const WCHAR *value = r->state->text + n->value_start;
    uint32_t length = r->end - r->start;
    if (maximum >= 0 && (uint32_t)maximum < length) length = (uint32_t)maximum;
    uint32_t end = r->start + length;
    if (length && end < n->value_len && value[end] >= 0xdc00 && value[end] <= 0xdfff) --length;
    *out = SysAllocStringLen(value + r->start, length); range_unlock(r); return *out ? S_OK : E_OUTOFMEMORY;
}
static HRESULT STDMETHODCALLTYPE range_move(ITextRangeProvider *iface, enum TextUnit unit, int count, int *out) {
    if (!out) return E_POINTER; *out = 0; Range *r = (Range *)iface; Node *n = range_lock(r); if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
    const WCHAR *value = r->state->text + n->value_start; BOOL degenerate = r->start == r->end, backward = count < 0;
    uint64_t remaining = backward ? (uint64_t)-(int64_t)count : (uint64_t)count;
    while (remaining--) { uint32_t next = step_unit(value, n->value_len, r->start, unit, backward); if (next == r->start) break; r->start = next; *out += backward ? -1 : 1; }
    r->end = r->start; if (!degenerate) expand_unit(r, value, n->value_len, unit);
    range_unlock(r); return S_OK;
}
static HRESULT STDMETHODCALLTYPE range_move_endpoint(ITextRangeProvider *iface, enum TextPatternRangeEndpoint endpoint, enum TextUnit unit, int count, int *out) {
    if (!out) return E_POINTER; *out = 0; Range *r = (Range *)iface; Node *n = range_lock(r); if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
    const WCHAR *value = r->state->text + n->value_start; BOOL backward = count < 0;
    uint32_t *position = endpoint == TextPatternRangeEndpoint_Start ? &r->start : &r->end;
    uint64_t remaining = backward ? (uint64_t)-(int64_t)count : (uint64_t)count;
    while (remaining--) { uint32_t next = step_unit(value, n->value_len, *position, unit, backward); if (next == *position) break; *position = next; *out += backward ? -1 : 1; }
    if (r->start > r->end) { if (endpoint == TextPatternRangeEndpoint_Start) r->end = r->start; else r->start = r->end; }
    range_unlock(r); return S_OK;
}
static HRESULT STDMETHODCALLTYPE range_move_endpoint_range(ITextRangeProvider *iface, enum TextPatternRangeEndpoint endpoint, ITextRangeProvider *other_iface, enum TextPatternRangeEndpoint other_endpoint) {
    Range *r = (Range *)iface; Range *other = compatible_range(r, other_iface); if (!other) return E_INVALIDARG;
    Node *n = range_lock(r); if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
    clamp_range(other, n, r->state->text + n->value_start);
    uint32_t position = other_endpoint == TextPatternRangeEndpoint_Start ? other->start : other->end;
    if (endpoint == TextPatternRangeEndpoint_Start) { r->start = position; if (r->end < position) r->end = position; }
    else { r->end = position; if (r->start > position) r->start = position; }
    range_unlock(r); return S_OK;
}
static HRESULT STDMETHODCALLTYPE range_select(ITextRangeProvider *iface) {
    Range *r = (Range *)iface; if (!range_lock(r)) return UIA_E_ELEMENTNOTAVAILABLE;
    uint32_t start = r->start, end = r->end; range_unlock(r); return request(r->state, r->id, 4, NULL, start, end, 0);
}
static HRESULT STDMETHODCALLTYPE range_add_selection(ITextRangeProvider *iface) { Range *r = (Range *)iface; if (!range_lock(r)) return UIA_E_ELEMENTNOTAVAILABLE; range_unlock(r); return UIA_E_INVALIDOPERATION; }
static HRESULT STDMETHODCALLTYPE range_remove_selection(ITextRangeProvider *iface) { return range_add_selection(iface); }
static HRESULT STDMETHODCALLTYPE range_scroll(ITextRangeProvider *iface, WINBOOL top) { (void)top; Range *r = (Range *)iface; if (!range_lock(r)) return UIA_E_ELEMENTNOTAVAILABLE; range_unlock(r); return E_NOTIMPL; }
static HRESULT STDMETHODCALLTYPE range_children(ITextRangeProvider *iface, SAFEARRAY **out) {
    if (!out) return E_POINTER; *out = NULL; Range *r = (Range *)iface; if (!range_lock(r)) return UIA_E_ELEMENTNOTAVAILABLE; range_unlock(r);
    *out = SafeArrayCreateVector(VT_UNKNOWN, 0, 0); return *out ? S_OK : E_OUTOFMEMORY;
}
static const ITextRangeProviderVtbl range_vtable = {
    range_query, range_add, range_release, range_clone, range_compare, range_compare_endpoints,
    range_expand, range_find_attribute, range_find_text, range_attribute, range_rectangles,
    range_element, range_text, range_move, range_move_endpoint, range_move_endpoint_range,
    range_select, range_add_selection, range_remove_selection, range_scroll, range_children
};

_Static_assert(sizeof(CollectionProvider) == 128, "native collection provider payload ABI");
IRawElementProviderSimple *zua_collection_retain_provider(State *state, const CollectionRegistration *key, uint64_t row, uint64_t incarnation) {
    if (!state || !key) return NULL;
    CollectionProvider *provider = NULL;
    return SUCCEEDED(collection_provider_new(state, *key, row, incarnation, &provider)) ? &provider->simple : NULL;
}
uint32_t zua_collection_provider_count(void) { return (uint32_t)InterlockedCompareExchange(&live_collection_providers, 0, 0); }
_Static_assert(sizeof(CollectionContainer) == 64, "native collection container payload ABI");
HRESULT zua_collection_container_pattern(State *state, uint64_t id, REFIID iid, void **out) {
    Provider *owner = NULL;
    HRESULT hr = provider_new(state, id, &owner);
    if (FAILED(hr)) return hr;
    hr = collection_container_new(owner, iid, out);
    provider_release(owner);
    return hr;
}
