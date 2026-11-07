/* When the GPU renderers sweep what they keep for later frames and no frame
   drew for a while: the textures of texts no frame drew in ZG_SWEEP_IDLE
   frames, and pooled render targets and captures no frame took since the
   sweep before. A renderer sweeps once ZG_SWEEP_EVERY frames went by since
   its last sweep, whichever way a frame was drawn, rather than at each
   multiple of it: frames that are drawn another way (a frame waiting for
   its drawable, one that changes nothing and presents nothing) would let
   an animation miss every multiple and never sweep, keeping a texture for
   each of its frames' transient drawing. Shared by the renderers' native
   code; frame counts are their own. */
#ifndef ZIGGURAT_GPU_SWEEP_H
#define ZIGGURAT_GPU_SWEEP_H
#include <stdint.h>
#define ZG_SWEEP_EVERY 120u
#define ZG_SWEEP_IDLE 240u
/* Whether frame `frame` sweeps, and if so, marks it the last that did. */
static inline int zg_sweep_due(uint64_t frame,uint64_t *swept){
    if(frame<*swept)*swept=frame;
    if(frame-*swept<ZG_SWEEP_EVERY)return 0;
    *swept=frame;return 1;
}
/* Whether what was last used at frame `used` sat idle long enough to go. */
static inline int zg_sweep_idle(uint64_t frame,uint64_t used,uint64_t idle){return frame>used&&frame-used>idle;}
#endif
