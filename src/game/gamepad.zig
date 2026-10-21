//! Game controllers, read in one standard layout whatever pad it is:
//! buttons by place, two sticks, analog triggers and a d-pad, as the
//! standard gamepad of web browsers and common controller databases name
//! them.
//!
//!     var pads: gamepad.Gamepads = .{};
//!     defer pads.deinit();
//!     var buffer: [gamepad.max_pads]gamepad.Pad = undefined;
//!     for (pads.pads(now, &buffer)) |pad| {
//!         const s = pad.state();
//!         const stick = s.leftStick();
//!         if (s.justPressed(last, .south)) jump();
//!     }
//!
//! Windows reads XInput (Xbox controllers and those that act as one);
//! Linux reads evdev, `/dev/input/event*`, which the user at the seat may
//! read. Other targets report no pads. Everything runs on the thread that
//! owns the `Gamepads`, normally the main thread; nothing allocates.
const std = @import("std");
const builtin = @import("builtin");

/// A button of the standard layout, named by place: `south` is A on an Xbox
/// controller, Cross on a PlayStation one, B on a Nintendo one.
pub const Button = enum(u8) {
    south,
    east,
    west,
    north,
    left_shoulder,
    right_shoulder,
    /// Analog: its value is from 0 to 1.
    left_trigger,
    right_trigger,
    /// View, Select, Share or Minus.
    back,
    start,
    left_stick_button,
    right_stick_button,
    up,
    down,
    left,
    right,
    /// The Xbox, PlayStation or Home button, where the system leaves it.
    guide,
};
pub const button_count = @typeInfo(Button).@"enum".fields.len;

/// An axis of the sticks, from -1 to 1: right and down are positive, as on
/// the screen.
pub const Axis = enum(u8) { left_x, left_y, right_x, right_y };
pub const axis_count = @typeInfo(Axis).@"enum".fields.len;

/// How far from the middle a stick must move to count, as a fraction of its
/// reach: sticks rest a little off their middle.
pub const deadzone: f32 = 0.15;
/// How far an analog trigger must go to be pressed.
pub const press_threshold: f32 = 0.25;
/// Pads followed at once.
pub const max_pads = 8;
/// How often `Gamepads.pads` looks for pads anew, in nanoseconds.
pub const scan_interval: u64 = std.time.ns_per_s;

/// What a pad's controls read at one time.
pub const State = struct {
    /// From 0 to 1: 0 or 1 but for the triggers.
    buttons: [button_count]f32 = @splat(0),
    /// From -1 to 1, as the pad reports them, without a dead zone.
    axes: [axis_count]f32 = @splat(0),

    /// How far `b` is pressed, from 0 to 1.
    pub fn value(self: State, b: Button) f32 {
        return self.buttons[@intFromEnum(b)];
    }
    /// `b` is pressed: a trigger a quarter of the way.
    pub fn pressed(self: State, b: Button) bool {
        return self.value(b) >= press_threshold;
    }
    /// `b` is pressed now and was not in `last`, the state read before.
    pub fn justPressed(self: State, last: State, b: Button) bool {
        return self.pressed(b) and !last.pressed(b);
    }
    /// `b` was pressed in `last` and is not now.
    pub fn justReleased(self: State, last: State, b: Button) bool {
        return !self.pressed(b) and last.pressed(b);
    }
    /// The raw value of `a`, from -1 to 1.
    pub fn axis(self: State, a: Axis) f32 {
        return self.axes[@intFromEnum(a)];
    }
    pub const Stick = struct { x: f32, y: f32 };
    /// Where the left stick is, each coordinate from -1 to 1, right and down
    /// positive, with a radial dead zone: 0 near the middle, then from 0 at
    /// `deadzone` to 1 at the rim, the same in every direction.
    pub fn leftStick(self: State) Stick {
        return stick(self.axis(.left_x), self.axis(.left_y));
    }
    /// Where the right stick is, as `leftStick`.
    pub fn rightStick(self: State) Stick {
        return stick(self.axis(.right_x), self.axis(.right_y));
    }
    fn set(self: *State, b: Button, v: f32) void {
        self.buttons[@intFromEnum(b)] = v;
    }
    fn setAxis(self: *State, a: Axis, v: f32) void {
        self.axes[@intFromEnum(a)] = v;
    }
};

fn stick(x: f32, y: f32) State.Stick {
    const m = @sqrt(x * x + y * y);
    if (m < deadzone) return .{ .x = 0, .y = 0 };
    const k = @min((m - deadzone) / (1 - deadzone), 1) / m;
    return .{ .x = x * k, .y = y * k };
}

