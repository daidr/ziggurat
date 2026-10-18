const std = @import("std");
pub const drawing = @import("ziggurat_drawing_resources");

pub const Limits = struct {
    bytes: usize = 64 * 1024 * 1024,
    filter_samples: u64 = 128 * 1024 * 1024,
};
pub const Options = struct {
    sigma: f32,
    scale: f32 = 1,
    /// Borrow until Work finishes/closes. This flag is cooperative; Work.cancel
    /// additionally serializes cancellation with the owner's final publication.
    cancellation: ?*const std.atomic.Value(bool) = null,
};
pub const Status = enum { captured, running, complete };
pub const Stats = struct {
    owned_current: usize,
    owned_peak: usize,
    requested_current: usize,
    borrowed_source_bytes: usize,
    reserved_current: usize,
    reserved_peak: usize,
    results: usize,
    work_active: bool,
};
pub const ResultStats = struct {
    width: u32,
    height: u32,
    scale: f32,
    radius: u32,
    placement: drawing.Point,
    pixel_bytes: usize,
    scratch_bytes: usize,
    filter_samples: u64,
    identity: bool,
};
const max_radius = 128;
const kernel_capacity = max_radius * 2 + 1;
const tag_bits = 4;
const serial_limit = std.math.maxInt(u64) >> tag_bits;
const cancel_bit: u64 = 8;
const Phase = enum(u3) { idle, captured, running, ready, failed, finishing };
fn word(serial: u64, phase: Phase) u64 {
    return (serial << tag_bits) | @intFromEnum(phase);
}
fn phaseOf(value: u64) Phase {
    return @enumFromInt(value & 7);
}

