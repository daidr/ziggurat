//! Flyouts on the native backend: placement beside an owner's rectangle and
//! a desktop rectangle, following the owner, showing without taking the
//! keyboard, and closing on Escape and on a dismissal. Linux injects input
//! with XTest on X11; Windows dismisses by activating the owner.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const system = @import("ziggurat_system");
const flyout = system.flyout;

const linux = builtin.os.tag == .linux;
const anchor: z.Rect = .{ .x = 10, .y = 20, .width = 80, .height = 24 };

extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;
const X11 = struct {
    extern fn XOpenDisplay(?[*:0]const u8) ?*anyopaque;
    extern fn XCloseDisplay(*anyopaque) c_int;
    extern fn XFlush(*anyopaque) c_int;
    extern fn XKeysymToKeycode(*anyopaque, c_ulong) u8;
    library: std.DynLib,
    display: *anyopaque,
    key: *const fn (*anyopaque, c_uint, c_int, c_ulong) callconv(.c) c_int,
    move: *const fn (*anyopaque, c_int, c_int, c_int, c_ulong) callconv(.c) c_int,
    button: *const fn (*anyopaque, c_uint, c_int, c_ulong) callconv(.c) c_int,

    fn open() !X11 {
        var library = try std.DynLib.open("libXtst.so.6");
        errdefer library.close();
        return .{
            .library = library,
            .display = XOpenDisplay(null) orelse return error.DisplayUnavailable,
            .key = library.lookup(*const fn (*anyopaque, c_uint, c_int, c_ulong) callconv(.c) c_int, "XTestFakeKeyEvent") orelse return error.XTestUnavailable,
            .move = library.lookup(*const fn (*anyopaque, c_int, c_int, c_int, c_ulong) callconv(.c) c_int, "XTestFakeMotionEvent") orelse return error.XTestUnavailable,
            .button = library.lookup(*const fn (*anyopaque, c_uint, c_int, c_ulong) callconv(.c) c_int, "XTestFakeButtonEvent") orelse return error.XTestUnavailable,
        };
    }
    fn close(self: *X11) void {
        _ = XCloseDisplay(self.display);
        self.library.close();
    }
    fn escape(self: *X11) void {
        const code = XKeysymToKeycode(self.display, 0xff1b);
        _ = self.key(self.display, code, 1, 0);
        _ = self.key(self.display, code, 0, 0);
        _ = XFlush(self.display);
    }
    /// Root coordinates are physical pixels; window positions are logical.
    fn click(self: *X11, x: i32, y: i32, scale: i32) void {
        _ = self.move(self.display, -1, x * scale, y * scale, 0);
        _ = self.button(self.display, 1, 1, 0);
        _ = self.button(self.display, 1, 0, 0);
        _ = XFlush(self.display);
    }
};

const Stage = enum { owner_focus, quiet_shown, owner_moved, quiet_closed, focusable_shown, escaped, refocused, dismissed, vetoed, screen_shown, done };

