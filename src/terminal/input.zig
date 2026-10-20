//! What the terminal sends to the program for keys, pasted text, the mouse
//! and focus, following the modes the program set. Keys that type text are
//! left to the platform's text input, which knows the keyboard layout and
//! the input method; these encoders cover the rest.
const std = @import("std");
const z = @import("ziggurat");
const screen = @import("screen.zig");

pub const Modes = screen.Modes;

/// The longest sequence a key produces.
pub const max_key = 16;

/// The bytes for `key`, or null when it types text or means nothing to a
/// terminal.
pub fn key(input: z.KeyInput, modes: Modes, buffer: *[max_key]u8) ?[]const u8 {
    const m = input.modifiers;
    // xterm's modifier parameter: 1 plus shift 1, alt 2, control 4, super 8.
    const mod: u8 = 1 + @as(u8, @intFromBool(m.shift)) + 2 * @as(u8, @intFromBool(m.alt)) + 4 * @as(u8, @intFromBool(m.control)) + 8 * @as(u8, @intFromBool(m.super));
    const modified = mod > 1;
    switch (input.key) {
        .up, .down, .right, .left, .home, .end => {
            const final: u8 = switch (input.key) {
                .up => 'A',
                .down => 'B',
                .right => 'C',
                .left => 'D',
                .home => 'H',
                else => 'F',
            };
            if (modified) return std.fmt.bufPrint(buffer, "\x1b[1;{d}{c}", .{ mod, final }) catch unreachable;
            return std.fmt.bufPrint(buffer, "\x1b{c}{c}", .{ @as(u8, if (modes.cursor_keys) 'O' else '['), final }) catch unreachable;
        },
        .insert, .delete, .page_up, .page_down => {
            const number: u8 = switch (input.key) {
                .insert => 2,
                .delete => 3,
                .page_up => 5,
                else => 6,
            };
            if (modified) return std.fmt.bufPrint(buffer, "\x1b[{d};{d}~", .{ number, mod }) catch unreachable;
            return std.fmt.bufPrint(buffer, "\x1b[{d}~", .{number}) catch unreachable;
        },
        .f1, .f2, .f3, .f4 => {
            const final: u8 = 'P' + @as(u8, @intCast(@intFromEnum(input.key) - @intFromEnum(z.KeyCode.f1)));
            if (modified) return std.fmt.bufPrint(buffer, "\x1b[1;{d}{c}", .{ mod, final }) catch unreachable;
            return std.fmt.bufPrint(buffer, "\x1bO{c}", .{final}) catch unreachable;
        },
        .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20 => {
            const codes = [_]u8{ 15, 17, 18, 19, 20, 21, 23, 24, 25, 26, 28, 29, 31, 32, 33, 34 };
            const number = codes[@intFromEnum(input.key) - @intFromEnum(z.KeyCode.f5)];
            if (modified) return std.fmt.bufPrint(buffer, "\x1b[{d};{d}~", .{ number, mod }) catch unreachable;
            return std.fmt.bufPrint(buffer, "\x1b[{d}~", .{number}) catch unreachable;
        },
        .enter => {
            const text: []const u8 = if (modes.newline) "\r\n" else "\r";
            return prefixed(buffer, m.alt, text);
        },
        .tab => {
            if (m.control or m.super) return null;
            if (m.shift) return copy(buffer, "\x1b[Z");
            return prefixed(buffer, m.alt, "\t");
        },
        .backspace => return prefixed(buffer, m.alt, if (m.control) "\x08" else "\x7f"),
        .escape => return prefixed(buffer, m.alt, "\x1b"),
        .numpad0, .numpad1, .numpad2, .numpad3, .numpad4, .numpad5, .numpad6, .numpad7, .numpad8, .numpad9, .decimal, .add, .subtract, .multiply, .divide => {
            if (!modes.keypad or modified) return null;
            const final: u8 = switch (input.key) {
                .decimal => 'n',
                .add => 'k',
                .subtract => 'm',
                .multiply => 'j',
                .divide => 'o',
                else => 'p' + @as(u8, @intCast(@intFromEnum(input.key) - @intFromEnum(z.KeyCode.numpad0))),
            };
            return std.fmt.bufPrint(buffer, "\x1bO{c}", .{final}) catch unreachable;
        },
        else => {},
    }
    if (m.super) return null;
    // Control and Alt with a character key send what text input cannot.
    const base = character(input.key, m.shift) orelse return null;
    if (m.control) {
        const control = controlCode(base) orelse return if (m.alt) null else null;
        return prefixed(buffer, m.alt, &.{control});
    }
    if (m.alt) return prefixed(buffer, true, &.{base});
    return null;
}

