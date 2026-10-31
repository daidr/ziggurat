//! Platform-neutral menu validation shared by menu bars, popup menus and tray
//! menus. Nothing here allocates or touches native state.
const std = @import("std");
const types = @import("types.zig");

pub const max_items = types.max_menu_items;

/// Facts derived once per snapshot. Indices refer to the caller's item slice.
pub const Plan = struct {
    count: usize = 0,
    commands: usize = 0,
    parent: [max_items]?u8 = @splat(null),
    /// The item and every ancestor submenu are enabled.
    enabled: [max_items]bool = @splat(false),
    /// Every ancestor submenu is enabled; the item's own state is excluded.
    ancestors_enabled: [max_items]bool = @splat(false),
    /// The first item of a radio command's group; null for other items.
    radio_group: [max_items]?u8 = @splat(null),

    pub fn lookup(self: *const Plan, items: []const types.Item, id: u64) ?usize {
        for (items[0..self.count], 0..) |item, index| if (item.kind == .command and item.id == id) return index;
        return null;
    }
};

/// Checks structure, labels and accelerators. A popup must contain at least
/// one item; a menu bar may be empty.
pub fn validate(items: []const types.Item, popup: bool) !Plan {
    if (items.len > max_items) return error.TooManyMenuItems;
    if (popup and items.len == 0) return error.EmptyMenu;
    var plan: Plan = .{ .count = items.len };
    for (items, 0..) |item, index| {
        if (item.kind != .separator) {
            if (item.id == 0) return error.InvalidMenuId;
            for (items[0..index]) |previous| if (previous.kind != .separator and previous.id == item.id) return error.DuplicateMenuId;
            try validateLabel(item.label);
        }
        var ancestors = true;
        if (item.parent) |parent| {
            const parent_index = for (items[0..index], 0..) |previous, previous_index| {
                if (previous.kind == .submenu and previous.id == parent) break previous_index;
            } else return error.InvalidMenuParent;
            plan.parent[index] = @intCast(parent_index);
            ancestors = plan.enabled[parent_index];
        }
        plan.ancestors_enabled[index] = ancestors;
        plan.enabled[index] = ancestors and item.enabled;
        if (item.accelerator) |accelerator| {
            if (item.kind != .command) return error.InvalidAccelerator;
            try validateAccelerator(accelerator);
            for (items[0..index]) |previous| if (previous.accelerator) |other| if (sameAccelerator(other, accelerator)) return error.DuplicateAccelerator;
        }
        if (item.radio) {
            if (item.kind != .command) return error.InvalidRadioItem;
            const group: u8 = if (index > 0 and items[index - 1].radio and std.meta.eql(items[index - 1].parent, item.parent)) plan.radio_group[index - 1].? else @intCast(index);
            plan.radio_group[index] = group;
            if (item.checked) for (items[group..index]) |previous| if (previous.checked) return error.MultipleRadioChecked;
        }
        if (item.kind == .command) plan.commands += 1;
    }
    return plan;
}

pub fn validateLabel(label: []const u8) !void {
    if (std.mem.indexOfScalar(u8, label, 0) != null) return error.EmbeddedNul;
    if (!std.unicode.utf8ValidateSlice(label)) return error.InvalidUtf8;
    const units = std.unicode.calcUtf16LeLen(label) catch return error.InvalidUtf8;
    if (units > 255) return error.TextCapacityExceeded;
}

pub fn validateAccelerator(accelerator: types.Accelerator) !void {
    const modifiers = accelerator.modifiers;
    if (modifiers.control or modifiers.alt or modifiers.super) return;
    if (functionKey(accelerator.key)) return;
    return error.InvalidAccelerator;
}

fn functionKey(key: types.Key) bool {
    return @backingInt(key) >= @backingInt(types.Key.f1) and @backingInt(key) <= @backingInt(types.Key.f24);
}

pub fn sameAccelerator(a: types.Accelerator, b: types.Accelerator) bool {
    return a.key == b.key and std.meta.eql(a.modifiers, b.modifiers);
}

