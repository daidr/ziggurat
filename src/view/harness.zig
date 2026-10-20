//! Drives a build function without a window. The harness runs the same
//! build, layout and event passes as Host, so tests can find controls by
//! kind, label or key, activate them by query or point, and inspect the
//! resulting state and tree. Nothing here touches native code or allocates.
//! With `attachInput`, each render is also recorded into a windowless
//! ui.Context so keys replay through the same focus, Tab, arrow and
//! activation logic that a window uses. Time is frozen unless a test
//! advances it, so tooltips and toasts are checked without sleeping.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("root.zig");

const View = view.View;
const Node = view.Node;
const Kind = view.Kind;
const Rect = view.Rect;
const Event = view.Event;
const ValueChange = view.ValueChange;
const SortDirection = view.SortDirection;

/// Selects nodes in build order. Every set field must match; `nth` picks one
/// of several matches, otherwise more than one match is `Ambiguous`.
pub const Query = struct {
    kind: ?Kind = null,
    /// Exact label or text content.
    text: ?[]const u8 = null,
    /// Exact accessible name from `Style.name`.
    name: ?[]const u8 = null,
    key: ?u64 = null,
    nth: ?usize = null,

    fn matches(self: Query, node: *const Node) bool {
        if (self.kind) |kind| if (node.kind != kind) return false;
        if (self.text) |text| if (!std.mem.eql(u8, node.text, text)) return false;
        if (self.name) |name| if (!std.mem.eql(u8, node.style.name, name)) return false;
        if (self.key) |value| if (node.style.key == null or node.style.key.? != value) return false;
        return true;
    }
};

pub const Error = error{ NotFound, Ambiguous, Disabled, Hidden, NotActivatable, NotAdjustable, NotScrollable, Stale };

pub const Config = struct {
    bounds: Rect = .{ .x = 0, .y = 0, .width = 640, .height = 480 },
    theme: view.Theme = .{},
    options: view.Options = .{},
};

pub const Harness = struct {
    view: View,
    build: view.Build,
    config: Config,
    /// Completed render passes, including the one after each delivered event.
    frames: usize = 0,
    /// Windowless Context whose input state receives each rendered frame.
    input: ?*ui.Context = null,
    /// The test's clock in nanoseconds; it moves only with `advance`.
    clock: u64 = 0,
    /// Focus given by `focus` when no input Context is attached.
    focus_id: ?u64 = null,

    pub fn init(state: anytype, comptime build: fn (@TypeOf(state), *View) anyerror!void, buffers: view.Buffers, config: Config) Harness {
        var built = View.init(buffers);
        built.tooltip_delay = config.options.tooltip_delay;
        return .{ .view = built, .build = view.Build.bind(state, build), .config = config };
    }

    fn run(self: *Harness, event: ?Event) anyerror!void {
        self.view.now = self.clock;
        self.view.focus = self.focusId();
        try self.build.run(&self.view, self.config.options.root, event);
    }
    fn focusId(self: *const Harness) ?u64 {
        if (self.input) |context| return context.input_state.focused;
        return self.focus_id;
    }
    fn setFocus(self: *Harness, id: ?u64) void {
        if (self.input) |context| context.input_state.setFocused(id) else self.focus_id = id;
    }
    fn restoreFocus(self: *Harness) void {
        const id = self.view.restore orelse return;
        self.view.restore = null;
        self.setFocus(id);
    }

    /// Build and arrange the current state, as a paint would.
    pub fn render(self: *Harness) anyerror!void {
        try self.run(null);
        try self.view.arrange(self.config.bounds, self.config.theme, self.config.options.measurer);
        if (self.input) |context| try self.record(context);
        self.frames += 1;
    }

    /// Record every following render into `context`, which must not be
    /// attached to a window and must stay valid while the harness uses it.
    /// Its action callback is never called; keys deliver events to the
    /// build function directly. Renders once.
    pub fn attachInput(self: *Harness, context: *ui.Context) anyerror!void {
        if (context.window != null) return error.Attached;
        context.on_value = context.on_value orelse ignoreValue;
        self.input = context;
        try self.render();
    }
    fn ignoreValue(_: *anyopaque, _: u64, _: view.ValueChange) void {}

    fn record(self: *Harness, context: *ui.Context) anyerror!void {
        const b = self.config.bounds;
        context.command_buffer.reset();
        defer context.command_buffer.reset();
        context.input_state.beginFrame();
        errdefer context.input_state.cancelFrame();
        var frame: ui.Frame = .{ .context = context, .size = .{ .width = @intFromFloat(@ceil(b.x + b.width)), .height = @intFromFloat(@ceil(b.y + b.height)), .scale = 1 } };
        try self.view.paint(&frame);
        if (frame.failure) |err| return err;
        context.input_state.commitFrame();
    }

    /// The node holding keyboard focus after the last render, if any.
    pub fn focused(self: *const Harness) ?*const Node {
        const id = self.focusId() orelse return null;
        for (self.view.nodes()) |*node| if (node.id == id) return node;
        return null;
    }

    /// Give the matching node keyboard focus, as a press or Tab would,
    /// then render. Embedded leaves such as text fields can take it too.
    pub fn focus(self: *Harness, query: Query) anyerror!void {
        const node = try self.find(query);
        try self.check(node);
        self.setFocus(node.id);
        try self.render();
    }

    /// Move the test clock forward and render, as a timer wake would.
    pub fn advance(self: *Harness, nanoseconds: u64) anyerror!void {
        self.clock += nanoseconds;
        try self.render();
    }

    /// Rest the pointer on the matching node, then render.
    pub fn hover(self: *Harness, query: Query) anyerror!void {
        const node = try self.find(query);
        const rect = self.visible(node) orelse return error.Hidden;
        try self.hoverAt(rect.x + rect.width / 2, rect.y + rect.height / 2);
    }
    /// Move the pointer to a point, or away from every control with null,
    /// as Host does, then render.
    pub fn hoverAt(self: *Harness, x: f32, y: f32) anyerror!void {
        _ = self.view.hoverAt(.{ .x = x, .y = y });
        try self.render();
    }
    pub fn leave(self: *Harness) anyerror!void {
        _ = self.view.hoverAt(null);
        try self.render();
    }
    /// The tooltip text the last render shows, if any.
    pub fn tooltip(self: *const Harness) ?[]const u8 {
        if (self.view.tip_index == std.math.maxInt(u32)) return null;
        return self.view.nodes()[self.view.tip_index].tooltip;
    }
    /// The earliest pass time the last render asked to run again at.
    pub fn deadline(self: *const Harness) ?u64 {
        return self.view.wake;
    }

    /// Replay one key press in the order a window routes it to controls:
    /// shortcuts, Tab, range keys, group arrows, spatial arrows, Home/End,
    /// then Enter/Space activation. Delivers any resulting event, renders,
    /// and returns whether a control handled the key. Needs `attachInput`.
    pub fn key(self: *Harness, input: z.KeyInput) anyerror!bool {
        const context = self.input orelse return error.NoInput;
        self.view.focus = self.focusId();
        switch (self.view.routeKey(input)) {
            .ignored => {},
            .handled => {
                self.restoreFocus();
                try self.render();
                return true;
            },
            .pass => self.restoreFocus(),
            .deliver => |event| return self.deliverKey(event),
        }
        const state = &context.input_state;
        const mods = input.modifiers;
        const plain = !mods.control and !mods.alt and !mods.super;
        if (state.matchShortcut(input)) |id| {
            if (state.get(id).?.options.range == null) return self.deliverKey(.{ .action = id });
            state.setFocused(id);
        } else if (input.key == .tab and plain) {
            state.tabDirection(mods.shift);
        } else if (state.rangeKey(input)) |action| {
            return self.deliverKey(.{ .value = .{ .id = action.id, .change = action.change } });
        } else if (if (editKey(input)) |edit| state.navigate(edit) else null) |id| {
            return self.deliverKey(.{ .action = id });
        } else if (!plain or mods.shift) {
            return false;
        } else if (state.spatial(input.key)) {} else if (input.key == .home or input.key == .end) {
            state.setFocused(null);
            state.tabDirection(input.key == .end);
        } else if (input.key == .enter or input.key == .space) {
            if (!input.repeat) if (state.activation()) |id| return self.deliverKey(.{ .action = id });
        } else return false;
        try self.render();
        return true;
    }
    fn deliverKey(self: *Harness, event: Event) anyerror!bool {
        try self.deliver(event);
        return true;
    }
    fn editKey(input: z.KeyInput) ?z.EditKey {
        const code: z.EditKeyCode = switch (input.key) {
            .left => .left,
            .right => .right,
            .up => .up,
            .down => .down,
            .home => .home,
            .end => .end,
            else => return null,
        };
        return .{ .key = code, .shift = input.modifiers.shift, .control = input.modifiers.control };
    }

    pub fn resize(self: *Harness, bounds: Rect) anyerror!void {
        self.config.bounds = bounds;
        try self.render();
    }

    pub fn nodes(self: *const Harness) []const Node {
        return self.view.nodes();
    }

    pub fn count(self: *const Harness, query: Query) usize {
        var total: usize = 0;
        for (self.view.nodes()) |*node| {
            if (query.matches(node)) total += 1;
        }
        return total;
    }

    pub fn find(self: *const Harness, query: Query) Error!*const Node {
        var found: ?*const Node = null;
        var seen: usize = 0;
        for (self.view.nodes()) |*node| {
            if (!query.matches(node)) continue;
            if (query.nth) |nth| {
                if (seen == nth) return node;
            } else if (found != null) return error.Ambiguous else found = node;
            seen += 1;
        }
        return found orelse error.NotFound;
    }

    /// The part of `node` left visible by its own bounds and every clipping
    /// ancestor, or null when nothing of it can be seen or hit.
    pub fn visible(self: *const Harness, node: *const Node) ?Rect {
        return self.view.visible(node);
    }

    /// The last painted interactive node under `point`, honouring clips.
    /// Popups and toasts are painted after the tree, so they are hit first.
    pub fn at(self: *const Harness, x: f32, y: f32) ?*const Node {
        const all = self.view.nodes();
        inline for (.{ true, false }) |over| {
            var index = all.len;
            while (index > 0) {
                index -= 1;
                const node = &all[index];
                if (!interactive(node.kind) or self.floating(node) != over) continue;
                const rect = self.visible(node) orelse continue;
                if (contains(rect, x, y)) return node;
            }
        }
        return null;
    }
    fn floating(self: *const Harness, node: *const Node) bool {
        const all = self.view.nodes();
        var parent = node.parent;
        while (parent < all.len) : (parent = all[parent].parent) if (all[parent].floats()) return true;
        return false;
    }

    /// Activate the matching button, link, checkbox, switch, radio, segment,
    /// tab, list item or disclosure, then render.
    pub fn click(self: *Harness, query: Query) anyerror!void {
        const node = try self.find(query);
        if (isRow(node.kind)) return self.clickWith(query, .{});
        try self.activate(node);
    }

    /// Press a tree or table row with modifiers, as Host routes a press:
    /// Ctrl toggles and Shift extends a multiple selection. Renders.
    pub fn clickWith(self: *Harness, query: Query, modifiers: z.KeyModifiers) anyerror!void {
        const node = try self.find(query);
        if (!isRow(node.kind)) return error.NotActivatable;
        try self.check(node);
        const rect = self.visible(node).?;
        // The right end of a row is clear of a tree row's triangle.
        try self.pressRow(node, .{ .x = rect.x + rect.width - 1, .y = rect.y + rect.height / 2 }, modifiers);
    }
    /// Press the triangle of a tree row to expand or collapse it. Renders.
    pub fn toggleExpanded(self: *Harness, query: Query) anyerror!void {
        const node = try self.find(query);
        if (node.kind != .tree_row or node.expanded == null) return error.NotActivatable;
        try self.check(node);
        const mark = ui.widgets.treeExpander(node.bounds, node.level, self.config.theme.metrics.indicator_size);
        try self.pressRow(node, .{ .x = mark.x + mark.width / 2, .y = mark.y + mark.height / 2 }, .{});
    }
    fn pressRow(self: *Harness, node: *const Node, point: view.Point, modifiers: z.KeyModifiers) anyerror!void {
        const event = self.view.rowPress(point, modifiers, node.id, self.config.theme) orelse return error.Hidden;
        try self.deliver(event);
    }
    /// Press the remove button of the matching token. Renders.
    pub fn removeToken(self: *Harness, query: Query) anyerror!void {
        const node = try self.find(query);
        if (node.kind != .token) return error.NotActivatable;
        try self.check(node);
        try self.deliver(.{ .action = view.tokenRemoveId(node.id) });
    }

    /// Press and release at a point, as Host routes it: an open popup or a
    /// shown tooltip sees the press first, then the interactive node under
    /// the point is activated. Renders.
    pub fn clickAt(self: *Harness, x: f32, y: f32) anyerror!void {
        switch (self.view.pointerDown(.{ .x = x, .y = y })) {
            .consumed => return self.render(),
            .changed, .ignored => {},
        }
        const node = self.at(x, y) orelse {
            try self.render();
            return error.NotFound;
        };
        if (isRow(node.kind)) return self.pressRow(node, .{ .x = x, .y = y }, .{});
        if (node.kind == .token) {
            const b = node.bounds;
            const width = ui.widgets.tokenRemoveWidth(b);
            if (x >= b.x + b.width - width) return self.deliver(.{ .action = view.tokenRemoveId(node.id) });
        }
        try self.activate(node);
    }

    /// Apply a value change to the matching slider, stepper, rating or
    /// split, then render.
    pub fn change(self: *Harness, query: Query, value: ValueChange) anyerror!void {
        const node = try self.find(query);
        switch (node.kind) {
            .slider, .stepper, .rating, .split => {},
            else => return error.NotAdjustable,
        }
        try self.check(node);
        try self.deliver(.{ .value = .{ .id = node.id, .change = value } });
    }

    /// Scroll the matching scroll container by `delta` DIP, then render.
    pub fn scroll(self: *Harness, query: Query, delta: view.Point) anyerror!void {
        const node = try self.find(query);
        if (node.kind != .scroll) return error.NotScrollable;
        if (self.visible(node) == null) return error.Hidden;
        try self.deliver(.{ .scroll = .{ .id = node.id, .delta = delta } });
    }

    /// Send wheel movement at a point to the innermost visible scroll
    /// container under it, as Host does, then render.
    pub fn wheel(self: *Harness, x: f32, y: f32, delta: view.Point) anyerror!void {
        const all = self.view.nodes();
        var index = all.len;
        while (index > 0) {
            index -= 1;
            const node = &all[index];
            if (node.kind != .scroll) continue;
            const rect = self.visible(node) orelse continue;
            if (!contains(rect, x, y)) continue;
            return self.deliver(.{ .scroll = .{ .id = node.id, .delta = delta } });
        }
        return error.NotFound;
    }

    fn activate(self: *Harness, node: *const Node) anyerror!void {
        switch (node.kind) {
            .button, .link, .nav_button, .combo_box, .checkbox, .toggle_switch, .radio, .segment, .tab, .list_item, .disclosure, .column_header, .token, .combo_toggle => {},
            else => return error.NotActivatable,
        }
        try self.check(node);
        // A press focuses the control it lands on, as in a window.
        self.setFocus(node.id);
        try self.deliver(.{ .action = node.id });
    }

    fn check(self: *const Harness, node: *const Node) Error!void {
        if (!node.style.enabled) return error.Disabled;
        if (self.visible(node) == null) return error.Hidden;
    }

    fn deliver(self: *Harness, event: Event) anyerror!void {
        try self.run(event);
        // The node came from the last render; a build that no longer emits it
        // means the test is acting on a stale tree.
        if (!self.view.consumed) return error.Stale;
        self.restoreFocus();
        try self.render();
    }

    /// Write an indented outline of the arranged tree, one node per line,
    /// suitable for comparison in tests.
    pub fn write(self: *const Harness, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const all = self.view.nodes();
        for (all) |*node| {
            var depth: usize = 0;
            var parent = node.parent;
            while (parent < all.len) : (parent = all[parent].parent) depth += 1;
            try writer.splatByteAll(' ', depth * 2);
            try writer.writeAll(@tagName(node.kind));
            if (node.text.len > 0) try writer.print(" \"{s}\"", .{node.text});
            if (node.style.name.len > 0) try writer.print(" name=\"{s}\"", .{node.style.name});
            switch (node.kind) {
                .checkbox, .toggle_switch, .radio, .segment, .tab, .list_item, .disclosure => try writer.writeAll(if (node.checked) " on" else " off"),
                .combo_box, .popup, .combo_field => try writer.writeAll(if (node.checked) " open" else " closed"),
                .tree_row, .table_row => {
                    if (node.kind == .tree_row) try writer.print(" level={d}", .{node.level});
                    if (node.expanded) |open| try writer.writeAll(if (open) " expanded" else " collapsed");
                    if (node.checked) try writer.writeAll(" selected");
                    if (node.cursor) try writer.writeAll(" cursor");
                },
                .column_header => if (node.sort) |direction| try writer.print(" {s}", .{@tagName(direction)}),
                .progress => try writer.print(" {d:.2}", .{node.fraction}),
                .slider, .stepper, .rating, .meter, .split => try writer.print(" {d}", .{node.value}),
                .scroll => if (node.scroll) |model| try writer.print(" offset={d}", .{round(model.offset.y)}),
                else => {},
            }
            if (node.highlighted) try writer.writeAll(" highlighted");
            if (node.tooltip.len > 0) try writer.print(" tooltip=\"{s}\"", .{node.tooltip});
            if (node.invalid) try writer.writeAll(" invalid");
            if (node.required) try writer.writeAll(" required");
            if (!node.style.enabled) try writer.writeAll(" disabled");
            const b = node.bounds;
            try writer.print(" @{d},{d} {d}x{d}\n", .{ round(b.x), round(b.y), round(b.width), round(b.height) });
        }
        if (self.tooltip()) |text| {
            const b = self.view.tip_rect;
            try writer.print("tooltip \"{s}\" @{d},{d} {d}x{d}\n", .{ text, round(b.x), round(b.y), round(b.width), round(b.height) });
        }
    }
};

