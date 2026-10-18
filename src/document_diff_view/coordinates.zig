const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const editing = @import("ziggurat_document_editor");

pub const Record = struct {
    stamp: editing.PresentationLease.Stamp,
    bounds: ui.Rect,
    columns: [2]ui.Rect,
    scale: f32,
};
/// Fixed geometry metadata only. Text/layout/native mappings keep their
/// existing owners. Two POD slots preserve an accepted front and one candidate.
pub const State = struct {
    lease: editing.PresentationLease = .{},
    id: u64,
    context: ?*ui.Context = null,
    space: ?ui.SpaceBinding = null,
    records: [2]?Record = @splat(null),

    pub fn accepted(self: *const State) !Record {
        const current = try self.lease.snapshot();
        for (self.records) |stored| if (stored) |value| {
            if (std.meta.eql(value.stamp, current.stamp)) return value;
        };
        // A superseded scratch can never lend its coordinates to another
        // publication, including an outer continuation after nested work.
        return error.StalePresentation;
    }
    pub fn record(self: *State, value: Record) void {
        var accepted_slot: ?usize = null;
        if (self.lease.snapshot()) |current| {
            for (self.records, 0..) |item, at| if (item) |stored| {
                if (std.meta.eql(stored.stamp, current.stamp)) accepted_slot = at;
            };
        } else |_| {}
        self.records[if (accepted_slot) |at| 1 - at else 0] = value;
        self.lease.offer(value.stamp);
    }
    pub fn candidateSpace(self: *const State, window: z.Window, token: ui.SpaceToken) !ui.SpaceBinding {
        const current = try self.lease.snapshot();
        _ = try self.accepted();
        if (token.context != self.context or token.id != self.id) return error.ForeignSpace;
        if (token.generation != current.stamp.space_generation) return error.StaleSpace;
        const binding = try token.binding();
        try binding.checkWindow(window);
        if (binding.epoch != current.stamp.space_epoch) return error.StaleSpace;
        if ((try self.lease.snapshot()).generation != current.generation) return error.StalePresentation;
        return binding;
    }
    pub fn resolve(self: *const State, window: z.Window, columns: [2]ui.Rect, scale: f32) !struct { token: ui.SpaceToken, generation: u64 } {
        const current = try self.lease.snapshot();
        const presented = try self.accepted();
        if (!std.meta.eql(presented.columns, columns) or presented.scale != scale) return error.GeometryRequired;
        const space = self.space orelse return error.GeometryRequired;
        try space.checkWindow(window);
        const token = try space.resolve();
        if (token.context != self.context or token.id != self.id or token.generation != current.stamp.space_generation or space.epoch != current.stamp.space_epoch) return error.StaleSpace;
        if ((try self.lease.snapshot()).generation != current.generation) return error.StalePresentation;
        return .{ .token = token, .generation = current.generation };
    }
};

const rectangle: ui.Rect = .{ .x = 2, .y = 4, .width = 200, .height = 100 };
fn sample(candidate: u64) Record {
    return .{ .stamp = .{ .publication = 9, .source = 3, .candidate = candidate, .space_epoch = 4, .space_generation = candidate }, .bounds = rectangle, .columns = @splat(rectangle), .scale = 1 };
}
test "failed candidate preserves accepted metadata and exact publication association" {
    var state: State = .{ .id = 91 };
    const publisher = try state.lease.acquire();
    state.record(sample(1));
    try state.lease.commit(publisher, try state.lease.begin(publisher), sample(1).stamp);
    state.record(sample(2));
    try std.testing.expectEqual(@as(u64, 1), (try state.accepted()).stamp.candidate);
    const next = try state.lease.begin(publisher);
    try state.lease.commit(publisher, next, sample(2).stamp);
    try std.testing.expectEqual(@as(u64, 2), (try state.accepted()).stamp.candidate);
    _ = try state.lease.begin(publisher); // Successful frame missing record.
    try std.testing.expectError(error.GeometryRequired, state.accepted());
}
test "nested scratch never impersonates an outer record or revives old authority" {
    var state: State = .{ .id = 91 };
    const publisher = try state.lease.acquire();
    state.record(sample(1));
    try state.lease.commit(publisher, try state.lease.begin(publisher), sample(1).stamp);
    state.record(sample(2)); // Outer B.
    state.record(sample(3)); // Hypothetical nested C overwrites scratch, fails.
    try std.testing.expectEqual(@as(u64, 1), (try state.accepted()).stamp.candidate);
    try std.testing.expect(!state.lease.candidateMatches(sample(2).stamp));
    _ = try state.lease.begin(publisher); // Publisher must send EMPTY to native.
    try std.testing.expectError(error.GeometryRequired, state.accepted());
    state.record(sample(4));
    try state.lease.commit(publisher, try state.lease.begin(publisher), sample(4).stamp);
    try std.testing.expectEqual(@as(u64, 4), (try state.accepted()).stamp.candidate);
}
