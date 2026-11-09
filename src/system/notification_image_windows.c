// The large icon a notification's balloon shows of its image.
#define COBJMACROS
#include <windows.h>
#include <wincodec.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* Fits an image of w by h pixels into a square box, keeping its aspect. */
static void fit_icon(UINT w, UINT h, int box, int *out_w, int *out_h) {
    *out_w = 0;
    *out_h = 0;
    if (w == 0 || h == 0 || box <= 0) return;
    if (w >= h) {
        *out_w = box;
        *out_h = (int)(((uint64_t)h * (uint64_t)box + w / 2) / w);
        if (*out_h < 1) *out_h = 1;
    } else {
        *out_h = box;
        *out_w = (int)(((uint64_t)w * (uint64_t)box + h / 2) / h);
        if (*out_w < 1) *out_w = 1;
    }
}

/* An icon of size by size pixels of an encoded image in any format WIC
   decodes (PNG, JPEG, ...): the image fit to the icon, centered on
   transparent pixels. NULL when WIC cannot decode it. The caller destroys
   the icon. COM must be initialized on the calling thread. */
HICON zsn_image_icon(const uint8_t *bytes, size_t length, int size) {
    if (bytes == NULL || length == 0 || length > 0xffffffffu || size <= 0 || size > 1024) return NULL;
    HICON icon = NULL;
    IWICImagingFactory *factory = NULL;
    IWICStream *stream = NULL;
    IWICBitmapDecoder *decoder = NULL;
    IWICBitmapFrameDecode *frame = NULL;
    IWICBitmapScaler *scaler = NULL;
    IWICBitmapSource *bgra = NULL;
    uint8_t *pixels = NULL;
    uint8_t *resource = NULL;
    if (FAILED(CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory, (void **)&factory))) goto done;
    if (FAILED(IWICImagingFactory_CreateStream(factory, &stream))) goto done;
    if (FAILED(IWICStream_InitializeFromMemory(stream, (BYTE *)bytes, (DWORD)length))) goto done;
    if (FAILED(IWICImagingFactory_CreateDecoderFromStream(factory, (IStream *)stream, NULL, WICDecodeMetadataCacheOnDemand, &decoder))) goto done;
    if (FAILED(IWICBitmapDecoder_GetFrame(decoder, 0, &frame))) goto done;
    UINT fw = 0, fh = 0;
    if (FAILED(IWICBitmapFrameDecode_GetSize(frame, &fw, &fh))) goto done;
    int w, h;
    fit_icon(fw, fh, size, &w, &h);
    if (w == 0) goto done;
    if (FAILED(IWICImagingFactory_CreateBitmapScaler(factory, &scaler))) goto done;
    if (FAILED(IWICBitmapScaler_Initialize(scaler, (IWICBitmapSource *)frame, (UINT)w, (UINT)h, WICBitmapInterpolationModeFant))) goto done;
    if (FAILED(WICConvertBitmapSource(&GUID_WICPixelFormat32bppBGRA, (IWICBitmapSource *)scaler, &bgra))) goto done;
    size_t stride = (size_t)w * 4;
    pixels = malloc(stride * (size_t)h);
    if (pixels == NULL) goto done;
    if (FAILED(IWICBitmapSource_CopyPixels(bgra, NULL, (UINT)stride, (UINT)(stride * (size_t)h), pixels))) goto done;
    /* An icon resource, as CreateIconFromResourceEx takes it: a header of
       twice the height, the pixels bottom-up with straight alpha, then the
       mask, which the alpha makes moot. */
    BITMAPINFOHEADER header;
    memset(&header, 0, sizeof header);
    header.biSize = sizeof header;
    header.biWidth = size;
    header.biHeight = 2 * size;
    header.biPlanes = 1;
    header.biBitCount = 32;
    size_t mask_stride = ((size_t)size + 31) / 32 * 4;
    size_t total = sizeof header + (size_t)size * (size_t)size * 4 + mask_stride * (size_t)size;
    resource = calloc(1, total);
    if (resource == NULL) goto done;
    memcpy(resource, &header, sizeof header);
    uint8_t *plane = resource + sizeof header;
    int left = (size - w) / 2, top = (size - h) / 2;
    for (int y = 0; y < h; y++) {
        int row = size - 1 - (top + y);
        memcpy(plane + ((size_t)row * (size_t)size + (size_t)left) * 4, pixels + (size_t)y * stride, stride);
    }
    icon = CreateIconFromResourceEx(resource, (DWORD)total, TRUE, 0x00030000, size, size, 0);
done:
    free(resource);
    free(pixels);
    if (bgra) IWICBitmapSource_Release(bgra);
    if (scaler) IWICBitmapScaler_Release(scaler);
    if (frame) IWICBitmapFrameDecode_Release(frame);
    if (decoder) IWICBitmapDecoder_Release(decoder);
    if (stream) IWICStream_Release(stream);
    if (factory) IWICImagingFactory_Release(factory);
    return icon;
}
