const std = @import("std");
const v = @import("ziggurat_vector");
const doc = @import("document.zig");
const numbers = @import("numbers.zig");
const paint = @import("paint.zig");
const text = @import("text.zig");
pub const Property = enum { fill, stroke, color, opacity, fill_opacity, stroke_opacity, fill_rule, stroke_width, stroke_linecap, stroke_linejoin, stroke_miterlimit, stroke_dashoffset, stroke_dasharray, display, visibility, overflow, stop_color, stop_opacity, color_interpolation, clip_path, clip_rule, mask, mask_type, font_family, font_size, font_weight, font_style, direction, text_anchor, white_space, paint_order, vector_effect, marker_start, marker_end, marker_mid };
const property_names = [_][]const u8{ "fill", "stroke", "color", "opacity", "fill-opacity", "stroke-opacity", "fill-rule", "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-dashoffset", "stroke-dasharray", "display", "visibility", "overflow", "stop-color", "stop-opacity", "color-interpolation", "clip-path", "clip-rule", "mask", "mask-type", "font-family", "font-size", "font-weight", "font-style", "direction", "text-anchor", "white-space", "paint-order", "vector-effect", "marker-start", "marker-end", "marker-mid" };
pub const PaintOperation = enum { fill, stroke, markers };
const normal_order: [3]PaintOperation = .{ .fill, .stroke, .markers };
pub const Interpolation = enum { srgb, linear_rgb };
pub fn property(name: []const u8) ?Property {
    for (property_names, 0..) |key, index| if (std.ascii.eqlIgnoreCase(name, key)) return @fromBackingInt(@intCast(index));
    return null;
}
pub const Style = struct {
    fill: paint.Paint = .{ .color = .{} },
    stroke: paint.Paint = .none,
    color: paint.Color = .{},
    opacity: f64 = 1,
    fill_opacity: f64 = 1,
    stroke_opacity: f64 = 1,
    paint_order: [3]PaintOperation = normal_order,
    rule: v.FillRule = .nonzero,
    stroke_options: v.Stroke = .{},
    vector_effect: enum { none, non_scaling_stroke } = .none,
    stroke_width: numbers.Length = .{ .value = 1 },
    dash_offset: numbers.Length = .{ .value = 0 },
    dash_values: [32]numbers.Length = undefined,
    dash_count: usize = 0,
    displayed: bool = true,
    visible: bool = true,
    overflow_hidden: bool = false,
    /// Preserve auto/scroll provenance for static image capability checks.
    /// Ordinary viewport clipping retains its existing overflow_hidden policy.
    overflow_scrollable: bool = false,
    stop_color: paint.Fallback = .{ .color = .{} },
    stop_opacity: f64 = 1,
    interpolation: Interpolation = .srgb,
    clip_path: ?[]const u8 = null,
    clip_rule: v.FillRule = .nonzero,
    mask: ?[]const u8 = null,
    marker_start: ?[]const u8 = null,
    marker_end: ?[]const u8 = null,
    marker_mid: ?[]const u8 = null,
    mask_type: enum { luminance, alpha } = .luminance,
    font: text.Font = .{},
    text_anchor: text.Anchor = .start,
    preserve_space: bool = false,
    pub fn base(self: Style, node: doc.Node) !Style {
        var result = self;
        result.clip_path = null;
        result.mask = null;
        result.mask_type = .luminance;
        result.opacity = 1;
        result.vector_effect = .none;
        result.displayed = true;
        result.overflow_hidden = false;
        result.overflow_scrollable = false;
        result.stop_color = .{ .color = .{} };
        result.stop_opacity = 1;
        for (node.attributes) |attribute| if (property(attribute.name)) |kind| try result.applyDeclaration(self, kind, attribute.value);
        return result;
    }
    pub fn applyDeclaration(self: *Style, parent: Style, kind: Property, input: []const u8) !void {
        // XML/SVG whitespace is independent of CSS white-space processing.
        // CSS segment-break handling requires a separate language contract.
        if (kind == .white_space) return error.UnsupportedTextWhitespace;
        const value = std.mem.trim(u8, input, " \t\r\n");
        const inherited = kind != .opacity and kind != .display and kind != .overflow and kind != .stop_color and kind != .stop_opacity and kind != .clip_path and kind != .mask and kind != .mask_type and kind != .vector_effect;
        if (std.ascii.eqlIgnoreCase(value, "inherit") or (std.ascii.eqlIgnoreCase(value, "unset") and inherited) or (kind == .color and std.ascii.eqlIgnoreCase(value, "currentColor"))) return self.copyProperty(parent, kind);
        if (std.ascii.eqlIgnoreCase(value, "initial") or std.ascii.eqlIgnoreCase(value, "unset")) return self.copyProperty(.{}, kind);
        if (kind == .font_size) {
            self.font.size = try (try numbers.length(value)).resolve(parent.font.size);
            if (self.font.size <= 0 or self.font.size > 1e6) return error.UnsupportedFontSize;
            return;
        }
        var keyword_buffer: [32]u8 = undefined;
        const normalized = switch (kind) {
            .fill_rule, .clip_rule, .mask_type, .stroke_linecap, .stroke_linejoin, .display, .visibility, .overflow, .color_interpolation, .font_style, .font_weight, .direction, .text_anchor, .white_space, .vector_effect => blk: {
                if (value.len > keyword_buffer.len) return error.InvalidStyle;
                for (value, 0..) |byte, i| keyword_buffer[i] = std.ascii.toLower(byte);
                break :blk keyword_buffer[0..value.len];
            },
            .stroke_dasharray => if (std.ascii.eqlIgnoreCase(value, "none")) "none" else value,
            else => value,
        };
        const applied = try self.apply(property_names[@backingInt(kind)], normalized);
        std.debug.assert(applied);
    }
    fn copyProperty(self: *Style, source: Style, kind: Property) void {
        switch (kind) {
            .fill => self.fill = source.fill,
            .stroke => self.stroke = source.stroke,
            .color => self.color = source.color,
            .opacity => self.opacity = source.opacity,
            .fill_opacity => self.fill_opacity = source.fill_opacity,
            .stroke_opacity => self.stroke_opacity = source.stroke_opacity,
            .paint_order => self.paint_order = source.paint_order,
            .fill_rule => self.rule = source.rule,
            .stroke_width => self.stroke_width = source.stroke_width,
            .stroke_linecap => self.stroke_options.cap = source.stroke_options.cap,
            .stroke_linejoin => self.stroke_options.join = source.stroke_options.join,
            .stroke_miterlimit => self.stroke_options.miter_limit = source.stroke_options.miter_limit,
            .vector_effect => self.vector_effect = source.vector_effect,
            .stroke_dashoffset => self.dash_offset = source.dash_offset,
            .stroke_dasharray => {
                self.dash_values = source.dash_values;
                self.dash_count = source.dash_count;
            },
            .display => self.displayed = source.displayed,
            .visibility => self.visible = source.visible,
            .overflow => {
                self.overflow_hidden = source.overflow_hidden;
                self.overflow_scrollable = source.overflow_scrollable;
            },
            .stop_color => self.stop_color = source.stop_color,
            .stop_opacity => self.stop_opacity = source.stop_opacity,
            .color_interpolation => self.interpolation = source.interpolation,
            .clip_path => self.clip_path = source.clip_path,
            .clip_rule => self.clip_rule = source.clip_rule,
            .mask => self.mask = source.mask,
            .marker_start => self.marker_start = source.marker_start,
            .marker_end => self.marker_end = source.marker_end,
            .marker_mid => self.marker_mid = source.marker_mid,
            .mask_type => self.mask_type = source.mask_type,
            .font_family => {
                self.font.family = source.font.family;
                self.font.generic = source.font.generic;
            },
            .font_size => self.font.size = source.font.size,
            .font_weight => self.font.weight = source.font.weight,
            .font_style => self.font.italic = source.font.italic,
            .direction => self.font.direction = source.font.direction,
            .text_anchor => self.text_anchor = source.text_anchor,
            .white_space => self.preserve_space = source.preserve_space,
        }
    }
    fn apply(self: *Style, key: []const u8, input: []const u8) !bool {
        const value = std.mem.trim(u8, input, " \t\r\n");
        if (std.mem.eql(u8, key, "marker-start") or std.mem.eql(u8, key, "marker-end") or std.mem.eql(u8, key, "marker-mid")) {
            const reference = try localReference(value);
            if (std.mem.eql(u8, key, "marker-start")) self.marker_start = reference else if (std.mem.eql(u8, key, "marker-end")) self.marker_end = reference else self.marker_mid = reference;
            return true;
        }
        if (std.mem.eql(u8, key, "vector-effect")) {
            self.vector_effect = if (std.mem.eql(u8, value, "none")) .none else if (std.mem.eql(u8, value, "non-scaling-stroke")) .non_scaling_stroke else return error.UnsupportedVectorEffect;
            return true;
        }
        if (std.mem.eql(u8, key, "paint-order")) {
            self.paint_order = try parsePaintOrder(value);
            return true;
        }
        if (std.mem.eql(u8, key, "font-family")) {
            try text.parseFamily(&self.font, value);
            return true;
        }
        if (std.mem.eql(u8, key, "font-weight")) {
            self.font.weight = if (std.mem.eql(u8, value, "normal")) 400 else if (std.mem.eql(u8, value, "bold")) 700 else std.fmt.parseInt(u32, value, 10) catch return error.UnsupportedFontWeight;
            if (self.font.weight < 100 or self.font.weight > 900) return error.UnsupportedFontWeight;
            return true;
        }
        if (std.mem.eql(u8, key, "font-style")) {
            self.font.italic = if (std.mem.eql(u8, value, "normal")) false else if (std.mem.eql(u8, value, "italic")) true else return error.UnsupportedFontStyle;
            return true;
        }
        if (std.mem.eql(u8, key, "direction")) {
            self.font.direction = if (std.mem.eql(u8, value, "ltr")) .ltr else if (std.mem.eql(u8, value, "rtl")) .rtl else return error.UnsupportedTextDirection;
            return true;
        }
        if (std.mem.eql(u8, key, "text-anchor")) {
            self.text_anchor = if (std.mem.eql(u8, value, "start")) .start else if (std.mem.eql(u8, value, "middle")) .middle else if (std.mem.eql(u8, value, "end")) .end else return error.UnsupportedTextAnchor;
            return true;
        }
        if (std.mem.eql(u8, key, "white-space")) {
            return error.UnsupportedTextWhitespace;
        }
        if (std.mem.eql(u8, key, "clip-path")) {
            self.clip_path = try localReference(value);
            return true;
        }
        if (std.mem.eql(u8, key, "mask")) {
            self.mask = try localReference(value);
            return true;
        }
        if (std.mem.eql(u8, key, "clip-rule")) {
            self.clip_rule = if (std.mem.eql(u8, value, "evenodd")) .even_odd else if (std.mem.eql(u8, value, "nonzero")) .nonzero else return error.InvalidStyle;
            return true;
        }
        if (std.mem.eql(u8, key, "mask-type")) {
            self.mask_type = if (std.mem.eql(u8, value, "alpha")) .alpha else if (std.mem.eql(u8, value, "luminance")) .luminance else return error.InvalidStyle;
            return true;
        }
        if (std.mem.eql(u8, key, "stop-color")) {
            self.stop_color = if (std.ascii.eqlIgnoreCase(value, "currentColor")) .current_color else .{ .color = try paint.color(value) };
            return true;
        }
        if (std.mem.eql(u8, key, "stop-opacity")) {
            self.stop_opacity = try paint.opacity(value);
            return true;
        }
        if (std.mem.eql(u8, key, "color-interpolation")) {
            self.interpolation = if (std.mem.eql(u8, value, "srgb") or std.mem.eql(u8, value, "auto")) .srgb else if (std.mem.eql(u8, value, "linearrgb")) .linear_rgb else return error.UnsupportedColorInterpolation;
            return true;
        }
        if (std.mem.eql(u8, key, "overflow")) {
            self.overflow_hidden = if (std.mem.eql(u8, value, "visible")) false else if (std.mem.eql(u8, value, "hidden") or std.mem.eql(u8, value, "scroll") or std.mem.eql(u8, value, "auto")) true else return error.UnsupportedOverflow;
            self.overflow_scrollable = std.mem.eql(u8, value, "auto") or std.mem.eql(u8, value, "scroll");
            return true;
        }
        if (std.mem.eql(u8, key, "fill")) self.fill = try paint.parse(value) else if (std.mem.eql(u8, key, "stroke")) self.stroke = try paint.parse(value) else if (std.mem.eql(u8, key, "color")) {
            if (!std.ascii.eqlIgnoreCase(value, "currentColor")) self.color = try paint.color(value);
        } else if (std.mem.eql(u8, key, "opacity")) self.opacity = try paint.opacity(value) else if (std.mem.eql(u8, key, "fill-opacity")) self.fill_opacity = try paint.opacity(value) else if (std.mem.eql(u8, key, "stroke-opacity")) self.stroke_opacity = try paint.opacity(value) else if (std.mem.eql(u8, key, "fill-rule")) {
            self.rule = if (std.mem.eql(u8, value, "evenodd")) .even_odd else if (std.mem.eql(u8, value, "nonzero")) .nonzero else return error.InvalidStyle;
        } else if (std.mem.eql(u8, key, "stroke-width")) {
            self.stroke_width = try numbers.length(value);
            if (self.stroke_width.value < 0) return error.InvalidStroke;
        } else if (std.mem.eql(u8, key, "stroke-linecap")) self.stroke_options.cap = if (std.mem.eql(u8, value, "round")) .round else if (std.mem.eql(u8, value, "square")) .square else if (std.mem.eql(u8, value, "butt")) .butt else return error.InvalidStroke else if (std.mem.eql(u8, key, "stroke-linejoin")) self.stroke_options.join = if (std.mem.eql(u8, value, "round")) .round else if (std.mem.eql(u8, value, "bevel")) .bevel else if (std.mem.eql(u8, value, "miter")) .miter else return error.InvalidStroke else if (std.mem.eql(u8, key, "stroke-miterlimit")) {
            self.stroke_options.miter_limit = try numbers.scalar(value);
            try self.stroke_options.validate();
        } else if (std.mem.eql(u8, key, "stroke-dashoffset")) self.dash_offset = try numbers.length(value) else if (std.mem.eql(u8, key, "stroke-dasharray")) {
            self.dash_count = 0;
            if (!std.mem.eql(u8, value, "none")) {
                // Dash percentages and physical units need length tokens, not
                // a numeric-only list. Separators are required between tokens.
                var scan: numbers.Scanner = .{ .input = value };
                _ = scan.space();
                while (scan.at < value.len) {
                    if (self.dash_count == self.dash_values.len) return error.DashesFull;
                    const begin = scan.at;
                    _ = try scan.number();
                    while (scan.at < value.len and (std.ascii.isAlphabetic(value[scan.at]) or value[scan.at] == '%')) scan.at += 1;
                    const length = try numbers.length(value[begin..scan.at]);
                    if (length.value < 0) return error.InvalidDash;
                    self.dash_values[self.dash_count] = length;
                    self.dash_count += 1;
                    const spaced = scan.space();
                    if (scan.at == value.len) break;
                    if (value[scan.at] == ',') {
                        scan.at += 1;
                        _ = scan.space();
                        if (scan.at == value.len) return error.InvalidDash;
                    } else if (!spaced) return error.InvalidDash;
                }
                if (self.dash_count == 0) return error.InvalidDash;
            }
        } else if (std.mem.eql(u8, key, "display")) self.displayed = if (std.mem.eql(u8, value, "none")) false else if (std.mem.eql(u8, value, "inline")) true else return error.UnsupportedDisplay else if (std.mem.eql(u8, key, "visibility")) self.visible = if (std.mem.eql(u8, value, "visible")) true else if (std.mem.eql(u8, value, "hidden") or std.mem.eql(u8, value, "collapse")) false else return error.InvalidStyle else return false;
        return true;
    }
};

