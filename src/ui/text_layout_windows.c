#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <initguid.h>
#include <d2d1.h>
#include <dwrite.h>
#include <dwrite_1.h>
#include <string.h>
#include <math.h>
#include "text_layout_native.h"
#include "text_layout_words_impl.h"
typedef void *(__cdecl *BreakOpen)(int32_t,const char *,const uint16_t *,int32_t,int32_t *);
typedef int32_t (__cdecl *BreakNext)(void *);
typedef void (__cdecl *BreakClose)(void *);
typedef struct Engine {IDWriteFactory *factory;HMODULE unicode;BreakOpen open;BreakNext first,next;BreakClose close;IDWriteFontCollection *fonts;uint64_t fonts_seen;} Engine;
/* The system's fonts and the application's registered ones; NULL, the
   system's alone, while none is registered. */
IDWriteFontCollection *zfont_collection(IDWriteFactory *factory,uint64_t *seen,IDWriteFontCollection **cache);
typedef struct Layout {Engine *engine;IDWriteTextLayout *layout;const uint16_t *text;uint32_t length,cell_count;ZtlCell *cells;ZtlRect terminal;int snapshot;ZtlSnapshotStats stats;} Layout;
enum { CELL_BULK=1,CELL_FALLBACK=2,CELL_CANDIDATE=3 };
static uint32_t cell_at(Layout *,uint32_t);
static int query_caret(Layout *,uint32_t,int,ZtlRect *,ZtlError *);
_Static_assert(sizeof(DWRITE_CLUSTER_METRICS)==8,"cluster scratch ABI");
_Static_assert(sizeof(DWRITE_HIT_TEST_METRICS)==36,"range scratch ABI");
_Static_assert(sizeof(Engine)<=ZTL_STORAGE,"engine storage");
_Static_assert(sizeof(Layout)<=ZTL_STORAGE,"layout storage");
static LONG engines,layouts,references,modules,prepared;
#define OWN(p) do{if(p)InterlockedIncrement(&references);}while(0)
#define DROP(p) do{if(p){IUnknown_Release((IUnknown *)(p));(p)=NULL;InterlockedDecrement(&references);}}while(0)
static int status(HRESULT hr,ZtlError *error){if(SUCCEEDED(hr))return ZTL_OK;*error=(ZtlError){1,(int32_t)hr};return hr==E_OUTOFMEMORY?ZTL_OOM:ZTL_FAILED;}
int ztl_engine_init(void *storage,ZtlError *error){
    Engine *s=storage;memset(s,0,sizeof(*s));*error=(ZtlError){0};
    s->unicode=LoadLibraryExW(L"icu.dll",NULL,LOAD_LIBRARY_SEARCH_SYSTEM32);
    if(!s->unicode){*error=(ZtlError){2,(int32_t)GetLastError()};return ZTL_UNICODE_UNAVAILABLE;}
    InterlockedIncrement(&modules);
    s->open=(BreakOpen)GetProcAddress(s->unicode,"ubrk_open");s->first=(BreakNext)GetProcAddress(s->unicode,"ubrk_first");s->next=(BreakNext)GetProcAddress(s->unicode,"ubrk_next");s->close=(BreakClose)GetProcAddress(s->unicode,"ubrk_close");
    if(!s->open||!s->first||!s->next||!s->close){*error=(ZtlError){2,(int32_t)ERROR_PROC_NOT_FOUND};FreeLibrary(s->unicode);s->unicode=NULL;InterlockedDecrement(&modules);return ZTL_UNICODE_UNAVAILABLE;}
    HRESULT hr=DWriteCreateFactory(DWRITE_FACTORY_TYPE_ISOLATED,&IID_IDWriteFactory,(IUnknown **)&s->factory);OWN(s->factory);
    if(FAILED(hr)){DROP(s->factory);FreeLibrary(s->unicode);s->unicode=NULL;InterlockedDecrement(&modules);return status(hr,error);}
    InterlockedIncrement(&engines);return ZTL_OK;
}
void ztl_engine_close(void *storage){Engine *s=storage;if(s->fonts){IDWriteFontCollection_Release(s->fonts);s->fonts=NULL;}DROP(s->factory);if(s->unicode){FreeLibrary(s->unicode);s->unicode=NULL;InterlockedDecrement(&modules);}InterlockedDecrement(&engines);}
int ztl_layout_init(void *storage,void *engine,const char *utf8,uint32_t n8,const uint16_t *text,uint32_t length,const ZtlOptions *options,ZtlError *error){
    (void)utf8;(void)n8;Layout *s=storage;memset(s,0,sizeof(*s));s->engine=engine;s->text=text;s->length=length;*error=(ZtlError){0};
    WCHAR family[256],locale[128];
    if(!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,options->family[0]?options->family:"Segoe UI",-1,family,256)||!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,options->locale[0]?options->locale:"en-US",-1,locale,128)){*error=(ZtlError){2,(int32_t)GetLastError()};return ZTL_FAILED;}
    IDWriteTextFormat *format=NULL;HRESULT hr=IDWriteFactory_CreateTextFormat(s->engine->factory,family,zfont_collection(s->engine->factory,&s->engine->fonts_seen,&s->engine->fonts),(DWRITE_FONT_WEIGHT)options->weight,options->italic?DWRITE_FONT_STYLE_ITALIC:DWRITE_FONT_STYLE_NORMAL,DWRITE_FONT_STRETCH_NORMAL,options->size,locale,&format);OWN(format);
    if(FAILED(hr))goto done;
    hr=IDWriteTextFormat_SetWordWrapping(format,options->wrap==0?DWRITE_WORD_WRAPPING_NO_WRAP:options->wrap==1?DWRITE_WORD_WRAPPING_WHOLE_WORD:DWRITE_WORD_WRAPPING_WRAP);if(FAILED(hr))goto done;
    hr=IDWriteTextFormat_SetReadingDirection(format,options->rtl?DWRITE_READING_DIRECTION_RIGHT_TO_LEFT:DWRITE_READING_DIRECTION_LEFT_TO_RIGHT);if(FAILED(hr))goto done;
    /* A line as wide as the width fits it: the layout that measured the width
       summed the same advances and may come out a rounding under them, which
       would wrap the line's last cluster. Lines wrap a thousandth of a pixel
       past the width. */
    hr=IDWriteFactory_CreateTextLayout(s->engine->factory,text,length,format,options->wrap?(options->width>0?options->width+1e-3f:options->width):1000000.0f,10000000.0f,&s->layout);OWN(s->layout);
    if(SUCCEEDED(hr)){DWRITE_TEXT_METRICS metrics;hr=IDWriteTextLayout_GetMetrics(s->layout,&metrics);if(SUCCEEDED(hr)&&!options->wrap)hr=IDWriteTextLayout_SetMaxWidth(s->layout,metrics.widthIncludingTrailingWhitespace);if(SUCCEEDED(hr))hr=IDWriteTextLayout_SetMaxHeight(s->layout,metrics.height);}
