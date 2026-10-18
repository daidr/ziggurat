const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");

const Host = struct {
    fn draw(_: *anyopaque, _: *ui.Frame) void {}
    fn action(_: *anyopaque, _: u64) void {}
};

// The old public API cannot describe host-owned lexical shortcut ranges. Keep
// that exact old append path runnable so its global duplicate rejection is a
// behavior RED, rather than treating a missing declaration as the RED.
fn enter(frame: *ui.Frame, id: u64) !void {
    if (@hasDecl(ui.Frame, "beginShortcutScope")) try frame.beginShortcutScope(id, .{});
}
fn leave(frame: *ui.Frame) !void {
    if (@hasDecl(ui.Frame, "endShortcutScope")) try frame.endShortcutScope();
}

test "a focused child range may override its parent shortcut in one accepted frame" {
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Host.draw, Host.action);
    if (@hasDecl(ui.Context, "prepareShortcutScopes")) try context.prepareShortcutScopes(std.testing.allocator, .{});
    defer if (@hasDecl(ui.Context, "clearShortcutScopes")) context.clearShortcutScopes() catch unreachable;
    context.input_state.beginFrame();
    defer if (context.input_state.building) context.input_state.cancelFrame();
    var frame: ui.Frame = .{ .context = &context, .size = .{ .width = 100, .height = 100, .scale = 1 } };
    const chord: ui.widgets.Chord = .{ .key = .f3 };
    try enter(&frame, 11);
    try frame.addControl(1, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = chord });
    try enter(&frame, 12);
    // Old production reports DuplicateShortcut here despite distinct host
    // ranges. The green implementation carries the real scope membership.
    try frame.addControl(2, .{ .x = 30, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = chord });
    try leave(&frame);
    try leave(&frame);
    context.input_state.commitFrame();
    context.input_state.focused = 2;
    try std.testing.expectEqual(@as(?u64, 2), context.input_state.matchShortcut(.{ .key = .f3 }));
    context.input_state.focused = 1;
    try std.testing.expectEqual(@as(?u64, 1), context.input_state.matchShortcut(.{ .key = .f3 }));
}

test "clear and replacement cannot reinterpret an old scoped front as flat shortcuts" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Host.draw, Host.action);
    context.render_mode = .gdi;
    context.semantics_enabled = false;
    try context.attach(window);
    try context.prepareShortcutScopes(std.testing.allocator, .{});
    context.input_state.beginFrame();
    var frame: ui.Frame = .{ .context = &context, .size = .{ .width = 100, .height = 100, .scale = 1 } };
    try frame.beginShortcutScope(11, .{});
    try frame.addControl(1, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .f3 } });
    try frame.beginShortcutScope(12, .{});
    try frame.addControl(2, .{ .x = 30, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .f3 } });
    try frame.endShortcutScope();
    try frame.endShortcutScope();
    context.input_state.commitFrame();
    context.input_state.focused = 2;
    try context.clearShortcutScopes();
    try std.testing.expect(context.input_state.matchShortcut(.{ .key = .f3 }) == null);
    try context.prepareShortcutScopes(std.testing.allocator, .{});
    try std.testing.expect(context.input_state.matchShortcut(.{ .key = .f3 }) == null);
}

