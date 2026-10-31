//! Facts a page tells its View through a script the View runs at document
//! start in the top frame, apart from the page's own messages: its theme
//! color and the size of its content. The script is page_facts.js; the
//! backends give it a channel that reaches the View alone.
const std = @import("std");

/// 8-bit sRGB with straight alpha.
pub const Rgba = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    /// "#rrggbbaa", as the script tells it.
    pub fn parse(text: []const u8) ?Rgba {
        if (text.len != 9 or text[0] != '#') return null;
        var bytes: [4]u8 = undefined;
        for (&bytes, 0..) |*byte, i| byte.* = std.fmt.parseInt(u8, text[1 + 2 * i ..][0..2], 16) catch return null;
        return .{ .r = bytes[0], .g = bytes[1], .b = bytes[2], .a = bytes[3] };
    }
    pub fn eql(a: ?Rgba, b: ?Rgba) bool {
        if (a == null or b == null) return a == null and b == null;
        return std.meta.eql(a.?, b.?);
    }
};

/// The size of a page's content in CSS pixels: its root element's, and the
/// room of the vertical scrollbar the page shows and of a horizontal one,
/// which counts only when the content is wider than the root.
pub const ContentSize = struct {
    width: f64,
    height: f64,
    scrollbar: f64 = 0,
    horizontal_scrollbar: f64 = 0,

    /// "width,height,scrollbar,horizontal", as the script tells it.
    pub fn parse(text: []const u8) ?ContentSize {
        var values: [4]f64 = undefined;
        var parts = std.mem.splitScalar(u8, text, ',');
        for (&values) |*value| {
            const part = parts.next() orelse return null;
            value.* = std.fmt.parseFloat(f64, part) catch return null;
            if (!std.math.isFinite(value.*) or value.* < 0 or value.* > max_css) return null;
        }
        if (parts.next() != null) return null;
        return .{ .width = values[0], .height = values[1], .scrollbar = values[2], .horizontal_scrollbar = values[3] };
    }
};
const max_css = 1 << 20;

/// Sizes a window to its page's content (Options.fit_content), in DIPs; 0 is
/// no limit. The page's root is laid out at its content's width within the
/// limits, so text wraps at max_width, and content taller than max_height
/// scrolls.
pub const FitContent = struct {
    min_width: u32 = 0,
    min_height: u32 = 0,
    max_width: u32 = 0,
    max_height: u32 = 0,
    /// Resize the window the View is attached to whenever the size changes,
    /// only in the dimension that changed, and not while it is maximized or
    /// in full screen. Regions, sessions and false only tell the size with
    /// PageEvent.content_size_changed, for the app to fit (fit, Flyout.setSize).
    resize_window: bool = true,

    pub fn validate(self: FitContent) !void {
        if (self.max_width != 0 and self.max_width < self.min_width) return error.InvalidFitContent;
        if (self.max_height != 0 and self.max_height < self.min_height) return error.InvalidFitContent;
        if (@max(self.min_width, self.min_height, self.max_width, self.max_height) > max_dips) return error.InvalidFitContent;
    }
};
/// No display is larger: no page makes an integer overflow.
const max_dips = 1 << 16;

pub const Size = struct { width: u32, height: u32 };

/// The size in DIPs of content at zoom within the limits, and below
/// max_height when it is not 0. Fractions of a pixel take one, but for the
/// rounding error of fractional layout. Content taller than the height it
/// gets takes the room of its vertical scrollbar.
pub fn fit(limits: FitContent, content: ContentSize, zoom: f64, max_height: u32) ?Size {
    if (!(content.width >= 0 and content.height >= 0)) return null;
    const z = if (zoom > 0 and std.math.isFinite(zoom)) zoom else 1;
    const height_limit = if (max_height != 0 and (limits.max_height == 0 or max_height < limits.max_height)) max_height else limits.max_height;
    const room = struct {
        fn of(value: f64) f64 {
            return if (value > 0) value else 0;
        }
    }.of;
    var width = content.width;
    const height = content.height + room(content.horizontal_scrollbar);
    if (dips(height, z) > within(dips(height, z), limits.min_height, height_limit)) width += room(content.scrollbar);
    return .{ .width = within(dips(width, z), limits.min_width, limits.max_width), .height = within(dips(height, z), limits.min_height, height_limit) };
}
fn dips(value_css: f64, zoom: f64) u32 {
    const value = @ceil(@min(value_css * zoom, max_dips) - 1.0 / 128.0);
    return @max(@as(u32, @intFromFloat(@max(value, 0))), 1);
}
fn within(value: u32, low: u32, high: u32) u32 {
    const raised = @max(value, low);
    return if (high != 0) @min(raised, high) else raised;
}

pub const Config = struct {
    theme: bool = false,
    fit: ?FitContent = null,
    zoom: f64 = 1,
    pub fn any(self: Config) bool {
        return self.theme or self.fit != null;
    }
};

