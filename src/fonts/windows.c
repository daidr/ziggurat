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
static WCHAR *paths[MAX_FILES];
static uint32_t path_count;
static uint64_t generation;

uint64_t zfont_generation(void) { return generation; }

/* Takes a copy of the path. 0 on success. */
int zfont_add_file(const WCHAR *path) {
    if (path_count == MAX_FILES) return 1;
    size_t n = wcslen(path) + 1;
    WCHAR *copy = HeapAlloc(GetProcessHeap(), 0, n * sizeof(WCHAR));
    if (!copy) return 2;
    memcpy(copy, path, n * sizeof(WCHAR));
    paths[path_count++] = copy;
    generation++;
    return 0;
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
                if (SUCCEEDED(IDWriteFactory3_CreateFontFaceReference_(f3, file, face, DWRITE_FONT_SIMULATIONS_NONE, &reference)) && reference) {
                    IDWriteFontSetBuilder_AddFontFaceReference(builder, reference);
                    IDWriteFontFaceReference_Release(reference);
                }
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
