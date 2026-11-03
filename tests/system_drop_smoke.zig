const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const system = @import("ziggurat_system");
const drop = system.drop;

pub const panic = std.debug.FullPanic(@import("macos_panic.zig").panic);
pub const std_options: std.Options = .{ .allow_stack_tracing = builtin.os.tag != .macos };

const Probe = struct {
    drops: u32 = 0,
    hovers: u32 = 0,
    accept: bool = true,
    last: [64]u8 = undefined,
    last_len: usize = 0,
    capacity: usize = 0,
    phase: ?drop.Phase = null,
    fn onHover(context: *anyopaque, _: z.Window, value: drop.Hover) bool {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.hovers += 1;
        self.phase = value.phase;
        return self.accept;
    }
    fn onDrop(context: *anyopaque, _: z.Window, value: drop.Drop) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.drops += 1;
        switch (value.payload) {
            .files, .text => |bytes| {
                @memcpy(self.last[0..bytes.len], bytes);
                self.last_len = bytes.len;
            },
            .capacity_exceeded => |size| self.capacity = size,
            .failed => {},
        }
    }
};
const Closed = struct {
    count: u32 = 0,
    fn notify(context: *anyopaque, _: z.Window) void {
        const self: *Closed = @ptrCast(@alignCast(context));
        self.count += 1;
    }
};

fn registration(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var closed: Closed = .{};
    var probe: Probe = .{};
    var buffer: [16]u8 = undefined;
    const window = try app.createWindow(.{ .on_closed = .{ .context = &closed, .notify = Closed.notify } });
    var target: drop.Target = .{ .context = &probe, .on_drop = Probe.onDrop, .on_hover = Probe.onHover, .buffer = &buffer };
    var empty: drop.Target = .{ .context = &probe, .on_drop = Probe.onDrop, .buffer = &buffer, .kinds = .{ .files = false, .text = false } };
    try std.testing.expectError(error.InvalidKinds, empty.attach(window));
    try std.testing.expect(!drop.Target.registered(window));
    try target.attach(window);
    try std.testing.expect(drop.Target.registered(window));
    try std.testing.expectError(error.AlreadyAttached, target.attach(window));

    // Adapter entries: payload bytes are copied into the Target buffer, larger
    // payloads report their size, and a refused hover is not accepted.
    try std.testing.expect(target.hover(.{ .phase = .enter, .point = .{ .x = 1, .y = 2 }, .files = true, .text = false }));
    try std.testing.expect(!target.hover(.{ .phase = .over, .point = .{ .x = 1, .y = 2 }, .files = false, .text = false }));
    probe.accept = false;
    try std.testing.expect(!target.hover(.{ .phase = .leave, .point = .{ .x = 1, .y = 2 }, .files = true, .text = true }));
    try std.testing.expectEqual(drop.Phase.leave, probe.phase.?);
    target.drop(.{ .x = 3, .y = 4 }, .{ .text = "dropped" });
    try std.testing.expectEqualStrings("dropped", probe.last[0..probe.last_len]);
    target.drop(.{ .x = 3, .y = 4 }, .{ .files = "/a/very/long/path/name.txt" });
    try std.testing.expectEqual(@as(usize, 26), probe.capacity);
    try std.testing.expectEqual(@as(u32, 2), probe.drops);

    target.detach();
    target.detach();
    try std.testing.expect(!drop.Target.registered(window));
    try target.attach(window);
    try std.testing.expect(drop.Target.registered(window));
    // Native destruction revokes the registration before the window is gone;
    // detach after on_closed only releases the Target's own native reference.
    _ = try window.destroy();
    try std.testing.expectEqual(@as(u32, 1), closed.count);
    try std.testing.expect(!drop.Target.registered(window));
    const drops = probe.drops;
    target.drop(.{ .x = 0, .y = 0 }, .{ .text = "late" });
    try std.testing.expectEqual(drops, probe.drops);
    target.detach();
}

fn dataDrop(_: *anyopaque, _: z.Window, _: drop.DataDrop) bool {
    return true;
}
/// A multi-format target takes the window's one drop registration.
fn dataRegistration(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    var context: u8 = 0;
    var data: drop.DataTarget = .{ .context = &context, .on_drop = dataDrop, .formats = &.{ system.transfer.file_list, system.transfer.text, "application/x-ziggurat-smoke-note" }, .allocator = allocator };
    try data.attach(window);
    try std.testing.expect(drop.Target.registered(window));
    var buffer: [16]u8 = undefined;
    var probe: Probe = .{};
    var second: drop.Target = .{ .context = &probe, .on_drop = Probe.onDrop, .buffer = &buffer };
    if (second.attach(window)) |_| return error.ExpectedOneRegistration else |_| {}
    data.detach();
    data.detach();
    try std.testing.expect(!drop.Target.registered(window));
    try second.attach(window);
    try std.testing.expect(drop.Target.registered(window));
    second.detach();
    _ = try window.destroy();
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(@import("macos_panic.zig").allocator_config) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    if (!drop.capabilities.drop_target) return error.UnsupportedCapability;
    for (0..12) |round| registration(gpa.allocator()) catch |err| {
        std.debug.print("drop round {d} failed\n", .{round});
        return err;
    };
    if (builtin.os.tag != .windows) for (0..4) |_| try dataRegistration(gpa.allocator());
    std.debug.print("drop smoke passed\n", .{});
}
