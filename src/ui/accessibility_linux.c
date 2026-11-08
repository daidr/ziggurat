/* The semantic tree as ATK objects, which GTK's bridge shows assistive
   technology such as Orca through AT-SPI. One root object hangs below the
   window's drawing area (the GTK accessible child host), and one object per
   node below it. Objects are kept from publication to publication by node
   ID, so a screen reader's position stays on them, and only what changed is
   signalled. Bounds are in the area's logical pixels; the area's screen and
   window origins are read when a frame is published or the window moves.
   Everything runs on the main thread, which owns the App and GTK. */
#include <gtk/gtk.h>
#include <atk/atk.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "../platform/linux_accessibility_host.h"
#include "accessibility_geometry.h"

/* accessibility.zig `Role`. */
enum {
    ROLE_WINDOW, ROLE_GROUP, ROLE_BUTTON, ROLE_TEXT, ROLE_TEXT_BOX, ROLE_CHECKBOX, ROLE_RADIO, ROLE_SWITCH, ROLE_PROGRESS,
    ROLE_RADIO_GROUP, ROLE_SLIDER, ROLE_STEPPER, ROLE_LIST, ROLE_TAB_LIST, ROLE_TAB, ROLE_TOOLBAR, ROLE_SPLITTER, ROLE_LINK,
    ROLE_DISCLOSURE, ROLE_METER, ROLE_NAVIGATION, ROLE_LIST_BOX, ROLE_LIST_ITEM, ROLE_COMBO_BOX, ROLE_TOOLTIP, ROLE_STATUS,
    ROLE_SEARCH, ROLE_IMAGE, ROLE_TREE, ROLE_TREE_ITEM, ROLE_TABLE, ROLE_TABLE_HEADER, ROLE_COLUMN_HEADER, ROLE_TABLE_ROW,
    ROLE_TOKEN_FIELD, ROLE_TOKEN, ROLE_POPUP, ROLE_CALENDAR, ROLE_COLOR_WELL, ROLE_DIALOG, ROLE_ALERT_DIALOG, ROLE_MENU,
    ROLE_MENU_ITEM, ROLE_MENU_ITEM_CHECKBOX, ROLE_MENU_ITEM_RADIO, ROLE_REGION, ROLE_LOG, ROLE_TIMER, ROLE_ALERT,
    ROLE_SEPARATOR, ROLE_ROW_HEADER, ROLE_OPTION, ROLE_ARTICLE, ROLE_CELL, ROLE_HEADING,
    ROLE_GRID, ROLE_TREE_GRID, ROLE_DELETION, ROLE_INSERTION, ROLE_COUNT
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
    /* NativeState: FOCUSABLE_DISABLED, BUSY, SELECTABLE, SELECTED,
       VERTICAL, SEARCH, HORIZONTAL and MULTI_LINE, then the popup kind (bits 8 to 10), current (11 to 13),
       sort (14, 15) and autocomplete (16, 17). */
    uint32_t states;
    uint32_t role_description_start, role_description_len, key_shortcuts_start, key_shortcuts_len;
    /* Rows and columns of a table or grid, built or not (aria-rowcount,
       aria-colcount); 0 for those built. */
    uint32_t value_text_start, value_text_len, row_count, column_count;
    /* The node this one controls (aria-controls), 0 for none. */
    uint64_t controls;
    /* A row's or cell's place among all rows and columns from 1
       (aria-rowindex, aria-colindex); 0 when not given. */
    uint32_t row_index, column_index;
    /* The nodes describing it (aria-describedby) and holding its error
       message (aria-errormessage), 0 for none. */
    uint64_t described_by, error_message;
} NativeNode;
_Static_assert(sizeof(NativeNode) == 208, "semantic node ABI");
enum { FOCUSABLE_DISABLED = 1, BUSY = 2, SELECTABLE = 4, SELECTED = 8, VERTICAL = 16, SEARCH = 32, HORIZONTAL = 64, MULTI_LINE = 128 };
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

static unsigned live_hosts, live_nodes, live_actions;

typedef struct Host Host;
typedef struct Node Node;

/* What a node shows assistive technology, from its last publication. */
struct Node {
    AtkObject *obj; /* owned */
    GType type;
    Host *host;
    Node *parent;
    GPtrArray *children; /* Node*, borrowed from host->nodes */
    NativeNode n;
    char *name, *description;
    /* What the app calls its role (aria-roledescription), the keys that
       press it (aria-keyshortcuts) and the text of a range's value
       (aria-valuetext); NULL for none. */
    char *role_description, *key_shortcuts, *value_text;
    /* The value as characters, which ATK's offsets count, and as UTF-8. */
    gunichar *chars;
    glong count;
    char *value;
    glong selection_start, selection_end; /* in characters */
    RecipientAuthority recipient;
    uint64_t *chosen;
    guint chosen_len;
    uint32_t index; /* in its publication, for its geometry */
    /* The accessible of native content inside the node, as a web view's
       AtkSocket holding its page's tree: the node's first child. Owned. */
    AtkObject *page;
};

struct Host {
    unsigned refs;
    ZuaEnqueue enqueue;
    void *context;
    gboolean closed, updating;
    NativeWindow *native;
    ZlgAccessibilityBinding *binding;
    AtkObject *root;
    GHashTable *nodes; /* id -> Node* (owned) */
    GPtrArray *top; /* Node*, borrowed */
    uint64_t focus;
    gboolean has_focus;
    ZlgAccessibilityPosition position;
    gboolean positioned;
    /* The precise geometry of transformed content, while published. */
    ZuaGeometry *geometry;
    gboolean geometry_active;
};

/* ------------------------------------------------------------------ */
/* Roles and what they take. */

static gboolean ranged(uint32_t role) { return role == ROLE_PROGRESS || role == ROLE_SLIDER || role == ROLE_STEPPER || role == ROLE_METER || role == ROLE_SPLITTER; }
static gboolean fixed_range(uint32_t role) { return role == ROLE_PROGRESS || role == ROLE_METER; }
static gboolean toggle(uint32_t role) { return role == ROLE_CHECKBOX || role == ROLE_RADIO || role == ROLE_SWITCH || role == ROLE_MENU_ITEM_CHECKBOX || role == ROLE_MENU_ITEM_RADIO; }
static gboolean textual(uint32_t role) { return role == ROLE_TEXT_BOX || role == ROLE_COMBO_BOX || role == ROLE_TOKEN_FIELD; }
static gboolean menu_item(uint32_t role) { return role == ROLE_MENU_ITEM || role == ROLE_MENU_ITEM_CHECKBOX || role == ROLE_MENU_ITEM_RADIO; }
static gboolean row(uint32_t role) { return role == ROLE_LIST_ITEM || role == ROLE_TREE_ITEM || role == ROLE_TABLE_ROW || role == ROLE_OPTION; }
/* Cells of a table, headers included. */
static gboolean cell(uint32_t role) { return role == ROLE_CELL || role == ROLE_COLUMN_HEADER || role == ROLE_ROW_HEADER; }
static gboolean rows_container(uint32_t role) { return role == ROLE_LIST || role == ROLE_LIST_BOX || role == ROLE_TREE || role == ROLE_TABLE ||
        role == ROLE_GRID || role == ROLE_TREE_GRID || role == ROLE_TAB_LIST ||
    role == ROLE_GRID || role == ROLE_TREE_GRID; }
static gboolean item(uint32_t role) { return role == ROLE_RADIO || role == ROLE_TAB || row(role); }
/* Roles whose activation is a press, as UI Automation's Invoke, Toggle,
   SelectionItem and ExpandCollapse are on Windows. */
static gboolean pressable(uint32_t role) {
    return role == ROLE_BUTTON || role == ROLE_LINK || role == ROLE_COLUMN_HEADER || role == ROLE_COLOR_WELL || menu_item(role) ||
        item(role) || toggle(role) || role == ROLE_DISCLOSURE || role == ROLE_COMBO_BOX || role == ROLE_TOKEN;
}
static gboolean focusable(uint32_t role) {
    return pressable(role) || role == ROLE_TEXT_BOX || role == ROLE_SLIDER || role == ROLE_STEPPER ||
        role == ROLE_SPLITTER || role == ROLE_LIST || role == ROLE_LIST_BOX || role == ROLE_TREE || role == ROLE_TABLE ||
        role == ROLE_CALENDAR || role == ROLE_TOKEN_FIELD;
}
/* A tree item that opens and closes. */
static gboolean expandable_item(const NativeNode *n) { return n->role == ROLE_TREE_ITEM && (n->flags & EXPANDABLE); }

