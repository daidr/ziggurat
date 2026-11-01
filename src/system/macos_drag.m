/* AppKit drag and drop for system.drop and system.drag: the same zsd_* and
   zst_* entry points as the GTK adapters, so drop.zig and drag.zig drive
   both. Everything runs on the main thread. Compiled with ARC.

   A window's content view (ZigView in src/platform/macos.m) forwards its
   NSDraggingDestination messages to the one drop target set on it, of
   either kind; the window's destruction unregisters it. Formats cross as
   MIME names: text/plain is public.utf8-plain-text, text/html public.html,
   image/png public.png, text/uri-list file URLs (one pasteboard item per
   file) or else public.url, and another name maps as the clipboard's custom
   formats do (zsc_custom_type). A pasteboard type with no such name is
   offered as its UTType's preferred MIME type, or as itself.

   A drag source is one pasteboard item whose types render lazily through
   the owner, plus one item per further file of a file list, which is
   rendered when the drag starts because AppKit needs every file item up
   front. AppKit has no call that ends a drag session early: cancel only
   silences the owner, and the session ends when the user lets go. */
#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

NSString *zsc_custom_type(const char *name, size_t len);

@interface NSView (ZigDrop)
- (void)setZigDropTarget:(id<NSDraggingDestination>)target;
- (id<NSDraggingDestination>)zigDropTarget;
@end

enum { PHASE_ENTER, PHASE_OVER, PHASE_LEAVE };
enum { STATUS_FILES, STATUS_TEXT, STATUS_TOO_MANY_FILES, STATUS_MALFORMED };
/* GDK action bits, as drop.zig and drag.zig read them. */
enum { ACTION_COPY = 2, ACTION_MOVE = 4 };
#define MAX_FILES 1024

static NSString *const mime_text = @"text/plain";
static NSString *const mime_html = @"text/html";
static NSString *const mime_png = @"image/png";
static NSString *const mime_uri_list = @"text/uri-list";

/* The window's ZigView: the content view itself, or a view inside it when
   the content view is a material container. */
static NSView *find_zig_view(NSView *view) {
    if (!view) return nil;
    if ([view respondsToSelector:@selector(setZigDropTarget:)]) return view;
    for (NSView *child in [view subviews]) {
        NSView *found = find_zig_view(child);
        if (found) return found;
    }
    return nil;
}
static NSView *content_view(void *handle) {
    NSWindow *window = (__bridge NSWindow *)handle;
    return find_zig_view([window contentView]);
}
/* The view's client point, top-left origin in points (ZigView is flipped). */
static NSPoint view_point(NSView *view, id<NSDraggingInfo> info) {
    return [view convertPoint:[info draggingLocation] fromView:nil];
}

/* The pasteboard type of a MIME name; nil for text/uri-list, which maps to
   file or web URLs, and for names only GTK uses. */
