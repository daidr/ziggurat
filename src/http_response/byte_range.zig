const std = @import("std");

// Bounded byte-range selection for an explicitly authorized representation.
// Inputs are borrowed only for a call. No allocator, file, transport or App.
pub const value_capacity = 256;
pub const empty_item_capacity = 8;
pub const maximum_content_range_length = 68;
pub const Error = error{ TooLong, InvalidRange, TooManyEmptyItems, InvalidSpec, InvalidSelection, NoSpaceLeft };
pub const Spec = union(enum) {
    closed: struct { first: u64, last: u64 },
    from: u64,
    suffix: u64,
};
pub const Parsed = union(enum) { single: Spec, unknown_unit, multiple, numeric_limit };
pub const Selection = union(enum) {
    full,
    partial: struct { offset: u64, length: u64, total: u64 },
    unsatisfiable: u64,
};
pub const Method = enum { get, head };

fn ows(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t");
}
fn token(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) != null;
}
const Decimal = struct { digits: []const u8, value: ?u64 };
fn decimal(value: []const u8) Error!Decimal {
    if (value.len == 0) return error.InvalidRange;
    var result: u64 = 0;
    var overflow = false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidRange;
        if (!overflow) {
            result = std.math.mul(u64, result, 10) catch {
                overflow = true;
                continue;
            };
            result = std.math.add(u64, result, byte - '0') catch {
                overflow = true;
                continue;
            };
        }
    }
    var first: usize = 0;
    while (first + 1 < value.len and value[first] == '0') : (first += 1) {}
    return .{ .digits = value[first..], .value = if (overflow) null else result };
}
fn larger(a: Decimal, b: Decimal) bool {
    return a.digits.len > b.digits.len or (a.digits.len == b.digits.len and std.mem.order(u8, a.digits, b.digits) == .gt);
}
fn item(value: []const u8) Error!?Spec {
    const dash = std.mem.indexOfScalar(u8, value, '-') orelse return error.InvalidRange;
    const left = value[0..dash];
    const right = value[dash + 1 ..];
    if (left.len == 0) {
        const count = try decimal(right);
        return if (count.value) |n| .{ .suffix = n } else null;
    }
    const first = try decimal(left);
    if (right.len == 0) return if (first.value) |n| .{ .from = n } else null;
    const last = try decimal(right);
    // Decimal ordering is checked even when either number exceeds u64.
    if (larger(first, last)) return error.InvalidRange;
    return if (first.value != null and last.value != null) .{ .closed = .{ .first = first.value.?, .last = last.value.? } } else null;
}

/// Field-value bound is checked before scanning. Outer OWS and up to eight
/// empty list members are accepted. Malformed tails always beat valid multiple
/// or numeric_limit outcomes. After a valid complete scan, numeric_limit takes
/// precedence over multiple; both are deliberate full-response fallbacks.
pub fn parse(value: []const u8) Error!Parsed {
    if (value.len > value_capacity) return error.TooLong;
    const field = ows(value);
    const equal = std.mem.indexOfScalar(u8, field, '=') orelse return error.InvalidRange;
    if (equal == 0) return error.InvalidRange;
    for (field[0..equal]) |byte| if (!token(byte)) return error.InvalidRange;
    const list = field[equal + 1 ..];
    if (!std.ascii.eqlIgnoreCase(field[0..equal], "bytes")) {
        // An unknown unit's grammar is opaque. Check its bounded lexical field
        // safety, not byte-range semantics, then let the host ignore it.
        if (ows(list).len == 0) return error.InvalidRange;
        for (list) |byte| if (byte != '\t' and (byte < 0x20 or byte > 0x7e)) return error.InvalidRange;
        return .unknown_unit;
    }
    var members = std.mem.splitScalar(u8, list, ',');
    var nonempty: usize = 0;
    var empty: usize = 0;
    var overflow = false;
    var first: Spec = undefined;
    while (members.next()) |raw| {
        const member = ows(raw);
        if (member.len == 0) {
            empty += 1;
            continue;
        }
        const spec = try item(member);
        nonempty += 1;
        if (spec) |valid| {
            if (nonempty == 1) first = valid;
        } else overflow = true;
    }
    if (nonempty == 0) return error.InvalidRange;
    if (empty > empty_item_capacity) return error.TooManyEmptyItems;
    if (overflow) return .numeric_limit;
    if (nonempty != 1) return .multiple;
    return .{ .single = first };
}

