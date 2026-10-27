const std = @import("std");
const zio = @import("ziggurat_io");
const options = @import("ziggurat_image_options");
const Initialization = struct {
    ready: std.atomic.Value(bool) = .init(false),
    mutex: zio.Mutex = .{},
    fn ensure(self: *Initialization, comptime initialize: *const fn () callconv(.c) c_int) c_int {
        if (self.ready.load(.acquire)) return 0;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.ready.load(.acquire)) return 0;
        const status = initialize();
        if (status == 0) self.ready.store(true, .release);
        return status;
    }
};
var initialization: Initialization = .{};
pub const Size = struct { width: u32, height: u32 };
pub fn inspect(bytes: []const u8) !Size {
    if (!options.webp) return error.UnsupportedFormat;
    if (bytes.len < 20 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WEBP")) return error.InvalidImage;
    if (@as(u64, std.mem.readInt(u32, bytes[4..8], .little)) + 8 != bytes.len) return error.InvalidImage;
    var offset: usize = 12;
    while (offset < bytes.len) {
        if (bytes.len - offset < 8) return error.InvalidImage;
        const size: usize = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .little);
        offset += 8;
        if (size > bytes.len - offset) return error.InvalidImage;
        offset += size;
        if (size & 1 != 0) {
            if (offset == bytes.len or bytes[offset] != 0) return error.InvalidImage;
            offset += 1;
        }
    }
    var size: Size = undefined;
    const status = zi_webp_inspect(bytes.ptr, bytes.len, &size.width, &size.height);
    if (status == 256) return error.UnsupportedAnimation;
    if (status != 0) return error.InvalidImage;
    return size;
}
pub fn decode(bytes: []const u8, width: u32, height: u32, storage: []u8) c_int {
    if (!options.webp) unreachable;
    const status = initialization.ensure(zi_webp_initialize);
    if (status != 0) return status;
    return zi_webp_decode(bytes.ptr, bytes.len, width, height, storage.ptr);
}
extern fn zi_webp_initialize() c_int;
extern fn zi_webp_inspect([*]const u8, usize, *u32, *u32) c_int;
extern fn zi_webp_decode([*]const u8, usize, u32, u32, [*]u8) c_int;

test "failed native initialization is not published and the next caller can retry" {
    const Probe = struct {
        var calls: usize = 0;
        fn initialize() callconv(.c) c_int {
            calls += 1;
            return if (calls == 1) 1 else 0;
        }
    };
    Probe.calls = 0;
    var state: Initialization = .{};
    try std.testing.expectEqual(@as(c_int, 1), state.ensure(Probe.initialize));
    try std.testing.expect(!state.ready.load(.acquire));
    try std.testing.expectEqual(@as(c_int, 0), state.ensure(Probe.initialize));
    try std.testing.expectEqual(@as(c_int, 0), state.ensure(Probe.initialize));
    try std.testing.expectEqual(@as(usize, 2), Probe.calls);
}
