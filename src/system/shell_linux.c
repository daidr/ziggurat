/* Blocking GIO/GDBus shell operations for shell.Worker on Linux. Every entry
   point runs on the caller's worker thread, takes NUL-terminated UTF-8 that
   Zig has already validated, keeps no state between calls and releases every
   GLib object before return. Nothing here touches GTK or a main context. */
#include <gio/gio.h>
#include <stdint.h>

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
