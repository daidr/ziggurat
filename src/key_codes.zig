//! Keys by their position on any keyboard, with the sides of the
//! modifiers told apart and every key of a full keyboard, those that
//! `KeyCode` has no name for too (`KeyInput.code`). The values are USB HID
//! usage IDs of the keyboard page (0x07) and the names those of UI Events'
//! `KeyboardEvent.code`, with Super for Meta, so that one table turns them
//! into another system's scan codes. The tables of each backend live here,
//! so that they are tested on any system.
const std = @import("std");

pub const Code = enum(u16) {
    unknown = 0,
    key_a = 0x04,
    key_b,
    key_c,
    key_d,
    key_e,
    key_f,
    key_g,
    key_h,
    key_i,
    key_j,
    key_k,
    key_l,
    key_m,
    key_n,
    key_o,
    key_p,
    key_q,
    key_r,
    key_s,
    key_t,
    key_u,
    key_v,
    key_w,
    key_x,
    key_y,
    key_z,
    digit1,
    digit2,
    digit3,
    digit4,
    digit5,
    digit6,
    digit7,
    digit8,
    digit9,
    digit0,
    enter,
    escape,
    backspace,
    tab,
    space,
    minus,
    equal,
    bracket_left,
    bracket_right,
    backslash,
    semicolon = 0x33,
    quote,
    backquote,
    comma,
    period,
    slash,
    caps_lock,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    print_screen,
    scroll_lock,
    pause,
    insert,
    home,
    page_up,
    delete,
    end,
    page_down,
    arrow_right,
    arrow_left,
    arrow_down,
    arrow_up,
    num_lock,
    numpad_divide,
    numpad_multiply,
    numpad_subtract,
    numpad_add,
    numpad_enter,
    numpad1,
    numpad2,
    numpad3,
    numpad4,
    numpad5,
    numpad6,
    numpad7,
    numpad8,
    numpad9,
    numpad0,
    numpad_decimal,
    intl_backslash,
    context_menu,
    power,
    numpad_equal,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    audio_volume_mute = 0x7f,
    audio_volume_up,
    audio_volume_down,
    numpad_comma = 0x85,
    intl_ro = 0x87,
    kana_mode = 0x88,
    intl_yen = 0x89,
    convert = 0x8a,
    non_convert = 0x8b,
    lang1 = 0x90,
    lang2 = 0x91,
    lang3 = 0x92,
    lang4 = 0x93,
    control_left = 0xe0,
    shift_left,
    alt_left,
    super_left,
    control_right,
    shift_right,
    alt_right,
    super_right,
    _,

    fn plus(base: Code, offset: anytype) Code {
        return @fromBackingInt(@intCast(@backingInt(base) + @as(u16, @intCast(offset))));
    }

    /// Whether the key is a modifier, of either side.
    pub fn modifier(self: Code) bool {
        return @backingInt(self) >= @backingInt(Code.control_left) and @backingInt(self) <= @backingInt(Code.super_right);
    }
    /// Whether the key turns a lock on and off.
    pub fn lock(self: Code) bool {
        return self == .caps_lock or self == .num_lock or self == .scroll_lock;
    }
    /// The key's name in `KeyboardEvent.code`, "" for one of no name.
    pub fn domName(self: Code) []const u8 {
        for (dom_names) |entry| if (entry.code == self) return entry.name;
        return "";
    }
};

