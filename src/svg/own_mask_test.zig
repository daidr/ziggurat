const std = @import("std");
const api = @import("root.zig");
const v = @import("ziggurat_vector");
const allocator = std.testing.allocator;
const Mode = @FieldType(api.PrepareOptions, "compositing");
const modes = [_]Mode{ .pixel, .sample_color };
const chain_source = "<svg viewBox='0 0 4 4'><style>#a {mask:url(#b)}</style><defs>" ++
    "<mask id='c' maskUnits='userSpaceOnUse' x='0' y='0' width='4' height='4' mask-type='alpha'><rect width='4' height='4' fill='white' fill-opacity='.5'/></mask>" ++
    "<mask id='b' mask='url(#c)' maskUnits='userSpaceOnUse' x='0' y='0' width='4' height='4' mask-type='alpha'><rect width='4' height='4' fill='white' fill-opacity='.5'/></mask>" ++
    "<mask id='a' opacity='0' display='none' maskUnits='userSpaceOnUse' x='0' y='0' width='4' height='4' mask-type='alpha'><rect width='4' height='4' fill='white' fill-opacity='.5'/></mask>" ++
    "</defs><rect width='4' height='4' fill='blue' mask='url(#a)'/></svg>";

test "SVG own mask alpha and color-space factors follow independently resolved mask images" {
    const cases = [_]struct { mode: []const u8, interpolation: []const u8, alpha: u8 }{
        .{ .mode = "alpha", .interpolation = "sRGB", .alpha = 64 },
        .{ .mode = "luminance", .interpolation = "sRGB", .alpha = 32 },
        .{ .mode = "luminance", .interpolation = "linearRGB", .alpha = 14 },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(allocator, "<svg><defs><mask id='n' maskUnits='userSpaceOnUse' x='0' y='0' width='4' height='4' mask-type='alpha'><rect width='4' height='4' fill='white' fill-opacity='.5'/></mask>" ++
            "<mask id='m' mask='url(#n)' maskUnits='userSpaceOnUse' x='0' y='0' width='4' height='4' mask-type='{s}' color-interpolation='{s}'><rect width='4' height='4' fill='#808080' fill-opacity='.5'/></mask>" ++
            "</defs><rect width='4' height='4' fill='blue' mask='url(#m)'/></svg>", .{ case.mode, case.interpolation });
        defer allocator.free(source);
        const document = try api.Document.parse(allocator, source, .{});
        defer document.close() catch unreachable;
        for (modes) |mode| {
            const image = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4, .compositing = mode });
            defer image.close() catch unreachable;
            const pixels = (try image.view()).levels[0].pixels;
            // Nested alpha resolves to128/255. It multiplies the gray .5-alpha
            // body once, yielding BGRA(32,32,32,64). Its outer conversion is
            // alpha64, sRGB luminance32, or64*decode_sRGB(.5) rounded to14.
            for (0..16) |pixel| try std.testing.expectEqualSlices(u8, &.{ case.alpha, 0, 0, case.alpha }, pixels[pixel * 4 ..][0..4]);
        }
    }
}

test "SVG own mask nested CSS references ignore definition opacity and display" {
    const document = try api.Document.parse(allocator, chain_source, .{});
    defer document.close() catch unreachable;
    for (modes) |mode| {
        const image = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4, .compositing = mode });
        defer image.close() catch unreachable;
        const pixels = (try image.view()).levels[0].pixels;
        // Each nested mask image resolves once:128 ->64 ->32. Mask containers
        // do not apply their own opacity/display; these are not inherited.
        for (0..16) |pixel| try std.testing.expectEqualSlices(u8, &.{ 32, 0, 0, 32 }, pixels[pixel * 4 ..][0..4]);
    }
}

test "SVG own mask object content coordinates agree with an explicit content group at three scales" {
    const body = "<g transform='translate(.05 .025) skewX(6)'><rect x='.1' y='.1' width='.8' height='.8' fill='#88ccff' fill-opacity='.75'/></g>";
    const prefix = "<svg viewBox='0 0 12 8'><defs><clipPath id='clip'><rect x='.15' y='.1' width='.7' height='.8'/></clipPath>" ++
        "<mask id='n' maskUnits='objectBoundingBox' maskContentUnits='objectBoundingBox' x='.1' y='.15' width='.8' height='.7' mask-type='alpha'><ellipse cx='.5' cy='.5' rx='.5' ry='.5' fill-opacity='.6' fill='white'/></mask>";
    const suffix = "</defs><g transform='translate(.25 .5) skewX(8)'><rect x='2' y='2' width='8' height='4' fill='blue' mask='url(#m)'/></g></svg>";
    const own = try api.Document.parse(allocator, prefix ++
        "<mask id='m' mask='url(#n)' maskContentUnits='objectBoundingBox' maskUnits='userSpaceOnUse' x='1' y='1' width='10' height='6' clip-path='url(#clip)' mask-type='alpha'>" ++ body ++ "</mask>" ++ suffix, .{});
    defer own.close() catch unreachable;
    const wrapped = try api.Document.parse(allocator, prefix ++
        "<mask id='m' maskContentUnits='objectBoundingBox' maskUnits='userSpaceOnUse' x='1' y='1' width='10' height='6' clip-path='url(#clip)' mask-type='alpha'><g mask='url(#n)'>" ++ body ++ "</g></mask>" ++ suffix, .{});
    defer wrapped.close() catch unreachable;
    for (modes) |mode| for ([_]f64{ 1, 1.5, 2 }) |scale| {
        const options: api.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = @intFromFloat(12 * scale), .height = @intFromFloat(8 * scale), .compositing = mode };
        const a = try own.prepare(allocator, options);
        defer a.close() catch unreachable;
        const b = try wrapped.prepare(allocator, options);
        defer b.close() catch unreachable;
        try std.testing.expectEqualSlices(u8, a.pixels, b.pixels);
        var nonzero: usize = 0;
        for (a.pixels) |value| if (value != 0) {
            nonzero += 1;
        };
        try std.testing.expect(nonzero > 0);
    };
}

