const std = @import("std");

pub const Severity = enum { info, warning, err };

/// Identifies the code namespace, independently of the failed operation.
pub const Domain = enum { core, win32, hresult, renderer, webview, packaging, dbus, x11 };

pub const Operation = enum {
    app_init,
    app_deinit,
    window_create,
    window_destroy,
    window_update,
    text_input,
    content_attach,
    post,
    wake,
    run,
    paint,
    utf8,
    webview_create,
    webview_post,
    webview_navigate,
    webview_teardown,
    icon_load,
    manifest,
    resource_release,
    webview_permission,
    webview_download,
    webview_geometry,
    app_stop,
};

/// An App-local runtime identity for correlation and App.findWindow lookup.
/// It does not retain a window or carry authority beyond the original App.
/// Identities from different App lifetimes must be kept in separate recorders
/// or correlated by caller-owned context.
pub const WindowId = struct { index: u32, generation: u64 };

/// Owns only values. Reporting and retaining a diagnostic never borrow text.
pub const Diagnostic = struct {
    severity: Severity = .err,
    domain: Domain,
    operation: Operation,
    /// Raw bits in the given domain. Null means unavailable; zero is a code.
    /// HRESULT callers preserve the signed value with @bitCast(value).
    code: ?u32 = null,
    err: ?anyerror = null,
    window: ?WindowId = null,
};

/// A borrowed, synchronous destination. It never allocates, locks or dispatches.
/// Context must stay at a stable address and outlive all reporters. Calls use
/// the reporting thread; shared sinks must provide their own synchronization.
/// The reporting owner establishes any native/UI callback scope before report.
pub const Sink = struct {
    context: *anyopaque,
    emit: *const fn (*anyopaque, Diagnostic) void,

    pub fn report(self: Sink, diagnostic: Diagnostic) void {
        self.emit(self.context, diagnostic);
    }
};

pub const Snapshot = struct {
    /// Number of initialized entries in the caller buffer.
    count: usize,
    /// Number retained by the recorder at the snapshot's synchronization point.
    retained: usize,
    /// Permanently overwritten records since initialization, saturating at u64.
    /// A short caller buffer omits retained - count additional records.
    dropped: u64,
};

/// Fixed storage with O(1) writes. Only diagnostic writes and snapshots lock;
/// successful framework operations have no reason to access this recorder.
/// Do not copy or move an active recorder or one referenced by a borrowed Sink.
pub fn Recorder(comptime capacity: usize) type {
    if (capacity == 0) @compileError("Diagnostic recorder capacity must be positive");
    return struct {
        const Self = @This();
        mutex: std.Thread.Mutex = .{},
        items: [capacity]Diagnostic = undefined,
        head: usize = 0,
        len: usize = 0,
        dropped: u64 = 0,

        pub fn sink(self: *Self) Sink {
            return .{ .context = self, .emit = emit };
        }

        fn emit(ptr: *anyopaque, diagnostic: Diagnostic) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.record(diagnostic);
        }

        pub fn record(self: *Self, diagnostic: Diagnostic) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.len == capacity) {
                self.items[self.head] = diagnostic;
                self.head = (self.head + 1) % capacity;
                self.dropped +|= 1;
            } else {
                self.items[(self.head + self.len) % capacity] = diagnostic;
                self.len += 1;
            }
        }

        /// Copy the latest entries, in oldest-to-newest order, without consuming
        /// them. An empty buffer queries metadata. No user callback runs locked.
        pub fn snapshot(self: *Self, buffer: []Diagnostic) Snapshot {
            self.mutex.lock();
            defer self.mutex.unlock();
            const count = @min(buffer.len, self.len);
            const start = (self.head + self.len - count) % capacity;
            for (buffer[0..count], 0..) |*destination, index| {
                destination.* = self.items[(start + index) % capacity];
            }
            return .{ .count = count, .retained = self.len, .dropped = self.dropped };
        }
    };
}

