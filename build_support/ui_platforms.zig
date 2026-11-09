//! The UI module's native renderers and the examples and smokes that need them, one function per platform.
const std = @import("std");
const native_support = @import("native.zig");
const helpers = @import("helpers.zig");
const addExample = helpers.addExample;
const addLinuxPointerCoreSmoke = helpers.addLinuxPointerCoreSmoke;
const addPointerCostSmoke = helpers.addPointerCostSmoke;
const addSmoke = helpers.addSmoke;
const runInstalled = helpers.runInstalled;
const addResources = helpers.addResources;

pub fn addGpu(b: *std.Build, c: anytype) void {
    const gpu = c.gpu;
    const target = c.target;
    const ui = c.ui;
    const optimize = c.optimize;
    const core = c.core;
    const text_layout = c.text_layout;
    const check = c.check;
    if (gpu and target.result.os.tag == .macos) {
        _ = native_support.add(b, ui, "ui-metal-native", "src/ui/metal.m", &.{ "-fobjc-arc", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        native_support.linkFrameworks(b, ui, &.{ "Metal", "QuartzCore", "AppKit", "Foundation", "CoreText", "CoreGraphics", "CoreVideo" });
        addSmoke(b, "smoke-metal", "tests/metal_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_ui", .module = ui },
        });
        addSmoke(b, "smoke-metal-domain", "tests/metal_domain_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_ui", .module = ui },
            .{ .name = "ziggurat_text_layout", .module = text_layout },
        });
    } else if (gpu and target.result.os.tag == .linux) {
        // OpenGL 3.3 through GDK's GL context of the window (GtkGLArea's
        // mechanism) or surfaceless EGL, both through libepoxy.
        const gl_native = native_support.add(b, ui, "ui-gl-native", "src/ui/gl_renderer.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        for ([_][]const u8{ "gtk+-3.0", "epoxy", "pangocairo" }) |library| gl_native.linkSystemLibrary(library, .{ .use_pkg_config = .force });
        for ([_][]const u8{ "gtk+-3.0", "epoxy", "pangocairo" }) |library| ui.linkSystemLibrary(library, .{ .use_pkg_config = .force });
        ui.linkSystemLibrary("dl", .{});
        addSmoke(b, "smoke-gl", "tests/gl_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_ui", .module = ui },
            .{ .name = "ziggurat_text_layout", .module = text_layout },
        });
    } else if (gpu) {
        if (target.result.os.tag != .windows) @panic("The GPU renderer requires Windows (D3D11), macOS (Metal) or Linux (OpenGL)");
        _ = native_support.add(b, ui, "ui-d3d11-native", "src/ui/d3d11.c", &.{"-std=c11"}, target, optimize);
        _ = native_support.addArchive(b, ui, "ui-gradient-interpolation-native", "src/ui/gradient_interpolation.c", &.{"-std=c11"}, target, optimize);
        _ = native_support.addArchive(b, ui, "ui-gaussian-native", "src/ui/gaussian_gpu.c", &.{"-std=c11"}, target, optimize);
        _ = native_support.addArchive(b, ui, "ui-hlsl-compile-native", "src/ui/hlsl_compile.c", &.{"-std=c11"}, target, optimize);
        for ([_][]const u8{ "d3d11", "dxgi", "d2d1", "dwrite", "user32" }) |library| ui.linkSystemLibrary(library, .{});
        for ([_][]const u8{ "default", "prepare" }) |kind| {
            const probe = b.addExecutable(.{ .name = b.fmt("gradient-program-{s}-link", .{kind}), .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tests/gradient_program_{s}_link.zig", .{kind})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "ziggurat_ui", .module = ui }},
            }) });
            addResources(b, probe);
            const install_probe = b.addInstallArtifact(probe, .{});
            check.dependOn(&install_probe.step);
            b.step(b.fmt("check-gradient-program-{s}-link", .{kind}), "Link and copy the isolated interpolation archive probe without running it").dependOn(&install_probe.step);
        }
        const program_smoke = b.addExecutable(.{ .name = "smoke-gradient-program", .root_module = b.createModule(.{
            .root_source_file = b.path("tests/gradient_program_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui } },
        }) });
        _ = native_support.add(b, program_smoke.root_module, "gradient-program-native-probe", "tests/gradient_program_native_probe.c", &.{"-std=c11"}, target, optimize);
        addResources(b, program_smoke);
        check.dependOn(&program_smoke.step);
        const install_program_smoke = b.addInstallArtifact(program_smoke, .{});
        b.step("check-gradient-program-smoke", "Link and copy interpolation program integration checks without starting graphics").dependOn(&install_program_smoke.step);
        const run_program_smoke = runInstalled(b, b.graph.path(.install_bin, "smoke-gradient-program.exe"));
        run_program_smoke.step.dependOn(&install_program_smoke.step);
        b.step("smoke-gradient-program", "Verify explicitly prepared interpolation programs, rollback and resource ownership").dependOn(&run_program_smoke.step);
        addSmoke(b, "smoke-shader-effects-gpu", "tests/shader_effects_gpu_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_ui", .module = ui },
        });
    }
}

