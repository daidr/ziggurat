/* The affine geometry of a published semantic tree, as accessibility.zig's
   NativeGeometry lays it out: each node's local box in its transform space
   and clip chain, with the inverse transform of each space. The macOS and
   Linux bridges keep a copy and find the node at a point through it, so a
   point in the corner a turned control's bounding box covers but the
   control does not is not the control's. */
#ifndef ZIGGURAT_ACCESSIBILITY_GEOMETRY_H
#define ZIGGURAT_ACCESSIBILITY_GEOMETRY_H
#include <math.h>
#include <stdint.h>

#define ZUA_GEOMETRY_SPACES (64 + 64 + 1)
#define ZUA_GEOMETRY_CLIPS 128
#define ZUA_GEOMETRY_NODES 128
#define ZUA_GEOMETRY_CLIP_DEPTH 128

typedef struct ZuaGeometrySpace { double xx, yx, xy, yy, x0, y0; } ZuaGeometrySpace;
typedef struct ZuaGeometryRef { double x, y, width, height; uint32_t space, clip; } ZuaGeometryRef;
typedef struct ZuaGeometry {
    ZuaGeometrySpace spaces[ZUA_GEOMETRY_SPACES];
    ZuaGeometryRef clips[ZUA_GEOMETRY_CLIPS], nodes[ZUA_GEOMETRY_NODES];
    uint32_t space_count, clip_count, node_count;
    double origin_x, origin_y, scale;
} ZuaGeometry;
_Static_assert(sizeof(ZuaGeometrySpace) == 48, "semantic space ABI");
_Static_assert(sizeof(ZuaGeometryRef) == 40, "semantic clip ABI");
_Static_assert(sizeof(ZuaGeometry) == 16472, "semantic geometry ABI");

static inline int zua_geometry_ref_valid(const ZuaGeometry *g, const ZuaGeometryRef *ref, uint32_t max_clip) {
    return ref->space < g->space_count && (ref->clip == UINT32_MAX || ref->clip < max_clip) && isfinite(ref->x) && isfinite(ref->y) &&
        isfinite(ref->width) && isfinite(ref->height) && ref->width >= 0 && ref->height >= 0;
}
/* Whether a copied geometry is whole: every reference names a space and
   an earlier clip, clip chains end, and numbers are finite. */
static inline int zua_geometry_valid(const ZuaGeometry *g, uint32_t count) {
    if (!g->space_count || g->space_count > ZUA_GEOMETRY_SPACES || g->clip_count > ZUA_GEOMETRY_CLIPS || g->node_count != count ||
        count > ZUA_GEOMETRY_NODES || !isfinite(g->origin_x) || !isfinite(g->origin_y) || !isfinite(g->scale) || g->scale <= 0)
        return 0;
    for (uint32_t i = 0; i < g->space_count; i++) {
        const ZuaGeometrySpace *s = &g->spaces[i];
        if (!isfinite(s->xx) || !isfinite(s->yx) || !isfinite(s->xy) || !isfinite(s->yy) || !isfinite(s->x0) || !isfinite(s->y0)) return 0;
    }
    for (uint32_t i = 0; i < g->clip_count; i++) {
        if (!zua_geometry_ref_valid(g, &g->clips[i], i)) return 0;
        uint32_t parent = g->clips[i].clip, depth = 1;
        while (parent != UINT32_MAX) {
            if (++depth > ZUA_GEOMETRY_CLIP_DEPTH) return 0;
            parent = g->clips[parent].clip;
        }
    }
    for (uint32_t i = 0; i < count; i++) if (!zua_geometry_ref_valid(g, &g->nodes[i], g->clip_count)) return 0;
    return 1;
}
static inline int zua_geometry_inside(const ZuaGeometry *g, const ZuaGeometryRef *ref, double wx, double wy) {
    const ZuaGeometrySpace *s = &g->spaces[ref->space];
    double x = s->xx * wx + s->xy * wy + s->x0, y = s->yx * wx + s->yy * wy + s->y0;
    return x >= ref->x && y >= ref->y && x < ref->x + ref->width && y < ref->y + ref->height;
}
/* Whether node `index` holds the point x, y of the published coordinates
   (its NativeNode's): inside its local box and every clip around it. */
static inline int zua_geometry_hit(const ZuaGeometry *g, uint32_t index, double x, double y) {
    if (index >= g->node_count) return 0;
    double wx = (x - g->origin_x) / g->scale, wy = (y - g->origin_y) / g->scale;
    const ZuaGeometryRef *ref = &g->nodes[index];
    if (!zua_geometry_inside(g, ref, wx, wy)) return 0;
    for (uint32_t clip = ref->clip; clip != UINT32_MAX; clip = g->clips[clip].clip)
        if (!zua_geometry_inside(g, &g->clips[clip], wx, wy)) return 0;
    return 1;
}
#endif
