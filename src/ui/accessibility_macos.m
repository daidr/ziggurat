/* The semantic tree as NSAccessibility elements, which VoiceOver and other
   assistive technology read: one element per node, contained by the
   window's content view. Elements are kept from publication to publication
   by node ID, so VoiceOver's cursor stays on them, and only what changed is
   set again. Frames are in the content view's points and turned into screen
   coordinates as they are asked for, so moving the window needs nothing.
   Everything runs on the main thread, which owns the App. Compiled with ARC;
   the C handles are bridged retains. */
#import <AppKit/AppKit.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

/* accessibility.zig `Role`. */
enum {
    ROLE_WINDOW, ROLE_GROUP, ROLE_BUTTON, ROLE_TEXT, ROLE_TEXT_BOX, ROLE_CHECKBOX, ROLE_RADIO, ROLE_SWITCH, ROLE_PROGRESS,
    ROLE_RADIO_GROUP, ROLE_SLIDER, ROLE_STEPPER, ROLE_LIST, ROLE_TAB_LIST, ROLE_TAB, ROLE_TOOLBAR, ROLE_SPLITTER, ROLE_LINK,
    ROLE_DISCLOSURE, ROLE_METER, ROLE_NAVIGATION, ROLE_LIST_BOX, ROLE_LIST_ITEM, ROLE_COMBO_BOX, ROLE_TOOLTIP, ROLE_STATUS,
    ROLE_SEARCH, ROLE_IMAGE, ROLE_TREE, ROLE_TREE_ITEM, ROLE_TABLE, ROLE_TABLE_HEADER, ROLE_COLUMN_HEADER, ROLE_TABLE_ROW,
    ROLE_TOKEN_FIELD, ROLE_TOKEN, ROLE_POPUP, ROLE_CALENDAR, ROLE_COLOR_WELL, ROLE_DIALOG, ROLE_ALERT_DIALOG, ROLE_MENU,
    ROLE_MENU_ITEM, ROLE_MENU_ITEM_CHECKBOX, ROLE_MENU_ITEM_RADIO, ROLE_COUNT
};
/* NativeNode flags, as accessibility.zig packs them. */
enum {
    ENABLED = 1, FOCUSED = 2, READ_ONLY = 4, OFFSCREEN = 8, CHECKED = 16, INVALID = 32, REQUIRED = 64, MULTIPLE = 128,
    EXPANDABLE = 256, EXPANDED = 512, MIXED = 1024, PASSWORD = 2048
};
/* NativeAction kinds. */
enum { ACTION_INVOKE = 1, ACTION_FOCUS = 2, ACTION_SET_VALUE = 3, ACTION_SELECT_TEXT = 4, ACTION_SET_RANGE = 5 };

typedef struct NativeNode {
    uint64_t id, parent;
    uint32_t role, flags, name_start, name_len, value_start, value_len, selection_start, selection_end, description_start, description_len;
    double x, y, width, height, range_value, range_minimum, range_maximum, range_small_change, range_large_change;
} NativeNode;
typedef struct RecipientAuthority { uint64_t epoch, serial, id, publication; uint32_t slot, kind; } RecipientAuthority;
typedef struct ActionView {
    void *context;
    uint32_t kind;
    uint64_t id;
    const uint16_t *value;
    uint32_t value_len, start, end;
    double number;
    RecipientAuthority recipient;
} ActionView;
_Static_assert(sizeof(ActionView) == 96, "captured native action ABI");
typedef int (*ZuaEnqueue)(void *context, void *action);

static unsigned live_hosts, live_elements, live_actions;

@class ZuaHost;

/* The accessibility of the content view: the informal protocol ZigView
   forwards its own accessibility to (platform/macos.m). */
@protocol ZuaViewAccessibility <NSObject>
- (NSArray *)zigAccessibilityChildren;
- (id)zigAccessibilityHitTest:(NSPoint)point;
- (id)zigAccessibilityFocusedElement;
@end
@interface NSView (ZuaHosting)
- (void)setZigAccessibility:(id)provider;
@end

static BOOL ranged(uint32_t role) { return role == ROLE_PROGRESS || role == ROLE_SLIDER || role == ROLE_STEPPER || role == ROLE_METER || role == ROLE_SPLITTER; }
static BOOL fixed_range(uint32_t role) { return role == ROLE_PROGRESS || role == ROLE_METER; }
static BOOL toggle(uint32_t role) { return role == ROLE_CHECKBOX || role == ROLE_RADIO || role == ROLE_SWITCH || role == ROLE_TAB || role == ROLE_MENU_ITEM_CHECKBOX || role == ROLE_MENU_ITEM_RADIO; }
static BOOL textual(uint32_t role) { return role == ROLE_TEXT_BOX || role == ROLE_COMBO_BOX || role == ROLE_TOKEN_FIELD; }
static BOOL menu_item(uint32_t role) { return role == ROLE_MENU_ITEM || role == ROLE_MENU_ITEM_CHECKBOX || role == ROLE_MENU_ITEM_RADIO; }
static BOOL item(uint32_t role) { return role == ROLE_RADIO || role == ROLE_TAB || role == ROLE_LIST_ITEM || role == ROLE_TREE_ITEM || role == ROLE_TABLE_ROW; }
static BOOL row(uint32_t role) { return role == ROLE_LIST_ITEM || role == ROLE_TREE_ITEM || role == ROLE_TABLE_ROW; }
static BOOL rows_container(uint32_t role) { return role == ROLE_LIST || role == ROLE_LIST_BOX || role == ROLE_TREE || role == ROLE_TABLE; }
/* Roles whose activation is a press, as UI Automation's Invoke, Toggle,
   SelectionItem and ExpandCollapse are on Windows. */
