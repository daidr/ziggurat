const std = @import("std");
const text = @import("ziggurat_text_layout");
const outlines = @import("ziggurat_text_outlines");
const vector = @import("ziggurat_vector");
extern fn ztc_check(*anyopaque, [*]const u8, u32, [*]const text.outlines.Segment, u32, [*]const text.outlines.Glyph, [*]const text.outlines.SourceRange, u32) c_int;

fn mappingCandidate(allocator: std.mem.Allocator, layout: *text.Layout) !void {
    const snapshot = try layout.outline(allocator, .{ .include_mapping = true, .include_cells = true });
    defer snapshot.close() catch unreachable;
}
fn bridgeCandidate(allocator: std.mem.Allocator, layout: *text.Layout) !void {
    const shape = try outlines.fromLayout(layout, allocator, .{ .include_mapping = true, .include_cells = true });
    defer shape.close() catch unreachable;
}
fn verifyMapping(allocator: std.mem.Allocator) !void {
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const samples = [_][]const u8{ "", "\r\n", "AV office ffi", "السلام", "ABC אבג 123", "क्षि", "e\u{301} 👩‍💻", "A\r\nB\nC", "\u{200b}\u{200d}\u{202e}A\u{202c}", "                                                                      j" };
    for (samples) |source| for ([_]text.Options{ .{ .size = 18 }, .{ .size = 17.37, .wrap = .word_character, .width = 55 }, .{ .size = 36, .direction = .rtl }, .{ .size = 511.5, .italic = true, .weight = 700 } }) |options| {
        const layout = try engine.layout(source, options);
        defer layout.close() catch unreachable;
        const plain = layout.outline(allocator, .{ .include_cells = true }) catch |err| {
            // A bitmap-only color emoji font is traced per pixel; at 511.5 px
            // that is over a million contours, so the bounded default command
            // budget must refuse it. Vector emoji fonts still take the check.
            if (err == error.OutlineCapacityExceeded and options.size > 500 and std.mem.indexOf(u8, source, "\u{1f4bb}") != null) continue;
            return err;
        };
        defer plain.close() catch unreachable;
        try std.testing.expect(try plain.mapping() == null);
        try std.testing.expectEqual(@as(u32, 2), (try plain.metrics()).native_passes);
        const snapshot = layout.outline(allocator, .{ .include_mapping = true, .include_cells = true }) catch |err| {
            std.debug.print("mapping failed source={s} size={d} direction={s}: {s}\n", .{ source, options.size, @tagName(options.direction), @errorName(err) });
            return err;
        };
        defer snapshot.close() catch unreachable;
        const mapping = (try snapshot.mapping()).?;
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(try plain.segments()), std.mem.sliceAsBytes(try snapshot.segments()));
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(try plain.cells()), std.mem.sliceAsBytes(try snapshot.cells()));
        try std.testing.expectEqualStrings(source, mapping.source);
        try std.testing.expectEqual(@as(usize, (try layout.metrics()).glyphs), mapping.glyphs.len);
        const covered = try allocator.alloc(u8, source.len);
        defer allocator.free(covered);
        @memset(covered, 0);
        var glyph_count: usize = 0;
        for (mapping.clusters, 0..) |cluster, index| {
            try std.testing.expect(cluster.source.start < cluster.source.end and cluster.source.end <= source.len);
            try std.testing.expect(std.unicode.utf8ValidateSlice(source[cluster.source.start..cluster.source.end]));
            for (covered[cluster.source.start..cluster.source.end]) |*count| count.* += 1;
            try std.testing.expectEqual(cluster.glyphs.count != 0, cluster.origin != null);
            try std.testing.expectEqual(cluster.glyphs.count != 0, cluster.run != null);
            glyph_count += cluster.glyphs.count;
            for (mapping.glyphs[cluster.glyphs.start..][0..cluster.glyphs.count]) |glyph| {
                try std.testing.expectEqual(@as(u32, @intCast(index)), glyph.cluster);
                try std.testing.expectEqual(cluster.run.?, glyph.run);
                try std.testing.expectEqual(cluster.bidi_level, glyph.bidi_level);
                try std.testing.expect(glyph.cell.height >= 0 and glyph.cell.width >= 0);
            }
        }
        for (covered) |count| try std.testing.expectEqual(1, count);
        try std.testing.expectEqual(mapping.glyphs.len, glyph_count);
        var segment_at: usize = 0;
        for (mapping.glyphs) |glyph| {
            try std.testing.expectEqual(segment_at, glyph.mapped_segments.start);
            segment_at += glyph.mapped_segments.count;
            try std.testing.expect(segment_at <= mapping.mapped_segments.len);
        }
        try std.testing.expectEqual(mapping.mapped_segments.len, segment_at);
        const glyph_sources = try allocator.alloc(text.outlines.SourceRange, mapping.glyphs.len);
        defer allocator.free(glyph_sources);
        for (mapping.glyphs, glyph_sources) |glyph, *range| range.* = mapping.clusters[glyph.cluster].source;
        const prepared = try layout.prepare(1, .{ .viewport = .{ .x = 0, .y = 0, .width = 120, .height = 120 } });
        defer prepared.close() catch unreachable;
        try std.testing.expectEqual(@as(c_int, 0), ztc_check((try prepared.view()).native_layout, source.ptr, @intCast(source.len), mapping.mapped_segments.ptr, @intCast(mapping.mapped_segments.len), mapping.glyphs.ptr, glyph_sources.ptr, @intCast(mapping.glyphs.len)));
        const stats = try snapshot.metrics();
        try std.testing.expectEqual(@as(u32, 4), stats.native_passes);
        try std.testing.expect(stats.peak_owned_bytes >= stats.owned_bytes);
        if (stats.peak_owned_bytes > 1) try std.testing.expectError(error.OutlineCapacityExceeded, layout.outline(allocator, .{ .include_mapping = true, .include_cells = true, .limits = .{ .bytes = stats.peak_owned_bytes - 1 } }));
    };
    const layout = try engine.layout("AV office e\u{301} אבג 👩‍💻\r\nक्षि", .{});
    defer layout.close() catch unreachable;
    try std.testing.checkAllAllocationFailures(allocator, mappingCandidate, .{layout});
    try std.testing.checkAllAllocationFailures(allocator, bridgeCandidate, .{layout});
    try std.testing.expectError(error.OutlineWorkExceeded, layout.outline(allocator, .{ .include_mapping = true, .limits = .{ .work = 1 } }));
    const plain = try layout.outline(allocator, .{});
    defer plain.close() catch unreachable;
    try std.testing.expectError(error.OutlineCapacityExceeded, layout.outline(allocator, .{ .include_mapping = true, .limits = .{ .commands = (try plain.metrics()).commands } }));
    const gaps = try engine.layout("A\nB", .{});
    defer gaps.close() catch unreachable;
    // The newline is owned source metadata, not free uncounted capacity.
    try std.testing.expectError(error.OutlineCapacityExceeded, gaps.outline(allocator, .{ .include_mapping = true, .limits = .{ .clusters = 2 } }));
}

