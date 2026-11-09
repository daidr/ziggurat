/* Symbols presented as text on Windows. DirectWrite's fallback takes Segoe
   UI Emoji for symbols the text's font lacks, ⏺ (U+23FA) among them, and
   draws them in color, though such a symbol is presented as text unless
   U+FE0F follows it (UTS #51). Its ranges take Segoe UI Symbol, Windows'
   monochrome font for most of the symbols Segoe UI Emoji draws, where it
   has them: they draw in the text's color, as the other systems, whose
   fallback picks a font by presentation, draw them. Characters presented
   as emoji by default are the regional indicators and the East Asian Wide
   symbols. Shared by the layouts that measure text and the renderer that
   draws labels, which then agree. */
#ifndef ZIGGURAT_TEXT_SYMBOLS_WINDOWS_H
#define ZIGGURAT_TEXT_SYMBOLS_WINDOWS_H
#include <windows.h>
#include <dwrite.h>
#include <stdint.h>

/* East Asian Wide symbols of the emoji blocks (UAX #11), sorted. */
static const uint32_t zsym_wide[][2] = {
    {0x231a, 0x231b}, {0x23e9, 0x23ec}, {0x23f0, 0x23f0}, {0x23f3, 0x23f3}, {0x25fd, 0x25fe}, {0x2614, 0x2615}, {0x2648, 0x2653},
    {0x267f, 0x267f}, {0x2693, 0x2693}, {0x26a1, 0x26a1}, {0x26aa, 0x26ab}, {0x26bd, 0x26be}, {0x26c4, 0x26c5}, {0x26ce, 0x26ce},
    {0x26d4, 0x26d4}, {0x26ea, 0x26ea}, {0x26f2, 0x26f3}, {0x26f5, 0x26f5}, {0x26fa, 0x26fa}, {0x26fd, 0x26fd}, {0x2705, 0x2705},
    {0x270a, 0x270b}, {0x2728, 0x2728}, {0x274c, 0x274c}, {0x274e, 0x274e}, {0x2753, 0x2755}, {0x2757, 0x2757}, {0x2795, 0x2797},
    {0x27b0, 0x27b0}, {0x27bf, 0x27bf}, {0x2b1b, 0x2b1c}, {0x2b50, 0x2b50}, {0x2b55, 0x2b55}, {0x1f004, 0x1f004}, {0x1f0cf, 0x1f0cf},
    {0x1f18e, 0x1f18e}, {0x1f191, 0x1f19a}, {0x1f200, 0x1f202}, {0x1f210, 0x1f23b}, {0x1f240, 0x1f248}, {0x1f250, 0x1f251},
    {0x1f260, 0x1f265}, {0x1f300, 0x1f320}, {0x1f32d, 0x1f335}, {0x1f337, 0x1f37c}, {0x1f37e, 0x1f393}, {0x1f3a0, 0x1f3ca},
    {0x1f3cf, 0x1f3d3}, {0x1f3e0, 0x1f3f0}, {0x1f3f4, 0x1f3f4}, {0x1f3f8, 0x1f43e}, {0x1f440, 0x1f440}, {0x1f442, 0x1f4fc},
    {0x1f4ff, 0x1f53d}, {0x1f54b, 0x1f54e}, {0x1f550, 0x1f567}, {0x1f57a, 0x1f57a}, {0x1f595, 0x1f596}, {0x1f5a4, 0x1f5a4},
    {0x1f5fb, 0x1f64f}, {0x1f680, 0x1f6c5}, {0x1f6cc, 0x1f6cc}, {0x1f6d0, 0x1f6d2}, {0x1f6d5, 0x1f6d7}, {0x1f6dc, 0x1f6df},
    {0x1f6eb, 0x1f6ec}, {0x1f6f4, 0x1f6fc}, {0x1f7e0, 0x1f7eb}, {0x1f7f0, 0x1f7f0}, {0x1f90c, 0x1f93a}, {0x1f93c, 0x1f945},
    {0x1f947, 0x1f9ff}, {0x1fa70, 0x1fa7c}, {0x1fa80, 0x1fa89}, {0x1fa8f, 0x1fac6}, {0x1face, 0x1fadc}, {0x1fadf, 0x1fae9},
    {0x1faf0, 0x1faf8},
};

static uint32_t zsym_scalar(const WCHAR *text, uint32_t length, uint32_t i, uint32_t *units) {
    *units = 1;
    if (text[i] >= 0xd800 && text[i] < 0xdc00 && i + 1 < length && text[i + 1] >= 0xdc00 && text[i + 1] < 0xe000) {
        *units = 2;
        return 0x10000 + (((uint32_t)text[i] - 0xd800) << 10) + ((uint32_t)text[i + 1] - 0xdc00);
    }
    return text[i];
}

/* Whether a character is presented as an emoji when no variation selector
   says which. */