fn copy(buffer: *[max_key]u8, bytes: []const u8) []const u8 {
    @memcpy(buffer[0..bytes.len], bytes);
    return buffer[0..bytes.len];
}
/// `bytes`, after ESC when Alt is held.
fn prefixed(buffer: *[max_key]u8, alt: bool, bytes: []const u8) []const u8 {
    var len: usize = 0;
    if (alt) {
        buffer[0] = 0x1b;
        len = 1;
    }
    @memcpy(buffer[len..][0..bytes.len], bytes);
    return buffer[0 .. len + bytes.len];
}

/// The character a key types on a US layout, for Control and Alt chords.
fn character(code: z.KeyCode, shift: bool) ?u8 {
    const index = @intFromEnum(code);
    if (index >= @intFromEnum(z.KeyCode.a) and index <= @intFromEnum(z.KeyCode.z)) {
        const letter: u8 = 'a' + @as(u8, @intCast(index - @intFromEnum(z.KeyCode.a)));
        return if (shift) std.ascii.toUpper(letter) else letter;
    }
    if (index >= @intFromEnum(z.KeyCode.digit0) and index <= @intFromEnum(z.KeyCode.digit9)) {
        const digit: u8 = @intCast(index - @intFromEnum(z.KeyCode.digit0));
        return if (shift) ")!@#$%^&*("[digit] else '0' + digit;
    }
    return switch (code) {
        .space => ' ',
        .minus => if (shift) '_' else '-',
        .equal => if (shift) '+' else '=',
        .left_bracket => if (shift) '{' else '[',
        .right_bracket => if (shift) '}' else ']',
        .backslash => if (shift) '|' else '\\',
        .semicolon => if (shift) ':' else ';',
        .apostrophe => if (shift) '"' else '\'',
        .grave => if (shift) '~' else '`',
        .comma => if (shift) '<' else ',',
        .period => if (shift) '>' else '.',
        .slash => if (shift) '?' else '/',
        else => null,
    };
}

fn controlCode(c: u8) ?u8 {
    return switch (c) {
        'a'...'z' => c - 'a' + 1,
        'A'...'Z' => c - 'A' + 1,
        ' ', '2', '@' => 0,
        '[', '3', '{' => 0x1b,
        '\\', '4', '|' => 0x1c,
        ']', '5', '}' => 0x1d,
        '^', '6', '~' => 0x1e,
        '_', '7', '-', '/', '?' => 0x1f,
        '8' => 0x7f,
        else => null,
    };
}

/// Text from the platform's text input, without control characters that
/// keys already sent.
pub fn typed(text: []const u8) bool {
    for (text) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return text.len > 0;
}

/// Write `text` as a paste: line breaks become carriage returns, and in
/// bracketed paste mode it goes between the markers with any ESC removed,
/// so pasted text cannot end the paste early. Returns the bytes written
/// into `out`, which needs `pasteSize(text)` bytes.
pub fn paste(text: []const u8, bracketed: bool, out: []u8) []const u8 {
    var len: usize = 0;
    if (bracketed) {
        @memcpy(out[0..6], "\x1b[200~");
        len = 6;
    }
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const byte = text[i];
        if (byte == '\r' and i + 1 < text.len and text[i + 1] == '\n') continue;
        if (bracketed and byte == 0x1b) continue;
        out[len] = if (byte == '\n') '\r' else byte;
        len += 1;
    }
    if (bracketed) {
        @memcpy(out[len..][0..6], "\x1b[201~");
        len += 6;
    }
    return out[0..len];
}
pub fn pasteSize(text: []const u8) usize {
    return text.len + 12;
}

pub const MouseButton = enum { left, middle, right, none, wheel_up, wheel_down, wheel_left, wheel_right };
pub const MouseAction = enum { press, release, motion };
pub const Mouse = struct {
    button: MouseButton,
    action: MouseAction,
    /// 0-based cell.
    col: u16,
    row: u16,
    /// Position in pixels for SGR pixel mode.
    x: u32 = 0,
    y: u32 = 0,
    modifiers: z.KeyModifiers = .{},
};

pub const max_mouse = 32;

