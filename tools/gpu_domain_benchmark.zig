const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const resources = ui.gpu_resources;
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
fn memory() !Memory {
    var result: Memory = .{};
    if (K32GetProcessMemoryInfo(c.GetCurrentProcess(), &result, @sizeOf(Memory)) == 0) return error.MemoryQueryFailed;
    return result;
}
const Counting = struct {
    child: std.mem.Allocator,
    calls: usize = 0,
    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ptr: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        return self.child.rawAlloc(length, alignment, ret);
    }
    fn resize(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, length: usize, ret: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        return self.child.rawResize(bytes, alignment, length, ret);
    }
    fn remap(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, length: usize, ret: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        return self.child.rawRemap(bytes, alignment, length, ret);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ptr));
        self.child.rawFree(bytes, alignment, ret);
    }
};
const Slot = struct {
    window: ?z.Window = null,
    dc: c.HDC = null,
    renderer: ui.d3d11.Renderer = .{},
    commands: ui.commands.Buffer = .{},
    fn close(self: *Slot) void {
        self.commands.reset();
        self.renderer.deinit();
        if (self.window) |window| {
            if (self.dc != null) _ = c.ReleaseDC(window.nativeHandle(), self.dc);
            _ = window.destroy() catch unreachable;
        }
        self.window = null;
        self.dc = null;
    }
    fn submit(self: *Slot) !void {
        const paint: z.Paint = .{ .native_window = self.window.?.nativeHandle(), .native_context = self.dc.?, .size = .{ .width = 320, .height = 180, .scale = 1 } };
        try self.renderer.begin(paint);
        errdefer self.renderer.abort();
        try self.renderer.replayBuffer(&self.commands);
        self.renderer.end() catch |err| if (err != error.PresentationBusy) return err;
    }
};
const Sample = struct {
    trial: usize,
    sequence: usize,
    windows: usize,
    shared: bool,
    setup_ns: u64,
    round_p50_ns: u64,
    round_p95_ns: u64,
    submissions: usize,
    presents: u64,
    busy_presents: u64,
    zig_allocation_attempts_during_rounds: usize,
    renderer_target_creations_during_rounds: u64 = 0,
    renderer_device_creations_during_rounds: u64 = 0,
    domain_device_creations: u64,
    domain_uploads: u64,
    domain_bitmap_creations: u64,
    domain_pixel_bytes: usize,
    domain_total_reservation: usize,
    live_adapter_references: u32,
    before_working_set_bytes: usize,
    warm_working_set_bytes: usize,
    after_working_set_bytes: usize = 0,
    before_private_bytes: usize,
    warm_private_bytes: usize,
    after_private_bytes: usize = 0,
    final_adapter_references: u32 = 0,
};
fn measure(child: std.mem.Allocator, driver: resources.Driver, windows: usize, shared: bool, trial: usize, sequence: usize) !Sample {
    var count: Counting = .{ .child = child };
    const allocator = count.allocator();
    const app = try z.App.init(allocator);
    defer app.deinit();
    const slots = try allocator.alloc(Slot, windows);
    defer allocator.free(slots);
    for (slots) |*slot| slot.* = .{};
    var domains: [8]?*resources.DeviceDomain = @splat(null);
    var textures: [8]?*resources.Texture = @splat(null);
    var cleaned = false;
    defer if (!cleaned) cleanup(slots, &textures, &domains);
    const pixels = try allocator.alloc(u8, 256 * 256 * 4);
    defer allocator.free(pixels);
    for (0..256 * 256) |index| @memcpy(pixels[index * 4 ..][0..4], &[_]u8{ 32, 64, 96, 128 });
    var lease = ui.drawing.Lease.init(std.Thread.getCurrentId());
    const levels = [_]ui.drawing.ImageLevel{.{ .pixels = pixels.ptr, .byte_len = pixels.len, .width = 256, .height = 256, .stride = 1024 }};
    const image: ui.drawing.ImageView = .{ .lease = &lease, .identity = try ui.drawing.reserveRasterIdentity(), .levels = &levels };
    const before = try memory();
    var timer = try zio.Timer.start();
    const domain_count = if (shared) 1 else windows;
    for (0..domain_count) |index| {
        domains[index] = try resources.DeviceDomain.create(app, allocator, .{ .driver = driver, .texture_bytes = pixels.len, .total_bytes = 4 * 1024 * 1024 });
        textures[index] = try domains[index].?.upload(image);
    }
    try lease.ensureUnused();
    for (slots, 0..) |*slot, index| {
        const at = if (shared) 0 else index;
        const window = try app.createWindow(.{ .title = "GPU resource measurement", .width = 320, .height = 180 });
        slot.window = window;
        slot.dc = c.GetDC(window.nativeHandle());
        if (slot.dc == null) return error.NoSurface;
        try slot.renderer.init(.{ .domain = domains[at].? });
        try slot.commands.fill(.{ .x = 0, .y = 0, .width = 320, .height = 180 }, 0x102030);
        for (0..16) |item| {
            try slot.commands.texture(.{ .x = 8 + @as(f32, @floatFromInt(item % 8)) * 38, .y = 8 + @as(f32, @floatFromInt(item / 8)) * 70, .width = 32, .height = 56 }, try textures[at].?.view(), .{ .sampling = .linear });
        }
        try slot.submit();
    }
    const setup_ns = timer.read();
    for (0..8) |_| for (slots) |*slot| try slot.submit();
    var initial_presents: u64 = 0;
    var initial_busy: u64 = 0;
    var bitmaps_before: u64 = 0;
    var targets_before: u64 = 0;
    var devices_before: u64 = 0;
    for (slots) |*slot| {
        const stats = slot.renderer.stats();
        initial_presents += stats.presents;
        initial_busy += stats.busy_presents;
        targets_before += stats.target_creations;
        devices_before += stats.device_creations;
    }
    for (domains[0..domain_count]) |domain| bitmaps_before += (try domain.?.stats()).bitmap_creations;
    const allocations_before = count.calls;
    var rounds: [64]u64 = undefined;
    for (&rounds) |*elapsed| {
        timer.reset();
        for (slots) |*slot| try slot.submit();
        elapsed.* = timer.read();
    }
    const allocations = count.calls - allocations_before;
    std.mem.sort(u64, &rounds, {}, std.sort.asc(u64));
    const warm = try memory();
    var sample: Sample = .{ .trial = trial, .sequence = sequence, .windows = windows, .shared = shared, .setup_ns = setup_ns, .round_p50_ns = rounds[32], .round_p95_ns = rounds[60], .submissions = rounds.len * windows, .presents = 0, .busy_presents = 0, .zig_allocation_attempts_during_rounds = allocations, .domain_device_creations = 0, .domain_uploads = 0, .domain_bitmap_creations = 0, .domain_pixel_bytes = 0, .domain_total_reservation = 0, .live_adapter_references = ui.d3d11.globalResourceCount(), .before_working_set_bytes = before.working_set, .warm_working_set_bytes = warm.working_set, .before_private_bytes = before.private_bytes, .warm_private_bytes = warm.private_bytes };
    for (slots) |*slot| {
        const stats = slot.renderer.stats();
        sample.presents += stats.presents;
        sample.busy_presents += stats.busy_presents;
        sample.renderer_target_creations_during_rounds += stats.target_creations;
        sample.renderer_device_creations_during_rounds += stats.device_creations;
    }
    sample.presents -= initial_presents;
    sample.busy_presents -= initial_busy;
    sample.renderer_target_creations_during_rounds -= targets_before;
    sample.renderer_device_creations_during_rounds -= devices_before;
    for (domains[0..domain_count]) |domain| {
        const stats = try domain.?.stats();
        if (stats.status != .ready or stats.device_losses != 0) return error.UnexpectedDeviceLoss;
        sample.domain_device_creations += stats.device_creations;
        sample.domain_uploads += stats.uploads;
        sample.domain_bitmap_creations += stats.bitmap_creations;
        sample.domain_pixel_bytes += stats.pixel_bytes;
        sample.domain_total_reservation += stats.total_reservation;
    }
    if (allocations != 0 or sample.renderer_target_creations_during_rounds != 0 or sample.renderer_device_creations_during_rounds != 0 or bitmaps_before != sample.domain_bitmap_creations or sample.domain_uploads != domain_count or sample.domain_device_creations != domain_count or sample.presents + sample.busy_presents != sample.submissions) return error.WarmResourceInvariantFailed;
    cleanup(slots, &textures, &domains);
    cleaned = true;
    try app.dispatch();
    const after = try memory();
    sample.after_working_set_bytes = after.working_set;
    sample.after_private_bytes = after.private_bytes;
    sample.final_adapter_references = ui.d3d11.globalResourceCount();
    if (sample.final_adapter_references != 0 or app.resourceStats().allocated_records != 0) return error.ResourceLeak;
    return sample;
}
fn cleanup(slots: []Slot, textures: *[8]?*resources.Texture, domains: *[8]?*resources.DeviceDomain) void {
    for (slots) |*slot| slot.close();
    for (textures) |*texture| if (texture.*) |value| {
        value.close() catch unreachable;
        texture.* = null;
    };
    for (domains) |*domain| if (domain.*) |value| {
        value.close() catch unreachable;
        domain.* = null;
    };
}
pub fn main(init: std.process.Init.Minimal) !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    const args = try zio.argsAlloc(allocator, init.args);
    defer zio.argsFree(allocator, args);
    var driver: resources.Driver = .hardware;
    var repetitions: usize = 3;
    var output: ?[]const u8 = null;
    var at: usize = 1;
    while (at < args.len) : (at += 1) {
        const key = args[at];
        at += 1;
        if (at == args.len) return error.ArgumentValueRequired;
        if (std.mem.eql(u8, key, "--driver")) driver = std.meta.stringToEnum(resources.Driver, args[at]) orelse return error.InvalidDriver else if (std.mem.eql(u8, key, "--repetitions")) {
            repetitions = try std.fmt.parseInt(usize, args[at], 10);
            if (repetitions == 0 or repetitions > 16) return error.InvalidRepetitions;
        } else if (std.mem.eql(u8, key, "--output")) output = args[at] else return error.UnknownArgument;
    }
    var samples: std.ArrayList(Sample) = .empty;
    defer samples.deinit(allocator);
    try samples.ensureTotalCapacityPrecise(allocator, repetitions * 6);
    for (0..repetitions) |trial| for ([_]usize{ 1, 4, 8 }) |windows| for (0..2) |order| {
        samples.appendAssumeCapacity(try measure(allocator, driver, windows, (order + trial) % 2 == 0, trial, samples.items.len));
    };
    const json = try std.json.Stringify.valueAlloc(allocator, .{ .schema = 1, .os = "windows", .arch = @tagName(builtin.cpu.arch), .optimize = @tagName(builtin.mode), .driver = @tagName(driver), .hidden_windows = true, .rounds = 64, .warmup_rounds = 8, .workload = "one fill and sixteen draws of one explicitly uploaded 256x256 premultiplied BGRA texture per 320x180 render target, scale 1", .setup_scope = "Domain creation and upload through first native begin/replay/end in every window; excludes App/source/command-storage construction", .timing_scope = "CPU wall time for a round of begin/replay/end submissions, including busy/occluded Present; no fence, readback, event-loop wait or display-latency measurement", .memory_scope = "whole-process samples; includes driver and OS caches and the benchmark harness; after is before App/source/harness allocator teardown; logical reservations are separate", .allocator_scope = "explicit Zig allocator calls only; native libraries and driver allocations are not intercepted", .ordering = "shared first on even trials, isolated first on odd trials; all trials in one process, so setup is not a clean process/driver cold-start comparison", .samples = samples.items }, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    if (output) |path| try std.Io.Dir.cwd().writeFile(zio.io(), .{ .sub_path = path, .data = json });
    try std.Io.File.stdout().writeStreamingAll(zio.io(), json);
    try std.Io.File.stdout().writeStreamingAll(zio.io(), "\n");
}