static int zsym_emoji_default(uint32_t cp) {
    if (cp >= 0x1f1e6 && cp <= 0x1f1ff) return 1;
    uint32_t lo = 0, hi = sizeof(zsym_wide) / sizeof(zsym_wide[0]);
    while (lo < hi) {
        const uint32_t mid = lo + (hi - lo) / 2;
        if (cp < zsym_wide[mid][0]) hi = mid;
        else if (cp > zsym_wide[mid][1]) lo = mid + 1;
        else return 1;
    }
    return 0;
}

/* Whether a character is among the symbols a color emoji font draws. */
static int zsym_symbol(uint32_t cp) {
    return cp == 0xa9 || cp == 0xae || (cp >= 0x2000 && cp <= 0x2bff) || cp == 0x3030 || cp == 0x303d || cp == 0x3297 || cp == 0x3299 || (cp >= 0x1f000 && cp <= 0x1faff);
}

/* The length of the text-presented symbol at `i`, its variation selector
   with it; 0 when none starts there. */
static uint32_t zsym_text_symbol(const WCHAR *text, uint32_t length, uint32_t i, uint32_t *cp) {
    uint32_t units = 1;
    *cp = zsym_scalar(text, length, i, &units);
    if (!zsym_symbol(*cp)) return 0;
    const WCHAR next = i + units < length ? text[i + units] : 0;
    if (next == 0xfe0f) return 0;
    if (next == 0xfe0e) return units + 1;
    return zsym_emoji_default(*cp) ? 0 : units;
}

/* Whether the text has a symbol presented as text: most texts have none,
   and skip the rest. */
static int zsym_any(const WCHAR *text, uint32_t length) {
    for (uint32_t i = 0; i < length; i++) {
        const WCHAR u = text[i];
        if ((u >= 0x2000 && u <= 0x2bff) || u == 0xa9 || u == 0xae || u == 0x3030 || u == 0x303d || u == 0x3297 || u == 0x3299 || u == 0xd83c || u == 0xd83d || u == 0xd83e) return 1;
    }
    return 0;
}

static IDWriteFont *zsym_font(IDWriteFontCollection *collection, const WCHAR *family, DWRITE_FONT_WEIGHT weight, DWRITE_FONT_STYLE style) {
    UINT32 index = 0;
    BOOL exists = FALSE;
    IDWriteFontFamily *found = NULL;
    IDWriteFont *font = NULL;
    if (FAILED(IDWriteFontCollection_FindFamilyName(collection, family, &index, &exists)) || !exists) return NULL;
    if (FAILED(IDWriteFontCollection_GetFontFamily(collection, index, &found)) || !found) return NULL;
    if (FAILED(IDWriteFontFamily_GetFirstMatchingFont(found, weight, DWRITE_FONT_STRETCH_NORMAL, style, &font))) font = NULL;
    IDWriteFontFamily_Release(found);
    return font;
}

/* Gives the symbols of `layout`'s text presented as text that its font
   lacks Segoe UI Symbol, where it has them. `collection` is the one the
   layout's format takes its family from, NULL for the system's. */
static HRESULT zsym_apply(IDWriteFactory *factory, IDWriteFontCollection *collection, IDWriteTextLayout *layout, const WCHAR *text, uint32_t length, const WCHAR *family, DWRITE_FONT_WEIGHT weight, DWRITE_FONT_STYLE style) {
    if (!zsym_any(text, length)) return S_OK;
    IDWriteFontCollection *system = NULL;
    if (FAILED(IDWriteFactory_GetSystemFontCollection(factory, &system, FALSE)) || !system) return S_OK;
    IDWriteFont *own = zsym_font(collection ? collection : system, family, weight, style);
    IDWriteFont *symbol = zsym_font(system, L"Segoe UI Symbol", weight, style);
    HRESULT hr = S_OK;
    if (symbol) {
        for (uint32_t i = 0; i < length && SUCCEEDED(hr);) {
            uint32_t cp = 0, units = 1;
            const uint32_t n = zsym_text_symbol(text, length, i, &cp);
            if (n) {
                BOOL has = FALSE, symbol_has = FALSE;
                if (own) IDWriteFont_HasCharacter(own, cp, &has);
                IDWriteFont_HasCharacter(symbol, cp, &symbol_has);
                if (!has && symbol_has) {
                    const DWRITE_TEXT_RANGE range = {i, n};
                    hr = IDWriteTextLayout_SetFontFamilyName(layout, L"Segoe UI Symbol", range);
                    /* The system's collection holds it, not the app's. */
                    if (SUCCEEDED(hr) && collection) hr = IDWriteTextLayout_SetFontCollection(layout, system, range);
                }
                i += n;
                continue;
            }
            (void)zsym_scalar(text, length, i, &units);
            i += units;
        }
    }
    if (symbol) IDWriteFont_Release(symbol);
    if (own) IDWriteFont_Release(own);
    IDWriteFontCollection_Release(system);
    return hr;
}
#endif
