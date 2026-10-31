//! Opening a URL from the owner thread, whose Worker calls would block it.
const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const shell = @import("shell.zig");

/// Opens one URL from the owner thread without blocking it: `start` copies
/// the URL, starts one thread that hands it to the system as Worker.openUrl
/// does, and `on_done` runs on the owner thread with the outcome. The thread
/// is the request's own; nothing is pooled. Caller-owned and address-stable
/// from start until on_done runs or App shutdown completes. Shutdown waits
/// for the thread, then on_done does not run. `extra_schemes` are borrowed
/// as long.
pub const OpenUrl = struct {
    app: ?*z.App = null,
    context: *anyopaque = undefined,
    on_done: *const fn (*anyopaque, *OpenUrl) void = undefined,
    options: shell.UrlOptions = .{},
    url_bytes: [shell.max_url_bytes]u8 = undefined,
    url_len: usize = 0,
    thread: ?std.Thread = null,
    stop_node: z.StopParticipant = undefined,
    stop_token: ?z.StopToken = null,
    /// The system's answer, read in on_done.
    result: anyerror!void = {},
    /// Set by shutdown: the thread ended and on_done will not run.
    abandoned: std.atomic.Value(bool) = .init(false),

    pub fn start(self: *OpenUrl, app: *z.App, target: []const u8, options: shell.UrlOptions, context: *anyopaque, on_done: *const fn (*anyopaque, *OpenUrl) void) !void {
        app.assertOwner();
        if (self.app != null) return error.Busy;
        if (comptime !shell.capabilities.open_url) return error.UnsupportedCapability;
        try shell.validateUrl(target, options.extra_schemes);
        self.* = .{ .app = app, .context = context, .on_done = on_done, .options = options, .url_len = target.len };
        @memcpy(self.url_bytes[0..target.len], target);
        self.stop_node = .{ .context = self, .stop = stopped };
        self.stop_token = try app.registerStop(&self.stop_node);
        errdefer {
            _ = app.cancelStop(self.stop_token.?) catch false;
            self.app = null;
        }
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }
    pub fn url(self: *const OpenUrl) []const u8 {
        return self.url_bytes[0..self.url_len];
    }
    /// Whether the thread has not reported yet.
    pub fn pending(self: *const OpenUrl) bool {
        return self.app != null;
    }

    fn run(self: *OpenUrl) void {
        const app = self.app.?;
        self.result = open: {
            var worker = shell.Worker.init(app.owner) catch |err| break :open err;
            defer worker.deinit();
            break :open worker.openUrl(self.url(), self.options);
        };
        // Full only means the owner thread is behind; Closed means shutdown,
        // which waits for this thread.
        while (true) {
            if (self.abandoned.load(.acquire)) return;
            app.post(.{ .context = self, .call = finish }) catch |err| switch (err) {
                error.Full => {
                    zio.sleep(std.time.ns_per_ms);
                    continue;
                },
                else => return,
            };
            return;
        }
    }
    fn finish(ptr: *anyopaque) void {
        const self: *OpenUrl = @ptrCast(@alignCast(ptr));
        const app = self.app orelse return;
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.stop_token) |token| _ = app.cancelStop(token) catch false;
        self.stop_token = null;
        self.app = null;
        self.on_done(self.context, self);
    }
    fn stopped(ptr: *anyopaque) anyerror!void {
        const self: *OpenUrl = @ptrCast(@alignCast(ptr));
        self.stop_token = null;
        self.abandoned.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.app = null;
    }
};
