#ifndef ZIGGURAT_WEBKIT_SESSION_IMPL_H
#define ZIGGURAT_WEBKIT_SESSION_IMPL_H

static int session_size(ZwkState *s,uint32_t width,uint32_t height,int x,int y) {
    if (!live(s) || !s->view || s->parent_destroying) return ZWK_CLOSED;
    int scale=MAX(1,gtk_widget_get_scale_factor(s->view));
    if (!width || !height || width%scale || height%scale || width/(unsigned)scale>32768 || height/(unsigned)scale>32768)
        return ZWK_GEOMETRY_NOT_APPLIED;
    /* visible and child-visible are distinct: a mounted hidden Session can
     * receive exact allocation without ever mapping its native widget. */
    gtk_widget_show(s->view);
    if (!live(s) || s->parent_destroying) return ZWK_CLOSED;
    GtkAllocation bounds={x,y,(int)(width/(unsigned)scale),(int)(height/(unsigned)scale)};
    gtk_widget_size_allocate(s->view,&bounds);
    if (!live(s) || s->parent_destroying) return ZWK_CLOSED;
    if ((uint64_t)MAX(0,gtk_widget_get_allocated_width(s->view))*(unsigned)scale!=width ||
        (uint64_t)MAX(0,gtk_widget_get_allocated_height(s->view))*(unsigned)scale!=height)
        return ZWK_GEOMETRY_NOT_APPLIED;
    return ZWK_OK;
}
static int session_region_size(ZwkState *s,int32_t left,int32_t top,int32_t right,int32_t bottom,int visible) {
    if (!s->region || !s->view || s->parent_destroying) return ZWK_CLOSED;
    int scale=MAX(1,gtk_widget_get_scale_factor(s->view));
    int x=floor_scale(left,scale),y=floor_scale(top,scale);
    int64_t width=(int64_t)ceil_scale(right,scale)-x,height=(int64_t)ceil_scale(bottom,scale)-y;
    if (right<left || bottom<top || width>32768 || height>32768) return ZWK_INVALID;
    gboolean shown=visible && width>0 && height>0;
    gtk_widget_set_child_visible(s->view,FALSE);
    if (!live(s) || s->parent_destroying) return ZWK_CLOSED;
    int result=content_result(zlg_region_viewport(s->region,x,y,(int)width,(int)height,shown));
    if (result!=ZWK_OK || !live(s) || s->parent_destroying) return result==ZWK_OK?ZWK_CLOSED:result;
    /* Empty viewports hide while retaining the last nonempty DOM allocation. */
    if (width && height) result=session_size(s,(uint32_t)(width*scale),(uint32_t)(height*scale),x,y);
    if (result!=ZWK_OK) return result;
    gtk_widget_set_child_visible(s->view,shown);
    if (!live(s) || s->parent_destroying) return ZWK_CLOSED;
    return ZWK_OK;
}
int zwk_session_park(ZwkState *s,uint64_t epoch) {
    retain(s);
    int result=ZWK_CLOSED;
    if (live(s) && s->session) {
        if (s->placement_busy) result=ZWK_FULL;
        else if (epoch!=s->session_epoch && s->region) result=ZWK_INVALID;
        else {
            s->placement_busy=TRUE;
            ZlgRegionHost *host=s->region; s->region=NULL; s->session_parent=NULL;
            if (host) zlg_region_detach(host);
            s->parent_destroying=FALSE; s->session_visible=FALSE;
            result=session_size(s,s->session_width,s->session_height,0,0);
            s->placement_busy=FALSE;
        }
    }
    release(s); return result;
}
int zwk_session_size(ZwkState *s,uint32_t *width,uint32_t *height) {
    if (!live(s) || !s->session || !s->view) return ZWK_CLOSED;
    const unsigned scale=(unsigned)MAX(1,gtk_widget_get_scale_factor(s->view));
    const uint64_t w=(uint64_t)MAX(0,gtk_widget_get_allocated_width(s->view))*scale;
    const uint64_t h=(uint64_t)MAX(0,gtk_widget_get_allocated_height(s->view))*scale;
    if (!w || !h || w>UINT32_MAX || h>UINT32_MAX) return ZWK_GEOMETRY_NOT_APPLIED;
    *width=(uint32_t)w; *height=(uint32_t)h;
    return ZWK_OK;
}
int zwk_session_mount(ZwkState *s,void *window,int32_t left,int32_t top,int32_t right,int32_t bottom,int visible,uint64_t epoch) {
    retain(s);
    if (!live(s) || !s->session) { release(s); return ZWK_CLOSED; }
    if (s->placement_busy) { release(s); return ZWK_FULL; }
    if (!epoch || (s->region?(s->session_epoch!=epoch || s->session_parent!=window):epoch<s->session_epoch)) {
        release(s); return ZWK_INVALID;
    }
    int result=ZWK_OK;
    s->placement_busy=TRUE;
    const gboolean attaching=s->region==NULL;
    const int32_t old_left=s->session_left,old_top=s->session_top,old_right=s->session_right,old_bottom=s->session_bottom;
    const gboolean old_visible=s->session_visible;
    if (attaching) {
        ZlgRegionHost *host=NULL;
        result=content_result(zlg_region_prepare(window,s->view,&host));
        if (result!=ZWK_OK) goto done;
        /* The early hook must see this host before GTK enters set_parent. */
        s->region=host; s->session_epoch=epoch; s->session_parent=window; s->parent_destroying=FALSE;
        result=content_result(zlg_region_mount(host));
        if (result!=ZWK_OK || !live(s) || s->parent_destroying) { if (result==ZWK_OK) result=ZWK_CLOSED; goto failed; }
    }
    result=session_region_size(s,left,top,right,bottom,visible);
    if (result!=ZWK_OK) goto failed;
    s->session_left=left; s->session_top=top; s->session_right=right; s->session_bottom=bottom;
    s->session_visible=visible && right>left && bottom>top;
    if (right>left && bottom>top) {
        int scale=MAX(1,gtk_widget_get_scale_factor(s->view));
        s->session_width=(uint32_t)MAX(1,gtk_widget_get_allocated_width(s->view))*(unsigned)scale;
        s->session_height=(uint32_t)MAX(1,gtk_widget_get_allocated_height(s->view))*(unsigned)scale;
    }
    goto done;
failed:
    if (live(s)) {
        if (attaching || s->parent_destroying) {
            ZlgRegionHost *host=s->region; s->region=NULL; s->session_parent=NULL;
            if (host) zlg_region_detach(host);
            s->parent_destroying=FALSE;
            (void)session_size(s,s->session_width,s->session_height,0,0);
        } else (void)session_region_size(s,old_left,old_top,old_right,old_bottom,old_visible);
    }
done:
    s->placement_busy=FALSE;
    release(s); return result;
}
void zwk_session_parent_destroying(ZwkState *s,uint64_t epoch) {
    retain(s);
    if (live(s) && s->session && s->region && s->session_epoch==epoch) {
        s->parent_destroying=TRUE;
        zlg_region_parent_destroying(s->region);
    }
    release(s);
}
#endif
