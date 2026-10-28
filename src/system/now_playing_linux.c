// An MPRIS player (org.mpris.MediaPlayer2) on the session bus, which GNOME's
// and KDE's media controls, their lock screens and playerctl show and drive,
// and which the desktops send the media keys to. The app owns its bus name
// only while it shows something, so the player leaves the desktop's controls
// once it shows nothing. Main thread only: GDBus dispatches the player's
// calls on the main context it was registered from.
#include <gio/gio.h>
#include <glib/gstdio.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

struct znp_info {
    const char *title;
    const char *artist;
    const char *album;
    const unsigned char *artwork;
    size_t artwork_len;
    int64_t duration_us;
    int64_t position_us;
    double rate;
    int state; // 0 playing, 1 paused, 2 stopped
    uint32_t commands;
};

typedef void (*znp_deliver)(uint32_t command, int64_t position_us);

enum { CMD_PLAY = 1, CMD_PAUSE = 2, CMD_TOGGLE = 4, CMD_STOP = 8, CMD_NEXT = 16, CMD_PREVIOUS = 32, CMD_SEEK = 64 };

#define MPRIS_PATH "/org/mpris/MediaPlayer2"
#define MPRIS_ROOT "org.mpris.MediaPlayer2"
#define MPRIS_PLAYER "org.mpris.MediaPlayer2.Player"
#define MPRIS_NO_TRACK "/org/mpris/MediaPlayer2/TrackList/NoTrack"

static const char mpris_xml[] =
    "<node>"
    "<interface name='org.mpris.MediaPlayer2'>"
    "<method name='Raise'/><method name='Quit'/>"
    "<property name='CanQuit' type='b' access='read'/>"
    "<property name='CanRaise' type='b' access='read'/>"
    "<property name='HasTrackList' type='b' access='read'/>"
    "<property name='Identity' type='s' access='read'/>"
    "<property name='DesktopEntry' type='s' access='read'/>"
    "<property name='SupportedUriSchemes' type='as' access='read'/>"
    "<property name='SupportedMimeTypes' type='as' access='read'/>"
    "</interface>"
    "<interface name='org.mpris.MediaPlayer2.Player'>"
    "<method name='Next'/><method name='Previous'/><method name='Pause'/>"
    "<method name='PlayPause'/><method name='Stop'/><method name='Play'/>"
    "<method name='Seek'><arg direction='in' name='Offset' type='x'/></method>"
    "<method name='SetPosition'><arg direction='in' name='TrackId' type='o'/><arg direction='in' name='Position' type='x'/></method>"
    "<method name='OpenUri'><arg direction='in' name='Uri' type='s'/></method>"
    "<signal name='Seeked'><arg name='Position' type='x'/></signal>"
    "<property name='PlaybackStatus' type='s' access='read'/>"
    "<property name='Rate' type='d' access='read'/>"
    "<property name='Metadata' type='a{sv}' access='read'/>"
    "<property name='Volume' type='d' access='read'/>"
    "<property name='Position' type='x' access='read'/>"
    "<property name='MinimumRate' type='d' access='read'/>"
    "<property name='MaximumRate' type='d' access='read'/>"
    "<property name='CanGoNext' type='b' access='read'/>"
    "<property name='CanGoPrevious' type='b' access='read'/>"
    "<property name='CanPlay' type='b' access='read'/>"
    "<property name='CanPause' type='b' access='read'/>"
    "<property name='CanSeek' type='b' access='read'/>"
    "<property name='CanControl' type='b' access='read'/>"
    "</interface>"
    "</node>";

// The player's state.
static GDBusConnection *mpris_conn;
static gboolean mpris_registered;
static guint mpris_owner;
static gboolean mpris_showing;
static char *mpris_title, *mpris_artist, *mpris_album;
static int64_t mpris_duration_us, mpris_position_us;
static double mpris_rate = 1;
static int mpris_state = 2;
static uint32_t mpris_commands;
static gint64 mpris_at; // monotonic microseconds of mpris_position_us
static unsigned mpris_track; // counts the tracks, for their ids
static char *mpris_art; // the artwork's file
static guint64 mpris_art_hash;
static znp_deliver mpris_deliver;