static BOOL pressable(uint32_t role) {
    return role == ROLE_BUTTON || role == ROLE_LINK || role == ROLE_COLUMN_HEADER || role == ROLE_COLOR_WELL || menu_item(role) ||
        item(role) || toggle(role) || role == ROLE_DISCLOSURE || role == ROLE_COMBO_BOX;
}
static BOOL focusable(uint32_t role) {
    return pressable(role) || role == ROLE_TOKEN || role == ROLE_TEXT_BOX || role == ROLE_SLIDER || role == ROLE_STEPPER ||
        role == ROLE_SPLITTER || role == ROLE_LIST || role == ROLE_CALENDAR || role == ROLE_TOKEN_FIELD;
}
/* Controls show their name, which AppKit's own give as their title; other
   elements are described by it. */
static BOOL titled(uint32_t role) {
    return role == ROLE_BUTTON || role == ROLE_LINK || role == ROLE_CHECKBOX || role == ROLE_RADIO || role == ROLE_SWITCH ||
        role == ROLE_TAB || role == ROLE_DISCLOSURE || menu_item(role) || role == ROLE_TOKEN;
}

static NSAccessibilityRole role_of(const NativeNode *n, NSAccessibilitySubrole *subrole) {
    *subrole = nil;
    switch (n->role) {
    case ROLE_BUTTON: case ROLE_TOKEN: return NSAccessibilityButtonRole;
    case ROLE_TEXT: return NSAccessibilityStaticTextRole;
    case ROLE_TEXT_BOX: case ROLE_TOKEN_FIELD:
        if (n->flags & PASSWORD) *subrole = NSAccessibilitySecureTextFieldSubrole;
        return NSAccessibilityTextFieldRole;
    case ROLE_CHECKBOX: return NSAccessibilityCheckBoxRole;
    case ROLE_RADIO: return NSAccessibilityRadioButtonRole;
    case ROLE_SWITCH: *subrole = NSAccessibilitySwitchSubrole; return NSAccessibilityCheckBoxRole;
    case ROLE_PROGRESS: return NSAccessibilityProgressIndicatorRole;
    case ROLE_RADIO_GROUP: return NSAccessibilityRadioGroupRole;
    case ROLE_SLIDER: return NSAccessibilitySliderRole;
    case ROLE_STEPPER: return NSAccessibilityIncrementorRole;
    /* Lists are tables of rows, as AppKit's own lists. */
    case ROLE_LIST: case ROLE_LIST_BOX: case ROLE_TABLE: return NSAccessibilityTableRole;
    case ROLE_TAB_LIST: return NSAccessibilityTabGroupRole;
    case ROLE_TAB: *subrole = NSAccessibilityTabButtonSubrole; return NSAccessibilityRadioButtonRole;
    case ROLE_TOOLBAR: return NSAccessibilityToolbarRole;
    case ROLE_SPLITTER: return NSAccessibilitySplitterRole;
    case ROLE_LINK: return NSAccessibilityLinkRole;
    case ROLE_DISCLOSURE: return NSAccessibilityDisclosureTriangleRole;
    case ROLE_METER: return NSAccessibilityLevelIndicatorRole;
    case ROLE_NAVIGATION: *subrole = @"AXLandmarkNavigation"; return NSAccessibilityGroupRole;
    case ROLE_LIST_ITEM: case ROLE_TABLE_ROW: *subrole = NSAccessibilityTableRowSubrole; return NSAccessibilityRowRole;
    case ROLE_COMBO_BOX: return NSAccessibilityComboBoxRole;
    case ROLE_TOOLTIP: return NSAccessibilityHelpTagRole;
    case ROLE_STATUS: *subrole = @"AXApplicationStatus"; return NSAccessibilityGroupRole;
    case ROLE_SEARCH: *subrole = @"AXLandmarkSearch"; return NSAccessibilityGroupRole;
    case ROLE_IMAGE: return NSAccessibilityImageRole;
    case ROLE_TREE: return NSAccessibilityOutlineRole;
    case ROLE_TREE_ITEM: *subrole = NSAccessibilityOutlineRowSubrole; return NSAccessibilityRowRole;
    case ROLE_COLUMN_HEADER: return NSAccessibilityCellRole;
    case ROLE_POPUP: return NSAccessibilityPopoverRole;
    case ROLE_COLOR_WELL: return NSAccessibilityColorWellRole;
    case ROLE_DIALOG: *subrole = NSAccessibilityDialogSubrole; return NSAccessibilityGroupRole;
    case ROLE_ALERT_DIALOG: *subrole = @"AXApplicationAlertDialog"; return NSAccessibilityGroupRole;
    case ROLE_MENU: return NSAccessibilityMenuRole;
    case ROLE_MENU_ITEM: case ROLE_MENU_ITEM_CHECKBOX: case ROLE_MENU_ITEM_RADIO: return NSAccessibilityMenuItemRole;
    default: return NSAccessibilityGroupRole;
    }
}

