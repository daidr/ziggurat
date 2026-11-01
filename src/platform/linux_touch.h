/* Fingers on a touchscreen doing what the mouse and a touchpad do: a tap
   clicks where it landed, a finger held still ZLG_LONG_PRESS_MS or longer
   right-clicks, a finger moving past ZLG_TOUCH_SLOP scrolls the content under
   it along with it, and two scroll as their midpoint moves. Free of GDK; the
   window feeds it the touches GTK would otherwise turn into a mouse that
   presses where a finger lands and selects text as it moves. Its rules are
   tested by tests/linux_touch_test.c. */
#include <math.h>
#include <stdint.h>
#include <string.h>

enum { ZLG_TOUCH_SLOP = 8, ZLG_LONG_PRESS_MS = 500, ZLG_TOUCH_FINGERS = 10 };
enum { ZLG_TOUCH_SCROLL = 1, ZLG_TOUCH_TAP = 2 };
/* button: 1 primary, 3 secondary, as GDK numbers buttons. */
typedef struct ZlgTouchOutput { int kind, button; double x, y, dx, dy; } ZlgTouchOutput;
typedef struct ZlgTouchFinger { uint64_t sequence; double x, y; } ZlgTouchFinger;
typedef struct ZlgTouch {
    ZlgTouchFinger fingers[ZLG_TOUCH_FINGERS];
    uint32_t count;
    /* The only finger down stayed within the slop of where it landed, at
       start_x, start_y at time start. */
    int tap;
    uint32_t start;
    double start_x, start_y;
    /* Where the fingers last scrolled from: the finger, or the midpoint of
       the first two. */
    double x, y;
} ZlgTouch;

static int touch_find(const ZlgTouch *g, uint64_t sequence) {
    for (uint32_t i = 0; i < g->count; ++i) if (g->fingers[i].sequence == sequence) return (int)i;
    return -1;
}
static void touch_anchor(ZlgTouch *g) {
    ZlgTouchFinger a = g->fingers[0];
    g->x = a.x; g->y = a.y;
    if (g->count > 1) { ZlgTouchFinger b = g->fingers[1]; g->x = (a.x + b.x) / 2; g->y = (a.y + b.y) / 2; }
}
/* The content at the last point follows the fingers to x, y: the other way
   from a scroll bar's thumb. */
static int touch_scroll(ZlgTouch *g, double x, double y, ZlgTouchOutput *out) {
    int moved = x != g->x || y != g->y;
    if (moved) *out = (ZlgTouchOutput){ZLG_TOUCH_SCROLL, 0, g->x, g->y, g->x - x, g->y - y};
    g->x = x; g->y = y;
    return moved;
}
/* Forgets fingers that ended unseen, as under a grab: the first finger of new
   touches has none down beside it. */
static void zlg_touch_reset(ZlgTouch *g) { g->count = 0; g->tap = 0; }
static void zlg_touch_begin(ZlgTouch *g, uint64_t sequence, double x, double y, uint32_t time) {
    if (touch_find(g, sequence) >= 0 || g->count == ZLG_TOUCH_FINGERS) return;
    g->fingers[g->count++] = (ZlgTouchFinger){sequence, x, y};
    g->tap = g->count == 1;
    if (g->tap) { g->start = time; g->start_x = x; g->start_y = y; }
    touch_anchor(g);
}
/* Writes at most one output: the scroll the move makes. */
static int zlg_touch_move(ZlgTouch *g, uint64_t sequence, double x, double y, ZlgTouchOutput *out) {
    int index = touch_find(g, sequence);
    if (index < 0) return 0;
    g->fingers[index].x = x; g->fingers[index].y = y;
    if (index >= 2) return 0;
    if (g->count == 1) {
        if (g->tap && hypot(x - g->start_x, y - g->start_y) < ZLG_TOUCH_SLOP) return 0;
        g->tap = 0;
        return touch_scroll(g, x, y, out);
    }
    return touch_scroll(g, (g->fingers[0].x + g->fingers[1].x) / 2, (g->fingers[0].y + g->fingers[1].y) / 2, out);
}
/* Lifts a finger; canceled, as when the compositor takes the touch for its own
   gesture, it neither moves nor taps. Writes up to two outputs. */
static int zlg_touch_end(ZlgTouch *g, uint64_t sequence, double x, double y, uint32_t time, int canceled, ZlgTouchOutput out[2]) {
    int index = touch_find(g, sequence), count = 0;
    if (index < 0) return 0;
    if (!canceled) count += zlg_touch_move(g, sequence, x, y, &out[count]);
    memmove(&g->fingers[index], &g->fingers[index + 1], (g->count - (uint32_t)index - 1) * sizeof g->fingers[0]);
    g->count--;
    if (g->count > 0) { touch_anchor(g); return count; }
    if (g->tap && !canceled) out[count++] = (ZlgTouchOutput){ZLG_TOUCH_TAP, time - g->start >= ZLG_LONG_PRESS_MS ? 3 : 1, g->start_x, g->start_y, 0, 0};
    g->tap = 0;
    return count;
}
