const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn cairo_image_surface_create(c_int, c_int, c_int) ?*anyopaque;
extern fn cairo_create(*anyopaque) ?*anyopaque;
extern fn cairo_destroy(*anyopaque) void;
extern fn cairo_surface_destroy(*anyopaque) void;
const samples = 9;
const iterations = 3;
const Mode = enum { ordinary, workspace, nested };
fn median(values: *[samples]u64) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[samples / 2];
}
fn finish(renderer: anytype, paint: z.Paint) !bool {
    if (@TypeOf(renderer.*) == ui.SoftwareRenderer) {
        try renderer.endChecked(paint);
        return true;
    }
    renderer.end() catch |err| {
        if (err == error.PresentationBusy) return false;
        return err;
    };
    return true;
}
fn record(buffer: *ui.commands.Buffer, mode: Mode) !void {
    try buffer.fill(.{ .x = 0, .y = 0, .width = 1280, .height = 720 }, 0x204060);
    if (mode == .nested) try buffer.beginGroup(.{ .x = 40, .y = 40, .width = 1160, .height = 620 }, .{ .opacity = 170 });
    try buffer.roundedRect(.{ .x = 80, .y = 80, .width = 720, .height = 480 }, 24, .{ .r = 240, .g = 32, .b = 16, .a = 200 });
    if (mode == .nested) try buffer.beginGroup(.{ .x = 100, .y = 100, .width = 1040, .height = 500 }, .{ .opacity = 128 });
    try buffer.roundedRect(.{ .x = 480, .y = 120, .width = 640, .height = 480 }, 16, .{ .r = 16, .g = 128, .b = 240, .a = 200 });
    try buffer.strokeRect(.{ .x = 400, .y = 300, .width = 320, .height = 240 }, 12, 4, .{ .r = 255, .g = 255, .b = 255, .a = 170 });
    if (mode == .nested) {
        try buffer.endGroup();
        try buffer.endGroup();
    }
    try buffer.finish();
}
fn measure(allocator: std.mem.Allocator, name: []const u8, renderer: anytype, paint: z.Paint, mode: Mode) !void {
    const options: ui.layers.Options = .{ .size = paint.size, .bytes = 128 * 1024 * 1024, .total_bytes = 160 * 1024 * 1024 };
    var prepare_ns: u64 = 0;
    if (mode != .ordinary) {
        var values: [samples]u64 = undefined;
        for (&values) |*value| {
            var timer = try zio.Timer.start();
            try renderer.prepareLayers(allocator, options);
            value.* = timer.read();
            try renderer.releaseLayers();
        }
        prepare_ns = median(&values);
        try renderer.prepareLayers(allocator, options);
    }
    defer renderer.releaseLayers() catch unreachable;
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try record(&buffer, mode);
    try renderer.begin(paint);
    try renderer.replayBuffer(&buffer);
    _ = try finish(renderer, paint);
    const before = renderer.layerStats();
    var replay_values: [samples]u64 = undefined;
    var submit_values: [samples]u64 = undefined;
    var accepted: usize = 0;
    for (0..samples) |index| {
        try renderer.begin(paint);
        var timer = try zio.Timer.start();
        for (0..iterations) |_| try renderer.replayBuffer(&buffer);
        replay_values[index] = timer.read() / iterations;
        timer.reset();
        accepted += @intFromBool(try finish(renderer, paint));
        submit_values[index] = timer.read();
    }
    const after = renderer.layerStats();
    if (before.native_objects != after.native_objects or before.native_creations != after.native_creations) return error.NativeObjectsGrew;
    std.debug.print("backend={s} mode={s} size={d}x{d} scale={d} prepare_median_ns={d} warm_replay_cpu_ns={d} end_cpu_ns={d} accepted_ends={d}/{d} workspace_bytes={d} native_objects={d} native_creations={d} clear_pixels={d} composite_pixels={d}\n", .{ name, @tagName(mode), paint.size.width, paint.size.height, paint.size.scale, prepare_ns, median(&replay_values), median(&submit_values), accepted, samples, after.pixel_bytes, after.native_objects, after.native_creations, after.clear_pixels - before.clear_pixels, after.composite_pixels - before.composite_pixels });
}
fn run(allocator: std.mem.Allocator, base: z.Paint) !void {
    for ([_]f32{ 1, 2 }) |scale| for ([_]Mode{ .ordinary, .workspace, .nested }) |mode| {
        var paint = base;
        paint.size = .{ .width = @intFromFloat(1280 * scale), .height = @intFromFloat(720 * scale), .scale = scale };
        {
            var renderer: ui.SoftwareRenderer = .{};
            defer renderer.deinit();
            try measure(allocator, if (builtin.os.tag == .windows) "gdi" else "cairo", &renderer, paint, mode);
        }
        if (ui.capabilities.gpu) for ([_]ui.d3d11.Driver{ .hardware, .warp }) |driver| {
            var renderer: ui.d3d11.Renderer = .{};
            try renderer.init(.{ .driver = driver });
            defer renderer.deinit();
            try measure(allocator, @tagName(driver), &renderer, paint, mode);
        };
    };
}
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    std.debug.print("layer benchmark: page allocator, prepare median9 (close outside timer); warm replay median9x3; opaque and workspace rows use identical commands, nested adds two opacity groups. Replay/end are CPU recording/submission, without GPU readback/wait/display timing.\n", .{});
    if (builtin.os.tag == .windows) {
        const app = try z.App.init(allocator);
        defer app.deinit();
        const window = try app.createWindow(.{});
        defer _ = window.destroy() catch unreachable;
        const hwnd = window.nativeHandle();
        const dc = c.GetDC(hwnd) orelse return error.CreateSurfaceFailed;
        defer _ = c.ReleaseDC(hwnd, dc);
        try run(allocator, .{ .native_context = dc, .native_window = hwnd, .size = .{ .width = 1280, .height = 720, .scale = 1 } });
        if (ui.capabilities.gpu and ui.d3d11.globalResourceCount() != 0) return error.NativeResourcesLeaked;
    } else {
        const surface = cairo_image_surface_create(0, 2560, 1440) orelse return error.CreateSurfaceFailed;
        defer cairo_surface_destroy(surface);
        const context = cairo_create(surface) orelse return error.CreateSurfaceFailed;
        defer cairo_destroy(context);
        try run(allocator, .{ .native_context = context, .size = .{ .width = 1280, .height = 720, .scale = 1 } });
    }
}