/* The text of a value AppKit sets: a string, an attributed string's text,
   or the text of an NSNumber, which VoiceOver may set as a text field's
   AXValue; anything else is empty. */
static NSString *zua_string_of(id value) {
    if (value == nil) return @"";
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSAttributedString class]]) return [value string];
    if ([value respondsToSelector:@selector(stringValue)]) {
        id text = [value stringValue];
        if ([text isKindOfClass:[NSString class]]) return text;
    }
    return @"";
}

/* A node's value as AppKit wants it: a number for toggles, disclosures
   and ranges, a string for texts. */
static id value_of(const NativeNode *n, NSString *name, NSString *value) {
    /* 1 while open, as AppKit's disclosure triangles. */
    if (n->role == ROLE_DISCLOSURE) return @((n->flags & (EXPANDED | CHECKED)) ? 1 : 0);
    if (toggle(n->role)) return @((n->flags & MIXED) ? 2 : (n->flags & CHECKED) ? 1 : 0);
    if (ranged(n->role)) {
        /* A progress of unknown length has no value. */
        if (n->role == ROLE_PROGRESS && n->range_minimum == n->range_maximum) return nil;
        return @(n->range_value);
    }
    if (n->role == ROLE_TEXT) return name;
    if (n->flags & PASSWORD) return @"";
    if (value.length > 0 || textual(n->role)) return value;
    return nil;
}

@interface ZuaElement : NSAccessibilityElement
@end

@interface ZuaHost : NSObject <ZuaViewAccessibility> {
@public
    NSWindow *__weak window;
    NSView *__weak view;
    ZuaEnqueue enqueue;
    void *context;
    BOOL closed;
    NSMutableDictionary<NSNumber *, ZuaElement *> *elements;
    NSArray *top;
    /* The elements in the order of their nodes: deeper or above later. */
    NSArray<ZuaElement *> *order;
    uint64_t focus;
    BOOL has_focus;
    /* Whether actions are refused, as while a publication sets elements. */
    BOOL updating;
}
- (BOOL)request:(ZuaElement *)element kind:(uint32_t)kind value:(NSString *)value start:(uint32_t)start end:(uint32_t)end number:(double)number;
@end

@interface ZuaElement () {
@public
    ZuaHost *__weak host;
    NativeNode node;
    NSString *name, *value, *text;
    RecipientAuthority recipient;
    NSArray<NSNumber *> *child_ids;
    id parent;
    BOOL fresh;
}
@end

/* An action an element asks for, until the App's thread has taken it. */
typedef struct Action {
    void *host; /* ZuaHost, bridged retain */
    uint32_t kind;
    uint64_t id;
    uint16_t *value;
    uint32_t value_len, start, end;
    double number;
    RecipientAuthority recipient;
} Action;

@implementation ZuaHost
- (instancetype)init {
    if ((self = [super init])) { elements = [NSMutableDictionary dictionary]; top = @[]; order = @[]; live_hosts++; }
    return self;
}
- (void)dealloc { live_hosts--; }
- (ZuaElement *)element:(uint64_t)identifier { return elements[@(identifier)]; }
- (NSArray *)zigAccessibilityChildren { return closed ? @[] : top; }
- (id)zigAccessibilityFocusedElement {
    if (closed || !has_focus) return nil;
    return [self element:focus];
}
/* The innermost element at a point of the screen: later nodes are deeper
   or drawn above. */
