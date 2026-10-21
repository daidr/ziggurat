//! Keys bound to terminal actions, as Ghostty's `keybind` option binds
//! them: the view does the action instead of sending the key to the
//! program. The defaults are Ghostty's for the platform; bindings an app
//! adds replace those of their key and modifiers, and one to `.none`
//! unbinds the key so that the program gets it.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");

pub const Action = enum {
    /// Unbinds the key, which goes to the program.
    none,
    /// Takes the key and does nothing.
    ignore,
    /// Copies the selection. Does something only with a selection, and when
    /// performable also lets go of it, so the key's next press reaches the
    /// program, as Windows Terminal's Control+C.
    copy,
    /// Pastes the clipboard. Does something only when the clipboard holds
    /// something.
    paste,
    /// Selects the scrollback and the screen.
    select_all,
    /// Clears the scrollback and the screen above the cursor's line, which
    /// moves to the top. Does nothing on a full-screen program's screen.
    clear_screen,
    /// Zoom a step in or out, or back to the font's size.
    increase_font_size,
    decrease_font_size,
    reset_font_size,
    /// Scroll the scrollback. They do nothing on a full-screen program's
    /// screen, which has none.
    scroll_page_up,
    scroll_page_down,
    scroll_to_top,
    scroll_to_bottom,
};

pub const Mods = packed struct(u4) {
    control: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,

    pub fn of(m: z.KeyModifiers) Mods {
        return .{ .control = m.control, .shift = m.shift, .alt = m.alt, .super = m.super };
    }
};

/// A key, with exactly `mods` held, bound to an action. A performable
/// binding, as Ghostty's `performable:` prefix, takes the key only when the
/// action does something; otherwise the key goes on as if unbound.
pub const Keybind = struct {
    mods: Mods = .{},
    key: z.KeyCode,
    action: Action,
    performable: bool = false,
};

pub const Os = enum { linux, windows, macos };

pub const native_os: Os = switch (builtin.os.tag) {
    .windows => .windows,
    .macos => .macos,
    else => .linux,
};

pub const max_bindings = 64;

/// A set of bindings, in order, the defaults first.
pub const Bindings = struct {
    items: [max_bindings]Keybind = undefined,
    len: usize = 0,

    /// The defaults of `os` unless `no_defaults`, then `extra` over them,
    /// each replacing the bindings of its key and modifiers.
    pub fn init(os: Os, extra: []const Keybind, no_defaults: bool) Bindings {
        var out: Bindings = .{};
        if (!no_defaults) out.addDefaults(os);
        for (extra) |b| out.bind(b);
        return out;
    }

    pub fn slice(self: *const Bindings) []const Keybind {
        return self.items[0..self.len];
    }

    /// Bind a key over what it had; `.none` unbinds it.
    pub fn bind(self: *Bindings, binding: Keybind) void {
        var kept: usize = 0;
        for (self.items[0..self.len]) |b| {
            if (b.mods == binding.mods and b.key == binding.key) continue;
            self.items[kept] = b;
            kept += 1;
        }
        self.len = kept;
        if (binding.action != .none and self.len < max_bindings) {
            self.items[self.len] = binding;
            self.len += 1;
        }
    }

    /// The binding of a key with exactly these modifiers.
    pub fn find(self: *const Bindings, mods: Mods, key: z.KeyCode) ?Keybind {
        for (self.slice()) |b| if (b.mods == mods and b.key == key) return b;
        return null;
    }

    /// The key a menu item of an action shows: its first binding that
    /// always takes the key, as Ghostty's menus show no performable one,
    /// else its first.
    pub fn shortcut(self: *const Bindings, action: Action) ?Keybind {
        var found: ?Keybind = null;
        for (self.slice()) |b| {
            if (b.action != action) continue;
            if (!b.performable) return b;
            if (found == null) found = b;
        }
        return found;
    }

    fn add(self: *Bindings, mods: Mods, key: z.KeyCode, action: Action, performable: bool) void {
        self.items[self.len] = .{ .mods = mods, .key = key, .action = action, .performable = performable };
        self.len += 1;
    }

    fn scroll(self: *Bindings, mods: Mods) void {
        self.add(mods, .page_up, .scroll_page_up, true);
        self.add(mods, .page_down, .scroll_page_down, true);
        self.add(mods, .home, .scroll_to_top, true);
        self.add(mods, .end, .scroll_to_bottom, true);
    }

    fn addDefaults(self: *Bindings, os: Os) void {
        const shift: Mods = .{ .shift = true };
        if (os == .macos) {
            const cmd: Mods = .{ .super = true };
            self.add(cmd, .c, .copy, false);
            self.add(cmd, .v, .paste, false);
            self.add(cmd, .a, .select_all, false);
            self.add(cmd, .k, .clear_screen, true);
            self.add(cmd, .equal, .increase_font_size, false);
            self.add(.{ .super = true, .shift = true }, .equal, .increase_font_size, false);
            self.add(cmd, .minus, .decrease_font_size, false);
            self.add(cmd, .digit0, .reset_font_size, false);
            self.scroll(cmd);
            self.add(shift, .page_up, .scroll_page_up, true);
            self.add(shift, .page_down, .scroll_page_down, true);
            return;
        }
        const ctrl: Mods = .{ .control = true };
        const ctrl_shift: Mods = .{ .control = true, .shift = true };
        // The first key of an action is the one menus show.
        self.add(ctrl_shift, .c, .copy, false);
        self.add(ctrl_shift, .v, .paste, false);
        self.add(ctrl, .insert, .copy, false);
        self.add(shift, .insert, .paste, false);
        self.add(ctrl_shift, .a, .select_all, false);
        self.add(ctrl, .equal, .increase_font_size, false);
        self.add(ctrl_shift, .equal, .increase_font_size, false);
        self.add(ctrl, .minus, .decrease_font_size, false);
        self.add(ctrl, .digit0, .reset_font_size, false);
        if (os != .windows) {
            self.scroll(shift);
            return;
        }
        // Windows Terminal's, which leave Shift+Home and End to the shell,
        // as PowerShell selects with them.
        self.add(ctrl, .c, .copy, true);
        self.add(ctrl, .v, .paste, true);
        self.add(ctrl_shift, .k, .clear_screen, true);
        self.add(shift, .page_up, .scroll_page_up, true);
        self.add(shift, .page_down, .scroll_page_down, true);
        self.scroll(ctrl_shift);
    }
};

