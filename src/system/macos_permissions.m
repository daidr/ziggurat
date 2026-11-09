/* The permissions macOS keeps in TCC (src/system/permissions.zig): checked
 * through the frameworks that guard them, asked for with their prompts, and
 * the guide's panel under System Settings.
 *
 * AVFoundation, EventKit and CoreBluetooth are loaded when a permission of
 * theirs is first checked, so that an app that never asks links none of
 * them. The guide's panel is an NSPanel that never takes the focus, so that
 * System Settings stays the active app while the user drags. A timer on the
 * main run loop follows System Settings through the window server, which
 * needs no permission, 30 times a second, moves the panel when the window
 * has moved and hides it while another app is in front. The card of the app
 * is the source of the drag; its item puts the app on the pasteboard as
 * Finder does. */
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdatomic.h>
#include <unistd.h>

enum {
    P_ACCESSIBILITY, P_SCREEN, P_INPUT, P_FULL_DISK, P_APP_MANAGEMENT, P_DEVELOPER,
    P_MICROPHONE, P_CAMERA, P_CALENDARS, P_REMINDERS, P_BLUETOOTH, P_MEDIA,
};
enum { S_UNKNOWN = 0, S_NOT_DETERMINED = 1, S_DENIED = 2, S_GRANTED = 3 };

/* The selectors of the frameworks loaded at run time. */
@interface NSObject (ZspFrameworks)
+ (NSInteger)authorizationStatusForMediaType:(NSString *)type;
+ (void)requestAccessForMediaType:(NSString *)type completionHandler:(void (^)(BOOL))handler;
+ (NSInteger)authorizationStatusForEntityType:(NSUInteger)type;
- (void)requestFullAccessToEventsWithCompletion:(void (^)(BOOL, NSError *))completion;
- (void)requestFullAccessToRemindersWithCompletion:(void (^)(BOOL, NSError *))completion;
- (void)requestAccessToEntityType:(NSUInteger)type completion:(void (^)(BOOL, NSError *))completion;
+ (NSInteger)authorization;
- (id)initWithDelegate:(id)delegate queue:(id)queue;
@end

typedef struct { double x, y, w, h; } ZspRect;
typedef struct { ZspRect bounds; int32_t layer; double alpha; } ZspWindow;
/* The panel geometry is exported by permissions.zig. A program can link this
 * object without ever analyzing that file (an import it never uses), so the
 * weak stand-ins below keep the link whole; the Zig definitions replace them
 * whenever the guide can be started at all. */
__attribute__((weak)) ZspRect zsp_panel_frame(ZspRect settings, double main_height, const ZspRect *screens, size_t count, double height) {
    (void)main_height; (void)screens; (void)count;
    return (ZspRect){settings.x, settings.y, settings.w, height};
}
__attribute__((weak)) double zsp_panel_width(ZspRect settings, double main_height, const ZspRect *screens, size_t count) {
    (void)main_height; (void)screens; (void)count;
    return settings.w;
}
__attribute__((weak)) int zsp_main_settings_window(const ZspWindow *windows, size_t count, ZspRect *out) {
    (void)windows; (void)count; (void)out;
    return 0;
}

int zsp_macos_major(void) {
    return (int)[[NSProcessInfo processInfo] operatingSystemVersion].majorVersion;
}

static int framework(const char *name) {
    char path[160];
    snprintf(path, sizeof path, "/System/Library/Frameworks/%s.framework/%s", name, name);
    return dlopen(path, RTLD_LAZY | RTLD_GLOBAL) != NULL;
}
static NSString *media_type(int permission) {
    if (!framework("AVFoundation")) return nil;
    void *symbol = dlsym(RTLD_DEFAULT, permission == P_CAMERA ? "AVMediaTypeVideo" : "AVMediaTypeAudio");
    return symbol ? *(NSString *__unsafe_unretained *)symbol : nil;
}
/* TCC's statuses as AVFoundation, EventKit and CoreBluetooth number them.
 * EventKit's 4, write only, isn't the access asked for. */
