const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const text = @import("ziggurat_text_layout");
const d = @import("ziggurat_document");
const editing = @import("ziggurat_document_editor");
const diff = @import("ziggurat_document_diff");
const viewing = @import("ziggurat_document_diff_view");
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;
extern fn zlg_resource_count() u32;
const rectangle: ui.Rect = .{ .x = 4, .y = 4, .width = 440, .height = 240 };
const body = "😀word\r\nsame\nword end";
const Finder = viewing.Find;
const Work = viewing.find.Work;

const Fixture = struct {
    view: *viewing.EditableSplit,
    inbox: *viewing.Inbox,
    documents: [2]*d.Document,
    window: z.Window,
    parameters: viewing.Parameters,
    fn refresh(self: *@This()) !void {
        const job = try self.inbox.begin();
        defer _ = self.inbox.finish(job.ticket) catch unreachable;
        var lines = diff.compare(std.heap.page_allocator, job.a, job.b, .{}) catch |err| {
            try job.release();
            return err;
        };
        defer lines.deinit();
        try job.release();
        try self.inbox.publish(job.ticket, &lines);
        try self.view.prepare(rectangle, self.parameters);
    }
    fn prepare(self: *@This()) !void {
        try self.view.prepare(rectangle, self.parameters);
    }
};

const AllocatorProbe = struct {
    child: std.mem.Allocator,
    fixture: ?*Fixture = null,
    find: ?*Finder = null,
    action: enum { none, aba, peer_edit, post_edit, close_window, quit } = .none,
    busy_probe: bool = false,
    close_probe: bool = false,
    fired: bool = false,
    revision: u64 = 0,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn observe(self: *@This(), freeing: bool) void {
        const find = self.find orelse return;
        const fixture = self.fixture.?;
        if (self.busy_probe) {
            std.testing.expectError(error.Busy, find.stop()) catch unreachable;
            std.testing.expectError(error.Busy, find.stats()) catch unreachable;
            std.testing.expectError(error.Busy, find.close()) catch unreachable;
        }
        if (self.close_probe) std.testing.expectError(error.ClientsAlive, fixture.view.close()) catch unreachable;
        if (self.action == .none or (self.action == .post_edit) != freeing) return;
        if (self.action == .post_edit and (fixture.documents[1].version() catch self.revision) == self.revision) return;
        const action = self.action;
        self.action = .none;
        self.fired = true;
        switch (action) {
            .aba => {
                fixture.view.focus(.a) catch unreachable;
                fixture.view.focus(.b) catch unreachable;
            },
            .peer_edit => fixture.documents[0].replace(.{ .start = 0, .end = 0 }, "peer:") catch unreachable,
            .post_edit => fixture.documents[1].replace(.{ .start = 0, .end = 0 }, "external:") catch unreachable,
            .close_window => _ = fixture.window.destroy() catch unreachable,
            .quit => fixture.window.app.quit(),
            .none => unreachable,
        }
    }
    fn alloc(ptr: *anyopaque, size: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.observe(false);
        return self.child.rawAlloc(size, alignment, ret);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.observe(true);
        self.child.rawFree(bytes, alignment, ret);
    }
};

fn complete(work: Work) !void {
    try work.prepare();
    while (try work.step(3) != .complete) {}
    try work.release();
}
fn retire(find: *Finder, work: Work) void {
    work.release() catch |err| {
        if (err != error.WorkClosed) @panic(@errorName(err));
    };
    _ = find.finish(work.ticket) catch unreachable;
}
fn noop(_: *anyopaque) void {}

fn beginFailures(find: *Finder, document: *d.Document, failure: *std.testing.FailingAllocator, probe: *AllocatorProbe) !usize {
    var scratch: [8]d.Selection = undefined;
    var offset: usize = 0;
    while (true) : (offset += 1) {
        if (offset == 64) return error.AllocationFailureSweepLimit;
        const held = try find.begin("word", .{});
        defer retire(find, held);
        try complete(held);
        const revision = try document.version();
        const bytes = (try document.stats()).owned_bytes;
        const owned = (try find.stats()).owned_bytes;
        failure.fail_index = failure.alloc_index + offset;
        probe.busy_probe = true;
        const attempted = find.begin("absent", .{});
        failure.fail_index = std.math.maxInt(usize);
        probe.busy_probe = false;
        if (attempted) |candidate| {
            defer retire(find, candidate);
            try complete(candidate);
            try std.testing.expectError(error.Cancelled, find.apply(held.ticket, &scratch));
            try std.testing.expect(try find.finish(candidate.ticket));
            try std.testing.expect(try find.finish(held.ticket));
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(revision, try document.version());
            try std.testing.expectEqual(bytes, (try document.stats()).owned_bytes);
            try std.testing.expectEqual(owned, (try find.stats()).owned_bytes);
            // Failed candidate construction did not cancel or consume held.
            _ = try find.apply(held.ticket, &scratch);
            try std.testing.expect(try find.finish(held.ticket));
        }
    }
    try std.testing.expect(offset != 0);
    return offset;
}

