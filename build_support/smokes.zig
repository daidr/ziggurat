//! Integration smokes, benchmarks and unit test steps that build.zig adds per platform.
const std = @import("std");
const native_support = @import("native.zig");
const helpers = @import("helpers.zig");
const addSmoke = helpers.addSmoke;
const addSmokeExecutable = helpers.addSmokeExecutable;
const runInstalled = helpers.runInstalled;
const addResources = helpers.addResources;
const addTest = helpers.addTest;

pub fn addLinuxHttpsResources(b: *std.Build, c: anytype) void {
    const https_resources = c.https_resources;
    const target = c.target;
    const optimize = c.optimize;
    const core = c.core;
    const check = c.check;
    https_resources.link_libc = true;
    const native = native_support.add(b, https_resources, "https-resources-native", "src/https_resources/linux.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
    const transport_native = native_support.add(b, https_resources, "https-transport-native", "src/https_resources/transport_linux.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
    // libsoup and WebKitGTK inherit -Wl,--export-dynamic from gmodule, a
    // pkg-config flag Zig rejects under `.force`; `.yes` skips it.
    for ([_][]const u8{ "libsoup-3.0", "gio-unix-2.0" }) |library| {
        native.linkSystemLibrary(library, .{ .use_pkg_config = .yes });
        transport_native.linkSystemLibrary(library, .{ .use_pkg_config = .yes });
        https_resources.linkSystemLibrary(library, .{ .use_pkg_config = .yes });
    }
    const smoke = b.addExecutable(.{ .name = "smoke-https-resources", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/https_resources_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_https_resources", .module = https_resources } },
        .link_libc = true,
    }) });
    const host_native = native_support.add(b, smoke.root_module, "https-resources-test-host", "tests/https_resources_host.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
    for ([_][]const u8{ "libsoup-3.0", "gio-unix-2.0" }) |library| {
        host_native.linkSystemLibrary(library, .{ .use_pkg_config = .yes });
        smoke.root_module.linkSystemLibrary(library, .{ .use_pkg_config = .yes });
    }
    smoke.root_module.linkSystemLibrary("curl", .{ .use_pkg_config = .no });
    smoke.root_module.linkSystemLibrary("pthread", .{ .use_pkg_config = .no });
    check.dependOn(&smoke.step);
    const install_smoke = b.addInstallArtifact(smoke, .{});
    b.step("check-https-resources-smoke", "Link and copy host-owned HTTPS integration checks without starting them").dependOn(&install_smoke.step);
    const run_smoke = runInstalled(b, b.graph.path(.install_bin, "smoke-https-resources"));
    run_smoke.step.dependOn(&install_smoke.step);
    b.step("smoke-https-resources", "Verify explicit HTTPS resource ownership, authentication and shutdown").dependOn(&run_smoke.step);
    // Fault-injected implementations stay in this separate test process;
    // consumers never link these copies alongside production file state.
    const native_tests = addTest(b, .{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/https_resources_native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    for ([_][]const u8{ "tests/https_resources_native.c", "src/https_resources/linux.c", "src/file_stream/linux.c" }, 0..) |file, index| {
        const unit = native_support.add(b, native_tests.root_module, b.fmt("https-resource-fault-{d}", .{index}), file, &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-DZHR_TESTING", "-DZWK_FILE_TESTING" }, target, optimize);
        for ([_][]const u8{ "libsoup-3.0", "gio-unix-2.0" }) |library| unit.linkSystemLibrary(library, .{ .use_pkg_config = .yes });
    }
    for ([_][]const u8{ "libsoup-3.0", "gio-unix-2.0" }) |library| native_tests.root_module.linkSystemLibrary(library, .{ .use_pkg_config = .yes });
    for ([_][]const u8{ "curl", "pthread" }) |library| native_tests.root_module.linkSystemLibrary(library, .{ .use_pkg_config = .no });
    check.dependOn(&native_tests.step);
    b.step("test-https-resources-native", "Verify real TLS failure paths and shared physical request capacity").dependOn(&b.addRunArtifact(native_tests).step);
    const transport_tests = addTest(b, .{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/https_transport_native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    for ([_][]const u8{ "tests/https_transport_native.c", "src/https_resources/transport_linux.c" }, 0..) |file, index| {
        const unit = native_support.add(b, transport_tests.root_module, b.fmt("https-transport-fault-{d}", .{index}), file, &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-DZHT_TESTING" }, target, optimize);
        for ([_][]const u8{ "libsoup-3.0", "gio-unix-2.0" }) |library| unit.linkSystemLibrary(library, .{ .use_pkg_config = .yes });
    }
    for ([_][]const u8{ "libsoup-3.0", "gio-unix-2.0" }) |library| transport_tests.root_module.linkSystemLibrary(library, .{ .use_pkg_config = .yes });
    check.dependOn(&transport_tests.step);
    b.step("test-https-transport-native", "Verify explicit TLS listener ownership, sealing and independent native references").dependOn(&b.addRunArtifact(transport_tests).step);
}

pub fn addTextSmokes(b: *std.Build, c: anytype) void {
    const target = c.target;
    const optimize = c.optimize;
    const text_layout = c.text_layout;
    const test_step = c.test_step;
    const check = c.check;
    const drawing_resources = c.drawing_resources;
    const fonts = c.fonts;
    const core = c.core;
    const document = c.document;
    const vector = c.vector;
    const text_outlines = c.text_outlines;
    const images = c.images;
    const image_drawing = c.image_drawing;
    addSmoke(b, "smoke-text-word-costs", "tests/text_word_costs.zig", target, optimize, &.{.{ .name = "ziggurat_text_layout", .module = text_layout }});
    const word_helper = b.addExecutable(.{ .name = "test-text-words-helper", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    word_helper.root_module.addCSourceFile(.{ .file = b.path("tests/text_words_helper_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    const run_word_helper = b.addRunArtifact(word_helper);
    test_step.dependOn(&run_word_helper.step);
    check.dependOn(&word_helper.step);
    b.step("test-text-words-helper", "Verify the bounded lexical/nonword partition writer").dependOn(&run_word_helper.step);
    const word_smoke = b.addExecutable(.{ .name = "smoke-text-words", .root_module = b.createModule(.{ .root_source_file = b.path("tests/text_words_smoke.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "ziggurat_text_layout", .module = text_layout }} }) });
    word_smoke.root_module.addCSourceFile(.{ .file = b.path("tests/text_words_oracle.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    if (target.result.os.tag == .linux) word_smoke.root_module.linkSystemLibrary("pangocairo", .{ .use_pkg_config = .force });
    const install_word_smoke = b.addInstallArtifact(word_smoke, .{});
    const run_word_smoke = b.addRunArtifact(word_smoke);
    run_word_smoke.step.dependOn(&install_word_smoke.step);
    check.dependOn(&word_smoke.step);
    b.step("build-smoke-text-words", "Build the independent system word-range oracle").dependOn(&install_word_smoke.step);
    b.step("smoke-text-words", "Verify word ranges against independent ICU/Pango segmentation").dependOn(&run_word_smoke.step);
    const word_fault_layout = b.createModule(.{ .root_source_file = b.path("src/ui/text_layout.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{ .{ .name = "ziggurat_drawing_resources", .module = drawing_resources }, .{ .name = "ziggurat_fonts", .module = fonts } } });
    if (target.result.os.tag == .windows) {
        _ = native_support.add(b, word_fault_layout, "text-layout-word-fault-native", "src/ui/text_layout_windows.c", &.{ "-std=c11", "-DZTL_WORD_TESTING" }, target, optimize);
        word_fault_layout.linkSystemLibrary("dwrite", .{});
        word_fault_layout.linkSystemLibrary("gdi32", .{});
    } else {
        const native = native_support.add(b, word_fault_layout, "text-layout-word-fault-native", "src/ui/text_layout_linux.c", &.{ "-std=c11", "-DZTL_WORD_TESTING" }, target, optimize);
        native.linkSystemLibrary("pangocairo", .{ .use_pkg_config = .force });
        word_fault_layout.linkSystemLibrary("pangocairo", .{ .use_pkg_config = .force });
    }
    const word_fault_smoke = b.addExecutable(.{ .name = "smoke-text-words-fault", .root_module = b.createModule(.{ .root_source_file = b.path("tests/text_words_fault_smoke.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "ziggurat_text_layout", .module = word_fault_layout }} }) });
    const install_word_fault = b.addInstallArtifact(word_fault_smoke, .{});
    const run_word_fault = b.addRunArtifact(word_fault_smoke);
    run_word_fault.step.dependOn(&install_word_fault.step);
    check.dependOn(&word_fault_smoke.step);
    b.step("build-smoke-text-words-fault", "Build the isolated word preparation fault adapter").dependOn(&install_word_fault.step);
    b.step("smoke-text-words-fault", "Verify explicit word capability failures and query call boundaries").dependOn(&run_word_fault.step);
    addSmoke(b, "smoke-window-registry", "tests/window_registry_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-accessibility-host", "tests/accessibility_host_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-composition", "tests/composition_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-app-stop", "tests/app_stop_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
    addSmoke(b, "smoke-document", "tests/document_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_document", .module = document },
    });
    addSmoke(b, "smoke-text-layout", "tests/text_layout_smoke.zig", target, optimize, &.{.{ .name = "ziggurat_text_layout", .module = text_layout }});
    addSmoke(b, "smoke-text-outlines", "tests/text_outlines_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat_text_layout", .module = text_layout },
        .{ .name = "ziggurat_vector", .module = vector },
        .{ .name = "ziggurat_text_outlines", .module = text_outlines },
    });
    const text_clusters = b.addExecutable(.{ .name = "smoke-text-clusters", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/text_clusters_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggurat_text_layout", .module = text_layout },
            .{ .name = "ziggurat_text_outlines", .module = text_outlines },
            .{ .name = "ziggurat_vector", .module = vector },
        },
    }) });
    text_clusters.root_module.addCSourceFile(.{ .file = b.path("tests/text_clusters_oracle.c"), .flags = &.{"-std=c11"} });
    if (target.result.os.tag == .linux) text_clusters.root_module.linkSystemLibrary("pangocairo", .{ .use_pkg_config = .force });
    addResources(b, text_clusters);
    check.dependOn(&text_clusters.step);
    b.step("smoke-text-clusters", "Verify optional owning glyph and source cluster outline mapping").dependOn(&b.addRunArtifact(text_clusters).step);
    const text_cells = b.addExecutable(.{ .name = "smoke-text-cells", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/text_cells_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggurat_text_layout", .module = text_layout },
            .{ .name = "ziggurat_text_outlines", .module = text_outlines },
        },
    }) });
    text_cells.root_module.addCSourceFile(.{ .file = b.path("tests/text_cells_native.c"), .flags = &.{"-std=c11"} });
    if (target.result.os.tag == .linux) text_cells.root_module.linkSystemLibrary("pangocairo", .{ .use_pkg_config = .force });
    addResources(b, text_cells);
    check.dependOn(&text_cells.step);
    b.step("smoke-text-cells", "Verify optional full glyph cells against independent system font metrics").dependOn(&b.addRunArtifact(text_cells).step);
    addSmoke(b, "smoke-images", "tests/images_smoke.zig", target, optimize, &.{.{ .name = "ziggurat_images", .module = images }});
    addSmoke(b, "smoke-image-prepare", "tests/image_prepare_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat_images", .module = images }, .{ .name = "ziggurat_image_drawing", .module = image_drawing },
    });
}

pub fn addSystemSmokes(b: *std.Build, c: anytype) void {
    const target = c.target;
    const optimize = c.optimize;
    const core = c.core;
    const system = c.system;
    const shell_smoke = addSmokeExecutable(b, "smoke-shell", "tests/system_shell_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_system", .module = system },
    });
    if (target.result.os.tag == .linux) {
        // Test-only private FileManager1 provider on the smoke's session bus.
        const fake = native_support.add(b, shell_smoke.root_module, "shell-file-manager-fake", "tests/system_shell_file_manager.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        fake.linkSystemLibrary("gio-2.0", .{ .use_pkg_config = .force });
        shell_smoke.root_module.linkSystemLibrary("gio-2.0", .{ .use_pkg_config = .force });
        shell_smoke.root_module.link_libc = true;
    }
    addSmoke(b, "smoke-clipboard", "tests/system_clipboard_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_system", .module = system },
    });
    addSmoke(b, "smoke-drop", "tests/system_drop_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_system", .module = system },
    });
    addSmoke(b, "smoke-drag", "tests/system_drag_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_system", .module = system },
    });
    addSmoke(b, "smoke-desktop", "tests/system_desktop_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_system", .module = system },
    });
    addSmoke(b, "smoke-system-details", "tests/system_details_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_system", .module = system },
    });
    addSmoke(b, "smoke-system-extras", "tests/system_extras_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_system", .module = system },
    });
    addSmoke(b, "smoke-system-session", "tests/system_session_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_system", .module = system },
    });
    addSmoke(b, "smoke-file-watch", "tests/system_watch_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat_system", .module = system },
    });
    addSmoke(b, "smoke-secrets", "tests/system_secrets_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_system", .module = system },
    });
    addSmoke(b, "smoke-flyout", "tests/system_flyout_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_system", .module = system },
    });
    addSmoke(b, "smoke-now-playing-commands", "tests/now_playing_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_system", .module = system },
    });
}

