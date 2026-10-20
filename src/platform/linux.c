#include <gtk/gtk.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#include <X11/Xatom.h>
#endif
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif
#include <stdint.h>
#include <string.h>
#include <math.h>
#include "linux_content.h"
#include "linux_pointer.h"

typedef struct NativeEvent {
    int kind, key, flags;
    void *context, *window;
    double x, y, dx, dy;
    uint32_t width, height, scale;
    const char *text;
    size_t length, selection;
} NativeEvent;
typedef struct NativeTextContext { char *text; size_t capacity, length, cursor; } NativeTextContext;
typedef int (*Emit)(void *, const NativeEvent *);
typedef struct NativeApp NativeApp;
typedef struct WakeSource { GSource source; NativeApp *app; } WakeSource;
struct NativeApp { GMainContext *context; GMainLoop *loop; GSource *source; void *owner; void (*dispatch)(void *); gint pending, stopped; };
typedef struct NativeWindow {
    gint refs;
    GtkWidget *window, *area;
    GtkIMContext *im;
    uint64_t im_epoch, composition_epoch;
    gboolean im_suspended;
    GdkRectangle caret;
    GtkWindowGroup *group;
    ZlgContentHost *content;
    ZlgRegionLayer *regions;
    gboolean content_busy;
    void *owner;
    Emit emit;
    gboolean destroyed, preedit;
    uint64_t pressed_keys[16];
    int decoration, cursor_hit;
    GdkCursor *resize_cursors[8];
    GdkEventButton *gesture;
    gboolean gesture_used;
    gboolean size_observed;
    uint32_t observed_width, observed_height, observed_scale;
    gboolean fullscreen_requested, above_requested, above_observed, saved_geometry, restore_pending;
    gboolean saved_maximized, saved_minimized;
    gint normal_x, normal_y, normal_width, normal_height;
    gint saved_x, saved_y, saved_width, saved_height;
    uint64_t pointer_operation;
    const ZlgPointerTicket *pointer_release;
    gboolean pointer_enabled;
    /* Present only while a system menu bar is attached: a vertical box that
       holds the bar above the window's ordinary child. */
    GtkWidget *menu_box, *menu_bar;
    /* WindowTraits the window manager cannot enforce on its own. */
    gboolean immovable, no_maximize;
} NativeWindow;
typedef struct NativeBounds { int32_t x,y; uint32_t width,height; int positioned; } NativeBounds;
static gint active_app, resources;
static void finalized(gpointer unused, GObject *object) { (void)unused; (void)object; g_atomic_int_add(&resources,-1); }
static void track(GObject *object) { g_atomic_int_inc(&resources); g_object_weak_ref(object,finalized,NULL); }
uint32_t zlg_resource_count(void) { return (uint32_t)g_atomic_int_get(&resources); }

static gboolean wake_prepare(GSource *source, gint *timeout) { *timeout=-1; WakeSource *wake=(WakeSource *)source; return wake->app && g_atomic_int_get(&wake->app->pending); }
static gboolean wake_check(GSource *source) { WakeSource *wake=(WakeSource *)source; return wake->app && g_atomic_int_get(&wake->app->pending); }
static gboolean wake_dispatch(GSource *source, GSourceFunc ignored, gpointer unused) {
    (void)ignored; (void)unused;
    NativeApp *app=((WakeSource *)source)->app;
    if (app && g_atomic_int_compare_and_exchange(&app->pending,1,0) && app->owner) app->dispatch(app->owner);
    return G_SOURCE_CONTINUE;
}
static GSourceFuncs wake_functions = {wake_prepare,wake_check,wake_dispatch,NULL,NULL,NULL};
NativeApp *zlg_app_create(void *owner, void (*dispatch)(void *), int *error) {
    if (!g_atomic_int_compare_and_exchange(&active_app,0,1)) { *error=1; return NULL; }
    if (!gtk_init_check(NULL,NULL)) { g_atomic_int_set(&active_app,0); *error=2; return NULL; }
    NativeApp *app=g_try_new0(NativeApp,1);
    if (!app) { g_atomic_int_set(&active_app,0); *error=3; return NULL; }
    g_atomic_int_inc(&resources);
    app->context=g_main_context_ref(g_main_context_default()); g_atomic_int_inc(&resources);
    app->loop=g_main_loop_new(app->context,FALSE); g_atomic_int_inc(&resources);
    app->owner=owner; app->dispatch=dispatch;
    app->source=g_source_new(&wake_functions,sizeof(WakeSource)); g_atomic_int_inc(&resources);
    ((WakeSource *)app->source)->app=app;
    g_source_set_name(app->source,"Ziggurat dispatcher");
    g_source_set_priority(app->source,G_PRIORITY_DEFAULT_IDLE);
    g_source_attach(app->source,app->context);
    *error=0; return app;
}
void zlg_app_wake(NativeApp *app) { if(g_atomic_int_compare_and_exchange(&app->pending,0,1))g_main_context_wakeup(app->context); }
void zlg_app_quit(NativeApp *app) { g_atomic_int_set(&app->stopped,1); g_main_loop_quit(app->loop); }
void zlg_app_run(NativeApp *app) { if (!g_atomic_int_get(&app->stopped)) g_main_loop_run(app->loop); }
void zlg_app_destroy(NativeApp *app) {
    app->owner=NULL; ((WakeSource *)app->source)->app=NULL;
    g_source_destroy(app->source); g_source_unref(app->source); g_atomic_int_add(&resources,-1);
    g_main_loop_unref(app->loop); g_atomic_int_add(&resources,-1);
    g_main_context_unref(app->context); g_atomic_int_add(&resources,-1);
    g_free(app); g_atomic_int_add(&resources,-1); g_atomic_int_set(&active_app,0);
}
static void retain(NativeWindow *s) { g_atomic_int_inc(&s->refs); }
static void release(NativeWindow *s) {
    if (g_atomic_int_dec_and_test(&s->refs)) {
        for (int i=0;i<8;i++) if (s->resize_cursors[i]) g_object_unref(s->resize_cursors[i]);
        g_object_unref(s->area); g_object_unref(s->window); g_object_unref(s->group); g_free(s); g_atomic_int_add(&resources,-1);
    }
}
static int emit(NativeWindow *s, NativeEvent *event) { retain(s); int result=0; if (s->owner && !s->destroyed) result=s->emit(s->owner,event); release(s); return result; }

