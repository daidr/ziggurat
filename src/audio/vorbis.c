/* Ogg Vorbis from the pinned stb_vorbis in third_party/, behind a small API
 * of opaque handles. Each handle is used by one thread at a time; the decoder
 * allocates with the C runtime. */
#define STB_VORBIS_NO_STDIO
#define STB_VORBIS_NO_PUSHDATA_API
#include "third_party/stb_vorbis.c"

/* Borrows `data` until zg_vorbis_close. */
stb_vorbis *zg_vorbis_open(const unsigned char *data, int length, int *error) {
    return stb_vorbis_open_memory(data, length, error, NULL);
}

void zg_vorbis_info(stb_vorbis *self, int *rate, int *channels, unsigned *frames) {
    stb_vorbis_info info = stb_vorbis_get_info(self);
    *rate = (int)info.sample_rate;
    *channels = info.channels;
    *frames = stb_vorbis_stream_length_in_samples(self);
}

/* Frames decoded into `buffer`, interleaved; 0 at the end. */
int zg_vorbis_read(stb_vorbis *self, int channels, float *buffer, int samples) {
    return stb_vorbis_get_samples_float_interleaved(self, channels, buffer, samples);
}

int zg_vorbis_error(stb_vorbis *self) {
    return stb_vorbis_get_error(self);
}

/* Returns nonzero on success. */
int zg_vorbis_seek(stb_vorbis *self, unsigned frame) {
    return stb_vorbis_seek(self, frame);
}

void zg_vorbis_close(stb_vorbis *self) {
    stb_vorbis_close(self);
}
