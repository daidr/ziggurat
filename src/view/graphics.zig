//! Painters for the pictures of a declarative view that need preparing:
//! `Icons` draws the built-in icon set from coverage masks, tinted at draw
//! time, and `SvgImage` draws an SVG document from pixels prepared at the
//! size it is laid out at. Paint only looks up what is prepared; a picture
//! missing its pixels for the size, scale or color it is painted at is
//! skipped, and a task posted after paint prepares and uploads them on the
//! main thread, then repaints. An unchanged view paints without allocating.
const std = @import("std");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const vector = @import("ziggurat_vector");
const svg = @import("ziggurat_svg");

/// Icon masks kept at once. Masks and images share the renderers' 32
/// resident slots, so keep this below that with room for images.
pub const max_icons = 16;

/// Draws `View.icon` nodes for one Host: pass `painter()` as
/// `Options.icons`. Keep it at a stable address while the Host may paint,
/// and call `deinit` outside paint before the Context detaches.
pub const Icons = struct {
    allocator: std.mem.Allocator,
    host: *view.Host,
    slots: [max_icons]Slot = @splat(.{}),
    /// Icons the last paints found missing, prepared by the posted task.
    wanted: [max_icons]Key = undefined,
    wanted_len: usize = 0,
    queued: bool = false,
    /// Paints so far, to evict the masks used longest ago.
    paints: u64 = 0,
    /// The first error from preparing, uploading or posting.
    last_error: ?anyerror = null,

    const Slot = struct { prepared: ?*vector.Prepared = null, key: Key = undefined, used: u64 = 0 };

    pub fn init(allocator: std.mem.Allocator, host: *view.Host) Icons {
        return .{ .allocator = allocator, .host = host };
    }
    pub fn painter(self: *Icons) view.IconPainter {
        return .{ .context = self, .paint = paint };
    }
    /// Release every mask. Call outside paint, before the Context detaches.
    pub fn deinit(self: *Icons) void {
        for (&self.slots) |*slot| self.release(slot);
        self.wanted_len = 0;
    }
    /// Masks prepared now.
    pub fn count(self: *const Icons) usize {
        var n: usize = 0;
        for (self.slots) |slot| n += @intFromBool(slot.prepared != null);
        return n;
    }

    fn paint(ptr: *anyopaque, frame: *ui.Frame, icon: view.Icon, bounds: view.Rect, color: ui.Color, mirrored: bool) anyerror!void {
        const self: *Icons = @ptrCast(@alignCast(ptr));
        const scale = frame.size.scale;
        // Masks are whole physical pixels, laid at the square's corner.
        const key: Key = .{ .icon = icon, .width = pixels(bounds.width, scale), .height = pixels(bounds.height, scale), .scale = scale, .mirrored = mirrored };
        if (key.width == 0 or key.height == 0) return;
        self.paints +%= 1;
        for (&self.slots) |*slot| if (slot.prepared) |prepared| if (std.meta.eql(slot.key, key)) {
            slot.used = self.paints;
            return frame.coverage(.{ .x = bounds.x, .y = bounds.y }, try prepared.view(), color);
        };
        self.want(key);
    }
    fn want(self: *Icons, key: Key) void {
        for (self.wanted[0..self.wanted_len]) |entry| if (std.meta.eql(entry, key)) return;
        if (self.wanted_len == self.wanted.len) return;
        self.wanted[self.wanted_len] = key;
        self.wanted_len += 1;
        if (self.queued) return;
        const window = self.host.context.window orelse return;
        window.app.post(.{ .context = self, .call = run }) catch |err| {
            self.last_error = self.last_error orelse err;
            return;
        };
        self.queued = true;
    }
    /// Posted after paint: prepare and upload the masks paint asked for.
    fn run(ptr: *anyopaque) void {
        const self: *Icons = @ptrCast(@alignCast(ptr));
        self.queued = false;
        const window = self.host.context.window orelse return;
        self.prepareWanted();
        window.invalidate();
    }
    /// Prepare the masks the last paints asked for now; call outside paint.
    pub fn prepareWanted(self: *Icons) void {
        defer self.wanted_len = 0;
        for (self.wanted[0..self.wanted_len]) |key| {
            const slot = self.victim();
            self.release(slot);
            const prepared = prepareIcon(self.allocator, key) catch |err| {
                self.last_error = self.last_error orelse err;
                continue;
            };
            const shown = prepared.view() catch |err| {
                self.last_error = self.last_error orelse err;
                prepared.close() catch {};
                continue;
            };
            self.host.context.uploadCoverage(shown) catch |err| {
                self.last_error = self.last_error orelse err;
                prepared.close() catch {};
                continue;
            };
            slot.* = .{ .prepared = prepared, .key = key, .used = self.paints };
        }
    }
    /// An empty slot, else the one used longest ago.
    fn victim(self: *Icons) *Slot {
        var best = &self.slots[0];
        for (&self.slots) |*slot| {
            if (slot.prepared == null) return slot;
            if (slot.used < best.used) best = slot;
        }
        return best;
    }
    fn release(self: *Icons, slot: *Slot) void {
        const prepared = slot.prepared orelse return;
        if (self.host.context.window != null) _ = self.host.context.releaseCoverage(prepared.identity) catch |err| {
            self.last_error = self.last_error orelse err;
        };
        prepared.close() catch |err| {
            self.last_error = self.last_error orelse err;
            return;
        };
        slot.* = .{};
    }
};

