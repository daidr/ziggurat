/* Blocking GIO/GDBus shell operations for shell.Worker on Linux. Every entry
   point runs on the caller's worker thread, takes NUL-terminated UTF-8 that
   Zig has already validated, keeps no state between calls and releases every
   GLib object before return. Nothing here touches a main context, the
   display or GTK's shared objects: icons come from an icon theme object of
   the call's own, never the default one. */
#include <gio/gio.h>
#include <gio/gdesktopappinfo.h>
#include <gtk/gtk.h>
#include <stdint.h>
#include <string.h>

enum {
    ZSH_OK = 0,
    ZSH_FAILED = 1,
    ZSH_NOT_SUPPORTED = 2,
    ZSH_NOT_FOUND = 3,
    ZSH_ACCESS_DENIED = 4,
    ZSH_UNAVAILABLE = 5,
    ZSH_TIMED_OUT = 6,
    ZSH_INVALID = 7,
};
enum { ZSH_DOMAIN_NONE = 0, ZSH_DOMAIN_GIO = 1, ZSH_DOMAIN_DBUS = 2, ZSH_DOMAIN_GLIB = 3 };
typedef struct ZshFailure { uint32_t domain, code; } ZshFailure;

static int classify(GError *error, ZshFailure *failure) {
    int status = ZSH_FAILED;
    failure->code = (uint32_t)error->code;
    if (error->domain == G_IO_ERROR) {
        failure->domain = ZSH_DOMAIN_GIO;
        switch (error->code) {
        case G_IO_ERROR_NOT_SUPPORTED: status = ZSH_NOT_SUPPORTED; break;
        case G_IO_ERROR_NOT_FOUND: status = ZSH_NOT_FOUND; break;
        case G_IO_ERROR_PERMISSION_DENIED: status = ZSH_ACCESS_DENIED; break;
        case G_IO_ERROR_TIMED_OUT: status = ZSH_TIMED_OUT; break;
        default: break;
        }
    } else if (error->domain == G_DBUS_ERROR) {
        failure->domain = ZSH_DOMAIN_DBUS;
        switch (error->code) {
        case G_DBUS_ERROR_SERVICE_UNKNOWN:
        case G_DBUS_ERROR_NAME_HAS_NO_OWNER:
        case G_DBUS_ERROR_UNKNOWN_METHOD:
        case G_DBUS_ERROR_UNKNOWN_OBJECT:
        case G_DBUS_ERROR_UNKNOWN_INTERFACE:
        case G_DBUS_ERROR_SPAWN_SERVICE_NOT_FOUND:
            status = ZSH_UNAVAILABLE;
            break;
        case G_DBUS_ERROR_TIMEOUT:
        case G_DBUS_ERROR_TIMED_OUT:
        case G_DBUS_ERROR_NO_REPLY:
            status = ZSH_TIMED_OUT;
            break;
        case G_DBUS_ERROR_ACCESS_DENIED: status = ZSH_ACCESS_DENIED; break;
        default: break;
        }
    } else {
        failure->domain = ZSH_DOMAIN_GLIB;
    }
    g_error_free(error);
    return status;
}

/* No GAppLaunchContext: no startup-notification token or display is chosen
   for the handler. GLib spawns the handler detached (or activates it over
   D-Bus); no child is returned or retained. */
int zsh_open_uri(const char *uri, ZshFailure *failure) {
    GError *error = NULL;
    if (g_app_info_launch_default_for_uri(uri, NULL, &error)) return ZSH_OK;
    return classify(error, failure);
}

int zsh_open_path(const char *path, ZshFailure *failure) {
    GError *error = NULL;
    char *uri = g_filename_to_uri(path, NULL, &error);
    if (!uri) {
        classify(error, failure);
        return ZSH_INVALID;
    }
    gboolean launched = g_app_info_launch_default_for_uri(uri, NULL, &error);
    g_free(uri);
    if (launched) return ZSH_OK;
    return classify(error, failure);
}

int zsh_trash(const char *path, ZshFailure *failure) {
    GError *error = NULL;
    GFile *file = g_file_new_for_path(path);
    gboolean trashed = g_file_trash(file, NULL, &error);
    g_object_unref(file);
    if (trashed) return ZSH_OK;
    return classify(error, failure);
}

/* One private session-bus connection per call, closed before return, so no
   bus connection outlives the operation. GDBus serves the connection from its
   own process-wide worker thread; this file starts no thread itself. */
