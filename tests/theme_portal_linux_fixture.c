#include <gio/gio.h>
#include <gtk/gtk.h>
#include <string.h>

/* A stand-in for the settings portal on a private session bus, served from
   the smoke's own main loop: Read answers the color-scheme it holds, and
   zpf_change sends SettingChanged as a desktop switching its style. */

static const char portal_xml[] =
    "<node><interface name='org.freedesktop.portal.Settings'>"
    "<method name='Read'><arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='v' direction='out'/></method>"
    "<signal name='SettingChanged'><arg type='s'/><arg type='s'/><arg type='v'/></signal>"
    "</interface></node>";

static GDBusConnection *bus;
static GDBusNodeInfo *info;
static guint32 scheme;
static int owned, reads;

static void method(GDBusConnection *connection, const gchar *sender, const gchar *path, const gchar *interface, const gchar *name, GVariant *parameters, GDBusMethodInvocation *invocation, gpointer data) {
    (void)connection; (void)sender; (void)path; (void)interface; (void)name; (void)data;
    const gchar *space = NULL, *key = NULL;
    g_variant_get(parameters, "(&s&s)", &space, &key);
    if (strcmp(space, "org.freedesktop.appearance") || strcmp(key, "color-scheme")) {
        g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.portal.Error.NotFound", "no such setting");
        return;
    }
    ++reads;
    /* Older portals wrap the value in a second variant. */
    g_dbus_method_invocation_return_value(invocation, g_variant_new("(v)", g_variant_new_variant(g_variant_new_uint32(scheme))));
}
static const GDBusInterfaceVTable vtable = {method, NULL, NULL, {0}};
static void acquired(GDBusConnection *connection, const gchar *name, gpointer data) { (void)connection; (void)name; (void)data; owned = 1; }

int zpf_start(guint32 initial) {
    scheme = initial;
    bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    if (!bus) return 0;
    info = g_dbus_node_info_new_for_xml(portal_xml, NULL);
    g_dbus_connection_register_object(bus, "/org/freedesktop/portal/desktop", info->interfaces[0], &vtable, NULL, NULL, NULL);
    g_bus_own_name_on_connection(bus, "org.freedesktop.portal.Desktop", G_BUS_NAME_OWNER_FLAGS_NONE, acquired, NULL, NULL, NULL);
    return 1;
}
int zpf_owned(void) { return owned; }
int zpf_reads(void) { return reads; }
void zpf_change(guint32 value) {
    scheme = value;
    g_dbus_connection_emit_signal(bus, NULL, "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", "SettingChanged",
        g_variant_new("(ssv)", "org.freedesktop.appearance", "color-scheme", g_variant_new_uint32(value)), NULL);
    g_dbus_connection_flush_sync(bus, NULL, NULL);
}
/* Runs the main loop for about `ms` milliseconds. */
void zpf_pump(int ms) {
    gint64 until = g_get_monotonic_time() + (gint64)ms * 1000;
    while (g_get_monotonic_time() < until) {
        while (g_main_context_iteration(NULL, FALSE)) {}
        g_usleep(2000);
    }
}
int zpf_prefers_dark(void) {
    gboolean dark = FALSE;
    g_object_get(gtk_settings_get_default(), "gtk-application-prefer-dark-theme", &dark, NULL);
    return dark ? 1 : 0;
}
/* The color GTK gives a label's text, 0xRRGGBB, under the screen's sheets. */
unsigned zpf_label_color(void) {
    GtkWidget *label = gtk_label_new("x");
    g_object_ref_sink(label);
    GtkStyleContext *style = gtk_widget_get_style_context(label);
    GdkRGBA color;
    gtk_style_context_get_color(style, GTK_STATE_FLAG_NORMAL, &color);
    g_object_unref(label);
    return ((unsigned)(color.red * 255 + 0.5) << 16) | ((unsigned)(color.green * 255 + 0.5) << 8) | (unsigned)(color.blue * 255 + 0.5);
}
