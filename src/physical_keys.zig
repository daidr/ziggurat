//! Keys by position on the keyboard, whatever its layout: the key in W's
//! place on a US keyboard is `.w` on AZERTY too, as games want for WASD.
//! Linux evdev codes and the scan codes Windows reports share one numbering
//! for the main block (1 to 88); the navigation block differs.
const KeyCode = @import("root.zig").KeyCode;

/// Main block, by evdev code and scan code alike (index 0 is no key).
const main_block = [89]KeyCode{
    .unknown,    .escape,  .digit1,       .digit2,        .digit3,  .digit4,   .digit5,      .digit6,
    .digit7,     .digit8,  .digit9,       .digit0,        .minus,   .equal,    .backspace,   .tab,
    .q,          .w,       .e,            .r,             .t,       .y,        .u,           .i,
    .o,          .p,       .left_bracket, .right_bracket, .enter,   .control,  .a,           .s,
    .d,          .f,       .g,            .h,             .j,       .k,        .l,           .semicolon,
    .apostrophe, .grave,   .shift,        .backslash,     .z,       .x,        .c,           .v,
    .b,          .n,       .m,            .comma,         .period,  .slash,    .shift,       .multiply,
    .alt,        .space,   .caps_lock,    .f1,            .f2,      .f3,       .f4,          .f5,
    .f6,         .f7,      .f8,           .f9,            .f10,     .num_lock, .scroll_lock, .numpad7,
    .numpad8,    .numpad9, .subtract,     .numpad4,       .numpad5, .numpad6,  .add,         .numpad1,
    .numpad2,    .numpad3, .numpad0,      .decimal,       .unknown, .unknown,  .backslash,   .f11,
    .f12,
};

/// The key at Linux evdev code `code` (an X11 or Wayland hardware keycode
/// less 8).
pub fn fromEvdev(code: u32) KeyCode {
    if (code < main_block.len) return main_block[code];
    if (code >= 183 and code <= 194) return @fromBackingInt(@intCast(@backingInt(KeyCode.f13) + code - 183));
    return switch (code) {
        96 => .enter,
        97 => .control,
        98 => .divide,
        99 => .print_screen,
        100 => .alt,
        102 => .home,
        103 => .up,
        104 => .page_up,
        105 => .left,
        106 => .right,
        107 => .end,
        108 => .down,
        109 => .page_down,
        110 => .insert,
        111 => .delete,
        119 => .pause,
        125, 126 => .super,
        127 => .context_menu,
        else => .unknown,
    };
}

/// The key at Windows scan code `scan`, `extended` when the E0 prefix
/// came with it, as WM_KEYDOWN's lParam bits 16 to 24 give them.
pub fn fromScanCode(scan: u32, extended: bool) KeyCode {
    if (extended) return switch (scan) {
        0x1c => .enter,
        0x1d => .control,
        0x35 => .divide,
        0x37 => .print_screen,
        0x38 => .alt,
        // Windows reports Num Lock as the extended twin of Pause.
        0x45 => .num_lock,
        0x47 => .home,
        0x48 => .up,
        0x49 => .page_up,
        0x4b => .left,
        0x4d => .right,
        0x4f => .end,
        0x50 => .down,
        0x51 => .page_down,
        0x52 => .insert,
        0x53 => .delete,
        0x5b, 0x5c => .super,
        0x5d => .context_menu,
        else => .unknown,
    };
    if (scan == 0x45) return .pause;
    if (scan < main_block.len) return main_block[scan];
    if (scan >= 0x64 and scan <= 0x6e) return @fromBackingInt(@intCast(@backingInt(KeyCode.f13) + scan - 0x64));
    return if (scan == 0x76) .f24 else .unknown;
}

