const ipc = @import("ipc");

pub const Service = struct {
    pub const events = .{
        .changed = ipc.Event(struct { path: []const u8, revision: u32 }),
        .reset = ipc.Event(void),
        .status = ipc.Event(enum { idle, busy }),
    };
    pub const methods = .{
        .add = ipc.Method(struct { a: i32, b: i32 }, i32, enum { overflow, denied }, void),
        .watch = ipc.Method(struct { topic: []const u8 }, void, enum { unavailable }, []const u8),
        .ping = ipc.Method(void, struct { ok: bool, label: ?[]const u8 = null }, enum { unavailable }, void),
        .inspect = ipc.Method(struct {
            flag: bool,
            mode: enum { tiny, full },
            weights: [2]f32,
            label: [2]u8,
            names: []const []const u8,
            optional: ?u16 = null,
        }, struct { ok: bool }, enum { denied }, void),
    };
};