static NSString *type_for_mime(NSString *name) {
    if ([name isEqualToString:mime_text]) return NSPasteboardTypeString;
    if ([name isEqualToString:mime_html]) return NSPasteboardTypeHTML;
    if ([name isEqualToString:mime_png]) return NSPasteboardTypePNG;
    if ([name isEqualToString:mime_uri_list] || [name isEqualToString:@"UTF8_STRING"] || [name hasPrefix:@"text/plain;"]) return nil;
    NSData *bytes = [name dataUsingEncoding:NSUTF8StringEncoding];
    return zsc_custom_type([bytes bytes], [bytes length]);
}
/* The MIME name of a pasteboard type, nil to leave it out. */
static NSString *mime_for_type(NSString *type) {
    if ([type isEqualToString:NSPasteboardTypeString]) return mime_text;
    if ([type isEqualToString:NSPasteboardTypeHTML]) return mime_html;
    if ([type isEqualToString:NSPasteboardTypePNG]) return mime_png;
    if ([type isEqualToString:NSPasteboardTypeFileURL] || [type isEqualToString:NSPasteboardTypeURL]) return mime_uri_list;
    if ([type hasPrefix:@"dyn."] || [type isEqualToString:@"dev.ziggurat.file-list"]) return nil;
    if ([type hasPrefix:@"dev.ziggurat.mime."]) {
        NSString *hex = [type substringFromIndex:18];
        if ([hex length] % 2) return nil;
        NSMutableData *bytes = [NSMutableData dataWithLength:[hex length] / 2];
        uint8_t *out = [bytes mutableBytes];
        for (NSUInteger i = 0; i < [bytes length]; i++) {
            unsigned value = 0;
            if (sscanf([[hex substringWithRange:NSMakeRange(i * 2, 2)] UTF8String], "%2x", &value) != 1) return nil;
            out[i] = (uint8_t)value;
        }
        return [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
    }
    if (@available(macOS 11.0, *)) {
        UTType *uttype = [UTType typeWithIdentifier:type];
        NSString *mime = uttype ? [uttype preferredMIMEType] : nil;
        if (mime) return mime;
    }
    return type;
}
/* NUL-terminated MIME names of every type on the pasteboard's items. */
static NSData *offered_names(NSPasteboard *pasteboard) {
    NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet orderedSet];
    for (NSPasteboardItem *item in [pasteboard pasteboardItems]) {
        for (NSString *type in [item types]) {
            NSString *name = mime_for_type(type);
            if (name) [names addObject:name];
        }
    }
    NSMutableData *out = [NSMutableData data];
    for (NSString *name in names) {
        NSData *bytes = [name dataUsingEncoding:NSUTF8StringEncoding];
        if ([bytes length] == 0 || memchr([bytes bytes], 0, [bytes length])) continue;
        [out appendData:bytes];
        [out appendBytes:"" length:1];
    }
    return out;
}
static int actions_of(NSDragOperation mask) {
    return (mask & NSDragOperationCopy ? ACTION_COPY : 0) | (mask & (NSDragOperationMove | NSDragOperationGeneric) ? ACTION_MOVE : 0);
}
/* Holding Option or Command narrows the source's mask to one operation:
   that is the user's suggestion. */
static int suggested_of(NSDragOperation mask) {
    int actions = actions_of(mask);
    return actions == ACTION_COPY || actions == ACTION_MOVE ? actions : 0;
}
static NSDragOperation operation_of(int action) {
    return action & ACTION_MOVE ? NSDragOperationMove : action & ACTION_COPY ? NSDragOperationCopy : NSDragOperationNone;
}

/* ---- Files and text drop target ---- */

typedef struct ZsdCallbacks {
    int (*hover)(void *owner, int phase, double x, double y, int files, int text);
    void (*drop)(void *owner, double x, double y, int status, const uint8_t *data, size_t len);
} ZsdCallbacks;

@interface ZsdTarget : NSObject <NSDraggingDestination> {
@public
    void *owner;
    ZsdCallbacks callbacks;
    __weak NSView *view;
    BOOL want_files, want_text, inside, offered_files, offered_text;
    NSPoint point;
}
@end

static NSDictionary *file_urls_only(void) { return @{NSPasteboardURLReadingFileURLsOnlyKey: @YES}; }

