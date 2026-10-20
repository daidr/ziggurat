//! A form of editable text fields built with `ziggurat_view_text`.
//!
//! Each field is a `ziggurat_document_editor.Field` over its own Document,
//! so keyboard input, IME composition and candidate placement, selection and
//! undo come from the native text path rather than from key events. The form
//! shows required and validated single-line fields (the error appears in the
//! view field), a multi-line notes area, an editable combo box with filtered
//! suggestions, and a token field that turns Enter or a picked suggestion
//! into a removable tag. The summary on the right is rebuilt from the
//! Documents on every frame.
//!
//! Run with `zig build run-text-input`.
const std = @import("std");
const z = @import("ziggurat");
const view = @import("ziggurat_view");
const text = @import("ziggurat_view_text");
const d = @import("ziggurat_document");
const t = @import("ziggurat_text_layout");
const editing = @import("ziggurat_document_editor");

const countries = [_][]const u8{ "Argentina", "Australia", "Austria", "Brazil", "Canada", "China", "Egypt", "France", "Germany", "India", "Japan", "Kenya", "Mexico", "Norway", "Portugal", "Spain", "Sweden" };
const known_tags = [_][]const u8{ "desktop", "editor", "graphics", "i18n", "input", "layout", "networking", "unicode", "zig" };

/// One text box: the caller-owned Document and Field, and the view leaf
/// that places and draws them. Keep it at a stable address until `close`.
const Input = struct {
    document: *d.Document,
    editor: *editing.Field,
    box: text.TextField,
    /// A replacement value applied after the current input dispatch.
    later: [256]u8 = undefined,
    later_len: usize = 0,
    queued: bool = false,

    fn open(self: *Input, allocator: std.mem.Allocator, engine: *t.Engine, host: *view.Host, scale: f32, field: editing.FieldOptions, options: text.Options) !void {
        const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "", .{});
        errdefer document.close() catch {};
        const editor = try editing.Field.create(allocator, document, engine, field);
        self.* = .{ .document = document, .editor = editor, .box = text.TextField.init(editor, host, .{ .font = .{ .size = 16 }, .scale = scale }, options) };
    }

    /// Stop deferred view work, then close the Field before its Document.
    fn close(self: *Input) void {
        self.box.detach();
        self.editor.close() catch |err| std.log.err("field close: {s}", .{@errorName(err)});
        self.document.close() catch |err| std.log.err("document close: {s}", .{@errorName(err)});
    }

    /// The committed text, truncated to `buffer`.
    fn value(self: *Input, buffer: []u8) []const u8 {
        const length = self.document.byteLength() catch return "";
        const count = self.document.read(.{ .start = 0, .end = @min(length, buffer.len) }, buffer) catch return "";
        return buffer[0..count];
    }

    /// Replace the value outside the build or input callback that asked for
    /// it, through the Field so undo and accessibility follow the change.
    fn setLater(self: *Input, window: z.Window, bytes: []const u8) void {
        const count = @min(bytes.len, self.later.len);
        @memcpy(self.later[0..count], bytes[0..count]);
        self.later_len = count;
        if (self.queued) return;
        window.app.post(.{ .context = self, .call = applyLater }) catch return;
        self.queued = true;
    }
    fn applyLater(ptr: *anyopaque) void {
        const self: *Input = @ptrCast(@alignCast(ptr));
        self.queued = false;
        _ = self.editor.setValue(self.later[0..self.later_len]) catch |err| switch (err) {
            // The window closed first; there is nothing left to update.
            error.Closed, error.NotAttached => {},
            else => std.log.err("set value: {s}", .{@errorName(err)}),
        };
    }
};

