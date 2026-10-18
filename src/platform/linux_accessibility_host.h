#ifndef ZIGGURAT_LINUX_ACCESSIBILITY_HOST_H
#define ZIGGURAT_LINUX_ACCESSIBILITY_HOST_H
#include <stdint.h>

/* Private GTK3 seam, not a document/text provider. All calls and native object
 * refs/unrefs are on the process main thread, even after App close. Supplying
 * NativeWindow requires a Window callback scope. A returned token thereafter
 * owns its lifetime independently of App/WindowRecord/Zig objects.
 *
 * The caller retains its original owning, non-floating AtkObject reference.
 * Its parent mutation is exclusive until withdraw and any in-flight mount
 * return; an invalidated provider object is not reused in another binding.
 * prepare leaves it undiscoverable. Publish the returned token before mount.
 * Only one prepared/mounted token is allowed per selected drawing area;
 * replacement explicitly withdraws the old token first.
 * Ordinary GTK callers keep an owning widget receiver reference across a
 * synchronous get_accessible call, including any reentrant destruction. Its
 * returned accessible is borrowed for that receiver lifetime.
 */
typedef struct NativeWindow NativeWindow;
typedef struct ZlgAccessibilityBinding ZlgAccessibilityBinding;

/* Receives only the retained child. C-only mark, no allocation/free, GTK,
 * notification or business/Zig callback. It may run during native destruction.
 * Invalid/OOM preparation never calls it. Accepted preparation arms it once. */
typedef void (*ZlgAccessibilityInvalidate)(void *atk_child);

enum ZlgAccessibilityResult {
    ZLG_ACCESSIBILITY_OK=0,
    ZLG_ACCESSIBILITY_CLOSED=1,
    ZLG_ACCESSIBILITY_BUSY=2,
    ZLG_ACCESSIBILITY_INVALID=3,
    ZLG_ACCESSIBILITY_OOM=4,
    ZLG_ACCESSIBILITY_UNSUPPORTED=5
};

/* Does not construct an accessible or register the optional GTypes. */
int zlg_accessibility_host_available(NativeWindow *);
int zlg_accessibility_prepare(NativeWindow *, void *nonfloating_atk_child,
    ZlgAccessibilityInvalidate, ZlgAccessibilityBinding **out);
/* Premutation refusal leaves the owned token withdrawable. Once the child slot
 * is published, returns OK even if a synchronous signal already retired it. */
int zlg_accessibility_mount(ZlgAccessibilityBinding *);
typedef struct ZlgAccessibilityPosition {
    int32_t window_x, window_y, screen_x, screen_y;
    uint32_t width, height, scale, flags;
} ZlgAccessibilityPosition;
enum ZlgAccessibilityPositionFlags {
    ZLG_ACCESSIBILITY_EXTENT=1,
    ZLG_ACCESSIBILITY_WINDOW_ORIGIN=2,
    ZLG_ACCESSIBILITY_SCREEN_ORIGIN=4
};
/* Explicit geometry-update snapshot, never a paint/ATK-getter operation.
 * GTK logical units. Only flagged fields are available. Unmapped/non-X11
 * areas expose extent/scale alone. Failure leaves output unchanged. The caller
 * owns its token across the call; no Window callback scope is needed here. */
int zlg_accessibility_position(ZlgAccessibilityBinding *, ZlgAccessibilityPosition *);
/* Idempotent. Retires ingress before foreign notifications; never consumes the
 * caller's token. release settles that token once, withdrawing it if necessary. */
void zlg_accessibility_withdraw(ZlgAccessibilityBinding *);
void zlg_accessibility_release(ZlgAccessibilityBinding *);
void zlg_accessibility_counts(unsigned *physical_tokens, unsigned *registered,
    unsigned *mounted);

#endif