fn ownership(allocator: std.mem.Allocator) !void {
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    const source = "AV office e\u{301} אבג 👩‍💻\r\nक्षि";
    const layout = try engine.layout(source, .{ .size = 24, .width = 170, .wrap = .word_character });
    const shape = try outlines.fromLayout(layout, allocator, .{ .include_mapping = true, .include_cells = true });
    const stats = try shape.stats();
    try std.testing.expect(stats.clusters != 0 and stats.mapped_commands != 0);
    try std.testing.expectError(error.CapacityExceeded, outlines.fromLayout(layout, allocator, .{ .include_mapping = true, .include_cells = true, .limits = .{ .bytes = stats.peak_owned_bytes - 1 } }));
    try std.testing.expectError(error.OutlineWorkExceeded, outlines.fromLayout(layout, allocator, .{ .include_mapping = true, .include_cells = true, .limits = .{ .work = stats.mapping_work - 1 } }));
    const mapping = try shape.takeMapping();
    const after = try shape.stats();
    try std.testing.expectEqual(stats.owned_bytes - try mapping.ownedBytes(), after.owned_bytes);
    try std.testing.expectEqual(@as(usize, 0), after.mapped_commands);
    try std.testing.expectError(error.MappingNotRequested, shape.takeMapping());
    try layout.close();
    try engine.close();
    try std.testing.expectEqualStrings(source, try mapping.source());
    try std.testing.expect((try mapping.glyphs()).len != 0);
    const path = try mapping.path();
    try std.testing.expectEqual(stats.mapped_commands, path.commands.len);
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const coverage = try path.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .viewport = .{ .x = -8, .y = -8, .width = 220, .height = 140 }, .scale = scale });
        defer coverage.close() catch unreachable;
        var nonzero: usize = 0;
        for ((try coverage.view()).coverage.pixels) |pixel| nonzero += @intFromBool(pixel != 0);
        try std.testing.expect(nonzero > 0);
    }
    try shape.close();
    // Mapping owns its path and metadata independently of the batch shell.
    try std.testing.expect((try path.bounds(.{}, null)) != null);
    try mapping.close();
}

