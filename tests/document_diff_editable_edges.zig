const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const d = @import("ziggurat_document");
const editing = @import("ziggurat_document_editor");
const diff = @import("ziggurat_document_diff");
const viewing = @import("ziggurat_document_diff_view");
const t = @import("ziggurat_text_layout");

fn refresh(inbox: *viewing.Inbox) !void {
    const job = try inbox.begin();
    var result = diff.compare(std.heap.page_allocator, job.a, job.b, .{}) catch |err| {
        try job.release();
        _ = try inbox.finish(job.ticket);
        return err;
    };
    defer result.deinit();
    try job.release();
    defer _ = inbox.finish(job.ticket) catch unreachable;
    try inbox.publish(job.ticket, &result);
}

/// Explicit update-stage probes. Native drawing/input lives in the caller's
/// fixture; this exercises the same View and its retained host Adapters.
pub fn run(allocator: std.mem.Allocator, window: z.Window, view: *viewing.EditableSplit, inbox: *viewing.Inbox, adapters: [2]*editing.Adapter, bounds: ui.Rect, parameters: viewing.Parameters, failing: *std.testing.FailingAllocator) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    for (0..1000) |_| try text.appendSlice(allocator, "line 😀\n");
    for (adapters, [_]*d.Document{ inbox.pair.a, inbox.pair.b }) |adapter, document| _ = try adapter.replaceMany(try document.version(), &.{.{ .range = .{ .start = 0, .end = try document.byteLength() }, .text = text.items }});
    _ = try adapters[1].replace(.{ .start = text.items.len - 1, .end = text.items.len }, "changed\n");
    try refresh(inbox);
    const before = .{ try adapters[0].stats(), try adapters[1].stats() };
    try view.prepare(bounds, parameters);
    try std.testing.expectEqual(@as(usize, 1000), (try view.info()).total_rows);
    const after = .{ try adapters[0].stats(), try adapters[1].stats() };
    try std.testing.expect(after[0].shaped_bytes - before[0].shaped_bytes < text.items.len / 4);
    try std.testing.expect(after[1].shaped_bytes - before[1].shaped_bytes < text.items.len / 4);
    try view.focus(.b);
    _ = try view.handleEvent(.{ .key_input = .{ .key = .end, .modifiers = .{ .control = true } } }, bounds, parameters);
    const bottom = try view.info();
    try std.testing.expect(bottom.anchor_row > 950);
    const caret = try adapters[1].caretRect(.{ .x = bounds.x + (bounds.width - 8) / 2 + 8, .y = bounds.y, .width = (bounds.width - 8) / 2, .height = bounds.height }, parameters.scale);
    try std.testing.expect(caret.y >= bounds.y and caret.y < bounds.y + bounds.height);
    _ = try view.handleEvent(.{ .key_input = .{ .key = .home, .modifiers = .{ .control = true } } }, bounds, parameters);
    try std.testing.expectEqual(@as(usize, 0), (try view.info()).anchor_row);
    // Placement/Plan candidates have several independently failing allocations;
    // a successful two-side publish must never precede one of those failures.
    var rejected: usize = 0;
    for (0..16) |offset| {
        const versions = .{ try adapters[0].viewVersion(), try adapters[1].viewVersion() };
        const owned = (try view.stats()).owned_bytes;
        var narrow = bounds;
        narrow.width -= 30;
        failing.fail_index = failing.alloc_index + offset;
        view.prepare(narrow, parameters) catch |err| {
            failing.fail_index = std.math.maxInt(usize);
            if (err != error.OutOfMemory) return err;
            rejected += 1;
            try std.testing.expectEqual(versions[0], try adapters[0].viewVersion());
            try std.testing.expectEqual(versions[1], try adapters[1].viewVersion());
            try std.testing.expectEqual(owned, (try view.stats()).owned_bytes);
            try view.prepare(bounds, parameters);
            continue;
        };
        failing.fail_index = std.math.maxInt(usize);
        try view.prepare(bounds, parameters);
    }
    try std.testing.expect(rejected >= 6);
    // Empty source, one terminal LF and a non-LF tail use real source lines;
    // comparison records never fabricate a selectable empty EOF record.
    const cases = [_][2][]const u8{ .{ "", "" }, .{ "", "one\n" }, .{ "one", "one\nextra\ntail" }, .{ "one\n", "one\nextra\ntail\n" } };
    for (cases) |pair| {
        for (adapters, [_]*d.Document{ inbox.pair.a, inbox.pair.b }, pair) |adapter, document, value| _ = try adapter.replaceMany(try document.version(), &.{.{ .range = .{ .start = 0, .end = try document.byteLength() }, .text = value }});
        try refresh(inbox);
        try view.prepare(bounds, parameters);
        try std.testing.expect(!(try view.info()).comparison_required);
        try view.focus(.b);
        _ = try view.handleEvent(.{ .key_input = .{ .key = .end, .modifiers = .{ .control = true } } }, bounds, parameters);
        try std.testing.expectEqual(try inbox.pair.b.byteLength(), (try inbox.pair.b.selection()).caret);
        try std.testing.expect(!window.isClosed());
    }
    try adapters[1].setFolds(try inbox.pair.b.version(), &.{.{ .id = 1, .header = 0, .end = try inbox.pair.b.byteLength(), .collapsed = true }});
    try std.testing.expectError(error.FoldedDocument, view.prepare(bounds, parameters));
    try adapters[1].setFolds(try inbox.pair.b.version(), &.{});
    try view.prepare(bounds, parameters);
}

