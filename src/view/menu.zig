//! Menus drawn in the window: one that a secondary press or the keyboard's
//! menu key opens over a node, with items, check box and radio items,
//! separators and submenus.
//!
//! `View.popoverMenu` follows the node it anchors on, like a popover. A
//! secondary press over the anchor opens it at the pointer, and the menu
//! key or Shift+F10 opens it below the anchor while focus is inside the
//! anchor; the innermost anchor wins. While it is open the menu holds the
//! keys: Up, Down, Home and End move the highlight among the items of the
//! deepest open level, a letter moves it to the next item starting with
//! it, Right, Enter or Space opens a submenu and highlights its first item,
//! Left or Escape closes the deepest submenu, and Escape at the top closes
//! the menu. Enter or Space, or a press, chooses an item: the menu closes
//! and focus goes back to where it was when the menu opened. The pointer
//! over an item highlights it and opens its submenu; a press outside every
//! panel closes the menu and goes on to what lies under it.
//!
//! Focus follows the highlight, so assistive technology reads the item the
//! keys are on. Only one menu is open at a time, and a menu whose anchor
//! is no longer built or is disabled closes.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("root.zig");

const View = view.View;
const Node = view.Node;
const Style = view.Style;
const Error = view.Error;
const Rect = view.Rect;
const Point = view.Point;
const Insets = view.Insets;
const KeyRoute = view.KeyRoute;
const PointerRoute = view.PointerRoute;

/// Levels of submenus one menu opens, the menu itself included.
pub const max_depth = 8;
/// Menu anchors a pointer or key can open in one frame.
pub const max_anchors = 16;
/// Items of an open menu and its submenus that input reaches in one frame.
pub const max_items = 128;
/// Narrowest a menu panel is laid out, in DIP.
pub const min_width: f32 = 160;
/// Padding a menu panel keeps around its items, in DIP.
pub const panel_padding: f32 = 4;
/// Height of a separator between items, in DIP.
pub const separator_height: f32 = 9;

pub const ItemOptions = struct {
    /// A check box item: checked or not. Null for a plain item.
    checked: ?bool = null,
    /// Draw `checked` as a radio's dot, for one of a group of choices.
    radio: bool = false,
    /// The shortcut shown at the end of the item, such as "Ctrl+C". It is
    /// only shown; bind the chord itself with `View.bindKey`.
    shortcut: []const u8 = "",
};

/// Which menu is open and where its highlight is. It belongs to the View
/// and outlives passes.
pub const State = struct {
    /// The open menu.
    open: ?u64 = null,
    /// Where a pointer opened it, from the anchor's top left corner; null
    /// opens it below the anchor.
    at: ?Point = null,
    /// The control that had focus as it opened, which takes focus back as
    /// an item is chosen or Escape closes it.
    opener: ?u64 = null,
    /// The items whose submenus show, from the top level down.
    path: [max_depth]u64 = undefined,
    path_len: usize = 0,
    /// The item the keys or the pointer are on.
    highlight: ?u64 = null,
    /// The next pass highlights the first enabled item of this level.
    first: ?u16 = null,
    /// The next pass focuses the highlight, or with none the first item.
    refocus: bool = false,
    /// The highlight is an item the menu built in this pass.
    seen: bool = false,
};

/// Geometry of the open menu that input routing needs between passes.
pub const Overlay = struct {
    pub const Anchor = struct {
        /// The menu's node id.
        id: u64,
        /// The anchor's node index and one past its last descendant.
        index: u32,
        end: u32,
        rect: Rect,
        origin: Point,
    };
    pub const Item = struct {
        id: u64,
        level: u16,
        rect: Rect,
        enabled: bool,
        submenu: bool,
        rtl: bool,
        initial: u8,
    };
    anchors: [max_anchors]Anchor = undefined,
    anchor_count: usize = 0,
    /// Panels of the open menu, from the top level down.
    panels: [max_depth]Rect = undefined,
    panel_count: usize = 0,
    items: [max_items]Item = undefined,
    item_count: usize = 0,

    pub fn clear(self: *Overlay) void {
        self.anchor_count = 0;
        self.panel_count = 0;
        self.item_count = 0;
    }
};