/// The report for a mouse event under the program's tracking mode, or null
/// when the mode does not report it.
pub fn mouse(event: Mouse, modes: Modes, buffer: *[max_mouse]u8) ?[]const u8 {
    switch (modes.mouse) {
        .none => return null,
        .x10 => if (event.action != .press or event.button == .none) return null,
        .normal => if (event.action == .motion) return null,
        .button => if (event.action == .motion and event.button == .none) return null,
        .any => {},
    }
    var code: u8 = switch (event.button) {
        .left => 0,
        .middle => 1,
        .right => 2,
        .none => 3,
        .wheel_up => 64,
        .wheel_down => 65,
        .wheel_left => 66,
        .wheel_right => 67,
    };
    if (event.action == .motion) code += 32;
    if (modes.mouse != .x10) {
        if (event.modifiers.shift) code += 4;
        if (event.modifiers.alt) code += 8;
        if (event.modifiers.control) code += 16;
    }
    const col: u32 = @as(u32, event.col) + 1;
    const row: u32 = @as(u32, event.row) + 1;
    switch (modes.mouse_encoding) {
        .sgr, .sgr_pixels => {
            const final: u8 = if (event.action == .release) 'm' else 'M';
            const x = if (modes.mouse_encoding == .sgr_pixels) event.x + 1 else col;
            const y = if (modes.mouse_encoding == .sgr_pixels) event.y + 1 else row;
            return std.fmt.bufPrint(buffer, "\x1b[<{d};{d};{d}{c}", .{ code, x, y, final }) catch unreachable;
        },
        .urxvt => {
            if (event.action == .release) code = 3 + (code & ~@as(u8, 3));
            return std.fmt.bufPrint(buffer, "\x1b[{d};{d};{d}M", .{ @as(u32, code) + 32, col, row }) catch unreachable;
        },
        .x10, .utf8 => {
            // The release of any button reports as button 3.
            if (event.action == .release and event.button != .wheel_up and event.button != .wheel_down) code = 3 + (code & ~@as(u8, 3));
            var len: usize = 3;
            @memcpy(buffer[0..3], "\x1b[M");
            buffer[3] = code + 32;
            len = 4;
            for ([_]u32{ col, row }) |value| {
                if (modes.mouse_encoding == .utf8) {
                    const cp: u21 = @intCast(@min(value + 32, 2047));
                    len += std.unicode.utf8Encode(cp, buffer[len..]) catch unreachable;
                } else {
                    // Classic reports cannot go past column 223.
                    if (value > 223) return null;
                    buffer[len] = @intCast(value + 32);
                    len += 1;
                }
            }
            return buffer[0..len];
        },
    }
}

/// The report for the window gaining or losing focus, when asked for.
pub fn focus(focused: bool, modes: Modes) ?[]const u8 {
    if (!modes.focus_events) return null;
    return if (focused) "\x1b[I" else "\x1b[O";
}

test "keys under normal and application cursor modes" {
    var buffer: [max_key]u8 = undefined;
    var modes: Modes = .{};
    try std.testing.expectEqualStrings("\x1b[A", key(.{ .key = .up }, modes, &buffer).?);
    try std.testing.expectEqualStrings("\x1b[1;5C", key(.{ .key = .right, .modifiers = .{ .control = true } }, modes, &buffer).?);
    try std.testing.expectEqualStrings("\x1b[3~", key(.{ .key = .delete }, modes, &buffer).?);
    try std.testing.expectEqualStrings("\x1b[5;2~", key(.{ .key = .page_up, .modifiers = .{ .shift = true } }, modes, &buffer).?);
    try std.testing.expectEqualStrings("\x1bOP", key(.{ .key = .f1 }, modes, &buffer).?);
    try std.testing.expectEqualStrings("\x1b[15~", key(.{ .key = .f5 }, modes, &buffer).?);
    try std.testing.expectEqualStrings("\x1b[24;3~", key(.{ .key = .f12, .modifiers = .{ .alt = true } }, modes, &buffer).?);
    try std.testing.expectEqualStrings("\r", key(.{ .key = .enter }, modes, &buffer).?);
    try std.testing.expectEqualStrings("\x7f", key(.{ .key = .backspace }, modes, &buffer).?);
    try std.testing.expectEqualStrings("\x1b[Z", key(.{ .key = .tab, .modifiers = .{ .shift = true } }, modes, &buffer).?);
    try std.testing.expectEqualStrings("\x03", key(.{ .key = .c, .modifiers = .{ .control = true } }, modes, &buffer).?);
    try std.testing.expectEqualStrings("\x1b\x01", key(.{ .key = .a, .modifiers = .{ .control = true, .alt = true } }, modes, &buffer).?);
    try std.testing.expectEqualStrings("\x1bx", key(.{ .key = .x, .modifiers = .{ .alt = true } }, modes, &buffer).?);
    try std.testing.expectEqualStrings("\x1bX", key(.{ .key = .x, .modifiers = .{ .alt = true, .shift = true } }, modes, &buffer).?);
    try std.testing.expectEqualStrings("\x00", key(.{ .key = .space, .modifiers = .{ .control = true } }, modes, &buffer).?);
    try std.testing.expectEqualStrings("\x1f", key(.{ .key = .slash, .modifiers = .{ .control = true } }, modes, &buffer).?);
    // Plain characters are typed text.
    try std.testing.expect(key(.{ .key = .a }, modes, &buffer) == null);
    try std.testing.expect(key(.{ .key = .a, .modifiers = .{ .shift = true } }, modes, &buffer) == null);
    try std.testing.expect(key(.{ .key = .numpad5 }, modes, &buffer) == null);
    modes.cursor_keys = true;
    modes.keypad = true;
    modes.newline = true;
    try std.testing.expectEqualStrings("\x1bOA", key(.{ .key = .up }, modes, &buffer).?);
    try std.testing.expectEqualStrings("\x1bOH", key(.{ .key = .home }, modes, &buffer).?);
    try std.testing.expectEqualStrings("\x1bOu", key(.{ .key = .numpad5 }, modes, &buffer).?);
    try std.testing.expectEqualStrings("\r\n", key(.{ .key = .enter }, modes, &buffer).?);
}

