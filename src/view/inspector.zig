//! The inspector shows the elements of a view in a panel docked beside the
//! content, as a browser's developer tools show a page's: the tree of
//! elements as markup, the styles, box model and properties of the one
//! chosen in the tree or picked in the window, which it outlines over the
//! content with a tooltip, how long frames take, and issues, such as two
//! elements given the same key under one parent.
//!
//! A Host or Harness given one in `Options.inspector` opens it with F12 or
//! Ctrl+Shift+I and picks with Ctrl+Shift+C; Escape stops picking. The
//! content gets the window less the panel, and the panel shows the elements
//! of the frame before, which the inspector copies after each frame is laid
//! out. It paints itself over the frame after the view and takes the input
//! that lands on it before the view, so it adds no nodes, controls or
//! accessibility elements to the view's own. Ctrl+F finds elements in the
//! tree by tag, text, name or key, and the details tell where the
//! application built the element chosen, read from the build's debug
//! information. Nothing here allocates but that lookup: the application
//! keeps the inspector, which holds the copy, at a stable address. Builds
//! without it (release builds unless `-Dinspector=true`) leave it out.
const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("root.zig");

const View = view.View;
const Node = view.Node;
const Kind = view.Kind;
const Rect = view.Rect;
const Point = view.Point;
const Size = view.Size;
const Font = view.Font;
const Measurer = view.Measurer;
const Cursor = view.Cursor;
const Direction = view.Direction;

/// Whether this build has the inspector; without it, Host and Harness
/// ignore `Options.inspector` and none of this is compiled in.
pub const enabled = @import("ziggurat_view_options").inspector;

/// Elements the inspector copies from a frame; a larger frame shows its
/// first ones and notes the rest as an issue.
pub const max_elements = 1024;
/// Bytes of the elements' texts and names it copies.
pub const text_capacity = 32 * 1024;
/// Frames the Performance tab shows.
pub const history_len = 120;
/// Width the panel starts at, in DIP; dragging its left edge resizes it.
pub const default_width: f32 = 420;
pub const max_issues = 16;

pub const Tab = enum { elements, performance, issues };
pub const Side = enum { styles, computed, properties };

/// An element of the last frame: what the tree, the details and the
/// highlight read.
pub const Element = struct {
    id: u64,
    kind: Kind,
    depth: u16,
    /// Index of the element it is in, or -1 for the root.
    parent: i32,
    kids: bool = false,
    bounds: Rect,
    /// What clips and floating leave visible, or null when nothing is.
    visible: ?Rect = null,
    floating: bool = false,
    text: []const u8 = "",
    name: []const u8 = "",
    key: ?u64 = null,
    axis: view.Axis = .column,
    gap: f32 = 0,
    padding: view.Insets = .{},
    alignment: view.Align = .stretch,
    justify: view.Justify = .start,
    self_align: ?view.Align = null,
    clip: bool = false,
    grow: f32 = 0,
    shrink: f32 = 1,
    width: ?f32 = null,
    height: ?f32 = null,
    min_width: f32 = 0,
    min_height: f32 = 0,
    max_width: f32 = std.math.inf(f32),
    max_height: f32 = std.math.inf(f32),
    background: ?u32 = null,
    border: ?u32 = null,
    border_width: f32 = 1,
    radius: f32 = 0,
    color: ?u32 = null,
    font: ?Font = null,
    enabled: bool = true,
    opacity: f32 = 1,
    cursor: ?Cursor = null,
    wrap: bool = false,
    max_lines: u16 = 0,
    direction: ?Direction = null,
    rtl: bool = false,
    material: bool = false,
    pose: bool = false,
    effect: bool = false,
    checked: bool = false,
    value: f64 = 0,
    scroll_offset: ?Point = null,
    scroll_content: Size = .{},
};

const Row = struct { node: u16, close: bool };
const Opened = struct { id: u64, open: bool };

/// Colors of the panel, light or dark with the theme.
const Palette = struct {
    bg: u32,
    toolbar: u32,
    border: u32,
    text: u32,
    muted: u32,
    accent: u32,
    selected: u32,
    unfocused: u32,
    hover: u32,
    tag: u32,
    attr: u32,
    value: u32,
    prop: u32,
    str: u32,
    lit: u32,
    warn: u32,

    fn of(night: bool) Palette {
        if (night) return .{ .bg = 0x202124, .toolbar = 0x292a2d, .border = 0x494c50, .text = 0xe8eaed, .muted = 0x9aa0a6, .accent = 0x8ab4f8, .selected = 0x0f3a66, .unfocused = 0x3c4043, .hover = 0x2f3237, .tag = 0x5db0d7, .attr = 0x9bbbdc, .value = 0xf29766, .prop = 0x5cd5fb, .str = 0xf28b54, .lit = 0x9980ff, .warn = 0xfdd663 };
        return .{ .bg = 0xffffff, .toolbar = 0xf1f3f4, .border = 0xcbcdd1, .text = 0x202124, .muted = 0x5f6368, .accent = 0x1a73e8, .selected = 0xcfe8fc, .unfocused = 0xe3e3e3, .hover = 0xebf1fb, .tag = 0x881280, .attr = 0x994500, .value = 0x1a1aa6, .prop = 0xc80000, .str = 0xc41a16, .lit = 0x1a1aa6, .warn = 0xe37400 };
    }
};

// The boxes of an element highlighted over the content: content in blue,
// padding in green and border in yellow.
const highlight_content = color(0x6fa8dc, 168);
const highlight_padding = color(0x93c47d, 140);
const highlight_border = color(0xffe599, 168);
// The parts of a frame in the Performance tab.
const build_color: u32 = 0xf2b630;
const layout_color: u32 = 0x9a7fd1;
const paint_color: u32 = 0x71b362;

const toolbar_height: f32 = 30;
const tab_height: f32 = 26;
const row_height: f32 = 20;
const crumbs_height: f32 = 24;
const find_height: f32 = 28;
const indent: f32 = 14;
const edge_width: f32 = 6;
const divider_height: f32 = 6;
const ui_font: Font = .{ .size = 12 };
const small_font: Font = .{ .size = 11 };
const mono_font: Font = .{ .size = 11.5, .monospace = true };
const big_font: Font = .{ .size = 18, .weight = .semibold };

fn color(rgb: u32, alpha: u8) ui.Color {
    var value = ui.Color.rgb(rgb);
    value.a = alpha;
    return value;
}
fn contains(rect: Rect, point: Point) bool {
    return point.x >= rect.x and point.y >= rect.y and point.x < rect.x + rect.width and point.y < rect.y + rect.height;
}
fn inset(rect: Rect, left: f32, top: f32, right: f32, bottom: f32) Rect {
    return .{ .x = rect.x + left, .y = rect.y + top, .width = @max(0, rect.width - left - right), .height = @max(0, rect.height - top - bottom) };
}