/// The scan codes that XT set 1, which Windows reports, and Linux's evdev
/// share: an AT keyboard's main block, its function keys and its keypad,
/// up to F12.
const xt_codes = blk: {
    var table: [0x59]Code = @splat(.unknown);
    const pairs = [_]struct { u8, Code }{
        .{ 0x01, .escape },       .{ 0x02, .digit1 },          .{ 0x03, .digit2 },          .{ 0x04, .digit3 },
        .{ 0x05, .digit4 },       .{ 0x06, .digit5 },          .{ 0x07, .digit6 },          .{ 0x08, .digit7 },
        .{ 0x09, .digit8 },       .{ 0x0a, .digit9 },          .{ 0x0b, .digit0 },          .{ 0x0c, .minus },
        .{ 0x0d, .equal },        .{ 0x0e, .backspace },       .{ 0x0f, .tab },             .{ 0x10, .key_q },
        .{ 0x11, .key_w },        .{ 0x12, .key_e },           .{ 0x13, .key_r },           .{ 0x14, .key_t },
        .{ 0x15, .key_y },        .{ 0x16, .key_u },           .{ 0x17, .key_i },           .{ 0x18, .key_o },
        .{ 0x19, .key_p },        .{ 0x1a, .bracket_left },    .{ 0x1b, .bracket_right },   .{ 0x1c, .enter },
        .{ 0x1d, .control_left }, .{ 0x1e, .key_a },           .{ 0x1f, .key_s },           .{ 0x20, .key_d },
        .{ 0x21, .key_f },        .{ 0x22, .key_g },           .{ 0x23, .key_h },           .{ 0x24, .key_j },
        .{ 0x25, .key_k },        .{ 0x26, .key_l },           .{ 0x27, .semicolon },       .{ 0x28, .quote },
        .{ 0x29, .backquote },    .{ 0x2a, .shift_left },      .{ 0x2b, .backslash },       .{ 0x2c, .key_z },
        .{ 0x2d, .key_x },        .{ 0x2e, .key_c },           .{ 0x2f, .key_v },           .{ 0x30, .key_b },
        .{ 0x31, .key_n },        .{ 0x32, .key_m },           .{ 0x33, .comma },           .{ 0x34, .period },
        .{ 0x35, .slash },        .{ 0x36, .shift_right },     .{ 0x37, .numpad_multiply }, .{ 0x38, .alt_left },
        .{ 0x39, .space },        .{ 0x3a, .caps_lock },       .{ 0x3b, .f1 },              .{ 0x3c, .f2 },
        .{ 0x3d, .f3 },           .{ 0x3e, .f4 },              .{ 0x3f, .f5 },              .{ 0x40, .f6 },
        .{ 0x41, .f7 },           .{ 0x42, .f8 },              .{ 0x43, .f9 },              .{ 0x44, .f10 },
        .{ 0x45, .num_lock },     .{ 0x46, .scroll_lock },     .{ 0x47, .numpad7 },         .{ 0x48, .numpad8 },
        .{ 0x49, .numpad9 },      .{ 0x4a, .numpad_subtract }, .{ 0x4b, .numpad4 },         .{ 0x4c, .numpad5 },
        .{ 0x4d, .numpad6 },      .{ 0x4e, .numpad_add },      .{ 0x4f, .numpad1 },         .{ 0x50, .numpad2 },
        .{ 0x51, .numpad3 },      .{ 0x52, .numpad0 },         .{ 0x53, .numpad_decimal },  .{ 0x56, .intl_backslash },
        .{ 0x57, .f11 },          .{ 0x58, .f12 },
    };
    for (pairs) |pair| table[pair[0]] = pair[1];
    break :blk table;
};

/// The key of a Linux evdev code (KEY_*; an X11 or GDK hardware keycode
/// less 8), `.unknown` for one not mapped.
pub fn fromEvdev(code: u32) Code {
    if (code < xt_codes.len) return xt_codes[code];
    if (code >= 183 and code <= 194) return Code.f13.plus(code - 183);
    return switch (code) {
        89 => .intl_ro,
        90 => .lang3, // Katakana
        91 => .lang4, // Hiragana
        92 => .convert,
        93 => .kana_mode,
        94 => .non_convert,
        95, 121 => .numpad_comma,
        96 => .numpad_enter,
        97 => .control_right,
        98 => .numpad_divide,
        99 => .print_screen,
        100 => .alt_right,
        102 => .home,
        103 => .arrow_up,
        104 => .page_up,
        105 => .arrow_left,
        106 => .arrow_right,
        107 => .end,
        108 => .arrow_down,
        109 => .page_down,
        110 => .insert,
        111 => .delete,
        113 => .audio_volume_mute,
        114 => .audio_volume_down,
        115 => .audio_volume_up,
        116 => .power,
        117 => .numpad_equal,
        119 => .pause,
        122 => .lang1, // Hangul
        123 => .lang2, // Hanja
        124 => .intl_yen,
        125 => .super_left,
        126 => .super_right,
        127 => .context_menu,
        else => .unknown,
    };
}

/// The evdev code of a modifier's other side (Shift's left for its
/// right), null for a key that is no modifier.
pub fn evdevTwin(code: u32) ?u32 {
    return switch (code) {
        42 => 54,
        54 => 42,
        29 => 97,
        97 => 29,
        56 => 100,
        100 => 56,
        125 => 126,
        126 => 125,
        else => null,
    };
}

