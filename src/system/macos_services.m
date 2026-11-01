/* macOS system services without a window: the login Keychain, sleep
   assertions, recent documents, the app's appearance, NSWorkspace shell
   hand-offs, installed applications, login items, URL scheme handlers and
   desktop snapshots and change notifications. Compiled with ARC.

   Threads: the Keychain, sleep assertion and shell entries run on any thread
   (the shell ones on the caller's worker). Recent documents run on any thread
   and hop to the main queue for NSDocumentController. Everything else runs on
   the main thread that owns the App. */
#import <AppKit/AppKit.h>
#import <Security/Security.h>
#import <ServiceManagement/ServiceManagement.h>
#import <CoreServices/CoreServices.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <Network/Network.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdint.h>
#include <string.h>

static NSString *text(const uint8_t *bytes, size_t length) {
    return [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
}
static NSString *ztext(const char *value) { return value ? [NSString stringWithUTF8String:value] : nil; }

/* ---- Keychain ----
   Secrets are generic passwords of the login keychain under kSecAttrService
   and kSecAttrAccount, the layout other macOS credential libraries use. The
   file-based keychain needs no keychain-access-groups entitlement, which an
   unsigned build cannot have. Status: 0 ok, 1 not found, 2 unavailable,
   3 failed (OSStatus in *code), 4 secret too large. */

static NSMutableDictionary *secret_query(NSString *service, NSString *account) {
    return [@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
              (__bridge id)kSecAttrService: service,
              (__bridge id)kSecAttrAccount: account} mutableCopy];
}
static int secret_status(OSStatus status, int *code) {
    switch (status) {
    case errSecSuccess: return 0;
    case errSecItemNotFound: return 1;
    case errSecNotAvailable: case errSecNoSuchKeychain: case errSecInteractionNotAllowed: *code = (int)status; return 2;
    default: *code = (int)status; return 3;
    }
}

int zss_secret_set(const uint8_t *service, size_t service_len, const uint8_t *key, size_t key_len, const uint8_t *value, size_t value_len, int *code) {
    @autoreleasepool {
        NSString *s = text(service, service_len), *k = text(key, key_len);
        if (!s || !k) { *code = (int)errSecParam; return 3; }
        NSData *data = [NSData dataWithBytes:value length:value_len];
        NSDictionary *update = @{(__bridge id)kSecValueData: data};
        OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)secret_query(s, k), (__bridge CFDictionaryRef)update);
        if (status != errSecItemNotFound) return secret_status(status, code);
        NSMutableDictionary *add = secret_query(s, k);
        add[(__bridge id)kSecValueData] = data;
        add[(__bridge id)kSecAttrLabel] = s;
        status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
        /* Added by another thread or process since the update. */
        if (status == errSecDuplicateItem) status = SecItemUpdate((__bridge CFDictionaryRef)secret_query(s, k), (__bridge CFDictionaryRef)update);
        return secret_status(status, code);
    }
}

int zss_secret_get(const uint8_t *service, size_t service_len, const uint8_t *key, size_t key_len, uint8_t *destination, size_t capacity, size_t *length, int *code) {
    @autoreleasepool {
        NSString *s = text(service, service_len), *k = text(key, key_len);
        if (!s || !k) { *code = (int)errSecParam; return 3; }
        NSMutableDictionary *query = secret_query(s, k);
        query[(__bridge id)kSecReturnData] = @YES;
        query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
        CFTypeRef result = NULL;
        int status = secret_status(SecItemCopyMatching((__bridge CFDictionaryRef)query, &result), code);
        if (status != 0) return status;
        NSMutableData *data = (__bridge_transfer NSMutableData *)result;
        if (![data isKindOfClass:[NSData class]]) { *code = (int)errSecDecode; return 3; }
        size_t size = [data length];
        int outcome = 0;
        if (size > capacity) outcome = 4;
        else {
            if (size) memcpy(destination, [data bytes], size);
            *length = size;
        }
        if (size && [data isKindOfClass:[NSMutableData class]]) memset_s([data mutableBytes], size, 0, size);
        return outcome;
    }
}

int zss_secret_delete(const uint8_t *service, size_t service_len, const uint8_t *key, size_t key_len, int *code) {
    @autoreleasepool {
        NSString *s = text(service, service_len), *k = text(key, key_len);
        if (!s || !k) { *code = (int)errSecParam; return 3; }
        int status = secret_status(SecItemDelete((__bridge CFDictionaryRef)secret_query(s, k)), code);
        return status == 1 ? 0 : status;
    }
}

/* ---- Sleep assertions ----
   An NSProcessInfo activity: idle system sleep, and with display also idle
   display sleep, stay off until it ends. The token is retained here and
   released by zsm_power_end, which may run on any thread. */

