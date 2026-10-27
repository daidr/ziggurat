/* Core Text paragraph layout behind the native text layout ABI. Positions
   are UTF-16 offsets, as Core Text's string indices are. Lines are broken
   once at creation with a typesetter; every query reads that result. */
#include <CoreText/CoreText.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "text_layout_native.h"
#include "text_layout_words_impl.h"

typedef struct Engine {uint32_t reserved;} Engine;
typedef struct LineInfo {CTLineRef line;uint32_t start,end,next;double x,y,width,height,baseline;} LineInfo;
typedef struct Layout {CFStringRef string;CTFontRef font;LineInfo *lines;uint32_t length,line_count,cell_count,glyphs,missing;ZtlCell *cells;double left,right,height;} Layout;
typedef struct Prepared {CGImageRef image;} Prepared;
_Static_assert(sizeof(Engine)<=ZTL_STORAGE,"engine storage");
_Static_assert(sizeof(Layout)<=ZTL_STORAGE,"layout storage");
_Static_assert(sizeof(Prepared)<=ZTL_STORAGE,"prepared storage");
_Static_assert(sizeof(ZtlOutlineSegment)==28,"outline segment ABI");
_Static_assert(sizeof(ZtlGlyphCell)==32,"glyph cell ABI");
_Static_assert(sizeof(ZtlOutlineGlyph)==96,"mapped glyph ABI");
_Static_assert(sizeof(ZtlOutlineCluster)==32,"mapped cluster ABI");
static atomic_int engines,layouts,references,prepared;

static double weight_trait(uint32_t weight){
    static const double traits[9]={-0.8,-0.6,-0.4,0,0.23,0.3,0.4,0.56,0.62};
    int index=(int)lround((double)weight/100)-1;if(index<0)index=0;if(index>8)index=8;return traits[index];
}
static int named_as(const char *family,const char *a,const char *b,const char *c){return !strcmp(family,a)||!strcmp(family,b)||(c&&!strcmp(family,c));}
static CTFontRef create_font(const char *family,float size,uint32_t weight,int italic){
    const int fixed=named_as(family,"Monospace","monospace",NULL);
    const int system=!family[0]||fixed||named_as(family,"Sans","sans-serif","system-ui");
    CFMutableDictionaryRef attributes=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef traits=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    if(!attributes||!traits){if(attributes)CFRelease(attributes);if(traits)CFRelease(traits);return NULL;}
    double trait=weight_trait(weight);CFNumberRef weight_number=CFNumberCreate(NULL,kCFNumberDoubleType,&trait);
    uint32_t symbolic=italic?kCTFontItalicTrait:0;CFNumberRef symbolic_number=CFNumberCreate(NULL,kCFNumberSInt32Type,&symbolic);
    if(weight_number){CFDictionarySetValue(traits,kCTFontWeightTrait,weight_number);CFRelease(weight_number);}
    if(symbolic_number){CFDictionarySetValue(traits,kCTFontSymbolicTrait,symbolic_number);CFRelease(symbolic_number);}
    CFDictionarySetValue(attributes,kCTFontTraitsAttribute,traits);CFRelease(traits);
    CTFontDescriptorRef descriptor=NULL;
    if(system){
        CTFontRef base=CTFontCreateUIFontForLanguage(fixed?kCTFontUIFontUserFixedPitch:kCTFontUIFontSystem,size,NULL);
        if(base){CTFontDescriptorRef from=CTFontCopyFontDescriptor(base);CFRelease(base);if(from){descriptor=CTFontDescriptorCreateCopyWithAttributes(from,attributes);CFRelease(from);}}
    }else{
        CFStringRef name=CFStringCreateWithCString(NULL,family,kCFStringEncodingUTF8);
        if(name){CFDictionarySetValue(attributes,kCTFontFamilyNameAttribute,name);CFRelease(name);descriptor=CTFontDescriptorCreateWithAttributes(attributes);}
    }
    CFRelease(attributes);if(!descriptor)return NULL;
    CTFontRef font=CTFontCreateWithFontDescriptor(descriptor,size,NULL);CFRelease(descriptor);return font;
}
static int is_break(UniChar c){return c=='\n'||c=='\r'||c==0x0b||c==0x0c||c==0x85||c==0x2028||c==0x2029;}

