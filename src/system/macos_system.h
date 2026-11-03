/* Shared by the AppKit menu, tray, Dock and dialog code of the system
   module. Every function runs on the main thread. Compiled with ARC: the
   records handed to Zig are retained once (CFBridgingRetain) and released
   by the call that removes or detaches them. */
#import <AppKit/AppKit.h>
#include <stdint.h>

typedef void (*ZsmDone)(void *owner, uint64_t serial, int32_t result);

/* A native record that reports to a Zig owner. Clearing `owner` detaches
   it: nothing reports any more, while AppKit may still hold the record. */
@interface ZsmLink : NSObject {
@public
    void *owner;
    uint64_t serial;
    ZsmDone done;
}
- (instancetype)initWithOwner:(void *)owner serial:(uint64_t)serial done:(ZsmDone)done;
/* Reports once and detaches. */
- (void)finish:(int32_t)result;
@end

/* Records alive, including detached ones AppKit still holds. */
int32_t zsm_live_links(void);

NSString *zsm_string(const char *text);
/* The height of the primary display, which turns Cocoa's bottom-left screen
   coordinates into the top-left ones windows use. */
double zsm_primary_height(void);
