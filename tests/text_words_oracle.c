/* Independent SDK oracle. It deliberately does not include the production
 * writer or TextLayout private ABI. Its test-only arrays use libc ownership. */
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NO_STRICT
#include <windows.h>
#else
#include <pango/pangocairo.h>
#endif

typedef struct TwMap { uint32_t byte, unit; } TwMap;
typedef struct TwRange { uint32_t start, end; } TwRange;
typedef struct TwWords { TwRange *ranges; uint32_t count, length; uint64_t work; } TwWords;
static uint32_t oracle_live;
static uint64_t oracle_build_work;
#define ORACLE_WORK_LIMIT UINT64_C(2097152)

static int decode(const unsigned char *text, uint32_t length, TwMap *map,
    uint16_t *utf16, uint32_t *scalars, uint32_t *units) {
    uint32_t at=0, used=0, u=0;
    while (at<length) {
        map[used++]=(TwMap){at,u};
        uint32_t first=text[at++], ch=0, more=0, minimum=0;
        if (first && first<0x80) ch=first;
        else if (first>=0xc2 && first<=0xdf) { ch=first&31; more=1; minimum=0x80; }
        else if (first>=0xe0 && first<=0xef) { ch=first&15; more=2; minimum=0x800; }
        else if (first>=0xf0 && first<=0xf4) { ch=first&7; more=3; minimum=0x10000; }
        else return 1;
        if (more>length-at) return 1;
        for (uint32_t i=0;i<more;++i) {
            uint32_t next=text[at++];
            if (next<0x80 || next>0xbf) return 1;
            ch=(ch<<6)|(next&63);
        }
        if (ch<minimum || ch>0x10ffff || (ch>=0xd800 && ch<=0xdfff)) return 1;
        if (ch<=0xffff) utf16[u++]=(uint16_t)ch;
        else { ch-=0x10000; utf16[u++]=(uint16_t)(0xd800+(ch>>10)); utf16[u++]=(uint16_t)(0xdc00+(ch&1023)); }
    }
    map[used]=(TwMap){length,u}; utf16[u]=0;
    *scalars=used; *units=u; return 0;
}
#ifdef _WIN32
typedef void *(__cdecl *TwOpen)(int32_t,const char *,const uint16_t *,int32_t,int32_t *);
typedef int32_t (__cdecl *TwStep)(void *);
typedef void (__cdecl *TwClose)(void *);
typedef void (__cdecl *TwVersion)(uint8_t *);
typedef const char *(__cdecl *TwLocale)(const void *,int32_t,int32_t *);
static int resolve(HMODULE module, const char *name, void *out, size_t bytes) {
    FARPROC address=GetProcAddress(module,name);
    if (!address || sizeof address!=bytes) return 0;
    memcpy(out,&address,bytes); return 1;
}
static int byte_at(const TwMap *map, uint32_t count, int32_t unit, uint32_t *out) {
    if (unit<0) return 1;
    uint32_t low=0,high=count+1;
    while(low<high){if(++oracle_build_work>ORACLE_WORK_LIMIT)return 1;uint32_t mid=low+(high-low)/2;if(map[mid].unit<(uint32_t)unit)low=mid+1;else high=mid;}
    if(low>count||map[low].unit!=(uint32_t)unit)return 1;
    *out=map[low].byte;return 0;
}
static int lexical(const char *text, uint32_t length, const char *locale, int rtl,
    const TwMap *map, uint32_t scalars, const uint16_t *utf16, uint32_t units,
    TwRange *lex, uint32_t *count) {
    (void)text; (void)length; (void)rtl;
    HMODULE module=LoadLibraryExW(L"icu.dll",NULL,LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!module) return 3;
    WCHAR dll[512];char path[2048];DWORD dll_units=GetModuleFileNameW(module,dll,512);
    if(dll_units&&dll_units<512&&WideCharToMultiByte(CP_UTF8,0,dll,(int)dll_units,path,sizeof(path)-1,NULL,NULL)>0){
        int bytes=WideCharToMultiByte(CP_UTF8,0,dll,(int)dll_units,path,sizeof(path)-1,NULL,NULL);
        path[bytes]=0;printf("word oracle actual ICU module=%s\n",path);
    }else printf("word oracle ICU module path unavailable/truncated units=%lu\n",(unsigned long)dll_units);
    TwOpen open=NULL; TwStep first=NULL,next=NULL,status=NULL; TwClose close=NULL;
    int result=3;
    if (!resolve(module,"ubrk_open",&open,sizeof open) || !resolve(module,"ubrk_first",&first,sizeof first) ||
        !resolve(module,"ubrk_next",&next,sizeof next) || !resolve(module,"ubrk_close",&close,sizeof close) ||
        !resolve(module,"ubrk_getRuleStatus",&status,sizeof status)) goto done;
    TwVersion version=NULL;
    if (resolve(module,"u_getVersion",&version,sizeof version)) {
        uint8_t v[4]={0}; version(v);
        printf("word oracle system ICU %u.%u.%u.%u locale=%s\n",v[0],v[1],v[2],v[3],locale);
    }
    int32_t error=0; void *iterator=open(1,locale,utf16,(int32_t)units,&error);
    printf("word oracle ICU requested locale=%s open_status=%d\n",locale,error);
    if (!iterator || error>0) { if (iterator) close(iterator); goto done; }
    TwLocale resolved=NULL;
    if(resolve(module,"ubrk_getLocaleByType",&resolved,sizeof resolved)){
        for(int32_t type=0;type<2;++type){int32_t code=0;const char *value=resolved(iterator,type,&code);printf("word oracle ICU locale_%s=%s status=%d\n",type?"valid":"actual",value?value:"<unavailable>",code);}
    }else puts("word oracle ICU resolved locale export unavailable");
    result=0; uint32_t used=0; int32_t start=first(iterator);
    if (start!=0) result=1;
    while (!result) {
        if(++oracle_build_work>ORACLE_WORK_LIMIT){result=1;break;}
        int32_t end=next(iterator);
        if (end==-1) { if ((uint32_t)start!=units) result=1; break; }
        if (end<=start || (uint32_t)end>units) { result=1; break; }
        int32_t kind=status(iterator);
        if (kind<0 || kind>=500) { result=1; break; }
        if (kind>=100) {
            if (used>=scalars || byte_at(map,scalars,start,&lex[used].start) || byte_at(map,scalars,end,&lex[used].end)) { result=1; break; }
            ++used;
        }
        start=end;
    }
    close(iterator); if (!result) *count=used;
done:
    FreeLibrary(module); return result;
}
#else
static int lexical(const char *text, uint32_t length, const char *locale, int rtl,
    const TwMap *map, uint32_t scalars, const uint16_t *utf16, uint32_t units,
    TwRange *lex, uint32_t *count) {
    (void)utf16; (void)units;
    PangoFontMap *fonts=pango_cairo_font_map_new();
    PangoContext *context=pango_font_map_create_context(fonts);
    pango_context_set_base_dir(context,rtl?PANGO_DIRECTION_RTL:PANGO_DIRECTION_LTR);
    if (*locale) pango_context_set_language(context,pango_language_from_string(locale));
    PangoLayout *layout=pango_layout_new(context);
    pango_layout_set_auto_dir(layout,FALSE);
    pango_layout_set_text(layout,text,(int)length);
    int n=0; const PangoLogAttr *attrs=pango_layout_get_log_attrs_readonly(layout,&n);
    int result=!attrs || n<0 || (uint32_t)n!=scalars+1;
    uint32_t used=0,start=0; int active=0;
    for (uint32_t i=0;!result && i<=scalars;++i) {
        if(++oracle_build_work>ORACLE_WORK_LIMIT){result=1;break;}
        if (attrs[i].is_word_end) {
            if (!active || map[i].byte<=start || used>=scalars) { result=1; break; }
            lex[used++]=(TwRange){start,map[i].byte}; active=0;
        }
        if (attrs[i].is_word_start) {
            if (active || i==scalars) { result=1; break; }
            start=map[i].byte; active=1;
        }
    }
    if (active) result=1;
    if (!result) *count=used;
    PangoLanguage *actual=pango_context_get_language(pango_layout_get_context(layout));
    printf("word oracle Pango %s GLib %u.%u.%u requested_locale=%s context_language=%s lexical=%u\n",pango_version_string(),glib_major_version,glib_minor_version,glib_micro_version,locale,actual?pango_language_to_string(actual):"<unavailable>",used);
    g_object_unref(layout); g_object_unref(context); g_object_unref(fonts);
    return result;
}
#endif

