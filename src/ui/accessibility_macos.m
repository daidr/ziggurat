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
#include "accessibility_geometry.h"
/* Complete lists: the platform-neutral store and models the Windows host
   shares, with NSAccessibility rows made as assistive technology asks. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
#include "accessibility_collection_store.h"
#include "accessibility_collection_model.h"
#pragma clang diagnostic pop

void zua_geometry_free(ZuaGeometry *geometry);

/* accessibility.zig `Role`. */
enum {
    ROLE_WINDOW, ROLE_GROUP, ROLE_BUTTON, ROLE_TEXT, ROLE_TEXT_BOX, ROLE_CHECKBOX, ROLE_RADIO, ROLE_SWITCH, ROLE_PROGRESS,
    ROLE_RADIO_GROUP, ROLE_SLIDER, ROLE_STEPPER, ROLE_LIST, ROLE_TAB_LIST, ROLE_TAB, ROLE_TOOLBAR, ROLE_SPLITTER, ROLE_LINK,
    ROLE_DISCLOSURE, ROLE_METER, ROLE_NAVIGATION, ROLE_LIST_BOX, ROLE_LIST_ITEM, ROLE_COMBO_BOX, ROLE_TOOLTIP, ROLE_STATUS,
    ROLE_SEARCH, ROLE_IMAGE, ROLE_TREE, ROLE_TREE_ITEM, ROLE_TABLE, ROLE_TABLE_HEADER, ROLE_COLUMN_HEADER, ROLE_TABLE_ROW,
    ROLE_TOKEN_FIELD, ROLE_TOKEN, ROLE_POPUP, ROLE_CALENDAR, ROLE_COLOR_WELL, ROLE_DIALOG, ROLE_ALERT_DIALOG, ROLE_MENU,
    ROLE_MENU_ITEM, ROLE_MENU_ITEM_CHECKBOX, ROLE_MENU_ITEM_RADIO, ROLE_REGION, ROLE_LOG, ROLE_TIMER, ROLE_ALERT,
    ROLE_SEPARATOR, ROLE_ROW_HEADER, ROLE_OPTION, ROLE_ARTICLE, ROLE_CELL, ROLE_HEADING, ROLE_COUNT
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
    /* Place among all of the list's items from 1, how many a list has and
       a tree item's depth from 1; 0 when not given. */
    uint32_t position, set_size, level;
    /* NativeState: FOCUSABLE_DISABLED, BUSY, SELECTABLE, SELECTED and
       VERTICAL, then the popup kind (bits 8 to 10), current (11 to 13),
       sort (14, 15) and autocomplete (16, 17). */
    uint32_t states;
    uint32_t role_description_start, role_description_len, key_shortcuts_start, key_shortcuts_len;
    uint32_t value_text_start, value_text_len, reserved0, reserved1;
    /* The node this one controls (aria-controls), 0 for none. */
    uint64_t controls;
} NativeNode;
_Static_assert(sizeof(NativeNode) == 184, "semantic node ABI");
enum { FOCUSABLE_DISABLED = 1, BUSY = 2, SELECTABLE = 4, SELECTED = 8, VERTICAL = 16 };
enum { POPUP_NONE, POPUP_MENU, POPUP_LIST_BOX, POPUP_TREE, POPUP_GRID, POPUP_DIALOG };
enum { CURRENT_NONE, CURRENT_ITEM, CURRENT_PAGE, CURRENT_STEP, CURRENT_LOCATION, CURRENT_DATE, CURRENT_TIME };
enum { SORT_NONE, SORT_ASCENDING, SORT_DESCENDING, SORT_OTHER };
enum { AUTOCOMPLETE_NONE, AUTOCOMPLETE_INLINE, AUTOCOMPLETE_LIST, AUTOCOMPLETE_BOTH };
static inline uint32_t node_popup(const NativeNode *n) { return (n->states >> 8) & 7; }
static inline uint32_t node_current(const NativeNode *n) { return (n->states >> 11) & 7; }
static inline uint32_t node_sort(const NativeNode *n) { return (n->states >> 14) & 3; }
static inline uint32_t node_autocomplete(const NativeNode *n) { return (n->states >> 16) & 3; }
static const char *const popup_names[] = { "", "menu", "listbox", "tree", "grid", "dialog" };
static const char *const current_names[] = { "", "true", "page", "step", "location", "date", "time" };
static const char *const sort_names[] = { "", "ascending", "descending", "other" };
static const char *const autocomplete_names[] = { "", "inline", "list", "both" };
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

static unsigned live_hosts, live_elements, live_actions, live_collections;
/* The registered recipients of a host and the store of its complete lists,
   which a candidate brings before the host adopts it. */
typedef struct ZuaCollections { CollectionStore *virtuals; } ZuaCollections;
/* Row requests of complete lists (collection_authority.zig `Kind`). */
enum { ROW_SELECT = 1, ROW_ADD = 2, ROW_REMOVE = 3, ROW_FOCUS = 4, ROW_REVEAL = 5 };

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
/* Native content a node holds, as a web view's page (webkit_macos.m). */
@interface NSObject (ZuaHosted)
- (void)setZigAccessibilityParent:(id)parent;
@end

/* Announcements posted, and the last one's text, for the smoke test. */
static uint32_t announcements;
static NSString *last_announcement;
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
@class ZuaRow;

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
    /* The precise geometry of transformed content, while published. */
    ZuaGeometry *geometry;
    BOOL geometry_active;
    /* Registered recipients and complete lists, once prepared, and the row
       of a complete list that had the focus at the last publication. */
    ZuaCollections *collections;
    uint64_t focus_row, focus_incarnation;
}
- (BOOL)request:(ZuaElement *)element kind:(uint32_t)kind value:(NSString *)value start:(uint32_t)start end:(uint32_t)end number:(double)number;
- (BOOL)requestRow:(ZuaRow *)row kind:(uint32_t)kind;
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
    uint32_t published_at; /* in its publication, for its geometry */
    /* Native content inside the node, as a web view's page: its first
       child (zua_pages). */
    NSView *__weak page;
    /* A complete list: its registration, its rows as assistive technology
       asked for them by ID, and the model and selection last published. */
    BOOL virtual_list;
    CollectionRegistration virtual_key;
    NSMutableDictionary<NSNumber *, ZuaRow *> *virtual_rows;
    const void *virtual_catalog;
    uint64_t virtual_revision;
}
@end