test "pasting converts line breaks and brackets safely" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a\rb\rc", paste("a\r\nb\nc", false, &out));
    try std.testing.expectEqualStrings("\x1b[200~ab[201~c\x1b[201~", paste("a\x1bb\x1b[201~c", true, &out));
    try std.testing.expect(typed("héllo"));
    try std.testing.expect(!typed("\x03"));
    try std.testing.expect(!typed(""));
}

test "mouse reports follow tracking and encoding modes" {
    var buffer: [max_mouse]u8 = undefined;
    var modes: Modes = .{};
    const press: Mouse = .{ .button = .left, .action = .press, .col = 4, .row = 1 };
    try std.testing.expect(mouse(press, modes, &buffer) == null);
    modes.mouse = .normal;
    try std.testing.expectEqualStrings("\x1b[M %\"", mouse(press, modes, &buffer).?);
    try std.testing.expectEqualStrings("\x1b[M#%\"", mouse(.{ .button = .left, .action = .release, .col = 4, .row = 1 }, modes, &buffer).?);
    try std.testing.expect(mouse(.{ .button = .left, .action = .motion, .col = 4, .row = 1 }, modes, &buffer) == null);
    modes.mouse = .button;
    modes.mouse_encoding = .sgr;
    try std.testing.expectEqualStrings("\x1b[<32;5;2M", mouse(.{ .button = .left, .action = .motion, .col = 4, .row = 1 }, modes, &buffer).?);
    try std.testing.expectEqualStrings("\x1b[<0;5;2m", mouse(.{ .button = .left, .action = .release, .col = 4, .row = 1 }, modes, &buffer).?);
    try std.testing.expectEqualStrings("\x1b[<80;5;2M", mouse(.{ .button = .wheel_up, .action = .press, .col = 4, .row = 1, .modifiers = .{ .control = true } }, modes, &buffer).?);
    try std.testing.expect(mouse(.{ .button = .none, .action = .motion, .col = 4, .row = 1 }, modes, &buffer) == null);
    modes.mouse = .any;
    try std.testing.expectEqualStrings("\x1b[<35;5;2M", mouse(.{ .button = .none, .action = .motion, .col = 4, .row = 1 }, modes, &buffer).?);
    modes.mouse_encoding = .x10;
    try std.testing.expect(mouse(.{ .button = .left, .action = .press, .col = 300, .row = 1 }, modes, &buffer) == null);
    modes.mouse_encoding = .utf8;
    try std.testing.expectEqualStrings("\x1b[M \xc5\x8d\"", mouse(.{ .button = .left, .action = .press, .col = 300, .row = 1 }, modes, &buffer).?);
    try std.testing.expect(focus(true, modes) == null);
    modes.focus_events = true;
    try std.testing.expectEqualStrings("\x1b[O", focus(false, modes).?);
}
