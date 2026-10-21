//! Pads from evdev, `/dev/input/event*`, which the seat manager lets the
//! user at the seat read. The kernel's drivers report gamepads in one
//! layout: BTN_SOUTH and the rest by place, sticks on ABS_X/Y and
//! ABS_RX/RY, triggers on ABS_Z/RZ, the d-pad on a hat or buttons. Xbox
//! controllers (xpad, and the virtual pad of Steam) predate it: they
//! report X as BTN_X, the code of BTN_NORTH, and Y as BTN_Y, that of
//! BTN_WEST.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const gamepad = @import("gamepad.zig");
const State = gamepad.State;
const Button = gamepad.Button;
const Axis = gamepad.Axis;

const ev_key = 0x01;
const ev_abs = 0x03;

const btn_south = 0x130;
const btn_east = 0x131;
const btn_north = 0x133; // also BTN_X
const btn_west = 0x134; // also BTN_Y
const btn_tl = 0x136;
const btn_tr = 0x137;
const btn_tl2 = 0x138;
const btn_tr2 = 0x139;
const btn_select = 0x13a;
const btn_start = 0x13b;
const btn_mode = 0x13c;
const btn_thumbl = 0x13d;
const btn_thumbr = 0x13e;
const btn_up = 0x220;
const btn_down = 0x221;
const btn_left = 0x222;
const btn_right = 0x223;

const abs_x = 0x00;
const abs_y = 0x01;
const abs_z = 0x02;
const abs_rx = 0x03;
const abs_ry = 0x04;
const abs_rz = 0x05;
const abs_hat0x = 0x10;
const abs_hat0y = 0x11;
const abs_max = 0x3f;
const key_max = 0x2ff;

/// The 64-bit `struct input_event`: a timeval, then type, code and value.
const event_size = 24;
const events_per_read = 64;

const AbsInfo = extern struct { value: i32, minimum: i32, maximum: i32, fuzz: i32, flat: i32, resolution: i32 };
const InputId = extern struct { bustype: u16, vendor: u16, product: u16, version: u16 };

fn ioc(nr: u32, size: usize) u32 {
    return 2 << 30 | @as(u32, @intCast(size)) << 16 | 'E' << 8 | nr;
}
fn ioctl(fd: i32, request: u32, arg: *anyopaque) bool {
    return linux.E.init(linux.ioctl(fd, request, @intFromPtr(arg))) == .SUCCESS;
}

fn bit(bytes: []const u8, index: usize) bool {
    return index / 8 < bytes.len and bytes[index / 8] & (@as(u8, 1) << @intCast(index % 8)) != 0;
}

