const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const system = @import("ziggurat_system");
fn action(_: *anyopaque, _: z.Window, _: system.Action) void {}
fn trayAction(_: *anyopaque, _: *system.Tray, _: system.TrayAction) void {}
fn selected(_: *anyopaque, _: z.Window, _: system.picker.Result) void {}
test "unsupported system capabilities fail explicitly" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    var context: u8 = 0;
    var destination: [100]u8 = undefined;
    var owner = system.Owner.init(&context, action);
    try std.testing.expect(!system.capabilities.native_menu and !system.capabilities.tray and !system.capabilities.clipboard_text and !system.capabilities.async_file_dialog);
    try std.testing.expectError(error.UnsupportedCapability, owner.attach(window));
    try std.testing.expectError(error.UnsupportedCapability, owner.setMenu(&.{}));
    try std.testing.expectError(error.UnsupportedCapability, owner.clearMenu());
    try std.testing.expectError(error.UnsupportedCapability, owner.setItemState(1, true, false));
    try std.testing.expectError(error.UnsupportedCapability, owner.setTray(.{}));
    try std.testing.expectError(error.UnsupportedCapability, owner.clearTray());
    try std.testing.expect(!system.capabilities.global_hotkeys and !system.capabilities.notification_area);
    try std.testing.expectError(error.UnsupportedCapability, owner.registerHotkey(1, .{ .key = .f24 }));
    try std.testing.expectError(error.UnsupportedCapability, owner.unregisterHotkey(1));
    try std.testing.expectError(error.UnsupportedCapability, owner.clearHotkeys());
    try std.testing.expectError(error.UnsupportedCapability, owner.showNotification(1, .{ .title = "Title", .body = "Body" }));
    try std.testing.expectError(error.UnsupportedCapability, owner.clearNotification());
    try std.testing.expectError(error.UnsupportedCapability, owner.openFile(.{}, &destination, &context, selected));
    try std.testing.expectError(error.UnsupportedCapability, owner.saveFile(.{}, &destination, &context, selected));
    try std.testing.expectError(error.UnsupportedCapability, owner.openFiles(.{}, &destination, &context, selected));
    try std.testing.expectError(error.UnsupportedCapability, owner.pickFolder(.{}, &destination, &context, selected));
    try std.testing.expectError(error.UnsupportedCapability, owner.cancelFileDialog());
    try std.testing.expectError(error.UnsupportedCapability, owner.popupMenu(1, &.{.{ .id = 1, .label = "Item" }}, .pointer));
    try std.testing.expectError(error.UnsupportedCapability, owner.cancelPopup());
    try std.testing.expectError(error.UnsupportedCapability, owner.showMessage(1, .{ .message = "Text", .buttons = &.{.{ .id = 1, .label = "OK" }} }));
    try std.testing.expectError(error.UnsupportedCapability, owner.cancelMessage());
    var tray = system.Tray.init(&context, trayAction);
    try std.testing.expectError(error.UnsupportedCapability, tray.show(app, .{}));
    try std.testing.expectError(error.UnsupportedCapability, tray.popupMenu(1, &.{.{ .id = 1, .label = "Item" }}, .icon));
    try std.testing.expectError(error.UnsupportedCapability, tray.setMenu(&.{.{ .id = 1, .label = "Item" }}));
    try tray.remove();
    try std.testing.expectError(error.UnsupportedCapability, system.clipboard.writeText(window, "text"));
    try std.testing.expectError(error.UnsupportedCapability, system.clipboard.readText(window, &destination));
    // The test backend has no native display; Board reports that explicitly.
    var board: system.clipboard.Board = undefined;
    try std.testing.expectError(error.UnsupportedCapability, board.init(app, .{}));
    var picker: system.picker.Picker = .{};
    try std.testing.expectError(error.UnsupportedCapability, picker.start(window, .open_file, .{}, &destination, &context, selected));
    try std.testing.expectError(error.UnsupportedCapability, picker.cancel());
    picker.detach();
    try owner.detach();
    try std.testing.expectEqual(0, system.picker.resourceCount());
}

