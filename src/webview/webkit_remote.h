#ifndef ZIGGURAT_WEBKIT_REMOTE_H
#define ZIGGURAT_WEBKIT_REMOTE_H
#include <stdint.h>
typedef struct ZwkRemoteHeader { const char *name,*value; } ZwkRemoteHeader;
typedef struct ZwkRemoteOrigin {
    const char *origin;
    uint32_t flags,methods;
    const ZwkRemoteHeader *headers;
    uint32_t header_count;
    const unsigned char *bearer;
} ZwkRemoteOrigin;
typedef struct ZwkRemoteOptions {
    const char *url,*directory;
    const ZwkRemoteOrigin *origins;
    uint32_t count,timeout_ms;
    int loopback,script_navigation,redirects;
} ZwkRemoteOptions;
#endif