pub const Inspector = struct {
    /// The window's developer tools let it open; when unset the keys pass
    /// to the view.
    enabled: bool = true,
    open: bool = false,
    /// Set while the pointer picks an element in the content; `swallow`
    /// while the release of the press that picked it goes nowhere.
    picking: bool = false,
    swallow: bool = false,
    /// The panel has the keyboard: the last press landed on it.
    focused: bool = false,
    /// The element chosen, and the element under the pointer in the tree,
    /// in the breadcrumbs, or in the content while picking.
    selected: u64 = 0,
    hovered: u64 = 0,
    /// Show the element chosen in the tree, opening the elements around it.
    reveal: bool = false,
    tab: Tab = .elements,
    side: Side = .styles,
    width: f32 = default_width,
    /// Height of the tree above the details, 0 until the panel is shown.
    split: f32 = 0,
    /// Lay the window out right to left, or back, to try it before it is
    /// translated; the Host applies it. The panel stays left to right.
    direction_override: ?Direction = null,
    /// The display's refresh rate, for the frame budget.
    refresh_hz: f32 = 60,
    /// The find bar of the tree (Ctrl+F): its query, the elements matching
    /// it in the order of the tree, and the one shown among them.
    finding: bool = false,
    query: [128]u8 = undefined,
    query_len: usize = 0,
    matches: [max_elements]u16 = undefined,
    match_count: usize = 0,
    match: usize = 0,
    /// Where the application built the element chosen: the return
    /// addresses the view noted while building it, and the first of them
    /// outside the view's own code as a file and line.
    trace: [view.source_depth]usize = undefined,
    trace_len: usize = 0,
    source_buffer: [512]u8 = undefined,
    source_len: usize = 0,

    elements: [max_elements]Element = undefined,
    len: usize = 0,
    /// Elements the last frame had, beyond those copied.
    total: usize = 0,
    text: [text_capacity]u8 = undefined,
    text_len: usize = 0,
    rows: [2 * max_elements]Row = undefined,
    row_count: usize = 0,
    opened: [256]Opened = undefined,
    opened_len: usize = 0,
    tree_scroll: f32 = 0,
    side_scroll: f32 = 0,
    side_content: f32 = 0,
    issues_scroll: f32 = 0,
    issues: [max_issues][160]u8 = undefined,
    issue_lens: [max_issues]u8 = undefined,
    issue_ids: [max_issues]u64 = undefined,
    issue_count: usize = 0,
    /// The focused control and the pointer as of the copied frame.
    focus: ?u64 = null,
    pointer: ?Point = null,
    /// How long the last frame took to build, lay out and paint, and the
    /// times of the last frames, `frames` of them in all.
    times: [3]u64 = .{ 0, 0, 0 },
    history: [history_len][3]u64 = undefined,
    frames: usize = 0,
    /// Width the window gave the content, and the window's bounds.
    app_width: f32 = 0,
    window: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    measurer: Measurer = .{},
    palette: Palette = Palette.of(false),
    /// A drag of the panel's left edge or of the divider above the details.
    dragging: ?enum { edge, divider } = null,
    drag_start: f32 = 0,
    drag_value: f32 = 0,
    /// A press went down on the panel; its release is the panel's too.
    held: bool = false,

    /// The bounds the content gets in a window with `bounds`: all of it
    /// while closed, otherwise less the panel at the right.
    pub fn contentBounds(self: *Inspector, bounds: Rect) Rect {
        self.window = bounds;
        if (!self.open) {
            self.app_width = bounds.width;
            return bounds;
        }
        var panel = std.math.clamp(self.width, 260, @max(260, bounds.width - 160));
        if (bounds.width < 520) panel = bounds.width / 2;
        self.app_width = @max(0, bounds.width - panel);
        return .{ .x = bounds.x, .y = bounds.y, .width = self.app_width, .height = bounds.height };
    }
    fn panelRect(self: *const Inspector) Rect {
        return .{ .x = self.window.x + self.app_width, .y = self.window.y, .width = self.window.width - self.app_width, .height = self.window.height };
    }

    pub fn toggle(self: *Inspector) void {
        self.open = !self.open;
        self.picking = false;
        self.hovered = 0;
        self.dragging = null;
        if (!self.open) self.focused = false;
    }

    /// Note how long the last frame took to build, lay out and paint.
    pub fn frameTimes(self: *Inspector, build_ns: u64, layout_ns: u64, paint_ns: u64) void {
        if (!self.open) return;
        self.times = .{ build_ns, layout_ns, paint_ns };
        self.history[self.frames % history_len] = self.times;
        self.frames += 1;
    }

    /// Copy the elements of `v`'s frame just laid out, with the focused
    /// control and the pointer, and note the issues it shows.
    pub fn capture(self: *Inspector, v: *const View, focus: ?u64, measurer: Measurer, theme: view.Theme) void {
        self.measurer = measurer;
        self.palette = Palette.of(dark(theme.palette.background));
        self.focus = focus;
        self.pointer = v.pointer;
        if (!self.open) return;
        const all = v.nodes();
        self.len = 0;
        self.text_len = 0;
        self.total = all.len;
        for (all, 0..) |*node, index| {
            if (self.len == max_elements) break;
            const parent: i32 = if (index == 0) -1 else @intCast(node.parent);
            const depth: u16 = if (parent < 0) 0 else self.elements[@intCast(parent)].depth + 1;
            if (parent >= 0) self.elements[@intCast(parent)].kids = true;
            const floating = node.floats() or (parent >= 0 and self.elements[@intCast(parent)].floating);
            const s = node.style;
            self.elements[self.len] = .{
                .id = node.id,
                .kind = node.kind,
                .depth = depth,
                .parent = parent,
                .bounds = node.bounds,
                .visible = if (node.hidden()) null else v.visible(node),
                .floating = floating,
                .text = self.copy(node.text),
                .name = self.copy(s.name),
                .key = s.key,
                .axis = if (node.kind == .row or node.kind == .toolbar or node.kind == .tab_list or node.kind == .segmented or node.kind == .breadcrumbs) .row else node.axis,
                .gap = s.gap,
                .padding = s.padding,
                .alignment = s.alignment,
                .justify = s.justify,
                .self_align = s.self_align,
                .clip = s.clip,
                .grow = s.grow,
                .shrink = s.shrink,
                .width = s.width,
                .height = s.height,
                .min_width = s.min_width,
                .min_height = s.min_height,
                .max_width = s.max_width,
                .max_height = s.max_height,
                .background = s.background,
                .border = s.border,
                .border_width = s.border_width,
                .radius = s.radius,
                .color = s.color,
                .font = s.font,
                .enabled = s.enabled,
                .opacity = s.opacity,
                .cursor = s.cursor,
                .wrap = s.wrap,
                .max_lines = s.max_lines,
                .direction = s.direction,
                .rtl = node.rtl,
                .material = s.material != null or s.refraction != null,
                .pose = s.pose != null,
                .effect = s.effect != null,
                .checked = node.checked,
                .value = node.value,
                .scroll_offset = if (node.scroll) |model| .{ .x = model.offset.x, .y = model.offset.y } else null,
                .scroll_content = node.content,
            };
            self.len += 1;
        }
        self.noteDuplicates();
        self.noteSource(v.source_trace[0..v.source_len]);
        if (self.finding) self.findMatches();
        if (self.total > max_elements) self.addIssue(1, "The frame has more elements than the inspector copies; the tree shows the first {d}.", .{max_elements});
        self.listRows();
        if (self.reveal and self.selected != 0) {
            self.reveal = false;
            if (self.expandTo(self.selected)) self.listRows();
            self.scrollToSelected();
        }
    }

    /// Where the element chosen was built: the trace the view noted for it,
    /// looked up when it changed.
    fn noteSource(self: *Inspector, trace: []const usize) void {
        if (std.mem.eql(usize, trace, self.trace[0..self.trace_len])) return;
        const n = @min(trace.len, self.trace.len);
        @memcpy(self.trace[0..n], trace[0..n]);
        self.trace_len = n;
        self.source_len = 0;
        if (n > 0) self.source_len = locateSource(trace[0..n], &self.source_buffer).len;
    }
    /// Where the application built the element chosen, as `file:line`, or
    /// "" when the build has no debug information.
    pub fn source(self: *const Inspector) []const u8 {
        return self.source_buffer[0..self.source_len];
    }

    // The find bar.

    /// The query of the find bar.
    pub fn findQuery(self: *const Inspector) []const u8 {
        return self.query[0..self.query_len];
    }
    /// The elements whose tag, text, name or key holds the query, whatever
    /// the case.
    fn findMatches(self: *Inspector) void {
        self.match_count = 0;
        const q = self.findQuery();
        if (q.len == 0) return;
        for (self.elements[0..self.len], 0..) |*e, index| {
            var names: [32]u8 = undefined;
            var digits: [24]u8 = undefined;
            const key_text = if (e.key) |value| std.fmt.bufPrint(&digits, "{d}", .{value}) catch "" else "";
            if (std.ascii.findIgnoreCase(tagName(e.kind, &names), q) != null or std.ascii.findIgnoreCase(e.text, q) != null or
                std.ascii.findIgnoreCase(e.name, q) != null or std.ascii.findIgnoreCase(key_text, q) != null)
            {
                self.matches[self.match_count] = @intCast(index);
                self.match_count += 1;
            }
        }
        if (self.match >= self.match_count) self.match = 0;
    }
    /// Open the find bar, or give it the keyboard.
    pub fn startFind(self: *Inspector) void {
        if (!self.open) self.toggle();
        self.finding = true;
        self.focused = true;
        self.tab = .elements;
        self.findMatches();
    }
    pub fn endFind(self: *Inspector) void {
        self.finding = false;
        self.match_count = 0;
    }
    /// Show match `index`: choose it and open the tree around it.
    fn showMatch(self: *Inspector, index: usize) void {
        if (self.match_count == 0) return;
        self.match = index % self.match_count;
        self.choose(self.elements[self.matches[self.match]].id);
        if (self.expandTo(self.selected)) self.listRows();
        self.scrollToSelected();
    }
    /// The next match, or the one before.
    pub fn findNext(self: *Inspector, back: bool) void {
        if (self.match_count == 0) return;
        self.showMatch(if (back) self.match + self.match_count - 1 else self.match + 1);
    }
    /// Text typed while the find bar has the keyboard goes into its query,
    /// which shows its first match. True when taken.
    pub fn typeText(self: *Inspector, value: []const u8) bool {
        if (!self.open or !self.finding or !self.focused) return false;
        for (value) |byte| if (byte < 0x20 or byte == 0x7f) return true;
        if (self.query_len + value.len > self.query.len) return true;
        @memcpy(self.query[self.query_len..][0..value.len], value);
        self.query_len += value.len;
        self.queryChanged();
        return true;
    }
    fn queryChanged(self: *Inspector) void {
        self.findMatches();
        self.showMatch(0);
    }

    fn copy(self: *Inspector, value: []const u8) []const u8 {
        const room = self.text.len - self.text_len;
        var n = @min(value.len, room, 400);
        while (n > 0 and n < value.len and value[n] & 0xc0 == 0x80) n -= 1;
        const out = self.text[self.text_len..][0..n];
        @memcpy(out, value[0..n]);
        self.text_len += n;
        return out;
    }

    /// Two elements with the same id share one state: two given the same
    /// key under one parent. Each is noted once.
    fn noteDuplicates(self: *Inspector) void {
        const list = self.elements[0..self.len];
        for (list, 0..) |*a, i| {
            for (list[i + 1 ..]) |*b| {
                if (a.id != b.id) continue;
                const parent = if (b.parent >= 0) list[@intCast(b.parent)].kind else .column;
                var name: [32]u8 = undefined;
                var parent_name: [32]u8 = undefined;
                if (a.key) |value| {
                    self.addIssue(a.id, "Two <{s}> elements have key {d} under one <{s}>: a click, the focus or scrolling meant for one goes to the other.", .{ tagName(a.kind, &name), value, tagName(parent, &parent_name) });
                } else self.addIssue(a.id, "Two <{s}> elements under one <{s}> share one identity: give them keys.", .{ tagName(a.kind, &name), tagName(parent, &parent_name) });
                break;
            }
        }
    }
    fn addIssue(self: *Inspector, id: u64, comptime format: []const u8, args: anytype) void {
        for (self.issue_ids[0..self.issue_count]) |known| if (known == id) return;
        if (self.issue_count == max_issues) return;
        const written = std.fmt.bufPrint(&self.issues[self.issue_count], format, args) catch self.issues[self.issue_count][0..];
        self.issue_lens[self.issue_count] = @intCast(written.len);
        self.issue_ids[self.issue_count] = id;
        self.issue_count += 1;
    }
    pub fn issue(self: *const Inspector, index: usize) []const u8 {
        return self.issues[index][0..self.issue_lens[index]];
    }

    // The tree.

    fn isOpen(self: *const Inspector, element: *const Element) bool {
        for (self.opened[0..self.opened_len]) |entry| if (entry.id == element.id) return entry.open;
        return element.depth < 3;
    }
    fn setOpenId(self: *Inspector, id: u64, open: bool) void {
        for (self.opened[0..self.opened_len]) |*entry| if (entry.id == id) {
            entry.open = open;
            return;
        };
        if (self.opened_len == self.opened.len) {
            std.mem.copyForwards(Opened, self.opened[0 .. self.opened.len - 1], self.opened[1..]);
            self.opened_len -= 1;
        }
        self.opened[self.opened_len] = .{ .id = id, .open = open };
        self.opened_len += 1;
    }
    /// Open or close element `index`, and with `all` everything inside it.
    pub fn setOpen(self: *Inspector, index: usize, open: bool, all: bool) void {
        const element = &self.elements[index];
        self.setOpenId(element.id, open);
        if (all) {
            var j = index + 1;
            while (j < self.len and self.elements[j].depth > element.depth) : (j += 1) {
                if (self.elements[j].kids) self.setOpenId(self.elements[j].id, open);
            }
        }
        self.listRows();
    }
    fn expandTo(self: *Inspector, id: u64) bool {
        var index = self.indexOf(id) orelse return false;
        var changed = false;
        while (self.elements[index].parent >= 0) {
            index = @intCast(self.elements[index].parent);
            if (!self.isOpen(&self.elements[index])) {
                self.setOpenId(self.elements[index].id, true);
                changed = true;
            }
        }
        return changed;
    }
    pub fn indexOf(self: *const Inspector, id: u64) ?usize {
        for (self.elements[0..self.len], 0..) |*element, index| if (element.id == id) return index;
        return null;
    }
    /// The rows the tree shows: elements inside none closed, and the
    /// closing tags of the elements open.
    fn listRows(self: *Inspector) void {
        self.row_count = 0;
        var open: [view.max_depth + 4]u16 = undefined;
        var open_len: usize = 0;
        var hide: ?u16 = null;
        for (self.elements[0..self.len], 0..) |*element, index| {
            while (open_len > 0 and self.elements[open[open_len - 1]].depth >= element.depth) {
                open_len -= 1;
                self.pushRow(open[open_len], true);
            }
            if (hide) |depth| {
                if (element.depth > depth) continue;
                hide = null;
            }
            self.pushRow(@intCast(index), false);
            if (element.kids) {
                if (self.isOpen(element) and open_len < open.len) {
                    open[open_len] = @intCast(index);
                    open_len += 1;
                } else hide = element.depth;
            }
        }
        while (open_len > 0) {
            open_len -= 1;
            self.pushRow(open[open_len], true);
        }
    }
    fn pushRow(self: *Inspector, node: u16, close: bool) void {
        if (self.row_count == self.rows.len) return;
        self.rows[self.row_count] = .{ .node = node, .close = close };
        self.row_count += 1;
    }
    pub fn rowOf(self: *const Inspector, id: u64) ?usize {
        for (self.rows[0..self.row_count], 0..) |row, index| if (!row.close and self.elements[row.node].id == id) return index;
        return null;
    }
    /// Choose element `id`, as a click on its row does.
    pub fn choose(self: *Inspector, id: u64) void {
        if (id != self.selected) {
            self.selected = id;
            self.side_scroll = 0;
        }
    }
    fn scrollToSelected(self: *Inspector) void {
        const row = self.rowOf(self.selected) orelse return;
        const tree = self.layout().tree;
        const top = @as(f32, @floatFromInt(row)) * row_height;
        if (top < self.tree_scroll) self.tree_scroll = top;
        if (top + row_height > self.tree_scroll + tree.height) self.tree_scroll = top + row_height - tree.height;
        self.clampScroll();
    }
    fn clampScroll(self: *Inspector) void {
        const l = self.layout();
        const tree_max = @max(0, @as(f32, @floatFromInt(self.row_count)) * row_height + 4 - l.tree.height);
        self.tree_scroll = std.math.clamp(self.tree_scroll, 0, tree_max);
        self.side_scroll = std.math.clamp(self.side_scroll, 0, @max(0, self.side_content - l.side.height));
        const issues_max = @max(0, @as(f32, @floatFromInt(self.issue_count)) * 34 - l.body.height);
        self.issues_scroll = std.math.clamp(self.issues_scroll, 0, issues_max);
    }

    /// The innermost element at `point` in the content, preferring what
    /// floats over the flow.
    pub fn elementAt(self: *const Inspector, point: Point) ?u64 {
        var best: ?usize = null;
        for (self.elements[0..self.len], 0..) |*element, index| {
            const rect = element.visible orelse continue;
            if (!contains(rect, point)) continue;
            if (best) |current| if (self.elements[current].floating and !element.floating) continue;
            best = index;
        }
        return if (best) |index| self.elements[index].id else null;
    }

    // Layout of the panel, shared by paint and input.

    /// The find bar above the tree: the query's field, the count of
    /// matches, and buttons for the match before, the next, and closing.
    pub const Find = struct { bar: Rect, field: Rect, previous: Rect, next: Rect, close: Rect };
    pub const Layout = struct {
        panel: Rect,
        edge: Rect,
        toolbar: Rect,
        pick: Rect,
        tabs: [3]Rect,
        rtl: Rect,
        badge: ?Rect,
        close: Rect,
        body: Rect,
        tree: Rect,
        find: ?Find,
        crumbs: ?Rect,
        divider: Rect,
        side_tabs: [3]Rect,
        side: Rect,
    };
    fn textWidth(self: *const Inspector, value: []const u8, font: Font) f32 {
        return self.measurer.textSize(value, font).width;
    }
    fn issuesLabel(self: *const Inspector, buffer: []u8) []const u8 {
        if (self.issue_count == 0) return "Issues";
        return std.fmt.bufPrint(buffer, "Issues {d}", .{self.issue_count}) catch "Issues";
    }
    pub fn layout(self: *const Inspector) Layout {
        const panel = self.panelRect();
        const toolbar: Rect = .{ .x = panel.x, .y = panel.y, .width = panel.width, .height = toolbar_height };
        var x = panel.x + 4;
        const pick: Rect = .{ .x = x, .y = toolbar.y + 3, .width = 26, .height = 24 };
        x += 26 + 9;
        var tabs: [3]Rect = undefined;
        var label_buffer: [24]u8 = undefined;
        const labels = [_][]const u8{ "Elements", "Performance", self.issuesLabel(&label_buffer) };
        for (labels, 0..) |text, i| {
            const w = self.textWidth(text, ui_font) + 20;
            tabs[i] = .{ .x = x, .y = toolbar.y, .width = w, .height = toolbar_height };
            x += w;
        }
        var right = panel.x + panel.width - 4;
        const close: Rect = .{ .x = right - 26, .y = toolbar.y + 3, .width = 26, .height = 24 };
        right -= 26;
        var badge: ?Rect = null;
        if (self.issue_count > 0) {
            badge = .{ .x = right - 34, .y = toolbar.y + 3, .width = 34, .height = 24 };
            right -= 34;
        }
        const rtl_width = self.textWidth("RTL", ui_font) + 20;
        const rtl: Rect = .{ .x = right - rtl_width, .y = toolbar.y, .width = rtl_width, .height = toolbar_height };
        const body = inset(panel, 0, toolbar_height, 0, 0);
        const split = if (self.split > 0) self.split else @max(body.height * 0.55, 120);
        const top_height = std.math.clamp(split, 60, @max(60, body.height - 80));
        const has_crumbs = self.selected != 0 and self.indexOf(self.selected) != null;
        const crumbs: ?Rect = if (has_crumbs) .{ .x = body.x, .y = body.y + top_height - crumbs_height, .width = body.width, .height = crumbs_height } else null;
        const find_bar: f32 = if (self.finding) find_height else 0;
        const tree: Rect = .{ .x = body.x, .y = body.y + find_bar, .width = body.width, .height = @max(0, top_height - find_bar - (if (has_crumbs) crumbs_height else 0)) };
        const find: ?Find = if (self.finding) blk: {
            const bar: Rect = .{ .x = body.x, .y = body.y, .width = body.width, .height = find_height };
            const end: Rect = .{ .x = bar.x + bar.width - 26, .y = bar.y + 3, .width = 22, .height = 22 };
            const next: Rect = .{ .x = end.x - 24, .y = end.y, .width = 22, .height = 22 };
            const previous: Rect = .{ .x = next.x - 24, .y = end.y, .width = 22, .height = 22 };
            const count_width: f32 = 80;
            break :blk .{ .bar = bar, .field = .{ .x = bar.x + 6, .y = bar.y + 4, .width = @max(40, previous.x - count_width - bar.x - 10), .height = 20 }, .previous = previous, .next = next, .close = end };
        } else null;
        const divider: Rect = .{ .x = body.x, .y = body.y + top_height - divider_height / 2, .width = body.width, .height = divider_height };
        var side_tabs: [3]Rect = undefined;
        x = body.x + 4;
        for ([_][]const u8{ "Styles", "Computed", "Properties" }, 0..) |text, i| {
            const w = self.textWidth(text, ui_font) + 20;
            side_tabs[i] = .{ .x = x, .y = body.y + top_height, .width = w, .height = tab_height };
            x += w;
        }
        const side: Rect = .{ .x = body.x, .y = body.y + top_height + tab_height, .width = body.width, .height = @max(0, body.height - top_height - tab_height) };
        return .{ .panel = panel, .edge = .{ .x = panel.x - edge_width / 2, .y = panel.y, .width = edge_width, .height = panel.height }, .toolbar = toolbar, .pick = pick, .tabs = tabs, .rtl = rtl, .badge = badge, .close = close, .body = body, .tree = tree, .find = find, .crumbs = crumbs, .divider = divider, .side_tabs = side_tabs, .side = side };
    }

    // Input.

    /// A key press, before the view sees it: the inspector's own keys, and
    /// the tree's keys while the panel has the keyboard. True when taken.
    pub fn key(self: *Inspector, input: z.KeyInput) bool {
        const m = input.modifiers;
        const plain = !m.control and !m.shift and !m.alt and !m.super;
        if (self.picking and input.key == .escape and plain) {
            self.picking = false;
            self.hovered = 0;
            return true;
        }
        if (!self.enabled) return false;
        const command = m.control and m.shift and !m.alt and !m.super;
        if ((input.key == .f12 and plain) or (input.key == .i and command)) {
            self.toggle();
            return true;
        }
        if (input.key == .c and command) {
            if (!self.open) self.toggle();
            self.picking = !self.picking;
            self.hovered = 0;
            self.tab = .elements;
            return true;
        }
        if (!self.open or !self.focused or self.tab != .elements) return false;
        if (input.key == .f and m.control and !m.shift and !m.alt and !m.super) {
            self.startFind();
            return true;
        }
        if (self.finding) switch (input.key) {
            .escape => if (plain) {
                self.endFind();
                return true;
            },
            .enter => if (!m.control and !m.alt and !m.super) {
                self.findNext(m.shift);
                return true;
            },
            .backspace => if (plain) {
                if (self.query_len > 0) {
                    self.query_len -= 1;
                    while (self.query_len > 0 and self.query[self.query_len] & 0xc0 == 0x80) self.query_len -= 1;
                    self.queryChanged();
                }
                return true;
            },
            else => {},
        };
        if (!plain) return false;
        const current = self.rowOf(self.selected);
        switch (input.key) {
            .up, .down, .home, .end => {
                var row: usize = current orelse 0;
                switch (input.key) {
                    .up => while (row > 0) {
                        row -= 1;
                        if (!self.rows[row].close) break;
                    },
                    .down => {
                        var next = row;
                        while (next + 1 < self.row_count) {
                            next += 1;
                            if (!self.rows[next].close) {
                                row = next;
                                break;
                            }
                        }
                        if (current == null) row = 0;
                    },
                    .home => row = 0,
                    else => {
                        row = self.row_count -| 1;
                        while (row > 0 and self.rows[row].close) row -= 1;
                    },
                }
                if (row < self.row_count) {
                    self.choose(self.elements[self.rows[row].node].id);
                    self.scrollToSelected();
                }
                return true;
            },
            .left, .right => {
                const index = self.indexOf(self.selected) orelse return true;
                const element = &self.elements[index];
                const open = element.kids and self.isOpen(element);
                if (input.key == .left) {
                    if (open) self.setOpen(index, false, false) else if (element.parent >= 0) {
                        self.choose(self.elements[@intCast(element.parent)].id);
                        self.scrollToSelected();
                    }
                } else if (element.kids) {
                    if (!open) self.setOpen(index, true, false) else {
                        self.choose(self.elements[index + 1].id);
                        self.scrollToSelected();
                    }
                }
                return true;
            },
            else => return false,
        }
    }

    /// The pointer moved; true when it is the inspector's, as over the
    /// panel, while picking or while dragging. `repaint` is set when what
    /// the inspector shows changed.
    pub fn pointerMove(self: *Inspector, point: Point, repaint: *bool) bool {
        if (!self.open) return false;
        if (self.dragging) |which| {
            const l = self.layout();
            switch (which) {
                .edge => self.width = @max(260, self.drag_value - (point.x - self.drag_start)),
                .divider => self.split = std.math.clamp(self.drag_value + (point.y - self.drag_start), 60, @max(60, l.body.height - 80)),
            }
            repaint.* = true;
            return true;
        }
        var hovered: u64 = 0;
        const l = self.layout();
        const in_panel = contains(l.panel, point) or contains(l.edge, point);
        if (self.picking and !in_panel) {
            hovered = self.elementAt(point) orelse 0;
        } else if (in_panel and self.tab == .elements) {
            if (contains(l.tree, point)) {
                if (self.rowAt(l.tree, point)) |row| hovered = self.elements[self.rows[row].node].id;
            } else if (l.crumbs) |crumbs| if (contains(crumbs, point)) {
                if (self.crumbAt(crumbs, point)) |index| hovered = self.elements[index].id;
            };
        }
        if (hovered != self.hovered) {
            self.hovered = hovered;
            repaint.* = true;
        }
        return in_panel or self.picking;
    }

    /// A button went down; true when the inspector took it.
    pub fn pointerDown(self: *Inspector, point: Point, modifiers: z.KeyModifiers, repaint: *bool) bool {
        const taken = self.press(point, modifiers, repaint);
        self.held = taken and !self.swallow;
        return taken;
    }
    fn press(self: *Inspector, point: Point, modifiers: z.KeyModifiers, repaint: *bool) bool {
        if (!self.open) return false;
        const l = self.layout();
        if (self.picking and !contains(l.panel, point)) {
            if (self.elementAt(point)) |id| {
                self.choose(id);
                self.reveal = true;
            }
            self.picking = false;
            self.hovered = 0;
            self.swallow = true;
            self.focused = true;
            repaint.* = true;
            return true;
        }
        if (contains(l.edge, point)) {
            self.dragging = .edge;
            self.drag_start = point.x;
            self.drag_value = l.panel.width;
            self.focused = true;
            return true;
        }
        if (!contains(l.panel, point)) {
            if (self.focused) repaint.* = true;
            self.focused = false;
            return false;
        }
        self.focused = true;
        repaint.* = true;
        if (contains(l.pick, point)) {
            self.picking = !self.picking;
            self.hovered = 0;
            self.tab = .elements;
            return true;
        }
        // The buttons at the right end go over tabs that overflow a narrow
        // panel.
        if (contains(l.close, point)) {
            self.toggle();
            return true;
        }
        if (l.badge) |rect| if (contains(rect, point)) {
            self.tab = .issues;
            return true;
        };
        if (contains(l.rtl, point)) {
            const rtl = if (self.direction_override) |value| value == .rtl else false;
            self.direction_override = if (rtl) .ltr else .rtl;
            return true;
        }
        for (l.tabs, 0..) |rect, i| if (contains(rect, point) and point.x < l.rtl.x) {
            self.tab = @fromBackingInt(@intCast(i));
            return true;
        };
        if (self.tab != .elements) return true;
        if (l.find) |find| if (contains(find.bar, point)) {
            if (contains(find.close, point)) self.endFind() else if (contains(find.previous, point)) self.findNext(true) else if (contains(find.next, point)) self.findNext(false);
            return true;
        };
        if (contains(l.divider, point)) {
            self.dragging = .divider;
            self.drag_start = point.y;
            self.drag_value = l.tree.height + (if (l.crumbs != null) crumbs_height else 0);
            return true;
        }
        if (contains(l.tree, point)) {
            const row = self.rowAt(l.tree, point) orelse return true;
            const entry = self.rows[row];
            const element = &self.elements[entry.node];
            const arrow_x = l.tree.x + @as(f32, @floatFromInt(element.depth)) * indent + 4;
            if (!entry.close and element.kids and point.x >= arrow_x and point.x < arrow_x + 14) {
                // Alt opens or closes everything inside.
                self.setOpen(entry.node, !self.isOpen(element), modifiers.alt);
                return true;
            }
            self.choose(element.id);
            return true;
        }
        if (l.crumbs) |crumbs| if (contains(crumbs, point)) {
            if (self.crumbAt(crumbs, point)) |index| {
                self.choose(self.elements[index].id);
                self.reveal = true;
                self.scrollToSelected();
            }
            return true;
        };
        for (l.side_tabs, 0..) |rect, i| if (contains(rect, point)) {
            self.side = @fromBackingInt(@intCast(i));
            self.side_scroll = 0;
            return true;
        };
        return true;
    }

    /// A button came up; true when the inspector took it.
    pub fn pointerUp(self: *Inspector, point: Point) bool {
        if (self.swallow) {
            self.swallow = false;
            return true;
        }
        _ = point;
        self.dragging = null;
        // A release over the panel of a press that began in the content is
        // the content's.
        defer self.held = false;
        return self.held;
    }

    /// The wheel turned over the panel; true when it scrolled a part.
    pub fn wheel(self: *Inspector, point: Point, delta: Point) bool {
        if (!self.open) return false;
        const l = self.layout();
        if (!contains(l.panel, point)) return false;
        const amount = -delta.y;
        switch (self.tab) {
            .elements => if (contains(l.tree, point)) {
                self.tree_scroll += amount;
            } else if (contains(l.side, point)) {
                self.side_scroll += amount;
            },
            .issues => self.issues_scroll += amount,
            .performance => {},
        }
        self.clampScroll();
        return true;
    }

    /// The pointer's shape over the panel, or null away from it.
    pub fn cursorAt(self: *const Inspector, point: Point) ?Cursor {
        if (!self.open) return null;
        if (self.dragging) |which| return if (which == .edge) .resize_ew else .resize_ns;
        const l = self.layout();
        if (contains(l.edge, point)) return .resize_ew;
        if (self.picking and !contains(l.panel, point)) return .crosshair;
        if (!contains(l.panel, point)) return null;
        if (self.tab == .elements and contains(l.divider, point)) return .resize_ns;
        if (self.tab == .elements) if (l.find) |find| if (contains(find.field, point)) return .text;
        return .default;
    }

    fn rowAt(self: *const Inspector, tree: Rect, point: Point) ?usize {
        const offset = point.y - tree.y - 2 + self.tree_scroll;
        if (offset < 0) return null;
        const row: usize = @intFromFloat(offset / row_height);
        return if (row < self.row_count) row else null;
    }
    /// The path to the element chosen, root first, into `out`.
    fn path(self: *const Inspector, out: []usize) []usize {
        var index = self.indexOf(self.selected) orelse return out[0..0];
        var count: usize = 0;
        while (count < out.len) {
            out[count] = index;
            count += 1;
            if (self.elements[index].parent < 0) break;
            index = @intCast(self.elements[index].parent);
        }
        std.mem.reverse(usize, out[0..count]);
        return out[0..count];
    }
    fn crumbRects(self: *const Inspector, crumbs: Rect, indices: []const usize, out: []Rect) void {
        var total: f32 = 4;
        var names: [32]u8 = undefined;
        for (indices, 0..) |index, i| {
            const w = self.textWidth(tagName(self.elements[index].kind, &names), small_font) + 12;
            out[i] = .{ .x = total, .y = crumbs.y + 3, .width = w, .height = crumbs.height - 6 };
            total += w + 1;
        }
        // The end of the path stays in view, at the right when it overflows.
        const shift = if (total > crumbs.width) crumbs.width - total else 0;
        for (out[0..indices.len]) |*rect| rect.x += crumbs.x + shift;
    }
    fn crumbAt(self: *const Inspector, crumbs: Rect, point: Point) ?usize {
        var buffer: [view.max_depth + 4]usize = undefined;
        const indices = self.path(&buffer);
        var rects: [view.max_depth + 4]Rect = undefined;
        self.crumbRects(crumbs, indices, &rects);
        for (indices, rects[0..indices.len]) |index, rect| if (contains(rect, point)) return index;
        return null;
    }

    // Painting.

    /// Paint the highlight over the content, then the panel at the right.
    pub fn paint(self: *Inspector, target: anytype) !void {
        if (!self.open) return;
        self.clampScroll();
        try self.paintHighlight(target);
        const l = self.layout();
        const p = self.palette;
        try target.pushClip(l.panel);
        defer target.popClip() catch {};
        target.roundedRect(l.panel, 0, ui.Color.rgb(p.bg));
        target.roundedRect(.{ .x = l.panel.x, .y = l.panel.y, .width = 1, .height = l.panel.height }, 0, ui.Color.rgb(p.border));
        try self.paintToolbar(target, l);
        switch (self.tab) {
            .elements => {
                if (l.find) |find| self.paintFind(target, find);
                try self.paintTree(target, l);
                if (l.crumbs) |crumbs| try self.paintCrumbs(target, crumbs);
                try self.paintSide(target, l);
            },
            .performance => try self.paintPerformance(target, l.body),
            .issues => try self.paintIssues(target, l.body),
        }
    }

    fn label(self: *const Inspector, target: anytype, x: f32, y: f32, height: f32, value: []const u8, rgb: u32, font: Font) f32 {
        const size = self.measurer.textSize(value, font);
        target.labelFont(.{ .x = x, .y = y + (height - size.height) / 2, .width = size.width + 1, .height = size.height }, value, rgb, font);
        return x + size.width;
    }

    fn paintToolbar(self: *Inspector, target: anytype, l: Layout) !void {
        const p = self.palette;
        target.roundedRect(l.toolbar, 0, ui.Color.rgb(p.toolbar));
        target.roundedRect(.{ .x = l.toolbar.x, .y = l.toolbar.y + l.toolbar.height - 1, .width = l.toolbar.width, .height = 1 }, 0, ui.Color.rgb(p.border));
        // The picker: an arrow over a box, in the accent while picking.
        const pick_color = if (self.picking) p.accent else p.muted;
        if (self.picking) target.roundedRect(l.pick, 4, ui.Color.rgb(p.hover));
        const box = inset(l.pick, 7, 5, 7, 5);
        target.strokeRect(box, 2, 1.5, ui.Color.rgb(pick_color));
        target.roundedRect(.{ .x = box.x + box.width - 4, .y = box.y + box.height - 4, .width = 6, .height = 6 }, 1, ui.Color.rgb(pick_color));
        target.roundedRect(.{ .x = l.pick.x + l.pick.width + 4, .y = l.toolbar.y + 7, .width = 1, .height = 16 }, 0, ui.Color.rgb(p.border));
        var label_buffer: [24]u8 = undefined;
        const labels = [_][]const u8{ "Elements", "Performance", self.issuesLabel(&label_buffer) };
        {
            // Tabs that overflow a narrow panel go under the buttons at the
            // right end.
            try target.pushClip(.{ .x = l.toolbar.x, .y = l.toolbar.y, .width = @max(0, l.rtl.x - l.toolbar.x), .height = l.toolbar.height });
            defer target.popClip() catch {};
            for (labels, l.tabs, 0..) |text, rect, i| self.paintTab(target, rect, text, @backingInt(self.tab) == i);
        }
        const rtl = if (self.direction_override) |value| value == .rtl else false;
        self.paintTab(target, l.rtl, "RTL", rtl);
        if (l.badge) |rect| {
            // A warning sign and the count of issues.
            target.roundedRect(.{ .x = rect.x + 6, .y = rect.y + 6, .width = 10, .height = 10 }, 2, ui.Color.rgb(p.warn));
            var count: [8]u8 = undefined;
            _ = self.label(target, rect.x + 19, rect.y, rect.height, std.fmt.bufPrint(&count, "{d}", .{self.issue_count}) catch "", p.muted, small_font);
        }
        // The close button: a cross.
        const c = l.close;
        _ = self.label(target, c.x + 8, c.y, c.height, "\u{2715}", p.muted, ui_font);
    }
    fn paintFind(self: *const Inspector, target: anytype, find: Find) void {
        const p = self.palette;
        target.roundedRect(find.bar, 0, ui.Color.rgb(p.toolbar));
        target.roundedRect(.{ .x = find.bar.x, .y = find.bar.y + find.bar.height - 1, .width = find.bar.width, .height = 1 }, 0, ui.Color.rgb(p.border));
        target.roundedRect(find.field, 3, ui.Color.rgb(p.bg));
        target.strokeRect(find.field, 3, 1, ui.Color.rgb(if (self.focused) p.accent else p.border));
        const q = self.findQuery();
        const end = if (q.len > 0) self.label(target, find.field.x + 6, find.field.y, find.field.height, q, p.text, ui_font) else blk: {
            _ = self.label(target, find.field.x + 6, find.field.y, find.field.height, "Find by tag, text, name or key", p.muted, ui_font);
            break :blk find.field.x + 6;
        };
        if (self.focused) target.roundedRect(.{ .x = end + 1, .y = find.field.y + 4, .width = 1, .height = find.field.height - 8 }, 0, ui.Color.rgb(p.text));
        var count: [32]u8 = undefined;
        const status = if (q.len == 0) "" else if (self.match_count == 0) "No matches" else std.fmt.bufPrint(&count, "{d} of {d}", .{ self.match + 1, self.match_count }) catch "";
        _ = self.label(target, find.field.x + find.field.width + 8, find.bar.y, find.bar.height, status, p.muted, small_font);
        for ([_]Rect{ find.previous, find.next, find.close }, [_][]const u8{ "\u{2191}", "\u{2193}", "\u{2715}" }) |rect, glyph| {
            _ = self.label(target, rect.x + 6, rect.y, rect.height, glyph, p.muted, ui_font);
        }
    }
    fn paintTab(self: *const Inspector, target: anytype, rect: Rect, text: []const u8, selected: bool) void {
        const p = self.palette;
        if (selected) target.roundedRect(.{ .x = rect.x, .y = rect.y + rect.height - 2, .width = rect.width, .height = 2 }, 0, ui.Color.rgb(p.accent));
        _ = self.label(target, rect.x + 10, rect.y, rect.height, text, if (selected) p.text else p.muted, ui_font);
    }

    fn paintTree(self: *Inspector, target: anytype, l: Layout) !void {
        const p = self.palette;
        const tree = l.tree;
        try target.pushClip(tree);
        defer target.popClip() catch {};
        const first: usize = @intFromFloat(@max(0, self.tree_scroll - 2) / row_height);
        var row = first;
        while (row < self.row_count) : (row += 1) {
            const y = tree.y + 2 + @as(f32, @floatFromInt(row)) * row_height - self.tree_scroll;
            if (y > tree.y + tree.height) break;
            const entry = self.rows[row];
            const element = &self.elements[entry.node];
            const rect: Rect = .{ .x = tree.x, .y = y, .width = tree.width, .height = row_height };
            if (!entry.close and element.id == self.selected) {
                target.roundedRect(rect, 0, ui.Color.rgb(if (self.focused) p.selected else p.unfocused));
            } else if (element.id == self.hovered) target.roundedRect(rect, 0, ui.Color.rgb(p.hover));
            var x = tree.x + @as(f32, @floatFromInt(element.depth)) * indent + 4;
            if (!entry.close and element.kids) {
                _ = self.label(target, x, y, row_height, if (self.isOpen(element)) "\u{25be}" else "\u{25b8}", p.muted, small_font);
            }
            x += 14;
            try self.paintMarkup(target, x, y, tree.x + tree.width - 6, entry, element);
        }
    }
    /// The markup of a row: `<Tag key="…" name="…">text</Tag>`.
    fn paintMarkup(self: *const Inspector, target: anytype, start: f32, y: f32, limit: f32, entry: Row, element: *const Element) !void {
        const p = self.palette;
        var names: [32]u8 = undefined;
        const tag = tagName(element.kind, &names);
        var parts: [12]struct { text: []const u8, rgb: u32 } = undefined;
        var count: usize = 0;
        var scratch: [192]u8 = undefined;
        var used: usize = 0;
        const Add = struct {
            fn add(list: *@TypeOf(parts), n: *usize, text: []const u8, rgb: u32) void {
                if (n.* == list.len) return;
                list[n.*] = .{ .text = text, .rgb = rgb };
                n.* += 1;
            }
            fn print(buffer: []u8, at: *usize, comptime format: []const u8, args: anytype) []const u8 {
                const out = std.fmt.bufPrint(buffer[at.*..], format, args) catch return "";
                at.* += out.len;
                return out;
            }
        };
        if (entry.close) {
            Add.add(&parts, &count, Add.print(&scratch, &used, "</{s}>", .{tag}), p.tag);
        } else {
            Add.add(&parts, &count, Add.print(&scratch, &used, "<{s}", .{tag}), p.tag);
            if (element.key) |value| {
                Add.add(&parts, &count, " key", p.attr);
                Add.add(&parts, &count, "=", p.tag);
                Add.add(&parts, &count, Add.print(&scratch, &used, "\"{d}\"", .{value}), p.value);
            }
            if (element.name.len > 0 and !std.mem.eql(u8, element.name, element.text)) {
                Add.add(&parts, &count, " name", p.attr);
                Add.add(&parts, &count, "=", p.tag);
                Add.add(&parts, &count, Add.print(&scratch, &used, "\"{s}\"", .{clip(element.name, 40)}), p.value);
            }
            if (element.kids and self.isOpen(element)) {
                Add.add(&parts, &count, ">", p.tag);
            } else if (element.kids) {
                Add.add(&parts, &count, ">", p.tag);
                Add.add(&parts, &count, "\u{2026}", p.muted);
                Add.add(&parts, &count, Add.print(&scratch, &used, "</{s}>", .{tag}), p.tag);
            } else if (element.text.len > 0) {
                Add.add(&parts, &count, ">", p.tag);
                Add.add(&parts, &count, clip(element.text, 80), p.text);
                Add.add(&parts, &count, Add.print(&scratch, &used, "</{s}>", .{tag}), p.tag);
            } else Add.add(&parts, &count, Add.print(&scratch, &used, "></{s}>", .{tag}), p.tag);
        }
        var x = start;
        for (parts[0..count]) |part| {
            if (x >= limit) break;
            x = self.label(target, x, y, row_height, part.text, part.rgb, mono_font);
        }
    }

    fn paintCrumbs(self: *Inspector, target: anytype, crumbs: Rect) !void {
        const p = self.palette;
        target.roundedRect(crumbs, 0, ui.Color.rgb(p.toolbar));
        target.roundedRect(.{ .x = crumbs.x, .y = crumbs.y, .width = crumbs.width, .height = 1 }, 0, ui.Color.rgb(p.border));
        var buffer: [view.max_depth + 4]usize = undefined;
        const indices = self.path(&buffer);
        var rects: [view.max_depth + 4]Rect = undefined;
        self.crumbRects(crumbs, indices, &rects);
        try target.pushClip(crumbs);
        defer target.popClip() catch {};
        var names: [32]u8 = undefined;
        for (indices, rects[0..indices.len], 0..) |index, rect, i| {
            const element = &self.elements[index];
            if (i + 1 == indices.len) target.roundedRect(rect, 3, ui.Color.rgb(p.selected)) else if (element.id == self.hovered) target.roundedRect(rect, 3, ui.Color.rgb(p.hover));
            _ = self.label(target, rect.x + 6, rect.y, rect.height, tagName(element.kind, &names), p.tag, small_font);
        }
    }

    fn paintSide(self: *Inspector, target: anytype, l: Layout) !void {
        const p = self.palette;
        const bar: Rect = .{ .x = l.body.x, .y = l.side_tabs[0].y, .width = l.body.width, .height = tab_height };
        target.roundedRect(bar, 0, ui.Color.rgb(p.toolbar));
        target.roundedRect(.{ .x = bar.x, .y = bar.y, .width = bar.width, .height = 1 }, 0, ui.Color.rgb(p.border));
        target.roundedRect(.{ .x = bar.x, .y = bar.y + bar.height - 1, .width = bar.width, .height = 1 }, 0, ui.Color.rgb(p.border));
        for ([_][]const u8{ "Styles", "Computed", "Properties" }, l.side_tabs, 0..) |text, rect, i| self.paintTab(target, rect, text, @backingInt(self.side) == i);
        const side = l.side;
        try target.pushClip(side);
        defer target.popClip() catch {};
        const index = self.indexOf(self.selected) orelse {
            _ = self.label(target, side.x + 12, side.y + 8, 20, "Choose an element in the tree, or pick one in the window.", p.muted, ui_font);
            self.side_content = 0;
            return;
        };
        var details: Details = .{};
        details.describe(self, index);
        var y = side.y - self.side_scroll;
        switch (self.side) {
            .styles => {
                const line = 18;
                var selector: [64]u8 = undefined;
                _ = self.label(target, side.x + 10, y + 6, line, details.selector(self, index, &selector), p.text, mono_font);
                // Where the application built it: the file's name and the
                // line, the whole path in the properties.
                const at = baseName(self.source());
                if (at.len > 0) {
                    const width = self.textWidth(at, small_font);
                    const x = side.x + side.width - 10 - width;
                    _ = self.label(target, x, y + 6, line, at, p.muted, small_font);
                    target.roundedRect(.{ .x = x, .y = y + 6 + line - 3, .width = width, .height = 1 }, 0, ui.Color.rgb(p.muted));
                }
                y += 6 + line;
                for (details.styles[0..details.style_count]) |decl| {
                    self.paintDecl(target, side.x + 26, y, line, decl);
                    y += line;
                }
                _ = self.label(target, side.x + 10, y, line, "}", p.text, mono_font);
                y += line + 8;
            },
            .computed => {
                y = try self.paintBoxModel(target, side, y + 12, &self.elements[index]);
                const line = 18;
                for (details.computed[0..details.computed_count]) |decl| {
                    self.paintDecl(target, side.x + 10, y, line, decl);
                    y += line;
                }
                y += 10;
            },
            .properties => {
                const line = 18;
                for (details.sections[0..details.section_count]) |section| {
                    _ = self.label(target, side.x + 10, y + 6, line, section.title, p.text, .{ .size = 11, .weight = .bold });
                    y += 6 + line;
                    for (details.properties[section.start..section.end]) |decl| {
                        self.paintDecl(target, side.x + 18, y, line, decl);
                        y += line;
                    }
                    y += 6;
                    target.roundedRect(.{ .x = side.x, .y = y, .width = side.width, .height = 1 }, 0, ui.Color.rgb(p.border));
                }
            },
        }
        self.side_content = y + self.side_scroll - side.y;
    }
    fn paintDecl(self: *const Inspector, target: anytype, x: f32, y: f32, line: f32, decl: Decl) void {
        const p = self.palette;
        var next = self.label(target, x, y, line, decl.name, if (self.side == .properties) p.tag else p.prop, mono_font);
        next = self.label(target, next, y, line, ": ", p.text, mono_font);
        if (decl.swatch) |rgb| {
            const box: Rect = .{ .x = next + 2, .y = y + (line - 10) / 2, .width = 10, .height = 10 };
            target.roundedRect(box, 0, ui.Color.rgb(rgb));
            target.strokeRect(box, 0, 1, ui.Color.rgb(p.border));
            next += 16;
        }
        const value_color = if (self.side != .properties) p.text else if (decl.value.len > 0 and decl.value[0] == '"') p.str else if (std.mem.eql(u8, decl.value, "true") or std.mem.eql(u8, decl.value, "false")) p.lit else p.text;
        next = self.label(target, next, y, line, decl.value, value_color, mono_font);
        if (self.side != .properties) _ = self.label(target, next, y, line, ";", p.text, mono_font);
    }
    /// The box model of the Computed tab: border, padding and content, with
    /// their sizes. Returns where the values below it start.
    fn paintBoxModel(self: *const Inspector, target: anytype, side: Rect, top: f32, element: *const Element) !f32 {
        const ink: u32 = 0x202124;
        const border = if (element.border != null) element.border_width else 0;
        const pad = element.padding;
        const outer: Rect = .{ .x = side.x + 12, .y = top, .width = @max(0, side.width - 24), .height = 150 };
        const Layer = struct {
            fn length(value: f32, buffer: []u8) []const u8 {
                if (value == 0) return "-";
                return number(value, buffer);
            }
        };
        var buffer: [24]u8 = undefined;
        const layers = [_]struct { name: []const u8, fill: u32, line: u32, sides: [4]f32 }{
            .{ .name = "margin", .fill = 0xf9cc9d, .line = 0x333333, .sides = .{ 0, 0, 0, 0 } },
            .{ .name = "border", .fill = 0xfddd9b, .line = 0x000000, .sides = .{ border, border, border, border } },
            .{ .name = "padding", .fill = 0xc3d08b, .line = 0x808080, .sides = .{ pad.top, pad.right, pad.bottom, pad.left } },
        };
        var rect = outer;
        for (layers) |layer| {
            target.roundedRect(rect, 0, ui.Color.rgb(layer.fill));
            target.strokeRect(rect, 0, 1, ui.Color.rgb(layer.line));
            _ = self.label(target, rect.x + 4, rect.y + 1, 14, layer.name, ink, .{ .size = 10 });
            const values = [_][]const u8{ Layer.length(layer.sides[0], &buffer), "", "", "" };
            const t = values[0];
            _ = self.label(target, rect.x + (rect.width - self.textWidth(t, small_font)) / 2, rect.y + 1, 14, t, ink, small_font);
            var b2: [24]u8 = undefined;
            const b = Layer.length(layer.sides[2], &b2);
            _ = self.label(target, rect.x + (rect.width - self.textWidth(b, small_font)) / 2, rect.y + rect.height - 15, 14, b, ink, small_font);
            var l2: [24]u8 = undefined;
            const left = Layer.length(layer.sides[3], &l2);
            _ = self.label(target, rect.x + 4, rect.y + (rect.height - 14) / 2, 14, left, ink, small_font);
            var r2: [24]u8 = undefined;
            const right = Layer.length(layer.sides[1], &r2);
            _ = self.label(target, rect.x + rect.width - 4 - self.textWidth(right, small_font), rect.y + (rect.height - 14) / 2, 14, right, ink, small_font);
            rect = inset(rect, 30, 16, 30, 16);
        }
        target.roundedRect(rect, 0, ui.Color.rgb(0x8cb6c0));
        target.strokeRect(rect, 0, 1, ui.Color.rgb(0x808080));
        const content_w = @max(0, element.bounds.width - 2 * border - pad.left - pad.right);
        const content_h = @max(0, element.bounds.height - 2 * border - pad.top - pad.bottom);
        var w_buffer: [24]u8 = undefined;
        var h_buffer: [24]u8 = undefined;
        var dims: [64]u8 = undefined;
        const size = std.fmt.bufPrint(&dims, "{s} \u{00d7} {s}", .{ number(content_w, &w_buffer), number(content_h, &h_buffer) }) catch "";
        _ = self.label(target, rect.x + (rect.width - self.textWidth(size, small_font)) / 2, rect.y, rect.height, size, ink, small_font);
        return outer.y + outer.height + 12;
    }

    fn paintPerformance(self: *const Inspector, target: anytype, body: Rect) !void {
        const p = self.palette;
        const count = @min(self.frames, history_len);
        var total: u64 = 0;
        var slowest: u64 = 0;
        for (self.history[0..count]) |f| {
            const d = f[0] + f[1] + f[2];
            total += d;
            slowest = @max(slowest, d);
        }
        const last = self.times[0] + self.times[1] + self.times[2];
        const average = if (count > 0) total / count else 0;
        var x = body.x + 12;
        const y = body.y + 12;
        const stats = [_]struct { name: []const u8, value: u64, unit: enum { ms, hz, count } }{
            .{ .name = "Last frame", .value = last, .unit = .ms },
            .{ .name = "Average", .value = average, .unit = .ms },
            .{ .name = "Slowest", .value = slowest, .unit = .ms },
            .{ .name = "Display", .value = @intFromFloat(self.refresh_hz), .unit = .hz },
            .{ .name = "Elements", .value = self.total, .unit = .count },
        };
        for (stats) |stat| {
            var buffer: [32]u8 = undefined;
            const value = switch (stat.unit) {
                .ms => std.fmt.bufPrint(&buffer, "{d:.1} ms", .{@as(f64, @floatFromInt(stat.value)) / 1e6}) catch "",
                .hz => std.fmt.bufPrint(&buffer, "{d} Hz", .{stat.value}) catch "",
                .count => std.fmt.bufPrint(&buffer, "{d}", .{stat.value}) catch "",
            };
            _ = self.label(target, x, y, 14, stat.name, p.muted, small_font);
            const end = self.label(target, x, y + 16, 24, value, p.text, big_font);
            x = @max(x + self.textWidth(stat.name, small_font), end) + 16;
        }
        const chart: Rect = .{ .x = body.x + 12, .y = y + 52, .width = @max(0, body.width - 24), .height = 150 };
        target.strokeRect(chart, 4, 1, ui.Color.rgb(p.border));
        self.paintFrames(target, chart);
        var lx = chart.x;
        const ly = chart.y + chart.height + 10;
        const parts = [_]struct { name: []const u8, rgb: u32, value: u64 }{
            .{ .name = "Build", .rgb = build_color, .value = self.times[0] },
            .{ .name = "Layout", .rgb = layout_color, .value = self.times[1] },
            .{ .name = "Paint", .rgb = paint_color, .value = self.times[2] },
        };
        for (parts) |part| {
            target.roundedRect(.{ .x = lx, .y = ly + 4, .width = 10, .height = 10 }, 2, ui.Color.rgb(part.rgb));
            var buffer: [48]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "{s} {d:.1} ms", .{ part.name, @as(f64, @floatFromInt(part.value)) / 1e6 }) catch "";
            lx = self.label(target, lx + 16, ly, 18, text, p.text, small_font) + 14;
        }
        var budget: [64]u8 = undefined;
        _ = self.label(target, lx, ly, 18, std.fmt.bufPrint(&budget, "\u{2014} {d:.1} ms, a frame at {d} Hz", .{ 1000.0 / self.refresh_hz, @as(u32, @intFromFloat(self.refresh_hz)) }) catch "", p.muted, small_font);
        _ = self.label(target, chart.x, ly + 26, 18, "Frames happen only when something changes: input, an update, or motion.", p.muted, small_font);
    }
    /// The last frames as bars, the latest at the right, stacked by what
    /// they spent their time on, under a line at the frame budget.
    fn paintFrames(self: *const Inspector, target: anytype, chart: Rect) void {
        const p = self.palette;
        const count = @min(self.frames, history_len);
        const budget = 1e9 / @as(f64, self.refresh_hz);
        var scale = 2 * budget;
        for (self.history[0..count]) |f| scale = @max(scale, @as(f64, @floatFromInt(f[0] + f[1] + f[2])) * 1.1);
        const r = inset(chart, 4, 6, 4, 4);
        const line_y = r.y + r.height - @as(f32, @floatCast(budget / scale)) * r.height;
        target.roundedRect(.{ .x = r.x, .y = line_y, .width = r.width, .height = 1 }, 0, color(p.muted, 150));
        const bar = r.width / history_len;
        for (0..count) |k| {
            const f = self.history[(self.frames - count + k) % history_len];
            const x = r.x + r.width - @as(f32, @floatFromInt(count - k)) * bar;
            var bottom = r.y + r.height;
            for (f, [_]u32{ build_color, layout_color, paint_color }) |value, rgb| {
                const h = @as(f32, @floatCast(@as(f64, @floatFromInt(value)) / scale)) * r.height;
                if (h <= 0) continue;
                target.roundedRect(.{ .x = x + bar * 0.15, .y = bottom - h, .width = bar * 0.7, .height = h }, 0, ui.Color.rgb(rgb));
                bottom -= h;
            }
        }
    }

    fn paintIssues(self: *const Inspector, target: anytype, body: Rect) !void {
        const p = self.palette;
        try target.pushClip(body);
        defer target.popClip() catch {};
        if (self.issue_count == 0) {
            _ = self.label(target, body.x + 12, body.y + 8, 20, "No issues so far.", p.muted, ui_font);
            return;
        }
        var y = body.y - self.issues_scroll;
        var index = self.issue_count;
        while (index > 0) {
            index -= 1;
            target.roundedRect(.{ .x = body.x + 10, .y = y + 12, .width = 10, .height = 10 }, 2, ui.Color.rgb(p.warn));
            _ = self.label(target, body.x + 28, y, 34, self.issue(index), p.text, small_font);
            y += 34;
            target.roundedRect(.{ .x = body.x, .y = y - 1, .width = body.width, .height = 1 }, 0, ui.Color.rgb(p.border));
        }
    }

    /// The element under the pointer in the tree or picking, else the one
    /// chosen while the panel has the keyboard: its border, padding and
    /// content over the content, with a tooltip.
    fn paintHighlight(self: *const Inspector, target: anytype) !void {
        const id = if (self.hovered != 0) self.hovered else if (self.focused) self.selected else 0;
        if (id == 0) return;
        const index = self.indexOf(id) orelse return;
        const e = &self.elements[index];
        if (e.visible == null) return;
        const area: Rect = .{ .x = self.window.x, .y = self.window.y, .width = self.app_width, .height = self.window.height };
        try target.pushClip(area);
        defer target.popClip() catch {};
        const b = if (e.border != null) e.border_width else 0;
        const border = e.bounds;
        const padding = inset(border, b, b, b, b);
        const content = inset(padding, e.padding.left, e.padding.top, e.padding.right, e.padding.bottom);
        ring(target, border, padding, highlight_border);
        ring(target, padding, content, highlight_padding);
        target.roundedRect(content, 0, highlight_content);
        self.paintTooltip(target, e, border, area);
    }
    fn paintTooltip(self: *const Inspector, target: anytype, e: *const Element, box: Rect, area: Rect) void {
        const ink: u32 = 0x202124;
        const muted: u32 = 0x5f6368;
        const pad: f32 = 8;
        const line: f32 = 16;
        var rows: [8]Decl = undefined;
        var count: usize = 0;
        var scratch: [256]u8 = undefined;
        var used: usize = 0;
        const text_like = e.kind == .text or e.kind == .note or e.kind == .icon;
        if (text_like) {
            const ink_color = e.color orelse 0x182430;
            rows[count] = .{ .name = "Color", .value = hex(ink_color, scratch[used..]), .swatch = ink_color };
            used += 7;
            count += 1;
            const font = e.font orelse Font{};
            rows[count] = .{ .name = "Font", .value = std.fmt.bufPrint(scratch[used..], "{s}px {s}", .{ number(font.size, scratch[used + 64 ..]), if (font.monospace) "monospace" else "system-ui" }) catch "" };
            used += rows[count].value.len;
            count += 1;
        }
        if (e.background) |rgb| {
            rows[count] = .{ .name = "Background", .value = hex(rgb, scratch[used..]), .swatch = rgb };
            used += 7;
            count += 1;
        }
        if (edges(e.padding, scratch[used..])) |value| {
            rows[count] = .{ .name = "Padding", .value = value };
            used += value.len;
            count += 1;
        }
        var acc: [3]Decl = .{
            .{ .name = "Name", .value = accessibleName(e) },
            .{ .name = "Role", .value = roleName(e.kind, e.name.len > 0) },
            .{ .name = "Keyboard-focusable", .value = if (focusable(e)) "\u{2713}" else "\u{2298}" },
        };
        var names: [32]u8 = undefined;
        const title = tagName(e.kind, &names);
        var key_buffer: [32]u8 = undefined;
        const key_text = if (e.key) |value| std.fmt.bufPrint(&key_buffer, "#{d}", .{value}) catch "" else "";
        var w_buffer: [24]u8 = undefined;
        var h_buffer: [24]u8 = undefined;
        var dims_buffer: [64]u8 = undefined;
        const dims = std.fmt.bufPrint(&dims_buffer, "{s} \u{00d7} {s}", .{ number(e.bounds.width, &w_buffer), number(e.bounds.height, &h_buffer) }) catch "";
        var label_w: f32 = 0;
        var value_w: f32 = 0;
        for (rows[0..count]) |row| {
            label_w = @max(label_w, self.textWidth(row.name, small_font));
            value_w = @max(value_w, self.textWidth(row.value, small_font) + (if (row.swatch != null) @as(f32, 14) else 0));
        }
        for (acc) |row| {
            label_w = @max(label_w, self.textWidth(row.name, small_font));
            value_w = @max(value_w, self.textWidth(row.value, small_font));
        }
        const title_w = self.textWidth(title, .{ .size = 11, .weight = .semibold }) + self.textWidth(key_text, small_font);
        var width = @max(@max(title_w + 16 + self.textWidth(dims, small_font), label_w + 16 + value_w), 160) + 2 * pad;
        width = @min(width, @max(area.width - 8, 100));
        const height = pad + line + @as(f32, @floatFromInt(count)) * line + 9 + line + 3 * line + pad;
        // Above the element, else below it, else inside its top.
        const arrow: f32 = 7;
        const x = @max(area.x + 4, @min(box.x, area.x + area.width - width - 4));
        var y = box.y - height - arrow;
        if (y < area.y + 4) {
            y = box.y + box.height + arrow;
            if (y + height > area.y + area.height - 4) y = @max(area.y + 4, box.y + 4);
        }
        const r: Rect = .{ .x = x, .y = y, .width = width, .height = height };
        target.roundedRect(.{ .x = r.x, .y = r.y + 2, .width = r.width, .height = r.height }, 4, color(0x000000, 50));
        target.roundedRect(r, 4, ui.Color.rgb(0xffffff));
        target.strokeRect(r, 4, 1, ui.Color.rgb(0xd0d0d0));
        var cy = y + pad;
        const after = self.label(target, x + pad, cy, line, title, 0x881280, .{ .size = 11, .weight = .semibold });
        if (key_text.len > 0) _ = self.label(target, after, cy, line, key_text, 0x1a1aa6, small_font);
        _ = self.label(target, x + width - pad - self.textWidth(dims, small_font), cy, line, dims, muted, small_font);
        cy += line;
        const value_x = x + width - pad - value_w;
        for (rows[0..count]) |row| {
            _ = self.label(target, x + pad, cy, line, row.name, muted, small_font);
            var vx = value_x;
            if (row.swatch) |rgb| {
                const swatch: Rect = .{ .x = vx, .y = cy + 3, .width = 10, .height = 10 };
                target.roundedRect(swatch, 0, ui.Color.rgb(rgb));
                target.strokeRect(swatch, 0, 1, ui.Color.rgb(0xc0c0c0));
                vx += 14;
            }
            _ = self.label(target, vx, cy, line, row.value, ink, small_font);
            cy += line;
        }
        target.roundedRect(.{ .x = x + pad, .y = cy + 3, .width = width - 2 * pad, .height = 1 }, 0, ui.Color.rgb(0xe0e0e0));
        cy += 9;
        _ = self.label(target, x + pad, cy, line, "ACCESSIBILITY", muted, .{ .size = 11, .weight = .semibold });
        cy += line;
        for (&acc, 0..) |*row, i| {
            _ = self.label(target, x + pad, cy, line, row.name, muted, small_font);
            const value_color: u32 = if (i == 2) (if (focusable(e)) 0x188038 else muted) else ink;
            _ = self.label(target, value_x, cy, line, row.value, value_color, small_font);
            cy += line;
        }
    }
};

