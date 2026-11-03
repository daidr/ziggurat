/* NSPasteboard glue for system.clipboard, the same zsc_* entry points as the
   GTK adapter (clipboard_linux.zig drives both). Everything runs on the main
   thread. Compiled with ARC.

   Formats: text is public.utf8-plain-text, html public.html, png public.png
   (a TIFF on the pasteboard is converted to PNG when read), files are file
   URLs, one pasteboard item per path, plus the whole NUL-separated list in
   dev.ziggurat.file-list. A custom name with '/' is a MIME type and maps to
   its UTType identifier, or to dev.ziggurat.mime.<hex> when the system has
   none; another name is used as the pasteboard type itself.

   A lazy offer is an NSPasteboardItemDataProvider. The pasteboard calls it
   on the main thread when a reader asks for a type, and tells it when it no
   longer needs it (another owner, clearContents), which ends the offer. A
   lazy file list announces only its first file URL and the full list, since
   the paths are not known before rendering. NSPasteboard has no change
   notification, so the Board's on_changed never runs on macOS. Reads run
   from the main queue, never inside zsc_read_start. */
#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum { KIND_TEXT, KIND_HTML, KIND_PNG, KIND_FILES, KIND_CUSTOM };
enum { STATUS_DATA, STATUS_UNAVAILABLE, STATUS_MALFORMED, STATUS_TOO_MANY_FILES, STATUS_FORMATS };
enum { FLAG_TEXT = 1, FLAG_HTML = 2, FLAG_PNG = 4, FLAG_FILES = 8 };
#define MAX_FILES 1024
#define MAX_ITEMS 16

typedef struct ZscItem { int kind; const char *name; size_t name_len; const uint8_t *data; size_t len; } ZscItem;
typedef struct ZscCallbacks {
    void (*changed)(void *owner);
    void (*lost)(void *owner);
    int (*render)(void *owner, size_t index, void *sink);
    void (*read_done)(void *request, int status, const uint8_t *data, size_t len, uint32_t flags);
} ZscCallbacks;
typedef struct ZscBoard ZscBoard;
typedef struct ZscSink { NSMutableData *__unsafe_unretained bytes; } ZscSink;

static atomic_int resources;
uint32_t zsc_resource_count(void) { return (uint32_t)atomic_load(&resources); }

static NSString *const file_list_type = @"dev.ziggurat.file-list";

/* The pasteboard type of a custom format name. */
NSString *zsc_custom_type(const char *name, size_t len) {
    NSString *value = [[NSString alloc] initWithBytes:name length:len encoding:NSUTF8StringEncoding];
    if (!value) return nil;
    if ([value rangeOfString:@"/"].location == NSNotFound) return value;
    if (@available(macOS 11.0, *)) {
        UTType *type = [UTType typeWithMIMEType:value];
        if (type && ![type isDynamic]) return [type identifier];
    }
    NSMutableString *hex = [NSMutableString stringWithString:@"dev.ziggurat.mime."];
    for (size_t i = 0; i < len; i++) [hex appendFormat:@"%02x", (unsigned char)name[i]];
    return hex;
}
static NSString *kind_type(int kind) {
    switch (kind) {
    case KIND_TEXT: return NSPasteboardTypeString;
    case KIND_HTML: return NSPasteboardTypeHTML;
    case KIND_PNG: return NSPasteboardTypePNG;
    default: return nil;
    }
}

/* The paths of a NUL-separated list. */
static NSArray<NSString *> *split_paths(NSData *data) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    const char *bytes = [data bytes];
    size_t len = [data length], start = 0;
    for (size_t i = 0; i <= len; i++) {
        if (i < len && bytes[i] != 0) continue;
        NSString *path = [[NSString alloc] initWithBytes:bytes + start length:i - start encoding:NSUTF8StringEncoding];
        if (path) [paths addObject:path];
        start = i + 1;
    }
    return paths;
}
static NSData *file_url_data(NSString *path) {
    return [[[NSURL fileURLWithPath:path] absoluteString] dataUsingEncoding:NSUTF8StringEncoding];
}

@interface ZscOffer : NSObject <NSPasteboardItemDataProvider> {
@public
    ZscBoard *board;
    int lazy, finished;
    size_t count;
    int kinds[MAX_ITEMS];
    NSString *types[MAX_ITEMS];
    NSData *files;
}
@end

