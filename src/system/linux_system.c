#include <gtk/gtk.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#include <stdint.h>
#include <string.h>

/* GTK popup menus, menu bars, message dialogs and file choosers. None runs a
   nested main loop: menus use the popup-at-rect API, dialogs and choosers
   report through "response", and menu bar commands report from idle.
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
    /* A 1x1 popup window that anchors a menu opened without an owner window. */
    GtkWidget *anchor;
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
    if (link->anchor) { gtk_widget_destroy(link->anchor); g_object_unref(link->anchor); }
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
    /* A menu bar box has no window of its own; use the content beside it. */
    if (child && GTK_IS_BOX(child)) {
        GList *children = gtk_container_get_children(GTK_CONTAINER(child));
        GList *last = g_list_last(children);
        child = last && !GTK_IS_MENU_BAR(last->data) ? last->data : NULL;
        g_list_free(children);
    }
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

static int root_scale(void) {
    GdkWindow *root = gdk_get_default_root_window();
    int scale = root ? gdk_window_get_scale_factor(root) : 1;
    return scale > 0 ? scale : 1;
}
/* An override-redirect 1x1 window at a logical screen point, for menus that
   belong to a tray item rather than to a window. X11 only. */
static GtkWidget *anchor_window(int x, int y) {
#ifdef GDK_WINDOWING_X11
    if (!GDK_IS_X11_DISPLAY(gdk_display_get_default())) return NULL;
#endif
    GtkWidget *anchor = gtk_window_new(GTK_WINDOW_POPUP);
    g_object_ref_sink(anchor);
    gtk_window_set_default_size(GTK_WINDOW(anchor), 1, 1);
    gtk_widget_set_app_paintable(anchor, TRUE);
    gtk_window_move(GTK_WINDOW(anchor), x, y);
    gtk_widget_show(anchor);
    return anchor;
}

/* anchor: 0 pointer, 1 client logical point, 2 physical screen point.
   Without a window, only pointer and screen anchors apply. */
