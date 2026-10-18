const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const t = @import("ziggurat_text_layout");
const d = @import("ziggurat_document");
const e = @import("ziggurat_document_editor");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const before = t.resourceCounts();
    {
        const app = try z.App.init(allocator);
        defer app.deinit();
        const window = try app.createWindow(.{ .width = 320, .height = 180 });
        defer _ = window.destroy() catch unreachable;
        const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
        defer engine.close() catch unreachable;
        for ([_][]const u8{ "", "\n", "a\n", "a😀e\u{301} אבג\r\nsecond\n", "wrapped words and more wrapped words and even more wrapped words" }) |text| {
            const document = try d.Document.create(allocator, std.Thread.getCurrentId(), text, .{});
            defer document.close() catch unreachable;
            const adapter = try e.Adapter.create(allocator, document, engine, .{});
            defer adapter.close() catch unreachable;
            const bounds: ui.Rect = .{ .x = 8, .y = 8, .width = 180, .height = 120 };
            _ = try adapter.prepare(bounds, .{ .scale = (try window.contentSize()).scale, .font = .{ .size = 18, .width = bounds.width, .wrap = .word_character } });
            var carets: [1024]e.GeometryCaret = undefined;
            var lines: [128]e.GeometryLine = undefined;
            const revision = try document.version();
            const snapshot = try adapter.preparedCarets(revision, &carets, &lines, .{});
            try std.testing.expect(snapshot.carets.len != 0 and snapshot.lines.len != 0);
            for (snapshot.carets) |caret| {
                try std.testing.expectEqual(@as(f32, 0), caret.rect.width);
                const expected = (try adapter.positionRect(revision, caret.position, caret.affinity)) orelse return error.MissingPreparedCaret;
                try std.testing.expectApproxEqAbs(expected.x, caret.rect.x, 0.001);
                try std.testing.expectApproxEqAbs(expected.y, caret.rect.y, 0.001);
                try std.testing.expectApproxEqAbs(expected.height, caret.rect.height, 0.001);
            }
            if (text.len == 0) try std.testing.expectEqual(@as(usize, 1), snapshot.lines.len);
            if (text.len != 0 and text[text.len - 1] == '\n') {
                const last = snapshot.lines[snapshot.lines.len - 1];
                for (snapshot.carets[last.first..][0..last.count]) |caret| try std.testing.expectEqual(text.len, caret.position);
            }
            const saved_caret = carets[0];
            const saved_line = lines[0];
            try std.testing.expectError(error.CaretCapacityExceeded, adapter.preparedCarets(revision, carets[0..0], &lines, .{}));
            try std.testing.expectEqualDeep(saved_caret, carets[0]);
            try std.testing.expectEqualDeep(saved_line, lines[0]);
            try std.testing.expectError(error.CaretCapacityExceeded, adapter.preparedCarets(revision, &carets, lines[0..0], .{}));
            try std.testing.expectEqualDeep(saved_caret, carets[0]);
            try std.testing.expectEqualDeep(saved_line, lines[0]);
            try document.setComposition("x", .{ .anchor = 0, .caret = 1 });
            try std.testing.expectError(error.StaleRevision, adapter.preparedCarets(revision, &carets, &lines, .{}));
        }
    }
    try std.testing.expectEqualDeep(before, t.resourceCounts());
    std.debug.print("prepared caret geometry: Unicode/bidi/wrap/empty/trailing LF, exact cached caret oracle, atomic capacities and stale revision; resources=0\n", .{});
}