/* A row of a complete list, built or not: it reads the list's last
   published model by its ID and incarnation, and stands for nothing once
   they are gone. */
@interface ZuaRow : NSAccessibilityElement {
@public
    ZuaHost *__weak host;
    ZuaElement *__weak list;
    CollectionRegistration key;
    uint64_t row_id, incarnation;
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
    /* Kind 6: the row of a complete list and what to do with it. */
    CollectionRowRequest row;
} Action;

static CollectionRegistration registration_of(const RecipientAuthority *key) {
    return (CollectionRegistration){ key->epoch, key->serial, key->id, key->slot, key->kind };
}
static CollectionStore *host_store(ZuaHost *host) {
    return host && !host->closed && host->collections ? host->collections->virtuals : NULL;
}
/* The published binding of a complete list. */
static CollectionBinding *virtual_binding(ZuaHost *host, CollectionRegistration key) {
    CollectionStore *store = host_store(host);
    CollectionBinding *binding = store ? collection_store_find(store, key) : NULL;
    return binding && binding->front && binding->front_publication ? binding : NULL;
}
/* The row of id and incarnation in a complete list's published model. */
static const CollectionRow *virtual_row(ZuaHost *host, CollectionRegistration key, uint64_t id, uint64_t incarnation, CollectionBinding **out, uint32_t *index) {
    CollectionBinding *binding = virtual_binding(host, key);
    if (!binding) return NULL;
    const CollectionRow *found = collection_catalog_find(binding->front->catalog, id, index);
    if (!found || found->incarnation != incarnation) return NULL;
    if (out) *out = binding;
    return found;
}
static BOOL virtual_selected(const CollectionBinding *binding, uint32_t index) {
    return (binding->front->selection->front[index / 64] >> (index % 64)) & 1;
}
/* The rows from first to before last whose ticks reach into the list's
   viewport. */
static void virtual_shown(const CollectionBinding *binding, uint32_t *first, uint32_t *last) {
    const CollectionCatalog *catalog = binding->front->catalog;
    const CollectionViewport viewport = binding->front_viewport;
    const double from = viewport.scroll * 64, to = (viewport.scroll + viewport.height) * 64;
    uint32_t low = 0, high = catalog->count;
    while (low < high) {
        const uint32_t middle = low + (high - low) / 2;
        if ((double)catalog->tops[middle + 1] <= from) low = middle + 1; else high = middle;
    }
    *first = low;
    while (low < catalog->count && (double)catalog->tops[low] < to) low++;
    *last = low;
}

@implementation ZuaHost
- (instancetype)init {
    if ((self = [super init])) { elements = [NSMutableDictionary dictionary]; top = @[]; order = @[]; live_hosts++; }
    return self;
}
- (void)dealloc {
    if (geometry) { zua_geometry_free(geometry); geometry = NULL; }
    if (collections) { collection_store_release(collections->virtuals); free(collections); live_collections--; }
    live_hosts--;
}
- (ZuaElement *)element:(uint64_t)identifier { return elements[@(identifier)]; }
- (NSArray *)zigAccessibilityChildren { return closed ? @[] : top; }
/* The element of a complete list's row at index of its published model,
   the same one each time while the row keeps its incarnation. */
- (ZuaRow *)row:(ZuaElement *)list binding:(const CollectionBinding *)binding index:(uint32_t)index {
    const CollectionRow *found = &binding->front->catalog->rows[index];
    NSNumber *key = @(found->id);
    ZuaRow *row = list->virtual_rows[key];
    if (row && row->incarnation == found->incarnation) return row;
    if (!list->virtual_rows) list->virtual_rows = [NSMutableDictionary dictionary];
    /* Rows asked for are kept by ID; a long walk through a large list
       starts the keeping again rather than growing without end. */
    if (list->virtual_rows.count >= 4096) [list->virtual_rows removeAllObjects];
    row = [[ZuaRow alloc] init];
    row->host = self; row->list = list; row->key = list->virtual_key;
    row->row_id = found->id; row->incarnation = found->incarnation;
    live_elements++;
    list->virtual_rows[key] = row;
    return row;
}
/* The row of a focused complete list that has the focus. */
- (ZuaRow *)focusedRow:(ZuaElement *)list {
    if (!list || !list->virtual_list) return nil;
    CollectionBinding *binding = virtual_binding(self, list->virtual_key);
    if (!binding || !binding->front_viewport.caret) return nil;
    uint32_t index;
    if (!virtual_row(self, list->virtual_key, binding->front_viewport.caret, binding->front_viewport.caret_incarnation, NULL, &index)) return nil;
    return [self row:list binding:binding index:index];
}
- (id)zigAccessibilityFocusedElement {
    if (closed || !has_focus) return nil;
    ZuaElement *element = [self element:focus];
    ZuaRow *row = [self focusedRow:element];
    return row ? row : element;
}
/* The row of a complete list at a point of the view, through the inverse
   of the list's mapping into the window. */
