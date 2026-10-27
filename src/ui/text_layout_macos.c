/* Core Text layout is not implemented yet: Engine.create reports
   UnsupportedPlatform on macOS before any of these run. They keep the
   native ABI linkable. */
#include <string.h>
#include "text_layout_native.h"
static int unavailable(ZtlError *error){if(error)*error=(ZtlError){0};return ZTL_FAILED;}
int ztl_engine_init(void *storage,ZtlError *error){(void)storage;return unavailable(error);}
void ztl_engine_close(void *storage){(void)storage;}
int ztl_layout_init(void *storage,void *engine,const char *text,uint32_t length,const uint16_t *utf16,uint32_t length16,const ZtlOptions *options,ZtlError *error){(void)storage;(void)engine;(void)text;(void)length;(void)utf16;(void)length16;(void)options;return unavailable(error);}
void ztl_layout_close(void *storage){(void)storage;}
int ztl_metrics(void *storage,ZtlMetrics *out,ZtlError *error){(void)storage;(void)out;return unavailable(error);}
int ztl_graphemes(void *storage,uint32_t *positions,uint32_t capacity,uint32_t *count,ZtlError *error){(void)storage;(void)positions;(void)capacity;(void)count;return unavailable(error);}
int ztl_word_ranges(void *storage,const char *locale,uint32_t *ends,uint32_t capacity,uint32_t *count,ZtlError *error){(void)storage;(void)locale;(void)ends;(void)capacity;(void)count;return unavailable(error);}
int ztl_lines(void *storage,ZtlLine *out,uint32_t capacity,uint32_t *count,ZtlError *error){(void)storage;(void)out;(void)capacity;(void)count;return unavailable(error);}
int ztl_caret(void *storage,uint32_t position,int trailing,ZtlRect *out,ZtlError *error){(void)storage;(void)position;(void)trailing;(void)out;return unavailable(error);}
int ztl_spans(void *storage,uint32_t start,uint32_t end,ZtlRect *out,uint32_t capacity,uint32_t *count,ZtlError *error){(void)storage;(void)start;(void)end;(void)out;(void)capacity;(void)count;return unavailable(error);}
int ztl_cells(void *storage,ZtlCell *cells,uint32_t count,ZtlError *error){(void)storage;(void)cells;(void)count;return unavailable(error);}
int ztl_snapshot_needs(void *storage,uint32_t *clusters,uint32_t *ranges,ZtlError *error){(void)storage;(void)clusters;(void)ranges;return unavailable(error);}
int ztl_snapshot_cells(void *storage,ZtlCell *cells,uint32_t count,void *clusters,uint32_t nc,void *ranges,uint32_t nr,ZtlError *error){(void)storage;(void)cells;(void)count;(void)clusters;(void)nc;(void)ranges;(void)nr;return unavailable(error);}
void ztl_snapshot_stats(void *storage,ZtlSnapshotStats *out){(void)storage;memset(out,0,sizeof(*out));}
void ztl_finish_snapshot(void *storage){(void)storage;}
int ztl_ink_bounds(void *storage,ZtlRect *out,ZtlError *error){(void)storage;(void)out;return unavailable(error);}
int ztl_outline(void *storage,ZtlOutlineSegment *segments,uint32_t capacity,uint32_t *count,ZtlGlyphCell *cells,uint32_t cell_capacity,uint32_t *cell_count,ZtlError *error){(void)storage;(void)segments;(void)capacity;(void)count;(void)cells;(void)cell_capacity;(void)cell_count;if(error)*error=(ZtlError){0};return ZTL_UNSUPPORTED_OUTLINE;}
int ztl_outline_mapping(void *storage,ZtlOutlineSegment *segments,uint32_t capacity,uint32_t *count,ZtlOutlineMapping *mapping,ZtlError *error){(void)storage;(void)segments;(void)capacity;(void)count;(void)mapping;if(error)*error=(ZtlError){0};return ZTL_UNSUPPORTED_MAPPING;}
int ztl_prepare(void *storage,void *layout,float scale,int32_t left,int32_t top,uint32_t width,uint32_t height,uint32_t stride,uint8_t *mask,const ZtlRect *clip,ZtlError *error){memset(storage,0,ZTL_STORAGE);(void)layout;(void)scale;(void)left;(void)top;(void)width;(void)height;(void)stride;(void)mask;(void)clip;return unavailable(error);}
void ztl_prepared_close(void *storage){(void)storage;}
void *ztl_native_layout(void *storage){(void)storage;return NULL;}
void *ztl_native_coverage(void *storage){(void)storage;return NULL;}
uint32_t ztl_prepared_count(void){return 0;}
void ztl_resources(uint32_t *a,uint32_t *b,uint32_t *c,uint32_t *d){*a=*b=*c=*d=0;}
