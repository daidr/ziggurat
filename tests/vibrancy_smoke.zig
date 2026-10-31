//! Transparent windows and materials against the real session: frames that
//! start transparent and keep their alpha, the material state of a window,
//! the composed GPU swap chain of a Windows window created with a material,
//! and its menus, which open in a popup instead of a menu bar.
const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const system = @import("ziggurat_system");
const Watchdog = @import("watchdog.zig").Watchdog;
const exitAfter = @import("watchdog.zig").exitAfter;

const windows = builtin.os.tag == .windows;
const linux = builtin.os.tag == .linux;
const c = @import("ziggurat_c_win32");
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlc_test_raw_argb(*anyopaque, u32, u32) u32;
extern fn gdk_screen_get_default() ?*anyopaque;
extern fn gdk_screen_get_rgba_visual(*anyopaque) ?*anyopaque;

const width = 120;
const height = 80;
const block: ui.Rect = .{ .x = 10, .y = 10, .width = 40, .height = 30 };

const Surface = struct {
    context: ui.Context = undefined,
    paints: usize = 0,
    /// Moves the block between frames: a transparent frame must not keep
    /// what the previous one drew.
    shift: f32 = 0,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Surface = @ptrCast(@alignCast(ptr));
        self.paints += 1;
        frame.rect(.{ .x = block.x + self.shift, .y = block.y, .width = block.width, .height = block.height }, 0x2050a0);
    }
    fn action(_: *anyopaque, _: u64) void {}
    fn paint(self: *Surface, window: z.Window) !void {
        const before = self.paints;
        if (windows) {
            _ = c.SendMessageW(@ptrCast(window.nativeHandle()), c.WM_PAINT, 0, 0);
        } else {
            const scope = window.beginCallback().?;
            defer scope.end();
            zlg_test_paint(scope.record.native.native.?, width, height);
        }
        try std.testing.expectEqual(before + 1, self.paints);
    }
    fn argb(self: *Surface, x: f32, y: f32) u32 {
        const size = self.context.last_paint_size.?;
        const px: u32 = @intFromFloat(@floor(x * size.scale));
        const py: u32 = @intFromFloat(@floor(y * size.scale));
        if (windows) return self.context.renderer.pixels.?[@as(usize, py) * self.context.renderer.width + px];
        return zlc_test_raw_argb(self.context.renderer.native.?, px, py);
    }
    /// Whether the last frame was drawn in memory rather than on the GPU.
    fn software(self: *const Surface) bool {
        return @TypeOf(self.context.gpu_renderer) == void or self.context.gpu_unavailable;
    }
};

