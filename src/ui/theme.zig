const std = @import("std");
const zio = @import("ziggurat_io");
const ScrollbarStyle = @import("scroll.zig").Style;
const Font = @import("commands.zig").Font;

/// The color `t` of the way from `a` to `b` (0xRRGGBB), rounded.
fn mix(a: u32, b: u32, t: f32) u32 {
    var out: u32 = 0;
    inline for (.{ @as(u5, 16), @as(u5, 8), @as(u5, 0) }) |shift| {
        const x: f32 = @floatFromInt(a >> shift & 0xff);
        const y: f32 = @floatFromInt(b >> shift & 0xff);
        const value: u32 = @intFromFloat(@round(x * (1 - t) + y * t));
        out |= @as(u32, @min(value, 255)) << shift;
    }
    return out;
}
/// The luminance of 0xRRGGBB, from 0 to 255.
fn gray(color: u32) u32 {
    const r: f32 = @floatFromInt(color >> 16 & 0xff);
    const g: f32 = @floatFromInt(color >> 8 & 0xff);
    const b: f32 = @floatFromInt(color & 0xff);
    return @intFromFloat(0.2126 * r + 0.7152 * g + 0.0722 * b + 0.5);
}
/// 0xAARRGGBB with its alpha 1.6 times stronger; an alpha of 0 is opaque.
fn stronger(color: u32) u32 {
    const alpha = color >> 24;
    if (alpha == 0) return color;
    const value: u32 = @intFromFloat(@min(255, @round(@as(f32, @floatFromInt(alpha)) * 1.6)));
    return value << 24 | (color & 0xffffff);
}

/// Opaque RGB colors. Alpha drawing remains an explicit drawing operation.
pub const Palette = struct {
    background: u32 = 0xffffff,
    control: u32 = 0xeeeeee,
    pressed: u32 = 0xc7d8ea,
    field: u32 = 0xf4f6f8,
    inset: u32 = 0xffffff,
    border: u32 = 0x677581,
    disabled_border: u32 = 0xaab0b6,
    focus: u32 = 0x274c77,
    text: u32 = 0x182430,
    disabled_text: u32 = 0x7e8790,
    accent: u32 = 0x276aa5,
    /// The accent of a window that does not have the keyboard: a gray, as
    /// native applications draw selections and checked controls there.
    inactive_accent: u32 = 0x8c8c8c,
    disabled_accent: u32 = 0x9aa7b3,
    on_accent: u32 = 0xffffff,
    trough: u32 = 0xe5e9ed,
    track: u32 = 0xb7c1ca,
    thumb: u32 = 0xf4f8fc,
    disabled_thumb: u32 = 0xd9dfe5,
    focused_thumb_border: u32 = 0x183b60,
    /// Fill of a meter whose value lies outside its preferred band.
    caution: u32 = 0xa8530f,
    /// What deletes or discards, as a menu item's label: legible on the
    /// background, and on the accent where it can be.
    danger: u32 = 0xc42b1c,
};
pub const Metrics = struct {
    border: f32 = 2,
    content_inset: f32 = 8,
    indicator_size: f32 = 22,
    indicator_inset: f32 = 6,
    label_gap: f32 = 8,
    thumb_size: f32 = 16,
    track_width: f32 = 4,
    /// Width of the ring that shows which control has the keyboard focus.
    focus_ring_width: f32 = 2,
    /// Where that ring's inner edge sits from the control's edge: outward
    /// when positive, on the edge at 0 and inward when negative. Rows of a
    /// list, a tree or a table, which the list clips, ring inside them
    /// unless they set an offset of their own.
    focus_ring_offset: f32 = 1,
};