/// Fill the room between `outer` and `inner`, which it holds.
fn ring(target: anytype, outer: Rect, inner: Rect, fill: ui.Color) void {
    if (inner.width <= 0 or inner.height <= 0) {
        target.roundedRect(outer, 0, fill);
        return;
    }
    target.roundedRect(.{ .x = outer.x, .y = outer.y, .width = outer.width, .height = inner.y - outer.y }, 0, fill);
    target.roundedRect(.{ .x = outer.x, .y = inner.y + inner.height, .width = outer.width, .height = outer.y + outer.height - inner.y - inner.height }, 0, fill);
    target.roundedRect(.{ .x = outer.x, .y = inner.y, .width = inner.x - outer.x, .height = inner.height }, 0, fill);
    target.roundedRect(.{ .x = inner.x + inner.width, .y = inner.y, .width = outer.x + outer.width - inner.x - inner.width, .height = inner.height }, 0, fill);
}

fn dark(background: u32) bool {
    const r: f32 = @floatFromInt((background >> 16) & 255);
    const g: f32 = @floatFromInt((background >> 8) & 255);
    const b: f32 = @floatFromInt(background & 255);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b < 128;
}

/// The tag of an element in the tree: its kind, as `Button` or `TreeRow`,
/// `Root` for the root.
pub fn tagName(kind: Kind, buffer: []u8) []const u8 {
    const name = @tagName(kind);
    var n: usize = 0;
    var upper = true;
    for (name) |char| {
        if (n == buffer.len) break;
        if (char == '_') {
            upper = true;
            continue;
        }
        buffer[n] = if (upper) std.ascii.toUpper(char) else char;
        upper = false;
        n += 1;
    }
    return buffer[0..n];
}

