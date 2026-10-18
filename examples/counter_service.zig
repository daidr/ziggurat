const ipc = @import("ziggurat_ipc");
pub const Service = struct {
    pub const events = .{
        .changed = ipc.Event(struct { path: []const u8, revision: u32 }),
    };
    pub const methods = .{
        .add = ipc.Method(struct { a: i32, b: i32 }, i32, enum { overflow, denied }, void),
        .watch = ipc.Method(struct { topic: []const u8 }, void, enum { unavailable }, []const u8),
        .ping = ipc.Method(void, struct { ok: bool, label: ?[]const u8 = null }, enum { unavailable }, void),
    };
};
