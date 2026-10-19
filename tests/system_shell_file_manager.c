/* Test-only org.freedesktop.FileManager1 provider for smoke-shell. It owns the
   name on the current session bus only when nobody else does (never replaces
   a real file manager), serves ShowItems on its own test thread and records
   the received URIs instead of showing anything. */
#include <gio/gio.h>
#include <string.h>

static const char introspection[] =
    "<node><interface name='org.freedesktop.FileManager1'>"
    "<method name='ShowItems'><arg type='as' name='uris' direction='in'/><arg type='s' name='startup_id' direction='in'/></method>"
    "</interface></node>";

static GMutex lock;
static GCond changed;
static int state; /* 0 starting, 1 owned, 2 not owned */
static GMainContext *context;
static GMainLoop *loop;
static GThread *thread;
static GDBusConnection *connection;
static char last_uri[4096];
static unsigned calls, last_count;
static gint delay_ms;

static void set_state(int value) {
    g_mutex_lock(&lock);
    state = value;
    g_cond_broadcast(&changed);
    g_mutex_unlock(&lock);
}
static void acquired(GDBusConnection *bus, const char *name, gpointer data) {
    (void)bus, (void)name, (void)data;
    set_state(1);
}
static void lost(GDBusConnection *bus, const char *name, gpointer data) {
    (void)bus, (void)name, (void)data;
    set_state(2);
}
static void call(GDBusConnection *bus, const char *sender, const char *path, const char *interface, const char *method, GVariant *parameters,
                 GDBusMethodInvocation *invocation, gpointer data) {
    (void)bus, (void)sender, (void)path, (void)interface, (void)data;
    if (strcmp(method, "ShowItems") != 0) {
        g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.UnknownMethod", "unknown");
        return;
    }
    const char **uris = NULL, *startup = NULL;
    g_variant_get(parameters, "(^a&s&s)", &uris, &startup);
    g_mutex_lock(&lock);
    calls++;
    last_count = uris ? g_strv_length((char **)uris) : 0;
    g_strlcpy(last_uri, last_count ? uris[0] : "", sizeof last_uri);
    g_mutex_unlock(&lock);
    g_free(uris);
    int delay = g_atomic_int_get(&delay_ms);
    if (delay > 0) g_usleep((gulong)delay * 1000);
    g_dbus_method_invocation_return_value(invocation, NULL);
}
static const GDBusInterfaceVTable vtable = {call, NULL, NULL, {0}};

static gpointer serve(gpointer data) {
    (void)data;
    g_main_context_push_thread_default(context);
    GDBusNodeInfo *node = g_dbus_node_info_new_for_xml(introspection, NULL);
    guint object = g_dbus_connection_register_object(connection, "/org/freedesktop/FileManager1", node->interfaces[0], &vtable, NULL, NULL, NULL);
    guint name = g_bus_own_name_on_connection(connection, "org.freedesktop.FileManager1", G_BUS_NAME_OWNER_FLAGS_DO_NOT_QUEUE, acquired, lost, NULL, NULL);
    if (!object) set_state(2);
    g_main_loop_run(loop);
    g_bus_unown_name(name);
    if (object) g_dbus_connection_unregister_object(connection, object);
    g_dbus_node_info_unref(node);
    while (g_main_context_iteration(context, FALSE)) {}
    g_main_context_pop_thread_default(context);
    return NULL;
}

static GDBusConnection *open_bus(void) {
    const char *address = g_getenv("DBUS_SESSION_BUS_ADDRESS");
    if (!address || !*address) return NULL;
    return g_dbus_connection_new_for_address_sync(address, G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION, NULL, NULL, NULL);
}

/* 1 when FileManager1 is owned or activatable, 0 when absent, -1 when no
   session bus could be reached from DBUS_SESSION_BUS_ADDRESS. */
int zsf_provider_present(void) {
    GDBusConnection *bus = open_bus();
    if (!bus) return -1;
    int present = -1;
    GVariant *owned = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
                                                  g_variant_new("(s)", "org.freedesktop.FileManager1"), G_VARIANT_TYPE("(b)"), G_DBUS_CALL_FLAGS_NONE, 5000, NULL, NULL);
    GVariant *activatable = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListActivatableNames", NULL,
                                                        G_VARIANT_TYPE("(as)"), G_DBUS_CALL_FLAGS_NONE, 5000, NULL, NULL);
    if (owned && activatable) {
        gboolean has_owner = FALSE;
        g_variant_get(owned, "(b)", &has_owner);
        present = has_owner ? 1 : 0;
        GVariantIter *names = NULL;
        const char *name = NULL;
        g_variant_get(activatable, "(as)", &names);
        while (g_variant_iter_next(names, "&s", &name))
            if (strcmp(name, "org.freedesktop.FileManager1") == 0) present = 1;
        g_variant_iter_free(names);
    }
    if (owned) g_variant_unref(owned);
    if (activatable) g_variant_unref(activatable);
    g_dbus_connection_close_sync(bus, NULL, NULL);
    g_object_unref(bus);
    return present;
}

/* 0 when this test owns the name and serves it; 1 no session bus; 2 the name
   could not be owned (for example a real file manager has it). */
int zsf_start(void) {
    connection = open_bus();
    if (!connection) return 1;
    g_dbus_connection_set_exit_on_close(connection, FALSE);
    state = 0;
    context = g_main_context_new();
    loop = g_main_loop_new(context, FALSE);
    thread = g_thread_new("shell-file-manager-fake", serve, NULL);
    g_mutex_lock(&lock);
    while (state == 0) g_cond_wait(&changed, &lock);
    int owned = state == 1;
    g_mutex_unlock(&lock);
    return owned ? 0 : 2;
}

void zsf_stop(void) {
    if (!thread) return;
    g_main_loop_quit(loop);
    g_thread_join(thread);
    thread = NULL;
    g_main_loop_unref(loop);
    g_main_context_unref(context);
    g_dbus_connection_close_sync(connection, NULL, NULL);
    g_object_unref(connection);
    connection = NULL;
}

void zsf_set_delay(int milliseconds) { g_atomic_int_set(&delay_ms, milliseconds); }

unsigned zsf_calls(char *uri, unsigned capacity, unsigned *count) {
    g_mutex_lock(&lock);
    unsigned result = calls;
    g_strlcpy(uri, last_uri, capacity);
    *count = last_count;
    g_mutex_unlock(&lock);
    return result;
}
