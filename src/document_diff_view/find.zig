const std = @import("std");
const z = @import("ziggurat");
const d = @import("ziggurat_document");
const editable = @import("editable.zig");
const physical = @import("find_pool.zig");
const Pool = physical.Pool(editable.SourceStamp);

pub const Limits = physical.Limits;
pub const Options = physical.Options;
pub const Direction = physical.Direction;
pub const Work = Pool.Work;
pub const Ticket = Pool.Ticket;
pub const Step = physical.Step;
pub const Progress = physical.Progress;
pub const Stats = physical.Stats;

/// Explicit bounded literal search on the editable coordinator's last active
/// source. Stable address covers every Work/Ticket and accepted host delivery.
/// The host supplies workers, App.post, stop, finish and shutdown ordering.
/// Never copy this owner or use a ticket after its owning Find is closed.
pub const Find = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    view: *editable.View,
    window: z.Window,
    pool: *Pool,
    busy: bool = false,

    pub fn create(allocator: std.mem.Allocator, view: *editable.View, limits: Limits) !*Find {
        try physical.validateLimits(limits);
        const minimum = std.math.add(usize, @sizeOf(Find), try Pool.minimumBytes(limits)) catch return error.CapacityExceeded;
        if (limits.bytes < minimum) return error.CapacityExceeded;
        try view.retainClient();
        const pair = view.sourcePair() catch |err| {
            view.releaseClient() catch unreachable;
            return err;
        };
        if (pair.window.app.phase == .stopping or pair.window.app.phase == .stopped) {
            view.releaseClient() catch unreachable;
            return error.Closed;
        }
        const scope = pair.window.beginCallback() orelse {
            view.releaseClient() catch unreachable;
            return error.Closed;
        };
        var transferred = false;
        defer {
            // Candidate frees run before this defer. On failure revoke the
            // provisional client before scope exit can expose close callbacks.
            if (!transferred) view.releaseClient() catch unreachable;
            scope.end();
        }
        const self = try allocator.create(Find);
        errdefer allocator.destroy(self);
        var pool_limits = limits;
        pool_limits.bytes -= @sizeOf(Find);
        const pool = try Pool.create(allocator, pool_limits);
        errdefer pool.close() catch unreachable;
        if (pair.window.isClosed() or pair.window.app.phase == .stopping or pair.window.app.phase == .stopped) return error.Closed;
        self.* = .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .view = view, .window = pair.window, .pool = pool };
        transferred = true;
        return self;
    }
    fn check(self: *Find) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.busy) return error.Busy;
    }
    fn enter(self: *Find) !z.CallbackScope {
        try self.check();
        if (self.pool.stopping or self.window.app.phase == .stopping or self.window.app.phase == .stopped) return error.Closed;
        const scope = self.window.beginCallback() orelse return error.Closed;
        self.busy = true;
        return scope;
    }
    fn enterTeardown(self: *Find) !z.AppCallbackScope {
        try self.check();
        self.busy = true;
        return self.window.app.beginTeardownCallback();
    }
    fn validate(ptr: *anyopaque, stamp: editable.SourceStamp) !void {
        const self: *Find = @ptrCast(@alignCast(ptr));
        try self.view.validateSource(stamp);
    }
    /// Owner copies and validates at most query_bytes UTF-8 bytes, captures an
    /// immutable Snapshot/Reader, then publishes. Prefix construction and the
    /// full-text scan run only in explicit worker prepare/step operations.
    /// Full/Closed/other failure leaves the previous current query unchanged.
    pub fn begin(self: *Find, pattern: []const u8, options: Options) !Work {
        const scope = try self.enter();
        defer {
            self.busy = false;
            scope.end();
        }
        const capture = try self.view.captureSource();
        const stamp = capture.stamp;
        return self.pool.begin(.{
            .document = capture.document,
            .stamp = stamp,
            .revision = stamp.revisions[@backingInt(stamp.side)],
            .text_version = stamp.text_versions[@backingInt(stamp.side)],
            .selection = stamp.selection,
        }, pattern, options, .{ .context = self, .validate = validate });
    }
    /// Apply once, only after Work.release. null means a completed no-match
    /// query. Caller scratch is the same explicit 2S selection storage required
    /// by View.run. A pre-commit error can be retried after fixing its cause;
    /// a returned committed receipt is never permission to repeat the command.
    pub fn apply(self: *Find, ticket: Ticket, selection_scratch: []d.Selection) !?editable.CommandOutcome {
        const scope = try self.enter();
        defer {
            self.busy = false;
            scope.end();
        }
        const result = try self.pool.result(ticket);
        switch (result.value) {
            .not_found => {
                try self.view.validateSource(result.stamp);
                self.pool.accept(ticket) catch unreachable;
                return null;
            },
            .match => |range| {
                const outcome = try self.view.runFromSource(result.stamp, .{ .set_selection = .{ .anchor = range.start, .caret = range.end } }, selection_scratch);
                // Find's gate spans all command/allocator/native callbacks, so
                // no cancellation, finish or reuse can intervene after commit.
                self.pool.accept(ticket) catch unreachable;
                return outcome;
            },
        }
    }
    /// Cancellation is logical only: the host still releases the worker and
    /// finishes its physical ticket after any accepted delivery executes once.
    pub fn cancel(self: *Find, ticket: Ticket) !bool {
        const scope = try self.enterTeardown();
        defer {
            self.busy = false;
            scope.end();
        }
        return self.pool.cancel(ticket);
    }
    pub fn stop(self: *Find) !void {
        const scope = try self.enterTeardown();
        defer {
            self.busy = false;
            scope.end();
        }
        try self.pool.stop();
    }
    /// Owner teardown after the delivery's last use. ReadersAlive/WorkerRunning
    /// retain responsibility and can be retried. No slot is reused at release.
    pub fn finish(self: *Find, ticket: Ticket) !bool {
        const scope = try self.enterTeardown();
        defer {
            self.busy = false;
            scope.end();
        }
        return self.pool.finish(ticket);
    }
    pub fn stats(self: *Find) !Stats {
        try self.check();
        var value = try self.pool.stats();
        value.owned_bytes += @sizeOf(Find);
        value.peak_bytes += @sizeOf(Find);
        return value;
    }
    /// Stop does not join a worker or drain App.post. The host does those steps
    /// explicitly, then closes this owner before closing its coordinator/App.
    pub fn close(self: *Find) !void {
        const scope = try self.enterTeardown();
        errdefer {
            self.busy = false;
            scope.end();
        }
        try self.pool.close();
        const allocator = self.allocator;
        const view = self.view;
        // Keep the coordinator pin through the final foreign free callback.
        allocator.destroy(self);
        view.releaseClient() catch unreachable;
        scope.end();
    }
};

test {
    _ = physical;
}