- (id)virtualRowIn:(ZuaElement *)list at:(NSPoint)local {
    CollectionBinding *binding = virtual_binding(self, list->virtual_key);
    if (!binding) return nil;
    const double scale = geometry_active && geometry ? geometry->scale : 1;
    const double ox = geometry_active && geometry ? geometry->origin_x : 0, oy = geometry_active && geometry ? geometry->origin_y : 0;
    const double *f = binding->front_mapping.forward;
    const double det = f[0] * f[3] - f[2] * f[1];
    if (!isfinite(det) || fabs(det) < 1e-12) return nil;
    const double dx = (local.x - ox) / scale - f[4], dy = (local.y - oy) / scale - f[5];
    const double lx = (f[3] * dx - f[2] * dy) / det, ly = (-f[1] * dx + f[0] * dy) / det;
    const CollectionViewport viewport = binding->front_viewport;
    if (!(lx >= viewport.x && ly >= viewport.y && lx < viewport.x + viewport.width && ly < viewport.y + viewport.height)) return nil;
    const CollectionCatalog *catalog = binding->front->catalog;
    const double position = (viewport.scroll + (ly - viewport.y)) * 64;
    if (!isfinite(position) || position < 0 || position >= (double)catalog->tops[catalog->count]) return nil;
    const uint64_t tick = (uint64_t)floor(position);
    uint32_t low = 0, high = catalog->count;
    while (low < high) {
        const uint32_t middle = low + (high - low) / 2;
        if (catalog->tops[middle + 1] <= tick) low = middle + 1; else high = middle;
    }
    return low < catalog->count ? [self row:list binding:binding index:low] : nil;
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
        if (!(local.x >= n->x && local.y >= n->y && local.x < n->x + n->width && local.y < n->y + n->height)) continue;
        /* Inside the box of a turned or clipped element: inside the
           element itself. */
        if (geometry_active && !zua_geometry_hit(geometry, element->published_at, local.x, local.y)) continue;
        found = element;
    }
    ZuaElement *deepest = found;
    if (deepest && deepest->virtual_list) {
        id row = [self virtualRowIn:deepest at:local];
        if (row) return row;
    }
    /* A node holding native content, as a web view's page: what the
       content has at the point. */
    NSView *page = deepest ? deepest->page : nil;
    if (page && !page.hidden && page.window == w) {
        id inner = [page accessibilityHitTest:point];
        return inner ? inner : page;
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
/* A request for a row of a complete list, carrying the row's authority in
   the published model: a later model refuses it. */
- (BOOL)requestRow:(ZuaRow *)row kind:(uint32_t)kind {
    if (closed || updating || !context || !enqueue || kind < ROW_SELECT || kind > ROW_REVEAL) return NO;
    ZuaElement *list = row->list;
    if (!list || !list->virtual_list || list != [self element:row->key.id] || !(list->node.flags & ENABLED)) return NO;
    if (!collection_registration_equal(registration_of(&list->recipient), row->key)) return NO;
    CollectionBinding *binding = NULL;
    uint32_t index;
    const CollectionRow *found = virtual_row(self, row->key, row->row_id, row->incarnation, &binding, &index);
    if (!found || !found->enabled) return NO;
    CollectionRowAuthority authority;
    if (collection_binding_capture(binding, index, &authority) != COLLECTION_OK) return NO;
    Action *a = calloc(1, sizeof(Action));
    if (!a) return NO;
    a->host = (__bridge_retained void *)self;
    a->kind = 6; a->id = row->key.id;
    a->recipient = list->recipient;
    a->row = (CollectionRowRequest){ .authority = authority, .kind = kind };
    live_actions++;
    if (!enqueue(context, a)) {
        CFRelease(a->host); free(a); live_actions--;
        return NO;
    }
    return YES;
}
@end

@implementation ZuaRow
- (void)dealloc { live_elements--; }
- (const CollectionRow *)read:(CollectionBinding **)binding index:(uint32_t *)index {
    ZuaHost *h = host;
    ZuaElement *l = list;
    if (!h || !l || !l->virtual_list || h->closed) return NULL;
    return virtual_row(h, key, row_id, incarnation, binding, index);
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityRowRole; }
- (NSAccessibilitySubrole)accessibilitySubrole { return NSAccessibilityTableRowSubrole; }
- (NSString *)accessibilityLabel {
    CollectionBinding *binding;
    uint32_t index;
    const CollectionRow *found = [self read:&binding index:&index];
    if (!found) return nil;
    const CollectionCatalog *catalog = binding->front->catalog;
    return [[NSString alloc] initWithBytes:catalog->text + found->start length:found->length encoding:NSUTF8StringEncoding] ?: @"";
}
- (NSString *)accessibilityIdentifier { return [NSString stringWithFormat:@"%llu", (unsigned long long)row_id]; }
- (NSInteger)accessibilityIndex {
    CollectionBinding *binding;
    uint32_t index;
    return [self read:&binding index:&index] ? (NSInteger)index : 0;
}
- (id)accessibilityParent { return [self read:NULL index:&(uint32_t){0}] ? list : nil; }
- (NSArray *)accessibilityChildren { return @[]; }
- (BOOL)isAccessibilityEnabled {
    ZuaElement *l = list;
    CollectionBinding *binding;
    uint32_t index;
    const CollectionRow *found = [self read:&binding index:&index];
    return found && found->enabled && l && (l->node.flags & ENABLED);
}
- (BOOL)isAccessibilitySelected {
    CollectionBinding *binding;
    uint32_t index;
    return [self read:&binding index:&index] && virtual_selected(binding, index);
}
- (BOOL)isAccessibilityFocused {
    ZuaHost *h = host;
    ZuaElement *l = list;
    if (!h || !l || !h->has_focus || h->focus != l->node.id) return NO;
    CollectionBinding *binding;
    uint32_t index;
    return [self read:&binding index:&index] && binding->front_viewport.caret == row_id && binding->front_viewport.caret_incarnation == incarnation;
}
/* Where the row shows, in screen coordinates; nothing while it is out of
   the list's viewport. */
- (NSRect)accessibilityFrame {
    ZuaHost *h = host;
    ZuaElement *l = list;
    CollectionBinding *binding;
    uint32_t index;
    if (!h || ![self read:&binding index:&index] || (l->node.flags & OFFSCREEN)) return NSZeroRect;
    const CollectionCatalog *catalog = binding->front->catalog;
    const CollectionViewport viewport = binding->front_viewport;
    const double top = viewport.y + (double)catalog->tops[index] / 64 - viewport.scroll;
    const double height = (double)catalog->rows[index].height / 64;
    const BOOL mapped = h->geometry_active && h->geometry;
    CollectionBounds bounds;
    if (zua_collection_row_bounds(&binding->front_mapping, top, height, mapped ? h->geometry->origin_x : 0, mapped ? h->geometry->origin_y : 0, mapped ? h->geometry->scale : 1, &bounds) || !bounds.visible) return NSZeroRect;
    return [h screenRect:NSMakeRect(bounds.rect.x, bounds.rect.y, bounds.rect.width, bounds.rect.height)];
}
- (BOOL)isAccessibilitySelectorAllowed:(SEL)selector {
    if (selector == @selector(accessibilityPerformPress) || selector == @selector(setAccessibilitySelected:) || selector == @selector(setAccessibilityFocused:)) return YES;
    return [super isAccessibilitySelectorAllowed:selector];
}
- (BOOL)accessibilityPerformPress {
    ZuaHost *h = host;
    return h && [h requestRow:self kind:ROW_SELECT];
}
/* Choosing a row chooses it alone, as AppKit's tables do; unchoosing it
   takes it out of the choice. */
- (void)setAccessibilitySelected:(BOOL)selected {
    ZuaHost *h = host;
    if (h) [h requestRow:self kind:selected ? ROW_SELECT : ROW_REMOVE];
}
- (void)setAccessibilityFocused:(BOOL)focused {
    ZuaHost *h = host;
    if (h && focused) [h requestRow:self kind:ROW_FOCUS];
}
/* AXScrollToVisible, which AppKit names no constant for, brings the row
   into the list's viewport. */
static NSString *const ZuaScrollToVisible = @"AXScrollToVisible";
- (NSArray *)accessibilityActionNames {
    NSArray *names = [super accessibilityActionNames] ?: @[];
    return [names containsObject:ZuaScrollToVisible] ? names : [names arrayByAddingObject:ZuaScrollToVisible];
}
- (void)accessibilityPerformAction:(NSAccessibilityActionName)action {
    ZuaHost *h = host;
    if ([action isEqualToString:ZuaScrollToVisible]) { if (h) [h requestRow:self kind:ROW_REVEAL]; return; }
    [super accessibilityPerformAction:action];
}
@end

@implementation ZuaElement
- (void)dealloc { live_elements--; }
/* The rows of a complete list from start, at most count of them. */
- (NSArray *)virtualRowsFrom:(NSUInteger)start count:(NSUInteger)count {
    ZuaHost *h = host;
    CollectionBinding *binding = h ? virtual_binding(h, virtual_key) : NULL;
    if (!binding) return @[];
    const uint32_t total = binding->front->catalog->count;
    if (start >= total) return @[];
    const NSUInteger end = count > total - start ? total : start + count;
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:end - start];
    for (NSUInteger i = start; i < end; i++) [rows addObject:[h row:self binding:binding index:(uint32_t)i]];
    return rows;
}
- (NSArray *)accessibilityChildren {
    if (virtual_list) return [self virtualRowsFrom:0 count:NSUIntegerMax];
    NSArray *kids = [super accessibilityChildren] ?: @[];
    NSView *p = page;
    return p ? [@[p] arrayByAddingObjectsFromArray:kids] : kids;
}
- (NSArray *)accessibilityRows { return virtual_list ? [self virtualRowsFrom:0 count:NSUIntegerMax] : [super accessibilityRows]; }
- (NSInteger)accessibilityRowCount {
    if (!virtual_list) return [super accessibilityRowCount];
    ZuaHost *h = host;
    CollectionBinding *binding = h ? virtual_binding(h, virtual_key) : NULL;
    return binding ? (NSInteger)binding->front->catalog->count : 0;
}
- (NSArray *)accessibilityVisibleRows {
    if (!virtual_list) return [super accessibilityVisibleRows];
    ZuaHost *h = host;
    CollectionBinding *binding = h ? virtual_binding(h, virtual_key) : NULL;
    if (!binding || (node.flags & OFFSCREEN)) return @[];
    uint32_t first, last;
    virtual_shown(binding, &first, &last);
    return [self virtualRowsFrom:first count:last - first];
}
- (NSArray *)accessibilitySelectedRows {
    if (!virtual_list) return [super accessibilitySelectedRows];
    ZuaHost *h = host;
    CollectionBinding *binding = h ? virtual_binding(h, virtual_key) : NULL;
    if (!binding) return @[];
    const CollectionSelection *selection = binding->front->selection;
    NSMutableArray *rows = [NSMutableArray array];
    for (uint32_t word = 0; word < selection->word_count; word++) {
        for (uint64_t bits = selection->front[word]; bits; bits &= bits - 1) {
            const uint32_t index = word * 64 + (uint32_t)__builtin_ctzll(bits);
            if (index < binding->front->catalog->count) [rows addObject:[h row:self binding:binding index:index]];
        }
    }
    return rows;
}
/* Choosing rows of a complete list: the first alone, then the others
   added to it. */