/// A copied value with no native state, callbacks or borrowed strings. The
/// application chooses appearance and prepares its own font/layout resources.
pub const Theme = struct {
    palette: Palette = .{},
    metrics: Metrics = .{},
    /// How long the pointer rests on a control before its tooltip shows, in
    /// nanoseconds: 0 keeps the window's delay (0.6 seconds unless the view
    /// sets another), and a negative delay shows it at once. Within two
    /// thirds of it after another tip goes, as the pointer moves along a
    /// toolbar, the next one shows at once: 0.4 seconds by default.
    tooltip_delay: i64 = 0,
    /// How every scroll bar of the theme looks, as a code editor's square
    /// thumb over a track; a view's own style takes its place. The zero
    /// style is the usual rounded thumb in the palette's `track`.
    scrollbar: ScrollbarStyle = .{},
    /// Size of the text that sets no font of its own, in DIP: controls'
    /// labels, and a view's text with no `Style.font`. Larger under
    /// the desktop's text scale once the theme follows it
    /// (`withPreferences`).
    font_size: f32 = default_font_size,
    /// What `withPreferences` changed, null where it has not.
    followed: ?Followed = null,

    /// A theme before and after following the desktop's settings.
    pub const Followed = struct {
        from: Palette,
        to: Palette,
        scrollbar_from: ScrollbarStyle,
        scrollbar_to: ScrollbarStyle,
        font_from: f32 = default_font_size,
        font_to: f32 = default_font_size,
    };
    /// The size of `Font{}`, and of the theme's text unless it sets another.
    pub const default_font_size: f32 = 16;

    /// Whether the theme is dark, by its background's luminance.
    pub fn isDark(self: Theme) bool {
        return gray(self.palette.background) < 128;
    }

    /// A copy of the theme in the accent `accent` (0xRRGGBB), with the
    /// shades the default looks give it, for the theme's appearance:
    /// `pressed`, the tint of what is selected or pressed, and `focus`,
    /// the ring, are the accent laid over the background (25% and 55%,
    /// or 40% and 60% of a lighter accent in the dark),
    /// `focused_thumb_border` a darker accent (a lighter one in the dark),
    /// and `on_accent` white, or near black on an accent as light as
    /// yellow. Null keeps the theme's accent, as where the desktop has
    /// none. A theme of the application's takes the desktop's accent so:
    ///
    ///     const theme = ui.Theme.dark().withAccent(preferences.accent);
    pub fn withAccent(self: Theme, accent: ?u32) Theme {
        var copy = self;
        if (accent) |value| copy.setAccent(value & 0xffffff);
        return copy;
    }
    fn setAccent(self: *Theme, accent: u32) void {
        const background = self.palette.background;
        self.palette.accent = accent;
        if (self.isDark()) {
            const lighter = mix(accent, 0xffffff, 0.2);
            self.palette.pressed = mix(background, accent, 0.4);
            self.palette.focus = mix(background, lighter, 0.6);
            self.palette.focused_thumb_border = lighter;
        } else {
            self.palette.pressed = mix(background, accent, 0.25);
            self.palette.focus = mix(background, accent, 0.55);
            self.palette.focused_thumb_border = mix(accent, 0x000000, 0.25);
        }
        // Text on the accent is near black where white would not stand
        // out, as on yellow.
        self.palette.on_accent = if (gray(accent) > 165) 0x18181b else 0xffffff;
    }

    /// What `withPreferences` follows of the desktop's settings, as
    /// `system.desktop.Preferences` gives them.
    pub const Preferences = struct {
        /// 0xRRGGBB, null where the desktop has none.
        accent: ?u32 = null,
        high_contrast: bool = false,
        /// How much larger the desktop asks text to be, 1 as usual; the
        /// theme's `font_size` grows by it, within 0.5 to 4.
        text_scale: f32 = 1,
    };

    /// A copy of the theme that follows the desktop's settings: in their
    /// accent (`withAccent`), and under high contrast with borders and
    /// disabled text closer to the text, the focus ring in the accent at
    /// full strength and the colors of `scrollbar` that are translucent
    /// stronger, and with `font_size` `text_scale` times larger. A theme that already follows them, as one this returns,
    /// follows `preferences` in their place: what following changed goes
    /// back first, so high contrast is not made stronger twice and a
    /// setting turned off goes, while the colors set since stay.
    ///
    ///     var theme = ui.Theme.dark();
    ///     theme.palette.background = 0x18181b;
    ///     _ = try context.setTheme(theme.withPreferences(.{ .accent = desktop.accent, .high_contrast = desktop.high_contrast, .text_scale = desktop.text_scale }));
    pub fn withPreferences(self: Theme, preferences: Preferences) Theme {
        var copy = self;
        if (copy.followed) |followed| copy.unfollow(followed);
        copy.followed = null;
        const from = copy;
        copy.follow(preferences);
        copy.followed = .{ .from = from.palette, .to = copy.palette, .scrollbar_from = from.scrollbar, .scrollbar_to = copy.scrollbar, .font_from = from.font_size, .font_to = copy.font_size };
        return copy;
    }
    fn follow(self: *Theme, preferences: Preferences) void {
        if (preferences.accent) |accent| self.setAccent(accent & 0xffffff);
        const scale = preferences.text_scale;
        if (std.math.isFinite(scale) and scale > 0 and scale != 1) self.font_size = @min(256, self.font_size * std.math.clamp(scale, 0.5, 4));
        if (!preferences.high_contrast) return;
        const text = self.palette.text;
        self.palette.border = mix(self.palette.border, text, 0.45);
        self.palette.disabled_text = mix(self.palette.disabled_text, text, 0.4);
        self.palette.focus = if (self.isDark()) mix(self.palette.accent, 0xffffff, 0.2) else self.palette.accent;
        // Translucent scroll bar colors are made stronger; an alpha of 0
        // is opaque already.
        inline for (.{ "track", "thumb", "thumb_hovered", "thumb_dragged" }) |name| {
            if (@field(self.scrollbar, name)) |color| @field(self.scrollbar, name) = stronger(color);
        }
    }
    /// Put back what following changed, keeping what was set since.
    fn unfollow(self: *Theme, followed: Followed) void {
        inline for (zio.fields(Palette)) |field| {
            if (@field(self.palette, field.name) == @field(followed.to, field.name)) @field(self.palette, field.name) = @field(followed.from, field.name);
        }
        if (std.meta.eql(self.scrollbar, followed.scrollbar_to)) self.scrollbar = followed.scrollbar_from;
        if (self.font_size == followed.font_to) self.font_size = followed.font_from;
    }

    pub fn light() Theme {
        return .{};
    }
    pub fn dark() Theme {
        return .{ .palette = .{
            .background = 0x181c22,
            .control = 0x2a313a,
            .pressed = 0x394e63,
            .field = 0x242b33,
            .inset = 0x1e252d,
            .border = 0x8b9aa9,
            .disabled_border = 0x56616c,
            .focus = 0x9acbff,
            .text = 0xf0f3f6,
            .disabled_text = 0x9ba5af,
            .accent = 0x5da9ed,
            .inactive_accent = 0x8a8a8a,
            .disabled_accent = 0x626e7a,
            .on_accent = 0x102438,
            .trough = 0x323c46,
            .track = 0x73808e,
            .thumb = 0xe0edf8,
            .disabled_thumb = 0x697581,
            .focused_thumb_border = 0xb8ddff,
            .caution = 0xf0a45c,
            .danger = 0xff8a80,
        } };
    }
    pub fn highContrast() Theme {
        return .{ .palette = .{
            .background = 0x000000,
            .control = 0x000000,
            .pressed = 0x303030,
            .field = 0x000000,
            .inset = 0x000000,
            .border = 0xffffff,
            .disabled_border = 0xaaaaaa,
            .focus = 0xffff00,
            .text = 0xffffff,
            .disabled_text = 0xaaaaaa,
            .accent = 0xffff00,
            .inactive_accent = 0xffff00,
            .disabled_accent = 0xaaaaaa,
            .on_accent = 0x000000,
            .trough = 0x000000,
            .track = 0xffffff,
            .thumb = 0x000000,
            .disabled_thumb = 0x000000,
            .focused_thumb_border = 0xffff00,
            .danger = 0xff6060,
        } };
    }
    pub fn validate(self: Theme) !void {
        inline for (zio.fields(Palette)) |field| {
            if (@field(self.palette, field.name) > 0xffffff) return error.InvalidThemeColor;
        }
        inline for (zio.fields(Metrics)) |field| {
            const value = @field(self.metrics, field.name);
            // A focus ring may sit inside the control's edge.
            const least: f32 = if (comptime std.mem.eql(u8, field.name, "focus_ring_offset")) -256 else 0;
            if (!std.math.isFinite(value) or value < least or value > 256) return error.InvalidThemeMetric;
        }
        if (self.metrics.indicator_size == 0 or self.metrics.thumb_size == 0 or self.metrics.track_width == 0) return error.InvalidThemeMetric;
        if (!std.math.isFinite(self.font_size) or self.font_size < 1 or self.font_size > 256) return error.InvalidThemeMetric;
    }
    /// The font of text that sets none: the label font in `font_size`.
    pub fn font(self: Theme) Font {
        return .{ .size = self.font_size };
    }
};