pub fn closeReentry(allocator: std.mem.Allocator, app: *z.App, engine: *t.Engine) !void {
    const Witness = struct { released: bool = false, closed: bool = false, fired: bool = false, failure: ?anyerror = null };
    const Context = struct {
        source: std.mem.Allocator,
        witness: *Witness,
        window: z.Window = undefined,
        inbox: *viewing.Inbox,
        adapters: [2]*editing.Adapter,
        armed: bool = false,
        fn tracked(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
        }
        fn alloc(ptr: *anyopaque, size: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.source.rawAlloc(size, alignment, ret);
        }
        fn resize(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, ret: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.source.rawResize(bytes, alignment, size, ret);
        }
        fn remap(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, ret: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.source.rawRemap(bytes, alignment, size, ret);
        }
        fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.armed) {
                self.armed = false;
                self.witness.fired = true;
                _ = self.window.destroy() catch |err| {
                    self.witness.failure = err;
                };
                if (self.witness.closed) self.witness.failure = error.EarlyContextFree;
            }
            self.source.rawFree(bytes, alignment, ret);
        }
        fn closed(ptr: *anyopaque, _: z.Window) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (!self.witness.released) self.witness.failure = error.EarlyContextFree;
            self.inbox.close() catch |err| {
                self.witness.failure = err;
            };
            for (self.adapters) |adapter| adapter.close() catch |err| {
                self.witness.failure = err;
            };
            self.witness.closed = true;
            const source = self.source;
            source.destroy(self);
        }
    };
    const a = try d.Document.create(allocator, std.Thread.getCurrentId(), "one\ntwo", .{});
    defer a.close() catch unreachable;
    const b = try d.Document.create(allocator, std.Thread.getCurrentId(), "one\nthree", .{});
    defer b.close() catch unreachable;
    var witness: Witness = .{};
    const context = try allocator.create(Context);
    context.* = .{ .source = allocator, .witness = &witness, .inbox = try viewing.Inbox.create(allocator, .{ .a = a, .b = b }, .{}), .adapters = .{ try editing.Adapter.create(allocator, a, engine, .{}), try editing.Adapter.create(allocator, b, engine, .{}) } };
    context.window = try app.createWindow(.{ .on_closed = .{ .context = context, .notify = Context.closed } });
    const view = try viewing.EditableSplit.create(context.tracked(), context.inbox, context.adapters[0], context.adapters[1], context.window, .{});
    try refresh(context.inbox);
    try view.prepare(.{ .x = 0, .y = 0, .width = 400, .height = 150 }, .{});
    context.armed = true;
    try view.close();
    witness.released = true;
    try std.testing.expect(witness.fired and !witness.closed);
    try app.dispatch();
    if (witness.failure) |err| return err;
    try std.testing.expect(witness.closed);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