fn desktopChanged(_: *anyopaque, _: system.desktop.Change) void {}
test "desktop environment queries need the native display outside the test backend" {
    const desktop = system.desktop;
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var monitors: [desktop.max_monitors]desktop.Monitor = undefined;
    try std.testing.expectError(error.UnsupportedCapability, desktop.monitors(app, &monitors));
    try std.testing.expectError(error.UnsupportedCapability, desktop.preferences(app));
    try std.testing.expectError(error.UnsupportedCapability, desktop.power(app));
    try std.testing.expectError(error.UnsupportedCapability, desktop.network(app));
    var context: u8 = 0;
    var watch = desktop.Watch.init(&context, desktopChanged);
    try std.testing.expectError(error.EmptySelection, watch.start(app, .{}));
    try std.testing.expectError(error.UnsupportedCapability, watch.start(app, .{ .preferences = true }));
    try std.testing.expect(!watch.running());
    watch.stop();
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().stop_participants);
    try std.testing.expectEqual(@as(usize, 0), desktop.resourceCount());
    const all: desktop.Kinds = .{ .monitors = true, .preferences = true, .power = true, .network = true };
    try std.testing.expectEqual(all, desktop.Kinds.fromBits(all.bits()));
    try std.testing.expectEqual(desktop.Kinds{ .power = true }, desktop.Kinds.fromBits(4));
}

const SecretProbe = struct {
    calls: usize = 0,
    outcome: ?anyerror = null,
    value: [system.secrets.max_secret_bytes]u8 = undefined,
    value_len: usize = 0,
    main: std.Thread.Id,
    fn done(ptr: *anyopaque, request: *system.secrets.Request) void {
        const self: *SecretProbe = @ptrCast(@alignCast(ptr));
        std.debug.assert(std.Thread.getCurrentId() == self.main);
        self.calls += 1;
        self.outcome = request.err();
        @memcpy(self.value[0..request.value().len], request.value());
        self.value_len = request.value().len;
        request.wipe();
    }
    fn exchange(self: *SecretProbe, app: *z.App, operation: system.secrets.Operation, key: []const u8, value: []const u8) !void {
        var request = try system.secrets.Request.init(app, operation, "dev.ziggurat.tests", key, value, self, done);
        const worker = try std.Thread.spawn(.{}, struct {
            fn run(item: *system.secrets.Request) void {
                item.run() catch unreachable;
            }
        }.run, .{&request});
        worker.join();
        const before = self.calls;
        try app.dispatch();
        try std.testing.expectEqual(before + 1, self.calls);
    }
};
test "secret requests run on a worker and finish once on the main thread" {
    const secrets = system.secrets;
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var probe: SecretProbe = .{ .main = std.Thread.getCurrentId() };
    try probe.exchange(app, .get, "token", "");
    try std.testing.expectEqual(error.SecretNotFound, probe.outcome.?);
    try probe.exchange(app, .set, "token", "s3cr\x00t");
    try std.testing.expectEqual(null, probe.outcome);
    try probe.exchange(app, .get, "token", "");
    try std.testing.expectEqual(null, probe.outcome);
    try std.testing.expectEqualStrings("s3cr\x00t", probe.value[0..probe.value_len]);
    try probe.exchange(app, .set, "token", "");
    try probe.exchange(app, .get, "token", "");
    try std.testing.expectEqual(0, probe.value_len);
    try std.testing.expectEqual(null, probe.outcome);
    try probe.exchange(app, .delete, "token", "");
    try probe.exchange(app, .delete, "token", "");
    try std.testing.expectEqual(null, probe.outcome);
    try probe.exchange(app, .get, "token", "");
    try std.testing.expectEqual(error.SecretNotFound, probe.outcome.?);

    var small: [2]u8 = undefined;
    try secrets.set("dev.ziggurat.tests", "long", "abc");
    try std.testing.expectError(error.SecretTooLarge, secrets.get("dev.ziggurat.tests", "long", &small));
    try secrets.delete("dev.ziggurat.tests", "long");
    try std.testing.expectError(error.EmptyName, system.secrets.Request.init(app, .get, "", "key", "", &probe, SecretProbe.done));
    try std.testing.expectError(error.NameTooLong, system.secrets.Request.init(app, .get, "s", "k" ** 257, "", &probe, SecretProbe.done));
    try std.testing.expectError(error.UnexpectedValue, system.secrets.Request.init(app, .delete, "s", "k", "v", &probe, SecretProbe.done));
    try std.testing.expectError(error.SecretTooLarge, system.secrets.Request.init(app, .set, "s", "k", &([_]u8{0} ** (secrets.max_secret_bytes + 1)), &probe, SecretProbe.done));
    try std.testing.expectError(error.EmbeddedNul, secrets.delete("s\x00", "k"));
}

