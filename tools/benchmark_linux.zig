const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;
const Allocation = extern struct { x: c_int = 0, y: c_int = 0, width: c_int, height: c_int };
extern fn gtk_widget_size_allocate(*anyopaque, *const Allocation) void;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
extern fn cairo_image_surface_create(c_int, c_int, c_int) ?*anyopaque;
extern fn cairo_surface_status(*anyopaque) c_int;
extern fn cairo_surface_destroy(*anyopaque) void;
extern fn cairo_create(*anyopaque) ?*anyopaque;
extern fn cairo_status(*anyopaque) c_int;
extern fn cairo_scale(*anyopaque, f64, f64) void;
extern fn cairo_destroy(*anyopaque) void;
extern fn cairo_version_string() [*:0]const u8;
extern fn pango_version_string() [*:0]const u8;
extern fn gtk_get_major_version() c_uint;
extern fn gtk_get_minor_version() c_uint;
extern fn gtk_get_micro_version() c_uint;
extern fn gdk_display_get_default() ?*anyopaque;
extern fn g_type_name_from_instance(*anyopaque) [*:0]const u8;
const Timespec = extern struct { seconds: c_long, nanoseconds: c_long };
extern "c" fn clock_gettime(c_int, *Timespec) c_int;

fn cpuTime() !u64 {
    var value: Timespec = undefined;
    if (clock_gettime(2, &value) != 0) return error.ProcessTimeFailed;
    return @as(u64, @intCast(value.seconds)) * std.time.ns_per_s + @as(u64, @intCast(value.nanoseconds));
}
fn memoryBytes(status: []const u8, key: []const u8) !u64 {
    var lines = std.mem.tokenizeScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        var fields = std.mem.tokenizeAny(u8, line[key.len..], " \t");
        return try std.fmt.parseInt(u64, fields.next() orelse return error.InvalidProcStatus, 10) * 1024;
    }
    return error.InvalidProcStatus;
}
fn cpuModel(info: []const u8) []const u8 {
    var lines = std.mem.tokenizeScalar(u8, info, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "model name")) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return "unavailable";
}
const State = struct {
    window: z.Window = undefined,
    idle_timer: zio.Timer = undefined,
    idle_start_cpu: u64 = 0,
    idle_cpu_ns: u64 = 0,
    idle_wall_ns: u64 = 0,
    idle_milliseconds: u32 = 500,
    idle_started: zio.ResetEvent = .{},
    fn draw(_: *anyopaque, frame: *ui.Frame) void {
        frame.clear(0xffffff);
        for (0..256) |index| frame.rect(.{
            .x = 16 + @as(f32, @floatFromInt(index % 32)) * 18,
            .y = 16 + @as(f32, @floatFromInt(index / 32)) * 24,
            .width = 16,
            .height = 20,
        }, @as(u32, @intCast(index)) * 60001 & 0xffffff);
        frame.label(.{ .x = 16, .y = 240, .width = 580, .height = 28 }, "Ziggurat — text / 文本 / Καλημέρα", 0x182430);
        frame.button(1, .{ .x = 24, .y = 400, .width = 160, .height = 40 }, "Input sample") catch unreachable;
    }
    fn action(_: *anyopaque, _: u64) void {}
    fn stop(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.idle_cpu_ns = (cpuTime() catch unreachable) - self.idle_start_cpu;
        self.idle_wall_ns = self.idle_timer.read();
        _ = self.window.destroy() catch unreachable;
    }
    fn startIdle(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.idle_timer = zio.Timer.start() catch unreachable;
        self.idle_start_cpu = cpuTime() catch unreachable;
        self.idle_started.set();
    }
    fn idle(self: *@This()) void {
        zio.sleep(200 * std.time.ns_per_ms);
        self.window.app.post(.{ .context = self, .call = startIdle }) catch return;
        // Only this owned worker waits; the measured UI interval starts first.
        self.idle_started.wait();
        zio.sleep(@as(u64, self.idle_milliseconds) * std.time.ns_per_ms);
        self.window.app.post(.{ .context = self, .call = stop }) catch return;
    }
};
fn paint(area: *anyopaque, context: *anyopaque) void {
    var handled: c_int = 0;
    g_signal_emit_by_name(area, "draw", context, &handled);
}
pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const args = try zio.argsAlloc(allocator, init.args);
    defer zio.argsFree(allocator, args);
    var visible = false;
    var idle_milliseconds: u32 = 500;
    var output_path: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--visible")) visible = true else if (std.mem.eql(u8, args[index], "--output")) {
            index += 1;
            if (index == args.len) return error.OutputPathRequired;
            output_path = args[index];
        } else if (std.mem.eql(u8, args[index], "--idle-ms")) {
            index += 1;
            if (index == args.len) return error.IdleDurationRequired;
            idle_milliseconds = std.fmt.parseInt(u32, args[index], 10) catch return error.InvalidIdleDuration;
            if (idle_milliseconds == 0 or idle_milliseconds > 120000) return error.InvalidIdleDuration;
        } else return error.UnknownArgument;
    }
    var startup = try zio.Timer.start();
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .idle_milliseconds = idle_milliseconds };
    var context = ui.Context.init(&state, State.draw, State.action);
    state.window = try app.createWindow(.{ .title = "Ziggurat benchmark", .width = 640, .height = 480 });
    try context.attach(state.window);
    const widget = state.window.nativeHandle().?;
    const area = gtk_bin_get_child(widget) orelse return error.NativeWidgetMissing;
    gtk_widget_size_allocate(area, &.{ .width = 640, .height = 480 });
    const scale = gtk_widget_get_scale_factor(widget);
    const surface = cairo_image_surface_create(0, 640 * scale, 480 * scale) orelse return error.CreateSurfaceFailed;
    defer cairo_surface_destroy(surface);
    if (cairo_surface_status(surface) != 0) return error.CreateSurfaceFailed;
    const native_context = cairo_create(surface) orelse return error.CreateContextFailed;
    defer cairo_destroy(native_context);
    if (cairo_status(native_context) != 0) return error.CreateContextFailed;
    cairo_scale(native_context, @floatFromInt(scale), @floatFromInt(scale));
    if (visible) state.window.show();
    paint(area, native_context);
    const first_paint_ns = startup.read();
    for (0..16) |_| paint(area, native_context);
    var samples: [200]u64 = undefined;
    for (&samples) |*sample| {
        var timer = try zio.Timer.start();
        paint(area, native_context);
        sample.* = timer.read();
    }
    if (context.frames != 217 or context.gdi_frames != 217) return error.PaintWorkloadIncomplete;
    const workload_frames = context.frames;
    const workload_cairo_frames = context.gdi_frames;
    const status = try std.Io.Dir.cwd().readFileAlloc(zio.io(), "/proc/self/status", allocator, .limited(64 * 1024));
    defer allocator.free(status);
    const resident = try memoryBytes(status, "VmRSS:");
    const data_memory = try memoryBytes(status, "VmData:");
    const virtual_memory = try memoryBytes(status, "VmSize:");
    const cpu_info = try std.Io.Dir.cwd().readFileAlloc(zio.io(), "/proc/cpuinfo", allocator, .limited(1024 * 1024));
    defer allocator.free(cpu_info);
    const kernel = try std.Io.Dir.cwd().readFileAlloc(zio.io(), "/proc/sys/kernel/osrelease", allocator, .limited(4096));
    defer allocator.free(kernel);
    state.idle_timer = try zio.Timer.start();
    state.idle_start_cpu = try cpuTime();
    const worker = try std.Thread.spawn(.{}, State.idle, .{&state});
    defer worker.join();
    try app.run();
    if (state.idle_wall_ns < @as(u64, idle_milliseconds) * std.time.ns_per_ms) return error.IdleMeasurementInterrupted;
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    const executable = try zio.executablePathAlloc(allocator);
    defer allocator.free(executable);
    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .schema = 1,
        .os = "linux",
        .arch = @tagName(builtin.cpu.arch),
        .optimize = @tagName(builtin.mode),
        .kernel = std.mem.trim(u8, kernel, "\r\n"),
        .display_backend = std.mem.span(g_type_name_from_instance(gdk_display_get_default() orelse return error.DisplayUnavailable)),
        .processor = cpuModel(cpu_info),
        .logical_processors = try std.Thread.getCpuCount(),
        .gtk = .{ .major = gtk_get_major_version(), .minor = gtk_get_minor_version(), .micro = gtk_get_micro_version() },
        .cairo = std.mem.span(cairo_version_string()),
        .pango = std.mem.span(pango_version_string()),
        .visible = visible,
        .scale = scale,
        .renderer = "cairo-pango",
        .workload = "256 rectangles, UTF-8 label, button; 200 synchronous GTK draw-signal submissions after 16 warmup paints into one persistent Cairo image destination",
        .first_paint_ns = first_paint_ns,
        .first_paint_scope = "App.init through return from the first synchronous GTK draw signal; excludes process creation and argument parsing",
        .process_start_to_paint_measured = false,
        .paint_submission_p50_ns = samples[100],
        .paint_submission_p95_ns = samples[190],
        .paint_submission_p99_ns = samples[198],
        .workload_paint_submissions = @as(u32, 217),
        .workload_cairo_frames = workload_cairo_frames,
        .workload_draw_callbacks = workload_frames,
        .cairo_frames = context.gdi_frames,
        .draw_callbacks = context.frames,
        .resident_bytes = resident,
        .data_bytes = data_memory,
        .virtual_bytes = virtual_memory,
        .idle_cpu_ns = state.idle_cpu_ns,
        .idle_wall_ns = state.idle_wall_ns,
        .requested_idle_ms = idle_milliseconds,
        .settle_ms = @as(u32, 200),
        .benchmark_executable_bytes = (try std.Io.Dir.cwd().statFile(zio.io(), executable, .{})).size,
        .display_latency_measured = false,
        .input_latency_measured = false,
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    if (output_path) |path| try std.Io.Dir.cwd().writeFile(zio.io(), .{ .sub_path = path, .data = json });
    try std.Io.File.stdout().writeStreamingAll(zio.io(), json);
    try std.Io.File.stdout().writeStreamingAll(zio.io(), "\n");
}
