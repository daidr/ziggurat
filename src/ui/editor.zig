const std = @import("std");
const z = @import("ziggurat");
const layout = @import("layout.zig");
const scrolling = @import("scroll.zig");
const editing = @import("text_buffer.zig");
pub const Rect = layout.Rect;
pub const Selection = editing.Selection;
pub const TextBuffer = editing.TextBuffer;
pub const TextBinding = @import("text_binding.zig").Binding;

pub const Clipboard = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, []const u8) anyerror!void,
    /// Return the initialized byte count in destination, or an explicit error.
    read: *const fn (*anyopaque, []u8) anyerror!usize,
};
pub const PaintCommand = union(enum) {
    text: struct { bounds: Rect, text: []const u8 },
    selection: Rect,
    composition: Rect,
    caret: Rect,
};
pub const Surface = struct {
    context: *anyopaque,
    line_height: f32,
    /// Width of a logical UTF-8 run. The fallback hit test assumes nondecreasing
    /// prefix widths; this surface does not provide bidi or shaped visual carets.
    measure: *const fn (*anyopaque, []const u8) anyerror!f32,
    paint: *const fn (*anyopaque, PaintCommand) anyerror!void,
};
pub const Options = struct {
    buffer: editing.Options = .{},
    multiline: bool = false,
    accept_tab: bool = false,
    autofocus: bool = false,
};

const Line = struct { start: usize, end: usize, row: usize };

