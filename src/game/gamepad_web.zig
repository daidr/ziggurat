//! Pads through the page's Gamepad API: pads in the standard mapping,
//! whose buttons and axes are this layout's, in the same order. Browsers
//! list a pad only after one of its buttons is pressed on the page.
const std = @import("std");
const gamepad = @import("gamepad.zig");
const State = gamepad.State;

/// The keys of connected standard pads; a pad keeps its key while it stays
/// connected.
extern "ziggurat" fn zw_gamepads(keys: [*]u32, capacity: u32) u32;
extern "ziggurat" fn zw_gamepad_name(key: u32, buffer: [*]u8, capacity: u32) u32;
/// False once the pad is gone.
extern "ziggurat" fn zw_gamepad_read(key: u32, buttons: *[gamepad.button_count]f32, axes: *[gamepad.axis_count]f32) u32;

pub const Backend = struct {
    pub const Device = struct {
        id: u32,
        label: [64]u8 = undefined,
        label_len: usize = 0,
        pub fn key(self: *const Device) u64 {
            return self.id;
        }
        pub fn name(self: *const Device) []const u8 {
            return self.label[0..self.label_len];
        }
    };

    pub fn scan(_: *Backend, known: []const u64, present: []u64, fresh: []Device) gamepad.Scan {
        var keys: [gamepad.max_pads * 2]u32 = undefined;
        const count = @min(keys.len, zw_gamepads(&keys, keys.len));
        var result: gamepad.Scan = .{};
        for (keys[0..count]) |id| {
            if (std.mem.indexOfScalar(u64, known, id) != null) {
                if (result.present < present.len) {
                    present[result.present] = id;
                    result.present += 1;
                }
                continue;
            }
            if (result.fresh == fresh.len) continue;
            var device: Device = .{ .id = id };
            device.label_len = @min(device.label.len, zw_gamepad_name(id, &device.label, device.label.len));
            fresh[result.fresh] = device;
            result.fresh += 1;
        }
        return result;
    }

    pub fn read(_: *Backend, device: *Device, state: *State) bool {
        return zw_gamepad_read(device.id, &state.buttons, &state.axes) != 0;
    }

    pub fn close(_: *Backend, _: *Device) void {}
};
