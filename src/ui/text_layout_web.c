/* Browser paragraph layout behind the native text layout ABI. Positions are
   UTF-16 offsets, as the page's strings are. The page measures the text and
   finds its graphemes, words and break opportunities; lines are broken here
   once at creation, and every query reads that result. */
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include "text_layout_native.h"
#include "text_layout_words_impl.h"
#include "coverage_resource.h"

#define IMPORT(name) __attribute__((import_module("ziggurat"),import_name(#name)))
/* Font ascent and descent, in CSS pixels of the font's size. */
IMPORT(zw_layout_font) void zw_layout_font(const char *font,uint32_t font_length,double *metrics);
/* kind 0: grapheme starts; 1: word segment ends then lexical flags;
   2: line break opportunities. Returns the count, or -1 past capacity. */
IMPORT(zw_layout_segments) int32_t zw_layout_segments(const uint16_t *text,uint32_t length,const char *locale,uint32_t locale_length,uint32_t kind,uint32_t *out,uint32_t capacity);
/* The pen's x at each UTF-16 offset 0..length, restarting at hard breaks. */
IMPORT(zw_layout_advances) void zw_layout_advances(const uint16_t *text,uint32_t length,const char *font,uint32_t font_length,float *out);
IMPORT(zw_layout_begin) int zw_layout_begin(uint32_t width,uint32_t height,double scale,double left,double top,const char *font,uint32_t font_length,uint32_t rtl);
IMPORT(zw_layout_draw) void zw_layout_draw(const uint16_t *text,uint32_t length,double x,double baseline);
IMPORT(zw_layout_end) void zw_layout_end(uint8_t *mask,uint32_t stride);

typedef struct Engine {uint32_t reserved;} Engine;
typedef struct LineInfo {uint32_t start,end,next;double x,y,width,height,baseline;} LineInfo;
typedef struct Layout {
    uint16_t *text;float *pen;uint32_t *graphemes;LineInfo *lines;ZtlCell *cells;
    uint32_t length,grapheme_count,line_count,cell_count,glyphs,rtl;
    double left,right,height,ascent;
    char font[512];
} Layout;
/* The coverage the renderer replays: the mask this prepare filled. */
typedef struct Prepared {ZgCoverage coverage;uint32_t live;} Prepared;
_Static_assert(sizeof(Engine)<=ZTL_STORAGE,"engine storage");
_Static_assert(sizeof(Prepared)<=ZTL_STORAGE,"prepared storage");
/* The layout's own storage holds a pointer to its heap state. */
typedef struct Handle {Layout *layout;} Handle;
_Static_assert(sizeof(Handle)<=ZTL_STORAGE,"layout storage");
static int engines,layouts,references,prepared;

static size_t css_font(char *out,size_t capacity,const char *named,float size,uint32_t weight,int italic){
    static const char sans[]="system-ui, -apple-system, \"Segoe UI\", Roboto, \"Helvetica Neue\", Arial, \"Noto Sans\", sans-serif, \"Apple Color Emoji\", \"Segoe UI Emoji\"";
    static const char mono[]="ui-monospace, SFMono-Regular, Menlo, Consolas, \"Liberation Mono\", monospace";
    const int system=!named||!named[0]||!strcmp(named,"Sans")||!strcmp(named,"sans-serif")||!strcmp(named,"system-ui");
    const int fixed=named&&(!strcmp(named,"Monospace")||!strcmp(named,"monospace")||!strcmp(named,"ui-monospace"));
    const int serif=named&&(!strcmp(named,"Serif")||!strcmp(named,"serif")||!strcmp(named,"ui-serif"));
    const char *families=fixed?mono:serif?"ui-serif, Georgia, \"Times New Roman\", serif":sans;
    char quoted[160]="";
    if(!fixed&&!serif&&!system){size_t q=0;quoted[q++]='"';for(const char *c=named;*c&&q+4<sizeof(quoted);c++)if(*c!='"'&&*c!='\\')quoted[q++]=*c;quoted[q++]='"';quoted[q++]=',';quoted[q++]=' ';quoted[q]=0;}
    if(weight<1)weight=400;if(weight>1000)weight=1000;
    const int n=snprintf(out,capacity,"%s%u %.3fpx %s%s",italic?"italic ":"",(unsigned)weight,(double)size,quoted,families);
    return n>0&&(size_t)n<capacity?(size_t)n:0;
}
static int is_break(uint16_t c){return c=='\n'||c=='\r'||c==0x0b||c==0x0c||c==0x85||c==0x2028||c==0x2029;}
static int is_space(uint16_t c){return c==' '||c=='\t'||c==0x3000||c==0xa0||c==0x2009||c==0x200b;}
static Layout *layout_of(void *storage){return ((Handle *)storage)->layout;}

