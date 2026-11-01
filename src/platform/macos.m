/* The AppKit application and window adapter. Every function runs on the
   main thread except zlm_app_wake. Window events reach Zig through the same
   event wire as the GTK adapter; the kinds are documented in macos.zig.
   Compiled without ARC: objects are retained and released explicitly. */
#import <AppKit/AppKit.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

typedef struct NativeEvent {
    int kind,key,flags;
    void *context,*window;
    double x,y,dx,dy;
    uint32_t width,height,scale;
    const char *text;
    size_t length,selection;
} NativeEvent;
typedef int (*Emit)(void *,const NativeEvent *);
typedef struct NativeBounds {int32_t x,y;uint32_t width,height;int positioned;} NativeBounds;

typedef struct NativeApp {void *owner;void (*dispatch)(void *);atomic_int pending,stopped;} NativeApp;
static NativeApp *current_app;

/* The application delegate. It answers the Dock's question for the menu
   the system module set (zlm_app_set_dock_menu). */
@interface ZigAppDelegate : NSObject <NSApplicationDelegate>
@end
static NSMenu *dock_menu;
static ZigAppDelegate *app_delegate;
@implementation ZigAppDelegate
- (NSMenu *)applicationDockMenu:(NSApplication *)sender{(void)sender;return dock_menu;}
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app{(void)app;return YES;}
@end
void zlm_app_set_dock_menu(void *menu){NSMenu *value=(NSMenu *)menu;[value retain];[dock_menu release];dock_menu=value;}

static void wake_main(void *unused){
    (void)unused;NativeApp *app=current_app;int expected=1;
    if(app&&atomic_compare_exchange_strong(&app->pending,&expected,0)&&app->owner)app->dispatch(app->owner);
}
NativeApp *zlm_app_create(void *owner,void (*dispatch)(void *),int *error){
    if(current_app){*error=1;return NULL;}
    if(![NSThread isMainThread]){*error=2;return NULL;}
    NativeApp *app=calloc(1,sizeof(NativeApp));if(!app){*error=3;return NULL;}
    @autoreleasepool{
        [NSApplication sharedApplication];
        /* AppKit's autofill heuristics inspect every text view that takes
           focus and offer contacts and passwords; the framework's own text
           input is not a form, so they stay off unless the app says so. */
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"NSAutoFillHeuristicControllerEnabled":@NO}];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        if(!app_delegate)app_delegate=[[ZigAppDelegate alloc] init];
        [NSApp setDelegate:app_delegate];
        [NSApp finishLaunching];
    }
    app->owner=owner;app->dispatch=dispatch;current_app=app;*error=0;return app;
}
void zlm_app_wake(NativeApp *app){int expected=0;if(atomic_compare_exchange_strong(&app->pending,&expected,1))dispatch_async_f(dispatch_get_main_queue(),NULL,wake_main);}
static void post_wake_event(void){
    NSEvent *event=[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0];
    [NSApp postEvent:event atStart:YES];
}
void zlm_app_quit(NativeApp *app){atomic_store(&app->stopped,1);@autoreleasepool{[NSApp stop:nil];post_wake_event();}}
void zlm_app_run(NativeApp *app){if(!atomic_load(&app->stopped))@autoreleasepool{[NSApp run];}}
void zlm_app_destroy(NativeApp *app){app->owner=NULL;if(current_app==app)current_app=NULL;zlm_app_set_dock_menu(NULL);free(app);}

@class ZigView;
@class ZigDelegate;
typedef struct NativeWindow {
    NSWindow *window;ZigView *view;ZigDelegate *delegate;
    void *owner;Emit emit;int refs,destroyed;
    int decoration,popup,enabled,keyboard,fullscreen_requested,topmost_requested,shown;
    uint32_t observed_width,observed_height,observed_scale;int size_observed;
    NSEvent *gesture;NSRect caret;
    NSMutableString *marked;NSRange marked_selection;
    NSCursor *cursor;
} NativeWindow;
enum {POPUP=1,POPUP_FOCUSABLE=2,POPUP_TOPMOST=4};