- (id)zigAccessibilityHitTest:(NSPoint)point {
    NSWindow *w = window;
    NSView *v = view;
    if (closed || !w || !v) return nil;
    NSPoint local = [v convertPoint:[w convertPointFromScreen:point] fromView:nil];
    id found = nil;
    for (ZuaElement *element in order) {
        const NativeNode *n = &element->node;
        if (local.x >= n->x && local.y >= n->y && local.x < n->x + n->width && local.y < n->y + n->height) found = element;
    }
    return found;
}
/* The view's rectangle `r` on the screen. */
- (NSRect)screenRect:(NSRect)r {
    NSWindow *w = window;
    NSView *v = view;
    if (closed || !w || !v) return NSZeroRect;
    return [w convertRectToScreen:[v convertRect:r toView:nil]];
}
- (BOOL)request:(ZuaElement *)element kind:(uint32_t)kind value:(NSString *)text start:(uint32_t)start end:(uint32_t)end number:(double)number {
    if (closed || updating || !context || !enqueue) return NO;
    const NativeNode *n = &element->node;
    if (!(n->flags & ENABLED)) return NO;
    if ((kind == ACTION_INVOKE && !pressable(n->role)) || (kind == ACTION_FOCUS && !focusable(n->role)) ||
        ((kind == ACTION_SET_VALUE || kind == ACTION_SELECT_TEXT) && !textual(n->role)) || (kind == ACTION_SET_RANGE && !ranged(n->role) && n->role != ROLE_TREE_ITEM && n->role != ROLE_TABLE_ROW))
        return NO;
    if (kind == ACTION_SET_VALUE && (n->flags & READ_ONLY)) return NO;
    if (kind == ACTION_SET_RANGE && ranged(n->role)) {
        if (fixed_range(n->role) || (n->flags & READ_ONLY) || !isfinite(number)) return NO;
        if (number < n->range_minimum) number = n->range_minimum;
        if (number > n->range_maximum) number = n->range_maximum;
    }
    Action *a = calloc(1, sizeof(Action));
    if (!a) return NO;
    if (kind == ACTION_SET_VALUE) {
        NSUInteger length = text.length;
        a->value = malloc((length ? length : 1) * sizeof(uint16_t));
        if (!a->value) { free(a); return NO; }
        [text getCharacters:(unichar *)a->value range:NSMakeRange(0, length)];
        a->value_len = (uint32_t)length;
    }
    a->host = (__bridge_retained void *)self;
    a->kind = kind; a->id = n->id; a->start = start; a->end = end; a->number = number;
    a->recipient = element->recipient;
    live_actions++;
    if (!enqueue(context, a)) {
        CFRelease(a->host); free(a->value); free(a); live_actions--;
        return NO;
    }
    return YES;
}
@end

@implementation ZuaElement
- (void)dealloc { live_elements--; }
- (NSRect)accessibilityFrame {
    ZuaHost *h = host;
    return h ? [h screenRect:NSMakeRect(node.x, node.y, node.width, node.height)] : NSZeroRect;
}
- (id)accessibilityParent {
    ZuaHost *h = host;
    return h && !h->closed ? parent : nil;
}
- (BOOL)isAccessibilityFocused {
    ZuaHost *h = host;
    return h && h->has_focus && h->focus == node.id;
}
- (BOOL)isAccessibilityElement { return YES; }
- (BOOL)isAccessibilitySelectorAllowed:(SEL)selector {
    if (selector == @selector(accessibilityPerformPress)) return pressable(node.role);
    if (selector == @selector(accessibilityPerformIncrement) || selector == @selector(accessibilityPerformDecrement)) return ranged(node.role) && !fixed_range(node.role);
    if (selector == @selector(setAccessibilityValue:)) return (textual(node.role) && !(node.flags & READ_ONLY)) || (ranged(node.role) && !fixed_range(node.role));
    if (selector == @selector(setAccessibilitySelectedText:)) return textual(node.role) && !(node.flags & READ_ONLY);
    if (selector == @selector(setAccessibilitySelectedTextRange:)) return textual(node.role);
    if (selector == @selector(setAccessibilityFocused:)) return focusable(node.role);
    if (selector == @selector(setAccessibilityDisclosed:)) return node.role == ROLE_TREE_ITEM && (node.flags & EXPANDABLE);
    return [super isAccessibilitySelectorAllowed:selector];
}
/* AXInvalid, which the newer API lacks, says a value is not valid, and
   AXMenuItemMarkChar what an item of a menu shows of its choice. */
- (NSArray *)accessibilityAttributeNames {
    NSArray *names = [super accessibilityAttributeNames];
    if (node.flags & INVALID) names = [names arrayByAddingObject:@"AXInvalid"];
    if (menu_item(node.role)) names = [names arrayByAddingObject:@"AXMenuItemMarkChar"];
    return names;
}
- (id)accessibilityAttributeValue:(NSAccessibilityAttributeName)attribute {
    if ([attribute isEqualToString:@"AXInvalid"]) return (node.flags & INVALID) ? @"true" : nil;
    if ([attribute isEqualToString:@"AXMenuItemMarkChar"]) {
        if (!menu_item(node.role)) return nil;
        return (node.flags & MIXED) ? @"-" : (node.flags & CHECKED) ? @"✓" : nil;
    }
    return [super accessibilityAttributeValue:attribute];
}
/* The older API asks which attributes are settable, which
   NSAccessibilityElement does not answer (asking super throws). */