pub const Backend = struct {
    pub const Device = struct {
        number: u32,
        fd: i32,
        label: [128]u8 = undefined,
        label_len: usize = 0,
        /// BTN_X and BTN_Y are X and Y, west and north.
        xbox: bool = false,
        /// A pad without ABS_RX has its right stick on ABS_Z/RZ, and its
        /// triggers as buttons only.
        right_on_z: bool = false,
        abs: [abs_max + 1]AbsInfo = undefined,
        has_abs: std.StaticBitSet(abs_max + 1) = .initEmpty(),
        keys: std.StaticBitSet(key_max + 1) = .initEmpty(),
        axes: [abs_max + 1]i32 = @splat(0),

        pub fn key(self: *const Device) u64 {
            return self.number;
        }
        pub fn name(self: *const Device) []const u8 {
            return self.label[0..self.label_len];
        }

        /// Read the events waiting; false once the device is gone.
        fn drain(self: *Device) bool {
            var buffer: [event_size * events_per_read]u8 align(8) = undefined;
            while (true) {
                const n = std.posix.read(self.fd, &buffer) catch |err| return err == error.WouldBlock;
                if (n == 0) return false; // unplugged
                var offset: usize = 0;
                while (offset + event_size <= n) : (offset += event_size) {
                    const e = buffer[offset..][0..event_size];
                    const kind = std.mem.readInt(u16, e[16..18], .little);
                    const code = std.mem.readInt(u16, e[18..20], .little);
                    const value = std.mem.readInt(i32, e[20..24], .little);
                    if (kind == ev_key and code <= key_max) self.keys.setValue(code, value != 0);
                    if (kind == ev_abs and code <= abs_max) self.axes[code] = value;
                }
                if (n < buffer.len) return true;
            }
        }

        /// Axis `a` from -1 to 1, or 0 to 1 when `half`.
        fn norm(self: *const Device, a: usize, half: bool) f32 {
            if (!self.has_abs.isSet(a)) return 0;
            const low: f32 = @floatFromInt(self.abs[a].minimum);
            const high: f32 = @floatFromInt(self.abs[a].maximum);
            if (high <= low) return 0;
            const t = (@as(f32, @floatFromInt(self.axes[a])) - low) / (high - low);
            if (half) return std.math.clamp(t, 0, 1);
            return std.math.clamp(t * 2 - 1, -1, 1);
        }

        fn fill(self: *const Device, state: *State) void {
            const Press = struct {
                fn at(d: *const Device, s: *State, b: Button, code: usize) void {
                    if (d.keys.isSet(code)) s.buttons[@intFromEnum(b)] = 1;
                }
            };
            const press = Press.at;
            press(self, state, .south, btn_south);
            press(self, state, .east, btn_east);
            if (self.xbox) {
                press(self, state, .west, btn_north);
                press(self, state, .north, btn_west);
            } else {
                press(self, state, .north, btn_north);
                press(self, state, .west, btn_west);
            }
            press(self, state, .left_shoulder, btn_tl);
            press(self, state, .right_shoulder, btn_tr);
            press(self, state, .back, btn_select);
            press(self, state, .start, btn_start);
            press(self, state, .guide, btn_mode);
            press(self, state, .left_stick_button, btn_thumbl);
            press(self, state, .right_stick_button, btn_thumbr);
            press(self, state, .up, btn_up);
            press(self, state, .down, btn_down);
            press(self, state, .left, btn_left);
            press(self, state, .right, btn_right);
            if (self.has_abs.isSet(abs_hat0x)) {
                const hx = self.axes[abs_hat0x];
                const hy = self.axes[abs_hat0y];
                if (hx < 0) state.buttons[@intFromEnum(Button.left)] = 1 else if (hx > 0) state.buttons[@intFromEnum(Button.right)] = 1;
                if (hy < 0) state.buttons[@intFromEnum(Button.up)] = 1 else if (hy > 0) state.buttons[@intFromEnum(Button.down)] = 1;
            }
            state.axes[@intFromEnum(Axis.left_x)] = self.norm(abs_x, false);
            state.axes[@intFromEnum(Axis.left_y)] = self.norm(abs_y, false);
            if (self.right_on_z) {
                state.axes[@intFromEnum(Axis.right_x)] = self.norm(abs_z, false);
                state.axes[@intFromEnum(Axis.right_y)] = self.norm(abs_rz, false);
            } else {
                state.axes[@intFromEnum(Axis.right_x)] = self.norm(abs_rx, false);
                state.axes[@intFromEnum(Axis.right_y)] = self.norm(abs_ry, false);
                state.buttons[@intFromEnum(Button.left_trigger)] = self.norm(abs_z, true);
                state.buttons[@intFromEnum(Button.right_trigger)] = self.norm(abs_rz, true);
            }
            press(self, state, .left_trigger, btn_tl2);
            press(self, state, .right_trigger, btn_tr2);
        }
    };

    pub fn scan(_: *Backend, known: []const u64, present: []u64, fresh: []Device) gamepad.Scan {
        var result: gamepad.Scan = .{};
        if (@sizeOf(usize) != 8) return result;
        var dir = std.fs.openDirAbsolute("/dev/input", .{ .iterate = true }) catch return result;
        defer dir.close();
        var entries = dir.iterate();
        while (entries.next() catch null) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "event")) continue;
            const number = std.fmt.parseInt(u32, entry.name["event".len..], 10) catch continue;
            if (std.mem.indexOfScalar(u64, known, number) != null) {
                if (result.present < present.len) {
                    present[result.present] = number;
                    result.present += 1;
                }
                continue;
            }
            if (result.fresh == fresh.len) continue;
            if (open(number, &fresh[result.fresh])) result.fresh += 1;
        }
        return result;
    }

    pub fn read(_: *Backend, device: *Device, state: *State) bool {
        if (!device.drain()) return false;
        device.fill(state);
        return true;
    }

    pub fn close(_: *Backend, device: *Device) void {
        std.posix.close(device.fd);
    }
};

