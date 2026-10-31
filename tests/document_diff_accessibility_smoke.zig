const std = @import("std");
const z = @import("ziggurat");
const d = @import("ziggurat_document");
const e = @import("ziggurat_document_editor");
const ui = @import("ziggurat_ui");
const t = @import("ziggurat_text_layout");
const diff = @import("ziggurat_document_diff");
const v = @import("ziggurat_document_diff_view");
const a = @import("ziggurat_document_accessibility");
const paired = @import("ziggurat_document_diff_accessibility");
const c = @import("ziggurat_c_win32");
extern fn zda_probe_read_mta(*anyopaque, [*]u16, u32, *u32) i32;
extern fn zda_probe_match_rectangles(*anyopaque, [*]const u16, u32, *u32) i32;
extern fn zda_probe_release(*anyopaque) void;
extern fn zda_probe_point(*anyopaque, f64, f64, *u32) i32;
extern fn zdd_probe_action(*anyopaque, u32, [*]const u16, u32) i32;
extern fn zdd_probe_identity(*anyopaque, *anyopaque) i32;
extern fn zdd_probe_point(*anyopaque, [*]const u16, u32, *u32, *u32) i32;
extern fn zdd_probe_hit(*anyopaque, *anyopaque, [*]const u16, u32) i32;
extern fn zdd_probe_point_hit_mta(*anyopaque, *anyopaque, [*]const u16, u32, *u32, *u32) i32;
extern fn zdd_probe_auxiliary(*anyopaque, u32, *f64) i32;
extern fn zdd_probe_auxiliary_window(?*anyopaque) i32;
const bounds: ui.Rect = .{ .x = 4, .y = 4, .width = 420, .height = 150 };
const original = "header\nremoved 😀 original\ncommon\nlast";
const modified = "header\nreplacement 文\ncommon\nlast";
const AllocationProbe = struct {
    source: std.mem.Allocator,
    view: ?*v.EditableSplit = null,
    closing: ?*paired.Bridge = null,
    window: ?z.Window = null,
    document: ?*d.Document = null,
    attempted: bool = false,
    wrong_result: bool = false,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.window) |window| if (self.document) |document| {
            _ = document.version() catch |err| {
                if (err == error.Busy) {
                    self.window = null;
                    self.attempted = true;
                    _ = window.destroy() catch {
                        self.wrong_result = true;
                    };
                }
                return self.source.rawAlloc(len, alignment, ret);
            };
        };
        return self.source.rawAlloc(len, alignment, ret);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.closing) |bridge| if (@intFromPtr(bytes.ptr) == @intFromPtr(bridge)) {
            self.closing = null;
            self.attempted = true;
            self.view.?.close() catch |err| {
                if (err != error.ClientsAlive) self.wrong_result = true;
                self.source.rawFree(bytes, alignment, ret);
                return;
            };
            self.wrong_result = true;
        };
        self.source.rawFree(bytes, alignment, ret);
    }
};
const State = struct {
    window: z.Window = undefined,
    context: ui.Context = undefined,
    view: *v.EditableSplit = undefined,
    bridge: ?*paired.Bridge = null,
    inbox: *v.Inbox,
    adapters: [2]*e.Adapter,
    parameters: v.Parameters = .{ .font = .{ .size = 16, .wrap = .word_character, .width = 200 } },
    failure: ?anyerror = null,
    expected: ?anyerror = null,
    fail_frame: bool = false,
    changes: usize = 0,
    aux_enabled: bool = false,
    aux_record: bool = true,
    aux_disabled: bool = false,
    aux_mismatch: bool = false,
    aux_x: f32 = 8,
    aux_calls: usize = 0,
    aux_expanded: bool = false,
    aux_key: a.auxiliary.Key = undefined,
    fn action(_: *anyopaque, _: u64) void {}
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value.err) |err| {
            if (self.expected) |wanted| {
                if (err != wanted) self.failure = err;
            } else self.failure = err;
        }
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        frame.clear(0xffffff);
        if (self.bridge) |bridge| bridge.draw(frame, .{}) catch |err| {
            self.failure = err;
            frame.failure = err;
        };
        if (self.aux_enabled) self.drawAuxiliary(frame) catch |err| {
            if (self.expected) |expected| {
                if (expected != err) self.failure = err;
            } else self.failure = err;
            frame.failure = err;
        };
        if (self.fail_frame) frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0);
    }
    fn drawAuxiliary(self: *State, frame: *ui.Frame) !void {
        const toolbar: ui.Rect = .{ .x = 4, .y = 162, .width = 420, .height = 40 };
        frame.rect(toolbar, 0xf0f0f0);
        try frame.semantic(.{ .id = 700, .role = .group, .name = "Tools", .bounds = toolbar });
        try frame.buttonWithOptions(701, .{ .x = self.aux_x, .y = 166, .width = 70, .height = 30 }, if (self.aux_mismatch) "Mismatch" else "Action", .{ .semantic_parent = 700, .enabled = !self.aux_disabled });
        const disclosure: ui.Rect = .{ .x = 100, .y = 166, .width = 120, .height = 30 };
        frame.rect(disclosure, 0xdddddd);
        frame.label(disclosure, "Context", 0);
        try frame.semantic(.{ .id = 702, .parent = 700, .role = .group, .name = "Context", .bounds = disclosure });
        if (self.aux_record) try self.bridge.?.recordAuxiliary(frame);
    }
    fn auxiliaryValidate(_: *anyopaque, _: z.Window, _: u64, _: a.auxiliary.Key) !void {}
    fn auxiliaryCall(ptr: *anyopaque, _: z.Window, event: a.AuxiliaryAction) !void {
        const self: *State = @ptrCast(@alignCast(ptr));
        try std.testing.expectEqual(self.aux_key.comparison, event.key.comparison);
        switch (event.operation) {
            .invoke => self.aux_calls += 1,
            .expanded => |expanded| self.aux_expanded = expanded,
        }
    }
    fn auxiliaryOptions(self: *State) a.AuxiliaryOptions {
        return .{ .limits = .{ .nodes = 4, .label_bytes = 64 }, .handler = .{ .context = self, .validate = auxiliaryValidate, .call = auxiliaryCall } };
    }
    fn auxiliaryNodes(self: *State) ![3]a.auxiliary.Node {
        var rows: [96]v.editable.Row = undefined;
        const presentation = try self.view.copyPresentation(&rows);
        const serial = presentation.comparison_serial;
        self.aux_key = .{ .namespace = 0x0123456789abcdef, .comparison = serial, .item = 1, .kind = .invoke, .variant = 7 };
        return .{
            .{ .frame_id = 700, .key = .{ .namespace = self.aux_key.namespace, .comparison = serial, .item = 0, .kind = .group }, .name = "Tools" },
            .{ .frame_id = 701, .parent = 700, .key = self.aux_key, .name = "Action" },
            .{ .frame_id = 702, .parent = 700, .key = .{ .namespace = self.aux_key.namespace, .comparison = serial, .item = 1, .kind = .disclosure, .variant = 8 }, .name = "Context", .expanded = self.aux_expanded },
        };
    }
    fn changed(ptr: *anyopaque, _: z.Window) !void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.changes += 1;
    }
    fn paint(self: *State) !void {
        _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0);
        if (self.failure) |err| return err;
    }
    fn compare(self: *State) !void {
        try self.publish();
        try self.view.prepare(bounds, self.parameters);
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
        const sa = try self.inbox.pair.a.snapshot();
        defer sa.close() catch unreachable;
        const sb = try self.inbox.pair.b.snapshot();
        defer sb.close() catch unreachable;
        const ra = try sa.borrowReader();
        defer ra.release() catch unreachable;
        const rb = try sb.borrowReader();
        defer rb.release() catch unreachable;
        try self.bridge.?.prepare(.{ ra, rb });
        if (self.aux_enabled) {
            const nodes = try self.auxiliaryNodes();
            try self.bridge.?.prepareAuxiliary(.{ .nodes = &nodes });
        }
    }
};
fn auxiliaryAction(provider: *anyopaque, kind: u32, x: *f64) !i32 {
    const Worker = struct {
        provider: *anyopaque,
        kind: u32,
        x: f64 = 0,
        hr: i32 = 0,
        fn run(self: *@This()) void {
            self.hr = zdd_probe_auxiliary(self.provider, self.kind, &self.x);
        }
    };
    var work: Worker = .{ .provider = provider, .kind = kind };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&work});
    thread.join();
    x.* = work.x;
    return work.hr;
}
fn auxiliaryChecks(state: *State) !void {
    const button = try state.bridge.?.retainAuxiliaryProvider(state.aux_key);
    defer zda_probe_release(button);
    var disclosure_key = state.aux_key;
    disclosure_key.kind = .disclosure;
    disclosure_key.variant = 8;
    const disclosure = try state.bridge.?.retainAuxiliaryProvider(disclosure_key);
    defer zda_probe_release(disclosure);
    var x: f64 = 0;
    try std.testing.expectEqual(@as(i32, 0), try auxiliaryAction(button, 0, &x));
    const old_x = x;
    try std.testing.expectEqual(@as(i32, 0), try auxiliaryAction(button, 1, &x));
    try state.window.app.dispatch();
    try std.testing.expectEqual(@as(usize, 1), state.aux_calls);
    try std.testing.expectEqual(@as(i32, 0), try auxiliaryAction(disclosure, 2, &x));
    try state.window.app.dispatch();
    try std.testing.expect(state.aux_expanded);
    try state.prepare();
    state.aux_x += 10;
    state.aux_mismatch = true;
    state.expected = error.AuxiliaryPlanMismatch;
    const frames = state.context.frames;
    try state.paint();
    try std.testing.expectEqual(frames, state.context.frames);
    try std.testing.expectEqual(@as(i32, 0), try auxiliaryAction(button, 0, &x));
    try std.testing.expectEqual(old_x, x);
    state.aux_mismatch = false;
    state.expected = null;
    try state.paint();
    try std.testing.expectEqual(@as(i32, 0), try auxiliaryAction(button, 0, &x));
    try std.testing.expect(x > old_x);
    state.aux_disabled = true;
    try state.paint();
    try std.testing.expect((try auxiliaryAction(button, 1, &x)) < 0);
    state.aux_disabled = false;
    try state.paint();
    // Accepted actions from the previous front cannot acquire the next epoch.
    try std.testing.expectEqual(@as(i32, 0), try auxiliaryAction(button, 1, &x));
    try state.view.prepare(bounds, state.parameters);
    try state.prepare();
    try state.paint();
    try state.window.app.dispatch();
    try std.testing.expectEqual(@as(usize, 1), state.aux_calls);
    state.aux_record = false;
    try state.paint();
    try std.testing.expect((try auxiliaryAction(button, 0, &x)) < 0);
    state.aux_record = true;
    try state.paint();
    try std.testing.expectEqual(@as(i32, 0), try auxiliaryAction(disclosure, 3, &x));
    try state.window.app.dispatch();
    try std.testing.expect(!state.aux_expanded);
}
fn action(provider: *anyopaque, kind: u32, needle: []const u8) !i32 {
    const Worker = struct {
        provider: *anyopaque,
        kind: u32,
        units: [128]u16 = undefined,
        len: usize,
        hr: i32 = 0,
        fn run(self: *@This()) void {
            self.hr = zdd_probe_action(self.provider, self.kind, &self.units, @intCast(self.len));
        }
    };
    var work: Worker = .{ .provider = provider, .kind = kind, .len = 0 };
    work.len = try std.unicode.utf8ToUtf16Le(&work.units, needle);
    const worker = try std.Thread.spawn(.{}, Worker.run, .{&work});
    worker.join();
    return work.hr;
}
fn textEquals(provider: *anyopaque, expected: []const u8) !void {
    const Worker = struct {
        provider: *anyopaque,
        units: [2048]u16 = undefined,
        len: u32 = 0,
        hr: i32 = 0,
        fn run(self: *@This()) void {
            self.hr = zda_probe_read_mta(self.provider, &self.units, self.units.len, &self.len);
        }
    };
    var work: Worker = .{ .provider = provider };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{&work});
    worker.join();
    try std.testing.expectEqual(@as(i32, 0), work.hr);
    var units: [2048]u16 = undefined;
    const len = try std.unicode.utf8ToUtf16Le(&units, expected);
    try std.testing.expectEqualSlices(u16, units[0..len], work.units[0..work.len]);
}
fn matchCount(provider: *anyopaque, needle: []const u8) !u32 {
    var units: [128]u16 = undefined;
    const len = try std.unicode.utf8ToUtf16Le(&units, needle);
    var count: u32 = 0;
    try std.testing.expectEqual(@as(i32, 0), zda_probe_match_rectangles(provider, &units, @intCast(len), &count));
    return count;
}
fn pointHit(root: *anyopaque, source: *anyopaque, needle: []const u8) !void {
    const Worker = struct {
        root: *anyopaque,
        source: *anyopaque,
        query: [128]u16 = undefined,
        len: usize = 0,
        offset: u32 = 0,
        rectangles: u32 = 0,
        hr: i32 = 0,
        fn run(self: *@This()) void {
            self.hr = zdd_probe_point_hit_mta(self.root, self.source, &self.query, @intCast(self.len), &self.offset, &self.rectangles);
        }
    };
    var worker_state: Worker = .{ .root = root, .source = source };
    worker_state.len = try std.unicode.utf8ToUtf16Le(&worker_state.query, needle);
    const worker = try std.Thread.spawn(.{}, Worker.run, .{&worker_state});
    worker.join();
    try std.testing.expectEqual(@as(i32, 0), worker_state.hr);
    try std.testing.expect(worker_state.offset >= 7 and worker_state.offset < 14 and worker_state.rectangles > 0);
}
fn allocationCandidate(allocator: std.mem.Allocator, state: *State, target: paired.Target, readers: [2]?d.Reader) !void {
    defer state.window.app.dispatch() catch unreachable;
    const bridge = try paired.Bridge.create(allocator, state.window, target, .{ .accessibility = .{ .auxiliary = state.auxiliaryOptions() } });
    defer bridge.close() catch unreachable;
    try bridge.attachContext(&state.context);
    try bridge.prepare(readers);
    const nodes = try state.auxiliaryNodes();
    try bridge.prepareAuxiliary(.{ .nodes = &nodes });
    const stats = try bridge.stats();
    try std.testing.expect(stats.peak_reserved_bytes <= stats.byte_limit);
}
fn allocationSweep(allocator: std.mem.Allocator, state: *State, target: paired.Target) !void {
    const sa = try state.inbox.pair.a.snapshot();
    defer sa.close() catch unreachable;
    const sb = try state.inbox.pair.b.snapshot();
    defer sb.close() catch unreachable;
    const ra = try sa.borrowReader();
    defer ra.release() catch unreachable;
    const rb = try sb.borrowReader();
    defer rb.release() catch unreachable;
    try std.testing.checkAllAllocationFailures(allocator, allocationCandidate, .{ state, target, [2]?d.Reader{ ra, rb } });
}
fn emptySources(allocator: std.mem.Allocator, state: *State, target: paired.Target) !void {
    state.bridge = try paired.Bridge.create(allocator, state.window, target, .{});
    defer {
        state.bridge.?.close() catch unreachable;
        state.bridge = null;
        state.window.app.dispatch() catch unreachable;
    }
    try state.bridge.?.attachContext(&state.context);
    const provider = try state.bridge.?.retainProvider(1);
    defer zda_probe_release(provider);
    for ([_][2][]const u8{ .{ "", "" }, .{ "original\n", "" }, .{ "", "modified\n" } }) |texts| {
        for (state.adapters, texts) |adapter, text| {
            const doc = try adapter.sourceDocument();
            _ = try adapter.replaceMany(try doc.version(), &.{.{ .range = .{ .start = 0, .end = try doc.byteLength() }, .text = text }});
        }
        try state.compare();
        try state.prepare();
        try state.paint();
        try textEquals(provider, texts[1]);
        if (texts[1].len == 0) {
            var carets: [256]e.GeometryCaret = undefined;
            var lines: [128]e.GeometryLine = undefined;
            const doc = state.inbox.pair.b;
            const prepared = try state.adapters[1].preparedCarets(try doc.version(), &carets, &lines, .{});
            try std.testing.expect(prepared.carets.len > 0 and prepared.lines.len > 0);
            const caret = prepared.carets[0];
            var origin: c.POINT = .{ .x = 0, .y = 0 };
            try std.testing.expect(c.ClientToScreen(state.window.nativeHandle(), &origin) != 0);
            var offset: u32 = 99;
            try std.testing.expectEqual(@as(i32, 0), zda_probe_point(provider, @as(f64, @floatFromInt(origin.x)) + (caret.rect.x + 0.01) * state.parameters.scale, @as(f64, @floatFromInt(origin.y)) + (caret.rect.y + caret.rect.height * 0.5) * state.parameters.scale, &offset));
            try std.testing.expectEqual(@as(u32, 0), offset);
        }
    }
}
fn runMode(allocator: std.mem.Allocator, unified: bool, termination: u2) !void {
    var state: State = .{ .inbox = undefined, .adapters = undefined };
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    var document_probe: AllocationProbe = .{ .source = allocator };
    const docs = [2]*d.Document{ try d.Document.create(allocator, std.Thread.getCurrentId(), original, .{}), try d.Document.create(document_probe.allocator(), std.Thread.getCurrentId(), modified, .{}) };
    document_probe.document = docs[1];
    defer for (docs) |doc| doc.close() catch unreachable;
    state.adapters = .{ try e.Adapter.create(allocator, docs[0], engine, .{}), try e.Adapter.create(allocator, docs[1], engine, .{}) };
    defer for (state.adapters) |adapter| adapter.close() catch unreachable;
    state.inbox = try v.Inbox.create(allocator, .{ .a = docs[0], .b = docs[1] }, .{});
    defer state.inbox.close() catch unreachable;
    state.window = try app.createWindow(.{ .width = 430, .height = 220 });
    defer {
        _ = state.window.destroy() catch unreachable;
        app.dispatch() catch unreachable;
    }
    state.parameters.scale = @as(f32, @floatFromInt(c.GetDpiForWindow(state.window.nativeHandle()))) / 96;
    const target: paired.Target = if (unified) .{ .unified = try v.EditableUnified.create(allocator, state.inbox, state.adapters[0], state.adapters[1], state.window, .{}) } else .{ .split = try v.EditableSplit.create(allocator, state.inbox, state.adapters[0], state.adapters[1], state.window, .{}) };
    state.view = switch (target) {
        .split => |value| value,
        .unified => |value| value.coordinator(),
    };
    defer state.view.close() catch unreachable;
    try state.compare();
    if (unified) try std.testing.expectError(error.ReadOnlySource, state.view.revert(0, .b_to_a));
    state.context = ui.Context.init(&state, State.draw, State.action);
    state.context.render_mode = .gdi;
    try state.context.attach(state.window);
    try allocationSweep(allocator, &state, target);
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var close_probe: AllocationProbe = .{ .source = failing.allocator(), .view = state.view };
    state.aux_enabled = true;
    state.bridge = try paired.Bridge.create(close_probe.allocator(), state.window, target, .{ .changed = .{ .context = &state, .call = State.changed }, .accessibility = .{ .auxiliary = state.auxiliaryOptions() } });
    defer if (state.bridge) |bridge| bridge.close() catch unreachable;
    try std.testing.expectError(error.ClientsAlive, state.view.close());
    try state.bridge.?.attachContext(&state.context);
    try state.prepare();
    const providers = [2]*anyopaque{ try state.bridge.?.retainProvider(0), try state.bridge.?.retainProvider(1) };
    defer for (providers) |provider| zda_probe_release(provider);
    try textEquals(providers[0], original);
    try textEquals(providers[1], modified);
    try std.testing.expect(zdd_probe_identity(providers[0], providers[1]) < 0);
    try std.testing.expect((try action(providers[1], 1, "replacement")) < 0);
    try state.paint();
    try auxiliaryChecks(&state);
    if (termination == 1) {
        const retained = try state.bridge.?.retainAuxiliaryProvider(state.aux_key);
        defer zda_probe_release(retained);
        const calls = state.aux_calls;
        var x: f64 = 0;
        try std.testing.expectEqual(@as(i32, 0), try auxiliaryAction(retained, 1, &x));
        state.expected = error.Closed;
        app.quit();
        try app.finishShutdown();
        try std.testing.expectEqual(calls, state.aux_calls);
        try std.testing.expect((try auxiliaryAction(retained, 0, &x)) < 0);
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().stop_participants);
        try state.bridge.?.close();
        state.bridge = null;
        if (state.failure) |err| return err;
        return;
    }
    if (termination == 2) {
        const Client = struct {
            window: z.Window,
            hwnd: ?*anyopaque,
            hr: i32 = 0,
            fn finish(ptr: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                self.window.app.quit();
            }
            fn run(self: *@This()) void {
                self.hr = zdd_probe_auxiliary_window(self.hwnd);
                self.window.app.post(.{ .context = self, .call = finish }) catch @panic("UIA client could not post completion");
            }
        };
        var client: Client = .{ .window = state.window, .hwnd = state.window.nativeHandle() };
        const thread = try std.Thread.spawn(.{}, Client.run, .{&client});
        defer thread.join();
        try app.run();
        try std.testing.expectEqual(@as(i32, 0), client.hr);
        try state.bridge.?.close();
        state.bridge = null;
        if (state.failure) |err| return err;
        return;
    }
    try std.testing.expect(try matchCount(providers[0], "removed") > 0);
    if (unified) try std.testing.expectEqual(@as(u32, 0), try matchCount(providers[0], "header"));
    const root = try state.bridge.?.retainProvider(null);
    defer zda_probe_release(root);
    try pointHit(root, providers[0], "removed");
    if (unified) try std.testing.expect((try action(providers[0], 1, "removed")) < 0);
    try std.testing.expectEqual(@as(i32, 0), try action(providers[1], 1, "replacement"));
    try app.dispatch();
    if (state.failure) |err| return err;
    const selected = try docs[1].selection();
    try std.testing.expectEqual(@as(usize, 7), selected.range().start);
    try std.testing.expectEqual(@as(usize, 18), selected.range().end);
    try std.testing.expectEqual(@as(u64, 0), try docs[0].version());
    try state.prepare();
    try state.paint();
    state.expected = error.FocusDenied;
    try std.testing.expectEqual(@as(i32, 0), try action(providers[1], 0, ""));
    try app.dispatch();
    state.expected = null;
    try std.testing.expectEqual(v.Side.b, (try state.view.info()).focused.?);
    try state.prepare();
    try state.paint();
    const unchanged = try docs[1].selection();
    try state.window.perform(.disable);
    state.expected = error.Disabled;
    try std.testing.expectEqual(@as(i32, 0), try action(providers[1], 1, "header"));
    try app.dispatch();
    state.expected = null;
    try std.testing.expectEqual(unchanged, try docs[1].selection());
    try state.window.perform(.enable);
    try std.testing.expectEqual(@as(i32, 0), try action(providers[1], 1, "header"));
    try state.view.prepare(bounds, state.parameters);
    try state.prepare();
    try state.paint();
    try app.dispatch();
    try std.testing.expectEqual(unchanged, try docs[1].selection());
    // A comparison replacement can invalidate owner authorization even before
    // a new front changes the native epoch captured by queued work.
    try std.testing.expectEqual(@as(i32, 0), try action(providers[1], 1, "header"));
    try state.publish();
    state.expected = error.StalePresentation;
    try app.dispatch();
    state.expected = null;
    try std.testing.expectEqual(unchanged, try docs[1].selection());
    try state.view.prepare(bounds, state.parameters);
    try state.prepare();
    try state.paint();
    const visible = try matchCount(providers[0], "removed");
    state.fail_frame = true;
    state.expected = error.InvalidGeometry;
    const frames = state.context.frames;
    try state.view.prepare(bounds, state.parameters);
    try state.prepare();
    try state.paint();
    try std.testing.expectEqual(frames, state.context.frames);
    try std.testing.expectEqual(visible, try matchCount(providers[0], "removed"));
    state.fail_frame = false;
    state.expected = null;
    try state.paint();
    for (0..4) |failure| {
        failing.fail_index = failing.alloc_index + failure;
        try std.testing.expectError(error.OutOfMemory, state.bridge.?.prepare(.{ null, null }));
        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expectEqual(visible, try matchCount(providers[0], "removed"));
    }
    try state.prepare();
    try state.paint();
    try docs[0].setComposition("preedit", .{ .anchor = 0, .caret = 0 });
    try state.view.prepare(bounds, state.parameters);
    try state.prepare();
    try state.paint();
    try std.testing.expectEqual(@as(u32, 0), try matchCount(providers[0], "removed"));
    try textEquals(providers[0], original);
    try textEquals(providers[1], modified);
    state.expected = error.CompositionActive;
    try std.testing.expectEqual(@as(i32, 0), try action(providers[1], 1, "header"));
    try app.dispatch();
    state.expected = null;
    try std.testing.expectEqual(unchanged, try docs[1].selection());
    _ = try docs[0].cancelComposition();
    try state.compare();
    try state.prepare();
    try state.paint();
    try std.testing.expectEqual(@as(i32, 0), try action(providers[1], 2, "last"));
    try app.dispatch();
    try state.prepare();
    try state.paint();
    try std.testing.expectEqual(@as(i32, 0), try action(providers[1], 1, "header"));
    close_probe.closing = state.bridge;
    const late_auxiliary = try state.bridge.?.retainAuxiliaryProvider(state.aux_key);
    defer zda_probe_release(late_auxiliary);
    var auxiliary_x: f64 = 0;
    const auxiliary_calls = state.aux_calls;
    try std.testing.expectEqual(@as(i32, 0), try auxiliaryAction(late_auxiliary, 1, &auxiliary_x));
    try state.bridge.?.close();
    state.aux_enabled = false;
    state.bridge = null;
    try std.testing.expect(close_probe.attempted and !close_probe.wrong_result);
    try app.dispatch();
    try std.testing.expectEqual(auxiliary_calls, state.aux_calls);
    try std.testing.expect((try auxiliaryAction(late_auxiliary, 0, &auxiliary_x)) < 0);
    try std.testing.expectEqual(unchanged, try docs[1].selection());
    // A second independent bridge exercises final Document-candidate validation.
    // The allocator fires only while the sole target Document reports Busy.
    try emptySources(allocator, &state, target);
    for (state.adapters, [_][]const u8{ original, modified }) |adapter, text| {
        const doc = try adapter.sourceDocument();
        _ = try adapter.replaceMany(try doc.version(), &.{.{ .range = .{ .start = 0, .end = try doc.byteLength() }, .text = text }});
    }
    try state.compare();
    const guarded_selection = try docs[1].selection();
    state.bridge = try paired.Bridge.create(close_probe.allocator(), state.window, target, .{});
    try state.bridge.?.attachContext(&state.context);
    try state.prepare();
    try state.paint();
    const guarded_provider = try state.bridge.?.retainProvider(1);
    defer zda_probe_release(guarded_provider);
    document_probe.window = state.window;
    state.expected = error.Closed;
    const revision = try docs[1].version();
    try std.testing.expectEqual(@as(i32, 0), try action(guarded_provider, 4, "last"));
    try app.dispatch();
    state.expected = null;
    try std.testing.expect(document_probe.attempted and !document_probe.wrong_result and state.window.isClosed());
    try std.testing.expectEqual(revision, try docs[1].version());
    try std.testing.expectEqual(guarded_selection, try docs[1].selection());
    close_probe.closing = state.bridge;
    try state.bridge.?.close();
    state.bridge = null;
    try app.dispatch();
    if (state.failure) |err| return err;
}
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const before = a.resourceCounts();
    try runMode(gpa.allocator(), false, 0);
    try runMode(gpa.allocator(), true, 0);
    try runMode(gpa.allocator(), false, 1);
    try runMode(gpa.allocator(), true, 2);
    try @import("document_diff_controls_smoke.zig").run(gpa.allocator());
    try std.testing.expectEqual(before, a.resourceCounts());
    std.debug.print("paired document UIA: A/B full text, ghost offsets, coordinator actions, single-root auxiliary Invoke/ExpandCollapse, epoch, failed/missing front, OOM, quit/late close resources=0\n", .{});
}
