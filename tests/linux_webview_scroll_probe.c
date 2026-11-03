#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

/* Scroll the window's only web view by dy lines of a smooth scroll at
 * (x, y) in it, as a touchpad does, through GTK's event path. Returns 0
 * without a realized web view. */
int zws_scroll(void *window, double x, double y, double dy) {
    GtkWidget *root=gtk_bin_get_child(GTK_BIN(window));
    if (!root || !GTK_IS_OVERLAY(root)) return 0;
    GList *children=gtk_container_get_children(GTK_CONTAINER(root));
    GtkWidget *web=NULL;
    for (GList *item=children;item;item=item->next) if (WEBKIT_IS_WEB_VIEW(item->data)) web=item->data;
    g_list_free(children);
    GdkWindow *target=web?gtk_widget_get_window(web):NULL;
    if (!target || !gtk_widget_get_mapped(web)) return 0;
    gint ox=0, oy=0;
    gdk_window_get_origin(target,&ox,&oy);
    GdkEvent *event=gdk_event_new(GDK_SCROLL);
    event->scroll.window=g_object_ref(target);
    event->scroll.send_event=TRUE;
    event->scroll.time=GDK_CURRENT_TIME;
    event->scroll.x=x; event->scroll.y=y;
    event->scroll.x_root=ox+x; event->scroll.y_root=oy+y;
    event->scroll.direction=GDK_SCROLL_SMOOTH;
    event->scroll.delta_x=0; event->scroll.delta_y=dy;
    GdkSeat *seat=gdk_display_get_default_seat(gdk_window_get_display(target));
    if (seat) gdk_event_set_device(event,gdk_seat_get_pointer(seat));
    gtk_widget_event(web,event);
    gdk_event_free(event);
    return 1;
}

/* Press and release keyval in the window, through GTK's event path, as the
 * keyboard does: the window gives it to its focus, the web view, which has
 * its page handle it. Returns 0 without a web view that has the focus. */
int zws_key(void *window, unsigned keyval) {
    GtkWidget *focus=gtk_window_get_focus(GTK_WINDOW(window));
    GdkWindow *target=gtk_widget_get_window(GTK_WIDGET(window));
    if (!focus || !WEBKIT_IS_WEB_VIEW(focus) || !target) return 0;
    GdkDisplay *display=gdk_window_get_display(target);
    GdkKeymapKey *keys=NULL; gint count=0;
    guint16 code=0;
    if (gdk_keymap_get_entries_for_keyval(gdk_keymap_get_for_display(display),keyval,&keys,&count) && count>0) code=(guint16)keys[0].keycode;
    g_free(keys);
    GdkSeat *seat=gdk_display_get_default_seat(display);
    for (int i=0;i<2;i++) {
        GdkEvent *event=gdk_event_new(i==0?GDK_KEY_PRESS:GDK_KEY_RELEASE);
        event->key.window=g_object_ref(target);
        event->key.send_event=TRUE;
        event->key.time=GDK_CURRENT_TIME;
        event->key.keyval=keyval;
        event->key.hardware_keycode=code;
        event->key.is_modifier=FALSE;
        if (seat) gdk_event_set_device(event,gdk_seat_get_keyboard(seat));
        gtk_main_do_event(event);
        gdk_event_free(event);
    }
    return 1;
}

/* Give the window's only web view the keyboard, as a click on it does. */
int zws_focus(void *window) {
    GtkWidget *root=gtk_bin_get_child(GTK_BIN(window));
    if (!root || !GTK_IS_OVERLAY(root)) return 0;
    GList *children=gtk_container_get_children(GTK_CONTAINER(root));
    GtkWidget *web=NULL;
    for (GList *item=children;item;item=item->next) if (WEBKIT_IS_WEB_VIEW(item->data)) web=item->data;
    g_list_free(children);
    if (!web) return 0;
    gtk_widget_grab_focus(web);
    return gtk_window_get_focus(GTK_WINDOW(window))==web;
}