@implementation ZsdTarget
- (void)offered:(id<NSDraggingInfo>)info {
    NSPasteboard *pasteboard = [info draggingPasteboard];
    offered_files = want_files && [pasteboard canReadObjectForClasses:@[[NSURL class]] options:file_urls_only()];
    offered_text = want_text && [pasteboard availableTypeFromArray:@[NSPasteboardTypeString]] != nil;
}
- (int)hover:(int)phase {
    if (!owner) return 0;
    return callbacks.hover(owner, phase, point.x, point.y, offered_files, offered_text);
}
- (void)leave {
    if (!inside) return;
    inside = NO;
    [self hover:PHASE_LEAVE];
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info {
    NSView *strong = view;
    if (!strong) return NSDragOperationNone;
    [self offered:info];
    point = view_point(strong, info);
    int phase = inside ? PHASE_OVER : PHASE_ENTER;
    inside = YES;
    return [self hover:phase] ? NSDragOperationCopy : NSDragOperationNone;
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info {
    NSView *strong = view;
    if (!strong) return NSDragOperationNone;
    if (!inside) return [self draggingEntered:info];
    point = view_point(strong, info);
    return [self hover:PHASE_OVER] ? NSDragOperationCopy : NSDragOperationNone;
}
- (void)draggingExited:(id<NSDraggingInfo>)info { (void)info; [self leave]; }
- (void)draggingEnded:(id<NSDraggingInfo>)info { (void)info; [self leave]; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)info { (void)info; return owner != NULL; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
    NSView *strong = view;
    if (!strong || !owner) return NO;
    point = view_point(strong, info);
    /* Every hover sequence ends with leave before the drop. */
    [self leave];
    [self offered:info];
    if (!owner) return NO;
    NSPasteboard *pasteboard = [info draggingPasteboard];
    if (offered_files) {
        NSArray<NSURL *> *urls = [pasteboard readObjectsForClasses:@[[NSURL class]] options:file_urls_only()];
        NSMutableData *out = [NSMutableData data];
        int status = STATUS_FILES;
        size_t count = 0;
        for (NSURL *url in urls) {
            const char *path = [[url path] UTF8String];
            if (!path) continue;
            if (++count > MAX_FILES) { status = STATUS_TOO_MANY_FILES; break; }
            if ([out length]) [out appendBytes:"" length:1];
            [out appendBytes:path length:strlen(path)];
        }
        if (status == STATUS_FILES && count == 0) status = STATUS_MALFORMED;
        callbacks.drop(owner, point.x, point.y, status, [out bytes], [out length]);
        return status == STATUS_FILES;
    }
    if (offered_text) {
        NSString *string = [pasteboard stringForType:NSPasteboardTypeString];
        const char *text = [string UTF8String];
        callbacks.drop(owner, point.x, point.y, text ? STATUS_TEXT : STATUS_MALFORMED, (const uint8_t *)text, text ? strlen(text) : 0);
        return text != NULL;
    }
    return NO;
}
@end

void *zsd_attach(void *handle, void *owner, const ZsdCallbacks *callbacks, int files, int text) {
    NSView *view = content_view(handle);
    if (!view || [view zigDropTarget]) return NULL;
    ZsdTarget *target = [[ZsdTarget alloc] init];
    target->owner = owner; target->callbacks = *callbacks; target->view = view;
    target->want_files = files != 0; target->want_text = text != 0;
    NSMutableArray<NSPasteboardType> *types = [NSMutableArray array];
    if (files) [types addObject:NSPasteboardTypeFileURL];
    if (text) [types addObject:NSPasteboardTypeString];
    [view registerForDraggedTypes:types];
    [view setZigDropTarget:target];
    return (__bridge_retained void *)target;
}
static void detach_from(NSView *view, id target) {
    if (!view || [view zigDropTarget] != target) return;
    [view unregisterDraggedTypes];
    [view setZigDropTarget:nil];
}
void zsd_detach(void *pointer) {
    ZsdTarget *target = (__bridge_transfer ZsdTarget *)pointer;
    target->owner = NULL;
    detach_from(target->view, target);
}
int zsd_registered(void *handle) {
    NSView *view = content_view(handle);
    return view && [view zigDropTarget] && [[view registeredDraggedTypes] count] > 0;
}

/* ---- Multi-format drop target ---- */

typedef struct ZstTargetCallbacks {
    int (*hover)(void *owner, int phase, double x, double y, const char *targets, size_t len, int actions, int suggested, void *session);
    int (*drop)(void *owner, void *record, double x, double y, const char *targets, size_t len, int actions, int suggested, void *session);
    void (*received)(void *owner, const char *target, const uint8_t *data, int len);
    int (*complete)(void *owner);
} ZstTargetCallbacks;

/* The names a drop asked for, collected by zst_target_request while the
   drop callback runs, then read from the pasteboard in order. */
@interface ZstRequests : NSObject {
@public
    NSMutableArray<NSString *> *names;
}
@end
@implementation ZstRequests
@end

@interface ZstTarget : NSObject <NSDraggingDestination> {
@public
    void *owner;
    ZstTargetCallbacks callbacks;
    __weak NSView *view;
    BOOL inside;
    NSPoint point;
}
@end

static void *session_of(id<NSDraggingInfo> info) {
    return (__bridge void *)[info draggingSource];
}
/* One value for every item: text lines and URI lines are joined as
   transfer.Data.read coalesces them; another format comes from the first
   item that has it. */
static NSData *read_name(NSPasteboard *pasteboard, NSString *name) {
    NSArray<NSPasteboardItem *> *items = [pasteboard pasteboardItems];
    if ([name isEqualToString:mime_text]) {
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        for (NSPasteboardItem *item in items) {
            NSString *string = [item stringForType:NSPasteboardTypeString];
            if (string) [lines addObject:string];
        }
        return [lines count] ? [[lines componentsJoinedByString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding] : nil;
    }
    if ([name isEqualToString:mime_uri_list]) {
        NSMutableString *list = [NSMutableString string];
        for (NSPasteboardItem *item in items) {
            NSString *uri = [item stringForType:NSPasteboardTypeFileURL];
            if (!uri) uri = [item stringForType:NSPasteboardTypeURL];
            if (!uri) continue;
            /* File reference URLs (file:///.file/id=...) name no path. */
            NSURL *url = [NSURL URLWithString:uri];
            if ([url isFileReferenceURL]) uri = [[url filePathURL] absoluteString];
            if (uri) [list appendFormat:@"%@\r\n", uri];
        }
        return [list length] ? [list dataUsingEncoding:NSUTF8StringEncoding] : nil;
    }
    for (NSPasteboardItem *item in items) {
        for (NSString *type in [item types]) {
            NSString *mime = mime_for_type(type);
            if (!mime || ![mime isEqualToString:name]) continue;
            NSData *data = [item dataForType:type];
            if (data) return data;
        }
    }
    return nil;
}

@implementation ZstTarget
- (NSDragOperation)hover:(int)phase info:(id<NSDraggingInfo>)info {
    NSView *strong = view;
    if (!strong || !owner) return NSDragOperationNone;
    point = view_point(strong, info);
    NSData *names = offered_names([info draggingPasteboard]);
    NSDragOperation mask = [info draggingSourceOperationMask];
    int action = callbacks.hover(owner, phase, point.x, point.y, [names bytes], [names length], actions_of(mask), suggested_of(mask), session_of(info));
    return operation_of(action);
}
- (void)leave {
    if (!inside) return;
    inside = NO;
    if (owner) callbacks.hover(owner, PHASE_LEAVE, point.x, point.y, "", 0, 0, 0, NULL);
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info {
    int phase = inside ? PHASE_OVER : PHASE_ENTER;
    inside = YES;
    return [self hover:phase info:info];
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info {
    int phase = inside ? PHASE_OVER : PHASE_ENTER;
    inside = YES;
    return [self hover:phase info:info];
}
- (void)draggingExited:(id<NSDraggingInfo>)info { (void)info; [self leave]; }
- (void)draggingEnded:(id<NSDraggingInfo>)info { (void)info; [self leave]; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)info { (void)info; return owner != NULL; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
    NSView *strong = view;
    if (!strong || !owner) return NO;
    point = view_point(strong, info);
    [self leave];
    if (!owner) return NO;
    NSPasteboard *pasteboard = [info draggingPasteboard];
    NSData *names = offered_names(pasteboard);
    NSDragOperation mask = [info draggingSourceOperationMask];
    ZstRequests *requests = [[ZstRequests alloc] init];
    requests->names = [NSMutableArray array];
    int action = callbacks.drop(owner, (__bridge void *)requests, point.x, point.y, [names bytes], [names length], actions_of(mask), suggested_of(mask), session_of(info));
    if (action == 0 || !owner) return NO;
    for (NSString *name in requests->names) {
        NSData *data = read_name(pasteboard, name);
        if (!owner) return NO;
        if (data && [data length] > INT32_MAX) data = nil;
        callbacks.received(owner, [name UTF8String], [data bytes], data ? (int)[data length] : -1);
    }
    return owner && callbacks.complete(owner) != 0;
}
@end

void zst_target_request(void *record, const char *name) {
    ZstRequests *requests = (__bridge ZstRequests *)record;
    NSString *value = [NSString stringWithUTF8String:name];
    if (value) [requests->names addObject:value];
}
/* names: the target's formats, NUL-terminated, to register for. */
void *zst_target_attach_types(void *handle, void *owner, const ZstTargetCallbacks *callbacks, const char *names, size_t names_len) {
    NSView *view = content_view(handle);
    if (!view || [view zigDropTarget]) return NULL;
    NSMutableOrderedSet<NSPasteboardType> *types = [NSMutableOrderedSet orderedSet];
    for (size_t at = 0; at < names_len;) {
        size_t len = strnlen(names + at, names_len - at);
        NSString *name = [[NSString alloc] initWithBytes:names + at length:len encoding:NSUTF8StringEncoding];
        at += len + 1;
        if (!name) continue;
        if ([name isEqualToString:mime_uri_list] || [name isEqualToString:@"application/x-ziggurat-file-list"]) {
            [types addObject:NSPasteboardTypeFileURL];
            if ([name isEqualToString:mime_uri_list]) [types addObject:NSPasteboardTypeURL];
            continue;
        }
        NSString *type = type_for_mime(name);
        if (type) [types addObject:type];
    }
    ZstTarget *target = [[ZstTarget alloc] init];
    target->owner = owner; target->callbacks = *callbacks; target->view = view;
    [view registerForDraggedTypes:[types array]];
    [view setZigDropTarget:target];
    return (__bridge_retained void *)target;
}
void zst_target_detach(void *pointer) {
    ZstTarget *target = (__bridge_transfer ZstTarget *)pointer;
    target->owner = NULL;
    detach_from(target->view, target);
}

/* ---- Drag source ---- */

typedef struct ZstSourceCallbacks {
    int (*get)(void *owner, const char *target, const uint8_t **data, size_t *len);
    /* status: 0 dropped, 1 no target, 2 given up, 3 failed */
    void (*end)(void *owner, int action, int status, int escaped);
} ZstSourceCallbacks;

@interface ZstSource : NSObject <NSDraggingSource, NSPasteboardItemDataProvider> {
@public
    void *owner;
    ZstSourceCallbacks callbacks;
    NSDragOperation mask;
    /* Pasteboard type to the MIME name the owner renders. */
    NSMutableDictionary<NSPasteboardType, NSString *> *names;
    id close_observer;
    BOOL ended;
}
@end

/* A copy of the event being handled when it can start a drag: a press, or
   a move with a button held. */
void *zst_current_event(void) {
    NSEvent *event = [NSApp currentEvent];
    switch ([event type]) {
    case NSEventTypeLeftMouseDown: case NSEventTypeLeftMouseDragged:
    case NSEventTypeRightMouseDown: case NSEventTypeRightMouseDragged:
    case NSEventTypeOtherMouseDown: case NSEventTypeOtherMouseDragged:
        return (__bridge_retained void *)event;
    default:
        return NULL;
    }
}
void zst_event_free(void *event) { CFRelease(event); }

static NSData *rendered(ZstSource *source, NSString *name) {
    if (!source->owner) return nil;
    const uint8_t *bytes = NULL;
    size_t len = 0;
    if (source->callbacks.get(source->owner, [name UTF8String], &bytes, &len) != 0) return nil;
    return [NSData dataWithBytes:len ? (const void *)bytes : "" length:len];
}

@implementation ZstSource
- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    (void)session; (void)context;
    return owner ? mask : NSDragOperationNone;
}
- (void)pasteboard:(NSPasteboard *)pasteboard item:(NSPasteboardItem *)item provideDataForType:(NSPasteboardType)type {
    (void)pasteboard;
    NSString *name = names[type];
    NSData *data = name ? rendered(self, name) : nil;
    if (data) [item setData:data forType:type];
}
- (void)finish:(int)action status:(int)status escaped:(int)escaped {
    if (ended) return;
    ended = YES;
    if (close_observer) [[NSNotificationCenter defaultCenter] removeObserver:close_observer];
    close_observer = nil;
    void *current = owner;
    owner = NULL;
    if (current) callbacks.end(current, action, status, escaped);
}
- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)point operation:(NSDragOperation)operation {
    (void)session; (void)point;
    int action = operation & NSDragOperationMove ? ACTION_MOVE : operation & NSDragOperationGeneric ? (mask & NSDragOperationMove ? ACTION_MOVE : ACTION_COPY) : operation & NSDragOperationCopy ? ACTION_COPY : 0;
    /* AppKit reports no reason; Escape is the key event that ended it. */
    NSEvent *event = [NSApp currentEvent];
    int escaped = action == 0 && [event type] == NSEventTypeKeyDown && [event keyCode] == 53;
    [self finish:action status:action ? 0 : escaped ? 2 : 1 escaped:escaped];
    /* Balances the reference zst_source_begin returned. */
    CFRelease((__bridge CFTypeRef)self);
}
@end

static NSImage *preview_image(const uint8_t *rgba, int width, int height) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:NSBitmapFormatAlphaNonpremultiplied bytesPerRow:(NSInteger)width * 4 bitsPerPixel:32];
    if (!rep) return nil;
    memcpy([rep bitmapData], rgba, (size_t)width * (size_t)height * 4);
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(width, height)];
    [image addRepresentation:rep];
    return image;
}
/* The URIs of a text/uri-list, comments left out. */
static NSArray<NSString *> *uri_lines(NSData *data) {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSMutableArray<NSString *> *uris = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed length] && ![trimmed hasPrefix:@"#"]) [uris addObject:trimmed];
    }
    return uris;
}

