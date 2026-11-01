/* AppKit message alerts and open/save panels for the system module. Each
   shows as a sheet of its window when the window is on screen and has no
   sheet yet, and as a window of its own otherwise; neither runs a modal
   loop, so the call that shows one returns at once and the answer comes
   from the run loop. */
#import "macos_system.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

/* Answers of an alert: a button's index, or one of these. */
enum { ANSWER_ESCAPE = -1, ANSWER_CANCELLED = -2 };
/* Sheet return codes, above NSAlertFirstButtonReturn's range. */
static const NSModalResponse code_base = 20000;

@interface ZsmAlert : ZsmLink {
@public
    NSAlert *alert;
    __weak NSWindow *parent;
    NSInteger cancel;
    int sheet, open;
}
- (BOOL)handleKey:(NSEvent *)event;
@end

static NSMutableArray<ZsmAlert *> *alerts;
static id alert_keys;

@implementation ZsmAlert
/* Ends the alert with an answer: the sheet's completion reports it. */
- (void)answer:(int32_t)value {
    if (!open) return;
    open = 0;
    [alerts removeObject:self];
    if (sheet) {
        NSWindow *window = [alert window];
        NSWindow *host = [window sheetParent];
        if (host) [host endSheet:window returnCode:code_base + value];
        else [self finish:value];
    } else {
        [[alert window] orderOut:nil];
        [self finish:value];
    }
}
- (void)zsmPressed:(NSButton *)button { [self answer:(int32_t)[button tag]]; }
/* Escape and Command-period press the cancel button, or close the alert
   without one, as AppKit's cancelOperation: would: a button has one key
   equivalent, which Return takes when the cancel button is the default. */
- (BOOL)handleKey:(NSEvent *)event {
    id responder = [[event window] firstResponder];
    if ([responder respondsToSelector:@selector(hasMarkedText)] && [responder hasMarkedText]) return NO;
    const NSEventModifierFlags flags = [event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask & ~NSEventModifierFlagCapsLock;
    NSString *characters = [event charactersIgnoringModifiers];
    const BOOL escape = (flags & ~NSEventModifierFlagFunction) == 0 && [characters isEqualToString:@"\x1b"];
    /* Shift may type the period, as on AZERTY. */
    const BOOL period = (flags & ~NSEventModifierFlagShift) == NSEventModifierFlagCommand && [characters isEqualToString:@"."];
    if (!escape && !period) return NO;
    NSArray<NSButton *> *buttons = [alert buttons];
    if (cancel >= 0 && (NSUInteger)cancel < [buttons count]) [[buttons objectAtIndex:(NSUInteger)cancel] performClick:nil];
    else [self answer:ANSWER_ESCAPE];
    return YES;
}
@end

static void watch_alert_keys(void) {
    if (alert_keys) return;
    alert_keys = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        for (ZsmAlert *link in [alerts copy]) if ([link->alert window] == [event window] && [link handleKey:event]) return nil;
        return event;
    }];
}

