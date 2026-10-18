const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");

pub fn Tests(comptime Control: type) type {
    return struct {
        const size: z.Size = .{ .width = 120, .height = 80, .scale = 1 };
        const bounds: ui.Rect = .{ .x = 0, .y = 0, .width = 50, .height = 20 };
        const Probe = struct {
            changes: usize = 0,
            activated: usize = 0,
            drawn: usize = 0,
            close_changed: bool = false,
            close_draw: bool = false,
            control: ?*Control = null,
            close_error: ?anyerror = null,
            fn hostDraw(_: *anyopaque, _: *ui.Frame) void {}
            fn hostAction(_: *anyopaque, _: u64) void {}
            fn closeEntered(self: *@This(), control: *Control) void {
                control.close() catch |err| {
                    self.close_error = err;
                    return;
                };
                self.close_error = error.FreedEnteredControl;
            }
            fn changed(ptr: ?*anyopaque, _: z.Window, control: *Control, _: Control.Change) void {
                const self: *@This() = @ptrCast(@alignCast(ptr.?));
                self.changes += 1;
                if (self.close_changed) {
                    self.close_changed = false;
                    self.closeEntered(control);
                }
            }
            fn activate(ptr: ?*anyopaque, _: z.Window, _: *Control, _: Control.RowToken) void {
                const self: *@This() = @ptrCast(@alignCast(ptr.?));
                self.activated += 1;
            }
            fn rowDraw(ptr: *anyopaque, _: *ui.Frame, _: Control.RowView) !void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                self.drawn += 1;
                if (self.close_draw) {
                    self.close_draw = false;
                    self.closeEntered(self.control.?);
                }
            }
        };
        fn initialize(context: *ui.Context, host: *Probe, window: z.Window) !void {
            context.* = ui.Context.init(host, Probe.hostDraw, Probe.hostAction);
            context.render_mode = .gdi;
            context.semantics_enabled = false;
            try context.attach(window);
            try context.prepareRecipients(std.testing.allocator, .{ .recipients = 4 });
        }
        fn create(host: *Probe) !*Control {
            const control = try Control.create(std.testing.allocator, std.Thread.getCurrentId(), &.{
                .{ .id = 11, .height = 10 }, .{ .id = 22, .height = 10 },
                .{ .id = 33, .height = 10 }, .{ .id = 44, .height = 10 },
            }, .{ .context = host, .changed = Probe.changed, .activated = Probe.activate });
            host.control = control;
            return control;
        }
        fn frame(context: *ui.Context, generation: u64) !ui.Frame {
            context.command_buffer.reset();
            const workspace = context.transforms.?;
            try ui.testing.begin(workspace, size, generation);
            try context.command_buffer.bindTransformStorage(&workspace.command_storage);
            context.input_state.beginMappedFrame(try workspace.state.pending());
            return .{ .context = context, .size = size, .transforms = workspace };
        }
        fn draw(context: *ui.Context, control: *Control, host: *Probe, generation: u64) !ui.Frame {
            var candidate = try frame(context, generation);
            _ = try control.draw(&candidate, bounds, "rows", .{ .context = host, .draw = Probe.rowDraw }, .{ .overscan = 0 });
            return candidate;
        }
        fn publish(context: *ui.Context, window: z.Window, control: *Control, host: *Probe, generation: u64) !void {
            _ = try draw(context, control, host, generation);
            try context.input_state.validateFrame();
            ui.testing.commit(context, window);
        }
        fn cancel(context: *ui.Context) void {
            context.input_state.cancelFrame();
            context.transforms.?.state.cancelFrame();
        }
        fn click(context: *ui.Context, window: z.Window, y: f32, modifiers: z.KeyModifiers) void {
            ui.testing.event(context, window, .{ .pointer_down = .{ .position = .{ .x = 5, .y = y }, .button = .primary, .modifiers = modifiers } });
            ui.testing.event(context, window, .{ .pointer_up = .{ .position = .{ .x = 5, .y = y }, .button = .primary, .modifiers = modifiers } });
        }

        test "mounted list cold catalog and commands precede accepted focus" {
            const app = try z.App.init(std.testing.allocator);
            defer app.deinit();
            const window = try app.createWindow(.{});
            defer _ = window.destroy() catch unreachable;
            var host: Probe = .{};
            var context: ui.Context = undefined;
            try initialize(&context, &host, window);
            const control = try create(&host);
            defer control.close() catch unreachable;
            try control.attach(&context, 7);
            try control.token.?.validateRegistration();
            try std.testing.expectError(error.StaleTextField, control.focus());
            _ = try control.select(try control.rowToken(22), .replace);
            const snapshot = try control.snapshotCatalog(std.testing.allocator, &.{
                .{ .id = 11, .text = "first" }, .{ .id = 22, .text = "second" },
                .{ .id = 33, .text = "third" }, .{ .id = 44, .text = "last" },
            }, .{});
            defer snapshot.close();
            try std.testing.expectEqual(@as(usize, 4), snapshot.count());
            try std.testing.expectEqualStrings("last", (try snapshot.row(3)).label);
            const changes = host.changes;
            try publish(&context, window, control, &host, 1);
            try std.testing.expectEqual(changes, host.changes);
            try control.focus();
            try std.testing.expectEqual(@as(?u64, 7), context.input_state.focused);
            try std.testing.expect(!try window.hasTextClient());
        }

        test "mounted list uses accepted scroll and allows consecutive selection events" {
            const app = try z.App.init(std.testing.allocator);
            defer app.deinit();
            const window = try app.createWindow(.{});
            defer _ = window.destroy() catch unreachable;
            var host: Probe = .{};
            var context: ui.Context = undefined;
            try initialize(&context, &host, window);
            const control = try create(&host);
            defer control.close() catch unreachable;
            try control.attach(&context, 7);
            try publish(&context, window, control, &host, 1);
            click(&context, window, 15, .{});
            ui.testing.event(&context, window, .{ .key_input = .{ .key = .down, .modifiers = .{ .shift = true } } });
            ui.testing.event(&context, window, .{ .key_input = .{ .key = .down, .modifiers = .{ .shift = true } } });
            try std.testing.expectEqual(@as(usize, 3), try control.selectedCount());
            try std.testing.expectEqual(@as(u64, 44), (try control.caret()).?.id);
            ui.testing.event(&context, window, .{ .key_input = .{ .key = .enter } });
            try std.testing.expectEqual(@as(usize, 1), host.activated);
            _ = try control.setScroll(20, bounds.height);
            _ = try draw(&context, control, &host, 2);
            cancel(&context);
            click(&context, window, 5, .{});
            try std.testing.expect(try control.selected(11));
            try publish(&context, window, control, &host, 3);
            click(&context, window, 5, .{});
            try std.testing.expect(try control.selected(33));
        }

        test "mounted list wheel does not steal focus and structure invalidates old image" {
            const app = try z.App.init(std.testing.allocator);
            defer app.deinit();
            const window = try app.createWindow(.{});
            defer _ = window.destroy() catch unreachable;
            var host: Probe = .{};
            var context: ui.Context = undefined;
            try initialize(&context, &host, window);
            const control = try create(&host);
            defer control.close() catch unreachable;
            try control.attach(&context, 7);
            try publish(&context, window, control, &host, 1);
            ui.testing.event(&context, window, .{ .wheel = .{ .position = .{ .x = 5, .y = 5 }, .delta = .{ .x = 0, .y = 10 } } });
            try std.testing.expectEqual(@as(?u64, null), context.input_state.focused);
            try std.testing.expectEqual(@as(f64, 10), try control.scrollOffset(bounds.height));
            _ = try control.replace(&.{ .{ .id = 44, .height = 10 }, .{ .id = 33, .height = 10 }, .{ .id = 22, .height = 10 }, .{ .id = 11, .height = 10 } }, bounds.height);
            click(&context, window, 5, .{});
            try std.testing.expectEqual(@as(usize, 0), try control.selectedCount());
            try publish(&context, window, control, &host, 2);
            click(&context, window, 5, .{});
            try std.testing.expectEqual(@as(usize, 1), try control.selectedCount());
        }

        test "mounted list retirement inside change and renderer pins the old shell" {
            const app = try z.App.init(std.testing.allocator);
            defer app.deinit();
            const window = try app.createWindow(.{});
            defer _ = window.destroy() catch unreachable;
            var host: Probe = .{};
            var context: ui.Context = undefined;
            try initialize(&context, &host, window);
            const first = try create(&host);
            try first.attach(&context, 7);
            try publish(&context, window, first, &host, 1);
            host.close_changed = true;
            click(&context, window, 5, .{});
            try std.testing.expectEqual(error.ResourceInUse, host.close_error.?);
            try std.testing.expectError(error.ListControlClosed, first.selectedCount());
            try first.close();
            const second = try create(&host);
            defer second.close() catch unreachable;
            try second.attach(&context, 7);
            host.close_draw = true;
            try std.testing.expectError(error.ListControlClosed, draw(&context, second, &host, 2));
            cancel(&context);
            try std.testing.expectEqual(error.ResourceInUse, host.close_error.?);
            try std.testing.expect(context.input_state.focused == null);
        }

        test "mounted list create captures options before allocator callbacks" {
            const Mutator = struct {
                options: *Control.Options,
                calls: usize = 0,
                fn allocator(self: *@This()) std.mem.Allocator {
                    return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
                }
                fn allocate(ptr: *anyopaque, size_: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
                    const self: *@This() = @ptrCast(@alignCast(ptr));
                    self.calls += 1;
                    self.options.* = .{ .enabled = false, .native_semantics = true, .adapter_bytes = 0, .edge_max_speed = 99, .model = .{ .bytes = 0, .peak_bytes = 0, .list = .{ .rows = 0, .owned_bytes = 0, .peak_bytes = 0 } } };
                    return std.testing.allocator.rawAlloc(size_, alignment, ra);
                }
                fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
                    std.testing.allocator.rawFree(memory, alignment, ra);
                }
            };
            var options: Control.Options = .{};
            var mutator: Mutator = .{ .options = &options };
            const control = try Control.create(mutator.allocator(), std.Thread.getCurrentId(), &.{.{ .id = 11, .height = 10 }}, options);
            defer control.close() catch unreachable;
            try std.testing.expect(mutator.calls > 1);
            try std.testing.expect(control.options.enabled and !control.options.native_semantics);
            try std.testing.expectEqual(@as(usize, 4096), control.options.adapter_bytes);
            try std.testing.expectEqual(@as(usize, 100_000), control.selection.options.list.rows);
            try std.testing.expectEqual(@as(usize, 1), try (try control.model()).count());
        }

        test "mounted list snapshot handles allocator retirement without detached context access" {
            const Mutator = struct {
                control: *Control,
                closed: bool = false,
                failure: ?anyerror = null,
                fn allocator(self: *@This()) std.mem.Allocator {
                    return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
                }
                fn allocate(ptr: *anyopaque, size_: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
                    const self: *@This() = @ptrCast(@alignCast(ptr));
                    if (!self.closed) {
                        self.closed = true;
                        self.control.close() catch |err| {
                            if (err != error.ResourceInUse) self.failure = err;
                        };
                    }
                    return std.testing.allocator.rawAlloc(size_, alignment, ra);
                }
                fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
                    std.testing.allocator.rawFree(memory, alignment, ra);
                }
            };
            const app = try z.App.init(std.testing.allocator);
            defer app.deinit();
            const window = try app.createWindow(.{});
            defer _ = window.destroy() catch unreachable;
            var host: Probe = .{};
            var context: ui.Context = undefined;
            try initialize(&context, &host, window);
            const control = try create(&host);
            defer control.close() catch unreachable;
            try control.attach(&context, 7);
            var mutator: Mutator = .{ .control = control };
            try std.testing.expectError(error.ListControlClosed, control.snapshotCatalog(mutator.allocator(), &.{
                .{ .id = 11, .text = "one" }, .{ .id = 22, .text = "two" }, .{ .id = 33, .text = "three" }, .{ .id = 44, .text = "four" },
            }, .{}));
            if (mutator.failure) |err| return err;
            try std.testing.expect(mutator.closed);
        }

        test "mounted list allocation failure releases model and adapter" {
            const Scenario = struct {
                fn run(allocator: std.mem.Allocator) !void {
                    const control = try Control.create(allocator, std.Thread.getCurrentId(), &.{.{ .id = 11, .height = 10 }}, .{});
                    defer control.close() catch unreachable;
                }
            };
            try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
        }
    };
}
