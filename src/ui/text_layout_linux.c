#include <pango/pangocairo.h>
#include <string.h>
#include "text_layout_native.h"
#include "text_layout_words_impl.h"
typedef struct Engine {PangoFontMap *map;uint64_t fonts_seen;} Engine;
/* Fonts the application registered since the map last looked. */
void zfont_refresh(void *map,uint64_t *seen);
typedef struct Layout {PangoLayout *layout;uint32_t length,line_count,cell_count;ZtlLine *lines;ZtlCell *cells;} Layout;
typedef struct Prepared {cairo_surface_t *surface;cairo_pattern_t *pattern;} Prepared;
#include "text_layout_outline_linux.h"
_Static_assert(sizeof(Engine)<=ZTL_STORAGE,"engine storage");
_Static_assert(sizeof(Layout)<=ZTL_STORAGE,"layout storage");
_Static_assert(sizeof(Prepared)<=ZTL_STORAGE,"prepared storage");
static gint engines,layouts,references,prepared;
#define OWN() g_atomic_int_inc(&references)
#define DROP_OBJECT(p) do{if(p){g_object_unref(p);(p)=NULL;g_atomic_int_add(&references,-1);}}while(0)
static float dip(int value){return (float)value/PANGO_SCALE;}
int ztl_engine_init(void *storage,ZtlError *error){
    Engine *s=storage;memset(s,0,sizeof(*s));*error=(ZtlError){0};
    s->map=pango_cairo_font_map_new();if(!s->map)return ZTL_OOM;
    OWN();g_atomic_int_inc(&engines);return ZTL_OK;
}
void ztl_engine_close(void *storage){Engine *s=storage;DROP_OBJECT(s->map);g_atomic_int_add(&engines,-1);}
int ztl_layout_init(void *storage,void *engine,const char *text,uint32_t length,const uint16_t *utf16,uint32_t length16,const ZtlOptions *options,ZtlError *error){
    (void)utf16;(void)length16;Engine *e=engine;Layout *s=storage;memset(s,0,sizeof(*s));*error=(ZtlError){0};
    zfont_refresh(e->map,&e->fonts_seen);
    PangoContext *context=pango_font_map_create_context(e->map);if(!context)return ZTL_OOM;OWN();
    pango_context_set_base_dir(context,options->rtl?PANGO_DIRECTION_RTL:PANGO_DIRECTION_LTR);
    if(options->locale[0])pango_context_set_language(context,pango_language_from_string(options->locale));
    s->layout=pango_layout_new(context);DROP_OBJECT(context);if(!s->layout)return ZTL_OOM;OWN();
    PangoFontDescription *font=pango_font_description_new();
    pango_font_description_set_family(font,options->family[0]?options->family:"Sans");
    pango_font_description_set_absolute_size(font,options->size*PANGO_SCALE);
    pango_font_description_set_weight(font,(PangoWeight)options->weight);
    pango_font_description_set_style(font,options->italic?PANGO_STYLE_ITALIC:PANGO_STYLE_NORMAL);
    pango_layout_set_font_description(s->layout,font);pango_font_description_free(font);
    pango_layout_set_auto_dir(s->layout,FALSE);
    pango_layout_set_alignment(s->layout,options->rtl?PANGO_ALIGN_RIGHT:PANGO_ALIGN_LEFT);
    pango_layout_set_width(s->layout,options->wrap?(int)(options->width*PANGO_SCALE):-1);
    pango_layout_set_wrap(s->layout,options->wrap==1?PANGO_WRAP_WORD:PANGO_WRAP_WORD_CHAR);
    pango_layout_set_text(s->layout,text,(int)length);s->length=length;
    /* Materialize the native runs during explicit creation, before queries. */
    PangoRectangle logical;pango_layout_get_extents(s->layout,NULL,&logical);
    g_atomic_int_inc(&layouts);return ZTL_OK;
}
void ztl_layout_close(void *storage){Layout *s=storage;DROP_OBJECT(s->layout);g_atomic_int_add(&layouts,-1);}
int ztl_metrics(void *storage,ZtlMetrics *out,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};PangoRectangle logical;pango_layout_get_extents(s->layout,NULL,&logical);
    *out=(ZtlMetrics){{dip(logical.x),dip(logical.y),dip(logical.width),dip(logical.height)},(uint32_t)pango_layout_get_line_count(s->layout),0,0};
    PangoLayoutIter *iter=pango_layout_get_iter(s->layout);
    do{PangoLayoutRun *run=pango_layout_iter_get_run_readonly(iter);if(run){out->glyphs+=(uint32_t)run->glyphs->num_glyphs;for(int i=0;i<run->glyphs->num_glyphs;i++)if(run->glyphs->glyphs[i].glyph&PANGO_GLYPH_UNKNOWN_FLAG)out->missing++;}}while(pango_layout_iter_next_run(iter));
    pango_layout_iter_free(iter);return ZTL_OK;
}
int ztl_graphemes(void *storage,uint32_t *positions,uint32_t capacity,uint32_t *count,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};int n=0;const PangoLogAttr *attrs=pango_layout_get_log_attrs_readonly(s->layout,&n);
    const char *text=pango_layout_get_text(s->layout),*at=text;uint32_t used=0;
    for(int i=0;i<n;i++){
        if(attrs[i].is_cursor_position){if(used==capacity)return ZTL_CAPACITY;positions[used++]=(uint32_t)(at-text);}
        if(i+1<n)at=g_utf8_next_char(at);
    }
    *count=used;return ZTL_OK;
}
#ifdef ZTL_WORD_TESTING
static uint32_t word_calls;
void ztl_word_test_missing(int missing){(void)missing;}
void ztl_word_test_counts(uint32_t *calls,uint32_t *lookups,uint32_t *opens,uint32_t *closes){*calls=word_calls;*lookups=0;*opens=0;*closes=0;}
#define WORD_CALL() (++word_calls)
#else
#define WORD_CALL() ((void)0)
#endif
int ztl_word_ranges(void *storage,const char *locale,uint32_t *ends,uint32_t capacity,uint32_t *count,ZtlError *error){
    Layout *s=storage;(void)locale;*error=(ZtlError){0};WORD_CALL();
    if(!count||(capacity&&!ends))return ZTL_FAILED;
    ZtlWordWriter writer;int result=ztl_word_writer_init(&writer,ends,capacity,s->length);
    if(result)return result==ZTL_WORD_CAPACITY?ZTL_CAPACITY:ZTL_FAILED;
    if(!s->length)return ztl_word_writer_finish(&writer,count)==ZTL_WORD_OK?ZTL_OK:ZTL_FAILED;
    int n=0;const PangoLogAttr *attrs=pango_layout_get_log_attrs_readonly(s->layout,&n);
    const char *text=pango_layout_get_text(s->layout),*at=text;
    glong scalars=g_utf8_strlen(text,(gssize)s->length);
    if(!attrs||n<=0||scalars<0||(uint32_t)n!=(uint32_t)scalars+1)return ZTL_FAILED;
    int active=0;
    for(int i=0;i<n;++i){
        uint32_t position=(uint32_t)(at-text);
        if(position>s->length)return ZTL_FAILED;
        if(attrs[i].is_word_end){
            if(!active)return ZTL_FAILED;
            int written=ztl_word_writer_segment(&writer,position,1);
            if(written)return written==ZTL_WORD_CAPACITY?ZTL_CAPACITY:ZTL_FAILED;
            active=0;
        }
        if(attrs[i].is_word_start){
            if(active||position==s->length)return ZTL_FAILED;
            if(writer.next<position){int written=ztl_word_writer_segment(&writer,position,0);if(written)return written==ZTL_WORD_CAPACITY?ZTL_CAPACITY:ZTL_FAILED;}
            active=1;
        }
        if(i+1<n)at=g_utf8_next_char(at);
    }
    if(active||(uint32_t)(at-text)!=s->length)return ZTL_FAILED;
    if(writer.next<s->length){int written=ztl_word_writer_segment(&writer,s->length,0);if(written)return written==ZTL_WORD_CAPACITY?ZTL_CAPACITY:ZTL_FAILED;}
    result=ztl_word_writer_finish(&writer,count);
    return result==ZTL_WORD_OK?ZTL_OK:result==ZTL_WORD_CAPACITY?ZTL_CAPACITY:ZTL_FAILED;
}
int ztl_lines(void *storage,ZtlLine *out,uint32_t capacity,uint32_t *count,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};uint32_t needed=(uint32_t)pango_layout_get_line_count(s->layout);*count=needed;if(needed>capacity)return ZTL_CAPACITY;
    PangoLayoutIter *iter=pango_layout_get_iter(s->layout);uint32_t index=0;
    do{
        PangoLayoutLine *line=pango_layout_iter_get_line_readonly(iter);PangoRectangle logical;pango_layout_iter_get_line_extents(iter,NULL,&logical);
        out[index]=(ZtlLine){(uint32_t)line->start_index,(uint32_t)(line->start_index+line->length),s->length,dip(logical.x),dip(logical.y),dip(logical.width),dip(logical.height),dip(pango_layout_iter_get_baseline(iter))};
        if(index)out[index-1].next=(uint32_t)line->start_index;
        index++;
    }while(pango_layout_iter_next_line(iter));
    pango_layout_iter_free(iter);s->lines=out;s->line_count=needed;return index==needed?ZTL_OK:ZTL_FAILED;
}
static uint32_t cell_at(Layout *s,uint32_t position){
    uint32_t lo=0,hi=s->cell_count;
    while(lo<hi){uint32_t mid=lo+(hi-lo)/2;if(s->cells[mid].position<position)lo=mid+1;else hi=mid;}
    return lo;
}
static uint32_t line_at(Layout *s,uint32_t position){
    uint32_t lo=0,hi=s->line_count;
    while(lo<hi){uint32_t mid=lo+(hi-lo)/2;if(s->lines[mid].start<=position)lo=mid+1;else hi=mid;}
    return lo?lo-1:0;
}
int ztl_cells(void *storage,ZtlCell *cells,uint32_t count,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};s->cells=cells;s->cell_count=count;
    PangoLayoutIter *iter=pango_layout_get_iter(s->layout);
    do{
        int position=pango_layout_iter_get_index(iter);if(position<0||(uint32_t)position>=s->length)continue;
        uint32_t ci=cell_at(s,(uint32_t)position);if(ci==count||cells[ci].position!=(uint32_t)position){pango_layout_iter_free(iter);return ZTL_FAILED;}
        PangoLayoutRun *run=pango_layout_iter_get_run_readonly(iter);if(!run)continue;
        uint32_t li=line_at(s,(uint32_t)position);PangoRectangle rect;pango_layout_iter_get_char_extents(iter,&rect);
        cells[ci].line=li;cells[ci].rect=(ZtlRect){dip(rect.x),s->lines[li].y,dip(rect.width),s->lines[li].height};
        cells[ci].rtl=run->item->analysis.level&1;cells[ci].valid=1;
    }while(pango_layout_iter_next_char(iter));
    pango_layout_iter_free(iter);return ZTL_OK;
}
void ztl_finish_snapshot(void *storage){Layout *s=storage;s->cells=NULL;s->cell_count=0;s->lines=NULL;s->line_count=0;}
int ztl_snapshot_needs(void *storage,uint32_t *clusters,uint32_t *ranges,ZtlError *error){(void)storage;*clusters=0;*ranges=0;*error=(ZtlError){0};return ZTL_OK;}
int ztl_snapshot_cells(void *storage,ZtlCell *cells,uint32_t count,void *clusters,uint32_t nc,void *ranges,uint32_t nr,ZtlError *error){(void)clusters;(void)nc;(void)ranges;(void)nr;return ztl_cells(storage,cells,count,error);}
void ztl_snapshot_stats(void *storage,ZtlSnapshotStats *out){Layout *s=storage;memset(out,0,sizeof(*out));for(uint32_t i=0;i<s->cell_count;i++)if(s->cells[i].valid)out->bulk_cells++;else out->fallback_cells++;}
int ztl_caret(void *storage,uint32_t position,int trailing,ZtlRect *out,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};int line=0,x=0;
    /* index_to_line_x(length) maps to a run's leading edge for RTL. The
       terminal cursor API instead returns the actual paragraph-end edge. */
    if(position==s->length&&!trailing){PangoRectangle pos;pango_layout_get_cursor_pos(s->layout,(int)position,&pos,NULL);ZtlLine *last=&s->lines[s->line_count-1];*out=(ZtlRect){dip(pos.x),last->y,0,last->height};return ZTL_OK;}
    uint32_t ci=cell_at(s,position);
    if(ci<s->cell_count&&s->cells[ci].position==position&&s->cells[ci].valid){
        ZtlCell *cell=&s->cells[ci];float edge=cell->rect.x+((!!trailing!=!!cell->rtl)?cell->rect.width:0);
        *out=(ZtlRect){edge,cell->rect.y,0,cell->rect.height};return ZTL_OK;
    }
    pango_layout_index_to_line_x(s->layout,(int)position,trailing,&line,&x);
    if(line<0||(uint32_t)line>=s->line_count)return ZTL_FAILED;
    *out=(ZtlRect){dip(x)+s->lines[line].x,s->lines[line].y,0,s->lines[line].height};return ZTL_OK;
}
int ztl_spans(void *storage,uint32_t start,uint32_t end,ZtlRect *out,uint32_t capacity,uint32_t *count,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};*count=0;
    uint32_t used=0;
    /* One creation-time character iterator supplied every scalar cell. Merge
       the complete grapheme, including spacing marks and missing-glyph cells.
       A grapheme with distinct visual islands retains distinct rectangles. */
    for(uint32_t ci=cell_at(s,start);ci<s->cell_count&&s->cells[ci].position<end;ci++){
        if(!s->cells[ci].valid)continue;ZtlRect rect=s->cells[ci].rect;
        for(uint32_t i=0;i<used;){
            ZtlRect old=out[i];
            if(rect.y==old.y&&rect.height==old.height&&rect.x<=old.x+old.width&&old.x<=rect.x+rect.width){
                float right=rect.x+rect.width>old.x+old.width?rect.x+rect.width:old.x+old.width;
                if(old.x<rect.x)rect.x=old.x;rect.width=right-rect.x;out[i]=out[--used];i=0;
            }else i++;
        }
        if(used==capacity)return ZTL_CAPACITY;out[used++]=rect;
    }
    *count=used;return ZTL_OK;
}
void ztl_resources(uint32_t *a,uint32_t *b,uint32_t *c,uint32_t *d){*a=(uint32_t)g_atomic_int_get(&engines);*b=(uint32_t)g_atomic_int_get(&layouts);*c=(uint32_t)g_atomic_int_get(&references);*d=0;}
int ztl_ink_bounds(void *storage,ZtlRect *out,ZtlError *error){Layout *s=storage;*error=(ZtlError){0};PangoRectangle ink;pango_layout_get_extents(s->layout,&ink,NULL);*out=(ZtlRect){dip(ink.x),dip(ink.y),dip(ink.width),dip(ink.height)};return ZTL_OK;}
int ztl_prepare(void *storage,void *layout,float scale,int32_t left,int32_t top,uint32_t width,uint32_t height,uint32_t stride,uint8_t *mask,const ZtlRect *clip,ZtlError *error){
    memset(storage,0,ZTL_STORAGE);Layout *s=layout;*error=(ZtlError){0};cairo_surface_t *surface=cairo_image_surface_create_for_data(mask,CAIRO_FORMAT_A8,(int)width,(int)height,(int)stride);
    if(cairo_surface_status(surface)!=CAIRO_STATUS_SUCCESS){cairo_surface_destroy(surface);return ZTL_OOM;}
    cairo_t *cr=cairo_create(surface);cairo_scale(cr,scale,scale);cairo_translate(cr,-(double)left/scale,-(double)top/scale);
    (void)clip; /* The renderer applies the exact viewport once at replay. */
    cairo_set_source_rgba(cr,1,1,1,1);pango_cairo_show_layout(cr,s->layout);
    int result=cairo_status(cr)==CAIRO_STATUS_SUCCESS?ZTL_OK:ZTL_FAILED;cairo_destroy(cr);cairo_surface_flush(surface);
    if(result!=ZTL_OK){cairo_surface_destroy(surface);return result;}
    cairo_pattern_t *pattern=cairo_pattern_create_for_surface(surface);
    if(cairo_pattern_status(pattern)!=CAIRO_STATUS_SUCCESS){cairo_pattern_destroy(pattern);cairo_surface_destroy(surface);return ZTL_OOM;}
    cairo_pattern_set_filter(pattern,CAIRO_FILTER_BILINEAR);
    Prepared *p=storage;p->surface=surface;p->pattern=pattern;OWN();OWN();g_atomic_int_inc(&prepared);return ZTL_OK;
}
void ztl_prepared_close(void *storage){Prepared *p=storage;if(p->surface){cairo_pattern_destroy(p->pattern);cairo_surface_destroy(p->surface);p->pattern=NULL;p->surface=NULL;g_atomic_int_add(&references,-2);g_atomic_int_add(&prepared,-1);}}
void *ztl_native_layout(void *storage){return ((Layout *)storage)->layout;}
void *ztl_native_coverage(void *storage){return ((Prepared *)storage)->pattern;}
uint32_t ztl_prepared_count(void){return (uint32_t)g_atomic_int_get(&prepared);}