/// Explicit CPU filter preparation. The owner holds one physical Work and all
/// result metadata. No native calls, threads, posts or waits are created here.
/// Close rejects outstanding Work/results; the allocator covers their lifetime.
pub const Processor = opaque {
    pub fn create(allocator: std.mem.Allocator, owner: std.Thread.Id, limits: Limits) !*Processor {
        if (owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (limits.bytes < @sizeOf(State) or limits.bytes > 256 * 1024 * 1024 or limits.filter_samples == 0 or limits.filter_samples > 1024 * 1024 * 1024) return error.InvalidGaussianLimits;
        const state = try allocator.create(State);
        state.* = .{ .allocator = allocator, .owner = owner, .limits = limits };
        return @ptrCast(state);
    }
    /// Pins immutable source storage before caller allocation. The worker will
    /// read captured raw pixels, never the owner-thread Lease or allocator.
    pub fn capture(self: *Processor, source: drawing.ImageView, options: Options) !Work {
        const state = cast(self);
        try state.enter();
        defer state.busy = false;
        if (phaseOf(state.control.load(.acquire)) != .idle) return error.Full;
        if (state.serial == serial_limit) return error.IdExhausted;
        try checkFlag(options.cancellation);
        try source.validate();
        const base = source.levels[0];
        const plan = try Plan.init(base, options, state.limits);
        const retained = source.pixelBytes();
        const requested = try add(@sizeOf(ResultState), try add(plan.output_bytes, plan.scratch_bytes));
        const reservation = try add(requested, retained);
        if (reservation > state.limits.bytes -| try add(state.requested, state.borrowed)) return error.GaussianBudgetExceeded;
        try source.lease.acquire();
        state.requested += requested;
        state.borrowed += retained;
        state.reserved_peak = @max(state.reserved_peak, state.requested + state.borrowed);
        var result: ?*ResultState = null;
        var output: []u8 = &.{};
        var temporary: []u8 = &.{};
        errdefer {
            if (temporary.len != 0) state.free(temporary);
            if (output.len != 0) state.free(output);
            if (result) |value| {
                state.allocator.destroy(value);
                state.owned -= @sizeOf(ResultState);
            }
            source.lease.release();
            state.requested -= requested;
            state.borrowed -= retained;
        }
        result = try state.allocator.create(ResultState);
        state.allocated(@sizeOf(ResultState));
        try checkFlag(options.cancellation);
        if (plan.output_bytes != 0) {
            output = try state.allocator.alloc(u8, plan.output_bytes);
            state.allocated(output.len);
            try checkFlag(options.cancellation);
            temporary = try state.allocator.alloc(u8, plan.scratch_bytes);
            state.allocated(temporary.len);
            try checkFlag(options.cancellation);
        }
        const identity = if (plan.radius == 0) source.identity else try drawing.reserveRasterIdentity();
        result.?.* = .{ .processor = state, .lease = drawing.Lease.init(state.owner), .identity = identity, .pixels = output, .level = .{ .pixels = output.ptr, .byte_len = output.len, .width = plan.width, .height = plan.height, .stride = plan.width * 4 }, .original = if (plan.radius == 0) source else null, .retained = if (plan.radius == 0) retained else 0, .info = plan.info() };
        state.data = .{ .source = source, .base = base, .retained = retained, .temporary = temporary, .result = result.?, .plan = plan, .cancellation = options.cancellation };
        kernel(&state.weights, plan);
        try checkFlag(options.cancellation);
        state.serial += 1;
        state.failure = null;
        state.control.store(word(state.serial, .captured), .release);
        return .{ .processor = state, .serial = state.serial };
    }
    pub fn stats(self: *const Processor) !Stats {
        const state = cast(@constCast(self));
        try state.check();
        return .{ .owned_current = state.owned, .owned_peak = state.owned_peak, .requested_current = state.requested, .borrowed_source_bytes = state.borrowed, .reserved_current = state.requested + state.borrowed, .reserved_peak = state.reserved_peak, .results = state.results, .work_active = phaseOf(state.control.load(.acquire)) != .idle };
    }
    pub fn close(self: *Processor) !void {
        const state = cast(self);
        try state.enter();
        errdefer state.busy = false;
        if (phaseOf(state.control.load(.acquire)) != .idle or state.results != 0) return error.Busy;
        std.debug.assert(state.owned == @sizeOf(State) and state.requested == state.owned and state.borrowed == 0);
        state.closing = true;
        state.allocator.destroy(state);
    }
};

/// Linear capability; copies share one physical responsibility. Keep Processor
/// alive through every worker/cancellation call. Only run/cancel/status may be
/// called off owner. A successful run still requires owner finish or close.
pub const Work = struct {
    processor: *State,
    serial: u64,
    fn load(self: Work) !u64 {
        if (self.serial == 0 or self.serial > serial_limit) return error.WorkClosed;
        const value = self.processor.control.load(.acquire);
        if (value >> tag_bits != self.serial or phaseOf(value) == .idle) return error.WorkClosed;
        return value;
    }
    pub fn status(self: Work) !Status {
        const value = try self.load();
        return switch (phaseOf(value)) {
            .captured => .captured,
            .running => .running,
            .ready, .failed => .complete,
            else => error.Busy,
        };
    }
    /// Cancellation is encoded in the serial-tagged word, so stale Work copies
    /// cannot cancel a replacement job even when a slot is reused.
    pub fn cancel(self: Work) !void {
        var value = try self.load();
        while (true) {
            if (self.processor.control.cmpxchgWeak(value, value | cancel_bit, .acq_rel, .acquire)) |changed| {
                if (changed >> tag_bits != self.serial or phaseOf(changed) == .idle) return error.WorkClosed;
                value = changed;
            } else return;
        }
    }
    pub fn run(self: Work) !void {
        var value = try self.load();
        while (true) {
            if (phaseOf(value) != .captured) return if (phaseOf(value) == .running or phaseOf(value) == .finishing) error.Busy else error.AlreadyComplete;
            const next = word(self.serial, .running) | (value & cancel_bit);
            if (self.processor.control.cmpxchgWeak(value, next, .acq_rel, .acquire)) |changed| {
                if (changed >> tag_bits != self.serial or phaseOf(changed) == .idle) return error.WorkClosed;
                value = changed;
            } else break;
        }
        const failure: ?anyerror = if (filter(self)) |_| null else |err| err;
        self.processor.failure = failure;
        value = self.processor.control.load(.acquire);
        while (self.processor.control.cmpxchgWeak(value, word(self.serial, if (failure == null) .ready else .failed) | (value & cancel_bit), .acq_rel, .acquire)) |changed| {
            value = changed;
        }
        if (failure) |err| return err;
    }
    fn acquireOwner(self: Work, abandon: bool) !void {
        var value = try self.load();
        while (true) {
            switch (phaseOf(value)) {
                .running, .finishing => return error.Busy,
                .captured => if (!abandon) return error.NotReady,
                .ready, .failed => {},
                else => return error.WorkClosed,
            }
            if (self.processor.control.cmpxchgWeak(value, word(self.serial, .finishing) | (value & cancel_bit), .acq_rel, .acquire)) |changed| {
                if (changed >> tag_bits != self.serial or phaseOf(changed) == .idle) return error.WorkClosed;
                value = changed;
            } else return;
        }
    }
    /// Terminal success/error consumes this Work. NotReady/Busy retain it.
    /// Temporary foreign cleanup completes before the final cancellation CAS.
    pub fn finish(self: Work) !*Prepared {
        const state = self.processor;
        try state.enter();
        defer state.busy = false;
        try self.acquireOwner(false);
        const data = &state.data;
        if (data.temporary.len != 0) {
            const temporary = data.temporary;
            data.temporary = &.{};
            state.free(temporary);
            state.requested -= temporary.len;
        }
        var value = state.control.load(.acquire);
        while (true) {
            std.debug.assert(value >> tag_bits == self.serial and phaseOf(value) == .finishing);
            const external_cancel = if (data.cancellation) |flag| flag.load(.acquire) else false;
            if (state.failure != null or value & cancel_bit != 0 or external_cancel) {
                const failure = state.failure orelse error.Cancelled;
                discard(state);
                state.control.store(word(self.serial, .idle), .release);
                return failure;
            }
            if (state.control.cmpxchgWeak(value, word(self.serial, .idle), .acq_rel, .acquire)) |changed| {
                value = changed;
            } else break;
        }
        const result = data.result;
        if (data.plan.radius != 0) {
            data.source.lease.release();
            state.borrowed -= data.retained;
        }
        state.results += 1;
        state.data = undefined;
        return @ptrCast(result);
    }
    /// Owner-only abandonment. Running work must first return cooperatively.
    pub fn close(self: Work) !void {
        const state = self.processor;
        try state.enter();
        defer state.busy = false;
        try self.acquireOwner(true);
        discard(state);
        state.control.store(word(self.serial, .idle), .release);
    }
};

/// Independent filtered pixels, or a sigma-zero pin of the exact input view.
/// Close all results before Processor.close. No App/native lifetime is borrowed.
pub const Prepared = opaque {
    pub fn view(self: *const Prepared) !drawing.ImageView {
        const state = resultCast(@constCast(self));
        try state.check();
        if (state.original) |original| return original;
        return .{ .lease = &state.lease, .identity = state.identity, .levels = @as([*]const drawing.ImageLevel, @ptrCast(&state.level))[0..1] };
    }
    pub fn stats(self: *const Prepared) !ResultStats {
        const state = resultCast(@constCast(self));
        try state.check();
        return state.info;
    }
    pub fn close(self: *Prepared) !void {
        const result = resultCast(self);
        try result.check();
        try result.lease.ensureUnused();
        const state = result.processor;
        try state.enter();
        defer state.busy = false;
        result.closing = true;
        const pixels = result.pixels;
        const original = result.original;
        const retained = result.retained;
        result.pixels = &.{};
        if (pixels.len != 0) state.free(pixels);
        state.allocator.destroy(result);
        state.owned -= @sizeOf(ResultState);
        state.requested -= pixels.len + @sizeOf(ResultState);
        if (original) |source| {
            source.lease.release();
            state.borrowed -= retained;
        }
        state.results -= 1;
    }
};

const ResultState = struct {
    processor: *State,
    lease: drawing.Lease,
    identity: u64,
    pixels: []u8,
    level: drawing.ImageLevel,
    original: ?drawing.ImageView,
    retained: usize,
    info: ResultStats,
    closing: bool = false,
    fn check(self: *const ResultState) !void {
        try self.lease.checkOwner();
        if (self.closing) return error.Closed;
        try self.processor.check();
    }
};
const Data = struct { source: drawing.ImageView, base: drawing.ImageLevel, retained: usize, temporary: []u8, result: *ResultState, plan: Plan, cancellation: ?*const std.atomic.Value(bool) };
const State = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    limits: Limits,
    control: std.atomic.Value(u64) = .init(word(0, .idle)),
    serial: u64 = 0,
    busy: bool = false,
    closing: bool = false,
    owned: usize = @sizeOf(State),
    owned_peak: usize = @sizeOf(State),
    requested: usize = @sizeOf(State),
    borrowed: usize = 0,
    reserved_peak: usize = @sizeOf(State),
    results: usize = 0,
    weights: [kernel_capacity]f64 = undefined,
    data: Data = undefined,
    failure: ?anyerror = null,
    fn check(self: *const State) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.closing) return error.Closed;
        if (self.busy) return error.Busy;
    }
    fn enter(self: *State) !void {
        try self.check();
        self.busy = true;
    }
    fn allocated(self: *State, bytes: usize) void {
        self.owned += bytes;
        self.owned_peak = @max(self.owned_peak, self.owned);
    }
    fn free(self: *State, bytes: []u8) void {
        self.allocator.free(bytes);
        self.owned -= bytes.len;
    }
};
fn cast(self: *Processor) *State {
    return @ptrCast(@alignCast(self));
}
fn resultCast(self: *Prepared) *ResultState {
    return @ptrCast(@alignCast(self));
}
fn add(a: usize, b: usize) !usize {
    return std.math.add(usize, a, b) catch error.GaussianBudgetExceeded;
}
fn mul(a: usize, b: usize) !usize {
    return std.math.mul(usize, a, b) catch error.GaussianBudgetExceeded;
}
const Plan = struct {
    width: u32,
    height: u32,
    radius: u32,
    sigma: f64,
    scale: f32,
    output_bytes: usize,
    scratch_bytes: usize,
    samples: u64,
    fn init(source: drawing.ImageLevel, options: Options, limits: Limits) !Plan {
        if (!std.math.isFinite(options.sigma) or options.sigma < 0 or !std.math.isFinite(options.scale) or options.scale < 0.0625 or options.scale > 16) return error.InvalidGaussian;
        const sigma = @as(f64, options.sigma) * options.scale;
        const radius_float = @ceil(3 * sigma);
        if (radius_float > max_radius) return error.GaussianRadiusExceeded;
        const radius: u32 = @intFromFloat(radius_float);
        if (radius == 0) return .{ .width = source.width, .height = source.height, .radius = 0, .sigma = 0, .scale = options.scale, .output_bytes = 0, .scratch_bytes = 0, .samples = 0 };
        const width = source.width + radius * 2;
        const height = source.height + radius * 2;
        if (width > 16384 or height > 16384 or @as(u64, width) * height > 16 * 1024 * 1024) return error.GaussianBudgetExceeded;
        const output = try mul(try mul(width, height), 4);
        const scratch = try mul(try mul(width, source.height), 4);
        const samples = (@as(u64, width) * source.height + @as(u64, width) * height) * (radius * 2 + 1);
        if (output > drawing.max_image_bytes) return error.GaussianBudgetExceeded;
        if (samples > limits.filter_samples) return error.GaussianWorkExceeded;
        return .{ .width = width, .height = height, .radius = radius, .sigma = sigma, .scale = options.scale, .output_bytes = output, .scratch_bytes = scratch, .samples = samples };
    }
    fn info(self: Plan) ResultStats {
        const delta = -@as(f64, @floatFromInt(self.radius)) / self.scale;
        return .{ .width = self.width, .height = self.height, .scale = self.scale, .radius = self.radius, .placement = .{ .x = @floatCast(delta), .y = @floatCast(delta) }, .pixel_bytes = self.output_bytes, .scratch_bytes = self.scratch_bytes, .filter_samples = self.samples, .identity = self.radius == 0 };
    }
};
fn kernel(weights: *[kernel_capacity]f64, plan: Plan) void {
    if (plan.radius == 0) return;
    var sum: f64 = 0;
    for (weights[0 .. plan.radius * 2 + 1], 0..) |*weight, index| {
        const delta = @as(f64, @floatFromInt(index)) - @as(f64, @floatFromInt(plan.radius));
        weight.* = @exp(-(delta * delta) / (2 * plan.sigma * plan.sigma));
        sum += weight.*;
    }
    for (weights[0 .. plan.radius * 2 + 1]) |*weight| weight.* /= sum;
}
fn cancelled(work: Work) !void {
    if (work.processor.control.load(.acquire) & cancel_bit != 0) return error.Cancelled;
    try checkFlag(work.processor.data.cancellation);
}
fn checkFlag(flag: ?*const std.atomic.Value(bool)) !void {
    if (flag) |value| if (value.load(.acquire)) return error.Cancelled;
}
fn quantize(value: f64) u8 {
    return @intFromFloat(std.math.clamp(@round(value), 0, 255));
}
fn filter(work: Work) !void {
    try cancelled(work);
    const state = work.processor;
    const data = &state.data;
    const plan = data.plan;
    if (plan.radius == 0) return;
    const weights = state.weights[0 .. plan.radius * 2 + 1];
    const radius: i64 = plan.radius;
    // The horizontal intermediate has the expanded width but only input rows.
    // Vertical reads outside those rows see transparent black, not edge clamp.
    for (0..data.base.height) |y| {
        for (0..plan.width) |x| {
            if (x % 64 == 0) try cancelled(work);
            var color = [_]f64{ 0, 0, 0, 0 };
            for (weights, 0..) |weight, index| {
                const sx = @as(i64, @intCast(x)) - radius + @as(i64, @intCast(index)) - radius;
                if (sx < 0 or sx >= data.base.width) continue;
                const at = y * data.base.stride + @as(usize, @intCast(sx)) * 4;
                inline for (0..4) |channel| color[channel] += @as(f64, @floatFromInt(data.base.pixels[at + channel])) * weight;
            }
            inline for (0..4) |channel| data.temporary[(y * plan.width + x) * 4 + channel] = quantize(color[channel]);
        }
    }
    for (0..plan.height) |y| {
        for (0..plan.width) |x| {
            if (x % 64 == 0) try cancelled(work);
            var color = [_]f64{ 0, 0, 0, 0 };
            for (weights, 0..) |weight, index| {
                const sy = @as(i64, @intCast(y)) - radius + @as(i64, @intCast(index)) - radius;
                if (sy < 0 or sy >= data.base.height) continue;
                const at = (@as(usize, @intCast(sy)) * plan.width + x) * 4;
                inline for (0..4) |channel| color[channel] += @as(f64, @floatFromInt(data.temporary[at + channel])) * weight;
            }
            inline for (0..4) |channel| data.result.pixels[(y * plan.width + x) * 4 + channel] = quantize(color[channel]);
        }
    }
    try cancelled(work);
}
fn discard(state: *State) void {
    const data = state.data;
    if (data.temporary.len != 0) state.free(data.temporary);
    const pixels = data.result.pixels;
    if (pixels.len != 0) state.free(pixels);
    state.allocator.destroy(data.result);
    state.owned -= @sizeOf(ResultState);
    state.requested -= data.temporary.len + pixels.len + @sizeOf(ResultState);
    if (data.retained != 0) {
        data.source.lease.release();
        state.borrowed -= data.retained;
    }
    state.data = undefined;
}