test "the real text client selects a nested shortcut range without a second control focus" {
    const Text = struct {
        fn read(_: *anyopaque, _: z.Window, _: []u8) !z.text.Snapshot {
            return error.Unavailable;
        }
        fn change(_: *anyopaque, _: z.Window, _: z.text.Change) !z.text.ChangeResult {
            return .applied;
        }
        fn unbound(_: *anyopaque, _: z.Window, _: z.text.UnbindReason) void {}
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Host.draw, Host.action);
    context.render_mode = .gdi;
    context.semantics_enabled = false;
    try context.attach(window);
    try context.prepareShortcutScopes(std.testing.allocator, .{});
    context.input_state.beginFrame();
    var frame: ui.Frame = .{ .context = &context, .size = .{ .width = 100, .height = 100, .scale = 1 } };
    try frame.addControl(1, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .f3 } });
    try frame.beginShortcutScope(12, .{});
    try frame.addControl(2, .{ .x = 30, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .f3 } });
    try frame.endShortcutScope();
    context.input_state.commitFrame();
    const token = try window.setTextClient(.{ .context = &dummy, .owner = app.owner, .read = Text.read, .change = Text.change, .unbound = Text.unbound });
    if (@hasDecl(ui.Context, "associateTextShortcutScope")) try context.associateTextShortcutScope(try context.shortcutScope(12), token);
    try std.testing.expect(context.input_state.focused == null);
    try std.testing.expectEqual(@as(?u64, 2), context.input_state.matchShortcut(.{ .key = .f3 }));
    _ = try window.clearTextClient(token);
    try std.testing.expectEqual(@as(?u64, 1), context.input_state.matchShortcut(.{ .key = .f3 }));
}

test "scoped low-level registration requires the same candidate as Frame registration" {
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Host.draw, Host.action);
    try context.prepareShortcutScopes(std.testing.allocator, .{});
    defer context.clearShortcutScopes() catch unreachable;
    try std.testing.expectError(error.NoFrame, context.input_state.addWithOptions(1, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .f4 } }));
    try std.testing.expectEqual(@as(usize, 0), context.input_state.len);
}

test "a contradictory nested overlay rejects its whole candidate and preserves the old front" {
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Host.draw, Host.action);
    try context.prepareShortcutScopes(std.testing.allocator, .{});
    defer context.clearShortcutScopes() catch unreachable;
    context.input_state.beginFrame();
    var frame: ui.Frame = .{ .context = &context, .size = .{ .width = 100, .height = 100, .scale = 1 } };
    try frame.addControl(1, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .f3 } });
    context.input_state.commitFrame();
    context.input_state.beginFrame();
    try frame.beginShortcutScope(20, .{ .kind = .overlay, .overlay_order = 9 });
    try frame.addControl(2, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{});
    try frame.beginShortcutScope(21, .{ .kind = .overlay, .overlay_order = 8 });
    try frame.addControl(3, .{ .x = 30, .y = 0, .width = 20, .height = 20 }, .{});
    try frame.endShortcutScope();
    try frame.endShortcutScope();
    try std.testing.expect(!context.input_state.frameValid());
    context.input_state.cancelFrame();
    try std.testing.expectEqual(@as(?u64, 1), context.input_state.matchShortcut(.{ .key = .f3 }));
}

test "an explicitly prepared Escape waits for its front before returning to fallback" {
    const Pending = struct {
        err: ?anyerror = null,
        fn onInput(ptr: *anyopaque, context: *ui.Context, event: z.Event) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (event == .key_input and event.key_input.key == .escape) {
                if (@hasDecl(ui.Context, "deferUnhandledEscape")) _ = context.deferUnhandledEscape() catch |err| {
                    self.err = err;
                    return true;
                };
            }
            return false;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var pending: Pending = .{};
    var context = ui.Context.init(&pending, Host.draw, Host.action);
    context.render_mode = .gdi;
    context.semantics_enabled = false;
    context.on_input = Pending.onInput;
    try context.attach(window);
    try context.prepareShortcutScopes(std.testing.allocator, .{});
    try window.perform(.focus);
    try std.testing.expect(context.handleKeyInput(window, .{ .key = .escape }));
    if (pending.err) |err| return err;
}

test "a pre-input repaint cannot redirect the old key to a new front without explicit deferral" {
    const Repaint = struct {
        actions: usize = 0,
        fn action(ptr: *anyopaque, _: u64) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.actions += 1;
        }
        fn input(_: *anyopaque, context: *ui.Context, ev: z.Event) bool {
            if (ev == .key_input and ev.key_input.key == .f3) {
                context.input_state.beginFrame();
                var frame: ui.Frame = .{ .context = context, .size = .{ .width = 100, .height = 100, .scale = 1 } };
                frame.addControl(2, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .f3 } }) catch unreachable;
                context.input_state.commitFrame();
            }
            return false;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var host: Repaint = .{};
    var context = ui.Context.init(&host, Host.draw, Repaint.action);
    context.render_mode = .gdi;
    context.semantics_enabled = false;
    context.on_input = Repaint.input;
    try context.attach(window);
    try context.prepareShortcutScopes(std.testing.allocator, .{});
    try window.perform(.focus);
    context.input_state.beginFrame();
    var frame: ui.Frame = .{ .context = &context, .size = .{ .width = 100, .height = 100, .scale = 1 } };
    try frame.addControl(1, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .f3 } });
    context.input_state.commitFrame();
    try std.testing.expect(context.handleKeyInput(window, .{ .key = .f3 }));
    try std.testing.expectEqual(@as(usize, 0), host.actions);
}

