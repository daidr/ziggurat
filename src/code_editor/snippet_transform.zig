const std = @import("std");
pub const regex = @import("snippet_regex.zig");
pub const formatting = @import("snippet_format.zig");
pub const Limits = struct {
    regex: regex.Limits = .{},
    format: formatting.Limits = .{},
    bytes: usize = 4 * 1024 * 1024,
    work: usize = 4 * 1024 * 1024,
    cancellation: ?*const std.atomic.Value(bool) = null,
};
/// Linear immutable compiled transform. Neither native engines nor a scripting
/// environment are used. Keep stable while Runtime explicitly borrows it.
pub const Transform = struct {
    program: regex.Program,
    format: formatting.Format,
    live: bool = true,
    owned_bytes: usize,
    peak_bytes: usize,
    compile_work: usize,
    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, format: []const u8, flags: []const u8, limits: Limits) !Transform {
        if (limits.bytes < @sizeOf(Transform) or limits.bytes > 64 * 1024 * 1024 or limits.work == 0 or limits.work > 128 * 1024 * 1024) return error.InvalidLimits;
        var budget: Budget = .{ .child = allocator, .limit = limits.bytes - @sizeOf(Transform) };
        return compileBudget(pattern, format, flags, limits, &budget) catch |err| return if (err == error.OutOfMemory and budget.denied) error.CapacityExceeded else err;
    }
    fn compileBudget(pattern: []const u8, format: []const u8, flags: []const u8, limits: Limits, budget: *Budget) !Transform {
        var regex_limits = limits.regex;
        regex_limits.cancellation = limits.cancellation;
        regex_limits.work = @min(regex_limits.work, limits.work);
        var program = try regex.Program.compile(budget.allocator(), pattern, flags, regex_limits);
        errdefer program.deinit() catch unreachable;
        var format_limits = limits.format;
        format_limits.cancellation = limits.cancellation;
        if (program.compile_work >= limits.work) return error.WorkExceeded;
        format_limits.work = @min(format_limits.work, limits.work - program.compile_work);
        var parsed = try formatting.Format.compile(budget.allocator(), format, format_limits);
        errdefer parsed.deinit() catch unreachable;
        var final_work: regex.Work = .{ .limit = limits.work, .cancellation = limits.cancellation };
        try final_work.charge(0);
        // After both candidates succeed, all persistent allocations are moved
        // off the stack budget adapter before returning their owning shells.
        program.allocator = budget.child;
        parsed.allocator = budget.child;
        return .{ .program = program, .format = parsed, .owned_bytes = @sizeOf(Transform) + budget.live, .peak_bytes = @sizeOf(Transform) + budget.peak, .compile_work = program.compile_work + parsed.compile_work };
    }
    pub fn deinit(self: *Transform) !void {
        if (self.program.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (!self.live) return error.Closed;
        if (self.program.clients != 0) return error.ClientsAlive;
        self.live = false;
        try self.program.deinit();
        try self.format.deinit();
    }
};
pub const RuntimeLimits = struct {
    instructions: usize = 128,
    captures: usize = 16,
    input_bytes: usize = 16384,
    result_bytes: usize = 16384,
    /// Workspace only; the enclosing Session also charges its own metadata and
    /// aggregate result buffer against the caller's total byte limit.
    bytes: usize = 64 * 1024 * 1024,
    fn workspace(self: RuntimeLimits) regex.WorkspaceLimits {
        return .{ .instructions = self.instructions, .captures = self.captures, .input_bytes = self.input_bytes, .bytes = self.bytes };
    }
};
/// Explicit fixed workspace, allocated once. applyInto allocates nothing and
/// builds exactly one table for all matches of a global replacement.
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    workspace: regex.Workspace,
    output: []u16,
    limits: RuntimeLimits,
    owned_bytes: usize,
    live: bool = true,
    pub fn requiredBytes(limits: RuntimeLimits) !usize {
        if (limits.result_bytes > 16 * 1024 * 1024) return error.InvalidLimits;
        const workspace_bytes = try regex.Workspace.requiredBytes(limits.workspace());
        const output_bytes = std.math.mul(usize, limits.result_bytes, 2) catch return error.CapacityExceeded;
        const bytes = std.math.add(usize, workspace_bytes, @sizeOf(Runtime) - @sizeOf(regex.Workspace)) catch return error.CapacityExceeded;
        const total = std.math.add(usize, bytes, output_bytes) catch return error.CapacityExceeded;
        if (total > limits.bytes) return error.CapacityExceeded;
        return total;
    }
    pub fn init(allocator: std.mem.Allocator, limits: RuntimeLimits) !Runtime {
        const bytes = try requiredBytes(limits);
        var workspace = try regex.Workspace.init(allocator, limits.workspace());
        errdefer workspace.deinit() catch unreachable;
        const output = try allocator.alloc(u16, limits.result_bytes);
        return .{ .allocator = allocator, .workspace = workspace, .output = output, .limits = limits, .owned_bytes = bytes };
    }
    pub fn deinit(self: *Runtime) !void {
        if (self.workspace.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (!self.live) return error.Closed;
        if (self.workspace.active) return error.Busy;
        self.live = false;
        const output = self.output;
        self.output = &.{};
        try self.workspace.deinit();
        self.allocator.free(output);
    }
    /// destination is changed only after the complete UTF16 candidate validates
    /// and fits. The returned UTF8 slice borrows destination, never input.
    pub fn applyInto(self: *Runtime, transform: *const Transform, input: []const u8, destination: []u8, work: *regex.Work) ![]const u8 {
        if (self.workspace.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (transform.program.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (!self.live or !transform.live) return error.Closed;
        var cursor = try self.workspace.begin(@constCast(&transform.program), input, work);
        defer cursor.end();
        var output: formatting.Output = .{ .buffer = self.output };
        const units = self.workspace.units();
        var previous: usize = 0;
        var matched = false;
        while (try cursor.next()) |match| {
            matched = true;
            try output.append(units[previous..match.range.start], work);
            try transform.format.append(&output, units, match, work);
            previous = match.range.end;
        }
        if (!matched and transform.format.fallback) {
            try transform.format.append(&output, units, null, work);
        } else try output.append(units[previous..], work);
        return output.utf8Into(destination[0..@min(destination.len, self.limits.result_bytes)], work);
    }
};
const Budget = struct {
    child: std.mem.Allocator,
    limit: usize,
    live: usize = 0,
    peak: usize = 0,
    denied: bool = false,
    fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, bytes: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        if (bytes > self.limit -| self.live) {
            self.denied = true;
            return null;
        }
        const result = self.child.rawAlloc(bytes, alignment, ret) orelse return null;
        self.live += bytes;
        self.peak = @max(self.peak, self.live);
        return result;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        self.child.rawFree(bytes, alignment, ret);
        self.live -= bytes.len;
    }
};
fn expectTransform(pattern: []const u8, format: []const u8, flags: []const u8, input: []const u8, expected: []const u8) !void {
    var transform = try Transform.compile(std.testing.allocator, pattern, format, flags, .{});
    defer transform.deinit() catch unreachable;
    var runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit() catch unreachable;
    var work: regex.Work = .{ .limit = 4 * 1024 * 1024 };
    var output: [16384]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try runtime.applyInto(&transform, input, &output, &work));
}
test "transform replaces globally with exact no-match and zero-width semantics" {
    try expectTransform("(.*)\\..+$", "$1", "", "foo.ts", "foo");
    try expectTransform("([a-z]+)", "${1:/upcase}", "g", "a-b cat", "A-B CAT");
    try expectTransform("x", "replacement", "g", "a", "a");
    try expectTransform("x", "${1:?yes:}", "g", "a", "a");
    try expectTransform("x", "pre-${1:-fallback}-post", "g", "a", "pre-fallback-post");
    try expectTransform("(x)?y", "${1:?yes:no}", "g", "yxy", "noyes");
    try expectTransform("", "-", "g", "ab", "-a-b-");
    try expectTransform("", "-", "gu", "😀", "-😀-");
    try expectTransform("(.)", "$1", "g", "😀", "😀");
    try std.testing.expectError(error.UnsupportedSurrogateResult, expectTransform("", "-", "g", "😀", ""));
    try std.testing.expectError(error.UnsupportedSurrogateResult, expectTransform("(.)", "", "", "😀", ""));
}
fn candidate(allocator: std.mem.Allocator) !void {
    var transform = try Transform.compile(allocator, "(a|aa)+b", "pre-$1${2:-post}", "gu", .{});
    defer transform.deinit() catch unreachable;
    var runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit() catch unreachable;
    var bytes: [64]u8 = undefined;
    var work: regex.Work = .{ .limit = 1024 * 1024 };
    _ = try runtime.applyInto(&transform, "aaaab", &bytes, &work);
}
test "transform aggregate construction OOM and runtime failure keep destination" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, candidate, .{});
    try std.testing.expectError(error.CapacityExceeded, Transform.compile(std.testing.allocator, "(a|aa)+b", "$1", "g", .{ .bytes = @sizeOf(Transform) }));
    var transform = try Transform.compile(std.testing.allocator, ".", "xxxxxxxx", "g", .{});
    defer transform.deinit() catch unreachable;
    var runtime = try Runtime.init(std.testing.allocator, .{ .result_bytes = 8 });
    defer runtime.deinit() catch unreachable;
    var bytes: [8]u8 = @splat(0xaa);
    var work: regex.Work = .{ .limit = 1024 * 1024 };
    try std.testing.expectError(error.OutputCapacityExceeded, runtime.applyInto(&transform, "ab", &bytes, &work));
    try std.testing.expectEqual([_]u8{0xaa} ** 8, bytes);
    work.limit = 1;
    work.used = 0;
    try std.testing.expectError(error.WorkExceeded, runtime.applyInto(&transform, "ab", &bytes, &work));
    try std.testing.expectEqual([_]u8{0xaa} ** 8, bytes);
}