static AtkRole atk_role_of(const NativeNode *n) {
    switch (n->role) {
    case ROLE_GROUP: return ATK_ROLE_PANEL;
    case ROLE_BUTTON: case ROLE_COLOR_WELL: case ROLE_TOKEN: return ATK_ROLE_PUSH_BUTTON;
    case ROLE_TEXT: return ATK_ROLE_LABEL;
    case ROLE_TEXT_BOX: case ROLE_TOKEN_FIELD: return (n->flags & PASSWORD) ? ATK_ROLE_PASSWORD_TEXT : ATK_ROLE_ENTRY;
    case ROLE_CHECKBOX: return ATK_ROLE_CHECK_BOX;
    case ROLE_RADIO: return ATK_ROLE_RADIO_BUTTON;
    case ROLE_SWITCH: return ATK_ROLE_TOGGLE_BUTTON;
    case ROLE_PROGRESS: return ATK_ROLE_PROGRESS_BAR;
    case ROLE_RADIO_GROUP: return ATK_ROLE_PANEL;
    case ROLE_SLIDER: return ATK_ROLE_SLIDER;
    case ROLE_STEPPER: return ATK_ROLE_SPIN_BUTTON;
    case ROLE_LIST: return (n->flags & MULTIPLE) ? ATK_ROLE_LIST_BOX : ATK_ROLE_LIST;
    case ROLE_LIST_BOX: return ATK_ROLE_LIST_BOX;
    case ROLE_TAB_LIST: return ATK_ROLE_PAGE_TAB_LIST;
    case ROLE_TAB: return ATK_ROLE_PAGE_TAB;
    case ROLE_TOOLBAR: return ATK_ROLE_TOOL_BAR;
    case ROLE_SPLITTER: return ATK_ROLE_SEPARATOR;
    case ROLE_LINK: return ATK_ROLE_LINK;
    /* Checked while open, as GTK's expanders. */
    case ROLE_DISCLOSURE: return ATK_ROLE_TOGGLE_BUTTON;
    case ROLE_METER: return ATK_ROLE_LEVEL_BAR;
    case ROLE_NAVIGATION: return ATK_ROLE_LANDMARK;
    case ROLE_LIST_ITEM: return ATK_ROLE_LIST_ITEM;
    case ROLE_COMBO_BOX: return ATK_ROLE_COMBO_BOX;
    case ROLE_TOOLTIP: return ATK_ROLE_TOOL_TIP;
    case ROLE_STATUS: return ATK_ROLE_STATUSBAR;
    case ROLE_SEARCH: return ATK_ROLE_LANDMARK;
    case ROLE_IMAGE: return ATK_ROLE_IMAGE;
    case ROLE_TREE: return ATK_ROLE_TREE;
    case ROLE_TREE_ITEM: return ATK_ROLE_TREE_ITEM;
    case ROLE_TABLE: return ATK_ROLE_TABLE;
    case ROLE_TABLE_HEADER: return ATK_ROLE_PANEL;
    case ROLE_COLUMN_HEADER: return ATK_ROLE_COLUMN_HEADER;
    case ROLE_TABLE_ROW: return ATK_ROLE_TABLE_ROW;
    case ROLE_POPUP: return ATK_ROLE_POPUP_MENU;
    case ROLE_CALENDAR: return ATK_ROLE_CALENDAR;
    case ROLE_DIALOG: return ATK_ROLE_DIALOG;
    case ROLE_ALERT_DIALOG: return ATK_ROLE_ALERT;
    case ROLE_MENU: return ATK_ROLE_MENU;
    case ROLE_MENU_ITEM: return ATK_ROLE_MENU_ITEM;
    case ROLE_MENU_ITEM_CHECKBOX: return ATK_ROLE_CHECK_MENU_ITEM;
    case ROLE_MENU_ITEM_RADIO: return ATK_ROLE_RADIO_MENU_ITEM;
    /* A landmark, whose xml-roles attribute says which, as Chromium's. */
    case ROLE_REGION: return ATK_ROLE_LANDMARK;
    case ROLE_LOG: return ATK_ROLE_LOG;
    case ROLE_TIMER: return ATK_ROLE_TIMER;
    case ROLE_ALERT: return ATK_ROLE_NOTIFICATION;
    case ROLE_SEPARATOR: return ATK_ROLE_SEPARATOR;
    case ROLE_ROW_HEADER: return ATK_ROLE_ROW_HEADER;
    case ROLE_OPTION: return ATK_ROLE_LIST_ITEM;
    case ROLE_ARTICLE: return ATK_ROLE_ARTICLE;
    case ROLE_CELL: return ATK_ROLE_TABLE_CELL;
    case ROLE_HEADING: return ATK_ROLE_HEADING;
    /* Tables whose cells take the focus, with xml-roles saying which. */
    case ROLE_GRID: return ATK_ROLE_TABLE;
    case ROLE_TREE_GRID: return ATK_ROLE_TREE_TABLE;
    case ROLE_DELETION: return ATK_ROLE_CONTENT_DELETION;
    case ROLE_INSERTION: return ATK_ROLE_CONTENT_INSERTION;
    default: return ATK_ROLE_PANEL;
    }
}

/* ------------------------------------------------------------------ */
/* GObject types: the root, and nodes by the interfaces they take. */

typedef struct ZuaRoot { AtkObject parent; Host *host; gboolean retired; } ZuaRoot;
typedef struct ZuaRootClass { AtkObjectClass parent; } ZuaRootClass;
typedef struct ZuaNode { AtkObject parent; Node *node; } ZuaNode;
typedef struct ZuaNodeClass { AtkObjectClass parent; } ZuaNodeClass;

static void zua_root_component_init(AtkComponentIface *iface);
static void zua_node_component_init(AtkComponentIface *iface);
static void zua_node_action_init(AtkActionIface *iface);
static void zua_range_value_init(AtkValueIface *iface);
static void zua_text_text_init(AtkTextIface *iface);
static void zua_editable_editable_init(AtkEditableTextIface *iface);
static void zua_selection_selection_init(AtkSelectionIface *iface);

G_DEFINE_TYPE_WITH_CODE(ZuaRoot, zua_root, ATK_TYPE_OBJECT, G_IMPLEMENT_INTERFACE(ATK_TYPE_COMPONENT, zua_root_component_init))
G_DEFINE_TYPE_WITH_CODE(ZuaNode, zua_node, ATK_TYPE_OBJECT,
    G_IMPLEMENT_INTERFACE(ATK_TYPE_COMPONENT, zua_node_component_init) G_IMPLEMENT_INTERFACE(ATK_TYPE_ACTION, zua_node_action_init))
typedef ZuaNode ZuaRange; typedef ZuaNodeClass ZuaRangeClass;
typedef ZuaNode ZuaText; typedef ZuaNodeClass ZuaTextClass;
typedef ZuaNode ZuaEditable; typedef ZuaNodeClass ZuaEditableClass;
typedef ZuaNode ZuaSelection; typedef ZuaNodeClass ZuaSelectionClass;
G_DEFINE_TYPE_WITH_CODE(ZuaRange, zua_range, zua_node_get_type(), G_IMPLEMENT_INTERFACE(ATK_TYPE_VALUE, zua_range_value_init))
G_DEFINE_TYPE_WITH_CODE(ZuaText, zua_text, zua_node_get_type(), G_IMPLEMENT_INTERFACE(ATK_TYPE_TEXT, zua_text_text_init))
G_DEFINE_TYPE_WITH_CODE(ZuaEditable, zua_editable, zua_text_get_type(), G_IMPLEMENT_INTERFACE(ATK_TYPE_EDITABLE_TEXT, zua_editable_editable_init))
G_DEFINE_TYPE_WITH_CODE(ZuaSelection, zua_selection, zua_node_get_type(), G_IMPLEMENT_INTERFACE(ATK_TYPE_SELECTION, zua_selection_selection_init))

static void zua_range_class_init(ZuaRangeClass *klass) { (void)klass; }
static void zua_range_init(ZuaRange *self) { (void)self; }
static void zua_text_class_init(ZuaTextClass *klass) { (void)klass; }
static void zua_text_init(ZuaText *self) { (void)self; }
static void zua_editable_class_init(ZuaEditableClass *klass) { (void)klass; }
static void zua_editable_init(ZuaEditable *self) { (void)self; }
static void zua_selection_class_init(ZuaSelectionClass *klass) { (void)klass; }
static void zua_selection_init(ZuaSelection *self) { (void)self; }

static GType type_of(const NativeNode *n) {
    if (ranged(n->role)) return zua_range_get_type();
    if (textual(n->role)) return zua_editable_get_type();
    if (n->role == ROLE_TEXT) return zua_text_get_type();
    if (rows_container(n->role)) return zua_selection_get_type();
    return zua_node_get_type();
}

static Node *node_of(gpointer obj) {
    if (!obj || !G_TYPE_CHECK_INSTANCE_TYPE(obj, zua_node_get_type())) return NULL;
    Node *node = ((ZuaNode *)obj)->node;
    if (!node || !node->host || node->host->closed) return NULL;
    return node;
}
static Host *root_host(gpointer obj) {
    ZuaRoot *root = obj;
    if (root->retired || !root->host || root->host->closed) return NULL;
    return root->host;
}

/* ------------------------------------------------------------------ */
/* Geometry. */

/* The area's origin for ATK coordinates: the screen, its toplevel window,
   or (for a node) its parent. Returns FALSE where it has none. */
static gboolean origin(Host *host, AtkCoordType coords, double *x, double *y) {
    *x = 0; *y = 0;
    if (!host->positioned) return FALSE;
    const ZlgAccessibilityPosition *p = &host->position;
    if (coords == ATK_XY_SCREEN) {
        if (!(p->flags & ZLG_ACCESSIBILITY_SCREEN_ORIGIN)) return FALSE;
        *x = p->screen_x; *y = p->screen_y;
        return TRUE;
    }
    if (coords == ATK_XY_WINDOW) {
        if (!(p->flags & ZLG_ACCESSIBILITY_WINDOW_ORIGIN)) return FALSE;
        *x = p->window_x; *y = p->window_y;
        return TRUE;
    }
    return TRUE;
}
static void node_extents(Node *node, gint *x, gint *y, gint *width, gint *height, AtkCoordType coords) {
    double bx = node->n.x, by = node->n.y;
    if (coords == ATK_XY_PARENT) {
        if (node->parent) { bx -= node->parent->n.x; by -= node->parent->n.y; }
    } else {
        double ox, oy;
        if (!origin(node->host, coords, &ox, &oy)) {
            if (x) *x = G_MININT; if (y) *y = G_MININT;
            if (width) *width = (gint)lround(node->n.width); if (height) *height = (gint)lround(node->n.height);
            return;
        }
        bx += ox; by += oy;
    }
    if (x) *x = (gint)floor(bx);
    if (y) *y = (gint)floor(by);
    if (width) *width = (gint)lround(node->n.width);
    if (height) *height = (gint)lround(node->n.height);
}
static gboolean node_contains(Node *node, gint px, gint py, AtkCoordType coords) {
    gint x, y, w, h;
    node_extents(node, &x, &y, &w, &h, coords);
    if (x == G_MININT || px < x || py < y || px >= x + w || py >= y + h) return FALSE;
    Host *host = node->host;
    if (!host->geometry_active) return TRUE;
    /* Inside the box of a turned or clipped node: inside the node itself. */
    double lx = px, ly = py, ox = 0, oy = 0;
    if (coords == ATK_XY_PARENT) {
        if (node->parent) { lx += node->parent->n.x; ly += node->parent->n.y; }
    } else if (origin(host, coords, &ox, &oy)) { lx -= ox; ly -= oy; }
    return zua_geometry_hit(host->geometry, node->index, lx + 0.5, ly + 0.5);
}
/* A new reference to the topmost of nodes at a point: later nodes are
   deeper or drawn above. */
static AtkObject *node_at(GPtrArray *nodes, gint x, gint y, AtkCoordType coords) {
    if (!nodes) return NULL;
    for (guint i = nodes->len; i > 0; i--) {
        Node *node = g_ptr_array_index(nodes, i - 1);
        if (!node_contains(node, x, y, coords)) continue;
        AtkObject *deeper = node_at(node->children, x, y, coords);
        if (!deeper && node->page) return g_object_ref(node->page);
        return deeper ? deeper : g_object_ref(node->obj);
    }
    return NULL;
}

/* ------------------------------------------------------------------ */
/* Actions: requests the App's thread takes from the queue. */

typedef struct Action {
    Host *host; /* one ref */
    uint32_t kind;
    uint64_t id;
    uint16_t *value;
    uint32_t value_len, start, end;
    double number;
    RecipientAuthority recipient;
} Action;

static void host_ref(Host *host) { host->refs++; }
static void zua_geometry_free_ptr(ZuaGeometry *geometry);
static void host_unref(Host *host) {
    if (--host->refs) return;
    zua_geometry_free_ptr(host->geometry);
    g_hash_table_unref(host->nodes);
    g_ptr_array_unref(host->top);
    g_free(host);
    live_hosts--;
}