fn validateSpec(spec: Spec) Error!void {
    switch (spec) {
        .closed => |span| if (span.first > span.last) return error.InvalidSpec,
        .from, .suffix => {},
    }
}
/// A public Spec can be hand-constructed. Validate before empty/full handling.
/// Empty representations deliberately ignore every valid range in this slice.
pub fn select(spec: Spec, total: u64) Error!Selection {
    try validateSpec(spec);
    if (total == 0) return .full;
    const span: struct { offset: u64, length: u64 } = switch (spec) {
        .closed => |span| blk: {
            if (span.first >= total) return .{ .unsatisfiable = total };
            const last = @min(span.last, total - 1);
            break :blk .{ .offset = span.first, .length = last - span.first + 1 };
        },
        .from => |first| blk: {
            if (first >= total) return .{ .unsatisfiable = total };
            break :blk .{ .offset = first, .length = total - first };
        },
        .suffix => |count| blk: {
            if (count == 0) return .{ .unsatisfiable = total };
            const length = @min(count, total);
            break :blk .{ .offset = total - length, .length = length };
        },
    };
    return .{ .partial = .{ .offset = span.offset, .length = span.length, .total = total } };
}

fn strongTag(value: []const u8) bool {
    if (value.len < 2 or value.len > value_capacity or value[0] != '"' or value[value.len - 1] != '"') return false;
    for (value[1 .. value.len - 1]) |byte| if (!(byte == 0x21 or (byte >= 0x23 and byte <= 0x7e) or byte >= 0x80)) return false;
    return true;
}
/// Only exact validated strong ETags optimize a transfer. Weak/date/missing,
/// oversized or malformed validators choose the full representation.
pub fn ifRangeMatches(value: []const u8, current_etag: ?[]const u8) bool {
    if (value.len > value_capacity) return false;
    const current = current_etag orelse return false;
    const candidate = ows(value);
    return strongTag(candidate) and strongTag(current) and std.mem.eql(u8, candidate, current);
}
/// This is a selection policy for an already authorized GET/HEAD. It does not
/// evaluate other HTTP preconditions, discover headers, or authorize a file.
pub fn evaluate(method: Method, parsed: ?Parsed, total: u64, if_range: ?[]const u8, current_etag: ?[]const u8) Error!Selection {
    const value = parsed orelse return .full;
    if (value == .single) try validateSpec(value.single);
    if (method == .head) return .full;
    if (if_range) |condition| if (!ifRangeMatches(condition, current_etag)) return .full;
    return switch (value) {
        .single => |spec| select(spec, total),
        .unknown_unit, .multiple, .numeric_limit => .full,
    };
}

fn decimalLength(number: u64) usize {
    var n = number;
    var len: usize = 1;
    while (n >= 10) : (n /= 10) len += 1;
    return len;
}
/// Check public numeric shape and required size before the first output write.
/// No buffer, including a too-small one, is modified on any error. The longest
/// u64 partial Content-Range is 68 bytes, excluding any optional NUL sentinel.
pub fn formatContentRange(selection: Selection, output: []u8) Error![]const u8 {
    const required = switch (selection) {
        .full => return error.InvalidSelection,
        .unsatisfiable => |total| blk: {
            if (total == 0) return error.InvalidSelection;
            break :blk 8 + decimalLength(total);
        },
        .partial => |span| blk: {
            if (span.total == 0 or span.length == 0 or span.offset >= span.total or span.length > span.total - span.offset) return error.InvalidSelection;
            const last = span.offset + (span.length - 1);
            break :blk 6 + decimalLength(span.offset) + 1 + decimalLength(last) + 1 + decimalLength(span.total);
        },
    };
    if (output.len < required) return error.NoSpaceLeft;
    return switch (selection) {
        .full => unreachable,
        .unsatisfiable => |total| std.fmt.bufPrint(output, "bytes */{d}", .{total}) catch unreachable,
        .partial => |span| std.fmt.bufPrint(output, "bytes {d}-{d}/{d}", .{ span.offset, span.offset + (span.length - 1), span.total }) catch unreachable,
    };
}