uint64_t zlg_window_pointer_operation(NativeWindow *s) {
    return s->destroyed?UINT64_MAX:s->pointer_operation;
}
uint64_t zlg_window_advance_pointer_operation(NativeWindow *s) {
    s->gesture=NULL; s->gesture_used=FALSE; s->pointer_release=NULL;
    s->pointer_operation=s->pointer_operation>=UINT64_MAX-1?UINT64_MAX:s->pointer_operation+1;
    return s->pointer_operation;
}
static gboolean pointer_current(NativeWindow *s, uint64_t operation) {
    return !s->destroyed && s->owner && operation && operation!=UINT64_MAX && s->pointer_operation==operation;
}
static gboolean pointer_allowed(NativeWindow *s, uint64_t operation) {
    if (!pointer_current(s,operation) || !gtk_widget_is_sensitive(s->window) || !gtk_widget_is_sensitive(s->area)) return FALSE;
    NativeEvent gate={0}; gate.kind=17;
    return emit(s,&gate) && pointer_current(s,operation) && gtk_widget_is_sensitive(s->window) && gtk_widget_is_sensitive(s->area);
}
static uint32_t pointer_button(guint button) {
    switch (button) {
        case 1:return ZLG_POINTER_PRIMARY;
        case 3:return ZLG_POINTER_SECONDARY;
        case 2:return ZLG_POINTER_MIDDLE;
        case 8:return ZLG_POINTER_BACK;
        case 9:return ZLG_POINTER_FORWARD;
        default:return ZLG_POINTER_UNKNOWN;
    }
}
static uint32_t pointer_modifiers(guint state) {
    return ((state&GDK_SHIFT_MASK)?1u:0u)|((state&GDK_CONTROL_MASK)?2u:0u)|
        ((state&GDK_MOD1_MASK)?4u:0u)|((state&GDK_SUPER_MASK)?8u:0u);
}
static void pointer_emit(NativeWindow *s, ZlgPointerFacts *facts) {
    NativeEvent event={0}; event.kind=24; event.context=facts; emit(s,&event);
}
/* The all-off caller never enters a 96-byte facts/settings helper. */
static __attribute__((noinline)) void pointer_revoked_enabled(NativeWindow *s, uint64_t operation, uint32_t phase) {
    ZlgPointerFacts facts={0}; facts.operation=operation; facts.phase=phase;
    facts.button=ZLG_POINTER_UNKNOWN; pointer_emit(s,&facts);
}
static uint64_t pointer_revoke(NativeWindow *s, gboolean domain) {
    uint64_t operation=zlg_window_advance_pointer_operation(s);
    s->pointer_release=NULL;
    if (s->pointer_enabled) pointer_revoked_enabled(s,operation,domain?ZLG_POINTER_DOMAIN:ZLG_POINTER_LOSS);
    return operation;
}
static void pointer_retire(NativeWindow *s) {
    s->pointer_operation=UINT64_MAX; s->pointer_release=NULL; s->gesture=NULL; s->gesture_used=FALSE;
    if (s->pointer_enabled) pointer_revoked_enabled(s,UINT64_MAX,ZLG_POINTER_LOSS);
}
static __attribute__((noinline)) gboolean pointer_begin_enabled(NativeWindow *s, const GdkEventButton *native, ZlgPointerTicket *ticket, gboolean down) {
    /* Copy every original timing fact before a settings property getter can
     * synchronously reenter. Time zero remains a valid captured timestamp. */
    ZlgPointerFacts facts={0};
    facts.operation=ticket->operation; facts.button=ticket->button;
    facts.modifiers=ticket->modifiers; facts.phase=down?ZLG_POINTER_DOWN_BEGIN:ZLG_POINTER_UP_BEGIN;
    facts.tick_ms=native->time; facts.sample_x=native->x; facts.sample_y=native->y;
    facts.qualified=native->window==gtk_widget_get_window(s->area) && native->window && isfinite(facts.sample_x) && isfinite(facts.sample_y);
    if (down) {
        gint interval=0,distance=-1;
        GtkSettings *settings=gtk_widget_get_settings(s->area);
        if (settings) g_object_get(settings,"gtk-double-click-time",&interval,"gtk-double-click-distance",&distance,NULL);
        facts.interval_ms=interval>0?(uint32_t)interval:0;
        facts.min_x=facts.min_y=-(double)distance; facts.max_x=facts.max_y=(double)distance;
        facts.edges=15; /* Inclusive distance, exclusive time. */
        facts.qualified=facts.qualified && interval>0 && (uint32_t)interval<0x80000000u && distance>=0;
    }
    /* A newer but no longer current stamp must not touch Core history. */
    if (!pointer_current(s,ticket->operation)) return FALSE;
    if (!pointer_allowed(s,ticket->operation)) {
        if (pointer_current(s,ticket->operation)) pointer_revoke(s,FALSE);
        return FALSE;
    }
    pointer_emit(s,&facts);
    if (!pointer_current(s,ticket->operation)) return FALSE;
    ticket->sequence=facts.sequence;
    return TRUE;
}
static __attribute__((noinline)) void pointer_finish_enabled(NativeWindow *s, const ZlgPointerTicket *ticket, gboolean down, uint32_t disposition) {
    if (!pointer_current(s,ticket->operation)) return;
    ZlgPointerFacts facts={0}; facts.operation=ticket->operation; facts.sequence=ticket->sequence;
    facts.button=ticket->button; facts.modifiers=ticket->modifiers;
    facts.phase=down?ZLG_POINTER_DOWN_FINISH:ZLG_POINTER_UP_FINISH; facts.disposition=disposition;
    pointer_emit(s,&facts);
}
static __attribute__((noinline)) void pointer_motion_enabled(NativeWindow *s, const GdkEventMotion *native, uint64_t operation) {
    ZlgPointerFacts facts={0}; facts.operation=operation; facts.phase=ZLG_POINTER_MOTION;
    facts.button=ZLG_POINTER_UNKNOWN; facts.sample_x=native->x; facts.sample_y=native->y;
    facts.qualified=native->window==gtk_widget_get_window(s->area) && native->window && isfinite(facts.sample_x) && isfinite(facts.sample_y);
    if (pointer_current(s,operation)) pointer_emit(s,&facts);
}

/* Included here so the adapter can retain the private NativeWindow state
 * across GTK operations that synchronously destroy the parent. */
