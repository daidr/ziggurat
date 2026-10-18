#ifndef ZIGGURAT_DOCUMENT_ACCESSIBILITY_NATIVE_H
#define ZIGGURAT_DOCUMENT_ACCESSIBILITY_NATIVE_H
#include "native_ledger.h"
#include "../document_editor/prepared_hit.h"
typedef struct ZdaNative ZdaNative;
typedef struct ZdaText ZdaText;
typedef struct ZdaGeometry ZdaGeometry;
typedef struct ZdaAuxPlan ZdaAuxPlan;
typedef struct ZdaAuxKey { uint64_t namespace_id, comparison, item; uint32_t kind, variant; } ZdaAuxKey;
/* expanded: bit0=expanded, bit1=keyboard-focusable; unknown bits rejected. */
typedef struct ZdaAuxNode { ZdaAuxKey key; uint64_t frame_id; uint32_t parent, name_start, name_length, expanded; } ZdaAuxNode;
/* Optional affine authority. A zero generation denotes the identity path. */
typedef struct ZdaPublication { uint64_t generation,publication,source,candidate,space_epoch,space_generation; } ZdaPublication;
typedef struct ZdaAuxAccepted { ZdaAuxKey key; uint64_t presentation_epoch; uint32_t flags,reserved; uint64_t frame_id; ZdaPublication publication; } ZdaAuxAccepted;
typedef struct ZdaAuxGeometry { double x,y,width,height; uint32_t flags,reserved; } ZdaAuxGeometry;
typedef struct ZdaAuxAction { void *context; ZdaAuxKey key; uint64_t presentation_epoch; uint32_t kind,reserved; ZdaPublication publication; } ZdaAuxAction;
typedef struct ZdaError { uint32_t domain; int32_t code; } ZdaError;
typedef struct ZdaRect { double x, y, width, height; } ZdaRect;
typedef struct ZdaPoint { double x, y; } ZdaPoint;
#define ZDA_MAP_POINTS 132
typedef struct ZdaMapping {
    double forward[6], inverse[6];
    ZdaPoint polygon[ZDA_MAP_POINTS];
    uint32_t count, reserved;
} ZdaMapping;
typedef struct ZdaCell { uint32_t start, end; ZdaRect rectangle; } ZdaCell;
/* True system caret stops, not an advance-cell midpoint approximation.
   Affinity 0=upstream, 1=downstream; line arrays are in visual order. */
typedef struct ZdaCaret { uint32_t position, affinity; ZdaRect rectangle; } ZdaCaret;
typedef struct ZdaLine { uint32_t first, count; ZdaRect rectangle; } ZdaLine;
typedef struct ZdaSelection { uint32_t anchor, caret; } ZdaSelection;
typedef struct ZdaSource {
    const uint16_t *name;
    uint32_t name_length;
    uint32_t read_only, selectable, focusable, scrollable;
} ZdaSource;
typedef struct ZdaTextInput {
    uint64_t text_version;
    const uint16_t *text;
    const uint32_t *scalars, *paragraphs;
    uint32_t text_length, scalar_count, paragraph_count;
} ZdaTextInput;
typedef struct ZdaMetadata {
    uint64_t text_version, revision;
    const ZdaSelection *selections;
    uint32_t selection_count, primary, focused, enabled, composing;
} ZdaMetadata;
typedef struct ZdaGeometryInput {
    uint64_t text_version, projection_version;
    ZdaRect bounds;
    const ZdaCell *cells;
    uint32_t cell_count;
    double scale;
    const ZdaCaret *carets;
    uint32_t caret_count;
    const ZdaLine *lines;
    uint32_t line_count;
} ZdaGeometryInput;
/* Full input routes and their authorization domain are separate. Domain zero
   uses the viewport; one additionally requires an actual visible line region. */
typedef struct ZdaHitInput {
    uint64_t revision,text_version,projection_version,geometry_generation;
    double scale;
    uint32_t domain,reserved;
    ZdeHitPacket packet;
} ZdaHitInput;
typedef struct ZdaActionView {
    void *context;
    uint64_t text_version, revision, presentation_epoch;
    uint32_t source, kind, start, end, align_top;
} ZdaActionView;
enum { ZDA_FOCUS = 1, ZDA_SELECT, ZDA_ADD_SELECTION, ZDA_REMOVE_SELECTION, ZDA_SCROLL };
typedef int (*ZdaEnqueue)(void *, void *);
/* Owner operations are main-thread only. Detached and late COM objects own
   native state exclusively. No source pointer below is retained after create. */
