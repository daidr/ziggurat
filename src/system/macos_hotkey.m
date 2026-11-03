/* Global hotkeys and notifications for the system module. Hotkeys are
   Carbon's RegisterEventHotKey, which needs no Accessibility permission and
   reaches the application whichever app is active; a hotkey that repeats
   reports again at the user's key repeat rate while it is held. Notifications
   go to the Notification Center through UNUserNotificationCenter, which only
   an app bundle can use. Every function runs on the main thread. */
#import "macos_system.h"
#import <Carbon/Carbon.h>
#import <UserNotifications/UserNotifications.h>

/* ---- Hotkeys ---- */

enum { HOTKEY_UNSUPPORTED_KEY = 2, HOTKEY_REGISTER_FAILED = 3 };
static const OSType hotkey_signature = 'zgHK';

@interface ZsmHotkey : ZsmLink {
@public
    EventHotKeyRef ref;
    UInt32 number;
    BOOL repeats;
    NSTimer *timer;
}
@end

static NSMutableDictionary<NSNumber *, ZsmHotkey *> *hotkeys;
static EventHandlerRef hotkey_handler;
static UInt32 hotkey_next = 1;

@implementation ZsmHotkey
- (void)report {
    void *target = owner;
    if (target && done) done(target, serial, 0);
}
- (void)stopRepeating {
    [timer invalidate];
    timer = nil;
}
- (void)pressed {
    [self stopRepeating];
    if (repeats) {
        __weak ZsmHotkey *weak = self;
        timer = [NSTimer timerWithTimeInterval:[NSEvent keyRepeatDelay] repeats:NO block:^(NSTimer *first) {
            (void)first;
            ZsmHotkey *strong = weak;
            if (!strong) return;
            strong->timer = [NSTimer timerWithTimeInterval:[NSEvent keyRepeatInterval] repeats:YES block:^(NSTimer *each) {
                (void)each;
                [weak report];
            }];
            [[NSRunLoop mainRunLoop] addTimer:strong->timer forMode:NSRunLoopCommonModes];
            [strong report];
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    }
    /* The owner may unregister this hotkey from its callback. */
    __attribute__((objc_precise_lifetime)) ZsmHotkey *keep = self;
    (void)keep;
    [self report];
}
@end

static OSStatus hotkey_event(EventHandlerCallRef next, EventRef event, void *data) {
    (void)next;
    (void)data;
    EventHotKeyID id;
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof id, NULL, &id) != noErr) return eventNotHandledErr;
    if (id.signature != hotkey_signature) return eventNotHandledErr;
    ZsmHotkey *hotkey = [hotkeys objectForKey:@(id.id)];
    if (!hotkey) return eventNotHandledErr;
    if (GetEventKind(event) == kEventHotKeyPressed) [hotkey pressed];
    else [hotkey stopRepeating];
    return noErr;
}

/* `key` is a virtual key code, `modifiers` Carbon's modifier bits. On
   failure `status` holds the OSStatus and `failure` HOTKEY_*. */
void *zsm_hotkey_register(uint32_t key, uint32_t modifiers, int repeats, void *owner, uint64_t serial, ZsmDone done, int *failure, int32_t *status) {
    *failure = 0;
    *status = 0;
    if (!hotkey_handler) {
        EventTypeSpec kinds[] = {{kEventClassKeyboard, kEventHotKeyPressed}, {kEventClassKeyboard, kEventHotKeyReleased}};
        OSStatus installed = InstallEventHandler(GetApplicationEventTarget(), hotkey_event, 2, kinds, NULL, &hotkey_handler);
        if (installed != noErr) {
            hotkey_handler = NULL;
            *failure = HOTKEY_REGISTER_FAILED;
            *status = installed;
            return NULL;
        }
        hotkeys = [NSMutableDictionary dictionary];
    }
    ZsmHotkey *hotkey = [[ZsmHotkey alloc] initWithOwner:owner serial:serial done:done];
    hotkey->number = hotkey_next++;
    hotkey->repeats = repeats != 0;
    EventHotKeyID id = {hotkey_signature, hotkey->number};
    OSStatus registered = RegisterEventHotKey(key, modifiers, id, GetApplicationEventTarget(), 0, &hotkey->ref);
    if (registered != noErr) {
        hotkey->owner = NULL;
        *failure = HOTKEY_REGISTER_FAILED;
        *status = registered;
        return NULL;
    }
    [hotkeys setObject:hotkey forKey:@(hotkey->number)];
    return (__bridge_retained void *)hotkey;
}

void zsm_hotkey_unregister(void *handle) {
    ZsmHotkey *hotkey = (__bridge_transfer ZsmHotkey *)handle;
    hotkey->owner = NULL;
    [hotkey stopRepeating];
    if (hotkey->ref) UnregisterEventHotKey(hotkey->ref);
    hotkey->ref = NULL;
    [hotkeys removeObjectForKey:@(hotkey->number)];
}

/* Integration checks: sends the event the system sends when the hotkey's
   keys go down (pressed) or up, through the application's event target. */
int zsm_hotkey_test_event(void *handle, int pressed) {
    ZsmHotkey *hotkey = (__bridge ZsmHotkey *)handle;
    EventRef event = NULL;
    if (CreateEvent(NULL, kEventClassKeyboard, pressed ? kEventHotKeyPressed : kEventHotKeyReleased, 0, kEventAttributeNone, &event) != noErr) return 0;
    EventHotKeyID id = {hotkey_signature, hotkey->number};
    OSStatus status = SetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, sizeof id, &id);
    if (status == noErr) status = SendEventToEventTarget(event, GetApplicationEventTarget());
    ReleaseEvent(event);
    return status == noErr;
}
int zsm_hotkey_live(void) { return (int)[hotkeys count]; }