Link *zsl_popup_show(GtkWidget *window, const Item *items, uint32_t count, int anchor, double x, double y, void *owner, uint64_t serial, Done done, int *error) {
    *error = 0;
    GtkWidget *standalone = NULL;
    if (!window) {
        int scale = root_scale(), px = (int)(x / scale), py = (int)(y / scale);
        if (anchor == 0) {
            GdkSeat *seat = gdk_display_get_default_seat(gdk_display_get_default());
            GdkDevice *pointer = seat ? gdk_seat_get_pointer(seat) : NULL;
            if (!pointer) { *error = 1; return NULL; }
            gdk_device_get_position(pointer, NULL, &px, &py);
        }
        standalone = anchor == 1 ? NULL : anchor_window(px, py);
        if (!standalone) { *error = 1; return NULL; }
        anchor = 1;
        x = 0;
        y = 0;
    }
    GdkWindow *target = standalone ? gtk_widget_get_window(standalone) : window ? client_window(window) : NULL;
    if (!target || !gdk_window_is_viewable(target)) {
        if (standalone) { gtk_widget_destroy(standalone); g_object_unref(standalone); }
        *error = 1;
        return NULL;
    }
    GtkWidget *menus[128] = {0};
    GtkWidget *root = gtk_menu_new();
    g_object_ref_sink(root);
    Link *link = link_new(owner, serial, done);
    link->widget = root;
    link->anchor = standalone;
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

/* ---- menu bars ----
   Command items carry their index; activation and accelerators report from
   idle with the bar's serial, so a replaced bar never reaches a new command.
   Accelerators are display-only to GTK and matched after the window's focus
   widget leaves the key unconsumed. Check items are reverted after GTK's own
   toggle; the application owns the state through zsl_menubar_state. */

typedef struct Bar {
    int refs;
    void *owner;
    uint64_t serial;
    Done done;
    GtkWidget *widget, *toplevel;
    gulong key_handler;
    uint32_t count;
    GtkWidget *commands[128];
    uint32_t keyvals[128], modifiers[128];
    uint8_t enabled[128], checked[128];
} Bar;
typedef struct Activation { Bar *bar; int32_t command; } Activation;
static gint live_bars;

static void bar_release(Bar *bar) {
    if (--bar->refs) return;
    if (bar->toplevel) g_object_unref(bar->toplevel);
    if (bar->widget) g_object_unref(bar->widget);
    g_atomic_int_dec_and_test(&live_bars);
    g_free(bar);
}
static gboolean bar_report(gpointer data) {
    Activation *activation = data;
    Bar *bar = activation->bar;
    if (bar->owner) bar->done(bar->owner, bar->serial, activation->command);
    bar_release(bar);
    g_free(activation);
    return G_SOURCE_REMOVE;
}
static void bar_schedule(Bar *bar, int32_t command) {
    Activation *activation = g_new0(Activation, 1);
    activation->bar = bar;
    activation->command = command;
    ++bar->refs;
    g_idle_add_full(G_PRIORITY_DEFAULT, bar_report, activation, NULL);
}
static void bar_item_activated(GtkMenuItem *item, gpointer data) {
    Bar *bar = data;
    int32_t command = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(item), "ziggurat-command"));
    if (!bar->owner || command < 0 || (uint32_t)command >= bar->count) return;
    if (GTK_IS_CHECK_MENU_ITEM(item) && gtk_check_menu_item_get_active(GTK_CHECK_MENU_ITEM(item)) != (bar->checked[command] != 0)) {
        g_signal_handlers_block_by_func(item, bar_item_activated, bar);
        gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(item), bar->checked[command] != 0);
        g_signal_handlers_unblock_by_func(item, bar_item_activated, bar);
    }
    if (bar->enabled[command]) bar_schedule(bar, command);
}
static GtkWidget *bar_command_new(Bar *bar, const char *label, int32_t command, gboolean checked, gboolean sensitive) {
    GtkWidget *entry = checked ? gtk_check_menu_item_new_with_mnemonic(label) : gtk_menu_item_new_with_mnemonic(label);
    if (checked) gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(entry), TRUE);
    if (bar->keyvals[command]) {
        GtkWidget *child = gtk_bin_get_child(GTK_BIN(entry));
        if (GTK_IS_ACCEL_LABEL(child)) gtk_accel_label_set_accel(GTK_ACCEL_LABEL(child), bar->keyvals[command], bar->modifiers[command]);
    }
    gtk_widget_set_sensitive(entry, sensitive);
    g_object_set_data(G_OBJECT(entry), "ziggurat-command", GINT_TO_POINTER(command));
    g_signal_connect(entry, "activate", G_CALLBACK(bar_item_activated), bar);
    return entry;
}
static guint event_modifiers(GdkKeymap *map, GdkModifierType state) {
    GdkModifierType virtual_state = state;
    gdk_keymap_add_virtual_modifiers(map, &virtual_state);
    return (state & GDK_SHIFT_MASK) | (state & GDK_CONTROL_MASK) | (state & GDK_MOD1_MASK) | (virtual_state & GDK_SUPER_MASK);
}
static guint event_keyval(GdkKeymap *map, const GdkEventKey *event) {
    guint keyval = event->keyval, translated;
    if (event->hardware_keycode && gdk_keymap_translate_keyboard_state(map, event->hardware_keycode,
        event->state & ~(GDK_SHIFT_MASK | GDK_LOCK_MASK), event->group, &translated, NULL, NULL, NULL)) keyval = translated;
    keyval = gdk_keyval_to_lower(keyval);
    if (keyval == GDK_KEY_ISO_Left_Tab) keyval = GDK_KEY_Tab;
    if (keyval == GDK_KEY_KP_Enter) keyval = GDK_KEY_Return;
    return keyval;
}
static gboolean bar_key(GtkWidget *window, GdkEventKey *event, gpointer data) {
    Bar *bar = data;
    if (!bar->owner || event->type != GDK_KEY_PRESS || !gtk_widget_is_sensitive(window)) return FALSE;
    GdkKeymap *map = gdk_keymap_get_for_display(gtk_widget_get_display(window));
    guint keyval = event_keyval(map, event), modifiers = event_modifiers(map, event->state);
    for (uint32_t i = 0; i < bar->count; ++i) {
        if (!bar->keyvals[i] || bar->keyvals[i] != keyval || bar->modifiers[i] != modifiers) continue;
        if (!bar->enabled[i]) return FALSE;
        bar_schedule(bar, (int32_t)i);
        return TRUE;
    }
    return FALSE;
}
int zlg_window_set_menubar(GtkWidget *toplevel, GtkWidget *bar);