int ztw_oracle_create(const char *text, uint32_t length, const char *locale, int rtl, TwWords **out) {
    if (!out) return 1;
    *out=NULL;
    oracle_build_work=0;
    if ((!text && length) || !locale || length>65536 || (rtl!=0 && rtl!=1)) return 1;
    TwMap *map=malloc(((size_t)length+1)*sizeof *map);
    uint16_t *utf16=malloc(((size_t)length+1)*sizeof *utf16);
    TwRange *lex=malloc(((size_t)length+1)*sizeof *lex);
    TwWords *words=calloc(1,sizeof *words);
    int result=2;
    if (!map || !utf16 || !lex || !words) goto done;
    uint32_t scalars=0,units=0,lex_count=0;
    result=decode((const unsigned char *)text,length,map,utf16,&scalars,&units);
    if (result) goto done;
    result=lexical(text,length,locale,rtl,map,scalars,utf16,units,lex,&lex_count);
    if (result) goto done;
    words->ranges=malloc(((size_t)scalars+1)*sizeof *words->ranges);
    if (!words->ranges) { result=2; goto done; }
    /* Independent whole-interval reference: add one gap before each lexical
     * interval, then one final gap. No stream writer/coalescing code is reused. */
    uint32_t cursor=0;
    for (uint32_t i=0;i<lex_count;++i) {
        if (lex[i].start<cursor || lex[i].end<=lex[i].start || lex[i].end>length) { result=1; goto done; }
        if (cursor<lex[i].start) words->ranges[words->count++]=(TwRange){cursor,lex[i].start};
        words->ranges[words->count++]=lex[i]; cursor=lex[i].end;
    }
    if (cursor<length) words->ranges[words->count++]=(TwRange){cursor,length};
    words->length=length;words->work=oracle_build_work+(uint64_t)length+scalars+lex_count;
    if(words->work>ORACLE_WORK_LIMIT){result=1;goto done;}
    *out=words; words=NULL; ++oracle_live;
done:
    if (words) { free(words->ranges); free(words); }
    free(lex); free(utf16); free(map); return result;
}
void ztw_oracle_close(TwWords *words) { if (words) { free(words->ranges); free(words); --oracle_live; } }
uint32_t ztw_oracle_live(void) { return oracle_live; }
uint32_t ztw_oracle_count(const TwWords *words) { return words->count; }
uint64_t ztw_oracle_work(const TwWords *words) { return words->work; }
int ztw_oracle_range(const TwWords *words, uint32_t index, TwRange *out) {
    if (!out || index>=words->count) return 1;
    *out=words->ranges[index]; return 0;
}
int ztw_oracle_at(const TwWords *words, uint32_t byte, int downstream, TwRange *out) {
    if (!out || byte>words->length || (downstream!=0 && downstream!=1)) return 1;
    if (!words->count) { *out=(TwRange){0,0}; return byte!=0; }
    if (!byte) { *out=words->ranges[0]; return 0; }
    if (byte==words->length) { *out=words->ranges[words->count-1]; return 0; }
    /* Independent lookup uses interval starts and an interior byte probe,
     * unlike production's partition-end/affinity search. No UTF decode or
     * repeated prefix scan is needed even at max-size native test fixtures. */
    uint32_t probe=downstream?byte:byte-1,low=0,high=words->count;
    TwWords *counter=(TwWords *)words;
    while(low<high){
        if(++counter->work>ORACLE_WORK_LIMIT)return 4;
        uint32_t mid=low+(high-low)/2;
        if(words->ranges[mid].start<=probe)low=mid+1;else high=mid;
    }
    if(!low)return 1;
    *out=words->ranges[low-1];return 0;
}
