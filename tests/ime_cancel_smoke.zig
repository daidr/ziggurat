const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const d = @import("ziggurat_document");
const editing = @import("ziggurat_document_editor");
const t = @import("ziggurat_text_layout");
const c = @import("ziggurat_c_win32");

const Action = enum { none, start, replace, close, native_close };
const Client = struct {
    fixture: *Fixture,
    unbound: usize = 0,
    fn descriptor(self: *Client) z.TextClient {
        return .{ .context = self, .owner = self.fixture.app.?.owner, .read = read, .change = change, .unbound = removed };
    }
    fn read(_: *anyopaque, _: z.Window, destination: []u8) !z.text.Snapshot {
        if (destination.len == 0) return error.CapacityExceeded;
        destination[0] = 'x';
        return .{ .range = .{ .start = 0, .end = 1 }, .selection = .{ .anchor = 0, .caret = 0 }, .revision = 1, .bytes = 1 };
    }
    fn change(_: *anyopaque, _: z.Window, _: z.text.Change) !z.text.ChangeResult {
        return .applied;
    }
    fn removed(ptr: *anyopaque, _: z.Window, _: z.text.UnbindReason) void {
        const self: *Client = @ptrCast(@alignCast(ptr));
        self.unbound += 1;
        self.fixture.unbound_context_clean = self.fixture.unbound_context_clean and !self.fixture.context.composing;
    }
};
const Fixture = struct {
    app: ?*z.App = null,
    window: z.Window = undefined,
    hwnd: c.HWND = null,
    context: ui.Context = undefined,
    input_context: c.HIMC = null,
    previous_context: c.HIMC = null,
    clients: [2]Client = undefined,
    token: z.TextClientToken = undefined,
    replacement: ?z.TextClientToken = null,
    action: Action = .none,
    cancellations: usize = 0,
    key_inputs: usize = 0,
    closes: usize = 0,
    diagnostics: usize = 0,
    cleared_before_callback: bool = true,
    unbound_context_clean: bool = true,
    failure: ?anyerror = null,
    fn init(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.* = .{};
        self.app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = self, .emit = diagnostic } });
        errdefer self.deinit();
        self.window = try self.app.?.createWindow(.{ .width = 240, .height = 120, .on_closed = .{ .context = self, .notify = closed } });
        self.hwnd = self.window.nativeHandle();
        self.context = ui.Context.init(self, draw, onAction);
        self.context.on_input = input;
        try self.context.attach(self.window);
        // Thread-local focus works on the private desktop. Foreground
        // activation belongs to the input desktop and is not this test.
        _ = c.SetFocus(self.hwnd);
        try std.testing.expect(c.GetFocus() == self.hwnd);
        self.input_context = c.ImmCreateContext() orelse return error.InputContextUnavailable;
        self.previous_context = c.ImmAssociateContext(self.hwnd, self.input_context);
        self.clients = .{ .{ .fixture = self }, .{ .fixture = self } };
        self.token = try self.window.setTextClient(self.clients[0].descriptor());
    }
    fn deinit(self: *Fixture) void {
        if (self.app) |app| {
            if (self.input_context != null) {
                if (c.IsWindow(self.hwnd) != 0) _ = c.ImmAssociateContext(self.hwnd, self.previous_context);
                std.debug.assert(c.ImmDestroyContext(self.input_context) != 0);
                self.input_context = null;
            }
            if (c.IsWindow(self.hwnd) != 0) _ = self.window.destroy() catch unreachable;
            app.dispatch() catch unreachable;
            std.debug.assert(app.resourceStats().allocated_records == 0);
            app.deinit();
            self.app = null;
        }
    }
    fn record(self: *Fixture) *z.WindowRecord {
        return @ptrFromInt(@as(usize, @bitCast(c.GetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA))));
    }
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *Fixture = @ptrCast(@alignCast(ptr));
        self.diagnostics += 1;
        if (value.err) |err| self.failure = err;
    }
    fn closed(ptr: *anyopaque, _: z.Window) void {
        const self: *Fixture = @ptrCast(@alignCast(ptr));
        self.closes += 1;
    }
    fn draw(_: *anyopaque, frame: *ui.Frame) void {
        frame.clear(0xffffff);
    }
    fn onAction(_: *anyopaque, _: u64) void {}
    fn input(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *Fixture = @ptrCast(@alignCast(ptr));
        if (event == .text_preedit_revoked) {
            self.failure = error.RevocationReachedBusinessInput;
            return true;
        }
        if (event == .key_input) self.key_inputs += 1;
        if (event != .text_preedit_cancel) return false;
        self.cancellations += 1;
        const native = &self.record().native.text;
        self.cleared_before_callback = self.cleared_before_callback and !native.composing and native.high_surrogate == null and native.reconversion == null and !self.context.composing;
        const next = self.action;
        self.action = .none;
        switch (next) {
            .none => {},
            .start => self.start(),
            .replace => {
                self.replacement = self.window.setTextClient(self.clients[1].descriptor()) catch |err| {
                    self.failure = err;
                    return true;
                };
                self.start();
            },
            .close => _ = self.window.destroy() catch |err| {
                self.failure = err;
                return true;
            },
            .native_close => if (c.DestroyWindow(self.hwnd) == 0) {
                self.failure = error.NativeDestroyFailed;
            },
        }
        return false;
    }
    fn start(self: *Fixture) void {
        _ = c.SendMessageW(self.hwnd, c.WM_IME_STARTCOMPOSITION, 0, 0);
        // Message-level IME lifecycle and the real Context event bridge are
        // exercised without requiring an installed language engine.
        self.record().emit(.{ .text_preedit = .{ .text = "文", .selection_start = 3, .selection_end = 3 } });
        _ = c.SendMessageW(self.hwnd, c.WM_CHAR, 0xd83d, 0);
    }
    fn tab(self: *Fixture) !void {
        var previous: [256]u8 = undefined;
        try std.testing.expect(c.GetKeyboardState(&previous) != 0);
        defer _ = c.SetKeyboardState(&previous);
        var clean: [256]u8 = @splat(0);
        try std.testing.expect(c.SetKeyboardState(&clean) != 0);
        _ = c.SendMessageW(self.hwnd, c.WM_KEYDOWN, c.VK_TAB, 0);
    }
    fn offer(self: *Fixture) !void {
        const required = c.SendMessageW(self.hwnd, c.WM_IME_REQUEST, c.IMR_RECONVERTSTRING, 0);
        try std.testing.expect(required >= @sizeOf(c.RECONVERTSTRING) and required <= 256);
        var storage: [256]u8 align(@alignOf(c.RECONVERTSTRING)) = @splat(0);
        const header: *c.RECONVERTSTRING = @ptrCast(&storage);
        header.dwSize = @intCast(required);
        try std.testing.expectEqual(required, c.SendMessageW(self.hwnd, c.WM_IME_REQUEST, c.IMR_RECONVERTSTRING, @bitCast(@intFromPtr(&storage))));
        try std.testing.expect(self.record().native.text.reconversion != null);
    }
    fn check(self: *Fixture) !void {
        if (self.failure) |err| return err;
        try std.testing.expect(self.cleared_before_callback);
        try std.testing.expect(self.unbound_context_clean);
    }
};

