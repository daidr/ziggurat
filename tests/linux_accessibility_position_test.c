/* Native coordinate/lifetime oracle; GTK's real AtkComponent is independent
 * of the private snapshot. No document model, AT-SPI client or visual QA. */
#include <stdio.h>
#include <string.h>
#include "../src/platform/linux.c"

#define CHECK(c) do { if (!(c)) { fprintf(stderr,"FAIL %d: %s\n",__LINE__,#c); return 1; } } while (0)
static unsigned invalidations;
static int event(void *unused, const NativeEvent *ev) { (void)unused;(void)ev;return 0; }
static void dispatch(void *unused) { (void)unused; }
static void invalidate(void *object) { (void)object;++invalidations; }
static void settle(void) { while (g_main_context_pending(NULL)) g_main_context_iteration(NULL,FALSE); }
typedef struct WrongThread { ZlgAccessibilityBinding *binding; int result; ZlgAccessibilityPosition out; } WrongThread;
typedef struct Reentry { ZlgAccessibilityBinding *binding; ZlgAccessibilityPosition out; int result; unsigned calls; } Reentry;
static void added(AtkObject *host, guint index, AtkObject *child, gpointer data) {
    (void)host;(void)index;(void)child;
    Reentry *probe=data; ++probe->calls;
    probe->result=zlg_accessibility_position(probe->binding,&probe->out);
}
static gpointer wrong_thread(gpointer data) {
    WrongThread *probe=data;
    probe->result=zlg_accessibility_position(probe->binding,&probe->out);
    return NULL;
}
static int sdk_equal(NativeWindow *native, ZlgAccessibilityBinding *binding, int expected_x, int expected_y) {
    ZlgAccessibilityPosition p={0};
    CHECK(zlg_accessibility_position(binding,&p)==ZLG_ACCESSIBILITY_OK);
    CHECK(p.flags==(ZLG_ACCESSIBILITY_EXTENT|ZLG_ACCESSIBILITY_WINDOW_ORIGIN|ZLG_ACCESSIBILITY_SCREEN_ORIGIN));
    CHECK(p.scale==(unsigned)gtk_widget_get_scale_factor(native->area));
    AtkObject *host=gtk_widget_get_accessible(native->area);
    gint x,y,w,h;
    atk_component_get_extents(ATK_COMPONENT(host),&x,&y,&w,&h,ATK_XY_WINDOW);
    CHECK(p.window_x==x && p.window_y==y && p.width==(unsigned)w && p.height==(unsigned)h);
    CHECK(x==expected_x && y==expected_y);
    atk_component_get_extents(ATK_COMPONENT(host),&x,&y,&w,&h,ATK_XY_SCREEN);
    CHECK(p.screen_x==x && p.screen_y==y && p.width==(unsigned)w && p.height==(unsigned)h);
    printf("position SDK equal: scale=%u window=%d,%d screen=%d,%d extent=%u,%u\n",
        p.scale,p.window_x,p.window_y,p.screen_x,p.screen_y,p.width,p.height);
    return 0;
}
int main(void) {
    _Static_assert(sizeof(ZlgAccessibilityPosition)==32,"position POD");
    int error=0;
    NativeApp *app=zlg_app_create(NULL,dispatch,&error);
    CHECK(app && !error);
    unsigned app_resources=zlg_resource_count();
    NativeWindow *native=zlg_window_create_mode_host(NULL,event,"position oracle",320,220,0,0,NULL,0,0,1,0,1,&error);
    CHECK(native && !error);
    retain(native);
    AtkObject *child=g_object_new(ATK_TYPE_OBJECT,NULL);
    ZlgAccessibilityBinding *binding=NULL;
    CHECK(zlg_accessibility_prepare(native,child,invalidate,&binding)==ZLG_ACCESSIBILITY_OK);
    ZlgAccessibilityPosition p={0};
    CHECK(zlg_accessibility_position(binding,&p)==ZLG_ACCESSIBILITY_OK);
    CHECK(p.flags==ZLG_ACCESSIBILITY_EXTENT && p.scale>=1 && !p.window_x && !p.window_y && !p.screen_x && !p.screen_y);
    ZlgAccessibilityPosition sentinel;
    memset(&sentinel,0x5a,sizeof sentinel);
    p=sentinel;
    CHECK(zlg_accessibility_position(NULL,&p)==ZLG_ACCESSIBILITY_INVALID && !memcmp(&p,&sentinel,sizeof p));
    CHECK(zlg_accessibility_position(binding,NULL)==ZLG_ACCESSIBILITY_INVALID);
    WrongThread thread_probe={.binding=binding,.out=sentinel};
    GThread *thread=g_thread_new("position-invalid",wrong_thread,&thread_probe);
    g_thread_join(thread); /* Test worker only; no UI work or application waits. */
    CHECK(thread_probe.result==ZLG_ACCESSIBILITY_INVALID && !memcmp(&thread_probe.out,&sentinel,sizeof sentinel));
    ZlgAccessibilityArea *area=(ZlgAccessibilityArea *)native->area;
    ++area->notifying;
    CHECK(zlg_accessibility_position(binding,&p)==ZLG_ACCESSIBILITY_BUSY && !memcmp(&p,&sentinel,sizeof p));
    --area->notifying;
    /* Move the actual original area under a real offset parent, retaining its
     * existing owner and binding refs across reparenting. No replacement child. */
    g_object_ref(native->area);
    gtk_container_remove(GTK_CONTAINER(native->window),native->area);
    GtkWidget *fixed=gtk_fixed_new();
    gtk_container_add(GTK_CONTAINER(native->window),fixed);
    gtk_widget_set_size_request(native->area,180,90);
    gtk_fixed_put(GTK_FIXED(fixed),native->area,17,23);
    g_object_unref(native->area);
    gtk_window_move(GTK_WINDOW(native->window),40,50);
    gtk_widget_show_all(native->window); settle();
    CHECK(sdk_equal(native,binding,17,23)==0); /* PREPARED coordinates are valid. */
    Reentry reentry={.binding=binding,.out=sentinel};
    AtkObject *host=gtk_widget_get_accessible(native->area);
    gulong signal=g_signal_connect(host,"children-changed::add",G_CALLBACK(added),&reentry);
    CHECK(zlg_accessibility_mount(binding)==ZLG_ACCESSIBILITY_OK);
    g_signal_handler_disconnect(host,signal);
    CHECK(reentry.calls==1 && reentry.result==ZLG_ACCESSIBILITY_BUSY && !memcmp(&reentry.out,&sentinel,sizeof sentinel));
    CHECK(sdk_equal(native,binding,17,23)==0);
    gtk_fixed_move(GTK_FIXED(fixed),native->area,31,37);
    gtk_widget_queue_resize(fixed); settle();
    /* GTK's frame clock may defer allocation; the test explicitly allocates
     * the parent instead of introducing a timer or sleeping on UI work. */
    GtkAllocation allocation; gtk_widget_get_allocation(fixed,&allocation);
    gtk_widget_size_allocate(fixed,&allocation);
    CHECK(sdk_equal(native,binding,31,37)==0);
    /* Native WMs can place the top-level at a physical coordinate not divisible
     * by scale. At negative odd pixels, rounding the child origin independently
     * is observably different from GTK's parent-origin plus logical allocation. */
    GdkWindow *top=gdk_window_get_toplevel(gtk_widget_get_window(native->area));
    XMoveWindow(GDK_WINDOW_XDISPLAY(top),GDK_WINDOW_XID(top),-1,-1);
    XSync(GDK_WINDOW_XDISPLAY(top),False); settle();
    int actual_x,actual_y; Window unused_child;
    Window root_xid=GDK_WINDOW_XID(gdk_screen_get_root_window(gdk_window_get_screen(top)));
    CHECK(XTranslateCoordinates(GDK_WINDOW_XDISPLAY(top),GDK_WINDOW_XID(top),root_xid,0,0,&actual_x,&actual_y,&unused_child));
    CHECK(actual_x==-1 && actual_y==-1);
    CHECK(sdk_equal(native,binding,31,37)==0);
    ZlgAccessibilityPosition before_move;
    CHECK(zlg_accessibility_position(binding,&before_move)==ZLG_ACCESSIBILITY_OK);
    gtk_window_move(GTK_WINDOW(native->window),120,140); settle();
    CHECK(sdk_equal(native,binding,31,37)==0);
    CHECK(zlg_accessibility_position(binding,&p)==ZLG_ACCESSIBILITY_OK);
    CHECK(p.screen_x!=before_move.screen_x && p.screen_y!=before_move.screen_y);
    gtk_widget_hide(native->window); settle();
    CHECK(zlg_accessibility_position(binding,&p)==ZLG_ACCESSIBILITY_OK && p.flags==ZLG_ACCESSIBILITY_EXTENT);
    gtk_widget_destroy(native->area);
    CHECK(invalidations==1);
    p=sentinel;
    CHECK(zlg_accessibility_position(binding,&p)==ZLG_ACCESSIBILITY_CLOSED && !memcmp(&p,&sentinel,sizeof p));
    zlg_window_destroy(native); release(native);
    CHECK(zlg_resource_count()==app_resources);
    /* A different live binding is retired by raw top-level destroy directly. */
    native=zlg_window_create_mode_host(NULL,event,"position raw close",80,60,0,0,NULL,0,0,1,0,1,&error);
    CHECK(native && !error);
    ZlgAccessibilityBinding *raw_binding=NULL;
    AtkObject *raw_child=g_object_new(ATK_TYPE_OBJECT,NULL);
    CHECK(zlg_accessibility_prepare(native,raw_child,invalidate,&raw_binding)==ZLG_ACCESSIBILITY_OK);
    CHECK(zlg_accessibility_mount(raw_binding)==ZLG_ACCESSIBILITY_OK);
    gtk_widget_destroy(native->window);
    CHECK(invalidations==2 && zlg_resource_count()==app_resources);
    p=sentinel;
    CHECK(zlg_accessibility_position(raw_binding,&p)==ZLG_ACCESSIBILITY_CLOSED && !memcmp(&p,&sentinel,sizeof p));
    zlg_accessibility_release(raw_binding); g_object_unref(raw_child);
    zlg_app_destroy(app); CHECK(zlg_resource_count()==0);
    CHECK(zlg_accessibility_position(binding,&p)==ZLG_ACCESSIBILITY_CLOSED && !memcmp(&p,&sentinel,sizeof p));
    zlg_accessibility_release(binding); g_object_unref(child);
    unsigned tokens,registered,mounted;
    zlg_accessibility_counts(&tokens,&registered,&mounted);
    CHECK(!tokens && !registered && !mounted);
    printf("position PASS: prepared/mounted, offset/move, SDK coordinates, hidden/unavailable, invalid/thread/busy/closed preserve; POD=%zu token=%zu native=%zu\n",
        sizeof(ZlgAccessibilityPosition),sizeof(ZlgAccessibilityBinding),sizeof(NativeWindow));
    return 0;
}
