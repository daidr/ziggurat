#ifdef _WIN32
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define NO_STRICT
#include <windows.h>
#include <dwrite.h>
#include <stdint.h>
/* A separate font API oracle for a single BMP glyph without kerning/fallback.
   It does not enumerate the production renderer's glyph runs or cell array. */
int ztc_single_cell(void *native, uint32_t character, double out[4]) {
    IDWriteTextFormat *format=(IDWriteTextFormat *)native;
    IDWriteFactory *factory=NULL;IDWriteFontCollection *collection=NULL;
    IDWriteFontFamily *family=NULL;IDWriteFont *font=NULL;IDWriteFontFace *face=NULL;
    WCHAR name[256];UINT32 index=0;BOOL exists=FALSE;UINT16 glyph=0;
    HRESULT hr=IDWriteTextFormat_GetFontFamilyName(format,name,256);
    if(FAILED(hr))goto done;
    hr=DWriteCreateFactory(DWRITE_FACTORY_TYPE_ISOLATED,&IID_IDWriteFactory,(IUnknown **)&factory);
    if(FAILED(hr))goto done;
    hr=IDWriteFactory_GetSystemFontCollection(factory,&collection,FALSE);if(FAILED(hr))goto done;
    hr=IDWriteFontCollection_FindFamilyName(collection,name,&index,&exists);if(FAILED(hr)||!exists){hr=E_FAIL;goto done;}
    hr=IDWriteFontCollection_GetFontFamily(collection,index,&family);if(FAILED(hr))goto done;
    hr=IDWriteFontFamily_GetFirstMatchingFont(family,IDWriteTextFormat_GetFontWeight(format),IDWriteTextFormat_GetFontStretch(format),IDWriteTextFormat_GetFontStyle(format),&font);if(FAILED(hr))goto done;
    hr=IDWriteFont_CreateFontFace(font,&face);if(FAILED(hr))goto done;
    hr=IDWriteFontFace_GetGlyphIndices(face,&character,1,&glyph);if(FAILED(hr)||!glyph){hr=E_FAIL;goto done;}
    DWRITE_GLYPH_METRICS design;DWRITE_FONT_METRICS metrics;
    IDWriteFontFace_GetMetrics(face,&metrics);
    hr=IDWriteFontFace_GetDesignGlyphMetrics(face,&glyph,1,&design,FALSE);if(FAILED(hr)||!metrics.designUnitsPerEm){hr=E_FAIL;goto done;}
    DWRITE_LINE_METRICS line;UINT32 lines=0;
    hr=IDWriteTextLayout_GetLineMetrics((IDWriteTextLayout *)native,&line,1,&lines);if(FAILED(hr)||lines!=1){hr=E_FAIL;goto done;}
    const double unit=(double)IDWriteTextFormat_GetFontSize(format)/metrics.designUnitsPerEm;
    out[0]=0;out[1]=(double)line.baseline-metrics.ascent*unit;
    out[2]=design.advanceWidth*unit;out[3]=(metrics.ascent+metrics.descent)*unit;
done:
    if(face)IDWriteFontFace_Release(face);if(font)IDWriteFont_Release(font);
    if(family)IDWriteFontFamily_Release(family);if(collection)IDWriteFontCollection_Release(collection);
    if(factory)IDWriteFactory_Release(factory);return FAILED(hr)?1:0;
}
#else
#include <pango/pangocairo.h>
#include <stdint.h>
int ztc_single_cell(void *native, uint32_t character, double out[4]) {
    (void)character;PangoLayout *layout=native;
    PangoContext *context=pango_layout_get_context(layout);
    PangoFont *font=pango_context_load_font(context,pango_layout_get_font_description(layout));
    if(!font)return 1;
    PangoFontMetrics *metrics=pango_font_get_metrics(font,pango_context_get_language(context));
    if(!metrics){g_object_unref(font);return 1;}
    int width,height;pango_layout_get_size(layout,&width,&height);
    const int ascent=pango_font_metrics_get_ascent(metrics),descent=pango_font_metrics_get_descent(metrics);
    out[0]=0;out[1]=((double)pango_layout_get_baseline(layout)-ascent)/PANGO_SCALE;
    out[2]=(double)width/PANGO_SCALE;out[3]=((double)ascent+descent)/PANGO_SCALE;
    pango_font_metrics_unref(metrics);g_object_unref(font);return 0;
}
#endif
