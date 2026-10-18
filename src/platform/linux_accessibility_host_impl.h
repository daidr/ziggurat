#ifndef ZIGGURAT_LINUX_ACCESSIBILITY_HOST_IMPL_H
#define ZIGGURAT_LINUX_ACCESSIBILITY_HOST_IMPL_H

/* Included after NativeWindow and retain/release, like the content adapters. */
#include "linux_accessibility_host.h"
#include <gtk/gtk-a11y.h>

typedef struct ZlgAccessibilityArea ZlgAccessibilityArea;
typedef struct ZlgAccessibilityAreaClass ZlgAccessibilityAreaClass;
typedef struct ZlgAccessibilityHost ZlgAccessibilityHost;
typedef struct ZlgAccessibilityHostClass ZlgAccessibilityHostClass;
enum AccessibilityPhase { ACCESSIBILITY_PREPARING, ACCESSIBILITY_PREPARED,
    ACCESSIBILITY_MOUNTED, ACCESSIBILITY_RETIRED };

struct ZlgAccessibilityBinding {
    unsigned refs;
    enum AccessibilityPhase phase;
    GThread *thread;
    NativeWindow *native;
    ZlgAccessibilityArea *area;
    AtkObject *child;
    ZlgAccessibilityHost *host;
    ZlgAccessibilityInvalidate invalidate;
    gboolean owns_area, owns_child, armed, parent_inflight;
};
struct ZlgAccessibilityArea {
    GtkDrawingArea parent;
    NativeWindow *native; /* Borrowed only while live; native owns this area. */
    ZlgAccessibilityBinding *binding; /* Owns one C token ref, including prepare. */
    ZlgAccessibilityHost *host; /* Owns one lazily created, stable accessible ref. */
    GThread *thread;
    unsigned notifying;
    gboolean closed;
};
struct ZlgAccessibilityAreaClass { GtkDrawingAreaClass parent; };
struct ZlgAccessibilityHost {
    GtkWidgetAccessible parent;
    ZlgAccessibilityArea *area; /* Borrowed; cleared before disposal signals. */
    ZlgAccessibilityBinding *binding; /* Borrowed from registered token. */
    AtkObject *child; /* Independent owning ref while published. */
    GThread *thread;
    gboolean unsetting;
};
struct ZlgAccessibilityHostClass { GtkWidgetAccessibleClass parent; };

static GType accessibility_area_type_id;
static gint accessibility_tokens, accessibility_registered, accessibility_mounted;
#ifndef ZLG_ACCESSIBILITY_BINDING_ALLOC
#define ZLG_ACCESSIBILITY_BINDING_ALLOC() g_try_new0(ZlgAccessibilityBinding,1)
#endif

static void accessibility_area_close(ZlgAccessibilityArea *, gboolean);
static void accessibility_retire(ZlgAccessibilityBinding *, gboolean);
static void accessibility_unset_host(ZlgAccessibilityHost *);
G_DEFINE_TYPE(ZlgAccessibilityHost,zlg_accessibility_host,GTK_TYPE_WIDGET_ACCESSIBLE)
G_DEFINE_TYPE(ZlgAccessibilityArea,zlg_accessibility_area,GTK_TYPE_DRAWING_AREA)

static gboolean accessibility_owner(GThread *thread) { return thread==g_thread_self(); }
static void accessibility_ref(ZlgAccessibilityBinding *binding) { ++binding->refs; }
static void accessibility_unref(ZlgAccessibilityBinding *binding) {
    if (--binding->refs) return;
    g_free(binding);
    g_atomic_int_add(&accessibility_tokens,-1);
}
void zlg_accessibility_counts(unsigned *tokens, unsigned *registered, unsigned *mounted) {
    if (tokens) *tokens=(unsigned)g_atomic_int_get(&accessibility_tokens);
    if (registered) *registered=(unsigned)g_atomic_int_get(&accessibility_registered);
    if (mounted) *mounted=(unsigned)g_atomic_int_get(&accessibility_mounted);
}
/* Never calls get_type: default windows do not initialize either optional type. */
static ZlgAccessibilityArea *accessibility_area(NativeWindow *native) {
    if (!accessibility_area_type_id || !native || !native->area ||
        G_OBJECT_TYPE(native->area)!=accessibility_area_type_id) return NULL;
    return (ZlgAccessibilityArea *)native->area;
}
int zlg_accessibility_host_available(NativeWindow *native) {
    ZlgAccessibilityArea *area=accessibility_area(native);
    return area && accessibility_owner(area->thread) && !area->closed && !native->destroyed;
}
static gboolean accessibility_live(ZlgAccessibilityBinding *binding) {
    return binding->phase!=ACCESSIBILITY_RETIRED && binding->native &&
        binding->area && !binding->area->closed && !binding->native->destroyed &&
        binding->area->binding==binding;
}

