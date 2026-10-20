const std = @import("std");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const rich = @import("rich_text.zig");

const testing = std.testing;
const RichText = rich.RichText;

/// Ten DIP per byte, and a line height that follows the font size.
fn measureFixed(_: ?*anyopaque, text: []const u8, font: view.Font) view.Size {
    return .{ .width = @as(f32, @floatFromInt(text.len)) * 10 * font.size / 16, .height = font.size * 1.5 };
}
fn fixedMeasure(_: ?*anyopaque, text: []const u8) view.Size {
    return .{ .width = @as(f32, @floatFromInt(text.len)) * 10, .height = 24 };
}
const measurer: view.Measurer = .{ .measure = fixedMeasure, .measure_font = measureFixed };

const Recorder = struct {
    const Label = struct { bounds: view.Rect, text: []const u8, color: u32, font: view.Font };
    const Fill = struct { bounds: view.Rect, color: u32, radius: f32 };
    labels: [32]Label = undefined,
    label_count: usize = 0,
    fills: [128]Fill = undefined,
    fill_count: usize = 0,

    pub fn rect(self: *Recorder, bounds: view.Rect, color: u32) void {
        self.fills[self.fill_count] = .{ .bounds = bounds, .color = color, .radius = 0 };
        self.fill_count += 1;
    }
    pub fn roundedRect(self: *Recorder, bounds: view.Rect, radius: f32, color: ui.Color) void {
        self.fills[self.fill_count] = .{ .bounds = bounds, .color = (@as(u32, color.r) << 16) | (@as(u32, color.g) << 8) | color.b, .radius = radius };
        self.fill_count += 1;
    }
    pub fn labelFont(self: *Recorder, bounds: view.Rect, text: []const u8, color: u32, font: view.Font) void {
        self.labels[self.label_count] = .{ .bounds = bounds, .text = text, .color = color, .font = font };
        self.label_count += 1;
    }
    fn fillsOf(self: *const Recorder, color: u32) usize {
        var count: usize = 0;
        for (self.fills[0..self.fill_count]) |fill| count += @intFromBool(fill.color == color);
        return count;
    }
};

fn runText(text: *const RichText, index: usize) []const u8 {
    const run = text.runs.items[index];
    return text.spans[run.span].text[run.start..run.end];
}

test "spans join into words and wrap together at the width" {
    var text = RichText.init(testing.allocator, .{ .measurer = measurer, .width = 130 });
    defer text.deinit();
    // "Saved report.pdf to Documents": the bold name is one word with the
    // period after it in another span.
    try text.setSpans(&.{
        .{ .text = "Saved " },
        .{ .text = "report", .weight = .bold },
        .{ .text = ".pdf to " },
        .{ .text = "Documents", .color = 0x276aa5, .underline = true },
    });
    try testing.expectEqual(@as(usize, 3), text.lines.items.len);
    // "Saved " fits; "report" + ".pdf" (100 DIP) wraps as one word.
    try testing.expectEqualStrings("Saved ", runText(&text, 0));
    try testing.expectEqual(@as(u32, 0), text.runs.items[0].line);
    try testing.expectEqualStrings("report", runText(&text, 1));
    try testing.expectEqual(@as(u32, 1), text.runs.items[1].line);
    try testing.expectEqualStrings(".pdf to ", runText(&text, 2));
    try testing.expectEqual(@as(u32, 1), text.runs.items[2].line);
    try testing.expectEqual(text.runs.items[1].width, text.runs.items[2].x);
    try testing.expectEqualStrings("Documents", runText(&text, 3));
    try testing.expectEqual(@as(u32, 2), text.runs.items[3].line);
    // Spaces that end a line take no room.
    try testing.expectEqual(@as(f32, 50), text.runs.items[0].width);
    try testing.expectEqual(@as(f32, 50), text.lines.items[0].width);
    try testing.expectEqual(@as(f32, 24 * 3), text.size.height);

    // A width change wraps the same words again without measuring.
    text.setWidth(0);
    try testing.expectEqual(@as(usize, 1), text.lines.items.len);
    try testing.expectEqual(@as(f32, 60 + 60 + 80 + 90), text.size.width);
}

test "newlines break lines and CJK breaks between characters" {
    var text = RichText.init(testing.allocator, .{ .measurer = measurer, .width = 45 });
    defer text.deinit();
    try text.setSpans(&.{ .{ .text = "ab\n\n" }, .{ .text = "汉字测试" } });
    // "ab", an empty line, then 3 bytes (30 DIP) per character: one a line.
    try testing.expectEqual(@as(usize, 6), text.lines.items.len);
    try testing.expectEqual(@as(usize, 0), text.lines.items[1].width);
    try testing.expectEqual(@as(f32, 24), text.lines.items[1].height);
    try testing.expectEqualStrings("字", runText(&text, 2));
    try testing.expectEqual(@as(u32, 3), text.runs.items[2].line);
}

