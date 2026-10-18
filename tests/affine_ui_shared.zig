const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");

pub const matrix: ui.affine.Affine = .{ .xx = 0.8, .yx = 0.6, .xy = -0.6, .yy = 0.8, .x0 = 85, .y0 = 12 };
pub const source: ui.layout.Size = .{ .width = 200, .height = 140 };
pub const button: ui.Rect = .{ .x = 10, .y = 10, .width = 60, .height = 24 };
pub const editor_bounds: ui.Rect = .{ .x = 10, .y = 78, .width = 140, .height = 24 };
pub const editor_space = 100;

pub fn Suite(comptime Native: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator = undefined,
        app: *z.App = undefined,
        window: z.Window = undefined,
        context: ?*ui.Context = null,
        editor: ui.editor.Editor = undefined,
        frame: ?*ui.Frame = null,
        actions: usize = 0,
        value: f64 = 20,
        closed: usize = 0,
        failed: ?anyerror = null,
        client_failed: ?anyerror = null,
        fail_frame: bool = false,
        plain: bool = false,
        close_draw: bool = false,
        native_caret_checks: usize = 0,

        pub fn init(self: *Self, app: *z.App, allocator: std.mem.Allocator) !void {
            self.allocator = allocator;
            self.app = app;
            self.editor = try ui.editor.Editor.init(allocator, .{ .buffer = .{ .max_bytes = 1024, .undo_entries = 16 } }, "ab");
            errdefer self.editor.deinit();
            self.window = try app.createWindow(.{ .title = "Affine UI integration", .width = 280, .height = 220, .on_closed = .{ .context = self, .notify = closedWindow } });
            errdefer _ = self.window.destroy() catch {};
            const context = try allocator.create(ui.Context);
            self.context = context;
            context.* = ui.Context.init(self, draw, action);
            context.render_mode = .gdi;
            context.on_value = changedValue;
            context.on_input = input;
            try context.attach(self.window);
        }
        fn closedWindow(ptr: *anyopaque, _: z.Window) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const context = self.context;
            self.context = null;
            self.closed += 1;
            if (context) |value| self.allocator.destroy(value);
        }
        pub fn finish(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.app.quit();
        }
        pub fn options(self: *Self) !ui.layers.TransformOptions {
            return .{ .layers = .{ .size = try self.window.contentSize(), .max_depth = 4 }, .source_size = source };
        }
        pub fn paint(self: *Self) !void {
            Native.paint(self.window);
            if (self.failed) |err| return err;
        }
        pub fn point(local: ui.affine.Point) !z.Point {
            const result = try (try matrix.narrowed()).mapPoint(local);
            return .{ .x = @floatCast(result.x), .y = @floatCast(result.y) };
        }
        fn surface(self: *Self) ui.editor.Surface {
            return .{ .context = self, .line_height = 18, .measure = measure, .paint = editorPaint };
        }
        fn measure(_: *anyopaque, text: []const u8) !f32 {
            return @as(f32, @floatFromInt(try std.unicode.utf8CountCodepoints(text))) * 8;
        }
        fn editorPaint(ptr: *anyopaque, command: ui.editor.PaintCommand) !void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const frame = self.frame orelse return error.PaintOutsideFrame;
            switch (command) {
                .text => |text| frame.label(text.bounds, text.text, 0x111111),
                .selection => |bounds| frame.rect(bounds, 0x90b0ff),
                .caret => |bounds| frame.rect(bounds, 0x111111),
                .composition => |bounds| frame.rect(bounds, 0x3366aa),
            }
        }
        fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.drawChecked(frame) catch |err| {
                self.failed = err;
            };
        }
        fn drawChecked(self: *Self, frame: *ui.Frame) !void {
            frame.clear(if (self.fail_frame) 0xff0000 else 0xffffff);
            if (self.plain) return;
            try frame.pushClip(.{ .x = 0, .y = 0, .width = 260, .height = 210 });
            var transform = matrix;
            if (self.fail_frame) transform.x0 += 20;
            try frame.beginTransform(source, transform);
            if (self.close_draw) {
                _ = try self.window.destroy();
                try std.testing.expect(self.context != null);
                return;
            }
            const stops = [_]ui.commands.brushes.Stop{ .{ .offset = 0, .color = ui.Color.rgb(0xf4f7ff) }, .{ .offset = 1, .color = ui.Color.rgb(0xc0dcff) } };
            frame.gradientRect(.{ .x = 0, .y = 0, .width = source.width, .height = source.height }, 0, .{ .linear = .{ .start = .{}, .end = .{ .x = source.width }, .stops = &stops } });
            try frame.button(1, button, "Transformed action");
            try frame.slider(2, .{ .x = 10, .y = 42, .width = 140, .height = 20 }, self.value, .{ .minimum = 0, .maximum = 100, .step = 1 }, .{ .control = .{ .name = "Transformed range" } });
            try frame.checkbox(3, .{ .x = 160, .y = 10, .width = 30, .height = 24 }, "Off", false, .{ .enabled = false });
            try frame.captureSpace(editor_space, editor_bounds);
            try frame.pushClip(editor_bounds);
            self.frame = frame;
            defer self.frame = null;
            try self.editor.draw(editor_bounds, self.surface());
            try frame.popClip();
            const selection = self.editor.buffer.selection();
            try frame.semantic(.{ .id = 9, .role = .text_box, .name = "Transformed editor", .value = self.editor.buffer.text(), .bounds = editor_bounds, .read_only = true, .selection_start = selection.anchor, .selection_end = selection.caret });
            if (self.fail_frame) frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0);
            try frame.endTransform();
            try frame.popClip();
        }
        fn action(ptr: *anyopaque, id: u64) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (id != 1) {
                self.failed = error.UnexpectedAction;
                return;
            }
            self.actions += 1;
        }
        fn changedValue(ptr: *anyopaque, id: u64, change: ui.ValueChange) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (id != 2) {
                self.failed = error.UnexpectedRange;
                return;
            }
            self.value = (ui.Range{ .minimum = 0, .maximum = 100, .step = 1 }).apply(self.value, change) catch unreachable;
        }
        fn input(ptr: *anyopaque, context: *ui.Context, event: z.Event) bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.edit(context, event) catch |err| {
                self.failed = err;
                return true;
            };
        }
        fn edit(self: *Self, context: *ui.Context, event: z.Event) !bool {
            switch (event) {
                .pointer_down, .pointer_up, .pointer_move, .wheel, .key_input, .text_input, .text_preedit, .text_preedit_cancel, .focus, .cancel_input => {},
                else => return false,
            }
            const token = context.committedSpace(editor_space) catch |err| switch (err) {
                error.TransformsNotPrepared, error.StaleSpace, error.SpaceNotFound => return false,
                else => return err,
            };
            if (event == .pointer_down and !try token.contains(event.pointer_down.position)) {
                _ = try self.editor.handleEvent(.{ .focus = false }, editor_bounds, self.surface());
                return false;
            }
            const mapped = try token.mapEvent(event, .{});
            const handled = try self.editor.handleEvent(mapped, editor_bounds, self.surface());
            if (handled and self.editor.focused) {
                var caret = try self.editor.caretRect(self.surface());
                caret.x += editor_bounds.x - self.editor.scroll.offset.x;
                caret.y += editor_bounds.y - self.editor.scroll.offset.y;
                try token.setTextCaret(caret);
            }
            return handled;
        }
        pub fn exercise(self: *Self) !void {
            const context = self.context.?;
            const options_value = try self.options();
            var failing = std.testing.FailingAllocator.init(self.allocator, .{ .fail_index = 0 });
            try std.testing.expectError(error.OutOfMemory, context.prepareTransforms(failing.allocator(), options_value));
            try std.testing.expectEqual(@as(usize, 0), (try context.transformStats()).metadata_bytes);
            try context.prepareTransforms(self.allocator, options_value);
            try self.paint();
            try std.testing.expect(context.frames > 0);
            const initial = try context.committedSpace(editor_space);
            const button_point = try point(.{ .x = 40, .y = 22 });
            try Native.click(self.window, button_point);
            try std.testing.expectEqual(@as(usize, 1), self.actions);
            Native.key(self.window, .space);
            try std.testing.expectEqual(@as(usize, 2), self.actions);
            try Native.click(self.window, try point(.{ .x = 175, .y = 22 }));
            try std.testing.expectEqual(@as(usize, 2), self.actions);
            try Native.pointer(self.window, .down, try point(.{ .x = 80, .y = 52 }));
            try Native.pointer(self.window, .move, try point(.{ .x = 195, .y = 52 }));
            try Native.pointer(self.window, .up, try point(.{ .x = 195, .y = 52 }));
            try std.testing.expectEqual(@as(f64, 100), self.value);
            try std.testing.expect(context.input_state.active == null);
            Native.focus(self.window);
            try Native.click(self.window, try point(.{ .x = 18.5, .y = 86 }));
            if (self.failed) |err| return err;
            try std.testing.expect(self.editor.focused);
            try std.testing.expect(self.editor.window_active);
            Native.text(self.window);
            if (self.failed) |err| return err;
            try std.testing.expectEqualStrings("a中b", self.editor.buffer.text());
            try self.paint();
            try std.testing.expectError(error.StaleSpace, initial.localPoint(button_point));
            const accepted = try context.committedSpace(editor_space);
            var caret = try self.editor.caretRect(self.surface());
            caret.x += editor_bounds.x;
            caret.y += editor_bounds.y;
            try Native.checkCaret(self.window, accepted, caret);
            self.native_caret_checks += 1;
            const frames = context.frames;
            const old_pixel = try Native.pixel(context);
            var invalid = options_value;
            invalid.layers.bytes = 1;
            try std.testing.expectError(error.LayerBudgetExceeded, context.prepareTransforms(self.allocator, invalid));
            _ = try accepted.localPoint(button_point);
            try context.prepareTransforms(self.allocator, options_value);
            try std.testing.expectEqual(frames, context.frames);
            try std.testing.expectEqual(old_pixel, try Native.pixel(context));
            _ = try accepted.localPoint(button_point);
            self.fail_frame = true;
            try self.paint();
            try std.testing.expectEqual(frames, context.frames);
            try std.testing.expectEqual(old_pixel, try Native.pixel(context));
            _ = try accepted.localPoint(try point(.{ .x = 20, .y = 85 }));
            self.fail_frame = false;
            try std.testing.expectError(error.ResourceInUse, context.releaseTransforms());
            self.plain = true;
            try self.paint();
            try context.releaseTransforms();
            try std.testing.expectEqual(@as(usize, 0), (try context.transformStats()).metadata_bytes);
            try std.testing.expectError(error.StaleSpace, accepted.contains(button_point));
            try context.prepareTransforms(self.allocator, options_value);
            self.plain = false;
            try self.paint();
        }

        const ClosingAllocator = struct {
            backing: std.mem.Allocator,
            owner: *Self,
            fired: bool = false,
            fn allocator(self: *ClosingAllocator) std.mem.Allocator {
                return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
            }
            fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
                const self: *ClosingAllocator = @ptrCast(@alignCast(ptr));
                if (!self.fired) {
                    self.fired = true;
                    const closed = self.owner.window.destroy() catch @panic("allocator close failed");
                    std.debug.assert(closed == .deferred and self.owner.context != null);
                }
                return self.backing.rawAlloc(len, alignment, address);
            }
            fn resize(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, address: usize) bool {
                const self: *ClosingAllocator = @ptrCast(@alignCast(ptr));
                return self.backing.rawResize(bytes, alignment, len, address);
            }
            fn remap(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, address: usize) ?[*]u8 {
                const self: *ClosingAllocator = @ptrCast(@alignCast(ptr));
                return self.backing.rawRemap(bytes, alignment, len, address);
            }
            fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
                const self: *ClosingAllocator = @ptrCast(@alignCast(ptr));
                self.backing.rawFree(bytes, alignment, address);
            }
        };
        pub fn reentry(app: *z.App, allocator: std.mem.Allocator) !void {
            var preparing: Self = .{};
            try preparing.init(app, allocator);
            defer preparing.editor.deinit();
            defer {
                if (!preparing.window.isClosed()) _ = preparing.window.destroy() catch {};
                app.dispatch() catch @panic("preparation cleanup failed");
            }
            var closing: ClosingAllocator = .{ .backing = allocator, .owner = &preparing };
            const options_value = try preparing.options();
            try std.testing.expectError(error.Closed, preparing.context.?.prepareTransforms(closing.allocator(), options_value));
            try app.dispatch();
            try std.testing.expect(closing.fired and preparing.context == null and preparing.closed == 1);

            var painting: Self = .{};
            try painting.init(app, allocator);
            defer painting.editor.deinit();
            defer {
                if (!painting.window.isClosed()) _ = painting.window.destroy() catch {};
                app.dispatch() catch @panic("paint cleanup failed");
            }
            try painting.context.?.prepareTransforms(allocator, try painting.options());
            painting.close_draw = true;
            Native.paint(painting.window);
            // GTK schedules callback-triggered native close at the next safe dispatch.
            try app.dispatch();
            if (painting.failed) |err| return err;
            try std.testing.expect(painting.context == null and painting.closed == 1);
        }
    };
}