/* UTF-16 units before character `index` of a node's value. */
static uint32_t units_before(const Node *node, glong index) {
    uint32_t units = 0;
    for (glong i = 0; i < index && i < node->count; i++) units += node->chars[i] > 0xFFFF ? 2 : 1;
    return units;
}
static gboolean request(Node *node, uint32_t kind, const char *text, glong start, glong end, double number) {
    Host *host = node->host;
    const NativeNode *n = &node->n;
    if (host->closed || host->updating || !host->context || !host->enqueue) return FALSE;
    if (!(n->flags & ENABLED)) return FALSE;
    if ((kind == ACTION_INVOKE && !pressable(n->role)) || (kind == ACTION_FOCUS && !focusable(n->role)) ||
        ((kind == ACTION_SET_VALUE || kind == ACTION_SELECT_TEXT) && !textual(n->role)) ||
        (kind == ACTION_SET_RANGE && !ranged(n->role) && n->role != ROLE_TREE_ITEM && n->role != ROLE_TABLE_ROW))
        return FALSE;
    if (kind == ACTION_SET_VALUE && (n->flags & READ_ONLY)) return FALSE;
    if (kind == ACTION_SET_RANGE && ranged(n->role)) {
        if (fixed_range(n->role) || (n->flags & READ_ONLY) || !isfinite(number)) return FALSE;
        if (number < n->range_minimum) number = n->range_minimum;
        if (number > n->range_maximum) number = n->range_maximum;
    }
    Action *a = g_try_new0(Action, 1);
    if (!a) return FALSE;
    if (kind == ACTION_SET_VALUE) {
        glong written = 0;
        a->value = (uint16_t *)g_utf8_to_utf16(text ? text : "", -1, NULL, &written, NULL);
        if (!a->value) { g_free(a); return FALSE; }
        a->value_len = (uint32_t)written;
    }
    if (kind == ACTION_SELECT_TEXT) {
        if (start < 0) start = 0;
        if (end < start) end = start;
        if (start > node->count) start = node->count;
        if (end > node->count) end = node->count;
        a->start = units_before(node, start);
        a->end = units_before(node, end);
    }
    host_ref(host);
    a->host = host;
    a->kind = kind; a->id = n->id; a->number = number;
    a->recipient = node->recipient;
    live_actions++;
    if (!host->enqueue(host->context, a)) {
        host_unref(host); g_free(a->value); g_free(a); live_actions--;
        return FALSE;
    }
    return TRUE;
}

/* ------------------------------------------------------------------ */
/* AtkObject. */

static gint root_n_children(AtkObject *obj) {
    Host *host = root_host(obj);
    return host ? (gint)host->top->len : 0;
}
static AtkObject *root_ref_child(AtkObject *obj, gint i) {
    Host *host = root_host(obj);
    if (!host || i < 0 || (guint)i >= host->top->len) return NULL;
    return g_object_ref(((Node *)g_ptr_array_index(host->top, i))->obj);
}
static AtkStateSet *root_ref_state_set(AtkObject *obj) {
    AtkStateSet *set = ATK_OBJECT_CLASS(zua_root_parent_class)->ref_state_set(obj);
    if (root_host(obj)) {
        atk_state_set_add_state(set, ATK_STATE_ENABLED);
        atk_state_set_add_state(set, ATK_STATE_SENSITIVE);
        atk_state_set_add_state(set, ATK_STATE_VISIBLE);
        atk_state_set_add_state(set, ATK_STATE_SHOWING);
    } else atk_state_set_add_state(set, ATK_STATE_DEFUNCT);
    return set;
}
static gint root_index_in_parent(AtkObject *obj) { return root_host(obj) ? 0 : -1; }
static void zua_root_class_init(ZuaRootClass *klass) {
    AtkObjectClass *object = ATK_OBJECT_CLASS(klass);
    object->get_n_children = root_n_children;
    object->ref_child = root_ref_child;
    object->ref_state_set = root_ref_state_set;
    object->get_index_in_parent = root_index_in_parent;
}
static void zua_root_init(ZuaRoot *self) { (void)self; }

static void root_extents(AtkComponent *component, gint *x, gint *y, gint *width, gint *height, AtkCoordType coords) {
    Host *host = root_host(component);
    if (x) *x = G_MININT; if (y) *y = G_MININT; if (width) *width = 0; if (height) *height = 0;
    if (!host || !host->positioned) return;
    double ox = 0, oy = 0;
    if (coords == ATK_XY_PARENT || origin(host, coords, &ox, &oy)) {
        if (x) *x = (gint)ox; if (y) *y = (gint)oy;
    }
    if (width) *width = (gint)host->position.width;
    if (height) *height = (gint)host->position.height;
}
static AtkObject *root_at_point(AtkComponent *component, gint x, gint y, AtkCoordType coords) {
    Host *host = root_host(component);
    return host ? node_at(host->top, x, y, coords) : NULL;
}
static void zua_root_component_init(AtkComponentIface *iface) {
    iface->get_extents = root_extents;
    iface->ref_accessible_at_point = root_at_point;
}

static gint node_n_children(AtkObject *obj) {
    Node *node = node_of(obj);
    return node ? (gint)node->children->len + (node->page ? 1 : 0) : 0;
}
static AtkObject *node_ref_child(AtkObject *obj, gint i) {
    Node *node = node_of(obj);
    if (node && node->page && i == 0) return g_object_ref(node->page);
    if (node && node->page) i--;
    if (!node || i < 0 || (guint)i >= node->children->len) return NULL;
    return g_object_ref(((Node *)g_ptr_array_index(node->children, i))->obj);
}
static gint node_index_in_parent(AtkObject *obj) {
    Node *node = node_of(obj);
    if (!node) return -1;
    GPtrArray *siblings = node->parent ? node->parent->children : node->host->top;
    guint index;
    return g_ptr_array_find(siblings, node, &index) ? (gint)index : -1;
}
/* A list's rows, or a tab list's tabs, are chosen by it. */
static gboolean chooses(const Node *node) {
    return node->parent && rows_container(node->parent->n.role) && (row(node->n.role) || node->n.role == ROLE_TAB);
}
static void add_states(AtkStateSet *set, const Node *node) {
    const NativeNode *n = &node->n;
    atk_state_set_add_state(set, ATK_STATE_VISIBLE);
    if (!(n->flags & OFFSCREEN)) atk_state_set_add_state(set, ATK_STATE_SHOWING);
    if (n->flags & ENABLED) { atk_state_set_add_state(set, ATK_STATE_ENABLED); atk_state_set_add_state(set, ATK_STATE_SENSITIVE); }
    /* What is only unavailable (aria-disabled) stays focusable. */
    if (focusable(n->role) && (n->flags & ENABLED || n->states & FOCUSABLE_DISABLED)) atk_state_set_add_state(set, ATK_STATE_FOCUSABLE);
    if (node->host->has_focus && node->host->focus == n->id) atk_state_set_add_state(set, ATK_STATE_FOCUSED);
    if (toggle(n->role)) atk_state_set_add_state(set, ATK_STATE_CHECKABLE);
    if (chooses(node) || row(n->role) || n->role == ROLE_TAB) {
        atk_state_set_add_state(set, ATK_STATE_SELECTABLE);
        if (n->flags & CHECKED) atk_state_set_add_state(set, ATK_STATE_SELECTED);
    } else if (cell(n->role) && (n->states & SELECTABLE)) {
        /* Cells where they are chosen or not, as ARIA's gridcells. */
        atk_state_set_add_state(set, ATK_STATE_SELECTABLE);
        if (n->states & SELECTED) atk_state_set_add_state(set, ATK_STATE_SELECTED);
    } else if (n->flags & CHECKED) atk_state_set_add_state(set, ATK_STATE_CHECKED);
    if (node_popup(n) != POPUP_NONE) atk_state_set_add_state(set, ATK_STATE_HAS_POPUP);
    if (n->states & BUSY) atk_state_set_add_state(set, ATK_STATE_BUSY);
    /* The current item is active, as Chromium's aria-current is. */
    if (node_current(n) != CURRENT_NONE) atk_state_set_add_state(set, ATK_STATE_ACTIVE);
    /* A field whose suggestions complete it, as Core-AAM maps
       aria-autocomplete, with its autocomplete attribute. */
    if (node_autocomplete(n) != AUTOCOMPLETE_NONE) atk_state_set_add_state(set, ATK_STATE_SUPPORTS_AUTOCOMPLETION);
    if (n->role == ROLE_DISCLOSURE) {
        atk_state_set_add_state(set, ATK_STATE_EXPANDABLE);
        if (n->flags & (EXPANDED | CHECKED)) { atk_state_set_add_state(set, ATK_STATE_CHECKED); atk_state_set_add_state(set, ATK_STATE_EXPANDED); }
    }
    if (n->role == ROLE_COMBO_BOX) atk_state_set_add_state(set, ATK_STATE_EXPANDABLE);
    if (n->flags & EXPANDABLE) atk_state_set_add_state(set, ATK_STATE_EXPANDABLE);
    if (n->flags & EXPANDED) atk_state_set_add_state(set, ATK_STATE_EXPANDED);
    if (n->flags & MIXED) atk_state_set_add_state(set, ATK_STATE_INDETERMINATE);
    if (n->role == ROLE_PROGRESS && n->range_minimum == n->range_maximum) atk_state_set_add_state(set, ATK_STATE_INDETERMINATE);
    if (n->flags & MULTIPLE) atk_state_set_add_state(set, ATK_STATE_MULTISELECTABLE);
    if (n->flags & INVALID) atk_state_set_add_state(set, ATK_STATE_INVALID_ENTRY);
    if (n->flags & REQUIRED) atk_state_set_add_state(set, ATK_STATE_REQUIRED);
    /* Which way it runs: as the application tells (aria-orientation),
       else a slider's or splitter's longer side, and a separator across
       as GtkSeparator's. */
    if (n->states & VERTICAL && n->role != ROLE_SEPARATOR) atk_state_set_add_state(set, ATK_STATE_VERTICAL);
    else if (n->states & HORIZONTAL) atk_state_set_add_state(set, ATK_STATE_HORIZONTAL);
    else if (n->role == ROLE_SLIDER || n->role == ROLE_SPLITTER) atk_state_set_add_state(set, n->width >= n->height ? ATK_STATE_HORIZONTAL : ATK_STATE_VERTICAL);
    if (n->role == ROLE_SEPARATOR) atk_state_set_add_state(set, (n->states & VERTICAL) ? ATK_STATE_VERTICAL : ATK_STATE_HORIZONTAL);
    if (textual(n->role)) {
        atk_state_set_add_state(set, ATK_STATE_SELECTABLE_TEXT);
        atk_state_set_add_state(set, (n->role == ROLE_TEXT_BOX && n->states & MULTI_LINE) ? ATK_STATE_MULTI_LINE : ATK_STATE_SINGLE_LINE);
        atk_state_set_add_state(set, (n->flags & READ_ONLY) ? ATK_STATE_READ_ONLY : ATK_STATE_EDITABLE);
    } else if (n->flags & READ_ONLY) atk_state_set_add_state(set, ATK_STATE_READ_ONLY);
}
static AtkStateSet *node_ref_state_set(AtkObject *obj) {
    AtkStateSet *set = atk_state_set_new();
    Node *node = node_of(obj);
    if (!node) { atk_state_set_add_state(set, ATK_STATE_DEFUNCT); return set; }
    add_states(set, node);
    return set;
}
static AtkAttributeSet *add_attribute(AtkAttributeSet *list, const char *name, char *value) {
    AtkAttribute *attribute = g_new0(AtkAttribute, 1);
    attribute->name = g_strdup(name);
    attribute->value = value;
    return g_slist_append(list, attribute);
}
/* The place of a row among its list's, which Orca reads as "5 of 10". */
static AtkAttributeSet *node_attributes(AtkObject *obj) {
    Node *node = node_of(obj);
    if (!node) return NULL;
    AtkAttributeSet *list = NULL;
    if (chooses(node)) {
        guint position = 0, size = 0;
        for (guint i = 0; i < node->parent->children->len; i++) {
            Node *sibling = g_ptr_array_index(node->parent->children, i);
            if (sibling->n.role != node->n.role) continue;
            size++;
            if (sibling == node) position = size;
        }
        /* A list built only in view says where its rows are among all. */
        if (node->n.position > 0) position = node->n.position;
        if (node->n.set_size > 0) size = node->n.set_size;
        else if (node->parent->n.set_size > 0) size = node->parent->n.set_size;
        list = add_attribute(list, "posinset", g_strdup_printf("%u", position));
        list = add_attribute(list, "setsize", g_strdup_printf("%u", size));
    }
    if (node->n.role == ROLE_TREE_ITEM) {
        guint level = 1;
        for (Node *up = node->parent; up && up->n.role == ROLE_TREE_ITEM; up = up->parent) level++;
        if (node->n.level > 0) level = node->n.level;
        list = add_attribute(list, "level", g_strdup_printf("%u", level));
    }
    const NativeNode *n = &node->n;
    /* The ARIA role of a landmark or a live region, which its ATK role
       does not say all of. */
    const char *xml = n->role == ROLE_NAVIGATION ? "navigation" : n->role == ROLE_SEARCH ? "search" : n->role == ROLE_REGION ? "region" :
        n->role == ROLE_LOG ? "log" : n->role == ROLE_TIMER ? "timer" : n->role == ROLE_ALERT ? "alert" : n->role == ROLE_STATUS ? "status" :
        n->role == ROLE_GRID ? "grid" : n->role == ROLE_TREE_GRID ? "treegrid" : (textual(n->role) && n->states & SEARCH) ? "searchbox" : NULL;
    if (xml) list = add_attribute(list, "xml-roles", g_strdup(xml));
    /* How a live region and what is inside it are read, as Chromium's say
       aria-live, aria-atomic and aria-relevant. */
    for (const Node *up = node; up; up = up->parent) {
        uint32_t role = up->n.role;
        const char *live = role == ROLE_STATUS || role == ROLE_LOG ? "polite" : role == ROLE_ALERT ? "assertive" : NULL;
        if (!live) continue;
        const char *atomic = role == ROLE_LOG ? "false" : "true";
        if (up == node) {
            list = add_attribute(list, "live", g_strdup(live));
            list = add_attribute(list, "atomic", g_strdup(atomic));
            list = add_attribute(list, "relevant", g_strdup("additions text"));
        }
        list = add_attribute(list, "container-live", g_strdup(live));
        list = add_attribute(list, "container-atomic", g_strdup(atomic));
        list = add_attribute(list, "container-relevant", g_strdup("additions text"));
        list = add_attribute(list, "container-live-role", g_strdup(role == ROLE_STATUS ? "status" : role == ROLE_LOG ? "log" : "alert"));
        break;
    }
    if (node_current(n) != CURRENT_NONE) list = add_attribute(list, "current", g_strdup(current_names[node_current(n)]));
    if (node_autocomplete(n) != AUTOCOMPLETE_NONE) list = add_attribute(list, "autocomplete", g_strdup(autocomplete_names[node_autocomplete(n)]));
    if (node_popup(n) != POPUP_NONE) list = add_attribute(list, "haspopup", g_strdup(popup_names[node_popup(n)]));
    /* The order of the column a table is sorted by, as Chromium says. */
    if (node_sort(n) != SORT_NONE) list = add_attribute(list, "sort", g_strdup(sort_names[node_sort(n)]));
    if (node->role_description) list = add_attribute(list, "roledescription", g_strdup(node->role_description));
    /* The keys that press or focus it, as Chromium says. */
    if (node->key_shortcuts) list = add_attribute(list, "keyshortcuts", g_strdup(node->key_shortcuts));
    /* A table's or grid's rows and columns, built or not, and where a row
       or cell is among them, from 1, as Chromium says aria-rowcount and
       the like. */
    if (n->row_count > 0) list = add_attribute(list, "rowcount", g_strdup_printf("%u", n->row_count));
    if (n->column_count > 0) list = add_attribute(list, "colcount", g_strdup_printf("%u", n->column_count));
    if (n->row_index > 0) list = add_attribute(list, "rowindex", g_strdup_printf("%u", n->row_index));
    if (n->column_index > 0) list = add_attribute(list, "colindex", g_strdup_printf("%u", n->column_index));
    return list;
}
/* The node a node controls (controller-for), and those controlling it
   (controlled-by), as ARIA's aria-controls; with its description and
   error message, and those it describes or is the error of. */