test "zero sigma keeps the exact original resource and performs no pixel work" {
    var lease = drawing.Lease.init(std.Thread.getCurrentId());
    const bytes = [_]u8{ 0, 64, 128, 128 };
    const levels = [_]drawing.ImageLevel{.{ .pixels = &bytes, .byte_len = bytes.len, .width = 1, .height = 1, .stride = 4 }};
    const source: drawing.ImageView = .{ .lease = &lease, .identity = 10, .levels = &levels };
    const processor = try Processor.create(std.testing.allocator, lease.owner, .{});
    defer processor.close() catch unreachable;
    const before = try processor.stats();
    const work = try processor.capture(source, .{ .sigma = 0 });
    try std.testing.expectError(error.Busy, processor.close());
    try std.testing.expectError(error.NotReady, work.finish());
    try work.run();
    const prepared = try work.finish();
    try std.testing.expectEqual(@as(usize, 1), lease.pins);
    const view = try prepared.view();
    try std.testing.expectEqual(source.identity, view.identity);
    try std.testing.expect(source.lease == view.lease and source.levels.ptr == view.levels.ptr);
    const info = try prepared.stats();
    try std.testing.expect(info.identity and info.pixel_bytes == 0 and info.scratch_bytes == 0 and info.filter_samples == 0);
    try std.testing.expectEqual(before.owned_current + @sizeOf(ResultState), (try processor.stats()).owned_current);
    // A frame retains the original source, not this passthrough wrapper.
    try view.lease.acquire();
    try prepared.close();
    try std.testing.expectEqual(@as(usize, 1), lease.pins);
    view.lease.release();
    try std.testing.expectEqual(before.owned_current, (try processor.stats()).owned_current);
}