/// The key at macOS virtual key code `code`, as NSEvent's keyCode gives it
/// (the kVK_ constants of Carbon's Events.h, numbered by ANSI position).
pub fn fromMacVirtualKey(code: u32) KeyCode {
    const ansi = [_]KeyCode{
        .a,     .s,            .d,         .f,         .h,       .g,      .z,             .x,
        .c,     .v,            .unknown,   .b,         .q,       .w,      .e,             .r,
        .y,     .t,            .digit1,    .digit2,    .digit3,  .digit4, .digit6,        .digit5,
        .equal, .digit9,       .digit7,    .minus,     .digit8,  .digit0, .right_bracket, .o,
        .u,     .left_bracket, .i,         .p,         .enter,   .l,      .j,             .apostrophe,
        .k,     .semicolon,    .backslash, .comma,     .slash,   .n,      .m,             .period,
        .tab,   .space,        .grave,     .backspace, .unknown, .escape, .super,         .super,
        .shift, .caps_lock,    .alt,       .control,   .shift,   .alt,    .control,       .unknown,
    };
    if (code < ansi.len) return ansi[code];
    return switch (code) {
        0x40 => .f17,
        0x41 => .decimal,
        0x43 => .multiply,
        0x45 => .add,
        0x47 => .num_lock,
        0x48 => .volume_up,
        0x49 => .volume_down,
        0x4a => .volume_mute,
        0x4b => .divide,
        0x4c => .enter,
        0x4e => .subtract,
        0x4f => .f18,
        0x50 => .f19,
        0x52...0x59 => @fromBackingInt(@intCast(@backingInt(KeyCode.numpad0) + code - 0x52)),
        0x5a => .f20,
        0x5b => .numpad8,
        0x5c => .numpad9,
        0x60 => .f5,
        0x61 => .f6,
        0x62 => .f7,
        0x63 => .f3,
        0x64 => .f8,
        0x65 => .f9,
        0x67 => .f11,
        0x69 => .f13,
        0x6a => .f16,
        0x6b => .f14,
        0x6d => .f10,
        0x6e => .context_menu,
        0x6f => .f12,
        0x71 => .f15,
        0x72 => .insert,
        0x73 => .home,
        0x74 => .page_up,
        0x75 => .delete,
        0x76 => .f4,
        0x77 => .end,
        0x78 => .f2,
        0x79 => .page_down,
        0x7a => .f1,
        0x7b => .left,
        0x7c => .right,
        0x7d => .down,
        0x7e => .up,
        else => .unknown,
    };
}

const std = @import("std");

test "letters keep their place across layouts" {
    try std.testing.expectEqual(KeyCode.w, fromEvdev(17));
    try std.testing.expectEqual(KeyCode.a, fromEvdev(30));
    try std.testing.expectEqual(KeyCode.s, fromScanCode(0x1f, false));
    try std.testing.expectEqual(KeyCode.d, fromScanCode(0x20, false));
    try std.testing.expectEqual(KeyCode.space, fromScanCode(0x39, false));
}

test "navigation keys need the extended flag or their evdev codes" {
    try std.testing.expectEqual(KeyCode.up, fromScanCode(0x48, true));
    try std.testing.expectEqual(KeyCode.numpad8, fromScanCode(0x48, false));
    try std.testing.expectEqual(KeyCode.up, fromEvdev(103));
    try std.testing.expectEqual(KeyCode.numpad8, fromEvdev(72));
    try std.testing.expectEqual(KeyCode.num_lock, fromScanCode(0x45, true));
    try std.testing.expectEqual(KeyCode.pause, fromScanCode(0x45, false));
    try std.testing.expectEqual(KeyCode.f13, fromEvdev(183));
    try std.testing.expectEqual(KeyCode.f24, fromScanCode(0x76, false));
    try std.testing.expectEqual(KeyCode.unknown, fromEvdev(500));
}

test "macOS virtual keys follow ANSI positions" {
    try std.testing.expectEqual(KeyCode.w, fromMacVirtualKey(0x0d));
    try std.testing.expectEqual(KeyCode.a, fromMacVirtualKey(0x00));
    try std.testing.expectEqual(KeyCode.digit5, fromMacVirtualKey(0x17));
    try std.testing.expectEqual(KeyCode.numpad7, fromMacVirtualKey(0x59));
    try std.testing.expectEqual(KeyCode.up, fromMacVirtualKey(0x7e));
    try std.testing.expectEqual(KeyCode.unknown, fromMacVirtualKey(500));
}

