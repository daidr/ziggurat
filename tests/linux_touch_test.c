/* The touchscreen gesture rules of linux_touch.h, free of GDK. */
#include <stdio.h>
#include <stdlib.h>
#include "../src/platform/linux_touch.h"

#define EXPECT(condition) do { if (!(condition)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); exit(1); } } while (0)

/* A tap clicks where it landed and a held finger right-clicks. */
static void taps(void) {
    ZlgTouch g = {0};
    ZlgTouchOutput out[2];
    zlg_touch_begin(&g, 1, 10, 20, 1000);
    EXPECT(zlg_touch_move(&g, 1, 13, 22, &out[0]) == 0);
    EXPECT(zlg_touch_end(&g, 1, 13, 22, 1100, 0, out) == 1);
    EXPECT(out[0].kind == ZLG_TOUCH_TAP && out[0].button == 1 && out[0].x == 10 && out[0].y == 20);
    zlg_touch_begin(&g, 2, 50, 50, 2000);
    EXPECT(zlg_touch_end(&g, 2, 50, 50, 2000 + ZLG_LONG_PRESS_MS, 0, out) == 1);
    EXPECT(out[0].button == 3);
    /* A canceled touch taps nothing. */
    zlg_touch_begin(&g, 3, 50, 50, 3000);
    EXPECT(zlg_touch_end(&g, 3, 50, 50, 3010, 1, out) == 0);
}

/* A finger past the slop scrolls the content along with it, and taps no more. */
static void scrolls(void) {
    ZlgTouch g = {0};
    ZlgTouchOutput out[2];
    zlg_touch_begin(&g, 1, 100, 100, 0);
    EXPECT(zlg_touch_move(&g, 1, 100, 105, &out[0]) == 0);
    EXPECT(zlg_touch_move(&g, 1, 100, 112, &out[0]) == 1);
    EXPECT(out[0].kind == ZLG_TOUCH_SCROLL && out[0].y == 100 && out[0].dy == -12);
    EXPECT(zlg_touch_move(&g, 1, 100, 102, &out[0]) == 1);
    EXPECT(out[0].y == 112 && out[0].dy == 10);
    EXPECT(zlg_touch_end(&g, 1, 100, 102, 200, 0, out) == 0);
}

/* Two fingers scroll as their midpoint moves, and lifting one taps nothing. */
static void pinches(void) {
    ZlgTouch g = {0};
    ZlgTouchOutput out[2];
    zlg_touch_begin(&g, 1, 0, 0, 0);
    zlg_touch_begin(&g, 2, 100, 0, 10);
    EXPECT(zlg_touch_move(&g, 2, 100, 20, &out[0]) == 1);
    EXPECT(out[0].x == 50 && out[0].dy == -10);
    /* A third finger is down but does not count. */
    zlg_touch_begin(&g, 3, 300, 300, 20);
    EXPECT(zlg_touch_move(&g, 3, 310, 310, &out[0]) == 0);
    EXPECT(zlg_touch_end(&g, 3, 310, 310, 30, 0, out) == 0);
    EXPECT(zlg_touch_end(&g, 1, 0, 0, 40, 0, out) == 0);
    /* The one left scrolls from where it is. */
    EXPECT(zlg_touch_move(&g, 2, 100, 30, &out[0]) == 1);
    EXPECT(out[0].y == 20 && out[0].dy == -10);
    EXPECT(zlg_touch_end(&g, 2, 100, 30, 50, 0, out) == 0);
    EXPECT(g.count == 0);
    /* A grab that hid the ends leaves no finger behind. */
    zlg_touch_begin(&g, 4, 0, 0, 60);
    zlg_touch_reset(&g);
    EXPECT(g.count == 0 && !g.tap);
}

int main(void) {
    taps();
    scrolls();
    pinches();
    puts("linux touch: ok");
    return 0;
}
