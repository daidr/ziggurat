#include <gtk/gtk.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static gboolean fail_layer, fail_host;
static void *allocate_region(size_t bytes, gboolean *fail) {
    if (*fail) { *fail=FALSE; return NULL; }
    return g_try_malloc0(bytes);
}
#define ZLG_REGION_LAYER_ALLOC() allocate_region(sizeof(ZlgRegionLayer),&fail_layer)
#define ZLG_REGION_HOST_ALLOC() allocate_region(sizeof(ZlgRegionHost),&fail_host)
#include "../src/platform/linux.c"
#define CHECK(test) do { if (!(test)) { fprintf(stderr,"regions:%u: %s\n",__LINE__,#test); exit(1); } } while (0)
typedef struct Fixture { NativeWindow *window; unsigned closed, paints; } Fixture;
static int event(void *ptr, const NativeEvent *value) {
    Fixture *f=ptr;
    if (value->kind==11) { ++f->closed; f->window=NULL; }
    if (value->kind==1) ++f->paints;
    return 0;
}
static void dispatch(void *unused) { (void)unused; }
static NativeWindow *create(Fixture *f) {
    memset(f,0,sizeof(*f)); int error=0;
    f->window=zlg_window_create(f,event,"hidden rectangular integration",320,200,0,0,NULL,0,0,1,&error);
    CHECK(f->window && !error); return f->window;
}
static GtkWidget *child_new(void) {
    GtkWidget *child=gtk_drawing_area_new(); g_object_ref_sink(child);
    gtk_widget_set_can_focus(child,TRUE); return child;
}
static void child_free(GtkWidget *child) { gtk_widget_destroy(child); g_object_unref(child); }
static void close_parent(GtkWidget *widget, GtkWidget *previous, gpointer data) {
    (void)previous;
    g_signal_handlers_disconnect_by_func(widget,G_CALLBACK(close_parent),data);
    gtk_widget_destroy(data);
}
static void destroy_candidate(GtkWidget *widget, GParamSpec *property, gpointer unused) {
    (void)property; (void)unused;
    g_signal_handlers_disconnect_by_func(widget,G_CALLBACK(destroy_candidate),unused);
    gtk_widget_destroy(widget);
}
static void detach_again(GtkWidget *widget, GtkWidget *previous, gpointer data) {
    (void)widget; (void)previous; zlg_region_detach(data);
}
static void detach_visible(GObject *widget, GParamSpec *property, gpointer data) {
    (void)property;
    g_signal_handlers_disconnect_by_func(widget,G_CALLBACK(detach_visible),data);
    zlg_region_detach(data);
}
static void roundtrip(unsigned baseline) {
    Fixture f; NativeWindow *s=create(&f);
    GtkWidget *area=s->area, *window=s->window;
    GtkIMContext *im=s->im;
    unsigned before=zlg_resource_count();
    GtkWidget *a=child_new(), *b=child_new();
    ZlgRegionHost *one=NULL, *two=NULL;
    fail_host=TRUE;
    CHECK(zlg_region_attach(s,a,&one)==ZLG_CONTENT_OOM && !one && !s->regions);
    fail_layer=TRUE;
    CHECK(zlg_region_attach(s,a,&one)==ZLG_CONTENT_OOM && !one && !s->regions);
    CHECK(zlg_region_count()==0 && zlg_resource_count()==before);
    for (unsigned i=0;i<12;++i) {
        CHECK(zlg_region_attach(s,a,&one)==ZLG_CONTENT_OK);
        CHECK(zlg_region_attach(s,b,&two)==ZLG_CONTENT_OK);
        CHECK(zlg_region_count()==3 && s->area==area && s->window==window && s->im==im);
        CHECK(gtk_widget_get_can_focus(area) && !gtk_widget_get_visible(a));
        CHECK(one->layer==two->layer && gtk_bin_get_child(GTK_BIN(window))==one->layer->overlay);
        ZlgContentHost *full=NULL;
        GtkWidget *other=child_new();
        CHECK(zlg_content_attach(s,other,&full)==ZLG_CONTENT_BUSY && !full);
        child_free(other);
        CHECK(zlg_region_viewport(one,11,19,101,73,1)==ZLG_CONTENT_OK);
        CHECK(zlg_region_viewport(two,130,31,113,89,1)==ZLG_CONTENT_OK);
        GtkAllocation allocation={0,0,320,200}; gtk_widget_size_allocate(one->layer->overlay,&allocation);
        CHECK(gtk_widget_get_allocated_width(area)==320 && gtk_widget_get_allocated_height(area)==200);
        GtkAllocation actual; gtk_widget_get_allocation(a,&actual);
        int x,y;
        CHECK(gtk_widget_translate_coordinates(a,one->layer->overlay,0,0,&x,&y));
        CHECK(x==11 && y==19 && actual.width==101 && actual.height==73);
        gtk_widget_get_allocation(b,&actual);
        CHECK(gtk_widget_translate_coordinates(b,two->layer->overlay,0,0,&x,&y));
        CHECK(x==130 && y==31 && actual.width==113 && actual.height==89);
        CHECK(zlg_region_focus(one)==ZLG_CONTENT_OK && gtk_window_get_focus(GTK_WINDOW(window))==a);
        CHECK(zlg_region_viewport(two,-5,3,0,50,1)==ZLG_CONTENT_OK && !gtk_widget_get_visible(b));
        CHECK(zlg_region_focus(two)==ZLG_CONTENT_INVALID);
        CHECK(zlg_region_viewport(one,1,2,-1,5,1)==ZLG_CONTENT_INVALID && one->x==11);
        zlg_test_paint(s,320,200); CHECK(f.paints==i+1);
        gulong handler=g_signal_connect(a,"parent-set",G_CALLBACK(detach_again),one);
        zlg_region_detach(one); one=NULL;
        g_signal_handler_disconnect(a,handler);
        CHECK(zlg_region_count()==2 && s->regions && gtk_widget_get_parent(area));
        CHECK(!gtk_widget_get_parent(a) && gtk_widget_get_parent(b));
        zlg_region_detach(two); two=NULL;
        CHECK(zlg_region_count()==0 && !s->regions && !s->content_busy);
        CHECK(gtk_bin_get_child(GTK_BIN(window))==area && !gtk_widget_get_parent(b));
        CHECK(zlg_resource_count()==before);
    }
    ZlgContentHost *full=NULL;
    CHECK(zlg_content_attach(s,a,&full)==ZLG_CONTENT_OK);
    CHECK(zlg_region_attach(s,b,&two)==ZLG_CONTENT_BUSY && !two);
    zlg_content_detach(full);
    child_free(a); child_free(b);
    CHECK(zlg_window_destroy(s) && f.closed==1 && zlg_resource_count()==baseline);
}
static void reentrant(unsigned baseline, unsigned mode) {
    Fixture f; NativeWindow *s=create(&f);
    GtkWidget *child=child_new(); ZlgRegionHost *host=NULL;
    if (mode==0) {
        g_signal_connect(s->area,"parent-set",G_CALLBACK(close_parent),s->window);
        CHECK(zlg_region_attach(s,child,&host)==ZLG_CONTENT_CLOSED && !host && f.closed==1);
    } else if (mode==1) {
        g_signal_connect(child,"notify::no-show-all",G_CALLBACK(destroy_candidate),NULL);
        CHECK(zlg_region_attach(s,child,&host)==ZLG_CONTENT_CLOSED && !host);
        CHECK(!s->regions && gtk_bin_get_child(GTK_BIN(s->window))==s->area);
        CHECK(zlg_window_destroy(s) && f.closed==1);
    } else {
        CHECK(zlg_region_attach(s,child,&host)==ZLG_CONTENT_OK);
        if (mode==2) {
            CHECK(zlg_window_destroy(s) && f.closed==1);
            zlg_region_detach(host);
        } else {
            g_signal_connect(child,"notify::visible",G_CALLBACK(detach_visible),host);
            CHECK(zlg_region_viewport(host,1,2,80,90,1)==ZLG_CONTENT_CLOSED);
            CHECK(!s->regions && !s->content_busy);
            CHECK(zlg_window_destroy(s) && f.closed==1);
        }
    }
    child_free(child);
    CHECK(zlg_region_count()==0 && zlg_resource_count()==baseline);
}
int main(void) {
    int error=0; NativeApp *app=zlg_app_create(NULL,dispatch,&error); CHECK(app && !error);
    unsigned baseline=zlg_resource_count();
    roundtrip(baseline);
    for (unsigned mode=0;mode<4;++mode) reentrant(baseline,mode);
    zlg_app_destroy(app); CHECK(zlg_resource_count()==0 && zlg_region_count()==0);
    puts("rectangular hosts: 12 cycles/two children, exact logical geometry, hidden/empty/focus, OOM and reentry/parent close resources=0");
    return 0;
}