test "flyout placement flips, slides and shrinks into the work area" {
    const flyout = system.flyout;
    // Under a menu bar.
    const work: flyout.Box = .{ .x = 0, .y = 25, .width = 1000, .height = 700 };
    const button: flyout.Box = .{ .x = 100, .y = 100, .width = 80, .height = 20 };
    const size: flyout.Size = .{ .width = 200, .height = 150 };
    const Case = struct { placement: flyout.Placement, gap: i32 = 0, anchor: flyout.Box, size: flyout.Size, want: flyout.Box, fx: bool = false, fy: bool = false };
    const cases = [_]Case{
        .{ .placement = .bottom_start, .gap = 4, .anchor = button, .size = size, .want = .{ .x = 100, .y = 124, .width = 200, .height = 150 } },
        .{ .placement = .bottom, .anchor = button, .size = size, .want = .{ .x = 40, .y = 120, .width = 200, .height = 150 } },
        .{ .placement = .bottom_end, .anchor = .{ .x = 400, .y = 100, .width = 80, .height = 20 }, .size = size, .want = .{ .x = 280, .y = 120, .width = 200, .height = 150 } },
        // No room left of the end: lines up with the start.
        .{ .placement = .bottom_end, .anchor = button, .size = size, .want = .{ .x = 100, .y = 120, .width = 200, .height = 150 }, .fx = true },
        .{ .placement = .top_start, .gap = 4, .anchor = .{ .x = 100, .y = 400, .width = 80, .height = 20 }, .size = size, .want = .{ .x = 100, .y = 246, .width = 200, .height = 150 } },
        .{ .placement = .right_start, .gap = 2, .anchor = button, .size = size, .want = .{ .x = 182, .y = 100, .width = 200, .height = 150 } },
        .{ .placement = .left_end, .anchor = .{ .x = 500, .y = 300, .width = 80, .height = 20 }, .size = size, .want = .{ .x = 300, .y = 170, .width = 200, .height = 150 } },
        // No room below: above instead, the gap on that side.
        .{ .placement = .bottom_start, .gap = 4, .anchor = .{ .x = 100, .y = 600, .width = 80, .height = 20 }, .size = size, .want = .{ .x = 100, .y = 446, .width = 200, .height = 150 }, .fy = true },
        // No room right of the start: lines up with the end.
        .{ .placement = .bottom_start, .anchor = .{ .x = 900, .y = 100, .width = 80, .height = 20 }, .size = size, .want = .{ .x = 780, .y = 120, .width = 200, .height = 150 }, .fx = true },
        // No room on either side: stays, slides back in.
        .{ .placement = .bottom_start, .anchor = .{ .x = 100, .y = 300, .width = 80, .height = 20 }, .size = .{ .width = 200, .height = 600 }, .want = .{ .x = 100, .y = 125, .width = 200, .height = 600 } },
        .{ .placement = .left_start, .anchor = .{ .x = 50, .y = 300, .width = 80, .height = 20 }, .size = .{ .width = 200, .height = 100 }, .want = .{ .x = 130, .y = 300, .width = 200, .height = 100 }, .fx = true },
        // Larger than the work area: its start shows, the rest is cut.
        .{ .placement = .bottom_start, .anchor = button, .size = .{ .width = 1200, .height = 900 }, .want = .{ .x = 0, .y = 25, .width = 1000, .height = 700 } },
    };
    for (cases) |case| {
        const placed = flyout.placeBeside(case.anchor, case.size, work, case.placement, case.gap);
        try std.testing.expectEqual(case.want, placed.box);
        try std.testing.expectEqual(case.fx, placed.flipped_x);
        try std.testing.expectEqual(case.fy, placed.flipped_y);
    }
    try std.testing.expectEqual(flyout.Box{ .x = 400, .y = 300, .width = 200, .height = 150 }, flyout.centered(size, .{ .x = 0, .y = 0, .width = 1000, .height = 750 }));
    try std.testing.expectEqual(flyout.Box{ .x = 0, .y = 0, .width = 100, .height = 100 }, flyout.centered(size, .{ .x = 0, .y = 0, .width = 100, .height = 100 }));
}

