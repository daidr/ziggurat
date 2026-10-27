const std = @import("std");

/// Compile each native translation unit as a build root so Zig 0.15.2 tracks
/// its indirect headers even when the consuming Zig module is imported.
/// The resulting object is shared by every executable using that module.
/// Configure compile-time native includes/pkg-config on the returned module;
/// final libraries remain explicit on the consuming module.
pub fn add(b: *std.Build, owner: *std.Build.Module, name: []const u8, path: []const u8, flags: []const []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const native = b.addObject(.{ .name = name, .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    native.root_module.addCSourceFile(.{ .file = b.path(path), .flags = flags });
    if (target.result.os.tag == .macos) appleSdk(b, native.root_module);
    owner.addObject(native);
    return native.root_module;
}

/// Keep optional native code in an archive member. Only a real undefined
/// symbol pulls that member into an executable; an unused preparation API does
/// not retain its embedded program. This is also a distinct C build root.
pub fn addArchive(b: *std.Build, owner: *std.Build.Module, name: []const u8, path: []const u8, flags: []const []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const native = b.addLibrary(.{ .name = name, .linkage = .static, .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    native.root_module.addCSourceFile(.{ .file = b.path(path), .flags = flags });
    owner.linkLibrary(native);
    return native.root_module;
}

/// Cross-compiling for macOS takes the SDK from `--sysroot`; a native macOS
/// build finds it through the installed developer tools instead.
pub fn appleSdk(b: *std.Build, module: *std.Build.Module) void {
    const sysroot = b.sysroot orelse return;
    module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
    module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr/include" }) });
    // The linker prefixes library paths with the sysroot itself.
    module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
}

/// Links Apple frameworks on a module, with the cross-compilation SDK paths.
pub fn linkFrameworks(b: *std.Build, module: *std.Build.Module, frameworks: []const []const u8) void {
    appleSdk(b, module);
    for (frameworks) |framework| module.linkFramework(framework, .{});
    module.link_libc = true;
}