/// Bounded logical-line editor. Rendering and clipboard are injected; no native
/// handles or timers are owned here. Call draw inside the caller's clip region.
/// Horizontal movement is scalar based, and vertical navigation uses logical
/// lines: grapheme clusters, bidi, soft wrapping and shaping require a richer
/// text surface. Direct edits to buffer require refresh() before display.
pub const Editor = struct {
    allocator: std.mem.Allocator,
    buffer: TextBuffer,
    display_storage: []u8,
    paste_storage: []u8,
    display_len: usize = 0,
    display_dirty: bool = true,
    /// Cache invalidation token; direct buffer edits still require refresh().
    display_revision: u64 = 0,
    reveal_caret: bool = true,
    multiline: bool,
    accept_tab: bool,
    focused: bool,
    window_active: bool = true,
    dragging: bool = false,
    preferred_x: ?f32 = null,
    scroll: scrolling.ScrollModel = .{},
    clipboard: ?Clipboard = null,
    /// Optional native cancellation hook. Invoked before pointer/navigation
    /// cancels preedit, so platform and virtual composition remain in agreement.
    composition_context: ?*anyopaque = null,
    cancel_native_composition: ?*const fn (*anyopaque) void = null,
    /// One retained native input owner. The pointer borrows its stable Binding
    /// through unbound; it is not another text, selection or undo authority.
    native_binding: ?*TextBinding = null,
    native_binding_busy: bool = false,

    pub fn init(allocator: std.mem.Allocator, options: Options, initial: []const u8) !Editor {
        if (std.mem.indexOfScalar(u8, initial, 0) != null) return error.EmbeddedNul;
        if (!options.multiline and std.mem.indexOfAny(u8, initial, "\r\n") != null) return error.MultilineTextInSingleLine;
        var buffer = try TextBuffer.init(allocator, options.buffer, initial);
        errdefer buffer.deinit();
        const display = try allocator.alloc(u8, options.buffer.max_bytes);
        errdefer allocator.free(display);
        const paste = try allocator.alloc(u8, options.buffer.max_bytes);
        return .{ .allocator = allocator, .buffer = buffer, .display_storage = display, .paste_storage = paste, .multiline = options.multiline, .accept_tab = options.accept_tab, .focused = options.autofocus };
    }
    pub fn deinit(self: *Editor) void {
        self.buffer.deinit();
        self.allocator.free(self.display_storage);
        self.allocator.free(self.paste_storage);
        self.* = undefined;
    }
    pub fn refresh(self: *Editor) void {
        self.display_dirty = true;
        self.display_revision +|= 1;
        self.reveal_caret = true;
        self.preferred_x = null;
    }
    fn edited(self: *Editor, changed: bool) bool {
        if (changed) self.refresh();
        return changed;
    }
    pub fn displayText(self: *Editor) []const u8 {
        if (self.display_dirty) {
            const text = self.buffer.text();
            if (self.buffer.composition()) |composition| {
                @memcpy(self.display_storage[0..composition.range.start], text[0..composition.range.start]);
                @memcpy(self.display_storage[composition.range.start..][0..composition.text.len], composition.text);
                const suffix = text[composition.range.end..];
                @memcpy(self.display_storage[composition.range.start + composition.text.len ..][0..suffix.len], suffix);
                self.display_len = composition.range.start + composition.text.len + suffix.len;
            } else {
                @memcpy(self.display_storage[0..text.len], text);
                self.display_len = text.len;
            }
            self.display_dirty = false;
        }
        return self.display_storage[0..self.display_len];
    }
    pub fn displaySelection(self: *const Editor) Selection {
        if (self.buffer.composition()) |composition| return .{
            .anchor = composition.range.start + composition.selection.anchor,
            .caret = composition.range.start + composition.selection.caret,
        };
        return self.buffer.selection();
    }
    pub fn cancelComposition(self: *Editor) bool {
        const active = self.buffer.composition() != null;
        if (!active) return false;
        // Clear virtual state before a native cancellation can synchronously
        // reenter the content callback with another cancellation notification.
        _ = self.buffer.cancelComposition();
        self.refresh();
        if (self.cancel_native_composition) |cancel| if (self.composition_context) |context| cancel(context);
        return true;
    }
    fn normalize(self: *Editor, text: []const u8) ![]const u8 {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, text, 0) != null) return error.EmbeddedNul;
        if (text.len > self.paste_storage.len) return error.CapacityExceeded;
        var count: usize = 0;
        var index: usize = 0;
        while (index < text.len) : (index += 1) {
            var byte = text[index];
            if (byte == '\r') {
                if (index + 1 < text.len and text[index + 1] == '\n') index += 1;
                byte = '\n';
            }
            if (byte == '\n' and !self.multiline) byte = ' ';
            if (byte == '\t' and !self.accept_tab) byte = ' ';
            self.paste_storage[count] = byte;
            count += 1;
        }
        return self.paste_storage[0..count];
    }
    /// Explicit native document replacement, with the same normalization and
    /// bounded history transaction as ordinary inserted text.
    pub fn replaceText(self: *Editor, range: editing.Range, text: []const u8) !bool {
        const normalized = try self.normalize(text);
        return self.edited(try self.buffer.replaceRange(range, normalized));
    }
    pub fn insertText(self: *Editor, text: []const u8) !bool {
        if (!self.multiline and (std.mem.eql(u8, text, "\n") or std.mem.eql(u8, text, "\r"))) return false;
        if (!self.accept_tab and std.mem.eql(u8, text, "\t")) return false;
        const normalized = try self.normalize(text);
        const changed = if (self.buffer.composition() != null) try self.buffer.commitComposition(normalized) else try self.buffer.replaceSelection(normalized);
        return self.edited(changed);
    }
    pub fn handleEvent(self: *Editor, event: z.Event, bounds: Rect, surface: Surface) !bool {
        switch (event) {
            .focus => |active| {
                const changed = self.window_active != active;
                self.window_active = active;
                if (!active) {
                    self.dragging = false;
                    return self.cancelComposition() or changed;
                }
                return changed;
            },
            .pointer_down => |pointer| {
                const point = pointer.position;
                if (!bounds.contains(point)) {
                    self.focused = false;
                    self.dragging = false;
                    _ = self.cancelComposition();
                    // Blur updates this editor, but the outside press still
                    // belongs to the next editor/button in the input route.
                    return false;
                }
                _ = self.cancelComposition();
                const offset = try self.hitTest(bounds, surface, .{ .x = point.x, .y = point.y });
                self.focused = true;
                self.dragging = true;
                self.preferred_x = null;
                _ = try self.buffer.setSelection(.{ .anchor = offset, .caret = offset });
                self.reveal_caret = true;
                return true;
            },
            .pointer_move, .pointer_up => {
                const point = if (event == .pointer_up) event.pointer_up.position else event.pointer_move;
                if (!self.dragging) return false;
                if (event == .pointer_up) self.dragging = false;
                const offset = try self.hitTest(bounds, surface, .{ .x = point.x, .y = point.y });
                const changed = try self.buffer.setSelection(.{ .anchor = self.buffer.selection().anchor, .caret = offset });
                self.reveal_caret = true;
                return changed;
            },
            .cancel_input => {
                self.dragging = false;
                return false;
            },
            .wheel => |wheel| return if (bounds.contains(wheel.position)) self.scroll.scrollBy(.{ .x = wheel.delta.x, .y = wheel.delta.y }) else false,
            else => {},
        }
        if (!self.focused or !self.window_active) return false;
        return switch (event) {
            .text_input => |input| self.insertText(input.text),
            .text_preedit => |preedit| blk: {
                if ((!self.multiline and std.mem.indexOfAny(u8, preedit.text, "\r\n") != null) or std.mem.indexOfScalar(u8, preedit.text, '\r') != null) return error.InvalidCompositionText;
                break :blk self.edited(try self.buffer.setComposition(preedit.text, .{ .anchor = preedit.selection_start, .caret = preedit.selection_end }));
            },
            .text_preedit_cancel => self.edited(self.buffer.cancelComposition()),
            .key_input => |input| blk: {
                if (input.modifiers.control or input.modifiers.alt or input.modifiers.super) break :blk false;
                switch (input.key) {
                    .space => {
                        _ = try self.insertText(" ");
                        break :blk true;
                    },
                    .enter => {
                        _ = try self.insertText("\n");
                        break :blk true;
                    },
                    .tab => {
                        if (input.modifiers.shift) {
                            self.focused = false;
                            _ = self.cancelComposition();
                            break :blk false;
                        }
                        if (self.multiline and self.accept_tab) {
                            _ = try self.insertText("\t");
                            break :blk true;
                        }
                        break :blk false;
                    },
                    else => break :blk false,
                }
            },
            .edit_key => |input| blk: {
                const supported = switch (input.key) {
                    .a, .c, .x, .v, .z, .y => input.control,
                    .left, .right, .up, .down, .home, .end, .backspace, .delete => true,
                };
                if (!supported) break :blk false;
                _ = try self.key(input, surface);
                break :blk true;
            },
            .key => |legacy| switch (legacy) {
                // Space/Enter also generate WM_CHAR. Consume the legacy button
                // activation while this field owns keyboard focus.
                .activate => true,
                .tab => tab: {
                    if (self.multiline and self.accept_tab) break :tab true;
                    self.focused = false;
                    _ = self.cancelComposition();
                    break :tab false;
                },
            },
            else => false,
        };
    }
    pub fn key(self: *Editor, input: z.EditKey, surface: Surface) !bool {
        const canceled = self.cancelComposition();
        self.reveal_caret = true;
        if (input.control) switch (input.key) {
            .a => return (try self.buffer.selectAll()) or canceled,
            .c, .x => {
                const text = self.buffer.selectedText();
                if (text.len == 0) return canceled;
                const clipboard = self.clipboard orelse return error.ClipboardUnavailable;
                try clipboard.write(clipboard.context, text);
                return if (input.key == .x) self.edited(try self.buffer.replaceSelection("")) or canceled else canceled;
            },
            .v => {
                const clipboard = self.clipboard orelse return error.ClipboardUnavailable;
                const count = try clipboard.read(clipboard.context, self.paste_storage);
                if (count > self.paste_storage.len) return error.InvalidClipboardLength;
                return (try self.insertText(self.paste_storage[0..count])) or canceled;
            },
            .z => return self.edited(if (input.shift) try self.buffer.redo() else try self.buffer.undo()) or canceled,
            .y => return self.edited(try self.buffer.redo()) or canceled,
            else => {},
        };
        switch (input.key) {
            .backspace => return self.edited(try self.buffer.deleteBackwardScalar()) or canceled,
            .delete => return self.edited(try self.buffer.deleteForwardScalar()) or canceled,
            .left, .right => {
                self.preferred_x = null;
                return (try self.buffer.moveScalar(if (input.key == .left) .backward else .forward, input.shift)) or canceled;
            },
            .home, .end => {
                self.preferred_x = null;
                const text = self.buffer.text();
                const line = lineAt(text, self.buffer.selection().caret);
                const offset = if (input.control) (if (input.key == .home) @as(usize, 0) else text.len) else (if (input.key == .home) line.start else line.end);
                return (try self.moveTo(offset, input.shift)) or canceled;
            },
            .up, .down => {
                try validateSurface(surface);
                const text = self.buffer.text();
                const line = lineAt(text, self.buffer.selection().caret);
                const x = self.preferred_x orelse try width(surface, text[line.start..self.buffer.selection().caret]);
                self.preferred_x = x;
                const row = if (input.key == .up) line.row -| 1 else line.row + 1;
                const target = lineForRow(text, row);
                return (try self.moveTo(try offsetAtX(text, target, x, surface), input.shift)) or canceled;
            },
            else => return canceled,
        }
    }
    fn moveTo(self: *Editor, offset: usize, extend: bool) !bool {
        return self.buffer.setSelection(.{ .anchor = if (extend) self.buffer.selection().anchor else offset, .caret = offset });
    }
    pub fn hitTest(self: *Editor, bounds: Rect, surface: Surface, point: layout.Point) !usize {
        try validateSurface(surface);
        if (!layout.validRect(bounds) or !std.math.isFinite(point.x) or !std.math.isFinite(point.y)) return error.InvalidGeometry;
        const text = self.displayText();
        const y = @max(0, @as(f64, point.y) - bounds.y + self.scroll.offset.y);
        const rows = @min(@floor(y / surface.line_height), @as(f64, @floatFromInt(text.len)));
        const line = lineForRow(text, @intFromFloat(rows));
        return offsetAtX(text, line, @floatCast(@max(0, @as(f64, point.x) - bounds.x + self.scroll.offset.x)), surface);
    }
    /// Caret in content DIP before viewport scrolling, suitable for ensureVisible.
    pub fn caretRect(self: *Editor, surface: Surface) !Rect {
        try validateSurface(surface);
        const text = self.displayText();
        const caret = self.displaySelection().caret;
        const line = lineAt(text, caret);
        return .{ .x = try width(surface, text[line.start..caret]), .y = @as(f32, @floatFromInt(line.row)) * surface.line_height, .width = 1, .height = surface.line_height };
    }
    pub fn draw(self: *Editor, bounds: Rect, surface: Surface) !void {
        try validateSurface(surface);
        if (!layout.validRect(bounds)) return error.InvalidGeometry;
        const text = self.displayText();
        var content_width: f32 = 1;
        var line = lineForRow(text, 0);
        while (true) {
            content_width = @max(content_width, try width(surface, text[line.start..line.end]) + 1);
            if (line.end == text.len) break;
            line = nextLine(text, line);
        }
        _ = try self.scroll.setSizes(.{ .width = bounds.width, .height = bounds.height }, .{ .width = content_width, .height = @as(f32, @floatFromInt(line.row + 1)) * surface.line_height });
        if (self.reveal_caret) {
            _ = try self.scroll.ensureVisible(try self.caretRect(surface));
            self.reveal_caret = false;
        }
        const selected = self.displaySelection().range();
        const composition = self.buffer.composition();
        line = lineForRow(text, 0);
        while (true) {
            const y = bounds.y + @as(f32, @floatFromInt(line.row)) * surface.line_height - self.scroll.offset.y;
            if (y + surface.line_height > bounds.y and y < bounds.y + bounds.height) {
                const start = @max(line.start, selected.start);
                const end = @min(line.end, selected.end);
                if (end > start or (selected.start <= line.end and selected.end > line.end)) {
                    const x = try width(surface, text[line.start..@min(start, line.end)]);
                    const right = try width(surface, text[line.start..@max(@min(end, line.end), @min(start, line.end))]);
                    try surface.paint(surface.context, .{ .selection = .{ .x = bounds.x + x - self.scroll.offset.x, .y = y, .width = @max(1, right - x), .height = surface.line_height } });
                }
                try surface.paint(surface.context, .{ .text = .{ .bounds = .{ .x = bounds.x - self.scroll.offset.x, .y = y, .width = @max(bounds.width, content_width), .height = surface.line_height }, .text = text[line.start..line.end] } });
                if (composition) |preedit| {
                    const begin = @max(line.start, preedit.range.start);
                    const finish = @min(line.end, preedit.range.start + preedit.text.len);
                    if (finish > begin) {
                        const x = try width(surface, text[line.start..begin]);
                        const right = try width(surface, text[line.start..finish]);
                        try surface.paint(surface.context, .{ .composition = .{ .x = bounds.x + x - self.scroll.offset.x, .y = y + surface.line_height - 1, .width = right - x, .height = 1 } });
                    }
                }
            }
            if (line.end == text.len) break;
            line = nextLine(text, line);
        }
        if (self.focused and self.window_active) {
            var caret = try self.caretRect(surface);
            caret.x += bounds.x - self.scroll.offset.x;
            caret.y += bounds.y - self.scroll.offset.y;
            try surface.paint(surface.context, .{ .caret = caret });
        }
    }
};

