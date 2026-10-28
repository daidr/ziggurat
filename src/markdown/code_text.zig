//! Monospace code blocks for `ziggurat_markdown_view`. `CodeBlocks`
//! lays out and rasterizes every code block of a tree with the system
//! text engine ahead of time, then hands the view embeds that only draw
//! the prepared text. Preparation allocates and calls native code, so it
//! runs on the main thread outside paint: after parsing, and again when
//! the window scale changes.
const std = @import("std");
const builtin = @import("builtin");
const md = @import("ziggurat_markdown");
const mv = @import("ziggurat_markdown_view");
const tl = @import("ziggurat_text_layout");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");

/// A monospace family every supported system resolves.
pub const default_family = if (builtin.os.tag == .windows) "Consolas" else "monospace";

pub const Options = struct {
    family: []const u8 = default_family,
    size: f32 = 14,
};

/// Prepared text that one frame can draw is limited, so at most this many
/// code blocks are prepared; later blocks fall back to plain lines.
pub const max_blocks = 32;

pub fn CodeBlocks(comptime capacity: usize) type {
    comptime std.debug.assert(capacity > 0 and capacity <= max_blocks);
    return struct {
        const Self = @This();
        const Entry = struct {
            node: u32,
            /// Content hash, telling a reparsed tree apart.
            hash: u64,
            layout: *tl.Layout,
            prepared: *tl.Prepared,
            size: view.Size,
        };
        entries: [capacity]Entry = undefined,
        len: usize = 0,

        /// Replace the prepared blocks with those of `tree` at `scale`.
        /// Fails with `Busy` while a frame still draws the previous ones;
        /// the old blocks then stay usable.
        pub fn prepare(self: *Self, engine: *tl.Engine, allocator: std.mem.Allocator, tree: md.Tree, scale: f32, options: Options) !void {
            for (self.entries[0..self.len]) |entry| if (try entry.prepared.inUse()) return error.Busy;
            try self.release();
            errdefer self.release() catch {};
            for (tree.nodes, 0..) |node, index| {
                if (node.kind != .code_block or self.len == capacity) continue;
                const text = std.mem.trimEnd(u8, node.text, "\n");
                const layout = try engine.layoutAllocated(allocator, if (text.len == 0) " " else text, .{ .family = options.family, .size = options.size });
                errdefer layout.close() catch {};
                const prepared = try layout.prepare(scale, .{});
                const bounds = (try layout.metrics()).bounds;
                self.entries[self.len] = .{ .node = @intCast(index), .hash = std.hash.Wyhash.hash(0, node.text), .layout = layout, .prepared = prepared, .size = .{ .width = bounds.x + bounds.width, .height = bounds.y + bounds.height } };
                self.len += 1;
            }
        }

        /// Close every prepared block. Fails with `Busy` while a frame
        /// still draws one.
        pub fn release(self: *Self) !void {
            while (self.len > 0) {
                const entry = self.entries[self.len - 1];
                try entry.prepared.close();
                try entry.layout.close();
                self.len -= 1;
            }
        }

        pub fn face(self: *Self) mv.CodeFace {
            return .{ .context = self, .embed = embed };
        }

        fn embed(context: *anyopaque, tree: md.Tree, index: u32) ?view.Embed {
            const self: *Self = @ptrCast(@alignCast(context));
            for (self.entries[0..self.len]) |*entry| {
                if (entry.node == index and entry.hash == std.hash.Wyhash.hash(0, tree.get(index).text))
                    return .{ .context = entry, .measure = measure, .paint = paint };
            }
            return null;
        }
        fn measure(context: *anyopaque, _: view.Theme) view.layout.Measurement {
            const entry: *Entry = @ptrCast(@alignCast(context));
            return .{ .minimum = .{ .width = 0, .height = entry.size.height }, .preferred = entry.size };
        }
        fn paint(context: *anyopaque, frame: *ui.Frame, _: u64, bounds: view.Rect) anyerror!void {
            const entry: *Entry = @ptrCast(@alignCast(context));
            const rgb = frame.context.currentTheme().palette.text;
            const color = ui.Color.rgb(rgb);
            const prepared = try entry.prepared.view();
            if (prepared.coverage.scale == frame.size.scale) {
                try frame.pushClip(bounds);
                defer frame.popClip() catch {};
                return frame.preparedText(.{ .x = bounds.x, .y = bounds.y }, prepared, color);
            }
            // Until the application prepares the new scale, draw each line
            // with the label face rather than a mis-scaled bitmap.
            const text = try entry.layout.text();
            for (try entry.layout.lines()) |line| {
                frame.label(.{ .x = bounds.x + line.x, .y = bounds.y + line.y, .width = bounds.width, .height = line.height }, text[line.start..line.end], rgb);
            }
        }
    };
}
