/* Optional test-only baseline. This translation unit includes the production
   renderer once; it must not also link its ordinary native object. */
#include "../src/ui/linux.c"

Renderer *bench_create(uint32_t w, uint32_t h, float scale) {
  Renderer *s = zlc_create();
  if (!s)
    return NULL;
  CairoLayers *l = zlc_layer_create(w, h, scale, 4, 0, w + 4, h + 4);
  if (!l) {
    zlc_destroy(s);
    return NULL;
  }
  zlc_layer_commit(s, l);
  return s;
}
int bench_begin(Renderer *s, const ZgTransform *value, uint32_t depth,
                uint32_t alpha) {
  layer_abort(s);
  if (layer_begin(s, s->width, s->height, s->scale))
    return 1;
  zlc_push_clip(s, .25f / s->scale, .25f / s->scale,
                (s->width - .5f) / s->scale, (s->height - .5f) / s->scale);
  for (uint32_t i = 0; i < depth; i++)
    if (zlc_layer_begin_transform(s, value))
      return 2;
  cairo_surface_flush(s->surface);
  uint32_t *p = (uint32_t *)cairo_image_surface_get_data(s->surface);
  uint32_t stride = (uint32_t)cairo_image_surface_get_stride(s->surface) / 4;
  for (uint32_t y = 1; y <= value->pixel_height; y++)
    for (uint32_t x = 1; x <= value->pixel_width; x++) {
      double cx = fmin(
                 1, fmax(0, (double)value->source_width * s->scale - (x - 1))),
             cy = fmin(
                 1, fmax(0, (double)value->source_height * s->scale - (y - 1)));
      uint32_t a = (uint32_t)round(alpha * cx * cy),
               r = (x * 3 + y * 7) % (a + 1), g = (x * 5 + y * 11) % (a + 1),
               b = (x * 7 + y * 13) % (a + 1);
      p[(size_t)y * stride + x] = (a << 24) | (r << 16) | (g << 8) | b;
    }
  cairo_surface_mark_dirty(s->surface);
  return 0;
}
int bench_flush(Renderer *s) {
  CairoLayers *l = s->layers;
  if (!l || !l->depth)
    return 1;
  CairoTarget *child = layer_current(l),
              *parent = &l->targets[l->depth > 1 ? l->depth : l->work];
  cairo_surface_flush(child->surface);
  cairo_surface_flush(parent->surface);
  return cairo_surface_status(child->surface) ||
         cairo_surface_status(parent->surface);
}
int bench_old_end(Renderer *s) {
  CairoLayers *l = s->layers;
  if (!l || !l->depth)
    return 1;
  CairoTarget *child = layer_current(l);
  CairoGroup *f = &l->groups[l->depth - 1];
  ZgTransform *v = &f->transform;
  l->depth--;
  CairoTarget *parent = layer_current(l);
  layer_alias(s, parent);
  s->gradient_clip_depth = f->clip_depth;
  memcpy(s->gradient_clips, f->clips, sizeof(f->clips));
  cairo_save(parent->context);
  cairo_matrix_t m;
  cairo_matrix_init(&m, v->xx, v->yx, v->xy, v->yy, v->x0, v->y0);
  cairo_transform(parent->context, &m);
  cairo_rectangle(parent->context, -1.0 / l->scale, -1.0 / l->scale,
                  (double)(v->pixel_width + 2) / l->scale,
                  (double)(v->pixel_height + 2) / l->scale);
  cairo_clip(parent->context);
  cairo_pattern_set_filter(child->pattern, CAIRO_FILTER_BILINEAR);
  cairo_set_source(parent->context, child->pattern);
  cairo_paint(parent->context);
  cairo_restore(parent->context);
  cairo_surface_flush(parent->surface);
  return cairo_status(parent->context) || cairo_surface_status(parent->surface);
}
void bench_counts(Renderer *s, uint64_t *creations, uint32_t *objects) {
  *creations = s->layers->stats.native_creations;
  *objects = live_layer_objects;
}
uint32_t bench_drop(Renderer *s) {
  zlc_destroy(s);
  return live_layer_objects + live_image_objects;
}
