//! Private capture and explicit residency plan shared by every live backend.
const std = @import("std");
const drawing = @import("ziggurat_drawing_resources");
const layers = @import("layers.zig");
const layout = @import("layout.zig");
const arithmetic = @import("gaussian_kernel.zig");
pub const Options = struct {
    layers: layers.Options,
    source_size: layout.Size,
    max_radius: u32 = arithmetic.max_radius,
    filter_samples: u64 = 128 * 1024 * 1024,
    render_work: u64 = 128 * 1024 * 1024,
};
pub const FilterOptions = struct { source_size: layout.Size, max_radius: u32 = arithmetic.max_radius, filter_samples: u64 = 128 * 1024 * 1024 };
pub fn withLayers(filter: FilterOptions, layer_options: layers.Options, render_work: u64) Options {
    return .{ .layers = layer_options, .source_size = filter.source_size, .max_radius = filter.max_radius, .filter_samples = filter.filter_samples, .render_work = render_work };
}
/// Physical capacity, independent of a capture's position in its parent.
pub const Capacity = extern struct {
    source_width: u32,
    source_height: u32,
    max_radius: u32,
    scale: f32,
    filter_samples: u64,
    pub fn validate(self: Capacity) !void {
        if (self.source_width == 0 or self.source_height == 0 or self.source_width > 16384 or self.source_height > 16384 or self.max_radius > arithmetic.max_radius or !std.math.isFinite(self.scale) or self.scale < 0.0625 or self.scale > 16 or self.filter_samples == 0 or self.filter_samples > 16 * 1024 * 1024 * 1024) return error.InvalidGaussianLimits;
        try dimensions(self.source_width + 2 * self.max_radius, self.source_height + 2 * self.max_radius);
    }
};
pub const Capture = extern struct {
    left: i32,
    top: i32,
    width: u32,
    height: u32,
    radius: u32,
    scale: f32,
    pub fn init(bounds: drawing.Rect, kernel: *const arithmetic.Kernel) !Capture {
        try kernel.validate();
        if (!std.math.isFinite(bounds.x) or !std.math.isFinite(bounds.y) or !std.math.isFinite(bounds.width) or !std.math.isFinite(bounds.height) or bounds.width <= 0 or bounds.height <= 0) return error.InvalidGaussianBounds;
        const scale: f64 = kernel.scale;
        const left = @floor(@as(f64, bounds.x) * scale);
        const top = @floor(@as(f64, bounds.y) * scale);
        const right = @ceil((@as(f64, bounds.x) + bounds.width) * scale);
        const bottom = @ceil((@as(f64, bounds.y) + bounds.height) * scale);
        // Leave space for the transparent halo and exactly representable
        // native integer offsets before any conversion or native work.
        const radius: f64 = @floatFromInt(kernel.radius);
        if (left - radius < std.math.minInt(i32) or top - radius < std.math.minInt(i32) or right + radius > std.math.maxInt(i32) or bottom + radius > std.math.maxInt(i32) or !std.math.isFinite(right) or !std.math.isFinite(bottom) or right <= left or bottom <= top or right - left > 16384 or bottom - top > 16384) return error.InvalidGaussianBounds;
        const result: Capture = .{ .left = @intFromFloat(left), .top = @intFromFloat(top), .width = @intFromFloat(right - left), .height = @intFromFloat(bottom - top), .radius = kernel.radius, .scale = kernel.scale };
        try dimensions(result.pixelWidth(), result.pixelHeight());
        return result;
    }
    pub fn pixelWidth(self: Capture) u32 {
        return self.width + 2 * self.radius;
    }
    pub fn pixelHeight(self: Capture) u32 {
        return self.height + 2 * self.radius;
    }
    pub fn origin(self: Capture) [2]f64 {
        return .{ @as(f64, @floatFromInt(self.radius)) - @as(f64, @floatFromInt(self.left)), @as(f64, @floatFromInt(self.radius)) - @as(f64, @floatFromInt(self.top)) };
    }
    pub fn samples(self: Capture) u64 {
        return @as(u64, self.pixelWidth()) * self.pixelHeight() * (self.radius * 2 + 1) * 2;
    }
    pub fn check(self: Capture, capacity: Capacity) !void {
        try capacity.validate();
        if (self.scale != capacity.scale) return error.GaussianDpiMismatch;
        if (self.radius > capacity.max_radius or self.width > capacity.source_width or self.height > capacity.source_height) return error.GaussianSourceExceeded;
        if (self.samples() > capacity.filter_samples) return error.GaussianWorkExceeded;
    }
};
pub const Plan = struct {
    layers: layers.Plan,
    capacity: Capacity,
    scratch_bytes: usize,
    pixel_bytes: usize,
    /// Existing raster-transform limits, if any, remain usable. Gaussian
    /// prepare does not change the coordinate workspace or accepted geometry.
    pub fn init(options: Options, backend: layers.Backend, transforms: ?layers.TransformOptions) !Plan {
        if (options.render_work == 0 or options.render_work > 512 * 1024 * 1024) return error.InvalidRenderLimits;
        const scale = options.layers.size.scale;
        if (!std.math.isFinite(options.source_size.width) or !std.math.isFinite(options.source_size.height) or options.source_size.width <= 0 or options.source_size.height <= 0 or !std.math.isFinite(scale) or scale < 0.0625 or scale > 16) return error.InvalidGaussianLimits;
        const width = @ceil(@as(f64, options.source_size.width) * scale) + 1;
        const height = @ceil(@as(f64, options.source_size.height) * scale) + 1;
        if (width > 16384 or height > 16384) return error.InvalidGaussianLimits;
        const capacity: Capacity = .{ .source_width = @intFromFloat(width), .source_height = @intFromFloat(height), .scale = scale, .max_radius = options.max_radius, .filter_samples = options.filter_samples };
        try capacity.validate();
        var base = if (transforms) |value| try layers.Plan.initTransforms(.{ .layers = options.layers, .source_size = value.source_size, .render_work = value.render_work }, backend) else try layers.Plan.init(options.layers, backend);
        base.pool_size.width = @max(base.pool_size.width, capacity.source_width + 2 * capacity.max_radius);
        base.pool_size.height = @max(base.pool_size.height, capacity.source_height + 2 * capacity.max_radius);
        try dimensions(base.pool_size.width, base.pool_size.height);
        base.pool_plane_bytes = @as(usize, base.pool_size.width) * base.pool_size.height * 4;
        base.pixel_bytes = base.plane_bytes * 2 + base.pool_plane_bytes * (base.planes - 2);
        const total = std.math.add(usize, base.pixel_bytes, base.pool_plane_bytes) catch return error.LayerBudgetExceeded;
        if (total > options.layers.bytes) return error.LayerBudgetExceeded;
        return .{ .layers = base, .capacity = capacity, .scratch_bytes = base.pool_plane_bytes, .pixel_bytes = total };
    }
    /// All old owners, metadata and both candidate backends participate in
    /// the same peak check; caller adds backend-specific metadata explicitly.
    pub fn checkPeak(first: Plan, second: ?Plan, old_bytes: usize, metadata: usize) !usize {
        const total = std.math.add(usize, std.math.add(usize, first.pixel_bytes, if (second) |value| value.pixel_bytes else 0) catch return error.LayerAggregateBudgetExceeded, std.math.add(usize, old_bytes, metadata) catch return error.LayerAggregateBudgetExceeded) catch return error.LayerAggregateBudgetExceeded;
        if (total > first.layers.options.total_bytes) return error.LayerAggregateBudgetExceeded;
        return total;
    }
};
fn dimensions(width: u32, height: u32) !void {
    if (width == 0 or height == 0 or width > 16384 or height > 16384 or @as(u64, width) * height > 16 * 1024 * 1024) return error.InvalidGaussianSurface;
}
comptime {
    if (@sizeOf(Capacity) != 24 or @sizeOf(Capture) != 24) @compileError("Gaussian capture ABI mismatch");
}

