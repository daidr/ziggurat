const std = @import("std");

pub fn Tests(comptime Control: type) type {
    return struct {
        const rows = [_]Control.Row{
            .{ .id = 11, .height = 10 },
            .{ .id = 22, .height = 20 },
            .{ .id = 33, .height = 30 },
            .{ .id = 44, .height = 40 },
            .{ .id = 55, .height = 50 },
        };
        fn create() !*Control {
            return Control.create(std.testing.allocator, std.Thread.getCurrentId(), &rows, .{});
        }
        fn expectSelection(control: *Control, ids: []const u64) !void {
            try std.testing.expectEqual(ids.len, try control.selectedCount());
            var cursor = try control.cursor();
            for (ids) |id| try std.testing.expectEqual(id, (try control.nextSelected(&cursor)).?.id);
            try std.testing.expectEqual(@as(?Control.Token, null), try control.nextSelected(&cursor));
        }
        test "selection changes once and explicit stable anchor drives ranges" {
            const control = try create();
            defer control.close() catch unreachable;
            const first = try control.token(22);
            try std.testing.expect((try control.select(first, .replace)).selection);
            try std.testing.expect(!(try control.select(first, .replace)).selection);
            _ = try control.select(try control.token(44), .extend);
            try expectSelection(control, &.{ 22, 33, 44 });
            try std.testing.expect(!(try control.select(try control.token(44), .extend)).selection);
            _ = try control.select(try control.token(55), .add_extend);
            try expectSelection(control, &.{ 22, 33, 44, 55 });
            _ = try control.select(try control.token(33), .toggle);
            try expectSelection(control, &.{ 22, 44, 55 });
            try std.testing.expectEqual(@as(u64, 33), (try control.anchor()).?.id);
        }
        test "reorder keeps selection identities and removed reinsertions cannot revive old tokens" {
            const control = try create();
            defer control.close() catch unreachable;
            const retained = try control.token(22);
            const removed = try control.token(33);
            const stamp = try control.stamp();
            _ = try control.select(retained, .replace);
            _ = try control.select(removed, .toggle);
            try control.replace(&.{ rows[3], rows[1], rows[0], rows[4] });
            try std.testing.expectEqual(@as(usize, 1), try control.resolve(retained));
            try std.testing.expectError(error.StaleRow, control.resolve(removed));
            try std.testing.expectError(error.StaleControlEvent, control.validateStamp(stamp));
            try expectSelection(control, &.{22});
            try std.testing.expect((try control.anchor()) == null);
            try std.testing.expect((try control.caret()) == null);
            try control.replace(&rows);
            const replacement = try control.token(33);
            try std.testing.expect(replacement.incarnation != removed.incarnation);
            try std.testing.expectError(error.StaleRow, control.select(removed, .replace));
            try std.testing.expect(!(try control.selected(33)));
        }
        test "range anchor follows its stable row after a reorder" {
            const control = try create();
            defer control.close() catch unreachable;
            _ = try control.select(try control.token(22), .replace);
            try control.replace(&.{ rows[1], rows[4], rows[0], rows[2], rows[3] });
            _ = try control.select(try control.token(33), .extend);
            try expectSelection(control, &.{ 22, 55, 11, 33 });
        }
        test "context click keeps selected group and selects only an unselected row" {
            const control = try create();
            defer control.close() catch unreachable;
            _ = try control.select(try control.token(22), .replace);
            _ = try control.select(try control.token(44), .extend);
            const anchor = try control.anchor();
            try std.testing.expect(!(try control.contextSelect(try control.token(33))).selection);
            try expectSelection(control, &.{ 22, 33, 44 });
            try std.testing.expectEqualDeep(anchor, try control.anchor());
            _ = try control.contextSelect(try control.token(55));
            try expectSelection(control, &.{55});
        }
        test "drag can cross its origin and contract without retaining overshoot" {
            const control = try create();
            defer control.close() catch unreachable;
            const drag = try control.beginDrag(try control.token(33), .replace);
            _ = try control.updateDrag(drag.token, try control.token(55));
            try expectSelection(control, &.{ 33, 44, 55 });
            _ = try control.updateDrag(drag.token, try control.token(11));
            try expectSelection(control, &.{ 11, 22, 33 });
            _ = try control.updateDrag(drag.token, try control.token(22));
            try expectSelection(control, &.{ 22, 33 });
            try control.cancelDrag(drag.token);
            try std.testing.expectError(error.StaleDrag, control.updateDrag(drag.token, try control.token(55)));
            try expectSelection(control, &.{ 22, 33 });
        }
        test "additive drag restores its captured base outside the moving range" {
            const control = try create();
            defer control.close() catch unreachable;
            _ = try control.select(try control.token(11), .replace);
            _ = try control.select(try control.token(55), .toggle);
            const drag = try control.beginDrag(try control.token(44), .add_extend);
            _ = try control.updateDrag(drag.token, try control.token(22));
            try expectSelection(control, &.{ 11, 22, 33, 44, 55 });
            _ = try control.updateDrag(drag.token, try control.token(44));
            try expectSelection(control, &.{ 11, 44, 55 });
            _ = try control.updateDrag(drag.token, try control.token(55));
            try expectSelection(control, &.{ 11, 55 });
        }
        test "height changes and index replacement revoke a drag without replacing retained row identity" {
            const control = try create();
            defer control.close() catch unreachable;
            const retained = try control.token(33);
            const drag = try control.beginDrag(retained, .replace);
            try std.testing.expect(try control.setHeight(33, 31));
            try std.testing.expectEqual(@as(usize, 2), try control.resolve(retained));
            try std.testing.expectError(error.StaleDrag, control.updateDrag(drag.token, retained));
            const next = try control.beginDrag(retained, .replace);
            try control.replace(&rows);
            try std.testing.expectError(error.StaleDrag, control.updateDrag(next.token, retained));
        }
        test "navigation uses variable height positions and returns explicit f64 reveal scroll" {
            const control = try create();
            defer control.close() catch unreachable;
            _ = try control.navigate(.first, .replace, 0, 25);
            const next = try control.navigate(.page_next, .extend, 0, 25);
            try std.testing.expectEqual(@as(u64, 22), (try control.caret()).?.id);
            try expectSelection(control, &.{ 11, 22 });
            try std.testing.expectEqual(@as(f64, 5), next.scroll);
            _ = try control.navigate(.last, .caret_only, next.scroll, 25);
            try std.testing.expectEqual(@as(u64, 55), (try control.caret()).?.id);
            try expectSelection(control, &.{ 11, 22 });
            const before = try control.stamp();
            try std.testing.expectError(error.EmptyViewport, control.navigate(.page_previous, .replace, 0, 0));
            try control.validateStamp(before);
        }
        test "select all is bounded bit storage and inserted rows do not inherit old selection" {
            const control = try create();
            defer control.close() catch unreachable;
            try std.testing.expect((try control.selectAll()).selection);
            try std.testing.expect(!(try control.selectAll()).selection);
            try control.replace(&.{ rows[0], .{ .id = 99, .height = 7 }, rows[4] });
            try expectSelection(control, &.{ 11, 55 });
            try std.testing.expect(!(try control.selected(99)));
            var cursor = try control.cursor();
            _ = try control.clear();
            try std.testing.expectError(error.StaleControlEvent, control.nextSelected(&cursor));
        }
        test "failed replacement preserves model selection tokens and active drag" {
            const control = try create();
            defer control.close() catch unreachable;
            const token = try control.token(22);
            const drag = try control.beginDrag(token, .replace);
            const before = try control.stamp();
            try std.testing.expectError(error.DuplicateId, control.replace(&.{ rows[0], rows[0] }));
            try control.validateStamp(before);
            _ = try control.updateDrag(drag.token, try control.token(44));
            try expectSelection(control, &.{ 22, 33, 44 });
        }
        test "selection storage limits reject a candidate before changing accepted data" {
            const control = try Control.create(std.testing.allocator, std.Thread.getCurrentId(), &rows, .{ .bytes = @sizeOf(Control) + 128, .peak_bytes = @sizeOf(Control) + 220 });
            defer control.close() catch unreachable;
            _ = try control.select(try control.token(22), .replace);
            const before = try control.stamp();
            const bigger: [20]Control.Row = @splat(.{ .id = 1, .height = 1 });
            try std.testing.expectError(error.ControlBudgetExceeded, control.replace(&bigger));
            try control.validateStamp(before);
            try expectSelection(control, &.{22});
        }
        test "one million selected rows retain compact storage and constant visible membership queries" {
            const count = 1_000_000;
            const large = try std.testing.allocator.alloc(Control.Row, count);
            defer std.testing.allocator.free(large);
            for (large, 0..) |*row, index| row.* = .{ .id = @intCast(index + 1), .height = 1 };
            const control = try Control.create(std.testing.allocator, std.Thread.getCurrentId(), large, .{ .list = .{ .rows = count } });
            defer control.close() catch unreachable;
            _ = try control.selectAll();
            try std.testing.expectEqual(@as(usize, count), try control.selectedCount());
            for ([_]usize{ 0, 63, 64, 100_000, count - 1 }) |index| try std.testing.expect(try control.selectedAt(index));
            try std.testing.expectEqual(@as(usize, count / 64), control.selection.bits.len);
            try std.testing.expectEqual(@as(usize, count * 8 + count / 64 * (3 * 8 + 3 * @sizeOf(usize) + 24)), try control.arrayStorageBytes());
        }
        test "every control allocation failure retires its candidate and preserves accepted identity" {
            const Scenario = struct {
                fn run(allocator: std.mem.Allocator) !void {
                    const control = try Control.create(allocator, std.Thread.getCurrentId(), &rows, .{});
                    defer control.close() catch unreachable;
                    const token = try control.token(22);
                    const drag = try control.beginDrag(token, .replace);
                    const before = try control.stamp();
                    control.replace(&.{ rows[4], rows[1], .{ .id = 99, .height = 2 } }) catch |err| {
                        if (err != error.OutOfMemory) return err;
                        try control.validateStamp(before);
                        try std.testing.expectEqual(@as(usize, 1), try control.resolve(token));
                        try expectSelection(control, &.{22});
                        _ = try control.updateDrag(drag.token, try control.token(44));
                        try expectSelection(control, &.{ 22, 33, 44 });
                        return err;
                    };
                    try std.testing.expectEqual(@as(usize, 1), try control.resolve(token));
                    try expectSelection(control, &.{22});
                }
            };
            try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
        }
        test "selection and navigation require no allocator after explicit construction" {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            const control = try Control.create(failing.allocator(), std.Thread.getCurrentId(), &rows, .{});
            defer control.close() catch unreachable;
            failing.fail_index = failing.alloc_index;
            _ = try control.selectAll();
            _ = try control.select(try control.token(22), .replace);
            _ = try control.navigate(.next, .extend, 0, 30);
            const drag = try control.beginDrag(try control.token(44), .add_extend);
            _ = try control.updateDrag(drag.token, try control.token(11));
            try control.cancelDrag(drag.token);
            _ = try control.contextSelect(try control.token(33));
            _ = try control.clear();
        }
        test "foreign threads and exhausted identities cannot mutate the control" {
            const control = try create();
            defer control.close() catch unreachable;
            const Probe = struct {
                fn run(value: *Control) void {
                    std.testing.expectError(error.WrongThread, value.token(22)) catch unreachable;
                    std.testing.expectError(error.WrongThread, value.selectAll()) catch unreachable;
                    std.testing.expectError(error.WrongThread, value.close()) catch unreachable;
                }
            };
            const thread = try std.Thread.spawn(.{}, Probe.run, .{control});
            thread.join();
            control.incarnation = std.math.maxInt(u64);
            try control.replace(&rows);
            const before = try control.stamp();
            try std.testing.expectError(error.IdExhausted, control.replace(&.{.{ .id = 99, .height = 1 }}));
            try control.validateStamp(before);
            control.state_revision = std.math.maxInt(u64);
            try std.testing.expectError(error.IdExhausted, control.selectAll());
        }
        test "selection deltas preserve their captured model and contain only changed final words" {
            const control = try create();
            defer control.close() catch unreachable;
            _ = try control.select(try control.token(22), .replace);
            const patch = try control.selectionPatch();
            try std.testing.expectEqual(@as(usize, 1), patch.delta.words.len);
            try std.testing.expectEqual(@as(u64, 1), patch.delta.base);
            try std.testing.expectEqual(@as(u64, 2), patch.delta.revision);
            _ = try control.select(try control.token(22), .replace);
            const unchanged = try control.selectionPatch();
            try std.testing.expectEqual(@as(usize, 0), unchanged.delta.words.len);
            try std.testing.expectEqual(@as(u64, 2), unchanged.delta.revision);
            const before = try control.stamp();
            try std.testing.expectError(error.StaleRow, control.select(.{ .id = 99, .incarnation = 1 }, .replace));
            try control.validateStamp(before);
            try std.testing.expectEqual(@as(usize, 0), (try control.selectionPatch()).delta.words.len);
            try control.replace(&rows);
            try std.testing.expectError(error.CatalogRequired, control.selectionPatch());
        }
        test "failed drag replacement keeps the active gesture captured base" {
            const control = try create();
            defer control.close() catch unreachable;
            _ = try control.select(try control.token(11), .replace);
            _ = try control.select(try control.token(55), .toggle);
            const drag = try control.beginDrag(try control.token(44), .add_extend);
            const revision = control.selection.revision;
            control.selection.revision = std.math.maxInt(u64);
            try std.testing.expectError(error.IdExhausted, control.beginDrag(try control.token(11), .replace));
            control.selection.revision = revision;
            _ = try control.updateDrag(drag.token, try control.token(55));
            try expectSelection(control, &.{ 11, 55 });
        }
    };
}