/// Returns the enabled command bound to a key, if any. Disabled commands and
/// commands below a disabled submenu never match.
pub fn matchAccelerator(items: []const types.Item, plan: *const Plan, pressed: types.Accelerator) ?u64 {
    for (items[0..plan.count], 0..) |item, index| if (item.accelerator) |accelerator| {
        if (sameAccelerator(accelerator, pressed)) return if (plan.enabled[index]) item.id else null;
    };
    return null;
}

pub const Style = enum { windows, linux };

/// Writes a display name such as "Ctrl+Shift+S" for the platform's menus.
pub fn formatAccelerator(destination: []u8, accelerator: types.Accelerator, style: Style) ![]const u8 {
    var writer = std.Io.Writer.fixed(destination);
    const modifiers = accelerator.modifiers;
    if (modifiers.control) try writer.writeAll("Ctrl+");
    if (modifiers.alt) try writer.writeAll("Alt+");
    if (modifiers.shift) try writer.writeAll("Shift+");
    if (modifiers.super) try writer.writeAll(if (style == .windows) "Win+" else "Super+");
    try writer.writeAll(keyName(accelerator.key));
    return writer.buffered();
}

pub fn keyName(key: types.Key) []const u8 {
    return switch (key) {
        .a => "A",
        .b => "B",
        .c => "C",
        .d => "D",
        .e => "E",
        .f => "F",
        .g => "G",
        .h => "H",
        .i => "I",
        .j => "J",
        .k => "K",
        .l => "L",
        .m => "M",
        .n => "N",
        .o => "O",
        .p => "P",
        .q => "Q",
        .r => "R",
        .s => "S",
        .t => "T",
        .u => "U",
        .v => "V",
        .w => "W",
        .x => "X",
        .y => "Y",
        .z => "Z",
        .digit0 => "0",
        .digit1 => "1",
        .digit2 => "2",
        .digit3 => "3",
        .digit4 => "4",
        .digit5 => "5",
        .digit6 => "6",
        .digit7 => "7",
        .digit8 => "8",
        .digit9 => "9",
        .f1 => "F1",
        .f2 => "F2",
        .f3 => "F3",
        .f4 => "F4",
        .f5 => "F5",
        .f6 => "F6",
        .f7 => "F7",
        .f8 => "F8",
        .f9 => "F9",
        .f10 => "F10",
        .f11 => "F11",
        .f12 => "F12",
        .f13 => "F13",
        .f14 => "F14",
        .f15 => "F15",
        .f16 => "F16",
        .f17 => "F17",
        .f18 => "F18",
        .f19 => "F19",
        .f20 => "F20",
        .f21 => "F21",
        .f22 => "F22",
        .f23 => "F23",
        .f24 => "F24",
        .space => "Space",
        .enter => "Enter",
        .escape => "Esc",
        .tab => "Tab",
        .backspace => "Backspace",
        .delete => "Del",
        .insert => "Ins",
        .home => "Home",
        .end => "End",
        .page_up => "PgUp",
        .page_down => "PgDn",
        .left => "Left",
        .right => "Right",
        .up => "Up",
        .down => "Down",
        .plus => "Plus",
        .minus => "-",
    };
}

/// Labels use `&` before a mnemonic and `&&` for a literal ampersand on every
/// platform. GTK spells mnemonics with `_`, so literal underscores double.
pub fn gtkMnemonic(destination: []u8, label: []const u8) ![:0]const u8 {
    var used: usize = 0;
    var index: usize = 0;
    while (index < label.len) : (index += 1) {
        var byte = label[index];
        var double = false;
        if (byte == '&') {
            if (index + 1 < label.len and label[index + 1] == '&') {
                index += 1;
            } else if (index + 1 < label.len) {
                byte = '_';
            } else continue;
        } else if (byte == '_') double = true;
        const needed: usize = if (double) 2 else 1;
        if (used + needed >= destination.len) return error.TextCapacityExceeded;
        destination[used] = byte;
        if (double) destination[used + 1] = '_';
        used += needed;
    }
    destination[used] = 0;
    return destination[0..used :0];
}

