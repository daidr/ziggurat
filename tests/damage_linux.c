#include <gtk/gtk.h>

void zlg_damage_clear(void *window) {
    GtkWidget *area=gtk_bin_get_child(GTK_BIN(window));
    gtk_window_move(GTK_WINDOW(window),-16000,-16000);
    gtk_widget_show_all(GTK_WIDGET(window));
    GdkWindow *native=gtk_widget_get_window(area);
    gdk_window_process_updates(native,TRUE);
    cairo_region_t *old=gdk_window_get_update_area(native);
    if (old) cairo_region_destroy(old);
}
int zlg_damage_read(void *window, int *bounds) {
    GtkWidget *area=gtk_bin_get_child(GTK_BIN(window));
    cairo_region_t *region=gdk_window_get_update_area(gtk_widget_get_window(area));
    if (!region) return 0;
    cairo_rectangle_int_t rect;
    cairo_region_get_extents(region,&rect);
    bounds[0]=rect.x; bounds[1]=rect.y; bounds[2]=rect.x+rect.width; bounds[3]=rect.y+rect.height;
    cairo_region_destroy(region);
    return 1;
}