done:DROP(format);if(FAILED(hr)){DROP(s->layout);return status(hr,error);}InterlockedIncrement(&layouts);return ZTL_OK;
}
void ztl_layout_close(void *storage){Layout *s=storage;DROP(s->layout);InterlockedDecrement(&layouts);}
typedef struct OutlineSink OutlineSink;
typedef struct MappingSink MappingSink;
static HRESULT outline_run(OutlineSink *,FLOAT,FLOAT,const DWRITE_GLYPH_RUN *);
static HRESULT mapping_run(MappingSink *,FLOAT,FLOAT,const DWRITE_GLYPH_RUN *,const DWRITE_GLYPH_RUN_DESCRIPTION *);
typedef struct Probe {IDWriteTextRenderer iface;LONG refs;uint32_t glyphs,missing;IDWriteBitmapRenderTarget *bitmap;IDWriteRenderingParams *params;float scale;Layout *snapshot;ZtlError *error;int failed_result;OutlineSink *outline;MappingSink *mapping;} Probe;
static HRESULT STDMETHODCALLTYPE probe_query(IDWriteTextRenderer *iface,REFIID id,void **out){if(!out)return E_POINTER;*out=NULL;if(!IsEqualIID(id,&IID_IUnknown)&&!IsEqualIID(id,&IID_IDWritePixelSnapping)&&!IsEqualIID(id,&IID_IDWriteTextRenderer))return E_NOINTERFACE;*out=iface;InterlockedIncrement(&((Probe *)iface)->refs);return S_OK;}
static ULONG STDMETHODCALLTYPE probe_add(IDWriteTextRenderer *iface){return InterlockedIncrement(&((Probe *)iface)->refs);}
static ULONG STDMETHODCALLTYPE probe_release(IDWriteTextRenderer *iface){return InterlockedDecrement(&((Probe *)iface)->refs);}
static HRESULT STDMETHODCALLTYPE probe_snap(IDWriteTextRenderer *iface,void *context,BOOL *out){(void)iface;(void)context;*out=TRUE;return S_OK;}
static HRESULT STDMETHODCALLTYPE probe_transform(IDWriteTextRenderer *iface,void *context,DWRITE_MATRIX *out){(void)iface;(void)context;*out=(DWRITE_MATRIX){1,0,0,1,0,0};return S_OK;}
static HRESULT STDMETHODCALLTYPE probe_scale(IDWriteTextRenderer *iface,void *context,FLOAT *out){(void)context;Probe *s=(Probe *)iface;*out=s->bitmap?s->scale:1;return S_OK;}
static HRESULT STDMETHODCALLTYPE probe_glyph(IDWriteTextRenderer *iface,void *context,FLOAT x,FLOAT y,DWRITE_MEASURING_MODE mode,const DWRITE_GLYPH_RUN *run,const DWRITE_GLYPH_RUN_DESCRIPTION *description,IUnknown *effect){
    (void)context;(void)x;(void)y;(void)mode;(void)description;(void)effect;Probe *s=(Probe *)iface;s->glyphs+=run->glyphCount;
    if(s->outline)return outline_run(s->outline,x,y,run);
    if(s->mapping)return mapping_run(s->mapping,x,y,run,description);
    for(UINT32 i=0;i<run->glyphCount;i++)if(!run->glyphIndices[i]&&run->glyphAdvances[i]>0)s->missing++;
    if(s->snapshot&&description){
        Layout *layout=s->snapshot;layout->stats.validation_runs++;
        uint32_t first=cell_at(layout,description->textPosition),last=cell_at(layout,description->textPosition+description->stringLength),test=first;
        while(test<last&&layout->cells[test].valid!=CELL_CANDIDATE)test++;
        if(test<last){
            /* A native glyph run has one font, baseline and bidi level. Check
               its origin/line box against native hit testing before reusing
               exact cluster advances. Validation is deliberately not shared
               with another run: long-document float origins can differ even
               for the same font and nominal baseline offset. */
            ZtlCell *cell=&layout->cells[test];ZtlRect native;
            int result=query_caret(layout,cell->position,0,&native,s->error);if(result!=ZTL_OK){s->failed_result=result;return E_FAIL;}
            float lead=cell->rect.x+(cell->rtl?cell->rect.width:0);
            int valid=lead==native.x&&cell->rect.y==native.y&&cell->rect.height==native.height;
            for(uint32_t ci=first;ci<last;ci++)if(layout->cells[ci].valid==CELL_CANDIDATE)layout->cells[ci].valid=valid?CELL_BULK:CELL_FALLBACK;
        }
    }
    if(s->bitmap)return IDWriteBitmapRenderTarget_DrawGlyphRun(s->bitmap,x,y,mode,run,s->params,RGB(255,255,255),NULL);return S_OK;
}
static HRESULT STDMETHODCALLTYPE probe_underline(IDWriteTextRenderer *iface,void *ctx,FLOAT x,FLOAT y,const DWRITE_UNDERLINE *line,IUnknown *effect){(void)iface;(void)ctx;(void)x;(void)y;(void)line;(void)effect;return S_OK;}
static HRESULT STDMETHODCALLTYPE probe_strike(IDWriteTextRenderer *iface,void *ctx,FLOAT x,FLOAT y,const DWRITE_STRIKETHROUGH *line,IUnknown *effect){(void)iface;(void)ctx;(void)x;(void)y;(void)line;(void)effect;return S_OK;}
static HRESULT STDMETHODCALLTYPE probe_inline(IDWriteTextRenderer *iface,void *ctx,FLOAT x,FLOAT y,IDWriteInlineObject *object,BOOL sideways,BOOL rtl,IUnknown *effect){(void)iface;(void)ctx;(void)x;(void)y;(void)object;(void)sideways;(void)rtl;(void)effect;return E_NOTIMPL;}
static const IDWriteTextRendererVtbl probe_vtable={probe_query,probe_add,probe_release,probe_snap,probe_transform,probe_scale,probe_glyph,probe_underline,probe_strike,probe_inline};
#include "text_layout_outline_windows.h"
int ztl_metrics(void *storage,ZtlMetrics *out,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};DWRITE_TEXT_METRICS metrics;HRESULT hr=IDWriteTextLayout_GetMetrics(s->layout,&metrics);if(FAILED(hr))return status(hr,error);
    Probe probe={0};probe.iface.lpVtbl=(IDWriteTextRendererVtbl *)&probe_vtable;probe.refs=1;s->stats.draw_queries++;hr=IDWriteTextLayout_Draw(s->layout,NULL,&probe.iface,0,0);if(FAILED(hr))return status(hr,error);
    *out=(ZtlMetrics){{metrics.left,metrics.top,metrics.widthIncludingTrailingWhitespace,metrics.height},metrics.lineCount,probe.glyphs,probe.missing};return ZTL_OK;
}
int ztl_graphemes(void *storage,uint32_t *positions,uint32_t capacity,uint32_t *count,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};int32_t code=0;void *iterator=s->engine->open(0,"",s->text,(int32_t)s->length,&code);
    if(!iterator||code>0){if(iterator)s->engine->close(iterator);*error=(ZtlError){3,code};return ZTL_FAILED;}
    uint32_t used=0;int result=ZTL_OK;
    for(int32_t at=s->engine->first(iterator);at>=0;at=s->engine->next(iterator)){if(used==capacity){result=ZTL_CAPACITY;break;}positions[used++]=(uint32_t)at;}
    s->engine->close(iterator);*count=used;return result;
}
#ifdef ZTL_WORD_TESTING
static uint32_t word_calls,word_lookups,word_opens,word_closes;
static int word_missing;
void ztl_word_test_missing(int missing){word_missing=missing;}
void ztl_word_test_counts(uint32_t *calls,uint32_t *lookups,uint32_t *opens,uint32_t *closes){*calls=word_calls;*lookups=word_lookups;*opens=word_opens;*closes=word_closes;}
#define WORD_COUNT(field) (++word_##field)
#else
#define WORD_COUNT(field) ((void)0)
#endif
int ztl_word_ranges(void *storage,const char *locale,uint32_t *ends,uint32_t capacity,uint32_t *count,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};WORD_COUNT(calls);
    if(!count||!locale||(capacity&&!ends))return ZTL_FAILED;
    WORD_COUNT(lookups);
    BreakNext rule_status=(BreakNext)GetProcAddress(s->engine->unicode,"ubrk_getRuleStatus");
