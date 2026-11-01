/* AppKit menus for the system module: a window's menu bar, which is the
   application's main menu while its window is the main window; popup menus;
   status items (the menu bar extras of NSStatusBar); the Dock menu and the
   Dock tile's badge and progress. Menus are built from the flat item list
   menus.zig validated: parents come before their children. */
#import "macos_system.h"
#include <stdatomic.h>
#include <string.h>

static atomic_int live_links;
int32_t zsm_live_links(void) { return atomic_load(&live_links); }

@implementation ZsmLink
- (instancetype)initWithOwner:(void *)value serial:(uint64_t)number done:(ZsmDone)callback {
    if ((self = [super init])) {
        owner = value;
        serial = number;
        done = callback;
        atomic_fetch_add(&live_links, 1);
    }
    return self;
}
- (void)dealloc { atomic_fetch_sub(&live_links, 1); }
- (void)finish:(int32_t)result {
    /* The owner may release this record from its callback. */
    __attribute__((objc_precise_lifetime)) ZsmLink *keep = self;
    (void)keep;
    void *target = owner;
    owner = NULL;
    if (target && done) done(target, serial, result);
}
@end

NSString *zsm_string(const char *text) { return text ? ([NSString stringWithUTF8String:text] ?: @"") : @""; }
double zsm_primary_height(void) {
    NSArray<NSScreen *> *screens = [NSScreen screens];
    return [screens count] ? [[screens objectAtIndex:0] frame].size.height : 0;
}

typedef struct ZsmItem {
    const char *label;
    int32_t parent;
    uint8_t kind, enabled, checked, radio;
    uint32_t key, modifiers;
    int32_t command;
    void *icon;
    int32_t role;
} ZsmItem;
enum { KIND_COMMAND = 0, KIND_SUBMENU = 1, KIND_SEPARATOR = 2 };

/* Standard roles AppKit performs itself, by the codes macos.zig passes:
   the Edit commands go to the first responder, the window's view or page,
   and the application's own to NSApp. */
static SEL role_selector(int32_t role) {
    switch (role) {
    case 1: return @selector(undo:);
    case 2: return @selector(redo:);
    case 3: return @selector(cut:);
    case 4: return @selector(copy:);
    case 5: return @selector(paste:);
    case 6: return @selector(pasteAsPlainText:);
    case 7: return @selector(delete:);
    case 8: return @selector(selectAll:);
    case 9: return @selector(orderFrontStandardAboutPanel:);
    case 10: return @selector(hide:);
    case 11: return @selector(hideOtherApplications:);
    case 12: return @selector(unhideAllApplications:);
    case 13: return @selector(arrangeInFront:);
    case 14: return @selector(startSpeaking:);
    case 15: return @selector(stopSpeaking:);
    default: return NULL;
    }
}
enum { ROLE_SERVICES = 20, ROLE_WINDOWS = 21, ROLE_HELP = 22 };
/* Roles the focus enables, so their menu has AppKit validate its items. */
static int role_validates(int32_t role) { return (role >= 1 && role <= 8) || role == 14 || role == 15; }

/* A disabled role item targets this object, which has none of the roles'
   actions: a menu that validates its items then disables it, where the
   first responder would enable it. */
@interface ZsmInert : NSObject
@end
@implementation ZsmInert
@end
static ZsmInert *inert(void) {
    static ZsmInert *value;
    if (!value) value = [[ZsmInert alloc] init];
    return value;
}

/* What a built menu keeps per command index: its item, the hidden "=" twin
   of a "+" key equivalent, and the role. */
@interface ZsmCommands : NSObject {
@public
    NSMutableArray<NSMenuItem *> *items;
    NSMutableArray *twins;
    NSMutableData *roles;
    /* The submenus AppKit keeps as its Services, Window and Help menus. */
    NSMenu *services, *windows, *help;
}
@end
@implementation ZsmCommands
- (instancetype)init {
    if ((self = [super init])) {
        items = [NSMutableArray array];
        twins = [NSMutableArray array];
        roles = [NSMutableData data];
    }
    return self;
}
- (int32_t)roleAt:(NSUInteger)index { return ((const int32_t *)[roles bytes])[index]; }
@end

static void apply_enabled(NSMenuItem *item, int32_t role, int enabled, id target) {
    [item setEnabled:enabled ? YES : NO];
    if (role_selector(role)) [item setTarget:enabled ? nil : inert()];
    else [item setTarget:target];
}

static NSString *key_string(uint32_t key) {
    if (!key) return @"";
    unichar character = (unichar)key;
    return [NSString stringWithCharacters:&character length:1];
}

