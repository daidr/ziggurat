#include <gtk/gtk.h>
#include <stdint.h>
#include <string.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#include <X11/XKBlib.h>
#endif

/* Desktop services that live outside a window's widget tree: status
   notifier tray items and notifications over the session bus, and X11 global
   key grabs. Bus connections and calls are asynchronous; GIO completes them
   on the main context. Every native record holds only an opaque owner token,
   which Zig clears before the owner can disappear, and a reference count
   that keeps it alive until its last pending callback returns. */

typedef void (*Done)(void *owner, uint64_t serial, int32_t result);
typedef void (*TrayEvent)(void *owner, uint64_t serial, int32_t kind, int32_t x, int32_t y);

static gint live_records;

/* ---- status notifier items ----
   Each item exports org.kde.StatusNotifierItem at its own object path and
   registers that path with org.kde.StatusNotifierWatcher whenever a watcher
   appears, so a restarted panel shows the item again. Events: 0 activate,
   1 context menu at (x, y), 2 secondary activate, 3 menu command at index
   x, -1 bus failure. */

static const char tray_xml[] =
    "<node><interface name='org.kde.StatusNotifierItem'>"
    "<method name='Activate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='SecondaryActivate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='ContextMenu'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='Scroll'><arg type='i' direction='in'/><arg type='s' direction='in'/></method>"
    "<property name='Category' type='s' access='read'/><property name='Id' type='s' access='read'/>"
    "<property name='Title' type='s' access='read'/><property name='Status' type='s' access='read'/>"
    "<property name='WindowId' type='i' access='read'/><property name='IconName' type='s' access='read'/>"
    "<property name='IconPixmap' type='a(iiay)' access='read'/><property name='OverlayIconName' type='s' access='read'/>"
    "<property name='OverlayIconPixmap' type='a(iiay)' access='read'/><property name='AttentionIconName' type='s' access='read'/>"
    "<property name='AttentionIconPixmap' type='a(iiay)' access='read'/><property name='AttentionMovieName' type='s' access='read'/>"
    "<property name='ToolTip' type='(sa(iiay)ss)' access='read'/><property name='ItemIsMenu' type='b' access='read'/>"
    "<property name='Menu' type='o' access='read'/>"
    "<property name='XAyatanaLabel' type='s' access='read'/><property name='XAyatanaLabelGuide' type='s' access='read'/>"
    "<signal name='NewTitle'/><signal name='NewIcon'/><signal name='NewToolTip'/>"
    "<signal name='NewStatus'><arg type='s'/></signal>"
    "<signal name='XAyatanaNewLabel'><arg type='s'/><arg type='s'/></signal>"
    "</interface></node>";
static GDBusNodeInfo *tray_info;
static guint tray_paths;

/* com.canonical.dbusmenu, the menu a status notifier host draws itself. The
   item's Menu property names it once a menu is set. Menu IDs are fresh for
   every snapshot, so a host still holding an old layout cannot select an
   item of a newer one. */
static const char menu_xml[] =
    "<node><interface name='com.canonical.dbusmenu'>"
    "<method name='GetLayout'><arg type='i' direction='in'/><arg type='i' direction='in'/><arg type='as' direction='in'/>"
    "<arg type='u' direction='out'/><arg type='(ia{sv}av)' direction='out'/></method>"
    "<method name='GetGroupProperties'><arg type='ai' direction='in'/><arg type='as' direction='in'/><arg type='a(ia{sv})' direction='out'/></method>"
    "<method name='GetProperty'><arg type='i' direction='in'/><arg type='s' direction='in'/><arg type='v' direction='out'/></method>"
    "<method name='Event'><arg type='i' direction='in'/><arg type='s' direction='in'/><arg type='v' direction='in'/><arg type='u' direction='in'/></method>"
    "<method name='EventGroup'><arg type='a(isvu)' direction='in'/><arg type='ai' direction='out'/></method>"
    "<method name='AboutToShow'><arg type='i' direction='in'/><arg type='b' direction='out'/></method>"
    "<method name='AboutToShowGroup'><arg type='ai' direction='in'/><arg type='ai' direction='out'/><arg type='ai' direction='out'/></method>"
    "<property name='Version' type='u' access='read'/><property name='TextDirection' type='s' access='read'/>"
    "<property name='Status' type='s' access='read'/><property name='IconThemePath' type='as' access='read'/>"
    "<signal name='ItemsPropertiesUpdated'><arg type='a(ia{sv})'/><arg type='a(ias)'/></signal>"
    "<signal name='LayoutUpdated'><arg type='u'/><arg type='i'/></signal>"
    "<signal name='ItemActivationRequested'><arg type='i'/><arg type='u'/></signal>"
    "</interface></node>";
static GDBusNodeInfo *menu_info;

/* The layout Zig passes for menu bars and popups. */
typedef struct NativeItem {
    const char *label;
    int32_t parent;
    uint8_t kind;
    uint8_t enabled;
    uint8_t checked;
    uint8_t padding;
    uint32_t keyval;
    uint32_t modifiers;
    int32_t command;
    void *icon;
} NativeItem;
typedef struct MenuEntry {
    gchar *label;
    int32_t parent, id;
    uint8_t kind, enabled, checked;
    uint32_t keyval, modifiers;
    /* The PNG of the item's icon, sent as DBusMenu's icon-data. */
    GBytes *icon;
} MenuEntry;
GBytes *zsx_menu_icon_png(void *icon);

