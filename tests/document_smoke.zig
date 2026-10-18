const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const d = @import("ziggurat_document");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
    @cInclude("imm.h");
}) else struct {};
extern fn zlg_test_surrounding(*anyopaque, [*]u8, usize, *usize, *usize) c_int;
extern fn zlg_test_delete_surrounding(*anyopaque, c_int, c_int) c_int;
extern fn zlg_test_commit(*anyopaque, [*:0]const u8) void;
extern fn zlg_resource_count() u32;

const prefix_length = 100000 * 11;
const tail = "a😀中bc";
const State = struct {
    document: *d.Document,
    binding: d.ClientBinding = undefined,
    failure: ?anyerror = null,
    changes: usize = 0,
    close_on_change: bool = false,
    fn event(ptr: *anyopaque, window: z.Window, event_value: z.Event) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = self.binding.handleEvent(window, event_value) catch |err| {
            self.failure = err;
        };
    }
    fn detach(_: *anyopaque) void {}
    fn changed(ptr: *anyopaque, window: z.Window) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.changes += 1;
        // This callback is the explicit layout/candidate update phase. Its
        // query sees the edit immediately, before any paint has happened.
        const selection = try self.document.selection();
        try std.testing.expect(selection.caret <= try self.document.byteLength());
        try window.setTextCaret(.{ .x = 8, .y = 12, .width = 1, .height = 20 });
        if (self.close_on_change) {
            _ = try window.destroy();
            try std.testing.expectError(error.ClientAttached, self.document.close());
        }
    }
};
fn expectTail(document: anytype, expected: []const u8) !void {
    var storage: [64]u8 = undefined;
    const length = try document.read(.{ .start = prefix_length, .end = try document.byteLength() }, &storage);
    try std.testing.expectEqualStrings(expected, storage[0..length]);
}
fn select(document: *d.Document) !void {
    _ = try document.setSelection(.{ .anchor = prefix_length + 1, .caret = prefix_length + 8 });
}
fn check(allocator: std.mem.Allocator) !void {
    const input = try allocator.alloc(u8, prefix_length + tail.len);
    defer allocator.free(input);
    for (0..100000) |i| @memcpy(input[i * 11 ..][0..11], "0123456789\n");
    @memcpy(input[prefix_length..], tail);
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const document = try d.Document.create(failing.allocator(), std.Thread.getCurrentId(), input, .{ .history_entries = 4 });
    var document_open = true;
    defer if (document_open) document.close() catch unreachable;
    const saved = try document.snapshot();
    defer saved.close() catch unreachable;
    try std.testing.expectEqual(@as(usize, 100001), try document.lineCount());
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var state: State = .{ .document = document };
    state.binding = d.ClientBinding.init(document, std.Thread.getCurrentId());
    state.binding.changed = .{ .context = &state, .call = State.changed };
    try window.setContent(.{ .context = &state, .event = State.event, .detach = State.detach });
    try state.binding.bind(window);
    try select(document);
    const before = try document.stats();
    // Querying the million-byte committed document must remain allocation-free.
    failing.fail_index = failing.alloc_index;
    if (builtin.os.tag == .windows) {
        const hwnd = window.nativeHandle();
        const needed = c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_DOCUMENTFEED, 0);
        try std.testing.expect(needed > 0);
        var storage: [12352]u8 align(8) = undefined;
        const offer: *c.RECONVERTSTRING = @ptrCast(&storage);
        offer.dwSize = storage.len;
        try std.testing.expectEqual(needed, c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_DOCUMENTFEED, @bitCast(@intFromPtr(offer))));
        var context: [4096]u8 = undefined;
        const expected = try document.nativeContext(&context);
        try std.testing.expectEqual(@as(u32, @intCast(expected.range.end - expected.range.start)), offer.dwStrLen);
        try std.testing.expectEqual(@as(u32, @intCast((prefix_length + 1 - expected.range.start) * 2)), offer.dwCompStrOffset);
        try std.testing.expectEqual(@as(u32, 3), offer.dwCompStrLen);
        offer.dwSize = storage.len;
        _ = c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_RECONVERTSTRING, @bitCast(@intFromPtr(offer)));
        const offset: u32 = @intCast((prefix_length + 3 - expected.range.start) * 2);
        offer.dwCompStrOffset = offset;
        offer.dwTargetStrOffset = offset;
        offer.dwCompStrLen = 1;
        offer.dwTargetStrLen = 1;
        try std.testing.expectEqual(@as(isize, 1), c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_CONFIRMRECONVERTSTRING, @bitCast(@intFromPtr(offer))));
        try std.testing.expectEqual(d.Selection{ .anchor = prefix_length + 5, .caret = prefix_length + 8 }, try document.selection());
        // An allocation failure in a real committed input leaves the old
        // version/selection intact; native callbacks report the failure.
        const revision = try document.version();
        _ = c.SendMessageW(hwnd, c.WM_UNICHAR, 0x6587, 0);
        try std.testing.expectEqual(error.OutOfMemory, state.failure.?);
        try std.testing.expectEqual(revision, try document.version());
        try expectTail(document, tail);
        state.failure = null;
        failing.fail_index = std.math.maxInt(usize);
        _ = c.SendMessageW(hwnd, c.WM_UNICHAR, 0x6587, 0);
        try expectTail(document, "a😀文bc");
        try std.testing.expect(try document.undo());
        try expectTail(document, tail);
        try select(document);
        offer.dwSize = storage.len;
        _ = c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_RECONVERTSTRING, @bitCast(@intFromPtr(offer)));
        _ = try document.setSelection(.{ .anchor = prefix_length, .caret = prefix_length });
        try std.testing.expectEqual(@as(isize, 0), c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_CONFIRMRECONVERTSTRING, @bitCast(@intFromPtr(offer))));
        try std.testing.expectEqual(d.Selection{ .anchor = prefix_length, .caret = prefix_length }, try document.selection());
    } else {
        const native = app.windows.get(window.key).?.native.native.?;
        var storage: [12288]u8 = undefined;
        var length: usize = 0;
        var cursor: usize = 0;
        try std.testing.expectEqual(@as(c_int, 1), zlg_test_surrounding(native, &storage, storage.len, &length, &cursor));
        try std.testing.expect(length <= storage.len and length < prefix_length);
        try std.testing.expectEqualStrings("a😀中bc", storage[length - tail.len .. length]);
        try std.testing.expectEqual(length - 2, cursor);
        const revision = try document.version();
        try std.testing.expectEqual(@as(c_int, 0), zlg_test_delete_surrounding(native, -2, 2));
        try std.testing.expectEqual(revision, try document.version());
        try expectTail(document, tail);
        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expectEqual(@as(c_int, 1), zlg_test_delete_surrounding(native, -2, 2));
        try expectTail(document, "abc");
        try std.testing.expect(try document.undo());
        try expectTail(document, tail);
        try select(document);
        zlg_test_commit(native, "文");
        try expectTail(document, "a文bc");
        try std.testing.expect(try document.undo());
        try expectTail(document, tail);
    }
    if (state.failure) |err| return err;
    const after = try document.stats();
    try std.testing.expect(after.visited_nodes - before.visited_nodes < 4000);
    try std.testing.expect(after.copied_bytes - before.copied_bytes < 65536);
    try std.testing.expect(state.changes > 0);
    // The final native text callback closes the same window. Its Document pin
    // remains live until callback return, detach and one unbound notification.
    state.close_on_change = true;
    _ = try document.setSelection(.{ .anchor = prefix_length, .caret = prefix_length + 1 });
    if (builtin.os.tag == .windows) {
        _ = c.SendMessageW(window.nativeHandle(), c.WM_UNICHAR, 'X', 0);
    } else zlg_test_commit(app.windows.get(window.key).?.native.native.?, "X");
    try app.dispatch();
    if (state.failure) |err| return err;
    try std.testing.expect(window.isClosed() and state.binding.token == null);
    try document.close();
    document_open = false;
    try expectTail(saved, tail);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