int ztl_engine_init(void *storage,ZtlError *error){memset(storage,0,sizeof(Engine));*error=(ZtlError){0};engines++;return ZTL_OK;}
void ztl_engine_close(void *storage){(void)storage;engines--;}
static void release_layout(Layout *s){
    if(!s)return;
    free(s->text);free(s->pen);free(s->graphemes);free(s->lines);
    if(s->text)references--;
    free(s);
}
static int push_line(Layout *s,uint32_t *capacity,uint32_t start,uint32_t end,uint32_t next){
    if(s->line_count==*capacity){
        uint32_t grown_capacity=*capacity?*capacity*2:8;LineInfo *grown=realloc(s->lines,(size_t)grown_capacity*sizeof(LineInfo));
        if(!grown)return ZTL_OOM;
        s->lines=grown;*capacity=grown_capacity;
    }
    s->lines[s->line_count++]=(LineInfo){.start=start,.end=end,.next=next};return ZTL_OK;
}
/* The pen's distance from start to end, both on one hard line. */
static double advance(const Layout *s,uint32_t start,uint32_t end){return (double)s->pen[end]-(double)s->pen[start];}
static uint32_t visible_end(const Layout *s,uint32_t start,uint32_t end){while(end>start&&is_space(s->text[end-1]))end--;return end;}
/* The grapheme boundary at or before position. */
static uint32_t grapheme_floor(const Layout *s,uint32_t position){
    uint32_t lo=0,hi=s->grapheme_count;
    while(lo<hi){uint32_t mid=lo+(hi-lo)/2;if(s->graphemes[mid]<=position)lo=mid+1;else hi=mid;}
    return lo?s->graphemes[lo-1]:0;
}
static uint32_t grapheme_after(const Layout *s,uint32_t position){
    uint32_t lo=0,hi=s->grapheme_count;
    while(lo<hi){uint32_t mid=lo+(hi-lo)/2;if(s->graphemes[mid]<=position)lo=mid+1;else hi=mid;}
    return lo<s->grapheme_count?s->graphemes[lo]:s->length;
}
/* Greedy breaking of one hard line [start,end) at the page's break
   opportunities; a word wider than the box breaks between graphemes. */