test "themes own copied values and validate every color and metric" {
    for ([_]Theme{ .light(), .dark(), .highContrast() }) |theme| try theme.validate();
    var custom = Theme.dark();
    const original = custom;
    custom.palette.accent = 0xff5500;
    try std.testing.expect(original.palette.accent != custom.palette.accent);
    inline for (zio.fields(Palette)) |field| {
        var invalid = original;
        @field(invalid.palette, field.name) = 0x01000000;
        try std.testing.expectError(error.InvalidThemeColor, invalid.validate());
    }
    inline for (zio.fields(Metrics)) |field| {
        for ([_]f32{ if (comptime std.mem.eql(u8, field.name, "focus_ring_offset")) -257 else -1, 257, std.math.nan(f32), std.math.inf(f32) }) |value| {
            var invalid = original;
            @field(invalid.metrics, field.name) = value;
            try std.testing.expectError(error.InvalidThemeMetric, invalid.validate());
        }
    }
}

test "an accent with its shades, for the theme's appearance" {
    const light = Theme.light().withAccent(0x7c3aed);
    try std.testing.expectEqual(@as(u32, 0x7c3aed), light.palette.accent);
    try std.testing.expectEqual(mix(0xffffff, 0x7c3aed, 0.25), light.palette.pressed);
    try std.testing.expectEqual(mix(0xffffff, 0x7c3aed, 0.55), light.palette.focus);
    try std.testing.expectEqual(mix(0x7c3aed, 0, 0.25), light.palette.focused_thumb_border);
    try std.testing.expectEqual(@as(u32, 0xffffff), light.palette.on_accent);
    try light.validate();
    // Lighter in the dark, and near black text on yellow.
    const dark = Theme.dark().withAccent(0xffd60a);
    try std.testing.expectEqual(mix(0x181c22, mix(0xffd60a, 0xffffff, 0.2), 0.6), dark.palette.focus);
    try std.testing.expectEqual(mix(0x181c22, 0xffd60a, 0.4), dark.palette.pressed);
    try std.testing.expectEqual(@as(u32, 0x18181b), dark.palette.on_accent);
    // None keeps the theme's own.
    try std.testing.expectEqualDeep(Theme.light(), Theme.light().withAccent(null));
    // The default accent's shades are close to the default look.
    const default = Theme.light().withAccent(Theme.light().palette.accent);
    try std.testing.expect(gray(default.palette.pressed) + 4 >= gray(Theme.light().palette.pressed) and gray(default.palette.pressed) <= gray(Theme.light().palette.pressed) + 4);
}

