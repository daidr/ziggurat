//! System clipboard: write, read, lazy offers and change notifications.
//!
//! A `ziggurat_system.clipboard.Board` connects the App to the system
//! clipboard. The buttons write the text field's content as plain text, as
//! text plus HTML, or this program's path as a file list, or *offer* text
//! that is rendered only when another program pastes it. Every clipboard
//! owner change (from this or any other program) triggers `on_changed`; the
//! example then asks which formats are available and reads the text and file
//! list asynchronously into fixed buffers. "Paste into field" copies the last
//! read text into the editable field.
//!
//! Run with `zig build run-clipboard`.
const std = @import("std");
const z = @import("ziggurat");
const d = @import("ziggurat_document");
const t = @import("ziggurat_text_layout");
const editing = @import("ziggurat_document_editor");
const view = @import("ziggurat_view");
const text = @import("ziggurat_view_text");
const clipboard = @import("ziggurat_system").clipboard;

const Clip = struct {
    window: ?z.Window = null,
    board: clipboard.Board = undefined,
    document: ?*d.Document = null,
    editor: ?*editing.Field = null,
    field: ?*text.TextField = null,

    // One request slot per concurrent query; each stays put while pending.
    formats_request: clipboard.Request = .{},
    text_request: clipboard.Request = .{},
    files_request: clipboard.Request = .{},
    available: clipboard.Available = .{},
    text_buffer: [4096]u8 = undefined,
    text_len: usize = 0,
    text_note: []const u8 = "",
    files_buffer: [4096]u8 = undefined,
    files_len: usize = 0,
    changes: usize = 0,
    lazy_renders: usize = 0,
    /// Scratch for outgoing data; write() and Sink.set() copy it.
    out: [8192]u8 = undefined,
    status: [128]u8 = undefined,
    status_len: usize = 0,

    fn say(self: *Clip, comptime format: []const u8, args: anytype) void {
        self.status_len = (std.fmt.bufPrint(&self.status, format, args) catch &self.status).len;
        if (self.window) |window| window.invalidate();
    }

    /// The text field's current content, read into `out`.
    fn fieldText(self: *Clip) []const u8 {
        const document = self.document orelse return "Hello from Ziggurat";
        const length = document.byteLength() catch return "";
        const count = document.read(.{ .start = 0, .end = @min(length, self.out.len / 2) }, self.out[0 .. self.out.len / 2]) catch return "";
        return self.out[0..count];
    }

    fn copyText(self: *Clip) void {
        const value = self.fieldText();
        if (value.len == 0) return self.say("Type something to copy first.", .{});
        self.board.write(&.{.{ .format = .{ .kind = .text }, .data = value }}) catch |err| return self.say("Copy failed: {s}", .{@errorName(err)});
        self.say("Copied {d} bytes of text.", .{value.len});
    }
    fn copyHtml(self: *Clip) void {
        const value = self.fieldText();
        if (value.len == 0) return self.say("Type something to copy first.", .{});
        // Text and HTML in one transaction; rich editors paste the HTML.
        var html: std.Io.Writer = .fixed(self.out[value.len..]);
        html.writeAll("<p><b>") catch {};
        for (value) |byte| switch (byte) {
            '<' => html.writeAll("&lt;") catch {},
            '>' => html.writeAll("&gt;") catch {},
            '&' => html.writeAll("&amp;") catch {},
            else => html.writeByte(byte) catch {},
        };
        html.writeAll("</b></p>") catch return self.say("Text is too long for the HTML buffer.", .{});
        self.board.write(&.{
            .{ .format = .{ .kind = .text }, .data = value },
            .{ .format = .{ .kind = .html }, .data = html.buffered() },
        }) catch |err| return self.say("Copy failed: {s}", .{@errorName(err)});
        self.say("Copied text and {d} bytes of HTML.", .{html.buffered().len});
    }
    fn copyPath(self: *Clip) void {
        const path = std.fs.selfExePath(&self.out) catch |err| return self.say("No executable path: {s}", .{@errorName(err)});
        self.board.write(&.{.{ .format = .{ .kind = .files }, .data = path }}) catch |err| return self.say("Copy failed: {s}", .{@errorName(err)});
        self.say("Copied this program as a file; paste it in a file manager.", .{});
    }
    /// Announce text now and render it only when a reader asks for it.
    fn offerLazily(self: *Clip) void {
        self.board.offer(.{ .context = self, .render = render, .released = released }, &.{.{ .kind = .text }}) catch |err| return self.say("Offer failed: {s}", .{@errorName(err)});
        self.say("Offered text; it is rendered when something pastes it.", .{});
    }
    fn render(ptr: *anyopaque, format: clipboard.Format, sink: *clipboard.Sink) anyerror!void {
        const self: *Clip = @ptrCast(@alignCast(ptr));
        if (format.kind != .text) return;
        self.lazy_renders += 1;
        var buffer: [96]u8 = undefined;
        try sink.set(try std.fmt.bufPrint(&buffer, "Rendered on demand (render #{d})", .{self.lazy_renders}));
        if (self.window) |window| window.invalidate();
    }
    fn released(ptr: *anyopaque) void {
        const self: *Clip = @ptrCast(@alignCast(ptr));
        self.say("Lazy offer ended after {d} render(s).", .{self.lazy_renders});
    }

    fn pasteIntoField(self: *Clip) void {
        const editor = self.editor orelse return;
        if (self.text_len == 0) return self.say("The clipboard has no text to paste.", .{});
        _ = editor.setValue(self.text_buffer[0..self.text_len]) catch |err| return self.say("Paste failed: {s}", .{@errorName(err)});
        if (self.window) |window| window.invalidate();
    }

    /// Any owner change: ask again which formats exist. Notifications carry
    /// no content, and a query already in flight will see the new owner.
    fn changed(ptr: *anyopaque) void {
        const self: *Clip = @ptrCast(@alignCast(ptr));
        self.changes += 1;
        self.refresh();
    }
    fn refresh(self: *Clip) void {
        if (self.formats_request.pending()) return;
        self.board.formats(&self.formats_request, self, onFormats) catch |err| self.say("Query failed: {s}", .{@errorName(err)});
    }
    fn onFormats(ptr: *anyopaque, result: clipboard.Result) void {
        const self: *Clip = @ptrCast(@alignCast(ptr));
        self.available = if (result == .formats) result.formats else .{};
        self.text_len = 0;
        self.files_len = 0;
        self.text_note = if (self.available.text) "reading..." else "";
        self.text_request.cancel();
        self.files_request.cancel();
        if (self.available.text) self.board.read(&self.text_request, .{ .kind = .text }, &self.text_buffer, self, onText, .{}) catch |err| self.say("Read failed: {s}", .{@errorName(err)});
        if (self.available.files) self.board.read(&self.files_request, .{ .kind = .files }, &self.files_buffer, self, onFiles, .{}) catch |err| self.say("Read failed: {s}", .{@errorName(err)});
        if (self.window) |window| window.invalidate();
    }
    fn onText(ptr: *anyopaque, result: clipboard.Result) void {
        const self: *Clip = @ptrCast(@alignCast(ptr));
        self.text_note = "";
        switch (result) {
            .data => |bytes| self.text_len = bytes.len,
            .capacity_exceeded => self.text_note = "(too large to preview)",
            .unavailable => self.text_note = "(no longer available)",
            .failed => |failure| self.text_note = @errorName(failure.err),
            .formats => {},
        }
        if (self.window) |window| window.invalidate();
    }
    fn onFiles(ptr: *anyopaque, result: clipboard.Result) void {
        const self: *Clip = @ptrCast(@alignCast(ptr));
        self.files_len = if (result == .data) result.data.len else 0;
        if (self.window) |window| window.invalidate();
    }

    fn build(self: *Clip, v: *view.View) anyerror!void {
        try v.text("Clipboard", .{ .font = view.Font.heading3 });
        try v.row(.{ .gap = 8, .self_align = .stretch, .alignment = .center });
        if (self.field) |field| try v.embed(field.embed(), .{ .grow = 1, .key = 1 });
        try v.end();
        try v.row(.{ .gap = 8 });
        if (try v.button("Copy text", .{})) self.copyText();
        if (try v.button("Copy as HTML", .{})) self.copyHtml();
        if (try v.button("Copy file", .{})) self.copyPath();
        if (try v.button("Offer lazily", .{})) self.offerLazily();
        try v.end();
        try v.row(.{ .gap = 8 });
        if (try v.button("Paste into field", .{ .enabled = self.text_len > 0 })) self.pasteIntoField();
        if (try v.button("Refresh", .{})) self.refresh();
        try v.end();
        if (self.status_len > 0) try v.text(self.status[0..self.status_len], .{ .color = 0x276aa5 });

        try v.column(.{ .self_align = .stretch, .grow = 1, .background = 0xeef1f4, .padding = view.Insets.all(12), .gap = 6, .clip = true });
        try v.row(.{ .gap = 6, .alignment = .center });
        try v.textf("Current clipboard (changes seen: {d})", .{self.changes}, .{ .color = 0x536475 });
        inline for (.{ "text", "html", "png", "files" }) |name| {
            if (@field(self.available, name)) try v.badge(name, .{});
        }
        try v.end();
        if (self.text_len > 0) {
            try v.text(firstLine(self.text_buffer[0..self.text_len], 120), .{ .font = view.Font.code });
            try v.textf("{d} bytes of text", .{self.text_len}, .{ .color = 0x536475 });
        } else if (self.text_note.len > 0) try v.text(self.text_note, .{ .color = 0x536475 });
        var paths = clipboard.paths(self.files_buffer[0..self.files_len]);
        var index: u64 = 0;
        while (paths.next()) |path| : (index += 1) {
            if (index == 4) {
                try v.text("...", .{});
                break;
            }
            try v.text(path, .{ .key = 100 + index });
        }
        if (!self.available.text and !self.available.files and !self.available.html and !self.available.png) try v.text("Empty, or only formats this example does not show.", .{ .color = 0x536475 });
        try v.end();
    }
};