void *zsm_power_begin(int display, const char *reason) {
    @autoreleasepool {
        NSActivityOptions options = NSActivityIdleSystemSleepDisabled;
        if (display) options |= NSActivityIdleDisplaySleepDisabled;
        id token = [[NSProcessInfo processInfo] beginActivityWithOptions:options reason:ztext(reason) ?: @"application"];
        return token ? (__bridge_retained void *)token : NULL;
    }
}
void zsm_power_end(void *token) {
    @autoreleasepool {
        id activity = (__bridge_transfer id)token;
        [[NSProcessInfo processInfo] endActivity:activity];
    }
}

/* ---- Recent documents ----
   NSDocumentController keeps the app's Open Recent list and the system's
   recent items (the Dock menu and Apple menu > Recent Items). It belongs
   to the main thread, so another thread's call is queued there. */

static void recent_note(NSURL *url) { [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:url]; }
int zsr_recent_add(const char *path, const char *app_name) {
    (void)app_name;
    @autoreleasepool {
        NSString *value = ztext(path);
        if (!value) return 1;
        NSURL *url = [NSURL fileURLWithPath:value];
        if (!url) return 1;
        if ([NSThread isMainThread]) recent_note(url);
        else dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool { recent_note(url); } });
        return 0;
    }
}

/* ---- Appearance ----
   Source: 0 follows the system, 1 light (Aqua), 2 dark (Dark Aqua). The
   application's appearance reaches every window and menu that does not set
   its own. */

void zsx_theme_set_source(int source) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSAppearance *appearance = nil;
        if (source == 1) appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        else if (source == 2) appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        /* Setting it again would notify effectiveAppearance observers, a
           desktop watch among them, which would apply it again. */
        NSAppearance *current = [NSApp appearance];
        if (current == appearance || (current && appearance && [[current name] isEqualToString:[appearance name]])) return;
        [NSApp setAppearance:appearance];
    }
}
/* 1 when the app's effective appearance is dark. */
int zsm_theme_dark(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSAppearanceName match = [[NSApp effectiveAppearance] bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
        return [match isEqualToString:NSAppearanceNameDarkAqua] ? 1 : 0;
    }
}

/* ---- Shell ----
   The same status codes as the GIO adapter: 0 ok, 1 failed, 2 not supported
   (no application), 3 not found, 4 access denied, 5 unavailable, 6 timed
   out, 7 invalid. Failures carry the NSError code in domain 4 (Cocoa) or 5
   (OSStatus / Launch Services). */

typedef struct ZshFailure { uint32_t domain, code; } ZshFailure;
enum { ZSH_OK = 0, ZSH_FAILED = 1, ZSH_NOT_SUPPORTED = 2, ZSH_NOT_FOUND = 3, ZSH_ACCESS_DENIED = 4, ZSH_UNAVAILABLE = 5, ZSH_TIMED_OUT = 6, ZSH_INVALID = 7 };
typedef int (*ZshAppVisit)(void *, const char *, const char *, const char *);

static int shell_error(NSError *error, ZshFailure *failure) {
    if (!error) return ZSH_FAILED;
    failure->domain = [[error domain] isEqualToString:NSOSStatusErrorDomain] ? 5 : 4;
    failure->code = (uint32_t)[error code];
    if ([[error domain] isEqualToString:NSCocoaErrorDomain]) {
        switch ([error code]) {
        case NSFileNoSuchFileError: case NSFileReadNoSuchFileError: return ZSH_NOT_FOUND;
        case NSFileWriteNoPermissionError: case NSFileReadNoPermissionError: return ZSH_ACCESS_DENIED;
        case NSFeatureUnsupportedError: return ZSH_NOT_SUPPORTED;
        default: return ZSH_FAILED;
        }
    }
    if ([[error domain] isEqualToString:NSPOSIXErrorDomain]) {
        if ([error code] == ENOENT) return ZSH_NOT_FOUND;
        if ([error code] == EACCES || [error code] == EPERM) return ZSH_ACCESS_DENIED;
    }
    return ZSH_FAILED;
}
/* Launch Services answers "no application" with kLSApplicationNotFoundErr. */
static int shell_open(NSURL *url, ZshFailure *failure) {
    if (!url) return ZSH_INVALID;
    NSURL *application = [[NSWorkspace sharedWorkspace] URLForApplicationToOpenURL:url];
    if (!application) { failure->domain = 5; failure->code = (uint32_t)kLSApplicationNotFoundErr; return ZSH_NOT_SUPPORTED; }
    return [[NSWorkspace sharedWorkspace] openURL:url] ? ZSH_OK : ZSH_FAILED;
}
int zsh_open_uri(const char *uri, ZshFailure *failure) {
    @autoreleasepool { return shell_open([NSURL URLWithString:ztext(uri) ?: @""], failure); }
}
int zsh_open_path(const char *path, ZshFailure *failure) {
    @autoreleasepool {
        NSString *value = ztext(path);
        if (!value) return ZSH_INVALID;
        if (![[NSFileManager defaultManager] fileExistsAtPath:value]) return ZSH_NOT_FOUND;
        return shell_open([NSURL fileURLWithPath:value], failure);
    }
}
/* Finder selects the item in a window of its own; there is no reply. */
int zsh_reveal(const char *path, int timeout_ms, ZshFailure *failure) {
    (void)timeout_ms; (void)failure;
    @autoreleasepool {
        NSString *value = ztext(path);
        if (!value) return ZSH_INVALID;
        if (![[NSFileManager defaultManager] fileExistsAtPath:value]) return ZSH_NOT_FOUND;
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:value]]];
        return ZSH_OK;
    }
}
int zsh_trash(const char *path, ZshFailure *failure) {
    @autoreleasepool {
        NSString *value = ztext(path);
        if (!value) return ZSH_INVALID;
        NSError *error = nil;
        if ([[NSFileManager defaultManager] trashItemAtURL:[NSURL fileURLWithPath:value] resultingItemURL:nil error:&error]) return ZSH_OK;
        return shell_error(error, failure);
    }
}