/// Starts a menu for the node just added, its anchor, shown while it is
/// open: build its items only when this returns true, and close it with
/// `end` either way. Named by `Style.name`.
pub fn popoverMenu(self: *View, style: Style) Error!bool {
    if (self.depth == 0) return error.UnbalancedContainer;
    const parent = &self.buffers.nodes[self.stack[self.depth - 1]];
    if (parent.last_child == none or self.buffers.nodes[parent.last_child].floats()) return error.NotContainer;
    const anchor_index = parent.last_child;
    const node = try self.openNode(.menu, panelStyle(style));
    node.anchor = anchor_index;
    node.level = 0;
    const anchor = &self.buffers.nodes[anchor_index];
    node.concealed = node.concealed or anchor.concealed;
    const state = &self.menu;
    if (state.open) |id| if (id == node.id and (!anchor.style.enabled or node.concealed)) close(self, false);
    node.checked = if (state.open) |id| id == node.id else false;
    return node.checked;
}

/// An item of the menu being built. True for the pass that delivers its
/// choice, by press, Enter or Space; the menu then closes.
pub fn menuItem(self: *View, label: []const u8, options: ItemOptions, style: Style) Error!bool {
    const panel = try currentPanel(self);
    const node = try item(self, panel, label, style);
    node.mark = if (options.checked == null) .none else if (options.radio) .radio else .check;
    node.checked = options.checked orelse false;
    node.badge = try self.copyText(options.shortcut);
    if (self.takeEvent(node.id) == null or !node.style.enabled) return false;
    close(self, true);
    return true;
}

/// An item that opens a submenu beside it, and starts that submenu: build
/// its items only when this returns true, and close it with `end` either
/// way.
pub fn submenu(self: *View, label: []const u8, style: Style) Error!bool {
    const panel = try currentPanel(self);
    const level = panel.level;
    const panel_id = panel.id;
    const node = try item(self, panel, label, style);
    const index: u32 = @intCast(node - self.buffers.nodes.ptr);
    const id = node.id;
    const state = &self.menu;
    if (self.takeEvent(id) != null and node.style.enabled) {
        openLevel(state, level, id);
        state.highlight = id;
    }
    const shown = node.style.enabled and state.path_len > level and state.path[level] == id;
    node.expanded = shown;
    if (level + 1 >= max_depth) return error.NestingTooDeep;
    const inner = try self.openNode(.menu, panelStyle(.{ .name = label }));
    inner.anchor = index;
    inner.level = level + 1;
    inner.semantic_parent = panel_id;
    inner.checked = shown;
    return shown;
}

/// A line between groups of items.
pub fn menuSeparator(self: *View) Error!void {
    _ = try currentPanel(self);
    _ = try self.appendNode(.menu_separator, .{});
}

fn panelStyle(style: Style) Style {
    var value = style;
    if (value.padding.top == 0 and value.padding.bottom == 0 and value.padding.left == 0 and value.padding.right == 0) value.padding = Insets.all(panel_padding);
    if (value.min_width == 0) value.min_width = min_width;
    return value;
}

fn currentPanel(self: *View) Error!*Node {
    if (self.depth == 0) return error.UnbalancedContainer;
    const panel = &self.buffers.nodes[self.stack[self.depth - 1]];
    if (panel.kind != .menu) return error.NotContainer;
    return panel;
}

fn item(self: *View, panel: *Node, label: []const u8, style: Style) Error!*Node {
    const level = panel.level;
    const panel_id = panel.id;
    const node = try self.appendNode(.menu_item, style);
    node.text = try self.copyText(label);
    node.level = level;
    node.semantic_parent = panel_id;
    const id = node.id;
    const state = &self.menu;
    if (state.first) |wanted| if (wanted == level and node.style.enabled) {
        state.first = null;
        state.highlight = id;
        state.refocus = true;
    };
    if (state.refocus and node.style.enabled) if (state.highlight orelse id == id) {
        state.refocus = false;
        self.restore = id;
    };
    node.highlighted = if (state.highlight) |current| current == id else false;
    if (node.highlighted) state.seen = true;
    return node;
}

/// Show the submenu of `id`, an item of `level`, and close deeper ones.
fn openLevel(state: *State, level: u16, id: u64) void {
    state.path[level] = id;
    state.path_len = level + 1;
}