test "the defaults are the platform's, and bindings replace them by key" {
    const linux = Bindings.init(.linux, &.{}, false);
    try std.testing.expectEqual(Action.copy, linux.find(.{ .control = true, .shift = true }, .c).?.action);
    try std.testing.expect(linux.find(.{ .control = true }, .c) == null);
    try std.testing.expectEqual(Action.scroll_to_top, linux.find(.{ .shift = true }, .home).?.action);
    const windows = Bindings.init(.windows, &.{}, false);
    const ctrl_c = windows.find(.{ .control = true }, .c).?;
    try std.testing.expect(ctrl_c.performable);
    try std.testing.expect(windows.find(.{ .shift = true }, .home) == null);
    try std.testing.expectEqual(Action.clear_screen, windows.find(.{ .control = true, .shift = true }, .k).?.action);
    // Menus show the binding that always takes its key.
    try std.testing.expectEqual(@as(?Mods, .{ .control = true, .shift = true }), if (windows.shortcut(.copy)) |b| b.mods else null);
    try std.testing.expect(windows.shortcut(.clear_screen).?.performable);
    const mac = Bindings.init(.macos, &.{}, false);
    try std.testing.expectEqual(Action.clear_screen, mac.find(.{ .super = true }, .k).?.action);

    const custom = Bindings.init(.linux, &.{
        .{ .mods = .{ .control = true }, .key = .c, .action = .copy, .performable = true },
        .{ .mods = .{ .control = true, .shift = true }, .key = .a, .action = .none },
        .{ .mods = .{ .control = true, .shift = true }, .key = .v, .action = .ignore },
    }, false);
    try std.testing.expect(custom.find(.{ .control = true }, .c).?.performable);
    try std.testing.expect(custom.find(.{ .control = true, .shift = true }, .a) == null);
    try std.testing.expectEqual(Action.ignore, custom.find(.{ .control = true, .shift = true }, .v).?.action);
    try std.testing.expectEqual(@as(usize, 1), Bindings.init(.linux, &.{.{ .key = .f1, .action = .select_all }}, true).len);
}
