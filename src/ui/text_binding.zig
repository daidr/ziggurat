const std = @import("std");
const z = @import("ziggurat");
const editing = @import("editor.zig");
const ui = @import("root.zig");

/// Native document bridge. Keep this address stable through unbind and callback
/// return. Editor remains the sole document, preedit and undo owner. This bridge
/// does not shape: changed is an explicit input/layout callback supplied by the
/// host, normally prepare -> setTextCaret. A preparation failure keeps the edit
/// committed and is returned for reporting/retry, just like ordinary input.
pub const Binding = struct {
    pub const Changed = struct { context: *anyopaque, call: *const fn (*anyopaque, z.Window) anyerror!void };
    editor: *editing.Editor,
    owner: std.Thread.Id,
    token: ?z.TextClientToken = null,
    changed: ?Changed = null,
    space: ?ui.SpaceBinding = null,
    space_required: bool = false,
    coordinate_generation: u64 = 0,

    pub fn init(editor: *editing.Editor, owner: std.Thread.Id) Binding {
        return .{ .editor = editor, .owner = owner };
    }
    pub fn bind(self: *Binding, window: z.Window) !void {
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        if (self.token != null) return error.AlreadyBound;
        if (self.editor.native_binding_busy) return error.Busy;
        try self.requireAvailableOwner();
        self.editor.native_binding_busy = true;
        defer self.editor.native_binding_busy = false;
        const token = try window.setTextClient(.{ .context = self, .owner = self.owner, .read = read, .change = change, .unbound = unbound });
        self.token = token;
        self.editor.native_binding = self;
        self.editor.focused = true;
        self.editor.window_active = true;
    }
    fn requireAvailableOwner(self: *Binding) !void {
        const previous = self.editor.native_binding orelse return;
        const token = previous.token orelse return;
        const physical = token.window.hasTextClient() catch |err| switch (err) {
            error.Closed => return,
            else => return err,
        };
        if (!physical) return;
        // The permission-filtered token may be null for a disabled/modal old
        // Window whose physical client is still installed. That is not a handoff.
        const current = token.window.textClientToken() orelse return error.EditorAlreadyBound;
        if (std.meta.eql(current, token)) return error.EditorAlreadyBound;
    }
    pub fn unbind(self: *Binding) !void {
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        if (self.token) |token| _ = try token.window.clearTextClient(token);
        if (self.token != null) return error.UnbindPending;
    }
    /// Opt in only after the matching source frame committed successfully.
    /// Borrow Context until clear/unbound AND all entered callbacks return.
    /// This follows the existing stable ID; it never prepares or shapes text.
    pub fn setCommittedSpace(self: *Binding, token: ui.SpaceToken) !void {
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        const bound = self.token orelse return error.NotBound;
        const scope = bound.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const generation = self.coordinate_generation;
        if (generation == std.math.maxInt(u64)) return error.IdExhausted;
        try self.checkBinding(bound);
        const candidate = try token.binding();
        try candidate.checkWindow(bound.window);
        try self.checkBinding(bound);
        if (self.coordinate_generation != generation) return error.StaleSpace;
        self.space = candidate;
        self.space_required = true;
        self.coordinate_generation += 1;
    }
    /// Revoke an opted-in space without silently using window coordinates.
    /// Native read/change remain rejected until a new space or a new binding.
    /// A default binding that never opted in has no coordinate borrow to clear.
    pub fn clearCommittedSpace(self: *Binding) !void {
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        if (!self.space_required or self.space == null) return;
        self.space = null;
        self.coordinate_generation +|= 1;
    }
    pub fn hasCommittedSpace(self: *const Binding) !bool {
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        return self.space != null;
    }
    /// Submit a prepared local caret through the selected coordinate authority.
    /// The host supplies geometry from the same existing Editor/visual adapter.
    pub fn setTextCaret(self: *Binding, local_caret: ui.Rect) !void {
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        const bound = self.token orelse return error.NotBound;
        const scope = bound.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const generation = self.coordinate_generation;
        const space = self.space;
        try self.authorize(bound.window);
        if (space) |selected| try selected.setTextCaret(local_caret) else try bound.window.setTextCaret(local_caret);
        try self.checkBinding(bound);
        // No old Context access after a callback revoked or replaced its borrow.
        if (self.coordinate_generation != generation) return error.StaleSpace;
    }
    fn checkBinding(self: *const Binding, token: z.TextClientToken) !void {
        if (token.window.isClosed() or token.window.app.phase == .stopping or token.window.app.phase == .stopped) return error.Closed;
        if (self.editor.native_binding != self or !std.meta.eql(self.token, @as(?z.TextClientToken, token)) or !std.meta.eql(token.window.textClientToken(), @as(?z.TextClientToken, token)) or !self.editor.focused or !self.editor.window_active) return error.StaleTextClient;
    }
    fn authorize(self: *const Binding, window: z.Window) !void {
        const bound = self.token orelse return error.StaleTextClient;
        if (bound.window.app != window.app or !std.meta.eql(bound.window.key, window.key)) return error.StaleTextClient;
        try self.checkBinding(bound);
        const generation = self.coordinate_generation;
        if (self.space_required and self.space == null) return error.StaleSpace;
        if (self.space) |selected| try selected.checkWindow(window);
        try self.checkBinding(bound);
        if (self.coordinate_generation != generation) return error.StaleSpace;
    }
    fn unbound(ptr: *anyopaque, _: z.Window, _: z.text.UnbindReason) void {
        const self: *Binding = @ptrCast(@alignCast(ptr));
        self.space = null;
        self.space_required = false;
        self.coordinate_generation +|= 1;
        self.token = null;
        // Native cancellation may have delivered a new binding to this same
        // Editor before the retired client's unbound callback reaches us.
        if (self.editor.native_binding != self) return;
        self.editor.native_binding = null;
        self.editor.focused = false;
        self.editor.dragging = false;
        // The core already reset native preedit before this notification.
        if (self.editor.buffer.cancelComposition()) self.editor.refresh();
    }
    fn read(ptr: *anyopaque, window: z.Window, storage: []u8) !z.text.Snapshot {
        const self: *Binding = @ptrCast(@alignCast(ptr));
        try self.authorize(window);
        const buffer = &self.editor.buffer;
        if (buffer.revision == std.math.maxInt(u64)) return error.IdExhausted;
        const selection = buffer.selection();
        const selected = selection.range();
        const text = buffer.text();
        if (selected.end - selected.start > storage.len) return error.CapacityExceeded;
        // Fit a contiguous scalar-aligned context around the complete selection.
        const spare = storage.len - (selected.end - selected.start);
        var start = selected.start - @min(selected.start, spare / 2);
        while (!@import("text_buffer.zig").isBoundary(text, start)) start += 1;
        var end = start + @min(text.len - start, storage.len);
        while (!@import("text_buffer.zig").isBoundary(text, end)) end -= 1;
        if (end < selected.end) return error.CapacityExceeded;
        @memcpy(storage[0 .. end - start], text[start..end]);
        return .{
            .range = .{ .start = try buffer.utf16Offset(start), .end = try buffer.utf16Offset(end) },
            .selection = .{ .anchor = try buffer.utf16Offset(selection.anchor), .caret = try buffer.utf16Offset(selection.caret) },
            .composition = if (buffer.composition()) |marked| .{ .start = try buffer.utf16Offset(marked.range.start), .end = try buffer.utf16Offset(marked.range.end) } else null,
            .revision = buffer.revision,
            .bytes = end - start,
        };
    }
    fn change(ptr: *anyopaque, window: z.Window, value: z.text.Change) !z.text.ChangeResult {
        const self: *Binding = @ptrCast(@alignCast(ptr));
        try self.authorize(window);
        const buffer = &self.editor.buffer;
        // Native surrounding deletion/reconversion cannot silently discard an
        // active virtual replacement. The IME can finish or cancel it first.
        if (buffer.composition() != null) return error.CompositionActive;
        const changed = switch (value) {
            .select => |selection| try buffer.setSelection(.{ .anchor = try buffer.byteOffsetFromUtf16(selection.anchor), .caret = try buffer.byteOffsetFromUtf16(selection.caret) }),
            .replace => |replacement| try self.editor.replaceText(.{ .start = try buffer.byteOffsetFromUtf16(replacement.range.start), .end = try buffer.byteOffsetFromUtf16(replacement.range.end) }, replacement.text),
        };
        if (!changed) return .applied;
        if (value == .select) {
            self.editor.reveal_caret = true;
            self.editor.preferred_x = null;
        }
        if (self.changed) |callback| try callback.call(callback.context, window);
        return .applied;
    }
};

