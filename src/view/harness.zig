//! Drives a build function without a window. The harness runs the same
//! build, layout and event passes as Host, so tests can find controls by
//! kind, label or key, activate them by query or point, and inspect the
//! resulting state and tree. Nothing here touches native code or allocates.
const std = @import("std");
const view = @import("root.zig");

const View = view.View;
const Node = view.Node;
const Kind = view.Kind;
const Rect = view.Rect;
const Event = view.Event;
const ValueChange = view.ValueChange;

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

pub const Error = error{ NotFound, Ambiguous, Disabled, Hidden, NotActivatable, NotAdjustable, Stale };

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

    pub fn init(state: anytype, comptime build: fn (@TypeOf(state), *View) anyerror!void, buffers: view.Buffers, config: Config) Harness {
        return .{ .view = View.init(buffers), .build = view.Build.bind(state, build), .config = config };
    }

    /// Build and arrange the current state, as a paint would.
    pub fn render(self: *Harness) anyerror!void {
        try self.build.run(&self.view, self.config.options.root, null);
        try self.view.arrange(self.config.bounds, self.config.theme, self.config.options.measurer);
        self.frames += 1;
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
        const all = self.view.nodes();
        var rect = node.bounds;
        var parent = node.parent;
        while (parent < all.len) : (parent = all[parent].parent) {
            const ancestor = &all[parent];
            if (ancestor.style.clip) rect = intersect(rect, ancestor.bounds) orelse return null;
        }
        if (!(rect.width > 0 and rect.height > 0)) return null;
        return rect;
    }

    /// The last painted interactive node under `point`, honouring clips.
    pub fn at(self: *const Harness, x: f32, y: f32) ?*const Node {
        const all = self.view.nodes();
        var index = all.len;
        while (index > 0) {
            index -= 1;
            const node = &all[index];
            if (!interactive(node.kind)) continue;
            const rect = self.visible(node) orelse continue;
            if (x >= rect.x and y >= rect.y and x < rect.x + rect.width and y < rect.y + rect.height) return node;
        }
        return null;
    }

    /// Activate the matching button, checkbox, switch or radio, then render.
    pub fn click(self: *Harness, query: Query) anyerror!void {
        try self.activate(try self.find(query));
    }

    /// Activate whatever interactive node lies under the point, then render.
    pub fn clickAt(self: *Harness, x: f32, y: f32) anyerror!void {
        try self.activate(self.at(x, y) orelse return error.NotFound);
    }

    /// Apply a value change to the matching slider, then render.
    pub fn change(self: *Harness, query: Query, value: ValueChange) anyerror!void {
        const node = try self.find(query);
        if (node.kind != .slider) return error.NotAdjustable;
        try self.check(node);
        try self.deliver(.{ .value = .{ .id = node.id, .change = value } });
    }

    fn activate(self: *Harness, node: *const Node) anyerror!void {
        switch (node.kind) {
            .button, .checkbox, .toggle_switch, .radio => {},
            else => return error.NotActivatable,
        }
        try self.check(node);
        try self.deliver(.{ .action = node.id });
    }

    fn check(self: *const Harness, node: *const Node) Error!void {
        if (!node.style.enabled) return error.Disabled;
        if (self.visible(node) == null) return error.Hidden;
    }

    fn deliver(self: *Harness, event: Event) anyerror!void {
        try self.build.run(&self.view, self.config.options.root, event);
        // The node came from the last render; a build that no longer emits it
        // means the test is acting on a stale tree.
        if (!self.view.consumed) return error.Stale;
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
                .checkbox, .toggle_switch, .radio => try writer.writeAll(if (node.checked) " on" else " off"),
                .progress => try writer.print(" {d:.2}", .{node.fraction}),
                .slider => try writer.print(" {d}", .{node.value}),
                else => {},
            }
            if (!node.style.enabled) try writer.writeAll(" disabled");
            const b = node.bounds;
            try writer.print(" @{d},{d} {d}x{d}\n", .{ round(b.x), round(b.y), round(b.width), round(b.height) });
        }
    }
};

fn interactive(kind: Kind) bool {
    return switch (kind) {
        .button, .checkbox, .toggle_switch, .radio, .slider => true,
        else => false,
    };
}

fn intersect(a: Rect, b: Rect) ?Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.width, b.x + b.width);
    const y1 = @min(a.y + a.height, b.y + b.height);
    if (!(x1 > x0 and y1 > y0)) return null;
    return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
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
