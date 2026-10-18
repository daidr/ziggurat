#ifndef ZIGGURAT_DOCUMENT_ACCESSIBILITY_INTERNAL_H
#define ZIGGURAT_DOCUMENT_ACCESSIBILITY_INTERNAL_H
#define COBJMACROS
#define CONST_VTABLE
#define WIN32_LEAN_AND_MEAN
#define NO_STRICT
#include <windows.h>
#include <uiautomation.h>
#include <oleauto.h>
#include "native.h"
#define ZDA_SOURCES 2
#define ZDA_SELECTIONS 64
#define ZDA_ACTIONS 16
typedef void *(__cdecl *ZdaBreakOpen)(int32_t,const char *,const uint16_t *,int32_t,int32_t *);
typedef int32_t (__cdecl *ZdaBreakNext)(void *);
typedef void (__cdecl *ZdaBreakClose)(void *);
typedef int32_t (__cdecl *ZdaBreakStatus)(void *);
typedef struct ZdaProvider ZdaProvider;
typedef struct ZdaAuxiliary ZdaAuxiliary;
typedef struct ZdaMapped ZdaMapped;
struct ZdaText {
    volatile LONG refs;
    uint32_t word_count;
    uint64_t version;
    uint32_t length, scalar_count, paragraph_count, grapheme_count;
    uint16_t *text;
    uint32_t *scalars, *paragraphs, *graphemes;
};
typedef struct ZdaOwnedHit {
    ZdaText *text; /* Owning exact Text, never a State back edge. */
    uint32_t source,reserved;
    ZdaHitInput input;
} ZdaOwnedHit;
struct ZdaGeometry {
    volatile LONG refs;
    uint64_t version, projection_version;
    double scale;
    ZdaRect bounds;
    uint32_t count;
    ZdaCell *cells;
    uint32_t caret_count, line_count;
    ZdaCaret *carets;
    ZdaLine *lines;
    const ZdaOwnedHit *hit; /* Header and arrays share this ledger block. */
};
typedef struct ZdaCurrent {
    ZdaText *text;
    ZdaGeometry *geometry;
    uint64_t revision;
    ZdaSelection selections[ZDA_SELECTIONS];
    uint32_t count, primary, enabled, focused, composing;
} ZdaCurrent;
typedef struct ZdaSpec {
    WCHAR name[128];
    uint32_t name_length, read_only, selectable, focusable, scrollable;
} ZdaSpec;
typedef struct ZdaAction {
    ZdaNative *state;
    BOOL used;
    uint64_t presentation_epoch;
    uint32_t source, kind;
    union {
        struct { uint64_t version, revision; uint32_t start, end, align_top; };
        ZdaAuxKey auxiliary_key;
    };
} ZdaAction;
typedef struct ZdaAuxEntry { ZdaAuxNode node; ZdaProvider *provider; } ZdaAuxEntry;
struct ZdaAuxPlan {
    volatile LONG refs;
    ZdaNative *state;
    uint32_t count, name_length;
    ZdaAuxEntry *entries;
    WCHAR *names;
};
typedef struct ZdaAuxMapping {
    ZdaMapping mapping;
    ZdaPublication publication;
    uint64_t action_serial[ZDA_ACTIONS];
    BOOL active;
} ZdaAuxMapping;
struct ZdaAuxiliary {
    uint32_t capacity, count;
    double scale;
    ZdaAuxPlan *current;
    ZdaAuxMapping *affine;
    ZdaAuxGeometry geometry[];
};
struct ZdaNative {
    volatile LONG refs;
    SRWLOCK lock;
    DWORD owner;
    BOOL closed;
    HWND hwnd;
    IRawElementProviderSimple *host;
    double screen_x, screen_y, screen_scale;
    ZdaAccount *account;
    ZdaEnqueue enqueue;
    void *context;
    uint32_t count, output_units, range_limit;
    ZdaSpec specs[ZDA_SOURCES];
    ZdaCurrent sources[ZDA_SOURCES];
    ZdaMapping *mappings;
    BOOL mapped[ZDA_SOURCES];
    BOOL presentation_required;
    uint32_t text_features;
    uint64_t presentation_epoch;
    uint64_t geometry_serial;
    ZdaAuxiliary *auxiliary;
    ZdaProvider *root, *providers[ZDA_SOURCES];
    ZdaAction actions[ZDA_ACTIONS];
    HMODULE unicode;
    ZdaBreakOpen break_open;
    ZdaBreakNext break_first, break_next;
    ZdaBreakClose break_close;
};
enum { ZDA_WORD_UNITS=1, ZDA_TEXT_STARTED=2 };
/* Optional word positions follow the existing grapheme-capacity array. The
   count occupies the old ref/version alignment padding; no default table. */
static inline uint32_t *zda_word_positions(ZdaText *text) { return text->graphemes+text->scalar_count; }
int zda_store_create(void *, const ZdaSource *, uint32_t, uint64_t, uint32_t, uint32_t, ZdaEnqueue, void *, ZdaNative **);
void zda_store_retain(ZdaNative *);
void zda_store_release(ZdaNative *);
void zda_text_retain(ZdaText *);
void zda_geometry_retain(ZdaGeometry *);
BOOL zda_text_boundary(const ZdaText *, uint32_t);
void zda_auxiliary_retain(ZdaAuxPlan *);
/* Returned refs contain no borrowed Zig memory, and may be released by MTA. */
HRESULT zda_acquire(ZdaNative *, uint32_t, uint64_t, ZdaText **, ZdaGeometry **, ZdaCurrent *);
HRESULT zda_acquire_mapped(ZdaNative *, uint32_t, uint64_t, ZdaText **, ZdaGeometry **, ZdaCurrent *, ZdaMapped *, double *, double *);
#endif
