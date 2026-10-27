//! Pixels an application computes, such as a simulation drawn on the CPU,
//! shown as an image that changes every frame. Write the next picture into
//! `pixels`, premultiplied BGRA rows from the top, then `commit` it outside
//! paint; paint draws the committed picture with `Frame.image(…, view())`.
//!
//! Two buffers take turns, so the picture a frame draws is never the one
//! being written. A commit uploads the first picture into the renderers'
//! dynamic storage and updates it in place after that.
const std = @import("std");
const drawing = @import("ziggurat_drawing_resources");

/// Main-thread only. Keep it at a stable address while committed.
pub const PixelImage = struct {
    allocator: std.mem.Allocator,
    lease: drawing.Lease,
    width: u32,
    height: u32,
    buffers: [2][]u8,
    levels: [2][1]drawing.ImageLevel = undefined,
    identities: [2]u64 = .{ 0, 0 },
    /// The buffer `pixels` writes, the other one being committed.
    back: u1 = 0,
    /// The identity the renderers hold, once a commit uploaded it.
    committed: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !PixelImage {
        if (width == 0 or height == 0 or width > 16384 or height > 16384 or @as(u64, width) * height > 16 * 1024 * 1024) return error.InvalidImageResource;
        const bytes = @as(usize, width) * height * 4;
        const first = try allocator.alloc(u8, bytes);
        errdefer allocator.free(first);
        const second = try allocator.alloc(u8, bytes);
        @memset(first, 0);
        @memset(second, 0);
        return .{ .allocator = allocator, .lease = drawing.Lease.init(std.Thread.getCurrentId()), .width = width, .height = height, .buffers = .{ first, second } };
    }

    /// Releases the pixels; the renderers must no longer hold them, so
    /// call `release` first while a window still shows them.
    pub fn deinit(self: *PixelImage) void {
        for (self.buffers) |buffer| self.allocator.free(buffer);
        self.* = undefined;
    }

    /// The buffer to write the next picture into.
    pub fn pixels(self: *PixelImage) []u8 {
        return self.buffers[self.back];
    }

    /// The committed picture, or null before the first commit.
    pub fn view(self: *PixelImage) ?drawing.ImageView {
        if (self.committed == null) return null;
        const front = self.back ^ 1;
        return .{ .lease = &self.lease, .identity = self.identities[front], .levels = &self.levels[front] };
    }

    /// Shows the picture written into `pixels` from the next paint on, in
    /// `context`, a `ui.Context` attached to a window. Call it outside
    /// paint, such as in a task posted after it.
    pub fn commit(self: *PixelImage, context: anytype) !void {
        const index = self.back;
        const identity = drawing.reserveRasterIdentity() catch return error.ImageIdentityExhausted;
        self.levels[index] = .{.{ .pixels = self.buffers[index].ptr, .byte_len = self.buffers[index].len, .width = self.width, .height = self.height, .stride = self.width * 4 }};
        self.identities[index] = identity;
        const next: drawing.ImageView = .{ .lease = &self.lease, .identity = identity, .levels = &self.levels[index] };
        if (self.committed) |old| {
            context.updateImage(old, next) catch |err| switch (err) {
                // Evicted under the image budget: upload it again.
                error.ImageNotUploaded => try context.uploadDynamicImage(next),
                else => return err,
            };
        } else try context.uploadDynamicImage(next);
        self.committed = identity;
        self.back ^= 1;
    }

    /// Lets the renderers drop the picture, as before `deinit`.
    pub fn release(self: *PixelImage, context: anytype) void {
        const identity = self.committed orelse return;
        _ = context.releaseImage(identity) catch {};
        self.committed = null;
    }
};

test "pictures take turns between two buffers" {
    var image = try PixelImage.init(std.testing.allocator, 2, 3);
    defer image.deinit();
    try std.testing.expectEqual(@as(usize, 24), image.pixels().len);
    try std.testing.expect(image.view() == null);
    const Uploads = struct {
        held: ?u64 = null,
        uploads: usize = 0,
        fn uploadDynamicImage(self: *@This(), next: drawing.ImageView) !void {
            try next.validate();
            self.held = next.identity;
            self.uploads += 1;
        }
        fn updateImage(self: *@This(), old: u64, next: drawing.ImageView) !void {
            if (self.held != old) return error.ImageNotUploaded;
            try next.validate();
            self.held = next.identity;
        }
        fn releaseImage(self: *@This(), identity: u64) !bool {
            if (self.held != identity) return false;
            self.held = null;
            return true;
        }
    };
    var context: Uploads = .{};
    const first = image.pixels();
    first[0] = 7;
    try image.commit(&context);
    try std.testing.expect(image.pixels().ptr != first.ptr);
    try std.testing.expectEqual(@as(u8, 7), image.view().?.levels[0].pixels[0]);
    try image.commit(&context);
    try std.testing.expect(image.view().?.levels[0].pixels != first.ptr and image.pixels().ptr == first.ptr);
    try std.testing.expectEqual(context.held.?, image.view().?.identity);
    // An evicted picture is uploaded again.
    context.held = null;
    try image.commit(&context);
    try std.testing.expectEqual(@as(usize, 2), context.uploads);
    image.release(&context);
    try std.testing.expect(context.held == null and image.view() == null);
    try std.testing.expectError(error.InvalidImageResource, PixelImage.init(std.testing.allocator, 0, 1));
}
