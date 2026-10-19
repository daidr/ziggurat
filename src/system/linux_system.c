#include <gtk/gtk.h>
#include <stdint.h>

/* GTK popup menus and message dialogs. Neither runs a nested main loop:
   menus use the popup-at-rect API and dialogs report through "response".
   Each widget carries a Link with no pointer into Zig other than the opaque
   owner token, which Zig clears before the owner can disappear. Completion
   is reported from a one-shot idle callback, outside GTK signal emission. */

typedef void (*Done)(void *owner, uint64_t serial, int32_t result);
typedef struct Link {
    int refs;
    void *owner;
    uint64_t serial;
    Done done;
    GtkWidget *widget;
    int32_t result;
    gboolean reported;
    gboolean scheduled;
} Link;
typedef struct Item {
    const char *label;
    int32_t parent;
    uint8_t kind;
    uint8_t enabled;
    uint8_t checked;
    uint8_t padding;
    uint32_t keyval;
    uint32_t modifiers;
    int32_t command;
} Item;

static gint live_links;

static void link_release(Link *link) {
    if (--link->refs) return;
    g_atomic_int_dec_and_test(&live_links);
    g_free(link);
}
static Link *link_new(void *owner, uint64_t serial, Done done) {
    Link *link = g_new0(Link, 1);
    link->refs = 1;
    link->owner = owner;
    link->serial = serial;
    link->done = done;
    link->result = -1;
    g_atomic_int_inc(&live_links);
    return link;
}
static void widget_destroyed(GtkWidget *widget, gpointer data) {
    (void)widget;
    Link *link = data;
    link->widget = NULL;
    link_release(link);
}
static gboolean report(gpointer data) {
    Link *link = data;
    link->scheduled = FALSE;
    void *owner = link->owner;
    GtkWidget *widget = link->widget;
    link->owner = NULL;
    if (widget) g_object_ref(widget);
    if (owner) link->done(owner, link->serial, link->result);
    if (widget) {
        if (link->widget == widget) gtk_widget_destroy(widget);
        g_object_unref(widget);
    }
    link_release(link);
    return G_SOURCE_REMOVE;
}
static void schedule(Link *link, int32_t result) {
    if (link->reported) return;
    link->reported = TRUE;
    link->result = result;
    link->scheduled = TRUE;
    ++link->refs;
    g_idle_add_full(G_PRIORITY_DEFAULT, report, link, NULL);
}

static GdkWindow *client_window(GtkWidget *window) {
    GtkWidget *child = GTK_IS_BIN(window) ? gtk_bin_get_child(GTK_BIN(window)) : NULL;
    GdkWindow *native = child && gtk_widget_get_has_window(child) ? gtk_widget_get_window(child) : NULL;
    return native ? native : gtk_widget_get_window(window);
}

/* ---- popup menus ---- */

static void item_activated(GtkMenuItem *item, gpointer data) {
    Link *link = data;
    if (!link->reported) link->result = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(item), "ziggurat-command"));
}
static void selection_done(GtkMenuShell *shell, gpointer data) {
    (void)shell;
    Link *link = data;
    schedule(link, link->result);
}

