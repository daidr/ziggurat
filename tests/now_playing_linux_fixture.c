// An MPRIS client on its own session-bus connection, as a desktop's media
// controls are. Calls are asynchronous and complete on the main context.
#include <gio/gio.h>
#include <string.h>

static GDBusConnection *client;
static int pending;
static char *last_text;
static char *player_name;

int znpf_start(void) {
    char *address = g_dbus_address_get_for_bus_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    if (!address) return 0;
    client = g_dbus_connection_new_for_address_sync(address, G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION, NULL, NULL, NULL);
    g_free(address);
    return client != NULL;
}

int znpf_pending(void) { return pending; }
const char *znpf_text(void) { return last_text ? last_text : ""; }
const char *znpf_player(void) { return player_name ? player_name : ""; }

static void finished(GObject *source, GAsyncResult *result, gpointer data) {
    (void)data;
    GError *error = NULL;
    GVariant *value = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
    g_clear_pointer(&last_text, g_free);
    if (value) {
        last_text = g_variant_print(value, TRUE);
        g_variant_unref(value);
    } else {
        last_text = g_strdup_printf("error: %s", error ? error->message : "?");
        g_clear_error(&error);
    }
    pending--;
}

static void names(GObject *source, GAsyncResult *result, gpointer data) {
    (void)data;
    GVariant *value = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, NULL);
    g_clear_pointer(&player_name, g_free);
    if (value) {
        GVariantIter *iter;
        const char *name;
        g_variant_get(value, "(as)", &iter);
        while (g_variant_iter_next(iter, "&s", &name)) {
            if (g_str_has_prefix(name, "org.mpris.MediaPlayer2.")) player_name = g_strdup(name);
        }
        g_variant_iter_free(iter);
        g_variant_unref(value);
    }
    pending--;
}

void znpf_find_player(void) {
    pending++;
    g_dbus_connection_call(client, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames", NULL, G_VARIANT_TYPE("(as)"), G_DBUS_CALL_FLAGS_NONE, 5000, NULL, names, NULL);
}

static void player_call(const char *interface, const char *method, GVariant *params) {
    pending++;
    g_dbus_connection_call(client, player_name, "/org/mpris/MediaPlayer2", interface, method, params, NULL, G_DBUS_CALL_FLAGS_NONE, 5000, NULL, finished, NULL);
}

void znpf_call(const char *method) { player_call("org.mpris.MediaPlayer2.Player", method, NULL); }
void znpf_seek(gint64 offset) { player_call("org.mpris.MediaPlayer2.Player", "Seek", g_variant_new("(x)", offset)); }
void znpf_set_position(const char *track, gint64 position) { player_call("org.mpris.MediaPlayer2.Player", "SetPosition", g_variant_new("(ox)", track, position)); }
void znpf_get(const char *interface, const char *property) { player_call("org.freedesktop.DBus.Properties", "Get", g_variant_new("(ss)", interface, property)); }
void znpf_open_uri(const char *uri) { player_call("org.mpris.MediaPlayer2.Player", "OpenUri", g_variant_new("(s)", uri)); }