/// An owned copy of a menu, for menus a platform opens later on its own,
/// such as a tray item's menu after a click. Labels are copied into fixed
/// storage, so the caller's slice is free once `set` returns.
pub const Snapshot = struct {
    items: [max_items]types.Item = undefined,
    text: [max_items * 256]u8 = undefined,
    count: usize = 0,

    /// Replaces the copy; an empty slice clears it. A failed call keeps the
    /// previous copy.
    pub fn set(self: *Snapshot, items: []const types.Item) !void {
        _ = try validate(items, false);
        var needed: usize = 0;
        for (items) |item| needed += item.label.len;
        if (needed > self.text.len) return error.TextCapacityExceeded;
        var used: usize = 0;
        for (items, 0..) |item, index| {
            @memcpy(self.text[used..][0..item.label.len], item.label);
            self.items[index] = item;
            self.items[index].label = self.text[used..][0..item.label.len];
            used += item.label.len;
        }
        self.count = items.len;
    }
    pub fn slice(self: *const Snapshot) []const types.Item {
        return self.items[0..self.count];
    }
};

/// Validates the button set and the default/cancel indices of a message.
pub fn validateMessage(options: types.MessageOptions) !void {
    if (options.buttons.len == 0 or options.buttons.len > types.max_message_buttons) return error.InvalidMessageButtons;
    if (options.message.len == 0) return error.EmptyMessage;
    try validateText(options.message, 4096);
    try validateText(options.title, 255);
    for (options.buttons, 0..) |button, index| {
        if (button.id == 0) return error.InvalidMessageButtons;
        if (button.label.len == 0) return error.InvalidMessageButtons;
        for (options.buttons[0..index]) |previous| if (previous.id == button.id) return error.InvalidMessageButtons;
        try validateText(button.label, 64);
    }
    if (options.default_button) |index| if (index >= options.buttons.len) return error.InvalidMessageButtons;
    if (options.cancel_button) |index| if (index >= options.buttons.len) return error.InvalidMessageButtons;
}

fn validateText(text: []const u8, max_units: usize) !void {
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.EmbeddedNul;
    const units = std.unicode.calcUtf16LeLen(text) catch return error.InvalidUtf8;
    if (units > max_units) return error.TextCapacityExceeded;
}

const testing = std.testing;

test "menu plans reject malformed snapshots" {
    try testing.expectError(error.EmptyMenu, validate(&.{}, true));
    _ = try validate(&.{}, false);
    try testing.expectError(error.InvalidMenuId, validate(&.{.{ .label = "None" }}, true));
    try testing.expectError(error.DuplicateMenuId, validate(&.{ .{ .id = 1, .label = "A" }, .{ .id = 1, .label = "B" } }, true));
    try testing.expectError(error.InvalidMenuParent, validate(&.{ .{ .id = 1, .label = "A" }, .{ .id = 2, .parent = 1, .label = "B" } }, true));
    try testing.expectError(error.InvalidMenuParent, validate(&.{ .{ .id = 2, .parent = 1, .label = "B" }, .{ .id = 1, .kind = .submenu, .label = "A" } }, true));
    try testing.expectError(error.EmbeddedNul, validate(&.{.{ .id = 1, .label = "a\x00b" }}, true));
    try testing.expectError(error.InvalidUtf8, validate(&.{.{ .id = 1, .label = "\xff" }}, true));
    try testing.expectError(error.TextCapacityExceeded, validate(&.{.{ .id = 1, .label = &@as([256]u8, @splat('x')) }}, true));
    _ = try validate(&.{.{ .id = 1, .label = &@as([255]u8, @splat('x')) }}, true);
    const many: [max_items + 1]types.Item = @splat(.{ .kind = .separator });
    try testing.expectError(error.TooManyMenuItems, validate(&many, false));
    // Separators need no identity and may repeat.
    const plan = try validate(&.{ .{ .id = 1, .label = "A" }, .{ .kind = .separator }, .{ .kind = .separator } }, true);
    try testing.expectEqual(1, plan.commands);
}

