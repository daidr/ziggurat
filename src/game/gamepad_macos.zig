//! Pads through GameController.framework (gamepad_macos.m): controllers
//! with an extended gamepad profile, which Xbox, PlayStation, Switch Pro
//! and MFi controllers have. The framework finds controllers on the main
//! run loop, which a running app turns.
const std = @import("std");
const gamepad = @import("gamepad.zig");
const State = gamepad.State;

extern fn zgc_controllers(out: [*]?*anyopaque, capacity: c_int) c_int;
extern fn zgc_retain(controller: *anyopaque) *anyopaque;
extern fn zgc_release(controller: *anyopaque) void;
extern fn zgc_name(controller: *anyopaque, buffer: [*]u8, capacity: c_int) c_int;
extern fn zgc_read(controller: *anyopaque, check_present: c_int, buttons: *[gamepad.button_count]f32, axes: *[gamepad.axis_count]f32) c_int;
extern fn zgc_test_controller() ?*anyopaque;

pub const Backend = struct {
    /// Tests read controllers the framework makes, which are not among
    /// the connected ones.
    check_present: bool = true,

    pub const Device = struct {
        /// Retained.
        controller: *anyopaque,
        label: [64]u8 = undefined,
        label_len: usize = 0,
        pub fn key(self: *const Device) u64 {
            return @intFromPtr(self.controller);
        }
        pub fn name(self: *const Device) []const u8 {
            return self.label[0..self.label_len];
        }
    };

    pub fn scan(_: *Backend, known: []const u64, present: []u64, fresh: []Device) gamepad.Scan {
        var controllers: [gamepad.max_pads * 2]?*anyopaque = undefined;
        const count: usize = @min(controllers.len, @as(usize, @intCast(@max(0, zgc_controllers(&controllers, controllers.len)))));
        var result: gamepad.Scan = .{};
        for (controllers[0..count]) |entry| {
            const controller = entry orelse continue;
            const key = @intFromPtr(controller);
            if (std.mem.indexOfScalar(u64, known, key) != null) {
                if (result.present < present.len) {
                    present[result.present] = key;
                    result.present += 1;
                }
                continue;
            }
            if (result.fresh == fresh.len) continue;
            fresh[result.fresh] = open(zgc_retain(controller));
            result.fresh += 1;
        }
        return result;
    }

    pub fn read(self: *Backend, device: *Device, state: *State) bool {
        return zgc_read(device.controller, @intFromBool(self.check_present), &state.buttons, &state.axes) != 0;
    }

    pub fn close(_: *Backend, device: *Device) void {
        zgc_release(device.controller);
    }
};

/// A device for a retained controller, named by its vendor.
fn open(controller: *anyopaque) Backend.Device {
    var device: Backend.Device = .{ .controller = controller };
    device.label_len = @intCast(@max(0, zgc_name(controller, &device.label, device.label.len)));
    return device;
}

test "a controller GameController makes reads in the standard layout, its y axes going down" {
    const controller = zgc_test_controller() orelse return error.SkipZigTest;
    var backend: Backend = .{ .check_present = false };
    var device = open(controller);
    defer backend.close(&device);
    var state: State = .{};
    try std.testing.expect(backend.read(&device, &state));
    try std.testing.expect(state.pressed(.south));
    try std.testing.expect(!state.pressed(.east));
    try std.testing.expect(state.pressed(.up));
    try std.testing.expect(!state.pressed(.down));
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), state.value(.right_trigger), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), state.axes[@backingInt(gamepad.Axis.left_x)], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, -0.25), state.axes[@backingInt(gamepad.Axis.left_y)], 1e-3);
}