fn interactive(kind: Kind) bool {
    return switch (kind) {
        .button, .link, .nav_button, .combo_box, .checkbox, .toggle_switch, .radio, .segment, .tab, .list_item, .disclosure, .slider, .stepper, .rating, .tree_row, .table_row, .column_header, .token, .combo_toggle => true,
        else => false,
    };
}
fn isRow(kind: Kind) bool {
    return kind == .tree_row or kind == .table_row;
}

fn contains(rect: Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x < rect.x + rect.width and y < rect.y + rect.height;
}

fn round(value: f32) i64 {
    return @intFromFloat(@round(value));
}

const Todo = struct {
    done: [3]bool = .{ false, false, false },
    names: [3][]const u8 = .{ "Write", "Test", "Ship" },
    filter: enum { all, open } = .all,
    zoom: f64 = 1,
    cleared: usize = 0,

    fn remaining(self: *const Todo) usize {
        var total: usize = 0;
        for (self.done) |done| total += @intFromBool(!done);
        return total;
    }

    fn build(self: *Todo, v: *View) anyerror!void {
        try v.textf("{d} left", .{self.remaining()}, .{});
        try v.radioGroup(.{ .name = "Filter" });
        _ = try v.radio(@TypeOf(self.filter), &self.filter, .all, "All", .{});
        _ = try v.radio(@TypeOf(self.filter), &self.filter, .open, "Open", .{});
        try v.end();
        try v.column(.{ .clip = true, .height = 60 });
        for (&self.done, self.names) |*done, name| {
            if (self.filter == .open and done.*) continue;
            _ = try v.checkbox(done, name, .{ .key = view.key(name) });
        }
        try v.end();
        _ = try v.slider(&self.zoom, .{ .minimum = 1, .maximum = 3, .step = 0.5 }, .{});
        if (try v.button("Clear", .{ .enabled = self.remaining() < 3 })) {
            self.done = .{ false, false, false };
            self.cleared += 1;
        }
    }
};

test "queries find nodes by kind, text, name and key" {
    var storage: view.Storage(32, 512) = .{};
    var state: Todo = .{};
    var h = Harness.init(&state, Todo.build, storage.buffers(), .{});
    try h.render();
    try std.testing.expectEqual(@as(usize, 3), h.count(.{ .kind = .checkbox }));
    try std.testing.expectEqualStrings("Test", (try h.find(.{ .key = view.key("Test") })).text);
    try std.testing.expectEqual(Kind.radio_group, (try h.find(.{ .name = "Filter" })).kind);
    try std.testing.expectEqualStrings("Ship", (try h.find(.{ .kind = .checkbox, .nth = 2 })).text);
    try std.testing.expectError(error.Ambiguous, h.find(.{ .kind = .checkbox }));
    try std.testing.expectError(error.NotFound, h.find(.{ .text = "Missing" }));
    try std.testing.expectError(error.NotFound, h.find(.{ .kind = .radio, .nth = 5 }));
}