fn validateSurface(surface: Surface) !void {
    if (!std.math.isFinite(surface.line_height) or surface.line_height <= 0) return error.InvalidMetrics;
}
fn width(surface: Surface, text: []const u8) !f32 {
    if (text.len == 0) return 0;
    const value = try surface.measure(surface.context, text);
    if (!std.math.isFinite(value) or value < 0) return error.InvalidMetrics;
    return value;
}
fn lineAt(text: []const u8, offset: usize) Line {
    var line: Line = .{ .start = 0, .end = 0, .row = 0 };
    while (true) {
        line.end = std.mem.indexOfScalarPos(u8, text, line.start, '\n') orelse text.len;
        if (offset <= line.end or line.end == text.len) return line;
        line.start = line.end + 1;
        line.row += 1;
    }
}
fn lineForRow(text: []const u8, row: usize) Line {
    var line = lineAt(text, 0);
    while (line.row < row and line.end != text.len) line = nextLine(text, line);
    return line;
}
fn nextLine(text: []const u8, line: Line) Line {
    const start = line.end + 1;
    return .{ .start = start, .end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len, .row = line.row + 1 };
}
fn offsetAtX(text: []const u8, line: Line, x: f32, surface: Surface) !usize {
    var low = line.start;
    var high = line.end;
    while (low < high) {
        var middle = low + (high - low) / 2;
        while (!editing.isBoundary(text, middle)) middle -= 1;
        var next = middle + 1;
        while (!editing.isBoundary(text, next)) next += 1;
        if (try width(surface, text[line.start..next]) < x) low = next else high = middle;
    }
    if (low == line.end) return low;
    var next = low + 1;
    while (!editing.isBoundary(text, next)) next += 1;
    const left = try width(surface, text[line.start..low]);
    const right = try width(surface, text[line.start..next]);
    return if (x - left < right - x) low else next;
}