test "a theme follows the desktop again from what it was" {
    var base = Theme.light();
    base.scrollbar.thumb = 0x40000000;
    const followed = base.withPreferences(.{ .accent = 0x7c3aed, .high_contrast = true });
    try std.testing.expectEqual(@as(u32, 0x7c3aed), followed.palette.accent);
    try std.testing.expectEqual(@as(u32, 0x7c3aed), followed.palette.focus);
    try std.testing.expectEqual(mix(base.palette.border, base.palette.text, 0.45), followed.palette.border);
    try std.testing.expectEqual(@as(?u32, 0x66000000), followed.scrollbar.thumb);
    // Following again does not make it stronger twice.
    const again = followed.withPreferences(.{ .accent = 0x7c3aed, .high_contrast = true });
    try std.testing.expectEqual(followed.palette.border, again.palette.border);
    try std.testing.expectEqual(followed.scrollbar.thumb, again.scrollbar.thumb);
    // A setting turned off goes; a color set since stays.
    var changed = followed;
    changed.palette.background = 0xfafafa;
    const plain = changed.withPreferences(.{});
    try std.testing.expectEqual(base.palette.border, plain.palette.border);
    try std.testing.expectEqual(base.palette.accent, plain.palette.accent);
    try std.testing.expectEqual(base.palette.focus, plain.palette.focus);
    try std.testing.expectEqual(base.scrollbar.thumb, plain.scrollbar.thumb);
    try std.testing.expectEqual(@as(u32, 0xfafafa), plain.palette.background);
    // The text scale grows the font size once, and goes back.
    const larger = base.withPreferences(.{ .text_scale = 1.5 });
    try std.testing.expectEqual(@as(f32, 24), larger.font_size);
    try std.testing.expectEqual(@as(f32, 24), larger.withPreferences(.{ .text_scale = 1.5 }).font_size);
    try std.testing.expectEqual(@as(f32, 16), larger.withPreferences(.{}).font_size);
    var sized = larger;
    sized.font_size = 18;
    try std.testing.expectEqual(@as(f32, 18), sized.withPreferences(.{}).font_size);
    try std.testing.expectEqual(@as(f32, 64), base.withPreferences(.{ .text_scale = 9 }).font_size);
    try std.testing.expectEqual(@as(f32, 16), base.withPreferences(.{ .text_scale = std.math.nan(f32) }).font_size);
    var tiny = base;
    tiny.font_size = 0;
    try std.testing.expectError(error.InvalidThemeMetric, tiny.validate());
    // Without settings it is the theme as it was.
    try std.testing.expectEqualDeep(base.palette, base.withPreferences(.{}).palette);
}
