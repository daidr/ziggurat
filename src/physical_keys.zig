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
    if (code >= 183 and code <= 194) return @enumFromInt(@intFromEnum(KeyCode.f13) + code - 183);
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
    if (scan >= 0x64 and scan <= 0x6e) return @enumFromInt(@intFromEnum(KeyCode.f13) + scan - 0x64);
    return if (scan == 0x76) .f24 else .unknown;
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