const TestSurface = struct {
    commands: usize = 0,
    clipboard: [128]u8 = undefined,
    clipboard_len: usize = 0,
    fn measure(_: *anyopaque, text: []const u8) !f32 {
        return @as(f32, @floatFromInt(try std.unicode.utf8CountCodepoints(text))) * 10;
    }
    fn paint(ptr: *anyopaque, _: PaintCommand) !void {
        const self: *TestSurface = @ptrCast(@alignCast(ptr));
        self.commands += 1;
    }
    fn write(ptr: *anyopaque, text: []const u8) !void {
        const self: *TestSurface = @ptrCast(@alignCast(ptr));
        if (text.len > self.clipboard.len) return error.CapacityExceeded;
        @memcpy(self.clipboard[0..text.len], text);
        self.clipboard_len = text.len;
    }
    fn read(ptr: *anyopaque, output: []u8) !usize {
        const self: *TestSurface = @ptrCast(@alignCast(ptr));
        if (self.clipboard_len > output.len) return error.CapacityExceeded;
        @memcpy(output[0..self.clipboard_len], self.clipboard[0..self.clipboard_len]);
        return self.clipboard_len;
    }
    fn surface(self: *TestSurface) Surface {
        return .{ .context = self, .line_height = 20, .measure = measure, .paint = paint };
    }
};