static void retain_window(NativeWindow *s){s->refs++;}
static atomic_uint live_windows;
static void release_window(NativeWindow *s){if(--s->refs==0){[s->marked release];[s->cursor release];free(s);atomic_fetch_sub(&live_windows,1);}}
static int emit(NativeWindow *s,NativeEvent *event){retain_window(s);int result=0;if(s->owner&&!s->destroyed)result=s->emit(s->owner,event);release_window(s);return result;}
static uint32_t modifiers(NSEventModifierFlags flags){
    return ((flags&NSEventModifierFlagShift)?1u:0u)|((flags&NSEventModifierFlagControl)?2u:0u)|((flags&NSEventModifierFlagOption)?4u:0u)|((flags&NSEventModifierFlagCommand)?8u:0u);
}
static void size_event(NativeWindow *s,NativeEvent *event){
    NSRect bounds=[s->view bounds];double scale=[s->window backingScaleFactor];
    event->scale=(uint32_t)fmax(1,lround(scale));
    event->width=(uint32_t)fmax(0,lround(bounds.size.width*event->scale));event->height=(uint32_t)fmax(0,lround(bounds.size.height*event->scale));
    event->window=s->window;
}
static void notify_size(NativeWindow *s){
    if(s->destroyed||!s->view)return;
    NativeEvent event={0};event.kind=2;size_event(s,&event);
    if(s->size_observed&&event.width==s->observed_width&&event.height==s->observed_height&&event.scale==s->observed_scale)return;
    s->size_observed=1;s->observed_width=event.width;s->observed_height=event.height;s->observed_scale=event.scale;
    emit(s,&event);
}
static void notify_state(NativeWindow *s){NativeEvent event={0};event.kind=16;emit(s,&event);}
static int input_allowed(NativeWindow *s){NativeEvent gate={0};gate.kind=17;return s->enabled&&emit(s,&gate);}
static int query_hit(NativeWindow *s,NSPoint point){
    if(!s->decoration)return 0;
    NSRect bounds=[s->view bounds];
    NativeEvent event={0};event.kind=19;event.x=point.x;event.y=point.y;event.width=(uint32_t)fmax(0,bounds.size.width);event.height=(uint32_t)fmax(0,bounds.size.height);
    return emit(s,&event);
}
static void emit_text(NativeWindow *s,int kind,NSString *string,size_t selection){
    const char *text=[string UTF8String];if(!text)return;
    NativeEvent event={0};event.kind=kind;event.text=text;event.length=strlen(text);event.selection=selection;emit(s,&event);
}
static void emit_edit(NativeWindow *s,int key,uint32_t flags){NativeEvent event={0};event.kind=9;event.key=key;event.flags=(int)flags;emit(s,&event);}

@interface ZigWindow : NSWindow
@property(nonatomic) BOOL takesKeyboard;
@end
@implementation ZigWindow
- (BOOL)canBecomeKeyWindow{return self.takesKeyboard;}
- (BOOL)canBecomeMainWindow{return self.takesKeyboard;}
@end

@interface ZigView : NSView <NSTextInputClient>{
@public NativeWindow *native;
}
@end
@interface ZigDelegate : NSObject <NSWindowDelegate>{
@public NativeWindow *native;
}
@end

/* Edit keys of the shared wire: left right up down home end backspace
   delete a c x v z y. */
static int edit_for_selector(SEL selector,uint32_t *flags){
    static const struct {const char *name;int key;uint32_t shift;} table[]={
        {"moveLeft:",0,0},{"moveRight:",1,0},{"moveUp:",2,0},{"moveDown:",3,0},
        {"moveLeftAndModifySelection:",0,1},{"moveRightAndModifySelection:",1,1},{"moveUpAndModifySelection:",2,1},{"moveDownAndModifySelection:",3,1},
        {"moveToBeginningOfLine:",4,0},{"moveToLeftEndOfLine:",4,0},{"moveToEndOfLine:",5,0},{"moveToRightEndOfLine:",5,0},
        {"moveToBeginningOfLineAndModifySelection:",4,1},{"moveToLeftEndOfLineAndModifySelection:",4,1},
        {"moveToEndOfLineAndModifySelection:",5,1},{"moveToRightEndOfLineAndModifySelection:",5,1},
        {"scrollToBeginningOfDocument:",4,0},{"scrollToEndOfDocument:",5,0},
        {"deleteBackward:",6,0},{"deleteBackwardByDecomposingPreviousCharacter:",6,0},{"deleteForward:",7,0},
    };
    const char *name=sel_getName(selector);
    for(size_t i=0;i<sizeof(table)/sizeof(table[0]);i++)if(!strcmp(name,table[i].name)){*flags=table[i].shift;return table[i].key;}
    return -1;
}