test "mixed sizes share a baseline and the tallest sets the line" {
    var text = RichText.init(testing.allocator, .{ .measurer = measurer });
    defer text.deinit();
    try text.setSpans(&.{ .{ .text = "big ", .size = 32 }, .{ .text = "small" } });
    const line = text.lines.items[0];
    // 32 DIP: 48 tall, ascent 24 + 11.2.
    try testing.expectApproxEqAbs(@as(f32, 35.2), line.baseline, 0.01);
    var recorder: Recorder = .{};
    text.paintTo(&recorder, .{ .x = 10, .y = 20 });
    try testing.expectEqual(@as(usize, 2), recorder.label_count);
    const big = recorder.labels[0];
    const small = recorder.labels[1];
    try testing.expectEqualStrings("big", big.text);
    try testing.expectEqual(@as(f32, 32), big.font.size);
    try testing.expectApproxEqAbs(big.bounds.y + 24 + 32 * 0.35, small.bounds.y + 12 + 16 * 0.35, 0.01);
    try testing.expectEqual(@as(f32, 10 + 80), small.bounds.x);
}

test "colors, lines and backgrounds paint over and under the text" {
    var text = RichText.init(testing.allocator, .{ .measurer = measurer, .color = 0x111111 });
    defer text.deinit();
    try text.setSpans(&.{
        .{ .text = "plain " },
        .{ .text = "code", .monospace = true, .background = 0xeeeeee, .radius = 3 },
        .{ .text = " found ", .background = 0xffff00 },
        .{ .text = "teh", .wavy_underline = true, .decoration_color = 0xff0000 },
        .{ .text = " gone", .strikethrough = true, .color = 0x777777 },
        .{ .text = " link", .underline = true, .color = 0x0000ff, .decoration_thickness = 2 },
    });
    var recorder: Recorder = .{};
    text.paintTo(&recorder, .{ .x = 0, .y = 0 });
    // Backgrounds come first, under every label.
    try testing.expectEqual(@as(f32, 3), recorder.fills[0].radius);
    try testing.expectEqual(@as(u32, 0xeeeeee), recorder.fills[0].color);
    try testing.expectEqual(@as(u32, 0xffff00), recorder.fills[1].color);
    try testing.expectEqual(@as(f32, 24), recorder.fills[1].bounds.height);
    try testing.expectEqual(@as(usize, 6), recorder.label_count);
    try testing.expectEqual(@as(u32, 0x111111), recorder.labels[0].color);
    try testing.expect(recorder.labels[1].font.monospace);
    try testing.expectEqual(@as(u32, 0x777777), recorder.labels[4].color);
    // A wave of steps two pixels wide across the 30 DIP word.
    try testing.expectEqual(@as(usize, 15), recorder.fillsOf(0xff0000));
    // The strikethrough takes the text color; the underline its thickness.
    try testing.expectEqual(@as(usize, 1), recorder.fillsOf(0x777777));
    try testing.expectEqual(@as(usize, 1), recorder.fillsOf(0x0000ff));
    for (recorder.fills[0..recorder.fill_count]) |fill| if (fill.color == 0x0000ff) {
        try testing.expectEqual(@as(f32, 2), fill.bounds.height);
        try testing.expectEqual(@as(f32, 50), fill.bounds.width);
    };
    try testing.expectEqual(@as(?usize, 3), text.spanAt(.{ .x = 175, .y = 5 }));
    try testing.expectEqual(@as(?usize, null), text.spanAt(.{ .x = 175, .y = 30 }));
}

test "the leaf measures to its wrapped size and takes the theme's text color" {
    var text = RichText.init(testing.allocator, .{ .measurer = measurer, .width = 60 });
    defer text.deinit();
    try text.setSpans(&.{.{ .text = "one two three" }});
    const content = text.embed();
    const measurement = content.measure(content.context, view.Theme.dark());
    try testing.expectEqual(@as(f32, 50), measurement.preferred.width);
    try testing.expectEqual(@as(f32, 72), measurement.preferred.height);
    try testing.expectEqual(measurement.preferred, measurement.minimum);
    var recorder: Recorder = .{};
    text.paintTo(&recorder, .{ .x = 0, .y = 0 });
    try testing.expectEqual(view.Theme.dark().palette.text, recorder.labels[0].color);
    // Empty spans leave one empty line.
    try text.setSpans(&.{});
    try testing.expectEqual(@as(usize, 1), text.lines.items.len);
    try testing.expectEqual(@as(f32, 0), text.size.width);
}
