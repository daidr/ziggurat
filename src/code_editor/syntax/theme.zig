//! Colors of code: editor surfaces, change and diagnostic colors, and how
//! each kind of token shows. Colors are opaque 0xRRGGBB; translucent tints
//! of the reference palette are pre-blended over the theme background.
const std = @import("std");
const syntax = @import("root.zig");

const TokenKind = syntax.TokenKind;

/// How a kind of token shows. A null color takes the theme's text color.
pub const TokenStyle = struct {
    color: ?u32 = null,
    italic: bool = false,
    bold: bool = false,
};

pub const Theme = struct {
    background: u32,
    text: u32,
    /// Gutter numbers; `active_line_number` for lines with a caret.
    line_number: u32,
    active_line_number: u32,
    /// Background of lines with a caret.
    active_line: u32,
    selection: u32,
    inactive_selection: u32,
    cursor: u32,
    /// Marks the brackets around the caret.
    matching_bracket: u32,
    /// Find matches, the current one, and other occurrences of the
    /// selected text.
    match: u32,
    current_match: u32,
    occurrence: u32,
    indent_guide: u32,
    active_indent_guide: u32,
    wrap_guide: u32,
    whitespace: u32,
    @"error": u32,
    warning: u32,
    info: u32,
    hint: u32,
    /// Changes: diff tints, gutter bars and changed words.
    added: u32,
    deleted: u32,
    modified: u32,
    tokens: [syntax.token_kinds]TokenStyle = @as([syntax.token_kinds]TokenStyle, @splat(.{})),

    /// The color a token of `kind` draws in.
    pub fn color(self: *const Theme, kind: TokenKind) u32 {
        return self.tokens[@backingInt(kind)].color orelse self.text;
    }
    pub fn style(self: *const Theme, kind: TokenKind) TokenStyle {
        var value = self.tokens[@backingInt(kind)];
        if (value.color == null) value.color = self.text;
        return value;
    }

    /// The default code theme over a background and text color: the light
    /// or dark token palette, with surface colors blended from the text.
    pub fn default(dark_appearance: bool, background: u32, text: u32, accent: u32) Theme {
        var theme: Theme = .{
            .background = background,
            .text = text,
            .line_number = blend(background, text, 0.5),
            .active_line_number = text,
            .active_line = blend(background, if (dark_appearance) 0xffffff else 0x000000, if (dark_appearance) 0.045 else 0.035),
            .selection = blend(background, accent, 0.3),
            .inactive_selection = blend(background, accent, 0.17),
            .cursor = accent,
            .matching_bracket = blend(background, if (dark_appearance) 0xffffff else 0x000000, if (dark_appearance) 0.35 else 0.3),
            .match = if (dark_appearance) blend(background, 0xffd23c, 0.22) else blend(background, 0xffc800, 0.3),
            .current_match = if (dark_appearance) blend(background, 0xffa028, 0.5) else blend(background, 0xff8c00, 0.45),
            .occurrence = blend(background, if (dark_appearance) 0xffffff else 0x000000, if (dark_appearance) 0.1 else 0.07),
            .indent_guide = blend(background, text, 0.15),
            .active_indent_guide = blend(background, text, 0.35),
            .wrap_guide = blend(background, text, 0.18),
            .whitespace = blend(background, text, 0.25),
            .@"error" = if (dark_appearance) 0xf85149 else 0xd1242f,
            .warning = if (dark_appearance) 0xd29922 else 0x9a6700,
            .info = if (dark_appearance) 0x58a6ff else 0x0969da,
            .hint = if (dark_appearance) 0x8b949e else 0x6e7781,
            .added = if (dark_appearance) 0x5ecc71 else 0x0dbe4e,
            .deleted = if (dark_appearance) 0xff6762 else 0xff2e3f,
            .modified = if (dark_appearance) 0x69b1ff else 0x009fff,
        };
        const palette = if (dark_appearance) dark_tokens else light_tokens;
        for (palette) |entry| theme.tokens[@backingInt(entry[0])].color = entry[1];
        theme.tokens[@backingInt(TokenKind.heading)].bold = true;
        theme.tokens[@backingInt(TokenKind.strong)].bold = true;
        theme.tokens[@backingInt(TokenKind.emphasis)].italic = true;
        return theme;
    }
    pub fn light() Theme {
        return default(false, 0xffffff, 0x1f2328, 0x0969da);
    }
    pub fn dark() Theme {
        return default(true, 0x0d1117, 0xe6edf3, 0x58a6ff);
    }
};

const Entry = struct { TokenKind, u32 };
const dark_tokens = [_]Entry{
    .{ .keyword, 0xff7b72 },   .{ .operator, 0xff7b72 }, .{ .type, 0xffa657 },     .{ .function, 0xd2a8ff },
    .{ .meta, 0xd2a8ff },      .{ .property, 0x79c0ff }, .{ .constant, 0x79c0ff }, .{ .number, 0x79c0ff },
    .{ .attribute, 0x79c0ff }, .{ .string, 0xa5d6ff },   .{ .escape, 0x79c0ff },   .{ .regexp, 0x7ee787 },
    .{ .tag, 0x7ee787 },       .{ .comment, 0x8b949e },  .{ .heading, 0x79c0ff },  .{ .link, 0xa5d6ff },
    .{ .code, 0xa5d6ff },      .{ .inserted, 0x7ee787 }, .{ .deleted, 0xffa198 },  .{ .invalid, 0xf85149 },
};
const light_tokens = [_]Entry{
    .{ .keyword, 0xcf222e },   .{ .operator, 0xcf222e }, .{ .type, 0x953800 },     .{ .function, 0x8250df },
    .{ .meta, 0x8250df },      .{ .property, 0x0550ae }, .{ .constant, 0x0550ae }, .{ .number, 0x0550ae },
    .{ .attribute, 0x0550ae }, .{ .string, 0x0a3069 },   .{ .escape, 0x0550ae },   .{ .regexp, 0x116329 },
    .{ .tag, 0x116329 },       .{ .comment, 0x6e7781 },  .{ .heading, 0x0550ae },  .{ .link, 0x0a3069 },
    .{ .code, 0x0a3069 },      .{ .inserted, 0x116329 }, .{ .deleted, 0x82071e },  .{ .invalid, 0xd1242f },
};

/// `over` at `alpha` composited onto `base`.
pub fn blend(base: u32, over: u32, alpha: f32) u32 {
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |shift| {
        const a: f32 = @floatFromInt(base >> shift & 0xff);
        const b: f32 = @floatFromInt(over >> shift & 0xff);
        const mixed: u32 = @intFromFloat(@round(a + (b - a) * std.math.clamp(alpha, 0, 1)));
        out |= mixed << shift;
    }
    return out;
}

test "themes color every kind and blend opaque tints" {
    const light = Theme.light();
    const dark = Theme.dark();
    try std.testing.expectEqual(@as(u32, 0xcf222e), light.color(.keyword));
    try std.testing.expectEqual(@as(u32, 0xff7b72), dark.color(.keyword));
    try std.testing.expectEqual(light.text, light.color(.variable));
    try std.testing.expect(light.style(.heading).bold);
    try std.testing.expect(dark.style(.emphasis).italic);
    try std.testing.expectEqual(@as(u32, 0x808080), blend(0x000000, 0xffffff, 0.502));
    try std.testing.expectEqual(@as(u32, 0x123456), blend(0x123456, 0xffffff, 0));
}