@implementation ZigView
- (BOOL)isFlipped{return YES;}
- (BOOL)acceptsFirstResponder{return YES;}
- (BOOL)acceptsFirstMouse:(NSEvent *)event{(void)event;return YES;}
- (void)drawRect:(NSRect)dirty{
    (void)dirty;NativeWindow *s=native;if(!s||s->destroyed)return;
    CGContextRef context=[[NSGraphicsContext currentContext] CGContext];if(!context)return;
    NativeEvent event={0};event.kind=1;event.context=context;size_event(s,&event);emit(s,&event);
}
- (void)resetCursorRects{NativeWindow *s=native;if(s&&s->cursor)[self addCursorRect:[self bounds] cursor:s->cursor];}
- (void)setFrameSize:(NSSize)size{[super setFrameSize:size];if(native)notify_size(native);}
- (void)viewDidChangeBackingProperties{[super viewDidChangeBackingProperties];if(native)notify_size(native);}
- (void)updateTrackingAreas{
    for(NSTrackingArea *area in [self trackingAreas])[self removeTrackingArea:area];
    NSTrackingArea *area=[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:area];[area release];[super updateTrackingAreas];
}
- (NSPoint)local:(NSEvent *)event{return [self convertPoint:[event locationInWindow] fromView:nil];}
- (void)mouseDown:(NSEvent *)event{
    NativeWindow *s=native;if(!s)return;retain_window(s);
    NSPoint point=[self local:event];
    if(!input_allowed(s)){release_window(s);return;}
    int hit=query_hit(s,point);
    if(!s->destroyed&&hit==1){
        if([event clickCount]==2)[s->window performZoom:nil];else [s->window performWindowDragWithEvent:event];
        release_window(s);return;
    }
    if(!s->destroyed&&!(s->popup&&!(s->popup&POPUP_FOCUSABLE)))[s->window makeFirstResponder:self];
    NativeEvent down={0};down.kind=3;down.x=point.x;down.y=point.y;down.flags=(int)modifiers([event modifierFlags]);
    s->gesture=event;emit(s,&down);if(s->gesture==event)s->gesture=nil;
    release_window(s);
}
- (void)mouseUp:(NSEvent *)event{
    NativeWindow *s=native;if(!s)return;NSPoint point=[self local:event];
    if(!input_allowed(s))return;
    NativeEvent up={0};up.kind=4;up.x=point.x;up.y=point.y;up.flags=(int)modifiers([event modifierFlags]);emit(s,&up);
}
- (void)moved:(NSEvent *)event{
    NativeWindow *s=native;if(!s)return;NSPoint point=[self local:event];
    NativeEvent move={0};move.kind=5;move.x=point.x;move.y=point.y;emit(s,&move);
}
- (void)mouseMoved:(NSEvent *)event{[self moved:event];}
- (void)mouseDragged:(NSEvent *)event{[self moved:event];}
- (void)scrollWheel:(NSEvent *)event{
    NativeWindow *s=native;if(!s)return;NSPoint point=[self local:event];
    /* Precise deltas are points; wheel deltas are lines, as GTK's are. */
    const double unit=[event hasPreciseScrollingDeltas]?1:48;
    NativeEvent wheel={0};wheel.kind=6;wheel.x=point.x;wheel.y=point.y;wheel.dx=-[event scrollingDeltaX]*unit;wheel.dy=-[event scrollingDeltaY]*unit;emit(s,&wheel);
}
static int key_event(NativeWindow *s,NSEvent *event,int kind){
    NSString *plain=[event charactersIgnoringModifiers];unichar c=[plain length]==1?[plain characterAtIndex:0]:0;
    if(c>='A'&&c<='Z')c=(unichar)(c-'A'+'a');
    NativeEvent key={0};key.kind=kind;key.key=c>=0x20&&c<0x7f?c:0;key.width=[event keyCode];
    key.flags=(int)(modifiers([event modifierFlags])|(kind==18&&[event isARepeat]?16u:0u));
    return emit(s,&key);
}
/* Keyboard/compose mode: the layout's characters, without the input method. */
static void keyboard_key(NativeWindow *s,NSEvent *event){
    static const struct {unsigned short code;int key;} edits[]={{0x7b,0},{0x7c,1},{0x7e,2},{0x7d,3},{0x73,4},{0x77,5},{0x33,6},{0x75,7}};
    const unsigned short code=[event keyCode];
    for(size_t i=0;i<sizeof(edits)/sizeof(edits[0]);i++)if(edits[i].code==code){emit_edit(s,edits[i].key,modifiers([event modifierFlags])&1);return;}
    NSString *text=[event characters];
    if(![text length])return;
    const unichar first=[text characterAtIndex:0];
    if(first<0x20||first==0x7f||(first>=0xf700&&first<=0xf8ff))return;
    emit_text(s,12,text,0);
}
- (void)keyDown:(NSEvent *)event{
    NativeWindow *s=native;if(!s)return;retain_window(s);
    if(!input_allowed(s)){release_window(s);return;}
    const int composing=[s->marked length]>0;const uint32_t flags=modifiers([event modifierFlags]);
    if(!composing&&key_event(s,event,18)){release_window(s);return;}
    if(s->destroyed){release_window(s);return;}
    if(!composing&&(flags&8)){
        /* Command shortcuts the text wire knows; others go to the menus. */
        NSString *plain=[[event charactersIgnoringModifiers] lowercaseString];
        static const char shortcuts[]="acxvzy";const char *at=[plain length]==1?strchr(shortcuts,(char)[plain characterAtIndex:0]):NULL;
        if(at&&*at)emit_edit(s,8+(int)(at-shortcuts),2u|(flags&1));
        release_window(s);return;
    }
    const unsigned short code=[event keyCode];
    if(!composing&&!(flags&(2|4))&&(code==0x30||code==0x24||code==0x4c||code==0x31)){
        NativeEvent activate={0};activate.kind=15;activate.key=code==0x30?0:1;emit(s,&activate);release_window(s);return;
    }
    if(s->keyboard){keyboard_key(s,event);release_window(s);return;}
    [self interpretKeyEvents:@[event]];
    release_window(s);
}
/* The Edit menu's actions (copy: and the others, which its roles send to
   the first responder) do what their Command shortcuts do: the menu takes
   the key before the window, so content that binds the key sees it first,
   then the text edit. */