/// The script's function, called with the post function and its options, as
/// a JavaScript expression. Limits go to the page in its CSS pixels.
pub fn script(allocator: std.mem.Allocator, config: Config, post: []const u8) ![]u8 {
    const source = comptime std.mem.trimEnd(u8, @embedFile("page_facts.js"), "\n");
    const z = if (config.zoom > 0) config.zoom else 1;
    if (config.fit) |limits| {
        return std.fmt.allocPrint(allocator, "({s})({s},{{theme:{},fit:{{minWidth:{d},minHeight:{d},maxWidth:{d},maxHeight:{d}}}}});", .{ source, post, config.theme, css(limits.min_width, z), css(limits.min_height, z), css(limits.max_width, z), css(limits.max_height, z) });
    }
    return std.fmt.allocPrint(allocator, "({s})({s},{{theme:{},fit:null}});", .{ source, post, config.theme });
}
fn css(value: u32, zoom: f64) f64 {
    return @as(f64, @floatFromInt(value)) / zoom;
}

/// A message the script posted, one letter and its value.
pub const Fact = union(enum) {
    theme_color: ?Rgba,
    content_size: ContentSize,
};
pub fn parse(text: []const u8) ?Fact {
    if (text.len == 0) return null;
    const value = text[1..];
    return switch (text[0]) {
        'T' => if (value.len == 0) .{ .theme_color = null } else if (Rgba.parse(value)) |color| .{ .theme_color = color } else null,
        'S' => if (ContentSize.parse(value)) |size| .{ .content_size = size } else null,
        else => null,
    };
}

test "theme colors and sizes parse strictly" {
    try std.testing.expectEqual(Rgba{ .r = 0x1e, .g = 0x90, .b = 0xff, .a = 0x80 }, Rgba.parse("#1e90ff80").?);
    try std.testing.expect(Rgba.parse("#1e90ff") == null);
    try std.testing.expect(Rgba.parse("#1e90fg80") == null);
    try std.testing.expectEqual(Fact{ .theme_color = null }, parse("T").?);
    try std.testing.expect(parse("Tred") == null);
    const size = parse("S320.5,200,15,0").?.content_size;
    try std.testing.expectEqual(@as(f64, 320.5), size.width);
    try std.testing.expectEqual(@as(f64, 15), size.scrollbar);
    try std.testing.expect(parse("S1,2,3") == null);
    try std.testing.expect(parse("S1,2,3,4,5") == null);
    try std.testing.expect(parse("S-1,2,3,4") == null);
    try std.testing.expect(parse("Snan,2,3,4") == null);
    try std.testing.expect(parse("X") == null);
    try std.testing.expect(parse("") == null);
}

test "fit rounds up within limits and counts the scrollbar of tall content" {
    const limits: FitContent = .{ .min_width = 100, .max_width = 400, .max_height = 300 };
    try std.testing.expectEqual(Size{ .width = 201, .height = 150 }, fit(limits, .{ .width = 200.5, .height = 150 }, 1, 0).?);
    try std.testing.expectEqual(Size{ .width = 100, .height = 20 }, fit(limits, .{ .width = 10, .height = 20 }, 1, 0).?);
    // Taller than the maximum: the scrollbar's room joins the width.
    try std.testing.expectEqual(Size{ .width = 215, .height = 300 }, fit(limits, .{ .width = 200, .height = 900, .scrollbar = 15 }, 1, 0).?);
    // The display's height bounds it below the limit.
    try std.testing.expectEqual(Size{ .width = 215, .height = 250 }, fit(limits, .{ .width = 200, .height = 900, .scrollbar = 15 }, 1, 250).?);
    // Zoom turns CSS pixels into DIPs; rounding error of a layout is forgiven.
    try std.testing.expectEqual(Size{ .width = 300, .height = 100 }, fit(.{}, .{ .width = 200.004, .height = 66.67 }, 1.5, 0).?);
    try std.testing.expectEqual(Size{ .width = 1, .height = 1 }, fit(.{}, .{ .width = 0, .height = 0 }, 1, 0).?);
    try std.testing.expect(fit(.{}, .{ .width = std.math.nan(f64), .height = 1 }, 1, 0) == null);
    try std.testing.expectEqual(Size{ .width = max_dips, .height = max_dips }, fit(.{}, .{ .width = 1e9, .height = 1e9 }, 1, 0).?);
}

test "limits validate and reach the script in CSS pixels" {
    try std.testing.expectError(error.InvalidFitContent, (FitContent{ .min_width = 10, .max_width = 5 }).validate());
    try std.testing.expectError(error.InvalidFitContent, (FitContent{ .max_height = 1 << 20 }).validate());
    try (FitContent{ .max_width = 400 }).validate();
    const text = try script(std.testing.allocator, .{ .theme = true, .fit = .{ .max_width = 400, .max_height = 300 }, .zoom = 2 }, "p");
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.endsWith(u8, text, "(p,{theme:true,fit:{minWidth:0,minHeight:0,maxWidth:200,maxHeight:150}});"));
    const plain = try script(std.testing.allocator, .{ .theme = true }, "p");
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.endsWith(u8, plain, "(p,{theme:true,fit:null});"));
}