test "binding bounded context preserves global UTF16 direction and replacement transactions without allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var editor = try editing.Editor.init(failing.allocator(), .{ .buffer = .{ .max_bytes = 32, .undo_entries = 4, .undo_bytes = 64, .composition_bytes = 8 } }, "pre😀post");
    defer editor.deinit();
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var binding = Binding.init(&editor, std.Thread.getCurrentId());
    try binding.bind(window);
    defer binding.unbind() catch unreachable;
    failing.fail_index = failing.alloc_index;
    _ = try editor.buffer.setSelection(.{ .anchor = 7, .caret = 3 });
    var storage: [4]u8 = undefined;
    const value = try window.readTextClient(binding.token.?, &storage);
    try std.testing.expectEqualStrings("😀", storage[0..value.bytes]);
    try std.testing.expectEqual(z.text.Range{ .start = 3, .end = 5 }, value.range);
    try std.testing.expectEqual(z.text.Selection{ .anchor = 5, .caret = 3 }, value.selection);
    const revision = editor.buffer.revision;
    try std.testing.expectError(error.InvalidBoundary, window.changeTextClient(binding.token.?, .{ .select = .{ .anchor = 4, .caret = 5 } }));
    try std.testing.expectError(error.CapacityExceeded, window.changeTextClient(binding.token.?, .{ .replace = .{ .range = .{ .start = 3, .end = 5 }, .text = "abcdefghijklmnopqrstuvwxyz0123456789" } }));
    try std.testing.expectError(error.EmbeddedNul, window.changeTextClient(binding.token.?, .{ .replace = .{ .range = .{ .start = 3, .end = 5 }, .text = "x\x00" } }));
    try std.testing.expectEqual(revision, editor.buffer.revision);
    try std.testing.expectEqualStrings("pre😀post", editor.buffer.text());
    _ = try window.changeTextClient(binding.token.?, .{ .replace = .{ .range = .{ .start = 3, .end = 5 }, .text = "中" } });
    try std.testing.expectEqualStrings("pre中post", editor.buffer.text());
    try std.testing.expect(try editor.buffer.undo());
    try std.testing.expectEqualStrings("pre😀post", editor.buffer.text());
    _ = try editor.buffer.setComposition("文", .{ .anchor = 3, .caret = 3 });
    const marked = editor.buffer.revision;
    try std.testing.expectError(error.CompositionActive, window.changeTextClient(binding.token.?, .{ .replace = .{ .range = .{ .start = 3, .end = 5 }, .text = "" } }));
    try std.testing.expectEqual(marked, editor.buffer.revision);
    try std.testing.expectEqualStrings("文", editor.buffer.composition().?.text);
}
test "binding reports explicit layout failure after preserving the successful document edit" {
    var editor = try editing.Editor.init(std.testing.allocator, .{}, "abc");
    defer editor.deinit();
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var binding = Binding.init(&editor, std.Thread.getCurrentId());
    var calls: usize = 0;
    const Host = struct {
        fn changed(ptr: *anyopaque, _: z.Window) !void {
            const n: *usize = @ptrCast(@alignCast(ptr));
            n.* += 1;
            return error.LayoutRequired;
        }
    };
    binding.changed = .{ .context = &calls, .call = Host.changed };
    try binding.bind(window);
    defer binding.unbind() catch unreachable;
    try std.testing.expectError(error.LayoutRequired, window.changeTextClient(binding.token.?, .{ .replace = .{ .range = .{ .start = 0, .end = 1 }, .text = "x" } }));
    try std.testing.expectEqualStrings("xbc", editor.buffer.text());
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expect(try editor.buffer.undo());
    try std.testing.expectEqualStrings("abc", editor.buffer.text());
}

