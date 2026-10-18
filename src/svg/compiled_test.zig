const std = @import("std");
const api = @import("root.zig");
const v = @import("ziggurat_vector");
const allocator = std.testing.allocator;

test "compiled sample color group clip resolves overlapping children once while pixel mode stays stable" {
    const document = try api.Document.parse(allocator, "<svg viewBox='0 0 3 1'><defs><clipPath id='c'><rect x='.5' width='2' height='1'/></clipPath></defs>" ++
        "<g clip-path='url(#c)'><rect width='3' height='1' fill='red'/><rect width='3' height='1' fill='blue'/></g></svg>", .{});
    defer document.close() catch unreachable;
    const pixel = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 3, .height = 1 });
    defer pixel.close() catch unreachable;
    try std.testing.expectEqualSlices(u8, &.{ 128, 0, 64, 192 }, (try pixel.view()).levels[0].pixels[0..4]);
    const strict = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 3, .height = 1, .compositing = .sample_color });
    defer strict.close() catch unreachable;
    const pixels = (try strict.view()).levels[0].pixels;
    try std.testing.expectEqualSlices(u8, &.{ 128, 0, 0, 128, 255, 0, 0, 255, 128, 0, 0, 128 }, pixels[0..12]);
    const stats = try strict.stats();
    try std.testing.expect(stats.peak_bytes > stats.owned_bytes);
    try std.testing.expect(stats.color_work > 0 and stats.scene_work > 0 and stats.sample_work > 0 and stats.sort_work > 0);
}

test "compiled sample color resolves use styles gradients masks and nested viewport before raster" {
    const document = try api.Document.parse(allocator, "<svg viewBox='0 0 8 4'><style>.p{fill:url(#g);stroke:none}</style><defs>" ++
        "<linearGradient id='g'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient>" ++
        "<mask id='m' maskUnits='userSpaceOnUse' x='0' y='0' width='8' height='4' mask-type='alpha'><rect width='8' height='4' fill='white' fill-opacity='.5'/></mask>" ++
        "<symbol id='s' viewBox='0 0 8 4'><rect class='p' width='8' height='4'/></symbol></defs>" ++
        "<svg x='.5' y='.5' width='7' height='3' viewBox='0 0 8 4' preserveAspectRatio='none'><g mask='url(#m)' opacity='.5'><use href='#s' width='8' height='4'/></g></svg></svg>", .{});
    defer document.close() catch unreachable;
    const image = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 8, .height = 4, .compositing = .sample_color });
    defer image.close() catch unreachable;
    const pixels = (try image.view()).levels[0].pixels;
    // The mask resolves to one continuous alpha per physical pixel. At the
    // corner its .5-alpha content has quarter coverage (32/255); that then
    // multiplies the target's quarter coverage and .5 group opacity once.
    try std.testing.expectEqual(@as(u8, 4), pixels[3]);
    try std.testing.expectEqual(@as(u8, 64), pixels[(1 * 8 + 3) * 4 + 3]);
    try std.testing.expect(pixels[(1 * 8 + 3) * 4] > 0 and pixels[(1 * 8 + 3) * 4 + 2] > 0);
}

fn allocationCase(a: std.mem.Allocator, document: *const api.Document) !void {
    const image = try document.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4, .compositing = .sample_color });
    try image.close();
}
test "compiled sample color all allocation failures and exact aggregate peak preserve source ownership" {
    const document = try api.Document.parse(allocator, "<svg viewBox='0 0 4 4'><defs><clipPath id='c'><circle cx='2' cy='2' r='2'/></clipPath></defs>" ++
        "<g clip-path='url(#c)' opacity='.7'><path d='M0 0H4V4H0Z' fill='red' stroke='blue' stroke-width='.5'/></g></svg>", .{});
    defer document.close() catch unreachable;
    try std.testing.checkAllAllocationFailures(allocator, allocationCase, .{document});
    const image = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4, .compositing = .sample_color });
    const peak = (try image.stats()).peak_bytes;
    try image.close();
    try std.testing.expectError(error.CapacityExceeded, document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4, .compositing = .sample_color, .limits = .{ .bytes = peak - 1 } }));
    const exact = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4, .compositing = .sample_color, .limits = .{ .bytes = peak } });
    defer exact.close() catch unreachable;
    try std.testing.expectEqual(peak, (try exact.stats()).peak_bytes);
    try std.testing.expect((try document.stats()).nodes > 0);
}

