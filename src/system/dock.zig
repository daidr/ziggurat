//! The application's Dock icon on macOS: the menu the Dock shows above its
//! own items when the user right-clicks the icon, and the icon itself. The
//! badge, progress and attention bounce are `taskbar.Taskbar`'s, as for the
//! taskbars of other systems.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const types = @import("types.zig");
const menus = @import("menus.zig");

const macos = builtin.os.tag == .macos and !builtin.is_test;
const native = if (macos) @import("macos.zig") else struct {};

pub const capabilities = .{ .menu = macos, .icon = macos };

extern fn zsm_dock_menu(items: [*]const native.NativeItem, count: u32, owner: ?*anyopaque, serial: u64, done: *const fn (?*anyopaque, u64, i32) callconv(.c) void) ?*anyopaque;
extern fn zsm_dock_remove(dock: *anyopaque, clear: c_int) void;
extern fn zsm_dock_icon(png: ?[*]const u8, length: usize) c_int;

/// Keep at a stable address while a menu is set. Main thread only. One Dock
/// menu shows at a time: the one set last.
pub const Dock = struct {
    context: *anyopaque,
    /// An enabled command of the Dock menu.
    on_menu: *const fn (*anyopaque, *Dock, u64) void,
    app: ?*z.App = null,
    handle: ?*anyopaque = null,
    ids: [types.max_menu_items]u64 = undefined,
    enabled: [types.max_menu_items]bool = undefined,
    count: usize = 0,
    serial: u64 = 0,

    pub fn init(context: *anyopaque, on_menu: *const fn (*anyopaque, *Dock, u64) void) Dock {
        return .{ .context = context, .on_menu = on_menu };
    }
    /// Replaces the Dock menu; an empty slice removes it. Items are copied.
    /// Standard roles run as in a menu bar.
    pub fn setMenu(self: *Dock, app: *z.App, items: []const types.Item) !void {
        app.assertOwner();
        if (comptime !macos) return error.UnsupportedCapability;
        if (self.app) |current| if (current != app) return error.AlreadyAttached;
        const plan = try menus.validate(items, false);
        if (items.len == 0) return self.clear();
        var labels: [types.max_menu_items][512]u8 = undefined;
        var native_items: [types.max_menu_items]native.NativeItem = undefined;
        var ids: [types.max_menu_items]u64 = undefined;
        var enabled: [types.max_menu_items]bool = undefined;
        const commands = try native.nativeItems(items, &plan, &labels, &native_items, &ids, &enabled);
        for (native_items[0..items.len], 0..) |*item, index| item.enabled = @intFromBool(plan.enabled[index]);
        if (self.serial == std.math.maxInt(u64)) return error.IdExhausted;
        self.serial += 1;
        const handle = zsm_dock_menu(&native_items, @intCast(items.len), self, self.serial, done) orelse return error.MenuAttachFailed;
        if (self.handle) |old| zsm_dock_remove(old, 0);
        self.handle = handle;
        self.app = app;
        @memcpy(self.ids[0..commands], ids[0..commands]);
        @memcpy(self.enabled[0..commands], enabled[0..commands]);
        self.count = commands;
    }
    /// Removes the menu this Dock set.
    pub fn clear(self: *Dock) !void {
        if (comptime !macos) return;
        if (self.app) |app| app.assertOwner();
        const handle = self.handle orelse return;
        self.handle = null;
        self.app = null;
        self.count = 0;
        zsm_dock_remove(handle, 1);
    }
    fn done(ptr: ?*anyopaque, serial: u64, command: i32) callconv(.c) void {
        const self: *Dock = @ptrCast(@alignCast(ptr.?));
        if (self.handle == null or serial != self.serial or command < 0 or command >= self.count) return;
        const index: usize = @intCast(command);
        if (!self.enabled[index]) return;
        const app = self.app orelse return;
        const scope = app.beginCallback() orelse return;
        defer scope.end();
        self.on_menu(self.context, self, self.ids[index]);
    }
};

/// Shows a PNG image as the application's Dock icon while it runs; null
/// restores the bundle's icon. The image is copied.
pub fn setIcon(app: *z.App, png: ?[]const u8) !void {
    app.assertOwner();
    if (comptime !macos) return error.UnsupportedCapability;
    if (png) |bytes| _ = try @import("png_header.zig").pngSize(bytes);
    if (zsm_dock_icon(if (png) |bytes| bytes.ptr else null, if (png) |bytes| bytes.len else 0) == 0) return error.IconDecodeFailed;
}

test "the Dock is macOS's and checks its menu first" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var context: u8 = 0;
    const Ignore = struct {
        fn menu(_: *anyopaque, _: *Dock, _: u64) void {}
    };
    var dock = Dock.init(&context, Ignore.menu);
    if (!macos) {
        try std.testing.expectError(error.UnsupportedCapability, dock.setMenu(app, &.{.{ .id = 1, .label = "New Window" }}));
        try std.testing.expectError(error.UnsupportedCapability, setIcon(app, null));
    }
    try dock.clear();
}
