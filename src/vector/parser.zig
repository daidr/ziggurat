const std = @import("std");
const api = @import("root.zig");
const Point = api.Point;

const Lexer = struct {
    bytes: []const u8,
    at: usize = 0,
    first: bool = true,
    fn whitespace(self: *Lexer) void {
        while (self.at < self.bytes.len and isWhitespace(self.bytes[self.at])) : (self.at += 1) {}
    }
    fn separator(self: *Lexer) !void {
        self.whitespace();
        if (self.at < self.bytes.len and self.bytes[self.at] == ',') {
            if (self.first) return error.InvalidPathData;
            self.at += 1;
            self.whitespace();
        }
        self.first = false;
    }
    fn number(self: *Lexer) !f64 {
        try self.separator();
        const start = self.at;
        if (self.at < self.bytes.len and (self.bytes[self.at] == '+' or self.bytes[self.at] == '-')) self.at += 1;
        var digits: usize = 0;
        while (self.at < self.bytes.len and std.ascii.isDigit(self.bytes[self.at])) : (self.at += 1) digits += 1;
        if (self.at < self.bytes.len and self.bytes[self.at] == '.') {
            self.at += 1;
            while (self.at < self.bytes.len and std.ascii.isDigit(self.bytes[self.at])) : (self.at += 1) digits += 1;
        }
        if (digits == 0) return error.InvalidPathData;
        const mantissa_end = self.at;
        if (self.at < self.bytes.len and (self.bytes[self.at] == 'e' or self.bytes[self.at] == 'E')) {
            self.at += 1;
            if (self.at < self.bytes.len and (self.bytes[self.at] == '+' or self.bytes[self.at] == '-')) self.at += 1;
            const exponent = self.at;
            while (self.at < self.bytes.len and std.ascii.isDigit(self.bytes[self.at])) : (self.at += 1) {}
            if (exponent == self.at) return error.InvalidPathData;
        }
        if (self.at - start > 128) return error.InvalidPathData;
        const value = std.fmt.parseFloat(f64, self.bytes[start..self.at]) catch return error.InvalidPathData;
        if (!std.math.isFinite(value)) return error.InvalidPathData;
        if (value == 0) for (self.bytes[start..mantissa_end]) |digit| {
            // Turning a nonzero radius into zero changes an arc into a line.
            // Reject underflow instead of silently changing its topology.
            if (digit >= '1' and digit <= '9') return error.UnsupportedNumberPrecision;
        };
        return value;
    }
    fn flag(self: *Lexer) !bool {
        try self.separator();
        if (self.at == self.bytes.len or (self.bytes[self.at] != '0' and self.bytes[self.at] != '1')) return error.InvalidPathData;
        const value = self.bytes[self.at] == '1';
        self.at += 1;
        return value;
    }
    fn point(self: *Lexer, base: Point) !Point {
        const p: Point = .{ .x = base.x + try self.number(), .y = base.y + try self.number() };
        try api.validPoint(p);
        return p;
    }
};
fn isWhitespace(char: u8) bool {
    return char == ' ' or char == '\t' or char == '\r' or char == '\n';
}
fn reflected(control: Point, pen: Point) Point {
    return .{ .x = 2 * pen.x - control.x, .y = 2 * pen.y - control.y };
}
const Writer = struct {
    output: ?[]api.Command,
    count: usize = 0,
    limit: usize,
    fn append(self: *Writer, command: api.Command) !void {
        if (self.count == self.limit) return error.CapacityExceeded;
        if (self.output) |output| output[self.count] = command;
        self.count += 1;
    }
};

/// The count and output passes use exactly the same lexer and expansion.
pub fn parse(bytes: []const u8, output: ?[]api.Command, options: api.ParseOptions) !usize {
    var lexer: Lexer = .{ .bytes = bytes };
    var writer: Writer = .{ .output = output, .limit = options.limits.commands };
    var command: u8 = 0;
    var previous: u8 = 0;
    var pen: Point = .{};
    var start: Point = .{};
    var control: Point = .{};
    var seen_move = false;
    var open = false;
    while (true) {
        if (options.cancellation) |cancel| try cancel.check();
        lexer.whitespace();
        if (lexer.at == bytes.len) return writer.count;
        const char = bytes[lexer.at];
        if (std.ascii.isAlphabetic(char)) {
            if (std.mem.indexOfScalar(u8, "MmZzLlHhVvCcSsQqTtAa", char) == null) return error.InvalidPathData;
            command = char;
            lexer.at += 1;
            lexer.first = true;
        } else if (command == 0) return error.InvalidPathData;
        const kind = std.ascii.toUpper(command);
        const base = if (std.ascii.isLower(command)) pen else Point{};
        if (!seen_move and kind != 'M') return error.MoveRequired;
        if (kind == 'Z') {
            if (open) try writer.append(.close);
            pen = start;
            previous = kind;
            command = 0;
            open = false;
            continue;
        }
        if (!open and kind != 'M') {
            try writer.append(.{ .move = pen });
            open = true;
        }
        switch (kind) {
            'M' => {
                pen = try lexer.point(base);
                start = pen;
                seen_move = true;
                open = true;
                try writer.append(.{ .move = pen });
                command = if (command == 'm') 'l' else 'L';
            },
            'L' => {
                pen = try lexer.point(base);
                try writer.append(.{ .line = pen });
            },
            'H' => {
                pen.x = base.x + try lexer.number();
                try api.validPoint(pen);
                try writer.append(.{ .line = pen });
            },
            'V' => {
                pen.y = base.y + try lexer.number();
                try api.validPoint(pen);
                try writer.append(.{ .line = pen });
            },
            'C', 'S' => {
                const first = if (kind == 'S') (if (previous == 'C' or previous == 'S') reflected(control, pen) else pen) else try lexer.point(base);
                try api.validPoint(first);
                const second = try lexer.point(base);
                const end = try lexer.point(base);
                try writer.append(.{ .cubic = .{ .first = first, .second = second, .end = end } });
                control = second;
                pen = end;
            },
            'Q', 'T' => {
                const first = if (kind == 'T') (if (previous == 'Q' or previous == 'T') reflected(control, pen) else pen) else try lexer.point(base);
                try api.validPoint(first);
                const end = try lexer.point(base);
                try writer.append(.{ .quadratic = .{ .control = first, .end = end } });
                control = first;
                pen = end;
            },
            'A' => {
                const radius: Point = .{ .x = try lexer.number(), .y = try lexer.number() };
                const rotation = try lexer.number();
                const large = try lexer.flag();
                const sweep = try lexer.flag();
                const end = try lexer.point(base);
                try api.validPoint(radius);
                if (@abs(rotation) > 1e9) return error.InvalidGeometry;
                try writer.append(.{ .arc = .{ .radius = radius, .rotation = rotation, .large = large, .sweep = sweep, .end = end } });
                pen = end;
            },
            else => unreachable,
        }
        previous = kind;
    }
}
