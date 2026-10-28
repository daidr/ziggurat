const std = @import("std");
const v = @import("ziggurat_vector");
const g = v.geometry;
const sample = @import("sample_color.zig");
pub const Gradient = @import("gradient.zig").Resolved;
pub const Color = sample.Color;
const full_samples: [sample.width_limit]u16 = @splat(0xffff);
pub const Range = struct { start: usize = 0, len: usize = 0 };
pub const Brush = union(enum) { solid: Color, gradient: usize, image: *const @import("image.zig").Paint };
const Pair = struct { a: usize, b: usize };
pub const Clip = union(enum) { empty, geometry: usize, union_of: Pair, intersection: Pair };
pub const Node = union(enum) {
    paint: struct { geometry: usize, brush: usize, clip: ?usize = null, opacity: f64 = 1 },
    group: struct { children: Range, clip: ?usize = null, mask: ?usize = null, opacity: f64 = 1 },
};
pub const Mask = struct { node: usize, mode: enum { alpha, luminance } = .luminance, linear_rgb: bool = false };

// A private compiled descriptor: arrays stay immutable and alive until Raster
// closes. They contain indices, geometry edges and copied brush data, never
// source XML/CSS or application callbacks. Child/clip/mask dependencies point
// backwards, so repeated instances form a finite DAG without runtime discovery.
pub const Program = struct {
    owner: std.Thread.Id,
    geometries: []const *g.Geometry,
    brushes: []const Brush,
    gradients: []const Gradient = &.{},
    clips: []const Clip = &.{},
    masks: []const Mask = &.{},
    nodes: []const Node,
    children: []const usize,
    roots: []const usize,
};
pub const Limits = struct { bytes: usize = 64 * 1024 * 1024, layers: usize = 8, calls: usize = 64, cancellation: ?*const v.Cancellation = null };
pub const Work = struct {
    op_limit: u64 = 128 * 1024 * 1024,
    ops: u64 = 0,
    color: sample.Work = .{},
    geometry: g.Work = .{},
    pixel_limit: u64 = 128 * 1024 * 1024,
    pixel_work: u64 = 0,
    pub fn step(self: *Work, count: usize, cancellation: ?*const v.Cancellation) !void {
        if (count > self.op_limit -| self.ops) return error.SceneWorkExceeded;
        if (self.ops % 256 == 0) if (cancellation) |cancel| try cancel.check();
        self.ops += count;
    }
    fn samples(self: *Work, count: usize) !void {
        if (count > self.geometry.sample_limit -| self.geometry.sample_work) return error.SampleWorkExceeded;
        self.geometry.sample_work += count;
    }
    fn pixels(self: *Work, count: usize) !void {
        if (count > self.pixel_limit -| self.pixel_work) return error.PixelWorkExceeded;
        self.pixel_work += count;
    }
};
// These bounds only cull raster work after clip/mask effects. They are not
// the analytic object bounds used to resolve objectBoundingBox resources.
const Meta = struct { bounds: ?v.Bounds, layers: usize = 0, calls: usize = 1 };
const ClipMeta = struct {
    bounds: ?v.Bounds,
    depth: usize = 0,
    epoch: u64 = 0,
    bits: [sample.width_limit]u16 = undefined,
};

