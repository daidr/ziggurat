#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#include <string.h>
#include <stdio.h>

int zrr_identify(void *window, const char *identifier) {
    GtkWidget *root=gtk_bin_get_child(GTK_BIN(window));
    if (!root || !GTK_IS_OVERLAY(root)) return 0;
    GList *children=gtk_container_get_children(GTK_CONTAINER(root));
    GtkWidget *candidate=NULL;
    unsigned count=0;
    for (GList *item=children;item;item=item->next) if (WEBKIT_IS_WEB_VIEW(item->data) &&
        !g_object_get_data(G_OBJECT(item->data),"ziggurat-test-region-id")) { candidate=item->data; ++count; }
    if (count==1) g_object_set_data(G_OBJECT(candidate),"ziggurat-test-region-id",(gpointer)identifier);
    g_list_free(children); return count==1;
}

int zrr_layout(void *window, int width, int height) {
    GtkWidget *root=gtk_bin_get_child(GTK_BIN(window));
    if (!root || !GTK_IS_OVERLAY(root)) return 0;
    GtkAllocation allocation={0,0,width,height};
    gtk_widget_size_allocate(root,&allocation);
    return 1;
}
int zrr_bounds(void *window, const char *title, int x, int y, int width, int height, int visible) {
    GtkWidget *root=gtk_bin_get_child(GTK_BIN(window));
    if (!root || !GTK_IS_OVERLAY(root)) return 0;
    GList *children=gtk_container_get_children(GTK_CONTAINER(root));
    int found=0;
    for (GList *item=children;item;item=item->next) if (WEBKIT_IS_WEB_VIEW(item->data)) {
        GtkWidget *child=item->data;
        const char *actual_title=g_object_get_data(G_OBJECT(child),"ziggurat-test-region-id");
        if (!actual_title || strcmp(actual_title,title)) continue;
        if (gtk_widget_get_visible(child)!=(visible!=0)) break;
        if (!visible) { found=1; break; }
        int actual_x=0,actual_y=0;
        GtkAllocation allocation; gtk_widget_get_allocation(child,&allocation);
        if (gtk_widget_translate_coordinates(child,root,0,0,&actual_x,&actual_y) &&
            actual_x==x && actual_y==y && allocation.width==width && allocation.height==height) found=1;
        if (!found) fprintf(stderr,"region %s actual=%d,%d %dx%d expected=%d,%d %dx%d\n",title,actual_x,actual_y,allocation.width,allocation.height,x,y,width,height);
        break;
    }
    g_list_free(children); return found;
}
