const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const d = @import("ziggurat_document");
const e = @import("ziggurat_document_editor");
const t = @import("ziggurat_text_layout");
const a = @import("ziggurat_document_accessibility");
const ui = @import("ziggurat_ui");
extern fn atk_text_get_text(*anyopaque, c_int, c_int) ?[*:0]u8;
extern fn atk_text_get_character_count(*anyopaque) c_int;
extern fn atk_text_get_character_at_offset(*anyopaque, c_int) u32;
extern fn atk_text_get_string_at_offset(*anyopaque, c_int, c_int, *c_int, *c_int) ?[*:0]u8;
extern fn atk_text_get_n_selections(*anyopaque) c_int;
extern fn atk_text_set_caret_offset(*anyopaque, c_int) c_int;
extern fn atk_text_add_selection(*anyopaque, c_int, c_int) c_int;
extern fn atk_text_get_character_extents(*anyopaque, c_int, *c_int, *c_int, *c_int, *c_int, c_int) void;
extern fn atk_text_get_offset_at_point(*anyopaque, c_int, c_int, c_int) c_int;
extern fn atk_text_get_range_extents(*anyopaque, c_int, c_int, c_int, *[4]c_int) void;
extern fn atk_component_grab_focus(*anyopaque) c_int;
extern fn atk_object_get_n_accessible_children(*anyopaque) c_int;
extern fn atk_object_ref_accessible_child(*anyopaque, c_int) ?*anyopaque;
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_accessible(*anyopaque) *anyopaque;
extern fn gtk_widget_destroy(*anyopaque) void;
extern fn g_object_unref(*anyopaque) void;
extern fn g_free(?*anyopaque) void;
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn g_signal_connect_data(*anyopaque, [*:0]const u8, *const fn (*anyopaque, *anyopaque) callconv(.c) void, *anyopaque, ?*anyopaque, c_int) c_ulong;
extern fn g_unix_fd_add(c_int, c_uint, *const fn (c_int, c_uint, *anyopaque) callconv(.c) c_int, *anyopaque) c_uint;
extern fn g_source_remove(c_uint) c_int;
extern fn fcntl(c_int, c_int, ...) c_int;
extern fn read(c_int, [*]u8, usize) isize;