void *zst_source_begin(void *handle, void *event_pointer, const char *names, size_t names_len, int actions,
                       const uint8_t *rgba, int width, int height, int hot_x, int hot_y,
                       void *owner, const ZstSourceCallbacks *callbacks) {
    NSWindow *window = (__bridge NSWindow *)handle;
    NSView *view = content_view(handle);
    NSEvent *event = (__bridge NSEvent *)event_pointer;
    if (!view) return NULL;
    ZstSource *source = [[ZstSource alloc] init];
    source->owner = owner;
    source->callbacks = *callbacks;
    source->mask = operation_of(actions & ACTION_COPY) | operation_of(actions & ACTION_MOVE);
    source->names = [NSMutableDictionary dictionary];

    NSPasteboardItem *first = [[NSPasteboardItem alloc] init];
    NSMutableArray<NSPasteboardItem *> *more = [NSMutableArray array];
    NSMutableArray<NSPasteboardType> *lazy = [NSMutableArray array];
    for (size_t at = 0; at < names_len;) {
        size_t len = strnlen(names + at, names_len - at);
        NSString *name = [[NSString alloc] initWithBytes:names + at length:len encoding:NSUTF8StringEncoding];
        at += len + 1;
        if (!name) continue;
        if ([name isEqualToString:mime_uri_list]) {
            NSData *list = rendered(source, name);
            NSArray<NSString *> *uris = list ? uri_lines(list) : @[];
            BOOL files = [uris count] > 0;
            for (NSString *uri in uris) files = files && [[NSURL URLWithString:uri] isFileURL];
            if (!files) {
                if ([uris count]) [first setString:uris[0] forType:NSPasteboardTypeURL];
                continue;
            }
            [first setString:uris[0] forType:NSPasteboardTypeFileURL];
            for (NSUInteger i = 1; i < [uris count]; i++) {
                NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
                [item setString:uris[i] forType:NSPasteboardTypeFileURL];
                [more addObject:item];
            }
            continue;
        }
        NSString *type = type_for_mime(name);
        if (!type || source->names[type]) continue;
        source->names[type] = name;
        [lazy addObject:type];
    }
    if ([lazy count] && ![first setDataProvider:source forTypes:lazy]) return NULL;
    if ([[first types] count] == 0 && [more count] == 0) return NULL;

    NSPoint at = [view convertPoint:[event locationInWindow] fromView:nil];
    NSImage *image = rgba && width > 0 && height > 0 ? preview_image(rgba, width, height) : nil;
    NSRect frame = image ? NSMakeRect(at.x - hot_x, at.y - hot_y, width, height) : NSMakeRect(at.x - 16, at.y - 16, 32, 32);
    if (!image && [more count] == 0) {
        if (@available(macOS 11.0, *)) image = [[NSWorkspace sharedWorkspace] iconForContentType:UTTypeItem];
    }
    if (!image) image = [NSImage imageNamed:NSImageNameMultipleDocuments];
    NSMutableArray<NSDraggingItem *> *items = [NSMutableArray array];
    for (NSPasteboardItem *item in [@[first] arrayByAddingObjectsFromArray:more]) {
        NSDraggingItem *dragging = [[NSDraggingItem alloc] initWithPasteboardWriter:item];
        [dragging setDraggingFrame:frame contents:item == first ? image : nil];
        [items addObject:dragging];
    }
    NSDraggingSession *session = [view beginDraggingSessionWithItems:items event:event source:source];
    if (!session) {
        source->owner = NULL;
        return NULL;
    }
    [session setAnimatesToStartingPositionsOnCancelOrFail:YES];
    [session setDraggingFormation:NSDraggingFormationNone];
    /* The source window closing gives the drag up. */
    __weak ZstSource *weak = source;
    source->close_observer = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:window queue:nil usingBlock:^(NSNotification *note) {
        (void)note;
        [weak finish:0 status:2 escaped:1];
    }];
    /* Released when the session ends. */
    return (__bridge_retained void *)source;
}
/* Silent: the owner hears nothing more. AppKit ends the session itself. */
void zst_source_cancel(void *pointer) {
    ZstSource *source = (__bridge ZstSource *)pointer;
    source->owner = NULL;
}
int zst_session_is(void *pointer, void *session) {
    return pointer && pointer == session;
}
