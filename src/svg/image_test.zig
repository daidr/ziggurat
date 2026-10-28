const std = @import("std");
const svg = @import("root.zig");
const drawing = @import("ziggurat_drawing_resources");
const v = @import("ziggurat_vector");
const a = std.testing.allocator;
const Mode = @FieldType(svg.PrepareOptions, "compositing");
const key = "data:image/png;base64,AAAA";
const picture = "<image href='" ++ key ++ "' x='2' y='2' width='8' height='4'/>";
const Mock = struct {
    lease: drawing.Lease = drawing.Lease.init(0),
    image_lease: drawing.Lease = drawing.Lease.init(0),
    pixels: [16]u8 = .{ 0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 0, 0, 0, 0 },
    level: drawing.ImageLevel = undefined,
    calls: usize = 0,
    solid: bool = false,
    invalid: bool = false,
    invalid_descriptor: bool = false,
    fn provider(self: *Mock) svg.image.Provider {
        self.lease.owner = std.Thread.getCurrentId();
        self.image_lease.owner = std.Thread.getCurrentId();
        return .{ .context = self, .lease = &self.lease, .resolve_fn = resolve };
    }
    fn resolve(context: *anyopaque, uri: []const u8) !drawing.ImageView {
        const self: *Mock = @ptrCast(@alignCast(context));
        try std.testing.expectEqual(@as(usize, 1), self.lease.pins);
        try std.testing.expectEqualStrings(key, uri);
        self.calls += 1;
        if (self.solid) self.pixels = @bitCast(@as([4][4]u8, @splat(.{ 0, 0, 255, 255 })));
        if (self.invalid) self.pixels[0] = 255;
        if (self.invalid) self.pixels[3] = 0;
        self.level = .{ .pixels = &self.pixels, .byte_len = self.pixels.len, .width = 2, .height = 2, .stride = 8 };
        if (self.invalid_descriptor) self.level.stride = 4;
        return .{ .lease = &self.image_lease, .identity = 1, .levels = @as(*[1]drawing.ImageLevel, @ptrCast(&self.level)) };
    }
    fn unused(self: *Mock) !void {
        try std.testing.expectEqual(@as(usize, 0), self.lease.pins);
        try std.testing.expectEqual(@as(usize, 0), self.image_lease.pins);
    }
};
fn prepare(allocator: std.mem.Allocator, document: *svg.Document, mode: Mode, provider: ?*const svg.image.Provider) !*svg.Prepared {
    return document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 16, .height = 12, .compositing = mode, .image_provider = provider });
}
fn equal(input: []const u8, expected: []const u8, mode: Mode) !void {
    const document = try svg.Document.parse(a, input, .{});
    defer document.close() catch unreachable;
    const oracle = try svg.Document.parse(a, expected, .{});
    defer oracle.close() catch unreachable;
    var mock: Mock = .{ .solid = true };
    const provider = mock.provider();
    const actual = try prepare(a, document, mode, &provider);
    defer actual.close() catch unreachable;
    const reference = try prepare(a, oracle, mode, null);
    defer reference.close() catch unreachable;
    try std.testing.expectEqualSlices(u8, reference.pixels, actual.pixels);
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
    try mock.unused();
}
test "embedded images fit geometry independently of fill stroke and outer affine" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg>" ++ picture ++ "</svg>", "<svg><rect x='4' y='2' width='4' height='4' fill='red'/></svg>", mode);
        try equal("<svg><image href='" ++ key ++ "' x='2' y='2' width='8' height='4' preserveAspectRatio='none' fill='none' stroke='blue' stroke-width='12'/></svg>", "<svg><rect x='2' y='2' width='8' height='4' fill='red'/></svg>", mode);
        try equal("<svg><image href='" ++ key ++ "' x='2' y='2' width='8' height='4' preserveAspectRatio='xMaxYMax slice'/></svg>", "<svg><rect x='2' y='2' width='8' height='4' fill='red'/></svg>", mode);
        try equal("<svg><g transform='matrix(1 .25 .5 1 1 0)' opacity='.5'>" ++ picture ++ "</g></svg>", "<svg><g transform='matrix(1 .25 .5 1 1 0)' opacity='.5'><rect x='4' y='2' width='4' height='4' fill='red'/></g></svg>", mode);
        // The positioning box is [2,10]x[2,6], not the fitted [4,8] square.
        try equal("<svg><defs><clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='.5' height='1'/></clipPath></defs><image href='" ++ key ++ "' x='2' y='2' width='8' height='4' clip-path='url(#c)'/></svg>", "<svg><rect x='4' y='2' width='2' height='4' fill='red'/></svg>", mode);
        try equal("<svg><g transform='matrix(1 0 .25 1 0 0)'><defs><clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='.5' height='1'/></clipPath></defs><image href='" ++ key ++ "' x='2' y='2' width='8' height='4' clip-path='url(#c)'/></g></svg>", "<svg><g transform='matrix(1 0 .25 1 0 0)'><rect x='4' y='2' width='2' height='4' fill='red'/></g></svg>", mode);
        try equal("<svg><defs><image id='i' href='" ++ key ++ "' x='2' y='2' width='8' height='4'/></defs><use href='#i'/><use href='#i' x='4'/></svg>", "<svg><rect x='4' y='2' width='8' height='4' fill='red'/></svg>", mode);
        try equal("<svg><defs><mask id='m' mask-type='alpha' maskUnits='userSpaceOnUse' x='0' y='0' width='16' height='12'>" ++ picture ++ "</mask></defs><rect width='16' height='12' fill='red' mask='url(#m)'/></svg>", "<svg><rect x='4' y='2' width='4' height='4' fill='red'/></svg>", mode);
    }
}
test "embedded image bilinear pixels are an independent premultiplied oracle" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const document = try svg.Document.parse(a, "<svg><image href='" ++ key ++ "' width='4' height='4' preserveAspectRatio='none'/></svg>", .{});
        defer document.close() catch unreachable;
        var mock: Mock = .{};
        const provider = mock.provider();
        const actual = try prepare(a, document, mode, &provider);
        defer actual.close() catch unreachable;
        // Explicit 2x2 source weights at destination (1.5,1.5):
        // 9/16 red, 3/16 green, 3/16 blue, 1/16 transparent.
        try std.testing.expectEqualSlices(u8, &.{ 48, 48, 143, 239 }, actual.pixels[(1 * 16 + 1) * 4 ..][0..4]);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, actual.pixels[0..4]);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, actual.pixels[(3 * 16 + 3) * 4 ..][0..4]);
        @memset(&mock.pixels, 0);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, actual.pixels[0..4]);
        try mock.unused();
    }
}
test "embedded image request instance and borrowed-source accounting cannot be bypassed by use" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        const cached = try svg.Document.parse(a, "<svg><defs><image id='i' href='" ++ key ++ "' width='4' height='4'/></defs><use href='#i'/><use href='#i' x='4'/></svg>", .{});
        defer cached.close() catch unreachable;
        const distinct = try svg.Document.parse(a, "<svg>" ++ picture ++ "<image href='data:image/jpeg;base64,AAAA' width='4' height='4'/></svg>", .{});
        defer distinct.close() catch unreachable;
        var mock: Mock = .{};
        var provider = mock.provider();
        provider.limits.instances = 1;
        try std.testing.expectError(error.ImageInstancesFull, prepare(a, cached, mode, &provider));
        try std.testing.expectEqual(@as(usize, 1), mock.calls);
        try mock.unused();
        mock = .{};
        provider = mock.provider();
        provider.limits.requests = 1;
        try std.testing.expectError(error.ImageRequestsFull, prepare(a, distinct, mode, &provider));
        try std.testing.expectEqual(@as(usize, 1), mock.calls);
        try mock.unused();
        mock = .{ .invalid_descriptor = true };
        provider = mock.provider();
        try std.testing.expectError(error.InvalidImageResource, prepare(a, cached, mode, &provider));
        try mock.unused();
        const disabled = try svg.Document.parse(a, "<svg><image href='" ++ key ++ "' width='0' height='4'/><image href='" ++ key ++ "' width='4' height='4' display='none'/></svg>", .{});
        defer disabled.close() catch unreachable;
        mock = .{};
        provider = mock.provider();
        const output = try prepare(a, disabled, mode, &provider);
        defer output.close() catch unreachable;
        try std.testing.expectEqual(@as(usize, 0), mock.calls);
        try mock.unused();
    }
}
test "embedded image rejection is closed before resource lookup" {
    const cases = [_]struct { source: []const u8, err: anyerror }{
        .{ .source = "<image href='https://example.invalid/a.png' width='4' height='4'/>", .err = error.ExternalImageDenied },
        .{ .source = "<image href='data:image/svg+xml;base64,AAAA' width='4' height='4'/>", .err = error.ExternalImageDenied },
        .{ .source = "<image href='data:image/png;base64,AB==' width='4' height='4'/>", .err = error.InvalidImageDataUri },
        .{ .source = "<image href='" ++ key ++ "' width='-1' height='4'/>", .err = error.InvalidImageSize },
        .{ .source = "<image href='" ++ key ++ "' height='4'/>", .err = error.ImageSizeRequired },
        .{ .source = "<image href='" ++ key ++ "' width='4' height='4' overflow='visible'/>", .err = error.UnsupportedImageOverflow },
        .{ .source = "<image href='" ++ key ++ "' width='4' height='4' overflow='auto'/>", .err = error.UnsupportedImageOverflow },
        .{ .source = "<image href='" ++ key ++ "' width='4' height='4' style='overflow:scroll'/>", .err = error.UnsupportedImageOverflow },
        .{ .source = "<style>image{overflow:auto}</style><image href='" ++ key ++ "' width='4' height='4'/>", .err = error.UnsupportedImageOverflow },
        .{ .source = "<g overflow='scroll'><image href='" ++ key ++ "' width='4' height='4' overflow='inherit'/></g>", .err = error.UnsupportedImageOverflow },
        .{ .source = "<image href='" ++ key ++ "' width='4' height='4' style='overflow:initial'/>", .err = error.UnsupportedImageOverflow },
        .{ .source = "<image href='" ++ key ++ "' width='4' height='4' style='overflow:unset'/>", .err = error.UnsupportedImageOverflow },
        .{ .source = "<style>image{overflow:auto!important}</style><image href='" ++ key ++ "' width='4' height='4' style='overflow:hidden'/>", .err = error.UnsupportedImageOverflow },
        .{ .source = "<image href='" ++ key ++ "' width='4' height='4' preserveAspectRatio='defer xMidYMid'/>", .err = error.InvalidAspectRatio },
        .{ .source = "<image href='" ++ key ++ "' width='4' height='4'><rect width='2' height='2'/></image>", .err = error.UnsupportedImageChild },
    };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (cases) |case| {
        const source = try std.mem.concat(a, u8, &.{ "<svg>", case.source, "</svg>" });
        defer a.free(source);
        const document = try svg.Document.parse(a, source, .{});
        defer document.close() catch unreachable;
        var mock: Mock = .{};
        const provider = mock.provider();
        try std.testing.expectError(case.err, prepare(a, document, mode, &provider));
        try std.testing.expectEqual(@as(usize, 0), mock.calls);
        try mock.unused();
    };
    const document = try svg.Document.parse(a, "<svg>" ++ picture ++ "</svg>", .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| try std.testing.expectError(error.ImageProviderRequired, prepare(a, document, mode, null));
}
test "image overflow provenance follows noninheritance and the winning cascade" {
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try equal("<svg><g overflow='auto'>" ++ picture ++ "</g></svg>", "<svg><rect x='4' y='2' width='4' height='4' fill='red'/></svg>", mode);
        try equal("<svg><g overflow='scroll'><image href='" ++ key ++ "' x='2' y='2' width='8' height='4' overflow='inherit' style='overflow:hidden'/></g></svg>", "<svg><rect x='4' y='2' width='4' height='4' fill='red'/></svg>", mode);
        try equal("<svg><style>image{overflow:scroll}</style><image href='" ++ key ++ "' x='2' y='2' width='8' height='4' style='overflow:hidden'/></svg>", "<svg><rect x='4' y='2' width='4' height='4' fill='red'/></svg>", mode);
    }
}
fn allocationTrial(allocator: std.mem.Allocator, document: *svg.Document, mode: Mode) !void {
    var mock: Mock = .{};
    defer mock.unused() catch unreachable;
    const provider = mock.provider();
    const output = try prepare(allocator, document, mode, &provider);
    defer output.close() catch unreachable;
}
test "embedded image budgets and every allocation failure release all leases" {
    const document = try svg.Document.parse(a, "<svg>" ++ picture ++ "</svg>", .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        try std.testing.checkAllAllocationFailures(a, allocationTrial, .{ document, mode });
        var mock: Mock = .{ .invalid = true };
        var provider = mock.provider();
        try std.testing.expectError(error.InvalidImagePremultiplication, prepare(a, document, mode, &provider));
        try mock.unused();
        mock = .{};
        provider = mock.provider();
        provider.limits.pixels = 3;
        try std.testing.expectError(error.ImageCapacityExceeded, prepare(a, document, mode, &provider));
        try mock.unused();
        provider.limits = .{ .bytes = 31 };
        try std.testing.expectError(error.ImageCapacityExceeded, prepare(a, document, mode, &provider));
        try mock.unused();
        provider.limits = .{ .work = key.len };
        try std.testing.expectError(error.ImageWorkExceeded, prepare(a, document, mode, &provider));
        try mock.unused();
    }
}
test "embedded image default record sizes keep common scene payloads unchanged" {
    const scene = @import("scene.zig");
    // The image union payload is a pointer, never the affine or pixel metadata.
    const PreviousBrush = union(enum) { solid: scene.Color, gradient: usize };
    try std.testing.expectEqual(@sizeOf(PreviousBrush), @sizeOf(scene.Brush));
    std.debug.print("svg_image_source_sizes style={d} provider={d} captured_optional={d}\n", .{ @sizeOf(@import("style.zig").Style), @sizeOf(svg.image.Provider), @sizeOf(?svg.image.Provider) });
    std.debug.print("svg_image_sizes options={d} work={d} brush={d} node={d} program={d} prepared={d} cache={d} snapshot={d} paint={d}\n", .{ @sizeOf(svg.PrepareOptions), @sizeOf(@import("prepare.zig").Work), @sizeOf(scene.Brush), @sizeOf(scene.Node), @sizeOf(scene.Program), @sizeOf(svg.Prepared), @sizeOf(@import("prepare_resources.zig").Resources), @sizeOf(@import("image.zig").Snapshot), @sizeOf(@import("image.zig").Paint) });
}