pub fn addMacos(b: *std.Build, c: anytype) void {
    const ui = c.ui;
    const target = c.target;
    const optimize = c.optimize;
    const core = c.core;
    const declarative_view = c.declarative_view;
    const virtual_list = c.virtual_list;
    const system = c.system;
    _ = native_support.add(b, ui, "ui-core-graphics-native", "src/ui/macos.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
    native_support.linkFrameworks(b, ui, &.{ "CoreFoundation", "CoreGraphics", "CoreText" });
    _ = addExample(b, "counter", "examples/counter.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    _ = addExample(b, "view-counter", "examples/view_counter.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_view", .module = declarative_view },
    });
    addSmoke(b, "smoke-macos", "tests/macos_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    addSmoke(b, "smoke-input-region", "tests/input_region_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-macos-chrome", "tests/macos_chrome_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    addSmoke(b, "smoke-accessibility-macos", "tests/macos_accessibility_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    addSmoke(b, "smoke-virtual-list-macos", "tests/macos_virtual_list_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_virtual_list", .module = virtual_list },
    });
    addSmoke(b, "smoke-file-watch", "tests/system_watch_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat_system", .module = system },
    });
    addSmoke(b, "smoke-system-macos", "tests/system_macos_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_system", .module = system },
    });
    addSmoke(b, "smoke-hotkeys-macos", "tests/macos_hotkey_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_system", .module = system },
    });
    addSmoke(b, "smoke-macos-services", "tests/macos_services_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_system", .module = system },
    });
    addSmoke(b, "smoke-clipboard", "tests/system_clipboard_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_system", .module = system },
    });
    addSmoke(b, "smoke-drop", "tests/system_drop_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_system", .module = system },
    });
    addSmoke(b, "smoke-now-playing-commands", "tests/now_playing_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_system", .module = system },
    });
}