fn run(allocator: std.mem.Allocator) !void {
    const fixture = try allocator.create(Fixture);
    defer allocator.destroy(fixture);
    try fixture.init(allocator);
    defer fixture.deinit();
    try fixture.offer();
    fixture.start();
    const before = fixture.key_inputs;
    try fixture.tab();
    try std.testing.expectEqual(before, fixture.key_inputs);
    try fixture.window.cancelTextComposition();
    try std.testing.expectEqual(@as(usize, 1), fixture.cancellations);
    try std.testing.expect(!fixture.context.composing and !fixture.record().native.text.composing);
    try std.testing.expect(fixture.record().native.text.high_surrogate == null and fixture.record().native.text.reconversion == null);
    try std.testing.expect(try fixture.window.hasTextClient());
    _ = c.SendMessageW(fixture.hwnd, c.WM_IME_ENDCOMPOSITION, 0, 0);
    try fixture.window.cancelTextComposition();
    try std.testing.expectEqual(@as(usize, 1), fixture.cancellations);
    try fixture.tab();
    try std.testing.expectEqual(before + 1, fixture.key_inputs);
    try fixture.check();
}
fn rebind(allocator: std.mem.Allocator, missing_context: bool) !void {
    const fixture = try allocator.create(Fixture);
    defer allocator.destroy(fixture);
    try fixture.init(allocator);
    defer fixture.deinit();
    fixture.start();
    if (missing_context) _ = c.ImmAssociateContext(fixture.hwnd, null);
    if (missing_context) {
        try std.testing.expectError(error.InputContextUnavailable, fixture.window.clearTextClient(fixture.token));
    } else try std.testing.expect(try fixture.window.clearTextClient(fixture.token));
    try std.testing.expect(!(try fixture.window.hasTextClient()));
    try std.testing.expectEqual(@as(usize, 1), fixture.clients[0].unbound);
    // Core revocation is a lifecycle notification, not another edit routed to
    // the old client. Context clears its flag before client.unbound runs.
    try std.testing.expectEqual(@as(usize, 0), fixture.cancellations);
    try std.testing.expect(!fixture.record().native.text.composing and !fixture.context.composing);
    if (missing_context) _ = c.ImmAssociateContext(fixture.hwnd, fixture.input_context);
    const current = try fixture.window.setTextClient(fixture.clients[1].descriptor());
    try std.testing.expect(current.generation > fixture.token.generation);
    try std.testing.expect(!try fixture.window.clearTextClient(fixture.token));
    try fixture.tab();
    try std.testing.expectEqual(@as(usize, 1), fixture.key_inputs);
    try fixture.check();
}
fn legacy(allocator: std.mem.Allocator) !void {
    const fixture = try allocator.create(Fixture);
    defer allocator.destroy(fixture);
    try fixture.init(allocator);
    defer fixture.deinit();
    try std.testing.expect(try fixture.window.clearTextClient(fixture.token));
    fixture.start();
    try fixture.window.cancelTextComposition();
    try std.testing.expectEqual(@as(usize, 1), fixture.cancellations);
    try std.testing.expect(!fixture.context.composing and !fixture.record().native.text.composing);
    try std.testing.expect(!(try fixture.window.hasTextClient()));
    try fixture.check();
}
fn callback(allocator: std.mem.Allocator, requested: Action, focus_loss: bool) !void {
    const fixture = try allocator.create(Fixture);
    defer allocator.destroy(fixture);
    try fixture.init(allocator);
    defer fixture.deinit();
    fixture.start();
    fixture.action = requested;
    if (focus_loss) {
        _ = c.SendMessageW(fixture.hwnd, c.WM_KILLFOCUS, 0, 0);
    } else if (requested == .close or requested == .native_close) {
        try std.testing.expectError(error.Closed, fixture.window.cancelTextComposition());
    } else try fixture.window.cancelTextComposition();
    if (requested == .close or requested == .native_close) {
        try fixture.app.?.dispatch();
        try std.testing.expect(fixture.window.isClosed());
        try std.testing.expectEqual(@as(usize, 1), fixture.closes);
        try std.testing.expectEqual(@as(usize, 0), fixture.diagnostics);
        try std.testing.expectEqual(@as(usize, 1), fixture.cancellations);
        try std.testing.expectEqual(@as(usize, 0), fixture.app.?.resourceStats().allocated_records);
    } else if (focus_loss) {
        // Real loss of input authority revokes the client even if a cancel
        // callback started another composition on this same window.
        try std.testing.expect(!(try fixture.window.hasTextClient()));
        try std.testing.expect(!fixture.record().native.text.composing and !fixture.context.composing);
        try std.testing.expectEqual(@as(usize, 1), fixture.cancellations);
    } else {
        try std.testing.expectEqual(@as(usize, 1), fixture.cancellations);
        try std.testing.expect(fixture.record().native.text.composing and fixture.context.composing);
        try std.testing.expectEqual(@as(?u16, 0xd83d), fixture.record().native.text.high_surrogate);
        if (requested == .replace) {
            try std.testing.expectEqual(@as(usize, 1), fixture.clients[0].unbound);
            try std.testing.expect(!try fixture.window.clearTextClient(fixture.token));
            try std.testing.expectEqual(fixture.replacement.?.generation, fixture.window.textClientToken().?.generation);
        }
        try fixture.tab();
        try std.testing.expectEqual(@as(usize, 0), fixture.key_inputs);
        try fixture.window.cancelTextComposition();
        try std.testing.expectEqual(@as(usize, 2), fixture.cancellations);
    }
    try fixture.check();
}