static AtkRelationSet *node_ref_relation_set(AtkObject *obj) {
    AtkRelationSet *set = atk_relation_set_new();
    Node *node = node_of(obj);
    if (!node) return set;
    if (node->n.controls) {
        Node *target = g_hash_table_lookup(node->host->nodes, &node->n.controls);
        if (target) atk_relation_set_add_relation_by_type(set, ATK_RELATION_CONTROLLER_FOR, target->obj);
    }
    /* What describes it (aria-describedby), and the message of its error
       while it is invalid (aria-errormessage). */
    if (node->n.described_by) {
        Node *target = g_hash_table_lookup(node->host->nodes, &node->n.described_by);
        if (target) atk_relation_set_add_relation_by_type(set, ATK_RELATION_DESCRIBED_BY, target->obj);
    }
    if (node->n.error_message && (node->n.flags & INVALID)) {
        Node *target = g_hash_table_lookup(node->host->nodes, &node->n.error_message);
        if (target) atk_relation_set_add_relation_by_type(set, ATK_RELATION_ERROR_MESSAGE, target->obj);
    }
    GHashTableIter iter;
    gpointer key, value;
    g_hash_table_iter_init(&iter, node->host->nodes);
    while (g_hash_table_iter_next(&iter, &key, &value)) {
        Node *other = value;
        if (other->n.controls == node->n.id) atk_relation_set_add_relation_by_type(set, ATK_RELATION_CONTROLLED_BY, other->obj);
        if (other->n.described_by == node->n.id) atk_relation_set_add_relation_by_type(set, ATK_RELATION_DESCRIPTION_FOR, other->obj);
        if (other->n.error_message == node->n.id && (other->n.flags & INVALID)) atk_relation_set_add_relation_by_type(set, ATK_RELATION_ERROR_FOR, other->obj);
    }
    return set;
}
static void zua_node_class_init(ZuaNodeClass *klass) {
    AtkObjectClass *object = ATK_OBJECT_CLASS(klass);
    object->ref_relation_set = node_ref_relation_set;
    object->get_n_children = node_n_children;
    object->ref_child = node_ref_child;
    object->get_index_in_parent = node_index_in_parent;
    object->ref_state_set = node_ref_state_set;
    object->get_attributes = node_attributes;
}
static void zua_node_init(ZuaNode *self) { (void)self; }

/* AtkComponent of nodes. */
static gboolean component_contains(AtkComponent *component, gint x, gint y, AtkCoordType coords) {
    Node *node = node_of(component);
    return node && node_contains(node, x, y, coords);
}
static AtkObject *component_at_point(AtkComponent *component, gint x, gint y, AtkCoordType coords) {
    Node *node = node_of(component);
    return node ? node_at(node->children, x, y, coords) : NULL;
}
static void component_extents(AtkComponent *component, gint *x, gint *y, gint *width, gint *height, AtkCoordType coords) {
    Node *node = node_of(component);
    if (node) node_extents(node, x, y, width, height, coords);
    else { if (x) *x = G_MININT; if (y) *y = G_MININT; if (width) *width = 0; if (height) *height = 0; }
}
static gboolean component_grab_focus(AtkComponent *component) {
    Node *node = node_of(component);
    return node && request(node, ACTION_FOCUS, NULL, 0, 0, 0);
}
static void zua_node_component_init(AtkComponentIface *iface) {
    iface->contains = component_contains;
    iface->ref_accessible_at_point = component_at_point;
    iface->get_extents = component_extents;
    iface->grab_focus = component_grab_focus;
}

/* AtkAction: click, then expand or contract for an item of a tree with
   children, as GTK's tree views have. */
enum { DO_CLICK = 1, DO_EXPAND = 2 };
static int action_at(Node *node, gint i) {
    int list[2], count = 0;
    if (pressable(node->n.role)) list[count++] = DO_CLICK;
    if (expandable_item(&node->n)) list[count++] = DO_EXPAND;
    return i >= 0 && i < count ? list[i] : 0;
}
static gint action_count(AtkAction *action) {
    Node *node = node_of(action);
    if (!node) return 0;
    return (pressable(node->n.role) ? 1 : 0) + (expandable_item(&node->n) ? 1 : 0);
}
static gboolean action_do(AtkAction *action, gint i) {
    Node *node = node_of(action);
    if (!node) return FALSE;
    switch (action_at(node, i)) {
    case DO_CLICK: return request(node, ACTION_INVOKE, NULL, 0, 0, 0);
    /* A tree item's value request: expand 3, collapse 2. */
    case DO_EXPAND: return request(node, ACTION_SET_RANGE, NULL, 0, 0, (node->n.flags & EXPANDED) ? 2 : 3);
    default: return FALSE;
    }
}
static const gchar *action_name(AtkAction *action, gint i) {
    Node *node = node_of(action);
    if (!node) return NULL;
    switch (action_at(node, i)) {
    case DO_CLICK: return "click";
    case DO_EXPAND: return "expand or contract";
    default: return NULL;
    }
}
static const gchar *action_empty(AtkAction *action, gint i) {
    Node *node = node_of(action);
    return node && action_at(node, i) ? "" : NULL;
}
static void zua_node_action_init(AtkActionIface *iface) {
    iface->do_action = action_do;
    iface->get_n_actions = action_count;
    iface->get_name = action_name;
    iface->get_localized_name = action_name;
    iface->get_description = action_empty;
    iface->get_keybinding = action_empty;
}

