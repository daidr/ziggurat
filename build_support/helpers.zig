//! Helpers shared by build.zig and the build_support step files.
const std = @import("std");
const packaging = @import("packaging.zig");
const native_support = @import("native.zig");

pub fn linksSqlite(compile: *std.Build.Step.Compile) bool {
    if (std.mem.eql(u8, compile.name, "sqlite-native")) return true;
    for (compile.root_module.getGraph().modules) |module| for (module.link_objects.items) |object| switch (object) {
        .other_step => |other| if (std.mem.eql(u8, other.name, "sqlite-native")) return true,
        else => {},
    };
    return false;
}
/// Windows Debug artifacts use Zig's self-hosted x86_64 backend and COFF
/// linker, which compile far faster than LLVM on the CI runner (Linux Debug
/// already defaults to them). Release builds and steps that pin `use_llvm`
/// keep LLVM. The self-hosted linker cannot yet read two kinds of mingw-w64
/// import, so affected executables get src/c/windows/assert_shim.c and an
/// import library for UI Automation generated from a lower-case definition.
/// The linker also binds `@sin`-style calls to UCRT rather than compiler-rt,
/// so they link src/c/windows/math, which defines those symbols from
/// compiler-rt's code. The self-hosted backend writes no PDB, so installs
/// skip it, and root modules are stripped.
/// Debug images with the SQLite amalgamation crash in most tests when Zig's
/// own backend and linker build them; those keep LLVM.
pub fn useWindowsSelfHostedBackend(b: *std.Build, llvm: bool) void {
    var steps: std.array_hash_map.Auto(*std.Build.Step, void) = .empty;
    var it = b.top_level_steps.iterator();
    while (it.next()) |entry| collectSteps(b, &steps, &entry.value_ptr.*.step);

    var automation_library: ?std.Build.LazyPath = null;
    var math_library: ?*std.Build.Step.Compile = null;
    var resource_tool: ?*std.Build.Step.Compile = null;
    var patched: std.AutoHashMapUnmanaged(*std.Build.Step.Compile, *std.Build.Step) = .empty;
    for (steps.keys()) |step| {
        const compile = step.cast(std.Build.Step.Compile) orelse continue;
        if (compile.rootModuleTarget().os.tag != .windows or compile.use_llvm != null) continue;
        if (llvm) continue;
        const optimize = compile.root_module.optimize orelse .debug;
        if (optimize != .debug) continue;
        if (linksSqlite(compile)) continue;
        compile.use_llvm = false;
        for (compile.root_module.getGraph().modules) |module| for (module.link_objects.items) |*object| switch (object.*) {
            .system_lib => |library| if (std.ascii.eqlIgnoreCase(library.name, "uiautomationcore")) {
                object.* = .{ .static_path = automation_library orelse blk: {
                    const generate = b.addSystemCommand(&.{ b.graph.zig_exe, "dlltool", "-m", "i386:x86-64", "-d" });
                    generate.addFileArg(b.path("src/c/windows/uiautomationcore.def"));
                    generate.addArg("-l");
                    automation_library = generate.addOutputFileArg("uiautomationcore.lib");
                    break :blk automation_library.?;
                } };
            },
            else => {},
        };
        if (compile.kind == .exe or compile.kind == .@"test") {
            // Root modules can be shared with object files that are linked
            // into the same executable, so give this artifact its own copy
            // to keep the shim from being linked twice.
            const root = b.allocator.create(std.Build.Module) catch @panic("OOM");
            root.* = compile.root_module.*;
            root.link_objects = compile.root_module.link_objects.clone(b.allocator) catch @panic("OOM");
            root.cached_graph = .{ .modules = &.{}, .names = &.{} };
            // With no PDB the image's debug information is never read, and
            // emitting it for some roots crashes the compiler (web-counter
            // with -Dwebview): leave it out.
            if (root.strip == null) root.strip = true;
            // Zig's COFF linker drops resource sections, so compile the
            // resources separately and add them to the linked image.
            var resources: std.ArrayList(*std.Build.Module.RcSourceFile) = .empty;
            var kept: usize = 0;
            for (root.link_objects.items) |object| switch (object) {
                .win32_resource_file => |file| resources.append(b.allocator, file) catch @panic("OOM"),
                else => {
                    root.link_objects.items[kept] = object;
                    kept += 1;
                },
            };
            root.link_objects.shrinkRetainingCapacity(kept);
            if (resources.items.len > 1) std.debug.panic("{s}: more than one resource file", .{compile.name});
            if (resources.items.len == 1) {
                const file = resources.items[0];
                const rc = b.addSystemCommand(&.{ b.graph.zig_exe, "rc", "/:output-format", "coff", "/:target", @tagName(compile.rootModuleTarget().cpu.arch), "/:auto-includes", "gnu", "/x", "/D_DEBUG" });
                rc.addArgs(file.flags);
                for (file.include_paths) |path| {
                    rc.addArg("/i");
                    rc.addDirectoryArg(path);
                }
                rc.addFileArg(file.file);
                // The generated script starts with `#pragma code_page`, which
                // makes the resource compiler print a warning; keep it out of the build output.
                _ = rc.captureStdErr(.{});
                const object = rc.addOutputFileArg("resources.obj");
                const tool = resource_tool orelse blk: {
                    resource_tool = b.addExecutable(.{ .name = "ziggurat-pe-resources", .root_module = b.createModule(.{ .root_source_file = b.path("tools/pe_resources.zig"), .target = b.graph.host, .optimize = .Debug }), .use_llvm = if (b.graph.host.result.os.tag == .windows) false else null });
                    break :blk resource_tool.?;
                };
                const patch = b.addRunArtifact(tool);
                patch.addFileArg(compile.getEmittedBin());
                patch.addFileArg(object);
                patched.put(b.allocator, compile, &patch.step) catch @panic("OOM");
            }
            root.addCSourceFile(.{ .file = b.path("src/c/windows/assert_shim.c") });
            root.linkLibrary(math_library orelse blk: {
                const sources = b.addWriteFiles();
                _ = sources.addCopyDirectory(.{ .relative = .{ .base = .zig_lib, .sub_path = "compiler_rt" } }, "compiler_rt", .{});
                _ = sources.addCopyFile(b.path("src/c/windows/math/compiler_rt.zig"), "compiler_rt.zig");
                const math_root = sources.addCopyFile(b.path("src/c/windows/math/root.zig"), "root.zig");
                math_library = b.addLibrary(.{ .name = "ziggurat-windows-math", .use_llvm = false, .root_module = b.createModule(.{
                    .root_source_file = math_root,
                    .target = compile.root_module.resolved_target,
                    .optimize = .fast,
                }) });
                break :blk math_library.?;
            });
            compile.root_module = root;
        }
    }
    for (steps.keys()) |step| {
        if (step.cast(std.Build.Step.Run)) |run| {
            // The image is patched in place, so everything that runs or
            // installs it waits for that.
            for (run.argv.items) |arg| switch (arg) {
                .artifact => |artifact| if (patched.get(artifact.artifact)) |patch| run.step.dependOn(patch),
                else => {},
            };
            continue;
        }
        const install = step.cast(std.Build.Step.InstallArtifact) orelse continue;
        if (patched.get(install.artifact)) |patch| install.step.dependOn(patch);
        if (install.artifact.producesPdbFile()) continue;
        install.pdb_dir = null;
        install.emitted_pdb = null;
    }
}

