const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const d = @import("ziggurat_document");
const e = @import("ziggurat_document_editor");
const t = @import("ziggurat_text_layout");
const ui = @import("ziggurat_ui");
const diff = @import("ziggurat_document_diff");
const v = @import("ziggurat_document_diff_view");
const a = @import("ziggurat_document_accessibility");
const paired = @import("ziggurat_document_diff_accessibility");
const c = @import("ziggurat_c_win32");
extern fn zdd_probe_auxiliary(*anyopaque, u32, *f64) i32;
extern fn zda_probe_release(*anyopaque) void;
extern fn zdd_probe_point_hit_mta(*anyopaque, *anyopaque, [*]const u16, u32, *u32, *u32) i32;
extern fn zdd_probe_auxiliary_hit_mta(*anyopaque, *anyopaque, f64, f64) i32;
const bounds: ui.Rect = .{ .x = 8, .y = 8, .width = 420, .height = 210 };
const original = "head\nold 😀\nsame 0\nsame 1\nsame 2\nsame 3\nsame 4\nsame 5\nsame 6\nsame 7\nsame 8\nsame 9\nsame 10\nlast";
const modified = "head\nnew 文\nsame 0\nsame 1\nsame 2\nsame 3\nsame 4\nsame 5\nsame 6\nsame 7\nsame 8\nsame 9\nsame 10\nlast";
const checkpoint = c.WM_APP + 119;
const trace_property = std.unicode.utf8ToUtf16LeStringLiteral("Ziggurat.DiffControls.TestTrace");
threadlocal var trace_window: c.HWND = null;
const Trace = struct {
    const Reason = enum { message, input_before, input_after };
    const Entry = struct {
        reason: Reason,
        message: u32,
        stage: u32,
        window_phase: z.WindowRecord.Phase,
        app_phase: @FieldType(z.App, "phase"),
        native_composing: bool,
        composing: bool,
        enabled_requested: bool,
        native_enabled: bool,
        allowed: bool,
        modal: bool,
        physical_client: bool,
        text_generation: u64,
        consumer: bool,
        modifiers: z.KeyModifiers,
        focused: ?u64,
        active: ?u64,
        hits: usize,
        target: u64,
        target_accepted: bool,
        frame: usize,
        front_candidate: u64,
        epoch: u64,
        needs_prepare: bool,
        bridge_busy: bool,
        key: ?z.KeyInput,
        err: ?anyerror,
    };
    state: *State,
    hwnd: c.HWND = null,
    hook: c.HHOOK = null,
    stage: u32 = 0,
    target: u64 = 0,
    total: u64 = 0,
    entries: [64]Entry = undefined,
    fn start(self: *Trace) !void {
        if (trace_window != null) return error.TraceBusy;
        self.hwnd = self.state.window.nativeHandle();
        if (c.SetPropW(self.hwnd, trace_property, self) == 0) return error.TracePropertyFailed;
        errdefer _ = c.RemovePropW(self.hwnd, trace_property);
        // NO_STRICT leaves HOOKPROC unprototyped; this callback keeps the
        // documented three-argument Win32 ABI.
        self.hook = c.SetWindowsHookExW(c.WH_GETMESSAGE, @ptrCast(&getMessage), null, c.GetCurrentThreadId());
        if (self.hook == null) return error.TraceHookFailed;
        trace_window = self.hwnd;
        self.state.trace = self;
    }
    fn stop(self: *Trace) void {
        self.state.trace = null;
        trace_window = null;
        if (self.hook != null) std.debug.assert(c.UnhookWindowsHookEx(self.hook) != 0);
        _ = c.RemovePropW(self.hwnd, trace_property);
        self.hook = null;
        self.hwnd = null;
    }
    fn getMessage(code: c_int, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
        if (code >= 0 and wp == c.PM_REMOVE and trace_window != null) {
            const message: *const c.MSG = @ptrFromInt(@as(usize, @bitCast(lp)));
            if (message.hwnd == trace_window and relevant(message.message, message.wParam)) {
                if (c.GetPropW(message.hwnd, trace_property)) |ptr| {
                    const self: *Trace = @ptrCast(@alignCast(ptr));
                    self.capture(.message, message.message, if (message.message == c.WM_KEYDOWN or message.message == c.WM_KEYUP or message.message == c.WM_SYSKEYDOWN or message.message == c.WM_SYSKEYUP) .{ .key = if (message.wParam == c.VK_TAB) .tab else .space, .modifiers = modifiers() } else null, null);
                }
            }
        }
        return c.CallNextHookEx(null, code, wp, lp);
    }
    fn relevant(kind: u32, key: usize) bool {
        return switch (kind) {
            c.WM_KEYDOWN, c.WM_KEYUP, c.WM_SYSKEYDOWN, c.WM_SYSKEYUP => key == c.VK_TAB or key == c.VK_SPACE,
            c.WM_IME_STARTCOMPOSITION, c.WM_IME_ENDCOMPOSITION, c.WM_IME_COMPOSITION, c.WM_ENABLE, c.WM_SETFOCUS, c.WM_KILLFOCUS, checkpoint => true,
            else => false,
        };
    }
    fn input(self: *Trace, reason: Reason, event: z.Event, err: ?anyerror) void {
        const kind: u32 = switch (event) {
            .key_input => |key| if (key.key == .tab or key.key == .space) c.WM_KEYDOWN else return,
            .key => |key| if (key == .tab) c.WM_KEYDOWN else return,
            .focus => |focused| if (focused) c.WM_SETFOCUS else c.WM_KILLFOCUS,
            .text_preedit => c.WM_IME_STARTCOMPOSITION,
            .text_preedit_cancel => c.WM_IME_ENDCOMPOSITION,
            .window_state => c.WM_ENABLE,
            else => return,
        };
        self.capture(reason, kind, if (event == .key_input) event.key_input else null, err);
    }
    fn capture(self: *Trace, reason: Reason, kind: u32, key: ?z.KeyInput, err: ?anyerror) void {
        const address = c.GetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA);
        if (address == 0) return;
        const record: *z.WindowRecord = @ptrFromInt(@as(usize, @bitCast(address)));
        if (record.native.hwnd != self.hwnd) return;
        const bridge = self.state.bridge orelse return;
        self.entries[self.total % self.entries.len] = .{
            .reason = reason,
            .message = kind,
            .stage = self.stage,
            .window_phase = record.phase,
            .app_phase = self.state.window.app.phase,
            .native_composing = record.native.text.composing,
            .composing = self.state.context.composing,
            .enabled_requested = record.enabled_requested,
            .native_enabled = c.IsWindowEnabled(self.hwnd) != 0,
            .allowed = record.inputAllowed(),
            .modal = record.blocked_by != null,
            .physical_client = record.text_client != null,
            .text_generation = record.text_generation,
            .consumer = if (record.content) |content| content.key_input != null else false,
            .modifiers = modifiers(),
            .focused = self.state.context.input_state.focused,
            .active = self.state.context.input_state.active,
            .hits = self.state.context.input_state.len,
            .target = self.target,
            .target_accepted = self.state.context.input_state.available(self.target),
            .frame = self.state.context.frames,
            .front_candidate = self.state.context.accessibility_source_state.frame_committed,
            .epoch = bridge.prepared_epoch,
            .needs_prepare = bridge.needs_prepare,
            .bridge_busy = bridge.busy,
            .key = key,
            .err = err,
        };
        self.total += 1;
    }
    fn modifiers() z.KeyModifiers {
        return .{ .shift = c.GetKeyState(c.VK_SHIFT) < 0, .control = c.GetKeyState(c.VK_CONTROL) < 0, .alt = c.GetKeyState(c.VK_MENU) < 0, .super = c.GetKeyState(c.VK_LWIN) < 0 or c.GetKeyState(c.VK_RWIN) < 0 };
    }
    fn dump(self: *const Trace) void {
        const first = self.total - @min(self.total, self.entries.len);
        for (first..self.total) |index| std.debug.print("diff control trace {d}: {any}\n", .{ index, self.entries[index % self.entries.len] });
    }
};
const Probe = struct {
    source: std.mem.Allocator,
    window: ?z.Window = null,
    target: ?*d.Document = null,
    adapter: ?*e.Adapter = null,
    action: enum { disable, quit, close } = .disable,
    fired: bool = false,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.window) |window| if (self.target) |document| {
            _ = document.version() catch |err| {
                if (err == error.Busy) {
                    self.window = null;
                    self.fired = true;
                    switch (self.action) {
                        .disable => window.perform(.disable) catch unreachable,
                        .quit => window.app.quit(),
                        .close => {
                            _ = window.destroy() catch unreachable;
                        },
                    }
                }
                return self.source.rawAlloc(len, alignment, ret);
            };
        };
        if (self.window) |window| if (self.adapter) |adapter| {
            _ = adapter.status() catch |err| {
                if (err == error.Busy) {
                    self.window = null;
                    self.fired = true;
                    window.perform(.disable) catch unreachable;
                }
                return self.source.rawAlloc(len, alignment, ret);
            };
        };
        return self.source.rawAlloc(len, alignment, ret);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.source.rawFree(bytes, alignment, ret);
    }
};
const State = struct {
    window: z.Window = undefined,
    context: ui.Context = undefined,
    view: *v.EditableSplit = undefined,
    bridge: ?*paired.Bridge = null,
    inbox: *v.Inbox = undefined,
    workspace: paired.controls.Controls = undefined,
    parameters: v.Parameters = .{ .font = .{ .size = 16, .wrap = .word_character } },
    expected: ?anyerror = null,
    failure: ?anyerror = null,
    fail_frame: bool = false,
    disabled: bool = false,
    calls: usize = 0,
    outcome: ?paired.controls.Outcome = null,
    last_key: ?z.KeyInput = null,
    trace: ?*Trace = null,
    fn recordError(self: *State, err: anyerror) void {
        if (self.expected) |wanted| {
            if (err != wanted) self.failure = err;
        } else self.failure = err;
    }
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value.err) |err| self.recordError(err);
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        frame.clear(0xffffff);
        if (self.bridge) |bridge| bridge.draw(frame, .{}) catch |err| {
            frame.failure = err;
            self.recordError(err);
        };
        if (self.fail_frame) frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0);
    }
    fn action(ptr: *anyopaque, id: u64) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.outcome = self.bridge.?.controlAction(id) catch |err| {
            self.recordError(err);
            return;
        };
        self.calls += 1;
        if (self.outcome) |outcome| if (outcome.changed) {
            self.publish() catch |err| {
                self.recordError(err);
                return;
            };
            self.prepare() catch |err| {
                self.recordError(err);
                return;
            };
        };
    }
    fn input(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *State = @ptrCast(@alignCast(ptr));
        var route_error: ?anyerror = null;
        if (self.trace) |trace| trace.input(.input_before, event, null);
        defer if (self.trace) |trace| trace.input(.input_after, event, route_error);
        if (event == .key_input) self.last_key = event.key_input;
        switch (event) {
            .cancel_input, .window_state, .window_position => return false,
            else => {},
        }
        const bridge = self.bridge orelse return false;
        const used = bridge.handleEvent(event, self.parameters) catch |err| {
            route_error = err;
            self.recordError(err);
            return true;
        };
        const needs_prepare = bridge.needsPrepare() catch |err| {
            if (err == error.Busy) return used;
            self.recordError(err);
            return true;
        };
        if (needs_prepare) self.prepare() catch |err| {
            self.recordError(err);
            return true;
        };
        return used;
    }
    fn publish(self: *State) !void {
        const job = try self.inbox.begin();
        var released = false;
        defer {
            if (!released) job.release() catch unreachable;
            _ = self.inbox.finish(job.ticket) catch unreachable;
        }
        var result = try diff.compare(std.heap.page_allocator, job.a, job.b, .{});
        defer result.deinit();
        try job.release();
        released = true;
        try self.inbox.publish(job.ticket, &result);
    }
    fn prepare(self: *State) !void {
        const docs = [2]*d.Document{ self.inbox.pair.a, self.inbox.pair.b };
        try self.view.prepare(bounds, self.parameters);
        const sa = try docs[0].snapshot();
        defer sa.close() catch unreachable;
        const sb = try docs[1].snapshot();
        defer sb.close() catch unreachable;
        const ra = try sa.borrowReader();
        defer ra.release() catch unreachable;
        const rb = try sb.borrowReader();
        defer rb.release() catch unreachable;
        try self.bridge.?.prepare(.{ ra, rb });
        var rows: [96]v.editable.Row = undefined;
        const presentation = try self.view.copyPresentation(&rows);
        const has_hunk = for (presentation.rows) |row| {
            if (row.hunk != null) break true;
        } else false;
        const hunk: paired.controls.Hunk = .{ .index = 0, .original_to_modified = .{ .bounds = .{ .x = 8, .y = 230, .width = 160, .height = 28 }, .name = "Use original", .enabled = !self.disabled }, .modified_to_original = if (presentation.mode == .split) .{ .bounds = .{ .x = 180, .y = 230, .width = 160, .height = 28 }, .name = "Use modified", .enabled = !self.disabled } else null };
        try self.bridge.?.prepareControls(.{ .bounds = .{ .x = 4, .y = 4, .width = 430, .height = 260 }, .hunks = if (has_hunk) &.{hunk} else &.{} });
    }
    fn paint(self: *State) !void {
        _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0);
        if (self.failure) |err| return err;
    }
    fn node(self: *State, kind: a.auxiliary.Kind, variant: u32) !a.auxiliary.Node {
        const bank = &self.workspace.banks[self.workspace.active];
        for (bank.nodes[0..bank.len]) |value| if (value.key.kind == kind and value.key.variant == variant) return value;
        return error.MissingControl;
    }
    fn click(self: *State, x: f32, y: f32) !void {
        const px: u16 = @intFromFloat(x * self.parameters.scale);
        const py: u16 = @intFromFloat(y * self.parameters.scale);
        const position: isize = @intCast(@as(u32, px) | (@as(u32, py) << 16));
        _ = c.SendMessageW(self.window.nativeHandle(), c.WM_LBUTTONDOWN, c.MK_LBUTTON, position);
        _ = c.SendMessageW(self.window.nativeHandle(), c.WM_LBUTTONUP, 0, position);
        if (self.failure) |err| return err;
    }
};
fn nativeAction(provider: *anyopaque, kind: u32) !i32 {
    const Worker = struct {
        provider: *anyopaque,
        kind: u32,
        hr: i32 = 0,
        fn run(self: *@This()) void {
            var x: f64 = 0;
            self.hr = zdd_probe_auxiliary(self.provider, self.kind, &x);
        }
    };
    var worker: Worker = .{ .provider = provider, .kind = kind };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();
    return worker.hr;
}
fn textEquals(document: *d.Document, text: []const u8) !void {
    var bytes: [512]u8 = undefined;
    const length = try document.byteLength();
    try std.testing.expectEqual(text.len, length);
    _ = try document.read(.{ .start = 0, .end = length }, &bytes);
    try std.testing.expectEqualStrings(text, bytes[0..length]);
}
fn bodyHit(state: *State) !void {
    const root = try state.bridge.?.retainProvider(null);
    defer zda_probe_release(root);
    const body = try state.bridge.?.retainProvider(1);
    defer zda_probe_release(body);
    const Worker = struct {
        root: *anyopaque,
        body: *anyopaque,
        hr: i32 = 0,
        fn run(self: *@This()) void {
            var offset: u32 = 0;
            var rectangles: u32 = 0;
            self.hr = zdd_probe_point_hit_mta(self.root, self.body, std.unicode.utf8ToUtf16LeStringLiteral("new"), 3, &offset, &rectangles);
        }
    };
    var worker: Worker = .{ .root = root, .body = body };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();
    try std.testing.expectEqual(@as(i32, 0), worker.hr);
}
fn overlayHit(state: *State) !void {
    const root = try state.bridge.?.retainProvider(null);
    defer zda_probe_release(root);
    var origin: c.POINT = .{ .x = 0, .y = 0 };
    try std.testing.expect(c.ClientToScreen(state.window.nativeHandle(), &origin) != 0);
    for ([_]bool{ true, false }) |enabled| {
        try state.bridge.?.prepareControls(.{ .bounds = .{ .x = 4, .y = 4, .width = 430, .height = 260 }, .hunks = &.{.{ .index = 0, .original_to_modified = .{ .bounds = .{ .x = 234, .y = 8, .width = 100, .height = 22 }, .name = "Use original", .enabled = enabled } }} });
        try state.paint();
        const node = try state.node(.invoke, 0);
        const provider = try state.bridge.?.retainAuxiliaryProvider(node.key);
        defer zda_probe_release(provider);
        const Worker = struct {
            root: *anyopaque,
            expected: *anyopaque,
            x: f64,
            y: f64,
            hr: i32 = 0,
            fn run(self: *@This()) void {
                self.hr = zdd_probe_auxiliary_hit_mta(self.root, self.expected, self.x, self.y);
            }
        };
        var worker: Worker = .{ .root = root, .expected = provider, .x = @as(f64, @floatFromInt(origin.x)) + 236 * state.parameters.scale, .y = @as(f64, @floatFromInt(origin.y)) + 12 * state.parameters.scale };
        const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
        thread.join();
        try std.testing.expectEqual(@as(i32, 0), worker.hr);
        try std.testing.expectEqual(enabled, (try state.context.hitControl(.{ .x = 236, .y = 12 })).?.options.enabled);
    }
    try state.prepare();
    try state.paint();
}
fn keyboardRun(state: *State) !void {
    const Queue = struct {
        state: *State,
        button: u64,
        calls: usize,
        stage: u32 = 0,
        error_value: ?anyerror = null,
        fn post(window: z.Window, key: usize) !void {
            if (c.PostMessageW(window.nativeHandle(), c.WM_KEYDOWN, key, 1) == 0 or c.PostMessageW(window.nativeHandle(), c.WM_KEYUP, key, 1 | (@as(isize, 1) << 31)) == 0) return error.PostFailed;
        }
        fn message(ptr: *anyopaque, window: z.Window, kind: u32, _: usize, _: isize) ?isize {
            if (kind != checkpoint) return null;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.advance(window) catch |err| {
                const record: *z.WindowRecord = @ptrFromInt(@as(usize, @bitCast(c.GetWindowLongPtrW(window.nativeHandle(), c.GWLP_USERDATA))));
                std.debug.print("diff control keyboard failed: stage={d} err={s} focused={any} composing={}/{} client={} key={any} host_error={any}\n", .{ self.stage, @errorName(err), self.state.context.input_state.focused, self.state.context.composing, record.native.text.composing, window.hasTextClient() catch false, self.state.last_key, self.state.failure });
                self.error_value = err;
                window.app.quit();
            };
            return 0;
        }
        fn detach(_: *anyopaque) void {}
        fn advance(self: *@This(), window: z.Window) !void {
            if (self.state.trace) |trace| trace.stage = self.stage;
            if (self.stage == 0) {
                try std.testing.expectEqual(@as(?u64, self.button), self.state.context.input_state.focused);
                try std.testing.expect(!(try window.hasTextClient()));
                var keyboard: [256]u8 = undefined;
                try std.testing.expect(c.GetKeyboardState(&keyboard) != 0);
                defer _ = c.SetKeyboardState(&keyboard);
                var shifted = keyboard;
                shifted[c.VK_SHIFT] |= 0x80;
                try std.testing.expect(c.SetKeyboardState(&shifted) != 0);
                _ = c.SendMessageW(window.nativeHandle(), c.WM_KEYDOWN, c.VK_TAB, 0);
                try std.testing.expect(self.state.context.input_state.focused != self.button);
                _ = c.SetKeyboardState(&keyboard);
                try post(window, c.VK_TAB);
            } else if (self.stage == 1) {
                try std.testing.expectEqual(@as(?u64, self.button), self.state.context.input_state.focused);
                try post(window, c.VK_SPACE);
            } else if (self.stage == 3) {
                try std.testing.expectEqual(self.calls + 1, self.state.calls);
                try textEquals(self.state.inbox.pair.b, original);
                self.state.expected = error.Closed;
                window.app.quit();
                self.stage = 4;
                return;
            }
            self.stage += 1;
            if (c.PostMessageW(window.nativeHandle(), checkpoint, 0, 0) == 0) return error.PostFailed;
        }
    };
    var previous: [256]u8 = undefined;
    try std.testing.expect(c.GetKeyboardState(&previous) != 0);
    defer _ = c.SetKeyboardState(&previous);
    var clean: [256]u8 = @splat(0);
    try std.testing.expect(c.SetKeyboardState(&clean) != 0);
    state.last_key = null;
    var queue: Queue = .{ .state = state, .button = (try state.node(.invoke, 0)).frame_id, .calls = state.calls };
    if (state.trace) |trace| trace.target = queue.button;
    try state.window.setService(.{ .context = &queue, .message = Queue.message, .native_destroying = Queue.detach });
    try Queue.post(state.window, c.VK_TAB);
    try std.testing.expect(c.PostMessageW(state.window.nativeHandle(), checkpoint, 0, 0) != 0);
    var watchdog: @import("watchdog.zig").Watchdog = .{ .app = state.window.app };
    try watchdog.start();
    defer watchdog.stop();
    try state.window.app.run();
    try std.testing.expect(!watchdog.expired);
    if (queue.error_value) |err| return err;
    if (state.failure) |err| return err;
    try std.testing.expectEqual(@as(u32, 4), queue.stage);
    _ = try state.inbox.pair.b.undo();
    try textEquals(state.inbox.pair.b, modified);
}
fn runMode(allocator: std.mem.Allocator, unified: bool, terminal: ?@FieldType(Probe, "action")) !void {
    return runScenario(allocator, unified, terminal, .full);
}
const Replay = enum { full, fresh, disabled, composition, uia, overlay };
fn runScenario(allocator: std.mem.Allocator, unified: bool, terminal: ?@FieldType(Probe, "action"), replay: Replay) !void {
    var state: State = .{};
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    const engine = try t.Engine.create(allocator, app.owner, .{});
    defer engine.close() catch unreachable;
    var probe: Probe = .{ .source = allocator };
    var fold_probe: Probe = .{ .source = allocator };
    const docs = [2]*d.Document{ try d.Document.create(allocator, app.owner, original, .{}), try d.Document.create(probe.allocator(), app.owner, modified, .{}) };
    defer for (docs) |document| document.close() catch unreachable;
    probe.target = docs[1];
    const adapters = [2]*e.Adapter{ try e.Adapter.create(allocator, docs[0], engine, .{}), try e.Adapter.create(fold_probe.allocator(), docs[1], engine, .{}) };
    fold_probe.adapter = adapters[1];
    defer for (adapters) |adapter| adapter.close() catch unreachable;
    state.inbox = try v.Inbox.create(allocator, .{ .a = docs[0], .b = docs[1] }, .{});
    defer state.inbox.close() catch unreachable;
    state.window = try app.createWindow(.{ .width = 450, .height = 280 });
    defer {
        _ = state.window.destroy() catch unreachable;
        app.dispatch() catch unreachable;
    }
    state.parameters.scale = @as(f32, @floatFromInt(c.GetDpiForWindow(state.window.nativeHandle()))) / 96;
    const target: paired.Target = if (unified) .{ .unified = try v.EditableUnified.create(allocator, state.inbox, adapters[0], adapters[1], state.window, .{}) } else .{ .split = try v.EditableSplit.create(allocator, state.inbox, adapters[0], adapters[1], state.window, .{}) };
    state.view = switch (target) {
        .split => |value| value,
        .unified => |value| value.coordinator(),
    };
    defer state.view.close() catch unreachable;
    try state.view.setContext(.{ .context_lines = 1, .minimum_hidden = 3 });
    try state.publish();
    try state.view.prepare(bounds, state.parameters);
    state.context = ui.Context.init(&state, State.draw, State.action);
    state.context.render_mode = .gdi;
    state.context.on_input = State.input;
    try state.context.attach(state.window);
    state.workspace = try paired.controls.Controls.init(0x44494646, 10000, .{});
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    state.bridge = try paired.Bridge.create(failing.allocator(), state.window, target, .{ .controls = &state.workspace });
    defer if (state.bridge) |bridge| bridge.close() catch unreachable;
    try state.bridge.?.attachContext(&state.context);
    try state.prepare();
    try state.paint();
    var trace: Trace = .{ .state = &state };
    try trace.start();
    defer trace.stop();
    errdefer trace.dump();
    if (replay != .full) {
        switch (replay) {
            .disabled => {
                try state.window.perform(.disable);
                try state.window.perform(.enable);
            },
            .composition => {
                try docs[0].setComposition("preedit", .{ .anchor = 0, .caret = 0 });
                _ = try docs[0].cancelComposition();
                try state.prepare();
                try state.paint();
            },
            .uia => {
                try state.click(240, 20);
                try state.prepare();
                try state.paint();
                const control = try state.node(.invoke, 0);
                const focus_provider = try state.bridge.?.retainAuxiliaryProvider(control.key);
                defer zda_probe_release(focus_provider);
                try std.testing.expectEqual(@as(i32, 0), try nativeAction(focus_provider, 4));
                try app.dispatch();
                try std.testing.expect(!(try state.window.hasTextClient()));
            },
            .overlay => try overlayHit(&state),
            .fresh => {},
            .full => unreachable,
        }
        try state.click(240, 20);
        try state.prepare();
        try state.paint();
        try std.testing.expect(try state.window.hasTextClient());
        try keyboardRun(&state);
        return;
    }
    try bodyHit(&state);
    try overlayHit(&state);
    const button = try state.node(.invoke, 0);
    const provider = try state.bridge.?.retainAuxiliaryProvider(button.key);
    defer zda_probe_release(provider);
    if (terminal) |action| {
        probe.window = state.window;
        probe.action = action;
        const version = try docs[1].version();
        var old_selections: [64]d.Selection = undefined;
        var new_selections: [64]d.Selection = undefined;
        const selected = try docs[1].selections(&old_selections);
        state.expected = if (action == .disable) error.Disabled else error.Closed;
        try std.testing.expectEqual(@as(i32, 0), try nativeAction(provider, 1));
        try app.dispatch();
        try std.testing.expect(probe.fired);
        try std.testing.expectEqual(version, try docs[1].version());
        try std.testing.expectEqualDeep(selected, try docs[1].selections(&new_selections));
        try textEquals(docs[1], modified);
        if (action == .disable) try state.window.perform(.enable);
        if (action == .quit) try app.finishShutdown();
        if (state.failure) |err| return err;
        return;
    }
    // A real queued action cannot inherit the next successful comparison epoch.
    try std.testing.expectEqual(@as(i32, 0), try nativeAction(provider, 1));
    try state.publish();
    try state.prepare();
    try state.paint();
    try app.dispatch();
    try textEquals(docs[1], modified);
    const active_button = try state.node(.invoke, 0);
    const active_provider = try state.bridge.?.retainAuxiliaryProvider(active_button.key);
    defer zda_probe_release(active_provider);
    // Failed frames keep both old input and native identity. Owner gates still
    // reject that old epoch after a newer Prepared candidate has been built.
    const old_hits = state.context.input_state.len;
    const old_id = active_button.frame_id;
    state.fail_frame = true;
    state.expected = error.InvalidGeometry;
    try state.prepare();
    try state.paint();
    try std.testing.expectEqual(old_hits, state.context.input_state.len);
    state.expected = error.StalePresentation;
    try std.testing.expectError(error.StalePresentation, state.bridge.?.controlAction(old_id));
    state.fail_frame = false;
    state.expected = null;
    try state.paint();
    // Candidate OOM does not publish a different control/semantic front.
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, state.bridge.?.prepareControls(.{ .bounds = .{ .x = 4, .y = 4, .width = 430, .height = 260 } }));
    failing.fail_index = std.math.maxInt(usize);
    try state.prepare();
    try state.paint();
    // Pointer focus enters the body, then one click hands the sole client to
    // the toolbar; Context retains all capture/press/navigation state.
    _ = c.SetFocus(state.window.nativeHandle());
    try state.click(35, 20);
    try std.testing.expect(try state.window.hasTextClient());
    try std.testing.expect(state.context.input_state.focused == null);
    try state.prepare();
    try state.paint();
    // Native UIA SetFocus follows the same coordinator handoff.
    const focus_node = try state.node(.invoke, 0);
    const focus_provider = try state.bridge.?.retainAuxiliaryProvider(focus_node.key);
    defer zda_probe_release(focus_provider);
    try std.testing.expectEqual(@as(i32, 0), try nativeAction(focus_provider, 4));
    try app.dispatch();
    try std.testing.expect(!(try state.window.hasTextClient()));
    try std.testing.expectEqual(@as(?u64, focus_node.frame_id), state.context.input_state.focused);
    // A fold is a real Input and ExpandCollapse node over each source header.
    const fold = try state.node(.disclosure, if (unified) 1 else 0);
    const fold_provider = try state.bridge.?.retainAuxiliaryProvider(fold.key);
    defer zda_probe_release(fold_provider);
    const version = [2]u64{ try docs[0].version(), try docs[1].version() };
    const fold_versions = [2]u64{ (try adapters[0].status()).fold_version, (try adapters[1].status()).fold_version };
    fold_probe.window = state.window;
    state.expected = error.Disabled;
    try std.testing.expectEqual(@as(i32, 0), try nativeAction(fold_provider, 2));
    try app.dispatch();
    try std.testing.expect(fold_probe.fired);
    try std.testing.expectEqual(fold_versions[0], (try adapters[0].status()).fold_version);
    try std.testing.expectEqual(fold_versions[1], (try adapters[1].status()).fold_version);
    try state.window.perform(.enable);
    state.expected = null;
    try state.prepare();
    try state.paint();
    var regions_before: [96]v.editable.ContextRegion = undefined;
    try std.testing.expect((try state.view.contextRegions(&regions_before))[0].collapsed);
    try std.testing.expectEqual(@as(i32, 0), try nativeAction(fold_provider, 2));
    try app.dispatch();
    try std.testing.expectEqual(version[0], try docs[0].version());
    try std.testing.expectEqual(version[1], try docs[1].version());
    try state.prepare();
    try state.paint();
    var contexts: [96]v.editable.ContextRegion = undefined;
    try std.testing.expect(!(try state.view.contextRegions(&contexts))[0].collapsed);
    // Body focus revokes the control authority before binding B.
    try state.click(240, 20);
    try std.testing.expect(try state.window.hasTextClient());
    try std.testing.expect(state.context.input_state.focused == null);
    try state.prepare();
    try state.paint();
    // Disabled controls occlude the body and cannot trigger a revert.
    state.disabled = true;
    try state.prepare();
    try state.paint();
    const calls = state.calls;
    try state.click(20, 240);
    try std.testing.expectEqual(calls, state.calls);
    try textEquals(docs[1], modified);
    state.disabled = false;
    try state.prepare();
    try state.paint();
    if (!unified) {
        const reverse = try state.node(.invoke, 1);
        const reverse_provider = try state.bridge.?.retainAuxiliaryProvider(reverse.key);
        defer zda_probe_release(reverse_provider);
        try std.testing.expectEqual(@as(i32, 0), try nativeAction(reverse_provider, 1));
        try app.dispatch();
        try textEquals(docs[0], modified);
        _ = try adapters[0].undo();
        try textEquals(docs[0], original);
        _ = try adapters[0].redo();
        try textEquals(docs[0], modified);
        _ = try adapters[0].undo();
        try state.publish();
        try state.prepare();
        try state.paint();
    }
    // First pointer click commits exactly one replace/undo transaction.
    try state.click(20, 240);
    try std.testing.expectEqual(calls + 1, state.calls);
    try std.testing.expect(state.outcome.?.changed);
    try textEquals(docs[1], original);
    _ = try adapters[1].undo();
    try textEquals(docs[1], modified);
    _ = try adapters[1].redo();
    try textEquals(docs[1], original);
    _ = try adapters[1].undo();
    try state.publish();
    try state.prepare();
    try state.paint();
    // Composition and modal/disabled changes are owner guards, even if a
    // previously accepted provider has not seen a new frame yet.
    const current = try state.node(.invoke, 0);
    try docs[0].setComposition("preedit", .{ .anchor = 0, .caret = 0 });
    try std.testing.expectError(error.LayoutRequired, state.bridge.?.controlAction(current.frame_id));
    _ = try docs[0].cancelComposition();
    try state.prepare();
    try state.paint();
    const last = try state.node(.invoke, 0);
    try state.window.perform(.disable);
    try std.testing.expectError(error.Disabled, state.bridge.?.controlAction(last.frame_id));
    try state.window.perform(.enable);
    try state.prepare();
    try state.paint();
    try state.click(240, 20);
    try state.prepare();
    try state.paint();
    try std.testing.expect(try state.window.hasTextClient());
    try keyboardRun(&state);
    if (state.failure) |err| return err;
}
pub fn run(allocator: std.mem.Allocator) !void {
    const before = a.resourceCounts();
    // An explicit fixture-only selector isolates prior history without changing
    // the queued key sequence or weakening its focus/undo assertions.
    if (zio.getEnvVarOwned(allocator, "ZIGGURAT_DIFF_CONTROLS_REPLAY")) |name| {
        defer allocator.free(name);
        const mode = std.meta.stringToEnum(Replay, name) orelse return error.InvalidReplay;
        try runScenario(allocator, false, null, mode);
        try std.testing.expectEqual(before, a.resourceCounts());
        std.debug.print("diff controls isolated replay {s}: original keyboard/undo assertions and resources=0\n", .{name});
        return;
    } else |err| if (err != error.EnvironmentVariableNotFound) return err;
    try runMode(allocator, false, null);
    try runMode(allocator, true, null);
    try runMode(allocator, false, .disable);
    try runMode(allocator, false, .close);
    try runMode(allocator, false, .quit);
    try std.testing.expectEqual(before, a.resourceCounts());
    std.debug.print("diff controls: split/unified typed revert and real context, sole focus, failed frame/OOM/stale/composition, final Doc disable/close/quit guards resources=0\n", .{});
}
