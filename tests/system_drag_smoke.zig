//! Native drags between two windows of this process with real input: a
//! multi-item, multi-format drag with a lazy representation reaches a
//! DataTarget with every item, copy and Shift's move are negotiated, and
//! Escape, `cancel`, letting go over no target and a refused offer all end
//! the drag once. Linux injects the pointer with XTest on X11, Windows
//! with SetCursorPos and SendInput.
const std = @import("std");
const zio = @import("ziggurat_io");
const exitAfter = @import("watchdog.zig").exitAfter;
const builtin = @import("builtin");
const z = @import("ziggurat");
const system = @import("ziggurat_system");
const transfer = system.transfer;
const drag = system.drag;
const drop = system.drop;

const linux = builtin.os.tag == .linux;
const note_format = "application/x-ziggurat-smoke-note";

const X11 = struct {
    extern fn XOpenDisplay(?[*:0]const u8) ?*anyopaque;
    extern fn XCloseDisplay(*anyopaque) c_int;
    extern fn XFlush(*anyopaque) c_int;
    extern fn XKeysymToKeycode(*anyopaque, c_ulong) u8;
    library: std.DynLib,
    display: *anyopaque,
    key: *const fn (*anyopaque, c_uint, c_int, c_ulong) callconv(.c) c_int,
    move: *const fn (*anyopaque, c_int, c_int, c_int, c_ulong) callconv(.c) c_int,
    button: *const fn (*anyopaque, c_uint, c_int, c_ulong) callconv(.c) c_int,

    fn open() !X11 {
        var library = try std.DynLib.open("libXtst.so.6");
        errdefer library.close();
        return .{
            .library = library,
            .display = XOpenDisplay(null) orelse return error.DisplayUnavailable,
            .key = library.lookup(*const fn (*anyopaque, c_uint, c_int, c_ulong) callconv(.c) c_int, "XTestFakeKeyEvent") orelse return error.XTestUnavailable,
            .move = library.lookup(*const fn (*anyopaque, c_int, c_int, c_int, c_ulong) callconv(.c) c_int, "XTestFakeMotionEvent") orelse return error.XTestUnavailable,
            .button = library.lookup(*const fn (*anyopaque, c_uint, c_int, c_ulong) callconv(.c) c_int, "XTestFakeButtonEvent") orelse return error.XTestUnavailable,
        };
    }
    fn close(self: *X11) void {
        _ = XCloseDisplay(self.display);
        self.library.close();
    }
    fn keyEvent(self: *X11, keysym: c_ulong, down: bool) void {
        _ = self.key(self.display, XKeysymToKeycode(self.display, keysym), @intFromBool(down), 0);
        _ = XFlush(self.display);
    }
    fn pointer(self: *X11, point: z.ScreenPoint) void {
        _ = self.move(self.display, -1, point.x, point.y, 0);
        _ = XFlush(self.display);
    }
    fn press(self: *X11, down: bool) void {
        _ = self.button(self.display, 1, @intFromBool(down), 0);
        _ = XFlush(self.display);
    }
};
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;

const win = @import("ziggurat_c_win32");
/// SetCursorPos moves and SendInput presses, as a user would.
const Win32 = struct {
    fn open() !Win32 {
        return .{};
    }
    fn close(_: *Win32) void {}
    fn send(input: win.INPUT) void {
        var copy = input;
        _ = win.SendInput(1, &copy, @sizeOf(win.INPUT));
    }
    fn keyEvent(_: *Win32, keysym: c_ulong, down: bool) void {
        var input = std.mem.zeroes(win.INPUT);
        input.type = win.INPUT_KEYBOARD;
        input.unnamed_0.ki.wVk = if (keysym == 0xff1b) win.VK_ESCAPE else win.VK_SHIFT;
        input.unnamed_0.ki.dwFlags = if (down) 0 else win.KEYEVENTF_KEYUP;
        send(input);
    }
    fn pointer(_: *Win32, point: z.ScreenPoint) void {
        _ = win.SetCursorPos(point.x, point.y);
    }
    fn press(_: *Win32, down: bool) void {
        var input = std.mem.zeroes(win.INPUT);
        input.type = win.INPUT_MOUSE;
        input.unnamed_0.mi.dwFlags = if (down) win.MOUSEEVENTF_LEFTDOWN else win.MOUSEEVENTF_LEFTUP;
        send(input);
    }
};
const Input = if (linux) X11 else Win32;

