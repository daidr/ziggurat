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
   1 context menu at (x, y), 2 secondary activate, -1 bus failure. */

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
    "<signal name='NewTitle'/><signal name='NewIcon'/><signal name='NewToolTip'/>"
    "<signal name='NewStatus'><arg type='s'/></signal>"
    "</interface></node>";
static GDBusNodeInfo *tray_info;
static guint tray_paths;

typedef struct Tray {
    int refs;
    void *owner;
    uint64_t serial;
    TrayEvent event;
    GCancellable *cancel;
    GDBusConnection *bus;
    guint object, watch;
    gchar path[64];
    gchar *id, *title, *icon_name;
    GVariant *pixmap;
} Tray;

static void tray_release(Tray *tray) {
    if (--tray->refs) return;
    g_clear_object(&tray->cancel);
    g_clear_object(&tray->bus);
    g_free(tray->id);
    g_free(tray->title);
    g_free(tray->icon_name);
    if (tray->pixmap) g_variant_unref(tray->pixmap);
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
    if (strcmp(name, "Menu") == 0) return g_variant_new_object_path("/NO_DBUSMENU");
    if (g_str_has_suffix(name, "Pixmap")) return empty_pixmaps();
    return g_variant_new_string("");
}
static void tray_object_freed(gpointer data) { tray_release(data); }
static const GDBusInterfaceVTable tray_vtable = {tray_method, tray_property, NULL, {0}};

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
Tray *zsl_tray_show(void *icon, const char *title, const char *id, void *owner, uint64_t serial, TrayEvent event, int *error) {
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
    tray->icon_name = g_strdup(pixmap ? "" : "application-x-executable");
    tray->pixmap = pixmap;
    g_snprintf(tray->path, sizeof tray->path, "/org/ziggurat/StatusNotifierItem/%u", ++tray_paths);
    g_atomic_int_inc(&live_records);
    ++tray->refs;
    g_bus_get(G_BUS_TYPE_SESSION, tray->cancel, tray_bus_ready, tray);
    return tray;
}
/* Replaces the icon and title in place and tells the host to reread them. */
int zsl_tray_update(Tray *tray, void *icon, const char *title) {
    GVariant *pixmap = NULL;
    if (icon && (!GDK_IS_PIXBUF(icon) || !(pixmap = pixmap_from(icon)))) return 0;
    if (tray->pixmap) g_variant_unref(tray->pixmap);
    tray->pixmap = pixmap;
    g_free(tray->icon_name);
    tray->icon_name = g_strdup(pixmap ? "" : "application-x-executable");
    g_free(tray->title);
    tray->title = g_strdup(title);
    tray_signal(tray, "NewIcon");
    tray_signal(tray, "NewTitle");
    tray_signal(tray, "NewToolTip");
    return 1;
}
const char *zsl_tray_path(Tray *tray) { return tray->path; }
/* Silent: unexports the item, which also removes it from the watcher. */
void zsl_tray_remove(Tray *tray) {
    tray->owner = NULL;
    g_cancellable_cancel(tray->cancel);
    if (tray->watch) { guint watch = tray->watch; tray->watch = 0; g_bus_unwatch_name(watch); }
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
