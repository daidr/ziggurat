//! What the automation socket's answers hold, as the command reads them:
//! windows, a window's elements and their bounds. Fields the command does
//! not know are ignored, so it reads answers of newer apps.
const std = @import("std");

pub const Rect = struct {
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,
};

/// A window the `windows` method lists.
pub const Window = struct {
    id: u64,
    title: []const u8 = "",
    kind: []const u8 = "content",
    url: ?[]const u8 = null,
    focused: bool = false,
    visible: bool = true,
};

/// An element of a window, with the fields the protocol gives. IDs and
/// keys are strings of digits.
pub const Node = struct {
    id: []const u8,
    parent: ?[]const u8 = null,
    role: []const u8 = "",
    key: ?[]const u8 = null,
    label: ?[]const u8 = null,
    value: ?[]const u8 = null,
    placeholder: ?[]const u8 = null,
    description: ?[]const u8 = null,
    bounds: Rect = .{},
    states: ?[]const []const u8 = null,
    actions: ?[]const []const u8 = null,
    min: ?f64 = null,
    max: ?f64 = null,
    now: ?f64 = null,
    step: ?f64 = null,
    selection: ?[2]u64 = null,
    level: ?u32 = null,
    posInSet: ?u32 = null,
    setSize: ?u32 = null,
    webView: ?bool = null,

    pub fn text(value: ?[]const u8) []const u8 {
        return value orelse "";
    }
};

/// The `tree` method's result.
pub const Tree = struct {
    window: u64,
    focus: ?[]const u8 = null,
    nodes: []const Node = &.{},
    announcements: ?[]const []const u8 = null,
};

pub const parse_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

/// Reads a result into `T`.
pub fn read(comptime T: type, arena: std.mem.Allocator, value: std.json.Value) !T {
    return std.json.parseFromValueLeaky(T, arena, value, parse_options);
}

/// The key `view.key` gives a text; it must stay the view's.
pub fn keyOf(text: []const u8) u64 {
    return std.hash.Wyhash.hash(0x6b_65_79, text);
}
