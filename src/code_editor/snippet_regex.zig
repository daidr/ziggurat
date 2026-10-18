const std = @import("std");

/// Logical work units are charged for instructions, class terms and capture
/// writes as well as input/output visits. Cancellation never invokes a callback.
pub const Work = struct {
    limit: usize,
    used: usize = 0,
    cancellation: ?*const std.atomic.Value(bool) = null,
    pub fn charge(self: *Work, count: usize) !void {
        if (self.cancellation) |flag| if (flag.load(.acquire)) return error.Cancelled;
        if (count > self.limit -| self.used) return error.WorkExceeded;
        self.used += count;
    }
};
pub const Limits = struct {
    pattern_bytes: usize = 4096,
    nodes: usize = 2048,
    instructions: usize = 128,
    class_ranges: usize = 1024,
    captures: usize = 16,
    depth: usize = 32,
    repeat: usize = 1024,
    bytes: usize = 4 * 1024 * 1024,
    work: usize = 4 * 1024 * 1024,
    cancellation: ?*const std.atomic.Value(bool) = null,
    fn validate(self: Limits) !void {
        if (self.pattern_bytes > 65536 or self.nodes == 0 or self.nodes > 65536 or self.instructions == 0 or self.instructions > 4096 or self.class_ranges > 16384 or self.captures > 64 or self.depth == 0 or self.depth > 64 or self.repeat > 65536 or self.bytes > 64 * 1024 * 1024 or self.bytes < @sizeOf(Program) or self.work == 0 or self.work > 128 * 1024 * 1024) return error.InvalidLimits;
    }
};
pub const Flags = struct {
    global: bool = false,
    ignore_case: bool = false,
    multiline: bool = false,
    dot_all: bool = false,
    unicode: bool = false,
    pub fn parse(input: []const u8) !Flags {
        var result: Flags = .{};
        var seen: u8 = 0;
        for (input) |byte| {
            const bit: u8 = switch (byte) {
                'g' => 1,
                'i' => 2,
                'm' => 4,
                's' => 8,
                'u' => 16,
                else => return error.UnsupportedRegexFlag,
            };
            if (seen & bit != 0) return error.InvalidRegexFlag;
            seen |= bit;
        }
        result.global = seen & 1 != 0;
        result.ignore_case = seen & 2 != 0;
        result.multiline = seen & 4 != 0;
        result.dot_all = seen & 8 != 0;
        result.unicode = seen & 16 != 0;
        return result;
    }
};
pub const Range = struct { start: usize, end: usize };
const CharacterRange = struct { first: u32, last: u32 };
const Inst = struct {
    kind: enum { accept, literal, class, any, split, save, clear, start, end, boundary },
    next: u32 = 0,
    a: u32 = 0,
    b: u32 = 0,
    negate: bool = false,
};
const Node = struct {
    kind: enum { empty, literal, class, any, concat, alt, capture, repeat, start, end, boundary },
    a: usize = 0,
    b: usize = 0,
    min: usize = 0,
    max: ?usize = null,
    greedy: bool = true,
    negate: bool = false,
    nullable: bool = false,
    capture_first: usize = 0,
    capture_end: usize = 0,
};
/// Linear owning value: moving is allowed, copying ownership is not. Arrays do
/// not point into this shell or the caller's pattern. Keep its address stable
/// while an explicit Cursor borrows it.
pub const Program = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    code: []Inst,
    ranges: []CharacterRange,
    order: []u32,
    entry: u32,
    flags: Flags,
    captures: usize,
    peak_bytes: usize,
    compile_work: usize,
    clients: usize = 0,
    live: bool = true,
    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, options: []const u8, limits: Limits) !Program {
        try limits.validate();
        var work: Work = .{ .limit = limits.work, .cancellation = limits.cancellation };
        try work.charge(0);
        if (pattern.len > limits.pattern_bytes) return error.CapacityExceeded;
        const flags = try Flags.parse(options);
        if (!std.unicode.utf8ValidateSlice(pattern)) return error.InvalidUtf8;
        var budget: Budget = .{ .child = allocator, .limit = limits.bytes - @sizeOf(Program) };
        var builder: Builder = .{ .allocator = budget.allocator(), .limits = limits, .flags = flags, .work = work };
        var builder_live = true;
        defer if (builder_live) builder.deinit();
        var result = builder.build(allocator, pattern, &budget) catch |err| return if (err == error.OutOfMemory and budget.denied) error.CapacityExceeded else err;
        errdefer result.deinit() catch unreachable;
        builder_live = false;
        builder.deinit();
        try builder.work.charge(0);
        return result;
    }
    fn check(self: *const Program) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (!self.live) return error.Closed;
    }
    pub fn deinit(self: *Program) !void {
        try self.check();
        if (self.clients != 0) return error.ClientsAlive;
        self.live = false;
        const allocator = self.allocator;
        const code = self.code;
        const ranges = self.ranges;
        const order = self.order;
        self.code = &.{};
        self.ranges = &.{};
        self.order = &.{};
        allocator.free(code);
        allocator.free(ranges);
        allocator.free(order);
    }
};
const Builder = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    flags: Flags,
    work: Work,
    input: []u32 = &.{},
    at: usize = 0,
    capture_count: usize = 0,
    nodes: std.ArrayList(Node) = .empty,
    code: std.ArrayList(Inst) = .empty,
    ranges: std.ArrayList(CharacterRange) = .empty,
    fn deinit(self: *Builder) void {
        self.allocator.free(self.input);
        self.nodes.deinit(self.allocator);
        self.code.deinit(self.allocator);
        self.ranges.deinit(self.allocator);
    }
    fn add(self: *Builder, node: Node) !usize {
        try self.work.charge(1);
        if (self.nodes.items.len == self.limits.nodes) return error.CapacityExceeded;
        try self.nodes.append(self.allocator, node);
        return self.nodes.items.len - 1;
    }
    fn emit(self: *Builder, inst: Inst) !u32 {
        try self.work.charge(1);
        if (self.code.items.len == self.limits.instructions) return error.CapacityExceeded;
        try self.code.append(self.allocator, inst);
        return @intCast(self.code.items.len - 1);
    }
    fn take(self: *Builder, value: u32) bool {
        if (self.at < self.input.len and self.input[self.at] == value) {
            self.at += 1;
            return true;
        }
        return false;
    }
    fn join(self: *Builder, kind: @FieldType(Node, "kind"), left: usize, right: usize) !usize {
        const a = self.nodes.items[left];
        const b = self.nodes.items[right];
        return self.add(.{ .kind = kind, .a = left, .b = right, .nullable = if (kind == .concat) a.nullable and b.nullable else a.nullable or b.nullable, .capture_first = a.capture_first, .capture_end = b.capture_end });
    }
    fn pushTree(self: *Builder, bins: *[17]?usize, kind: @FieldType(Node, "kind"), value: usize) !void {
        var index: usize = 0;
        var merged = value;
        while (bins[index]) |left| : (index += 1) {
            merged = try self.join(kind, left, merged);
            bins[index] = null;
        }
        bins[index] = merged;
    }
    fn finishTree(self: *Builder, bins: *[17]?usize, kind: @FieldType(Node, "kind")) !?usize {
        var result: ?usize = null;
        var remaining = bins.len;
        while (remaining != 0) {
            remaining -= 1;
            if (bins[remaining]) |value| {
                result = if (result) |left| try self.join(kind, left, value) else value;
            }
        }
        return result;
    }
    fn expression(self: *Builder, depth: usize) anyerror!usize {
        if (depth > self.limits.depth) return error.CapacityExceeded;
        var bins: [17]?usize = @splat(null);
        try self.pushTree(&bins, .alt, try self.sequence(depth));
        while (self.take('|')) try self.pushTree(&bins, .alt, try self.sequence(depth));
        return (try self.finishTree(&bins, .alt)).?;
    }
    fn sequence(self: *Builder, depth: usize) anyerror!usize {
        var bins: [17]?usize = @splat(null);
        const first_capture = self.capture_count + 1;
        while (self.at < self.input.len and self.input[self.at] != ')' and self.input[self.at] != '|') try self.pushTree(&bins, .concat, try self.quantified(depth));
        return (try self.finishTree(&bins, .concat)) orelse try self.add(.{ .kind = .empty, .nullable = true, .capture_first = first_capture, .capture_end = self.capture_count + 1 });
    }
    fn number(self: *Builder) !usize {
        const begin = self.at;
        var result: usize = 0;
        while (self.at < self.input.len and self.input[self.at] >= '0' and self.input[self.at] <= '9') : (self.at += 1) {
            try self.work.charge(1);
            result = std.math.mul(usize, result, 10) catch return error.CapacityExceeded;
            result = std.math.add(usize, result, self.input[self.at] - '0') catch return error.CapacityExceeded;
            if (result > self.limits.repeat) return error.CapacityExceeded;
        }
        if (begin == self.at) return error.InvalidRegex;
        return result;
    }
    fn quantified(self: *Builder, depth: usize) anyerror!usize {
        const atom = try self.parseAtom(depth);
        if (self.at == self.input.len) return atom;
        const next = self.input[self.at];
        var min: usize = 0;
        var max: ?usize = null;
        switch (next) {
            '*' => self.at += 1,
            '+' => {
                self.at += 1;
                min = 1;
            },
            '?' => {
                self.at += 1;
                max = 1;
            },
            '{' => {
                self.at += 1;
                min = try self.number();
                max = min;
                if (self.take(',')) max = if (self.at < self.input.len and self.input[self.at] != '}') try self.number() else null;
                if (!self.take('}') or (max != null and max.? < min)) return error.InvalidRegex;
            },
            else => return atom,
        }
        const child = self.nodes.items[atom];
        if (child.nullable and (max == null or max.? != 0)) return error.UnsupportedNullableRepeat;
        return self.add(.{ .kind = .repeat, .a = atom, .min = min, .max = max, .greedy = !self.take('?'), .nullable = min == 0, .capture_first = child.capture_first, .capture_end = child.capture_end });
    }
    fn literal(self: *Builder, value: u32) !usize {
        if (self.flags.ignore_case and value > 127) return error.UnsupportedRegexCase;
        return self.add(.{ .kind = .literal, .a = value, .capture_first = self.capture_count + 1, .capture_end = self.capture_count + 1 });
    }
    fn hex(self: *Builder, count: usize) !u32 {
        if (count > self.input.len - self.at) return error.InvalidRegex;
        var result: u32 = 0;
        for (0..count) |_| {
            try self.work.charge(1);
            const c = self.input[self.at];
            self.at += 1;
            const n: u32 = if (c >= '0' and c <= '9') c - '0' else if (c >= 'a' and c <= 'f') c - 'a' + 10 else if (c >= 'A' and c <= 'F') c - 'A' + 10 else return error.InvalidRegex;
            result = result * 16 + n;
        }
        return result;
    }
    fn readEscape(self: *Builder, in_class: bool) !u32 {
        if (self.at == self.input.len) return error.InvalidRegex;
        const value = self.input[self.at];
        self.at += 1;
        return switch (value) {
            'n' => 10,
            'r' => 13,
            't' => 9,
            'f' => 12,
            'v' => 11,
            '0' => if (self.at < self.input.len and self.input[self.at] >= '0' and self.input[self.at] <= '9') error.UnsupportedRegex else 0,
            'x' => self.hex(2),
            'u' => block: {
                if (self.flags.unicode and self.take('{')) {
                    var result: u32 = 0;
                    var digits: usize = 0;
                    while (self.at < self.input.len and self.input[self.at] != '}') {
                        if (digits == 6) return error.InvalidRegex;
                        result = result * 16 + try self.hex(1);
                        digits += 1;
                    }
                    if (digits == 0 or !self.take('}') or result > 0x10ffff) return error.InvalidRegex;
                    break :block result;
                }
                const first = try self.hex(4);
                if (self.flags.unicode and first >= 0xd800 and first <= 0xdbff and self.input.len - self.at >= 6 and self.input[self.at] == '\\' and self.input[self.at + 1] == 'u') {
                    const saved = self.at;
                    self.at += 2;
                    const second = try self.hex(4);
                    if (second >= 0xdc00 and second <= 0xdfff) break :block 0x10000 + ((first - 0xd800) << 10) + second - 0xdc00;
                    self.at = saved;
                }
                break :block first;
            },
            '-' => if (self.flags.unicode and !in_class) error.InvalidRegex else value,
            '\\', '/', '.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|' => value,
            else => error.UnsupportedRegex,
        };
    }
    fn appendRange(self: *Builder, first: u32, last: u32) !void {
        try self.work.charge(1);
        if (first > last) return error.InvalidRegex;
        if (self.ranges.items.len == self.limits.class_ranges) return error.CapacityExceeded;
        try self.ranges.append(self.allocator, .{ .first = first, .last = last });
    }
    fn builtin(self: *Builder, value: u32) !void {
        const digit = [_]CharacterRange{.{ .first = '0', .last = '9' }};
        const word = [_]CharacterRange{ .{ .first = '0', .last = '9' }, .{ .first = 'A', .last = 'Z' }, .{ .first = '_', .last = '_' }, .{ .first = 'a', .last = 'z' } };
        // ECMAScript WhiteSpace and LineTerminator, independent of locale.
        const space = [_]CharacterRange{ .{ .first = 9, .last = 13 }, .{ .first = 0x20, .last = 0x20 }, .{ .first = 0xa0, .last = 0xa0 }, .{ .first = 0x1680, .last = 0x1680 }, .{ .first = 0x2000, .last = 0x200a }, .{ .first = 0x2028, .last = 0x2029 }, .{ .first = 0x202f, .last = 0x202f }, .{ .first = 0x205f, .last = 0x205f }, .{ .first = 0x3000, .last = 0x3000 }, .{ .first = 0xfeff, .last = 0xfeff } };
        const base: []const CharacterRange = switch (value) {
            'd', 'D' => &digit,
            'w', 'W' => &word,
            's', 'S' => &space,
            else => unreachable,
        };
        if (value >= 'a') {
            for (base) |range| try self.appendRange(range.first, range.last);
            return;
        }
        var begin: u32 = 0;
        for (base) |range| {
            if (begin < range.first) try self.appendRange(begin, range.first - 1);
            begin = range.last + 1;
        }
        try self.appendRange(begin, if (self.flags.unicode) 0x10ffff else 0xffff);
    }
    fn classAtom(self: *Builder) !?u32 {
        if (self.at == self.input.len) return error.InvalidRegex;
        if (self.take('\\')) {
            if (self.at == self.input.len) return error.InvalidRegex;
            const c = self.input[self.at];
            if (c == 'd' or c == 'D' or c == 'w' or c == 'W' or c == 's' or c == 'S') {
                self.at += 1;
                try self.builtin(c);
                return null;
            }
            if (c == 'b') {
                self.at += 1;
                return 8;
            }
            return try self.readEscape(true);
        }
        const result = self.input[self.at];
        self.at += 1;
        return result;
    }
    fn characterClass(self: *Builder) !usize {
        const negate = self.take('^');
        const first = self.ranges.items.len;
        while (self.at < self.input.len and self.input[self.at] != ']') {
            const begin = try self.classAtom();
            if (begin) |value| {
                if (self.flags.ignore_case and value > 127) return error.UnsupportedRegexCase;
                if (self.at + 1 < self.input.len and self.input[self.at] == '-' and self.input[self.at + 1] != ']') {
                    self.at += 1;
                    const end = try self.classAtom() orelse return error.InvalidRegex;
                    if (self.flags.ignore_case and end > 127) return error.UnsupportedRegexCase;
                    try self.appendRange(value, end);
                } else try self.appendRange(value, value);
            }
        }
        if (!self.take(']')) return error.InvalidRegex;
        return self.add(.{ .kind = .class, .a = first, .b = self.ranges.items.len, .negate = negate, .capture_first = self.capture_count + 1, .capture_end = self.capture_count + 1 });
    }
    fn parseAtom(self: *Builder, depth: usize) anyerror!usize {
        try self.work.charge(1);
        const c = self.input[self.at];
        self.at += 1;
        switch (c) {
            '(' => {
                const first = self.capture_count + 1;
                var capturing = true;
                if (self.take('?')) {
                    if (!self.take(':')) return error.UnsupportedRegex;
                    capturing = false;
                }
                var capture: usize = 0;
                if (capturing) {
                    if (self.capture_count == self.limits.captures) return error.CapacityExceeded;
                    self.capture_count += 1;
                    capture = self.capture_count;
                }
                const inner = try self.expression(depth + 1);
                if (!self.take(')')) return error.InvalidRegex;
                if (!capturing) return inner;
                return self.add(.{ .kind = .capture, .a = inner, .b = capture, .nullable = self.nodes.items[inner].nullable, .capture_first = first, .capture_end = self.capture_count + 1 });
            },
            '[' => return self.characterClass(),
            '.' => return self.add(.{ .kind = .any, .capture_first = self.capture_count + 1, .capture_end = self.capture_count + 1 }),
            '^', '$' => return self.add(.{ .kind = if (c == '^') .start else .end, .nullable = true, .capture_first = self.capture_count + 1, .capture_end = self.capture_count + 1 }),
            '\\' => {
                if (self.at == self.input.len) return error.InvalidRegex;
                const escaped = self.input[self.at];
                if (escaped == 'b' or escaped == 'B') {
                    self.at += 1;
                    return self.add(.{ .kind = .boundary, .negate = escaped == 'B', .nullable = true, .capture_first = self.capture_count + 1, .capture_end = self.capture_count + 1 });
                }
                if (escaped == 'd' or escaped == 'D' or escaped == 'w' or escaped == 'W' or escaped == 's' or escaped == 'S') {
                    self.at += 1;
                    const begin = self.ranges.items.len;
                    try self.builtin(escaped);
                    return self.add(.{ .kind = .class, .a = begin, .b = self.ranges.items.len, .capture_first = self.capture_count + 1, .capture_end = self.capture_count + 1 });
                }
                return self.literal(try self.readEscape(false));
            },
            ']' => if (self.flags.unicode) return error.InvalidRegex else return self.literal(c),
            ')', '*', '+', '?', '{', '}' => return error.InvalidRegex,
            else => return self.literal(c),
        }
    }
    fn repeated(self: *Builder, child: usize, next: u32) anyerror!u32 {
        const node = self.nodes.items[child];
        const entry = try self.compileNode(child, next);
        if (node.capture_first == node.capture_end) return entry;
        return self.emit(.{ .kind = .clear, .next = entry, .a = @intCast(node.capture_first), .b = @intCast(node.capture_end) });
    }
    fn compileNode(self: *Builder, index: usize, next: u32) anyerror!u32 {
        try self.work.charge(1);
        const node = self.nodes.items[index];
        switch (node.kind) {
            .empty => return next,
            .literal => return self.emit(.{ .kind = .literal, .next = next, .a = @intCast(node.a) }),
            .class => return self.emit(.{ .kind = .class, .next = next, .a = @intCast(node.a), .b = @intCast(node.b), .negate = node.negate }),
            .any => return self.emit(.{ .kind = .any, .next = next }),
            .start, .end, .boundary => return self.emit(.{ .kind = switch (node.kind) {
                .start => .start,
                .end => .end,
                .boundary => .boundary,
                else => unreachable,
            }, .next = next, .negate = node.negate }),
            .concat => return self.compileNode(node.a, try self.compileNode(node.b, next)),
            .alt => {
                const left = try self.compileNode(node.a, next);
                const right = try self.compileNode(node.b, next);
                return self.emit(.{ .kind = .split, .a = left, .b = right });
            },
            .capture => {
                const end = try self.emit(.{ .kind = .save, .next = next, .a = @intCast(node.b * 2 + 1) });
                return self.emit(.{ .kind = .save, .next = try self.compileNode(node.a, end), .a = @intCast(node.b * 2) });
            },
            .repeat => {
                var tail = next;
                if (node.max) |maximum| {
                    for (0..maximum - node.min) |_| {
                        const body = try self.repeated(node.a, tail);
                        tail = try self.emit(.{ .kind = .split, .a = if (node.greedy) body else tail, .b = if (node.greedy) tail else body });
                    }
                } else {
                    const split = try self.emit(.{ .kind = .split });
                    const body = try self.repeated(node.a, split);
                    self.code.items[split].a = if (node.greedy) body else next;
                    self.code.items[split].b = if (node.greedy) next else body;
                    tail = split;
                }
                for (0..node.min) |_| tail = try self.repeated(node.a, tail);
                return tail;
            },
        }
    }
    fn build(self: *Builder, child: std.mem.Allocator, pattern: []const u8, budget: *Budget) !Program {
        try self.work.charge(pattern.len * 2);
        self.input = try self.allocator.alloc(u32, pattern.len);
        var utf8 = (try std.unicode.Utf8View.init(pattern)).iterator();
        var count: usize = 0;
        while (utf8.nextCodepoint()) |cp| {
            if (!self.flags.unicode and cp > 0xffff) {
                self.input[count] = 0xd800 + ((cp - 0x10000) >> 10);
                count += 1;
                self.input[count] = 0xdc00 + ((cp - 0x10000) & 1023);
                count += 1;
            } else {
                self.input[count] = cp;
                count += 1;
            }
        }
        const full_input = self.input;
        defer self.input = full_input;
        self.input = full_input[0..count];
        const root = try self.expression(0);
        if (self.at != self.input.len) return error.InvalidRegex;
        const end = try self.emit(.{ .kind = .accept });
        const entry = try self.compileNode(root, end);
        const order = try self.allocator.alloc(u32, self.code.items.len);
        errdefer self.allocator.free(order);
        const colors = try self.allocator.alloc(u2, self.code.items.len);
        defer self.allocator.free(colors);
        @memset(colors, 0);
        const frames = try self.allocator.alloc(struct { pc: u32, edge: u2 = 0 }, self.code.items.len);
        defer self.allocator.free(frames);
        var written: usize = 0;
        for (0..self.code.items.len) |pc| {
            if (colors[pc] != 0) continue;
            var len: usize = 1;
            frames[0] = .{ .pc = @intCast(pc) };
            colors[pc] = 1;
            while (len != 0) {
                try self.work.charge(1);
                const frame = &frames[len - 1];
                const inst = self.code.items[frame.pc];
                const edge: ?u32 = switch (inst.kind) {
                    .split => if (frame.edge == 0) inst.a else if (frame.edge == 1) inst.b else null,
                    .save, .clear, .start, .end, .boundary => if (frame.edge == 0) inst.next else null,
                    else => null,
                };
                frame.edge += 1;
                if (edge) |target| {
                    if (colors[target] == 1) return error.UnsupportedNullableRepeat;
                    if (colors[target] == 0) {
                        colors[target] = 1;
                        frames[len] = .{ .pc = target };
                        len += 1;
                    }
                } else {
                    colors[frame.pc] = 2;
                    order[written] = frame.pc;
                    written += 1;
                    len -= 1;
                }
            }
        }
        std.debug.assert(written == order.len);
        const code = try self.code.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(code);
        const ranges = try self.ranges.toOwnedSlice(self.allocator);
        return .{ .allocator = child, .owner = std.Thread.getCurrentId(), .code = code, .ranges = ranges, .order = order, .entry = entry, .flags = self.flags, .captures = self.capture_count, .peak_bytes = budget.peak + @sizeOf(Program), .compile_work = self.work.used };
    }
};
const Budget = struct {
    child: std.mem.Allocator,
    limit: usize,
    live: usize = 0,
    peak: usize = 0,
    denied: bool = false,
    fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, bytes: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        if (bytes > self.limit -| self.live) {
            self.denied = true;
            return null;
        }
        const result = self.child.rawAlloc(bytes, alignment, ret) orelse return null;
        self.live += bytes;
        self.peak = @max(self.peak, self.live);
        return result;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        self.child.rawFree(bytes, alignment, ret);
        self.live -= bytes.len;
    }
};