int zsh_reveal(const char *path, int timeout_ms, ZshFailure *failure) {
    GError *error = NULL;
    char *uri = g_filename_to_uri(path, NULL, &error);
    if (!uri) {
        classify(error, failure);
        return ZSH_INVALID;
    }
    char *address = g_dbus_address_get_for_bus_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (!address) {
        g_free(uri);
        classify(error, failure);
        return ZSH_UNAVAILABLE;
    }
    GDBusConnection *connection = g_dbus_connection_new_for_address_sync(
        address, G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION, NULL, NULL, &error);
    g_free(address);
    if (!connection) {
        g_free(uri);
        classify(error, failure);
        return ZSH_UNAVAILABLE;
    }
    g_dbus_connection_set_exit_on_close(connection, FALSE);
    GVariantBuilder items;
    g_variant_builder_init(&items, G_VARIANT_TYPE("as"));
    g_variant_builder_add(&items, "s", uri);
    g_free(uri);
    GVariant *reply = g_dbus_connection_call_sync(
        connection, "org.freedesktop.FileManager1", "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1", "ShowItems",
        g_variant_new("(ass)", &items, ""), NULL, G_DBUS_CALL_FLAGS_NONE, timeout_ms, NULL, &error);
    int status = ZSH_OK;
    if (reply) g_variant_unref(reply);
    else status = classify(error, failure);
    g_dbus_connection_close_sync(connection, NULL, NULL);
    g_object_unref(connection);
    return status;
}

/* Visits the applications that menus show (not NoDisplay or Hidden, and
   meant for this desktop) with their display names, desktop file IDs and
   entry paths. A nonzero visit result stops early and is returned. */
typedef int (*ZshAppVisit)(void *context, const char *name, const char *id, const char *path);
int zsh_apps(ZshAppVisit visit, void *context) {
    GList *list = g_app_info_get_all();
    int status = ZSH_OK;
    for (GList *item = list; item; item = item->next) {
        GAppInfo *info = item->data;
        if (status == ZSH_OK && G_IS_DESKTOP_APP_INFO(info) && g_app_info_should_show(info)) {
            const char *path = g_desktop_app_info_get_filename(G_DESKTOP_APP_INFO(info));
            const char *name = g_app_info_get_display_name(info);
            const char *id = g_app_info_get_id(info);
            if (path && name && id && name[0] && id[0]) status = visit(context, name, id, path);
        }
        g_object_unref(info);
    }
    g_list_free(list);
    return status;
}

/* Launches the application of a desktop entry. Without GTK on this worker
   there is no display launch context, so no startup notification. */
int zsh_launch_app(const char *path, ZshFailure *failure) {
    GDesktopAppInfo *info = g_desktop_app_info_new_from_filename(path);
    if (!info) return ZSH_NOT_FOUND;
    GError *error = NULL;
    gboolean launched = g_app_info_launch(G_APP_INFO(info), NULL, NULL, &error);
    g_object_unref(info);
    if (launched) return ZSH_OK;
    return classify(error, failure);
}

/* The icon theme the desktop names (org.gnome.desktop.interface icon-theme,
   which GTK's settings follow under GNOME and most desktops), else Adwaita,
   with hicolor behind it as every theme has. */
static GtkIconTheme *icon_theme(void) {
    GtkIconTheme *theme = gtk_icon_theme_new();
    gchar *name = NULL;
    GSettingsSchemaSource *source = g_settings_schema_source_get_default();
    GSettingsSchema *schema = source ? g_settings_schema_source_lookup(source, "org.gnome.desktop.interface", TRUE) : NULL;
    if (schema) {
        if (g_settings_schema_has_key(schema, "icon-theme")) {
            GSettings *settings = g_settings_new_full(schema, NULL, NULL);
            name = g_settings_get_string(settings, "icon-theme");
            g_object_unref(settings);
        }
        g_settings_schema_unref(schema);
    }
    gtk_icon_theme_set_custom_theme(theme, name && name[0] ? name : "Adwaita");
    g_free(name);
    return theme;
}

/* Draws icon from the icon theme at size by size pixels over background
   (0xRRGGBB) into out, top-down RGBA8 with alpha 255, centered where the
   theme's image is smaller. */
static int theme_icon(GIcon *icon, int size, uint32_t background, unsigned char *out) {
    if (!icon) return ZSH_NOT_SUPPORTED; /* no icon: not a missing file */
    GtkIconTheme *theme = icon_theme();
    GtkIconInfo *info = gtk_icon_theme_lookup_by_gicon(theme, icon, size, GTK_ICON_LOOKUP_FORCE_SIZE);
    GdkPixbuf *pixbuf = info ? gtk_icon_info_load_icon(info, NULL) : NULL;
    if (info) g_object_unref(info);
    g_object_unref(theme);
    if (!pixbuf) return ZSH_NOT_SUPPORTED;
    if (gdk_pixbuf_get_width(pixbuf) > size || gdk_pixbuf_get_height(pixbuf) > size) {
        GdkPixbuf *scaled = gdk_pixbuf_scale_simple(pixbuf, size, size, GDK_INTERP_BILINEAR);
        g_object_unref(pixbuf);
        if (!scaled) return ZSH_FAILED;
        pixbuf = scaled;
    }
    const int width = gdk_pixbuf_get_width(pixbuf), height = gdk_pixbuf_get_height(pixbuf);
    const int channels = gdk_pixbuf_get_n_channels(pixbuf), stride = gdk_pixbuf_get_rowstride(pixbuf);
    const gboolean alpha = gdk_pixbuf_get_has_alpha(pixbuf);
    if (gdk_pixbuf_get_bits_per_sample(pixbuf) != 8 || channels < 3) { g_object_unref(pixbuf); return ZSH_FAILED; }
    const guchar *pixels = gdk_pixbuf_read_pixels(pixbuf);
    const unsigned char back[3] = {(unsigned char)(background >> 16), (unsigned char)(background >> 8), (unsigned char)background};
    for (int i = 0; i < size * size; i++) {
        memcpy(out + i * 4, back, 3);
        out[i * 4 + 3] = 255;
    }
    const int left = (size - width) / 2, top = (size - height) / 2;
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            const guchar *from = pixels + y * stride + x * channels;
            unsigned char *to = out + ((top + y) * size + left + x) * 4;
            const unsigned a = alpha ? from[3] : 255;
            for (int c = 0; c < 3; c++) to[c] = (unsigned char)((from[c] * a + to[c] * (255 - a) + 127) / 255);
        }
    }
    g_object_unref(pixbuf);
    return ZSH_OK;
}

