const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const view = @import("ziggurat_view");
const web = @import("ziggurat_webview");
const embedded = @import("ziggurat_webview_view");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn g_timeout_add(c_uint, *const fn (*anyopaque) callconv(.c) c_int, *anyopaque) c_uint;
var active: ?*State = null;

const width = 480;
const height = 320;
const Phase = enum { loading, shown, hidden, again, done };

const State = struct {
    app: *z.App,
    window: z.Window = undefined,
    host: *view.Host = undefined,
    web_views: *embedded.WebViews = undefined,
    item: embedded.WebView = undefined,
    page: web.View = undefined,
    show: bool = true,
    loaded: bool = false,
    phase: Phase = .loading,
    page_id: ?web.PageId = null,
    failure: ?anyerror = null,

    fn build(self: *State, v: *view.View) !void {
        try v.row(.{ .grow = 1, .alignment = .stretch, .gap = 0, .padding = view.Insets.all(0) });
        try v.text("Native sidebar", .{ .width = 120 });
        if (self.show) try self.item.show(v, .{ .grow = 1 });
        try v.end();
    }
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("embedded web view {s}: {s}\n", .{ @tagName(self.phase), @errorName(err) });
        self.app.quit();
    }
    fn event(ptr: *anyopaque, _: *web.View, input: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (input) {
            .failed, .process_failed => self.fail(error.NativePageFailed),
            else => {},
        }
    }
    fn pageEvent(ptr: *anyopaque, _: *web.View, input: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (input != .completed) return;
        if (!input.completed.success) return self.fail(error.LoadFailed);
        self.loaded = true;
    }
    fn paint(self: *State) void {
        if (builtin.os.tag == .windows) {
            const hwnd: c.HWND = self.window.nativeHandle();
            _ = c.InvalidateRect(hwnd, null, 0);
            _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
            return;
        }
        const scope = self.window.beginCallback() orelse return;
        defer scope.end();
        zlg_test_paint(scope.record.native.native.?, width, height);
    }
    fn leaf(self: *State) ?view.Rect {
        for (self.host.view.nodes()) |node| if (node.kind == .embed) return node.bounds;
        return null;
    }
    fn tick(ptr: *anyopaque) callconv(.c) c_int {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.step() catch |err| {
            self.fail(err);
            return 0;
        };
        return @intFromBool(self.phase != .done);
    }
    fn windowsTick(_: c.HWND, _: c.UINT, _: c.UINT_PTR, _: c.DWORD) callconv(.winapi) void {
        const self = active orelse return;
        if (self.phase != .done and self.failure == null) _ = tick(self);
    }
    fn step(self: *State) !void {
        if (self.host.last_error) |err| return err;
        if (self.web_views.takeError()) |err| return err;
        self.paint();
        const snapshot = try self.item.region.?.snapshot();
        switch (self.phase) {
            .loading => if (self.loaded and snapshot.viewport.visible) {
                const bounds = self.leaf() orelse return error.MissingLeaf;
                try std.testing.expect(bounds.x >= 120 and bounds.width > 0 and bounds.height > 0);
                try std.testing.expectEqual(bounds, snapshot.viewport.bounds);
                self.page_id = self.page.pageId();
                self.show = false;
                self.window.invalidate();
                self.phase = .shown;
            },
            .shown => if (!snapshot.viewport.visible) {
                try std.testing.expect(self.leaf() == null);
                self.show = true;
                self.window.invalidate();
                self.phase = .hidden;
            },
            .hidden => if (snapshot.viewport.visible) {
                // Hiding kept the page where it was.
                try std.testing.expectEqual(self.page_id, self.page.pageId());
                try std.testing.expectEqual(self.leaf().?, snapshot.viewport.bounds);
                self.phase = .done;
                self.app.quit();
            },
            else => {},
        }
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    // WebView2 keeps its profile in an absolute folder, prepared off the
    // main thread; WebKitGTK runs the page in an ephemeral session.
    var temporary = zio.tmpDir(.{});
    defer temporary.cleanup();
    var profile: ?[]u8 = null;
    defer if (profile) |path| allocator.free(path);
    if (builtin.os.tag == .windows) {
        const Prepare = struct {
            fn run(dir: std.Io.Dir, gpa_allocator: std.mem.Allocator, out: *?[]u8) void {
                out.* = zio.realPathAlloc(dir, ".", gpa_allocator) catch null;
            }
        };
        const worker = try std.Thread.spawn(.{}, Prepare.run, .{ temporary.dir, allocator, &profile });
        worker.join();
        if (profile == null) return error.ProfileUnavailable;
    }
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .app = app };
    var storage: view.Storage(32, 256) = .{};
    var host = view.Host.init(&state, State.build, storage.buffers(), .{ .root = .{ .padding = view.Insets.all(0), .alignment = .stretch } });
    host.context.render_mode = .gdi;
    state.host = &host;
    state.window = try app.createWindow(.{ .width = width, .height = height });
    defer _ = state.window.destroy() catch {};
    const owner = try z.composition.Owner.create(allocator, state.window, .{ .capacity = 4 });
    defer owner.close() catch {};
    var web_views = embedded.WebViews.init(&host, owner);
    state.web_views = &web_views;
    host.options.after_frame = web_views.hook();
    _ = try host.attachBackdrop(owner);
    state.page = web.View.init(allocator, &state, State.event);
    try web_views.add(&state.item, &state.page, .{ .html = "<!doctype html><p>page</p>", .storage = if (builtin.os.tag == .windows) .profile else .ephemeral, .user_data_folder = profile orelse "", .page_listener = .{ .context = &state, .event = State.pageEvent } });
    active = &state;
    defer active = null;
    if (builtin.os.tag == .windows) {
        const timer = c.SetTimer(null, 0, 20, @ptrCast(&State.windowsTick));
        if (timer == 0) return error.CreateTimerFailed;
    } else _ = g_timeout_add(20, State.tick, &state);
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and state.phase == .done);
    state.item.remove();
    _ = try state.window.destroy();
    std.debug.print("embedded web view: placed on its leaf, hidden when not built, shown again with the same page\n", .{});
}
