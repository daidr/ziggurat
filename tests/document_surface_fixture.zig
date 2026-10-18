const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const d = @import("ziggurat_document");
const t = @import("ziggurat_text_layout");
const editing = @import("ziggurat_document_editor");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("NO_STRICT", "1");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn gtk_widget_grab_focus(*anyopaque) void;
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_test_surrounding(*anyopaque, [*]u8, usize, *usize, *usize) c_int;
extern fn zlg_test_commit(*anyopaque, [*:0]const u8) void;
extern fn zlg_resource_count() u32;

const text = "alpha beta!\r\nlast";
const bounds: editing.Rect = .{ .x = 8, .y = 8, .width = 180, .height = 100 };
const raster: ui.layout.Size = .{ .width = 240, .height = 160 };
const offset: ui.layout.Point = .{ .x = 3, .y = 5 };
const checkpoint_message = 0x8000 + 194;
const Case = enum { rotation, shear, reflection, same_geometry_drag, changed_transform, changed_clip, polygon_miss, failed_missing, scroll_ime, generation_reentry };

fn Harness(comptime Native: type) type {
    return struct {
        const Self = @This();
        const Hook = struct {
            backing: std.mem.Allocator,
            host: ?*Self = null,
            armed: bool = false,
            fired: bool = false,
            fn allocator(self: *@This()) std.mem.Allocator {
                return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
            }
            fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                if (self.armed) {
                    self.armed = false;
                    self.fired = true;
                    const host = self.host.?;
                    host.placeholder = true;
                    host.matrix.x0 += 9;
                    host.paint() catch @panic("reentrant successful front failed");
                }
                return self.backing.rawAlloc(len, alignment, ra);
            }
            fn resize(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                return self.backing.rawResize(bytes, alignment, len, ra);
            }
            fn remap(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                return self.backing.rawRemap(bytes, alignment, len, ra);
            }
            fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                self.backing.rawFree(bytes, alignment, ra);
            }
        };
        case: Case,
        app: *z.App,
        app_ready: bool = false,
        window: z.Window = undefined,
        context: ui.Context = undefined,
        adapter: *editing.Adapter,
        document: *d.Document,
        engine: *t.Engine,
        hook: *Hook,
        parameters: editing.Parameters = .{ .font = .{ .word_ranges = true, .size = 16 } },
        matrix: ui.affine.Affine = .{ .xx = 0.8, .yx = 0.6, .xy = -0.6, .yy = 0.8, .x0 = 170, .y0 = 35 },
        parent_clip: ui.Rect = .{ .x = 5, .y = 5, .width = 500, .height = 350 },
        a: z.Point = undefined,
        b: z.Point = undefined,
        stage: usize = 0,
        downs: usize = 0,
        ups: usize = 0,
        moves: usize = 0,
        failures: usize = 0,
        paints: usize = 0,
        fail_frame: bool = false,
        omit: bool = false,
        plain: bool = false,
        placeholder: bool = false,
        expected_paint_error: bool = false,
        paint_error: ?anyerror = null,
        failure: ?anyerror = null,

        fn fail(self: *Self, err: anyerror) void {
            if (self.failure == null) self.failure = err;
            std.debug.print("Document surface {s} stage={d} down/up/move={d}/{d}/{d}: {s}\n", .{ @tagName(self.case), self.stage, self.downs, self.ups, self.moves, @errorName(err) });
            if (self.app_ready) self.app.quit();
        }
        fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (value.operation == .paint) self.paint_error = value.err else self.fail(value.err orelse error.UnexpectedDiagnostic);
        }
        fn action(_: *anyopaque, _: u64) void {}
        fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.drawChecked(frame) catch |err| {
                frame.failure = frame.failure orelse err;
                self.fail(err);
            };
        }
        fn drawChecked(self: *Self, frame: *ui.Frame) !void {
            frame.clear(0xffffff);
            if (self.plain) return;
            try frame.pushClip(self.parent_clip);
            try frame.beginTransform(raster, self.matrix);
            try frame.pushOffset(offset);
            if (!self.omit) try frame.captureSpace(90, bounds);
            // The adversarial allocator may repaint while Adapter is Busy.
            // Its independently prepared placeholder performs no editor work.
            if (self.placeholder) frame.rect(bounds, 0xeeeeee) else try self.adapter.draw(frame, bounds, .{});
            try frame.popOffset();
            try frame.endTransform();
            try frame.popClip();
            if (self.fail_frame) frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0);
            self.paints += 1;
        }
        fn input(ptr: *anyopaque, _: *ui.Context, value: z.Event) bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.receive(value) catch |err| blk: {
                self.fail(err);
                break :blk true;
            };
        }
        fn selected(self: *Self, anchor: usize, caret: usize) !void {
            try std.testing.expectEqualDeep(d.Selection{ .anchor = anchor, .caret = caret }, try self.document.selection());
        }
        fn rejected(self: *Self, result: editing.PointerResult, expected: anyerror) !void {
            try std.testing.expect(result.handled and !result.selection_committed and result.presentation_error == null);
            try std.testing.expectEqual(expected, result.input_error orelse return error.MissingInputError);
            self.failures += 1;
        }
        fn receive(self: *Self, value: z.Event) !bool {
            switch (value) {
                .pointer_down, .pointer_up, .pointer_move => {},
                else => return self.adapter.handleEvent(self.window, value, bounds, self.parameters),
            }
            // Raw Window-DIP input is passed once. The Adapter is the only
            // place that maps it through the accepted Space.
            const result = try self.adapter.handlePointerEvent(self.window, value, bounds, self.parameters);
            if (value == .pointer_down) self.downs += 1 else if (value == .pointer_up) self.ups += 1 else self.moves += 1;
            if (self.case == .polygon_miss and self.stage == 0) {
                try std.testing.expect(!result.handled and !result.selection_committed and result.input_error == null and result.presentation_error == null);
                try self.selected(text.len, text.len);
                return false;
            }
            if ((self.case == .changed_transform or self.case == .changed_clip) and self.stage == 1) {
                try self.rejected(result, error.StalePointerInput);
                try self.selected(2, 2);
                return true;
            }
            if (self.case == .failed_missing and self.stage == 2) {
                try self.rejected(result, if (value == .pointer_down) error.SpaceNotFound else error.StalePointerInput);
                try self.selected(0, 5);
                return true;
            }
            if (result.input_error) |err| return err;
            if (result.presentation_error) |err| return err;
            try std.testing.expect(result.handled and result.selection_committed);
            if (value == .pointer_down) {
                switch (self.case) {
                    .rotation, .shear, .reflection => switch (self.stage) {
                        0, 3 => try self.selected(2, 2),
                        1 => try self.selected(0, 5),
                        2 => try self.selected(0, 13),
                        else => unreachable,
                    },
                    .failed_missing => if (self.stage == 1) try self.selected(0, 5) else try self.selected(2, 2),
                    else => try self.selected(2, 2),
                }
            } else if (self.case == .same_geometry_drag) try self.selected(2, 8);
            return true;
        }
        // Independent point oracle: the renderer narrows each coefficient to
        // f32, then applies the child offset once before that native matrix.
        // No Mapping or exported AABB participates in the expected input.
        fn windowPoint(self: *Self, local: z.Point) z.Point {
            const m = self.matrix;
            const xx: f64 = @as(f32, @floatCast(m.xx));
            const xy: f64 = @as(f32, @floatCast(m.xy));
            const yx: f64 = @as(f32, @floatCast(m.yx));
            const yy: f64 = @as(f32, @floatCast(m.yy));
            const x0: f64 = @as(f32, @floatCast(m.x0));
            const y0: f64 = @as(f32, @floatCast(m.y0));
            const x: f64 = local.x + offset.x;
            const y: f64 = local.y + offset.y;
            return .{ .x = @floatCast(xx * x + xy * y + x0), .y = @floatCast(yx * x + yy * y + y0) };
        }
        fn paint(self: *Self) !void {
            self.paint_error = null;
            if (builtin.os.tag == .windows) {
                _ = c.InvalidateRect(self.window.nativeHandle(), null, 0);
                _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0);
            } else {
                const size = try self.window.contentSize();
                const factor: u32 = @intFromFloat(size.scale);
                const native = self.app.windows.get(self.window.key).?.native.native.?;
                zlg_test_paint(native, size.width / factor, size.height / factor);
            }
            if (self.failure) |err| return err;
            if (self.expected_paint_error) {
                try std.testing.expect(self.paint_error != null);
            } else if (self.paint_error) |err| return err;
        }
        fn pair(self: *Self, point: z.Point, tick: u32) !void {
            try Native.button(self.window, point, .down, tick, false);
            try Native.button(self.window, point, .up, tick + 1, false);
        }
        fn checkpoint(self: *Self) !void {
            if (builtin.os.tag == .windows) {
                if (c.PostMessageW(self.window.nativeHandle(), checkpoint_message, 0, 0) == 0) return error.PostCheckpointFailed;
            } else try self.app.post(.{ .context = self, .call = next });
        }
        fn message(ptr: *anyopaque, _: z.Window, kind: u32, _: usize, _: isize) ?isize {
            if (kind != checkpoint_message) return null;
            next(ptr);
            return 0;
        }
        fn serviceDestroy(_: *anyopaque) void {}
        fn start(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.begin() catch |err| self.fail(err);
        }
        fn begin(self: *Self) !void {
            if (builtin.os.tag == .windows) {
                _ = c.SetFocus(self.window.nativeHandle());
                try std.testing.expect(c.GetFocus() == self.window.nativeHandle());
            } else gtk_widget_grab_focus(try Native.area(self.window));
            try self.paint();
            try self.adapter.setCommittedSpace(try self.context.committedSpace(90));
            try self.adapter.preparePointerSelection(self.window);
            if (self.case == .generation_reentry) {
                const before = try self.context.committedSpace(90);
                const revision = try self.document.version();
                self.hook.armed = true;
                const outcome = self.window.changeTextClient(self.window.textClientToken().?, .{ .replace = .{ .range = .{ .start = 0, .end = 1 }, .text = "Q" } });
                try std.testing.expect(self.hook.fired);
                try std.testing.expectError(error.StaleSpace, outcome);
                try std.testing.expect((try self.context.committedSpace(90)).generation > before.generation);
                try std.testing.expectEqual(revision, try self.document.version());
                self.failures += 1;
                self.app.quit();
                return;
            }
            if (self.case == .scroll_ime) {
                _ = try self.adapter.scrollBy(.{ .x = 1.375, .y = 0 });
                _ = try self.adapter.prepare(bounds, self.parameters);
                // The live Editor oracle checks the independently measured
                // local point after an explicit fractional horizontal scroll.
                try std.testing.expectEqual(@as(usize, 2), (try self.adapter.hitTest(bounds, .{ .x = self.a.x, .y = self.a.y })).byte_offset);
            }
            try self.queue();
        }
        fn queue(self: *Self) !void {
            const tick: u32 = @intCast(self.stage * 25);
            if ((self.case == .same_geometry_drag or self.case == .changed_transform or self.case == .changed_clip) and self.stage == 0) {
                try Native.button(self.window, self.windowPoint(self.a), .down, tick, false);
            } else if ((self.case == .same_geometry_drag or self.case == .changed_transform or self.case == .changed_clip) and self.stage == 1) {
                try Native.move(self.window, self.windowPoint(self.b), tick, true);
                try Native.button(self.window, self.windowPoint(self.b), .up, tick + 1, false);
            } else if (self.case == .polygon_miss and self.stage == 0) {
                // Rotated quad's AABB top-left lies outside its exact polygon.
                const p = self.windowPoint(.{ .x = bounds.x, .y = bounds.y });
                const q = self.windowPoint(.{ .x = bounds.x, .y = bounds.y + bounds.height });
                const miss: z.Point = .{ .x = q.x + 1, .y = p.y + 1 };
                try std.testing.expect(!try (try self.context.committedSpace(90)).contains(miss));
                try self.pair(miss, tick);
            } else try self.pair(self.windowPoint(self.a), tick);
            try self.checkpoint();
        }
        fn next(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.advance() catch |err| self.fail(err);
        }
        fn advance(self: *Self) !void {
            if (self.failure) |err| return err;
            if (self.case == .failed_missing and self.stage == 2) {
                try std.testing.expectEqual(@as(usize, 2), self.failures);
                self.app.quit();
                return;
            }
            const before = try self.context.committedSpace(90);
            const geometry = try before.geometryVersion();
            self.stage += 1;
            switch (self.case) {
                .rotation, .shear, .reflection => if (self.stage < 4) {
                    try self.paint();
                    const after = try self.context.committedSpace(90);
                    try std.testing.expect(after.generation != before.generation);
                    try std.testing.expectEqual(geometry, try after.geometryVersion());
                    return self.queue();
                },
                .same_geometry_drag, .changed_transform, .changed_clip => {
                    if (self.stage == 1) {
                        if (self.case == .changed_transform) self.matrix.x0 += 12;
                        if (self.case == .changed_clip) self.parent_clip.width -= 7;
                        try self.paint();
                        const current = try (try self.context.committedSpace(90)).geometryVersion();
                        try std.testing.expect((current == geometry) == (self.case == .same_geometry_drag));
                        return self.queue();
                    }
                    if (self.case != .same_geometry_drag and self.stage == 2) return self.queue();
                    if (self.case != .same_geometry_drag) try std.testing.expectEqual(@as(usize, 2), self.failures);
                },
                .polygon_miss => if (self.stage == 1) return self.queue(),
                .failed_missing => {
                    if (self.stage == 1) {
                        self.expected_paint_error = true;
                        self.fail_frame = true;
                        self.matrix.x0 += 12;
                        try self.paint();
                        self.matrix.x0 -= 12;
                        self.fail_frame = false;
                        self.expected_paint_error = false;
                        const after = try self.context.committedSpace(90);
                        try std.testing.expectEqual(before.generation, after.generation);
                        try std.testing.expectEqual(geometry, try after.geometryVersion());
                        return self.queue();
                    }
                    if (self.stage == 2) {
                        self.omit = true;
                        try self.paint();
                        const token = self.window.textClientToken().?;
                        var storage: [512]u8 = undefined;
                        try std.testing.expectError(error.SpaceNotFound, self.window.readTextClient(token, &storage));
                        try std.testing.expectError(error.SpaceNotFound, self.window.changeTextClient(token, .{ .select = .{ .anchor = 1, .caret = 1 } }));
                        return self.queue();
                    }
                    try std.testing.expectEqual(@as(usize, 2), self.failures);
                },
                .scroll_ime => {
                    const token = self.window.textClientToken().?;
                    var storage: [512]u8 = undefined;
                    const snap = try self.window.readTextClient(token, &storage);
                    try std.testing.expect(snap.bytes != 0);
                    _ = try self.adapter.handleEvent(self.window, .{ .text_preedit = .{ .text = "X", .selection_start = 0, .selection_end = 1 } }, bounds, self.parameters);
                    try std.testing.expect(try self.document.composition() != null);
                    _ = try self.adapter.handleEvent(self.window, .text_preedit_cancel, bounds, self.parameters);
                    try std.testing.expect(try self.document.composition() == null);
                    const version = try self.document.version();
                    if (builtin.os.tag == .linux) {
                        const native = self.app.windows.get(self.window.key).?.native.native.?;
                        var length: usize = 0;
                        var cursor: usize = 0;
                        try std.testing.expect(zlg_test_surrounding(native, &storage, storage.len, &length, &cursor) != 0);
                        zlg_test_commit(native, "Z");
                    } else _ = try self.window.changeTextClient(token, .{ .replace = .{ .range = .{ .start = 2, .end = 2 }, .text = "Z" } });
                    try std.testing.expect((try self.document.version()) > version);
                    try self.adapter.syncNativeCaret();
                    try self.paint();
                },
                .generation_reentry => unreachable,
            }
            self.app.quit();
        }
    };
}

