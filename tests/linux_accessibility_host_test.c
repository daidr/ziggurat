/* Native ownership oracle. No Document, text export, AT-SPI client or visual QA.
 * The legacy build uses the exact preserved adapter and fails at a real plain
 * drawing area's missing discoverable child, rather than a missing declaration. */
#include <gtk/gtk.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fail_binding_alloc;
static void *binding_alloc(size_t bytes) {
    if (fail_binding_alloc) { fail_binding_alloc=0; return NULL; }
    return g_try_malloc0(bytes);
}
#define ZLG_ACCESSIBILITY_BINDING_ALLOC() binding_alloc(sizeof(ZlgAccessibilityBinding))
#ifdef ZLG_ACCESSIBILITY_HOST_LEGACY
#include "../.validation/linux-accessibility-host/before/src/platform/linux.c"
#else
#include "../src/platform/linux.c"
#endif

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#condition); exit(1); } } while (0)

typedef struct TestWindow { unsigned closed; } TestWindow;
static int event(void *context, const NativeEvent *ev) {
    if (ev->kind==11) ++((TestWindow *)context)->closed;
    return 0;
}
static void dispatch(void *unused) { (void)unused; }
static NativeWindow *window_new(TestWindow *owner, int selected) {
    int error=0;
#ifdef ZLG_ACCESSIBILITY_HOST_LEGACY
    (void)selected;
    NativeWindow *native=zlg_window_create_mode(owner,event,"host-oracle",80,60,0,0,NULL,0,0,1,0,&error);
#else
    NativeWindow *native=zlg_window_create_mode_host(owner,event,"host-oracle",80,60,0,0,NULL,0,0,1,0,selected,&error);
#endif
    CHECK(native && !error);
    retain(native); /* Oracle's explicit C pin, released by window_done. */
    return native;
}
static void window_done(NativeWindow *native, TestWindow *owner) {
    zlg_window_destroy(native);
    CHECK(owner->closed==1);
    release(native);
}
static int selected_host_shape(NativeWindow *native, AtkObject *host) {
    return strcmp(G_OBJECT_TYPE_NAME(native->area),"ZlgAccessibilityArea")==0 &&
        strcmp(G_OBJECT_TYPE_NAME(host),"ZlgAccessibilityHost")==0 &&
        atk_object_get_n_accessible_children(host)==0;
}

