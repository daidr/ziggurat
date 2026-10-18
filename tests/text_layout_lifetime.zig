const std = @import("std");
const text = @import("ziggurat_text_layout");
const expectError = std.testing.expectError;
const equal = std.testing.expectEqual;
const Hook = struct {
    child: std.mem.Allocator,
    engine: ?*text.Engine = null,
    layout: ?*text.Layout = null,
    prepared: ?*text.Prepared = null,
    phase: enum { off, construct, prepare, layout_close, prepared_close, engine_close } = .off,
    live: usize = 0,
    calls: usize = 0,
    checks: usize = 0,
    failure: ?anyerror = null,
    fn allocator(self: *Hook) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn check(self: *Hook) !void {
        switch (self.phase) {
            .off => return,
            .construct => {
                try expectError(error.Busy, self.engine.?.close());
                try expectError(error.Busy, self.engine.?.layout("nested", .{}));
                try expectError(error.Busy, self.engine.?.layoutAllocated(self.child, "nested", .{}));
            },
            .prepare => {
                try expectError(error.Busy, self.layout.?.close());
                try expectError(error.Busy, self.layout.?.prepare(1, .{}));
                try expectError(error.Busy, self.layout.?.outline(self.child, .{}));
                try expectError(error.LayoutsAlive, self.engine.?.close());
            },
            .layout_close => {
                try expectError(error.Closed, self.layout.?.close());
                try expectError(error.Closed, self.layout.?.text());
                try expectError(error.Closed, self.layout.?.prepare(1, .{}));
                try expectError(error.LayoutsAlive, self.engine.?.close());
            },
            .prepared_close => {
                try expectError(error.Closed, self.prepared.?.close());
                try expectError(error.Closed, self.prepared.?.view());
                try expectError(error.Closed, self.prepared.?.ensureUnused());
                try expectError(error.Busy, self.layout.?.close());
                try expectError(error.LayoutsAlive, self.engine.?.close());
            },
            .engine_close => {
                try expectError(error.Closed, self.engine.?.close());
                try expectError(error.Closed, self.engine.?.layout("nested", .{}));
                try expectError(error.Closed, self.engine.?.lastNativeError());
            },
        }
        self.checks += 1;
    }
    fn fire(self: *Hook) void {
        self.check() catch |err| {
            self.failure = err;
        };
    }
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Hook = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.fire();
        const bytes = self.child.rawAlloc(length, alignment, ret) orelse return null;
        self.live += length;
        return bytes;
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Hook = @ptrCast(@alignCast(context));
        self.fire();
        self.live -= bytes.len;
        self.child.rawFree(bytes, alignment, ret);
    }
    fn verify(self: *Hook) !void {
        if (self.failure) |err| return err;
        try std.testing.expect(self.checks > 0);
    }
};
fn allocationPass(allocator: std.mem.Allocator, engine: *text.Engine) !void {
    const layout = try engine.layoutAllocated(allocator, "A \u{5d0}\u{5d1} office", .{ .size = 19.1 });
    defer layout.close() catch unreachable;
    const prepared = try layout.prepare(1.5, .{});
    defer prepared.close() catch unreachable;
    _ = try prepared.view();
}
pub fn run(allocator: std.mem.Allocator) !void {
    var engine_memory: Hook = .{ .child = allocator };
    const engine = try text.Engine.create(engine_memory.allocator(), std.Thread.getCurrentId(), .{});
    engine_memory.engine = engine;
    var memory: Hook = .{ .child = allocator, .engine = engine, .phase = .construct };
    const engine_calls = engine_memory.calls;
    const layout = try engine.layoutAllocated(memory.allocator(), "Office A O \u{5d0}\u{5d1}", .{ .size = 24 });
    memory.layout = layout;
    try memory.verify();
    // The reusable Engine allocator receives no layout/snapshot storage.
    try equal(engine_calls, engine_memory.calls);
    memory.phase = .prepare;
    const prepared = try layout.prepare(1.5, .{});
    memory.prepared = prepared;
    try memory.verify();
    try equal(engine_calls, engine_memory.calls);
    memory.phase = .prepared_close;
    try prepared.close();
    try memory.verify();
    memory.phase = .layout_close;
    try layout.close();
    try memory.verify();
    try equal(@as(usize, 0), memory.live);
    try std.testing.checkAllAllocationFailures(allocator, allocationPass, .{engine});
    engine_memory.phase = .engine_close;
    try engine.close();
    try engine_memory.verify();
    try equal(@as(usize, 0), engine_memory.live);
}
