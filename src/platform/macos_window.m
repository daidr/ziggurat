/* Window chrome of the AppKit adapter that macos.m calls into: the material
   behind the content (NSVisualEffectView, or macOS 26's NSGlassEffectView),
   rounded frameless windows, the active look, the system's title bar
   double-click action, and moving a window with the press of a drag region.
   Main thread only. Compiled without ARC. */
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>

/* NSGlassEffectView is macOS 26's; it is looked up by name so that older
   SDKs build and older systems fall back to a visual effect material. */
@interface NSView (ZigguratGlass)
- (void)setStyle:(NSInteger)style;
- (void)setCornerRadius:(CGFloat)radius;
@end
@interface NSWindow (ZigguratActive)
- (void)_setForceMainAppearance:(BOOL)force;
@end

static Class glass_class(void){return NSClassFromString(@"NSGlassEffectView");}

/* Cuts the material to the container's corners. The glass draws its rim
   along its own corners, which it rounds itself. */
static void round_effect(NSView *effect,int glass,double radius){
    if(!effect||radius<=0)return;
    if(glass){if([effect respondsToSelector:@selector(setCornerRadius:)])[effect setCornerRadius:radius];return;}
    [effect setWantsLayer:YES];
    CALayer *layer=[effect layer];
    [layer setCornerRadius:radius];
    if(@available(macOS 10.15,*))[layer setCornerCurve:kCACornerCurveContinuous];
    [layer setMasksToBounds:YES];
}

/* Puts material `material` (an NSVisualEffectMaterial) behind `content` in
   `container`, or glass of style `glass_style` (0 regular, 1 clear) where
   macOS has it, `material` being its stand-in elsewhere; a negative
   material removes it. Returns the material's view, retained, which
   replaces `effect`; *glass tells whether it is glass. */
NSView *zlmw_set_material(NSView *container,NSView *content,NSView *effect,int *glass,double radius,int material,int glass_style){
    const int wants_glass=glass_style>=0&&glass_class()!=nil;
    if(material<0&&!wants_glass){
        if(effect){[effect removeFromSuperview];[effect release];}
        *glass=0;return nil;
    }
    if(effect&&*glass!=wants_glass){[effect removeFromSuperview];[effect release];effect=nil;}
    if(!effect){
        Class kind=wants_glass?glass_class():[NSVisualEffectView class];
        effect=[[kind alloc] initWithFrame:[container bounds]];
        if(!effect){*glass=0;return nil;}
        if(!wants_glass){
            NSVisualEffectView *visual=(NSVisualEffectView *)effect;
            [visual setBlendingMode:NSVisualEffectBlendingModeBehindWindow];
            [visual setState:NSVisualEffectStateActive];
        }
        [effect setAutoresizingMask:NSViewWidthSizable|NSViewHeightSizable];
        [container addSubview:effect positioned:NSWindowBelow relativeTo:content];
        *glass=wants_glass;
        round_effect(effect,wants_glass,radius);
    }
    if(wants_glass){if([effect respondsToSelector:@selector(setStyle:)])[effect setStyle:glass_style];}
    else [(NSVisualEffectView *)effect setMaterial:(NSVisualEffectMaterial)material];
    return effect;
}

/* Cuts the container, and the material in it, to corners of `radius`. The
   window is made clear, so that nothing fills the corners, and its shadow,
   made from what it draws, follows them. */
void zlmw_round(NSWindow *window,NSView *container,NSView *effect,int glass,double radius){
    if(radius<=0)return;
    [container setWantsLayer:YES];
    CALayer *layer=[container layer];
    [layer setCornerRadius:radius];
    if(@available(macOS 10.15,*))[layer setCornerCurve:kCACornerCurveContinuous];
    [layer setMasksToBounds:YES];
    [window setOpaque:NO];
    [window setBackgroundColor:[NSColor clearColor]];
    round_effect(effect,glass,radius);
    [window invalidateShadow];
}

