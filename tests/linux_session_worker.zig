const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");

/// One explicit host worker. Only the protected owning response crosses into
/// its accepted task; the pump never reads View, Session or Window storage.
pub const FileWorker = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    ready: z.Task,
    thread: ?std.Thread = null,
    gate: zio.Semaphore = .{},
    mutex: zio.Mutex = .{},
    stopping: bool = false,
    response: ?web.OwnedFileResponse = null,
    failure: std.atomic.Value(u16) = .init(0),
    pub fn start(self: *FileWorker) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }
    pub fn begin(self: *FileWorker) void {
        self.gate.post();
    }
    pub fn err(self: *FileWorker) ?anyerror {
        const value = self.failure.load(.acquire);
        return if (value == 0) null else @errorFromInt(value);
    }
    pub fn take(self: *FileWorker) ?web.OwnedFileResponse {
        self.mutex.lock();
        defer self.mutex.unlock();
        var value: ?web.OwnedFileResponse = null;
        std.mem.swap(?web.OwnedFileResponse, &self.response, &value);
        return value;
    }
    /// Called by the host after App.run, never by framework UI callbacks.
    pub fn stop(self: *FileWorker) void {
        self.mutex.lock();
        self.stopping = true;
        var pending: ?web.OwnedFileResponse = null;
        std.mem.swap(?web.OwnedFileResponse, &self.response, &pending);
        self.mutex.unlock();
        if (pending) |*owned| owned.deinit();
        self.gate.post();
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }
    fn run(self: *FileWorker) void {
        self.gate.wait();
        self.mutex.lock();
        const stopped = self.stopping;
        self.mutex.unlock();
        if (stopped) return;
        self.perform() catch |failure| {
            self.failure.store(@intFromError(failure), .release);
            self.app.post(self.ready) catch {};
        };
    }
    fn perform(self: *FileWorker) !void {
        var temporary = zio.tmpDir(.{});
        defer temporary.cleanup();
        const file = try temporary.dir.createFile(zio.io(), "private", .{ .read = true });
        defer file.close(zio.io());
        const block: [4096]u8 = @splat('w');
        for (0..128) |_| try file.writeStreamingAll(zio.io(), &block);
        try file.writeStreamingAll(zio.io(), block[0..37]);
        const position = try zio.posix.position(file.handle);
        var prepared = try web.OwnedFileResponse.preparePumped(self.allocator, self.app.owner, file, .{ .mime = "application/octet-stream" }, 1024 * 1024);
        defer prepared.pump.deinit();
        self.mutex.lock();
        const stopped = self.stopping;
        if (!stopped) self.response = prepared.response;
        self.mutex.unlock();
        if (stopped) {
            prepared.response.deinit();
            return;
        }
        self.app.post(self.ready) catch |failure| {
            if (self.take()) |owned_value| {
                var owned = owned_value;
                owned.deinit();
            }
            return failure;
        };
        try prepared.pump.pump();
        try std.testing.expectEqual(position, try zio.posix.position(file.handle));
    }
};
