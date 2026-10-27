//! Pictures in a view: a decoded and prepared bitmap (`image`), a vector
//! document drawn at the size it is laid out at (`svg`), and an icon of
//! the built-in set (`icon`). All three are leaves that take no input. A
//! picture with alternative text is an image to accessibility clients,
//! named by it; one without, or marked decorative, is not exposed at all.
//!
//! Paint only reads what was prepared before it: a bitmap must already be
//! an uploaded `ImageView`, and SVG documents and icons are drawn by
//! painters (see `ziggurat_view_graphics`) that prepare and upload their
//! pixels in a task posted after paint, then repaint.
const std = @import("std");
const ui = @import("ziggurat_ui");
const view = @import("root.zig");

const View = view.View;
const Node = view.Node;
const Style = view.Style;
const Error = view.Error;
const Rect = view.Rect;
const Size = view.Size;
const ImageView = view.ImageView;
pub const Icon = @import("icons.zig").Icon;

/// How a picture fills the box it is laid out in.
pub const Fit = enum {
    /// Scaled to fit inside the box, keeping its proportions; the rest of
    /// the box stays empty.
    contain,
    /// Scaled to cover the box, keeping its proportions; what falls
    /// outside is cropped.
    cover,
    /// Stretched to the box.
    fill,
    /// At its own size, centered and cropped to the box.
    none,
};

pub const ImageOptions = struct {
    fit: Fit = .contain,
    /// What the picture shows, for accessibility clients. Without it the
    /// picture is decorative.
    alt: []const u8 = "",
    /// Hide the picture from accessibility clients even with `alt`, such
    /// as a picture beside text that says the same.
    decorative: bool = false,
};

pub const IconOptions = struct {
    /// Accessible name; an icon without one is decorative, as an icon
    /// beside a label is. Name the button instead of an icon in it.
    name: []const u8 = "",
    /// Side of the icon's square in DIP, unless `Style.width`/`height`
    /// say otherwise.
    size: f32 = 20,
    /// Mirror the icon right to left; null mirrors directional icons
    /// (horizontal chevrons and arrows) only.
    mirror: ?bool = null,
};

/// A vector picture drawn by its owner, such as
/// `ziggurat_view_graphics.SvgImage`. `width` and `height` are its own
/// size in DIP, which the layout uses and `Fit` keeps the proportions of.
pub const SvgPicture = struct {
    context: *anyopaque,
    width: f32,
    height: f32,
    /// Called in paint with the window frame: draw the picture stretched to
    /// `destination` with `color` for its current color. It must not
    /// allocate or prepare; a painter without pixels for that size draws
    /// nothing and prepares them after paint.
    paint: *const fn (context: *anyopaque, frame: *ui.Frame, destination: Rect, color: ui.Color) anyerror!void,
};

/// Draws built-in icons for a Host; see `Options.icons`.
pub const IconPainter = struct {
    context: *anyopaque,
    /// Called in paint: draw `icon` filling the square `bounds` in `color`,
    /// mirrored horizontally when `mirrored`. The same rules as
    /// `SvgPicture.paint` apply.
    paint: *const fn (context: *anyopaque, frame: *ui.Frame, icon: Icon, bounds: Rect, color: ui.Color, mirrored: bool) anyerror!void,
};

/// What an image, SVG or icon node shows.
pub const Graphic = struct {
    source: union(enum) {
        bitmap: ImageView,
        svg: SvgPicture,
        icon: Icon,
    },
    fit: Fit = .contain,
    natural: Size,
    /// Not exposed to accessibility clients.
    decorative: bool = true,
    /// An icon drawn mirrored.
    mirrored: bool = false,
};

/// A decoded, prepared and uploaded bitmap; see `ImageOptions`. It is its
/// size in pixels as DIP unless `Style.width`/`height` say otherwise, and
/// shrinks to nothing in a crowded row.
pub fn image(v: *View, picture: ImageView, options: ImageOptions, style: Style) Error!void {
    const level = if (picture.levels.len > 0) picture.levels[0] else return error.InvalidValue;
    try leaf(v, .image, .{ .source = .{ .bitmap = picture }, .natural = .{ .width = @floatFromInt(level.width), .height = @floatFromInt(level.height) } }, options, style);
}

/// A vector picture at the size it is laid out at; see `ImageOptions`.
pub fn svg(v: *View, picture: SvgPicture, options: ImageOptions, style: Style) Error!void {
    if (!(picture.width > 0 and picture.height > 0) or !std.math.isFinite(picture.width) or !std.math.isFinite(picture.height)) return error.InvalidValue;
    try leaf(v, .svg, .{ .source = .{ .svg = picture }, .natural = .{ .width = picture.width, .height = picture.height } }, options, style);
}