fn pixels(extent: f32, scale: f32) u32 {
    const value = @round(extent * scale);
    if (!(value >= 1) or value > 4096) return 0;
    return @intFromFloat(value);
}

/// The coverage of `key`'s icon: its outline scaled from the grid to the
/// square, stroked with round caps and joins, mirrored when asked.
fn prepareIcon(allocator: std.mem.Allocator, key: Key) !*vector.Prepared {
    const path = try vector.Path.parseData(allocator, key.icon.pathData(), .{});
    defer path.close() catch {};
    const width = @as(f64, @floatFromInt(key.width)) / key.scale;
    const height = @as(f64, @floatFromInt(key.height)) / key.scale;
    const sx = width / @as(f64, view.icons.grid);
    const sy = height / @as(f64, view.icons.grid);
    const margin: f32 = @floatCast(@max(sx, sy) * view.icons.stroke + 1);
    return path.prepare(allocator, .{
        .main_thread = std.Thread.getCurrentId(),
        // Round caps reach half a stroke past the grid; antialiasing a little more.
        .viewport = .{ .x = -margin, .y = -margin, .width = @floatCast(width + 2 * margin), .height = @floatCast(height + 2 * margin) },
        .scale = key.scale,
        .transform = if (key.mirrored) .{ .xx = -sx, .yy = sy, .x0 = width } else .{ .xx = sx, .yy = sy },
        .style = .{ .stroke = .{ .width = view.icons.stroke, .cap = .round, .join = .round } },
    });
}
/// One prepared icon mask: which icon, its square in physical pixels, the
/// scale it is drawn at and whether it is mirrored.
const Key = struct { icon: view.Icon, width: u32, height: u32, scale: f32, mirrored: bool };

pub const SvgOptions = struct {
    /// The picture's own size in DIP; null reads the root element's
    /// `width` and `height`, else its `viewBox`, else 24 by 24.
    width: ?f32 = null,
    height: ?f32 = null,
    limits: svg.Limits = .{},
};

/// An SVG document shown by `View.svg(image.picture(), ...)`, in its own
/// colors with the node's color as `currentColor`. Parse and keep it on
/// the main thread at a stable address while views paint it; `deinit`
/// outside paint before the Context detaches.
pub const SvgImage = struct {
    allocator: std.mem.Allocator,
    host: *view.Host,
    document: *svg.Document,
    width: f32,
    height: f32,
    prepared: ?*svg.Prepared = null,
    key: ?Want = null,
    wanted: ?Want = null,
    queued: bool = false,
    last_error: ?anyerror = null,

    const Want = struct { width: u32, height: u32, color: u32 };

    pub fn init(allocator: std.mem.Allocator, host: *view.Host, bytes: []const u8, options: SvgOptions) !SvgImage {
        const document = try svg.Document.parse(allocator, bytes, options.limits);
        errdefer document.close() catch {};
        const own = try naturalSize(document);
        return .{ .allocator = allocator, .host = host, .document = document, .width = options.width orelse own.width, .height = options.height orelse own.height };
    }
    pub fn picture(self: *SvgImage) view.SvgPicture {
        return .{ .context = self, .width = self.width, .height = self.height, .paint = paint };
    }
    /// Release the prepared pixels and the document.
    pub fn deinit(self: *SvgImage) void {
        self.release();
        self.document.close() catch |err| {
            self.last_error = self.last_error orelse err;
        };
    }
    /// Pixels are prepared now.
    pub fn ready(self: *const SvgImage) bool {
        return self.prepared != null;
    }

    fn paint(ptr: *anyopaque, frame: *ui.Frame, destination: view.Rect, color: ui.Color) anyerror!void {
        const self: *SvgImage = @ptrCast(@alignCast(ptr));
        const scale = frame.size.scale;
        const wanted: Want = .{ .width = pixels(destination.width, scale), .height = pixels(destination.height, scale), .color = @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b };
        if (wanted.width == 0 or wanted.height == 0) return;
        if (self.prepared) |prepared| if (std.meta.eql(self.key, wanted)) return frame.image(destination, try prepared.view(), .{});
        if (std.meta.eql(self.wanted, wanted) and !self.queued) return;
        self.wanted = wanted;
        if (self.queued) return;
        const window = self.host.context.window orelse return;
        window.app.post(.{ .context = self, .call = run }) catch |err| {
            self.last_error = self.last_error orelse err;
            return;
        };
        self.queued = true;
    }
    fn run(ptr: *anyopaque) void {
        const self: *SvgImage = @ptrCast(@alignCast(ptr));
        self.queued = false;
        const window = self.host.context.window orelse return;
        self.prepareWanted();
        window.invalidate();
    }
    /// Prepare the pixels the last paint asked for now; call outside paint.
    /// A failed preparation is not retried until the size or color changes.
    pub fn prepareWanted(self: *SvgImage) void {
        const wanted = self.wanted orelse return;
        if (std.meta.eql(self.key, wanted) and self.prepared != null) return;
        self.release();
        self.key = wanted;
        const prepared = self.document.prepare(self.allocator, .{
            .main_thread = std.Thread.getCurrentId(),
            .width = wanted.width,
            .height = wanted.height,
            .current_color = .{ .r = @truncate(wanted.color >> 16), .g = @truncate(wanted.color >> 8), .b = @truncate(wanted.color) },
        }) catch |err| {
            self.last_error = self.last_error orelse err;
            return;
        };
        const shown = prepared.view() catch |err| {
            self.last_error = self.last_error orelse err;
            prepared.close() catch {};
            return;
        };
        self.host.context.uploadImage(shown) catch |err| {
            self.last_error = self.last_error orelse err;
            prepared.close() catch {};
            return;
        };
        self.prepared = prepared;
    }
    fn release(self: *SvgImage) void {
        const prepared = self.prepared orelse return;
        if (self.host.context.window != null) _ = self.host.context.releaseImage(prepared.identity) catch |err| {
            self.last_error = self.last_error orelse err;
        };
        prepared.close() catch |err| {
            self.last_error = self.last_error orelse err;
            return;
        };
        self.prepared = null;
    }
};