const original = "a😀e\u{301} אבג\r\nfull document\nlast hidden paragraph";
const bounds: ui.Rect = .{ .x = 8, .y = 8, .width = 280, .height = 100 };
const State = struct {
    context: ui.Context = undefined,
    window: z.Window,
    adapter: *e.Adapter,
    document: *d.Document,
    bridge: ?*a.Bridge = null,
    failure: ?anyerror = null,
    fail_frame: bool = false,
    paints: usize = 0,
    edit_on_geometry: bool = false,
    geometry_edits: usize = 0,
    replace_source: bool = false,
    viewport: ui.Rect = bounds,
    paragraph_filter: ?[]const usize = null,
    hide_document: bool = false,
    fn noQuery(_: *anyopaque, _: z.Window, _: usize, _: isize) ?isize {
        return null;
    }
    fn geometrySignal(_: *anyopaque, ptr: *anyopaque) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (self.replace_source) {
            self.replace_source = false;
            _ = self.context.installAccessibilitySource(.{ .context = self, .query = noQuery }) catch |err| {
                self.failure = err;
            };
            return;
        }
        if (!self.edit_on_geometry) return;
        self.edit_on_geometry = false;
        self.document.replace(.{ .start = 0, .end = self.document.byteLength() catch unreachable }, "foreign mutation 😀\n") catch |err| {
            self.failure = err;
            return;
        };
        self.geometry_edits += 1;
    }
    fn control(fd: c_int, condition: c_uint, ptr: *anyopaque) callconv(.c) c_int {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (condition & 1 != 0) {
            var input: [1]u8 = undefined;
            if (read(fd, &input, 1) == 1) self.command(input[0]) catch |err| {
                self.failure = err;
                self.window.app.quit();
            };
        } else if (condition & 16 != 0) self.window.app.quit();
        return 1;
    }
    fn command(self: *State, value: u8) !void {
        switch (value) {
            'r' => {
                try self.document.replace(.{ .start = 0, .end = try self.document.byteLength() }, "external replacement 😀\n");
                try self.refresh(self.document);
                try self.paint();
                std.debug.print("external server replaced\n", .{});
            },
            'c' => {
                try self.bridge.?.detach();
                std.debug.print("external server detached\n", .{});
            },
            'q' => self.window.app.quit(),
            else => return error.InvalidControl,
        }
    }
    fn action(_: *anyopaque, _: u64) void {}
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.drawChecked(frame) catch |err| {
            self.failure = err;
            frame.failure = frame.failure orelse err;
        };
    }
    fn drawChecked(self: *State, frame: *ui.Frame) !void {
        frame.clear(0xffffff);
        if (!self.hide_document) {
            if (self.paragraph_filter) |filter| try self.adapter.drawParagraphs(frame, self.viewport, filter, ui.Color.rgb(0)) else try self.adapter.draw(frame, self.viewport, .{});
        }
        if (self.bridge) |bridge| try bridge.recordGeometry(frame);
        self.paints += 1;
        if (self.fail_frame) frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0);
    }
    fn paint(self: *State) !void {
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const size = try self.window.contentSize();
        const scale: u32 = @intFromFloat(size.scale);
        zlg_test_paint(scope.record.native.native.?, size.width / scale, size.height / scale);
        if (self.failure) |err| return err;
    }
    fn refresh(self: *State, document: *d.Document) !void {
        try self.adapter.reindex();
        _ = try self.adapter.prepare(bounds, .{ .font = .{ .size = 18, .wrap = .word_character, .width = bounds.width }, .scale = (try self.window.contentSize()).scale });
        try self.prepareText(document);
        try self.bridge.?.prepareGeometry(&.{null});
    }
    fn prepareText(self: *State, document: *d.Document) !void {
        const snapshot = try document.snapshot();
        defer snapshot.close() catch unreachable;
        const reader = try snapshot.borrowReader();
        defer reader.release() catch unreachable;
        try self.bridge.?.prepareText(&.{reader});
    }
};

fn exactPoint(state: *State, provider: *anyopaque, source: []const u8, x: c_int, y: c_int) !void {
    const hit = try state.adapter.hitTest(state.viewport, .{ .x = @floatFromInt(x), .y = @floatFromInt(y) });
    const expected: c_int = @intCast(try std.unicode.utf8CountCodepoints(source[0..hit.byte_offset]));
    const actual = atk_text_get_offset_at_point(provider, x, y, 2);
    if (actual != expected) std.debug.print("complete hit mismatch ({d},{d}) expected={d} actual={d}\n", .{ x, y, expected, actual });
    try std.testing.expectEqual(expected, actual);
}

