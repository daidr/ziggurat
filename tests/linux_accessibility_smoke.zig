//! A window's semantic tree as a screen reader reads it through ATK: the
//! objects below the drawing area, their roles, names, values, states and
//! extents, the signals they send, and the actions assistive technology
//! takes on them.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");

extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zua_test_element(host: *anyopaque, name: [*:0]const u8) ?*anyopaque;
extern fn zua_test_describe(element: *anyopaque, buffer: [*]u8, capacity: c_int) c_int;
extern fn zua_test_extents(element: *anyopaque, window: c_int, out: *[4]i32) void;
extern fn zua_test_act(element: *anyopaque, kind: c_int, number: f64, text: [*:0]const u8) c_int;
extern fn zua_test_child_count(host: *anyopaque) c_int;
extern fn zua_test_mounted(host: *anyopaque) c_int;
extern fn zua_test_announcements(buffer: [*]u8, capacity: c_int) c_int;
extern fn zua_test_selection_count(element: *anyopaque) c_int;
extern fn zua_test_caret(element: *anyopaque) c_int;

const Probe = struct {
    window: z.Window = undefined,
    content: ui.Context = undefined,
    pressed: u32 = 0,
    volume: f64 = 5,
    name: [64]u8 = undefined,
    name_len: usize = 3,
    selection: [2]usize = .{ 0, 0 },
    focused: u64 = 0,
    agree: bool = true,
    saved: bool = false,
    chosen: u64 = 21,
    open: bool = false,

    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        frame.clear(0xffffff);
        const semantic = struct {
            fn add(f: *ui.Frame, node: ui.accessibility.Node) void {
                f.semantic(node) catch |err| std.debug.panic("semantic {d}: {s}", .{ node.id, @errorName(err) });
            }
        };
        semantic.add(frame, .{ .id = 1, .role = .button, .name = "Save", .bounds = .{ .x = 10, .y = 10, .width = 80, .height = 24 }, .focused = self.focused == 1 });
        semantic.add(frame, .{ .id = 2, .role = .text_box, .name = "Name", .value = self.name[0..self.name_len], .selection_start = self.selection[0], .selection_end = self.selection[1], .bounds = .{ .x = 10, .y = 40, .width = 160, .height = 24 }, .focused = self.focused == 2 });
        semantic.add(frame, .{ .id = 3, .role = .slider, .name = "Volume", .range_value = self.volume, .range_minimum = 0, .range_maximum = 10, .range_small_change = 1, .bounds = .{ .x = 10, .y = 70, .width = 160, .height = 24 } });
        semantic.add(frame, .{ .id = 4, .role = .group, .name = "Options", .bounds = .{ .x = 10, .y = 100, .width = 200, .height = 60 } });
        semantic.add(frame, .{ .id = 5, .parent = 4, .role = .checkbox, .name = "Agree", .checked = self.agree, .bounds = .{ .x = 14, .y = 104, .width = 100, .height = 20 } });
        semantic.add(frame, .{ .id = 6, .parent = 4, .role = .button, .name = "Disabled", .enabled = false, .bounds = .{ .x = 14, .y = 130, .width = 100, .height = 20 } });
        semantic.add(frame, .{ .id = 20, .role = .list_box, .name = "Fruit", .bounds = .{ .x = 220, .y = 10, .width = 90, .height = 60 } });
        semantic.add(frame, .{ .id = 21, .parent = 20, .role = .list_item, .name = "Apple", .checked = self.chosen == 21, .bounds = .{ .x = 220, .y = 10, .width = 90, .height = 20 } });
        semantic.add(frame, .{ .id = 22, .parent = 20, .role = .list_item, .name = "Pear", .checked = self.chosen == 22, .bounds = .{ .x = 220, .y = 30, .width = 90, .height = 20 } });
        semantic.add(frame, .{ .id = 30, .role = .tree, .name = "Files", .bounds = .{ .x = 220, .y = 80, .width = 90, .height = 40 } });
        semantic.add(frame, .{ .id = 31, .parent = 30, .role = .tree_item, .name = "src", .expanded = self.open, .bounds = .{ .x = 220, .y = 80, .width = 90, .height = 20 } });
        if (self.saved) semantic.add(frame, .{ .id = 7, .role = .status, .name = "Saved", .bounds = .{ .x = 10, .y = 170, .width = 160, .height = 20 } });
    }
    fn action(_: *anyopaque, _: u64) void {}
    fn accessibility(ptr: *anyopaque, context: *ui.Context, value: ui.accessibility.Action) void {
        _ = context;
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (value) {
            .invoke => |id| switch (id) {
                1 => self.pressed += 1,
                5 => self.agree = !self.agree,
                6 => @panic("a disabled button was pressed"),
                21, 22 => self.chosen = id,
                else => {},
            },
            .set_range => |range| switch (range.id) {
                3 => self.volume = range.value,
                31 => self.open = range.value == 3,
                else => {},
            },
            .set_value => |text| if (text.id == 2) {
                @memcpy(self.name[0..text.text.len], text.text);
                self.name_len = text.text.len;
            },
            .select_text => |range| if (range.id == 2) {
                self.selection = .{ bytesOf(self.name[0..self.name_len], range.start_utf16), bytesOf(self.name[0..self.name_len], range.end_utf16) };
            },
            .set_focus => |id| self.focused = id,
        }
    }
    /// The UTF-8 offset of a UTF-16 offset of `text`.
    fn bytesOf(text: []const u8, units: usize) usize {
        var seen: usize = 0;
        var at: usize = 0;
        while (at < text.len and seen < units) {
            const length = std.unicode.utf8ByteSequenceLength(text[at]) catch 1;
            seen += if (length == 4) 2 else 1;
            at += length;
        }
        return at;
    }
    fn native(self: *Probe) *anyopaque {
        return self.window.app.windows.get(self.window.key).?.native.native.?;
    }
    fn host(self: *Probe) *anyopaque {
        return self.content.accessibility_bridge.native.?;
    }
    /// Draws a frame, which publishes the tree.
    fn publish(self: *Probe) void {
        self.window.invalidate();
        zlg_test_paint(self.native(), 320, 200);
    }
    fn element(self: *Probe, name: [*:0]const u8) !*anyopaque {
        return zua_test_element(self.host(), name) orelse {
            std.debug.print("no element named {s}\n", .{name});
            return error.MissingElement;
        };
    }
    fn expect(self: *Probe, name: [*:0]const u8, want: []const u8) !void {
        var buffer: [512]u8 = undefined;
        const length = zua_test_describe(try self.element(name), &buffer, buffer.len);
        try std.testing.expectEqualStrings(want, buffer[0..@intCast(length)]);
    }
};