typedef struct Tray {
    int refs;
    void *owner;
    uint64_t serial;
    TrayEvent event;
    GCancellable *cancel;
    GDBusConnection *bus;
    guint object, watch, menu_object;
    gchar path[64], menu_path[80];
    gchar *id, *title, *icon_name, *label;
    GVariant *pixmap;
    MenuEntry *entries;
    uint32_t count;
    gboolean has_menu;
    guint32 revision;
    int32_t next_id;
} Tray;

static void menu_clear(Tray *tray) {
    for (uint32_t index = 0; index < tray->count; ++index) {
        g_free(tray->entries[index].label);
        if (tray->entries[index].icon) g_bytes_unref(tray->entries[index].icon);
    }
    g_free(tray->entries);
    tray->entries = NULL;
    tray->count = 0;
}

static void tray_release(Tray *tray) {
    if (--tray->refs) return;
    g_clear_object(&tray->cancel);
    g_clear_object(&tray->bus);
    g_free(tray->id);
    g_free(tray->title);
    g_free(tray->icon_name);
    g_free(tray->label);
    if (tray->pixmap) g_variant_unref(tray->pixmap);
    menu_clear(tray);
    g_atomic_int_dec_and_test(&live_records);
    g_free(tray);
}
static void tray_emit(Tray *tray, int32_t kind, int32_t x, int32_t y) {
    if (!tray->owner) return;
    ++tray->refs;
    tray->event(tray->owner, tray->serial, kind, x, y);
    tray_release(tray);
}
static void tray_method(GDBusConnection *bus, const gchar *sender, const gchar *path, const gchar *interface, const gchar *method, GVariant *parameters, GDBusMethodInvocation *invocation, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface;
    Tray *tray = data;
    gint x = 0, y = 0;
    if (g_variant_is_of_type(parameters, G_VARIANT_TYPE("(ii)"))) g_variant_get(parameters, "(ii)", &x, &y);
    g_dbus_method_invocation_return_value(invocation, NULL);
    if (strcmp(method, "Activate") == 0) tray_emit(tray, 0, x, y);
    else if (strcmp(method, "ContextMenu") == 0) tray_emit(tray, 1, x, y);
    else if (strcmp(method, "SecondaryActivate") == 0) tray_emit(tray, 2, x, y);
}
static GVariant *empty_pixmaps(void) { return g_variant_new_array(G_VARIANT_TYPE("(iiay)"), NULL, 0); }
static GVariant *tray_property(GDBusConnection *bus, const gchar *sender, const gchar *path, const gchar *interface, const gchar *name, GError **error, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface; (void)error;
    Tray *tray = data;
    if (strcmp(name, "Category") == 0) return g_variant_new_string("ApplicationStatus");
    if (strcmp(name, "Id") == 0) return g_variant_new_string(tray->id);
    if (strcmp(name, "Title") == 0) return g_variant_new_string(tray->title);
    if (strcmp(name, "Status") == 0) return g_variant_new_string("Active");
    if (strcmp(name, "WindowId") == 0) return g_variant_new_int32(0);
    if (strcmp(name, "IconName") == 0) return g_variant_new_string(tray->icon_name);
    if (strcmp(name, "IconPixmap") == 0) return tray->pixmap ? g_variant_ref(tray->pixmap) : empty_pixmaps();
    if (strcmp(name, "ToolTip") == 0) return g_variant_new("(s@a(iiay)ss)", "", empty_pixmaps(), tray->title, "");
    if (strcmp(name, "ItemIsMenu") == 0) return g_variant_new_boolean(FALSE);
    if (strcmp(name, "Menu") == 0) return g_variant_new_object_path(tray->has_menu && tray->menu_object ? tray->menu_path : "/NO_DBUSMENU");
    if (strcmp(name, "XAyatanaLabel") == 0 || strcmp(name, "XAyatanaLabelGuide") == 0) return g_variant_new_string(tray->label);
    if (g_str_has_suffix(name, "Pixmap")) return empty_pixmaps();
    return g_variant_new_string("");
}
static void tray_object_freed(gpointer data) { tray_release(data); }
static const GDBusInterfaceVTable tray_vtable = {tray_method, tray_property, NULL, {0}};

/* ---- tray menus ---- */