- (void)setAccessibilitySelectedRows:(NSArray *)rows {
    if (!virtual_list) { [super setAccessibilitySelectedRows:rows]; return; }
    ZuaHost *h = host;
    BOOL first = YES;
    for (id entry in rows) {
        if (![entry isKindOfClass:[ZuaRow class]]) continue;
        ZuaRow *row = entry;
        if (row->list != self) continue;
        [h requestRow:row kind:first ? ROW_SELECT : ROW_ADD];
        first = NO;
    }
}
/* Assistive technology reads a large list's rows a range at a time. */
- (NSUInteger)accessibilityArrayAttributeCount:(NSAccessibilityAttributeName)attribute {
    if (virtual_list && ([attribute isEqualToString:NSAccessibilityChildrenAttribute] || [attribute isEqualToString:NSAccessibilityRowsAttribute]))
        return (NSUInteger)[self accessibilityRowCount];
    return [super accessibilityArrayAttributeCount:attribute];
}
- (NSArray *)accessibilityArrayAttributeValues:(NSAccessibilityAttributeName)attribute index:(NSUInteger)index maxCount:(NSUInteger)maxCount {
    if (virtual_list && ([attribute isEqualToString:NSAccessibilityChildrenAttribute] || [attribute isEqualToString:NSAccessibilityRowsAttribute]))
        return [self virtualRowsFrom:index count:maxCount];
    return [super accessibilityArrayAttributeValues:attribute index:index maxCount:maxCount];
}
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
    /* How deep the row of an outline is, from 0. */
    if (n->role == ROLE_TREE_ITEM && n->level > 0 && (fresh || n->level != o.level)) [el setAccessibilityDisclosureLevel:(NSInteger)n->level - 1];
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