test "editor keyboard navigation clipboard and undo form a usable editing path" {
    var probe: TestSurface = .{};
    var editor = try Editor.init(std.testing.allocator, .{ .multiline = true, .autofocus = true }, "a中\nxyz");
    defer editor.deinit();
    editor.clipboard = .{ .context = &probe, .write = TestSurface.write, .read = TestSurface.read };
    _ = try editor.key(.{ .key = .home }, probe.surface());
    _ = try editor.key(.{ .key = .up }, probe.surface());
    try std.testing.expectEqual(@as(usize, 0), editor.buffer.selection().caret);
    _ = try editor.key(.{ .key = .right, .shift = true }, probe.surface());
    _ = try editor.key(.{ .key = .right, .shift = true }, probe.surface());
    _ = try editor.key(.{ .key = .x, .control = true }, probe.surface());
    try std.testing.expectEqualStrings("\nxyz", editor.buffer.text());
    try std.testing.expectEqualStrings("a中", probe.clipboard[0..probe.clipboard_len]);
    _ = try editor.key(.{ .key = .v, .control = true }, probe.surface());
    try std.testing.expectEqualStrings("a中\nxyz", editor.buffer.text());
    _ = try editor.key(.{ .key = .z, .control = true }, probe.surface());
    try std.testing.expectEqualStrings("\nxyz", editor.buffer.text());
    _ = try editor.key(.{ .key = .y, .control = true }, probe.surface());
    try std.testing.expectEqualStrings("a中\nxyz", editor.buffer.text());
}