test "filtered output is independently leased and stale Work cannot mutate a reused slot" {
    var lease = drawing.Lease.init(std.Thread.getCurrentId());
    const bytes = [_]u8{ 0, 0, 255, 255 };
    const levels = [_]drawing.ImageLevel{.{ .pixels = &bytes, .byte_len = bytes.len, .width = 1, .height = 1, .stride = 4 }};
    const source: drawing.ImageView = .{ .lease = &lease, .identity = 11, .levels = &levels };
    const processor = try Processor.create(std.testing.allocator, lease.owner, .{});
    defer processor.close() catch unreachable;
    const work = try processor.capture(source, .{ .sigma = 1, .scale = 1.5 });
    try std.testing.expectError(error.Full, processor.capture(source, .{ .sigma = 1 }));
    try std.testing.expectError(error.ResourceInUse, lease.ensureUnused());
    try work.run();
    const prepared = try work.finish();
    try std.testing.expectEqual(@as(usize, 0), lease.pins);
    try std.testing.expectError(error.Busy, processor.close());
    const view = try prepared.view();
    try view.validate();
    const info = try prepared.stats();
    try std.testing.expectEqual(@as(u32, 5), info.radius);
    try std.testing.expectEqual(@as(u32, 11), info.width);
    try std.testing.expectEqual(@as(f32, -5.0 / 1.5), info.placement.x);
    try view.lease.acquireResidency();
    try std.testing.expectError(error.ResourceInUse, prepared.close());
    view.lease.releaseResidency();
    const replacement = try processor.capture(source, .{ .sigma = 0 });
    try std.testing.expectError(error.WorkClosed, work.cancel());
    try std.testing.expectError(error.WorkClosed, work.run());
    try std.testing.expectError(error.WorkClosed, work.close());
    try replacement.close();
    try prepared.close();
    try std.testing.expectEqual(@as(usize, 0), lease.pins);
}