static int menu_index(Tray *tray, int32_t id) {
    for (uint32_t index = 0; index < tray->count; ++index) if (tray->entries[index].id == id) return (int)index;
    return -1;
}
static GVariant *menu_shortcut(const MenuEntry *entry) {
    GVariantBuilder keys;
    g_variant_builder_init(&keys, G_VARIANT_TYPE("as"));
    /* GDK_CONTROL_MASK, GDK_MOD1_MASK, GDK_SHIFT_MASK and GDK_SUPER_MASK. */
    if (entry->modifiers & (1u << 2)) g_variant_builder_add(&keys, "s", "Control");
    if (entry->modifiers & (1u << 3)) g_variant_builder_add(&keys, "s", "Alt");
    if (entry->modifiers & (1u << 0)) g_variant_builder_add(&keys, "s", "Shift");
    if (entry->modifiers & (1u << 26)) g_variant_builder_add(&keys, "s", "Super");
    const gchar *name = gdk_keyval_name(entry->keyval);
    g_variant_builder_add(&keys, "s", name ? name : "");
    GVariant *one = g_variant_builder_end(&keys);
    return g_variant_new_array(G_VARIANT_TYPE("as"), &one, 1);
}
/* Properties of one entry, or of the root for index -1. */
static GVariant *menu_properties(Tray *tray, int index) {
    GVariantBuilder properties;
    g_variant_builder_init(&properties, G_VARIANT_TYPE("a{sv}"));
    if (index < 0) {
        g_variant_builder_add(&properties, "{sv}", "children-display", g_variant_new_string("submenu"));
        return g_variant_builder_end(&properties);
    }
    const MenuEntry *entry = &tray->entries[index];
    if (entry->kind == 2) {
        g_variant_builder_add(&properties, "{sv}", "type", g_variant_new_string("separator"));
        return g_variant_builder_end(&properties);
    }
    g_variant_builder_add(&properties, "{sv}", "label", g_variant_new_string(entry->label));
    g_variant_builder_add(&properties, "{sv}", "enabled", g_variant_new_boolean(entry->enabled != 0));
    g_variant_builder_add(&properties, "{sv}", "visible", g_variant_new_boolean(TRUE));
    if (entry->kind == 1) g_variant_builder_add(&properties, "{sv}", "children-display", g_variant_new_string("submenu"));
    if (entry->kind == 0 && entry->checked) {
        g_variant_builder_add(&properties, "{sv}", "toggle-type", g_variant_new_string("checkmark"));
        g_variant_builder_add(&properties, "{sv}", "toggle-state", g_variant_new_int32(1));
    }
    if (entry->kind == 0 && entry->keyval) g_variant_builder_add(&properties, "{sv}", "shortcut", menu_shortcut(entry));
    if (entry->icon) g_variant_builder_add(&properties, "{sv}", "icon-data", g_variant_new_from_bytes(G_VARIANT_TYPE_BYTESTRING, entry->icon, TRUE));
    return g_variant_builder_end(&properties);
}
static GVariant *menu_layout(Tray *tray, int index, int depth) {
    GVariantBuilder children;
    g_variant_builder_init(&children, G_VARIANT_TYPE("av"));
    if (depth != 0) {
        for (uint32_t child = 0; child < tray->count; ++child) {
            if (tray->entries[child].parent != index) continue;
            g_variant_builder_add(&children, "v", menu_layout(tray, (int)child, depth < 0 ? -1 : depth - 1));
        }
    }
    return g_variant_new("(i@a{sv}@av)", index < 0 ? 0 : tray->entries[index].id, menu_properties(tray, index), g_variant_builder_end(&children));
}
static int menu_lookup(Tray *tray, int32_t id, int *index) {
    if (id == 0) { *index = -1; return 1; }
    *index = menu_index(tray, id);
    return *index >= 0;
}
/* Reports a click on an enabled command as event 3 with its index. */
static void menu_event(Tray *tray, int32_t id, const gchar *event) {
    int index = menu_index(tray, id);
    if (index < 0 || strcmp(event, "clicked") != 0) return;
    if (tray->entries[index].kind != 0 || !tray->entries[index].enabled) return;
    tray_emit(tray, 3, index, 0);
}
static void menu_method(GDBusConnection *bus, const gchar *sender, const gchar *path, const gchar *interface, const gchar *method, GVariant *parameters, GDBusMethodInvocation *invocation, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface;
    Tray *tray = data;
    if (strcmp(method, "GetLayout") == 0) {
        gint32 parent = 0, depth = -1;
        g_variant_get(parameters, "(ii@as)", &parent, &depth, NULL);
        int index = 0;
        if (!menu_lookup(tray, parent, &index)) {
            g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR, G_DBUS_ERROR_INVALID_ARGS, "Unknown menu item %d", parent);
            return;
        }
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(u@(ia{sv}av))", tray->revision, menu_layout(tray, index, depth)));
    } else if (strcmp(method, "GetGroupProperties") == 0) {
        GVariantIter *ids = NULL;
        g_variant_get(parameters, "(ai@as)", &ids, NULL);
        GVariantBuilder result;
        g_variant_builder_init(&result, G_VARIANT_TYPE("a(ia{sv})"));
        gint32 id = 0;
        while (g_variant_iter_next(ids, "i", &id)) {
            int index = 0;
            if (menu_lookup(tray, id, &index)) g_variant_builder_add(&result, "(i@a{sv})", id, menu_properties(tray, index));
        }
        g_variant_iter_free(ids);
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(@a(ia{sv}))", g_variant_builder_end(&result)));
    } else if (strcmp(method, "GetProperty") == 0) {
        gint32 id = 0;
        const gchar *name = NULL;
        g_variant_get(parameters, "(i&s)", &id, &name);
        int index = 0;
        GVariant *value = NULL;
        if (menu_lookup(tray, id, &index)) {
            GVariant *properties = menu_properties(tray, index);
            g_variant_ref_sink(properties);
            value = g_variant_lookup_value(properties, name, NULL);
            g_variant_unref(properties);
        }
        if (!value) {
            g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR, G_DBUS_ERROR_INVALID_ARGS, "Unknown menu property");
            return;
        }
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(v)", value));
        g_variant_unref(value);
    } else if (strcmp(method, "Event") == 0) {
        gint32 id = 0;
        const gchar *event = NULL;
        g_variant_get(parameters, "(i&svu)", &id, &event, NULL, NULL);
        gchar *copy = g_strdup(event);
        ++tray->refs;
        g_dbus_method_invocation_return_value(invocation, NULL);
        menu_event(tray, id, copy);
        g_free(copy);
        tray_release(tray);
    } else if (strcmp(method, "EventGroup") == 0) {
        GVariantIter *events = NULL;
        g_variant_get(parameters, "(a(isvu))", &events);
        GVariantBuilder errors;
        g_variant_builder_init(&errors, G_VARIANT_TYPE("ai"));
        guint total = (guint)g_variant_iter_n_children(events);
        gint32 *ids = g_new0(gint32, total ? total : 1);
        gchar **names = g_new0(gchar *, total ? total : 1);
        guint count = 0;
        gint32 id = 0;
        const gchar *event = NULL;
        while (g_variant_iter_next(events, "(i&svu)", &id, &event, NULL, NULL)) {
            if (menu_index(tray, id) < 0) g_variant_builder_add(&errors, "i", id);
            else { ids[count] = id; names[count] = g_strdup(event); ++count; }
        }
        g_variant_iter_free(events);
        ++tray->refs;
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(@ai)", g_variant_builder_end(&errors)));
        /* Each event can replace the menu, so IDs are looked up again. */
        for (guint index = 0; index < count; ++index) { menu_event(tray, ids[index], names[index]); g_free(names[index]); }
        g_free(ids);
        g_free(names);
        tray_release(tray);
    } else if (strcmp(method, "AboutToShow") == 0) {
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(b)", FALSE));
    } else {
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(@ai@ai)", g_variant_new_array(G_VARIANT_TYPE_INT32, NULL, 0), g_variant_new_array(G_VARIANT_TYPE_INT32, NULL, 0)));
    }
}
static GVariant *menu_property(GDBusConnection *bus, const gchar *sender, const gchar *path, const gchar *interface, const gchar *name, GError **error, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface; (void)error; (void)data;
    if (strcmp(name, "Version") == 0) return g_variant_new_uint32(3);
    if (strcmp(name, "TextDirection") == 0) return g_variant_new_string(gtk_widget_get_default_direction() == GTK_TEXT_DIR_RTL ? "rtl" : "ltr");
    if (strcmp(name, "Status") == 0) return g_variant_new_string("normal");
    return g_variant_new_strv(NULL, 0);
}
static const GDBusInterfaceVTable menu_vtable = {menu_method, menu_property, NULL, {0}};

