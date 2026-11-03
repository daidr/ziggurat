/* What a test needs of a macOS window holding web views in its native UI:
   a repeating timer on the main run loop, the window made key, Tab pressed
   as the keyboard presses it, and the window's backing scale. */
#import <AppKit/AppKit.h>

typedef int (*ZwoTick)(void *);
/* Calls tick every interval milliseconds until it returns 0. */
void zwo_timer(unsigned interval, ZwoTick tick, void *context) {
    [NSTimer scheduledTimerWithTimeInterval:interval / 1000.0 repeats:YES block:^(NSTimer *timer) {
        if (!tick(context)) [timer invalidate];
    }];
}
/* Makes the window key in the active app: a page gives the keyboard back
   by Tab only in the key window, and focuses its elements only there. */
int zwo_activate(void *handle) {
    NSWindow *window = (__bridge NSWindow *)handle;
    if (!window) return 0;
    [NSApp activateIgnoringOtherApps:YES];
    [window makeKeyAndOrderFront:nil];
    return window.isKeyWindow ? 1 : 0;
}
/* Presses and releases Tab (Shift+Tab with shift) in the window, which
   gives it to its first responder. */
int zwo_tab(void *handle, int shift) {
    NSWindow *window = (__bridge NSWindow *)handle;
    if (!window) return 0;
    NSString *text = shift ? [NSString stringWithFormat:@"%C", (unichar)NSBackTabCharacter] : @"\t";
    for (int i = 0; i < 2; i++) {
        NSEvent *event = [NSEvent keyEventWithType:i == 0 ? NSEventTypeKeyDown : NSEventTypeKeyUp location:NSZeroPoint
            modifierFlags:shift ? NSEventModifierFlagShift : 0 timestamp:[[NSProcessInfo processInfo] systemUptime]
            windowNumber:window.windowNumber context:nil characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:0x30];
        [window sendEvent:event];
    }
    return 1;
}
/* Backing pixels per point of the window. */
double zwo_scale(void *handle) {
    NSWindow *window = (__bridge NSWindow *)handle;
    return window && window.backingScaleFactor > 0 ? window.backingScaleFactor : 1;
}