/// Close the open menu; with `restore`, focus goes back to its opener.
pub fn close(self: *View, restore: bool) void {
    const state = &self.menu;
    if (restore) if (state.opener) |id| {
        self.restore = id;
    };
    state.* = .{};
    self.overlay.menu.panel_count = 0;
    self.overlay.menu.item_count = 0;
}

/// Close the menu once its anchor is no longer built, and forget submenus
/// and a highlight the build no longer made. Called as a pass finishes.
pub fn finish(self: *View) void {
    const state = &self.menu;
    const id = state.open orelse return;
    const all = self.buffers.nodes[0..self.len];
    const present = for (all) |*node| {
        if (node.id == id and node.kind == .menu and node.checked) break true;
    } else false;
    if (!present) {
        const within = if (self.focus) |focused| for (all) |*node| {
            if (node.id == focused and node.kind == .menu_item) break true;
        } else false else false;
        close(self, within);
        return;
    }
    var level: usize = 0;
    while (level < state.path_len) : (level += 1) {
        const shown = for (all) |*node| {
            if (node.id == state.path[level] and node.kind == .menu_item and node.expanded == true) break true;
        } else false;
        if (!shown) {
            state.path_len = level;
            break;
        }
    }
    if (!state.seen) state.highlight = null;
    state.seen = false;
}

/// Where a menu panel goes: at the pointer that opened it or below its
/// anchor, a submenu beside its item, flipped and kept within `window`.
pub fn bounds(self: *const View, node: *const Node, window: Rect) Rect {
    const anchor = self.buffers.nodes[node.anchor].bounds;
    const preferred = node.measured.preferred;
    const width = @min(@max(preferred.width, node.style.min_width), window.width);
    const height = @min(preferred.height, window.height);
    const right = window.x + window.width;
    const bottom = window.y + window.height;
    var x: f32 = undefined;
    var y: f32 = undefined;
    if (node.level == 0) {
        const point: Point = if (self.menu.at) |at| .{ .x = anchor.x + at.x, .y = anchor.y + at.y } else .{ .x = if (node.rtl) anchor.x + anchor.width else anchor.x, .y = anchor.y + anchor.height };
        x = if (node.rtl) point.x - width else point.x;
        if (node.rtl and x < window.x) x = point.x else if (!node.rtl and x + width > right) x = point.x - width;
        y = point.y;
        if (y + height > bottom) y = (if (self.menu.at == null) anchor.y else point.y) - height;
    } else {
        // A submenu's items line up with the item that opens it.
        const pad = node.style.padding;
        const after = anchor.x + anchor.width + pad.left;
        const before = anchor.x - pad.right - width;
        x = if (node.rtl) before else after;
        if (node.rtl and x < window.x) x = after else if (!node.rtl and x + width > right) x = before;
        y = anchor.y - pad.top;
        if (y + height > bottom) y = anchor.y + anchor.height + pad.bottom - height;
    }
    x = std.math.clamp(x, window.x, @max(window.x, right - width));
    y = std.math.clamp(y, window.y, @max(window.y, bottom - height));
    return .{ .x = x, .y = y, .width = width, .height = height };
}

/// Keep what input needs from one arranged node.
pub fn record(self: *View, node: *const Node) void {
    const overlay = &self.overlay.menu;
    const all = self.buffers.nodes[0..self.len];
    switch (node.kind) {
        .menu => {
            if (node.level == 0 and overlay.anchor_count < max_anchors) {
                const anchor = &all[node.anchor];
                if (anchor.style.enabled) if (self.visible(anchor)) |rect| {
                    overlay.anchors[overlay.anchor_count] = .{ .id = node.id, .index = node.anchor, .end = anchor.end, .rect = rect, .origin = .{ .x = anchor.bounds.x, .y = anchor.bounds.y } };
                    overlay.anchor_count += 1;
                };
            }
            if (node.checked and overlay.panel_count < max_depth) {
                overlay.panels[overlay.panel_count] = node.bounds;
                overlay.panel_count += 1;
            }
        },
        .menu_item => if (overlay.item_count < max_items) {
            overlay.items[overlay.item_count] = .{ .id = node.id, .level = node.level, .rect = self.visible(node) orelse node.bounds, .enabled = node.style.enabled, .submenu = node.expanded != null, .rtl = node.rtl, .initial = initialOf(node.text) };
            overlay.item_count += 1;
        },
        else => {},
    }
}