fn posted(app: *z.App, find: *Finder) !void {
    const Delivery = struct {
        app: *z.App,
        find: *Finder,
        work: Work,
        failure: ?anyerror = null,
        post_failure: ?anyerror = null,
        deliveries: usize = 0,
        fn worker(self: *@This()) void {
            complete(self.work) catch |err| {
                self.failure = err;
                self.work.release() catch {};
                return;
            };
            self.app.post(.{ .context = self, .call = receive }) catch |err| {
                self.post_failure = err;
            };
        }
        fn receive(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.deliveries += 1;
            var scratch: [4]d.Selection = undefined;
            _ = self.find.apply(self.work.ticket, &scratch) catch |err| {
                self.failure = err;
            };
            _ = self.find.finish(self.work.ticket) catch |err| {
                self.failure = err;
            };
        }
    };
    var marker: u8 = 0;
    var count: usize = 0;
    while (true) : (count += 1) {
        app.post(.{ .context = &marker, .call = noop }) catch |err| {
            try std.testing.expectEqual(error.Full, err);
            break;
        };
        if (count > 1024) return error.QueueLimitExceeded;
    }
    var delivery: Delivery = .{ .app = app, .find = find, .work = try find.begin("word", .{}) };
    defer retire(find, delivery.work);
    // Explicit test orchestration joins the host-created worker before owner
    // dispatch. Find itself starts no worker and performs no blocking wait.
    const thread = try std.Thread.spawn(.{}, Delivery.worker, .{&delivery});
    thread.join();
    if (delivery.failure) |err| return err;
    try std.testing.expectEqual(error.Full, delivery.post_failure.?);
    try std.testing.expectEqual(@as(usize, 1), (try find.stats()).outstanding);
    try std.testing.expectError(error.JobsAlive, find.close());
    try app.dispatch();
    try app.post(.{ .context = &delivery, .call = Delivery.receive });
    try std.testing.expectError(error.JobsAlive, find.close());
    try app.dispatch();
    if (delivery.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 1), delivery.deliveries);
    try std.testing.expectEqual(@as(usize, 0), (try find.stats()).outstanding);
    try app.dispatch();
    try std.testing.expectEqual(@as(usize, 1), delivery.deliveries);
}

