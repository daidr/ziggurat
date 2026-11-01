//! The names the protocol gives input: event types, buttons, modifiers,
//! and keys in the syntax of menu accelerators, as "Enter", "Shift+Tab"
//! or "CmdOrCtrl+Z".
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const protocol = @import("protocol.zig");

const Value = std.json.Value;
const Failure = protocol.Failure;
const InputEvent = protocol.InputEvent;
const fail = protocol.fail;

/// The fields each event type takes.
const fields = .{
    .pointerMove = .{ "type", "x", "y", "mods" },
    .pointerDown = .{ "type", "x", "y", "button", "clicks", "mods" },
    .pointerUp = .{ "type", "x", "y", "button", "clicks", "mods" },
    .click = .{ "type", "x", "y", "button", "clicks", "mods" },
    .wheel = .{ "type", "x", "y", "dx", "dy", "precise", "mods" },
    .keyDown = .{ "type", "key" },
    .keyUp = .{ "type", "key" },
    .key = .{ "type", "key" },
    .text = .{ "type", "text" },
};
const Type = std.meta.FieldEnum(@TypeOf(fields));

/// Appends the events of `item`, the event at `index` of an input
/// request, as the platform adapters would send them: a click is a move,
/// then a press and a release for each click, and a key a press and a
/// release.
pub fn inputEvents(arena: std.mem.Allocator, item: Value, index: usize, out: *std.ArrayList(InputEvent), failure: *Failure) protocol.Error!void {
    if (item != .object) return fail(failure, arena, .invalid_request, "event {d} is not an object", .{index});
    const object = item.object;
    const type_value = object.get("type") orelse return fail(failure, arena, .invalid_request, "event {d} has no type", .{index});
    if (type_value != .string) return fail(failure, arena, .invalid_request, "event {d}: type is a string", .{index});
    const kind = std.meta.stringToEnum(Type, type_value.string) orelse return fail(failure, arena, .invalid_request, "event {d}: no event type \"{s}\"", .{ index, type_value.string });
    var it = object.iterator();
    while (it.next()) |entry| {
        const known = switch (kind) {
            inline else => |tag| known: {
                inline for (@field(fields, @tagName(tag))) |name| {
                    if (std.mem.eql(u8, entry.key_ptr.*, name)) break :known true;
                }
                break :known false;
            },
        };
        if (!known) return fail(failure, arena, .invalid_request, "event {d}: {s} takes no field \"{s}\"", .{ index, type_value.string, entry.key_ptr.* });
    }
    const event: Event = .{ .object = object, .index = index, .arena = arena, .failure = failure };
    switch (kind) {
        .pointerMove, .pointerDown, .pointerUp, .click, .wheel => {
            const pointer: protocol.Pointer = .{ .x = try event.number("x", true), .y = try event.number("y", true), .button = try event.button(), .modifiers = try event.mods() };
            const clicks = try event.clicks();
            switch (kind) {
                .pointerMove => try out.append(arena, .{ .pointer_move = pointer }),
                .pointerDown => try out.append(arena, .{ .pointer_down = pointer }),
                .pointerUp => try out.append(arena, .{ .pointer_up = pointer }),
                .click => {
                    try out.append(arena, .{ .pointer_move = pointer });
                    for (0..clicks) |_| {
                        try out.append(arena, .{ .pointer_down = pointer });
                        try out.append(arena, .{ .pointer_up = pointer });
                    }
                },
                .wheel => try out.append(arena, .{ .wheel = .{ .pointer = pointer, .dx = try event.number("dx", false), .dy = try event.number("dy", false) } }),
                else => unreachable,
            }
        },
        .keyDown, .keyUp, .key => {
            const value = object.get("key") orelse return fail(failure, arena, .invalid_request, "event {d}: {s} needs a key", .{ index, type_value.string });
            if (value != .string) return fail(failure, arena, .invalid_request, "event {d}: key is a string", .{index});
            const input = parseKey(value.string) catch |err| return fail(failure, arena, .invalid_request, "event {d}: {s}", .{ index, keyMessage(err, value.string, arena) });
            if (kind != .keyUp) try out.append(arena, .{ .key_down = input });
            if (kind != .keyDown) try out.append(arena, .{ .key_up = input });
        },
        .text => {
            const value = object.get("text") orelse return fail(failure, arena, .invalid_request, "event {d}: text has no text", .{index});
            if (value != .string or value.string.len == 0) return fail(failure, arena, .invalid_request, "event {d}: text has no text", .{index});
            if (std.mem.indexOfScalar(u8, value.string, 0) != null) return fail(failure, arena, .invalid_request, "event {d}: text holds a NUL", .{index});
            try out.append(arena, .{ .text = value.string });
        },
    }
}

