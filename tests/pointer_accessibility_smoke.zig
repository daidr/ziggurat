const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const access = ui.accessibility;
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
    @cInclude("uiautomation.h");
    @cInclude("oleauto.h");
});

const Mode = enum { invoke, close, all };
const position: c.LPARAM = 20 | (20 << 16);

// This observer outlives the heap callback owner and the App. A retained native
// provider is the only object used after on_closed frees that callback owner.
const Observer = struct {
    mode: Mode,
    provider: ?*c.IInvokeProvider = null,
    failure: ?anyerror = null,
    downs: usize = 0,
    ups: usize = 0,
    actions: usize = 0,
    masked: usize = 0,
    restored: usize = 0,
    detaches: usize = 0,
    closed: usize = 0,
    host_frees: usize = 0,
    finish_actions: u32 = std.math.maxInt(u32),

    fn fail(self: *Observer, err: anyerror) void {
        if (self.failure == null) self.failure = err;
    }
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *Observer = @ptrCast(@alignCast(ptr));
        self.fail(value.err orelse error.UnexpectedDiagnostic);
    }
};

const Host = struct {
    allocator: std.mem.Allocator,
    observer: *Observer,
    bridge: access.Bridge = undefined,
    tree: access.Tree = .{},
    press: z.PointerPress = .{},

    fn publish(self: *Host) !void {
        try self.tree.reset("Pointer callback boundary", .{ .x = 0, .y = 0, .width = 240, .height = 120 });
        try self.tree.add(.{ .id = 1, .role = .button, .name = "Invoke", .bounds = .{ .x = 10, .y = 10, .width = 100, .height = 40 } });
        try self.bridge.publish(&self.tree);
    }
    fn object(ptr: *anyopaque, window: z.Window, wp: usize, lp: isize) ?isize {
        const self: *Host = @ptrCast(@alignCast(ptr));
        return self.bridge.getObject(window, wp, lp);
    }
    fn action(ptr: *anyopaque, window: z.Window, value: access.Action) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        const observer = self.observer;
        self.receiveAction(window, value) catch |err| observer.fail(err);
    }
    fn receiveAction(self: *Host, window: z.Window, value: access.Action) !void {
        const observer = self.observer;
        window.app.assertOwner();
        try std.testing.expectEqual(@as(usize, 1), observer.downs);
        try std.testing.expectEqual(@as(usize, 0), observer.actions);
        switch (value) {
            .invoke => |id| try std.testing.expectEqual(@as(u64, 1), id),
            else => return error.UnexpectedAction,
        }
        observer.actions += 1;

        // This is reached only through the native IInvokeProvider vtable and
        // Bridge.enqueue/dispatch. The nested action must not borrow the outer
        // Content pointer callback's otherwise still-current native receipt.
        if (window.pointerPressSnapshot(self.press, .down)) |_| {
            std.debug.print("pointer UIA action mode={s}: borrowed outer receipt={d}\n", .{ @tagName(observer.mode), self.press.sequence });
            observer.fail(error.ExpectedNativeCallbackMasked);
        } else |err| {
            if (err != error.StalePointerInput) return err;
            observer.masked += 1;
        }
        if (observer.mode == .close) {
            try std.testing.expectEqual(z.CloseResult.deferred, try window.destroy());
            try std.testing.expectEqual(@as(usize, 0), observer.host_frees);
        }
    }
    fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        const observer = self.observer;
        self.receive(window, value) catch |err| observer.fail(err);
    }
    fn receive(self: *Host, window: z.Window, value: z.Event) !void {
        const observer = self.observer;
        if (value == .pointer_up) {
            observer.ups += 1;
            return;
        }
        if (value != .pointer_down) return;
        observer.downs += 1;
        const input = value.pointer_down;
        try std.testing.expectEqual(z.PointerButton.primary, input.button);
        try std.testing.expect(input.press.sequence != 0);
        self.press = input.press;
        const original = try window.pointerPressSnapshot(input.press, .down);
        try std.testing.expect(original.timing == null);
        const record = window.app.windows.get(window.key) orelse return error.MissingRecord;
        const operation = record.pointerOperation();
        try std.testing.expect(operation != 0 and operation != std.math.maxInt(u64));

        const provider = observer.provider orelse return error.MissingProvider;
        try check(provider.lpVtbl.*.Invoke.?(provider));
        observer.finish_actions = access.resourceCounts().actions;
        try std.testing.expectEqual(@as(u32, 0), observer.finish_actions);
        try std.testing.expectEqual(@as(usize, 1), observer.actions);
        if (observer.mode == .invoke) {
            try std.testing.expectEqual(operation, record.pointerOperation());
            const restored = try window.pointerPressSnapshot(input.press, .down);
            try std.testing.expectEqualDeep(original, restored);
            observer.restored += 1;
        } else {
            try std.testing.expect(window.isClosed());
            try std.testing.expectError(error.StalePointerInput, window.pointerPressSnapshot(input.press, .down));
            try std.testing.expectEqual(@as(usize, 0), observer.host_frees);
        }
    }
    fn detach(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.observer.detaches += 1;
        self.bridge.detach();
    }
    fn closed(ptr: *anyopaque, _: z.Window) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        const observer = self.observer;
        const allocator = self.allocator;
        // Also handles attachment/setup failure before Content takes the bridge.
        self.bridge.detach();
        observer.closed += 1;
        observer.host_frees += 1;
        allocator.destroy(self);
    }
};