pub const Raster = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    program: Program,
    nodes: []Meta,
    clips: []ClipMeta,
    call_clips: []u16,
    rows: *g.Rows,
    tile: *sample.Tile,
    owned_bytes: usize,
    busy: bool = false,
    width: usize = 0,
    clip_epoch: u64 = 0,
    bits: [sample.width_limit]u16 = undefined,
    colors: [sample.width_limit]Color = undefined,
    means: [sample.width_limit]Color = undefined,
    factors: [sample.width_limit]f64 = undefined,

    // The byte limit is the remaining scene budget after its owned program,
    // geometry and candidate output are counted. It includes all geometries'
    // Rows scratch, metadata, f64 planes and clip buffers together.
    pub fn create(allocator: std.mem.Allocator, program: Program, limits: Limits, work: *Work) !*Raster {
        if (program.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (limits.bytes == 0 or limits.bytes > 256 * 1024 * 1024 or limits.layers > 32 or limits.calls == 0 or limits.calls > 128) return error.InvalidLimits;
        if (limits.cancellation) |cancel| try cancel.check();
        for ([_]usize{ program.geometries.len, program.brushes.len, program.gradients.len, program.clips.len, program.masks.len, program.nodes.len, program.children.len, program.roots.len }) |length| if (length > 1024 * 1024) return error.CapacityExceeded;
        for (program.geometries) |geometry| {
            try work.step(1, limits.cancellation);
            try geometry.checkOwner();
        }
        var bytes: usize = @sizeOf(Raster);
        try addBytes(&bytes, program.nodes.len, @sizeOf(Meta), limits.bytes);
        try addBytes(&bytes, program.clips.len, @sizeOf(ClipMeta), limits.bytes);
        const nodes = try allocator.alloc(Meta, program.nodes.len);
        errdefer allocator.free(nodes);
        const clips = try allocator.alloc(ClipMeta, program.clips.len);
        errdefer allocator.free(clips);
        for (program.clips, clips, 0..) |clip, *meta, index| {
            try work.step(1, limits.cancellation);
            meta.* = switch (clip) {
                .empty => .{ .bounds = null },
                .geometry => |at| .{ .bounds = try geometryBounds(program, at) },
                .union_of, .intersection => |pair| value: {
                    if (pair.a >= index or pair.b >= index) return error.InvalidSceneDependency;
                    const depth = 1 + @max(clips[pair.a].depth, clips[pair.b].depth);
                    if (depth > 32) return error.ReferenceDepthFull;
                    break :value .{ .bounds = if (clip == .union_of) unite(clips[pair.a].bounds, clips[pair.b].bounds) else intersect(clips[pair.a].bounds, clips[pair.b].bounds), .depth = depth };
                },
            };
        }
        for (program.brushes) |brush| {
            try work.step(1, limits.cancellation);
            switch (brush) {
                .solid => |color| try validColor(color),
                .gradient => |at| if (at >= program.gradients.len) return error.InvalidSceneIndex,
                .image => |paint| try paint.validate(),
            }
        }
        for (program.gradients) |gradient| {
            try work.step(1, limits.cancellation);
            if (gradient.count > gradient.stops.len) return error.InvalidSceneGradient;
            var last: f64 = 0;
            for (gradient.stops[0..gradient.count]) |stop| {
                try work.step(1, limits.cancellation);
                if (!std.math.isFinite(stop.offset) or stop.offset < last or stop.offset > 1) return error.InvalidSceneGradient;
                for (stop.channels) |channel| try factor(channel);
                last = stop.offset;
            }
        }
        for (program.masks) |mask| {
            try work.step(1, limits.cancellation);
            if (mask.node >= program.nodes.len) return error.InvalidSceneIndex;
        }
        var layers: usize = 0;
        var calls: usize = 1;
        for (program.nodes, nodes, 0..) |node, *meta, index| {
            try work.step(1, limits.cancellation);
            meta.* = switch (node) {
                .paint => |paint| value: {
                    try factor(paint.opacity);
                    if (paint.brush >= program.brushes.len) return error.InvalidSceneIndex;
                    break :value .{ .bounds = try geometryBounds(program, paint.geometry) };
                },
                .group => |group| value: {
                    try factor(group.opacity);
                    const children = try childRange(program, group.children);
                    var result: Meta = .{ .bounds = null };
                    for (children) |child| {
                        try work.step(1, limits.cancellation);
                        if (child >= index) return error.InvalidSceneDependency;
                        result.bounds = unite(result.bounds, nodes[child].bounds);
                        result.layers = @max(result.layers, nodes[child].layers);
                        result.calls = @max(result.calls, 1 + nodes[child].calls);
                    }
                    const isolated = group.opacity != 1 or group.mask != null;
                    if (isolated) result.layers += 1;
                    if (group.mask) |at| {
                        if (at >= program.masks.len) return error.InvalidSceneIndex;
                        const source = program.masks[at].node;
                        if (source >= index) return error.InvalidSceneDependency;
                        result.bounds = intersect(result.bounds, nodes[source].bounds);
                        result.layers = @max(result.layers, 2 + nodes[source].layers);
                        result.calls = @max(result.calls, 1 + nodes[source].calls);
                    }
                    break :value result;
                },
            };
            const clip = switch (node) {
                .paint => |paint| paint.clip,
                .group => |group| group.clip,
            };
            if (clip) |at| {
                if (at >= clips.len) return error.InvalidSceneIndex;
                meta.bounds = intersect(meta.bounds, clips[at].bounds);
            }
            layers = @max(layers, meta.layers);
            calls = @max(calls, meta.calls);
            if (layers > limits.layers) return error.LayersFull;
            if (calls > limits.calls) return error.ReferenceDepthFull;
        }
        for (program.roots) |index| {
            try work.step(1, limits.cancellation);
            if (index >= nodes.len) return error.InvalidSceneIndex;
        }
        try addBytes(&bytes, calls * sample.width_limit, @sizeOf(u16), limits.bytes);
        const call_clips = try allocator.alloc(u16, calls * sample.width_limit);
        errdefer allocator.free(call_clips);
        const rows = try g.Rows.create(allocator, program.geometries, limits.bytes - bytes);
        errdefer rows.close() catch unreachable;
        bytes += try rows.stats();
        const tile = try sample.Tile.create(allocator, layers, limits.bytes - bytes);
        errdefer tile.close() catch unreachable;
        bytes += try tile.stats();
        const result = try allocator.create(Raster);
        result.* = .{ .allocator = allocator, .owner = program.owner, .program = program, .nodes = nodes, .clips = clips, .call_clips = call_clips, .rows = rows, .tile = tile, .owned_bytes = bytes };
        return result;
    }
    fn checkOwner(self: *const Raster) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
    }
    // The output is a private candidate. An error may leave that candidate
    // partially written; the owning preparation layer must discard it and
    // publish only after the entire render succeeds.
    pub fn render(self: *Raster, output: []u8, width: u32, height: u32, work: *Work, cancellation: ?*const v.Cancellation) !void {
        return self.renderClipped(output, width, height, null, work, cancellation);
    }
    pub fn renderClipped(self: *Raster, output: []u8, width: u32, height: u32, inherited: ?struct { samples: []const u16, stride: usize }, work: *Work, cancellation: ?*const v.Cancellation) !void {
        try self.checkOwner();
        if (self.busy) return error.Busy;
        if (width == 0 or height == 0 or width > 16384 or height > 16384 or @as(u64, width) * height > 16 * 1024 * 1024) return error.InvalidViewport;
        if (output.len < @as(usize, width) * height * 4) return error.OutputFull;
        if (inherited) |clip| if (clip.stride < width or clip.stride > clip.samples.len / height) return error.InvalidSceneClip;
        self.busy = true;
        defer self.busy = false;
        for (0..height) |y| {
            if (cancellation) |cancel| try cancel.check();
            var x: usize = 0;
            while (x < width) : (x += self.width) {
                // An epoch names one (x, y, width) tile. No per-tile table
                // clear, wraparound or traversal of unused clips is hidden.
                if (self.clip_epoch == std.math.maxInt(u64)) return error.GenerationExhausted;
                self.clip_epoch += 1;
                self.width = @min(sample.width_limit, width - x);
                try work.pixels(self.width);
                try work.samples(sample.scope_clip_reset_writes);
                try self.tile.begin(self.width, &work.color);
                const clip = if (inherited) |value| value.samples[y * value.stride + x ..][0..self.width] else full_samples[0..self.width];
                for (self.program.roots) |root| try self.draw(root, @intCast(x), @intCast(y), 0, clip, work, cancellation);
                try self.tile.resolve(output[(y * width + x) * 4 ..][0 .. self.width * 4], &work.color);
            }
        }
    }
    fn draw(self: *Raster, index: usize, x: i32, y: i32, depth: usize, inherited: []const u16, work: *Work, cancellation: ?*const v.Cancellation) anyerror!void {
        try work.step(1, cancellation);
        if (!overlaps(self.nodes[index].bounds, x, y, self.width)) return;
        const node = self.program.nodes[index];
        const clip = self.call_clips[depth * sample.width_limit ..][0..self.width];
        try work.samples(self.width);
        @memcpy(clip, inherited);
        const clip_id = switch (node) {
            .paint => |paint| paint.clip,
            .group => |group| group.clip,
        };
        if (clip_id) |at| {
            const clip_bits = try self.sampleClip(at, x, y, work, cancellation);
            try work.samples(self.width);
            for (clip, clip_bits) |*target, value| target.* &= value;
        }
        switch (node) {
            .paint => |paint| {
                try work.pixels(self.width);
                const row = try self.rows.prepare(paint.geometry, y, &work.geometry, cancellation);
                try row.writeSamples(x, self.bits[0..self.width], &work.geometry);
                try work.samples(self.width);
                for (self.bits[0..self.width], clip) |*bits, value| bits.* &= value;
                const brush = self.program.brushes[paint.brush];
                for (self.colors[0..self.width], 0..) |*color, column| color.* = if (self.bits[column] == 0) @splat(0) else switch (brush) {
                    .solid => |value| value,
                    .image => |paint_value| value: {
                        try work.step(16, cancellation);
                        const channels = try paint_value.sample(.{ .x = @as(f64, @floatFromInt(x)) + @as(f64, @floatFromInt(column)) + 0.5, .y = @as(f64, @floatFromInt(y)) + 0.5 });
                        break :value @as(Color, channels) / @as(Color, @splat(255));
                    },
                    .gradient => |at| value: {
                        try work.step(1, cancellation);
                        const channels = try self.program.gradients[at].sample(.{ .x = @as(f64, @floatFromInt(x)) + @as(f64, @floatFromInt(column)) + 0.5, .y = @as(f64, @floatFromInt(y)) + 0.5 });
                        break :value @as(Color, channels) / @as(Color, @splat(255));
                    },
                };
                try self.tile.paint(self.bits[0..self.width], self.colors[0..self.width], paint.opacity, &work.color);
            },
            .group => |group| {
                const isolated = group.opacity != 1 or group.mask != null;
                if (isolated) {
                    try work.samples(sample.scope_clip_reset_writes + self.width);
                    try self.tile.push(group.opacity, clip, &work.color);
                }
                for (try childRange(self.program, group.children)) |child| try self.draw(child, x, y, depth + 1, if (isolated) full_samples[0..self.width] else clip, work, cancellation);
                if (group.mask) |at| {
                    const mask = self.program.masks[at];
                    try work.samples(sample.scope_clip_reset_writes);
                    try self.tile.push(1, null, &work.color);
                    try self.draw(mask.node, x, y, depth + 1, full_samples[0..self.width], work, cancellation);
                    try self.tile.mean(self.means[0..self.width], &work.color);
                    try self.tile.discard();
                    try work.pixels(self.width);
                    try work.color.charge(self.width);
                    for (self.factors[0..self.width], self.means[0..self.width]) |*amount, mean| amount.* = maskFactor(mean, mask);
                    try self.tile.pop(self.factors[0..self.width], &work.color);
                } else if (isolated) try self.tile.pop(null, &work.color);
            },
        }
    }
    fn sampleClip(self: *Raster, index: usize, x: i32, y: i32, work: *Work, cancellation: ?*const v.Cancellation) anyerror![]const u16 {
        try work.step(1, cancellation);
        const cache = &self.clips[index];
        if (cache.epoch == self.clip_epoch) return cache.bits[0..self.width];
        const output = cache.bits[0..self.width];
        if (!overlaps(cache.bounds, x, y, self.width)) {
            try work.samples(self.width);
            @memset(output, 0);
        } else switch (self.program.clips[index]) {
            .empty => unreachable,
            .geometry => |at| {
                const row = try self.rows.prepare(at, y, &work.geometry, cancellation);
                try row.writeSamples(x, output, &work.geometry);
            },
            .union_of, .intersection => |pair| {
                const first = try self.sampleClip(pair.a, x, y, work, cancellation);
                const second = try self.sampleClip(pair.b, x, y, work, cancellation);
                try work.samples(self.width);
                for (output, first, second) |*target, a, b| target.* = if (self.program.clips[index] == .union_of) a | b else a & b;
            },
        }
        // Publish only after the complete result succeeds. A cancelled or
        // exhausted computation cannot be observed as a cache hit.
        cache.epoch = self.clip_epoch;
        return output;
    }
    pub fn stats(self: *const Raster) !usize {
        try self.checkOwner();
        return self.owned_bytes;
    }
    pub fn close(self: *Raster) !void {
        try self.checkOwner();
        if (self.busy) return error.Busy;
        try self.tile.close();
        try self.rows.close();
        const allocator = self.allocator;
        allocator.free(self.call_clips);
        allocator.free(self.clips);
        allocator.free(self.nodes);
        allocator.destroy(self);
    }
};
fn addBytes(total: *usize, count: usize, size: usize, limit: usize) !void {
    if (count > (limit -| total.*) / size) return error.CapacityExceeded;
    total.* += count * size;
    if (total.* > limit) return error.CapacityExceeded;
}
fn geometryBounds(program: Program, index: usize) !?v.Bounds {
    if (index >= program.geometries.len) return error.InvalidSceneIndex;
    return program.geometries[index].bounds;
}
fn childRange(program: Program, range: Range) ![]const usize {
    if (range.start > program.children.len or range.len > program.children.len - range.start) return error.InvalidSceneIndex;
    return program.children[range.start..][0..range.len];
}
fn factor(value: f64) !void {
    if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidOpacity;
}
fn validColor(color: Color) !void {
    try factor(color[3]);
    inline for (0..3) |index| if (!std.math.isFinite(color[index]) or color[index] < 0 or color[index] > color[3]) return error.InvalidPremultipliedColor;
}
fn unite(a: ?v.Bounds, b: ?v.Bounds) ?v.Bounds {
    const first = a orelse return b;
    const second = b orelse return a;
    const left = @min(first.x, second.x);
    const top = @min(first.y, second.y);
    return .{ .x = left, .y = top, .width = @max(first.x + first.width, second.x + second.width) - left, .height = @max(first.y + first.height, second.y + second.height) - top };
}
fn intersect(a: ?v.Bounds, b: ?v.Bounds) ?v.Bounds {
    const first = a orelse return null;
    const second = b orelse return null;
    const left = @max(first.x, second.x);
    const top = @max(first.y, second.y);
    const right = @min(first.x + first.width, second.x + second.width);
    const bottom = @min(first.y + first.height, second.y + second.height);
    if (right <= left or bottom <= top) return null;
    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
}
fn overlaps(bounds: ?v.Bounds, x: i32, y: i32, width: usize) bool {
    const box = bounds orelse return false;
    const left: f64 = @floatFromInt(x);
    const top: f64 = @floatFromInt(y);
    return left < box.x + box.width and left + @as(f64, @floatFromInt(width)) > box.x and top < box.y + box.height and top + 1 > box.y;
}
fn maskFactor(mean_vector: Color, mask: Mask) f64 {
    const mean: [4]f64 = mean_vector;
    // The mask remains a continuous alpha image resolved at physical pixels.
    // Quantize its premultiplied image once before the existing mask formula.
    const alpha = @round(std.math.clamp(mean[3], 0, 1) * 255) / 255;
    if (mask.mode == .alpha or alpha == 0) return alpha;
    var straight: [3]f64 = undefined;
    for (&straight, 0..) |*channel, index| {
        channel.* = @min(alpha, @round(std.math.clamp(mean[index], 0, 1) * 255) / 255) / alpha;
        if (mask.linear_rgb) channel.* = if (channel.* <= 0.04045) channel.* / 12.92 else std.math.pow(f64, (channel.* + 0.055) / 1.055, 2.4);
    }
    return std.math.clamp((straight[2] * 0.2125 + straight[1] * 0.7154 + straight[0] * 0.0721) * alpha, 0, 1);
}