const Event = struct {
    object: std.json.ObjectMap,
    index: usize,
    arena: std.mem.Allocator,
    failure: *Failure,

    fn number(self: Event, name: []const u8, required: bool) protocol.Error!f32 {
        const value = self.object.get(name) orelse {
            if (required) return fail(self.failure, self.arena, .invalid_request, "event {d} needs {s}", .{ self.index, name });
            return 0;
        };
        const result: f64 = switch (value) {
            .integer => |n| @floatFromInt(n),
            .float => |f| f,
            else => return fail(self.failure, self.arena, .invalid_request, "event {d}: {s} is a number", .{ self.index, name }),
        };
        if (!std.math.isFinite(result) or @abs(result) > 1e7) return fail(self.failure, self.arena, .invalid_request, "event {d}: {s} is out of range", .{ self.index, name });
        return @floatCast(result);
    }
    fn button(self: Event) protocol.Error!z.PointerButton {
        const value = self.object.get("button") orelse return .primary;
        if (value == .string) {
            if (std.mem.eql(u8, value.string, "left")) return .primary;
            if (std.mem.eql(u8, value.string, "right")) return .secondary;
            if (std.mem.eql(u8, value.string, "middle")) return .middle;
        }
        return fail(self.failure, self.arena, .invalid_request, "event {d}: button is left, right or middle", .{self.index});
    }
    fn clicks(self: Event) protocol.Error!usize {
        const value = self.object.get("clicks") orelse return 1;
        if (value != .integer or value.integer < 1 or value.integer > 3) return fail(self.failure, self.arena, .invalid_request, "event {d}: clicks is 1, 2 or 3", .{self.index});
        return @intCast(value.integer);
    }
    fn mods(self: Event) protocol.Error!z.KeyModifiers {
        const value = self.object.get("mods") orelse return .{};
        if (value != .array) return fail(self.failure, self.arena, .invalid_request, "event {d}: mods is a list", .{self.index});
        var result: z.KeyModifiers = .{};
        for (value.array.items) |item| {
            if (item != .string or !modifier(item.string, &result)) return fail(self.failure, self.arena, .invalid_request, "event {d}: no modifier {f}", .{ self.index, std.json.fmt(item, .{}) });
        }
        return result;
    }
};

/// Sets the modifier `name` names in `mods`; false for no modifier.
fn modifier(name: []const u8, mods: *z.KeyModifiers) bool {
    const eql = std.ascii.eqlIgnoreCase;
    if (eql(name, "shift")) {
        mods.shift = true;
    } else if (eql(name, "ctrl") or eql(name, "control")) {
        mods.control = true;
    } else if (eql(name, "alt") or eql(name, "option")) {
        mods.alt = true;
    } else if (eql(name, "super") or eql(name, "cmd") or eql(name, "command") or eql(name, "meta")) {
        mods.super = true;
    } else if (eql(name, "cmdOrCtrl") or eql(name, "commandOrControl")) {
        if (builtin.os.tag.isDarwin()) mods.super = true else mods.control = true;
    } else return false;
    return true;
}

pub const KeyError = error{ EmptyKey, NoKey, NoModifier, TwoKeys };

fn keyMessage(err: KeyError, text: []const u8, arena: std.mem.Allocator) []const u8 {
    return switch (err) {
        error.EmptyKey => "the key is empty",
        error.NoKey => std.fmt.allocPrint(arena, "no key in \"{s}\"", .{text}) catch "no key",
        error.NoModifier => std.fmt.allocPrint(arena, "no modifier in \"{s}\"", .{text}) catch "no modifier",
        error.TwoKeys => std.fmt.allocPrint(arena, "\"{s}\" names two keys", .{text}) catch "two keys",
    };
}