test "disabled ancestors disable every descendant command" {
    const items = [_]types.Item{
        .{ .id = 1, .kind = .submenu, .label = "&Edit", .enabled = false },
        .{ .id = 2, .parent = 1, .kind = .submenu, .label = "Nested" },
        .{ .id = 3, .parent = 2, .label = "Deep", .accelerator = .{ .key = .d, .modifiers = .{ .control = true } } },
        .{ .id = 4, .label = "Root", .accelerator = .{ .key = .f5 } },
        .{ .id = 5, .label = "Off", .enabled = false, .accelerator = .{ .key = .f6 } },
    };
    const plan = try validate(&items, false);
    try testing.expect(!plan.enabled[1] and !plan.enabled[2] and !plan.ancestors_enabled[2]);
    try testing.expect(plan.enabled[3] and plan.ancestors_enabled[4] and !plan.enabled[4]);
    try testing.expectEqual(@as(?u8, 1), plan.parent[2]);
    try testing.expectEqual(@as(?u64, null), matchAccelerator(&items, &plan, .{ .key = .d, .modifiers = .{ .control = true } }));
    try testing.expectEqual(@as(?u64, 4), matchAccelerator(&items, &plan, .{ .key = .f5 }));
    try testing.expectEqual(@as(?u64, null), matchAccelerator(&items, &plan, .{ .key = .f5, .modifiers = .{ .shift = true } }));
    try testing.expectEqual(@as(?u64, null), matchAccelerator(&items, &plan, .{ .key = .f6 }));
    try testing.expectEqual(@as(?usize, 3), plan.lookup(&items, 4));
    try testing.expectEqual(@as(?usize, null), plan.lookup(&items, 1));
}

test "adjacent radio commands under one parent form a group with one checked item" {
    const items = [_]types.Item{
        .{ .id = 1, .label = "Small", .radio = true, .checked = true },
        .{ .id = 2, .label = "Large", .radio = true },
        .{ .kind = .separator },
        .{ .id = 3, .label = "Light", .radio = true },
        .{ .id = 4, .label = "Dark", .radio = true, .checked = true },
        .{ .id = 5, .label = "Plain", .checked = true },
    };
    const plan = try validate(&items, true);
    try testing.expectEqual(@as(?u8, 0), plan.radio_group[1]);
    try testing.expectEqual(@as(?u8, null), plan.radio_group[2]);
    try testing.expectEqual(@as(?u8, 3), plan.radio_group[4]);
    try testing.expectEqual(@as(?u8, null), plan.radio_group[5]);
    try testing.expectError(error.MultipleRadioChecked, validate(&.{ .{ .id = 1, .label = "A", .radio = true, .checked = true }, .{ .id = 2, .label = "B", .radio = true, .checked = true } }, true));
    try testing.expectError(error.InvalidRadioItem, validate(&.{.{ .id = 1, .label = "A", .kind = .submenu, .radio = true }}, true));
    // A different parent starts another group.
    const nested = [_]types.Item{
        .{ .id = 1, .label = "A", .radio = true, .checked = true },
        .{ .id = 2, .label = "Menu", .kind = .submenu },
        .{ .id = 3, .label = "B", .parent = 2, .radio = true, .checked = true },
    };
    const nested_plan = try validate(&nested, false);
    try testing.expectEqual(@as(?u8, 2), nested_plan.radio_group[2]);
}

test "accelerators must not capture typing and must be unique" {
    try testing.expectError(error.InvalidAccelerator, validate(&.{.{ .id = 1, .label = "A", .accelerator = .{ .key = .s } }}, true));
    try testing.expectError(error.InvalidAccelerator, validate(&.{.{ .id = 1, .label = "A", .accelerator = .{ .key = .s, .modifiers = .{ .shift = true } } }}, true));
    try testing.expectError(error.InvalidAccelerator, validate(&.{.{ .id = 1, .kind = .submenu, .label = "A", .accelerator = .{ .key = .f1 } }}, true));
    try testing.expectError(error.DuplicateAccelerator, validate(&.{
        .{ .id = 1, .label = "A", .accelerator = .{ .key = .s, .modifiers = .{ .control = true } } },
        .{ .id = 2, .label = "B", .accelerator = .{ .key = .s, .modifiers = .{ .control = true } } },
    }, true));
    _ = try validate(&.{
        .{ .id = 1, .label = "A", .accelerator = .{ .key = .s, .modifiers = .{ .control = true } } },
        .{ .id = 2, .label = "B", .accelerator = .{ .key = .s, .modifiers = .{ .control = true, .shift = true } } },
        .{ .id = 3, .label = "C", .accelerator = .{ .key = .left, .modifiers = .{ .alt = true } } },
    }, true);
}

