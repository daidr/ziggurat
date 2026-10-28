const std = @import("std");
const s = @import("affine_state");
const a = s.affine;
const bounds: a.Rect = .{ .width = 20, .height = 10 };

fn addVersionedCapture(state: *s.State, id: u64, x: f64, parent_width: f64, local: a.Rect, extra: bool) !void {
    const next = try state.pending();
    if (extra) _ = try next.geometry.addSpace(.{ .x0 = 444 });
    const parent = try next.geometry.addClip(.identity, null, .{ .width = parent_width, .height = 100 });
    const space = try next.geometry.addSpace(.{ .xx = -0.8, .xy = 0.15, .yy = 1.05, .x0 = x, .y0 = 5.25 });
    const clip = try next.geometry.addClip(space, parent, local);
    try next.addCapture(id, .{ .space = space, .clip = clip }, local);
}

test "equal successful capture geometry keeps semantic version while every frame token changes" {
    var state: s.State = .{};
    for (1..9) |frame| {
        try state.beginFrame(frame);
        try addVersionedCapture(&state, 7, 30.375, 200, bounds, frame % 2 == 0);
        _ = try state.commitFrame();
        try std.testing.expectEqual(@as(u64, 1), (try state.lookup(frame, 7)).geometry_version);
        if (frame != 1) try std.testing.expectError(error.StaleSpace, state.lookup(frame - 1, 7));
    }
    try state.beginFrame(9);
    try addVersionedCapture(&state, 7, 40, 100, bounds, false);
    state.cancelFrame();
    try std.testing.expectEqual(@as(u64, 1), (try state.lookup(8, 7)).geometry_version);
}

test "full clips local bounds changed transform and missing capture never revive semantic versions" {
    var state: s.State = .{};
    try state.beginFrame(1);
    try addVersionedCapture(&state, 7, 30, 200, bounds, false);
    _ = try state.commitFrame();
    try state.beginFrame(2);
    // This parent clip does not cut the capture; its policy still changed.
    try addVersionedCapture(&state, 7, 30, 300, bounds, false);
    _ = try state.commitFrame();
    try std.testing.expectEqual(@as(u64, 2), (try state.lookup(2, 7)).geometry_version);
    try state.beginFrame(3);
    try addVersionedCapture(&state, 7, 31, 300, bounds, false);
    _ = try state.commitFrame();
    try std.testing.expectEqual(@as(u64, 3), (try state.lookup(3, 7)).geometry_version);
    try state.beginFrame(4);
    try addVersionedCapture(&state, 7, 30, 200, bounds, false);
    _ = try state.commitFrame();
    try std.testing.expectEqual(@as(u64, 4), (try state.lookup(4, 7)).geometry_version);
    try state.beginFrame(5);
    try addVersionedCapture(&state, 7, 30, 200, .{ .x = 1, .width = 19, .height = 10 }, false);
    _ = try state.commitFrame();
    try std.testing.expectEqual(@as(u64, 5), (try state.lookup(5, 7)).geometry_version);
    try state.beginFrame(6);
    _ = try state.commitFrame();
    try state.beginFrame(7);
    try addVersionedCapture(&state, 7, 30, 200, bounds, false);
    _ = try state.commitFrame();
    try std.testing.expectEqual(@as(u64, 7), (try state.lookup(7, 7)).geometry_version);
}

test "capture continuity stays bounded at maximum captures and full clip depth" {
    var state: s.State = .{};
    for (1..3) |frame| {
        try state.beginFrame(frame);
        const next = try state.pending();
        var parent: ?a.ClipId = null;
        for (0..a.max_clip_depth) |_| parent = try next.geometry.addClip(.identity, parent, bounds);
        for (0..s.max_captures) |id| try next.addCapture(id, .{ .clip = parent }, bounds);
        _ = try state.commitFrame();
    }
    for (state.committed().captures[0..s.max_captures]) |capture| try std.testing.expectEqual(@as(u64, 1), capture.geometry_version);
}

test "exact reference comparison rejects malformed lengths parents and invalid inverse" {
    var first: s.Geometry = .{};
    var other: s.Geometry = .{};
    const clip = try first.addClip(.identity, null, bounds);
    const next = try other.addClip(.identity, null, bounds);
    try std.testing.expect(s.sameReferenceGeometry(&first, .{ .clip = clip }, &other, .{ .clip = next }));
    other.clips[@backingInt(next)].parent = next;
    try std.testing.expect(!s.sameReferenceGeometry(&first, .{ .clip = clip }, &other, .{ .clip = next }));
    other = .{};
    other.space_len = other.spaces.len + 1;
    try std.testing.expect(!s.sameReferenceGeometry(&first, .{}, &other, .{}));
    other = .{};
    other.spaces[0].to_local.xx = 0;
    other.spaces[0].to_local.yy = 0;
    try std.testing.expect(!s.sameReferenceGeometry(&first, .{}, &other, .{}));
}

