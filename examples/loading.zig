//! The 29 loading indicators of the views, with their options: size,
//! color, easing, the ends of their strokes, and a pause. A frame holds at
//! most `ui.loading.max_entries` indicators, so the gallery shows them a
//! page at a time. Moving indicators ask for the next frame through
//! `View.wakeAt`; the `ziggurat_view_timer` turns that into one one-shot
//! timer, and a paused gallery schedules nothing.
//!
//! Run it with `zig build run-loading`.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const view_timer = @import("ziggurat_view_timer");

const kinds = ui.loading.all;
const per_page = 12;
const pages = (kinds.len + per_page - 1) / per_page;
const sizes = [_]f32{ 16, 24, 32, 48 };
const columns = [_]view.Track{view.Track.fraction(1)} ** 4;
const muted = 0x5f6b7a;

const Tint = enum { text, accent, muted };

const Gallery = struct {
    page: usize = 0,
    size: usize = 1,
    tint: Tint = .text,
    easing: ui.loading.Easing = .linear,
    cap: ui.loading.Cap = .round,
    paused: bool = false,
    /// One timer for the whole gallery, so a pause holds every pose and
    /// resuming continues from it.
    timer: view.LoadingTimer = .{},

    fn build(self: *Gallery, v: *view.View) anyerror!void {
        try v.text("Loading indicators", .{ .font = view.Font.heading3 });
        try v.toolbar(.{ .gap = 12, .alignment = .center, .name = "Options" });
        try v.segmented(.{ .name = "Size" });
        inline for (sizes, 0..) |size, index| _ = try v.segment(usize, &self.size, index, std.fmt.comptimePrint("{d}", .{size}), .{});
        try v.end();
        try v.segmented(.{ .name = "Color" });
        _ = try v.segment(Tint, &self.tint, .text, "Text", .{});
        _ = try v.segment(Tint, &self.tint, .accent, "Accent", .{});
        _ = try v.segment(Tint, &self.tint, .muted, "Muted", .{});
        try v.end();
        try v.segmented(.{ .name = "Easing" });
        _ = try v.segment(ui.loading.Easing, &self.easing, .linear, "Linear", .{});
        _ = try v.segment(ui.loading.Easing, &self.easing, .ease_in_out, "Ease in out", .{});
        _ = try v.segment(ui.loading.Easing, &self.easing, .stacked, "Stacked", .{});
        try v.end();
        try v.segmented(.{ .name = "Cap" });
        _ = try v.segment(ui.loading.Cap, &self.cap, .round, "Round", .{});
        _ = try v.segment(ui.loading.Cap, &self.cap, .flat, "Flat", .{});
        try v.end();
        _ = try v.checkbox(&self.paused, "Paused", .{});
        try v.end();

        const color: ?u32 = switch (self.tint) {
            .text => null,
            .accent => 0x2a6fd4,
            .muted => muted,
        };
        const look: view.LoadingOptions = .{
            .size = sizes[self.size],
            .color = color,
            .paused = self.paused,
            .timer = &self.timer,
            .variant = .{ .easing = self.easing, .cap = self.cap },
        };
        try v.grid(&columns, .{ .gap = 12, .grow = 1, .self_align = .stretch, .key = 1 });
        const first = self.page * per_page;
        for (kinds[first..@min(kinds.len, first + per_page)]) |kind| {
            try v.column(.{ .key = @intFromEnum(kind), .gap = 14, .alignment = .center, .justify = .center, .height = 116, .padding = .all(8), .radius = 8, .border = 0xd5dbe3 });
            try v.column(.{ .height = 48, .alignment = .center, .justify = .center });
            try v.loadingIndicator(kind, look, .{ .name = kind.name() });
            try v.end();
            try v.text(kind.name(), .{ .color = muted });
            try v.end();
        }
        try v.end();

        try v.row(.{ .gap = 12, .alignment = .center, .justify = .center, .key = 2 });
        if (try v.button("Previous", .{ .enabled = self.page > 0 })) self.page -= 1;
        try v.textf("Page {d} of {d}", .{ self.page + 1, pages }, .{});
        if (try v.button("Next", .{ .enabled = self.page + 1 < pages })) self.page += 1;
        try v.end();
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var gallery: Gallery = .{};
    var storage: view.Storage(128, 2048) = .{};
    var host = view.Host.init(&gallery, Gallery.build, storage.buffers(), .{});
    var timer = view_timer.Timer.init(&host);

    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Loading", .width = 780, .height = 640, .min_width = 560, .min_height = 480 });
    try host.attach(window);
    try timer.attach(app, allocator);
    window.show();
    try app.run();
    try timer.close();
}

test "pages show every indicator once and a pause schedules no frame" {
    var gallery: Gallery = .{};
    var storage: view.Storage(128, 2048) = .{};
    var h = view.Harness.init(&gallery, Gallery.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 780, .height = 640 } });
    try h.render();
    var seen: usize = 0;
    for (0..pages) |page| {
        const shown = h.count(.{ .kind = .loading });
        try std.testing.expect(shown <= ui.loading.max_entries);
        seen += shown;
        _ = try h.find(.{ .kind = .loading, .name = kinds[page * per_page].name() });
        try std.testing.expect(h.deadline() != null);
        if (page + 1 < pages) try h.click(.{ .text = "Next" });
    }
    try std.testing.expectEqual(kinds.len, seen);
    try h.click(.{ .text = "Paused" });
    try std.testing.expectEqual(@as(?u64, null), h.deadline());
    try h.click(.{ .text = "Previous" });
    try std.testing.expectEqual(@as(usize, pages - 2), gallery.page);
}
