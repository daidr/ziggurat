//! Frameless window with a title bar drawn by the application.
//!
//! The window is created with `decoration = .custom`: the system frame is gone
//! and the view draws its own title bar. A hit-test handler reports the title
//! area as `.caption`, so the platform moves the window natively and toggles
//! maximize on a double-click; the minimize, maximize/restore and close
//! buttons answer `.client` and call `Window.perform` / `requestClose`. The
//! `resize_border` edges around the client area resize the window.
//!
//! Where the display cannot host custom decoration (for example Wayland), the
//! example falls back to the system frame and says so.
//!
//! Run with `zig build run-frameless`.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");

const title_height: f32 = 40;
const title_text = "Ziggurat / Frameless";

const Chrome = struct {
    window: ?z.Window = null,
    caps: ?z.WindowCapabilities = null,
    custom: bool = true,
    /// Window bounds of the draggable title area from the last arranged frame.
    caption: ?view.Rect = null,
    last_error: ?anyerror = null,

    /// Native hit-test policy. It runs synchronously for pointer input, so it
    /// only compares against the rectangle recorded by the last frame.
    fn hit(ptr: *anyopaque, _: z.Window, point: z.Point) z.WindowHit {
        const self: *Chrome = @ptrCast(@alignCast(ptr));
        const r = self.caption orelse return .client;
        const inside = point.x >= r.x and point.y >= r.y and point.x < r.x + r.width and point.y < r.y + r.height;
        return if (inside) .caption else .client;
    }

    /// The draggable title area is an embedded leaf: it paints the title and
    /// learns its bounds after every arranged frame.
    fn dragArea(self: *Chrome) view.Embed {
        return .{ .context = self, .measure = measureDrag, .place = placeDrag, .paint = paintDrag };
    }
    fn measureDrag(_: *anyopaque, _: view.Theme) view.layout.Measurement {
        return .{ .minimum = .{ .width = 40, .height = title_height }, .preferred = .{ .width = 240, .height = title_height } };
    }
    fn placeDrag(ptr: *anyopaque, _: u64, bounds: view.Rect) void {
        const self: *Chrome = @ptrCast(@alignCast(ptr));
        self.caption = bounds;
    }
    fn paintDrag(_: *anyopaque, frame: *ui.Frame, _: u64, bounds: view.Rect) anyerror!void {
        frame.labelFont(.{ .x = bounds.x + 12, .y = bounds.y + 8, .width = @max(bounds.width - 12, 0), .height = 24 }, title_text, 0xf2f5f8, .{ .size = 15, .weight = .semibold });
    }

    fn command(self: *Chrome, action: z.WindowAction) void {
        const window = self.window orelse return;
        window.perform(action) catch |err| {
            self.last_error = err;
        };
    }

    fn build(self: *Chrome, v: *view.View) anyerror!void {
        const state: ?z.WindowState = if (self.window) |window| window.state() catch null else null;
        const maximized = if (state) |s| s.maximized else false;
        const fullscreen = if (state) |s| s.fullscreen else false;

        // Title bar: drag area, then the window buttons.
        if (self.custom and !fullscreen) {
            try v.row(.{ .self_align = .stretch, .background = 0x23313f, .alignment = .center, .gap = 4, .padding = .{ .right = 6 } });
            try v.embed(self.dragArea(), .{ .grow = 1 });
            if (try v.button("Minimize", .{ .name = "Minimize window" })) self.command(.minimize);
            if (try v.button(if (maximized) "Restore" else "Maximize", .{})) self.command(if (maximized) .restore else .maximize);
            if (try v.button("Close", .{ .name = "Close window" })) {
                if (self.window) |window| _ = window.requestClose() catch |err| {
                    self.last_error = err;
                };
            }
            try v.end();
        } else self.caption = null;

        try v.column(.{ .grow = 1, .self_align = .stretch, .padding = view.Insets.all(24), .gap = 12 });
        try v.text("Custom window chrome", .{ .font = view.Font.heading3 });
        if (self.custom) {
            try v.text("Drag the dark bar to move the window; double-click it to maximize or restore.", .{});
            try v.text("Drag any edge or corner to resize.", .{});
        } else {
            try v.text("This display cannot host custom decoration, so the system frame is used.", .{ .color = 0xa04020 });
        }
        if (self.caps) |caps| {
            try v.textf("Native move/resize: {s}   System menu: {s}   Fullscreen: {s}", .{ yesNo(caps.native_move_resize), yesNo(caps.system_menu), yesNo(caps.fullscreen) }, .{ .color = 0x536475 });
            if (caps.fullscreen) {
                try v.row(.{ .gap = 8 });
                if (try v.button(if (fullscreen) "Leave fullscreen" else "Enter fullscreen", .{})) {
                    if (self.window) |window| window.setFullscreen(!fullscreen) catch |err| {
                        self.last_error = err;
                    };
                }
                try v.end();
            }
        }
        if (self.last_error) |err| try v.textf("Last error: {s}", .{@errorName(err)}, .{ .color = 0xa04020 });
        try v.end();
    }
};

fn yesNo(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    var chrome: Chrome = .{};
    var storage: view.Storage(64, 2048) = .{};
    // The title bar spans the full width, so the root has no padding.
    var host = view.Host.init(&chrome, Chrome.build, storage.buffers(), .{ .root = .{ .alignment = .stretch } });
    const app = try z.App.init(gpa.allocator());
    defer app.deinit();

    // `chrome` is the hit-test context; it outlives the window's on_closed.
    const options: z.WindowOptions = .{
        .title = title_text,
        .width = 640,
        .height = 400,
        .min_width = 360,
        .min_height = 220,
        .decoration = .custom,
        .resize_border = 6,
        .hit_test = .{ .context = &chrome, .query = Chrome.hit },
    };
    const window = app.createWindow(options) catch |err| switch (err) {
        error.UnsupportedCapability => fallback: {
            chrome.custom = false;
            var system = options;
            system.decoration = .system;
            system.hit_test = null;
            break :fallback try app.createWindow(system);
        },
        else => return err,
    };
    chrome.window = window;
    chrome.caps = window.capabilities() catch null;
    try host.attach(window);
    window.show();
    try app.run();
}

test "title bar buttons and fallback text" {
    var chrome: Chrome = .{};
    var storage: view.Storage(64, 2048) = .{};
    var h = view.Harness.init(&chrome, Chrome.build, storage.buffers(), .{});
    try h.render();
    _ = try h.find(.{ .text = "Maximize" });
    chrome.custom = false;
    try h.render();
    try std.testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Close" }));
}
