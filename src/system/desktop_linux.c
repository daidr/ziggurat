/* Linux desktop snapshots and refcounted change subscriptions. Every entry
   runs on the GTK main thread that owns the App. A stopped watch disconnects
   all handlers synchronously and clears its owner, so no later notification
   reaches the Zig Watch; a dispatching idle keeps its own reference. */
#define _GNU_SOURCE
#include <gtk/gtk.h>
#include <gdk/gdkx.h>
#include <gio/gio.h>
#include <dirent.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { ZSD_MONITORS = 1, ZSD_PREFERENCES = 2, ZSD_POWER = 4, ZSD_NETWORK = 8 };
enum { ZSD_OK = 0, ZSD_UNSUPPORTED = 1, ZSD_FAILED = 2, ZSD_CAPACITY = 3, ZSD_NO_MEMORY = 4 };

typedef struct ZsdRect { int32_t x, y; uint32_t width, height; } ZsdRect;
typedef struct ZsdMonitor { ZsdRect bounds, work; float scale; uint32_t primary, refresh_millihz; } ZsdMonitor;
typedef struct ZsdPreferences { int32_t scheme; uint32_t high_contrast, reduce_motion; float text_scale; } ZsdPreferences;
typedef struct ZsdPower { int32_t source, percent, saver; } ZsdPower;
typedef struct ZsdNetwork { int32_t state, metered; } ZsdNetwork;
typedef void (*ZsdChanged)(void *owner, uint32_t bits);

static gint live_states;
uint32_t zsd_resource_count(void) { return (uint32_t)g_atomic_int_get(&live_states); }

/* The system alert sound, or the X bell. */
int zsd_beep(void) {
    GdkDisplay *display = gdk_display_get_default();
    if (!display) return ZSD_UNSUPPORTED;
    gdk_display_beep(display);
    return 0;
}

/* The pointer in the same root coordinates as zsd_monitors. Wayland keeps
   the global pointer position private. */
int zsd_cursor(int32_t *x, int32_t *y) {
    GdkDisplay *display = gdk_display_get_default();
    if (!display || !GDK_IS_X11_DISPLAY(display)) return ZSD_UNSUPPORTED;
    GdkSeat *seat = gdk_display_get_default_seat(display);
    GdkDevice *pointer = seat ? gdk_seat_get_pointer(seat) : NULL;
    if (!pointer) return ZSD_FAILED;
    gint px = 0, py = 0;
    gdk_device_get_position(pointer, NULL, &px, &py);
    *x = px; *y = py;
    return 0;
}

int zsd_monitors(ZsdMonitor *output, uint32_t capacity, uint32_t *count) {
    GdkDisplay *display = gdk_display_get_default();
    if (!display || !GDK_IS_X11_DISPLAY(display)) return ZSD_UNSUPPORTED;
    int n = gdk_display_get_n_monitors(display);
    if (n <= 0) return ZSD_FAILED;
    if ((uint32_t)n > capacity) return ZSD_CAPACITY;
    for (int i = 0; i < n; i++) {
        GdkMonitor *monitor = gdk_display_get_monitor(display, i);
        if (!monitor) return ZSD_FAILED;
        GdkRectangle bounds, work;
        gdk_monitor_get_geometry(monitor, &bounds);
        gdk_monitor_get_workarea(monitor, &work);
        if (bounds.width <= 0 || bounds.height <= 0 || work.width <= 0 || work.height <= 0) return ZSD_FAILED;
        int refresh = gdk_monitor_get_refresh_rate(monitor);
        ZsdMonitor *out = &output[i];
        memset(out, 0, sizeof(*out));
        out->bounds = (ZsdRect){bounds.x, bounds.y, (uint32_t)bounds.width, (uint32_t)bounds.height};
        out->work = (ZsdRect){work.x, work.y, (uint32_t)work.width, (uint32_t)work.height};
        out->scale = (float)gdk_monitor_get_scale_factor(monitor);
        out->primary = gdk_monitor_is_primary(monitor) ? 1u : 0u;
        out->refresh_millihz = refresh > 0 ? (uint32_t)refresh : 0u;
    }
    *count = (uint32_t)n;
    return ZSD_OK;
}

static gboolean contains(const char *text, const char *needle) {
    if (!text) return FALSE;
    gchar *lower = g_ascii_strdown(text, -1);
    gboolean found = strstr(lower, needle) != NULL;
    g_free(lower);
    return found;
}

/* Heuristics: prefer-dark or a theme name containing "dark" (or an inverse
   high-contrast theme) is dark; another named theme is light. High contrast
   is a theme name containing "contrast". The portal color-scheme is not read:
   that would be a blocking D-Bus call on the UI thread. */
