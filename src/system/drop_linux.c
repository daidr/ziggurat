#include <gtk/gtk.h>
#include <stdint.h>
#include <string.h>

/* Manual GTK drop destination for system.drop. The record is shared by the
 * Zig Target and the widget: destroy drops the widget reference, detach drops
 * the Target reference, and the last one frees it. Callbacks never run after
 * either side let go. */

enum { PHASE_ENTER, PHASE_OVER, PHASE_LEAVE };
enum { STATUS_FILES, STATUS_TEXT, STATUS_TOO_MANY_FILES, STATUS_MALFORMED };
#define MAX_FILES 1024
#define INFO_FILES 1u
#define INFO_TEXT 2u

typedef struct ZsdCallbacks {
    int (*hover)(void *owner, int phase, double x, double y, int files, int text);
    void (*drop)(void *owner, double x, double y, int status, const uint8_t *data, size_t len);
} ZsdCallbacks;
typedef struct ZsdTarget {
    gint refs;
    GtkWidget *widget;
    void *owner;
    ZsdCallbacks callbacks;
    gboolean want_files, want_text, inside, offered_files, offered_text, created_site;
    GtkTargetList *previous;
    double x, y;
    gulong handlers[5];
} ZsdTarget;

static void target_release(ZsdTarget *target) {
    if (!g_atomic_int_dec_and_test(&target->refs)) return;
    if (target->previous) gtk_target_list_unref(target->previous);
    g_free(target);
}
static void client_point(ZsdTarget *target, gint x, gint y) {
    /* Widget coordinates include client-side decoration; report the content. */
    GtkWidget *child = gtk_bin_get_child(GTK_BIN(target->widget));
    gint cx = x, cy = y;
    if (child && gtk_widget_get_realized(child)) gtk_widget_translate_coordinates(target->widget, child, x, y, &cx, &cy);
    target->x = cx; target->y = cy;
}
static void offered(ZsdTarget *target, GdkDragContext *context) {
    target->offered_files = FALSE; target->offered_text = FALSE;
    GList *list = gdk_drag_context_list_targets(context);
    guint count = g_list_length(list), i = 0;
    GdkAtom *atoms = g_new0(GdkAtom, count ? count : 1);
    for (GList *item = list; item; item = item->next) atoms[i++] = GDK_POINTER_TO_ATOM(item->data);
    if (target->want_files && gtk_targets_include_uri(atoms, (gint)count)) target->offered_files = TRUE;
    if (target->want_text && gtk_targets_include_text(atoms, (gint)count)) target->offered_text = TRUE;
    g_free(atoms);
}
static int hover(ZsdTarget *target, int phase) {
    if (!target->owner) return 0;
    return target->callbacks.hover(target->owner, phase, target->x, target->y, target->offered_files, target->offered_text);
}
static gboolean motion(GtkWidget *widget, GdkDragContext *context, gint x, gint y, guint time, gpointer data) {
    (void)widget;
    ZsdTarget *target = data;
    int phase = target->inside ? PHASE_OVER : PHASE_ENTER;
    if (!target->inside) offered(target, context);
    target->inside = TRUE;
    client_point(target, x, y);
    gdk_drag_status(context, hover(target, phase) ? GDK_ACTION_COPY : 0, time);
    return TRUE;
}
static void leave(GtkWidget *widget, GdkDragContext *context, guint time, gpointer data) {
    (void)widget; (void)context; (void)time;
    ZsdTarget *target = data;
    if (!target->inside) return;
    target->inside = FALSE;
    hover(target, PHASE_LEAVE);
}
static gboolean drop(GtkWidget *widget, GdkDragContext *context, gint x, gint y, guint time, gpointer data) {
    ZsdTarget *target = data;
    /* GTK emits drag-leave before drag-drop, which already closed the hover. */
    client_point(target, x, y);
    offered(target, context);
    const char *name = target->offered_files ? "text/uri-list" : NULL;
    GdkAtom atom = name ? gdk_atom_intern_static_string(name) : gtk_drag_dest_find_target(widget, context, NULL);
    if (!target->owner || atom == GDK_NONE || (!target->offered_files && !target->offered_text)) { gtk_drag_finish(context, FALSE, FALSE, time); return TRUE; }
    gtk_drag_get_data(widget, context, atom, time);
    return TRUE;
}
static void received(GtkWidget *widget, GdkDragContext *context, gint x, gint y, GtkSelectionData *selection, guint info, guint time, gpointer data) {
    (void)widget; (void)x; (void)y;
    ZsdTarget *target = data;
    gboolean ok = FALSE;
    if (!target->owner) { gtk_drag_finish(context, FALSE, FALSE, time); return; }
    if (info == INFO_FILES) {
        gchar **uris = gtk_selection_data_get_uris(selection);
        GByteArray *out = g_byte_array_new();
        int status = STATUS_FILES;
        size_t count = 0;
        for (gchar **uri = uris; uri && *uri && status == STATUS_FILES; uri++) {
            gchar *path = g_filename_from_uri(*uri, NULL, NULL);
            if (!path) continue;
            size_t len = strlen(path);
            if (++count > MAX_FILES) status = STATUS_TOO_MANY_FILES;
            else if (!g_utf8_validate(path, (gssize)len, NULL)) status = STATUS_MALFORMED;
            else {
                if (out->len) g_byte_array_append(out, (const guint8 *)"", 1);
                g_byte_array_append(out, (const guint8 *)path, (guint)len);
            }
            g_free(path);
        }
        if (status == STATUS_FILES && count == 0) status = STATUS_MALFORMED;
        ok = status == STATUS_FILES;
        target->callbacks.drop(target->owner, target->x, target->y, status, out->data, out->len);
        g_byte_array_unref(out);
        g_strfreev(uris);
    } else {
        guchar *text = gtk_selection_data_get_text(selection);
        size_t len = text ? strlen((const char *)text) : 0;
        ok = text && g_utf8_validate((const gchar *)text, (gssize)len, NULL);
        target->callbacks.drop(target->owner, target->x, target->y, ok ? STATUS_TEXT : STATUS_MALFORMED, text, len);
        g_free(text);
    }
    gtk_drag_finish(context, ok, FALSE, time);
}
static void destroyed(GtkWidget *widget, gpointer data) {
    ZsdTarget *target = data;
    for (int i = 0; i < 5; i++) if (target->handlers[i]) g_signal_handler_disconnect(widget, target->handlers[i]);
    memset(target->handlers, 0, sizeof target->handlers);
    target->widget = NULL;
    target->owner = NULL;
    target_release(target);
}

