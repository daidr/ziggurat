const std = @import("std");
const root = @import("root.zig");

pub fn add(_: std.mem.Allocator, _: []const u8, _: *const [16]u8) !void {
    return error.UnsupportedCapability;
}

pub const List = struct {
    items: []root.SystemFamily = &.{},
    pub fn deinit(_: *List, _: std.mem.Allocator) void {}
};

pub fn systemFamilies(_: std.mem.Allocator) !List {
    return .{};
}