/// The key of an XT set 1 scan code as Windows reports it in a key
/// message's lParam, `extended` being its bit 24, `.unknown` for one not
/// mapped. Windows's own quirks are in it: Num Lock is the extended 0x45
/// and Pause the plain one, Alt+Print Screen and Ctrl+Pause have codes of
/// their own, and CJK input methods set the extended bit of the right
/// Shift.
pub fn fromXt(scan: u8, extended: bool) Code {
    if (extended) return switch (scan) {
        0x1c => .numpad_enter,
        0x1d => .control_right,
        0x35 => .numpad_divide,
        0x36 => .shift_right,
        0x37 => .print_screen,
        0x38 => .alt_right,
        0x45 => .num_lock,
        0x46 => .pause,
        0x47 => .home,
        0x48 => .arrow_up,
        0x49 => .page_up,
        0x4b => .arrow_left,
        0x4d => .arrow_right,
        0x4f => .end,
        0x50 => .arrow_down,
        0x51 => .page_down,
        0x52 => .insert,
        0x53 => .delete,
        0x5b => .super_left,
        0x5c => .super_right,
        0x5d => .context_menu,
        0x5e => .power,
        else => .unknown,
    };
    return switch (scan) {
        0x45 => .pause,
        0x54 => .print_screen,
        0x59 => .numpad_equal,
        0x70 => .kana_mode,
        0x73 => .intl_ro,
        0x76 => .f24,
        0x79 => .convert,
        0x7b => .non_convert,
        0x7d => .intl_yen,
        0x7e => .numpad_comma,
        0x71 => .lang2, // Hanja
        0x72 => .lang1, // Hangul
        0x77 => .lang4, // Hiragana
        0x78 => .lang3, // Katakana
        0x64...0x6e => Code.f13.plus(scan - 0x64),
        else => if (scan < xt_codes.len) xt_codes[scan] else .unknown,
    };
}

/// macOS's virtual key codes (Carbon's kVK_*). A keyboard of ISO's layout
/// swaps the codes of its section and grave keys, which the backend,
/// knowing the keyboard, undoes.
const mac_codes = blk: {
    var table: [0x7f]Code = @splat(.unknown);
    const pairs = [_]struct { u8, Code }{
        .{ 0x00, .key_a },             .{ 0x01, .key_s },             .{ 0x02, .key_d },          .{ 0x03, .key_f },
        .{ 0x04, .key_h },             .{ 0x05, .key_g },             .{ 0x06, .key_z },          .{ 0x07, .key_x },
        .{ 0x08, .key_c },             .{ 0x09, .key_v },             .{ 0x0a, .intl_backslash }, .{ 0x0b, .key_b },
        .{ 0x0c, .key_q },             .{ 0x0d, .key_w },             .{ 0x0e, .key_e },          .{ 0x0f, .key_r },
        .{ 0x10, .key_y },             .{ 0x11, .key_t },             .{ 0x12, .digit1 },         .{ 0x13, .digit2 },
        .{ 0x14, .digit3 },            .{ 0x15, .digit4 },            .{ 0x16, .digit6 },         .{ 0x17, .digit5 },
        .{ 0x18, .equal },             .{ 0x19, .digit9 },            .{ 0x1a, .digit7 },         .{ 0x1b, .minus },
        .{ 0x1c, .digit8 },            .{ 0x1d, .digit0 },            .{ 0x1e, .bracket_right },  .{ 0x1f, .key_o },
        .{ 0x20, .key_u },             .{ 0x21, .bracket_left },      .{ 0x22, .key_i },          .{ 0x23, .key_p },
        .{ 0x24, .enter },             .{ 0x25, .key_l },             .{ 0x26, .key_j },          .{ 0x27, .quote },
        .{ 0x28, .key_k },             .{ 0x29, .semicolon },         .{ 0x2a, .backslash },      .{ 0x2b, .comma },
        .{ 0x2c, .slash },             .{ 0x2d, .key_n },             .{ 0x2e, .key_m },          .{ 0x2f, .period },
        .{ 0x30, .tab },               .{ 0x31, .space },             .{ 0x32, .backquote },      .{ 0x33, .backspace },
        .{ 0x35, .escape },            .{ 0x36, .super_right },       .{ 0x37, .super_left },     .{ 0x38, .shift_left },
        .{ 0x39, .caps_lock },         .{ 0x3a, .alt_left },          .{ 0x3b, .control_left },   .{ 0x3c, .shift_right },
        .{ 0x3d, .alt_right },         .{ 0x3e, .control_right },     .{ 0x40, .f17 },            .{ 0x41, .numpad_decimal },
        .{ 0x43, .numpad_multiply },   .{ 0x45, .numpad_add },        .{ 0x47, .num_lock },       .{ 0x48, .audio_volume_up },
        .{ 0x49, .audio_volume_down }, .{ 0x4a, .audio_volume_mute }, .{ 0x4b, .numpad_divide },  .{ 0x4c, .numpad_enter },
        .{ 0x4e, .numpad_subtract },   .{ 0x4f, .f18 },               .{ 0x50, .f19 },            .{ 0x51, .numpad_equal },
        .{ 0x52, .numpad0 },           .{ 0x53, .numpad1 },           .{ 0x54, .numpad2 },        .{ 0x55, .numpad3 },
        .{ 0x56, .numpad4 },           .{ 0x57, .numpad5 },           .{ 0x58, .numpad6 },        .{ 0x59, .numpad7 },
        .{ 0x5a, .f20 },               .{ 0x5b, .numpad8 },           .{ 0x5c, .numpad9 },        .{ 0x5d, .intl_yen },
        .{ 0x5e, .intl_ro },           .{ 0x5f, .numpad_comma },      .{ 0x60, .f5 },             .{ 0x61, .f6 },
        .{ 0x62, .f7 },                .{ 0x63, .f3 },                .{ 0x64, .f8 },             .{ 0x65, .f9 },
        .{ 0x66, .lang2 },             .{ 0x67, .f11 },               .{ 0x68, .lang1 },          .{ 0x69, .f13 },
        .{ 0x6a, .f16 },               .{ 0x6b, .f14 },               .{ 0x6d, .f10 },            .{ 0x6e, .context_menu },
        .{ 0x6f, .f12 },               .{ 0x71, .f15 },               .{ 0x72, .insert },         .{ 0x73, .home },
        .{ 0x74, .page_up },           .{ 0x75, .delete },            .{ 0x76, .f4 },             .{ 0x77, .end },
        .{ 0x78, .f2 },                .{ 0x79, .page_down },         .{ 0x7a, .f1 },             .{ 0x7b, .arrow_left },
        .{ 0x7c, .arrow_right },       .{ 0x7d, .arrow_down },        .{ 0x7e, .arrow_up },
    };
    for (pairs) |pair| table[pair[0]] = pair[1];
    break :blk table;
};