#ifdef ZTL_WORD_TESTING
    if(word_missing)rule_status=NULL;
#endif
    if(!rule_status){*error=(ZtlError){2,(int32_t)ERROR_PROC_NOT_FOUND};return ZTL_UNICODE_UNAVAILABLE;}
    ZtlWordWriter writer;int result=ztl_word_writer_init(&writer,ends,capacity,s->length);
    if(result)return result==ZTL_WORD_CAPACITY?ZTL_CAPACITY:ZTL_FAILED;
    /* Enabled-empty still resolved the required export, without an iterator. */
    if(!s->length)return ztl_word_writer_finish(&writer,count)==ZTL_WORD_OK?ZTL_OK:ZTL_FAILED;
    int32_t code=0;void *iterator=s->engine->open(1,locale,s->text,(int32_t)s->length,&code);
    if(iterator)WORD_COUNT(opens);
    if(!iterator||code>0){if(iterator){s->engine->close(iterator);WORD_COUNT(closes);}*error=(ZtlError){3,code};return ZTL_FAILED;}
    int32_t start=s->engine->first(iterator);result=start==0?ZTL_OK:ZTL_FAILED;
    while(result==ZTL_OK){
        int32_t end=s->engine->next(iterator);
        if(end==-1){if((uint32_t)start!=s->length)result=ZTL_FAILED;break;}
        if(end<=start||(uint32_t)end>s->length){result=ZTL_FAILED;break;}
        int32_t kind=rule_status(iterator);
        if(kind<0||kind>=500){result=ZTL_FAILED;break;}
        int written=ztl_word_writer_segment(&writer,(uint32_t)end,kind>=100);
        if(written){result=written==ZTL_WORD_CAPACITY?ZTL_CAPACITY:ZTL_FAILED;break;}
        start=end;
    }
    if(result==ZTL_OK){int done=ztl_word_writer_finish(&writer,count);if(done)result=done==ZTL_WORD_CAPACITY?ZTL_CAPACITY:ZTL_FAILED;}
    s->engine->close(iterator);WORD_COUNT(closes);return result;
}
static uint32_t cell_at(Layout *s,uint32_t position){uint32_t lo=0,hi=s->cell_count;while(lo<hi){uint32_t mid=lo+(hi-lo)/2;if(s->cells[mid].position<position)lo=mid+1;else hi=mid;}return lo;}
static int query_caret(Layout *s,uint32_t position,int trailing,ZtlRect *out,ZtlError *error){
    FLOAT x,y;DWRITE_HIT_TEST_METRICS metrics;s->stats.position_queries++;
    HRESULT hr=IDWriteTextLayout_HitTestTextPosition(s->layout,position,trailing?TRUE:FALSE,&x,&y,&metrics);if(FAILED(hr))return status(hr,error);
    *out=(ZtlRect){x,y,0,metrics.height};return ZTL_OK;
}
int ztl_lines(void *storage,ZtlLine *out,uint32_t capacity,uint32_t *count,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};DWRITE_LINE_METRICS metrics[4096];UINT32 used=0;
    if(capacity>4096)return ZTL_CAPACITY;
    s->stats.line_queries++;HRESULT hr=IDWriteTextLayout_GetLineMetrics(s->layout,metrics,capacity,&used);*count=used;if(hr==E_NOT_SUFFICIENT_BUFFER)return ZTL_CAPACITY;if(FAILED(hr))return status(hr,error);
    uint32_t at=0;
    for(UINT32 i=0;i<used;i++){
        ZtlRect caret;int result=ztl_caret(s,at,0,&caret,error);if(result!=ZTL_OK)return result;FLOAT x=caret.x,y=caret.y;
        /* Native hit positions and range boxes must use the same line top.
           Summing float heights drifts over long documents and misassigns
           later carets to their preceding line. */
        out[i]=(ZtlLine){at,at+metrics[i].length-metrics[i].newlineLength,at+metrics[i].length,x,y,0,metrics[i].height,y+metrics[i].baseline};
        at+=metrics[i].length;
    }
    return ZTL_OK;
}
int ztl_caret(void *storage,uint32_t position,int trailing,ZtlRect *out,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};
    if(s->snapshot){
        if(position==s->length){*out=s->terminal;return ZTL_OK;}
        uint32_t ci=cell_at(s,position);
        if(ci<s->cell_count&&s->cells[ci].position==position&&s->cells[ci].valid==1){ZtlCell *cell=&s->cells[ci];*out=(ZtlRect){cell->rect.x+((!!trailing!=!!cell->rtl)?cell->rect.width:0),cell->rect.y,0,cell->rect.height};return ZTL_OK;}
    }
    return query_caret(s,position,trailing,out,error);
}
int ztl_spans(void *storage,uint32_t start,uint32_t end,ZtlRect *out,uint32_t capacity,uint32_t *count,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};DWRITE_HIT_TEST_METRICS metrics[ZTL_LOCAL_RECTS];UINT32 used=0;
    if(s->snapshot){
        uint32_t first=cell_at(s,start),last=cell_at(s,end);int cached=1;
        for(uint32_t ci=first;ci<last;ci++)if(s->cells[ci].valid!=1){cached=0;break;}
        if(cached){
            for(uint32_t ci=first;ci<last;ci++){
                ZtlRect rect=s->cells[ci].rect;
                for(uint32_t i=0;i<used;){ZtlRect old=out[i];if(rect.y==old.y&&rect.height==old.height&&rect.x<=old.x+old.width&&old.x<=rect.x+rect.width){float right=rect.x+rect.width>old.x+old.width?rect.x+rect.width:old.x+old.width;if(old.x<rect.x)rect.x=old.x;rect.width=right-rect.x;out[i]=out[--used];i=0;}else i++;}
                if(used==capacity)return ZTL_CAPACITY;out[used++]=rect;
            }
            *count=used;return ZTL_OK;
        }
    }
    s->stats.range_queries++;
    HRESULT hr=IDWriteTextLayout_HitTestTextRange(s->layout,start,end-start,0,0,metrics,ZTL_LOCAL_RECTS,&used);*count=used;
    if(hr==E_NOT_SUFFICIENT_BUFFER||used>capacity)return ZTL_CAPACITY;if(FAILED(hr))return status(hr,error);
    for(UINT32 i=0;i<used;i++)out[i]=(ZtlRect){metrics[i].left,metrics[i].top,metrics[i].width,metrics[i].height};return ZTL_OK;
}
int ztl_cells(void *storage,ZtlCell *cells,uint32_t count,ZtlError *error){(void)storage;(void)cells;(void)count;*error=(ZtlError){0};return ZTL_OK;}
int ztl_snapshot_needs(void *storage,uint32_t *clusters,uint32_t *ranges,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};*clusters=0;*ranges=0;
    s->stats.cluster_queries++;HRESULT hr=IDWriteTextLayout_GetClusterMetrics(s->layout,NULL,0,clusters);if(FAILED(hr)&&hr!=E_NOT_SUFFICIENT_BUFFER)return status(hr,error);
    if(s->length){s->stats.range_queries++;hr=IDWriteTextLayout_HitTestTextRange(s->layout,0,s->length,0,0,NULL,0,ranges);if(FAILED(hr)&&hr!=E_NOT_SUFFICIENT_BUFFER)return status(hr,error);}
    return ZTL_OK;
}
/* In-place heapsort keeps arbitrary native island order independent of text
   order, without allocating native scratch behind the caller's budget. */
