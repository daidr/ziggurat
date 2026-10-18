//! Pure bounded geometry and source composition for selected completion text.
const std = @import("std");
const ui = @import("ziggurat_ui");
const t = @import("ziggurat_text_layout");

pub const Options = struct {
    /// Sum of detail/documentation bytes, including the optional two newlines.
    text_bytes: usize = 16 * 1024,
    max_width: f32 = 360,
    max_height: f32 = 160,
    min_width: f32 = 96,
    min_height: f32 = 32,
    gap: f32 = 4,
    prepared: t.PrepareLimits = .{ .pixels = 256 * 1024, .bytes = 2 * 1024 * 1024 },

    pub fn validate(self: Options) !void {
        if (self.text_bytes == 0 or self.text_bytes > 128 * 1024 or
            !std.math.isFinite(self.max_width) or !std.math.isFinite(self.max_height) or
            !std.math.isFinite(self.min_width) or !std.math.isFinite(self.min_height) or !std.math.isFinite(self.gap) or
            self.min_width < 12 or self.min_height < 8 or self.max_width < self.min_width or self.max_height < self.min_height or
            self.max_width > 4096 or self.max_height > 4096 or self.gap < 0 or self.gap > 64 or
            self.prepared.pixels == 0 or self.prepared.pixels > 16 * 1024 * 1024 or self.prepared.bytes == 0 or self.prepared.bytes > 64 * 1024 * 1024)
            return error.InvalidLimits;
    }
};

pub fn sourceLength(detail: []const u8, documentation: []const u8, limit: usize) !usize {
    if (detail.len > limit or documentation.len > limit - detail.len) return error.CapacityExceeded;
    const sum = detail.len + documentation.len;
    const separator: usize = if (detail.len != 0 and documentation.len != 0) 2 else 0;
    if (separator > limit - sum) return error.CapacityExceeded;
    return sum + separator;
}

/// Capacity is checked before writing. Result is ordinary text, never markup.
pub fn writeSource(detail: []const u8, documentation: []const u8, output: []u8) ![]const u8 {
    const size = try sourceLength(detail, documentation, output.len);
    @memcpy(output[0..detail.len], detail);
    var at = detail.len;
    if (detail.len != 0 and documentation.len != 0) {
        @memcpy(output[at..][0..2], "\n\n");
        at += 2;
    }
    @memcpy(output[at..][0..documentation.len], documentation);
    return output[0..size];
}

fn valid(rect: ui.Rect) bool {
    return std.math.isFinite(rect.x) and std.math.isFinite(rect.y) and std.math.isFinite(rect.width) and std.math.isFinite(rect.height) and rect.width >= 0 and rect.height >= 0 and std.math.isFinite(rect.x + rect.width) and std.math.isFinite(rect.y + rect.height);
}
/// Right, left, below, above, inside bounds; never steals list rows. No fitting
/// region is a legitimate invisible panel, rather than a clipped tiny label.
pub fn place(bounds: ui.Rect, popup: ui.Rect, options: Options) !?ui.Rect {
    try options.validate();
    if (!valid(bounds) or !valid(popup)) return error.InvalidGeometry;
    if (bounds.width == 0 or bounds.height == 0) return null;
    const x0: f64 = bounds.x;
    const y0: f64 = bounds.y;
    const x1 = x0 + bounds.width;
    const y1 = y0 + bounds.height;
    const px0 = std.math.clamp(@as(f64, popup.x), x0, x1);
    const py0 = std.math.clamp(@as(f64, popup.y), y0, y1);
    const px1 = std.math.clamp(@as(f64, popup.x) + popup.width, x0, x1);
    const py1 = std.math.clamp(@as(f64, popup.y) + popup.height, y0, y1);
    const candidates: [4][4]f64 = .{
        .{ @min(x1, px1 + options.gap), y0, x1, y1 },
        .{ x0, y0, @max(x0, px0 - options.gap), y1 },
        .{ x0, @min(y1, py1 + options.gap), x1, y1 },
        .{ x0, y0, x1, @max(y0, py0 - options.gap) },
    };
    for (candidates, 0..) |box, index| {
        const width = @min(box[2] - box[0], options.max_width);
        const height = @min(box[3] - box[1], options.max_height);
        if (width < options.min_width or height < options.min_height) continue;
        const x = std.math.clamp(if (index == 1) box[2] - width else if (index < 2) box[0] else px0, box[0], box[2] - width);
        const y = std.math.clamp(if (index == 3) box[3] - height else if (index < 2) py0 else box[1], box[1], box[3] - height);
        return .{ .x = @floatCast(x), .y = @floatCast(y), .width = @floatCast(width), .height = @floatCast(height) };
    }
    return null;
}

test "details composition is bounded and failed output is untouched" {
    var output: [8]u8 = @splat(0x5a);
    try std.testing.expectError(error.CapacityExceeded, writeSource("1234", "5678", &output));
    try std.testing.expectEqual([_]u8{0x5a} ** 8, output);
    try std.testing.expectEqualStrings("a\n\nb", try writeSource("a", "b", &output));
    try std.testing.expectEqualStrings("b", try writeSource("", "b", &output));
    try std.testing.expectEqual(@as(usize, 0), try sourceLength("", "", 0));
    try std.testing.expectError(error.CapacityExceeded, sourceLength("a", "b", 3));
}
test "details placement is deterministic and excludes the popup inside the viewport" {
    const bounds: ui.Rect = .{ .x = 4, .y = 8, .width = 800, .height = 400 };
    const popup: ui.Rect = .{ .x = 10, .y = 40, .width = 360, .height = 160 };
    const right = (try place(bounds, popup, .{})).?;
    try std.testing.expectEqual(@as(f32, 374), right.x);
    try std.testing.expectEqual(@as(f32, 40), right.y);
    const narrow: ui.Rect = .{ .x = 4, .y = 8, .width = 400, .height = 400 };
    const below = (try place(narrow, popup, .{})).?;
    try std.testing.expectEqual(@as(f32, 204), below.y);
    try std.testing.expectEqual(@as(f32, 10), below.x);
    try std.testing.expect(try place(popup, popup, .{}) == null);
    try std.testing.expectError(error.InvalidGeometry, place(.{ .x = 0, .y = 0, .width = std.math.inf(f32), .height = 20 }, popup, .{}));
    try std.testing.expectError(error.InvalidLimits, place(bounds, popup, .{ .max_width = 1 }));
}
