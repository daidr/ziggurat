const std = @import("std");
const v = @import("ziggurat_vector");
const pre = @import("prepare.zig");
const d = @import("document.zig");
const n = @import("numbers.zig");
const styles = @import("style.zig");
const shapes = @import("shape.zig");
const refs = @import("references.zig");
const keys = [_][]const u8{ "x", "y", "width", "height", "patternUnits", "patternContentUnits", "patternTransform", "viewBox", "preserveAspectRatio" };

fn objectUnits(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "objectBoundingBox")) return true;
    if (std.mem.eql(u8, value, "userSpaceOnUse")) return false;
    return error.UnsupportedPatternUnits;
}

pub fn validateNode(node: d.Node) !void {
    _ = try objectUnits(node.attribute("patternUnits") orelse "objectBoundingBox");
    _ = try objectUnits(node.attribute("patternContentUnits") orelse "userSpaceOnUse");
    if (node.attribute("transform") != null) return error.UnsupportedPatternTransform;
    for ([_][]const u8{ "width", "height" }) |key| if (try shapes.coordinate(node, key, 0, 1) < 0) return error.InvalidPatternSize;
}

// Borrowed source slices only. Attributes select the nearest definition;
// cloned child content inherits the referencing pattern's computed style.
const Template = struct {
    attributes: [keys.len]?[]const u8 = @splat(null),
    content: ?usize = null,
    fn node(self: *const Template, storage: *[keys.len]d.Attribute) d.Node {
        var count: usize = 0;
        for (keys, self.attributes) |key, value| if (value) |text| {
            storage[count] = .{ .name = key, .value = text };
            count += 1;
        };
        return .{ .kind = .element, .name = "pattern", .attributes = storage[0..count] };
    }
};
fn resolve(work: *pre.Work, index: usize) !Template {
    var result: Template = .{};
    var chain: [32]usize = undefined;
    var count: usize = 0;
    var at = index;
    while (true) {
        try work.visit();
        if (count == chain.len or (count != 0 and count > work.options.limits.reference_depth -| (work.reference_depth + 1))) return error.ReferenceDepthFull;
        for (chain[0..count]) |previous| if (previous == at) return error.ReferenceCycle;
        chain[count] = at;
        count += 1;
        const current = work.document.nodes[at];
        if (!std.mem.eql(u8, try pre.localName(work.document.nodes, at), "pattern")) return error.UnsupportedPatternTemplate;
        try work.parse_work.node(current);
        for (keys, 0..) |key, i| if (result.attributes[i] == null) {
            result.attributes[i] = current.attribute(key);
        };
        if (result.content == null) {
            var child = current.first_child;
            while (child) |child_index| {
                try work.visit();
                const value = work.document.nodes[child_index];
                child = value.next_sibling;
                if (value.kind == .text) {
                    if (std.mem.trim(u8, value.text, " \t\r\n").len != 0) return error.UnsupportedPatternContent;
                    continue;
                }
                if (!pre.oneOf(try pre.localName(work.document.nodes, child_index), &.{ "title", "desc", "metadata" })) {
                    result.content = at;
                    break;
                }
            }
        }
        if (current.attribute("href") == null and current.attribute("xlink:href") == null) break;
        at = work.references.?.find(try refs.href(work.document.nodes, at)) orelse return error.ReferenceNotFound;
    }
    return result;
}

