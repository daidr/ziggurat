#define INITGUID
#include "native_internal.h"
_Static_assert(sizeof(void *) != 8 || (sizeof(ZdaActionView)==56 && offsetof(ZdaActionView,presentation_epoch)==24), "presentation action ABI");
_Static_assert(sizeof(ZdaAuxKey)==32 && sizeof(ZdaAuxNode)==56 && sizeof(ZdaAuxGeometry)==40, "auxiliary semantic ABI");
_Static_assert(sizeof(ZdaAuxAccepted)==104, "accepted auxiliary ABI");
_Static_assert(sizeof(void *)!=8 || sizeof(ZdaAuxAction)==104, "auxiliary action ABI");
#include "native_mapping.h"
#include <string.h>
#include <math.h>
#include <assert.h>
#include <limits.h>
#include <stdlib.h>

#define ROOT_SOURCE UINT32_MAX
#define AUX_SOURCE (UINT32_MAX-1)
typedef struct ZdaRange ZdaRange;
struct ZdaProvider {
    IUnknown identity;
    IRawElementProviderSimple simple;
    IRawElementProviderFragment fragment;
    IRawElementProviderFragmentRoot root;
    ITextProvider text;
    ITextProvider2 text2;
    IInvokeProvider invoke;
    IExpandCollapseProvider expand;
    volatile LONG refs;
    ZdaNative *state;
    uint32_t source;
    BOOL is_root;
    ZdaAuxKey key;
};
struct ZdaRange {
    ITextRangeProvider iface;
    IUnknown identity;
    volatile LONG refs;
    ZdaNative *state;
    uint64_t version;
    uint32_t source, start, end;
};
static const IRawElementProviderSimpleVtbl simple_vtable;
static const IUnknownVtbl unknown_vtable;
static const IRawElementProviderFragmentVtbl fragment_vtable;
static const IRawElementProviderFragmentRootVtbl root_vtable;
static const ITextProviderVtbl text_vtable;
static const ITextProvider2Vtbl text2_vtable;
static const ITextRangeProviderVtbl range_vtable;
static const IInvokeProviderVtbl invoke_vtable;
static const IExpandCollapseProviderVtbl expand_vtable;
static int auxiliary_index(ZdaNative *, const ZdaAuxKey *);
static HRESULT auxiliary_property(ZdaProvider *, PROPERTYID, VARIANT *);
static HRESULT auxiliary_bounds(ZdaProvider *, struct UiaRect *, BOOL *);
static HRESULT auxiliary_navigate(ZdaProvider *, enum NavigateDirection, IRawElementProviderFragment **);
static HRESULT auxiliary_request(ZdaProvider *, uint32_t);
static HRESULT create_range(ZdaNative *, uint32_t, uint64_t, uint32_t, uint32_t, ZdaRange **);
static HRESULT request(ZdaProvider *, uint32_t, uint32_t, uint32_t, uint32_t);
static ZdaProvider *simple_self(IRawElementProviderSimple *p) { return (ZdaProvider *)((char *)p - offsetof(ZdaProvider, simple)); }
static ZdaProvider *unknown_self(IUnknown *p) { return (ZdaProvider *)((char *)p - offsetof(ZdaProvider, identity)); }
static ZdaProvider *fragment_self(IRawElementProviderFragment *p) { return (ZdaProvider *)((char *)p - offsetof(ZdaProvider, fragment)); }
static ZdaProvider *root_self(IRawElementProviderFragmentRoot *p) { return (ZdaProvider *)((char *)p - offsetof(ZdaProvider, root)); }
static ZdaProvider *text_self(ITextProvider *p) { return (ZdaProvider *)((char *)p - offsetof(ZdaProvider, text)); }
static ZdaProvider *text2_self(ITextProvider2 *p) { return (ZdaProvider *)((char *)p - offsetof(ZdaProvider, text2)); }
static HRESULT status(int value) {
    return value == ZDA_OK ? S_OK : value == ZDA_CLOSED ? UIA_E_ELEMENTNOTAVAILABLE : value == ZDA_CAPACITY ? HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA) : value == ZDA_OOM ? E_OUTOFMEMORY : E_INVALIDARG;
}
static ULONG provider_add(ZdaProvider *p) { return (ULONG)InterlockedIncrement(&p->refs); }
static ULONG provider_release(ZdaProvider *p) {
    LONG refs = InterlockedDecrement(&p->refs);
    if (!refs) { ZdaNative *state = p->state; zda_storage_release(p); zda_store_release(state); }
    return (ULONG)refs;
}
static BOOL group(ZdaProvider *p) { return p->source == ROOT_SOURCE; }
static BOOL auxiliary(ZdaProvider *p) { return p->source == AUX_SOURCE; }
static HRESULT alive(ZdaProvider *p) {
    AcquireSRWLockShared(&p->state->lock);
    BOOL closed = p->state->closed || (auxiliary(p) && auxiliary_index(p->state,&p->key)<0);
    ReleaseSRWLockShared(&p->state->lock); return closed ? UIA_E_ELEMENTNOTAVAILABLE : S_OK;
}
static HRESULT provider_query(ZdaProvider *p, REFIID iid, void **out) {
    if (!out) return E_POINTER; *out = NULL;
    if (IsEqualIID(iid, &IID_IUnknown)) *out = &p->identity;
    else if (IsEqualIID(iid, &IID_IRawElementProviderSimple)) *out = &p->simple;
    else if (IsEqualIID(iid, &IID_IRawElementProviderFragment)) *out = &p->fragment;
    else if (p->is_root && IsEqualIID(iid, &IID_IRawElementProviderFragmentRoot)) *out = &p->root;
    else if (!group(p) && !auxiliary(p) && IsEqualIID(iid, &IID_ITextProvider)) *out = &p->text;
    else if (!group(p) && !auxiliary(p) && IsEqualIID(iid, &IID_ITextProvider2)) *out = &p->text2;
    else if (auxiliary(p) && p->key.kind==1 && IsEqualIID(iid,&IID_IInvokeProvider)) *out=&p->invoke;
    else if (auxiliary(p) && p->key.kind==2 && IsEqualIID(iid,&IID_IExpandCollapseProvider)) *out=&p->expand;
    if (!*out) return E_NOINTERFACE; provider_add(p); return S_OK;
}
#define ADAPTER(prefix, type, self) \
static HRESULT STDMETHODCALLTYPE prefix##_query(type *p, REFIID iid, void **out) { return provider_query(self(p), iid, out); } \
static ULONG STDMETHODCALLTYPE prefix##_add(type *p) { return provider_add(self(p)); } \
static ULONG STDMETHODCALLTYPE prefix##_release(type *p) { return provider_release(self(p)); }
ADAPTER(simple, IRawElementProviderSimple, simple_self)
ADAPTER(unknown, IUnknown, unknown_self)
ADAPTER(fragment, IRawElementProviderFragment, fragment_self)
ADAPTER(root, IRawElementProviderFragmentRoot, root_self)
ADAPTER(text, ITextProvider, text_self)
ADAPTER(text2, ITextProvider2, text2_self)
#undef ADAPTER
static const IUnknownVtbl unknown_vtable = { unknown_query, unknown_add, unknown_release };
static HRESULT create_provider(ZdaNative *state, uint32_t source, ZdaProvider **out) {
    ZdaProvider *p = NULL;
    int result = zda_storage_create(state->account, ZDA_PROVIDER, sizeof(*p), (void **)&p);
    if (result != ZDA_OK) return status(result);
    memset(p, 0, sizeof(*p)); p->refs = 1; p->state = state; p->source = source;
    p->identity.lpVtbl = &unknown_vtable; p->simple.lpVtbl = &simple_vtable; p->fragment.lpVtbl = &fragment_vtable;
    p->root.lpVtbl = &root_vtable; p->text.lpVtbl = &text_vtable; p->text2.lpVtbl = &text2_vtable;
    p->invoke.lpVtbl=&invoke_vtable;p->expand.lpVtbl=&expand_vtable;
    zda_store_retain(state); *out = p; return S_OK;
}
static HRESULT STDMETHODCALLTYPE simple_options(IRawElementProviderSimple *iface, enum ProviderOptions *out) {
    (void)iface; if (!out) return E_POINTER;
    *out = ProviderOptions_ServerSideProvider | ProviderOptions_UseComThreading; return S_OK;
}
static HRESULT STDMETHODCALLTYPE simple_pattern(IRawElementProviderSimple *iface, PATTERNID id, IUnknown **out) {
    if (!out) return E_POINTER; *out = NULL; ZdaProvider *p = simple_self(iface);
    HRESULT hr = alive(p); if (FAILED(hr)) return hr;
    if(auxiliary(p)) {
        if((id==UIA_InvokePatternId&&p->key.kind==1)||(id==UIA_ExpandCollapsePatternId&&p->key.kind==2)){*out=&p->identity;provider_add(p);}
        return S_OK;
    }
    if ((id == UIA_TextPatternId || id == UIA_TextPattern2Id) && !group(p)) {
        ZdaText *current = NULL; hr = zda_acquire(p->state, p->source, UINT64_MAX, &current, NULL, NULL);
        if (SUCCEEDED(hr)) { zda_text_release(current); *out = &p->identity; provider_add(p); }
    }
    return S_OK;
}
static uint32_t geometry_piece_count(ZdaNative *state, ZdaGeometry *geometry) {
    if (!geometry || (!geometry->count && !geometry->line_count)) return 0;
    /* A single Document is a viewport control. A multi-source group retains
       actual visible row regions so filtered ghosts cannot cover the peer. */
    return state->count == 1 ? 1 : geometry->line_count ? geometry->line_count : geometry->count;
}
static ZdaRect geometry_piece(ZdaNative *state, ZdaGeometry *geometry, uint32_t at) {
    return state->count == 1 ? geometry->bounds : geometry->line_count ? geometry->lines[at].rectangle : geometry->cells[at].rectangle;
}
typedef struct GeometrySnapshot {
    ZdaGeometry *geometry[ZDA_SOURCES];
    uintptr_t text_identity[ZDA_SOURCES],geometry_identity[ZDA_SOURCES];
    ZdaMapped mapping[ZDA_SOURCES];
    double x,y,scale;
    uint64_t serial;
    ZdaRect auxiliary_bounds;
    BOOL has_auxiliary_bounds;
} GeometrySnapshot;
static HRESULT geometry_snapshot(ZdaNative *state, GeometrySnapshot *out) {
    AcquireSRWLockShared(&state->lock);
    if (state->closed) {ReleaseSRWLockShared(&state->lock);return UIA_E_ELEMENTNOTAVAILABLE;}
    out->x=state->screen_x;out->y=state->screen_y;out->scale=state->screen_scale;out->serial=state->geometry_serial;out->has_auxiliary_bounds=FALSE;
    if(state->auxiliary)for(uint32_t i=0;i<state->auxiliary->count;++i){
        const ZdaAuxGeometry*g=&state->auxiliary->geometry[i];ZdaRect local;if(!zda_auxiliary_rectangle(state->auxiliary,g,&local))continue;
        ZdaRect r={out->x+local.x*state->auxiliary->scale,out->y+local.y*state->auxiliary->scale,local.width*state->auxiliary->scale,local.height*state->auxiliary->scale};
        if(!out->has_auxiliary_bounds){out->auxiliary_bounds=r;out->has_auxiliary_bounds=TRUE;}else{ZdaRect*previous=&out->auxiliary_bounds;double right=fmax(previous->x+previous->width,r.x+r.width),bottom=fmax(previous->y+previous->height,r.y+r.height);previous->x=fmin(previous->x,r.x);previous->y=fmin(previous->y,r.y);previous->width=right-previous->x;previous->height=bottom-previous->y;}
    }
    for(uint32_t i=0;i<state->count;++i) {
        out->geometry[i]=state->sources[i].text?state->sources[i].geometry:NULL;
        out->text_identity[i]=(uintptr_t)state->sources[i].text;
        out->geometry_identity[i]=(uintptr_t)out->geometry[i];
        zda_geometry_retain(out->geometry[i]);
        zda_copy_mapping(state,i,&out->mapping[i]);
    }
    ReleaseSRWLockShared(&state->lock);return S_OK;
}
static void geometry_snapshot_release(ZdaNative *state, GeometrySnapshot *snapshot) {
    for(uint32_t i=0;i<state->count;++i) zda_geometry_release(snapshot->geometry[i]);
}
/* Caller holds the native lock. Integer identities remain usable after all
   snapshot pins retire; serial rejects a new publication reusing an address. */