/* AtkValue of ranges. */
static double range_now(const NativeNode *n) { return n->range_value < n->range_minimum ? n->range_minimum : n->range_value; }
static double range_step(const NativeNode *n) {
    double step = n->range_small_change > 0 ? n->range_small_change : (n->range_maximum - n->range_minimum) / 10;
    return step > 0 ? step : 1;
}
static void set_double(GValue *value, double number) {
    memset(value, 0, sizeof(GValue));
    g_value_init(value, G_TYPE_DOUBLE);
    g_value_set_double(value, number);
}
static void value_current(AtkValue *value, GValue *out) { Node *node = node_of(value); if (node) set_double(out, range_now(&node->n)); }
static void value_maximum(AtkValue *value, GValue *out) { Node *node = node_of(value); if (node) set_double(out, node->n.range_maximum); }
static void value_minimum(AtkValue *value, GValue *out) { Node *node = node_of(value); if (node) set_double(out, node->n.range_minimum); }
static void value_minimum_increment(AtkValue *value, GValue *out) { Node *node = node_of(value); if (node) set_double(out, range_step(&node->n)); }
static gboolean value_set_current(AtkValue *value, const GValue *in) {
    Node *node = node_of(value);
    if (!node || !G_VALUE_HOLDS_DOUBLE(in)) return FALSE;
    return request(node, ACTION_SET_RANGE, NULL, 0, 0, g_value_get_double(in));
}
static void value_and_text(AtkValue *value, gdouble *number, gchar **text) {
    Node *node = node_of(value);
    if (number) *number = node ? range_now(&node->n) : 0;
    /* The text of the value (aria-valuetext), the caller's to free. */
    if (text) *text = node && node->value_text ? g_strdup(node->value_text) : NULL;
}
static AtkRange *value_range(AtkValue *value) {
    Node *node = node_of(value);
    /* A progress of unknown length has no range. */
    if (!node || (node->n.role == ROLE_PROGRESS && node->n.range_minimum == node->n.range_maximum)) return NULL;
    return atk_range_new(node->n.range_minimum, node->n.range_maximum, NULL);
}
static gdouble value_increment(AtkValue *value) { Node *node = node_of(value); return node ? range_step(&node->n) : 0; }
static void value_set(AtkValue *value, gdouble number) { Node *node = node_of(value); if (node) request(node, ACTION_SET_RANGE, NULL, 0, 0, number); }
static void zua_range_value_init(AtkValueIface *iface) {
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    iface->get_current_value = value_current;
    iface->get_maximum_value = value_maximum;
    iface->get_minimum_value = value_minimum;
    iface->get_minimum_increment = value_minimum_increment;
    iface->set_current_value = value_set_current;
    G_GNUC_END_IGNORE_DEPRECATIONS
    iface->get_value_and_text = value_and_text;
    iface->get_range = value_range;
    iface->get_increment = value_increment;
    iface->set_value = value_set;
}

/* AtkText: a label's name, or a text box's value. */
static const gunichar *text_chars(Node *node, glong *count) {
    if ((node->n.flags & PASSWORD)) { *count = 0; return NULL; }
    *count = node->count;
    return node->chars;
}
static void clamp_span(gint start, gint end, glong count, glong *a, glong *b) {
    if (end < 0 || end > count) end = (gint)count;
    *a = start < 0 ? 0 : start > count ? count : start;
    *b = end < *a ? *a : end;
}
static gchar *substring(const gunichar *chars, glong a, glong b) {
    gchar *text = g_ucs4_to_utf8(chars ? chars + a : NULL, b - a, NULL, NULL, NULL);
    return text ? text : g_strdup("");
}
static gchar *text_get(AtkText *text, gint start, gint end) {
    Node *node = node_of(text);
    if (!node) return NULL;
    glong count, a, b;
    const gunichar *chars = text_chars(node, &count);
    clamp_span(start, end, count, &a, &b);
    return substring(chars, a, b);
}
static gunichar text_char_at(AtkText *text, gint offset) {
    Node *node = node_of(text);
    if (!node) return 0;
    glong count;
    const gunichar *chars = text_chars(node, &count);
    return offset >= 0 && offset < count ? chars[offset] : 0;
}
static gint text_caret(AtkText *text) {
    Node *node = node_of(text);
    return node && textual(node->n.role) ? (gint)node->selection_end : -1;
}
static gint text_count(AtkText *text) {
    Node *node = node_of(text);
    glong count = 0;
    if (node) text_chars(node, &count);
    return (gint)count;
}
static gint text_selections(AtkText *text) {
    Node *node = node_of(text);
    return node && textual(node->n.role) && node->selection_start != node->selection_end ? 1 : 0;
}
static gchar *text_selection(AtkText *text, gint i, gint *start, gint *end) {
    Node *node = node_of(text);
    *start = 0; *end = 0;
    if (!node || i != 0 || !textual(node->n.role) || node->selection_start == node->selection_end) return NULL;
    glong count, a, b;
    const gunichar *chars = text_chars(node, &count);
    clamp_span((gint)MIN(node->selection_start, node->selection_end), (gint)MAX(node->selection_start, node->selection_end), count, &a, &b);
    *start = (gint)a; *end = (gint)b;
    return substring(chars, a, b);
}
static gboolean text_set_selection(AtkText *text, gint i, gint start, gint end) {
    Node *node = node_of(text);
    return node && i == 0 && request(node, ACTION_SELECT_TEXT, NULL, start, end < 0 ? node->count : end, 0);
}
static gboolean text_add_selection(AtkText *text, gint start, gint end) { return text_set_selection(text, 0, start, end); }
static gboolean text_remove_selection(AtkText *text, gint i) {
    Node *node = node_of(text);
    return node && i == 0 && request(node, ACTION_SELECT_TEXT, NULL, node->selection_end, node->selection_end, 0);
}
static gboolean text_set_caret(AtkText *text, gint offset) {
    Node *node = node_of(text);
    return node && request(node, ACTION_SELECT_TEXT, NULL, offset, offset, 0);
}
/* The range of the character, word, or line at an offset, for ATK's
   granularities 0, 1, and above. */
static void segment(const gunichar *chars, glong count, glong offset, int granularity, glong *start, glong *end) {
    offset = offset < 0 ? 0 : offset > count ? count : offset;
    if (granularity == ATK_TEXT_GRANULARITY_CHAR) { *start = offset; *end = MIN(offset + 1, count); return; }
    if (granularity == ATK_TEXT_GRANULARITY_WORD) {
        glong a = offset;
        while (a > 0 && g_unichar_isspace(chars[a - 1]) && (a == count || g_unichar_isspace(chars[a]))) a--;
        while (a > 0 && !g_unichar_isspace(chars[a - 1])) a--;
        glong b = a;
        while (b < count && !g_unichar_isspace(chars[b])) b++;
        while (b < count && g_unichar_isspace(chars[b])) b++;
        *start = a; *end = b;
        return;
    }
    glong a = offset, b = offset;
    while (a > 0 && chars[a - 1] != '\n') a--;
    while (b < count && chars[b] != '\n') b++;
    *start = a; *end = MIN(b + 1, count);
}
static gchar *string_at(AtkText *text, gint offset, int granularity, gint *start, gint *end) {
    Node *node = node_of(text);
    *start = 0; *end = 0;
    if (!node) return NULL;
    glong count, a, b;
    const gunichar *chars = text_chars(node, &count);
    segment(chars, count, offset, granularity, &a, &b);
    *start = (gint)a; *end = (gint)b;
    return substring(chars, a, b);
}
static gchar *text_string_at_offset(AtkText *text, gint offset, AtkTextGranularity granularity, gint *start, gint *end) {
    return string_at(text, offset, (int)granularity, start, end);
}
/* The boundaries of the older text_at_offset: characters, the starts and
   ends of words, sentences and lines. */
static gchar *text_at_offset(AtkText *text, gint offset, AtkTextBoundary boundary, gint *start, gint *end) {
    static const int granularity[] = { ATK_TEXT_GRANULARITY_CHAR, ATK_TEXT_GRANULARITY_WORD, ATK_TEXT_GRANULARITY_WORD,
        ATK_TEXT_GRANULARITY_LINE, ATK_TEXT_GRANULARITY_LINE, ATK_TEXT_GRANULARITY_LINE, ATK_TEXT_GRANULARITY_LINE };
    int index = (int)boundary < 0 ? 0 : (int)boundary > 6 ? 6 : (int)boundary;
    return string_at(text, offset, granularity[index], start, end);
}
static void text_character_extents(AtkText *text, gint offset, gint *x, gint *y, gint *width, gint *height, AtkCoordType coords) {
    (void)offset;
    Node *node = node_of(text);
    if (node) node_extents(node, x, y, width, height, coords);
}
static AtkAttributeSet *text_run_attributes(AtkText *text, gint offset, gint *start, gint *end) {
    Node *node = node_of(text);
    (void)offset;
    *start = 0; *end = node ? (gint)node->count : 0;
    return NULL;
}
static void zua_text_text_init(AtkTextIface *iface) {
    iface->get_text = text_get;
    iface->get_character_at_offset = text_char_at;
    iface->get_caret_offset = text_caret;
    iface->get_character_count = text_count;
    iface->get_n_selections = text_selections;
    iface->get_selection = text_selection;
    iface->add_selection = text_add_selection;
    iface->remove_selection = text_remove_selection;
    iface->set_selection = text_set_selection;
    iface->set_caret_offset = text_set_caret;
    iface->get_string_at_offset = text_string_at_offset;
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    iface->get_text_at_offset = text_at_offset;
    G_GNUC_END_IGNORE_DEPRECATIONS
    iface->get_character_extents = text_character_extents;
    iface->get_run_attributes = text_run_attributes;
}

