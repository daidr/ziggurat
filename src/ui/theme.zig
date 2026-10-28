const std = @import("std");
const zio = @import("ziggurat_io");

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
    disabled_accent: u32 = 0x9aa7b3,
    on_accent: u32 = 0xffffff,
    trough: u32 = 0xe5e9ed,
    track: u32 = 0xb7c1ca,
    thumb: u32 = 0xf4f8fc,
    disabled_thumb: u32 = 0xd9dfe5,
    focused_thumb_border: u32 = 0x183b60,
    /// Fill of a meter whose value lies outside its preferred band.
    caution: u32 = 0xa8530f,
};
pub const Metrics = struct {
    border: f32 = 2,
    content_inset: f32 = 8,
    indicator_size: f32 = 22,
    indicator_inset: f32 = 6,
    label_gap: f32 = 8,
    thumb_size: f32 = 16,
    track_width: f32 = 4,
};

/// A copied value with no native state, callbacks or borrowed strings. The
/// application chooses appearance and prepares its own font/layout resources.
pub const Theme = struct {
    palette: Palette = .{},
    metrics: Metrics = .{},
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
            .disabled_accent = 0x626e7a,
            .on_accent = 0x102438,
            .trough = 0x323c46,
            .track = 0x73808e,
            .thumb = 0xe0edf8,
            .disabled_thumb = 0x697581,
            .focused_thumb_border = 0xb8ddff,
            .caution = 0xf0a45c,
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
            .disabled_accent = 0xaaaaaa,
            .on_accent = 0x000000,
            .trough = 0x000000,
            .track = 0xffffff,
            .thumb = 0x000000,
            .disabled_thumb = 0x000000,
            .focused_thumb_border = 0xffff00,
        } };
    }
    pub fn validate(self: Theme) !void {
        inline for (zio.fields(Palette)) |field| {
            if (@field(self.palette, field.name) > 0xffffff) return error.InvalidThemeColor;
        }
        inline for (zio.fields(Metrics)) |field| {
            const value = @field(self.metrics, field.name);
            if (!std.math.isFinite(value) or value < 0 or value > 256) return error.InvalidThemeMetric;
        }
        if (self.metrics.indicator_size == 0 or self.metrics.thumb_size == 0 or self.metrics.track_width == 0) return error.InvalidThemeMetric;
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
        for ([_]f32{ -1, 257, std.math.nan(f32), std.math.inf(f32) }) |value| {
            var invalid = original;
            @field(invalid.metrics, field.name) = value;
            try std.testing.expectError(error.InvalidThemeMetric, invalid.validate());
        }
    }
}