const Probe = struct {
    document: *svg.Document,
    mock: *Mock,
    provider: *svg.image.Provider,
    active: bool = true,
    failure: ?anyerror = null,
    allocations: usize = 0,
    frees: usize = 0,
    resource_checks: usize = 0,
    cancel_free: ?usize = null,
    cancellation: v.Cancellation = .{},
    fn allocator(self: *Probe) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn check(self: *Probe) !void {
        if (!self.active) return;
        try std.testing.expectError(error.Busy, self.document.close());
        try std.testing.expectError(error.Busy, self.document.prepare(a, .{ .main_thread = std.Thread.getCurrentId(), .width = 1, .height = 1 }));
        try std.testing.expectError(error.ResourceInUse, self.mock.lease.ensureUnused());
        if (self.mock.image_lease.pins != 0) {
            try std.testing.expectError(error.ResourceInUse, self.mock.image_lease.ensureUnused());
            self.resource_checks += 1;
        }
        // prepare must use its captured provider, including on the first alloc.
        self.provider.resolve_fn = unavailable;
        self.provider.limits.requests = 0;
    }
    fn unavailable(_: *anyopaque, _: []const u8) !drawing.ImageView {
        return error.ProviderDescriptorWasNotCaptured;
    }
    fn fire(self: *Probe) void {
        self.check() catch |err| {
            self.failure = err;
        };
    }
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.allocations += 1;
        self.fire();
        return a.rawAlloc(length, alignment, ret);
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.frees += 1;
        if (self.cancel_free == self.frees) self.cancellation.request();
        self.fire();
        a.rawFree(bytes, alignment, ret);
    }
};
test "embedded provider capture and foreign final free keep cancellation and leases authoritative" {
    const document = try svg.Document.parse(a, "<svg>" ++ picture ++ "</svg>", .{});
    defer document.close() catch unreachable;
    for ([_]Mode{ .pixel, .sample_color }) |mode| {
        var mock: Mock = .{};
        var provider = mock.provider();
        var baseline: Probe = .{ .document = document, .mock = &mock, .provider = &provider };
        const output = try prepare(baseline.allocator(), document, mode, &provider);
        const frees = baseline.frees;
        baseline.active = false;
        if (baseline.failure) |err| return err;
        try std.testing.expect(baseline.resource_checks > 0);
        const peak = (try output.stats()).peak_bytes;
        try output.close();
        try mock.unused();
        provider = mock.provider();
        var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 16, .height = 12, .compositing = mode, .image_provider = &provider };
        options.limits.bytes = peak - 1;
        try std.testing.expectError(error.CapacityExceeded, document.prepare(a, options));
        try mock.unused();
        options.limits.bytes = 64 * 1024 * 1024;
        for (1..frees + 1) |at| {
            provider = mock.provider();
            var trial: Probe = .{ .document = document, .mock = &mock, .provider = &provider, .cancel_free = at };
            options.cancellation = &trial.cancellation;
            try std.testing.expectError(error.Cancelled, document.prepare(trial.allocator(), options));
            if (trial.failure) |err| return err;
            try mock.unused();
        }
    }
}