test "accelerator names follow each platform's spelling" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("Ctrl+Shift+S", try formatAccelerator(&buffer, .{ .key = .s, .modifiers = .{ .control = true, .shift = true } }, .windows));
    try testing.expectEqualStrings("Alt+Win+F4", try formatAccelerator(&buffer, .{ .key = .f4, .modifiers = .{ .alt = true, .super = true } }, .windows));
    try testing.expectEqualStrings("Super+PgDn", try formatAccelerator(&buffer, .{ .key = .page_down, .modifiers = .{ .super = true } }, .linux));
    try testing.expectError(error.WriteFailed, formatAccelerator(buffer[0..4], .{ .key = .s, .modifiers = .{ .control = true } }, .windows));
}

test "ampersand mnemonics translate to GTK underscores" {
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("_File", try gtkMnemonic(&buffer, "&File"));
    try testing.expectEqualStrings("Save & Close", try gtkMnemonic(&buffer, "Save && Close"));
    try testing.expectEqualStrings("snake__case", try gtkMnemonic(&buffer, "snake_case"));
    try testing.expectEqualStrings("End", try gtkMnemonic(&buffer, "End&"));
    try testing.expectError(error.TextCapacityExceeded, gtkMnemonic(buffer[0..4], "____"));
}

test "menu snapshots own their labels and keep the old copy on failure" {
    var snapshot: Snapshot = .{};
    var label = "&Show".*;
    try snapshot.set(&.{ .{ .id = 1, .label = &label }, .{ .kind = .separator }, .{ .id = 2, .label = "Quit", .checked = true } });
    label[1] = 'X';
    try testing.expectEqual(3, snapshot.slice().len);
    try testing.expectEqualStrings("&Show", snapshot.slice()[0].label);
    try testing.expect(snapshot.slice()[2].checked);
    try testing.expectError(error.DuplicateMenuId, snapshot.set(&.{ .{ .id = 1, .label = "A" }, .{ .id = 1, .label = "B" } }));
    try testing.expectEqualStrings("Quit", snapshot.slice()[2].label);
    try snapshot.set(&.{});
    try testing.expectEqual(0, snapshot.slice().len);
}

test "message options are bounded and indices checked" {
    const ok = [_]types.MessageButton{ .{ .id = 1, .label = "OK" }, .{ .id = 2, .label = "Cancel" } };
    try validateMessage(.{ .message = "Saved", .buttons = &ok, .default_button = 0, .cancel_button = 1 });
    try testing.expectError(error.InvalidMessageButtons, validateMessage(.{ .message = "Saved", .buttons = &.{} }));
    try testing.expectError(error.EmptyMessage, validateMessage(.{ .message = "", .buttons = &ok }));
    try testing.expectError(error.InvalidMessageButtons, validateMessage(.{ .message = "x", .buttons = &ok, .cancel_button = 2 }));
    try testing.expectError(error.InvalidMessageButtons, validateMessage(.{ .message = "x", .buttons = &.{ .{ .id = 1, .label = "A" }, .{ .id = 1, .label = "B" } } }));
    try testing.expectError(error.InvalidMessageButtons, validateMessage(.{ .message = "x", .buttons = &.{ .{ .id = 1, .label = "A" }, .{ .id = 2, .label = "B" }, .{ .id = 3, .label = "C" }, .{ .id = 4, .label = "D" } } }));
    try testing.expectError(error.InvalidMessageButtons, validateMessage(.{ .message = "x", .buttons = &.{.{ .id = 1, .label = "" }} }));
    try testing.expectError(error.EmbeddedNul, validateMessage(.{ .message = "a\x00", .buttons = &ok }));
    try testing.expectError(error.TextCapacityExceeded, validateMessage(.{ .message = "x", .title = &@as([256]u8, @splat('t')), .buttons = &ok }));
}
