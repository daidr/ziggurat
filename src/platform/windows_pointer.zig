//! Pens and fingers on Windows, and the cursors Windows has no shape of.
//!
//! Pens and fingers come as WM_POINTER messages, which the window leaves to
//! DefWindowProc to make mouse messages of, as it does for windows that
//! handle none: the window reads their pressure from them, and the mouse
//! messages that follow tell what device they come of.
const std = @import("std");
const core = @import("../root.zig");
const c = @import("ziggurat_c_win32");

pub const wm_pointer_update: c.UINT = 0x0245;
pub const wm_pointer_down: c.UINT = 0x0246;
pub const wm_pointer_up: c.UINT = 0x0247;

const pt_touch = 2;
const pt_pen = 3;
const pen_mask_pressure = 0x1;
const touch_mask_pressure = 0x4;
/// POINTER_MESSAGE_FLAG_CANCELED, in the high word of a WM_POINTER
/// message's wParam.
const pointer_message_flag_canceled = 0x8000;
/// MI_WP_SIGNATURE marks the extra information of mouse messages that
/// Windows makes of a pen's or a finger's, with 0x80 set for a finger's.
const mi_wp_signature: u32 = 0xFF515700;
const signature_mask: u32 = 0xFFFFFF00;

const PointerInfo = extern struct {
    type: u32,
    id: u32,
    frame_id: u32,
    flags: u32,
    source_device: ?*anyopaque,
    target: ?*anyopaque,
    pixel: c.POINT,
    himetric: c.POINT,
    pixel_raw: c.POINT,
    himetric_raw: c.POINT,
    time: u32,
    history_count: u32,
    input_data: i32,
    key_states: u32,
    performance_count: u64,
    button_change_type: u32,
};
const PointerPenInfo = extern struct {
    info: PointerInfo,
    flags: u32,
    mask: u32,
    pressure: u32,
    rotation: u32,
    tilt_x: i32,
    tilt_y: i32,
};
const PointerTouchInfo = extern struct {
    info: PointerInfo,
    flags: u32,
    mask: u32,
    contact: c.RECT,
    contact_raw: c.RECT,
    orientation: u32,
    pressure: u32,
};

const GetPointerType = *const fn (u32, *u32) callconv(.winapi) c.BOOL;
const GetPointerPenInfo = *const fn (u32, *PointerPenInfo) callconv(.winapi) c.BOOL;
const GetPointerTouchInfo = *const fn (u32, *PointerTouchInfo) callconv(.winapi) c.BOOL;
const Procs = struct { kind: ?GetPointerType = null, pen: ?GetPointerPenInfo = null, touch: ?GetPointerTouchInfo = null };
var procs: ?Procs = null;

/// The pointer functions, looked up once: Windows 7 has none.
fn lookup() Procs {
    if (procs) |found| return found;
    var found: Procs = .{};
    if (c.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("user32.dll"))) |module| {
        found.kind = @ptrCast(c.GetProcAddress(module, "GetPointerType"));
        found.pen = @ptrCast(c.GetProcAddress(module, "GetPointerPenInfo"));
        found.touch = @ptrCast(c.GetProcAddress(module, "GetPointerTouchInfo"));
    }
    procs = found;
    return found;
}

/// What a WM_POINTER message tells of its pen or finger.
pub const Sample = struct {
    device: core.PointerDevice,
    /// From 0 to 1; null where the device tells none.
    pressure: ?f32,
    /// Where it is on the screen, in pixels.
    at: c.POINT,
};

pub fn isPointerMessage(message: c.UINT) bool {
    return message == wm_pointer_update or message == wm_pointer_down or message == wm_pointer_up;
}

/// The pen or finger of a WM_POINTER message's pointer id; null for a
/// mouse's, or where Windows tells nothing of it.
pub fn sample(wp: c.WPARAM) ?Sample {
    const found = lookup();
    const id: u32 = @truncate(wp & 0xffff);
    var kind: u32 = 0;
    const get_kind = found.kind orelse return null;
    if (get_kind(id, &kind) == 0) return null;
    switch (kind) {
        pt_pen => {
            var info: PointerPenInfo = std.mem.zeroes(PointerPenInfo);
            const get = found.pen orelse return null;
            if (get(id, &info) == 0) return null;
            return .{ .device = .pen, .pressure = if (info.mask & pen_mask_pressure != 0) pressureOf(info.pressure) else null, .at = info.info.pixel };
        },
        pt_touch => {
            var info: PointerTouchInfo = std.mem.zeroes(PointerTouchInfo);
            const get = found.touch orelse return null;
            if (get(id, &info) == 0) return null;
            return .{ .device = .touch, .pressure = if (info.mask & touch_mask_pressure != 0) pressureOf(info.pressure) else null, .at = info.info.pixel };
        },
        else => return null,
    }
}

