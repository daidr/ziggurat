const std = @import("std");
pub const drawing = @import("ziggurat_drawing_resources");
pub const RoundedRect = struct { width: f32, height: f32, radius: f32 = 0 };
pub const Kind = enum { outer, inset };
pub const Shadow = struct { kind: Kind = .outer, offset: drawing.Point = .{}, spread: f32 = 0, sigma: f32 = 0 };
pub const PrepareOptions = struct {
    main_thread: std.Thread.Id,
    scale: f32 = 1,
    bytes: usize = 64 * 1024 * 1024,
    work_samples: u64 = 128 * 1024 * 1024,
    cancellation: ?*const std.atomic.Value(bool) = null,
};
pub const Stats = struct { bytes: usize, peak_bytes: usize, filter_samples: u64, width: u32, height: u32, radius: u32, elapsed_ns: ?u64 };
const max_radius = 128;
const max_kernel = max_radius * 2 + 1;
const kernel_bytes = max_kernel * @sizeOf(f64);

/// Immutable, color-independent shadow coverage. Preparation is explicit and
/// may run on an exclusively owning worker; native drawing remains on main.
pub const PreparedShadow = opaque {
    pub fn create(allocator: std.mem.Allocator, shape: RoundedRect, shadow: Shadow, options: PrepareOptions) !*PreparedShadow {
        try cancelled(options.cancellation);
        var timer = std.time.Timer.start() catch null;
        const plan = try Plan.init(shape, shadow, options);
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        const output = try allocator.alloc(u8, plan.pixels);
        errdefer allocator.free(output);
        const scratch = try allocator.alloc(u8, plan.pixels * 2);
        defer allocator.free(scratch);
        const input = scratch[0..plan.pixels];
        const temporary = scratch[plan.pixels..];
        @memset(input, 0);
        @memset(temporary, 0);
        @memset(output, 0);
        const scale: f64 = options.scale;
        for (0..plan.height) |y| {
            if (y % 16 == 0) try cancelled(options.cancellation);
            for (0..plan.width) |x| {
                if (x % 256 == 0) try cancelled(options.cancellation);
                const px = (@as(f64, @floatFromInt(plan.left)) + @as(f64, @floatFromInt(x)) + 0.5) / scale;
                const py = (@as(f64, @floatFromInt(plan.top)) + @as(f64, @floatFromInt(y)) + 0.5) / scale;
                const alpha = coverage(plan.caster, px, py, 1 / scale);
                input[y * plan.stride + x] = if (shadow.kind == .outer) alpha else 255 - alpha;
            }
        }
        var weights: [max_kernel]f64 = undefined;
        const count = plan.radius * 2 + 1;
        var sum: f64 = 0;
        for (weights[0..count], 0..) |*weight, index| {
            const offset = @as(f64, @floatFromInt(index)) - @as(f64, @floatFromInt(plan.radius));
            weight.* = if (plan.radius == 0) 1 else @exp(-(offset * offset) / (2 * plan.sigma * plan.sigma));
            sum += weight.*;
        }
        for (weights[0..count]) |*weight| weight.* /= sum;
        const outside: f64 = if (shadow.kind == .outer) 0 else 255;
        try blur(input, temporary, plan, weights[0..count], false, outside, options.cancellation);
        try blur(temporary, output, plan, weights[0..count], true, outside, options.cancellation);
        for (0..plan.height) |y| {
            if (y % 16 == 0) try cancelled(options.cancellation);
            for (0..plan.width) |x| {
                if (x % 256 == 0) try cancelled(options.cancellation);
                const px = (@as(f64, @floatFromInt(plan.left)) + @as(f64, @floatFromInt(x)) + 0.5) / scale;
                const py = (@as(f64, @floatFromInt(plan.top)) + @as(f64, @floatFromInt(y)) + 0.5) / scale;
                const original = coverage(plan.original, px, py, 1 / scale);
                const clip: u32 = if (shadow.kind == .outer) 255 - @as(u32, original) else original;
                const index = y * plan.stride + x;
                output[index] = @intCast((@as(u32, output[index]) * clip + 127) / 255);
            }
        }
        try cancelled(options.cancellation);
        state.* = .{
            .allocator = allocator,
            .lease = drawing.Lease.init(std.Thread.getCurrentId()),
            .main_thread = options.main_thread,
            .adopted = std.Thread.getCurrentId() == options.main_thread,
            .identity = try drawing.reserveRasterIdentity(),
            .data = output,
            .coverage = .{ .pixels = output, .width = plan.width, .height = plan.height, .stride = plan.stride, .origin_x = plan.left, .origin_y = plan.top, .scale = options.scale },
            .stats = .{ .bytes = @sizeOf(State) + plan.pixels, .peak_bytes = plan.peak_bytes, .filter_samples = plan.filter_samples, .width = plan.width, .height = plan.height, .radius = plan.radius, .elapsed_ns = if (timer) |*clock| clock.read() else null },
        };
        return @ptrCast(state);
    }
    pub fn adopt(self: *PreparedShadow) !void {
        const state = cast(self);
        if (std.Thread.getCurrentId() != state.main_thread) return error.WrongThread;
        if (state.adopted) return error.AlreadyAdopted;
        if (state.lease.pins != 0) return error.ResourceInUse;
        state.lease.owner = state.main_thread;
        state.adopted = true;
    }
    pub fn view(self: *const PreparedShadow) !drawing.CoverageView {
        const state = cast(@constCast(self));
        try state.lease.checkOwner();
        if (!state.adopted) return error.NotAdopted;
        return .{ .lease = &state.lease, .identity = state.identity, .coverage = state.coverage };
    }
    pub fn stats(self: *const PreparedShadow) !Stats {
        const state = cast(@constCast(self));
        try state.lease.checkOwner();
        return state.stats;
    }
    pub fn inUse(self: *const PreparedShadow) !bool {
        const state = cast(@constCast(self));
        try state.lease.checkOwner();
        return state.lease.pins != 0;
    }
    pub fn close(self: *PreparedShadow) !void {
        const state = cast(self);
        try state.lease.ensureUnused();
        const allocator = state.allocator;
        allocator.free(state.data);
        allocator.destroy(state);
    }
};
const State = struct { allocator: std.mem.Allocator, lease: drawing.Lease, main_thread: std.Thread.Id, adopted: bool, identity: u64, data: []u8, coverage: drawing.Coverage, stats: Stats };
fn cast(value: *PreparedShadow) *State {
    return @ptrCast(@alignCast(value));
}
const Box = struct { x: f64 = 0, y: f64 = 0, width: f64, height: f64, radius: f64 };
const Plan = struct {
    original: Box,
    caster: Box,
    left: i32,
    top: i32,
    width: u32,
    height: u32,
    stride: u32,
    pixels: usize,
    radius: u32,
    sigma: f64,
    peak_bytes: usize,
    filter_samples: u64,
    fn init(shape: RoundedRect, shadow: Shadow, options: PrepareOptions) !Plan {
        if (!std.math.isFinite(shape.width) or !std.math.isFinite(shape.height) or !std.math.isFinite(shape.radius) or shape.width <= 0 or shape.height <= 0 or shape.radius < 0 or !std.math.isFinite(shadow.offset.x) or !std.math.isFinite(shadow.offset.y) or !std.math.isFinite(shadow.spread) or !std.math.isFinite(shadow.sigma) or shadow.sigma < 0 or !std.math.isFinite(options.scale) or options.scale < 0.0625 or options.scale > 16) return error.InvalidShadow;
        if (options.bytes == 0 or options.bytes > 256 * 1024 * 1024 or options.work_samples == 0) return error.InvalidPrepareLimits;
        const sigma = @as(f64, shadow.sigma) * options.scale;
        const radius_float = @ceil(sigma * 3);
        if (radius_float > max_radius) return error.CapacityExceeded;
        const radius: u32 = @intFromFloat(radius_float);
        const original: Box = .{ .width = shape.width, .height = shape.height, .radius = @min(shape.radius, @min(shape.width, shape.height) * 0.5) };
        const spread: f64 = if (shadow.kind == .outer) shadow.spread else -@as(f64, shadow.spread);
        const caster: Box = .{ .x = -spread + shadow.offset.x, .y = -spread + shadow.offset.y, .width = @max(0, @as(f64, shape.width) + 2 * spread), .height = @max(0, @as(f64, shape.height) + 2 * spread), .radius = @max(0, original.radius + spread) };
        const extent = if (shadow.kind == .outer and caster.width > 0 and caster.height > 0) caster else original;
        // Inset is multiplied by the original contour. Only its finite filter
        // neighborhood can contribute; a distant hole must not grow storage.
        const min_x = if (shadow.kind == .inset) 0 else extent.x;
        const min_y = if (shadow.kind == .inset) 0 else extent.y;
        const max_x = if (shadow.kind == .inset) original.width else extent.x + extent.width;
        const max_y = if (shadow.kind == .inset) original.height else extent.y + extent.height;
        const left = @floor(min_x * options.scale) - radius_float;
        const top = @floor(min_y * options.scale) - radius_float;
        const right = @ceil(max_x * options.scale) + radius_float;
        const bottom = @ceil(max_y * options.scale) + radius_float;
        if (left < std.math.minInt(i32) or top < std.math.minInt(i32) or right > std.math.maxInt(i32) or bottom > std.math.maxInt(i32) or right <= left or bottom <= top or right - left > 16384 or bottom - top > 16384) return error.CapacityExceeded;
        const width: u32 = @intFromFloat(right - left);
        const height: u32 = @intFromFloat(bottom - top);
        const stride = (width + 3) & ~@as(u32, 3);
        const pixels = @as(usize, stride) * height;
        const peak = @sizeOf(State) + pixels * 3 + kernel_bytes;
        const work = @as(u64, width) * height * (radius * 2 + 1) * 2;
        if (pixels > drawing.max_coverage_bytes or peak > options.bytes or work > options.work_samples) return error.CapacityExceeded;
        return .{ .original = original, .caster = caster, .left = @intFromFloat(left), .top = @intFromFloat(top), .width = width, .height = height, .stride = stride, .pixels = pixels, .radius = radius, .sigma = sigma, .peak_bytes = peak, .filter_samples = work };
    }
};
fn cancelled(flag: ?*const std.atomic.Value(bool)) !void {
    if (flag) |value| if (value.load(.acquire)) return error.Cancelled;
}
fn distance(box: Box, x: f64, y: f64) f64 {
    const radius = @min(box.radius, @min(box.width, box.height) * 0.5);
    const qx = @abs(x - box.x - box.width * 0.5) - box.width * 0.5 + radius;
    const qy = @abs(y - box.y - box.height * 0.5) - box.height * 0.5 + radius;
    return @sqrt(@max(qx, 0) * @max(qx, 0) + @max(qy, 0) * @max(qy, 0)) + @min(@max(qx, qy), 0) - radius;
}
fn coverage(box: Box, x: f64, y: f64, pixel_size: f64) u8 {
    if (box.width <= 0 or box.height <= 0) return 0;
    const d = distance(box, x, y);
    const margin = pixel_size * 0.7071067811865476;
    if (d < -margin) return 255;
    if (d > margin) return 0;
    var count: u32 = 0;
    for (0..4) |sy| for (0..4) |sx| {
        if (distance(box, x + (@as(f64, @floatFromInt(sx)) * 0.25 - 0.375) * pixel_size, y + (@as(f64, @floatFromInt(sy)) * 0.25 - 0.375) * pixel_size) <= 0) count += 1;
    };
    return @intCast((count * 255 + 8) / 16);
}
fn blur(source: []const u8, destination: []u8, plan: Plan, weights: []const f64, vertical: bool, outside: f64, flag: ?*const std.atomic.Value(bool)) !void {
    for (0..plan.height) |y| {
        if (y % 8 == 0) try cancelled(flag);
        for (0..plan.width) |x| {
            if (x % 256 == 0) try cancelled(flag);
            var sum: f64 = 0;
            for (weights, 0..) |weight, index| {
                const delta = @as(i64, @intCast(index)) - plan.radius;
                const sx = @as(i64, @intCast(x)) + if (vertical) @as(i64, 0) else delta;
                const sy = @as(i64, @intCast(y)) + if (vertical) delta else @as(i64, 0);
                const alpha: f64 = if (sx < 0 or sy < 0 or sx >= plan.width or sy >= plan.height) outside else @floatFromInt(source[@as(usize, @intCast(sy)) * plan.stride + @as(usize, @intCast(sx))]);
                sum += alpha * weight;
            }
            destination[y * plan.stride + x] = @intFromFloat(std.math.clamp(@round(sum), 0, 255));
        }
    }
}

