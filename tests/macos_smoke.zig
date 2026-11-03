const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
extern fn zlm_resource_count() u32;
extern fn zlm_test_paint(*anyopaque) void;
extern fn zlm_test_close(*anyopaque) void;
extern fn zlm_test_commit(*anyopaque, [*:0]const u8) void;
extern fn zlm_test_compose(*anyopaque, [*:0]const u8, usize) void;
extern fn zlm_test_title_is(*anyopaque, [*:0]const u8) c_int;
extern fn zlc_test_pixel(*anyopaque, u32, u32) u32;
extern fn zlc_test_text_pixels(*anyopaque) u32;

const Probe = struct {
    window: z.Window = undefined,
    content: ui.Context = undefined,
    cancel: bool = false,
    requests: usize = 0,
    closed: usize = 0,
    calls: usize = 0,
    commits: usize = 0,
    preedits: usize = 0,
    close_in_text: bool = false,
    paint_scale: f32 = 0,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.paint_scale = frame.size.scale;
        frame.clear(0xffffff);
        frame.label(.{ .x = 8, .y = 8, .width = 280, .height = 40 }, "AppKit / 图形 / 日本語 / 한글", 0x123456);
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
    }
    fn attach(self: *Probe, app: *z.App) !void {
        self.window = try app.createWindow(.{ .title = "macOS / 图形", .width = 320, .height = 200, .min_width = 180, .min_height = 100, .on_close = .{ .context = self, .request = request }, .on_closed = .{ .context = self, .notify = complete } });
        self.content = ui.Context.init(self, draw, action);
        self.content.on_input = input;
        try self.content.attach(self.window);
    }
    fn input(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (event) {
            .text_input => |value| {
                std.debug.assert(std.mem.eql(u8, value.text, "AppKit 输入 / 😀"));
                std.debug.assert(value.producer == .appkit_text_input);
                self.commits += 1;
                if (self.close_in_text) _ = self.window.destroy() catch unreachable;
                return true;
            },
            .text_preedit => |value| {
                std.debug.assert(std.mem.eql(u8, value.text, "にほん"));
                std.debug.assert(value.selection_start == "にほ".len);
                self.preedits += 1;
                return true;
            },
            else => return false,
        }
    }
    fn native(self: *Probe) *anyopaque {
        return self.window.app.windows.get(self.window.key).?.native.native.?;
    }
    fn task(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.window.app.assertOwner();
        self.calls += 1;
        if (self.calls == 256) std.debug.assert((self.window.destroy() catch unreachable) == .deferred);
    }
    fn produce(self: *Probe) void {
        for (0..64) |_| self.window.app.post(.{ .context = self, .call = task }) catch unreachable;
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
        try probe.window.setTitle("macOS title / 新标题");
        try std.testing.expect(zlm_test_title_is(probe.native(), "macOS title / 新标题") != 0);
        try probe.window.perform(.disable);
        try std.testing.expect(!(try probe.window.state()).enabled);
        try probe.window.perform(.enable);
        try std.testing.expect((try probe.window.state()).enabled);
        try probe.window.resize(400, 240);
        const bounds = try probe.window.clientBounds();
        try std.testing.expectEqual(@as(u32, 400), bounds.width);
        try std.testing.expectEqual(@as(u32, 240), bounds.height);
        try probe.window.setTextCaret(.{ .x = 8, .y = 8, .width = 1, .height = 18 });
        try probe.window.cancelTextComposition();
        zlm_test_paint(probe.native());
        try std.testing.expect(probe.content.frames > 0 and probe.content.hasSurface());
        try std.testing.expect(probe.paint_scale >= 1);
        const surface = probe.content.renderer.native.?;
        const scale: u32 = @intFromFloat(probe.paint_scale);
        try std.testing.expectEqual(@as(u32, 0x274c77), zlc_test_pixel(surface, 20 * scale, 70 * scale));
        try std.testing.expectEqual(@as(u32, 0xffffff), zlc_test_pixel(surface, 200 * scale, 150 * scale));
        try std.testing.expect(zlc_test_text_pixels(surface) > 50);
        // The capture shows the same pixels, as premultiplied BGRA.
        const shot = try probe.window.capture(gpa.allocator());
        defer gpa.allocator().free(shot.pixels);
        try std.testing.expectEqual(400 * scale, shot.width);
        try std.testing.expectEqual(240 * scale, shot.height);
        const blue = shot.pixels[((70 * scale) * shot.width + 20 * scale) * 4 ..][0..4];
        for (blue, [_]u8{ 0x77, 0x4c, 0x27, 0xff }) |got, want| try std.testing.expect(@abs(@as(i16, got) - want) <= 2);
        zlm_test_compose(probe.native(), "にほん", 2);
        try std.testing.expectEqual(@as(usize, 1), probe.preedits);
        probe.cancel = true;
        zlm_test_close(probe.native());
        try std.testing.expect(!probe.window.isClosed());
        probe.cancel = false;
        zlm_test_close(probe.native());
        try std.testing.expect(probe.window.isClosed());
        try std.testing.expectEqual(@as(usize, 0), probe.closed);
        try app.dispatch();
        try std.testing.expectEqual(@as(usize, 1), probe.closed);
        try probe.attach(app);
        probe.close_in_text = true;
        zlm_test_commit(probe.native(), "AppKit 输入 / 😀");
        try std.testing.expectEqual(@as(usize, 1), probe.commits);
        try std.testing.expect(probe.window.isClosed());
        try app.dispatch();
        probe.close_in_text = false;
        try probe.attach(app);
        probe.window.show();
        try std.testing.expect((try probe.window.state()).visible);
        var threads: [4]std.Thread = undefined;
        for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Probe.produce, .{&probe});
        for (threads) |thread| thread.join();
        try app.run();
        try std.testing.expectEqual(@as(usize, 256), probe.calls);
        try std.testing.expect(probe.window.isClosed());
        app.deinit();
        try std.testing.expectEqual(@as(u32, 0), zlm_resource_count());
        std.debug.print("macOS cycle {d}: AppKit/Core Graphics/Core Text, veto/closed callback, IME commit and preedit, 256 cross-thread tasks; native windows=0\n", .{cycle + 1});
    }
    try std.testing.expectError(error.UnsupportedCapability, z.App.initWithOptions(gpa.allocator(), .{ .icon_policy = .required }));
    std.debug.print("macOS smoke passed\n", .{});
}