- (BOOL)accessibilityIsAttributeSettable:(NSAccessibilityAttributeName)attribute {
    if ([attribute isEqualToString:NSAccessibilityValueAttribute]) return (textual(node.role) && !(node.flags & READ_ONLY)) || (ranged(node.role) && !fixed_range(node.role));
    if ([attribute isEqualToString:NSAccessibilitySelectedTextAttribute]) return textual(node.role) && !(node.flags & READ_ONLY);
    if ([attribute isEqualToString:NSAccessibilitySelectedTextRangeAttribute]) return textual(node.role);
    if ([attribute isEqualToString:NSAccessibilityFocusedAttribute]) return focusable(node.role);
    if ([attribute isEqualToString:NSAccessibilityDisclosingAttribute]) return node.role == ROLE_TREE_ITEM && (node.flags & EXPANDABLE);
    return NO;
}
- (BOOL)accessibilityPerformPress {
    ZuaHost *h = host;
    return h && [h request:self kind:ACTION_INVOKE value:nil start:0 end:0 number:0];
}
/* A step of a range: its small change, or a tenth of the range. */
- (double)step {
    double step = node.range_small_change > 0 ? node.range_small_change : (node.range_maximum - node.range_minimum) / 10;
    return step > 0 ? step : 1;
}
- (BOOL)accessibilityPerformIncrement {
    ZuaHost *h = host;
    return h && [h request:self kind:ACTION_SET_RANGE value:nil start:0 end:0 number:node.range_value + [self step]];
}
- (BOOL)accessibilityPerformDecrement {
    ZuaHost *h = host;
    return h && [h request:self kind:ACTION_SET_RANGE value:nil start:0 end:0 number:node.range_value - [self step]];
}
- (void)setAccessibilityFocused:(BOOL)focused {
    ZuaHost *h = host;
    if (h && focused) [h request:self kind:ACTION_FOCUS value:nil start:0 end:0 number:0];
}
/* Opening and closing a row of an outline, as VoiceOver does: a tree
   item's value request (expand 3, collapse 2). */
- (void)setAccessibilityDisclosed:(BOOL)open {
    [super setAccessibilityDisclosed:open];
    ZuaHost *h = host;
    if (h && node.role == ROLE_TREE_ITEM && (node.flags & EXPANDABLE) && ((node.flags & EXPANDED) != 0) != open)
        [h request:self kind:ACTION_SET_RANGE value:nil start:0 end:0 number:open ? 3 : 2];
}
- (void)setAccessibilityValue:(id)newValue {
    [super setAccessibilityValue:newValue];
    ZuaHost *h = host;
    if (!h || h->updating) return;
    if (textual(node.role)) {
        [h request:self kind:ACTION_SET_VALUE value:zua_string_of(newValue) start:0 end:0 number:0];
    } else if (ranged(node.role) && [newValue respondsToSelector:@selector(doubleValue)]) {
        [h request:self kind:ACTION_SET_RANGE value:nil start:0 end:0 number:[newValue doubleValue]];
    }
}
/* Typing over a text field's selection, as Voice Control, dictation and
   automation insert text. */
- (void)setAccessibilitySelectedText:(NSString *)inserted {
    [super setAccessibilitySelectedText:inserted];
    ZuaHost *h = host;
    if (!h || h->updating || !textual(node.role) || (node.flags & READ_ONLY)) return;
    NSString *current = value ?: @"";
    NSUInteger length = current.length;
    NSUInteger a = MIN(node.selection_start, length), b = MIN(MAX(node.selection_end, node.selection_start), length);
    NSString *next = [current stringByReplacingCharactersInRange:NSMakeRange(a, b - a) withString:zua_string_of(inserted)];
    [h request:self kind:ACTION_SET_VALUE value:next start:0 end:0 number:0];
}
/* Moving the selection of a text field, as VoiceOver does. */
- (void)setAccessibilitySelectedTextRange:(NSRange)range {
    [super setAccessibilitySelectedTextRange:range];
    ZuaHost *h = host;
    if (!h || h->updating || !textual(node.role)) return;
    NSUInteger length = (value ?: @"").length;
    NSUInteger a = MIN(range.location, length), b = MIN(a + range.length, length);
    [h request:self kind:ACTION_SELECT_TEXT value:nil start:(uint32_t)a end:(uint32_t)b number:0];
}
/* The text of text fields, for reading by characters and lines. */
- (NSString *)accessibilityStringForRange:(NSRange)range {
    NSString *current = (node.flags & PASSWORD) ? @"" : (value ?: @"");
    NSUInteger a = MIN(range.location, current.length), b = MIN(a + range.length, current.length);
    return [current substringWithRange:NSMakeRange(a, b - a)];
}
- (NSInteger)accessibilityLineForIndex:(NSInteger)index { (void)index; return 0; }
- (NSRange)accessibilityRangeForLine:(NSInteger)line {
    (void)line;
    return NSMakeRange(0, (node.flags & PASSWORD) ? 0 : (value ?: @"").length);
}
- (NSRect)accessibilityFrameForRange:(NSRange)range { (void)range; return [self accessibilityFrame]; }
@end

static NSString *text_at(const uint16_t *text, uint32_t text_len, uint32_t start, uint32_t len) {
    if (start > text_len || len > text_len - start) return @"";
    return [NSString stringWithCharacters:(const unichar *)text + start length:len];
}

/* Sets the properties of an element that changed, all of them for a new
   one, and reports whether its value changed. */
