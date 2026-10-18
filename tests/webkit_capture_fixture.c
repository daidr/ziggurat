#include <cairo.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

typedef struct PngInput { const unsigned char *data;size_t length,at; } PngInput;
static cairo_status_t png_read(void *raw,unsigned char *out,unsigned int length) {
    PngInput *input=raw;
    if (length>input->length-input->at) return CAIRO_STATUS_READ_ERROR;
    memcpy(out,input->data+input->at,length);input->at+=length;
    return CAIRO_STATUS_SUCCESS;
}
int zcap_test_check_png(const unsigned char *data,size_t length,uint32_t width,uint32_t height) {
    static const unsigned char signature[]={137,80,78,71,13,10,26,10};
    if (length<33 || memcmp(data,signature,8) || memcmp(data+12,"IHDR",4)) return 1;
    const uint32_t png_width=((uint32_t)data[16]<<24)|((uint32_t)data[17]<<16)|((uint32_t)data[18]<<8)|data[19];
    const uint32_t png_height=((uint32_t)data[20]<<24)|((uint32_t)data[21]<<16)|((uint32_t)data[22]<<8)|data[23];
    if (!width || !height || width>1024 || height>1024 || png_width!=width || png_height!=height) return 2;
    PngInput input={data,length,0};
    cairo_surface_t *surface=cairo_image_surface_create_from_png_stream(png_read,&input);
    int failure=0;
    if (cairo_surface_status(surface)!=CAIRO_STATUS_SUCCESS) failure=3;
    else if ((uint32_t)cairo_image_surface_get_width(surface)!=width || (uint32_t)cairo_image_surface_get_height(surface)!=height) failure=4;
    else {
        const cairo_format_t format=cairo_image_surface_get_format(surface);
        if (format!=CAIRO_FORMAT_RGB24 && format!=CAIRO_FORMAT_ARGB32) failure=5;
        else {
            cairo_surface_flush(surface);
            unsigned char *pixels=cairo_image_surface_get_data(surface);
            const int stride=cairo_image_surface_get_stride(surface);
            for (uint32_t y=0;y<height && !failure;++y) for (uint32_t x=0;x<width;++x) {
                uint32_t value;memcpy(&value,pixels+(size_t)y*(size_t)stride+4*x,4);
                const uint32_t expected=x<width/2?0x204060u:0xe08020u;
                if ((value&0xffffffu)!=expected || (format==CAIRO_FORMAT_ARGB32 && value>>24!=255)) { failure=6;break; }
            }
        }
    }
    cairo_surface_destroy(surface);return failure;
}