/// An icon of the built-in set, in `Style.color` or the theme's text color
/// (its disabled color when disabled); see `IconOptions`. Drawn by the
/// Host's `Options.icons`; without a painter it keeps its place empty.
pub fn icon(v: *View, which: Icon, options: IconOptions, style: Style) Error!void {
    if (!(options.size > 0) or !std.math.isFinite(options.size)) return error.InvalidValue;
    const node = try v.appendNode(.icon, style);
    node.text = @tagName(which);
    if (options.name.len > 0) node.style.name = try v.copyText(options.name);
    const mirrored = node.rtl and (options.mirror orelse which.directional());
    node.graphic = .{ .source = .{ .icon = which }, .natural = .{ .width = options.size, .height = options.size }, .decorative = options.name.len == 0, .mirrored = mirrored };
}

fn leaf(v: *View, kind: view.Kind, graphic: Graphic, options: ImageOptions, style: Style) Error!void {
    const node = try v.appendNode(kind, style);
    var shown = graphic;
    shown.fit = options.fit;
    shown.decorative = options.decorative or options.alt.len == 0;
    if (options.alt.len > 0) node.style.name = try v.copyText(options.alt);
    node.graphic = shown;
}

/// Natural size as the preferred size; pictures may shrink to nothing.
pub fn measure(node: *const Node) view.layout.Measurement {
    const natural = node.graphic.?.natural;
    if (node.kind == .icon) return .{ .minimum = natural, .preferred = natural };
    return .{ .minimum = .{}, .preferred = natural };
}

/// Where a picture of size `natural` goes for `fit` in `box`; it may reach
/// past the box for `cover` and `none`, whose painting clips to the box.
pub fn fitted(box: Rect, natural: Size, fit: Fit) Rect {
    if (fit == .fill or !(natural.width > 0 and natural.height > 0)) return box;
    const scale: f32 = switch (fit) {
        .contain => @min(box.width / natural.width, box.height / natural.height),
        .cover => @max(box.width / natural.width, box.height / natural.height),
        .none => 1,
        .fill => unreachable,
    };
    const width = natural.width * scale;
    const height = natural.height * scale;
    return .{ .x = box.x + (box.width - width) / 2, .y = box.y + (box.height - height) / 2, .width = width, .height = height };
}

/// Record a picture node: its semantics, then its pixels on a window
/// frame. Other recording targets only see where it is.
pub fn paint(v: *const View, target: anytype, node: *const Node, theme: view.Theme) !void {
    const graphic = node.graphic.?;
    const bounds = node.bounds;
    if (@TypeOf(target) != *ui.Frame) return target.graphic(node.kind, node.id, bounds);
    if (!graphic.decorative and node.style.name.len > 0) try target.semantic(.{ .id = node.id, .parent = node.semantic_parent, .role = .image, .name = node.style.name, .bounds = bounds, .read_only = true });
    if (!(bounds.width > 0 and bounds.height > 0)) return;
    const color = ui.Color.rgb(node.style.color orelse if (node.style.enabled) theme.palette.text else theme.palette.disabled_text);
    switch (graphic.source) {
        .bitmap => |picture| {
            if (graphic.fit == .none) {
                try target.pushClip(bounds);
                defer target.popClip() catch {};
                return target.image(fitted(bounds, graphic.natural, .none), picture, .{});
            }
            try target.image(bounds, picture, .{ .fit = switch (graphic.fit) {
                .contain => .contain,
                .cover => .cover,
                .fill, .none => .stretch,
            } });
        },
        .svg => |picture| {
            const destination = fitted(bounds, graphic.natural, graphic.fit);
            const crops = destination.width > bounds.width + 0.01 or destination.height > bounds.height + 0.01;
            if (crops) try target.pushClip(bounds);
            defer if (crops) target.popClip() catch {};
            try picture.paint(picture.context, target, destination, color);
        },
        .icon => |which| {
            const painter = v.icons orelse return;
            // The icon stays square, centered in its box.
            const side = @min(bounds.width, bounds.height);
            const square: Rect = .{ .x = bounds.x + (bounds.width - side) / 2, .y = bounds.y + (bounds.height - side) / 2, .width = side, .height = side };
            try painter.paint(painter.context, target, which, square, color, graphic.mirrored);
        },
    }
}

test "fit modes" {
    const box: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 50 };
    const natural: Size = .{ .width = 20, .height = 20 };
    try std.testing.expectEqual(Rect{ .x = 25, .y = 0, .width = 50, .height = 50 }, fitted(box, natural, .contain));
    try std.testing.expectEqual(Rect{ .x = 0, .y = -25, .width = 100, .height = 100 }, fitted(box, natural, .cover));
    try std.testing.expectEqual(box, fitted(box, natural, .fill));
    try std.testing.expectEqual(Rect{ .x = 40, .y = 15, .width = 20, .height = 20 }, fitted(box, natural, .none));
}