/* Builds an NSMenu whose commands send zsmClicked: to `target` with their
   command index as the tag. `bar` leaves the icons off the top level. */
static NSMenu *build_menu(const ZsmItem *items, uint32_t count, id target, ZsmCommands *commands, int bar, NSString *title) {
    NSMenu *root = [[NSMenu alloc] initWithTitle:title ?: @""];
    NSMutableArray<NSMenu *> *menus = [NSMutableArray arrayWithCapacity:count];
    NSMutableSet<NSMenu *> *validating = [NSMutableSet set];
    for (uint32_t i = 0; i < count; ++i) {
        const ZsmItem *it = &items[i];
        NSMenu *parent = it->parent >= 0 && (NSUInteger)it->parent < [menus count] && [menus objectAtIndex:(NSUInteger)it->parent] != (id)[NSNull null] ? [menus objectAtIndex:(NSUInteger)it->parent] : root;
        [menus addObject:(id)[NSNull null]];
        if (it->kind == KIND_SEPARATOR) {
            [parent addItem:[NSMenuItem separatorItem]];
            continue;
        }
        NSString *label = zsm_string(it->label);
        SEL native = role_selector(it->role);
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:label action:it->kind == KIND_COMMAND ? (native ?: @selector(zsmClicked:)) : NULL keyEquivalent:key_string(it->key)];
        if (it->key) [item setKeyEquivalentModifierMask:it->modifiers];
        if (it->icon && !(bar && it->parent < 0)) [item setImage:(__bridge NSImage *)it->icon];
        if (it->kind == KIND_SUBMENU) {
            NSMenu *submenu = [[NSMenu alloc] initWithTitle:label];
            [submenu setAutoenablesItems:NO];
            [item setSubmenu:submenu];
            [item setEnabled:it->enabled ? YES : NO];
            [menus replaceObjectAtIndex:i withObject:submenu];
            if (commands && it->role == ROLE_SERVICES) commands->services = submenu;
            else if (commands && it->role == ROLE_WINDOWS) commands->windows = submenu;
            else if (commands && it->role == ROLE_HELP) commands->help = submenu;
            [parent addItem:item];
            continue;
        }
        [item setTag:it->command];
        [item setState:it->checked ? NSControlStateValueOn : NSControlStateValueOff];
        apply_enabled(item, it->role, it->enabled, target);
        [parent addItem:item];
        if (role_validates(it->role)) [validating addObject:parent];
        id twin = [NSNull null];
        if (it->key == '+') {
            /* Command-= zooms in too, as in other macOS apps: "+" is the
               shifted "=" on most layouts. */
            NSMenuItem *alternate = [[NSMenuItem alloc] initWithTitle:label action:[item action] keyEquivalent:@"="];
            [alternate setKeyEquivalentModifierMask:it->modifiers & ~NSEventModifierFlagShift];
            [alternate setTag:it->command];
            [alternate setHidden:YES];
            [alternate setAllowsKeyEquivalentWhenHidden:YES];
            apply_enabled(alternate, it->role, it->enabled, target);
            [parent addItem:alternate];
            twin = alternate;
        }
        if (commands) {
            [commands->items addObject:item];
            [commands->twins addObject:twin];
            int32_t role = it->role;
            [commands->roles appendBytes:&role length:sizeof role];
        }
    }
    [root setAutoenablesItems:[validating containsObject:root]];
    for (NSMenu *menu in validating) [menu setAutoenablesItems:YES];
    return root;
}

/* ---- menu bars ---- */

@interface ZsmBar : ZsmLink {
@public
    NSMenu *menu;
    ZsmCommands *commands;
    __weak NSWindow *window;
    uint64_t order;
}
@end

static NSMutableArray<ZsmBar *> *bars;
static uint64_t bar_order;
static id main_observer;

static int menu_is_ours(NSMenu *menu);
static void install(ZsmBar *bar) {
    if (!bar) {
        /* AppKit keeps the old menu bar for setMainMenu:nil, so an empty
           menu takes its place. */
        NSMenu *current = [NSApp mainMenu];
        if (!current || menu_is_ours(current) || [current numberOfItems]) [NSApp setMainMenu:[[NSMenu alloc] initWithTitle:@""]];
        return;
    }
    if ([NSApp mainMenu] != bar->menu) [NSApp setMainMenu:bar->menu];
    ZsmCommands *commands = bar->commands;
    if (commands->services && [NSApp servicesMenu] != commands->services) [NSApp setServicesMenu:commands->services];
    if (commands->windows && [NSApp windowsMenu] != commands->windows) [NSApp setWindowsMenu:commands->windows];
    if (commands->help && [NSApp helpMenu] != commands->help) [NSApp setHelpMenu:commands->help];
}
static int menu_is_ours(NSMenu *menu) {
    if (!menu) return 0;
    for (ZsmBar *bar in bars) if (bar->menu == menu) return 1;
    return 0;
}
/* The main menu belongs to the bar of the main window, or else to the bar
   set last. */