fn validateChildren(work: *pre.Work, index: usize, parent: styles.Style) anyerror!void {
    var child = work.document.nodes[index].first_child;
    while (child) |at| {
        try work.visit();
        const node = work.document.nodes[at];
        child = node.next_sibling;
        if (node.kind == .text) {
            if (std.mem.trim(u8, node.text, " \t\r\n").len != 0) return error.UnsupportedPatternContent;
            continue;
        }
        const name = try pre.localName(work.document.nodes, at);
        if (pre.oneOf(name, &.{ "title", "desc", "metadata" })) continue;
        if (!pre.oneOf(name, &.{ "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon" })) return error.UnsupportedPatternContent;
        try work.parse_work.node(node);
        const style = try work.sheet.?.derive(parent, node, name, &work.style_work);
        if (@import("marker.zig").enabled(style) or style.fill == .reference or style.stroke == .reference or style.clip_path != null or style.mask != null) return error.UnsupportedPatternPaintServer;
        if (style.stroke_width.percent or style.dash_offset.percent) return error.UnsupportedPatternPercentage;
        for (style.dash_values[0..style.dash_count]) |dash| if (dash.percent) return error.UnsupportedPatternPercentage;
        for (node.attributes) |attribute| if (pre.oneOf(attribute.name, &.{ "x", "y", "width", "height", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry" }) and std.mem.indexOfScalar(u8, attribute.value, '%') != null) return error.UnsupportedPatternPercentage;
        try validateChildren(work, at, style);
    }
}

pub const Plan = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    transform: v.Transform,
    content_transform: v.Transform,
    content_follows_grid: bool,
    content_viewport: shapes.Viewport,
    content: usize,
    style: styles.Style,
};
pub const Grid = struct {
    definition: Plan,
    first_col: i64,
    first_row: i64,
    cols: usize,
    rows: usize,
    pub fn frame(self: Grid, parent: pre.Frame, col: usize, row: usize) !struct { value: pre.Frame, box: pre.Box, clip_matrix: v.Transform } {
        const definition = self.definition;
        const ix = self.first_col + @as(i64, @intCast(col));
        const iy = self.first_row + @as(i64, @intCast(row));
        const x = @mulAdd(f64, @as(f64, @floatFromInt(ix)), definition.width, definition.x);
        const y = @mulAdd(f64, @as(f64, @floatFromInt(iy)), definition.height, definition.y);
        const right = @mulAdd(f64, @as(f64, @floatFromInt(ix + 1)), definition.width, definition.x);
        const bottom = @mulAdd(f64, @as(f64, @floatFromInt(iy + 1)), definition.height, definition.y);
        if (!(right > x and bottom > y)) return error.UnsupportedPatternPrecision;
        var result = parent;
        result.style = definition.style;
        result.samples = null;
        result.viewport = definition.content_viewport;
        const tile = (v.Transform{ .x0 = x, .y0 = y }).then(definition.transform);
        const content = if (definition.content_follows_grid) definition.content_transform.then(tile) else value: {
            var matrix = definition.content_transform;
            matrix.x0 = tile.x0;
            matrix.y0 = tile.y0;
            break :value matrix;
        };
        result.prepend(content);
        try result.matrix.validate();
        const clip_matrix = tile.then(parent.matrix);
        try clip_matrix.validate();
        return .{ .value = result, .box = .{ .width = right - x, .height = bottom - y }, .clip_matrix = clip_matrix };
    }
};

// Resolve and reject coordinate policy before creating scene geometry. The
// target Path/cells already exist; only a necessary local BBox query is made.
pub noinline fn plan(work: *pre.Work, index: usize, frame: pre.Frame, path: *v.Path, bounds_work: *pre.Work) !?Plan {
    if (work.reference_depth == work.options.limits.reference_depth) return error.ReferenceDepthFull;
    const template = try resolve(work, index);
    var attributes: [keys.len]d.Attribute = undefined;
    const node = template.node(&attributes);
    const style = try work.computed(index);
    if (!style.overflow_hidden or style.overflow_scrollable) return error.UnsupportedPatternOverflow;
    if (style.opacity != 1 or style.clip_path != null or style.mask != null) return error.UnsupportedPatternStyle;
    const content = template.content orelse return null;
    const grid_object = try objectUnits(node.attribute("patternUnits") orelse "objectBoundingBox");
    const has_viewbox = node.attribute("viewBox") != null;
    const content_object = !has_viewbox and try objectUnits(node.attribute("patternContentUnits") orelse "userSpaceOnUse");
    const pattern_transform = if (node.attribute("patternTransform")) |text| try n.transform(text) else v.Transform{};
    // The two unresolved coordinate combinations are one early policy gate,
    // rather than per-tile guesses. No content geometry has been expanded.
    if (!has_viewbox and grid_object != content_object and !std.meta.eql(pattern_transform, v.Transform{})) return error.UnsupportedPatternCoordinateSpace;
    const reference: shapes.Viewport = if (grid_object) .{ .width = 1, .height = 1 } else frame.viewport;
    const width = try shapes.coordinate(node, "width", 0, reference.width);
    const height = try shapes.coordinate(node, "height", 0, reference.height);
    if (width == 0 or height == 0) return null;
    var bbox: v.Transform = .{};
    if (grid_object or content_object) {
        const object = try bounds_work.paintBounds(path);
        if (object.unsupported) return error.UnsupportedTextBoundingBox;
        const box = object.value orelse return null;
        if (box.width == 0 or box.height == 0) return null;
        bbox = .{ .xx = box.width, .yy = box.height, .x0 = box.x, .y0 = box.y };
    }
    if (has_viewbox and grid_object and bbox.xx != bbox.yy and !std.mem.eql(u8, std.mem.trim(u8, node.attribute("preserveAspectRatio") orelse "xMidYMid meet", " \t\r\n"), "none")) return error.UnsupportedPatternCoordinateSpace;
    try validateChildren(work, content, style);
    const x = try shapes.coordinate(node, "x", 0, reference.width);
    const y = try shapes.coordinate(node, "y", 0, reference.height);
    const transform = pattern_transform.then(if (grid_object) bbox else .{});
    var content_viewport = if (content_object) shapes.Viewport{ .width = 1, .height = 1 } else frame.viewport;
    const content_transform = if (has_viewbox) value: {
        const box = try pre.viewport(node, width, height);
        if (box.width == 0 or box.height == 0) return null;
        content_viewport = .{ .width = box.width, .height = box.height };
        break :value try pre.viewTransform(box, node, width, height);
    } else pattern_transform.then(if (content_object) bbox else .{});
    return .{ .x = x, .y = y, .width = width, .height = height, .transform = transform, .content_transform = content_transform, .content_follows_grid = has_viewbox, .content_viewport = content_viewport, .content = content, .style = style };
}
// All floor conversions, signed subtraction and tile products are checked
// before iteration. A tiny period or huge inverse shear never starts a loop.
pub noinline fn grid(work: *pre.Work, definition: Plan, frame: pre.Frame, output: ?v.Bounds) !?Grid {
    const matrix = definition.transform.then(frame.matrix);
    if (!pre.nonsingular(matrix)) return null;
    const determinant = matrix.xx * matrix.yy - matrix.xy * matrix.yx;
    if (determinant == 0) return error.UnsupportedPatternPrecision;
    const inverse: v.Transform = .{ .xx = matrix.yy / determinant, .xy = -matrix.xy / determinant, .yx = -matrix.yx / determinant, .yy = matrix.xx / determinant, .x0 = (matrix.xy * matrix.y0 - matrix.yy * matrix.x0) / determinant, .y0 = (matrix.yx * matrix.x0 - matrix.xx * matrix.y0) / determinant };
    inline for (std.meta.fields(v.Transform)) |field| if (!std.math.isFinite(@field(inverse, field.name)) or @abs(@field(inverse, field.name)) > 1e15) return error.UnsupportedPatternPrecision;
    const bounds = output orelse return null;
    const left = @max(0, bounds.x);
    const top = @max(0, bounds.y);
    const right = @min(@as(f64, @floatFromInt(work.options.width)), bounds.x + bounds.width);
    const bottom = @min(@as(f64, @floatFromInt(work.options.height)), bounds.y + bounds.height);
    if (right <= left or bottom <= top) return null;
    var min_x = std.math.inf(f64);
    var min_y = std.math.inf(f64);
    var max_x = -std.math.inf(f64);
    var max_y = -std.math.inf(f64);
    for ([_]v.Point{ .{ .x = left, .y = top }, .{ .x = right, .y = top }, .{ .x = left, .y = bottom }, .{ .x = right, .y = bottom } }) |corner| {
        const point = inverse.apply(corner);
        min_x = @min(min_x, point.x);
        min_y = @min(min_y, point.y);
        max_x = @max(max_x, point.x);
        max_y = @max(max_y, point.y);
    }
    const columns = try range(min_x, max_x, definition.x, definition.width);
    const rows = try range(min_y, max_y, definition.y, definition.height);
    const remaining: u64 = work.options.limits.node_visits -| work.node_visits;
    if (columns.count > remaining or rows.count > remaining or (rows.count != 0 and columns.count > remaining / rows.count)) return error.NodeWorkExceeded;
    if (columns.count == 0 or rows.count == 0) return error.UnsupportedPatternPrecision;
    const result: Grid = .{ .definition = definition, .first_col = columns.first, .first_row = rows.first, .cols = @intCast(columns.count), .rows = @intCast(rows.count) };
    // Linear extrema occur at these corners. Check finite, progressing tile
    // coordinates and composed transforms before the first candidate is built.
    _ = try result.frame(frame, 0, 0);
    _ = try result.frame(frame, result.cols - 1, 0);
    _ = try result.frame(frame, 0, result.rows - 1);
    _ = try result.frame(frame, result.cols - 1, result.rows - 1);
    return result;
}
fn range(minimum: f64, maximum: f64, origin: f64, period: f64) !struct { first: i64, count: u64 } {
    const first = @floor((minimum - origin) / period);
    const last = @ceil((maximum - origin) / period);
    if (!std.math.isFinite(first) or !std.math.isFinite(last) or @abs(first) > 0x1p40 or @abs(last) > 0x1p40 or last < first) return error.UnsupportedPatternPrecision;
    const begin: i64 = @intFromFloat(first);
    const end: i64 = @intFromFloat(last);
    return .{ .first = begin, .count = @intCast(end - begin) };
}
test "pattern planning costs remain explicit conditional values" {
    const PreviousGrid = struct {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        first_col: i64,
        first_row: i64,
        cols: usize,
        rows: usize,
        transform: v.Transform,
        style: styles.Style,
    };
    std.debug.print("pattern_sizes grid={d} old_grid={d} plan={d} template={d} attr_scratch={d} chain={d} style={d} frame={d} work={d} options={d} prepared={d}\n", .{ @sizeOf(Grid), @sizeOf(PreviousGrid), @sizeOf(Plan), @sizeOf(Template), @sizeOf([keys.len]d.Attribute), @sizeOf([32]usize), @sizeOf(styles.Style), @sizeOf(pre.Frame), @sizeOf(pre.Work), @sizeOf(pre.Options), @sizeOf(pre.Prepared) });
}
