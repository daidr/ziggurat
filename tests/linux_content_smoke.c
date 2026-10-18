#include <gtk/gtk.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static gboolean fail_host_allocation;
static GtkIMContext *bound_im;
static GdkWindow *bound_window;
static void *host_allocate(size_t bytes) {
    if (fail_host_allocation) { fail_host_allocation=FALSE; return NULL; }
    return g_try_malloc0(bytes);
}
static void probe_im_bind(GtkIMContext *im, GdkWindow *window) {
    gtk_im_context_set_client_window(im,window);
    bound_im=im; bound_window=window;
}
#define ZLG_CONTENT_ALLOC() host_allocate(sizeof(ZlgContentHost))
#define gtk_im_context_set_client_window probe_im_bind
/* This standalone target includes the adapter once to inspect object identity
 * and inject one allocation failure without adding production test hooks. */
#include "../src/platform/linux.c"
#undef gtk_im_context_set_client_window

#define CHECK(test) do { if (!(test)) { fprintf(stderr,"content smoke:%u: %s\n",__LINE__,#test); exit(1); } } while (0)
typedef struct Fixture {
    NativeWindow *window;
    GtkWidget *reentrant_child;
    unsigned paints, commits, cancelled, blurred, closed, busy;
    gboolean nested_attach;
} Fixture;
static int event(void *context, const NativeEvent *value) {
    Fixture *f=context;
    if (value->kind==1) ++f->paints;
    if (value->kind==12) ++f->commits;
    if (value->kind==14) ++f->cancelled;
    if (value->kind==7 && !value->flags) {
        ++f->blurred;
        if (f->nested_attach) {
            f->nested_attach=FALSE;
            ZlgContentHost *nested=NULL;
            CHECK(zlg_content_attach(f->window,f->reentrant_child,&nested)==ZLG_CONTENT_BUSY);
            CHECK(!nested); ++f->busy;
        }
    }
    if (value->kind==11) { ++f->closed; f->window=NULL; }
    return 0;
}
static void dispatch(void *unused) { (void)unused; }
static NativeWindow *create(Fixture *f) {
    memset(f,0,sizeof(*f));
    int error=0;
    f->window=zlg_window_create(f,event,"hidden content integration",320,200,0,0,NULL,0,0,1,&error);
    CHECK(f->window && error==0);
    return f->window;
}
static GtkWidget *child_new(void) {
    GtkWidget *child=gtk_drawing_area_new(); g_object_ref_sink(child);
    gtk_widget_set_can_focus(child,TRUE);
    return child;
}
static void child_free(GtkWidget *child) { gtk_widget_destroy(child); g_object_unref(child); }
static void close_on_reparent(GtkWidget *widget, GtkWidget *old_parent, gpointer data) {
    (void)old_parent;
    g_signal_handlers_disconnect_by_func(widget,G_CALLBACK(close_on_reparent),data);
    gtk_widget_destroy(data);
}
static void destroy_child(GObject *widget, GParamSpec *property, gpointer unused) {
    (void)property; (void)unused;
    gtk_widget_destroy(GTK_WIDGET(widget));
}
static void detach_again(GtkWidget *widget, GtkWidget *old_parent, gpointer data) {
    (void)widget; (void)old_parent;
    zlg_content_detach(data);
}
static void roundtrips(unsigned baseline) {
    Fixture f;
    NativeWindow *s=create(&f);
    GtkWidget *window=s->window, *area=s->area;
    GtkIMContext *im=s->im;
    GtkWidget *child=child_new(), *other=child_new();
    GdkWindow *original=gtk_widget_get_window(area);
    CHECK(bound_im==im && bound_window==original && !s->content && !s->content_busy);
    unsigned window_count=zlg_resource_count();
    fail_host_allocation=TRUE;
    ZlgContentHost *host=NULL;
    CHECK(zlg_content_attach(s,child,&host)==ZLG_CONTENT_OOM && !host);
    CHECK(gtk_bin_get_child(GTK_BIN(window))==area && gtk_widget_get_window(area)==original);
    CHECK(zlg_resource_count()==window_count && zlg_content_count()==0);
    GtkWidget *parent=gtk_box_new(GTK_ORIENTATION_VERTICAL,0); g_object_ref_sink(parent);
    gtk_container_add(GTK_CONTAINER(parent),other);
    CHECK(zlg_content_attach(s,other,&host)==ZLG_CONTENT_INVALID && !host);
    gtk_container_remove(GTK_CONTAINER(parent),other); g_object_unref(parent);
    f.reentrant_child=other; f.nested_attach=TRUE;
    for (unsigned i=0;i<8;++i) {
        CHECK(zlg_content_attach(s,child,&host)==ZLG_CONTENT_OK && host);
        CHECK(s->window==window && s->area==area && s->im==im);
        CHECK(gtk_bin_get_child(GTK_BIN(window))==host->overlay);
        CHECK(gtk_widget_get_parent(area)==host->overlay && gtk_widget_get_parent(child)==host->overlay);
        CHECK(bound_im==im && bound_window==gtk_widget_get_window(area) && bound_window);
        CHECK(zlg_content_count()==1 && !gtk_widget_get_can_focus(area));
        GtkAllocation allocation={0,0,481,279}; gtk_widget_size_allocate(host->overlay,&allocation);
        CHECK(gtk_widget_get_allocated_width(area)==481 && gtk_widget_get_allocated_width(child)==481);
        CHECK(zlg_content_focus(host)==ZLG_CONTENT_OK && gtk_window_get_focus(GTK_WINDOW(window))==child);
        zlg_test_paint(s,481,279); zlg_test_commit(s,"still bound");
        CHECK(f.paints==i+1 && f.commits==i+1);
        gulong detach_handler=0;
        if (i==0) detach_handler=g_signal_connect(child,"parent-set",G_CALLBACK(detach_again),host);
        zlg_content_detach(host); host=NULL;
        if (detach_handler) g_signal_handler_disconnect(child,detach_handler);
        CHECK(s->window==window && s->area==area && s->im==im);
        CHECK(gtk_bin_get_child(GTK_BIN(window))==area && !gtk_widget_get_parent(child));
        CHECK(bound_im==im && bound_window==gtk_widget_get_window(area) && bound_window);
        CHECK(gtk_widget_get_can_focus(area) && !s->content && !s->content_busy);
        CHECK(zlg_content_count()==0 && zlg_resource_count()==window_count);
    }
    CHECK(f.busy==1 && f.blurred==16 && f.cancelled>=16);
    child_free(child); child_free(other);
    CHECK(zlg_window_destroy(s) && f.closed==1 && !f.window);
    CHECK(zlg_resource_count()==baseline);
}
static void parent_close(unsigned baseline, gboolean during_attach) {
    Fixture f;
    NativeWindow *s=create(&f);
    GtkWidget *child=child_new();
    ZlgContentHost *host=NULL;
    if (!during_attach) CHECK(zlg_content_attach(s,child,&host)==ZLG_CONTENT_OK);
    g_signal_connect(s->area,"parent-set",G_CALLBACK(close_on_reparent),s->window);
    if (during_attach) {
        CHECK(zlg_content_attach(s,child,&host)==ZLG_CONTENT_CLOSED && !host);
    } else zlg_content_detach(host);
    CHECK(f.closed==1 && !f.window && zlg_content_count()==0);
    child_free(child);
    CHECK(zlg_resource_count()==baseline);
}
static void destroyed_candidate(unsigned baseline) {
    Fixture f;
    NativeWindow *s=create(&f);
    GtkWidget *child=child_new();
    g_signal_connect(child,"notify::hexpand",G_CALLBACK(destroy_child),NULL);
    ZlgContentHost *host=NULL;
    CHECK(zlg_content_attach(s,child,&host)==ZLG_CONTENT_CLOSED && !host);
    CHECK(gtk_bin_get_child(GTK_BIN(s->window))==s->area && !s->content);
    CHECK(bound_im==s->im && bound_window==gtk_widget_get_window(s->area));
    child_free(child);
    child=child_new();
    CHECK(zlg_content_attach(s,child,&host)==ZLG_CONTENT_OK);
    CHECK(zlg_window_destroy(s) && f.closed==1);
    CHECK(zlg_content_count()==1);
    zlg_content_detach(host); child_free(child);
    CHECK(zlg_content_count()==0 && zlg_resource_count()==baseline);
}
int main(void) {
    int error=0;
    NativeApp *app=zlg_app_create(NULL,dispatch,&error);
    CHECK(app && !error);
    unsigned baseline=zlg_resource_count();
    roundtrips(baseline);
    parent_close(baseline,TRUE); parent_close(baseline,FALSE);
    destroyed_candidate(baseline);
    zlg_app_destroy(app);
    CHECK(zlg_resource_count()==0 && zlg_content_count()==0);
    puts("linux content smoke: 8 retries, identity/IM/rollback/reentry/raw-close, resources=0");
    return 0;
}