test "clicks and value changes update state and re-render" {
    var storage: view.Storage(32, 512) = .{};
    var state: Todo = .{};
    var h = Harness.init(&state, Todo.build, storage.buffers(), .{});
    try h.render();
    try std.testing.expectError(error.Disabled, h.click(.{ .text = "Clear" }));

    try h.click(.{ .text = "Write" });
    try std.testing.expect(state.done[0]);
    try std.testing.expectEqualStrings("2 left", (try h.find(.{ .kind = .text })).text);
    try std.testing.expect((try h.find(.{ .text = "Write" })).checked);

    try h.click(.{ .text = "Open" });
    try std.testing.expectEqual(.open, state.filter);
    try std.testing.expectEqual(@as(usize, 2), h.count(.{ .kind = .checkbox }));

    try h.change(.{ .kind = .slider }, .{ .steps = 3 });
    try std.testing.expectEqual(@as(f64, 2.5), state.zoom);
    try std.testing.expectEqual(@as(f64, 2.5), (try h.find(.{ .kind = .slider })).value);

    try h.click(.{ .text = "Clear" });
    try std.testing.expectEqual(@as(usize, 1), state.cleared);
    try std.testing.expectEqual(@as(usize, 3), state.remaining());

    try std.testing.expectError(error.NotActivatable, h.click(.{ .kind = .text }));
    try std.testing.expectError(error.NotAdjustable, h.change(.{ .text = "Clear" }, .{ .steps = 1 }));
}

test "point hits honour clips and paint order" {
    var storage: view.Storage(32, 512) = .{};
    var state: Todo = .{};
    var h = Harness.init(&state, Todo.build, storage.buffers(), .{});
    try h.render();
    const write = try h.find(.{ .text = "Write" });
    try h.clickAt(write.bounds.x + 4, write.bounds.y + 4);
    try std.testing.expect(state.done[0]);

    // The third checkbox lies below the 60 DIP clip of its column; the gap
    // above the slider that overlaps its lower half hits nothing.
    const ship = try h.find(.{ .text = "Ship" });
    try std.testing.expect(h.visible(ship) == null);
    try std.testing.expect(h.at(ship.bounds.x + 4, ship.bounds.y + 4) == null);
    try std.testing.expectError(error.Hidden, h.click(.{ .text = "Ship" }));
    try std.testing.expectError(error.NotFound, h.clickAt(-10, -10));
}

test "a stale node is reported rather than silently ignored" {
    const Flip = struct {
        shown: bool = true,
        fn build(self: *@This(), v: *View) anyerror!void {
            if (self.shown) _ = try v.button("Go", .{});
        }
    };
    var storage: view.Storage(8, 64) = .{};
    var state: Flip = .{};
    var h = Harness.init(&state, Flip.build, storage.buffers(), .{});
    try h.render();
    state.shown = false;
    try std.testing.expectError(error.Stale, h.click(.{ .text = "Go" }));
}

test "outline lists the arranged tree" {
    var storage: view.Storage(32, 512) = .{};
    var state: Todo = .{};
    state.done[1] = true;
    var h = Harness.init(&state, Todo.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 320, .height = 400 } });
    try h.render();
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try h.write(&writer);
    try std.testing.expectEqualStrings(
        \\column @0,0 320x400
        \\  text "2 left" @24,24 54x24
        \\  radio_group name="Filter" @24,60 66x64
        \\    radio "All" on @24,60 66x32
        \\    radio "Open" off @24,92 66x32
        \\  column @24,136 75x60
        \\    checkbox "Write" off @24,136 75x32
        \\    checkbox "Test" on @24,168 75x32
        \\    checkbox "Ship" off @24,200 75x32
        \\  slider 1 @24,208 200x32
        \\  button "Clear" @24,252 77x40
        \\
    , writer.buffered());
}

const Gallery = struct {
    model: view.ScrollModel = .{},
    count: f64 = 2,
    picked: ?usize = null,
    const columns = [_]view.Track{ view.Track.fixed(80), view.Track.fraction(1) };

    fn build(self: *Gallery, v: *View) anyerror!void {
        _ = try v.stepper(&self.count, .{ .minimum = 0, .maximum = 12, .step = 1 }, .{ .name = "Count" });
        try v.grid(&columns, .{ .gap = 4 });
        try v.text("Name", .{});
        try v.text("Value", .{});
        try v.text("Wide cell", .{ .column_span = 2 });
        try v.end();
        try v.scroll(&self.model, .{ .height = 100, .gap = 4 });
        for (0..@intFromFloat(self.count)) |i| {
            if (try v.button("Item", .{ .key = i, .height = 30 })) self.picked = i;
        }
        try v.end();
    }
};

test "grids place children row by row with spans" {
    var storage: view.Storage(32, 256) = .{};
    var state: Gallery = .{};
    var h = Harness.init(&state, Gallery.build, storage.buffers(), .{});
    try h.render();
    const name = try h.find(.{ .text = "Name" });
    const value = try h.find(.{ .text = "Value" });
    const wide = try h.find(.{ .text = "Wide cell" });
    try std.testing.expectEqual(@as(f32, 80), name.bounds.width);
    try std.testing.expectEqual(name.bounds.y, value.bounds.y);
    try std.testing.expectEqual(name.bounds.x + 80 + 4, value.bounds.x);
    try std.testing.expectEqual(name.bounds.x, wide.bounds.x);
    try std.testing.expectEqual(name.bounds.y + name.bounds.height + 4, wide.bounds.y);
    try std.testing.expectApproxEqAbs(value.bounds.x + value.bounds.width, wide.bounds.x + wide.bounds.width, 0.01);
}

test "steppers adjust bound values" {
    var storage: view.Storage(32, 256) = .{};
    var state: Gallery = .{};
    var h = Harness.init(&state, Gallery.build, storage.buffers(), .{});
    try h.render();
    try h.change(.{ .name = "Count" }, .{ .steps = 3 });
    try std.testing.expectEqual(@as(f64, 5), state.count);
    try std.testing.expectEqual(@as(usize, 5), h.count(.{ .text = "Item" }));
    try h.change(.{ .kind = .stepper }, .{ .steps = 100 });
    try std.testing.expectEqual(@as(f64, 12), state.count);
}

test "scroll containers clip, scroll by wheel and clamp to content" {
    var storage: view.Storage(32, 256) = .{};
    var state: Gallery = .{ .count = 6 };
    var h = Harness.init(&state, Gallery.build, storage.buffers(), .{});
    try h.render();
    const area = try h.find(.{ .kind = .scroll });
    try std.testing.expectEqual(@as(f32, 100), area.bounds.height);
    // Six 30 DIP items with 4 DIP gaps make 200 DIP of content.
    try std.testing.expectEqual(@as(f32, 100), state.model.viewport.height);
    try std.testing.expectEqual(@as(f32, 200), state.model.content.height);
    try std.testing.expectError(error.Hidden, h.click(.{ .key = 4 }));

    try h.wheel(area.bounds.x + 10, area.bounds.y + 10, .{ .x = 0, .y = 48 });
    try std.testing.expectEqual(@as(f32, 48), state.model.offset.y);
    const first = try h.find(.{ .key = 0 });
    try std.testing.expectEqual(area.bounds.y - 48, first.bounds.y);

    try h.scroll(.{ .kind = .scroll }, .{ .x = 0, .y = 1000 });
    try std.testing.expectEqual(@as(f32, 100), state.model.offset.y);
    try h.click(.{ .key = 5 });
    try std.testing.expectEqual(@as(?usize, 5), state.picked);
    try std.testing.expectError(error.Hidden, h.click(.{ .key = 0 }));

    // Fewer items clamp the offset back into range on the next arrange:
    // four make 132 DIP, three fit entirely in the viewport.
    state.count = 4;
    try h.render();
    try std.testing.expectEqual(@as(f32, 32), state.model.offset.y);
    state.count = 3;
    try h.render();
    try std.testing.expectEqual(@as(f32, 0), state.model.offset.y);
    try std.testing.expectError(error.NotFound, h.wheel(-5, -5, .{ .x = 0, .y = 10 }));
    try std.testing.expectError(error.NotScrollable, h.scroll(.{ .kind = .stepper }, .{ .x = 0, .y = 1 }));
}

const Editor = struct {
    section: enum { files, search } = .files,
    sidebar: f64 = 0.3,
    bold: bool = false,
    saved: usize = 0,

    fn build(self: *Editor, v: *View) anyerror!void {
        try v.toolbar(.{ .name = "Formatting", .gap = 4 });
        if (try v.button("Save", .{})) self.saved += 1;
        _ = try v.toggleSwitch(&self.bold, "Bold", .{});
        try v.end();
        _ = try v.split(.row, &self.sidebar, .{ .minimum = 0.2, .maximum = 0.8, .step = 0.1 }, .{ .grow = 1, .self_align = .stretch, .name = "Sidebar" });
        try v.column(.{ .clip = true });
        try v.tabs(.{ .name = "Sections" });
        _ = try v.tab(@TypeOf(self.section), &self.section, .files, "Files", .{});
        _ = try v.tab(@TypeOf(self.section), &self.section, .search, "Search", .{});
        try v.end();
        switch (self.section) {
            .files => try v.text("All files", .{}),
            .search => try v.text("Find in files", .{}),
        }
        try v.end();
        try v.text("Document", .{});
        try v.end();
    }
};

test "tabs switch content, splits divide space and toolbars parent controls" {
    var storage: view.Storage(32, 256) = .{};
    var state: Editor = .{};
    var h = Harness.init(&state, Editor.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 600, .height = 400 } });
    try h.render();
    const toolbar = try h.find(.{ .kind = .toolbar });
    try std.testing.expectEqual(toolbar.id, (try h.find(.{ .text = "Save" })).semantic_parent);
    try std.testing.expectEqual(toolbar.id, (try h.find(.{ .text = "Bold" })).semantic_parent);
    try std.testing.expectEqual(@as(u64, 0), (try h.find(.{ .text = "Files" })).semantic_parent);

    // The first pane takes 30% of the width left beside the divider.
    const split = try h.find(.{ .kind = .split });
    const sidebar = &h.nodes()[split.first_child];
    const content = try h.find(.{ .text = "Document" });
    const available = split.bounds.width - view.split_divider;
    try std.testing.expectEqual(@round(available * 0.3), sidebar.bounds.width);
    try std.testing.expectEqual(sidebar.bounds.x + sidebar.bounds.width + view.split_divider, content.bounds.x);
    try std.testing.expectEqualDeep(Rect{ .x = sidebar.bounds.x + sidebar.bounds.width, .y = split.bounds.y, .width = view.split_divider, .height = split.bounds.height }, h.view.divider(split).?);

    try h.change(.{ .name = "Sidebar" }, .{ .steps = 2 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), state.sidebar, 1e-9);
    try h.change(.{ .kind = .split }, .maximum);
    try std.testing.expectEqual(@as(f64, 0.8), state.sidebar);

    try std.testing.expect((try h.find(.{ .text = "Files" })).checked);
    try std.testing.expectEqual(@as(usize, 1), h.count(.{ .text = "All files" }));
    try h.click(.{ .text = "Search" });
    try std.testing.expectEqual(.search, state.section);
    try std.testing.expectEqual(@as(usize, 1), h.count(.{ .text = "Find in files" }));
    try std.testing.expect(!(try h.find(.{ .text = "Files" })).checked);
    try h.click(.{ .text = "Save" });
    try std.testing.expectEqual(@as(usize, 1), state.saved);
}

