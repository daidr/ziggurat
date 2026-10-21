const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const view = @import("ziggurat_view");
const collections = @import("ziggurat_view_collections");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};

extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_resource_count() u32;

const width = 480;
const height = 640;

fn nativePaint(window: z.Window) void {
    if (builtin.os.tag == .windows) {
        const hwnd: c.HWND = window.nativeHandle();
        _ = c.InvalidateRect(hwnd, null, 0);
        _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    } else {
        const scope = window.beginCallback().?;
        defer scope.end();
        zlg_test_paint(scope.record.native.native.?, width, height);
    }
}

const columns = [_]collections.Column{
    .{ .title = "Name" },
    .{ .title = "Size", .width = 90, .alignment = .end, .sortable = true },
};

const State = struct {
    count: usize = 1_000_000,
    table: collections.TableState = .{},
    selection: collections.Selection = undefined,
    storage: [64]u64 = undefined,
    sort: ?collections.SortOrder = null,
    submitted: ?usize = null,

    fn cell(_: ?*const anyopaque, row: usize, column: usize, buffer: []u8) collections.Cell {
        return .{ .text = (if (column == 0) std.fmt.bufPrint(buffer, "file {d}", .{row}) else std.fmt.bufPrint(buffer, "{d} KB", .{row % 977})) catch "" };
    }
    fn build(self: *State, v: *view.View) anyerror!void {
        self.table.selection = &self.selection;
        self.table.sort = &self.sort;
        const result = try collections.table(v, &self.table, &columns, .{ .count = self.count }, .{ .call = cell }, .{ .style = .{ .grow = 1, .self_align = .stretch, .name = "Files" } });
        if (result.submitted) |row| self.submitted = row;
    }
};

fn paint(host: *view.Host, window: z.Window) !void {
    const before = host.frames;
    nativePaint(window);
    if (host.last_error) |err| return err;
    try std.testing.expectEqual(before + 1, host.frames);
}

fn key(host: *view.Host, app: *z.App, window: z.Window, input: z.KeyInput) !void {
    _ = host.context.handleKeyInput(window, input);
    if (host.last_error) |err| return err;
    try paint(host, window);
    try app.dispatch();
    try paint(host, window);
}

fn run(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{};
    state.selection = collections.Selection.init(.multiple, &state.storage);
    var storage: view.Storage(32, 1024) = .{};
    var host = view.Host.init(&state, State.build, storage.buffers(), .{});
    host.context.render_mode = .gdi;
    const window = try app.createWindow(.{ .width = width, .height = height });
    try host.attach(window);
    try paint(&host, window);

    // The table is one Tab stop; its keys arrive through the window's
    // Context, choose rows of a million and scroll them into view.
    var leaf: ?view.Node = null;
    for (host.view.nodes()) |node| if (node.kind == .embed) {
        leaf = node;
    };
    host.context.input_state.setFocused(leaf.?.id);
    try key(&host, app, window, .{ .key = .down });
    try std.testing.expectEqualSlices(u64, &.{1}, state.selection.items());
    try key(&host, app, window, .{ .key = .end });
    try std.testing.expectEqualSlices(u64, &.{1_000_000}, state.selection.items());
    try std.testing.expect(state.table.atEnd());
    try key(&host, app, window, .{ .key = .up, .modifiers = .{ .shift = true } });
    try std.testing.expectEqual(@as(usize, 2), state.selection.len);
    try key(&host, app, window, .{ .key = .enter });
    try std.testing.expectEqual(@as(?usize, 999_998), state.submitted);
    try key(&host, app, window, .{ .key = .home });
    try std.testing.expectEqual(@as(f64, 0), state.table.scrollOffset());
    try std.testing.expectEqual(leaf.?.id, host.context.input_state.focused.?);

    _ = try window.destroy();
    try app.dispatch();
    try std.testing.expect(host.context.window == null);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    try run(gpa.allocator());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("collections native: million-row table keys, range choice, submit and scrolling passed\n", .{});
}