static void install_main_menu(void) {
    ZsmBar *chosen = nil;
    for (ZsmBar *bar in bars) {
        if (bar->window && [bar->window isMainWindow]) { chosen = bar; break; }
        if (!chosen || bar->order > chosen->order) chosen = bar;
    }
    install(chosen);
}

@implementation ZsmBar
- (void)zsmClicked:(NSMenuItem *)item {
    if (owner && done) done(owner, serial, (int32_t)[item tag]);
}
- (BOOL)validateMenuItem:(NSMenuItem *)item { return [item isEnabled]; }
@end

void *zsm_bar_set(NSWindow *window, const ZsmItem *items, uint32_t count, void *owner, uint64_t serial, ZsmDone done) {
    @autoreleasepool {
        if (!bars) bars = [NSMutableArray array];
        if (!main_observer) {
            main_observer = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeMainNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
                for (ZsmBar *bar in bars) if (bar->window == [note object]) { install(bar); return; }
            }];
        }
        ZsmBar *bar = [[ZsmBar alloc] initWithOwner:owner serial:serial done:done];
        bar->commands = [[ZsmCommands alloc] init];
        bar->menu = build_menu(items, count, bar, bar->commands, 1, @"");
        bar->window = window;
        bar->order = ++bar_order;
        const int replace = !menu_is_ours([NSApp mainMenu]) || [window isMainWindow];
        [bars addObject:bar];
        if (replace) install(bar);
        return (void *)CFBridgingRetain(bar);
    }
}
/* `restore` hands the main menu to another bar, or none, when it was this
   bar's; otherwise the bar replacing it takes it. */
void zsm_bar_remove(void *handle, int restore) {
    @autoreleasepool {
        ZsmBar *bar = CFBridgingRelease(handle);
        bar->owner = NULL;
        [bars removeObject:bar];
        if ([NSApp mainMenu] == bar->menu) {
            if (restore || [bars count]) install_main_menu();
        }
    }
}
int zsm_bar_state(void *handle, int32_t command, int enabled, int checked) {
    ZsmBar *bar = (__bridge ZsmBar *)handle;
    if (command < 0 || (NSUInteger)command >= [bar->commands->items count]) return 0;
    NSMenuItem *item = [bar->commands->items objectAtIndex:(NSUInteger)command];
    const int32_t role = [bar->commands roleAt:(NSUInteger)command];
    apply_enabled(item, role, enabled, bar);
    [item setState:checked ? NSControlStateValueOn : NSControlStateValueOff];
    id twin = [bar->commands->twins objectAtIndex:(NSUInteger)command];
    if (twin != [NSNull null]) apply_enabled(twin, role, enabled, bar);
    return 1;
}
int zsm_bar_icon(void *handle, int32_t command, void *icon) {
    ZsmBar *bar = (__bridge ZsmBar *)handle;
    if (command < 0 || (NSUInteger)command >= [bar->commands->items count]) return 0;
    NSMenuItem *item = [bar->commands->items objectAtIndex:(NSUInteger)command];
    if ([[item menu] supermenu] || [item menu] != bar->menu) [item setImage:(__bridge NSImage *)icon];
    return 1;
}
void *zsm_bar_menu(void *handle) { return (__bridge void *)((__bridge ZsmBar *)handle)->menu; }

/* The view that draws the window's content: the content view itself, or
   the ZigView inside a material container. */
static NSView *content_view(NSWindow *window) {
    NSView *root = [window contentView];
    Class zig = NSClassFromString(@"ZigView");
    if (!zig || !root || [root isKindOfClass:zig]) return root;
    NSMutableArray<NSView *> *queue = [NSMutableArray arrayWithObject:root];
    while ([queue count]) {
        NSView *view = [queue objectAtIndex:0];
        [queue removeObjectAtIndex:0];
        if ([view isKindOfClass:zig]) return view;
        [queue addObjectsFromArray:[view subviews]];
    }
    return root;
}

/* ---- popup menus ----
   AppKit tracks a popup menu in a loop of its own, so a popup opens from
   the run loop after the call that asks for it returns, and reports its
   choice once tracking ends. */

@interface ZsmStatus : ZsmLink {
@public
    NSStatusItem *statusItem;
    NSMenu *menu;
    ZsmCommands *commands;
    void (*event)(void *, uint64_t, int32_t, int32_t, int32_t);
    NSRect clicked, of;
    int opening;
}
@end

