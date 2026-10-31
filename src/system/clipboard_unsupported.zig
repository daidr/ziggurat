const api = @import("clipboard.zig");

pub const supported = false;
pub const BoardState = struct {};
pub const RequestState = struct {};
pub fn open(_: *api.Board) !void {
    return error.UnsupportedCapability;
}
pub fn close(_: *api.Board, _: bool) void {}
pub fn write(_: *api.Board, _: []const api.Entry) !void {
    return error.UnsupportedCapability;
}
pub fn offer(_: *api.Board, _: []const api.Format) !void {
    return error.UnsupportedCapability;
}
pub fn clear(_: *api.Board) !void {
    return error.UnsupportedCapability;
}
pub fn revoke(_: *api.Board) void {}
pub fn start(_: *api.Board, _: *api.Request) !void {
    return error.UnsupportedCapability;
}
pub fn cancel(_: *api.Board, _: *api.Request) void {}
pub fn sinkSet(_: *api.Sink, _: []const u8) !void {
    return error.UnsupportedCapability;
}
