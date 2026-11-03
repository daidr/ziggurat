const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const d = @import("ziggurat_document");
const t = @import("ziggurat_text_layout");
const editing = @import("ziggurat_document_editor");
const view = @import("ziggurat_view");
const text = @import("ziggurat_view_text");
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};

extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_resource_count() u32;
extern fn zlg_test_commit(*anyopaque, [*:0]const u8) void;
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn gdk_event_new(c_int) ?*anyopaque;
extern fn gdk_event_free(*anyopaque) void;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
const ButtonEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, axes: ?*anyopaque, state: c_uint, button: c_uint, device: ?*anyopaque, x_root: f64, y_root: f64 };

const width = 360;
const height = 240;

const Native = struct {
    fn paint(window: z.Window) void {
        if (builtin.os.tag == .windows) {
            const hwnd: c.HWND = window.nativeHandle();
            _ = c.InvalidateRect(hwnd, null, 0);
            _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
        } else {
            const scope = window.beginCallback().?;
            defer scope.end();
            zlg_test_paint(scope.record.native.native.?, width, height);
        }
    }
    fn pointer(window: z.Window, down: bool, x: f32, y: f32) void {
        if (builtin.os.tag == .windows) {
            const hwnd: c.HWND = window.nativeHandle();
            const scale = @as(f32, @floatFromInt(c.GetDpiForWindow(hwnd))) / 96;
            const px: u16 = @bitCast(@as(i16, @intFromFloat(x * scale)));
            const py: u16 = @bitCast(@as(i16, @intFromFloat(y * scale)));
            const point: c.LPARAM = @intCast(@as(u32, px) | (@as(u32, py) << 16));
            _ = c.SendMessageW(hwnd, if (down) c.WM_LBUTTONDOWN else c.WM_LBUTTONUP, if (down) c.MK_LBUTTON else 0, point);
        } else {
            const widget = gtk_bin_get_child(window.nativeHandle().?).?;
            const event = gdk_event_new(if (down) 4 else 7).?;
            defer gdk_event_free(event);
            const native: *ButtonEvent = @ptrCast(@alignCast(event));
            native.* = .{ .kind = if (down) 4 else 7, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .x = x, .y = y, .axes = null, .state = if (down) 0 else 1 << 8, .button = 1, .device = null, .x_root = 0, .y_root = 0 };
            var handled: c_int = 0;
            g_signal_emit_by_name(widget, if (down) @as([*:0]const u8, "button-press-event") else @as([*:0]const u8, "button-release-event"), native, &handled);
        }
    }
    fn click(window: z.Window, bounds: view.Rect) void {
        const x = bounds.x + bounds.width / 2;
        const y = bounds.y + bounds.height / 2;
        pointer(window, true, x, y);
        pointer(window, false, x, y);
    }
    /// Commit text through the platform text service path.
    fn commit(window: z.Window, value: [:0]const u8) !void {
        if (builtin.os.tag == .linux) {
            zlg_test_commit(window.app.windows.get(window.key).?.native.native.?, value);
        } else {
            const token = window.textClientToken() orelse return error.NoTextClient;
            var current: [64]u8 = undefined;
            const snapshot = try window.readTextClient(token, &current);
            _ = try window.changeTextClient(token, .{ .replace = .{ .range = .{ .start = snapshot.selection.caret, .end = snapshot.selection.caret }, .text = value } });
        }
    }
};

const State = struct {
    field: *text.TextField = undefined,
    banner: bool = false,
    clears: usize = 0,
    fn build(self: *State, v: *view.View) anyerror!void {
        if (self.banner) try v.text("Moved down", .{});
        try v.text("Name", .{ .key = 1 });
        try v.row(.{ .gap = 8, .self_align = .stretch, .key = 2 });
        try v.embed(self.field.embed(), .{ .grow = 1 });
        if (try v.button("Clear", .{})) self.clears += 1;
        try v.end();
    }
};

fn find(host: *const view.Host, kind: view.Kind) !view.Node {
    for (host.view.nodes()) |node| if (node.kind == kind) return node;
    return error.MissingNode;
}

fn paint(host: *view.Host, window: z.Window) !void {
    const before = host.frames;
    Native.paint(window);
    if (host.last_error) |err| return err;
    try std.testing.expectEqual(before + 1, host.frames);
}

