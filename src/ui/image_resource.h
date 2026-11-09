#ifndef ZIGGURAT_IMAGE_RESOURCE_H
#define ZIGGURAT_IMAGE_RESOURCE_H
#include <stddef.h>
#include <stdint.h>
#define ZI_IMAGE_SLOTS 32
#define ZI_IMAGE_LEVELS 15
typedef struct ZiImageLevel {const uint8_t *pixels;size_t byte_len;uint32_t width,height,stride;} ZiImageLevel;
typedef struct ZiImageRect {float x,y,width,height;} ZiImageRect;
typedef struct ZiImagePlan {ZiImageRect destination,source;uint32_t level,sampling;float opacity;} ZiImagePlan;
/* A frame of video where its decoder left it (drawing.VideoPicture): format
   0 is NV12 (luma, then chroma of half the size both ways, Cb and Cr
   interleaved), 1 BGRA; matrix 0 to 2 is BT.601, 709 and 2020 in the
   limited range, plus 3 for the full range. */
#define ZI_VIDEO_NV12 0u
#define ZI_VIDEO_BGRA 1u
typedef struct ZiVideoPicture {
    uint32_t width,height,format,matrix;
    const uint8_t *planes[2];uint32_t strides[2];
    void *native;uint32_t element,native_id;
    void *read;void *read_context;
} ZiVideoPicture;
#endif