static BOOL point_front_current(ZdaNative *state,uint64_t serial,double x,double y,double scale) {
    return !state->closed && state->geometry_serial==serial && state->screen_x==x && state->screen_y==y && state->screen_scale==scale;
}
static BOOL point_bank_current(ZdaNative *state,uint32_t source,uintptr_t text,uintptr_t geometry) {
    return source<state->count && (uintptr_t)state->sources[source].text==text &&
        (uintptr_t)(state->sources[source].text?state->sources[source].geometry:NULL)==geometry;
}
static BOOL geometry_snapshot_current(ZdaNative *state,const GeometrySnapshot *snapshot) {
    if (!point_front_current(state,snapshot->serial,snapshot->x,snapshot->y,snapshot->scale)) return FALSE;
    for (uint32_t i=0;i<state->count;++i) if (!point_bank_current(state,i,snapshot->text_identity[i],snapshot->geometry_identity[i])) return FALSE;
    return TRUE;
}
static HRESULT provider_bounds(ZdaProvider *p, struct UiaRect *out, BOOL *offscreen) {
    if(auxiliary(p))return auxiliary_bounds(p,out,offscreen);
    if (!out) return E_POINTER; *out = (struct UiaRect){0};
    ZdaNative *state = p->state;
    GeometrySnapshot snapshot;
    HRESULT hr=geometry_snapshot(state,&snapshot);if(FAILED(hr))return hr;
    BOOL found = FALSE; double right = 0, bottom = 0;
    uint32_t start = group(p) ? 0 : p->source, end = group(p) ? state->count : p->source + 1;
    for (uint32_t i = start; i < end; ++i) {
        ZdaGeometry *geometry = snapshot.geometry[i];
        for (uint32_t j = 0; j < geometry_piece_count(state, geometry); ++j) {
            ZdaRect r;
            if (!zda_map_rectangle(&snapshot.mapping[i],geometry_piece(state, geometry, j),&r)) continue;
            r.x = snapshot.x + r.x * geometry->scale; r.y = snapshot.y + r.y * geometry->scale;
            r.width *= geometry->scale; r.height *= geometry->scale;
            if (!found) { *out = (struct UiaRect){ r.x, r.y, r.width, r.height }; right = r.x + r.width; bottom = r.y + r.height; found = TRUE; }
            else { out->left = fmin(out->left, r.x); out->top = fmin(out->top, r.y); right = fmax(right, r.x + r.width); bottom = fmax(bottom, r.y + r.height); }
        }
    }
    if (found) { out->width = right - out->left; out->height = bottom - out->top; }
    if(group(p)&&snapshot.has_auxiliary_bounds) {
        ZdaRect*r=&snapshot.auxiliary_bounds;
        if(!found){out->left=r->x;out->top=r->y;right=r->x+r->width;bottom=r->y+r->height;found=TRUE;}else{out->left=fmin(out->left,r->x);out->top=fmin(out->top,r->y);right=fmax(right,r->x+r->width);bottom=fmax(bottom,r->y+r->height);}
        if(found){out->width=right-out->left;out->height=bottom-out->top;}
    }
    if (offscreen) *offscreen = !found;
    geometry_snapshot_release(state,&snapshot); return S_OK;
}
static HRESULT STDMETHODCALLTYPE simple_property(IRawElementProviderSimple *iface, PROPERTYID id, VARIANT *out) {
    if (!out) return E_POINTER; VariantInit(out); ZdaProvider *p = simple_self(iface);
    HRESULT hr = alive(p); if (FAILED(hr)) return hr;
    if(auxiliary(p))return auxiliary_property(p,id,out);
    ZdaSpec *spec = group(p) ? NULL : &p->state->specs[p->source];
    if (id == UIA_ControlTypePropertyId) { out->vt = VT_I4; out->lVal = group(p) ? UIA_GroupControlTypeId : UIA_DocumentControlTypeId; }
    else if (id == UIA_NamePropertyId) { out->vt = VT_BSTR; out->bstrVal = spec ? SysAllocStringLen(spec->name, spec->name_length) : SysAllocString(L"Document comparison"); if (!out->bstrVal) return E_OUTOFMEMORY; }
    else if (id == UIA_IsControlElementPropertyId || id == UIA_IsContentElementPropertyId) { out->vt = VT_BOOL; out->boolVal = VARIANT_TRUE; }
    else if (id == UIA_IsKeyboardFocusablePropertyId) { out->vt = VT_BOOL; out->boolVal = spec && spec->focusable ? VARIANT_TRUE : VARIANT_FALSE; }
    else if (id == UIA_IsTextPatternAvailablePropertyId || id == UIA_IsTextPattern2AvailablePropertyId) {
        ZdaText *text = NULL; out->vt = VT_BOOL;
        out->boolVal = !group(p) && SUCCEEDED(zda_acquire(p->state, p->source, UINT64_MAX, &text, NULL, NULL)) ? VARIANT_TRUE : VARIANT_FALSE;
        zda_text_release(text);
    } else if (id == UIA_IsEnabledPropertyId || id == UIA_HasKeyboardFocusPropertyId) {
        AcquireSRWLockShared(&p->state->lock);
        if (p->state->closed) { ReleaseSRWLockShared(&p->state->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
        BOOL value = group(p) ? id == UIA_IsEnabledPropertyId : id == UIA_IsEnabledPropertyId ? p->state->sources[p->source].enabled : p->state->sources[p->source].focused;
        ReleaseSRWLockShared(&p->state->lock); out->vt = VT_BOOL; out->boolVal = value ? VARIANT_TRUE : VARIANT_FALSE;
    } else if (id == UIA_IsOffscreenPropertyId) { struct UiaRect bounds; BOOL offscreen; hr = provider_bounds(p, &bounds, &offscreen); if (FAILED(hr)) return hr; out->vt = VT_BOOL; out->boolVal = offscreen ? VARIANT_TRUE : VARIANT_FALSE; }
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE simple_host(IRawElementProviderSimple *iface, IRawElementProviderSimple **out) {
    if (!out) return E_POINTER; *out = NULL; ZdaProvider *p = simple_self(iface);
    // Immutable host identity is required by UiaDisconnectProvider after all
    // text/action ingress has closed. It owns no borrowed Window or Zig data.
    if (p->is_root && p->state->host) { *out = p->state->host; IRawElementProviderSimple_AddRef(*out); }
    return S_OK;
}
static const IRawElementProviderSimpleVtbl simple_vtable = { simple_query, simple_add, simple_release, simple_options, simple_pattern, simple_property, simple_host };
static HRESULT STDMETHODCALLTYPE fragment_navigate(IRawElementProviderFragment *iface, enum NavigateDirection direction, IRawElementProviderFragment **out) {
    if (!out) return E_POINTER; *out = NULL; ZdaProvider *p = fragment_self(iface); ZdaNative *s = p->state;
    if(auxiliary(p))return auxiliary_navigate(p,direction,out);
    AcquireSRWLockShared(&s->lock);
    if (s->closed) { ReleaseSRWLockShared(&s->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    ZdaProvider *next = NULL;
    if (group(p)) { if (direction == NavigateDirection_FirstChild) next = s->providers[0]; else if (direction == NavigateDirection_LastChild) next = s->auxiliary&&s->auxiliary->count?s->auxiliary->current->entries[0].provider:s->providers[s->count - 1]; }
    else if (!p->is_root) {
        if (direction == NavigateDirection_Parent) next = s->root;
        else if (direction == NavigateDirection_NextSibling && p->source + 1 < s->count) next = s->providers[p->source + 1];
        else if (direction == NavigateDirection_PreviousSibling && p->source) next = s->providers[p->source - 1];
        else if(direction==NavigateDirection_NextSibling&&p->source+1==s->count&&s->auxiliary&&s->auxiliary->count)next=s->auxiliary->current->entries[0].provider;
    }
    if (next) { provider_add(next); *out = &next->fragment; }
    ReleaseSRWLockShared(&s->lock); return S_OK;
}
static HRESULT STDMETHODCALLTYPE fragment_runtime(IRawElementProviderFragment *iface, SAFEARRAY **out) {
    if (!out) return E_POINTER; *out = NULL; ZdaProvider *p = fragment_self(iface);
    if (p->is_root) return S_OK;
    ULONG count=auxiliary(p)?10:2;
    SAFEARRAY *array = SafeArrayCreateVector(VT_I4, 0, count); if (!array) return E_OUTOFMEMORY;
    LONG values[10] = { UiaAppendRuntimeId, (LONG)p->source + 1 };
    if(auxiliary(p)){values[1]=0x415558;values[2]=(LONG)p->key.namespace_id;values[3]=(LONG)(p->key.namespace_id>>32);values[4]=(LONG)p->key.comparison;values[5]=(LONG)(p->key.comparison>>32);values[6]=(LONG)p->key.item;values[7]=(LONG)(p->key.item>>32);values[8]=(LONG)p->key.kind;values[9]=(LONG)p->key.variant;}
    for (LONG i = 0; i < (LONG)count; ++i) { HRESULT hr = SafeArrayPutElement(array, &i, &values[i]); if (FAILED(hr)) { SafeArrayDestroy(array); return hr; } }
    *out = array; return S_OK;
}
static HRESULT STDMETHODCALLTYPE fragment_bounds(IRawElementProviderFragment *iface, struct UiaRect *out) { return provider_bounds(fragment_self(iface), out, NULL); }
static HRESULT STDMETHODCALLTYPE fragment_embedded(IRawElementProviderFragment *iface, SAFEARRAY **out) { if (!out) return E_POINTER; *out = NULL; return alive(fragment_self(iface)); }
static HRESULT STDMETHODCALLTYPE fragment_focus(IRawElementProviderFragment *iface) { ZdaProvider*p=fragment_self(iface);return auxiliary(p)?auxiliary_request(p,4):request(p, ZDA_FOCUS, 0, 0, 0); }
static HRESULT STDMETHODCALLTYPE fragment_root(IRawElementProviderFragment *iface, IRawElementProviderFragmentRoot **out) {
    if (!out) return E_POINTER; *out = NULL; ZdaProvider *p = fragment_self(iface);
    AcquireSRWLockShared(&p->state->lock);
    // Disconnect resolves child runtime IDs through their immutable root even
    // after text and actions close. No semantic or Zig entry is restored.
    ZdaProvider *root = p->state->root;
    if (root) { provider_add(root); *out = &root->root; }
    ReleaseSRWLockShared(&p->state->lock); return root ? S_OK : UIA_E_ELEMENTNOTAVAILABLE;
}
static const IRawElementProviderFragmentVtbl fragment_vtable = { fragment_query, fragment_add, fragment_release, fragment_navigate, fragment_runtime, fragment_bounds, fragment_embedded, fragment_focus, fragment_root };
static HRESULT STDMETHODCALLTYPE root_point(IRawElementProviderFragmentRoot *iface, double x, double y, IRawElementProviderFragment **out) {
    if (!out) return E_POINTER; *out = NULL; ZdaProvider *p = root_self(iface); HRESULT hr = alive(p); if (FAILED(hr)) return hr;
    ZdaNative *state = p->state;
    if(!isfinite(x)||!isfinite(y))return E_INVALIDARG;
    zda_store_retain(state);
    GeometrySnapshot snapshot;
    hr=geometry_snapshot(state,&snapshot);if(FAILED(hr)){zda_store_release(state);return hr;}
    uint32_t found=state->count;
    for (uint32_t i = 0; i < state->count; ++i) {
        ZdaGeometry *geometry = snapshot.geometry[i];
        if(!geometry)continue;
        ZdaPoint point={(x-snapshot.x)/geometry->scale,(y-snapshot.y)/geometry->scale};
        if(!zda_map_contains(&snapshot.mapping[i],point))continue;
        if(snapshot.mapping[i].active)point=zda_map_point(snapshot.mapping[i].value.inverse,point);
        for (uint32_t j = 0; j < geometry_piece_count(state, geometry); ++j) {
            ZdaRect r = geometry_piece(state, geometry, j);
            if(point.x>=r.x && point.y>=r.y && point.x<r.x+r.width && point.y<r.y+r.height){found=i;break;}
        }
        if(found!=state->count)break;
    }
    ZdaProvider *candidate=NULL;
    AcquireSRWLockShared(&state->lock);
    if(!geometry_snapshot_current(state,&snapshot))hr=UIA_E_ELEMENTNOTAVAILABLE;
    if(SUCCEEDED(hr)&&state->auxiliary)for(uint32_t i=state->auxiliary->count;i>0;--i){
        const ZdaAuxEntry*entry=&state->auxiliary->current->entries[i-1];
        /* A semantic container is not a foreground input occluder. */
        if(entry->node.key.kind==0&&found<state->count)continue;
        const ZdaAuxGeometry*g=&state->auxiliary->geometry[i-1];double px=(x-state->screen_x)/state->auxiliary->scale,py=(y-state->screen_y)/state->auxiliary->scale;
        if(zda_auxiliary_contains(state->auxiliary,g,(ZdaPoint){px,py})){candidate=entry->provider;provider_add(candidate);break;}
    }
    if(SUCCEEDED(hr)&&!candidate&&found<state->count){candidate=state->providers[found];provider_add(candidate);}
    ReleaseSRWLockShared(&state->lock);
#ifdef ZDA_POINT_TESTING
    /* The isolated oracle pauses only its matching MTA invocation. Ordinary
       builds contain no hook, symbol, branch or associated storage. */
    if(SUCCEEDED(hr)) {
        extern void zda_point_test_snapshot(ZdaNative *,IRawElementProviderFragmentRoot *);
        zda_point_test_snapshot(state,iface);
    }
#endif
    geometry_snapshot_release(state,&snapshot);
    /* The calling provider still owns State; this invocation pin cannot be its
       last reference. No foreign release remains after the final shared lock. */
    zda_store_release(state);
    if(SUCCEEDED(hr)) {
        AcquireSRWLockShared(&state->lock);
        if(!geometry_snapshot_current(state,&snapshot) || (candidate && auxiliary(candidate) && auxiliary_index(state,&candidate->key)<0))hr=UIA_E_ELEMENTNOTAVAILABLE;
        if(SUCCEEDED(hr)&&candidate){*out=&candidate->fragment;candidate=NULL;}
        ReleaseSRWLockShared(&state->lock);
    }
    if(candidate)provider_release(candidate);
    return hr; /* No hit deliberately remains S_OK/NULL. */
}
static HRESULT STDMETHODCALLTYPE root_focus(IRawElementProviderFragmentRoot *iface, IRawElementProviderFragment **out) {
    if (!out) return E_POINTER; *out = NULL; ZdaProvider *p = root_self(iface); ZdaNative *state = p->state;
    AcquireSRWLockShared(&state->lock);
    if (state->closed) { ReleaseSRWLockShared(&state->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    if(state->auxiliary)for(uint32_t i=0;i<state->auxiliary->count;++i){ZdaRect visible;if((state->auxiliary->geometry[i].flags&6)==6&&zda_auxiliary_rectangle(state->auxiliary,&state->auxiliary->geometry[i],&visible)){ZdaProvider*child=state->auxiliary->current->entries[i].provider;provider_add(child);*out=&child->fragment;break;}}
    for (uint32_t i = 0; !*out && i < state->count; ++i) if (state->sources[i].focused) { provider_add(state->providers[i]); *out = &state->providers[i]->fragment; break; }
    ReleaseSRWLockShared(&state->lock); return S_OK;
}
static const IRawElementProviderFragmentRootVtbl root_vtable = { root_query, root_add, root_release, root_point, root_focus };

static ULONG STDMETHODCALLTYPE range_add(ITextRangeProvider *iface) { return (ULONG)InterlockedIncrement(&((ZdaRange *)iface)->refs); }
static ULONG STDMETHODCALLTYPE range_release(ITextRangeProvider *iface) {
    ZdaRange *r = (ZdaRange *)iface; LONG refs = InterlockedDecrement(&r->refs);
    if (!refs) { ZdaNative *state = r->state; zda_storage_release(r); zda_store_release(state); }
    return (ULONG)refs;
}
static HRESULT STDMETHODCALLTYPE range_query(ITextRangeProvider *iface, REFIID iid, void **out) {
    if (!out) return E_POINTER; *out = NULL;
    if (!IsEqualIID(iid, &IID_IUnknown) && !IsEqualIID(iid, &IID_ITextRangeProvider)) return E_NOINTERFACE;
    *out = IsEqualIID(iid, &IID_IUnknown) ? (void *)&((ZdaRange *)iface)->identity : (void *)iface;
    range_add(iface); return S_OK;
}
static ZdaRange *range_unknown_self(IUnknown *p) { return (ZdaRange *)((char *)p - offsetof(ZdaRange, identity)); }
static HRESULT STDMETHODCALLTYPE range_unknown_query(IUnknown *p, REFIID iid, void **out) { return range_query(&range_unknown_self(p)->iface, iid, out); }
static ULONG STDMETHODCALLTYPE range_unknown_add(IUnknown *p) { return range_add(&range_unknown_self(p)->iface); }
static ULONG STDMETHODCALLTYPE range_unknown_release(IUnknown *p) { return range_release(&range_unknown_self(p)->iface); }
static const IUnknownVtbl range_unknown_vtable = { range_unknown_query, range_unknown_add, range_unknown_release };
static BOOL current_range(ZdaRange *r) {
    ZdaCurrent *source = &r->state->sources[r->source];
    return !r->state->closed && source->text && source->text->version == r->version;
}
static HRESULT range_view_mapped(ZdaRange *r, ZdaText **text, ZdaGeometry **geometry, uint32_t *start, uint32_t *end, ZdaCurrent *metadata, double *x, double *y, ZdaMapped *mapping) {
    *text = NULL; if (geometry) *geometry = NULL;
    ZdaNative *state = r->state;
    AcquireSRWLockShared(&state->lock);
    if (!current_range(r)) { ReleaseSRWLockShared(&state->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    ZdaCurrent *source = &state->sources[r->source];
    *text = source->text; zda_text_retain(*text);
    if (geometry) { *geometry = source->geometry; zda_geometry_retain(*geometry); }
    if (start) *start = r->start; if (end) *end = r->end;
    if (metadata) *metadata = *source;
    if (x) *x = state->screen_x; if (y) *y = state->screen_y;
    if (mapping) zda_copy_mapping(state,r->source,mapping);
    ReleaseSRWLockShared(&state->lock); return S_OK;
}
static HRESULT range_view(ZdaRange *r, ZdaText **text, ZdaGeometry **geometry, uint32_t *start, uint32_t *end, ZdaCurrent *metadata, double *x, double *y) {
    return range_view_mapped(r,text,geometry,start,end,metadata,x,y,NULL);
}
static HRESULT create_range(ZdaNative *state, uint32_t source, uint64_t version, uint32_t start, uint32_t end, ZdaRange **out) {
    *out = NULL; if (source >= state->count || start > end) return E_INVALIDARG;
    ZdaText *text = NULL; HRESULT hr = zda_acquire(state, source, version, &text, NULL, NULL);
    if (FAILED(hr)) return hr;
    BOOL valid = zda_text_boundary(text, start) && zda_text_boundary(text, end); zda_text_release(text);
    if (!valid) return E_INVALIDARG;
    ZdaRange *r = NULL; int result = zda_storage_create(state->account, ZDA_RANGE, sizeof(*r), (void **)&r);
    if (result != ZDA_OK) return status(result);
    memset(r, 0, sizeof(*r)); r->iface.lpVtbl = &range_vtable; r->identity.lpVtbl = &range_unknown_vtable; r->refs = 1; r->state = state;
    r->source = source; r->version = version; r->start = start; r->end = end; zda_store_retain(state);
    AcquireSRWLockShared(&state->lock); valid = current_range(r); ReleaseSRWLockShared(&state->lock);
    if (!valid) { range_release(&r->iface); return UIA_E_ELEMENTNOTAVAILABLE; }
    *out = r; return S_OK;
}
typedef struct Interval { uint32_t start, end; } Interval;
static HRESULT array_ranges(ZdaProvider *p, uint64_t version, const Interval *ranges, uint32_t count, SAFEARRAY **out) {
    *out = NULL;
    if (count > p->state->range_limit) return HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA);
    SAFEARRAY *array = SafeArrayCreateVector(VT_UNKNOWN, 0, count); if (!array) return E_OUTOFMEMORY;
    for (LONG i = 0; i < (LONG)count; ++i) {
        ZdaRange *range = NULL; HRESULT hr = create_range(p->state, p->source, version, ranges[i].start, ranges[i].end, &range);
        if (SUCCEEDED(hr)) { hr = SafeArrayPutElement(array, &i, &range->identity); range_release(&range->iface); }
        if (FAILED(hr)) { SafeArrayDestroy(array); return hr; }
    }
    *out = array; return S_OK;
}
static HRESULT STDMETHODCALLTYPE text_selection(ITextProvider *iface, SAFEARRAY **out) {
    if (!out) return E_POINTER; *out = NULL; ZdaProvider *p = text_self(iface);
    ZdaText *text = NULL; ZdaCurrent source; HRESULT hr = zda_acquire(p->state, p->source, UINT64_MAX, &text, NULL, &source); if (FAILED(hr)) return hr;
    Interval ranges[ZDA_SELECTIONS]; uint32_t count = p->state->specs[p->source].selectable ? source.count : 0;
    for (uint32_t i = 0; i < count; ++i) { uint32_t a = source.selections[i].anchor, b = source.selections[i].caret; ranges[i] = (Interval){ a < b ? a : b, a > b ? a : b }; }
    hr = array_ranges(p, text->version, ranges, count, out); zda_text_release(text); return hr;
}
static int interval_compare(const void *a, const void *b) {
    const Interval *x = a, *y = b;
    return x->start < y->start ? -1 : x->start > y->start ? 1 : x->end < y->end ? -1 : x->end > y->end;
}
static HRESULT STDMETHODCALLTYPE text_visible(ITextProvider *iface, SAFEARRAY **out) {
    if (!out) return E_POINTER; *out = NULL; ZdaProvider *p = text_self(iface);
    ZdaText *text = NULL; ZdaGeometry *geometry = NULL; ZdaCurrent current; ZdaMapped mapping;
    HRESULT hr = zda_acquire_mapped(p->state, p->source, UINT64_MAX, &text, &geometry, &current,&mapping,NULL,NULL); if (FAILED(hr)) return hr;
    Interval *ranges = NULL; uint32_t count = 0;
    if (geometry && geometry->count) {
        int result = zda_storage_create(p->state->account, ZDA_BLOB, (size_t)geometry->count * sizeof(Interval), (void **)&ranges);
        if (result != ZDA_OK) { hr = status(result); goto done; }
        for (uint32_t i = 0; i < geometry->count; ++i) {ZdaRect visible;if(zda_map_rectangle(&mapping,geometry->cells[i].rectangle,&visible)) ranges[count++] = (Interval){ geometry->cells[i].start, geometry->cells[i].end };}
        qsort(ranges, count, sizeof(Interval), interval_compare);
        uint32_t merged = 0;
        for (uint32_t i = 0; i < count; ++i) {
            if (merged && ranges[i].start <= ranges[merged - 1].end) { if (ranges[i].end > ranges[merged - 1].end) ranges[merged - 1].end = ranges[i].end; }
            else ranges[merged++] = ranges[i];
        }
        count = merged;
    }
    if (count) hr = array_ranges(p, text->version, ranges, count, out);
    else {
        uint32_t caret = current.selections[current.primary].caret;
        if(geometry)for(uint32_t i=0;i<geometry->caret_count;++i)if(zda_map_caret(&mapping,geometry->carets[i].rectangle)){caret=geometry->carets[i].position;break;}
        const Interval empty = { caret, caret };
        hr = array_ranges(p, text->version, &empty, 1, out);
    }
done:
    zda_storage_release(ranges); zda_geometry_release(geometry); zda_text_release(text); return hr;
}
static HRESULT STDMETHODCALLTYPE text_child(ITextProvider *iface, IRawElementProviderSimple *child, ITextRangeProvider **out) {
    (void)child; if (!out) return E_POINTER; *out = NULL; HRESULT hr = alive(text_self(iface)); return FAILED(hr) ? hr : E_INVALIDARG;
}
static HRESULT STDMETHODCALLTYPE text_point(ITextProvider *iface, struct UiaPoint point, ITextRangeProvider **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    if (!isfinite(point.x) || !isfinite(point.y)) return E_INVALIDARG;
    ZdaProvider *provider = text_self(iface);
    ZdaNative *state = provider->state;
    ZdaText *text = NULL;
    ZdaGeometry *geometry = NULL;
    ZdaMapped mapping;
    const uint32_t source=provider->source;
    double origin_x,origin_y,screen_scale;
    uint64_t serial;
    uintptr_t text_identity,geometry_identity;
    ZdaRange *candidate=NULL;
    zda_store_retain(state);
    AcquireSRWLockShared(&state->lock);
    if(state->closed || source>=state->count || !state->sources[source].text) {
        ReleaseSRWLockShared(&state->lock);zda_store_release(state);return UIA_E_ELEMENTNOTAVAILABLE;
    }
    text=state->sources[source].text;zda_text_retain(text);
    geometry=state->sources[source].geometry;zda_geometry_retain(geometry);
    zda_copy_mapping(state,source,&mapping);
    origin_x=state->screen_x;origin_y=state->screen_y;screen_scale=state->screen_scale;serial=state->geometry_serial;
    text_identity=(uintptr_t)text;geometry_identity=(uintptr_t)geometry;
    ReleaseSRWLockShared(&state->lock);
    HRESULT hr;
    hr = UIA_E_NOTSUPPORTED;
    if (!geometry || !geometry->hit) goto done;
    if (geometry->hit->source!=source || geometry->hit->text!=text) { hr=UIA_E_ELEMENTNOTAVAILABLE;goto done; }
    ZdaPoint local = {(point.x-origin_x)/geometry->scale,(point.y-origin_y)/geometry->scale};
    if(!zda_map_contains(&mapping,local)){hr=E_INVALIDARG;goto done;}
    if(mapping.active)local=zda_map_point(mapping.value.inverse,local);
    const double x=local.x,y=local.y;
    if (x < geometry->bounds.x || y < geometry->bounds.y || x > geometry->bounds.x + geometry->bounds.width || y > geometry->bounds.y + geometry->bounds.height) { hr = E_INVALIDARG; goto done; }
    if(geometry->hit->input.domain) {
        BOOL visible=FALSE;
        for(uint32_t i=0;i<geometry->line_count;++i) {
            const ZdaRect r=geometry->lines[i].rectangle;
            if(x>=r.x && y>=r.y && x<r.x+r.width && y<r.y+r.height){visible=TRUE;break;}
        }
        if(!visible){hr=E_INVALIDARG;goto done;}
    }
    const float fx=(float)x,fy=(float)y;
    if(!isfinite(fx)||!isfinite(fy)){hr=E_INVALIDARG;goto done;}
    ZdeHitResult hit;
    int result=zde_prepared_hit_query(&geometry->hit->input.packet,fx,fy,&hit);
    if(result || hit.position>UINT32_MAX){hr=result?status(result):E_INVALIDARG;goto done;}
    const uint32_t position=(uint32_t)hit.position;
    hr=create_range(state,source,text->version,position,position,&candidate);
done:
    zda_geometry_release(geometry);zda_text_release(text);zda_store_release(state);
    if(SUCCEEDED(hr)) {
        AcquireSRWLockShared(&state->lock);
        if(!point_front_current(state,serial,origin_x,origin_y,screen_scale) || !point_bank_current(state,source,text_identity,geometry_identity))hr=UIA_E_ELEMENTNOTAVAILABLE;
        if(SUCCEEDED(hr)){*out=&candidate->iface;candidate=NULL;}
        ReleaseSRWLockShared(&state->lock);
    }
    if(candidate)range_release(&candidate->iface);
    return hr;
}
static HRESULT STDMETHODCALLTYPE text_document(ITextProvider *iface, ITextRangeProvider **out) {
    if (!out) return E_POINTER; *out = NULL; ZdaProvider *p = text_self(iface); ZdaText *text = NULL;
    HRESULT hr = zda_acquire(p->state, p->source, UINT64_MAX, &text, NULL, NULL); if (FAILED(hr)) return hr;
    ZdaRange *range = NULL; hr = create_range(p->state, p->source, text->version, 0, text->length, &range);
    zda_text_release(text); if (SUCCEEDED(hr)) *out = &range->iface; return hr;
}
static HRESULT STDMETHODCALLTYPE text_supported(ITextProvider *iface, enum SupportedTextSelection *out) {
    if (!out) return E_POINTER; ZdaProvider *p = text_self(iface); HRESULT hr = alive(p); if (FAILED(hr)) return hr;
    *out = p->state->specs[p->source].selectable ? SupportedTextSelection_Multiple : SupportedTextSelection_None; return S_OK;
}
static const ITextProviderVtbl text_vtable = { text_query, text_add, text_release, text_selection, text_visible, text_child, text_point, text_document, text_supported };
#include "native_text2.h"
static HRESULT STDMETHODCALLTYPE range_clone(ITextRangeProvider *iface, ITextRangeProvider **out) {
    if (!out) return E_POINTER; *out = NULL; ZdaRange *r = (ZdaRange *)iface; ZdaText *text = NULL; uint32_t start, end;
    HRESULT hr = range_view(r, &text, NULL, &start, &end, NULL, NULL, NULL); if (FAILED(hr)) return hr;
    ZdaRange *copy = NULL; hr = create_range(r->state, r->source, r->version, start, end, &copy); zda_text_release(text);
    if (SUCCEEDED(hr)) *out = &copy->iface; return hr;
}
static ZdaRange *compatible(ZdaRange *r, ITextRangeProvider *iface) {
    if (!iface || iface->lpVtbl != &range_vtable) return NULL;
    ZdaRange *other = (ZdaRange *)iface;
    return r->state == other->state && r->source == other->source && r->version == other->version ? other : NULL;
}
static HRESULT STDMETHODCALLTYPE range_compare(ITextRangeProvider *iface, ITextRangeProvider *other_iface, WINBOOL *out) {
    if (!out) return E_POINTER; *out = FALSE; ZdaRange *r = (ZdaRange *)iface, *other = compatible(r, other_iface);
    if (!other) return S_OK;
    AcquireSRWLockShared(&r->state->lock);
    HRESULT hr = current_range(r) && current_range(other) ? S_OK : UIA_E_ELEMENTNOTAVAILABLE;
    if (SUCCEEDED(hr)) *out = r->start == other->start && r->end == other->end;
    ReleaseSRWLockShared(&r->state->lock); return hr;
}
static BOOL endpoint_valid(enum TextPatternRangeEndpoint endpoint) { return endpoint == TextPatternRangeEndpoint_Start || endpoint == TextPatternRangeEndpoint_End; }
static HRESULT STDMETHODCALLTYPE range_compare_endpoints(ITextRangeProvider *iface, enum TextPatternRangeEndpoint endpoint, ITextRangeProvider *other_iface, enum TextPatternRangeEndpoint other_endpoint, int *out) {
    if (!out) return E_POINTER; *out = 0; ZdaRange *r = (ZdaRange *)iface, *other = compatible(r, other_iface);
    if (!other || !endpoint_valid(endpoint) || !endpoint_valid(other_endpoint)) return E_INVALIDARG;
    AcquireSRWLockShared(&r->state->lock);
    HRESULT hr = current_range(r) && current_range(other) ? S_OK : UIA_E_ELEMENTNOTAVAILABLE;
    if (SUCCEEDED(hr)) *out = (int)(endpoint == TextPatternRangeEndpoint_Start ? r->start : r->end) - (int)(other_endpoint == TextPatternRangeEndpoint_Start ? other->start : other->end);
    ReleaseSRWLockShared(&r->state->lock); return hr;
}
typedef struct Units { const uint32_t *positions; uint32_t count; } Units;
static BOOL units_for(ZdaText *text, enum TextUnit unit, uint32_t document[2], Units *out) {
    if (unit < TextUnit_Character || unit > TextUnit_Document) return FALSE;
    if (unit == TextUnit_Character) *out = (Units){ text->graphemes, text->grapheme_count };
    else if (unit <= TextUnit_Word && text->word_count) *out = (Units){ zda_word_positions(text), text->word_count };
    else if (unit <= TextUnit_Paragraph) {
        uint32_t count = text->paragraph_count;
        if (count > 1 && text->paragraphs[count - 1] == text->paragraphs[count - 2]) --count;
        *out = (Units){ text->paragraphs, count };
    } else { document[0] = 0; document[1] = text->length; *out = (Units){ document, text->length ? 2 : 1 }; }
    return TRUE;
}
static uint32_t lower_unit(Units units, uint32_t position) {
    uint32_t lo = 0, hi = units.count;
    while (lo < hi) { uint32_t mid = lo + (hi - lo) / 2; if (units.positions[mid] < position) lo = mid + 1; else hi = mid; }
    return lo;
}
static HRESULT STDMETHODCALLTYPE range_expand(ITextRangeProvider *iface, enum TextUnit unit) {
    ZdaRange *r = (ZdaRange *)iface; ZdaNative *s = r->state; AcquireSRWLockExclusive(&s->lock);
    if (!current_range(r)) { ReleaseSRWLockExclusive(&s->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    uint32_t document[2]; Units units;
    if (!units_for(s->sources[r->source].text, unit, document, &units)) { ReleaseSRWLockExclusive(&s->lock); return E_INVALIDARG; }
    ZdaText *text = s->sources[r->source].text;
    if (units.positions == text->paragraphs && r->start == text->length && text->paragraphs[text->paragraph_count - 2] == text->length) {
        r->end = r->start; ReleaseSRWLockExclusive(&s->lock); return S_OK;
    }
    uint32_t at = lower_unit(units, r->start);
    if (at == units.count || units.positions[at] > r->start || (at + 1 == units.count && at)) --at;
    r->start = units.positions[at]; r->end = units.positions[at + 1 < units.count ? at + 1 : at];
    ReleaseSRWLockExclusive(&s->lock); return S_OK;
}
static HRESULT STDMETHODCALLTYPE range_find_attribute(ITextRangeProvider *iface, TEXTATTRIBUTEID attribute, VARIANT value, WINBOOL backward, ITextRangeProvider **out) {
    (void)backward; if (!out) return E_POINTER; *out = NULL; ZdaRange *r = (ZdaRange *)iface;
    if (attribute != UIA_IsReadOnlyAttributeId || value.vt != VT_BOOL || ((value.boolVal != VARIANT_FALSE) != !!r->state->specs[r->source].read_only)) { ZdaText *text = NULL; HRESULT hr = range_view(r, &text, NULL, NULL, NULL, NULL, NULL, NULL); zda_text_release(text); return hr; }
    return range_clone(iface, out);
}
static HRESULT STDMETHODCALLTYPE range_find_text(ITextRangeProvider *iface, BSTR needle, WINBOOL backward, WINBOOL ignore_case, ITextRangeProvider **out) {
    if (!out) return E_POINTER; *out = NULL; ZdaRange *r = (ZdaRange *)iface; ZdaText *text = NULL; uint32_t start, end;
    HRESULT hr = range_view(r, &text, NULL, &start, &end, NULL, NULL, NULL); if (FAILED(hr)) return hr;
    const uint32_t length = SysStringLen(needle); uint64_t work = 0; uint32_t found = UINT32_MAX;
    if (length > r->state->output_units) { zda_text_release(text); return HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA); }
    if (length <= end - start) {
        uint32_t last = end - length;
        for (uint32_t step = 0; step <= last - start; ++step) {
            uint32_t position = backward ? last - step : start + step;
            if (!zda_text_boundary(text, position) || !zda_text_boundary(text, position + length)) continue;
            work += (uint64_t)length + 1;
            if (work > UINT64_C(16777216)) { hr = HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA); break; }
            if (!length || CompareStringOrdinal(text->text + position, (int)length, needle, (int)length, ignore_case) == CSTR_EQUAL) { found = position; break; }
        }
    }
    if (SUCCEEDED(hr) && found != UINT32_MAX) { ZdaRange *result = NULL; hr = create_range(r->state, r->source, r->version, found, found + length, &result); if (SUCCEEDED(hr)) *out = &result->iface; }
    zda_text_release(text); return hr;
}
static HRESULT STDMETHODCALLTYPE range_attribute(ITextRangeProvider *iface, TEXTATTRIBUTEID attribute, VARIANT *out) {
    if (!out) return E_POINTER; VariantInit(out); ZdaRange *r = (ZdaRange *)iface; ZdaText *text = NULL;
    HRESULT hr = range_view(r, &text, NULL, NULL, NULL, NULL, NULL, NULL); zda_text_release(text); if (FAILED(hr)) return hr;
    if (attribute == UIA_IsReadOnlyAttributeId) { out->vt = VT_BOOL; out->boolVal = r->state->specs[r->source].read_only ? VARIANT_TRUE : VARIANT_FALSE; return S_OK; }
    out->vt = VT_UNKNOWN; return UiaGetReservedNotSupportedValue(&out->punkVal);
}
static HRESULT STDMETHODCALLTYPE range_rectangles(ITextRangeProvider *iface, SAFEARRAY **out) {
    if (!out) return E_POINTER; *out = NULL; ZdaRange *r = (ZdaRange *)iface; ZdaText *text = NULL; ZdaGeometry *geometry = NULL; uint32_t start, end; double x, y;
    ZdaMapped mapping;
    HRESULT hr = range_view_mapped(r, &text, &geometry, &start, &end, NULL, &x, &y,&mapping); if (FAILED(hr)) return hr;
    uint32_t count = 0;
    if (geometry && start != end) for (uint32_t i = 0; i < geometry->count; ++i) {
        ZdaCell *cell = &geometry->cells[i];
        ZdaRect visible;
        if (cell->start < end && cell->end > start && zda_map_rectangle(&mapping,cell->rectangle,&visible)) ++count;
    }
    SAFEARRAY *array = SafeArrayCreateVector(VT_R8, 0, count * 4); if (!array) { hr = E_OUTOFMEMORY; goto done; }
    LONG at = 0;
    if (geometry && start != end) for (uint32_t i = 0; i < geometry->count; ++i) {
        ZdaCell *cell = &geometry->cells[i];
        ZdaRect visible;
        if (!(cell->start < end && cell->end > start) || !zda_map_rectangle(&mapping,cell->rectangle,&visible)) continue;
        double values[4] = { x + visible.x * geometry->scale, y + visible.y * geometry->scale, visible.width * geometry->scale, visible.height * geometry->scale };
        for (int j = 0; j < 4; ++j, ++at) { hr = SafeArrayPutElement(array, &at, &values[j]); if (FAILED(hr)) { SafeArrayDestroy(array); goto done; } }
    }
    *out = array;
done:
    zda_geometry_release(geometry); zda_text_release(text); return hr;
}
static HRESULT STDMETHODCALLTYPE range_element(ITextRangeProvider *iface, IRawElementProviderSimple **out) {
    if (!out) return E_POINTER; *out = NULL; ZdaRange *r = (ZdaRange *)iface;
    AcquireSRWLockShared(&r->state->lock);
    if (!current_range(r)) { ReleaseSRWLockShared(&r->state->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    ZdaProvider *provider = r->state->providers[r->source]; provider_add(provider); *out = &provider->simple;
    ReleaseSRWLockShared(&r->state->lock); return S_OK;
}
static HRESULT STDMETHODCALLTYPE range_text(ITextRangeProvider *iface, int maximum, BSTR *out) {
    if (!out) return E_POINTER; *out = NULL; if (maximum < -1) return E_INVALIDARG;
    ZdaRange *r = (ZdaRange *)iface; ZdaText *text = NULL; uint32_t start, end;
    HRESULT hr = range_view(r, &text, NULL, &start, &end, NULL, NULL, NULL); if (FAILED(hr)) return hr;
    uint32_t length = end - start;
    if (maximum >= 0 && (uint32_t)maximum < length) length = (uint32_t)maximum;
    if (length > r->state->output_units) { zda_text_release(text); return HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA); }
    if (length && !zda_text_boundary(text, start + length)) --length;
    *out = SysAllocStringLen(text->text + start, length); zda_text_release(text); return *out ? S_OK : E_OUTOFMEMORY;
}
static HRESULT STDMETHODCALLTYPE range_move(ITextRangeProvider *iface, enum TextUnit unit, int count, int *out) {
    if (!out) return E_POINTER; *out = 0; ZdaRange *r = (ZdaRange *)iface; ZdaNative *s = r->state; AcquireSRWLockExclusive(&s->lock);
    if (!current_range(r)) { ReleaseSRWLockExclusive(&s->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    uint32_t document[2]; Units units;
    if (!units_for(s->sources[r->source].text, unit, document, &units)) { ReleaseSRWLockExclusive(&s->lock); return E_INVALIDARG; }
    if (!count || units.count <= 1) { ReleaseSRWLockExclusive(&s->lock); return S_OK; }
    uint32_t at = lower_unit(units, r->start); BOOL empty = r->start == r->end;
    int64_t base;
    if (empty) base = at < units.count && units.positions[at] == r->start ? at : count > 0 ? (int64_t)at - 1 : at;
    else { if (at == units.count || units.positions[at] > r->start || at + 1 == units.count) --at; base = at; }
    int64_t target = base + count, last = (int64_t)units.count - (empty ? 1 : 2);
    if (target < 0) target = 0; if (target > last) target = last;
    if (target == base) { ReleaseSRWLockExclusive(&s->lock); return S_OK; }
    *out = (int)(target - base); r->start = units.positions[target]; r->end = empty ? r->start : units.positions[target + 1];
    ReleaseSRWLockExclusive(&s->lock); return S_OK;
}
static HRESULT STDMETHODCALLTYPE range_move_endpoint(ITextRangeProvider *iface, enum TextPatternRangeEndpoint endpoint, enum TextUnit unit, int count, int *out) {
    if (!out) return E_POINTER; *out = 0; if (!endpoint_valid(endpoint)) return E_INVALIDARG;
    ZdaRange *r = (ZdaRange *)iface; ZdaNative *s = r->state; AcquireSRWLockExclusive(&s->lock);
    if (!current_range(r)) { ReleaseSRWLockExclusive(&s->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    uint32_t document[2]; Units units;
    if (!units_for(s->sources[r->source].text, unit, document, &units)) { ReleaseSRWLockExclusive(&s->lock); return E_INVALIDARG; }
    uint32_t *position = endpoint == TextPatternRangeEndpoint_Start ? &r->start : &r->end;
    if (count) {
        uint32_t at = lower_unit(units, *position);
        int64_t base = at < units.count && units.positions[at] == *position ? at : count > 0 ? (int64_t)at - 1 : at;
        int64_t target = base + count; if (target < 0) target = 0; if (target >= units.count) target = units.count - 1;
        *out = (int)(target - base); *position = units.positions[target];
        if (r->start > r->end) { if (endpoint == TextPatternRangeEndpoint_Start) r->end = r->start; else r->start = r->end; }
    }
    ReleaseSRWLockExclusive(&s->lock); return S_OK;
}
static HRESULT STDMETHODCALLTYPE range_move_endpoint_range(ITextRangeProvider *iface, enum TextPatternRangeEndpoint endpoint, ITextRangeProvider *other_iface, enum TextPatternRangeEndpoint other_endpoint) {
    ZdaRange *r = (ZdaRange *)iface, *other = compatible(r, other_iface);
    if (!other || !endpoint_valid(endpoint) || !endpoint_valid(other_endpoint)) return E_INVALIDARG;
    AcquireSRWLockExclusive(&r->state->lock);
    if (!current_range(r) || !current_range(other)) { ReleaseSRWLockExclusive(&r->state->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    uint32_t position = other_endpoint == TextPatternRangeEndpoint_Start ? other->start : other->end;
    if (endpoint == TextPatternRangeEndpoint_Start) { r->start = position; if (r->end < position) r->end = position; }
    else { r->end = position; if (r->start > position) r->start = position; }
    ReleaseSRWLockExclusive(&r->state->lock); return S_OK;
}
/* Explicit bounded native handoff. A successful enqueue owns exactly one slot
   until finish_action, including tasks left in the App's accepted post queue. */
static HRESULT request_version(ZdaNative *state, uint32_t source, uint64_t version, uint32_t kind, uint32_t start, uint32_t end, uint32_t align) {
    AcquireSRWLockExclusive(&state->lock);
    ZdaCurrent *current = source < state->count ? &state->sources[source] : NULL;
    if (state->closed || !current || !current->text || !state->context || !state->enqueue || (version != UINT64_MAX && version != current->text->version)) { ReleaseSRWLockExclusive(&state->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    ZdaSpec *spec = &state->specs[source];
    if (!current->enabled) { ReleaseSRWLockExclusive(&state->lock); return UIA_E_ELEMENTNOTENABLED; }
    if (current->composing) { ReleaseSRWLockExclusive(&state->lock); return UIA_E_INVALIDOPERATION; }
    if (state->presentation_required && !state->presentation_epoch) { ReleaseSRWLockExclusive(&state->lock); return UIA_E_NOTSUPPORTED; }
    if ((kind == ZDA_FOCUS && !spec->focusable) || (kind == ZDA_SCROLL && !spec->scrollable) || (kind != ZDA_FOCUS && kind != ZDA_SCROLL && !spec->selectable)) { ReleaseSRWLockExclusive(&state->lock); return UIA_E_NOTSUPPORTED; }
    if (!zda_text_boundary(current->text, start) || !zda_text_boundary(current->text, end) || start > end) { ReleaseSRWLockExclusive(&state->lock); return E_INVALIDARG; }
    ZdaAction *action = NULL;
    for (uint32_t i = 0; i < ZDA_ACTIONS; ++i) if (!state->actions[i].used) { action = &state->actions[i]; break; }
    if (!action) { ReleaseSRWLockExclusive(&state->lock); return HRESULT_FROM_WIN32(ERROR_BUSY); }
    *action = (ZdaAction){ .state = state, .used = TRUE, .version = current->text->version, .revision = current->revision, .presentation_epoch = state->presentation_epoch, .source = source, .kind = kind, .start = start, .end = end, .align_top = align };
    zda_store_retain(state);
    ZdaEnqueue enqueue = state->enqueue; void *context = state->context; BOOL is_owner = GetCurrentThreadId() == state->owner;
    if (is_owner) ReleaseSRWLockExclusive(&state->lock);
    int accepted = enqueue(context, action);
    if (!is_owner) ReleaseSRWLockExclusive(&state->lock);
    if (!accepted) { AcquireSRWLockExclusive(&state->lock); action->used = FALSE; ReleaseSRWLockExclusive(&state->lock); zda_store_release(state); return HRESULT_FROM_WIN32(ERROR_BUSY); }
    return S_OK;
}
static HRESULT request(ZdaProvider *p, uint32_t kind, uint32_t start, uint32_t end, uint32_t align) {
    if (group(p)) return UIA_E_NOTSUPPORTED;
    return request_version(p->state, p->source, UINT64_MAX, kind, start, end, align);
}
int zda_native_take_action(void *storage, ZdaActionView *out) {
    ZdaAction *action = storage; ZdaNative *state = action->state;
    assert(GetCurrentThreadId() == state->owner);
    AcquireSRWLockShared(&state->lock);
    BOOL valid = action->used && action->source < state->count && !state->closed && state->context && action->presentation_epoch == state->presentation_epoch;
    if (valid) *out = (ZdaActionView){ state->context, action->version, action->revision, action->presentation_epoch, action->source, action->kind, action->start, action->end, action->align_top };
    ReleaseSRWLockShared(&state->lock); return valid;
}
void zda_native_finish_action(void *storage) {
    ZdaAction *action = storage; ZdaNative *state = action->state;
    assert(GetCurrentThreadId() == state->owner);
    AcquireSRWLockExclusive(&state->lock); assert(action->used); action->used = FALSE; ReleaseSRWLockExclusive(&state->lock);
    zda_store_release(state);
}
static HRESULT range_request(ITextRangeProvider *iface, uint32_t kind, uint32_t align) {
    ZdaRange *r = (ZdaRange *)iface; ZdaText *text = NULL; uint32_t start, end;
    HRESULT hr = range_view(r, &text, NULL, &start, &end, NULL, NULL, NULL); zda_text_release(text); if (FAILED(hr)) return hr;
    return request_version(r->state, r->source, r->version, kind, start, end, align);
}
static HRESULT STDMETHODCALLTYPE range_select(ITextRangeProvider *iface) { return range_request(iface, ZDA_SELECT, 0); }
static HRESULT STDMETHODCALLTYPE range_add_selection(ITextRangeProvider *iface) { return range_request(iface, ZDA_ADD_SELECTION, 0); }
static HRESULT STDMETHODCALLTYPE range_remove_selection(ITextRangeProvider *iface) { return range_request(iface, ZDA_REMOVE_SELECTION, 0); }
static HRESULT STDMETHODCALLTYPE range_scroll(ITextRangeProvider *iface, WINBOOL align) { return range_request(iface, ZDA_SCROLL, !!align); }
static HRESULT STDMETHODCALLTYPE range_children(ITextRangeProvider *iface, SAFEARRAY **out) {
    if (!out) return E_POINTER; *out = NULL; ZdaText *text = NULL; HRESULT hr = range_view((ZdaRange *)iface, &text, NULL, NULL, NULL, NULL, NULL, NULL); zda_text_release(text); if (FAILED(hr)) return hr;
    *out = SafeArrayCreateVector(VT_UNKNOWN, 0, 0); return *out ? S_OK : E_OUTOFMEMORY;
}
static const ITextRangeProviderVtbl range_vtable = {
    range_query, range_add, range_release, range_clone, range_compare, range_compare_endpoints,
    range_expand, range_find_attribute, range_find_text, range_attribute, range_rectangles,
    range_element, range_text, range_move, range_move_endpoint, range_move_endpoint_range,
    range_select, range_add_selection, range_remove_selection, range_scroll, range_children
};
int zda_native_create(void *hwnd, const ZdaSource *sources, uint32_t count, uint64_t bytes, uint32_t ranges, uint32_t outputs, ZdaEnqueue enqueue, void *context, ZdaError *error, ZdaNative **out) {
    if (error) *error = (ZdaError){0};
    int result = zda_store_create(hwnd, sources, count, bytes, ranges, outputs, enqueue, context, out);
    if (result != ZDA_OK) return result;
    ZdaNative *state = *out; HRESULT hr = UiaHostProviderFromHwnd(hwnd, &state->host);
    if (FAILED(hr)) goto failed;
    for (uint32_t i = 0; i < count; ++i) { hr = create_provider(state, i, &state->providers[i]); if (FAILED(hr)) goto failed; }
    if (count == 1) { state->root = state->providers[0]; provider_add(state->root); }
    else { hr = create_provider(state, ROOT_SOURCE, &state->root); if (FAILED(hr)) goto failed; }
    state->root->is_root = TRUE;
    return ZDA_OK;
failed:
    if (error) *error = (ZdaError){ 1, hr };
    zda_native_begin_close(state);
    if (state->root) provider_release(state->root);
    for (uint32_t i = 0; i < count; ++i) if (state->providers[i]) provider_release(state->providers[i]);
    zda_store_release(state); *out = NULL;
    return hr == E_OUTOFMEMORY ? ZDA_OOM : ZDA_UNAVAILABLE;
}
int32_t zda_native_disconnect(ZdaNative *state) {
    assert(GetCurrentThreadId() == state->owner && state->closed);
    HRESULT result = S_OK;
    for (uint32_t i = 0; i < state->count; ++i) {
        HRESULT hr = UiaDisconnectProvider(&state->providers[i]->simple);
        if (FAILED(hr) && SUCCEEDED(result)) result = hr;
    }
    if (state->root->source == ROOT_SOURCE) { HRESULT hr = UiaDisconnectProvider(&state->root->simple); if (FAILED(hr) && SUCCEEDED(result)) result = hr; }
    if(state->auxiliary&&state->auxiliary->current)for(uint32_t i=0;i<state->auxiliary->current->count;++i){HRESULT hr=UiaDisconnectProvider(&state->auxiliary->current->entries[i].provider->simple);if(FAILED(hr)&&SUCCEEDED(result))result=hr;}
    ZdaProvider *root, *providers[ZDA_SOURCES] = {0};
    AcquireSRWLockExclusive(&state->lock);
    root = state->root; state->root = NULL;
    ZdaAuxiliary *auxiliary=state->auxiliary;state->auxiliary=NULL;
    for (uint32_t i = 0; i < state->count; ++i) { providers[i] = state->providers[i]; state->providers[i] = NULL; }
    ReleaseSRWLockExclusive(&state->lock);
    if(auxiliary){zda_auxiliary_release(auxiliary->current);zda_storage_release(auxiliary->affine);zda_storage_release(auxiliary);}
    provider_release(root);
    for (uint32_t i = 0; i < state->count; ++i) provider_release(providers[i]);
    zda_store_release(state); return result;
}
intptr_t zda_native_object(ZdaNative *state, uintptr_t wp, intptr_t lp) {
    assert(GetCurrentThreadId() == state->owner);
    if (state->closed || lp != UiaRootObjectId) return 0;
    return UiaReturnRawElementProvider(state->hwnd, (WPARAM)wp, (LPARAM)lp, &state->root->simple);
}
void *zda_native_provider(ZdaNative *state, uint32_t source) {
    AcquireSRWLockShared(&state->lock);
    ZdaProvider *provider = state->closed ? NULL : source == ROOT_SOURCE ? state->root : source < state->count ? state->providers[source] : NULL;
    if (provider) provider_add(provider);
    ReleaseSRWLockShared(&state->lock); return provider ? &provider->simple : NULL;
}
#include "native_auxiliary.h"