static BOOL apply(ZuaElement *el, const NativeNode *n, NSString *name, NSString *value, NSString *description, const RecipientAuthority *recipient) {
    BOOL fresh = el->fresh;
    NativeNode o = el->node;
    NSString *old_name = el->name, *old_value = el->value;
    el->node = *n; el->name = name; el->value = value;
    el->recipient = recipient ? *recipient : (RecipientAuthority){0};
    el->fresh = NO;
    NSAccessibilitySubrole subrole, old_subrole;
    NSAccessibilityRole role = role_of(n, &subrole), old_role = role_of(&o, &old_subrole);
    if (fresh || ![role isEqualToString:old_role] || !(subrole == old_subrole || [subrole isEqualToString:old_subrole])) {
        [el setAccessibilityRole:role];
        [el setAccessibilitySubrole:subrole];
    }
    if (fresh || ![name isEqualToString:old_name] || n->role != o.role) {
        if (titled(n->role)) { [el setAccessibilityTitle:name]; [el setAccessibilityLabel:nil]; }
        else { [el setAccessibilityTitle:nil]; [el setAccessibilityLabel:name]; }
    }
    if (fresh || ((n->flags ^ o.flags) & ENABLED)) [el setAccessibilityEnabled:(n->flags & ENABLED) != 0];
    if (fresh || ((n->flags ^ o.flags) & (EXPANDABLE | EXPANDED))) [el setAccessibilityExpanded:(n->flags & EXPANDED) != 0];
    if (fresh || ((n->flags ^ o.flags) & REQUIRED)) [el setAccessibilityRequired:(n->flags & REQUIRED) != 0];
    if (ranged(n->role) && (fresh || n->range_minimum != o.range_minimum || n->range_maximum != o.range_maximum)) {
        [el setAccessibilityMinValue:@(n->range_minimum)];
        [el setAccessibilityMaxValue:@(n->range_maximum)];
    }
    BOOL toggled = ((n->flags ^ o.flags) & (CHECKED | MIXED | EXPANDED)) != 0;
    BOOL changed = NO;
    if (fresh || ![value isEqualToString:old_value] || n->range_value != o.range_value || toggled || n->role != o.role || (n->role == ROLE_TEXT && ![name isEqualToString:old_name])) {
        el->text = value;
        [el setAccessibilityValue:value_of(n, name, value)];
        changed = !fresh;
    }
    if (n->role == ROLE_TREE_ITEM && (fresh || ((n->flags ^ o.flags) & EXPANDED))) [el setAccessibilityDisclosed:(n->flags & EXPANDED) != 0];
    if (row(n->role) && (fresh || ((n->flags ^ o.flags) & CHECKED))) [el setAccessibilitySelected:(n->flags & CHECKED) != 0];
    if (fresh || ![description isEqualToString:el.accessibilityHelp ?: @""]) [el setAccessibilityHelp:description.length ? description : nil];
    if (textual(n->role) && (fresh || changed || n->selection_start != o.selection_start || n->selection_end != o.selection_end)) {
        NSUInteger length = (n->flags & PASSWORD) ? 0 : value.length;
        NSUInteger a = MIN(n->selection_start, length), b = MIN(MAX(n->selection_end, n->selection_start), length);
        [el setAccessibilityNumberOfCharacters:(NSInteger)length];
        [el setAccessibilitySelectedTextRange:NSMakeRange(a, b - a)];
    }
    return changed;
}

