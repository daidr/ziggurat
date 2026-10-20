//! A small Zig source editor.
//!
//! The text area is a multi-line `ziggurat_document_editor.Field` over one
//! Document, embedded in a declarative view, so typing, IME, selection, undo
//! and scrolling come from the native text path. On top of it the example
//! adds: token highlighting through versioned range markers, a line-number
//! gutter positioned from the prepared layout, find and replace, a status bar
//! with the caret's line and column, and Open/Save through the native menu
//! bar and asynchronous file pickers. File reads and writes run on a thread
//! the example owns; results come back with `App.post`. Closing with unsaved
//! changes asks first.
//!
//! Run with `zig build run-code-editor`, optionally `-- path/to/file.zig`.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const text = @import("ziggurat_view_text");
const d = @import("ziggurat_document");
const t = @import("ziggurat_text_layout");
const editing = @import("ziggurat_document_editor");
const system = @import("ziggurat_system");

/// The Field shows and exports at most this many bytes.
const max_file = 16 * 1024;
const mono = if (builtin.os.tag == .windows) "Consolas" else "monospace";
const sample =
    \\//! Edit me, or open a file with Ctrl+O.
    \\const std = @import("std");
    \\
    \\pub fn main() void {
    \\    const greeting = "Hello, editor";
    \\    var total: u32 = 0;
    \\    for (0..10) |i| total += @intCast(i);
    \\    std.debug.print("{s}: {d}\n", .{ greeting, total });
    \\}
    \\
;
const Menu = enum(u64) { file = 1, open, save, save_as, quit, edit, find, find_next };

/// A Document, its Field and the view leaf that shows it.
const Box = struct {
    document: *d.Document,
    field: *editing.Field,
    box: text.TextField,

    fn open(self: *Box, allocator: std.mem.Allocator, engine: *t.Engine, host: *view.Host, initial: []const u8, parameters: editing.Parameters, field: editing.FieldOptions, options: text.Options) !void {
        const document = try d.Document.create(allocator, std.Thread.getCurrentId(), initial, .{});
        errdefer document.close() catch {};
        const editor = try editing.Field.create(allocator, document, engine, field);
        self.* = .{ .document = document, .field = editor, .box = text.TextField.init(editor, host, parameters, options) };
    }
    fn close(self: *Box) void {
        self.box.detach();
        self.field.close() catch |err| std.log.err("field close: {s}", .{@errorName(err)});
        self.document.close() catch |err| std.log.err("document close: {s}", .{@errorName(err)});
    }
    fn value(self: *Box, buffer: []u8) []const u8 {
        const length = self.document.byteLength() catch return "";
        const count = self.document.read(.{ .start = 0, .end = @min(length, buffer.len) }, buffer) catch return "";
        return buffer[0..count];
    }
};

