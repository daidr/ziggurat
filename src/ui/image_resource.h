#ifndef ZIGGURAT_IMAGE_RESOURCE_H
#define ZIGGURAT_IMAGE_RESOURCE_H
#include <stddef.h>
#include <stdint.h>
#define ZI_IMAGE_SLOTS 32
#define ZI_IMAGE_LEVELS 15
typedef struct ZiImageLevel {const uint8_t *pixels;size_t byte_len;uint32_t width,height,stride;} ZiImageLevel;
typedef struct ZiImageRect {float x,y,width,height;} ZiImageRect;
typedef struct ZiImagePlan {ZiImageRect destination,source;uint32_t level,sampling;float opacity;} ZiImagePlan;
#endif