test "two-pass BGRA matches an independent direct two-dimensional Gaussian within one byte" {
    var lease = drawing.Lease.init(std.Thread.getCurrentId());
    // Already-composited opaque, translucent and transparent pixels. RGB is
    // premultiplied: an invisible colored input contributes no hidden RGB.
    const bytes = [_]u8{ 0, 0, 255, 255, 128, 0, 64, 192, 0, 0, 0, 0, 32, 96, 16, 128, 64, 16, 0, 64, 40, 40, 40, 80 };
    const levels = [_]drawing.ImageLevel{.{ .pixels = &bytes, .byte_len = bytes.len, .width = 3, .height = 2, .stride = 12 }};
    const processor = try Processor.create(std.testing.allocator, lease.owner, .{});
    defer processor.close() catch unreachable;
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        for ([_]f32{ 0.125, 0.75, 1.25 }) |sigma_dip| {
            const sigma = @as(f64, sigma_dip) * scale;
            const work = try processor.capture(.{ .lease = &lease, .identity = 12, .levels = &levels }, .{ .sigma = sigma_dip, .scale = scale });
            try work.run();
            const prepared = try work.finish();
            defer prepared.close() catch unreachable;
            const view = try prepared.view();
            const level = view.levels[0];
            const radius: i64 = @intFromFloat(@ceil(3 * @as(f64, sigma)));
            var normalization: f64 = 0;
            var dy: i64 = -radius;
            while (dy <= radius) : (dy += 1) {
                var dx: i64 = -radius;
                while (dx <= radius) : (dx += 1) normalization += @exp(-@as(f64, @floatFromInt(dx * dx + dy * dy)) / (2 * @as(f64, sigma) * sigma));
            }
            for (0..level.height) |y| for (0..level.width) |x| {
                var sum = [_]f64{ 0, 0, 0, 0 };
                for (0..2) |sy| for (0..3) |sx| {
                    const dx = @as(i64, @intCast(sx)) - (@as(i64, @intCast(x)) - radius);
                    const ddy = @as(i64, @intCast(sy)) - (@as(i64, @intCast(y)) - radius);
                    if (@abs(dx) > radius or @abs(ddy) > radius) continue;
                    const weight = @exp(-@as(f64, @floatFromInt(dx * dx + ddy * ddy)) / (2 * @as(f64, sigma) * sigma)) / normalization;
                    for (0..4) |channel| sum[channel] += @as(f64, @floatFromInt(bytes[(sy * 3 + sx) * 4 + channel])) * weight;
                };
                for (0..4) |channel| {
                    const expected: i32 = @intFromFloat(@round(sum[channel]));
                    const actual: i32 = level.pixels[(y * level.width + x) * 4 + channel];
                    try std.testing.expect(@abs(expected - actual) <= 1);
                }
                for (0..3) |channel| try std.testing.expect(level.pixels[(y * level.width + x) * 4 + channel] <= level.pixels[(y * level.width + x) * 4 + 3]);
            };
        }
    }
}

