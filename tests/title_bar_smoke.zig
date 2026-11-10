//! Hidden title bars (WindowOptions.title_bar): the system's window controls
//! stay over the content of a `.custom` window, `Window.titleBar` says where
//! they are, they hide in full screen and with `hide_window_buttons`, and
//! `title_bar_height` and `traffic_light_position` move them.
const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const Watchdog = @import("watchdog.zig").Watchdog;

pub const panic = std.debug.FullPanic(@import("macos_panic.zig").panic);

extern fn gtk_widget_get_mapped(*anyopaque) c_int;

const Expect = enum { plain, sized, inset, hidden_buttons };

const Probe = struct {
    window: z.Window = undefined,
    expect: Expect,
    stage: enum { starting, fullscreen, unfull, done } = .starting,
    pending: bool = false,
    closed: bool = false,
    fullscreen_checked: bool = false,
    first: z.TitleBar = .{},

    fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (window.app.phase == .stopping or window.app.phase == .stopped or self.pending or self.stage == .done) return;
        if (value == .window_state or value == .resize or value == .focus) {
            self.pending = true;
            window.app.post(.{ .context = self, .call = advance }) catch unreachable;
        }
    }
    fn detach(_: *anyopaque) void {}
    fn notify(ptr: *anyopaque, _: z.Window) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.closed = true;
    }
    fn advance(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.pending = false;
        self.step() catch |err| std.debug.panic("title bar {s} stage {s}: {s}", .{ @tagName(self.expect), @tagName(self.stage), @errorName(err) });
    }
    fn step(self: *Probe) !void {
        if (self.window.isClosed()) return;
        const state = try self.window.state();
        switch (self.stage) {
            .starting => {
                if (!state.visible or state.fullscreen) return;
                if (builtin.os.tag == .linux and gtk_widget_get_mapped(self.window.nativeHandle().?) == 0) return;
                const bar = state.title_bar;
                try std.testing.expectEqual(bar, try self.window.titleBar());
                if (self.expect == .hidden_buttons) {
                    try std.testing.expectEqual(z.TitleBar{}, bar);
                    return self.finish();
                }
                // Linux shows the buttons the desktop's layout names, here
                // the default's close at the right.
                if (bar.left + bar.right == 0) return;
                try std.testing.expect(bar.height > 0 and bar.bottom > 0 and bar.bottom <= bar.height);
                switch (builtin.os.tag) {
                    .windows => {
                        try std.testing.expectEqual(@as(f32, if (self.expect == .sized) 44 else 32), bar.height);
                        try std.testing.expectEqual(bar.height, bar.bottom);
                        try std.testing.expectEqual(@as(f32, 46 * 3), bar.right);
                        try std.testing.expectEqual(@as(f32, 0), bar.left);
                    },
                    .linux => {
                        try std.testing.expectEqual(bar.height, bar.bottom);
                        if (self.expect == .sized) try std.testing.expectEqual(@as(f32, 44), bar.height);
                    },
                    .macos => {
                        // The traffic lights at the left, below the top edge.
                        try std.testing.expect(bar.left > 40 and bar.right == 0 and bar.bottom < bar.height);
                        if (self.expect == .inset) {
                            // The close button 20 from the left and 18 from
                            // the top: as much room below it as above.
                            try std.testing.expect(bar.left > 60);
                            try std.testing.expectEqual(bar.height, @round(bar.bottom + 18));
                        }
                    },
                    else => {},
                }
                self.first = bar;
                const caps = try self.window.capabilities();
                if (!caps.fullscreen or (builtin.os.tag == .linux and !caps.native_move_resize)) return self.finish();
                self.stage = .fullscreen;
                try self.window.setFullscreen(true);
            },
            .fullscreen => {
                if (!state.fullscreen) return;
                // The controls hide in full screen.
                try std.testing.expectEqual(z.TitleBar{}, state.title_bar);
                self.fullscreen_checked = true;
                self.stage = .unfull;
                try self.window.setFullscreen(false);
            },
            .unfull => {
                if (state.fullscreen or state.title_bar.left + state.title_bar.right == 0) return;
                try std.testing.expectEqual(self.first, state.title_bar);
                self.finish();
            },
            .done => {},
        }
    }
    fn finish(self: *Probe) void {
        self.stage = .done;
        _ = self.window.destroy() catch {};
    }
};

fn probe(allocator: std.mem.Allocator, expect: Expect) !bool {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var p: Probe = .{ .expect = expect };
    p.window = try app.createWindow(.{
        .title = "Title bar",
        .width = 480,
        .height = 320,
        .decoration = .custom,
        .title_bar = if (expect == .inset) .hidden_inset else .hidden,
        .title_bar_height = if (expect == .sized) 44 else 0,
        .traffic_light_position = if (expect == .inset) .{ .x = 20, .y = 18 } else null,
        .hide_window_buttons = expect == .hidden_buttons,
        .on_closed = .{ .context = &p, .notify = Probe.notify },
    });
    try p.window.setContent(.{ .context = &p, .event = Probe.event, .detach = Probe.detach });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try p.window.perform(.show);
    try app.run();
    if (watchdog.expired) std.debug.print("title bar timeout {s} {s}: {any}\n", .{ @tagName(expect), @tagName(p.stage), p.window.titleBar() catch z.TitleBar{} });
    try std.testing.expect(!watchdog.expired and p.closed);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    return p.fullscreen_checked;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(@import("macos_panic.zig").allocator_config) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    {
        // Only a .custom window, and no popup, hides its title bar.
        const app = try z.App.init(allocator);
        defer app.deinit();
        try std.testing.expectError(error.InvalidWindowDecoration, app.createWindow(.{ .title_bar = .hidden }));
        try std.testing.expectError(error.InvalidWindowDecoration, app.createWindow(.{ .decoration = .borderless, .title_bar = .hidden }));
        try std.testing.expectError(error.InvalidGeometry, app.createWindow(.{ .decoration = .custom, .title_bar = .hidden, .title_bar_height = 1000 }));
        // A window without a hidden title bar has no room for controls.
        const plain = try app.createWindow(.{ .decoration = .custom });
        try std.testing.expectEqual(z.TitleBar{}, try plain.titleBar());
        _ = try plain.destroy();
    }
    const fullscreen = try probe(allocator, .plain);
    _ = try probe(allocator, .sized);
    _ = try probe(allocator, .inset);
    _ = try probe(allocator, .hidden_buttons);
    std.debug.print("title bar smoke passed: controls over the content, sized and inset title bars, hidden buttons{s}\n", .{if (fullscreen) ", hidden in full screen" else ""});
}
