const std = @import("std");
const zio = @import("ziggurat_io");
const images = @import("ziggurat_images");
const prepared = @import("ziggurat_image_drawing");
const fixture = @embedFile("image_fixture/colors.png");

// Delay physical frees so a broken recursive destructor produces a precise
// ownership failure instead of relying on a heap-use-after-free crash.
const Retained = struct {
    child: std.mem.Allocator,
    blocks: [8]struct { bytes: []u8, alignment: std.mem.Alignment } = undefined,
    count: usize = 0,
    source: ?*images.Image = null,
    resource: ?*prepared.PreparedImage = null,
    mode: enum { off, prepare, source_close, prepared_close } = .off,
    nested: bool = false,
    allowed: usize = 0,
    blocked: usize = 0,
    unexpected: ?anyerror = null,

    fn allocator(self: *Retained) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn deinit(self: *Retained) void {
        while (self.count != 0) {
            self.count -= 1;
            const block = self.blocks[self.count];
            self.child.rawFree(block.bytes, block.alignment, @returnAddress());
        }
    }
    fn probe(self: *Retained, expected: anyerror) void {
        if (self.nested) return;
        self.nested = true;
        defer self.nested = false;
        const result = if (self.mode == .prepared_close) self.resource.?.close() else self.source.?.close();
        if (result) |_| {
            self.allowed += 1;
        } else |err| {
            if (err == expected) self.blocked += 1 else self.unexpected = err;
        }
    }
    fn alloc(ptr: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Retained = @ptrCast(@alignCast(ptr));
        if (self.mode == .prepare) self.probe(error.ResourceInUse);
        std.debug.assert(self.count < self.blocks.len);
        const bytes = self.child.rawAlloc(length, alignment, ret) orelse return null;
        self.blocks[self.count] = .{ .bytes = bytes[0..length], .alignment = alignment };
        self.count += 1;
        return bytes;
    }
    fn free(ptr: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {
        const self: *Retained = @ptrCast(@alignCast(ptr));
        if (self.mode == .source_close or self.mode == .prepared_close) self.probe(error.Closed);
    }
    fn verify(self: *Retained) !void {
        if (self.unexpected) |err| return err;
        try std.testing.expectEqual(@as(usize, 0), self.allowed);
        try std.testing.expect(self.blocked >= 2);
    }
};

pub fn run(allocator: std.mem.Allocator, worker: *images.Worker) !void {
    {
        var memory: Retained = .{ .child = allocator };
        defer memory.deinit();
        const source = try worker.decode(memory.allocator(), fixture, .{});
        memory.source = source;
        memory.mode = .prepare;
        const output = try prepared.PreparedImage.create(memory.allocator(), source, .{});
        memory.mode = .off;
        try output.close();
        try source.close();
        try memory.verify();
    }
    {
        var memory: Retained = .{ .child = allocator };
        defer memory.deinit();
        const source = try worker.decode(memory.allocator(), fixture, .{});
        memory.source = source;
        memory.mode = .source_close;
        try source.close();
        memory.mode = .off;
        try memory.verify();
    }
    {
        var memory: Retained = .{ .child = allocator };
        defer memory.deinit();
        const source = try worker.decode(memory.allocator(), fixture, .{});
        const output = try prepared.PreparedImage.create(memory.allocator(), source, .{});
        memory.resource = output;
        memory.mode = .prepared_close;
        try output.close();
        memory.mode = .off;
        try source.close();
        try memory.verify();
    }
}

const Handoff = struct {
    allocator: std.mem.Allocator,
    main_thread: std.Thread.Id,
    mutex: zio.Mutex = .{},
    changed: zio.Condition = .{},
    ready: bool = false,
    released: bool = false,
    image: ?*images.Image = null,
    failure: ?anyerror = null,
    fn work(self: *Handoff) void {
        self.produce() catch |err| {
            self.failure = err;
        };
        self.mutex.lock();
        self.ready = true;
        self.changed.signal();
        while (!self.released) self.changed.wait(&self.mutex);
        self.mutex.unlock();
        if (self.image) |image| image.lease.release();
    }
    fn produce(self: *Handoff) !void {
        var worker = try images.Worker.init(self.main_thread);
        defer worker.deinit();
        const image = try worker.decode(self.allocator, fixture, .{});
        errdefer image.close() catch unreachable;
        try image.lease.acquire();
        self.image = image;
    }
    fn release(self: *Handoff) void {
        self.mutex.lock();
        self.released = true;
        self.changed.signal();
        self.mutex.unlock();
    }
};

// The main thread receives a real worker-owned image while the worker still
// holds a source borrow. Failed adoption must not move that borrow's owner.
pub fn handoff(allocator: std.mem.Allocator) !void {
    var state: Handoff = .{ .allocator = allocator, .main_thread = std.Thread.getCurrentId() };
    const worker = try std.Thread.spawn(.{}, Handoff.work, .{&state});
    var joined = false;
    defer if (!joined) {
        state.release();
        worker.join();
        if (state.image) |image| {
            image.adopt() catch unreachable;
            image.close() catch unreachable;
        }
    };
    state.mutex.lock();
    while (!state.ready) state.changed.wait(&state.mutex);
    state.mutex.unlock();
    if (state.failure) |err| return err;
    try std.testing.expectError(error.ResourceInUse, state.image.?.adopt());
    state.release();
    worker.join();
    joined = true;
    const image = state.image.?;
    try image.adopt();
    defer image.close() catch unreachable;
    try std.testing.expectEqual(@as(usize, 24), (try image.pixels()).len);
}
