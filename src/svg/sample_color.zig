const std = @import("std");

// Preparation-only premultiplied encoded-sRGB colors, in BGRA channel order.
// Geometry is sampled at 4x4 positions; a paint's pixel-center color is shared
// by its sixteen lanes. This is compositing, not gradient color integration.
pub const Color = @Vector(4, f64);
pub const width_limit = 32;
pub const sample_count = 16;
// Scene reserves these u16 writes in its cumulative sample budget before
// begin/push. Work below counts only four-channel color operations.
pub const scope_clip_reset_writes = width_limit;
const plane_len = width_limit * sample_count;
const zero: Color = @splat(0);
const Scope = struct { opacity: f64 = 1, clip: [width_limit]u16 = @splat(0xffff) };

pub const Work = struct {
    limit: u64 = 128 * 1024 * 1024,
    rgba_operations: u64 = 0,
    pub fn charge(self: *Work, count: usize) !void {
        if (count > self.limit -| self.rgba_operations) return error.ColorWorkExceeded;
        self.rgba_operations += count;
    }
};

pub const Tile = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    planes: []Color,
    scopes: []Scope,
    owned_bytes: usize,
    width: usize = 0,
    depth: usize = 0,

    // Root plus `layers` isolated groups. All planes are reserved here; push,
    // pop, paint, resolve and discard allocate nothing.
    pub fn create(allocator: std.mem.Allocator, layers: usize, bytes: usize) !*Tile {
        if (layers > 32) return error.InvalidLayers;
        const plane_count = layers + 1;
        const required = @sizeOf(Tile) + plane_count * (plane_len * @sizeOf(Color) + @sizeOf(Scope));
        if (required > bytes) return error.CapacityExceeded;
        const planes = try allocator.alloc(Color, plane_count * plane_len);
        errdefer allocator.free(planes);
        const scopes = try allocator.alloc(Scope, plane_count);
        errdefer allocator.free(scopes);
        const result = try allocator.create(Tile);
        result.* = .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .planes = planes, .scopes = scopes, .owned_bytes = required };
        return result;
    }
    fn checkOwner(self: *const Tile) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
    }
    fn checkStarted(self: *const Tile) !void {
        try self.checkOwner();
        if (self.width == 0) return error.TileNotStarted;
    }
    fn plane(self: *Tile, depth: usize) []Color {
        return self.planes[depth * plane_len ..][0 .. self.width * sample_count];
    }
    pub fn begin(self: *Tile, width: usize, work: *Work) !void {
        try self.checkOwner();
        if (width == 0 or width > width_limit) return error.InvalidTileWidth;
        try work.charge(width * sample_count);
        self.width = width;
        self.depth = 0;
        self.scopes[0] = .{};
        @memset(self.plane(0), zero);
    }
    pub fn paint(self: *Tile, bits: []const u16, colors: []const Color, opacity: f64, work: *Work) !void {
        try self.checkStarted();
        if (bits.len != self.width or colors.len != self.width) return error.InvalidTileInput;
        try factor(opacity);
        var count: usize = 0;
        for (bits, colors) |coverage, color| {
            try validColor(color);
            count += @popCount(coverage);
        }
        try work.charge(count);
        const target = self.plane(self.depth);
        for (bits, colors, 0..) |coverage, color, pixel| {
            const source = color * @as(Color, @splat(opacity));
            for (0..sample_count) |lane| {
                if (coverage & (@as(u16, 1) << @intCast(lane)) != 0) over(&target[pixel * sample_count + lane], source);
            }
        }
    }
    pub fn push(self: *Tile, opacity: f64, clip: ?[]const u16, work: *Work) !void {
        try self.checkStarted();
        try factor(opacity);
        if (clip) |bits| if (bits.len != self.width) return error.InvalidTileInput;
        if (self.depth + 1 == self.scopes.len) return error.LayersFull;
        try work.charge(self.width * sample_count);
        self.depth += 1;
        self.scopes[self.depth] = .{ .opacity = opacity };
        if (clip) |bits| @memcpy(self.scopes[self.depth].clip[0..self.width], bits);
        @memset(self.plane(self.depth), zero);
    }
    // A mask is one continuous alpha factor per physical pixel. It is shared
    // across sixteen lanes and is not a sixteen-sample mask-color field.
    pub fn pop(self: *Tile, mask: ?[]const f64, work: *Work) !void {
        try self.checkStarted();
        if (self.depth == 0) return error.UnbalancedGroup;
        if (mask) |values| {
            if (values.len != self.width) return error.InvalidTileInput;
            for (values) |value| try factor(value);
        }
        try work.charge(self.width * sample_count);
        const scope = &self.scopes[self.depth];
        const source = self.plane(self.depth);
        const target = self.plane(self.depth - 1);
        for (0..self.width) |pixel| {
            const amount = scope.opacity * (if (mask) |values| values[pixel] else 1);
            for (0..sample_count) |lane| {
                if (scope.clip[pixel] & (@as(u16, 1) << @intCast(lane)) != 0) over(&target[pixel * sample_count + lane], source[pixel * sample_count + lane] * @as(Color, @splat(amount)));
            }
        }
        self.depth -= 1;
    }
    // Read the current completed group as if composited onto transparent
    // black. A mask program can read this, discard it, then mask its caller.
    pub fn mean(self: *Tile, output: []Color, work: *Work) !void {
        try self.checkStarted();
        if (output.len != self.width) return error.InvalidTileInput;
        try work.charge(self.width * (sample_count + 1));
        for (output, 0..) |*color, pixel| color.* = self.meanPixel(pixel);
    }
    fn meanPixel(self: *Tile, pixel: usize) Color {
        const scope = &self.scopes[self.depth];
        var color = zero;
        const current = self.plane(self.depth);
        for (0..sample_count) |lane| {
            if (scope.clip[pixel] & (@as(u16, 1) << @intCast(lane)) != 0) color += current[pixel * sample_count + lane];
        }
        return color * @as(Color, @splat(scope.opacity / sample_count));
    }
    pub fn discard(self: *Tile) !void {
        try self.checkStarted();
        if (self.depth == 0) return error.UnbalancedGroup;
        self.depth -= 1;
    }
    pub fn resolve(self: *Tile, output: []u8, work: *Work) !void {
        try self.checkStarted();
        if (self.depth != 0) return error.UnbalancedGroup;
        if (output.len < self.width * 4) return error.OutputFull;
        try work.charge(self.width * (sample_count + 1));
        for (0..self.width) |pixel| {
            const color: [4]f64 = self.meanPixel(pixel);
            const alpha = quantize(color[3]);
            for (0..3) |channel| output[pixel * 4 + channel] = @min(alpha, quantize(color[channel]));
            output[pixel * 4 + 3] = alpha;
        }
    }
    pub fn stats(self: *const Tile) !usize {
        try self.checkOwner();
        return self.owned_bytes;
    }
    pub fn close(self: *Tile) !void {
        try self.checkOwner();
        const allocator = self.allocator;
        allocator.free(self.scopes);
        allocator.free(self.planes);
        allocator.destroy(self);
    }
};
fn factor(value: f64) !void {
    if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidOpacity;
}
fn validColor(color: Color) !void {
    try factor(color[3]);
    inline for (0..3) |index| if (!std.math.isFinite(color[index]) or color[index] < 0 or color[index] > color[3]) return error.InvalidPremultipliedColor;
}
fn over(target: *Color, source: Color) void {
    target.* = source + target.* * @as(Color, @splat(1 - source[3]));
}
fn quantize(value: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}