static void menu_edit(NativeWindow *s,unichar key,unsigned short code,uint32_t extra,int edit){
    if(!s)return;retain_window(s);
    if(!input_allowed(s)){release_window(s);return;}
    NativeEvent press={0};press.kind=18;press.key=key;press.width=code;press.flags=(int)(8u|extra);
    if(!emit(s,&press)&&!s->destroyed)emit_edit(s,edit,2u|(extra&1u));
    release_window(s);
}
- (void)selectAll:(id)sender{(void)sender;menu_edit(native,'a',0x00,0,8);}
- (void)copy:(id)sender{(void)sender;menu_edit(native,'c',0x08,0,9);}
- (void)cut:(id)sender{(void)sender;menu_edit(native,'x',0x07,0,10);}
- (void)paste:(id)sender{(void)sender;menu_edit(native,'v',0x09,0,11);}
- (void)pasteAsPlainText:(id)sender{(void)sender;menu_edit(native,'v',0x09,1u|4u,11);}
- (void)undo:(id)sender{(void)sender;menu_edit(native,'z',0x06,0,12);}
- (void)redo:(id)sender{(void)sender;menu_edit(native,'z',0x06,1u,12);}
- (void)delete:(id)sender{(void)sender;NativeWindow *s=native;if(s&&input_allowed(s))emit_edit(s,7,0);}
- (BOOL)validateMenuItem:(NSMenuItem *)item{(void)item;NativeWindow *s=native;return s&&!s->destroyed&&s->enabled;}
- (void)keyUp:(NSEvent *)event{NativeWindow *s=native;if(s&&input_allowed(s))key_event(s,event,26);}
- (void)flagsChanged:(NSEvent *)event{
    NativeWindow *s=native;if(!s||!input_allowed(s))return;
    NSEventModifierFlags mask=0;
    switch([event keyCode]){
        case 0x38:case 0x3c:mask=NSEventModifierFlagShift;break;
        case 0x3b:case 0x3e:mask=NSEventModifierFlagControl;break;
        case 0x3a:case 0x3d:mask=NSEventModifierFlagOption;break;
        case 0x37:case 0x36:mask=NSEventModifierFlagCommand;break;
        case 0x39:mask=NSEventModifierFlagCapsLock;break;
        default:return;
    }
    NativeEvent key={0};key.kind=([event modifierFlags]&mask)?18:26;key.width=[event keyCode];key.flags=(int)modifiers([event modifierFlags]);emit(s,&key);
}
- (void)doCommandBySelector:(SEL)selector{
    NativeWindow *s=native;if(!s)return;uint32_t shift=0;int edit=edit_for_selector(selector,&shift);
    if(edit>=0)emit_edit(s,edit,shift);
}
- (void)insertText:(id)string replacementRange:(NSRange)range{
    (void)range;NativeWindow *s=native;if(!s)return;
    NSString *text=[string isKindOfClass:[NSAttributedString class]]?[string string]:string;
    if([s->marked length]){[s->marked setString:@""];}
    if([text length])emit_text(s,12,text,0);
}
- (void)setMarkedText:(id)string selectedRange:(NSRange)selected replacementRange:(NSRange)range{
    (void)range;NativeWindow *s=native;if(!s)return;
    NSString *text=[string isKindOfClass:[NSAttributedString class]]?[string string]:string;
    [s->marked setString:text];s->marked_selection=selected;
    if(![text length]){NativeEvent cancel={0};cancel.kind=14;emit(s,&cancel);return;}
    NSUInteger at=MIN(selected.location,[text length]);
    size_t selection=strlen([[text substringToIndex:at] UTF8String]);
    emit_text(s,13,text,selection);
}
- (void)unmarkText{NativeWindow *s=native;if(!s)return;if([s->marked length]){[s->marked setString:@""];NativeEvent cancel={0};cancel.kind=14;emit(s,&cancel);}}
- (NSRange)selectedRange{return NSMakeRange(0,0);}
- (NSRange)markedRange{NativeWindow *s=native;return s&&[s->marked length]?NSMakeRange(0,[s->marked length]):NSMakeRange(NSNotFound,0);}
- (BOOL)hasMarkedText{NativeWindow *s=native;return s&&[s->marked length]>0;}
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actual{(void)range;(void)actual;return nil;}
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText{return @[];}
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actual{
    (void)range;(void)actual;NativeWindow *s=native;if(!s)return NSZeroRect;
    NSRect local=[self convertRect:s->caret toView:nil];return [s->window convertRectToScreen:local];
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point{(void)point;return NSNotFound;}
@end

@implementation ZigDelegate
- (BOOL)windowShouldClose:(NSWindow *)window{(void)window;NativeWindow *s=native;if(s){NativeEvent close={0};close.kind=10;emit(s,&close);}return NO;}
- (void)windowDidResize:(NSNotification *)note{(void)note;NativeWindow *s=native;if(s){notify_size(s);notify_state(s);}}
- (void)windowDidMove:(NSNotification *)note{(void)note;NativeWindow *s=native;if(s){NativeEvent moved={0};moved.kind=22;emit(s,&moved);}}
- (void)windowDidBecomeKey:(NSNotification *)note{(void)note;NativeWindow *s=native;if(!s)return;NativeEvent focus={0};focus.kind=7;focus.flags=1;emit(s,&focus);notify_state(s);}
- (void)windowDidResignKey:(NSNotification *)note{
    (void)note;NativeWindow *s=native;if(!s)return;retain_window(s);
    if([s->marked length]){[[s->view inputContext] discardMarkedText];[s->marked setString:@""];}
    NativeEvent focus={0};focus.kind=7;emit(s,&focus);
    NativeEvent cancel={0};cancel.kind=8;emit(s,&cancel);
    if(s->popup&&(s->popup&POPUP_FOCUSABLE)){NativeEvent dismissed={0};dismissed.kind=25;emit(s,&dismissed);}
    if(!s->destroyed)notify_state(s);
    release_window(s);
}
- (void)windowDidMiniaturize:(NSNotification *)note{(void)note;if(native)notify_state(native);}
- (void)windowDidDeminiaturize:(NSNotification *)note{(void)note;if(native)notify_state(native);}
- (void)windowDidEnterFullScreen:(NSNotification *)note{(void)note;if(native)notify_state(native);}
- (void)windowDidExitFullScreen:(NSNotification *)note{(void)note;if(native)notify_state(native);}
- (void)windowDidChangeBackingProperties:(NSNotification *)note{(void)note;if(native)notify_size(native);}
@end

NativeWindow *zlm_window_create(void *owner,Emit callback,const char *title,uint32_t width,uint32_t height,uint32_t min_width,uint32_t min_height,NativeWindow *parent,int modal,int decoration,int resizable,int popup,int *error){
    (void)modal;*error=0;
    NativeWindow *s=calloc(1,sizeof(NativeWindow));if(!s)return NULL;
    atomic_fetch_add(&live_windows,1);
    s->refs=1;s->owner=owner;s->emit=callback;s->decoration=decoration;s->popup=popup;s->enabled=1;
    @autoreleasepool{
        NSWindowStyleMask style=decoration||popup?NSWindowStyleMaskBorderless:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable);
        if(resizable&&!popup)style|=NSWindowStyleMaskResizable;
        if(decoration&&!popup)style|=NSWindowStyleMaskMiniaturizable;
        ZigWindow *window=[[ZigWindow alloc] initWithContentRect:NSMakeRect(0,0,width?width:1,height?height:1) styleMask:style backing:NSBackingStoreBuffered defer:NO];
        if(!window){free(s);atomic_fetch_sub(&live_windows,1);return NULL;}
        window.takesKeyboard=!popup||(popup&POPUP_FOCUSABLE);
        [window setReleasedWhenClosed:NO];
        [window setAcceptsMouseMovedEvents:YES];
        [window setTitle:[NSString stringWithUTF8String:title]?:@""];
        [window setContentMinSize:NSMakeSize(min_width,min_height)];
        if(!popup)[window setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];
        if(popup){[window setLevel:(popup&POPUP_TOPMOST)?NSPopUpMenuWindowLevel:NSFloatingWindowLevel];[window setHasShadow:YES];}
        ZigView *view=[[ZigView alloc] initWithFrame:NSMakeRect(0,0,width?width:1,height?height:1)];
        view->native=s;
        ZigDelegate *delegate=[[ZigDelegate alloc] init];delegate->native=s;
        [window setContentView:view];[window setDelegate:delegate];
        if(parent&&popup)[parent->window addChildWindow:window ordered:NSWindowAbove];
        if(!parent)[window center];
        else{NSRect frame=[parent->window frame];NSRect own=[window frame];[window setFrameOrigin:NSMakePoint(NSMidX(frame)-own.size.width/2,NSMidY(frame)-own.size.height/2)];}
        s->window=window;s->view=view;s->delegate=delegate;s->marked=[[NSMutableString alloc] init];
    }
    return s;
}
int zlm_window_destroy(NativeWindow *s){
    if(s->destroyed)return 1;
    retain_window(s);s->destroyed=1;void *owner=s->owner;s->owner=NULL;
    @autoreleasepool{
        NSWindow *window=s->window;
        s->view->native=NULL;s->delegate->native=NULL;
        [window setDelegate:nil];
        NSWindow *parent=[window parentWindow];if(parent)[parent removeChildWindow:window];
        [window orderOut:nil];[window close];
        [s->view release];[s->delegate release];[window release];
        s->view=nil;s->delegate=nil;s->window=nil;
    }
    if(owner){NativeEvent event={0};event.kind=11;s->emit(owner,&event);}
    release_window(s);release_window(s);return 1;
}
void *zlm_window_handle(NativeWindow *s){return s->window;}
/* The flipped content view that hosts native child views such as a page. */
void *zlm_window_content(NativeWindow *s){return s->destroyed?NULL:s->view;}
void zlm_window_action(NativeWindow *s,int action){
    @autoreleasepool{
        NSWindow *window=s->window;
        switch(action){
            case 0:
                if(s->popup&&!(s->popup&POPUP_FOCUSABLE))[window orderFront:nil];
                else{if(!s->shown)[NSApp activateIgnoringOtherApps:YES];[window makeKeyAndOrderFront:nil];}
                s->shown=1;break;
            case 1:[window orderOut:nil];break;
            case 2:[window miniaturize:nil];break;
            case 3:if(![window isZoomed])[window zoom:nil];break;
            case 4:if([window isMiniaturized])[window deminiaturize:nil];else if([window isZoomed])[window zoom:nil];break;
            case 5:
                if(s->popup&&!(s->popup&POPUP_FOCUSABLE)){[window orderFront:nil];break;}
                [NSApp activateIgnoringOtherApps:YES];[window makeKeyAndOrderFront:nil];[window makeFirstResponder:s->view];s->shown=1;break;
            case 6:s->enabled=1;break;
            case 7:s->enabled=0;break;
            default:break;
        }
    }
    if(!s->destroyed)notify_state(s);
}
uint32_t zlm_window_state(NativeWindow *s){
    NSWindow *window=s->window;
    const int fullscreen=([window styleMask]&NSWindowStyleMaskFullScreen)!=0,topmost=[window level]>NSNormalWindowLevel;
    return ([window isVisible]?1u:0u)|([window isMiniaturized]?2u:0u)|(!fullscreen&&[window isZoomed]?4u:0u)|([window isKeyWindow]?8u:0u)|(s->enabled?16u:0u)|
        (fullscreen?32u:0u)|(s->fullscreen_requested?64u:0u)|(topmost?128u:0u)|(s->topmost_requested?256u:0u);
}
uint32_t zlm_window_capabilities(NativeWindow *s){(void)s;return 1u|2u|4u|8u|16u|64u|128u|256u|1024u|2048u;}
static double primary_height(void){NSArray<NSScreen *> *screens=[NSScreen screens];return [screens count]?[[screens objectAtIndex:0] frame].size.height:0;}
void zlm_window_bounds(NativeWindow *s,NativeBounds *out){
    NSRect content=[s->window contentRectForFrameRect:[s->window frame]];
    *out=(NativeBounds){(int32_t)lround(content.origin.x),(int32_t)lround(primary_height()-(content.origin.y+content.size.height)),(uint32_t)fmax(0,lround(content.size.width)),(uint32_t)fmax(0,lround(content.size.height)),1};
}
void zlm_window_size(NativeWindow *s,uint32_t *width,uint32_t *height,uint32_t *scale){
    NativeEvent event={0};size_event(s,&event);*width=event.width;*height=event.height;*scale=event.scale;
}
int zlm_window_set_bounds(NativeWindow *s,const NativeBounds *bounds){
    if([s->window styleMask]&NSWindowStyleMaskFullScreen)return 3;
    @autoreleasepool{
        NSRect content=[s->window contentRectForFrameRect:[s->window frame]];
        if(bounds->positioned){content.origin.x=bounds->x;content.origin.y=primary_height()-bounds->y-(double)bounds->height;}
        else content.origin.y+=content.size.height-(double)bounds->height;
        content.size=NSMakeSize(bounds->width,bounds->height);
        [s->window setFrame:[s->window frameRectForContentRect:content] display:YES];
    }
    return 0;
}
int zlm_window_fullscreen(NativeWindow *s,int enabled){
    if(s->popup)return 1;
    s->fullscreen_requested=enabled;
    const int current=([s->window styleMask]&NSWindowStyleMaskFullScreen)!=0;
    if(current!=!!enabled)@autoreleasepool{[s->window toggleFullScreen:nil];}
    return 0;
}
int zlm_window_topmost(NativeWindow *s,int enabled){
    s->topmost_requested=enabled;
    if(!s->popup)[s->window setLevel:enabled?NSFloatingWindowLevel:NSNormalWindowLevel];
    notify_state(s);return 0;
}
void zlm_window_title(NativeWindow *s,const char *title){@autoreleasepool{[s->window setTitle:[NSString stringWithUTF8String:title]?:@""];}}
void zlm_window_resize(NativeWindow *s,uint32_t width,uint32_t height){@autoreleasepool{[s->window setContentSize:NSMakeSize(width,height)];}}
void zlm_window_invalidate(NativeWindow *s){[s->view setNeedsDisplay:YES];}
void zlm_window_invalidate_rect(NativeWindow *s,int left,int top,int right,int bottom){[s->view setNeedsDisplayInRect:NSMakeRect(left,top,right-left,bottom-top)];}
void zlm_window_caret(NativeWindow *s,int x,int y,int width,int height){s->caret=NSMakeRect(x,y,width,height);}
void zlm_window_cancel_composition(NativeWindow *s){
    @autoreleasepool{
        if([s->marked length]){[[s->view inputContext] discardMarkedText];[s->marked setString:@""];NativeEvent cancel={0};cancel.kind=14;emit(s,&cancel);}
    }
}
/* Moves or resizes from the press being delivered: -1 moves, 8 is the
   window menu, which macOS does not have. Edges resize natively. */