static void range_sift(DWRITE_HIT_TEST_METRICS *a,uint32_t root,uint32_t n){
    for(;;){uint32_t child=root*2+1;if(child>=n)return;if(child+1<n&&a[child].textPosition<a[child+1].textPosition)child++;if(a[root].textPosition>=a[child].textPosition)return;DWRITE_HIT_TEST_METRICS temp=a[root];a[root]=a[child];a[child]=temp;root=child;}
}
static void range_sort(DWRITE_HIT_TEST_METRICS *a,uint32_t n){for(uint32_t i=n/2;i>0;i--)range_sift(a,i-1,n);for(uint32_t i=n;i>1;i--){DWRITE_HIT_TEST_METRICS temp=a[0];a[0]=a[i-1];a[i-1]=temp;range_sift(a,0,i-1);}}
int ztl_snapshot_cells(void *storage,ZtlCell *cells,uint32_t count,void *cluster_storage,uint32_t cluster_capacity,void *range_storage,uint32_t range_capacity,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};DWRITE_CLUSTER_METRICS *clusters=cluster_storage;DWRITE_HIT_TEST_METRICS *ranges=range_storage;UINT32 nc=0,nr=0;
    s->stats.cluster_queries++;HRESULT hr=IDWriteTextLayout_GetClusterMetrics(s->layout,clusters,cluster_capacity,&nc);if(hr==E_NOT_SUFFICIENT_BUFFER||nc>cluster_capacity)return ZTL_CAPACITY;if(FAILED(hr))return status(hr,error);
    if(s->length){s->stats.range_queries++;hr=IDWriteTextLayout_HitTestTextRange(s->layout,0,s->length,0,0,ranges,range_capacity,&nr);if(hr==E_NOT_SUFFICIENT_BUFFER||nr>range_capacity)return ZTL_CAPACITY;if(FAILED(hr))return status(hr,error);}
    range_sort(ranges,nr);
    int result=query_caret(s,s->length,0,&s->terminal,error);if(result!=ZTL_OK)return result;
    uint32_t position=0,ci=0,ri=0,range_first=0;float advance=0;double grid=1;int grid_valid=1;
    for(uint32_t k=0;k<nc;k++){
        DWRITE_CLUSTER_METRICS cluster=clusters[k];if(!cluster.length||cluster.length>s->length-position)return ZTL_FAILED;
        uint32_t end=position+cluster.length;
        while(ri<nr&&ranges[ri].textPosition+ranges[ri].length<=position){ri++;advance=0;range_first=ci;grid=1;grid_valid=1;}
        int valid=ri<nr&&ranges[ri].textPosition<=position&&end<=ranges[ri].textPosition+ranges[ri].length&&cluster.length==1&&!cluster.isSoftHyphen&&ranges[ri].isText&&!ranges[ri].isTrimmed&&ranges[ri].height==s->terminal.height&&cluster.isRightToLeft==(ranges[ri].bidiLevel&1);
        ZtlRect rect={0};uint32_t rtl=0;
        if(ri<nr){
            DWRITE_HIT_TEST_METRICS range=ranges[ri];rtl=range.bidiLevel&1;
            /* Only exact dyadic arithmetic is reconstructed. A fractional
               font or large coordinate can exceed float's integer mantissa;
               that complete island then keeps the native query oracle. No
               widths are rounded, interpolated or distributed to characters. */
            double values[3]={range.left,range.width,cluster.width};
            for(unsigned v=0;v<3;v++)while(grid<=16777216.0&&floor(values[v]*grid)!=values[v]*grid)grid*=2;
            if(grid>16777216.0||(fabs((double)range.left)+fabs((double)range.width))*grid>16777216.0)grid_valid=0;
            if(advance==0&&position!=range.textPosition)grid_valid=0;
            rect=(ZtlRect){range.left+(rtl?range.width-advance-cluster.width:advance),range.top,cluster.width,range.height};
        }
        while(ci<count&&cells[ci].position<end){if(cells[ci].position<position)return ZTL_FAILED;cells[ci].rect=rect;cells[ci].rtl=rtl;cells[ci].valid=valid?CELL_CANDIDATE:CELL_FALLBACK;ci++;}
        advance+=cluster.width;
        if(ri<nr&&end==ranges[ri].textPosition+ranges[ri].length&&(!grid_valid||advance!=ranges[ri].width))for(uint32_t i=range_first;i<ci;i++)cells[i].valid=CELL_FALLBACK;
        position=end;
    }
    if(position!=s->length||ci!=count)return ZTL_FAILED;
    s->cells=cells;s->cell_count=count;
    Probe probe={0};probe.iface.lpVtbl=(IDWriteTextRendererVtbl *)&probe_vtable;probe.refs=1;probe.snapshot=s;probe.error=error;s->stats.draw_queries++;
    hr=IDWriteTextLayout_Draw(s->layout,NULL,&probe.iface,0,0);if(FAILED(hr))return probe.failed_result?probe.failed_result:status(hr,error);
    for(uint32_t i=0;i<count;i++){if(cells[i].valid==CELL_CANDIDATE)cells[i].valid=CELL_FALLBACK;if(cells[i].valid==CELL_BULK)s->stats.bulk_cells++;else s->stats.fallback_cells++;}
    s->snapshot=1;return ZTL_OK;
}
void ztl_snapshot_stats(void *storage,ZtlSnapshotStats *out){*out=((Layout *)storage)->stats;}
void ztl_finish_snapshot(void *storage){Layout *s=storage;s->cells=NULL;s->cell_count=0;s->snapshot=0;}
int ztl_ink_bounds(void *storage,ZtlRect *out,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};DWRITE_OVERHANG_METRICS ink;HRESULT hr=IDWriteTextLayout_GetOverhangMetrics(s->layout,&ink);if(FAILED(hr))return status(hr,error);
    float right=IDWriteTextLayout_GetMaxWidth(s->layout)+ink.right,bottom=IDWriteTextLayout_GetMaxHeight(s->layout)+ink.bottom;
    *out=(ZtlRect){-ink.left,-ink.top,right+ink.left,bottom+ink.top};return ZTL_OK;
}
int ztl_prepare(void *storage,void *layout,float scale,int32_t left,int32_t top,uint32_t width,uint32_t height,uint32_t stride,uint8_t *mask,const ZtlRect *clip,ZtlError *error){
    (void)clip;memset(storage,0,ZTL_STORAGE);Layout *s=layout;*error=(ZtlError){0};
    IDWriteGdiInterop *interop=NULL;IDWriteBitmapRenderTarget *bitmap=NULL;IDWriteBitmapRenderTarget1 *bitmap1=NULL;IDWriteRenderingParams *params=NULL;
    HRESULT hr=IDWriteFactory_GetGdiInterop(s->engine->factory,&interop);OWN(interop);if(FAILED(hr))goto done;
    hr=IDWriteGdiInterop_CreateBitmapRenderTarget(interop,NULL,width,height,&bitmap);OWN(bitmap);if(FAILED(hr))goto done;
    hr=IDWriteBitmapRenderTarget_QueryInterface(bitmap,&IID_IDWriteBitmapRenderTarget1,(void **)&bitmap1);OWN(bitmap1);if(FAILED(hr))goto done;
    hr=IDWriteBitmapRenderTarget1_SetTextAntialiasMode(bitmap1,DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE);if(FAILED(hr))goto done;
    hr=IDWriteBitmapRenderTarget_SetPixelsPerDip(bitmap,scale);if(FAILED(hr))goto done;
    hr=IDWriteFactory_CreateRenderingParams(s->engine->factory,&params);OWN(params);if(FAILED(hr))goto done;
    HDC dc=IDWriteBitmapRenderTarget_GetMemoryDC(bitmap);DIBSECTION dib;
    if(GetObjectW(GetCurrentObject(dc,OBJ_BITMAP),sizeof(dib),&dib)!=sizeof(dib)||!dib.dsBm.bmBits||dib.dsBm.bmBitsPixel!=32||dib.dsBm.bmWidthBytes<(LONG)(width*4)){hr=E_FAIL;goto done;}
    memset(dib.dsBm.bmBits,0,(size_t)dib.dsBm.bmWidthBytes*height);
    Probe probe={0};probe.iface.lpVtbl=(IDWriteTextRendererVtbl *)&probe_vtable;probe.refs=1;probe.bitmap=bitmap;probe.params=params;probe.scale=scale;
    hr=IDWriteTextLayout_Draw(s->layout,NULL,&probe.iface,-(float)left/scale,-(float)top/scale);if(FAILED(hr))goto done;
    SetLastError(0);if(!GdiFlush()){hr=HRESULT_FROM_WIN32(GetLastError());if(SUCCEEDED(hr))hr=E_FAIL;goto done;}
    for(uint32_t y=0;y<height;y++){const uint32_t *row=(const uint32_t *)((const uint8_t *)dib.dsBm.bmBits+(size_t)y*dib.dsBm.bmWidthBytes);for(uint32_t x=0;x<width;x++)mask[(size_t)y*stride+x]=(uint8_t)row[x];}
done:DROP(params);DROP(bitmap1);DROP(bitmap);DROP(interop);if(FAILED(hr))return status(hr,error);*(int *)storage=1;InterlockedIncrement(&prepared);return ZTL_OK;
}
void ztl_prepared_close(void *storage){if(*(int *)storage){*(int *)storage=0;InterlockedDecrement(&prepared);}}
void *ztl_native_layout(void *storage){return ((Layout *)storage)->layout;}
void *ztl_native_coverage(void *storage){(void)storage;return NULL;}
uint32_t ztl_prepared_count(void){return (uint32_t)InterlockedCompareExchange(&prepared,0,0);}
void ztl_resources(uint32_t *a,uint32_t *b,uint32_t *c,uint32_t *d){*a=(uint32_t)InterlockedCompareExchange(&engines,0,0);*b=(uint32_t)InterlockedCompareExchange(&layouts,0,0);*c=(uint32_t)InterlockedCompareExchange(&references,0,0);*d=(uint32_t)InterlockedCompareExchange(&modules,0,0);}