fn completeHitRoutes(allocator: std.mem.Allocator) !void {
    const source_text = "aaaaaaaaaaaaaaaa\nאבג e\u{301}😀\r\nthird\nlast";
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .accessibility_host = .children, .width = 320, .height = 180 });
    defer _ = window.destroy() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), source_text, .{});
    defer document.close() catch unreachable;
    var plan: ?*e.ProjectionPlan = null;
    defer if (plan) |item| item.close() catch unreachable;
    const adapter = try e.Adapter.create(allocator, document, engine, .{ .batch_rows = 1 });
    defer adapter.close() catch unreachable;
    var state: State = .{ .window = window, .adapter = adapter, .document = document, .viewport = .{ .x = 8.25, .y = 8.375, .width = 280.5, .height = 100.25 } };
    state.context = .{ .state = &state, .draw = State.draw, .on_action = State.action };
    try state.context.attach(window);
    const parameters: e.Parameters = .{ .font = .{ .size = 24, .wrap = .none, .width = state.viewport.width }, .scale = (try window.contentSize()).scale };
    _ = try adapter.prepare(state.viewport, parameters);
    _ = try adapter.scrollBy(.{ .x = 1.375, .y = 0 });
    const bridge = try a.Bridge.create(allocator, window, &.{.{ .adapter = adapter, .name = "Complete input routes", .read_only = true, .selectable = false, .focusable = false }}, .{});
    defer bridge.close() catch unreachable;
    state.bridge = bridge;
    try bridge.attachContext(&state.context);
    const provider = try bridge.retainProvider(0);
    defer g_object_unref(provider);
    var comparisons: usize = 0;
    for (0..2) |mode| {
        if (mode == 1) {
            plan = try e.ProjectionPlan.create(allocator, document, &.{ .{ .line = 1, .gap_before = 17.25, .minimum_height = 45 }, .{ .line = 2, .gap_before = 4.5 } }, .{});
            try adapter.setProjection(plan);
        }
        _ = try adapter.prepare(state.viewport, parameters);
        try state.prepareText(document);
        try bridge.prepareGeometry(&.{null});
        try state.paint();
        const owned = try bridge.stats();
        std.debug.print("complete hit mode={d} requested_bytes={d} peak_reserved_bytes={d} host_staging_bytes={d} Options={d} Bridge={d}\n", .{ mode, owned.requested_bytes, owned.peak_reserved_bytes, owned.host_staging_bytes, @sizeOf(a.Options), @sizeOf(a.Bridge) });
        for (0..17) |yi| for (0..14) |xi| {
            const x: c_int = 9 + @as(c_int, @intCast(xi)) * 20;
            const y: c_int = 9 + @as(c_int, @intCast(yi)) * 6;
            try exactPoint(&state, provider, source_text, x, y);
            comparisons += 1;
        };
    }
    const filter = [_]usize{1};
    state.paragraph_filter = &filter;
    try bridge.prepareGeometry(&.{filter[0..]});
    try state.paint();
    var carets: [512]e.GeometryCaret = undefined;
    var lines: [64]e.GeometryLine = undefined;
    const visible = try adapter.preparedCarets(try document.version(), &carets, &lines, .{ .paragraphs = &filter });
    try std.testing.expect(visible.lines.len != 0);
    const y: c_int = @intFromFloat(@floor(visible.lines[0].rect.y + visible.lines[0].rect.height / 2));
    try exactPoint(&state, provider, source_text, 9, y);
    try std.testing.expectEqual(@as(c_int, -1), atk_text_get_offset_at_point(provider, 9, 10, 2));
    const gap: c_int = @intFromFloat(@floor(visible.lines[0].rect.y - 5));
    try std.testing.expectEqual(@as(c_int, -1), atk_text_get_offset_at_point(provider, 9, gap, 2));
    const empty: []const usize = &.{};
    state.paragraph_filter = empty;
    try bridge.prepareGeometry(&.{empty});
    try state.paint();
    try std.testing.expectEqual(@as(c_int, -1), atk_text_get_offset_at_point(provider, 9, y, 2));
    state.hide_document = true;
    try bridge.prepareGeometrySelected(&.{.hidden}, 0);
    try state.paint();
    try std.testing.expectEqual(@as(c_int, -1), atk_text_get_offset_at_point(provider, 9, y, 2));
    std.debug.print("complete Prepared native hit: {d} ordinary/projected points; fractional bounds/scroll, actual filtered line/gap, empty and hidden denied\n", .{comparisons});
}
fn textEquals(provider: *anyopaque, wanted: []const u8) !void {
    const raw = atk_text_get_text(provider, 0, -1) orelse return error.TextUnavailable;
    defer g_free(raw);
    try std.testing.expectEqualStrings(wanted, std.mem.span(raw));
}
fn character(provider: *anyopaque, offset: c_int) [4]c_int {
    var result: [4]c_int = undefined;
    atk_text_get_character_extents(provider, offset, &result[0], &result[1], &result[2], &result[3], 2);
    return result;
}
fn geometryUnavailable(provider: *anyopaque, offset: c_int) !void {
    // ATK 2.52's public character wrapper normalizes every negative width,
    // including its own -1 sentinel, into x=-2,width=1. Height stays -1.
    try std.testing.expectEqual(@as(c_int, -1), character(provider, offset)[3]);
    var range: [4]c_int = undefined;
    atk_text_get_range_extents(provider, offset, offset + 1, 2, &range);
    try std.testing.expectEqualSlices(c_int, &.{ -1, -1, -1, -1 }, &range);
}
fn pointOracle(state: *State, provider: *anyopaque) !void {
    var carets: [512]e.GeometryCaret = undefined;
    var lines: [64]e.GeometryLine = undefined;
    const exported = try state.adapter.preparedCarets(try state.document.version(), &carets, &lines, .{});
    var checks: usize = 0;
    for (exported.lines) |line| {
        const y: c_int = @intFromFloat(@floor(line.rect.y + line.rect.height / 2));
        if (y < bounds.y or y >= bounds.y + bounds.height) continue;
        for (0..24) |at| {
            const x: c_int = @intFromFloat(bounds.x + @as(f32, @floatFromInt(at)) * (bounds.width - 1) / 23);
            const hit = try state.adapter.hitTest(bounds, .{ .x = @floatFromInt(x), .y = @floatFromInt(y) });
            const expected = try std.unicode.utf8CountCodepoints(original[0..hit.byte_offset]);
            const actual = atk_text_get_offset_at_point(provider, x, y, 2);
            if (actual != @as(c_int, @intCast(expected))) {
                std.debug.print("point mismatch x={d} y={d} expected={d} actual={d}\n", .{ x, y, expected, actual });
                return error.PointMismatch;
            }
            checks += 1;
        }
    }
    try std.testing.expect(checks >= 24);
    std.debug.print("actual Prepared/ATK point comparisons={d}\n", .{checks});
}