static GtkContainer *root_container(NativeWindow *s) { return GTK_CONTAINER(s->menu_box?s->menu_box:s->window); }
static void root_add(NativeWindow *s, GtkWidget *child) {
    if (s->menu_box) gtk_box_pack_start(GTK_BOX(s->menu_box),child,TRUE,TRUE,0);
    else gtk_container_add(GTK_CONTAINER(s->window),child);
}
#include "linux_content_impl.h"
#include "linux_regions_impl.h"
#include "linux_accessibility_host_impl.h"
static void size_event(NativeWindow *s, NativeEvent *event) {
    event->scale=gtk_widget_get_scale_factor(s->area);
    event->width=(uint32_t)MAX(0,gtk_widget_get_allocated_width(s->area))*event->scale;
    event->height=(uint32_t)MAX(0,gtk_widget_get_allocated_height(s->area))*event->scale;
    event->window=s->window;
}
uint32_t zlg_window_capabilities(NativeWindow *s) {
    GdkDisplay *display=gtk_widget_get_display(s->window);
#ifdef GDK_WINDOWING_X11
    if (GDK_IS_X11_DISPLAY(display)) {
        GdkScreen *screen=gtk_widget_get_screen(s->window);
        return 1u | 8u | 128u | 256u | 512u | 1024u | (gdk_screen_is_composited(screen)?64u:0u) | (gdk_x11_screen_supports_net_wm_hint(screen,gdk_atom_intern_static_string("_NET_WM_STATE_FULLSCREEN"))?2u:0u) |
            (gdk_x11_screen_supports_net_wm_hint(screen,gdk_atom_intern_static_string("_NET_WM_STATE_ABOVE"))?4u:0u) |
            (gdk_x11_screen_supports_net_wm_hint(screen,gdk_atom_intern_static_string("_NET_WM_MOVERESIZE"))?16u:0u) |
            (gdk_x11_screen_supports_net_wm_hint(screen,gdk_atom_intern_static_string("_GTK_SHOW_WINDOW_MENU"))?32u:0u);
    }
#endif
#ifdef GDK_WINDOWING_WAYLAND
    if (GDK_IS_WAYLAND_DISPLAY(display)) return 2u | 64u | 128u | 256u;
#endif
    return 0;
}
static GdkWindowState window_state(NativeWindow *s) { return gdk_window_get_state(gtk_widget_get_window(s->window)); }
static void notify_state(NativeWindow *s) {
    uint64_t operation=s->pointer_operation;
    NativeEvent event={0}; event.kind=16; event.flags=ZLG_POINTER_REVOKED; event.context=&operation; emit(s,&event);
}
static gboolean property_changed(GtkWidget *widget, GdkEventProperty *event, gpointer data) {
    (void)widget; NativeWindow *s=data; retain(s);
#ifdef GDK_WINDOWING_X11
    GdkDisplay *display=gtk_widget_get_display(s->window);
    if (GDK_IS_X11_DISPLAY(display) && event->atom==gdk_atom_intern_static_string("_NET_WM_STATE")) {
        // GTK3 does not populate ABOVE from the X11 state property. Bound this
        // event-only native read; state queries and paints use the cached bit.
        Atom type=None; int format=0; unsigned long count=0,remaining=0; unsigned char *values=NULL;
        gdk_x11_display_error_trap_push(display);
        int status=XGetWindowProperty(GDK_DISPLAY_XDISPLAY(display),GDK_WINDOW_XID(gtk_widget_get_window(s->window)),
            gdk_x11_get_xatom_by_name_for_display(display,"_NET_WM_STATE"),0,256,False,XA_ATOM,&type,&format,&count,&remaining,&values);
        int failure=gdk_x11_display_error_trap_pop(display);
        gboolean before=s->above_observed; s->above_observed=FALSE;
        if (!failure && status==Success && type==XA_ATOM && format==32 && remaining==0 && count<=256) {
            Atom above=gdk_x11_get_xatom_by_name_for_display(display,"_NET_WM_STATE_ABOVE");
            const Atom *atoms=(const Atom *)values;
            for (unsigned long i=0;i<count;i++) if (atoms[i]==above) { s->above_observed=TRUE; break; }
        }
        if (values) XFree(values);
        if (before!=s->above_observed) notify_state(s);
    }
#else
    (void)event; (void)s;
#endif
    release(s); return FALSE;
}
static void remember_normal(NativeWindow *s) {
    GdkWindowState state=window_state(s);
    if (s->fullscreen_requested || s->saved_geometry || (state&(GDK_WINDOW_STATE_FULLSCREEN|GDK_WINDOW_STATE_MAXIMIZED|GDK_WINDOW_STATE_ICONIFIED))) return;
    gtk_window_get_size(GTK_WINDOW(s->window),&s->normal_width,&s->normal_height);
    if (zlg_window_capabilities(s)&1u) gtk_window_get_position(GTK_WINDOW(s->window),&s->normal_x,&s->normal_y);
}
static void restore_geometry(NativeWindow *s) {
    if (!s->restore_pending || s->destroyed || (window_state(s)&GDK_WINDOW_STATE_FULLSCREEN)) return;
    s->restore_pending=FALSE; s->saved_geometry=FALSE;
    gtk_window_unmaximize(GTK_WINDOW(s->window));
    if (s->destroyed) return;
    gtk_window_resize(GTK_WINDOW(s->window),s->saved_width,s->saved_height);
    if (s->destroyed) return;
    if (zlg_window_capabilities(s)&1u) gtk_window_move(GTK_WINDOW(s->window),s->saved_x,s->saved_y);
    if (s->destroyed) return;
    if (s->saved_maximized) gtk_window_maximize(GTK_WINDOW(s->window));
    if (s->destroyed) return;
    if (s->saved_minimized) gtk_window_iconify(GTK_WINDOW(s->window));
}
static gboolean state_changed(GtkWidget *widget, GdkEventWindowState *event, gpointer data) {
    (void)widget; (void)event; NativeWindow *s=data; retain(s);
    uint64_t operation=pointer_revoke(s,TRUE);
    if (s->destroyed || s->pointer_operation!=operation) { release(s); return FALSE; }
    restore_geometry(s);
    if (!s->destroyed && s->pointer_operation==operation) remember_normal(s);
    if (!s->destroyed && s->pointer_operation==operation) notify_state(s);
    release(s); return FALSE;
}
static gboolean draw(GtkWidget *widget, cairo_t *context, gpointer data) {
    (void)widget; NativeWindow *s=data; NativeEvent event={0}; event.kind=1; event.context=context;
    size_event(s,&event); emit(s,&event); return FALSE;
}
static gboolean configured(GtkWidget *widget, GdkEventConfigure *native, gpointer data) {
    (void)widget; (void)native; NativeWindow *s=data; retain(s);
    if (!s->destroyed) {
        uint64_t operation=pointer_revoke(s,TRUE);
        if (s->destroyed || s->pointer_operation!=operation) { release(s); return FALSE; }
        remember_normal(s);
        NativeEvent event={0}; event.kind=2; event.flags=ZLG_POINTER_REVOKED; event.context=&operation;
        size_event(s,&event); emit(s,&event);
        if (!s->destroyed && s->pointer_operation==operation) { NativeEvent moved={0}; moved.kind=22; moved.flags=ZLG_POINTER_REVOKED; moved.context=&operation; emit(s,&moved); }
    }
    release(s); return FALSE;
}
static void notify_size(NativeWindow *s, const GtkAllocation *allocation) {
    if (s->destroyed) return;
    NativeEvent event={0}; event.kind=2;
    event.scale=gtk_widget_get_scale_factor(s->area);
    event.width=(uint32_t)MAX(0,allocation->width)*event.scale;
    event.height=(uint32_t)MAX(0,allocation->height)*event.scale;
    event.window=s->window;
    if (s->size_observed && event.width==s->observed_width && event.height==s->observed_height && event.scale==s->observed_scale) return;
    uint64_t operation=pointer_revoke(s,TRUE);
    if (s->destroyed || s->pointer_operation!=operation) return;
    event.flags=ZLG_POINTER_REVOKED; event.context=&operation;
    s->size_observed=TRUE;
    s->observed_width=event.width; s->observed_height=event.height; s->observed_scale=event.scale;
    emit(s,&event);
}
static void allocated(GtkWidget *widget, GtkAllocation *allocation, gpointer data) {
    (void)widget; NativeWindow *s=data; retain(s);
    notify_size(s,allocation);
    release(s);
}
static void scale_changed(GObject *object, GParamSpec *property, gpointer data) {
    (void)object; (void)property; NativeWindow *s=data; retain(s);
    if (!s->destroyed) {
        GtkAllocation allocation; gtk_widget_get_allocation(s->area,&allocation);
        notify_size(s,&allocation);
    }
    release(s);
}
static gboolean deleted(GtkWidget *widget, GdkEvent *event, gpointer data) {
    (void)widget; (void)event; NativeEvent close={0}; close.kind=10; emit(data,&close); return TRUE;
}
static void leave_group(NativeWindow *s) {
    guint members=GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(s->group),"ziggurat-window-members"));
    g_assert(members>0);
    g_object_set_data(G_OBJECT(s->group),"ziggurat-window-members",GUINT_TO_POINTER(members-1));
    if (members!=1) return;
    // Native auxiliary windows may inherit the group without sharing our
    // lifecycle. Release their relationships; their toolkit keeps ownership.
    GList *windows=gtk_window_group_list_windows(s->group);
    for (GList *item=windows;item;item=item->next) g_object_ref(item->data);
    for (GList *item=windows;item;item=item->next) {
        GtkWindow *window=item->data;
        if (window==GTK_WINDOW(s->window)) continue;
        if (gtk_window_get_transient_for(window)) gtk_window_set_transient_for(window,NULL);
        if (gtk_window_has_group(window) && gtk_window_get_group(window)==s->group) gtk_window_group_remove_window(s->group,window);
    }
    g_list_free_full(windows,g_object_unref);
}
static void destroyed(GtkWidget *widget, gpointer data) {
    (void)widget; NativeWindow *s=data; retain(s);
    if (s->destroyed) { release(s); return; }
    pointer_retire(s);
    s->destroyed=TRUE;
    accessibility_parent_destroying(s);
    s->gesture=NULL;
    void *owner=s->owner; s->owner=NULL;
    g_signal_handlers_disconnect_by_data(s->window,s);
    g_signal_handlers_disconnect_by_data(s->area,s);
    g_object_set_data(G_OBJECT(s->window),"ziggurat-native-window",NULL);
    if (s->menu_bar) { g_object_unref(s->menu_bar); s->menu_bar=NULL; }
    if (s->menu_box) { g_object_unref(s->menu_box); s->menu_box=NULL; }
    if (gtk_widget_has_grab(s->area)) gtk_grab_remove(s->area);
    GtkIMContext *im=s->im;s->im=NULL;
    if(im){g_signal_handlers_disconnect_by_data(im,s);gtk_im_context_set_client_window(im,NULL);g_object_unref(im);}
    leave_group(s);
    if (owner) { NativeEvent event={0}; event.kind=11; s->emit(owner,&event); }
    release(s); release(s);
}
static int query_hit(NativeWindow *s, double x, double y) {
    if (!s->decoration) return 0;
    NativeEvent event={0}; event.kind=19; event.x=x; event.y=y;
    event.width=MAX(0,gtk_widget_get_allocated_width(s->area)); event.height=MAX(0,gtk_widget_get_allocated_height(s->area));
    return emit(s,&event);
}
static int start_interaction(NativeWindow *s, GdkEventButton *event, int edge, gboolean owned_gesture) {
    uint64_t operation=s->pointer_operation;
    if (!(zlg_window_capabilities(s)&(edge==8?32u:16u))) return 1;
    if (!pointer_current(s,operation)) return 2;
    if (gtk_widget_has_grab(s->area)) gtk_grab_remove(s->area);
    if (!pointer_current(s,operation)) return 2;
    if (owned_gesture && (s->gesture!=event || s->gesture_used)) return 4;
    if (!pointer_allowed(s,operation)) return 2;
    if (edge!=8 && (!isfinite(event->x_root) || !isfinite(event->y_root) || event->x_root<G_MININT || event->x_root>G_MAXINT || event->y_root<G_MININT || event->y_root>G_MAXINT)) return 4;
    if (owned_gesture) s->gesture_used=TRUE;
    if (edge==8) {
        int result=gdk_window_show_window_menu(gtk_widget_get_window(s->window),(GdkEvent *)event)?0:1;
        if (result && owned_gesture && pointer_current(s,operation) && s->gesture==event) s->gesture_used=FALSE;
        return result;
    }
    if (edge<0 && s->immovable) return 4;
    if (edge<0) gtk_window_begin_move_drag(GTK_WINDOW(s->window),event->button,(int)event->x_root,(int)event->y_root,event->time);
    else gtk_window_begin_resize_drag(GTK_WINDOW(s->window),(GdkWindowEdge)edge,event->button,(int)event->x_root,(int)event->y_root,event->time);
    return s->destroyed?2:0;
}
int zlg_window_interaction(NativeWindow *s, int edge) {
    if (!s->gesture || s->gesture_used || !gtk_window_is_active(GTK_WINDOW(s->window))) return 4;
    retain(s); int result=start_interaction(s,s->gesture,edge,TRUE);
    release(s); return result;
}
static gboolean button(GtkWidget *widget, GdkEventButton *native, gpointer data) {
    NativeWindow *s=data;
    retain(s);
    const GdkEventType type=native->type;
    const guint native_button=native->button;
    const double x=native->x,y=native->y;
    /* GDK's synthesized double/triple notifications are decoration policy,
     * never a second down. The accompanying ordinary PRESS owns the receipt. */
    if (type!=GDK_BUTTON_PRESS && type!=GDK_BUTTON_RELEASE) {
        uint64_t operation=s->pointer_operation;
        if (native_button==1 && type==GDK_2BUTTON_PRESS && pointer_allowed(s,operation) && query_hit(s,x,y)==1 && pointer_allowed(s,operation)) {
            pointer_revoke(s,TRUE);
            if (!s->destroyed && gtk_window_get_resizable(GTK_WINDOW(s->window)) && !s->no_maximize) {
                if (window_state(s)&GDK_WINDOW_STATE_MAXIMIZED) gtk_window_unmaximize(GTK_WINDOW(s->window)); else gtk_window_maximize(GTK_WINDOW(s->window));
            }
        }
        release(s); return native_button==1;
    }
    ZlgPointerTicket ticket={0};
    ticket.operation=zlg_window_advance_pointer_operation(s);
    ticket.button=pointer_button(native_button); ticket.modifiers=pointer_modifiers(native->state);
    s->gesture=NULL; s->gesture_used=FALSE;
    const gboolean down=type==GDK_BUTTON_PRESS;
    const gboolean owned_grab=!down && gtk_widget_has_grab(widget) && gtk_window_group_get_current_grab(s->group)==widget;
    uint32_t disposition=ZLG_POINTER_DENIED;
    gboolean handled=native_button==1;
    if (ticket.operation==UINT64_MAX) {
        if (s->pointer_enabled) pointer_revoked_enabled(s,UINT64_MAX,ZLG_POINTER_LOSS);
        goto done;
    }
    if (s->pointer_enabled && !pointer_begin_enabled(s,native,&ticket,down)) goto done;
    if (!pointer_allowed(s,ticket.operation)) {
        if (pointer_current(s,ticket.operation)) pointer_revoke(s,FALSE);
        goto done;
    }
    int hit=query_hit(s,x,y);
    if (!pointer_allowed(s,ticket.operation)) goto done;
    disposition=ZLG_POINTER_DELIVERED;
    if (native_button!=1) {
        if (native_button==3 && down && (hit==1 || hit==2)) {
            handled=start_interaction(s,native,8,FALSE)==0;
            if (handled) disposition=ZLG_POINTER_CONSUMED;
        }
        goto done;
    }
    if (down && hit>0 && start_interaction(s,native,hit==1?-1:hit==2?8:hit-3,FALSE)==0) {
        disposition=ZLG_POINTER_CONSUMED; goto done;
    }
    if (!pointer_allowed(s,ticket.operation)) { disposition=ZLG_POINTER_DENIED; goto done; }
    if (down) {
        gtk_widget_grab_focus(widget);
        if (!pointer_allowed(s,ticket.operation)) { disposition=ZLG_POINTER_DENIED; goto done; }
        gtk_grab_add(widget);
        if (!pointer_allowed(s,ticket.operation)) { disposition=ZLG_POINTER_DENIED; goto done; }
    }
    NativeEvent event={0}; event.kind=down?3:4; event.x=x; event.y=y; event.flags=(int)ticket.modifiers;
    event.context=s->pointer_enabled?&ticket:NULL;
    if (down) s->gesture=native;
    emit(s,&event);
    if (!pointer_allowed(s,ticket.operation)) { disposition=ZLG_POINTER_DENIED; goto done; }
    if (down && s->gesture_used) disposition=ZLG_POINTER_CONSUMED;
    if (s->gesture==native) s->gesture=NULL;
    if (owned_grab && gtk_widget_has_grab(widget) && gtk_window_group_get_current_grab(s->group)==widget) {
        /* A borrowed stack fact exists only around this exact own removal.
         * Nested input changes the mandatory stamp before any old tail runs. */
        s->pointer_release=&ticket;
        gtk_grab_remove(widget);
        if (s->pointer_release==&ticket) s->pointer_release=NULL;
        if (!pointer_allowed(s,ticket.operation)) disposition=ZLG_POINTER_DENIED;
    }
done:
    if (pointer_current(s,ticket.operation) && s->gesture==native) s->gesture=NULL;
    if (s->pointer_enabled) pointer_finish_enabled(s,&ticket,down,disposition);
    release(s); return handled;
}
static gboolean motion(GtkWidget *widget, GdkEventMotion *native, gpointer data) {
    (void)widget; NativeWindow *s=data; retain(s);
    const double x=native->x,y=native->y;
    uint64_t operation=s->pointer_operation;
    if (s->pointer_enabled) pointer_motion_enabled(s,native,operation);
    if (s->destroyed || s->pointer_operation!=operation) { release(s); return TRUE; }
    int hit=query_hit(s,x,y);
    if (s->destroyed || s->pointer_operation!=operation) { release(s); return TRUE; }
    if (!s->destroyed && hit!=s->cursor_hit) {
        GdkCursor *cursor=hit>=3 && hit<=10?s->resize_cursors[hit-3]:NULL;
        gdk_window_set_cursor(gtk_widget_get_window(s->area),cursor); s->cursor_hit=hit;
    }
    if (!s->destroyed && s->pointer_operation==operation) {
        NativeEvent event={0}; event.kind=5; event.x=x; event.y=y; emit(s,&event);
    }
    release(s); return TRUE;
}
static gboolean scroll(GtkWidget *widget, GdkEventScroll *native, gpointer data) {
    (void)widget; NativeEvent event={0}; event.kind=6; event.x=native->x; event.y=native->y;
    if (!gdk_event_get_scroll_deltas((GdkEvent *)native,&event.dx,&event.dy)) {
        if (native->direction==GDK_SCROLL_UP) event.dy=-1;
        if (native->direction==GDK_SCROLL_DOWN) event.dy=1;
        if (native->direction==GDK_SCROLL_LEFT) event.dx=-1;
        if (native->direction==GDK_SCROLL_RIGHT) event.dx=1;
    }
    event.dx*=48; event.dy*=48; emit(data,&event); return TRUE;
}
static gboolean focus(GtkWidget *widget, GdkEventFocus *native, gpointer data) {
    (void)widget; NativeWindow *s=data; retain(s);
    const gboolean gained=native->in;
    uint64_t operation=gained?s->pointer_operation:pointer_revoke(s,TRUE);
    if(s->im){GtkIMContext *im=g_object_ref(s->im);
        if (gained) gtk_im_context_focus_in(im); else gtk_im_context_focus_out(im);
        g_object_unref(im);}
    if (s->destroyed || s->pointer_operation!=operation) { release(s); return FALSE; }
    NativeEvent event={0}; event.kind=7; event.flags=gained?1:ZLG_POINTER_REVOKED; event.context=gained?NULL:&operation; emit(s,&event);
    if (!gained && !s->destroyed && s->pointer_operation==operation) { s->gesture=NULL; memset(s->pressed_keys,0,sizeof(s->pressed_keys)); event.kind=8; emit(s,&event); }
    if (!s->destroyed && s->pointer_operation==operation) notify_state(s);
    release(s); return FALSE;
}
static gboolean grab_broken(GtkWidget *widget, GdkEventGrabBroken *native, gpointer data) {
    (void)widget; (void)native; NativeWindow *s=data; retain(s);
    /* gtk_grab_remove only changes the GTK logical stack. A GDK broken
     * pointer/keyboard grab is a separate real loss, including during up. */
    uint64_t operation=pointer_revoke(s,FALSE);
    NativeEvent event={0}; event.kind=8; event.flags=ZLG_POINTER_REVOKED; event.context=&operation; emit(s,&event); release(s); return FALSE;
}
static void grab_notify(GtkWidget *widget, gboolean was_grabbed, gpointer data) {
    NativeWindow *s=data;
    if (was_grabbed || s->destroyed) return; /* Becoming unshadowed cannot revive. */
    retain(s);
    GtkWidget *current=gtk_window_group_get_current_grab(s->group);
    const ZlgPointerTicket *expected=s->pointer_release;
    if (expected && pointer_current(s,expected->operation) && !current && !gtk_widget_has_grab(widget)) {
        NativeEvent event={0}; event.kind=8; event.context=(void *)expected; emit(s,&event);
    } else {
        uint64_t operation=pointer_revoke(s,FALSE);
        NativeEvent event={0}; event.kind=8; event.flags=ZLG_POINTER_REVOKED; event.context=&operation; emit(s,&event);
    }
    release(s);
}
static void pointer_unmapped(GtkWidget *widget, gpointer data) {
    (void)widget; NativeWindow *s=data; retain(s);
    if (!s->destroyed) {
        uint64_t operation=pointer_revoke(s,TRUE);
        NativeEvent event={0}; event.kind=8; event.flags=ZLG_POINTER_REVOKED; event.context=&operation; emit(s,&event);
    }
    release(s);
}
static void pointer_state_flags(GtkWidget *widget, GtkStateFlags previous, gpointer data) {
    NativeWindow *s=data;
    if (s->destroyed || !((gtk_widget_get_state_flags(widget)^previous)&GTK_STATE_FLAG_INSENSITIVE)) return;
    retain(s);
    /* Observe raw GTK permission ABA too; Core's pure getter cannot probe GTK
     * later and address/allowed=true must not resurrect the old ingress. */
    uint64_t operation=pointer_revoke(s,FALSE);
    if (!gtk_widget_is_sensitive(s->window) || !gtk_widget_is_sensitive(s->area)) {
        NativeEvent event={0}; event.kind=8; event.flags=ZLG_POINTER_REVOKED; event.context=&operation; emit(s,&event);
    }
    release(s);
}
static gboolean surrounding(GtkIMContext *im, gpointer data) {
    NativeWindow *s=data; retain(s); g_object_ref(im);
    uint64_t epoch=s->im_epoch;
    if(s->destroyed || s->im!=im || s->im_suspended) { g_object_unref(im);release(s);return FALSE; }
    char bytes[12288]; NativeTextContext query={bytes,sizeof(bytes),0,0};
    NativeEvent event={0}; event.kind=20; event.context=&query;
    gboolean accepted=emit(s,&event)!=0;
    if (accepted && !s->destroyed && s->im==im && epoch==s->im_epoch && !s->im_suspended && query.length<=sizeof(bytes) && query.cursor<=query.length)
        gtk_im_context_set_surrounding(im,bytes,(gint)query.length,(gint)query.cursor);
    else accepted=FALSE;
    g_object_unref(im); release(s); return accepted;
}
static gboolean delete_surrounding(GtkIMContext *im, gint offset, gint count, gpointer data) {
    NativeWindow *s=data; retain(s); g_object_ref(im);
    uint64_t epoch=s->im_epoch;
    if(s->destroyed || s->im!=im || s->im_suspended) { g_object_unref(im);release(s);return FALSE; }
    NativeEvent event={0}; event.kind=21; event.key=offset; event.flags=count;
    gboolean accepted=emit(s,&event)!=0;
    if(s->destroyed || s->im!=im || epoch!=s->im_epoch || s->im_suspended) accepted=FALSE;
    g_object_unref(im); release(s); return accepted;
}
static void commit(GtkIMContext *im, gchar *text, gpointer data) {
    NativeWindow *s=data;retain(s);g_object_ref(im);
    if(!s->destroyed && s->im==im && !s->im_suspended) { NativeEvent event={0}; event.kind=12; event.text=text; event.length=strlen(text); emit(s,&event); }
    g_object_unref(im);release(s);
}
static void preedit_started(GtkIMContext *im, gpointer data) { NativeWindow *s=data;if(!s->destroyed && s->im==im && !s->im_suspended && s->composition_epoch<UINT64_MAX){++s->composition_epoch;s->preedit=TRUE;} }
static void preedit_ended(GtkIMContext *im, gpointer data) { NativeWindow *s=data;if(!s->destroyed && s->im==im && !s->im_suspended)s->preedit=FALSE; }
static void preedit(GtkIMContext *im, gpointer data) {
    NativeWindow *s=data; retain(s);g_object_ref(im);
    uint64_t epoch=s->im_epoch;
    if(s->destroyed || s->im!=im || s->im_suspended) {g_object_unref(im);release(s);return;}
    gchar *text=NULL; PangoAttrList *attributes=NULL; gint cursor=0;
    gtk_im_context_get_preedit_string(im,&text,&attributes,&cursor);
    if(s->destroyed || s->im!=im || epoch!=s->im_epoch || s->im_suspended){if(attributes)pango_attr_list_unref(attributes);g_free(text);g_object_unref(im);release(s);return;}
    NativeEvent event={0}; event.kind=13; event.text=text; event.length=strlen(text);
    cursor=CLAMP(cursor,0,g_utf8_strlen(text,-1)); event.selection=(size_t)(g_utf8_offset_to_pointer(text,cursor)-text);
    if (event.length) { if(!s->preedit && s->composition_epoch<UINT64_MAX)++s->composition_epoch;s->preedit=TRUE; } else event.kind=14;
    emit(s,&event); if(attributes)pango_attr_list_unref(attributes); g_free(text);g_object_unref(im); release(s);
}
static void connect_im(NativeWindow *s,GtkIMContext *im) {
    g_signal_connect(im,"retrieve-surrounding",G_CALLBACK(surrounding),s);
    g_signal_connect(im,"delete-surrounding",G_CALLBACK(delete_surrounding),s);
    g_signal_connect(im,"commit",G_CALLBACK(commit),s);g_signal_connect(im,"preedit-changed",G_CALLBACK(preedit),s);
    g_signal_connect(im,"preedit-start",G_CALLBACK(preedit_started),s);g_signal_connect(im,"preedit-end",G_CALLBACK(preedit_ended),s);
}
static gboolean key(GtkWidget *widget, GdkEventKey *native, gpointer data) {
    (void)widget; NativeWindow *s=data; retain(s);
    uint64_t epoch=s->im_epoch;
    gboolean repeat=FALSE;
    if (native->hardware_keycode>0 && native->hardware_keycode<1024) {
        uint64_t mask=UINT64_C(1)<<(native->hardware_keycode%64);
        uint64_t *word=&s->pressed_keys[native->hardware_keycode/64];
        repeat=(*word&mask)!=0;
        if (native->type==GDK_KEY_RELEASE) *word&=~mask; else *word|=mask;
    }
    NativeEvent gate={0}; gate.kind=17;
    if (!gtk_widget_is_sensitive(s->window) || !emit(s,&gate)) { release(s); return TRUE; }
    gboolean composing=s->preedit;
    GdkKeymap *map=gdk_keymap_get_for_display(gtk_widget_get_display(s->window));
    GdkModifierType modifiers=native->state, consumed=0;
    gdk_keymap_add_virtual_modifiers(map,&modifiers);
    guint logical=native->keyval, translated;
    if (native->hardware_keycode && gdk_keymap_translate_keyboard_state(map,native->hardware_keycode,
        native->state&~(GDK_SHIFT_MASK|GDK_LOCK_MASK),native->group,&translated,NULL,NULL,&consumed)) logical=translated;
    gboolean altgr=(native->state&GDK_MOD5_MASK)!=0 || logical==GDK_KEY_ISO_Level3_Shift || logical==GDK_KEY_ISO_Level5_Shift ||
        ((native->state&(GDK_CONTROL_MASK|GDK_MOD1_MASK))==(GDK_CONTROL_MASK|GDK_MOD1_MASK) && (consumed&(GDK_CONTROL_MASK|GDK_MOD1_MASK)));
    NativeEvent event={0}; event.kind=18; event.key=gdk_keyval_to_lower(logical);
    event.flags=((modifiers&GDK_SHIFT_MASK)?1:0)|((modifiers&GDK_CONTROL_MASK)?2:0)|((modifiers&GDK_MOD1_MASK)?4:0)|
        ((modifiers&(GDK_SUPER_MASK|GDK_META_MASK))?8:0)|(repeat?16:0);
    if (native->type==GDK_KEY_PRESS && !composing && !altgr && emit(s,&event)) { release(s); return TRUE; }
    if (s->destroyed || epoch!=s->im_epoch || !s->im) { release(s); return TRUE; }
    gboolean plain=(event.flags&(4|8))==0;
    if (!composing && !altgr && !plain) { release(s); return FALSE; }
    GtkIMContext *im=g_object_ref(s->im);
    gboolean handled=gtk_im_context_filter_keypress(im,native);
    g_object_unref(im);
    if (s->destroyed || epoch!=s->im_epoch) {release(s);return TRUE;}
    if (native->type==GDK_KEY_RELEASE) { release(s); return handled; }
    event.kind=9;
    int edit=-1;
    switch (native->keyval) {
        case GDK_KEY_Left: edit=0; break; case GDK_KEY_Right: edit=1; break;
        case GDK_KEY_Up: edit=2; break; case GDK_KEY_Down: edit=3; break;
        case GDK_KEY_Home: edit=4; break; case GDK_KEY_End: edit=5; break;
        case GDK_KEY_BackSpace: edit=6; break; case GDK_KEY_Delete: edit=7; break;
        case GDK_KEY_a: case GDK_KEY_A: if(event.flags&2)edit=8; break;
        case GDK_KEY_c: case GDK_KEY_C: if(event.flags&2)edit=9; break;
        case GDK_KEY_x: case GDK_KEY_X: if(event.flags&2)edit=10; break;
        case GDK_KEY_v: case GDK_KEY_V: if(event.flags&2)edit=11; break;
        case GDK_KEY_z: case GDK_KEY_Z: if(event.flags&2)edit=12; break;
        case GDK_KEY_y: case GDK_KEY_Y: if(event.flags&2)edit=13; break;
        default: break;
    }
    if (!composing && !altgr && plain && edit>=0) { event.key=edit; emit(s,&event); handled=TRUE; }
    if(s->destroyed || epoch!=s->im_epoch){release(s);return TRUE;}
    if (!composing && !altgr && plain && (native->keyval==GDK_KEY_Tab || native->keyval==GDK_KEY_ISO_Left_Tab || native->keyval==GDK_KEY_Return || native->keyval==GDK_KEY_space)) {
        event.kind=15; event.key=(native->keyval==GDK_KEY_Tab || native->keyval==GDK_KEY_ISO_Left_Tab)?0:1; emit(s,&event); handled=TRUE;
    }
    if(s->destroyed || epoch!=s->im_epoch){release(s);return TRUE;}
    if (!handled && ((plain && !(event.flags&2)) || altgr)) {
        gunichar scalar=gdk_keyval_to_unicode(native->keyval);
        if (scalar>=0x20) { gchar text[8]; int count=g_unichar_to_utf8(scalar,text); event.kind=12; event.flags=1; event.text=text; event.length=count; emit(s,&event); handled=TRUE; }
    }
    release(s); return handled;
}
NativeWindow *zlg_window_create_mode_host_pointer(void *owner, Emit callback, const char *title, uint32_t width, uint32_t height, uint32_t min_width, uint32_t min_height, NativeWindow *parent, int modal, int decoration, int resizable, int text_mode, int accessibility_host, int pointer_enabled, int *error) {
    *error=0;
    if (decoration) {
#ifdef GDK_WINDOWING_X11
        if (!GDK_IS_X11_DISPLAY(gdk_display_get_default())) { *error=1; return NULL; }
#else
        *error=1; return NULL;
#endif
    }
    NativeWindow *s=g_try_new0(NativeWindow,1); if (!s) return NULL;
    g_atomic_int_inc(&resources); s->refs=1; s->owner=owner; s->emit=callback;
    s->pointer_enabled=pointer_enabled!=0;
    s->window=gtk_window_new(GTK_WINDOW_TOPLEVEL); g_object_ref_sink(s->window); track(G_OBJECT(s->window));
    s->decoration=decoration; s->cursor_hit=-1;
    gtk_window_set_decorated(GTK_WINDOW(s->window),decoration==0);
    gtk_window_set_resizable(GTK_WINDOW(s->window),resizable);
    if (decoration) {
        const char *names[8]={"nw-resize","n-resize","ne-resize","w-resize","e-resize","sw-resize","s-resize","se-resize"};
        for (int i=0;i<8;i++) s->resize_cursors[i]=gdk_cursor_new_from_name(gtk_widget_get_display(s->window),names[i]);
    }
    s->group=parent?g_object_ref(parent->group):gtk_window_group_new();
    if (!parent) track(G_OBJECT(s->group));
    guint members=GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(s->group),"ziggurat-window-members"));
    g_object_set_data(G_OBJECT(s->group),"ziggurat-window-members",GUINT_TO_POINTER(members+1));
    gtk_window_group_add_window(s->group,GTK_WINDOW(s->window));
    if (parent) gtk_window_set_transient_for(GTK_WINDOW(s->window),GTK_WINDOW(parent->window));
    gtk_window_set_modal(GTK_WINDOW(s->window),modal);
    s->area=accessibility_host?accessibility_area_new(s):gtk_drawing_area_new(); g_object_ref_sink(s->area); track(G_OBJECT(s->area));
    gtk_container_add(GTK_CONTAINER(s->window),s->area);
    g_object_set_data(G_OBJECT(s->window),"ziggurat-native-window",s);
    gtk_widget_set_can_focus(s->area,TRUE);
    gtk_widget_add_events(s->area,GDK_BUTTON_PRESS_MASK|GDK_BUTTON_RELEASE_MASK|GDK_POINTER_MOTION_MASK|GDK_SCROLL_MASK|GDK_SMOOTH_SCROLL_MASK|GDK_FOCUS_CHANGE_MASK|GDK_KEY_PRESS_MASK|GDK_KEY_RELEASE_MASK);
    gtk_widget_add_events(s->window,GDK_PROPERTY_CHANGE_MASK);
    gtk_window_set_title(GTK_WINDOW(s->window),title); gtk_window_set_default_size(GTK_WINDOW(s->window),width,height);
    gtk_window_set_gravity(GTK_WINDOW(s->window),GDK_GRAVITY_STATIC);
    s->normal_width=width; s->normal_height=height;
    if(min_width||min_height) { GdkGeometry limits={0}; limits.min_width=MAX(1,min_width); limits.min_height=MAX(1,min_height); gtk_window_set_geometry_hints(GTK_WINDOW(s->window),NULL,&limits,GDK_HINT_MIN_SIZE); }
    gtk_widget_show(s->area); gtk_widget_realize(s->window); gtk_widget_realize(s->area);
    s->im=text_mode?gtk_im_context_simple_new():gtk_im_multicontext_new(); track(G_OBJECT(s->im)); gtk_im_context_set_client_window(s->im,gtk_widget_get_window(s->area));
    g_signal_connect(s->window,"delete-event",G_CALLBACK(deleted),s); g_signal_connect(s->window,"destroy",G_CALLBACK(destroyed),s);
    g_signal_connect(s->area,"draw",G_CALLBACK(draw),s); g_signal_connect(s->window,"configure-event",G_CALLBACK(configured),s);
    g_signal_connect(s->area,"size-allocate",G_CALLBACK(allocated),s);
    g_signal_connect(s->area,"notify::scale-factor",G_CALLBACK(scale_changed),s);
    g_signal_connect(s->window,"window-state-event",G_CALLBACK(state_changed),s);
    g_signal_connect(s->window,"property-notify-event",G_CALLBACK(property_changed),s);
    g_signal_connect(s->area,"button-press-event",G_CALLBACK(button),s); g_signal_connect(s->area,"button-release-event",G_CALLBACK(button),s);
    g_signal_connect(s->area,"motion-notify-event",G_CALLBACK(motion),s); g_signal_connect(s->area,"scroll-event",G_CALLBACK(scroll),s);
    g_signal_connect(s->area,"focus-in-event",G_CALLBACK(focus),s); g_signal_connect(s->area,"focus-out-event",G_CALLBACK(focus),s);
    g_signal_connect(s->area,"grab-broken-event",G_CALLBACK(grab_broken),s);
    if (s->pointer_enabled) {
        g_signal_connect(s->area,"grab-notify",G_CALLBACK(grab_notify),s);
        g_signal_connect(s->area,"unmap",G_CALLBACK(pointer_unmapped),s);
        g_signal_connect(s->area,"state-flags-changed",G_CALLBACK(pointer_state_flags),s);
        g_signal_connect(s->window,"state-flags-changed",G_CALLBACK(pointer_state_flags),s);
    }
    g_signal_connect(s->area,"key-press-event",G_CALLBACK(key),s); g_signal_connect(s->area,"key-release-event",G_CALLBACK(key),s);
    connect_im(s,s->im);
    return s;
}
NativeWindow *zlg_window_create_mode_host(void *owner, Emit callback, const char *title, uint32_t width, uint32_t height, uint32_t min_width, uint32_t min_height, NativeWindow *parent, int modal, int decoration, int resizable, int text_mode, int accessibility_host, int *error) {
    return zlg_window_create_mode_host_pointer(owner,callback,title,width,height,min_width,min_height,parent,modal,decoration,resizable,text_mode,accessibility_host,0,error);
}
NativeWindow *zlg_window_create_mode(void *owner, Emit callback, const char *title, uint32_t width, uint32_t height, uint32_t min_width, uint32_t min_height, NativeWindow *parent, int modal, int decoration, int resizable, int text_mode, int *error) {
    return zlg_window_create_mode_host(owner,callback,title,width,height,min_width,min_height,parent,modal,decoration,resizable,text_mode,0,error);
}
NativeWindow *zlg_window_create(void *owner, Emit callback, const char *title, uint32_t width, uint32_t height, uint32_t min_width, uint32_t min_height, NativeWindow *parent, int modal, int decoration, int resizable, int *error) {
    return zlg_window_create_mode(owner,callback,title,width,height,min_width,min_height,parent,modal,decoration,resizable,0,error);
}
int zlg_window_destroy(NativeWindow *s) { retain(s); pointer_retire(s); accessibility_parent_destroying(s); gtk_widget_destroy(s->window); int done=s->destroyed; release(s); return done; }
void *zlg_window_handle(NativeWindow *s) { return s->window; }
void zlg_window_action(NativeWindow *s, int action) {
    retain(s);
    if (action==1 || action==7) s->gesture=NULL;
    switch(action) {
        case 0: gtk_widget_show(s->window); break; case 1: gtk_widget_hide(s->window); break;
        case 2: gtk_window_iconify(GTK_WINDOW(s->window)); break; case 3: gtk_window_maximize(GTK_WINDOW(s->window)); break;
        case 4: gtk_window_unmaximize(GTK_WINDOW(s->window)); if(!s->destroyed)gtk_window_deiconify(GTK_WINDOW(s->window)); break;
        case 5: gtk_window_present(GTK_WINDOW(s->window)); if(!s->destroyed)gtk_widget_grab_focus(s->area); break;
        case 6: gtk_widget_set_sensitive(s->window,TRUE); break; case 7: gtk_widget_set_sensitive(s->window,FALSE); break;
    }
    release(s);
}
uint32_t zlg_window_state(NativeWindow *s) {
    GdkWindowState state=window_state(s);
    return (gtk_widget_get_visible(s->window)?1:0)|((state&GDK_WINDOW_STATE_ICONIFIED)?2:0)|((state&GDK_WINDOW_STATE_MAXIMIZED)?4:0)|
        (gtk_window_is_active(GTK_WINDOW(s->window))?8:0)|(gtk_widget_is_sensitive(s->window)?16:0)|
        ((state&GDK_WINDOW_STATE_FULLSCREEN)?32:0)|(s->fullscreen_requested?64:0)|
        (s->above_observed?128:0)|(s->above_requested?256:0);
}
void zlg_window_bounds(NativeWindow *s, NativeBounds *bounds) {
    gint width,height; gtk_window_get_size(GTK_WINDOW(s->window),&width,&height);
    bounds->width=MAX(0,width); bounds->height=MAX(0,height);
    bounds->positioned=(zlg_window_capabilities(s)&1u)!=0; bounds->x=0; bounds->y=0;
    if (bounds->positioned) gtk_window_get_position(GTK_WINDOW(s->window),&bounds->x,&bounds->y);
}
void zlg_window_size(NativeWindow *s, uint32_t *width, uint32_t *height, uint32_t *scale) {
    guint factor=MAX(1,gtk_widget_get_scale_factor(s->area));
    *width=(uint32_t)MAX(0,gtk_widget_get_allocated_width(s->area))*factor;
    *height=(uint32_t)MAX(0,gtk_widget_get_allocated_height(s->area))*factor;
    *scale=factor;
}
int zlg_window_set_bounds(NativeWindow *s, const NativeBounds *bounds) {
    if (bounds->positioned && !(zlg_window_capabilities(s)&1u)) return 1;
    if (s->restore_pending) return 3;
    retain(s);
    gtk_window_resize(GTK_WINDOW(s->window),bounds->width,bounds->height);
    if (!s->destroyed && bounds->positioned) gtk_window_move(GTK_WINDOW(s->window),bounds->x,bounds->y);
    if (!s->destroyed) {
        s->normal_width=bounds->width; s->normal_height=bounds->height;
        if (bounds->positioned) { s->normal_x=bounds->x; s->normal_y=bounds->y; }
    }
    int result=s->destroyed?2:0; release(s); return result;
}
int zlg_window_fullscreen(NativeWindow *s, int enabled) {
    if (enabled && !(zlg_window_capabilities(s)&2u)) return 1;
    gboolean observed=(window_state(s)&GDK_WINDOW_STATE_FULLSCREEN)!=0;
    if (!!enabled==s->fullscreen_requested && !!enabled==observed && !s->restore_pending) return 0;
    retain(s);
    if (enabled) {
        if (!s->saved_geometry) {
            remember_normal(s); GdkWindowState state=window_state(s);
            s->saved_x=s->normal_x; s->saved_y=s->normal_y; s->saved_width=s->normal_width; s->saved_height=s->normal_height;
            s->saved_maximized=(state&GDK_WINDOW_STATE_MAXIMIZED)!=0; s->saved_minimized=(state&GDK_WINDOW_STATE_ICONIFIED)!=0;
            s->saved_geometry=TRUE;
        }
        s->restore_pending=FALSE; s->fullscreen_requested=TRUE;
        gtk_window_deiconify(GTK_WINDOW(s->window));
        if (!s->destroyed) gtk_window_fullscreen(GTK_WINDOW(s->window));
    } else {
        s->fullscreen_requested=FALSE; s->restore_pending=s->saved_geometry;
        gtk_window_unfullscreen(GTK_WINDOW(s->window));
        if (!s->destroyed) restore_geometry(s);
    }
    int result=s->destroyed?2:0; release(s); return result;
}
int zlg_window_topmost(NativeWindow *s, int enabled) {
    if (enabled && !(zlg_window_capabilities(s)&4u)) return 1;
    retain(s); s->above_requested=!!enabled;
    gtk_window_set_keep_above(GTK_WINDOW(s->window),enabled);
    int result=s->destroyed?2:0; release(s); return result;
}
/* Places a system menu bar above the window's child, replaces it, or removes
   it with NULL. The window keeps its own reference while the bar is attached.
   Moving the child re-realizes the drawing area and rebinds its input method.
   Returns 0, 2 when the window is closing, or 3 while content is changing. */