pub fn addDrawingSmokes(b: *std.Build, c: anytype) void {
    const target = c.target;
    const optimize = c.optimize;
    const markdown = c.markdown;
    const markdown_view = c.markdown_view;
    const markdown_code = c.markdown_code;
    const text_layout = c.text_layout;
    const declarative_view = c.declarative_view;
    const core = c.core;
    const ui = c.ui;
    const system = c.system;
    const wake = c.wake;
    const view_timer = c.view_timer;
    const view_graphics = c.view_graphics;
    const view_video = c.view_video;
    const animation = c.animation;
    const svg = c.svg;
    const svg_text = c.svg_text;
    const text_outlines = c.text_outlines;
    const vector = c.vector;
    addSmoke(b, "smoke-markdown-code", "tests/markdown_code_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat_markdown", .module = markdown },
        .{ .name = "ziggurat_markdown_view", .module = markdown_view },
        .{ .name = "ziggurat_markdown_code", .module = markdown_code },
        .{ .name = "ziggurat_text_layout", .module = text_layout },
        .{ .name = "ziggurat_view", .module = declarative_view },
    });
    addSmoke(b, "smoke-affine-renderer", "tests/affine_renderer_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_text_layout", .module = text_layout },
    });
    addSmoke(b, "smoke-affine-ui", if (target.result.os.tag == .windows) "tests/affine_ui_smoke.zig" else "tests/linux_affine_ui_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    addSmoke(b, "smoke-theme", "tests/theme_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    addSmoke(b, "smoke-backdrop", "tests/backdrop_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    addSmoke(b, "smoke-vibrancy", "tests/vibrancy_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_system", .module = system },
    });
    addSmoke(b, "smoke-shader-effects", "tests/shader_effects_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    if (target.result.os.tag == .linux) addSmoke(b, "smoke-shader-effects-gl", "tests/shader_effects_gl_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    addSmoke(b, "smoke-view", "tests/view_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_view", .module = declarative_view },
        .{ .name = "ziggurat_wake", .module = wake },
        .{ .name = "ziggurat_view_timer", .module = view_timer },
        .{ .name = "ziggurat_view_graphics", .module = view_graphics },
        .{ .name = "ziggurat_view_video", .module = view_video },
    });
    addSmoke(b, "smoke-animation-ui", "tests/animation_ui_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_animation", .module = animation },
        .{ .name = "ziggurat_wake", .module = wake },
    });
    addSmoke(b, "smoke-svg-text", "tests/svg_text_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_svg", .module = svg },
        .{ .name = "ziggurat_svg_text", .module = svg_text },
        .{ .name = "ziggurat_text_layout", .module = text_layout },
        .{ .name = "ziggurat_text_outlines", .module = text_outlines },
        .{ .name = "ziggurat_vector", .module = vector },
    });
}