test "flyouts go to the display with most of the anchor, else the nearest" {
    const flyout = system.flyout;
    const displays = [_]system.desktop.Monitor{
        .{ .bounds = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 }, .work_area = .{ .x = 0, .y = 25, .width = 1920, .height = 1055 }, .scale = 1, .primary = true, .refresh_hz = null },
        .{ .bounds = .{ .x = 1920, .y = -77, .width = 1470, .height = 956 }, .work_area = .{ .x = 1920, .y = -77, .width = 1470, .height = 900 }, .scale = 2, .primary = false, .refresh_hz = null },
    };
    const Case = struct { rect: flyout.Box, want: usize };
    for ([_]Case{
        .{ .rect = .{ .x = 100, .y = 100, .width = 50, .height = 20 }, .want = 0 },
        .{ .rect = .{ .x = 1900, .y = 100, .width = 50, .height = 20 }, .want = 1 },
        .{ .rect = .{ .x = 1880, .y = 100, .width = 50, .height = 20 }, .want = 0 },
        .{ .rect = .{ .x = 2000, .y = 100, .width = 0, .height = 0 }, .want = 1 },
        .{ .rect = .{ .x = 5000, .y = 100, .width = 10, .height = 10 }, .want = 1 },
        .{ .rect = .{ .x = -300, .y = 5, .width = 10, .height = 10 }, .want = 0 },
    }) |case| try std.testing.expectEqual(displays[case.want].work_area, flyout.monitorFor(case.rect, &displays).work_area);
    for (std.enums.values(flyout.Placement), 0..) |placement, index| {
        try std.testing.expectEqual(@as(flyout.Side, @enumFromInt(index / 3)), placement.side());
        try std.testing.expectEqual(@as(flyout.Alignment, @enumFromInt(index % 3)), placement.alignment());
    }
}

const FlyoutProbe = struct {
    closed: usize = 0,
    veto: bool = false,
    fn request(ptr: *anyopaque, _: z.Window, _: z.CloseReason) z.CloseDecision {
        const self: *FlyoutProbe = @ptrCast(@alignCast(ptr));
        return if (self.veto) .cancel else .allow;
    }
    fn notify(ptr: *anyopaque, _: z.Window) void {
        const self: *FlyoutProbe = @ptrCast(@alignCast(ptr));
        self.closed += 1;
    }
};
fn testRecord(window: z.Window) *z.WindowRecord {
    return @ptrCast(@alignCast(window.nativeHandle().?));
}
test "flyouts place beside their anchor, follow their owner and close as popups" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const displays = [_]system.desktop.Monitor{.{ .bounds = .{ .x = 0, .y = 0, .width = 1000, .height = 925 }, .work_area = .{ .x = 0, .y = 25, .width = 1000, .height = 900 }, .scale = 1, .primary = true, .refresh_hz = null }};
    const owner = try app.createWindow(.{ .width = 400, .height = 300 });
    try owner.setClientBounds(.{ .position = .{ .x = 100, .y = 100 }, .width = 400, .height = 300 });
    var probe: FlyoutProbe = .{};
    var flyout: system.Flyout = .{};
    const anchor: z.Rect = .{ .x = 10, .y = 20, .width = 80, .height = 24 };
    const window = try flyout.open(app, .{ .anchor = .{ .window = .{ .owner = owner, .rect = anchor } }, .gap = 4, .width = 200, .height = 100, .focusable = true, .displays = &displays, .on_close = .{ .context = &probe, .request = FlyoutProbe.request }, .on_closed = .{ .context = &probe, .notify = FlyoutProbe.notify } });
    try std.testing.expect(flyout.isOpen());
    try std.testing.expectEqual(z.ClientBounds{ .position = .{ .x = 110, .y = 148 }, .width = 200, .height = 100 }, try window.clientBounds());
    try std.testing.expect(std.meta.eql((try window.relationship()).owner, owner));
    try std.testing.expectError(error.AlreadyOpen, flyout.open(app, .{ .anchor = .{ .screen = .{ .x = 0, .y = 0, .width = 1, .height = 1 } } }));

    // It follows its owner, and flips above the anchor near the bottom.
    try owner.setClientBounds(.{ .position = .{ .x = 300, .y = 200 }, .width = 400, .height = 300 });
    testRecord(owner).emit(.window_position);
    try std.testing.expectEqual(z.ScreenPoint{ .x = 310, .y = 248 }, (try window.clientBounds()).position.?);
    try owner.setClientBounds(.{ .position = .{ .x = 300, .y = 800 }, .width = 400, .height = 300 });
    testRecord(owner).emit(.window_position);
    try std.testing.expectEqual(z.ScreenPoint{ .x = 310, .y = 800 + 20 - 4 - 100 }, (try window.clientBounds()).position.?);

    try owner.setClientBounds(.{ .position = .{ .x = 100, .y = 100 }, .width = 400, .height = 300 });
    try flyout.setAnchor(.{ .window = .{ .owner = owner, .rect = .{ .x = 50, .y = 60, .width = 0, .height = 0 } } });
    try flyout.setSize(120, 90);
    try std.testing.expectEqual(z.ClientBounds{ .position = .{ .x = 150, .y = 164 }, .width = 120, .height = 90 }, try window.clientBounds());
    try std.testing.expectError(error.AnchorKindChanged, flyout.setAnchor(.{ .screen = .{ .x = 0, .y = 0, .width = 1, .height = 1 } }));
    try std.testing.expectError(error.InvalidSize, flyout.setSize(0, 10));

    // A dismissal and an unconsumed Escape close it as the user, which
    // on_close may refuse.
    probe.veto = true;
    testRecord(window).popupDismissed();
    try std.testing.expect(testRecord(window).keyInput(.{ .key = .escape }));
    try std.testing.expect(flyout.isOpen());
    try std.testing.expect(!testRecord(window).keyInput(.{ .key = .escape, .modifiers = .{ .shift = true } }));
    probe.veto = false;
    testRecord(window).popupDismissed();
    try std.testing.expect(!flyout.isOpen());
    // Native destruction waits for the safe point after the callback.
    try app.dispatch();
    try std.testing.expectEqual(1, probe.closed);
    try std.testing.expectEqual(null, flyout.window);

    // Escape closes a flyout that is not focusable too; dismissals reach
    // only focusable ones.
    const quiet = try flyout.open(app, .{ .anchor = .{ .window = .{ .owner = owner, .rect = anchor } }, .displays = &displays });
    testRecord(quiet).popupDismissed();
    try std.testing.expect(flyout.isOpen());
    try std.testing.expect(testRecord(quiet).keyInput(.{ .key = .escape }));
    try std.testing.expect(!flyout.isOpen());

    // A flyout closes with its owner.
    _ = try flyout.open(app, .{ .anchor = .{ .window = .{ .owner = owner, .rect = anchor } }, .displays = &displays });
    _ = try owner.destroy();
    try std.testing.expect(!flyout.isOpen());
}