/* The complete lists of a publication: every list node is a registered
   control staged in this frame, every list staged is in it, and the
   recipients agree on one publication, which they return. */
static enum CollectionStatus virtual_preflight(ZuaHost *host, const NativeNode *nodes, uint32_t count, const RecipientAuthority *keys, BOOL mapped, uint64_t *publication) {
    CollectionStore *store = host_store(host);
    *publication = 0;
    if (!store) return COLLECTION_OK;
    enum CollectionStatus status = collection_store_preflight(store, store->frame);
    if (status) return status;
    uint64_t accepted = 0;
    for (uint32_t i = 0; i < count; i++) {
        if (keys && keys[i].serial) {
            if (accepted && accepted != keys[i].publication) return COLLECTION_INVALID;
            accepted = keys[i].publication;
        }
        if (nodes[i].role != ROLE_LIST) continue;
        if (!keys || !keys[i].serial || keys[i].kind != 1 || !mapped) return COLLECTION_INVALID;
        CollectionBinding *binding = collection_store_find(store, registration_of(&keys[i]));
        if (!binding || binding->staged_frame != store->frame) return COLLECTION_STALE;
    }
    for (uint32_t slot = 0; slot < store->capacity; slot++) {
        const CollectionBinding *binding = &store->bindings[slot];
        if (binding->staged_frame != store->frame) continue;
        BOOL found = NO;
        for (uint32_t i = 0; i < count && !found; i++) found = nodes[i].role == ROLE_LIST && nodes[i].id == binding->registration.id;
        if (!found) return COLLECTION_INVALID;
    }
    *publication = accepted;
    return COLLECTION_OK;
}