/// The key at a browser's `KeyboardEvent.code`, which names positions by
/// what they type on a US keyboard ("KeyW", "Digit1", "ArrowLeft").
pub fn fromDomCode(code: []const u8) KeyCode {
    if (code.len == 4 and std.mem.startsWith(u8, code, "Key") and code[3] >= 'A' and code[3] <= 'Z')
        return @fromBackingInt(@intCast(@backingInt(KeyCode.a) + code[3] - 'A'));
    if (code.len == 6 and std.mem.startsWith(u8, code, "Digit") and code[5] >= '0' and code[5] <= '9')
        return @fromBackingInt(@intCast(@backingInt(KeyCode.digit0) + code[5] - '0'));
    if (code.len == 7 and std.mem.startsWith(u8, code, "Numpad") and code[6] >= '0' and code[6] <= '9')
        return @fromBackingInt(@intCast(@backingInt(KeyCode.numpad0) + code[6] - '0'));
    if (code.len >= 2 and code.len <= 3 and code[0] == 'F') {
        const number = std.fmt.parseInt(u8, code[1..], 10) catch return .unknown;
        if (number >= 1 and number <= 24) return @fromBackingInt(@intCast(@backingInt(KeyCode.f1) + number - 1));
        return .unknown;
    }
    const table = [_]struct { []const u8, KeyCode }{
        .{ "Tab", .tab },                     .{ "Enter", .enter },                    .{ "NumpadEnter", .enter },
        .{ "Space", .space },                 .{ "Escape", .escape },                  .{ "ArrowLeft", .left },
        .{ "ArrowRight", .right },            .{ "ArrowUp", .up },                     .{ "ArrowDown", .down },
        .{ "Home", .home },                   .{ "End", .end },                        .{ "PageUp", .page_up },
        .{ "PageDown", .page_down },          .{ "Insert", .insert },                  .{ "Delete", .delete },
        .{ "Backspace", .backspace },         .{ "CapsLock", .caps_lock },             .{ "NumLock", .num_lock },
        .{ "ScrollLock", .scroll_lock },      .{ "PrintScreen", .print_screen },       .{ "Pause", .pause },
        .{ "ShiftLeft", .shift },             .{ "ShiftRight", .shift },               .{ "ControlLeft", .control },
        .{ "ControlRight", .control },        .{ "AltLeft", .alt },                    .{ "AltRight", .alt },
        .{ "MetaLeft", .super },              .{ "MetaRight", .super },                .{ "ContextMenu", .context_menu },
        .{ "Minus", .minus },                 .{ "Equal", .equal },                    .{ "BracketLeft", .left_bracket },
        .{ "BracketRight", .right_bracket },  .{ "Backslash", .backslash },            .{ "IntlBackslash", .backslash },
        .{ "Semicolon", .semicolon },         .{ "Quote", .apostrophe },               .{ "Backquote", .grave },
        .{ "Comma", .comma },                 .{ "Period", .period },                  .{ "Slash", .slash },
        .{ "NumpadDecimal", .decimal },       .{ "NumpadAdd", .add },                  .{ "NumpadSubtract", .subtract },
        .{ "NumpadMultiply", .multiply },     .{ "NumpadDivide", .divide },            .{ "MediaPlayPause", .media_play_pause },
        .{ "MediaStop", .media_stop },        .{ "MediaTrackNext", .media_next },      .{ "MediaTrackPrevious", .media_previous },
        .{ "AudioVolumeMute", .volume_mute }, .{ "AudioVolumeDown", .volume_down },    .{ "AudioVolumeUp", .volume_up },
        .{ "BrowserBack", .browser_back },    .{ "BrowserForward", .browser_forward }, .{ "BrowserRefresh", .browser_refresh },
        .{ "BrowserStop", .browser_stop },    .{ "BrowserSearch", .browser_search },   .{ "BrowserFavorites", .browser_favorites },
        .{ "BrowserHome", .browser_home },
    };
    for (table) |entry| if (std.mem.eql(u8, entry[0], code)) return entry[1];
    return .unknown;
}

/// The key of a browser's `KeyboardEvent`: letters, digits and punctuation
/// by the character the layout gives them (`key`), as the desktop backends
/// name them, and every other key by its position (`code`), keypad keys
/// included.
pub fn fromDomKey(key: []const u8, code: []const u8) KeyCode {
    const keypad = std.mem.startsWith(u8, code, "Numpad");
    if (key.len == 1 and !keypad) {
        const c = std.ascii.toLower(key[0]);
        if (c >= 'a' and c <= 'z') return @fromBackingInt(@intCast(@backingInt(KeyCode.a) + c - 'a'));
        if (c >= '0' and c <= '9') return @fromBackingInt(@intCast(@backingInt(KeyCode.digit0) + c - '0'));
        switch (c) {
            '-' => return .minus,
            '=' => return .equal,
            '[' => return .left_bracket,
            ']' => return .right_bracket,
            '\\' => return .backslash,
            ';' => return .semicolon,
            '\'' => return .apostrophe,
            '`' => return .grave,
            ',' => return .comma,
            '.' => return .period,
            '/' => return .slash,
            ' ' => return .space,
            else => {},
        }
    }
    return fromDomCode(code);
}

test "browser keys are named by the layout's characters and by position" {
    const testing = std.testing;
    try testing.expectEqual(KeyCode.w, fromDomCode("KeyW"));
    try testing.expectEqual(KeyCode.digit7, fromDomCode("Digit7"));
    try testing.expectEqual(KeyCode.numpad3, fromDomCode("Numpad3"));
    try testing.expectEqual(KeyCode.f12, fromDomCode("F12"));
    try testing.expectEqual(KeyCode.left, fromDomCode("ArrowLeft"));
    // AZERTY: the key in Q's place types "a".
    try testing.expectEqual(KeyCode.a, fromDomKey("a", "KeyQ"));
    try testing.expectEqual(KeyCode.a, fromDomKey("A", "KeyA"));
    try testing.expectEqual(KeyCode.numpad1, fromDomKey("1", "Numpad1"));
    try testing.expectEqual(KeyCode.escape, fromDomKey("Escape", "Escape"));
    // A character outside ASCII names the key by its position.
    try testing.expectEqual(KeyCode.digit2, fromDomKey("é", "Digit2"));
}