pub fn run(comptime Native: type, allocator: std.mem.Allocator) !void {
    const Host = Harness(Native);
    const resources = t.resourceCounts();
    // One live Context per iteration; do not unroll its large Debug locals
    // into independent stack reservations in this test harness.
    for (std.meta.tags(Case)) |case| {
        var hook: Host.Hook = .{ .backing = allocator };
        const document = try d.Document.create(hook.allocator(), std.Thread.getCurrentId(), text, .{});
        defer document.close() catch unreachable;
        const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
        defer engine.close() catch unreachable;
        const adapter = try editing.Adapter.create(allocator, document, engine, .{});
        defer adapter.close() catch unreachable;
        var host: Host = .{ .case = case, .app = undefined, .adapter = adapter, .document = document, .engine = engine, .hook = &hook };
        hook.host = &host;
        const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &host, .emit = Host.diagnostic } });
        defer {
            host.app_ready = false;
            app.deinit();
        }
        host.app = app;
        host.app_ready = true;
        host.window = try app.createWindow(.{ .width = 540, .height = 400, .native_pointer_clicks = true });
        if (builtin.os.tag == .windows) try host.window.setService(.{ .context = &host, .message = Host.message, .native_destroying = Host.serviceDestroy });
        host.parameters.scale = (try host.window.contentSize()).scale;
        if (case == .shear) host.matrix = .{ .xx = 1, .yx = 0.2, .xy = 0.35, .yy = 1, .x0 = 45, .y0 = 35 };
        if (case == .reflection) host.matrix = .{ .xx = -1, .yx = 0.15, .xy = 0.2, .yy = 1, .x0 = 270, .y0 = 35 };
        _ = try adapter.prepare(bounds, host.parameters);
        const layout = try engine.layout(text, host.parameters.font);
        const a = try layout.caret(.{ .byte_offset = 2 });
        const b = try layout.caret(.{ .byte_offset = 8 });
        host.a = .{ .x = bounds.x + a.x, .y = bounds.y + a.y + a.height * 0.5 };
        host.b = .{ .x = bounds.x + b.x, .y = bounds.y + b.y + b.height * 0.5 };
        try layout.close();
        host.context = ui.Context.init(&host, Host.draw, Host.action);
        host.context.render_mode = .gdi;
        host.context.on_input = Host.input;
        try host.context.attach(host.window);
        try host.context.prepareTransforms(allocator, .{ .layers = .{ .size = try host.window.contentSize(), .max_depth = 3 }, .source_size = raster });
        try adapter.bind(host.window);
        defer adapter.unbind() catch unreachable;
        try app.post(.{ .context = &host, .call = Host.start });
        try app.run();
        if (host.failure) |err| return err;
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
        std.debug.print("Document surface native {s}: down/up/move={d}/{d}/{d} expected_rejections={d} paints={d} records=0\n", .{ @tagName(case), host.downs, host.ups, host.moves, host.failures, host.paints });
        // Adapter/Engine are still in scope; their independent resource check
        // is performed by the outer smoke after this complete function exits.
    }
    try std.testing.expectEqualDeep(resources, t.resourceCounts());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
}