int zlg_window_set_menubar(GtkWidget *toplevel, GtkWidget *bar) {
    NativeWindow *s=toplevel?g_object_get_data(G_OBJECT(toplevel),"ziggurat-native-window"):NULL;
    if (!s || !content_live(s)) return 2;
    if (s->content_busy) return 3;
    if (bar==s->menu_bar) return 0;
    retain(s);
    if (s->menu_bar) {
        GtkWidget *old=s->menu_bar; s->menu_bar=NULL;
        if (gtk_widget_get_parent(old)==s->menu_box) gtk_container_remove(GTK_CONTAINER(s->menu_box),old);
        g_object_unref(old);
    }
    if (!content_live(s)) goto done;
    if (bar && s->menu_box) {
        s->menu_bar=g_object_ref(bar);
        gtk_box_pack_start(GTK_BOX(s->menu_box),bar,FALSE,FALSE,0);
        gtk_box_reorder_child(GTK_BOX(s->menu_box),bar,0);
        gtk_widget_show(bar);
    } else if (bar || s->menu_box) {
        GtkWidget *from=s->menu_box?s->menu_box:s->window, *child=NULL;
        GList *children=gtk_container_get_children(GTK_CONTAINER(from));
        if (children) child=g_object_ref(children->data);
        g_list_free(children);
        content_cancel_input(s);
        if (child && content_live(s)) gtk_container_remove(GTK_CONTAINER(from),child);
        if (bar && content_live(s)) {
            s->menu_box=gtk_box_new(GTK_ORIENTATION_VERTICAL,0); g_object_ref_sink(s->menu_box); track(G_OBJECT(s->menu_box));
            s->menu_bar=g_object_ref(bar);
            gtk_box_pack_start(GTK_BOX(s->menu_box),bar,FALSE,FALSE,0);
            gtk_container_add(GTK_CONTAINER(s->window),s->menu_box);
            gtk_widget_show(bar); gtk_widget_show(s->menu_box);
        } else if (s->menu_box) {
            GtkWidget *box=s->menu_box; s->menu_box=NULL;
            if (content_live(s)) gtk_container_remove(GTK_CONTAINER(s->window),box);
            gtk_widget_destroy(box); g_object_unref(box);
        }
        if (child) { if (content_live(s) && !gtk_widget_get_parent(child)) root_add(s,child); g_object_unref(child); }
        if (content_live(s)) gtk_widget_realize(s->area);
        content_bind_im(s);
    }
done:;
    int result=s->destroyed?2:0; release(s); return result;
}
/* Applies WindowTraits. Minimize, maximize and move reach the window manager
   as Motif function hints on X11; other displays keep the GTK part only.
   Returns 0, or 2 when the window is closing. */
