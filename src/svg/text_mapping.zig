const std = @import("std");
const v = @import("ziggurat_vector");
pub const Path = v.Path;

pub const Range = struct { start: usize, count: usize };
pub const Source = struct { start: usize, end: usize };
pub const Glyph = struct { commands: Range, cluster: usize, pen: v.Point, advance: f64, cell: v.Bounds };
pub const Cluster = struct { source: Source, glyphs: Range, commands: Range, bidi_level: u32 };
pub const Owned = struct { path: *v.Path, source: []u8, glyphs: []Glyph, clusters: []Cluster };
pub const View = struct { path: *v.Path, source: []const u8, glyphs: []const Glyph, clusters: []const Cluster };

/// Independent monochrome geometry and original UTF-8 cluster ownership.
/// All arrays, path and shell use one explicit allocator. Ranges address only
/// this path; they never address the accompanying Result batch path.
/// Glyphs and clusters partition this path in the provider's original glyph
/// paint order. Source ranges can run in either direction; callers must not
/// sort outlines by source byte, pen position or geometry before painting.
pub const Mapping = opaque {
    /// Takes all payload ownership only on success. No array is copied.
    pub fn adopt(allocator: std.mem.Allocator, owned: Owned) !*Mapping {
        try owned.path.checkOwner();
        if (owned.path.allocator.ptr != allocator.ptr or owned.path.allocator.vtable != allocator.vtable) return error.InvalidTextProviderAllocator;
        const state = try allocator.create(State);
        state.* = .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .owned = owned };
        return @ptrCast(state);
    }
    /// Borrowed exclusively during preparation, ending at close/takePath.
    pub fn view(self: *Mapping) !View {
        const state = cast(self);
        try state.check();
        return .{ .path = state.owned.path, .source = state.owned.source, .glyphs = state.owned.glyphs, .clusters = state.owned.clusters };
    }
    pub fn close(self: *Mapping) !void {
        const state = cast(self);
        try state.check();
        release(state, false);
    }
    /// Consumes metadata/source/shell and transfers the independent Path.
    pub fn takePath(self: *Mapping) !*v.Path {
        const state = cast(self);
        try state.check();
        const path = state.owned.path;
        release(state, true);
        return path;
    }
};
const State = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    owned: Owned,
    closing: bool = false,
    fn check(self: *State) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.closing) return error.Closed;
    }
};
fn cast(value: *Mapping) *State {
    return @ptrCast(@alignCast(value));
}
fn release(state: *State, keep_path: bool) void {
    state.closing = true;
    const a = state.allocator;
    const owned = state.owned;
    a.free(owned.source);
    a.free(owned.glyphs);
    a.free(owned.clusters);
    if (!keep_path) owned.path.close() catch unreachable;
    a.destroy(state);
}