static void tray_registered(GObject *source, GAsyncResult *result, gpointer data) {
    Tray *tray = data;
    GError *error = NULL;
    GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
    if (reply) g_variant_unref(reply);
    /* A watcher that refuses the item leaves it exported for the next one. */
    if (error && !g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) tray_emit(tray, -1, 3, error->code);
    g_clear_error(&error);
    tray_release(tray);
}
static void watcher_appeared(GDBusConnection *bus, const gchar *name, const gchar *name_owner, gpointer data) {
    (void)name;
    Tray *tray = data;
    if (!tray->owner || !tray->object) return;
    ++tray->refs;
    g_dbus_connection_call(bus, name_owner, "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem",
        g_variant_new("(s)", tray->path), NULL, G_DBUS_CALL_FLAGS_NONE, -1, tray->cancel, tray_registered, tray);
}
static void tray_bus_ready(GObject *source, GAsyncResult *result, gpointer data) {
    (void)source;
    Tray *tray = data;
    GError *error = NULL;
    GDBusConnection *bus = g_bus_get_finish(result, &error);
    if (!bus || !tray->owner) {
        if (!bus && !g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) tray_emit(tray, -1, 1, error ? error->code : 0);
        g_clear_error(&error);
        g_clear_object(&bus);
        tray_release(tray);
        return;
    }
    tray->bus = bus;
    if (!tray_info) tray_info = g_dbus_node_info_new_for_xml(tray_xml, NULL);
    ++tray->refs;
    tray->object = g_dbus_connection_register_object(bus, tray->path, tray_info->interfaces[0], &tray_vtable, tray, tray_object_freed, &error);
    if (!tray->object) {
        --tray->refs;
        tray_emit(tray, -1, 2, error ? error->code : 0);
        g_clear_error(&error);
        tray_release(tray);
        return;
    }
    if (!menu_info) menu_info = g_dbus_node_info_new_for_xml(menu_xml, NULL);
    ++tray->refs;
    tray->menu_object = g_dbus_connection_register_object(bus, tray->menu_path, menu_info->interfaces[0], &menu_vtable, tray, tray_object_freed, &error);
    if (!tray->menu_object) {
        /* The item still works; hosts call ContextMenu instead. */
        --tray->refs;
        tray_emit(tray, -1, 4, error ? error->code : 0);
        g_clear_error(&error);
    }
    ++tray->refs;
    tray->watch = g_bus_watch_name_on_connection(bus, "org.kde.StatusNotifierWatcher", G_BUS_NAME_WATCHER_FLAGS_NONE, watcher_appeared, NULL, tray, tray_object_freed);
    tray_release(tray);
}
static void tray_signal(Tray *tray, const char *name) {
    if (tray->bus && tray->object) g_dbus_connection_emit_signal(tray->bus, NULL, tray->path, "org.kde.StatusNotifierItem", name, NULL, NULL);
}
/* Copies a borrowed pixbuf as big-endian ARGB, the item protocol's format. */
static GVariant *pixmap_from(GdkPixbuf *pixbuf) {
    if (!pixbuf || gdk_pixbuf_get_colorspace(pixbuf) != GDK_COLORSPACE_RGB || gdk_pixbuf_get_bits_per_sample(pixbuf) != 8) return NULL;
    int width = gdk_pixbuf_get_width(pixbuf), height = gdk_pixbuf_get_height(pixbuf), channels = gdk_pixbuf_get_n_channels(pixbuf), stride = gdk_pixbuf_get_rowstride(pixbuf);
    if (width <= 0 || height <= 0 || width > 1024 || height > 1024 || (channels != 3 && channels != 4)) return NULL;
    const guchar *pixels = gdk_pixbuf_read_pixels(pixbuf);
    guchar *argb = g_malloc((gsize)width * height * 4);
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
        const guchar *source = pixels + y * stride + x * channels;
        guchar *target = argb + ((gsize)y * width + x) * 4;
        target[0] = channels == 4 ? source[3] : 255;
        target[1] = source[0];
        target[2] = source[1];
        target[3] = source[2];
    }
    GVariant *bytes = g_variant_new_from_data(G_VARIANT_TYPE("ay"), argb, (gsize)width * height * 4, TRUE, g_free, argb);
    GVariant *entry = g_variant_new("(ii@ay)", width, height, bytes);
    return g_variant_ref_sink(g_variant_new_array(G_VARIANT_TYPE("(iiay)"), &entry, 1));
}