/* kind: 0 info, 1 warning, 2 error, 3 question. */
void *zsm_message_show(NSWindow *window, const char *title, const char *message, const char *const *labels, uint32_t count, uint32_t destructive, int32_t default_index, int32_t cancel_index, int kind, void *owner, uint64_t serial, ZsmDone done) {
    @autoreleasepool {
        if (!alerts) alerts = [NSMutableArray array];
        ZsmAlert *link = [[ZsmAlert alloc] initWithOwner:owner serial:serial done:done];
        NSAlert *alert = [[NSAlert alloc] init];
        link->alert = alert;
        link->cancel = cancel_index;
        [alert setAlertStyle:kind == 1 ? NSAlertStyleWarning : kind == 2 ? NSAlertStyleCritical : NSAlertStyleInformational];
        NSString *heading = zsm_string(title), *text = zsm_string(message);
        if ([heading length]) {
            [alert setMessageText:heading];
            [alert setInformativeText:text];
        } else [alert setMessageText:text];
        for (uint32_t i = 0; i < count; ++i) {
            NSButton *button = [alert addButtonWithTitle:zsm_string(labels[i])];
            [button setTag:(NSInteger)i];
            [button setTarget:link];
            [button setAction:@selector(zsmPressed:)];
            [button setKeyEquivalent:(int32_t)i == default_index ? @"\r" : @""];
            if ((destructive & (1u << i)) && [button respondsToSelector:@selector(setHasDestructiveAction:)]) [button setHasDestructiveAction:YES];
        }
        [alerts addObject:link];
        watch_alert_keys();
        link->open = 1;
        if (window && [window isVisible] && ![window attachedSheet]) {
            link->sheet = 1;
            link->parent = window;
            ZsmAlert *strong = link;
            [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
                const int32_t value = response >= code_base + ANSWER_CANCELLED && response < code_base + 64 ? (int32_t)(response - code_base) : ANSWER_ESCAPE;
                [strong finish:value];
            }];
        } else {
            [alert layout];
            NSWindow *panel = [alert window];
            [panel center];
            [panel makeKeyAndOrderFront:nil];
        }
        return (void *)CFBridgingRetain(link);
    }
}
/* Closes the alert; the request still reports, as dismissed. */
void zsm_message_cancel(void *handle) { [(__bridge ZsmAlert *)handle answer:ANSWER_CANCELLED]; }
/* Releases the record without reporting and closes the alert. */
void zsm_message_detach(void *handle) {
    @autoreleasepool {
        ZsmAlert *link = CFBridgingRelease(handle);
        link->owner = NULL;
        [link answer:ANSWER_CANCELLED];
    }
}
/* Test hooks: press a button, type a key, and read the buttons' roles. */
int zsm_message_press(void *handle, int32_t index) {
    ZsmAlert *link = (__bridge ZsmAlert *)handle;
    NSArray<NSButton *> *buttons = [link->alert buttons];
    if (!link->open || index < 0 || (NSUInteger)index >= [buttons count]) return 0;
    [[buttons objectAtIndex:(NSUInteger)index] performClick:nil];
    return 1;
}
int zsm_message_key(void *handle, const char *characters, uint32_t modifiers) {
    @autoreleasepool {
        ZsmAlert *link = (__bridge ZsmAlert *)handle;
        if (!link->open) return 0;
        NSString *text = zsm_string(characters);
        NSEvent *key = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:modifiers timestamp:0 windowNumber:[[link->alert window] windowNumber] context:nil characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:0];
        if ([link handleKey:key]) return 1;
        /* Return goes to the button whose key equivalent it is. */
        for (NSButton *button in [link->alert buttons])
            if ([[button keyEquivalent] isEqualToString:text] && [text length]) {
                [button performClick:nil];
                return 1;
            }
        return 0;
    }
}
int zsm_message_button(void *handle, int32_t index, int *is_default, int *is_destructive) {
    ZsmAlert *link = (__bridge ZsmAlert *)handle;
    NSArray<NSButton *> *buttons = [link->alert buttons];
    if (index < 0 || (NSUInteger)index >= [buttons count]) return 0;
    NSButton *button = [buttons objectAtIndex:(NSUInteger)index];
    *is_default = [[button keyEquivalent] isEqualToString:@"\r"];
    *is_destructive = [button respondsToSelector:@selector(hasDestructiveAction)] && [button hasDestructiveAction];
    return 1;
}
int zsm_message_is_sheet(void *handle) { return ((__bridge ZsmAlert *)handle)->sheet; }

/* ---- open and save panels ---- */

@interface ZsmChooser : ZsmLink {
@public
    NSSavePanel *panel;
    NSMutableArray<NSData *> *paths;
    NSArray<NSString *> *test_paths;
    int sheet, open;
}
@end
@implementation ZsmChooser
- (void)complete:(NSModalResponse)response {
    if (!open) return;
    open = 0;
    paths = [NSMutableArray array];
    if (response != NSModalResponseOK) {
        [self finish:-1];
        return;
    }
    if (test_paths) {
        for (NSString *path in test_paths) [paths addObject:[path dataUsingEncoding:NSUTF8StringEncoding]];
    } else {
        NSArray<NSURL *> *urls = [panel isKindOfClass:[NSOpenPanel class]] ? [(NSOpenPanel *)panel URLs] : ([panel URL] ? @[ [panel URL] ] : @[]);
        for (NSURL *url in urls) {
            if (![url isFileURL]) {
                [self finish:-3];
                return;
            }
            const char *bytes = [url fileSystemRepresentation];
            if (!bytes) {
                [self finish:-4];
                return;
            }
            [paths addObject:[NSData dataWithBytes:bytes length:strlen(bytes)]];
        }
    }
    [self finish:[paths count] ? (int32_t)[paths count] : -5];
}
- (void)end:(NSModalResponse)response {
    if (!open) return;
    if (sheet && [panel sheetParent]) [[panel sheetParent] endSheet:panel returnCode:response];
    else {
        [panel orderOut:nil];
        [self complete:response];
    }
}
@end