/// A point `d` DIPs from a window origin in desktop pixels: X11 positions
/// are logical, Windows positions physical.
fn screenAt(origin: z.ScreenPoint, dx: i32, dy: i32, scale: f32) z.ScreenPoint {
    if (linux) return .{ .x = @intFromFloat(@as(f32, @floatFromInt(origin.x + dx)) * scale), .y = @intFromFloat(@as(f32, @floatFromInt(origin.y + dy)) * scale) };
    return .{ .x = origin.x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(dx)) * scale)), .y = origin.y + @as(i32, @intFromFloat(@as(f32, @floatFromInt(dy)) * scale)) };
}
fn windowScale(window: z.Window) !f32 {
    if (linux) return @floatFromInt(gtk_widget_get_scale_factor(window.nativeHandle().?));
    return (try window.contentSize()).scale;
}

const Round = enum { copy, move, escape, cancel, no_target, refused, legacy, external };
const Stage = enum { settle, press, start, travel, over, release, wait_done, next, external, done };

const Smoke = struct {
    app: *z.App,
    allocator: std.mem.Allocator,
    source_window: z.Window = undefined,
    target_window: z.Window = undefined,
    legacy_window: z.Window = undefined,
    legacy: drop.Target = undefined,
    legacy_buffer: [256]u8 = undefined,
    legacy_drops: u32 = 0,
    legacy_text: [64]u8 = undefined,
    legacy_text_len: usize = 0,
    source: drag.Source = .{},
    target: drop.DataTarget = undefined,
    round: Round = .copy,
    stage: Stage = .settle,
    waited: u32 = 0,
    step: u32 = 0,
    held: bool = false,
    want_start: bool = false,
    started: u32 = 0,
    renders: u32 = 0,
    hovers: u32 = 0,
    local_hovers: u32 = 0,
    left: u32 = 0,
    drops: u32 = 0,
    last_drop: ?drop.DataDrop = null,
    dropped_items: usize = 0,
    dropped_note: [64]u8 = undefined,
    dropped_note_len: usize = 0,
    dropped_text: [64]u8 = undefined,
    dropped_text_len: usize = 0,
    results: [8]?drag.Result = @splat(null),
    dropped_files: [256]u8 = undefined,
    dropped_files_len: usize = 0,
    child: ?std.process.Child = null,
    child_exit: std.atomic.Value(i32) = .init(-1),
    done_calls: u32 = 0,
    failure: ?anyerror = null,
    input: Input = undefined,
    scale: f32 = 1,
    stop: std.atomic.Value(bool) = .init(false),

    fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
        const self: *Smoke = @ptrCast(@alignCast(ptr));
        _ = window;
        switch (value) {
            .pointer_down => self.held = true,
            .pointer_up => self.held = false,
            .pointer_move => if (self.held and self.want_start) {
                self.want_start = false;
                self.begin() catch |err| self.finish(err);
            },
            else => {},
        }
    }
    fn detach(_: *anyopaque) void {}

    fn render(ptr: *anyopaque, format: transfer.Format, sink: *transfer.Sink) anyerror!void {
        const self: *Smoke = @ptrCast(@alignCast(ptr));
        self.renders += 1;
        try std.testing.expectEqualStrings(note_format, format);
        try sink.set("{\"note\":1}");
    }
    fn begin(self: *Smoke) !void {
        const lazy: transfer.Provider = .{ .context = self, .render = render };
        const refused = [_]transfer.Item{.{ .representations = &.{.fromBytes("application/x-ziggurat-other", "x")} }};
        const items = [_]transfer.Item{
            .{ .representations = &.{ .fromBytes(transfer.text, "hello"), .lazy(note_format, lazy) } },
            .{ .representations = &.{.fromBytes(transfer.text, "world")} },
        };
        var preview: [8 * 8 * 4]u8 = @splat(0x80);
        const data: transfer.Data = .{ .items = if (self.round == .refused) &refused else &items };
        try self.source.start(self.allocator, self.source_window, data, .{
            .operations = .copy_move,
            .preview = .{ .pixels = &preview, .width = 8, .height = 8, .hotspot_x = 4, .hotspot_y = 4 },
            .context = self,
            .on_done = done,
        });
        try std.testing.expectError(error.AlreadyStarted, self.source.start(self.allocator, self.source_window, data, .{}));
        var other: drag.Source = .{};
        try std.testing.expectError(error.DragActive, other.start(self.allocator, self.target_window, data, .{}));
        self.started += 1;
    }
    fn done(ptr: ?*anyopaque, source: *drag.Source, result: drag.Result) void {
        const self: *Smoke = @ptrCast(@alignCast(ptr.?));
        std.testing.expect(!source.running() and drag.current() == null) catch |err| return self.finish(err);
        self.done_calls += 1;
        if (self.results[@backingInt(self.round)] != null) return self.finish(error.DoneTwice);
        self.results[@backingInt(self.round)] = result;
    }
    fn hover(ptr: *anyopaque, _: z.Window, value: drop.DataHover) bool {
        const self: *Smoke = @ptrCast(@alignCast(ptr));
        if (value.phase == .leave) {
            self.left += 1;
            return false;
        }
        self.hovers += 1;
        if (value.local) self.local_hovers += 1;
        return true;
    }
    fn dropped(ptr: *anyopaque, _: z.Window, value: drop.DataDrop) bool {
        const self: *Smoke = @ptrCast(@alignCast(ptr));
        self.drops += 1;
        self.last_drop = value;
        self.dropped_items = value.data.items.len;
        const note = value.data.read(self.allocator, note_format) catch "";
        defer if (note.len != 0) self.allocator.free(note);
        @memcpy(self.dropped_note[0..note.len], note);
        self.dropped_note_len = note.len;
        const text = value.data.read(self.allocator, transfer.text) catch "";
        defer if (text.len != 0) self.allocator.free(text);
        @memcpy(self.dropped_text[0..text.len], text);
        self.dropped_text_len = text.len;
        const paths = transfer.files(self.allocator, value.data) catch "";
        defer if (paths.len != 0) self.allocator.free(paths);
        @memcpy(self.dropped_files[0..paths.len], paths);
        self.dropped_files_len = paths.len;
        self.last_drop.?.data = .{};
        return true;
    }

    fn legacyDrop(ptr: *anyopaque, _: z.Window, value: drop.Drop) void {
        const self: *Smoke = @ptrCast(@alignCast(ptr));
        self.legacy_drops += 1;
        if (value.payload == .text) {
            @memcpy(self.legacy_text[0..value.payload.text.len], value.payload.text);
            self.legacy_text_len = value.payload.text.len;
        }
    }
    fn ticker(self: *Smoke) void {
        while (!self.stop.load(.acquire)) {
            zio.sleep(25 * std.time.ns_per_ms);
            self.app.post(.{ .context = self, .call = tick }) catch return;
        }
    }
    fn tick(ptr: *anyopaque) void {
        const self: *Smoke = @ptrCast(@alignCast(ptr));
        if (self.stage == .done) return;
        self.advance() catch |err| return self.finish(err);
        self.waited += 1;
        if (self.waited > 800) {
            std.debug.print("drag smoke: stuck in round {s} at {s}; source {s}, hovers {d}, left {d}\n", .{ @tagName(self.round), @tagName(self.stage), @tagName(self.source.state), self.hovers, self.left });
            self.finish(error.Timeout);
        }
    }
    fn to(self: *Smoke, stage: Stage) void {
        self.stage = stage;
        self.waited = 0;
        self.step = 0;
    }
    fn finish(self: *Smoke, failure: ?anyerror) void {
        if (self.stage == .done) return;
        if (failure) |err| std.debug.print("drag smoke: round {s} stage {s}: {s}\n", .{ @tagName(self.round), @tagName(self.stage), @errorName(err) });
        self.failure = failure;
        self.stage = .done;
        self.stop.store(true, .release);
        if (self.held) self.input.press(false);
        if (self.round == .move) self.input.keyEvent(0xffe1, false);
        self.app.quit();
    }
    fn center(self: *Smoke, window: z.Window) !z.ScreenPoint {
        const bounds = try window.clientBounds();
        const origin = bounds.position orelse return error.PositionUnavailable;
        return screenAt(origin, @intCast(bounds.width / 2), @intCast(bounds.height / 2), self.scale);
    }
    fn destination(self: *Smoke) !z.ScreenPoint {
        // Below the windows, over none of them.
        if (self.round == .no_target) return screenAt(.{ .x = 440, .y = 700 }, 0, 0, self.scale);
        if (self.round == .legacy) return self.center(self.legacy_window);
        return self.center(self.target_window);
    }

    fn advance(self: *Smoke) !void {
        switch (self.stage) {
            .settle => if (self.waited > 12) self.to(.press),
            .press => {
                const start = try self.center(self.source_window);
                self.input.pointer(start);
                self.input.press(true);
                self.held = false;
                self.want_start = true;
                self.to(.start);
            },
            .start => {
                // Small moves inside the source until it starts the drag.
                const start = try self.center(self.source_window);
                self.step += 1;
                self.input.pointer(.{ .x = start.x + @as(i32, @intCast(self.step % 8)) * 3, .y = start.y });
                if (self.source.running() and self.source.state == .running) self.to(.travel);
            },
            .travel => {
                const from = try self.center(self.source_window);
                const end = try self.destination();
                self.step += 1;
                const steps = 12;
                const t = @min(self.step, steps);
                self.input.pointer(.{ .x = from.x + @divTrunc((end.x - from.x) * @as(i32, @intCast(t)), steps), .y = from.y + @divTrunc((end.y - from.y) * @as(i32, @intCast(t)), steps) });
                if (self.round == .escape and self.step == 4) {
                    self.input.keyEvent(0xff1b, true);
                    self.input.keyEvent(0xff1b, false);
                    self.to(.release);
                } else if (self.round == .cancel and self.step == 4) {
                    self.source.cancel();
                    try std.testing.expect(!self.source.running());
                    self.to(.release);
                } else if (t == steps) self.to(.over);
            },
            .over => {
                // Wiggle over the destination until GTK has a status for it.
                const end = try self.destination();
                self.step += 1;
                self.input.pointer(.{ .x = end.x + @as(i32, @intCast(self.step % 4)), .y = end.y });
                if (self.round == .move and self.step == 2) self.input.keyEvent(0xffe1, true);
                if (self.step > 10 and (self.round == .no_target or self.round == .legacy or self.hovers > 0)) self.to(.release);
            },
            .release => if (self.waited > 2) {
                self.input.press(false);
                self.to(.wait_done);
            },
            .wait_done => if (self.results[@backingInt(self.round)] != null and self.waited > 6) {
                // Shift stays down until the drop is over: OLE reads the
                // key state when it handles the button release, which may
                // be after a key release queued right behind it.
                if (self.round == .move) self.input.keyEvent(0xffe1, false);
                try self.check();
                self.to(.next);
            },
            .next => {
                self.hovers = 0;
                self.local_hovers = 0;
                self.drops = 0;
                self.dropped_items = 0;
                self.dropped_note_len = 0;
                self.dropped_text_len = 0;
                self.round = @fromBackingInt(@intCast(@backingInt(self.round) + 1));
                if (self.round != .external) return self.to(.settle);
                // Another process drags into the target with real XDND.
                const exe = try zio.executablePathAlloc(self.allocator);
                defer self.allocator.free(exe);
                self.child = try zio.spawn(.{ .argv = &.{ exe, "--source" } });
                const waiter = try std.Thread.spawn(.{}, waitChild, .{self});
                waiter.detach();
                self.to(.external);
            },
            .external => if (self.child_exit.load(.acquire) >= 0) {
                try std.testing.expectEqual(0, self.child_exit.load(.acquire));
                try std.testing.expectEqual(1, self.drops);
                try std.testing.expect(!self.last_drop.?.local);
                try std.testing.expectEqual(transfer.Operation.copy, self.last_drop.?.operation);
                // Another process's items arrive as one.
                try std.testing.expectEqual(1, self.dropped_items);
                try std.testing.expectEqualStrings("from another process", self.dropped_text[0..self.dropped_text_len]);
                try std.testing.expectEqualStrings("{\"note\":2}", self.dropped_note[0..self.dropped_note_len]);
                try std.testing.expectEqualStrings("/tmp/drag smoke & more.txt", self.dropped_files[0..self.dropped_files_len]);
                return self.finish(null);
            },
            .done => {},
        }
    }
    fn waitChild(self: *Smoke) void {
        const term = self.child.?.wait(zio.io()) catch return self.child_exit.store(99, .release);
        self.child_exit.store(switch (term) {
            .exited => |code| code,
            else => 98,
        }, .release);
    }
    fn check(self: *Smoke) !void {
        const result = self.results[@backingInt(self.round)].?;
        if (result.err) |err| return err;
        switch (self.round) {
            .copy, .move => {
                try std.testing.expectEqual(if (self.round == .copy) transfer.Operation.copy else .move, result.operation);
                try std.testing.expect(!result.canceled and !result.escaped);
                try std.testing.expectEqual(1, self.drops);
                try std.testing.expect(self.local_hovers > 0 and self.last_drop.?.local);
                try std.testing.expectEqual(result.operation, self.last_drop.?.operation);
                // Both items survive a drag within the process.
                try std.testing.expectEqual(2, self.dropped_items);
                try std.testing.expectEqualStrings("hello\nworld", self.dropped_text[0..self.dropped_text_len]);
                try std.testing.expectEqualStrings("{\"note\":1}", self.dropped_note[0..self.dropped_note_len]);
                try std.testing.expectEqual(@as(u32, @backingInt(self.round)) + 1, self.renders);
            },
            .escape, .cancel => {
                try std.testing.expectEqual(transfer.Operation.none, result.operation);
                try std.testing.expect(result.canceled and result.escaped);
                try std.testing.expectEqual(0, self.drops);
            },
            .legacy => {
                // The files-and-text target takes the text of the same drag.
                try std.testing.expectEqual(transfer.Operation.copy, result.operation);
                try std.testing.expectEqual(1, self.legacy_drops);
                try std.testing.expectEqualStrings("hello\nworld", self.legacy_text[0..self.legacy_text_len]);
                try std.testing.expectEqual(0, self.drops);
            },
            .external => unreachable,
            .no_target, .refused => {
                try std.testing.expectEqual(transfer.Operation.none, result.operation);
                try std.testing.expect(result.canceled and !result.escaped);
                try std.testing.expectEqual(0, self.drops);
            },
        }
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    var args = try init.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    if (args.next()) |arg| if (std.mem.eql(u8, arg, "--source")) {
        try exitAfter("drag smoke source", 120);
        return Other.main(allocator);
    };
    try exitAfter("drag smoke", 240);
    const app = try z.App.init(allocator);
    defer app.deinit();
    var smoke: Smoke = .{ .app = app, .allocator = allocator };
    smoke.input = try Input.open();
    defer smoke.input.close();

    smoke.source_window = try app.createWindow(.{ .title = "drag source", .width = 300, .height = 220 });
    try smoke.source_window.setClientBounds(.{ .position = .{ .x = 60, .y = 80 }, .width = 300, .height = 220 });
    try smoke.source_window.setContent(.{ .context = &smoke, .event = Smoke.event, .detach = Smoke.detach });
    try smoke.source_window.perform(.show);
    smoke.target_window = try app.createWindow(.{ .title = "drop target", .width = 300, .height = 220 });
    try smoke.target_window.setClientBounds(.{ .position = .{ .x = 520, .y = 80 }, .width = 300, .height = 220 });
    try smoke.target_window.perform(.show);
    smoke.scale = try windowScale(smoke.source_window);

    smoke.target = .{ .context = &smoke, .on_drop = Smoke.dropped, .on_hover = Smoke.hover, .formats = &.{ note_format, transfer.text, transfer.file_list }, .operations = .copy_move, .allocator = allocator };
    try smoke.target.attach(smoke.target_window);
    smoke.legacy_window = try app.createWindow(.{ .title = "text target", .width = 300, .height = 200 });
    try smoke.legacy_window.setClientBounds(.{ .position = .{ .x = 520, .y = 420 }, .width = 300, .height = 200 });
    try smoke.legacy_window.perform(.show);
    smoke.legacy = .{ .context = &smoke, .on_drop = Smoke.legacyDrop, .kinds = .{ .files = false }, .buffer = &smoke.legacy_buffer };
    try smoke.legacy.attach(smoke.legacy_window);
    defer smoke.legacy.detach();
    defer smoke.target.detach();
    var second: drop.DataTarget = .{ .context = &smoke, .on_drop = Smoke.dropped, .formats = &.{transfer.text}, .allocator = allocator };
    try std.testing.expectError(error.AlreadyAttached, second.attach(smoke.target_window));
    try std.testing.expect(drop.Target.registered(smoke.target_window));

    const thread = try std.Thread.spawn(.{}, Smoke.ticker, .{&smoke});
    try app.run();
    smoke.stop.store(true, .release);
    thread.join();
    if (smoke.failure) |err| return err;
    try std.testing.expectEqual(7, smoke.done_calls);
    try std.testing.expectEqual(7, smoke.started);
    std.debug.print("drag smoke passed: copy and move with every item and one lazy render each, escape, cancel, no target, refused offer, a files-and-text target, a drop from another process\n", .{});
}

