/* GTK drag sources and multi-format drop targets for system.drag and
   system.drop.DataTarget. Every entry runs on the GTK main thread. Zig owns
   the formats and bytes; this file only moves selection data. */
#include <gtk/gtk.h>
#include <stdint.h>
#include <string.h>

/* ---- Drag source ---- */

typedef struct ZstSourceCallbacks {
    int (*get)(void *owner, const char *target, const uint8_t **data, size_t *len);
    /* status: 0 dropped, 1 no target, 2 given up, 3 failed */
    void (*end)(void *owner, int action, int status, int escaped);
} ZstSourceCallbacks;

typedef struct ZstSource {
    GtkWidget *widget;
    GdkDragContext *context;
    void *owner;
    ZstSourceCallbacks callbacks;
    int status, escaped;
    gulong handlers[4];
} ZstSource;

/* A copy of the event being handled when it can start a drag: a press, or
   a move with a button held. */
void *zst_current_event(void) {
    GdkEvent *event = gtk_get_current_event();
    if (!event) return NULL;
    GdkModifierType state = 0;
    gboolean usable = event->type == GDK_BUTTON_PRESS ||
        (event->type == GDK_MOTION_NOTIFY && gdk_event_get_state(event, &state) &&
         (state & (GDK_BUTTON1_MASK | GDK_BUTTON2_MASK | GDK_BUTTON3_MASK)));
    if (!usable) { gdk_event_free(event); return NULL; }
    return event;
}
void zst_event_free(void *event) { gdk_event_free(event); }

static void source_free(ZstSource *source) {
    for (int i = 0; i < 4; i++) if (source->handlers[i]) g_signal_handler_disconnect(source->widget, source->handlers[i]);
    g_object_unref(source->widget);
    g_free(source);
}
static void source_end_now(ZstSource *source, int action) {
    void *owner = source->owner;
    source->owner = NULL;
    if (owner) source->callbacks.end(owner, action, source->status, source->escaped);
}
static void source_get(GtkWidget *widget, GdkDragContext *context, GtkSelectionData *selection, guint info, guint time, gpointer data) {
    (void)widget; (void)info; (void)time;
    ZstSource *source = data;
    if (context != source->context || !source->owner) return;
    GdkAtom target = gtk_selection_data_get_target(selection);
    gchar *name = gdk_atom_name(target);
    const uint8_t *bytes = NULL;
    size_t len = 0;
    if (name && source->callbacks.get(source->owner, name, &bytes, &len) == 0) {
        static const guchar empty = 0;
        gtk_selection_data_set(selection, target, 8, len ? bytes : &empty, (gint)len);
    }
    g_free(name);
}
static gboolean source_failed(GtkWidget *widget, GdkDragContext *context, GtkDragResult result, gpointer data) {
    (void)widget;
    ZstSource *source = data;
    if (context != source->context) return FALSE;
    /* No target and Escape are ordinary ends without a drop. */
    source->status = result == GTK_DRAG_RESULT_NO_TARGET ? 1 : result == GTK_DRAG_RESULT_USER_CANCELLED ? 2 : 3;
    if (result == GTK_DRAG_RESULT_USER_CANCELLED) source->escaped = 1;
    /* Ours ended it: no snap-back animation keeps the grab. */
    return source->owner == NULL;
}
static void source_end(GtkWidget *widget, GdkDragContext *context, gpointer data) {
    (void)widget;
    ZstSource *source = data;
    if (context != source->context) return;
    int action = source->status == 0 ? (int)gdk_drag_context_get_selected_action(context) : 0;
    if (source->status == 0 && action == 0) source->status = 1;
    source_end_now(source, action);
    source->context = NULL;
    g_object_unref(context);
    source_free(source);
}
static void source_destroyed(GtkWidget *widget, gpointer data) {
    (void)widget;
    ZstSource *source = data;
    /* The source window closing gives the drag up. */
    source->status = 2;
    source->escaped = 1;
    source_end_now(source, 0);
    if (source->context) gtk_drag_cancel(source->context);
}