/// Windows tells pressure from 0 to 1024.
pub fn pressureOf(raw: u32) f32 {
    return @min(@as(f32, @floatFromInt(raw)) / 1024.0, 1.0);
}

/// Whether a WM_POINTER message's pointer was canceled
/// (IS_POINTER_CANCELED_WPARAM): the system took it, and it ends with no
/// release.
pub fn canceled(wp: c.WPARAM) bool {
    return (wp >> 16) & pointer_message_flag_canceled != 0;
}

/// The device of a mouse message, from its extra information: Windows
/// marks those it makes of a pen's or a finger's.
pub fn deviceOf(extra: usize) core.PointerDevice {
    const low: u32 = @truncate(extra);
    if (low & signature_mask != mi_wp_signature) return .mouse;
    return if (low & 0x80 != 0) .touch else .pen;
}

/// Cursors Windows has no shape of, drawn once and kept: a magnifier with
/// a plus or a minus for zooming in and out, and a white plus with a black
/// edge for a cell.
var drawn: [3]c.HCURSOR = .{ null, null, null };

pub fn drawnCursor(cursor: core.Cursor) c.HCURSOR {
    const slot: usize = switch (cursor) {
        .zoom_in => 0,
        .zoom_out => 1,
        .cell => 2,
        else => return null,
    };
    if (drawn[slot]) |handle| return handle;
    const metric = c.GetSystemMetrics(c.SM_CXCURSOR);
    // Whole words a row.
    const size: usize = @as(usize, @intCast(std.math.clamp(metric, 32, 256))) & ~@as(usize, 15);
    var and_mask: [256 * 256 / 8]u8 = undefined;
    var xor_mask: [256 * 256 / 8]u8 = undefined;
    const hot = masks(cursor, size, and_mask[0 .. size * size / 8], xor_mask[0 .. size * size / 8]);
    drawn[slot] = c.CreateCursor(c.GetModuleHandleW(null), @intCast(hot.x), @intCast(hot.y), @intCast(size), @intCast(size), &and_mask, &xor_mask);
    return drawn[slot];
}

const Hot = struct { x: usize, y: usize };

fn plus(x: f64, y: f64, grow: f64) bool {
    const arm = 10.5;
    const half = 2.5;
    const dx = @abs(x - 16);
    const dy = @abs(y - 16);
    return (dx <= half + grow and dy <= arm + grow) or (dy <= half + grow and dx <= arm + grow);
}