/* Draws the window as the main window of the app in front, whichever is,
   through AppKit's own _setForceMainAppearance:: without it a window that
   is not draws its glass frosted, the clear style too, as a panel over
   another app always is. NSVisualEffectView keeps its active state by
   itself (zlmw_set_material); NSGlassEffectView has no such setting. */
void zlmw_active_appearance(NSWindow *window,int enabled){
    if([window respondsToSelector:@selector(_setForceMainAppearance:)])[window _setForceMainAppearance:enabled?YES:NO];
}
int zlmw_test_material(NSView *effect,int glass,int *style,double *radius){
    if(!effect)return -1;
    if(glass){*style=(int)[[effect valueForKey:@"style"] integerValue];*radius=[[effect valueForKey:@"cornerRadius"] doubleValue];return 1;}
    *style=(int)[(NSVisualEffectView *)effect material];*radius=[effect layer]?[[effect layer] cornerRadius]:0;return 0;
}

/* What a double click on a title bar does, as the user set it in System
   Settings: 0 zooms, 1 minimizes, 2 does nothing. */
int zlmw_double_click_action(void){
    NSUserDefaults *defaults=[NSUserDefaults standardUserDefaults];
    NSString *action=[defaults stringForKey:@"AppleActionOnDoubleClick"];
    if([action isEqualToString:@"None"])return 2;
    if([action isEqualToString:@"Minimize"])return 1;
    if(!action&&[defaults boolForKey:@"AppleMiniaturizeOnDoubleClick"])return 1;
    return 0;
}

/* Drag regions move the window with a press: a caption hit or startMove
   while the press is delivered.

   The window server moves the window best (performWindowDragWithEvent:):
   it takes the window to other Spaces and tiles it. But it may not begin
   when the pointer has moved since the press by the time it is asked;
   AppKit logs "Window move completed without beginning" and the window
   stays where it was, which a quick press and drag hits now and then. So
   the press is watched. When the pointer has not moved yet, the window
   server is asked; when it has, or when the press's drags still reach the
   app past a few points and the window server has not begun, the window is
   moved here, keeping the point pressed under the pointer, as the window
   server would. Either way the press's drags are the window's, not the
   content's.

   The window server tells the window as it begins (windowWillMove:),
   within a drag or two of being asked. The window's frame says so late:
   AppKit learns where the window is about every tenth of a second while
   the window server moves it. Should a frame that has not moved be taken
   for a window server that did not begin, both would move the window and
   it would shake; for a window server that still begins once the window is
   moved here, the window not being where it was put says to leave it
   alone. Points are in the display space of Core Graphics (top-left origin
   of the primary display, y down), where events keep their place when the
   window moves; window origins are AppKit's (bottom-left, y up). */
enum {DRAG_IDLE,DRAG_PRESSED,DRAG_NATIVE,DRAG_MANUAL,DRAG_SERVER};
/* How far the pointer may have gone when the drag is asked for the window
   server to be asked (a hand on a touchpad trembles); how far it may go,
   the window not moving, before the window is moved here; how far the
   window may be from where it was put, which AppKit rounds, before the
   window server is taken to move it. */
static const double drag_still=1,drag_slop=3,drag_away=2;
static struct {int phase;NSWindow *window;NSPoint press,at,origin,put;} drag;
static id drag_monitor;

static double distance(NSPoint a,NSPoint b){return hypot(a.x-b.x,a.y-b.y);}
static NSPoint event_point(NSEvent *event){
    CGEventRef cg=[event CGEvent];
    if(cg)return NSPointFromCGPoint(CGEventGetLocation(cg));
    NSPoint p=[NSEvent mouseLocation];NSArray<NSScreen *> *screens=[NSScreen screens];
    return NSMakePoint(p.x,([screens count]?[[screens objectAtIndex:0] frame].size.height:0)-p.y);
}
/* The window's origin that keeps the pressed point under the pointer,
   with its top kept below the menu bar of the screen with the pointer, as
   AppKit keeps a title bar out of it. */
