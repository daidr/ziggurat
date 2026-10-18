#ifndef ZUA_COLLECTION_GEOMETRY_H
#define ZUA_COLLECTION_GEOMETRY_H
#include <stdint.h>
typedef struct CollectionPoint { double x, y; } CollectionPoint;
typedef struct CollectionRect { double x, y, width, height; } CollectionRect;
typedef struct CollectionMapping {
    double forward[6];
    CollectionRect viewport;
    CollectionPoint polygon[132];
    uint32_t count, reserved;
} CollectionMapping;
typedef struct CollectionBounds { CollectionRect rect; uint32_t visible, reserved; } CollectionBounds;
_Static_assert(sizeof(CollectionMapping) == 2200, "collection visible mapping ABI");
_Static_assert(sizeof(CollectionBounds) == 40, "collection row bounds ABI");
/* Private pure-value exports supplied by the UI affine math adapter. They read
   no Window, Context, allocator or Zig-owned address and may run on a native
   request thread after App teardown. Failure preserves the output bytes. */
int zua_collection_row_bounds(const CollectionMapping *, double top, double height,
    double origin_x, double origin_y, double scale, CollectionBounds *);
#endif
