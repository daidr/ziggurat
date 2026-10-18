#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define NO_STRICT
#include <windows.h>
#include <objbase.h>
#include <wincodec.h>
#include <stdint.h>
#include <string.h>

typedef struct { IWICImagingFactory *factory; } ZiWorker;
static volatile LONG references;
#define OWN(p) do { if (p) InterlockedIncrement(&references); } while (0)
#define DROP(Type,p) do { if (p) { Type##_Release(p); InterlockedDecrement(&references); } } while (0)
uint32_t zi_native_references(void) { return (uint32_t)InterlockedCompareExchange(&references, 0, 0); }

void *zi_create(void) {
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr)) return NULL;
    ZiWorker *worker = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*worker));
    if (worker) hr = CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory, (void **)&worker->factory);
    if (worker) OWN(worker->factory);
    if (!worker || FAILED(hr)) {
        if (worker) DROP(IWICImagingFactory, worker->factory);
        if (worker) HeapFree(GetProcessHeap(), 0, worker);
        CoUninitialize();
        return NULL;
    }
    return worker;
}

void zi_destroy(void *context) {
    ZiWorker *worker = context;
    DROP(IWICImagingFactory, worker->factory);
    HeapFree(GetProcessHeap(), 0, worker);
    CoUninitialize();
}

typedef struct { uint32_t domain; int32_t code; uint32_t native_domain; } ZiError;
int zi_decode(void *context, const uint8_t *bytes, uint32_t length, int format, uint32_t width, uint32_t height, uint8_t *out, ZiError *error) {
    ZiWorker *worker = context;
    IWICStream *stream = NULL;
    IWICBitmapDecoder *decoder = NULL;
    IWICBitmapFrameDecode *frame = NULL;
    IWICFormatConverter *converter = NULL;
    UINT actual_width = 0, actual_height = 0;
    GUID container;
    *error = (ZiError){0};
    int result = 1;
    HRESULT hr;
#define CALL(expression) do { hr = (expression); if (FAILED(hr)) { error->domain = 1; error->code = hr; goto done; } } while (0)
#define CREATE(expression, object) do { hr = (expression); OWN(object); if (FAILED(hr)) { error->domain = 1; error->code = hr; goto done; } } while (0)
    CREATE(IWICImagingFactory_CreateStream(worker->factory, &stream), stream);
    CALL(IWICStream_InitializeFromMemory(stream, (BYTE *)bytes, length));
    CREATE(IWICImagingFactory_CreateDecoderFromStream(worker->factory, (IStream *)stream, NULL, WICDecodeMetadataCacheOnDemand, &decoder), decoder);
    CALL(IWICBitmapDecoder_GetContainerFormat(decoder, &container));
    const GUID *expected = format == 1 ? &GUID_ContainerFormatPng : format == 2 ? &GUID_ContainerFormatJpeg : format == 3 ? &GUID_ContainerFormatBmp : NULL;
    if (!expected || memcmp(&container, expected, sizeof(GUID))) goto done;
    CREATE(IWICBitmapDecoder_GetFrame(decoder, 0, &frame), frame);
    CALL(IWICBitmapFrameDecode_GetSize(frame, &actual_width, &actual_height));
    if (actual_width != width || actual_height != height || !width || !height || width > UINT32_MAX / 4 || (uint64_t)width * height * 4 > UINT32_MAX) goto done;
    CREATE(IWICImagingFactory_CreateFormatConverter(worker->factory, &converter), converter);
    CALL(IWICFormatConverter_Initialize(converter, (IWICBitmapSource *)frame, &GUID_WICPixelFormat32bppRGBA, WICBitmapDitherTypeNone, NULL, 0, WICBitmapPaletteTypeCustom));
    CALL(IWICFormatConverter_CopyPixels(converter, NULL, width * 4, width * height * 4, out));
    result = 0;
done:
#undef CALL
#undef CREATE
    DROP(IWICFormatConverter, converter);
    DROP(IWICBitmapFrameDecode, frame);
    DROP(IWICBitmapDecoder, decoder);
    DROP(IWICStream, stream);
    return error->domain && error->code == E_OUTOFMEMORY ? 2 : result;
}