int zlg_window_traits(NativeWindow *s, int resizable, int movable, int minimizable, int maximizable, int closable) {
    retain(s);
    if (s->destroyed) { release(s); return 2; }
    GtkWindow *window=GTK_WINDOW(s->window);
    if (!resizable && gtk_window_get_resizable(window)) {
        /* A fixed window would otherwise shrink to its natural size. */
        int width=0,height=0; gtk_window_get_size(window,&width,&height);
        gtk_window_set_default_size(window,width,height);
    }
    gtk_window_set_resizable(window,resizable);
    gtk_window_set_deletable(window,closable);
    s->immovable=!movable; s->no_maximize=!maximizable;
#ifdef GDK_WINDOWING_X11
    if (!s->destroyed && GDK_IS_X11_DISPLAY(gtk_widget_get_display(s->window))) {
        if (!gtk_widget_get_realized(s->window)) gtk_widget_realize(s->window);
        GdkWindow *native=gtk_widget_get_window(s->window);
        GdkWMFunction functions=GDK_FUNC_ALL;
        if (!resizable || !movable || !minimizable || !maximizable || !closable) {
            functions=0;
            if (resizable) functions|=GDK_FUNC_RESIZE;
            if (movable) functions|=GDK_FUNC_MOVE;
            if (minimizable) functions|=GDK_FUNC_MINIMIZE;
            if (maximizable && resizable) functions|=GDK_FUNC_MAXIMIZE;
            if (closable) functions|=GDK_FUNC_CLOSE;
        }
        if (native) gdk_window_set_functions(native,functions);
    }
#endif
    int result=s->destroyed?2:0; release(s); return result;
}
void zlg_window_opacity(NativeWindow *s, double opacity) { retain(s);gtk_widget_set_opacity(s->window,opacity);release(s); }
/* An empty input shape lets the pointer reach the windows below. */
void zlg_window_ignore_pointer(NativeWindow *s, int enabled) {
    retain(s);
    cairo_region_t *empty=enabled?cairo_region_create():NULL;
    gtk_widget_input_shape_combine_region(s->window,empty);
    if (empty) cairo_region_destroy(empty);
    release(s);
}
void zlg_window_urgent(NativeWindow *s, int enabled) { retain(s);gtk_window_set_urgency_hint(GTK_WINDOW(s->window),enabled);release(s); }
void zlg_window_skip_taskbar(NativeWindow *s, int enabled) { retain(s);gtk_window_set_skip_taskbar_hint(GTK_WINDOW(s->window),enabled);release(s); }
void zlg_window_title(NativeWindow *s, const char *title) { retain(s);gtk_window_set_title(GTK_WINDOW(s->window),title);release(s); }
void zlg_window_resize(NativeWindow *s, uint32_t width, uint32_t height) { retain(s);gtk_window_resize(GTK_WINDOW(s->window),width,height);release(s); }
void zlg_window_invalidate(NativeWindow *s) { gtk_widget_queue_draw(s->area); }
void zlg_window_invalidate_rect(NativeWindow *s, int left, int top, int right, int bottom) {
    right=MIN(right,gtk_widget_get_allocated_width(s->area));
    bottom=MIN(bottom,gtk_widget_get_allocated_height(s->area));
    if (right>left && bottom>top) gtk_widget_queue_draw_area(s->area,left,top,right-left,bottom-top);
}
void zlg_window_caret(NativeWindow *s, int x, int y, int width, int height) { s->caret=(GdkRectangle){x,y,width,height};if(!s->im)return;GtkIMContext *im=g_object_ref(s->im);gtk_im_context_set_cursor_location(im,&s->caret);g_object_unref(im); }
void zlg_window_cancel_composition(NativeWindow *s) { if(!s->im)return;GtkIMContext *im=g_object_ref(s->im);gtk_im_context_reset(im);g_object_unref(im); }
int zlg_window_cancel_text_for_mode(NativeWindow *s) {
    retain(s);GtkIMContext *im=g_object_ref(s->im);uint64_t epoch=s->composition_epoch;
    gboolean was=s->preedit;s->preedit=FALSE;
    if(was){NativeEvent event={0};event.kind=14;emit(s,&event);}
    gboolean current=!s->destroyed && s->im==im && epoch==s->composition_epoch && !s->preedit;
    if(current){s->im_suspended=TRUE;gtk_im_context_reset(im);s->im_suspended=FALSE;current=!s->destroyed && s->im==im && epoch==s->composition_epoch && !s->preedit;}
    g_object_unref(im);release(s);return current;
}
/* Every real transition installs a fresh context. A late engine signal cannot
   revive authority when the Window returns to a previously selected mode. */
