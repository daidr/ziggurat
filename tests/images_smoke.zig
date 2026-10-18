const std = @import("std");
const images = @import("ziggurat_images");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;
const png = @embedFile("image_fixture/colors.png");
const jpeg = @embedFile("image_fixture/colors.jpg");
const bitmaps = .{
    @embedFile("image_fixture/bitmap24.bmp"),     @embedFile("image_fixture/bitmap24-top.bmp"),
    @embedFile("image_fixture/bitmap32.bmp"),     @embedFile("image_fixture/bitmap565.bmp"),
    @embedFile("image_fixture/bitmap8.bmp"),      @embedFile("image_fixture/bitmap-rle8.bmp"),
    @embedFile("image_fixture/bitmap-alpha.bmp"),
};
const bitmap_pixels = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 0, 255, 255, 0, 255, 255, 0, 255, 255, 255 };
const graphics = .{
    .{ @embedFile("image_fixture/graphic-interlaced.gif"), @embedFile("image_fixture/graphic-interlaced.rgba") },
    .{ @embedFile("image_fixture/graphic-dictionary.gif"), @embedFile("image_fixture/graphic-dictionary.rgba") },
    .{ @embedFile("image_fixture/graphic-deferred-clear.gif"), @embedFile("image_fixture/graphic-deferred-clear.rgba") },
};
const webps = .{
    .{ @embedFile("image_fixture/webp-lossy.webp"), @embedFile("image_fixture/webp-lossy.rgba") },
    .{ @embedFile("image_fixture/webp-lossless.webp"), @embedFile("image_fixture/webp-lossless.rgba") },
    .{ @embedFile("image_fixture/webp-opaque.webp"), @embedFile("image_fixture/webp-opaque.rgba") },
    .{ @embedFile("image_fixture/webp-palette.webp"), @embedFile("image_fixture/webp-palette.rgba") },
};
const orientations = .{
    @embedFile("image_fixture/orientation-1.jpg"), @embedFile("image_fixture/orientation-2.jpg"),
    @embedFile("image_fixture/orientation-3.jpg"), @embedFile("image_fixture/orientation-4.jpg"),
    @embedFile("image_fixture/orientation-5.jpg"), @embedFile("image_fixture/orientation-6.jpg"),
    @embedFile("image_fixture/orientation-7.jpg"), @embedFile("image_fixture/orientation-8.jpg"),
};
const oriented_order = [8][6]u8{
    .{ 0, 1, 2, 3, 4, 5 }, .{ 1, 0, 3, 2, 5, 4 },
    .{ 5, 4, 3, 2, 1, 0 }, .{ 4, 5, 2, 3, 0, 1 },
    .{ 0, 2, 4, 1, 3, 5 }, .{ 4, 2, 0, 5, 3, 1 },
    .{ 5, 3, 1, 4, 2, 0 }, .{ 1, 3, 5, 0, 2, 4 },
};

const Concurrent = struct {
    const Gate = struct {
        ready: std.Thread.ResetEvent = .{},
        start: std.Thread.ResetEvent = .{},
        count: std.atomic.Value(u32) = .init(0),
        fn arrive(self: *Gate) void {
            if (self.count.fetchAdd(1, .acq_rel) == 3) self.ready.set();
        }
    };
    gate: *Gate,
    allocator: std.mem.Allocator,
    main_thread: std.Thread.Id,
    failure: ?anyerror = null,
    fn run(self: *Concurrent) void {
        var worker = images.Worker.init(self.main_thread) catch |err| {
            self.failure = err;
            self.gate.arrive();
            return;
        };
        defer worker.deinit();
        self.gate.arrive();
        self.gate.start.wait();
        self.check(&worker) catch |err| {
            self.failure = err;
        };
    }
    fn check(self: *Concurrent, worker: *images.Worker) !void {
        for (0..16) |_| inline for (webps) |fixture| {
            const image = try worker.decode(self.allocator, fixture[0], .{});
            defer image.close() catch unreachable;
            try std.testing.expectEqualSlices(u8, fixture[1], try image.pixels());
        };
    }
    fn verify(allocator: std.mem.Allocator) !void {
        var gate: Gate = .{};
        var jobs: [4]Concurrent = undefined;
        var threads: [4]std.Thread = undefined;
        var count: usize = 0;
        errdefer {
            gate.start.set();
            for (threads[0..count]) |thread| thread.join();
        }
        for (&jobs, &threads) |*job, *thread| {
            job.* = .{ .gate = &gate, .allocator = allocator, .main_thread = std.Thread.getCurrentId() };
            thread.* = try std.Thread.spawn(.{}, run, .{job});
            count += 1;
        }
        gate.ready.wait();
        gate.start.set();
        for (threads) |thread| thread.join();
        count = 0;
        for (jobs) |job| if (job.failure) |err| return err;
        try equal(0, images.nativeReferences());
    }
};