test "compiled sample color limits cancellation and unsupported contracts publish no candidate" {
    const document = try api.Document.parse(allocator, "<svg><g opacity='.5'><rect width='4' height='4'/></g></svg>", .{});
    defer document.close() catch unreachable;
    var options: api.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4, .compositing = .sample_color };
    options.limits.color_work = 1;
    try std.testing.expectError(error.ColorWorkExceeded, document.prepare(allocator, options));
    options.limits = .{ .scene_work = 1 };
    try std.testing.expectError(error.SceneWorkExceeded, document.prepare(allocator, options));
    options.limits = .{ .sample_work = 1 };
    try std.testing.expectError(error.SampleWorkExceeded, document.prepare(allocator, options));
    options.limits = .{ .pixel_work = 1 };
    try std.testing.expectError(error.PixelWorkExceeded, document.prepare(allocator, options));
    options.limits = .{ .sort_work = 1 };
    try std.testing.expectError(error.SortBudgetExceeded, document.prepare(allocator, options));
    options.limits = .{ .raster = .{ .scan_tests = 1 } };
    try std.testing.expectError(error.ScanBudgetExceeded, document.prepare(allocator, options));
    options.limits = .{ .parse_work = 1 };
    try std.testing.expectError(error.ParseWorkExceeded, document.prepare(allocator, options));
    options.limits = .{ .node_visits = 1 };
    try std.testing.expectError(error.NodeWorkExceeded, document.prepare(allocator, options));
    options.limits = .{ .layers = 0 };
    try std.testing.expectError(error.LayersFull, document.prepare(allocator, options));
    options.limits = .{};
    var cancellation: v.Cancellation = .{};
    cancellation.request();
    options.cancellation = &cancellation;
    try std.testing.expectError(error.Cancelled, document.prepare(allocator, options));
    const invalid = try api.Document.parse(allocator, "<svg><defs><clipPath id='c'><use href='#g'/></clipPath><g id='g'><rect width='4' height='4'/></g></defs><rect width='4' height='4' clip-path='url(#c)'/></svg>", .{});
    defer invalid.close() catch unreachable;
    options.cancellation = null;
    try std.testing.expectError(error.InvalidClipUseTarget, invalid.prepare(allocator, options));
}

test "compiled sample color worker closes source before exclusive main adoption" {
    const Probe = struct {
        main_thread: std.Thread.Id,
        image: ?*api.Prepared = null,
        failure: ?anyerror = null,
        fn worker(self: *@This()) void {
            self.image = self.run() catch |err| {
                self.failure = err;
                return;
            };
        }
        fn run(self: *@This()) !*api.Prepared {
            const document = try api.Document.parse(allocator, "<svg viewBox='0 0 2 1'><g opacity='.5'><rect width='2' height='1' fill='blue'/></g></svg>", .{});
            defer document.close() catch unreachable;
            return document.prepare(allocator, .{ .main_thread = self.main_thread, .width = 2, .height = 1, .compositing = .sample_color });
        }
    };
    var probe: Probe = .{ .main_thread = std.Thread.getCurrentId() };
    const thread = try std.Thread.spawn(.{}, Probe.worker, .{&probe});
    thread.join();
    if (probe.failure) |err| return err;
    const image = probe.image orelse return error.MissingPrepared;
    var closed = false;
    defer if (!closed) image.close() catch unreachable;
    try std.testing.expectError(error.WrongThread, image.view());
    try image.adopt();
    try std.testing.expectError(error.AlreadyAdopted, image.adopt());
    const view = try image.view();
    try view.validate();
    try std.testing.expectEqualSlices(u8, &.{ 128, 0, 0, 128, 128, 0, 0, 128 }, view.levels[0].pixels[0..8]);
    try view.lease.acquire();
    try std.testing.expectError(error.ResourceInUse, image.close());
    view.lease.release();
    try image.close();
    closed = true;
}