static int publish(ZuaHost *host, const NativeNode *nodes, uint32_t count, const uint16_t *text, uint32_t text_len, const RecipientAuthority *keys, const ZuaGeometry *geometry) {
    if (host->closed) return -1;
    if (count == 0 || nodes[0].id != 0) return -2;
    if (geometry && (!host->geometry || !zua_geometry_valid(geometry, count))) return -2;
    for (uint32_t i = 1; i < count; i++) if (nodes[i].role >= ROLE_COUNT) return -2;
    uint64_t publication = 0;
    const enum CollectionStatus checked = virtual_preflight(host, nodes, count, keys, geometry != NULL, &publication);
    if (checked) return checked == COLLECTION_STALE ? -1 : -2;
    if (geometry) memcpy(host->geometry, geometry, sizeof *geometry);
    host->geometry_active = geometry != NULL;
    NSView *view = host->view;
    host->updating = YES;
    BOOL layout = NO;
    NSMutableArray<ZuaElement *> *value_changed = [NSMutableArray array];
    NSMutableArray<NSString *> *announce = [NSMutableArray array];
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
        const BOOL created = el == nil;
        if (!el) {
            el = [[ZuaElement alloc] init];
            el->host = host; el->fresh = YES;
            live_elements++;
            layout = YES;
        }
        NSString *name = text_at(text, text_len, n->name_start, n->name_len);
        NSString *value = text_at(text, text_len, n->value_start, n->value_len);
        NSString *description = text_at(text, text_len, n->description_start, n->description_len);
        el->published_at = i;
        if (apply(el, n, name, value, description, keys ? &keys[i] : NULL)) [value_changed addObject:el];
        /* A status message absent from the previous tree announces itself
           once, politely. */
        if (created && n->role == ROLE_STATUS && (name.length || value.length)) [announce addObject:name.length ? name : value];
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
    /* Lists and tables: their rows, the rows that show and those chosen.
       VoiceOver reads a row "5 of 10,000" from its index among all of its
       table's (AXIndex) and how many the table has (AXRowCount), built or
       not, as a list built only in view says through position and
       set_size; without them, from the rows built. */
    /* Complete lists: the staged models become the published ones, and the
       lists read their rows from them. */
    CollectionStore *store = host_store(host);
    if (store) collection_store_commit(store, store->frame, publication);
    NSMutableArray<ZuaElement *> *recounted = [NSMutableArray array], *rechosen = [NSMutableArray array];
    for (NSNumber *key in live) {
        ZuaElement *el = live[key];
        CollectionBinding *binding = el->node.role == ROLE_LIST && el->recipient.serial ? virtual_binding(host, registration_of(&el->recipient)) : NULL;
        const BOOL was = el->virtual_list;
        el->virtual_list = binding != NULL;
        if (!binding) { el->virtual_rows = nil; el->virtual_catalog = NULL; continue; }
        el->virtual_key = registration_of(&el->recipient);
        const CollectionCatalog *catalog = binding->front->catalog;
        if (el->virtual_catalog != catalog) {
            /* Rows of the old model keep their elements while their ID and
               incarnation stay. */
            NSMutableArray *stale = [NSMutableArray array];
            for (NSNumber *id in el->virtual_rows) {
                uint32_t index;
                const CollectionRow *found = collection_catalog_find(catalog, el->virtual_rows[id]->row_id, &index);
                if (!found || found->incarnation != el->virtual_rows[id]->incarnation) [stale addObject:id];
            }
            [el->virtual_rows removeObjectsForKeys:stale];
            if (was) [recounted addObject:el];
            el->virtual_catalog = catalog;
            layout = YES;
        }
        if (was && el->virtual_revision != binding->front->selection->front_revision) [rechosen addObject:el];
        el->virtual_revision = binding->front->selection->front_revision;
    }
    for (NSNumber *key in live) {
        ZuaElement *el = live[key];
        if (!rows_container(el->node.role) || el->virtual_list) continue;
        NSMutableArray *rows = [NSMutableArray array], *shown = [NSMutableArray array], *chosen = [NSMutableArray array];
        for (ZuaElement *kid in children[key] ?: @[]) {
            if (!row(kid->node.role)) continue;
            [kid setAccessibilityIndex:kid->node.position > 0 ? (NSInteger)kid->node.position - 1 : (NSInteger)rows.count];
            [rows addObject:kid];
            if (!(kid->node.flags & OFFSCREEN)) [shown addObject:kid];
            if (kid->node.flags & CHECKED) [chosen addObject:kid];
        }
        [el setAccessibilityRows:rows];
        [el setAccessibilityRowCount:el->node.set_size > 0 ? (NSInteger)el->node.set_size : (NSInteger)rows.count];
        [el setAccessibilityVisibleRows:shown];
        [el setAccessibilitySelectedRows:chosen];
    }
    for (NSNumber *key in host->elements) {
        if (live[key]) continue;
        ZuaElement *gone = host->elements[key];
        gone->parent = nil;
        gone->virtual_list = NO; gone->virtual_rows = nil;
        NSView *page = gone->page;
        if (page && [page respondsToSelector:@selector(setZigAccessibilityParent:)] && [page accessibilityParent] == gone) [(id)page setZigAccessibilityParent:nil];
        gone->page = nil;
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
    /* The focus moving between the rows of a focused complete list. */
    ZuaRow *focus_row = has_focus ? [host focusedRow:live[@(focus)]] : nil;
    if ((focus_row ? focus_row->row_id : 0) != host->focus_row || (focus_row ? focus_row->incarnation : 0) != host->focus_incarnation) focus_changed = has_focus;
    host->focus_row = focus_row ? focus_row->row_id : 0;
    host->focus_incarnation = focus_row ? focus_row->incarnation : 0;
    if (view && layout) NSAccessibilityPostNotification(view, NSAccessibilityLayoutChangedNotification);
    for (ZuaElement *el in value_changed) NSAccessibilityPostNotification(el, NSAccessibilityValueChangedNotification);
    for (ZuaElement *el in recounted) NSAccessibilityPostNotification(el, NSAccessibilityRowCountChangedNotification);
    for (ZuaElement *el in rechosen) NSAccessibilityPostNotification(el, NSAccessibilitySelectedRowsChangedNotification);
    if (focus_changed && has_focus) NSAccessibilityPostNotification(focus_row ? (id)focus_row : (id)live[@(focus)], NSAccessibilityFocusedUIElementChangedNotification);
    for (NSString *message in announce) {
        announcements++;
        last_announcement = message;
        NSAccessibilityPostNotificationWithUserInfo(NSApp, NSAccessibilityAnnouncementRequestedNotification,
            @{NSAccessibilityAnnouncementKey: message, NSAccessibilityPriorityKey: @(NSAccessibilityPriorityMedium)});
    }
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
    /* Rows asked for later stand for nothing. */
    if (host->collections) collection_store_clear(host->collections->virtuals);
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
    if (host->collections) collection_store_clear(host->collections->virtuals);
    for (ZuaElement *el in [host->elements allValues]) {
        el->parent = nil;
        el->virtual_list = NO; el->virtual_rows = nil;
        NSView *page = el->page;
        if (page && [page respondsToSelector:@selector(setZigAccessibilityParent:)] && [page accessibilityParent] == el) [(id)page setZigAccessibilityParent:nil];
        el->page = nil;
        NSAccessibilityPostNotification(el, NSAccessibilityUIElementDestroyedNotification);
    }
    host->elements = [NSMutableDictionary dictionary];
    host->top = @[];
    host->order = @[];
    return 0;
}
/* What live regions read out, as Zig tells them: the content added to a
   log, and an alert's at high priority, interrupting what is being read. */
int zua_announce(void *state, const uint16_t *text, uint32_t text_len, int assertive) {
    @autoreleasepool {
        if (!state || !text) return -1;
        NSString *message = [NSString stringWithCharacters:text length:text_len];
        announcements++;
        last_announcement = message;
        NSAccessibilityPostNotificationWithUserInfo(NSApp, NSAccessibilityAnnouncementRequestedNotification,
            @{NSAccessibilityAnnouncementKey: message,
              NSAccessibilityPriorityKey: @(assertive ? NSAccessibilityPriorityHigh : NSAccessibilityPriorityMedium)});
        return 0;
    }
}
int zua_publish(void *state, const NativeNode *nodes, uint32_t count, const uint16_t *text, uint32_t text_len) {
    @autoreleasepool { return publish((__bridge ZuaHost *)state, nodes, count, text, text_len, NULL, NULL); }
}
int zua_publish_registered(void *state, const NativeNode *nodes, uint32_t count, const uint16_t *text, uint32_t text_len, const RecipientAuthority *keys) {
    @autoreleasepool { return publish((__bridge ZuaHost *)state, nodes, count, text, text_len, keys, NULL); }
}
/* Transformed content: frames as laid out, and their precise geometry for
   finding the element at a point. */
int zua_publish_geometry(void *state, const NativeNode *nodes, uint32_t count, const uint16_t *text, uint32_t text_len, const ZuaGeometry *geometry) {
    if (!geometry) return -2;
    @autoreleasepool { return publish((__bridge ZuaHost *)state, nodes, count, text, text_len, NULL, geometry); }
}
int zua_publish_geometry_registered(void *state, const NativeNode *nodes, uint32_t count, const uint16_t *text, uint32_t text_len, const ZuaGeometry *geometry, const RecipientAuthority *keys) {
    if (!geometry || !keys) return -2;
    @autoreleasepool { return publish((__bridge ZuaHost *)state, nodes, count, text, text_len, keys, geometry); }
}
static unsigned live_geometry;
ZuaGeometry *zua_geometry_create(void) { ZuaGeometry *g = calloc(1, sizeof(ZuaGeometry)); if (g) live_geometry++; return g; }
void zua_geometry_free(ZuaGeometry *geometry) { if (geometry) { free(geometry); live_geometry--; } }
int zua_geometry_commit(void *state, ZuaGeometry *geometry) {
    ZuaHost *host = (__bridge ZuaHost *)state;
    if (host->closed || host->geometry) return -1;
    host->geometry = geometry;
    host->geometry_active = NO;
    return 0;
}
void zua_geometry_release(void *state) {
    ZuaHost *host = (__bridge ZuaHost *)state;
    ZuaGeometry *geometry = host->geometry;
    host->geometry = NULL; host->geometry_active = NO;
    zua_geometry_free(geometry);
}
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
/* A row request still for the list and the model it was made in. */
int zua_take_collection_action(void *pointer, CollectionRowRequest *out) {
    Action *a = pointer;
    ZuaHost *host = (__bridge ZuaHost *)a->host;
    ZuaElement *el = host->closed ? nil : [host element:a->id];
    BOOL available = !host->closed && host->context && el && el->node.role == ROLE_LIST && (el->node.flags & ENABLED) &&
        memcmp(&el->recipient, &a->recipient, sizeof(RecipientAuthority)) == 0 && a->kind == 6 &&
        a->row.kind >= ROW_SELECT && a->row.kind <= ROW_REVEAL && !a->row.reserved;
    if (available) {
        CollectionBinding *binding = virtual_binding(host, registration_of(&a->recipient));
        available = collection_binding_accepts(binding, a->row.authority);
    }
    if (available) *out = a->row;
    return available;
}
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

/* The native content inside nodes of the last publication: each view, a web
   view holding its page's tree, becomes the first child of the element of
   its id; the other elements hold none. */
static void page_set(ZuaElement *el, NSView *page) {
    NSView *old = el->page;
    if (old == page) return;
    el->page = nil;
    if (old && [old respondsToSelector:@selector(setZigAccessibilityParent:)] && [old accessibilityParent] == el) [(id)old setZigAccessibilityParent:nil];
    if (page) {
        el->page = page;
        if ([page respondsToSelector:@selector(setZigAccessibilityParent:)]) [(id)page setZigAccessibilityParent:el];
    }
    NSAccessibilityPostNotification(el, NSAccessibilityLayoutChangedNotification);
}
int zua_pages(void *state, const uint64_t *ids, void *const *views, uint32_t count) {
    ZuaHost *host = (__bridge ZuaHost *)state;
    if (host->closed) return -1;
    if (count && (!ids || !views)) return -2;
    @autoreleasepool {
        BOOL changed = NO;
        for (ZuaElement *el in [host->elements allValues]) {
            NSView *page = nil;
            for (uint32_t i = 0; i < count && !page; i++) {
                if (ids[i] != el->node.id || !views[i]) continue;
                id object = (__bridge id)views[i];
                if ([object isKindOfClass:[NSView class]]) page = object;
            }
            if (el->page != page) changed = YES;
            page_set(el, page);
        }
        NSView *view = host->view;
        if (changed && view) NSAccessibilityPostNotification(view, NSAccessibilityLayoutChangedNotification);
    }
    return 0;
}

/* Registered recipients and complete lists. Everything runs on the main
   thread, which owns the App, so no lock guards them. */
size_t zua_collections_metadata_size(void) { return sizeof(ZuaCollections); }
uint32_t zua_collections_count(void) { return live_collections; }
void *zua_collections_create(void) {
    ZuaCollections *candidate = calloc(1, sizeof(ZuaCollections));
    if (candidate) live_collections++;
    return candidate;
}
void zua_collections_free(void *pointer) {
    ZuaCollections *candidate = pointer;
    if (!candidate) return;
    collection_store_release(candidate->virtuals);
    free(candidate);
    live_collections--;
}
int zua_collections_commit(void *state, void *candidate) {
    ZuaHost *host = (__bridge ZuaHost *)state;
    if (!candidate) return -2;
    if (host->closed) return -1;
    if (host->collections) return -3;
    host->collections = candidate;
    return 0;
}
static ZuaHost *owned_host(void *state) { return state && [NSThread isMainThread] ? (__bridge ZuaHost *)state : nil; }
uint32_t zua_virtuals_stats(void *state, CollectionStats *out) {
    ZuaHost *host = owned_host(state);
    if (!host || !out) return COLLECTION_INVALID;
    CollectionStore *store = host_store(host);
    if (!store) return COLLECTION_STALE;
    *out = (CollectionStats){ store->metadata_bytes, atomic_load_explicit(&store->ledger->used, memory_order_relaxed),
        store->held_model_bytes, store->provider_bytes, store->request_bytes, store->ledger->limit,
        store->provider_limit, store->request_limit, store->capacity, 0 };
    return COLLECTION_OK;
}
uint32_t zua_virtuals_commit(void *state, CollectionStore *candidate) {
    ZuaHost *host = owned_host(state);
    if (!host || !candidate) return COLLECTION_INVALID;
    if (host->closed) return COLLECTION_STALE;
    if (!host->collections || host->collections->virtuals) return COLLECTION_INVALID;
    host->collections->virtuals = candidate;
    return COLLECTION_OK;
}
uint32_t zua_virtuals_prepared(void *state) {
    ZuaHost *host = state ? (__bridge ZuaHost *)state : nil;
    return host_store(host) != NULL;
}
uint32_t zua_virtuals_install(void *state, const CollectionRegistration *key, CollectionModel *model, uint64_t revision, const uint64_t *bits, uint32_t words) {
    ZuaHost *host = owned_host(state);
    if (!host || !key) return COLLECTION_INVALID;
    CollectionStore *store = host_store(host);
    return store ? collection_store_install(store, *key, model, revision, bits, words) : COLLECTION_STALE;
}
uint32_t zua_virtuals_selection(void *state, const CollectionRegistration *key, uint64_t model, uint64_t base, uint64_t revision, const CollectionWordChange *changes, uint32_t count) {
    ZuaHost *host = owned_host(state);
    if (!host || !key) return COLLECTION_INVALID;
    return collection_store_apply(host_store(host), *key, model, base, revision, changes, count);
}
void zua_virtuals_withdraw(void *state, const CollectionRegistration *key) {
    ZuaHost *host = owned_host(state);
    CollectionStore *store = host && host->collections ? host->collections->virtuals : NULL;
    if (!store) return;
    if (key) collection_store_withdraw(store, *key);
    else collection_store_clear(store);
}
uint32_t zua_virtuals_begin_frame(void *state) {
    ZuaHost *host = owned_host(state);
    if (!host) return COLLECTION_INVALID;
    CollectionStore *store = host_store(host);
    uint64_t frame;
    return store ? collection_store_begin_frame(store, &frame) : COLLECTION_OK;
}
uint32_t zua_virtuals_stage(void *state, const CollectionRegistration *key, uint64_t model, uint64_t selection, const CollectionViewport *viewport, const CollectionMapping *mapping) {
    ZuaHost *host = owned_host(state);
    if (!host || !key || !viewport || !mapping) return COLLECTION_INVALID;
    CollectionStore *store = host_store(host);
    return store ? collection_store_stage_mapped(store, *key, store->frame, model, selection, *viewport, mapping) : COLLECTION_STALE;
}
uint32_t zua_virtuals_validate_frame(void *state) {
    ZuaHost *host = owned_host(state);
    if (!host) return COLLECTION_INVALID;
    CollectionStore *store = host_store(host);
    return store ? collection_store_preflight(store, store->frame) : COLLECTION_OK;
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
/* A row's AXIndex, or a table's AXRowCount when row is 0. */
int zua_test_row(void *element, int row) {
    id object = (__bridge id)element;
    return row ? (int)[object accessibilityIndex] : (int)[object accessibilityRowCount];
}

/* Test hooks for complete lists. The row of a list whose label is name,
   read a range at a time as VoiceOver reads large lists; a retained
   reference that zua_test_release gives back. */
void *zua_test_list_row(void *list, const char *name) {
    @autoreleasepool {
        id element = (__bridge id)list;
        NSString *wanted = [NSString stringWithUTF8String:name];
        const NSUInteger count = [element accessibilityArrayAttributeCount:NSAccessibilityRowsAttribute];
        for (NSUInteger at = 0; at < count; at += 64) {
            for (id row in [element accessibilityArrayAttributeValues:NSAccessibilityRowsAttribute index:at maxCount:64])
                if ([[row accessibilityLabel] isEqualToString:wanted]) return (__bridge_retained void *)row;
        }
        return NULL;
    }
}
void zua_test_release(void *object) { if (object) CFRelease(object); }
/* A row as VoiceOver reads it: -1 once it stands for nothing, else its
   index, with whether it is chosen, shows in its window and has the focus. */
int zua_test_row_state(void *pointer, void *handle, int *selected, int *shown, int *focused) {
    @autoreleasepool {
        id row = (__bridge id)pointer;
        if (![row accessibilityParent]) return -1;
        *selected = [row isAccessibilitySelected];
        *shown = zua_test_frame_in_window(pointer, handle);
        *focused = [row isAccessibilityFocused];
        return (int)[row accessibilityIndex];
    }
}
/* Acts on a row: 1 press, 2 scroll it into view, 3 focus, 4 unchoose. */
void zua_test_row_act(void *pointer, int kind) {
    @autoreleasepool {
        id row = (__bridge id)pointer;
        switch (kind) {
        case 1: [row accessibilityPerformPress]; break;
        case 2:
            /* As the accessibility server asks for an action by name. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [row accessibilityPerformAction:ZuaScrollToVisible];
#pragma clang diagnostic pop
            break;
        case 3: [row setAccessibilityFocused:YES]; break;
        case 4: [row setAccessibilitySelected:NO]; break;
        }
    }
}
/* A list's chosen rows (0), the rows in its viewport (1), and its rows as
   the ranged count reads them (2). */
int zua_test_list_count(void *list, int which) {
    @autoreleasepool {
        id element = (__bridge id)list;
        if (which == 0) return (int)[[element accessibilitySelectedRows] count];
        if (which == 1) return (int)[[element accessibilityVisibleRows] count];
        return (int)[element accessibilityArrayAttributeCount:NSAccessibilityChildrenAttribute];
    }
}
/* Whether an element of the window's tree holds a view among its
   children, as a web view's node holds its page, whose parent is that
   element, while the content view itself lists the view no more: 1 when
   one does, 0 when none does, -1 when the content view still lists it. */
int zua_test_page_in_tree(void *handle) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)handle;
        NSArray *top = [zua_content_view(window) accessibilityChildren] ?: @[];
        NSMutableArray *queue = [NSMutableArray array];
        for (id child in top) {
            if ([child isKindOfClass:[NSView class]] && [child respondsToSelector:@selector(setZigAccessibilityParent:)] && ![[child accessibilityParent] isKindOfClass:[NSView class]]) return -1;
            if (![child isKindOfClass:[NSView class]]) [queue addObject:child];
        }
        while (queue.count) {
            id element = queue[0];
            [queue removeObjectAtIndex:0];
            for (id child in [element accessibilityChildren] ?: @[]) {
                if ([child isKindOfClass:[NSView class]]) { if ([child accessibilityParent] == element) return 1; }
                else [queue addObject:child];
            }
        }
        return 0;
    }
}

int zua_test_child_count(void *handle) {
    NSWindow *window = (__bridge NSWindow *)handle;
    return (int)[[zua_content_view(window) accessibilityChildren] count];
}

/* The announcements posted so far; the last one's text into buffer. */
int zua_test_announcements(char *buffer, int capacity) {
    const char *utf8 = last_announcement.UTF8String ?: "";
    snprintf(buffer, (size_t)capacity, "%s", utf8);
    return (int)announcements;
}
