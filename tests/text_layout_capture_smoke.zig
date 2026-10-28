const std = @import("std");
const zio = @import("ziggurat_io");
const t = @import("ziggurat_text_layout");
const ui = @import("ziggurat_ui");
const shaped = @import("ziggurat_shaped_editor");

const Hook = struct {
    child: std.mem.Allocator,
    editor: ?*ui.editor.Editor = null,
    family: ?[]u8 = null,
    locale: ?[]u8 = null,
    trigger: usize = 0,
    allocations: usize = 0,
    hits: usize = 0,
    engine: ?*t.Engine = null,
    raw: ?[]u8 = null,
    invalid: enum { none, utf8, nul } = .none,
    replacement: []const u8 = "ab",
    replace_end: usize = 2,

    fn allocator(self: *Hook) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Hook = @ptrCast(@alignCast(ptr));
        const memory = self.child.rawAlloc(len, alignment, ra) orelse return null;
        self.allocations += 1;
        if (self.allocations == self.trigger) {
            self.hits += 1;
            if (self.engine) |engine| {
                std.testing.expectError(error.Busy, engine.close()) catch unreachable;
                std.testing.expectError(error.Busy, engine.layout("nested", .{})) catch unreachable;
            }
            if (self.editor) |editor| {
                _ = editor.buffer.replaceRange(.{ .start = 0, .end = self.replace_end }, self.replacement) catch unreachable;
                editor.refresh();
                _ = editor.displayText();
            }
            if (self.family) |family| @memcpy(family, "Hack");
            if (self.locale) |locale| @memcpy(locale, "zz");
            if (self.raw) |raw| raw[0] = switch (self.invalid) {
                .utf8 => 0xff,
                .nul => 0,
                .none => unreachable,
            };
        }
        return memory;
    }
    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Hook = @ptrCast(@alignCast(ptr));
        self.child.rawFree(memory, alignment, ra);
    }
};

