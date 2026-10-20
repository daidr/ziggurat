const std = @import("std");
const api = @import("clipboard.zig");

pub const supported = true;
pub const BoardState = struct { handle: ?*anyopaque = null };
pub const RequestState = struct { read: ?*anyopaque = null };

const Item = extern struct { kind: c_int, name: [*]const u8, name_len: usize, data: [*]const u8, len: usize };
const Callbacks = extern struct {
    changed: *const fn (?*anyopaque) callconv(.c) void,
    lost: *const fn (?*anyopaque) callconv(.c) void,
    render: *const fn (?*anyopaque, usize, ?*anyopaque) callconv(.c) c_int,
    read_done: *const fn (?*anyopaque, c_int, ?[*]const u8, usize, u32) callconv(.c) void,
};
extern fn zsc_board_create(owner: *anyopaque, callbacks: *const Callbacks) ?*anyopaque;
extern fn zsc_board_destroy(board: *anyopaque) void;
extern fn zsc_board_write(board: *anyopaque, items: [*]const Item, count: usize) c_int;
extern fn zsc_board_offer(board: *anyopaque, items: [*]const Item, count: usize) c_int;
extern fn zsc_board_revoke(board: *anyopaque) void;
extern fn zsc_read_start(board: *anyopaque, request: *anyopaque, formats: c_int, kind: c_int, name: [*]const u8, name_len: usize) ?*anyopaque;
extern fn zsc_read_cancel(read: *anyopaque) void;
extern fn zsc_sink_set(sink: *anyopaque, data: [*]const u8, len: usize) c_int;
/// Native offers, reads and Board connections still alive, including GTK
/// callbacks that arrive after cancellation.
pub extern fn zsc_resource_count() u32;

const callbacks: Callbacks = .{ .changed = changed, .lost = lost, .render = render, .read_done = readDone };
fn board(owner: ?*anyopaque) *api.Board {
    return @ptrCast(@alignCast(owner.?));
}
fn changed(owner: ?*anyopaque) callconv(.c) void {
    board(owner).changed();
}
fn lost(owner: ?*anyopaque) callconv(.c) void {
    board(owner).ownershipLost();
}
fn render(owner: ?*anyopaque, index: usize, sink: ?*anyopaque) callconv(.c) c_int {
    return @intFromBool(board(owner).render(index, sink.?, false));
}
fn readDone(pointer: ?*anyopaque, status: c_int, data: ?[*]const u8, len: usize, flags: u32) callconv(.c) void {
    const request: *api.Request = @ptrCast(@alignCast(pointer.?));
    request.native.read = null;
    const owner = request.board.?;
    const bytes: []const u8 = if (data) |pointer_data| pointer_data[0..len] else &.{};
    switch (status) {
        0 => owner.completeData(request, bytes),
        1 => owner.complete(request, .unavailable),
        2 => owner.complete(request, .{ .failed = .{ .err = error.ClipboardMalformed } }),
        3 => owner.complete(request, .{ .failed = .{ .err = error.TooManyFiles } }),
        else => owner.complete(request, .{ .formats = .{ .text = flags & 1 != 0, .html = flags & 2 != 0, .png = flags & 4 != 0, .files = flags & 8 != 0 } }),
    }
}

pub fn open(owner: *api.Board) !void {
    owner.native.handle = zsc_board_create(owner, &callbacks) orelse return error.DisplayUnavailable;
}
pub fn close(owner: *api.Board, _: bool) void {
    const handle = owner.native.handle orelse return;
    zsc_board_destroy(handle);
    owner.native.handle = null;
}
fn items(storage: *[api.max_formats]Item, formats: []const api.Format, entries: ?[]const api.Entry) []const Item {
    for (formats, 0..) |item, index| {
        const data = if (entries) |values| values[index].data else "";
        storage[index] = .{ .kind = @intFromEnum(item.kind), .name = item.name.ptr, .name_len = item.name.len, .data = data.ptr, .len = data.len };
    }
    return storage[0..formats.len];
}
pub fn write(owner: *api.Board, entries: []const api.Entry) !void {
    var formats: [api.max_formats]api.Format = undefined;
    for (entries, 0..) |entry, index| formats[index] = entry.format;
    var storage: [api.max_formats]Item = undefined;
    const list = items(&storage, formats[0..entries.len], entries);
    if (zsc_board_write(owner.native.handle.?, list.ptr, list.len) == 0) return error.ClipboardWriteFailed;
}
pub fn offer(owner: *api.Board, formats: []const api.Format) !void {
    var storage: [api.max_formats]Item = undefined;
    const list = items(&storage, formats, null);
    if (zsc_board_offer(owner.native.handle.?, list.ptr, list.len) == 0) return error.ClipboardWriteFailed;
}
pub fn revoke(owner: *api.Board) void {
    zsc_board_revoke(owner.native.handle orelse return);
}
pub fn start(owner: *api.Board, request: *api.Request) !void {
    const formats = request.query == .formats;
    const item: api.Format = if (formats) .{ .kind = .text } else request.format();
    request.native.read = zsc_read_start(owner.native.handle.?, request, @intFromBool(formats), @intFromEnum(item.kind), item.name.ptr, item.name.len) orelse return error.OutOfMemory;
}
pub fn cancel(_: *api.Board, request: *api.Request) void {
    if (request.native.read) |read| zsc_read_cancel(read);
    request.native.read = null;
}
pub fn sinkSet(sink: *api.Sink, data: []const u8) !void {
    if (zsc_sink_set(sink.native, data.ptr, data.len) == 0) return error.EntryTooLarge;
}
