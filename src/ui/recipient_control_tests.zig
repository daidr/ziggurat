const std = @import("std");
const z = @import("ziggurat");

// The root supplies its real private frame commit and event ingress. These
// tests exercise public tokens against the ordinary Input/Workspace banks.
pub fn Tests(comptime U: type) type {
    return struct {
        const size: z.Size = .{ .width = 120, .height = 80, .scale = 1 };
        const bounds: z.Rect = .{ .x = 0, .y = 0, .width = 50, .height = 30 };
        const Mode = enum { normal, pass_input, replace_input, replace_focus, replace_blur, reopen_blur };
        const Probe = struct {
            context: *U.ContextType = undefined,
            token: ?U.TokenType = null,
            retired: ?U.TokenType = null,
            mode: Mode = .normal,
            focus_calls: usize = 0,
            blur_calls: usize = 0,
            inputs: usize = 0,
            actions: usize = 0,
            preprocessing: usize = 0,
            failure: ?anyerror = null,

            fn draw(_: *anyopaque, _: *U.FrameType) void {}
            fn ordinaryAction(_: *anyopaque, _: u64) void {}
            fn registration(self: *@This()) U.RegistrationType {
                return .{ .context = self, .focus = focus, .blur = blur, .input = input, .action = action };
            }
            fn replace(self: *@This()) !void {
                const before = self.token.?;
                try std.testing.expect(!try before.close());
                self.retired = before;
                self.token = try self.context.registerControlRecipient(before.key.id, self.registration());
                try std.testing.expect(self.token.?.key.serial > before.key.serial);
                try std.testing.expect(self.token.?.key.slot != before.key.slot);
            }
            fn focus(ptr: *anyopaque, scope: *U.ScopeType) !void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                try scope.validate();
                self.focus_calls += 1;
                if (self.mode == .replace_focus) {
                    self.mode = .normal;
                    try self.replace();
                    try std.testing.expectError(error.StaleTextField, scope.validate());
                }
            }
            fn blur(ptr: *anyopaque, _: z.Window) !void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                self.blur_calls += 1;
                if (self.mode == .replace_blur) {
                    self.mode = .normal;
                    try self.replace();
                } else if (self.mode == .reopen_blur) {
                    self.mode = .normal;
                    const before = self.token.?;
                    self.retired = before;
                    try self.context.prepareRecipients(std.testing.allocator, .{ .recipients = 4 });
                    self.token = try self.context.registerControlRecipient(before.key.id, self.registration());
                    try std.testing.expect(self.token.?.key.serial > before.key.serial);
                }
            }
            fn input(ptr: *anyopaque, scope: *U.ScopeType, _: z.Event) !U.ResultType {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                try scope.validate();
                self.inputs += 1;
                if (self.mode == .pass_input) return .{};
                return .{ .handled = true };
            }
            fn action(ptr: *anyopaque, scope: *U.ScopeType, _: U.ActionType) !U.ResultType {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                try scope.validate();
                self.actions += 1;
                return .{ .handled = true, .changed = true };
            }
            fn preprocess(ptr: *anyopaque, _: *U.ContextType, event: z.Event) bool {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                if (event == .pointer_down and self.mode == .replace_input) {
                    self.preprocessing += 1;
                    self.mode = .normal;
                    self.replace() catch |err| {
                        self.failure = err;
                    };
                }
                return false;
            }
        };
        const TextProbe = struct {
            fn focus(_: *anyopaque, _: *U.ScopeType) !z.TextClientToken {
                return error.NotBound;
            }
            fn blur(_: *anyopaque, _: z.Window) !void {}
            fn input(_: *anyopaque, _: *U.ScopeType, _: z.Event) !U.TextResultType {
                return .{};
            }
            fn action(_: *anyopaque, _: *U.ScopeType, _: U.TextActionType) !U.TextResultType {
                return .{};
            }
            fn registration(context: *anyopaque) U.TextRegistrationType {
                return .{ .context = context, .focus = focus, .blur = blur, .input = input, .action = action };
            }
        };
        fn initialize(context: *U.ContextType, host: *Probe, window: z.Window) !void {
            context.* = U.ContextType.init(host, Probe.draw, Probe.ordinaryAction);
            context.render_mode = .gdi;
            context.semantics_enabled = false;
            context.on_input = Probe.preprocess;
            try context.attach(window);
            host.context = context;
            try context.prepareRecipients(std.testing.allocator, .{ .recipients = 4 });
            host.token = try context.registerControlRecipient(7, host.registration());
        }
        fn frame(context: *U.ContextType, generation: u64) !U.FrameType {
            context.command_buffer.reset();
            const workspace = context.transforms.?;
            try U.begin(workspace, size, generation);
            try context.command_buffer.bindTransformStorage(&workspace.command_storage);
            context.input_state.beginMappedFrame(try workspace.state.pending());
            return .{ .context = context, .size = size, .transforms = workspace };
        }
        fn publish(context: *U.ContextType, window: z.Window, token: U.TokenType, generation: u64, enabled: bool) !void {
            var candidate = try frame(context, generation);
            try candidate.controlRecipient(token, bounds, enabled);
            try context.input_state.validateFrame();
            U.commit(context, window);
        }

        test "control tokens share focus and preserve their kind through text clear and reopen" {
            const app = try z.App.init(std.testing.allocator);
            defer app.deinit();
            const window = try app.createWindow(.{});
            defer _ = window.destroy() catch unreachable;
            var host: Probe = .{};
            var context: U.ContextType = undefined;
            try initialize(&context, &host, window);
            const text = try context.registerTextField(9, TextProbe.registration(&host));
            var candidate = try frame(&context, 1);
            try candidate.controlRecipient(host.token.?, bounds, true);
            try candidate.textField(text, .{ .x = 60, .y = 0, .width = 50, .height = 30 }, true);
            U.commit(&context, window);
            try host.token.?.focus();
            try std.testing.expectEqual(@as(?u64, 7), context.input_state.focused);
            try std.testing.expect(!try window.hasTextClient());
            try context.clearTextFields();
            try host.token.?.validate();
            try std.testing.expectEqual(@as(?u64, 7), context.input_state.focused);
            try std.testing.expectEqual(@as(usize, 0), host.blur_calls);
            try std.testing.expectError(error.TextFieldsClosed, context.registerTextField(9, TextProbe.registration(&host)));
            try context.prepareTextFields(std.testing.allocator, .{ .fields = 4 });
            const next = try context.registerTextField(9, TextProbe.registration(&host));
            try std.testing.expect(next.key.serial > text.key.serial);
            const forged: U.TextTokenType = .{ .context = &context, .key = host.token.?.key };
            try std.testing.expectError(error.InvalidRecipientKind, forged.validate());
            try std.testing.expectError(error.InvalidRecipientKind, forged.close());
            try host.token.?.validate();
            const result = try host.token.?.perform(.focus);
            try std.testing.expect(result.handled and result.changed);
            try std.testing.expectEqual(@as(usize, 1), host.actions);
        }

        test "preprocessing replacement cannot retarget an entered control event" {
            const app = try z.App.init(std.testing.allocator);
            defer app.deinit();
            const window = try app.createWindow(.{});
            defer _ = window.destroy() catch unreachable;
            var host: Probe = .{};
            var context: U.ContextType = undefined;
            try initialize(&context, &host, window);
            try publish(&context, window, host.token.?, 1, true);
            host.mode = .replace_input;
            U.event(&context, window, .{ .pointer_down = .{ .position = .{ .x = 5, .y = 5 }, .button = .primary } });
            if (host.failure) |err| return err;
            try std.testing.expectEqual(@as(usize, 1), host.preprocessing);
            try std.testing.expectEqual(@as(usize, 0), host.inputs);
            try std.testing.expectEqual(@as(usize, 0), host.focus_calls);
            try std.testing.expect(context.input_state.focused == null and context.input_state.active == null);
            try std.testing.expectError(error.StaleTextField, host.retired.?.validate());
            try publish(&context, window, host.token.?, 2, true);
            try host.token.?.focus();
            try std.testing.expectEqual(@as(usize, 1), host.focus_calls);
        }

        test "focus callback replacement does not publish focus or a text client" {
            const app = try z.App.init(std.testing.allocator);
            defer app.deinit();
            const window = try app.createWindow(.{});
            defer _ = window.destroy() catch unreachable;
            var host: Probe = .{};
            var context: U.ContextType = undefined;
            try initialize(&context, &host, window);
            try publish(&context, window, host.token.?, 1, true);
            host.mode = .replace_focus;
            const before = host.token.?;
            try std.testing.expectError(error.StaleTextField, before.focus());
            try std.testing.expect(context.input_state.focused == null);
            try std.testing.expect(!try window.hasTextClient());
            try std.testing.expectEqual(@as(usize, 1), host.focus_calls);
            try publish(&context, window, host.token.?, 2, true);
            try host.token.?.focus();
            try std.testing.expectEqual(@as(?u64, 7), context.input_state.focused);
        }

        test "failed frames retain control focus while successful removal blurs the pinned old recipient once" {
            const app = try z.App.init(std.testing.allocator);
            defer app.deinit();
            const window = try app.createWindow(.{});
            defer _ = window.destroy() catch unreachable;
            var host: Probe = .{};
            var context: U.ContextType = undefined;
            try initialize(&context, &host, window);
            try publish(&context, window, host.token.?, 1, true);
            try host.token.?.focus();
            var candidate = try frame(&context, 2);
            try candidate.controlRecipient(host.token.?, bounds, false);
            context.input_state.cancelFrame();
            context.transforms.?.state.cancelFrame();
            try std.testing.expectEqual(@as(?u64, 7), context.input_state.focused);
            try std.testing.expectEqual(@as(usize, 0), host.blur_calls);
            const old = host.token.?;
            var external_pin = try context.input_state.fields.?.borrow(old.key);
            defer external_pin.end();
            host.mode = .replace_blur;
            try publish(&context, window, host.token.?, 2, false);
            try std.testing.expectEqual(@as(usize, 1), host.blur_calls);
            try std.testing.expect(context.input_state.focused == null);
            try publish(&context, window, host.token.?, 3, true);
            try host.token.?.focus();
            try std.testing.expect(!try old.close());
            try std.testing.expectEqual(@as(?u64, 7), context.input_state.focused);
            try host.token.?.validate();
        }

        test "clear recipients withdraws old callbacks before blur can reopen and register a new serial" {
            const app = try z.App.init(std.testing.allocator);
            defer app.deinit();
            const window = try app.createWindow(.{});
            defer _ = window.destroy() catch unreachable;
            var host: Probe = .{};
            var context: U.ContextType = undefined;
            try initialize(&context, &host, window);
            try publish(&context, window, host.token.?, 1, true);
            try host.token.?.focus();
            host.mode = .reopen_blur;
            try context.clearRecipients();
            try std.testing.expect(context.input_state.focused == null);
            try std.testing.expectEqual(@as(usize, 1), host.blur_calls);
            try std.testing.expectError(error.StaleTextField, host.retired.?.validate());
            try std.testing.expect(context.input_state.fields.?.current(host.token.?.key));
            try publish(&context, window, host.token.?, 2, true);
            try host.token.?.focus();
            try std.testing.expectEqual(@as(?u64, 7), context.input_state.focused);
        }

        test "unhandled spatial boundary and range shortcut focus use recipient blur and focus callbacks" {
            inline for (.{ .spatial, .boundary, .range_shortcut }) |kind| {
                const app = try z.App.init(std.testing.allocator);
                defer app.deinit();
                const window = try app.createWindow(.{});
                defer _ = window.destroy() catch unreachable;
                var host: Probe = .{ .mode = .pass_input };
                var context: U.ContextType = undefined;
                try initialize(&context, &host, window);
                var candidate = try frame(&context, 1);
                try candidate.addControl(90, bounds, .{});
                try candidate.controlRecipient(host.token.?, .{ .x = 60, .y = 0, .width = 50, .height = 30 }, true);
                if (kind == .range_shortcut) try candidate.addControl(91, .{ .x = 0, .y = 40, .width = 50, .height = 20 }, .{ .shortcut = .{ .key = .f3 }, .range = .{ .spec = .{ .minimum = 0, .maximum = 100 }, .track = .{ .x = 0, .y = 40, .width = 50, .height = 20 } } });
                U.commit(&context, window);
                try host.token.?.focus();
                if (kind == .range_shortcut) {
                    try std.testing.expect(context.handleKeyInput(window, .{ .key = .f3 }));
                    try std.testing.expectEqual(@as(?u64, 91), context.input_state.focused);
                } else {
                    try std.testing.expect(context.handleKeyInput(window, .{ .key = .left }));
                    try std.testing.expectEqual(@as(?u64, 90), context.input_state.focused);
                    if (kind == .boundary) {
                        try std.testing.expect(context.handleKeyInput(window, .{ .key = .end }));
                        try std.testing.expectEqual(@as(?u64, 7), context.input_state.focused);
                        try std.testing.expectEqual(@as(usize, 2), host.focus_calls);
                    }
                }
                try std.testing.expectEqual(@as(usize, 1), host.blur_calls);
                try std.testing.expect(!try window.hasTextClient());
            }
        }

        test "recipient budget preflight performs no caller allocation or coordinate publication" {
            const app = try z.App.init(std.testing.allocator);
            defer app.deinit();
            const window = try app.createWindow(.{});
            defer _ = window.destroy() catch unreachable;
            var host: Probe = .{};
            var context = U.ContextType.init(&host, Probe.draw, Probe.ordinaryAction);
            context.render_mode = .gdi;
            context.semantics_enabled = false;
            try context.attach(window);
            const required = try context.recipientMetadata(4);
            try std.testing.expectEqual(@as(usize, 0), required.native_bytes);
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            try std.testing.expectError(error.TextFieldBudgetExceeded, context.prepareRecipients(failing.allocator(), .{ .recipients = 4, .bytes = required.total_bytes - 1 }));
            try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
            try std.testing.expect(context.input_state.fields == null and context.transforms == null);
            try context.prepareRecipients(std.testing.allocator, .{ .recipients = 4, .bytes = required.total_bytes });
            try std.testing.expectEqualDeep(required, try context.recipientsStats());
            const LegacySlot = struct { serial: u64, id: u64, pins: usize, registration: ?U.TextRegistrationType, token: ?z.TextClientToken };
            const LegacyMark = struct { serial: u64, slot: u8 };
            const fields = context.input_state.fields.?;
            std.debug.print("Recipient metadata registry={d} native={d} total={d}; Slot={d} legacySlot={d} Mark={d} legacyMark={d}; Input={d} Context={d}\n", .{ required.registry_bytes, required.native_bytes, required.total_bytes, @sizeOf(@TypeOf(fields.slots[0])), @sizeOf(LegacySlot), @sizeOf(@TypeOf(fields.banks[0].marks[0])), @sizeOf(LegacyMark), @sizeOf(@TypeOf(context.input_state)), @sizeOf(U.ContextType) });
            try context.clearRecipients();
            try std.testing.expectError(error.TextFieldBudgetExceeded, context.prepareRecipients(failing.allocator(), .{ .recipients = 4, .bytes = required.total_bytes - 1 }));
            try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
        }
    };
}
