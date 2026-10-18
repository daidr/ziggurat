#ifndef ZIGGURAT_GRADIENT_INTERPOLATION_NATIVE_H
#define ZIGGURAT_GRADIENT_INTERPOLATION_NATIVE_H
#include <stdint.h>
#include <stddef.h>
#ifndef ZG_E_GRADIENT_PRECISION
#define ZG_E_GRADIENT_PRECISION ((HRESULT)0x88995001)
#endif

/* This bridge contains no shader or reference to its optional archive member.
   The ordinary renderer owns exactly one nullable pointer to this prefix. */
typedef struct ZgInterpolationPacket {
    uint32_t space, len, reserved[2];
    float colors[16][4];
} ZgInterpolationPacket;
typedef struct ZgInterpolationStats {
    uint64_t metadata_reserved, metadata_actual, constant_uploads;
    uint32_t ready, effect_creations, draws, device_losses;
} ZgInterpolationStats;
typedef struct ZgInterpolation ZgInterpolation;
typedef struct ZgInterpolationOps {
    void (*lose)(ZgInterpolation *);
    void (*destroy)(ZgInterpolation *);
    void (*stats)(ZgInterpolation *, ZgInterpolationStats *);
    HRESULT (*draw)(ZgInterpolation *, ID2D1DeviceContext *, float, float, float, float,
                    float, float, double, uint32_t, uint32_t, const ZgBrush *, const ZgInterpolationPacket *);
} ZgInterpolationOps;
struct ZgInterpolation {
    const ZgInterpolationOps *ops;
    ZgInterpolationStats stats;
};
_Static_assert(sizeof(ZgInterpolationPacket)==272,"interpolation packet ABI");
_Static_assert(sizeof(ZgInterpolationStats)==40,"interpolation stats ABI");
_Static_assert(offsetof(ZgInterpolationPacket,colors)==16,"interpolation colors ABI");

/* The optional program reports physical references through this C-only sink.
   No callback stores a renderer, App, Window or Zig allocation. */
void zgpu_interpolation_account(int delta);
#endif