/// The role assistive technology sees, named as browsers name roles.
pub fn roleName(kind: Kind, named: bool) []const u8 {
    return switch (kind) {
        .button, .nav_button, .disclosure, .combo_toggle => "button",
        .link => "link",
        .checkbox => "checkbox",
        .radio => "radio",
        .radio_group => "radiogroup",
        .toggle_switch => "switch",
        .slider, .rating => "slider",
        .stepper => "spinbutton",
        .progress, .loading => "progressbar",
        .meter => "meter",
        .tab => "tab",
        .tab_list => "tablist",
        .segmented => "radiogroup",
        .segment => "radio",
        .list_box => "listbox",
        .list_item => "option",
        .tree => "tree",
        .tree_item, .tree_row => "treeitem",
        .table => "table",
        .table_row => "row",
        .table_header => "row",
        .column_header => "columnheader",
        .dialog => "dialog",
        .popover => "dialog",
        .popup => "listbox",
        .toolbar => "toolbar",
        .breadcrumbs => "navigation",
        .text, .note, .badge => "text",
        .image, .svg, .icon, .avatar => "image",
        .combo_box, .popup_button, .combo_field => "combobox",
        .embed, .editable_text => "textbox",
        .token, .token_field => "group",
        .scroll => "scroll area",
        .search => "search",
        .toast, .toasts => "status",
        .fieldset, .field, .accordion => "group",
        .spacer => "none",
        else => if (named) "group" else "none",
    };
}

