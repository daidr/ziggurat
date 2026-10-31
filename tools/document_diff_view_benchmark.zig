const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const text = @import("ziggurat_text_layout");
const doc = @import("ziggurat_document");
const editor = @import("ziggurat_document_editor");
const diff = @import("ziggurat_document_diff");
const viewing = @import("ziggurat_document_diff_view");

fn percentiles(samples: []u64) struct { median: u64, p95: u64 } {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return .{ .median = samples[samples.len / 2], .p95 = samples[samples.len * 95 / 100] };
}

fn measure(allocator: std.mem.Allocator, records: usize) !void {
    const row = "record value 00\n";
    const bytes = try allocator.alloc(u8, row.len * records);
    defer allocator.free(bytes);
    for (0..records) |index| @memcpy(bytes[index * row.len ..][0..row.len], row);
    const a = try doc.Document.create(allocator, std.Thread.getCurrentId(), bytes, .{});
    defer a.close() catch unreachable;
    const b = try doc.Document.create(allocator, std.Thread.getCurrentId(), bytes, .{});
    defer b.close() catch unreachable;
    const at = records / 2 * row.len + 13;
    try b.replace(.{ .start = at, .end = at + 1 }, "1");
    const inbox = try viewing.Inbox.create(allocator, .{ .a = a, .b = b }, .{});
    defer inbox.close() catch unreachable;
    // CLI setup precedes App creation. Production applications perform this
    // bounded comparison on their explicit worker and deliver through App.post.
    const job = try inbox.begin();
    var result = diff.compare(allocator, job.a, job.b, .{}) catch |err| {
        try job.release();
        _ = try inbox.finish(job.ticket);
        return err;
    };
    defer result.deinit();
    try job.release();
    inbox.publish(job.ticket, &result) catch |err| {
        _ = try inbox.finish(job.ticket);
        return err;
    };
    _ = try inbox.finish(job.ticket);

    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 800, .height = 480 });
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const left = try editor.Adapter.create(allocator, a, engine, .{});
    defer left.close() catch unreachable;
    const right = try editor.Adapter.create(allocator, b, engine, .{});
    defer right.close() catch unreachable;
    const view = try viewing.View.create(allocator, inbox, left, right, engine, window, .{});
    defer view.close() catch unreachable;
    const bounds: ui.Rect = .{ .x = 0, .y = 0, .width = 800, .height = 480 };
    const parameters: viewing.Parameters = .{ .font = .{ .size = 16, .wrap = .word_character } };
    var timer = try zio.Timer.start();
    try view.prepare(bounds, parameters);
    const first_ns = timer.read();
    const first = try view.stats();
    var samples: [64]u64 = undefined;
    for (&samples, 0..) |*sample, index| {
        timer.reset();
        _ = try left.setSelection(.{ .anchor = index % 32, .caret = index % 32 }, .downstream);
        try view.prepare(bounds, parameters);
        sample.* = timer.read();
    }
    const unchanged = try view.stats();
    try std.testing.expectEqual(first.shaped_batches, unchanged.shaped_batches);
    const selection = percentiles(&samples);
    // A small back-and-forth scroll stays in the explicitly warmed paragraph
    // cache. This is CPU update timing, without replay or native presentation.
    for (&samples, 0..) |*sample, index| {
        timer.reset();
        _ = try view.scrollBy(if (index % 2 == 0) 20 else -20);
        try view.prepare(bounds, parameters);
        sample.* = timer.read();
    }
    const scrolling = percentiles(&samples);
    const after = try view.stats();
    try std.testing.expectEqual(unchanged.header_layouts, after.header_layouts);
    try std.testing.expectEqual(unchanged.header_prepared, after.header_prepared);
    std.debug.print("document-diff-view records={d} first_prepare_ns={d} selection_median_ns={d} selection_p95_ns={d} selection_shapes={d} scroll_median_ns={d} scroll_p95_ns={d} scroll_shapes={d} scroll_header_layouts={d} scroll_header_prepared={d} scroll_header_reuses={d} initial_shapes={d} indexed_rows={d} reserved_peak={d}\n", .{ records, first_ns, selection.median, selection.p95, unchanged.shaped_batches - first.shaped_batches, scrolling.median, scrolling.p95, after.shaped_batches - unchanged.shaped_batches, after.header_layouts - unchanged.header_layouts, after.header_prepared - unchanged.header_prepared, after.header_reuses - unchanged.header_reuses, first.shaped_batches, after.indexed_rows, after.peak_reserved_bytes });
}

pub fn main() !void {
    var allocations: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocations.deinit() == .ok);
    for ([_]usize{ 10000, 100000 }) |records| try measure(allocations.allocator(), records);
}
