/* GTK adapter/ABI oracle. The sink records native transitions and returns only
 * pairing sequences; it has no click classifier/history or semantic owner.
 * Direct event values below are an explicit deterministic private oracle, not
 * evidence of a human device clock or a UI control's multi-click action. */
#include <gtk/gtk.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../src/platform/linux_pointer.h"

static void (*settings_reentry)(void);
static unsigned settings_reads;
static unsigned extra_connections;
static gulong pointer_test_connect(gpointer instance, const gchar *name, GCallback callback, gpointer data, GClosureNotify destroy, GConnectFlags flags) {
    if (strcmp(name,"grab-notify")==0 || strcmp(name,"unmap")==0 || strcmp(name,"state-flags-changed")==0) ++extra_connections;
    return g_signal_connect_data(instance,name,callback,data,destroy,flags);
}
static void G_GNUC_UNUSED pointer_test_get(gpointer object, const gchar *first, ...) {
    va_list args; va_start(args,first); g_object_get_valist(G_OBJECT(object),first,args); va_end(args);
    if (strcmp(first,"gtk-double-click-time")==0) {
        ++settings_reads;
        void (*callback)(void)=settings_reentry; settings_reentry=NULL;
        if (callback) callback();
    }
}
#define g_object_get pointer_test_get
#define g_signal_connect_data pointer_test_connect
#ifndef ZLG_POINTER_NATIVE_FILE
#define ZLG_POINTER_NATIVE_FILE "../src/platform/linux.c"
#endif
#include ZLG_POINTER_NATIVE_FILE
#undef g_object_get
#undef g_signal_connect_data

#define CHECK(value) do { if (!(value)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#value); exit(1); } } while (0)
typedef struct Test {
    NativeWindow *native;
    unsigned closed, down, up, cancel, began, finished, motion, loss, domain, hits, connections;
    uint64_t issued, pair[5], delivered_sequence;
    ZlgPointerFacts last_begin, last_motion;
    gboolean allowed, nest_on_up, close_on_down, hit_requires_motion;
    double delivered_x,delivered_y;
} Test;
static Test *foreign_test;
static GdkEventButton *foreign_event;

static void inject(Test *, GdkEventType, guint, guint32, double, double);
static int sink(void *context, const NativeEvent *event) {
    Test *test=context;
    if (event->kind==17) return test->allowed;
    if (event->kind==19) {
        if (test->hit_requires_motion) { CHECK(test->motion>0); test->hit_requires_motion=FALSE; }
        ++test->hits; return 0;
    }
    if (event->kind==11) { ++test->closed; return 0; }
    if (event->kind==24) {
        ZlgPointerFacts *facts=event->context;
        CHECK(facts->phase<=6 && facts->qualified<=1 && facts->modifiers<=15);
#ifndef ZLG_POINTER_LEGACY
        CHECK(facts->operation==test->native->pointer_operation);
#endif
        switch (facts->phase) {
            case ZLG_POINTER_DOWN_BEGIN:
                ++test->began; test->last_begin=*facts;
                facts->sequence=facts->button<5?++test->issued:0;
                if (facts->button<5) test->pair[facts->button]=facts->sequence;
                break;
            case ZLG_POINTER_UP_BEGIN:
                ++test->began; test->last_begin=*facts;
                facts->sequence=facts->button<5?test->pair[facts->button]:0;
                break;
            case ZLG_POINTER_DOWN_FINISH: ++test->finished; break;
            case ZLG_POINTER_UP_FINISH:
                ++test->finished;
                if (facts->button<5 && test->pair[facts->button]==facts->sequence) test->pair[facts->button]=0;
                break;
            case ZLG_POINTER_MOTION: ++test->motion; test->last_motion=*facts; break;
            case ZLG_POINTER_LOSS: ++test->loss; memset(test->pair,0,sizeof(test->pair)); break;
            case ZLG_POINTER_DOMAIN: ++test->domain; memset(test->pair,0,sizeof(test->pair)); break;
            default: CHECK(FALSE);
        }
        return 1;
    }
    if (event->kind==8) { ++test->cancel; return 0; }
    if (event->kind==3 || event->kind==4) {
        if (event->kind==3) ++test->down; else ++test->up;
        test->delivered_x=event->x; test->delivered_y=event->y;
        if (event->context) {
            const ZlgPointerTicket *ticket=event->context;
            CHECK(ticket->button==ZLG_POINTER_PRIMARY);
            test->delivered_sequence=ticket->sequence;
        } else test->delivered_sequence=0;
        if (test->nest_on_up && event->kind==4) {
            test->nest_on_up=FALSE;
            inject(test,GDK_BUTTON_PRESS,1,300,12,13);
        }
        if (test->close_on_down && event->kind==3) { test->close_on_down=FALSE; zlg_window_destroy(test->native); }
    }
    return 0;
}
static void dispatch(void *unused) { (void)unused; }
static void window_new(Test *test, gboolean enabled) {
    memset(test,0,sizeof(*test)); test->allowed=TRUE;
    int error=0;
    unsigned before=extra_connections;
#ifdef ZLG_POINTER_LEGACY
    (void)enabled;
    test->native=zlg_window_create_mode_host(test,sink,"pointer-oracle",100,80,0,0,NULL,0,0,1,0,0,&error);
#else
    test->native=zlg_window_create_mode_host_pointer(test,sink,"pointer-oracle",100,80,0,0,NULL,0,0,1,0,0,enabled,&error);
#endif
    CHECK(test->native && !error); retain(test->native); test->connections=extra_connections-before;
}
static void window_done(Test *test) {
    if (!test->closed) zlg_window_destroy(test->native);
    CHECK(test->closed==1); release(test->native); test->native=NULL;
}
static void inject(Test *test, GdkEventType type, guint button_number, guint32 time, double x, double y) {
    GdkEventButton event={0}; event.type=type; event.window=gtk_widget_get_window(test->native->area);
    event.button=button_number; event.time=time; event.x=x; event.y=y;
    event.x_root=x+100; event.y_root=y+100;
    event.state=GDK_SHIFT_MASK|GDK_CONTROL_MASK;
    button(test->native->area,&event,test->native);
}
static void mutate_source(void) {
    CHECK(foreign_event);
    foreign_event->time=999; foreign_event->x=999; foreign_event->y=999;
    foreign_event->state=0; foreign_event->button=8;
}
static void nested_press(void) { inject(foreign_test,GDK_BUTTON_PRESS,1,210,20,21); }
static void close_native(void) { zlg_window_destroy(foreign_test->native); }