static gint accessibility_n_children(AtkObject *object) {
    ZlgAccessibilityHost *host=(ZlgAccessibilityHost *)object;
    if (!accessibility_owner(host->thread)) return 0;
    return host->child?1:0;
}
static AtkObject *accessibility_ref_child(AtkObject *object, gint index) {
    ZlgAccessibilityHost *host=(ZlgAccessibilityHost *)object;
    if (!accessibility_owner(host->thread) || index!=0 || !host->child) return NULL;
    ZlgAccessibilityBinding *binding=host->binding;
    accessibility_ref(binding); /* Keep this registration while returning its ref. */
    /* Mounted child has independent token + host owning refs (at least two).
     * GLib only notifies toggle refs at 1 -> 2, so this increment cannot call
     * foreign code; owner-thread withdrawal cannot interleave these reads. */
    AtkObject *child=g_object_ref(host->child);
    gboolean same=host->binding==binding && host->child==child &&
        binding->phase==ACCESSIBILITY_MOUNTED;
    accessibility_unref(binding);
    if (!same) { g_object_unref(child); return NULL; }
    return child;
}
static void accessibility_widget_set(GtkAccessible *accessible) {
    ZlgAccessibilityHost *host=(ZlgAccessibilityHost *)accessible;
    GtkWidget *widget=gtk_accessible_get_widget(accessible);
    if (widget && accessibility_area_type_id && G_OBJECT_TYPE(widget)==accessibility_area_type_id) {
        ZlgAccessibilityArea *area=(ZlgAccessibilityArea *)widget;
        /* Publish before g_object_ref: even a toggle hook sees this genuine
         * host. The area's invocation/native owner keeps it alive meanwhile. */
        if (!area->host) {
            area->host=host;
            g_object_ref(host);
        }
        if (area->host==host && !area->closed) host->area=area;
        else {
            host->area=NULL;
            accessibility_unset_host(host);
            return;
        }
    }
    GTK_ACCESSIBLE_CLASS(zlg_accessibility_host_parent_class)->widget_set(accessible);
}
static void accessibility_widget_unset(GtkAccessible *accessible) {
    ZlgAccessibilityHost *host=(ZlgAccessibilityHost *)accessible;
    gboolean unsetting=host->unsetting;
    host->unsetting=TRUE;
    ZlgAccessibilityArea *area=host->area;
    host->area=NULL;
    if (area) accessibility_area_close(area,FALSE);
    GTK_ACCESSIBLE_CLASS(zlg_accessibility_host_parent_class)->widget_unset(accessible);
    host->unsetting=unsetting;
}
static void zlg_accessibility_host_class_init(ZlgAccessibilityHostClass *klass) {
    AtkObjectClass *object=ATK_OBJECT_CLASS(klass);
    GtkAccessibleClass *accessible=GTK_ACCESSIBLE_CLASS(klass);
    object->get_n_children=accessibility_n_children;
    object->ref_child=accessibility_ref_child;
    accessible->widget_set=accessibility_widget_set;
    accessible->widget_unset=accessibility_widget_unset;
}
static void zlg_accessibility_host_init(ZlgAccessibilityHost *host) { host->thread=g_thread_self(); }