pub fn collectSteps(b: *std.Build, steps: *std.array_hash_map.Auto(*std.Build.Step, void), step: *std.Build.Step) void {
    if ((steps.getOrPut(b.allocator, step) catch @panic("OOM")).found_existing) return;
    for (step.dependencies.items) |dependency| collectSteps(b, steps, dependency);
}

/// Every module may import the process-wide Io (`ziggurat_io`) and the system
/// declarations (`ziggurat_c_win32`, `ziggurat_c_gtk`, `ziggurat_c_posix`).
/// They are added to each module reachable from a step or an exported module.
pub fn shareCommonModules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, check: *std.Build.Step, test_step: *std.Build.Step) void {
    // Shared modules leave target and optimization to the module importing them.
    const io = b.addModule("ziggurat_io", .{ .root_source_file = b.path("src/io/root.zig") });
    const io_tests = addTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("src/io/root.zig"), .target = target, .optimize = optimize }) });
    check.dependOn(&io_tests.step);
    test_step.dependOn(&b.addRunArtifact(io_tests).step);
    const win32 = b.addTranslateC(.{ .root_source_file = b.path("build_support/c/win32.h"), .target = target, .optimize = optimize });
    const shared = [_]std.Build.Module.Import{
        .{ .name = "ziggurat_io", .module = io },
        .{ .name = "ziggurat_c_win32", .module = win32.createModule() },
        .{ .name = "ziggurat_c_gtk", .module = b.createModule(.{ .root_source_file = b.path("src/c/gtk.zig") }) },
        .{ .name = "ziggurat_c_posix", .module = b.createModule(.{ .root_source_file = b.path("src/c/posix.zig") }) },
    };
    var modules: std.AutoArrayHashMapUnmanaged(*std.Build.Module, void) = .empty;
    var steps: std.AutoArrayHashMapUnmanaged(*std.Build.Step, void) = .empty;
    for (shared) |import| modules.put(b.allocator, import.module, {}) catch @panic("OOM");
    for (b.modules.values()) |module| collectModule(b, &modules, module);
    for (b.top_level_steps.values()) |top| collectStep(b, &modules, &steps, &top.step);
    for (modules.keys()[shared.len..]) |module| {
        // C-only executables have no Zig root to import into.
        if (module.root_source_file == null) continue;
        for (shared) |import| {
            if (!module.import_table.contains(import.name)) module.addImport(import.name, import.module);
        }
    }
}