test "diagnostics preserve absent codes, zero, HRESULT bits and window identity" {
    var recorder: Recorder(4) = .{};
    const sink = recorder.sink();
    sink.report(.{ .domain = .core, .operation = .app_init, .err = error.OutOfMemory });
    sink.report(.{ .domain = .win32, .operation = .window_create, .code = 0 });
    const hr: i32 = -2147467259;
    const window: WindowId = .{ .index = 0, .generation = std.math.maxInt(u64) };
    sink.report(.{ .severity = .warning, .domain = .hresult, .operation = .webview_create, .code = @bitCast(hr), .window = window });
    var buffer: [4]Diagnostic = undefined;
    const result = recorder.snapshot(&buffer);
    try std.testing.expectEqual(3, result.count);
    try std.testing.expectEqual(3, result.retained);
    try std.testing.expectEqual(0, result.dropped);
    try std.testing.expect(buffer[0].code == null);
    try std.testing.expectEqual(error.OutOfMemory, buffer[0].err.?);
    try std.testing.expectEqual(@as(?u32, 0), buffer[1].code);
    try std.testing.expect(buffer[1].err == null);
    try std.testing.expectEqual(@as(u32, @bitCast(hr)), buffer[2].code.?);
    try std.testing.expectEqual(Severity.warning, buffer[2].severity);
    try std.testing.expectEqualDeep(window, buffer[2].window.?);
}

test "bounded recorder wraps and copies the latest retained diagnostics in order" {
    var recorder: Recorder(3) = .{};
    for (0..8) |index| recorder.record(.{ .domain = .renderer, .operation = .paint, .code = @intCast(index) });
    var buffer: [5]Diagnostic = @splat(.{ .domain = .core, .operation = .run, .code = 99 });
    const all = recorder.snapshot(&buffer);
    try std.testing.expectEqual(3, all.count);
    try std.testing.expectEqual(3, all.retained);
    try std.testing.expectEqual(5, all.dropped);
    for (buffer[0..all.count], 5..) |diagnostic, index| try std.testing.expectEqual(@as(?u32, @intCast(index)), diagnostic.code);
    try std.testing.expectEqual(@as(?u32, 99), buffer[3].code);
    try std.testing.expectEqual(@as(?u32, 99), buffer[4].code);
    var latest: [2]Diagnostic = undefined;
    const partial = recorder.snapshot(&latest);
    try std.testing.expectEqual(2, partial.count);
    try std.testing.expectEqual(3, partial.retained);
    try std.testing.expectEqual(5, partial.dropped);
    try std.testing.expectEqual(@as(?u32, 6), latest[0].code);
    try std.testing.expectEqual(@as(?u32, 7), latest[1].code);
    const metadata = recorder.snapshot(&.{});
    try std.testing.expectEqual(0, metadata.count);
    try std.testing.expectEqual(3, metadata.retained);
    try std.testing.expectEqual(5, metadata.dropped);
}

test "empty and single-entry recorders keep counters and snapshots bounded" {
    var recorder: Recorder(1) = .{};
    var buffer: [1]Diagnostic = undefined;
    const empty = recorder.snapshot(&buffer);
    try std.testing.expectEqual(0, empty.count);
    try std.testing.expectEqual(0, empty.retained);
    try std.testing.expectEqual(0, empty.dropped);
    recorder.record(.{ .domain = .packaging, .operation = .manifest, .code = 1 });
    recorder.record(.{ .domain = .packaging, .operation = .icon_load, .code = 2 });
    const full = recorder.snapshot(&buffer);
    try std.testing.expectEqual(1, full.count);
    try std.testing.expectEqual(1, full.dropped);
    try std.testing.expectEqual(Operation.icon_load, buffer[0].operation);
    try std.testing.expectEqual(@as(?u32, 2), buffer[0].code);
    recorder.dropped = std.math.maxInt(u64);
    recorder.record(.{ .domain = .packaging, .operation = .resource_release });
    try std.testing.expectEqual(std.math.maxInt(u64), recorder.snapshot(&buffer).dropped);
}