/// True for an element the keyboard can focus.
fn focusable(e: *const Element) bool {
    if (!e.enabled) return false;
    return switch (e.kind) {
        .button, .link, .nav_button, .combo_box, .popup_button, .checkbox, .radio, .segment, .tab, .list_item, .disclosure, .toggle_switch, .slider, .stepper, .rating, .tree_row, .column_header, .token, .combo_toggle, .editable_text, .embed => true,
        else => false,
    };
}
fn accessibleName(e: *const Element) []const u8 {
    if (e.name.len > 0) return e.name;
    return clip(e.text, 40);
}

/// `value` cut to `n` bytes on one line, at a character boundary.
fn clip(value: []const u8, n: usize) []const u8 {
    var end = std.mem.indexOfScalar(u8, value, '\n') orelse value.len;
    if (end > n) end = n;
    while (end > 0 and end < value.len and value[end] & 0xc0 == 0x80) end -= 1;
    return value[0..end];
}
/// A size, whole or with one decimal.
fn number(value: f32, buffer: []u8) []const u8 {
    if (value == @round(value) and @abs(value) < 1e9) return std.fmt.bufPrint(buffer, "{d}", .{@as(i64, @intFromFloat(value))}) catch "";
    return std.fmt.bufPrint(buffer, "{d:.1}", .{value}) catch "";
}
/// A length as CSS writes pixels.
fn px(value: f32, buffer: []u8) []const u8 {
    if (value == 0) return "0";
    var digits: [24]u8 = undefined;
    return std.fmt.bufPrint(buffer, "{s}px", .{number(value, &digits)}) catch "";
}
fn hex(rgb: u32, buffer: []u8) []const u8 {
    return std.fmt.bufPrint(buffer, "#{x:0>6}", .{rgb & 0xffffff}) catch "";
}
/// Four sides as CSS writes them, or null when all are zero.
fn edges(value: view.Insets, buffer: []u8) ?[]const u8 {
    if (value.top == 0 and value.right == 0 and value.bottom == 0 and value.left == 0) return null;
    var a: [24]u8 = undefined;
    var b: [24]u8 = undefined;
    var c: [24]u8 = undefined;
    var d: [24]u8 = undefined;
    if (value.top == value.right and value.top == value.bottom and value.top == value.left) return std.fmt.bufPrint(buffer, "{s}", .{px(value.top, &a)}) catch null;
    if (value.top == value.bottom and value.left == value.right) return std.fmt.bufPrint(buffer, "{s} {s}", .{ px(value.top, &a), px(value.right, &b) }) catch null;
    return std.fmt.bufPrint(buffer, "{s} {s} {s} {s}", .{ px(value.top, &a), px(value.right, &b), px(value.bottom, &c), px(value.left, &d) }) catch null;
}
fn alignName(value: view.Align) []const u8 {
    return switch (value) {
        .start => "flex-start",
        .center => "center",
        .end => "flex-end",
        .stretch => "stretch",
    };
}
fn justifyName(value: view.Justify) []const u8 {
    return switch (value) {
        .start => "flex-start",
        .center => "center",
        .end => "flex-end",
        .space_between => "space-between",
    };
}