const Editor = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    window: ?z.Window = null,
    host: view.Host = undefined,
    owner: system.Owner = undefined,
    code: Box = undefined,
    find: Box = undefined,
    replace: Box = undefined,
    path: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    saved_version: u64 = 0,
    discard: bool = false,
    status: [256]u8 = undefined,
    status_len: usize = 0,
    /// Scratch for whole-document passes on the main thread.
    scratch: [max_file]u8 = undefined,
    markers: [2048]editing.RangeMarker = undefined,
    highlight_queued: bool = false,
    highlighted: bool = false,
    picker_path: [std.fs.max_path_bytes]u8 = undefined,
    /// One load or save at a time, on a thread this example owns.
    io: ?std.Thread = null,
    io_save: bool = false,
    io_path: [std.fs.max_path_bytes]u8 = undefined,
    io_path_len: usize = 0,
    io_bytes: [max_file]u8 = undefined,
    io_len: usize = 0,
    io_version: u64 = 0,
    io_error: ?anyerror = null,
    load_waiting: bool = false,

    fn say(self: *Editor, comptime format: []const u8, arguments: anytype) void {
        self.status_len = (std.fmt.bufPrint(&self.status, format, arguments) catch self.status[0..0]).len;
        if (self.window) |window| window.invalidate();
    }
    fn dirty(self: *Editor) bool {
        return (self.code.document.committedTextVersion() catch self.saved_version) != self.saved_version;
    }
    fn fileName(self: *const Editor) []const u8 {
        return if (self.path_len == 0) "Untitled" else std.fs.path.basename(self.path[0..self.path_len]);
    }
    fn retitle(self: *Editor) void {
        var buffer: [320]u8 = undefined;
        const title = std.fmt.bufPrint(&buffer, "{s}{s} \u{2014} Code editor", .{ self.fileName(), if (self.dirty()) " \u{2022}" else "" }) catch return;
        if (self.window) |window| window.setTitle(title) catch {};
    }

    fn build(self: *Editor, v: *view.View) anyerror!void {
        if (!self.highlighted and self.code.box.attached) {
            self.highlighted = true;
            self.queueHighlight();
        }
        if (self.load_waiting and self.code.box.attached) {
            self.load_waiting = false;
            self.app.post(.{ .context = self, .call = ioDone }) catch {};
        }
        try v.toolbar(.{ .name = "Editor tools", .gap = 8, .alignment = .center, .self_align = .stretch });
        if (try v.button("Open\u{2026}", .{ .enabled = self.io == null })) self.openFile();
        if (try v.button("Save", .{ .enabled = self.io == null })) self.save(false);
        try v.embed(self.find.box.embed(), .{ .grow = 1, .key = 1 });
        if (try v.button("Find next", .{})) self.findNext();
        try v.embed(self.replace.box.embed(), .{ .grow = 1, .key = 2 });
        if (try v.button("Replace", .{})) self.replaceOne();
        if (try v.button("All", .{})) self.replaceAll();
        try v.end();

        try v.row(.{ .grow = 1, .self_align = .stretch, .key = 3 });
        try v.embed(.{ .context = self, .measure = gutterMeasure, .paint = gutterPaint }, .{ .self_align = .stretch });
        try v.embed(self.code.box.embed(), .{ .grow = 1, .self_align = .stretch, .key = 4 });
        try v.end();

        // Status bar: caret position from the Document's primary selection.
        const caret = (self.code.document.selection() catch d.Selection{}).caret;
        const line = self.code.document.lineAt(caret) catch 0;
        const start = (self.code.document.line(line) catch d.Range{ .start = caret, .end = caret }).start;
        var prefix: [1024]u8 = undefined;
        const count = self.code.document.read(.{ .start = start, .end = @min(caret, start + prefix.len) }, &prefix) catch 0;
        const column = (std.unicode.utf8CountCodepoints(prefix[0..count]) catch count) + 1;
        try v.row(.{ .gap = 16, .self_align = .stretch, .alignment = .center, .key = 5 });
        try v.textf("Ln {d}, Col {d}", .{ line + 1, column }, .{});
        try v.textf("{d} lines", .{self.code.document.lineCount() catch 0}, .{ .color = 0x536475 });
        try v.textf("{s}{s}", .{ self.fileName(), if (self.dirty()) " (modified)" else "" }, .{ .color = 0x536475 });
        try v.text(self.status[0..self.status_len], .{ .grow = 1, .color = 0x536475 });
        try v.end();
    }

    // Gutter: one number per visible paragraph, at the position the editor's
    // prepared layout reports. Paint reads cached geometry only.
    fn gutterMeasure(_: *anyopaque, _: ui.Theme) view.layout.Measurement {
        return .{ .minimum = .{ .width = 44, .height = 0 }, .preferred = .{ .width = 44, .height = 0 } };
    }
    fn gutterPaint(ptr: *anyopaque, frame: *ui.Frame, _: u64, bounds: view.Rect) anyerror!void {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        if (!self.code.box.attached) return;
        const adapter = self.code.field.adapter;
        const document = self.code.document;
        const revision = document.version() catch return;
        const first = (adapter.viewportAnchor() catch return).line;
        const lines = document.lineCount() catch return;
        try frame.pushClip(bounds);
        defer frame.popClip() catch {};
        var line = first;
        while (line < lines) : (line += 1) {
            const start = (document.line(line) catch break).start;
            const rect = (adapter.positionRect(revision, start, .downstream) catch break) orelse break;
            if (rect.y > bounds.y + bounds.height) break;
            var digits: [16]u8 = undefined;
            const label = std.fmt.bufPrint(&digits, "{d}", .{line + 1}) catch break;
            const width = 8 * @as(f32, @floatFromInt(label.len));
            frame.labelFont(.{ .x = bounds.x + bounds.width - width - 10, .y = rect.y, .width = width + 4, .height = rect.height }, label, 0x8a96a3, view.Font.code);
        }
    }

    // Highlighting runs after input returns: it reads the committed text,
    // installs range markers for that text version and re-prepares the field.
    fn queueHighlight(self: *Editor) void {
        if (self.highlight_queued) return;
        self.app.post(.{ .context = self, .call = highlight }) catch return;
        self.highlight_queued = true;
    }
    fn highlight(ptr: *anyopaque) void {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        self.highlight_queued = false;
        const version = self.code.document.committedTextVersion() catch return;
        const source = self.code.value(&self.scratch);
        var count = lex(source, &self.markers);
        var query_buffer: [256]u8 = undefined;
        const query = self.find.value(&query_buffer);
        if (query.len > 0) {
            var at: usize = 0;
            while (count < self.markers.len) {
                const found = std.mem.indexOfPos(u8, source, at, query) orelse break;
                self.markers[count] = .{ .range = .{ .start = found, .end = found + query.len }, .kind = .underline, .color = 0xd08a00, .thickness = 2 };
                count += 1;
                at = found + query.len;
            }
        }
        std.mem.sort(editing.RangeMarker, self.markers[0..count], {}, struct {
            fn less(_: void, a: editing.RangeMarker, b: editing.RangeMarker) bool {
                return a.range.start < b.range.start;
            }
        }.less);
        // A composition in progress or a newer edit retries on the next change.
        _ = self.code.field.adapter.setRangeMarkers(version, self.markers[0..count]) catch return;
        self.code.field.prepare(self.code.field.bounds, self.code.field.parameters) catch return;
        if (self.window) |window| window.invalidate();
    }
    fn codeChanged(context: ?*anyopaque, _: z.Window, _: u64) void {
        const self: *Editor = @ptrCast(@alignCast(context.?));
        self.queueHighlight();
        self.retitle();
    }

    fn queryChanged(context: ?*anyopaque, _: z.Window, _: u64) void {
        const self: *Editor = @ptrCast(@alignCast(context.?));
        self.queueHighlight();
    }

    fn findNext(self: *Editor) void {
        var query_buffer: [256]u8 = undefined;
        const query = self.find.value(&query_buffer);
        if (query.len == 0) return self.say("Type something to find.", .{});
        const source = self.code.value(&self.scratch);
        const after = (self.code.document.selection() catch d.Selection{}).range().end;
        const found = std.mem.indexOfPos(u8, source, @min(after, source.len), query) orelse std.mem.indexOf(u8, source, query) orelse
            return self.say("\u{201c}{s}\u{201d} not found.", .{query});
        self.selectBytes(source, found, found + query.len);
        self.say("Found at line {d}.", .{(self.code.document.lineAt(found) catch 0) + 1});
    }
    /// Enter in the find box moves to the next match.
    fn findSubmitted(context: ?*anyopaque, _: z.Window) void {
        const self: *Editor = @ptrCast(@alignCast(context.?));
        self.findNext();
    }
    /// Field selection takes UTF-16 positions.
    fn selectBytes(self: *Editor, source: []const u8, start: usize, end: usize) void {
        const start16 = std.unicode.calcUtf16LeLen(source[0..start]) catch return;
        const end16 = start16 + (std.unicode.calcUtf16LeLen(source[start..end]) catch return);
        _ = self.code.field.select(start16, end16) catch |err| self.say("Select failed: {s}", .{@errorName(err)});
    }
    fn replaceOne(self: *Editor) void {
        var query_buffer: [256]u8 = undefined;
        var with_buffer: [256]u8 = undefined;
        const query = self.find.value(&query_buffer);
        const with = self.replace.value(&with_buffer);
        const source = self.code.value(&self.scratch);
        const selected = (self.code.document.selection() catch d.Selection{}).range();
        if (query.len == 0 or !std.mem.eql(u8, source[@min(selected.start, source.len)..@min(selected.end, source.len)], query)) return self.findNext();
        var result: [max_file]u8 = undefined;
        const joined = std.fmt.bufPrint(&result, "{s}{s}{s}", .{ source[0..selected.start], with, source[selected.end..] }) catch return self.say("The file would exceed {d} bytes.", .{max_file});
        _ = self.code.field.setValue(joined) catch |err| return self.say("Replace failed: {s}", .{@errorName(err)});
        self.selectBytes(joined, selected.start, selected.start + with.len);
        self.findNext();
    }
    fn replaceAll(self: *Editor) void {
        var query_buffer: [256]u8 = undefined;
        var with_buffer: [256]u8 = undefined;
        const query = self.find.value(&query_buffer);
        const with = self.replace.value(&with_buffer);
        if (query.len == 0) return self.say("Type something to find.", .{});
        const source = self.code.value(&self.scratch);
        var result: [max_file]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&result);
        var replaced: usize = 0;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, source, at, query)) |found| : (replaced += 1) {
            writer.print("{s}{s}", .{ source[at..found], with }) catch return self.say("The file would exceed {d} bytes.", .{max_file});
            at = found + query.len;
        }
        writer.writeAll(source[at..]) catch return self.say("The file would exceed {d} bytes.", .{max_file});
        if (replaced == 0) return self.say("\u{201c}{s}\u{201d} not found.", .{query});
        // One setValue is one undo step for the whole replacement.
        _ = self.code.field.setValue(writer.buffered()) catch |err| return self.say("Replace failed: {s}", .{@errorName(err)});
        self.say("Replaced {d} occurrence{s}.", .{ replaced, if (replaced == 1) "" else "s" });
    }

    // Files: pickers are asynchronous; reading and writing run on `io`.
    fn openFile(self: *Editor) void {
        self.owner.openFile(.{ .extensions = &.{ ".zig", ".zon", ".txt", ".md", "*" } }, &self.picker_path, self, picked) catch |err| self.say("Open failed: {s}", .{@errorName(err)});
    }
    fn save(self: *Editor, choose: bool) void {
        if (choose or self.path_len == 0) {
            self.owner.saveFile(.{ .extensions = &.{ ".zig", ".txt" }, .suggested_name = self.fileName() }, &self.picker_path, self, pickedSave) catch |err| self.say("Save failed: {s}", .{@errorName(err)});
            return;
        }
        self.startIo(true, self.path[0..self.path_len]);
    }
    fn picked(ptr: *anyopaque, _: z.Window, result: system.picker.Result) void {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        if (result == .selected) self.startIo(false, result.selected);
    }
    fn pickedSave(ptr: *anyopaque, _: z.Window, result: system.picker.Result) void {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        if (result == .selected) self.startIo(true, result.selected);
    }
    fn startIo(self: *Editor, saving: bool, path: []const u8) void {
        if (self.io != null) return self.say("Busy with another file.", .{});
        if (path.len > self.io_path.len) return self.say("The path is too long.", .{});
        @memcpy(self.io_path[0..path.len], path);
        self.io_path_len = path.len;
        self.io_save = saving;
        self.io_error = null;
        if (saving) {
            self.io_version = self.code.document.committedTextVersion() catch 0;
            self.io_len = self.code.value(&self.io_bytes).len;
        }
        self.io = std.Thread.spawn(.{}, runIo, .{self}) catch |err| return self.say("Could not start: {s}", .{@errorName(err)});
        self.say("{s} {s}\u{2026}", .{ if (saving) "Saving" else "Opening", std.fs.path.basename(path) });
    }
    /// The worker touches only the io_* fields; the post is its last action.
    fn runIo(self: *Editor) void {
        const path = self.io_path[0..self.io_path_len];
        if (self.io_save) {
            std.fs.cwd().writeFile(.{ .sub_path = path, .data = self.io_bytes[0..self.io_len] }) catch |err| {
                self.io_error = err;
            };
        } else if (std.fs.cwd().openFile(path, .{})) |file| {
            defer file.close();
            self.io_len = file.readAll(&self.io_bytes) catch |err| blk: {
                self.io_error = err;
                break :blk 0;
            };
            if (self.io_error == null and self.io_len == self.io_bytes.len) self.io_error = error.FileTooBig;
            if (self.io_error == null and !std.unicode.utf8ValidateSlice(self.io_bytes[0..self.io_len])) self.io_error = error.InvalidUtf8;
        } else |err| self.io_error = err;
        // Closed means the app is stopping; main() joins this thread.
        self.app.post(.{ .context = self, .call = ioDone }) catch {};
    }
    fn ioDone(ptr: *anyopaque) void {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        if (self.io) |thread| thread.join();
        self.io = null;
        const name = std.fs.path.basename(self.io_path[0..self.io_path_len]);
        if (self.io_error) |err| return self.say("{s}: {s}", .{ name, @errorName(err) });
        if (!self.io_save) {
            // The field attaches after its first paint; build posts this again.
            if (!self.code.box.attached) {
                self.load_waiting = true;
                return;
            }
            _ = self.code.field.setValue(self.io_bytes[0..self.io_len]) catch |err| return self.say("{s}: {s}", .{ name, @errorName(err) });
        }
        @memcpy(self.path[0..self.io_path_len], self.io_path[0..self.io_path_len]);
        self.path_len = self.io_path_len;
        self.saved_version = if (self.io_save) self.io_version else self.code.document.committedTextVersion() catch 0;
        self.say("{s} {s}.", .{ if (self.io_save) "Saved" else "Opened", name });
        self.retitle();
    }

    fn onSystem(ptr: *anyopaque, window: z.Window, action: system.Action) void {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        switch (action) {
            .menu => |id| switch (@as(Menu, @enumFromInt(id))) {
                .open => self.openFile(),
                .save => self.save(false),
                .save_as => self.save(true),
                .quit => _ = self.app.requestQuit(),
                .find => self.find.field.focus() catch {},
                .find_next => self.findNext(),
                .file, .edit => {},
            },
            .message => |result| if (result.response == .button and result.response.button == 1) {
                self.discard = true;
                _ = window.requestClose() catch {};
            },
            else => {},
        }
    }
    /// Unsaved changes veto the close once and ask; Discard closes again.
    fn onClose(ptr: *anyopaque, _: z.Window, _: z.CloseReason) z.CloseDecision {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        if (self.discard or !self.dirty()) return .allow;
        self.owner.showMessage(1, .{
            .title = "Unsaved changes",
            .message = "Close without saving your changes?",
            .buttons = &.{ .{ .id = 1, .label = "Discard" }, .{ .id = 2, .label = "Cancel" } },
            .default_button = 1,
            .cancel_button = 1,
            .kind = .question,
        }) catch return .allow;
        return .cancel;
    }
};

