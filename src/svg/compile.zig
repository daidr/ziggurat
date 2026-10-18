const std = @import("std");
const v = @import("ziggurat_vector");
const drawing = @import("ziggurat_drawing_resources");
const pre = @import("prepare.zig");
const d = @import("document.zig");
const scene = @import("scene.zig");
const Budget = @import("budget.zig").Budget;
const n = @import("numbers.zig");
const shapes = @import("shape.zig");
const styles = @import("style.zig");
const paints = @import("paint.zig");
const css = @import("css.zig");
const refs = @import("references.zig");
const gradients = @import("gradient.zig");
const markers = @import("marker.zig");
const patterns = @import("pattern.zig");
const Frame = pre.Frame;
const Instance = pre.Instance;
const nameOf = pre.localName;
const oneOf = pre.oneOf;

// One stable owner for the compiled arrays and their allocator context. Source
// strings are consulted only while building this candidate; Raster receives
// copied descriptors and owning geometry, never CSS/XML or callbacks.
const Builder = struct {
    budget: Budget,
    source: pre.Work = undefined,
    work: scene.Work = .{},
    sheet: ?css.Sheet = null,
    references: ?refs.Index = null,
    geometries: std.ArrayList(*v.geometry.Geometry) = .empty,
    brushes: std.ArrayList(scene.Brush) = .empty,
    gradients: std.ArrayList(scene.Gradient) = .empty,
    clips: std.ArrayList(scene.Clip) = .empty,
    masks: std.ArrayList(scene.Mask) = .empty,
    nodes: std.ArrayList(scene.Node) = .empty,
    children: std.ArrayList(usize) = .empty,
    roots: std.ArrayList(usize) = .empty,
    pixels: []u8 = &.{},
    source_initialized: bool = false,

    fn allocator(self: *Builder) std.mem.Allocator {
        return self.budget.allocator();
    }
    fn deinit(self: *Builder) void {
        const a = self.allocator();
        if (self.source_initialized) {
            self.source.closeText();
            self.source.closeResources();
        }
        for (self.geometries.items) |item| item.close() catch unreachable;
        self.geometries.deinit(a);
        self.brushes.deinit(a);
        self.gradients.deinit(a);
        self.clips.deinit(a);
        self.masks.deinit(a);
        self.nodes.deinit(a);
        self.children.deinit(a);
        self.roots.deinit(a);
        if (self.sheet) |*sheet| sheet.deinit();
        if (self.references) |*references| references.deinit();
        a.free(self.pixels);
        std.debug.assert(self.budget.live == @sizeOf(Builder));
        self.budget.child.destroy(self);
    }
    fn append(self: *Builder, comptime T: type, list: *std.ArrayList(T), item: T) !usize {
        try self.work.step(1, self.source.options.cancellation);
        if (list.items.len == 1024 * 1024) return error.CapacityExceeded;
        const index = list.items.len;
        try list.append(self.allocator(), item);
        return index;
    }
    fn group(self: *Builder, child_nodes: []const usize, clip: ?usize, mask: ?usize, opacity: f64) !?usize {
        if (child_nodes.len == 0 or opacity == 0 or clip == 0) return null;
        const start = self.children.items.len;
        if (child_nodes.len > 1024 * 1024 -| start) return error.CapacityExceeded;
        try self.work.step(child_nodes.len, self.source.options.cancellation);
        try self.children.appendSlice(self.allocator(), child_nodes);
        return try self.append(scene.Node, &self.nodes, .{ .group = .{ .children = .{ .start = start, .len = child_nodes.len }, .clip = clip, .mask = mask, .opacity = opacity } });
    }
    fn combine(self: *Builder, a: usize, b: usize, union_region: bool) !usize {
        if (a == b) return a;
        if (a == 0) return if (union_region) b else 0;
        if (b == 0) return if (union_region) a else 0;
        return self.append(scene.Clip, &self.clips, if (union_region) .{ .union_of = .{ .a = a, .b = b } } else .{ .intersection = .{ .a = a, .b = b } });
    }
    fn geometry(self: *Builder, path: *v.Path, matrix: v.Transform, style: v.Style) !usize {
        return self.geometryOutput(path, matrix, null, style);
    }
    fn geometryOutput(self: *Builder, path: *v.Path, matrix: v.Transform, output: ?*const v.Transform, style: v.Style) !usize {
        const limits = self.source.options.limits.raster;
        const old = &self.source;
        if (old.vertices == limits.vertices or old.edges == limits.edges or old.edge_attempts == limits.edge_attempts or old.stroke_steps == limits.stroke_steps) return error.SceneGeometryBudgetExceeded;
        var remaining = limits;
        remaining.vertices -= old.vertices;
        remaining.edges -= old.edges;
        remaining.edge_attempts -= old.edge_attempts;
        remaining.stroke_steps -= old.stroke_steps;
        remaining.bytes = @min(remaining.bytes, self.budget.remaining());
        if (remaining.bytes == 0) return error.CapacityExceeded;
        const value = try v.geometry.compile(path, self.allocator(), .{ .transform = matrix, .stroke_output = output, .style = style, .limits = remaining, .cancellation = old.options.cancellation });
        errdefer value.close() catch unreachable;
        const stats = try value.stats();
        old.vertices += stats.vertices;
        old.edges += stats.edges;
        old.edge_attempts += stats.edge_attempts;
        old.stroke_steps += stats.stroke_steps;
        old.paths += 1;
        return self.append(*v.geometry.Geometry, &self.geometries, value);
    }
    fn clipRectangle(self: *Builder, box: pre.Box, matrix: v.Transform) !usize {
        var limits = self.source.options.limits.path;
        limits.bytes = @min(limits.bytes, self.budget.remaining());
        if (limits.bytes == 0) return error.CapacityExceeded;
        const path = try v.Path.create(self.allocator(), &.{ .{ .move = .{ .x = box.x, .y = box.y } }, .{ .line = .{ .x = box.x + box.width, .y = box.y } }, .{ .line = .{ .x = box.x + box.width, .y = box.y + box.height } }, .{ .line = .{ .x = box.x, .y = box.y + box.height } }, .close }, limits);
        defer path.close() catch unreachable;
        const at = try self.geometry(path, matrix, .{ .fill = .nonzero });
        return self.append(scene.Clip, &self.clips, .{ .geometry = at });
    }
    fn clipFor(self: *Builder, id: []const u8, target: usize, name: []const u8, frame: Frame) !usize {
        const index = self.source.references.?.find(id) orelse return error.ReferenceNotFound;
        if (!std.mem.eql(u8, try nameOf(self.source.document.nodes, index), "clipPath")) return error.InvalidClipReference;
        const object = std.mem.eql(u8, self.source.document.nodes[index].attribute("clipPathUnits") orelse "userSpaceOnUse", "objectBoundingBox");
        return self.clipReference(index, frame, if (object) try self.source.localBounds(target, name, frame) else null);
    }
    fn clipReference(self: *Builder, index: usize, target: Frame, bounds: ?v.Bounds) anyerror!usize {
        const source = &self.source;
        if (source.reference_depth == source.options.limits.reference_depth) return error.ReferenceDepthFull;
        source.reference_depth += 1;
        defer source.reference_depth -= 1;
        try source.enter(index);
        defer source.depth -= 1;
        const node = source.document.nodes[index];
        try source.parse_work.node(node);
        const style = try source.computed(index);
        if (style.mask != null) return error.UnsupportedClipContainerEffect;
        var frame: Frame = .{ .matrix = target.matrix, .host_matrix = target.host_matrix, .viewport = target.viewport, .style = style };
        const units = node.attribute("clipPathUnits") orelse "userSpaceOnUse";
        if (std.mem.eql(u8, units, "objectBoundingBox")) {
            const box = bounds orelse return 0;
            if (box.width == 0 or box.height == 0) return 0;
            frame.prepend(.{ .xx = box.width, .yy = box.height, .x0 = box.x, .y0 = box.y });
            frame.viewport = .{ .width = 1, .height = 1 };
        } else if (!std.mem.eql(u8, units, "userSpaceOnUse")) return error.InvalidClipUnits;
        if (node.attribute("transform")) |text| frame.prepend(try n.transform(text));
        try frame.matrix.validate();
        var result: usize = 0;
        var child = node.first_child;
        while (child) |at| {
            result = try self.combine(result, try self.clipChild(at, frame), true);
            child = source.document.nodes[at].next_sibling;
        }
        if (style.clip_path) |id| result = try self.combine(result, try self.clipFor(id, index, "clipPath", frame), false);
        return result;
    }
    fn clipChild(self: *Builder, index: usize, parent: Frame) anyerror!usize {
        const source = &self.source;
        try source.enter(index);
        defer source.depth -= 1;
        const node = source.document.nodes[index];
        if (node.kind == .text) return 0;
        const name = try nameOf(source.document.nodes, index);
        if (oneOf(name, &.{ "title", "desc", "metadata" })) return 0;
        if (!oneOf(name, &.{ "use", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text" })) return error.UnsupportedClipChild;
        try source.parse_work.node(node);
        const style = try source.sheet.?.derive(parent.style, node, name, &source.style_work);
        if (!style.displayed or (!style.visible and !std.mem.eql(u8, name, "use"))) return 0;
        var frame: Frame = .{ .matrix = parent.matrix, .host_matrix = parent.host_matrix, .viewport = parent.viewport, .style = style };
        if (node.attribute("transform")) |text| frame.prepend(try n.transform(text));
        var result: usize = 0;
        if (std.mem.eql(u8, name, "use")) {
            frame.prepend(.{ .x0 = try shapes.coordinate(node, "x", 0, parent.viewport.width), .y0 = try shapes.coordinate(node, "y", 0, parent.viewport.height) });
            const at = source.references.?.find(try refs.href(source.document.nodes, index)) orelse return error.ReferenceNotFound;
            if (!oneOf(try nameOf(source.document.nodes, at), &.{ "path", "text", "rect", "circle", "ellipse", "line", "polyline", "polygon" })) return error.InvalidClipUseTarget;
            if (source.reference_depth == source.options.limits.reference_depth) return error.ReferenceDepthFull;
            source.reference_depth += 1;
            defer source.reference_depth -= 1;
            try frame.matrix.validate();
            result = try self.clipChild(at, frame);
        } else {
            try frame.matrix.validate();
            if (try source.geometry(index, name, frame)) |path| {
                defer source.freeGeometry(path);
                result = try self.append(scene.Clip, &self.clips, .{ .geometry = try self.geometry(path, frame.matrix, .{ .fill = style.clip_rule }) });
            }
        }
        if (style.clip_path) |id| result = try self.combine(result, try self.clipFor(id, index, name, frame), false);
        return result;
    }
    fn maskFor(self: *Builder, id: []const u8, target: usize, name: []const u8, frame: Frame) anyerror!usize {
        const source = &self.source;
        const index = source.references.?.find(id) orelse return error.ReferenceNotFound;
        const node = source.document.nodes[index];
        if (!std.mem.eql(u8, try nameOf(source.document.nodes, index), "mask")) return error.InvalidMaskReference;
        const object = try pre.objectUnits(node.attribute("maskUnits"), "objectBoundingBox") or try pre.objectUnits(node.attribute("maskContentUnits"), "userSpaceOnUse");
        const bounds = if (object) try source.localBounds(target, name, frame) else null;
        if (source.reference_depth == source.options.limits.reference_depth) return error.ReferenceDepthFull;
        source.reference_depth += 1;
        defer source.reference_depth -= 1;
        try source.enter(index);
        defer source.depth -= 1;
        try source.parse_work.node(node);
        const style = try source.computed(index);
        var region_matrix = frame.matrix;
        var reference = frame.viewport;
        const object_region = try pre.objectUnits(node.attribute("maskUnits"), "objectBoundingBox");
        var empty = false;
        if (object_region) {
            if (bounds) |box| {
                region_matrix = (v.Transform{ .xx = box.width, .yy = box.height, .x0 = box.x, .y0 = box.y }).then(region_matrix);
                reference = .{ .width = 1, .height = 1 };
                empty = box.width == 0 or box.height == 0;
            } else empty = true;
        }
        const region: pre.Box = .{ .x = try pre.unitCoordinate(node.attribute("x"), "-10%", reference.width, object_region), .y = try pre.unitCoordinate(node.attribute("y"), "-10%", reference.height, object_region), .width = try pre.unitCoordinate(node.attribute("width"), "120%", reference.width, object_region), .height = try pre.unitCoordinate(node.attribute("height"), "120%", reference.height, object_region) };
        if (region.width < 0 or region.height < 0) return error.InvalidMaskRegion;
        empty = empty or region.width == 0 or region.height == 0;
        var mask_frame: Frame = .{ .matrix = frame.matrix, .host_matrix = frame.host_matrix, .viewport = frame.viewport, .style = style };
        if (try pre.objectUnits(node.attribute("maskContentUnits"), "userSpaceOnUse")) {
            if (bounds) |box| {
                mask_frame.prepend(.{ .xx = box.width, .yy = box.height, .x0 = box.x, .y0 = box.y });
                mask_frame.viewport = .{ .width = 1, .height = 1 };
                empty = empty or box.width == 0 or box.height == 0;
            } else empty = true;
        }
        var child_nodes: std.ArrayList(usize) = .empty;
        defer child_nodes.deinit(self.allocator());
        var clip: usize = 0;
        if (!empty) {
            try region_matrix.validate();
            try mask_frame.matrix.validate();
            clip = try self.clipRectangle(region, region_matrix);
            if (style.clip_path) |clip_id| clip = try self.combine(clip, try self.clipFor(clip_id, index, "mask", mask_frame), false);
            try self.contents(index, "mask", mask_frame, &child_nodes);
        }
        const own_mask = if (!empty and style.mask != null) try self.maskFor(style.mask.?, index, "mask", mask_frame) else null;
        const root = (try self.group(child_nodes.items, clip, own_mask, 1)) orelse try self.append(scene.Node, &self.nodes, .{ .group = .{ .children = .{} } });
        return self.append(scene.Mask, &self.masks, .{ .node = root, .mode = if (style.mask_type == .alpha) .alpha else .luminance, .linear_rgb = style.interpolation == .linear_rgb });
    }
    fn drawInstance(self: *Builder, index: usize, parent: Frame, instance: ?Instance) anyerror!?usize {
        const source = &self.source;
        try source.enter(index);
        defer source.depth -= 1;
        const node = source.document.nodes[index];
        if (node.kind == .text) return null;
        const name = try nameOf(source.document.nodes, index);
        if (oneOf(name, &.{ "defs", "title", "desc", "metadata", "style", "linearGradient", "radialGradient", "stop", "clipPath", "mask", "pattern", "marker" })) return null;
        if (std.mem.eql(u8, name, "symbol") and instance == null) return null;
        try source.parse_work.node(node);
        const style = try source.sheet.?.derive(parent.style, node, name, &source.style_work);
        if (!style.displayed or style.opacity == 0) return null;
        const transform = if (node.attribute("transform")) |text| try n.transform(text) else v.Transform{};
        var frame: Frame = .{ .matrix = parent.matrix, .host_matrix = parent.host_matrix, .viewport = parent.viewport, .style = style };
        if (index == 0) {
            frame.matrix = parent.matrix.then(transform);
            if (node.attribute("transform") != null) {
                frame.host_matrix = parent.matrix;
                source.host_output = transform;
            }
        } else frame.prepend(transform);
        if (std.mem.eql(u8, name, "use")) frame.prepend(.{ .x0 = try shapes.coordinate(node, "x", 0, parent.viewport.width), .y0 = try shapes.coordinate(node, "y", 0, parent.viewport.height) });
        var clip: ?usize = null;
        if (oneOf(name, &.{ "svg", "symbol" }) and (index != 0 or instance != null)) {
            const overrides = instance orelse Instance{};
            const width = overrides.width orelse try pre.dimension(node, "width", parent.viewport.width);
            const height = overrides.height orelse try pre.dimension(node, "height", parent.viewport.height);
            const x = try shapes.coordinate(node, "x", 0, parent.viewport.width);
            const y = try shapes.coordinate(node, "y", 0, parent.viewport.height);
            if (width < 0 or height < 0) return error.InvalidViewport;
            if (width == 0 or height == 0) return null;
            const box = try pre.viewport(node, width, height);
            if (box.width == 0 or box.height == 0) return null;
            if (style.overflow_hidden) clip = try self.clipRectangle(.{ .x = x, .y = y, .width = width, .height = height }, frame.matrix);
            frame.prepend((try pre.viewTransform(box, node, width, height)).then(.{ .x0 = x, .y0 = y }));
            frame.viewport = .{ .width = box.width, .height = box.height };
        }
        try frame.matrix.validate();
        if (style.clip_path) |id| {
            const own = try self.clipFor(id, index, name, frame);
            clip = if (clip) |previous| try self.combine(previous, own, false) else own;
        }
        var child_nodes: std.ArrayList(usize) = .empty;
        defer child_nodes.deinit(self.allocator());
        try self.contents(index, name, frame, &child_nodes);
        const mask = if (style.mask) |id| try self.maskFor(id, index, name, frame) else null;
        return self.group(child_nodes.items, clip, mask, style.opacity);
    }
    fn contents(self: *Builder, index: usize, name: []const u8, frame: Frame, output: *std.ArrayList(usize)) !void {
        const source = &self.source;
        if (std.mem.eql(u8, name, "use")) {
            const at = source.references.?.find(try refs.href(source.document.nodes, index)) orelse return error.ReferenceNotFound;
            if (source.reference_depth == source.options.limits.reference_depth) return error.ReferenceDepthFull;
            source.reference_depth += 1;
            defer source.reference_depth -= 1;
            if (try self.drawInstance(at, frame, try source.useInstance(index, at, frame.viewport))) |child| try output.append(self.allocator(), child);
            return;
        }
        if (std.mem.eql(u8, name, "image")) {
            if (frame.style.visible) if (try source.imageSource(index, frame)) |value| {
                const path = try source.imageRectangle(value.placement.rectangle);
                defer source.freeGeometry(path);
                const brush = try self.append(scene.Brush, &self.brushes, .{ .image = value.paint });
                const geometry_index = try self.geometry(path, frame.matrix, .{ .fill = .nonzero });
                const child = try self.append(scene.Node, &self.nodes, .{ .paint = .{ .geometry = geometry_index, .brush = brush } });
                try output.append(self.allocator(), child);
            };
            return;
        }
        if (std.mem.eql(u8, name, "text") and !frame.style.visible) {
            try source.validateHiddenText(index, frame);
            return;
        }
        if (!oneOf(name, &.{ "g", "svg", "symbol", "mask", "pattern", "marker" }) and frame.style.visible) {
            if (try source.geometry(index, name, frame)) |path| {
                defer source.freeGeometry(path);
                for (frame.style.paint_order) |operation| switch (operation) {
                    .fill => {
                        const fallback: @import("text_paint.zig").Fill = .{ .paint = frame.style.fill, .opacity = frame.style.fill_opacity };
                        const fill: @import("text_cache.zig").Fill = if (source.text_cache) |cache| cache.fill(path, fallback) else .{ .single = fallback };
                        switch (fill) {
                            .parts => |parts| for (parts) |part| {
                                if (try self.paint(part.path, frame, .{ .fill = frame.style.rule }, part.fill.paint, part.fill.opacity)) |child| try output.append(self.allocator(), child);
                            },
                            .single => |single| if (try self.paint(path, frame, .{ .fill = frame.style.rule }, single.paint, single.opacity)) |child| try output.append(self.allocator(), child),
                        }
                    },
                    .stroke => {
                        const reference = std.math.hypot(frame.viewport.width, frame.viewport.height) / @sqrt(@as(f64, 2));
                        const width = try frame.style.stroke_width.resolve(reference);
                        if (width != 0 and (frame.style.vector_effect == .none or pre.nonsingular(frame.matrix))) {
                            var stroke = frame.style.stroke_options;
                            stroke.space = if (frame.style.vector_effect == .none) .local else .transformed;
                            stroke.width = width;
                            stroke.dash_offset = try frame.style.dash_offset.resolve(reference);
                            var dash_values: [32]f64 = undefined;
                            for (frame.style.dash_values[0..frame.style.dash_count], 0..) |dash, i| dash_values[i] = try dash.resolve(reference);
                            stroke.dashes = dash_values[0..frame.style.dash_count];
                            if (try self.paint(path, frame, .{ .stroke = stroke }, frame.style.stroke, frame.style.stroke_opacity)) |child| try output.append(self.allocator(), child);
                        }
                    },
                    .markers => if (markers.enabled(frame.style) and oneOf(name, &.{ "path", "line", "polyline", "rect", "circle", "ellipse", "polygon" })) try self.paintMarkers(path, name, frame, output),
                };
            }
        }
        if (std.mem.eql(u8, name, "text")) return;
        var child = source.document.nodes[index].first_child;
        while (child) |at| {
            if (try self.drawInstance(at, frame, null)) |value| try output.append(self.allocator(), value);
            child = source.document.nodes[at].next_sibling;
        }
    }
    noinline fn paintMarkers(self: *Builder, path: *v.Path, name: []const u8, frame: Frame, output: *std.ArrayList(usize)) anyerror!void {
        if (try markers.streamInspection(&self.source, path, name)) |inspection|
            return self.paintStreamMarkers(path, &frame, inspection, output);
        const source = &self.source;
        const indices = [_]?usize{ try markers.resolve(source, frame.style.marker_start), try markers.resolve(source, frame.style.marker_end) };
        const mid = if (path.commands.len > 2) try markers.resolve(source, frame.style.marker_mid) else null;
        if (indices[0] == null and indices[1] == null and mid == null) return;
        if (markers.closedTarget(path, name)) return self.paintClosedMarkers(path, frame, indices, mid, output);
        const topology = (try markers.endpoints(source, path, name)) orelse return;
        const ends = topology.ends;
        if (indices[0]) |index| try self.paintMarker(index, frame, ends.start, ends.start_angle, true, output);
        if (mid) |index| {
            if (topology.mids == .omitted) {
                try self.paintOmittedMids(path, &frame, index, output);
            } else if (topology.mids == .zero_polynomials) {
                try self.paintZeroPolynomialMids(path, &frame, index, output);
            } else if (topology.mids == .zero_lines) {
                var cursor: markers.ZeroLineCursor = .{};
                while (try cursor.next(source, path)) |placement| try self.paintMarker(index, frame, placement.point, placement.direction, false, output);
            } else {
                var cursor: markers.MidCursor = .{};
                while (try cursor.next(source, path)) |placement| try self.paintMarker(index, frame, placement.point, placement.direction, false, output);
            }
        }
        if (indices[1]) |index| try self.paintMarker(index, frame, ends.end, ends.end_angle, false, output);
    }
    noinline fn paintStreamMarkers(self: *Builder, path: *v.Path, frame: *const Frame, inspection: markers.StreamInspection, output: *std.ArrayList(usize)) anyerror!void {
        if (inspection.vertices == 0) return;
        const indices = [_]?usize{
            try markers.resolve(&self.source, frame.style.marker_start),
            if (inspection.vertices > 2) try markers.resolve(&self.source, frame.style.marker_mid) else null,
            try markers.resolve(&self.source, frame.style.marker_end),
        };
        if (indices[0] == null and indices[1] == null and indices[2] == null) return;
        try markers.validateStream(&self.source, path);
        var cursor = markers.RoleCursor.init(path.commands, inspection);
        while (try cursor.next(&self.source)) |role| {
            const index = indices[
                switch (role.kind) {
                    .start => @as(usize, 0),
                    .mid => 1,
                    .end => 2,
                }
            ] orelse continue;
            try self.paintMarker(index, frame.*, role.point, role.direction, role.kind == .start, output);
        }
    }
    noinline fn paintOmittedMids(self: *Builder, path: *v.Path, frame: *const Frame, index: usize, output: *std.ArrayList(usize)) anyerror!void {
        var cursor: markers.OmittedPolynomialCursor = .{};
        while (try cursor.next(&self.source, path)) |placement| try self.paintMarker(index, frame.*, placement.point, placement.direction, false, output);
    }
    noinline fn paintZeroPolynomialMids(self: *Builder, path: *v.Path, frame: *const Frame, index: usize, output: *std.ArrayList(usize)) anyerror!void {
        var cursor: markers.ZeroPolynomialCursor = .{};
        while (try cursor.next(&self.source, path)) |placement| try self.paintMarker(index, frame.*, placement.point, placement.direction, false, output);
    }
    noinline fn paintClosedMarkers(self: *Builder, path: *v.Path, frame: Frame, ends: [2]?usize, mid: ?usize, output: *std.ArrayList(usize)) anyerror!void {
        const topology = try markers.closed(&self.source, path, ends[0] != null or ends[1] != null);
        if (ends[0]) |index| try self.paintMarker(index, frame, topology.seam.point, topology.seam.direction, true, output);
        if (mid) |index| {
            if (topology.mids == .zero_polynomials) {
                try self.paintClosedZeroPolynomialMids(path, &frame, index, output);
            } else if (topology.mids == .zero_lines) {
                try self.paintClosedZeroMids(path, &frame, index, output);
            } else {
                var cursor: markers.MidCursor = .{};
                while (try cursor.nextClosed(&self.source, path)) |placement| try self.paintMarker(index, frame, placement.point, placement.direction, false, output);
            }
        }
        if (ends[1]) |index| try self.paintMarker(index, frame, topology.seam.point, topology.seam.direction, false, output);
    }
    noinline fn paintClosedZeroMids(self: *Builder, path: *v.Path, frame: *const Frame, index: usize, output: *std.ArrayList(usize)) anyerror!void {
        var cursor: markers.ClosedZeroLineCursor = .{};
        while (try cursor.next(&self.source, path)) |placement| try self.paintMarker(index, frame.*, placement.point, placement.direction, false, output);
    }
    noinline fn paintClosedZeroPolynomialMids(self: *Builder, path: *v.Path, frame: *const Frame, index: usize, output: *std.ArrayList(usize)) anyerror!void {
        var cursor: markers.ClosedZeroPolynomialCursor = .{};
        while (try cursor.next(&self.source, path)) |placement| try self.paintMarker(index, frame.*, placement.point, placement.direction, false, output);
    }
    fn paintMarker(self: *Builder, index: usize, frame: Frame, point: v.Point, direction: ?f64, start: bool, output: *std.ArrayList(usize)) anyerror!void {
        const source = &self.source;
        if (source.reference_depth == source.options.limits.reference_depth) return error.ReferenceDepthFull;
        source.reference_depth += 1;
        defer source.reference_depth -= 1;
        try source.enter(index);
        defer source.depth -= 1;
        const plan = (try markers.plan(source, index, frame, point, direction, start)) orelse return;
        const clip = try self.clipRectangle(plan.clip_box, plan.clip_matrix);
        var children: std.ArrayList(usize) = .empty;
        defer children.deinit(self.allocator());
        try self.contents(index, "marker", plan.frame, &children);
        if (try self.group(children.items, clip, null, 1)) |child| try output.append(self.allocator(), child);
    }
    noinline fn paintPattern(self: *Builder, index: usize, path: *v.Path, frame: Frame, style: v.Style, opacity: f64, bounds_source: ?*pre.Work) anyerror!?usize {
        const definition = (try patterns.plan(&self.source, index, frame, path, bounds_source orelse &self.source)) orelse return null;
        return self.paintResolvedPattern(index, path, frame, style, opacity, definition);
    }
    noinline fn paintResolvedPattern(self: *Builder, index: usize, path: *v.Path, frame: Frame, style: v.Style, opacity: f64, definition: patterns.Plan) anyerror!?usize {
        const source = &self.source;
        if (source.reference_depth == source.options.limits.reference_depth) return error.ReferenceDepthFull;
        source.reference_depth += 1;
        defer source.reference_depth -= 1;
        try source.enter(index);
        defer source.depth -= 1;
        const host = style == .stroke and style.stroke.space == .transformed;
        const geometry_index = try self.geometryOutput(path, if (host) frame.host_matrix orelse frame.matrix else frame.matrix, if (host and frame.host_matrix != null) &source.host_output else null, style);
        const plan = (try patterns.grid(source, definition, frame, self.geometries.items[geometry_index].bounds)) orelse return null;
        const target_clip = try self.append(scene.Clip, &self.clips, .{ .geometry = geometry_index });
        var children: std.ArrayList(usize) = .empty;
        defer children.deinit(self.allocator());
        for (0..plan.rows) |row| for (0..plan.cols) |col| {
            try source.visit();
            const tile = try plan.frame(frame, col, row);
            const clip = try self.clipRectangle(tile.box, tile.clip_matrix);
            var parts: std.ArrayList(usize) = .empty;
            defer parts.deinit(self.allocator());
            try self.contents(plan.definition.content, "pattern", tile.value, &parts);
            if (try self.group(parts.items, clip, null, 1)) |child| try children.append(self.allocator(), child);
        };
        return self.group(children.items, target_clip, null, opacity);
    }
    fn paint(self: *Builder, path: *v.Path, frame: Frame, style: v.Style, paint_value: paints.Paint, opacity: f64) !?usize {
        if (opacity == 0) return null;
        const source = &self.source;
        var gradient: ?gradients.Resolved = null;
        const color: paints.Color = switch (paint_value) {
            .none => return null,
            .current_color => frame.style.color,
            .color => |value| value,
            .reference => |reference| value: {
                if (source.references.?.find(reference.id)) |index| {
                    if (std.mem.eql(u8, try nameOf(source.document.nodes, index), "pattern")) return self.paintPattern(index, path, frame, style, opacity, null);
                    if (oneOf(try nameOf(source.document.nodes, index), &.{ "linearGradient", "radialGradient" })) {
                        const box = try source.paintBounds(path);
                        const resolver: gradients.Source = .{ .reject_object_bounds = box.unsupported, .nodes = source.document.nodes, .references = source.references.?, .sheet = source.sheet.?, .style_work = &source.style_work, .parse_work = &source.parse_work, .node_visits = &source.node_visits, .node_limit = source.options.limits.node_visits, .reference_depth = source.options.limits.reference_depth, .stops = source.options.limits.gradient_stops, .current_color = source.options.current_color, .cancellation = source.options.cancellation };
                        gradient = try resolver.compile(index, frame.viewport, box.value, frame.matrix);
                        if (gradient.?.count == 0 or gradient.?.inverse == null) return null;
                        break :value paints.Color{};
                    }
                }
                break :value switch (reference.fallback) {
                    .none => return null,
                    .current_color => frame.style.color,
                    .color => |fallback| fallback,
                };
            },
        };
        if (color.a == 0) return null;
        const brush: scene.Brush = if (gradient) |value| .{ .gradient = try self.append(scene.Gradient, &self.gradients, value) } else value: {
            const alpha = @as(f64, @floatFromInt(color.a)) / 255;
            break :value .{ .solid = .{ @as(f64, @floatFromInt(color.b)) / 255 * alpha, @as(f64, @floatFromInt(color.g)) / 255 * alpha, @as(f64, @floatFromInt(color.r)) / 255 * alpha, alpha } };
        };
        const brush_index = try self.append(scene.Brush, &self.brushes, brush);
        const host = style == .stroke and style.stroke.space == .transformed;
        const geometry_index = try self.geometryOutput(path, if (host) frame.host_matrix orelse frame.matrix else frame.matrix, if (host and frame.host_matrix != null) &source.host_output else null, style);
        return try self.append(scene.Node, &self.nodes, .{ .paint = .{ .geometry = geometry_index, .brush = brush_index, .opacity = opacity } });
    }
    fn run(self: *Builder, document: *const d.Document, options: pre.Options) !*pre.Prepared {
        const limits = options.limits;
        const pixel_bytes = @as(usize, options.width) * options.height * 4;
        self.source = .{ .allocator = self.allocator(), .document = d.state(document), .options = options, .live = @sizeOf(pre.Prepared) + pixel_bytes, .peak = @sizeOf(pre.Prepared) + pixel_bytes, .style_work = .{ .limit = limits.style_work }, .parse_work = .{ .limit = limits.parse_work } };
        self.source.allocator_budgeted = true;
        self.source_initialized = true;
        self.work = .{ .op_limit = limits.scene_work, .pixel_limit = limits.pixel_work, .color = .{ .limit = limits.color_work }, .geometry = .{ .scan_limit = limits.raster.scan_tests, .sort_limit = limits.sort_work, .sample_limit = limits.sample_work } };
        try self.source.check();
        try self.source.validateSource();
        const result = try self.allocator().create(pre.Prepared);
        errdefer self.allocator().destroy(result);
        self.pixels = try self.allocator().alloc(u8, pixel_bytes);
        self.sheet = try css.Sheet.init(self.allocator(), self.source.document.nodes, limits.styles, self.budget.remaining());
        self.source.sheet = &self.sheet.?;
        self.references = try refs.Index.init(self.allocator(), self.source.document.nodes, self.budget.remaining());
        self.source.references = &self.references.?;
        _ = try self.append(scene.Clip, &self.clips, .empty);
        const root = self.source.document.nodes[0];
        const width: f64 = @floatFromInt(options.width);
        const height: f64 = @floatFromInt(options.height);
        const box = try pre.viewport(root, try pre.dimension(root, "width", width), try pre.dimension(root, "height", height));
        if (box.width != 0 and box.height != 0) {
            const transform = try pre.viewTransform(box, root, width, height);
            try transform.validate();
            if (try self.drawInstance(0, .{ .matrix = transform, .viewport = .{ .width = box.width, .height = box.height }, .style = .{ .color = options.current_color } }, null)) |at| _ = try self.append(usize, &self.roots, at);
        }
        const program: scene.Program = .{ .owner = std.Thread.getCurrentId(), .geometries = self.geometries.items, .brushes = self.brushes.items, .gradients = self.gradients.items, .clips = self.clips.items, .masks = self.masks.items, .nodes = self.nodes.items, .children = self.children.items, .roots = self.roots.items };
        if (self.budget.remaining() == 0) return error.CapacityExceeded;
        const raster = try scene.Raster.create(self.allocator(), program, .{ .bytes = self.budget.remaining(), .layers = limits.layers, .calls = 128, .cancellation = options.cancellation }, &self.work);
        defer raster.close() catch unreachable;
        try raster.render(self.pixels, options.width, options.height, &self.work, options.cancellation);
        try self.source.check();
        result.* = .{ .allocator = self.budget.child, .lease = drawing.Lease.init(std.Thread.getCurrentId()), .main_thread = options.main_thread, .adopted = std.Thread.getCurrentId() == options.main_thread, .identity = try drawing.reserveRasterIdentity(), .level = .{ .pixels = self.pixels.ptr, .byte_len = self.pixels.len, .width = options.width, .height = options.height, .stride = options.width * 4 }, .pixels = self.pixels, .metrics = .{ .owned_bytes = @sizeOf(pre.Prepared) + pixel_bytes, .peak_bytes = self.budget.peak, .paths = self.source.paths, .pixel_work = self.work.pixel_work, .sample_work = self.work.geometry.sample_work, .scan_tests = self.work.geometry.scan_tests, .stroke_steps = self.source.stroke_steps, .vertices = self.source.vertices, .edges = self.source.edges, .edge_attempts = self.source.edge_attempts, .style_work = self.source.style_work.used, .stylesheet_bytes = self.sheet.?.bytes(), .stylesheet_rules = self.sheet.?.rules.len, .node_visits = self.source.node_visits, .reference_bytes = self.references.?.bytes(), .parse_work = self.source.parse_work.used, .color_work = self.work.color.rgba_operations, .scene_work = self.work.ops, .sort_work = self.work.geometry.sort_tests, .text_source_bytes = if (self.source.text_cache) |cache| cache.source_bytes else 0, .text_glyphs = if (self.source.text_cache) |cache| cache.glyphs else 0, .text_commands = if (self.source.text_cache) |cache| cache.commands else 0, .text_accounted_commands = if (self.source.text_cache) |cache| cache.commands + cache.extra_commands else 0, .text_mapping_requests = if (self.source.text_cache) |cache| cache.mapping_requests else 0, .text_work = if (self.source.text_cache) |cache| cache.used else 0, .text_requests = if (self.source.text_cache) |cache| cache.requests else 0, .text_characters = if (self.source.text_cache) |cache| cache.characters else 0, .text_position_values = if (self.source.text_cache) |cache| cache.position_values else 0, .text_chunks = if (self.source.text_cache) |cache| cache.chunks else 0, .text_paint_runs = if (self.source.text_cache) |cache| cache.paint_runs else 0, .text_paint_commands = if (self.source.text_cache) |cache| cache.paint_commands else 0 } };
        self.budget.transfer(pixel_bytes + @sizeOf(pre.Prepared));
        self.pixels = &.{};
        return result;
    }
};

pub fn prepare(document: *const d.Document, allocator: std.mem.Allocator, options: pre.Options) !*pre.Prepared {
    try pre.validateOptions(document, options);
    if (options.limits.bytes < @sizeOf(Builder)) return error.CapacityExceeded;
    const builder = try allocator.create(Builder);
    builder.* = .{ .budget = .{ .child = allocator, .limit = options.limits.bytes, .live = @sizeOf(Builder), .peak = @sizeOf(Builder) } };
    defer builder.deinit();
    return builder.run(document, options) catch |err| return builder.budget.failure(err);
}

const ParentAllocator = struct {
    source: *pre.Work,
    denied: bool = false,
    fn allocator(self: *ParentAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *ParentAllocator = @ptrCast(@alignCast(context));
        self.source.reserve(length) catch {
            self.denied = true;
            return null;
        };
        return self.source.allocator.rawAlloc(length, alignment, ret) orelse {
            self.source.live -= length;
            return null;
        };
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *ParentAllocator = @ptrCast(@alignCast(context));
        self.source.allocator.rawFree(bytes, alignment, ret);
        self.source.live -= bytes.len;
    }
};

/// A borrowed source and an owning private scene. Only this path creates the
/// temporary owner; ordinary pixel paints retain their original allocations.
/// Arrays/geometry are owned here; Sheet/refs and the parent's resource caches
/// are never passed to the owning destructor. The single defer merges work on
/// success and failure, before the local source is destroyed.
pub noinline fn renderPattern(parent: *pre.Work, ledger: *scene.Work, index: usize, path: *v.Path, frame: Frame, style: v.Style, definition: patterns.Plan, output: []u8) !void {
    std.debug.assert(!parent.allocator_budgeted);
    const limits = parent.options.limits;
    const allowance = limits.bytes -| parent.live;
    try parent.reserve(@sizeOf(Builder));
    const builder = parent.allocator.create(Builder) catch |err| {
        parent.live -= @sizeOf(Builder);
        return err;
    };
    var bridge: ParentAllocator = .{ .source = parent };
    builder.* = .{ .budget = .{ .child = bridge.allocator(), .limit = allowance, .live = @sizeOf(Builder), .peak = @sizeOf(Builder) }, .source = parent.* };
    // This copy borrows only immutable source inputs. Resource-cache pointers
    // and the owning destructor switch remain null/false throughout the call.
    builder.source.allocator = builder.allocator();
    builder.source.allocator_budgeted = true;
    builder.source.text_cache = null;
    builder.source.resources = null;
    const before_pixels = ledger.pixel_work;
    const before_samples = ledger.geometry.sample_work;
    const before_scans = ledger.geometry.scan_tests;
    ledger.pixel_limit = before_pixels + (limits.pixel_work -| parent.pixel_work);
    ledger.geometry.sample_limit = before_samples + (limits.sample_work -| parent.sample_work);
    ledger.geometry.scan_limit = before_scans + (limits.raster.scan_tests -| parent.scan_tests);
    builder.work = ledger.*;
    defer {
        ledger.* = builder.work;
        parent.pixel_work += ledger.pixel_work - before_pixels;
        parent.sample_work += ledger.geometry.sample_work - before_samples;
        parent.scan_tests += ledger.geometry.scan_tests - before_scans;
        inline for (.{ "stroke_steps", "vertices", "edges", "edge_attempts", "paths", "style_work", "parse_work", "node_visits" }) |field| @field(parent, field) = @field(builder.source, field);
        builder.deinit();
    }
    return renderPatternCandidate(builder, parent, index, path, frame, style, definition, output) catch |err| return if (bridge.denied) error.CapacityExceeded else builder.budget.failure(err);
}
fn renderPatternCandidate(builder: *Builder, parent: *pre.Work, index: usize, path: *v.Path, frame: Frame, style: v.Style, definition: patterns.Plan, output: []u8) !void {
    const limits = parent.options.limits;
    try builder.source.check();
    _ = try builder.append(scene.Clip, &builder.clips, .empty);
    const root = try builder.paintResolvedPattern(index, path, frame, style, 1, definition);
    if (root) |at| _ = try builder.append(usize, &builder.roots, at);
    const program: scene.Program = .{ .owner = std.Thread.getCurrentId(), .geometries = builder.geometries.items, .brushes = builder.brushes.items, .gradients = builder.gradients.items, .clips = builder.clips.items, .masks = builder.masks.items, .nodes = builder.nodes.items, .children = builder.children.items, .roots = builder.roots.items };
    if (builder.budget.remaining() == 0) return error.CapacityExceeded;
    const raster = scene.Raster.create(builder.allocator(), program, .{ .bytes = builder.budget.remaining(), .layers = limits.layers -| parent.layers, .calls = 128, .cancellation = parent.options.cancellation }, &builder.work) catch |err| return builder.budget.failure(err);
    defer raster.close() catch unreachable;
    try raster.renderClipped(output, parent.options.width, parent.options.height, if (frame.samples) |bits| .{ .samples = bits, .stride = (parent.options.width + 3) & ~@as(u32, 3) } else null, &builder.work, parent.options.cancellation);
}

test "image source extension does not enlarge common compiled scene payloads" {
    std.debug.print("svg_image_compiled_sizes builder={d} raster={d} scene_work={d} frame={d} limits={d}\n", .{ @sizeOf(Builder), @sizeOf(scene.Raster), @sizeOf(scene.Work), @sizeOf(pre.Frame), @sizeOf(pre.Limits) });
}

test "failed borrowed pattern scene merges work once and keeps stylesheet and refs owned by parent" {
    const a = std.testing.allocator;
    const document = try d.Document.parse(a, "<svg><style>rect{fill:red}</style><defs><pattern id='p' patternUnits='userSpaceOnUse' x='.5' width='4' height='4'><rect width='4' height='4'/></pattern></defs></svg>", .{});
    defer document.close() catch unreachable;
    var sheet = try css.Sheet.init(a, d.state(document).nodes, .{}, 1024 * 1024);
    defer sheet.deinit();
    var references = try refs.Index.init(a, d.state(document).nodes, 1024 * 1024);
    defer references.deinit();
    const path = try v.Path.create(a, &.{ .{ .move = .{} }, .{ .line = .{ .x = 8 } }, .{ .line = .{ .x = 8, .y = 4 } }, .{ .line = .{ .y = 4 } }, .close }, .{});
    defer path.close() catch unreachable;
    var parent: pre.Work = .{ .allocator = a, .document = d.state(document), .options = .{ .main_thread = std.Thread.getCurrentId(), .width = 8, .height = 4 }, .live = 0, .peak = 0, .sheet = &sheet, .references = &references, .style_work = .{ .limit = 1024 * 1024 }, .parse_work = .{ .limit = 1024 * 1024 } };
    var ledger: scene.Work = .{ .color = .{ .limit = 1 } };
    var pixels: [8 * 4 * 4]u8 = @splat(0);
    const frame: Frame = .{ .matrix = .{}, .viewport = .{ .width = 8, .height = 4 }, .style = .{} };
    const index = references.find("p").?;
    const definition = (try patterns.plan(&parent, index, frame, path, &parent)).?;
    try std.testing.expectError(error.ColorWorkExceeded, renderPattern(&parent, &ledger, index, path, frame, .{ .fill = .nonzero }, definition, &pixels));
    try std.testing.expectEqual(@as(usize, 0), parent.live);
    try std.testing.expect(parent.parse_work.used > 0 and parent.style_work.used > 0 and parent.node_visits > 0 and parent.vertices > 0 and parent.pixel_work > 0 and parent.sample_work > 0 and ledger.ops > 0);
    const first = parent;
    const first_ops = ledger.ops;
    const next_definition = (try patterns.plan(&parent, index, frame, path, &parent)).?;
    try std.testing.expectError(error.ColorWorkExceeded, renderPattern(&parent, &ledger, index, path, frame, .{ .fill = .nonzero }, next_definition, &pixels));
    try std.testing.expectEqual(@as(usize, 0), parent.live);
    inline for (.{ "vertices", "edges", "paths", "node_visits", "pixel_work", "sample_work" }) |field| try std.testing.expectEqual(@field(first, field) * 2, @field(parent, field));
    try std.testing.expectEqual(first.parse_work.used * 2, parent.parse_work.used);
    try std.testing.expectEqual(first.style_work.used * 2, parent.style_work.used);
    try std.testing.expectEqual(first_ops * 2, ledger.ops);
    try std.testing.expectEqual(@as(usize, 1), sheet.rules.len);
    try std.testing.expectEqual(index, references.find("p").?);
}
test "pattern coordinate policy rejects before any scene allocation" {
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
        var builder: Builder = .{ .budget = .{ .child = a, .limit = 0, .live = 0, .peak = 0 } };
        // Stack-only borrowed fixture: zero allocation allowance. The normal
        // owning destructor also destroys its heap Builder, so is not used.
        builder.source = .{ .allocator = builder.allocator(), .allocator_budgeted = true, .document = d.state(document), .options = .{ .main_thread = std.Thread.getCurrentId(), .width = 8, .height = 4 }, .live = 0, .peak = 0, .sheet = &sheet, .references = &references, .style_work = .{ .limit = 1024 * 1024 }, .parse_work = .{ .limit = 1024 * 1024 } };
        const frame: Frame = .{ .matrix = .{}, .viewport = .{ .width = 8, .height = 4 }, .style = .{} };
        try std.testing.expectError(error.UnsupportedPatternCoordinateSpace, builder.paintPattern(references.find("p").?, path, frame, .{ .fill = .nonzero }, 1, null));
        try std.testing.expect(!builder.budget.denied);
        try std.testing.expectEqual(@as(usize, 0), builder.geometries.items.len);
        try std.testing.expectEqual(@as(usize, 0), builder.budget.peak);
    }
}