/* The .app bundles in the folders apps are installed in and one level down
   (Utilities, an app's own folder), without looking inside bundles, plus
   Finder. An app a symbolic link points to is listed once, at the link.
   Each has the name Finder shows (without .app) and its bundle identifier,
   or its path when it has none. */
static void apps_add(NSMutableArray<NSString *> *paths, NSMutableSet<NSString *> *seen, NSString *path) {
    NSString *real = [path stringByResolvingSymlinksInPath];
    if ([seen containsObject:real]) return;
    [seen addObject:real];
    [paths addObject:path];
}
int zsh_apps(ZshAppVisit visit, void *context) {
    @autoreleasepool {
        NSFileManager *files = [NSFileManager defaultManager];
        NSMutableArray<NSString *> *roots = [@[@"/Applications", @"/System/Applications", @"/System/Library/CoreServices/Applications"] mutableCopy];
        [roots addObject:[NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]];
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        for (NSString *root in roots) {
            for (NSString *name in [files contentsOfDirectoryAtPath:root error:nil]) {
                NSString *path = [root stringByAppendingPathComponent:name];
                if ([[name pathExtension] isEqualToString:@"app"]) { apps_add(paths, seen, path); continue; }
                BOOL directory = NO;
                if (![files fileExistsAtPath:path isDirectory:&directory] || !directory) continue;
                for (NSString *inner in [files contentsOfDirectoryAtPath:path error:nil])
                    if ([[inner pathExtension] isEqualToString:@"app"]) apps_add(paths, seen, [path stringByAppendingPathComponent:inner]);
            }
        }
        apps_add(paths, seen, @"/System/Library/CoreServices/Finder.app");
        for (NSString *path in paths) {
            NSBundle *bundle = [NSBundle bundleWithPath:path];
            if (!bundle) continue;
            NSString *name = [files displayNameAtPath:path];
            if ([[name pathExtension] isEqualToString:@"app"]) name = [name stringByDeletingPathExtension];
            NSString *identifier = [bundle bundleIdentifier];
            if (![identifier length]) identifier = path;
            if (![name length]) continue;
            int status = visit(context, [name UTF8String], [identifier UTF8String], [path fileSystemRepresentation]);
            if (status != 0) return status;
        }
        return ZSH_OK;
    }
}
/* Starts an app, or brings it to the front when it runs. */
int zsh_launch_app(const char *path, ZshFailure *failure) {
    @autoreleasepool {
        NSString *value = ztext(path);
        if (!value) return ZSH_INVALID;
        if (![[NSFileManager defaultManager] fileExistsAtPath:value]) return ZSH_NOT_FOUND;
        return shell_open([NSURL fileURLWithPath:value], failure);
    }
}

/* ---- Login items ----
   macOS 13 and later: the app bundle's SMAppService main app service, which
   System Settings > General > Login Items lists. Earlier: a launch agent in
   ~/Library/LaunchAgents/<id>.plist that opens the bundle. Both need the
   process to run from an app bundle. Status: 0 ok, 1 no app bundle,
   2 needs the user's approval in System Settings (registered), 3 failed
   (NSError code in *code), 4 unavailable (no SMAppService and no agent). */

