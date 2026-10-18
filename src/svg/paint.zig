const std = @import("std");
const numbers = @import("numbers.zig");
const names = @import("color_names.zig");
pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,
    pub fn rgb(value: u32) Color {
        return .{ .r = @truncate(value >> 16), .g = @truncate(value >> 8), .b = @truncate(value) };
    }
};
pub const Fallback = union(enum) { none, current_color, color: Color };
pub const Paint = union(enum) { none, current_color, color: Color, reference: struct { id: []const u8, fallback: Fallback = .none } };
fn trim(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \t\r\n");
}
fn channel(value: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}
pub fn opacity(input: []const u8) !f64 {
    const value = trim(input);
    if (value.len == 0) return error.InvalidOpacity;
    const percent = value[value.len - 1] == '%';
    return std.math.clamp((try numbers.scalar(if (percent) value[0 .. value.len - 1] else value)) / @as(f64, if (percent) 100 else 1), 0, 1);
}
pub fn parse(input: []const u8) !Paint {
    const value = trim(input);
    if (std.ascii.eqlIgnoreCase(value, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(value, "currentColor")) return .current_color;
    if (std.ascii.startsWithIgnoreCase(value, "url(")) {
        const end = std.mem.indexOfScalarPos(u8, value, 4, ')') orelse return error.InvalidPaint;
        var target = trim(value[4..end]);
        if (target.len >= 2 and (target[0] == '\'' or target[0] == '"') and target[target.len - 1] == target[0]) target = target[1 .. target.len - 1];
        if (target.len < 2 or target[0] != '#') return error.ExternalResourceDenied;
        for (target[1..]) |byte| if (byte <= 32 or byte == 127 or std.mem.indexOfScalar(u8, "#%()\"'\\", byte) != null) return error.InvalidPaint;
        const remaining = trim(value[end + 1 ..]);
        if (remaining.len != 0 and std.mem.indexOfScalar(u8, " \t\r\n", value[end + 1]) == null) return error.InvalidPaint;
        var fallback: Fallback = .none;
        if (remaining.len != 0) {
            if (std.ascii.eqlIgnoreCase(remaining, "currentColor")) fallback = .current_color else if (!std.ascii.eqlIgnoreCase(remaining, "none")) fallback = .{ .color = try color(remaining) };
        }
        return .{ .reference = .{ .id = target[1..], .fallback = fallback } };
    }
    return .{ .color = try color(value) };
}
pub fn color(input: []const u8) !Color {
    const value = trim(input);
    if (value.len == 0) return error.InvalidColor;
    if (std.ascii.eqlIgnoreCase(value, "transparent")) return .{ .a = 0 };
    if (value[0] == '#') {
        const hex = value[1..];
        if (hex.len != 3 and hex.len != 4 and hex.len != 6 and hex.len != 8) return error.InvalidColor;
        for (hex) |byte| if (!std.ascii.isHex(byte)) return error.InvalidColor;
        var rgba: [4]u8 = .{ 0, 0, 0, 255 };
        if (hex.len <= 4) {
            for (hex, 0..) |byte, i| rgba[i] = (std.fmt.charToDigit(byte, 16) catch return error.InvalidColor) * 17;
        } else {
            for (0..hex.len / 2) |i| rgba[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch return error.InvalidColor;
        }
        return .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] };
    }
    if (std.mem.indexOfScalar(u8, value, '(')) |open| {
        if (value[value.len - 1] != ')') return error.InvalidColor;
        const name = value[0..open];
        const hsl = std.ascii.eqlIgnoreCase(name, "hsl") or std.ascii.eqlIgnoreCase(name, "hsla");
        if (!hsl and !std.ascii.eqlIgnoreCase(name, "rgb") and !std.ascii.eqlIgnoreCase(name, "rgba")) return error.UnsupportedColor;
        var scan: numbers.Scanner = .{ .input = value[open + 1 .. value.len - 1] };
        var args: [4]f64 = .{ 0, 0, 0, 1 };
        var percent: [4]bool = @splat(false);
        var count: usize = 0;
        var commas: ?bool = null;
        while (true) {
            _ = scan.space();
            if (scan.at == scan.input.len or count == args.len) return error.InvalidColor;
            args[count] = try scan.number();
            if (hsl and count == 0) {
                const start = scan.at;
                while (scan.at < scan.input.len and std.ascii.isAlphabetic(scan.input[scan.at])) scan.at += 1;
                const unit = scan.input[start..scan.at];
                const ratio: f64 = if (unit.len == 0 or std.ascii.eqlIgnoreCase(unit, "deg")) 1 else if (std.ascii.eqlIgnoreCase(unit, "turn")) 360 else if (std.ascii.eqlIgnoreCase(unit, "grad")) 0.9 else if (std.ascii.eqlIgnoreCase(unit, "rad")) 180.0 / std.math.pi else return error.InvalidColor;
                args[0] *= ratio;
                if (!std.math.isFinite(args[0])) return error.InvalidColor;
            }
            if (scan.at < scan.input.len and scan.input[scan.at] == '%') {
                percent[count] = true;
                scan.at += 1;
            }
            count += 1;
            const spaced = scan.space();
            if (scan.at == scan.input.len) break;
            if (scan.input[scan.at] == ',') {
                if (commas == false) return error.InvalidColor;
                commas = true;
                scan.at += 1;
            } else if (scan.input[scan.at] == '/') {
                if (count != 3 or commas == true) return error.InvalidColor;
                commas = false;
                scan.at += 1;
            } else {
                if (!spaced or commas == true or count == 3) return error.InvalidColor;
                commas = false;
            }
        }
        if (count != 3 and count != 4) return error.InvalidColor;
        const alpha = if (count == 4) channel(args[3] / @as(f64, if (percent[3]) 100 else 1)) else 255;
        if (hsl) {
            if (percent[0] or !percent[1] or !percent[2]) return error.InvalidColor;
            const hue = @mod(args[0], 360) / 60;
            const saturation = std.math.clamp(args[1] / 100, 0, 1);
            const lightness = std.math.clamp(args[2] / 100, 0, 1);
            const chroma = (1 - @abs(2 * lightness - 1)) * saturation;
            const x = chroma * (1 - @abs(@mod(hue, 2) - 1));
            const base = lightness - chroma / 2;
            const rgb: [3]f64 = if (hue < 1) .{ chroma, x, 0 } else if (hue < 2) .{ x, chroma, 0 } else if (hue < 3) .{ 0, chroma, x } else if (hue < 4) .{ 0, x, chroma } else if (hue < 5) .{ x, 0, chroma } else .{ chroma, 0, x };
            return .{ .r = channel(rgb[0] + base), .g = channel(rgb[1] + base), .b = channel(rgb[2] + base), .a = alpha };
        }
        if (commas == true and (percent[0] != percent[1] or percent[0] != percent[2])) return error.InvalidColor;
        return .{ .r = channel(args[0] / @as(f64, if (percent[0]) 100 else 255)), .g = channel(args[1] / @as(f64, if (percent[1]) 100 else 255)), .b = channel(args[2] / @as(f64, if (percent[2]) 100 else 255)), .a = alpha };
    }
    if (value.len > 32) return error.UnsupportedColor;
    var lowercase: [32]u8 = undefined;
    for (value, 0..) |byte, i| lowercase[i] = std.ascii.toLower(byte);
    return Color.rgb(names.values.get(lowercase[0..value.len]) orelse return error.UnsupportedColor);
}
