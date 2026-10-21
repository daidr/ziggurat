#include <gio/gio.h>
#include <gio/gunixfdlist.h>
#include <unistd.h>

/* systemd-logind inhibitor. The returned descriptor is the inhibitor: closing
 * the last copy releases it. 0 ok, 1 service unavailable, 2 denied,
 * 3 timeout, 4 other failure. */
int ziggurat_system_logind_inhibit(const char *what, const char *who, const char *why, int timeout_ms, int *fd) {
    *fd = -1;
    GError *error = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, &error);
    if (bus == NULL) {
        g_clear_error(&error);
        return 1;
    }
    GUnixFDList *descriptors = NULL;
    GVariant *reply = g_dbus_connection_call_with_unix_fd_list_sync(
        bus, "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "Inhibit",
        g_variant_new("(ssss)", what, who, why, "block"), G_VARIANT_TYPE("(h)"), G_DBUS_CALL_FLAGS_NO_AUTO_START,
        timeout_ms, NULL, &descriptors, NULL, &error);
    g_object_unref(bus);
    if (reply == NULL) {
        int status = 4;
        if (g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_SERVICE_UNKNOWN) || g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_NAME_HAS_NO_OWNER) ||
            g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD) || g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_OBJECT))
            status = 1;
        else if (g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_ACCESS_DENIED) || g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_AUTH_FAILED))
            status = 2;
        else if (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT) || g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_TIMEOUT) ||
                 g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_NO_REPLY))
            status = 3;
        g_clear_error(&error);
        if (descriptors != NULL) g_object_unref(descriptors);
        return status;
    }
    gint32 index = -1;
    g_variant_get(reply, "(h)", &index);
    g_variant_unref(reply);
    int status = 4;
    if (descriptors != NULL && index >= 0 && index < g_unix_fd_list_get_length(descriptors)) {
        /* get duplicates the descriptor; the list keeps and closes its own. */
        *fd = g_unix_fd_list_get(descriptors, index, NULL);
        if (*fd >= 0) status = 0;
    }
    if (descriptors != NULL) g_object_unref(descriptors);
    return status;
}

void *ziggurat_system_launcher_open(int *status) {
    GError *error = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    *status = bus == NULL ? 1 : 0;
    g_clear_error(&error);
    return bus;
}

/* Emits com.canonical.Unity.LauncherEntry.Update(s app_uri, a{sv} properties).
 * The connection queues the message; no reply exists for a signal. */
int ziggurat_system_launcher_update(void *connection, const char *uri, const char *path, int progress_visible, double progress, int count_visible, gint64 count, int urgent) {
    GVariantBuilder properties;
    g_variant_builder_init(&properties, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&properties, "{sv}", "progress-visible", g_variant_new_boolean(progress_visible != 0));
    g_variant_builder_add(&properties, "{sv}", "progress", g_variant_new_double(progress));
    g_variant_builder_add(&properties, "{sv}", "count-visible", g_variant_new_boolean(count_visible != 0));
    g_variant_builder_add(&properties, "{sv}", "count", g_variant_new_int64(count));
    g_variant_builder_add(&properties, "{sv}", "urgent", g_variant_new_boolean(urgent != 0));
    GError *error = NULL;
    gboolean sent = g_dbus_connection_emit_signal(connection, NULL, path, "com.canonical.Unity.LauncherEntry", "Update",
                                                  g_variant_new("(sa{sv})", uri, &properties), &error);
    g_clear_error(&error);
    return sent ? 0 : 1;
}

void ziggurat_system_launcher_close(void *connection) {
    /* Deliver queued updates before dropping this owner's reference; the bus
     * singleton may be shared with GTK or other modules. */
    g_dbus_connection_flush_sync(connection, NULL, NULL);
    g_object_unref(connection);
}
