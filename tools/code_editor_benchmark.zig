const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const text = @import("ziggurat_text_layout");
const doc = @import("ziggurat_document");
const editor = @import("ziggurat_document_editor");
const code = @import("ziggurat_code_editor");

fn measure(allocator: std.mem.Allocator, count: usize) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    const source = try allocator.alloc(u8, 4096);
    defer allocator.free(source);
    @memset(source, 'a');
    const document = try doc.Document.create(allocator, std.Thread.getCurrentId(), source, .{});
    defer document.close() catch unreachable;
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const adapter = try editor.Adapter.create(allocator, document, engine, .{});
    defer adapter.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    defer broker.close() catch unreachable;
    const presenter = try code.Presenter.create(allocator, broker, adapter, engine, window, .{});
    defer presenter.close() catch unreachable;
    var diagnostics: [256]code.Diagnostic = undefined;
    for (diagnostics[0..count], 0..) |*item, index| item.* = .{ .range = .{ .start = index * 2, .end = index * 2 + 1 }, .message = "bounded diagnostic" };
    var job = try broker.begin(.diagnostics, 0);
    var result = try code.OwnedResult.init(allocator, .{ .diagnostics = diagnostics[0..count] }, job.limits);
    defer result.deinit();
    try job.release();
    try broker.publish(job.ticket, &result);
    _ = try broker.finish(job.ticket);
    const bounds: ui.Rect = .{ .x = 0, .y = 0, .width = 640, .height = 240 };
    const parameters: editor.Parameters = .{ .font = .{ .size = 16, .width = 640, .wrap = .none } };
    try presenter.prepare(bounds, parameters);
    const before = try adapter.stats();
    const generation = broker.display_generation;
    var elapsed: [64]u64 = undefined;
    for (&elapsed, 0..) |*duration, index| {
        var timer = try zio.Timer.start();
        _ = try adapter.setSelection(.{ .anchor = index % 32, .caret = index % 32 }, .downstream);
        try presenter.prepare(bounds, parameters);
        duration.* = timer.read();
    }
    const after = try adapter.stats();
    try std.testing.expectEqual(generation, broker.display_generation);
    try std.testing.expectEqual(before.shaped_batches, after.shaped_batches);
    std.mem.sort(u64, &elapsed, {}, std.sort.asc(u64));
    std.debug.print("code-editor diagnostics={d} text_bytes={d} selection_prepare_median_ns={d} p95_ns={d} additional_shaped_batches={d} presenter_reserved_peak={d}\n", .{ count, source.len, elapsed[elapsed.len / 2], elapsed[elapsed.len * 95 / 100], after.shaped_batches - before.shaped_batches, presenter.peak_reserved });
}

pub fn main() !void {
    var allocations: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocations.deinit() == .ok);
    try measure(allocations.allocator(), 1);
    try measure(allocations.allocator(), 256);
}
