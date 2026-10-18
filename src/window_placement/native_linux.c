#include <gtk/gtk.h>
#include <gdk/gdkx.h>
#include <stdint.h>
#include <string.h>
typedef struct ZwpRect { int32_t x,y; uint32_t width,height; } ZwpRect;
typedef struct ZwpMonitor { ZwpRect bounds,work; char key[96]; uint32_t key_length,primary; } ZwpMonitor;
static int make_key(GdkMonitor *monitor,unsigned index,char output[96],uint32_t *length){
    const char *model=gdk_monitor_get_model(monitor); if(!model)model="monitor";
    int n=g_snprintf(output,96,"x11:%u:%s",index,model);
    if(n<0||n>=96||!g_utf8_validate(output,n,NULL))return 3;
    *length=(uint32_t)n;return 0;
}
int zwp_query(void *window,ZwpMonitor *output,uint32_t capacity,uint32_t *count){
    GdkDisplay *display=gtk_widget_get_display(GTK_WIDGET(window));
    if(!GDK_IS_X11_DISPLAY(display))return 1;
    int n=gdk_display_get_n_monitors(display);if(n<=0)return 2;if((unsigned)n>capacity)return 3;
    for(int i=0;i<n;i++){
        GdkMonitor *monitor=gdk_display_get_monitor(display,i);if(!monitor)return 2;
        GdkRectangle rect,work;gdk_monitor_get_geometry(monitor,&rect);gdk_monitor_get_workarea(monitor,&work);
        if(rect.width<=0||rect.height<=0||work.width<=0||work.height<=0)return 2;
        ZwpMonitor *out=&output[i];memset(out,0,sizeof(*out));
        out->bounds=(ZwpRect){rect.x,rect.y,(uint32_t)rect.width,(uint32_t)rect.height};
        out->work=(ZwpRect){work.x,work.y,(uint32_t)work.width,(uint32_t)work.height};
        int result=make_key(monitor,(unsigned)i,out->key,&out->key_length);if(result)return result;
        out->primary=gdk_monitor_is_primary(monitor);
    }
    *count=(uint32_t)n;return 0;
}
int zwp_metrics(void *window,char key[96],uint32_t *key_length,uint32_t insets[4],ZwpRect *client,ZwpRect *outer){
    GtkWidget *widget=GTK_WIDGET(window);GdkDisplay *display=gtk_widget_get_display(widget);
    if(!GDK_IS_X11_DISPLAY(display))return 1;
    GdkWindow *native=gtk_widget_get_window(widget);if(!native)return 2;
    GdkMonitor *current=gdk_display_get_monitor_at_window(display,native);if(!current)return 2;
    int count=gdk_display_get_n_monitors(display),index=-1;
    for(int i=0;i<count;i++)if(gdk_display_get_monitor(display,i)==current){index=i;break;}
    if(index<0)return 2;int result=make_key(current,(unsigned)index,key,key_length);if(result)return result;
    GdkRectangle frame;gdk_window_get_frame_extents(native,&frame);
    int x,y;if(!gdk_window_get_origin(native,&x,&y))return 2;
    int width=gdk_window_get_width(native),height=gdk_window_get_height(native);
    if(width<=0||height<=0||frame.width<=0||frame.height<=0)return 2;
    *client=(ZwpRect){x,y,(uint32_t)width,(uint32_t)height};
    *outer=(ZwpRect){frame.x,frame.y,(uint32_t)frame.width,(uint32_t)frame.height};
    /* Actual GdkWindow geometry, never gtk_window_get_size's pending request.
       Core uses STATIC gravity so its public client origin is the GDK origin. */
    insets[0]=(uint32_t)MAX(0,(int64_t)x-frame.x);insets[1]=(uint32_t)MAX(0,(int64_t)y-frame.y);
    insets[2]=(uint32_t)MAX(0,(int64_t)frame.x+frame.width-x-width);
    insets[3]=(uint32_t)MAX(0,(int64_t)frame.y+frame.height-y-height);
    return 0;
}
