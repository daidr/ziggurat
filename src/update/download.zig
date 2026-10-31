const std = @import("std");
const zio = @import("ziggurat_io");
const update = @import("root.zig");

pub const Progress = struct { received: u64, total: u64 };

/// Shared between the worker running `fetch` and the UI thread. `cancel` may
/// be called from any thread; progress is reported on the worker, so a UI
/// host forwards it with `App.post` and treats `error.Full` as a dropped
/// intermediate value.
pub const Control = struct {
    cancelled: std.atomic.Value(bool) = .init(false),
    context: ?*anyopaque = null,
    on_progress: ?*const fn (context: ?*anyopaque, progress: Progress) void = null,
    /// Minimum bytes between progress reports, besides the first and last.
    report_interval: u64 = 256 * 1024,

    pub fn cancel(self: *Control) void {
        self.cancelled.store(true, .release);
    }
    pub fn isCancelled(self: *const Control) bool {
        return self.cancelled.load(.acquire);
    }
    fn report(self: *Control, progress: Progress) void {
        if (self.on_progress) |callback| callback(self.context, progress);
    }
};

/// A response body positioned at `offset`. A source that cannot resume
/// returns offset 0 and the full body.
pub const Body = struct { reader: *std.Io.Reader, offset: u64 };

/// Caller-provided transport. `open` starts a transfer of `url` at `offset`;
/// `close` releases whatever `open` acquired, including after errors in the
/// body. Sources run on the caller's worker thread.
pub const Source = struct {
    context: *anyopaque,
    open: *const fn (context: *anyopaque, url: []const u8, offset: u64) anyerror!Body,
    close: *const fn (context: *anyopaque) void,
};

/// Transfer `manifest`'s artifact into `partial`, a caller-owned file. Bytes
/// already in `partial` are re-hashed and the transfer resumes after them; a
/// source without resume support restarts from zero. Cancellation keeps the
/// partial file for a later resume and returns `error.Cancelled`. A complete
/// transfer with the wrong size or digest truncates `partial` so a retry
/// starts clean. Blocking: run on an application-managed worker.
pub fn fetch(manifest: update.Manifest, source: Source, partial: std.Io.File, control: *Control) !update.Receipt {
    var existing = (try partial.stat(zio.io())).size;
    if (existing > manifest.bytes) {
        try partial.setLength(zio.io(), 0);
        existing = 0;
    }
    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
    var buffer: [16 * 1024]u8 = undefined;
    var hashed: u64 = 0;
    while (hashed < existing) {
        if (control.isCancelled()) return error.Cancelled;
        const part: usize = @intCast(@min(buffer.len, existing - hashed));
        const n = try partial.readPositionalAll(zio.io(), buffer[0..part], hashed);
        if (n != part) return error.SizeMismatch;
        hasher.update(buffer[0..n]);
        hashed += n;
    }
    var received = existing;
    if (received < manifest.bytes) {
        if (control.isCancelled()) return error.Cancelled;
        const body = try source.open(source.context, manifest.url, received);
        defer source.close(source.context);
        if (body.offset != received) {
            if (body.offset != 0) return error.UnexpectedRange;
            try partial.setLength(zio.io(), 0);
            hasher = .init(.{});
            received = 0;
        }
        control.report(.{ .received = received, .total = manifest.bytes });
        var reported = received;
        while (true) {
            if (control.isCancelled()) return error.Cancelled;
            const n = try body.reader.readSliceShort(&buffer);
            if (n == 0) break;
            if (n > manifest.bytes - received) {
                try partial.setLength(zio.io(), 0);
                return error.SizeMismatch;
            }
            try partial.writePositionalAll(zio.io(), buffer[0..n], received);
            hasher.update(buffer[0..n]);
            received += n;
            if (received - reported >= control.report_interval or received == manifest.bytes) {
                control.report(.{ .received = received, .total = manifest.bytes });
                reported = received;
            }
        }
    }
    // A short body keeps the prefix: the next fetch resumes after it.
    if (received != manifest.bytes) return error.Incomplete;
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    if (!std.crypto.timing_safe.eql([32]u8, digest, manifest.sha256)) {
        try partial.setLength(zio.io(), 0);
        return error.HashMismatch;
    }
    try partial.sync(zio.io());
    control.report(.{ .received = received, .total = manifest.bytes });
    return .{ .bytes = received, .sha256 = digest };
}