struct ZscBoard { void *owner; ZscCallbacks callbacks; ZscOffer *__strong current; NSInteger change; };

/* The general pasteboard, or for smokes the private named pasteboard that
   ZIGGURAT_TEST_PASTEBOARD names, so a test leaves the user's clipboard alone. */
static NSPasteboard *board_pasteboard(void) {
    static NSPasteboard *pasteboard;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *name = getenv("ZIGGURAT_TEST_PASTEBOARD");
        pasteboard = name && name[0] ? [NSPasteboard pasteboardWithName:[NSString stringWithUTF8String:name]] : [NSPasteboard generalPasteboard];
    });
    return pasteboard;
}
/* Lazy offers the pasteboard may still call, kept until it says it is done
   with them, whatever happened to their Board. */
static NSMutableSet<ZscOffer *> *live_offers;

@implementation ZscOffer
- (NSData *)render:(size_t)index {
    if (!board || !board->owner || board->current != self) return nil;
    NSMutableData *bytes = [NSMutableData data];
    ZscSink sink = {bytes};
    if (!board->callbacks.render(board->owner, index, &sink)) return nil;
    return bytes;
}
- (void)pasteboard:(NSPasteboard *)pasteboard item:(NSPasteboardItem *)item provideDataForType:(NSPasteboardType)type {
    (void)pasteboard;
    for (size_t i = 0; i < count; i++) {
        if (kinds[i] == KIND_FILES) {
            if (![type isEqualToString:NSPasteboardTypeFileURL] && ![type isEqualToString:file_list_type]) continue;
            if (!files) files = [self render:i];
            if (!files) return;
            if ([type isEqualToString:file_list_type]) { [item setData:files forType:type]; return; }
            NSArray<NSString *> *paths = split_paths(files);
            if ([paths count]) [item setData:file_url_data(paths[0]) forType:type];
            return;
        }
        if (![types[i] isEqualToString:type]) continue;
        NSData *data = [self render:i];
        if (data) [item setData:data forType:type];
        return;
    }
}
- (void)pasteboardFinishedWithDataProvider:(NSPasteboard *)pasteboard {
    (void)pasteboard;
    if (finished) return;
    finished = 1;
    ZscBoard *owner = board;
    files = nil;
    ZscOffer *keep = self;
    [live_offers removeObject:keep];
    if (!owner || owner->current != self) return;
    owner->current = nil;
    if (owner->owner) owner->callbacks.lost(owner->owner);
}
- (void)dealloc { atomic_fetch_sub(&resources, 1); }
@end

ZscBoard *zsc_board_create(void *owner, const ZscCallbacks *callbacks) {
    ZscBoard *board = calloc(1, sizeof(ZscBoard));
    if (!board) return NULL;
    atomic_fetch_add(&resources, 1);
    board->owner = owner;
    board->callbacks = *callbacks;
    return board;
}

int zsc_sink_set(void *sink, const uint8_t *data, size_t len) {
    ZscSink *state = sink;
    [state->bytes appendBytes:data length:len];
    return 1;
}