fn initialOf(label: []const u8) u8 {
    if (label.len == 0) return 0;
    return std.ascii.toLower(label[0]);
}

/// The panel of the open menu under `point`.
pub fn panelAt(self: *const View, point: Point) bool {
    if (self.menu.open == null) return false;
    const overlay = &self.overlay.menu;
    for (overlay.panels[0..overlay.panel_count]) |rect| if (contains(rect, point)) return true;
    return false;
}

fn itemAt(self: *const View, point: Point) ?Overlay.Item {
    const overlay = &self.overlay.menu;
    // Deeper panels go over shallower ones.
    var index = overlay.item_count;
    var found: ?Overlay.Item = null;
    var level: i32 = -1;
    while (index > 0) {
        index -= 1;
        const entry = overlay.items[index];
        if (entry.level < level or !contains(entry.rect, point)) continue;
        if (!contains(overlay.panels[@min(entry.level, overlay.panel_count -| 1)], point)) continue;
        found = entry;
        level = entry.level;
    }
    return found;
}

/// A primary or secondary press while a menu is open: one on a panel stays
/// with the menu, an item's press going on to the item, and one elsewhere
/// closes the menu and goes on to what lies under it.
pub fn pointerDown(self: *View, point: Point) ?PointerRoute {
    if (self.menu.open == null) return null;
    if (panelAt(self, point)) {
        if (itemAt(self, point)) |entry| if (entry.enabled) return .ignored;
        return .consumed;
    }
    close(self, false);
    return .changed;
}

/// Open the menu of the innermost anchor under a secondary press at
/// `point`; true when one opened.
pub fn openAt(self: *View, point: Point) bool {
    const overlay = &self.overlay.menu;
    var best: ?Overlay.Anchor = null;
    for (overlay.anchors[0..overlay.anchor_count]) |anchor| {
        if (!contains(anchor.rect, point)) continue;
        if (best == null or anchor.index > best.?.index) best = anchor;
    }
    const anchor = best orelse return false;
    const opener = self.focus;
    close(self, false);
    self.menu = .{ .open = anchor.id, .at = .{ .x = point.x - anchor.origin.x, .y = point.y - anchor.origin.y }, .opener = opener, .refocus = true };
    return true;
}

/// The pointer over an item highlights it and shows its submenu, closing
/// deeper ones; true when that changed anything.
pub fn hover(self: *View, point: ?Point) bool {
    const state = &self.menu;
    if (state.open == null) return false;
    const at = point orelse return false;
    const entry = itemAt(self, at) orelse return false;
    if (!entry.enabled) return false;
    const path_len: usize = if (entry.submenu) entry.level + 1 else entry.level;
    const same_path = path_len == state.path_len and (!entry.submenu or state.path[entry.level] == entry.id);
    if (state.highlight == entry.id and same_path) return false;
    state.highlight = entry.id;
    state.refocus = true;
    if (entry.submenu) openLevel(state, entry.level, entry.id) else state.path_len = @min(state.path_len, entry.level);
    return true;
}

