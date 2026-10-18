const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
});

const State = struct {
    fn draw(_: *anyopaque, frame: *ui.Frame) void {
        frame.clear(0xffffff);
        frame.button(1, .{ .x = 4, .y = 4, .width = 100, .height = 32 }, "Apply") catch unreachable;
    }
    fn action(_: *anyopaque, _: u64) void {}
};

fn noResources() !void {
    try std.testing.expectEqual(ui.accessibility.ResourceCounts{ .states = 0, .providers = 0, .ranges = 0, .actions = 0 }, ui.accessibility.resourceCounts());
}
fn paint(window: z.Window) void {
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
}
fn expectName(context: *const ui.Context, wanted: []const u8) !void {
    const root = context.semantic_tree.entries[0];
    try std.testing.expectEqualStrings(wanted, context.semantic_tree.storage[root.name_start..][0..root.name_len]);
}

pub fn main() !void {
    if (!ui.capabilities.accessibility) return error.AccessibilityBuildRequired;
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    const app = try z.App.init(allocator.allocator());
    defer app.deinit();
    var state: State = .{};
    var context = ui.Context.init(&state, State.draw, State.action);
    context.render_mode = .gdi;
    try noResources();

    // The configuration slice is deliberately overwritten after attach. Both
    // subsequent frames and the native snapshot must use the attached copy.
    var temporary_name = "Temporary name".*;
    context.semantic_name = &temporary_name;
    const first = try app.createWindow(.{});
    try context.attach(first);
    try std.testing.expect(context.attached_semantics_enabled);
    try std.testing.expectEqual(1, ui.accessibility.resourceCounts().states);
    @memset(&temporary_name, '?');
    context.semantic_name = "Next attachment";
    context.semantics_enabled = false;
    paint(first);
    try expectName(&context, "Temporary name");
    try std.testing.expectEqual(2, context.semantic_tree.len);
    try std.testing.expect(context.attached_semantics_enabled);
    _ = try first.destroy();
    try std.testing.expect(context.window == null and !context.attached_semantics_enabled);
    try app.dispatch();
    try noResources();

    // Changes configure the next attach. Enabling while attached must not use
    // an uninitialized Bridge; closing must also leave native counts at zero.
    const second = try app.createWindow(.{});
    try context.attach(second);
    try std.testing.expect(!context.attached_semantics_enabled);
    context.semantics_enabled = true;
    paint(second);
    try std.testing.expect(!context.attached_semantics_enabled);
    try noResources();
    _ = try second.destroy();
    try noResources();

    const third = try app.createWindow(.{});
    try context.attach(third);
    paint(third);
    try std.testing.expect(context.attached_semantics_enabled);
    try expectName(&context, "Next attachment");
    try std.testing.expectEqual(2, context.semantic_tree.len);
    _ = try third.destroy();
    try app.dispatch();
    try noResources();
    try std.testing.expectEqual(0, app.resourceStats().allocated_records);
    std.debug.print("UI config smoke passed: semantics frozen through attach, names copied before mutation, reused Context releases every Bridge\n", .{});
}