/// A declaration of the details: a property and its value, after a swatch
/// of its color when it has one.
pub const Decl = struct { name: []const u8, value: []const u8, swatch: ?u32 = null };
const Section = struct { title: []const u8, start: usize, end: usize };

/// The details of the element chosen, for the tabs below the tree: its
/// styles as a CSS rule, its computed values and its properties.
pub const Details = struct {
    styles: [40]Decl = undefined,
    style_count: usize = 0,
    computed: [24]Decl = undefined,
    computed_count: usize = 0,
    properties: [24]Decl = undefined,
    property_count: usize = 0,
    sections: [3]Section = undefined,
    section_count: usize = 0,
    scratch: [4096]u8 = undefined,
    used: usize = 0,

    fn print(self: *Details, comptime format: []const u8, args: anytype) []const u8 {
        const out = std.fmt.bufPrint(self.scratch[self.used..], format, args) catch return "";
        self.used += out.len;
        return out;
    }
    fn style(self: *Details, name: []const u8, value: []const u8) void {
        if (self.style_count == self.styles.len) return;
        self.styles[self.style_count] = .{ .name = name, .value = value };
        self.style_count += 1;
    }
    fn styleColor(self: *Details, name: []const u8, rgb: u32) void {
        if (self.style_count == self.styles.len) return;
        self.styles[self.style_count] = .{ .name = name, .value = self.print("#{x:0>6}", .{rgb & 0xffffff}), .swatch = rgb };
        self.style_count += 1;
    }
    fn computedValue(self: *Details, name: []const u8, value: []const u8, swatch: ?u32) void {
        if (self.computed_count == self.computed.len) return;
        self.computed[self.computed_count] = .{ .name = name, .value = value, .swatch = swatch };
        self.computed_count += 1;
    }
    fn property(self: *Details, name: []const u8, value: []const u8) void {
        if (self.property_count == self.properties.len) return;
        self.properties[self.property_count] = .{ .name = name, .value = value };
        self.property_count += 1;
    }
    fn section(self: *Details, title: []const u8) void {
        if (self.section_count > 0) self.sections[self.section_count - 1].end = self.property_count;
        self.sections[self.section_count] = .{ .title = title, .start = self.property_count, .end = self.property_count };
        self.section_count += 1;
    }
    fn len(self: *Details, value: f32) []const u8 {
        var digits: [24]u8 = undefined;
        if (value == 0) return "0";
        return self.print("{s}px", .{number(value, &digits)});
    }
    fn bool_(value: bool) []const u8 {
        return if (value) "true" else "false";
    }

    /// The rule's selector: the tag, with the key.
    pub fn selector(_: *const Details, inspector: *const Inspector, index: usize, buffer: []u8) []const u8 {
        const e = &inspector.elements[index];
        var names: [32]u8 = undefined;
        const tag = tagName(e.kind, &names);
        if (e.key) |value| return std.fmt.bufPrint(buffer, "{s}#{d} {{", .{ tag, value }) catch "";
        return std.fmt.bufPrint(buffer, "{s} {{", .{tag}) catch "";
    }

    pub fn describe(self: *Details, inspector: *const Inspector, index: usize) void {
        const e = &inspector.elements[index];
        const container = switch (e.kind) {
            .text, .note, .badge, .spacer, .image, .svg, .icon, .embed => false,
            else => e.kids or e.kind == .column or e.kind == .row,
        };
        // Styles: what the element sets, as CSS declarations.
        if (container) {
            if (e.axis == .row) self.style("flex-direction", "row");
            if (e.gap != 0) self.style("gap", self.len(e.gap));
            if (e.justify != .start) self.style("justify-content", justifyName(e.justify));
            if (e.alignment != .stretch) self.style("align-items", alignName(e.alignment));
        }
        if (e.self_align) |value| self.style("align-self", alignName(value));
        if (e.direction) |value| self.style("direction", if (value == .rtl) "rtl" else "ltr");
        if (e.width) |value| self.style("width", self.len(value));
        if (e.height) |value| self.style("height", self.len(value));
        if (e.min_width != 0) self.style("min-width", self.len(e.min_width));
        if (e.min_height != 0) self.style("min-height", self.len(e.min_height));
        if (std.math.isFinite(e.max_width)) self.style("max-width", self.len(e.max_width));
        if (std.math.isFinite(e.max_height)) self.style("max-height", self.len(e.max_height));
        if (e.grow != 0) self.style("flex-grow", self.print("{s}", .{number(e.grow, self.scratch[self.used + 32 ..])}));
        if (e.shrink != 1) self.style("flex-shrink", self.print("{d}", .{e.shrink}));
        if (edges(e.padding, self.scratch[self.used..])) |value| {
            self.used += value.len;
            self.style("padding", value);
        }
        if (e.border) |rgb| {
            var digits: [24]u8 = undefined;
            self.styles[self.style_count] = .{ .name = "border", .value = self.print("{s} solid #{x:0>6}", .{ px(e.border_width, &digits), rgb & 0xffffff }), .swatch = rgb };
            self.style_count += 1;
        }
        if (e.radius != 0) self.style("border-radius", self.len(e.radius));
        if (e.clip) self.style("overflow", "clip");
        if (e.kind == .scroll) self.style("overflow-y", "scroll");
        if (e.material) self.style("backdrop-filter", "material") else if (e.background) |rgb| self.styleColor("background-color", rgb);
        if (e.opacity < 1) self.style("opacity", self.print("{d}", .{e.opacity}));
        if (e.pose) self.style("transform", "pose");
        if (e.effect) self.style("filter", "shader");
        if (e.cursor) |value| self.style("cursor", cursorName(value));
        if (e.color) |rgb| self.styleColor("color", rgb);
        if (e.font) |font| {
            if (font.monospace) self.style("font-family", "monospace");
            self.style("font-size", self.len(font.size));
            if (font.weight != .regular) self.style("font-weight", self.print("{d}", .{font.weight.value()}));
            if (font.italic) self.style("font-style", "italic");
        }
        if (e.kind == .text) {
            if (e.max_lines > 0) self.style("line-clamp", self.print("{d}", .{e.max_lines}));
            self.style("white-space", if (e.wrap) "normal" else "nowrap");
        }

        // Computed: the values it has as laid out, by name.
        const display = switch (e.kind) {
            .text, .note, .badge => "text",
            .image, .svg, .icon, .avatar => "image",
            .grid, .table_header, .table_row => "grid",
            else => if (container) "flex" else "block",
        };
        const font = e.font orelse Font{};
        const ink = e.color orelse 0x182430;
        var list: [24]Decl = undefined;
        var n: usize = 0;
        list[n] = .{ .name = "color", .value = self.print("#{x:0>6}", .{ink & 0xffffff}), .swatch = ink };
        n += 1;
        list[n] = .{ .name = "direction", .value = if (e.rtl) "rtl" else "ltr" };
        n += 1;
        list[n] = .{ .name = "display", .value = display };
        n += 1;
        if (container) {
            list[n] = .{ .name = "flex-direction", .value = if (e.axis == .row) "row" else "column" };
            n += 1;
        }
        list[n] = .{ .name = "font-family", .value = if (font.monospace) "monospace" else "system-ui" };
        n += 1;
        list[n] = .{ .name = "font-size", .value = self.len(font.size) };
        n += 1;
        list[n] = .{ .name = "font-weight", .value = self.print("{d}", .{font.weight.value()}) };
        n += 1;
        list[n] = .{ .name = "height", .value = self.len(e.bounds.height) };
        n += 1;
        list[n] = .{ .name = "left", .value = self.len(e.bounds.x) };
        n += 1;
        list[n] = .{ .name = "opacity", .value = self.print("{d}", .{e.opacity}) };
        n += 1;
        if (e.scroll_offset) |offset| {
            list[n] = .{ .name = "scroll-height", .value = self.len(e.scroll_content.height) };
            n += 1;
            list[n] = .{ .name = "scroll-left", .value = self.len(offset.x) };
            n += 1;
            list[n] = .{ .name = "scroll-top", .value = self.len(offset.y) };
            n += 1;
            list[n] = .{ .name = "scroll-width", .value = self.len(e.scroll_content.width) };
            n += 1;
        }
        list[n] = .{ .name = "top", .value = self.len(e.bounds.y) };
        n += 1;
        list[n] = .{ .name = "width", .value = self.len(e.bounds.width) };
        n += 1;
        for (list[0..n]) |decl| self.computedValue(decl.name, decl.value, decl.swatch);

        // Properties: what it is, its state, and what assistive
        // technology sees of it.
        var names: [32]u8 = undefined;
        self.section("Element");
        self.property("type", self.print("{s}", .{tagName(e.kind, &names)}));
        self.property("id", self.print("{x:0>16}", .{e.id}));
        if (e.key) |value| self.property("key", self.print("{d}", .{value}));
        if (e.id == inspector.selected and inspector.source_len > 0) self.property("built at", inspector.source());
        if (e.text.len > 0) self.property("text", self.print("\"{s}\"", .{clip(e.text, 200)}));
        self.section("State");
        self.property("focused", bool_(inspector.focus != null and inspector.focus.? == e.id));
        const hovered = if (inspector.pointer) |point| if (e.visible) |rect| contains(rect, point) else false else false;
        self.property("hovered", bool_(hovered));
        self.property("disabled", bool_(!e.enabled));
        switch (e.kind) {
            .checkbox, .radio, .toggle_switch, .segment, .tab, .list_item, .disclosure => self.property("checked", bool_(e.checked)),
            .slider, .stepper, .rating, .progress, .meter => self.property("value", self.print("{d}", .{e.value})),
            else => {},
        }
        self.section("Accessibility");
        self.property("name", self.print("\"{s}\"", .{accessibleName(e)}));
        self.property("role", roleName(e.kind, e.name.len > 0));
        self.property("keyboard-focusable", bool_(focusable(e)));
        self.sections[self.section_count - 1].end = self.property_count;
    }
};

