#ifndef ZIGGURAT_LINUX_REGIONS_IMPL_H
#define ZIGGURAT_LINUX_REGIONS_IMPL_H
#include <gtk/gtk-a11y.h>
#include <math.h>

/* Native regions of a window, such as web views in its declarative UI, are
 * children of a GtkOverlay put where the drawing area was, under the area,
 * which the overlay holds over them: what the content paints after a region
 * (its popovers, menus, dialogs) shows over it. The area is shaped by the
 * regions placed: its own GdkWindow, which X11 would otherwise show over
 * them whatever its frames leave, shows the content outside their clips and
 * where the content paints over them (their covers), and the overlay's
 * window of the area takes the pointer only there, letting it through to
 * the regions elsewhere. A region with corners gives back to the content
 * the pixels its corners cut off. Assistive technology finds the overlay's
 * area alone: the regions' trees are inside the area's nodes standing for
 * them. */
enum { ZLG_REGION_MAX_COVERS=16 };

struct ZlgRegionLayer {
    NativeWindow *window;
    GtkWidget *overlay, *base;
    ZlgRegionHost *first;
    unsigned refs;
    gulong position_handler, allocate_handler, realize_handler;
    gboolean restored;
};
struct ZlgRegionHost {
    ZlgRegionLayer *layer;
    GtkWidget *child;
    ZlgRegionHost *previous, *next;
    unsigned refs;
    gulong destroy_handler, scroll_handler, key_handler, focus_handler;
    int x, y, width, height;
    /* What shows of the region (its clip, the pixels it wholly covers), the
       corners of its box, and the content's covers over it, in GTK's
       logical pixels of the area; set by zlg_region_shape. */
    gboolean shaped;
    cairo_rectangle_int_t clip, covers[ZLG_REGION_MAX_COVERS];
    unsigned cover_count;
    double radii[4];
    gboolean visible, closed, child_destroyed;
};
/* The overlay holding the regions, whose accessible lists the area alone. */
typedef struct ZlgRegionOverlay { GtkOverlay parent; } ZlgRegionOverlay;
typedef struct ZlgRegionOverlayClass { GtkOverlayClass parent; } ZlgRegionOverlayClass;
typedef struct ZlgRegionOverlayAccessible { GtkContainerAccessible parent; } ZlgRegionOverlayAccessible;
typedef struct ZlgRegionOverlayAccessibleClass { GtkContainerAccessibleClass parent; } ZlgRegionOverlayAccessibleClass;
G_DEFINE_TYPE(ZlgRegionOverlay,zlg_region_overlay,GTK_TYPE_OVERLAY)
G_DEFINE_TYPE(ZlgRegionOverlayAccessible,zlg_region_overlay_accessible,GTK_TYPE_CONTAINER_ACCESSIBLE)
static GQuark region_area_quark(void) { return g_quark_from_static_string("ziggurat-region-area"); }
static GtkWidget *region_overlay_area(AtkObject *object) {
    GtkWidget *overlay=gtk_accessible_get_widget(GTK_ACCESSIBLE(object));
    GtkWidget *area=overlay?g_object_get_qdata(G_OBJECT(overlay),region_area_quark()):NULL;
    return area && gtk_widget_get_parent(area)==overlay?area:NULL;
}
static gint region_overlay_n_children(AtkObject *object) { return region_overlay_area(object)?1:0; }
static AtkObject *region_overlay_ref_child(AtkObject *object, gint index) {
    GtkWidget *area=region_overlay_area(object);
    if (!area || index!=0) return NULL;
    AtkObject *child=gtk_widget_get_accessible(area);
    return child?g_object_ref(child):NULL;
}
static void zlg_region_overlay_accessible_class_init(ZlgRegionOverlayAccessibleClass *klass) {
    AtkObjectClass *object=ATK_OBJECT_CLASS(klass);
    object->get_n_children=region_overlay_n_children;
    object->ref_child=region_overlay_ref_child;
}
static void zlg_region_overlay_accessible_init(ZlgRegionOverlayAccessible *self) { (void)self; }
static void zlg_region_overlay_class_init(ZlgRegionOverlayClass *klass) {
    gtk_widget_class_set_accessible_type(GTK_WIDGET_CLASS(klass),zlg_region_overlay_accessible_get_type());
}
static void zlg_region_overlay_init(ZlgRegionOverlay *self) { (void)self; }
static gint region_resources;
static gboolean page_key(NativeWindow *s, GdkEventKey *native);
static void page_tab_out(NativeWindow *s, gboolean back);
static void region_shape(ZlgRegionLayer *layer);
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
    g_object_unref(layer->base);
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
    if (layer->allocate_handler && g_signal_handler_is_connected(s->area,layer->allocate_handler)) g_signal_handler_disconnect(s->area,layer->allocate_handler);
    if (layer->realize_handler && g_signal_handler_is_connected(s->area,layer->realize_handler)) g_signal_handler_disconnect(s->area,layer->realize_handler);
    layer->allocate_handler=layer->realize_handler=0;
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
    layer->overlay=g_object_new(zlg_region_overlay_get_type(),NULL); g_object_ref_sink(layer->overlay); track(G_OBJECT(layer->overlay));
    g_object_set_qdata(G_OBJECT(layer->overlay),region_area_quark(),s->area);
    /* An empty base gives the overlay its size; the area is its top child. */
    layer->base=gtk_fixed_new(); g_object_ref_sink(layer->base);
    gtk_container_add(GTK_CONTAINER(layer->overlay),layer->base);
    gtk_widget_show(layer->base);
    layer->position_handler=g_signal_connect(layer->overlay,"get-child-position",G_CALLBACK(region_position),layer);
    s->regions=layer;
    content_cancel_input(s);
    if (!content_live(s)) goto closed;
    gtk_container_remove(root_container(s),s->area);
    if (!content_live(s)) goto closed;
    root_add(s,layer->overlay);
    if (!content_live(s)) goto closed;
    gtk_overlay_add_overlay(GTK_OVERLAY(layer->overlay),s->area);
    if (!content_live(s)) goto closed;
    layer->allocate_handler=g_signal_connect_swapped(s->area,"size-allocate",G_CALLBACK(region_shape),layer);
    layer->realize_handler=g_signal_connect_swapped(s->area,"realize",G_CALLBACK(region_shape),layer);
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
    /* Under the area, over the regions before it. */
    if (region_live(host) && gtk_widget_get_parent(s->area)==host->layer->overlay)
        gtk_overlay_reorder_overlay(GTK_OVERLAY(host->layer->overlay),s->area,-1);
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
static gboolean scroll(GtkWidget *widget, GdkEventScroll *native, gpointer data);
/* The child's scroll event, given to the drawing area at the same point on
   the screen: the native UI around the page scrolls, the page never does. */