static int tcc_status(NSInteger value) {
    switch (value) {
    case 0: return S_NOT_DETERMINED;
    case 3: return S_GRANTED;
    default: return S_DENIED;
    }
}
static int granted(bool ok) { return ok ? S_GRANTED : S_DENIED; }

/* Full Disk Access has no API: read files only apps with it read, TCC's own
 * database of the user, then Safari's. */
static int full_disk_access(void) {
    NSString *home = NSHomeDirectory();
    if (!home.length) return S_UNKNOWN;
    NSString *tcc = [home stringByAppendingPathComponent:@"Library/Application Support/com.apple.TCC/TCC.db"];
    int fd = open(tcc.fileSystemRepresentation, O_RDONLY);
    if (fd >= 0) { close(fd); return S_GRANTED; }
    if (errno == EPERM || errno == EACCES) return S_DENIED;
    NSError *error = nil;
    NSArray *safari = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[home stringByAppendingPathComponent:@"Library/Safari"] error:&error];
    if (safari) return S_GRANTED;
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if (error.code == NSFileReadNoPermissionError || (underlying && (underlying.code == EPERM || underlying.code == EACCES))) return S_DENIED;
    return S_UNKNOWN;
}

int zsp_check(int permission) {
    @autoreleasepool {
        switch (permission) {
        case P_ACCESSIBILITY: return granted(AXIsProcessTrusted());
        case P_SCREEN: return granted(CGPreflightScreenCaptureAccess());
        case P_INPUT: return granted(CGPreflightListenEventAccess());
        case P_FULL_DISK: return full_disk_access();
        case P_MICROPHONE:
        case P_CAMERA: {
            NSString *type = media_type(permission);
            Class device = NSClassFromString(@"AVCaptureDevice");
            return type && device ? tcc_status([device authorizationStatusForMediaType:type]) : S_UNKNOWN;
        }
        case P_CALENDARS:
        case P_REMINDERS: {
            Class store = framework("EventKit") ? NSClassFromString(@"EKEventStore") : Nil;
            return store ? tcc_status([store authorizationStatusForEntityType:permission == P_REMINDERS ? 1 : 0]) : S_UNKNOWN;
        }
        case P_BLUETOOTH: {
            Class manager = framework("CoreBluetooth") ? NSClassFromString(@"CBManager") : Nil;
            if (!manager || ![manager respondsToSelector:@selector(authorization)]) return S_UNKNOWN;
            return tcc_status([manager authorization]);
        }
        default: return S_UNKNOWN;
        }
    }
}

/* macOS ends an app in a bundle that asks without saying why; a program
 * outside a bundle asks for the app that started it. */
static int described(NSArray<NSString *> *keys) {
    NSBundle *bundle = [NSBundle mainBundle];
    if (![bundle.bundlePath hasSuffix:@".app"]) return 1;
    for (NSString *key in keys)
        if (![bundle objectForInfoDictionaryKey:key]) return 0;
    return 1;
}

/* Kept: a request dies with its store, and Bluetooth asks while its manager
 * lives. */
static id event_store;
static id central_manager;

/* Waits for done or for the caller to give up; 2 when it gave up. */
static int wait_answer(dispatch_semaphore_t done, int *abandoned) {
    while (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) != 0)
        if (atomic_load_explicit((_Atomic int *)abandoned, memory_order_acquire)) return 2;
    return 0;
}

/* 0 with *status, 1 when the Info.plist lacks the usage description, 2
 * when the caller gave up while the user hadn't answered. */
