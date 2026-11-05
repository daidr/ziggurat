/* GTK pieces of icons and the app's light/dark choice.
   Every entry runs on the GTK main thread that owns the App. */
#include <dlfcn.h>
#include <gtk/gtk.h>
#include <stdint.h>
#include <string.h>

/* A new GdkPixbuf decoded from PNG bytes, or NULL. */
void *zsx_icon_from_png(const uint8_t *data, size_t length) {
    GdkPixbufLoader *loader = gdk_pixbuf_loader_new_with_type("png", NULL);
    if (!loader) return NULL;
    gboolean ok = gdk_pixbuf_loader_write(loader, data, length, NULL);
    ok = gdk_pixbuf_loader_close(loader, NULL) && ok;
    GdkPixbuf *pixbuf = ok ? gdk_pixbuf_loader_get_pixbuf(loader) : NULL;
    if (pixbuf) g_object_ref(pixbuf);
    g_object_unref(loader);
    return pixbuf;
}
void zsx_icon_release(void *pixbuf) { g_object_unref(pixbuf); }

/* A menu item icon (menu_icon.zig): the decoded image, its copies fit to
   the 16 DIP box at scales 1 to 4, made as menus ask for them, and the PNG
   bytes a tray's DBusMenu sends. */
typedef struct MenuIcon { GdkPixbuf *source; GBytes *png; cairo_surface_t *sized[4]; } MenuIcon;
enum { MENU_ICON_BOX = 16 };
void *zsx_menu_icon_new(const uint8_t *data, size_t length) {
    GdkPixbuf *pixbuf = zsx_icon_from_png(data, length);
    if (!pixbuf) return NULL;
    MenuIcon *icon = g_new0(MenuIcon, 1);
    icon->source = pixbuf;
    icon->png = g_bytes_new(data, length);
    return icon;
}
void zsx_menu_icon_free(void *native) {
    MenuIcon *icon = native;
    for (int i = 0; i < 4; ++i) if (icon->sized[i]) cairo_surface_destroy(icon->sized[i]);
    g_bytes_unref(icon->png);
    g_object_unref(icon->source);
    g_free(icon);
}
/* A new GtkImage of the icon for widgets at scale. */
GtkWidget *zsx_menu_icon_image(void *native, int scale) {
    MenuIcon *icon = native;
    scale = CLAMP(scale, 1, 4);
    if (!icon->sized[scale - 1]) {
        int width = gdk_pixbuf_get_width(icon->source), height = gdk_pixbuf_get_height(icon->source), side = MENU_ICON_BOX * scale;
        int w = width >= height ? side : MAX((width * side + height / 2) / height, 1);
        int h = width >= height ? MAX((height * side + width / 2) / width, 1) : side;
        GdkPixbuf *scaled = gdk_pixbuf_scale_simple(icon->source, w, h, GDK_INTERP_HYPER);
        if (!scaled) return gtk_image_new();
        icon->sized[scale - 1] = gdk_cairo_surface_create_from_pixbuf(scaled, scale, NULL);
        g_object_unref(scaled);
    }
    return gtk_image_new_from_surface(icon->sized[scale - 1]);
}
/* The PNG bytes, borrowed. */
GBytes *zsx_menu_icon_png(void *native) { return ((MenuIcon *)native)->png; }
void zsx_window_set_icon(void *window, void *pixbuf) { gtk_window_set_icon(GTK_WINDOW(window), pixbuf); }
/* The window's icon, borrowed, for checks. */
void *zsx_window_icon(void *window) { return gtk_window_get_icon(GTK_WINDOW(window)); }

/* The app's appearance: 0 follows the desktop, 1 forces light, 2 dark.
   Following the desktop gives GTK's own settings back. A theme named for
   its dark variant (such as "Yaru-dark") stays dark whatever
   gtk-application-prefer-dark-theme says, so light takes the theme of the
   name without the suffix. Properties change only when their value does,
   so the notifications a desktop watch sees always mean a change. */
static gboolean theme_overridden, theme_renamed;
/* The core follows the settings portal's color-scheme while the app follows
   the desktop (platform/linux.c). */
extern void zlg_follow_portal_scheme(int follow) __attribute__((weak));
void zsx_theme_set_source(int source) {
    GtkSettings *settings = gtk_settings_get_default();
    if (!settings) return;
    if (source != 1 && theme_renamed) {
        theme_renamed = FALSE;
        gtk_settings_reset_property(settings, "gtk-theme-name");
    }
    if (source == 0) {
        if (theme_overridden) {
            theme_overridden = FALSE;
            gtk_settings_reset_property(settings, "gtk-application-prefer-dark-theme");
        }
        if (zlg_follow_portal_scheme) zlg_follow_portal_scheme(1);
        return;
    }
    if (zlg_follow_portal_scheme) zlg_follow_portal_scheme(0);
    if (source == 1 && !theme_renamed) {
        gchar *name = NULL;
        g_object_get(settings, "gtk-theme-name", &name, NULL);
        size_t length = name ? strlen(name) : 0;
        if (length > 5 && g_ascii_strcasecmp(name + length - 5, "-dark") == 0) {
            name[length - 5] = 0;
            theme_renamed = TRUE;
            g_object_set(settings, "gtk-theme-name", name, NULL);
        }
        g_free(name);
    }
    gboolean dark = source == 2, current = FALSE;
    g_object_get(settings, "gtk-application-prefer-dark-theme", &current, NULL);
    theme_overridden = TRUE;
    if ((current != 0) != dark) g_object_set(settings, "gtk-application-prefer-dark-theme", dark, NULL);
}