/* enabled[] is the effective state including ancestors; GTK sensitivity only
   follows each item's own flag. Returns NULL with error 1 for a closing
   window and 2 while its content is changing. */
Bar *zsl_menubar_set(GtkWidget *window, const Item *items, uint32_t count, const uint8_t *enabled, void *owner, uint64_t serial, Done done, int *error) {
    *error = 0;
    if (!window || !GTK_IS_WINDOW(window) || gtk_widget_in_destruction(window)) { *error = 1; return NULL; }
    Bar *bar = g_new0(Bar, 1);
    bar->refs = 1;
    bar->owner = owner;
    bar->serial = serial;
    bar->done = done;
    g_atomic_int_inc(&live_bars);
    GtkWidget *menus[128] = {0};
    GtkWidget *root = gtk_menu_bar_new();
    bar->widget = g_object_ref_sink(root);
    for (uint32_t i = 0; i < count && i < 128; ++i) {
        const Item *item = &items[i];
        GtkWidget *parent = item->parent >= 0 ? menus[item->parent] : root;
        GtkWidget *entry;
        if (item->kind == 2) entry = gtk_separator_menu_item_new();
        else if (item->kind == 1) {
            entry = gtk_menu_item_new_with_mnemonic(item->label);
            gtk_widget_set_sensitive(entry, item->enabled != 0);
            menus[i] = gtk_menu_new();
            gtk_menu_item_set_submenu(GTK_MENU_ITEM(entry), menus[i]);
        } else {
            int32_t command = item->command;
            bar->keyvals[command] = item->keyval;
            bar->modifiers[command] = item->modifiers;
            bar->enabled[command] = enabled[command];
            bar->checked[command] = item->checked;
            if ((uint32_t)command + 1 > bar->count) bar->count = (uint32_t)command + 1;
            entry = bar_command_new(bar, item->label, command, item->checked != 0, item->enabled != 0);
            bar->commands[command] = entry;
        }
        gtk_menu_shell_append(GTK_MENU_SHELL(parent), entry);
    }
    gtk_widget_show_all(root);
    int placed = zlg_window_set_menubar(window, root);
    if (placed) {
        *error = placed == 3 ? 2 : 1;
        bar->owner = NULL;
        gtk_widget_destroy(root);
        bar_release(bar);
        return NULL;
    }
    bar->toplevel = g_object_ref(window);
    bar->key_handler = g_signal_connect_after(window, "key-press-event", G_CALLBACK(bar_key), bar);
    return bar;
}
/* Rebuilds a command item when its check presence changes, in place. */
int zsl_menubar_state(Bar *bar, int32_t command, int enabled, int effective, int checked) {
    if (!bar->owner || command < 0 || (uint32_t)command >= bar->count || !bar->commands[command]) return 0;
    GtkWidget *entry = bar->commands[command];
    bar->enabled[command] = effective != 0;
    bar->checked[command] = checked != 0;
    if (GTK_IS_CHECK_MENU_ITEM(entry) != (checked != 0)) {
        GtkWidget *shell = gtk_widget_get_parent(entry);
        GList *children = gtk_container_get_children(GTK_CONTAINER(shell));
        gint position = g_list_index(children, entry);
        g_list_free(children);
        GtkWidget *child = gtk_bin_get_child(GTK_BIN(entry));
        gchar *label = g_strdup(GTK_IS_LABEL(child) ? gtk_label_get_label(GTK_LABEL(child)) : "");
        GtkWidget *replacement = bar_command_new(bar, label, command, checked != 0, enabled != 0);
        g_free(label);
        gtk_widget_destroy(entry);
        gtk_menu_shell_insert(GTK_MENU_SHELL(shell), replacement, position);
        gtk_widget_show(replacement);
        bar->commands[command] = replacement;
        return 1;
    }
    gtk_widget_set_sensitive(entry, enabled != 0);
    if (checked) {
        g_signal_handlers_block_by_func(entry, bar_item_activated, bar);
        gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(entry), TRUE);
        g_signal_handlers_unblock_by_func(entry, bar_item_activated, bar);
    }
    return 1;
}
/* Silent: removes the bar, restores the window's child when the window is
   still open, and cancels idle reports. */