#ifndef ZLG_ACCESSIBILITY_HOST_LEGACY
typedef struct TestChild TestChild;
typedef struct TestChildClass TestChildClass;
struct TestChild {
    AtkObject parent;
    unsigned marks;
    gboolean invalid;
    void (*on_get)(TestChild *);
    void (*before_set)(TestChild *);
    void (*after_set)(TestChild *);
    NativeWindow *native;
};
struct TestChildClass { AtkObjectClass parent; };
static unsigned finalized_children;
G_DEFINE_TYPE(TestChild,test_child,ATK_TYPE_OBJECT)
static AtkObject *child_get_parent(AtkObject *object) {
    TestChild *child=(TestChild *)object;
    if (child->on_get) child->on_get(child);
    return ATK_OBJECT_CLASS(test_child_parent_class)->get_parent(object);
}
static void child_set_parent(AtkObject *object, AtkObject *parent) {
    TestChild *child=(TestChild *)object;
    if (parent && child->before_set) child->before_set(child);
    ATK_OBJECT_CLASS(test_child_parent_class)->set_parent(object,parent);
    if (parent && child->after_set) child->after_set(child);
}
static void child_finalize(GObject *object) {
    ++finalized_children;
    G_OBJECT_CLASS(test_child_parent_class)->finalize(object);
}
static void test_child_class_init(TestChildClass *klass) {
    ATK_OBJECT_CLASS(klass)->get_parent=child_get_parent;
    ATK_OBJECT_CLASS(klass)->set_parent=child_set_parent;
    G_OBJECT_CLASS(klass)->finalize=child_finalize;
}
static void test_child_init(TestChild *child) { (void)child; }
static TestChild *child_new(void) { return g_object_new(test_child_get_type(),NULL); }
static void mark(void *object) {
    TestChild *child=object;
    child->invalid=TRUE; ++child->marks;
}
static void counts(unsigned tokens, unsigned registered, unsigned mounted) {
    unsigned t,r,m;
    zlg_accessibility_counts(&t,&r,&m);
    CHECK(t==tokens && r==registered && m==mounted);
}
static ZlgAccessibilityBinding *prepare(NativeWindow *native, TestChild *child) {
    ZlgAccessibilityBinding *binding=NULL;
    CHECK(zlg_accessibility_prepare(native,child,mark,&binding)==ZLG_ACCESSIBILITY_OK);
    CHECK(binding && !child->invalid);
    return binding;
}
static void no_child(AtkObject *host) {
    CHECK(atk_object_get_n_accessible_children(host)==0);
    CHECK(atk_object_ref_accessible_child(host,0)==NULL);
}
static void exact_child(AtkObject *host, TestChild *child) {
    CHECK(atk_object_get_n_accessible_children(host)==1);
    AtkObject *owned=atk_object_ref_accessible_child(host,0);
    CHECK(owned==ATK_OBJECT(child));
    CHECK(atk_object_get_parent(owned)==host);
    g_object_unref(owned);
    CHECK(atk_object_ref_accessible_child(host,-1)==NULL);
    CHECK(atk_object_ref_accessible_child(host,1)==NULL);
}
typedef struct WeakRebind { NativeWindow *native; TestChild *next; unsigned calls; int status; } WeakRebind;
static void weak_rebind(void *context, GObject *object) {
    (void)object;
    WeakRebind *probe=context;
    ++probe->calls;
    ZlgAccessibilityBinding *out=(void *)1;
    probe->status=zlg_accessibility_prepare(probe->native,probe->next,mark,&out);
    CHECK(!out && probe->status==ZLG_ACCESSIBILITY_BUSY);
}
static void check_default(void) {
    CHECK(!g_type_from_name("ZlgAccessibilityArea"));
    CHECK(!g_type_from_name("ZlgAccessibilityHost"));
    TestWindow owner={0}; NativeWindow *native=window_new(&owner,0);
    CHECK(G_OBJECT_TYPE(native->area)==GTK_TYPE_DRAWING_AREA);
    CHECK(!zlg_accessibility_host_available(native));
    ZlgAccessibilityBinding *out=(void *)1;
    CHECK(zlg_accessibility_prepare(native,NULL,NULL,&out)==ZLG_ACCESSIBILITY_UNSUPPORTED);
    CHECK(!out);
    window_done(native,&owner);
    CHECK(!g_type_from_name("ZlgAccessibilityArea"));
    CHECK(!g_type_from_name("ZlgAccessibilityHost"));
    counts(0,0,0);
    puts("host: default plain area / no optional type registration");
}
static void check_binding(void) {
    TestWindow owner={0}; NativeWindow *native=window_new(&owner,1);
    CHECK(zlg_accessibility_host_available(native));
    TestChild *old=child_new(), *next=child_new();
    ZlgAccessibilityBinding *binding=prepare(native,old);
    AtkObject *host=gtk_widget_get_accessible(native->area); /* Genuine borrowed host. */
    CHECK(host && GTK_IS_ACCESSIBLE(host));
    CHECK(selected_host_shape(native,host));
    no_child(host); counts(1,1,0);
    CHECK(!atk_object_get_parent(ATK_OBJECT(old)));
    ZlgAccessibilityBinding *rejected=(void *)1;
    CHECK(zlg_accessibility_prepare(native,next,mark,&rejected)==ZLG_ACCESSIBILITY_BUSY);
    CHECK(!rejected && !next->marks);
    CHECK(zlg_accessibility_mount(binding)==ZLG_ACCESSIBILITY_OK);
    CHECK(zlg_accessibility_mount(binding)==ZLG_ACCESSIBILITY_OK);
    exact_child(host,old); counts(1,1,1);
    zlg_accessibility_withdraw(binding);
    zlg_accessibility_withdraw(binding);
    CHECK(old->marks==1 && !atk_object_get_parent(ATK_OBJECT(old)));
    no_child(host); counts(1,0,0);
    ZlgAccessibilityBinding *new_binding=prepare(native,next);
    CHECK(zlg_accessibility_mount(new_binding)==ZLG_ACCESSIBILITY_OK);
    exact_child(host,next); counts(2,1,1);
    zlg_accessibility_release(binding); /* Old retired tail cannot clear new slot. */
    exact_child(host,next); counts(1,1,1);
    zlg_accessibility_release(new_binding);
    CHECK(next->marks==1); no_child(host); counts(0,0,0);
    g_object_unref(old); g_object_unref(next);
    TestChild *victim=child_new(), *successor=child_new();
    WeakRebind weak={native,successor,0,0};
    g_object_weak_ref(G_OBJECT(victim),weak_rebind,&weak);
    binding=prepare(native,victim);
    CHECK(zlg_accessibility_mount(binding)==ZLG_ACCESSIBILITY_OK);
    g_object_unref(victim); /* Only the accepted token/host own it now. */
    zlg_accessibility_withdraw(binding);
    CHECK(weak.calls==1 && weak.status==ZLG_ACCESSIBILITY_BUSY);
    counts(1,0,0);
    new_binding=prepare(native,successor);
    CHECK(zlg_accessibility_mount(new_binding)==ZLG_ACCESSIBILITY_OK);
    zlg_accessibility_release(binding);
    exact_child(host,successor);
    zlg_accessibility_release(new_binding); counts(0,0,0);
    g_object_unref(successor);
    window_done(native,&owner);
    puts("host: prepare/mount/discover/withdraw/new binding vs old token");
}
static void check_refusal(void) {
    TestWindow owner={0}; NativeWindow *native=window_new(&owner,1);
    TestChild *child=child_new();
    ZlgAccessibilityBinding *out=(void *)1;
    unsigned original=G_OBJECT(child)->ref_count;
    fail_binding_alloc=1;
    CHECK(zlg_accessibility_prepare(native,child,mark,&out)==ZLG_ACCESSIBILITY_OOM);
    CHECK(!out && !child->marks && G_OBJECT(child)->ref_count==original); counts(0,0,0);
    CHECK(zlg_accessibility_prepare(native,child,NULL,&out)==ZLG_ACCESSIBILITY_INVALID && !out);
    g_object_force_floating(G_OBJECT(child));
    CHECK(zlg_accessibility_prepare(native,child,mark,&out)==ZLG_ACCESSIBILITY_INVALID && !out);
    g_object_ref_sink(child);
    AtkObject *parent=g_object_new(ATK_TYPE_OBJECT,NULL);
    atk_object_set_parent(ATK_OBJECT(child),parent);
    CHECK(zlg_accessibility_prepare(native,child,mark,&out)==ZLG_ACCESSIBILITY_INVALID && !out);
    CHECK(!child->marks && G_OBJECT(child)->ref_count==original);
    CHECK(atk_object_get_parent(ATK_OBJECT(child))==parent); counts(0,0,0);
    atk_object_set_parent(ATK_OBJECT(child),NULL); g_object_unref(parent);
    g_object_unref(child); window_done(native,&owner);
    puts("host: real allocation fault / invalid / floating / parented refusal");
}
static void destroy_from_get(TestChild *child) {
    child->on_get=NULL;
    zlg_window_destroy(child->native);
}
static void check_virtual_get(void) {
    for (unsigned stage=0;stage<2;++stage) {
        TestWindow owner={0}; NativeWindow *native=window_new(&owner,1);
        TestChild *child=child_new(); child->native=native;
        ZlgAccessibilityBinding *binding=NULL;
        if (stage) binding=prepare(native,child);
        child->on_get=destroy_from_get;
        if (!stage) CHECK(zlg_accessibility_prepare(native,child,mark,&binding)==ZLG_ACCESSIBILITY_CLOSED);
        else CHECK(zlg_accessibility_mount(binding)==ZLG_ACCESSIBILITY_CLOSED);
        CHECK(child->marks==stage);
        CHECK(owner.closed==1 && !atk_object_get_parent(ATK_OBJECT(child)));
        if (binding) zlg_accessibility_release(binding);
        counts(0,0,0); g_object_unref(child); window_done(native,&owner);
    }
    puts("host: virtual parent query closes before prepare/mount acceptance");
}
typedef struct ToggleClose { NativeWindow *native; unsigned calls; } ToggleClose;
static void toggle_close(void *context, GObject *object, gboolean last) {
    (void)object;
    ToggleClose *probe=context;
    if (!last && !probe->calls++) zlg_window_destroy(probe->native);
}
static void check_toggle(void) {
    TestWindow owner={0}; NativeWindow *native=window_new(&owner,1);
    TestChild *child=child_new();
    ToggleClose probe={native,0};
    g_object_add_toggle_ref(G_OBJECT(child),toggle_close,&probe);
    g_object_unref(child); /* Caller now owns the sole native toggle reference. */
    CHECK(G_OBJECT(child)->ref_count==1);
    ZlgAccessibilityBinding *binding=(void *)1;
    CHECK(zlg_accessibility_prepare(native,child,mark,&binding)==ZLG_ACCESSIBILITY_CLOSED);
    CHECK(probe.calls==1 && !binding && !child->marks);
    CHECK(G_OBJECT(child)->ref_count==1); counts(0,0,0);
    g_object_remove_toggle_ref(G_OBJECT(child),toggle_close,&probe);
    window_done(native,&owner);
    puts("host: actual 1-to-2 child toggle closes while first ref is acquired");
}
typedef struct Observe { NativeWindow *native; TestChild *child; unsigned removes, adds, closed_notifications; int close_on_add, nested_close; } Observe;
static void child_event(AtkObject *host, guint index, gpointer object, gpointer context) {
    Observe *probe=context;
    CHECK(index==0 && object==probe->child);
    if (((TestChild *)object)->invalid) {
        ++probe->removes; no_child(host);
        CHECK(((TestChild *)object)->marks==1);
        if (probe->nested_close) { probe->nested_close=0; zlg_window_destroy(probe->native); }
    } else {
        ++probe->adds; exact_child(host,probe->child);
        if (probe->close_on_add) { probe->close_on_add=0; zlg_window_destroy(probe->native); }
    }
}
static void defunct_event(AtkObject *host, const char *name, gboolean value, gpointer context) {
    Observe *probe=context;
    if (!value || strcmp(name,"defunct")) return;
    ++probe->closed_notifications;
    no_child(host);
    CHECK(probe->child->invalid);
    if (probe->nested_close) { probe->nested_close=0; zlg_window_destroy(probe->native); }
}
static void destroy_before_set(TestChild *child) {
    child->before_set=NULL;
    gtk_widget_destroy(child->native->area); /* BEFORE chaining the stock setter. */
}
static void destroy_after_set(TestChild *child) {
    child->after_set=NULL;
    gtk_widget_destroy(child->native->window);
}
static void check_setter_close(void) {
    unsigned baseline=zlg_resource_count();
    for (unsigned stage=0;stage<3;++stage) {
        TestWindow owner={0}; NativeWindow *native=window_new(&owner,1);
        TestChild *child=child_new(); child->native=native;
        ZlgAccessibilityBinding *binding=prepare(native,child);
        AtkObject *host=g_object_ref(gtk_widget_get_accessible(native->area));
        Observe probe={native,child,0,0,0,stage==2,1};
        g_signal_connect(host,"children-changed",G_CALLBACK(child_event),&probe);
        g_signal_connect(host,"state-change",G_CALLBACK(defunct_event),&probe);
        if (stage==0) child->before_set=destroy_before_set;
        if (stage==1) child->after_set=destroy_after_set;
        /* This branch has NO oracle C native pin through mount. Only the
         * token/invocation may keep the raw close stack alive. */
        if (stage==1) release(native);
        CHECK(zlg_accessibility_mount(binding)==ZLG_ACCESSIBILITY_OK);
        CHECK(child->marks==1 && !atk_object_get_parent(ATK_OBJECT(child)));
        CHECK(probe.removes==1 && probe.adds==(stage==2?1u:0u));
        CHECK(probe.closed_notifications>=1);
        no_child(host); counts(1,0,0);
        CHECK(gtk_accessible_get_widget(GTK_ACCESSIBLE(host))==NULL);
        CHECK(zlg_accessibility_mount(binding)==ZLG_ACCESSIBILITY_CLOSED);
        zlg_accessibility_release(binding); counts(0,0,0);
        g_signal_handlers_disconnect_by_data(host,&probe);
        g_object_unref(host); g_object_unref(child);
        if (stage==1) { CHECK(owner.closed==1); CHECK(zlg_resource_count()==baseline); }
        else window_done(native,&owner);
    }
    puts("host: virtual setter before/after stock + add signal close / nested teardown");
}
typedef struct InitClose { NativeWindow *native; unsigned hit; gboolean raw_window; } InitClose;
static gboolean initialization_event(GSignalInvocationHint *hint, guint count, const GValue *values, gpointer context) {
    (void)hint;
    InitClose *probe=context;
    if (count!=3 || probe->hit || !G_VALUE_HOLDS_OBJECT(&values[0])) return TRUE;
    GObject *object=g_value_get_object(&values[0]);
    if (!object || strcmp(G_OBJECT_TYPE_NAME(object),"ZlgAccessibilityHost") ||
        strcmp(g_value_get_string(&values[1]),"defunct") || g_value_get_boolean(&values[2])) return TRUE;
    ++probe->hit;
    if (probe->raw_window) gtk_widget_destroy(probe->native->window);
    else gtk_widget_destroy(probe->native->area);
    return TRUE;
}
static void check_first_accessible_close(void) {
    for (unsigned stage=0;stage<2;++stage) {
        TestWindow owner={0}; NativeWindow *native=window_new(&owner,1);
        TestChild *child=child_new();
        ZlgAccessibilityBinding *binding=stage?prepare(native,child):NULL;
        GtkWidget *area=g_object_ref(native->area); /* Own the GTK getter receiver. */
        InitClose probe={native,0,stage!=0};
        guint signal=g_signal_lookup("state-change",ATK_TYPE_OBJECT);
        CHECK(signal);
        gulong hook=g_signal_add_emission_hook(signal,0,initialization_event,&probe,NULL);
        CHECK(hook);
        if (stage) CHECK(zlg_accessibility_mount(binding)==ZLG_ACCESSIBILITY_CLOSED);
        else {
            AtkObject *host=gtk_widget_get_accessible(area);
            CHECK(host && !gtk_accessible_get_widget(GTK_ACCESSIBLE(host)));
            no_child(host);
        }
        g_signal_remove_emission_hook(signal,hook);
        CHECK(probe.hit==1 && child->marks==stage);
        if (binding) zlg_accessibility_release(binding);
        g_object_unref(area);
        counts(0,0,0); g_object_unref(child); window_done(native,&owner);
    }
    puts("host: genuine first widget-set notification raw-close / no published child");
}
static void check_raw_and_late(NativeApp *app, unsigned app_resources) {
    for (unsigned mode=0;mode<4;++mode) {
        TestWindow owner={0}; NativeWindow *native=window_new(&owner,1);
        TestChild *child=child_new();
        ZlgAccessibilityBinding *binding=prepare(native,child);
        AtkObject *host=g_object_ref(gtk_widget_get_accessible(native->area));
        if (mode>0) CHECK(zlg_accessibility_mount(binding)==ZLG_ACCESSIBILITY_OK);
        if (mode==0) accessibility_parent_destroying(native); /* Constructor rollback seam. */
        if (mode==1) gtk_widget_destroy(native->area);
        if (mode==2) gtk_widget_destroy(native->window);
        if (mode==3) zlg_window_destroy(native);
        CHECK(child->marks==1 && !atk_object_get_parent(ATK_OBJECT(child)));
        CHECK(!zlg_accessibility_host_available(native));
        CHECK(gtk_accessible_get_widget(GTK_ACCESSIBLE(host))==NULL);
        no_child(host); counts(1,0,0);
        window_done(native,&owner); CHECK(zlg_resource_count()==app_resources);
        /* Retired token and native objects remain valid after native Window. */
        CHECK(zlg_accessibility_mount(binding)==ZLG_ACCESSIBILITY_CLOSED);
        zlg_accessibility_release(binding); counts(0,0,0);
        g_object_unref(host); g_object_unref(child);
    }
    TestWindow owner={0}; NativeWindow *native=window_new(&owner,1);
    TestChild *child=child_new(); ZlgAccessibilityBinding *binding=prepare(native,child);
    CHECK(zlg_accessibility_mount(binding)==ZLG_ACCESSIBILITY_OK);
    AtkObject *host=g_object_ref(gtk_widget_get_accessible(native->area));
    window_done(native,&owner); CHECK(zlg_resource_count()==app_resources);
    zlg_app_destroy(app); CHECK(zlg_resource_count()==0);
    no_child(host); CHECK(!atk_object_get_parent(ATK_OBJECT(child)));
    CHECK(!gtk_accessible_get_widget(GTK_ACCESSIBLE(host)));
    zlg_accessibility_release(binding); counts(0,0,0);
    g_object_unref(child); g_object_unref(host);
    puts("host: common rollback/raw area/raw window/ordinary retire and late refs across App");
}
#endif

