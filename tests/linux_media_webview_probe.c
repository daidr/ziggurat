#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

static void find(GtkWidget *widget, gpointer data) {
    WebKitWebView **out=data;
    if (*out) return;
    if (WEBKIT_IS_WEB_VIEW(widget)) { *out=WEBKIT_WEB_VIEW(widget); return; }
    if (GTK_IS_CONTAINER(widget)) gtk_container_forall(GTK_CONTAINER(widget),find,data);
}
/* Give the window's web view WebKit's mock camera and microphone, so
 * getUserMedia works without devices. Returns 0 without a web view. */
int zwm_mock_devices(void *window) {
    WebKitWebView *view=NULL;
    find(GTK_WIDGET(window),&view);
    if (!view) return 0;
    webkit_settings_set_enable_mock_capture_devices(webkit_web_view_get_settings(view),TRUE);
    return 1;
}