test "a split needs exactly two panes and limits within 0..1" {
    const Bad = struct {
        panes: usize = 1,
        limits: view.Range = .{ .minimum = 0, .maximum = 1 },
        value: f64 = 0.5,
        fn build(self: *@This(), v: *View) anyerror!void {
            _ = try v.split(.column, &self.value, self.limits, .{});
            for (0..self.panes) |_| try v.text("Pane", .{});
            try v.end();
        }
    };
    var storage: view.Storage(8, 64) = .{};
    var state: Bad = .{};
    var h = Harness.init(&state, Bad.build, storage.buffers(), .{});
    try std.testing.expectError(error.InvalidSplit, h.render());
    state.panes = 2;
    state.limits = .{ .minimum = 0, .maximum = 2 };
    try std.testing.expectError(error.InvalidRange, h.render());
    state.limits = .{ .minimum = 0.25, .maximum = 0.75 };
    state.value = 0.9;
    try h.render();
    try std.testing.expectEqual(@as(f64, 0.75), state.value);
}

const Settings = struct {
    range: enum { day, week, month } = .week,
    advanced: bool = false,
    opened: usize = 0,

    fn build(self: *Settings, v: *View) anyerror!void {
        try v.row(.{ .gap = 8, .alignment = .center });
        try v.text("Inbox", .{});
        try v.badge("3", .{});
        try v.end();
        try v.segmented(.{ .name = "Range" });
        _ = try v.segment(@TypeOf(self.range), &self.range, .day, "Day", .{});
        _ = try v.segment(@TypeOf(self.range), &self.range, .week, "Week", .{});
        _ = try v.segment(@TypeOf(self.range), &self.range, .month, "Month", .{});
        try v.end();
        if (try v.disclosure(&self.advanced, "Advanced", .{})) {}
        if (self.advanced) try v.text("Hidden option", .{});
        if (try v.link("Open documentation", .{})) self.opened += 1;
    }
};

test "segments select, disclosures reveal content and links activate" {
    var storage: view.Storage(32, 256) = .{};
    var state: Settings = .{};
    var h = Harness.init(&state, Settings.build, storage.buffers(), .{});
    try h.render();
    const badge = try h.find(.{ .kind = .badge });
    try std.testing.expectEqualStrings("3", badge.text);
    try std.testing.expect(h.at(badge.bounds.x + 2, badge.bounds.y + 2) == null);
    try std.testing.expectError(error.NotActivatable, h.click(.{ .kind = .badge }));

    // Segments sit edge to edge in their row.
    const day = try h.find(.{ .text = "Day" });
    const week = try h.find(.{ .text = "Week" });
    try std.testing.expectEqual(day.bounds.x + day.bounds.width, week.bounds.x);
    try std.testing.expect(week.checked);
    try h.click(.{ .text = "Month" });
    try std.testing.expectEqual(.month, state.range);
    try std.testing.expect(!(try h.find(.{ .text = "Week" })).checked);

    try std.testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Hidden option" }));
    try h.click(.{ .kind = .disclosure });
    try std.testing.expect(state.advanced);
    try std.testing.expectEqual(@as(usize, 1), h.count(.{ .text = "Hidden option" }));
    try std.testing.expect((try h.find(.{ .kind = .disclosure })).checked);

    try h.click(.{ .kind = .link });
    try std.testing.expectEqual(@as(usize, 1), state.opened);
}

const Library = struct {
    open: ?enum { details, reviews } = .details,
    score: u8 = 3,
    used: f64 = 420,
    home: usize = 0,

    fn build(self: *Library, v: *View) anyerror!void {
        try v.breadcrumbs(.{ .name = "Location" });
        if (try v.link("Home", .{})) self.home += 1;
        _ = try v.link("Books", .{});
        try v.text("Dune", .{});
        try v.end();
        try v.meter(self.used, .{ .minimum = 0, .maximum = 512 }, .{ .high = 400 }, .{ .name = "Storage" });
        try v.accordion(.{ .name = "About", .gap = 4 });
        _ = try v.section(@TypeOf(self.open.?), &self.open, .details, "Details", .{});
        if (self.open == .details) try v.text("Published 1965", .{});
        _ = try v.section(@TypeOf(self.open.?), &self.open, .reviews, "Reviews", .{});
        if (self.open == .reviews) _ = try v.rating(&self.score, 5, .{ .name = "Score" });
        try v.end();
    }
};

test "accordions keep one section open; ratings, meters and breadcrumbs report state" {
    var storage: view.Storage(32, 256) = .{};
    var state: Library = .{};
    var h = Harness.init(&state, Library.build, storage.buffers(), .{});
    try h.render();
    const trail = try h.find(.{ .kind = .breadcrumbs });
    const home = try h.find(.{ .text = "Home" });
    const books = try h.find(.{ .text = "Books" });
    try std.testing.expectEqual(trail.id, home.semantic_parent);
    try std.testing.expectEqual(home.bounds.x + home.bounds.width + 16, books.bounds.x);
    try h.click(.{ .text = "Home" });
    try std.testing.expectEqual(@as(usize, 1), state.home);

    const about = try h.find(.{ .kind = .accordion });
    try std.testing.expectEqual(about.id, (try h.find(.{ .text = "Details" })).semantic_parent);
    try std.testing.expect((try h.find(.{ .text = "Details" })).checked);
    try std.testing.expectEqual(@as(usize, 0), h.count(.{ .kind = .rating }));
    // Opening another section closes the open one; opening it again closes it.
    try h.click(.{ .text = "Reviews" });
    try std.testing.expectEqual(.reviews, state.open.?);
    try std.testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Published 1965" }));
    try h.change(.{ .name = "Score" }, .{ .steps = 1 });
    try std.testing.expectEqual(@as(u8, 4), state.score);
    try h.change(.{ .name = "Score" }, .{ .steps = 9 });
    try std.testing.expectEqual(@as(u8, 5), state.score);
    try h.change(.{ .name = "Score" }, .minimum);
    try std.testing.expectEqual(@as(u8, 0), state.score);
    try h.click(.{ .text = "Reviews" });
    try std.testing.expect(state.open == null);

    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try h.write(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "meter name=\"Storage\" 420") != null);
    try std.testing.expectError(error.NotAdjustable, h.change(.{ .kind = .meter }, .maximum));

    var invalid: view.Storage(8, 64) = .{};
    var v = View.init(invalid.buffers());
    v.reset(.{}, null);
    try std.testing.expectError(error.InvalidRange, v.meter(1, .{ .minimum = 0, .maximum = 10 }, .{ .low = 20 }, .{}));
    var score: u8 = 0;
    try std.testing.expectError(error.InvalidRange, v.rating(&score, 11, .{}));
    var section: ?u8 = null;
    try std.testing.expectError(error.NotContainer, v.section(u8, &section, 1, "Loose", .{}));
}

const Signup = struct {
    email: f64 = 0,
    terms: bool = false,
    locked: bool = false,
    submitted: usize = 0,

    fn build(self: *Signup, v: *View) anyerror!void {
        try v.fieldset("Account", .{ .enabled = !self.locked });
        try v.field("Age", .{ .help = "Whole years", .required = true }, .{});
        _ = try v.stepper(&self.email, .{ .minimum = 0, .maximum = 120, .step = 1 }, .{});
        try v.end();
        try v.field("Terms", .{ .@"error" = if (self.terms) null else "Accept to continue" }, .{});
        _ = try v.checkbox(&self.terms, "I accept", .{});
        try v.end();
        try v.end();
        if (try v.button("Submit", .{ .enabled = self.terms })) self.submitted += 1;
    }
};

test "fields label, describe and validate their controls; fieldsets disable theirs" {
    var storage: view.Storage(32, 256) = .{};
    var state: Signup = .{};
    var h = Harness.init(&state, Signup.build, storage.buffers(), .{});
    try h.render();
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try h.write(&writer);
    const outline = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, outline, "text \"Age *\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, outline, "note \"Whole years\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, outline, "note \"Accept to continue\" invalid") != null);

    // The label sits above the control and the note below it.
    const label = try h.find(.{ .text = "Age *" });
    const age = try h.find(.{ .kind = .stepper });
    const hint = try h.find(.{ .text = "Whole years" });
    try std.testing.expect(label.bounds.y + label.bounds.height <= age.bounds.y);
    try std.testing.expect(age.bounds.y + age.bounds.height <= hint.bounds.y);
    const set = try h.find(.{ .kind = .fieldset });
    try std.testing.expectEqual(set.id, age.semantic_parent);
    try std.testing.expectEqual(@as(usize, 1), h.count(.{ .kind = .text, .text = "Account" }));

    try h.click(.{ .text = "I accept" });
    try std.testing.expectEqual(@as(usize, 0), h.count(.{ .kind = .note, .text = "Accept to continue" }));
    try h.click(.{ .text = "Submit" });
    try std.testing.expectEqual(@as(usize, 1), state.submitted);

    // A disabled fieldset disables everything inside it.
    state.locked = true;
    try h.render();
    try std.testing.expectError(error.Disabled, h.click(.{ .text = "I accept" }));
    try std.testing.expectError(error.Disabled, h.change(.{ .kind = .stepper }, .{ .steps = 1 }));
    try h.click(.{ .text = "Submit" });
    try std.testing.expectEqual(@as(usize, 2), state.submitted);

    var small: view.Storage(8, 64) = .{};
    var v = View.init(small.buffers());
    v.reset(.{}, null);
    try v.field("Empty", .{}, .{});
    try std.testing.expectError(error.InvalidField, v.end());
}

const Fonts = struct {
    names: [6][]const u8 = .{ "Serif", "Sans", "Mono", "Display", "Hand", "Symbol" },
    chosen: usize = 0,
    list: view.ScrollModel = .{},

    fn build(self: *Fonts, v: *View) anyerror!void {
        try v.scroll(&self.list, .{ .height = 100, .self_align = .stretch });
        try v.listBox(.{ .name = "Fonts" });
        for (self.names, 0..) |name, i| _ = try v.listItem(usize, &self.chosen, i, name, .{ .key = i, .height = 30 });
        try v.end();
        try v.end();
    }
};

