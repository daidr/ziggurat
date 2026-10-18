#ifndef ZIGGURAT_COVERAGE_RESOURCE_H
#define ZIGGURAT_COVERAGE_RESOURCE_H
#include <stdint.h>
#include <stddef.h>
/* Copy this descriptor before returning; its caller may use stack storage. */
typedef struct ZgCoverage {const uint8_t *pixels;size_t byte_len;uint32_t width,height,stride;int32_t origin_x,origin_y;float scale;} ZgCoverage;
_Static_assert(offsetof(ZgCoverage,width)==2*sizeof(void *),"coverage dimension offset");
#if UINTPTR_MAX == UINT64_MAX
_Static_assert(sizeof(ZgCoverage)==40,"64-bit coverage bridge layout");
#endif
#endif
