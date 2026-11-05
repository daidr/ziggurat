//! Browsers: the page's clipboard text. What the app writes goes to the
//! system clipboard as the browser allows a page, and is what the page's
//! copy and cut hand the browser; a paste from the system brings its text,
//! which reads return until the app writes again. Only text crosses: other
//! formats stay on the page's own board, as no other app reads them.
const std = @import("std");
const z = @import("ziggurat");
const api = @import("clipboard.zig");

extern "ziggurat" fn zw_clipboard_write(text: [*]const u8, length: u32) void;
/// The bytes of the page's clipboard text, or -1 when it holds none; past
/// capacity it copies nothing.
extern "ziggurat" fn zw_clipboard_read(destination: [*]u8, capacity: u32) i32;

pub const supported = true;
pub const BoardState = struct {};
pub const RequestState = struct { token: u32 = 0 };

var active: ?*api.Board = null;
var next_token: u32 = 1;
/// What a sink writes into: the page, or a read's destination.
const Target = struct { request: ?*api.Request = null, length: usize = 0, data: []const u8 = &.{} };

pub fn open(board: *api.Board) !void {
    active = board;
}
pub fn close(board: *api.Board, _: bool) void {
    if (active == board) active = null;
}
pub fn write(_: *api.Board, entries: []const api.Entry) !void {
    for (entries) |entry| if (entry.format.kind == .text) {
        zw_clipboard_write(entry.data.ptr, @intCast(entry.data.len));
        return;
    };
    zw_clipboard_write("", 0);
}
pub fn offer(_: *api.Board, _: []const api.Format) !void {}
pub fn clear(_: *api.Board) !void {
    zw_clipboard_write("", 0);
}
pub fn revoke(_: *api.Board) void {}
pub fn start(board: *api.Board, request: *api.Request) !void {
    request.native.token = next_token;
    next_token +%= 1;
    if (next_token == 0) next_token = 1;
    try board.app.post(.{ .context = request, .call = deliver });
}
pub fn cancel(_: *api.Board, request: *api.Request) void {
    request.native.token = 0;
}
pub fn sinkSet(sink: *api.Sink, data: []const u8) !void {
    const target: *Target = @ptrCast(@alignCast(sink.native));
    target.data = data;
    if (target.request == null) zw_clipboard_write(data.ptr, @intCast(data.len));
}

fn offeredText(board: *api.Board) ?usize {
    if (board.provider == null) return null;
    for (board.offered[0..board.offered_count], 0..) |format, index| if (format.kind == .text) return index;
    return null;
}

fn deliver(context: *anyopaque) void {
    const request: *api.Request = @ptrCast(@alignCast(context));
    if (request.native.token == 0) return;
    const board = request.board orelse return;
    request.native.token = 0;
    switch (request.query) {
        .formats => {
            var empty: [0]u8 = .{};
            const text = offeredText(board) != null or zw_clipboard_read(&empty, 0) >= 0;
            board.complete(request, .{ .formats = .{ .text = text } });
        },
        .read => |format| {
            if (format.kind != .text) return board.complete(request, .unavailable);
            if (offeredText(board)) |index| {
                var target: Target = .{ .request = request };
                if (board.render(index, &target, false)) return board.completeData(request, target.data);
                return board.complete(request, .unavailable);
            }
            const length = zw_clipboard_read(request.destination.ptr, @intCast(@min(request.destination.len, std.math.maxInt(u32))));
            if (length < 0) return board.complete(request, .unavailable);
            const bytes: usize = @intCast(length);
            if (bytes > request.destination.len) return board.complete(request, .{ .capacity_exceeded = bytes });
            board.complete(request, .{ .data = request.destination[0..bytes] });
        },
    }
}

/// The page's copy and cut ask for the text an offer holds, so that they
/// hand it to the browser while the event lasts.
fn flush() callconv(.c) void {
    const board = active orelse return;
    const index = offeredText(board) orelse return;
    var target: Target = .{};
    _ = board.render(index, &target, false);
}
comptime {
    if (@import("builtin").cpu.arch == .wasm32) @export(&flush, .{ .name = "ziggurat_clipboard_flush" });
}
