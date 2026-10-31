const std = @import("std");
const builtin = @import("builtin");
const d = @import("ziggurat_document");
const viewing = @import("ziggurat_document_diff_view");
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn zlg_test_surrounding(*anyopaque, [*]u8, usize, *usize, *usize) c_int;
extern fn zlg_test_delete_surrounding(*anyopaque, c_int, c_int) c_int;

pub fn run(comptime Surface: type, state: *@import("document_diff_editable_smoke.zig").Harness(Surface)) !void {
    const document = state.inbox.pair.b;
    if (Surface == viewing.EditableUnified) try state.view.focus() else try state.view.focus(.b);
    const caret = (try document.line(2)).start + 1;
    _ = try state.adapters[1].setSelection(.{ .anchor = caret, .caret = caret }, .downstream);
    try state.view.prepare(state.viewport, state.parameters);
    if (builtin.os.tag == .windows) {
        var bytes: [12352]u8 align(8) = undefined;
        const offer: *c.RECONVERTSTRING = @ptrCast(&bytes);
        const hwnd = state.window.nativeHandle();
        try std.testing.expect(c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_DOCUMENTFEED, 0) > 0);
        offer.dwSize = bytes.len;
        try std.testing.expect(c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_RECONVERTSTRING, @bitCast(@intFromPtr(offer))) > 0);
        const base = try document.utf16Offset(caret) - offer.dwTargetStrOffset / 2;
        const hidden = try document.utf16Offset((try document.line(20)).start);
        try std.testing.expect(hidden >= base and hidden - base < offer.dwStrLen);
        offer.dwCompStrOffset = @intCast((hidden - base) * 2);
        offer.dwTargetStrOffset = offer.dwCompStrOffset;
        offer.dwCompStrLen = 1;
        offer.dwTargetStrLen = 1;
        const revision = try document.version();
        // Host rejection cannot force a language engine to abandon its
        // original offer; it proves only that no hidden selection is adopted.
        state.expected = error.CaretInsideFold;
        try std.testing.expectEqual(@as(isize, 0), c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_CONFIRMRECONVERTSTRING, @bitCast(@intFromPtr(offer))));
        state.expected = null;
        try std.testing.expectEqual(revision, try document.version());
        offer.dwSize = bytes.len;
        try std.testing.expect(c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_RECONVERTSTRING, @bitCast(@intFromPtr(offer))) > 0);
        offer.dwCompStrLen = 1;
        offer.dwTargetStrLen = 1;
        try std.testing.expectEqual(@as(isize, 1), c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_CONFIRMRECONVERTSTRING, @bitCast(@intFromPtr(offer))));
        try std.testing.expectEqual(d.Selection{ .anchor = caret, .caret = caret + 1 }, try document.selection());
        // No UI text event followed the native confirmation. The one Adapter
        // observer must synchronously refresh both projections and caret.
        try std.testing.expect(!(try state.view.info()).comparison_required);
        for (state.adapters) |adapter| try std.testing.expect((try adapter.stats()).folds != 0);
    } else {
        const record = state.window.app.windows.get(state.window.key).?.native.native.?;
        var bytes: [12288]u8 = undefined;
        var length: usize = 0;
        var cursor: usize = 0;
        try std.testing.expectEqual(@as(c_int, 1), zlg_test_surrounding(record, &bytes, bytes.len, &length, &cursor));
        try std.testing.expectEqual(caret, cursor);
        const before = try document.byteLength();
        try std.testing.expectEqual(@as(c_int, 1), zlg_test_delete_surrounding(record, -1, 1));
        try std.testing.expectEqual(before - 1, try document.byteLength());
        try std.testing.expect((try state.view.info()).comparison_required);
        for (state.adapters) |adapter| try std.testing.expectEqual((try adapter.stats()).paragraphs, (try adapter.stats()).visible_paragraphs);
        try state.paint();
        _ = try state.adapters[1].undo();
        try state.refresh();
    }
    try state.paint();
}
