const std = @import("std");
const builtin = @import("builtin");
pub const authority = @import("collection_authority.zig");
pub const math = @import("collection_geometry.zig").Geometry(@import("affine.zig"));
pub const WordChange = extern struct { word: u32, reserved: u32 = 0, before: u64, after: u64 };
pub const Row = extern struct { id: u64, incarnation: u64, height: u32, start: u32, len: u32, enabled: u32 };
pub const Identity = extern struct { id: u64, index: u64 };
pub const Store = opaque {};
const Model = opaque {};
pub const Options = struct {
    lists: u32 = 8,
    metadata_bytes: usize = 64 * 1024,
    model_bytes: usize = 128 * 1024 * 1024,
    provider_bytes: usize = 1024 * 1024,
    request_bytes: usize = 1024 * 1024,
};
pub const ModelInfo = extern struct { owner: u64, generation: u64, model: u64, rows: u32, reserved: u32, bytes: usize };
pub const Stats = extern struct {
    metadata: usize,
    physical_models: usize,
    held_models: usize,
    providers: usize,
    requests: usize,
    model_limit: usize,
    provider_limit: usize,
    request_limit: usize,
    capacity: u32,
    reserved: u32,
};
pub const Viewport = extern struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    scroll: f64,
    space: u32 = 0,
    clip: u32 = std.math.maxInt(u32),
    caret: u64 = 0,
    caret_incarnation: u64 = 0,
};

extern fn zua_collection_model_prepare(u64, u64, u64, [*]const Row, [*]const Identity, [*]const u64, u32, [*]const u8, u32, usize, *?*Model) u32;
extern fn zua_collection_model_release(*Model) void;
extern fn zua_collection_model_info(*const Model, *ModelInfo) u32;
extern fn zua_virtuals_metadata_size(u32, *usize) u32;
extern fn zua_virtuals_create(u32, usize, usize, usize, usize, *?*Store) u32;
extern fn zua_virtuals_free(*Store) void;
extern fn zua_virtuals_commit(*anyopaque, *Store) u32;
extern fn zua_virtuals_prepared(*anyopaque) u32;
extern fn zua_virtuals_install(*anyopaque, *const authority.Registration, *Model, u64, [*]const u64, u32) u32;
extern fn zua_virtuals_selection(*anyopaque, *const authority.Registration, u64, u64, u64, [*]const WordChange, u32) u32;
extern fn zua_virtuals_withdraw(*anyopaque, ?*const authority.Registration) void;
extern fn zua_virtuals_begin_frame(*anyopaque) u32;
extern fn zua_virtuals_validate_frame(*anyopaque) u32;
extern fn zua_virtuals_stage(*anyopaque, *const authority.Registration, u64, u64, *const Viewport, *const math.Mapping) u32;
extern fn zua_virtuals_stats(*anyopaque, *Stats) u32;

fn status(value: u32) !void {
    return switch (value) {
        0 => {},
        1 => error.InvalidNativeCollection,
        2 => error.NativeCollectionBudgetExceeded,
        3 => error.OutOfMemory,
        4 => error.StaleNativeCollection,
        5 => error.IdExhausted,
        else => error.InvalidNativeCollectionStatus,
    };
}
pub fn enableMath() void {
    if (comptime builtin.os.tag == .windows) {
        comptime {
            @export(&math.nativeBounds, .{ .name = "zua_collection_row_bounds", .linkage = .strong });
        }
    }
}

