/* Application fonts for DirectWrite: a font collection of the system's font
   set and the files registered, made again for a factory when a file is
   added; and the system collection's families. GDI takes registered fonts
   with AddFontMemResourceEx on the Zig side. */
#define COBJMACROS
#include <windows.h>
#include <dwrite_3.h>
#include <stdint.h>

/* Defined here so that no import library needs to carry them. */
static const IID factory_iid = {0xb859ee5a, 0xd838, 0x4b5b, {0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48}};
static const IID factory3_iid = {0x9a1b41c3, 0xd3bb, 0x466a, {0x87, 0xfc, 0xfe, 0x67, 0x55, 0x6a, 0x3b, 0x65}};
static const IID font1_iid = {0xacd16696, 0x8c14, 0x4f5d, {0x87, 0x7e, 0xfe, 0x3f, 0xc1, 0xd3, 0x27, 0x38}};

#define MAX_FILES 63
/* The files registered, each under its own families (family NULL) or again
   under a family the app gave its faces, which holds only the files it was
   given. */
static WCHAR *paths[MAX_FILES];
static WCHAR *given[MAX_FILES];
static uint32_t path_count;
static uint64_t generation;

uint64_t zfont_generation(void) { return generation; }

static WCHAR *copy_string(const WCHAR *text) {
    size_t n = wcslen(text) + 1;
    WCHAR *copy = HeapAlloc(GetProcessHeap(), 0, n * sizeof(WCHAR));
    if (copy) memcpy(copy, text, n * sizeof(WCHAR));
    return copy;
}

/* Takes copies of the path and the family, NULL for the font's own. 0 on
   success. */
int zfont_add_family(const WCHAR *path, const WCHAR *family) {
    if (path_count == MAX_FILES) return 1;
    WCHAR *copy = copy_string(path);
    if (!copy) return 2;
    WCHAR *name = NULL;
    if (family && !(name = copy_string(family))) { HeapFree(GetProcessHeap(), 0, copy); return 2; }
    paths[path_count] = copy;
    given[path_count] = name;
    path_count++;
    generation++;
    return 0;
}
int zfont_add_file(const WCHAR *path) { return zfont_add_family(path, NULL); }

/* Whether the app gave `family` to files other than `path`, and not to
   `path` itself. */
static int taken(const WCHAR *family, const WCHAR *path) {
    int others = 0;
    for (uint32_t i = 0; i < path_count; i++) {
        if (!given[i] || lstrcmpiW(given[i], family) != 0) continue;
        if (lstrcmpiW(paths[i], path) == 0) return 0;
        others = 1;
    }
    return others;
}

/* The face's own WWS family name, empty when it has none. */
static void own_family(IDWriteFontSet *one, WCHAR out[256]) {
    out[0] = 0;
    BOOL exists = FALSE;
    IDWriteLocalizedStrings *names = NULL;
    if (FAILED(IDWriteFontSet_GetPropertyValues(one, 0, DWRITE_FONT_PROPERTY_ID_WEIGHT_STRETCH_STYLE_FAMILY_NAME, &exists, &names)) || !names) return;
    UINT32 index = 0;
    BOOL found = FALSE;
    if (FAILED(IDWriteLocalizedStrings_FindLocaleName(names, L"en-us", &index, &found)) || !found) index = 0;
    UINT32 length = 0;
    if (IDWriteLocalizedStrings_GetCount(names) && SUCCEEDED(IDWriteLocalizedStrings_GetStringLength(names, index, &length)) && length < 256) IDWriteLocalizedStrings_GetString(names, index, out, 256);
    IDWriteLocalizedStrings_Release(names);
}

#define MAX_PROPERTIES 96
/* Adds a face under `family`: with its own properties, its weight,
   stretch and style among them, but for its family names. */