/* AtkEditableText: every edit sets the whole value. */
static Node *editable(gpointer obj) {
    Node *node = node_of(obj);
    return node && textual(node->n.role) && !(node->n.flags & READ_ONLY) && (node->n.flags & ENABLED) ? node : NULL;
}
static gchar *spliced(Node *node, glong a, glong b, const gchar *inserted, gint length) {
    GString *out = g_string_new(NULL);
    gchar *head = substring(node->chars, 0, a), *tail = substring(node->chars, b, node->count);
    g_string_append(out, head);
    if (inserted) g_string_append_len(out, inserted, length);
    g_string_append(out, tail);
    g_free(head); g_free(tail);
    return g_string_free(out, FALSE);
}
static void editable_set_contents(AtkEditableText *text, const gchar *contents) {
    Node *node = editable(text);
    if (node) request(node, ACTION_SET_VALUE, contents, 0, 0, 0);
}
static void editable_insert(AtkEditableText *text, const gchar *inserted, gint length, gint *position) {
    Node *node = editable(text);
    if (!node || !position || !inserted) return;
    if (length < 0) length = (gint)strlen(inserted);
    if (!g_utf8_validate(inserted, length, NULL)) return;
    glong at = *position < 0 ? 0 : *position > node->count ? node->count : *position;
    gchar *next = spliced(node, at, at, inserted, length);
    if (request(node, ACTION_SET_VALUE, next, 0, 0, 0)) *position = (gint)(at + g_utf8_strlen(inserted, length));
    g_free(next);
}
static void editable_delete(AtkEditableText *text, gint start, gint end) {
    Node *node = editable(text);
    if (!node) return;
    glong a, b;
    clamp_span(start, end, node->count, &a, &b);
    if (a == b) return;
    gchar *next = spliced(node, a, b, NULL, 0);
    request(node, ACTION_SET_VALUE, next, 0, 0, 0);
    g_free(next);
}
static void zua_editable_editable_init(AtkEditableTextIface *iface) {
    iface->set_text_contents = editable_set_contents;
    iface->insert_text = editable_insert;
    iface->delete_text = editable_delete;
}

/* AtkSelection of lists, trees, tables and tab lists: the rows they
   choose. Choosing a row presses it, which chooses that row alone. */
static Node *child_at(Node *node, gint i) {
    return node && i >= 0 && (guint)i < node->children->len ? g_ptr_array_index(node->children, i) : NULL;
}
static gboolean chosen(const Node *child) { return chooses(child) && (child->n.flags & CHECKED); }
static gboolean selection_add(AtkSelection *selection, gint i) {
    Node *child = child_at(node_of(selection), i);
    return child && chooses(child) && request(child, ACTION_INVOKE, NULL, 0, 0, 0);
}
static gboolean selection_refuse(AtkSelection *selection) { (void)selection; return FALSE; }
static gboolean selection_refuse_at(AtkSelection *selection, gint i) { (void)selection; (void)i; return FALSE; }
static AtkObject *selection_ref(AtkSelection *selection, gint i) {
    Node *node = node_of(selection);
    if (!node || i < 0) return NULL;
    for (guint k = 0; k < node->children->len; k++) {
        Node *child = g_ptr_array_index(node->children, k);
        if (chosen(child) && i-- == 0) return g_object_ref(child->obj);
    }
    return NULL;
}
static gint selection_count(AtkSelection *selection) {
    Node *node = node_of(selection);
    gint count = 0;
    if (node) for (guint k = 0; k < node->children->len; k++) count += chosen(g_ptr_array_index(node->children, k));
    return count;
}
static gboolean selection_is(AtkSelection *selection, gint i) {
    Node *child = child_at(node_of(selection), i);
    return child && chosen(child);
}
static void zua_selection_selection_init(AtkSelectionIface *iface) {
    iface->add_selection = selection_add;
    iface->clear_selection = selection_refuse;
    iface->ref_selection = selection_ref;
    iface->get_selection_count = selection_count;
    iface->is_child_selected = selection_is;
    iface->remove_selection = selection_refuse_at;
    iface->select_all_selection = selection_refuse;
}

/* ------------------------------------------------------------------ */
/* Publication. */

static void page_set(Node *node, AtkObject *page);
static void node_free(gpointer data) {
    Node *node = data;
    page_set(node, NULL);
    ((ZuaNode *)node->obj)->node = NULL;
    atk_object_notify_state_change(node->obj, ATK_STATE_DEFUNCT, TRUE);
    g_object_unref(node->obj);
    g_ptr_array_unref(node->children);
    g_free(node->name); g_free(node->description); g_free(node->value); g_free(node->chars); g_free(node->chosen);
    g_free(node->role_description); g_free(node->key_shortcuts); g_free(node->value_text);
    g_free(node);
    live_nodes--;
}
static gchar *text_at(const uint16_t *text, uint32_t text_len, uint32_t start, uint32_t len) {
    if (start > text_len || len > text_len - start) return g_strdup("");
    gchar *out = g_utf16_to_utf8((const gunichar2 *)text + start, len, NULL, NULL, NULL);
    return out ? out : g_strdup("");
}
/* Character offset of UTF-16 unit `units` in `chars`. */
static glong chars_before(const gunichar *chars, glong count, uint32_t units) {
    glong i = 0;
    uint32_t seen = 0;
    while (i < count && seen < units) { seen += chars[i] > 0xFFFF ? 2 : 1; i++; }
    return i;
}
static void emit_child(AtkObject *parent, const char *signal, guint index, AtkObject *child) {
    g_signal_emit_by_name(parent, signal, index, child);
}
static gboolean contains_node(GPtrArray *list, Node *node) { guint index; return list && g_ptr_array_find(list, node, &index); }
/* Tells assistive technology how a node's states changed; the focus is
   signalled on its own. */
static void notify_states(Node *node, const NativeNode *before) {
    Node old = *node;
    old.n = *before;
    AtkStateSet *a = atk_state_set_new(), *b = atk_state_set_new();
    add_states(a, &old);
    add_states(b, node);
    atk_state_set_remove_state(a, ATK_STATE_FOCUSED);
    atk_state_set_remove_state(b, ATK_STATE_FOCUSED);
    for (int state = ATK_STATE_INVALID + 1; state < ATK_STATE_LAST_DEFINED; state++) {
        gboolean was = atk_state_set_contains_state(a, state), is = atk_state_set_contains_state(b, state);
        if (was != is) atk_object_notify_state_change(node->obj, state, is);
    }
    g_object_unref(a); g_object_unref(b);
}
/* What changed in a text box's value, between the text both have at their
   ends, and where its caret and selection went. */
static void notify_text(Node *node, const gunichar *old, glong old_count, glong old_start, glong old_end) {
    const gunichar *now = node->chars;
    glong count = node->count;
    if (node->n.flags & PASSWORD) { old_count = 0; count = 0; }
    glong start = 0;
    while (start < old_count && start < count && old[start] == now[start]) start++;
    glong end = 0;
    while (end < old_count - start && end < count - start && old[old_count - 1 - end] == now[count - 1 - end]) end++;
    if (old_count - end > start) {
        gchar *removed = substring(old, start, old_count - end);
        g_signal_emit_by_name(node->obj, "text-remove", (gint)start, (gint)(old_count - end - start), removed);
        g_free(removed);
    }
    if (count - end > start) {
        gchar *inserted = substring(now, start, count - end);
        g_signal_emit_by_name(node->obj, "text-insert", (gint)start, (gint)(count - end - start), inserted);
        g_free(inserted);
    }
    if (old_end != node->selection_end) g_signal_emit_by_name(node->obj, "text-caret-moved", (gint)node->selection_end);
    if ((old_start != node->selection_start || old_end != node->selection_end) && (old_start != old_end || node->selection_start != node->selection_end))
        g_signal_emit_by_name(node->obj, "text-selection-changed");
}

static guint announcement_signal(void) {
    static gsize once;
    static guint signal;
    if (g_once_init_enter(&once)) {
        signal = g_signal_lookup("notification", ATK_TYPE_OBJECT);
        if (!signal) signal = g_signal_lookup("announcement", ATK_TYPE_OBJECT);
        g_once_init_leave(&once, 1);
    }
    return signal;
}
static uint32_t announcements;
static gchar *last_announcement;
/* A status message absent from the previous tree says itself once,
   politely. */
static void announce_as(Host *host, const gchar *message, gint politeness);
static void announce(Host *host, const gchar *message) { announce_as(host, message, 1 /* ATK_LIVE_POLITE */); }
/* What live regions read out, as Zig tells them: the content added to a
   log politely, and an alert's at once, assertively (ATK_LIVE_ASSERTIVE),
   through the notification signal of ATK 2.50, or announced before it. */
int zua_announce(void *state, const uint16_t *text, uint32_t text_len, int assertive) {
    Host *host = state;
    if (!host || host->closed) return -1;
    gchar *message = text_at(text, text_len, 0, text_len);
    announce_as(host, message, assertive ? 2 : 1);
    g_free(message);
    return 0;
}
static void announce_as(Host *host, const gchar *message, gint politeness) {
    announcements++;
    g_free(last_announcement);
    last_announcement = g_strdup(message);
    guint signal = announcement_signal();
    if (!signal) return;
    GSignalQuery query;
    g_signal_query(signal, &query);
    if (query.n_params == 2) g_signal_emit(host->root, signal, 0, message, politeness);
    else g_signal_emit(host->root, signal, 0, message);
}

static void refresh_position(Host *host) {
    ZlgAccessibilityPosition position;
    if (host->binding && zlg_accessibility_position(host->binding, &position) == ZLG_ACCESSIBILITY_OK) {
        host->position = position;
        host->positioned = TRUE;
    }
}