test "sibling overlays, barriers, disabled anchors and repeat shadowing use one accepted route" {
    const Case = enum { top, focused, barrier, disabled_barrier, clipped_barrier, repeat };
    inline for (std.meta.tags(Case)) |case| {
        errdefer std.debug.print("scope route case: {s}\n", .{@tagName(case)});
        var dummy: u8 = 0;
        var context = ui.Context.init(&dummy, Host.draw, Host.action);
        try context.prepareShortcutScopes(std.testing.allocator, .{});
        defer context.clearShortcutScopes() catch unreachable;
        context.input_state.beginFrame();
        var frame: ui.Frame = .{ .context = &context, .size = .{ .width = 100, .height = 100, .scale = 1 } };
        const box: ui.Rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 };
        try frame.addControl(1, box, .{ .shortcut = .{ .key = .f3, .allow_repeat = true } });
        try frame.beginShortcutScope(10, .{});
        try frame.addControl(2, box, .{ .shortcut = .{ .key = .f3 } });
        try frame.endShortcutScope();
        try frame.beginShortcutScope(20, .{ .kind = .overlay, .overlay_order = 1 });
        try frame.addControl(3, box, .{ .shortcut = .{ .key = .f3 } });
        try frame.endShortcutScope();
        try frame.beginShortcutScope(30, .{ .kind = .overlay, .overlay_order = 2, .keyboard_barrier = case == .barrier or case == .disabled_barrier or case == .clipped_barrier });
        try frame.addControl(4, if (case == .clipped_barrier) .{ .x = 0, .y = 0, .width = 0, .height = 20 } else box, .{ .enabled = case != .disabled_barrier, .focusable = case != .disabled_barrier, .shortcut = if (case == .disabled_barrier) null else .{ .key = .f3 } });
        try frame.endShortcutScope();
        try std.testing.expect(context.input_state.frameValid());
        context.input_state.commitFrame();
        context.input_state.focused = if (case == .top) null else 2;
        const expected: ?u64 = switch (case) {
            .top, .barrier => 4,
            .disabled_barrier, .repeat => null,
            .focused, .clipped_barrier => 2,
        };
        try std.testing.expectEqual(expected, context.input_state.matchShortcut(.{ .key = .f3, .repeat = case == .repeat }));
    }
}

