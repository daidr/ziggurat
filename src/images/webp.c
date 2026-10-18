#include <stddef.h>
#include <stdint.h>
#include "src/webp/decode.h"
#include "src/dec/vp8_dec.h"
#include "src/dsp/dsp.h"
#include "src/dsp/lossless.h"

/* Serialized until success before concurrent decode. VP8New also initializes
 * the pinned decoder's private coefficient dispatch, which DSP init omits. */
int zi_webp_initialize(void) {
    VP8Decoder *decoder=VP8New();
    if (!decoder) return VP8_STATUS_OUT_OF_MEMORY;
    VP8InitClipTables(); VP8DspInit(); VP8LDspInit();
    WebPInitUpsamplers(); WebPInitSamplers(); WebPInitYUV444Converters();
    WebPRescalerDspInit(); WebPInitAlphaProcessing(); VP8FiltersInit();
    VP8Delete(decoder);
    return VP8_STATUS_OK;
}
int zi_webp_inspect(const uint8_t *bytes, size_t length, uint32_t *width, uint32_t *height) {
    WebPBitstreamFeatures features;
    VP8StatusCode status=WebPGetFeatures(bytes,length,&features);
    if (status!=VP8_STATUS_OK) return status;
    if (features.has_animation) return 256;
    *width=(uint32_t)features.width;*height=(uint32_t)features.height;
    return 0;
}
int zi_webp_decode(const uint8_t *bytes, size_t length, uint32_t width, uint32_t height, uint8_t *pixels) {
    WebPDecoderConfig config;
    if (!WebPInitDecoderConfig(&config)) return VP8_STATUS_INVALID_PARAM;
    VP8StatusCode status=WebPGetFeatures(bytes,length,&config.input);
    if (status!=VP8_STATUS_OK) return status;
    if (config.input.has_animation || config.input.width!=(int)width || config.input.height!=(int)height) return VP8_STATUS_BITSTREAM_ERROR;
    config.options.use_threads=0;
    config.output.colorspace=MODE_RGBA;
    config.output.is_external_memory=1;
    config.output.u.RGBA.rgba=pixels;
    config.output.u.RGBA.stride=(int)(width*4);
    config.output.u.RGBA.size=(size_t)width*height*4;
    status=WebPDecode(bytes,length,&config);
    WebPFreeDecBuffer(&config.output);
    return status;
}
