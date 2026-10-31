#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

/* What the page of a window's WebKitWebView does with a swipe and a pinch:
   its back-forward gestures setting, and whether its zoom gesture takes
   events. */
static GtkWidget *find_view(GtkWidget *widget) {
    if (WEBKIT_IS_WEB_VIEW(widget)) return widget;
    if (!GTK_IS_CONTAINER(widget)) return NULL;
    GList *children=gtk_container_get_children(GTK_CONTAINER(widget));
    GtkWidget *found=NULL;
    for (GList *item=children;item && !found;item=item->next) found=find_view(item->data);
    g_list_free(children);
    return found;
}
int zpo_gestures(void *window,int *swipe,int *pinch) {
    GtkWidget *view=find_view(GTK_WIDGET(window));
    if (!view) return 0;
    *swipe=webkit_settings_get_enable_back_forward_navigation_gestures(webkit_web_view_get_settings(WEBKIT_WEB_VIEW(view)))?1:0;
    GtkEventController *zoom=g_object_get_data(G_OBJECT(view),"wk-view-zoom-gesture");
    if (!GTK_IS_EVENT_CONTROLLER(zoom)) return 0;
    *pinch=gtk_event_controller_get_propagation_phase(zoom)!=GTK_PHASE_NONE?1:0;
    return 1;
}