test "SVG own mask cycles share ordinary mask and use reference stacks" {
    const cases = [_][]const u8{
        "<svg><defs><mask id='a' mask='url(#a)'><rect width='4' height='4'/></mask></defs><rect width='4' height='4' mask='url(#a)'/></svg>",
        "<svg><defs><mask id='a' mask='url(#b)'><rect width='4' height='4'/></mask><mask id='b' mask='url(#a)'><rect width='4' height='4'/></mask></defs><rect width='4' height='4' mask='url(#a)'/></svg>",
        "<svg><defs><rect id='p' width='4' height='4' mask='url(#a)'/><mask id='a' mask='url(#b)'><rect width='4' height='4'/></mask><mask id='b'><use href='#p'/></mask></defs><rect width='4' height='4' mask='url(#a)'/></svg>",
    };
    for (cases) |source| {
        const document = try api.Document.parse(allocator, source, .{});
        defer document.close() catch unreachable;
        for (modes) |mode| try std.testing.expectError(error.ReferenceCycle, document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4, .compositing = mode }));
    }
}

fn allocationCase(a: std.mem.Allocator, document: *api.Document, mode: Mode) !void {
    const image = try document.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4, .compositing = mode });
    try image.close();
}
test "SVG own mask allocation failures and cumulative limits retain the source" {
    const document = try api.Document.parse(allocator, chain_source, .{});
    defer document.close() catch unreachable;
    for (modes) |mode| {
        try std.testing.checkAllAllocationFailures(allocator, allocationCase, .{ document, mode });
        var options: api.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4, .compositing = mode };
        options.limits.layers = 2;
        try std.testing.expectError(error.LayersFull, document.prepare(allocator, options));
        options.limits = .{ .reference_depth = 1 };
        try std.testing.expectError(error.ReferenceDepthFull, document.prepare(allocator, options));
        options.limits = .{ .bytes = 1024 };
        try std.testing.expectError(error.CapacityExceeded, document.prepare(allocator, options));
        options.limits = .{ .pixel_work = 1 };
        try std.testing.expectError(error.PixelWorkExceeded, document.prepare(allocator, options));
        options.limits = .{};
        const image = try document.prepare(allocator, options);
        defer image.close() catch unreachable;
        try std.testing.expectEqual(@as(u8, 32), image.pixels[3]);
    }
    try std.testing.expect((try document.stats()).nodes > 0);
}

const CancelAllocator = struct {
    cancellation: *v.Cancellation,
    cancel_at: usize,
    calls: usize = 0,
    live: usize = 0,
    fn allocator(self: *CancelAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *CancelAllocator = @ptrCast(@alignCast(context));
        const memory = std.testing.allocator.rawAlloc(length, alignment, ret) orelse return null;
        self.live += length;
        if (self.calls == self.cancel_at) self.cancellation.request();
        self.calls += 1;
        return memory;
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *CancelAllocator = @ptrCast(@alignCast(context));
        self.live -= memory.len;
        std.testing.allocator.rawFree(memory, alignment, ret);
    }
};
test "SVG own mask cancellation at every candidate allocation releases all nested storage" {
    const document = try api.Document.parse(allocator, chain_source, .{});
    defer document.close() catch unreachable;
    for (modes) |mode| {
        var cancel: v.Cancellation = .{};
        var probe: CancelAllocator = .{ .cancellation = &cancel, .cancel_at = std.math.maxInt(usize) };
        var options: api.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4, .compositing = mode, .cancellation = &cancel };
        const image = try document.prepare(probe.allocator(), options);
        try image.close();
        const total = probe.calls;
        try std.testing.expect(total > 10);
        try std.testing.expectEqual(@as(usize, 0), probe.live);
        for (0..total) |index| {
            cancel = .{};
            probe = .{ .cancellation = &cancel, .cancel_at = index };
            options.cancellation = &cancel;
            try std.testing.expectError(error.Cancelled, document.prepare(probe.allocator(), options));
            try std.testing.expectEqual(@as(usize, 0), probe.live);
        }
    }
}
