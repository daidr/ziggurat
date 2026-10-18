const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const t = @import("ziggurat_text_layout");
const d = @import("ziggurat_document");
const editing = @import("ziggurat_document_editor");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("NO_STRICT", "1");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn zlg_test_commit(*anyopaque, [*:0]const u8) void;
extern fn zlg_resource_count() u32;
const bounds: ui.Rect = .{ .x = 0, .y = 0, .width = 200, .height = 100 };
const Mode = enum { pass, consume, edit_pass, edit_consume, reenter, close, chord, layout_failure, change_mode };
const Host = struct {
    adapter: *editing.Adapter,
    peer: *editing.Adapter,
    mode: Mode = .pass,
    window: z.Window = undefined,
    context: ui.Context = undefined,
    calls: usize = 0,
    keys: usize = 0,
    text: usize = 0,
    preedit: usize = 0,
    native: usize = 0,
    producer: ?z.TextProducer = null,
    failure: ?anyerror = null,
    chord: bool = false,
    engine_fault: ?*std.testing.FailingAllocator = null,
    fn draw(_: *anyopaque, frame: *ui.Frame) void {
        frame.clear(0xffffff);
    }
    fn action(_: *anyopaque, _: u64) void {}
    fn input(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *Host = @ptrCast(@alignCast(ptr));
        return self.adapter.handleEvent(self.window, event, bounds, .{}) catch |err| {
            self.failure = err;
            return true;
        };
    }
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.failure = value.err orelse error.Diagnostic;
    }
    fn planner(_: *anyopaque, _: [2]*editing.LayoutProbe) !editing.PairProjection {
        return error.UnexpectedPlanner;
    }
    fn hook(ptr: *anyopaque, window: z.Window, adapter: *editing.Adapter, input_value: editing.PreInput) editing.PreInputDecision {
        const self: *Host = @ptrCast(@alignCast(ptr));
        return self.checked(window, adapter, input_value) catch |err| {
            self.failure = err;
            return .consume;
        };
    }
    fn checked(self: *Host, window: z.Window, adapter: *editing.Adapter, input_value: editing.PreInput) !editing.PreInputDecision {
        self.calls += 1;
        switch (input_value) {
            .key => self.keys += 1,
            .text => |text| {
                self.text += 1;
                self.producer = text.producer;
            },
            .preedit => self.preedit += 1,
            .native_change => self.native += 1,
        }
        try std.testing.expectError(error.Busy, adapter.setPreInputHook(null));
        try std.testing.expectError(error.ClientsAlive, adapter.close());
        try std.testing.expectError(error.Busy, adapter.prepare(bounds, .{}));
        try std.testing.expectError(error.Busy, editing.preparePair(window, adapter, self.peer, .{ bounds, bounds }, .{ .{}, .{} }));
        try std.testing.expectError(error.Busy, editing.projectPair(window, self.peer, adapter, .{ bounds, bounds }, .{ .{}, .{} }, .{ .context = self, .build = planner }));
        switch (self.mode) {
            .pass => return .pass,
            .consume => return .consume,
            .change_mode => {
                try std.testing.expectEqual(z.TextInputModeResult.applied, try window.setTextInputMode(.keyboard_compose));
                return .pass;
            },
            .edit_pass, .edit_consume, .layout_failure => {
                _ = try adapter.replaceSelections("H");
                if (self.mode == .layout_failure) {
                    const fault = self.engine_fault.?;
                    fault.fail_index = fault.alloc_index;
                }
                return if (self.mode == .edit_consume) .consume else .pass;
            },
            .reenter => {
                try std.testing.expectError(error.Busy, adapter.handleEvent(window, .{ .text_input = .{ .text = "nested", .producer = .application } }, bounds, .{}));
                try std.testing.expectError(error.Busy, adapter.handleKey(window, .{ .key = .enter }, bounds, .{}));
                return .pass;
            },
            .close => {
                _ = try window.destroy();
                return .pass;
            },
            .chord => {
                if (input_value != .key) return .pass;
                const key = input_value.key;
                if (self.chord) {
                    self.chord = false;
                    return .consume;
                }
                if (key.key == .k and key.modifiers.control) {
                    self.chord = true;
                    return .consume;
                }
                return .pass;
            },
        }
    }
    fn nativeText(self: *Host) !void {
        if (builtin.os.tag == .windows) {
            _ = c.SendMessageW(self.window.nativeHandle(), c.WM_UNICHAR, 'X', 0);
        } else {
            const native = self.window.app.windows.get(self.window.key).?.native.native.?;
            zlg_test_commit(native, "X");
        }
        if (self.failure) |err| return err;
    }
};
fn textEquals(document: *d.Document, expected: []const u8) !void {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(expected, buffer[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &buffer)]);
}
fn scenario(allocator: std.mem.Allocator, mode: Mode, native_change: bool, bound: bool) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "a", .{});
    defer document.close() catch unreachable;
    const peer_document = try d.Document.create(allocator, std.Thread.getCurrentId(), "peer", .{});
    defer peer_document.close() catch unreachable;
    var fault = std.testing.FailingAllocator.init(allocator, .{});
    const engine = try t.Engine.create(fault.allocator(), std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    var adapter_fault = std.testing.FailingAllocator.init(allocator, .{});
    const adapter = try editing.Adapter.create(adapter_fault.allocator(), document, engine, .{});
    defer adapter.close() catch unreachable;
    const peer = try editing.Adapter.create(allocator, peer_document, engine, .{});
    defer peer.close() catch unreachable;
    var host: Host = .{ .adapter = adapter, .peer = peer, .mode = mode, .engine_fault = &fault };
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &host, .emit = Host.diagnostic } });
    defer app.deinit();
    host.context = ui.Context.init(&host, Host.draw, Host.action);
    host.context.on_input = Host.input;
    host.window = try app.createWindow(.{ .width = 240, .height = 140 });
    defer _ = host.window.destroy() catch unreachable;
    _ = try adapter.setSelection(.{ .anchor = 0, .caret = 1 }, .downstream);
    _ = try adapter.prepare(bounds, .{});
    _ = try peer.prepare(bounds, .{});
    try host.context.attach(host.window);
    if (bound) try adapter.bind(host.window);
    defer {
        _ = host.window.destroy() catch unreachable;
        app.dispatch() catch unreachable;
        adapter.unbind() catch unreachable;
    }
    const default_allocations = adapter_fault.alloc_index;
    adapter_fault.fail_index = default_allocations;
    fault.fail_index = fault.alloc_index;
    _ = host.context.handleKeyInput(host.window, .{ .key = .c, .modifiers = .{ .control = true } });
    adapter_fault.fail_index = std.math.maxInt(usize);
    fault.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(default_allocations, adapter_fault.alloc_index);
    try std.testing.expectEqual(@as(usize, 0), host.calls);
    try adapter.setPreInputHook(.{ .context = &host, .call = Host.hook });
    defer adapter.setPreInputHook(null) catch unreachable;
    const revision = try document.version();
    if (native_change) {
        const result = try host.window.changeTextClient(host.window.textClientToken().?, .{ .replace = .{ .range = .{ .start = 0, .end = 1 }, .text = "X" } });
        const expected: z.text.ChangeResult = switch (mode) {
            .consume => .rejected,
            .edit_pass, .edit_consume, .close, .layout_failure, .change_mode => .superseded,
            else => .applied,
        };
        try std.testing.expectEqual(expected, result);
        try std.testing.expectEqual(@as(usize, 1), host.native);
    } else {
        try host.nativeText();
        try std.testing.expectEqual(@as(usize, 1), host.text);
        try std.testing.expectEqual(@as(?z.TextProducer, if (builtin.os.tag == .windows) .win32_character else .gtk_text_service_commit), host.producer);
    }
    fault.fail_index = std.math.maxInt(usize);
    if (host.window.isClosed()) try app.dispatch();
    if (host.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 1), host.calls);
    switch (mode) {
        .consume, .close, .change_mode => {
            try textEquals(document, "a");
            try std.testing.expectEqual(revision, try document.version());
        },
        .edit_pass, .edit_consume, .layout_failure => {
            try textEquals(document, "H");
            if (mode == .layout_failure) {
                const status = try adapter.status();
                try std.testing.expect(status.layout_required);
                try std.testing.expect(status.last_layout_error != null);
                try std.testing.expectEqual(error.OutOfMemory, status.last_layout_error.?);
                _ = try adapter.prepare(bounds, .{});
                try std.testing.expectEqual(@as(usize, 1), host.calls);
            }
            try std.testing.expect((try adapter.undo()).changed);
            try textEquals(document, "a");
            try std.testing.expect(!(try adapter.undo()).changed);
        },
        else => try textEquals(document, if (bound) "X" else "a"),
    }
    if (!host.window.isClosed()) {
        if (mode == .pass and !native_change and bound) {
            const before_preedit = host.calls;
            host.mode = .consume;
            const preview: z.Event = .{ .text_preedit = .{ .text = "TEMP", .selection_start = 4, .selection_end = 4 } };
            try std.testing.expect(try adapter.handleEvent(host.window, preview, bounds, .{}));
            try std.testing.expect(try document.composition() == null);
            host.mode = .pass;
            try std.testing.expect(try adapter.handleEvent(host.window, preview, bounds, .{}));
            try std.testing.expect(try document.composition() != null);
            try std.testing.expectEqual(before_preedit + 2, host.calls);
            try std.testing.expectEqual(@as(usize, 2), host.preedit);
            try std.testing.expect(try adapter.handleEvent(host.window, .text_preedit_cancel, bounds, .{}));
            try std.testing.expect(try document.composition() == null);
            try std.testing.expectEqual(before_preedit + 2, host.calls);
        }
        // The same physical-key route offers a compatibility edit_key after a
        // typed pass. It must not invoke the hook twice.
        host.mode = .pass;
        if (mode == .pass and bound) {
            _ = try adapter.setSelection(.{ .anchor = 0, .caret = 1 }, .downstream);
            _ = try adapter.prepare(bounds, .{});
            const enter_calls = host.calls;
            try std.testing.expect(host.context.handleKeyInput(host.window, .{ .key = .enter }));
            try std.testing.expectEqual(enter_calls + 1, host.calls);
            try textEquals(document, "\n");
            try std.testing.expect((try adapter.undo()).changed);
            try textEquals(document, "X");
        }
        const before = host.calls;
        _ = host.context.handleKeyInput(host.window, .{ .key = .c, .modifiers = .{ .control = true } });
        try std.testing.expectEqual(before + 1, host.calls);
        host.mode = .chord;
        try std.testing.expect(host.context.handleKeyInput(host.window, .{ .key = .k, .modifiers = .{ .control = true } }));
        try std.testing.expect(host.context.handleKeyInput(host.window, .{ .key = .c }));
        try std.testing.expect(!host.chord);
        try std.testing.expectEqual(before + 3, host.calls);
        const lifecycle_calls = host.calls;
        _ = try host.window.destroy();
        try app.dispatch();
        try std.testing.expectEqual(lifecycle_calls, host.calls);
    }
}
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const before = t.resourceCounts();
    for ([_]Mode{ .pass, .consume, .edit_pass, .edit_consume, .reenter, .close, .layout_failure, .change_mode }) |mode| for ([_]bool{ false, true }) |native_change| try scenario(gpa.allocator(), mode, native_change, true);
    for ([_]Mode{ .pass, .consume, .edit_pass, .edit_consume, .reenter, .close, .change_mode }) |mode| try scenario(gpa.allocator(), mode, false, false);
    try std.testing.expectEqual(before, t.resourceCounts());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("pre-input: native producer paths, one hook per typed key, explicit native veto, callback edit/close/reentry, failed presentation and sole undo authority resources=0\n", .{});
}