/// The pads of the platform.
pub const Gamepads = Set(switch (builtin.os.tag) {
    .windows => @import("gamepad_windows.zig").Backend,
    .linux => @import("gamepad_linux.zig").Backend,
    else => NoPads,
});

/// A platform without pads.
pub const NoPads = struct {
    pub const Device = struct {
        pub fn key(_: *const Device) u64 {
            return 0;
        }
        pub fn name(_: *const Device) []const u8 {
            return "";
        }
    };
    pub fn scan(_: *NoPads, _: []const u64, _: []u64, _: []Device) Scan {
        return .{};
    }
    pub fn read(_: *NoPads, _: *Device, _: *State) bool {
        return false;
    }
    pub fn close(_: *NoPads, _: *Device) void {}
};

/// What a backend's scan found: `present` keys of known devices still
/// connected, and `fresh` devices it opened.
pub const Scan = struct { present: usize = 0, fresh: usize = 0 };

/// The pads a backend finds. A backend has a `Device` type with `key` and
/// `name`, and `scan`, `read` and `close`; tests give their own.
pub fn Set(comptime Backend: type) type {
    return struct {
        const Self = @This();
        pub const Device = Backend.Device;

        backend: Backend = .{},
        slots: [max_pads]Slot = @splat(.{}),
        /// Slots of connected pads in the order they connected.
        order: [max_pads]u8 = undefined,
        count: usize = 0,
        scanned: ?u64 = null,

        const Slot = struct {
            device: Device = undefined,
            used: bool = false,
            generation: u32 = 0,
        };

        /// A pad, from when it connects until it disconnects; connected
        /// again, it is a new one. A value handle: the Gamepads must outlive
        /// every use.
        pub const Pad = struct {
            const Handle = @This();
            owner: *Self,
            slot: u8,
            generation: u32,

            fn live(self: Handle) ?*Slot {
                const s = &self.owner.slots[self.slot];
                return if (s.used and s.generation == self.generation) s else null;
            }
            /// The pad is still connected.
            pub fn connected(self: Handle) bool {
                return self.live() != null;
            }
            /// The pad's name as its maker gives it, valid while it stays
            /// connected; empty once it is gone.
            pub fn name(self: Handle) []const u8 {
                const s = self.live() orelse return "";
                return s.device.name();
            }
            /// Read the pad's controls now; a pad no longer connected reads
            /// nothing pressed, and one found gone disconnects.
            pub fn state(self: Handle) State {
                const s = self.live() orelse return .{};
                var result: State = .{};
                if (!self.owner.backend.read(&s.device, &result)) {
                    self.owner.disconnect(self.slot);
                    return .{};
                }
                return result;
            }
        };

        /// Close every device.
        pub fn deinit(self: *Self) void {
            while (self.count > 0) self.disconnect(self.order[0]);
        }

        /// The pads connected, in the order they connected, written to
        /// `buffer`. Looks for pads connected or gone at most once every
        /// `scan_interval` of `now`, a monotonic time in nanoseconds; a game
        /// calls it once a frame.
        pub fn pads(self: *Self, now: u64, buffer: *[max_pads]Self.Pad) []Self.Pad {
            if (self.scanned == null or now -% self.scanned.? >= scan_interval) {
                self.scanned = now;
                self.rescan();
            }
            for (self.order[0..self.count], 0..) |slot, i| buffer[i] = .{ .owner = self, .slot = slot, .generation = self.slots[slot].generation };
            return buffer[0..self.count];
        }

        /// Look for pads now: the pads of devices gone disconnect, new
        /// devices connect as pads.
        pub fn rescan(self: *Self) void {
            var known: [max_pads]u64 = undefined;
            for (self.order[0..self.count], 0..) |slot, i| known[i] = self.slots[slot].device.key();
            var present: [max_pads]u64 = undefined;
            var fresh: [max_pads]Device = undefined;
            const found = self.backend.scan(known[0..self.count], &present, &fresh);
            var index: usize = 0;
            while (index < self.count) {
                const slot = self.order[index];
                const key = self.slots[slot].device.key();
                if (std.mem.indexOfScalar(u64, present[0..found.present], key) == null) {
                    self.disconnect(slot);
                } else index += 1;
            }
            for (fresh[0..found.fresh]) |*device| {
                const slot = self.free() orelse {
                    self.backend.close(device);
                    continue;
                };
                self.slots[slot].device = device.*;
                self.slots[slot].used = true;
                self.order[self.count] = slot;
                self.count += 1;
            }
        }

        fn free(self: *Self) ?u8 {
            for (&self.slots, 0..) |*s, i| if (!s.used) return @intCast(i);
            return null;
        }
        fn disconnect(self: *Self, slot: u8) void {
            const s = &self.slots[slot];
            if (!s.used) return;
            self.backend.close(&s.device);
            s.used = false;
            s.generation +%= 1;
            const at = std.mem.indexOfScalar(u8, self.order[0..self.count], slot) orelse return;
            std.mem.copyForwards(u8, self.order[at .. self.count - 1], self.order[at + 1 .. self.count]);
            self.count -= 1;
        }
    };
}