/* The pixbuf is borrowed; a NULL icon names the generic application icon.
   Returns NULL with error 1 when the icon cannot be copied. */
Tray *zsl_tray_show(void *icon, const char *title, const char *label, const char *id, void *owner, uint64_t serial, TrayEvent event, int *error) {
    *error = 0;
    GVariant *pixmap = NULL;
    if (icon) {
        if (!GDK_IS_PIXBUF(icon) || !(pixmap = pixmap_from(icon))) { *error = 1; return NULL; }
    }
    Tray *tray = g_new0(Tray, 1);
    tray->refs = 1;
    tray->owner = owner;
    tray->serial = serial;
    tray->event = event;
    tray->cancel = g_cancellable_new();
    tray->id = g_strdup(id && id[0] ? id : g_get_prgname() ? g_get_prgname() : "application");
    tray->title = g_strdup(title);
    tray->label = g_strdup(label);
    tray->icon_name = g_strdup(pixmap ? "" : "application-x-executable");
    tray->pixmap = pixmap;
    tray->next_id = 1;
    g_snprintf(tray->path, sizeof tray->path, "/org/ziggurat/StatusNotifierItem/%u", ++tray_paths);
    g_snprintf(tray->menu_path, sizeof tray->menu_path, "%s/Menu", tray->path);
    g_atomic_int_inc(&live_records);
    ++tray->refs;
    g_bus_get(G_BUS_TYPE_SESSION, tray->cancel, tray_bus_ready, tray);
    return tray;
}
/* Replaces the icon and title in place and tells the host to reread them. */
int zsl_tray_update(Tray *tray, void *icon, const char *title, const char *label) {
    GVariant *pixmap = NULL;
    if (icon && (!GDK_IS_PIXBUF(icon) || !(pixmap = pixmap_from(icon)))) return 0;
    if (tray->pixmap) g_variant_unref(tray->pixmap);
    tray->pixmap = pixmap;
    g_free(tray->icon_name);
    tray->icon_name = g_strdup(pixmap ? "" : "application-x-executable");
    g_free(tray->title);
    tray->title = g_strdup(title);
    gboolean relabel = strcmp(tray->label, label) != 0;
    g_free(tray->label);
    tray->label = g_strdup(label);
    tray_signal(tray, "NewIcon");
    tray_signal(tray, "NewTitle");
    tray_signal(tray, "NewToolTip");
    if (relabel && tray->bus && tray->object)
        g_dbus_connection_emit_signal(tray->bus, NULL, tray->path, "org.kde.StatusNotifierItem", "XAyatanaNewLabel", g_variant_new("(ss)", tray->label, tray->label), NULL);
    return 1;
}
/* Replaces the menu with a copy of `items`; zero items remove it. Item
   kinds are 0 command, 1 submenu, 2 separator; parents index earlier items
   or are -1, and `enabled` already includes every ancestor's state. */