int main(void) {
    int error=0; NativeApp *app=zlg_app_create(NULL,dispatch,&error);
    CHECK(app && !error);
#ifdef ZLG_ACCESSIBILITY_HOST_LEGACY
    (void)binding_alloc;
    TestWindow owner={0}; NativeWindow *native=window_new(&owner,1);
    AtkObject *host=gtk_widget_get_accessible(native->area);
    fprintf(stderr,"legacy actual area=%s accessible=%s children=%d; required generic child host absent\n",
        G_OBJECT_TYPE_NAME(native->area),G_OBJECT_TYPE_NAME(host),atk_object_get_n_accessible_children(host));
    int supported=selected_host_shape(native,host);
    window_done(native,&owner); zlg_app_destroy(app);
    CHECK(supported); /* Actual behavior RED, compiles all preserved adapter code. */
#else
    unsigned app_resources=zlg_resource_count();
    check_default(); CHECK(zlg_resource_count()==app_resources);
    check_binding(); CHECK(zlg_resource_count()==app_resources);
    check_refusal(); CHECK(zlg_resource_count()==app_resources);
    check_virtual_get(); CHECK(zlg_resource_count()==app_resources);
    check_toggle(); CHECK(zlg_resource_count()==app_resources);
    check_setter_close(); CHECK(zlg_resource_count()==app_resources);
    check_first_accessible_close(); CHECK(zlg_resource_count()==app_resources);
    check_raw_and_late(app,app_resources);
    CHECK(finalized_children==18);
    printf("host: PASS 8 groups; finalized_children=%u; sizes token=%zu area=%zu(+%zu) host=%zu(+%zu) NativeWindow=%zu\n",
        finalized_children,sizeof(ZlgAccessibilityBinding),sizeof(ZlgAccessibilityArea),
        sizeof(ZlgAccessibilityArea)-sizeof(GtkDrawingArea),sizeof(ZlgAccessibilityHost),
        sizeof(ZlgAccessibilityHost)-sizeof(GtkWidgetAccessible),sizeof(NativeWindow));
#endif
    return 0;
}