const Hook = struct {
    child: std.mem.Allocator,
    layout: *text.Layout,
    engine: *text.Engine,
    cancellation: std.atomic.Value(bool) = .init(false),
    cancel: bool = false,
    enabled: bool = true,
    calls: usize = 0,
    close_at: usize = 0,
    source_closed: bool = false,
    live: usize = 0,
    failure: ?anyerror = null,
    fn allocator(self: *Hook) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn callback(self: *Hook) void {
        if (!self.enabled) return;
        self.probe() catch |err| {
            self.failure = err;
        };
        if (self.cancel) self.cancellation.store(true, .release);
    }
    fn probe(self: *Hook) !void {
        try std.testing.expectError(error.Busy, self.layout.close());
        try std.testing.expectError(error.Busy, self.layout.outline(self.child, .{ .include_mapping = true }));
        try std.testing.expectError(error.Busy, self.layout.prepare(1, .{}));
        try std.testing.expectError(error.LayoutsAlive, self.engine.close());
    }
    fn alloc(context: *anyopaque, n: usize, a: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Hook = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.close_at != 0 and self.close_at == self.calls) {
            self.enabled = false;
            self.closeSource() catch |err| {
                self.failure = err;
            };
        }
        self.callback();
        const value = self.child.rawAlloc(n, a, ret) orelse return null;
        self.live += n;
        return value;
    }
    fn closeSource(self: *Hook) !void {
        try self.layout.close();
        try self.engine.close();
        self.source_closed = true;
    }
    fn free(context: *anyopaque, value: []u8, a: std.mem.Alignment, ret: usize) void {
        const self: *Hook = @ptrCast(@alignCast(context));
        self.callback();
        self.live -= value.len;
        self.child.rawFree(value, a, ret);
    }
};
fn reentry(allocator: std.mem.Allocator) !void {
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const layout = try engine.layout("AV office אבג", .{});
    defer layout.close() catch unreachable;
    var hook: Hook = .{ .child = allocator, .layout = layout, .engine = engine };
    const snapshot = try layout.outline(hook.allocator(), .{ .include_mapping = true });
    if (hook.failure) |err| return err;
    // Its allocator is still stable, but close is independent of the source;
    // only construction/rollback keeps the Layout operation pinned.
    const saved = hook.layout;
    hook.cancel = true;
    try std.testing.expectError(error.Cancelled, layout.outline(hook.allocator(), .{ .include_mapping = true, .cancellation = &hook.cancellation }));
    if (hook.failure) |err| return err;
    hook.cancel = false;
    try std.testing.expect(hook.layout == saved);
    // Disable source probes for independent output destruction.
    hook.enabled = false;
    try snapshot.close();
    try std.testing.expectEqual(@as(usize, 0), hook.live);
}
fn bridgeSourceRelease(allocator: std.mem.Allocator) !void {
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    const layout = try engine.layout("ffi אבג e\u{301}", .{});
    var hook: Hook = .{ .child = allocator, .layout = layout, .engine = engine, .enabled = false };
    const baseline = try layout.outline(hook.allocator(), .{ .include_mapping = true });
    const allocations = hook.calls;
    try baseline.close();
    hook.calls = 0;
    hook.close_at = allocations + 1;
    // The bridge's first conversion allocation follows the complete owning
    // native snapshot. Closing the source here cannot invalidate later work.
    const shape = try outlines.fromLayout(layout, hook.allocator(), .{ .include_mapping = true });
    if (hook.failure) |err| return err;
    try std.testing.expect(hook.source_closed);
    const mapping = try shape.takeMapping();
    try shape.close();
    try std.testing.expectEqualStrings("ffi אבג e\u{301}", try mapping.source());
    try mapping.close();
    try std.testing.expectEqual(@as(usize, 0), hook.live);
}

