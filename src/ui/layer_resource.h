#ifndef ZIGGURAT_LAYER_RESOURCE_H
#define ZIGGURAT_LAYER_RESOURCE_H
#include <stddef.h>
#include <stdint.h>
typedef struct ZgLayerGroup {float x,y,width,height,mask_x,mask_y;uint32_t opacity,mask_slot;int32_t mask_left,mask_top;float mask_scale;} ZgLayerGroup;
typedef struct ZgTransform {double xx,yx,xy,yy,x0,y0;float source_width,source_height;uint32_t pixel_width,pixel_height;} ZgTransform;
typedef struct ZgLayerStats {uint32_t native_objects,native_restores;uint64_t native_creations,groups,clear_pixels,composite_pixels,committed_frames,aborted_frames;size_t metadata_bytes;} ZgLayerStats;
_Static_assert(sizeof(ZgLayerGroup)==44,"layer group ABI");
_Static_assert(sizeof(ZgTransform)==64,"transform ABI");
_Static_assert(offsetof(ZgTransform,source_width)==48&&offsetof(ZgTransform,pixel_width)==56,"transform offsets");
#if UINTPTR_MAX == UINT64_MAX
_Static_assert(sizeof(ZgLayerStats)==64,"layer statistics ABI");
#endif
#endif
