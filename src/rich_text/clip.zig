//! The editor's own clipboard format: the paragraphs, styles and runs of
//! attributed text as JSON, which other editors paste whole. Applications
//! also save texts in it. A copy names itself, so that the editor that
//! made it pastes back the text it holds, attachments included.
const std = @import("std");
const tx = @import("text.zig");
const html = @import("html.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Text = tx.Text;

/// The clipboard format of attributed text.
pub const format = "application/x-ziggurat-rich-text";

/// Writes `t` as JSON; `copy` names the copy, or is empty. A copy leaves
/// the paragraphs' IDs out, which are the application's names of
/// paragraphs where they are: a paste makes new ones.
pub fn write(t: *const Text, w: *Writer, copy: []const u8) Writer.Error!void {
    try w.writeByte('{');
    if (copy.len > 0) {
        try w.writeAll("\"copy\":");
        try std.json.Stringify.encodeJsonString(copy, .{}, w);
        try w.writeByte(',');
    }
    try w.writeAll("\"paragraphs\":[");
    var p: u32 = 0;
    while (p < t.paragraphCount()) : (p += 1) {
        if (p > 0) try w.writeByte(',');
        const q = t.para(p);
        try w.writeAll("{\"style\":{");
        var fields = Fields{ .w = w };
        const s = q.style;
        if (s.heading > 0) try fields.number("heading", s.heading);
        if (s.list != .none) try fields.number("list", @backingInt(s.list));
        if (s.checked) try fields.boolean("checked");
        if (s.indent > 0) try fields.number("indent", s.indent);
        if (s.@"align" != .start) try fields.number("align", @backingInt(s.@"align"));
        if (s.quote) try fields.boolean("quote");
        if (s.code_block) try fields.boolean("codeBlock");
        if (s.id.len > 0 and copy.len == 0) try fields.string("id", s.id);
        try w.writeByte('}');
        var it = q.iterator();
        var first = true;
        while (it.next()) |item| {
            try w.writeAll(if (first) ",\"runs\":[" else ",");
            first = false;
            try writeRun(w, item.run);
        }
        if (!first) try w.writeByte(']');
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

/// `t` as JSON, allocated.
pub fn json(allocator: Allocator, t: *const Text, copy: []const u8) ![]u8 {
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    write(t, &out.writer, copy) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

const Fields = struct {
    w: *Writer,
    any: bool = false,
    fn key(self: *Fields, name: []const u8) Writer.Error!void {
        if (self.any) try self.w.writeByte(',');
        self.any = true;
        try self.w.print("\"{s}\":", .{name});
    }
    fn number(self: *Fields, name: []const u8, v: anytype) Writer.Error!void {
        try self.key(name);
        try self.w.print("{d}", .{v});
    }
    fn boolean(self: *Fields, name: []const u8) Writer.Error!void {
        try self.key(name);
        try self.w.writeAll("true");
    }
    fn string(self: *Fields, name: []const u8, v: []const u8) Writer.Error!void {
        try self.key(name);
        try std.json.Stringify.encodeJsonString(v, .{}, self.w);
    }
};

fn writeRun(w: *Writer, r: tx.Run) Writer.Error!void {
    const a = r.attributes;
    try w.writeAll("{\"text\":");
    try std.json.Stringify.encodeJsonString(r.text, .{}, w);
    try w.writeAll(",\"attributes\":{");
    var f = Fields{ .w = w };
    if (a.font.len > 0) try f.string("font", a.font);
    if (a.size > 0) try f.number("size", a.size);
    if (a.weight > 0) try f.number("weight", a.weight);
    if (a.italic) try f.boolean("italic");
    if (a.underline) try f.boolean("underline");
    if (a.strikethrough) try f.boolean("strikethrough");
    var buffer: [32]u8 = undefined;
    if (a.color.set()) try f.string("color", html.cssColorString(a.color, &buffer));
    if (a.background.set()) try f.string("background", html.cssColorString(a.background, &buffer));
    if (a.code) try f.boolean("code");
    if (a.link.len > 0) try f.string("link", a.link);
    if (a.tag.len > 0) try f.string("tag", a.tag);
    try w.writeByte('}');
    if (a.attachment) |at| {
        const size = at.size();
        try w.writeAll(",\"attachment\":{");
        var g = Fields{ .w = w };
        if (at.name.len > 0) try g.string("name", at.name);
        if (at.url.len > 0) try g.string("url", at.url);
        try g.number("width", size.width);
        try g.number("height", size.height);
        try w.writeByte('}');
    }
    try w.writeByte('}');
}

const JsonAttributes = struct {
    font: []const u8 = "",
    size: f32 = 0,
    weight: i64 = 0,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    color: []const u8 = "",
    background: []const u8 = "",
    code: bool = false,
    link: []const u8 = "",
    tag: []const u8 = "",
};
const JsonAttachment = struct { name: []const u8 = "", url: []const u8 = "", width: f32 = 0, height: f32 = 0 };
const JsonRun = struct { text: []const u8 = "", attributes: JsonAttributes = .{}, attachment: ?JsonAttachment = null };
const JsonStyle = struct { heading: i64 = 0, list: i64 = 0, checked: bool = false, indent: i64 = 0, @"align": i64 = 0, quote: bool = false, codeBlock: bool = false, id: []const u8 = "" };
const JsonParagraph = struct { style: JsonStyle = .{}, runs: []const JsonRun = &.{} };
const JsonText = struct { copy: []const u8 = "", paragraphs: []const JsonParagraph = &.{} };

pub const Parsed = struct {
    text: Text,
    copy_storage: [64]u8 = undefined,
    copy_len: usize = 0,

    /// The name of the copy, or empty.
    pub fn copy(self: *const Parsed) []const u8 {
        return self.copy_storage[0..self.copy_len];
    }
};

/// The text of JSON the format holds, or null when it holds none.
pub fn parse(allocator: Allocator, bytes: []const u8) !?Parsed {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const value = std.json.parseFromSliceLeaky(JsonText, arena, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    if (value.paragraphs.len == 0 and value.copy.len == 0) return null;
    var paras = try arena.alloc(tx.Paragraph, value.paragraphs.len);
    for (value.paragraphs, 0..) |jp, k| {
        const runs = try arena.alloc(tx.Run, jp.runs.len);
        for (jp.runs, 0..) |jr, i| {
            const ja = jr.attributes;
            var a: tx.Attributes = .{
                .font = ja.font,
                .size = if (std.math.isFinite(ja.size) and ja.size > 0 and ja.size < 1e4) ja.size else 0,
                .weight = @intCast(std.math.clamp(ja.weight, 0, 900)),
                .italic = ja.italic,
                .underline = ja.underline,
                .strikethrough = ja.strikethrough,
                .code = ja.code,
                .link = html.safeLink(ja.link),
                .tag = ja.tag,
            };
            a.color = html.parseCssColor(ja.color) orelse .{};
            a.background = html.parseCssColor(ja.background) orelse .{};
            if (jr.attachment) |jat| {
                const at = try arena.create(tx.Attachment);
                at.* = .{ .name = jat.name, .url = jat.url, .width = html.side(jat.width), .height = html.side(jat.height) };
                a.attachment = at;
            }
            runs[i] = .{ .text = jr.text, .attributes = a };
        }
        const js = jp.style;
        paras[k] = .{ .style = .{
            .heading = @intCast(std.math.clamp(js.heading, 0, 6)),
            .list = if (js.list >= 0 and js.list <= 3) @fromBackingInt(@intCast(js.list)) else .none,
            .checked = js.checked,
            .indent = @intCast(std.math.clamp(js.indent, 0, tx.max_indent)),
            .@"align" = if (js.@"align" >= 0 and js.@"align" <= 2) @fromBackingInt(@intCast(js.@"align")) else .start,
            .quote = js.quote,
            .code_block = js.codeBlock,
            .id = js.id,
        }, .runs = runs };
    }
    var out: Parsed = .{ .text = if (paras.len == 0) try Text.init(allocator) else try Text.of(allocator, paras) };
    out.copy_len = @min(value.copy.len, out.copy_storage.len);
    @memcpy(out.copy_storage[0..out.copy_len], value.copy[0..out.copy_len]);
    return out;
}