pub fn collectStep(b: *std.Build, modules: *std.AutoArrayHashMapUnmanaged(*std.Build.Module, void), steps: *std.AutoArrayHashMapUnmanaged(*std.Build.Step, void), step: *std.Build.Step) void {
    if ((steps.getOrPut(b.allocator, step) catch @panic("OOM")).found_existing) return;
    if (step.cast(std.Build.Step.Compile)) |compile| collectModule(b, modules, compile.root_module);
    // A run step names the executable it runs without depending on its step.
    if (step.cast(std.Build.Step.Run)) |run| if (run.producer) |producer| collectStep(b, modules, steps, &producer.step);
    for (step.dependencies.items) |dependency| collectStep(b, modules, steps, dependency);
}

pub fn collectModule(b: *std.Build, modules: *std.AutoArrayHashMapUnmanaged(*std.Build.Module, void), module: *std.Build.Module) void {
    if ((modules.getOrPut(b.allocator, module) catch @panic("OOM")).found_existing) return;
    for (module.import_table.values()) |import| collectModule(b, modules, import);
}

pub fn sourcePath(b: *std.Build, path: []const u8) std.Build.LazyPath {
    return if (std.fs.path.isAbsolute(path)) .{ .cwd_relative = path } else b.path(path);
}

pub fn addExample(b: *std.Build, name: []const u8, path: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, imports: []const std.Build.Module.Import) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    addResources(b, exe);
    b.installArtifact(exe);
    b.top_level_steps.get("check").?.step.dependOn(&exe.step);
    const run = runInstalled(b, b.graph.path(.install_bin, b.fmt("{s}{s}", .{ name, if (target.result.os.tag == .windows) ".exe" else "" })));
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step(b.fmt("run-{s}", .{name}), b.fmt("Run {s}", .{name})).dependOn(&run.step);
    b.step(b.fmt("example-{s}", .{name}), b.fmt("Compile and install only {s}", .{name})).dependOn(&b.addInstallArtifact(exe, .{}).step);
    return exe;
}

pub fn addLinuxPointerCoreSmoke(b: *std.Build, check: *std.Build.Step, core: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const smoke = b.addExecutable(.{ .name = "smoke-pointer-core-linux", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/linux_pointer_core_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ziggurat", .module = core }},
        .link_libc = true,
    }) });
    smoke.root_module.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
    check.dependOn(&smoke.step);
    const install = b.addInstallArtifact(smoke, .{});
    b.step("build-smoke-pointer-core-linux", "Build the real GTK-to-Core pointer boundary check").dependOn(&install.step);
    const run = runInstalled(b, b.graph.path(.install_bin, "smoke-pointer-core-linux"));
    run.step.dependOn(&install.step);
    b.step("smoke-pointer-core-linux", "Verify real GTK/Core pointer facts and independent callback scopes").dependOn(&run.step);
}

