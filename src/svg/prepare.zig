const std = @import("std");
const v = @import("ziggurat_vector");
const drawing = @import("ziggurat_drawing_resources");
const d = @import("document.zig");
const n = @import("numbers.zig");
const shapes = @import("shape.zig");
const styles = @import("style.zig");
const paints = @import("paint.zig");
const css = @import("css.zig");
const refs = @import("references.zig");
const gradients = @import("gradient.zig");
const parsing = @import("parse_work.zig");
const text_support = @import("text.zig");
const TextCache = @import("text_cache.zig").Cache;
const images = @import("image.zig");
const Resources = @import("prepare_resources.zig").Resources;
const markers = @import("marker.zig");
pub const Limits = struct {
    bytes: usize = 64 * 1024 * 1024,
    layers: usize = 8,
    /// Physical-pixel visits; sample_color counts paint stripes, mask resolve
    /// and output resolve. The pixel mode counts its whole-plane passes.
    pixel_work: u64 = 128 * 1024 * 1024,
    /// u16 coverage writes: clears, copies, OR/AND and geometry's conservative
    /// reservation of seventeen writes per output pixel.
    sample_work: u64 = 128 * 1024 * 1024,
    /// The following three budgets apply to sample_color. One color operation
    /// processes one four-channel f64 lane; sorting counts comparisons.
    color_work: u64 = 128 * 1024 * 1024,
    scene_work: u64 = 128 * 1024 * 1024,
    sort_work: u64 = 512 * 1024 * 1024,
    styles: css.Limits = .{},
    style_work: u64 = 2 * 1024 * 1024,
    parse_work: u64 = 4 * 1024 * 1024,
    node_visits: usize = 65536,
    reference_depth: usize = 16,
    gradient_stops: usize = 32,
    path: v.Limits = .{},
    raster: v.PrepareLimits = .{},
    text: text_support.Limits = .{},
};
pub const Options = struct {
    main_thread: std.Thread.Id,
    width: u32,
    height: u32,
    current_color: paints.Color = .{},
    /// sample_color composites 4x4 geometry lanes before final BGRA8 resolve.
    /// A gradient's color still comes from the physical pixel center. Masks
    /// remain continuous per-pixel alpha images in both modes.
    compositing: enum { pixel, sample_color } = .pixel,
    limits: Limits = .{},
    cancellation: ?*const v.Cancellation = null,
    text_provider: ?text_support.Provider = null,
    /// Captured by value before the first allocator callback.
    image_provider: ?*const images.Provider = null,
};
pub const Stats = struct {
    owned_bytes: usize,
    peak_bytes: usize,
    paths: usize,
    pixel_work: u64,
    sample_work: u64,
    scan_tests: u64,
    stroke_steps: u64,
    vertices: usize,
    edges: usize,
    edge_attempts: u64,
    style_work: u64,
    stylesheet_bytes: usize,
    stylesheet_rules: usize,
    node_visits: usize,
    reference_bytes: usize,
    parse_work: u64,
    color_work: u64 = 0,
    scene_work: u64 = 0,
    sort_work: u64 = 0,
    text_source_bytes: usize = 0,
    text_glyphs: usize = 0,
    text_commands: usize = 0,
    /// Aggregate/paint-part commands per geometry use, including bbox probes,
    /// plus discarded mapping batches. This is the text.commands charge.
    text_accounted_commands: usize = 0,
    text_mapping_requests: usize = 0,
    text_work: u64 = 0,
    text_requests: usize = 0,
    text_characters: usize = 0,
    text_position_values: usize = 0,
    text_chunks: usize = 0,
    /// Mixed-fill parts per geometry use (including bbox probes), separate
    /// from whole-text geometry; not unique Paths or actual draw calls.
    text_paint_runs: usize = 0,
    text_paint_commands: usize = 0,
};
pub const Prepared = struct {
    allocator: std.mem.Allocator,
    lease: drawing.Lease,
    main_thread: std.Thread.Id,
    adopted: bool,
    identity: u64,
    level: drawing.ImageLevel,
    pixels: []u8,
    metrics: Stats,
    closing: bool = false,
    pub fn adopt(self: *Prepared) !void {
        if (std.Thread.getCurrentId() != self.main_thread) return error.WrongThread;
        if (self.closing) return error.Closed;
        if (self.adopted) return error.AlreadyAdopted;
        if (self.lease.pins != 0) return error.ResourceInUse;
        self.lease.owner = self.main_thread;
        self.adopted = true;
    }
    pub fn view(self: *Prepared) !drawing.ImageView {
        try self.lease.checkOwner();
        if (self.closing) return error.Closed;
        if (!self.adopted) return error.NotAdopted;
        return .{ .lease = &self.lease, .identity = self.identity, .levels = @as(*[1]drawing.ImageLevel, @ptrCast(&self.level)) };
    }
    pub fn stats(self: *const Prepared) !Stats {
        try self.lease.checkOwner();
        if (self.closing) return error.Closed;
        return self.metrics;
    }
    pub fn close(self: *Prepared) !void {
        try self.lease.checkOwner();
        if (self.closing) return error.Closed;
        try self.lease.ensureUnused();
        self.closing = true;
        const allocator = self.allocator;
        allocator.free(self.pixels);
        allocator.destroy(self);
    }
};
pub const Box = struct { x: f64 = 0, y: f64 = 0, width: f64, height: f64 };
pub const Frame = struct {
    matrix: v.Transform,
    /// Present only when the outer svg has its own transform. This mapping
    /// stops at its viewport; matrix additionally includes that outer effect.
    host_matrix: ?v.Transform = null,
    viewport: shapes.Viewport,
    style: styles.Style,
    samples: ?[]const u16 = null,
    pub fn prepend(self: *Frame, transform: v.Transform) void {
        self.matrix = transform.then(self.matrix);
        if (self.host_matrix) |host| self.host_matrix = transform.then(host);
    }
};
pub const Instance = struct { width: ?f64 = null, height: ?f64 = null };
const Clip = struct { box: Box, matrix: v.Transform };
const Mask = struct { pixels: []u8, alpha: bool, interpolation: styles.Interpolation };
// Shared source traversal; only preparation backends import this internal type.
pub const Work = struct {
    allocator_budgeted: bool = false,
    text_cache: ?*TextCache = null,
    resources: ?*Resources = null,
    allocator: std.mem.Allocator,
    document: *const d.State,
    options: Options,
    live: usize,
    peak: usize,
    pixel_work: u64 = 0,
    sample_work: u64 = 0,
    scan_tests: u64 = 0,
    stroke_steps: u64 = 0,
    vertices: usize = 0,
    edges: usize = 0,
    edge_attempts: u64 = 0,
    paths: usize = 0,
    layers: usize = 0,
    sheet: ?*const css.Sheet = null,
    style_work: css.Work,
    parse_work: parsing.Work,
    references: ?*const refs.Index = null,
    node_visits: usize = 0,
    reference_depth: usize = 0,
    active: [64]usize = undefined,
    depth: usize = 0,
    host_output: v.Transform = .{},
    pub fn check(self: *const Work) !void {
        if (self.options.cancellation) |cancel| try cancel.check();
    }
    pub fn closeResources(self: *Work) void {
        if (self.resources) |cache| {
            self.resources = null;
            cache.close();
        }
    }
    pub fn closeText(self: *Work) void {
        if (self.text_cache) |cache| {
            cache.close();
            self.text_cache = null;
        }
    }
    pub fn isTextPath(self: *Work, path: *v.Path) bool {
        return if (self.text_cache) |cache| cache.contains(path) else false;
    }
    pub fn paintBounds(self: *Work, path: *v.Path) !struct { value: ?v.Bounds, unsupported: bool } {
        if (self.text_cache) |cache| if (cache.contains(path)) {
            if (!cache.hasCells(path)) return .{ .value = null, .unsupported = true };
            return .{ .value = try cache.bounds(path, .{}), .unsupported = false };
        };
        return .{ .value = try path.bounds(.{}, self.options.cancellation), .unsupported = false };
    }
    pub fn reserve(self: *Work, bytes: usize) !void {
        if (bytes > self.options.limits.bytes -| self.live) return error.CapacityExceeded;
        self.live += bytes;
        self.peak = @max(self.peak, self.live);
    }
    pub fn chargePixels(self: *Work, count: u64) !void {
        if (count > self.options.limits.pixel_work -| self.pixel_work) return error.PixelWorkExceeded;
        self.pixel_work += count;
    }
    pub fn enter(self: *Work, index: usize) !void {
        try self.visit();
        if (self.depth == self.active.len) return error.RenderDepthFull;
        for (self.active[0..self.depth]) |at| if (at == index) return error.ReferenceCycle;
        self.active[self.depth] = index;
        self.depth += 1;
    }
    pub fn visit(self: *Work) !void {
        try self.check();
        if (self.node_visits == self.options.limits.node_visits) return error.NodeWorkExceeded;
        self.node_visits += 1;
    }
    fn chargeSamples(self: *Work, amount: u64) !void {
        if (amount > self.options.limits.sample_work -| self.sample_work) return error.SampleWorkExceeded;
        self.sample_work += amount;
    }
    fn sampleCount(self: *const Work) usize {
        return @as(usize, (self.options.width + 3) & ~@as(u32, 3)) * self.options.height;
    }
    fn newSamples(self: *Work) ![]u16 {
        const count = self.sampleCount();
        try self.chargeSamples(count);
        try self.reserve(count * 2);
        errdefer self.live -= count * 2;
        const bits = try self.allocator.alloc(u16, count);
        @memset(bits, 0);
        return bits;
    }
    fn freeSamples(self: *Work, bits: []u16) void {
        self.live -= bits.len * 2;
        self.allocator.free(bits);
    }
    fn copySamples(self: *Work, source: []const u16) ![]u16 {
        const bits = try self.newSamples();
        errdefer self.freeSamples(bits);
        try self.chargeSamples(source.len);
        @memcpy(bits, source);
        return bits;
    }
    fn combineSamples(self: *Work, destination: []u16, source: []const u16, union_region: bool) !void {
        std.debug.assert(destination.len == source.len);
        try self.chargeSamples(destination.len);
        for (destination, source, 0..) |*a, b, i| {
            if (i % 256 == 0) try self.check();
            a.* = if (union_region) a.* | b else a.* & b;
        }
    }
    fn releasePath(self: *Work, path: *v.Prepared) void {
        self.live -= (path.stats() catch unreachable).owned_bytes;
        path.close() catch unreachable;
    }
    pub fn validateSource(self: *Work) !void {
        // Validate the whole source before allocating a raster result. Hidden or
        // definition subtrees cannot silently introduce executable/external content.
        for (self.document.nodes, 0..) |node, index| {
            try self.check();
            if (node.kind == .text) continue;
            try self.parse_work.node(node);
            const name = try localName(self.document.nodes, index);
            if (!oneOf(name, &.{ "svg", "g", "defs", "title", "desc", "metadata", "style", "symbol", "use", "linearGradient", "radialGradient", "stop", "clipPath", "mask", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text", "tspan", "textPath", "image", "pattern", "marker" })) return error.UnsupportedElement;
            if (std.mem.eql(u8, name, "pattern")) try @import("pattern.zig").validateNode(node);
            if (std.mem.eql(u8, name, "marker")) try markers.validateNode(node);
            if (std.mem.eql(u8, name, "tspan")) {
                const parent = node.parent orelse return error.InvalidTextSpanParent;
                if (!oneOf(try localName(self.document.nodes, parent), &.{ "text", "tspan", "textPath" })) return error.InvalidTextSpanParent;
            }
            if (std.mem.eql(u8, name, "textPath")) {
                const parent = node.parent orelse return error.InvalidTextPathParent;
                if (!std.mem.eql(u8, try localName(self.document.nodes, parent), "text")) return error.InvalidTextPathParent;
                _ = try refs.href(self.document.nodes, index);
            }
            if (std.mem.eql(u8, name, "image")) {
                _ = try images.href(self.document.nodes, index);
                if (self.options.image_provider == null) return error.ImageProviderRequired;
                var child = node.first_child;
                while (child) |at| {
                    const value = self.document.nodes[at];
                    if (value.kind == .element and !oneOf(try localName(self.document.nodes, at), &.{ "title", "desc", "metadata" })) return error.UnsupportedImageChild;
                    if (value.kind == .text and std.mem.trim(u8, value.text, " \t\r\n").len != 0) return error.UnsupportedImageChild;
                    child = value.next_sibling;
                }
            }
            if (std.mem.eql(u8, name, "text") and self.options.text_provider == null) return error.TextProviderRequired;
            if (std.mem.eql(u8, name, "mask") and node.attribute("transform") != null) return error.UnsupportedMaskTransform;
            if (std.mem.eql(u8, name, "use")) _ = try refs.href(self.document.nodes, index);
            for (node.attributes) |attribute| {
                if (oneOf(attribute.name, &.{ "markerUnits", "markerWidth", "markerHeight", "refX", "refY", "orient" })) {
                    if (!std.mem.eql(u8, name, "marker")) return error.UnsupportedAttribute;
                    continue;
                }
                if (oneOf(attribute.name, &.{ "patternUnits", "patternContentUnits", "patternTransform" })) {
                    if (!std.mem.eql(u8, name, "pattern")) return error.UnsupportedAttribute;
                    continue;
                }
                if (oneOf(attribute.name, &.{ "startOffset", "method", "spacing" })) {
                    if (!std.mem.eql(u8, name, "textPath")) return error.UnsupportedAttribute;
                    continue;
                }
                if (oneOf(attribute.name, &.{ "textLength", "lengthAdjust" })) {
                    if (!oneOf(name, &.{ "text", "tspan" })) return error.UnsupportedAttribute;
                    continue;
                }
                if (std.ascii.startsWithIgnoreCase(attribute.name, "on") or oneOf(attribute.name, &.{"filter"})) return error.UnsupportedFeature;
                if (oneOf(attribute.name, &.{ "href", "xlink:href" })) {
                    if (std.mem.eql(u8, name, "image")) continue;
                    if (!oneOf(name, &.{ "use", "linearGradient", "radialGradient", "textPath", "pattern" })) return error.UnsupportedReference;
                    _ = try refs.href(self.document.nodes, index);
                    continue;
                }
                if (!oneOf(attribute.name, &.{ "id", "class", "style", "type", "role", "version", "xml:lang", "xml:space", "xmlns", "transform", "viewBox", "preserveAspectRatio", "x", "y", "width", "height", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry", "fx", "fy", "fr", "gradientUnits", "gradientTransform", "spreadMethod", "offset", "points", "d", "fill", "stroke", "color", "opacity", "fill-opacity", "stroke-opacity", "fill-rule", "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset", "display", "visibility", "overflow", "stop-color", "stop-opacity", "color-interpolation", "clip-path", "clip-rule", "clipPathUnits", "mask", "mask-type", "maskUnits", "maskContentUnits" }) and
                    styles.property(attribute.name) == null and !oneOf(attribute.name, &.{ "dx", "dy" }) and !(std.mem.eql(u8, attribute.name, "rotate") and oneOf(name, &.{ "text", "tspan" })) and
                    !std.mem.startsWith(u8, attribute.name, "xmlns:") and !std.mem.startsWith(u8, attribute.name, "data-") and !std.mem.startsWith(u8, attribute.name, "aria-")) return error.UnsupportedAttribute;
            }
            for (node.attributes) |attribute| if (styles.property(attribute.name) != null) try self.style_work.charge(attribute.value.len + 1);
            _ = try (styles.Style{}).base(node);
            if (node.attribute("style")) |value| {
                try self.style_work.charge(value.len + 1);
                var declarations: css.Declarations = .{ .input = value };
                while (try declarations.next()) |_| {}
            }
        }
    }
    pub fn computed(self: *Work, index: usize) !styles.Style {
        var ancestors: [64]usize = undefined;
        var count: usize = 0;
        var at: ?usize = index;
        while (at) |node| {
            if (count == ancestors.len) return error.RenderDepthFull;
            ancestors[count] = node;
            count += 1;
            at = self.document.nodes[node].parent;
        }
        var style: styles.Style = .{ .color = self.options.current_color };
        while (count != 0) {
            count -= 1;
            try self.visit();
            const node = self.document.nodes[ancestors[count]];
            try self.parse_work.node(node);
            style = try self.sheet.?.derive(style, node, try localName(self.document.nodes, ancestors[count]), &self.style_work);
        }
        return style;
    }
    pub fn geometry(self: *Work, index: usize, name: []const u8, frame: Frame) !?*v.Path {
        if (std.mem.eql(u8, name, "text")) {
            if (self.text_cache == null) self.text_cache = try TextCache.create(self);
            return try self.text_cache.?.geometry(index, frame);
        }
        var limits = self.options.limits.path;
        limits.bytes = @min(limits.bytes, self.options.limits.bytes -| self.live);
        if (limits.bytes == 0) return error.CapacityExceeded;
        const path = try shapes.path(self.allocator, self.document.nodes[index], name, frame.viewport, limits, self.options.cancellation);
        if (path) |value| {
            errdefer value.close() catch unreachable;
            const bytes = @sizeOf(v.Path) + value.commands.len * @sizeOf(v.Command);
            const extra = if (oneOf(name, &.{ "polygon", "polyline" })) value.commands.len * @sizeOf(v.Command) else 0;
            try self.reserve(bytes + extra);
            self.live -= extra;
        }
        return path;
    }
    pub fn imageSource(self: *Work, index: usize, frame: Frame) !?struct { placement: images.Placement, paint: *const images.Paint } {
        const node = self.document.nodes[index];
        const positioning = try images.box(node, frame.viewport);
        if (!frame.style.overflow_hidden or frame.style.overflow_scrollable) return error.UnsupportedImageOverflow;
        if (positioning.width == 0 or positioning.height == 0 or !nonsingular(frame.matrix)) return null;
        if (self.resources == null) self.resources = try Resources.create(self);
        const cache = self.resources.?;
        const snapshot = try cache.get(try images.href(self.document.nodes, index));
        const placement = (try images.place(node, positioning, snapshot.width, snapshot.height, frame.matrix)) orelse return null;
        return .{ .placement = placement, .paint = try cache.paint(snapshot, placement.inverse) };
    }
    pub fn imageRectangle(self: *Work, box: Box) !*v.Path {
        var limits = self.options.limits.path;
        limits.bytes = @min(limits.bytes, self.options.limits.bytes -| self.live);
        if (limits.bytes == 0) return error.CapacityExceeded;
        const path = try v.Path.create(self.allocator, &.{ .{ .move = .{ .x = box.x, .y = box.y } }, .{ .line = .{ .x = box.x + box.width, .y = box.y } }, .{ .line = .{ .x = box.x + box.width, .y = box.y + box.height } }, .{ .line = .{ .x = box.x, .y = box.y + box.height } }, .close }, limits);
        errdefer path.close() catch unreachable;
        try self.reserve(@sizeOf(v.Path) + path.commands.len * @sizeOf(v.Command));
        return path;
    }
    pub fn validateHiddenText(self: *Work, index: usize, frame: Frame) !void {
        if (self.text_cache == null) self.text_cache = try TextCache.create(self);
        try self.text_cache.?.validateHidden(index, frame);
    }
    pub fn freeGeometry(self: *Work, path: *v.Path) void {
        if (self.isTextPath(path)) return;
        self.live -= @sizeOf(v.Path) + path.commands.len * @sizeOf(v.Command);
        path.close() catch unreachable;
    }
    // Object bounds exclude paint, clipping and opacity. Each expanded visit
    // still consumes the scene's parse/style/node budgets; no hidden cache.
    pub fn localBounds(self: *Work, index: usize, name: []const u8, frame: Frame) anyerror!?v.Bounds {
        try self.visit();
        try self.parse_work.node(self.document.nodes[index]);
        var local = frame;
        local.matrix = .{};
        local.samples = null;
        return self.boundsContents(index, name, local);
    }
    fn boundsContents(self: *Work, index: usize, name: []const u8, frame: Frame) anyerror!?v.Bounds {
        if (std.mem.eql(u8, name, "text")) {
            const path = (try self.geometry(index, name, frame)).?;
            return self.text_cache.?.bounds(path, frame.matrix);
        }
        if (std.mem.eql(u8, name, "use")) {
            const at = self.references.?.find(try refs.href(self.document.nodes, index)) orelse return error.ReferenceNotFound;
            if (self.reference_depth == self.options.limits.reference_depth) return error.ReferenceDepthFull;
            self.reference_depth += 1;
            defer self.reference_depth -= 1;
            return self.boundsInstance(at, frame, try self.useInstance(index, at, frame.viewport));
        }
        if (std.mem.eql(u8, name, "image")) {
            const rectangle = try self.imageRectangle(try images.box(self.document.nodes[index], frame.viewport));
            defer self.freeGeometry(rectangle);
            return try rectangle.bounds(frame.matrix, self.options.cancellation);
        }
        var result: ?v.Bounds = null;
        if (!oneOf(name, &.{ "g", "svg", "symbol", "clipPath", "mask" })) {
            if (try self.geometry(index, name, frame)) |path| {
                defer self.freeGeometry(path);
                result = try path.bounds(frame.matrix, self.options.cancellation);
            }
        }
        var child = self.document.nodes[index].first_child;
        while (child) |at| {
            if (try self.boundsInstance(at, frame, null)) |box| result = unionBounds(result, box);
            child = self.document.nodes[at].next_sibling;
        }
        return result;
    }
    pub fn useInstance(self: *Work, index: usize, at: usize, reference: shapes.Viewport) !?Instance {
        const name = try localName(self.document.nodes, at);
        if (!oneOf(name, &.{ "svg", "symbol", "g", "use", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text", "image" })) return error.UnsupportedReference;
        if (!oneOf(name, &.{ "svg", "symbol" })) return null;
        var result: Instance = .{};
        const node = self.document.nodes[index];
        if (node.attribute("width")) |value| if (!std.mem.eql(u8, value, "auto")) {
            result.width = try (try n.length(value)).resolve(reference.width);
        };
        if (node.attribute("height")) |value| if (!std.mem.eql(u8, value, "auto")) {
            result.height = try (try n.length(value)).resolve(reference.height);
        };
        return result;
    }
    fn boundsInstance(self: *Work, index: usize, parent: Frame, instance: ?Instance) anyerror!?v.Bounds {
        try self.enter(index);
        defer self.depth -= 1;
        const node = self.document.nodes[index];
        if (node.kind == .text) return null;
        const name = try localName(self.document.nodes, index);
        if (oneOf(name, &.{ "defs", "title", "desc", "metadata", "style", "linearGradient", "radialGradient", "stop", "clipPath", "mask" })) return null;
        if (std.mem.eql(u8, name, "symbol") and instance == null) return null;
        try self.parse_work.node(node);
        const style = try self.sheet.?.derive(parent.style, node, name, &self.style_work);
        if (!style.displayed) return null;
        const transform = if (node.attribute("transform")) |source| try n.transform(source) else v.Transform{};
        var frame: Frame = .{ .matrix = transform.then(parent.matrix), .viewport = parent.viewport, .style = style };
        if (std.mem.eql(u8, name, "use")) frame.matrix = (v.Transform{ .x0 = try shapes.coordinate(node, "x", 0, parent.viewport.width), .y0 = try shapes.coordinate(node, "y", 0, parent.viewport.height) }).then(frame.matrix);
        if (oneOf(name, &.{ "svg", "symbol" })) {
            const overrides = instance orelse Instance{};
            const width = overrides.width orelse try dimension(node, "width", parent.viewport.width);
            const height = overrides.height orelse try dimension(node, "height", parent.viewport.height);
            if (width < 0 or height < 0) return error.InvalidViewport;
            if (width == 0 or height == 0) return null;
            const box = try viewport(node, width, height);
            if (box.width == 0 or box.height == 0) return null;
            frame.matrix = (try viewTransform(box, node, width, height)).then(v.Transform{ .x0 = try shapes.coordinate(node, "x", 0, parent.viewport.width), .y0 = try shapes.coordinate(node, "y", 0, parent.viewport.height) }).then(frame.matrix);
            frame.viewport = .{ .width = box.width, .height = box.height };
        }
        try frame.matrix.validate();
        return self.boundsContents(index, name, frame);
    }
    fn clipFor(self: *Work, id: []const u8, target: usize, name: []const u8, frame: Frame) ![]u16 {
        const index = self.references.?.find(id) orelse return error.ReferenceNotFound;
        if (!std.mem.eql(u8, try localName(self.document.nodes, index), "clipPath")) return error.InvalidClipReference;
        const object = std.mem.eql(u8, self.document.nodes[index].attribute("clipPathUnits") orelse "userSpaceOnUse", "objectBoundingBox");
        // User-space clips do not need to re-parse a container's descendants
        // merely to obtain an unused object bounding box.
        return self.clipReference(id, frame, if (object) try self.localBounds(target, name, frame) else null);
    }
    fn clipReference(self: *Work, id: []const u8, target: Frame, bounds: ?v.Bounds) anyerror![]u16 {
        const index = self.references.?.find(id) orelse return error.ReferenceNotFound;
        if (!std.mem.eql(u8, try localName(self.document.nodes, index), "clipPath")) return error.InvalidClipReference;
        if (self.reference_depth == self.options.limits.reference_depth) return error.ReferenceDepthFull;
        self.reference_depth += 1;
        defer self.reference_depth -= 1;
        try self.enter(index);
        defer self.depth -= 1;
        const node = self.document.nodes[index];
        try self.parse_work.node(node);
        const style = try self.computed(index);
        if (style.mask != null) return error.UnsupportedClipContainerEffect;
        const result = try self.newSamples();
        errdefer self.freeSamples(result);
        var frame: Frame = .{ .matrix = target.matrix, .host_matrix = target.host_matrix, .viewport = target.viewport, .style = style };
        const units = node.attribute("clipPathUnits") orelse "userSpaceOnUse";
        if (std.mem.eql(u8, units, "objectBoundingBox")) {
            const box = bounds orelse return result;
            if (box.width == 0 or box.height == 0) return result;
            frame.prepend(.{ .xx = box.width, .yy = box.height, .x0 = box.x, .y0 = box.y });
            frame.viewport = .{ .width = 1, .height = 1 };
        } else if (!std.mem.eql(u8, units, "userSpaceOnUse")) return error.InvalidClipUnits;
        if (node.attribute("transform")) |source| frame.prepend(try n.transform(source));
        try frame.matrix.validate();
        var child = node.first_child;
        while (child) |at| {
            try self.clipChild(at, frame, result);
            child = self.document.nodes[at].next_sibling;
        }
        if (style.clip_path) |nested| {
            const intersection = try self.clipFor(nested, index, "clipPath", frame);
            defer self.freeSamples(intersection);
            try self.combineSamples(result, intersection, false);
        }
        return result;
    }
    fn maskFor(self: *Work, id: []const u8, target: usize, name: []const u8, frame: Frame) !Mask {
        const index = self.references.?.find(id) orelse return error.ReferenceNotFound;
        const node = self.document.nodes[index];
        if (!std.mem.eql(u8, try localName(self.document.nodes, index), "mask")) return error.InvalidMaskReference;
        const object = try objectUnits(node.attribute("maskUnits"), "objectBoundingBox") or try objectUnits(node.attribute("maskContentUnits"), "userSpaceOnUse");
        return self.maskReference(id, frame, if (object) try self.localBounds(target, name, frame) else null);
    }
    fn maskReference(self: *Work, id: []const u8, target: Frame, bounds: ?v.Bounds) anyerror!Mask {
        const index = self.references.?.find(id) orelse return error.ReferenceNotFound;
        if (!std.mem.eql(u8, try localName(self.document.nodes, index), "mask")) return error.InvalidMaskReference;
        if (self.reference_depth == self.options.limits.reference_depth) return error.ReferenceDepthFull;
        self.reference_depth += 1;
        defer self.reference_depth -= 1;
        try self.enter(index);
        defer self.depth -= 1;
        const node = self.document.nodes[index];
        try self.parse_work.node(node);
        const style = try self.computed(index);
        if (self.layers == self.options.limits.layers) return error.LayersFull;
        self.layers += 1;
        defer self.layers -= 1;
        const bytes = @as(usize, self.options.width) * self.options.height * 4;
        try self.chargePixels(@as(u64, self.options.width) * self.options.height);
        try self.reserve(bytes);
        errdefer self.live -= bytes;
        const pixels = try self.allocator.alloc(u8, bytes);
        errdefer self.allocator.free(pixels);
        @memset(pixels, 0);
        const result: Mask = .{ .pixels = pixels, .alpha = style.mask_type == .alpha, .interpolation = style.interpolation };
        var region_matrix = target.matrix;
        var reference = target.viewport;
        const object_region = try objectUnits(node.attribute("maskUnits"), "objectBoundingBox");
        if (object_region) {
            const box = bounds orelse return result;
            if (box.width == 0 or box.height == 0) return result;
            region_matrix = (v.Transform{ .xx = box.width, .yy = box.height, .x0 = box.x, .y0 = box.y }).then(region_matrix);
            reference = .{ .width = 1, .height = 1 };
        }
        const region: Box = .{ .x = try unitCoordinate(node.attribute("x"), "-10%", reference.width, object_region), .y = try unitCoordinate(node.attribute("y"), "-10%", reference.height, object_region), .width = try unitCoordinate(node.attribute("width"), "120%", reference.width, object_region), .height = try unitCoordinate(node.attribute("height"), "120%", reference.height, object_region) };
        if (region.width < 0 or region.height < 0) return error.InvalidMaskRegion;
        if (region.width == 0 or region.height == 0) return result;
        var frame: Frame = .{ .matrix = target.matrix, .host_matrix = target.host_matrix, .viewport = target.viewport, .style = style };
        if (try objectUnits(node.attribute("maskContentUnits"), "userSpaceOnUse")) {
            const box = bounds orelse return result;
            if (box.width == 0 or box.height == 0) return result;
            frame.prepend(.{ .xx = box.width, .yy = box.height, .x0 = box.x, .y0 = box.y });
            frame.viewport = .{ .width = 1, .height = 1 };
        }
        try region_matrix.validate();
        try frame.matrix.validate();
        const region_coverage = try self.clipRectangle(.{ .box = region, .matrix = region_matrix });
        defer self.releasePath(region_coverage);
        var owned_clip: ?[]u16 = null;
        defer if (owned_clip) |bits| self.freeSamples(bits);
        frame.samples = region_coverage.samples;
        if (style.clip_path) |clip_id| {
            const bits = try self.clipFor(clip_id, index, "mask", frame);
            owned_clip = bits;
            try self.combineSamples(bits, region_coverage.samples, false);
            frame.samples = bits;
        }
        try self.contents(index, "mask", frame, pixels);
        if (style.mask) |nested_id| {
            // This definition is still active: nested mask references share
            // the same cycle/depth/byte/work budgets as ordinary mask use.
            // Its target coordinates and object bounds belong to this mask's
            // content, not to the original element that referenced it.
            const nested = try self.maskFor(nested_id, index, "mask", frame);
            defer {
                self.live -= nested.pixels.len;
                self.allocator.free(nested.pixels);
            }
            try self.chargePixels(@as(u64, self.options.width) * self.options.height);
            for (0..pixels.len / 4) |pixel| {
                if (pixel % 256 == 0) try self.check();
                const amount = maskFactor(nested.pixels[pixel * 4 ..][0..4], nested.alpha, nested.interpolation);
                for (pixels[pixel * 4 ..][0..4]) |*channel| channel.* = @intFromFloat(@round(@as(f64, @floatFromInt(channel.*)) * amount));
            }
        }
        // Definition containers establish inherited child style, not an extra
        // graphics group. Their child groups retain ordinary opacity/masks.
        return result;
    }
    fn clipChild(self: *Work, index: usize, parent: Frame, union_result: []u16) anyerror!void {
        try self.enter(index);
        defer self.depth -= 1;
        const node = self.document.nodes[index];
        if (node.kind == .text) return;
        const name = try localName(self.document.nodes, index);
        if (oneOf(name, &.{ "title", "desc", "metadata" })) return;
        if (!oneOf(name, &.{ "use", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text" })) return error.UnsupportedClipChild;
        try self.parse_work.node(node);
        const style = try self.sheet.?.derive(parent.style, node, name, &self.style_work);
        if (!style.displayed or (!style.visible and !std.mem.eql(u8, name, "use"))) return;
        var frame: Frame = .{ .matrix = parent.matrix, .host_matrix = parent.host_matrix, .viewport = parent.viewport, .style = style };
        if (node.attribute("transform")) |source| frame.prepend(try n.transform(source));
        if (std.mem.eql(u8, name, "use")) frame.prepend(.{ .x0 = try shapes.coordinate(node, "x", 0, parent.viewport.width), .y0 = try shapes.coordinate(node, "y", 0, parent.viewport.height) });
        try frame.matrix.validate();
        const bits = try self.newSamples();
        defer self.freeSamples(bits);
        if (std.mem.eql(u8, name, "use")) {
            const at = self.references.?.find(try refs.href(self.document.nodes, index)) orelse return error.ReferenceNotFound;
            // Clipping use content must directly name a permitted silhouette;
            // ordinary scene instance expansion has a broader content model.
            const target_name = try localName(self.document.nodes, at);
            if (!oneOf(target_name, &.{ "path", "text", "rect", "circle", "ellipse", "line", "polyline", "polygon" })) return error.InvalidClipUseTarget;
            if (self.reference_depth == self.options.limits.reference_depth) return error.ReferenceDepthFull;
            self.reference_depth += 1;
            defer self.reference_depth -= 1;
            try self.clipChild(at, frame, bits);
        } else if (try self.geometry(index, name, frame)) |path| {
            defer self.freeGeometry(path);
            const coverage = try self.preparePath(path, frame.matrix, .{ .fill = style.clip_rule }, true);
            defer self.releasePath(coverage);
            try self.combineSamples(bits, coverage.samples, true);
        }
        if (style.clip_path) |id| {
            const intersection = try self.clipFor(id, index, name, frame);
            defer self.freeSamples(intersection);
            try self.combineSamples(bits, intersection, false);
        }
        try self.combineSamples(union_result, bits, true);
    }
    fn draw(self: *Work, index: usize, parent: Frame, target: []u8) anyerror!void {
        return self.drawInstance(index, parent, target, null);
    }
    fn drawInstance(self: *Work, index: usize, parent: Frame, target: []u8, instance: ?Instance) anyerror!void {
        try self.enter(index);
        defer self.depth -= 1;
        const node = self.document.nodes[index];
        if (node.kind == .text) return;
        const name = try localName(self.document.nodes, index);
        if (oneOf(name, &.{ "defs", "title", "desc", "metadata", "style", "linearGradient", "radialGradient", "stop", "clipPath", "mask", "pattern", "marker" })) return;
        if (std.mem.eql(u8, name, "symbol") and instance == null) return;
        try self.parse_work.node(node);
        const style = try self.sheet.?.derive(parent.style, node, name, &self.style_work);
        if (!style.displayed or style.opacity == 0) return;
        const transform = if (node.attribute("transform")) |source| try n.transform(source) else v.Transform{};
        // The root viewBox mapping was prepared by the caller; its transform
        // belongs outside that mapping, just like a transformed parent group.
        var frame: Frame = .{ .matrix = parent.matrix, .host_matrix = parent.host_matrix, .viewport = parent.viewport, .style = style, .samples = parent.samples };
        if (index == 0) {
            frame.matrix = parent.matrix.then(transform);
            if (node.attribute("transform") != null) {
                frame.host_matrix = parent.matrix;
                self.host_output = transform;
            }
        } else frame.prepend(transform);
        if (std.mem.eql(u8, name, "use")) frame.prepend(.{ .x0 = try shapes.coordinate(node, "x", 0, parent.viewport.width), .y0 = try shapes.coordinate(node, "y", 0, parent.viewport.height) });
        var clip: ?Clip = null;
        if (oneOf(name, &.{ "svg", "symbol" }) and (index != 0 or instance != null)) {
            const overrides = instance orelse Instance{};
            const width = overrides.width orelse try dimension(node, "width", parent.viewport.width);
            const height = overrides.height orelse try dimension(node, "height", parent.viewport.height);
            const x = try shapes.coordinate(node, "x", 0, parent.viewport.width);
            const y = try shapes.coordinate(node, "y", 0, parent.viewport.height);
            if (width < 0 or height < 0) return error.InvalidViewport;
            if (width == 0 or height == 0) return;
            const box = try viewport(node, width, height);
            if (box.width == 0 or box.height == 0) return;
            if (style.overflow_hidden) clip = .{ .box = .{ .x = x, .y = y, .width = width, .height = height }, .matrix = frame.matrix };
            frame.prepend((try viewTransform(box, node, width, height)).then(.{ .x0 = x, .y0 = y }));
            frame.viewport = .{ .width = box.width, .height = box.height };
        }
        try frame.matrix.validate();
        // Keep clipping in the common 4x4 sample domain until each leaf is
        // rasterized. Multiplying two A8 edges would darken coincident clips.
        var owned_samples: ?[]u16 = null;
        defer if (owned_samples) |bits| self.freeSamples(bits);
        if (clip) |value| {
            const rectangle = try self.clipRectangle(value);
            defer self.releasePath(rectangle);
            owned_samples = try self.copySamples(rectangle.samples);
        }
        if (style.clip_path) |id| {
            const bits = try self.clipFor(id, index, name, frame);
            if (owned_samples) |previous| {
                defer self.freeSamples(bits);
                try self.combineSamples(previous, bits, false);
            } else owned_samples = bits;
        }
        if (owned_samples) |bits| {
            if (parent.samples) |previous| try self.combineSamples(bits, previous, false);
            frame.samples = bits;
        }
        if (style.opacity < 1 or style.mask != null) {
            if (self.layers == self.options.limits.layers) return error.LayersFull;
            try self.chargePixels(@as(u64, self.options.width) * self.options.height * 2);
            try self.reserve(target.len);
            defer self.live -= target.len;
            const layer = try self.allocator.alloc(u8, target.len);
            defer self.allocator.free(layer);
            @memset(layer, 0);
            self.layers += 1;
            defer self.layers -= 1;
            try self.contents(index, name, frame, layer);
            const mask = if (style.mask) |id| try self.maskFor(id, index, name, frame) else null;
            defer if (mask) |value| {
                self.live -= value.pixels.len;
                self.allocator.free(value.pixels);
            };
            try self.composite(target, layer, style.opacity, mask);
        } else try self.contents(index, name, frame, target);
    }
    fn contents(self: *Work, index: usize, name: []const u8, frame: Frame, target: []u8) !void {
        if (std.mem.eql(u8, name, "use")) {
            const id = try refs.href(self.document.nodes, index);
            const at = self.references.?.find(id) orelse return error.ReferenceNotFound;
            const kind = try localName(self.document.nodes, at);
            if (!oneOf(kind, &.{ "svg", "symbol", "g", "use", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text", "image" })) return error.UnsupportedReference;
            if (self.reference_depth == self.options.limits.reference_depth) return error.ReferenceDepthFull;
            self.reference_depth += 1;
            defer self.reference_depth -= 1;
            const node = self.document.nodes[index];
            var instance: Instance = .{};
            if (oneOf(kind, &.{ "svg", "symbol" })) {
                if (node.attribute("width")) |value| if (!std.mem.eql(u8, value, "auto")) {
                    instance.width = try (try n.length(value)).resolve(frame.viewport.width);
                };
                if (node.attribute("height")) |value| if (!std.mem.eql(u8, value, "auto")) {
                    instance.height = try (try n.length(value)).resolve(frame.viewport.height);
                };
            }
            try self.drawInstance(at, frame, target, instance);
            return;
        }
        if (std.mem.eql(u8, name, "image")) {
            if (frame.style.visible) if (try self.imageSource(index, frame)) |value| {
                const path = try self.imageRectangle(value.placement.rectangle);
                defer self.freeGeometry(path);
                try self.paintImage(path, frame, target, value.paint);
            };
            return;
        }
        if (std.mem.eql(u8, name, "text") and !frame.style.visible) {
            try self.validateHiddenText(index, frame);
            return;
        }
        if (!oneOf(name, &.{ "g", "svg", "symbol", "mask", "pattern", "marker" }) and frame.style.visible) {
            if (try self.geometry(index, name, frame)) |value| {
                defer self.freeGeometry(value);
                for (frame.style.paint_order) |operation| switch (operation) {
                    .fill => {
                        const fallback: @import("text_paint.zig").Fill = .{ .paint = frame.style.fill, .opacity = frame.style.fill_opacity };
                        const fill: @import("text_cache.zig").Fill = if (self.text_cache) |cache| cache.fill(value, fallback) else .{ .single = fallback };
                        switch (fill) {
                            .parts => |parts| for (parts) |part| try self.paintPath(part.path, frame, target, .{ .fill = frame.style.rule }, part.fill.paint, part.fill.opacity),
                            .single => |single| try self.paintPath(value, frame, target, .{ .fill = frame.style.rule }, single.paint, single.opacity),
                        }
                    },
                    .stroke => {
                        const reference = std.math.hypot(frame.viewport.width, frame.viewport.height) / @sqrt(@as(f64, 2));
                        const width = try frame.style.stroke_width.resolve(reference);
                        if (width != 0 and (frame.style.vector_effect == .none or nonsingular(frame.matrix))) {
                            var stroke = frame.style.stroke_options;
                            stroke.space = if (frame.style.vector_effect == .none) .local else .transformed;
                            stroke.width = width;
                            stroke.dash_offset = try frame.style.dash_offset.resolve(reference);
                            var dash_values: [32]f64 = undefined;
                            for (frame.style.dash_values[0..frame.style.dash_count], 0..) |dash, i| dash_values[i] = try dash.resolve(reference);
                            stroke.dashes = dash_values[0..frame.style.dash_count];
                            try self.paintPath(value, frame, target, .{ .stroke = stroke }, frame.style.stroke, frame.style.stroke_opacity);
                        }
                    },
                    .markers => if (markers.enabled(frame.style) and oneOf(name, &.{ "path", "line", "polyline", "rect", "circle", "ellipse", "polygon" })) try self.paintMarkers(value, name, frame, target),
                };
            }
        }
        if (std.mem.eql(u8, name, "text")) return;
        var child = self.document.nodes[index].first_child;
        while (child) |at| {
            try self.draw(at, frame, target);
            child = self.document.nodes[at].next_sibling;
        }
    }
    fn paintImage(self: *Work, path: *v.Path, frame: Frame, target: []u8, paint: *const images.Paint) !void {
        try self.chargePixels(@as(u64, self.options.width) * self.options.height);
        const mask = try self.preparePath(path, frame.matrix, .{ .fill = .nonzero }, frame.samples != null);
        defer self.releasePath(mask);
        const coverage = mask.coverage;
        if (frame.samples != null) try self.chargeSamples(@as(u64, self.options.width) * self.options.height);
        for (0..self.options.height) |y| {
            try self.check();
            for (0..self.options.width) |x| {
                if (x % 256 == 0) try self.check();
                const alpha: u8 = if (frame.samples) |bits| @intCast((@as(u16, @popCount(bits[y * coverage.stride + x] & mask.samples[y * coverage.stride + x])) * 255 + 8) / 16) else coverage.pixels[y * coverage.stride + x];
                if (alpha == 0) continue;
                var channels = try paint.sample(.{ .x = @as(f64, @floatFromInt(x)) + 0.5, .y = @as(f64, @floatFromInt(y)) + 0.5 });
                for (&channels) |*channel| channel.* *= @as(f64, @floatFromInt(alpha)) / 255;
                blend(target[(y * self.options.width + x) * 4 ..][0..4], channels);
            }
        }
    }
    noinline fn paintMarkers(self: *Work, path: *v.Path, name: []const u8, frame: Frame, target: []u8) anyerror!void {
        if (try markers.streamInspection(self, path, name)) |inspection|
            return self.paintStreamMarkers(path, &frame, inspection, target);
        const indices = [_]?usize{ try markers.resolve(self, frame.style.marker_start), try markers.resolve(self, frame.style.marker_end) };
        // No interior command means no mid instance, including no reference
        // lookup, definition work or stroke-space capability check.
        const mid = if (path.commands.len > 2) try markers.resolve(self, frame.style.marker_mid) else null;
        if (indices[0] == null and indices[1] == null and mid == null) return;
        if (markers.closedTarget(path, name)) return self.paintClosedMarkers(path, frame, indices, mid, target);
        const topology = (try markers.endpoints(self, path, name)) orelse return;
        const ends = topology.ends;
        if (indices[0]) |index| try self.paintMarker(index, frame, ends.start, ends.start_angle, true, target);
        if (mid) |index| {
            if (topology.mids == .omitted) {
                try self.paintOmittedMids(path, &frame, index, target);
            } else if (topology.mids == .zero_polynomials) {
                try self.paintZeroPolynomialMids(path, &frame, index, target);
            } else if (topology.mids == .zero_lines) {
                var cursor: markers.ZeroLineCursor = .{};
                while (try cursor.next(self, path)) |placement| try self.paintMarker(index, frame, placement.point, placement.direction, false, target);
            } else {
                var cursor: markers.MidCursor = .{};
                while (try cursor.next(self, path)) |placement| try self.paintMarker(index, frame, placement.point, placement.direction, false, target);
            }
        }
        if (indices[1]) |index| try self.paintMarker(index, frame, ends.end, ends.end_angle, false, target);
    }
    noinline fn paintStreamMarkers(self: *Work, path: *v.Path, frame: *const Frame, inspection: markers.StreamInspection, target: []u8) anyerror!void {
        if (inspection.vertices == 0) return;
        const indices = [_]?usize{
            try markers.resolve(self, frame.style.marker_start),
            if (inspection.vertices > 2) try markers.resolve(self, frame.style.marker_mid) else null,
            try markers.resolve(self, frame.style.marker_end),
        };
        if (indices[0] == null and indices[1] == null and indices[2] == null) return;
        try markers.validateStream(self, path);
        var cursor = markers.RoleCursor.init(path.commands, inspection);
        while (try cursor.next(self)) |role| {
            const index = indices[
                switch (role.kind) {
                    .start => @as(usize, 0),
                    .mid => 1,
                    .end => 2,
                }
            ] orelse continue;
            try self.paintMarker(index, frame.*, role.point, role.direction, role.kind == .start, target);
        }
    }
    noinline fn paintOmittedMids(self: *Work, path: *v.Path, frame: *const Frame, index: usize, target: []u8) anyerror!void {
        var cursor: markers.OmittedPolynomialCursor = .{};
        while (try cursor.next(self, path)) |placement| try self.paintMarker(index, frame.*, placement.point, placement.direction, false, target);
    }
    noinline fn paintZeroPolynomialMids(self: *Work, path: *v.Path, frame: *const Frame, index: usize, target: []u8) anyerror!void {
        var cursor: markers.ZeroPolynomialCursor = .{};
        while (try cursor.next(self, path)) |placement| try self.paintMarker(index, frame.*, placement.point, placement.direction, false, target);
    }
    noinline fn paintClosedMarkers(self: *Work, path: *v.Path, frame: Frame, ends: [2]?usize, mid: ?usize, target: []u8) anyerror!void {
        const topology = try markers.closed(self, path, ends[0] != null or ends[1] != null);
        if (ends[0]) |index| try self.paintMarker(index, frame, topology.seam.point, topology.seam.direction, true, target);
        if (mid) |index| {
            if (topology.mids == .zero_polynomials) {
                try self.paintClosedZeroPolynomialMids(path, &frame, index, target);
            } else if (topology.mids == .zero_lines) {
                try self.paintClosedZeroMids(path, &frame, index, target);
            } else {
                var cursor: markers.MidCursor = .{};
                while (try cursor.nextClosed(self, path)) |placement| try self.paintMarker(index, frame, placement.point, placement.direction, false, target);
            }
        }
        if (ends[1]) |index| try self.paintMarker(index, frame, topology.seam.point, topology.seam.direction, false, target);
    }
    noinline fn paintClosedZeroMids(self: *Work, path: *v.Path, frame: *const Frame, index: usize, target: []u8) anyerror!void {
        var cursor: markers.ClosedZeroLineCursor = .{};
        while (try cursor.next(self, path)) |placement| try self.paintMarker(index, frame.*, placement.point, placement.direction, false, target);
    }
    noinline fn paintClosedZeroPolynomialMids(self: *Work, path: *v.Path, frame: *const Frame, index: usize, target: []u8) anyerror!void {
        var cursor: markers.ClosedZeroPolynomialCursor = .{};
        while (try cursor.next(self, path)) |placement| try self.paintMarker(index, frame.*, placement.point, placement.direction, false, target);
    }
    fn paintMarker(self: *Work, index: usize, frame: Frame, point: v.Point, direction: ?f64, start: bool, target: []u8) anyerror!void {
        if (self.reference_depth == self.options.limits.reference_depth) return error.ReferenceDepthFull;
        self.reference_depth += 1;
        defer self.reference_depth -= 1;
        try self.enter(index);
        defer self.depth -= 1;
        const plan = (try markers.plan(self, index, frame, point, direction, start)) orelse return;
        const coverage = try self.clipRectangle(.{ .box = plan.clip_box, .matrix = plan.clip_matrix });
        defer self.releasePath(coverage);
        const bits = try self.copySamples(coverage.samples);
        defer self.freeSamples(bits);
        if (frame.samples) |previous| try self.combineSamples(bits, previous, false);
        var child_frame = plan.frame;
        child_frame.samples = bits;
        try self.contents(index, "marker", child_frame, target);
    }
    noinline fn paintPattern(self: *Work, index: usize, path: *v.Path, frame: Frame, target: []u8, style: v.Style, opacity_value: f64) !void {
        if (opacity_value == 0) return;
        const definition = (try @import("pattern.zig").plan(self, index, frame, path, self)) orelse return;
        if (self.layers == self.options.limits.layers) return error.LayersFull;
        self.layers += 1;
        defer self.layers -= 1;
        if (self.resources == null) self.resources = try Resources.create(self);
        const ledger = try self.resources.?.patternLedger();
        try self.reserve(target.len);
        defer self.live -= target.len;
        const pixels = try self.allocator.alloc(u8, target.len);
        defer self.allocator.free(pixels);
        try self.chargePixels(@as(u64, self.options.width) * self.options.height);
        @memset(pixels, 0);
        try @import("compile.zig").renderPattern(self, ledger, index, path, frame, style, definition, pixels);
        try self.chargePixels(@as(u64, self.options.width) * self.options.height);
        try self.composite(target, pixels, opacity_value, null);
    }
    fn paintPath(self: *Work, path: *v.Path, frame: Frame, target: []u8, style: v.Style, paint: paints.Paint, opacity_value: f64) !void {
        var gradient: ?gradients.Resolved = null;
        const color: paints.Color = switch (paint) {
            .none => return,
            .current_color => frame.style.color,
            .color => |color| color,
            .reference => |reference| blk: {
                if (self.references.?.find(reference.id)) |index| {
                    const name = try localName(self.document.nodes, index);
                    if (std.mem.eql(u8, name, "pattern")) return self.paintPattern(index, path, frame, target, style, opacity_value);
                    if (oneOf(name, &.{ "linearGradient", "radialGradient" })) {
                        const box = try self.paintBounds(path);
                        const source: gradients.Source = .{ .reject_object_bounds = box.unsupported, .nodes = self.document.nodes, .references = self.references.?, .sheet = self.sheet.?, .style_work = &self.style_work, .parse_work = &self.parse_work, .node_visits = &self.node_visits, .node_limit = self.options.limits.node_visits, .reference_depth = self.options.limits.reference_depth, .stops = self.options.limits.gradient_stops, .current_color = self.options.current_color, .cancellation = self.options.cancellation };
                        gradient = try source.compile(index, frame.viewport, box.value, frame.matrix);
                        if (gradient.?.count == 0 or gradient.?.inverse == null) return;
                        break :blk paints.Color{};
                    }
                }
                break :blk switch (reference.fallback) {
                    .none => return,
                    .current_color => frame.style.color,
                    .color => |value| value,
                };
            },
        };
        if (color.a == 0 or opacity_value == 0) return;
        try self.chargePixels(@as(u64, self.options.width) * self.options.height);
        const host = style == .stroke and style.stroke.space == .transformed;
        const mask = try self.preparePathOutput(path, if (host) frame.host_matrix orelse frame.matrix else frame.matrix, if (host and frame.host_matrix != null) &self.host_output else null, style, frame.samples != null);
        defer {
            self.live -= (mask.stats() catch unreachable).owned_bytes;
            mask.close() catch unreachable;
        }
        // A private preparing-owner mask needs no native view or publication.
        const coverage = mask.coverage;
        if (frame.samples != null) try self.chargeSamples(@as(u64, self.options.width) * self.options.height);
        for (0..self.options.height) |y| {
            try self.check();
            for (0..self.options.width) |x| {
                if (x % 256 == 0) try self.check();
                const coverage_alpha: u8 = if (frame.samples) |bits| @intCast((@as(u16, @popCount(bits[y * coverage.stride + x] & mask.samples[y * coverage.stride + x])) * 255 + 8) / 16) else coverage.pixels[y * coverage.stride + x];
                const factor = @as(f64, @floatFromInt(coverage_alpha)) / 255 * opacity_value;
                if (factor == 0) continue;
                var channels: [4]f64 = if (gradient) |*value| try value.sample(.{ .x = @as(f64, @floatFromInt(x)) + 0.5, .y = @as(f64, @floatFromInt(y)) + 0.5 }) else blk: {
                    const alpha = @as(f64, @floatFromInt(color.a)) / 255;
                    break :blk .{ @as(f64, @floatFromInt(color.b)) * alpha, @as(f64, @floatFromInt(color.g)) * alpha, @as(f64, @floatFromInt(color.r)) * alpha, alpha * 255 };
                };
                for (&channels) |*value| value.* *= factor;
                blend(target[(y * self.options.width + x) * 4 ..][0..4], channels);
            }
        }
    }
    fn preparePath(self: *Work, path: *v.Path, matrix: v.Transform, style: v.Style, retain_samples: bool) !*v.Prepared {
        return self.preparePathOutput(path, matrix, null, style, retain_samples);
    }
    fn preparePathOutput(self: *Work, path: *v.Path, matrix: v.Transform, output: ?*const v.Transform, style: v.Style, retain_samples: bool) !*v.Prepared {
        // The vector snapshot quantizes every output pixel and, when requested,
        // clears its sample plane. Charge both whole-plane passes as well.
        try self.chargeSamples(self.sampleCount() * @as(u64, if (retain_samples) 2 else 1));
        if (self.scan_tests == self.options.limits.raster.scan_tests or self.stroke_steps == self.options.limits.raster.stroke_steps) return error.ScanBudgetExceeded;
        var limits = self.options.limits.raster;
        if (self.vertices == limits.vertices or self.edges == limits.edges or self.edge_attempts == limits.edge_attempts) return error.SceneGeometryBudgetExceeded;
        limits.vertices -= self.vertices;
        limits.edges -= self.edges;
        limits.edge_attempts -= self.edge_attempts;
        limits.bytes = @min(limits.bytes, self.options.limits.bytes -| self.live);
        if (limits.bytes == 0) return error.CapacityExceeded;
        limits.scan_tests -= self.scan_tests;
        limits.stroke_steps -= self.stroke_steps;
        const mask = try path.prepare(self.allocator, .{ .main_thread = self.options.main_thread, .viewport = .{ .width = @floatFromInt(self.options.width), .height = @floatFromInt(self.options.height) }, .style = style, .transform = matrix, .stroke_output = output, .limits = limits, .cancellation = self.options.cancellation, .retain_samples = retain_samples });
        errdefer mask.close() catch unreachable;
        const stats_value = try mask.stats();
        if (stats_value.prepare_peak_bytes > self.options.limits.bytes -| self.live) return error.CapacityExceeded;
        self.peak = @max(self.peak, self.live + stats_value.prepare_peak_bytes);
        self.scan_tests += stats_value.scan_tests;
        self.stroke_steps += stats_value.stroke_steps;
        self.vertices += stats_value.vertices;
        self.edges += stats_value.edges;
        self.edge_attempts += stats_value.edge_attempts;
        self.paths += 1;
        try self.reserve(stats_value.owned_bytes);
        return mask;
    }
    fn clipRectangle(self: *Work, clip: Clip) !*v.Prepared {
        const b = clip.box;
        var limits = self.options.limits.path;
        limits.bytes = @min(limits.bytes, self.options.limits.bytes -| self.live);
        if (limits.bytes == 0) return error.CapacityExceeded;
        const path = try v.Path.create(self.allocator, &.{ .{ .move = .{ .x = b.x, .y = b.y } }, .{ .line = .{ .x = b.x + b.width, .y = b.y } }, .{ .line = .{ .x = b.x + b.width, .y = b.y + b.height } }, .{ .line = .{ .x = b.x, .y = b.y + b.height } }, .close }, limits);
        defer path.close() catch unreachable;
        const bytes = @sizeOf(v.Path) + path.commands.len * @sizeOf(v.Command);
        try self.reserve(bytes);
        defer self.live -= bytes;
        return try self.preparePath(path, clip.matrix, .{ .fill = .nonzero }, true);
    }
    fn composite(self: *Work, target: []u8, source: []const u8, opacity_value: f64, mask: ?Mask) !void {
        for (0..source.len / 4) |index| {
            if (index % 256 == 0) try self.check();
            const input = source[index * 4 ..][0..4];
            var channels: [4]f64 = undefined;
            const factor = opacity_value * (if (mask) |value| maskFactor(value.pixels[index * 4 ..][0..4], value.alpha, value.interpolation) else 1);
            for (input, 0..) |value, i| channels[i] = @as(f64, @floatFromInt(value)) * factor;
            blend(target[index * 4 ..][0..4], channels);
        }
    }
};

// Each product of binary64 operands is exact in binary128. Comparing the
// products avoids classifying a tiny nonzero determinant as zero through
// cancellation or binary64 product underflow.
pub fn nonsingular(matrix: v.Transform) bool {
    return @as(f128, matrix.xx) * @as(f128, matrix.yy) != @as(f128, matrix.xy) * @as(f128, matrix.yx);
}
fn blend(target: []u8, source: [4]f64) void {
    const inverse = 1 - source[3] / 255;
    for (target, source) |*destination, value| destination.* = @intFromFloat(std.math.clamp(@round(value + @as(f64, @floatFromInt(destination.*)) * inverse), 0, 255));
}
pub fn oneOf(name: []const u8, values: []const []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, name, value)) return true;
    return false;
}
pub const localName = @import("names.zig").localName;
pub fn dimension(node: d.Node, key: []const u8, reference: f64) !f64 {
    const input = node.attribute(key) orelse return reference;
    if (std.mem.eql(u8, input, "auto")) return reference;
    return try (try n.length(input)).resolve(reference);
}
pub fn viewport(node: d.Node, width: f64, height: f64) !Box {
    if (node.attribute("viewBox")) |text| {
        var values: [4]f64 = undefined;
        if ((try n.list(text, &values)).len != 4 or values[2] < 0 or values[3] < 0) return error.InvalidViewBox;
        for (values) |value| if (@abs(value) > 1e9) return error.InvalidViewBox;
        return .{ .x = values[0], .y = values[1], .width = values[2], .height = values[3] };
    }
    if (width < 0 or height < 0) return error.InvalidViewport;
    return .{ .width = width, .height = height };
}
pub fn viewTransform(box: Box, node: d.Node, width: f64, height: f64) !v.Transform {
    const value = std.mem.trim(u8, node.attribute("preserveAspectRatio") orelse "xMidYMid meet", " \t\r\n");
    const sx = width / box.width;
    const sy = height / box.height;
    if (std.mem.eql(u8, value, "none")) return .{ .xx = sx, .yy = sy, .x0 = -box.x * sx, .y0 = -box.y * sy };
    var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
    const alignment = tokens.next() orelse return error.InvalidAspectRatio;
    const mode = tokens.next() orelse "meet";
    if (tokens.next() != null or (!std.mem.eql(u8, mode, "meet") and !std.mem.eql(u8, mode, "slice"))) return error.InvalidAspectRatio;
    if (alignment.len != 8 or alignment[0] != 'x' or alignment[4] != 'Y') return error.InvalidAspectRatio;
    const x = alignment[1..4];
    const y = alignment[5..8];
    const ax: f64 = if (std.mem.eql(u8, x, "Min")) 0 else if (std.mem.eql(u8, x, "Mid")) 0.5 else if (std.mem.eql(u8, x, "Max")) 1 else return error.InvalidAspectRatio;
    const ay: f64 = if (std.mem.eql(u8, y, "Min")) 0 else if (std.mem.eql(u8, y, "Mid")) 0.5 else if (std.mem.eql(u8, y, "Max")) 1 else return error.InvalidAspectRatio;
    const scale = if (std.mem.eql(u8, mode, "meet")) @min(sx, sy) else @max(sx, sy);
    return .{ .xx = scale, .yy = scale, .x0 = -box.x * scale + (width - box.width * scale) * ax, .y0 = -box.y * scale + (height - box.height * scale) * ay };
}
pub fn validateOptions(document: *const d.Document, options: Options) !void {
    try document.checkOwner();
    const limits = options.limits;
    if (limits.color_work == 0 or limits.color_work > 1024 * 1024 * 1024 or limits.scene_work == 0 or limits.scene_work > 1024 * 1024 * 1024 or limits.sort_work == 0 or limits.sort_work > 1024 * 1024 * 1024) return error.InvalidLimits;
    if (limits.bytes == 0 or limits.bytes > 256 * 1024 * 1024 or limits.layers > 32 or limits.pixel_work == 0 or limits.pixel_work > 1024 * 1024 * 1024 or limits.sample_work == 0 or limits.sample_work > 1024 * 1024 * 1024 or limits.style_work == 0 or limits.style_work > 64 * 1024 * 1024 or limits.parse_work == 0 or limits.parse_work > 64 * 1024 * 1024 or limits.node_visits == 0 or limits.node_visits > 1024 * 1024 or limits.reference_depth == 0 or limits.reference_depth > 32 or limits.gradient_stops == 0 or limits.gradient_stops > gradients.max_stops) return error.InvalidLimits;
    try limits.path.validate();
    try limits.raster.validate();
    try limits.text.validate();
    if (options.width == 0 or options.height == 0 or options.width > 16384 or options.height > 16384 or @as(u64, options.width) * options.height > 16 * 1024 * 1024) return error.InvalidSize;
}
pub fn prepare(document: *const d.Document, allocator: std.mem.Allocator, options: Options) !*Prepared {
    try validateOptions(document, options);
    if (options.compositing == .sample_color) return @import("compile.zig").prepare(document, allocator, options);
    const limits = options.limits;
    const pixel_bytes = @as(usize, options.width) * options.height * 4;
    var work: Work = .{ .allocator = allocator, .document = d.state(document), .options = options, .live = @sizeOf(Prepared), .peak = @sizeOf(Prepared), .style_work = .{ .limit = limits.style_work }, .parse_work = .{ .limit = limits.parse_work } };
    defer work.closeText();
    defer work.closeResources();
    try work.check();
    try work.reserve(pixel_bytes);
    try work.validateSource();
    var sheet = try css.Sheet.init(allocator, work.document.nodes, limits.styles, limits.bytes -| work.live);
    defer sheet.deinit();
    try work.reserve(sheet.bytes());
    work.sheet = &sheet;
    var references = try refs.Index.init(allocator, work.document.nodes, limits.bytes -| work.live);
    defer references.deinit();
    try work.reserve(references.bytes());
    work.references = &references;
    const result = try allocator.create(Prepared);
    errdefer allocator.destroy(result);
    const pixels = try allocator.alloc(u8, pixel_bytes);
    errdefer allocator.free(pixels);
    try work.chargePixels(@as(u64, options.width) * options.height);
    @memset(pixels, 0);
    const root = work.document.nodes[0];
    const width: f64 = @floatFromInt(options.width);
    const height: f64 = @floatFromInt(options.height);
    const box = try viewport(root, try dimension(root, "width", width), try dimension(root, "height", height));
    if (box.width != 0 and box.height != 0) {
        const transform = try viewTransform(box, root, width, height);
        try transform.validate();
        try work.draw(0, .{ .matrix = transform, .viewport = .{ .width = box.width, .height = box.height }, .style = .{ .color = options.current_color } }, pixels);
    }
    try work.check();
    result.* = .{ .allocator = allocator, .lease = drawing.Lease.init(std.Thread.getCurrentId()), .main_thread = options.main_thread, .adopted = std.Thread.getCurrentId() == options.main_thread, .identity = try drawing.reserveRasterIdentity(), .level = .{ .pixels = pixels.ptr, .byte_len = pixels.len, .width = options.width, .height = options.height, .stride = options.width * 4 }, .pixels = pixels, .metrics = .{ .owned_bytes = @sizeOf(Prepared) + pixel_bytes, .peak_bytes = work.peak, .paths = work.paths, .pixel_work = work.pixel_work, .sample_work = work.sample_work, .scan_tests = work.scan_tests, .stroke_steps = work.stroke_steps, .vertices = work.vertices, .edges = work.edges, .edge_attempts = work.edge_attempts, .style_work = work.style_work.used, .stylesheet_bytes = sheet.bytes(), .stylesheet_rules = sheet.rules.len, .node_visits = work.node_visits, .reference_bytes = references.bytes(), .parse_work = work.parse_work.used, .color_work = if (work.resources) |cache| if (cache.pattern_work) |ledger| ledger.color.rgba_operations else 0 else 0, .scene_work = if (work.resources) |cache| if (cache.pattern_work) |ledger| ledger.ops else 0 else 0, .sort_work = if (work.resources) |cache| if (cache.pattern_work) |ledger| ledger.geometry.sort_tests else 0 else 0, .text_source_bytes = if (work.text_cache) |cache| cache.source_bytes else 0, .text_glyphs = if (work.text_cache) |cache| cache.glyphs else 0, .text_commands = if (work.text_cache) |cache| cache.commands else 0, .text_accounted_commands = if (work.text_cache) |cache| cache.commands + cache.extra_commands else 0, .text_mapping_requests = if (work.text_cache) |cache| cache.mapping_requests else 0, .text_work = if (work.text_cache) |cache| cache.used else 0, .text_requests = if (work.text_cache) |cache| cache.requests else 0, .text_characters = if (work.text_cache) |cache| cache.characters else 0, .text_position_values = if (work.text_cache) |cache| cache.position_values else 0, .text_chunks = if (work.text_cache) |cache| cache.chunks else 0, .text_paint_runs = if (work.text_cache) |cache| cache.paint_runs else 0, .text_paint_commands = if (work.text_cache) |cache| cache.paint_commands else 0 } };
    return result;
}

test "pattern coordinate policy rejects before pixel resources and temporary owner allocation" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "width='.5' height='1' patternTransform='translate(.5 0)'",
        "width='.5' height='1' viewBox='0 0 4 2'",
    }) |attributes| {
        const text = try std.fmt.allocPrint(a, "<svg><defs><pattern id='p' {s}><rect width='1' height='1'/></pattern></defs></svg>", .{attributes});
        defer a.free(text);
        const document = try d.Document.parse(a, text, .{});
        defer document.close() catch unreachable;
        var sheet = try css.Sheet.init(a, d.state(document).nodes, .{}, 1024 * 1024);
        defer sheet.deinit();
        var references = try refs.Index.init(a, d.state(document).nodes, 1024 * 1024);
        defer references.deinit();
        const path = try v.Path.parseData(a, "M0 0H8V4H0Z", .{});
        defer path.close() catch unreachable;
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
        var work: Work = .{ .allocator = failing.allocator(), .document = d.state(document), .options = .{ .main_thread = std.Thread.getCurrentId(), .width = 8, .height = 4 }, .live = 0, .peak = 0, .sheet = &sheet, .references = &references, .style_work = .{ .limit = 1024 * 1024 }, .parse_work = .{ .limit = 1024 * 1024 } };
        var pixels: [8 * 4 * 4]u8 = @splat(73);
        const frame: Frame = .{ .matrix = .{}, .viewport = .{ .width = 8, .height = 4 }, .style = .{} };
        try std.testing.expectError(error.UnsupportedPatternCoordinateSpace, work.paintPattern(references.find("p").?, path, frame, &pixels, .{ .fill = .nonzero }, 1));
        try std.testing.expect(!failing.has_induced_failure);
        try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
        try std.testing.expect(work.resources == null and work.text_cache == null);
        try std.testing.expectEqual(@as(usize, 0), work.live);
        try std.testing.expectEqual(@as(usize, 0), work.peak);
        try std.testing.expectEqual(@as(usize, 0), work.layers);
        try std.testing.expect(std.mem.allEqual(u8, &pixels, 73));
    }
}

fn unionBounds(previous: ?v.Bounds, next: v.Bounds) v.Bounds {
    const first = previous orelse return next;
    const x = @min(first.x, next.x);
    const y = @min(first.y, next.y);
    return .{ .x = x, .y = y, .width = @max(first.x + first.width, next.x + next.width) - x, .height = @max(first.y + first.height, next.y + next.height) - y };
}

pub fn objectUnits(input: ?[]const u8, fallback: []const u8) !bool {
    const value = input orelse fallback;
    if (std.mem.eql(u8, value, "objectBoundingBox")) return true;
    if (std.mem.eql(u8, value, "userSpaceOnUse")) return false;
    return error.InvalidCoordinateUnits;
}
pub fn unitCoordinate(input: ?[]const u8, fallback: []const u8, reference: f64, object: bool) !f64 {
    const value = input orelse fallback;
    if (object) {
        var scan: n.Scanner = .{ .input = value };
        _ = scan.space();
        _ = try scan.number();
        if (scan.at < value.len and value[scan.at] == '%') scan.at += 1;
        _ = scan.space();
        if (scan.at != value.len) return error.UnsupportedBoundingBoxUnit;
    }
    return (try n.length(value)).resolve(reference);
}
fn maskFactor(pixel: []const u8, alpha_only: bool, interpolation: styles.Interpolation) f64 {
    const alpha = @as(f64, @floatFromInt(pixel[3])) / 255;
    if (alpha_only or alpha == 0) return alpha;
    var channels: [3]f64 = undefined;
    for (&channels, pixel[0..3]) |*channel, byte| {
        channel.* = @as(f64, @floatFromInt(byte)) / 255;
        if (interpolation == .linear_rgb) {
            const straight = std.math.clamp(channel.* / alpha, 0, 1);
            channel.* = (if (straight <= 0.04045) straight / 12.92 else std.math.pow(f64, (straight + 0.055) / 1.055, 2.4)) * alpha;
        }
    }
    return channels[2] * 0.2125 + channels[1] * 0.7154 + channels[0] * 0.0721;
}
