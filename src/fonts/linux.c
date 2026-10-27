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

/* A font map of its own sees fonts added since `seen`. */
void zfont_refresh(void *map, uint64_t *seen) {
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