/// The key of a macOS virtual key code, `.unknown` for one not mapped, as
/// Fn.
pub fn fromMac(code: u32) Code {
    return if (code < mac_codes.len) mac_codes[code] else .unknown;
}

pub const FlagsChange = struct { code: Code, down: bool };
/// The key of a `flagsChanged:` event of virtual key code `key_code` and
/// NSEvent modifierFlags `flags`, and whether it pressed that key rather
/// than let go of it; null for one of no modifier (AppKit sends some with
/// other codes) and for Fn, which has no code. The flags' device-dependent
/// bits tell the sides; where the left and right bits are both clear while
/// the side-independent bit is set, as in events another program made, it
/// counts as pressed. Caps Lock counts as pressed: macOS tells of it once
/// for each change of the lock, and the backend gives it a release at once.
pub fn macFlagsChanged(key_code: u32, flags: u64) ?FlagsChange {
    const shift: u64 = 1 << 17;
    const control: u64 = 1 << 18;
    const option: u64 = 1 << 19;
    const command: u64 = 1 << 20;
    const code = fromMac(key_code);
    const own: u64, const other: u64, const class: u64 = switch (code) {
        .caps_lock => return .{ .code = code, .down = true },
        .control_left => .{ 0x0001, 0x2000, control },
        .control_right => .{ 0x2000, 0x0001, control },
        .shift_left => .{ 0x0002, 0x0004, shift },
        .shift_right => .{ 0x0004, 0x0002, shift },
        .super_left => .{ 0x0008, 0x0010, command },
        .super_right => .{ 0x0010, 0x0008, command },
        .alt_left => .{ 0x0020, 0x0040, option },
        .alt_right => .{ 0x0040, 0x0020, option },
        else => return null,
    };
    return .{ .code = code, .down = flags & own != 0 or (flags & other == 0 and flags & class != 0) };
}

