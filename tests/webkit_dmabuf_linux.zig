//! WebKitGTK's DMA-BUF renderer stays off unless the app leaves it on,
//! everywhere or where the host is known to draw with it; the user's
//! variable always wins. The host is a fake root of files.
const std = @import("std");
const zio = @import("ziggurat_io");

extern fn zwk_dmabuf_disables(c_int, ?[*]const ?[*:0]const u8, [*:0]const u8) c_int;

test "the DMA-BUF renderer is off by default, on where asked, and on a Mesa GPU under Wayland for auto" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = zio.io();
    const root = try zio.realPathAlloc(tmp.dir, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeSentinel(u8, root, 0);
    defer std.testing.allocator.free(root_z);
    // A Wayland socket and a render node of Intel's driver.
    try tmp.dir.createDirPath(io, "run");
    const socket_path = try std.fs.path.join(std.testing.allocator, &.{ root, "run", "wayland-0" });
    defer std.testing.allocator.free(socket_path);
    const socket = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    try std.testing.expect(socket >= 0);
    defer _ = std.c.close(socket);
    var address: std.c.sockaddr.un = .{ .family = std.c.AF.UNIX, .path = @splat(0) };
    @memcpy(address.path[0..socket_path.len], socket_path);
    try std.testing.expectEqual(@as(c_int, 0), std.c.bind(socket, @ptrCast(&address), @sizeOf(std.c.sockaddr.un)));
    try tmp.dir.createDirPath(io, "sys/class/drm/renderD128/device");
    try tmp.dir.createDirPath(io, "sys/bus/pci/drivers/i915");
    try tmp.dir.symLink(io, "../../../../bus/pci/drivers/i915", "sys/class/drm/renderD128/device/driver", .{});
    const runtime = try std.fmt.allocPrintSentinel(std.testing.allocator, "XDG_RUNTIME_DIR={s}/run", .{root}, 0);
    defer std.testing.allocator.free(runtime);
    const wayland = [_]?[*:0]const u8{ "WAYLAND_DISPLAY=wayland-0", runtime.ptr, null };
    const x11 = [_]?[*:0]const u8{ "DISPLAY=:0", null };
    const forced_x11 = [_]?[*:0]const u8{ "WAYLAND_DISPLAY=wayland-0", runtime.ptr, "GDK_BACKEND=x11", null };
    const software = [_]?[*:0]const u8{ "WAYLAND_DISPLAY=wayland-0", runtime.ptr, "LIBGL_ALWAYS_SOFTWARE=1", null };
    const user_on = [_]?[*:0]const u8{ "WEBKIT_DISABLE_DMABUF_RENDERER=0", null };
    try std.testing.expectEqual(@as(c_int, 1), zwk_dmabuf_disables(0, &wayland, root_z));
    try std.testing.expectEqual(@as(c_int, 0), zwk_dmabuf_disables(1, &x11, root_z));
    try std.testing.expectEqual(@as(c_int, 0), zwk_dmabuf_disables(2, &wayland, root_z));
    try std.testing.expectEqual(@as(c_int, 1), zwk_dmabuf_disables(2, &x11, root_z));
    try std.testing.expectEqual(@as(c_int, 1), zwk_dmabuf_disables(2, &forced_x11, root_z));
    try std.testing.expectEqual(@as(c_int, 1), zwk_dmabuf_disables(2, &software, root_z));
    // The user's variable wins whatever the app chose.
    try std.testing.expectEqual(@as(c_int, 0), zwk_dmabuf_disables(0, &user_on, root_z));
    // NVIDIA's driver, a container and a virtual machine turn it off.
    try tmp.dir.createDirPath(io, "sys/module/nvidia");
    try std.testing.expectEqual(@as(c_int, 1), zwk_dmabuf_disables(2, &wayland, root_z));
    try tmp.dir.deleteTree(io, "sys/module");
    try tmp.dir.writeFile(io, .{ .sub_path = ".dockerenv", .data = "" });
    try std.testing.expectEqual(@as(c_int, 1), zwk_dmabuf_disables(2, &wayland, root_z));
    try tmp.dir.deleteFile(io, ".dockerenv");
    try tmp.dir.createDirPath(io, "sys/class/dmi/id");
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/class/dmi/id/sys_vendor", .data = "QEMU\n" });
    try std.testing.expectEqual(@as(c_int, 1), zwk_dmabuf_disables(2, &wayland, root_z));
    try tmp.dir.deleteFile(io, "sys/class/dmi/id/sys_vendor");
    try std.testing.expectEqual(@as(c_int, 0), zwk_dmabuf_disables(2, &wayland, root_z));
    // A display-only driver draws nothing on the GPU.
    try tmp.dir.deleteFile(io, "sys/class/drm/renderD128/device/driver");
    try tmp.dir.createDirPath(io, "sys/bus/platform/drivers/simpledrm");
    try tmp.dir.symLink(io, "../../../../bus/platform/drivers/simpledrm", "sys/class/drm/renderD128/device/driver", .{});
    try std.testing.expectEqual(@as(c_int, 1), zwk_dmabuf_disables(2, &wayland, root_z));
}
