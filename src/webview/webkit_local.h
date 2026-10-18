#ifndef ZIGGURAT_WEBKIT_LOCAL_H
#define ZIGGURAT_WEBKIT_LOCAL_H
#include <stdint.h>
#include <stddef.h>
typedef struct ZwkLocalBudget ZwkLocalBudget;
typedef struct ZwkLocalResource {
    const char *path,*mime;
    size_t path_length,mime_length;
    const uint8_t *bytes;
    size_t length;
} ZwkLocalResource;
/* All strings are construction-stack borrows. NULL value grants any legal
 * observed value; a non-NULL empty string means exact empty. */
typedef struct ZwkLocalHeaderGrant { const char *name,*value; } ZwkLocalHeaderGrant;
typedef struct ZwkLocalPolicy {
    uint32_t methods,header_count,origin_count,reserved;
    const ZwkLocalHeaderGrant *headers;
    const char *const *origins;
} ZwkLocalPolicy;
#define ZWK_LOCAL_POLICY_BYTES (32u*1024u)
typedef struct ZwkLocalOptions {
    const char *scheme,*host,*start_path;
    const ZwkLocalResource *resources;
    uint32_t count,max_response_bytes;
    ZwkLocalBudget *budget;
    int secure,ipc;
    const ZwkLocalPolicy *policy;
} ZwkLocalOptions;
ZwkLocalBudget *zwk_local_budget_new(uint32_t max_live,uint32_t max_bytes);
void zwk_local_budget_limit(ZwkLocalBudget *,uint32_t max_live,uint32_t max_bytes);
void zwk_local_budget_release(ZwkLocalBudget *);
void zwk_local_counts(uint32_t *budgets,uint32_t *streams,uint32_t *bytes);
#endif
