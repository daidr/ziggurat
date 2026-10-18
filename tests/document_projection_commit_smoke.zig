const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const d = @import("ziggurat_document");
const t = @import("ziggurat_text_layout");
const editing = @import("ziggurat_document_editor");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;
const rectangles: [2]ui.Rect = .{ .{ .x = 0, .y = 0, .width = 200, .height = 160 }, .{ .x = 208, .y = 0, .width = 200, .height = 160 } };
const Hook = struct {
    source: std.mem.Allocator,
    document: *d.Document,
    window: z.Window = undefined,
    watch: ?usize = null,
    close_window: bool = false,
    fired: bool = false,
    failure: ?anyerror = null,
    fn allocator(self: *Hook) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ptr: *anyopaque, size: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Hook = @ptrCast(@alignCast(ptr));
        return self.source.rawAlloc(size, alignment, ret);
    }
    fn resize(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, ret: usize) bool {
        const self: *Hook = @ptrCast(@alignCast(ptr));
        return self.source.rawResize(bytes, alignment, size, ret);
    }
    fn remap(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, ret: usize) ?[*]u8 {
        const self: *Hook = @ptrCast(@alignCast(ptr));
        return self.source.rawRemap(bytes, alignment, size, ret);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Hook = @ptrCast(@alignCast(ptr));
        if (self.watch) |address| if (address >= @intFromPtr(bytes.ptr) and address - @intFromPtr(bytes.ptr) < bytes.len) {
            self.watch = null;
            self.fired = true;
            if (self.close_window) _ = self.window.destroy() catch |err| {
                self.failure = err;
            } else _ = self.document.setSelection(.{ .anchor = 1, .caret = 1 }) catch |err| {
                self.failure = err;
            };
        };
        self.source.rawFree(bytes, alignment, ret);
    }
};
const Context = struct {
    hook: *Hook,
    adapters: [2]*editing.Adapter,
    context: ui.Context = undefined,
    failure: ?anyerror = null,
    fn action(_: *anyopaque, _: u64) void {}
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Context = @ptrCast(@alignCast(ptr));
        for (self.adapters, rectangles) |adapter, bounds| adapter.draw(frame, bounds, .{}) catch |err| {
            self.failure = err;
            return;
        };
        const resources = frame.context.command_buffer.preparedTextResources();
        if (resources.len == 0) {
            self.failure = error.MissingPreparedResource;
            return;
        }
        self.hook.watch = @intFromPtr(resources[0].lease);
    }
};
pub fn run(allocator: std.mem.Allocator) !void {
    for ([_]bool{ false, true }) |closing| try check(allocator, closing);
}
fn check(allocator: std.mem.Allocator, closing: bool) !void {
    const a = try d.Document.create(allocator, std.Thread.getCurrentId(), "one\ntwo", .{});
    defer a.close() catch unreachable;
    const b = try d.Document.create(allocator, std.Thread.getCurrentId(), "first\nsecond", .{});
    defer b.close() catch unreachable;
    var hook: Hook = .{ .source = allocator, .document = a, .close_window = closing };
    const engine = try t.Engine.create(hook.allocator(), std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const adapters: [2]*editing.Adapter = .{ try editing.Adapter.create(allocator, a, engine, .{}), try editing.Adapter.create(allocator, b, engine, .{}) };
    defer for (adapters) |adapter| adapter.close() catch unreachable;
    const app = try z.App.init(allocator);
    defer app.deinit();
    hook.window = try app.createWindow(.{ .width = 420, .height = 180 });
    defer _ = hook.window.destroy() catch unreachable;
    const outer = hook.window.beginCallback().?;
    defer outer.end();
    const scale: f32 = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(hook.window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(hook.window.nativeHandle().?));
    var parameters: [2]editing.Parameters = @splat(.{ .font = .{ .size = 16 }, .scale = scale });
    _ = try editing.preparePair(hook.window, adapters[0], adapters[1], rectangles, parameters);
    var state: Context = .{ .hook = &hook, .adapters = adapters };
    state.context = ui.Context.init(&state, Context.draw, Context.action);
    state.context.render_mode = .gdi;
    try state.context.attach(hook.window);
    if (builtin.os.tag == .windows) _ = c.SendMessageW(hook.window.nativeHandle(), c.WM_PAINT, 0, 0) else zlg_test_paint(hook.window.app.windows.get(hook.window.key).?.native.native.?, @intFromFloat(420 * scale), @intFromFloat(180 * scale));
    if (state.failure) |err| return err;
    if (hook.watch == null or hook.fired) std.debug.print("projection first frame closing={} watch={?} fired={}\n", .{ closing, hook.watch, hook.fired });
    try std.testing.expect(hook.watch != null and !hook.fired);
    const Planner = struct {
        plans: [2]*editing.ProjectionPlan,
        fn build(ptr: *anyopaque, _: [2]*editing.LayoutProbe) !editing.PairProjection {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return .{ .plans = .{ self.plans[0], self.plans[1] } };
        }
    };
    var planner: Planner = .{ .plans = .{ try editing.ProjectionPlan.create(allocator, a, &.{.{ .line = 1, .gap_before = 8 }}, .{}), try editing.ProjectionPlan.create(allocator, b, &.{.{ .line = 1, .gap_before = 8 }}, .{}) } };
    defer for (planner.plans) |plan| plan.close() catch unreachable;
    defer for (adapters) |adapter| adapter.setProjection(null) catch unreachable;
    parameters[0].font.size = 18;
    parameters[1].font.size = 18;
    const outcome = try editing.projectPair(hook.window, adapters[0], adapters[1], rectangles, parameters, .{ .context = &planner, .build = Planner.build });
    if (!hook.fired or outcome.current or outcome.post_publish_error == null) std.debug.print("projection retired frame closing={} fired={} hook_error={?} current={} post_error={?}\n", .{ closing, hook.fired, hook.failure, outcome.current, outcome.post_publish_error });
    try std.testing.expect(hook.fired);
    if (hook.failure) |err| return err;
    try std.testing.expect(!outcome.current and outcome.post_publish_error != null);
    for (adapters, planner.plans) |adapter, plan| try std.testing.expectEqual(@as(?*editing.ProjectionPlan, plan), try adapter.projectionPlan());
}
