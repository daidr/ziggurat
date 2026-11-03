//! Global hotkeys and notifications of a macOS Owner against the real
//! session: hotkeys are registered with the system, and the events it sends
//! when their keys go down and up are sent through the application's event
//! target, as a key press would; notifications need an app bundle, which a
//! smoke binary is not.
const std = @import("std");
const builtin = @import("builtin");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const system = @import("ziggurat_system");
const Watchdog = @import("watchdog.zig").Watchdog;

pub const std_options: std.Options = .{ .allow_stack_tracing = builtin.os.tag != .macos };

extern fn zsm_hotkey_test_event(*anyopaque, c_int) c_int;
extern fn zsm_hotkey_live() c_int;

const long_title: [64]u8 = @splat('t');

fn expectAt(src: std.builtin.SourceLocation, ok: bool) !void {
    if (!ok) {
        std.debug.print("check failed at line {d}\n", .{src.line});
        return error.TestUnexpectedResult;
    }
}

const State = struct {
    app: *z.App,
    window: z.Window = undefined,
    owner: system.Owner = undefined,
    presses: [64]u64 = @splat(0),
    press_count: usize = 0,
    repeat_checks: usize = 0,
    repeats_seen: usize = 0,
    failure: ?anyerror = null,
    passed: bool = false,

    fn action(ptr: *anyopaque, _: z.Window, value: system.Action) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .hotkey => |id| if (self.press_count < self.presses.len) {
                self.presses[self.press_count] = id;
                self.press_count += 1;
            },
            else => {},
        }
    }
    fn count(self: *State, id: u64) usize {
        var total: usize = 0;
        for (self.presses[0..self.press_count]) |value| total += @intFromBool(value == id);
        return total;
    }
    fn fail(self: *State, err: anyerror) void {
        self.failure = err;
        self.app.quit();
    }
    fn run(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.start() catch |err| self.fail(err);
    }
    fn start(self: *State) !void {
        const owner = &self.owner;
        try owner.registerHotkey(1, .{ .key = .f13, .modifiers = .{ .super = true, .shift = true } });
        try owner.registerHotkey(2, .{ .key = .f14, .modifiers = .{ .control = true, .alt = true }, .repeat = true });
        try std.testing.expectError(error.DuplicateHotkeyId, owner.registerHotkey(1, .{ .key = .f15 }));
        try std.testing.expectError(error.InvalidHotkeyId, owner.registerHotkey(0, .{ .key = .f15 }));
        try std.testing.expectError(error.UnsupportedKey, owner.registerHotkey(3, .{ .key = .f21 }));
        // The system refuses a combination the process already holds.
        try std.testing.expectError(error.HotkeyRegistrationFailed, owner.registerHotkey(3, .{ .key = .f13, .modifiers = .{ .super = true, .shift = true } }));
        try expectAt(@src(), owner.last_error != 0);
        try expectAt(@src(), zsm_hotkey_live() == 2);

        // A press reports once; its release reports nothing.
        const first = owner.hotkeyHandleForTesting(1).?;
        try expectAt(@src(), zsm_hotkey_test_event(first, 1) == 1);
        try expectAt(@src(), zsm_hotkey_test_event(first, 0) == 1);
        try expectAt(@src(), self.count(1) == 1);

        // Unregistering one leaves the other; an unknown id is reported.
        try owner.registerHotkey(4, .{ .key = .k, .modifiers = .{ .super = true, .alt = true } });
        try owner.unregisterHotkey(4);
        try std.testing.expectError(error.HotkeyNotFound, owner.unregisterHotkey(4));
        try expectAt(@src(), zsm_hotkey_live() == 2);

        // Notifications: validated first, then refused outside an app bundle.
        try std.testing.expectError(error.InvalidNotificationId, owner.showNotification(0, .{ .title = "Title", .body = "Body" }));
        try std.testing.expectError(error.EmptyNotification, owner.showNotification(1, .{ .title = "Title", .body = "" }));
        try std.testing.expectError(error.TextCapacityExceeded, owner.showNotification(1, .{ .title = &long_title, .body = "Body" }));
        try std.testing.expectError(error.UnsupportedCapability, owner.showNotification(1, .{ .title = "Title", .body = "Body" }));
        try owner.clearNotification();

        // A repeating hotkey held down reports again at the key repeat rate.
        try expectAt(@src(), zsm_hotkey_test_event(owner.hotkeyHandleForTesting(2).?, 1) == 1);
        try expectAt(@src(), self.count(2) == 1);
        (try std.Thread.spawn(.{}, later, .{self})).detach();
    }
    fn later(self: *State) void {
        zio.sleep(100 * std.time.ns_per_ms);
        self.app.post(.{ .context = self, .call = checkRepeat }) catch {};
    }
    fn checkRepeat(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.repeat_checks += 1;
        if (self.count(2) < 3 and self.repeat_checks < 50) {
            const thread = std.Thread.spawn(.{}, later, .{self}) catch |err| return self.fail(err);
            thread.detach();
            return;
        }
        self.finish() catch |err| self.fail(err);
    }
    fn finish(self: *State) !void {
        const owner = &self.owner;
        try expectAt(@src(), self.count(2) >= 3);
        const handle = owner.hotkeyHandleForTesting(2).?;
        try expectAt(@src(), zsm_hotkey_test_event(handle, 0) == 1);
        self.repeats_seen = self.count(2);
        try std.testing.expectEqual(@as(usize, 1), self.count(1));
        // Clearing and detaching release every registration.
        try owner.clearHotkeys();
        try expectAt(@src(), zsm_hotkey_live() == 0);
        try owner.registerHotkey(5, .{ .key = .f16 });
        try owner.detach();
        try expectAt(@src(), zsm_hotkey_live() == 0);
        self.passed = true;
        self.app.quit();
    }
};

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    const app = try z.App.init(allocator.allocator());
    defer app.deinit();
    var state: State = .{ .app = app };
    state.owner = system.Owner.init(&state, State.action);
    state.window = try app.createWindow(.{ .title = "Hotkey macOS smoke", .width = 320, .height = 200 });
    try state.owner.attach(state.window);
    state.window.show();
    try app.post(.{ .context = &state, .call = State.run });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    try expectAt(@src(), !watchdog.expired);
    if (state.failure) |err| return err;
    try expectAt(@src(), state.passed);
    std.debug.print("macOS hotkeys smoke passed: register/duplicate/unsupported key/system refusal (OSStatus {d}), press and release, repeat while held ({d} reports), unregister/clear/detach; notifications refused outside an app bundle\n", .{ state.owner.last_error, state.repeats_seen });
}