static int publish(ZscBoard *board, const ZscItem *items, size_t count, int lazy) {
    @autoreleasepool {
        if (count > MAX_ITEMS) return 0;
        ZscOffer *offer = [ZscOffer new];
        if (!offer) return 0;
        atomic_fetch_add(&resources, 1);
        offer->board = board;
        offer->lazy = lazy;
        offer->count = count;
        NSPasteboardItem *first = [NSPasteboardItem new];
        NSMutableArray<NSPasteboardItem *> *more = [NSMutableArray array];
        NSMutableArray<NSPasteboardType> *announced = [NSMutableArray array];
        for (size_t i = 0; i < count; i++) {
            const ZscItem *item = &items[i];
            offer->kinds[i] = item->kind;
            NSString *type = item->kind == KIND_CUSTOM ? zsc_custom_type(item->name, item->name_len) : kind_type(item->kind);
            offer->types[i] = type;
            if (item->kind == KIND_FILES) {
                [announced addObject:NSPasteboardTypeFileURL];
                [announced addObject:file_list_type];
                if (lazy) continue;
                NSData *list = [NSData dataWithBytes:item->data length:item->len];
                NSArray<NSString *> *paths = split_paths(list);
                [first setData:list forType:file_list_type];
                for (NSUInteger p = 0; p < [paths count]; p++) {
                    NSPasteboardItem *target = first;
                    if (p) { target = [NSPasteboardItem new]; [more addObject:target]; }
                    [target setData:file_url_data(paths[p]) forType:NSPasteboardTypeFileURL];
                }
                continue;
            }
            if (!type) return 0;
            [announced addObject:type];
            if (!lazy) [first setData:[NSData dataWithBytes:item->data length:item->len] forType:type];
        }
        if (lazy && ![first setDataProvider:offer forTypes:announced]) return 0;
        if (lazy) {
            if (!live_offers) live_offers = [NSMutableSet set];
            [live_offers addObject:offer];
        }
        NSPasteboard *pasteboard = board_pasteboard();
        /* Ends the previous offer: its provider hears it is finished. */
        board->current = nil;
        [pasteboard clearContents];
        NSMutableArray *objects = [NSMutableArray arrayWithObject:first];
        [objects addObjectsFromArray:more];
        if (![pasteboard writeObjects:objects]) {
            [live_offers removeObject:offer];
            return 0;
        }
        board->change = [pasteboard changeCount];
        if (lazy) board->current = offer;
        return 1;
    }
}
int zsc_board_write(ZscBoard *board, const ZscItem *items, size_t count) { return publish(board, items, count, 0); }
int zsc_board_offer(ZscBoard *board, const ZscItem *items, size_t count) { return publish(board, items, count, 1); }
/* Empties the pasteboard when this Board's lazy offer still owns it. */
void zsc_board_revoke(ZscBoard *board) {
    @autoreleasepool {
        if (!board->current) return;
        board->current = nil;
        if ([board_pasteboard() changeCount] == board->change) [board_pasteboard() clearContents];
    }
}
void zsc_board_clear(ZscBoard *board) {
    @autoreleasepool {
        board->current = nil;
        [board_pasteboard() clearContents];
    }
}
/* Eager data stays on the pasteboard after the Board closes; a lazy offer
   cannot render without its provider and is cleared. */
void zsc_board_destroy(ZscBoard *board) {
    zsc_board_revoke(board);
    for (ZscOffer *offer in live_offers) if (offer->board == board) offer->board = NULL;
    board->owner = NULL;
    free(board);
    atomic_fetch_sub(&resources, 1);
}

/* ---- Reads ---- */

typedef struct ZscRead { ZscBoard *board; void *request; int formats, kind; NSString *__strong custom; } ZscRead;