/// Open `/dev/input/event<number>` into `device` if it is a gamepad.
fn open(number: u32, device: *Backend.Device) bool {
    var path_buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "/dev/input/event{d}", .{number}) catch return false;
    const fd = std.posix.openZ(path, .{ .NONBLOCK = true, .CLOEXEC = true }, 0) catch return false;
    var keys: [key_max / 8 + 1]u8 = @splat(0);
    if (!ioctl(fd, ioc(0x20 + ev_key, keys.len), &keys) or !bit(&keys, btn_south)) {
        std.posix.close(fd);
        return false;
    }
    device.* = .{ .number = number, .fd = fd };
    var label: [128]u8 = @splat(0);
    if (ioctl(fd, ioc(0x06, label.len), &label)) {
        device.label_len = std.mem.indexOfScalar(u8, &label, 0) orelse label.len;
        @memcpy(device.label[0..device.label_len], label[0..device.label_len]);
    }
    var id: InputId = std.mem.zeroes(InputId);
    _ = ioctl(fd, ioc(0x02, @sizeOf(InputId)), &id);
    device.xbox = id.vendor == 0x045e or id.vendor == 0x28de or isXpad(number);
    var abs: [abs_max / 8 + 1]u8 = @splat(0);
    _ = ioctl(fd, ioc(0x20 + ev_abs, abs.len), &abs);
    for (0..abs_max + 1) |a| {
        if (!bit(&abs, a)) continue;
        if (ioctl(fd, ioc(0x40 + @as(u32, @intCast(a)), @sizeOf(AbsInfo)), &device.abs[a])) {
            device.has_abs.set(a);
            device.axes[a] = device.abs[a].value;
        }
    }
    device.right_on_z = !device.has_abs.isSet(abs_rx) and device.has_abs.isSet(abs_z);
    var held: [key_max / 8 + 1]u8 = @splat(0);
    if (ioctl(fd, ioc(0x18, held.len), &held)) {
        for (0..key_max + 1) |k| device.keys.setValue(k, bit(&held, k));
    }
    return true;
}

/// The kernel driver of the device is xpad.
fn isXpad(number: u32) bool {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/sys/class/input/event{d}/device/device/driver", .{number}) catch return false;
    var link: [std.fs.max_path_bytes]u8 = undefined;
    const target = std.fs.readLinkAbsolute(path, &link) catch return false;
    return std.mem.eql(u8, std.fs.path.basename(target), "xpad");
}

test "an Xbox pad's X and Y read in place and its hat drives the d-pad" {
    var device: Backend.Device = .{ .number = 0, .fd = -1, .xbox = true };
    device.keys.set(btn_north); // BTN_X
    device.has_abs.set(abs_hat0x);
    device.has_abs.set(abs_hat0y);
    device.axes[abs_hat0x] = -1;
    device.axes[abs_hat0y] = 1;
    device.has_abs.set(abs_x);
    device.abs[abs_x] = .{ .value = 0, .minimum = -32768, .maximum = 32767, .fuzz = 0, .flat = 0, .resolution = 0 };
    device.axes[abs_x] = 32767;
    device.has_abs.set(abs_z);
    device.abs[abs_z] = .{ .value = 0, .minimum = 0, .maximum = 1023, .fuzz = 0, .flat = 0, .resolution = 0 };
    device.axes[abs_z] = 1023;
    var state: State = .{};
    device.fill(&state);
    try std.testing.expect(state.pressed(.west));
    try std.testing.expect(!state.pressed(.north));
    try std.testing.expect(state.pressed(.left));
    try std.testing.expect(state.pressed(.down));
    try std.testing.expectEqual(@as(f32, 1), state.axis(.left_x));
    try std.testing.expectEqual(@as(f32, 1), state.value(.left_trigger));
}

test "the ioctl numbers match the kernel's" {
    // EVIOCGNAME(256) and EVIOCGABS(ABS_X).
    try std.testing.expectEqual(@as(u32, 0x81004506), ioc(0x06, 256));
    try std.testing.expectEqual(@as(u32, 0x80184540), ioc(0x40, @sizeOf(AbsInfo)));
}
