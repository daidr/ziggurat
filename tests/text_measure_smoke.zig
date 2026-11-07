//! The platform measurer's numbers put together from their characters, and
//! lines of a paragraph measured from it shaped once, against texts laid
//! out on their own.
const std = @import("std");
const view = @import("ziggurat_view");
const measure = @import("ziggurat_text_measure");

fn alone(native: *measure.Native, utf8: []const u8, font: view.Font) !f32 {
    const layout = try native.engine.layout(utf8, .{ .family = measure.interface_family, .size = font.size, .weight = font.weight.value(), .italic = font.italic });
    defer layout.close() catch {};
    return @ceil((try layout.metrics()).bounds.width);
}

fn check(ok: bool, comptime what: []const u8, args: anytype) !void {
    if (ok) return;
    std.debug.print("text measure: " ++ what ++ "\n", args);
    return error.TestUnexpectedResult;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const native = try measure.Native.create(allocator, std.Thread.getCurrentId());
    defer native.destroy();
    const fonts = [_]view.Font{ .{}, .{ .size = 13, .weight = .semibold } };

    // A dashboard's numbers, each new in every frame.
    for (fonts) |font| {
        var buffer: [32]u8 = undefined;
        var index: u32 = 0;
        while (index < 400) : (index += 1) {
            const number = try std.fmt.bufPrint(&buffer, "{d}.{d:0>2}%", .{ index * 37 % 1000, index % 100 });
            const width = native.width(number, font);
            const expected = try alone(native, number, font);
            try check(@abs(width - expected) <= 1, "number {s} is {d}, laid out alone {d}", .{ number, width, expected });
        }
    }
    try check(native.stats.distrusted == 0 and native.stats.numbers >= 700, "numbers put together {d}, fonts distrusted {d}", .{ native.stats.numbers, native.stats.distrusted });
    // Single characters and pairs of the 13 signs, and the checks.
    try check(native.stats.layouts <= 2 * (13 + 13 * 13 + 8), "numbers took {d} layouts", .{native.stats.layouts});

    const sentence = "Wrapping a paragraph at a new width takes its lines from the text shaped once, so a window being resized does not lay out every line again. ";
    // A paragraph wrapped at every width of a window being resized.
    const paragraph = sentence ++ sentence ++ sentence;
    const measurer = native.measurer();
    for (fonts) |font| {
        const before = native.stats.layouts;
        var lines: u64 = 0;
        var width: f32 = 160;
        while (width <= 900) : (width += 8) {
            var start: usize = 0;
            while (start < paragraph.len) {
                const line = view.line_breaks.next(paragraph, start, width, font, measurer, .{});
                const got = measurer.partWidth(paragraph, line.start, line.end, font);
                const expected = try alone(native, paragraph[line.start..line.end], font);
                try check(@abs(got - expected) <= 1, "line \"{s}\" at {d} is {d}, laid out alone {d}", .{ paragraph[line.start..line.end], width, got, expected });
                try check(expected <= width + 1 or std.mem.indexOfScalar(u8, paragraph[line.start..line.end], ' ') == null, "line \"{s}\" is wider than {d}", .{ paragraph[line.start..line.end], width });
                lines += 1;
                start = line.next;
            }
        }
        const layouts = native.stats.layouts - before;
        try check(native.stats.distrusted == 0, "a font was distrusted for lines", .{});
        try check(layouts <= 24, "{d} lines at 93 widths took {d} layouts", .{ lines, layouts });
    }
    // Text that breaks other ways, or is quoted, is laid out on its own.
    const parts = native.stats.parts;
    _ = measurer.partWidth("say \"hello there\" now", 0, 9, null);
    _ = measurer.partWidth("日本語 text", 0, 9, null);
    try check(native.stats.parts == parts, "text not plain was measured from a shaped line", .{});
    std.debug.print("text measure: numbers {d}, parts {d}, layouts {d}\n", .{ native.stats.numbers, native.stats.parts, native.stats.layouts });
}