const CancelOnFree = struct {
    child: std.mem.Allocator,
    cancel: *std.atomic.Value(bool),
    target: ?[*]u8 = null,
    target_bytes: usize,
    triggered: bool = false,
    fn allocator(self: *CancelOnFree) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, bytes: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *CancelOnFree = @ptrCast(@alignCast(ptr));
        const allocation = self.child.rawAlloc(bytes, alignment, ret) orelse return null;
        if (self.target == null and bytes == self.target_bytes) self.target = allocation;
        return allocation;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *CancelOnFree = @ptrCast(@alignCast(ptr));
        if (self.target == bytes.ptr) {
            self.triggered = true;
            self.cancel.store(true, .release);
        }
        self.child.rawFree(bytes, alignment, ret);
    }
};
test "compile cancellation from final scratch free closes the already constructed candidate" {
    const pattern = "(ab|cd)+";
    var cancel = std.atomic.Value(bool).init(false);
    // The first regex allocation is the decoded source, retained until the
    // compiled owner exists; freeing it tests the final construction boundary.
    var allocator: CancelOnFree = .{ .child = std.testing.allocator, .cancel = &cancel, .target_bytes = pattern.len * @sizeOf(u32) };
    try std.testing.expectError(error.Cancelled, Transform.compile(allocator.allocator(), pattern, "$1", "g", .{ .cancellation = &cancel }));
    try std.testing.expect(allocator.triggered);
    try std.testing.expectError(error.Cancelled, Transform.compile(std.testing.allocator, pattern, "$1", "g", .{ .cancellation = &cancel }));
}