/// The key and modifiers of an accelerator, as "CmdOrCtrl+Shift+Z".
pub fn parseKey(text: []const u8) KeyError!z.KeyInput {
    if (text.len == 0) return error.EmptyKey;
    var result: z.KeyInput = .{ .key = .unknown };
    var rest = text;
    while (rest.len != 0) {
        // "+" alone, or at the end after a "+", is the plus key.
        const cut = if (rest.len > 1) std.mem.indexOfScalarPos(u8, rest, 1, '+') else null;
        const part = if (cut) |at| rest[0..at] else rest;
        rest = if (cut) |at| rest[at + 1 ..] else "";
        if (rest.len == 0 and cut != null) return error.NoKey;
        if (modifier(part, &result.modifiers)) {
            if (rest.len == 0) return error.NoKey;
            continue;
        }
        if (rest.len != 0) return error.NoModifier;
        if (result.key != .unknown) return error.TwoKeys;
        result.key = keyNamed(part) orelse return error.NoKey;
    }
    if (result.key == .unknown) return error.NoKey;
    return result;
}

const named = .{
    .{ "Enter", .enter },              .{ "Return", .enter },             .{ "Escape", .escape },                  .{ "Esc", .escape },
    .{ "Backspace", .backspace },      .{ "Tab", .tab },                  .{ "Space", .space },                    .{ "Delete", .delete },
    .{ "Insert", .insert },            .{ "Home", .home },                .{ "End", .end },                        .{ "PageUp", .page_up },
    .{ "PageDown", .page_down },       .{ "Left", .left },                .{ "Right", .right },                    .{ "Up", .up },
    .{ "Down", .down },                .{ "Plus", .equal },               .{ "Minus", .minus },                    .{ "ContextMenu", .context_menu },
    .{ "PrintScreen", .print_screen }, .{ "BrowserBack", .browser_back }, .{ "BrowserForward", .browser_forward },
};

fn keyNamed(name: []const u8) ?z.KeyCode {
    inline for (named) |entry| if (std.ascii.eqlIgnoreCase(name, entry[0])) return entry[1];
    if (name.len == 1) return switch (std.ascii.toLower(name[0])) {
        'a'...'z' => |letter| @fromBackingInt(@intCast(@backingInt(z.KeyCode.a) + (letter - 'a'))),
        '0'...'9' => |digit| @fromBackingInt(@intCast(@backingInt(z.KeyCode.digit0) + (digit - '0'))),
        ' ' => .space,
        '-' => .minus,
        '=', '+' => .equal,
        '[' => .left_bracket,
        ']' => .right_bracket,
        '\\' => .backslash,
        ';' => .semicolon,
        '\'' => .apostrophe,
        '`' => .grave,
        ',' => .comma,
        '.' => .period,
        '/' => .slash,
        else => null,
    };
    if ((name[0] == 'F' or name[0] == 'f') and name.len <= 3) {
        const n = std.fmt.parseInt(u8, name[1..], 10) catch return null;
        if (n >= 1 and n <= 24) return @fromBackingInt(@intCast(@backingInt(z.KeyCode.f1) + (n - 1)));
    }
    return null;
}

test "accelerators name a key and its modifiers" {
    const expect = std.testing.expectEqual;
    try expect(z.KeyInput{ .key = .enter }, try parseKey("Enter"));
    try expect(z.KeyInput{ .key = .tab, .modifiers = .{ .shift = true } }, try parseKey("Shift+Tab"));
    const undo = try parseKey("CmdOrCtrl+Z");
    try expect(z.KeyCode.z, undo.key);
    try expect(!builtin.os.tag.isDarwin(), undo.modifiers.control);
    try expect(z.KeyInput{ .key = .equal, .modifiers = .{ .control = true } }, try parseKey("Ctrl++"));
    try expect(z.KeyInput{ .key = .f12 }, try parseKey("F12"));
    try expect(z.KeyInput{ .key = .a, .modifiers = .{ .control = true, .shift = true } }, try parseKey("ctrl+shift+a"));
    try std.testing.expectError(error.NoKey, parseKey("Shift"));
    try std.testing.expectError(error.NoKey, parseKey("Shift+"));
    try std.testing.expectError(error.NoKey, parseKey("Hyper"));
    try std.testing.expectError(error.NoModifier, parseKey("A+B"));
    try std.testing.expectError(error.EmptyKey, parseKey(""));
}