test "candidate captures publish only with a successful frame" {
    var state: s.State = .{};
    try std.testing.expectError(error.StaleSpace, state.lookup(0, 20));
    try state.beginFrame(1);
    const candidate = try state.pending();
    const child = try candidate.geometry.addSpace(.{ .xx = 2, .x0 = 50 });
    try candidate.addCapture(20, .{ .space = child }, bounds);
    try std.testing.expectError(error.StaleSpace, state.lookup(1, 20));
    try std.testing.expectEqual(@as(u64, 1), try state.commitFrame());
    try std.testing.expectEqual(@as(f64, 50), (try state.lookup(1, 20)).visible_bounds.?.x);
    try state.beginFrame(2);
    try (try state.pending()).addCapture(20, .{}, bounds);
    // The old committed mapping remains available during reentrant input.
    try std.testing.expectEqual(@as(f64, 50), (try state.lookup(1, 20)).visible_bounds.?.x);
    state.cancelFrame();
    try std.testing.expectEqual(@as(u64, 1), state.committed().generation);
    try std.testing.expectEqual(@as(f64, 50), (try state.lookup(1, 20)).visible_bounds.?.x);
    try state.beginFrame(2);
    try (try state.pending()).addCapture(21, .{}, bounds);
    _ = try state.commitFrame();
    try std.testing.expectError(error.StaleSpace, state.lookup(1, 20));
    try std.testing.expectError(error.SpaceNotFound, state.lookup(2, 20));
}

test "generation exhaustion and invalid transitions preserve the front" {
    var state: s.State = .{};
    try std.testing.expectError(error.NoFrame, state.pending());
    try std.testing.expectError(error.NoFrame, state.commitFrame());
    try std.testing.expectError(error.InvalidGeneration, state.beginFrame(0));
    try state.beginFrame(std.math.maxInt(u64));
    try std.testing.expectError(error.Busy, state.beginFrame(1));
    try (try state.pending()).addCapture(1, .{}, bounds);
    _ = try state.commitFrame();
    try std.testing.expectError(error.GenerationExhausted, state.beginFrame(1));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), state.committed().generation);
    _ = try state.lookup(std.math.maxInt(u64), 1);
    state.cancelFrame();
    _ = try state.lookup(std.math.maxInt(u64), 1);
    var ordinary: s.State = .{};
    try ordinary.beginFrame(5);
    _ = try ordinary.commitFrame();
    try std.testing.expectError(error.InvalidGeneration, ordinary.beginFrame(5));
    try std.testing.expectError(error.InvalidGeneration, ordinary.beginFrame(4));
}

test "captured dragging maps offtrack positions without treating them as hits" {
    var snapshot: s.Snapshot = .{};
    const rotated = try snapshot.geometry.addSpace(.{ .xx = 0, .xy = -2, .yx = 3, .yy = 0, .x0 = 100, .y0 = 20 });
    const clip = try snapshot.geometry.addClip(rotated, null, bounds);
    const ref: a.Ref = .{ .space = rotated, .clip = clip };
    try snapshot.addHit(ref, bounds, bounds);
    try snapshot.addCapture(1, ref, bounds);
    const outside: a.Point = .{ .x = 110, .y = 110 };
    try std.testing.expect(!(try snapshot.hitContains(0, bounds, outside)));
    try std.testing.expect(!(try snapshot.captureContains(1, outside)));
    const local = try snapshot.localHitPoint(0, outside);
    try std.testing.expectApproxEqAbs(@as(f64, 30), local.x, 1e-8);
    try std.testing.expectApproxEqAbs(@as(f64, -5), local.y, 1e-8);
    try std.testing.expectEqualDeep(a.Rect{ .x = 80, .y = 20, .width = 20, .height = 60 }, snapshot.hits[0].focus_bounds.?);
    const space = try snapshot.captureSpace(1);
    const caret = try space.windowCaret(.{ .x = 1, .y = 2, .width = 1, .height = 3 });
    try std.testing.expectEqualDeep(a.Rect{ .x = 90, .y = 23, .width = 6, .height = 3 }, caret);
}