test "editor preedit display pointer selection and drawing share byte coordinates" {
    var probe: TestSurface = .{};
    const surface = probe.surface();
    var editor = try Editor.init(std.testing.allocator, .{ .autofocus = true }, "a");
    defer editor.deinit();
    const bounds: Rect = .{ .x = 10, .y = 10, .width = 100, .height = 30 };
    _ = try editor.handleEvent(.{ .text_preedit = .{ .text = "中文", .selection_start = 6, .selection_end = 6 } }, bounds, surface);
    try std.testing.expectEqualStrings("a中文", editor.displayText());
    try std.testing.expectEqualStrings("a", editor.buffer.text());
    _ = try editor.handleEvent(.{ .text_input = .{ .text = "中文", .producer = .application } }, bounds, surface);
    try std.testing.expectEqualStrings("a中文", editor.buffer.text());
    _ = try editor.handleEvent(.{ .pointer_down = .{ .position = .{ .x = 21, .y = 15 } } }, bounds, surface);
    _ = try editor.handleEvent(.{ .pointer_up = .{ .position = .{ .x = 39, .y = 15 } } }, bounds, surface);
    try std.testing.expectEqualStrings("中文", editor.buffer.selectedText());
    try editor.draw(bounds, surface);
    try std.testing.expect(probe.commands >= 3);
}

test "editor uses only bounded initialization storage and single-line paste normalizes breaks" {
    var memory: [8192]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&memory);
    var editor = try Editor.init(allocator.allocator(), .{ .buffer = .{ .max_bytes = 128, .undo_entries = 4, .undo_bytes = 128, .composition_bytes = 32 }, .autofocus = true }, "");
    defer editor.deinit();
    const used = allocator.end_index;
    var probe: TestSurface = .{};
    _ = try editor.insertText("a\r\nb\nc");
    try std.testing.expectEqualStrings("a b c", editor.buffer.text());
    try std.testing.expect(!(try editor.insertText("\n")));
    try editor.draw(.{ .x = 0, .y = 0, .width = 200, .height = 30 }, probe.surface());
    try std.testing.expectEqual(used, allocator.end_index);
}

test "editor consumes recognized keys at boundaries while preserving key change semantics" {
    var probe: TestSurface = .{};
    const surface = probe.surface();
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 30 };
    var editor = try Editor.init(std.testing.allocator, .{ .autofocus = true }, "");
    defer editor.deinit();
    try std.testing.expect(!(try editor.key(.{ .key = .left }, surface)));
    try std.testing.expect(try editor.handleEvent(.{ .edit_key = .{ .key = .left } }, bounds, surface));
    try std.testing.expect(try editor.handleEvent(.{ .edit_key = .{ .key = .c, .control = true } }, bounds, surface));
    try std.testing.expect(!(try editor.handleEvent(.{ .key_input = .{ .key = .f3 } }, bounds, surface)));
    try std.testing.expect(!(try editor.handleEvent(.{ .edit_key = .{ .key = .c } }, bounds, surface)));
    try std.testing.expect(try editor.handleEvent(.{ .key_input = .{ .key = .space } }, bounds, surface));
    try std.testing.expect(try editor.handleEvent(.{ .key_input = .{ .key = .enter } }, bounds, surface));
    try std.testing.expectEqualStrings(" ", editor.buffer.text());
    _ = try editor.buffer.selectAll();
    try std.testing.expectError(error.ClipboardUnavailable, editor.handleEvent(.{ .edit_key = .{ .key = .c, .control = true } }, bounds, surface));
}

test {
    _ = TextBinding;
}