test "binding retains its borrow until deferred close unbound cancels the sole composition" {
    var editor = try editing.Editor.init(std.testing.allocator, .{}, "abc");
    defer editor.deinit();
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    var binding = Binding.init(&editor, std.Thread.getCurrentId());
    try binding.bind(window);
    _ = try editor.buffer.setComposition("文", .{ .anchor = 3, .caret = 3 });
    editor.refresh();
    const scope = window.beginCallback().?;
    try std.testing.expectEqual(z.CloseResult.deferred, try window.destroy());
    try std.testing.expect(window.isClosed() and binding.token != null);
    try std.testing.expectError(error.UnbindPending, binding.unbind());
    try std.testing.expect(binding.token != null and editor.buffer.composition() != null);
    scope.end();
    try app.dispatch();
    try std.testing.expect(binding.token == null and editor.buffer.composition() == null and !editor.focused);
    try binding.unbind();
    try std.testing.expectEqualStrings("abc", editor.buffer.text());
    try std.testing.expect(!editor.buffer.canUndo());
}

test "retired binding cleanup does not cancel the new owner created during native focus revocation" {
    var editor = try editing.Editor.init(std.testing.allocator, .{}, "abc");
    defer editor.deinit();
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var old = Binding.init(&editor, std.Thread.getCurrentId());
    var next = Binding.init(&editor, std.Thread.getCurrentId());
    const Probe = struct {
        editor: *editing.Editor,
        next: *Binding,
        handed_off: bool = false,
        fn event(ptr: *anyopaque, owner: z.Window, value: z.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (value != .text_preedit_revoked or self.handed_off) return;
            self.handed_off = true;
            _ = self.editor.buffer.cancelComposition();
            self.editor.refresh();
            self.next.bind(owner) catch unreachable;
            _ = self.editor.buffer.setComposition("新", .{ .anchor = 3, .caret = 3 }) catch unreachable;
            self.editor.refresh();
        }
        fn detach(_: *anyopaque) void {}
    };
    var probe: Probe = .{ .editor = &editor, .next = &next };
    try window.setContent(.{ .context = &probe, .event = Probe.event, .detach = Probe.detach });
    try old.bind(window);
    defer old.unbind() catch unreachable;
    defer next.unbind() catch unreachable;
    _ = try editor.buffer.setComposition("旧", .{ .anchor = 3, .caret = 3 });
    editor.refresh();
    app.native.emit_text_cancel = true;
    app.windows.get(window.key).?.emit(.{ .focus = false });
    try std.testing.expect(probe.handed_off and old.token == null and next.token != null);
    try std.testing.expect(editor.focused and editor.window_active);
    try std.testing.expect(editor.buffer.composition() != null);
    try std.testing.expectEqualStrings("新", editor.buffer.composition().?.text);
    var storage: [16]u8 = undefined;
    const snapshot = try window.readTextClient(next.token.?, &storage);
    try std.testing.expectEqualStrings("abc", storage[0..snapshot.bytes]);
}

