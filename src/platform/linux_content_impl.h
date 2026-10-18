#ifndef ZIGGURAT_LINUX_CONTENT_IMPL_H
#define ZIGGURAT_LINUX_CONTENT_IMPL_H

struct ZlgContentHost {
    NativeWindow *window;
    GtkWidget *overlay, *child;
    gulong destroy_handler;
    gboolean area_can_focus, detaching, child_destroyed;
};
static gint content_resources;
unsigned zlg_content_count(void) { return (unsigned)g_atomic_int_get(&content_resources); }

#ifndef ZLG_CONTENT_ALLOC
#define ZLG_CONTENT_ALLOC() g_try_new0(ZlgContentHost,1)
#endif

static gboolean content_live(NativeWindow *s) {
    return !s->destroyed && !gtk_widget_in_destruction(s->window) &&
        !gtk_widget_in_destruction(s->area);
}
static void content_child_destroyed(GtkWidget *child, gpointer data) {
    (void)child;
    ((ZlgContentHost *)data)->child_destroyed=TRUE;
}
static gboolean content_candidate_live(ZlgContentHost *host) {
    return content_live(host->window) && !host->child_destroyed;
}
static void content_bind_im(NativeWindow *s) {
    if (!content_live(s) || !s->im) return;
    GtkIMContext *im=g_object_ref(s->im);
    GdkWindow *window=gtk_widget_get_window(s->area);
    gtk_im_context_set_client_window(im,window);
    g_object_unref(im);
}
static void content_cancel_input(NativeWindow *s) {
    s->gesture=NULL;
    memset(s->pressed_keys,0,sizeof(s->pressed_keys));
    if (gtk_widget_has_grab(s->area)) gtk_grab_remove(s->area);
    if (!content_live(s)) return;
    if (s->im) {
        GtkIMContext *im=g_object_ref(s->im);
        gtk_im_context_focus_out(im);
        if (content_live(s)) gtk_im_context_reset(im);
        if (content_live(s)) gtk_im_context_set_client_window(im,NULL);
        g_object_unref(im);
    }
    if (!content_live(s)) return;
    s->preedit=FALSE;
    NativeEvent event={0}; event.kind=14; emit(s,&event);
    if (!content_live(s)) return;
    event.kind=7; event.flags=0; emit(s,&event);
    if (!content_live(s)) return;
    event.kind=8; emit(s,&event);
    if (!content_live(s)) return;
    gtk_window_set_focus(GTK_WINDOW(s->window),NULL);
}
static void content_remove(GtkWidget *child, GtkWidget *parent) {
    if (gtk_widget_get_parent(child)==parent)
        gtk_container_remove(GTK_CONTAINER(parent),child);
}
static void content_restore(ZlgContentHost *host) {
    NativeWindow *s=host->window;
    if (!content_live(s)) return;
    content_remove(host->child,host->overlay);
    if (!content_live(s)) return;
    content_remove(s->area,host->overlay);
    if (!content_live(s)) return;
    content_remove(host->overlay,s->window);
    if (!content_live(s)) return;
    if (!gtk_widget_get_parent(s->area)) gtk_container_add(GTK_CONTAINER(s->window),s->area);
    if (!content_live(s)) return;
    gtk_widget_set_can_focus(s->area,host->area_can_focus);
    gtk_widget_show(s->area);
    if (!content_live(s)) return;
    gtk_widget_realize(s->area);
    if (!content_live(s)) return;
    content_bind_im(s);
}
static void content_free(ZlgContentHost *host) {
    NativeWindow *s=host->window;
    if (g_signal_handler_is_connected(host->child,host->destroy_handler))
        g_signal_handler_disconnect(host->child,host->destroy_handler);
    g_object_unref(host->child);
    gtk_widget_destroy(host->overlay);
    g_object_unref(host->overlay);
    g_free(host);
    g_atomic_int_add(&content_resources,-1);
    release(s);
}
int zlg_content_attach(NativeWindow *s, void *widget, ZlgContentHost **out) {
    *out=NULL;
    if (!content_live(s)) return ZLG_CONTENT_CLOSED;
    if (s->content || s->regions || s->content_busy) return ZLG_CONTENT_BUSY;
    GtkWidget *child=widget;
    if (!GTK_IS_WIDGET(child) || g_object_is_floating(child) || child==s->area || child==s->window ||
        gtk_widget_get_parent(child) || gtk_widget_in_destruction(child) ||
        gtk_widget_get_parent(s->area)!=s->window) return ZLG_CONTENT_INVALID;
    ZlgContentHost *host=ZLG_CONTENT_ALLOC();
    if (!host) return ZLG_CONTENT_OOM;
    retain(s); g_atomic_int_inc(&content_resources);
    host->window=s; host->child=g_object_ref(child);
    host->destroy_handler=g_signal_connect(child,"destroy",G_CALLBACK(content_child_destroyed),host);
    host->area_can_focus=gtk_widget_get_can_focus(s->area);
    host->overlay=gtk_overlay_new(); g_object_ref_sink(host->overlay); track(G_OBJECT(host->overlay));
    s->content_busy=TRUE;
    s->content=host;
    content_cancel_input(s);
    if (!content_candidate_live(host)) goto closed;
    gtk_widget_set_can_focus(s->area,FALSE);
    if (!content_candidate_live(host)) goto closed;
    gtk_container_remove(GTK_CONTAINER(s->window),s->area);
    if (!content_candidate_live(host)) goto closed;
    gtk_container_add(GTK_CONTAINER(s->window),host->overlay);
    if (!content_candidate_live(host)) goto closed;
    gtk_container_add(GTK_CONTAINER(host->overlay),s->area);
    if (!content_candidate_live(host)) goto closed;
    gtk_widget_set_halign(child,GTK_ALIGN_FILL);
    if (!content_candidate_live(host)) goto closed;
    gtk_widget_set_valign(child,GTK_ALIGN_FILL);
    if (!content_candidate_live(host)) goto closed;
    gtk_widget_set_hexpand(child,TRUE);
    if (!content_candidate_live(host)) goto closed;
    gtk_widget_set_vexpand(child,TRUE);
    if (!content_candidate_live(host)) goto closed;
    gtk_overlay_add_overlay(GTK_OVERLAY(host->overlay),child);
    if (!content_candidate_live(host)) goto closed;
    gtk_widget_show(host->overlay);
    if (!content_candidate_live(host)) goto closed;
    gtk_widget_show(child);
    if (!content_candidate_live(host)) goto closed;
    gtk_widget_realize(host->overlay);
    if (!content_candidate_live(host)) goto closed;
    gtk_widget_realize(s->area);
    if (!content_candidate_live(host)) goto closed;
    content_bind_im(s);
    if (!content_candidate_live(host)) goto closed;
    s->content_busy=FALSE;
    *out=host;
    return ZLG_CONTENT_OK;
closed:
    s->content=NULL;
    content_restore(host);
    s->content_busy=FALSE;
    content_free(host);
    return ZLG_CONTENT_CLOSED;
}
void zlg_content_detach(ZlgContentHost *host) {
    if (host->detaching) return;
    host->detaching=TRUE;
    NativeWindow *s=host->window;
    s->content_busy=TRUE;
    if (s->content==host) s->content=NULL;
    if (content_live(s)) content_cancel_input(s);
    content_restore(host);
    s->content_busy=FALSE;
    content_free(host);
}
int zlg_content_focus(ZlgContentHost *host) {
    NativeWindow *s=host->window;
    if (!content_candidate_live(host) || host->detaching) return ZLG_CONTENT_CLOSED;
    if (s->content_busy || s->content!=host) return ZLG_CONTENT_BUSY;
    retain(s);
    gtk_widget_grab_focus(host->child);
    int result=content_live(s)?ZLG_CONTENT_OK:ZLG_CONTENT_CLOSED;
    release(s);
    return result;
}
#endif