/// The file's name and what follows it in a path.
fn baseName(path_text: []const u8) []const u8 {
    const at = std.mem.lastIndexOfAny(u8, path_text, "/\\") orelse return path_text;
    return path_text[at + 1 ..];
}

/// The first of the return addresses in `trace` whose code lies outside
/// the view's own files and the standard library, as `file:line` in
/// `out`; "" without debug information.
fn locateSource(trace: []const usize, out: []u8) []const u8 {
    if (comptime !std.debug.sys_can_stack_trace) return "";
    const info = std.debug.getSelfDebugInfo() catch return "";
    var own: [512]u8 = undefined;
    const here = lineAt(info, @returnAddress() - 1, &own) orelse return "";
    const own_dir = here.file[0 .. std.mem.lastIndexOfAny(u8, here.file, "/\\") orelse 0];
    for (trace) |address| {
        if (address == 0) continue;
        const at = lineAt(info, address - 1, out) orelse continue;
        // The view's files, but for its tests, which build as an
        // application does.
        if (own_dir.len > 0 and std.mem.startsWith(u8, at.file, own_dir) and std.mem.indexOfAnyPos(u8, at.file, own_dir.len + 1, "/\\") == null and !std.mem.endsWith(u8, at.file, "_tests.zig")) continue;
        if (std.mem.indexOf(u8, at.file, "lib/std/") != null or std.mem.indexOf(u8, at.file, "lib\\std\\") != null) continue;
        const suffix = std.fmt.bufPrint(out[at.file.len..], ":{d}", .{at.line}) catch return "";
        return out[0 .. at.file.len + suffix.len];
    }
    return "";
}
fn lineAt(info: *std.debug.SelfInfo, address: usize, out: []u8) ?struct { file: []const u8, line: u64 } {
    var scratch: [4096]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
    var symbols: std.ArrayList(std.debug.Symbol) = .empty;
    info.getSymbols(zio.io(), fixed.allocator(), fixed.allocator(), address, false, &symbols) catch return null;
    if (symbols.items.len == 0) return null;
    const location = symbols.items[0].source_location orelse return null;
    if (location.file_name.len + 24 > out.len) return null;
    @memcpy(out[0..location.file_name.len], location.file_name);
    return .{ .file = out[0..location.file_name.len], .line = location.line };
}

fn cursorName(value: Cursor) []const u8 {
    return switch (value) {
        .resize_ew => "ew-resize",
        .resize_ns => "ns-resize",
        .resize_nwse => "nwse-resize",
        .resize_nesw => "nesw-resize",
        .resize_n => "n-resize",
        .resize_e => "e-resize",
        .resize_s => "s-resize",
        .resize_w => "w-resize",
        .resize_column => "col-resize",
        .resize_row => "row-resize",
        .not_allowed => "not-allowed",
        .vertical_text => "vertical-text",
        .context_menu => "context-menu",
        else => @tagName(value),
    };
}
