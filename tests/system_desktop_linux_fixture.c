#include <gio/gio.h>
#include <stdint.h>
#include <string.h>

/* Stand-ins for a status notifier watcher and a notification server, served
   from the smoke's own main loop on a private session bus. Every call here is
   asynchronous: a synchronous call would wait on the loop that answers it. */

static const char watcher_xml[] =
    "<node><interface name='org.kde.StatusNotifierWatcher'>"
    "<method name='RegisterStatusNotifierItem'><arg type='s' direction='in'/></method>"
    "</interface>"
    "<interface name='org.freedesktop.Notifications'>"
    "<method name='Notify'><arg type='s' direction='in'/><arg type='u' direction='in'/><arg type='s' direction='in'/>"
    "<arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='as' direction='in'/>"
    "<arg type='a{sv}' direction='in'/><arg type='i' direction='in'/><arg type='u' direction='out'/></method>"
    "<method name='CloseNotification'><arg type='u' direction='in'/></method>"
    "</interface></node>";

static GDBusConnection *bus;
static GDBusNodeInfo *info;
static int names_owned;
static char item_sender[128], item_path[128];
static int registrations;
static guint32 next_id, last_id, closed_by_client;
static int notify_count, last_urgency = -1, last_silent, last_transient;
static char last_summary[256], last_body[1024];
static char property_text[512];
static int property_ready;

static void method(GDBusConnection *connection, const gchar *sender, const gchar *path, const gchar *interface, const gchar *name, GVariant *parameters, GDBusMethodInvocation *invocation, gpointer data) {
    (void)connection; (void)path; (void)data;
    if (strcmp(interface, "org.kde.StatusNotifierWatcher") == 0) {
        const gchar *service = NULL;
        g_variant_get(parameters, "(&s)", &service);
        g_strlcpy(item_sender, sender, sizeof item_sender);
        g_strlcpy(item_path, service, sizeof item_path);
        ++registrations;
        g_dbus_method_invocation_return_value(invocation, NULL);
    } else if (strcmp(name, "Notify") == 0) {
        const gchar *summary = NULL, *body = NULL;
        GVariant *hints = NULL;
        g_variant_get(parameters, "(&su&s&s&s^a&s@a{sv}i)", NULL, NULL, NULL, &summary, &body, NULL, &hints, NULL);
        g_strlcpy(last_summary, summary, sizeof last_summary);
        g_strlcpy(last_body, body, sizeof last_body);
        guchar urgency = 0;
        gboolean flag = FALSE;
        last_urgency = g_variant_lookup(hints, "urgency", "y", &urgency) ? urgency : -1;
        last_silent = g_variant_lookup(hints, "suppress-sound", "b", &flag) && flag;
        flag = FALSE;
        last_transient = g_variant_lookup(hints, "transient", "b", &flag) && flag;
        g_variant_unref(hints);
        ++notify_count;
        last_id = ++next_id;
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(u)", last_id));
    } else {
        guint32 id = 0;
        g_variant_get(parameters, "(u)", &id);
        closed_by_client = id;
        g_dbus_method_invocation_return_value(invocation, NULL);
    }
}
static const GDBusInterfaceVTable vtable = {method, NULL, NULL, {0}};
static void acquired(GDBusConnection *connection, const gchar *name, gpointer data) { (void)connection; (void)name; (void)data; ++names_owned; }

int zsf_start(void) {
    bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    if (!bus) return 0;
    info = g_dbus_node_info_new_for_xml(watcher_xml, NULL);
    g_dbus_connection_register_object(bus, "/StatusNotifierWatcher", info->interfaces[0], &vtable, NULL, NULL, NULL);
    g_dbus_connection_register_object(bus, "/org/freedesktop/Notifications", info->interfaces[1], &vtable, NULL, NULL, NULL);
    g_bus_own_name_on_connection(bus, "org.kde.StatusNotifierWatcher", G_BUS_NAME_OWNER_FLAGS_NONE, acquired, NULL, NULL, NULL);
    g_bus_own_name_on_connection(bus, "org.freedesktop.Notifications", G_BUS_NAME_OWNER_FLAGS_NONE, acquired, NULL, NULL, NULL);
    return 1;
}
int zsf_ready(void) { return names_owned == 2; }
int zsf_registrations(void) { return registrations; }
const char *zsf_item_path(void) { return item_path; }

