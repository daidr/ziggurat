const std = @import("std");

pub const Registration = extern struct {
    epoch: u64,
    serial: u64,
    id: u64,
    slot: u32,
    kind: u32 = 1,
    pub fn from(key: anytype) Registration {
        return .{ .epoch = key.epoch, .serial = key.serial, .id = key.id, .slot = key.slot };
    }
};
pub const RowAuthority = extern struct { owner: u64, generation: u64, model: u64, publication: u64, row: u64, incarnation: u64 };
pub const Kind = enum(u32) { select = 1, add_selection, remove_selection, focus, reveal };
/// Borrow only for the entered synchronous callback. Native storage copies
/// these values at request time; no field borrows a UI model or a Row record.
pub const RowRequest = extern struct {
    authority: RowAuthority,
    kind: u32,
    reserved: u32 = 0,
    pub fn action(self: RowRequest) !Kind {
        if (self.reserved != 0) return error.InvalidCollectionAction;
        return std.meta.intToEnum(Kind, self.kind) catch error.InvalidCollectionAction;
    }
};
comptime {
    if (@sizeOf(Registration) != 32 or @sizeOf(RowAuthority) != 48 or @sizeOf(RowRequest) != 56) @compileError("native collection identity ABI mismatch");
}