/// The other process: drags text, a note and a file into the first
/// process's target window and exits 0 once the drag was copied.
const Other = struct {
    app: *z.App,
    allocator: std.mem.Allocator,
    window: z.Window = undefined,
    source: drag.Source = .{},
    input: Input = undefined,
    scale: f32 = 1,
    stage: Stage = .settle,
    waited: u32 = 0,
    step: u32 = 0,
    held: bool = false,
    want_start: bool = false,
    result: ?drag.Result = null,
    failure: ?anyerror = null,
    stop: std.atomic.Value(bool) = .init(false),

    fn event(ptr: *anyopaque, _: z.Window, value: z.Event) void {
        const self: *Other = @ptrCast(@alignCast(ptr));
        switch (value) {
            .pointer_down => self.held = true,
            .pointer_up => self.held = false,
            .pointer_move => if (self.held and self.want_start) {
                self.want_start = false;
                self.begin() catch |err| self.end(err);
            },
            else => {},
        }
    }
    fn detach(_: *anyopaque) void {}
    fn begin(self: *Other) !void {
        const url = "file:///tmp/drag%20smoke%20&%20more.txt";
        const items = [_]transfer.Item{.{ .representations = &.{ .fromBytes(transfer.text, "from another process"), .fromBytes(note_format, "{\"note\":2}"), .fromBytes(transfer.file_list, url), .fromBytes(transfer.uri_list, url) } }};
        try self.source.start(self.allocator, self.window, .{ .items = &items }, .{ .context = self, .on_done = done });
    }
    fn done(ptr: ?*anyopaque, _: *drag.Source, result: drag.Result) void {
        const self: *Other = @ptrCast(@alignCast(ptr.?));
        self.result = result;
    }
    fn end(self: *Other, failure: ?anyerror) void {
        if (self.stage == .done) return;
        self.failure = failure;
        self.stage = .done;
        self.stop.store(true, .release);
        if (self.held) self.input.press(false);
        self.app.quit();
    }
    fn ticker(self: *Other) void {
        while (!self.stop.load(.acquire)) {
            zio.sleep(25 * std.time.ns_per_ms);
            self.app.post(.{ .context = self, .call = tick }) catch return;
        }
    }
    fn tick(ptr: *anyopaque) void {
        const self: *Other = @ptrCast(@alignCast(ptr));
        if (self.stage == .done) return;
        self.advance() catch |err| return self.end(err);
        self.waited += 1;
        if (self.waited > 400) self.end(error.Timeout);
    }
    fn to(self: *Other, stage: Stage) void {
        self.stage = stage;
        self.waited = 0;
        self.step = 0;
    }
    fn advance(self: *Other) !void {
        const bounds = try self.window.clientBounds();
        const origin = bounds.position orelse return error.PositionUnavailable;
        const from = screenAt(origin, 150, 100, self.scale);
        // The first process's target window, as it placed it.
        const end_point = screenAt(.{ .x = 520, .y = 80 }, 150, 110, self.scale);
        switch (self.stage) {
            .settle => if (self.waited > 12) self.to(.press),
            .press => {
                self.input.pointer(from);
                self.input.press(true);
                self.want_start = true;
                self.to(.start);
            },
            .start => {
                self.step += 1;
                self.input.pointer(.{ .x = from.x + @as(i32, @intCast(self.step % 8)) * 3, .y = from.y });
                if (self.source.state == .running) self.to(.travel);
            },
            .travel => {
                self.step += 1;
                const t: i32 = @intCast(@min(self.step, 12));
                self.input.pointer(.{ .x = from.x + @divTrunc((end_point.x - from.x) * t, 12), .y = from.y + @divTrunc((end_point.y - from.y) * t, 12) });
                if (t == 12) self.to(.over);
            },
            .over => {
                self.step += 1;
                self.input.pointer(.{ .x = end_point.x + @as(i32, @intCast(self.step % 4)), .y = end_point.y });
                if (self.step > 16) self.to(.release);
            },
            .release => {
                self.input.press(false);
                self.held = false;
                self.to(.wait_done);
            },
            .wait_done => if (self.result) |result| {
                if (result.err) |err| return err;
                try std.testing.expectEqual(transfer.Operation.copy, result.operation);
                self.end(null);
            },
            else => {},
        }
    }

    fn main(allocator: std.mem.Allocator) !void {
        const app = try z.App.init(allocator);
        defer app.deinit();
        var other: Other = .{ .app = app, .allocator = allocator };
        other.input = try Input.open();
        defer other.input.close();
        other.window = try app.createWindow(.{ .title = "other drag source", .width = 300, .height = 200 });
        try other.window.setClientBounds(.{ .position = .{ .x = 60, .y = 420 }, .width = 300, .height = 200 });
        try other.window.setContent(.{ .context = &other, .event = event, .detach = detach });
        try other.window.perform(.show);
        other.scale = try windowScale(other.window);
        const thread = try std.Thread.spawn(.{}, ticker, .{&other});
        try app.run();
        other.stop.store(true, .release);
        thread.join();
        if (other.failure) |err| return err;
    }
};
