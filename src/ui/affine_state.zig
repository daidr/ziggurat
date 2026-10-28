const std = @import("std");
pub const affine = @import("affine.zig");

pub const max_scopes = 64;
pub const max_clips = 128;
pub const max_hits = 128;
pub const max_captures = 64;
pub const max_semantics = 128;
// A capture may include a different pushOffset inside the same raster scope.
pub const Geometry = affine.GeometryTable(max_scopes + max_captures + 1, max_clips);
pub const Error = affine.Error || error{ Busy, NoFrame, InvalidGeneration, GenerationExhausted, HitsFull, CapturesFull, SemanticsFull, DuplicateSpaceId, StaleSpace, SpaceNotFound, InvalidHit };

/// Small parallel metadata for Input's stable control records. The logical
/// track/button rectangles stay in Input, not in another business state copy.
pub const Hit = struct {
    reference: affine.Ref,
    visible: bool,
    focus_bounds: ?affine.Rect,
};
pub const Capture = struct {
    id: u64,
    /// Stable only across consecutive successful fronts with exact geometry.
    /// Input transactions still use the frame's separate generation.
    geometry_version: u64,
    reference: affine.Ref,
    local_bounds: affine.Rect,
    visible_bounds: ?affine.Rect,
};
pub const Semantic = struct { reference: affine.Ref, local_bounds: affine.Rect };
pub const Checkpoint = struct { geometry: affine.Checkpoint, hits: usize, captures: usize, scopes: usize, semantics: usize };

/// Owning value storage with no heap/native resources. Allocate the enclosing
/// State only when transforms are explicitly prepared; do not inline it into
/// every ordinary Context. References are borrowed from this exact snapshot.
pub const Snapshot = struct {
    geometry: Geometry = .{},
    generation: u64 = 0,
    scope_count: usize = 0,
    hits: [max_hits]Hit = undefined,
    hit_len: usize = 0,
    captures: [max_captures]Capture = undefined,
    capture_len: usize = 0,
    semantics: [max_semantics]Semantic = undefined,
    semantic_len: usize = 0,

    fn reset(self: *Snapshot, generation: u64) void {
        self.geometry.reset();
        self.generation = generation;
        self.scope_count = 0;
        self.hit_len = 0;
        self.capture_len = 0;
        self.semantic_len = 0;
    }
    pub fn checkpoint(self: *const Snapshot) Checkpoint {
        return .{ .geometry = self.geometry.checkpoint(), .hits = self.hit_len, .captures = self.capture_len, .scopes = self.scope_count, .semantics = self.semantic_len };
    }
    pub fn rollback(self: *Snapshot, mark: Checkpoint) Error!void {
        if (mark.hits > self.hit_len or mark.captures > self.capture_len or mark.scopes > self.scope_count or mark.semantics > self.semantic_len) return error.InvalidCheckpoint;
        for (self.hits[0..mark.hits]) |hit| if (!retained(hit.reference, mark.geometry)) return error.InvalidCheckpoint;
        for (self.captures[0..mark.captures]) |item| if (!retained(item.reference, mark.geometry)) return error.InvalidCheckpoint;
        for (self.semantics[0..mark.semantics]) |item| if (!retained(item.reference, mark.geometry)) return error.InvalidCheckpoint;
        try self.geometry.rollback(mark.geometry);
        self.hit_len = mark.hits;
        self.capture_len = mark.captures;
        self.scope_count = mark.scopes;
        self.semantic_len = mark.semantics;
    }
    pub fn noteScope(self: *Snapshot) Error!void {
        if (self.scope_count == max_scopes) return error.SpacesFull;
        self.scope_count += 1;
    }
    pub fn inUse(self: *const Snapshot) bool {
        return self.scope_count != 0 or self.capture_len != 0;
    }
    pub fn addHit(self: *Snapshot, reference: affine.Ref, bounds: affine.Rect, focus_bounds: affine.Rect) Error!void {
        if (self.hit_len == max_hits) return error.HitsFull;
        const visible = (try self.geometry.visibleBounds(reference, bounds)) != null;
        const focus = try self.geometry.visibleBounds(reference, focus_bounds);
        self.hits[self.hit_len] = .{ .reference = reference, .visible = visible, .focus_bounds = focus };
        self.hit_len += 1;
    }
    pub fn hitContains(self: *const Snapshot, index: usize, bounds: affine.Rect, window_point: affine.Point) Error!bool {
        if (index >= self.hit_len) return error.InvalidHit;
        const hit = self.hits[index];
        if (!hit.visible) return false;
        return self.geometry.contains(hit.reference, bounds, window_point);
    }
    /// Capture/drag maps positions outside the visible region as well. The
    /// caller separately decides whether a release still hits the same control.
    pub fn localHitPoint(self: *const Snapshot, index: usize, window_point: affine.Point) Error!affine.Point {
        if (index >= self.hit_len) return error.InvalidHit;
        return (try self.geometry.getSpace(self.hits[index].reference.space)).localPoint(window_point);
    }
    pub fn addCapture(self: *Snapshot, id: u64, reference: affine.Ref, local_bounds: affine.Rect) Error!void {
        for (self.captures[0..self.capture_len]) |item| if (item.id == id) return error.DuplicateSpaceId;
        if (self.capture_len == max_captures) return error.CapturesFull;
        const visible = try self.geometry.visibleBounds(reference, local_bounds);
        self.captures[self.capture_len] = .{ .id = id, .geometry_version = self.generation, .reference = reference, .local_bounds = local_bounds, .visible_bounds = visible };
        self.capture_len += 1;
    }
    pub fn capture(self: *const Snapshot, id: u64) Error!Capture {
        for (self.captures[0..self.capture_len]) |item| if (item.id == id) return item;
        return error.SpaceNotFound;
    }
    pub fn captureContains(self: *const Snapshot, id: u64, window_point: affine.Point) Error!bool {
        const item = try self.capture(id);
        return self.geometry.contains(item.reference, item.local_bounds, window_point);
    }
    pub fn captureSpace(self: *const Snapshot, id: u64) Error!affine.Space {
        return self.geometry.getSpace((try self.capture(id)).reference.space);
    }
    pub fn addSemantic(self: *Snapshot, reference: affine.Ref, local_bounds: affine.Rect) Error!void {
        if (self.semantic_len == max_semantics) return error.SemanticsFull;
        _ = try self.geometry.visibleBounds(reference, local_bounds);
        self.semantics[self.semantic_len] = .{ .reference = reference, .local_bounds = local_bounds };
        self.semantic_len += 1;
    }
};