static int publish(Host *host, const NativeNode *nodes, uint32_t count, const uint16_t *text, uint32_t text_len, const RecipientAuthority *keys, const ZuaGeometry *geometry) {
    if (host->closed) return -1;
    if (count == 0 || nodes[0].id != 0) return -2;
    for (uint32_t i = 1; i < count; i++) if (nodes[i].role >= ROLE_COUNT) return -2;
    if (geometry && (!host->geometry || !zua_geometry_valid(geometry, count))) return -2;
    if (geometry) memcpy(host->geometry, geometry, sizeof *geometry);
    host->geometry_active = geometry != NULL;
    host->updating = TRUE;
    refresh_position(host);
    gchar *root_name = text_at(text, text_len, nodes[0].name_start, nodes[0].name_len);
    if (g_strcmp0(atk_object_get_name(host->root), root_name) != 0) atk_object_set_name(host->root, root_name);
    g_free(root_name);

    GHashTable *old = host->nodes;
    GHashTable *live = g_hash_table_new_full(g_int64_hash, g_int64_equal, NULL, node_free);
    Node **list = g_new0(Node *, count);
    NativeNode *before = g_new0(NativeNode, count);
    gboolean *fresh = g_new0(gboolean, count);
    gchar **old_names = g_new0(gchar *, count), **old_descriptions = g_new0(gchar *, count);
    gunichar **old_chars = g_new0(gunichar *, count);
    glong *old_counts = g_new0(glong, count), *old_starts = g_new0(glong, count), *old_ends = g_new0(glong, count);
    /* Old children lists, for the parents that stay. */
    GHashTable *old_kids = g_hash_table_new_full(g_direct_hash, g_direct_equal, NULL, (GDestroyNotify)g_ptr_array_unref);
    GPtrArray *old_top = host->top;
    GPtrArray *announce_list = g_ptr_array_new_with_free_func(g_free);
    uint64_t focus = 0;
    gboolean has_focus = FALSE;
    for (uint32_t i = 1; i < count; i++) {
        const NativeNode *n = &nodes[i];
        GType type = type_of(n);
        Node *node = g_hash_table_lookup(old, &n->id);
        if (node && node->type == type) {
            g_hash_table_steal(old, &n->id);
            before[i] = node->n;
            g_hash_table_insert(old_kids, node, node->children);
            node->children = g_ptr_array_new();
            old_names[i] = node->name; old_descriptions[i] = node->description;
            old_chars[i] = node->chars; old_counts[i] = node->count;
            old_starts[i] = node->selection_start; old_ends[i] = node->selection_end;
            g_free(node->value);
            g_free(node->role_description); g_free(node->key_shortcuts); g_free(node->value_text);
        } else {
            node = g_new0(Node, 1);
            node->obj = g_object_new(type, NULL);
            ((ZuaNode *)node->obj)->node = node;
            node->type = type;
            node->host = host;
            node->children = g_ptr_array_new();
            live_nodes++;
            fresh[i] = TRUE;
        }
        node->n = *n;
        node->index = i;
        node->parent = NULL;
        node->name = text_at(text, text_len, n->name_start, n->name_len);
        node->description = text_at(text, text_len, n->description_start, n->description_len);
        node->role_description = n->role_description_len ? text_at(text, text_len, n->role_description_start, n->role_description_len) : NULL;
        node->key_shortcuts = n->key_shortcuts_len ? text_at(text, text_len, n->key_shortcuts_start, n->key_shortcuts_len) : NULL;
        node->value_text = n->value_text_len ? text_at(text, text_len, n->value_text_start, n->value_text_len) : NULL;
        gchar *value = n->role == ROLE_TEXT ? g_strdup(node->name) : text_at(text, text_len, n->value_start, n->value_len);
        node->value = value;
        glong chars = 0;
        node->chars = g_utf8_to_ucs4_fast(value, -1, &chars);
        node->count = chars;
        node->selection_start = chars_before(node->chars, chars, n->selection_start);
        node->selection_end = chars_before(node->chars, chars, n->selection_end);
        node->recipient = keys ? keys[i] : (RecipientAuthority){0};
        g_hash_table_insert(live, &node->n.id, node);
        list[i] = node;
        if ((n->flags & FOCUSED) && !has_focus) { focus = n->id; has_focus = TRUE; }
        if (fresh[i] && n->role == ROLE_STATUS && (node->name[0] || node->value[0]))
            g_ptr_array_add(announce_list, g_strdup(node->name[0] ? node->name : node->value));
    }
    GPtrArray *top = g_ptr_array_new();
    for (uint32_t i = 1; i < count; i++) {
        Node *node = list[i];
        Node *parent = node->n.parent == 0 ? NULL : g_hash_table_lookup(live, &node->n.parent);
        if (parent) g_ptr_array_add(parent->children, node);
        else g_ptr_array_add(top, node);
        AtkObject *parent_obj = parent ? parent->obj : host->root;
        node->parent = parent;
        if (fresh[i] || atk_object_get_parent(node->obj) != parent_obj) atk_object_set_parent(node->obj, parent_obj);
        AtkRole role = atk_role_of(&node->n);
        if (fresh[i] || atk_role_of(&before[i]) != role) atk_object_set_role(node->obj, role);
        if (fresh[i] || g_strcmp0(old_names[i], node->name) != 0) atk_object_set_name(node->obj, node->name);
        if (fresh[i] || g_strcmp0(old_descriptions[i], node->description) != 0) atk_object_set_description(node->obj, node->description);
    }
    host->nodes = live;
    host->top = top;
    gboolean had_focus = host->has_focus;
    uint64_t old_focus = host->focus;
    host->focus = focus; host->has_focus = has_focus;
    host->updating = FALSE;

    /* Children that left their parent, then those that joined it, for the
       parents that were in the tree before. */
    {
        GPtrArray *kids = old_top;
        for (guint k = kids->len; k > 0; k--) {
            Node *kid = g_ptr_array_index(kids, k - 1);
            if (!contains_node(top, kid)) emit_child(host->root, "children-changed::remove", k - 1, kid->obj);
        }
        for (guint k = 0; k < top->len; k++) {
            Node *kid = g_ptr_array_index(top, k);
            if (!contains_node(kids, kid)) emit_child(host->root, "children-changed::add", k, kid->obj);
        }
    }
    for (uint32_t i = 1; i < count; i++) {
        if (fresh[i]) continue;
        Node *node = list[i];
        GPtrArray *kids = g_hash_table_lookup(old_kids, node);
        for (guint k = kids->len; k > 0; k--) {
            Node *kid = g_ptr_array_index(kids, k - 1);
            if (!contains_node(node->children, kid)) emit_child(node->obj, "children-changed::remove", k - 1, kid->obj);
        }
        for (guint k = 0; k < node->children->len; k++) {
            Node *kid = g_ptr_array_index(node->children, k);
            if (!contains_node(kids, kid)) emit_child(node->obj, "children-changed::add", k, kid->obj);
        }
        notify_states(node, &before[i]);
        if (ranged(node->n.role) && (before[i].range_value != node->n.range_value || before[i].range_minimum != node->n.range_minimum || before[i].range_maximum != node->n.range_maximum))
            g_object_notify(G_OBJECT(node->obj), "accessible-value");
        if (textual(node->n.role)) notify_text(node, old_chars[i], old_counts[i], old_starts[i], old_ends[i]);
        else if (node->n.role == ROLE_TEXT && g_strcmp0(old_names[i], node->name) != 0) {
            if (old_counts[i]) {
                gchar *removed = substring(old_chars[i], 0, old_counts[i]);
                g_signal_emit_by_name(node->obj, "text-remove", 0, (gint)old_counts[i], removed);
                g_free(removed);
            }
            if (node->count) g_signal_emit_by_name(node->obj, "text-insert", 0, (gint)node->count, node->value);
        }
    }
    /* Lists choosing their rows tell when the choice moves. */
    for (uint32_t i = 1; i < count; i++) {
        Node *node = list[i];
        if (!rows_container(node->n.role)) continue;
        guint len = 0;
        uint64_t *ids = g_new0(uint64_t, node->children->len + 1);
        for (guint k = 0; k < node->children->len; k++) {
            Node *child = g_ptr_array_index(node->children, k);
            if (chosen(child)) ids[len++] = child->n.id;
        }
        gboolean same = len == node->chosen_len && (len == 0 || memcmp(ids, node->chosen, len * sizeof(uint64_t)) == 0);
        if (!same) {
            g_free(node->chosen);
            node->chosen = ids; node->chosen_len = len;
            if (!fresh[i]) g_signal_emit_by_name(node->obj, "selection-changed");
        } else g_free(ids);
    }
    if (had_focus != has_focus || old_focus != focus) {
        Node *was = had_focus ? g_hash_table_lookup(live, &old_focus) : NULL;
        if (was) atk_object_notify_state_change(was->obj, ATK_STATE_FOCUSED, FALSE);
        Node *now = has_focus ? g_hash_table_lookup(live, &focus) : NULL;
        if (now) {
            atk_object_notify_state_change(now->obj, ATK_STATE_FOCUSED, TRUE);
            G_GNUC_BEGIN_IGNORE_DEPRECATIONS
            atk_focus_tracker_notify(now->obj);
            G_GNUC_END_IGNORE_DEPRECATIONS
        }
    }
    for (guint k = 0; k < announce_list->len; k++) announce(host, g_ptr_array_index(announce_list, k));

    /* Nodes that left the tree. */
    g_hash_table_unref(old);
    for (uint32_t i = 1; i < count; i++) {
        g_free(old_names[i]); g_free(old_descriptions[i]); g_free(old_chars[i]);
    }
    g_ptr_array_unref(old_top);
    g_hash_table_unref(old_kids);
    g_ptr_array_unref(announce_list);
    g_free(list); g_free(before); g_free(fresh); g_free(old_names); g_free(old_descriptions); g_free(old_chars);
    g_free(old_counts); g_free(old_starts); g_free(old_ends);
    return 0;
}

/* ------------------------------------------------------------------ */
/* The ABI accessibility.zig calls. */

/* The binding retires the root as the area goes: it is only marked. */
static void root_invalidated(void *child) { ((ZuaRoot *)child)->retired = TRUE; }

void *zua_create(void *native, ZuaEnqueue enqueue, void *context) {
    NativeWindow *window = native;
    if (!window || !zlg_accessibility_host_available(window)) return NULL;
    Host *host = g_new0(Host, 1);
    host->refs = 1;
    host->enqueue = enqueue; host->context = context; host->native = window;
    host->nodes = g_hash_table_new_full(g_int64_hash, g_int64_equal, NULL, node_free);
    host->top = g_ptr_array_new();
    ZuaRoot *root = g_object_new(zua_root_get_type(), NULL);
    root->host = host;
    host->root = ATK_OBJECT(root);
    atk_object_set_role(host->root, ATK_ROLE_PANEL);
    live_hosts++;
    if (zlg_accessibility_prepare(window, root, root_invalidated, &host->binding) != ZLG_ACCESSIBILITY_OK) {
        host->binding = NULL;
        root->host = NULL;
        g_object_unref(root);
        host_unref(host);
        return NULL;
    }
    if (zlg_accessibility_mount(host->binding) != ZLG_ACCESSIBILITY_OK) {
        zlg_accessibility_release(host->binding);
        host->binding = NULL;
        root->host = NULL;
        g_object_unref(root);
        host_unref(host);
        return NULL;
    }
    refresh_position(host);
    return host;
}
/* Revokes the Zig context: actions taken after it are refused. */
void zua_begin_close(void *state) {
    Host *host = state;
    host->context = NULL;
    host->closed = TRUE;
}
int zua_disconnect(void *state) {
    Host *host = state;
    host->closed = TRUE;
    host->context = NULL;
    if (host->binding) { zlg_accessibility_release(host->binding); host->binding = NULL; }
    GHashTable *nodes = host->nodes;
    host->nodes = g_hash_table_new_full(g_int64_hash, g_int64_equal, NULL, node_free);
    g_ptr_array_set_size(host->top, 0);
    g_hash_table_unref(nodes);
    ZuaRoot *root = (ZuaRoot *)host->root;
    root->host = NULL;
    atk_object_notify_state_change(host->root, ATK_STATE_DEFUNCT, TRUE);
    g_object_unref(host->root);
    host->root = NULL;
    host_unref(host);
    return 0;
}
/* Put native content's accessible in a node, or take it out. */
static void page_set(Node *node, AtkObject *page) {
    if (node->page == page) return;
    AtkObject *old = node->page;
    node->page = NULL;
    if (old) {
        if (atk_object_get_parent(old) == node->obj) atk_object_set_parent(old, NULL);
        if (!node->host->closed) emit_child(node->obj, "children-changed::remove", 0, old);
        g_object_unref(old);
    }
    if (page) {
        node->page = g_object_ref(page);
        atk_object_set_parent(page, node->obj);
        emit_child(node->obj, "children-changed::add", 0, page);
    }
}
/* The native content inside nodes of the last publication: each widget's
   accessible, a web view's AtkSocket its page's tree is embedded in, goes in
   the node of its id; the other nodes hold none. */
