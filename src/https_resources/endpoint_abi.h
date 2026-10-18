#ifndef ZIGGURAT_HTTPS_ENDPOINT_ABI_H
#define ZIGGURAT_HTTPS_ENDPOINT_ABI_H
#include <stddef.h>
#include <stdint.h>

/* Platform-neutral descriptor ABI. All byte pointers borrow their documented
 * call scope; native owners and callbacks carry independent physical refs. */
typedef struct ZhrBorrow ZhrBorrow;
typedef struct ZhrTicket ZhrTicket;
typedef struct ZhrSlice { const uint8_t *ptr; size_t length; } ZhrSlice;
typedef struct ZhrHeader { ZhrSlice name,value; } ZhrHeader;
typedef struct ZhrRequest {
    ZhrSlice scheme,host,path,query,method;
    const ZhrHeader *headers;
    size_t header_count;
    uint16_t port,local_port;
    uint8_t local_ip[4],peer_ip[4];
    uint32_t flags; /* bit0 HTTP/1.1; bit1 userinfo; bit2 fragment; bit3 query */
} ZhrRequest;
typedef struct ZhrOptions {
    size_t bytes;
    uint32_t pending,port,file_streams;
    ZhrSlice prefix;
} ZhrOptions;
typedef struct ZhrResponse {
    uint32_t status;
    ZhrSlice mime;
    const ZhrHeader *headers;
    size_t header_count;
    ZhrSlice body;
    uint64_t length;
} ZhrResponse;
typedef struct ZhrTarget { ZhrBorrow *borrow; ZhrTicket *ticket; } ZhrTarget;
typedef struct ZhrStats {
    size_t bytes,peak_bytes,queued_payload_reservation;
    uint32_t physical_pending,accepting;
} ZhrStats;
typedef struct ZhrCounts {
    uint32_t owners,gates,operations,tickets;
    size_t bytes,queued_payload_reservation;
} ZhrCounts;

#endif