/// The AND and XOR masks of a drawn cursor `size` pixels square, drawn on a
/// grid of 32 and scaled: white where both are clear, black where the AND
/// mask alone is clear, and clear where the AND mask alone is set.
fn masks(cursor: core.Cursor, size: usize, and_mask: []u8, xor_mask: []u8) Hot {
    const f = @as(f64, @floatFromInt(size)) / 32.0;
    const stride = size / 8;
    @memset(and_mask, 0);
    @memset(xor_mask, 0);
    const Shade = enum { clear, black, white };
    const shade = struct {
        fn at(kind: core.Cursor, x: f64, y: f64) Shade {
            if (kind == .cell) {
                if (plus(x, y, 0)) return .white;
                return if (plus(x, y, 1.25)) .black else .clear;
            }
            return lens(kind, x, y);
        }
        fn lens(kind: core.Cursor, x: f64, y: f64) Shade {
            const cx = 12.0;
            const cy = 12.0;
            const r = 9.5;
            const ring = 2.25;
            const d = std.math.hypot(x - cx, y - cy);
            // The handle, along the diagonal from the ring outward.
            const t = @max(0, @min(1, ((x - 17.5) + (y - 17.5)) / 2 / 9.5));
            const hdx = x - (17.5 + 9.5 * t);
            const hdy = y - (17.5 + 9.5 * t);
            var sign = @abs(y - cy) <= 1.25 and @abs(x - cx) <= 4.75;
            if (kind == .zoom_in) sign = sign or (@abs(x - cx) <= 1.25 and @abs(y - cy) <= 4.75);
            const black = (d >= r - ring and (d <= r or std.math.hypot(hdx, hdy) <= 2.25)) or sign;
            if (black) return .black;
            return if (d < r - ring) .white else .clear;
        }
    };
    for (0..size) |j| for (0..size) |i| {
        const x = (@as(f64, @floatFromInt(i)) + 0.5) / f;
        const y = (@as(f64, @floatFromInt(j)) + 0.5) / f;
        var value = shade.at(cursor, x, y);
        if (value == .clear and cursor != .cell) {
            // A white edge around the black, which shows on dark backgrounds.
            outer: for (0..9) |k| {
                const ni = @as(isize, @intCast(i)) + @as(isize, @intCast(k % 3)) - 1;
                const nj = @as(isize, @intCast(j)) + @as(isize, @intCast(k / 3)) - 1;
                if (ni < 0 or nj < 0 or ni >= size or nj >= size) continue;
                const nx = (@as(f64, @floatFromInt(ni)) + 0.5) / f;
                const ny = (@as(f64, @floatFromInt(nj)) + 0.5) / f;
                if (shade.at(cursor, nx, ny) == .black) {
                    value = .white;
                    break :outer;
                }
            }
        }
        const bit = @as(u8, 0x80) >> @intCast(i % 8);
        const index = j * stride + i / 8;
        switch (value) {
            .white => xor_mask[index] |= bit,
            .clear => and_mask[index] |= bit,
            .black => {},
        }
    };
    if (cursor == .cell) return .{ .x = size / 2, .y = size / 2 };
    return .{ .x = @intFromFloat(12 * f), .y = @intFromFloat(12 * f) };
}

test "a pen's and a finger's mouse messages tell their device" {
    try std.testing.expectEqual(core.PointerDevice.mouse, deviceOf(0));
    try std.testing.expectEqual(core.PointerDevice.pen, deviceOf(0xFF515700));
    try std.testing.expectEqual(core.PointerDevice.touch, deviceOf(0xFF515780));
    try std.testing.expectEqual(core.PointerDevice.mouse, deviceOf(0x12345678));
    try std.testing.expect(canceled(0x8000 << 16 | 3));
    try std.testing.expect(!canceled(0x0001 << 16 | 3));
    try std.testing.expectEqual(@as(f32, 0.5), pressureOf(512));
    try std.testing.expectEqual(@as(f32, 1), pressureOf(2048));
}

test "drawn cursors are white inside, black around and clear outside" {
    var and_mask: [32 * 32 / 8]u8 = undefined;
    var xor_mask: [32 * 32 / 8]u8 = undefined;
    const pixel = struct {
        fn of(a: []const u8, x: []const u8, i: usize, j: usize) enum { clear, black, white } {
            const bit = @as(u8, 0x80) >> @intCast(i % 8);
            const index = j * 4 + i / 8;
            if (x[index] & bit != 0) return .white;
            return if (a[index] & bit != 0) .clear else .black;
        }
    };
    var hot = masks(.cell, 32, &and_mask, &xor_mask);
    try std.testing.expectEqual(Hot{ .x = 16, .y = 16 }, hot);
    try std.testing.expectEqual(.white, pixel.of(&and_mask, &xor_mask, 16, 16));
    try std.testing.expectEqual(.black, pixel.of(&and_mask, &xor_mask, 16, 4));
    try std.testing.expectEqual(.clear, pixel.of(&and_mask, &xor_mask, 2, 2));
    hot = masks(.zoom_in, 32, &and_mask, &xor_mask);
    try std.testing.expectEqual(Hot{ .x = 12, .y = 12 }, hot);
    // The plus in the lens, the white lens, and the corner away from it.
    try std.testing.expectEqual(.black, pixel.of(&and_mask, &xor_mask, 12, 12));
    try std.testing.expectEqual(.white, pixel.of(&and_mask, &xor_mask, 8, 8));
    try std.testing.expectEqual(.clear, pixel.of(&and_mask, &xor_mask, 31, 0));
    _ = masks(.zoom_out, 32, &and_mask, &xor_mask);
    // A minus has no upright stroke.
    try std.testing.expectEqual(.white, pixel.of(&and_mask, &xor_mask, 12, 8));
}