/* Calls the registered item as a panel would on a click. */
void zsf_item_call(const char *name, int x, int y) {
    g_dbus_connection_call(bus, item_sender, item_path, "org.kde.StatusNotifierItem", name, g_variant_new("(ii)", x, y), NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL, NULL);
}
static void property_done(GObject *source, GAsyncResult *result, gpointer data) {
    (void)data;
    GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, NULL);
    property_text[0] = 0;
    if (reply) {
        GVariant *value = NULL;
        g_variant_get(reply, "(v)", &value);
        if (g_variant_is_of_type(value, G_VARIANT_TYPE_STRING) || g_variant_is_of_type(value, G_VARIANT_TYPE_OBJECT_PATH)) g_strlcpy(property_text, g_variant_get_string(value, NULL), sizeof property_text);
        else if (g_variant_is_of_type(value, G_VARIANT_TYPE("(sa(iiay)ss)"))) {
            const gchar *title = NULL;
            g_variant_get(value, "(&s@a(iiay)&s&s)", NULL, NULL, &title, NULL);
            g_strlcpy(property_text, title, sizeof property_text);
        } else if (g_variant_is_of_type(value, G_VARIANT_TYPE("a(iiay)"))) {
            g_snprintf(property_text, sizeof property_text, "%zu", g_variant_n_children(value));
            if (g_variant_n_children(value)) {
                gint width = 0, height = 0;
                GVariant *bytes = NULL;
                g_variant_get_child(value, 0, "(ii@ay)", &width, &height, &bytes);
                gsize length = 0;
                const guchar *argb = g_variant_get_fixed_array(bytes, &length, 1);
                g_snprintf(property_text, sizeof property_text, "%dx%d:%02x%02x%02x%02x", width, height, length > 3 ? argb[0] : 0, length > 3 ? argb[1] : 0, length > 3 ? argb[2] : 0, length > 3 ? argb[3] : 0);
                g_variant_unref(bytes);
            }
        }
        g_variant_unref(value);
        g_variant_unref(reply);
    }
    property_ready = 1;
}
void zsf_item_property(const char *name) {
    property_ready = 0;
    g_dbus_connection_call(bus, item_sender, item_path, "org.freedesktop.DBus.Properties", "Get", g_variant_new("(ss)", "org.kde.StatusNotifierItem", name),
        G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, -1, NULL, property_done, NULL);
}
int zsf_property_ready(void) { return property_ready; }
const char *zsf_property_text(void) { return property_text; }