test "list boxes select one option and reveal it inside a scroll container" {
    var storage: view.Storage(16, 128) = .{};
    var state: Fonts = .{};
    var h = Harness.init(&state, Fonts.build, storage.buffers(), .{});
    try h.render();
    const list = try h.find(.{ .kind = .list_box });
    const serif = try h.find(.{ .text = "Serif" });
    try std.testing.expect(serif.checked);
    try std.testing.expectEqual(list.id, serif.radio_group.?);
    try std.testing.expectEqual(list.bounds.width, serif.bounds.width);
    try std.testing.expectError(error.Hidden, h.click(.{ .text = "Hand" }));

    // "Display" is cut off at the bottom; selecting it scrolls it fully in.
    const area = try h.find(.{ .kind = .scroll });
    const display = try h.find(.{ .text = "Display" });
    try std.testing.expect(display.bounds.y + display.bounds.height > area.bounds.y + area.bounds.height);
    try h.click(.{ .text = "Display" });
    try std.testing.expectEqual(@as(usize, 3), state.chosen);
    try std.testing.expectEqual(@as(f32, 20), state.list.offset.y);
    const shown = try h.find(.{ .text = "Display" });
    try std.testing.expect(shown.checked and !(try h.find(.{ .text = "Serif" })).checked);
    try std.testing.expectEqual(area.bounds.y + area.bounds.height, shown.bounds.y + shown.bounds.height);
    // Selecting the selected option changes nothing and does not scroll.
    state.list.offset.y = 0;
    try h.render();
    try h.click(.{ .text = "Sans" });
    try h.click(.{ .text = "Sans" });
    try std.testing.expectEqual(@as(f32, 0), state.list.offset.y);

    var loose: view.Storage(4, 32) = .{};
    var v = View.init(loose.buffers());
    v.reset(.{}, null);
    var chosen: u8 = 0;
    try std.testing.expectError(error.NotContainer, v.listItem(u8, &chosen, 1, "x", .{}));
}

const Windowless = struct {
    fn draw(_: *anyopaque, _: *ui.Frame) void {}
    fn action(_: *anyopaque, _: u64) void {}
};