static int publish(ZuaHost *host, const NativeNode *nodes, uint32_t count, const uint16_t *text, uint32_t text_len, const RecipientAuthority *keys) {
    if (host->closed) return -1;
    if (count == 0 || nodes[0].id != 0) return -2;
    NSView *view = host->view;
    host->updating = YES;
    BOOL layout = NO;
    NSMutableArray<ZuaElement *> *value_changed = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, ZuaElement *> *live = [NSMutableDictionary dictionaryWithCapacity:count];
    NSMutableDictionary<NSNumber *, NSMutableArray *> *children = [NSMutableDictionary dictionary];
    NSMutableArray *top = [NSMutableArray array];
    NSMutableArray *order = [NSMutableArray arrayWithCapacity:count];
    uint64_t focus = 0;
    BOOL has_focus = NO;
    /* The root is the view itself, which names the content. */
    [view setAccessibilityLabel:text_at(text, text_len, nodes[0].name_start, nodes[0].name_len)];
    for (uint32_t i = 1; i < count; i++) {
        const NativeNode *n = &nodes[i];
        if (n->role >= ROLE_COUNT) { host->updating = NO; return -2; }
        NSNumber *key = @(n->id);
        ZuaElement *el = host->elements[key];
        if (!el) {
            el = [[ZuaElement alloc] init];
            el->host = host; el->fresh = YES;
            live_elements++;
            layout = YES;
        }
        NSString *name = text_at(text, text_len, n->name_start, n->name_len);
        NSString *value = text_at(text, text_len, n->value_start, n->value_len);
        NSString *description = text_at(text, text_len, n->description_start, n->description_len);
        if (apply(el, n, name, value, description, keys ? &keys[i] : NULL)) [value_changed addObject:el];
        live[key] = el;
        [order addObject:el];
        if ((n->flags & FOCUSED) && !has_focus) { focus = n->id; has_focus = YES; }
        if (n->parent == 0) [top addObject:el];
        else {
            NSMutableArray *list = children[@(n->parent)];
            if (!list) children[@(n->parent)] = list = [NSMutableArray array];
            [list addObject:el];
        }
    }
    for (NSNumber *key in live) {
        ZuaElement *el = live[key];
        id parent = el->node.parent == 0 ? view : live[@(el->node.parent)];
        if (el->parent != parent) { el->parent = parent; [el setAccessibilityParent:parent]; }
        NSArray *kids = children[key] ?: @[];
        NSMutableArray<NSNumber *> *ids = [NSMutableArray arrayWithCapacity:kids.count];
        for (ZuaElement *kid in kids) [ids addObject:@(kid->node.id)];
        if (![ids isEqualToArray:el->child_ids ?: @[]]) {
            el->child_ids = ids;
            [el setAccessibilityChildren:kids];
            layout = YES;
        }
    }
    /* Lists and tables: their rows, the rows that show and those chosen. */
    for (NSNumber *key in live) {
        ZuaElement *el = live[key];
        if (!rows_container(el->node.role)) continue;
        NSMutableArray *rows = [NSMutableArray array], *shown = [NSMutableArray array], *chosen = [NSMutableArray array];
        for (ZuaElement *kid in children[key] ?: @[]) {
            if (!row(kid->node.role)) continue;
            [kid setAccessibilityIndex:(NSInteger)rows.count];
            [rows addObject:kid];
            if (!(kid->node.flags & OFFSCREEN)) [shown addObject:kid];
            if (kid->node.flags & CHECKED) [chosen addObject:kid];
        }
        [el setAccessibilityRows:rows];
        [el setAccessibilityRowCount:(NSInteger)rows.count];
        [el setAccessibilityVisibleRows:shown];
        [el setAccessibilitySelectedRows:chosen];
    }
    for (NSNumber *key in host->elements) {
        if (live[key]) continue;
        ZuaElement *gone = host->elements[key];
        gone->parent = nil;
        NSAccessibilityPostNotification(gone, NSAccessibilityUIElementDestroyedNotification);
        layout = YES;
    }
    if (![top isEqualToArray:host->top]) layout = YES;
    host->elements = live;
    host->top = top;
    host->order = order;
    BOOL focus_changed = has_focus != host->has_focus || focus != host->focus;
    host->focus = focus; host->has_focus = has_focus;
    host->updating = NO;
    if (view && layout) NSAccessibilityPostNotification(view, NSAccessibilityLayoutChangedNotification);
    for (ZuaElement *el in value_changed) NSAccessibilityPostNotification(el, NSAccessibilityValueChangedNotification);
    if (focus_changed && has_focus) NSAccessibilityPostNotification(live[@(focus)], NSAccessibilityFocusedUIElementChangedNotification);
    return 0;
}

/* The window's drawing view: its content view holds it, above the
   material behind it. */
static NSView *zua_content_view(NSWindow *window) {
    NSView *content = window.contentView;
    if ([content respondsToSelector:@selector(setZigAccessibility:)]) return content;
    for (NSView *child in content.subviews)
        if ([child respondsToSelector:@selector(setZigAccessibility:)]) return child;
    return nil;
}
void *zua_create(void *handle, ZuaEnqueue enqueue, void *context) {
    NSWindow *window = (__bridge NSWindow *)handle;
    NSView *view = zua_content_view(window);
    if (!view) return NULL;
    ZuaHost *host = [[ZuaHost alloc] init];
    host->window = window; host->view = view; host->enqueue = enqueue; host->context = context;
    [view setZigAccessibility:host];
    return (__bridge_retained void *)host;
}
/* Revokes the Zig context: actions taken after it are refused. */
void zua_begin_close(void *state) {
    ZuaHost *host = (__bridge ZuaHost *)state;
    host->context = NULL;
    host->closed = YES;
    NSView *view = host->view;
    if (view) {
        [view setZigAccessibility:nil];
        NSAccessibilityPostNotification(view, NSAccessibilityLayoutChangedNotification);
    }
}
int zua_disconnect(void *state) {
    ZuaHost *host = (__bridge_transfer ZuaHost *)state;
    host->closed = YES;
    host->context = NULL;
    for (ZuaElement *el in [host->elements allValues]) {
        el->parent = nil;
        NSAccessibilityPostNotification(el, NSAccessibilityUIElementDestroyedNotification);
    }
    host->elements = [NSMutableDictionary dictionary];
    host->top = @[];
    host->order = @[];
    return 0;
}
int zua_publish(void *state, const NativeNode *nodes, uint32_t count, const uint16_t *text, uint32_t text_len) {
    @autoreleasepool { return publish((__bridge ZuaHost *)state, nodes, count, text, text_len, NULL); }
}
int zua_publish_registered(void *state, const NativeNode *nodes, uint32_t count, const uint16_t *text, uint32_t text_len, const RecipientAuthority *keys) {
    @autoreleasepool { return publish((__bridge ZuaHost *)state, nodes, count, text, text_len, keys); }
}
/* Transformed content reports the bounds of its nodes as laid out; their
   precise geometry is not used here. */