int zda_native_create(void *hwnd, const ZdaSource *sources, uint32_t count,
    uint64_t byte_limit, uint32_t range_limit, uint32_t output_units,
    ZdaEnqueue enqueue, void *context, ZdaError *error, ZdaNative **out);
int zda_native_text(ZdaNative *, const ZdaTextInput *, ZdaText **out);
/* Constructor-only opt-in. No word table, ICU word request or lookup on the
   default path; every later Text candidate owns its charged boundary table. */
int zda_native_enable_words(ZdaNative *);
void zda_text_release(ZdaText *);
int zda_native_geometry(ZdaNative *, const ZdaGeometryInput *, ZdaGeometry **out);
int zda_native_geometry_hit(ZdaNative *, uint32_t source, const ZdaGeometryInput *, const ZdaHitInput *, ZdaGeometry **out);
void zda_geometry_release(ZdaGeometry *);
/* Publication takes one ref to every candidate before replacing any source.
   The caller retains candidate ownership and can release it on return. */
int zda_native_publish(ZdaNative *, ZdaText *const *, const ZdaMetadata *, uint32_t);
int zda_native_publish_geometry(ZdaNative *, ZdaGeometry *const *, uint32_t);
int zda_native_enable_mapping(ZdaNative *);
int zda_native_publish_mapped(ZdaNative *, ZdaGeometry *const *, const ZdaMapping *, uint32_t);
/* Optional presentation-scoped actions. No allocation; epoch zero withdraws
   action authorization while publishing an empty geometry bank. */
int zda_native_enable_presentation(ZdaNative *);
int zda_native_publish_presented(ZdaNative *, ZdaGeometry *const *, const ZdaMapping *, uint32_t, uint64_t);
/* Optional two-source subtree. Plans own labels/identity/providers; recorded
   geometry is copied under the same lock as the full-text front and epoch. */
int zda_native_enable_auxiliary(ZdaNative *, uint32_t capacity);
int zda_native_enable_auxiliary_mapping(ZdaNative *);
int zda_native_auxiliary(ZdaNative *, const ZdaAuxNode *, uint32_t, const uint16_t *, uint32_t, ZdaAuxPlan **);
void zda_auxiliary_release(ZdaAuxPlan *);
int zda_native_publish_auxiliary(ZdaNative *, ZdaGeometry *const *, uint32_t, uint64_t, ZdaAuxPlan *, const ZdaAuxGeometry *, uint32_t, double);
int zda_native_publish_auxiliary_mapped(ZdaNative *, ZdaGeometry *const *, const ZdaMapping *, uint32_t, uint64_t, ZdaAuxPlan *, const ZdaAuxGeometry *, uint32_t, double, const ZdaMapping *, const ZdaPublication *);
void *zda_native_auxiliary_provider(ZdaNative *, const ZdaAuxKey *);
int zda_native_auxiliary_accepted(ZdaNative *, uint64_t frame_id, ZdaAuxAccepted *);
int zda_native_auxiliary_accepted_key(ZdaNative *, const ZdaAuxKey *, ZdaAuxAccepted *);
int zda_native_take_auxiliary_action(void *, ZdaAuxAction *);
void zda_native_invalidate(ZdaNative *, uint32_t source);
/* Non-incrementing fail-closed retirement, including at serial exhaustion.
   A set bit also withdraws that source's now-observed stale full Text. */
void zda_native_withdraw_geometry(ZdaNative *, uint32_t invalid_text_mask);
int zda_native_position(ZdaNative *, double screen_x, double screen_y, double scale);
void zda_native_begin_close(ZdaNative *);
int32_t zda_native_disconnect(ZdaNative *);
intptr_t zda_native_object(ZdaNative *, uintptr_t wp, intptr_t lp);
void *zda_native_provider(ZdaNative *, uint32_t source);
void zda_native_stats(ZdaNative *, ZdaStats *);
/* Owned native-only account reference for explicitly charged host staging. */
ZdaAccount *zda_native_account(ZdaNative *);
int zda_native_take_action(void *, ZdaActionView *);
void zda_native_finish_action(void *);
#endif
