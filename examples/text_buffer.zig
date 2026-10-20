//! A large editable document: 100,000 lines of mixed-script text in one
//! editor. The Document keeps its text in an indexed tree, and the
//! `ziggurat_document_editor.Adapter` lays out and draws only the rows near
//! the viewport, so opening, scrolling and typing do not shape the whole
//! text. The window's content is a `ui.Context` that hands input to the
//! Adapter and draws a status line read from the Document's index.
//!
//! Run it with `zig build run-text-buffer`.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const d = @import("ziggurat_document");
const t = @import("ziggurat_text_layout");
const editing = @import("ziggurat_document_editor");
const system = @import("ziggurat_system");

const lines = 100_000;
const line_format = "Line {d}: editable text, 😀, العربية, עברית\n";
const mono = if (builtin.os.tag == .windows) "Consolas" else "monospace";
const ink: u32 = 0x182430;
const muted: u32 = 0x5f6b7a;
const margin: f32 = 20;
/// Height of the heading and status line above the editor.
const header: f32 = 70;
const inset: f32 = 6;

const Menu = enum(u64) { edit = 1, undo, redo, select_all };

/// The generated text, in `allocator` memory the caller frees.
fn generate(allocator: std.mem.Allocator, count: usize) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    for (1..count + 1) |number| try output.writer.print(line_format, .{number});
    return output.toOwnedSlice();
}

/// The text area for a content size in DIP.
fn editorBounds(width: f32, height: f32) ui.Rect {
    const top = margin + header + inset;
    return .{ .x = margin + inset, .y = top, .width = @max(1, width - 2 * (margin + inset)), .height = @max(1, height - top - margin - inset) };
}

