//! A command's arguments: positional ones and flags, with flags anywhere
//! among them (`press @e2 --settle`), written `-f`, `--f`, `--f=v` or
//! `--f v`. `--` ends the flags; a negative number, as wheel's `-120`, and
//! `-` alone are positional.
const std = @import("std");

/// A flag a command takes: with a value, or a switch.
pub const Flag = struct { name: []const u8, value: bool = false };

/// The short spellings of flags.
const aliases = [_][2][]const u8{.{ "i", "interactive" }};

pub const Args = struct {
    pos: []const []const u8,
    switches: []const []const u8,
    values: []const [2][]const u8,

    pub fn has(self: Args, name: []const u8) bool {
        for (self.switches) |item| if (std.mem.eql(u8, item, name)) return true;
        return false;
    }
    pub fn value(self: Args, name: []const u8) ?[]const u8 {
        var found: ?[]const u8 = null;
        for (self.values) |item| if (std.mem.eql(u8, item[0], name)) {
            found = item[1];
        };
        return found;
    }
};

pub const Problem = @import("problem.zig").Problem;

fn find(spec: []const Flag, name: []const u8) ?Flag {
    for (spec) |flag| if (std.mem.eql(u8, flag.name, name)) return flag;
    return null;
}

pub fn parse(arena: std.mem.Allocator, in: []const []const u8, spec: []const Flag, problem: *Problem) (error{Usage} || std.mem.Allocator.Error)!Args {
    var pos: std.ArrayList([]const u8) = .empty;
    var switches: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList([2][]const u8) = .empty;
    var index: usize = 0;
    while (index < in.len) : (index += 1) {
        const item = in[index];
        if (std.mem.eql(u8, item, "--")) {
            try pos.appendSlice(arena, in[index + 1 ..]);
            break;
        }
        if (item.len < 2 or item[0] != '-' or std.ascii.isDigit(item[1]) or item[1] == '.') {
            try pos.append(arena, item);
            continue;
        }
        var name = std.mem.trimStart(u8, item, "-");
        var given: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, name, '=')) |at| {
            given = name[at + 1 ..];
            name = name[0..at];
        }
        for (aliases) |alias| if (std.mem.eql(u8, alias[0], name)) {
            name = alias[1];
        };
        const flag = find(spec, name) orelse return problem.usage("unknown flag {s}", .{item});
        if (flag.value) {
            const text = given orelse blk: {
                if (index + 1 >= in.len) return problem.usage("flag --{s} needs a value", .{name});
                index += 1;
                break :blk in[index];
            };
            try values.append(arena, .{ flag.name, text });
        } else {
            if (given != null) return problem.usage("flag --{s} takes no value", .{name});
            try switches.append(arena, flag.name);
        }
    }
    return .{ .pos = pos.items, .switches = switches.items, .values = values.items };
}

test "flags go anywhere among the arguments, and numbers stay positional" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const spec = [_]Flag{ .{ .name = "settle" }, .{ .name = "timeout", .value = true }, .{ .name = "interactive" }, .{ .name = "mods", .value = true } };
    var problem: Problem = .{};
    const a = try parse(arena, &.{ "@e2", "--settle", "-i", "0", "-120", "--timeout=2s", "--mods", "shift,ctrl", "-.5", "-", "--", "--settle" }, &spec, &problem);
    try std.testing.expectEqual(@as(usize, 6), a.pos.len);
    for ([_][]const u8{ "@e2", "0", "-120", "-.5", "-", "--settle" }, a.pos) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expect(a.has("settle") and a.has("interactive"));
    try std.testing.expectEqualStrings("2s", a.value("timeout").?);
    try std.testing.expectEqualStrings("shift,ctrl", a.value("mods").?);
    for ([_][]const []const u8{ &.{"--nope"}, &.{"--timeout"}, &.{"--settle=1"} }) |bad| {
        try std.testing.expectError(error.Usage, parse(arena, bad, &spec, &problem));
    }
}
