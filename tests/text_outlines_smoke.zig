const std = @import("std");
const text = @import("ziggurat_text_layout");
const outlines = @import("ziggurat_text_outlines");
const vector = @import("ziggurat_vector");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;

fn geometry(allocator: std.mem.Allocator) !void {
    for ([_][]const u8{ "Office A g O", "\u{627}\u{644}\u{639}\u{631}\u{628}\u{64a}\u{629}", "ABC \u{5d0}\u{5d1}\u{5d2} 123", "\u{915}\u{94d}\u{937}\u{93f}", "a\u{301} \u{1f600}", " \t  " }) |source| {
        const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
        const layout = try engine.layout(source, .{ .size = 24, .width = 220, .wrap = .word_character });
        const metrics = try layout.metrics();
        const snapshot = try layout.outline(allocator, .{});
        const copy = try layout.outline(allocator, .{});
        try std.testing.expectEqualSlices(text.outlines.Segment, try snapshot.segments(), try copy.segments());
        try equal(metrics.glyphs, (try snapshot.metrics()).glyphs);
        try equal((try layout.lines())[0].baseline, (try snapshot.metrics()).first_baseline);
        const shape = try outlines.fromLayout(layout, allocator, .{});
        const stats = try shape.stats();
        try equal((try snapshot.segments()).len, stats.commands);
        try expect(stats.peak_owned_bytes >= stats.owned_bytes);
        try copy.close();
        try snapshot.close();
        try layout.close();
        try engine.close();
        // Both source objects are already gone. Curves and counters are owned
        // by the path and can be prepared at any explicit target scale.
        const path = try shape.path();
        const bounds = try path.bounds(.{}, null);
        if (std.mem.eql(u8, source, " \t  ")) {
            try expect(bounds == null);
        } else {
            const box = bounds orelse return error.EmptyOutline;
            try expect(box.width > 0 and box.height > 0);
            for ([_]f32{ 1, 1.5, 2 }) |scale| {
                const prepared = try path.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .viewport = .{ .x = -4, .y = -4, .width = 240, .height = 100 }, .scale = scale });
                var visible: usize = 0;
                for ((try prepared.view()).coverage.pixels) |coverage| visible += @intFromBool(coverage != 0);
                try expect(visible > 0);
                try prepared.close();
            }
        }
        try shape.close();
    }
}
fn allocationPass(allocator: std.mem.Allocator, layout: *text.Layout) !void {
    const shape = try outlines.fromLayout(layout, allocator, .{});
    defer shape.close() catch unreachable;
    _ = try shape.path();
}
const Hook = struct {
    child: std.mem.Allocator,
    engine: ?*text.Engine,
    layout: ?*text.Layout,
    action: enum { lock, close_source, cancel, none } = .lock,
    at: usize = 0,
    calls: usize = 0,
    fail_at: usize = 0,
    live: usize = 0,
    failure: ?anyerror = null,
    cancellation: ?*vector.Cancellation = null,
    fn allocator(self: *Hook) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn run(self: *Hook) !void {
        switch (self.action) {
            .lock, .cancel => {
                try expectError(error.Busy, self.layout.?.close());
                try expectError(error.Busy, self.layout.?.outline(self.child, .{}));
                try expectError(error.Busy, self.layout.?.prepare(1, .{}));
                try expectError(error.LayoutsAlive, self.engine.?.close());
                _ = try self.layout.?.metrics();
                if (self.action == .cancel) self.cancellation.?.request();
            },
            .close_source => {
                try self.layout.?.close();
                self.layout = null;
                try self.engine.?.close();
                self.engine = null;
                self.action = .none;
            },
            .none => {},
        }
    }
    fn fire(self: *Hook) void {
        self.run() catch |err| {
            self.failure = err;
        };
    }
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Hook = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.at == 0 or self.at == self.calls) self.fire();
        if (self.calls == self.fail_at) return null;
        const bytes = self.child.rawAlloc(length, alignment, ret) orelse return null;
        self.live += length;
        return bytes;
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Hook = @ptrCast(@alignCast(context));
        if (self.action == .lock or self.action == .cancel) self.fire();
        self.live -= bytes.len;
        self.child.rawFree(bytes, alignment, ret);
    }
    fn check(self: *Hook) !void {
        if (self.failure) |err| return err;
    }
};
fn reentry(allocator: std.mem.Allocator) !void {
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    const layout = try engine.layout("Office", .{ .size = 24 });
    var hook: Hook = .{ .child = allocator, .engine = engine, .layout = layout };
    const snapshot = try layout.outline(hook.allocator(), .{});
    try hook.check();
    hook.action = .none;
    try snapshot.close();
    try equal(@as(usize, 0), hook.live);
    hook.action = .lock;
    hook.calls = 0;
    hook.fail_at = 2;
    try expectError(error.OutOfMemory, layout.outline(hook.allocator(), .{}));
    try hook.check();
    try equal(@as(usize, 0), hook.live);
    var cancellation: vector.Cancellation = .{};
    hook.action = .cancel;
    hook.calls = 0;
    hook.fail_at = 0;
    hook.cancellation = &cancellation;
    try expectError(error.Cancelled, layout.outline(hook.allocator(), .{ .cancellation = &cancellation.requested }));
    try hook.check();
    try equal(@as(usize, 0), hook.live);
    // The third allocation starts conversion of an already independent native
    // snapshot. No subsequent bridge step may access its old layout/engine.
    hook.action = .close_source;
    hook.calls = 0;
    hook.at = 3;
    const shape = try outlines.fromLayout(layout, hook.allocator(), .{});
    try hook.check();
    try expect(hook.layout == null and hook.engine == null);
    try expect((try (try shape.path()).bounds(.{}, null)) != null);
    try shape.close();
    try equal(@as(usize, 0), hook.live);
}
const Worker = struct {
    layout: *text.Layout,
    shape: *outlines.Shape,
    allocator: std.mem.Allocator,
    fn run(self: *Worker) !void {
        try expectError(error.WrongThread, self.layout.outline(self.allocator, .{}));
        try expectError(error.WrongThread, outlines.fromLayout(self.layout, self.allocator, .{}));
        try expectError(error.WrongThread, self.shape.path());
        try expectError(error.WrongThread, self.shape.close());
    }
};
fn contours(allocator: std.mem.Allocator) !void {
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const layout = try engine.layout("O\nO", .{ .family = "sans-serif", .size = 64 });
    defer layout.close() catch unreachable;
    const shape = try outlines.fromLayout(layout, allocator, .{});
    defer shape.close() catch unreachable;
    const path = try shape.path();
    const stats = try shape.stats();
    try expectError(error.CapacityExceeded, outlines.fromLayout(layout, allocator, .{ .limits = .{ .bytes = stats.peak_owned_bytes - 1 } }));
    const lines = try layout.lines();
    try equal(@as(usize, 2), lines.len);
    const bounds = (try path.bounds(.{}, null)).?;
    try expect(bounds.y < lines[0].baseline and bounds.y + bounds.height > lines[1].baseline - 10);
    const first_height = bounds.height - @as(f64, lines[1].baseline - lines[0].baseline);
    const center: vector.Point = .{ .x = bounds.x + bounds.width / 2, .y = bounds.y + first_height / 2 };
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const prepared = try path.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .viewport = .{ .width = 100, .height = 180 }, .scale = scale });
        defer prepared.close() catch unreachable;
        const coverage = (try prepared.view()).coverage;
        const x: usize = @intFromFloat(center.x * scale);
        const y: usize = @intFromFloat(center.y * scale);
        try equal(@as(u8, 0), coverage.pixels[y * coverage.stride + x]);
        var upper: usize = 0;
        for (0..y) |row| upper += @intFromBool(coverage.pixels[row * coverage.stride + x] != 0);
        try expect(upper > 0);
    }
    var worker: Worker = .{ .layout = layout, .shape = shape, .allocator = allocator };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();
}
pub fn main() !void {
    var heap: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(heap.deinit() == .ok);
    const allocator = heap.allocator();
    try geometry(allocator);
    try reentry(allocator);
    try contours(allocator);
    try @import("text_layout_lifetime.zig").run(allocator);
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    const layout = try engine.layout("Office A g O", .{ .size = 24 });
    try expectError(error.OutlineGlyphsExceeded, layout.outline(allocator, .{ .limits = .{ .glyphs = 1 } }));
    try expectError(error.OutlineCapacityExceeded, layout.outline(allocator, .{ .limits = .{ .commands = 1 } }));
    try expectError(error.OutlineCapacityExceeded, layout.outline(allocator, .{ .limits = .{ .bytes = 1 } }));
    var cancel: vector.Cancellation = .{};
    cancel.request();
    try expectError(error.Cancelled, outlines.fromLayout(layout, allocator, .{ .cancellation = &cancel }));
    try std.testing.checkAllAllocationFailures(allocator, allocationPass, .{layout});
    try layout.close();
    try engine.close();
    const counts = text.resourceCounts();
    try equal(@as(u32, 0), counts.engines);
    try equal(@as(u32, 0), counts.layouts);
    try equal(@as(u32, 0), counts.references);
    try equal(@as(u32, 0), counts.modules);
    std.debug.print("text outlines: original system runs, independent path, complex/bidi/fallback text, 3 DPI, limits/OOM/cancel and refs=0 passed\n", .{});
}