void zsl_menubar_remove(Bar *bar, int restore) {
    bar->owner = NULL;
    if (bar->toplevel && bar->key_handler) g_signal_handler_disconnect(bar->toplevel, bar->key_handler);
    bar->key_handler = 0;
    if (restore && bar->toplevel) zlg_window_set_menubar(bar->toplevel, NULL);
    if (bar->widget) gtk_widget_destroy(bar->widget);
    bar_release(bar);
}
/* Native activation of the n-th command, as a click on the item would do. */
int zsl_menubar_activate(Bar *bar, int32_t command) {
    if (!bar->owner || command < 0 || (uint32_t)command >= bar->count || !bar->commands[command]) return 0;
    if (!gtk_widget_is_sensitive(bar->commands[command])) return 0;
    gtk_menu_item_activate(GTK_MENU_ITEM(bar->commands[command]));
    return 1;
}
int zsl_menubar_checked(Bar *bar, int32_t command) {
    if (command < 0 || (uint32_t)command >= bar->count || !GTK_IS_CHECK_MENU_ITEM(bar->commands[command])) return -1;
    return gtk_check_menu_item_get_active(GTK_CHECK_MENU_ITEM(bar->commands[command])) ? 1 : 0;
}
/* Test access: delivers a key press to the bar's window as GDK would. */
int zsl_menubar_key(Bar *bar, uint32_t keyval, uint32_t state) {
    if (!bar->toplevel || !gtk_widget_get_realized(bar->toplevel)) return 0;
    GdkEvent *event = gdk_event_new(GDK_KEY_PRESS);
    GdkKeymapKey *keys = NULL;
    gint count = 0;
    GdkDisplay *display = gtk_widget_get_display(bar->toplevel);
    event->key.window = g_object_ref(gtk_widget_get_window(bar->toplevel));
    event->key.send_event = TRUE;
    event->key.time = GDK_CURRENT_TIME;
    event->key.keyval = keyval;
    event->key.state = state;
    if (gdk_keymap_get_entries_for_keyval(gdk_keymap_get_for_display(display), keyval, &keys, &count) && count) {
        event->key.hardware_keycode = (guint16)keys[0].keycode;
        event->key.group = (guint8)keys[0].group;
    }
    g_free(keys);
    GdkSeat *seat = gdk_display_get_default_seat(display);
    if (seat) gdk_event_set_device(event, gdk_seat_get_keyboard(seat));
    gtk_main_do_event(event);
    gdk_event_free(event);
    return 1;
}
/* The bar's height in logical pixels, for checks that content moved below it. */
int zsl_menubar_height(Bar *bar) { return bar->widget ? gtk_widget_get_allocated_height(bar->widget) : 0; }

/* ---- file choosers ----
   GtkFileChooserNative uses the desktop portal when one applies and GTK's own
   dialog otherwise; both report through "response". Selected paths are kept
   here until the Zig completion copies them. Results: n >= 0 paths, -1
   cancelled, -3 a selection without a local path, -4 a path that is not
   UTF-8, -5 more than 128 paths. */

typedef struct Chooser {
    int refs;
    void *owner;
    uint64_t serial;
    Done done;
    GtkFileChooserNative *dialog;
    gchar *paths[128];
    uint32_t count;
    int32_t result;
    gboolean reported;
} Chooser;
static gint live_choosers;