test "zero-blur outer and inset shadow masks retain original contour and ownership" {
    for ([_]Kind{ .outer, .inset }) |kind| {
        const value = try PreparedShadow.create(std.testing.allocator, .{ .width = 10, .height = 8, .radius = 0 }, .{ .kind = kind, .spread = 2 }, .{ .main_thread = std.Thread.getCurrentId() });
        defer value.close() catch unreachable;
        const view = try value.view();
        try view.validate();
        const c = view.coverage;
        const center = @as(usize, @intCast(4 - c.origin_y)) * c.stride + @as(usize, @intCast(5 - c.origin_x));
        try std.testing.expectEqual(0, c.pixels[center]);
        const edge_x: i32 = if (kind == .outer) -1 else 0;
        const edge = @as(usize, @intCast(4 - c.origin_y)) * c.stride + @as(usize, @intCast(edge_x - c.origin_x));
        try std.testing.expectEqual(255, c.pixels[edge]);
        try view.lease.acquire();
        try std.testing.expectError(error.ResourceInUse, value.close());
        view.lease.release();
    }
}
test "shadow budgets finite geometry cancellation and allocation rollback are explicit" {
    const main_thread = std.Thread.getCurrentId();
    try std.testing.expectError(error.InvalidShadow, PreparedShadow.create(std.testing.allocator, .{ .width = 10, .height = 8 }, .{ .sigma = std.math.nan(f32) }, .{ .main_thread = main_thread }));
    try std.testing.expectError(error.CapacityExceeded, PreparedShadow.create(std.testing.allocator, .{ .width = 10, .height = 8 }, .{ .sigma = 100 }, .{ .main_thread = main_thread }));
    try std.testing.expectError(error.CapacityExceeded, PreparedShadow.create(std.testing.allocator, .{ .width = 100, .height = 100 }, .{ .sigma = 8 }, .{ .main_thread = main_thread, .work_samples = 1 }));
    var flag = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, PreparedShadow.create(std.testing.allocator, .{ .width = 10, .height = 8 }, .{}, .{ .main_thread = main_thread, .cancellation = &flag }));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const value = try PreparedShadow.create(allocator, .{ .width = 10, .height = 8, .radius = 2 }, .{ .sigma = 1 }, .{ .main_thread = std.Thread.getCurrentId() });
            defer value.close() catch unreachable;
        }
    }.run, .{});
}

