#ifndef ZIGGURAT_PREPARED_HIT_H
#define ZIGGURAT_PREPARED_HIT_H
#include <stdint.h>
#include <stddef.h>
typedef struct ZdeHitRect { float x,y,width,height; } ZdeHitRect;
typedef struct ZdeHitStop { float x; uint32_t affinity; uint64_t position; } ZdeHitStop;
typedef struct ZdeHitLine { float y,height; uint32_t first,count; } ZdeHitLine;
typedef struct ZdeHitBlock { uint32_t first,count; double y,end; } ZdeHitBlock;
typedef struct ZdeHitPlacement { uint32_t block,reserved; double y,native_top,height; } ZdeHitPlacement;
typedef struct ZdeHitResult { uint64_t position; uint32_t affinity,reserved; } ZdeHitResult;
typedef struct ZdeHitPacket {
    ZdeHitRect bounds;
    double scroll_x;
    uint32_t mode,block_count,line_count,stop_count,placement_count,reserved;
    const ZdeHitBlock *blocks;
    const ZdeHitLine *lines;
    const ZdeHitStop *stops;
    const ZdeHitPlacement *placements;
} ZdeHitPacket;
_Static_assert(sizeof(ZdeHitStop)==16 && sizeof(ZdeHitLine)==16 && sizeof(ZdeHitBlock)==24 && sizeof(ZdeHitPlacement)==32 && sizeof(ZdeHitResult)==16,"Prepared hit records ABI");
#if UINTPTR_MAX == UINT64_MAX
_Static_assert(sizeof(ZdeHitPacket)==80 && offsetof(ZdeHitPacket,blocks)==48,"Prepared hit packet ABI");
#endif
/* Complete validation belongs to construction, before an immutable owned copy
 * is exposed. Query borrows only such a packet, pinned by its C geometry owner;
 * it performs no allocation, owner callback, SDK call, or full-table validation. */
int zde_prepared_hit_validate(const ZdeHitPacket *,uint32_t stops,uint32_t lines,uint64_t work,uint64_t position);
int zde_prepared_hit_query(const ZdeHitPacket *,float x,float y,ZdeHitResult *);
#endif