int zsd_preferences(ZsdPreferences *out) {
    GtkSettings *settings = gtk_settings_get_default();
    if (!settings) return ZSD_UNSUPPORTED;
    gboolean dark = FALSE, animations = TRUE;
    gchar *theme = NULL;
    gint dpi = -1;
    g_object_get(settings, "gtk-application-prefer-dark-theme", &dark, "gtk-enable-animations", &animations,
                 "gtk-theme-name", &theme, "gtk-xft-dpi", &dpi, NULL);
    memset(out, 0, sizeof(*out));
    out->high_contrast = contains(theme, "contrast") ? 1u : 0u;
    if (dark || contains(theme, "dark") || contains(theme, "inverse")) out->scheme = 2;
    else out->scheme = theme && theme[0] ? 1 : 0;
    out->reduce_motion = animations ? 0u : 1u;
    out->text_scale = dpi > 0 ? (float)dpi / (96.0f * 1024.0f) : 1.0f;
    g_free(theme);
    return ZSD_OK;
}

/* Process-lifetime GIO singleton, resolved at runtime so GLib < 2.70 loads. */
typedef GObject *(*ZsdDupDefault)(void);
static GObject *power_profile_monitor(void) {
    static gboolean resolved;
    static GObject *monitor;
    if (!resolved) {
        resolved = TRUE;
        void *symbol = dlsym(RTLD_DEFAULT, "g_power_profile_monitor_dup_default");
        if (symbol) {
            ZsdDupDefault dup;
            memcpy(&dup, &symbol, sizeof(dup));
            monitor = dup();
        }
    }
    return monitor;
}

static gboolean read_small(const char *supply, const char *field, char *buffer, size_t size) {
    char path[256];
    int n = snprintf(path, sizeof(path), "/sys/class/power_supply/%s/%s", supply, field);
    if (n < 0 || (size_t)n >= sizeof(path)) return FALSE;
    FILE *file = fopen(path, "re");
    if (!file) return FALSE;
    gboolean ok = fgets(buffer, (int)size, file) != NULL;
    fclose(file);
    if (ok) buffer[strcspn(buffer, "\n")] = 0;
    return ok;
}

/* Bounded synchronous sysfs snapshot: at most 16 supplies, a few small reads
   each. Device-scope batteries (peripherals) are ignored. */
int zsd_power(ZsdPower *out) {
    out->source = 0;
    out->percent = -1;
    out->saver = -1;
    DIR *directory = opendir("/sys/class/power_supply");
    gboolean mains_online = FALSE, battery = FALSE;
    if (directory) {
        struct dirent *entry;
        for (int seen = 0; seen < 16 && (entry = readdir(directory)); ) {
            if (entry->d_name[0] == '.') continue;
            seen++;
            char type[32], value[32];
            if (!read_small(entry->d_name, "type", type, sizeof(type))) continue;
            if (!strcmp(type, "Mains") || !strcmp(type, "USB")) {
                if (read_small(entry->d_name, "online", value, sizeof(value)) && !strcmp(value, "1")) mains_online = TRUE;
            } else if (!strcmp(type, "Battery")) {
                if (read_small(entry->d_name, "scope", value, sizeof(value)) && !strcmp(value, "Device")) continue;
                battery = TRUE;
                if (out->percent < 0 && read_small(entry->d_name, "capacity", value, sizeof(value))) {
                    char *end = NULL;
                    long percent = strtol(value, &end, 10);
                    if (end != value && percent >= 0 && percent <= 100) out->percent = (int32_t)percent;
                }
            }
        }
        closedir(directory);
    }
    /* No supply entries (typical desktops, containers) stays unknown. */
    if (mains_online) out->source = 1;
    else if (battery) out->source = 2;
    GObject *monitor = power_profile_monitor();
    if (monitor) {
        gboolean saver = FALSE;
        g_object_get(monitor, "power-saver-enabled", &saver, NULL);
        out->saver = saver ? 1 : 0;
    }
    return ZSD_OK;
}

/* The netlink backend (and its base) cannot know metered state. */
static gboolean metered_known(GNetworkMonitor *monitor) {
    const char *type = G_OBJECT_TYPE_NAME(monitor);
    return strcmp(type, "GNetworkMonitorNetlink") != 0 && strcmp(type, "GNetworkMonitorBase") != 0;
}

int zsd_network(ZsdNetwork *out) {
    GNetworkMonitor *monitor = g_network_monitor_get_default();
    out->state = 0;
    out->metered = -1;
    if (!monitor) return ZSD_OK;
    out->state = g_network_monitor_get_network_available(monitor) ? 1 : 2;
    if (metered_known(monitor)) out->metered = g_network_monitor_get_network_metered(monitor) ? 1 : 0;
    return ZSD_OK;
}

#define ZSD_MAX_HANDLERS 16
typedef struct ZsdWatch {
    gint refs;
    void *owner;
    ZsdChanged changed;
    uint32_t kinds, pending;
    guint idle;
    unsigned count;
    gulong handlers[ZSD_MAX_HANDLERS];
    GObject *targets[ZSD_MAX_HANDLERS];
} ZsdWatch;

static void watch_release(gpointer data) {
    ZsdWatch *watch = data;
    if (g_atomic_int_dec_and_test(&watch->refs)) {
        g_free(watch);
        g_atomic_int_add(&live_states, -1);
    }
}