static AtkObject *accessibility_get_accessible(GtkWidget *widget) {
    ZlgAccessibilityArea *area=(ZlgAccessibilityArea *)widget;
    if (area->host) return ATK_OBJECT(area->host);
    /* The widget_set override takes an area-owned ref before initialize can
     * reenter destroy. GTK's local return then remains valid even if its own
     * cached ref was removed by the destroy class closure. */
    return GTK_WIDGET_CLASS(zlg_accessibility_area_parent_class)->get_accessible(widget);
}
static void accessibility_dispose(GObject *object) {
    accessibility_area_close((ZlgAccessibilityArea *)object,TRUE);
    G_OBJECT_CLASS(zlg_accessibility_area_parent_class)->dispose(object);
}
static void accessibility_finalize(GObject *object) {
    ZlgAccessibilityArea *area=(ZlgAccessibilityArea *)object;
    ZlgAccessibilityHost *host=area->host;
    area->host=NULL;
    if (host) g_object_unref(host);
    G_OBJECT_CLASS(zlg_accessibility_area_parent_class)->finalize(object);
}
static void zlg_accessibility_area_class_init(ZlgAccessibilityAreaClass *klass) {
    accessibility_area_type_id=G_TYPE_FROM_CLASS(klass);
    GObjectClass *object=G_OBJECT_CLASS(klass);
    GtkWidgetClass *widget=GTK_WIDGET_CLASS(klass);
    object->dispose=accessibility_dispose;
    object->finalize=accessibility_finalize;
    widget->get_accessible=accessibility_get_accessible;
    gtk_widget_class_set_accessible_type(widget,zlg_accessibility_host_get_type());
    gtk_widget_class_set_accessible_role(widget,ATK_ROLE_DRAWING_AREA);
}
static void zlg_accessibility_area_init(ZlgAccessibilityArea *area) { area->thread=g_thread_self(); }
static GtkWidget *accessibility_area_new(NativeWindow *native) {
    ZlgAccessibilityArea *area=g_object_new(zlg_accessibility_area_get_type(),NULL);
    area->native=native;
    return GTK_WIDGET(area);
}
static void accessibility_unset_host(ZlgAccessibilityHost *host) {
    if (host->unsetting) return;
    host->area=NULL;
    host->unsetting=TRUE;
    gtk_accessible_set_widget(GTK_ACCESSIBLE(host),NULL);
    host->unsetting=FALSE;
}

static void accessibility_clear_parent(AtkObject *child, ZlgAccessibilityHost *host) {
    /* Both objects have local owning pins. Never remove another host's link. */
    if (atk_object_get_parent(child)==ATK_OBJECT(host)) atk_object_set_parent(child,NULL);
}
static void accessibility_retire(ZlgAccessibilityBinding *binding, gboolean closing) {
    accessibility_ref(binding);
    if (binding->phase==ACCESSIBILITY_RETIRED) { accessibility_unref(binding); return; }
    gboolean mounted=binding->phase==ACCESSIBILITY_MOUNTED;
    NativeWindow *native=binding->native;
    ZlgAccessibilityArea *area=binding->area;
    AtkObject *child=binding->owns_child?binding->child:NULL;
    ZlgAccessibilityHost *host=binding->host;
    AtkObject *host_child=NULL;
    gboolean owns_area=binding->owns_area;
    gboolean armed=binding->armed;
    ZlgAccessibilityInvalidate invalidate=binding->invalidate;
    gboolean parent_inflight=binding->parent_inflight;
    /* Move completed owned refs to locals. No GObject operation precedes this
     * publication; partially acquired refs are returned to their own callers. */
    binding->phase=ACCESSIBILITY_RETIRED;
    binding->native=NULL; binding->area=NULL; binding->child=NULL; binding->host=NULL;
    binding->owns_area=FALSE; binding->owns_child=FALSE; binding->armed=FALSE;
    if (area->binding==binding) area->binding=NULL;
    ++area->notifying;
    g_atomic_int_add(&accessibility_registered,-1);
    if (mounted) g_atomic_int_add(&accessibility_mounted,-1);
    if (host && host->binding==binding) {
        host_child=host->child; host->child=NULL; host->binding=NULL;
    }
    ZlgAccessibilityHost *closing_host=closing?area->host:NULL;
    if (closing_host) closing_host->area=NULL;
    if (armed && child) invalidate(child);
    if (closing_host) accessibility_unset_host(closing_host);
    /* During a virtual setter, its outer call owns child/host pins and clears
     * the residual exact old link after that call returns. Avoid recursion. */
    if (mounted && !parent_inflight) accessibility_clear_parent(child,host);
    if (mounted) g_signal_emit_by_name(host,"children-changed::remove",0,child,NULL);
    if (host_child) g_object_unref(host_child);
    if (host) g_object_unref(host);
    if (child) g_object_unref(child);
    --area->notifying;
    if (owns_area) g_object_unref(area);
    release(native);
    accessibility_unref(binding); /* Registration ref. */
    accessibility_unref(binding); /* Invocation ref. */
}
static void accessibility_area_close(ZlgAccessibilityArea *area, gboolean clear_widget) {
    area->closed=TRUE; area->native=NULL;
    ZlgAccessibilityHost *host=area->host;
    if (host) host->area=NULL;
    if (area->binding) accessibility_retire(area->binding,clear_widget);
    else if (clear_widget && host) accessibility_unset_host(host);
}
static void accessibility_parent_destroying(NativeWindow *native) {
    ZlgAccessibilityArea *area=accessibility_area(native);
    if (area) accessibility_area_close(area,TRUE);
}