static void finish(ZscRead *read, int status, NSData *data, uint32_t flags) {
    if (read->request) read->board->callbacks.read_done(read->request, status, data ? [data bytes] : NULL, data ? [data length] : 0, flags);
}
static int has_files(NSPasteboard *pasteboard) {
    return [pasteboard canReadObjectForClasses:@[[NSURL class]] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}] || [[pasteboard types] containsObject:file_list_type];
}
static NSData *png_data(NSPasteboard *pasteboard, int *status) {
    NSData *png = [pasteboard dataForType:NSPasteboardTypePNG];
    if (png) return png;
    NSData *tiff = [pasteboard dataForType:NSPasteboardTypeTIFF];
    if (!tiff) { *status = STATUS_UNAVAILABLE; return nil; }
    NSBitmapImageRep *image = [NSBitmapImageRep imageRepWithData:tiff];
    NSData *converted = image ? [image representationUsingType:NSBitmapImageFileTypePNG properties:@{}] : nil;
    if (!converted) *status = STATUS_MALFORMED;
    return converted;
}
/* public.html may be UTF-16 with a byte order mark, or end in NULs. */
static NSData *html_data(NSPasteboard *pasteboard, int *status) {
    NSData *raw = [pasteboard dataForType:NSPasteboardTypeHTML];
    if (!raw) { *status = STATUS_UNAVAILABLE; return nil; }
    const uint8_t *bytes = [raw bytes];
    size_t len = [raw length];
    NSString *text = nil;
    if (len >= 2 && ((bytes[0] == 0xff && bytes[1] == 0xfe) || (bytes[0] == 0xfe && bytes[1] == 0xff))) text = [[NSString alloc] initWithData:raw encoding:NSUnicodeStringEncoding];
    else {
        if (len >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf) { bytes += 3; len -= 3; }
        text = [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
    }
    if (!text) { *status = STATUS_MALFORMED; return nil; }
    NSMutableData *out = [[text dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    while ([out length] && ((const char *)[out bytes])[[out length] - 1] == 0) [out setLength:[out length] - 1];
    if (memchr([out bytes], 0, [out length])) { *status = STATUS_MALFORMED; return nil; }
    return out;
}
static NSData *files_data(NSPasteboard *pasteboard, int *status) {
    NSData *list = [pasteboard dataForType:file_list_type];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    if (list) [paths addObjectsFromArray:split_paths(list)];
    else for (NSURL *url in [pasteboard readObjectsForClasses:@[[NSURL class]] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}]) {
        const char *path = [url fileSystemRepresentation];
        if (path) [paths addObject:[NSString stringWithUTF8String:path]];
    }
    if ([paths count] == 0) { *status = STATUS_UNAVAILABLE; return nil; }
    if ([paths count] > MAX_FILES) { *status = STATUS_TOO_MANY_FILES; return nil; }
    NSMutableData *out = [NSMutableData data];
    for (NSString *path in paths) {
        if ([out length]) [out appendBytes:"" length:1];
        [out appendData:[path dataUsingEncoding:NSUTF8StringEncoding]];
    }
    return out;
}
static void perform(ZscRead *read) {
    if (!read->request) return;
    NSPasteboard *pasteboard = board_pasteboard();
    if (read->formats) {
        NSArray<NSPasteboardType> *types = [pasteboard types];
        uint32_t flags = 0;
        if ([pasteboard canReadObjectForClasses:@[[NSString class]] options:nil] && [pasteboard availableTypeFromArray:@[NSPasteboardTypeString, @"public.utf16-plain-text", @"public.utf16-external-plain-text"]]) flags |= FLAG_TEXT;
        if ([types containsObject:NSPasteboardTypeHTML]) flags |= FLAG_HTML;
        if ([types containsObject:NSPasteboardTypePNG] || [types containsObject:NSPasteboardTypeTIFF]) flags |= FLAG_PNG;
        if (has_files(pasteboard)) flags |= FLAG_FILES;
        return finish(read, STATUS_FORMATS, nil, flags);
    }
    int status = STATUS_DATA;
    NSData *data = nil;
    switch (read->kind) {
    case KIND_TEXT: {
        NSString *text = [pasteboard stringForType:NSPasteboardTypeString];
        if (!text) status = STATUS_UNAVAILABLE;
        else data = [text dataUsingEncoding:NSUTF8StringEncoding];
        break;
    }
    case KIND_HTML: data = html_data(pasteboard, &status); break;
    case KIND_PNG: data = png_data(pasteboard, &status); break;
    case KIND_FILES: data = files_data(pasteboard, &status); break;
    default:
        data = read->custom ? [pasteboard dataForType:read->custom] : nil;
        if (!data) status = STATUS_UNAVAILABLE;
    }
    finish(read, status, status == STATUS_DATA ? data : nil, 0);
}

void *zsc_read_start(ZscBoard *board, void *request, int formats, int kind, const char *name, size_t name_len) {
    ZscRead *read = calloc(1, sizeof(ZscRead));
    if (!read) return NULL;
    atomic_fetch_add(&resources, 1);
    read->board = board;
    read->request = request;
    read->formats = formats;
    read->kind = kind;
    if (!formats && kind == KIND_CUSTOM) read->custom = zsc_custom_type(name, name_len);
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool { perform(read); }
        read->custom = nil;
        free(read);
        atomic_fetch_sub(&resources, 1);
    });
    return read;
}
void zsc_read_cancel(void *read) { ((ZscRead *)read)->request = NULL; }

/* ---- Synchronous text helpers ---- */

int zsc_text_write(const uint8_t *text, size_t len) {
    @autoreleasepool {
        NSString *value = [[NSString alloc] initWithBytes:text length:len encoding:NSUTF8StringEncoding];
        if (!value) return 0;
        NSPasteboard *pasteboard = board_pasteboard();
        [pasteboard clearContents];
        return [pasteboard setString:value forType:NSPasteboardTypeString] ? 1 : 0;
    }
}
/* Bytes written, or the length needed (negative) when capacity is short;
   0 with *empty set when there is no text. */
long zsc_text_read(uint8_t *destination, size_t capacity, int *empty) {
    @autoreleasepool {
        NSString *value = [board_pasteboard() stringForType:NSPasteboardTypeString];
        *empty = value == nil;
        if (!value) return 0;
        NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
        size_t len = [data length];
        if (len > capacity) return -(long)len;
        memcpy(destination, [data bytes], len);
        return (long)len;
    }
}
