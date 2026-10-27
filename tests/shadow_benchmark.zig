const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const shadows = @import("ziggurat_shadows");
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn cairo_image_surface_create(c_int, c_int, c_int) ?*anyopaque;
extern fn cairo_create(*anyopaque) ?*anyopaque;
extern fn cairo_destroy(*anyopaque) void;
extern fn cairo_surface_destroy(*anyopaque) void;
const samples = 9;
const iterations = 3;
fn median(values: *[samples]u64) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[samples / 2];
}
fn end(renderer: anytype, paint: z.Paint) !bool {
    if (@TypeOf(renderer.*) == ui.SoftwareRenderer) {
        renderer.end(paint);
        return true;
    }
    renderer.end() catch |err| {
        if (err == error.PresentationBusy) return false;
        return err;
    };
    return true;
}
fn replay(name: []const u8, renderer: anytype, paint: z.Paint, prepared: *shadows.PreparedShadow, sigma: f32, prepare_ns: u64) !void {
    const view = try prepared.view();
    var clock = try zio.Timer.start();
    try renderer.uploadCoverage(view);
    const upload_ns = clock.read();
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try buffer.coverage(.{ .x = 64, .y = 64 }, view, .{ .r = 16, .g = 32, .b = 64, .a = 170 });
    var clear: ui.commands.Buffer = .{};
    defer clear.reset();
    try clear.fill(.{ .x = 0, .y = 0, .width = 512, .height = 384 }, 0xe8e8e8);
    try renderer.begin(paint);
    try renderer.replayBuffer(&clear);
    try renderer.replayBuffer(&buffer);
    _ = try end(renderer, paint);
    const before = renderer.coverageStats();
    var replay_samples: [samples]u64 = undefined;
    var submit_samples: [samples]u64 = undefined;
    var accepted: usize = 0;
    for (0..samples) |index| {
        try renderer.begin(paint);
        try renderer.replayBuffer(&clear);
        clock.reset();
        for (0..iterations) |_| try renderer.replayBuffer(&buffer);
        replay_samples[index] = clock.read() / iterations;
        clock.reset();
        accepted += @intFromBool(try end(renderer, paint));
        submit_samples[index] = clock.read();
    }
    const after = renderer.coverageStats();
    if (before.native_creations != after.native_creations or before.native_objects != after.native_objects) return error.NativeObjectsGrew;
    const stats = try prepared.stats();
    std.debug.print("backend={s} sigma_dip={d} scale={d} prepare_median_ns={d} first_upload_ns={d} warm_replay_cpu_ns={d} end_cpu_ns={d} accepted_ends={d}/{d} mask_bytes={d} prepare_peak={d} filter_samples={d} native_objects={d} native_creations={d}\n", .{ name, sigma, paint.size.scale, prepare_ns, upload_ns, median(&replay_samples), median(&submit_samples), accepted, samples, view.pixelBytes(), stats.peak_bytes, stats.filter_samples, after.native_objects, after.native_creations });
    buffer.reset();
    _ = try renderer.releaseCoverage(view.identity);
    try view.lease.ensureUnused();
}
fn run(allocator: std.mem.Allocator, base: z.Paint) !void {
    for ([_]f32{ 1, 2 }) |scale| for ([_]f32{ 0, 4, 12 }) |sigma| {
        const options: shadows.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .scale = scale };
        var times: [samples]u64 = undefined;
        for (&times) |*sample| {
            var clock = try zio.Timer.start();
            const prepared = try shadows.PreparedShadow.create(allocator, .{ .width = 256, .height = 128, .radius = 16 }, .{ .sigma = sigma }, options);
            sample.* = clock.read();
            try prepared.close();
        }
        const prepared = try shadows.PreparedShadow.create(allocator, .{ .width = 256, .height = 128, .radius = 16 }, .{ .sigma = sigma }, options);
        defer prepared.close() catch unreachable;
        var paint = base;
        paint.size = .{ .width = @intFromFloat(512 * scale), .height = @intFromFloat(384 * scale), .scale = scale };
        {
            var renderer: ui.SoftwareRenderer = .{};
            defer renderer.deinit();
            try replay(if (builtin.os.tag == .windows) "gdi" else "cairo", &renderer, paint, prepared, sigma, median(&times));
        }
        if (ui.capabilities.gpu) for ([_]ui.d3d11.Driver{ .hardware, .warp }) |driver| {
            var renderer: ui.d3d11.Renderer = .{};
            try renderer.init(.{ .driver = driver });
            defer renderer.deinit();
            try replay(@tagName(driver), &renderer, paint, prepared, sigma, median(&times));
        };
    };
}
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    std.debug.print("shadow benchmark: page allocator, main-owner prepare (no adopt needed), median9 prepare; first upload; warm replay median9x3. GPU replay is CPU command recording, end is CPU submission; no readback/wait/display timing.\n", .{});
    if (builtin.os.tag == .windows) {
        const app = try z.App.init(allocator);
        defer app.deinit();
        const window = try app.createWindow(.{});
        defer _ = window.destroy() catch unreachable;
        const hwnd = window.nativeHandle();
        const dc = c.GetDC(hwnd) orelse return error.CreateSurfaceFailed;
        defer _ = c.ReleaseDC(hwnd, dc);
        try run(allocator, .{ .native_context = dc, .native_window = hwnd, .size = .{ .width = 512, .height = 384, .scale = 1 } });
        if (ui.capabilities.gpu and ui.d3d11.globalResourceCount() != 0) return error.NativeResourcesLeaked;
    } else {
        const surface = cairo_image_surface_create(0, 1024, 768) orelse return error.CreateSurfaceFailed;
        defer cairo_surface_destroy(surface);
        const context = cairo_create(surface) orelse return error.CreateSurfaceFailed;
        defer cairo_destroy(context);
        try run(allocator, .{ .native_context = context, .size = .{ .width = 512, .height = 384, .scale = 1 } });
    }
}