int zlg_window_text_mode(NativeWindow *s,int mode,void *guard,int (*current)(void *)) {
    retain(s);
    if(s->destroyed){release(s);return 2;}
    if(s->im_epoch==UINT64_MAX){release(s);return 6;}
    GtkIMContext *old=s->im,*next=mode?gtk_im_context_simple_new():gtk_im_multicontext_new();
    uint64_t composition_epoch=s->composition_epoch;
    track(G_OBJECT(next));connect_im(s,next);
    gtk_im_context_set_client_window(next,gtk_widget_get_window(s->area));
    gtk_im_context_set_cursor_location(next,&s->caret);
    if(s->destroyed || s->im!=old || s->preedit || s->composition_epoch!=composition_epoch || !current(guard)){
        g_signal_handlers_disconnect_by_data(next,s);gtk_im_context_set_client_window(next,NULL);g_object_unref(next);release(s);return 2;
    }
    /* Commit before foreign teardown. Rebinding/close after this point sees
       the new native owner and selected policy; it cannot turn success into
       a retryable failure. The old owner reference is now held by this call. */
    s->im=g_object_ref(next);++s->im_epoch;
    NativeEvent event={0};event.kind=23;event.flags=mode;emit(s,&event);
    g_signal_handlers_disconnect_by_data(old,s);
    gtk_im_context_focus_out(old);gtk_im_context_reset(old);gtk_im_context_set_client_window(old,NULL);
    if(!s->destroyed && s->im==next && gtk_widget_has_focus(s->area))gtk_im_context_focus_in(next);
    g_object_unref(next);
    g_object_unref(old);release(s);return 0;
}
void zlg_test_paint(NativeWindow *s, uint32_t width, uint32_t height) {
    retain(s); GtkAllocation allocation={0,0,width,height}; gtk_widget_size_allocate(s->area,&allocation);
    cairo_surface_t *surface=cairo_image_surface_create(CAIRO_FORMAT_ARGB32,width,height); cairo_t *cr=cairo_create(surface);
    gboolean handled=FALSE; g_signal_emit_by_name(s->area,"draw",cr,&handled); cairo_destroy(cr); cairo_surface_destroy(surface); release(s);
}
void zlg_test_close(NativeWindow *s) { NativeEvent event={0}; event.kind=10; emit(s,&event); }
void zlg_test_commit(NativeWindow *s, const char *text) { retain(s);GtkIMContext *im=g_object_ref(s->im);g_signal_emit_by_name(im,"commit",text);g_object_unref(im);release(s); }
int zlg_test_text_mode_simple(NativeWindow *s) { return s->im && GTK_IS_IM_CONTEXT_SIMPLE(s->im); }
void zlg_test_text_key(NativeWindow *s,unsigned keyval,unsigned modifiers) {
    GdkEventKey event={0};event.type=GDK_KEY_PRESS;event.window=gtk_widget_get_window(s->area);event.keyval=keyval;event.state=modifiers;
    key(s->area,&event,s);
}
void zlg_test_text_key_release(NativeWindow *s,unsigned keyval,unsigned modifiers) {
    GdkEventKey event={0};event.type=GDK_KEY_RELEASE;event.window=gtk_widget_get_window(s->area);event.keyval=keyval;event.state=modifiers;
    key(s->area,&event,s);
}
void zlg_test_preedit_start(NativeWindow *s) { retain(s);GtkIMContext *im=g_object_ref(s->im);g_signal_emit_by_name(im,"preedit-start");g_object_unref(im);release(s); }
void *zlg_test_text_context_hold(NativeWindow *s) { return g_object_ref(s->im); }
int zlg_test_retired_text_signals(GtkIMContext *im) {
    g_signal_emit_by_name(im,"commit","STALE");g_signal_emit_by_name(im,"preedit-start");
    g_signal_emit_by_name(im,"preedit-changed");g_signal_emit_by_name(im,"preedit-end");
    gboolean surrounding_accepted=FALSE,delete_accepted=FALSE;
    g_signal_emit_by_name(im,"retrieve-surrounding",&surrounding_accepted);
    g_signal_emit_by_name(im,"delete-surrounding",0,1,&delete_accepted);
    return !surrounding_accepted && !delete_accepted;
}

int zlg_test_surrounding(NativeWindow *s, char *destination, size_t capacity, size_t *length, size_t *cursor) {
    retain(s); GtkIMContext *im=g_object_ref(s->im); char *text=NULL; gint index=0;
    gboolean accepted=gtk_im_context_get_surrounding(im,&text,&index);
    if (accepted) {
        size_t n=strlen(text); accepted=n<=capacity && index>=0 && (size_t)index<=n;
        if (accepted) { memcpy(destination,text,n); *length=n; *cursor=(size_t)index; }
    }
    g_free(text); g_object_unref(im); release(s); return accepted;
}
int zlg_test_delete_surrounding(NativeWindow *s, int offset, int count) {
    retain(s); GtkIMContext *im=g_object_ref(s->im);
    gboolean accepted=gtk_im_context_delete_surrounding(im,offset,count);
    g_object_unref(im); release(s); return accepted;
}