int zua_publish_geometry(void *state, const NativeNode *nodes, uint32_t count, const uint16_t *text, uint32_t text_len, const void *geometry) {
    (void)geometry;
    return zua_publish(state, nodes, count, text, text_len);
}
int zua_publish_geometry_registered(void *state, const NativeNode *nodes, uint32_t count, const uint16_t *text, uint32_t text_len, const void *geometry, const RecipientAuthority *keys) {
    (void)geometry;
    return zua_publish_registered(state, nodes, count, text, text_len, keys);
}
static unsigned live_geometry;
void *zua_geometry_create(void) { void *g = malloc(1); if (g) live_geometry++; return g; }
void zua_geometry_free(void *geometry) { if (geometry) { free(geometry); live_geometry--; } }
int zua_geometry_commit(void *state, void *geometry) { (void)state; zua_geometry_free(geometry); return 0; }
void zua_geometry_release(void *state) { (void)state; }
uint32_t zua_geometry_count(void) { return live_geometry; }

int zua_take_action(void *pointer, ActionView *out) {
    Action *a = pointer;
    ZuaHost *host = (__bridge ZuaHost *)a->host;
    ZuaElement *el = host->closed ? nil : [host element:a->id];
    BOOL available = !host->closed && host->context && el && (el->node.flags & ENABLED);
    /* The element's recipient must still be the one the request was made
       for: an older request does not act on a newly registered recipient. */
    if (available && memcmp(&el->recipient, &a->recipient, sizeof(RecipientAuthority)) != 0) available = NO;
    if (available) *out = (ActionView){ host->context, a->kind, a->id, a->value, a->value_len, a->start, a->end, a->number, a->recipient };
    return available;
}
int zua_take_collection_action(void *action, void *out) { (void)action; (void)out; return 0; }
void zua_finish_action(void *pointer) {
    Action *a = pointer;
    CFRelease(a->host);
    free(a->value);
    free(a);
    live_actions--;
}
void zua_resource_counts(uint32_t *states, uint32_t *providers, uint32_t *ranges, uint32_t *actions) {
    *states = live_hosts; *providers = live_elements; *ranges = 0; *actions = live_actions;
}

/* Test hooks: assistive technology's view of a window, as VoiceOver would
   ask for it. */
void *zua_test_element(void *handle, const char *name) {
    NSWindow *window = (__bridge NSWindow *)handle;
    NSMutableArray *queue = [NSMutableArray arrayWithArray:[zua_content_view(window) accessibilityChildren] ?: @[]];
    NSString *wanted = [NSString stringWithUTF8String:name];
    while (queue.count) {
        id element = queue[0];
        [queue removeObjectAtIndex:0];
        if ([[element accessibilityTitle] isEqualToString:wanted] || [[element accessibilityLabel] isEqualToString:wanted]) return (__bridge void *)element;
        [queue addObjectsFromArray:[element accessibilityChildren] ?: @[]];
    }
    return NULL;
}

/* What assistive technology reads of an element: "role/subrole|title|label|
   value|enabled", cut to fit `capacity`. */
int zua_test_describe(void *pointer, char *buffer, int capacity) {
    @autoreleasepool {
        NSAccessibilityElement *element = (__bridge NSAccessibilityElement *)pointer;
        id value = [element accessibilityValue];
        NSString *text = [NSString stringWithFormat:@"%@/%@|%@|%@|%@|%d", [element accessibilityRole], [element accessibilitySubrole] ?: @"",
            [element accessibilityTitle] ?: @"", [element accessibilityLabel] ?: @"", value ? zua_string_of(value) : @"", [element isAccessibilityEnabled]];
        const char *utf8 = [text UTF8String];
        int length = (int)strlen(utf8);
        if (length >= capacity) length = capacity - 1;
        memcpy(buffer, utf8, (size_t)length);
        buffer[length] = 0;
        return length;
    }
}
/* The element's frame on the screen, and whether it lies in its window. */
int zua_test_frame_in_window(void *pointer, void *handle) {
    NSAccessibilityElement *element = (__bridge NSAccessibilityElement *)pointer;
    NSWindow *window = (__bridge NSWindow *)handle;
    NSRect frame = [element accessibilityFrame];
    return frame.size.width > 0 && frame.size.height > 0 && NSContainsRect([window convertRectToScreen:[zua_content_view(window) convertRect:zua_content_view(window).bounds toView:nil]], frame);
}
/* Acts on an element as VoiceOver does: 1 press, 2 increment, 3 set a
   string value, 4 set a number value (as VoiceOver may for a text field),
   5 focus, 6 select text from `number` for one character. */
void zua_test_act(void *pointer, int kind, double number, const char *text) {
    @autoreleasepool {
        NSAccessibilityElement *element = (__bridge NSAccessibilityElement *)pointer;
        switch (kind) {
        case 1: [element accessibilityPerformPress]; break;
        case 2: [element accessibilityPerformIncrement]; break;
        case 3: [element setAccessibilityValue:[NSString stringWithUTF8String:text]]; break;
        case 4: [element setAccessibilityValue:@(number)]; break;
        case 5: [element setAccessibilityFocused:YES]; break;
        case 6: [element setAccessibilitySelectedTextRange:NSMakeRange((NSUInteger)number, 1)]; break;
        }
    }
}
/* The window's content view's children as assistive technology sees them. */
int zua_test_child_count(void *handle) {
    NSWindow *window = (__bridge NSWindow *)handle;
    return (int)[[zua_content_view(window) accessibilityChildren] count];
}
