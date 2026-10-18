const ipc = @import("ziggurat_ipc");
const resource = @import("ziggurat_resource_stream");
pub const Params = struct { path: []const u8 };
pub const Service = struct {
    pub const methods = .{ .open = ipc.Method(Params, resource.wire.Summary, resource.wire.Failure, resource.wire.Frame) };
};
