/* Application fonts through fontconfig, and the families of Pango's font map. */
#include <fontconfig/fontconfig.h>
#include <pango/pangocairo.h>
#include <pango/pangofc-fontmap.h>
#include <stdint.h>
#include <string.h>
#include <strings.h>

static uint64_t generation;

uint64_t zfont_generation(void) { return generation; }

/* Adds the font file to the current configuration's application fonts and
   lets the default font map see it. 0 on success. */
int zfont_add_file(const char *path) {
    FcConfig *config = FcConfigGetCurrent();
    if (!config || !FcConfigAppFontAddFile(config, (const FcChar8 *)path)) return 1;
    PangoFontMap *map = pango_cairo_font_map_get_default();
    if (map && PANGO_IS_FC_FONT_MAP(map)) pango_fc_font_map_config_changed(PANGO_FC_FONT_MAP(map));
    generation++;
    return 0;
}

/* Adds the faces of the font file again under `family` alone, as the app
   named it: copies of their fontconfig patterns with that family and none
   of their own, so that the family holds only the files registered under
   it, matched by weight and style among them, while the font's own family
   keeps all of them. 0 on success. */
int zfont_add_family(const char *path, const char *family) {
    FcConfig *config = FcConfigGetCurrent();
    FcFontSet *fonts = config ? FcConfigGetFonts(config, FcSetApplication) : NULL;
    if (!fonts) return 1;
    FcFontSet *faces = FcFontSetCreate();
    if (!faces) return 1;
    FcFreeTypeQueryAll((const FcChar8 *)path, -1, NULL, NULL, faces);
    int added = 0;
    for (int i = 0; i < faces->nfont; i++) {
        FcPattern *face = FcPatternDuplicate(faces->fonts[i]);
        if (!face) continue;
        FcPatternDel(face, FC_FAMILY);
        FcPatternDel(face, FC_FAMILYLANG);
        FcPatternAddString(face, FC_FAMILY, (const FcChar8 *)family);
        if (FcFontSetAdd(fonts, face)) added++;
        else FcPatternDestroy(face);
    }
    FcFontSetDestroy(faces);
    if (!added) return 1;
    PangoFontMap *map = pango_cairo_font_map_get_default();
    if (map && PANGO_IS_FC_FONT_MAP(map)) pango_fc_font_map_config_changed(PANGO_FC_FONT_MAP(map));
    generation++;
    return 0;
}

/* Fonts whose fontconfig settings name no LCD filter take FreeType's
   (FIR5), which cairo 1.17 and later use for those by default. A filter
   fontconfig names is kept: a test of every value of an element holds where
   the element is missing, and no filter is above 3. */
static const char lcd_filter_rule[] =
    "<?xml version=\"1.0\"?><!DOCTYPE fontconfig SYSTEM \"fonts.dtd\"><fontconfig><match target=\"font\">"
    "<test qual=\"all\" name=\"lcdfilter\" compare=\"more\"><int>3</int></test>"
    "<edit name=\"lcdfilter\" mode=\"assign\"><const>lcddefault</const></edit></match></fontconfig>";

/* Before 1.17, cairo's font options have no public setter for the LCD filter
   and default to FreeType's legacy one, which leaves thin strokes pale with
   coloured fringes in subpixel text; cairo takes a font pattern's filter
   over that default. Once per process, before the first layout. */
static void pin_lcd_filter(void) {
    static int pinned;
    if (pinned) return;
    pinned = 1;
    if (cairo_version() >= CAIRO_VERSION_ENCODE(1, 17, 0)) return;
    FcConfig *config = FcConfigGetCurrent();
    if (config) FcConfigParseAndLoadFromMemory(config, (const FcChar8 *)lcd_filter_rule, FcTrue);
}

/* A font map of its own sees fonts added since `seen`. */
void zfont_refresh(void *map, uint64_t *seen) {
    pin_lcd_filter();
    if (*seen == generation) return;
    *seen = generation;
    if (map && PANGO_IS_FC_FONT_MAP(map)) pango_fc_font_map_config_changed(PANGO_FC_FONT_MAP(map));
}

typedef void (*ZfontEach)(void *context, const char *name, int monospaced);

/* The default font map's families, without the generic ones Pango adds,
   which are aliases rather than fonts. */
int zfont_list(void *context, ZfontEach each) {
    PangoFontMap *map = pango_cairo_font_map_get_default();
    if (!map) return 1;
    PangoFontFamily **families = NULL;
    int count = 0;
    pango_font_map_list_families(map, &families, &count);
    for (int i = 0; i < count; i++) {
        const char *name = pango_font_family_get_name(families[i]);
        if (!name || !name[0] || !strcasecmp(name, "sans") || !strcasecmp(name, "serif") || !strcasecmp(name, "monospace") || !strcasecmp(name, "system-ui")) continue;
        each(context, name, pango_font_family_is_monospace(families[i]));
    }
    g_free(families);
    return 0;
}