pub fn addWindowsDocumentAccessibility(b: *std.Build, c: anytype) void {
    const document_accessibility = c.document_accessibility;
    const target = c.target;
    const optimize = c.optimize;
    const core = c.core;
    const ui = c.ui;
    const text_layout = c.text_layout;
    const document = c.document;
    const document_editor = c.document_editor;
    const check = c.check;
    const prepared_hit_abi = c.prepared_hit_abi;
    document_accessibility.link_libc = true;
    for ([_][]const u8{ "native_ledger.c", "native_store.c", "native_windows.c" }) |file| {
        _ = native_support.add(b, document_accessibility, b.fmt("document-accessibility-{s}", .{file}), b.fmt("src/document_accessibility/{s}", .{file}), &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
    }
    for ([_][]const u8{ "ole32", "oleaut32", "uiautomationcore", "user32" }) |library| document_accessibility.linkSystemLibrary(library, .{});
    const accessibility_smoke = b.addExecutable(.{ .name = "smoke-document-accessibility", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/document_accessibility_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_ui", .module = ui },
            .{ .name = "ziggurat_text_layout", .module = text_layout },
            .{ .name = "ziggurat_document", .module = document },
            .{ .name = "ziggurat_document_editor", .module = document_editor },
            .{ .name = "ziggurat_document_accessibility", .module = document_accessibility },
        },
    }) });
    accessibility_smoke.root_module.addCSourceFile(.{ .file = b.path("tests/document_accessibility_client.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    addResources(b, accessibility_smoke);
    check.dependOn(&accessibility_smoke.step);
    b.step("smoke-document-accessibility", "Verify complete-document native UIA and main-thread action/lifetime boundaries").dependOn(&b.addRunArtifact(accessibility_smoke).step);
    b.step("build-smoke-document-accessibility", "Build the native document UIA renderer matrix fixture").dependOn(&b.addInstallArtifact(accessibility_smoke, .{}).step);
    // Only this executable includes the deterministic final-release hook.
    // It owns one isolated C implementation and never imports ordinary DA.
    const point_latch = b.addExecutable(.{ .name = "smoke-document-point-latch", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/document_accessibility_point_latch.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "ziggurat", .module = core }},
    }) });
    for ([_][]const u8{ "native_ledger.c", "native_store.c", "native_windows.c" }) |file| {
        _ = native_support.add(b, point_latch.root_module, b.fmt("document-point-latch-{s}", .{file}), b.fmt("src/document_accessibility/{s}", .{file}), &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-DZDA_POINT_TESTING" }, target, optimize);
    }
    const point_latch_probe = native_support.add(b, point_latch.root_module, "document-point-latch-probe", "tests/document_accessibility_point_latch.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-DZDA_POINT_TESTING" }, target, optimize);
    point_latch_probe.addIncludePath(b.path("src/document_accessibility"));
    point_latch.root_module.addObject(prepared_hit_abi.?);
    for ([_][]const u8{ "ole32", "oleaut32", "uiautomationcore", "user32" }) |library| point_latch.root_module.linkSystemLibrary(library, .{});
    addResources(b, point_latch);
    check.dependOn(&point_latch.step);
    b.step("build-smoke-document-point-latch", "Build the isolated UIA final-release oracle").dependOn(&b.addInstallArtifact(point_latch, .{}).step);
    b.step("smoke-document-point-latch", "Verify UIA final-release currentness with the normal main-thread FIFO").dependOn(&b.addRunArtifact(point_latch).step);
    const provider_tests = addTest(b, .{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/document_accessibility_provider.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "ziggurat_document_accessibility", .module = document_accessibility }},
    }) });
    const provider_probe = native_support.add(b, provider_tests.root_module, "document-provider-probe", "tests/document_accessibility_provider_probe.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
    provider_probe.addIncludePath(b.path("src/document_accessibility"));
    check.dependOn(&provider_tests.step);
    b.step("smoke-document-provider", "Verify native UIA packet identity, foreign release and provider ownership").dependOn(&b.addRunArtifact(provider_tests).step);
}