test "Gaussian shadow uses a normalized three-sigma kernel with rounded A8 passes" {
    const outer = try PreparedShadow.create(std.testing.allocator, .{ .width = 1, .height = 1 }, .{ .sigma = 1 }, .{ .main_thread = std.Thread.getCurrentId() });
    defer outer.close() catch unreachable;
    const view = try outer.view();
    const mask = view.coverage;
    try std.testing.expectEqual(@as(i32, -3), mask.origin_x);
    try std.testing.expectEqual(@as(u32, 3), (try outer.stats()).radius);
    try std.testing.expectEqual(@as(u8, 0), mask.pixels[3 * mask.stride + 3]);
    try std.testing.expectEqual(@as(u8, 25), mask.pixels[3 * mask.stride + 4]);
    try std.testing.expectEqual(@as(u8, 15), mask.pixels[4 * mask.stride + 4]);
    try std.testing.expectEqual(@as(u8, 6), mask.pixels[3 * mask.stride + 5]);
    const inset = try PreparedShadow.create(std.testing.allocator, .{ .width = 1, .height = 1 }, .{ .kind = .inset, .sigma = 1 }, .{ .main_thread = std.Thread.getCurrentId() });
    defer inset.close() catch unreachable;
    const inner = (try inset.view()).coverage;
    try std.testing.expectEqual(@as(u8, 214), inner.pixels[3 * inner.stride + 3]);
    try std.testing.expectEqual(@as(u8, 0), inner.pixels[3 * inner.stride + 4]);
}