fn textCapture(allocator: std.mem.Allocator, trigger: usize, adapter_case: bool, reference: bool) !void {
    var editor = try ui.editor.Editor.init(allocator, .{}, "é");
    defer editor.deinit();
    var hook: Hook = .{ .child = allocator };
    const engine = try t.Engine.create(hook.allocator(), std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    hook.allocations = 0;
    hook.trigger = trigger;
    hook.engine = engine;
    hook.editor = &editor;
    if (adapter_case) {
        var adapter = try shaped.Adapter.init(allocator, &editor, engine, .{});
        defer adapter.deinit() catch unreachable;
        try std.testing.expectError(error.LayoutRequired, adapter.prepare(.{ .x = 0, .y = 0, .width = 80, .height = 40 }, .{}));
        try std.testing.expect(adapter.snapshot == null);
        hook.trigger = 0;
        _ = try adapter.prepare(.{ .x = 0, .y = 0, .width = 80, .height = 40 }, .{});
        try std.testing.expectEqualStrings("ab", try adapter.snapshot.?.layout.text());
    } else {
        const layout = if (reference) try engine.layoutReference(editor.displayText(), .{}) else try engine.layout(editor.displayText(), .{});
        defer layout.close() catch unreachable;
        const expected: []const u8 = if (trigger <= 2) "ab" else "é";
        try std.testing.expectEqualStrings(expected, try layout.text());
        const scalars = try std.unicode.utf8CountCodepoints(expected);
        try std.testing.expectEqual(scalars, (try layout.buildStats()).scalar_count);
        try std.testing.expectEqual(scalars, try layout.graphemeCount());
        try std.testing.expectEqual(expected.len, try layout.byteFromUtf16(try layout.utf16FromByte(expected.len)));
    }
    try std.testing.expectEqual(@as(usize, 1), hook.hits);
    try std.testing.expectEqualStrings("ab", editor.displayText());
}

fn optionCapture(allocator: std.mem.Allocator, trigger: usize) !void {
    var family = [_]u8{ 'S', 'a', 'n', 's' };
    var locale = [_]u8{ 'e', 'n' };
    var hook: Hook = .{ .child = allocator };
    const engine = try t.Engine.create(hook.allocator(), std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    hook.allocations = 0;
    hook.trigger = trigger;
    hook.family = &family;
    hook.locale = &locale;
    hook.engine = engine;
    const layout = try engine.layout("abc", .{ .family = &family, .locale = &locale });
    defer layout.close() catch unreachable;
    try std.testing.expectEqual(@as(usize, 1), hook.hits);
    try std.testing.expectEqualStrings("Sans", (try layout.options()).family);
    try std.testing.expectEqualStrings("en", (try layout.options()).locale);
    try std.testing.expectEqualStrings("Hack", &family);
    try std.testing.expectEqualStrings("zz", &locale);
}

fn invalidCapture(allocator: std.mem.Allocator) !void {
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    for ([_]@FieldType(Hook, "invalid"){ .utf8, .nul }) |invalid| {
        for ([_]usize{ 1, 2, 3 }) |trigger| {
            var raw = [_]u8{ 'a', 'b' };
            var hook: Hook = .{ .child = allocator, .raw = &raw, .invalid = invalid, .trigger = trigger, .engine = engine };
            const result = engine.layoutAllocated(hook.allocator(), &raw, .{});
            if (trigger <= 2) {
                if (invalid == .utf8) try std.testing.expectError(error.InvalidUtf8, result) else try std.testing.expectError(error.EmbeddedNul, result);
            } else {
                const layout = try result;
                defer layout.close() catch unreachable;
                try std.testing.expectEqualStrings("ab", try layout.text());
                try std.testing.expectEqual(@as(usize, 2), (try layout.buildStats()).scalar_count);
            }
            try std.testing.expectEqual(@as(usize, 1), hook.hits);
        }
    }
    // Option bytes are captured even when their caller alias becomes invalid.
    for ([_]bool{ false, true }) |font| {
        var raw = [_]u8{ 'e', 'n' };
        var hook: Hook = .{ .child = allocator, .raw = &raw, .invalid = .nul, .trigger = 1, .engine = engine };
        const layout = try engine.layoutAllocated(hook.allocator(), "x", if (font) .{ .family = &raw } else .{ .locale = &raw });
        defer layout.close() catch unreachable;
        try std.testing.expectEqualStrings("en", if (font) (try layout.options()).family else (try layout.options()).locale);
    }
}

fn byteBudgets(allocator: std.mem.Allocator) !void {
    var hook: Hook = .{ .child = allocator };
    const small = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{ .layout_bytes = 1024 });
    defer small.close() catch unreachable;
    const before = t.resourceCounts();
    try std.testing.expectError(error.LayoutByteCapacityExceeded, small.layoutAllocated(hook.allocator(), &@as([2048]u8, @splat('x')), .{}));
    try std.testing.expectEqual(@as(usize, 0), hook.allocations);
    try std.testing.expectEqual(before, t.resourceCounts());

    const bounded = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{ .layout_bytes = 4096 });
    defer bounded.close() catch unreachable;
    const bounded_before = t.resourceCounts();
    try std.testing.expectError(error.LayoutByteCapacityExceeded, bounded.layoutAllocated(hook.allocator(), &@as([512]u8, @splat('x')), .{}));
    // Only the State and sole UTF-8 copy exist before the exact count check.
    try std.testing.expectEqual(@as(usize, 2), hook.allocations);
    try std.testing.expectEqual(bounded_before, t.resourceCounts());
    hook.allocations = 0;
    try std.testing.expectError(error.TextCapacityExceeded, bounded.layoutAllocated(hook.allocator(), &@as([65537]u8, @splat('x')), .{}));
    try std.testing.expectEqual(@as(usize, 0), hook.allocations);
    try std.testing.expectError(error.InvalidUtf8, bounded.layoutAllocated(hook.allocator(), "x", .{ .family = "\xff" }));
    try std.testing.expectError(error.EmbeddedNul, bounded.layoutAllocated(hook.allocator(), "x", .{ .locale = "a\x00" }));
    try std.testing.expectError(error.InvalidOptions, bounded.layoutAllocated(hook.allocator(), "x", .{ .family = &@as([256]u8, @splat('a')) }));
    try std.testing.expectError(error.InvalidOptions, bounded.layoutAllocated(hook.allocator(), "x", .{ .locale = &@as([128]u8, @splat('a')) }));
    try std.testing.expectEqual(@as(usize, 0), hook.allocations);

    var editor = try ui.editor.Editor.init(allocator, .{}, &@as([512]u8, @bitCast(@as([256][2]u8, @splat("é".*)))));
    defer editor.deinit();
    hook.editor = &editor;
    hook.replace_end = 512;
    hook.replacement = &@as([512]u8, @splat('a'));
    hook.engine = bounded;
    hook.trigger = 1;
    try std.testing.expectError(error.LayoutByteCapacityExceeded, bounded.layoutAllocated(hook.allocator(), editor.displayText(), .{}));
    try std.testing.expectEqual(@as(usize, 1), hook.hits);
    try std.testing.expectEqual(@as(usize, 2), hook.allocations);
    try std.testing.expectEqual(bounded_before, t.resourceCounts());
}