int zlg_accessibility_prepare(NativeWindow *native, void *object,
    ZlgAccessibilityInvalidate invalidate, ZlgAccessibilityBinding **out) {
    if (!out) return ZLG_ACCESSIBILITY_INVALID;
    *out=NULL;
    ZlgAccessibilityArea *area=accessibility_area(native);
    if (!area) return native && !native->destroyed?ZLG_ACCESSIBILITY_UNSUPPORTED:ZLG_ACCESSIBILITY_CLOSED;
    if (!accessibility_owner(area->thread)) return ZLG_ACCESSIBILITY_INVALID;
    if (area->closed || native->destroyed) return ZLG_ACCESSIBILITY_CLOSED;
    if (area->binding || area->notifying) return ZLG_ACCESSIBILITY_BUSY;
    if (!object || !ATK_IS_OBJECT(object) || g_object_is_floating(object) || !invalidate)
        return ZLG_ACCESSIBILITY_INVALID;
    ZlgAccessibilityBinding *binding=ZLG_ACCESSIBILITY_BINDING_ALLOC();
    if (!binding) return ZLG_ACCESSIBILITY_OOM;
    binding->refs=2; /* Registration and this invocation, returned to caller. */
    binding->thread=area->thread; binding->phase=ACCESSIBILITY_PREPARING;
    binding->native=native; binding->area=area; binding->invalidate=invalidate;
    retain(native); /* Binding's completed C-only owned ref. */
    retain(native); /* Invocation independently survives reentrant retirement. */
    area->binding=binding; ++area->notifying;
    g_atomic_int_inc(&accessibility_tokens); g_atomic_int_inc(&accessibility_registered);
    int result=ZLG_ACCESSIBILITY_CLOSED;
    gpointer acquired=g_object_ref(area);
    if (!accessibility_live(binding)) { g_object_unref(acquired); goto refused; }
    binding->owns_area=TRUE;
    acquired=g_object_ref(object);
    if (!accessibility_live(binding)) { g_object_unref(acquired); goto refused; }
    binding->child=acquired; binding->owns_child=TRUE;
    AtkObject *parent=atk_object_get_parent(binding->child);
    if (!accessibility_live(binding)) goto refused;
    if (parent) { result=ZLG_ACCESSIBILITY_INVALID; goto refused; }
    binding->phase=ACCESSIBILITY_PREPARED; binding->armed=TRUE;
    *out=binding;
    --area->notifying;
    release(native);
    return ZLG_ACCESSIBILITY_OK;
refused:
    accessibility_retire(binding,FALSE);
    --area->notifying;
    accessibility_unref(binding);
    release(native);
    return result;
}
int zlg_accessibility_mount(ZlgAccessibilityBinding *binding) {
    if (!binding || !accessibility_owner(binding->thread)) return ZLG_ACCESSIBILITY_INVALID;
    if (!accessibility_live(binding)) return ZLG_ACCESSIBILITY_CLOSED;
    if (binding->phase==ACCESSIBILITY_MOUNTED) return ZLG_ACCESSIBILITY_OK;
    if (binding->phase!=ACCESSIBILITY_PREPARED) return ZLG_ACCESSIBILITY_BUSY;
    ZlgAccessibilityArea *area=binding->area;
    if (area->notifying) return ZLG_ACCESSIBILITY_BUSY;
    NativeWindow *native=binding->native;
    accessibility_ref(binding); retain(native); ++area->notifying;
    GtkWidget *area_pin=GTK_WIDGET(g_object_ref(area));
    AtkObject *child=NULL, *host_child=NULL;
    ZlgAccessibilityHost *host=NULL;
    int result=ZLG_ACCESSIBILITY_CLOSED;
    if (!accessibility_live(binding)) goto done;
    child=g_object_ref(binding->child);
    if (!accessibility_live(binding)) goto done;
    AtkObject *parent=atk_object_get_parent(child);
    if (!accessibility_live(binding)) goto done;
    if (parent) { result=ZLG_ACCESSIBILITY_INVALID; goto done; }
    AtkObject *accessible=gtk_widget_get_accessible(GTK_WIDGET(area));
    if (!accessibility_live(binding)) goto done;
    if (!accessible || !G_TYPE_CHECK_INSTANCE_TYPE(accessible,zlg_accessibility_host_get_type())) {
        result=ZLG_ACCESSIBILITY_INVALID; goto done;
    }
    host=(ZlgAccessibilityHost *)g_object_ref(accessible);
    if (!accessibility_live(binding)) goto done;
    host_child=g_object_ref(child);
    if (!accessibility_live(binding)) goto done;
    /* No fallible preparation remains. Independent host/child refs are moved
     * into the binding/slot; invocation locals still pin both across setters. */
    ZlgAccessibilityHost *binding_host=g_object_ref(host);
    if (!accessibility_live(binding)) { g_object_unref(binding_host); goto done; }
    binding->host=binding_host;
    host->child=host_child; host_child=NULL; host->binding=binding;
    binding->phase=ACCESSIBILITY_MOUNTED;
    g_atomic_int_inc(&accessibility_mounted);
    result=ZLG_ACCESSIBILITY_OK;
    binding->parent_inflight=TRUE;
    atk_object_set_parent(child,ATK_OBJECT(host));
    binding->parent_inflight=FALSE;
    if (binding->phase==ACCESSIBILITY_RETIRED) accessibility_clear_parent(child,host);
    else g_signal_emit_by_name(host,"children-changed::add",0,child,NULL);
done:
    if (host_child) g_object_unref(host_child);
    if (host) g_object_unref(host);
    if (child) g_object_unref(child);
    --area->notifying;
    g_object_unref(area_pin);
    release(native);
    accessibility_unref(binding);
    return result;
}
void zlg_accessibility_withdraw(ZlgAccessibilityBinding *binding) {
    if (binding && accessibility_owner(binding->thread)) accessibility_retire(binding,FALSE);
}
int zlg_accessibility_position(ZlgAccessibilityBinding *binding, ZlgAccessibilityPosition *out) {
    if (!binding || !out || !accessibility_owner(binding->thread)) return ZLG_ACCESSIBILITY_INVALID;
    if (!accessibility_live(binding)) return ZLG_ACCESSIBILITY_CLOSED;
    if ((binding->phase!=ACCESSIBILITY_PREPARED && binding->phase!=ACCESSIBILITY_MOUNTED) ||
        binding->area->notifying) return ZLG_ACCESSIBILITY_BUSY;
    ZlgAccessibilityArea *area=binding->area;
    NativeWindow *native=binding->native;
    accessibility_ref(binding); retain(native); ++area->notifying;
    GtkWidget *widget=GTK_WIDGET(g_object_ref(area));
    GdkWindow *parent_window=NULL, *top_window=NULL;
    ZlgAccessibilityPosition candidate={0};
    int result=ZLG_ACCESSIBILITY_CLOSED;
    if (!accessibility_live(binding)) goto done;
    int width=gtk_widget_get_allocated_width(widget);
    if (!accessibility_live(binding)) goto done;
    int height=gtk_widget_get_allocated_height(widget);
    if (!accessibility_live(binding)) goto done;
    int scale=gtk_widget_get_scale_factor(widget);
    if (!accessibility_live(binding)) goto done;
    if (width<0 || height<0 || scale<1) { result=ZLG_ACCESSIBILITY_INVALID; goto done; }
    candidate.width=(uint32_t)width; candidate.height=(uint32_t)height;
    candidate.scale=(uint32_t)scale; candidate.flags=ZLG_ACCESSIBILITY_EXTENT;
    result=ZLG_ACCESSIBILITY_OK;
    if (!gtk_widget_get_mapped(widget) || !gtk_widget_is_drawable(widget) ||
        !gtk_widget_get_has_window(widget)) goto done;
    if (!accessibility_live(binding)) goto done;
#ifdef GDK_WINDOWING_X11
    if (!GDK_IS_X11_DISPLAY(gtk_widget_get_display(widget))) goto done;
    if (!accessibility_live(binding)) goto done;
    GtkAllocation allocation;
    gtk_widget_get_allocation(widget,&allocation);
    if (!accessibility_live(binding)) goto done;
    GdkWindow *own_window=gtk_widget_get_window(widget);
    if (!accessibility_live(binding)) goto done;
    if (!own_window || gdk_window_is_destroyed(own_window)) goto done;
    GdkWindow *borrowed=gtk_widget_get_parent_window(widget);
    if (!accessibility_live(binding)) goto done;
    if (!borrowed || gdk_window_is_destroyed(borrowed)) goto done;
    parent_window=g_object_ref(borrowed);
    if (!accessibility_live(binding)) goto done;
    borrowed=gdk_window_get_toplevel(own_window);
    if (!accessibility_live(binding)) goto done;
    if (!borrowed || gdk_window_is_destroyed(borrowed)) goto done;
    top_window=g_object_ref(borrowed);
    if (!accessibility_live(binding)) goto done;
    int parent_x=0,parent_y=0,top_x=0,top_y=0;
    int have_parent=gdk_window_get_origin(parent_window,&parent_x,&parent_y);
    if (!accessibility_live(binding)) goto done;
    int have_top=gdk_window_get_origin(top_window,&top_x,&top_y);
    if (!accessibility_live(binding)) goto done;
    if (!have_parent || !have_top || gdk_window_is_destroyed(parent_window) ||
        gdk_window_is_destroyed(top_window) || !gtk_widget_get_mapped(widget) ||
        !gtk_widget_is_drawable(widget)) goto done;
    /* Use the widget's parent-window basis, preserving logical allocation
     * offsets before subtraction. Independently rounding its own GdkWindow
     * origin loses a unit at negative physical coordinates under HiDPI. */
    GtkAllocation current;
    gtk_widget_get_allocation(widget,&current);
    if (!accessibility_live(binding)) goto done;
    if (current.x!=allocation.x || current.y!=allocation.y ||
        current.width!=allocation.width || current.height!=allocation.height ||
        gtk_widget_get_parent_window(widget)!=parent_window ||
        gtk_widget_get_window(widget)!=own_window || gtk_widget_get_scale_factor(widget)!=scale) goto done;
    int64_t screen_x=(int64_t)parent_x+allocation.x, screen_y=(int64_t)parent_y+allocation.y;
    int64_t window_x=screen_x-top_x, window_y=screen_y-top_y;
    if (screen_x>=INT32_MIN && screen_x<=INT32_MAX && screen_y>=INT32_MIN && screen_y<=INT32_MAX) {
        candidate.screen_x=(int32_t)screen_x; candidate.screen_y=(int32_t)screen_y;
        candidate.flags|=ZLG_ACCESSIBILITY_SCREEN_ORIGIN;
    }
    if (window_x>=INT32_MIN && window_x<=INT32_MAX && window_y>=INT32_MIN && window_y<=INT32_MAX) {
        candidate.window_x=(int32_t)window_x; candidate.window_y=(int32_t)window_y;
        candidate.flags|=ZLG_ACCESSIBILITY_WINDOW_ORIGIN;
    }
#endif
done:
    if (top_window) g_object_unref(top_window);
    if (parent_window) g_object_unref(parent_window);
    --area->notifying;
    g_object_unref(widget);
    release(native);
    /* Only the independent token is touched after foreign unrefs/native release.
     * A retired token clears native/area before their finalization. */
    if (!accessibility_live(binding)) result=ZLG_ACCESSIBILITY_CLOSED;
    if (result==ZLG_ACCESSIBILITY_OK) *out=candidate;
    accessibility_unref(binding);
    return result;
}
void zlg_accessibility_release(ZlgAccessibilityBinding *binding) {
    if (!binding || !accessibility_owner(binding->thread)) return;
    accessibility_ref(binding);
    accessibility_retire(binding,FALSE);
    accessibility_unref(binding); /* Caller responsibility. */
    accessibility_unref(binding); /* Invocation pin. */
}

#endif
