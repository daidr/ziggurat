const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const system = @import("ziggurat_system");
const Watchdog = @import("watchdog.zig").Watchdog;
const clipboard = system.clipboard;

const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x0dIDATx\x9cc\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99=\x1d\x00\x00\x00\x00IEND\xaeB`\x82";
const text = "héllo 世界 😀";
const html = "<b>粗体</b> & <i>x</i>";
const custom: clipboard.Format = .{ .kind = .custom, .name = "application/x-ziggurat-smoke" };
const custom_bytes = "\x00\x01\x02binary\xff";
const files = if (builtin.os.tag == .windows) "C:\\Windows\\a b.txt\x00C:\\Windows\\文件.txt" else "/tmp/a b.txt\x00/tmp/文件.txt";

const Step = enum { formats, text, html, png, custom, files, capacity, missing, lazy, replace, revoked, done };
const Script = struct {
    app: *z.App,
    board: clipboard.Board = undefined,
    request: clipboard.Request = .{},
    spare: clipboard.Request = .{},
    buffer: [4096]u8 = undefined,
    step: Step = .formats,
    changes: u32 = 0,
    renders: u32 = 0,
    released: u32 = 0,
    spare_calls: u32 = 0,
    failure: ?anyerror = null,

    fn changed(context: *anyopaque) void {
        const self: *Script = @ptrCast(@alignCast(context));
        self.changes += 1;
    }
    fn render(context: *anyopaque, format: clipboard.Format, sink: *clipboard.Sink) anyerror!void {
        const self: *Script = @ptrCast(@alignCast(context));
        self.renders += 1;
        switch (format.kind) {
            .text => try sink.set("lazy " ++ text),
            .custom => try sink.set(custom_bytes),
            else => return error.Unexpected,
        }
        try std.testing.expectError(error.AlreadyWritten, sink.set("again"));
    }
    fn release(context: *anyopaque) void {
        const self: *Script = @ptrCast(@alignCast(context));
        self.released += 1;
    }
    fn spareResult(context: *anyopaque, _: clipboard.Result) void {
        const self: *Script = @ptrCast(@alignCast(context));
        self.spare_calls += 1;
    }
    fn result(context: *anyopaque, value: clipboard.Result) void {
        const self: *Script = @ptrCast(@alignCast(context));
        self.check(value) catch |err| {
            self.failure = err;
            self.app.quit();
        };
    }
    fn expectData(value: clipboard.Result, expected: []const u8) !void {
        switch (value) {
            .data => |data| try std.testing.expectEqualSlices(u8, expected, data),
            else => {
                std.debug.print("unexpected clipboard result {any}\n", .{value});
                return error.UnexpectedResult;
            },
        }
    }
    fn read(self: *Script, format: clipboard.Format, destination: []u8) !void {
        try self.board.read(&self.request, format, destination, self, result, .{});
    }
    fn begin(self: *Script) !void {
        try self.board.write(&.{
            .{ .format = .{ .kind = .text }, .data = text },
            .{ .format = .{ .kind = .html }, .data = html },
            .{ .format = .{ .kind = .png }, .data = png },
            .{ .format = custom, .data = custom_bytes },
            .{ .format = .{ .kind = .files }, .data = files },
        });
        try self.board.formats(&self.request, self, result);
        try std.testing.expectError(error.RequestPending, self.read(.{ .kind = .text }, &self.buffer));
        // A cancelled slot never calls back, even though native work continues.
        try self.board.read(&self.spare, .{ .kind = .text }, &self.buffer, self, spareResult, .{});
        self.spare.cancel();
        self.spare.cancel();
    }
    fn check(self: *Script, value: clipboard.Result) !void {
        switch (self.step) {
            .formats => {
                const available = value.formats;
                try std.testing.expect(available.text and available.html and available.png and available.files);
                self.step = .text;
                try self.read(.{ .kind = .text }, &self.buffer);
            },
            .text => {
                try expectData(value, text);
                self.step = .html;
                try self.read(.{ .kind = .html }, &self.buffer);
            },
            .html => {
                try expectData(value, html);
                self.step = .png;
                try self.read(.{ .kind = .png }, &self.buffer);
            },
            .png => {
                try expectData(value, png);
                self.step = .custom;
                try self.read(custom, &self.buffer);
            },
            .custom => {
                switch (value) {
                    // Windows may report allocator padding after foreign custom bytes.
                    .data => |data| try std.testing.expectEqualSlices(u8, custom_bytes, data[0..custom_bytes.len]),
                    else => return error.UnexpectedResult,
                }
                self.step = .files;
                try self.read(.{ .kind = .files }, &self.buffer);
            },
            .files => {
                try expectData(value, files);
                self.step = .capacity;
                try self.read(.{ .kind = .text }, self.buffer[0..3]);
            },
            .capacity => {
                try std.testing.expectEqual(clipboard.Result{ .capacity_exceeded = text.len }, value);
                self.step = .missing;
                try self.read(.{ .kind = .custom, .name = "application/x-ziggurat-missing" }, &self.buffer);
            },
            .missing => {
                try std.testing.expect(value == .unavailable);
                self.step = .lazy;
                try self.board.offer(.{ .context = self, .render = render, .released = release }, &.{ .{ .kind = .text }, custom });
                try std.testing.expect(self.board.offering());
                try std.testing.expectEqual(@as(u32, 0), self.renders);
                try self.read(.{ .kind = .text }, &self.buffer);
            },
            .lazy => {
                try expectData(value, "lazy " ++ text);
                try std.testing.expect(self.renders >= 1 and self.released == 0);
                // An eager write replaces the offer and releases its provider once.
                try self.board.write(&.{.{ .format = .{ .kind = .text }, .data = "eager" }});
                try std.testing.expectEqual(@as(u32, 1), self.released);
                try std.testing.expect(!self.board.offering());
                self.step = .replace;
                try self.read(.{ .kind = .text }, &self.buffer);
            },
            .replace => {
                try expectData(value, "eager");
                try self.board.offer(.{ .context = self, .render = render, .released = release }, &.{.{ .kind = .text }});
                self.board.revoke();
                self.board.revoke();
                try std.testing.expectEqual(@as(u32, 2), self.released);
                self.step = .revoked;
                try self.read(.{ .kind = .text }, &self.buffer);
            },
            .revoked => {
                try std.testing.expect(value == .unavailable);
                try std.testing.expect(self.changes >= 1 and self.spare_calls == 0);
                // Leave a pending read and a live offer for App stop to reclaim.
                try self.board.offer(.{ .context = self, .render = render, .released = release }, &.{.{ .kind = .text }});
                self.step = .done;
                try self.read(.{ .kind = .text }, &self.buffer);
                self.app.quit();
            },
            .done => return error.CallbackAfterStop,
        }
    }
    fn start(context: *anyopaque) void {
        const self: *Script = @ptrCast(@alignCast(context));
        self.begin() catch |err| {
            self.failure = err;
            self.app.quit();
        };
    }
};

fn script(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    // A run loop without windows ends at once; the window is never shown.
    _ = try app.createWindow(.{});
    var state: Script = .{ .app = app };
    try state.board.init(app, .{ .context = &state, .on_changed = Script.changed, .render_on_stop = false });
    defer state.board.deinit();
    try std.testing.expectError(error.InvalidFormatName, state.board.write(&.{.{ .format = .{ .kind = .custom, .name = "bad name " }, .data = "" }}));
    try std.testing.expectError(error.DuplicateFormat, state.board.write(&.{ .{ .format = .{ .kind = .text }, .data = "a" }, .{ .format = .{ .kind = .text }, .data = "b" } }));
    try std.testing.expectError(error.InvalidPng, state.board.write(&.{.{ .format = .{ .kind = .png }, .data = "nope" }}));
    try std.testing.expectError(error.InvalidOptions, state.board.read(&state.request, .{ .kind = .text }, &state.buffer, &state, Script.result, .{ .attempts = 200 }));
    try app.post(.{ .context = &state, .call = Script.start });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    if (state.failure) |err| return err;
    try std.testing.expect(!watchdog.expired);
    try std.testing.expectEqual(Step.done, state.step);
    // App stop cancelled the pending read and released the live offer.
    try std.testing.expect(!state.request.pending());
    try std.testing.expectEqual(@as(u32, 3), state.released);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().stop_participants);
}

const Round = struct {
    app: *z.App,
    board: clipboard.Board = undefined,
    request: clipboard.Request = .{},
    buffer: [64]u8 = undefined,
    calls: u32 = 0,
    fn result(context: *anyopaque, value: clipboard.Result) void {
        const self: *Round = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (value != .data) std.debug.print("round result {any}\n", .{value});
        self.app.quit();
    }
    fn start(context: *anyopaque) void {
        const self: *Round = @ptrCast(@alignCast(context));
        self.board.write(&.{.{ .format = .{ .kind = .text }, .data = "round" }}) catch self.app.quit();
        self.board.read(&self.request, .{ .kind = .text }, &self.buffer, self, result, .{}) catch self.app.quit();
    }
};
fn rounds(allocator: std.mem.Allocator) !void {
    for (0..12) |_| {
        const app = try z.App.init(allocator);
        defer app.deinit();
        _ = try app.createWindow(.{});
        var state: Round = .{ .app = app };
        try state.board.init(app, .{});
        defer state.board.deinit();
        try app.post(.{ .context = &state, .call = Round.start });
        var watchdog: Watchdog = .{ .app = app };
        try watchdog.start();
        defer watchdog.stop();
        try app.run();
        try std.testing.expect(!watchdog.expired and state.calls == 1);
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    try script(gpa.allocator());
    try rounds(gpa.allocator());
    // Cancelled GTK requests finished in later main loops and freed themselves.
    // Only the last eager GTK offer remains: it serves its own copy after its
    // Board closed until another owner replaces it. Windows owns no records.
    try std.testing.expectEqual(@as(u32, if (builtin.os.tag == .linux) 1 else 0), clipboard.resourceCount());
    std.debug.print("clipboard smoke passed\n", .{});
}
