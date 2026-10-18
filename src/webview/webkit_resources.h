#ifndef ZIGGURAT_WEBKIT_RESOURCES_H
#define ZIGGURAT_WEBKIT_RESOURCES_H
#include <stdint.h>
#include <stddef.h>
typedef struct ZwkResourceHeader { const char *name,*value; } ZwkResourceHeader;
typedef struct ZwkResponseHeader { const uint8_t *name; uint32_t name_length; const uint8_t *value; uint32_t value_length; } ZwkResponseHeader;
typedef void (*ZwkResourceNotify)(void *,const char *,const char *,const ZwkResourceHeader *,uint32_t,void *);
typedef struct ZwkFile ZwkFile;
typedef struct ZwkFileBudget ZwkFileBudget;
typedef struct ZwkFileControl ZwkFileControl;
int zwk_resources_enable(ZwkState *,ZwkResourceNotify,int dynamic_document,uint32_t max_pending);
int zwk_resource_respond(void *,uint32_t,const uint8_t *,size_t,const uint8_t *,size_t,const ZwkResponseHeader *,uint32_t);
int zwk_resource_defer(void *,uint64_t);
int zwk_resource_respond_deferred(ZwkState *,uint64_t,uint32_t,const uint8_t *,size_t,const uint8_t *,size_t,const ZwkResponseHeader *,uint32_t);
void zwk_resource_cancel(ZwkState *,uint64_t);
void zwk_resource_cancel_all(ZwkState *);
uint32_t zwk_resources_pending(void);
int zwk_resource_respond_file(void *,ZwkFile *,uint64_t,ZwkFileBudget *,uint32_t,const uint8_t *,size_t,const ZwkResponseHeader *,uint32_t,int,ZwkFileControl **);
int zwk_resource_respond_file_deferred(ZwkState *,uint64_t,ZwkFile *,uint64_t,ZwkFileBudget *,uint32_t,const uint8_t *,size_t,const ZwkResponseHeader *,uint32_t,int,ZwkFileControl **);
#endif