int ztl_engine_init(void *storage,ZtlError *error){
    memset(storage,0,sizeof(Engine));*error=(ZtlError){0};
    atomic_fetch_add(&engines,1);return ZTL_OK;
}
void ztl_engine_close(void *storage){(void)storage;atomic_fetch_sub(&engines,1);}
static void release_layout(Layout *s){
    if(s->lines){for(uint32_t i=0;i<s->line_count;i++)if(s->lines[i].line){CFRelease(s->lines[i].line);atomic_fetch_sub(&references,1);}free(s->lines);}
    if(s->font){CFRelease(s->font);atomic_fetch_sub(&references,1);}
    if(s->string){CFRelease(s->string);atomic_fetch_sub(&references,1);}
    memset(s,0,sizeof(*s));
}
static int push_line(Layout *s,uint32_t *capacity,CTLineRef line,uint32_t start,uint32_t end){
    if(s->line_count==*capacity){
        uint32_t next=*capacity?*capacity*2:8;LineInfo *grown=realloc(s->lines,(size_t)next*sizeof(LineInfo));
        if(!grown){if(line)CFRelease(line);return ZTL_OOM;}
        s->lines=grown;*capacity=next;
    }
    if(line)atomic_fetch_add(&references,1);
    s->lines[s->line_count++]=(LineInfo){.line=line,.start=start,.end=end};return ZTL_OK;
}
int ztl_layout_init(void *storage,void *engine,const char *text,uint32_t length,const uint16_t *utf16,uint32_t length16,const ZtlOptions *options,ZtlError *error){
    (void)engine;(void)text;(void)length;Layout *s=storage;memset(s,0,sizeof(*s));*error=(ZtlError){0};
    static const UniChar empty=0;
    s->string=CFStringCreateWithCharacters(NULL,length16?utf16:&empty,length16);if(!s->string)return ZTL_OOM;atomic_fetch_add(&references,1);
    s->length=length16;
    s->font=create_font(options->family?options->family:"",options->size,options->weight,(int)options->italic);if(!s->font){release_layout(s);return ZTL_FAILED;}atomic_fetch_add(&references,1);
    CTTextAlignment alignment=options->rtl?kCTTextAlignmentRight:kCTTextAlignmentLeft;
    CTWritingDirection direction=options->rtl?kCTWritingDirectionRightToLeft:kCTWritingDirectionLeftToRight;
    CTLineBreakMode breaks=kCTLineBreakByWordWrapping;
    CTParagraphStyleSetting settings[3]={{kCTParagraphStyleSpecifierAlignment,sizeof(alignment),&alignment},{kCTParagraphStyleSpecifierBaseWritingDirection,sizeof(direction),&direction},{kCTParagraphStyleSpecifierLineBreakMode,sizeof(breaks),&breaks}};
    CTParagraphStyleRef paragraph=CTParagraphStyleCreate(settings,3);
    CFMutableDictionaryRef attributes=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    if(!paragraph||!attributes){if(paragraph)CFRelease(paragraph);if(attributes)CFRelease(attributes);release_layout(s);return ZTL_OOM;}
    CFDictionarySetValue(attributes,kCTFontAttributeName,s->font);CFDictionarySetValue(attributes,kCTParagraphStyleAttributeName,paragraph);CFRelease(paragraph);
    if(options->locale&&options->locale[0]){CFStringRef language=CFStringCreateWithCString(NULL,options->locale,kCFStringEncodingUTF8);if(language){CFDictionarySetValue(attributes,kCTLanguageAttributeName,language);CFRelease(language);}}
    CFAttributedStringRef attributed=CFAttributedStringCreate(NULL,s->string,attributes);CFRelease(attributes);if(!attributed){release_layout(s);return ZTL_OOM;}
    CTTypesetterRef typesetter=length16?CTTypesetterCreateWithAttributedString(attributed):NULL;CFRelease(attributed);
    if(length16&&!typesetter){release_layout(s);return ZTL_OOM;}
    const double width=options->wrap&&options->width>0?options->width:1e9;
    uint32_t capacity=0;int result=ZTL_OK;
    for(CFIndex start=0;start<(CFIndex)length16;){
        CFIndex count=CTTypesetterSuggestLineBreak(typesetter,start,width);
        if(count<=0)count=(CFIndex)length16-start;
        CTLineRef line=CTTypesetterCreateLine(typesetter,CFRangeMake(start,count));if(!line){result=ZTL_OOM;break;}
        uint32_t end=(uint32_t)(start+count);
        UniChar last=end?CFStringGetCharacterAtIndex(s->string,end-1):0;
        if(is_break(last)){end--;if(last=='\n'&&end>(uint32_t)start&&CFStringGetCharacterAtIndex(s->string,end-1)=='\r')end--;}
        result=push_line(s,&capacity,line,(uint32_t)start,end);if(result)break;
        start+=count;
    }
    if(typesetter)CFRelease(typesetter);
    /* An empty text, or one ending in a line break, ends with an empty line. */
    if(!result&&(!length16||is_break(CFStringGetCharacterAtIndex(s->string,length16-1))))result=push_line(s,&capacity,NULL,length16,length16);
    if(result){release_layout(s);return result;}
    const double font_ascent=CTFontGetAscent(s->font),font_descent=CTFontGetDescent(s->font),font_leading=CTFontGetLeading(s->font);
    double y=0,widest=0;
    for(uint32_t i=0;i<s->line_count;i++){
        LineInfo *line=&s->lines[i];CGFloat ascent=font_ascent,descent=font_descent,leading=font_leading;double advance=0,visible=0;
        if(line->line){advance=CTLineGetTypographicBounds(line->line,&ascent,&descent,&leading);visible=advance-CTLineGetTrailingWhitespaceWidth(line->line);
            CFArrayRef runs=CTLineGetGlyphRuns(line->line);
            for(CFIndex r=0;r<CFArrayGetCount(runs);r++){CTRunRef run=CFArrayGetValueAtIndex(runs,r);CFIndex n=CTRunGetGlyphCount(run);s->glyphs+=(uint32_t)n;
                const CGGlyph *glyphs=CTRunGetGlyphsPtr(run);CGGlyph local[64];
                for(CFIndex g=0;g<n;g++){CGGlyph glyph;if(glyphs)glyph=glyphs[g];else{CTRunGetGlyphs(run,CFRangeMake(g,1),local);glyph=local[0];}if(!glyph)s->missing++;}}}
        line->width=advance;line->height=ascent+descent+leading;line->y=y;line->baseline=y+ascent;line->x=visible;y+=line->height;
        if(!options->wrap&&visible>widest)widest=visible;
        line->next=i+1<s->line_count?s->lines[i+1].start:s->length;
    }
    const double box=options->wrap&&options->width>0?options->width:widest;
    s->left=INFINITY;s->right=-INFINITY;
    for(uint32_t i=0;i<s->line_count;i++){LineInfo *line=&s->lines[i];double visible=line->x;line->x=options->rtl?box-visible:0;if(line->x<s->left)s->left=line->x;if(line->x+line->width>s->right)s->right=line->x+line->width;}
    s->height=y;atomic_fetch_add(&layouts,1);return ZTL_OK;
}
void ztl_layout_close(void *storage){release_layout(storage);atomic_fetch_sub(&layouts,1);}
int ztl_metrics(void *storage,ZtlMetrics *out,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};
    *out=(ZtlMetrics){{(float)s->left,0,(float)(s->right-s->left),(float)s->height},s->line_count,s->glyphs,s->missing};return ZTL_OK;
}
int ztl_graphemes(void *storage,uint32_t *positions,uint32_t capacity,uint32_t *count,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};uint32_t used=0;
    for(CFIndex at=0;;){
        if(used==capacity)return ZTL_CAPACITY;positions[used++]=(uint32_t)at;
        if(at>=(CFIndex)s->length)break;
        CFRange range=CFStringGetRangeOfComposedCharactersAtIndex(s->string,at);
        at=range.location+range.length>at?range.location+range.length:at+1;
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
static int word_status(int written){return written==ZTL_WORD_CAPACITY?ZTL_CAPACITY:ZTL_FAILED;}
int ztl_word_ranges(void *storage,const char *locale,uint32_t *ends,uint32_t capacity,uint32_t *count,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};WORD_CALL();
    if(!count||(capacity&&!ends))return ZTL_FAILED;
    ZtlWordWriter writer;int result=ztl_word_writer_init(&writer,ends,capacity,s->length);
    if(result)return word_status(result);
    if(!s->length)return ztl_word_writer_finish(&writer,count)==ZTL_WORD_OK?ZTL_OK:ZTL_FAILED;
    CFStringRef name=locale&&locale[0]?CFStringCreateWithCString(NULL,locale,kCFStringEncodingUTF8):NULL;
    CFLocaleRef language=name?CFLocaleCreate(NULL,name):NULL;if(name)CFRelease(name);
    CFStringTokenizerRef tokenizer=CFStringTokenizerCreate(NULL,s->string,CFRangeMake(0,s->length),kCFStringTokenizerUnitWord,language);
    if(language)CFRelease(language);if(!tokenizer)return ZTL_OOM;
    while(!result&&CFStringTokenizerAdvanceToNextToken(tokenizer)!=kCFStringTokenizerTokenNone){
        CFRange token=CFStringTokenizerGetCurrentTokenRange(tokenizer);
        if(token.location<0||token.length<=0||(uint32_t)(token.location+token.length)>s->length||(uint32_t)token.location<writer.next){result=ZTL_FAILED;break;}
        if(writer.next<(uint32_t)token.location){int written=ztl_word_writer_segment(&writer,(uint32_t)token.location,0);if(written){result=word_status(written);break;}}
        int written=ztl_word_writer_segment(&writer,(uint32_t)(token.location+token.length),1);if(written)result=word_status(written);
    }
    CFRelease(tokenizer);if(result)return result;
    if(writer.next<s->length){int written=ztl_word_writer_segment(&writer,s->length,0);if(written)return word_status(written);}
    result=ztl_word_writer_finish(&writer,count);
    return result==ZTL_WORD_OK?ZTL_OK:word_status(result);
}
int ztl_lines(void *storage,ZtlLine *out,uint32_t capacity,uint32_t *count,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};*count=s->line_count;if(s->line_count>capacity)return ZTL_CAPACITY;
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
/* Every glyph widens the cell of the scalar its cluster starts at; scalars a
   cluster covers without glyphs of their own (ligature parts, marks) share
   that cell's width evenly, in the run's visual direction. */