fn exercise(allocator: std.mem.Allocator, raw_close: bool, external: bool, source_revoke: bool) !*anyopaque {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .accessibility_host = .children, .width = 320, .height = 180 });
    defer _ = window.destroy() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), original, .{});
    defer document.close() catch unreachable;
    const adapter = try e.Adapter.create(allocator, document, engine, .{});
    defer adapter.close() catch unreachable;
    var state: State = .{ .window = window, .adapter = adapter, .document = document };
    state.context = .{ .state = &state, .draw = State.draw, .on_action = State.action };
    try state.context.attach(window);
    const source: a.Source = .{ .adapter = adapter, .name = "Ziggurat Linux document oracle", .read_only = true, .selectable = false, .focusable = false };
    var poison = source;
    poison.adapter = @ptrFromInt(4096);
    poison.read_only = false;
    try std.testing.expectError(error.UnsupportedCapability, a.Bridge.create(std.testing.failing_allocator, window, &.{poison}, .{}));
    for ([_]a.Options{ .{ .affine_geometry = true }, .{ .word_units = true }, .{ .presentation_epochs = true } }) |options| {
        try std.testing.expectError(error.UnsupportedCapability, a.Bridge.create(std.testing.failing_allocator, window, &.{source}, options));
    }
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, a.Bridge.create(failing.allocator(), window, &.{source}, .{}));
    failing.fail_index = std.math.maxInt(usize);
    const bridge = a.Bridge.create(failing.allocator(), window, &.{source}, .{}) catch |err| {
        std.debug.print("actual Linux Bridge.create: {s}\n", .{@errorName(err)});
        return err;
    };
    var bridge_live = true;
    defer if (bridge_live) bridge.close() catch unreachable;
    state.bridge = bridge;
    try bridge.attachContext(&state.context);
    const provider = try bridge.retainProvider(0);
    errdefer g_object_unref(provider);
    const area = gtk_bin_get_child(window.nativeHandle().?).?;
    const host = gtk_widget_get_accessible(area);
    try std.testing.expectEqual(@as(c_int, 1), atk_object_get_n_accessible_children(host));
    const discovered = atk_object_ref_accessible_child(host, 0) orelse return error.ChildMissing;
    try std.testing.expect(discovered == provider);
    g_object_unref(discovered);
    try state.refresh(document);
    if (external) {
        window.show();
        try bridge.positionChanged();
        try state.paint();
        const old_flags = fcntl(0, 3);
        if (old_flags < 0 or fcntl(0, 4, old_flags | @as(c_int, 2048)) != 0) return error.ControlNonblockingFailed;
        const watcher = g_unix_fd_add(0, 1 | 16, State.control, &state);
        if (watcher == 0) return error.ControlWatcherFailed;
        defer _ = g_source_remove(watcher);
        defer _ = fcntl(0, 4, old_flags);
        std.debug.print("external server ready; native ATK published\n", .{});
        try app.run();
        if (state.failure) |err| return err;
        return provider;
    }
    try textEquals(provider, original);
    try std.testing.expectEqual(@as(c_int, @intCast(try document.scalarLength())), atk_text_get_character_count(provider));
    try std.testing.expectEqual(@as(u32, 0x1f600), atk_text_get_character_at_offset(provider, 1));
    var start: c_int = 0;
    var end: c_int = 0;
    const emoji = atk_text_get_string_at_offset(provider, 1, 0, &start, &end) orelse return error.CharUnavailable;
    defer g_free(emoji);
    try std.testing.expectEqualStrings("😀", std.mem.span(emoji));
    try std.testing.expect(start == 1 and end == 2);
    try std.testing.expect(atk_text_get_string_at_offset(provider, 1, 1, &start, &end) == null and start == -1 and end == -1);
    try std.testing.expectEqual(@as(c_int, 0), atk_text_get_n_selections(provider));
    try std.testing.expectEqual(@as(c_int, 0), atk_text_set_caret_offset(provider, 1));
    try std.testing.expectEqual(@as(c_int, 0), atk_text_add_selection(provider, 0, 1));
    try std.testing.expectEqual(@as(c_int, 0), atk_component_grab_focus(provider));
    try geometryUnavailable(provider, 1);
    try state.paint();
    const accepted = character(provider, 1);
    try std.testing.expect(accepted[2] > 0 and accepted[3] > 0);
    const hit = atk_text_get_offset_at_point(provider, accepted[0], accepted[1] + @divTrunc(accepted[3], 2), 2);
    try std.testing.expect(hit >= 0 and hit <= 2);
    try pointOracle(&state, provider);
    if (!raw_close and !source_revoke) {
        for (0..3) |at| {
            var bytes: [64]u8 = undefined;
            const text = try std.fmt.bufPrint(&bytes, "OOM candidate {d} 😀\n", .{at});
            try document.replace(.{ .start = 0, .end = try document.byteLength() }, text);
            failing.fail_index = failing.alloc_index + at;
            try std.testing.expectError(error.OutOfMemory, state.prepareText(document));
            failing.fail_index = std.math.maxInt(usize);
            try std.testing.expect(atk_text_get_text(provider, 0, -1) == null);
            try std.testing.expectEqual(@as(u64, 0), (try bridge.stats()).host_staging_bytes);
            try state.prepareText(document);
        }
        try document.replace(.{ .start = 0, .end = try document.byteLength() }, original);
        try state.refresh(document);
        try state.paint();
        for (0..9) |at| {
            failing.fail_index = failing.alloc_index + at;
            try std.testing.expectError(error.OutOfMemory, bridge.prepareGeometry(&.{null}));
            failing.fail_index = std.math.maxInt(usize);
            try std.testing.expectEqual(@as(u64, 0), (try bridge.stats()).host_staging_bytes);
        }
        try bridge.prepareGeometry(&.{null});
    }
    state.fail_frame = true;
    try state.paint();
    try std.testing.expectEqualSlices(c_int, &accepted, &character(provider, 1));
    state.fail_frame = false;
    _ = try adapter.replace(.{ .start = 0, .end = try document.byteLength() }, "changed 😀\n");
    try std.testing.expectError(error.TextRequired, bridge.updateMetadata());
    try std.testing.expect(atk_text_get_text(provider, 0, -1) == null);
    try state.refresh(document);
    try textEquals(provider, "changed 😀\n");
    try geometryUnavailable(provider, 0);
    try state.paint();
    try std.testing.expect(character(provider, 0)[3] > 0);
    try document.replace(.{ .start = 0, .end = try document.byteLength() }, "cannot\x00truncate");
    try std.testing.expectError(error.EmbeddedNul, state.prepareText(document));
    try std.testing.expect(atk_text_get_text(provider, 0, -1) == null);
    try document.replace(.{ .start = 0, .end = try document.byteLength() }, "restored 😀\n");
    try state.refresh(document);
    try state.paint();
    try textEquals(provider, "restored 😀\n");
    _ = g_signal_connect_data(provider, "visible-data-changed", State.geometrySignal, &state, null, 0);
    state.edit_on_geometry = true;
    try state.paint();
    try std.testing.expectEqual(@as(usize, 1), state.geometry_edits);
    try std.testing.expect(atk_text_get_text(provider, 0, -1) == null);
    try geometryUnavailable(provider, 0);
    try state.refresh(document);
    try state.paint();
    try textEquals(provider, "foreign mutation 😀\n");
    try document.replace(.{ .start = 0, .end = try document.byteLength() }, "");
    try state.refresh(document);
    try state.paint();
    try textEquals(provider, "");
    try std.testing.expectEqual(@as(c_int, 0), atk_text_get_character_count(provider));
    const empty_caret = character(provider, 0);
    try std.testing.expect(empty_caret[2] == 0 and empty_caret[3] > 0);
    if (source_revoke) {
        state.replace_source = true;
        try state.paint();
        try std.testing.expect(!window.isClosed());
        try std.testing.expect(atk_text_get_text(provider, 0, -1) == null);
        try std.testing.expectError(error.Closed, bridge.positionChanged());
    }
    if (raw_close) gtk_widget_destroy(window.nativeHandle().?) else _ = try window.destroy();
    try std.testing.expect(window.isClosed());
    try std.testing.expect(atk_text_get_text(provider, 0, -1) == null);
    try std.testing.expectError(error.Closed, bridge.positionChanged());
    try bridge.close();
    bridge_live = false;
    state.bridge = null;
    // Return a genuine ATK reference beyond Bridge, Adapter, Document and App.
    return provider;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const args = try zio.argsAlloc(allocator, init.args);
    defer zio.argsFree(allocator, args);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--external")) {
        const late = try exercise(allocator, false, true, false);
        g_object_unref(late);
        try std.testing.expectEqualDeep(@as(a.ResourceCounts, .{ .accounts = 0, .blocks = 0, .bytes = 0 }), a.resourceCounts());
        return;
    }
    for (0..3) |at| {
        const late = try exercise(allocator, at == 1, false, at == 2);
        try std.testing.expect(atk_text_get_text(late, 0, -1) == null);
        g_object_unref(late);
        try std.testing.expectEqualDeep(@as(a.ResourceCounts, .{ .accounts = 0, .blocks = 0, .bytes = 0 }), a.resourceCounts());
    }
    try completeHitRoutes(allocator);
    try std.testing.expectEqualDeep(@as(a.ResourceCounts, .{ .accounts = 0, .blocks = 0, .bytes = 0 }), a.resourceCounts());
    std.debug.print("Linux document native passed: genuine host/full Unicode/CHAR/read-only/success+failed front/new version/NUL/restore/empty caret/3 text+9 geometry OOM/foreign Document+Source revoke/normal+raw close/late ATK past App; ledger=0\n", .{});
}