int zsf_notify_count(void) { return notify_count; }
uint32_t zsf_last_id(void) { return last_id; }
uint32_t zsf_closed_by_client(void) { return closed_by_client; }
const char *zsf_last_summary(void) { return last_summary; }
const char *zsf_last_body(void) { return last_body; }
int zsf_last_urgency(void) { return last_urgency; }
int zsf_last_silent(void) { return last_silent; }
int zsf_last_transient(void) { return last_transient; }
void zsf_invoke(uint32_t id) {
    g_dbus_connection_emit_signal(bus, NULL, "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "ActionInvoked", g_variant_new("(us)", id, "default"), NULL);
}
void zsf_server_close(uint32_t id) {
    g_dbus_connection_emit_signal(bus, NULL, "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "NotificationClosed", g_variant_new("(uu)", id, 1), NULL);
}

/* ---- the item's dbusmenu, read as a panel would ----
   The layout is flattened to text: items separated by ';', '-' for a
   separator, '!' before a disabled label, '*' after a checked one,
   '[keys]' for a shortcut and '(children)' for a submenu. */

static char layout_text[1024];
static int layout_ready;
static guint32 layout_revision;
static gint32 layout_ids[32];
static int layout_count;

static void append(const char *text) { g_strlcat(layout_text, text, sizeof layout_text); }
static void describe(GVariant *node) {
    gint32 id = 0;
    GVariant *properties = NULL, *children = NULL;
    g_variant_get(node, "(i@a{sv}@av)", &id, &properties, &children);
    if (layout_count < 32) layout_ids[layout_count++] = id;
    const gchar *type = NULL, *label = "", *display = NULL, *toggle = NULL;
    gboolean enabled = TRUE;
    gint32 state = 0;
    g_variant_lookup(properties, "type", "&s", &type);
    g_variant_lookup(properties, "label", "&s", &label);
    g_variant_lookup(properties, "enabled", "b", &enabled);
    g_variant_lookup(properties, "children-display", "&s", &display);
    g_variant_lookup(properties, "toggle-type", "&s", &toggle);
    g_variant_lookup(properties, "toggle-state", "i", &state);
    if (type && strcmp(type, "separator") == 0) append("-");
    else {
        if (!enabled) append("!");
        append(label);
        if (toggle && strcmp(toggle, "checkmark") == 0 && state == 1) append("*");
        GVariant *shortcut = g_variant_lookup_value(properties, "shortcut", G_VARIANT_TYPE("aas"));
        if (shortcut) {
            append("[");
            GVariant *keys = g_variant_get_child_value(shortcut, 0);
            for (gsize index = 0; index < g_variant_n_children(keys); ++index) {
                const gchar *key = NULL;
                g_variant_get_child(keys, index, "&s", &key);
                if (index) append("+");
                append(key);
            }
            append("]");
            g_variant_unref(keys);
            g_variant_unref(shortcut);
        }
    }
    if (display && strcmp(display, "submenu") == 0) {
        append("(");
        for (gsize index = 0; index < g_variant_n_children(children); ++index) {
            GVariant *boxed = g_variant_get_child_value(children, index), *child = g_variant_get_variant(boxed);
            if (index) append(";");
            describe(child);
            g_variant_unref(child);
            g_variant_unref(boxed);
        }
        append(")");
    }
    g_variant_unref(properties);
    g_variant_unref(children);
}
static void layout_done(GObject *source, GAsyncResult *result, gpointer data) {
    (void)data;
    GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, NULL);
    layout_text[0] = 0;
    layout_count = 0;
    if (reply) {
        GVariant *root = NULL;
        g_variant_get(reply, "(u@(ia{sv}av))", &layout_revision, &root);
        describe(root);
        g_variant_unref(root);
        g_variant_unref(reply);
    } else g_strlcpy(layout_text, "error", sizeof layout_text);
    layout_ready = 1;
}
void zsf_menu_layout(const char *path) {
    layout_ready = 0;
    g_dbus_connection_call(bus, item_sender, path, "com.canonical.dbusmenu", "GetLayout", g_variant_new("(ii@as)", 0, -1, g_variant_new_strv(NULL, 0)),
        G_VARIANT_TYPE("(u(ia{sv}av))"), G_DBUS_CALL_FLAGS_NONE, -1, NULL, layout_done, NULL);
}
int zsf_layout_ready(void) { return layout_ready; }
const char *zsf_layout_text(void) { return layout_text; }
uint32_t zsf_layout_revision(void) { return layout_revision; }
/* IDs in the order describe() met them; 0 is the root. */
int32_t zsf_layout_id(int index) { return index < layout_count ? layout_ids[index] : -1; }
void zsf_menu_click(const char *path, int32_t id) {
    g_dbus_connection_call(bus, item_sender, path, "com.canonical.dbusmenu", "Event", g_variant_new("(isvu)", id, "clicked", g_variant_new_int32(0), 0u),
        NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL, NULL);
}