int zsp_request(int permission, int *abandoned, int *status) {
    @autoreleasepool {
        int now = zsp_check(permission);
        *status = now;
        switch (permission) {
        case P_ACCESSIBILITY:
            if (now != S_GRANTED) *status = granted(AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES}));
            return 0;
        case P_SCREEN:
            if (now != S_GRANTED) *status = granted(CGRequestScreenCaptureAccess());
            return 0;
        case P_INPUT:
            if (now != S_GRANTED) *status = granted(CGRequestListenEventAccess());
            return 0;
        default: break;
        }
        if (now != S_NOT_DETERMINED) return 0;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        switch (permission) {
        case P_MICROPHONE:
        case P_CAMERA: {
            if (!described(@[permission == P_CAMERA ? @"NSCameraUsageDescription" : @"NSMicrophoneUsageDescription"])) return 1;
            [NSClassFromString(@"AVCaptureDevice") requestAccessForMediaType:media_type(permission) completionHandler:^(BOOL ok) { (void)ok; dispatch_semaphore_signal(done); }];
            break;
        }
        case P_CALENDARS:
        case P_REMINDERS: {
            Class store_class = NSClassFromString(@"EKEventStore");
            const BOOL modern = [store_class instancesRespondToSelector:@selector(requestFullAccessToEventsWithCompletion:)];
            NSString *key = permission == P_REMINDERS ? (modern ? @"NSRemindersFullAccessUsageDescription" : @"NSRemindersUsageDescription")
                                                      : (modern ? @"NSCalendarsFullAccessUsageDescription" : @"NSCalendarsUsageDescription");
            if (!described(@[key])) return 1;
            id store;
            @synchronized([NSProcessInfo processInfo]) {
                if (!event_store) event_store = [[store_class alloc] init];
                store = event_store;
            }
            void (^answer)(BOOL, NSError *) = ^(BOOL ok, NSError *error) { (void)ok; (void)error; dispatch_semaphore_signal(done); };
            if (modern && permission == P_CALENDARS) [store requestFullAccessToEventsWithCompletion:answer];
            else if (modern) [store requestFullAccessToRemindersWithCompletion:answer];
            else [store requestAccessToEntityType:permission == P_REMINDERS ? 1 : 0 completion:answer];
            break;
        }
        case P_BLUETOOTH: {
            if (!described(@[@"NSBluetoothAlwaysUsageDescription"])) return 1;
            @synchronized([NSProcessInfo processInfo]) {
                /* Its delegate would hear of the radio: the prompt shows
                 * without one. */
                if (!central_manager) central_manager = [[NSClassFromString(@"CBCentralManager") alloc] initWithDelegate:nil queue:nil];
            }
            /* CoreBluetooth calls no block: wait for the status to change. */
            while ((*status = zsp_check(permission)) == S_NOT_DETERMINED) {
                if (atomic_load_explicit((_Atomic int *)abandoned, memory_order_acquire)) return 2;
                usleep(250 * 1000);
            }
            return 0;
        }
        default: return 0;
        }
        if (wait_answer(done, abandoned)) return 2;
        *status = zsp_check(permission);
        return 0;
    }
}

/* ---- The guide ---- */

static const CGFloat panel_padding = 12, panel_radius = 16, card_height = 48, icon_size = 32, close_size = 18, drag_icon_size = 56;
/* System Settings is missing for a moment while it opens or changes pages:
 * this many ticks in a row end the guide, as 10 s without it ever showing
 * do. */
static const int settings_misses = 12;
static const NSTimeInterval settings_wait = 10, track_interval = 1.0 / 30;

@class ZspGuide;
static ZspGuide *active_guide; /* whose panel may show; main thread */

@interface ZspGuide : NSObject {
@public
    _Atomic int ended;
    int draggable;
    NSString *app, *name, *title;
    NSPanel *panel;
    NSTextField *label;
    NSView *border, *closeButton, *cardBox, *icon, *nameLabel, *hint, *hand, *card;
    NSTimer *timer;
    NSDate *started;
    CGFloat labelHeight;
    ZspRect last;
    int seen, misses, front, shown, dragging, dragBegan;
    NSPoint dragOrigin;
}
- (void)tick:(NSTimer *)timer;
- (void)stop;
@end

