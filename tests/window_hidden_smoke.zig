//! A view that asks `View.windowHidden` builds once as its window hides,
//! out of sight, and again as it shows. No frame comes to a window out of
//! sight: macOS draws none for a window hidden or minimized, and Windows
//! sends a minimized window no WM_PAINT, so the hidden build must not wait
//! for one. Linux and Windows tell only that a window is minimized; Linux
//! has no window manager in CI that minimizes, so it is skipped there.
const std = @import("std");
const builtin = @import("builtin");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const view = @import("ziggurat_view");
const macos_panic = @import("macos_panic.zig");

pub const panic = std.debug.FullPanic(macos_panic.panic);
// The macOS unwinder cannot walk the driving thread's shallow stack.
pub const std_options: std.Options = .{ .allow_stack_tracing = builtin.os.tag != .macos };

const Seen = struct {
    builds: std.atomic.Value(u64) = .init(0),
    last_hidden: std.atomic.Value(bool) = .init(true),
    built_hidden: std.atomic.Value(bool) = .init(false),
    built_shown: std.atomic.Value(bool) = .init(false),
    fn build(self: *Seen, v: *view.View) anyerror!void {
        const hidden = v.windowHidden();
        self.last_hidden.store(hidden, .seq_cst);
        if (hidden) self.built_hidden.store(true, .seq_cst) else self.built_shown.store(true, .seq_cst);
        _ = self.builds.fetchAdd(1, .seq_cst);
        try v.text("WindowHidden", .{});
    }
};

const Step = enum { invalidate, focus, hide, show, minimize, restore, quit };

const Task = struct {
    driver: *Driver,
    step: Step,
};

const Driver = struct {
    app: *z.App,
    window: z.Window,
    seen: *Seen,
    failure: ?[]const u8 = null,
    /// One posted task for each step, so that steps queued together each
    /// run as posted.
    tasks: [std.enums.values(Step).len]Task = undefined,

    fn post(self: *Driver, step: Step) !void {
        const task = &self.tasks[@backingInt(step)];
        task.* = .{ .driver = self, .step = step };
        try self.app.post(.{ .context = task, .call = run });
    }
    fn run(ptr: *anyopaque) void {
        const task: *Task = @ptrCast(@alignCast(ptr));
        const self = task.driver;
        switch (task.step) {
            .invalidate => self.window.invalidate(),
            .focus => self.window.perform(.focus) catch {},
            .hide => self.window.perform(.hide) catch {},
            .show => self.window.show(),
            .minimize => self.window.perform(.minimize) catch {},
            .restore => self.window.perform(.restore) catch {},
            .quit => self.app.quit(),
        }
    }
    fn eventually(self: *Driver, what: []const u8, condition: *const fn (*Driver) bool) bool {
        var waited: u64 = 0;
        while (waited < 10 * std.time.ns_per_s) : (waited += 20 * std.time.ns_per_ms) {
            if (condition(self)) return true;
            zio.sleep(20 * std.time.ns_per_ms);
        }
        self.failure = what;
        return false;
    }
    fn hiddenBuilt(self: *Driver) bool {
        return self.seen.built_hidden.load(.seq_cst);
    }
    fn shownBuilt(self: *Driver) bool {
        return self.seen.built_shown.load(.seq_cst);
    }
    /// A window may be out of sight a moment before it first shows, so the
    /// view builds anew until a build sees it shown.
    fn shownOnce(self: *Driver) bool {
        const asked = self.seen.builds.load(.seq_cst);
        if (asked > 0 and !self.seen.last_hidden.load(.seq_cst)) return true;
        self.post(.invalidate) catch {};
        zio.sleep(30 * std.time.ns_per_ms);
        return self.seen.builds.load(.seq_cst) > asked and !self.seen.last_hidden.load(.seq_cst);
    }
    fn state(self: *Driver, out: Step, back: Step) bool {
        self.seen.built_hidden.store(false, .seq_cst);
        self.post(out) catch return false;
        if (!self.eventually(if (out == .hide) "a build as the window hides" else "a build as the window minimizes", hiddenBuilt)) return false;
        self.seen.built_shown.store(false, .seq_cst);
        self.post(back) catch return false;
        return self.eventually(if (back == .show) "a build as the window shows again" else "a build as the window is restored", shownBuilt);
    }
    fn drive(self: *Driver) void {
        defer self.post(.quit) catch {};
        zio.sleep(50 * std.time.ns_per_ms);
        self.post(.focus) catch return;
        if (!self.eventually("a build that sees the window shown", shownOnce)) return;
        if (builtin.os.tag == .macos and !self.state(.hide, .show)) return;
        if (!self.eventually("a build that sees the window shown again", shownOnce)) return;
        _ = self.state(.minimize, .restore);
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(macos_panic.allocator_config) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    if (builtin.os.tag == .linux) {
        std.debug.print("window hidden: Linux has no window manager here to minimize a window; skipped\n", .{});
        return;
    }
    const app = try z.App.init(gpa.allocator());
    defer app.deinit();
    var seen: Seen = .{};
    var storage: view.Storage(8, 64) = .{};
    var host = view.Host.init(&seen, Seen.build, storage.buffers(), .{});
    const window = try app.createWindow(.{ .title = "WindowHidden", .width = 320, .height = 240 });
    try host.attach(window);
    window.show();
    var driver: Driver = .{ .app = app, .window = window, .seen = &seen };
    const thread = try std.Thread.spawn(.{}, Driver.drive, .{&driver});
    try app.run();
    thread.join();
    if (host.last_error) |err| return err;
    if (driver.failure) |what| {
        std.debug.print("window hidden: timed out waiting for {s}\n", .{what});
        return error.TimedOut;
    }
    std.debug.print("window hidden: a view built as its window {s}, and again as it showed\n", .{if (builtin.os.tag == .macos) "hid and minimized" else "minimized"});
}
