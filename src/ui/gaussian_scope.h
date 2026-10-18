#ifndef ZIGGURAT_GAUSSIAN_SCOPE_H
#define ZIGGURAT_GAUSSIAN_SCOPE_H
#include <stdint.h>
#include <stddef.h>
typedef struct ZgGaussianCapacity {uint32_t source_width,source_height,max_radius;float scale;uint64_t filter_samples;} ZgGaussianCapacity;
typedef struct ZgGaussianCapture {int32_t left,top;uint32_t width,height,radius;float scale;} ZgGaussianCapture;
typedef struct ZgGaussianKernel {float sigma,scale;uint32_t radius,weights[257];} ZgGaussianKernel;
typedef struct ZgGaussianFrame {ZgGaussianCapture capture;ZgGaussianKernel kernel;} ZgGaussianFrame;
_Static_assert(sizeof(ZgGaussianCapacity)==24,"Gaussian capacity ABI");
_Static_assert(sizeof(ZgGaussianCapture)==24,"Gaussian capture ABI");
_Static_assert(sizeof(ZgGaussianKernel)==1040&&offsetof(ZgGaussianKernel,weights)==12,"Gaussian kernel ABI");
static uint64_t zg_filter_samples(const ZgGaussianCapture *c){return (uint64_t)(c->width+2*c->radius)*(c->height+2*c->radius)*(2*c->radius+1)*2;}
static int zg_filter_check(const ZgGaussianCapacity *p,const ZgGaussianCapture *c){return c->radius&&c->radius<=p->max_radius&&c->width&&c->height&&c->width<=p->source_width&&c->height<=p->source_height&&c->scale==p->scale&&zg_filter_samples(c)<=p->filter_samples;}
#endif