static NSString *bundle_path(void) {
    NSString *path = [[NSBundle mainBundle] bundlePath];
    return [[path pathExtension] isEqualToString:@"app"] ? path : nil;
}
static NSURL *agent_url(const char *id) {
    NSString *name = [ztext(id) stringByAppendingPathExtension:@"plist"];
    return [NSURL fileURLWithPath:[[NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents"] stringByAppendingPathComponent:name]];
}
static SMAppService *main_service(void) API_AVAILABLE(macos(13.0)) { return [SMAppService mainAppService]; }

int zsm_login_set(const char *id, const char *const *arguments, uint32_t count, int *code) {
    @autoreleasepool {
        NSString *app = bundle_path();
        if (!app) return 1;
        if (@available(macOS 13.0, *)) {
            NSError *error = nil;
            if (![main_service() registerAndReturnError:&error]) {
                if ([main_service() status] == SMAppServiceStatusEnabled) return 0;
                *code = (int)[error code];
                return 3;
            }
            return [main_service() status] == SMAppServiceStatusRequiresApproval ? 2 : 0;
        }
        NSMutableArray *program = [@[@"/usr/bin/open", @"-a", app] mutableCopy];
        if (count) {
            [program addObject:@"--args"];
            for (uint32_t i = 0; i < count; i++) [program addObject:ztext(arguments[i]) ?: @""];
        }
        NSDictionary *agent = @{@"Label": ztext(id), @"ProgramArguments": program, @"RunAtLoad": @YES};
        NSURL *url = agent_url(id);
        NSError *error = nil;
        [[NSFileManager defaultManager] createDirectoryAtURL:[url URLByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        if (![agent writeToURL:url error:&error]) { *code = (int)[error code]; return 3; }
        return 0;
    }
}
int zsm_login_remove(const char *id, int *code) {
    @autoreleasepool {
        if (!bundle_path()) return 1;
        if (@available(macOS 13.0, *)) {
            if ([main_service() status] == SMAppServiceStatusNotRegistered) return 0;
            NSError *error = nil;
            if (![main_service() unregisterAndReturnError:&error]) { *code = (int)[error code]; return 3; }
            return 0;
        }
        NSError *error = nil;
        if (![[NSFileManager defaultManager] removeItemAtURL:agent_url(id) error:&error] && !([[error domain] isEqualToString:NSCocoaErrorDomain] && [error code] == NSFileNoSuchFileError)) {
            *code = (int)[error code];
            return 3;
        }
        return 0;
    }
}
/* 1 enabled, 0 not, negative: -1 no app bundle. */
int zsm_login_registered(const char *id) {
    @autoreleasepool {
        if (!bundle_path()) return -1;
        if (@available(macOS 13.0, *)) return [main_service() status] == SMAppServiceStatusEnabled ? 1 : 0;
        return [[NSFileManager defaultManager] fileExistsAtPath:[agent_url(id) path]] ? 1 : 0;
    }
}

/* ---- URL schemes ----
   A bundle declares its schemes in Info.plist (CFBundleURLTypes) and Launch
   Services registers them with the bundle; at run time the app can only
   become the default handler of a declared one. Status: 0 ok, 1 no app
   bundle, 2 not declared, 3 Launch Services failed (OSStatus in *code). */

static int scheme_declared(NSString *scheme) {
    for (NSDictionary *type in [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleURLTypes"]) {
        if (![type isKindOfClass:[NSDictionary class]]) continue;
        for (NSString *declared in type[@"CFBundleURLSchemes"])
            if ([declared isKindOfClass:[NSString class]] && [declared caseInsensitiveCompare:scheme] == NSOrderedSame) return 1;
    }
    return 0;
}
int zsm_scheme_register(const char *scheme, int make_default, int *code) {
    @autoreleasepool {
        if (!bundle_path()) return 1;
        NSString *name = ztext(scheme);
        if (!scheme_declared(name)) return 2;
        if (!make_default) return 0;
        NSString *identifier = [[NSBundle mainBundle] bundleIdentifier];
        if (!identifier) return 1;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        OSStatus status = LSSetDefaultHandlerForURLScheme((__bridge CFStringRef)name, (__bridge CFStringRef)identifier);
#pragma clang diagnostic pop
        if (status != noErr) { *code = (int)status; return 3; }
        return 0;
    }
}
/* 1 when this bundle is the scheme's default handler. */
int zsm_scheme_is_default(const char *scheme) {
    @autoreleasepool {
        NSString *identifier = [[NSBundle mainBundle] bundleIdentifier];
        if (!identifier) return 0;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSString *handler = (__bridge_transfer NSString *)LSCopyDefaultHandlerForURLScheme((__bridge CFStringRef)ztext(scheme));
#pragma clang diagnostic pop
        return handler && [handler caseInsensitiveCompare:identifier] == NSOrderedSame;
    }
}

/* ---- Desktop snapshots ----
   The desktop ABI of desktop.zig. Coordinates are points with the origin at
   the top-left of the primary display, y down, as window bounds use. */

enum { ZSD_MONITORS = 1, ZSD_PREFERENCES = 2, ZSD_POWER = 4, ZSD_NETWORK = 8 };
enum { ZSD_OK = 0, ZSD_UNSUPPORTED = 1, ZSD_FAILED = 2, ZSD_CAPACITY = 3, ZSD_NO_MEMORY = 4 };
typedef struct ZsdRect { int32_t x, y; uint32_t width, height; } ZsdRect;
typedef struct ZsdMonitor { ZsdRect bounds, work; float scale; uint32_t primary, refresh_millihz; } ZsdMonitor;
typedef struct ZsdPreferences { int32_t scheme; uint32_t high_contrast, reduce_motion; float text_scale; int32_t accent, reduce_transparency; } ZsdPreferences;
typedef struct ZsdPower { int32_t source, percent, saver; } ZsdPower;
typedef struct ZsdNetwork { int32_t state, metered; } ZsdNetwork;
typedef void (*ZsdChanged)(void *owner, uint32_t bits);

static atomic_uint desktop_live;
uint32_t zsd_resource_count(void) { return atomic_load(&desktop_live); }

int zsd_beep(void) { NSBeep(); return ZSD_OK; }

static double primary_height(void) {
    NSArray<NSScreen *> *screens = [NSScreen screens];
    return [screens count] ? [[screens objectAtIndex:0] frame].size.height : 0;
}
static ZsdRect flip(NSRect rect, double height) {
    return (ZsdRect){(int32_t)lround(rect.origin.x), (int32_t)lround(height - rect.origin.y - rect.size.height), (uint32_t)fmax(0, lround(rect.size.width)), (uint32_t)fmax(0, lround(rect.size.height))};
}
int zsd_cursor(int32_t *x, int32_t *y) {
    @autoreleasepool {
        NSPoint point = [NSEvent mouseLocation];
        *x = (int32_t)lround(point.x);
        *y = (int32_t)lround(primary_height() - point.y);
        return ZSD_OK;
    }
}
int zsd_monitors(ZsdMonitor *output, uint32_t capacity, uint32_t *count) {
    @autoreleasepool {
        NSArray<NSScreen *> *screens = [NSScreen screens];
        NSUInteger n = [screens count];
        if (n == 0) return ZSD_FAILED;
        if (n > capacity) return ZSD_CAPACITY;
        double height = primary_height();
        for (NSUInteger i = 0; i < n; i++) {
            NSScreen *screen = screens[i];
            ZsdMonitor *out = &output[i];
            memset(out, 0, sizeof(*out));
            out->bounds = flip([screen frame], height);
            out->work = flip([screen visibleFrame], height);
            out->scale = (float)[screen backingScaleFactor];
            out->primary = i == 0;
            NSInteger fps = 0;
            if (@available(macOS 12.0, *)) fps = [screen maximumFramesPerSecond];
            out->refresh_millihz = fps > 0 ? (uint32_t)fps * 1000u : 0u;
        }
        *count = (uint32_t)n;
        return ZSD_OK;
    }
}
/* The accent as the app's effective appearance draws it, 0xRRGGBB. */
static int32_t accent_color(void) {
    __block int32_t value = -1;
    void (^read)(void) = ^{
        NSColor *color = [[NSColor controlAccentColor] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        if (!color) return;
        CGFloat r, g, b, a;
        [color getRed:&r green:&g blue:&b alpha:&a];
        int32_t R = (int32_t)lround(fmin(fmax(r, 0), 1) * 255), G = (int32_t)lround(fmin(fmax(g, 0), 1) * 255), B = (int32_t)lround(fmin(fmax(b, 0), 1) * 255);
        value = R << 16 | G << 8 | B;
    };
    if (@available(macOS 11.0, *)) [[NSApp effectiveAppearance] performAsCurrentDrawingAppearance:read];
    else read();
    return value;
}
int zsd_preferences(ZsdPreferences *out) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
        memset(out, 0, sizeof(*out));
        out->scheme = zsm_theme_dark() ? 2 : 1;
        out->high_contrast = [workspace accessibilityDisplayShouldIncreaseContrast];
        out->reduce_motion = [workspace accessibilityDisplayShouldReduceMotion];
        out->reduce_transparency = [workspace accessibilityDisplayShouldReduceTransparency];
        out->text_scale = 1;
        out->accent = accent_color();
        return ZSD_OK;
    }
}
int zsd_power(ZsdPower *out) {
    out->source = 0;
    out->percent = -1;
    out->saver = -1;
    @autoreleasepool {
        if (@available(macOS 12.0, *)) out->saver = [[NSProcessInfo processInfo] isLowPowerModeEnabled] ? 1 : 0;
        CFTypeRef info = IOPSCopyPowerSourcesInfo();
        if (!info) return ZSD_OK;
        CFStringRef providing = IOPSGetProvidingPowerSourceType(info);
        if (providing) out->source = CFEqual(providing, CFSTR(kIOPSBatteryPowerValue)) ? 2 : 1;
        CFArrayRef list = IOPSCopyPowerSourcesList(info);
        if (list) {
            for (CFIndex i = 0; i < CFArrayGetCount(list) && out->percent < 0; i++) {
                CFDictionaryRef source = IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, i));
                if (!source) continue;
                CFStringRef type = CFDictionaryGetValue(source, CFSTR(kIOPSTypeKey));
                if (!type || !CFEqual(type, CFSTR(kIOPSInternalBatteryType))) continue;
                CFNumberRef current = CFDictionaryGetValue(source, CFSTR(kIOPSCurrentCapacityKey));
                CFNumberRef maximum = CFDictionaryGetValue(source, CFSTR(kIOPSMaxCapacityKey));
                int now = 0, max = 0;
                if (current && maximum && CFNumberGetValue(current, kCFNumberIntType, &now) && CFNumberGetValue(maximum, kCFNumberIntType, &max) && max > 0) {
                    long percent = lround(100.0 * now / max);
                    out->percent = (int32_t)(percent < 0 ? 0 : percent > 100 ? 100 : percent);
                }
            }
            CFRelease(list);
        }
        CFRelease(info);
        return ZSD_OK;
    }
}

/* One path monitor for the process, on a queue of its own. A snapshot waits
   on the first path for at most a second, as it arrives within
   milliseconds; watches hear of the later ones on the main queue. */
static struct {
    dispatch_once_t once;
    dispatch_semaphore_t first;
    atomic_int ready, state, metered;
    nw_path_monitor_t monitor;
} network;
static void watches_mark(uint32_t bits);
static void network_start(void) {
    dispatch_once(&network.once, ^{
        network.first = dispatch_semaphore_create(0);
        network.monitor = nw_path_monitor_create();
        if (!network.monitor) { dispatch_semaphore_signal(network.first); return; }
        nw_path_monitor_set_update_handler(network.monitor, ^(nw_path_t path) {
            atomic_store(&network.state, nw_path_get_status(path) == nw_path_status_satisfied ? 1 : 2);
            atomic_store(&network.metered, (nw_path_is_expensive(path) || nw_path_is_constrained(path)) ? 1 : 0);
            if (!atomic_exchange(&network.ready, 1)) { dispatch_semaphore_signal(network.first); return; }
            dispatch_async(dispatch_get_main_queue(), ^{ watches_mark(ZSD_NETWORK); });
        });
        nw_path_monitor_set_queue(network.monitor, dispatch_queue_create("ziggurat.network", DISPATCH_QUEUE_SERIAL));
        nw_path_monitor_start(network.monitor);
    });
}
int zsd_network(ZsdNetwork *out) {
    network_start();
    if (!atomic_load(&network.ready) && dispatch_semaphore_wait(network.first, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0)
        dispatch_semaphore_signal(network.first);
    out->state = atomic_load(&network.ready) ? atomic_load(&network.state) : 0;
    out->metered = atomic_load(&network.ready) ? atomic_load(&network.metered) : -1;
    return ZSD_OK;
}

/* ---- Desktop watches ----
   Each watch observes the notifications of its kinds; a burst of them
   becomes one call on the main queue. A stopped watch clears its owner at
   once, so a pending flush does nothing; the block keeps the record. */

@interface ZsdWatch : NSObject {
@public
    void *owner;
    ZsdChanged changed;
    uint32_t kinds, pending;
    int scheduled, observing_appearance;
    CFRunLoopSourceRef power_source;
}
- (void)mark:(uint32_t)bits;
@end

static NSMutableArray<ZsdWatch *> *watches;
static void watches_mark(uint32_t bits) { for (ZsdWatch *watch in [watches copy]) [watch mark:bits]; }
static void power_changed(void *context) { (void)context; watches_mark(ZSD_POWER); }

@implementation ZsdWatch
- (void)mark:(uint32_t)bits {
    if (!owner) return;
    pending |= bits & kinds;
    if (!pending || scheduled) return;
    scheduled = 1;
    ZsdWatch *watch = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        uint32_t ready = watch->pending;
        watch->pending = 0;
        watch->scheduled = 0;
        if (watch->owner && ready) watch->changed(watch->owner, ready);
    });
}
- (void)monitors:(NSNotification *)note { (void)note; [self mark:ZSD_MONITORS]; }
- (void)preferences:(NSNotification *)note { (void)note; [self mark:ZSD_PREFERENCES]; }
- (void)power:(NSNotification *)note { (void)note; [self mark:ZSD_POWER]; }
- (void)observeValueForKeyPath:(NSString *)path ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    (void)path; (void)object; (void)change; (void)context;
    [self mark:ZSD_PREFERENCES];
}
@end

int zsd_watch_start(uint32_t kinds, void *owner, ZsdChanged changed, void **out) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        ZsdWatch *watch = [ZsdWatch new];
        if (!watch) return ZSD_NO_MEMORY;
        watch->owner = owner;
        watch->changed = changed;
        watch->kinds = kinds;
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        NSNotificationCenter *workspace = [[NSWorkspace sharedWorkspace] notificationCenter];
        if (kinds & ZSD_MONITORS) [center addObserver:watch selector:@selector(monitors:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
        if (kinds & ZSD_PREFERENCES) {
            [NSApp addObserver:watch forKeyPath:@"effectiveAppearance" options:0 context:NULL];
            watch->observing_appearance = 1;
            [center addObserver:watch selector:@selector(preferences:) name:NSSystemColorsDidChangeNotification object:nil];
            [workspace addObserver:watch selector:@selector(preferences:) name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
        }
        if (kinds & ZSD_POWER) {
            if (@available(macOS 12.0, *)) [center addObserver:watch selector:@selector(power:) name:NSProcessInfoPowerStateDidChangeNotification object:nil];
            watch->power_source = IOPSNotificationCreateRunLoopSource(power_changed, NULL);
            if (watch->power_source) CFRunLoopAddSource(CFRunLoopGetMain(), watch->power_source, kCFRunLoopCommonModes);
        }
        if (kinds & ZSD_NETWORK) network_start();
        if (!watches) watches = [NSMutableArray array];
        [watches addObject:watch];
        atomic_fetch_add(&desktop_live, 1);
        *out = (__bridge_retained void *)watch;
        return ZSD_OK;
    }
}
void zsd_watch_stop(void *handle) {
    @autoreleasepool {
        ZsdWatch *watch = (__bridge_transfer ZsdWatch *)handle;
        watch->owner = NULL;
        watch->pending = 0;
        [[NSNotificationCenter defaultCenter] removeObserver:watch];
        [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:watch];
        if (watch->observing_appearance) [NSApp removeObserver:watch forKeyPath:@"effectiveAppearance"];
        watch->observing_appearance = 0;
        if (watch->power_source) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), watch->power_source, kCFRunLoopCommonModes);
            CFRelease(watch->power_source);
            watch->power_source = NULL;
        }
        [watches removeObject:watch];
        atomic_fetch_sub(&desktop_live, 1);
    }
}