const State = struct {
    app: *z.App,
    window: z.Window = undefined,
    owner: system.Owner = undefined,
    surface: Surface = .{},
    menu_seen: bool = false,
    caps: z.WindowCapabilities = undefined,
    attempts: usize = 0,
    failure: ?anyerror = null,
    fn fail(self: *State, err: anyerror) void {
        std.debug.print("vibrancy smoke failed: {s}\n", .{@errorName(err)});
        if (self.failure == null) self.failure = err;
        self.app.quit();
    }
    fn onAction(_: *anyopaque, _: z.Window, _: system.Action) void {}
    fn start(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.run() catch |err| self.fail(err);
    }
    fn run(self: *State) !void {
        const window = self.window;
        const caps = try window.capabilities();
        self.caps = caps;
        try std.testing.expectEqual(z.Vibrancy.sidebar, try window.vibrancy());
        if (windows) {
            try std.testing.expectEqual(backdropsAvailable(), caps.vibrancy);
            try std.testing.expectEqual(caps.vibrancy, caps.transparent);
        } else {
            // GTK has no materials; frames keep alpha with an RGBA visual.
            try std.testing.expect(!caps.vibrancy);
            const screen = gdk_screen_get_default().?;
            try std.testing.expectEqual(gdk_screen_get_rgba_visual(screen) != null, caps.transparent);
        }
        try std.testing.expectEqual(caps.vibrancy, window.showsVibrancy());

        try self.surface.paint(window);
        if (windows and caps.transparent and self.surface.software()) {
            // Software frames show through DirectComposition too.
            try std.testing.expect(self.surface.context.renderer.composed != null);
        }
        if (caps.transparent and self.surface.software()) {
            try std.testing.expectEqual(@as(u32, 0), self.surface.argb(80, 60));
            try std.testing.expectEqual(@as(u32, 0xff2050a0), self.surface.argb(20, 20));
            self.surface.shift = 50;
            try self.surface.paint(window);
            try std.testing.expectEqual(@as(u32, 0), self.surface.argb(20, 20));
            try std.testing.expectEqual(@as(u32, 0xff2050a0), self.surface.argb(70, 20));
        }
        if (@TypeOf(self.surface.context.gpu_renderer) != void) if (caps.vibrancy and !self.surface.context.gpu_unavailable) {
            // The swap chain is composed, not bound to a window.
            const gpu = &self.surface.context.gpu_renderer;
            try std.testing.expect(gpu.surfaceForTest() != null);
            try std.testing.expect(gpu.swapchainWindowForTest() == null);
            try std.testing.expect(gpu.stats().presents > 0);
        };

        try window.setVibrancy(.acrylic);
        try std.testing.expectEqual(z.Vibrancy.acrylic, try window.vibrancy());
        try window.setVibrancy(.none);
        try std.testing.expect(!window.showsVibrancy());
        try window.setVibrancy(.mica);
        try std.testing.expectEqual(caps.vibrancy, window.showsVibrancy());

        try self.owner.setMenu(&.{
            .{ .id = 1, .kind = .submenu, .label = "&File" },
            .{ .id = 2, .parent = 1, .label = "&Open" },
        });
        if (windows) {
            const hwnd: c.HWND = @ptrCast(window.nativeHandle().?);
            // A window that shows a material has no menu bar.
            try std.testing.expectEqual(caps.vibrancy, c.GetMenu(hwnd) == null);
            if (caps.vibrancy) {
                // F10 opens the menus in a popup, a native menu loop in
                // which App tasks keep running.
                _ = c.PostMessageW(hwnd, c.WM_SYSCOMMAND, c.SC_KEYMENU, 0);
                try self.app.post(.{ .context = self, .call = watchMenu });
                return;
            }
        }
        self.finish();
    }
    fn watchMenu(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        var info = std.mem.zeroes(c.GUITHREADINFO);
        info.cbSize = @sizeOf(c.GUITHREADINFO);
        if (c.GetGUIThreadInfo(0, &info) != 0 and info.flags & c.GUI_POPUPMENUMODE != 0) {
            self.menu_seen = true;
            _ = c.EndMenu();
            self.app.post(.{ .context = self, .call = finishTask }) catch |err| self.fail(err);
            return;
        }
        self.attempts += 1;
        if (self.attempts > 2000) return self.fail(error.MenuPopupNotShown);
        zio.sleep(std.time.ns_per_ms);
        self.app.post(.{ .context = self, .call = watchMenu }) catch |err| self.fail(err);
    }
    fn finishTask(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.finish();
    }
    fn finish(self: *State) void {
        self.owner.clearMenu() catch |err| return self.fail(err);
        self.app.quit();
    }
};

fn backdropsAvailable() bool {
    var info: std.os.windows.RTL_OSVERSIONINFOW = undefined;
    info.dwOSVersionInfoSize = @sizeOf(std.os.windows.RTL_OSVERSIONINFOW);
    return std.os.windows.ntdll.RtlGetVersion(&info) == .SUCCESS and (info.dwMajorVersion > 10 or (info.dwMajorVersion == 10 and info.dwBuildNumber >= 22621));
}

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    try exitAfter("vibrancy smoke", 120);
    const app = try z.App.init(allocator);
    defer app.deinit();
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();

    var state: State = .{ .app = app };
    state.window = try app.createWindow(.{ .title = "Vibrancy", .width = width, .height = height, .transparent = true, .vibrancy = .sidebar });
    state.surface.context = ui.Context.init(&state.surface, Surface.draw, Surface.action);
    state.surface.context.semantics_enabled = false;
    try state.surface.context.attach(state.window);
    state.owner = system.Owner.init(&state, State.onAction);
    try state.owner.attach(state.window);
    state.window.show();

    // A window without a material keeps opaque frames.
    const plain = try app.createWindow(.{ .title = "Plain", .width = width, .height = height });
    const plain_caps = try plain.capabilities();
    try std.testing.expect(!plain_caps.transparent and !plain_caps.vibrancy);
    try plain.setVibrancy(.mica);
    try std.testing.expect(!plain.showsVibrancy());
    _ = try plain.destroy();

    try app.post(.{ .context = &state, .call = State.start });
    try app.run();
    if (state.failure) |err| return err;
    const caps = state.caps;
    if (windows and caps.vibrancy) try std.testing.expect(state.menu_seen);
    try state.owner.detach();
    std.debug.print("vibrancy smoke passed (transparent {}, material {})\n", .{ caps.transparent, caps.vibrancy });
}
