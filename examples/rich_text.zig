//! A rich text editor: a toolbar of formats over `ziggurat_rich_text_editor`,
//! with the system clipboard connected, so that copies paste into other
//! applications as HTML and plain text, and HTML, RTF and Markdown copied
//! elsewhere paste with their formats. Markdown typed at the start of a
//! paragraph ("# ", "- ", "1. ", "[ ] ", "```") and around words ("**bold**",
//! "`code`") formats as it is typed. Text is measured with the platform's
//! text layout, so that it wraps where it is drawn.
//!
//! Run it with `zig build run-rich-text`.
const std = @import("std");
const z = @import("ziggurat");
const view = @import("ziggurat_view");
const system = @import("ziggurat_system");
const rt = @import("ziggurat_rich_text");
const rich = @import("ziggurat_rich_text_editor");
const clipboard = @import("ziggurat_rich_text_clipboard");
const measure = @import("ziggurat_text_measure");

const sample =
    \\# Notes
    \\
    \\Select text and use the toolbar, or **Ctrl+B**, _Ctrl+I_ and `Ctrl+Shift+E`.
    \\
    \\- Lists continue on Enter
    \\- Tab indents, Shift+Tab outdents
    \\
    \\1. Numbered items count themselves
    \\2. A [link](https://ziglang.org) opens on click
    \\
    \\- [ ] Tasks toggle when clicked
    \\- [x] Undo with Ctrl+Z
    \\
;

const Tool = struct { label: []const u8, command: rich.Command };
const tools = [_]Tool{
    .{ .label = "B", .command = .bold },
    .{ .label = "I", .command = .italic },
    .{ .label = "U", .command = .underline },
    .{ .label = "S", .command = .strikethrough },
    .{ .label = "Code", .command = .code },
    .{ .label = "H1", .command = .{ .heading = 1 } },
    .{ .label = "H2", .command = .{ .heading = 2 } },
    .{ .label = "Bullets", .command = .bullets },
    .{ .label = "Numbers", .command = .numbers },
    .{ .label = "Tasks", .command = .tasks },
    .{ .label = "Undo", .command = .undo },
    .{ .label = "Redo", .command = .redo },
};

const Notes = struct {
    editor: *rich.Editor = undefined,
    doc: *rt.Document = undefined,
    status: [64]u8 = undefined,

    fn build(self: *Notes, v: *view.View) anyerror!void {
        try v.column(.{ .grow = 1, .self_align = .stretch, .gap = 8, .padding = .all(12) });
        try v.toolbar(.{ .gap = 4 });
        for (tools, 0..) |tool, index| {
            if (try v.button(tool.label, .{ .key = index + 1 })) _ = self.editor.runCommand(tool.command);
        }
        try v.end();
        try self.editor.emit(v, .{ .grow = 1, .self_align = .stretch, .key = 100 });
        try v.text(self.count(), .{ .key = 101 });
        try v.end();
    }

    /// The length of the text, for the status line.
    fn count(self: *Notes) []const u8 {
        const t = &self.doc.text;
        return std.fmt.bufPrint(&self.status, "{d} characters, {d} paragraphs", .{ t.len() -| (t.paragraphCount() - 1), t.paragraphCount() }) catch "";
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const app = try z.App.init(allocator);
    defer app.deinit();
    const native = try measure.Native.create(allocator, std.Thread.getCurrentId());
    defer native.destroy();

    // The state, Document, editor and Host stay at stable addresses while
    // the window shows them.
    var notes: Notes = .{};
    var storage: view.Storage(64, 2048) = .{};
    var host = view.Host.init(&notes, Notes.build, storage.buffers(), .{ .measurer = native.measurer() });
    var doc = rt.Document.init(allocator, try rt.parseMarkdown(allocator, sample));
    defer doc.deinit();
    var board: system.clipboard.Board = undefined;
    try board.init(app, .{});
    defer board.deinit();
    var system_clipboard = clipboard.SystemClipboard.init(allocator, &board);
    defer system_clipboard.deinit();
    var editor = rich.Editor.init(&host, allocator, &doc, .{
        .measurer = native.measurer(),
        .placeholder = "Write something",
        .clipboard = system_clipboard.clipboard(),
        .font = .{ .size = 15 },
    });
    defer editor.deinit();
    notes.editor = &editor;
    notes.doc = &doc;

    const window = try app.createWindow(.{ .title = "Rich Text", .width = 900, .height = 560, .min_width = 360, .min_height = 280 });
    try host.attach(window);
    try host.context.prepareTextFields(allocator, .{});
    window.show();
    try app.run();
    system_clipboard.cancel();
    editor.detach();
}

test "the toolbar formats the selection and the status counts the text" {
    var doc = try rt.Document.initString(std.testing.allocator, "one two");
    defer doc.deinit();
    var editor = rich.Editor.init(undefined, std.testing.allocator, &doc, .{});
    defer editor.deinit();
    editor.bounds = .{ .x = 0, .y = 0, .width = 400, .height = 200 };
    try editor.layoutNow();
    doc.setSelection(0, 3);
    try std.testing.expect(editor.runCommand(.bold));
    try std.testing.expect(doc.text.attributesAt(0).weight >= 700);
    var notes: Notes = .{ .editor = &editor, .doc = &doc };
    try std.testing.expectEqualStrings("7 characters, 1 paragraphs", notes.count());
}