void *zst_source_begin(GtkWidget *widget, GdkEvent *event, const char *names, size_t names_len, int actions,
                       const uint8_t *rgba, int width, int height, int hot_x, int hot_y,
                       void *owner, const ZstSourceCallbacks *callbacks) {
    GtkTargetList *list = gtk_target_list_new(NULL, 0);
    for (size_t at = 0; at < names_len;) {
        const char *name = names + at;
        size_t len = strlen(name);
        gtk_target_list_add(list, gdk_atom_intern(name, FALSE), 0, 0);
        at += len + 1;
    }
    ZstSource *source = g_new0(ZstSource, 1);
    source->widget = g_object_ref(widget);
    source->owner = owner;
    source->callbacks = *callbacks;
    source->handlers[0] = g_signal_connect(widget, "drag-data-get", G_CALLBACK(source_get), source);
    source->handlers[1] = g_signal_connect(widget, "drag-failed", G_CALLBACK(source_failed), source);
    source->handlers[2] = g_signal_connect(widget, "drag-end", G_CALLBACK(source_end), source);
    source->handlers[3] = g_signal_connect(widget, "destroy", G_CALLBACK(source_destroyed), source);
    guint button = 1;
    if (event->type == GDK_BUTTON_PRESS) button = event->button.button;
    GdkDragContext *context = gtk_drag_begin_with_coordinates(widget, list, (GdkDragAction)actions, (gint)button, event, -1, -1);
    gtk_target_list_unref(list);
    if (!context) {
        source->owner = NULL;
        source_free(source);
        return NULL;
    }
    source->context = g_object_ref(context);
    if (rgba && width > 0 && height > 0) {
        GdkPixbuf *pixbuf = gdk_pixbuf_new_from_data(rgba, GDK_COLORSPACE_RGB, TRUE, 8, width, height, width * 4, NULL, NULL);
        if (pixbuf) {
            GdkPixbuf *copy = gdk_pixbuf_copy(pixbuf);
            g_object_unref(pixbuf);
            if (copy) {
                gtk_drag_set_icon_pixbuf(context, copy, hot_x, hot_y);
                g_object_unref(copy);
            }
        }
    }
    return source;
}
/* Silent: the owner hears nothing more. The record ends with drag-end. */
void zst_source_cancel(void *pointer) {
    ZstSource *source = pointer;
    source->owner = NULL;
    source->status = 2;
    if (source->context) gtk_drag_cancel(source->context);
}
/* The session a drop target reports to Zig, which matches it against its
   own drag with zst_session_is. */
void *zst_context_session(GdkDragContext *context) {
    return context;
}
/* Whether a drop target's context is this source's drag: in-process XDND
   gives the destination its own context for the same source window. */
int zst_session_is(void *pointer, GdkDragContext *context) {
    ZstSource *source = pointer;
    if (!source || !source->context) return 0;
    if (source->context == context) return 1;
    GdkWindow *window = gdk_drag_context_get_source_window(source->context);
    return window && window == gdk_drag_context_get_source_window(context);
}

/* ---- Multi-format drop target ---- */

typedef struct ZstTargetCallbacks {
    /* phase 0 enter, 1 over, 2 leave. targets: NUL-terminated names.
       Returns the GdkDragAction to report, 0 to refuse. */
    int (*hover)(void *owner, int phase, double x, double y, const char *targets, size_t len, int actions, int suggested, void *session);
    /* Returns the action of an accepted drop, 0 to refuse. It may request
       targets with zst_target_request before returning. */
    int (*drop)(void *owner, void *record, double x, double y, const char *targets, size_t len, int actions, int suggested, void *session);
    void (*received)(void *owner, const char *target, const uint8_t *data, int len);
    /* All requested targets arrived. Returns whether the drop was taken. */
    int (*complete)(void *owner);
} ZstTargetCallbacks;