test "compiled sample color shared viewport and object clips retain one sample boundary at three scales" {
    const document = try api.Document.parse(allocator, "<svg viewBox='0 0 8 4'><defs><clipPath id='c' clipPathUnits='objectBoundingBox'><rect x='.0625' y='.125' width='.875' height='.75'/></clipPath></defs>" ++
        "<g clip-path='url(#c)' opacity='.5'><rect width='8' height='4' fill='none'/><svg x='.5' y='.5' width='7' height='3' viewBox='0 0 7 3'>" ++
        "<rect width='7' height='3' fill='red'/><rect width='7' height='3' fill='blue'/></svg></g></svg>", .{});
    defer document.close() catch unreachable;
    for ([_]f64{ 1, 1.5, 2 }) |scale| {
        const width: u32 = @intFromFloat(8 * scale);
        const height: u32 = @intFromFloat(4 * scale);
        const image = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = width, .height = height, .compositing = .sample_color });
        defer image.close() catch unreachable;
        const pixels = (try image.view()).levels[0].pixels;
        for (0..height) |y| for (0..width) |x| {
            var count: u32 = 0;
            for (0..4) |sy| for (0..4) |sx| {
                const px = @as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(sx)) + 0.5) / 4;
                const py = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(sy)) + 0.5) / 4;
                if (px >= 0.5 * scale and px < 7.5 * scale and py >= 0.5 * scale and py < 3.5 * scale) count += 1;
            };
            const alpha: u8 = @intFromFloat(@round(@as(f64, @floatFromInt(count)) / 16 * 0.5 * 255));
            try std.testing.expectEqualSlices(u8, &.{ alpha, 0, 0, alpha }, pixels[(y * width + x) * 4 ..][0..4]);
        };
    }
}

test "compiled sample color curves arcs and evenodd holes match independent prepared path bits" {
    const data = "M.2 .3C1 -1 4 1 4.8 2A2 1 25 0 1 .2 2.7Z M1 1H2V2H1Z";
    const document = try api.Document.parse(allocator, "<svg viewBox='0 0 5 3'><path d='" ++ data ++ "' transform='matrix(1 .2 .1 1 .5 .25)' fill='blue' fill-rule='evenodd'/></svg>", .{});
    defer document.close() catch unreachable;
    const path = try v.Path.parseData(allocator, data, .{});
    defer path.close() catch unreachable;
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const width: u32 = @intFromFloat(10 * scale);
        const height: u32 = @intFromFloat(6 * scale);
        const image = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = width, .height = height, .compositing = .sample_color });
        defer image.close() catch unreachable;
        const transform = (v.Transform{ .yx = 0.2, .xy = 0.1, .x0 = 0.5, .y0 = 0.25 }).then(.{ .xx = 2, .yy = 2 });
        const mask = try path.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .viewport = .{ .width = 10, .height = 6 }, .transform = transform, .style = .{ .fill = .even_odd }, .scale = scale });
        defer mask.close() catch unreachable;
        const pixels = (try image.view()).levels[0].pixels;
        for (0..height) |y| for (0..width) |x| {
            const alpha = mask.coverage.pixels[y * mask.coverage.stride + x];
            try std.testing.expectEqualSlices(u8, &.{ alpha, 0, 0, alpha }, pixels[(y * width + x) * 4 ..][0..4]);
        };
    }
}

test "compiled sample color preserves unsupported radial and definition contracts" {
    const cases = [_]struct { source: []const u8, err: anyerror }{
        .{ .source = "<svg><defs><radialGradient id='g' gradientUnits='userSpaceOnUse' cx='2.5' cy='2.5' r='2' fx='4.5' fy='2.5' spreadMethod='repeat'><stop stop-color='red' stop-opacity='0'/><stop offset='1' stop-color='blue'/></radialGradient></defs><rect width='4' height='4' fill='url(#g)'/></svg>", .err = error.UnsupportedRadialAverage },
        .{ .source = "<svg><defs><radialGradient id='g' gradientUnits='userSpaceOnUse' cx='2.5' cy='2.5' r='3' fx='4.5' fy='2.5' fr='1'><stop/></radialGradient></defs><rect width='4' height='4' fill='url(#g)'/></svg>", .err = error.UnsupportedRadialFocus },
        .{ .source = "<svg><defs><mask id='m' mask='url(#m)'><rect width='4' height='4'/></mask></defs><rect width='4' height='4' mask='url(#m)'/></svg>", .err = error.ReferenceCycle },
        .{ .source = "<svg><defs><clipPath id='c' mask='url(#m)'/></defs><rect width='4' height='4' clip-path='url(#c)'/></svg>", .err = error.UnsupportedClipContainerEffect },
    };
    for (cases) |case| {
        const document = try api.Document.parse(allocator, case.source, .{});
        defer document.close() catch unreachable;
        try std.testing.expectError(case.err, document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 4, .height = 4, .compositing = .sample_color }));
    }
}