test "one Editor rejects a second Window binding including a disabled physical owner" {
    var editor = try editing.Editor.init(std.testing.allocator, .{}, "abc");
    defer editor.deinit();
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const a = try app.createWindow(.{});
    defer _ = a.destroy() catch unreachable;
    const b = try app.createWindow(.{});
    defer _ = b.destroy() catch unreachable;
    var old = Binding.init(&editor, std.Thread.getCurrentId());
    var next = Binding.init(&editor, std.Thread.getCurrentId());
    try old.bind(a);
    defer old.unbind() catch unreachable;
    defer next.unbind() catch unreachable;
    const token = old.token.?;
    try std.testing.expectError(error.EditorAlreadyBound, next.bind(b));
    try std.testing.expect(editor.native_binding == &old and next.token == null and !try b.hasTextClient());
    try a.perform(.disable);
    try std.testing.expect(try a.hasTextClient());
    try std.testing.expect(a.textClientToken() == null);
    try std.testing.expectError(error.EditorAlreadyBound, next.bind(b));
    try std.testing.expect(editor.native_binding == &old and std.meta.eql(token, old.token.?));
    try a.perform(.enable);
    try old.unbind();
    try next.bind(b);
    try std.testing.expect(editor.native_binding == &next and old.token == null and next.token != null);
}