/* ---- URLs and documents the system asks the app to open ---- */

/* kind: 0 URLs, 1 file paths. Items are UTF-8, valid during the call. */
typedef void (*ZsmOpenCallback)(void *owner, int kind, const char *const *items, size_t count, int sender);

@interface ZsmOpenHandler : NSObject {
@public
    void *owner;
    ZsmOpenCallback callback;
}
@end

static int sender_of(NSAppleEventDescriptor *event) {
    NSAppleEventDescriptor *pid = [event attributeDescriptorForKeyword:keySenderPIDAttr];
    return pid ? [pid int32Value] : 0;
}
static void deliver_open(ZsmOpenHandler *handler, int kind, NSArray<NSString *> *items, int sender) {
    if (!handler->owner || [items count] == 0) return;
    const char **values = calloc([items count], sizeof *values);
    if (!values) return;
    size_t count = 0;
    for (NSString *item in items) {
        const char *value = [item UTF8String];
        if (value) values[count++] = value;
    }
    if (count) handler->callback(handler->owner, kind, values, count, sender);
    free(values);
}

@implementation ZsmOpenHandler
- (void)url:(NSAppleEventDescriptor *)event reply:(NSAppleEventDescriptor *)reply {
    (void)reply;
    NSString *url = [[event paramDescriptorForKeyword:keyDirectObject] stringValue];
    if (url) deliver_open(self, 0, @[url], sender_of(event));
}
- (void)documents:(NSAppleEventDescriptor *)event reply:(NSAppleEventDescriptor *)reply {
    (void)reply;
    NSAppleEventDescriptor *list = [[event paramDescriptorForKeyword:keyDirectObject] coerceToDescriptorType:typeAEList];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSInteger i = 1; i <= [list numberOfItems]; i++) {
        NSData *data = [[[list descriptorAtIndex:i] coerceToDescriptorType:typeFileURL] data];
        NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSURL *url = text ? [NSURL URLWithString:text] : nil;
        NSString *path = [url isFileURL] ? [[url filePathURL] path] : nil;
        if (path) [paths addObject:path];
    }
    deliver_open(self, 1, paths, sender_of(event));
}
@end