test "metadata candidates are transactional under capacity and rollback" {
    var snapshot: s.Snapshot = .{};
    const mark = snapshot.checkpoint();
    const space = try snapshot.geometry.addSpace(.{ .x0 = 5 });
    const clip = try snapshot.geometry.addClip(space, null, bounds);
    const ref: a.Ref = .{ .space = space, .clip = clip };
    try snapshot.addHit(ref, bounds, bounds);
    try snapshot.addCapture(1, ref, bounds);
    try std.testing.expectError(error.InvalidCheckpoint, snapshot.rollback(.{ .geometry = mark.geometry, .hits = 1, .captures = 1, .scopes = 0, .semantics = 0 }));
    try std.testing.expectEqual(@as(usize, 1), snapshot.hit_len);
    try snapshot.rollback(mark);
    try std.testing.expectEqual(@as(usize, 0), snapshot.hit_len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.capture_len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.geometry.space_len);
    for (0..s.max_captures) |index| try snapshot.addCapture(index, .{}, bounds);
    const full = snapshot.checkpoint();
    try std.testing.expectError(error.DuplicateSpaceId, snapshot.addCapture(0, .{}, bounds));
    try std.testing.expectError(error.CapturesFull, snapshot.addCapture(1000, .{}, bounds));
    try std.testing.expectEqualDeep(full, snapshot.checkpoint());
    for (0..s.max_hits) |_| try snapshot.addHit(.{}, bounds, bounds);
    try std.testing.expectError(error.HitsFull, snapshot.addHit(.{}, bounds, bounds));
    try std.testing.expectError(error.InvalidHit, snapshot.localHitPoint(s.max_hits, .{}));
}

test "fully clipped focus is unavailable while copied snapshots stay independent" {
    var snapshot: s.Snapshot = .{};
    const clip = try snapshot.geometry.addClip(.identity, null, .{ .x = 30, .width = 1, .height = 1 });
    try snapshot.addHit(.{ .clip = clip }, bounds, bounds);
    try snapshot.addCapture(1, .{ .clip = clip }, bounds);
    try std.testing.expect(!snapshot.hits[0].visible);
    try std.testing.expect(snapshot.hits[0].focus_bounds == null);
    try std.testing.expect((try snapshot.capture(1)).visible_bounds == null);
    const owned_copy = snapshot;
    snapshot.geometry.reset();
    snapshot.hit_len = 0;
    snapshot.capture_len = 0;
    try std.testing.expect(!(try owned_copy.captureContains(1, .{ .x = 1, .y = 1 })));
    _ = try owned_copy.capture(1);
    try std.testing.expectError(error.SpaceNotFound, snapshot.capture(1));
}

test "accepted transform or captured space retains resources until a plain frame" {
    var state: s.State = .{};
    try state.beginFrame(1);
    const candidate = try state.pending();
    for (0..s.max_scopes) |_| try candidate.noteScope();
    try std.testing.expectError(error.SpacesFull, candidate.noteScope());
    _ = try state.commitFrame();
    try std.testing.expect(state.committed().inUse());
    try state.beginFrame(2);
    state.cancelFrame();
    try std.testing.expect(state.committed().inUse());
    try state.beginFrame(2);
    _ = try state.commitFrame();
    try std.testing.expect(!state.committed().inUse());
    try state.beginFrame(3);
    try (try state.pending()).addCapture(1, .{}, bounds);
    _ = try state.commitFrame();
    try std.testing.expect(state.committed().inUse());
}

test "semantic geometry rolls back with the candidate and stays value owned" {
    var state: s.State = .{};
    try state.beginFrame(1);
    const candidate = try state.pending();
    const mark = candidate.checkpoint();
    const child = try candidate.geometry.addSpace(.{ .x0 = 40 });
    try candidate.addSemantic(.{ .space = child }, bounds);
    try std.testing.expectError(error.InvalidCheckpoint, candidate.rollback(.{ .geometry = mark.geometry, .hits = 0, .captures = 0, .scopes = 0, .semantics = 1 }));
    try candidate.rollback(mark);
    try std.testing.expectEqual(@as(usize, 0), candidate.semantic_len);
    try candidate.addSemantic(.{}, bounds);
    _ = try state.commitFrame();
    try state.beginFrame(2);
    try (try state.pending()).addSemantic(.{}, .{ .width = 1, .height = 1 });
    state.cancelFrame();
    try std.testing.expectEqualDeep(bounds, state.committed().semantics[0].local_bounds);
    var full: s.Snapshot = .{};
    for (0..s.max_semantics) |_| try full.addSemantic(.{}, bounds);
    const full_mark = full.checkpoint();
    try std.testing.expectError(error.SemanticsFull, full.addSemantic(.{}, bounds));
    try std.testing.expectEqualDeep(full_mark, full.checkpoint());
}