void zsl_tray_menu(Tray *tray, const NativeItem *items, uint32_t count) {
    gboolean had_menu = tray->has_menu;
    menu_clear(tray);
    tray->has_menu = count != 0;
    if (count) tray->entries = g_new0(MenuEntry, count);
    for (uint32_t index = 0; index < count; ++index) {
        MenuEntry *entry = &tray->entries[index];
        entry->label = g_strdup(items[index].label);
        entry->parent = items[index].parent;
        entry->kind = items[index].kind;
        entry->enabled = items[index].enabled;
        entry->checked = items[index].checked;
        entry->keyval = items[index].keyval;
        entry->modifiers = items[index].modifiers;
        entry->icon = items[index].icon ? g_bytes_ref(zsx_menu_icon_png(items[index].icon)) : NULL;
        if (tray->next_id <= 0) tray->next_id = 1;
        entry->id = tray->next_id++;
    }
    tray->count = count;
    ++tray->revision;
    if (!tray->bus || !tray->menu_object) return;
    g_dbus_connection_emit_signal(tray->bus, NULL, tray->menu_path, "com.canonical.dbusmenu", "LayoutUpdated", g_variant_new("(ui)", tray->revision, 0), NULL);
    if (had_menu != tray->has_menu && tray->object) {
        GVariantBuilder changed;
        g_variant_builder_init(&changed, G_VARIANT_TYPE("a{sv}"));
        g_variant_builder_add(&changed, "{sv}", "Menu", g_variant_new_object_path(tray->has_menu ? tray->menu_path : "/NO_DBUSMENU"));
        g_dbus_connection_emit_signal(tray->bus, NULL, tray->path, "org.freedesktop.DBus.Properties", "PropertiesChanged",
            g_variant_new("(sa{sv}as)", "org.kde.StatusNotifierItem", &changed, NULL), NULL);
    }
}
const char *zsl_tray_menu_path(Tray *tray) { return tray->menu_path; }
/* For checks: the size of the icon-data a host gets for item index, 0
   for none. */
gsize zsl_test_tray_icon(Tray *tray, uint32_t index) {
    if (index >= tray->count) return 0;
    GVariant *properties = menu_properties(tray, (int)index);
    GVariant *data = g_variant_lookup_value(properties, "icon-data", G_VARIANT_TYPE_BYTESTRING);
    gsize size = data ? g_variant_get_size(data) : 0;
    if (data) g_variant_unref(data);
    g_variant_unref(g_variant_ref_sink(properties));
    return size;
}
const char *zsl_tray_path(Tray *tray) { return tray->path; }
/* Silent: unexports the item, which also removes it from the watcher. */
void zsl_tray_remove(Tray *tray) {
    tray->owner = NULL;
    g_cancellable_cancel(tray->cancel);
    if (tray->watch) { guint watch = tray->watch; tray->watch = 0; g_bus_unwatch_name(watch); }
    if (tray->menu_object) { guint object = tray->menu_object; tray->menu_object = 0; g_dbus_connection_unregister_object(tray->bus, object); }
    if (tray->object) { guint object = tray->object; tray->object = 0; g_dbus_connection_unregister_object(tray->bus, object); }
    tray_release(tray);
}

/* ---- notifications ----
   org.freedesktop.Notifications with a default action. Done reports 1 when
   the user activates it, 0 when the server closes it, and -1 when the bus or
   server refuses it. Signals are subscribed before Notify, and only the
   server identity returned by this record's own call can match. A Notify
   already sent is never cancelled: its reply names what to withdraw. */

typedef struct Note {
    int refs;
    void *owner;
    uint64_t serial;
    Done done;
    GCancellable *cancel;
    GDBusConnection *bus;
    guint32 server;
    guint invoked, closed;
    gboolean reported, server_closed;
    gchar *app, *summary, *body;
    guchar urgency;
    gboolean silent, transient;
} Note;