@interface ZsmPopup : ZsmLink {
@public
    NSMenu *menu;
    __weak NSWindow *window;
    __weak ZsmStatus *status;
    int kind;
    double x, y;
    int32_t chosen;
    int open, cancelled;
}
@end
@implementation ZsmPopup
- (void)zsmClicked:(NSMenuItem *)item { chosen = (int32_t)[item tag]; }
- (BOOL)validateMenuItem:(NSMenuItem *)item { return [item isEnabled]; }
- (void)zsmOpen {
    if (!owner) return;
    if (cancelled) { [self finish:-1]; return; }
    open = 1;
    ZsmStatus *tray = status;
    if (tray) {
        /* The status item places and tracks its own menu, with the button
           highlighted. Its own menu, if any, comes back afterwards. */
        NSMenu *previous = tray->statusItem.menu;
        tray->opening = 1;
        tray->statusItem.menu = menu;
        [tray->statusItem.button performClick:nil];
        if (tray->statusItem && tray->statusItem.menu == menu) tray->statusItem.menu = previous;
        tray->opening = 0;
    } else {
        NSView *view = nil;
        NSPoint location = NSZeroPoint;
        NSWindow *parent = window;
        if (parent && kind != 2) {
            view = content_view(parent);
            if (kind == 1) {
                location = NSMakePoint(x, y);
                if (![view isFlipped]) location.y = [view bounds].size.height - location.y;
            } else location = [view convertPoint:[parent mouseLocationOutsideOfEventStream] fromView:nil];
        } else if (kind == 2) location = NSMakePoint(x, zsm_primary_height() - y);
        else location = [NSEvent mouseLocation];
        [menu popUpMenuPositioningItem:nil atLocation:location inView:view];
    }
    open = 0;
    [self finish:chosen];
}
@end

void *zsm_popup_show(NSWindow *window, const ZsmItem *items, uint32_t count, int kind, double x, double y, void *owner, uint64_t serial, ZsmDone done) {
    @autoreleasepool {
        ZsmPopup *popup = [[ZsmPopup alloc] initWithOwner:owner serial:serial done:done];
        popup->menu = build_menu(items, count, popup, nil, 0, @"");
        popup->window = window;
        popup->kind = kind;
        popup->x = x;
        popup->y = y;
        popup->chosen = -1;
        [popup performSelector:@selector(zsmOpen) withObject:nil afterDelay:0 inModes:@[ NSRunLoopCommonModes ]];
        return (void *)CFBridgingRetain(popup);
    }
}
void *zsm_tray_popup(void *tray, const ZsmItem *items, uint32_t count, void *owner, uint64_t serial, ZsmDone done) {
    ZsmPopup *popup = (__bridge ZsmPopup *)zsm_popup_show(nil, items, count, 0, 0, 0, owner, serial, done);
    popup->status = (__bridge ZsmStatus *)tray;
    return (__bridge void *)popup;
}
/* Closes the menu; the request still reports, with no choice. */
void zsm_popup_cancel(void *handle) {
    ZsmPopup *popup = (__bridge ZsmPopup *)handle;
    popup->cancelled = 1;
    popup->chosen = -1;
    if (popup->open) [popup->menu cancelTracking];
}
/* Releases the record without reporting; a menu still open closes. */
void zsm_popup_detach(void *handle) {
    ZsmPopup *popup = CFBridgingRelease(handle);
    popup->owner = NULL;
    if (popup->open) [popup->menu cancelTracking];
    else [NSObject cancelPreviousPerformRequestsWithTarget:popup selector:@selector(zsmOpen) object:nil];
}
/* Test hooks: choose a command of an open popup, as a click would. */
int zsm_popup_is_open(void *handle) { return ((__bridge ZsmPopup *)handle)->open; }
int zsm_popup_choose(void *handle, int32_t command) {
    ZsmPopup *popup = (__bridge ZsmPopup *)handle;
    if (!popup->open) return 0;
    popup->chosen = command;
    [popup->menu cancelTracking];
    return 1;
}

/* ---- status items ---- */

/* A right-click, or a Control-click, which macOS takes for one. */
static int secondary_click(NSEvent *event) {
    if (!event) return 0;
    const NSEventType type = [event type];
    return type == NSEventTypeRightMouseUp || type == NSEventTypeRightMouseDown ||
           ((type == NSEventTypeLeftMouseUp || type == NSEventTypeLeftMouseDown) && ([event modifierFlags] & NSEventModifierFlagControl));
}