/// Marks comments, strings, numbers, builtins and keywords of Zig source.
fn lex(source: []const u8, out: []editing.RangeMarker) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < source.len and count < out.len) {
        const c = source[i];
        const next: u8 = if (i + 1 < source.len) source[i + 1] else 0;
        var end = i + 1;
        const color: ?u32 = switch (c) {
            '/' => if (next == '/') blk: {
                end = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
                break :blk 0xeeeeee;
            } else null,
            '\\' => if (next == '\\') blk: {
                end = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
                break :blk 0xdff3d8;
            } else null,
            '"', '\'' => blk: {
                while (end < source.len and source[end] != c and source[end] != '\n') end += if (source[end] == '\\' and end + 1 < source.len and source[end + 1] != '\n') 2 else 1;
                if (end < source.len and source[end] == c) end += 1;
                break :blk 0xdff3d8;
            },
            '0'...'9' => blk: {
                while (end < source.len and (std.ascii.isAlphanumeric(source[end]) or source[end] == '_' or (source[end] == '.' and end + 1 < source.len and std.ascii.isDigit(source[end + 1])))) end += 1;
                break :blk 0xffecd2;
            },
            '@', 'a'...'z', 'A'...'Z', '_' => blk: {
                while (end < source.len and (std.ascii.isAlphanumeric(source[end]) or source[end] == '_')) end += 1;
                if (c == '@') break :blk if (end > i + 1) 0xf0e2ff else null;
                break :blk if (std.zig.Token.getKeyword(source[i..end]) != null) 0xdde8ff else null;
            },
            else => null,
        };
        if (color) |rgb| if (end > i) {
            out[count] = .{ .range = .{ .start = i, .end = end }, .color = rgb };
            count += 1;
        };
        i = end;
    }
    return count;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const app = try z.App.init(allocator);
    defer app.deinit();
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch |err| std.log.err("engine close: {s}", .{@errorName(err)});

    var editor: Editor = .{ .allocator = allocator, .app = app };
    var storage: view.Storage(64, 4096) = .{};
    editor.host = view.Host.init(&editor, Editor.build, storage.buffers(), .{ .root = .{ .padding = view.Insets.all(8), .gap = 8 } });
    editor.owner = system.Owner.init(&editor, Editor.onSystem);
    defer if (editor.io) |thread| thread.join();

    const window = try app.createWindow(.{ .title = "Code editor", .width = 900, .height = 640, .min_width = 520, .min_height = 360, .on_close = .{ .context = &editor, .request = Editor.onClose } });
    editor.window = window;
    try editor.host.attach(window);
    try editor.host.context.prepareTextFields(allocator, .{});
    try editor.owner.attach(window);
    try editor.owner.setMenu(&.{
        .{ .id = @intFromEnum(Menu.file), .kind = .submenu, .label = "&File" },
        .{ .id = @intFromEnum(Menu.open), .parent = 1, .label = "&Open\u{2026}", .accelerator = .{ .key = .o, .modifiers = .{ .control = true } } },
        .{ .id = @intFromEnum(Menu.save), .parent = 1, .label = "&Save", .accelerator = .{ .key = .s, .modifiers = .{ .control = true } } },
        .{ .id = @intFromEnum(Menu.save_as), .parent = 1, .label = "Save &As\u{2026}", .accelerator = .{ .key = .s, .modifiers = .{ .control = true, .shift = true } } },
        .{ .parent = 1, .kind = .separator },
        .{ .id = @intFromEnum(Menu.quit), .parent = 1, .label = "&Quit", .accelerator = .{ .key = .q, .modifiers = .{ .control = true } } },
        .{ .id = @intFromEnum(Menu.edit), .kind = .submenu, .label = "&Edit" },
        .{ .id = @intFromEnum(Menu.find), .parent = @intFromEnum(Menu.edit), .label = "&Find", .accelerator = .{ .key = .f, .modifiers = .{ .control = true } } },
        .{ .id = @intFromEnum(Menu.find_next), .parent = @intFromEnum(Menu.edit), .label = "Find &Next", .accelerator = .{ .key = .f3 } },
    });

    const scale = (try window.contentSize()).scale;
    const code_parameters: editing.Parameters = .{ .font = .{ .size = 14, .family = mono }, .scale = scale };
    try editor.code.open(allocator, engine, &editor.host, sample, code_parameters, .{ .multiline = true, .accept_tab = true, .value_bytes = max_file, .context = &editor, .changed = Editor.codeChanged }, .{ .name = "Source", .lines = 8, .width = 480 });
    defer editor.code.close();
    editor.saved_version = try editor.code.document.committedTextVersion();
    const box_parameters: editing.Parameters = .{ .font = .{ .size = 15 }, .scale = scale };
    const box_field: editing.FieldOptions = .{ .value_bytes = 256, .context = &editor, .changed = Editor.queryChanged, .submit = Editor.findSubmitted };
    try editor.find.open(allocator, engine, &editor.host, "", box_parameters, box_field, .{ .name = "Find", .width = 140 });
    defer editor.find.close();
    try editor.replace.open(allocator, engine, &editor.host, "", box_parameters, .{ .value_bytes = 256 }, .{ .name = "Replace with", .width = 140 });
    defer editor.replace.close();

    var arguments = try std.process.argsWithAllocator(allocator);
    defer arguments.deinit();
    _ = arguments.skip();
    if (arguments.next()) |path| {
        if (std.fs.cwd().realpathAlloc(allocator, path)) |absolute| {
            defer allocator.free(absolute);
            editor.startIo(false, absolute);
        } else |err| editor.say("{s}: {s}", .{ path, @errorName(err) });
    }

    editor.retitle();
    window.show();
    try app.run();
    editor.window = null;
}

test "lexer marks Zig tokens in order" {
    var markers: [16]editing.RangeMarker = undefined;
    const source = "const x = \"a\\\"b\"; // done\n@as(u8, 42)";
    const count = lex(source, &markers);
    const expected = [_][]const u8{ "const", "\"a\\\"b\"", "// done", "@as", "42" };
    try std.testing.expectEqual(expected.len, count);
    for (expected, markers[0..count]) |want, marker| try std.testing.expectEqualStrings(want, source[marker.range.start..marker.range.end]);
}