static gboolean region_scroll(GtkWidget *widget, GdkEventScroll *native, gpointer data) {
    (void)widget;
    ZlgRegionHost *host=data;
    if (!region_live(host) || !host->scroll_handler) return FALSE;
    NativeWindow *s=host->layer->window;
    GdkWindow *area=gtk_widget_get_window(s->area);
    if (!area) return FALSE;
    gint ox=0, oy=0;
    gdk_window_get_origin(area,&ox,&oy);
    GdkEvent *event=gdk_event_copy((GdkEvent *)native);
    event->scroll.x=native->x_root-ox; event->scroll.y=native->y_root-oy;
    region_retain(host); retain(s);
    scroll(s->area,&event->scroll,s);
    release(s); region_release(host);
    gdk_event_free(event);
    return TRUE;
}
void zlg_region_scroll_to_container(ZlgRegionHost *host, int on) {
    if (!region_live(host)) return;
    if (on && !host->scroll_handler) host->scroll_handler=g_signal_connect(host->child,"scroll-event",G_CALLBACK(region_scroll),host);
    else if (!on && host->scroll_handler) { g_signal_handler_disconnect(host->child,host->scroll_handler); host->scroll_handler=0; }
}
/* Runs after the child's class handler, so for the keys the child passes on:
   WebKitGTK dispatches a key again once its web process says the page left
   it, and its class handler then lets it through. */