@implementation ZsmStatus
- (void)zsmClicked:(NSMenuItem *)item {
    if (owner && event) event(owner, serial, 3, (int32_t)[item tag], 0);
}
- (BOOL)validateMenuItem:(NSMenuItem *)item { return [item isEnabled]; }
/* Keeps where on screen the copy of the item the click was on is: macOS 26
   shows a menu bar item on each display from one window, so the click's
   place in that window, taken from the pointer's, finds the copy. */
- (void)noteClick:(NSEvent *)click {
    NSWindow *window = [statusItem.button window];
    if (!click || !window || [click window] != window) return;
    of = [window frame];
    NSPoint at = [NSEvent mouseLocation], in = [click locationInWindow];
    clicked = NSMakeRect(at.x - in.x, at.y - in.y, of.size.width, of.size.height);
}
- (void)zsmButton:(id)sender {
    (void)sender;
    [self handleClick:[NSApp currentEvent]];
}
- (void)handleClick:(NSEvent *)click {
    [self noteClick:click];
    if (!owner || !event || opening) return;
    NSRect frame = [self frame];
    const int32_t x = (int32_t)lround(NSMidX(frame)), y = (int32_t)lround(zsm_primary_height() - NSMinY(frame));
    event(owner, serial, secondary_click(click) ? 1 : 0, x, y);
}
/* The copy the user clicked last, while the item's window keeps the frame
   it had then, or else the window's frame. */
- (NSRect)frame {
    NSWindow *window = [statusItem.button window];
    if (!window) return NSZeroRect;
    NSRect current = [window frame];
    if (clicked.size.width > 0 && NSEqualRects(current, of)) return clicked;
    return current;
}
@end

static NSImage *status_image(void *icon) {
    NSImage *image = icon ? [(__bridge NSImage *)icon copy] : [[NSApp applicationIconImage] copy];
    if (!image) return nil;
    /* Menu bar icons are 18 points tall. */
    NSSize size = [image size];
    if (size.height > 0) [image setSize:NSMakeSize(size.width * 18 / size.height, 18)];
    return image;
}
static void status_text(ZsmStatus *status, const char *tooltip, const char *title) {
    NSStatusBarButton *button = status->statusItem.button;
    [button setToolTip:tooltip && tooltip[0] ? zsm_string(tooltip) : nil];
    [button setTitle:zsm_string(title)];
    [button setImagePosition:[button image] && title && title[0] ? NSImageLeft : NSImageOnly];
}