pub fn main() !void {
    if (comptime !ui.capabilities.accessibility) {
        std.debug.print("Linux accessibility: this build leaves accessibility out; skipped\n", .{});
        return;
    }
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const app = try z.App.init(gpa.allocator());
    defer app.deinit();

    // A window whose drawing area hosts no accessible children shows no
    // tree, and its content works as without accessibility.
    {
        var plain: Probe = .{};
        plain.window = try app.createWindow(.{ .title = "Plain", .width = 100, .height = 100 });
        plain.content = ui.Context.init(&plain, Probe.draw, Probe.action);
        try plain.content.attach(plain.window);
        try std.testing.expect(!plain.content.attached_semantics_enabled);
        zlg_test_paint(plain.native(), 100, 100);
        _ = try plain.window.destroy();
        try app.dispatch();
    }

    var probe: Probe = .{};
    @memcpy(probe.name[0..3], "abc");
    probe.window = try app.createWindow(.{ .title = "Accessibility", .width = 320, .height = 200, .accessibility_host = .children });
    probe.content = ui.Context.init(&probe, Probe.draw, Probe.action);
    probe.content.semantic_name = "Settings";
    probe.content.on_accessibility_action = Probe.accessibility;
    try probe.content.attach(probe.window);
    probe.window.show();
    probe.publish();
    try std.testing.expect(zua_test_mounted(probe.host()) != 0);

    // The top level: six objects, the checkbox and the disabled button
    // inside the group, the rows inside the list.
    try std.testing.expectEqual(@as(c_int, 6), zua_test_child_count(probe.host()));
    try probe.expect("Save", "push button|Save||e");
    try probe.expect("Name", "entry|Name|abc|e");
    try probe.expect("Volume", "slider|Volume|5|e");
    try probe.expect("Options", "panel|Options||e");
    try probe.expect("Agree", "check box|Agree||ec");
    try probe.expect("Disabled", "push button|Disabled||");
    try probe.expect("Apple", "list item|Apple||es");
    try probe.expect("Pear", "list item|Pear||e");
    try std.testing.expectEqual(@as(c_int, 1), zua_test_selection_count(try probe.element("Fruit")));
    var extents: [4]i32 = undefined;
    zua_test_extents(try probe.element("Save"), 1, &extents);
    try std.testing.expectEqual(@as(i32, 80), extents[2]);
    try std.testing.expectEqual(@as(i32, 24), extents[3]);

    // Actions reach the content, which publishes what they changed.
    try std.testing.expect(zua_test_act(try probe.element("Save"), 1, 0, "") != 0);
    try std.testing.expectEqual(@as(u32, 1), probe.pressed);
    try std.testing.expect(zua_test_act(try probe.element("Disabled"), 1, 0, "") == 0);
    _ = zua_test_act(try probe.element("Agree"), 1, 0, "");
    try std.testing.expect(!probe.agree);
    _ = zua_test_act(try probe.element("Volume"), 2, 7, "");
    try std.testing.expectEqual(@as(f64, 7), probe.volume);
    _ = zua_test_act(try probe.element("Volume"), 2, 70, "");
    try std.testing.expectEqual(@as(f64, 10), probe.volume);
    _ = zua_test_act(try probe.element("Name"), 3, 0, "张三");
    try std.testing.expectEqualStrings("张三", probe.name[0..probe.name_len]);
    _ = zua_test_act(try probe.element("Name"), 5, 0, "");
    try std.testing.expectEqual(@as(u64, 2), probe.focused);
    _ = zua_test_act(try probe.element("Fruit"), 7, 1, "");
    try std.testing.expectEqual(@as(u64, 22), probe.chosen);
    _ = zua_test_act(try probe.element("src"), 8, 0, "");
    try std.testing.expect(probe.open);
    probe.publish();
    try probe.expect("Agree", "check box|Agree||e");
    try probe.expect("Volume", "slider|Volume|10|e");
    try probe.expect("Name", "entry|Name|张三|e");
    try probe.expect("Pear", "list item|Pear||es");
    try probe.expect("src", "tree item|src||ex");
    // Offsets count characters; the content hears UTF-16 units.
    _ = zua_test_act(try probe.element("Name"), 6, 1, "");
    try std.testing.expectEqual([2]usize{ 3, 6 }, probe.selection);
    probe.publish();
    try std.testing.expectEqual(@as(c_int, 2), zua_test_caret(try probe.element("Name")));
    try std.testing.expectEqual(@as(c_int, 3), zua_test_act(try probe.element("Name"), 4, 2, "x"));
    try std.testing.expectEqualStrings("张三x", probe.name[0..probe.name_len]);
    probe.publish();

    // A status message announces itself once, when it appears.
    var said: [64]u8 = @splat(0);
    const before = zua_test_announcements(&said, said.len);
    probe.saved = true;
    probe.publish();
    try std.testing.expectEqual(before + 1, zua_test_announcements(&said, said.len));
    try std.testing.expectEqualStrings("Saved", std.mem.sliceTo(&said, 0));
    probe.publish();
    try std.testing.expectEqual(before + 1, zua_test_announcements(&said, said.len));
    try std.testing.expectEqual(@as(c_int, 7), zua_test_child_count(probe.host()));

    _ = try probe.window.destroy();
    try app.dispatch();
    const counts = ui.accessibility.resourceCounts();
    std.debug.print("Linux accessibility: ATK roles, names, values, states, extents, press/value/text/focus/selection/expand actions and a status announcement passed; hosts={d} objects={d} actions={d}\n", .{ counts.states, counts.providers, counts.actions });
    try std.testing.expectEqual(@as(u32, 0), counts.actions);
    try std.testing.expectEqual(@as(u32, 0), counts.providers);
}
