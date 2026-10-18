const std = @import("std");
const pre = @import("prepare.zig");
const n = @import("numbers.zig");
const styles = @import("style.zig");
const text = @import("text.zig");
const painting = @import("text_paint.zig");
const path_text = @import("text_path.zig");

pub const Position = struct { x: ?f64 = null, y: ?f64 = null, dx: f64 = 0, dy: f64 = 0, rotate: f64 = 0 };
pub const Chunk = struct { start: usize, end: usize, position: Position, adjusted: bool = false };
pub const Character = struct { start: usize, end: usize, dx: f64 = 0, dy: f64 = 0, rotate: f64 = 0 };
const Range = struct { start: usize = 0, len: usize = 0 };
const Element = struct { parent: ?usize, count: usize = 0, lists: [5]Range = @splat(.{}) };

/// Preparation-only, owning normalized Unicode scalar and positioning model.
/// One chunk is one independent shaping request; tspan markup alone never
/// introduces a chunk. All allocations use the scene's accountable allocator.
pub const Plan = struct {
    allocator: std.mem.Allocator,
    source: std.ArrayList(u8) = .empty,
    chunks: std.ArrayList(Chunk) = .empty,
    character_count: usize = 0,
    text_length: ?f64 = null,
    spacing_length: bool = false,
    viewport: @import("shape.zig").Viewport,
    elements: std.ArrayList(Element) = .empty,
    values: std.ArrayList(n.Length) = .empty,
    pending_space: ?usize = null,
    pending_fill: painting.Fill = .{ .paint = .none, .opacity = 1 },
    first_fill: ?painting.Fill = null,
    paints: std.ArrayList(painting.Run) = .empty,
    source_limit: ?usize = null,
    position_count: usize = 0,
    characters: std.ArrayList(Character) = .empty,
    path_node: ?usize = null,
    route: ?*path_text.Route = null,
    explicit_positioning: bool = false,

    pub fn deinit(self: *Plan) void {
        if (self.route) |route| route.close();
        self.source.deinit(self.allocator);
        self.chunks.deinit(self.allocator);
        self.elements.deinit(self.allocator);
        self.values.deinit(self.allocator);
        self.characters.deinit(self.allocator);
        self.paints.deinit(self.allocator);
    }
    pub fn build(cache: anytype, allocator: std.mem.Allocator, index: usize, frame: pre.Frame) !Plan {
        return buildBounded(cache, allocator, index, frame, null);
    }
    /// A mapped cache hit already owns this normalized source. The temporary
    /// revalidation may use exactly that many bytes, without claiming another
    /// persistent source entry from the scene's source_bytes allowance.
    pub fn buildCached(cache: anytype, allocator: std.mem.Allocator, index: usize, frame: pre.Frame, source_bytes: usize) !Plan {
        return buildBounded(cache, allocator, index, frame, source_bytes);
    }
    fn buildBounded(cache: anytype, allocator: std.mem.Allocator, index: usize, frame: pre.Frame, source_limit: ?usize) !Plan {
        var plan: Plan = .{ .allocator = allocator, .viewport = frame.viewport, .source_limit = source_limit };
        errdefer plan.deinit();
        try plan.walk(cache, index, null, frame.style, frame, 0, false);
        if (plan.path_node) |at| {
            if (plan.explicit_positioning or plan.text_length != null) return error.UnsupportedTextPathPositioning;
            if (plan.chunks.items.len != 1) return error.UnsupportedTextPathChunks;
            plan.route = try path_text.Route.create(cache, allocator, at);
            var source_at: usize = 0;
            try cache.charge(plan.source.items.len);
            while (source_at < plan.source.items.len) {
                const len = try std.unicode.utf8ByteSequenceLength(plan.source.items[source_at]);
                try plan.characters.append(allocator, .{ .start = source_at, .end = source_at + len });
                source_at += len;
            }
            plan.chunks.items[0].adjusted = true;
        }
        if (plan.mixedPaint()) {
            if (plan.chunks.items.len != 1) return error.UnsupportedTextPaintChunks;
            if (plan.text_length != null and !plan.spacing_length) {
                const position = plan.chunks.items[0].position;
                if (plan.characters.items.len != 0 or position.dx != 0 or position.dy != 0) return error.UnsupportedTextLengthPositioning;
            }
            for (plan.paints.items) |run| if (!run.fill.solid()) return error.UnsupportedTextPaintServer;
        }
        if (plan.text_length != null and plan.chunks.items.len > 1) return error.UnsupportedTextLengthChunks;
        if (plan.characters.items.len != 0) {
            if (plan.text_length != null and !plan.spacing_length) return error.UnsupportedTextLengthPositioning;
            if (plan.chunks.items.len != 1) return error.UnsupportedTextPositionChunks;
            var chars = std.unicode.Utf8View.initUnchecked(plan.source.items).iterator();
            while (chars.nextCodepoint()) |cp| if (cp == 0xad or cp == 0x61c or cp == 0x200e or cp == 0x200f or (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069)) return error.UnsupportedTextPositionControls;
        }
        return plan;
    }
    pub fn mixedPaint(self: *const Plan) bool {
        return self.paints.items.len != 0;
    }
    fn walk(self: *Plan, cache: anytype, index: usize, parent: ?usize, inherited: styles.Style, frame: pre.Frame, depth: usize, on_path: bool) anyerror!void {
        if (depth == 64) return error.RenderDepthFull;
        try cache.work.visit();
        try cache.work.check();
        const node = cache.work.document.nodes[index];
        if (node.kind == .text) {
            var fill = painting.Fill.from(inherited);
            if (fill.paint == .reference) try cache.charge(fill.paint.reference.id.len);
            // Canonicalize once per text node. Equal paint-server ids must
            // not require another potentially long comparison per scalar.
            if (self.first_fill) |first| if (painting.Fill.same(first, fill)) {
                fill = first;
            };
            var at: usize = 0;
            while (at < node.text.len) {
                const length = try std.unicode.utf8ByteSequenceLength(node.text[at]);
                const bytes = node.text[at..][0..length];
                const scalar = try std.unicode.utf8Decode(bytes);
                if (!on_path and self.path_node != null and (inherited.preserve_space or !std.ascii.isWhitespace(node.text[at]))) return error.UnsupportedTextPathContents;
                try cache.charge(length);
                if (scalar == '\r') return error.UnsupportedTextWhitespace;
                if (inherited.preserve_space) {
                    try self.flushSpace(cache);
                    try self.emit(cache, if (scalar == '\n' or scalar == '\t') " " else bytes, parent.?, fill);
                } else if (scalar == '\n') {} else if (scalar == ' ' or scalar == '\t') {
                    if (self.source.items.len != 0 and self.pending_space == null) {
                        self.pending_space = parent;
                        self.pending_fill = fill;
                    }
                } else {
                    try self.flushSpace(cache);
                    try self.emit(cache, bytes, parent.?, fill);
                }
                at += length;
            }
            return;
        }
        const root = parent == null;
        const name = try pre.localName(cache.work.document.nodes, index);
        const is_path = std.mem.eql(u8, name, "textPath");
        if (!std.mem.eql(u8, name, if (root) "text" else "tspan") and !(is_path and !root)) return error.UnsupportedTextChildren;
        try cache.work.parse_work.node(node);
        const style = if (root) inherited else try cache.work.sheet.?.derive(inherited, node, name, &cache.work.style_work);
        if (!style.displayed) return;
        if (is_path) {
            if (on_path or self.path_node != null or self.source.items.len != 0 or parent.? != 0) return error.UnsupportedTextPathContents;
            self.path_node = index;
            for ([_][]const u8{ "method", "spacing" }, [_][]const u8{ "align", "exact" }) |key, accepted| if (node.attribute(key)) |value| {
                try cache.charge(value.len);
                if (!std.mem.eql(u8, std.mem.trim(u8, value, " \t\r\n"), accepted)) return error.UnsupportedTextPathMethod;
            };
        }
        const desired = node.attribute("textLength");
        const adjustment_source = node.attribute("lengthAdjust");
        const adjustment = if (adjustment_source) |value| std.mem.trim(u8, value, " \t\r\n") else null;
        if (!root and (desired != null or adjustment != null)) return error.UnsupportedTextSpanLength;
        if (adjustment_source) |value| try cache.charge(value.len);
        if (adjustment) |value| {
            if (!std.mem.eql(u8, value, "spacing") and !std.mem.eql(u8, value, "spacingAndGlyphs")) return error.InvalidTextLengthAdjust;
        }
        if (desired) |value| {
            try cache.charge(value.len);
            const length = try n.length(value);
            if (length.value < 0) return error.InvalidTextLength;
            if (length.percent) return error.UnsupportedTextLengthPercent;
            self.text_length = length.value;
            self.spacing_length = adjustment == null or std.mem.eql(u8, adjustment.?, "spacing");
        }
        if (!root) {
            if (!sameStrokeAndMetrics(frame.style, style) or style.opacity != 1 or style.clip_path != null or style.mask != null or style.overflow_hidden or style.vector_effect != .none or node.attribute("transform") != null) return error.UnsupportedTextSpanStyle;
            const root_fill = painting.Fill.from(frame.style);
            const span_fill = painting.Fill.from(style);
            if (!painting.Fill.same(root_fill, span_fill) and (!root_fill.solid() or !span_fill.solid())) return error.UnsupportedTextPaintServer;
        }
        if (self.elements.items.len == cache.work.document.nodes.len) return error.TextCapacityExceeded;
        const element = self.elements.items.len;
        try self.elements.append(self.allocator, .{ .parent = parent });
        for ([_][]const u8{ "x", "y", "dx", "dy" }, 0..) |key, axis| if (node.attribute(key)) |value| {
            self.explicit_positioning = true;
            try cache.charge(value.len);
            self.elements.items[element].lists[axis] = try self.lengths(cache, value);
        };
        if (node.attribute("rotate")) |value| {
            self.explicit_positioning = true;
            try cache.charge(value.len);
            var list: n.List = .{ .scan = .{ .input = value } };
            var count: usize = 0;
            while (try list.next()) |angle| {
                if (self.position_count == cache.work.options.limits.text.position_values -| cache.position_values) return error.TextPositionsFull;
                count += 1;
                self.position_count += 1;
                try self.values.append(self.allocator, .{ .value = angle, .percent = false });
            }
            if (count == 0) return error.InvalidNumber;
            self.elements.items[element].lists[4] = .{ .start = self.values.items.len - count, .len = count };
        }
        var child = node.first_child;
        while (child) |at| {
            try self.walk(cache, at, element, style, frame, depth + 1, on_path or is_path);
            child = cache.work.document.nodes[at].next_sibling;
        }
    }
    fn lengths(self: *Plan, cache: anytype, source: []const u8) !Range {
        const start = self.values.items.len;
        var scan: n.Scanner = .{ .input = source };
        var first = true;
        while (true) {
            const spaced = scan.space();
            if (scan.at == source.len) break;
            if (!first) {
                if (source[scan.at] == ',') {
                    scan.at += 1;
                    _ = scan.space();
                    if (scan.at == source.len) return error.InvalidLength;
                } else if (!spaced) return error.NumberSeparatorRequired;
            }
            const begin = scan.at;
            _ = try scan.number();
            while (scan.at < source.len and (std.ascii.isAlphabetic(source[scan.at]) or source[scan.at] == '%')) scan.at += 1;
            const value = try n.length(source[begin..scan.at]);
            if (self.position_count == cache.work.options.limits.text.position_values -| cache.position_values) return error.TextPositionsFull;
            try self.values.append(self.allocator, value);
            self.position_count += 1;
            first = false;
        }
        if (first) return error.InvalidLength;
        return .{ .start = start, .len = self.values.items.len - start };
    }
    fn flushSpace(self: *Plan, cache: anytype) !void {
        if (self.pending_space) |element| {
            self.pending_space = null;
            try self.emit(cache, " ", element, self.pending_fill);
        }
    }
    fn emit(self: *Plan, cache: anytype, bytes: []const u8, element_index: usize, fill: painting.Fill) !void {
        const limits = cache.work.options.limits.text;
        if (self.character_count == limits.characters -| cache.characters) return error.TextCharactersFull;
        if (bytes.len > (self.source_limit orelse (limits.source_bytes -| cache.source_bytes)) -| self.source.items.len) return error.TextSourceExceeded;
        var position: Position = .{};
        var selected: [5]bool = @splat(false);
        var element: ?usize = element_index;
        while (element) |at| {
            try cache.charge(1);
            const current = &self.elements.items[at];
            for (current.lists, 0..) |list, axis| if (!selected[axis] and list.len != 0 and (current.count < list.len or axis == 4)) {
                const value = try self.values.items[list.start + @min(current.count, list.len - 1)].resolve(if (axis == 0 or axis == 2) self.viewport.width else self.viewport.height);
                switch (axis) {
                    0 => position.x = value,
                    1 => position.y = value,
                    2 => position.dx = value,
                    3 => position.dy = value,
                    4 => position.rotate = if (@rem(value, 360) == 0) 0 else value,
                    else => unreachable,
                }
                selected[axis] = true;
            };
            current.count += 1;
            element = current.parent;
        }
        const start = self.source.items.len;
        if (self.first_fill) |first| {
            if (self.paints.items.len == 0 and !painting.Fill.same(first, fill)) {
                if (limits.paint_runs -| cache.paint_runs < 2) return error.TextPaintRunsFull;
                try self.paints.append(self.allocator, .{ .start = 0, .end = start, .fill = first });
            }
        } else self.first_fill = fill;
        if (self.paints.items.len != 0) {
            const previous = &self.paints.items[self.paints.items.len - 1];
            if (painting.Fill.same(previous.fill, fill)) previous.end = start + bytes.len else {
                if (self.paints.items.len == limits.paint_runs -| cache.paint_runs) return error.TextPaintRunsFull;
                try self.paints.append(self.allocator, .{ .start = start, .end = start + bytes.len, .fill = fill });
            }
        }
        const new_chunk = self.character_count == 0 or position.x != null or position.y != null;
        const adjusted = self.spacing_length or position.rotate != 0 or (!new_chunk and (position.dx != 0 or position.dy != 0));
        if (adjusted and self.characters.items.len == 0) {
            try cache.charge(start);
            // Before the first adjustment every previous scalar had zero
            // relative adjustment except its already-positioned chunk start.
            var at: usize = 0;
            while (at < start) {
                const len = try std.unicode.utf8ByteSequenceLength(self.source.items[at]);
                try self.characters.append(self.allocator, .{ .start = at, .end = at + len });
                at += len;
            }
        }
        if (adjusted or self.characters.items.len != 0) try self.characters.append(self.allocator, .{ .start = start, .end = start + bytes.len, .dx = if (new_chunk) 0 else position.dx, .dy = if (new_chunk) 0 else position.dy, .rotate = position.rotate });
        if (new_chunk) {
            if (self.chunks.items.len == limits.chunks -| cache.chunks) return error.TextChunksFull;
            try self.chunks.append(self.allocator, .{ .start = start, .end = start + bytes.len, .position = position, .adjusted = adjusted });
        } else {
            self.chunks.items[self.chunks.items.len - 1].end = start + bytes.len;
            self.chunks.items[self.chunks.items.len - 1].adjusted = self.chunks.items[self.chunks.items.len - 1].adjusted or adjusted;
        }
        try self.source.appendSlice(self.allocator, bytes);
        self.character_count += 1;
    }
};

