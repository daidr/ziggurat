const std = @import("std");
const z = @import("ziggurat");
const d = @import("ziggurat_document");
const t = @import("ziggurat_text_layout");
const editing = @import("ziggurat_document_editor");
const bounds: editing.Rect = .{ .x = 0, .y = 0, .width = 300, .height = 150 };
const State = struct {
    adapter: *editing.Adapter,
    failing: *std.testing.FailingAllocator,
    token: ?editing.NativeObserverToken = null,
    replacement: ?editing.NativeObserverToken = null,
    count: usize = 0,
    repaired: bool = false,
    diagnostics: usize = 0,
    diagnostic_error: ?anyerror = null,
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value.domain == .core and value.operation == .text_input and value.err != null and value.err.? == error.LayoutRequired) {
            self.diagnostics += 1;
        } else if (value.err) |err| self.diagnostic_error = err;
    }
    fn replaced(ptr: *anyopaque, _: z.Window, _: *editing.Adapter, _: editing.NativeChange) !void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.count += 1;
    }
    fn first(ptr: *anyopaque, _: z.Window, adapter: *editing.Adapter, change: editing.NativeChange) !void {
        const self: *State = @ptrCast(@alignCast(ptr));
        try std.testing.expectEqual(self.adapter, adapter);
        try std.testing.expect(change.layout_error == null);
        try std.testing.expect(try adapter.clearNativeObserver(self.token.?));
        self.replacement = try adapter.observeNativeChanges(.{ .context = self, .call = replaced });
        try std.testing.expect(!try adapter.clearNativeObserver(self.token.?));
        self.count += 1;
    }
    fn repair(ptr: *anyopaque, _: z.Window, adapter: *editing.Adapter, change: editing.NativeChange) !void {
        const self: *State = @ptrCast(@alignCast(ptr));
        const failure = change.layout_error orelse return error.MissingLayoutFailure;
        try std.testing.expectEqual(error.LayoutRequired, failure);
        try std.testing.expectEqual(change.revision, (try adapter.status()).revision);
        self.failing.fail_index = std.math.maxInt(usize);
        _ = try adapter.prepare(bounds, .{});
        self.repaired = true;
    }
};
pub fn run(allocator: std.mem.Allocator) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "one\ntwo", .{});
    defer document.close() catch unreachable;
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const engine = try t.Engine.create(failing.allocator(), std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const adapter = try editing.Adapter.create(allocator, document, engine, .{});
    defer adapter.close() catch unreachable;
    var state: State = .{ .adapter = adapter, .failing = &failing };
    state.token = try adapter.observeNativeChanges(.{ .context = &state, .call = State.first });
    try std.testing.expectError(error.ObserverAttached, adapter.close());
    try std.testing.expectError(error.ObserverAttached, adapter.observeNativeChanges(.{ .context = &state, .call = State.first }));
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    _ = try adapter.prepare(bounds, .{});
    try adapter.bind(window);
    defer adapter.unbind() catch unreachable;
    const native = window.textClientToken().?;
    _ = try window.changeTextClient(native, .{ .select = .{ .anchor = 1, .caret = 1 } });
    try std.testing.expectEqual(@as(usize, 1), state.count);
    _ = try window.changeTextClient(native, .{ .select = .{ .anchor = 1, .caret = 1 } });
    try std.testing.expectEqual(@as(usize, 1), state.count);
    _ = try window.changeTextClient(native, .{ .select = .{ .anchor = 2, .caret = 2 } });
    try std.testing.expectEqual(@as(usize, 2), state.count);
    try std.testing.expect(try adapter.clearNativeObserver(state.replacement.?));
    const repair = try adapter.observeNativeChanges(.{ .context = &state, .call = State.repair });
    defer _ = adapter.clearNativeObserver(repair) catch unreachable;
    failing.fail_index = failing.alloc_index;
    const before = try document.version();
    try std.testing.expectEqual(z.text.ChangeResult.applied, try window.changeTextClient(native, .{ .replace = .{ .range = .{ .start = 0, .end = 3 }, .text = "replacement" } }));
    if (!state.repaired) std.debug.print("native observer repair missing diagnostics={} diagnostic_error={?}\n", .{ state.diagnostics, state.diagnostic_error });
    try std.testing.expect(state.repaired);
    try std.testing.expectEqual(before + 1, try document.version());
    try std.testing.expectEqual(@as(usize, 1), state.diagnostics);
    if (state.diagnostic_error) |err| return err;
    _ = try adapter.viewVersion();
    var bytes: [100]u8 = undefined;
    try std.testing.expectEqualStrings("replacement\ntwo", bytes[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &bytes)]);
    try std.testing.expect(try document.undo());
    try std.testing.expectEqualStrings("one\ntwo", bytes[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &bytes)]);
    try std.testing.expect(try document.redo());
    try std.testing.expectEqualStrings("replacement\ntwo", bytes[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &bytes)]);
    try releaseContext(allocator, engine, app);
}
fn releaseContext(allocator: std.mem.Allocator, engine: *t.Engine, app: *z.App) !void {
    const Witness = struct { callback_done: bool = false, closed: bool = false, failure: ?anyerror = null };
    const Context = struct {
        allocator: std.mem.Allocator,
        witness: *Witness,
        adapter: *editing.Adapter,
        observer: editing.NativeObserverToken = undefined,
        fn update(ptr: *anyopaque, window: z.Window, adapter: *editing.Adapter, _: editing.NativeChange) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try std.testing.expect(try adapter.clearNativeObserver(self.observer));
            _ = try window.destroy();
            try std.testing.expect(!self.witness.closed);
            self.witness.callback_done = true;
        }
        fn closed(ptr: *anyopaque, _: z.Window) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (!self.witness.callback_done) self.witness.failure = error.EarlyClose;
            self.adapter.close() catch |err| {
                self.witness.failure = err;
            };
            self.witness.closed = true;
            const source = self.allocator;
            source.destroy(self);
        }
    };
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    var witness: Witness = .{};
    const context = try allocator.create(Context);
    context.* = .{ .allocator = allocator, .witness = &witness, .adapter = try editing.Adapter.create(allocator, document, engine, .{}) };
    const window = try app.createWindow(.{ .on_closed = .{ .context = context, .notify = Context.closed } });
    _ = try context.adapter.prepare(bounds, .{});
    context.observer = try context.adapter.observeNativeChanges(.{ .context = context, .call = Context.update });
    try context.adapter.bind(window);
    try std.testing.expectError(error.StaleTextClient, window.changeTextClient(window.textClientToken().?, .{ .select = .{ .anchor = 1, .caret = 1 } }));
    try app.dispatch();
    if (witness.failure) |err| return err;
    try std.testing.expect(witness.closed and witness.callback_done);
}