fn failures(allocator: std.mem.Allocator) !void {
    const Scenario = struct {
        fn run(candidate: std.mem.Allocator) !void {
            const engine = try t.Engine.create(candidate, std.Thread.getCurrentId(), .{});
            defer engine.close() catch unreachable;
            var raw = [_]u8{ 'S', 'a', 'n', 's' };
            var hook: Hook = .{ .child = candidate, .family = &raw, .trigger = 1, .engine = engine };
            const layout = try engine.layoutAllocated(hook.allocator(), "é ab😀 אבג\n", .{ .family = &raw, .locale = "en" });
            defer layout.close() catch unreachable;
            try std.testing.expectEqualStrings("Sans", (try layout.options()).family);
            try std.testing.expectEqualStrings("é ab😀 אבג\n", try layout.text());
            const prepared = try layout.prepare(1.5, .{});
            defer prepared.close() catch unreachable;
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scenario.run, .{});
    const MutableScenario = struct {
        fn run(candidate: std.mem.Allocator, backing: std.mem.Allocator, reference: bool) !void {
            var editor = try ui.editor.Editor.init(backing, .{}, "é");
            defer editor.deinit();
            var hook: Hook = .{ .child = candidate };
            const engine = try t.Engine.create(hook.allocator(), std.Thread.getCurrentId(), .{});
            defer engine.close() catch unreachable;
            hook.allocations = 0;
            hook.trigger = 1;
            hook.editor = &editor;
            hook.engine = engine;
            const layout = if (reference) try engine.layoutReference(editor.displayText(), .{}) else try engine.layout(editor.displayText(), .{});
            defer layout.close() catch unreachable;
            try std.testing.expectEqualStrings("ab", try layout.text());
            try std.testing.expectEqual(@as(usize, 2), (try layout.buildStats()).scalar_count);
        }
    };
    for ([_]bool{ false, true }) |reference| try std.testing.checkAllAllocationFailures(allocator, MutableScenario.run, .{ allocator, reference });
    try std.testing.expectEqual(t.ResourceCounts{}, t.resourceCounts());
}

const Case = enum { first, second, after_copy, options_first, options_second, adapter_first, adapter_second, adapter_after_copy, reference_first, reference_second, reference_after_copy };
fn runCase(allocator: std.mem.Allocator, name: []const u8) !void {
    const case = std.meta.stringToEnum(Case, name) orelse return error.InvalidCase;
    switch (case) {
        .first => try textCapture(allocator, 1, false, false),
        .second => try textCapture(allocator, 2, false, false),
        .after_copy => try textCapture(allocator, 3, false, false),
        .options_first => try optionCapture(allocator, 1),
        .options_second => try optionCapture(allocator, 2),
        .adapter_first => try textCapture(allocator, 1, true, false),
        .adapter_second => try textCapture(allocator, 2, true, false),
        .adapter_after_copy => try textCapture(allocator, 3, true, false),
        .reference_first => try textCapture(allocator, 1, false, true),
        .reference_second => try textCapture(allocator, 2, false, true),
        .reference_after_copy => try textCapture(allocator, 3, false, true),
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    const args = try zio.argsAlloc(allocator, init.args);
    defer zio.argsFree(allocator, args);
    if (args.len == 3 and std.mem.eql(u8, args[1], "--case")) {
        try std.testing.expectEqual(t.ResourceCounts{}, t.resourceCounts());
        try runCase(allocator, args[2]);
        try std.testing.expectEqual(t.ResourceCounts{}, t.resourceCounts());
        return;
    }
    const executable = try zio.executablePathAlloc(allocator);
    defer allocator.free(executable);
    var failed = false;
    for (std.enums.values(Case)) |case| {
        const name = @tagName(case);
        const result = try zio.run(allocator, .{ .argv = &.{ executable, "--case", name }, .stdout_limit = .limited(128 * 1024), .stderr_limit = .limited(128 * 1024) });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        std.debug.print("layout capture {s}: {any}\n{s}{s}", .{ name, result.term, result.stdout, result.stderr });
        if (result.term != .exited or result.term.exited != 0) failed = true;
    }
    if (failed) return error.CaptureRegression;
    try invalidCapture(allocator);
    try byteBudgets(allocator);
    try failures(allocator);
    try std.testing.expectEqual(t.ResourceCounts{}, t.resourceCounts());
    std.debug.print("layout capture passed: 11 child probes, copied source, invalid mutations, fixed options, preallocation/exact budgets, all OOM, Engine gates, Adapter stamp, resources=0\n", .{});
}