test "keys replay Tab order, group arrows, range keys and activation" {
    var storage: view.Storage(32, 512) = .{};
    var state: Todo = .{};
    var h = Harness.init(&state, Todo.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try std.testing.expectError(error.NoInput, h.key(.{ .key = .tab }));
    try h.attachInput(&context);
    try std.testing.expect(h.focused() == null);

    try std.testing.expect(try h.key(.{ .key = .tab }));
    try std.testing.expectEqualStrings("All", h.focused().?.text);
    try std.testing.expect(try h.key(.{ .key = .tab }));
    try std.testing.expectEqualStrings("Write", h.focused().?.text);
    try std.testing.expect(try h.key(.{ .key = .space }));
    try std.testing.expect(state.done[0]);
    try std.testing.expect(try h.key(.{ .key = .space, .repeat = true }));
    try std.testing.expect(state.done[0]);

    // The radio group is one tab stop; arrows move the selection inside it.
    try std.testing.expect(try h.key(.{ .key = .tab, .modifiers = .{ .shift = true } }));
    try std.testing.expectEqualStrings("All", h.focused().?.text);
    try std.testing.expect(try h.key(.{ .key = .right }));
    try std.testing.expectEqual(.open, state.filter);
    try std.testing.expectEqualStrings("Open", h.focused().?.text);
    try std.testing.expect(try h.key(.{ .key = .tab }));
    try std.testing.expectEqualStrings("Test", h.focused().?.text);

    // End reaches the last enabled stop: Clear is enabled once a task is done.
    try std.testing.expect(try h.key(.{ .key = .end }));
    try std.testing.expectEqualStrings("Clear", h.focused().?.text);
    try std.testing.expect(try h.key(.{ .key = .enter }));
    try std.testing.expectEqual(@as(usize, 1), state.cleared);

    try std.testing.expect(try h.key(.{ .key = .tab, .modifiers = .{ .shift = true } }));
    try std.testing.expectEqual(Kind.slider, h.focused().?.kind);
    try std.testing.expect(try h.key(.{ .key = .right }));
    try std.testing.expectEqual(@as(f64, 1.5), state.zoom);
    try std.testing.expect(!try h.key(.{ .key = .a, .modifiers = .{ .control = true } }));
}

test "arrow keys move a list box selection and reveal it" {
    var storage: view.Storage(16, 128) = .{};
    var state: Fonts = .{};
    var h = Harness.init(&state, Fonts.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try std.testing.expect(try h.key(.{ .key = .tab }));
    try std.testing.expectEqualStrings("Serif", h.focused().?.text);
    for (0..3) |_| try std.testing.expect(try h.key(.{ .key = .down }));
    try std.testing.expectEqual(@as(usize, 3), state.chosen);
    try std.testing.expectEqualStrings("Display", h.focused().?.text);
    try std.testing.expectEqual(@as(f32, 20), state.list.offset.y);
}

const Hints = struct {
    saved: usize = 0,
    fn build(self: *Hints, v: *View) anyerror!void {
        try v.row(.{ .gap = 8 });
        if (try v.button("Save", .{})) self.saved += 1;
        try v.tooltip("Save the document");
        _ = try v.button("Open", .{});
        try v.end();
    }
};

test "tooltips appear after the hover delay and hide on press, Escape or leaving" {
    var storage: view.Storage(16, 256) = .{};
    var state: Hints = .{};
    var h = Harness.init(&state, Hints.build, storage.buffers(), .{ .options = .{ .tooltip_delay = 100 } });
    try h.render();
    try std.testing.expectEqual(@as(?u64, null), h.deadline());
    try h.hover(.{ .text = "Save" });
    try std.testing.expect(h.tooltip() == null);
    try std.testing.expectEqual(@as(?u64, 100), h.deadline());
    try h.advance(99);
    try std.testing.expect(h.tooltip() == null);
    try h.advance(1);
    try std.testing.expectEqualStrings("Save the document", h.tooltip().?);
    try std.testing.expectEqual(@as(?u64, null), h.deadline());
    // The tooltip sits below its control and stays inside the window.
    const save = try h.find(.{ .text = "Save" });
    try std.testing.expect(h.view.tip_rect.y >= save.bounds.y + save.bounds.height);
    try std.testing.expect(h.view.tip_rect.x >= 0 and h.view.tip_rect.x + h.view.tip_rect.width <= 640);

    try h.leave();
    try std.testing.expect(h.tooltip() == null);

    // A press hides it for as long as the same control keeps it.
    try h.hover(.{ .text = "Save" });
    try h.clickAt(save.bounds.x + 4, save.bounds.y + 4);
    try std.testing.expectEqual(@as(usize, 1), state.saved);
    try h.advance(1000);
    try std.testing.expect(h.tooltip() == null);
    try std.testing.expectEqual(@as(?u64, null), h.deadline());

    // Keyboard focus shows it too, and Escape hides it.
    var keyboard_storage: view.Storage(16, 256) = .{};
    h = Harness.init(&state, Hints.build, keyboard_storage.buffers(), .{ .options = .{ .tooltip_delay = 100 } });
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    _ = try h.key(.{ .key = .tab });
    try std.testing.expectEqualStrings("Save", h.focused().?.text);
    try h.advance(100);
    try std.testing.expect(h.tooltip() != null);
    try std.testing.expect(try h.key(.{ .key = .escape }));
    try std.testing.expect(h.tooltip() == null);
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try h.write(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "button \"Save\" tooltip=\"Save the document\"") != null);

    var empty: view.Storage(4, 32) = .{};
    var v = View.init(empty.buffers());
    v.reset(.{}, null);
    try std.testing.expectError(error.NotContainer, v.tooltip("Nothing to describe"));
}

const Notices = struct {
    queue: view.Toasts(3) = .{},
    undone: usize = 0,
    fn build(self: *Notices, v: *View) anyerror!void {
        if (try v.button("Delete", .{})) _ = try self.queue.show("Deleted 3 files", .{ .action = "Undo", .duration = 1000 });
        if (try v.toasts(&self.queue, .{})) |_| self.undone += 1;
    }
};

test "toasts stack over the bottom edge, expire, act and dismiss" {
    var storage: view.Storage(32, 512) = .{};
    var state: Notices = .{};
    var h = Harness.init(&state, Notices.build, storage.buffers(), .{});
    try h.render();
    try std.testing.expectEqual(@as(usize, 0), h.count(.{ .kind = .toast }));
    try h.click(.{ .text = "Delete" });
    try std.testing.expectEqual(@as(usize, 1), h.count(.{ .kind = .toast }));
    const toast = try h.find(.{ .kind = .toast });
    try std.testing.expectEqualStrings("Deleted 3 files", toast.text);
    try std.testing.expectApproxEqAbs(@as(f32, 480 - view.toast_margin), toast.bounds.y + toast.bounds.height, 0.01);
    try std.testing.expectEqual(@as(?u64, 1000), h.deadline());
    // Shown time counts from the first pass that showed the message.
    try h.advance(999);
    try std.testing.expectEqual(@as(usize, 1), h.count(.{ .kind = .toast }));
    try h.advance(1);
    try std.testing.expectEqual(@as(usize, 0), h.count(.{ .kind = .toast }));
    try std.testing.expectEqual(@as(?u64, null), h.deadline());

    try h.click(.{ .text = "Delete" });
    try h.click(.{ .text = "Undo" });
    try std.testing.expectEqual(@as(usize, 1), state.undone);
    try std.testing.expectEqual(@as(usize, 0), state.queue.len);
    try h.click(.{ .text = "Delete" });
    try h.click(.{ .name = "Dismiss" });
    try std.testing.expectEqual(@as(usize, 1), state.undone);
    try std.testing.expectEqual(@as(usize, 0), h.count(.{ .kind = .toast }));

    // A full queue drops its oldest message.
    for (0..4) |_| try h.click(.{ .text = "Delete" });
    try std.testing.expectEqual(@as(usize, 3), state.queue.len);
    try std.testing.expectEqual(@as(u64, 5), state.queue.items()[0].id);
    try std.testing.expect(state.queue.dismiss(5));
    try std.testing.expect(!state.queue.dismiss(5));
    try std.testing.expectError(error.TextTooLong, state.queue.show("x" ** (view.max_toast_message + 1), .{}));
    var persistent: view.Toasts(1) = .{};
    _ = try persistent.show("Offline", .{ .duration = 0 });
    try std.testing.expectEqual(@as(u64, 0), persistent.items()[0].duration);
}

const Picker = struct {
    names: [4][]const u8 = .{ "Serif", "Sans", "Mono", "Display" },
    font: usize = 1,
    changes: usize = 0,
    at_bottom: bool = false,
    fn build(self: *Picker, v: *View) anyerror!void {
        if (self.at_bottom) try v.spacer(.{});
        try v.comboBox(self.names[self.font], .{ .name = "Font", .width = 160 });
        for (self.names, 0..) |name, i| if (try v.comboOption(usize, &self.font, i, name, .{ .key = i })) {
            self.changes += 1;
        };
        try v.end();
        try v.tooltip("Typeface");
        _ = try v.button("Apply", .{});
    }
};

test "combo boxes open a list, move a highlight and restore focus when closed" {
    var storage: view.Storage(32, 256) = .{};
    var state: Picker = .{};
    var h = Harness.init(&state, Picker.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    const combo = try h.find(.{ .kind = .combo_box });
    try std.testing.expectEqualStrings("Sans", combo.text);
    try std.testing.expectEqualStrings("Typeface", combo.tooltip);
    try std.testing.expect(!combo.checked);
    try std.testing.expectError(error.Hidden, h.click(.{ .text = "Mono" }));

    // Activation opens the list below the field over the button; the
    // chosen option starts highlighted.
    try h.click(.{ .kind = .combo_box });
    try std.testing.expect((try h.find(.{ .kind = .combo_box })).checked);
    const list = try h.find(.{ .kind = .popup });
    const field = try h.find(.{ .kind = .combo_box });
    try std.testing.expect(list.checked);
    try std.testing.expectEqual(field.bounds.y + field.bounds.height + view.popup_gap, list.bounds.y);
    try std.testing.expect(list.bounds.width >= field.bounds.width);
    try std.testing.expect((try h.find(.{ .text = "Sans", .kind = .list_item })).highlighted);
    const apply = try h.find(.{ .text = "Apply" });
    // The list covers the button below it.
    try std.testing.expectEqual(Kind.list_item, h.at(apply.bounds.x + 4, apply.bounds.y + 4).?.kind);

    // Arrows move the highlight without choosing; Enter picks it and the
    // list closes with focus on the combo box.
    try std.testing.expect(try h.key(.{ .key = .down }));
    try std.testing.expect((try h.find(.{ .text = "Mono" })).highlighted);
    try std.testing.expectEqual(@as(usize, 1), state.font);
    try std.testing.expect(try h.key(.{ .key = .end }));
    try std.testing.expect(try h.key(.{ .key = .down }));
    try std.testing.expect((try h.find(.{ .text = "Serif" })).highlighted);
    try std.testing.expect(try h.key(.{ .key = .enter }));
    try std.testing.expectEqual(@as(usize, 0), state.font);
    try std.testing.expectEqual(@as(usize, 1), state.changes);
    try std.testing.expect(!(try h.find(.{ .kind = .popup })).checked);
    try std.testing.expectEqual(Kind.combo_box, h.focused().?.kind);

    // Down opens a focused, closed combo box; Escape closes it unchanged.
    try std.testing.expect(try h.key(.{ .key = .down }));
    try std.testing.expect((try h.find(.{ .kind = .popup })).checked);
    try std.testing.expect(try h.key(.{ .key = .escape }));
    try std.testing.expect(!(try h.find(.{ .kind = .popup })).checked);
    try std.testing.expectEqual(@as(usize, 0), state.font);

    // Clicking an option picks it and returns focus to the combo box.
    try h.click(.{ .kind = .combo_box });
    try h.click(.{ .text = "Display" });
    try std.testing.expectEqual(@as(usize, 3), state.font);
    try std.testing.expectEqual(Kind.combo_box, h.focused().?.kind);
    try std.testing.expectEqualStrings("Display", (try h.find(.{ .kind = .combo_box })).text);

    // A press outside the list closes it and is consumed.
    try h.click(.{ .kind = .combo_box });
    try h.clickAt(600, 400);
    try std.testing.expect(!(try h.find(.{ .kind = .popup })).checked);

    // Near the bottom edge the list opens above the field.
    state.at_bottom = true;
    try h.render();
    try h.click(.{ .kind = .combo_box });
    const above = try h.find(.{ .kind = .popup });
    const bottom_field = try h.find(.{ .kind = .combo_box });
    try std.testing.expectEqual(bottom_field.bounds.y - view.popup_gap, above.bounds.y + above.bounds.height);
    try std.testing.expect(above.bounds.y >= 0);
    // Tab closes it and moves on from the combo box.
    try std.testing.expect(try h.key(.{ .key = .tab }));
    try std.testing.expect(!(try h.find(.{ .kind = .popup })).checked);
    try std.testing.expectEqualStrings("Apply", h.focused().?.text);

    var loose: view.Storage(4, 32) = .{};
    var v = View.init(loose.buffers());
    v.reset(.{}, null);
    var chosen: u8 = 0;
    try std.testing.expectError(error.NotContainer, v.comboOption(u8, &chosen, 1, "x", .{}));
    try std.testing.expectError(error.NotContainer, v.suggestions(.{}));
}

const Cities = struct {
    all: [5][]const u8 = .{ "Berlin", "Bern", "Bergen", "Boston", "Lima" },
    query: []const u8 = "Ber",
    picked: ?[]const u8 = null,
    fn build(self: *Cities, v: *View) anyerror!void {
        // A focusable control stands in for the text field an application
        // would embed.
        _ = try v.button(self.query, .{ .key = 1 });
        try v.suggestions(.{ .name = "Cities" });
        for (self.all) |city| if (std.mem.startsWith(u8, city, self.query)) {
            if (try v.suggestion(city, .{ .key = view.key(city) })) {
                self.picked = city;
                self.query = city;
            }
        };
        try v.end();
        _ = try v.button("Go", .{});
    }
};

test "suggestions follow focus, highlight without moving it and stay closed after a pick" {
    var storage: view.Storage(32, 256) = .{};
    var state: Cities = .{};
    var h = Harness.init(&state, Cities.build, storage.buffers(), .{});
    try h.render();
    try std.testing.expect(!(try h.find(.{ .kind = .popup })).checked);
    try h.focus(.{ .key = 1 });
    const list = try h.find(.{ .kind = .popup });
    try std.testing.expect(list.checked);
    try std.testing.expectEqual(@as(usize, 3), h.count(.{ .kind = .list_item }));
    try std.testing.expect(h.visible(try h.find(.{ .text = "Bergen" })) != null);

    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    const input_id = (try h.find(.{ .key = 1 })).id;
    try h.attachInput(&context);
    context.input_state.setFocused(input_id);
    try h.render();
    // Down highlights the first suggestion; focus stays on the input.
    try std.testing.expect(try h.key(.{ .key = .down }));
    try std.testing.expect((try h.find(.{ .text = "Berlin" })).highlighted);
    try std.testing.expect((try h.find(.{ .text = "Berlin" })).checked);
    try std.testing.expectEqual(input_id, h.focused().?.id);
    try std.testing.expect(try h.key(.{ .key = .up }));
    try std.testing.expect((try h.find(.{ .text = "Bergen" })).highlighted);
    try std.testing.expect(try h.key(.{ .key = .enter }));
    try std.testing.expectEqualStrings("Bergen", state.picked.?);
    // The pick closes the list over the labels it produced.
    try std.testing.expect(!(try h.find(.{ .kind = .popup })).checked);
    try h.render();
    try std.testing.expect(!(try h.find(.{ .kind = .popup })).checked);
    try std.testing.expectEqual(input_id, h.focused().?.id);

    // Typing changes the labels and reopens it; Escape closes it until then.
    state.query = "B";
    try h.render();
    try std.testing.expect((try h.find(.{ .kind = .popup })).checked);
    try std.testing.expect(try h.key(.{ .key = .escape }));
    try std.testing.expect(!(try h.find(.{ .kind = .popup })).checked);
    // Down reopens it.
    try std.testing.expect(try h.key(.{ .key = .down }));
    try std.testing.expect((try h.find(.{ .kind = .popup })).checked);
    // A pointer pick returns focus to the input.
    try h.click(.{ .text = "Boston" });
    try std.testing.expectEqualStrings("Boston", state.query);
    try std.testing.expectEqual(input_id, h.focused().?.id);
    // Focus elsewhere closes it.
    state.query = "Be";
    context.input_state.setFocused((try h.find(.{ .text = "Go" })).id);
    try h.render();
    try std.testing.expect(!(try h.find(.{ .kind = .popup })).checked);
}

const Profile = struct {
    page: usize = 1,
    fn build(self: *Profile, v: *View) anyerror!void {
        try v.row(.{ .gap = 8, .alignment = .center });
        if (try v.navButton(.back, .{ .enabled = self.page > 0 })) self.page -= 1;
        if (try v.navButton(.forward, .{ .name = "Next page" })) self.page += 1;
        try v.avatar("Ada Lovelace", null, .{});
        try v.avatar("Grace Hopper", null, .{ .width = 48, .height = 48, .background = 0x2e7d4f });
        try v.end();
        try v.search(.{ .name = "Find" });
        try v.text("query", .{ .grow = 1 });
        _ = try v.button("Clear", .{});
        try v.end();
    }
};

test "navigation buttons step pages, avatars and search regions describe themselves" {
    var storage: view.Storage(16, 256) = .{};
    var state: Profile = .{};
    var h = Harness.init(&state, Profile.build, storage.buffers(), .{});
    try h.render();
    try h.click(.{ .text = "Back" });
    try std.testing.expectEqual(@as(usize, 0), state.page);
    try std.testing.expectError(error.Disabled, h.click(.{ .text = "Back" }));
    try h.click(.{ .text = "Next page" });
    try std.testing.expectEqual(@as(usize, 1), state.page);
    const back = try h.find(.{ .text = "Back" });
    try std.testing.expectEqual(back.bounds.width, back.bounds.height);
    const ada = try h.find(.{ .text = "Ada Lovelace" });
    try std.testing.expectEqual(@as(f32, 32), ada.bounds.width);
    try std.testing.expectEqual(@as(f32, 48), (try h.find(.{ .text = "Grace Hopper" })).bounds.height);
    try std.testing.expectError(error.NotActivatable, h.click(.{ .text = "Ada Lovelace" }));
    const region = try h.find(.{ .kind = .search });
    try std.testing.expectEqual(region.id, (try h.find(.{ .text = "Clear" })).semantic_parent);
    try std.testing.expectEqual(@as(f32, 8), (try h.find(.{ .text = "Clear" })).bounds.x - ((try h.find(.{ .text = "query" })).bounds.x + (try h.find(.{ .text = "query" })).bounds.width));
}

const LongPicker = struct {
    size: usize = 0,
    list: view.ScrollModel = .{},
    fn build(self: *LongPicker, v: *View) anyerror!void {
        var labels: [12][8]u8 = undefined;
        try v.comboBox(try std.fmt.bufPrint(&labels[self.size], "{d} pt", .{8 + self.size}), .{ .name = "Size" });
        try v.scroll(&self.list, .{ .height = 120, .self_align = .stretch });
        for (&labels, 0..) |*label, i| _ = try v.comboOption(usize, &self.size, i, try std.fmt.bufPrint(label, "{d} pt", .{8 + i}), .{ .key = i + 1 });
        try v.end();
        try v.end();
    }
};

test "a scroll inside a combo box list keeps the highlight in view" {
    var storage: view.Storage(32, 512) = .{};
    var state: LongPicker = .{};
    var h = Harness.init(&state, LongPicker.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.click(.{ .kind = .combo_box });
    try std.testing.expect((try h.find(.{ .kind = .popup })).checked);
    // A press in the window padding, outside the list, closes it.
    try h.clickAt(1, 1);
    try std.testing.expect(!(try h.find(.{ .kind = .popup })).checked);
    try h.click(.{ .kind = .combo_box });
    try std.testing.expect(h.visible(try h.find(.{ .key = 12 })) == null);
    try std.testing.expect(try h.key(.{ .key = .end }));
    try std.testing.expect((try h.find(.{ .key = 12 })).highlighted);
    try std.testing.expect(h.visible(try h.find(.{ .key = 12 })) != null);
    try std.testing.expect(state.list.offset.y > 0);
    try std.testing.expect(try h.key(.{ .key = .enter }));
    try std.testing.expectEqual(@as(usize, 11), state.size);
    try std.testing.expectEqualStrings("19 pt", (try h.find(.{ .kind = .combo_box })).text);
}

/// A focusable stand-in for an embedded text input that reports
/// composition and emptiness like a text field.
const FakeInput = struct {
    composing: bool = false,
    text: []const u8 = "",
    fn measure(_: *anyopaque, _: view.Theme) view.layout.Measurement {
        return .{ .minimum = .{ .width = 40, .height = 32 }, .preferred = .{ .width = 120, .height = 32 } };
    }
    fn paint(_: *anyopaque, frame: *ui.Frame, id: u64, bounds: Rect) anyerror!void {
        try frame.addControl(id, bounds, .{});
    }
    fn status(ptr: *anyopaque) view.EmbedStatus {
        const self: *FakeInput = @ptrCast(@alignCast(ptr));
        return .{ .composing = self.composing, .empty = self.text.len == 0 };
    }
    fn embed(self: *FakeInput) view.Embed {
        return .{ .context = self, .measure = measure, .paint = paint, .status = status };
    }
};

const Files = struct {
    const Entry = struct { id: u64, name: []const u8, parent: ?u64 };
    entries: []const Entry = &.{
        .{ .id = 10, .name = "src", .parent = null },
        .{ .id = 11, .name = "main.zig", .parent = 10 },
        .{ .id = 12, .name = "view", .parent = 10 },
        .{ .id = 13, .name = "root.zig", .parent = 12 },
        .{ .id = 20, .name = "docs", .parent = null },
        .{ .id = 30, .name = "README.md", .parent = null },
    },
    open: [64]bool = @splat(false),
    storage: [8]u64 = undefined,
    selection: view.Selection = undefined,
    activated: ?u64 = null,
    fn branch(self: *const Files, id: u64) bool {
        for (self.entries) |entry| if (entry.parent == id) return true;
        return false;
    }
    fn level(self: *Files, v: *View, parent: ?u64) anyerror!void {
        for (self.entries) |entry| if (std.meta.eql(entry.parent, parent)) {
            const expanded: ?*bool = if (self.branch(entry.id)) &self.open[entry.id] else null;
            if (try v.treeItem(entry.id, expanded, entry.name, .{})) self.activated = entry.id;
            if (expanded) |flag| if (flag.*) try self.level(v, entry.id);
            try v.end();
        };
    }
    fn build(self: *Files, v: *View) anyerror!void {
        try v.tree(&self.selection, .{ .name = "Files" });
        try self.level(v, null);
        try v.end();
        _ = try v.button("Done", .{});
    }
};

test "trees expand, select by stable id and move with the keyboard" {
    var storage: view.Storage(64, 1024) = .{};
    var state: Files = .{};
    state.selection = .init(.single, &state.storage);
    var h = Harness.init(&state, Files.build, storage.buffers(), .{});
    try h.render();
    try std.testing.expectEqual(@as(usize, 3), h.count(.{ .kind = .tree_row }));
    try h.click(.{ .text = "docs" });
    try std.testing.expectEqualSlices(u64, &.{20}, state.selection.items());
    try std.testing.expectEqual(@as(?u64, 20), state.selection.cursor);
    // The triangle expands without selecting.
    try h.toggleExpanded(.{ .text = "src" });
    try std.testing.expect(state.open[10]);
    try std.testing.expectEqual(@as(usize, 5), h.count(.{ .kind = .tree_row }));
    try std.testing.expectEqualSlices(u64, &.{20}, state.selection.items());
    const child = try h.find(.{ .text = "main.zig" });
    try std.testing.expectEqual(@as(u16, 1), child.level);
    try std.testing.expect(child.bounds.y > (try h.find(.{ .text = "src" })).bounds.y);
    // A disabled id-less query is stale once the row is gone.
    try h.toggleExpanded(.{ .text = "src" });
    try std.testing.expect(!state.open[10]);

    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    // Tab lands on the cursor row.
    try std.testing.expect(try h.key(.{ .key = .tab }));
    try std.testing.expectEqualStrings("docs", h.focused().?.text);
    try std.testing.expect(try h.key(.{ .key = .up }));
    try std.testing.expectEqualSlices(u64, &.{10}, state.selection.items());
    try std.testing.expectEqualStrings("src", h.focused().?.text);
    // Right expands, Right again enters the first child, Left returns to
    // the parent and Left again collapses it.
    try std.testing.expect(try h.key(.{ .key = .right }));
    try std.testing.expect(state.open[10]);
    try std.testing.expect(try h.key(.{ .key = .right }));
    try std.testing.expectEqualStrings("main.zig", h.focused().?.text);
    try std.testing.expect(try h.key(.{ .key = .down }));
    try std.testing.expect(try h.key(.{ .key = .right }));
    try std.testing.expect(state.open[12]);
    try std.testing.expect(try h.key(.{ .key = .end }));
    try std.testing.expectEqualStrings("README.md", h.focused().?.text);
    try std.testing.expect(try h.key(.{ .key = .home }));
    try std.testing.expectEqualStrings("src", h.focused().?.text);
    try std.testing.expect(try h.key(.{ .key = .down }));
    try std.testing.expect(try h.key(.{ .key = .down }));
    try std.testing.expect(try h.key(.{ .key = .left }));
    try std.testing.expect(!state.open[12]);
    try std.testing.expect(try h.key(.{ .key = .left }));
    try std.testing.expectEqualStrings("src", h.focused().?.text);
    try std.testing.expect(try h.key(.{ .key = .enter }));
    try std.testing.expectEqual(@as(?u64, 10), state.activated);
    // The selection follows the item id when labels and order change.
    state.entries = &.{
        .{ .id = 30, .name = "README.md", .parent = null },
        .{ .id = 10, .name = "source", .parent = null },
    };
    try h.render();
    try std.testing.expect((try h.find(.{ .text = "source" })).checked);
    try std.testing.expect(!(try h.find(.{ .text = "README.md" })).checked);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try h.write(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "tree_row \"source\" level=0 selected cursor") != null);
}

const Inventory = struct {
    const Item = struct { id: u64, name: []const u8, count: u32 };
    items: [5]Item = .{
        .{ .id = 1, .name = "Bolts", .count = 40 },
        .{ .id = 2, .name = "Nuts", .count = 12 },
        .{ .id = 3, .name = "Washers", .count = 90 },
        .{ .id = 4, .name = "Screws", .count = 7 },
        .{ .id = 5, .name = "Rivets", .count = 55 },
    },
    sort: ?view.Sort = null,
    storage: [8]u64 = undefined,
    selection: view.Selection = undefined,
    scroll: view.ScrollModel = .{},
    sorts: usize = 0,
    fn lessName(_: void, a: Item, b: Item) bool {
        return std.mem.lessThan(u8, a.name, b.name);
    }
    fn lessCount(_: void, a: Item, b: Item) bool {
        return a.count < b.count;
    }
    fn build(self: *Inventory, v: *View) anyerror!void {
        const columns = [_]view.Column{ .{ .title = "Name", .track = view.Track.fraction(2) }, .{ .title = "Count" }, .{ .title = "Note", .sortable = false } };
        if (try v.table(&columns, &self.sort, &self.selection, .{ .name = "Parts", .self_align = .stretch })) {
            self.sorts += 1;
            const current = self.sort.?;
            if (current.column == 0) std.mem.sort(Item, &self.items, {}, lessName) else std.mem.sort(Item, &self.items, {}, lessCount);
            if (current.direction == .descending) std.mem.reverse(Item, &self.items);
        }
        try v.scroll(&self.scroll, .{ .height = 90 });
        for (self.items) |entry| {
            _ = try v.tableRow(entry.id, entry.name, .{});
            try v.text(entry.name, .{});
            try v.textf("{d}", .{entry.count}, .{});
            try v.text("", .{});
            try v.end();
        }
        try v.end();
        try v.end();
    }
};

test "tables sort from headers and select several rows by stable id" {
    var storage: view.Storage(64, 1024) = .{};
    var state: Inventory = .{};
    state.selection = .init(.multiple, &state.storage);
    var h = Harness.init(&state, Inventory.build, storage.buffers(), .{});
    try h.render();
    // Header columns line up with the row cells.
    const header = try h.find(.{ .text = "Count", .kind = .column_header });
    const cell = try h.find(.{ .text = "40" });
    try std.testing.expectApproxEqAbs(header.bounds.x, cell.bounds.x, 0.01);
    try h.click(.{ .text = "Count", .kind = .column_header });
    try std.testing.expectEqual(@as(?view.Sort, .{ .column = 1 }), state.sort);
    try std.testing.expectEqualStrings("Screws", state.items[0].name);
    try h.click(.{ .text = "Count", .kind = .column_header });
    try std.testing.expectEqual(SortDirection.descending, state.sort.?.direction);
    try std.testing.expectEqual(SortDirection.descending, (try h.find(.{ .text = "Count", .kind = .column_header })).sort.?);
    try std.testing.expectEqual(@as(?SortDirection, null), (try h.find(.{ .text = "Name", .kind = .column_header })).sort);
    // A column that does not sort ignores activation.
    try h.click(.{ .text = "Note", .kind = .column_header });
    try std.testing.expectEqual(@as(usize, 2), state.sorts);

    try h.click(.{ .kind = .table_row, .text = "Washers" });
    try h.clickWith(.{ .kind = .table_row, .text = "Bolts" }, .{ .control = true });
    try std.testing.expectEqualSlices(u64, &.{ 3, 1 }, state.selection.items());
    // Shift selects from the anchor through the visible order, and
    // Ctrl+Shift adds such a range to the selection.
    try h.clickWith(.{ .kind = .table_row, .text = "Rivets" }, .{ .shift = true });
    try std.testing.expectEqual(@as(usize, 2), state.selection.len);
    for ([_]u64{ 1, 5 }) |id| try std.testing.expect(state.selection.contains(id));
    try h.clickWith(.{ .kind = .table_row, .text = "Washers" }, .{ .shift = true, .control = true });
    try std.testing.expectEqual(@as(usize, 3), state.selection.len);
    for ([_]u64{ 1, 3, 5 }) |id| try std.testing.expect(state.selection.contains(id));
    // Cells of a selected row are drawn on the accent.
    try std.testing.expect((try h.find(.{ .kind = .table_row, .text = "Rivets" })).checked);
    // Sorting keeps the selection, which names items, not positions.
    try h.click(.{ .text = "Name", .kind = .column_header });
    try std.testing.expectEqualStrings("Bolts", state.items[0].name);
    try std.testing.expectEqual(@as(usize, 3), state.selection.len);

    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    context.input_state.setFocused((try h.find(.{ .kind = .table_row, .text = "Bolts" })).id);
    try h.render();
    // Ctrl moves the cursor alone, Ctrl+Space toggles, Space selects only.
    try std.testing.expect(try h.key(.{ .key = .down, .modifiers = .{ .control = true } }));
    try std.testing.expectEqualStrings("Nuts", h.focused().?.text);
    try std.testing.expect(!state.selection.contains(2));
    try std.testing.expect(try h.key(.{ .key = .space, .modifiers = .{ .control = true } }));
    try std.testing.expect(state.selection.contains(2));
    try std.testing.expect(try h.key(.{ .key = .space }));
    try std.testing.expectEqualSlices(u64, &.{2}, state.selection.items());
    try std.testing.expect(try h.key(.{ .key = .down, .modifiers = .{ .shift = true } }));
    try std.testing.expectEqual(@as(usize, 2), state.selection.len);
    try std.testing.expect(try h.key(.{ .key = .a, .modifiers = .{ .control = true } }));
    try std.testing.expectEqual(@as(usize, 5), state.selection.len);
    // Moving to the last row scrolls it into view.
    try std.testing.expect(try h.key(.{ .key = .end }));
    try std.testing.expectEqualStrings("Washers", h.focused().?.text);
    try std.testing.expect(state.scroll.offset.y > 0);
    try std.testing.expect(h.visible(try h.find(.{ .kind = .table_row, .text = "Washers" })) != null);
    try std.testing.expect(try h.key(.{ .key = .page_up }));
    try std.testing.expectEqualSlices(u64, &.{h.focused().?.item}, state.selection.items());
    // Rows scrolled out of sight record no controls, except the cursor.
    try std.testing.expect(context.input_state.len < 3 + 5);
}

const FontPicker = struct {
    all: [4][]const u8 = .{ "Serif", "Sans", "Mono", "Script" },
    input: FakeInput = .{ .text = "S" },
    picked: ?[]const u8 = null,
    fn build(self: *FontPicker, v: *View) anyerror!void {
        try v.editableComboBox(self.input.text, .{ .name = "Font" });
        try v.embed(self.input.embed(), .{ .grow = 1, .key = 1 });
        try v.end();
        try v.suggestions(.{});
        for (self.all) |font| if (std.mem.startsWith(u8, font, self.input.text)) {
            if (try v.suggestion(font, .{ .key = view.key(font) })) {
                self.picked = font;
                self.input.text = font;
            }
        };
        try v.end();
        _ = try v.button("Apply", .{});
    }
};

test "editable combo boxes open on typing, the button or Down and wait for composition" {
    var storage: view.Storage(32, 256) = .{};
    var state: FontPicker = .{};
    var h = Harness.init(&state, FontPicker.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    const input_id = (try h.find(.{ .key = 1 })).id;
    context.input_state.setFocused(input_id);
    try h.render();
    // Gaining focus leaves the list closed.
    try std.testing.expect(!(try h.find(.{ .kind = .popup })).checked);
    // Typing that changes the options opens it.
    state.input.text = "Se";
    try h.render();
    try std.testing.expect((try h.find(.{ .kind = .popup })).checked);
    try std.testing.expect((try h.find(.{ .kind = .combo_field })).checked);
    try std.testing.expect(try h.key(.{ .key = .escape }));
    try std.testing.expect(!(try h.find(.{ .kind = .popup })).checked);
    try std.testing.expectEqual(input_id, h.focused().?.id);
    // Down opens it with the same options; F4 closes it.
    try std.testing.expect(try h.key(.{ .key = .down }));
    try std.testing.expect((try h.find(.{ .kind = .popup })).checked);
    try std.testing.expect(try h.key(.{ .key = .f4 }));
    try std.testing.expect(!(try h.find(.{ .kind = .popup })).checked);
    // The button opens and closes it, and focus stays in the input.
    state.input.text = "S";
    try h.render();
    try std.testing.expect((try h.find(.{ .kind = .popup })).checked);
    try h.click(.{ .kind = .combo_toggle });
    try std.testing.expect(!(try h.find(.{ .kind = .popup })).checked);
    try h.click(.{ .kind = .combo_toggle });
    try std.testing.expect((try h.find(.{ .kind = .popup })).checked);
    try std.testing.expectEqual(input_id, h.focused().?.id);
    // While an input method composes, the list hides and keys go to it.
    state.input.composing = true;
    try h.render();
    try std.testing.expect(!(try h.find(.{ .kind = .popup })).checked);
    h.view.focus = input_id;
    try std.testing.expect(h.view.routeKey(.{ .key = .enter }) == .ignored);
    try std.testing.expect(h.view.routeKey(.{ .key = .down }) == .ignored);
    try std.testing.expect(h.view.routeKey(.{ .key = .escape }) == .ignored);
    try std.testing.expect(state.picked == null);
    state.input.composing = false;
    try h.render();
    try std.testing.expect((try h.find(.{ .kind = .popup })).checked);
    try std.testing.expect(try h.key(.{ .key = .down }));
    try std.testing.expect(try h.key(.{ .key = .enter }));
    try std.testing.expectEqualStrings("Serif", state.picked.?);
    try std.testing.expect(!(try h.find(.{ .kind = .popup })).checked);
    try std.testing.expectEqual(input_id, h.focused().?.id);
    // Leaving the field forgets the explicit opening.
    context.input_state.setFocused((try h.find(.{ .text = "Apply" })).id);
    try h.render();
    try std.testing.expect(!(try h.find(.{ .kind = .popup })).checked);
}

const Tags = struct {
    tags: [8][]const u8 = .{ "zig", "ui", "desktop", "windows", "linux", "", "", "" },
    len: usize = 5,
    input: FakeInput = .{},
    fn build(self: *Tags, v: *View) anyerror!void {
        try v.tokenField(.{ .name = "Tags", .self_align = .stretch });
        var index: usize = 0;
        while (index < self.len) {
            const tag = self.tags[index];
            if (try v.token(tag, .{ .key = view.key(tag) })) {
                std.mem.copyForwards([]const u8, self.tags[index .. self.len - 1], self.tags[index + 1 .. self.len]);
                self.len -= 1;
            } else index += 1;
        }
        try v.embed(self.input.embed(), .{ .grow = 1, .key = 1 });
        try v.end();
    }
};

test "token fields wrap, remove tokens and move between tokens and input" {
    var storage: view.Storage(32, 256) = .{};
    var state: Tags = .{};
    var h = Harness.init(&state, Tags.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 640, .height = 480 } });
    try h.render();
    const wide = (try h.find(.{ .kind = .token_field })).bounds.height;
    // A narrow window wraps the tokens onto more lines.
    try h.resize(.{ .x = 0, .y = 0, .width = 220, .height = 480 });
    const field = try h.find(.{ .kind = .token_field });
    try std.testing.expect(field.bounds.height > wide);
    for (h.nodes()) |*node| if (node.parent < h.nodes().len and h.nodes()[node.parent].kind == .token_field) {
        try std.testing.expect(node.bounds.x + node.bounds.width <= field.bounds.x + field.bounds.width + 0.01);
    };
    try h.resize(.{ .x = 0, .y = 0, .width = 640, .height = 480 });
    try std.testing.expectEqual(wide, (try h.find(.{ .kind = .token_field })).bounds.height);

    try h.removeToken(.{ .text = "ui" });
    try std.testing.expectEqual(@as(usize, 4), state.len);
    try std.testing.expectEqualStrings("desktop", state.tags[1]);

    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    const input_id = (try h.find(.{ .key = 1 })).id;
    context.input_state.setFocused(input_id);
    try h.render();
    // Backspace in the empty input moves to the last token; Left moves on.
    try std.testing.expect(try h.key(.{ .key = .backspace }));
    try std.testing.expectEqualStrings("linux", h.focused().?.text);
    try std.testing.expect(try h.key(.{ .key = .left }));
    try std.testing.expectEqualStrings("windows", h.focused().?.text);
    try std.testing.expect(try h.key(.{ .key = .home }));
    try std.testing.expectEqualStrings("zig", h.focused().?.text);
    // Delete removes the focused token and returns to the input.
    try std.testing.expect(try h.key(.{ .key = .delete }));
    try std.testing.expectEqual(@as(usize, 3), state.len);
    try std.testing.expectEqual(input_id, h.focused().?.id);
    // Right from the last token goes back to the input.
    context.input_state.setFocused((try h.find(.{ .text = "linux" })).id);
    try h.render();
    try std.testing.expect(try h.key(.{ .key = .right }));
    try std.testing.expectEqual(input_id, h.focused().?.id);
    // A non-empty input keeps Backspace for itself.
    state.input.text = "x";
    try std.testing.expect(!try h.key(.{ .key = .backspace }));
    // A press on the remove button removes the token.
    const last = try h.find(.{ .text = "linux" });
    try h.clickAt(last.bounds.x + last.bounds.width - 2, last.bounds.y + last.bounds.height / 2);
    try std.testing.expectEqual(@as(usize, 2), state.len);

    var loose: view.Storage(4, 32) = .{};
    var v = View.init(loose.buffers());
    v.reset(.{}, null);
    try std.testing.expectError(error.NotContainer, v.token("x", .{}));
    try std.testing.expectError(error.NotContainer, v.treeItem(1, null, "x", .{}));
    try std.testing.expectError(error.NotContainer, v.tableRow(1, "x", .{}));
}

test "selections keep stable ids within their capacity" {
    var storage: [2]u64 = undefined;
    var selection: view.Selection = .init(.multiple, &storage);
    try selection.add(4);
    try selection.add(4);
    try selection.add(9);
    try std.testing.expectError(error.SelectionFull, selection.add(1));
    try std.testing.expect(selection.remove(4));
    try std.testing.expect(!selection.remove(4));
    try selection.set(7);
    try std.testing.expectEqualSlices(u64, &.{7}, selection.items());
    try std.testing.expectEqual(@as(?u64, 7), selection.anchor);
    var single: view.Selection = .init(.single, &storage);
    try single.add(1);
    try single.add(2);
    try std.testing.expectEqualSlices(u64, &.{2}, single.items());
}