test "Gaussian capture pads outward independently of parent clipping" {
    const kernel = try arithmetic.Kernel.prepare(.{ .sigma = 0.5, .scale = 1.5 });
    const capture = try Capture.init(.{ .x = -2.25, .y = 4.1, .width = 4.5, .height = 2 }, &kernel);
    try std.testing.expectEqualDeep(Capture{ .left = -4, .top = 6, .width = 8, .height = 4, .radius = 3, .scale = 1.5 }, capture);
    try std.testing.expectEqualDeep([2]f64{ 7, -3 }, capture.origin());
    try std.testing.expectEqual(@as(u64, 1960), capture.samples());
    const capacity: Capacity = .{ .source_width = 8, .source_height = 4, .max_radius = 3, .scale = 1.5, .filter_samples = 1960 };
    try capture.check(capacity);
    var short = capacity;
    short.filter_samples -= 1;
    try std.testing.expectError(error.GaussianWorkExceeded, capture.check(short));
    short = capacity;
    short.scale = 1;
    try std.testing.expectError(error.GaussianDpiMismatch, capture.check(short));
    try std.testing.expectError(error.InvalidGaussianBounds, Capture.init(.{ .x = 1.0e20, .width = 1, .height = 1 }, &kernel));
}
test "Gaussian explicit plan includes scratch and simultaneous old candidates" {
    const options: Options = .{ .layers = .{ .size = .{ .width = 8, .height = 6, .scale = 1.5 }, .max_depth = 2 }, .source_size = .{ .width = 10, .height = 20 }, .max_radius = 3 };
    const cpu = try Plan.init(options, .gdi, null);
    const gpu = try Plan.init(options, .gpu, null);
    try std.testing.expectEqual(@as(u32, 22), cpu.layers.pool_size.width);
    try std.testing.expectEqual(@as(u32, 37), cpu.layers.pool_size.height);
    try std.testing.expectEqual(@as(usize, 8 * 6 * 4 * 2 + 22 * 37 * 4 * 4), cpu.pixel_bytes);
    const peak = try Plan.checkPeak(cpu, gpu, 123, 17);
    try std.testing.expectEqual(cpu.pixel_bytes + gpu.pixel_bytes + 140, peak);
    var limited = options;
    limited.layers.bytes = cpu.pixel_bytes - 1;
    try std.testing.expectError(error.LayerBudgetExceeded, Plan.init(limited, .gdi, null));
    var short = cpu;
    short.layers.options.total_bytes = peak - 1;
    try std.testing.expectError(error.LayerAggregateBudgetExceeded, Plan.checkPeak(short, gpu, 123, 17));
}