static int break_paragraph(Layout *s,uint32_t *capacity,uint32_t start,uint32_t end,uint32_t after,const uint32_t *breaks,uint32_t break_count,uint32_t *cursor,double width){
    while(*cursor<break_count&&breaks[*cursor]<=start)++*cursor;
    while(start<end){
        uint32_t best=0,k=*cursor;
        for(;k<break_count&&breaks[k]<end;k++){
            if(advance(s,start,visible_end(s,start,breaks[k]))>width)break;
            best=breaks[k];
        }
        if(advance(s,start,visible_end(s,start,end))<=width&&(k==break_count||breaks[k]>=end))best=end;
        if(!best){
            /* Nothing fits: as many graphemes as fit, at least one. */
            uint32_t at=grapheme_after(s,start);
            for(uint32_t next=grapheme_after(s,at);at<end&&next<=end&&advance(s,start,next)<=width;next=grapheme_after(s,next))at=next;
            if(at>end)at=end;
            best=at;
        }
        while(*cursor<break_count&&breaks[*cursor]<=best)++*cursor;
        int result=push_line(s,capacity,start,best,best<end?best:after);if(result)return result;
        start=best;
    }
    return ZTL_OK;
}
int ztl_layout_init(void *storage,void *engine,const char *text,uint32_t length,const uint16_t *utf16,uint32_t length16,const ZtlOptions *options,ZtlError *error){
    (void)engine;(void)text;(void)length;*error=(ZtlError){0};
    Handle *handle=storage;memset(handle,0,sizeof(*handle));
    Layout *s=calloc(1,sizeof(Layout));if(!s)return ZTL_OOM;
    const size_t font_length=css_font(s->font,sizeof(s->font),options->family,options->size,options->weight,(int)options->italic);
    if(!font_length){free(s);return ZTL_FAILED;}
    s->length=length16;s->rtl=options->rtl;
    s->text=malloc(((size_t)length16+1)*sizeof(uint16_t));s->pen=malloc(((size_t)length16+1)*sizeof(float));s->graphemes=malloc(((size_t)length16+1)*sizeof(uint32_t));
    if(!s->text||!s->pen||!s->graphemes){release_layout(s);return ZTL_OOM;}
    references++;
    if(length16)memcpy(s->text,utf16,(size_t)length16*sizeof(uint16_t));s->text[length16]=0;
    const char *locale=options->locale?options->locale:"";const uint32_t locale_length=(uint32_t)strlen(locale);
    double font_metrics[2]={0};zw_layout_font(s->font,(uint32_t)font_length,font_metrics);
    const double ascent=font_metrics[0],descent=font_metrics[1];s->ascent=ascent;
    int32_t graphemes=zw_layout_segments(s->text,length16,locale,locale_length,0,s->graphemes,length16+1);
    if(graphemes<0){release_layout(s);return ZTL_FAILED;}
    s->grapheme_count=(uint32_t)graphemes;
    zw_layout_advances(s->text,length16,s->font,(uint32_t)font_length,s->pen);
    const int wrap=options->wrap&&options->width>0;
    uint32_t *breaks=NULL;uint32_t break_count=0;
    if(wrap&&length16){
        breaks=malloc(((size_t)length16+1)*sizeof(uint32_t));if(!breaks){release_layout(s);return ZTL_OOM;}
        int32_t n=zw_layout_segments(s->text,length16,locale,locale_length,2,breaks,length16+1);
        if(n<0){free(breaks);release_layout(s);return ZTL_FAILED;}
        break_count=(uint32_t)n;
    }
    uint32_t capacity=0,cursor=0;int result=ZTL_OK;
    for(uint32_t start=0;start<length16&&!result;){
        uint32_t end=start;while(end<length16&&!is_break(s->text[end]))end++;
        uint32_t after=end;
        if(after<length16){after+=s->text[after]=='\r'&&after+1<length16&&s->text[after+1]=='\n'?2:1;}
        if(wrap&&end>start)result=break_paragraph(s,&capacity,start,end,after,breaks,break_count,&cursor,options->width);
        else result=push_line(s,&capacity,start,end,after);
        start=after;
    }
    free(breaks);
    /* An empty text, or one ending in a line break, ends with an empty line. */
    if(!result&&(!length16||is_break(s->text[length16-1])))result=push_line(s,&capacity,length16,length16,length16);
    if(result){release_layout(s);return result;}
    double y=0,widest=0;
    for(uint32_t i=0;i<s->line_count;i++){
        LineInfo *line=&s->lines[i];
        line->width=advance(s,line->start,line->end);
        const double visible=advance(s,line->start,visible_end(s,line->start,line->end));
        line->height=ascent+descent;line->y=y;line->baseline=y+ascent;line->x=visible;y+=line->height;
        if(!wrap&&visible>widest)widest=visible;
        for(uint32_t at=line->start;at<line->end;at=grapheme_after(s,at))if(!is_space(s->text[at]))s->glyphs++;
    }
    const double box=wrap?options->width:widest;
    s->left=INFINITY;s->right=-INFINITY;
    for(uint32_t i=0;i<s->line_count;i++){LineInfo *line=&s->lines[i];double visible=line->x;line->x=options->rtl?box-visible:0;if(line->x<s->left)s->left=line->x;if(line->x+line->width>s->right)s->right=line->x+line->width;}
    s->height=y;handle->layout=s;layouts++;return ZTL_OK;
}
void ztl_layout_close(void *storage){release_layout(layout_of(storage));((Handle *)storage)->layout=NULL;layouts--;}
int ztl_metrics(void *storage,ZtlMetrics *out,ZtlError *error){
    Layout *s=layout_of(storage);*error=(ZtlError){0};
    *out=(ZtlMetrics){{(float)s->left,0,(float)(s->right-s->left),(float)s->height},s->line_count,s->glyphs,0};return ZTL_OK;
}
int ztl_graphemes(void *storage,uint32_t *positions,uint32_t capacity,uint32_t *count,ZtlError *error){
    Layout *s=layout_of(storage);*error=(ZtlError){0};
    if(s->grapheme_count+1>capacity)return ZTL_CAPACITY;
    memcpy(positions,s->graphemes,(size_t)s->grapheme_count*sizeof(uint32_t));
    positions[s->grapheme_count]=s->length;*count=s->grapheme_count+1;return ZTL_OK;
}
#ifdef ZTL_WORD_TESTING
static uint32_t word_calls;
void ztl_word_test_missing(int missing){(void)missing;}
void ztl_word_test_counts(uint32_t *calls,uint32_t *lookups,uint32_t *opens,uint32_t *closes){*calls=word_calls;*lookups=0;*opens=0;*closes=0;}
#define WORD_CALL() (++word_calls)
#else
#define WORD_CALL() ((void)0)
#endif
static int word_status(int written){return written==ZTL_WORD_CAPACITY?ZTL_CAPACITY:ZTL_FAILED;}
int ztl_word_ranges(void *storage,const char *locale,uint32_t *ends,uint32_t capacity,uint32_t *count,ZtlError *error){
    Layout *s=layout_of(storage);*error=(ZtlError){0};WORD_CALL();
    if(!count||(capacity&&!ends))return ZTL_FAILED;
    ZtlWordWriter writer;int result=ztl_word_writer_init(&writer,ends,capacity,s->length);
    if(result)return word_status(result);
    if(!s->length)return ztl_word_writer_finish(&writer,count)==ZTL_WORD_OK?ZTL_OK:ZTL_FAILED;
    /* The page writes segment ends, then one lexical flag per segment. */
    uint32_t *segments=malloc((size_t)s->length*2*sizeof(uint32_t));if(!segments)return ZTL_OOM;
    const char *name=locale?locale:"";
    int32_t n=zw_layout_segments(s->text,s->length,name,(uint32_t)strlen(name),1,segments,s->length*2);
    if(n<0){free(segments);return ZTL_FAILED;}
    for(int32_t i=0;i<n&&!result;i++){int written=ztl_word_writer_segment(&writer,segments[i],segments[n+i]?1:0);if(written)result=word_status(written);}
    free(segments);if(result)return result;
    if(writer.next<s->length){int written=ztl_word_writer_segment(&writer,s->length,0);if(written)return word_status(written);}
    result=ztl_word_writer_finish(&writer,count);
    return result==ZTL_WORD_OK?ZTL_OK:word_status(result);
}
int ztl_lines(void *storage,ZtlLine *out,uint32_t capacity,uint32_t *count,ZtlError *error){
    Layout *s=layout_of(storage);*error=(ZtlError){0};*count=s->line_count;if(s->line_count>capacity)return ZTL_CAPACITY;
    for(uint32_t i=0;i<s->line_count;i++){const LineInfo *l=&s->lines[i];out[i]=(ZtlLine){l->start,l->end,l->next,(float)l->x,(float)l->y,(float)l->width,(float)l->height,(float)l->baseline};}
    return ZTL_OK;
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
/* A grapheme's advance is shared evenly by the scalars it covers. */
int ztl_cells(void *storage,ZtlCell *cells,uint32_t count,ZtlError *error){
    Layout *s=layout_of(storage);*error=(ZtlError){0};s->cells=cells;s->cell_count=count;
    for(uint32_t li=0;li<s->line_count;li++){
        const LineInfo *line=&s->lines[li];
        for(uint32_t at=line->start;at<line->end;){
            const uint32_t next=grapheme_after(s,at)<line->end?grapheme_after(s,at):line->end;
            const double x=line->x+advance(s,line->start,at),width=advance(s,at,next);
            uint32_t first=cell_at(s,at),last=first;while(last<count&&cells[last].position<next)last++;
            const uint32_t parts=last-first;
            for(uint32_t k=0;k<parts;k++){
                const float share=(float)(width/parts);
                cells[first+k].line=li;cells[first+k].rtl=0;cells[first+k].valid=1;
                cells[first+k].rect=(ZtlRect){(float)x+share*(float)k,(float)line->y,share,(float)line->height};
            }
            at=next>at?next:at+1;
        }
    }
    return ZTL_OK;
}
void ztl_finish_snapshot(void *storage){Layout *s=layout_of(storage);s->cells=NULL;s->cell_count=0;}
int ztl_snapshot_needs(void *storage,uint32_t *clusters,uint32_t *ranges,ZtlError *error){(void)storage;*clusters=0;*ranges=0;*error=(ZtlError){0};return ZTL_OK;}
int ztl_snapshot_cells(void *storage,ZtlCell *cells,uint32_t count,void *clusters,uint32_t nc,void *ranges,uint32_t nr,ZtlError *error){(void)clusters;(void)nc;(void)ranges;(void)nr;return ztl_cells(storage,cells,count,error);}
void ztl_snapshot_stats(void *storage,ZtlSnapshotStats *out){Layout *s=layout_of(storage);memset(out,0,sizeof(*out));for(uint32_t i=0;i<s->cell_count;i++)if(s->cells[i].valid)out->bulk_cells++;else out->fallback_cells++;}
int ztl_caret(void *storage,uint32_t position,int trailing,ZtlRect *out,ZtlError *error){
    Layout *s=layout_of(storage);*error=(ZtlError){0};
    if(!s->line_count||position>s->length)return ZTL_FAILED;
    if(s->cells){
        uint32_t ci=cell_at(s,position);
        if(ci<s->cell_count&&s->cells[ci].position==position&&s->cells[ci].valid&&!(position==s->length&&!trailing)){
            ZtlCell *cell=&s->cells[ci];float edge=cell->rect.x+((!!trailing!=!!cell->rtl)?cell->rect.width:0);
            *out=(ZtlRect){edge,cell->rect.y,0,cell->rect.height};return ZTL_OK;
        }
    }
    const LineInfo *line=&s->lines[position==s->length?s->line_count-1:line_at(s,position)];
    uint32_t at=position>=line->end?line->end:grapheme_floor(s,position);
    if(at<line->start)at=line->start;
    *out=(ZtlRect){(float)(line->x+advance(s,line->start,at)),(float)line->y,0,(float)line->height};return ZTL_OK;
}
int ztl_spans(void *storage,uint32_t start,uint32_t end,ZtlRect *out,uint32_t capacity,uint32_t *count,ZtlError *error){
    Layout *s=layout_of(storage);*error=(ZtlError){0};*count=0;
    uint32_t used=0;
    for(uint32_t ci=cell_at(s,start);ci<s->cell_count&&s->cells[ci].position<end;ci++){
        if(!s->cells[ci].valid)continue;ZtlRect rect=s->cells[ci].rect;
        for(uint32_t i=0;i<used;){
            ZtlRect old=out[i];
            if(rect.y==old.y&&rect.height==old.height&&rect.x<=old.x+old.width&&old.x<=rect.x+rect.width){
                float right=rect.x+rect.width>old.x+old.width?rect.x+rect.width:old.x+old.width;
                if(old.x<rect.x)rect.x=old.x;
                rect.width=right-rect.x;out[i]=out[--used];i=0;
            }else i++;
        }
        if(used==capacity)return ZTL_CAPACITY;
        out[used++]=rect;
    }
    *count=used;return ZTL_OK;
}
void ztl_resources(uint32_t *a,uint32_t *b,uint32_t *c,uint32_t *d){*a=(uint32_t)engines;*b=(uint32_t)layouts;*c=(uint32_t)references;*d=0;}
/* The pen's boxes stand in for ink, which the page does not report. */
int ztl_ink_bounds(void *storage,ZtlRect *out,ZtlError *error){
    Layout *s=layout_of(storage);*error=(ZtlError){0};double left=INFINITY,top=INFINITY,right=-INFINITY,bottom=-INFINITY;
    for(uint32_t i=0;i<s->line_count;i++){
        const LineInfo *line=&s->lines[i];const uint32_t end=visible_end(s,line->start,line->end);if(end==line->start)continue;
        const double width=advance(s,line->start,end);
        /* Italic and wide glyphs overhang their advances a little. */
        const double overhang=s->ascent*0.25;
        left=fmin(left,line->x-overhang);right=fmax(right,line->x+width+overhang);
        top=fmin(top,line->y);bottom=fmax(bottom,line->y+line->height);
    }
    *out=left<=right?(ZtlRect){(float)left,(float)top,(float)(right-left),(float)(bottom-top)}:(ZtlRect){0,0,0,0};return ZTL_OK;
}
int ztl_prepare(void *storage,void *layout,float scale,int32_t left,int32_t top,uint32_t width,uint32_t height,uint32_t stride,uint8_t *mask,const ZtlRect *clip,ZtlError *error){
    memset(storage,0,ZTL_STORAGE);Layout *s=layout_of(layout);*error=(ZtlError){0};(void)clip; /* The renderer applies the exact viewport once at replay. */
    if(!width||!height)return ZTL_FAILED;
    if(zw_layout_begin(width,height,scale,left,top,s->font,(uint32_t)strlen(s->font),s->rtl))return ZTL_OOM;
    for(uint32_t i=0;i<s->line_count;i++){const LineInfo *line=&s->lines[i];if(line->end>line->start)zw_layout_draw(s->text+line->start,line->end-line->start,line->x,line->baseline);}
    zw_layout_end(mask,stride);
    Prepared *p=storage;p->coverage=(ZgCoverage){mask,(size_t)stride*height,width,height,stride,left,top,scale};p->live=1;references++;prepared++;return ZTL_OK;
}
void ztl_prepared_close(void *storage){Prepared *p=storage;if(p->live){p->live=0;references--;prepared--;}}
void *ztl_native_layout(void *storage){return storage;}
void *ztl_native_coverage(void *storage){return &((Prepared *)storage)->coverage;}
uint32_t ztl_prepared_count(void){return (uint32_t)prepared;}
/* The page does not hand out glyph outlines. */
int ztl_outline(void *storage,ZtlOutlineSegment *output,uint32_t capacity,uint32_t *count,ZtlGlyphCell *cells,uint32_t cell_capacity,uint32_t *cell_count,ZtlError *error){
    (void)storage;(void)output;(void)capacity;(void)cells;(void)cell_capacity;*error=(ZtlError){0};*count=0;*cell_count=0;return ZTL_UNSUPPORTED_OUTLINE;
}
int ztl_outline_mapping(void *storage,ZtlOutlineSegment *output,uint32_t capacity,uint32_t *count,ZtlOutlineMapping *map,ZtlError *error){
    (void)storage;(void)output;(void)capacity;*error=(ZtlError){0};*count=0;map->glyph_count=map->cluster_count=map->run_count=0;return ZTL_UNSUPPORTED_MAPPING;
}