const Job = struct {
    allocator: std.mem.Allocator,
    main_thread: std.Thread.Id,
    result: ?*images.Image = null,
    failure: ?anyerror = null,
    fn run(self: *Job) void {
        self.check() catch |err| {
            self.failure = err;
        };
    }
    fn allocationFailure(allocator: std.mem.Allocator, worker: *images.Worker, bytes: []const u8) !void {
        const image = try worker.decode(allocator, bytes, .{});
        defer image.close() catch unreachable;
    }
    fn check(self: *Job) !void {
        var worker = try images.Worker.init(self.main_thread);
        defer worker.deinit();
        try equal(1, images.nativeReferences());
        const allocator = self.allocator;
        const image = try worker.decode(allocator, png, .{});
        defer image.close() catch unreachable;
        try equal(2, image.width);
        try equal(3, image.height);
        const pixels = try image.pixels();
        try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 128 }, pixels[0..8]);
        try equal(0, pixels[11]);
        try equal(64, pixels[19]);
        try expectError(error.WrongThread, image.adopt());
        var cancellation: images.Cancellation = .{};
        cancellation.request();
        try expectError(error.Cancelled, worker.decode(allocator, png, .{ .cancellation = &cancellation }));
        try expectError(error.InvalidImage, worker.decode(allocator, png[0..24], .{}));
        const native_failure = worker.last_failure orelse return error.MissingNativeFailure;
        switch (native_failure) {
            .hresult => |hr| try expect(hr != 0),
            .gdk_pixbuf => |failure| try expect(failure.domain != 0),
            .webp => return error.UnexpectedCodec,
        }
        try equal(1, images.nativeReferences());
        try expectError(error.CapacityExceeded, worker.decode(allocator, png, .{ .limits = .{ .pixels = 5 } }));
        try expect(worker.last_failure == null);
        try std.testing.checkAllAllocationFailures(allocator, allocationFailure, .{ &worker, png });
        try std.testing.checkAllAllocationFailures(allocator, allocationFailure, .{ &worker, orientations[5] });
        inline for (bitmaps, 0..) |encoded, i| {
            const metadata = try images.inspect(encoded, .{});
            try equal(images.Format.bmp, metadata.format);
            const decoded = try worker.decode(allocator, encoded, .{});
            defer decoded.close() catch unreachable;
            try equal(2, decoded.width);
            try equal(3, decoded.height);
            var expected = bitmap_pixels;
            if (i == 6) for ([_]u8{ 255, 128, 0, 255, 64, 255 }, 0..) |alpha, at| {
                expected[at * 4 + 3] = alpha;
            };
            try std.testing.expectEqualSlices(u8, &expected, try decoded.pixels());
            try equal(1, images.nativeReferences());
            for (0..encoded.len) |end| {
                if (images.inspect(encoded[0..end], .{})) |_| return error.TruncatedBitmapAccepted else |_| {}
            }
        }
        {
            const core = try worker.decode(allocator, @embedFile("image_fixture/bitmap-core.bmp"), .{});
            defer core.close() catch unreachable;
            try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 0, 255, 0, 255 }, try core.pixels());
        }
        try std.testing.checkAllAllocationFailures(allocator, allocationFailure, .{ &worker, bitmaps[0] });
        try std.testing.checkAllAllocationFailures(allocator, allocationFailure, .{ &worker, bitmaps[6] });
        inline for (graphics) |fixture| {
            const metadata = try images.inspect(fixture[0], .{});
            try equal(images.Format.gif, metadata.format);
            const decoded = try worker.decode(allocator, fixture[0], .{});
            defer decoded.close() catch unreachable;
            try std.testing.expectEqualSlices(u8, fixture[1], try decoded.pixels());
            try expect(worker.last_failure == null);
            try equal(1, images.nativeReferences());
        }
        {
            const special = try worker.decode(allocator, @embedFile("image_fixture/graphic-special.gif"), .{});
            defer special.close() catch unreachable;
            try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255 }, try special.pixels());
            const animated = try worker.decode(allocator, @embedFile("image_fixture/graphic-animated.gif"), .{});
            defer animated.close() catch unreachable;
            try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255 }, try animated.pixels());
        }
        try std.testing.checkAllAllocationFailures(allocator, allocationFailure, .{ &worker, graphics[0][0] });
        try std.testing.checkAllAllocationFailures(allocator, allocationFailure, .{ &worker, graphics[1][0] });
        if (images.capabilities.webp) {
            inline for (webps) |fixture| {
                const metadata = try images.inspect(fixture[0], .{});
                try equal(images.Format.webp, metadata.format);
                const decoded = try worker.decode(allocator, fixture[0], .{});
                defer decoded.close() catch unreachable;
                try equal(31, decoded.width);
                try equal(27, decoded.height);
                try std.testing.expectEqualSlices(u8, fixture[1], try decoded.pixels());
                try expect(worker.last_failure == null);
                for (0..fixture[0].len) |end| {
                    if (images.inspect(fixture[0][0..end], .{})) |_| return error.TruncatedWebpAccepted else |_| {}
                }
            }
            try expectError(error.UnsupportedAnimation, worker.decode(allocator, @embedFile("image_fixture/webp-animated.webp"), .{}));
            try expectError(error.CapacityExceeded, worker.decode(allocator, webps[0][0], .{ .limits = .{ .pixels = 10 } }));
            try std.testing.checkAllAllocationFailures(allocator, allocationFailure, .{ &worker, webps[0][0] });
            try std.testing.checkAllAllocationFailures(allocator, allocationFailure, .{ &worker, webps[1][0] });
            var damaged = webps[0][0].*;
            const chunk = std.mem.indexOf(u8, &damaged, "VP8 ") orelse return error.FixtureMissingLossy;
            @memset(damaged[chunk + 18 ..], 0xff);
            if (worker.decode(allocator, &damaged, .{})) |unexpected| {
                try unexpected.close();
                return error.MalformedFixtureDecoded;
            } else |err| try equal(error.InvalidImage, err);
            const failure = worker.last_failure orelse return error.MissingNativeFailure;
            try expect(failure == .webp and failure.webp != 0);
            try expectError(error.Cancelled, worker.decode(allocator, webps[0][0], .{ .cancellation = &cancellation }));
            try expect(worker.last_failure == null);
        } else {
            try expectError(error.UnsupportedFormat, worker.decode(allocator, webps[0][0], .{}));
        }
        const baseline = try worker.decode(allocator, jpeg, .{});
        defer baseline.close() catch unreachable;
        const reference = try baseline.pixels();
        inline for (orientations, 1..) |encoded, orientation| {
            const current = try worker.decode(allocator, encoded, .{});
            defer current.close() catch unreachable;
            const swapped = orientation >= 5;
            try equal(@as(u32, if (swapped) 3 else 2), current.width);
            try equal(@as(u32, if (swapped) 2 else 3), current.height);
            const output = try current.pixels();
            for (oriented_order[orientation - 1], 0..) |source, target| try std.testing.expectEqualSlices(u8, reference[@as(usize, source) * 4 ..][0..4], output[target * 4 ..][0..4]);
        }
        self.result = try worker.decode(allocator, png, .{});
        worker.deinit();
        try equal(0, images.nativeReferences());
        try expectError(error.Closed, worker.decode(allocator, png, .{}));
    }
};