fn parsePaintOrder(value: []const u8) ![3]PaintOperation {
    if (std.ascii.eqlIgnoreCase(value, "normal")) return normal_order;
    var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n\x0c");
    var result: [3]PaintOperation = undefined;
    var count: usize = 0;
    var seen: [3]bool = @splat(false);
    while (tokens.next()) |token| {
        const operation: PaintOperation = if (std.ascii.eqlIgnoreCase(token, "fill")) .fill else if (std.ascii.eqlIgnoreCase(token, "stroke")) .stroke else if (std.ascii.eqlIgnoreCase(token, "markers")) .markers else return error.InvalidPaintOrder;
        const index = @backingInt(operation);
        if (seen[index]) return error.InvalidPaintOrder;
        seen[index] = true;
        result[count] = operation;
        count += 1;
    }
    if (count == 0) return error.InvalidPaintOrder;
    for (normal_order) |operation| if (!seen[@backingInt(operation)]) {
        result[count] = operation;
        count += 1;
    };
    return result;
}

fn localReference(value: []const u8) !?[]const u8 {
    if (std.ascii.eqlIgnoreCase(value, "none")) return null;
    const parsed = try paint.parse(value);
    if (parsed != .reference or (std.mem.indexOfScalarPos(u8, value, 4, ')') orelse return error.InvalidEffectReference) != value.len - 1) return error.InvalidEffectReference;
    return parsed.reference.id;
}