pub fn addDocumentSmokes(b: *std.Build, c: anytype) void {
    const target = c.target;
    const optimize = c.optimize;
    const core = c.core;
    const ui = c.ui;
    const text_layout = c.text_layout;
    const document = c.document;
    const document_editor = c.document_editor;
    const code_editor = c.code_editor;
    const language_protocol = c.language_protocol;
    const check = c.check;
    const protocol_server = c.protocol_server;
    addSmoke(b, "smoke-document-geometry", "tests/document_accessibility_geometry_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_text_layout", .module = text_layout },
        .{ .name = "ziggurat_document", .module = document },
        .{ .name = "ziggurat_document_editor", .module = document_editor },
    });
    addSmoke(b, "smoke-affine-document", "tests/affine_document_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_text_layout", .module = text_layout },
        .{ .name = "ziggurat_document", .module = document },
        .{ .name = "ziggurat_document_editor", .module = document_editor },
        .{ .name = "ziggurat_code_editor", .module = code_editor },
    });
    addSmoke(b, "smoke-editor-line-backgrounds", "tests/editor_line_background_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_text_layout", .module = text_layout },
        .{ .name = "ziggurat_document", .module = document },
        .{ .name = "ziggurat_document_editor", .module = document_editor },
    });
    addSmoke(b, "smoke-editor-range-markers", "tests/editor_range_markers_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_text_layout", .module = text_layout },
        .{ .name = "ziggurat_document", .module = document },
        .{ .name = "ziggurat_document_editor", .module = document_editor },
    });
    addSmoke(b, "smoke-editor-pre-input", "tests/editor_pre_input_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_text_layout", .module = text_layout },
        .{ .name = "ziggurat_document", .module = document },
        .{ .name = "ziggurat_document_editor", .module = document_editor },
    });
    addSmoke(b, "smoke-snippets", "tests/snippets_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_text_layout", .module = text_layout },
        .{ .name = "ziggurat_document", .module = document },
        .{ .name = "ziggurat_document_editor", .module = document_editor },
        .{ .name = "ziggurat_code_editor", .module = code_editor },
    });
    const resolve_smoke = b.addExecutable(.{ .name = "smoke-completion-resolve", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/completion_resolve_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_ui", .module = ui },
            .{ .name = "ziggurat_text_layout", .module = text_layout },
            .{ .name = "ziggurat_document", .module = document },
            .{ .name = "ziggurat_document_editor", .module = document_editor },
            .{ .name = "ziggurat_code_editor", .module = code_editor },
            .{ .name = "ziggurat_language_protocol", .module = language_protocol },
        },
    }) });
    addResources(b, resolve_smoke);
    check.dependOn(&resolve_smoke.step);
    const resolve_run = b.addRunArtifact(resolve_smoke);
    resolve_run.addArtifactArg(protocol_server);
    b.step("smoke-completion-resolve", "Verify explicit completion enrichment with a real worker child and unchanged edit transactions").dependOn(&resolve_run.step);
}