test "capture allocation failures and canceled work restore all budget and source pins" {
    const Case = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var lease = drawing.Lease.init(std.Thread.getCurrentId());
            defer std.debug.assert(lease.pins == 0);
            const pixels = [_]u8{ 0, 0, 255, 255 };
            const levels = [_]drawing.ImageLevel{.{ .pixels = &pixels, .byte_len = pixels.len, .width = 1, .height = 1, .stride = 4 }};
            const processor = try Processor.create(allocator, lease.owner, .{});
            defer processor.close() catch unreachable;
            const work = try processor.capture(.{ .lease = &lease, .identity = 13, .levels = &levels }, .{ .sigma = 1 });
            try work.run();
            const result = try work.finish();
            defer result.close() catch unreachable;
            const old_view = try result.view();
            const old_pixel = old_view.levels[0].pixels[0];
            const baseline = try processor.stats();
            const next = processor.capture(.{ .lease = &lease, .identity = 13, .levels = &levels }, .{ .sigma = 1 }) catch |err| {
                try std.testing.expectEqual(old_view.identity, (try result.view()).identity);
                try std.testing.expectEqual(old_pixel, (try result.view()).levels[0].pixels[0]);
                try std.testing.expectEqual(baseline.owned_current, (try processor.stats()).owned_current);
                try std.testing.expectEqual(@as(usize, 0), lease.pins);
                return err;
            };
            try next.cancel();
            try std.testing.expectError(error.Cancelled, next.run());
            try std.testing.expectError(error.Cancelled, next.finish());
            const stats = try processor.stats();
            try std.testing.expectEqual(baseline.owned_current, stats.owned_current);
            try std.testing.expectEqual(stats.owned_current, stats.requested_current);
            try std.testing.expectEqual(@as(usize, 0), stats.borrowed_source_bytes);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "an actual worker reads only pinned immutable pixels and publishes through owner finish" {
    const Thread = struct {
        work: Work,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            if (self.work.finish()) |_| {
                self.failure = error.UnexpectedSuccess;
                return;
            } else |err| {
                if (err != error.WrongThread) {
                    self.failure = err;
                    return;
                }
            }
            self.work.run() catch |err| {
                self.failure = err;
            };
        }
    };
    var lease = drawing.Lease.init(std.Thread.getCurrentId());
    const bytes = [_]u8{ 0, 0, 255, 255 };
    const levels = [_]drawing.ImageLevel{.{ .pixels = &bytes, .byte_len = bytes.len, .width = 1, .height = 1, .stride = 4 }};
    const processor = try Processor.create(std.testing.allocator, lease.owner, .{});
    defer processor.close() catch unreachable;
    const work = try processor.capture(.{ .lease = &lease, .identity = 14, .levels = &levels }, .{ .sigma = 1 });
    const before = try processor.stats();
    var context: Thread = .{ .work = work };
    const thread = try std.Thread.spawn(.{}, Thread.run, .{&context});
    thread.join();
    if (context.failure) |err| return err;
    const after = try processor.stats();
    try std.testing.expectEqual(before.owned_current, after.owned_current);
    try std.testing.expectEqual(@as(usize, 1), lease.pins);
    const result = try work.finish();
    try std.testing.expectEqual(@as(usize, 0), lease.pins);
    try result.close();
}

test "the Gaussian filters composited overlap instead of applying a filter to each child" {
    var lease = drawing.Lease.init(std.Thread.getCurrentId());
    // Red alpha128, then blue alpha128, produces BGRA(128,0,64,192).
    // Blurring those children separately and then compositing instead would
    // yield alpha about38 at the center; filtering their composition yields31.
    const pixels = [_]u8{ 128, 0, 64, 192 };
    const levels = [_]drawing.ImageLevel{.{ .pixels = &pixels, .byte_len = 4, .width = 1, .height = 1, .stride = 4 }};
    const processor = try Processor.create(std.testing.allocator, lease.owner, .{});
    defer processor.close() catch unreachable;
    const work = try processor.capture(.{ .lease = &lease, .identity = 15, .levels = &levels }, .{ .sigma = 1 });
    try work.run();
    const result = try work.finish();
    defer result.close() catch unreachable;
    const level = (try result.view()).levels[0];
    const center = (3 * level.width + 3) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 20, 0, 10, 31 }, level.pixels[center..][0..4]);
    try std.testing.expect(level.pixels[center + 3] < 36);
}