/* The app on the pasteboard, as System Settings takes it from Finder. */
@interface ZspAppWriter : NSObject <NSPasteboardWriting> {
@public
    NSString *path;
}
@end
@implementation ZspAppWriter
- (NSArray<NSPasteboardType> *)writableTypesForPasteboard:(NSPasteboard *)pasteboard {
    (void)pasteboard;
    return @[@"public.file-url", @"public.url", @"NSFilenamesPboardType", @"com.apple.pasteboard.promised-file-url", @"public.utf8-plain-text"];
}
- (id)pasteboardPropertyListForType:(NSPasteboardType)type {
    if ([type isEqualToString:@"public.file-url"] || [type isEqualToString:@"public.url"] || [type isEqualToString:@"com.apple.pasteboard.promised-file-url"])
        return [[NSURL fileURLWithPath:path] absoluteString];
    if ([type isEqualToString:@"NSFilenamesPboardType"]) return @[path];
    if ([type isEqualToString:@"public.utf8-plain-text"]) return path;
    return nil;
}
@end

@interface ZspDragCard : NSView <NSDraggingSource> {
@public
    __weak ZspGuide *guide;
}
@end
@implementation ZspDragCard
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:[NSCursor openHandCursor]]; }
- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    (void)session; (void)context;
    return NSDragOperationCopy;
}
- (BOOL)ignoreModifierKeysForDraggingSession:(NSDraggingSession *)session { (void)session; return YES; }
- (void)mouseDown:(NSEvent *)event {
    ZspGuide *g = guide;
    if (!g) return;
    g->dragOrigin = event.locationInWindow;
    g->dragBegan = 0;
}
- (void)mouseUp:(NSEvent *)event {
    (void)event;
    ZspGuide *g = guide;
    if (g) g->dragBegan = 0;
}
- (void)mouseDragged:(NSEvent *)event {
    ZspGuide *g = guide;
    if (!g || g->dragBegan) return;
    const NSPoint at = event.locationInWindow;
    if (hypot(at.x - g->dragOrigin.x, at.y - g->dragOrigin.y) <= 4) return;
    g->dragBegan = 1;
    ZspAppWriter *writer = [ZspAppWriter new];
    writer->path = g->app;
    NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:writer];
    NSImage *image = [[NSWorkspace sharedWorkspace] iconForFile:g->app];
    image.size = NSMakeSize(drag_icon_size, drag_icon_size);
    const NSPoint p = [self convertPoint:at fromView:nil];
    [item setDraggingFrame:NSMakeRect(p.x - drag_icon_size / 2, p.y - drag_icon_size / 2, drag_icon_size, drag_icon_size) contents:image];
    NSDraggingSession *session = [self beginDraggingSessionWithItems:@[item] event:event source:self];
    session.animatesToStartingPositionsOnCancelOrFail = YES;
    session.draggingFormation = NSDraggingFormationNone;
    /* System Settings, under the pointer, takes the drop. */
    g->dragging = 1;
    g->panel.ignoresMouseEvents = YES;
    g->panel.alphaValue = 0.72;
}
@end

static NSImage *symbol(NSString *name, NSString *description) {
    if (@available(macOS 11.0, *)) return [NSImage imageWithSystemSymbolName:name accessibilityDescription:description];
    return nil;
}
/* A rounded rectangle that stretches keeping its corners: a layer's corner
 * radius doesn't clip what NSVisualEffectView blurs from behind the window,
 * a mask does, and the window's shadow follows it. */
static NSImage *rounded_mask(CGFloat radius) {
    const CGFloat side = 2 * radius + 1;
    NSImage *image = [NSImage imageWithSize:NSMakeSize(side, side) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [[NSColor blackColor] set];
        [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius] fill];
        return YES;
    }];
    image.capInsets = NSEdgeInsetsMake(radius, radius, radius, radius);
    image.resizingMode = NSImageResizingModeStretch;
    return image;
}
static NSBox *new_box(NSColor *fill, CGFloat radius) {
    NSBox *box = [[NSBox alloc] initWithFrame:NSZeroRect];
    box.boxType = NSBoxCustom;
    box.titlePosition = NSNoTitle;
    box.borderWidth = 1;
    box.cornerRadius = radius;
    box.borderColor = [NSColor separatorColor];
    box.fillColor = fill;
    return box;
}
/* "Drag **MyApp** to the list above to allow **Accessibility**." */
static NSAttributedString *panel_text(NSString *app, NSString *permission) {
    NSMutableAttributedString *text = [NSMutableAttributedString new];
    NSArray *runs = @[@[@"Drag ", @NO], @[app, @YES], @[@" to the list above to allow ", @NO], @[permission, @YES], @[@".", @NO]];
    for (NSArray *run in runs) {
        NSFont *font = [run[1] boolValue] ? [NSFont boldSystemFontOfSize:13] : [NSFont systemFontOfSize:13];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:run[0] attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: [NSColor labelColor]}]];
    }
    return text;
}