const Owner = struct {
    window: z.Window = undefined,
    context: ui.Context = undefined,
    adapter: ?*editing.Adapter = null,
    cancellations: usize = 0,
    failure: ?anyerror = null,
    const bounds: ui.Rect = .{ .x = 0, .y = 0, .width = 200, .height = 80 };
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *Owner = @ptrCast(@alignCast(ptr));
        if (value.err) |err| self.failure = err;
    }
    fn draw(_: *anyopaque, frame: *ui.Frame) void {
        frame.clear(0xffffff);
    }
    fn action(_: *anyopaque, _: u64) void {}
    fn input(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *Owner = @ptrCast(@alignCast(ptr));
        if (event == .text_preedit_revoked) {
            self.failure = error.RevocationReachedBusinessInput;
            return true;
        }
        switch (event) {
            .text_preedit, .text_preedit_cancel => {},
            else => return false,
        }
        if (event == .text_preedit_cancel) self.cancellations += 1;
        const adapter = self.adapter orelse return false;
        return adapter.handleEvent(self.window, event, bounds, .{}) catch |err| {
            self.failure = err;
            return true;
        };
    }
};
fn documentOwner(allocator: std.mem.Allocator, mode: enum { cancel, unbind, close }) !void {
    const state = try allocator.create(Owner);
    state.* = .{};
    defer allocator.destroy(state);
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = state, .emit = Owner.diagnostic } });
    defer app.deinit();
    const engine = try t.Engine.create(allocator, app.owner, .{});
    defer engine.close() catch unreachable;
    const document = try d.Document.create(allocator, app.owner, "x", .{});
    defer document.close() catch unreachable;
    state.adapter = try editing.Adapter.create(allocator, document, engine, .{});
    defer if (state.adapter) |adapter| adapter.close() catch unreachable;
    state.window = try app.createWindow(.{ .width = 240, .height = 120 });
    defer {
        if (!state.window.isClosed()) _ = state.window.destroy() catch unreachable;
        app.dispatch() catch unreachable;
        std.debug.assert(app.resourceStats().allocated_records == 0);
    }
    state.context = ui.Context.init(state, Owner.draw, Owner.action);
    state.context.on_input = Owner.input;
    try state.context.attach(state.window);
    const hwnd: c.HWND = state.window.nativeHandle();
    _ = c.SetFocus(hwnd);
    try std.testing.expect(c.GetFocus() == hwnd);
    _ = try state.adapter.?.prepare(Owner.bounds, .{});
    try state.adapter.?.bind(state.window);
    const token = state.window.textClientToken().?;
    const text_version = try document.committedTextVersion();
    _ = c.SendMessageW(hwnd, c.WM_IME_STARTCOMPOSITION, 0, 0);
    const record: *z.WindowRecord = @ptrFromInt(@as(usize, @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA))));
    record.emit(.{ .text_preedit = .{ .text = "文", .selection_start = 3, .selection_end = 3 } });
    if (state.failure) |err| return err;
    try std.testing.expect(try document.composition() != null);
    try std.testing.expect(state.context.composing);
    switch (mode) {
        .cancel => try state.window.cancelTextComposition(),
        .unbind => try state.adapter.?.unbind(),
        .close => {
            _ = try state.window.destroy();
            try app.dispatch();
            try state.adapter.?.close();
            state.adapter = null;
        },
    }
    if (state.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, if (mode == .cancel) 1 else 0), state.cancellations);
    try std.testing.expect(try document.composition() == null);
    try std.testing.expect(!state.context.composing);
    if (mode != .close) try std.testing.expect(!record.native.text.composing);
    try std.testing.expectEqual(text_version, try document.committedTextVersion());
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqualStrings("x", bytes[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &bytes)]);
    try std.testing.expect(!try document.undo());
    if (mode == .cancel) {
        try std.testing.expectEqual(token.generation, state.window.textClientToken().?.generation);
        try state.adapter.?.unbind();
    } else if (mode == .close) {
        try std.testing.expectError(error.Closed, state.window.hasTextClient());
    } else try std.testing.expect(!(try state.window.hasTextClient()));
}