test "limits charge old outputs and complete borrowed mip storage before any candidate allocation" {
    var lease = drawing.Lease.init(std.Thread.getCurrentId());
    const pixels = [_]u8{0} ** 20;
    const levels = [_]drawing.ImageLevel{
        .{ .pixels = &pixels, .byte_len = 16, .width = 2, .height = 2, .stride = 8 },
        .{ .pixels = pixels[16..].ptr, .byte_len = 4, .width = 1, .height = 1, .stride = 4 },
    };
    const source: drawing.ImageView = .{ .lease = &lease, .identity = 16, .levels = &levels };
    const exact = @sizeOf(State) + @sizeOf(ResultState) + pixels.len;
    const processor = try Processor.create(std.testing.allocator, lease.owner, .{ .bytes = exact });
    defer processor.close() catch unreachable;
    const work = try processor.capture(source, .{ .sigma = 0 });
    try work.run();
    const result = try work.finish();
    try std.testing.expectEqual(@as(usize, pixels.len), (try processor.stats()).borrowed_source_bytes);
    try std.testing.expectEqual(@as(usize, exact), (try processor.stats()).reserved_current);
    const before = try processor.stats();
    try std.testing.expectError(error.GaussianBudgetExceeded, processor.capture(source, .{ .sigma = 0 }));
    try std.testing.expectEqualDeep(before, try processor.stats());
    try std.testing.expectEqual(@as(usize, 1), lease.pins);
    try result.close();
    try std.testing.expectEqual(@as(usize, 0), lease.pins);
    try std.testing.expectError(error.GaussianBudgetExceeded, processor.capture(source, .{ .sigma = 1 }));
    inline for (.{ std.math.nan(f32), std.math.inf(f32), -1.0 }) |sigma| try std.testing.expectError(error.InvalidGaussian, processor.capture(source, .{ .sigma = sigma }));
    try std.testing.expectError(error.InvalidGaussian, processor.capture(source, .{ .sigma = 0, .scale = 0 }));
    try std.testing.expectError(error.GaussianRadiusExceeded, processor.capture(source, .{ .sigma = 1000 }));
    const limited = try Processor.create(std.testing.allocator, lease.owner, .{ .filter_samples = 1 });
    defer limited.close() catch unreachable;
    try std.testing.expectError(error.GaussianWorkExceeded, limited.capture(source, .{ .sigma = 1 }));
    try std.testing.expectEqual(@as(usize, 0), lease.pins);
}

test "capture cancellation and final foreign frees preserve owner gates and exact responsibility" {
    const Harness = struct {
        processor: ?*Processor = null,
        result: ?*Prepared = null,
        source: *drawing.Lease,
        work: ?Work = null,
        flag: std.atomic.Value(bool) = .init(false),
        cancel_allocation: bool = false,
        expect_source_pin: bool = false,
        finish_frees: usize = 0,
        mode: enum { none, finish, result, processor } = .none,
        failure: ?anyerror = null,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
        }
        fn checkError(self: *@This(), expected: anyerror, actual: anytype) void {
            std.testing.expectError(expected, actual) catch |err| {
                self.failure = err;
            };
        }
        fn alloc(ptr: *anyopaque, size: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const memory = std.testing.allocator.rawAlloc(size, alignment, ra);
            if (self.cancel_allocation) {
                self.cancel_allocation = false;
                self.checkError(error.ResourceInUse, self.source.ensureUnused());
                self.checkError(error.Busy, self.processor.?.close());
                self.flag.store(true, .release);
            }
            return memory;
        }
        fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            switch (self.mode) {
                .none => {},
                .finish => {
                    self.finish_frees += 1;
                    self.checkError(error.Busy, self.processor.?.stats());
                    self.checkError(error.Busy, self.processor.?.close());
                    self.checkError(error.ResourceInUse, self.source.ensureUnused());
                    self.checkError(error.Busy, self.work.?.finish());
                    self.work.?.cancel() catch |err| {
                        self.failure = err;
                    };
                    if (bytes.ptr == @as([*]u8, @ptrCast(self.work.?.processor.data.result))) self.mode = .none;
                },
                .result => {
                    self.checkError(error.Closed, self.result.?.view());
                    self.checkError(error.Closed, self.result.?.close());
                    self.checkError(error.Busy, self.processor.?.close());
                    if (self.expect_source_pin) self.checkError(error.ResourceInUse, self.source.ensureUnused());
                    if (bytes.ptr == @as([*]u8, @ptrCast(self.result.?))) {
                        self.mode = .none;
                        self.result = null;
                    }
                },
                .processor => {
                    self.mode = .none;
                    self.checkError(error.Closed, self.processor.?.stats());
                    self.checkError(error.Closed, self.processor.?.close());
                },
            }
            std.testing.allocator.rawFree(bytes, alignment, ra);
        }
    };
    var lease = drawing.Lease.init(std.Thread.getCurrentId());
    const pixels = [_]u8{ 64, 0, 0, 128 };
    const levels = [_]drawing.ImageLevel{.{ .pixels = &pixels, .byte_len = 4, .width = 1, .height = 1, .stride = 4 }};
    const source: drawing.ImageView = .{ .lease = &lease, .identity = 17, .levels = &levels };
    var harness: Harness = .{ .source = &lease };
    const processor = try Processor.create(harness.allocator(), lease.owner, .{});
    harness.processor = processor;
    harness.cancel_allocation = true;
    try std.testing.expectError(error.Cancelled, processor.capture(source, .{ .sigma = 1, .cancellation = &harness.flag }));
    try std.testing.expectEqual(@as(usize, 0), lease.pins);
    harness.flag.store(false, .release);
    const work = try processor.capture(source, .{ .sigma = 1 });
    harness.work = work;
    try work.run();
    harness.mode = .finish;
    try std.testing.expectError(error.Cancelled, work.finish());
    try std.testing.expectEqual(@as(usize, 3), harness.finish_frees);
    try std.testing.expectEqual(@as(usize, 0), lease.pins);
    try std.testing.expectEqual(@as(usize, @sizeOf(State)), (try processor.stats()).owned_current);
    // Exercise both owned pixels and sigma-zero final shell/source-pin release.
    for ([_]f32{ 1, 0 }) |sigma| {
        const next = try processor.capture(source, .{ .sigma = sigma });
        try next.run();
        const result = try next.finish();
        harness.result = result;
        harness.expect_source_pin = sigma == 0;
        harness.mode = .result;
        try result.close();
        try std.testing.expectEqual(@as(usize, 0), lease.pins);
    }
    harness.mode = .processor;
    try processor.close();
    if (harness.failure) |err| return err;
}