test "worker shadow preparation requires exclusive main-thread adoption" {
    const Work = struct {
        main_thread: std.Thread.Id,
        value: ?*PreparedShadow = null,
        err: ?anyerror = null,
        fn run(self: *@This()) void {
            self.value = PreparedShadow.create(std.testing.allocator, .{ .width = 8, .height = 8, .radius = 2 }, .{ .sigma = 1 }, .{ .main_thread = self.main_thread }) catch |err| {
                self.err = err;
                return;
            };
        }
    };
    var work: Work = .{ .main_thread = std.Thread.getCurrentId() };
    const worker = try std.Thread.spawn(.{}, Work.run, .{&work});
    worker.join();
    if (work.err) |err| return err;
    const value = work.value.?;
    try std.testing.expectError(error.WrongThread, value.view());
    try value.adopt();
    defer value.close() catch unreachable;
    try (try value.view()).validate();
    try std.testing.expectError(error.AlreadyAdopted, value.adopt());
}

test "shadow cancellation after acquiring all planes rolls back every allocation" {
    const Cancelling = struct {
        child: std.mem.Allocator,
        flag: *std.atomic.Value(bool),
        allocations: usize = 0,
        live: usize = 0,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
        }
        fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const data = self.child.rawAlloc(len, alignment, address) orelse return null;
            self.live += len;
            self.allocations += 1;
            if (self.allocations == 3) self.flag.store(true, .release);
            return data;
        }
        fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.live -= bytes.len;
            self.child.rawFree(bytes, alignment, address);
        }
    };
    var flag = std.atomic.Value(bool).init(false);
    var cancelling: Cancelling = .{ .child = std.testing.allocator, .flag = &flag };
    try std.testing.expectError(error.Cancelled, PreparedShadow.create(cancelling.allocator(), .{ .width = 128, .height = 128, .radius = 12 }, .{ .sigma = 4 }, .{ .main_thread = std.Thread.getCurrentId(), .cancellation = &flag }));
    try std.testing.expectEqual(3, cancelling.allocations);
    try std.testing.expectEqual(0, cancelling.live);
}