test "close-pending native owner must finish unbound before another Window takes the Editor" {
    var editor = try editing.Editor.init(std.testing.allocator, .{}, "abc");
    defer editor.deinit();
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const a = try app.createWindow(.{});
    defer _ = a.destroy() catch unreachable;
    const b = try app.createWindow(.{});
    defer _ = b.destroy() catch unreachable;
    var old = Binding.init(&editor, std.Thread.getCurrentId());
    var next = Binding.init(&editor, std.Thread.getCurrentId());
    try old.bind(a);
    defer old.unbind() catch unreachable;
    defer next.unbind() catch unreachable;
    _ = try editor.buffer.setComposition("旧", .{ .anchor = 3, .caret = 3 });
    const scope = a.beginCallback().?;
    try std.testing.expectEqual(z.CloseResult.deferred, try a.destroy());
    const attempted = next.bind(b);
    const preserved = old.token != null and next.token == null and editor.native_binding == &old and editor.buffer.composition() != null;
    scope.end();
    try app.dispatch();
    try std.testing.expectError(error.EditorAlreadyBound, attempted);
    try std.testing.expect(preserved and old.token == null and editor.native_binding == null and editor.buffer.composition() == null);
    try next.bind(b);
    try std.testing.expect(editor.native_binding == &next);
}

test "failed or closing handoff does not publish a new owner or allow another foreign bind" {
    const Mode = enum { failure, close };
    const Probe = struct {
        editor: *editing.Editor,
        old: *Binding,
        next: *Binding,
        competing: *Binding,
        source: z.Window,
        target: z.Window,
        mode: Mode,
        attempted: bool = false,
        rejected: bool = false,
        fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (value != .text_preedit_revoked) return;
            if (std.meta.eql(window.key, self.target.key)) {
                std.testing.expectError(error.Busy, self.competing.bind(self.source)) catch unreachable;
                if (self.mode == .close) _ = window.destroy() catch unreachable;
                return;
            }
            if (self.attempted) return;
            self.attempted = true;
            if (self.mode == .failure) window.app.native.fail_text_cancel = true;
            const expected = if (self.mode == .failure) error.CompositionQueryFailed else error.Closed;
            std.testing.expectError(expected, self.next.bind(self.target)) catch unreachable;
            std.testing.expect(self.editor.native_binding == self.old and self.next.token == null) catch unreachable;
            std.testing.expect(self.editor.focused and self.editor.buffer.composition() != null) catch unreachable;
            self.rejected = true;
        }
        fn detach(_: *anyopaque) void {}
        fn read(_: *anyopaque, _: z.Window, storage: []u8) !z.text.Snapshot {
            storage[0] = 'x';
            return .{ .range = .{ .start = 0, .end = 1 }, .selection = .{ .anchor = 1, .caret = 1 }, .revision = 1, .bytes = 1 };
        }
        fn change(_: *anyopaque, _: z.Window, _: z.text.Change) !z.text.ChangeResult {
            return .applied;
        }
    };
    for ([_]Mode{ .failure, .close }) |mode| {
        var editor = try editing.Editor.init(std.testing.allocator, .{}, "abc");
        defer editor.deinit();
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        const source = try app.createWindow(.{});
        defer _ = source.destroy() catch unreachable;
        const target = try app.createWindow(.{});
        defer _ = target.destroy() catch unreachable;
        var old = Binding.init(&editor, std.Thread.getCurrentId());
        var next = Binding.init(&editor, std.Thread.getCurrentId());
        var competing = Binding.init(&editor, std.Thread.getCurrentId());
        var probe: Probe = .{ .editor = &editor, .old = &old, .next = &next, .competing = &competing, .source = source, .target = target, .mode = mode };
        try source.setContent(.{ .context = &probe, .event = Probe.event, .detach = Probe.detach });
        try target.setContent(.{ .context = &probe, .event = Probe.event, .detach = Probe.detach });
        _ = try target.setTextClient(.{ .context = &probe, .owner = std.Thread.getCurrentId(), .read = Probe.read, .change = Probe.change });
        try old.bind(source);
        defer old.unbind() catch unreachable;
        defer next.unbind() catch unreachable;
        defer competing.unbind() catch unreachable;
        _ = try editor.buffer.setComposition("旧", .{ .anchor = 3, .caret = 3 });
        app.native.emit_text_cancel = true;
        app.windows.get(source.key).?.emit(.{ .focus = false });
        try std.testing.expect(probe.attempted and probe.rejected and editor.native_binding == null);
        try std.testing.expect(old.token == null and next.token == null and competing.token == null and editor.buffer.composition() == null);
        try app.dispatch();
    }
}