static void move_dragged(void){
    NSPoint origin=NSMakePoint(drag.origin.x+drag.at.x-drag.press.x,drag.origin.y-(drag.at.y-drag.press.y));
    NSArray<NSScreen *> *screens=[NSScreen screens];
    if([screens count]){
        NSRect primary=[[screens objectAtIndex:0] frame];
        NSPoint p=NSMakePoint(drag.at.x,primary.origin.y+primary.size.height-drag.at.y);
        for(NSScreen *screen in screens){
            if(!NSPointInRect(p,[screen frame]))continue;
            NSRect visible=[screen visibleFrame];const double height=[drag.window frame].size.height;
            if(origin.y+height>NSMaxY(visible))origin.y=NSMaxY(visible)-height;
            break;
        }
    }
    drag.put=origin;
    [drag.window setFrameOrigin:origin];
}
static void drag_reset(void){drag.phase=DRAG_IDLE;drag.window=nil;}
/* Notes the pointer at `at` with the button down: whether the drag is the
   window's move rather than the content's, moving the window when it is
   moved here. */
static int dragged(NSPoint at){
    const NSPoint origin=[drag.window frame].origin;
    drag.at=at;
    switch(drag.phase){
        case DRAG_PRESSED:return 0;
        case DRAG_NATIVE:
            if(!NSEqualPoints(origin,drag.origin)){drag.phase=DRAG_SERVER;return 1;}
            /* The pointer has hardly moved yet. */
            if(distance(at,drag.press)<drag_slop)return 1;
            drag.phase=DRAG_MANUAL;move_dragged();return 1;
        case DRAG_MANUAL:
            /* The window server began after all. */
            if(distance(origin,drag.put)>drag_away){drag.phase=DRAG_SERVER;return 1;}
            move_dragged();return 1;
        default:return 1;
    }
}
/* Sees the drags and the release of a press before the window does. */
static void watch_drags(void){
    if(drag_monitor)return;
    drag_monitor=[[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown|NSEventMaskLeftMouseUp|NSEventMaskLeftMouseDragged handler:^NSEvent *(NSEvent *event){
        if(drag.phase==DRAG_IDLE)return event;
        /* A release, or a press the window has yet to see, which notes
           itself if it may drag. */
        if([event type]!=NSEventTypeLeftMouseDragged){drag_reset();return event;}
        if([event window]!=drag.window)return event;
        return dragged(event_point(event))?nil:event;
    }] retain];
}
/* Notes a press of the left button in the window, which a drag region may
   ask to move it with. */
void zlmw_drag_pressed(NSWindow *window,NSEvent *event){
    watch_drags();
    drag.phase=DRAG_PRESSED;drag.window=window;drag.press=drag.at=event_point(event);
}
/* Moves the window with its press, once: 0 asked the window server, 1 moves
   it here, 2 found no press of the window down. */
int zlmw_drag_start(NSWindow *window,NSEvent *press){
    if(drag.phase!=DRAG_PRESSED||drag.window!=window)return 2;
    if([window styleMask]&NSWindowStyleMaskFullScreen)return 2;
    drag.origin=[window frame].origin;
    if(distance(drag.at,drag.press)>=drag_still){drag.phase=DRAG_MANUAL;move_dragged();return 1;}
    drag.phase=DRAG_NATIVE;
    [window performWindowDragWithEvent:press];
    return 0;
}
void zlmw_drag_will_move(NSWindow *window){if(drag.phase==DRAG_NATIVE&&drag.window==window)drag.phase=DRAG_SERVER;}
void zlmw_drag_forget(NSWindow *window){if(drag.window==window)drag_reset();}
/* Test hooks: where the press stands, and a drag of the pointer to the
   display point (x, y) as the monitor sees it. */
int zlmw_test_drag_phase(void){return drag.phase;}
void zlmw_test_drag_press(double *x,double *y){*x=drag.press.x;*y=drag.press.y;}
void zlmw_test_drag_to(double x,double y){if(drag.phase!=DRAG_IDLE&&drag.window)(void)dragged(NSMakePoint(x,y));}