/* Checks for smokes. */
int zsx_theme_prefers_dark(void) {
    gboolean dark = FALSE;
    g_object_get(gtk_settings_get_default(), "gtk-application-prefer-dark-theme", &dark, NULL);
    return dark ? 1 : 0;
}

/* The app's GTK 3 style sheet for what GTK draws itself: decorations,
   header bars, title buttons, menus and dialogs. A provider of its own for
   the default screen at the user's priority, so its rules win over the
   theme's and the user's gtk.css (GTK looks providers up from the highest
   priority, among equal ones from the last added). A sheet loads into a new
   provider, which replaces the one before only once it parsed; "" removes
   it. 0 set, 1 the sheet does not parse (its first error in `message`), 2
   no display. */
static GtkCssProvider *app_css;
int zsx_theme_set_gtk_css(const char *css, size_t length, char *message, size_t capacity) {
    GdkScreen *screen = gdk_screen_get_default();
    if (!screen) return 2;
    if (capacity) message[0] = 0;
    GtkCssProvider *provider = NULL;
    if (length > 0) {
        provider = gtk_css_provider_new();
        GError *error = NULL;
        if (!gtk_css_provider_load_from_data(provider, css, (gssize)length, &error)) {
            if (error && capacity) g_strlcpy(message, error->message, capacity);
            if (error) g_error_free(error);
            g_object_unref(provider);
            return 1;
        }
        gtk_style_context_add_provider_for_screen(screen, GTK_STYLE_PROVIDER(provider), GTK_STYLE_PROVIDER_PRIORITY_USER);
    }
    if (app_css) {
        gtk_style_context_remove_provider_for_screen(screen, GTK_STYLE_PROVIDER(app_css));
        g_object_unref(app_css);
    }
    app_css = provider;
    return 0;
}

/* The window buttons gtk-decoration-layout puts at the start and the end of
   title bars, as "close,minimize:" or ":minimize,maximize,close": only
   minimize, maximize and close, in order, the side's separator kept. None
   where a Wayland compositor decorates windows itself (it prefers
   server-side decorations, as tiling ones such as Sway and Hyprland do),
   whose title bars show none of GTK's. Writes it NUL-terminated into `out`
   and returns its length, -1 without settings. */
static gboolean compositor_decorates(void) {
    GdkDisplay *display = gdk_display_get_default();
    if (!display || strcmp(G_OBJECT_TYPE_NAME(display), "GdkWaylandDisplay") != 0) return FALSE;
    static gboolean (*prefers_ssd)(GdkDisplay *);
    static gboolean bound;
    if (!bound) {
        bound = TRUE;
        void *self = dlopen(NULL, RTLD_LAZY);
        if (self) {
            void *symbol = dlsym(self, "gdk_wayland_display_prefers_ssd");
            memcpy(&prefers_ssd, &symbol, sizeof prefers_ssd);
            dlclose(self);
        }
    }
    return prefers_ssd && prefers_ssd(display);
}
int zsx_theme_window_buttons(char *out, size_t capacity) {
    GtkSettings *settings = gtk_settings_get_default();
    if (!settings || capacity < 32) return -1;
    size_t length = 0;
    out[0] = 0;
    if (compositor_decorates()) {
        out[length++] = ':';
        out[length] = 0;
        return (int)length;
    }
    gchar *layout = NULL;
    g_object_get(settings, "gtk-decoration-layout", &layout, NULL);
    const char *colon = layout ? strchr(layout, ':') : NULL;
    for (int side = 0; side < 2; ++side) {
        const char *begin = side == 0 ? (layout ? layout : "") : (colon ? colon + 1 : "");
        const char *end = side == 0 ? (colon ? colon : begin + strlen(begin)) : begin + strlen(begin);
        gboolean first = TRUE;
        while (begin < end) {
            const char *comma = memchr(begin, ',', (size_t)(end - begin));
            const char *stop = comma ? comma : end;
            while (begin < stop && g_ascii_isspace(*begin)) ++begin;
            const char *last = stop;
            while (last > begin && g_ascii_isspace(last[-1])) --last;
            size_t n = (size_t)(last - begin);
            static const char *const known[] = {"minimize", "maximize", "close"};
            for (int k = 0; k < 3; ++k) {
                if (n != strlen(known[k]) || strncmp(begin, known[k], n) != 0) continue;
                if (length + n + 2 >= capacity) break;
                if (!first) out[length++] = ',';
                memcpy(out + length, begin, n);
                length += n;
                first = FALSE;
            }
            begin = comma ? comma + 1 : end;
        }
        if (side == 0) out[length++] = ':';
    }
    out[length] = 0;
    g_free(layout);
    return (int)length;
}