@implementation ZspGuide
- (void)build:(CGFloat)width {
    panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, width, 100) styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    panel.level = NSFloatingWindowLevel;
    panel.releasedWhenClosed = NO;
    panel.opaque = NO;
    panel.backgroundColor = [NSColor clearColor];
    panel.hasShadow = YES;
    panel.hidesOnDeactivate = NO;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    panel.movableByWindowBackground = NO;
    NSVisualEffectView *effect = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    effect.material = NSVisualEffectMaterialPopover;
    effect.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    effect.state = NSVisualEffectStateActive;
    effect.maskImage = rounded_mask(panel_radius);
    panel.contentView = effect;

    border = new_box([NSColor clearColor], panel_radius);
    [effect addSubview:border];
    label = [NSTextField wrappingLabelWithString:@""];
    label.attributedStringValue = panel_text(name, title);
    [effect addSubview:label];

    NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
    button.bordered = NO;
    button.imagePosition = NSImageOnly;
    NSImage *xmark = symbol(@"xmark.circle.fill", @"Close");
    if (xmark) {
        button.image = xmark;
        button.contentTintColor = [NSColor secondaryLabelColor];
    } else {
        button.title = @"✕";
    }
    button.target = self;
    button.action = @selector(closePanel:);
    [effect addSubview:button];
    closeButton = button;

    /* The card: a box, the app's icon and name, a hint, and over them the
     * view the drag starts from, which gets every click on the card. */
    cardBox = new_box([[NSColor controlBackgroundColor] colorWithAlphaComponent:0.65], 10);
    [effect addSubview:cardBox];
    icon = [NSImageView imageViewWithImage:[[NSWorkspace sharedWorkspace] iconForFile:app]];
    [effect addSubview:icon];
    NSTextField *appLabel = [NSTextField labelWithString:name];
    appLabel.font = [NSFont systemFontOfSize:15];
    [effect addSubview:appLabel];
    nameLabel = appLabel;
    NSTextField *hintLabel = [NSTextField labelWithString:@"Drag"];
    hintLabel.font = [NSFont systemFontOfSize:9];
    hintLabel.textColor = [NSColor secondaryLabelColor];
    hintLabel.alignment = NSTextAlignmentCenter;
    [effect addSubview:hintLabel];
    hint = hintLabel;
    NSImage *handImage = symbol(@"hand.draw", @"Drag");
    if (handImage) {
        NSImageView *view = [NSImageView imageViewWithImage:handImage];
        view.contentTintColor = [NSColor secondaryLabelColor];
        [effect addSubview:view];
        hand = view;
    }
    ZspDragCard *source = [[ZspDragCard alloc] initWithFrame:NSZeroRect];
    source->guide = self;
    [effect addSubview:source];
    card = source;
}
- (void)layout:(CGFloat)w {
    const CGFloat textW = w - 2 * panel_padding - close_size - 6;
    label.preferredMaxLayoutWidth = textW;
    labelHeight = ceil(label.fittingSize.height);
    const CGFloat h = panel_padding + labelHeight + 8 + card_height + panel_padding;
    const NSRect c = NSMakeRect(panel_padding, panel_padding, w - 2 * panel_padding, card_height);
    border.frame = NSMakeRect(0, 0, w, h);
    label.frame = NSMakeRect(panel_padding, h - panel_padding - labelHeight, textW, labelHeight);
    closeButton.frame = NSMakeRect(w - panel_padding - close_size, h - panel_padding - close_size + 2, close_size, close_size);
    cardBox.frame = c;
    icon.frame = NSMakeRect(c.origin.x + 8, c.origin.y + (card_height - icon_size) / 2, icon_size, icon_size);
    nameLabel.frame = NSMakeRect(c.origin.x + 8 + icon_size + 8, c.origin.y + (card_height - 20) / 2, c.size.width - icon_size - 70, 20);
    hand.frame = NSMakeRect(NSMaxX(c) - 38, c.origin.y + 20, 24, 18);
    hint.frame = NSMakeRect(NSMaxX(c) - 44, c.origin.y + 6, 36, 12);
    card.frame = c;
    [panel invalidateCursorRectsForView:card];
}
/* Shows the panel under System Settings' window at frame, in the window
 * server's coordinates, or hides it. */
