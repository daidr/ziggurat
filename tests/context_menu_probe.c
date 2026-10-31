#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#include <string.h>

/* Drives a page's context menu as a user would, and reads the menu the View
   made of WebKitGTK's before it would pop up: a handler connected after the
   View's sees it, chooses the app's item by its action, and shows nothing. */
typedef struct Probe { int menus, copy_link, open_link, app_items, activated, items; } Probe;
static Probe probe;

static GtkWidget *find_view(GtkWidget *widget) {
    if (WEBKIT_IS_WEB_VIEW(widget)) return widget;
    if (!GTK_IS_CONTAINER(widget)) return NULL;
    GList *children=gtk_container_get_children(GTK_CONTAINER(widget));
    GtkWidget *found=NULL;
    for (GList *item=children;item && !found;item=item->next) found=find_view(item->data);
    g_list_free(children);
    return found;
}
static gboolean shown(WebKitWebView *view,WebKitContextMenu *menu,GdkEvent *event,WebKitHitTestResult *hit,gpointer data) {
    (void)view; (void)event; (void)hit; (void)data;
    probe.menus++;
    probe.copy_link=probe.open_link=probe.app_items=0;
    probe.items=(int)webkit_context_menu_get_n_items(menu);
    for (GList *link=webkit_context_menu_get_items(menu);link;link=link->next) {
        WebKitContextMenuItem *item=link->data;
        const WebKitContextMenuAction action=webkit_context_menu_item_get_stock_action(item);
        if (action==WEBKIT_CONTEXT_MENU_ACTION_COPY_LINK_TO_CLIPBOARD) probe.copy_link++;
        if (action==WEBKIT_CONTEXT_MENU_ACTION_OPEN_LINK) probe.open_link++;
        GAction *gaction=webkit_context_menu_item_get_gaction(item);
        if (gaction && g_str_has_prefix(g_action_get_name(gaction),"ziggurat-")) {
            probe.app_items++;
            if (g_action_get_enabled(gaction) && !probe.activated) { probe.activated++; g_action_activate(gaction,NULL); }
        }
    }
    return TRUE;
}
int zcm_watch(void *window) {
    GtkWidget *view=find_view(GTK_WIDGET(window));
    if (!view) return 0;
    memset(&probe,0,sizeof(probe));
    g_signal_connect_after(view,"context-menu",G_CALLBACK(shown),NULL);
    return 1;
}
/* A press of the secondary button at x, y of the page, which opens the menu. */
int zcm_right_click(void *window,int x,int y) {
    GtkWidget *view=find_view(GTK_WIDGET(window));
    GdkWindow *target=view?gtk_widget_get_window(view):NULL;
    if (!target) return 0;
    GdkSeat *seat=gdk_display_get_default_seat(gtk_widget_get_display(view));
    for (int release=0;release<2;release++) {
        GdkEvent *event=gdk_event_new(release?GDK_BUTTON_RELEASE:GDK_BUTTON_PRESS);
        event->button.window=g_object_ref(target);
        event->button.send_event=TRUE;
        event->button.time=GDK_CURRENT_TIME;
        event->button.x=x; event->button.y=y;
        event->button.button=3;
        if (release) event->button.state=GDK_BUTTON3_MASK;
        if (seat) gdk_event_set_device(event,gdk_seat_get_pointer(seat));
        gtk_widget_event(view,event);
        gdk_event_free(event);
    }
    return 1;
}
/* The menu key: WebKitGTK opens the menu of the focus or the selection. */
int zcm_menu_key(void *window) {
    GtkWidget *view=find_view(GTK_WIDGET(window));
    if (!view) return 0;
    gboolean handled=FALSE;
    g_signal_emit_by_name(view,"popup-menu",&handled);
    return handled?1:0;
}
void zcm_result(int *menus,int *items,int *open_link,int *copy_link,int *app_items,int *activated) {
    *menus=probe.menus; *items=probe.items; *open_link=probe.open_link; *copy_link=probe.copy_link; *app_items=probe.app_items; *activated=probe.activated;
}