typedef struct ZstTarget {
    gint refs;
    GtkWidget *widget;
    void *owner;
    ZstTargetCallbacks callbacks;
    gboolean inside, created_site;
    GtkTargetList *previous;
    double x, y;
    GdkDragContext *pending_context;
    guint pending_time, pending;
    int pending_action;
    gulong handlers[5];
} ZstTarget;

static void target_release(ZstTarget *target) {
    if (!g_atomic_int_dec_and_test(&target->refs)) return;
    if (target->previous) gtk_target_list_unref(target->previous);
    g_free(target);
}
static void target_point(ZstTarget *target, gint x, gint y) {
    /* Widget coordinates include client-side decoration; report the content. */
    GtkWidget *child = gtk_bin_get_child(GTK_BIN(target->widget));
    gint cx = x, cy = y;
    if (child && gtk_widget_get_realized(child)) gtk_widget_translate_coordinates(target->widget, child, x, y, &cx, &cy);
    target->x = cx; target->y = cy;
}
static GString *target_names(GdkDragContext *context) {
    GString *names = g_string_new(NULL);
    for (GList *item = gdk_drag_context_list_targets(context); item; item = item->next) {
        gchar *name = gdk_atom_name(GDK_POINTER_TO_ATOM(item->data));
        if (name) g_string_append_len(names, name, (gssize)strlen(name) + 1);
        g_free(name);
    }
    return names;
}
static int suggested_action(GdkDragContext *context) {
    return (int)gdk_drag_context_get_suggested_action(context);
}
static void finish_pending(ZstTarget *target, gboolean success) {
    GdkDragContext *context = target->pending_context;
    if (!context) return;
    target->pending_context = NULL;
    target->pending = 0;
    gtk_drag_finish(context, success, success && target->pending_action == GDK_ACTION_MOVE, target->pending_time);
    g_object_unref(context);
}
static gboolean target_motion(GtkWidget *widget, GdkDragContext *context, gint x, gint y, guint time, gpointer data) {
    (void)widget;
    ZstTarget *target = data;
    if (!target->owner) return FALSE;
    int phase = target->inside ? 1 : 0;
    target->inside = TRUE;
    target_point(target, x, y);
    GString *names = target_names(context);
    int action = target->callbacks.hover(target->owner, phase, target->x, target->y, names->str, names->len,
                                         (int)gdk_drag_context_get_actions(context), suggested_action(context), zst_context_session(context));
    g_string_free(names, TRUE);
    gdk_drag_status(context, (GdkDragAction)action, time);
    return TRUE;
}
static void target_leave(GtkWidget *widget, GdkDragContext *context, guint time, gpointer data) {
    (void)widget; (void)context; (void)time;
    ZstTarget *target = data;
    if (!target->inside || !target->owner) return;
    target->inside = FALSE;
    target->callbacks.hover(target->owner, 2, target->x, target->y, "", 0, 0, 0, NULL);
}
static gboolean target_drop(GtkWidget *widget, GdkDragContext *context, gint x, gint y, guint time, gpointer data) {
    (void)widget;
    ZstTarget *target = data;
    if (!target->owner) return FALSE;
    finish_pending(target, FALSE);
    target_point(target, x, y);
    target->pending_context = g_object_ref(context);
    target->pending_time = time;
    /* One count for the requests themselves: an in-process source can
       answer a request before the next one is made. */
    target->pending = 1;
    GString *names = target_names(context);
    int action = target->callbacks.drop(target->owner, target, target->x, target->y, names->str, names->len,
                                        (int)gdk_drag_context_get_actions(context), suggested_action(context), zst_context_session(context));
    g_string_free(names, TRUE);
    target->pending_action = action;
    if (!target->pending_context) return TRUE;
    if (action == 0) finish_pending(target, FALSE);
    else if (--target->pending == 0) finish_pending(target, target->owner && target->callbacks.complete(target->owner) != 0);
    return TRUE;
}
/* Asks the source for one target of the drop being handled. */
void zst_target_request(void *pointer, const char *name) {
    ZstTarget *target = pointer;
    if (!target->pending_context) return;
    target->pending++;
    gtk_drag_get_data(target->widget, target->pending_context, gdk_atom_intern(name, FALSE), target->pending_time);
}
static void target_received(GtkWidget *widget, GdkDragContext *context, gint x, gint y, GtkSelectionData *selection, guint info, guint time, gpointer data) {
    (void)widget; (void)x; (void)y; (void)info; (void)time;
    ZstTarget *target = data;
    if (context != target->pending_context || target->pending == 0) return;
    gchar *name = gdk_atom_name(gtk_selection_data_get_target(selection));
    if (target->owner && name) target->callbacks.received(target->owner, name, gtk_selection_data_get_data(selection), gtk_selection_data_get_length(selection));
    g_free(name);
    if (--target->pending != 0) return;
    finish_pending(target, target->owner && target->callbacks.complete(target->owner) != 0);
}
static void target_destroyed(GtkWidget *widget, gpointer data) {
    ZstTarget *target = data;
    finish_pending(target, FALSE);
    for (int i = 0; i < 5; i++) if (target->handlers[i]) g_signal_handler_disconnect(widget, target->handlers[i]);
    memset(target->handlers, 0, sizeof target->handlers);
    g_object_set_data(G_OBJECT(widget), "ziggurat-system-drop", NULL);
    target->widget = NULL;
    target->owner = NULL;
    target_release(target);
}