int zlm_window_interaction(NativeWindow *s,int edge){
    if(edge!=-1)return 1;
    if(!s->gesture)return 4;
    @autoreleasepool{[s->window performWindowDragWithEvent:s->gesture];}
    s->gesture=nil;return s->destroyed?2:0;
}
void zlm_window_text_mode(NativeWindow *s,int keyboard){zlm_window_cancel_composition(s);s->keyboard=keyboard;}

/* Test hooks: drive a window as AppKit would, without a user at the screen. */
uint32_t zlm_resource_count(void){return atomic_load(&live_windows);}
void zlm_test_paint(NativeWindow *s){
    @autoreleasepool{
        NSBitmapImageRep *bitmap=[s->view bitmapImageRepForCachingDisplayInRect:[s->view bounds]];
        if(bitmap)[s->view cacheDisplayInRect:[s->view bounds] toBitmapImageRep:bitmap];
    }
}
void zlm_test_close(NativeWindow *s){@autoreleasepool{[s->delegate windowShouldClose:s->window];}}
void zlm_test_commit(NativeWindow *s,const char *text){@autoreleasepool{[s->view insertText:[NSString stringWithUTF8String:text] replacementRange:NSMakeRange(NSNotFound,0)];}}
void zlm_test_compose(NativeWindow *s,const char *text,size_t caret){@autoreleasepool{[s->view setMarkedText:[NSString stringWithUTF8String:text] selectedRange:NSMakeRange(caret,0) replacementRange:NSMakeRange(NSNotFound,0)];}}
int zlm_test_title_is(NativeWindow *s,const char *title){@autoreleasepool{return [[s->window title] isEqualToString:[NSString stringWithUTF8String:title]];}}
/* The client cursor, by the order of core.Cursor. macOS has no public
   diagonal resize cursors before macOS 15, so those keep the arrow. */