static gboolean region_key(GtkWidget *widget, GdkEventKey *native, gpointer data) {
    (void)widget;
    ZlgRegionHost *host=data;
    if (!region_live(host) || native->type!=GDK_KEY_PRESS) return FALSE;
    NativeWindow *s=host->layer->window;
    region_retain(host); retain(s);
    gboolean taken=page_key(s,native);
    release(s); region_release(host);
    return taken;
}
void zlg_region_forward_keys(ZlgRegionHost *host, int on) {
    if (!region_live(host)) return;
    if (on && !host->key_handler) host->key_handler=g_signal_connect_after(host->child,"key-press-event",G_CALLBACK(region_key),host);
    else if (!on && host->key_handler) { g_signal_handler_disconnect(host->child,host->key_handler); host->key_handler=0; }
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
    /* A destroyed child has lost its handlers already. */
    gulong *handlers[]={&host->scroll_handler,&host->key_handler,&host->focus_handler};
    for (unsigned i=0;i<G_N_ELEMENTS(handlers);i++) {
        if (*handlers[i] && g_signal_handler_is_connected(host->child,*handlers[i])) g_signal_handler_disconnect(host->child,*handlers[i]);
        *handlers[i]=0;
    }
    if (!host->child_destroyed && gtk_widget_is_focus(host->child) && content_live(s)) gtk_widget_grab_focus(s->area);
    content_remove(host->child,layer->overlay);
    if (!layer->first) region_restore(layer);
    else region_shape(layer);
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
    /* A hidden region keeps no keyboard: it goes back to the content. */
    if (!host->visible && gtk_widget_is_focus(host->child)) gtk_widget_grab_focus(s->area);
    if (region_live(host)) { if (host->visible) gtk_widget_show(host->child); else gtk_widget_hide(host->child); }
    if (region_live(host)) region_shape(host->layer);
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
/* The pixels of r, in logical pixels, that it covers wholly (out: at all). */
static cairo_rectangle_int_t region_pixels(const double r[4], int scale, gboolean out) {
    double x0=r[0]/scale, y0=r[1]/scale, x1=(r[0]+r[2])/scale, y1=(r[1]+r[3])/scale;
    int a=(int)(out?floor(x0):ceil(x0)), b=(int)(out?floor(y0):ceil(y0)), c=(int)(out?ceil(x1):floor(x1)), d=(int)(out?ceil(y1):floor(y1));
    cairo_rectangle_int_t value={a,b,MAX(c-a,0),MAX(d-b,0)};
    return value;
}
/* The pixels, by rows, that corners of radii (from the top-left clockwise)
   cut off at all from the box x, y, width, height, added to region within
   clip. */
static void region_corners(cairo_region_t *region, const cairo_rectangle_int_t *clip, double x, double y, double width, double height, const double radii[4]) {
    for (int i=0;i<4;i++) {
        double r=radii[i];
        if (r<=0) continue;
        gboolean right=i==1 || i==2, bottom=i>=2;
        double cx=right?x+width-r:x+r, cy=bottom?y+height-r:y+r;
        double top=bottom?cy:y;
        for (double row=floor(top); row<top+r; row++) {
            double dy=bottom?MIN(row+1,top+r)-cy:cy-MAX(row,top);
            double half=r*sqrt(MAX(1-dy*dy/(r*r),0));
            double x0=right?floor(cx+half):floor(x), x1=right?ceil(x+width):ceil(cx-half);
            if (x1<=x0) continue;
            cairo_rectangle_int_t cut={(int)x0,(int)row,(int)(x1-x0),1};
            cairo_region_t *piece=cairo_region_create_rectangle(&cut);
            cairo_region_intersect_rectangle(piece,clip);
            cairo_region_union(region,piece);
            cairo_region_destroy(piece);
        }
    }
}
/* Shape the area by the regions shown: all of it but their clips, save the
   pixels their corners cut off and the content's covers over them; no shape
   without one shown. Follows the area's size and new windows. */
static void region_shape(ZlgRegionLayer *layer) {
    NativeWindow *s=layer->window;
    if (layer->restored || !content_live(s) || gtk_widget_get_parent(s->area)!=layer->overlay) return;
    GtkAllocation all;
    gtk_widget_get_allocation(s->area,&all);
    cairo_rectangle_int_t box={0,0,MAX(all.width,0),MAX(all.height,0)};
    cairo_region_t *region=NULL;
    for (ZlgRegionHost *host=layer->first;host;host=host->next) {
        if (host->closed || !host->visible) continue;
        if (!region) region=cairo_region_create_rectangle(&box);
        cairo_rectangle_int_t frame={host->x,host->y,host->width,host->height};
        cairo_rectangle_int_t clip=frame;
        if (host->shaped) gdk_rectangle_intersect(&frame,&host->clip,&clip);
        cairo_region_subtract_rectangle(region,&clip);
        if (!host->shaped) continue;
        region_corners(region,&clip,host->x,host->y,host->width,host->height,host->radii);
        for (unsigned i=0;i<host->cover_count;i++) cairo_region_union_rectangle(region,&host->covers[i]);
    }
    GdkWindow *input=gtk_widget_get_parent_window(s->area);
    if (input && input!=gtk_widget_get_window(s->window)) gdk_window_input_shape_combine_region(input,region,0,0);
    if (gtk_widget_get_has_window(s->area)) {
        GdkWindow *own=gtk_widget_get_window(s->area);
        if (own) gdk_window_shape_combine_region(own,region,0,0);
    }
    /* Kept for tests to read: where the content shows; none is everywhere. */
    g_object_set_data_full(G_OBJECT(layer->overlay),"ziggurat-region-shape",region,region?(GDestroyNotify)cairo_region_destroy:NULL);
}
/* clip, each cover and the corners' radii in device pixels of the area. */
int zlg_region_shape(ZlgRegionHost *host, const double clip[4], const double radii[4], const double *covers, unsigned count) {
    if (!region_live(host)) return ZLG_CONTENT_CLOSED;
    NativeWindow *s=host->layer->window;
    if (s->content_busy) return ZLG_CONTENT_BUSY;
    if (count>ZLG_REGION_MAX_COVERS || (count && !covers)) return ZLG_CONTENT_INVALID;
    for (int i=0;i<4;i++) if (!isfinite(clip[i]) || !isfinite(radii[i]) || radii[i]<0) return ZLG_CONTENT_INVALID;
    for (unsigned i=0;i<4*count;i++) if (!isfinite(covers[i])) return ZLG_CONTENT_INVALID;
    int scale=MAX(1,gtk_widget_get_scale_factor(s->area));
    host->shaped=TRUE;
    host->clip=region_pixels(clip,scale,FALSE);
    for (int i=0;i<4;i++) host->radii[i]=radii[i]/scale;
    host->cover_count=count;
    for (unsigned i=0;i<count;i++) host->covers[i]=region_pixels(covers+4*i,scale,TRUE);
    region_shape(host->layer);
    return region_live(host)?ZLG_CONTENT_OK:ZLG_CONTENT_CLOSED;
}
int zlg_region_has_focus(ZlgRegionHost *host) {
    return region_live(host) && gtk_widget_is_focus(host->child);
}
/* GTK moves the keyboard with Tab through focus signals, which a page's Tab
   past its ends starts: the content takes the keyboard back and moves its
   focus on from the region's node. GTK moving the keyboard into the region
   by itself, as a window shows, leaves it with the content. */
static gboolean region_focus(GtkWidget *widget, GtkDirectionType direction, gpointer data) {
    ZlgRegionHost *host=data;
    if (!region_live(host)) return FALSE;
    NativeWindow *s=host->layer->window;
    if (gtk_widget_is_focus(widget)) {
        if (direction!=GTK_DIR_TAB_FORWARD && direction!=GTK_DIR_TAB_BACKWARD) return FALSE;
        region_retain(host); retain(s);
        page_tab_out(s,direction==GTK_DIR_TAB_BACKWARD);
        if (region_live(host) && gtk_widget_is_focus(widget)) gtk_widget_grab_focus(s->area);
        release(s); region_release(host);
        return TRUE;
    }
    if (GTK_IS_CONTAINER(widget) && gtk_container_get_focus_child(GTK_CONTAINER(widget))) return FALSE;
    gtk_widget_grab_focus(s->area);
    return TRUE;
}
void zlg_region_tab_focus(ZlgRegionHost *host, int on) {
    if (!region_live(host)) return;
    if (on && !host->focus_handler) host->focus_handler=g_signal_connect(host->child,"focus",G_CALLBACK(region_focus),host);
    else if (!on && host->focus_handler) { g_signal_handler_disconnect(host->child,host->focus_handler); host->focus_handler=0; }
}
#endif