pub const Pad = Gamepads.Pad;

const testing = std.testing;

const Fake = struct {
    const Device = struct {
        id: u64,
        pub fn key(self: *const Device) u64 {
            return self.id;
        }
        pub fn name(_: *const Device) []const u8 {
            return "Fake Pad";
        }
    };
    connected: [4]bool = @splat(false),
    opened: [4]bool = @splat(false),
    readings: [4]State = @splat(.{}),
    scans: usize = 0,
    closes: usize = 0,
    fn scan(self: *Fake, known: []const u64, present: []u64, fresh: []Device) Scan {
        self.scans += 1;
        var result: Scan = .{};
        for (self.connected, 0..) |is, i| {
            if (!is) continue;
            if (std.mem.indexOfScalar(u64, known, i) != null) {
                present[result.present] = i;
                result.present += 1;
            } else {
                self.opened[i] = true;
                fresh[result.fresh] = .{ .id = i };
                result.fresh += 1;
            }
        }
        return result;
    }
    fn read(self: *Fake, device: *Device, state: *State) bool {
        if (!self.connected[device.id]) return false;
        state.* = self.readings[device.id];
        return true;
    }
    fn close(self: *Fake, device: *Device) void {
        self.opened[device.id] = false;
        self.closes += 1;
    }
};

test "pads connect in order, scan at most once a second and disconnect" {
    var set: Set(Fake) = .{};
    defer set.deinit();
    var buffer: [max_pads]Set(Fake).Pad = undefined;
    try testing.expectEqual(@as(usize, 0), set.pads(0, &buffer).len);
    set.backend.connected[2] = true;
    set.backend.connected[0] = true;
    // Not a second since the last look.
    try testing.expectEqual(@as(usize, 0), set.pads(scan_interval / 2, &buffer).len);
    const found = set.pads(scan_interval, &buffer);
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqualStrings("Fake Pad", found[0].name());
    const first = found[0];
    set.backend.readings[0].buttons[@intFromEnum(Button.south)] = 1;
    try testing.expect(first.state().pressed(.south));

    // Unplugged: the read finds it gone, and the pad disconnects at once.
    set.backend.connected[0] = false;
    try testing.expect(!first.state().pressed(.south));
    try testing.expect(!first.connected());
    try testing.expectEqual(@as(usize, 1), set.pads(scan_interval, &buffer).len);
    // Plugged in again, it is a new pad; the old handle stays gone.
    set.backend.connected[0] = true;
    const again = set.pads(2 * scan_interval, &buffer);
    try testing.expectEqual(@as(usize, 2), again.len);
    try testing.expect(!first.connected());
    try testing.expect(again[1].connected());
    try testing.expectEqual(@as(usize, 3), set.backend.scans);

    // Gone between scans: the next scan drops it.
    set.backend.connected[2] = false;
    try testing.expectEqual(@as(usize, 1), set.pads(3 * scan_interval, &buffer).len);
    try testing.expect(!set.backend.opened[2]);
}

test "sticks have a radial dead zone and triggers press a quarter of the way" {
    var s: State = .{};
    s.setAxis(.left_x, 0.1);
    s.setAxis(.left_y, -0.1);
    try testing.expectEqual(State.Stick{ .x = 0, .y = 0 }, s.leftStick());
    s.setAxis(.left_x, 1);
    s.setAxis(.left_y, 0);
    try testing.expectApproxEqAbs(@as(f32, 1), s.leftStick().x, 1e-6);
    s.setAxis(.right_x, 0.575);
    try testing.expectApproxEqAbs(@as(f32, 0.5), s.rightStick().x, 1e-6);
    s.set(.left_trigger, 0.2);
    try testing.expect(!s.pressed(.left_trigger));
    var now = s;
    now.set(.left_trigger, 0.3);
    try testing.expect(now.justPressed(s, .left_trigger));
    try testing.expect(s.justReleased(now, .left_trigger));
}

test {
    _ = Gamepads;
    if (builtin.os.tag == .linux) _ = @import("gamepad_linux.zig");
    if (builtin.os.tag == .windows) _ = @import("gamepad_windows.zig");
}
