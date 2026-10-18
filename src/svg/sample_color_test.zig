const std = @import("std");
const s = @import("sample_color.zig");
const allocator = std.testing.allocator;
const opaque_red: s.Color = .{ 0, 0, 1, 1 };
const opaque_blue: s.Color = .{ 1, 0, 0, 1 };

test "sample_color_private group clip is applied after overlapping paints once" {
    const tile = try s.Tile.create(allocator, 2, 1024 * 1024);
    defer tile.close() catch unreachable;
    var work: s.Work = .{};
    try tile.begin(1, &work);
    try tile.push(1, &.{0x3333}, &work);
    try tile.paint(&.{0xffff}, &.{opaque_red}, 1, &work);
    try tile.paint(&.{0xffff}, &.{opaque_blue}, 1, &work);
    try tile.pop(null, &work);
    var bytes: [4]u8 = undefined;
    try tile.resolve(&bytes, &work);
    try std.testing.expectEqualSlices(u8, &.{ 128, 0, 0, 128 }, &bytes);

    try tile.begin(1, &work);
    try tile.push(1, &.{0x3333}, &work);
    try tile.push(1, &.{0x3333}, &work);
    try tile.paint(&.{0xffff}, &.{opaque_blue}, 1, &work);
    try tile.pop(null, &work);
    try tile.pop(null, &work);
    try tile.resolve(&bytes, &work);
    try std.testing.expectEqualSlices(u8, &.{ 128, 0, 0, 128 }, &bytes);
}

fn oracleOver(target: *[4]f64, source: [4]f64, amount: f64) void {
    for (0..4) |channel| target[channel] = source[channel] * amount + target[channel] * (1 - source[3] * amount);
}
fn byte(value: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}
test "sample_color_private nested opacity continuous masks and clip agree with lane oracle" {
    const tile = try s.Tile.create(allocator, 3, 1024 * 1024);
    defer tile.close() catch unreachable;
    const background: s.Color = .{ 0.11, 0.08, 0.2, 0.4 };
    const colors_a = [_]s.Color{ .{ 0.3, 0.1, 0.2, 0.6 }, .{ 0.1, 0.4, 0, 0.7 }, .{ 0, 0.1, 0.2, 0.25 } };
    const colors_b = [_]s.Color{ .{ 0, 0.2, 0.8, 0.9 }, .{ 0.2, 0, 0, 0.2 }, .{ 0.1, 0.4, 0.2, 0.7 } };
    const bits_a = [_]u16{ 0x6f6f, 0x3c3c, 0xffff };
    const bits_b = [_]u16{ 0xff00, 0xaaaa, 0x7b3d };
    const inner_clip = [_]u16{ 0xcccc, 0xcccc, 0x9669 };
    const outer_clip = [_]u16{ 0x3333, 0xffff, 0xf3f3 };
    const inner_mask = [_]f64{ 0.65, 0.25, 1 };
    const outer_mask = [_]f64{ 0.75, 1, 0.4 };
    var work: s.Work = .{};
    try tile.begin(3, &work);
    try tile.paint(&.{ 0xffff, 0xffff, 0xffff }, &.{ background, background, background }, 1, &work);
    try tile.push(0.6, &outer_clip, &work);
    try tile.push(0.37, &inner_clip, &work);
    try tile.paint(&bits_a, &colors_a, 0.83, &work);
    try tile.paint(&bits_b, &colors_b, 1, &work);
    try tile.pop(&inner_mask, &work);
    try tile.paint(&bits_b, &colors_b, 0.23, &work);
    try tile.pop(&outer_mask, &work);
    var output: [12]u8 = undefined;
    try tile.resolve(&output, &work);
    for (0..3) |pixel| {
        var sum: [4]f64 = @splat(0);
        for (0..16) |lane| {
            const bit = @as(u16, 1) << @intCast(lane);
            var inner: [4]f64 = @splat(0);
            if (bits_a[pixel] & bit != 0) oracleOver(&inner, colors_a[pixel], 0.83);
            if (bits_b[pixel] & bit != 0) oracleOver(&inner, colors_b[pixel], 1);
            var outer: [4]f64 = @splat(0);
            if (inner_clip[pixel] & bit != 0) oracleOver(&outer, inner, 0.37 * inner_mask[pixel]);
            if (bits_b[pixel] & bit != 0) oracleOver(&outer, colors_b[pixel], 0.23);
            var result: [4]f64 = background;
            if (outer_clip[pixel] & bit != 0) oracleOver(&result, outer, 0.6 * outer_mask[pixel]);
            for (&sum, result) |*channel, value| channel.* += value / 16;
        }
        for (sum, 0..) |value, channel| try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(byte(value))), @as(f64, @floatFromInt(output[pixel * 4 + channel])), 1);
    }
}