const CloseHook = struct {
    child: std.mem.Allocator,
    snapshot: ?*text.OutlineSnapshot = null,
    shape: ?*outlines.Shape = null,
    mapping: ?*outlines.Mapping = null,
    failure: ?anyerror = null,
    callbacks: usize = 0,
    fn allocator(self: *CloseHook) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(context: *anyopaque, n: usize, a: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *CloseHook = @ptrCast(@alignCast(context));
        return self.child.rawAlloc(n, a, ret);
    }
    fn free(context: *anyopaque, bytes: []u8, a: std.mem.Alignment, ret: usize) void {
        const self: *CloseHook = @ptrCast(@alignCast(context));
        self.probe() catch |err| {
            self.failure = err;
        };
        self.child.rawFree(bytes, a, ret);
    }
    fn probe(self: *CloseHook) !void {
        if (self.snapshot) |value| {
            self.callbacks += 1;
            try std.testing.expectError(error.Closed, value.close());
        }
        if (self.shape) |value| {
            self.callbacks += 1;
            try std.testing.expectError(error.Closed, value.close());
        }
        if (self.mapping) |value| {
            self.callbacks += 1;
            try std.testing.expectError(error.Closed, value.close());
        }
    }
};
const Worker = struct {
    snapshot: *text.OutlineSnapshot,
    shape: *outlines.Shape,
    mapping: *outlines.Mapping,
    failure: ?anyerror = null,
    fn run(self: *Worker) void {
        self.probe() catch |err| {
            self.failure = err;
        };
    }
    fn probe(self: *Worker) !void {
        try std.testing.expectError(error.WrongThread, self.snapshot.mapping());
        try std.testing.expectError(error.WrongThread, self.snapshot.close());
        try std.testing.expectError(error.WrongThread, self.shape.takeMapping());
        try std.testing.expectError(error.WrongThread, self.mapping.path());
        try std.testing.expectError(error.WrongThread, self.mapping.close());
    }
};
fn closeAndThread(allocator: std.mem.Allocator) !void {
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const layout = try engine.layout("office e\u{301} אבג", .{});
    defer layout.close() catch unreachable;
    var hook: CloseHook = .{ .child = allocator };
    const snapshot = try layout.outline(hook.allocator(), .{ .include_mapping = true });
    const shape = try outlines.fromLayout(layout, hook.allocator(), .{ .include_mapping = true });
    const mapping = try shape.takeMapping();
    var worker: Worker = .{ .snapshot = snapshot, .shape = shape, .mapping = mapping };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();
    if (worker.failure) |err| return err;
    hook.snapshot = snapshot;
    try snapshot.close();
    hook.snapshot = null;
    hook.shape = shape;
    try shape.close();
    hook.shape = null;
    hook.mapping = mapping;
    try mapping.close();
    hook.mapping = null;
    if (hook.failure) |err| return err;
    try std.testing.expect(hook.callbacks > 8);
    // Untaken mappings are disposed by both existing consuming transfers.
    const kept = try outlines.fromLayout(layout, allocator, .{ .include_mapping = true });
    const geometry = try kept.takeGeometry();
    geometry.path.allocator.free(geometry.cells);
    try geometry.path.close();
    const path = try (try outlines.fromLayout(layout, allocator, .{ .include_mapping = true })).takePath();
    try path.close();
}