test "same-scope chord ambiguity includes disabled and repeat variants, rollback truncates membership" {
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Host.draw, Host.action);
    try context.prepareShortcutScopes(std.testing.allocator, .{});
    defer context.clearShortcutScopes() catch unreachable;
    context.input_state.beginFrame();
    var frame: ui.Frame = .{ .context = &context, .size = .{ .width = 100, .height = 100, .scale = 1 } };
    const box: ui.Rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 };
    try frame.beginShortcutScope(10, .{});
    try frame.addControl(1, box, .{ .shortcut = .{ .key = .f3, .modifiers = .{ .shift = true, .control = true, .alt = true, .super = true } } });
    // Use the public low-level candidate API to inspect a rejected append
    // without clearing the Frame's sticky error contract.
    try std.testing.expectError(error.DuplicateShortcut, context.input_state.addWithOptions(2, box, .{ .enabled = false, .shortcut = .{ .key = .f3, .modifiers = .{ .shift = true, .control = true, .alt = true, .super = true }, .allow_repeat = true } }));
    const mark = context.input_state.checkpoint();
    try context.input_state.addWithOptions(3, box, .{ .shortcut = .{ .key = .f4 } });
    context.input_state.rollback(mark);
    try frame.endShortcutScope();
    try frame.beginShortcutScope(11, .{});
    try frame.addControl(4, box, .{ .shortcut = .{ .key = .f4 } });
    try frame.endShortcutScope();
    context.input_state.commitFrame();
    context.input_state.focused = 1;
    try std.testing.expectEqual(@as(?u64, 1), context.input_state.matchShortcut(.{ .key = .f3, .modifiers = .{ .shift = true, .control = true, .alt = true, .super = true } }));
    try std.testing.expect(context.input_state.matchShortcut(.{ .key = .f3 }) == null);
    context.input_state.focused = 4;
    try std.testing.expectEqual(@as(?u64, 4), context.input_state.matchShortcut(.{ .key = .f4 }));
    try std.testing.expectEqual(@as(usize, 2), context.input_state.len);
}

test "scope capacity depth balance membership and nonwrapping generation fail the complete candidate" {
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Host.draw, Host.action);
    try context.prepareShortcutScopes(std.testing.allocator, .{});
    defer context.clearShortcutScopes() catch unreachable;
    const ws = context.input_state.scopes.?;
    context.input_state.beginFrame();
    for (1..32) |id| {
        try ws.beginScope(@intCast(id), .{});
        try ws.endScope();
    }
    try std.testing.expect(context.input_state.frameValid());
    try std.testing.expectError(error.TooManyShortcutScopes, ws.beginScope(32, .{}));
    try std.testing.expect(!context.input_state.frameValid());
    context.input_state.cancelFrame();
    context.input_state.beginFrame();
    for (1..17) |id| try ws.beginScope(@intCast(id), .{});
    try std.testing.expectError(error.ShortcutScopeDepthExceeded, ws.beginScope(17, .{}));
    context.input_state.cancelFrame();
    context.input_state.beginFrame();
    try std.testing.expectError(error.UnbalancedShortcutScopes, ws.endScope());
    context.input_state.cancelFrame();
    context.input_state.beginFrame();
    try ws.beginScope(10, .{});
    try std.testing.expect(!context.input_state.frameValid());
    try ws.endScope();
    const box: ui.Rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 };
    for (1..129) |id| try context.input_state.addWithOptions(@intCast(id), box, .{});
    try std.testing.expectError(error.TooManyControls, context.input_state.addWithOptions(129, box, .{}));
    try std.testing.expect(context.input_state.frameValid());
    ws.pending().members[127] = 32;
    try std.testing.expect(!context.input_state.frameValid());
    context.input_state.cancelFrame();
    ws.candidate = std.math.maxInt(u64);
    context.input_state.beginFrame();
    try std.testing.expectError(error.ShortcutGenerationExhausted, context.input_state.validateFrame());
    context.input_state.cancelFrame();
}

const WorkspaceAllocator = struct {
    source: std.mem.Allocator = std.testing.allocator,
    window: ?z.Window = null,
    hook: enum { none, allocation, free } = .none,
    fail: bool = false,
    fired: bool = false,
    allocations: usize = 0,
    bytes: usize = 0,
    peak: usize = 0,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn fire(self: *@This()) void {
        self.hook = .none;
        self.fired = true;
        _ = self.window.?.destroy() catch unreachable;
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.fail) return null;
        if (self.hook == .allocation) self.fire();
        const result = self.source.rawAlloc(len, alignment, ret) orelse return null;
        self.allocations += 1;
        self.bytes += len;
        self.peak = @max(self.peak, self.bytes);
        return result;
    }
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.bytes -= bytes.len;
        self.source.rawFree(bytes, alignment, ret);
        if (self.hook == .free) self.fire();
    }
};

