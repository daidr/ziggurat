#ifndef ZIGGURAT_WEBKIT_CONTENT_RULES_H
#define ZIGGURAT_WEBKIT_CONTENT_RULES_H
#include <stddef.h>
#include <stdint.h>

enum ZwkContentResult { ZWK_CONTENT_OK=0, ZWK_CONTENT_INVALID=1, ZWK_CONTENT_OOM=2, ZWK_CONTENT_STORAGE=3 };
typedef struct ZwkContentCompile ZwkContentCompile;
/* filter is a new WebKitUserContentFilter reference the callee owns, or NULL
 * with the engine's GError domain and code; invalid tells rules the engine
 * rejected from other failures. Never called after zwk_content_cancel. */
typedef void (*ZwkContentDone)(void *context,void *filter,int invalid,uint32_t domain,int32_t code);

/* Loads the list kept as identifier in the store at directory, or compiles
 * rules into it and removes the store's lists of id under other identifiers. */
int zwk_content_compile(const char *directory,const char *id,const char *identifier,const char *rules,size_t length,ZwkContentDone done,void *context,ZwkContentCompile **out);
void zwk_content_cancel(ZwkContentCompile *);
void zwk_content_filter_unref(void *filter);
const char *zwk_content_filter_identifier(void *filter);
uint32_t zwk_content_compile_count(void);
#endif