pub fn addLinux(b: *std.Build, c: anytype) void {
    const ui = c.ui;
    const target = c.target;
    const optimize = c.optimize;
    const check = c.check;
    const core = c.core;
    const declarative_view = c.declarative_view;
    const native = native_support.add(b, ui, "ui-cairo-native", "src/ui/linux.c", &.{"-std=c11"}, target, optimize);
    native.linkSystemLibrary("pangocairo", .{ .use_pkg_config = .force });
    ui.linkSystemLibrary("pangocairo", .{ .use_pkg_config = .force });
    // Shader effects on OpenGL through libepoxy, which GTK already uses.
    const gl_effects = native_support.add(b, ui, "ui-gl-effects-native", "src/ui/gl_effects.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
    gl_effects.linkSystemLibrary("epoxy", .{ .use_pkg_config = .force });
    ui.linkSystemLibrary("epoxy", .{ .use_pkg_config = .force });
    ui.link_libc = true;
    const content_host = b.addExecutable(.{ .name = "smoke-content-host", .root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    content_host.root_module.addCSourceFile(.{ .file = b.path("tests/linux_content_smoke.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    content_host.root_module.linkSystemLibrary("gtk+-3.0", .{});
    content_host.root_module.linkSystemLibrary("x11", .{});
    check.dependOn(&content_host.step);
    b.step("smoke-content-host", "Run private GTK content ownership and input reparenting checks").dependOn(&b.addRunArtifact(content_host).step);
    _ = addExample(b, "counter", "examples/counter.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    _ = addExample(b, "view-counter", "examples/view_counter.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_view", .module = declarative_view },
    });
    addSmoke(b, "smoke-linux", "tests/linux_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    addLinuxPointerCoreSmoke(b, check, core, target, optimize);
    addSmoke(b, "smoke-linux-touch", "tests/linux_touch_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-window-state", "tests/window_state_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-window-relationships", "tests/window_relationship_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-key-input", "tests/key_input_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-window-chrome", "tests/window_chrome_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-window-policy", "tests/window_policy_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-input-region", "tests/input_region_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-drawing", "tests/drawing_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    addSmoke(b, "smoke-gradients", "tests/gradients_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    addSmoke(b, "smoke-widgets", "tests/linux_widgets_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    addSmoke(b, "smoke-widget-ranges", "tests/linux_widget_ranges_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    const benchmark = b.addExecutable(.{ .name = "benchmark", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/benchmark_linux.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui } },
    }) });
    check.dependOn(&benchmark.step);
    const benchmark_install = b.addInstallArtifact(benchmark, .{});
    const benchmark_run = runInstalled(b, b.graph.path(.install_bin, "benchmark"));
    benchmark_run.step.dependOn(&benchmark_install.step);
    benchmark_run.addPassthruArgs();
    b.step("benchmark", "Run measured GTK/Cairo submission and idle workload").dependOn(&benchmark_run.step);
}

pub fn addWindows(b: *std.Build, c: anytype) void {
    const target = c.target;
    const optimize = c.optimize;
    const core = c.core;
    const ui = c.ui;
    const declarative_view = c.declarative_view;
    const document = c.document;
    const document_editor = c.document_editor;
    const text_layout = c.text_layout;
    const system = c.system;
    const accessibility = c.accessibility;
    const check = c.check;
    const gpu = c.gpu;
    _ = addExample(b, "counter", "examples/counter.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    _ = addExample(b, "view-counter", "examples/view_counter.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_view", .module = declarative_view },
    });
    addSmoke(b, "smoke", "tests/native_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    addSmoke(b, "smoke-widgets", "tests/widgets_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    addSmoke(b, "smoke-widget-ranges", "tests/widget_ranges_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    addSmoke(b, "smoke-lifecycle", "tests/lifecycle_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    addSmoke(b, "smoke-pointer-press", "tests/pointer_press_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-pointer-focus", "tests/pointer_focus_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui },
    });
    addPointerCostSmoke(b, target, optimize, core);
    addSmoke(b, "smoke-window-state", "tests/window_state_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-window-reveal", "tests/window_reveal_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-window-relationships", "tests/window_relationship_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-key-input", "tests/key_input_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-window-chrome", "tests/window_chrome_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-window-policy", "tests/window_policy_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-input-region", "tests/input_region_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-drawing", "tests/drawing_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    addSmoke(b, "smoke-gradients", "tests/gradients_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    const icon_module = b.createModule(.{ .root_source_file = b.path("src/platform/windows_icons.zig"), .target = target, .optimize = optimize, .link_libc = true });
    icon_module.linkSystemLibrary("user32", .{});
    icon_module.linkSystemLibrary("gdi32", .{});
    addSmoke(b, "smoke-packaging", "tests/packaging_smoke.zig", target, optimize, &.{.{ .name = "ziggurat_windows_icons", .module = icon_module }});
    addSmoke(b, "smoke-diagnostics", "tests/diagnostics_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-waitables", "tests/waitables_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-native-reentry", "tests/native_reentry_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-ime-cancel", "tests/ime_cancel_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },                    .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_document", .module = document },       .{ .name = "ziggurat_document_editor", .module = document_editor },
        .{ .name = "ziggurat_text_layout", .module = text_layout },
    });
    addSmoke(b, "smoke-cleanup", "tests/cleanup_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-system", "tests/system_native_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_system", .module = system },
    });
    addSmoke(b, "smoke-system-events", "tests/system_events_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_system", .module = system },
    });
    addSmoke(b, "smoke-picker", "tests/system_picker_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_system", .module = system },
    });
    addSmoke(b, "smoke-editor", "tests/editor_native_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    addSmoke(b, "smoke-editor-routing", "tests/editor_routing_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    const picker_probe = b.createModule(.{ .root_source_file = b.path("src/system/picker.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat", .module = core }} });
    addSmoke(b, "smoke-picker-result", "tests/picker_result_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "picker_api", .module = picker_probe },
    });
    if (accessibility) {
        addSmoke(b, "smoke-pointer-accessibility", "tests/pointer_accessibility_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_ui", .module = ui },
        });
        addSmoke(b, "smoke-accessibility", "tests/accessibility_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_ui", .module = ui },
        });
        addSmoke(b, "smoke-ui-config", "tests/ui_config_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_ui", .module = ui },
        });
    }
    const benchmark = b.addExecutable(.{ .name = "benchmark", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/benchmark_windows.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui } },
    }) });
    addResources(b, benchmark);
    check.dependOn(&benchmark.step);
    const benchmark_install = b.addInstallArtifact(benchmark, .{});
    const benchmark_run = runInstalled(b, b.graph.path(.install_bin, "benchmark.exe"));
    benchmark_run.step.dependOn(&benchmark_install.step);
    benchmark_run.addPassthruArgs();
    b.step("benchmark", "Run measured paint submission, input, idle CPU and memory workload").dependOn(&benchmark_run.step);
    if (gpu) {
        const domain_benchmark = b.addExecutable(.{ .name = "benchmark-gpu-domain", .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gpu_domain_benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui } },
        }) });
        addResources(b, domain_benchmark);
        check.dependOn(&domain_benchmark.step);
        const domain_benchmark_run = b.addRunArtifact(domain_benchmark);
        domain_benchmark_run.addPassthruArgs();
        b.step("benchmark-gpu-domain", "Measure explicit shared and isolated device domains across hidden windows").dependOn(&domain_benchmark_run.step);
        addSmoke(b, "smoke-gpu-offscreen", "tests/gpu_offscreen_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_ui", .module = ui },
            .{ .name = "ziggurat_text_layout", .module = text_layout },
        });
        // Opacities and masked clips, each drawing by itself, on GDI and
        // Direct3D 11 alike.
        addSmoke(b, "smoke-gpu-masks", "tests/gpu_masks_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_ui", .module = ui },
        });
        addSmoke(b, "smoke-gpu-domain", "tests/gpu_domain_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_ui", .module = ui },
        });
        addSmoke(b, "smoke-gpu", "tests/gpu_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_ui", .module = ui },
        });
        addSmoke(b, "smoke-gpu-fallback", "tests/gpu_fallback_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_ui", .module = ui },
        });
        addSmoke(b, "smoke-gpu-shared-device", "tests/gpu_shared_device_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_ui", .module = ui },
        });
    }
}
