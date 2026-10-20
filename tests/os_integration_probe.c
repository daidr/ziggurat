/* Independent GIO observers for the OS integration smoke: desktop handler
 * resolution as GLib applications see it, a private logind stand-in on the
 * bus named by DBUS_SYSTEM_BUS_ADDRESS, and a launcher entry subscriber. */
#define _POSIX_C_SOURCE 200809L
#include <gio/gio.h>
#include <gio/gunixfdlist.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int copy_out(const char *value, char *out, size_t capacity) {
    if (value == NULL) return 1;
    size_t length = strlen(value);
    if (length + 1 > capacity) return 2;
    memcpy(out, value, length + 1);
    return 0;
}

int probe_setenv(const char *name, const char *value) { return setenv(name, value, 1); }

int probe_default_for_scheme(const char *scheme, char *out, size_t capacity) {
    GAppInfo *info = g_app_info_get_default_for_uri_scheme(scheme);
    if (info == NULL) return 1;
    int status = copy_out(g_app_info_get_id(info), out, capacity);
    g_object_unref(info);
    return status;
}

int probe_default_for_type(const char *mime, char *out, size_t capacity) {
    GAppInfo *info = g_app_info_get_default_for_type(mime, FALSE);
    if (info == NULL) return 1;
    int status = copy_out(g_app_info_get_id(info), out, capacity);
    g_object_unref(info);
    return status;
}

int probe_guess(const char *filename, char *out, size_t capacity) {
    gboolean uncertain = FALSE;
    char *type = g_content_type_guess(filename, NULL, 0, &uncertain);
    char *mime = type == NULL ? NULL : g_content_type_get_mime_type(type);
    int status = copy_out(mime, out, capacity);
    g_free(mime);
    g_free(type);
    return status;
}

int probe_launch_uri(const char *uri) {
    GError *error = NULL;
    gboolean launched = g_app_info_launch_default_for_uri(uri, NULL, &error);
    if (!launched) g_printerr("launch %s: %s\n", uri, error == NULL ? "unknown" : error->message);
    g_clear_error(&error);
    return launched ? 0 : 1;
}

/* Observer thread with its own main context. */

typedef struct {
    GMutex lock;
    GCond changed;
    GThread *thread;
    GMainContext *context;
    gboolean ready;
    gboolean stop;
    int failure;
    int want_logind;
    char logind_args[4][256];
    int logind_calls;
    int held_fd;
    int updates;
    char uri[256];
    double progress;
    gboolean progress_visible;
    gint64 count;
    gboolean count_visible;
    gboolean urgent;
} Probe;

static Probe probe;

static void handle_method(GDBusConnection *connection, const gchar *sender, const gchar *path, const gchar *interface, const gchar *method,
                          GVariant *parameters, GDBusMethodInvocation *invocation, gpointer data) {
    (void)connection, (void)sender, (void)path, (void)interface, (void)data;
    if (g_strcmp0(method, "Inhibit") != 0) {
        g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.UnknownMethod", "unknown");
        return;
    }
    const char *values[4];
    g_variant_get(parameters, "(&s&s&s&s)", &values[0], &values[1], &values[2], &values[3]);
    int pipe_fds[2];
    if (pipe(pipe_fds) != 0) {
        g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.Failed", "pipe");
        return;
    }
    g_mutex_lock(&probe.lock);
    for (int i = 0; i < 4; i++) g_strlcpy(probe.logind_args[i], values[i], sizeof probe.logind_args[i]);
    if (probe.held_fd >= 0) close(probe.held_fd);
    probe.held_fd = pipe_fds[0];
    probe.logind_calls++;
    g_cond_broadcast(&probe.changed);
    g_mutex_unlock(&probe.lock);
    GUnixFDList *list = g_unix_fd_list_new_from_array(&pipe_fds[1], 1);
    g_dbus_method_invocation_return_value_with_unix_fd_list(invocation, g_variant_new("(h)", 0), list);
    g_object_unref(list);
}

static void handle_update(GDBusConnection *connection, const gchar *sender, const gchar *path, const gchar *interface, const gchar *signal,
                          GVariant *parameters, gpointer data) {
    (void)connection, (void)sender, (void)path, (void)interface, (void)signal, (void)data;
    const char *uri = NULL;
    GVariant *properties = NULL;
    g_variant_get(parameters, "(&s@a{sv})", &uri, &properties);
    g_mutex_lock(&probe.lock);
    g_strlcpy(probe.uri, uri, sizeof probe.uri);
    g_variant_lookup(properties, "progress", "d", &probe.progress);
    g_variant_lookup(properties, "progress-visible", "b", &probe.progress_visible);
    g_variant_lookup(properties, "count", "x", &probe.count);
    g_variant_lookup(properties, "count-visible", "b", &probe.count_visible);
    g_variant_lookup(properties, "urgent", "b", &probe.urgent);
    probe.updates++;
    g_cond_broadcast(&probe.changed);
    g_mutex_unlock(&probe.lock);
    g_variant_unref(properties);
}

static GDBusConnection *connect_address(const char *variable) {
    const char *address = g_getenv(variable);
    if (address == NULL) return NULL;
    return g_dbus_connection_new_for_address_sync(address, G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION,
                                                  NULL, NULL, NULL);
}

