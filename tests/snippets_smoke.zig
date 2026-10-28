const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const text = @import("ziggurat_text_layout");
const d = @import("ziggurat_document");
const editing = @import("ziggurat_document_editor");
const snippets = @import("ziggurat_code_editor").snippets;
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_resource_count() u32;
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;
extern fn gdk_event_new(c_int) ?*anyopaque;
extern fn gdk_event_free(*anyopaque) void;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
const KeyEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, state: c_uint, keyval: c_uint, length: c_int, string: ?[*:0]u8, hardware_keycode: u16, group: u8, modifier_storage: c_uint };
const bounds: ui.Rect = .{ .x = 8, .y = 8, .width = 300, .height = 120 };
const Host = struct {
    window: z.Window = undefined,
    context: ui.Context = undefined,
    adapter: *editing.Adapter,
    session: *snippets.Session,
    parameters: editing.Parameters = .{ .font = .{ .size = 18, .wrap = .word_character, .width = 300 } },
    failure: ?anyerror = null,
    paints: usize = 0,
    close_in_input: bool = false,
    fn action(_: *anyopaque, _: u64) void {}
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        if (value.err) |err| self.failure = err;
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        frame.clear(0xffffff);
        self.adapter.draw(frame, bounds, .{}) catch |err| {
            std.debug.print("snippet draw {s}: paint scale={d}, prepared scale={d}, adapter={any}\n", .{ @errorName(err), frame.size.scale, self.parameters.scale, self.adapter.status() catch null });
            self.failure = err;
        };
        std.testing.expectError(error.ResourceInUse, self.adapter.prepare(bounds, self.parameters)) catch |err| {
            self.failure = err;
        };
        self.paints += 1;
    }
    fn input(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *Host = @ptrCast(@alignCast(ptr));
        return self.inputChecked(event) catch |err| {
            self.failure = err;
            return true;
        };
    }
    fn inputChecked(self: *Host, event: z.Event) !bool {
        const handled = if (try self.session.handleEvent(self.window, event)) true else try self.adapter.handleEvent(self.window, event, bounds, self.parameters);
        if (self.close_in_input and event == .text_input) {
            _ = try self.window.destroy();
            return handled;
        }
        _ = try self.adapter.prepare(bounds, self.parameters);
        self.window.invalidate();
        return handled;
    }
    fn paint(self: *Host) !void {
        if (builtin.os.tag == .windows) _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0) else {
            const native = self.window.app.windows.get(self.window.key).?.native.native.?;
            zlg_test_paint(native, @intFromFloat(330 * self.parameters.scale), @intFromFloat(150 * self.parameters.scale));
        }
        if (self.failure) |err| return err;
    }
    fn tab(self: *Host, shift: bool) !void {
        if (builtin.os.tag == .windows and !shift) _ = c.SendMessageW(self.window.nativeHandle(), c.WM_KEYDOWN, c.VK_TAB, 0) else if (builtin.os.tag == .linux) {
            const child = gtk_bin_get_child(self.window.nativeHandle().?).?;
            const event = gdk_event_new(8) orelse return error.EventAllocationFailed;
            defer gdk_event_free(event);
            const key: *KeyEvent = @ptrCast(@alignCast(event));
            key.* = .{ .kind = 8, .window = g_object_ref(gtk_widget_get_window(child).?), .send_event = 1, .time = 0, .state = if (shift) 1 else 0, .keyval = if (shift) 0xfe20 else 0xff09, .length = 0, .string = null, .hardware_keycode = 0, .group = 0, .modifier_storage = 0 };
            var handled: c_int = 0;
            g_signal_emit_by_name(child, "key-press-event", event, &handled);
            try std.testing.expect(handled != 0);
        } else try std.testing.expect(try self.inputChecked(.{ .key_input = .{ .key = .tab, .modifiers = .{ .shift = true } } }));
        if (self.failure) |err| return err;
    }
    fn commitByte(self: *Host, value: u8) !void {
        if (builtin.os.tag == .windows) _ = c.SendMessageW(self.window.nativeHandle(), c.WM_CHAR, value, 0) else try std.testing.expect(try self.inputChecked(.{ .text_input = .{ .text = &.{value}, .producer = .application } }));
        if (self.failure) |err| return err;
    }
};
fn expectText(document: *d.Document, expected: []const u8) !void {
    var bytes: [4096]u8 = undefined;
    const length = try document.byteLength();
    try std.testing.expectEqualStrings(expected, bytes[0..try document.read(.{ .start = 0, .end = length }, &bytes)]);
}
fn run(allocator: std.mem.Allocator) !void {
    var host: Host = .{ .adapter = undefined, .session = undefined };
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &host, .emit = Host.diagnostic } });
    defer app.deinit();
    const engine = try text.Engine.create(allocator, app.owner, .{});
    defer engine.close() catch unreachable;
    const document = try d.Document.create(allocator, app.owner, "old", .{});
    defer document.close() catch unreachable;
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const adapter = try editing.Adapter.create(failing.allocator(), document, engine, .{});
    defer adapter.close() catch unreachable;
    const session = try snippets.Session.create(allocator, adapter, .{ .transforms = .{} });
    defer session.close() catch unreachable;
    const template = try snippets.Template.parse(allocator, "fn ${1:猫}($1) { ${2|red,green|};$0 }", .{});
    defer {
        session.cancel() catch unreachable;
        template.close() catch unreachable;
    }
    host.adapter = adapter;
    host.session = session;
    host.window = try app.createWindow(.{ .width = 330, .height = 150 });
    defer _ = host.window.destroy() catch unreachable;
    host.parameters.scale = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(host.window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(host.window.nativeHandle().?));
    host.context = ui.Context.init(&host, Host.draw, Host.action);
    host.context.on_input = Host.input;
    host.context.render_mode = .gdi;
    try host.context.attach(host.window);
    _ = try adapter.prepare(bounds, host.parameters);
    try adapter.bind(host.window);
    defer adapter.unbind() catch unreachable;
    if (builtin.os.tag == .windows) host.window.show();
    const revision = try document.version();
    const original = try document.selection();
    var failures: usize = 0;
    for (0..128) |offset| {
        failing.fail_index = failing.alloc_index + offset;
        const outcome = session.start(template, revision, &.{.{ .start = 0, .end = 3 }}, 0) catch |err| {
            if (err != error.OutOfMemory) return err;
            failures += 1;
            try std.testing.expectEqual(revision, try document.version());
            try expectText(document, "old");
            try std.testing.expect(!(try session.status()).active);
            continue;
        };
        try std.testing.expect(outcome.committed and outcome.active);
        break;
    } else return error.NoSuccessfulCandidate;
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expect(failures > 1);
    _ = try adapter.prepare(bounds, host.parameters);
    try host.paint();
    try std.testing.expect(host.paints != 0);
    try expectText(document, "fn 猫(猫) { red; }");
    try host.commitByte('x');
    try expectText(document, "fn x(x) { red; }");
    try host.commitByte('y');
    try expectText(document, "fn xy(xy) { red; }");
    try host.tab(false);
    try std.testing.expectEqual(@as(?u16, 2), (try session.status()).id);
    _ = try session.choose(1);
    try expectText(document, "fn xy(xy) { green; }");
    try host.tab(true);
    try std.testing.expectEqual(@as(?u16, 1), (try session.status()).id);
    try host.tab(false);
    try host.tab(false);
    try std.testing.expect(!(try session.status()).active);
    _ = try adapter.undo();
    try expectText(document, "fn xy(xy) { red; }");
    _ = try adapter.redo();
    try expectText(document, "fn xy(xy) { green; }");
    for (0..4) |_| _ = try adapter.undo();
    try expectText(document, "old");
    try std.testing.expectEqual(original, try document.selection());
    _ = try session.start(template, try document.version(), &.{.{ .start = 0, .end = 3 }}, 0);
    _ = try adapter.setSelection(.{}, .downstream);
    try std.testing.expectError(error.StaleRevision, session.edit("never"));
    // Ingress explicitly retires stale metadata and forwards the event once.
    try host.commitByte('z');
    try std.testing.expect(!(try session.status()).active);
    try expectText(document, "zfn 猫(猫) { red; }");
    try session.cancel();
    _ = try session.start(template, try document.version(), &.{.{ .start = 0, .end = try document.byteLength() }}, 0);
    try std.testing.expect(!try session.handleEvent(host.window, .{ .text_preedit = .{ .text = "a", .selection_start = 1, .selection_end = 1 } }));
    try std.testing.expect(!(try session.status()).active);
    _ = try adapter.handleEvent(host.window, .{ .text_preedit = .{ .text = "a", .selection_start = 1, .selection_end = 1 } }, bounds, host.parameters);
    try std.testing.expectError(error.CompositionActive, session.start(template, try document.version(), &.{.{ .start = 0, .end = 0 }}, 0));
    _ = try adapter.handleEvent(host.window, .text_preedit_cancel, bounds, host.parameters);
    const transformed = try snippets.Template.parse(allocator, "${1:ab} ${1/(.*)/${1:/upcase}/} ${1/(.*)/<$1>/} ${2:next}$0", .{});
    defer transformed.close() catch unreachable;
    _ = try session.start(transformed, try document.version(), &.{.{ .start = 0, .end = try document.byteLength() }}, 0);
    _ = try adapter.prepare(bounds, host.parameters);
    const transform_revision = try document.version();
    try host.tab(false);
    try std.testing.expectEqual(transform_revision + 1, try document.version());
    try expectText(document, "ab AB <ab> next");
    try host.tab(true);
    try host.commitByte('z');
    try expectText(document, "z z z next");
    try session.cancel();
    _ = try adapter.undo();
    try expectText(document, "ab AB <ab> next");
    _ = try adapter.undo();
    try expectText(document, "ab ab ab next");
    _ = try session.start(template, try document.version(), &.{.{ .start = 0, .end = try document.byteLength() }}, 0);
    _ = try adapter.prepare(bounds, host.parameters);
    host.close_in_input = true;
    try host.commitByte('q');
    try app.dispatch();
    try std.testing.expect(host.window.isClosed());
    try session.cancel();
}
const Reentry = struct {
    child: std.mem.Allocator,
    document: *d.Document,
    session: ?*snippets.Session = null,
    template: ?*snippets.Template = null,
    mode: enum { off, before, after } = .off,
    expected: u64 = 0,
    triggered: bool = false,
    failure: ?anyerror = null,
    fn allocator(self: *Reentry) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn callback(self: *Reentry, after: bool) void {
        if (self.triggered or self.mode == .off or (self.mode == .after) != after or self.session == null) return;
        const revision = self.document.version() catch return;
        if (after and revision != self.expected + 1) return;
        self.triggered = true;
        self.checked() catch |err| {
            self.failure = err;
        };
    }
    fn checked(self: *Reentry) !void {
        try std.testing.expectError(error.Busy, self.session.?.close());
        try std.testing.expectError(error.ClientsAlive, self.template.?.close());
        const end = try self.document.byteLength();
        try self.document.replace(.{ .start = end, .end = end }, "!");
    }
    fn alloc(ptr: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Reentry = @ptrCast(@alignCast(ptr));
        self.callback(false);
        return self.child.rawAlloc(length, alignment, ret);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Reentry = @ptrCast(@alignCast(ptr));
        self.callback(true);
        self.child.rawFree(bytes, alignment, ret);
    }
};
fn reentry(allocator: std.mem.Allocator) !void {
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    var hook: Reentry = .{ .child = allocator, .document = document };
    const adapter = try editing.Adapter.create(hook.allocator(), document, engine, .{ .metadata_history = 0 });
    defer adapter.close() catch unreachable;
    const template = try snippets.Template.parse(allocator, "${1:猫}=$1$0", .{});
    defer template.close() catch unreachable;
    const session = try snippets.Session.create(allocator, adapter, .{ .transforms = .{} });
    defer session.close() catch unreachable;
    hook.session = session;
    hook.template = template;
    hook.mode = .before;
    hook.expected = try document.version();
    try std.testing.expectError(error.StaleRevision, session.start(template, hook.expected, &.{.{ .start = 0, .end = 3 }}, 0));
    if (hook.failure) |err| return err;
    try std.testing.expect(hook.triggered);
    try expectText(document, "abc!");
    try std.testing.expect(!(try session.status()).active);
    hook.mode = .off;
    _ = try document.undo();
    try adapter.reindex();
    hook.mode = .after;
    hook.triggered = false;
    hook.expected = try document.version();
    const result = try session.start(template, hook.expected, &.{.{ .start = 0, .end = 3 }}, 0);
    hook.mode = .off;
    if (hook.failure) |err| return err;
    try std.testing.expect(hook.triggered);
    try std.testing.expect(result.committed and result.stale_after_commit and !result.active);
    try std.testing.expectEqual(@as(?u64, hook.expected + 1), result.committed_revision);
    try std.testing.expectEqual(hook.expected + 2, result.revision);
    try expectText(document, "猫=猫!");
    try adapter.reindex();
    _ = try adapter.undo();
    try expectText(document, "猫=猫");
    _ = try adapter.undo();
    try expectText(document, "abc");
    const transformed = try snippets.Template.parse(allocator, "${1:ab} ${1/(.*)/<$1>/} ${2:x}$0", .{});
    defer transformed.close() catch unreachable;
    hook.template = transformed;
    try adapter.reindex();
    _ = try session.start(transformed, try document.version(), &.{.{ .start = 0, .end = try document.byteLength() }}, 0);
    hook.mode = .before;
    hook.triggered = false;
    hook.expected = try document.version();
    try std.testing.expectError(error.StaleRevision, session.next(false));
    hook.mode = .off;
    if (hook.failure) |err| return err;
    try std.testing.expect(hook.triggered);
    try expectText(document, "ab ab x!");
    try std.testing.expectEqual(@as(?u16, 1), (try session.status()).id);
    try session.cancel();
    _ = try document.undo();
    try adapter.reindex();
    _ = try session.start(transformed, try document.version(), &.{.{ .start = 0, .end = try document.byteLength() }}, 0);
    hook.mode = .after;
    hook.triggered = false;
    hook.expected = try document.version();
    const transformed_outcome = try session.next(false);
    hook.mode = .off;
    if (hook.failure) |err| return err;
    try std.testing.expect(hook.triggered);
    try std.testing.expect(transformed_outcome.committed and transformed_outcome.stale_after_commit and !transformed_outcome.active);
    try std.testing.expectEqual(@as(?u64, hook.expected + 1), transformed_outcome.committed_revision);
    try expectText(document, "ab <ab> x!");
    try adapter.reindex();
    _ = try adapter.undo();
    try expectText(document, "ab <ab> x");
    _ = try adapter.undo();
    try expectText(document, "ab ab x");
}
const ClosingDocumentAllocator = struct {
    child: std.mem.Allocator,
    window: ?z.Window = null,
    armed: bool = false,
    triggered: bool = false,
    failure: ?anyerror = null,
    fn allocator(self: *ClosingDocumentAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *ClosingDocumentAllocator = @ptrCast(@alignCast(ptr));
        if (self.armed and !self.triggered) {
            self.triggered = true;
            _ = self.window.?.destroy() catch |err| {
                self.failure = err;
                return null;
            };
        }
        return self.child.rawAlloc(length, alignment, ret);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *ClosingDocumentAllocator = @ptrCast(@alignCast(ptr));
        self.child.rawFree(bytes, alignment, ret);
    }
};
fn closeDuringDocumentCandidate(allocator: std.mem.Allocator, transforming: bool) !void {
    var host: Host = .{ .adapter = undefined, .session = undefined };
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &host, .emit = Host.diagnostic } });
    defer app.deinit();
    const engine = try text.Engine.create(allocator, app.owner, .{});
    defer engine.close() catch unreachable;
    var hook: ClosingDocumentAllocator = .{ .child = allocator };
    const document = try d.Document.create(hook.allocator(), app.owner, "old", .{});
    defer document.close() catch unreachable;
    const adapter = try editing.Adapter.create(allocator, document, engine, .{});
    defer adapter.close() catch unreachable;
    const template = try snippets.Template.parse(allocator, if (transforming) "${1:ab} ${1/(.*)/<$1>/} ${2:x}$0" else "${1:猫}=$1$0", .{});
    defer template.close() catch unreachable;
    const session = try snippets.Session.create(allocator, adapter, .{ .transforms = .{} });
    defer session.close() catch unreachable;
    host.adapter = adapter;
    host.session = session;
    host.window = try app.createWindow(.{ .width = 330, .height = 150 });
    defer _ = host.window.destroy() catch unreachable;
    host.parameters.scale = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(host.window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(host.window.nativeHandle().?));
    host.context = ui.Context.init(&host, Host.draw, Host.action);
    host.context.on_input = Host.input;
    host.context.render_mode = .gdi;
    try host.context.attach(host.window);
    _ = try adapter.prepare(bounds, host.parameters);
    try adapter.bind(host.window);
    defer adapter.unbind() catch unreachable;
    if (builtin.os.tag == .windows) host.window.show();
    _ = try session.start(template, try document.version(), &.{.{ .start = 0, .end = 3 }}, 0);
    _ = try adapter.prepare(bounds, host.parameters);
    const revision = try document.version();
    var before: [8]d.Selection = undefined;
    const selected = try document.selections(&before);
    const session_before = try session.status();
    hook.window = host.window;
    hook.armed = true;
    // This allocator belongs to Document, after Adapter's candidate check.
    // The final publication guard must still see the original native input.
    if (transforming) try std.testing.expectError(error.Closed, host.tab(false)) else try std.testing.expectError(error.Closed, host.commitByte('q'));
    hook.armed = false;
    if (hook.failure) |err| return err;
    try std.testing.expect(hook.triggered);
    try std.testing.expectEqual(revision, try document.version());
    try expectText(document, if (transforming) "ab ab x" else "猫=猫");
    var after: [8]d.Selection = undefined;
    const actual = try document.selections(&after);
    try std.testing.expectEqual(selected.primary, actual.primary);
    try std.testing.expectEqualSlices(d.Selection, selected.items, actual.items);
    try std.testing.expectEqual(session_before, try session.status());
    try app.dispatch();
    try std.testing.expect(host.window.isClosed());
    try session.cancel();
}
fn isolatedWindows() !void {
    var name: [80]u8 = undefined;
    const label = try std.fmt.bufPrint(&name, "Ziggurat.Snippets.{d}", .{c.GetCurrentProcessId()});
    var wide: [80:0]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&wide, label);
    wide[length] = 0;
    const desktop = c.CreateDesktopW(&wide, null, null, 0, c.DESKTOP_CREATEWINDOW | c.DESKTOP_CREATEMENU | c.DESKTOP_READOBJECTS | c.DESKTOP_WRITEOBJECTS, null) orelse return error.CreateDesktopFailed;
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
        return error.TestTimeout;
    }
    var result: c.DWORD = 0;
    if (c.GetExitCodeProcess(process.hProcess, &result) == 0 or result != 0) return error.ChildFailed;
}
pub fn main(init: std.process.Init.Minimal) !void {
    if (builtin.os.tag == .windows) {
        const args = try zio.argsAlloc(std.heap.page_allocator, init.args);
        defer zio.argsFree(std.heap.page_allocator, args);
        if (args.len == 1) return isolatedWindows();
        if (args.len != 2 or !std.mem.eql(u8, args[1], "--desktop-child")) return error.InvalidArguments;
    }
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const before = text.resourceCounts();
    try run(debug.allocator());
    try reentry(debug.allocator());
    try closeDuringDocumentCandidate(debug.allocator(), false);
    try closeDuringDocumentCandidate(debug.allocator(), true);
    try std.testing.expectEqual(before, text.resourceCounts());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("snippets: native input/Tab, mirrors/choice, transaction OOM/undo/selection, IME/stale/close and refs=0 passed\n", .{});
}