void *zsd_attach(GtkWidget *widget, void *owner, const ZsdCallbacks *callbacks, int files, int text) {
    if (!GTK_IS_WINDOW(widget)) return NULL;
    ZsdTarget *target = g_try_new0(ZsdTarget, 1);
    if (!target) return NULL;
    target->refs = 2; target->widget = widget; target->owner = owner; target->callbacks = *callbacks;
    target->want_files = files; target->want_text = text;
    if (g_object_get_data(G_OBJECT(widget), "ziggurat-system-drop")) { g_free(target); return NULL; }
    /* GtkWindow already registers a manual site for root-window drops. Extend
     * that list and restore it on detach instead of replacing the site. */
    GtkTargetList *list = gtk_target_list_new(NULL, 0);
    target->previous = gtk_drag_dest_get_target_list(widget);
    if (target->previous) {
        gtk_target_list_ref(target->previous);
        gint n = 0;
        GtkTargetEntry *entries = gtk_target_table_new_from_list(target->previous, &n);
        gtk_target_list_add_table(list, entries, (guint)n);
        gtk_target_table_free(entries, n);
    } else {
        gtk_drag_dest_set(widget, 0, NULL, 0, GDK_ACTION_COPY);
        target->created_site = TRUE;
    }
    if (files) gtk_target_list_add_uri_targets(list, INFO_FILES);
    if (text) gtk_target_list_add_text_targets(list, INFO_TEXT);
    gtk_drag_dest_set_target_list(widget, list);
    gtk_target_list_unref(list);
    g_object_set_data(G_OBJECT(widget), "ziggurat-system-drop", target);
    target->handlers[0] = g_signal_connect(widget, "drag-motion", G_CALLBACK(motion), target);
    target->handlers[1] = g_signal_connect(widget, "drag-leave", G_CALLBACK(leave), target);
    target->handlers[2] = g_signal_connect(widget, "drag-drop", G_CALLBACK(drop), target);
    target->handlers[3] = g_signal_connect(widget, "drag-data-received", G_CALLBACK(received), target);
    target->handlers[4] = g_signal_connect(widget, "destroy", G_CALLBACK(destroyed), target);
    return target;
}
void zsd_detach(void *pointer) {
    ZsdTarget *target = pointer;
    if (target->widget) {
        GtkWidget *widget = target->widget;
        for (int i = 0; i < 5; i++) if (target->handlers[i]) g_signal_handler_disconnect(widget, target->handlers[i]);
        memset(target->handlers, 0, sizeof target->handlers);
        g_object_set_data(G_OBJECT(widget), "ziggurat-system-drop", NULL);
        if (target->created_site) gtk_drag_dest_unset(widget);
        else gtk_drag_dest_set_target_list(widget, target->previous);
        target->widget = NULL;
        target_release(target);
    }
    target->owner = NULL;
    target_release(target);
}
int zsd_registered(GtkWidget *widget) { return g_object_get_data(G_OBJECT(widget), "ziggurat-system-drop") != NULL; }
