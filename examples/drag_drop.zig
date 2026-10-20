//! Drop target: accept files and text dragged onto the window.
//!
//! A `ziggurat_system.drop.Target` registers the window as a native drop
//! target. `on_hover` reports enter/over/leave with the client point and what
//! the source offers, and returns whether the drop would be accepted (the
//! checkboxes choose); the drop zone highlights while something hovers.
//! `on_drop` receives the files (NUL-separated absolute paths) or text in a
//! caller-allocated buffer, which the example copies into its own storage
//! and lists.
//!
//! Dragging *out* of the window is not offered by the framework
//! (`drop.capabilities.drag_source` is false), so this example only receives.
//!
//! Run with `zig build run-drag-drop`, then drag files from a file manager or
//! selected text from another program onto the window.
const std = @import("std");
const z = @import("ziggurat");
const view = @import("ziggurat_view");
const drop = @import("ziggurat_system").drop;

const Dropped = enum { nothing, files, text, too_large, failed };

const DropZone = struct {
    window: ?z.Window = null,
    accept_files: bool = true,
    accept_text: bool = true,
    hover: ?drop.Hover = null,
    /// Whether the current hover would be accepted.
    accepted: bool = false,
    drops: usize = 0,
    dropped: Dropped = .nothing,
    /// The last payload, copied out of the Target buffer (borrowed only
    /// during on_drop). Allocated by main.
    storage: []u8 = &.{},
    len: usize = 0,
    needed: usize = 0,
    scroll: view.ScrollModel = .{},

    fn onHover(ptr: *anyopaque, window: z.Window, hover: drop.Hover) bool {
        const self: *DropZone = @ptrCast(@alignCast(ptr));
        self.accepted = (hover.files and self.accept_files) or (hover.text and self.accept_text);
        self.hover = if (hover.phase == .leave) null else hover;
        window.invalidate();
        return self.accepted;
    }
    fn onDrop(ptr: *anyopaque, window: z.Window, value: drop.Drop) void {
        const self: *DropZone = @ptrCast(@alignCast(ptr));
        self.drops += 1;
        self.len = 0;
        switch (value.payload) {
            .files, .text => |bytes| {
                const count = @min(bytes.len, self.storage.len);
                @memcpy(self.storage[0..count], bytes[0..count]);
                self.len = count;
                self.dropped = if (value.payload == .files) .files else .text;
            },
            .capacity_exceeded => |needed| {
                self.needed = needed;
                self.dropped = .too_large;
            },
            .failed => self.dropped = .failed,
        }
        window.invalidate();
    }

    fn build(self: *DropZone, v: *view.View) anyerror!void {
        try v.text("Drag and drop", .{ .font = view.Font.heading3 });
        try v.row(.{ .gap = 16 });
        _ = try v.checkbox(&self.accept_files, "Accept files", .{});
        _ = try v.checkbox(&self.accept_text, "Accept text", .{});
        try v.end();

        // The drop zone reflects the live hover state.
        const hovering = self.hover != null;
        const fill: u32 = if (!hovering) 0xeef1f4 else if (self.accepted) 0xd9f0dd else 0xf6dcd6;
        const edge: u32 = if (!hovering) 0xb8c2cc else if (self.accepted) 0x2f8f46 else 0xb2452c;
        try v.column(.{ .self_align = .stretch, .height = 110, .background = fill, .border = edge, .border_width = 2, .radius = 8, .alignment = .center, .justify = .center, .gap = 4 });
        if (self.hover) |hover| {
            const offer = if (hover.files and hover.text) "files and text" else if (hover.files) "files" else "text";
            try v.textf("{s}: {s}", .{ if (self.accepted) "Release to drop" else "Not accepted", offer }, .{});
            try v.textf("at ({d:.0}, {d:.0})", .{ hover.point.x, hover.point.y }, .{ .color = 0x536475 });
        } else {
            try v.text("Drop files or text anywhere on this window", .{});
        }
        try v.end();

        try v.textf("Drops received: {d}", .{self.drops}, .{ .color = 0x536475 });
        try v.scroll(&self.scroll, .{ .grow = 1, .self_align = .stretch, .gap = 4 });
        const bytes = self.storage[0..self.len];
        switch (self.dropped) {
            .nothing => try v.text("Nothing dropped yet.", .{ .color = 0x536475 }),
            .files => {
                var paths = std.mem.splitScalar(u8, bytes, 0);
                var index: u64 = 0;
                while (paths.next()) |path| : (index += 1) try v.text(path, .{ .key = index + 1, .font = view.Font.code });
            },
            .text => {
                var lines = std.mem.splitScalar(u8, bytes, '\n');
                var index: u64 = 0;
                while (lines.next()) |line| : (index += 1) {
                    if (index == 40) break;
                    try v.text(line, .{ .key = index + 1 });
                }
            },
            .too_large => try v.textf("The payload needs {d} bytes; the buffer holds {d}.", .{ self.needed, self.storage.len }, .{ .color = 0xa04020 }),
            .failed => try v.text("The drop could not be read.", .{ .color = 0xa04020 }),
        }
        try v.end();
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Explicit, bounded storage: one buffer the Target fills during a drop and
    // one the application keeps the last payload in.
    const target_buffer = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(target_buffer);
    const kept = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(kept);

    var zone: DropZone = .{ .storage = kept };
    var storage: view.Storage(128, 16 * 1024) = .{};
    var host = view.Host.init(&zone, DropZone.build, storage.buffers(), .{});
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Ziggurat / Drag and drop", .width = 640, .height = 460 });
    zone.window = window;
    try host.attach(window);

    // Target and its context stay put until detach or the window's on_closed.
    var target: drop.Target = .{ .context = &zone, .on_drop = DropZone.onDrop, .on_hover = DropZone.onHover, .buffer = target_buffer };
    try target.attach(window);
    defer target.detach();

    window.show();
    try app.run();
}

test "drop updates the listing" {
    var kept: [256]u8 = undefined;
    var zone: DropZone = .{ .storage = &kept };
    var storage: view.Storage(128, 4096) = .{};
    var h = view.Harness.init(&zone, DropZone.build, storage.buffers(), .{});
    try h.render();
    _ = try h.find(.{ .text = "Nothing dropped yet." });
    const paths = "/tmp/a.txt\x00/tmp/b.txt";
    @memcpy(kept[0..paths.len], paths);
    zone.len = paths.len;
    zone.dropped = .files;
    try h.render();
    _ = try h.find(.{ .text = "/tmp/b.txt" });
    try h.click(.{ .text = "Accept text" });
    try std.testing.expect(!zone.accept_text);
}