void *zst_target_attach(GtkWidget *widget, void *owner, const ZstTargetCallbacks *callbacks) {
    if (!GTK_IS_WINDOW(widget) || g_object_get_data(G_OBJECT(widget), "ziggurat-system-drop")) return NULL;
    ZstTarget *target = g_try_new0(ZstTarget, 1);
    if (!target) return NULL;
    target->refs = 2; target->widget = widget; target->owner = owner; target->callbacks = *callbacks;
    /* GtkWindow's own site takes root-window drops with default motion and
       drop handling, which would refuse other targets before drag-motion.
       A manual site replaces it while attached; detach restores it. */
    target->previous = gtk_drag_dest_get_target_list(widget);
    if (target->previous) gtk_target_list_ref(target->previous);
    else target->created_site = TRUE;
    gtk_drag_dest_set(widget, 0, NULL, 0, GDK_ACTION_COPY | GDK_ACTION_MOVE);
    g_object_set_data(G_OBJECT(widget), "ziggurat-system-drop", target);
    target->handlers[0] = g_signal_connect(widget, "drag-motion", G_CALLBACK(target_motion), target);
    target->handlers[1] = g_signal_connect(widget, "drag-leave", G_CALLBACK(target_leave), target);
    target->handlers[2] = g_signal_connect(widget, "drag-drop", G_CALLBACK(target_drop), target);
    target->handlers[3] = g_signal_connect(widget, "drag-data-received", G_CALLBACK(target_received), target);
    target->handlers[4] = g_signal_connect(widget, "destroy", G_CALLBACK(target_destroyed), target);
    return target;
}
void zst_target_detach(void *pointer) {
    ZstTarget *target = pointer;
    if (target->widget) {
        GtkWidget *widget = target->widget;
        finish_pending(target, FALSE);
        for (int i = 0; i < 5; i++) if (target->handlers[i]) g_signal_handler_disconnect(widget, target->handlers[i]);
        memset(target->handlers, 0, sizeof target->handlers);
        g_object_set_data(G_OBJECT(widget), "ziggurat-system-drop", NULL);
        if (target->created_site) gtk_drag_dest_unset(widget);
        else {
            gint count = 0;
            GtkTargetEntry *entries = gtk_target_table_new_from_list(target->previous, &count);
            gtk_drag_dest_set(widget, GTK_DEST_DEFAULT_MOTION | GTK_DEST_DEFAULT_DROP, entries, count, GDK_ACTION_MOVE);
            gtk_target_table_free(entries, count);
        }
        target->widget = NULL;
        target_release(target);
    }
    target->owner = NULL;
    target_release(target);
}
