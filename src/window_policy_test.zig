const std = @import("std");
const z = @import("root.zig");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

fn record(window: z.Window) *z.WindowRecord {
    return window.app.windows.get(window.key).?;
}

test "window traits apply together, gate interactions and cancel user close" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .decoration = .custom, .movable = false, .closable = false });
    const native = &record(window).native;
    try expect(!native.traits.movable and !native.traits.closable and native.traits.resizable);
    try window.perform(.show);
    native.gesture_active = true;
    try std.testing.expectError(error.InvalidWindowState, window.startMove());
    try equal(z.CloseResult.cancelled, try window.requestCloseFrom(.user));
    try window.setMovable(true);
    try window.startMove();
    try window.setResizable(false);
    try expect(!native.traits.resizable and native.traits.movable);
    try equal(z.WindowHit.client, record(window).hitTest(.{ .x = 1, .y = 1 }, 100, 100));
    try std.testing.expectError(error.InvalidWindowState, window.startResize(.north_west));
    try window.setTraits(.{ .minimizable = false, .maximizable = false });
    const value = try window.traits();
    try expect(value.resizable and value.closable and !value.minimizable and !value.maximizable);
    try equal(record(window).hitTest(.{ .x = 1, .y = 1 }, 100, 100), .north_west);
    app.native.fail_update = true;
    try std.testing.expectError(error.WindowUpdateFailed, window.setClosable(false));
    try expect((try window.traits()).closable);
    try equal(z.CloseResult.closed, try window.requestCloseFrom(.user));
}

test "window buttons require their capability, also at construction" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    record(window).native.caps.window_buttons = false;
    try std.testing.expectError(error.UnsupportedCapability, window.setMaximizable(false));
    try window.setClosable(false);
    try expect(!(try window.traits()).closable);
    try std.testing.expectError(error.InvalidOpacity, app.createWindow(.{ .opacity = 1.5 }));
    try equal(0, app.resourceStats().live_windows - 1);
}

test "opacity, pointer pass-through, protection, attention and taskbar reach the backend" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .opacity = 0.5, .skip_taskbar = true });
    const native = &record(window).native;
    try equal(0.5, native.opacity);
    try equal(0.5, try window.opacity());
    try expect(native.skip_taskbar);
    try std.testing.expectError(error.InvalidOpacity, window.setOpacity(std.math.nan(f32)));
    try std.testing.expectError(error.InvalidOpacity, window.setOpacity(-0.1));
    try window.setOpacity(1);
    try equal(1, native.opacity);
    try window.setIgnorePointer(true);
    try window.setContentProtection(true);
    try window.flashFrame(true);
    try window.setSkipTaskbar(false);
    try expect(native.ignore_pointer and native.content_protected and native.flashing and !native.skip_taskbar);
    native.caps.content_protection = false;
    try std.testing.expectError(error.UnsupportedCapability, window.setContentProtection(false));
    app.native.fail_update = true;
    try std.testing.expectError(error.WindowUpdateFailed, window.setOpacity(0.25));
    try equal(1, try window.opacity());
}

test "document edited marks the native title and survives title changes" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const app = try z.App.init(failing.allocator());
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Notes" });
    const native = &record(window).native;
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("Notes", native.shownTitle());
    try window.setDocumentEdited(true);
    try expect(try window.isDocumentEdited());
    try std.testing.expectEqualStrings("*Notes", native.shownTitle());
    try window.setTitle("Draft");
    try std.testing.expectEqualStrings("*Draft", native.shownTitle());
    try std.testing.expectEqualStrings("Draft", try window.title(&buffer));
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, window.setTitle("Other"));
    try std.testing.expectEqualStrings("Draft", try window.title(&buffer));
    try std.testing.expectEqualStrings("*Draft", native.shownTitle());
    failing.fail_index = std.math.maxInt(usize);
    try window.setDocumentEdited(false);
    try std.testing.expectEqualStrings("Draft", native.shownTitle());
    try std.testing.expectError(error.ResultCapacityExceeded, window.title(buffer[0..2]));
}

test "app activation reports focus entering and leaving the app, not moves between its windows" {
    const Probe = struct {
        changes: [4]bool = undefined,
        count: usize = 0,
        fn changed(ptr: *anyopaque, _: *z.App, active: bool) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.changes[self.count] = active;
            self.count += 1;
        }
    };
    var probe: Probe = .{};
    const app = try z.App.initWithOptions(std.testing.allocator, .{ .activation = .{ .context = &probe, .changed = Probe.changed } });
    defer app.deinit();
    const a = try app.createWindow(.{});
    const b = try app.createWindow(.{});
    record(a).emit(.{ .focus = true });
    try equal(0, probe.count);
    try app.dispatch();
    try equal(1, probe.count);
    try expect(probe.changes[0] and app.isActive());
    record(a).emit(.{ .focus = false });
    record(b).emit(.{ .focus = true });
    try app.dispatch();
    try equal(1, probe.count);
    record(b).emit(.{ .focus = false });
    try app.dispatch();
    try equal(2, probe.count);
    try expect(!probe.changes[1] and !app.isActive());
    record(a).emit(.{ .focus = true });
    try app.dispatch();
    _ = try a.destroy();
    try app.dispatch();
    try equal(4, probe.count);
    try expect(probe.changes[2] and !probe.changes[3]);
}
