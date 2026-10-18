#ifndef ZIGGURAT_DOCUMENT_ACCESSIBILITY_LINUX_INTERNAL_H
#define ZIGGURAT_DOCUMENT_ACCESSIBILITY_LINUX_INTERNAL_H
#include "native.h"
#include "../platform/linux_accessibility_host.h"
#include <gtk/gtk.h>
#include <stdatomic.h>
#include <stdbool.h>

struct ZdaText {
    atomic_uint refs;
    ZdaAccount *account;
    uint64_t version;
    uint32_t length, scalar_count, paragraph_count;
    uint16_t *text;
    uint32_t *scalars, *paragraphs;
};
struct ZdaGeometry {
    atomic_uint refs;
    ZdaAccount *account;
    uint64_t version, projection_version;
    double scale;
    ZdaRect bounds;
    uint32_t cell_count, caret_count, line_count;
    ZdaCell *cells;
    ZdaCaret *carets;
    ZdaLine *lines;
    const ZdaHitInput *hit; /* Interior owned data in this same allocation. */
};
/* One GObject is both State and the sole document provider. Counts report
 * these two roles separately; the physical object is charged only once. */
struct ZdaNative {
    AtkObject parent;
    GThread *owner;
    ZdaAccount *account;
    ZlgAccessibilityBinding *binding;
    ZdaText *text;
    ZdaGeometry *geometry;
    uint64_t revision;
    uint32_t output_units, caret;
    gboolean closed, ready, enabled, composing;
    /* Original-area logical positions, not physical screen pixels. */
    int32_t window_x, window_y, screen_x, screen_y;
    uint32_t position_flags, area_width, area_height, scale;
};
typedef struct ZdaNativeClass { AtkObjectClass parent; } ZdaNativeClass;
enum { ZDA_LINUX_BUSY=6, ZDA_LINUX_UNSUPPORTED=7 };

int zda_linux_create(const ZdaSource *, uint32_t, uint64_t, uint32_t,
    uint32_t, ZdaError *, ZdaNative **);
int zda_linux_prepare(ZdaNative *, void *);
int zda_linux_mount(ZdaNative *);
int zda_linux_live(ZdaNative *);
int zda_linux_position(ZdaNative *, double *);
int zda_linux_geometry_hit(ZdaNative *,const ZdaGeometryInput *,const ZdaHitInput *,ZdaGeometry **);
void zda_linux_retain(ZdaNative *);
void zda_linux_release(ZdaNative *);
GType zda_linux_provider_get_type(void);
void *zda_linux_allocate(size_t);
int zda_linux_object_reserve(ZdaAccount *, size_t);
void zda_linux_object_release(ZdaAccount *, size_t);
void zda_text_retain(ZdaText *);
void zda_geometry_retain(ZdaGeometry *);
gboolean zda_linux_owner(const ZdaNative *);
gboolean zda_linux_boundary(const ZdaText *, uint32_t);
int32_t zda_linux_scalar(const ZdaText *, uint32_t);
char *zda_linux_utf8(const ZdaText *, uint32_t, uint32_t, ZdaAccount *, int *);
void zda_linux_mark(void *);
void zda_linux_drop_current(ZdaNative *);
void zda_linux_notify_text(ZdaNative *, uint32_t, const char *, uint32_t, const char *);
void zda_linux_notify_geometry(ZdaNative *);

#ifdef ZDA_LINUX_TESTING
void zda_linux_test_fail_after(int);
#endif
#endif
