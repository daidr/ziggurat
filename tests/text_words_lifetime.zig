const std = @import("std");
const t = @import("ziggurat_text_layout");
const Memory = struct {
    child: std.mem.Allocator,
    engine: *t.Engine,
    old: ?*t.Layout = null,
    current: ?*t.Layout = null,
    phase: enum { construct, prepare, closing, off } = .construct,
    failure: ?anyerror = null,
    live: usize = 0,
    calls: usize = 0,
    checks: usize = 0,
    deny: bool = false,
    rewrite: ?[]u8 = null,
    locale: ?[]u8 = null,
    trigger: usize = 0,
    fn allocator(self: *Memory) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn check(self: *Memory) !void {
        switch (self.phase) {
            .construct => {
                try std.testing.expectError(error.Busy, self.engine.close());
                try std.testing.expectError(error.Busy, self.engine.layout("nested", .{ .word_ranges = true }));
                if (self.old) |old| _ = try old.wordRangeAt(.{ .byte_offset = 0 });
            },
            .prepare => {
                try std.testing.expectError(error.Busy, self.current.?.close());
                try std.testing.expectError(error.Busy, self.current.?.prepare(1, .{}));
                _ = try self.current.?.wordRangeAt(.{ .byte_offset = 0 });
                try std.testing.expectError(error.LayoutsAlive, self.engine.close());
            },
            .closing => {
                try std.testing.expectError(error.Closed, self.current.?.wordRangeAt(.{ .byte_offset = 0 }));
                try std.testing.expectError(error.Closed, self.current.?.close());
                try std.testing.expectError(error.LayoutsAlive, self.engine.close());
            },
            .off => return,
        }
        self.checks += 1;
    }
    fn fire(self: *Memory) void {
        self.check() catch |err| {
            self.failure = err;
        };
    }
    fn alloc(ptr: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Memory = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        if (self.deny) return null;
        self.fire();
        const result = self.child.rawAlloc(length, alignment, ret) orelse return null;
        self.live += length;
        if (self.calls == self.trigger) {
            if (self.rewrite) |bytes| @memcpy(bytes, "xyz");
            if (self.locale) |bytes| @memcpy(bytes, "zz");
        }
        return result;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Memory = @ptrCast(@alignCast(ptr));
        self.fire();
        self.live -= bytes.len;
        self.child.rawFree(bytes, alignment, ret);
    }
    fn verify(self: *Memory) !void {
        if (self.failure) |err| return err;
        try std.testing.expect(self.checks != 0);
    }
};
fn allocationPass(allocator: std.mem.Allocator, engine: *t.Engine) !void {
    const layout = try engine.layoutAllocated(allocator, "alpha 😀 beta\r\n", .{ .word_ranges = true, .locale = "" });
    defer layout.close() catch unreachable;
    _ = try layout.wordRangeAt(.{ .byte_offset = 0 });
    const prepared = try layout.prepare(1.25, .{ .viewport = .{ .x = 0, .y = 0, .width = 96, .height = 40 } });
    defer prepared.close() catch unreachable;
    _ = try prepared.view();
}
fn byteBudgets(allocator: std.mem.Allocator) !void {
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    const sample = try engine.layout("alpha  beta", .{ .word_ranges = true });
    const peak = (try sample.buildStats()).peak_owned_bytes;
    try sample.close();
    try engine.close();
    const exact = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{ .layout_bytes = peak });
    const accepted = try exact.layout("alpha  beta", .{ .word_ranges = true });
    try accepted.close();
    try exact.close();
    const short = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{ .layout_bytes = peak - 1 });
    defer short.close() catch unreachable;
    try std.testing.expectError(error.LayoutByteCapacityExceeded, short.layout("alpha  beta", .{ .word_ranges = true }));
}
pub fn run(allocator: std.mem.Allocator) !void {
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    const old = try engine.layout("old words", .{ .word_ranges = true });
    var memory: Memory = .{ .child = allocator, .engine = engine, .old = old };
    const layout = try engine.layoutAllocated(memory.allocator(), "new 😀 words", .{ .word_ranges = true });
    memory.current = layout;
    try memory.verify();
    const calls = memory.calls;
    memory.deny = true;
    for (0..128) |_| _ = try layout.wordRangeAt(.{ .byte_offset = 0 });
    try std.testing.expectEqual(calls, memory.calls);
    memory.deny = false;
    memory.phase = .prepare;
    const prepared = try layout.prepare(1.25, .{});
    const second = try layout.prepare(1, .{});
    const view = try prepared.view();
    try view.lease.acquire();
    try std.testing.expectError(error.ResourceInUse, prepared.close());
    try std.testing.expectError(error.PreparedAlive, layout.close());
    view.lease.release();
    // Prepared.close pins the parent operation gate across foreign free.
    try prepared.close();
    try std.testing.expectError(error.PreparedAlive, layout.close());
    try second.close();
    memory.phase = .closing;
    try layout.close();
    try memory.verify();
    try std.testing.expectEqual(@as(usize, 0), memory.live);
    const resources = t.resourceCounts();
    try std.testing.checkAllAllocationFailures(allocator, allocationPass, .{engine});
    try std.testing.expectEqualDeep(resources, t.resourceCounts());
    try std.testing.expectEqualDeep(@as(t.ByteRange, .{ .start = 0, .end = 3 }), try old.wordRangeAt(.{ .byte_offset = 0 }));
    try old.close();
    for ([_]usize{ 1, 2, 3, 4 }) |trigger| {
        var text = [_]u8{ 'a', ' ', 'b' };
        var locale = [_]u8{ 'e', 'n' };
        var hook: Memory = .{ .child = allocator, .engine = engine, .rewrite = &text, .locale = &locale, .trigger = trigger };
        const captured = try engine.layoutAllocated(hook.allocator(), &text, .{ .word_ranges = true, .locale = &locale });
        const wanted: []const u8 = if (trigger <= 2) "xyz" else "a b";
        try std.testing.expectEqualStrings(wanted, try captured.text());
        try std.testing.expectEqualStrings("en", (try captured.options()).locale);
        try std.testing.expectEqualDeep(@as(t.ByteRange, .{ .start = 0, .end = if (trigger <= 2) 3 else 1 }), try captured.wordRangeAt(.{ .byte_offset = 0 }));
        hook.phase = .closing;
        hook.current = captured;
        try captured.close();
        try hook.verify();
        try std.testing.expectEqual(@as(usize, 0), hook.live);
    }
    try engine.close();
    try byteBudgets(allocator);
    try std.testing.expectEqualDeep(@as(t.ResourceCounts, .{}), t.resourceCounts());
    std.debug.print("word lifetime passed: allocator Busy/Closed, old/new owners, pure denied-allocation queries, lease+PreparedAlive, all OOM, source/locale capture and exact/short peak budget\n", .{});
}
