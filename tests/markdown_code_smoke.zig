//! Prepares Markdown code blocks with the system text engine and checks
//! that the default family is monospace, that the view embeds the
//! prepared size, and that release closes every native resource.
const std = @import("std");
const md = @import("ziggurat_markdown");
const mv = @import("ziggurat_markdown_view");
const code = @import("ziggurat_markdown_code");
const tl = @import("ziggurat_text_layout");
const view = @import("ziggurat_view");

const Doc = struct {
    tree: md.Tree,
    options: mv.Options,
    fn build(self: *Doc, v: *view.View) anyerror!void {
        _ = try mv.build(v, self.tree, self.options, .{});
    }
};

var parsed: md.Storage(256, 8192) = .{};
var nodes: view.Storage(512, 8192) = .{};

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .{};
    defer if (debug.deinit() != .ok) @panic("leak");
    const allocator = debug.allocator();
    const engine = try tl.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch @panic("engine still has layouts");

    // Equal advances for narrow and wide letters identify a monospace face.
    const narrow = try engine.layout("iiiiiiii", .{ .family = code.default_family, .size = 14 });
    defer narrow.close() catch {};
    const wide = try engine.layout("WWWWWWWW", .{ .family = code.default_family, .size = 14 });
    defer wide.close() catch {};
    const narrow_width = (try narrow.metrics()).bounds.width;
    const wide_width = (try wide.metrics()).bounds.width;
    if (@abs(narrow_width - wide_width) > 0.5) return error.NotMonospace;

    const tree = try md.parse("Intro\n\n```zig\nconst a = 1;\nconst longer_name = 2;\n```\n\n    indented\n", parsed.buffers());
    var blocks: code.CodeBlocks(4) = .{};
    try blocks.prepare(engine, allocator, tree, 2, .{});
    defer blocks.release() catch @panic("prepared text still in use");
    if (blocks.len != 2) return error.MissingBlocks;
    for (blocks.entries[0..blocks.len]) |entry| if (entry.size.width <= 0 or entry.size.height <= 0) return error.EmptyBlock;
    // Two lines are taller than one.
    if (blocks.entries[0].size.height <= blocks.entries[1].size.height) return error.WrongLines;

    var doc: Doc = .{ .tree = tree, .options = .{ .code = blocks.face() } };
    var harness = view.Harness.init(&doc, Doc.build, nodes.buffers(), .{});
    try harness.render();
    if (harness.count(.{ .kind = .embed }) != 2) return error.MissingEmbeds;
    const first = try harness.find(.{ .kind = .embed, .nth = 0 });
    if (@abs(first.bounds.width - blocks.entries[0].size.width) > 0.01) return error.WrongSize;

    // A reparsed tree is not matched to stale preparations.
    const other = try md.parse("```\nx\n```", parsed.buffers());
    var stale: Doc = .{ .tree = other, .options = .{ .code = blocks.face() } };
    var again = view.Harness.init(&stale, Doc.build, nodes.buffers(), .{});
    try again.render();
    if (again.count(.{ .kind = .embed }) != 0) return error.StaleEmbed;
    try blocks.release();
    if (blocks.len != 0) return error.NotReleased;
    std.debug.print("smoke-markdown-code: ok\n", .{});
}
