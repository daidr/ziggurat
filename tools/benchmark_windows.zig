const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const c = @import("ziggurat_c_win32");
const Memory = extern struct {
    cb: u32 = @sizeOf(Memory),
    faults: u32 = 0,
    peak_working_set: usize = 0,
    working_set: usize = 0,
    peak_paged_pool: usize = 0,
    paged_pool: usize = 0,
    peak_nonpaged_pool: usize = 0,
    nonpaged_pool: usize = 0,
    pagefile: usize = 0,
    peak_pagefile: usize = 0,
    private_bytes: usize = 0,
};
extern "kernel32" fn K32GetProcessMemoryInfo(?*anyopaque, *Memory, u32) callconv(.winapi) c_int;
fn fileTime(value: c.FILETIME) u64 {
    return (@as(u64, value.dwHighDateTime) << 32) | value.dwLowDateTime;
}
fn cpuTime() !u64 {
    var creation: c.FILETIME = undefined;
    var exit: c.FILETIME = undefined;
    var kernel: c.FILETIME = undefined;
    var user: c.FILETIME = undefined;
    if (c.GetProcessTimes(c.GetCurrentProcess(), &creation, &exit, &kernel, &user) == 0) return error.ProcessTimeFailed;
    return (fileTime(kernel) + fileTime(user)) * 100;
}
fn sinceProcessStart() !u64 {
    var creation: c.FILETIME = undefined;
    var exit: c.FILETIME = undefined;
    var kernel: c.FILETIME = undefined;
    var user: c.FILETIME = undefined;
    if (c.GetProcessTimes(c.GetCurrentProcess(), &creation, &exit, &kernel, &user) == 0) return error.ProcessTimeFailed;
    var now: c.FILETIME = undefined;
    c.GetSystemTimePreciseAsFileTime(&now);
    const start = fileTime(creation);
    const end = fileTime(now);
    if (end < start) return error.SystemClockMovedBackwards;
    return std.math.mul(u64, end - start, 100) catch error.ProcessTimeOverflow;
}
const State = struct {
    window: z.Window = undefined,
    context: *ui.Context = undefined,
    actions: usize = 0,
    scale: f32 = 1,
    idle_timer: zio.Timer = undefined,
    idle_start_cpu: u64 = 0,
    idle_cpu_ns: u64 = 0,
    idle_wall_ns: u64 = 0,
    idle_milliseconds: u32 = 500,
    idle_started: zio.ResetEvent = .{},
    final_busy_presents: u32 = 0,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.scale = frame.size.scale;
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
    fn action(ptr: *anyopaque, _: u64) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.actions += 1;
    }
    fn stop(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.idle_cpu_ns = (cpuTime() catch unreachable) - self.idle_start_cpu;
        self.idle_wall_ns = self.idle_timer.read();
        if (ui.capabilities.gpu) self.final_busy_presents = self.context.gpu_renderer.stats().busy_presents;
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
pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const args = try zio.argsAlloc(allocator, init.args);
    defer zio.argsFree(allocator, args);
    var visible = false;
    var software_only = false;
    var warp = false;
    var idle_milliseconds: u32 = 500;
    var output_path: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--visible")) visible = true else if (std.mem.eql(u8, args[index], "--software")) software_only = true else if (std.mem.eql(u8, args[index], "--warp")) warp = true else if (std.mem.eql(u8, args[index], "--output")) {
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
    state.context = &context;
    context.render_mode = if (software_only) .gdi else if (warp) .warp else .automatic;
    state.window = try app.createWindow(.{ .title = "Ziggurat benchmark", .width = 640, .height = 480 });
    try context.attach(state.window);
    const hwnd = state.window.nativeHandle();
    if (visible) state.window.show();
    _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    const first_paint_ns = startup.read();
    const first_paint_since_process_start_ns = try sinceProcessStart();
    for (0..16) |_| _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    var samples: [200]u64 = undefined;
    for (&samples) |*sample| {
        var frame_time = try zio.Timer.start();
        _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
        sample.* = frame_time.read();
    }
    const x: isize = @intFromFloat(32 * state.scale);
    const y: isize = @intFromFloat(410 * state.scale);
    var input_timer = try zio.Timer.start();
    for (0..100) |_| {
        _ = c.SendMessageW(hwnd, c.WM_LBUTTONDOWN, 0, (y << 16) | x);
        _ = c.SendMessageW(hwnd, c.WM_LBUTTONUP, 0, (y << 16) | x);
    }
    const input_total_ns = input_timer.read();
    try std.testing.expectEqual(100, state.actions);
    var memory: Memory = .{};
    if (K32GetProcessMemoryInfo(c.GetCurrentProcess(), &memory, @sizeOf(Memory)) == 0) return error.ProcessMemoryFailed;
    const gpu_stats = if (ui.capabilities.gpu) context.gpu_renderer.stats() else ui.d3d11.Stats{};
    const gpu_frames = context.gpu_frames;
    const gdi_frames = context.gdi_frames;
    const fallbacks = context.fallbacks;
    const deferred_frames = context.deferred_frames;
    const draw_callbacks = context.frames;
    state.idle_timer = try zio.Timer.start();
    state.idle_start_cpu = try cpuTime();
    const worker = try std.Thread.spawn(.{}, State.idle, .{&state});
    defer worker.join();
    try app.run();
    if (state.idle_wall_ns < @as(u64, idle_milliseconds) * std.time.ns_per_ms) return error.IdleMeasurementInterrupted;
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    const executable = try zio.executablePathAlloc(allocator);
    defer allocator.free(executable);
    const executable_size = (try std.Io.Dir.cwd().statFile(zio.io(), executable, .{})).size;
    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .schema = 1,
        .os = "windows",
        .arch = @tagName(builtin.cpu.arch),
        .optimize = @tagName(builtin.mode),
        .visible = visible,
        .requested_renderer = if (software_only) "gdi" else if (warp) "warp" else "automatic",
        .workload = "256 rectangles, UTF-8 label, button; 200 synchronous paint submissions after 16 warmup paints",
        .first_paint_ns = first_paint_ns,
        .first_paint_scope = "App.init through return from the first synchronous WM_PAINT; excludes process creation and argument parsing",
        .first_paint_since_process_start_ns = first_paint_since_process_start_ns,
        .process_start_to_paint_measured = true,
        .process_start_clock = "GetProcessTimes creation FILETIME to GetSystemTimePreciseAsFileTime immediately after first paint; system clock, not display latency",
        .paint_submission_p50_ns = samples[100],
        .paint_submission_p95_ns = samples[190],
        .paint_submission_p99_ns = samples[198],
        .input_100_actions_ns = input_total_ns,
        .workload_paint_submissions = @as(u32, 217),
        .workload_gpu_frames = gpu_frames,
        .workload_gdi_frames = gdi_frames,
        .workload_fallbacks = fallbacks,
        .workload_deferred_frames = deferred_frames,
        .workload_draw_callbacks = draw_callbacks,
        .workload_busy_presents = gpu_stats.busy_presents,
        .gpu_frames = context.gpu_frames,
        .gdi_frames = context.gdi_frames,
        .fallbacks = context.fallbacks,
        .deferred_frames = context.deferred_frames,
        .draw_callbacks = context.frames,
        .busy_presents = state.final_busy_presents,
        .working_set_bytes = memory.working_set,
        .private_bytes = memory.private_bytes,
        .idle_cpu_ns = state.idle_cpu_ns,
        .idle_wall_ns = state.idle_wall_ns,
        .requested_idle_ms = idle_milliseconds,
        .settle_ms = @as(u32, 200),
        .benchmark_executable_bytes = executable_size,
        .display_latency_measured = false,
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    if (output_path) |path| try std.Io.Dir.cwd().writeFile(zio.io(), .{ .sub_path = path, .data = json });
    try std.Io.File.stdout().writeStreamingAll(zio.io(), json);
    try std.Io.File.stdout().writeStreamingAll(zio.io(), "\n");
}