pub fn addEditorSmokes(b: *std.Build, c: anytype) void {
    const core = c.core;
    const ui = c.ui;
    const text_layout = c.text_layout;
    const shaped_editor = c.shaped_editor;
    const target = c.target;
    const optimize = c.optimize;
    const document = c.document;
    const document_editor = c.document_editor;
    const code_editor = c.code_editor;
    const document_diff = c.document_diff;
    const document_diff_view = c.document_diff_view;
    const shadows = c.shadows;
    const vector = c.vector;
    const svg = c.svg;
    const gaussian = c.gaussian;
    const check = c.check;
    const virtual_list = c.virtual_list;
    const images = c.images;
    const image_drawing = c.image_drawing;
    const shaped_imports: []const std.Build.Module.Import = &.{
        .{ .name = "ziggurat", .module = core },                    .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_text_layout", .module = text_layout }, .{ .name = "ziggurat_shaped_editor", .module = shaped_editor },
    };
    addSmoke(b, "smoke-shaped-editor", "tests/shaped_editor_smoke.zig", target, optimize, shaped_imports);
    addSmoke(b, "smoke-text-input-mode", "tests/text_input_mode_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
    });
    addSmoke(b, "smoke-text-layout-capture", "tests/text_layout_capture_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_text_layout", .module = text_layout },
        .{ .name = "ziggurat_shaped_editor", .module = shaped_editor },
    });
    addSmoke(b, "smoke-shaped-editor-native", "tests/shaped_editor_native_smoke.zig", target, optimize, shaped_imports);
    addSmoke(b, "smoke-document-editor", "tests/document_editor_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },                            .{ .name = "ziggurat_document", .module = document },
        .{ .name = "ziggurat_ui", .module = ui },                           .{ .name = "ziggurat_text_layout", .module = text_layout },
        .{ .name = "ziggurat_document_editor", .module = document_editor },
    });
    addSmoke(b, "smoke-document-pointer-selection", "tests/document_pointer_selection_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_document", .module = document },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_text_layout", .module = text_layout },
        .{ .name = "ziggurat_document_editor", .module = document_editor },
    });
    addSmoke(b, "smoke-document-fields", "tests/document_fields_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_document", .module = document },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_text_layout", .module = text_layout },
        .{ .name = "ziggurat_document_editor", .module = document_editor },
    });
    addSmoke(b, "smoke-gaussian-scope", "tests/gaussian_scope_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
    });
    addSmoke(b, "smoke-editor-caret", "tests/editor_caret_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_text_layout", .module = text_layout },
        .{ .name = "ziggurat_shaped_editor", .module = shaped_editor },
        .{ .name = "ziggurat_document", .module = document },
        .{ .name = "ziggurat_document_editor", .module = document_editor },
    });
    addSmoke(b, "smoke-code-editor", "tests/code_editor_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_document", .module = document },
        .{ .name = "ziggurat_document_editor", .module = document_editor },
        .{ .name = "ziggurat_code_editor", .module = code_editor },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_text_layout", .module = text_layout },
    });
    addSmoke(b, "smoke-completion-details", "tests/completion_details_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_text_layout", .module = text_layout },
        .{ .name = "ziggurat_document", .module = document },
        .{ .name = "ziggurat_document_editor", .module = document_editor },
        .{ .name = "ziggurat_code_editor", .module = code_editor },
    });
    addSmoke(b, "smoke-document-diff-view", "tests/document_diff_view_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_document", .module = document },
        .{ .name = "ziggurat_document_diff", .module = document_diff },
        .{ .name = "ziggurat_document_editor", .module = document_editor },
        .{ .name = "ziggurat_document_diff_view", .module = document_diff_view },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_text_layout", .module = text_layout },
    });
    addSmoke(b, "smoke-diff-caret", "tests/document_diff_caret_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_text_layout", .module = text_layout },
        .{ .name = "ziggurat_document", .module = document },
        .{ .name = "ziggurat_document_editor", .module = document_editor },
        .{ .name = "ziggurat_document_diff", .module = document_diff },
        .{ .name = "ziggurat_document_diff_view", .module = document_diff_view },
    });
    addSmoke(b, "smoke-diff-commands", "tests/document_diff_commands_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_text_layout", .module = text_layout },
        .{ .name = "ziggurat_document", .module = document },
        .{ .name = "ziggurat_document_editor", .module = document_editor },
        .{ .name = "ziggurat_document_diff", .module = document_diff },
        .{ .name = "ziggurat_document_diff_view", .module = document_diff_view },
    });
    addSmoke(b, "smoke-diff-find", "tests/document_diff_find_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_text_layout", .module = text_layout },
        .{ .name = "ziggurat_document", .module = document },
        .{ .name = "ziggurat_document_editor", .module = document_editor },
        .{ .name = "ziggurat_document_diff", .module = document_diff },
        .{ .name = "ziggurat_document_diff_view", .module = document_diff_view },
    });
    addSmoke(b, "smoke-text-client", "tests/text_client_smoke.zig", target, optimize, shaped_imports);
    addSmoke(b, "smoke-affine-text-binding", "tests/affine_text_binding_smoke.zig", target, optimize, shaped_imports);
    addSmoke(b, "smoke-gradient-analytic", "tests/gradient_analytic_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui },
    });
    addSmoke(b, "smoke-conic-gradients", if (target.result.os.tag == .linux) "tests/linux_conic_gradient_smoke.zig" else "tests/conic_gradient_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui },
    });
    addSmoke(b, "smoke-gradient-interpolation", if (target.result.os.tag == .linux) "tests/linux_gradient_interpolation_smoke.zig" else "tests/gradient_interpolation_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui },
    });
    addSmoke(b, "smoke-gradient-spread", "tests/gradient_spread_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui },
    });
    addSmoke(b, "smoke-composition-ui", "tests/composition_ui_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui },
    });
    addSmoke(b, "smoke-coverage", "tests/coverage_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },            .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_shadows", .module = shadows }, .{ .name = "ziggurat_vector", .module = vector },
    });
    addSmoke(b, "smoke-gradient-coverage", "tests/gradient_coverage_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui }, .{ .name = "ziggurat_vector", .module = vector },
    });
    addSmoke(b, "smoke-svg", "tests/svg_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui }, .{ .name = "ziggurat_svg", .module = svg },
    });
    addSmoke(b, "smoke-layers", "tests/layers_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui }, .{ .name = "ziggurat_text_layout", .module = text_layout },
    });
    addSmoke(b, "smoke-offscreen", "tests/offscreen_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui }, .{ .name = "ziggurat_text_layout", .module = text_layout },
    });
    const gaussian_smoke = b.addExecutable(.{ .name = "smoke-gaussian", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/gaussian_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui }, .{ .name = "ziggurat_gaussian", .module = gaussian } },
    }) });
    addResources(b, gaussian_smoke);
    check.dependOn(&gaussian_smoke.step);
    b.step("check-gaussian-smoke", "Compile composed-image Gaussian checks without starting native graphics").dependOn(&gaussian_smoke.step);
    const install_gaussian = b.addInstallArtifact(gaussian_smoke, .{});
    const run_gaussian = runInstalled(b, b.graph.path(.install_bin, b.fmt("smoke-gaussian{s}", .{if (target.result.os.tag == .windows) ".exe" else ""})));
    run_gaussian.step.dependOn(&install_gaussian.step);
    b.step("smoke-gaussian", "Verify composed subtree filtering, image replay and resource lifetime").dependOn(&run_gaussian.step);
    const shadow_benchmark = b.addExecutable(.{ .name = "benchmark-shadows", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/shadow_benchmark.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui }, .{ .name = "ziggurat_shadows", .module = shadows } },
    }) });
    addResources(b, shadow_benchmark);
    b.step("benchmark-shadows", "Measure explicit shadow preparation, upload and warm replay costs").dependOn(&b.addRunArtifact(shadow_benchmark).step);
    const layers_benchmark = b.addExecutable(.{ .name = "benchmark-layers", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/layers_benchmark.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui } },
    }) });
    addResources(b, layers_benchmark);
    b.step("benchmark-layers", "Measure explicit transparent workspace and group replay costs").dependOn(&b.addRunArtifact(layers_benchmark).step);
    addSmoke(b, "smoke-virtual-list", "tests/virtual_list_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui }, .{ .name = "ziggurat_virtual_list", .module = virtual_list },
    });
    addSmoke(b, "smoke-text-drawing", "tests/text_layout_drawing_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui }, .{ .name = "ziggurat_text_layout", .module = text_layout },
    });
    addSmoke(b, "smoke-image-drawing", "tests/image_drawing_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },          .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_images", .module = images }, .{ .name = "ziggurat_image_drawing", .module = image_drawing },
    });
    addSmoke(b, "smoke-svg-image", "tests/svg_image_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },                        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_svg", .module = svg },                     .{ .name = "ziggurat_images", .module = images },
        .{ .name = "ziggurat_image_drawing", .module = image_drawing },
    });
    addSmoke(b, "smoke-image-update", "tests/image_update_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },          .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_images", .module = images }, .{ .name = "ziggurat_image_drawing", .module = image_drawing },
    });
}