test "workspace preparation is atomic across OOM and allocator close callbacks; ordinary keys allocate nothing" {
    inline for (.{ .none, .allocation, .free }) |hook| {
        errdefer std.debug.print("workspace allocator hook: {s}\n", .{@tagName(hook)});
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        const window = try app.createWindow(.{});
        defer _ = window.destroy() catch unreachable;
        var dummy: u8 = 0;
        var context = ui.Context.init(&dummy, Host.draw, Host.action);
        context.render_mode = .gdi;
        context.semantics_enabled = false;
        try context.attach(window);
        var allocator: WorkspaceAllocator = .{ .window = window };
        try std.testing.expectEqual(@as(usize, 0), (try context.shortcutScopesStats()).metadata_bytes);
        try context.prepareShortcutScopes(allocator.allocator(), .{});
        const metadata = (try context.shortcutScopesStats()).metadata_bytes;
        try std.testing.expectEqual(metadata, allocator.bytes);
        try std.testing.expectEqual(@as(usize, 1), allocator.allocations);
        context.input_state.beginFrame();
        var frame: ui.Frame = .{ .context = &context, .size = .{ .width = 100, .height = 100, .scale = 1 } };
        try frame.addControl(1, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .f3 } });
        context.input_state.commitFrame();
        const serial = (try context.shortcutScopesStats()).serial;
        allocator.fail = true;
        try std.testing.expectError(error.OutOfMemory, context.prepareShortcutScopes(allocator.allocator(), .{}));
        try std.testing.expectEqual(serial, (try context.shortcutScopesStats()).serial);
        try std.testing.expectEqual(@as(?u64, 1), context.input_state.matchShortcut(.{ .key = .f3 }));
        try window.perform(.focus);
        for (0..10) |_| {
            context.input_state.beginFrame();
            try frame.addControl(1, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .f3 } });
            context.input_state.commitFrame();
            try std.testing.expect(context.handleKeyInput(window, .{ .key = .f3 }));
        }
        try std.testing.expectEqual(@as(usize, 1), allocator.allocations);
        allocator.fail = false;
        allocator.hook = hook;
        if (hook == .allocation) {
            try std.testing.expectError(error.Closed, context.prepareShortcutScopes(allocator.allocator(), .{}));
        } else try context.prepareShortcutScopes(allocator.allocator(), .{});
        if (hook != .none) {
            try std.testing.expect(allocator.fired and window.isClosed());
        } else {
            try std.testing.expectEqual(2 * metadata, allocator.peak);
            _ = try window.destroy();
        }
        try app.dispatch(); // Actual detach follows the allocator callback pin.
        try std.testing.expectEqual(@as(usize, 0), allocator.bytes);
    }
}

