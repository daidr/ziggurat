#ifndef ZIGGURAT_TEXT_LAYOUT_OUTLINE_WINDOWS_H
#define ZIGGURAT_TEXT_LAYOUT_OUTLINE_WINDOWS_H

/* The immutable layout supplies its original font, offsets, advances and bidi
   runs. The sink only counts/copies contours; it never shapes text. */
struct OutlineSink {
    ID2D1SimplifiedGeometrySink iface;
    LONG references;
    ZtlOutlineSegment *output;
    uint32_t capacity,count;
    ZtlGlyphCell *cells;
    uint32_t cell_capacity,cell_count;
    FLOAT x,y;
    int exceeded,unsupported;
    ZtlOutlineMapping *mapping;
    int work_exceeded;
};
_Static_assert(sizeof(ZtlOutlineSegment)==28,"outline segment ABI");
_Static_assert(sizeof(ZtlGlyphCell)==32,"glyph cell ABI");
static HRESULT STDMETHODCALLTYPE outline_query(IUnknown *iface,REFIID id,void **out){
    if(!out)return E_POINTER;*out=NULL;
    if(!IsEqualIID(id,&IID_IUnknown)&&!IsEqualIID(id,&IID_ID2D1SimplifiedGeometrySink))return E_NOINTERFACE;
    *out=iface;InterlockedIncrement(&((OutlineSink *)iface)->references);return S_OK;
}
static ULONG STDMETHODCALLTYPE outline_add(IUnknown *iface){return InterlockedIncrement(&((OutlineSink *)iface)->references);}
static ULONG STDMETHODCALLTYPE outline_release(IUnknown *iface){return InterlockedDecrement(&((OutlineSink *)iface)->references);}
static void outline_emit(OutlineSink *s,ZtlOutlineSegment segment){
    if(s->mapping){if(s->mapping->work==s->mapping->work_limit){s->work_exceeded=1;return;}++s->mapping->work;}
    if(s->count==s->capacity){s->exceeded=1;return;}
    if(s->exceeded||s->unsupported)return;
    if(s->output)s->output[s->count]=segment;
    s->count++;
}
static ZtlOutlinePoint outline_point(OutlineSink *s,D2D1_POINT_2F p){return (ZtlOutlinePoint){p.x+s->x,p.y+s->y};}
static void STDMETHODCALLTYPE outline_fill(ID2D1SimplifiedGeometrySink *iface,D2D1_FILL_MODE mode){if(mode!=D2D1_FILL_MODE_WINDING)((OutlineSink *)iface)->unsupported=1;}
static void STDMETHODCALLTYPE outline_flags(ID2D1SimplifiedGeometrySink *iface,D2D1_PATH_SEGMENT flags){(void)iface;(void)flags;}
static void STDMETHODCALLTYPE outline_begin(ID2D1SimplifiedGeometrySink *iface,D2D1_POINT_2F point,D2D1_FIGURE_BEGIN begin){
    OutlineSink *s=(OutlineSink *)iface;if(begin!=D2D1_FIGURE_BEGIN_FILLED){s->unsupported=1;return;}
    outline_emit(s,(ZtlOutlineSegment){ZTL_OUTLINE_MOVE,{outline_point(s,point),{0},{0}}});
}
static void STDMETHODCALLTYPE outline_lines(ID2D1SimplifiedGeometrySink *iface,const D2D1_POINT_2F *points,UINT count){
    OutlineSink *s=(OutlineSink *)iface;for(UINT i=0;i<count&&!s->exceeded;i++)outline_emit(s,(ZtlOutlineSegment){ZTL_OUTLINE_LINE,{outline_point(s,points[i]),{0},{0}}});
}
static void STDMETHODCALLTYPE outline_beziers(ID2D1SimplifiedGeometrySink *iface,const D2D1_BEZIER_SEGMENT *segments,UINT count){
    OutlineSink *s=(OutlineSink *)iface;for(UINT i=0;i<count&&!s->exceeded;i++)outline_emit(s,(ZtlOutlineSegment){ZTL_OUTLINE_CUBIC,{outline_point(s,segments[i].point1),outline_point(s,segments[i].point2),outline_point(s,segments[i].point3)}});
}
static void STDMETHODCALLTYPE outline_end(ID2D1SimplifiedGeometrySink *iface,D2D1_FIGURE_END end){
    OutlineSink *s=(OutlineSink *)iface;if(end!=D2D1_FIGURE_END_CLOSED){s->unsupported=1;return;}outline_emit(s,(ZtlOutlineSegment){ZTL_OUTLINE_CLOSE,{{0},{0},{0}}});
}
static HRESULT STDMETHODCALLTYPE outline_close(ID2D1SimplifiedGeometrySink *iface){OutlineSink *s=(OutlineSink *)iface;return s->exceeded||s->unsupported?E_FAIL:S_OK;}
static const ID2D1SimplifiedGeometrySinkVtbl outline_vtable={{outline_query,outline_add,outline_release},outline_fill,outline_flags,outline_begin,outline_lines,outline_beziers,outline_end,outline_close};
static HRESULT outline_run(OutlineSink *s,FLOAT x,FLOAT y,const DWRITE_GLYPH_RUN *run){
    if(run->isSideways){s->unsupported=1;return E_FAIL;}
    if(s->cell_capacity){
        if(run->glyphCount>s->cell_capacity-s->cell_count){s->exceeded=1;return E_FAIL;}
        if(s->cells&&run->glyphCount){
            DWRITE_FONT_METRICS metrics;IDWriteFontFace_GetMetrics(run->fontFace,&metrics);
            if(!metrics.designUnitsPerEm){s->unsupported=1;return E_FAIL;}
            const double unit=(double)run->fontEmSize/metrics.designUnitsPerEm;
            const double ascent=metrics.ascent*unit,descent=metrics.descent*unit;
            const double direction=(run->bidiLevel&1)?-1.0:1.0;
            double pen=x;
            for(UINT32 i=0;i<run->glyphCount;i++){
                double advance;
                if(run->glyphAdvances)advance=run->glyphAdvances[i];
                else{
                    DWRITE_GLYPH_METRICS glyph;
                    HRESULT hr=IDWriteFontFace_GetDesignGlyphMetrics(run->fontFace,&run->glyphIndices[i],1,&glyph,FALSE);
                    if(FAILED(hr))return hr;advance=glyph.advanceWidth*unit;
                }
                const double dx=run->glyphOffsets?run->glyphOffsets[i].advanceOffset:0;
                const double dy=run->glyphOffsets?run->glyphOffsets[i].ascenderOffset:0;
                const double first=pen+direction*dx,last=first+direction*advance;
                s->cells[s->cell_count+i]=(ZtlGlyphCell){fmin(first,last),(double)y-dy-ascent,fabs(advance),ascent+descent};
                pen+=direction*advance;
            }
        }
        s->cell_count+=run->glyphCount;
    }
    s->x=x;s->y=y;
    return IDWriteFontFace_GetGlyphRunOutline(run->fontFace,run->fontEmSize,run->glyphIndices,run->glyphAdvances,run->glyphOffsets,run->glyphCount,run->isSideways,(run->bidiLevel&1)!=0,(IDWriteGeometrySink *)&s->iface);
}
int ztl_outline(void *storage,ZtlOutlineSegment *output,uint32_t capacity,uint32_t *count,ZtlGlyphCell *cells,uint32_t cell_capacity,uint32_t *cell_count,ZtlError *error){
    Layout *layout=storage;*error=(ZtlError){0};*count=0;*cell_count=0;
    OutlineSink sink={0};sink.iface.lpVtbl=&outline_vtable;sink.references=1;sink.output=output;sink.capacity=capacity;
    sink.cells=cells;sink.cell_capacity=cell_capacity;
    Probe probe={0};probe.iface.lpVtbl=(IDWriteTextRendererVtbl *)&probe_vtable;probe.refs=1;probe.outline=&sink;
    HRESULT hr=IDWriteTextLayout_Draw(layout->layout,NULL,&probe.iface,0,0);
    if(sink.exceeded)return ZTL_CAPACITY;if(sink.unsupported)return ZTL_UNSUPPORTED_OUTLINE;
    if(FAILED(hr))return status(hr,error);*count=sink.count;*cell_count=sink.cell_count;return ZTL_OK;
}
_Static_assert(sizeof(ZtlOutlineGlyph)==96,"mapped glyph ABI");
_Static_assert(sizeof(ZtlOutlineCluster)==32,"mapped cluster ABI");
struct MappingSink { OutlineSink sink;Layout *layout;ZtlOutlineMapping *map;int result; };
static int mapping_charge(MappingSink *s,uint64_t work){
    if(s->map->cancellation&&__atomic_load_n(s->map->cancellation,__ATOMIC_ACQUIRE)){s->result=ZTL_OUTLINE_CANCELLED;return 0;}
    if(work>s->map->work_limit-s->map->work){s->result=ZTL_OUTLINE_WORK;return 0;}
    s->map->work+=work;return 1;
}
static HRESULT mapping_run(MappingSink *s,FLOAT x,FLOAT y,const DWRITE_GLYPH_RUN *run,const DWRITE_GLYPH_RUN_DESCRIPTION *description){
    ZtlOutlineMapping *map=s->map;
    if(run->isSideways||!description)goto unsupported;
    if(description->textPosition>s->layout->length||description->stringLength>s->layout->length-description->textPosition||
       (description->stringLength&&(!description->clusterMap||!description->string)))goto unsupported;
    if(!mapping_charge(s,description->stringLength+1u))return E_FAIL;
    if(description->stringLength&&memcmp(description->string,s->layout->text+description->textPosition,(size_t)description->stringLength*sizeof(uint16_t)))goto unsupported;
    if(run->glyphCount>map->glyph_capacity-map->glyph_count){s->result=ZTL_CAPACITY;return E_FAIL;}
    if(!run->glyphCount)return S_OK;
    if(!run->glyphAdvances)goto unsupported;
    if(!description->stringLength||description->clusterMap[0]!=0)goto unsupported;
    DWRITE_FONT_METRICS metrics;IDWriteFontFace_GetMetrics(run->fontFace,&metrics);
    if(!metrics.designUnitsPerEm)goto unsupported;
    const double unit=(double)run->fontEmSize/metrics.designUnitsPerEm,ascent=metrics.ascent*unit,descent=metrics.descent*unit;
    const double direction=(run->bidiLevel&1)?-1.0:1.0;
    const uint32_t run_index=map->run_count++;double pen=x;uint32_t glyph_at=0;
    for(uint32_t text_at=0;text_at<description->stringLength;){
        uint32_t text_end=text_at+1;
        while(text_end<description->stringLength&&description->clusterMap[text_end]==description->clusterMap[text_at])++text_end;
        const uint32_t first=description->clusterMap[text_at],end=text_end<description->stringLength?description->clusterMap[text_end]:run->glyphCount;
        // Native glyph arrays are logical order. Reject a noncontiguous source
        // cluster rather than guessing a glyph split from visual ink.
        if(first!=glyph_at||end<=first||end>run->glyphCount)goto unsupported;
        if(map->cluster_count==map->cluster_capacity){s->result=ZTL_CAPACITY;return E_FAIL;}
        const uint32_t cluster_index=map->cluster_count++,glyph_start=map->glyph_count,segment_start=s->sink.count;
        for(uint32_t i=first;i<end;i++){
            if(!mapping_charge(s,2))return E_FAIL;
            const double advance=run->glyphAdvances[i];
            const double dx=run->glyphOffsets?run->glyphOffsets[i].advanceOffset:0,dy=run->glyphOffsets?run->glyphOffsets[i].ascenderOffset:0;
            const double origin=pen+direction*dx,last=origin+direction*advance;
            const uint32_t begin=s->sink.count;
            DWRITE_GLYPH_RUN glyph=*run;glyph.glyphCount=1;glyph.glyphIndices=run->glyphIndices+i;glyph.glyphAdvances=run->glyphAdvances+i;glyph.glyphOffsets=run->glyphOffsets?run->glyphOffsets+i:NULL;
            HRESULT hr=outline_run(&s->sink,(FLOAT)pen,y,&glyph);if(FAILED(hr))return hr;
            if(s->sink.work_exceeded){s->result=ZTL_OUTLINE_WORK;return E_FAIL;}
            if(map->glyphs)map->glyphs[map->glyph_count]=(ZtlOutlineGlyph){run->glyphIndices[i],cluster_index,run_index,run->bidiLevel,{begin,s->sink.count-begin},{pen,y},{origin,(double)y-dy},direction*advance,{fmin(origin,last),(double)y-dy-ascent,fabs(advance),ascent+descent}};
            ++map->glyph_count;pen+=direction*advance;
        }
        if(map->clusters)map->clusters[cluster_index]=(ZtlOutlineCluster){{description->textPosition+text_at,description->textPosition+text_end},{glyph_start,map->glyph_count-glyph_start},{segment_start,s->sink.count-segment_start},run_index,run->bidiLevel};
        glyph_at=end;text_at=text_end;
    }
    return S_OK;
unsupported:s->result=ZTL_UNSUPPORTED_MAPPING;return E_FAIL;
}
int ztl_outline_mapping(void *storage,ZtlOutlineSegment *output,uint32_t capacity,uint32_t *count,ZtlOutlineMapping *map,ZtlError *error){
    Layout *layout=storage;*error=(ZtlError){0};*count=0;
    map->glyph_count=map->cluster_count=map->run_count=0;map->work=0;
    MappingSink sink={0};sink.sink.iface.lpVtbl=&outline_vtable;sink.sink.references=1;sink.sink.output=output;sink.sink.capacity=capacity;sink.sink.mapping=map;sink.layout=layout;sink.map=map;
    Probe probe={0};probe.iface.lpVtbl=(IDWriteTextRendererVtbl *)&probe_vtable;probe.refs=1;probe.mapping=&sink;
    HRESULT hr=IDWriteTextLayout_Draw(layout->layout,NULL,&probe.iface,0,0);
    if(sink.result)return sink.result;
    if(sink.sink.work_exceeded)return ZTL_OUTLINE_WORK;
    if(sink.sink.exceeded)return ZTL_CAPACITY;
    if(sink.sink.unsupported)return ZTL_UNSUPPORTED_OUTLINE;
    if(FAILED(hr))return status(hr,error);
    *count=sink.sink.count;return ZTL_OK;
}
#endif