/// Keys while a menu is open, and the menu key or Shift+F10 that opens one
/// around the focused control.
pub fn routeKey(self: *View, input: z.KeyInput) ?KeyRoute {
    const mods = input.modifiers;
    const plain = !mods.control and !mods.alt and !mods.super and !mods.shift;
    const state = &self.menu;
    if (state.open == null) {
        const menu_key = (input.key == .context_menu and plain) or (input.key == .f10 and mods.shift and !mods.control and !mods.alt and !mods.super);
        if (!menu_key or input.repeat) return null;
        return if (openFromFocus(self)) .handled else null;
    }
    const overlay = &self.overlay.menu;
    const items = overlay.items[0..overlay.item_count];
    const current: ?Overlay.Item = if (state.highlight) |id| for (items) |entry| {
        if (entry.id == id) break entry;
    } else null else null;
    const level: u16 = if (current) |entry| entry.level else @intCast(state.path_len);
    var key = input.key;
    // Right to left, Left opens a submenu and Right closes it.
    const rtl = if (current) |entry| entry.rtl else for (items) |entry| {
        if (entry.level == level) break entry.rtl;
    } else false;
    if (rtl and (key == .left or key == .right)) key = if (key == .left) .right else .left;
    switch (key) {
        .down, .up, .home, .end => {
            if (!plain) return .handled;
            moveHighlight(self, items, level, current, key);
            return .handled;
        },
        .right, .enter, .space => {
            if (!plain) return .handled;
            const entry = current orelse return .handled;
            if (entry.submenu) {
                if (input.repeat and key != .right) return .handled;
                openLevel(state, entry.level, entry.id);
                state.first = entry.level + 1;
                return .handled;
            }
            if (key == .right or input.repeat) return .handled;
            return .{ .deliver = .{ .action = entry.id } };
        },
        .left, .escape => {
            if (!plain) return .handled;
            if (level > 0 and state.path_len >= level) {
                const parent = state.path[level - 1];
                state.path_len = level - 1;
                state.highlight = parent;
                state.refocus = true;
                self.restore = parent;
                return .handled;
            }
            if (key == .escape) close(self, true);
            return .handled;
        },
        .tab, .context_menu => {
            close(self, true);
            return .handled;
        },
        else => {
            if (mods.control or mods.alt or mods.super) return .handled;
            const letter = keyInitial(input.key) orelse return .handled;
            var start: usize = 0;
            if (current) |entry| for (items, 0..) |candidate, i| {
                if (candidate.id == entry.id) start = i + 1;
            };
            for (0..items.len) |step| {
                const candidate = items[(start + step) % items.len];
                if (candidate.level != level or !candidate.enabled or candidate.initial != letter) continue;
                highlight(self, candidate);
                break;
            }
            return .handled;
        },
    }
}

fn highlight(self: *View, entry: Overlay.Item) void {
    const state = &self.menu;
    state.highlight = entry.id;
    state.path_len = @min(state.path_len, entry.level);
    state.refocus = true;
    self.restore = entry.id;
}

fn moveHighlight(self: *View, items: []const Overlay.Item, level: u16, current: ?Overlay.Item, key: z.KeyCode) void {
    var members: [max_items]usize = undefined;
    var count: usize = 0;
    var at: ?usize = null;
    for (items, 0..) |entry, i| {
        if (entry.level != level or !entry.enabled) continue;
        if (current) |value| if (value.id == entry.id) {
            at = count;
        };
        members[count] = i;
        count += 1;
    }
    if (count == 0) return;
    const next: usize = switch (key) {
        .home => 0,
        .end => count - 1,
        .down => if (at) |i| (i + 1) % count else 0,
        else => if (at) |i| (i + count - 1) % count else count - 1,
    };
    highlight(self, items[members[next]]);
}

/// Open the menu of the innermost anchor around the focused control, below
/// the anchor, its first item highlighted.
fn openFromFocus(self: *View) bool {
    const focused = self.focus orelse return false;
    const all = self.buffers.nodes[0..self.len];
    const at = for (all, 0..) |*node, i| {
        if (node.id == focused) break i;
    } else return false;
    const overlay = &self.overlay.menu;
    var best: ?Overlay.Anchor = null;
    for (overlay.anchors[0..overlay.anchor_count]) |anchor| {
        if (at < anchor.index or at >= anchor.end) continue;
        if (best == null or anchor.index > best.?.index) best = anchor;
    }
    const anchor = best orelse return false;
    self.menu = .{ .open = anchor.id, .opener = focused, .first = 0 };
    return true;
}

fn keyInitial(code: z.KeyCode) ?u8 {
    const value = @backingInt(code);
    if (value >= @backingInt(z.KeyCode.a) and value <= @backingInt(z.KeyCode.z)) return 'a' + @as(u8, @intCast(value - @backingInt(z.KeyCode.a)));
    if (value >= @backingInt(z.KeyCode.digit0) and value <= @backingInt(z.KeyCode.digit9)) return '0' + @as(u8, @intCast(value - @backingInt(z.KeyCode.digit0)));
    return null;
}

fn contains(rect: Rect, point: Point) bool {
    return point.x >= rect.x and point.y >= rect.y and point.x < rect.x + rect.width and point.y < rect.y + rect.height;
}

const none = std.math.maxInt(u32);