test "sample_color_private mask group can resolve and discard without painting its caller" {
    const tile = try s.Tile.create(allocator, 2, 1024 * 1024);
    defer tile.close() catch unreachable;
    var work: s.Work = .{};
    try tile.begin(1, &work);
    try tile.push(1, null, &work);
    try tile.paint(&.{0xffff}, &.{opaque_red}, 1, &work);
    try tile.push(0.5, &.{0x3333}, &work);
    try tile.paint(&.{0xffff}, &.{opaque_blue}, 1, &work);
    var mask_mean: [1]s.Color = undefined;
    try tile.mean(&mask_mean, &work);
    try std.testing.expectEqual(@as(f64, 0.25), mask_mean[0][3]);
    try tile.discard();
    try tile.pop(&.{mask_mean[0][3]}, &work);
    var bytes: [4]u8 = undefined;
    try tile.resolve(&bytes, &work);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 64, 64 }, &bytes);
}

fn allocationCase(a: std.mem.Allocator) !void {
    const tile = try s.Tile.create(a, 2, 1024 * 1024);
    defer tile.close() catch unreachable;
    var work: s.Work = .{};
    try tile.begin(1, &work);
    try tile.push(0.5, null, &work);
    try tile.paint(&.{0xffff}, &.{opaque_red}, 1, &work);
    try tile.pop(null, &work);
    var bytes: [4]u8 = undefined;
    try tile.resolve(&bytes, &work);
}
test "sample_color_private all candidate allocations and explicit byte budget are balanced" {
    try std.testing.checkAllAllocationFailures(allocator, allocationCase, .{});
    const tile = try s.Tile.create(allocator, 2, 1024 * 1024);
    defer tile.close() catch unreachable;
    const bytes = try tile.stats();
    try std.testing.expectError(error.CapacityExceeded, s.Tile.create(allocator, 2, bytes - 1));
    try std.testing.expectError(error.InvalidLayers, s.Tile.create(allocator, 33, std.math.maxInt(usize)));
}

test "sample_color_private same depth reuse and aborted groups allocate nothing" {
    var failure = std.testing.FailingAllocator.init(allocator, .{});
    const tile = try s.Tile.create(failure.allocator(), 1, 1024 * 1024);
    defer tile.close() catch unreachable;
    const allocations = failure.alloc_index;
    failure.fail_index = allocations;
    var work: s.Work = .{};
    for (0..100) |_| {
        try tile.begin(1, &work);
        for (0..7) |_| {
            try tile.push(1, null, &work);
            try tile.paint(&.{0xffff}, &.{opaque_red}, 1, &work);
            try tile.pop(null, &work);
            try tile.push(1, null, &work);
            try tile.paint(&.{0xffff}, &.{opaque_blue}, 1, &work);
            try tile.discard();
        }
        var bytes: [4]u8 = undefined;
        try tile.resolve(&bytes, &work);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, &bytes);
    }
    try std.testing.expectEqual(allocations, failure.alloc_index);
}

test "sample_color_private invalid or exhausted operations leave completed colors unchanged" {
    const tile = try s.Tile.create(allocator, 1, 1024 * 1024);
    defer tile.close() catch unreachable;
    var work: s.Work = .{};
    try tile.begin(1, &work);
    try tile.paint(&.{0xffff}, &.{opaque_red}, 1, &work);
    try std.testing.expectError(error.InvalidPremultipliedColor, tile.paint(&.{0xffff}, &.{.{ 1, 0, 0, 0 }}, 1, &work));
    work.limit = work.rgba_operations + 15;
    try std.testing.expectError(error.ColorWorkExceeded, tile.push(1, null, &work));
    try std.testing.expectEqual(@as(usize, 0), tile.depth);
    work.limit = std.math.maxInt(u64);
    try tile.push(1, null, &work);
    try std.testing.expectError(error.LayersFull, tile.push(1, null, &work));
    try tile.paint(&.{0xffff}, &.{opaque_blue}, 1, &work);
    try std.testing.expectError(error.InvalidOpacity, tile.pop(&.{std.math.nan(f64)}, &work));
    var output: [4]u8 = @splat(19);
    try std.testing.expectError(error.UnbalancedGroup, tile.resolve(&output, &work));
    try std.testing.expectEqualSlices(u8, &.{ 19, 19, 19, 19 }, &output);
    try tile.discard();
    work.limit = work.rgba_operations;
    try std.testing.expectError(error.ColorWorkExceeded, tile.resolve(&output, &work));
    try std.testing.expectEqualSlices(u8, &.{ 19, 19, 19, 19 }, &output);
    work.limit = std.math.maxInt(u64);
    try tile.resolve(&output, &work);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, &output);
}
