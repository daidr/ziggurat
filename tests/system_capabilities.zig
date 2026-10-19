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