static void note_release(Note *note) {
    if (--note->refs) return;
    g_clear_object(&note->cancel);
    g_clear_object(&note->bus);
    g_free(note->app);
    g_free(note->summary);
    g_free(note->body);
    g_atomic_int_dec_and_test(&live_records);
    g_free(note);
}
static void note_unsubscribe(Note *note) {
    if (note->invoked) { g_dbus_connection_signal_unsubscribe(note->bus, note->invoked); note->invoked = 0; }
    if (note->closed) { g_dbus_connection_signal_unsubscribe(note->bus, note->closed); note->closed = 0; }
}
static void note_report(Note *note, int32_t result) {
    if (note->reported) return;
    note->reported = TRUE;
    void *owner = note->owner;
    note->owner = NULL;
    if (note->bus) note_unsubscribe(note);
    ++note->refs;
    if (owner) note->done(owner, note->serial, result);
    note_release(note);
}
static void note_signal(GDBusConnection *bus, const gchar *sender, const gchar *path, const gchar *interface, const gchar *name, GVariant *parameters, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface;
    Note *note = data;
    guint32 id = 0;
    if (strcmp(name, "ActionInvoked") == 0 && g_variant_is_of_type(parameters, G_VARIANT_TYPE("(us)"))) {
        const gchar *key = NULL;
        g_variant_get(parameters, "(u&s)", &id, &key);
        if (note->server && id == note->server && strcmp(key, "default") == 0) note_report(note, 1);
    } else if (strcmp(name, "NotificationClosed") == 0 && g_variant_is_of_type(parameters, G_VARIANT_TYPE("(uu)"))) {
        g_variant_get(parameters, "(uu)", &id, NULL);
        if (note->server && id == note->server) {
            note->server_closed = TRUE;
            note_report(note, 0);
        }
    }
}
static void note_subscription_freed(gpointer data) { note_release(data); }
static void note_close_server(Note *note) {
    if (!note->bus || !note->server || note->server_closed) return;
    note->server_closed = TRUE;
    g_dbus_connection_call(note->bus, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications",
        "CloseNotification", g_variant_new("(u)", note->server), NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL, NULL);
}
static void note_sent(GObject *source, GAsyncResult *result, gpointer data) {
    Note *note = data;
    GError *error = NULL;
    GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
    if (reply) {
        g_variant_get(reply, "(u)", &note->server);
        g_variant_unref(reply);
        if (!note->owner) note_close_server(note);
    } else note_report(note, -1);
    g_clear_error(&error);
    note_release(note);
}
static void note_bus_ready(GObject *source, GAsyncResult *result, gpointer data) {
    (void)source;
    Note *note = data;
    GDBusConnection *bus = g_bus_get_finish(result, NULL);
    if (!bus || !note->owner) {
        g_clear_object(&bus);
        note_report(note, -1);
        note_release(note);
        return;
    }
    note->bus = bus;
    ++note->refs;
    note->invoked = g_dbus_connection_signal_subscribe(bus, "org.freedesktop.Notifications", "org.freedesktop.Notifications", "ActionInvoked",
        "/org/freedesktop/Notifications", NULL, G_DBUS_SIGNAL_FLAGS_NONE, note_signal, note, note_subscription_freed);
    ++note->refs;
    note->closed = g_dbus_connection_signal_subscribe(bus, "org.freedesktop.Notifications", "org.freedesktop.Notifications", "NotificationClosed",
        "/org/freedesktop/Notifications", NULL, G_DBUS_SIGNAL_FLAGS_NONE, note_signal, note, note_subscription_freed);
    GVariantBuilder hints;
    g_variant_builder_init(&hints, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&hints, "{sv}", "urgency", g_variant_new_byte(note->urgency));
    if (note->silent) g_variant_builder_add(&hints, "{sv}", "suppress-sound", g_variant_new_boolean(TRUE));
    if (note->transient) g_variant_builder_add(&hints, "{sv}", "transient", g_variant_new_boolean(TRUE));
    const gchar *actions[] = {"default", "", NULL};
    g_dbus_connection_call(bus, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "Notify",
        g_variant_new("(susss^asa{sv}i)", note->app, (guint32)0, "", note->summary, note->body, actions, &hints, -1),
        G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, -1, NULL, note_sent, note);
}

/* kind: 0 info, 1 warning, 2 error. Text is copied before return. */
Note *zsl_note_show(const char *summary, const char *body, int kind, int silent, int transient, void *owner, uint64_t serial, Done done) {
    Note *note = g_new0(Note, 1);
    note->refs = 1;
    note->owner = owner;
    note->serial = serial;
    note->done = done;
    note->cancel = g_cancellable_new();
    note->app = g_strdup(g_get_application_name() ? g_get_application_name() : "");
    note->summary = g_strdup(summary);
    note->body = g_strdup(body);
    note->urgency = kind == 2 ? 2 : 1;
    note->silent = silent != 0;
    note->transient = transient != 0;
    g_atomic_int_inc(&live_records);
    ++note->refs;
    g_bus_get(G_BUS_TYPE_SESSION, note->cancel, note_bus_ready, note);
    return note;
}
/* Silent: withdraws the notification from the server if it is still shown. */
void zsl_note_close(Note *note) {
    note->owner = NULL;
    note->reported = TRUE;
    g_cancellable_cancel(note->cancel);
    if (note->bus) note_unsubscribe(note);
    note_close_server(note);
    note_release(note);
}
uint32_t zsl_note_server_id(Note *note) { return note->server; }

/* ---- global key grabs ----
   Passive grabs on the X11 root window for each lock-modifier combination.
   A conflicting grab is detected through a trapped X error. Presses report
   from idle; without repeat, a key reports again only after its release. */

typedef struct Hotkey {
    int refs;
    void *owner;
    uint64_t serial;
    Done done;
    unsigned keycode, modifiers;
    gboolean repeat, down, grabbed;
} Hotkey;
static GPtrArray *hotkeys;
static gboolean hotkey_filter_installed;

static void hotkey_release(Hotkey *hotkey) {
    if (--hotkey->refs) return;
    g_atomic_int_dec_and_test(&live_records);
    g_free(hotkey);
}
static gboolean hotkey_report(gpointer data) {
    Hotkey *hotkey = data;
    if (hotkey->owner) hotkey->done(hotkey->owner, hotkey->serial, 0);
    hotkey_release(hotkey);
    return G_SOURCE_REMOVE;
}
#ifdef GDK_WINDOWING_X11
static unsigned lock_masks(Display *display, unsigned *masks) {
    unsigned num_lock = XkbKeysymToModifiers(display, XK_Num_Lock);
    masks[0] = 0;
    masks[1] = LockMask;
    masks[2] = num_lock;
    masks[3] = LockMask | num_lock;
    return num_lock && num_lock != LockMask ? 4 : 2;
}
static GdkFilterReturn hotkey_filter(GdkXEvent *native, GdkEvent *event, gpointer data) {
    (void)event; (void)data;
    XEvent *x = native;
    if ((x->type != KeyPress && x->type != KeyRelease) || !hotkeys) return GDK_FILTER_CONTINUE;
    unsigned state = x->xkey.state & (ShiftMask | ControlMask | Mod1Mask | Mod4Mask);
    for (guint i = 0; i < hotkeys->len; ++i) {
        Hotkey *hotkey = g_ptr_array_index(hotkeys, i);
        if (hotkey->keycode != x->xkey.keycode) continue;
        if (x->type == KeyRelease) { hotkey->down = FALSE; continue; }
        if (hotkey->modifiers != state) continue;
        if (hotkey->down && !hotkey->repeat) return GDK_FILTER_REMOVE;
        hotkey->down = TRUE;
        ++hotkey->refs;
        g_idle_add_full(G_PRIORITY_DEFAULT, hotkey_report, hotkey, NULL);
        return GDK_FILTER_REMOVE;
    }
    return GDK_FILTER_CONTINUE;
}
static void hotkey_ungrab(Display *display, Window root, Hotkey *hotkey) {
    unsigned masks[4], count = lock_masks(display, masks);
    for (unsigned i = 0; i < count; ++i) XUngrabKey(display, (int)hotkey->keycode, hotkey->modifiers | masks[i], root);
}
#endif