int zua_pages(void *state, const uint64_t *ids, void *const *widgets, uint32_t count) {
    Host *host = state;
    if (host->closed) return -1;
    if (count && (!ids || !widgets)) return -2;
    GHashTableIter iter;
    gpointer key, value;
    g_hash_table_iter_init(&iter, host->nodes);
    while (g_hash_table_iter_next(&iter, &key, &value)) {
        Node *node = value;
        AtkObject *page = NULL;
        for (uint32_t i = 0; i < count && !page; i++) {
            if (ids[i] != node->n.id || !GTK_IS_WIDGET(widgets[i]) || gtk_widget_in_destruction(widgets[i])) continue;
            AtkObject *accessible = gtk_widget_get_accessible(widgets[i]);
            /* Each page goes in one node. */
            Node *other = accessible && node->page != accessible ? node_of(atk_object_get_parent(accessible)) : NULL;
            if (other && other != node && other->page == accessible) page_set(other, NULL);
            page = accessible;
        }
        page_set(node, page);
    }
    return 0;
}
int zua_publish(void *state, const NativeNode *nodes, uint32_t count, const uint16_t *text, uint32_t text_len) {
    return publish(state, nodes, count, text, text_len, NULL, NULL);
}
int zua_publish_registered(void *state, const NativeNode *nodes, uint32_t count, const uint16_t *text, uint32_t text_len, const RecipientAuthority *keys) {
    return publish(state, nodes, count, text, text_len, keys, NULL);
}
/* Transformed content: boxes as laid out, and their precise geometry for
   finding the node at a point. */
int zua_publish_geometry(void *state, const NativeNode *nodes, uint32_t count, const uint16_t *text, uint32_t text_len, const ZuaGeometry *geometry) {
    return geometry ? publish(state, nodes, count, text, text_len, NULL, geometry) : -2;
}
int zua_publish_geometry_registered(void *state, const NativeNode *nodes, uint32_t count, const uint16_t *text, uint32_t text_len, const ZuaGeometry *geometry, const RecipientAuthority *keys) {
    return geometry && keys ? publish(state, nodes, count, text, text_len, keys, geometry) : -2;
}
/* The window moved: its screen origin is read again. */
int zua_position_changed(void *state, double dx, double dy) {
    (void)dx; (void)dy;
    Host *host = state;
    if (!host->closed) refresh_position(host);
    return 0;
}
static unsigned live_geometry;
ZuaGeometry *zua_geometry_create(void) { ZuaGeometry *g = g_try_new0(ZuaGeometry, 1); if (g) live_geometry++; return g; }
void zua_geometry_free(ZuaGeometry *geometry) { if (geometry) { g_free(geometry); live_geometry--; } }
int zua_geometry_commit(void *state, ZuaGeometry *geometry) {
    Host *host = state;
    if (host->closed || host->geometry) return -1;
    host->geometry = geometry;
    host->geometry_active = FALSE;
    return 0;
}
void zua_geometry_release(void *state) {
    Host *host = state;
    ZuaGeometry *geometry = host->geometry;
    host->geometry = NULL; host->geometry_active = FALSE;
    zua_geometry_free(geometry);
}
uint32_t zua_geometry_count(void) { return live_geometry; }
static void zua_geometry_free_ptr(ZuaGeometry *geometry) { zua_geometry_free(geometry); }

int zua_take_action(void *pointer, ActionView *out) {
    Action *a = pointer;
    Host *host = a->host;
    Node *node = host->closed ? NULL : g_hash_table_lookup(host->nodes, &a->id);
    gboolean available = !host->closed && host->context && node && (node->n.flags & ENABLED);
    /* The node's recipient must still be the one the request was made
       for: an older request does not act on a newly registered recipient. */
    if (available && memcmp(&node->recipient, &a->recipient, sizeof(RecipientAuthority)) != 0) available = FALSE;
    if (available) *out = (ActionView){ host->context, a->kind, a->id, a->value, a->value_len, a->start, a->end, a->number, a->recipient };
    return available;
}
int zua_take_collection_action(void *action, void *out) { (void)action; (void)out; return 0; }
void zua_finish_action(void *pointer) {
    Action *a = pointer;
    host_unref(a->host);
    g_free(a->value);
    g_free(a);
    live_actions--;
}
void zua_resource_counts(uint32_t *states, uint32_t *providers, uint32_t *ranges, uint32_t *actions) {
    *states = live_hosts; *providers = live_nodes; *ranges = 0; *actions = live_actions;
}

/* ------------------------------------------------------------------ */
/* Test hooks: assistive technology's view of a Bridge's tree, as a screen
   reader would ask for it through ATK. */

void *zua_test_root(void *state) { return state ? ((Host *)state)->root : NULL; }
static AtkObject *find(AtkObject *obj, const char *name) {
    if (g_strcmp0(atk_object_get_name(obj), name) == 0) return obj;
    gint count = atk_object_get_n_accessible_children(obj);
    for (gint i = 0; i < count; i++) {
        AtkObject *child = atk_object_ref_accessible_child(obj, i);
        if (!child) continue;
        AtkObject *found = find(child, name);
        g_object_unref(child);
        if (found) return found;
    }
    return NULL;
}
void *zua_test_element(void *state, const char *name) {
    Host *host = state;
    if (!host || !host->root) return NULL;
    gint count = atk_object_get_n_accessible_children(host->root);
    for (gint i = 0; i < count; i++) {
        AtkObject *child = atk_object_ref_accessible_child(host->root, i);
        AtkObject *found = child ? find(child, name) : NULL;
        if (child) g_object_unref(child);
        if (found) return found;
    }
    return NULL;
}
/* What a screen reader reads of an element: "role|name|value|states",
   the value its text or its number, the states enabled, focused, checked,
   selected and expanded as e f c s x. */
int zua_test_describe(void *pointer, char *buffer, int capacity) {
    AtkObject *obj = pointer;
    GString *out = g_string_new(atk_role_get_name(atk_object_get_role(obj)));
    g_string_append_printf(out, "|%s|", atk_object_get_name(obj) ? atk_object_get_name(obj) : "");
    if (ATK_IS_TEXT(obj) && atk_object_get_role(obj) != ATK_ROLE_LABEL) {
        gchar *text = atk_text_get_text(ATK_TEXT(obj), 0, -1);
        g_string_append(out, text ? text : "");
        g_free(text);
    } else if (ATK_IS_VALUE(obj)) {
        gdouble number = 0;
        atk_value_get_value_and_text(ATK_VALUE(obj), &number, NULL);
        g_string_append_printf(out, "%g", number);
    }
    g_string_append_c(out, '|');
    AtkStateSet *set = atk_object_ref_state_set(obj);
    static const struct { AtkStateType state; char letter; } letters[] = {
        { ATK_STATE_ENABLED, 'e' }, { ATK_STATE_FOCUSED, 'f' }, { ATK_STATE_CHECKED, 'c' }, { ATK_STATE_SELECTED, 's' }, { ATK_STATE_EXPANDED, 'x' }, { ATK_STATE_DEFUNCT, 'd' },
    };
    for (size_t i = 0; i < G_N_ELEMENTS(letters); i++) if (atk_state_set_contains_state(set, letters[i].state)) g_string_append_c(out, letters[i].letter);
    g_object_unref(set);
    int length = (int)MIN(out->len, (gsize)capacity - 1);
    memcpy(buffer, out->str, (size_t)length);
    buffer[length] = 0;
    g_string_free(out, TRUE);
    return length;
}
/* The element's extents on the screen and in its window. */
void zua_test_extents(void *pointer, int window, int32_t *out) {
    gint x = 0, y = 0, w = 0, h = 0;
    atk_component_get_extents(ATK_COMPONENT(pointer), &x, &y, &w, &h, window ? ATK_XY_WINDOW : ATK_XY_SCREEN);
    out[0] = x; out[1] = y; out[2] = w; out[3] = h;
}
/* Acts on an element as a screen reader does: 1 its first action, 2 sets
   its value to `number`, 3 sets its text, 4 inserts text at `number`,
   5 grabs focus, 6 selects one character from `number`, 7 chooses its
   `number`th child, 8 its second action. */
int zua_test_act(void *pointer, int kind, double number, const char *text) {
    AtkObject *obj = pointer;
    switch (kind) {
    case 1: return atk_action_do_action(ATK_ACTION(obj), 0);
    case 2: atk_value_set_value(ATK_VALUE(obj), number); return 1;
    case 3: atk_editable_text_set_text_contents(ATK_EDITABLE_TEXT(obj), text); return 1;
    case 4: { gint at = (gint)number; atk_editable_text_insert_text(ATK_EDITABLE_TEXT(obj), text, -1, &at); return at; }
    case 5: return atk_component_grab_focus(ATK_COMPONENT(obj));
    case 6: return atk_text_set_selection(ATK_TEXT(obj), 0, (gint)number, (gint)number + 1);
    case 7: return atk_selection_add_selection(ATK_SELECTION(obj), (gint)number);
    case 8: return atk_action_do_action(ATK_ACTION(obj), 1);
    }
    return 0;
}
int zua_test_child_count(void *state) {
    Host *host = state;
    return host && host->root ? atk_object_get_n_accessible_children(host->root) : 0;
}
/* Whether the root hangs below the window's drawing area. */
int zua_test_mounted(void *state) {
    Host *host = state;
    AtkObject *parent = host && host->root ? atk_object_get_parent(host->root) : NULL;
    return parent && GTK_IS_ACCESSIBLE(parent) && GTK_IS_DRAWING_AREA(gtk_accessible_get_widget(GTK_ACCESSIBLE(parent)));
}
int zua_test_announcements(char *buffer, int capacity) {
    snprintf(buffer, (size_t)capacity, "%s", last_announcement ? last_announcement : "");
    return (int)announcements;
}
int zua_test_selection_count(void *pointer) { return atk_selection_get_selection_count(ATK_SELECTION(pointer)); }
/* The value of an object's attribute, such as "posinset", as a number;
   -1 without it. */
int zua_test_attribute(void *pointer, const char *name) {
    AtkAttributeSet *set = atk_object_get_attributes(ATK_OBJECT(pointer));
    int value = -1;
    for (GSList *item = set; item; item = item->next) {
        AtkAttribute *attribute = item->data;
        if (g_strcmp0(attribute->name, name) == 0) value = atoi(attribute->value);
    }
    atk_attribute_set_free(set);
    return value;
}
int zua_test_caret(void *pointer) { return atk_text_get_caret_offset(ATK_TEXT(pointer)); }