/// In-memory source for tests and embedded payloads. `resumable` false
/// models a server that ignores range requests; `limit` truncates bodies.
pub const MemorySource = struct {
    bytes: []const u8,
    resumable: bool = true,
    limit: ?usize = null,
    opened: usize = 0,
    reader: std.Io.Reader = undefined,

    pub fn source(self: *MemorySource) Source {
        return .{ .context = self, .open = open, .close = close };
    }
    fn open(context: *anyopaque, _: []const u8, offset: u64) anyerror!Body {
        const self: *MemorySource = @ptrCast(@alignCast(context));
        self.opened += 1;
        const start: usize = if (self.resumable) @intCast(@min(offset, self.bytes.len)) else 0;
        const end = if (self.limit) |limit| @min(self.bytes.len, start + limit) else self.bytes.len;
        self.reader = .fixed(self.bytes[start..end]);
        return .{ .reader = &self.reader, .offset = start };
    }
    fn close(_: *anyopaque) void {}
};

fn testManifest(bytes: []const u8) update.Manifest {
    var manifest: update.Manifest = .{ .identity = "org.ziggurat.Download", .target = "linux-x86_64", .version = .{ .major = 1, .minor = 0, .patch = 0 }, .url = "https://example.invalid/a.zip", .bytes = bytes.len, .sha256 = undefined, .signature = @splat(0) };
    std.crypto.hash.sha2.Sha256.hash(bytes, &manifest.sha256, .{});
    return manifest;
}

const Recorder = struct {
    calls: usize = 0,
    last: Progress = .{ .received = 0, .total = 0 },
    cancel_at: ?u64 = null,
    control: *Control = undefined,
    fn record(context: ?*anyopaque, progress: Progress) void {
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.last = progress;
        if (self.cancel_at) |at| if (progress.received >= at) self.control.cancel();
    }
};

test "downloads resume after cancellation and short bodies, restart without ranges" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var payload: [100 * 1024]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(3);
    prng.random().bytes(&payload);
    const manifest = testManifest(&payload);
    var file = try temp.dir.createFile(zio.io(), "partial", .{ .read = true });
    defer file.close(zio.io());

    var memory: MemorySource = .{ .bytes = &payload };
    var recorder: Recorder = .{ .cancel_at = 40 * 1024 };
    var control: Control = .{ .context = &recorder, .on_progress = Recorder.record, .report_interval = 16 * 1024 };
    recorder.control = &control;
    try std.testing.expectError(error.Cancelled, fetch(manifest, memory.source(), file, &control));
    const kept = (try file.stat(zio.io())).size;
    try std.testing.expect(kept >= 40 * 1024 and kept < payload.len);

    control.cancelled.store(false, .release);
    recorder.cancel_at = null;
    memory.limit = 10 * 1024;
    try std.testing.expectError(error.Incomplete, fetch(manifest, memory.source(), file, &control));
    try std.testing.expectEqual(kept + 10 * 1024, (try file.stat(zio.io())).size);

    memory.limit = null;
    const receipt = try fetch(manifest, memory.source(), file, &control);
    try std.testing.expectEqual(manifest.sha256, receipt.sha256);
    try std.testing.expectEqual(Progress{ .received = payload.len, .total = payload.len }, recorder.last);
    // Already complete: verified from disk without opening the source again.
    const opened = memory.opened;
    _ = try fetch(manifest, memory.source(), file, &control);
    try std.testing.expectEqual(opened, memory.opened);

    // A source without ranges restarts; corrupted prefixes are discarded.
    try file.writePositionalAll(zio.io(), "corrupt", 0);
    try file.setLength(zio.io(), 5000);
    var plain: MemorySource = .{ .bytes = &payload, .resumable = false };
    _ = try fetch(manifest, plain.source(), file, &control);
    try file.writePositionalAll(zio.io(), "corrupt", 0);
    try std.testing.expectError(error.HashMismatch, fetch(manifest, memory.source(), file, &control));
    try std.testing.expectEqual(0, (try file.stat(zio.io())).size);
    _ = try fetch(manifest, memory.source(), file, &control);

    // Copy instead of `payload ++ ...`: concatenating a runtime array lowers to
    // one element per byte and stalls LLVM builds.
    var extended: [payload.len + 1]u8 = undefined;
    @memcpy(extended[0..payload.len], &payload);
    extended[payload.len] = 'x';
    var longer: MemorySource = .{ .bytes = &extended };
    try file.setLength(zio.io(), 0);
    try std.testing.expectError(error.SizeMismatch, fetch(manifest, longer.source(), file, &control));
    try std.testing.expectEqual(0, (try file.stat(zio.io())).size);
}