test "text scope association follows exact client tokens and cannot revive after scope removal or reinstallation" {
    const Text = struct {
        fn read(_: *anyopaque, _: z.Window, _: []u8) !z.text.Snapshot {
            return error.Unavailable;
        }
        fn change(_: *anyopaque, _: z.Window, _: z.text.Change) !z.text.ChangeResult {
            return .applied;
        }
        fn unbound(_: *anyopaque, _: z.Window, _: z.text.UnbindReason) void {}
        fn front(context: *ui.Context, child: bool) !void {
            context.input_state.beginFrame();
            var frame: ui.Frame = .{ .context = context, .size = .{ .width = 100, .height = 100, .scale = 1 } };
            const box: ui.Rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 };
            try frame.addControl(1, box, .{ .shortcut = .{ .key = .f3 } });
            if (child) {
                try frame.beginShortcutScope(10, .{});
                try frame.addControl(2, box, .{ .shortcut = .{ .key = .f3 } });
                try frame.endShortcutScope();
            }
            context.input_state.commitFrame();
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Host.draw, Host.action);
    context.render_mode = .gdi;
    context.semantics_enabled = false;
    try context.attach(window);
    try context.prepareShortcutScopes(std.testing.allocator, .{});
    try Text.front(&context, true);
    const first_scope = try context.shortcutScope(10);
    const client: z.TextClient = .{ .context = &dummy, .owner = app.owner, .read = Text.read, .change = Text.change, .unbound = Text.unbound };
    const first = try window.setTextClient(client);
    try context.associateTextShortcutScope(first_scope, first);
    try std.testing.expectEqual(@as(?u64, 2), context.input_state.matchShortcut(.{ .key = .f3 }));
    _ = try window.clearTextClient(first);
    const second = try window.setTextClient(client);
    try std.testing.expect(!std.meta.eql(first, second));
    try std.testing.expectEqual(@as(?u64, 1), context.input_state.matchShortcut(.{ .key = .f3 }));
    try std.testing.expectError(error.StaleShortcutScope, context.associateTextShortcutScope(first_scope, first));
    try context.associateTextShortcutScope(first_scope, second);
    try Text.front(&context, false);
    try Text.front(&context, true);
    try std.testing.expectEqual(@as(?u64, 1), context.input_state.matchShortcut(.{ .key = .f3 }));
    try std.testing.expectError(error.StaleShortcutScope, context.associateTextShortcutScope(first_scope, second));
    const before_clear = try context.shortcutScope(10);
    try context.clearShortcutScopes();
    try context.prepareShortcutScopes(std.testing.allocator, .{});
    try Text.front(&context, true);
    try std.testing.expectError(error.StaleShortcutScope, context.associateTextShortcutScope(before_clear, second));
    _ = try window.clearTextClient(second);
}

test "only entered bare nonrepeat Escape can defer; cancellation and request attribution use exact tokens" {
    const Pending = struct {
        request: ?ui.ShortcutRequestToken = null,
        err: ?anyerror = null,
        calls: usize = 0,
        fn input(ptr: *anyopaque, context: *ui.Context, ev: z.Event) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (ev == .key_input) {
                self.calls += 1;
                self.request = context.deferUnhandledEscape() catch |err| {
                    self.err = err;
                    return true;
                };
            }
            return false;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var host: Pending = .{};
    var context = ui.Context.init(&host, Host.draw, Host.action);
    context.render_mode = .gdi;
    context.semantics_enabled = false;
    context.on_input = Pending.input;
    try context.attach(window);
    try context.prepareShortcutScopes(std.testing.allocator, .{});
    try window.perform(.focus);
    try std.testing.expectError(error.NoKeyInput, context.deferUnhandledEscape());
    for ([_]z.KeyInput{ .{ .key = .f3 }, .{ .key = .escape, .modifiers = .{ .control = true } }, .{ .key = .escape, .repeat = true } }) |key| {
        host.err = null;
        try std.testing.expect(context.handleKeyInput(window, key));
        try std.testing.expectEqual(@as(?anyerror, error.InvalidDeferredShortcut), host.err);
        try std.testing.expect(host.request == null);
    }
    host.err = null;
    try std.testing.expect(context.handleKeyInput(window, .{ .key = .escape }));
    try std.testing.expect(host.err == null);
    var token = host.request.?;
    context.input_state.beginFrame();
    var frame: ui.Frame = .{ .context = &context, .size = .{ .width = 100, .height = 100, .scale = 1 } };
    token.id += 1;
    try std.testing.expectError(error.StaleShortcutRequest, frame.acceptShortcutRequest(token));
    try std.testing.expect(frame.failure != null);
    context.input_state.cancelFrame();
    try std.testing.expect(try context.cancelDeferredShortcut(host.request.?));
    try std.testing.expect(!try context.cancelDeferredShortcut(host.request.?));
    context.composing = true;
    try std.testing.expect(!context.handleKeyInput(window, .{ .key = .escape }));
    context.composing = false;
    try std.testing.expectEqual(@as(usize, 4), host.calls);
}
