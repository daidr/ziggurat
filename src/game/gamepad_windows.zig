//! Pads through XInput, which has four slots, for Xbox controllers and
//! those that act as one. The ordinal-100 export of XInput 1.3 and 1.4
//! reads the Guide button too; the plain `XInputGetState` does not.
const std = @import("std");
const gamepad = @import("gamepad.zig");
const State = gamepad.State;

const HMODULE = *opaque {};
extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetProcAddress(module: HMODULE, name: ?*const anyopaque) callconv(.winapi) ?*const anyopaque;

const XInputGamepad = extern struct {
    buttons: u16,
    left_trigger: u8,
    right_trigger: u8,
    thumb_lx: i16,
    thumb_ly: i16,
    thumb_rx: i16,
    thumb_ry: i16,
};
const XInputState = extern struct { packet: u32, gamepad: XInputGamepad };
const GetState = *const fn (u32, *XInputState) callconv(.winapi) u32;

const slots = 4;
const success = 0;

const masks = [_]struct { button: gamepad.Button, mask: u16 }{
    .{ .button = .south, .mask = 0x1000 },             .{ .button = .east, .mask = 0x2000 },
    .{ .button = .west, .mask = 0x4000 },              .{ .button = .north, .mask = 0x8000 },
    .{ .button = .left_shoulder, .mask = 0x0100 },     .{ .button = .right_shoulder, .mask = 0x0200 },
    .{ .button = .back, .mask = 0x0020 },              .{ .button = .start, .mask = 0x0010 },
    .{ .button = .left_stick_button, .mask = 0x0040 }, .{ .button = .right_stick_button, .mask = 0x0080 },
    .{ .button = .up, .mask = 0x0001 },                .{ .button = .down, .mask = 0x0002 },
    .{ .button = .left, .mask = 0x0004 },              .{ .button = .right, .mask = 0x0008 },
    .{ .button = .guide, .mask = 0x0400 },
};

pub const Backend = struct {
    get_state: ?GetState = null,
    loaded: bool = false,

    pub const Device = struct {
        slot: u32,
        label: [20]u8 = undefined,
        label_len: usize = 0,
        pub fn key(self: *const Device) u64 {
            return self.slot;
        }
        pub fn name(self: *const Device) []const u8 {
            return self.label[0..self.label_len];
        }
    };

    fn load(self: *Backend) ?GetState {
        if (self.loaded) return self.get_state;
        self.loaded = true;
        const names = [_][:0]const u16{
            std.unicode.utf8ToUtf16LeStringLiteral("xinput1_4.dll"),
            std.unicode.utf8ToUtf16LeStringLiteral("xinput1_3.dll"),
            std.unicode.utf8ToUtf16LeStringLiteral("xinput9_1_0.dll"),
        };
        for (names) |library| {
            const module = LoadLibraryW(library) orelse continue;
            // XInputGetStateEx by ordinal, where there is one.
            const proc = GetProcAddress(module, @ptrFromInt(100)) orelse GetProcAddress(module, "XInputGetState") orelse continue;
            self.get_state = @ptrCast(proc);
            return self.get_state;
        }
        return null;
    }

    pub fn scan(self: *Backend, known: []const u64, present: []u64, fresh: []Device) gamepad.Scan {
        const get_state = self.load() orelse return .{};
        var result: gamepad.Scan = .{};
        for (0..slots) |slot| {
            if (std.mem.indexOfScalar(u64, known, slot) != null) {
                // Read as it is used; a slot that empties disconnects there.
                present[result.present] = slot;
                result.present += 1;
                continue;
            }
            // Asking an empty slot is slow, which is why scans are rare.
            var state: XInputState = undefined;
            if (get_state(@intCast(slot), &state) != success) continue;
            var device: Device = .{ .slot = @intCast(slot) };
            device.label_len = (std.fmt.bufPrint(&device.label, "Xbox Controller {d}", .{slot + 1}) catch unreachable).len;
            fresh[result.fresh] = device;
            result.fresh += 1;
        }
        return result;
    }

    pub fn read(self: *Backend, device: *Device, state: *State) bool {
        const get_state = self.get_state orelse return false;
        var raw: XInputState = undefined;
        if (get_state(device.slot, &raw) != success) return false;
        fill(raw.gamepad, state);
        return true;
    }

    pub fn close(_: *Backend, _: *Device) void {}
};

fn fill(pad: XInputGamepad, state: *State) void {
    for (masks) |entry| if (pad.buttons & entry.mask != 0) {
        state.buttons[@backingInt(entry.button)] = 1;
    };
    state.buttons[@backingInt(gamepad.Button.left_trigger)] = @as(f32, @floatFromInt(pad.left_trigger)) / 255;
    state.buttons[@backingInt(gamepad.Button.right_trigger)] = @as(f32, @floatFromInt(pad.right_trigger)) / 255;
    // XInput's y axes go up.
    state.axes[@backingInt(gamepad.Axis.left_x)] = thumb(pad.thumb_lx);
    state.axes[@backingInt(gamepad.Axis.left_y)] = -thumb(pad.thumb_ly);
    state.axes[@backingInt(gamepad.Axis.right_x)] = thumb(pad.thumb_rx);
    state.axes[@backingInt(gamepad.Axis.right_y)] = -thumb(pad.thumb_ry);
}

fn thumb(value: i16) f32 {
    return @max(@as(f32, @floatFromInt(value)) / 32767, -1);
}

test "XInput's packed state maps to the standard layout" {
    var state: State = .{};
    fill(.{ .buttons = 0x1000 | 0x0001 | 0x0400, .left_trigger = 255, .right_trigger = 0, .thumb_lx = -32768, .thumb_ly = 32767, .thumb_rx = 0, .thumb_ry = 0 }, &state);
    try std.testing.expect(state.pressed(.south));
    try std.testing.expect(state.pressed(.up));
    try std.testing.expect(state.pressed(.guide));
    try std.testing.expect(!state.pressed(.east));
    try std.testing.expectEqual(@as(f32, 1), state.value(.left_trigger));
    try std.testing.expectEqual(@as(f32, -1), state.axis(.left_x));
    try std.testing.expectEqual(@as(f32, -1), state.axis(.left_y));
}
