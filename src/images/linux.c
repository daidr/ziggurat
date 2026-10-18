#include <gdk-pixbuf/gdk-pixbuf.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static gint references;
uint32_t zi_native_references(void) { return (uint32_t)g_atomic_int_get(&references); }
void *zi_create(void) { void *context = malloc(1); if (context) g_atomic_int_inc(&references); return context; }
void zi_destroy(void *context) { free(context); g_atomic_int_add(&references, -1); }
typedef struct { uint32_t width, height; int valid, seen; } ZiDimensions;
static void dimensions(GdkPixbufLoader *loader, int width, int height, gpointer context) {
    ZiDimensions *expected = context;
    expected->seen = 1;
    expected->valid = width > 0 && height > 0 && (uint32_t)width == expected->width && (uint32_t)height == expected->height;
    if (!expected->valid) gdk_pixbuf_loader_set_size(loader, 1, 1);
}
typedef struct { uint32_t domain; int32_t code; uint32_t native_domain; } ZiError;
static int capture(GError *error, ZiError *out) {
    if (!error) return 1;
    if (!out->domain) { out->domain = 2; out->code = error->code; out->native_domain = error->domain; }
    return error->domain == GDK_PIXBUF_ERROR && error->code == GDK_PIXBUF_ERROR_INSUFFICIENT_MEMORY ? 2 : 1;
}
int zi_decode(void *context, const uint8_t *bytes, uint32_t length, int format, uint32_t width, uint32_t height, uint8_t *out, ZiError *failure) {
    (void)context;
    *failure = (ZiError){0};
    if (format != 1 && format != 2 && format != 3) return -1;
    GError *error = NULL;
    GdkPixbufLoader *loader = gdk_pixbuf_loader_new_with_type(format == 1 ? "png" : format == 2 ? "jpeg" : "bmp", &error);
    if (!loader) { int result = capture(error, failure); if (error) g_error_free(error); return result; }
    g_atomic_int_inc(&references);
    ZiDimensions expected = { width, height, 0, 0 };
    g_signal_connect(loader, "size-prepared", G_CALLBACK(dimensions), &expected);
    int valid = gdk_pixbuf_loader_write(loader, bytes, length, &error);
    int result = error ? capture(error, failure) : 1;
    if (error) { g_error_free(error); error = NULL; }
    int closed = gdk_pixbuf_loader_close(loader, &error);
    if (error && !failure->domain) result = capture(error, failure);
    if (error) g_error_free(error);
    GdkPixbuf *pixbuf = gdk_pixbuf_loader_get_pixbuf(loader);
    valid = valid && closed && expected.seen && expected.valid && pixbuf;
    if (valid) valid = gdk_pixbuf_get_width(pixbuf) == (int)width && gdk_pixbuf_get_height(pixbuf) == (int)height && gdk_pixbuf_get_colorspace(pixbuf) == GDK_COLORSPACE_RGB && gdk_pixbuf_get_bits_per_sample(pixbuf) == 8;
    if (valid) {
        int channels = gdk_pixbuf_get_n_channels(pixbuf), stride = gdk_pixbuf_get_rowstride(pixbuf);
        const uint8_t *pixels = gdk_pixbuf_read_pixels(pixbuf);
        valid = (channels == 3 || channels == 4) && stride >= (int)(width * channels);
        if (valid) for (uint32_t y = 0; y < height; y++) for (uint32_t x = 0; x < width; x++) {
            const uint8_t *source = pixels + (size_t)y * stride + x * channels;
            uint8_t *target = out + ((size_t)y * width + x) * 4;
            memcpy(target, source, 3);
            target[3] = channels == 4 ? source[3] : 255;
        }
    }
    g_object_unref(loader);
    g_atomic_int_add(&references, -1);
    return valid ? 0 : result;
}