fn multiCheck(allocator: std.mem.Allocator) !void {
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const document = try d.Document.create(failing.allocator(), std.Thread.getCurrentId(), "aa bb", .{});
    defer document.close() catch unreachable;
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var state: State = .{ .document = document };
    state.binding = d.ClientBinding.init(document, std.Thread.getCurrentId());
    try window.setContent(.{ .context = &state, .event = State.event, .detach = State.detach });
    try state.binding.bind(window);
    _ = try document.setSelections(&.{ .{ .anchor = 0, .caret = 2 }, .{ .anchor = 5, .caret = 3 } }, 1);
    const before = try document.version();
    const token = window.textClientToken().?;
    try std.testing.expectError(error.MultipleSelections, window.changeTextClient(token, .{ .select = .{ .anchor = 0, .caret = 0 } }));
    try std.testing.expectEqual(before, try document.version());
    if (builtin.os.tag == .windows) {
        try std.testing.expect(c.SendMessageW(window.nativeHandle(), c.WM_IME_REQUEST, c.IMR_DOCUMENTFEED, 0) > 0);
    } else {
        const native = app.windows.get(window.key).?.native.native.?;
        var context: [12288]u8 = undefined;
        var length: usize = 0;
        var cursor: usize = 0;
        try std.testing.expectEqual(@as(c_int, 1), zlg_test_surrounding(native, &context, context.len, &length, &cursor));
        try std.testing.expectEqual(@as(c_int, 0), zlg_test_delete_surrounding(native, -1, 1));
        try std.testing.expectEqual(before, try document.version());
    }
    failing.fail_index = failing.alloc_index;
    if (builtin.os.tag == .windows) _ = c.SendMessageW(window.nativeHandle(), c.WM_UNICHAR, 0x6587, 0) else zlg_test_commit(app.windows.get(window.key).?.native.native.?, "文");
    try std.testing.expectEqual(error.OutOfMemory, state.failure.?);
    try std.testing.expectEqual(before, try document.version());
    try std.testing.expectEqual(@as(usize, 2), try document.selectionCount());
    failing.fail_index = std.math.maxInt(usize);
    state.failure = null;
    _ = try state.binding.handleEvent(window, .{ .text_preedit = .{ .text = "中文", .selection_start = 6, .selection_end = 6 } });
    if (builtin.os.tag == .windows) _ = c.SendMessageW(window.nativeHandle(), c.WM_UNICHAR, 0x6587, 0) else zlg_test_commit(app.windows.get(window.key).?.native.native.?, "文");
    if (state.failure) |err| return err;
    var output: [32]u8 = undefined;
    try std.testing.expectEqualStrings("文 文", output[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &output)]);
    try std.testing.expect(try document.undo());
    try std.testing.expectEqualStrings("aa bb", output[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &output)]);
    try std.testing.expectEqual(d.Selection{ .anchor = 5, .caret = 3 }, try document.selection());
    try std.testing.expect(try document.redo());
    const saved = try document.snapshot();
    defer saved.close() catch unreachable;
    const Worker = struct {
        app: *z.App,
        document: *d.Document,
        reader: d.Reader,
        matches: [8]d.Range = undefined,
        count: usize = 0,
        revision: u64,
        failure: ?anyerror = null,
        applied: bool = false,
        fn run(self: *@This()) void {
            self.scan() catch |err| {
                self.failure = err;
            };
            self.reader.release() catch |err| {
                self.failure = err;
            };
            self.app.post(.{ .context = self, .call = deliver }) catch |err| {
                self.failure = err;
            };
        }
        fn scan(self: *@This()) !void {
            var prefix: [3]usize = undefined;
            var search = try d.search.Iterator.init(self.reader, .{ .start = 0, .end = try self.reader.byteLength() }, "文", &prefix, .{});
            while (true) switch (try search.step(1)) {
                .yielded => {},
                .done => break,
                .match => |range| {
                    if (self.count == self.matches.len) return error.CapacityExceeded;
                    self.matches[self.count] = range;
                    self.count += 1;
                },
            };
        }
        fn deliver(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            defer self.app.quit();
            if (self.failure != null) return;
            var edits: [8]d.Replacement = undefined;
            d.search.replaceMatches(self.document, self.revision, self.matches[0..self.count], "Z", &edits) catch |err| {
                self.failure = err;
                return;
            };
            self.applied = true;
        }
    };
    var worker: Worker = .{ .app = app, .document = document, .reader = try saved.borrowReader(), .revision = try saved.version() };
    var watchdog: @import("watchdog.zig").Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    var joined = false;
    defer if (!joined) thread.join();
    try app.run();
    thread.join();
    joined = true;
    if (worker.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and worker.applied and worker.count == 2);
    try std.testing.expectEqualStrings("Z Z", output[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &output)]);
    try std.testing.expect(window.isClosed() and state.binding.token == null);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
pub fn main() !void {
    var allocator_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator_state.deinit() == .ok);
    try check(allocator_state.allocator());
    try multiCheck(allocator_state.allocator());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("indexed document native smoke passed: 100k lines, bounded context, transactional failure, edit/undo, stale offer, close, surviving snapshot, atomic multi IME and worker streaming replace via App.post\n", .{});
}
