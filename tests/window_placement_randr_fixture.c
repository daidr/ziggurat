#include <X11/Xlib.h>
#include <X11/extensions/Xrandr.h>
#include <string.h>

/* Changes the first CRTC of an isolated Xvfb server to a smaller mode and
   back, so GDK observes a real monitor geometry change. */

static RRMode original_mode;
static unsigned original_width, original_height, screen_width, screen_height;

static int apply(Display *display, RRMode mode, unsigned width, unsigned height) {
    Window root = DefaultRootWindow(display);
    XRRScreenResources *resources = XRRGetScreenResources(display, root);
    if (!resources || resources->ncrtc < 1 || resources->noutput < 1) {
        if (resources) XRRFreeScreenResources(resources);
        return 1;
    }
    XRRCrtcInfo *crtc = XRRGetCrtcInfo(display, resources, resources->crtcs[0]);
    if (!crtc) {
        XRRFreeScreenResources(resources);
        return 1;
    }
    /* The screen must contain the CRTC: grow it first, shrink it last. */
    /* Xlib caches the screen size until it processes RandR events. */
    if (!screen_width) {
        screen_width = (unsigned)DisplayWidth(display, DefaultScreen(display));
        screen_height = (unsigned)DisplayHeight(display, DefaultScreen(display));
    }
    int grow = width > screen_width || height > screen_height;
    if (grow) XRRSetScreenSize(display, root, (int)width, (int)height, (int)(width * 254 / 960), (int)(height * 254 / 960));
    if (!original_mode) {
        original_mode = crtc->mode;
        original_width = crtc->width;
        original_height = crtc->height;
    }
    Status status = XRRSetCrtcConfig(display, resources, resources->crtcs[0], CurrentTime, 0, 0, mode, crtc->rotation, resources->outputs, 1);
    XRRFreeCrtcInfo(crtc);
    XRRFreeScreenResources(resources);
    if (status != RRSetConfigSuccess) return 2;
    if (!grow) XRRSetScreenSize(display, root, (int)width, (int)height, (int)(width * 254 / 960), (int)(height * 254 / 960));
    screen_width = width;
    screen_height = height;
    XSync(display, False);
    return 0;
}

/* Halves the first CRTC in device pixels, independent of GDK_SCALE. */
int zwpt_shrink_output(void *xdisplay) {
    Display *display = xdisplay;
    Window root = DefaultRootWindow(display);
    XRRScreenResources *resources = XRRGetScreenResources(display, root);
    if (!resources || resources->noutput < 1 || resources->ncrtc < 1) {
        if (resources) XRRFreeScreenResources(resources);
        return 1;
    }
    XRRCrtcInfo *crtc = XRRGetCrtcInfo(display, resources, resources->crtcs[0]);
    if (!crtc || crtc->width < 2 || crtc->height < 2) {
        if (crtc) XRRFreeCrtcInfo(crtc);
        XRRFreeScreenResources(resources);
        return 1;
    }
    unsigned width = crtc->width / 2, height = crtc->height / 2;
    XRRFreeCrtcInfo(crtc);
    char name[] = "ziggurat-placement-shrunk";
    XRRModeInfo info;
    memset(&info, 0, sizeof info);
    info.width = width;
    info.height = height;
    info.hTotal = width;
    info.vTotal = height;
    info.dotClock = (unsigned long)width * height * 60;
    info.name = name;
    info.nameLength = (unsigned)strlen(name);
    RRMode mode = XRRCreateMode(display, root, &info);
    XRRAddOutputMode(display, resources->outputs[0], mode);
    XRRFreeScreenResources(resources);
    return apply(display, mode, width, height);
}

int zwpt_restore_output(void *xdisplay) {
    if (!original_mode) return 0;
    return apply(xdisplay, original_mode, original_width, original_height);
}