const Form = struct {
    window: ?z.Window = null,
    name: Input = undefined,
    email: Input = undefined,
    notes: Input = undefined,
    country: Input = undefined,
    tag: Input = undefined,
    tags: [8][24]u8 = undefined,
    tag_lengths: [8]u8 = undefined,
    tag_count: usize = 0,
    submitted: bool = false,
    saved: usize = 0,
    /// A clipboard shared by the fields; see the report of API gaps.
    clip: [1024]u8 = undefined,
    clip_len: usize = 0,

    fn addTag(self: *Form, raw: []const u8) void {
        const label = std.mem.trim(u8, raw, " ");
        if (label.len == 0 or label.len > self.tags[0].len or self.tag_count == self.tags.len) return;
        for (self.tags[0..self.tag_count], self.tag_lengths[0..self.tag_count]) |*existing, length| {
            if (std.mem.eql(u8, existing[0..length], label)) return;
        }
        @memcpy(self.tags[self.tag_count][0..label.len], label);
        self.tag_lengths[self.tag_count] = @intCast(label.len);
        self.tag_count += 1;
    }
    fn tagAt(self: *const Form, index: usize) []const u8 {
        return self.tags[index][0..self.tag_lengths[index]];
    }
    fn hasTag(self: *const Form, label: []const u8) bool {
        for (0..self.tag_count) |index| if (std.mem.eql(u8, self.tagAt(index), label)) return true;
        return false;
    }

    /// Enter in the tag input commits its text as a tag.
    fn submitTag(context: ?*anyopaque, window: z.Window) void {
        const self: *Form = @ptrCast(@alignCast(context.?));
        var buffer: [64]u8 = undefined;
        self.addTag(self.tag.value(&buffer));
        self.tag.setLater(window, "");
    }
    fn changed(_: ?*anyopaque, window: z.Window, _: u64) void {
        window.invalidate();
    }
    fn clipWrite(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Form = @ptrCast(@alignCast(context));
        if (bytes.len > self.clip.len) return error.ClipboardFull;
        @memcpy(self.clip[0..bytes.len], bytes);
        self.clip_len = bytes.len;
    }
    fn clipRead(context: *anyopaque, destination: []u8) anyerror!usize {
        const self: *Form = @ptrCast(@alignCast(context));
        if (self.clip_len > destination.len) return error.CapacityExceeded;
        @memcpy(destination[0..self.clip_len], self.clip[0..self.clip_len]);
        return self.clip_len;
    }

    fn emailError(email: []const u8) ?[]const u8 {
        if (email.len == 0) return null;
        const at = std.mem.indexOfScalar(u8, email, '@') orelse return "An email address contains @";
        if (at == 0 or std.mem.indexOfScalarPos(u8, email, at + 1, '.') == null) return "Use the form name@example.com";
        return null;
    }

    fn build(self: *Form, v: *view.View) anyerror!void {
        var name_buffer: [256]u8 = undefined;
        var email_buffer: [256]u8 = undefined;
        var notes_buffer: [2048]u8 = undefined;
        var country_buffer: [256]u8 = undefined;
        var tag_buffer: [64]u8 = undefined;
        const name = self.name.value(&name_buffer);
        const email = self.email.value(&email_buffer);
        const notes = self.notes.value(&notes_buffer);
        const country = self.country.value(&country_buffer);
        const tag_text = self.tag.value(&tag_buffer);
        const name_error: ?[]const u8 = if (self.submitted and std.mem.trim(u8, name, " ").len == 0) "Enter a name" else null;
        const email_error = emailError(email);

        try v.row(.{ .gap = 24, .grow = 1, .self_align = .stretch });
        try v.column(.{ .gap = 12, .grow = 1 });
        try v.text("Profile", .{ .font = view.Font.heading3 });
        try v.field("Name", .{ .required = true, .@"error" = name_error, .help = "Any script works; try an input method." }, .{ .self_align = .stretch, .key = 1 });
        try v.embed(self.name.box.embed(), .{ .self_align = .stretch, .key = 1 });
        try v.end();
        try v.field("Email", .{ .@"error" = email_error, .help = "Checked as you type." }, .{ .self_align = .stretch, .key = 2 });
        try v.embed(self.email.box.embed(), .{ .self_align = .stretch, .key = 2 });
        try v.end();

        try v.field("Country", .{ .help = "Type to filter, or press Down." }, .{ .self_align = .stretch, .key = 3 });
        try v.editableComboBox(country, .{ .name = "Country", .self_align = .stretch });
        try v.embed(self.country.box.embed(), .{ .grow = 1, .key = 3 });
        try v.end();
        try v.suggestions(.{ .name = "Countries" });
        for (countries) |candidate| {
            if (!std.ascii.startsWithIgnoreCase(candidate, country) or std.mem.eql(u8, candidate, country)) continue;
            if (try v.suggestion(candidate, .{ .key = view.key(candidate) })) if (self.window) |window| self.country.setLater(window, candidate);
        }
        try v.end();
        try v.end();

        try v.field("Tags", .{ .help = "Enter adds a tag; Backspace on an empty input selects the last one." }, .{ .self_align = .stretch, .key = 4 });
        try v.tokenField(.{ .name = "Tags", .self_align = .stretch });
        var index: usize = 0;
        while (index < self.tag_count) {
            if (try v.token(self.tagAt(index), .{ .key = view.key(self.tagAt(index)) })) {
                // Removed: shift the rest down and keep this index.
                for (index + 1..self.tag_count) |next| {
                    self.tags[next - 1] = self.tags[next];
                    self.tag_lengths[next - 1] = self.tag_lengths[next];
                }
                self.tag_count -= 1;
                continue;
            }
            index += 1;
        }
        try v.embed(self.tag.box.embed(), .{ .grow = 1, .min_width = 120, .key = 4 });
        try v.end();
        try v.suggestions(.{ .name = "Known tags" });
        if (tag_text.len > 0) for (known_tags) |candidate| {
            if (!std.ascii.startsWithIgnoreCase(candidate, tag_text) or self.hasTag(candidate)) continue;
            if (try v.suggestion(candidate, .{ .key = view.key(candidate) })) {
                self.addTag(candidate);
                if (self.window) |window| self.tag.setLater(window, "");
            }
        };
        try v.end();
        try v.end();

        try v.field("Notes", .{ .help = "Enter starts a new line." }, .{ .self_align = .stretch, .key = 5 });
        try v.embed(self.notes.box.embed(), .{ .self_align = .stretch, .key = 5 });
        try v.end();
        try v.row(.{ .gap = 8, .alignment = .center, .key = 6 });
        if (try v.button("Submit", .{})) {
            self.submitted = true;
            if (std.mem.trim(u8, name, " ").len > 0 and email_error == null) self.saved += 1;
        }
        if (self.saved > 0) try v.textf("Saved {d} time{s}.", .{ self.saved, if (self.saved == 1) "" else "s" }, .{ .color = 0x2e7d32 });
        try v.end();
        try v.end();

        try v.column(.{ .gap = 6, .width = 240, .padding = view.Insets.all(12), .background = 0xf3f6f9, .radius = 6, .border = 0xd5dde5 });
        try v.text("Summary", .{ .font = view.Font.heading4 });
        try v.textf("Name: {s}", .{if (name.len > 0) name else "—"}, .{});
        try v.textf("Email: {s}", .{if (email.len == 0) "—" else if (email_error == null) email else "(invalid)"}, .{});
        try v.textf("Country: {s}", .{if (country.len > 0) country else "—"}, .{});
        try v.textf("Tags: {d}", .{self.tag_count}, .{});
        for (0..self.tag_count) |at| try v.badge(self.tagAt(at), .{ .key = view.key(self.tagAt(at)) });
        const lines = if (notes.len == 0) 0 else std.mem.count(u8, notes, "\n") + 1;
        try v.textf("Notes: {d} line{s}, {d} characters", .{ lines, if (lines == 1) "" else "s", std.unicode.utf8CountCodepoints(notes) catch notes.len }, .{ .key = 7 });
        try v.end();
        try v.end();
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const app = try z.App.init(allocator);
    defer app.deinit();
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch |err| std.log.err("engine close: {s}", .{@errorName(err)});

    var form: Form = .{};
    var storage: view.Storage(128, 4096) = .{};
    var host = view.Host.init(&form, Form.build, storage.buffers(), .{});
    const window = try app.createWindow(.{ .title = "Ziggurat — Text input", .width = 820, .height = 680, .min_width = 560, .min_height = 480 });
    form.window = window;
    try host.attach(window);
    // Fields register with the Host's Context once it is attached.
    try host.context.prepareTextFields(allocator, .{});

    const scale = (try window.contentSize()).scale;
    const clipboard: @import("ziggurat_ui").editor.Clipboard = .{ .context = &form, .read = Form.clipRead, .write = Form.clipWrite };
    const common: editing.FieldOptions = .{ .value_bytes = 256, .clipboard = clipboard, .context = &form, .changed = Form.changed };
    try form.name.open(allocator, engine, &host, scale, common, .{ .width = 320 });
    defer form.name.close();
    try form.email.open(allocator, engine, &host, scale, common, .{ .width = 320 });
    defer form.email.close();
    try form.country.open(allocator, engine, &host, scale, common, .{ .frame = false });
    defer form.country.close();
    var tag_options = common;
    tag_options.submit = Form.submitTag;
    try form.tag.open(allocator, engine, &host, scale, tag_options, .{ .frame = false, .width = 120, .name = "New tag" });
    defer form.tag.close();
    var notes_options = common;
    notes_options.multiline = true;
    notes_options.value_bytes = 2048;
    notes_options.storage_bytes = 64 * 1024;
    try form.notes.open(allocator, engine, &host, scale, notes_options, .{ .lines = 4, .width = 320 });
    defer form.notes.close();

    window.show();
    try app.run();
    form.window = null;
}
