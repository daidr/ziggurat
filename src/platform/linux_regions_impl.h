#ifndef ZIGGURAT_LINUX_REGIONS_IMPL_H
#define ZIGGURAT_LINUX_REGIONS_IMPL_H

struct ZlgRegionLayer {
    NativeWindow *window;
    GtkWidget *overlay;
    ZlgRegionHost *first;
    unsigned refs;
    gulong position_handler;
    gboolean restored;
};
struct ZlgRegionHost {
    ZlgRegionLayer *layer;
    GtkWidget *child;
    ZlgRegionHost *previous, *next;
    unsigned refs;
    gulong destroy_handler;
    int x, y, width, height;
    gboolean visible, closed, child_destroyed;
};
static gint region_resources;
unsigned zlg_region_count(void) { return (unsigned)g_atomic_int_get(&region_resources); }
#ifndef ZLG_REGION_LAYER_ALLOC
#define ZLG_REGION_LAYER_ALLOC() g_try_new0(ZlgRegionLayer,1)
#endif
#ifndef ZLG_REGION_HOST_ALLOC
#define ZLG_REGION_HOST_ALLOC() g_try_new0(ZlgRegionHost,1)
#endif

static void region_layer_retain(ZlgRegionLayer *layer) { ++layer->refs; }
static void region_layer_release(ZlgRegionLayer *layer) {
    if (--layer->refs) return;
    NativeWindow *s=layer->window;
    if (g_signal_handler_is_connected(layer->overlay,layer->position_handler))
        g_signal_handler_disconnect(layer->overlay,layer->position_handler);
    gtk_widget_destroy(layer->overlay);
    g_object_unref(layer->overlay);
    g_free(layer);
    g_atomic_int_add(&region_resources,-1);
    release(s);
}
static void region_retain(ZlgRegionHost *host) { ++host->refs; }
static void region_release(ZlgRegionHost *host) {
    if (--host->refs) return;
    ZlgRegionLayer *layer=host->layer;
    if (g_signal_handler_is_connected(host->child,host->destroy_handler))
        g_signal_handler_disconnect(host->child,host->destroy_handler);
    g_object_unref(host->child);
    g_free(host);
    g_atomic_int_add(&region_resources,-1);
    region_layer_release(layer);
}
static void region_child_destroyed(GtkWidget *unused, gpointer data) {
    (void)unused;
    ((ZlgRegionHost *)data)->child_destroyed=TRUE;
}
static gboolean region_live(ZlgRegionHost *host) {
    return !host->closed && !host->child_destroyed && content_live(host->layer->window);
}
static gboolean region_position(GtkOverlay *overlay, GtkWidget *child, GdkRectangle *allocation, gpointer data) {
    (void)overlay;
    ZlgRegionLayer *layer=data;
    for (ZlgRegionHost *host=layer->first;host;host=host->next) if (host->child==child) {
        allocation->x=host->x; allocation->y=host->y;
        allocation->width=MAX(1,host->width); allocation->height=MAX(1,host->height);
        return TRUE;
    }
    return FALSE;
}
static void region_restore(ZlgRegionLayer *layer) {
    if (layer->restored) return;
    layer->restored=TRUE;
    NativeWindow *s=layer->window;
    if (s->regions==layer) s->regions=NULL;
    if (!content_live(s)) return;
    content_remove(s->area,layer->overlay);
    if (!content_live(s)) return;
    content_remove(layer->overlay,GTK_WIDGET(root_container(s)));
    if (!content_live(s)) return;
    if (!gtk_widget_get_parent(s->area)) root_add(s,s->area);
    if (!content_live(s)) return;
    gtk_widget_show(s->area);
    if (!content_live(s)) return;
    gtk_widget_realize(s->area);
    if (!content_live(s)) return;
    content_bind_im(s);
}
static ZlgRegionLayer *region_layer_create(NativeWindow *s) {
    ZlgRegionLayer *layer=ZLG_REGION_LAYER_ALLOC();
    if (!layer) return NULL;
    layer->refs=1; layer->window=s; retain(s);
    g_atomic_int_inc(&region_resources);
    layer->overlay=gtk_overlay_new(); g_object_ref_sink(layer->overlay); track(G_OBJECT(layer->overlay));
    layer->position_handler=g_signal_connect(layer->overlay,"get-child-position",G_CALLBACK(region_position),layer);
    s->regions=layer;
    content_cancel_input(s);
    if (!content_live(s)) goto closed;
    gtk_container_remove(root_container(s),s->area);
    if (!content_live(s)) goto closed;
    root_add(s,layer->overlay);
    if (!content_live(s)) goto closed;
    gtk_container_add(GTK_CONTAINER(layer->overlay),s->area);
    if (!content_live(s)) goto closed;
    gtk_widget_show(layer->overlay);
    if (!content_live(s)) goto closed;
    gtk_widget_realize(s->area);
    if (!content_live(s)) goto closed;
    content_bind_im(s);
    if (!content_live(s)) goto closed;
    return layer;
closed:
    region_restore(layer);
    region_layer_release(layer);
    return NULL;
}
int zlg_region_prepare(NativeWindow *s, void *widget, ZlgRegionHost **out) {
    *out=NULL;
    if (!content_live(s)) return ZLG_CONTENT_CLOSED;
    if (s->content || s->content_busy) return ZLG_CONTENT_BUSY;
    GtkWidget *child=widget;
    if (!GTK_IS_WIDGET(child) || g_object_is_floating(child) || child==s->area || child==s->window ||
        gtk_widget_get_parent(child) || gtk_widget_in_destruction(child)) return ZLG_CONTENT_INVALID;
    ZlgRegionHost *host=ZLG_REGION_HOST_ALLOC();
    if (!host) return ZLG_CONTENT_OOM;
    /* This pin also covers a failed first layer creation and its callbacks. */
    retain(s); s->content_busy=TRUE;
    ZlgRegionLayer *layer=s->regions;
    if (layer) region_layer_retain(layer);
    else layer=region_layer_create(s);
    if (!layer) {
        int result=content_live(s)?ZLG_CONTENT_OOM:ZLG_CONTENT_CLOSED;
        s->content_busy=FALSE; g_free(host); release(s); return result;
    }
    /* Owner and this attach invocation each hold a physical pin. */
    host->refs=2; host->layer=layer; host->child=g_object_ref(child);
    g_atomic_int_inc(&region_resources);
    host->destroy_handler=g_signal_connect(child,"destroy",G_CALLBACK(region_child_destroyed),host);
    host->next=layer->first;
    if (host->next) host->next->previous=host;
    layer->first=host;
    gtk_widget_set_no_show_all(child,TRUE);
    if (!region_live(host)) goto closed;
    gtk_widget_hide(child);
    if (!region_live(host)) goto closed;
    s->content_busy=FALSE;
    *out=host;
    region_release(host); release(s);
    return ZLG_CONTENT_OK;
closed:
    zlg_region_detach(host);
    s->content_busy=FALSE;
    region_release(host); release(s);
    return ZLG_CONTENT_CLOSED;
}
int zlg_region_mount(ZlgRegionHost *host) {
    if (!region_live(host)) return ZLG_CONTENT_CLOSED;
    NativeWindow *s=host->layer->window;
    if (s->content_busy) return ZLG_CONTENT_BUSY;
    GtkWidget *parent=gtk_widget_get_parent(host->child);
    if (parent==host->layer->overlay) return ZLG_CONTENT_OK;
    if (parent) return ZLG_CONTENT_INVALID;
    region_retain(host); s->content_busy=TRUE;
    gtk_overlay_add_overlay(GTK_OVERLAY(host->layer->overlay),host->child);
    int result=region_live(host)?ZLG_CONTENT_OK:ZLG_CONTENT_CLOSED;
    s->content_busy=FALSE; region_release(host);
    return result;
}
void zlg_region_parent_destroying(ZlgRegionHost *host) {
    /* A child may still be inside GTK's set_parent call. Preserve that parent
     * relation until its native call returns; evacuate the independently
     * retained layer instead. Ordinary safe-point detach settles each child. */
    region_retain(host);
    ZlgRegionLayer *layer=host->layer;
    if (!host->closed && !content_live(layer->window))
        content_remove(layer->overlay,layer->window->window);
    region_release(host);
}
int zlg_region_attach(NativeWindow *s, void *widget, ZlgRegionHost **out) {
    ZlgRegionHost *host=NULL;
    *out=NULL;
    int result=zlg_region_prepare(s,widget,&host);
    if (result!=ZLG_CONTENT_OK) return result;
    region_retain(host);
    result=zlg_region_mount(host);
    if (result!=ZLG_CONTENT_OK) { zlg_region_detach(host); region_release(host); return result; }
    *out=host;
    region_release(host);
    return ZLG_CONTENT_OK;
}
void zlg_region_detach(ZlgRegionHost *host) {
    region_retain(host);
    if (host->closed) { region_release(host); return; }
    host->closed=TRUE;
    ZlgRegionLayer *layer=host->layer;
    NativeWindow *s=layer->window;
    gboolean was_busy=s->content_busy; s->content_busy=TRUE;
    if (host->previous) host->previous->next=host->next; else layer->first=host->next;
    if (host->next) host->next->previous=host->previous;
    host->previous=NULL; host->next=NULL;
    content_remove(host->child,layer->overlay);
    if (!layer->first) region_restore(layer);
    s->content_busy=was_busy;
    region_release(host); /* Owner responsibility ends once. */
    region_release(host); /* Invocation pin ends after all foreign operations. */
}
int zlg_region_viewport(ZlgRegionHost *host, int x, int y, int width, int height, int visible) {
    if (!region_live(host)) return ZLG_CONTENT_CLOSED;
    NativeWindow *s=host->layer->window;
    if (s->content_busy) return ZLG_CONTENT_BUSY;
    if (width<0 || height<0 || width>32768 || height>32768 || x< -1000000 || x>1000000 || y< -1000000 || y>1000000) return ZLG_CONTENT_INVALID;
    region_retain(host); s->content_busy=TRUE;
    host->x=x; host->y=y; host->width=width; host->height=height;
    host->visible=visible && width>0 && height>0;
    if (host->visible) gtk_widget_show(host->child); else gtk_widget_hide(host->child);
    if (region_live(host)) gtk_widget_queue_resize(host->layer->overlay);
    int result=region_live(host)?ZLG_CONTENT_OK:ZLG_CONTENT_CLOSED;
    s->content_busy=FALSE;
    region_release(host);
    return result;
}
int zlg_region_focus(ZlgRegionHost *host) {
    if (!region_live(host)) return ZLG_CONTENT_CLOSED;
    NativeWindow *s=host->layer->window;
    if (s->content_busy) return ZLG_CONTENT_BUSY;
    if (!host->visible) return ZLG_CONTENT_INVALID;
    region_retain(host); s->content_busy=TRUE;
    gtk_widget_grab_focus(host->child);
    int result=region_live(host)?ZLG_CONTENT_OK:ZLG_CONTENT_CLOSED;
    s->content_busy=FALSE;
    region_release(host);
    return result;
}
#endif