fn run(allocator: std.mem.Allocator, mode: viewing.editable.Mode) !usize {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 450, .height = 250 });
    defer {
        if (app.phase == .stopping) app.finishShutdown() catch unreachable else {
            _ = window.destroy() catch unreachable;
            app.dispatch() catch unreachable;
        }
    }
    var document_failure = std.testing.FailingAllocator.init(allocator, .{});
    const documents = [_]*d.Document{ try d.Document.create(document_failure.allocator(), app.owner, "original\n" ++ body, .{}), try d.Document.create(document_failure.allocator(), app.owner, body, .{}) };
    defer for (documents) |document| document.close() catch unreachable;
    const engine = try text.Engine.create(allocator, app.owner, .{});
    defer engine.close() catch unreachable;
    var adapter_probe: AllocatorProbe = .{ .child = allocator };
    const adapters = [_]*editing.Adapter{ try editing.Adapter.create(adapter_probe.allocator(), documents[0], engine, .{ .metadata_history = 0 }), try editing.Adapter.create(adapter_probe.allocator(), documents[1], engine, .{ .metadata_history = 0 }) };
    defer for (adapters) |adapter| adapter.close() catch unreachable;
    const inbox = try viewing.Inbox.create(allocator, .{ .a = documents[0], .b = documents[1] }, .{});
    defer inbox.close() catch unreachable;
    const unified = if (mode == .unified) try viewing.EditableUnified.create(allocator, inbox, adapters[0], adapters[1], window, .{}) else null;
    const view = if (unified) |value| value.coordinator() else try viewing.EditableSplit.create(allocator, inbox, adapters[0], adapters[1], window, .{});
    defer view.close() catch unreachable;
    var fixture: Fixture = .{ .view = view, .inbox = inbox, .documents = documents, .window = window, .parameters = .{ .font = .{ .size = 16, .wrap = .word_character, .width = 200 }, .scale = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(window.nativeHandle().?)) } };
    try fixture.refresh();
    try view.focus(.b);
    var find_failure = std.testing.FailingAllocator.init(allocator, .{});
    var find_probe: AllocatorProbe = .{ .child = find_failure.allocator(), .fixture = &fixture };
    const find = try Finder.create(find_probe.allocator(), view, .{});
    defer find.close() catch unreachable;
    adapter_probe.fixture = &fixture;
    adapter_probe.find = find;
    find_probe.find = find;
    var scratch: [8]d.Selection = undefined;

    if (mode == .split) {
        // Both columns are valid prepared layouts. Only the second caret lies
        // beyond the native caret API's narrower coordinate range.
        try view.focus(.a);
        var distant = rectangle;
        distant.x = 999900;
        try view.prepare(distant, fixture.parameters);
        const old_source = try view.captureSource();
        const old_a = try find.begin("word", .{});
        defer retire(find, old_a);
        try complete(old_a);
        const old_revisions = [2]u64{ try documents[0].version(), try documents[1].version() };
        try std.testing.expectError(error.InvalidGeometry, view.focus(.b));
        try std.testing.expect(!try adapters[0].isBound());
        try std.testing.expect(try adapters[1].isBound());
        try std.testing.expect(window.textClientToken() != null and !window.isClosed());
        try std.testing.expectEqual(old_revisions, [2]u64{ try documents[0].version(), try documents[1].version() });
        // Acquiring B revokes A even if the later caret presentation fails.
        try std.testing.expectError(error.StaleActiveSide, find.apply(old_a.ticket, &scratch));
        const acquired = try view.captureSource();
        try std.testing.expectEqual(viewing.editable.Side.b, acquired.stamp.side);
        try std.testing.expect(acquired.stamp.acquisition_generation > old_source.stamp.acquisition_generation);
        try std.testing.expect(try find.finish(old_a.ticket));
        try fixture.prepare();
        try view.focus(.b);
    }

    // Real worker, queue Full/no-transfer, accepted delivery exactly once.
    try posted(app, find);
    try std.testing.expectEqual(d.Selection{ .anchor = 4, .caret = 8 }, try documents[1].selection());
    const cursor = try view.cursor();
    try std.testing.expectEqual(@as(usize, 6), cursor.utf16_column);
    const version = try documents[1].committedTextVersion();
    const second = try find.begin("word", .{});
    defer retire(find, second);
    try complete(second);
    const outcome = (try find.apply(second.ticket, &scratch)).?;
    try std.testing.expect(outcome.selection_changed and !outcome.text_changed and outcome.committed_revision != null and !outcome.stale_after_commit);
    try std.testing.expectEqual(version, try documents[1].committedTextVersion());
    try std.testing.expectEqual(d.Selection{ .anchor = 15, .caret = 19 }, try documents[1].selection());
    try std.testing.expectError(error.AlreadyApplied, find.apply(second.ticket, &scratch));
    try std.testing.expect(try find.finish(second.ticket));
    const no_text_undo = try view.run(.undo, &scratch);
    try std.testing.expect(!no_text_undo.text_changed and !no_text_undo.changed);
    const absent = try find.begin("absent", .{ .wrap = false });
    defer retire(find, absent);
    try complete(absent);
    const before_absent = try documents[1].version();
    try std.testing.expect((try find.apply(absent.ticket, &scratch)) == null);
    try std.testing.expectEqual(before_absent, try documents[1].version());
    try std.testing.expect(try find.finish(absent.ticket));

    // Source authorization observes revisions, not text/selection equality.
    const selected = try documents[1].selection();
    const stale_selection = try find.begin("word", .{});
    defer retire(find, stale_selection);
    try complete(stale_selection);
    _ = try documents[1].setSelection(.{ .anchor = 0, .caret = 0 });
    _ = try documents[1].setSelection(selected);
    try std.testing.expectError(error.StaleRevision, find.apply(stale_selection.ticket, &scratch));
    try std.testing.expect(try find.finish(stale_selection.ticket));
    const stale_ime = try find.begin("word", .{});
    defer retire(find, stale_ime);
    try complete(stale_ime);
    try documents[1].setComposition("候", .{ .anchor = 0, .caret = 0 });
    try std.testing.expectError(error.CompositionActive, find.apply(stale_ime.ticket, &scratch));
    _ = try documents[1].cancelComposition();
    try std.testing.expectError(error.StaleRevision, find.apply(stale_ime.ticket, &scratch));
    try std.testing.expect(try find.finish(stale_ime.ticket));
    try fixture.prepare();
    if (mode == .split) {
        const aba = try find.begin("word", .{});
        defer retire(find, aba);
        try complete(aba);
        try view.focus(.a);
        try view.focus(.b);
        try std.testing.expectError(error.StaleActiveSide, find.apply(aba.ticket, &scratch));
        try std.testing.expect(try find.finish(aba.ticket));
        find_probe.action = .aba;
        find_probe.busy_probe = true;
        try std.testing.expectError(error.StaleActiveSide, find.begin("word", .{}));
        find_probe.busy_probe = false;
        try std.testing.expect(find_probe.fired);
    } else try std.testing.expectError(error.ReadOnlySource, view.focus(.a));

    // Blur retains the last source; a disabled owner rejects before editing.
    var rows: [96]viewing.editable.Row = undefined;
    const presentation = try view.copyPresentation(&rows);
    try view.blurPresented(presentation.epoch);
    const blurred = try find.begin("word", .{});
    defer retire(find, blurred);
    try complete(blurred);
    try window.perform(.disable);
    try std.testing.expectError(error.Disabled, find.apply(blurred.ticket, &scratch));
    try window.perform(.enable);
    _ = try find.apply(blurred.ticket, &scratch);
    try std.testing.expect(window.textClientToken() == null);
    try std.testing.expect(try find.finish(blurred.ticket));

    // Foreign preparation cannot reacquire source ownership; an independent
    // peer edit still reaches the final command gate and cannot commit selection.
    _ = try documents[1].setSelection(.{ .anchor = 0, .caret = 0 });
    const late_peer = try find.begin("word", .{});
    defer retire(find, late_peer);
    try complete(late_peer);
    const before_peer = try documents[1].version();
    adapter_probe.action = .peer_edit;
    adapter_probe.busy_probe = true;
    adapter_probe.fired = false;
    try std.testing.expectError(error.StaleRevision, find.apply(late_peer.ticket, &scratch));
    adapter_probe.busy_probe = false;
    try std.testing.expect(adapter_probe.fired);
    try std.testing.expectEqual(before_peer, try documents[1].version());
    try std.testing.expect(try find.finish(late_peer.ticket));
    try fixture.refresh();

    // A changed Document after a selection commit is an outcome, never a
    // retryable error; the physical result is consumed once in either case.
    const post = try find.begin("word", .{});
    defer retire(find, post);
    try complete(post);
    adapter_probe.action = .post_edit;
    adapter_probe.revision = try documents[1].version();
    adapter_probe.fired = false;
    const changed = (try find.apply(post.ticket, &scratch)).?;
    adapter_probe.action = .none;
    try std.testing.expect(adapter_probe.fired and changed.committed_revision != null and changed.stale_after_commit);
    try std.testing.expect(changed.observed_revision > changed.committed_revision.?);
    try std.testing.expectError(error.AlreadyApplied, find.apply(post.ticket, &scratch));
    try std.testing.expect(try find.finish(post.ticket));
    try adapters[1].reindex();
    try fixture.refresh();
    const allocation_failures = try beginFailures(find, documents[1], &find_failure, &find_probe) + try beginFailures(find, documents[1], &document_failure, &find_probe);

    // Search owns no visible-row index: a match inside collapsed unchanged
    // source records is revealed by the existing selection command path.
    const shared = &@as([30 * "same\n".len]u8, @bitCast(@as([30]["same\n".len]u8, @splat("same\n".*)))) ++ "needle\n" ++ &@as([30 * "same\n".len]u8, @bitCast(@as([30]["same\n".len]u8, @splat("same\n".*))));
    const replacement = [_][]const u8{ "left\n" ++ shared ++ "old", "right\n" ++ shared ++ "new" };
    for (documents, adapters, replacement) |document, adapter, bytes| {
        try document.replace(.{ .start = 0, .end = try document.byteLength() }, bytes);
        _ = try document.setSelection(.{ .anchor = 0, .caret = 0 });
        try adapter.reindex();
    }
    try fixture.refresh();
    try view.setContext(.{ .context_lines = 1, .minimum_hidden = 2 });
    try fixture.prepare();
    var regions: [16]viewing.editable.ContextRegion = undefined;
    const collapsed = try view.contextRegions(&regions);
    try std.testing.expect(collapsed.len != 0 and collapsed[0].collapsed);
    const before_visible = (try adapters[1].stats()).visible_paragraphs;
    const folded = try find.begin("needle", .{});
    defer retire(find, folded);
    try complete(folded);
    const revealed = (try find.apply(folded.ticket, &scratch)).?;
    try std.testing.expect(revealed.selection_changed and !revealed.text_changed and revealed.presentation_error == null);
    const original_line = try documents[1].lineAt((try documents[1].selection()).range().start);
    try std.testing.expectEqual(@as(usize, 31), original_line);
    try std.testing.expect((try adapters[1].stats()).visible_paragraphs > before_visible);
    // Context headers outside the new viewport are deliberately not exported.
    // Check the newly visible actual source row and prepared caret instead.
    const visible = try view.rowInfo(&rows);
    var found_row = false;
    for (visible) |row| if (row.b == original_line) {
        found_row = true;
    };
    try std.testing.expect(found_row);
    const after_reveal = try view.copyPresentation(&rows);
    _ = try adapters[1].caretRect(after_reveal.columns[1], fixture.parameters.scale);
    try std.testing.expect(try find.finish(folded.ticket));

    const sealed = try Finder.create(allocator, view, .{});
    const abandoned = try sealed.begin("needle", .{});
    try sealed.stop();
    try sealed.stop();
    try documents[1].setComposition("候", .{ .anchor = 0, .caret = 0 });
    try std.testing.expectError(error.Closed, sealed.begin("needle", .{}));
    try std.testing.expectError(error.Closed, sealed.apply(abandoned.ticket, &scratch));
    _ = try documents[1].cancelComposition();
    try std.testing.expectError(error.Cancelled, abandoned.prepare());
    try abandoned.release();
    try std.testing.expect(try sealed.finish(abandoned.ticket));
    try sealed.close();

    const stopped = try find.begin("word", .{});
    defer retire(find, stopped);
    try complete(stopped);
    const ClosingDelivery = struct {
        find: *Finder,
        work: Work,
        calls: usize = 0,
        fn receive(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            var selected_scratch: [4]d.Selection = undefined;
            std.testing.expectError(error.Closed, self.find.apply(self.work.ticket, &selected_scratch)) catch unreachable;
            std.testing.expect(self.find.finish(self.work.ticket) catch unreachable) catch unreachable;
        }
    };
    var queued: ClosingDelivery = .{ .find = find, .work = try find.begin("needle", .{}) };
    defer retire(find, queued.work);
    try complete(queued.work);
    try app.post(.{ .context = &queued, .call = ClosingDelivery.receive });
    // Even an assertion failure below must retire the accepted task before its
    // stack context, ticket or Find can be reclaimed by later cleanup defers.
    defer {
        if (app.phase == .stopping) app.finishShutdown() catch unreachable else app.dispatch() catch unreachable;
    }
    app.quit();
    try std.testing.expectError(error.Closed, app.post(.{ .context = find, .call = noop }));
    try std.testing.expectError(error.Closed, find.apply(stopped.ticket, &scratch));
    try std.testing.expectError(error.JobsAlive, find.close());
    try find.stop();
    try std.testing.expect(try find.finish(stopped.ticket));
    try std.testing.expectEqual(@as(usize, 1), (try find.stats()).outstanding);
    // Teardown scope remains usable after stop. All foreign frees still hold
    // the Find busy gate and coordinator client, including the final shell.
    find_probe.busy_probe = true;
    find_probe.close_probe = true;
    // The deferred close runs after native shutdown but before view.close.
    try app.finishShutdown();
    try std.testing.expectEqual(@as(usize, 1), queued.calls);
    try std.testing.expectEqual(@as(usize, 0), (try find.stats()).outstanding);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    return allocation_failures;
}