void *zsm_tray_show(void *icon, int template_image, const char *tooltip, const char *title, const char *autosave, void *owner, uint64_t serial, void (*event)(void *, uint64_t, int32_t, int32_t, int32_t)) {
    @autoreleasepool {
        ZsmStatus *status = [[ZsmStatus alloc] initWithOwner:owner serial:serial done:NULL];
        status->event = event;
        status->statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
        if (!status->statusItem) return NULL;
        if (autosave) [status->statusItem setAutosaveName:zsm_string(autosave)];
        NSStatusBarButton *button = status->statusItem.button;
        [button setTarget:status];
        [button setAction:@selector(zsmButton:)];
        [button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
        /* Digits of one width, so a changing number in the title keeps the
           item's width and the icons beside it in place. The menu bar's
           font at its size, set on the button, keeps AppKit's colors. */
        const CGFloat size = [[NSFont menuBarFontOfSize:0] pointSize];
        NSFont *font = [NSFont monospacedDigitSystemFontOfSize:size weight:NSFontWeightRegular];
        if (font) [button setFont:font];
        NSImage *image = status_image(icon);
        [image setTemplate:template_image ? YES : NO];
        [button setImage:image];
        status_text(status, tooltip, title);
        return (void *)CFBridgingRetain(status);
    }
}
int zsm_tray_update(void *handle, void *icon, int template_image, const char *tooltip, const char *title) {
    @autoreleasepool {
        ZsmStatus *status = (__bridge ZsmStatus *)handle;
        if (!status->statusItem) return 0;
        NSImage *image = status_image(icon);
        [image setTemplate:template_image ? YES : NO];
        [status->statusItem.button setImage:image];
        status_text(status, tooltip, title);
        return 1;
    }
}
/* The item's own menu, which AppKit opens on a click; none sends clicks. */
void zsm_tray_menu(void *handle, const ZsmItem *items, uint32_t count) {
    @autoreleasepool {
        ZsmStatus *status = (__bridge ZsmStatus *)handle;
        status->commands = [[ZsmCommands alloc] init];
        status->menu = count ? build_menu(items, count, status, status->commands, 0, @"") : nil;
        status->statusItem.menu = status->menu;
    }
}
int zsm_tray_frame(void *handle, double *x, double *y, double *width, double *height) {
    ZsmStatus *status = (__bridge ZsmStatus *)handle;
    NSRect frame = [status frame];
    if (frame.size.width <= 0) return 0;
    *x = frame.origin.x;
    *y = zsm_primary_height() - NSMaxY(frame);
    *width = frame.size.width;
    *height = frame.size.height;
    return 1;
}
int zsm_tray_pointer_over(void *handle) {
    ZsmStatus *status = (__bridge ZsmStatus *)handle;
    NSRect frame = [status frame];
    return frame.size.width > 0 && NSPointInRect([NSEvent mouseLocation], frame);
}
void zsm_tray_remove(void *handle) {
    @autoreleasepool {
        ZsmStatus *status = CFBridgingRelease(handle);
        status->owner = NULL;
        if (status->statusItem) [[NSStatusBar systemStatusBar] removeStatusItem:status->statusItem];
        status->statusItem = nil;
        status->menu = nil;
    }
}
/* Test hooks: press the button as AppKit would, with or without Control,
   and read what it shows. */
void zsm_tray_test_click(void *handle, int right, int control) {
    @autoreleasepool {
        ZsmStatus *status = (__bridge ZsmStatus *)handle;
        NSEvent *click = [NSEvent mouseEventWithType:right ? NSEventTypeRightMouseUp : NSEventTypeLeftMouseUp location:NSMakePoint(4, 4) modifierFlags:control ? NSEventModifierFlagControl : 0 timestamp:0 windowNumber:0 context:nil eventNumber:0 clickCount:1 pressure:0];
        [status handleClick:click];
    }
}
int zsm_tray_test_title_is(void *handle, const char *title) {
    @autoreleasepool {
        ZsmStatus *status = (__bridge ZsmStatus *)handle;
        return [[status->statusItem.button title] isEqualToString:zsm_string(title)];
    }
}
int zsm_tray_test_monospaced_digits(void *handle) {
    @autoreleasepool {
        ZsmStatus *status = (__bridge ZsmStatus *)handle;
        NSFont *font = [status->statusItem.button font];
        NSDictionary *attributes = @{NSFontAttributeName: font};
        const CGFloat one = [@"1" sizeWithAttributes:attributes].width, eight = [@"8" sizeWithAttributes:attributes].width;
        return fabs(one - eight) < 0.01;
    }
}
void *zsm_tray_test_menu(void *handle) { return (__bridge void *)((__bridge ZsmStatus *)handle)->statusItem.menu; }
/* Sends the action of a menu's item at a path of indices, as a click on it
   would, and reports whether the item was enabled to take it. */
int zsm_test_menu_perform(void *menu, const int32_t *path, uint32_t depth) {
    @autoreleasepool {
        NSMenu *current = (__bridge NSMenu *)menu;
        for (uint32_t i = 0; i + 1 < depth; ++i) {
            if (path[i] < 0 || path[i] >= [current numberOfItems]) return -1;
            current = [[current itemAtIndex:path[i]] submenu];
            if (!current) return -1;
        }
        if (!depth || path[depth - 1] < 0 || path[depth - 1] >= [current numberOfItems]) return -1;
        [current update];
        NSMenuItem *item = [current itemAtIndex:path[depth - 1]];
        if (![item isEnabled]) return 0;
        [current performActionForItemAtIndex:path[depth - 1]];
        return 1;
    }
}
/* Matches a key equivalent against a menu, as AppKit does for a key press. */
int zsm_test_menu_key(void *menu, const char *characters, uint32_t modifiers) {
    @autoreleasepool {
        NSString *text = zsm_string(characters);
        NSEvent *key = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:modifiers timestamp:0 windowNumber:0 context:nil characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:0];
        return [(__bridge NSMenu *)menu performKeyEquivalent:key] ? 1 : 0;
    }
}
/* Describes an item: its title, key equivalent and state, for the tests. */
int zsm_test_menu_item(void *menu, const int32_t *path, uint32_t depth, char *title, size_t capacity, uint32_t *key, uint32_t *modifiers, int *state, int *enabled, int *has_image) {
    @autoreleasepool {
        NSMenu *current = (__bridge NSMenu *)menu;
        NSMenuItem *item = nil;
        for (uint32_t i = 0; i < depth; ++i) {
            if (!current || path[i] < 0 || path[i] >= [current numberOfItems]) return 0;
            item = [current itemAtIndex:path[i]];
            if (i + 1 < depth) current = [item submenu];
        }
        if (!item) return 0;
        [[item menu] update];
        const char *text = [[item title] UTF8String] ?: "";
        strncpy(title, text, capacity - 1);
        title[capacity - 1] = 0;
        NSString *equivalent = [item keyEquivalent];
        *key = [equivalent length] ? [equivalent characterAtIndex:0] : 0;
        *modifiers = (uint32_t)[item keyEquivalentModifierMask];
        *state = (int)[item state];
        *enabled = [item isEnabled];
        *has_image = [item image] != nil;
        return 1;
    }
}
void *zsm_test_main_menu(void) { return (__bridge void *)[NSApp mainMenu]; }
int zsm_test_menu_count(void *menu) { return (int)[(__bridge NSMenu *)menu numberOfItems]; }