pub fn addPointerCostSmoke(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module) void {
    const name = "smoke-pointer-cost";
    const exe = b.addExecutable(.{ .name = name, .root_module = b.createModule(.{
        .root_source_file = b.path("tests/pointer_cost_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "ziggurat", .module = core }},
    }) });
    exe.root_module.addCSourceFile(.{ .file = b.path("tests/pointer_cost_windows.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    addResources(b, exe);
    b.top_level_steps.get("check").?.step.dependOn(&exe.step);
    const install = b.addInstallArtifact(exe, .{});
    b.step("build-" ++ name, "Build the isolated native pointer cost probe").dependOn(&install.step);
    const run = runInstalled(b, b.graph.path(.install_bin, name ++ ".exe"));
    run.step.dependOn(&install.step);
    run.addPassthruArgs();
    b.step(name, "Measure caller allocations and selected real native pointer calls").dependOn(&run.step);
}

pub fn addWebNativeBoundarySmoke(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module, view: *std.Build.Module) void {
    const name = "smoke-webview-native-boundary";
    const exe = b.addExecutable(.{ .name = name, .root_module = b.createModule(.{
        .root_source_file = b.path("tests/webview_native_boundary_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view } },
    }) });
    if (target.result.os.tag == .linux) exe.root_module.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
    addResources(b, exe);
    b.top_level_steps.get("check").?.step.dependOn(&exe.step);
    const install = b.addInstallArtifact(exe, .{});
    const build_step = b.step("build-" ++ name, "Build the independent SDK callback ownership probe");
    build_step.dependOn(&install.step);
    build_step.dependOn(&b.top_level_steps.get("webview-runtime").?.step);
    const run = runInstalled(b, b.graph.path(.install_bin, b.fmt("{s}{s}", .{ name, if (target.result.os.tag == .windows) ".exe" else "" })));
    run.step.dependOn(&install.step);
    run.step.dependOn(&b.top_level_steps.get("webview-runtime").?.step);
    run.addPassthruArgs();
    b.step(name, "Verify synchronous SDK completion cannot borrow pointer ingress").dependOn(&run.step);
}

/// The WebView2 adapter references the owned Profile lifetime, storage and
/// session objects. Every module that compiles or includes the adapter links
/// them once, together with their security and certificate libraries.
pub fn addWindowsProfileNative(b: *std.Build, owner: *std.Build.Module, prefix: []const u8, sdk: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const native = native_support.add(b, owner, b.fmt("{s}-windows_profile.c", .{prefix}), "src/webview/windows_profile.c", &.{"-std=c11"}, target, optimize);
    native.addIncludePath(sourcePath(b, b.pathJoin(&.{ sdk, "build/native/include" })));
    native.addIncludePath(b.path("src/webview/include"));
    owner.linkSystemLibrary("crypt32", .{});
    addWindowsProfileStorageNative(b, owner, prefix, target, optimize);
}

/// Profile storage preparation and process lifetime need no WebView2 SDK.
pub fn addWindowsProfileStorageNative(b: *std.Build, owner: *std.Build.Module, prefix: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    for ([_][]const u8{ "windows_profile_lifetime.c", "windows_profile_storage.c" }) |file|
        _ = native_support.add(b, owner, b.fmt("{s}-{s}", .{ prefix, file }), b.fmt("src/webview/{s}", .{file}), &.{"-std=c11"}, target, optimize);
    owner.linkSystemLibrary("advapi32", .{});
}

/// Single-instance, registration, power and taskbar natives of ziggurat_system.
pub fn addSystemIntegrationNative(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    switch (target.result.os.tag) {
        .windows => {
            _ = native_support.add(b, module, "system-taskbar-native", "src/system/taskbar_windows.c", &.{"-std=c11"}, target, optimize);
            _ = native_support.add(b, module, "system-jump-list-native", "src/system/jump_list_windows.c", &.{"-std=c11"}, target, optimize);
            _ = native_support.add(b, module, "system-notification-image-native", "src/system/notification_image_windows.c", &.{"-std=c11"}, target, optimize);
            for ([_][]const u8{ "advapi32", "ole32", "shell32", "windowscodecs" }) |library| module.linkSystemLibrary(library, .{});
            module.link_libc = true;
        },
        .linux => {
            const native = native_support.add(b, module, "system-integration-native", "src/system/linux_integration.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
            for ([_][]const u8{ "gio-2.0", "gio-unix-2.0" }) |library| {
                native.linkSystemLibrary(library, .{ .use_pkg_config = .yes });
                module.linkSystemLibrary(library, .{ .use_pkg_config = .yes });
            }
            module.link_libc = true;
        },
        .macos => {
            // Keychain, sleep assertions, recent documents, appearance,
            // shell hand-offs, login items, URL schemes and desktop state.
            _ = native_support.add(b, module, "system-services-native", "src/system/macos_services.m", &.{ "-fobjc-arc", "-Wall", "-Wextra", "-Werror" }, target, optimize);
            _ = native_support.add(b, module, "system-clipboard-native", "src/system/macos_clipboard.m", &.{ "-fobjc-arc", "-Wall", "-Wextra", "-Werror" }, target, optimize);
            _ = native_support.add(b, module, "system-drag-native", "src/system/macos_drag.m", &.{ "-fobjc-arc", "-Wall", "-Wextra", "-Werror" }, target, optimize);
            _ = native_support.add(b, module, "system-media-native", "src/system/macos_media.m", &.{ "-fobjc-arc", "-Wall", "-Wextra", "-Werror" }, target, optimize);
            // TCC permissions and the guide's panel; AVFoundation, EventKit
            // and CoreBluetooth load at run time.
            _ = native_support.add(b, module, "system-permissions-native", "src/system/macos_permissions.m", &.{ "-fobjc-arc", "-Wall", "-Wextra", "-Werror" }, target, optimize);
            native_support.linkFrameworks(b, module, &.{ "AppKit", "Foundation", "Security", "ServiceManagement", "IOKit", "Network", "CoreServices", "CoreFoundation", "UniformTypeIdentifiers", "MediaPlayer", "ApplicationServices", "CoreGraphics" });
        },
        else => {},
    }
}

/// One end-to-end page: the runtime package bundled into a hidden window.
pub fn addPageRuntimeSmoke(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module, view: *std.Build.Module, ipc: *std.Build.Module, i18n: *std.Build.Module, page_runtime: *std.Build.Module, net: *std.Build.Module, plugin_fetch: *std.Build.Module, plugin_watch: *std.Build.Module, plugin_sqlite: *std.Build.Module, plugin_websocket: *std.Build.Module) void {
    const fetch_bundle = b.addSystemCommand(&.{ "bun", "build" });
    fetch_bundle.addFileArg(b.path("tests/plugin_fetch_page.ts"));
    fetch_bundle.addFileInput(b.path("packages/runtime/src/index.ts"));
    fetch_bundle.addFileInput(b.path("packages/plugin-fetch/src/index.ts"));
    fetch_bundle.addFileInput(b.path("packages/plugin-fetch/src/generated/fetch.ts"));
    fetch_bundle.addArgs(&.{ "--target", "browser", "--format", "iife", "--outfile" });
    const fetch_page = b.createModule(.{ .root_source_file = fetch_bundle.addOutputFileArg("plugin-fetch-page.js") });
    addSmoke(b, "smoke-plugin-fetch", "tests/plugin_fetch_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_webview", .module = view },
        .{ .name = "ziggurat_net", .module = net },
        .{ .name = "ziggurat_page_runtime", .module = page_runtime },
        .{ .name = "ziggurat_plugin_fetch", .module = plugin_fetch },
        .{ .name = "plugin_fetch_page", .module = fetch_page },
    });
    const watch_bundle = b.addSystemCommand(&.{ "bun", "build" });
    watch_bundle.addFileArg(b.path("tests/plugin_watch_page.ts"));
    watch_bundle.addFileInput(b.path("packages/runtime/src/index.ts"));
    watch_bundle.addFileInput(b.path("packages/plugin-watch/src/index.ts"));
    watch_bundle.addFileInput(b.path("packages/plugin-watch/src/generated/watch.ts"));
    watch_bundle.addArgs(&.{ "--target", "browser", "--format", "iife", "--outfile" });
    const watch_page = b.createModule(.{ .root_source_file = watch_bundle.addOutputFileArg("plugin-watch-page.js") });
    addSmoke(b, "smoke-plugin-watch", "tests/plugin_watch_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_webview", .module = view },
        .{ .name = "ziggurat_page_runtime", .module = page_runtime },
        .{ .name = "ziggurat_plugin_watch", .module = plugin_watch },
        .{ .name = "plugin_watch_page", .module = watch_page },
    });
    const sqlite_bundle = b.addSystemCommand(&.{ "bun", "build" });
    sqlite_bundle.addFileArg(b.path("tests/plugin_sqlite_page.ts"));
    sqlite_bundle.addFileInput(b.path("packages/runtime/src/index.ts"));
    sqlite_bundle.addFileInput(b.path("packages/plugin-sqlite/src/index.ts"));
    sqlite_bundle.addFileInput(b.path("packages/plugin-sqlite/src/generated/sqlite.ts"));
    sqlite_bundle.addArgs(&.{ "--target", "browser", "--format", "iife", "--outfile" });
    const sqlite_page = b.createModule(.{ .root_source_file = sqlite_bundle.addOutputFileArg("plugin-sqlite-page.js") });
    addSmoke(b, "smoke-plugin-sqlite", "tests/plugin_sqlite_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_webview", .module = view },
        .{ .name = "ziggurat_page_runtime", .module = page_runtime },
        .{ .name = "ziggurat_plugin_sqlite", .module = plugin_sqlite },
        .{ .name = "plugin_sqlite_page", .module = sqlite_page },
    });
    const websocket_bundle = b.addSystemCommand(&.{ "bun", "build" });
    websocket_bundle.addFileArg(b.path("tests/plugin_websocket_page.ts"));
    websocket_bundle.addFileInput(b.path("packages/runtime/src/index.ts"));
    websocket_bundle.addFileInput(b.path("packages/plugin-websocket/src/index.ts"));
    websocket_bundle.addFileInput(b.path("packages/plugin-websocket/src/generated/websocket.ts"));
    websocket_bundle.addArgs(&.{ "--target", "browser", "--format", "iife", "--outfile" });
    const websocket_page = b.createModule(.{ .root_source_file = websocket_bundle.addOutputFileArg("plugin-websocket-page.js") });
    addSmoke(b, "smoke-plugin-websocket", "tests/plugin_websocket_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_webview", .module = view },
        .{ .name = "ziggurat_page_runtime", .module = page_runtime },
        .{ .name = "ziggurat_plugin_websocket", .module = plugin_websocket },
        .{ .name = "plugin_websocket_page", .module = websocket_page },
    });
    const bundle = b.addSystemCommand(&.{ "bun", "build" });
    bundle.addFileArg(b.path("tests/page_runtime_page.ts"));
    bundle.addFileInput(b.path("tests/ipc_fixture.ts"));
    bundle.addFileInput(b.path("packages/runtime/src/index.ts"));
    bundle.addFileInput(b.path("packages/runtime/src/generated/runtime.ts"));
    bundle.addArgs(&.{ "--target", "browser", "--format", "iife", "--outfile" });
    const page = b.createModule(.{ .root_source_file = bundle.addOutputFileArg("page-runtime-page.js") });
    const counter_service = b.createModule(.{ .root_source_file = b.path("examples/counter_service.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat_ipc", .module = ipc }} });
    addSmoke(b, "smoke-page-runtime", "tests/page_runtime_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_webview", .module = view },
        .{ .name = "ziggurat_ipc", .module = ipc },
        .{ .name = "ziggurat_i18n", .module = i18n },
        .{ .name = "ziggurat_page_runtime", .module = page_runtime },
        .{ .name = "counter_service", .module = counter_service },
        .{ .name = "page_runtime_page", .module = page },
    });
}

