const std = @import("std");
const builtin = @import("builtin");
const images = @import("ziggurat_images");
pub const drawing = @import("ziggurat_drawing_resources");
pub const PixelRect = struct { x: u32 = 0, y: u32 = 0, width: u32, height: u32 };
pub const PrepareOptions = struct { source: ?PixelRect = null, mipmaps: bool = true, bytes: usize = drawing.max_image_bytes, cancellation: ?*const images.Cancellation = null };
pub const Stats = struct { bytes: usize, pixel_bytes: usize, levels: usize, source: PixelRect, elapsed_ns: ?u64 };

/// Independent immutable pixel snapshot. Preparation may run on the decoded
/// image's worker owner. Adopt transfers exclusive access to the main thread.
pub const PreparedImage = opaque {
    pub fn create(allocator: std.mem.Allocator, image: *const images.Image, options: PrepareOptions) !*PreparedImage {
        const source = try image.pixels();
        // Keep source descriptors and pixels stable across caller allocator
        // callbacks, including every failure destructor and the final read.
        try @constCast(image).lease.acquire();
        defer @constCast(image).lease.release();
        try checkCancellation(options.cancellation);
        if (builtin.cpu.arch.endian() != .little) return error.UnsupportedPixelEndian;
        if (options.bytes == 0 or options.bytes > drawing.max_image_bytes) return error.InvalidPrepareLimits;
        const crop = options.source orelse PixelRect{ .width = image.width, .height = image.height };
        if (crop.width == 0 or crop.height == 0 or crop.x > image.width or crop.y > image.height or crop.width > image.width - crop.x or crop.height > image.height - crop.y) return error.InvalidSourceRectangle;
        var timer = std.time.Timer.start() catch null;
        var total: usize = 0;
        var count: usize = 0;
        var width = crop.width;
        var height = crop.height;
        while (true) {
            const bytes = @as(usize, width) * height * 4;
            if (bytes > options.bytes -| total or count == drawing.max_image_levels) return error.CapacityExceeded;
            total += bytes;
            count += 1;
            if (!options.mipmaps or (width == 1 and height == 1)) break;
            width = @max(1, width / 2);
            height = @max(1, height / 2);
        }
        if (total + @sizeOf(State) > options.bytes) return error.CapacityExceeded;
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        const data = try allocator.alloc(u8, total);
        errdefer allocator.free(data);
        state.* = .{ .allocator = allocator, .lease = drawing.Lease.init(std.Thread.getCurrentId()), .main_thread = image.main_thread, .adopted = image.adopted, .identity = try identity(), .data = data, .count = count, .stats = undefined };
        width = crop.width;
        height = crop.height;
        var offset: usize = 0;
        for (state.levels[0..count]) |*level| {
            const len = @as(usize, width) * height * 4;
            level.* = .{ .pixels = data[offset..].ptr, .byte_len = len, .width = width, .height = height, .stride = width * 4 };
            offset += len;
            width = @max(1, width / 2);
            height = @max(1, height / 2);
        }
        for (0..crop.height) |y| {
            if (y % 32 == 0) try checkCancellation(options.cancellation);
            for (0..crop.width) |x| {
                const at = (@as(usize, crop.y + @as(u32, @intCast(y))) * image.width + crop.x + x) * 4;
                const target = (y * crop.width + x) * 4;
                const alpha: u32 = source[at + 3];
                data[target] = @intCast((@as(u32, source[at + 2]) * alpha + 127) / 255);
                data[target + 1] = @intCast((@as(u32, source[at + 1]) * alpha + 127) / 255);
                data[target + 2] = @intCast((@as(u32, source[at]) * alpha + 127) / 255);
                data[target + 3] = @intCast(alpha);
            }
        }
        for (1..count) |index| try downsampleCancellable(state.levels[index - 1], state.levels[index], options.cancellation);
        try checkCancellation(options.cancellation);
        state.stats = .{ .bytes = total + @sizeOf(State), .pixel_bytes = total, .levels = count, .source = crop, .elapsed_ns = if (timer) |*t| t.read() else null };
        return @ptrCast(state);
    }
    pub fn adopt(self: *PreparedImage) !void {
        const state = cast(self);
        if (std.Thread.getCurrentId() != state.main_thread) return error.WrongThread;
        if (state.closing) return error.Closed;
        if (state.adopted) return error.AlreadyAdopted;
        if (state.lease.pins != 0) return error.ResourceInUse;
        state.lease.owner = state.main_thread;
        state.adopted = true;
    }
    pub fn view(self: *const PreparedImage) !drawing.ImageView {
        const state = cast(@constCast(self));
        try state.lease.checkOwner();
        if (state.closing) return error.Closed;
        if (!state.adopted) return error.NotAdopted;
        return .{ .lease = &state.lease, .identity = state.identity, .levels = state.levels[0..state.count] };
    }
    pub fn stats(self: *const PreparedImage) !Stats {
        const state = cast(@constCast(self));
        try state.lease.checkOwner();
        if (state.closing) return error.Closed;
        return state.stats;
    }
    pub fn inUse(self: *const PreparedImage) !bool {
        const state = cast(@constCast(self));
        try state.lease.checkOwner();
        if (state.closing) return error.Closed;
        return state.lease.pins != 0;
    }
    pub fn close(self: *PreparedImage) !void {
        const state = cast(self);
        try state.lease.checkOwner();
        if (state.closing) return error.Closed;
        try state.lease.ensureUnused();
        state.closing = true;
        const allocator = state.allocator;
        allocator.free(state.data);
        allocator.destroy(state);
    }
};
const State = struct {
    allocator: std.mem.Allocator,
    lease: drawing.Lease,
    main_thread: std.Thread.Id,
    adopted: bool,
    closing: bool = false,
    identity: u64,
    data: []u8,
    levels: [drawing.max_image_levels]drawing.ImageLevel = undefined,
    count: usize,
    stats: Stats,
};
fn cast(image: *PreparedImage) *State {
    return @ptrCast(@alignCast(image));
}
fn identity() !u64 {
    return drawing.reserveRasterIdentity() catch return error.ImageIdentityExhausted;
}
fn downsample(source: drawing.ImageLevel, target: drawing.ImageLevel) void {
    downsampleCancellable(source, target, null) catch unreachable;
}
fn checkCancellation(cancellation: ?*const images.Cancellation) !void {
    if (cancellation) |cancel| if (cancel.requested.load(.acquire)) return error.Cancelled;
}
fn downsampleCancellable(source: drawing.ImageLevel, target: drawing.ImageLevel, cancellation: ?*const images.Cancellation) !void {
    try checkCancellation(cancellation);
    const out = @constCast(target.pixels[0..target.byte_len]);
    const input = source.pixels[0..source.byte_len];
    const scale_x = @as(f64, @floatFromInt(source.width)) / @as(f64, @floatFromInt(target.width));
    const scale_y = @as(f64, @floatFromInt(source.height)) / @as(f64, @floatFromInt(target.height));
    // Area integration covers odd dimensions completely. Premultiplied
    // channels and alpha use the same weights; invisible RGB cannot bleed.
    for (0..target.height) |y| {
        if (y % 32 == 0) try checkCancellation(cancellation);
        for (0..target.width) |x| {
            // Multiplication can round the terminal edge slightly past the source
            // (for example 13 * (27 / 13)). Clamp the area and iteration together.
            const left = @min(@as(f64, @floatFromInt(source.width)), @as(f64, @floatFromInt(x)) * scale_x);
            const right = @min(@as(f64, @floatFromInt(source.width)), @as(f64, @floatFromInt(x + 1)) * scale_x);
            const top = @min(@as(f64, @floatFromInt(source.height)), @as(f64, @floatFromInt(y)) * scale_y);
            const bottom = @min(@as(f64, @floatFromInt(source.height)), @as(f64, @floatFromInt(y + 1)) * scale_y);
            var sum = [_]f64{ 0, 0, 0, 0 };
            var yy: u32 = @intFromFloat(@floor(top));
            while (yy < @as(u32, @intFromFloat(@ceil(bottom)))) : (yy += 1) {
                var xx: u32 = @intFromFloat(@floor(left));
                while (xx < @as(u32, @intFromFloat(@ceil(right)))) : (xx += 1) {
                    std.debug.assert(xx < source.width and yy < source.height);
                    const weight = (@min(right, @as(f64, @floatFromInt(xx + 1))) - @max(left, @as(f64, @floatFromInt(xx)))) * (@min(bottom, @as(f64, @floatFromInt(yy + 1))) - @max(top, @as(f64, @floatFromInt(yy))));
                    for (0..4) |channel| sum[channel] += @as(f64, @floatFromInt(input[@as(usize, yy) * source.stride + xx * 4 + channel])) * weight;
                }
            }
            const area = (right - left) * (bottom - top);
            for (0..4) |channel| out[y * target.stride + x * 4 + channel] = @intFromFloat(@round(sum[channel] / area));
        }
    }
}

