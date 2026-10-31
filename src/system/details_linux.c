/* GTK pieces of icons and the app's light/dark choice.
   Every entry runs on the GTK main thread that owns the App. */
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
        return;
    }
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