/// A short single-line preview that never splits a UTF-8 sequence.
fn firstLine(bytes: []const u8, limit: usize) []const u8 {
    var end = std.mem.indexOfAny(u8, bytes, "\r\n") orelse bytes.len;
    if (end > limit) {
        end = limit;
        while (end > 0 and bytes[end] & 0xc0 == 0x80) end -= 1;
    }
    return bytes[0..end];
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const app = try z.App.init(allocator);
    defer app.deinit();

    var clip: Clip = .{};
    try clip.board.init(app, .{ .context = &clip, .on_changed = Clip.changed });
    defer clip.board.deinit();

    // The editable field: Engine and Document are owned here, the editor
    // Field adapts them, and TextField places it in the view.
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch {};
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "Hello from Ziggurat", .{});
    defer document.close() catch {};
    clip.document = document;

    var storage: view.Storage(64, 4096) = .{};
    var host = view.Host.init(&clip, Clip.build, storage.buffers(), .{});
    const window = try app.createWindow(.{ .title = "Ziggurat / Clipboard", .width = 680, .height = 460 });
    clip.window = window;
    try host.attach(window);
    try host.context.prepareTextFields(allocator, .{});

    const editor = try editing.Field.create(allocator, document, engine, .{});
    var field = text.TextField.init(editor, &host, .{ .font = .{ .size = 16 }, .scale = (try window.contentSize()).scale }, .{ .name = "Text to copy" });
    clip.editor = editor;
    clip.field = &field;

    clip.refresh();
    window.show();
    app.run() catch |err| std.log.err("run: {s}", .{@errorName(err)});

    // Stop deferred field work, then close the editor before its Document.
    field.detach();
    clip.field = null;
    clip.editor = null;
    try editor.close();
}

test "preview keeps whole characters" {
    try std.testing.expectEqualStrings("ab", firstLine("ab\ncd", 10));
    try std.testing.expectEqualStrings("a", firstLine("a\xc3\xa9", 2));
}

test "view without a board lists empty clipboard" {
    var clip: Clip = .{};
    var storage: view.Storage(64, 4096) = .{};
    var h = view.Harness.init(&clip, Clip.build, storage.buffers(), .{});
    try h.render();
    _ = try h.find(.{ .text = "Empty, or only formats this example does not show." });
}
