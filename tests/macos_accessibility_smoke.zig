//! A window's semantic tree as VoiceOver reads it through NSAccessibility:
//! the content view's elements, their roles, titles, values and frames,
//! and the actions assistive technology takes on them, including an
//! NSNumber set as a text field's AXValue.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");

extern fn zlm_test_paint(*anyopaque) void;
extern fn zua_test_element(handle: *anyopaque, name: [*:0]const u8) ?*anyopaque;
extern fn zua_test_describe(element: *anyopaque, buffer: [*]u8, capacity: c_int) c_int;
extern fn zua_test_frame_in_window(element: *anyopaque, handle: *anyopaque) c_int;
extern fn zua_test_act(element: *anyopaque, kind: c_int, number: f64, text: [*:0]const u8) void;
extern fn zua_test_child_count(handle: *anyopaque) c_int;

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
                else => {},
            },
            .set_range => |range| if (range.id == 3) {
                self.volume = range.value;
            },
            .set_value => |text| if (text.id == 2) {
                @memcpy(self.name[0..text.text.len], text.text);
                self.name_len = text.text.len;
            },
            .select_text => |range| if (range.id == 2) {
                self.selection = .{ range.start_utf16, range.end_utf16 };
            },
            .set_focus => |id| self.focused = id,
        }
    }
    fn handle(self: *Probe) *anyopaque {
        return self.window.nativeHandle().?;
    }
    fn native(self: *Probe) *anyopaque {
        return self.window.app.windows.get(self.window.key).?.native.native.?;
    }
    /// Draws a frame, which publishes the tree.
    fn publish(self: *Probe) void {
        zlm_test_paint(self.native());
    }
    fn element(self: *Probe, name: [*:0]const u8) !*anyopaque {
        return zua_test_element(self.handle(), name) orelse {
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
        std.debug.print("macOS accessibility: this build leaves accessibility out; skipped\n", .{});
        return;
    }
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const app = try z.App.init(gpa.allocator());
    defer app.deinit();
    var probe: Probe = .{};
    @memcpy(probe.name[0..3], "abc");
    probe.window = try app.createWindow(.{ .title = "Accessibility", .width = 320, .height = 200 });
    probe.content = ui.Context.init(&probe, Probe.draw, Probe.action);
    probe.content.semantic_name = "Settings";
    probe.content.on_accessibility_action = Probe.accessibility;
    try probe.content.attach(probe.window);
    probe.window.show();
    probe.publish();

    // The top level: four elements, the checkbox and the disabled button
    // inside the group.
    try std.testing.expectEqual(@as(c_int, 4), zua_test_child_count(probe.handle()));
    try probe.expect("Save", "AXButton/|Save|||1");
    try probe.expect("Name", "AXTextField/||Name|abc|1");
    try probe.expect("Volume", "AXSlider/||Volume|5|1");
    try probe.expect("Options", "AXGroup/||Options||1");
    try probe.expect("Agree", "AXCheckBox/|Agree||1|1");
    try probe.expect("Disabled", "AXButton/|Disabled|||0");
    try std.testing.expect(zua_test_frame_in_window(try probe.element("Save"), probe.handle()) != 0);

    // Actions reach the content, which publishes what they changed.
    zua_test_act(try probe.element("Save"), 1, 0, "");
    try std.testing.expectEqual(@as(u32, 1), probe.pressed);
    zua_test_act(try probe.element("Disabled"), 1, 0, "");
    zua_test_act(try probe.element("Agree"), 1, 0, "");
    try std.testing.expect(!probe.agree);
    zua_test_act(try probe.element("Volume"), 2, 0, "");
    try std.testing.expectEqual(@as(f64, 6), probe.volume);
    zua_test_act(try probe.element("Name"), 3, 0, "张三");
    try std.testing.expectEqualStrings("张三", probe.name[0..probe.name_len]);
    zua_test_act(try probe.element("Name"), 5, 0, "");
    try std.testing.expectEqual(@as(u64, 2), probe.focused);
    probe.publish();
    try probe.expect("Agree", "AXCheckBox/|Agree||0|1");
    try probe.expect("Volume", "AXSlider/||Volume|6|1");
    try probe.expect("Name", "AXTextField/||Name|张三|1");
    zua_test_act(try probe.element("Name"), 6, 1, "");
    try std.testing.expectEqual([2]usize{ 1, 2 }, probe.selection);
    // VoiceOver may set a text field's value as an NSNumber: it reads as
    // its text instead of crashing the app.
    zua_test_act(try probe.element("Name"), 4, 42, "");
    try std.testing.expectEqualStrings("42", probe.name[0..probe.name_len]);
    probe.publish();
    try probe.expect("Name", "AXTextField/||Name|42|1");

    _ = try probe.window.destroy();
    try app.dispatch();
    const counts = ui.accessibility.resourceCounts();
    std.debug.print("macOS accessibility: roles, titles, values, frames, press/increment/value/focus/selection and an NSNumber AXValue passed; hosts={d} elements={d} actions={d}\n", .{ counts.states, counts.providers, counts.actions });
    try std.testing.expectEqual(@as(u32, 0), counts.actions);
}