static void chooser_clear(Chooser *chooser) {
    for (uint32_t i = 0; i < chooser->count; ++i) g_free(chooser->paths[i]);
    chooser->count = 0;
}
static void chooser_close(Chooser *chooser) {
    GtkFileChooserNative *dialog = chooser->dialog;
    chooser->dialog = NULL;
    if (!dialog) return;
    g_signal_handlers_disconnect_by_data(dialog, chooser);
    gtk_native_dialog_destroy(GTK_NATIVE_DIALOG(dialog));
    g_object_unref(dialog);
}
static void chooser_release(Chooser *chooser) {
    if (--chooser->refs) return;
    chooser_close(chooser);
    chooser_clear(chooser);
    g_atomic_int_dec_and_test(&live_choosers);
    g_free(chooser);
}
static gboolean chooser_report(gpointer data) {
    Chooser *chooser = data;
    void *owner = chooser->owner;
    chooser->owner = NULL;
    if (owner) chooser->done(owner, chooser->serial, chooser->result);
    chooser_close(chooser);
    chooser_release(chooser);
    return G_SOURCE_REMOVE;
}
static void chooser_schedule(Chooser *chooser, int32_t result) {
    if (chooser->reported) return;
    chooser->reported = TRUE;
    chooser->result = result;
    ++chooser->refs;
    g_idle_add_full(G_PRIORITY_DEFAULT, chooser_report, chooser, NULL);
}
static int32_t chooser_collect(Chooser *chooser) {
    GSList *files = gtk_file_chooser_get_files(GTK_FILE_CHOOSER(chooser->dialog));
    int32_t result = 0;
    for (GSList *cursor = files; cursor && result >= 0; cursor = cursor->next) {
        if (chooser->count == 128) { result = -5; break; }
        gchar *path = g_file_get_path(cursor->data);
        if (!path) { result = -3; break; }
        gchar *text = g_filename_to_utf8(path, -1, NULL, NULL, NULL);
        g_free(path);
        if (!text) { result = -4; break; }
        chooser->paths[chooser->count++] = text;
    }
    g_slist_free_full(files, g_object_unref);
    if (result < 0) chooser_clear(chooser);
    else if (chooser->count == 0) result = -1;
    else result = (int32_t)chooser->count;
    return result;
}
static void chooser_response(GtkNativeDialog *dialog, gint response, gpointer data) {
    (void)dialog;
    Chooser *chooser = data;
    if (chooser->reported) return;
    chooser_schedule(chooser, response == GTK_RESPONSE_ACCEPT ? chooser_collect(chooser) : -1);
}
static void add_pattern(GtkFileFilter *filter, const char *extension) {
    GString *pattern = g_string_new("*");
    for (const char *cursor = extension; *cursor; ++cursor) {
        gunichar lower = g_unichar_tolower(g_utf8_get_char(cursor)), upper = g_unichar_toupper(g_utf8_get_char(cursor));
        const char *next = g_utf8_next_char(cursor);
        if (lower == upper) g_string_append_len(pattern, cursor, next - cursor);
        else { g_string_append_c(pattern, '['); g_string_append_unichar(pattern, lower); g_string_append_unichar(pattern, upper); g_string_append_c(pattern, ']'); }
        cursor = next - 1;
    }
    gtk_file_filter_add_pattern(filter, pattern->str);
    g_string_free(pattern, TRUE);
}

/* kind: 0 open one file, 1 save, 2 open several files, 3 folder. Extensions
   are "*" or ".ext"; saving offers one filter per extension. */
