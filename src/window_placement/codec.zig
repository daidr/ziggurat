const std = @import("std");
const m = @import("model.zig");
pub const version: u16 = 1;
pub const header_bytes = 16;
pub const record_bytes = 240;
pub const max_bytes = header_bytes + m.max_entries * record_bytes;

fn put(comptime T: type, output: []u8, offset: *usize, value: T) void {
    std.mem.writeInt(T, output[offset.*..][0..@sizeOf(T)], value, .little);
    offset.* += @sizeOf(T);
}
fn get(comptime T: type, input: []const u8, offset: *usize) T {
    const value = std.mem.readInt(T, input[offset.*..][0..@sizeOf(T)], .little);
    offset.* += @sizeOf(T);
    return value;
}
fn putKey(output: []u8, offset: *usize, key: m.Key) void {
    output[offset.*] = key.len;
    offset.* += 1;
    @memcpy(output[offset.*..][0..key.len], key.bytes[0..key.len]);
    offset.* += key.bytes.len;
}
fn getKey(input: []const u8, offset: *usize) !m.Key {
    const len = input[offset.*];
    offset.* += 1;
    if (len == 0 or len > 96 or !std.mem.allEqual(u8, input[offset.* + len ..][0 .. 96 - len], 0)) return error.InvalidEncoding;
    const key = m.Key.init(input[offset.*..][0..len]) catch return error.InvalidEncoding;
    offset.* += 96;
    return key;
}
pub fn encodedSize(count: usize) !usize {
    if (count > m.max_entries) return error.CapacityExceeded;
    return header_bytes + record_bytes * count;
}
/// Capacity and semantic failures do not write any output byte.
pub fn encode(store: *const m.Store, output: []u8) ![]const u8 {
    const size = try encodedSize(store.count);
    if (output.len < size) return error.OutputTooSmall;
    for (store.items(), 0..) |entry, at| {
        try entry.key.validate();
        try entry.state.validate();
        for (store.items()[0..at]) |previous| if (previous.key.eql(entry.key)) return error.DuplicateKey;
    }
    @memset(output[0..size], 0);
    @memcpy(output[0..4], "ZGWP");
    var offset: usize = 4;
    put(u16, output, &offset, version);
    put(u16, output, &offset, record_bytes);
    put(u16, output, &offset, @intCast(store.count));
    offset = header_bytes;
    for (store.items()) |entry| {
        putKey(output, &offset, entry.key);
        putKey(output, &offset, entry.state.display);
        put(u8, output, &offset, @intFromEnum(entry.state.space));
        put(u8, output, &offset, @as(u8, @intFromBool(entry.state.maximized)) | @as(u8, @intFromBool(entry.state.fullscreen)) << 1 | @as(u8, @intFromBool(entry.state.always_on_top)) << 2);
        offset += 2;
        put(i32, output, &offset, entry.state.normal.position.x);
        put(i32, output, &offset, entry.state.normal.position.y);
        put(u32, output, &offset, entry.state.normal.width);
        put(u32, output, &offset, entry.state.normal.height);
        put(i32, output, &offset, entry.state.work.x);
        put(i32, output, &offset, entry.state.work.y);
        put(u32, output, &offset, entry.state.work.width);
        put(u32, output, &offset, entry.state.work.height);
        put(u64, output, &offset, @bitCast(entry.state.units_per_dip));
        offset += 2;
    }
    std.debug.assert(offset == size);
    std.mem.writeInt(u32, output[12..16], std.hash.Crc32.hash(output[header_bytes..size]), .little);
    return output[0..size];
}
/// Strict version/length/checksum/semantic validation precedes the one store
/// publication. Corruption, duplicate keys and capacity preserve the old store.
pub fn decode(store: *m.Store, input: []const u8) !void {
    if (input.len < header_bytes or input.len > max_bytes or !std.mem.eql(u8, input[0..4], "ZGWP")) return error.InvalidEncoding;
    var offset: usize = 4;
    if (get(u16, input, &offset) != version) return error.UnsupportedVersion;
    if (get(u16, input, &offset) != record_bytes) return error.InvalidEncoding;
    const count = get(u16, input, &offset);
    if (get(u16, input, &offset) != 0 or try encodedSize(count) != input.len) return error.InvalidEncoding;
    if (get(u32, input, &offset) != std.hash.Crc32.hash(input[header_bytes..])) return error.InvalidChecksum;
    if (count > store.storage.len) return error.CapacityExceeded;
    var candidate: [m.max_entries]m.Entry = undefined;
    for (candidate[0..count], 0..) |*entry, at| {
        const key = try getKey(input, &offset);
        const display = try getKey(input, &offset);
        const space = std.enums.fromInt(m.Space, get(u8, input, &offset)) orelse return error.InvalidEncoding;
        const flags = get(u8, input, &offset);
        if (flags & ~@as(u8, 7) != 0 or get(u16, input, &offset) != 0) return error.InvalidEncoding;
        const x = get(i32, input, &offset);
        const y = get(i32, input, &offset);
        const width = get(u32, input, &offset);
        const height = get(u32, input, &offset);
        const wx = get(i32, input, &offset);
        const wy = get(i32, input, &offset);
        const ww = get(u32, input, &offset);
        const wh = get(u32, input, &offset);
        const scale: f64 = @bitCast(get(u64, input, &offset));
        if (get(u16, input, &offset) != 0) return error.InvalidEncoding;
        entry.* = .{ .key = key, .state = .{ .space = space, .normal = .{ .position = .{ .x = x, .y = y }, .width = width, .height = height }, .work = .{ .x = wx, .y = wy, .width = ww, .height = wh }, .display = display, .units_per_dip = scale, .maximized = flags & 1 != 0, .fullscreen = flags & 2 != 0, .always_on_top = flags & 4 != 0 } };
        entry.state.validate() catch return error.InvalidEncoding;
        for (candidate[0..at]) |previous| if (previous.key.eql(key)) return error.DuplicateKey;
    }
    @memcpy(store.storage[0..count], candidate[0..count]);
    store.count = count;
}