fn check(hr: c.HRESULT) !void {
    if (hr < 0) {
        std.debug.print("pointer UIA HRESULT=0x{x}\n", .{@as(u32, @bitCast(hr))});
        return error.NativeCallFailed;
    }
}

fn buttonProvider(bridge: *access.Bridge) !*c.IInvokeProvider {
    const simple: *c.IRawElementProviderSimple = @ptrCast(@alignCast(try bridge.retainProvider(access.root_id)));
    defer _ = simple.lpVtbl.*.Release.?(simple);
    var root: ?*c.IRawElementProviderFragment = null;
    try check(simple.lpVtbl.*.QueryInterface.?(simple, &c.IID_IRawElementProviderFragment, @ptrCast(&root)));
    const fragment = root orelse return error.MissingRootFragment;
    defer _ = fragment.lpVtbl.*.Release.?(fragment);
    var child: ?*c.IRawElementProviderFragment = null;
    try check(fragment.lpVtbl.*.Navigate.?(fragment, c.NavigateDirection_FirstChild, &child));
    const button = child orelse return error.MissingButtonFragment;
    defer _ = button.lpVtbl.*.Release.?(button);
    var provider: ?*c.IInvokeProvider = null;
    try check(button.lpVtbl.*.QueryInterface.?(button, &c.IID_IInvokeProvider, @ptrCast(&provider)));
    return provider orelse error.MissingInvokeProvider;
}