static gpointer run(gpointer data) {
    (void)data;
    g_main_context_push_thread_default(probe.context);
    GDBusConnection *session = connect_address("DBUS_SESSION_BUS_ADDRESS");
    GDBusConnection *system = probe.want_logind ? connect_address("DBUS_SYSTEM_BUS_ADDRESS") : NULL;
    int failure = session == NULL ? 1 : (probe.want_logind && system == NULL) ? 2 : 0;
    guint subscription = 0, registration = 0;
    if (failure == 0) {
        subscription = g_dbus_connection_signal_subscribe(session, NULL, "com.canonical.Unity.LauncherEntry", "Update", NULL, NULL, G_DBUS_SIGNAL_FLAGS_NONE,
                                                          handle_update, NULL, NULL);
    }
    if (failure == 0 && system != NULL) {
        static const char xml[] = "<node><interface name='org.freedesktop.login1.Manager'><method name='Inhibit'>"
                                  "<arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='s' direction='in'/>"
                                  "<arg type='s' direction='in'/><arg type='h' direction='out'/></method></interface></node>";
        static const GDBusInterfaceVTable vtable = {handle_method, NULL, NULL, {0}};
        GDBusNodeInfo *node = g_dbus_node_info_new_for_xml(xml, NULL);
        registration = g_dbus_connection_register_object(system, "/org/freedesktop/login1", node->interfaces[0], &vtable, NULL, NULL, NULL);
        g_dbus_node_info_unref(node);
        GVariant *reply = g_dbus_connection_call_sync(system, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                                                      g_variant_new("(su)", "org.freedesktop.login1", 4u), G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 2000,
                                                      NULL, NULL);
        guint32 owner = 0;
        if (reply != NULL) {
            g_variant_get(reply, "(u)", &owner);
            g_variant_unref(reply);
        }
        if (registration == 0 || owner != 1) failure = 3;
    }
    g_mutex_lock(&probe.lock);
    probe.failure = failure;
    probe.ready = TRUE;
    g_cond_broadcast(&probe.changed);
    g_mutex_unlock(&probe.lock);
    while (failure == 0) {
        g_mutex_lock(&probe.lock);
        gboolean stop = probe.stop;
        g_mutex_unlock(&probe.lock);
        if (stop) break;
        g_main_context_iteration(probe.context, TRUE);
    }
    if (subscription != 0) g_dbus_connection_signal_unsubscribe(session, subscription);
    if (registration != 0) g_dbus_connection_unregister_object(system, registration);
    if (system != NULL) {
        g_dbus_connection_close_sync(system, NULL, NULL);
        g_object_unref(system);
    }
    if (session != NULL) {
        g_dbus_connection_close_sync(session, NULL, NULL);
        g_object_unref(session);
    }
    while (g_main_context_iteration(probe.context, FALSE)) {
    }
    g_main_context_pop_thread_default(probe.context);
    return NULL;
}

/* 0 ready; 1 no session bus; 2 no system bus address; 3 name not acquired. */
int probe_start(int want_logind) {
    memset(&probe, 0, sizeof probe);
    g_mutex_init(&probe.lock);
    g_cond_init(&probe.changed);
    probe.held_fd = -1;
    probe.want_logind = want_logind;
    probe.context = g_main_context_new();
    probe.thread = g_thread_new("os-integration-probe", run, NULL);
    g_mutex_lock(&probe.lock);
    while (!probe.ready) g_cond_wait(&probe.changed, &probe.lock);
    int failure = probe.failure;
    g_mutex_unlock(&probe.lock);
    return failure;
}

void probe_stop(void) {
    g_mutex_lock(&probe.lock);
    probe.stop = TRUE;
    g_mutex_unlock(&probe.lock);
    g_main_context_wakeup(probe.context);
    g_thread_join(probe.thread);
    if (probe.held_fd >= 0) close(probe.held_fd);
    g_main_context_unref(probe.context);
    g_cond_clear(&probe.changed);
    g_mutex_clear(&probe.lock);
}

static int wait_for(int *counter, int target, int timeout_ms) {
    gint64 deadline = g_get_monotonic_time() + (gint64)timeout_ms * 1000;
    g_mutex_lock(&probe.lock);
    while (*counter < target) {
        if (!g_cond_wait_until(&probe.changed, &probe.lock, deadline)) break;
    }
    int reached = *counter >= target;
    g_mutex_unlock(&probe.lock);
    return reached ? 0 : 1;
}

int probe_logind_wait(int calls, int timeout_ms, char *what, char *who, char *why, char *mode) {
    if (wait_for(&probe.logind_calls, calls, timeout_ms) != 0) return 1;
    g_mutex_lock(&probe.lock);
    char *outputs[4] = {what, who, why, mode};
    for (int i = 0; i < 4; i++) g_strlcpy(outputs[i], probe.logind_args[i], 256);
    g_mutex_unlock(&probe.lock);
    return 0;
}

/* 0 when every copy of the inhibitor descriptor handed out has closed. */
int probe_logind_released(int timeout_ms) {
    g_mutex_lock(&probe.lock);
    int fd = probe.held_fd;
    g_mutex_unlock(&probe.lock);
    if (fd < 0) return 2;
    struct pollfd entry = {.fd = fd, .events = POLLIN};
    if (poll(&entry, 1, timeout_ms) != 1) return 1;
    char byte;
    return read(fd, &byte, 1) == 0 ? 0 : 1;
}

int probe_launcher_wait(int updates, int timeout_ms, char *uri, double *progress, int *progress_visible, long long *count, int *count_visible, int *urgent) {
    if (wait_for(&probe.updates, updates, timeout_ms) != 0) return 1;
    g_mutex_lock(&probe.lock);
    g_strlcpy(uri, probe.uri, 256);
    *progress = probe.progress;
    *progress_visible = probe.progress_visible;
    *count = probe.count;
    *count_visible = probe.count_visible;
    *urgent = probe.urgent;
    g_mutex_unlock(&probe.lock);
    return 0;
}