static HRESULT add_given(IDWriteFontSetBuilder *builder, IDWriteFontFaceReference *reference, IDWriteFontSet *one, const WCHAR *family) {
    DWRITE_FONT_PROPERTY properties[MAX_PROPERTIES];
    WCHAR *strings[2 * MAX_PROPERTIES];
    UINT32 count = 0, string_count = 0;
    for (UINT32 id = DWRITE_FONT_PROPERTY_ID_WEIGHT_STRETCH_STYLE_FAMILY_NAME; id <= DWRITE_FONT_PROPERTY_ID_TYPOGRAPHIC_FACE_NAME; id++) {
        if (id == DWRITE_FONT_PROPERTY_ID_WEIGHT_STRETCH_STYLE_FAMILY_NAME || id == DWRITE_FONT_PROPERTY_ID_TYPOGRAPHIC_FAMILY_NAME || id == DWRITE_FONT_PROPERTY_ID_WIN32_FAMILY_NAME) {
            properties[count++] = (DWRITE_FONT_PROPERTY){(DWRITE_FONT_PROPERTY_ID)id, family, L"en-us"};
            continue;
        }
        BOOL exists = FALSE;
        IDWriteLocalizedStrings *values = NULL;
        /* A property the system does not know, as the typographic face name
           before Windows 10 1709, is left out. */
        if (FAILED(IDWriteFontSet_GetPropertyValues(one, 0, (DWRITE_FONT_PROPERTY_ID)id, &exists, &values)) || !values) continue;
        for (UINT32 j = 0; j < IDWriteLocalizedStrings_GetCount(values) && count < MAX_PROPERTIES; j++) {
            UINT32 length = 0, locale_length = 0;
            if (FAILED(IDWriteLocalizedStrings_GetStringLength(values, j, &length)) || FAILED(IDWriteLocalizedStrings_GetLocaleNameLength(values, j, &locale_length))) continue;
            WCHAR *value = HeapAlloc(GetProcessHeap(), 0, (length + 1) * sizeof(WCHAR)), *locale = HeapAlloc(GetProcessHeap(), 0, (locale_length + 1) * sizeof(WCHAR));
            if (value) strings[string_count++] = value;
            if (locale) strings[string_count++] = locale;
            if (!value || !locale || FAILED(IDWriteLocalizedStrings_GetString(values, j, value, length + 1)) || FAILED(IDWriteLocalizedStrings_GetLocaleName(values, j, locale, locale_length + 1))) continue;
            properties[count++] = (DWRITE_FONT_PROPERTY){(DWRITE_FONT_PROPERTY_ID)id, value, locale};
        }
        IDWriteLocalizedStrings_Release(values);
    }
    HRESULT hr = IDWriteFontSetBuilder_AddFontFaceReference_(builder, reference, properties, count);
    for (UINT32 i = 0; i < string_count; i++) HeapFree(GetProcessHeap(), 0, strings[i]);
    return hr;
}

/* A set of the one face. */
static IDWriteFontSet *face_set(IDWriteFactory3 *f3, IDWriteFontFaceReference *reference) {
    IDWriteFontSetBuilder *builder = NULL;
    IDWriteFontSet *set = NULL;
    if (FAILED(IDWriteFactory3_CreateFontSetBuilder(f3, &builder)) || !builder) return NULL;
    if (FAILED(IDWriteFontSetBuilder_AddFontFaceReference(builder, reference)) || FAILED(IDWriteFontSetBuilder_CreateFontSet(builder, &set))) set = NULL;
    IDWriteFontSetBuilder_Release(builder);
    return set;
}

