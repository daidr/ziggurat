const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
extern fn zlg_resource_count() u32;
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_test_close(*anyopaque) void;
extern fn zlg_test_commit(*anyopaque, [*:0]const u8) void;
extern fn zlc_test_pixel(*anyopaque, u32, u32) u32;
extern fn zlc_test_text_pixels(*anyopaque) u32;
extern fn zlc_test_generation(*anyopaque) u32;
extern fn gtk_window_get_title(*anyopaque) [*:0]const u8;
extern fn gtk_widget_destroy(*anyopaque) void;
extern fn g_timeout_add(c_uint, *const fn (*anyopaque) callconv(.c) c_int, *anyopaque) c_uint;
extern fn g_source_remove(c_uint) c_int;

const Probe = struct {
    window: z.Window = undefined,
    content: ui.Context = undefined,
    cancel: bool = false,
    requests: usize = 0,
    closed: usize = 0,
    calls: usize = 0,
    close_in_draw: bool = false,
    close_in_text: bool = false,
    commits: usize = 0,
    timer_fired: bool = false,
    flood_calls: usize = 0,
    paint_scale: f32 = 0,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.paint_scale = frame.size.scale;
        frame.clear(0xffffff);
        if (self.close_in_draw) {
            std.debug.assert((self.window.destroy() catch unreachable) == .deferred);
            std.debug.assert(self.content.window != null);
        }
        frame.label(.{ .x = 8, .y = 8, .width = 280, .height = 40 }, "GTK / 图形 / 日本語 / 한글", 0x123456);
        frame.pushClip(.{ .x = 8, .y = 60, .width = 100, .height = 30 }) catch unreachable;
        frame.rect(.{ .x = 0, .y = 0, .width = 200, .height = 100 }, 0x274c77);
        frame.popClip() catch unreachable;
    }
    fn action(_: *anyopaque, _: u64) void {}
    fn request(ptr: *anyopaque, _: z.Window, reason: z.CloseReason) z.CloseDecision {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.requests += 1;
        std.debug.assert(reason == .user);
        return if (self.cancel) .cancel else .allow;
    }
    fn complete(ptr: *anyopaque, window: z.Window) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.closed += 1;
        std.debug.assert(window.isClosed());
        std.debug.assert(self.content.window == null);
    }
    fn attach(self: *Probe, app: *z.App) !void {
        self.window = try app.createWindow(.{ .title = "Linux / 图形", .width = 320, .height = 200, .min_width = 180, .min_height = 100, .on_close = .{ .context = self, .request = request }, .on_closed = .{ .context = self, .notify = complete } });
        self.content = ui.Context.init(self, draw, action);
        self.content.on_input = input;
        try self.content.attach(self.window);
    }
    fn input(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (event == .text_input) {
            std.debug.assert(std.mem.eql(u8, event.text_input.text, "GTK 输入 / 😀"));
            self.commits += 1;
            if (self.close_in_text) _ = self.window.destroy() catch unreachable;
            return true;
        }
        return false;
    }
    fn native(self: *Probe) *anyopaque {
        return self.window.app.windows.get(self.window.key).?.native.native.?;
    }
    fn task(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.window.app.assertOwner();
        self.calls += 1;
        if (self.calls == 256) {
            std.debug.assert((self.window.destroy() catch unreachable) == .deferred);
        }
    }
    fn produce(self: *Probe) void {
        for (0..64) |_| self.window.app.post(.{ .context = self, .call = task }) catch unreachable;
    }
    fn tick(ptr: *anyopaque) callconv(.c) c_int {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.timer_fired = true;
        return 0;
    }
    fn flood(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.flood_calls += 1;
        if (self.timer_fired) _ = self.window.destroy() catch unreachable else self.window.app.post(.{ .context = self, .call = flood }) catch unreachable;
    }
};
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    for (0..3) |cycle| {
        const app = try z.App.init(gpa.allocator());
        try std.testing.expectError(error.AppAlreadyExists, z.App.init(gpa.allocator()));
        var probe: Probe = .{};
        try probe.attach(app);
        try std.testing.expect(!(try probe.window.state()).visible);
        try probe.window.setTitle("Linux title / 新标题");
        try std.testing.expectEqualStrings("Linux title / 新标题", std.mem.span(gtk_window_get_title(probe.window.nativeHandle().?)));
        try probe.window.perform(.disable);
        try std.testing.expect(!(try probe.window.state()).enabled);
        try probe.window.perform(.enable);
        try std.testing.expect((try probe.window.state()).enabled);
        try probe.window.resize(400, 240);
        try probe.window.setTextCaret(.{ .x = 8, .y = 8, .width = 1, .height = 18 });
        try probe.window.cancelTextComposition();
        zlg_test_paint(probe.native(), 320, 200);
        try std.testing.expect(probe.content.frames > 0 and probe.content.hasSurface());
        // X11 obeys this explicit test scale; other display servers choose their own scale.
        if (zio.getenv("GDK_BACKEND")) |backend| if (std.mem.eql(u8, backend, "x11")) {
            if (zio.getenv("GDK_SCALE")) |scale| try std.testing.expectEqual(try std.fmt.parseFloat(f32, scale), probe.paint_scale);
        };
        const surface = probe.content.renderer.native.?;
        try std.testing.expectEqual(@as(u32, 0x274c77), zlc_test_pixel(surface, 20, 70));
        try std.testing.expectEqual(@as(u32, 0xffffff), zlc_test_pixel(surface, 200, 150));
        try std.testing.expect(zlc_test_text_pixels(surface) > 50);
        const generation = zlc_test_generation(surface);
        zlg_test_paint(probe.native(), 320, 200);
        try std.testing.expectEqual(generation, zlc_test_generation(surface));
        probe.cancel = true;
        zlg_test_close(probe.native());
        try std.testing.expect(!probe.window.isClosed());
        probe.cancel = false;
        zlg_test_close(probe.native());
        try std.testing.expect(probe.window.isClosed());
        try std.testing.expectEqual(@as(usize, 0), probe.closed);
        try app.dispatch();
        try std.testing.expectEqual(@as(usize, 1), probe.closed);
        const stale = probe.window;
        try probe.attach(app);
        probe.close_in_draw = true;
        zlg_test_paint(probe.native(), 320, 200);
        try std.testing.expect(probe.window.isClosed() and probe.content.window != null);
        try app.dispatch();
        probe.close_in_draw = false;
        try probe.attach(app);
        probe.close_in_text = true;
        zlg_test_commit(probe.native(), "GTK 输入 / 😀");
        try std.testing.expectEqual(@as(usize, 1), probe.commits);
        try std.testing.expect(probe.window.isClosed() and probe.content.window != null);
        try app.dispatch();
        probe.close_in_text = false;
        try probe.attach(app);
        gtk_widget_destroy(probe.window.nativeHandle().?);
        try std.testing.expect(probe.window.isClosed() and probe.content.window == null);
        for (0..64) |_| {
            try probe.attach(app);
            _ = try stale.destroy();
            try std.testing.expect(!probe.window.isClosed());
            _ = try probe.window.destroy();
        }
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
        try std.testing.expectEqual(@as(usize, 1), app.resourceStats().registry_slots);
        try probe.attach(app);
        var threads: [4]std.Thread = undefined;
        for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Probe.produce, .{&probe});
        for (threads) |thread| thread.join();
        try app.run();
        try std.testing.expectEqual(@as(usize, 256), probe.calls);
        try std.testing.expect(probe.window.isClosed() and probe.content.window == null);
        app.deinit();
        try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
        std.debug.print("Linux cycle {d}: GTK/Cairo/Pango, veto/closed callback, 256 cross-thread tasks; records/native resources=0\n", .{cycle + 1});
    }
    const flood_app = try z.App.init(gpa.allocator());
    var flood_probe: Probe = .{};
    try flood_probe.attach(flood_app);
    const timer = g_timeout_add(2, Probe.tick, &flood_probe);
    defer if (!flood_probe.timer_fired) {
        _ = g_source_remove(timer);
    };
    try flood_app.post(.{ .context = &flood_probe, .call = Probe.flood });
    try flood_app.run();
    try std.testing.expect(flood_probe.timer_fired and flood_probe.flood_calls > 0);
    flood_app.deinit();
    try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    try std.testing.expectError(error.UnsupportedCapability, z.App.initWithOptions(gpa.allocator(), .{ .icon_policy = .required }));
    std.debug.print("Linux smoke passed: 4 sequential Apps, hidden native windows, IM commit/callback close, fair event-driven GLib wake\n", .{});
}