pub fn addUiTests(b: *std.Build, c: anytype) void {
    const ui = c.ui;
    const check = c.check;
    const test_step = c.test_step;
    const target = c.target;
    const optimize = c.optimize;
    const core = c.core;
    const text_layout = c.text_layout;
    const drawing_resources = c.drawing_resources;
    const gif = c.gif;
    const png = c.png;
    const apng = c.apng;
    const images = c.images;
    const image_drawing = c.image_drawing;
    const shaped_editor = c.shaped_editor;
    const document_editor = c.document_editor;
    const virtual_list = c.virtual_list;
    const declarative_view = c.declarative_view;
    const markdown_view = c.markdown_view;
    const chart_view = c.chart_view;
    const view_video = c.view_video;
    const view_graphics = c.view_graphics;
    const i18n = c.i18n;
    const chart = c.chart;
    const ui_tests = addTest(b, .{ .root_module = ui });
    check.dependOn(&ui_tests.step);
    const run_ui_tests = b.addRunArtifact(ui_tests);
    test_step.dependOn(&run_ui_tests.step);
    b.step("test-ui", "Run UI frame, geometry, widgets and theme contracts").dependOn(&run_ui_tests.step);
    const pointer_controls_tests = addTest(b, .{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/pointer_clicks_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui } },
    }) });
    check.dependOn(&pointer_controls_tests.step);
    const run_pointer_controls_tests = b.addRunArtifact(pointer_controls_tests);
    test_step.dependOn(&run_pointer_controls_tests.step);
    b.step("test-ui-pointer-clicks", "Run registered pointer controls, frame authority and lifetime contracts").dependOn(&run_pointer_controls_tests.step);
    addSmoke(b, "smoke-pointer-clicks", "tests/pointer_clicks_smoke.zig", target, optimize, &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui } });
    const shortcut_scopes_tests = addTest(b, .{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/shortcut_scopes_contract.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui } },
    }) });
    check.dependOn(&shortcut_scopes_tests.step);
    const run_shortcut_scopes_tests = b.addRunArtifact(shortcut_scopes_tests);
    test_step.dependOn(&run_shortcut_scopes_tests.step);
    b.step("test-shortcut-scopes", "Run scoped key routing, front authority and bounded continuation contracts").dependOn(&run_shortcut_scopes_tests.step);
    addSmoke(b, "smoke-shortcut-scopes", "tests/shortcut_scopes_smoke.zig", target, optimize, &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui } });
    const text_tests = addTest(b, .{ .root_module = text_layout });
    check.dependOn(&text_tests.step);
    const run_text_tests = b.addRunArtifact(text_tests);
    test_step.dependOn(&run_text_tests.step);
    b.step("test-text-layout", "Run immutable text layout and ownership invariants").dependOn(&run_text_tests.step);
    const drawing_tests = addTest(b, .{ .root_module = drawing_resources });
    check.dependOn(&drawing_tests.step);
    test_step.dependOn(&b.addRunArtifact(drawing_tests).step);
    const gif_tests = addTest(b, .{ .root_module = gif });
    check.dependOn(&gif_tests.step);
    const run_gif_tests = b.addRunArtifact(gif_tests);
    test_step.dependOn(&run_gif_tests.step);
    b.step("test-gif", "Run GIF graphic decoding and animation frame tests").dependOn(&run_gif_tests.step);
    const png_tests = addTest(b, .{ .root_module = png });
    check.dependOn(&png_tests.step);
    test_step.dependOn(&b.addRunArtifact(png_tests).step);
    const apng_tests = addTest(b, .{ .root_module = apng });
    check.dependOn(&apng_tests.step);
    const run_apng_tests = b.addRunArtifact(apng_tests);
    test_step.dependOn(&run_apng_tests.step);
    b.step("test-apng", "Run animated PNG decoding and frame composition tests").dependOn(&run_apng_tests.step);
    const image_tests = addTest(b, .{ .root_module = images });
    check.dependOn(&image_tests.step);
    test_step.dependOn(&b.addRunArtifact(image_tests).step);
    const image_drawing_tests = addTest(b, .{ .root_module = image_drawing });
    check.dependOn(&image_drawing_tests.step);
    test_step.dependOn(&b.addRunArtifact(image_drawing_tests).step);
    const shaped_tests = addTest(b, .{ .root_module = shaped_editor });
    const document_editor_tests = addTest(b, .{ .root_module = document_editor });
    check.dependOn(&document_editor_tests.step);
    const run_document_editor_tests = b.addRunArtifact(document_editor_tests);
    test_step.dependOn(&run_document_editor_tests.step);
    b.step("test-document-editor", "Run indexed document editor invariant tests").dependOn(&run_document_editor_tests.step);
    check.dependOn(&shaped_tests.step);
    test_step.dependOn(&b.addRunArtifact(shaped_tests).step);
    const list_tests = addTest(b, .{ .root_module = virtual_list });
    check.dependOn(&list_tests.step);
    const run_list_tests = b.addRunArtifact(list_tests);
    test_step.dependOn(&run_list_tests.step);
    b.step("test-virtual-list", "Run virtual list model and control invariant tests").dependOn(&run_list_tests.step);
    const declarative_view_tests = addTest(b, .{ .root_module = declarative_view });
    check.dependOn(&declarative_view_tests.step);
    const run_declarative_view_tests = b.addRunArtifact(declarative_view_tests);
    test_step.dependOn(&run_declarative_view_tests.step);
    b.step("test-view", "Run declarative view build, identity and layout tests").dependOn(&run_declarative_view_tests.step);
    const markdown_view_tests = addTest(b, .{ .root_module = markdown_view });
    check.dependOn(&markdown_view_tests.step);
    const run_markdown_view_tests = b.addRunArtifact(markdown_view_tests);
    test_step.dependOn(&run_markdown_view_tests.step);
    b.step("test-markdown-view", "Run Markdown to declarative view mapping, wrapping and activation tests").dependOn(&run_markdown_view_tests.step);
    const chart_view_tests = addTest(b, .{ .root_module = chart_view });
    check.dependOn(&chart_view_tests.step);
    const run_chart_view_tests = b.addRunArtifact(chart_view_tests);
    test_step.dependOn(&run_chart_view_tests.step);
    b.step("test-chart-view", "Run chart view arrangement, storage and preparation key tests").dependOn(&run_chart_view_tests.step);
    const view_video_tests = addTest(b, .{ .root_module = view_video });
    check.dependOn(&view_video_tests.step);
    const run_view_video_tests = b.addRunArtifact(view_video_tests);
    test_step.dependOn(&run_view_video_tests.step);
    b.step("test-view-video", "Run view video playback, frame timing and GIF decoder tests").dependOn(&run_view_video_tests.step);
    const view_graphics_tests = addTest(b, .{ .root_module = view_graphics });
    check.dependOn(&view_graphics_tests.step);
    const run_view_graphics_tests = b.addRunArtifact(view_graphics_tests);
    test_step.dependOn(&run_view_graphics_tests.step);
    b.step("test-view-graphics", "Run view icon mask and SVG picture preparation tests").dependOn(&run_view_graphics_tests.step);
    const view_pickers = b.addModule("ziggurat_view_pickers", .{ .root_source_file = b.path("src/view/pickers.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },                  .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_view", .module = declarative_view }, .{ .name = "ziggurat_i18n", .module = i18n },
    } });
    const view_pickers_tests = addTest(b, .{ .root_module = view_pickers });
    check.dependOn(&view_pickers_tests.step);
    const run_view_pickers_tests = b.addRunArtifact(view_pickers_tests);
    test_step.dependOn(&run_view_pickers_tests.step);
    b.step("test-view-pickers", "Run calendar, date, time, number and color picker tests").dependOn(&run_view_pickers_tests.step);
    const view_collections = b.addModule("ziggurat_view_collections", .{ .root_source_file = b.path("src/view/collections.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },                  .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_view", .module = declarative_view },
    } });
    const view_collections_tests = addTest(b, .{ .root_module = view_collections });
    check.dependOn(&view_collections_tests.step);
    const run_view_collections_tests = b.addRunArtifact(view_collections_tests);
    test_step.dependOn(&run_view_collections_tests.step);
    b.step("test-view-collections", "Run virtual table, outline and grid view tests").dependOn(&run_view_collections_tests.step);
    addSmoke(b, "smoke-view-collections", "tests/collections_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_view", .module = declarative_view },
        .{ .name = "ziggurat_view_collections", .module = view_collections },
    });
    addSmoke(b, "smoke-view-pickers", "tests/pickers_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_view", .module = declarative_view },
        .{ .name = "ziggurat_i18n", .module = i18n },
        .{ .name = "ziggurat_view_pickers", .module = view_pickers },
    });
    addSmoke(b, "smoke-chart", "tests/chart_view_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_view", .module = declarative_view },
        .{ .name = "ziggurat_chart", .module = chart },
        .{ .name = "ziggurat_chart_view", .module = chart_view },
    });
}