/// Two fixed snapshots. UI Context supplies a nonwrapping generation from its
/// own lifetime, including release/reprepare. A failed frame never publishes
/// its candidate or invalidates the previous successfully displayed snapshot.
pub const State = struct {
    snapshots: [2]Snapshot = .{ .{}, .{} },
    front: u1 = 0,
    building: bool = false,

    pub fn committed(self: *const State) *const Snapshot {
        return &self.snapshots[self.front];
    }
    pub fn beginFrame(self: *State, next_generation: u64) Error!void {
        if (self.building) return error.Busy;
        if (self.committed().generation == std.math.maxInt(u64)) return error.GenerationExhausted;
        if (next_generation == 0 or next_generation <= self.committed().generation) return error.InvalidGeneration;
        self.snapshots[self.front ^ 1].reset(next_generation);
        self.building = true;
    }
    pub fn pending(self: *State) Error!*Snapshot {
        if (!self.building) return error.NoFrame;
        return &self.snapshots[self.front ^ 1];
    }
    /// Call only once the renderer has successfully committed/presented. This
    /// operation cannot invoke foreign code and performs no fallible allocation.
    pub fn commitFrame(self: *State) Error!u64 {
        if (!self.building) return error.NoFrame;
        const previous = self.committed();
        const next = &self.snapshots[self.front ^ 1];
        for (next.captures[0..next.capture_len]) |*capture| {
            capture.geometry_version = next.generation;
            for (previous.captures[0..previous.capture_len]) |old| {
                if (old.id != capture.id) continue;
                if (old.geometry_version != 0 and old.geometry_version <= previous.generation and std.meta.eql(old.local_bounds, capture.local_bounds) and sameReferenceGeometry(&previous.geometry, old.reference, &next.geometry, capture.reference)) capture.geometry_version = old.geometry_version;
                break;
            }
        }
        self.front ^= 1;
        self.building = false;
        return self.committed().generation;
    }
    pub fn cancelFrame(self: *State) void {
        if (!self.building) return;
        self.snapshots[self.front ^ 1].reset(0);
        self.building = false;
    }
    pub fn lookup(self: *const State, generation: u64, id: u64) Error!Capture {
        if (generation == 0 or generation != self.committed().generation) return error.StaleSpace;
        return self.committed().capture(id);
    }
};

fn sameSpace(a: *const Geometry, ai: affine.SpaceId, b: *const Geometry, bi: affine.SpaceId) bool {
    const av = a.getSpace(ai) catch return false;
    const bv = b.getSpace(bi) catch return false;
    av.to_window.validate() catch return false;
    av.to_local.validate() catch return false;
    bv.to_window.validate() catch return false;
    bv.to_local.validate() catch return false;
    return std.meta.eql(av, bv);
}

/// Exact value comparison of bounded immutable geometry. Numeric table IDs
/// may differ; every forward/inverse matrix and complete clip chain must agree.
/// This establishes continuity only, never permission to use an old snapshot.
pub fn sameReferenceGeometry(a: *const Geometry, ar: affine.Ref, b: *const Geometry, br: affine.Ref) bool {
    if (a.space_len > a.spaces.len or b.space_len > b.spaces.len or a.clip_len > a.clips.len or b.clip_len > b.clips.len) return false;
    if (!sameSpace(a, ar.space, b, br.space)) return false;
    var ac = ar.clip;
    var bc = br.clip;
    var depth: usize = 0;
    while (ac != null or bc != null) {
        if (ac == null or bc == null or depth == affine.max_clip_depth) return false;
        const ax = @backingInt(ac.?);
        const bx = @backingInt(bc.?);
        if (ax >= a.clip_len or bx >= b.clip_len) return false;
        const av = a.clips[ax];
        const bv = b.clips[bx];
        av.bounds.validate() catch return false;
        bv.bounds.validate() catch return false;
        if (av.depth == 0 or av.depth > affine.max_clip_depth or bv.depth == 0 or bv.depth > affine.max_clip_depth) return false;
        if (av.parent) |parent| {
            if (@backingInt(parent) >= ax or a.clips[@backingInt(parent)].depth + @as(usize, 1) != av.depth) return false;
        } else if (av.depth != 1) return false;
        if (bv.parent) |parent| {
            if (@backingInt(parent) >= bx or b.clips[@backingInt(parent)].depth + @as(usize, 1) != bv.depth) return false;
        } else if (bv.depth != 1) return false;
        if (!std.meta.eql(av.bounds, bv.bounds) or !sameSpace(a, av.space, b, bv.space)) return false;
        ac = av.parent;
        bc = bv.parent;
        depth += 1;
    }
    return true;
}

fn retained(reference: affine.Ref, mark: affine.Checkpoint) bool {
    return @backingInt(reference.space) < mark.spaces and (if (reference.clip) |id| @backingInt(id) < mark.clips else true);
}