void zlm_window_cursor(NativeWindow *s,int cursor){
    if(s->destroyed)return;
    @autoreleasepool{
        NSCursor *value=nil;
        switch(cursor){
            case 1:value=[NSCursor pointingHandCursor];break;
            case 2:value=[NSCursor IBeamCursor];break;
            case 3:case 10:value=[NSCursor openHandCursor];break;
            case 4:case 13:case 15:case 16:value=[NSCursor resizeLeftRightCursor];break;
            case 5:case 12:case 14:case 17:value=[NSCursor resizeUpDownCursor];break;
            case 8:value=[NSCursor operationNotAllowedCursor];break;
            case 9:value=[NSCursor crosshairCursor];break;
            case 11:value=[NSCursor closedHandCursor];break;
            case 18:value=[NSCursor IBeamCursorForVerticalLayout];break;
            case 19:value=[NSCursor dragCopyCursor];break;
            case 20:value=[NSCursor dragLinkCursor];break;
            case 21:value=[NSCursor contextualMenuCursor];break;
            case 22:{NSImage *blank=[[[NSImage alloc] initWithSize:NSMakeSize(1,1)] autorelease];value=[[[NSCursor alloc] initWithImage:blank hotSpot:NSZeroPoint] autorelease];break;}
            default:value=nil;break;
        }
        [s->cursor release];s->cursor=[value retain];
        [s->window invalidateCursorRectsForView:s->view];
        NSPoint inside=[s->view convertPoint:[s->window mouseLocationOutsideOfEventStream] fromView:nil];
        if([s->window isKeyWindow]&&NSPointInRect(inside,[s->view bounds]))[(s->cursor?s->cursor:[NSCursor arrowCursor]) set];
    }
}
int zlm_window_traits(NativeWindow *s,int resizable,int movable,int minimizable,int maximizable,int closable){
    if(s->destroyed)return 2;
    @autoreleasepool{
        NSWindow *window=s->window;NSWindowStyleMask style=[window styleMask];
        if(style&NSWindowStyleMaskTitled){
            style=resizable?style|NSWindowStyleMaskResizable:style&~NSWindowStyleMaskResizable;
            style=minimizable?style|NSWindowStyleMaskMiniaturizable:style&~NSWindowStyleMaskMiniaturizable;
            style=closable?style|NSWindowStyleMaskClosable:style&~NSWindowStyleMaskClosable;
            [window setStyleMask:style];
            [[window standardWindowButton:NSWindowZoomButton] setEnabled:maximizable&&resizable];
        }else if(!s->popup)[window setStyleMask:resizable?style|NSWindowStyleMaskResizable:style&~NSWindowStyleMaskResizable];
        [window setMovable:movable];
        if(!s->popup)[window setCollectionBehavior:maximizable?NSWindowCollectionBehaviorFullScreenPrimary:NSWindowCollectionBehaviorFullScreenNone];
    }
    return 0;
}
void zlm_window_opacity(NativeWindow *s,float value){[s->window setAlphaValue:value];}
void zlm_window_ignore_pointer(NativeWindow *s,int enabled){[s->window setIgnoresMouseEvents:enabled];}
void zlm_window_content_protection(NativeWindow *s,int enabled){[s->window setSharingType:enabled?NSWindowSharingNone:NSWindowSharingReadOnly];}
/* Bounces the Dock icon until the app is active; a request per window
   would need the window to own it, which macOS does not offer. */
static NSInteger attention_request=0;
void zlm_window_attention(NativeWindow *s,int enabled){
    (void)s;
    if(attention_request){[NSApp cancelUserAttentionRequest:attention_request];attention_request=0;}
    if(enabled&&![NSApp isActive])attention_request=[NSApp requestUserAttention:NSInformationalRequest];
}