static gboolean watch_flush(gpointer data) {
    ZsdWatch *watch = data;
    uint32_t bits = watch->pending;
    watch->pending = 0;
    watch->idle = 0;
    /* The idle's own reference keeps watch alive even if the callback stops it. */
    if (watch->owner && bits) watch->changed(watch->owner, bits);
    return G_SOURCE_REMOVE;
}

/* One idle source per burst: synchronous notifications only merge bits. */
static void watch_mark(ZsdWatch *watch, uint32_t bits) {
    if (!watch->owner) return;
    watch->pending |= bits & watch->kinds;
    if (!watch->pending || watch->idle) return;
    g_atomic_int_inc(&watch->refs);
    watch->idle = g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, watch_flush, watch, watch_release);
}

static void on_screen(GdkScreen *screen, gpointer data) { (void)screen; watch_mark(data, ZSD_MONITORS); }
static void on_monitor(GdkDisplay *display, GdkMonitor *monitor, gpointer data) { (void)display; (void)monitor; watch_mark(data, ZSD_MONITORS); }
static void on_preference(GObject *object, GParamSpec *spec, gpointer data) { (void)object; (void)spec; watch_mark(data, ZSD_PREFERENCES); }
static void on_power(GObject *object, GParamSpec *spec, gpointer data) { (void)object; (void)spec; watch_mark(data, ZSD_POWER); }
static void on_network(GNetworkMonitor *monitor, gboolean available, gpointer data) { (void)monitor; (void)available; watch_mark(data, ZSD_NETWORK); }
static void on_network_property(GObject *object, GParamSpec *spec, gpointer data) { (void)object; (void)spec; watch_mark(data, ZSD_NETWORK); }

static void watch_connect(ZsdWatch *watch, gpointer target, const char *signal, GCallback callback) {
    g_assert(watch->count < ZSD_MAX_HANDLERS);
    watch->handlers[watch->count] = g_signal_connect(target, signal, callback, watch);
    watch->targets[watch->count] = g_object_ref(G_OBJECT(target));
    watch->count++;
}

void zsd_watch_stop(void *handle) {
    ZsdWatch *watch = handle;
    watch->owner = NULL;
    watch->pending = 0;
    for (unsigned i = 0; i < watch->count; i++) {
        g_signal_handler_disconnect(watch->targets[i], watch->handlers[i]);
        g_object_unref(watch->targets[i]);
    }
    watch->count = 0;
    if (watch->idle) {
        guint idle = watch->idle;
        watch->idle = 0;
        g_source_remove(idle);
    }
    watch_release(watch);
}

int zsd_watch_start(uint32_t kinds, void *owner, ZsdChanged changed, void **out) {
    GdkDisplay *display = NULL;
    GtkSettings *settings = NULL;
    if (kinds & ZSD_MONITORS) {
        display = gdk_display_get_default();
        if (!display || !GDK_IS_X11_DISPLAY(display)) return ZSD_UNSUPPORTED;
    }
    if (kinds & ZSD_PREFERENCES) {
        settings = gtk_settings_get_default();
        if (!settings) return ZSD_UNSUPPORTED;
    }
    ZsdWatch *watch = g_try_new0(ZsdWatch, 1);
    if (!watch) return ZSD_NO_MEMORY;
    watch->refs = 1;
    watch->owner = owner;
    watch->changed = changed;
    watch->kinds = kinds;
    g_atomic_int_inc(&live_states);
    if (display) {
        GdkScreen *screen = gdk_display_get_default_screen(display);
        watch_connect(watch, display, "monitor-added", G_CALLBACK(on_monitor));
        watch_connect(watch, display, "monitor-removed", G_CALLBACK(on_monitor));
        watch_connect(watch, screen, "monitors-changed", G_CALLBACK(on_screen));
        watch_connect(watch, screen, "size-changed", G_CALLBACK(on_screen));
    }
    if (settings) {
        watch_connect(watch, settings, "notify::gtk-application-prefer-dark-theme", G_CALLBACK(on_preference));
        watch_connect(watch, settings, "notify::gtk-theme-name", G_CALLBACK(on_preference));
        watch_connect(watch, settings, "notify::gtk-enable-animations", G_CALLBACK(on_preference));
        watch_connect(watch, settings, "notify::gtk-xft-dpi", G_CALLBACK(on_preference));
    }
    if (kinds & ZSD_POWER) {
        GObject *monitor = power_profile_monitor();
        if (monitor) watch_connect(watch, monitor, "notify::power-saver-enabled", G_CALLBACK(on_power));
    }
    if (kinds & ZSD_NETWORK) {
        GNetworkMonitor *monitor = g_network_monitor_get_default();
        if (monitor) {
            watch_connect(watch, monitor, "network-changed", G_CALLBACK(on_network));
            watch_connect(watch, monitor, "notify::network-metered", G_CALLBACK(on_network_property));
            watch_connect(watch, monitor, "notify::connectivity", G_CALLBACK(on_network_property));
        }
    }
    *out = watch;
    return ZSD_OK;
}