fn scenario(allocator: std.mem.Allocator, mode: Mode) !void {
    std.debug.assert(mode != .all);
    var observer: Observer = .{ .mode = mode };
    defer {
        if (observer.provider) |provider| _ = provider.lpVtbl.*.Release.?(provider);
    }
    {
        const app = try z.App.initWithOptions(allocator, .{ .icon_policy = .disabled, .diagnostics_sink = .{ .context = &observer, .emit = Observer.diagnostic } });
        defer app.deinit();
        const host = try allocator.create(Host);
        var owns_host = true;
        errdefer if (owns_host) allocator.destroy(host);
        host.* = .{ .allocator = allocator, .observer = &observer };
        host.bridge = access.Bridge.init(host, Host.action);
        const window = try app.createWindow(.{ .native_pointer_clicks = true, .title = "Pointer UIA boundary", .width = 240, .height = 120, .on_closed = .{ .context = host, .notify = Host.closed } });
        owns_host = false; // on_closed owns the callback allocation from here.
        defer {
            if (!window.isClosed()) _ = window.destroy() catch unreachable;
            app.dispatch() catch unreachable;
            std.debug.assert(app.resourceStats().allocated_records == 0);
        }
        try host.bridge.attach(window);
        try window.setContent(.{ .context = host, .event = Host.event, .detach = Host.detach, .accessibility = Host.object });
        try host.publish();
        observer.provider = try buttonProvider(&host.bridge);
        const hwnd: c.HWND = @ptrCast(window.nativeHandle());
        _ = c.SetFocus(hwnd);
        if (c.GetFocus() != hwnd) return error.ThreadFocusUnavailable;
        std.debug.print("pointer UIA mode={s} owner={d} provider=native root/navigate/invoke, direct SendMessage down\n", .{ @tagName(mode), c.GetCurrentThreadId() });
        _ = c.SendMessageW(hwnd, c.WM_LBUTTONDOWN, c.MK_LBUTTON, position);
        // on_closed may already have freed Host. Only observer/Window/App are
        // read from here; a still-open case completes its ordinary matching up.
        if (!window.isClosed()) _ = c.SendMessageW(hwnd, c.WM_LBUTTONUP, 0, position);
        try app.dispatch();
    }
    const provider = observer.provider orelse return error.MissingProvider;
    const late = provider.lpVtbl.*.Invoke.?(provider);
    try std.testing.expectEqual(@as(u32, c.UIA_E_ELEMENTNOTAVAILABLE), @as(u32, @bitCast(late)));
    _ = provider.lpVtbl.*.Release.?(provider);
    observer.provider = null;
    const counts = access.resourceCounts();
    std.debug.print("pointer UIA mode={s} down={d} up={d} action={d} masked={d} restored={d} detach={d} closed={d} host_free={d} finish_actions={d} resources={any}\n", .{ @tagName(mode), observer.downs, observer.ups, observer.actions, observer.masked, observer.restored, observer.detaches, observer.closed, observer.host_frees, observer.finish_actions, counts });
    try std.testing.expectEqual(access.ResourceCounts{ .states = 0, .providers = 0, .ranges = 0, .actions = 0 }, counts);
    try std.testing.expectEqual(@as(usize, 1), observer.downs);
    try std.testing.expectEqual(@as(usize, if (mode == .invoke) 1 else 0), observer.ups);
    try std.testing.expectEqual(@as(usize, 1), observer.actions);
    try std.testing.expectEqual(@as(usize, 1), observer.detaches);
    try std.testing.expectEqual(@as(usize, 1), observer.closed);
    try std.testing.expectEqual(@as(usize, 1), observer.host_frees);
    try std.testing.expectEqual(@as(u32, 0), observer.finish_actions);
    if (observer.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 1), observer.masked);
    try std.testing.expectEqual(@as(usize, if (mode == .invoke) 1 else 0), observer.restored);
}

fn isolatedWindows(mode: Mode) !void {
    var name: [80]u8 = undefined;
    const label = try std.fmt.bufPrint(&name, "Ziggurat.PointerAccessibility.{d}", .{c.GetCurrentProcessId()});
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
    const suffix: []const u16 = switch (mode) {
        .invoke => std.unicode.utf8ToUtf16LeStringLiteral("\" --desktop-child invoke"),
        .close => std.unicode.utf8ToUtf16LeStringLiteral("\" --desktop-child close"),
        .all => std.unicode.utf8ToUtf16LeStringLiteral("\" --desktop-child all"),
    };
    if (count + 1 + suffix.len >= command.len) return error.CommandTooLong;
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
    if (c.GetExitCodeProcess(process.hProcess, &exit_code) == 0) return error.TestProcessStatusUnavailable;
    if (exit_code != 0) {
        std.debug.print("pointer UIA private-desktop child exit=0x{x}\n", .{exit_code});
        return error.TestProcessFailed;
    }
}

fn parseMode(value: []const u8) !Mode {
    return std.meta.stringToEnum(Mode, value) orelse error.InvalidArgument;
}

pub fn main() !void {
    if (builtin.os.tag != .windows or !ui.capabilities.accessibility) return error.UnsupportedCapability;
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);
    if (args.len == 1) return isolatedWindows(.invoke);
    if (args.len == 2) return isolatedWindows(try parseMode(args[1]));
    if (args.len != 3 or !std.mem.eql(u8, args[1], "--desktop-child")) return error.InvalidArgument;
    const mode = try parseMode(args[2]);
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    std.debug.print("pointer UIA ABI Event={d} Input={d} Press={d} Snapshot={d} IInvokeProvider={d}\n", .{ @sizeOf(z.Event), @sizeOf(z.PointerButtonInput), @sizeOf(z.PointerPress), @sizeOf(z.PointerPressSnapshot), @sizeOf(c.IInvokeProvider) });
    if (mode == .all) {
        try scenario(debug.allocator(), .invoke);
        try scenario(debug.allocator(), .close);
    } else try scenario(debug.allocator(), mode);
    std.debug.print("pointer UIA native boundary mode={s} passed; resources=0; final-State-free masking not claimed\n", .{@tagName(mode)});
}
