#ifndef ZIGGURAT_GAUSSIAN_GPU_NATIVE_H
#define ZIGGURAT_GAUSSIAN_GPU_NATIVE_H
#include "gaussian_scope.h"
#define ZG_E_GAUSSIAN_PRECISION ((HRESULT)0x88995002)
typedef struct ZgGaussianGpu ZgGaussianGpu;
typedef struct ZgGaussianGpuOps {
    void (*lose)(ZgGaussianGpu *);
    void (*destroy)(ZgGaussianGpu *);
    ID2D1Bitmap1 *(*bitmap)(ZgGaussianGpu *,uint32_t);
    HRESULT (*filter)(ZgGaussianGpu *,uint32_t,const ZgGaussianCapture *,const ZgGaussianKernel *);
} ZgGaussianGpuOps;
/* No App, Context, State, Zig allocation or callback is retained. Optional
   program, owned textures and metadata leave through these C-only vtables. */
struct ZgGaussianGpu {
    const ZgGaussianGpuOps *ops;
    ZgGaussianCapacity capacity;
    ZgGaussianFrame frames[4];
    uint64_t visits,passes;
    size_t metadata_bytes;
    uint32_t ready,objects;
};
void zgpu_gaussian_account(int delta);
#endif