test "sink is synchronous and supports reentrant reporting and snapshots" {
    const State = struct {
        recorder: Recorder(4) = .{},
        calls: usize = 0,
        nested_snapshot_count: usize = 0,
        fn emit(ptr: *anyopaque, diagnostic: Diagnostic) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            self.recorder.record(diagnostic);
            var buffer: [4]Diagnostic = undefined;
            self.nested_snapshot_count = self.recorder.snapshot(&buffer).count;
            if (self.calls == 1) {
                const recursive: Sink = .{ .context = self, .emit = emit };
                recursive.report(.{ .domain = .core, .operation = .run, .code = 2 });
            }
        }
    };
    var state: State = .{};
    const sink: Sink = .{ .context = &state, .emit = State.emit };
    sink.report(.{ .domain = .core, .operation = .app_init, .code = 1 });
    try std.testing.expectEqual(2, state.calls);
    try std.testing.expectEqual(2, state.nested_snapshot_count);
    var buffer: [4]Diagnostic = undefined;
    try std.testing.expectEqual(2, state.recorder.snapshot(&buffer).count);
    try std.testing.expectEqual(@as(?u32, 1), buffer[0].code);
    try std.testing.expectEqual(@as(?u32, 2), buffer[1].code);
}

test "concurrent sinks retain every diagnostic without tearing snapshot values" {
    const total = 4 * 128;
    const Worker = struct {
        sink: Sink,
        start: *std.Thread.ResetEvent,
        finished: *std.atomic.Value(usize),
        base: u32,
        fn run(self: *@This()) void {
            self.start.wait();
            for (0..128) |index| {
                const code = self.base + @as(u32, @intCast(index));
                self.sink.report(.{
                    .domain = .win32,
                    .operation = .wake,
                    .code = code,
                    .window = .{ .index = code, .generation = @as(u64, code) + 1 },
                });
            }
            _ = self.finished.fetchAdd(1, .release);
        }
    };
    var recorder: Recorder(total) = .{};
    var start: std.Thread.ResetEvent = .{};
    var finished: std.atomic.Value(usize) = .init(0);
    var workers: [4]Worker = undefined;
    var threads: [4]std.Thread = undefined;
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |thread| thread.join();
    errdefer start.set();
    for (&workers, &threads, 0..) |*worker, *thread, index| {
        worker.* = .{ .sink = recorder.sink(), .start = &start, .finished = &finished, .base = @intCast(index * 128) };
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
        spawned += 1;
    }
    start.set();
    var buffer: [total]Diagnostic = undefined;
    while (finished.load(.acquire) != threads.len) {
        const snapshot = recorder.snapshot(&buffer);
        try std.testing.expectEqual(0, snapshot.dropped);
        for (buffer[0..snapshot.count]) |diagnostic| {
            try std.testing.expectEqual(diagnostic.code.?, diagnostic.window.?.index);
            try std.testing.expectEqual(@as(u64, diagnostic.code.?) + 1, diagnostic.window.?.generation);
        }
        std.Thread.yield() catch {};
    }
    for (threads) |thread| thread.join();
    spawned = 0;
    const snapshot = recorder.snapshot(&buffer);
    try std.testing.expectEqual(total, snapshot.count);
    try std.testing.expectEqual(0, snapshot.dropped);
    var seen: [total]bool = @splat(false);
    for (buffer[0..snapshot.count]) |diagnostic| {
        const code = diagnostic.code.?;
        try std.testing.expect(!seen[code]);
        seen[code] = true;
    }
    for (seen) |present| try std.testing.expect(present);
}

test "concurrent bounded recording counts overwritten diagnostics exactly" {
    const Worker = struct {
        recorder: *Recorder(7),
        start: *std.Thread.ResetEvent,
        fn run(self: *@This()) void {
            self.start.wait();
            for (0..128) |_| self.recorder.record(.{ .domain = .hresult, .operation = .webview_create, .err = error.InitializationFailed });
        }
    };
    var recorder: Recorder(7) = .{};
    var start: std.Thread.ResetEvent = .{};
    var worker: Worker = .{ .recorder = &recorder, .start = &start };
    var threads: [4]std.Thread = undefined;
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |thread| thread.join();
    errdefer start.set();
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{&worker});
        spawned += 1;
    }
    start.set();
    for (threads) |thread| thread.join();
    spawned = 0;
    var buffer: [7]Diagnostic = undefined;
    const snapshot = recorder.snapshot(&buffer);
    try std.testing.expectEqual(7, snapshot.count);
    try std.testing.expectEqual(7, snapshot.retained);
    try std.testing.expectEqual(512 - 7, snapshot.dropped);
    for (buffer) |diagnostic| try std.testing.expectEqual(error.InitializationFailed, diagnostic.err.?);
}