static ZsmOpenHandler *open_handler;
static NSArray *open_observers;

static void install_open_handlers(void) {
    if (!open_handler) return;
    NSAppleEventManager *manager = [NSAppleEventManager sharedAppleEventManager];
    [manager setEventHandler:open_handler andSelector:@selector(url:reply:) forEventClass:kInternetEventClass andEventID:kAEGetURL];
    [manager setEventHandler:open_handler andSelector:@selector(documents:reply:) forEventClass:kCoreEventClass andEventID:kAEOpenDocuments];
}

/* Installs the GURL and odoc handlers; at most one listener. NSApplication
   installs its own odoc handler whenever it finishes launching, which
   [NSApp run] does again, so the handlers are installed again then, before
   the launch's own requests are dispatched. */
int zsm_open_start(void *owner, ZsmOpenCallback callback) {
    if (open_handler) return 0;
    open_handler = [[ZsmOpenHandler alloc] init];
    open_handler->owner = owner;
    open_handler->callback = callback;
    install_open_handlers();
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    void (^again)(NSNotification *) = ^(NSNotification *note) { (void)note; install_open_handlers(); };
    open_observers = @[
        [center addObserverForName:NSApplicationWillFinishLaunchingNotification object:nil queue:nil usingBlock:again],
        [center addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:again],
    ];
    return 1;
}
void zsm_open_stop(void) {
    if (!open_handler) return;
    for (id observer in open_observers) [[NSNotificationCenter defaultCenter] removeObserver:observer];
    open_observers = nil;
    NSAppleEventManager *manager = [NSAppleEventManager sharedAppleEventManager];
    [manager removeEventHandlerForEventClass:kInternetEventClass andEventID:kAEGetURL];
    [manager removeEventHandlerForEventClass:kCoreEventClass andEventID:kAEOpenDocuments];
    open_handler->owner = NULL;
    open_handler = nil;
}
/* Integration checks: dispatches an event to the installed handler as the
   system's delivery does. kind 0 sends a GURL with `item`, 1 an odoc with one file. */