// An element of a bus name: ASCII letters, digits, _ and -, not starting
// with a digit.
static char *bus_name_element(const char *text) {
    GString *out = g_string_new(NULL);
    for (const char *p = text ? text : ""; *p; p++) {
        char ch = *p;
        if (g_ascii_isalpha(ch) || ch == '_' || ch == '-' || (g_ascii_isdigit(ch) && out->len > 0)) {
            g_string_append_c(out, ch);
        } else if (g_ascii_isdigit(ch)) {
            g_string_append_c(out, '_');
            g_string_append_c(out, ch);
        } else {
            g_string_append_c(out, '_');
        }
    }
    if (out->len == 0) g_string_append(out, "ziggurat");
    return g_string_free(out, FALSE);
}

static const char *app_identity(void) {
    const char *name = g_get_application_name();
    if (name && *name) return name;
    name = g_get_prgname();
    return name && *name ? name : "ziggurat";
}

static int64_t mpris_now_position(void) {
    if (!mpris_showing) return 0;
    double position = (double)mpris_position_us;
    if (mpris_state == 0) position += (double)(g_get_monotonic_time() - mpris_at) * mpris_rate;
    if (mpris_duration_us > 0 && position > (double)mpris_duration_us) position = (double)mpris_duration_us;
    return position < 0 ? 0 : (int64_t)position;
}

static char *mpris_track_id(void) {
    if (!mpris_showing) return g_strdup(MPRIS_NO_TRACK);
    return g_strdup_printf("/org/ziggurat/track/%u", mpris_track);
}

static gboolean mpris_can(uint32_t command) {
    return mpris_showing && (mpris_commands & command) != 0;
}

// The artwork, written to a file whose URL the metadata gives. Clients read
// it whenever they like, so the file stays until the artwork changes.
static void mpris_set_art(const unsigned char *art, size_t len) {
    guint64 hash = 14695981039346656037ull;
    for (size_t i = 0; i < len; i++) hash = (hash ^ art[i]) * 1099511628211ull;
    if (len > 0 && mpris_art && hash == mpris_art_hash) return;
    if (mpris_art) {
        g_unlink(mpris_art);
        g_clear_pointer(&mpris_art, g_free);
    }
    if (len == 0) return;
    // The user's runtime directory goes away as the session ends.
    char *element = bus_name_element(g_get_prgname());
    char *dir = g_build_filename(g_get_user_runtime_dir(), element, NULL);
    g_free(element);
    if (g_mkdir_with_parents(dir, 0700) == 0) {
        char *name = g_strdup_printf("now-playing-%d-%" G_GINT64_MODIFIER "x", (int)getpid(), hash);
        char *path = g_build_filename(dir, name, NULL);
        g_free(name);
        if (g_file_set_contents_full(path, (const char *)art, (gssize)len, G_FILE_SET_CONTENTS_CONSISTENT, 0600, NULL)) {
            mpris_art = path;
            mpris_art_hash = hash;
        } else {
            g_free(path);
        }
    }
    g_free(dir);
}

static GVariant *mpris_metadata(void) {
    GVariantBuilder builder;
    g_variant_builder_init(&builder, G_VARIANT_TYPE("a{sv}"));
    char *track = mpris_track_id();
    g_variant_builder_add(&builder, "{sv}", "mpris:trackid", g_variant_new_object_path(track));
    g_free(track);
    if (mpris_showing) {
        if (*mpris_title) g_variant_builder_add(&builder, "{sv}", "xesam:title", g_variant_new_string(mpris_title));
        if (*mpris_artist) {
            const char *artists[] = {mpris_artist, NULL};
            g_variant_builder_add(&builder, "{sv}", "xesam:artist", g_variant_new_strv(artists, 1));
        }
        if (*mpris_album) g_variant_builder_add(&builder, "{sv}", "xesam:album", g_variant_new_string(mpris_album));
        if (mpris_duration_us > 0) g_variant_builder_add(&builder, "{sv}", "mpris:length", g_variant_new_int64(mpris_duration_us));
        if (mpris_art) {
            char *uri = g_filename_to_uri(mpris_art, NULL, NULL);
            if (uri) g_variant_builder_add(&builder, "{sv}", "mpris:artUrl", g_variant_new_string(uri));
            g_free(uri);
        }
    }
    return g_variant_builder_end(&builder);
}