int ztl_cells(void *storage,ZtlCell *cells,uint32_t count,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};s->cells=cells;s->cell_count=count;
    for(uint32_t li=0;li<s->line_count;li++){
        const LineInfo *line=&s->lines[li];if(!line->line)continue;
        CFArrayRef runs=CTLineGetGlyphRuns(line->line);
        for(CFIndex r=0;r<CFArrayGetCount(runs);r++){
            CTRunRef run=CFArrayGetValueAtIndex(runs,r);const CFIndex n=CTRunGetGlyphCount(run);const uint32_t rtl=(CTRunGetStatus(run)&kCTRunStatusRightToLeft)!=0;
            CFRange range=CTRunGetStringRange(run);
            for(CFIndex g=0;g<n;g++){
                CFIndex index;CGPoint position;CGSize advance;
                CTRunGetStringIndices(run,CFRangeMake(g,1),&index);CTRunGetPositions(run,CFRangeMake(g,1),&position);CTRunGetAdvances(run,CFRangeMake(g,1),&advance);
                uint32_t ci=cell_at(s,(uint32_t)index);if(ci==count||cells[ci].position!=(uint32_t)index)continue;
                const double x=line->x+position.x,right=x+advance.width;ZtlCell *cell=&cells[ci];
                if(cell->valid){double left=fmin(cell->rect.x,x),end=fmax(cell->rect.x+cell->rect.width,right);cell->rect.x=(float)left;cell->rect.width=(float)(end-left);}
                else{cell->line=li;cell->rect=(ZtlRect){(float)x,(float)line->y,(float)advance.width,(float)line->height};cell->rtl=rtl;cell->valid=1;}
            }
            for(uint32_t ci=cell_at(s,(uint32_t)range.location);ci<count&&cells[ci].position<(uint32_t)(range.location+range.length);){
                if(!cells[ci].valid){ci++;continue;}
                uint32_t last=ci+1;while(last<count&&cells[last].position<(uint32_t)(range.location+range.length)&&!cells[last].valid)last++;
                const uint32_t parts=last-ci;
                if(parts>1){ZtlRect whole=cells[ci].rect;const float share=whole.width/(float)parts;
                    for(uint32_t k=0;k<parts;k++){ZtlCell *cell=&cells[ci+k];cell->line=li;cell->rtl=rtl;cell->valid=1;
                        cell->rect=(ZtlRect){rtl?whole.x+whole.width-share*(float)(k+1):whole.x+share*(float)k,whole.y,share,whole.height};}}
                ci=last;
            }
        }
    }
    return ZTL_OK;
}
void ztl_finish_snapshot(void *storage){Layout *s=storage;s->cells=NULL;s->cell_count=0;}
int ztl_snapshot_needs(void *storage,uint32_t *clusters,uint32_t *ranges,ZtlError *error){(void)storage;*clusters=0;*ranges=0;*error=(ZtlError){0};return ZTL_OK;}
int ztl_snapshot_cells(void *storage,ZtlCell *cells,uint32_t count,void *clusters,uint32_t nc,void *ranges,uint32_t nr,ZtlError *error){(void)clusters;(void)nc;(void)ranges;(void)nr;return ztl_cells(storage,cells,count,error);}
void ztl_snapshot_stats(void *storage,ZtlSnapshotStats *out){Layout *s=storage;memset(out,0,sizeof(*out));for(uint32_t i=0;i<s->cell_count;i++)if(s->cells[i].valid)out->bulk_cells++;else out->fallback_cells++;}
int ztl_caret(void *storage,uint32_t position,int trailing,ZtlRect *out,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};
    if(!s->line_count||position>s->length)return ZTL_FAILED;
    if(s->cells){
        uint32_t ci=cell_at(s,position);
        if(ci<s->cell_count&&s->cells[ci].position==position&&s->cells[ci].valid&&!(position==s->length&&!trailing)){
            ZtlCell *cell=&s->cells[ci];float edge=cell->rect.x+((!!trailing!=!!cell->rtl)?cell->rect.width:0);
            *out=(ZtlRect){edge,cell->rect.y,0,cell->rect.height};return ZTL_OK;
        }
    }
    const LineInfo *line=&s->lines[position==s->length?s->line_count-1:line_at(s,position)];
    double x=line->x;
    if(line->line){CGFloat secondary=0;x+=CTLineGetOffsetForStringIndex(line->line,position,&secondary);}
    *out=(ZtlRect){(float)x,(float)line->y,0,(float)line->height};return ZTL_OK;
}
int ztl_spans(void *storage,uint32_t start,uint32_t end,ZtlRect *out,uint32_t capacity,uint32_t *count,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};*count=0;
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
void ztl_resources(uint32_t *a,uint32_t *b,uint32_t *c,uint32_t *d){*a=(uint32_t)atomic_load(&engines);*b=(uint32_t)atomic_load(&layouts);*c=(uint32_t)atomic_load(&references);*d=0;}
int ztl_ink_bounds(void *storage,ZtlRect *out,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};double left=INFINITY,top=INFINITY,right=-INFINITY,bottom=-INFINITY;
    for(uint32_t i=0;i<s->line_count;i++){
        const LineInfo *line=&s->lines[i];if(!line->line)continue;
        CGRect ink=CTLineGetImageBounds(line->line,NULL);if(CGRectIsNull(ink)||CGRectIsEmpty(ink))continue;
        left=fmin(left,line->x+ink.origin.x);right=fmax(right,line->x+ink.origin.x+ink.size.width);
        top=fmin(top,line->baseline-(ink.origin.y+ink.size.height));bottom=fmax(bottom,line->baseline-ink.origin.y);
    }
    *out=left<=right?(ZtlRect){(float)left,(float)top,(float)(right-left),(float)(bottom-top)}:(ZtlRect){0,0,0,0};return ZTL_OK;
}
static void draw_lines(Layout *s,CGContextRef context){
    CGContextSetTextMatrix(context,CGAffineTransformMakeScale(1,-1));
    for(uint32_t i=0;i<s->line_count;i++){const LineInfo *line=&s->lines[i];if(!line->line)continue;CGContextSetTextPosition(context,line->x,line->baseline);CTLineDraw(line->line,context);}
}
int ztl_prepare(void *storage,void *layout,float scale,int32_t left,int32_t top,uint32_t width,uint32_t height,uint32_t stride,uint8_t *mask,const ZtlRect *clip,ZtlError *error){
    memset(storage,0,ZTL_STORAGE);Layout *s=layout;*error=(ZtlError){0};(void)clip; /* The renderer applies the exact viewport once at replay. */
    if(!width||!height)return ZTL_FAILED;
    CGContextRef context=CGBitmapContextCreate(mask,width,height,8,stride,NULL,(CGBitmapInfo)kCGImageAlphaOnly);if(!context)return ZTL_OOM;
    CGContextTranslateCTM(context,0,height);CGContextScaleCTM(context,1,-1);
    CGContextTranslateCTM(context,-(double)left,-(double)top);CGContextScaleCTM(context,scale,scale);
    CGContextSetRGBFillColor(context,1,1,1,1);CGContextSetAllowsFontSmoothing(context,false);
    draw_lines(s,context);CGContextRelease(context);
    /* The coverage plane, read as gray samples, is the mask replay clips to. */
    CGColorSpaceRef gray=CGColorSpaceCreateDeviceGray();
    CGDataProviderRef provider=CGDataProviderCreateWithData(NULL,mask,(size_t)stride*height,NULL);
    CGImageRef image=gray&&provider?CGImageCreate(width,height,8,8,stride,gray,(CGBitmapInfo)kCGImageAlphaNone,provider,NULL,false,kCGRenderingIntentDefault):NULL;
    if(provider)CGDataProviderRelease(provider);if(gray)CGColorSpaceRelease(gray);
    if(!image)return ZTL_OOM;
    Prepared *p=storage;p->image=image;atomic_fetch_add(&references,1);atomic_fetch_add(&prepared,1);return ZTL_OK;
}
void ztl_prepared_close(void *storage){Prepared *p=storage;if(p->image){CGImageRelease(p->image);p->image=NULL;atomic_fetch_sub(&references,1);atomic_fetch_sub(&prepared,1);}}
void *ztl_native_layout(void *storage){return storage;}
void *ztl_native_coverage(void *storage){return (void *)((Prepared *)storage)->image;}
uint32_t ztl_prepared_count(void){return (uint32_t)atomic_load(&prepared);}

