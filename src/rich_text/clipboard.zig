//! Connects a rich text `Editor` to the system clipboard of
//! `ziggurat_system`. A copy writes the editor's own format, HTML and plain
//! text; a paste reads its own format, HTML, RTF, Markdown and plain text,
//! one after another, and pastes the richest the editor reads. A paste that
//! matches the style reads plain text alone.
const std = @import("std");
const builtin = @import("builtin");
const system = @import("ziggurat_system");
const editor = @import("ziggurat_rich_text_editor");
const rt = @import("ziggurat_rich_text");

const Allocator = std.mem.Allocator;
const cb = system.clipboard;

/// The custom format of Rich Text Format: Windows registers it under this
/// name, GTK applications offer it as a MIME type.
pub const rtf_format = if (builtin.os.tag == .windows) "Rich Text Format" else "text/rtf";
pub const markdown_format = "text/markdown";

const Slot = enum { rich, html, rtf, markdown, text };
const order = [_]Slot{ .rich, .html, .rtf, .markdown, .text };

fn formatOf(slot: Slot) cb.Format {
    return switch (slot) {
        .rich => .{ .kind = .custom, .name = rt.clip.format },
        .html => .{ .kind = .html },
        .rtf => .{ .kind = .custom, .name = rtf_format },
        .markdown => .{ .kind = .custom, .name = markdown_format },
        .text => .{ .kind = .text },
    };
}

/// Keep at a stable address while connected; deinit before the Board.
pub const SystemClipboard = struct {
    allocator: Allocator,
    board: *cb.Board,
    request: cb.Request = .{},
    buffer: []u8 = &.{},
    /// The largest format read; one larger fails as unavailable.
    limit: usize = 16 * 1024 * 1024,
    target: ?*editor.Editor = null,
    match_style: bool = false,
    next: usize = 0,
    read: [order.len][]u8 = @splat(&.{}),

    pub fn init(allocator: Allocator, board: *cb.Board) SystemClipboard {
        return .{ .allocator = allocator, .board = board };
    }

    pub fn deinit(self: *SystemClipboard) void {
        self.request.cancel();
        self.clear();
        self.allocator.free(self.buffer);
        self.buffer = &.{};
    }

    /// The editor's `Options.clipboard`.
    pub fn clipboard(self: *SystemClipboard) editor.Clipboard {
        return .{ .context = self, .write = write, .read = startRead };
    }

    /// Ends a paste still reading, which then pastes nothing; call it
    /// before the editor it pastes into goes away.
    pub fn cancel(self: *SystemClipboard) void {
        self.request.cancel();
        self.clear();
        self.target = null;
    }

    fn clear(self: *SystemClipboard) void {
        for (&self.read) |*data| {
            self.allocator.free(data.*);
            data.* = &.{};
        }
    }

    fn write(context: ?*anyopaque, copied: editor.Copied) anyerror!void {
        const self: *SystemClipboard = @ptrCast(@alignCast(context.?));
        var entries: [3]cb.Entry = undefined;
        var n: usize = 0;
        if (copied.rich.len > 0) {
            entries[n] = .{ .format = formatOf(.rich), .data = copied.rich };
            n += 1;
        }
        if (copied.html.len > 0) {
            entries[n] = .{ .format = formatOf(.html), .data = copied.html };
            n += 1;
        }
        entries[n] = .{ .format = formatOf(.text), .data = copied.text };
        n += 1;
        try self.board.write(entries[0..n]);
    }

    fn startRead(context: ?*anyopaque, target: *editor.Editor, match_style: bool) anyerror!void {
        const self: *SystemClipboard = @ptrCast(@alignCast(context.?));
        // A paste while another reads replaces it.
        self.cancel();
        self.target = target;
        self.match_style = match_style;
        self.next = if (match_style) order.len - 1 else 0;
        if (self.buffer.len == 0) self.buffer = try self.allocator.alloc(u8, 64 * 1024);
        try self.readNext();
    }

    fn readNext(self: *SystemClipboard) !void {
        try self.board.read(&self.request, formatOf(order[self.next]), self.buffer, self, done, .{});
    }

    fn done(context: *anyopaque, result: cb.Result) void {
        const self: *SystemClipboard = @ptrCast(@alignCast(context));
        self.step(result) catch {
            // A format that cannot be read counts as one the clipboard
            // does not hold.
            self.advance();
        };
    }

    fn step(self: *SystemClipboard, result: cb.Result) !void {
        switch (result) {
            .data => |data| {
                self.read[self.next] = try self.allocator.dupe(u8, data);
                self.advance();
            },
            .capacity_exceeded => |size| {
                if (size > self.limit) return self.advance();
                // Read the format again into a buffer that holds it.
                const bigger = try self.allocator.alloc(u8, size);
                self.allocator.free(self.buffer);
                self.buffer = bigger;
                try self.readNext();
            },
            else => self.advance(),
        }
    }

    fn advance(self: *SystemClipboard) void {
        self.next += 1;
        while (self.next < order.len) {
            self.readNext() catch {
                self.next += 1;
                continue;
            };
            return;
        }
        self.finish();
    }

    fn finish(self: *SystemClipboard) void {
        const target = self.target orelse return self.clear();
        self.target = null;
        defer self.clear();
        target.paste(.{
            .rich = self.read[@intFromEnum(Slot.rich)],
            .html = self.read[@intFromEnum(Slot.html)],
            .rtf = self.read[@intFromEnum(Slot.rtf)],
            .markdown = self.read[@intFromEnum(Slot.markdown)],
            .text = self.read[@intFromEnum(Slot.text)],
        }, self.match_style);
    }
};
