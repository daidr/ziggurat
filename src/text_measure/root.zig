//! A `view.Measurer` that measures with the platform's text layout, in the
//! families the renderers draw with, so that views and the rich text editor
//! place text as it is drawn. Widths are cached by text and font; text the
//! layout does not take is estimated.
const std = @import("std");
const builtin = @import("builtin");
const view = @import("ziggurat_view");
const text = @import("ziggurat_text_layout");

const Allocator = std.mem.Allocator;
const Font = view.Font;
const Size = view.Size;

/// The families the renderers draw the interface and fixed-pitch text in.
pub const interface_family = if (builtin.os.tag == .windows) "Segoe UI" else "Sans";
pub const monospace_family = if (builtin.os.tag == .windows) "Consolas" else "Monospace";

/// Create and use on the main thread.
pub const Native = struct {
    allocator: Allocator,
    engine: *text.Engine,
    widths: std.AutoHashMapUnmanaged(Key, f32) = .empty,

    const Key = struct { hash: u64, font: u32 };
    const max_entries = 8192;

    pub fn create(allocator: Allocator, main_thread: std.Thread.Id) !*Native {
        const self = try allocator.create(Native);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .engine = try text.Engine.create(allocator, main_thread, .{}) };
        return self;
    }

    pub fn destroy(self: *Native) void {
        self.widths.deinit(self.allocator);
        self.engine.close() catch {};
        self.allocator.destroy(self);
    }

    pub fn measurer(self: *Native) view.Measurer {
        return .{ .context = self, .measure = measureLabel, .measure_font = measureFont };
    }

    /// The width of `utf8` in `font`, in DIP.
    pub fn width(self: *Native, utf8: []const u8, font: Font) f32 {
        if (utf8.len == 0) return 0;
        const key: Key = .{ .hash = std.hash.Wyhash.hash(0, utf8), .font = @bitCast(font.key()) };
        if (self.widths.get(key)) |w| return w;
        const w = self.layoutWidth(utf8, font) catch estimate(utf8, font);
        if (self.widths.count() >= max_entries) self.widths.clearRetainingCapacity();
        self.widths.put(self.allocator, key, w) catch {};
        return w;
    }

    fn layoutWidth(self: *Native, utf8: []const u8, font: Font) !f32 {
        const family = if (font.monospace) monospace_family else interface_family;
        const layout = try self.engine.layout(utf8, .{ .family = family, .size = font.size, .weight = font.weight.value(), .italic = font.italic });
        defer layout.close() catch {};
        const m = try layout.metrics();
        return @ceil(m.bounds.width);
    }

    fn measureLabel(context: ?*anyopaque, utf8: []const u8) Size {
        const self: *Native = @ptrCast(@alignCast(context.?));
        return .{ .width = self.width(utf8, .{}), .height = view.Measurer.line_height };
    }

    fn measureFont(context: ?*anyopaque, utf8: []const u8, font: Font) Size {
        const self: *Native = @ptrCast(@alignCast(context.?));
        const scale = font.size / 16;
        const height = @max(view.Measurer.line_height * scale, @ceil(font.size * 1.25));
        return .{ .width = self.width(utf8, font), .height = height };
    }
};

/// What the default measurer gives, for text the layout does not take.
fn estimate(utf8: []const u8, font: Font) f32 {
    const m: view.Measurer = .{};
    return m.textSize(utf8, font).width;
}