const Named = struct { name: []const u8, code: Code };
/// The named codes of `KeyboardEvent` that are no letter, digit or
/// function key.
const dom_names = [_]Named{
    .{ .name = "Enter", .code = .enter },                    .{ .name = "Escape", .code = .escape },
    .{ .name = "Backspace", .code = .backspace },            .{ .name = "Tab", .code = .tab },
    .{ .name = "Space", .code = .space },                    .{ .name = "Minus", .code = .minus },
    .{ .name = "Equal", .code = .equal },                    .{ .name = "BracketLeft", .code = .bracket_left },
    .{ .name = "BracketRight", .code = .bracket_right },     .{ .name = "Backslash", .code = .backslash },
    .{ .name = "Semicolon", .code = .semicolon },            .{ .name = "Quote", .code = .quote },
    .{ .name = "Backquote", .code = .backquote },            .{ .name = "Comma", .code = .comma },
    .{ .name = "Period", .code = .period },                  .{ .name = "Slash", .code = .slash },
    .{ .name = "CapsLock", .code = .caps_lock },             .{ .name = "PrintScreen", .code = .print_screen },
    .{ .name = "ScrollLock", .code = .scroll_lock },         .{ .name = "Pause", .code = .pause },
    .{ .name = "Insert", .code = .insert },                  .{ .name = "Home", .code = .home },
    .{ .name = "PageUp", .code = .page_up },                 .{ .name = "Delete", .code = .delete },
    .{ .name = "End", .code = .end },                        .{ .name = "PageDown", .code = .page_down },
    .{ .name = "ArrowRight", .code = .arrow_right },         .{ .name = "ArrowLeft", .code = .arrow_left },
    .{ .name = "ArrowDown", .code = .arrow_down },           .{ .name = "ArrowUp", .code = .arrow_up },
    .{ .name = "NumLock", .code = .num_lock },               .{ .name = "NumpadDivide", .code = .numpad_divide },
    .{ .name = "NumpadMultiply", .code = .numpad_multiply }, .{ .name = "NumpadSubtract", .code = .numpad_subtract },
    .{ .name = "NumpadAdd", .code = .numpad_add },           .{ .name = "NumpadEnter", .code = .numpad_enter },
    .{ .name = "NumpadDecimal", .code = .numpad_decimal },   .{ .name = "NumpadEqual", .code = .numpad_equal },
    .{ .name = "NumpadComma", .code = .numpad_comma },       .{ .name = "IntlBackslash", .code = .intl_backslash },
    .{ .name = "IntlRo", .code = .intl_ro },                 .{ .name = "IntlYen", .code = .intl_yen },
    .{ .name = "KanaMode", .code = .kana_mode },             .{ .name = "Convert", .code = .convert },
    .{ .name = "NonConvert", .code = .non_convert },         .{ .name = "Lang1", .code = .lang1 },
    .{ .name = "Lang2", .code = .lang2 },                    .{ .name = "Lang3", .code = .lang3 },
    .{ .name = "Lang4", .code = .lang4 },                    .{ .name = "ContextMenu", .code = .context_menu },
    .{ .name = "Power", .code = .power },                    .{ .name = "AudioVolumeMute", .code = .audio_volume_mute },
    .{ .name = "AudioVolumeUp", .code = .audio_volume_up },  .{ .name = "AudioVolumeDown", .code = .audio_volume_down },
    .{ .name = "ControlLeft", .code = .control_left },       .{ .name = "ShiftLeft", .code = .shift_left },
    .{ .name = "AltLeft", .code = .alt_left },               .{ .name = "MetaLeft", .code = .super_left },
    .{ .name = "ControlRight", .code = .control_right },     .{ .name = "ShiftRight", .code = .shift_right },
    .{ .name = "AltRight", .code = .alt_right },             .{ .name = "MetaRight", .code = .super_right },
    // Older names of the same keys, which some browsers still give.
    .{ .name = "OSLeft", .code = .super_left },              .{ .name = "OSRight", .code = .super_right },
};

/// The key of a `KeyboardEvent.code`, `.unknown` for one not mapped.
pub fn fromDom(code: []const u8) Code {
    if (code.len == 4 and std.mem.startsWith(u8, code, "Key") and code[3] >= 'A' and code[3] <= 'Z') return Code.key_a.plus(code[3] - 'A');
    if (code.len == 6 and std.mem.startsWith(u8, code, "Digit") and code[5] >= '1' and code[5] <= '9') return Code.digit1.plus(code[5] - '1');
    if (std.mem.eql(u8, code, "Digit0")) return .digit0;
    if (code.len == 7 and std.mem.startsWith(u8, code, "Numpad") and code[6] >= '1' and code[6] <= '9') return Code.numpad1.plus(code[6] - '1');
    if (std.mem.eql(u8, code, "Numpad0")) return .numpad0;
    if (code.len >= 2 and code.len <= 3 and code[0] == 'F') {
        const n = std.fmt.parseUnsigned(u8, code[1..], 10) catch 0;
        if (n >= 1 and n <= 12) return Code.f1.plus(n - 1);
        if (n >= 13 and n <= 24) return Code.f13.plus(n - 13);
    }
    for (dom_names) |entry| if (std.mem.eql(u8, entry.name, code)) return entry.code;
    return .unknown;
}