static void original_facts_and_pair(void) {
    Test test; window_new(&test,TRUE);
    GdkEventButton event={0}; event.type=GDK_BUTTON_PRESS; event.window=gtk_widget_get_window(test.native->area);
    event.button=1; event.time=0; event.x=7.25; event.y=8.5; event.state=GDK_SHIFT_MASK|GDK_CONTROL_MASK;
    foreign_event=&event; settings_reentry=mutate_source;
    button(test.native->area,&event,test.native);
    CHECK(test.began==1); /* Compiled old implementation's real capability RED. */
    CHECK(test.connections==4);
    CHECK(test.last_begin.tick_ms==0 && test.last_begin.sample_x==7.25 && test.last_begin.sample_y==8.5);
    CHECK(test.last_begin.button==0 && test.last_begin.modifiers==3 && test.last_begin.qualified==1);
    CHECK(test.last_begin.edges==15 && test.last_begin.interval_ms>0);
    CHECK(test.down==1 && test.delivered_x==7.25 && test.delivered_y==8.5 && test.delivered_sequence!=0);
    uint64_t sequence=test.delivered_sequence;
    CHECK(gtk_widget_has_grab(test.native->area));
    inject(&test,GDK_BUTTON_RELEASE,1,20,7.25,8.5);
    CHECK(test.up==1 && test.delivered_sequence==sequence && test.finished==2);
    CHECK(!gtk_widget_has_grab(test.native->area));
    printf("gtk pointer original facts/pair own_remove cancel=%u loss=%u\n",test.cancel,test.loss);
    window_done(&test);
}
static void every_button_and_decorations(void) {
    Test test; window_new(&test,TRUE);
    const guint buttons[5]={1,3,2,8,9};
    for (unsigned i=0;i<5;++i) {
        inject(&test,GDK_BUTTON_PRESS,buttons[i],10+i,4,5);
        CHECK(test.last_begin.button==i && test.pair[i]!=0);
    }
    for (unsigned i=0;i<5;++i) {
        uint64_t sequence=test.pair[i]; inject(&test,GDK_BUTTON_RELEASE,buttons[i],30+i,4,5);
        CHECK(test.last_begin.button==i && sequence!=0);
    }
    CHECK(test.began==10 && test.finished==10 && test.down==1 && test.up==1);
    unsigned began=test.began;
    inject(&test,GDK_2BUTTON_PRESS,1,50,4,5); inject(&test,GDK_3BUTTON_PRESS,1,51,4,5);
    CHECK(test.began==began && test.down==1);
    inject(&test,GDK_BUTTON_PRESS,6,60,4,5);
    CHECK(test.last_begin.button==UINT32_MAX && test.down==1);
    window_done(&test);
}
static void settings_reentry_and_close(void) {
    Test test; window_new(&test,TRUE); foreign_test=&test; settings_reentry=nested_press;
    inject(&test,GDK_BUTTON_PRESS,1,200,7,8);
    CHECK(test.began==1 && test.down==1 && test.delivered_x==20 && test.last_begin.tick_ms==210);
    CHECK(test.finished==1 && gtk_widget_has_grab(test.native->area));
    window_done(&test);
    window_new(&test,TRUE); foreign_test=&test; settings_reentry=close_native;
    inject(&test,GDK_BUTTON_PRESS,1,200,7,8);
    CHECK(test.closed==1 && test.began==0 && test.down==0);
    window_done(&test);
}
static void nested_up_tail(void) {
    Test test; window_new(&test,TRUE);
    inject(&test,GDK_BUTTON_PRESS,1,100,4,5);
    unsigned before=test.finished;
    test.nest_on_up=TRUE; inject(&test,GDK_BUTTON_RELEASE,1,200,4,5);
    CHECK(test.down==2 && test.up==1 && test.finished==before+1);
    CHECK(gtk_widget_has_grab(test.native->area)); /* Old up did not remove new grab. */
    inject(&test,GDK_BUTTON_RELEASE,1,400,12,13);
    CHECK(test.up==2 && !gtk_widget_has_grab(test.native->area));
    window_done(&test);
}
static void motion_and_domains(void) {
    Test test; window_new(&test,TRUE); inject(&test,GDK_BUTTON_PRESS,1,100,4,5);
    GdkEventMotion event={0}; event.type=GDK_MOTION_NOTIFY; event.window=gtk_widget_get_window(test.native->area); event.x=999; event.y=5;
    test.native->decoration=1; test.hit_requires_motion=TRUE;
    motion(test.native->area,&event,test.native);
    CHECK(test.motion==1 && test.last_motion.qualified==1 && test.last_motion.sample_x==999);
    test.native->decoration=0;
    GdkEventConfigure configure={0}; configure.type=GDK_CONFIGURE;
    configured(test.native->window,&configure,test.native);
    CHECK(test.domain>0 && test.pair[0]==0);
    window_done(&test);
}
static void foreign_grab_and_permission(void) {
    Test test; window_new(&test,TRUE); inject(&test,GDK_BUTTON_PRESS,1,100,4,5);
    GtkWidget *window=gtk_window_new(GTK_WINDOW_TOPLEVEL); g_object_ref_sink(window);
    GtkWidget *other=gtk_button_new(); gtk_container_add(GTK_CONTAINER(window),other);
    gtk_window_group_add_window(test.native->group,GTK_WINDOW(window));
    gtk_widget_show(other); gtk_widget_realize(window);
    unsigned before=test.loss; gtk_grab_add(other);
    CHECK(test.loss>before && test.cancel>0 && test.pair[0]==0);
    gtk_grab_remove(other); gtk_widget_destroy(window); g_object_unref(window);
    inject(&test,GDK_BUTTON_PRESS,1,200,4,5);
    before=test.loss;
    gtk_widget_set_sensitive(test.native->area,FALSE); gtk_widget_set_sensitive(test.native->area,TRUE);
    CHECK(test.loss>before && test.pair[0]==0);
    window_done(&test);
}
static void close_callback_and_all_off(void) {
    Test test; window_new(&test,TRUE); test.close_on_down=TRUE;
    inject(&test,GDK_BUTTON_PRESS,1,100,4,5);
    CHECK(test.closed==1 && test.down==1 && test.finished==0); window_done(&test);
    unsigned reads=settings_reads; window_new(&test,FALSE);
    inject(&test,GDK_BUTTON_PRESS,1,100,4,5); inject(&test,GDK_BUTTON_RELEASE,1,200,4,5);
    CHECK(test.down==1 && test.up==1 && test.began==0 && settings_reads==reads);
    CHECK(test.connections==0);
    CHECK(test.delivered_sequence==0); window_done(&test);
}
static void exhaustion(void) {
#ifndef ZLG_POINTER_LEGACY
    Test test; window_new(&test,TRUE); test.native->pointer_operation=UINT64_MAX-2;
    inject(&test,GDK_BUTTON_PRESS,1,100,4,5); CHECK(test.down==1 && test.pair[0]!=0);
    inject(&test,GDK_BUTTON_RELEASE,1,200,4,5);
    CHECK(test.native->pointer_operation==UINT64_MAX && test.pair[0]==0 && test.up==0);
    inject(&test,GDK_BUTTON_PRESS,1,300,4,5); CHECK(test.down==1);
    window_done(&test);
#endif
}
int main(void) {
    int error=0; NativeApp *app=zlg_app_create(NULL,dispatch,&error); CHECK(app && !error);
    printf("gtk pointer facts=%zu ticket=%zu native=%zu scale=%s\n",sizeof(ZlgPointerFacts),sizeof(ZlgPointerTicket),sizeof(NativeWindow),g_getenv("GDK_SCALE")?g_getenv("GDK_SCALE"):"default");
    original_facts_and_pair(); every_button_and_decorations(); settings_reentry_and_close(); nested_up_tail();
    motion_and_domains(); foreign_grab_and_permission(); close_callback_and_all_off(); exhaustion();
    zlg_app_destroy(app); CHECK(zlg_resource_count()==0);
    puts("GTK pointer adapter 8/8 groups passed; tracked resources=0"); return 0;
}