fn createClosing(allocator: std.mem.Allocator, quit: bool, fail: bool, offset: usize) !void {
    const Host = struct {
        allocator: std.mem.Allocator,
        live: *bool,
        fixture: Fixture,
        engine: *text.Engine,
        adapters: [2]*editing.Adapter,
        fn closed(ptr: *anyopaque, _: z.Window) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.fixture.view.close() catch unreachable;
            self.fixture.inbox.close() catch unreachable;
            for (self.adapters) |adapter| adapter.close() catch unreachable;
            self.engine.close() catch unreachable;
            for (self.fixture.documents) |document| document.close() catch unreachable;
            self.live.* = false;
            const child = self.allocator;
            child.destroy(self);
        }
    };
    const Probe = struct {
        allocator: std.mem.Allocator,
        window: z.Window,
        live: *bool,
        quit: bool,
        fail: bool,
        remaining: usize,
        fired: bool = false,
        fn facade(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
        }
        fn alloc(ptr: *anyopaque, size: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (!self.fired) {
                if (self.remaining != 0) self.remaining -= 1 else {
                    self.fired = true;
                    if (self.quit) self.window.app.quit() else _ = self.window.destroy() catch unreachable;
                    std.testing.expect(self.live.*) catch unreachable;
                    if (self.fail) return null;
                }
            }
            return self.allocator.rawAlloc(size, alignment, ret);
        }
        fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            // Every candidate free must precede the callback that frees Host.
            std.testing.expect(self.live.*) catch unreachable;
            self.allocator.rawFree(bytes, alignment, ret);
        }
    };
    const app = try z.App.init(allocator);
    defer app.deinit();
    var live = true;
    const host = try allocator.create(Host);
    const documents = [_]*d.Document{ try d.Document.create(allocator, app.owner, "a", .{}), try d.Document.create(allocator, app.owner, "b", .{}) };
    const engine = try text.Engine.create(allocator, app.owner, .{});
    const adapters = [_]*editing.Adapter{ try editing.Adapter.create(allocator, documents[0], engine, .{}), try editing.Adapter.create(allocator, documents[1], engine, .{}) };
    const inbox = try viewing.Inbox.create(allocator, .{ .a = documents[0], .b = documents[1] }, .{});
    const window = try app.createWindow(.{ .width = 450, .height = 250, .on_closed = .{ .context = host, .notify = Host.closed } });
    const view = try viewing.EditableSplit.create(allocator, inbox, adapters[0], adapters[1], window, .{});
    host.* = .{ .allocator = allocator, .live = &live, .fixture = .{ .view = view, .inbox = inbox, .documents = documents, .window = window, .parameters = .{} }, .engine = engine, .adapters = adapters };
    var probe: Probe = .{ .allocator = allocator, .window = window, .live = &live, .quit = quit, .fail = fail, .remaining = offset };
    const result = Finder.create(probe.facade(), view, .{});
    try std.testing.expect(probe.fired);
    try std.testing.expectError(if (fail) error.OutOfMemory else error.Closed, result);
    if (quit) try app.finishShutdown() else try app.dispatch();
    try std.testing.expect(!live);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const counts = text.resourceCounts();
    for (0..3) |offset| for ([_]bool{ false, true }) |quit| for ([_]bool{ false, true }) |fail| try createClosing(debug.allocator(), quit, fail, offset);
    var allocation_failures = try run(debug.allocator(), .split);
    const gdi = if (builtin.os.tag == .windows) c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS) else 0;
    const user = if (builtin.os.tag == .windows) c.GetGuiResources(c.GetCurrentProcess(), c.GR_USEROBJECTS) else 0;
    allocation_failures += try run(debug.allocator(), .unified);
    try std.testing.expectEqualDeep(counts, text.resourceCounts());
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqual(gdi, c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS));
        try std.testing.expectEqual(user, c.GetGuiResources(c.GetCurrentProcess(), c.GR_USEROBJECTS));
    } else try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("Diff Find: split/unified UTF8/UTF16/CRLF source, real worker/post Full/Closed, ABA/IME/stale/blur/folds, final guard and committed outcome, begin_allocation_failures={d}, native/text resources=0\n", .{allocation_failures});
}