- (void)place:(ZspRect)frame show:(int)show {
    if (!show) {
        if (panel && shown) [panel orderOut:nil];
        shown = 0;
        return;
    }
    NSArray<NSScreen *> *screens = [NSScreen screens];
    if (!screens.count) return;
    const double mainHeight = screens[0].frame.size.height;
    ZspRect visible[16];
    size_t count = 0;
    for (NSScreen *screen in screens) {
        if (count == 16) break;
        const NSRect r = screen.visibleFrame;
        visible[count++] = (ZspRect){r.origin.x, r.origin.y, r.size.width, r.size.height};
    }
    const CGFloat w = zsp_panel_width(frame, mainHeight, visible, count);
    if (!panel) [self build:w];
    [self layout:w];
    const CGFloat h = panel_padding + labelHeight + 8 + card_height + panel_padding;
    const ZspRect target = zsp_panel_frame(frame, mainHeight, visible, count, h);
    [panel setFrame:NSMakeRect(target.x, target.y, target.w, target.h) display:YES];
    [panel invalidateShadow];
    if (!shown) [panel orderFrontRegardless];
    shown = 1;
}
- (void)closePanel:(id)sender {
    (void)sender;
    [self end];
}
- (void)end {
    atomic_store_explicit(&ended, 1, memory_order_release);
    [self place:(ZspRect){0} show:0];
}
- (void)endDrag {
    dragging = 0;
    dragBegan = 0;
    panel.ignoresMouseEvents = NO;
    panel.alphaValue = 1;
}
/* System Settings' process, 0 when it isn't running, and whether it is the
 * app in front. */
static pid_t settings_process(int *frontmost) {
    *frontmost = 0;
    NSArray<NSRunningApplication *> *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.systempreferences"];
    if (!apps.count) return 0;
    const pid_t pid = apps.firstObject.processIdentifier;
    NSRunningApplication *front = [NSWorkspace sharedWorkspace].frontmostApplication;
    *frontmost = front && front.processIdentifier == pid;
    return pid;
}
/* The bounds of System Settings' window, in the window server's
 * coordinates. */