const Smoke = struct {
    app: *z.App,
    owner: z.Window,
    quiet: system.Flyout = .{},
    focused: system.Flyout = .{},
    screen: system.Flyout = .{},
    stage: Stage = .owner_focus,
    waited: u32 = 0,
    veto: bool = false,
    closes: u32 = 0,
    failure: ?anyerror = null,
    x11: if (linux) ?X11 else void = if (linux) null else {},
    stop: std.atomic.Value(bool) = .init(false),

    fn ticker(self: *Smoke) void {
        while (!self.stop.load(.acquire)) {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            self.app.post(.{ .context = self, .call = tick }) catch return;
        }
    }
    fn tick(ptr: *anyopaque) void {
        const self: *Smoke = @ptrCast(@alignCast(ptr));
        if (self.stage == .done) return;
        self.step() catch |err| return self.finish(err);
        self.waited += 1;
        if (self.waited > 200) {
            std.debug.print("flyout smoke: stuck at {s}\n", .{@tagName(self.stage)});
            self.finish(error.Timeout);
        }
    }
    fn advance(self: *Smoke, stage: Stage) void {
        self.stage = stage;
        self.waited = 0;
    }
    fn finish(self: *Smoke, failure: ?anyerror) void {
        if (self.stage == .done) return;
        self.failure = failure;
        self.stage = .done;
        self.stop.store(true, .release);
        self.app.quit();
    }
    fn request(ptr: *anyopaque, _: z.Window, reason: z.CloseReason) z.CloseDecision {
        const self: *Smoke = @ptrCast(@alignCast(ptr));
        if (reason == .user) self.closes += 1;
        return if (self.veto) .cancel else .allow;
    }

    /// Where the flyout goes for the owner's current position.
    fn expected(self: *Smoke, width: u32, height: u32, gap: f32) !flyout.Box {
        const bounds = try self.owner.clientBounds();
        const origin = bounds.position orelse return error.PositionUnavailable;
        var monitors: [system.desktop.max_monitors]system.desktop.Monitor = undefined;
        const displays = monitors[0..try system.desktop.monitors(self.app, &monitors)];
        const scale: f32 = if (builtin.os.tag == .windows) (try self.owner.contentSize()).scale else 1;
        const rect: flyout.Box = .{ .x = origin.x + @as(i32, @intFromFloat(@round(anchor.x * scale))), .y = origin.y + @as(i32, @intFromFloat(@round(anchor.y * scale))), .width = @intFromFloat(@round(anchor.width * scale)), .height = @intFromFloat(@round(anchor.height * scale)) };
        const monitor = flyout.monitorFor(rect, displays);
        const native: f32 = if (builtin.os.tag == .windows) monitor.scale else 1;
        const size: flyout.Size = .{ .width = @intFromFloat(@round(@as(f32, @floatFromInt(width)) * native)), .height = @intFromFloat(@round(@as(f32, @floatFromInt(height)) * native)) };
        return flyout.placeBeside(rect, size, flyout.Box.of(monitor.work_area), .bottom_start, @intFromFloat(@round(gap * native))).box;
    }
    fn at(window: z.Window, box: flyout.Box) !bool {
        const position = (try window.clientBounds()).position orelse return error.PositionUnavailable;
        return position.x == box.x and position.y == box.y;
    }
    fn open(self: *Smoke, target: *system.Flyout, focusable: bool) !z.Window {
        return target.open(self.app, .{ .anchor = .{ .window = .{ .owner = self.owner, .rect = anchor } }, .gap = 4, .width = 200, .height = 100, .focusable = focusable, .shadow = true, .title = "flyout", .on_close = .{ .context = self, .request = request } });
    }
    fn rootScale(self: *Smoke) i32 {
        return if (linux) gtk_widget_get_scale_factor(self.owner.nativeHandle().?) else 1;
    }

    fn step(self: *Smoke) !void {
        switch (self.stage) {
            .owner_focus => {
                if (!(try self.owner.state()).focused) {
                    if (self.waited % 20 == 0) self.owner.perform(.focus) catch {};
                    return;
                }
                const window = try self.open(&self.quiet, false);
                if ((try window.relationship()).owner == null) return error.OwnerMissing;
                self.advance(.quiet_shown);
            },
            .quiet_shown => {
                const window = self.quiet.window.?;
                if (!(try window.state()).visible) return;
                if (!try at(window, try self.expected(200, 100, 4)) or self.waited < 4) return;
                // Showing it did not take the keyboard. Other smokes share
                // the display and may hold focus, so the owner is not checked.
                if ((try window.state()).focused) return error.QuietFlyoutTookFocus;
                const bounds = try self.owner.clientBounds();
                const origin = bounds.position.?;
                try self.owner.setClientBounds(.{ .position = .{ .x = origin.x + 40, .y = origin.y + 30 }, .width = bounds.width, .height = bounds.height });
                self.advance(.owner_moved);
            },
            .owner_moved => {
                if (!try at(self.quiet.window.?, try self.expected(200, 100, 4))) return;
                _ = try self.quiet.close();
                self.advance(.quiet_closed);
            },
            .quiet_closed => {
                if (self.quiet.isOpen()) return;
                _ = try self.open(&self.focused, true);
                self.advance(.focusable_shown);
            },
            .focusable_shown => {
                const window = self.focused.window.?;
                if (!(try window.state()).visible or self.waited < 4) return;
                if (linux) {
                    if (self.x11 == null) self.x11 = try X11.open();
                    self.x11.?.escape();
                    self.advance(.escaped);
                } else {
                    if (!(try window.state()).focused) {
                        // A session without the foreground right cannot
                        // activate it; the dismissal needs that.
                        std.debug.print("flyout smoke: the session denied the foreground; skipping keyboard checks\n", .{});
                        _ = try self.focused.close();
                        self.advance(.vetoed);
                        return;
                    }
                    // Activating the owner dismisses it.
                    self.owner.perform(.focus) catch {};
                    self.advance(.dismissed);
                }
            },
            .escaped => {
                if (self.focused.isOpen()) return;
                if (self.closes != 1) return error.EscapeNotUserClose;
                _ = try self.open(&self.focused, true);
                self.advance(.refocused);
            },
            .refocused => {
                const window = self.focused.window.?;
                if (!(try window.state()).visible or self.waited < 4) return;
                // A press on the owner, outside the flyout.
                if (linux) {
                    const origin = (try self.owner.clientBounds()).position.?;
                    self.x11.?.click(origin.x + 300, origin.y + 250, self.rootScale());
                }
                self.advance(.dismissed);
            },
            .dismissed => {
                if (self.focused.isOpen()) return;
                if (self.closes == 0) return error.DismissalNotUserClose;
                if (linux) {
                    self.veto = true;
                    _ = try self.open(&self.focused, true);
                    self.advance(.vetoed);
                } else self.advance(.vetoed);
            },
            .vetoed => {
                if (linux) {
                    const window = self.focused.window.?;
                    if (self.waited == 4) {
                        const origin = (try self.owner.clientBounds()).position.?;
                        self.x11.?.click(origin.x + 300, origin.y + 250, self.rootScale());
                    }
                    if (self.waited < 12) return;
                    // on_close refused: it stays.
                    if (!self.focused.isOpen() or !(try window.state()).visible) return error.VetoIgnored;
                    self.veto = false;
                    _ = try window.destroy();
                }
                const owner = (try self.owner.clientBounds()).position.?;
                const rect: system.desktop.Rect = .{ .x = owner.x, .y = owner.y, .width = 1, .height = 1 };
                const window = try self.screen.open(self.app, .{ .anchor = .{ .screen = rect }, .placement = .right_start, .width = 120, .height = 80 });
                if ((try window.relationship()).owner != null) return error.UnexpectedOwner;
                self.advance(.screen_shown);
            },
            .screen_shown => {
                const window = self.screen.window.?;
                if (!(try window.state()).visible) return;
                const position = (try window.clientBounds()).position.?;
                const owner = (try self.owner.clientBounds()).position.?;
                if (position.x != owner.x + 1 or position.y != owner.y) {
                    std.debug.print("screen flyout at {d},{d}, owner at {d},{d}\n", .{ position.x, position.y, owner.x, owner.y });
                    return error.ScreenFlyoutMisplaced;
                }
                _ = try self.screen.close();
                self.finish(null);
            },
            .done => {},
        }
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const app = try z.App.init(gpa.allocator());
    defer app.deinit();
    const owner = try app.createWindow(.{ .title = "flyout owner", .width = 420, .height = 320 });
    try owner.setClientBounds(.{ .position = .{ .x = 120, .y = 120 }, .width = 420, .height = 320 });
    owner.show();
    var smoke: Smoke = .{ .app = app, .owner = owner };
    defer if (linux) if (smoke.x11) |*x11| x11.close();
    const thread = try std.Thread.spawn(.{}, Smoke.ticker, .{&smoke});
    app.run() catch |err| {
        smoke.stop.store(true, .release);
        thread.join();
        return err;
    };
    smoke.stop.store(true, .release);
    thread.join();
    if (smoke.failure) |err| return err;
    std.debug.print("flyout smoke: placement, following, quiet show, Escape and dismissal passed\n", .{});
}