int zsm_open_simulate(int kind, const char *item) {
    NSString *value = [NSString stringWithUTF8String:item];
    if (!value) return 0;
    pid_t pid = getpid();
    NSAppleEventDescriptor *target = [NSAppleEventDescriptor descriptorWithDescriptorType:typeKernelProcessID bytes:&pid length:sizeof pid];
    NSAppleEventDescriptor *event = [NSAppleEventDescriptor appleEventWithEventClass:kind ? kCoreEventClass : kInternetEventClass eventID:kind ? kAEOpenDocuments : kAEGetURL targetDescriptor:target returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
    if (kind) {
        NSAppleEventDescriptor *list = [NSAppleEventDescriptor listDescriptor];
        NSData *url = [[[NSURL fileURLWithPath:value] absoluteString] dataUsingEncoding:NSUTF8StringEncoding];
        [list insertDescriptor:[NSAppleEventDescriptor descriptorWithDescriptorType:typeFileURL data:url] atIndex:1];
        [event setParamDescriptor:list forKeyword:keyDirectObject];
    } else [event setParamDescriptor:[NSAppleEventDescriptor descriptorWithString:value] forKeyword:keyDirectObject];
    [event setAttributeDescriptor:[NSAppleEventDescriptor descriptorWithInt32:pid] forKeyword:keySenderPIDAttr];
    /* Calls the handler the process installed for the event, as the Apple
       Event Manager does for a received event: sending it to ourselves would
       need the Automation permission in some sessions. */
    AEEventHandlerUPP handler = NULL;
    SRefCon refcon = 0;
    if (AEGetEventHandler(kind ? kCoreEventClass : kInternetEventClass, kind ? kAEOpenDocuments : kAEGetURL, &handler, &refcon, false) != noErr || !handler) return 0;
    AppleEvent reply = {typeNull, NULL};
    OSErr status = handler([event aeDesc], &reply, refcon);
    AEDisposeDesc(&reply);
    return status == noErr;
}