static int settings_frame(pid_t pid, ZspRect *out) {
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!list) return 0;
    NSArray *windows = CFBridgingRelease(list);
    ZspWindow found[32];
    size_t count = 0;
    for (NSDictionary *window in windows) {
        if (count == 32) break;
        if ([window[(__bridge NSString *)kCGWindowOwnerPID] intValue] != pid) continue;
        CGRect bounds;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(__bridge NSString *)kCGWindowBounds], &bounds)) continue;
        NSNumber *alpha = window[(__bridge NSString *)kCGWindowAlpha];
        found[count++] = (ZspWindow){
            .bounds = {bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height},
            .layer = [window[(__bridge NSString *)kCGWindowLayer] intValue],
            .alpha = alpha ? alpha.doubleValue : 1,
        };
    }
    return zsp_main_settings_window(found, count, out);
}
- (void)tick:(NSTimer *)t {
    (void)t;
    if (atomic_load_explicit(&ended, memory_order_acquire)) return;
    int frontmost;
    const pid_t pid = settings_process(&frontmost);
    if (pid) {
        seen = 1;
        misses = 0;
    } else if (seen) {
        if (++misses >= settings_misses) {
            [self end];
            return;
        }
    } else if (-[started timeIntervalSinceNow] > settings_wait) {
        [self end];
        return;
    }
    if (dragging && !CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft)) [self endDrag];
    if (!draggable || !pid || active_guide != self) return;
    /* While a drag is on, System Settings is in front even when the window
     * server doesn't say so yet. */
    const int show = frontmost || dragging;
    ZspRect frame;
    if (settings_frame(pid, &frame) && (memcmp(&frame, &last, sizeof frame) != 0 || show != front || (show && !shown))) {
        last = frame;
        front = show;
        [self place:frame show:show];
    }
}
- (void)stop {
    [timer invalidate];
    timer = nil;
    atomic_store_explicit(&ended, 1, memory_order_release);
    if (active_guide == self) active_guide = nil;
    if (panel) {
        [panel orderOut:nil];
        [panel close];
    }
    panel = nil;
}
@end

static NSString *default_app(void) {
    NSString *bundle = [NSBundle mainBundle].bundlePath;
    if ([bundle hasSuffix:@".app"]) return bundle;
    NSString *executable = [NSBundle mainBundle].executablePath;
    return executable ?: bundle;
}
static NSString *app_name(NSString *path) {
    return [[[path stringByStandardizingPath] lastPathComponent] stringByDeletingPathExtension];
}

void *zsp_guide_start(int permission, int draggable, const char *app, const char *name, const char *title) {
    (void)permission;
    @autoreleasepool {
        ZspGuide *guide = [ZspGuide new];
        guide->draggable = draggable;
        guide->app = app[0] ? [NSString stringWithUTF8String:app] : default_app();
        guide->name = name[0] ? [NSString stringWithUTF8String:name] : app_name(guide->app);
        guide->title = [NSString stringWithUTF8String:title];
        guide->started = [NSDate date];
        if (!guide->app || !guide->name || !guide->title) return NULL;
        /* One panel shows at a time: the one before ends. */
        if (active_guide) [active_guide end];
        active_guide = guide;
        guide->timer = [NSTimer timerWithTimeInterval:track_interval target:guide selector:@selector(tick:) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:guide->timer forMode:NSRunLoopCommonModes];
        return (__bridge_retained void *)guide;
    }
}
int zsp_guide_ended(void *handle) {
    ZspGuide *guide = (__bridge ZspGuide *)handle;
    return atomic_load_explicit(&guide->ended, memory_order_acquire);
}
void zsp_guide_stop(void *handle) {
    @autoreleasepool {
        ZspGuide *guide = CFBridgingRelease(handle);
        [guide stop];
    }
}

/* Test hooks: lay the panel out under a window of System Settings at frame
 * (window server coordinates) without System Settings, and describe it. */
int zsp_test_guide_place(void *handle, double x, double y, double w, double h) {
    ZspGuide *guide = (__bridge ZspGuide *)handle;
    guide->started = [NSDate distantFuture];
    [guide place:(ZspRect){x, y, w, h} show:1];
    return guide->shown && guide->panel.visible;
}
int zsp_test_guide_describe(void *handle, double *frame, char *text, size_t capacity) {
    ZspGuide *guide = (__bridge ZspGuide *)handle;
    if (!guide->panel) return 0;
    const NSRect r = guide->panel.frame;
    frame[0] = r.origin.x; frame[1] = r.origin.y; frame[2] = r.size.width; frame[3] = r.size.height;
    const char *utf8 = guide->label.attributedStringValue.string.UTF8String;
    if (!utf8 || strlen(utf8) >= capacity) return 0;
    memcpy(text, utf8, strlen(utf8) + 1);
    return guide->panel.canBecomeKeyWindow ? 2 : 1;
}
void zsp_test_guide_close(void *handle) {
    ZspGuide *guide = (__bridge ZspGuide *)handle;
    [(NSButton *)guide->closeButton performClick:nil];
}