Chooser *zsl_chooser_show(GtkWidget *window, int kind, const char *const *extensions, uint32_t count, const char *suggested_name, void *owner, uint64_t serial, Done done, int *error) {
    *error = 0;
    if (!window || !GTK_IS_WINDOW(window) || gtk_widget_in_destruction(window)) { *error = 1; return NULL; }
    static const GtkFileChooserAction actions[] = {GTK_FILE_CHOOSER_ACTION_OPEN, GTK_FILE_CHOOSER_ACTION_SAVE, GTK_FILE_CHOOSER_ACTION_OPEN, GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER};
    GtkFileChooserNative *dialog = gtk_file_chooser_native_new(NULL, GTK_WINDOW(window), actions[kind & 3], NULL, NULL);
    if (!dialog) { *error = 2; return NULL; }
    GtkFileChooser *chooser_view = GTK_FILE_CHOOSER(dialog);
    gtk_native_dialog_set_modal(GTK_NATIVE_DIALOG(dialog), TRUE);
    gtk_file_chooser_set_local_only(chooser_view, TRUE);
    gtk_file_chooser_set_select_multiple(chooser_view, kind == 2);
    gboolean every = FALSE;
    for (uint32_t i = 0; i < count; ++i) if (strcmp(extensions[i], "*") == 0) every = TRUE;
    if (kind == 1) {
        gtk_file_chooser_set_do_overwrite_confirmation(chooser_view, TRUE);
        gboolean listed = FALSE;
        for (uint32_t i = 0; i < count; ++i) {
            GtkFileFilter *filter = gtk_file_filter_new();
            gtk_file_filter_set_name(filter, extensions[i]);
            add_pattern(filter, extensions[i]);
            gtk_file_chooser_add_filter(chooser_view, filter);
            if (g_str_has_suffix(suggested_name, extensions[i])) listed = TRUE;
        }
        gchar *name = listed || count == 0 ? g_strdup(suggested_name) : g_strconcat(suggested_name, extensions[0], NULL);
        gtk_file_chooser_set_current_name(chooser_view, name);
        g_free(name);
    } else if (kind != 3 && !every && count) {
        GtkFileFilter *filter = gtk_file_filter_new();
        GString *name = g_string_new(NULL);
        for (uint32_t i = 0; i < count; ++i) {
            if (i) g_string_append(name, ", ");
            g_string_append_c(name, '*');
            g_string_append(name, extensions[i]);
            add_pattern(filter, extensions[i]);
        }
        gtk_file_filter_set_name(filter, name->str);
        g_string_free(name, TRUE);
        gtk_file_chooser_add_filter(chooser_view, filter);
    }
    Chooser *chooser = g_new0(Chooser, 1);
    chooser->refs = 1;
    chooser->owner = owner;
    chooser->serial = serial;
    chooser->done = done;
    chooser->dialog = dialog;
    chooser->result = -1;
    g_atomic_int_inc(&live_choosers);
    g_signal_connect(dialog, "response", G_CALLBACK(chooser_response), chooser);
    gtk_native_dialog_show(GTK_NATIVE_DIALOG(dialog));
    return chooser;
}
void zsl_chooser_path(Chooser *chooser, uint32_t index, const char **path, size_t *length) {
    *path = index < chooser->count ? chooser->paths[index] : NULL;
    *length = *path ? strlen(*path) : 0;
}
/* Hides the dialog; completion still reports cancellation through Done. */
void zsl_chooser_cancel(Chooser *chooser) {
    if (chooser->reported) return;
    if (chooser->dialog) gtk_native_dialog_hide(GTK_NATIVE_DIALOG(chooser->dialog));
    chooser_schedule(chooser, -1);
}
/* Silent: no Done call follows. */
void zsl_chooser_detach(Chooser *chooser) {
    chooser->owner = NULL;
    chooser->reported = TRUE;
    chooser_close(chooser);
    chooser_release(chooser);
}
/* Test access: chooses paths as the user would. Saving takes a folder and a
   name. Folder loading is asynchronous, so zsl_chooser_accept answers only
   once the chooser reports the expected number of files. */
int zsl_chooser_select(Chooser *chooser, const char *const *paths, uint32_t count, const char *save_name) {
    if (!chooser->dialog || chooser->reported) return 0;
    GtkFileChooser *view = GTK_FILE_CHOOSER(chooser->dialog);
    if (save_name) {
        gtk_file_chooser_set_current_folder(view, paths[0]);
        gtk_file_chooser_set_current_name(view, save_name);
        return 1;
    }
    gtk_file_chooser_unselect_all(view);
    for (uint32_t i = 0; i < count; ++i) {
        GFile *file = g_file_new_for_path(paths[i]);
        gtk_file_chooser_select_file(view, file, NULL);
        g_object_unref(file);
    }
    return 1;
}
/* Test access: completes with paths as the dialog's accept would have
   collected them. GTK's own chooser offers no scripted multiple selection. */
int zsl_chooser_complete(Chooser *chooser, const char *const *paths, uint32_t count) {
    if (!chooser->dialog || chooser->reported || count > 128) return 0;
    for (uint32_t i = 0; i < count; ++i) chooser->paths[chooser->count++] = g_strdup(paths[i]);
    gtk_native_dialog_hide(GTK_NATIVE_DIALOG(chooser->dialog));
    chooser_schedule(chooser, count ? (int32_t)count : -1);
    return 1;
}
int zsl_chooser_accept(Chooser *chooser, uint32_t expected, const char *first) {
    if (!chooser->dialog || chooser->reported) return 0;
    if (expected) {
        GSList *files = gtk_file_chooser_get_files(GTK_FILE_CHOOSER(chooser->dialog));
        guint count = g_slist_length(files);
        gchar *path = files ? g_file_get_path(files->data) : NULL;
        gboolean matches = count == expected && (!first || g_strcmp0(path, first) == 0);
        g_free(path);
        g_slist_free_full(files, g_object_unref);
        if (!matches) return 0;
    }
    g_signal_emit_by_name(chooser->dialog, "response", expected ? GTK_RESPONSE_ACCEPT : GTK_RESPONSE_CANCEL);
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
int zsl_live_links(void) { return g_atomic_int_get(&live_links) + g_atomic_int_get(&live_bars) + g_atomic_int_get(&live_choosers); }