fn ignoreTray(_: *anyopaque, _: *system.Tray, _: system.TrayAction) void {}
test "flyouts without an owner float above others, beside a rectangle or centered" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const displays = [_]system.desktop.Monitor{
        .{ .bounds = .{ .x = 0, .y = 0, .width = 1000, .height = 800 }, .work_area = .{ .x = 0, .y = 0, .width = 1000, .height = 760 }, .scale = 1, .primary = true, .refresh_hz = null },
        .{ .bounds = .{ .x = 1000, .y = 0, .width = 800, .height = 600 }, .work_area = .{ .x = 1000, .y = 0, .width = 800, .height = 600 }, .scale = 1, .primary = false, .refresh_hz = null },
    };
    var flyout: system.Flyout = .{};
    // Above an icon of a taskbar at the bottom of the second display.
    const window = try flyout.open(app, .{ .anchor = .{ .screen = .{ .x = 1700, .y = 580, .width = 20, .height = 20 } }, .placement = .bottom, .gap = 4, .width = 280, .height = 230, .displays = &displays });
    try std.testing.expectEqual(z.ClientBounds{ .position = .{ .x = 1520, .y = 346 }, .width = 280, .height = 230 }, try window.clientBounds());
    try std.testing.expectEqual(null, (try window.relationship()).owner);
    try flyout.toggle(app, .{ .anchor = .{ .screen = .{ .x = 0, .y = 0, .width = 1, .height = 1 } } });
    try std.testing.expect(!flyout.isOpen());

    // Without a reported icon, in the middle of the primary work area.
    var context: u8 = 0;
    var tray = system.Tray.init(&context, ignoreTray);
    try flyout.toggle(app, .{ .anchor = .{ .tray = &tray }, .width = 200, .height = 100, .displays = &displays });
    try std.testing.expect(flyout.isOpen());
    try std.testing.expectEqual(z.ClientBounds{ .position = .{ .x = 400, .y = 330 }, .width = 200, .height = 100 }, try flyout.window.?.clientBounds());
    try std.testing.expectError(error.InvalidPopup, app.createWindow(.{ .popup = .{} }));
    _ = try flyout.close();
    try std.testing.expect(!flyout.isOpen());
}