/* ---- the Dock ---- */

extern void zlm_app_set_dock_menu(void *menu);

@interface ZsmDock : ZsmLink {
@public
    NSMenu *menu;
}
@end
@implementation ZsmDock
- (void)zsmClicked:(NSMenuItem *)item {
    if (owner && done) done(owner, serial, (int32_t)[item tag]);
}
- (BOOL)validateMenuItem:(NSMenuItem *)item { return [item isEnabled]; }
@end

/* The menu the Dock adds above its own items, from the application
   delegate's applicationDockMenu:. Replaces any menu set before. */
void *zsm_dock_menu(const ZsmItem *items, uint32_t count, void *owner, uint64_t serial, ZsmDone done) {
    @autoreleasepool {
        ZsmDock *dock = [[ZsmDock alloc] initWithOwner:owner serial:serial done:done];
        dock->menu = build_menu(items, count, dock, nil, 0, @"");
        zlm_app_set_dock_menu((__bridge void *)dock->menu);
        return (void *)CFBridgingRetain(dock);
    }
}
void zsm_dock_remove(void *handle, int clear) {
    @autoreleasepool {
        ZsmDock *dock = CFBridgingRelease(handle);
        dock->owner = NULL;
        if (clear) zlm_app_set_dock_menu(NULL);
    }
}
void *zsm_dock_test_menu(void *handle) { return (__bridge void *)((__bridge ZsmDock *)handle)->menu; }

/* The application icon in the Dock, from PNG bytes; none restores the
   bundle's icon. */
int zsm_dock_icon(const uint8_t *png, size_t length) {
    @autoreleasepool {
        NSImage *image = nil;
        if (png) {
            image = [[NSImage alloc] initWithData:[NSData dataWithBytes:png length:length]];
            if (!image) return 0;
        }
        [NSApp setApplicationIconImage:image];
        return 1;
    }
}
/* The Dock tile's badge, as "3"; empty hides it. */
void zsm_dock_badge(const char *text) {
    @autoreleasepool { [[NSApp dockTile] setBadgeLabel:text && text[0] ? zsm_string(text) : nil]; }
}
int zsm_dock_test_badge_is(const char *text) {
    @autoreleasepool {
        NSString *badge = [[NSApp dockTile] badgeLabel];
        return text && text[0] ? [badge isEqualToString:zsm_string(text)] : badge == nil;
    }
}
static NSInteger attention_request;
/* Bounces the icon once, informational, until the app is active. */
void zsm_dock_attention(int urgent) {
    if (attention_request) [NSApp cancelUserAttentionRequest:attention_request];
    attention_request = 0;
    if (urgent && ![NSApp isActive]) attention_request = [NSApp requestUserAttention:NSInformationalRequest];
}

/* Progress under the icon in the Dock tile. NSProgressIndicator does not
   draw in a tile, which renders its content view offscreen, so the bar is
   two custom NSBoxes, which draw themselves. */