fn isolatedWindows() !void {
    var name: [80]u8 = undefined;
    const label = try std.fmt.bufPrint(&name, "Ziggurat.ImeCancel.{d}", .{c.GetCurrentProcessId()});
    var wide: [80:0]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&wide, label);
    wide[length] = 0;
    const desktop = c.CreateDesktopW(&wide, null, null, 0, c.DESKTOP_CREATEWINDOW | c.DESKTOP_CREATEMENU | c.DESKTOP_READOBJECTS | c.DESKTOP_WRITEOBJECTS, null);
    if (desktop == null) return error.CreateDesktopFailed;
    defer std.debug.assert(c.CloseDesktop(desktop) != 0);
    var executable: [32768:0]u16 = undefined;
    const count = c.GetModuleFileNameW(null, &executable, executable.len);
    if (count == 0 or count >= executable.len) return error.ExecutablePathUnavailable;
    var command: [32768:0]u16 = undefined;
    command[0] = '"';
    @memcpy(command[1 .. count + 1], executable[0..count]);
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\" --desktop-child");
    @memcpy(command[count + 1 .. count + 1 + suffix.len], suffix);
    command[count + 1 + suffix.len] = 0;
    var startup = std.mem.zeroes(c.STARTUPINFOW);
    startup.cb = @sizeOf(c.STARTUPINFOW);
    startup.lpDesktop = &wide;
    startup.dwFlags = c.STARTF_USESTDHANDLES;
    startup.hStdInput = c.GetStdHandle(c.STD_INPUT_HANDLE);
    startup.hStdOutput = c.GetStdHandle(c.STD_OUTPUT_HANDLE);
    startup.hStdError = c.GetStdHandle(c.STD_ERROR_HANDLE);
    var process: c.PROCESS_INFORMATION = undefined;
    if (c.CreateProcessW(&executable, &command, null, null, c.TRUE, c.CREATE_NO_WINDOW, null, null, &startup, &process) == 0) return error.CreateTestProcessFailed;
    defer _ = c.CloseHandle(process.hThread);
    defer _ = c.CloseHandle(process.hProcess);
    if (c.WaitForSingleObject(process.hProcess, 60000) != c.WAIT_OBJECT_0) {
        _ = c.TerminateProcess(process.hProcess, 1);
        _ = c.WaitForSingleObject(process.hProcess, c.INFINITE);
        return error.TestProcessTimeout;
    }
    var exit_code: c.DWORD = 0;
    if (c.GetExitCodeProcess(process.hProcess, &exit_code) == 0 or exit_code != 0) return error.TestProcessFailed;
}
pub fn main(init: std.process.Init.Minimal) !void {
    const args = try zio.argsAlloc(std.heap.page_allocator, init.args);
    defer zio.argsFree(std.heap.page_allocator, args);
    if (args.len == 1) return isolatedWindows();
    if (args.len != 2 or !std.mem.eql(u8, args[1], "--desktop-child")) return error.InvalidArgument;
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    try run(allocator);
    try rebind(allocator, false);
    try rebind(allocator, true);
    try legacy(allocator);
    try callback(allocator, .start, false);
    try callback(allocator, .replace, false);
    try callback(allocator, .close, false);
    try callback(allocator, .native_close, false);
    try callback(allocator, .start, true);
    try callback(allocator, .close, true);
    try callback(allocator, .native_close, true);
    try documentOwner(allocator, .cancel);
    try documentOwner(allocator, .unbind);
    try documentOwner(allocator, .close);
    try std.testing.expectEqual(t.ResourceCounts{}, t.resourceCounts());
    std.debug.print("IMM cancellation: old local state/Context notification, clear/rebind/failure, callback START/client/close, focus loss and live IME key priority; resources=0\n", .{});
}