const Buffer = struct {
    window: z.Window = undefined,
    document: *d.Document,
    adapter: *editing.Adapter,
    context: ui.Context = undefined,
    owner: system.Owner = undefined,
    parameters: editing.Parameters,
    /// Bounds the Adapter was last prepared for, and the size paint saw.
    bounds: ui.Rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    wanted: ui.Rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    queued: bool = false,

    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Buffer = @ptrCast(@alignCast(ptr));
        const width = @as(f32, @floatFromInt(frame.size.width)) / frame.size.scale;
        const height = @as(f32, @floatFromInt(frame.size.height)) / frame.size.scale;
        frame.clear(0xffffff);
        frame.labelFont(.{ .x = margin, .y = margin, .width = width - 2 * margin, .height = 30 }, "Indexed text input", ink, .{ .size = 22, .weight = .bold });
        var status: [128]u8 = undefined;
        const line_count = self.document.lineCount() catch 0;
        const scalars = self.document.scalarLength() catch 0;
        const version = self.document.version() catch 0;
        frame.label(.{ .x = margin, .y = margin + 38, .width = width - 2 * margin, .height = 22 }, std.fmt.bufPrint(&status, "{d} lines · {d} characters · version {d}", .{ line_count, scalars, version }) catch "", muted);
        const box: ui.Rect = .{ .x = margin, .y = margin + header, .width = @max(1, width - 2 * margin), .height = @max(1, height - 2 * margin - header) };
        frame.roundedRect(box, 4, ui.Color.rgb(0xc9d1dc));
        frame.roundedRect(.{ .x = box.x + 1, .y = box.y + 1, .width = @max(0, box.width - 2), .height = @max(0, box.height - 2) }, 3, ui.Color.rgb(0xfcfcfd));
        // Preparing never runs inside paint: a new size is laid out by a
        // posted task, and this frame draws the last prepared rows.
        self.wanted = editorBounds(width, height);
        if (!std.meta.eql(self.wanted, self.bounds) and !self.queued) {
            self.queued = true;
            self.window.app.post(.{ .context = self, .call = resized }) catch {
                self.queued = false;
            };
        }
        self.adapter.draw(frame, self.bounds, .{}) catch |err| std.log.err("draw: {s}", .{@errorName(err)});
    }

    fn resized(ptr: *anyopaque) void {
        const self: *Buffer = @ptrCast(@alignCast(ptr));
        self.queued = false;
        self.bounds = self.wanted;
        self.parameters.font.width = self.bounds.width;
        self.refresh();
    }

    /// Lay out the rows near the viewport again and repaint.
    fn refresh(self: *Buffer) void {
        _ = self.adapter.prepare(self.bounds, self.parameters) catch |err| std.log.err("prepare: {s}", .{@errorName(err)});
        self.window.invalidate();
    }

    fn input(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *Buffer = @ptrCast(@alignCast(ptr));
        return self.adapter.handleEvent(self.window, event, self.bounds, self.parameters) catch |err| {
            std.log.err("input: {s}", .{@errorName(err)});
            return true;
        };
    }

    fn action(_: *anyopaque, _: u64) void {}

    fn onSystem(ptr: *anyopaque, _: z.Window, event: system.Action) void {
        const self: *Buffer = @ptrCast(@alignCast(ptr));
        switch (event) {
            .menu => |id| {
                switch (@as(Menu, @enumFromInt(id))) {
                    .undo => _ = self.adapter.undo() catch return,
                    .redo => _ = self.adapter.redo() catch return,
                    .select_all => _ = self.document.setSelection(.{ .anchor = 0, .caret = self.document.byteLength() catch return }) catch return,
                    .edit => return,
                }
                self.refresh();
            },
            else => {},
        }
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const app = try z.App.init(allocator);
    defer app.deinit();
    const thread = std.Thread.getCurrentId();
    const engine = try t.Engine.create(allocator, thread, .{});
    defer engine.close() catch |err| std.log.err("engine close: {s}", .{@errorName(err)});

    const source = try generate(allocator, lines);
    const document = d.Document.create(allocator, thread, source, .{}) catch |err| {
        allocator.free(source);
        return err;
    };
    allocator.free(source);
    defer document.close() catch |err| std.log.err("document close: {s}", .{@errorName(err)});
    const adapter = try editing.Adapter.create(allocator, document, engine, .{});
    defer adapter.close() catch |err| std.log.err("adapter close: {s}", .{@errorName(err)});

    // The Buffer holds the Context and Owner at stable addresses while the
    // window shows them.
    var buffer: Buffer = .{ .document = document, .adapter = adapter, .parameters = .{ .font = .{ .size = 14, .family = mono, .wrap = .word_character, .width = 1 } } };
    buffer.context = ui.Context.init(&buffer, Buffer.draw, Buffer.action);
    buffer.context.on_input = Buffer.input;
    buffer.owner = system.Owner.init(&buffer, Buffer.onSystem);

    const window = try app.createWindow(.{ .title = "Indexed text buffer", .width = 900, .height = 650, .min_width = 420, .min_height = 300 });
    buffer.window = window;
    const size = try window.contentSize();
    buffer.parameters.scale = size.scale;
    buffer.bounds = editorBounds(@as(f32, @floatFromInt(size.width)) / size.scale, @as(f32, @floatFromInt(size.height)) / size.scale);
    buffer.wanted = buffer.bounds;
    buffer.parameters.font.width = buffer.bounds.width;
    _ = try adapter.prepare(buffer.bounds, buffer.parameters);
    try buffer.context.attach(window);
    // Native text input and IME go to the Adapter from here on.
    try adapter.bind(window);
    defer adapter.unbind() catch {};
    try buffer.owner.attach(window);
    const control: system.Modifiers = .{ .control = true };
    try buffer.owner.setMenu(&.{
        .{ .id = @intFromEnum(Menu.edit), .kind = .submenu, .label = "&Edit" },
        .{ .id = @intFromEnum(Menu.undo), .parent = @intFromEnum(Menu.edit), .label = "&Undo", .accelerator = .{ .key = .z, .modifiers = control } },
        .{ .id = @intFromEnum(Menu.redo), .parent = @intFromEnum(Menu.edit), .label = "&Redo", .accelerator = .{ .key = .y, .modifiers = control } },
        .{ .parent = @intFromEnum(Menu.edit), .kind = .separator },
        .{ .id = @intFromEnum(Menu.select_all), .parent = @intFromEnum(Menu.edit), .label = "Select &All", .accelerator = .{ .key = .a, .modifiers = control } },
    });
    window.show();
    try app.run();
}

test "the generated document has one indexed line per row" {
    const allocator = std.testing.allocator;
    const source = try generate(allocator, 1000);
    defer allocator.free(source);
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), source, .{});
    defer document.close() catch unreachable;
    // The text ends with a newline, which opens one empty last line.
    try std.testing.expectEqual(@as(usize, 1001), try document.lineCount());
    var line: [128]u8 = undefined;
    const range = try document.line(499);
    try std.testing.expect(std.mem.startsWith(u8, line[0..try document.read(range, &line)], "Line 500: editable text, 😀"));
}