test "inset storage ignores distant holes and matches full convolution at the original contour" {
    const options: PrepareOptions = .{ .main_thread = std.Thread.getCurrentId() };
    const shape: RoundedRect = .{ .width = 8, .height = 6, .radius = 2 };
    const near = try PreparedShadow.create(std.testing.allocator, shape, .{ .kind = .inset, .offset = .{ .x = 2, .y = -1 }, .spread = 0.5, .sigma = 1 }, options);
    defer near.close() catch unreachable;
    const distant = try PreparedShadow.create(std.testing.allocator, shape, .{ .kind = .inset, .offset = .{ .x = 1e6, .y = -1e6 }, .spread = 0.5, .sigma = 1 }, options);
    defer distant.close() catch unreachable;
    const a = try near.stats();
    const b = try distant.stats();
    try std.testing.expectEqual(a.width, b.width);
    try std.testing.expectEqual(a.height, b.height);
    try std.testing.expectEqual(a.peak_bytes, b.peak_bytes);
    try std.testing.expectEqual(a.filter_samples, b.filter_samples);
    const original: Box = .{ .width = 8, .height = 6, .radius = 2 };
    const hole: Box = .{ .x = 2.5, .y = -0.5, .width = 7, .height = 5, .radius = 1.5 };
    var weights: [7]f64 = undefined;
    var total: f64 = 0;
    for (&weights, 0..) |*weight, index| {
        const delta = @as(f64, @floatFromInt(index)) - 3;
        weight.* = @exp(-delta * delta * 0.5);
        total += weight.*;
    }
    for (&weights) |*weight| weight.* /= total;
    const actual = (try near.view()).coverage;
    const far = (try distant.view()).coverage;
    for (0..actual.height) |y| for (0..actual.width) |x| {
        const px = @as(f64, @floatFromInt(actual.origin_x)) + @as(f64, @floatFromInt(x)) + 0.5;
        const py = @as(f64, @floatFromInt(actual.origin_y)) + @as(f64, @floatFromInt(y)) + 0.5;
        const contour = coverage(original, px, py, 1);
        var vertical: f64 = 0;
        for (weights, 0..) |wy, iy| {
            var horizontal: f64 = 0;
            for (weights, 0..) |wx, ix| horizontal += wx * @as(f64, @floatFromInt(255 - @as(u32, coverage(hole, px + @as(f64, @floatFromInt(ix)) - 3, py + @as(f64, @floatFromInt(iy)) - 3, 1))));
            vertical += wy * @round(horizontal);
        }
        const filtered: u32 = @intFromFloat(@round(vertical));
        const expected: u8 = @intCast((filtered * contour + 127) / 255);
        try std.testing.expectEqual(expected, actual.pixels[y * actual.stride + x]);
        try std.testing.expectEqual(contour, far.pixels[y * far.stride + x]);
    };
}