/// Paint, let the posted preparation run, and paint the prepared field.
fn settle(host: *view.Host, field: *text.TextField, window: z.Window) !void {
    try paint(host, window);
    try window.app.dispatch();
    if (field.last_error) |err| return err;
    try paint(host, window);
    try std.testing.expect(field.pending == null and !field.queued);
}

fn expectValue(document: *d.Document, expected: []const u8) !void {
    var bytes: [64]u8 = undefined;
    const count = try document.read(.{ .start = 0, .end = try document.byteLength() }, &bytes);
    try std.testing.expectEqualStrings(expected, bytes[0..count]);
}

fn run(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "", .{});
    defer document.close() catch unreachable;

    var state: State = .{};
    var storage: view.Storage(32, 512) = .{};
    var host = view.Host.init(&state, State.build, storage.buffers(), .{});
    host.context.render_mode = .gdi;
    const window = try app.createWindow(.{ .width = width, .height = height });
    try host.attach(window);
    try host.context.prepareTextFields(allocator, .{});

    const editor = try editing.Field.create(allocator, document, engine, .{});
    var closed = false;
    defer if (!closed) editor.close() catch unreachable;
    var field = text.TextField.init(editor, &host, .{ .font = .{ .size = 16 }, .scale = (try window.contentSize()).scale }, .{ .name = "Name" });
    state.field = &field;

    // The first frame places the field; preparation and attach follow it.
    try paint(&host, window);
    try std.testing.expect(!field.attached and field.queued);
    try app.dispatch();
    if (field.last_error) |err| return err;
    try std.testing.expect(field.attached);
    try paint(&host, window);
    const box = try find(&host, .embed);
    try std.testing.expectEqualDeep(box.bounds, field.prepared.?);
    try std.testing.expectEqual(box.id, field.id);
    try std.testing.expect(box.bounds.width > 100);

    // A native click focuses the field and binds the native text client.
    Native.click(window, box.bounds);
    try std.testing.expectEqual(@as(?u64, field.id), host.context.input_state.focused);
    try std.testing.expect(try window.hasTextClient());
    try Native.commit(window, "Hi");
    try expectValue(document, "Hi");
    try paint(&host, window);

    // The sibling button still works beside the field.
    Native.click(window, (try find(&host, .button)).bounds);
    try std.testing.expectEqual(@as(usize, 1), state.clears);

    // A layout change moves the field; it is prepared again after paint and
    // keeps its id and document.
    state.banner = true;
    Native.click(window, box.bounds);
    try settle(&host, &field, window);
    const moved = try find(&host, .embed);
    try std.testing.expectEqual(box.id, moved.id);
    try std.testing.expect(moved.bounds.y > box.bounds.y);
    try std.testing.expectEqualDeep(moved.bounds, field.prepared.?);
    Native.click(window, moved.bounds);
    try std.testing.expectEqual(@as(?u64, field.id), host.context.input_state.focused);
    try Native.commit(window, "!");
    try expectValue(document, "Hi!");

    // Automation selects a range, in UTF-16 units, through the field's
    // accessibility path; a reversed range is refused.
    try host.perform(field.id, .{ .select_text = .{ .start = 1, .end = 3 } });
    var current: [64]u8 = undefined;
    const snapshot = try window.readTextClient(window.textClientToken() orelse return error.NoTextClient, &current);
    try std.testing.expectEqual(@as(usize, 1), snapshot.selection.anchor);
    try std.testing.expectEqual(@as(usize, 3), snapshot.selection.caret);
    try std.testing.expectError(error.InvalidValue, host.perform(field.id, .{ .select_text = .{ .start = 3, .end = 1 } }));
    try std.testing.expectError(error.NotSupported, host.perform((try find(&host, .button)).id, .{ .select_text = .{ .start = 0, .end = 1 } }));
    try paint(&host, window);

    field.detach();
    try editor.close();
    closed = true;
    _ = try window.destroy();
    try app.dispatch();
    try std.testing.expect(host.context.window == null);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    try run(gpa.allocator());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("view text native: deferred prepare, attach, focus, commit and relayout passed\n", .{});
}