/* modifiers: 1 shift, 2 control, 4 alt, 8 super. Returns NULL with error 1
   when the display is not X11, 2 when no key produces keysym, and 3 when
   another grab already holds the combination (x_error gets the X code). */
Hotkey *zsl_hotkey_register(uint32_t keysym, uint32_t modifiers, int repeat, void *owner, uint64_t serial, Done done, int *error, int *x_error) {
    *error = 0;
    *x_error = 0;
#ifdef GDK_WINDOWING_X11
    GdkDisplay *gdk_display = gdk_display_get_default();
    if (!gdk_display || !GDK_IS_X11_DISPLAY(gdk_display)) { *error = 1; return NULL; }
    Display *display = GDK_DISPLAY_XDISPLAY(gdk_display);
    GdkWindow *root_window = gdk_get_default_root_window();
    Window root = GDK_WINDOW_XID(root_window);
    KeyCode keycode = XKeysymToKeycode(display, keysym);
    if (!keycode) { *error = 2; return NULL; }
    unsigned mask = (modifiers & 1 ? ShiftMask : 0) | (modifiers & 2 ? ControlMask : 0) | (modifiers & 4 ? Mod1Mask : 0) | (modifiers & 8 ? Mod4Mask : 0);
    if (hotkeys) for (guint i = 0; i < hotkeys->len; ++i) {
        Hotkey *other = g_ptr_array_index(hotkeys, i);
        if (other->keycode == keycode && other->modifiers == mask) { *error = 3; return NULL; }
    }
    Hotkey *hotkey = g_new0(Hotkey, 1);
    hotkey->refs = 1;
    hotkey->owner = owner;
    hotkey->serial = serial;
    hotkey->done = done;
    hotkey->keycode = keycode;
    hotkey->modifiers = mask;
    hotkey->repeat = repeat != 0;
    g_atomic_int_inc(&live_records);
    unsigned masks[4], count = lock_masks(display, masks);
    gdk_x11_display_error_trap_push(gdk_display);
    for (unsigned i = 0; i < count; ++i) XGrabKey(display, keycode, mask | masks[i], root, False, GrabModeAsync, GrabModeAsync);
    *x_error = gdk_x11_display_error_trap_pop(gdk_display);
    if (*x_error) {
        gdk_x11_display_error_trap_push(gdk_display);
        hotkey_ungrab(display, root, hotkey);
        gdk_x11_display_error_trap_pop_ignored(gdk_display);
        hotkey->owner = NULL;
        hotkey_release(hotkey);
        *error = 3;
        return NULL;
    }
    hotkey->grabbed = TRUE;
    if (!hotkeys) hotkeys = g_ptr_array_new();
    g_ptr_array_add(hotkeys, hotkey);
    if (!hotkey_filter_installed) {
        Bool supported = False;
        XkbSetDetectableAutoRepeat(display, True, &supported);
        gdk_window_add_filter(root_window, hotkey_filter, NULL);
        hotkey_filter_installed = TRUE;
    }
    return hotkey;
#else
    (void)keysym; (void)modifiers; (void)repeat; (void)owner; (void)serial; (void)done;
    *error = 1;
    return NULL;
#endif
}
/* Silent: releases the grab; a press already queued is dropped. */
void zsl_hotkey_unregister(Hotkey *hotkey) {
    hotkey->owner = NULL;
#ifdef GDK_WINDOWING_X11
    if (hotkey->grabbed) {
        GdkDisplay *gdk_display = gdk_display_get_default();
        hotkey->grabbed = FALSE;
        if (gdk_display && GDK_IS_X11_DISPLAY(gdk_display)) {
            gdk_x11_display_error_trap_push(gdk_display);
            hotkey_ungrab(GDK_DISPLAY_XDISPLAY(gdk_display), GDK_WINDOW_XID(gdk_get_default_root_window()), hotkey);
            gdk_x11_display_error_trap_pop_ignored(gdk_display);
        }
    }
#endif
    if (hotkeys) g_ptr_array_remove(hotkeys, hotkey);
    hotkey_release(hotkey);
}

int zsl_desktop_live_records(void) { return g_atomic_int_get(&live_records); }