test "codes are the HID usages of the keyboard page" {
    try std.testing.expectEqual(@as(u16, 0x04), @backingInt(Code.key_a));
    try std.testing.expectEqual(@as(u16, 0x1d), @backingInt(Code.key_z));
    try std.testing.expectEqual(@as(u16, 0x27), @backingInt(Code.digit0));
    try std.testing.expectEqual(@as(u16, 0x31), @backingInt(Code.backslash));
    try std.testing.expectEqual(@as(u16, 0x45), @backingInt(Code.f12));
    try std.testing.expectEqual(@as(u16, 0x64), @backingInt(Code.intl_backslash));
    try std.testing.expectEqual(@as(u16, 0x73), @backingInt(Code.f24));
    try std.testing.expectEqual(@as(u16, 0xe7), @backingInt(Code.super_right));
}

test "every backend's table tells the sides of the modifiers" {
    try std.testing.expectEqual(Code.shift_left, fromEvdev(42));
    try std.testing.expectEqual(Code.shift_right, fromEvdev(54));
    try std.testing.expectEqual(Code.alt_right, fromEvdev(100));
    try std.testing.expectEqual(Code.super_left, fromEvdev(125));
    try std.testing.expectEqual(Code.intl_backslash, fromEvdev(86));
    try std.testing.expectEqual(Code.f13, fromEvdev(183));
    try std.testing.expectEqual(Code.control_right, fromXt(0x1d, true));
    try std.testing.expectEqual(Code.control_left, fromXt(0x1d, false));
    try std.testing.expectEqual(Code.num_lock, fromXt(0x45, true));
    try std.testing.expectEqual(Code.pause, fromXt(0x45, false));
    try std.testing.expectEqual(Code.numpad_enter, fromXt(0x1c, true));
    try std.testing.expectEqual(Code.f13, fromXt(0x64, false));
    try std.testing.expectEqual(Code.super_right, fromMac(0x36));
    try std.testing.expectEqual(Code.arrow_up, fromMac(0x7e));
    try std.testing.expectEqual(Code.unknown, fromMac(0x3f)); // Fn
    try std.testing.expectEqual(Code.key_q, fromDom("KeyQ"));
    try std.testing.expectEqual(Code.digit0, fromDom("Digit0"));
    try std.testing.expectEqual(Code.numpad5, fromDom("Numpad5"));
    try std.testing.expectEqual(Code.f19, fromDom("F19"));
    try std.testing.expectEqual(Code.super_left, fromDom("MetaLeft"));
    try std.testing.expectEqual(Code.super_right, fromDom("OSRight"));
    try std.testing.expectEqual(Code.unknown, fromDom("F25"));
    try std.testing.expectEqualStrings("ShiftLeft", Code.shift_left.domName());
}

test "macOS flags tell which side went down or up" {
    const left_shift: u64 = (1 << 17) | 0x0002;
    try std.testing.expectEqual(FlagsChange{ .code = .shift_left, .down = true }, macFlagsChanged(0x38, left_shift).?);
    // The right one goes down while the left is held.
    try std.testing.expectEqual(FlagsChange{ .code = .shift_right, .down = true }, macFlagsChanged(0x3c, left_shift | 0x0004).?);
    // Letting go of the left one while the right is held.
    try std.testing.expectEqual(FlagsChange{ .code = .shift_left, .down = false }, macFlagsChanged(0x38, (1 << 17) | 0x0004).?);
    // A made-up event with only the class bit counts as pressed.
    try std.testing.expectEqual(FlagsChange{ .code = .alt_left, .down = true }, macFlagsChanged(0x3a, 1 << 19).?);
    try std.testing.expectEqual(FlagsChange{ .code = .caps_lock, .down = true }, macFlagsChanged(0x39, 0).?);
    try std.testing.expect(macFlagsChanged(0x00, 0) == null);
}