static GVariant *mpris_property(const char *property) {
    if (!strcmp(property, "CanQuit") || !strcmp(property, "CanRaise") || !strcmp(property, "HasTrackList")) return g_variant_new_boolean(FALSE);
    if (!strcmp(property, "Identity")) return g_variant_new_string(app_identity());
    if (!strcmp(property, "DesktopEntry")) {
        const char *entry = g_get_prgname();
        return g_variant_new_string(entry ? entry : "");
    }
    if (!strcmp(property, "SupportedUriSchemes") || !strcmp(property, "SupportedMimeTypes")) return g_variant_new_strv(NULL, 0);
    if (!strcmp(property, "PlaybackStatus")) {
        static const char *const names[] = {"Playing", "Paused", "Stopped"};
        return g_variant_new_string(mpris_showing ? names[mpris_state] : "Stopped");
    }
    if (!strcmp(property, "Rate")) return g_variant_new_double(mpris_showing ? mpris_rate : 1);
    if (!strcmp(property, "Volume") || !strcmp(property, "MinimumRate") || !strcmp(property, "MaximumRate")) return g_variant_new_double(1);
    if (!strcmp(property, "Position")) return g_variant_new_int64(mpris_now_position());
    if (!strcmp(property, "Metadata")) return mpris_metadata();
    if (!strcmp(property, "CanGoNext")) return g_variant_new_boolean(mpris_can(CMD_NEXT));
    if (!strcmp(property, "CanGoPrevious")) return g_variant_new_boolean(mpris_can(CMD_PREVIOUS));
    if (!strcmp(property, "CanPlay")) return g_variant_new_boolean(mpris_can(CMD_PLAY));
    if (!strcmp(property, "CanPause")) return g_variant_new_boolean(mpris_can(CMD_PAUSE));
    if (!strcmp(property, "CanSeek")) return g_variant_new_boolean(mpris_can(CMD_SEEK) && mpris_duration_us > 0);
    if (!strcmp(property, "CanControl")) return g_variant_new_boolean(TRUE);
    return NULL;
}

static GVariant *get_property(GDBusConnection *connection, const char *sender, const char *path, const char *interface, const char *property, GError **error, gpointer data) {
    (void)connection, (void)sender, (void)path, (void)interface, (void)data;
    GVariant *value = mpris_property(property);
    if (!value) g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY, "No property %s", property);
    return value;
}

static void method_call(GDBusConnection *connection, const char *sender, const char *path, const char *interface, const char *method, GVariant *params, GDBusMethodInvocation *invocation, gpointer data) {
    (void)connection, (void)sender, (void)path, (void)interface, (void)data;
    uint32_t command = 0;
    int64_t position = 0;
    if (!strcmp(method, "Play")) command = CMD_PLAY;
    else if (!strcmp(method, "Pause")) command = CMD_PAUSE;
    else if (!strcmp(method, "PlayPause")) command = CMD_TOGGLE;
    else if (!strcmp(method, "Stop")) command = CMD_STOP;
    else if (!strcmp(method, "Next")) command = CMD_NEXT;
    else if (!strcmp(method, "Previous")) command = CMD_PREVIOUS;
    else if (!strcmp(method, "Seek")) {
        gint64 offset = 0;
        g_variant_get(params, "(x)", &offset);
        position = mpris_now_position() + offset;
        if (position < 0) position = 0;
        command = CMD_SEEK;
    } else if (!strcmp(method, "SetPosition")) {
        const char *track = NULL;
        gint64 target = 0;
        g_variant_get(params, "(&ox)", &track, &target);
        char *current = mpris_track_id();
        // The specification ignores positions of other tracks, and out of the track.
        if (mpris_showing && !strcmp(track, current) && target >= 0 && (mpris_duration_us == 0 || target <= mpris_duration_us)) {
            command = CMD_SEEK;
            position = target;
        }
        g_free(current);
    } else if (!strcmp(method, "OpenUri")) {
        g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.NotSupported", "The player opens no URIs");
        return;
    }
    g_dbus_method_invocation_return_value(invocation, NULL);
    if (command && mpris_showing && mpris_deliver) mpris_deliver(command, position);
}