/* kind: 0 one file, 1 save, 2 several files, 3 a folder. Filters are
   extensions with their dot, or "*" for any file. */
void *zsm_chooser_show(NSWindow *window, int kind, const char *const *filters, uint32_t count, const char *suggested, void *owner, uint64_t serial, ZsmDone done) {
    @autoreleasepool {
        ZsmChooser *link = [[ZsmChooser alloc] initWithOwner:owner serial:serial done:done];
        NSSavePanel *panel;
        if (kind == 1) {
            panel = [NSSavePanel savePanel];
            [panel setNameFieldStringValue:zsm_string(suggested)];
        } else {
            NSOpenPanel *open = [NSOpenPanel openPanel];
            [open setCanChooseFiles:kind != 3];
            [open setCanChooseDirectories:kind == 3];
            [open setAllowsMultipleSelection:kind == 2];
            panel = open;
        }
        [panel setCanCreateDirectories:YES];
        NSMutableArray<UTType *> *types = [NSMutableArray array];
        BOOL any = kind == 3;
        for (uint32_t i = 0; i < count && !any; ++i) {
            if (!strcmp(filters[i], "*")) {
                any = YES;
                break;
            }
            UTType *type = [UTType typeWithFilenameExtension:zsm_string(filters[i] + 1)];
            if (type) [types addObject:type];
        }
        if (!any && [types count]) [panel setAllowedContentTypes:types];
        link->panel = panel;
        link->open = 1;
        ZsmChooser *strong = link;
        if (window && [window isVisible] && ![window attachedSheet]) {
            link->sheet = 1;
            [panel beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) { [strong complete:response]; }];
        } else {
            [panel beginWithCompletionHandler:^(NSModalResponse response) { [strong complete:response]; }];
        }
        return (void *)CFBridgingRetain(link);
    }
}
void zsm_chooser_path(void *handle, uint32_t index, const uint8_t **bytes, size_t *length) {
    ZsmChooser *link = (__bridge ZsmChooser *)handle;
    if (!link->paths || index >= [link->paths count]) {
        *bytes = NULL;
        *length = 0;
        return;
    }
    NSData *path = [link->paths objectAtIndex:index];
    *bytes = [path bytes];
    *length = [path length];
}
/* Hides the panel; its result still arrives, as cancelled. */
void zsm_chooser_cancel(void *handle) { [(__bridge ZsmChooser *)handle end:NSModalResponseCancel]; }
void zsm_chooser_detach(void *handle) {
    @autoreleasepool {
        ZsmChooser *link = CFBridgingRelease(handle);
        link->owner = NULL;
        [link end:NSModalResponseCancel];
    }
}
/* Test hooks: accept the panel with the given paths, and read what it
   shows. */
int zsm_chooser_accept(void *handle, const char *const *paths, uint32_t count) {
    @autoreleasepool {
        ZsmChooser *link = (__bridge ZsmChooser *)handle;
        if (!link->open) return 0;
        NSMutableArray<NSString *> *list = [NSMutableArray array];
        for (uint32_t i = 0; i < count; ++i) [list addObject:zsm_string(paths[i])];
        link->test_paths = list;
        [link end:NSModalResponseOK];
        return 1;
    }
}
int zsm_chooser_describe(void *handle, int *sheet, int *multiple, int *directories, int *types, char *name, size_t capacity) {
    @autoreleasepool {
        ZsmChooser *link = (__bridge ZsmChooser *)handle;
        *sheet = link->sheet;
        NSOpenPanel *open = [link->panel isKindOfClass:[NSOpenPanel class]] ? (NSOpenPanel *)link->panel : nil;
        *multiple = open ? [open allowsMultipleSelection] : 0;
        *directories = open ? [open canChooseDirectories] : 0;
        *types = (int)[[link->panel allowedContentTypes] count];
        const char *text = [[link->panel nameFieldStringValue] UTF8String] ?: "";
        strncpy(name, text, capacity - 1);
        name[capacity - 1] = 0;
        return link->open;
    }
}