/* The icon the file manager shows for an item: a desktop entry's own icon,
   else GIO's standard::icon of the file. */
int zsh_file_icon(const char *path, int size, uint32_t background, unsigned char *out, ZshFailure *failure) {
    GIcon *icon = NULL;
    if (g_str_has_suffix(path, ".desktop")) {
        GDesktopAppInfo *app = g_desktop_app_info_new_from_filename(path);
        if (app) {
            GIcon *own = g_app_info_get_icon(G_APP_INFO(app));
            if (own) icon = g_object_ref(own);
            g_object_unref(app);
        }
    }
    if (!icon) {
        GError *error = NULL;
        GFile *file = g_file_new_for_path(path);
        GFileInfo *info = g_file_query_info(file, G_FILE_ATTRIBUTE_STANDARD_ICON, G_FILE_QUERY_INFO_NONE, NULL, &error);
        g_object_unref(file);
        if (!info) return classify(error, failure);
        GIcon *own = g_file_info_get_icon(info);
        if (own) icon = g_object_ref(own);
        g_object_unref(info);
    }
    int status = theme_icon(icon, size, background, out);
    if (icon) g_object_unref(icon);
    return status;
}

/* The icon the file manager shows for files with an extension, though no
   such file exists: that of the content type GIO guesses from such a name. */
int zsh_type_icon(const char *extension, int size, uint32_t background, unsigned char *out) {
    gchar *name = g_strconcat("file.", extension, NULL);
    gchar *type = g_content_type_guess(name, NULL, 0, NULL);
    g_free(name);
    GIcon *icon = type ? g_content_type_get_icon(type) : NULL;
    g_free(type);
    int status = theme_icon(icon, size, background, out);
    if (icon) g_object_unref(icon);
    return status;
}

/* The content type of the file at path, as GIO finds it from its name and
   first bytes (inode/directory for a folder), or what its whole name tells
   where there is no such file, as "Makefile" or "notes.txt". Owned. */
static char *content_type(const char *path) {
    GFile *file = g_file_new_for_path(path);
    GFileInfo *info = g_file_query_info(file, G_FILE_ATTRIBUTE_STANDARD_CONTENT_TYPE, G_FILE_QUERY_INFO_NONE, NULL, NULL);
    g_object_unref(file);
    if (info) {
        const char *type = g_file_info_get_content_type(info);
        char *owned = type ? g_strdup(type) : NULL;
        g_object_unref(info);
        if (owned) return owned;
    }
    char *base = g_path_get_basename(path);
    char *guessed = g_content_type_guess(base, NULL, 0, NULL);
    g_free(base);
    return guessed;
}

/* The application that opens a URL of `scheme`, or else the file at `path`:
   the default handler of the scheme, or of the file's content type. It is
   visited once with the display name, desktop file ID and entry path that
   zsh_apps gives. */
int zsh_default_app(const char *url, const char *scheme, const char *path, ZshAppVisit visit, void *context, ZshFailure *failure) {
    (void)url; (void)failure;
    GAppInfo *info = NULL;
    if (scheme) info = g_app_info_get_default_for_uri_scheme(scheme);
    else if (path) {
        char *type = content_type(path);
        if (!type) return ZSH_NOT_SUPPORTED;
        info = g_app_info_get_default_for_type(type, FALSE);
        g_free(type);
    } else return ZSH_INVALID;
    if (!info) return ZSH_NOT_SUPPORTED;
    const char *id = g_app_info_get_id(info);
    const char *entry = G_IS_DESKTOP_APP_INFO(info) ? g_desktop_app_info_get_filename(G_DESKTOP_APP_INFO(info)) : NULL;
    const char *name = g_app_info_get_display_name(info);
    int status = visit(context, name ? name : "", id ? id : "", entry ? entry : id ? id : "");
    g_object_unref(info);
    return status;
}