/* Glyph outlines, in layout coordinates (y down). */
typedef struct PathSink {ZtlOutlineSegment *output;uint32_t capacity,count;double x,y;CGPoint current,start;int result;ZtlOutlineMapping *map;} PathSink;
static int mapping_charge(ZtlOutlineMapping *map,uint64_t work){
    if(!map)return ZTL_OK;
    if(map->cancellation&&__atomic_load_n(map->cancellation,__ATOMIC_ACQUIRE))return ZTL_OUTLINE_CANCELLED;
    if(work>map->work_limit-map->work)return ZTL_OUTLINE_WORK;
    map->work+=work;return ZTL_OK;
}
static void sink_add(PathSink *sink,uint32_t kind,const CGPoint *points,unsigned count){
    if(sink->result)return;
    int charged=mapping_charge(sink->map,1);if(charged){sink->result=charged;return;}
    if(sink->count==sink->capacity){sink->result=ZTL_CAPACITY;return;}
    if(sink->output){ZtlOutlineSegment segment={.kind=kind};for(unsigned i=0;i<count;i++)segment.points[i]=(ZtlOutlinePoint){(float)(sink->x+points[i].x),(float)(sink->y-points[i].y)};sink->output[sink->count]=segment;}
    sink->count++;
}
static void path_element(void *info,const CGPathElement *element){
    PathSink *sink=info;
    switch(element->type){
        case kCGPathElementMoveToPoint:sink_add(sink,ZTL_OUTLINE_MOVE,element->points,1);sink->current=sink->start=element->points[0];break;
        case kCGPathElementAddLineToPoint:sink_add(sink,ZTL_OUTLINE_LINE,element->points,1);sink->current=element->points[0];break;
        case kCGPathElementAddQuadCurveToPoint:{
            const CGPoint a=sink->current,c=element->points[0],e=element->points[1];
            CGPoint cubic[3]={{a.x+2.0/3.0*(c.x-a.x),a.y+2.0/3.0*(c.y-a.y)},{e.x+2.0/3.0*(c.x-e.x),e.y+2.0/3.0*(c.y-e.y)},e};
            sink_add(sink,ZTL_OUTLINE_CUBIC,cubic,3);sink->current=e;break;
        }
        case kCGPathElementAddCurveToPoint:sink_add(sink,ZTL_OUTLINE_CUBIC,element->points,3);sink->current=element->points[2];break;
        case kCGPathElementCloseSubpath:sink_add(sink,ZTL_OUTLINE_CLOSE,NULL,0);sink->current=sink->start;break;
        default:if(!sink->result)sink->result=sink->map?ZTL_UNSUPPORTED_MAPPING:ZTL_UNSUPPORTED_OUTLINE;break;
    }
}
static int glyph_path(CTFontRef font,CGGlyph glyph,double x,double y,PathSink *sink){
    CGPathRef path=CTFontCreatePathForGlyph(font,glyph,NULL);if(!path)return ZTL_OK; /* blank glyphs have no path */
    sink->x=x;sink->y=y;sink->current=sink->start=CGPointZero;
    CGPathApply(path,sink,path_element);CGPathRelease(path);return sink->result;
}
static void run_font_metrics(CTRunRef run,CTFontRef fallback,CTFontRef *font,double *ascent,double *descent){
    CFDictionaryRef attributes=CTRunGetAttributes(run);CTFontRef value=attributes?CFDictionaryGetValue(attributes,kCTFontAttributeName):NULL;
    *font=value?value:fallback;*ascent=CTFontGetAscent(*font);*descent=CTFontGetDescent(*font);
}
int ztl_outline(void *storage,ZtlOutlineSegment *output,uint32_t capacity,uint32_t *count,ZtlGlyphCell *cells,uint32_t cell_capacity,uint32_t *cell_count,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};*count=0;*cell_count=0;
    PathSink sink={.output=output,.capacity=capacity};
    for(uint32_t li=0;li<s->line_count;li++){
        const LineInfo *line=&s->lines[li];if(!line->line)continue;
        CFArrayRef runs=CTLineGetGlyphRuns(line->line);
        for(CFIndex r=0;r<CFArrayGetCount(runs);r++){
            CTRunRef run=CFArrayGetValueAtIndex(runs,r);const CFIndex n=CTRunGetGlyphCount(run);
            CTFontRef font;double ascent,descent;run_font_metrics(run,s->font,&font,&ascent,&descent);
            if(cell_capacity&&(uint32_t)n>cell_capacity-*cell_count)return ZTL_CAPACITY;
            for(CFIndex g=0;g<n;g++){
                CGGlyph glyph;CGPoint position;CGSize advance;
                CTRunGetGlyphs(run,CFRangeMake(g,1),&glyph);CTRunGetPositions(run,CFRangeMake(g,1),&position);CTRunGetAdvances(run,CFRangeMake(g,1),&advance);
                const double x=line->x+position.x,y=line->baseline-position.y;
                if(cell_capacity){if(cells)cells[*cell_count]=(ZtlGlyphCell){fmin(x,x+advance.width),y-ascent,fabs(advance.width),ascent+descent};++*cell_count;}
                int result=glyph_path(font,glyph,x,y,&sink);if(result)return result;
            }
        }
    }
    *count=sink.count;return ZTL_OK;
}
int ztl_outline_mapping(void *storage,ZtlOutlineSegment *output,uint32_t capacity,uint32_t *count,ZtlOutlineMapping *map,ZtlError *error){
    Layout *s=storage;*error=(ZtlError){0};*count=0;map->glyph_count=map->cluster_count=map->run_count=0;map->work=0;
    PathSink sink={.output=output,.capacity=capacity,.map=map};
    for(uint32_t li=0;li<s->line_count;li++){
        const LineInfo *line=&s->lines[li];if(!line->line)continue;
        CFArrayRef runs=CTLineGetGlyphRuns(line->line);
        for(CFIndex r=0;r<CFArrayGetCount(runs);r++){
            int result=mapping_charge(map,1);if(result)return result;
            CTRunRef run=CFArrayGetValueAtIndex(runs,r);const CFIndex n=CTRunGetGlyphCount(run);const CFRange range=CTRunGetStringRange(run);
            if(n<0||range.location<0||range.length<0||(uint32_t)(range.location+range.length)>s->length)return ZTL_UNSUPPORTED_MAPPING;
            if((uint32_t)n>map->glyph_capacity-map->glyph_count)return ZTL_CAPACITY;
            CTFontRef font;double ascent,descent;run_font_metrics(run,s->font,&font,&ascent,&descent);
            const uint32_t rtl=(CTRunGetStatus(run)&kCTRunStatusRightToLeft)!=0,level=rtl,run_index=map->run_count++;
            /* Physical glyph order; a cluster is the consecutive glyphs of one
               string index. Its source ends at the next larger cluster start. */
            for(CFIndex g=0;g<n;){
                CFIndex index;CTRunGetStringIndices(run,CFRangeMake(g,1),&index);
                CFIndex last=g+1;
                for(;last<n;last++){CFIndex other;CTRunGetStringIndices(run,CFRangeMake(last,1),&other);if(other!=index)break;}
                CFIndex end=range.location+range.length;
                for(CFIndex k=0;k<n;k++){CFIndex other;CTRunGetStringIndices(run,CFRangeMake(k,1),&other);if(other>index&&other<end)end=other;}
                if(index<range.location||end<=index)return ZTL_UNSUPPORTED_MAPPING;
                if(map->cluster_count==map->cluster_capacity)return ZTL_CAPACITY;
                result=mapping_charge(map,1+(uint64_t)n);if(result)return result;
                const uint32_t cluster_index=map->cluster_count++,glyph_start=map->glyph_count,segment_start=sink.count;
                for(CFIndex i=g;i<last;i++){
                    result=mapping_charge(map,2);if(result)return result;
                    CGGlyph glyph;CGPoint position;CGSize advance;
                    CTRunGetGlyphs(run,CFRangeMake(i,1),&glyph);CTRunGetPositions(run,CFRangeMake(i,1),&position);CTRunGetAdvances(run,CFRangeMake(i,1),&advance);
                    const double x=line->x+position.x,y=line->baseline-position.y;const uint32_t begin=sink.count;
                    result=glyph_path(font,glyph,x,y,&sink);if(result)return result;
                    if(map->glyphs)map->glyphs[map->glyph_count]=(ZtlOutlineGlyph){glyph,cluster_index,run_index,level,{begin,sink.count-begin},{x,line->baseline},{x,y},advance.width,{fmin(x,x+advance.width),y-ascent,fabs(advance.width),ascent+descent}};
                    ++map->glyph_count;
                }
                if(map->clusters)map->clusters[cluster_index]=(ZtlOutlineCluster){{(uint32_t)index,(uint32_t)end},{glyph_start,map->glyph_count-glyph_start},{segment_start,sink.count-segment_start},run_index,level};
                g=last;
            }
        }
    }
    *count=sink.count;return ZTL_OK;
}