test "odd mip chains clamp terminal integration edges and preserve premultiplied constants" {
    for ([_][2]u32{ .{ 27, 27 }, .{ 31, 7 }, .{ 3, 27 } }) |size| {
        var width = size[0];
        var height = size[1];
        var pixels = try std.testing.allocator.alloc(u8, @as(usize, width) * height * 4);
        defer std.testing.allocator.free(pixels);
        for (0..@as(usize, width) * height) |i| @memcpy(pixels[i * 4 ..][0..4], &[_]u8{ 17, 43, 70, 128 });
        while (width != 1 or height != 1) {
            const next_width = @max(1, width / 2);
            const next_height = @max(1, height / 2);
            const output = try std.testing.allocator.alloc(u8, @as(usize, next_width) * next_height * 4);
            errdefer std.testing.allocator.free(output);
            downsample(.{ .pixels = pixels.ptr, .byte_len = pixels.len, .width = width, .height = height, .stride = width * 4 }, .{ .pixels = output.ptr, .byte_len = output.len, .width = next_width, .height = next_height, .stride = next_width * 4 });
            for (0..@as(usize, next_width) * next_height) |i| try std.testing.expectEqualSlices(u8, &.{ 17, 43, 70, 128 }, output[i * 4 ..][0..4]);
            std.testing.allocator.free(pixels);
            pixels = output;
            width = next_width;
            height = next_height;
        }
    }
}
