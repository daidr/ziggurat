#ifndef ZIGGURAT_LINUX_CONTENT_H
#define ZIGGURAT_LINUX_CONTENT_H

/* Private GTK3 content adapter. The caller holds a Window callback scope and
 * an owning, non-floating reference to the unparented child. All calls are on
 * the process main thread. Successful attach adds references, never consumes
 * the caller's reference; detach releases the host exactly once. */
typedef struct NativeWindow NativeWindow;
typedef struct ZlgContentHost ZlgContentHost;
typedef struct ZlgRegionLayer ZlgRegionLayer;
typedef struct ZlgRegionHost ZlgRegionHost;
enum ZlgContentResult {
    ZLG_CONTENT_OK=0,
    ZLG_CONTENT_CLOSED=1,
    ZLG_CONTENT_BUSY=2,
    ZLG_CONTENT_INVALID=3,
    ZLG_CONTENT_OOM=4
};

int zlg_content_attach(NativeWindow *, void *gtk_widget, ZlgContentHost **out);
void zlg_content_detach(ZlgContentHost *);
int zlg_content_focus(ZlgContentHost *);
unsigned zlg_content_count(void);

/* Independent rectangular children over the original drawing area. A host
 * owns its references until detach; the caller keeps its original child ref.
 * Coordinates are GTK logical integers. Attach starts hidden and empty. */
int zlg_region_attach(NativeWindow *, void *gtk_widget, ZlgRegionHost **out);
/* prepare owns a provisional host but leaves the child unparented. Publish
 * that host in the provider before mount: native parent destruction during
 * mount can then evacuate the layer synchronously. Neither this hook nor the
 * early destruction hook settles the ordinary detach responsibility. */
int zlg_region_prepare(NativeWindow *, void *gtk_widget, ZlgRegionHost **out);
int zlg_region_mount(ZlgRegionHost *);
void zlg_region_parent_destroying(ZlgRegionHost *);
int zlg_region_viewport(ZlgRegionHost *, int x, int y, int width, int height, int visible);
int zlg_region_focus(ZlgRegionHost *);
void zlg_region_detach(ZlgRegionHost *);
unsigned zlg_region_count(void);

#endif