static IDWriteFontCollection *build(IDWriteFactory *factory) {
    IDWriteFactory3 *f3 = NULL;
    if (FAILED(IDWriteFactory_QueryInterface(factory, &factory3_iid, (void **)&f3)) || !f3) return NULL;
    IDWriteFontSet *system = NULL, *set = NULL;
    IDWriteFontSetBuilder *builder = NULL;
    IDWriteFontCollection1 *collection = NULL;
    if (FAILED(IDWriteFactory3_GetSystemFontSet(f3, &system)) || FAILED(IDWriteFactory3_CreateFontSetBuilder(f3, &builder))) goto done;
    if (FAILED(IDWriteFontSetBuilder_AddFontSet(builder, system))) goto done;
    for (uint32_t i = 0; i < path_count; i++) {
        IDWriteFontFile *file = NULL;
        if (FAILED(IDWriteFactory_CreateFontFileReference(factory, paths[i], NULL, &file)) || !file) continue;
        BOOL supported = FALSE;
        DWRITE_FONT_FILE_TYPE file_type;
        DWRITE_FONT_FACE_TYPE face_type;
        UINT32 faces = 0;
        if (SUCCEEDED(IDWriteFontFile_Analyze(file, &supported, &file_type, &face_type, &faces)) && supported) {
            for (UINT32 face = 0; face < faces; face++) {
                IDWriteFontFaceReference *reference = NULL;
                if (FAILED(IDWriteFactory3_CreateFontFaceReference_(f3, file, face, DWRITE_FONT_SIMULATIONS_NONE, &reference)) || !reference) continue;
                IDWriteFontSet *one = face_set(f3, reference);
                if (given[i]) {
                    /* Under the family the app gave, unless it is its own,
                       which the file's own entry holds. */
                    WCHAR own[256];
                    if (one) own_family(one, own); else own[0] = 0;
                    if (one && own[0] && lstrcmpiW(own, given[i]) != 0) add_given(builder, reference, one, given[i]);
                } else {
                    /* Under its own family, unless the app gives that
                       family other files: it then holds only those. */
                    WCHAR own[256];
                    if (one) own_family(one, own); else own[0] = 0;
                    if (!own[0] || !taken(own, paths[i])) IDWriteFontSetBuilder_AddFontFaceReference(builder, reference);
                }
                if (one) IDWriteFontSet_Release(one);
                IDWriteFontFaceReference_Release(reference);
            }
        }
        IDWriteFontFile_Release(file);
    }
    if (FAILED(IDWriteFontSetBuilder_CreateFontSet(builder, &set))) goto done;
    IDWriteFactory3_CreateFontCollectionFromFontSet(f3, set, &collection);
done:
    if (set) IDWriteFontSet_Release(set);
    if (builder) IDWriteFontSetBuilder_Release(builder);
    if (system) IDWriteFontSet_Release(system);
    IDWriteFactory3_Release(f3);
    return (IDWriteFontCollection *)collection;
}

/* The collection to make text formats from with `factory`: NULL, the
   system's, until a font is registered. `*cache` holds a reference the
   caller releases; `*seen` is the generation it was made for. */
IDWriteFontCollection *zfont_collection(IDWriteFactory *factory, uint64_t *seen, IDWriteFontCollection **cache) {
    if (*seen == generation) return *cache;
    if (*cache) IDWriteFontCollection_Release(*cache);
    *cache = path_count ? build(factory) : NULL;
    *seen = generation;
    return *cache;
}

typedef void (*ZfontEach)(void *context, const WCHAR *name, uint32_t length, int monospaced);

int zfont_list(void *context, ZfontEach each) {
    IDWriteFactory *factory = NULL;
    if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_ISOLATED, &factory_iid, (IUnknown **)&factory)) || !factory) return 1;
    IDWriteFontCollection *collection = NULL;
    if (FAILED(IDWriteFactory_GetSystemFontCollection(factory, &collection, FALSE)) || !collection) { IDWriteFactory_Release(factory); return 1; }
    UINT32 count = IDWriteFontCollection_GetFontFamilyCount(collection);
    for (UINT32 i = 0; i < count; i++) {
        IDWriteFontFamily *family = NULL;
        if (FAILED(IDWriteFontCollection_GetFontFamily(collection, i, &family)) || !family) continue;
        IDWriteLocalizedStrings *names = NULL;
        if (SUCCEEDED(IDWriteFontFamily_GetFamilyNames(family, &names)) && names) {
            UINT32 index = 0; BOOL exists = FALSE;
            if (FAILED(IDWriteLocalizedStrings_FindLocaleName(names, L"en-us", &index, &exists)) || !exists) index = 0;
            UINT32 length = 0;
            WCHAR name[256];
            if (SUCCEEDED(IDWriteLocalizedStrings_GetStringLength(names, index, &length)) && length < 256 && SUCCEEDED(IDWriteLocalizedStrings_GetString(names, index, name, 256))) {
                int monospaced = 0;
                IDWriteFont *font = NULL;
                if (SUCCEEDED(IDWriteFontFamily_GetFirstMatchingFont(family, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE_NORMAL, &font)) && font) {
                    IDWriteFont1 *font1 = NULL;
                    if (SUCCEEDED(IDWriteFont_QueryInterface(font, &font1_iid, (void **)&font1)) && font1) {
                        monospaced = IDWriteFont1_IsMonospacedFont(font1) ? 1 : 0;
                        IDWriteFont1_Release(font1);
                    }
                    IDWriteFont_Release(font);
                }
                each(context, name, length, monospaced);
            }
            IDWriteLocalizedStrings_Release(names);
        }
        IDWriteFontFamily_Release(family);
    }
    IDWriteFontCollection_Release(collection);
    IDWriteFactory_Release(factory);
    return 0;
}