pub fn main() !void {
    var allocation_state: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer std.debug.assert(allocation_state.deinit() == .ok);
    if (images.capabilities.webp) try Concurrent.verify(allocation_state.allocator());
    var job: Job = .{ .main_thread = std.Thread.getCurrentId(), .allocator = allocation_state.allocator() };
    try expectError(error.UiThreadForbidden, images.Worker.init(job.main_thread));
    const thread = try std.Thread.spawn(.{}, Job.run, .{&job});
    thread.join();
    if (job.failure) |err| return err;
    const image = job.result orelse return error.MissingResult;
    try equal(0, images.nativeReferences());
    try expectError(error.WrongThread, image.pixels());
    try image.adopt();
    defer image.close() catch unreachable;
    try equal(24, (try image.pixels()).len);
    try expectError(error.AlreadyAdopted, image.adopt());
    try image.lease.acquire();
    try expectError(error.ResourceInUse, image.close());
    image.lease.release();
    try expect(image.adopted);
    std.debug.print("images: PNG/JPEG/BMP/GIF RGBA, EXIF 1..8, bitmap masks/palette/RLE/top-down, GIF first frame/interlace/LZW full dictionary, malformed/limits/cancel/OOM, exclusive handoff and resource pins passed\n", .{});
    if (images.capabilities.webp) {
        std.debug.print("WebP: lossless/lossy alpha oracle, four concurrent first-use workers, RIFF truncation/animation rejection, native failure/cancel/OOM passed\n", .{});
    } else std.debug.print("WebP disabled: explicit UnsupportedFormat passed\n", .{});
}