pub const WorkspaceLimits = struct { instructions: usize = 128, captures: usize = 16, input_bytes: usize = 16384, bytes: usize = 1024 * 1024 };
pub const Capture = struct { start: ?usize = null, end: ?usize = null };
pub const Match = struct {
    range: Range,
    captures: []const Capture,
    pub fn capture(self: Match, index: usize) ?Range {
        if (index >= self.captures.len) return null;
        const value = self.captures[index];
        return .{ .start = value.start orelse return null, .end = value.end orelse return null };
    }
};
/// Caller-owned linear workspace. create is the only allocation path; prepare,
/// search and prioritized capture reconstruction allocate nothing. At most one
/// Cursor borrows it. The Program must remain at a stable address until end.
pub const Workspace = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    limits: WorkspaceLimits,
    input: []u16,
    table: []u8,
    captures: []Capture,
    length: usize = 0,
    stride: usize = 0,
    active: bool = false,
    live: bool = true,
    owned_bytes: usize,
    pub fn requiredBytes(limits: WorkspaceLimits) !usize {
        if (limits.instructions == 0 or limits.instructions > 4096 or limits.captures > 64 or limits.input_bytes > 1024 * 1024 or limits.bytes > 64 * 1024 * 1024) return error.InvalidLimits;
        const stride = (limits.instructions + 7) / 8;
        const positions = std.math.add(usize, limits.input_bytes, 1) catch return error.CapacityExceeded;
        var total: usize = @sizeOf(Workspace);
        for ([_]struct { usize, usize }{ .{ positions, stride }, .{ limits.input_bytes, @sizeOf(u16) }, .{ limits.captures + 1, @sizeOf(Capture) } }) |part| {
            total = std.math.add(usize, total, std.math.mul(usize, part[0], part[1]) catch return error.CapacityExceeded) catch return error.CapacityExceeded;
        }
        if (total > limits.bytes) return error.CapacityExceeded;
        return total;
    }
    pub fn init(allocator: std.mem.Allocator, limits: WorkspaceLimits) !Workspace {
        const bytes = try requiredBytes(limits);
        const input = try allocator.alloc(u16, limits.input_bytes);
        errdefer allocator.free(input);
        const table = try allocator.alloc(u8, (limits.input_bytes + 1) * ((limits.instructions + 7) / 8));
        errdefer allocator.free(table);
        const captures = try allocator.alloc(Capture, limits.captures + 1);
        return .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .limits = limits, .input = input, .table = table, .captures = captures, .owned_bytes = bytes };
    }
    fn check(self: *const Workspace) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (!self.live) return error.Closed;
        if (self.active) return error.Busy;
    }
    pub fn deinit(self: *Workspace) !void {
        try self.check();
        self.live = false;
        const allocator = self.allocator;
        const input = self.input;
        const table = self.table;
        const captures = self.captures;
        self.input = &.{};
        self.table = &.{};
        self.captures = &.{};
        allocator.free(input);
        allocator.free(table);
        allocator.free(captures);
    }
    pub fn begin(self: *Workspace, program: *Program, input: []const u8, work: *Work) !Cursor {
        try self.check();
        try program.check();
        if (input.len > self.limits.input_bytes or program.code.len > self.limits.instructions or program.captures > self.limits.captures) return error.CapacityExceeded;
        try work.charge(input.len * 2);
        if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
        var utf8 = (try std.unicode.Utf8View.init(input)).iterator();
        var count: usize = 0;
        while (utf8.nextCodepoint()) |cp| {
            if (program.flags.ignore_case and cp > 127) return error.UnsupportedRegexCase;
            if (cp <= 0xffff) {
                self.input[count] = @intCast(cp);
                count += 1;
            } else {
                self.input[count] = @intCast(0xd800 + ((cp - 0x10000) >> 10));
                self.input[count + 1] = @intCast(0xdc00 + ((cp - 0x10000) & 1023));
                count += 2;
            }
        }
        self.length = count;
        self.stride = (program.code.len + 7) / 8;
        const cells = std.math.mul(usize, count + 1, program.code.len) catch return error.CapacityExceeded;
        try work.charge(cells);
        program.clients = std.math.add(usize, program.clients, 1) catch return error.CapacityExceeded;
        self.active = true;
        errdefer {
            self.active = false;
            program.clients -= 1;
        }
        var remaining = count + 1;
        while (remaining != 0) {
            remaining -= 1;
            const at = remaining;
            try work.charge(0);
            const current_scalar = self.scalar(at, program.flags.unicode);
            for (program.order) |pc| {
                const inst = program.code[pc];
                const value: bool = switch (inst.kind) {
                    .accept => true,
                    .literal => at < count and equal(current_scalar.value, inst.a, program.flags.ignore_case) and self.get(at + current_scalar.width, inst.next),
                    .any => at < count and (program.flags.dot_all or !newline(current_scalar.value)) and self.get(at + current_scalar.width, inst.next),
                    .class => at < count and try classMatches(program, inst, current_scalar.value, work) and self.get(at + current_scalar.width, inst.next),
                    .split => self.get(at, inst.a) or self.get(at, inst.b),
                    .save, .clear => self.get(at, inst.next),
                    .start => (at == 0 or (program.flags.multiline and newline(self.input[at - 1]))) and self.get(at, inst.next),
                    .end => (at == count or (program.flags.multiline and newline(self.input[at]))) and self.get(at, inst.next),
                    .boundary => ((wordCharacter(if (at == 0) 0 else self.input[at - 1]) != wordCharacter(if (at == count) 0 else self.input[at])) != inst.negate) and self.get(at, inst.next),
                };
                self.set(at, pc, value);
            }
        }
        return .{ .workspace = self, .program = program, .work = work };
    }
    pub fn units(self: *const Workspace) []const u16 {
        return self.input[0..self.length];
    }
    fn scalar(self: *const Workspace, at: usize, unicode: bool) struct { value: u32, width: usize } {
        if (at == self.length) return .{ .value = 0, .width = 0 };
        const a = self.input[at];
        if (unicode and a >= 0xd800 and a <= 0xdbff and at + 1 < self.length) {
            const b = self.input[at + 1];
            if (b >= 0xdc00 and b <= 0xdfff) return .{ .value = 0x10000 + ((@as(u32, a) - 0xd800) << 10) + b - 0xdc00, .width = 2 };
        }
        return .{ .value = a, .width = 1 };
    }
    fn get(self: *const Workspace, position: usize, pc: u32) bool {
        return self.table[position * self.stride + pc / 8] & (@as(u8, 1) << @as(u3, @intCast(pc % 8))) != 0;
    }
    fn set(self: *Workspace, position: usize, pc: u32, value: bool) void {
        const address = &self.table[position * self.stride + pc / 8];
        const mask = @as(u8, 1) << @as(u3, @intCast(pc % 8));
        address.* = if (value) address.* | mask else address.* & ~mask;
    }
};
fn equal(a: u32, b: u32, ignore: bool) bool {
    return if (ignore) std.ascii.toLower(@intCast(a)) == std.ascii.toLower(@intCast(b)) else a == b;
}
fn newline(cp: u32) bool {
    return cp == 10 or cp == 13 or cp == 0x2028 or cp == 0x2029;
}
fn wordCharacter(cp: u32) bool {
    return cp == '_' or (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z') or (cp >= '0' and cp <= '9');
}
fn classMatches(program: *const Program, inst: Inst, cp: u32, work: *Work) !bool {
    var found = false;
    for (program.ranges[inst.a..inst.b]) |range| {
        try work.charge(1);
        if (cp >= range.first and cp <= range.last) {
            found = true;
            break;
        }
        if (program.flags.ignore_case) {
            try work.charge(2);
            const lower = std.ascii.toLower(@intCast(cp));
            const upper = std.ascii.toUpper(@intCast(cp));
            if ((lower >= range.first and lower <= range.last) or (upper >= range.first and upper <= range.last)) {
                found = true;
                break;
            }
        }
    }
    return found != inst.negate;
}
pub const Cursor = struct {
    workspace: *Workspace,
    program: *Program,
    work: *Work,
    next_start: usize = 0,
    done: bool = false,
    live: bool = true,
    pub fn end(self: *Cursor) void {
        if (!self.live) return;
        std.debug.assert(self.workspace.owner == std.Thread.getCurrentId() and self.workspace.active and self.program.clients != 0);
        self.live = false;
        self.workspace.active = false;
        self.program.clients -= 1;
    }
    pub fn next(self: *Cursor) !?Match {
        if (!self.live) return error.Closed;
        if (self.workspace.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.done or self.next_start > self.workspace.length) return null;
        var start = self.next_start;
        while (!self.workspace.get(start, self.program.entry)) {
            try self.work.charge(1);
            if (start == self.workspace.length) {
                self.done = true;
                return null;
            }
            start += self.workspace.scalar(start, self.program.flags.unicode).width;
        }
        const captures = self.workspace.captures[0 .. self.program.captures + 1];
        try self.work.charge(captures.len + 2);
        @memset(captures, .{});
        captures[0].start = start;
        var position = start;
        var pc = self.program.entry;
        while (true) {
            try self.work.charge(1);
            const inst = self.program.code[pc];
            switch (inst.kind) {
                .accept => break,
                .literal, .any, .class => {
                    position += self.workspace.scalar(position, self.program.flags.unicode).width;
                    pc = inst.next;
                },
                .split => pc = if (self.workspace.get(position, inst.a)) inst.a else inst.b,
                .save => {
                    try self.work.charge(1);
                    const capture = &captures[inst.a / 2];
                    if (inst.a % 2 == 0) {
                        capture.start = position;
                        capture.end = null;
                    } else capture.end = position;
                    pc = inst.next;
                },
                .clear => {
                    try self.work.charge(inst.b - inst.a);
                    @memset(captures[inst.a..inst.b], .{});
                    pc = inst.next;
                },
                .start, .end, .boundary => pc = inst.next,
            }
        }
        captures[0].end = position;
        if (!self.program.flags.global) self.done = true;
        self.next_start = if (position != start) position else if (position == self.workspace.length) position + 1 else position + self.workspace.scalar(position, self.program.flags.unicode).width;
        return .{ .range = .{ .start = start, .end = position }, .captures = captures };
    }
};
fn expectMatch(pattern: []const u8, flags: []const u8, text: []const u8, expected: Range, captures: []const ?Range) !void {
    var program = try Program.compile(std.testing.allocator, pattern, flags, .{});
    defer program.deinit() catch unreachable;
    var workspace = try Workspace.init(std.testing.allocator, .{});
    defer workspace.deinit() catch unreachable;
    var work: Work = .{ .limit = 1024 * 1024 };
    var cursor = try workspace.begin(&program, text, &work);
    defer cursor.end();
    const result = (try cursor.next()).?;
    try std.testing.expectEqual(expected, result.range);
    for (captures, 0..) |capture, index| try std.testing.expectEqual(capture, result.capture(index + 1));
    try std.testing.expectError(error.ClientsAlive, program.deinit());
    try std.testing.expectError(error.Busy, workspace.deinit());
}
test "ordered regex reconstruction preserves greediness captures and UTF16 coordinates" {
    try expectMatch("(a|aa)", "", "aa", .{ .start = 0, .end = 1 }, &.{.{ .start = 0, .end = 1 }});
    try expectMatch("(a+?)(a+)", "", "aaaa", .{ .start = 0, .end = 4 }, &.{ .{ .start = 0, .end = 1 }, .{ .start = 1, .end = 4 } });
    try expectMatch("(a|(b))+", "", "ba", .{ .start = 0, .end = 2 }, &.{ .{ .start = 1, .end = 2 }, null });
    try expectMatch("(.*)\\..+$", "", "猫-file.txt", .{ .start = 0, .end = 10 }, &.{.{ .start = 0, .end = 6 }});
    try expectMatch("(.)", "", "😀", .{ .start = 0, .end = 1 }, &.{.{ .start = 0, .end = 1 }});
    try expectMatch("(.)", "u", "😀", .{ .start = 0, .end = 2 }, &.{.{ .start = 0, .end = 2 }});
    try expectMatch("\\b[a-z]+\\b", "i", "ABC!", .{ .start = 0, .end = 3 }, &.{});
    try expectMatch("^a.$", "ms", "x\na\n\ny", .{ .start = 2, .end = 4 }, &.{});
}
test "global empty matches advance by code unit or scalar and share one table" {
    for ([_][]const u8{ "g", "gu" }) |flags| {
        var program = try Program.compile(std.testing.allocator, "", flags, .{});
        defer program.deinit() catch unreachable;
        var workspace = try Workspace.init(std.testing.allocator, .{});
        defer workspace.deinit() catch unreachable;
        var work: Work = .{ .limit = 1024 * 1024 };
        var cursor = try workspace.begin(&program, "😀", &work);
        defer cursor.end();
        var count: usize = 0;
        while (try cursor.next()) |_| count += 1;
        try std.testing.expectEqual(@as(usize, if (program.flags.unicode) 2 else 3), count);
    }
}
test "regex compilation bounds epsilon DAG captures and syntax capabilities" {
    for ([_][]const u8{ "(.*)\\..+$", "([a-z]+)-([0-9]+)", "(?:a|aa)+?b", "[\\s\\D]", "a{2,4}", "^$", "\\bword\\B", "😀+" }) |pattern| {
        var program = try Program.compile(std.testing.allocator, pattern, "gmu", .{});
        defer program.deinit() catch unreachable;
        try std.testing.expect(program.order.len == program.code.len);
    }
    for ([_][]const u8{ "(a?)*", "(a*)+", "(^)?" }) |pattern| try std.testing.expectError(error.UnsupportedNullableRepeat, Program.compile(std.testing.allocator, pattern, "", .{}));
    for ([_][]const u8{ "(a)\\1", "(?=a)", "(?<x>a)", "\\p{L}" }) |pattern| try std.testing.expectError(error.UnsupportedRegex, Program.compile(std.testing.allocator, pattern, "", .{}));
    try std.testing.expectError(error.CapacityExceeded, Program.compile(std.testing.allocator, "a{999999999}", "", .{}));
    try std.testing.expectError(error.InvalidRegexFlag, Program.compile(std.testing.allocator, "a", "gg", .{}));
    try std.testing.expectError(error.UnsupportedRegexFlag, Program.compile(std.testing.allocator, "a", "v", .{}));
}
fn compileCandidate(allocator: std.mem.Allocator) !void {
    var program = try Program.compile(allocator, "(ab|cd)+?([0-9]{2,4})", "g", .{});
    defer program.deinit() catch unreachable;
}
test "regex compiled owner rolls back every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileCandidate, .{});
}