static NSView *progress_view;
static NSImageView *progress_icon;
static NSBox *progress_track, *progress_fill;
static double progress_value = -1;
static NSBox *progress_box(NSColor *fill, NSColor *border, CGFloat width, CGFloat radius) {
    NSBox *box = [[NSBox alloc] initWithFrame:NSZeroRect];
    [box setBoxType:NSBoxCustom];
    [box setTitlePosition:NSNoTitle];
    [box setFillColor:fill];
    [box setBorderColor:border];
    [box setBorderWidth:width];
    [box setCornerRadius:radius];
    [progress_view addSubview:box];
    return box;
}
/* state: 0 none, 1 indeterminate, 2 normal, 3 paused, 4 failed. */
void zsm_dock_progress(int state, double value) {
    @autoreleasepool {
        NSDockTile *tile = [NSApp dockTile];
        if (state == 0) {
            if (progress_view) {
                [tile setContentView:nil];
                progress_view = nil;
                progress_icon = nil;
                progress_track = progress_fill = nil;
                [tile display];
            }
            progress_value = -1;
            return;
        }
        const NSSize size = [tile size];
        const CGFloat height = 14, inset = 6;
        if (!progress_view) {
            const NSRect frame = NSMakeRect(0, 0, size.width, size.height);
            progress_view = [[NSView alloc] initWithFrame:frame];
            progress_icon = [[NSImageView alloc] initWithFrame:frame];
            [progress_view addSubview:progress_icon];
            progress_track = progress_box([NSColor colorWithSRGBRed:40 / 255.0 green:40 / 255.0 blue:40 / 255.0 alpha:200 / 255.0], [NSColor colorWithSRGBRed:160 / 255.0 green:160 / 255.0 blue:160 / 255.0 alpha:1], 1.5, height / 2);
            progress_fill = progress_box([NSColor systemBlueColor], [NSColor systemBlueColor], 0, height / 2);
            [tile setContentView:progress_view];
        }
        NSColor *fill = state == 4 ? [NSColor systemRedColor] : state == 3 ? [NSColor systemYellowColor] : [NSColor systemBlueColor];
        [progress_fill setFillColor:fill];
        [progress_fill setBorderColor:fill];
        [progress_icon setImage:[NSApp applicationIconImage]];
        const NSRect track = NSMakeRect(inset, inset, size.width - 2 * inset, height);
        [progress_track setFrame:track];
        if (state == 1) value = 1;
        NSRect bar = track;
        bar.size.width = fmax(height, track.size.width * value);
        [progress_fill setHidden:value <= 0];
        [progress_fill setFrame:bar];
        progress_value = value;
        [tile display];
    }
}
double zsm_dock_test_progress(void) { return progress_value; }

/* ---- images ---- */

/* An NSImage from PNG bytes, fit in a box of `box` points keeping its
   aspect (none for 0), retained for the caller. */
void *zsm_image_png(const uint8_t *data, size_t length, double box, int template_image) {
    @autoreleasepool {
        NSImage *image = [[NSImage alloc] initWithData:[NSData dataWithBytes:data length:length]];
        if (!image) return NULL;
        NSSize size = [image size];
        if (box > 0 && size.width > 0 && size.height > 0) {
            const double scale = box / fmax(size.width, size.height);
            [image setSize:NSMakeSize(size.width * scale, size.height * scale)];
        }
        [image setTemplate:template_image ? YES : NO];
        return (void *)CFBridgingRetain(image);
    }
}
/* An NSImage from straight-alpha RGBA pixels, at two pixels a point. */
void *zsm_image_rgba(uint32_t width, uint32_t height, const uint8_t *pixels) {
    @autoreleasepool {
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:NSBitmapFormatAlphaNonpremultiplied bytesPerRow:(NSInteger)width * 4 bitsPerPixel:32];
        if (!bitmap || ![bitmap bitmapData]) return NULL;
        memcpy([bitmap bitmapData], pixels, (size_t)width * height * 4);
        NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(width / 2.0, height / 2.0)];
        [image addRepresentation:bitmap];
        return (void *)CFBridgingRetain(image);
    }
}
void zsm_image_release(void *image) {
    if (image) CFRelease(image);
}

/* Test hook: sends an action, as a menu item targeting `target` would. */
int zsm_test_send_action(const char *selector, void *target) {
    @autoreleasepool { return [NSApp sendAction:NSSelectorFromString(zsm_string(selector)) to:(__bridge id)target from:nil] ? 1 : 0; }
}
/* Test hook: the action of a menu's item, by its path of indices. */
int zsm_test_menu_action_is(void *menu, const int32_t *path, uint32_t depth, const char *selector) {
    @autoreleasepool {
        NSMenu *current = (__bridge NSMenu *)menu;
        NSMenuItem *item = nil;
        for (uint32_t i = 0; i < depth; ++i) {
            if (!current || path[i] < 0 || path[i] >= [current numberOfItems]) return 0;
            item = [current itemAtIndex:path[i]];
            if (i + 1 < depth) current = [item submenu];
        }
        return item && [item action] == NSSelectorFromString(zsm_string(selector));
    }
}
void *zsm_test_window_view(void *window) { return (__bridge void *)content_view((__bridge NSWindow *)window); }
int zsm_test_services_menu_is(void *menu, const int32_t *path, uint32_t depth) {
    NSMenu *current = (__bridge NSMenu *)menu;
    NSMenuItem *item = nil;
    for (uint32_t i = 0; i < depth; ++i) {
        if (!current || path[i] < 0 || path[i] >= [current numberOfItems]) return 0;
        item = [current itemAtIndex:path[i]];
        current = [item submenu];
    }
    return current && [NSApp servicesMenu] == current;
}