/* ---- Notifications ---- */

/* done results: 1 activated, 0 dismissed, -1 refused or failed. */
@interface ZsmNote : ZsmLink {
@public
    NSString *identifier;
}
@end
@implementation ZsmNote
@end

@interface ZsmNoteDelegate : NSObject <UNUserNotificationCenterDelegate>
@end

static NSMutableDictionary<NSString *, ZsmNote *> *notes;
static ZsmNoteDelegate *note_delegate;

static void note_finish(NSString *identifier, int32_t result) {
    ZsmNote *note = [notes objectForKey:identifier];
    if (note) [note finish:result];
}

@implementation ZsmNoteDelegate
- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completion {
    (void)center;
    UNNotificationPresentationOptions options = UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList;
    if (notification.request.content.sound) options |= UNNotificationPresentationOptionSound;
    completion(options);
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response withCompletionHandler:(void (^)(void))completion {
    (void)center;
    NSString *identifier = response.notification.request.identifier;
    NSString *action = response.actionIdentifier;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([action isEqualToString:UNNotificationDefaultActionIdentifier]) note_finish(identifier, 1);
        else if ([action isEqualToString:UNNotificationDismissActionIdentifier]) note_finish(identifier, 0);
    });
    completion();
}
@end

/* UNUserNotificationCenter raises for a process outside an app bundle. */
int zsm_note_available(void) {
    NSBundle *bundle = [NSBundle mainBundle];
    return [bundle bundleIdentifier] != nil && [[bundle bundlePath] hasSuffix:@".app"];
}

static UNUserNotificationCenter *note_center(void) {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    if (!note_delegate) {
        note_delegate = [[ZsmNoteDelegate alloc] init];
        notes = [NSMutableDictionary dictionary];
        center.delegate = note_delegate;
    }
    return center;
}

/* Asks for permission the first time, then adds the request; a refusal or
   failure reports -1 after this call returns. NULL outside an app bundle. */
/* A notification's image, as an attachment, which UserNotifications makes
   only of a file, its format told by its extension: written to a temporary
   file, which the system moves into its store as it adds the request. The
   caller removes the file if it is still there once the request is added or
   refused. nil, with *path nil, for an image the system does not take. */
static UNNotificationAttachment *note_attachment(const unsigned char *bytes, size_t length, NSString **path) {
    *path = nil;
    const BOOL jpeg = length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff;
    NSString *name = [NSString stringWithFormat:@"ziggurat-notification-%@.%@", [[NSUUID UUID] UUIDString], jpeg ? @"jpg" : @"png"];
    NSString *file = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    if (![[NSData dataWithBytes:bytes length:length] writeToFile:file options:NSDataWritingAtomic error:NULL]) return nil;
    NSError *error = nil;
    UNNotificationAttachment *attachment = [UNNotificationAttachment attachmentWithIdentifier:@"" URL:[NSURL fileURLWithPath:file] options:nil error:&error];
    if (!attachment) {
        [[NSFileManager defaultManager] removeItemAtPath:file error:NULL];
        return nil;
    }
    *path = file;
    return attachment;
}
static void note_remove_file(NSString *path) {
    if (path) [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

void *zsm_note_show(const char *title, const char *body, int silent, const unsigned char *image, size_t image_length, void *owner, uint64_t serial, ZsmDone done) {
    if (!zsm_note_available()) return NULL;
    UNUserNotificationCenter *center = note_center();
    ZsmNote *note = [[ZsmNote alloc] initWithOwner:owner serial:serial done:done];
    note->identifier = [NSString stringWithFormat:@"ziggurat.%@", [[NSUUID UUID] UUIDString]];
    [notes setObject:note forKey:note->identifier];
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = zsm_string(title);
    content.body = zsm_string(body);
    if (!silent) content.sound = [UNNotificationSound defaultSound];
    NSString *image_path = nil;
    if (image && image_length) {
        UNNotificationAttachment *attachment = note_attachment(image, image_length, &image_path);
        if (attachment) content.attachments = @[attachment];
    }
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:note->identifier content:content trigger:nil];
    NSString *identifier = note->identifier;
    [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound completionHandler:^(BOOL granted, NSError *error) {
        if (!granted || error) {
            note_remove_file(image_path);
            dispatch_async(dispatch_get_main_queue(), ^{ note_finish(identifier, -1); });
            return;
        }
        [center addNotificationRequest:request withCompletionHandler:^(NSError *failed) {
            note_remove_file(image_path);
            if (failed) dispatch_async(dispatch_get_main_queue(), ^{ note_finish(identifier, -1); });
        }];
    }];
    return (__bridge_retained void *)note;
}

/* Detaches the record and withdraws the notification, shown or not yet. */
void zsm_note_close(void *handle) {
    ZsmNote *note = (__bridge_transfer ZsmNote *)handle;
    note->owner = NULL;
    [notes removeObjectForKey:note->identifier];
    UNUserNotificationCenter *center = note_center();
    [center removePendingNotificationRequestsWithIdentifiers:@[note->identifier]];
    [center removeDeliveredNotificationsWithIdentifiers:@[note->identifier]];
}
