#ifndef ZIGGURAT_TEXT_LAYOUT_NATIVE_H
#define ZIGGURAT_TEXT_LAYOUT_NATIVE_H
#include <stdint.h>
#include <stddef.h>
#define ZTL_STORAGE 256
#define ZTL_LOCAL_RECTS 16
enum { ZTL_OK=0,ZTL_FAILED=1,ZTL_CAPACITY=2,ZTL_UNICODE_UNAVAILABLE=3,ZTL_OOM=4 };
typedef struct ZtlError {uint32_t domain;int32_t code;} ZtlError;
typedef struct ZtlOptions {float size,width;uint32_t weight,italic,wrap,rtl;const char *family,*locale;} ZtlOptions;
typedef struct ZtlRect {float x,y,width,height;} ZtlRect;
typedef struct ZtlLine {uint32_t start,end,next;float x,y,width,height,baseline;} ZtlLine;
typedef struct ZtlMetrics {ZtlRect bounds;uint32_t lines,glyphs,missing;} ZtlMetrics;
typedef struct ZtlCell {uint32_t position,line;ZtlRect rect;uint32_t rtl,valid;} ZtlCell;
typedef struct ZtlSnapshotStats {uint32_t position_queries,range_queries,cluster_queries,line_queries,bulk_cells,fallback_cells,draw_queries,validation_runs;} ZtlSnapshotStats;
typedef struct ZtlOutlinePoint {float x,y;} ZtlOutlinePoint;
typedef struct ZtlOutlineSegment {uint32_t kind;ZtlOutlinePoint points[3];} ZtlOutlineSegment;
typedef struct ZtlGlyphCell {double x,y,width,height;} ZtlGlyphCell;
typedef struct ZtlOutlinePosition {double x,y;} ZtlOutlinePosition;
typedef struct ZtlOutlineRange {uint32_t start,count;} ZtlOutlineRange;
typedef struct ZtlOutlineSource {uint32_t start,end;} ZtlOutlineSource;
typedef struct ZtlOutlineGlyph {
    uint32_t glyph_id,cluster,run,bidi_level;
    ZtlOutlineRange mapped_segments;
    ZtlOutlinePosition pen,origin;
    double advance;
    ZtlGlyphCell cell;
} ZtlOutlineGlyph;
typedef struct ZtlOutlineCluster {
    ZtlOutlineSource source;
    ZtlOutlineRange glyphs,mapped_segments;
    uint32_t run,bidi_level;
} ZtlOutlineCluster;
typedef struct ZtlOutlineMapping {
    ZtlOutlineGlyph *glyphs;
    ZtlOutlineCluster *clusters;
    uint32_t glyph_capacity,cluster_capacity,glyph_count,cluster_count,run_count,reserved;
    const uint8_t *cancellation;
    uint64_t work_limit,work;
} ZtlOutlineMapping;
enum { ZTL_OUTLINE_MOVE=0,ZTL_OUTLINE_LINE=1,ZTL_OUTLINE_CUBIC=2,ZTL_OUTLINE_CLOSE=3,ZTL_UNSUPPORTED_OUTLINE=5,ZTL_OUTLINE_WORK=6,ZTL_UNSUPPORTED_MAPPING=7,ZTL_OUTLINE_CANCELLED=8 };
int ztl_engine_init(void *,ZtlError *);
void ztl_engine_close(void *);
int ztl_layout_init(void *,void *,const char *,uint32_t,const uint16_t *,uint32_t,const ZtlOptions *,ZtlError *);
void ztl_layout_close(void *);
int ztl_metrics(void *,ZtlMetrics *,ZtlError *);
int ztl_graphemes(void *,uint32_t *,uint32_t,uint32_t *,ZtlError *);
/* Explicit opt-in construction only. Ends use this backend's native units;
 * the owning Zig candidate converts/validates final scalar/grapheme endpoints.
 * No output pointer or iterator is retained. Empty opt-in still checks SDK
 * capability, but requires no table or iterator allocation. */
int ztl_word_ranges(void *,const char *,uint32_t *,uint32_t,uint32_t *,ZtlError *);
#ifdef ZTL_WORD_TESTING
void ztl_word_test_missing(int);
void ztl_word_test_counts(uint32_t *,uint32_t *,uint32_t *,uint32_t *);
#endif
int ztl_lines(void *,ZtlLine *,uint32_t,uint32_t *,ZtlError *);
int ztl_caret(void *,uint32_t,int,ZtlRect *,ZtlError *);
int ztl_spans(void *,uint32_t,uint32_t,ZtlRect *,uint32_t,uint32_t *,ZtlError *);
int ztl_cells(void *,ZtlCell *,uint32_t,ZtlError *);
int ztl_snapshot_needs(void *,uint32_t *,uint32_t *,ZtlError *);
int ztl_snapshot_cells(void *,ZtlCell *,uint32_t,void *,uint32_t,void *,uint32_t,ZtlError *);
void ztl_snapshot_stats(void *,ZtlSnapshotStats *);
void ztl_finish_snapshot(void *);
int ztl_ink_bounds(void *,ZtlRect *,ZtlError *);
int ztl_outline(void *,ZtlOutlineSegment *,uint32_t,uint32_t *,ZtlGlyphCell *,uint32_t,uint32_t *,ZtlError *);
int ztl_outline_mapping(void *,ZtlOutlineSegment *,uint32_t,uint32_t *,ZtlOutlineMapping *,ZtlError *);
int ztl_prepare(void *,void *,float,int32_t,int32_t,uint32_t,uint32_t,uint32_t,uint8_t *,const ZtlRect *,ZtlError *);
void ztl_prepared_close(void *);
void *ztl_native_layout(void *);
void *ztl_native_coverage(void *);
uint32_t ztl_prepared_count(void);
void ztl_resources(uint32_t *,uint32_t *,uint32_t *,uint32_t *);
#endif