fn workspaceCandidate(allocator: std.mem.Allocator) !void {
    var workspace = try Workspace.init(allocator, .{});
    defer workspace.deinit() catch unreachable;
    var program = try Program.compile(std.testing.allocator, "(ab|a)+b", "g", .{});
    defer program.deinit() catch unreachable;
    var work: Work = .{ .limit = 1024 * 1024 };
    var cursor = try workspace.begin(&program, "aaab", &work);
    defer cursor.end();
    _ = try cursor.next();
}
test "workspace preallocation failure cancellation and runtime bounds" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, workspaceCandidate, .{});
    try std.testing.expectError(error.CapacityExceeded, Workspace.init(std.testing.allocator, .{ .bytes = 256 }));
    var workspace = try Workspace.init(std.testing.allocator, .{ .input_bytes = 64 });
    defer workspace.deinit() catch unreachable;
    var program = try Program.compile(std.testing.allocator, "[a-z]+", "gi", .{});
    defer program.deinit() catch unreachable;
    var cancel = std.atomic.Value(bool).init(true);
    var work: Work = .{ .limit = 1024, .cancellation = &cancel };
    try std.testing.expectError(error.Cancelled, workspace.begin(&program, "abc", &work));
    cancel.store(false, .release);
    work.limit = 2;
    try std.testing.expectError(error.WorkExceeded, workspace.begin(&program, "abc", &work));
    work = .{ .limit = 1024 };
    try std.testing.expectError(error.UnsupportedRegexCase, workspace.begin(&program, "猫", &work));
    var cursor = try workspace.begin(&program, "abc", &work);
    try std.testing.expectError(error.Busy, workspace.begin(&program, "abc", &work));
    cursor.end();
    cursor.end();
    try std.testing.expectError(error.Closed, cursor.next());
}
test "one global table and adversarial alternation have bounded work" {
    var workspace = try Workspace.init(std.testing.allocator, .{});
    defer workspace.deinit() catch unreachable;
    var program = try Program.compile(std.testing.allocator, "(a|aa)+b", "g", .{});
    defer program.deinit() catch unreachable;
    var work: Work = .{ .limit = 1024 * 1024 };
    var input: [8192]u8 = @splat('a');
    var cursor = try workspace.begin(&program, &input, &work);
    try std.testing.expect(try cursor.next() == null);
    try std.testing.expect(work.used < 32 * input.len);
    cursor.end();
    var empty = try Program.compile(std.testing.allocator, "", "g", .{});
    defer empty.deinit() catch unreachable;
    work = .{ .limit = 1024 * 1024 };
    cursor = try workspace.begin(&empty, &input, &work);
    defer cursor.end();
    const prepared = work.used;
    var count: usize = 0;
    while (try cursor.next()) |_| count += 1;
    try std.testing.expectEqual(input.len + 1, count);
    try std.testing.expectEqual(4 * count, work.used - prepared);
}