/// Paint-only fill changes are distinct from metrics and the common stroke.
/// Resolve inherited currentColor before comparing that stroke; a color
/// change cannot quietly give a child a different whole-text stroke.
pub fn sameStrokeAndMetrics(a: styles.Style, b: styles.Style) bool {
    var comparable = b;
    if (!painting.samePaint(painting.resolved(a.stroke, a.color), painting.resolved(b.stroke, b.color))) return false;
    comparable.fill = a.fill;
    comparable.color = a.color;
    comparable.fill_opacity = a.fill_opacity;
    comparable.stroke = a.stroke;
    return sameInherited(a, comparable);
}

/// Only these inherited properties affect this single-style text submodel.
/// Own effects remain on the text graphics element; tspan own effects reject.
pub fn sameInherited(a: styles.Style, b: styles.Style) bool {
    if (!std.meta.eql(a.paint_order, b.paint_order)) return false;
    if (!text.sameFont(a.font, b.font) or a.text_anchor != b.text_anchor or a.visible != b.visible or !std.meta.eql(a.fill, b.fill) or !std.meta.eql(a.stroke, b.stroke) or !std.meta.eql(a.color, b.color) or a.fill_opacity != b.fill_opacity or a.stroke_opacity != b.stroke_opacity or a.rule != b.rule or !std.meta.eql(a.stroke_options, b.stroke_options) or !std.meta.eql(a.stroke_width, b.stroke_width) or !std.meta.eql(a.dash_offset, b.dash_offset) or a.dash_count != b.dash_count or a.interpolation != b.interpolation or a.clip_rule != b.clip_rule) return false;
    for (a.dash_values[0..a.dash_count], b.dash_values[0..b.dash_count]) |av, bv| if (!std.meta.eql(av, bv)) return false;
    return true;
}
