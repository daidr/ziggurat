//! A web view in a native scroll container with `scroll_to_container`:
//! the wheel over the page scrolls the container, not the page.
const std = @import("std");
const z = @import("ziggurat");
const view = @import("ziggurat_view");
const web = @import("ziggurat_webview");
const embedded = @import("ziggurat_webview_view");
const Watchdog = @import("watchdog.zig").Watchdog;
extern fn zws_scroll(*anyopaque, f64, f64, f64) c_int;
extern fn g_timeout_add(c_uint, *const fn (*anyopaque) callconv(.c) c_int, *anyopaque) c_uint;

const Phase = enum { loading, scrolled, done };

const State = struct {
    app: *z.App,
    window: z.Window = undefined,
    host: *view.Host = undefined,
    web_views: *embedded.WebViews = undefined,
    item: embedded.WebView = undefined,
    page: web.View = undefined,
    list: view.ScrollModel = .{},
    loaded: bool = false,
    phase: Phase = .loading,
    ticks: u32 = 0,
    failure: ?anyerror = null,

    fn build(self: *State, v: *view.View) !void {
        try v.scroll(&self.list, .{ .grow = 1, .self_align = .stretch });
        try v.text("Native header", .{ .height = 60 });
        try self.item.show(v, .{ .height = 400, .self_align = .stretch });
        try v.text("Native comments", .{ .height = 400 });
        try v.end();
    }
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("web view scroll {s}: {s}\n", .{ @tagName(self.phase), @errorName(err) });
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
    fn tick(ptr: *anyopaque) callconv(.c) c_int {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.step() catch |err| {
            self.fail(err);
            return 0;
        };
        return @intFromBool(self.phase != .done);
    }
    fn step(self: *State) !void {
        if (self.host.last_error) |err| return err;
        if (self.web_views.takeError()) |err| return err;
        self.ticks += 1;
        const snapshot = try self.item.region.?.snapshot();
        switch (self.phase) {
            .loading => if (self.loaded and snapshot.viewport.visible and self.ticks > 10) {
                if (self.list.offset.y != 0) return error.ScrolledEarly;
                // Two notches down over the page.
                if (zws_scroll(self.window.nativeHandle().?, 40, 40, 2) == 1) self.phase = .scrolled;
            },
            .scrolled => {
                if (self.list.offset.y > 0) {
                    self.phase = .done;
                    self.app.quit();
                } else if (self.ticks > 200) return error.ContainerDidNotScroll;
            },
            .done => {},
        }
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .app = app };
    var storage: view.Storage(32, 256) = .{};
    var host = view.Host.init(&state, State.build, storage.buffers(), .{ .root = .{ .padding = view.Insets.all(0), .alignment = .stretch } });
    host.context.render_mode = .gdi;
    state.host = &host;
    state.window = try app.createWindow(.{ .width = 360, .height = 300 });
    defer _ = state.window.destroy() catch {};
    const owner = try z.composition.Owner.create(allocator, state.window, .{ .capacity = 4 });
    defer owner.close() catch {};
    var web_views = embedded.WebViews.init(&host, owner);
    state.web_views = &web_views;
    host.options.after_frame = web_views.hook();
    _ = try host.attachBackdrop(owner);
    state.page = web.View.init(allocator, &state, State.event);
    try web_views.add(&state.item, &state.page, .{ .html = "<!doctype html><p>a page as tall as its view</p>", .storage = .ephemeral, .scroll_to_container = true, .page_listener = .{ .context = &state, .event = State.pageEvent } });
    state.window.show();
    _ = g_timeout_add(20, State.tick, &state);
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and state.phase == .done);
    state.item.remove();
    _ = try state.window.destroy();
    std.debug.print("web view scroll: the wheel over the page scrolled the native container ({d} DIPs)\n", .{state.list.offset.y});
}