const CancelOnFree = struct {
    const Allocation = struct { pointer: [*]u8, live: bool = true };
    child: std.mem.Allocator,
    allocations: [128]Allocation = undefined,
    allocated: usize = 0,
    freed: [128]usize = undefined,
    frees: usize = 0,
    target: ?usize = null,
    cancellation: vector.Cancellation = .{},
    fn allocator(self: *CancelOnFree) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(context: *anyopaque, n: usize, a: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *CancelOnFree = @ptrCast(@alignCast(context));
        const bytes = self.child.rawAlloc(n, a, ret) orelse return null;
        std.debug.assert(self.allocated < self.allocations.len);
        self.allocations[self.allocated] = .{ .pointer = bytes };
        self.allocated += 1;
        return bytes;
    }
    fn free(context: *anyopaque, bytes: []u8, a: std.mem.Alignment, ret: usize) void {
        const self: *CancelOnFree = @ptrCast(@alignCast(context));
        for (self.allocations[0..self.allocated], 0..) |*value, id| {
            if (value.live and value.pointer == bytes.ptr) {
                value.live = false;
                self.freed[self.frees] = id;
                self.frees += 1;
                if (self.target) |target| if (target == id) {
                    self.cancellation.request();
                };
                self.child.rawFree(bytes, a, ret);
                return;
            }
        }
        unreachable;
    }
    fn assertEmpty(self: *const CancelOnFree) !void {
        for (self.allocations[0..self.allocated]) |value| try std.testing.expect(!value.live);
    }
};
fn finalScratchCancellation(allocator: std.mem.Allocator) !void {
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const layout = try engine.layout("office e\u{301} אבג", .{});
    defer layout.close() catch unreachable;
    for ([_]bool{ false, true }) |include_mapping| {
        var baseline: CancelOnFree = .{ .child = allocator };
        const shape = try outlines.fromLayout(layout, baseline.allocator(), .{ .include_mapping = include_mapping });
        try std.testing.expect(baseline.frees > 0);
        // Target each exact scratch allocation, including the final native
        // Snapshot and the Mapping conversion array. Output destructors are
        // excluded by capturing this count before close.
        const scratch_frees = baseline.frees;
        try shape.close();
        try baseline.assertEmpty();
        for (baseline.freed[0..scratch_frees]) |target| {
            var trial: CancelOnFree = .{ .child = allocator, .target = target };
            if (outlines.fromLayout(layout, trial.allocator(), .{ .include_mapping = include_mapping, .cancellation = &trial.cancellation })) |unexpected| {
                try unexpected.close();
                return error.CancellationIgnoredAfterScratchFree;
            } else |err| try std.testing.expectEqual(error.Cancelled, err);
            try std.testing.expect(trial.cancellation.requested.load(.acquire));
            try trial.assertEmpty();
        }
    }
}

pub fn main() !void {
    var heap: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(heap.deinit() == .ok);
    try verifyMapping(heap.allocator());
    try ownership(heap.allocator());
    try reentry(heap.allocator());
    try bridgeSourceRelease(heap.allocator());
    try closeAndThread(heap.allocator());
    try finalScratchCancellation(heap.allocator());
    try std.testing.expectEqualDeep(text.ResourceCounts{}, text.resourceCounts());
    std.debug.print("text clusters: original layout mapping, unchanged batch outline, UTF-8 coverage, real glyph positions/segments, bounded candidates/OOM, refs=0\n", .{});
}