/// Web views laid out in declarative native UI.
pub fn addEmbeddedWebView(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module, ui: *std.Build.Module, declarative_view: *std.Build.Module, view: *std.Build.Module) void {
    const embedded = b.addModule("ziggurat_webview_view", .{ .root_source_file = b.path("src/webview/embedded.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_view", .module = declarative_view },
        .{ .name = "ziggurat_webview", .module = view },
    } });
    // The embedded web view smoke paints through the GTK and Win32 test
    // hooks; macOS has its own below.
    if (target.result.os.tag != .macos) addSmoke(b, "smoke-embedded-webview", "tests/embedded_webview_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_view", .module = declarative_view },
        .{ .name = "ziggurat_webview", .module = view },
        .{ .name = "ziggurat_webview_view", .module = embedded },
    });
    if (target.result.os.tag == .linux) {
        const scroll_smoke = b.addExecutable(.{ .name = "smoke-webview-scroll-linux", .root_module = b.createModule(.{ .root_source_file = b.path("tests/linux_webview_scroll_smoke.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_view", .module = declarative_view }, .{ .name = "ziggurat_webview", .module = view }, .{ .name = "ziggurat_webview_view", .module = embedded } } }) });
        scroll_smoke.root_module.addCSourceFile(.{ .file = b.path("tests/linux_webview_scroll_probe.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        scroll_smoke.root_module.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes });
        b.top_level_steps.get("check").?.step.dependOn(&scroll_smoke.step);
        b.step("smoke-webview-scroll-linux", "Verify that the wheel over a web view with scroll_to_container scrolls the native container, and that the keys its page leaves come to the native UI").dependOn(&b.addRunArtifact(scroll_smoke).step);
        const media_smoke = b.addExecutable(.{ .name = "smoke-webview-media-linux", .root_module = b.createModule(.{ .root_source_file = b.path("tests/linux_media_webview_smoke.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view } } }) });
        media_smoke.root_module.addCSourceFile(.{ .file = b.path("tests/linux_media_webview_probe.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        media_smoke.root_module.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes });
        b.top_level_steps.get("check").?.step.dependOn(&media_smoke.step);
        b.step("smoke-webview-media-linux", "Verify camera and microphone permission offers and capture state through WebKitGTK's mock devices").dependOn(&b.addRunArtifact(media_smoke).step);
        const overlay_smoke = b.addExecutable(.{ .name = "smoke-webview-overlay-linux", .root_module = b.createModule(.{ .root_source_file = b.path("tests/linux_webview_overlay_smoke.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui }, .{ .name = "ziggurat_view", .module = declarative_view }, .{ .name = "ziggurat_webview", .module = view }, .{ .name = "ziggurat_webview_view", .module = embedded } } }) });
        overlay_smoke.root_module.addCSourceFile(.{ .file = b.path("tests/linux_webview_overlay_probe.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        overlay_smoke.root_module.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes });
        b.top_level_steps.get("check").?.step.dependOn(&overlay_smoke.step);
        b.step("smoke-webview-overlay-linux", "Verify native UI over an embedded page, Tab into, through and out of it, and its tree inside the native UI's").dependOn(&b.addRunArtifact(overlay_smoke).step);
    }
    if (target.result.os.tag == .windows) addSmoke(b, "smoke-webview-overlay-windows", "tests/windows_webview_overlay_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_view", .module = declarative_view },
        .{ .name = "ziggurat_webview", .module = view },
        .{ .name = "ziggurat_webview_view", .module = embedded },
    });
    if (target.result.os.tag == .macos) {
        const overlay = addSmokeModule(b, "smoke-webview-overlay-macos", "tests/macos_webview_overlay_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_ui", .module = ui },
            .{ .name = "ziggurat_view", .module = declarative_view },
            .{ .name = "ziggurat_webview", .module = view },
            .{ .name = "ziggurat_webview_view", .module = embedded },
        });
        _ = native_support.add(b, overlay, "webview-overlay-probe-macos", "tests/macos_webview_overlay_probe.m", &.{ "-fobjc-arc", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        native_support.linkFrameworks(b, overlay, &.{ "AppKit", "Foundation" });
    }
}

pub fn addSmoke(b: *std.Build, name: []const u8, path: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, imports: []const std.Build.Module.Import) void {
    _ = addSmokeExecutable(b, name, path, target, optimize, imports);
}

/// Like addSmoke, returning the root module for native test fixtures.
pub fn addSmokeModule(b: *std.Build, name: []const u8, path: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, imports: []const std.Build.Module.Import) *std.Build.Module {
    return addSmokeExecutable(b, name, path, target, optimize, imports).root_module;
}

/// addSmoke that returns the executable for test-only native additions.
pub fn addSmokeExecutable(b: *std.Build, name: []const u8, path: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, imports: []const std.Build.Module.Import) *std.Build.Step.Compile {
    // Error return traces name the check that failed in release builds too.
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize, .error_tracing = true, .imports = imports }),
    });
    addResources(b, exe);
    const install = b.addInstallArtifact(exe, .{});
    b.step(b.fmt("build-{s}", .{name}), "Build a hidden-window integration executable without running it").dependOn(&install.step);
    const run = runInstalled(b, b.graph.path(.install_bin, b.fmt("{s}{s}", .{ name, if (target.result.os.tag == .windows) ".exe" else "" })));
    run.step.dependOn(&install.step);
    for (imports) |dependency| {
        if (std.mem.eql(u8, dependency.name, "ziggurat_webview")) run.step.dependOn(&b.top_level_steps.get("webview-runtime").?.step);
    }
    run.addPassthruArgs();
    b.step(name, "Run integration checks with hidden windows").dependOn(&run.step);
    b.top_level_steps.get("check").?.step.dependOn(&exe.step);
    return exe;
}

/// Where an application's Windows icon comes from: this package's default
/// icon, an .ico, or a square PNG (ideally 1024x1024) rendered at each icon
/// size when the app builds.
pub const ApplicationIcon = union(enum) {
    default,
    ico: std.Build.LazyPath,
    png: std.Build.LazyPath,
};

/// For applications that depend on this package: embed the Windows manifest,
/// version resource and icon. Other targets need no resources.
pub fn addApplicationResources(b: *std.Build, exe: *std.Build.Step.Compile, dependency: *std.Build.Dependency, metadata: packaging.Metadata) void {
    addApplicationResourcesWithIcon(b, exe, dependency, metadata, .default);
}

/// As `addApplicationResources`, with the app's own icon.
pub fn addApplicationResourcesWithIcon(b: *std.Build, exe: *std.Build.Step.Compile, dependency: *std.Build.Dependency, metadata: packaging.Metadata, icon: ApplicationIcon) void {
    if (exe.root_module.resolved_target.?.result.cpu.arch == .wasm32) return addBrowserSite(b, exe, dependency);
    if (exe.root_module.resolved_target.?.result.os.tag != .windows) return;
    const file = iconFile(b, dependency.path("tools/icon_main.zig"), dependency.path("assets/application.ico"), icon);
    _ = packaging.addWindowsResources(b, exe, .{ .metadata = metadata, .icon = file }) catch |err| std.debug.panic("invalid application resources: {s}", .{@errorName(err)});
}

/// The .ico of `icon`: a PNG is rendered by the icon tool, built for the
/// machine that runs the build.
pub fn iconFile(b: *std.Build, tool_source: std.Build.LazyPath, default: std.Build.LazyPath, icon: ApplicationIcon) std.Build.LazyPath {
    return switch (icon) {
        .default => default,
        .ico => |path| path,
        .png => |path| blk: {
            const tool = b.addExecutable(.{ .name = "ziggurat-icon", .root_module = b.createModule(.{ .root_source_file = tool_source, .target = b.graph.host, .optimize = .ReleaseSafe }) });
            const run = b.addRunArtifact(tool);
            run.addFileArg(path);
            break :blk run.addOutputFileArg("application.ico");
        },
    };
}

/// Runs an installed executable. The build runner forks children while other
/// steps write their files; until such a child execs it still holds those
/// write handles, so starting a file installed a moment ago can fail with
/// ETXTBSY. On POSIX hosts a shell retries only that failure (status 126).
/// The HTTP sign-in and certificate error smoke, which its Python host runs
/// with the loopback servers it starts.
pub fn addHttpAuthSmoke(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module, view: *std.Build.Module) *std.Build.Step.Run {
    const name = "smoke-webview-http-auth";
    const exe = b.addExecutable(.{ .name = name, .root_module = b.createModule(.{ .root_source_file = b.path("tests/http_auth_webview_smoke.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view } } }) });
    addResources(b, exe);
    const install = b.addInstallArtifact(exe, .{});
    b.step("build-" ++ name, "Build the HTTP sign-in smoke without running it").dependOn(&install.step);
    const python = if (b.graph.host.result.os.tag == .windows) "python" else "python3";
    const run = b.addSystemCommand(&.{ python, "-B", "tests/http_auth_host.py", "--exe" });
    run.addFileArg(b.graph.path(.install_bin, b.fmt("{s}{s}", .{ name, if (target.result.os.tag == .windows) ".exe" else "" })));
    run.step.dependOn(&install.step);
    run.step.dependOn(&b.top_level_steps.get("webview-runtime").?.step);
    b.step(name, "Answer HTTP sign-ins and certificate errors of loopback pages").dependOn(&run.step);
    b.top_level_steps.get("check").?.step.dependOn(&exe.step);
    return run;
}

pub fn runInstalled(b: *std.Build, executable: std.Build.LazyPath) *std.Build.Step.Run {
    if (b.graph.host.result.os.tag == .windows) return b.addRunFile(executable);
    const run = b.addSystemCommand(&.{ "/bin/sh", "-c", "n=0; while :; do \"$0\" \"$@\"; s=$?; if [ $s -ne 126 ] || [ $n -ge 20 ]; then exit $s; fi; n=$((n + 1)); sleep 0.1; done" });
    run.addFileArg(executable);
    return run;
}

/// A browser build of an application: its WebAssembly, the page's script and
/// a page loading them, installed as a static site under `web/<name>/`, and a
/// `web-<name>` step building it.
/// Sets up a browser build of `exe` (built for wasm32-wasi) and installs it
/// as a static site in <prefix>/web: index.html, ziggurat.js and app.wasm.
/// `addApplicationResources` calls this for browser targets.
pub fn addBrowserSite(b: *std.Build, exe: *std.Build.Step.Compile, dependency: *std.Build.Dependency) void {
    configureBrowserExecutable(exe);
    for ([_]struct { std.Build.LazyPath, []const u8 }{
        .{ exe.getEmittedBin(), "web/app.wasm" },
        .{ dependency.path("web/ziggurat.js"), "web/ziggurat.js" },
        .{ dependency.path("web/index.html"), "web/index.html" },
    }) |entry| b.getInstallStep().dependOn(&b.addInstallFileWithDir(entry[0], .prefix, entry[1]).step);
}

pub fn configureBrowserExecutable(exe: *std.Build.Step.Compile) void {
    exe.rdynamic = true;
    exe.stack_size = 8 * 1024 * 1024;
    // The page calls the callbacks Zig hands it, from the function table.
    exe.export_table = true;
    exe.initial_memory = null;
}

pub fn addWebApp(b: *std.Build, exe: *std.Build.Step.Compile) void {
    configureBrowserExecutable(exe);
    const step = b.step(b.fmt("web-{s}", .{exe.name}), b.fmt("Build {s} for browsers into zig-out/web/{s}", .{ exe.name, exe.name }));
    const dir = b.fmt("web/{s}", .{exe.name});
    const wasm = b.addInstallFileWithDir(exe.getEmittedBin(), .prefix, b.fmt("{s}/app.wasm", .{dir}));
    const script = b.addInstallFileWithDir(b.path("web/ziggurat.js"), .prefix, b.fmt("{s}/ziggurat.js", .{dir}));
    const page = b.addInstallFileWithDir(b.path("web/index.html"), .prefix, b.fmt("{s}/index.html", .{dir}));
    const all = if (b.top_level_steps.get("web")) |existing| &existing.step else b.step("web", "Build every browser app into zig-out/web (with -Dtarget=wasm32-wasi)");
    for ([_]*std.Build.Step{ &wasm.step, &script.step, &page.step }) |each| {
        step.dependOn(each);
        all.dependOn(each);
        b.getInstallStep().dependOn(each);
    }
}

pub fn addResources(b: *std.Build, exe: *std.Build.Step.Compile) void {
    if (exe.root_module.resolved_target.?.result.os.tag != .windows) return;
    const special = std.mem.eql(u8, exe.name, "smoke-packaging");
    _ = packaging.addWindowsResources(b, exe, .{
        .metadata = .{
            .identity = if (special) "org.ziggurat.PackagingSmoke" else b.fmt("org.ziggurat.{s}", .{exe.name}),
            .display_name = if (special) "Ziggurat \"资源\" & packaging \\ test" else b.fmt("Ziggurat {s}", .{exe.name}),
            .version = if (special) .{ .major = 1, .minor = 2, .patch = 3, .revision = 4 } else .{ .major = 0, .minor = 1, .patch = 0 },
            .description = "Ziggurat desktop application",
            // The packaging smoke checks a second string table.
            .translations = if (special) &.{.{ .language = "zh-Hans", .display_name = "Ziggurat 资源测试" }} else &.{},
        },
        // The packaging smoke checks icons rendered from a PNG.
        .icon = if (special) iconFile(b, b.path("tools/icon_main.zig"), b.path("assets/application.ico"), .{ .png = b.path("assets/application.png") }) else b.path("assets/application.ico"),
    }) catch |err| std.debug.panic("invalid application resources: {s}", .{@errorName(err)});
}

/// b.addTest with build_support/macos_test_runner.zig on macOS targets.
pub fn addTest(b: *std.Build, options: std.Build.TestOptions) *std.Build.Step.Compile {
    var with = options;
    // Named after the root file, so the build summary says which tests ran.
    if (std.mem.eql(u8, with.name, "test")) if (with.root_module.root_source_file) |root| switch (root) {
        .src_path => |source| {
            const path = @constCast(b.dupe(source.sub_path));
            std.mem.replaceScalar(u8, path, '\\', '/');
            var name = std.mem.trimEnd(u8, path, ".zig");
            if (std.mem.startsWith(u8, name, "src/")) name = name["src/".len..];
            if (std.mem.endsWith(u8, name, "/root")) name = name[0 .. name.len - "/root".len];
            const named = b.fmt("test-{s}", .{name});
            std.mem.replaceScalar(u8, named, '/', '-');
            with.name = named;
        },
        else => {},
    };
    if (with.test_runner == null) if (with.root_module.resolved_target) |target| if (target.result.os.tag == .macos) {
        with.test_runner = .{ .path = b.path("build_support/macos_test_runner.zig"), .mode = .server };
    };
    return b.addTest(with);
}