test "source stride padding is ignored and filtered pixels no longer borrow source storage" {
    var lease = drawing.Lease.init(std.Thread.getCurrentId());
    const padded = [_]u8{ 0, 0, 128, 128, 255, 255, 255, 255, 64, 0, 0, 64 };
    const tight = [_]u8{ 0, 0, 128, 128, 64, 0, 0, 64 };
    const sources = [_]drawing.ImageLevel{
        .{ .pixels = &padded, .byte_len = padded.len, .width = 1, .height = 2, .stride = 8 },
        .{ .pixels = &tight, .byte_len = tight.len, .width = 1, .height = 2, .stride = 4 },
    };
    // Both descriptors need a full final stride, even though padding is never
    // sampled; the first source therefore supplies16 initialized bytes below.
    var full_padded = [_]u8{0} ** 16;
    @memcpy(full_padded[0..padded.len], &padded);
    var padded_level = sources[0];
    padded_level.pixels = &full_padded;
    padded_level.byte_len = full_padded.len;
    const processor = try Processor.create(std.testing.allocator, lease.owner, .{});
    defer processor.close() catch unreachable;
    const first = try processor.capture(.{ .lease = &lease, .identity = 18, .levels = @as([*]const drawing.ImageLevel, @ptrCast(&padded_level))[0..1] }, .{ .sigma = 0.75 });
    try first.run();
    const padded_result = try first.finish();
    defer padded_result.close() catch unreachable;
    const second = try processor.capture(.{ .lease = &lease, .identity = 19, .levels = sources[1..2] }, .{ .sigma = 0.75 });
    try second.run();
    const packed_result = try second.finish();
    defer packed_result.close() catch unreachable;
    try lease.ensureUnused();
    @memset(&full_padded, 0x55);
    const actual = (try padded_result.view()).levels[0];
    const expected = (try packed_result.view()).levels[0];
    try std.testing.expectEqualSlices(u8, expected.pixels[0..expected.byte_len], actual.pixels[0..actual.byte_len]);
}

test "running owner operations do not inspect a candidate and serial exhaustion precedes source acquisition" {
    var lease = drawing.Lease.init(std.Thread.getCurrentId());
    const pixels = [_]u8{ 0, 0, 0, 0 };
    const levels = [_]drawing.ImageLevel{.{ .pixels = &pixels, .byte_len = 4, .width = 1, .height = 1, .stride = 4 }};
    const source: drawing.ImageView = .{ .lease = &lease, .identity = 20, .levels = &levels };
    const processor = try Processor.create(std.testing.allocator, lease.owner, .{});
    defer processor.close() catch unreachable;
    const work = try processor.capture(source, .{ .sigma = 1 });
    // Model a worker paused immediately after taking its atomic capability.
    // No candidate reads/clears are permitted at this protocol boundary.
    cast(processor).control.store(word(work.serial, .running), .release);
    try std.testing.expectEqual(Status.running, try work.status());
    try std.testing.expectError(error.Busy, work.finish());
    try std.testing.expectError(error.Busy, work.close());
    try std.testing.expectError(error.Busy, work.run());
    try std.testing.expectError(error.Busy, processor.close());
    cast(processor).control.store(word(work.serial, .captured), .release);
    try work.close();
    cast(processor).serial = serial_limit;
    try std.testing.expectError(error.IdExhausted, processor.capture(source, .{ .sigma = 0 }));
    try std.testing.expectEqual(@as(usize, 0), lease.pins);
}
