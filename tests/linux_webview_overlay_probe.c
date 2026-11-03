#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

/* The overlay holding the window's web views, and its web view and area. */
static GtkWidget *overlay_of(void *window, GtkWidget **web, GtkWidget **area) {
    GtkWidget *root=gtk_bin_get_child(GTK_BIN(window));
    if (!root || !GTK_IS_OVERLAY(root)) return NULL;
    GList *children=gtk_container_get_children(GTK_CONTAINER(root));
    for (GList *item=children;item;item=item->next) {
        if (WEBKIT_IS_WEB_VIEW(item->data)) { if (web) *web=item->data; }
        else if (GTK_IS_DRAWING_AREA(item->data)) { if (area) *area=item->data; }
    }
    g_list_free(children);
    return root;
}

/* Whether the native UI shows and takes the pointer at x, y of the area
 * (logical pixels), rather than the page under it: -1 without web views. */
int zwo_content_at(void *window, int x, int y) {
    GtkWidget *overlay=overlay_of(window,NULL,NULL);
    if (!overlay) return -1;
    cairo_region_t *shape=g_object_get_data(G_OBJECT(overlay),"ziggurat-region-shape");
    return shape?cairo_region_contains_point(shape,x,y):1;
}

/* Whether the web view has the keyboard. */
int zwo_page_focused(void *window) {
    GtkWidget *focus=gtk_window_get_focus(GTK_WINDOW(window));
    return focus && WEBKIT_IS_WEB_VIEW(focus);
}

/* Press and release keyval (Tab, or Shift+Tab with shift) in the window, as
 * the keyboard does: the window gives it to its focus. */
int zwo_key(void *window, unsigned keyval, int shift) {
    GdkWindow *target=gtk_widget_get_window(GTK_WIDGET(window));
    if (!target) return 0;
    GdkDisplay *display=gdk_window_get_display(target);
    GdkKeymapKey *keys=NULL; gint count=0;
    guint16 code=0;
    if (gdk_keymap_get_entries_for_keyval(gdk_keymap_get_for_display(display),GDK_KEY_Tab,&keys,&count) && count>0) code=(guint16)keys[0].keycode;
    g_free(keys);
    GdkSeat *seat=gdk_display_get_default_seat(display);
    for (int i=0;i<2;i++) {
        GdkEvent *event=gdk_event_new(i==0?GDK_KEY_PRESS:GDK_KEY_RELEASE);
        event->key.window=g_object_ref(target);
        event->key.send_event=TRUE;
        event->key.time=GDK_CURRENT_TIME;
        event->key.keyval=shift && keyval==GDK_KEY_Tab?GDK_KEY_ISO_Left_Tab:keyval;
        event->key.state=shift?GDK_SHIFT_MASK:0;
        event->key.hardware_keycode=code;
        event->key.is_modifier=FALSE;
        if (seat) gdk_event_set_device(event,gdk_seat_get_keyboard(seat));
        gtk_main_do_event(event);
        gdk_event_free(event);
    }
    return 1;
}

/* Whether assistive technology finds the page inside the native UI's tree:
 * the web view's accessible, an AtkSocket, has a parent of the area's tree
 * and not the overlay, which lists the area alone. */
int zwo_page_in_tree(void *window) {
    GtkWidget *web=NULL, *area=NULL;
    GtkWidget *overlay=overlay_of(window,&web,&area);
    if (!overlay || !web || !area) return -1;
    AtkObject *page=gtk_widget_get_accessible(web), *top=gtk_widget_get_accessible(area), *holder=gtk_widget_get_accessible(overlay);
    if (!page || !ATK_IS_SOCKET(page)) return -2;
    if (atk_object_get_n_accessible_children(holder)!=1) return -3;
    AtkObject *parent=atk_object_get_parent(page);
    if (!parent || parent==holder) return 0;
    /* The node holds the page as its child. */
    int found=0;
    for (int i=0;i<atk_object_get_n_accessible_children(parent);i++) {
        AtkObject *child=atk_object_ref_accessible_child(parent,i);
        if (child==page) found=1;
        if (child) g_object_unref(child);
    }
    if (!found) return -4;
    for (AtkObject *up=parent;up;up=atk_object_get_parent(up)) if (up==top) return 1;
    return -5;
}
#include <gdk/gdkx.h>
/* Make the window the active one, as a window manager does when it is
 * clicked: Xvfb runs none. Returns whether GTK sees it active. */
int zwo_activate(void *window) {
    GdkWindow *target=gtk_widget_get_window(GTK_WIDGET(window));
    if (!target || !gdk_window_is_viewable(target)) return 0;
    if (gtk_window_is_active(GTK_WINDOW(window))) return 1;
    if (GDK_IS_X11_WINDOW(target)) XSetInputFocus(GDK_WINDOW_XDISPLAY(target),GDK_WINDOW_XID(target),RevertToParent,CurrentTime);
    return gtk_window_is_active(GTK_WINDOW(window));
}
