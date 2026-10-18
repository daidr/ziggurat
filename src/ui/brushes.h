#ifndef ZIGGURAT_BRUSHES_H
#define ZIGGURAT_BRUSHES_H
#include <stdint.h>
#define ZG_BRUSH_CAPACITY 32
#define ZG_STOP_CAPACITY 16
enum { ZG_BRUSH_LINEAR, ZG_BRUSH_RADIAL, ZG_BRUSH_CONIC };
typedef struct ZgStop {float offset;uint32_t rgba;} ZgStop;
typedef struct ZgBrush {uint32_t kind;float x0,y0,x1,y1;uint32_t len;ZgStop stops[ZG_STOP_CAPACITY];} ZgBrush;
_Static_assert(sizeof(ZgBrush)==152,"gradient bridge layout");
#endif