static const GDBusInterfaceVTable vtable = {method_call, get_property, NULL, {0}};

static void mpris_changed(const char *const *properties) {
    GVariantBuilder changed;
    g_variant_builder_init(&changed, G_VARIANT_TYPE("a{sv}"));
    for (; *properties; properties++) g_variant_builder_add(&changed, "{sv}", *properties, mpris_property(*properties));
    g_dbus_connection_emit_signal(mpris_conn, NULL, MPRIS_PATH, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                                  g_variant_new("(sa{sv}as)", MPRIS_PLAYER, &changed, NULL), NULL);
}

static int mpris_register(void) {
    if (mpris_registered) return 0;
    if (!mpris_conn) {
        mpris_conn = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
        if (!mpris_conn) return 1;
    }
    GDBusNodeInfo *node = g_dbus_node_info_new_for_xml(mpris_xml, NULL);
    if (!node) return 2;
    int status = 0;
    const char *interfaces[] = {MPRIS_ROOT, MPRIS_PLAYER};
    for (int i = 0; i < 2 && status == 0; i++) {
        if (g_dbus_connection_register_object(mpris_conn, MPRIS_PATH, g_dbus_node_info_lookup_interface(node, interfaces[i]), &vtable, NULL, NULL, NULL) == 0) status = 2;
    }
    g_dbus_node_info_unref(node);
    // Registered once per process; the bus name comes and goes.
    if (status == 0) mpris_registered = TRUE;
    return status;
}

// Shows info, or nothing for NULL. 0 on success, 1 without a session bus.
int znp_set(const struct znp_info *info, znp_deliver deliver) {
    mpris_deliver = deliver;
    if (!info) {
        mpris_showing = FALSE;
        if (mpris_owner) {
            g_bus_unown_name(mpris_owner);
            mpris_owner = 0;
        }
        mpris_set_art(NULL, 0);
        return 0;
    }
    int status = mpris_register();
    if (status) return status;
    int64_t expected = mpris_now_position();
    gboolean was = mpris_showing;
    if (!was || g_strcmp0(mpris_title, info->title) || g_strcmp0(mpris_artist, info->artist) || g_strcmp0(mpris_album, info->album) || mpris_duration_us != info->duration_us) mpris_track++;
    g_free(mpris_title), g_free(mpris_artist), g_free(mpris_album);
    mpris_title = g_strdup(info->title);
    mpris_artist = g_strdup(info->artist);
    mpris_album = g_strdup(info->album);
    mpris_duration_us = info->duration_us;
    mpris_position_us = info->position_us;
    mpris_rate = info->rate > 0 ? info->rate : 1;
    mpris_state = info->state >= 0 && info->state <= 2 ? info->state : 2;
    mpris_commands = info->commands;
    mpris_at = g_get_monotonic_time();
    mpris_showing = TRUE;
    mpris_set_art(info->artwork, info->artwork_len);
    if (!mpris_owner) {
        char *element = bus_name_element(g_get_prgname());
        char *name = g_strdup_printf("org.mpris.MediaPlayer2.%s.instance%d", element, (int)getpid());
        mpris_owner = g_bus_own_name_on_connection(mpris_conn, name, G_BUS_NAME_OWNER_FLAGS_NONE, NULL, NULL, NULL, NULL);
        g_free(name);
        g_free(element);
        return 0;
    }
    static const char *const properties[] = {"PlaybackStatus", "Rate", "Metadata", "CanGoNext", "CanGoPrevious", "CanPlay", "CanPause", "CanSeek", NULL};
    mpris_changed(properties);
    // Clients advance the position at the rate, and hear only of jumps.
    int64_t jump = info->position_us - expected;
    if (was && (jump > 500000 || jump < -500000)) {
        g_dbus_connection_emit_signal(mpris_conn, NULL, MPRIS_PATH, MPRIS_PLAYER, "Seeked", g_variant_new("(x)", (gint64)info->position_us), NULL);
    }
    return 0;
}
