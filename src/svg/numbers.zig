const std = @import("std");
const v = @import("ziggurat_vector");
pub const Scanner = struct {
    input: []const u8,
    at: usize = 0,
    pub fn space(self: *Scanner) bool {
        const before = self.at;
        while (self.at < self.input.len and std.mem.indexOfScalar(u8, " \t\r\n", self.input[self.at]) != null) self.at += 1;
        return before != self.at;
    }
    pub fn number(self: *Scanner) !f64 {
        const begin = self.at;
        if (self.at < self.input.len and (self.input[self.at] == '+' or self.input[self.at] == '-')) self.at += 1;
        var digits: usize = 0;
        while (self.at < self.input.len and std.ascii.isDigit(self.input[self.at])) : (self.at += 1) digits += 1;
        if (self.at < self.input.len and self.input[self.at] == '.') {
            self.at += 1;
            while (self.at < self.input.len and std.ascii.isDigit(self.input[self.at])) : (self.at += 1) digits += 1;
        }
        if (digits == 0) return error.InvalidNumber;
        const mantissa_end = self.at;
        if (self.at < self.input.len and (self.input[self.at] == 'e' or self.input[self.at] == 'E')) {
            self.at += 1;
            if (self.at < self.input.len and (self.input[self.at] == '+' or self.input[self.at] == '-')) self.at += 1;
            const exponent_begin = self.at;
            while (self.at < self.input.len and std.ascii.isDigit(self.input[self.at])) self.at += 1;
            if (self.at == exponent_begin) return error.InvalidNumber;
        }
        const value = std.fmt.parseFloat(f64, self.input[begin..self.at]) catch return error.InvalidNumber;
        if (!std.math.isFinite(value)) return error.InvalidNumber;
        if (value == 0) for (self.input[begin..mantissa_end]) |byte| {
            if (byte >= '1' and byte <= '9') return error.UnsupportedNumberPrecision;
        };
        return value;
    }
};
pub fn scalar(input: []const u8) !f64 {
    var scan: Scanner = .{ .input = input };
    _ = scan.space();
    const value = try scan.number();
    _ = scan.space();
    if (scan.at != input.len) return error.InvalidNumber;
    return value;
}
pub fn list(input: []const u8, output: []f64) ![]f64 {
    var iterator: List = .{ .scan = .{ .input = input } };
    var count: usize = 0;
    while (try iterator.next()) |value| {
        if (count == output.len) return error.NumbersFull;
        output[count] = value;
        count += 1;
    }
    return output[0..count];
}
pub const List = struct {
    scan: Scanner,
    started: bool = false,
    pub fn next(self: *List) !?f64 {
        const spaced = self.scan.space();
        if (self.scan.at == self.scan.input.len) return null;
        if (self.started) {
            if (self.scan.input[self.scan.at] == ',') {
                self.scan.at += 1;
                _ = self.scan.space();
                if (self.scan.at == self.scan.input.len) return error.InvalidNumber;
            } else if (!spaced) return error.NumberSeparatorRequired;
        }
        self.started = true;
        return try self.scan.number();
    }
};
pub const Length = struct {
    value: f64,
    percent: bool = false,
    pub fn resolve(self: Length, reference: f64) !f64 {
        const value = if (self.percent) self.value * reference / 100 else self.value;
        if (!std.math.isFinite(value) or @abs(value) > 1e9) return error.InvalidLength;
        return value;
    }
};
pub fn length(input: []const u8) !Length {
    var scan: Scanner = .{ .input = input };
    _ = scan.space();
    var value = try scan.number();
    const unit_begin = scan.at;
    while (scan.at < input.len and (std.ascii.isAlphabetic(input[scan.at]) or input[scan.at] == '%')) scan.at += 1;
    const original_unit = input[unit_begin..scan.at];
    var unit_storage: [2]u8 = undefined;
    if (original_unit.len > unit_storage.len) return error.UnsupportedLengthUnit;
    for (original_unit, 0..) |byte, i| unit_storage[i] = std.ascii.toLower(byte);
    const unit = unit_storage[0..original_unit.len];
    _ = scan.space();
    if (scan.at != input.len) return error.InvalidLength;
    const ratio: f64 = if (unit.len == 0 or std.mem.eql(u8, unit, "px") or std.mem.eql(u8, unit, "%")) 1 else if (std.mem.eql(u8, unit, "in")) 96 else if (std.mem.eql(u8, unit, "cm")) 96.0 / 2.54 else if (std.mem.eql(u8, unit, "mm")) 96.0 / 25.4 else if (std.mem.eql(u8, unit, "q")) 96.0 / 101.6 else if (std.mem.eql(u8, unit, "pt")) 96.0 / 72.0 else if (std.mem.eql(u8, unit, "pc")) 16 else return error.UnsupportedLengthUnit;
    value *= ratio;
    if (!std.math.isFinite(value) or @abs(value) > 1e9) return error.InvalidLength;
    return .{ .value = value, .percent = std.mem.eql(u8, unit, "%") };
}
pub fn transform(input: []const u8) !v.Transform {
    var scan: Scanner = .{ .input = input };
    var result: v.Transform = .{};
    var count: usize = 0;
    while (true) {
        _ = scan.space();
        if (scan.at == input.len) return result;
        if (count == 32) return error.TransformsFull;
        count += 1;
        const name_begin = scan.at;
        while (scan.at < input.len and std.ascii.isAlphabetic(input[scan.at])) scan.at += 1;
        const name = input[name_begin..scan.at];
        _ = scan.space();
        if (scan.at == input.len or input[scan.at] != '(') return error.InvalidTransform;
        scan.at += 1;
        const args_begin = scan.at;
        while (scan.at < input.len and input[scan.at] != ')') scan.at += 1;
        if (scan.at == input.len) return error.InvalidTransform;
        var storage: [6]f64 = undefined;
        const args = try list(input[args_begin..scan.at], &storage);
        scan.at += 1;
        const local: v.Transform = if (std.mem.eql(u8, name, "matrix") and args.len == 6) .{ .xx = args[0], .yx = args[1], .xy = args[2], .yy = args[3], .x0 = args[4], .y0 = args[5] } else if (std.mem.eql(u8, name, "translate") and (args.len == 1 or args.len == 2)) .{ .x0 = args[0], .y0 = if (args.len == 2) args[1] else 0 } else if (std.mem.eql(u8, name, "scale") and (args.len == 1 or args.len == 2)) .{ .xx = args[0], .yy = if (args.len == 2) args[1] else args[0] } else if (std.mem.eql(u8, name, "rotate") and (args.len == 1 or args.len == 3)) blk: {
            const radians = @mod(args[0], 360) * (std.math.pi / 180.0);
            const cosine = @cos(radians);
            const sine = @sin(radians);
            const x = if (args.len == 3) args[1] else 0;
            const y = if (args.len == 3) args[2] else 0;
            break :blk .{ .xx = cosine, .xy = -sine, .yx = sine, .yy = cosine, .x0 = x - cosine * x + sine * y, .y0 = y - sine * x - cosine * y };
        } else if ((std.mem.eql(u8, name, "skewX") or std.mem.eql(u8, name, "skewY")) and args.len == 1) blk: {
            const tangent = @tan(@mod(args[0], 180) * (std.math.pi / 180.0));
            break :blk if (std.mem.eql(u8, name, "skewX")) .{ .xy = tangent } else .{ .yx = tangent };
        } else return error.InvalidTransform;
        try local.validate();
        result = local.then(result);
        try result.validate();
        const spaced = scan.space();
        if (scan.at < input.len and input[scan.at] == ',') {
            scan.at += 1;
            _ = scan.space();
            if (scan.at == input.len) return error.InvalidTransform;
        } else if (scan.at != input.len and !spaced) return error.TransformSeparatorRequired;
    }
}
