/* Independent native enumeration: no production mapping entry is called. */
#include <stdint.h>
#include <string.h>
#include <math.h>
#include "../src/ui/text_layout_native.h"
typedef struct Check {
    const char *source;
    uint32_t bytes;
    const ZtlOutlineSegment *segments;
    const ZtlOutlineGlyph *glyphs;
    const ZtlOutlineSource *sources;
    uint32_t segment_count,glyph_count,at,segment_at,limit;
    int failed;
} Check;
static void command(Check *c,ZtlOutlineSegment value){
    if(c->segment_at>=c->limit||memcmp(&value,c->segments+c->segment_at,sizeof(value)))c->failed=1;
    ++c->segment_at;
}
static const ZtlOutlineGlyph *next_glyph(Check *c,uint32_t id,uint32_t level,uint32_t start,uint32_t end,double x,double y,double ox,double oy,double advance,double ascent,double descent){
    if(c->at>=c->glyph_count){c->failed=1;return NULL;}
    const ZtlOutlineGlyph *g=c->glyphs+c->at;
    const ZtlOutlineSource source=c->sources[c->at++];
    if(g->glyph_id!=id||g->bidi_level!=level||source.start!=start||source.end!=end||g->pen.x!=x||g->pen.y!=y||g->origin.x!=ox||g->origin.y!=oy||g->advance!=advance||g->cell.x!=fmin(ox,ox+advance)||g->cell.y!=oy-ascent||g->cell.width!=fabs(advance)||g->cell.height!=ascent+descent||g->mapped_segments.start!=c->segment_at)c->failed=1;
    c->limit=g->mapped_segments.start+g->mapped_segments.count;
    if(c->limit>c->segment_count)c->failed=1;
    return g;
}
#ifdef _WIN32
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d2d1.h>
#include <dwrite.h>
typedef struct Sink {ID2D1SimplifiedGeometrySink iface;Check *check;FLOAT x,y;LONG refs;} Sink;
static HRESULT STDMETHODCALLTYPE sink_query(IUnknown *p,REFIID iid,void **out){if(!out)return E_POINTER;*out=NULL;if(!IsEqualIID(iid,&IID_IUnknown)&&!IsEqualIID(iid,&IID_ID2D1SimplifiedGeometrySink))return E_NOINTERFACE;*out=p;++((Sink *)p)->refs;return S_OK;}
static ULONG STDMETHODCALLTYPE sink_add(IUnknown *p){return ++((Sink *)p)->refs;}
static ULONG STDMETHODCALLTYPE sink_release(IUnknown *p){return --((Sink *)p)->refs;}
static void STDMETHODCALLTYPE sink_fill(ID2D1SimplifiedGeometrySink *p,D2D1_FILL_MODE mode){if(mode!=D2D1_FILL_MODE_WINDING)((Sink *)p)->check->failed=1;}
static void STDMETHODCALLTYPE sink_flags(ID2D1SimplifiedGeometrySink *p,D2D1_PATH_SEGMENT flags){(void)p;(void)flags;}
static ZtlOutlinePoint location(Sink *s,D2D1_POINT_2F p){return (ZtlOutlinePoint){p.x+s->x,p.y+s->y};}
static void STDMETHODCALLTYPE sink_begin(ID2D1SimplifiedGeometrySink *p,D2D1_POINT_2F point,D2D1_FIGURE_BEGIN begin){Sink *s=(Sink *)p;if(begin!=D2D1_FIGURE_BEGIN_FILLED)s->check->failed=1;command(s->check,(ZtlOutlineSegment){ZTL_OUTLINE_MOVE,{location(s,point),{0},{0}}});}
static void STDMETHODCALLTYPE sink_lines(ID2D1SimplifiedGeometrySink *p,const D2D1_POINT_2F *points,UINT n){Sink *s=(Sink *)p;for(UINT i=0;i<n;i++)command(s->check,(ZtlOutlineSegment){ZTL_OUTLINE_LINE,{location(s,points[i]),{0},{0}}});}
static void STDMETHODCALLTYPE sink_curves(ID2D1SimplifiedGeometrySink *p,const D2D1_BEZIER_SEGMENT *curves,UINT n){Sink *s=(Sink *)p;for(UINT i=0;i<n;i++)command(s->check,(ZtlOutlineSegment){ZTL_OUTLINE_CUBIC,{location(s,curves[i].point1),location(s,curves[i].point2),location(s,curves[i].point3)}});}
static void STDMETHODCALLTYPE sink_end(ID2D1SimplifiedGeometrySink *p,D2D1_FIGURE_END end){Sink *s=(Sink *)p;if(end!=D2D1_FIGURE_END_CLOSED)s->check->failed=1;command(s->check,(ZtlOutlineSegment){ZTL_OUTLINE_CLOSE,{{0},{0},{0}}});}
static HRESULT STDMETHODCALLTYPE sink_close(ID2D1SimplifiedGeometrySink *p){return ((Sink *)p)->check->failed?E_FAIL:S_OK;}
static const ID2D1SimplifiedGeometrySinkVtbl sink_vtable={{sink_query,sink_add,sink_release},sink_fill,sink_flags,sink_begin,sink_lines,sink_curves,sink_end,sink_close};
typedef struct Renderer {IDWriteTextRenderer iface;Check check;LONG refs;} Renderer;
static HRESULT STDMETHODCALLTYPE renderer_query(IDWriteTextRenderer *p,REFIID iid,void **out){if(!out)return E_POINTER;*out=NULL;if(!IsEqualIID(iid,&IID_IUnknown)&&!IsEqualIID(iid,&IID_IDWritePixelSnapping)&&!IsEqualIID(iid,&IID_IDWriteTextRenderer))return E_NOINTERFACE;*out=p;++((Renderer *)p)->refs;return S_OK;}
static ULONG STDMETHODCALLTYPE renderer_add(IDWriteTextRenderer *p){return ++((Renderer *)p)->refs;}
static ULONG STDMETHODCALLTYPE renderer_release(IDWriteTextRenderer *p){return --((Renderer *)p)->refs;}
static HRESULT STDMETHODCALLTYPE renderer_snap(IDWriteTextRenderer *p,void *ctx,BOOL *out){(void)p;(void)ctx;*out=TRUE;return S_OK;}
static HRESULT STDMETHODCALLTYPE renderer_transform(IDWriteTextRenderer *p,void *ctx,DWRITE_MATRIX *out){(void)p;(void)ctx;*out=(DWRITE_MATRIX){1,0,0,1,0,0};return S_OK;}
static HRESULT STDMETHODCALLTYPE renderer_scale(IDWriteTextRenderer *p,void *ctx,FLOAT *out){(void)p;(void)ctx;*out=1;return S_OK;}
static uint32_t utf8_at(Check *c,uint32_t utf16){
    uint32_t at=0,units=0;
    while(at<c->bytes&&units<utf16){const unsigned char b=(unsigned char)c->source[at];const uint32_t bytes=b<0x80?1:b<0xe0?2:b<0xf0?3:4;units+=bytes==4?2:1;at+=bytes;}
    if(units!=utf16)c->failed=1;return at;
}
static HRESULT STDMETHODCALLTYPE renderer_glyph(IDWriteTextRenderer *p,void *ctx,FLOAT x,FLOAT y,DWRITE_MEASURING_MODE mode,const DWRITE_GLYPH_RUN *run,const DWRITE_GLYPH_RUN_DESCRIPTION *description,IUnknown *effect){
    (void)ctx;(void)mode;(void)effect;Check *c=&((Renderer *)p)->check;
    if(!description||run->isSideways||(!run->glyphAdvances&&run->glyphCount))return E_FAIL;
    DWRITE_FONT_METRICS metrics;IDWriteFontFace_GetMetrics(run->fontFace,&metrics);
    const double ratio=(double)run->fontEmSize/metrics.designUnitsPerEm,ascent=metrics.ascent*ratio,descent=metrics.descent*ratio,direction=(run->bidiLevel&1)?-1:1;
    double pen=x;
    for(uint32_t i=0;i<run->glyphCount;i++){
        /* Find the source cluster directly from the original character map,
           independently of the production group's forward walk. */
        uint32_t begin=description->stringLength,end=description->stringLength;
        for(uint32_t ch=0;ch<description->stringLength;ch++){
            uint32_t next=run->glyphCount;
            for(uint32_t n=ch+1;n<description->stringLength;n++)if(description->clusterMap[n]!=description->clusterMap[ch]){next=description->clusterMap[n];break;}
            if(i>=description->clusterMap[ch]&&i<next){if(begin==description->stringLength)begin=ch;end=ch+1;}
        }
        const double advance=direction*run->glyphAdvances[i],dx=run->glyphOffsets?run->glyphOffsets[i].advanceOffset:0,dy=run->glyphOffsets?run->glyphOffsets[i].ascenderOffset:0;
        const ZtlOutlineGlyph *g=next_glyph(c,run->glyphIndices[i],run->bidiLevel,utf8_at(c,description->textPosition+begin),utf8_at(c,description->textPosition+end),pen,y,pen+direction*dx,(double)y-dy,advance,ascent,descent);
        if(!g)return E_FAIL;
        Sink sink={0};sink.iface.lpVtbl=&sink_vtable;sink.refs=1;sink.check=c;sink.x=(FLOAT)pen;sink.y=y;
        HRESULT hr=IDWriteFontFace_GetGlyphRunOutline(run->fontFace,run->fontEmSize,run->glyphIndices+i,run->glyphAdvances+i,run->glyphOffsets?run->glyphOffsets+i:NULL,1,FALSE,(run->bidiLevel&1)!=0,(IDWriteGeometrySink *)&sink.iface);
        if(FAILED(hr)||c->segment_at!=c->limit||c->failed)return E_FAIL;
        pen+=advance;
    }
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE renderer_underline(IDWriteTextRenderer *p,void *ctx,FLOAT x,FLOAT y,const DWRITE_UNDERLINE *v,IUnknown *effect){(void)p;(void)ctx;(void)x;(void)y;(void)v;(void)effect;return E_NOTIMPL;}
static HRESULT STDMETHODCALLTYPE renderer_strike(IDWriteTextRenderer *p,void *ctx,FLOAT x,FLOAT y,const DWRITE_STRIKETHROUGH *v,IUnknown *effect){(void)p;(void)ctx;(void)x;(void)y;(void)v;(void)effect;return E_NOTIMPL;}
static HRESULT STDMETHODCALLTYPE renderer_inline(IDWriteTextRenderer *p,void *ctx,FLOAT x,FLOAT y,IDWriteInlineObject *v,BOOL sideways,BOOL rtl,IUnknown *effect){(void)p;(void)ctx;(void)x;(void)y;(void)v;(void)sideways;(void)rtl;(void)effect;return E_NOTIMPL;}
int ztc_check(void *layout,const char *source,uint32_t bytes,const ZtlOutlineSegment *segments,uint32_t count,const ZtlOutlineGlyph *glyphs,const ZtlOutlineSource *sources,uint32_t glyph_count){
    static const IDWriteTextRendererVtbl methods={renderer_query,renderer_add,renderer_release,renderer_snap,renderer_transform,renderer_scale,renderer_glyph,renderer_underline,renderer_strike,renderer_inline};
    Renderer r={0};r.iface.lpVtbl=(IDWriteTextRendererVtbl *)&methods;r.refs=1;r.check=(Check){.source=source,.bytes=bytes,.segments=segments,.segment_count=count,.glyphs=glyphs,.sources=sources,.glyph_count=glyph_count};
    const HRESULT hr=IDWriteTextLayout_Draw((IDWriteTextLayout *)layout,NULL,&r.iface,0,0);
    return FAILED(hr)||r.check.failed||r.check.at!=glyph_count||r.check.segment_at!=count;
}
#else
#include <pango/pangocairo.h>
int ztc_check(void *layout,const char *source,uint32_t bytes,const ZtlOutlineSegment *segments,uint32_t count,const ZtlOutlineGlyph *glyphs,const ZtlOutlineSource *sources,uint32_t glyph_count){
    Check c={.source=source,.bytes=bytes,.segments=segments,.segment_count=count,.glyphs=glyphs,.sources=sources,.glyph_count=glyph_count};
    PangoLayoutIter *iter=pango_layout_get_iter(layout);
    cairo_surface_t *surface=cairo_recording_surface_create(CAIRO_CONTENT_ALPHA,NULL);cairo_t *cr=cairo_create(surface);
    do{
        PangoLayoutRun *run=pango_layout_iter_get_run_readonly(iter);if(!run)continue;
        PangoRectangle position,relative;pango_layout_iter_get_run_extents(iter,NULL,&position);pango_glyph_string_extents(run->glyphs,run->item->analysis.font,NULL,&relative);
        int64_t pen=(int64_t)position.x-relative.x;
        const double baseline=(double)pango_layout_iter_get_run_baseline(iter)/PANGO_SCALE;
        PangoFontMetrics *metrics=pango_font_get_metrics(run->item->analysis.font,run->item->analysis.language);
        const double ascent=(double)pango_font_metrics_get_ascent(metrics)/PANGO_SCALE,descent=(double)pango_font_metrics_get_descent(metrics)/PANGO_SCALE;pango_font_metrics_unref(metrics);
        for(int i=0;i<run->glyphs->num_glyphs;i++){
            const PangoGlyphInfo info=run->glyphs->glyphs[i];const int begin=run->glyphs->log_clusters[i];int end=run->item->length;
            /* log_clusters is byte based, may descend in RTL, and does not
               imply one glyph or one scalar per source cluster. */
            for(int j=0;j<run->glyphs->num_glyphs;j++)if(run->glyphs->log_clusters[j]>begin&&run->glyphs->log_clusters[j]<end)end=run->glyphs->log_clusters[j];
            const double x=(double)pen/PANGO_SCALE,advance=(double)info.geometry.width/PANGO_SCALE;
            if(!next_glyph(&c,info.glyph,run->item->analysis.level,(uint32_t)(run->item->offset+begin),(uint32_t)(run->item->offset+end),x,baseline,x+(double)info.geometry.x_offset/PANGO_SCALE,baseline+(double)info.geometry.y_offset/PANGO_SCALE,advance,ascent,descent))break;
            PangoGlyphString *one=pango_glyph_string_new();pango_glyph_string_set_size(one,1);one->glyphs[0]=info;one->log_clusters[0]=0;
            cairo_new_path(cr);cairo_move_to(cr,x,baseline);pango_cairo_glyph_string_path(cr,run->item->analysis.font,one);pango_glyph_string_free(one);
            cairo_path_t *path=cairo_copy_path(cr);
            if(path->status!=CAIRO_STATUS_SUCCESS)c.failed=1;
            for(int at=0;at<path->num_data;at+=path->data[at].header.length){
                const cairo_path_data_t *d=path->data+at;ZtlOutlineSegment s={0};unsigned points=0;
                switch(d->header.type){case CAIRO_PATH_MOVE_TO:s.kind=ZTL_OUTLINE_MOVE;points=1;break;case CAIRO_PATH_LINE_TO:s.kind=ZTL_OUTLINE_LINE;points=1;break;case CAIRO_PATH_CURVE_TO:s.kind=ZTL_OUTLINE_CUBIC;points=3;break;case CAIRO_PATH_CLOSE_PATH:s.kind=ZTL_OUTLINE_CLOSE;break;default:c.failed=1;break;}
                for(unsigned p=0;p<points;p++)s.points[p]=(ZtlOutlinePoint){(float)d[p+1].point.x,(float)d[p+1].point.y};command(&c,s);
            }
            cairo_path_destroy(path);if(c.segment_at!=c.limit)c.failed=1;pen+=info.geometry.width;
        }
    }while(!c.failed&&pango_layout_iter_next_run(iter));
    cairo_destroy(cr);cairo_surface_destroy(surface);pango_layout_iter_free(iter);
    return c.failed||c.at!=glyph_count||c.segment_at!=count;
}
#endif
