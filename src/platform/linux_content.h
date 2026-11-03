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

/* Independent rectangular children under the original drawing area, which
 * the regions placed shape (zlg_region_shape) so that they show and take the
 * pointer where the content does not paint over them. A host owns its
 * references until detach; the caller keeps its original child ref.
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
/* Nonzero sends the wheel and the touchpad over the child to the drawing
 * area beneath it, at the same point, before the child sees them. */
void zlg_region_scroll_to_container(ZlgRegionHost *, int);
/* Nonzero gives the window's content, as its own keys (flag 32 of a key
 * press), the key presses the child passes on: those a web view's page left
 * unhandled. Tab and modifier keys on their own stay out. */
void zlg_region_forward_keys(ZlgRegionHost *, int);
/* What shows of the child: clip, the content's covers over it (count boxes
 * of x, y, width, height) and the radii of its box's corners from the
 * top-left clockwise, in the drawing area's device pixels. Until called the
 * child shows wherever it is placed. */
int zlg_region_shape(ZlgRegionHost *, const double clip[4], const double radii[4], const double *covers, unsigned count);
/* Nonzero moves the keyboard out of the child as Tab leaves it past its
 * ends, as a web view's page does: the content takes it as a Tab of its own
 * (flag 32 of a key press, Shift for back) from the child's node. */
void zlg_region_tab_focus(ZlgRegionHost *, int);
/* Whether the child has the keyboard. */
int zlg_region_has_focus(ZlgRegionHost *);
void zlg_region_detach(ZlgRegionHost *);
unsigned zlg_region_count(void);

#endif
