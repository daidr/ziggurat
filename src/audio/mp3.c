/* MP3 from the pinned minimp3 in third_party/, behind a small API of opaque
 * handles. Each handle is used by one thread at a time; the decoder
 * allocates with the C runtime. */
#define MINIMP3_IMPLEMENTATION
#define MINIMP3_FLOAT_OUTPUT
#define MINIMP3_NO_STDIO
#include "third_party/minimp3_ex.h"

#include <stdlib.h>

typedef size_t (*zg_audio_read)(void *buffer, size_t size, void *context);
typedef int (*zg_audio_seek)(uint64_t position, void *context);

typedef struct {
    mp3dec_ex_t decoder;
    mp3dec_io_t io;
} zg_mp3;

/* Returns 0 and a handle, or the decoder's negative error. The context's
 * callbacks stay valid until zg_mp3_close. Opening scans the whole input for
 * its frames, so that seeking is exact. */
int zg_mp3_open(zg_audio_read read, zg_audio_seek seek, void *context, zg_mp3 **out) {
    zg_mp3 *self = (zg_mp3 *)calloc(1, sizeof(zg_mp3));
    if (!self) return MP3D_E_MEMORY;
    self->io.read = read;
    self->io.read_data = context;
    self->io.seek = seek;
    self->io.seek_data = context;
    int result = mp3dec_ex_open_cb(&self->decoder, &self->io, MP3D_SEEK_TO_SAMPLE);
    if (result != 0 || self->decoder.info.channels == 0 || self->decoder.info.hz == 0) {
        mp3dec_ex_close(&self->decoder);
        free(self);
        return result != 0 ? result : MP3D_E_DECODE;
    }
    *out = self;
    return 0;
}

void zg_mp3_info(zg_mp3 *self, int *rate, int *channels, uint64_t *samples) {
    *rate = self->decoder.info.hz;
    *channels = self->decoder.info.channels;
    *samples = self->decoder.samples;
}

/* Interleaved samples; fewer than asked only at the end, or on an error,
 * which zg_mp3_error then reports. */
size_t zg_mp3_read(zg_mp3 *self, float *buffer, size_t samples) {
    return mp3dec_ex_read(&self->decoder, buffer, samples);
}

int zg_mp3_error(zg_mp3 *self) {
    return self->decoder.last_error;
}

/* Position in interleaved samples. */
int zg_mp3_seek(zg_mp3 *self, uint64_t sample) {
    return mp3dec_ex_seek(&self->decoder, sample);
}

void zg_mp3_close(zg_mp3 *self) {
    mp3dec_ex_close(&self->decoder);
    free(self);
}