/* anchor: 0 pointer, 1 client logical point, 2 physical screen point. */
Link *zsl_popup_show(GtkWidget *window, const Item *items, uint32_t count, int anchor, double x, double y, void *owner, uint64_t serial, Done done, int *error) {
    *error = 0;
    GdkWindow *target = window ? client_window(window) : NULL;
    if (!target || !gdk_window_is_viewable(target)) { *error = 1; return NULL; }
    GtkWidget *menus[128] = {0};
    GtkWidget *root = gtk_menu_new();
    g_object_ref_sink(root);
    Link *link = link_new(owner, serial, done);
    link->widget = root;
    g_signal_connect(root, "destroy", G_CALLBACK(widget_destroyed), link);
    g_signal_connect(root, "selection-done", G_CALLBACK(selection_done), link);
    for (uint32_t i = 0; i < count && i < 128; ++i) {
        const Item *item = &items[i];
        GtkWidget *parent = item->parent >= 0 ? menus[item->parent] : root;
        GtkWidget *entry;
        if (item->kind == 2) entry = gtk_separator_menu_item_new();
        else {
            entry = item->checked && item->kind == 0 ? gtk_check_menu_item_new_with_mnemonic(item->label) : gtk_menu_item_new_with_mnemonic(item->label);
            if (item->checked && item->kind == 0) gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(entry), TRUE);
            if (item->keyval) {
                GtkWidget *label = gtk_bin_get_child(GTK_BIN(entry));
                if (GTK_IS_ACCEL_LABEL(label)) gtk_accel_label_set_accel(GTK_ACCEL_LABEL(label), item->keyval, item->modifiers);
            }
            gtk_widget_set_sensitive(entry, item->enabled != 0);
            if (item->kind == 1) {
                menus[i] = gtk_menu_new();
                gtk_menu_item_set_submenu(GTK_MENU_ITEM(entry), menus[i]);
            } else {
                g_object_set_data(G_OBJECT(entry), "ziggurat-command", GINT_TO_POINTER(item->command));
                g_signal_connect(entry, "activate", G_CALLBACK(item_activated), link);
            }
        }
        gtk_menu_shell_append(GTK_MENU_SHELL(parent), entry);
    }
    gtk_widget_show_all(root);
    gtk_menu_set_screen(GTK_MENU(root), gdk_window_get_screen(target));
    GdkRectangle rect = {0, 0, 1, 1};
    if (anchor == 0) {
        GdkSeat *seat = gdk_display_get_default_seat(gdk_window_get_display(target));
        GdkDevice *pointer = seat ? gdk_seat_get_pointer(seat) : NULL;
        if (pointer) gdk_window_get_device_position(target, pointer, &rect.x, &rect.y, NULL);
    } else if (anchor == 1) {
        rect.x = (int)x; rect.y = (int)y;
    } else {
        int origin_x = 0, origin_y = 0, scale = gdk_window_get_scale_factor(target);
        gdk_window_get_origin(target, &origin_x, &origin_y);
        rect.x = (int)(x / (scale > 0 ? scale : 1)) - origin_x;
        rect.y = (int)(y / (scale > 0 ? scale : 1)) - origin_y;
    }
    gtk_menu_popup_at_rect(GTK_MENU(root), target, &rect, GDK_GRAVITY_NORTH_WEST, GDK_GRAVITY_NORTH_WEST, NULL);
    /* A menu that could not take its grab never opens; report dismissal. */
    if (!gtk_widget_get_visible(root)) schedule(link, -1);
    g_object_unref(root);
    return link;
}
/* Closes the menu; completion still reports through Done. */
void zsl_popup_cancel(Link *link) {
    if (link->widget && !link->reported) gtk_menu_shell_cancel(GTK_MENU_SHELL(link->widget));
    if (!link->reported) schedule(link, -1);
}
/* Native activation of the n-th command item, as a keyboard choice would do. */
int zsl_popup_activate(Link *link, int32_t command) {
    if (!link->widget || link->reported) return 0;
    GList *pending = g_list_prepend(NULL, link->widget);
    GtkWidget *found = NULL;
    while (pending && !found) {
        GtkWidget *shell = pending->data;
        pending = g_list_delete_link(pending, pending);
        GList *children = gtk_container_get_children(GTK_CONTAINER(shell));
        for (GList *cursor = children; cursor && !found; cursor = cursor->next) {
            GtkWidget *child = cursor->data;
            GtkWidget *submenu = GTK_IS_MENU_ITEM(child) ? gtk_menu_item_get_submenu(GTK_MENU_ITEM(child)) : NULL;
            if (submenu) pending = g_list_append(pending, submenu);
            else if (GTK_IS_MENU_ITEM(child) && g_signal_handler_find(child, G_SIGNAL_MATCH_DATA, 0, 0, NULL, NULL, link) &&
                GPOINTER_TO_INT(g_object_get_data(G_OBJECT(child), "ziggurat-command")) == command) found = child;
        }
        g_list_free(children);
    }
    g_list_free(pending);
    if (!found || !gtk_widget_is_sensitive(found)) return 0;
    GtkWidget *root = g_object_ref(link->widget);
    gtk_menu_shell_activate_item(GTK_MENU_SHELL(gtk_widget_get_parent(found)), found, TRUE);
    /* A submenu that was never opened by pointer or keyboard has no parent
       shell, so only the root's own cancellation closes the hierarchy. */
    if (!link->reported && link->widget == root) gtk_menu_shell_cancel(GTK_MENU_SHELL(root));
    g_object_unref(root);
    return 1;
}

/* ---- message dialogs ---- */

static void dialog_response(GtkDialog *dialog, gint response, gpointer data) {
    (void)dialog;
    Link *link = data;
    /* -1 is a close request; -2 an explicit cancel from the application. */
    schedule(link, response >= 0 ? response : response == GTK_RESPONSE_CANCEL ? -2 : -1);
}

Link *zsl_message_show(GtkWidget *window, const char *title, const char *message, const char *const *buttons, uint32_t count, int32_t default_index, int kind, void *owner, uint64_t serial, Done done, int *error) {
    *error = 0;
    if (!window || !GTK_IS_WINDOW(window)) { *error = 1; return NULL; }
    static const GtkMessageType types[] = {GTK_MESSAGE_INFO, GTK_MESSAGE_WARNING, GTK_MESSAGE_ERROR, GTK_MESSAGE_QUESTION};
    GtkWidget *dialog = gtk_message_dialog_new(GTK_WINDOW(window), GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT, types[kind & 3], GTK_BUTTONS_NONE, "%s", message);
    g_object_ref_sink(dialog);
    if (title[0]) gtk_window_set_title(GTK_WINDOW(dialog), title);
    for (uint32_t i = 0; i < count; ++i) gtk_dialog_add_button(GTK_DIALOG(dialog), buttons[i], (gint)i);
    if (default_index >= 0) gtk_dialog_set_default_response(GTK_DIALOG(dialog), default_index);
    Link *link = link_new(owner, serial, done);
    link->widget = dialog;
    g_signal_connect(dialog, "destroy", G_CALLBACK(widget_destroyed), link);
    g_signal_connect(dialog, "response", G_CALLBACK(dialog_response), link);
    gtk_widget_show(dialog);
    g_object_unref(dialog);
    return link;
}
void zsl_message_cancel(Link *link) {
    if (link->widget && !link->reported) gtk_dialog_response(GTK_DIALOG(link->widget), GTK_RESPONSE_CANCEL);
}
/* Native button activation, as a click would do. */
int zsl_message_press(Link *link, int32_t index) {
    if (!link->widget || link->reported) return 0;
    GtkWidget *button = gtk_dialog_get_widget_for_response(GTK_DIALOG(link->widget), index);
    if (!button) return 0;
    gtk_button_clicked(GTK_BUTTON(button));
    return 1;
}
int zsl_message_close(Link *link) {
    if (!link->widget || link->reported) return 0;
    gtk_window_close(GTK_WINDOW(link->widget));
    return 1;
}

/* Silent: no Done call follows. Destroys the widget if it still exists. */
void zsl_detach(Link *link) {
    link->owner = NULL;
    link->reported = TRUE;
    GtkWidget *widget = link->widget;
    ++link->refs;
    if (widget) gtk_widget_destroy(widget);
    link_release(link);
}
int zsl_live_links(void) { return g_atomic_int_get(&live_links); }