/// The root element's `width` and `height` in user units, else its
/// `viewBox` size, else 24 by 24.
fn naturalSize(document: *svg.Document) !view.Size {
    const root = try document.node(0);
    const width = length(root.attribute("width"));
    const height = length(root.attribute("height"));
    if (width != null and height != null) return .{ .width = width.?, .height = height.? };
    if (root.attribute("viewBox")) |box| {
        var numbers: [4]f32 = undefined;
        var count: usize = 0;
        var it = std.mem.tokenizeAny(u8, box, " ,\t\r\n");
        while (it.next()) |part| {
            if (count == numbers.len) break;
            numbers[count] = std.fmt.parseFloat(f32, part) catch break;
            count += 1;
        }
        if (count == 4 and numbers[2] > 0 and numbers[3] > 0) return .{ .width = width orelse numbers[2], .height = height orelse numbers[3] };
    }
    return .{ .width = width orelse 24, .height = height orelse 24 };
}

/// A plain or `px` length; null for none, percentages and other units.
fn length(text: ?[]const u8) ?f32 {
    var value = std.mem.trim(u8, text orelse return null, " \t\r\n");
    if (std.mem.endsWith(u8, value, "px")) value = value[0 .. value.len - 2];
    const number = std.fmt.parseFloat(f32, value) catch return null;
    return if (number > 0 and std.math.isFinite(number)) number else null;
}

test "lengths and natural sizes" {
    try std.testing.expectEqual(@as(?f32, 12), length("12px"));
    try std.testing.expectEqual(@as(?f32, null), length("50%"));
    const document = try svg.Document.parse(std.testing.allocator, "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 40 20'><rect width='40' height='20'/></svg>", .{});
    defer document.close() catch {};
    try std.testing.expectEqual(view.Size{ .width = 40, .height = 20 }, try naturalSize(document));
}

test "every icon prepares a mask, mirrored or not" {
    for (std.meta.tags(view.Icon)) |icon| for ([_]bool{ false, true }) |mirrored| {
        const prepared = try prepareIcon(std.testing.allocator, .{ .icon = icon, .width = 30, .height = 30, .scale = 1.5, .mirrored = mirrored });
        defer prepared.close() catch {};
        const shown = try prepared.view();
        try std.testing.expect(shown.coverage.width > 0 and shown.coverage.height > 0);
        var any: bool = false;
        for (shown.coverage.pixels) |value| any = any or value != 0;
        try std.testing.expect(any);
    };
    // Mirroring a chevron moves the ends of its arms to the other side.
    const plain = try prepareIcon(std.testing.allocator, .{ .icon = .chevron_right, .width = 24, .height = 24, .scale = 1, .mirrored = false });
    defer plain.close() catch {};
    const flipped = try prepareIcon(std.testing.allocator, .{ .icon = .chevron_right, .width = 24, .height = 24, .scale = 1, .mirrored = true });
    defer flipped.close() catch {};
    const a = (try plain.view()).coverage;
    const b = (try flipped.view()).coverage;
    // Pixel columns 9 and 14 mirror each other across the 24 pixel square.
    try std.testing.expect(ink(a, 9, 7) > 128 and ink(a, 14, 7) < 64);
    try std.testing.expect(ink(b, 14, 7) > 128 and ink(b, 9, 7) < 64);
}

/// Coverage of the pixel at grid `x`, `y` (scale 1).
fn ink(c: vector.drawing.Coverage, x: i32, y: i32) u8 {
    const column = x - c.origin_x;
    const row = y - c.origin_y;
    if (column < 0 or column >= c.width or row < 0 or row >= c.height) return 0;
    return c.pixels[@as(usize, @intCast(row)) * c.stride + @as(usize, @intCast(column))];
}