/// Native-only immutable preparation. Copies the complete supplied Catalog;
/// the product retains no input or allocator address and can be prepared or
/// released on an explicit caller-managed worker. Copies of this pointer are
/// borrows; close exactly once unless installation succeeds and consumes it.
pub const Prepared = opaque {
    pub fn prepare(input: anytype, budget: usize) !*Prepared {
        if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
        comptime {
            if (@sizeOf(@TypeOf(input.entries[0])) != @sizeOf(Row) or @alignOf(@TypeOf(input.entries[0])) != @alignOf(Row) or
                @sizeOf(@TypeOf(input.ids[0])) != @sizeOf(Identity) or @alignOf(@TypeOf(input.ids[0])) != @alignOf(Identity)) @compileError("immutable collection input ABI mismatch");
        }
        if (input.entries.len > 1_000_000 or input.ids.len != input.entries.len or input.tops.len != input.entries.len + 1 or input.text.len > 8 * 1024 * 1024) return error.InvalidNativeCollection;
        enableMath();
        var model: ?*Model = null;
        try status(zua_collection_model_prepare(input.authority.owner, input.authority.generation, input.authority.model, @ptrCast(input.entries.ptr), @ptrCast(input.ids.ptr), input.tops.ptr, @intCast(input.entries.len), input.text.ptr, @intCast(input.text.len), budget, &model));
        return @ptrCast(model.?);
    }
    pub fn close(self: *Prepared) void {
        if (comptime builtin.os.tag == .windows) zua_collection_model_release(@ptrCast(self));
    }
    pub fn info(self: *const Prepared) !ModelInfo {
        if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
        var result: ModelInfo = undefined;
        try status(zua_collection_model_info(@ptrCast(self), &result));
        return result;
    }
};
pub fn requiredMetadata(options: Options) !usize {
    if (options.lists == 0 or options.lists > 32 or options.metadata_bytes > 256 * 1024 or
        options.model_bytes == 0 or options.model_bytes > 128 * 1024 * 1024 or
        options.provider_bytes == 0 or options.provider_bytes > 256 * 1024 * 1024 or
        options.request_bytes == 0 or options.request_bytes > 16 * 1024 * 1024) return error.InvalidNativeCollectionLimits;
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    var bytes: usize = 0;
    try status(zua_virtuals_metadata_size(options.lists, &bytes));
    if (bytes > options.metadata_bytes) return error.NativeCollectionBudgetExceeded;
    return bytes;
}
pub fn createCandidate(options: Options) !*Store {
    _ = try requiredMetadata(options);
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    enableMath();
    var candidate: ?*Store = null;
    try status(zua_virtuals_create(options.lists, options.metadata_bytes, options.model_bytes, options.provider_bytes, options.request_bytes, &candidate));
    return candidate.?;
}
pub fn freeCandidate(candidate: *Store) void {
    if (comptime builtin.os.tag == .windows) zua_virtuals_free(candidate);
}
pub fn commitCandidate(state: *anyopaque, candidate: *Store) !void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    try status(zua_virtuals_commit(state, candidate));
}
pub fn prepared(state: *anyopaque) bool {
    if (comptime builtin.os.tag != .windows) return false;
    return zua_virtuals_prepared(state) != 0;
}
pub fn stats(state: *anyopaque) !Stats {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    var result: Stats = undefined;
    try status(zua_virtuals_stats(state, &result));
    return result;
}
/// Success consumes the product after the native store has retained it.
/// Failure keeps the product and every existing front/pending publication.
pub fn install(state: *anyopaque, key: anytype, model: *Prepared, revision: u64, bits: []const u64) !void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    if (bits.len > 15_625) return error.InvalidNativeCollection;
    const registration = authority.Registration.from(key);
    try status(zua_virtuals_install(state, &registration, @ptrCast(model), revision, bits.ptr, @intCast(bits.len)));
    model.close();
}
pub fn applySelection(state: *anyopaque, key: anytype, model: u64, patch: anytype) !void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    if (patch.words.len > 15_625) return error.InvalidNativeCollection;
    const registration = authority.Registration.from(key);
    const words: [*]const WordChange = @ptrCast(patch.words.ptr);
    try status(zua_virtuals_selection(state, &registration, model, patch.base, patch.revision, words, @intCast(patch.words.len)));
}
pub fn withdraw(state: *anyopaque, key: anytype) void {
    if (comptime builtin.os.tag == .windows) {
        const registration = authority.Registration.from(key);
        zua_virtuals_withdraw(state, &registration);
    }
}
pub fn clear(state: *anyopaque) void {
    if (comptime builtin.os.tag == .windows) zua_virtuals_withdraw(state, null);
}
pub fn beginFrame(state: *anyopaque) !void {
    if (comptime builtin.os.tag == .windows) try status(zua_virtuals_begin_frame(state));
}
pub fn validateFrame(state: *anyopaque) !void {
    if (comptime builtin.os.tag == .windows) try status(zua_virtuals_validate_frame(state));
}
pub fn stage(state: *anyopaque, key: anytype, model: u64, selection: u64, viewport: Viewport, mapping: *const math.Mapping) !void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const registration = authority.Registration.from(key);
    try status(zua_virtuals_stage(state, &registration, model, selection, &viewport, mapping));
}
comptime {
    if (@sizeOf(Row) != 32 or @sizeOf(Identity) != 16 or @sizeOf(Viewport) != 64 or
        @sizeOf(math.Mapping) != 2200 or @sizeOf(WordChange) != 24) @compileError("native collection product ABI mismatch");
    if (@sizeOf(usize) == 8 and (@sizeOf(ModelInfo) != 40 or @sizeOf(Stats) != 72)) @compileError("native collection budget ABI mismatch");
}

test "native list platform boundary is explicit before allocation or adoption" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try std.testing.expectError(error.UnsupportedPlatform, requiredMetadata(.{}));
    try std.testing.expectError(error.UnsupportedPlatform, createCandidate(.{}));
    try std.testing.expectError(error.InvalidNativeCollectionLimits, createCandidate(.{ .lists = 0 }));
    try std.testing.expectError(error.UnsupportedPlatform, Prepared.prepare(@as(*const anyopaque, undefined), 1024));
}
