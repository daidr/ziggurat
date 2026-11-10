const std = @import("std");
pub const packaging = @import("build_support/packaging.zig");
const native_support = @import("build_support/native.zig");
const helpers = @import("build_support/helpers.zig");
const smokes = @import("build_support/smokes.zig");
const ui_platforms = @import("build_support/ui_platforms.zig");
const webview = @import("build_support/webview.zig");
const useWindowsSelfHostedBackend = helpers.useWindowsSelfHostedBackend;
const shareCommonModules = helpers.shareCommonModules;
const addExamples = @import("build_support/examples.zig").addExamples;
const sourcePath = helpers.sourcePath;
const addExample = helpers.addExample;
const addWindowsProfileStorageNative = helpers.addWindowsProfileStorageNative;
const addSystemIntegrationNative = helpers.addSystemIntegrationNative;
const addSmoke = helpers.addSmoke;
const addSmokeModule = helpers.addSmokeModule;
const addSmokeExecutable = helpers.addSmokeExecutable;
pub const ApplicationIcon = helpers.ApplicationIcon;
pub const addApplicationResources = helpers.addApplicationResources;
pub const addApplicationResourcesWithIcon = helpers.addApplicationResourcesWithIcon;
const runInstalled = helpers.runInstalled;
pub const addBrowserSite = helpers.addBrowserSite;
const addWebApp = helpers.addWebApp;
const addResources = helpers.addResources;
const addTest = helpers.addTest;

pub fn build(b: *std.Build) void {
    b.installFile("LICENSE", "share/ziggurat/LICENSE");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    native_support.apple_sdk = b.option([]const u8, "macos-sdk", "macOS SDK root for cross-compiling to macOS");
    const web = b.option(bool, "webview", "Build the optional system WebView (Windows SDK or Linux WebKitGTK)") orelse false;
    const https_resources_enabled = b.option(bool, "https-resources", "Build the optional HTTPS resource transport on Windows or Linux") orelse false;
    const gpu = b.option(bool, "gpu", "Build the optional GPU renderer (D3D11 on Windows, Metal on macOS, OpenGL on Linux) with software fallback") orelse false;
    const webp = b.option(bool, "webp", "Build the optional pinned WebP decoder (fetch source first)") orelse false;
    const accessibility = b.option(bool, "accessibility", "Build the optional native accessibility bridge (Windows UI Automation, macOS NSAccessibility, Linux ATK)") orelse false;
    const check = b.step("check", "Compile selected examples and tests without running them");
    const test_step = b.step("test", "Run invariant tests without opening windows");
    var view_tests: ?*std.Build.Step.Compile = null;
    var webkit_file_run: ?*std.Build.Step.Run = null;
    var initializer_native_run: ?*std.Build.Step.Run = null;
    const pointer_classifier = b.createModule(.{
        .root_source_file = b.path("src/platform/pointer_clicks.zig"),
        .target = target,
        .optimize = optimize,
    });
    const classifier_tests = addTest(b, .{ .root_module = pointer_classifier });
    check.dependOn(&classifier_tests.step);
    const run_classifier_tests = b.addRunArtifact(classifier_tests);
    test_step.dependOn(&run_classifier_tests.step);
    b.step("test-pointer-classifier", "Run clock-free pointer timing, distance and wrap contracts").dependOn(&run_classifier_tests.step);
    const core = b.addModule("ziggurat", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "pointer_classifier", .module = pointer_classifier }},
    });
    const ipc = b.addModule("ziggurat_ipc", .{ .root_source_file = b.path("src/ipc/root.zig"), .target = target, .optimize = optimize });
    const webview_runtime = b.addModule("ziggurat_webview_runtime", .{ .root_source_file = b.path("src/webview_runtime/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    if (target.result.os.tag == .windows) webview_runtime.linkSystemLibrary("ole32", .{});
    if (target.result.os.tag == .linux) webview_runtime.linkSystemLibrary("dl", .{ .use_pkg_config = .no });
    const runtime_tests = addTest(b, .{ .root_module = webview_runtime });
    check.dependOn(&runtime_tests.step);
    const run_runtime_tests = b.addRunArtifact(runtime_tests);
    b.step("test-webview-runtime", "Verify explicit worker runtime discovery contracts without a page").dependOn(&run_runtime_tests.step);
    if (target.result.os.tag == .linux) {
        // Explicit test-only ICU dependency; ordinary libraries/test/check do
        // not require system ICU headers or its word dictionary data.
        const word_units = b.addExecutable(.{ .name = "test-document-word-units", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
        word_units.root_module.addCSourceFile(.{ .file = b.path("tests/document_accessibility_words.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        word_units.root_module.linkSystemLibrary("icu-i18n", .{ .use_pkg_config = .force });
        b.step("test-document-word-units", "Run independent system ICU word and grapheme boundary corpora").dependOn(&b.addRunArtifact(word_units).step);
    }
    if (target.result.os.tag == .windows) {
        const runtime_smoke = b.addExecutable(.{ .name = "smoke-webview-runtime", .root_module = b.createModule(.{
            .root_source_file = b.path("tests/webview_runtime_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ziggurat_webview_runtime", .module = webview_runtime }},
        }) });
        check.dependOn(&runtime_smoke.step);
        b.step("build-smoke-webview-runtime", "Build standalone engine discovery harness; run with an explicit loader DLL path").dependOn(&b.addInstallArtifact(runtime_smoke, .{}).step);
    }
    if (target.result.os.tag == .linux) {
        // A no-GTK harness: only explicit test DSOs are loaded by this target.
        // A real SDK path is an optional caller argument, never a default probe.
        const runtime_smoke = b.addExecutable(.{ .name = "smoke-webview-runtime-linux", .root_module = b.createModule(.{
            .root_source_file = b.path("tests/webview_runtime_linux_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ziggurat_webview_runtime", .module = webview_runtime }},
            .link_libc = true,
        }) });
        runtime_smoke.root_module.linkSystemLibrary("dl", .{ .use_pkg_config = .no });
        check.dependOn(&runtime_smoke.step);
        const runtime_run = b.addRunArtifact(runtime_smoke);
        const runtime_build = b.step("build-smoke-webview-runtime-linux", "Build worker discovery and four explicit test-only DSOs without GTK");
        runtime_build.dependOn(&b.addInstallArtifact(runtime_smoke, .{}).step);
        for ([_]?[]const u8{ null, "RUNTIME_FIXTURE_OMIT_MAJOR", "RUNTIME_FIXTURE_OMIT_MINOR", "RUNTIME_FIXTURE_OMIT_MICRO" }, 0..) |omit, i| {
            const fixture = b.addLibrary(.{ .name = b.fmt("runtime-discovery-fixture-{d}", .{i}), .linkage = .dynamic, .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
            const flags: []const []const u8 = if (omit) |define| &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-fPIC", b.fmt("-D{s}", .{define}) } else &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-fPIC" };
            fixture.root_module.addCSourceFile(.{ .file = b.path("tests/webview_runtime_linux_fixture.c"), .flags = flags });
            runtime_run.addArtifactArg(fixture);
            runtime_build.dependOn(&b.addInstallArtifact(fixture, .{}).step);
        }
        // The dependency has a unique SONAME and stays only in the build
        // cache. Pass its file directly, rather than linkLibrary (which adds
        // a search path), so this consumer has a controlled unresolved need.
        const runtime_dependency = b.addLibrary(.{ .name = "ziggurat-runtime-missingdependency", .version = .{ .major = 0, .minor = 0, .patch = 0 }, .linkage = .dynamic, .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
        runtime_dependency.root_module.addCSourceFile(.{ .file = b.path("tests/webview_runtime_linux_dependency.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-fPIC" } });
        const runtime_consumer = b.addLibrary(.{ .name = "runtime-discovery-needs-dependency", .linkage = .dynamic, .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
        runtime_consumer.root_module.addCSourceFile(.{ .file = b.path("tests/webview_runtime_linux_dependency.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-fPIC", "-DRUNTIME_FIXTURE_NEEDS_DEPENDENCY" } });
        runtime_consumer.each_lib_rpath = false;
        runtime_consumer.root_module.addObjectFile(runtime_dependency.getEmittedBin());
        runtime_run.addArg("--failed-load");
        runtime_run.addArtifactArg(runtime_consumer);
        runtime_build.dependOn(&b.addInstallArtifact(runtime_consumer, .{}).step);
        runtime_run.addPassthruArgs();
        b.step("smoke-webview-runtime-linux", "Run explicit worker and test-DSO discovery contracts; optional real DSO path follows --").dependOn(&runtime_run.step);
        const runtime_oracle = b.addExecutable(.{ .name = "webview-runtime-linux-oracle", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
        runtime_oracle.root_module.addCSourceFile(.{ .file = b.path("tests/webview_runtime_linux_oracle.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        runtime_oracle.root_module.linkSystemLibrary("dl", .{ .use_pkg_config = .no });
        runtime_oracle.root_module.linkSystemLibrary("pthread", .{ .use_pkg_config = .no });
        b.step("build-webview-runtime-linux-oracle", "Build the independent no-display worker version oracle; run with an explicit DSO path").dependOn(&b.addInstallArtifact(runtime_oracle, .{}).step);
    }
    const window_placement = b.addModule("ziggurat_window_placement", .{ .root_source_file = b.path("src/window_placement/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat", .module = core }}, .link_libc = true });
    if (target.result.os.tag == .windows) window_placement.linkSystemLibrary("user32", .{});
    if (target.result.os.tag == .linux) {
        const native = native_support.add(b, window_placement, "window-placement-native", "src/window_placement/native_linux.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        native.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        window_placement.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
    }
    if (target.result.os.tag == .windows or target.result.os.tag == .linux) addSmoke(b, "smoke-window-placement", "tests/window_placement_smoke.zig", target, optimize, &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_window_placement", .module = window_placement } });
    const document_app = b.addModule("ziggurat_document_app", .{ .root_source_file = b.path("src/document_app/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat", .module = core }} });
    const resource_stream = b.addModule("ziggurat_resource_stream", .{ .root_source_file = b.path("src/resource_stream/root.zig"), .target = target, .optimize = optimize });
    const http_response = b.addModule("ziggurat_http_response", .{ .root_source_file = b.path("src/http_response/root.zig"), .target = target, .optimize = optimize });
    const tls_pem = b.createModule(.{ .root_source_file = b.path("src/tls_pem/root.zig"), .target = target, .optimize = optimize });
    const file_stream = b.addModule("ziggurat_file_stream", .{ .root_source_file = b.path("src/file_stream/root.zig"), .target = target, .optimize = optimize });
    if (target.result.os.tag == .windows) {
        file_stream.link_libc = true;
        _ = native_support.add(b, file_stream, "file-stream-core-native", "src/file_stream/windows_core.c", &.{"-std=c11"}, target, optimize);
        _ = native_support.add(b, file_stream, "file-stream-file-native", "src/file_stream/windows_file.c", &.{"-std=c11"}, target, optimize);
        file_stream.linkSystemLibrary("kernel32", .{});
    }
    if (target.result.os.tag == .macos) {
        file_stream.link_libc = true;
        _ = native_support.add(b, file_stream, "file-stream-native", "src/file_stream/macos.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
    }
    if (target.result.os.tag == .linux) {
        file_stream.link_libc = true;
        const native = native_support.add(b, file_stream, "file-stream-native", "src/file_stream/linux.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        native.linkSystemLibrary("gio-unix-2.0", .{ .use_pkg_config = .force });
        file_stream.linkSystemLibrary("gio-unix-2.0", .{ .use_pkg_config = .force });
    }
    const native_stream = b.addModule("ziggurat_native_stream", .{
        .root_source_file = b.path("src/native_stream/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ziggurat_file_stream", .module = file_stream }},
    });
    const https_resources = b.addModule("ziggurat_https_resources", .{ .root_source_file = b.path("src/https_resources/root.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_http_response", .module = http_response },
        .{ .name = "ziggurat_file_stream", .module = file_stream },
        .{ .name = "ziggurat_tls_pem", .module = tls_pem },
    } });
    const https_resources_options = b.addOptions();
    https_resources_options.addOption(bool, "enabled", https_resources_enabled);
    https_resources.addOptions("ziggurat_https_resources_options", https_resources_options);
    if (https_resources_enabled and target.result.os.tag == .windows)
        @import("build_support/windows_https.zig").add(b, https_resources, target, optimize);
    if (https_resources_enabled and target.result.os.tag == .linux) {
        smokes.addLinuxHttpsResources(b, .{
            .https_resources = https_resources,
            .target = target,
            .optimize = optimize,
            .core = core,
            .check = check,
        });
    }
    const file_stream_tests = addTest(b, .{ .root_module = file_stream });
    const run_file_stream_tests = b.addRunArtifact(file_stream_tests);
    check.dependOn(&file_stream_tests.step);
    b.step("test-file-stream", "Verify consumer-neutral file preparation, cancellation and ownership contracts").dependOn(&run_file_stream_tests.step);
    const native_stream_tests = addTest(b, .{ .root_module = native_stream });
    const run_native_stream_tests = b.addRunArtifact(native_stream_tests);
    check.dependOn(&native_stream_tests.step);
    test_step.dependOn(&run_native_stream_tests.step);
    b.step("test-native-stream", "Verify generated byte-source bounds, cold capability and linear ownership").dependOn(&run_native_stream_tests.step);
    if (target.result.os.tag == .linux) {
        // Private module instances contain declarations only. This process
        // links one fault-enabled channel implementation, never production C.
        const fixture_file_stream = b.createModule(.{
            .root_source_file = b.path("src/file_stream/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        const fixture_native_stream = b.createModule(.{
            .root_source_file = b.path("src/native_stream/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ziggurat_file_stream", .module = fixture_file_stream }},
        });
        const native_tests = addTest(b, .{ .root_module = b.createModule(.{
            .root_source_file = b.path("tests/native_stream_native.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "ziggurat_native_stream", .module = fixture_native_stream },
                .{ .name = "ziggurat_file_stream", .module = fixture_file_stream },
            },
        }) });
        for ([_][]const u8{ "tests/native_stream_native.c", "src/file_stream/linux.c" }, 0..) |file, index| {
            const unit = native_support.add(b, native_tests.root_module, b.fmt("generated-stream-fault-{d}", .{index}), file, &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-DZWK_FILE_TESTING" }, target, optimize);
            unit.linkSystemLibrary("gio-unix-2.0", .{ .use_pkg_config = .force });
        }
        native_tests.root_module.linkSystemLibrary("gio-unix-2.0", .{ .use_pkg_config = .force });
        native_tests.root_module.linkSystemLibrary("pthread", .{ .use_pkg_config = .no });
        check.dependOn(&native_tests.step);
        b.step("test-native-stream-native", "Verify generated channel admission, backpressure, terminal state and physical ownership").dependOn(&b.addRunArtifact(native_tests).step);
    }
    const animation = b.addModule("ziggurat_animation", .{ .root_source_file = b.path("src/animation/root.zig"), .target = target, .optimize = optimize });
    const i18n = b.addModule("ziggurat_i18n", .{ .root_source_file = b.path("src/i18n/root.zig"), .target = target, .optimize = optimize });
    const i18n_tests = addTest(b, .{ .root_module = i18n });
    check.dependOn(&i18n_tests.step);
    const run_i18n_tests = b.addRunArtifact(i18n_tests);
    test_step.dependOn(&run_i18n_tests.step);
    b.step("test-i18n", "Run locale fallback, catalog, plural, number, date and pseudolocale tests").dependOn(&run_i18n_tests.step);
    const page_runtime = b.addModule("ziggurat_page_runtime", .{ .root_source_file = b.path("src/page_runtime/root.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ipc", .module = ipc },
        .{ .name = "ziggurat_i18n", .module = i18n },
    } });
    const page_runtime_tests = addTest(b, .{ .root_module = page_runtime });
    check.dependOn(&page_runtime_tests.step);
    const run_page_runtime_tests = b.addRunArtifact(page_runtime_tests);
    test_step.dependOn(&run_page_runtime_tests.step);
    b.step("test-page-runtime", "Run page handshake, runtime service, plugin routing, find script and plugin manifest tests").dependOn(&run_page_runtime_tests.step);
    const markdown = b.addModule("ziggurat_markdown", .{ .root_source_file = b.path("src/markdown/root.zig"), .target = target, .optimize = optimize });
    const markdown_tests = addTest(b, .{ .root_module = markdown });
    check.dependOn(&markdown_tests.step);
    const run_markdown_tests = b.addRunArtifact(markdown_tests);
    test_step.dependOn(&run_markdown_tests.step);
    b.step("test-markdown", "Run CommonMark block, inline, table, task list and HTML output tests").dependOn(&run_markdown_tests.step);
    // Optional: needs `python scripts/fetch-sqlite.py`, so it stays out of `test` and `check`.
    const sqlite = b.addModule("ziggurat_sqlite", .{ .root_source_file = b.path("src/sqlite/root.zig"), .target = target, .optimize = optimize });
    @import("build_support/sqlite.zig").add(b, sqlite, target, optimize);
    const sqlite_tests = addTest(b, .{ .root_module = sqlite });
    b.step("test-sqlite", "Run SQLite connection, binding, row, transaction, migration and thread tests (fetch source first)").dependOn(&b.addRunArtifact(sqlite_tests).step);
    const wake = b.addModule("ziggurat_wake", .{ .root_source_file = b.path("src/wake/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat", .module = core }} });
    if (target.result.os.tag == .windows or target.result.os.tag == .linux or target.result.os.tag == .macos) {
        wake.link_libc = true;
        const native = native_support.add(b, wake, "wake-native", "src/wake/native.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        if (target.result.os.tag == .linux) {
            native.linkSystemLibrary("glib-2.0", .{ .use_pkg_config = .force });
            wake.linkSystemLibrary("glib-2.0", .{ .use_pkg_config = .force });
        }
        if (target.result.os.tag == .macos) native_support.linkFrameworks(b, wake, &.{"CoreFoundation"});
        addSmoke(b, "smoke-wake", "tests/wake_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_wake", .module = wake },
            .{ .name = "ziggurat_animation", .module = animation },
        });
    }
    // Linux loads GIO for the system proxy settings with dlopen.
    const net = b.addModule("ziggurat_net", .{ .root_source_file = b.path("src/net/root.zig"), .target = target, .optimize = optimize, .link_libc = target.result.os.tag == .linux });
    // macOS reads the network settings and runs PAC files with CFNetwork.
    if (target.result.os.tag == .macos) native_support.linkFrameworks(b, net, &.{ "CoreFoundation", "CFNetwork" });
    const update = b.addModule("ziggurat_update", .{ .root_source_file = b.path("src/update/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat_net", .module = net }} });
    const plugin_fetch = b.addModule("ziggurat_plugin_fetch", .{ .root_source_file = b.path("src/page_runtime/plugins/fetch.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat_ipc", .module = ipc },
        .{ .name = "ziggurat_net", .module = net },
        .{ .name = "ziggurat_page_runtime", .module = page_runtime },
    } });
    const plugin_fetch_tests = addTest(b, .{ .root_module = plugin_fetch });
    check.dependOn(&plugin_fetch_tests.step);
    const run_plugin_fetch_tests = b.addRunArtifact(plugin_fetch_tests);
    test_step.dependOn(&run_plugin_fetch_tests.step);
    b.step("test-plugin-fetch", "Run the fetch plugin's streaming, redirect, validation and cancellation tests against local servers").dependOn(&run_plugin_fetch_tests.step);
    const plugin_websocket = b.addModule("ziggurat_plugin_websocket", .{ .root_source_file = b.path("src/page_runtime/plugins/websocket.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat_ipc", .module = ipc },
        .{ .name = "ziggurat_net", .module = net },
        .{ .name = "ziggurat_page_runtime", .module = page_runtime },
    } });
    const plugin_websocket_tests = addTest(b, .{ .root_module = plugin_websocket });
    check.dependOn(&plugin_websocket_tests.step);
    const run_plugin_websocket_tests = b.addRunArtifact(plugin_websocket_tests);
    test_step.dependOn(&run_plugin_websocket_tests.step);
    b.step("test-plugin-websocket", "Run the WebSocket plugin's message, piece, close, refusal and page-leave tests against local servers").dependOn(&run_plugin_websocket_tests.step);
    const system_watch = b.createModule(.{ .root_source_file = b.path("src/system/watch.zig"), .target = target, .optimize = optimize, .link_libc = target.result.os.tag == .windows });
    if (target.result.os.tag == .macos) native_support.linkFrameworks(b, system_watch, &.{ "CoreServices", "CoreFoundation" });
    const plugin_watch = b.addModule("ziggurat_plugin_watch", .{ .root_source_file = b.path("src/page_runtime/plugins/watch.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat_ipc", .module = ipc },
        .{ .name = "ziggurat_page_runtime", .module = page_runtime },
        .{ .name = "ziggurat_system_watch", .module = system_watch },
    } });
    const plugin_watch_tests = addTest(b, .{ .root_module = plugin_watch });
    check.dependOn(&plugin_watch_tests.step);
    const run_plugin_watch_tests = b.addRunArtifact(plugin_watch_tests);
    test_step.dependOn(&run_plugin_watch_tests.step);
    b.step("test-plugin-watch", "Run the watch plugin's snapshot comparison, rename pairing, root and request checks against temporary directories").dependOn(&run_plugin_watch_tests.step);
    // Loads SQLite at run time; libc gives the dynamic loader on Linux.
    const plugin_sqlite = b.addModule("ziggurat_plugin_sqlite", .{ .root_source_file = b.path("src/page_runtime/plugins/sqlite.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{
        .{ .name = "ziggurat_ipc", .module = ipc },
        .{ .name = "ziggurat_page_runtime", .module = page_runtime },
    } });
    const plugin_sqlite_tests = addTest(b, .{ .root_module = plugin_sqlite });
    check.dependOn(&plugin_sqlite_tests.step);
    const run_plugin_sqlite_tests = b.addRunArtifact(plugin_sqlite_tests);
    test_step.dependOn(&run_plugin_sqlite_tests.step);
    b.step("test-plugin-sqlite", "Run the SQLite plugin's value, statement, streaming, transaction, name and cancellation tests against the system SQLite").dependOn(&run_plugin_sqlite_tests.step);
    const assets = b.addModule("ziggurat_assets", .{ .root_source_file = b.path("src/assets/root.zig"), .target = target, .optimize = optimize });
    const extensions = b.addModule("ziggurat_extensions", .{ .root_source_file = b.path("src/extensions/root.zig"), .target = target, .optimize = optimize });
    const drawing_resources = b.addModule("ziggurat_drawing_resources", .{ .root_source_file = b.path("src/drawing_resources.zig"), .target = target, .optimize = optimize });
    const vector = b.addModule("ziggurat_vector", .{ .root_source_file = b.path("src/vector/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat_drawing_resources", .module = drawing_resources }} });
    const svg = b.addModule("ziggurat_svg", .{ .root_source_file = b.path("src/svg/root.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat_vector", .module = vector }, .{ .name = "ziggurat_drawing_resources", .module = drawing_resources },
    } });
    const shadows = b.addModule("ziggurat_shadows", .{ .root_source_file = b.path("src/ui/shadow_resource.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat_drawing_resources", .module = drawing_resources }} });
    const gaussian = b.addModule("ziggurat_gaussian", .{ .root_source_file = b.path("src/ui/gaussian_resource.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat_drawing_resources", .module = drawing_resources }} });
    const document = b.addModule("ziggurat_document", .{ .root_source_file = b.path("src/document/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat", .module = core }} });
    const document_diff = b.addModule("ziggurat_document_diff", .{ .root_source_file = b.path("src/document_diff/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat_document", .module = document }} });
    const document_diff_benchmark = b.addExecutable(.{ .name = "benchmark-document-diff", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/document_diff_benchmark.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "ziggurat_document", .module = document }, .{ .name = "ziggurat_document_diff", .module = document_diff } },
    }) });
    b.step("benchmark-document-diff", "Measure bounded snapshot comparison without a UI loop").dependOn(&b.addRunArtifact(document_diff_benchmark).step);
    const code_syntax = b.addModule("ziggurat_code_syntax", .{ .root_source_file = b.path("src/code_editor/syntax/root.zig"), .target = target, .optimize = optimize });
    const code_editor = b.addModule("ziggurat_code_editor", .{ .root_source_file = b.path("src/code_editor/root.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ziggurat_document", .module = document }, .{ .name = "ziggurat_code_syntax", .module = code_syntax }, .{ .name = "ziggurat_document_diff", .module = document_diff } } });
    const language_protocol = b.addModule("ziggurat_language_protocol", .{ .root_source_file = b.path("src/language_protocol/root.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat_document", .module = document },
        .{ .name = "ziggurat_code_editor", .module = code_editor },
        .{ .name = "ziggurat", .module = core },
    } });
    const protocol_server = b.addExecutable(.{ .name = "language-protocol-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/language_protocol_server.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat_language_protocol", .module = language_protocol }} }) });
    const protocol_smoke = b.addExecutable(.{ .name = "smoke-language-protocol", .root_module = b.createModule(.{ .root_source_file = b.path("tests/language_protocol_smoke.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_document", .module = document },
        .{ .name = "ziggurat_code_editor", .module = code_editor },
        .{ .name = "ziggurat_language_protocol", .module = language_protocol },
    } }) });
    addResources(b, protocol_smoke);
    check.dependOn(&protocol_smoke.step);
    check.dependOn(&protocol_server.step);
    const protocol_run = b.addRunArtifact(protocol_smoke);
    protocol_run.addArtifactArg(protocol_server);
    b.step("smoke-language-protocol", "Verify an explicit worker child process and versioned language protocol delivery").dependOn(&protocol_run.step);
    const shutdown_server = b.addExecutable(.{ .name = "language-protocol-shutdown-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/language_protocol_shutdown_server.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat_language_protocol", .module = language_protocol }} }) });
    const shutdown_smoke = b.addExecutable(.{ .name = "smoke-language-protocol-shutdown", .root_module = b.createModule(.{ .root_source_file = b.path("tests/language_protocol_shutdown_smoke.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_document", .module = document },
        .{ .name = "ziggurat_code_editor", .module = code_editor },
        .{ .name = "ziggurat_language_protocol", .module = language_protocol },
    } }) });
    addResources(b, shutdown_smoke);
    check.dependOn(&shutdown_smoke.step);
    check.dependOn(&shutdown_server.step);
    const shutdown_run = b.addRunArtifact(shutdown_smoke);
    shutdown_run.addArtifactArg(shutdown_server);
    b.step("smoke-language-protocol-shutdown", "Verify explicit worker shutdown, response-only service and child termination").dependOn(&shutdown_run.step);
    const vector_benchmark = b.addExecutable(.{ .name = "benchmark-vector", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/vector_benchmark.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ziggurat_vector", .module = vector }},
    }) });
    b.step("benchmark-vector", "Measure explicit path coverage preparation costs").dependOn(&b.addRunArtifact(vector_benchmark).step);
    if (target.result.os.tag == .linux) {
        const sampler = b.createModule(.{
            .root_source_file = b.path("src/ui/transform_composite.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ziggurat_drawing_resources", .module = drawing_resources }},
        });
        const affine_benchmark = b.addExecutable(.{ .name = "benchmark-affine-cairo", .root_module = b.createModule(.{
            .root_source_file = b.path("tools/benchmark_affine_cairo.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "sampler", .module = sampler }},
        }) });
        affine_benchmark.root_module.addCSourceFile(.{ .file = b.path("tools/benchmark_affine_cairo.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        affine_benchmark.root_module.linkSystemLibrary("pangocairo", .{ .use_pkg_config = .force });
        affine_benchmark.root_module.linkSystemLibrary("m", .{});
        const affine_run = b.addRunArtifact(affine_benchmark);
        affine_run.addPassthruArgs();
        b.step("benchmark-affine-cairo", "Measure segmented software affine completion against a test-only native baseline").dependOn(&affine_run.step);
    }
    const caret = b.addModule("ziggurat_caret", .{ .root_source_file = b.path("src/document_editor/caret.zig"), .target = target, .optimize = optimize });
    const fonts = b.addModule("ziggurat_fonts", .{ .root_source_file = b.path("src/fonts/root.zig"), .target = target, .optimize = optimize });
    if (target.result.os.tag == .linux) {
        const native = native_support.add(b, fonts, "fonts-native", "src/fonts/linux.c", &.{"-std=c11"}, target, optimize);
        for ([_][]const u8{ "fontconfig", "pangoft2", "pangocairo" }) |library| {
            native.linkSystemLibrary(library, .{ .use_pkg_config = .yes });
            fonts.linkSystemLibrary(library, .{ .use_pkg_config = .yes });
        }
        fonts.link_libc = true;
    }
    if (target.result.os.tag == .macos) {
        _ = native_support.add(b, fonts, "fonts-native", "src/fonts/macos.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        native_support.linkFrameworks(b, fonts, &.{ "CoreFoundation", "CoreText" });
    }
    if (target.result.os.tag == .windows) {
        _ = native_support.add(b, fonts, "fonts-native", "src/fonts/windows.c", &.{"-std=c11"}, target, optimize);
        fonts.linkSystemLibrary("dwrite", .{});
        fonts.linkSystemLibrary("gdi32", .{});
        fonts.link_libc = true;
    }
    const text_layout = b.addModule("ziggurat_text_layout", .{ .root_source_file = b.path("src/ui/text_layout.zig"), .target = target, .optimize = optimize });
    text_layout.addImport("ziggurat_drawing_resources", drawing_resources);
    const text_outlines = b.addModule("ziggurat_text_outlines", .{ .root_source_file = b.path("src/text_outlines/root.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat_text_layout", .module = text_layout },
        .{ .name = "ziggurat_vector", .module = vector },
    } });
    const svg_text = b.addModule("ziggurat_svg_text", .{ .root_source_file = b.path("src/svg_text/root.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat_svg", .module = svg },
        .{ .name = "ziggurat_text_layout", .module = text_layout },
        .{ .name = "ziggurat_text_outlines", .module = text_outlines },
    } });
    const gif = b.addModule("ziggurat_gif", .{ .root_source_file = b.path("src/images/gif.zig"), .target = target, .optimize = optimize });
    const png = b.addModule("ziggurat_png", .{ .root_source_file = b.path("src/images/png.zig"), .target = target, .optimize = optimize });
    const apng = b.addModule("ziggurat_apng", .{ .root_source_file = b.path("src/images/apng.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat_png", .module = png }} });
    const images = b.addModule("ziggurat_images", .{ .root_source_file = b.path("src/images/root.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ziggurat_drawing_resources", .module = drawing_resources }, .{ .name = "ziggurat_gif", .module = gif } } });
    const image_options = b.addOptions();
    image_options.addOption(bool, "webp", webp);
    images.addOptions("ziggurat_image_options", image_options);
    if (webp) {
        if (target.result.os.tag != .windows and target.result.os.tag != .linux) @panic("WebP worker is currently supported on Windows/Linux only");
        @import("build_support/webp.zig").add(b, images, target, optimize);
    }
    const image_drawing = b.addModule("ziggurat_image_drawing", .{ .root_source_file = b.path("src/ui/image_resource.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat_images", .module = images }, .{ .name = "ziggurat_drawing_resources", .module = drawing_resources },
    } });
    if (target.result.os.tag == .windows) {
        _ = native_support.add(b, images, "images-native", "src/images/windows.c", &.{"-std=c11"}, target, optimize);
        for ([_][]const u8{ "windowscodecs", "ole32", "uuid" }) |library| images.linkSystemLibrary(library, .{});
        images.link_libc = true;
    }
    if (target.result.os.tag == .linux) {
        const native = native_support.add(b, images, "images-native", "src/images/linux.c", &.{"-std=c11"}, target, optimize);
        native.linkSystemLibrary("gdk-pixbuf-2.0", .{ .use_pkg_config = .force });
        images.linkSystemLibrary("gdk-pixbuf-2.0", .{ .use_pkg_config = .force });
        images.link_libc = true;
    }
    if (target.result.cpu.arch == .wasm32) {
        _ = native_support.add(b, text_layout, "text-layout-native", "src/ui/text_layout_web.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        text_layout.link_libc = true;
    }
    if (target.result.os.tag == .windows) {
        _ = native_support.add(b, text_layout, "text-layout-native", "src/ui/text_layout_windows.c", &.{"-std=c11"}, target, optimize);
        text_layout.linkSystemLibrary("dwrite", .{});
        text_layout.linkSystemLibrary("gdi32", .{});
        text_layout.link_libc = true;
    }
    if (target.result.os.tag == .macos) {
        _ = native_support.add(b, text_layout, "text-layout-native", "src/ui/text_layout_macos.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        native_support.linkFrameworks(b, text_layout, &.{ "CoreFoundation", "CoreGraphics", "CoreText" });
    }
    if (target.result.os.tag == .linux) {
        const native = native_support.add(b, text_layout, "text-layout-native", "src/ui/text_layout_linux.c", &.{"-std=c11"}, target, optimize);
        native.linkSystemLibrary("pangocairo", .{ .use_pkg_config = .force });
        text_layout.linkSystemLibrary("pangocairo", .{ .use_pkg_config = .force });
        text_layout.link_libc = true;
    }
    if (target.result.os.tag == .windows or target.result.os.tag == .linux) {
        smokes.addTextSmokes(b, .{
            .target = target,
            .optimize = optimize,
            .text_layout = text_layout,
            .test_step = test_step,
            .check = check,
            .drawing_resources = drawing_resources,
            .fonts = fonts,
            .core = core,
            .document = document,
            .vector = vector,
            .text_outlines = text_outlines,
            .images = images,
            .image_drawing = image_drawing,
        });
    }
    const system = b.addModule("ziggurat_system", .{ .root_source_file = b.path("src/system/root.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_i18n", .module = i18n } } });
    // The file watcher uses FSEvents on macOS; menus, status items, the Dock
    // and dialogs are AppKit's.
    if (target.result.os.tag == .macos) {
        native_support.linkFrameworks(b, system, &.{ "CoreServices", "CoreFoundation", "AppKit", "Foundation", "UniformTypeIdentifiers" });
        _ = native_support.add(b, system, "system-menu-macos", "src/system/macos_menu.m", &.{ "-fobjc-arc", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        _ = native_support.add(b, system, "system-dialog-macos", "src/system/macos_dialog.m", &.{ "-fobjc-arc", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        native_support.linkFrameworks(b, system, &.{ "Carbon", "UserNotifications" });
        _ = native_support.add(b, system, "system-hotkey-macos", "src/system/macos_hotkey.m", &.{ "-fobjc-arc", "-Wall", "-Wextra", "-Werror" }, target, optimize);
    }
    if (target.result.os.tag == .linux) {
        const native = native_support.add(b, system, "system-shell-native", "src/system/shell_linux.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        native.linkSystemLibrary("gio-2.0", .{ .use_pkg_config = .force });
        native.linkSystemLibrary("gio-unix-2.0", .{ .use_pkg_config = .force });
        native.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        const secrets_native = native_support.add(b, system, "system-secrets-native", "src/system/secrets_linux.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        secrets_native.linkSystemLibrary("gio-2.0", .{ .use_pkg_config = .force });
        const now_playing_native = native_support.add(b, system, "system-now-playing-native", "src/system/now_playing_linux.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        now_playing_native.linkSystemLibrary("gio-2.0", .{ .use_pkg_config = .force });
        system.linkSystemLibrary("gio-2.0", .{ .use_pkg_config = .force });
        const signals_native = native_support.add(b, system, "system-signals-native", "src/system/signals_linux.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        signals_native.linkSystemLibrary("glib-2.0", .{ .use_pkg_config = .force });
        const recent_native = native_support.add(b, system, "system-recent-native", "src/system/recent_linux.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        recent_native.linkSystemLibrary("gio-2.0", .{ .use_pkg_config = .force });
        system.link_libc = true;
    }
    if (target.result.os.tag == .windows or target.result.os.tag == .linux) {
        smokes.addSystemSmokes(b, .{
            .target = target,
            .optimize = optimize,
            .core = core,
            .system = system,
        });
    }
    if (target.result.os.tag == .linux) {
        const desktop_native = native_support.add(b, system, "system-desktop-native", "src/system/desktop_linux.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        desktop_native.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        const clipboard_native = native_support.add(b, system, "system-clipboard-native", "src/system/clipboard_linux.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        clipboard_native.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        const drop_native = native_support.add(b, system, "system-drop-native", "src/system/drop_linux.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        drop_native.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        const transfer_native = native_support.add(b, system, "system-transfer-native", "src/system/transfer_linux.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        transfer_native.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        system.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        system.link_libc = true;
    }
    if (target.result.os.tag == .windows) {
        system.linkSystemLibrary("ole32", .{});
        system.linkSystemLibrary("advapi32", .{});
        system.linkSystemLibrary("shell32", .{});
        system.linkSystemLibrary("user32", .{});
        system.linkSystemLibrary("gdi32", .{});
        system.linkSystemLibrary("comctl32", .{});
        _ = native_support.add(b, system, "system-picker-native", "src/system/picker.c", &.{"-std=c11"}, target, optimize);
        _ = native_support.add(b, system, "system-message-native", "src/system/message.c", &.{"-std=c11"}, target, optimize);
        system.link_libc = true;
    }
    if (target.result.os.tag == .linux) addSmoke(b, "smoke-system-menus", "tests/system_menus_linux_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_system", .module = system },
    });
    if (target.result.os.tag == .linux) {
        // Needs a session bus and an X11 display: dbus-run-session -- xvfb-run.
        const desktop_smoke = addSmokeModule(b, "smoke-system-desktop", "tests/system_desktop_linux_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_system", .module = system },
        });
        const fixture = native_support.add(b, desktop_smoke, "system-desktop-fixture", "tests/system_desktop_linux_fixture.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        fixture.linkSystemLibrary("gio-2.0", .{ .use_pkg_config = .force });
        fixture.linkSystemLibrary("gdk-pixbuf-2.0", .{ .use_pkg_config = .force });
        desktop_smoke.linkSystemLibrary("gio-2.0", .{ .use_pkg_config = .force });
        desktop_smoke.linkSystemLibrary("gdk-pixbuf-2.0", .{ .use_pkg_config = .force });
        desktop_smoke.linkSystemLibrary("x11", .{ .use_pkg_config = .force });
        // Needs a session bus and an X11 display: dbus-run-session -- xvfb-run.
        const now_playing_smoke = addSmokeModule(b, "smoke-now-playing", "tests/now_playing_linux_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_system", .module = system },
        });
        const now_playing_fixture = native_support.add(b, now_playing_smoke, "now-playing-fixture", "tests/now_playing_linux_fixture.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        now_playing_fixture.linkSystemLibrary("gio-2.0", .{ .use_pkg_config = .force });
        now_playing_smoke.linkSystemLibrary("gio-2.0", .{ .use_pkg_config = .force });
        // Needs a session bus and an X11 display: dbus-run-session -- xvfb-run.
        const portal_smoke = addSmokeModule(b, "smoke-theme-portal", "tests/theme_portal_linux_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_system", .module = system },
        });
        const portal_fixture = native_support.add(b, portal_smoke, "theme-portal-fixture", "tests/theme_portal_linux_fixture.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        portal_fixture.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        portal_smoke.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        // Needs an isolated Xvfb with a window manager: shrinks its only output.
        const displays_smoke = addSmokeModule(b, "smoke-window-placement-displays", "tests/window_placement_displays_linux.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_window_placement", .module = window_placement },
            .{ .name = "ziggurat_system", .module = system },
        });
        const randr = native_support.add(b, displays_smoke, "window-placement-randr-fixture", "tests/window_placement_randr_fixture.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        randr.linkSystemLibrary("xrandr", .{ .use_pkg_config = .force });
        displays_smoke.linkSystemLibrary("xrandr", .{ .use_pkg_config = .force });
        displays_smoke.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
    }
    if (target.result.os.tag == .windows) addSmoke(b, "smoke-system-menus", "tests/system_menus_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_system", .module = system },
    });
    if (target.result.os.tag == .linux) {
        const native = native_support.add(b, system, "system-linux-native", "src/system/linux_system.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        native.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        const details = native_support.add(b, system, "system-linux-details", "src/system/details_linux.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        details.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        const desktop = native_support.add(b, system, "system-linux-desktop", "src/system/linux_desktop.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        desktop.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        desktop.linkSystemLibrary("x11", .{ .use_pkg_config = .force });
        system.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        system.linkSystemLibrary("x11", .{ .use_pkg_config = .force });
        system.link_libc = true;
    }
    addSystemIntegrationNative(b, system, target, optimize);
    const system_unit_tests = addTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("src/system/root.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_i18n", .module = i18n } } }) });
    addSystemIntegrationNative(b, system_unit_tests.root_module, target, optimize);
    if (target.result.os.tag == .windows) {
        for ([_][]const u8{ "user32", "gdi32", "shell32", "ole32" }) |library| system_unit_tests.root_module.linkSystemLibrary(library, .{});
        _ = native_support.add(b, system_unit_tests.root_module, "system-picker-native-test", "src/system/picker.c", &.{"-std=c11"}, target, optimize);
    }
    if (target.result.os.tag == .windows or target.result.os.tag == .linux or target.result.os.tag == .macos) {
        // macOS runs the single-instance part only; the probe stays unlinked.
        const integration_probe = b.createModule(.{ .root_source_file = b.path("tests/os_integration_probe.zig"), .target = target, .optimize = optimize, .link_libc = true });
        if (target.result.os.tag == .linux) {
            integration_probe.addCSourceFile(.{ .file = b.path("tests/os_integration_probe.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
            for ([_][]const u8{ "gio-2.0", "gio-unix-2.0" }) |library| integration_probe.linkSystemLibrary(library, .{ .use_pkg_config = .yes });
        } else if (target.result.os.tag == .windows) integration_probe.linkSystemLibrary("shlwapi", .{});
        addSmoke(b, "smoke-os-integration", "tests/os_integration_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_system", .module = system },
            .{ .name = "os_integration_probe", .module = integration_probe },
        });
    }
    if (target.result.os.tag == .windows) {
        core.linkSystemLibrary("user32", .{});
        core.linkSystemLibrary("ole32", .{});
        core.linkSystemLibrary("imm32", .{});
        core.linkSystemLibrary("dwmapi", .{});
        core.linkSystemLibrary("gdi32", .{});
        core.link_libc = true;
    }
    if (target.result.os.tag == .macos) {
        _ = native_support.add(b, core, "core-native", "src/platform/macos.m", &.{ "-fno-objc-arc", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        _ = native_support.add(b, core, "core-native-window", "src/platform/macos_window.m", &.{ "-fno-objc-arc", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        native_support.linkFrameworks(b, core, &.{ "AppKit", "Foundation", "CoreFoundation", "CoreGraphics", "QuartzCore" });
        core.linkSystemLibrary("objc", .{ .use_pkg_config = .no });
    }
    if (target.result.os.tag == .linux) {
        const native = native_support.add(b, core, "core-native", "src/platform/linux.c", &.{"-std=c11"}, target, optimize);
        native.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        native.linkSystemLibrary("x11", .{ .use_pkg_config = .force });
        core.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        core.linkSystemLibrary("x11", .{ .use_pkg_config = .force });
        core.link_libc = true;
        const accessibility_host_test = b.addExecutable(.{ .name = "test-linux-accessibility-host", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
        accessibility_host_test.root_module.addCSourceFile(.{ .file = b.path("tests/linux_accessibility_host_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations" } });
        accessibility_host_test.root_module.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        accessibility_host_test.root_module.linkSystemLibrary("x11", .{ .use_pkg_config = .force });
        check.dependOn(&accessibility_host_test.step);
        b.step("test-linux-accessibility-host", "Verify generic GTK child host ownership, reentry and retirement").dependOn(&b.addRunArtifact(accessibility_host_test).step);
        const accessibility_position_test = b.addExecutable(.{ .name = "test-linux-accessibility-position", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
        accessibility_position_test.root_module.addCSourceFile(.{ .file = b.path("tests/linux_accessibility_position_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations" } });
        accessibility_position_test.root_module.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        accessibility_position_test.root_module.linkSystemLibrary("x11", .{ .use_pkg_config = .force });
        check.dependOn(&accessibility_position_test.step);
        b.step("test-linux-accessibility-position", "Verify original GTK area coordinate snapshots and retired-token refusal").dependOn(&b.addRunArtifact(accessibility_position_test).step);
        const pointer_gtk_test = b.addExecutable(.{ .name = "test-pointer-gtk", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
        pointer_gtk_test.root_module.addCSourceFile(.{ .file = b.path("tests/linux_pointer_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations" } });
        pointer_gtk_test.root_module.addIncludePath(b.path("src/platform"));
        pointer_gtk_test.root_module.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        pointer_gtk_test.root_module.linkSystemLibrary("x11", .{ .use_pkg_config = .force });
        check.dependOn(&pointer_gtk_test.step);
        b.step("test-pointer-gtk", "Verify native GTK pointer facts, pairing and callback continuation authority").dependOn(&b.addRunArtifact(pointer_gtk_test).step);
        const touch_test = b.addExecutable(.{ .name = "test-linux-touch", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
        touch_test.root_module.addCSourceFile(.{ .file = b.path("tests/linux_touch_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        touch_test.root_module.linkSystemLibrary("m", .{});
        check.dependOn(&touch_test.step);
        b.step("test-linux-touch", "Verify touchscreen taps, long presses and scrolls").dependOn(&b.addRunArtifact(touch_test).step);
    }
    if (target.result.os.tag == .windows or target.result.os.tag == .linux) {
        const damage = b.addExecutable(.{ .name = "smoke-damage", .root_module = b.createModule(.{
            .root_source_file = b.path("tests/damage_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ziggurat", .module = core }},
        }) });
        if (target.result.os.tag == .linux) {
            damage.root_module.addCSourceFile(.{ .file = b.path("tests/damage_linux.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations" } });
            damage.root_module.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        }
        addResources(b, damage);
        check.dependOn(&damage.step);
        b.step("smoke-damage", "Verify native update regions for explicit DIP damage").dependOn(&b.addRunArtifact(damage).step);
    }
    const ui = b.addModule("ziggurat_ui", .{
        .root_source_file = b.path("src/ui/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "pointer_classifier", .module = pointer_classifier } },
    });
    const declarative_view = b.addModule("ziggurat_view", .{ .root_source_file = b.path("src/view/root.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui }, .{ .name = "ziggurat_animation", .module = animation } } });
    // The views' developer tools are left out of release builds, as their
    // windows have none, unless asked for.
    const view_options = b.addOptions();
    view_options.addOption(bool, "inspector", b.option(bool, "inspector", "Build the views' inspector (default: Debug builds only)") orelse (optimize == .debug));
    declarative_view.addOptions("ziggurat_view_options", view_options);
    // Drives a running app from another process; apps link it in test builds.
    const automation_options = b.addOptions();
    automation_options.addOption(bool, "webview", web);
    const automation = b.addModule("ziggurat_automation", .{ .root_source_file = b.path("src/automation/root.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui }, .{ .name = "ziggurat_view", .module = declarative_view },
    } });
    automation.addOptions("ziggurat_automation_options", automation_options);
    automation.addImport("ziggurat_window_placement", window_placement);
    const automation_tests = addTest(b, .{ .root_module = automation });
    check.dependOn(&automation_tests.step);
    const run_automation_tests = b.addRunArtifact(automation_tests);
    test_step.dependOn(&run_automation_tests.step);
    b.step("test-automation", "Run the automation protocol, input and socket tests").dependOn(&run_automation_tests.step);
    if (target.result.os.tag == .windows or target.result.os.tag == .linux or target.result.os.tag == .macos) addSmoke(b, "smoke-automation", "tests/automation_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_view", .module = declarative_view },
        .{ .name = "ziggurat_system", .module = system },
        .{ .name = "ziggurat_automation", .module = automation },
    });
    // ziggurat-automation: the socket's command line client for agents.
    const automation_cli_options = b.addOptions();
    automation_cli_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    const automation_cli_module = b.addModule("ziggurat_automation_cli", .{ .root_source_file = b.path("tools/automation/cli.zig"), .target = target, .optimize = optimize });
    const automation_cli = b.addExecutable(.{ .name = "ziggurat-automation", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/automation/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggurat_automation_cli", .module = automation_cli_module },
            .{ .name = "automation_cli_options", .module = automation_cli_options.createModule() },
        },
    }) });
    b.installArtifact(automation_cli);
    b.step("automation-cli", "Build ziggurat-automation, the automation socket's command line client for agents").dependOn(&b.addInstallArtifact(automation_cli, .{}).step);
    check.dependOn(&automation_cli.step);
    const automation_cli_tests = addTest(b, .{ .root_module = automation_cli_module });
    const automation_cli_main_tests = addTest(b, .{ .root_module = automation_cli.root_module });
    check.dependOn(&automation_cli_tests.step);
    check.dependOn(&automation_cli_main_tests.step);
    const test_automation_cli = b.step("test-automation-cli", "Run ziggurat-automation's argument, session, snapshot, diff and command tests");
    test_automation_cli.dependOn(&b.addRunArtifact(automation_cli_tests).step);
    test_automation_cli.dependOn(&b.addRunArtifact(automation_cli_main_tests).step);
    test_step.dependOn(test_automation_cli);
    if (target.result.os.tag == .windows or target.result.os.tag == .linux or target.result.os.tag == .macos) addSmoke(b, "smoke-automation-cli", "tests/automation_cli_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_view", .module = declarative_view },
        .{ .name = "ziggurat_system", .module = system },
        .{ .name = "ziggurat_automation", .module = automation },
        .{ .name = "ziggurat_automation_cli", .module = automation_cli_module },
    });
    const view_graphics = b.addModule("ziggurat_view_graphics", .{ .root_source_file = b.path("src/view/graphics.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },                  .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_view", .module = declarative_view }, .{ .name = "ziggurat_vector", .module = vector },
        .{ .name = "ziggurat_svg", .module = svg },
    } });
    const view_video = b.addModule("ziggurat_view_video", .{ .root_source_file = b.path("src/view/video.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat_ui", .module = ui },   .{ .name = "ziggurat_view", .module = declarative_view },
        .{ .name = "ziggurat_gif", .module = gif }, .{ .name = "ziggurat_apng", .module = apng },
        .{ .name = "ziggurat", .module = core },
    } });
    // The system's media engines: GStreamer (loaded at the first video),
    // AVFoundation, the browser's video element.
    const system_video = b.addModule("ziggurat_video", .{ .root_source_file = b.path("src/video/root.zig"), .target = target, .optimize = optimize, .link_libc = target.result.cpu.arch != .wasm32, .imports = &.{
        .{ .name = "ziggurat_ui", .module = ui },                 .{ .name = "ziggurat_view", .module = declarative_view },
        .{ .name = "ziggurat_view_video", .module = view_video },
    } });
    if (target.result.os.tag == .macos) {
        native_support.add(b, system_video, "video-avfoundation", "src/video/avfoundation.m", &.{ "-fobjc-arc", "-Wall", "-Wextra", "-Werror" }, target, optimize).addIncludePath(b.path("src/ui"));
        native_support.linkFrameworks(b, system_video, &.{ "AVFoundation", "CoreMedia", "CoreVideo", "QuartzCore", "Foundation" });
    }
    // Media Foundation's media engine, its DLLs loaded with the first video.
    if (target.result.os.tag == .windows) {
        _ = native_support.add(b, system_video, "video-media-foundation", "src/video/media_foundation.c", &.{ "-Wall", "-Wextra", "-Werror" }, target, optimize);
        system_video.linkSystemLibrary("ole32", .{});
        system_video.linkSystemLibrary("oleaut32", .{});
    }
    // A clip played by the system's engine in a real window, drawn in
    // software, and with -Dgpu=true by OpenGL or Metal from its NV12 planes.
    if (target.result.os.tag == .linux or target.result.os.tag == .macos or target.result.os.tag == .windows) addSmoke(b, "smoke-video", "tests/video_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },                  .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_view", .module = declarative_view }, .{ .name = "ziggurat_view_video", .module = view_video },
        .{ .name = "ziggurat_video", .module = system_video },
    });
    // An app's own frames of video, in BGRA, NV12 and I420, drawn and read
    // back each frame: `-- [frames]`.
    if (target.result.os.tag == .linux or target.result.os.tag == .macos) {
        _ = addSmokeExecutable(b, "benchmark-video-frames", "tests/video_frame_benchmark.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui }, .{ .name = "ziggurat_view", .module = declarative_view },
        });
    }
    const view_timer = b.addModule("ziggurat_view_timer", .{ .root_source_file = b.path("src/view/timer.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },      .{ .name = "ziggurat_view", .module = declarative_view },
        .{ .name = "ziggurat_wake", .module = wake },
    } });
    const markdown_view = b.addModule("ziggurat_markdown_view", .{ .root_source_file = b.path("src/markdown/view.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat_markdown", .module = markdown }, .{ .name = "ziggurat_view", .module = declarative_view },
        .{ .name = "ziggurat_ui", .module = ui },
    } });
    const markdown_code = b.addModule("ziggurat_markdown_code", .{ .root_source_file = b.path("src/markdown/code_text.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat_markdown", .module = markdown },       .{ .name = "ziggurat_markdown_view", .module = markdown_view },
        .{ .name = "ziggurat_text_layout", .module = text_layout }, .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_view", .module = declarative_view },
    } });
    const view_rich_text = b.addModule("ziggurat_view_rich_text", .{ .root_source_file = b.path("src/view/rich_text.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat_ui", .module = ui }, .{ .name = "ziggurat_view", .module = declarative_view },
    } });
    const view_rich_text_tests = addTest(b, .{ .root_module = view_rich_text });
    check.dependOn(&view_rich_text_tests.step);
    const run_view_rich_text_tests = b.addRunArtifact(view_rich_text_tests);
    test_step.dependOn(&run_view_rich_text_tests.step);
    b.step("test-view-rich-text", "Run rich text wrapping, baseline, decoration and paint tests").dependOn(&run_view_rich_text_tests.step);
    const markdown_rich = b.addModule("ziggurat_markdown_rich", .{ .root_source_file = b.path("src/markdown/rich_text.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat_markdown", .module = markdown },     .{ .name = "ziggurat_markdown_view", .module = markdown_view },
        .{ .name = "ziggurat_view", .module = declarative_view }, .{ .name = "ziggurat_view_rich_text", .module = view_rich_text },
    } });
    const markdown_rich_tests = addTest(b, .{ .root_module = markdown_rich });
    check.dependOn(&markdown_rich_tests.step);
    const run_markdown_rich_tests = b.addRunArtifact(markdown_rich_tests);
    test_step.dependOn(&run_markdown_rich_tests.step);
    b.step("test-markdown-rich", "Run Markdown inline style to rich text span tests").dependOn(&run_markdown_rich_tests.step);
    const chart = b.addModule("ziggurat_chart", .{ .root_source_file = b.path("src/chart/root.zig"), .target = target, .optimize = optimize });
    const chart_tests = addTest(b, .{ .root_module = chart });
    check.dependOn(&chart_tests.step);
    const run_chart_tests = b.addRunArtifact(chart_tests);
    test_step.dependOn(&run_chart_tests.step);
    b.step("test-chart", "Run chart scale, tick, stack, path, downsampling, layout and selection tests").dependOn(&run_chart_tests.step);
    if (target.result.os.tag == .windows or target.result.os.tag == .linux) {
        smokes.addDrawingSmokes(b, .{
            .target = target,
            .optimize = optimize,
            .markdown = markdown,
            .markdown_view = markdown_view,
            .markdown_code = markdown_code,
            .text_layout = text_layout,
            .declarative_view = declarative_view,
            .core = core,
            .ui = ui,
            .system = system,
            .wake = wake,
            .view_timer = view_timer,
            .view_graphics = view_graphics,
            .view_video = view_video,
            .animation = animation,
            .svg = svg,
            .svg_text = svg_text,
            .text_outlines = text_outlines,
            .vector = vector,
        });
    }
    const ui_options = b.addOptions();
    ui.addImport("ziggurat_drawing_resources", drawing_resources);
    ui.addImport("ziggurat_vector", vector);
    const shader = b.addModule("ziggurat_shader", .{ .root_source_file = b.path("src/shader/root.zig"), .target = target, .optimize = optimize });
    ui.addImport("ziggurat_shader", shader);
    const shader_tests = addTest(b, .{ .root_module = shader });
    check.dependOn(&shader_tests.step);
    const run_shader_tests = b.addRunArtifact(shader_tests);
    test_step.dependOn(&run_shader_tests.step);
    b.step("test-shader", "Run shader language, bounded execution and uniform contracts").dependOn(&run_shader_tests.step);
    if (target.result.os.tag == .linux) {
        // Translated programs against the CPU machine on OpenGL (Mesa
        // draws without a GPU); needs EGL and libepoxy.
        const gl_parity = addTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/shader_gpu_gl.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "ziggurat_shader", .module = shader }} }) });
        gl_parity.root_module.addCSourceFile(.{ .file = b.path("tests/shader_gpu_gl.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        gl_parity.root_module.linkSystemLibrary("epoxy", .{});
        check.dependOn(&gl_parity.step);
        b.step("test-shader-gl", "Run translated shader programs on OpenGL against the CPU machine").dependOn(&b.addRunArtifact(gl_parity).step);
    }
    if (target.result.os.tag == .macos) {
        // Translated programs against the CPU machine on Metal, compiled at
        // run time as the renderer compiles them.
        const metal_parity = addTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/shader_gpu_metal.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "ziggurat_shader", .module = shader }} }) });
        _ = native_support.add(b, metal_parity.root_module, "shader-gpu-metal-native", "tests/shader_gpu_metal.m", &.{ "-fobjc-arc", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        native_support.linkFrameworks(b, metal_parity.root_module, &.{ "Metal", "Foundation" });
        check.dependOn(&metal_parity.step);
        b.step("test-shader-metal", "Run translated shader programs on Metal against the CPU machine").dependOn(&b.addRunArtifact(metal_parity).step);
    }
    if (target.result.os.tag == .windows) {
        // Translated programs against the CPU machine on Direct3D 11 WARP,
        // compiled by the system's HLSL compiler.
        const d3d_parity = addTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/shader_gpu_d3d.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "ziggurat_shader", .module = shader }} }) });
        d3d_parity.root_module.addCSourceFiles(.{ .files = &.{ "tests/shader_gpu_d3d.c", "src/ui/hlsl_compile.c" }, .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        d3d_parity.root_module.linkSystemLibrary("d3d11", .{});
        check.dependOn(&d3d_parity.step);
        const run_d3d_parity = b.addRunArtifact(d3d_parity);
        test_step.dependOn(&run_d3d_parity.step);
        b.step("test-shader-d3d", "Run translated shader programs on Direct3D 11 against the CPU machine").dependOn(&run_d3d_parity.step);
    }
    const shaped_editor = b.addModule("ziggurat_shaped_editor", .{ .root_source_file = b.path("src/ui/shaped_editor.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_text_layout", .module = text_layout },
        .{ .name = "ziggurat_caret", .module = caret },
    } });
    const virtual_list = b.addModule("ziggurat_virtual_list", .{ .root_source_file = b.path("src/ui/virtual_list.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui } } });
    if (target.result.os.tag == .windows and accessibility) {
        const list_smoke = b.addExecutable(.{ .name = "smoke-virtual-list-control", .root_module = b.createModule(.{
            .root_source_file = b.path("tests/virtual_list_control_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ziggurat", .module = core },
                .{ .name = "ziggurat_ui", .module = ui },
                .{ .name = "ziggurat_virtual_list", .module = virtual_list },
            },
        }) });
        _ = native_support.add(b, list_smoke.root_module, "virtual-list-control-client", "tests/virtual_list_control_client.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        for ([_][]const u8{ "ole32", "oleaut32", "uiautomationcore", "uuid" }) |library| list_smoke.root_module.linkSystemLibrary(library, .{});
        addResources(b, list_smoke);
        check.dependOn(&list_smoke.step);
        const install = b.addInstallArtifact(list_smoke, .{});
        b.step("build-smoke-virtual-list-control", "Build the isolated native complete-list UI Automation fixture").dependOn(&install.step);
        const run = runInstalled(b, b.graph.path(.install_bin, "smoke-virtual-list-control.exe"));
        run.step.dependOn(&install.step);
        b.step("smoke-virtual-list-control", "Verify native complete-list selection, offscreen rows and captured action retirement").dependOn(&run.step);
    } else if (target.result.os.tag == .linux) {
        addSmoke(b, "smoke-accessibility-linux", "tests/linux_accessibility_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_ui", .module = ui },
        });
        addSmoke(b, "smoke-virtual-list-control", "tests/virtual_list_control_linux_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_ui", .module = ui },
            .{ .name = "ziggurat_virtual_list", .module = virtual_list },
        });
    }
    const prepared_hit = b.createModule(.{ .root_source_file = b.path("src/document_editor/prepared_hit.zig"), .target = target, .optimize = optimize });
    const prepared_hit_tests = addTest(b, .{ .root_module = prepared_hit });
    const run_prepared_hit_tests = b.addRunArtifact(prepared_hit_tests);
    check.dependOn(&prepared_hit_tests.step);
    test_step.dependOn(&run_prepared_hit_tests.step);
    b.step("test-prepared-hit", "Verify the shared immutable Prepared hit routing kernel").dependOn(&run_prepared_hit_tests.step);
    const document_editor = b.addModule("ziggurat_document_editor", .{ .root_source_file = b.path("src/document_editor/root.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },                         .{ .name = "ziggurat_document", .module = document },
        .{ .name = "ziggurat_ui", .module = ui },                        .{ .name = "ziggurat_text_layout", .module = text_layout },
        .{ .name = "ziggurat_caret", .module = caret },                  .{ .name = "ziggurat_prepared_hit", .module = prepared_hit },
        .{ .name = "pointer_classifier", .module = pointer_classifier },
    } });
    const view_text = b.addModule("ziggurat_view_text", .{ .root_source_file = b.path("src/view/text_field.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },                  .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_view", .module = declarative_view }, .{ .name = "ziggurat_document_editor", .module = document_editor },
    } });
    const view_text_tests = addTest(b, .{ .root_module = view_text });
    check.dependOn(&view_text_tests.step);
    const run_view_text_tests = b.addRunArtifact(view_text_tests);
    test_step.dependOn(&run_view_text_tests.step);
    b.step("test-view-text", "Run view text field placeholder and caret tests").dependOn(&run_view_text_tests.step);
    if (target.result.os.tag == .windows or target.result.os.tag == .linux) {
        addSmoke(b, "smoke-view-text", "tests/view_text_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_ui", .module = ui },
            .{ .name = "ziggurat_document", .module = document },
            .{ .name = "ziggurat_text_layout", .module = text_layout },
            .{ .name = "ziggurat_document_editor", .module = document_editor },
            .{ .name = "ziggurat_view", .module = declarative_view },
            .{ .name = "ziggurat_view_text", .module = view_text },
        });
    }
    const document_accessibility = b.addModule("ziggurat_document_accessibility", .{ .root_source_file = b.path("src/document_accessibility/root.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_document", .module = document },
        .{ .name = "ziggurat_document_editor", .module = document_editor },
        .{ .name = "ziggurat_ui", .module = ui },
    } });
    const prepared_hit_abi: ?*std.Build.Step.Compile = if (target.result.os.tag == .windows or target.result.os.tag == .linux)
        b.addObject(.{ .name = "document-prepared-hit-abi", .root_module = b.createModule(.{ .root_source_file = b.path("src/document_accessibility/prepared_hit_abi.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "ziggurat_prepared_hit", .module = prepared_hit }} }) })
    else
        null;
    if (prepared_hit_abi) |object| document_accessibility.addObject(object);
    if (target.result.os.tag == .linux) {
        document_accessibility.link_libc = true;
        for ([_][]const u8{ "linux_ledger.c", "linux_store.c", "linux_provider.c" }) |file| {
            const native = native_support.add(b, document_accessibility, b.fmt("document-accessibility-{s}", .{file}), b.fmt("src/document_accessibility/{s}", .{file}), &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
            native.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        }
        document_accessibility.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        const accessibility_client = b.addExecutable(.{ .name = "document-accessibility-atspi-client", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
        accessibility_client.root_module.addCSourceFile(.{ .file = b.path("tests/document_accessibility_atspi_client.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        accessibility_client.root_module.linkSystemLibrary("atspi-2", .{ .use_pkg_config = .force });
        accessibility_client.root_module.linkSystemLibrary("gobject-2.0", .{ .use_pkg_config = .force });
        check.dependOn(&accessibility_client.step);
        b.step("build-document-accessibility-atspi-client", "Build the separate-process AT-SPI document oracle").dependOn(&b.addInstallArtifact(accessibility_client, .{}).step);
        const accessibility_owner = b.addExecutable(.{ .name = "test-document-accessibility-linux-owner", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
        accessibility_owner.root_module.addObject(prepared_hit_abi.?);
        accessibility_owner.root_module.addCSourceFiles(.{ .files = &.{ "tests/document_accessibility_linux_owner.c", "src/document_accessibility/linux_ledger.c", "src/document_accessibility/linux_store.c", "src/document_accessibility/linux_provider.c" }, .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations", "-DZDA_LINUX_TESTING" } });
        accessibility_owner.root_module.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        accessibility_owner.root_module.linkSystemLibrary("x11", .{ .use_pkg_config = .force });
        check.dependOn(&accessibility_owner.step);
        b.step("test-document-accessibility-linux-owner", "Verify Linux document provider C ownership, budgets, notifications and late references").dependOn(&b.addRunArtifact(accessibility_owner).step);
        addSmoke(b, "smoke-document-accessibility-linux", "tests/document_accessibility_linux_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_document", .module = document },
            .{ .name = "ziggurat_document_editor", .module = document_editor },
            .{ .name = "ziggurat_text_layout", .module = text_layout },
            .{ .name = "ziggurat_ui", .module = ui },
            .{ .name = "ziggurat_document_accessibility", .module = document_accessibility },
        });
    }
    if (target.result.os.tag == .windows) {
        smokes.addWindowsDocumentAccessibility(b, .{
            .document_accessibility = document_accessibility,
            .target = target,
            .optimize = optimize,
            .core = core,
            .ui = ui,
            .text_layout = text_layout,
            .document = document,
            .document_editor = document_editor,
            .check = check,
            .prepared_hit_abi = prepared_hit_abi,
        });
    }
    const document_diff_view = b.addModule("ziggurat_document_diff_view", .{ .root_source_file = b.path("src/document_diff_view/root.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_document", .module = document },
        .{ .name = "ziggurat_document_diff", .module = document_diff },
        .{ .name = "ziggurat_document_editor", .module = document_editor },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_text_layout", .module = text_layout },
    } });
    const document_diff_accessibility = b.addModule("ziggurat_document_diff_accessibility", .{ .root_source_file = b.path("src/document_diff_accessibility/root.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_document", .module = document },
        .{ .name = "ziggurat_document_diff_view", .module = document_diff_view },
        .{ .name = "ziggurat_document_accessibility", .module = document_accessibility },
    } });
    if (target.result.os.tag == .windows) {
        const smoke_diff_accessibility = b.addExecutable(.{ .name = "smoke-document-diff-accessibility", .root_module = b.createModule(.{
            .root_source_file = b.path("tests/document_diff_accessibility_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ziggurat", .module = core },
                .{ .name = "ziggurat_ui", .module = ui },
                .{ .name = "ziggurat_document", .module = document },
                .{ .name = "ziggurat_document_editor", .module = document_editor },
                .{ .name = "ziggurat_text_layout", .module = text_layout },
                .{ .name = "ziggurat_document_diff", .module = document_diff },
                .{ .name = "ziggurat_document_diff_view", .module = document_diff_view },
                .{ .name = "ziggurat_document_accessibility", .module = document_accessibility },
                .{ .name = "ziggurat_document_diff_accessibility", .module = document_diff_accessibility },
            },
        }) });
        for ([_][]const u8{ "tests/document_diff_accessibility_client.c", "tests/document_accessibility_client.c" }) |file| smoke_diff_accessibility.root_module.addCSourceFile(.{ .file = b.path(file), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        addResources(b, smoke_diff_accessibility);
        check.dependOn(&smoke_diff_accessibility.step);
        b.step("smoke-document-diff-accessibility", "Verify paired editable document text, presentation epochs and owner actions with real UIA").dependOn(&b.addRunArtifact(smoke_diff_accessibility).step);
    }
    if (target.result.os.tag == .windows or target.result.os.tag == .linux) {
        for ([_]struct { name: []const u8, source: []const u8, description: []const u8 }{
            .{ .name = "smoke-affine-document-diff", .source = "tests/document_diff_affine_smoke.zig", .description = "Verify shared committed affine coordinates for editable diff input and native geometry" },
            .{ .name = "smoke-affine-diff-controls", .source = "tests/document_diff_affine_controls_smoke.zig", .description = "Verify atomic affine diff text and typed controls with native geometry and actions" },
        }) |fixture| {
            const smoke_affine_diff = b.addExecutable(.{ .name = fixture.name, .root_module = b.createModule(.{
                .root_source_file = b.path(fixture.source),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "ziggurat", .module = core },
                    .{ .name = "ziggurat_ui", .module = ui },
                    .{ .name = "ziggurat_document", .module = document },
                    .{ .name = "ziggurat_document_editor", .module = document_editor },
                    .{ .name = "ziggurat_text_layout", .module = text_layout },
                    .{ .name = "ziggurat_document_diff", .module = document_diff },
                    .{ .name = "ziggurat_document_diff_view", .module = document_diff_view },
                    .{ .name = "ziggurat_document_accessibility", .module = document_accessibility },
                    .{ .name = "ziggurat_document_diff_accessibility", .module = document_diff_accessibility },
                },
            }) });
            if (target.result.os.tag == .windows) for ([_][]const u8{ "tests/document_diff_accessibility_client.c", "tests/document_accessibility_client.c" }) |file| smoke_affine_diff.root_module.addCSourceFile(.{ .file = b.path(file), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
            if (target.result.os.tag == .windows and std.mem.eql(u8, fixture.name, "smoke-affine-diff-controls")) smoke_affine_diff.root_module.addCSourceFile(.{ .file = b.path("tests/document_diff_affine_controls_probe.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
            addResources(b, smoke_affine_diff);
            check.dependOn(&smoke_affine_diff.step);
            const install = b.addInstallArtifact(smoke_affine_diff, .{});
            b.step(b.fmt("build-{s}", .{fixture.name}), "Build an affine diff integration executable without running it").dependOn(&install.step);
            b.step(fixture.name, fixture.description).dependOn(&b.addRunArtifact(smoke_affine_diff).step);
        }
    }
    code_editor.addImport("ziggurat", core);
    code_editor.addImport("ziggurat_document_editor", document_editor);
    code_editor.addImport("ziggurat_ui", ui);
    code_editor.addImport("ziggurat_text_layout", text_layout);
    if (target.result.os.tag == .windows or target.result.os.tag == .linux) {
        smokes.addDocumentSmokes(b, .{
            .target = target,
            .optimize = optimize,
            .core = core,
            .ui = ui,
            .text_layout = text_layout,
            .document = document,
            .document_editor = document_editor,
            .code_editor = code_editor,
            .language_protocol = language_protocol,
            .check = check,
            .protocol_server = protocol_server,
        });
    }
    if (target.result.os.tag == .windows or target.result.os.tag == .linux) {
        const code_editor_benchmark = b.addExecutable(.{ .name = "benchmark-code-editor", .root_module = b.createModule(.{
            .root_source_file = b.path("tools/code_editor_benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ziggurat", .module = core },
                .{ .name = "ziggurat_document", .module = document },
                .{ .name = "ziggurat_document_editor", .module = document_editor },
                .{ .name = "ziggurat_code_editor", .module = code_editor },
                .{ .name = "ziggurat_ui", .module = ui },
                .{ .name = "ziggurat_text_layout", .module = text_layout },
            },
        }) });
        addResources(b, code_editor_benchmark);
        b.step("benchmark-code-editor", "Measure explicit selection updates with retained diagnostics").dependOn(&b.addRunArtifact(code_editor_benchmark).step);
        const diff_view_benchmark = b.addExecutable(.{ .name = "benchmark-document-diff-view", .root_module = b.createModule(.{
            .root_source_file = b.path("tools/document_diff_view_benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ziggurat", .module = core },
                .{ .name = "ziggurat_document", .module = document },
                .{ .name = "ziggurat_document_diff", .module = document_diff },
                .{ .name = "ziggurat_document_editor", .module = document_editor },
                .{ .name = "ziggurat_document_diff_view", .module = document_diff_view },
                .{ .name = "ziggurat_ui", .module = ui },
                .{ .name = "ziggurat_text_layout", .module = text_layout },
            },
        }) });
        addResources(b, diff_view_benchmark);
        b.step("benchmark-document-diff-view", "Measure bounded diff viewport preparation and warm updates").dependOn(&b.addRunArtifact(diff_view_benchmark).step);
    }
    if (target.result.os.tag == .windows or target.result.os.tag == .linux) {
        smokes.addEditorSmokes(b, .{
            .core = core,
            .ui = ui,
            .text_layout = text_layout,
            .shaped_editor = shaped_editor,
            .target = target,
            .optimize = optimize,
            .document = document,
            .document_editor = document_editor,
            .code_editor = code_editor,
            .document_diff = document_diff,
            .document_diff_view = document_diff_view,
            .shadows = shadows,
            .vector = vector,
            .svg = svg,
            .gaussian = gaussian,
            .check = check,
            .virtual_list = virtual_list,
            .images = images,
            .image_drawing = image_drawing,
        });
    }
    // Browsers always build the WebGL2 renderer: the page falls back to
    // the software renderer where it has no WebGL2.
    ui_options.addOption(bool, "gpu", gpu or target.result.cpu.arch == .wasm32);
    if (target.result.os.tag == .linux) {
        const gradient_benchmark = b.addExecutable(.{ .name = "benchmark-gradients", .root_module = b.createModule(.{
            .root_source_file = b.path("tests/gradient_benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui } },
        }) });
        gradient_benchmark.root_module.addCSourceFile(.{ .file = b.path("tests/cairo_gradient_native_probe.c"), .flags = &.{"-std=c11"} });
        gradient_benchmark.root_module.linkSystemLibrary("cairo", .{ .use_pkg_config = .force });
        gradient_benchmark.root_module.link_libc = true;
        const run = b.addRunArtifact(gradient_benchmark);
        run.addPassthruArgs();
        b.step("benchmark-gradients", "Measure explicit software gradient replay costs").dependOn(&run.step);
    }
    ui_options.addOption(bool, "accessibility", accessibility);
    ui.addOptions("ziggurat_ui_options", ui_options);
    ui_platforms.addGpu(b, .{
        .gpu = gpu,
        .target = target,
        .ui = ui,
        .optimize = optimize,
        .core = core,
        .text_layout = text_layout,
        .check = check,
    });
    if (accessibility and target.result.os.tag == .macos) {
        _ = native_support.addArchive(b, ui, "ui-accessibility-native", "src/ui/accessibility_macos.m", &.{ "-fobjc-arc", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        native_support.linkFrameworks(b, ui, &.{ "AppKit", "Foundation" });
    } else if (accessibility and target.result.os.tag == .linux) {
        // ATK objects below the window's GTK accessible child host, which
        // GTK's bridge shows assistive technology through AT-SPI.
        const native = native_support.addArchive(b, ui, "ui-accessibility-native", "src/ui/accessibility_linux.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations" }, target, optimize);
        native.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        ui.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
    } else if (accessibility) {
        if (target.result.os.tag != .windows) @panic("UI Automation requires Windows; macOS uses NSAccessibility, Linux ATK");
        // An archive member is linked only by programs that reference UIA.
        _ = native_support.addArchive(b, ui, "ui-accessibility-native", "src/ui/accessibility.c", &.{"-std=c11"}, target, optimize);
        ui.linkSystemLibrary("uiautomationcore", .{});
        ui.linkSystemLibrary("oleaut32", .{});
    }
    if (target.result.os.tag == .windows) {
        _ = native_support.add(b, ui, "ui-composed-native", "src/ui/windows_composed.c", &.{"-std=c11"}, target, optimize);
        ui.linkSystemLibrary("gdi32", .{});
        ui.link_libc = true;
    }
    if (target.result.cpu.arch == .wasm32) {
        // Browsers: the software renderer draws in memory and the page shows
        // its frames; `web/` holds the page's side.
        _ = native_support.add(b, ui, "ui-web-native", "src/ui/web.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        // The Linux OpenGL renderer on the page's WebGL2 (src/ui/gl_web.h).
        _ = native_support.add(b, ui, "ui-gl-native", "src/ui/gl_renderer.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        ui.link_libc = true;
        addWebApp(b, addExample(b, "counter", "examples/counter.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_ui", .module = ui },
        }));
        addWebApp(b, addExample(b, "view-counter", "examples/view_counter.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_view", .module = declarative_view },
        }));
    }
    if (target.result.os.tag == .macos) {
        ui_platforms.addMacos(b, .{
            .ui = ui,
            .target = target,
            .optimize = optimize,
            .core = core,
            .declarative_view = declarative_view,
            .virtual_list = virtual_list,
            .system = system,
        });
    }
    if (target.result.os.tag == .linux) {
        ui_platforms.addLinux(b, .{
            .ui = ui,
            .target = target,
            .optimize = optimize,
            .check = check,
            .core = core,
            .declarative_view = declarative_view,
        });
    }
    if (target.result.os.tag == .windows) {
        ui_platforms.addWindows(b, .{
            .target = target,
            .optimize = optimize,
            .core = core,
            .ui = ui,
            .declarative_view = declarative_view,
            .document = document,
            .document_editor = document_editor,
            .text_layout = text_layout,
            .system = system,
            .accessibility = accessibility,
            .check = check,
            .gpu = gpu,
        });
    }
    if (web and target.result.os.tag != .windows and target.result.os.tag != .linux and target.result.os.tag != .macos)
        @panic("WebView currently requires Windows x86_64, Linux GTK3 or macOS");
    if (web and target.result.os.tag == .macos) {
        webview.addMacos(b, .{
            .target = target,
            .optimize = optimize,
            .core = core,
            .file_stream = file_stream,
            .http_response = http_response,
            .automation = automation,
            .tls_pem = tls_pem,
            .view_tests = &view_tests,
            .ui = ui,
            .declarative_view = declarative_view,
            .system = system,
        });
    }
    if (web and target.result.os.tag == .windows) {
        webview.addWindows(b, .{
            .target = target,
            .optimize = optimize,
            .core = core,
            .file_stream = file_stream,
            .http_response = http_response,
            .automation = automation,
            .tls_pem = tls_pem,
            .ipc = ipc,
            .resource_stream = resource_stream,
            .view_tests = &view_tests,
            .check = check,
            .https_resources_enabled = https_resources_enabled,
            .https_resources = https_resources,
            .native_stream = native_stream,
            .ui = ui,
            .initializer_native_run = &initializer_native_run,
            .assets = assets,
            .i18n = i18n,
            .page_runtime = page_runtime,
            .net = net,
            .plugin_fetch = plugin_fetch,
            .plugin_watch = plugin_watch,
            .plugin_sqlite = plugin_sqlite,
            .plugin_websocket = plugin_websocket,
            .declarative_view = declarative_view,
            .system = system,
        });
    }
    if (web and target.result.os.tag == .linux) {
        webview.addLinux(b, .{
            .target = target,
            .optimize = optimize,
            .core = core,
            .file_stream = file_stream,
            .http_response = http_response,
            .automation = automation,
            .tls_pem = tls_pem,
            .check = check,
            .webkit_file_run = &webkit_file_run,
            .view_tests = &view_tests,
            .ipc = ipc,
            .i18n = i18n,
            .page_runtime = page_runtime,
            .net = net,
            .plugin_fetch = plugin_fetch,
            .plugin_watch = plugin_watch,
            .plugin_sqlite = plugin_sqlite,
            .plugin_websocket = plugin_websocket,
            .ui = ui,
            .declarative_view = declarative_view,
            .test_step = test_step,
            .https_resources_enabled = https_resources_enabled,
            .https_resources = https_resources,
            .native_stream = native_stream,
            .system = system,
        });
    }
    const tests = addTest(b, .{ .root_module = core });
    const webkit_remote_tests = addTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("src/webview/webkit_remote.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat_http_response", .module = http_response }} }) });
    check.dependOn(&webkit_remote_tests.step);
    const run_webkit_remote = b.addRunArtifact(webkit_remote_tests);
    b.step("test-webkit-remote", "Run remote origin policy and owned native descriptor invariants").dependOn(&run_webkit_remote.step);
    const ipc_host = b.createModule(.{ .root_source_file = b.path("src/ipc/root.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    const resource_stream_host = b.createModule(.{ .root_source_file = b.path("src/resource_stream/root.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    const service_source = b.option([]const u8, "ipc-service", "Zig source exporting a Service type for TypeScript generation") orelse "examples/counter_service.zig";
    const service = b.createModule(.{ .root_source_file = sourcePath(b, service_source), .target = b.graph.host, .optimize = .ReleaseSafe, .imports = &.{ .{ .name = "ziggurat_ipc", .module = ipc_host }, .{ .name = "ziggurat_resource_stream", .module = resource_stream_host } } });
    const generator = b.addExecutable(.{ .name = "ipc-client-generator", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/ipc_client.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{ .{ .name = "ziggurat_ipc", .module = ipc_host }, .{ .name = "service", .module = service } },
    }) });
    const generated = b.addRunArtifact(generator);
    const client_source = generated.addOutputFileArg("client.ts");
    const install_client = b.addInstallFileWithDir(client_source, .prefix, "share/ziggurat/client.ts");
    b.step("ipc-client", "Generate the versioned TypeScript client from Zig service types").dependOn(&install_client.step);
    // Schemas only: the generator does not build Core for the host.
    const page_runtime_host = b.createModule(.{ .root_source_file = b.path("src/page_runtime/service.zig"), .target = b.graph.host, .optimize = .ReleaseSafe, .imports = &.{.{ .name = "ziggurat_ipc", .module = ipc_host }} });
    const plugin_fetch_host = b.createModule(.{ .root_source_file = b.path("src/page_runtime/plugins/fetch_service.zig"), .target = b.graph.host, .optimize = .ReleaseSafe, .imports = &.{.{ .name = "ziggurat_ipc", .module = ipc_host }} });
    const plugin_websocket_host = b.createModule(.{ .root_source_file = b.path("src/page_runtime/plugins/websocket_service.zig"), .target = b.graph.host, .optimize = .ReleaseSafe, .imports = &.{.{ .name = "ziggurat_ipc", .module = ipc_host }} });
    const plugin_watch_host = b.createModule(.{ .root_source_file = b.path("src/page_runtime/plugins/watch_service.zig"), .target = b.graph.host, .optimize = .ReleaseSafe, .imports = &.{.{ .name = "ziggurat_ipc", .module = ipc_host }} });
    const plugin_sqlite_host = b.createModule(.{ .root_source_file = b.path("src/page_runtime/plugins/sqlite_service.zig"), .target = b.graph.host, .optimize = .ReleaseSafe, .imports = &.{.{ .name = "ziggurat_ipc", .module = ipc_host }} });
    const page_runtime_clients = b.addExecutable(.{ .name = "page-runtime-clients", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/page_runtime_clients.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{
            .{ .name = "ziggurat_ipc", .module = ipc_host },
            .{ .name = "page_runtime_service", .module = page_runtime_host },
            .{ .name = "plugin_fetch_service", .module = plugin_fetch_host },
            .{ .name = "plugin_watch_service", .module = plugin_watch_host },
            .{ .name = "plugin_sqlite_service", .module = plugin_sqlite_host },
            .{ .name = "plugin_websocket_service", .module = plugin_websocket_host },
        },
    }) });
    const write_page_clients = b.addRunArtifact(page_runtime_clients);
    write_page_clients.addArg("write");
    write_page_clients.addDirectoryArg(b.path("."));
    b.step("page-runtime-clients", "Regenerate the TypeScript clients of the page runtime's services under packages/").dependOn(&write_page_clients.step);
    const check_page_clients = b.addRunArtifact(page_runtime_clients);
    check_page_clients.addArg("check");
    check_page_clients.addDirectoryArg(b.path("."));
    check_page_clients.addFileInput(b.path("packages/runtime/src/generated/runtime.ts"));
    check_page_clients.addFileInput(b.path("packages/plugin-fetch/src/generated/fetch.ts"));
    check_page_clients.addFileInput(b.path("packages/plugin-watch/src/generated/watch.ts"));
    check_page_clients.addFileInput(b.path("packages/plugin-sqlite/src/generated/sqlite.ts"));
    check_page_clients.addFileInput(b.path("packages/plugin-websocket/src/generated/websocket.ts"));
    test_step.dependOn(&check_page_clients.step);
    b.step("check-page-runtime-clients", "Fail when a generated page runtime client under packages/ differs from its Zig schema").dependOn(&check_page_clients.step);
    const ipc_tests = addTest(b, .{ .root_module = ipc });
    const ipc_fixture = b.createModule(.{ .root_source_file = b.path("src/ipc/fixture.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ipc", .module = ipc }} });
    const ipc_fixture_tests = addTest(b, .{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/ipc_fixture_check.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "ipc", .module = ipc }, .{ .name = "fixture", .module = ipc_fixture } },
    }) });
    const update_tests = addTest(b, .{ .root_module = update });
    b.step("test-update", "Run signed update, package, delta and publication tests").dependOn(&b.addRunArtifact(update_tests).step);
    const net_tests = addTest(b, .{ .root_module = net });
    const producer_service = b.createModule(.{ .root_source_file = b.path("tests/resource_producer_service.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ziggurat_ipc", .module = ipc }, .{ .name = "ziggurat_resource_stream", .module = resource_stream } } });
    const producer_fixture_tests = addTest(b, .{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/resource_producer_fixture_check.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "ziggurat_ipc", .module = ipc }, .{ .name = "producer_service", .module = producer_service } },
    }) });
    const asset_tests = addTest(b, .{ .root_module = assets });
    const extension_tests = addTest(b, .{ .root_module = extensions });
    const vector_tests = addTest(b, .{ .root_module = vector });
    const svg_tests = addTest(b, .{ .root_module = svg });
    const shadow_tests = addTest(b, .{ .root_module = shadows });
    const document_tests = addTest(b, .{ .root_module = document });
    const document_diff_tests = addTest(b, .{ .root_module = document_diff });
    const document_diff_view_tests = addTest(b, .{ .root_module = document_diff_view });
    const code_editor_tests = addTest(b, .{ .root_module = code_editor });
    const resource_stream_tests = addTest(b, .{ .root_module = resource_stream });
    const animation_tests = addTest(b, .{ .root_module = animation });
    const producer_tests = addTest(b, .{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/resource_stream/bridge.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_ipc", .module = ipc },
            .{ .name = "ziggurat_resource_stream", .module = resource_stream },
        },
    }) });
    const shell_test_module = b.createModule(.{ .root_source_file = b.path("src/system/shell.zig"), .target = target, .optimize = optimize, .link_libc = target.result.os.tag == .windows or target.result.os.tag == .linux });
    if (target.result.os.tag == .windows) {
        for ([_][]const u8{ "user32", "gdi32", "shell32", "ole32" }) |library| shell_test_module.linkSystemLibrary(library, .{});
    }
    const shell_tests = addTest(b, .{ .root_module = shell_test_module });
    const clipboard_tests = addTest(b, .{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/system/clipboard.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ziggurat", .module = core }},
    }) });
    const watch_tests = addTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("src/system/watch.zig"), .target = target, .optimize = optimize, .link_libc = target.result.os.tag == .windows }) });
    if (target.result.os.tag == .macos) native_support.linkFrameworks(b, watch_tests.root_module, &.{ "CoreServices", "CoreFoundation" });
    b.step("test-file-watch", "Run coarse file-watch unit tests").dependOn(&b.addRunArtifact(watch_tests).step);
    const menu_tests = addTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("src/system/menus.zig"), .target = target, .optimize = optimize }) });
    const system_extra_tests = addTest(b, .{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/system/extras_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ziggurat", .module = core }},
    }) });
    check.dependOn(&system_extra_tests.step);
    const run_system_extra_tests = b.addRunArtifact(system_extra_tests);
    test_step.dependOn(&run_system_extra_tests.step);
    b.step("test-system-extras", "Run application paths, menu role, role action, signal quit, jump list, recent document and relaunch tests").dependOn(&run_system_extra_tests.step);
    const system_tests = addTest(b, .{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/system_capabilities.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_system", .module = system } },
    }) });
    const update_tool = b.addExecutable(.{ .name = "ziggurat-update", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/update.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ziggurat_update", .module = update }},
    }) });
    addResources(b, update_tool);
    const install_update = b.addInstallArtifact(update_tool, .{});
    b.step("update-tool", "Build the optional signed-update tool").dependOn(&install_update.step);
    check.dependOn(&update_tool.step);
    const setup_format_module = b.createModule(.{ .root_source_file = b.path("tools/setup_format.zig"), .target = target, .optimize = optimize });
    const deb_module = b.createModule(.{ .root_source_file = b.path("tools/deb.zig"), .target = target, .optimize = optimize });
    const setup_module = b.createModule(.{
        .root_source_file = b.path("tools/setup.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "ziggurat_update", .module = update }, .{ .name = "setup_format", .module = setup_format_module } },
        .link_libc = target.result.os.tag == .windows,
    });
    if (target.result.os.tag == .windows) {
        setup_module.addCSourceFile(.{ .file = b.path("tools/setup_windows.c"), .flags = &.{"-std=c11"} });
        for ([_][]const u8{ "ole32", "shell32", "advapi32", "uuid" }) |library| setup_module.linkSystemLibrary(library, .{});
    }
    const setup_stub = b.addExecutable(.{ .name = "ziggurat-setup", .root_module = setup_module });
    addResources(b, setup_stub);
    const install_setup_stub = b.addInstallArtifact(setup_stub, .{});
    b.step("setup-stub", "Build the self-extracting setup, launcher and uninstaller stub").dependOn(&install_setup_stub.step);
    check.dependOn(&setup_stub.step);
    for ([_]*std.Build.Module{ setup_format_module, deb_module }) |module| {
        const module_tests = addTest(b, .{ .root_module = module });
        check.dependOn(&module_tests.step);
        test_step.dependOn(&b.addRunArtifact(module_tests).step);
    }
    // Setup smoke inputs: two fixture versions plus the stub and tools.
    const setup_smoke = b.step("build-setup-smoke", "Build fixtures for tests/setup_smoke.{ps1,sh}");
    for ([_][]const u8{ "1.0.0", "1.1.0" }) |fixture_version| {
        const fixture_options = b.addOptions();
        fixture_options.addOption([]const u8, "version", fixture_version);
        const fixture = b.addExecutable(.{ .name = b.fmt("setup-fixture-{s}", .{fixture_version}), .root_module = b.createModule(.{
            .root_source_file = b.path("tests/setup_fixture_app.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "setup_fixture_options", .module = fixture_options.createModule() }},
        }) });
        check.dependOn(&fixture.step);
        setup_smoke.dependOn(&b.addInstallArtifact(fixture, .{}).step);
    }
    setup_smoke.dependOn(&install_setup_stub.step);
    setup_smoke.dependOn(&install_update.step);
    const cli_options = b.addOptions();
    cli_options.addOptionPathDirectory("framework_root", b.path("."));
    const cli_module = b.createModule(.{
        .root_source_file = b.path("tools/cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggurat_update", .module = update },
            .{ .name = "cli_options", .module = cli_options.createModule() },
            .{ .name = "setup_format", .module = setup_format_module },
            .{ .name = "deb", .module = deb_module },
            .{ .name = "ziggurat_i18n", .module = i18n },
        },
    });
    const cli = b.addExecutable(.{ .name = "ziggurat", .root_module = cli_module });
    addResources(b, cli);
    const cli_step = b.step("cli", "Build the ziggurat init/dev/build/package/publish/generate/i18n/install-skills/doctor command and its setup stub");
    cli_step.dependOn(&b.addInstallArtifact(cli, .{}).step);
    cli_step.dependOn(&install_setup_stub.step);
    setup_smoke.dependOn(&b.addInstallArtifact(cli, .{}).step);
    check.dependOn(&cli.step);
    // LLVM, as release builds use: the Linux Debug self-hosted backend keeps
    // constants writable and hid a write to `std.Io.Reader.ending`.
    const cli_tests = addTest(b, .{ .root_module = cli_module, .use_llvm = true });
    check.dependOn(&cli_tests.step);
    const run_cli_tests = b.addRunArtifact(cli_tests);
    test_step.dependOn(&run_cli_tests.step);
    b.step("test-cli", "Run the ziggurat command's tests: templates, catalogs, S3 signing, install.sh and install.ps1, console output, icons, Windows signing, macOS bundles and disk image layout, and vet").dependOn(&run_cli_tests.step);
    // Measurement tools: apps' memory once idle, and how long input takes
    // to be painted.
    if (target.result.os.tag == .linux or target.result.os.tag == .windows) {
        const idle_memory_module = b.createModule(.{ .root_source_file = b.path("tools/idle_memory.zig"), .target = target, .optimize = optimize });
        const idle_memory = b.addExecutable(.{ .name = "idle-memory", .root_module = idle_memory_module });
        check.dependOn(&idle_memory.step);
        const idle_memory_run = b.addRunArtifact(idle_memory);
        idle_memory_run.addPassthruArgs();
        b.step("idle-memory", "Report apps' memory once idle, with the processes they run: zig build idle-memory -- [--count N] [--idle SECONDS] APP...").dependOn(&idle_memory_run.step);
        const input_latency_module = b.createModule(.{ .root_source_file = b.path("tools/input_latency.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_ui", .module = ui } } });
        const input_latency = b.addExecutable(.{ .name = "input-latency", .root_module = input_latency_module });
        addResources(b, input_latency);
        check.dependOn(&input_latency.step);
        const input_latency_install = b.addInstallArtifact(input_latency, .{});
        // Installed first: each run starts the installed tool again.
        const input_latency_run = runInstalled(b, b.graph.path(.install_bin, if (target.result.os.tag == .windows) "input-latency.exe" else "input-latency"));
        input_latency_run.step.dependOn(&input_latency_install.step);
        input_latency_run.addPassthruArgs();
        b.step("input-latency", "Measure how long typing, scrolling, dragging and animation take to be painted: zig build input-latency -- [--mode LIST] [--runs N] [--events N]").dependOn(&input_latency_run.step);
        const measurement_tests = b.step("test-measurement-tools", "Run the idle-memory and input-latency tools' tests");
        inline for (.{ idle_memory_module, input_latency_module }) |module| {
            const tool_tests = addTest(b, .{ .root_module = module });
            check.dependOn(&tool_tests.step);
            const run_tool_tests = b.addRunArtifact(tool_tests);
            measurement_tests.dependOn(&run_tool_tests.step);
            test_step.dependOn(&run_tool_tests.step);
        }
    }
    // The accessors `ziggurat generate` writes compile against the module.
    const i18n_host = b.createModule(.{ .root_source_file = b.path("src/i18n/root.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    const catalog_generator = b.addExecutable(.{ .name = "i18n-catalog", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/i18n_catalog.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "ziggurat_i18n", .module = i18n_host }},
    }) });
    // Checked directly too, which also lets the shared modules reach it.
    check.dependOn(&catalog_generator.step);
    const generate_catalog = b.addRunArtifact(catalog_generator);
    generate_catalog.addDirectoryArg(b.path("tests/i18n_fixture"));
    const fixture_catalog = generate_catalog.addOutputFileArg("catalog.zig");
    const generated_catalog_tests = addTest(b, .{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/i18n_generated_check.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggurat_i18n", .module = i18n },
            .{ .name = "fixture_catalog", .module = b.createModule(.{ .root_source_file = fixture_catalog, .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat_i18n", .module = i18n }} }) },
        },
    }) });
    check.dependOn(&generated_catalog_tests.step);
    const run_generated_catalog_tests = b.addRunArtifact(generated_catalog_tests);
    test_step.dependOn(&run_generated_catalog_tests.step);
    b.step("test-i18n-generated", "Compile and run the Zig accessors generated from tests/i18n_fixture").dependOn(&run_generated_catalog_tests.step);
    const assets_host = b.createModule(.{ .root_source_file = b.path("src/assets/root.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    const asset_generator = b.addExecutable(.{ .name = "web-assets-generator", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/web_assets.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "ziggurat_assets", .module = assets_host }},
    }) });
    const asset_input = b.option([]const u8, "web-assets", "Built frontend directory to embed") orelse "tests/assets_fixture";
    const asset_entry = b.option([]const u8, "web-entry", "Embedded frontend entry URL path") orelse "/index.html";
    const generate_assets = b.addRunArtifact(asset_generator);
    generate_assets.addDirectoryArg(sourcePath(b, asset_input));
    const asset_output = generate_assets.addOutputDirectoryArg("web-assets");
    generate_assets.addArg(asset_entry);
    const install_assets = b.addInstallDirectory(.{ .source_dir = asset_output, .install_dir = .prefix, .install_subdir = "share/ziggurat/web-assets" });
    b.step("web-assets", "Embed a built frontend as content-addressed Zig resources").dependOn(&install_assets.step);
    const embedded = b.createModule(.{ .root_source_file = asset_output.path(b, "assets.zig"), .target = target, .optimize = optimize });
    const embed_probe = b.addExecutable(.{ .name = "assets-embed-probe", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/assets_embed_probe.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "web_assets", .module = embedded }},
    }) });
    const packaging_tests = addTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("build_support/packaging.zig"), .target = target, .optimize = optimize }) });
    const platform_probe = b.addExecutable(.{
        .name = "platform-check",
        .root_module = b.createModule(.{ .root_source_file = b.path("tests/platform_check.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat", .module = core }} }),
    });
    check.dependOn(&platform_probe.step);
    check.dependOn(&tests.step);
    check.dependOn(&ipc_tests.step);
    check.dependOn(&ipc_fixture_tests.step);
    check.dependOn(&producer_fixture_tests.step);
    check.dependOn(&update_tests.step);
    check.dependOn(&net_tests.step);
    check.dependOn(&asset_tests.step);
    check.dependOn(&extension_tests.step);
    check.dependOn(&vector_tests.step);
    check.dependOn(&svg_tests.step);
    check.dependOn(&shadow_tests.step);
    check.dependOn(&document_tests.step);
    check.dependOn(&document_diff_tests.step);
    check.dependOn(&document_diff_view_tests.step);
    check.dependOn(&code_editor_tests.step);
    check.dependOn(&resource_stream_tests.step);
    check.dependOn(&animation_tests.step);
    check.dependOn(&producer_tests.step);
    check.dependOn(&shell_tests.step);
    check.dependOn(&watch_tests.step);
    check.dependOn(&menu_tests.step);
    check.dependOn(&system_tests.step);
    check.dependOn(&system_unit_tests.step);
    check.dependOn(&clipboard_tests.step);
    check.dependOn(&embed_probe.step);
    check.dependOn(&packaging_tests.step);
    const run_tests = b.addRunArtifact(tests);
    b.step("test-core", "Run core lifecycle and composition invariant tests").dependOn(&run_tests.step);
    test_step.dependOn(&run_runtime_tests.step);
    test_step.dependOn(&run_file_stream_tests.step);
    const https_resources_tests = addTest(b, .{ .root_module = https_resources });
    const run_https_resources_tests = b.addRunArtifact(https_resources_tests);
    check.dependOn(&https_resources_tests.step);
    test_step.dependOn(&run_https_resources_tests.step);
    b.step("test-https-resources", "Verify optional HTTPS resource admission, limits and cold capability rejection").dependOn(&run_https_resources_tests.step);
    const site_routes_tests = addTest(b, .{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/https_resources/site_routes.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ziggurat_http_response", .module = http_response }},
    }) });
    const run_site_routes_tests = b.addRunArtifact(site_routes_tests);
    check.dependOn(&site_routes_tests.step);
    test_step.dependOn(&run_site_routes_tests.step);
    b.step("test-https-site-routes", "Run owned HTTPS route, static response and explicit header policy contracts").dependOn(&run_site_routes_tests.step);
    const http_response_tests = addTest(b, .{ .root_module = http_response });
    const run_http_response_tests = b.addRunArtifact(http_response_tests);
    check.dependOn(&http_response_tests.step);
    test_step.dependOn(&run_http_response_tests.step);
    b.step("test-http-response", "Verify shared HTTP response validation and owned metadata without a browser or server").dependOn(&run_http_response_tests.step);
    const caret_tests = addTest(b, .{ .root_module = caret });
    const run_caret_tests = b.addRunArtifact(caret_tests);
    check.dependOn(&caret_tests.step);
    test_step.dependOn(&run_caret_tests.step);
    b.step("test-caret", "Verify bounded visual caret geometry independently of shaping and native rendering").dependOn(&run_caret_tests.step);
    const gaussian_tests = addTest(b, .{ .root_module = gaussian });
    const run_gaussian_tests = b.addRunArtifact(gaussian_tests);
    check.dependOn(&gaussian_tests.step);
    test_step.dependOn(&run_gaussian_tests.step);
    b.step("test-gaussian", "Verify bounded composed-image Gaussian preparation, worker handoff and resource leases").dependOn(&run_gaussian_tests.step);
    const profile_storage_module = b.createModule(.{ .root_source_file = b.path("src/webview/profile_storage.zig"), .target = target, .optimize = optimize, .link_libc = target.result.os.tag == .windows });
    if (target.result.os.tag == .windows) addWindowsProfileStorageNative(b, profile_storage_module, "profile-storage-test", target, optimize);
    const profile_storage_tests = addTest(b, .{ .root_module = profile_storage_module });
    const run_profile_storage_tests = b.addRunArtifact(profile_storage_tests);
    check.dependOn(&profile_storage_tests.step);
    test_step.dependOn(&run_profile_storage_tests.step);
    b.step("test-profile-storage", "Verify private profile preparation metadata, handoff and ownership without an engine").dependOn(&run_profile_storage_tests.step);
    const profile_tls_tests = addTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("src/webview/profile_tls_policy.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat_tls_pem", .module = tls_pem }} }) });
    const run_profile_tls_tests = b.addRunArtifact(profile_tls_tests);
    check.dependOn(&profile_tls_tests.step);
    test_step.dependOn(&run_profile_tls_tests.step);
    b.step("test-profile-tls", "Verify bounded certificate-only profile policy without TLS or an engine").dependOn(&run_profile_tls_tests.step);
    const pem_tests = addTest(b, .{ .root_module = tls_pem });
    const run_pem_tests = b.addRunArtifact(pem_tests);
    check.dependOn(&pem_tests.step);
    test_step.dependOn(&run_pem_tests.step);
    b.step("test-tls-pem", "Verify bounded shared certificate and private-key framing without native TLS").dependOn(&run_pem_tests.step);
    const cookies_tests = addTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("src/webview/cookies.zig"), .target = target, .optimize = optimize }) });
    const run_cookies_tests = b.addRunArtifact(cookies_tests);
    check.dependOn(&cookies_tests.step);
    test_step.dependOn(&run_cookies_tests.step);
    b.step("test-cookies", "Verify cookie identity, owned result batches and bounded operation tokens without an engine").dependOn(&run_cookies_tests.step);
    const content_rules_tests = addTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("src/webview/content_rules.zig"), .target = target, .optimize = optimize }) });
    const run_content_rules_tests = b.addRunArtifact(content_rules_tests);
    check.dependOn(&content_rules_tests.step);
    test_step.dependOn(&run_content_rules_tests.step);
    b.step("test-content-rules", "Verify content rule parsing, WebKit regular expressions, public suffixes and hiding scripts without an engine").dependOn(&run_content_rules_tests.step);
    if (target.result.os.tag == .linux) {
        const file_tests = addTest(b, .{ .root_module = b.createModule(.{
            .root_source_file = b.path("tests/profile_storage_linux.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "profile_storage", .module = profile_storage_module }},
        }) });
        check.dependOn(&file_tests.step);
        b.step("test-profile-storage-files", "Verify opt-in Linux profile locks, private paths and physical descriptor lifetime").dependOn(&b.addRunArtifact(file_tests).step);
    }
    if (webkit_file_run) |run| test_step.dependOn(&run.step);
    if (initializer_native_run) |run| test_step.dependOn(&run.step);
    const language_protocol_tests = addTest(b, .{ .root_module = language_protocol });
    const run_language_protocol_tests = b.addRunArtifact(language_protocol_tests);
    check.dependOn(&language_protocol_tests.step);
    test_step.dependOn(&run_language_protocol_tests.step);
    b.step("test-language-protocol", "Verify bounded framing, versioned synchronization and explicit language client ownership").dependOn(&run_language_protocol_tests.step);
    const window_placement_tests = addTest(b, .{ .root_module = window_placement });
    const run_window_placement_tests = b.addRunArtifact(window_placement_tests);
    check.dependOn(&window_placement_tests.step);
    test_step.dependOn(&run_window_placement_tests.step);
    b.step("test-window-placement", "Run monitor placement, versioned encoding and explicit worker storage invariants").dependOn(&run_window_placement_tests.step);
    const document_app_tests = addTest(b, .{ .root_module = document_app });
    const run_document_app_tests = b.addRunArtifact(document_app_tests);
    check.dependOn(&document_app_tests.step);
    test_step.dependOn(&run_document_app_tests.step);
    b.step("test-document-app", "Run document identity, close preflight, atomic save, autosave and recovery invariants").dependOn(&run_document_app_tests.step);
    const updater = b.addModule("ziggurat_updater", .{ .root_source_file = b.path("src/updater/root.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_view", .module = declarative_view },
        .{ .name = "ziggurat_update", .module = update },
        .{ .name = "ziggurat_wake", .module = wake },
        .{ .name = "ziggurat_markdown", .module = markdown },
        .{ .name = "ziggurat_markdown_view", .module = markdown_view },
    } });
    const updater_tests = addTest(b, .{ .root_module = updater });
    const run_updater_tests = b.addRunArtifact(updater_tests);
    check.dependOn(&updater_tests.step);
    test_step.dependOn(&run_updater_tests.step);
    b.step("test-updater", "Run update window sessions, choices, texts and feed backend tests").dependOn(&run_updater_tests.step);
    if (target.result.cpu.arch == .wasm32) {
        // What tests/web/smoke.py drives in headless Chromium; it also checks
        // the context menu, and what single instance, the updater and window
        // placement do there.
        addWebApp(b, addExample(b, "browser-smoke", "tests/web/smoke_app.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_view", .module = declarative_view },
            .{ .name = "ziggurat_system", .module = system },
            .{ .name = "ziggurat_updater", .module = updater },
            .{ .name = "ziggurat_window_placement", .module = window_placement },
            .{ .name = "ziggurat_ui", .module = ui },
        }));
    }
    test_step.dependOn(&run_webkit_remote.step);
    const audio = b.addModule("ziggurat_audio", .{ .root_source_file = b.path("src/audio/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat", .module = core }} });
    audio.link_libc = true;
    if (target.result.os.tag == .windows) audio.linkSystemLibrary("ole32", .{});
    if (target.result.os.tag == .macos) native_support.linkFrameworks(b, audio, &.{"AudioToolbox"});
    // Pinned third-party decoders: their own warnings and undefined-behavior
    // checks are not this project's to enforce.
    for ([_][]const u8{ "mp3", "vorbis" }) |codec| _ = native_support.add(b, audio, b.fmt("audio-{s}-native", .{codec}), b.fmt("src/audio/{s}.c", .{codec}), if (target.result.cpu.arch == .wasm32) &.{ "-std=c99", "-w", "-fno-sanitize=undefined", "-Dalloca=__builtin_alloca" } else &.{ "-std=c99", "-w", "-fno-sanitize=undefined" }, target, optimize);
    const audio_tests = addTest(b, .{ .root_module = audio });
    const run_audio_tests = b.addRunArtifact(audio_tests);
    check.dependOn(&audio_tests.step);
    test_step.dependOn(&run_audio_tests.step);
    b.step("test-audio", "Run WAV/FLAC decoding, mixing, player, stream, notification and test-backend output invariants").dependOn(&run_audio_tests.step);
    addSmoke(b, "smoke-audio", "tests/audio_smoke.zig", target, optimize, &.{.{ .name = "ziggurat_audio", .module = audio }});
    const terminal = b.addModule("ziggurat_terminal", .{ .root_source_file = b.path("src/terminal/root.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_png", .module = png } } });
    terminal.link_libc = true;
    const terminal_tests = addTest(b, .{ .root_module = terminal });
    const run_terminal_tests = b.addRunArtifact(terminal_tests);
    check.dependOn(&terminal_tests.step);
    test_step.dependOn(&run_terminal_tests.step);
    const terminal_view = b.addModule("ziggurat_terminal_view", .{ .root_source_file = b.path("src/terminal/view.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },                  .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_view", .module = declarative_view }, .{ .name = "ziggurat_terminal", .module = terminal },
    } });
    const terminal_view_tests = addTest(b, .{ .root_module = terminal_view });
    const run_terminal_view_tests = b.addRunArtifact(terminal_view_tests);
    check.dependOn(&terminal_view_tests.step);
    test_step.dependOn(&run_terminal_view_tests.step);
    const test_terminal = b.step("test-terminal", "Run escape sequence parsing, screen, scrollback, key and mouse encoding, selection, link, PTY session and terminal view tests");
    test_terminal.dependOn(&run_terminal_tests.step);
    test_terminal.dependOn(&run_terminal_view_tests.step);
    if (target.result.os.tag == .windows or target.result.os.tag == .linux) addSmoke(b, "smoke-terminal", "tests/terminal_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_view", .module = declarative_view },
        .{ .name = "ziggurat_terminal", .module = terminal },
        .{ .name = "ziggurat_terminal_view", .module = terminal_view },
    });
    const snippets_tests = addTest(b, .{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/code_editor/snippet.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_document", .module = document },
            .{ .name = "ziggurat_document_editor", .module = document_editor },
        },
    }) });
    check.dependOn(&snippets_tests.step);
    b.step("test-snippets", "Run bounded snippet parsing and document session invariants").dependOn(&b.addRunArtifact(snippets_tests).step);
    const document_accessibility_tests = addTest(b, .{ .root_module = document_accessibility });
    const run_document_accessibility_tests = b.addRunArtifact(document_accessibility_tests);
    test_step.dependOn(&run_document_accessibility_tests.step);
    check.dependOn(&document_accessibility_tests.step);
    b.step("test-document-accessibility", "Run complete document text snapshot and ownership invariants").dependOn(&run_document_accessibility_tests.step);
    const diff_accessibility_tests = addTest(b, .{ .root_module = document_diff_accessibility });
    const run_diff_accessibility_tests = b.addRunArtifact(diff_accessibility_tests);
    test_step.dependOn(&run_diff_accessibility_tests.step);
    check.dependOn(&diff_accessibility_tests.step);
    b.step("test-document-diff-accessibility", "Verify optional paired document accessibility ownership and presentation gates").dependOn(&run_diff_accessibility_tests.step);
    inline for (.{
        .{ "test-affine", "affine", "src/ui/affine.zig", "tests/ui_affine.zig" },
        .{ "test-affine-state", "affine_state", "src/ui/affine_state.zig", "tests/ui_affine_state.zig" },
    }) |entry| {
        const math_module = b.createModule(.{ .root_source_file = b.path(entry[2]), .target = target, .optimize = optimize });
        const math_tests = addTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path(entry[3]), .target = target, .optimize = optimize, .imports = &.{.{ .name = entry[1], .module = math_module }} }) });
        const run_math_tests = b.addRunArtifact(math_tests);
        test_step.dependOn(&run_math_tests.step);
        check.dependOn(&math_tests.step);
        b.step(entry[0], "Run pure coordinate and committed-frame geometry invariants").dependOn(&run_math_tests.step);
    }
    const code_syntax_tests = addTest(b, .{ .root_module = code_syntax });
    const run_code_syntax_tests = b.addRunArtifact(code_syntax_tests);
    test_step.dependOn(&run_code_syntax_tests.step);
    check.dependOn(&code_syntax_tests.step);
    b.step("test-code-syntax", "Run lexer, language, theme, incremental highlighting, bracket and word search tests").dependOn(&run_code_syntax_tests.step);
    const run_code_editor_tests = b.addRunArtifact(code_editor_tests);
    test_step.dependOn(&run_code_editor_tests.step);
    b.step("test-code-editor", "Run revisioned editor services and ownership tests").dependOn(&run_code_editor_tests.step);
    const run_resource_stream_tests = b.addRunArtifact(resource_stream_tests);
    test_step.dependOn(&run_resource_stream_tests.step);
    b.step("test-resource-stream", "Run bounded byte producer, protocol credit and ownership tests").dependOn(&run_resource_stream_tests.step);
    const run_animation_tests = b.addRunArtifact(animation_tests);
    test_step.dependOn(&run_animation_tests.step);
    b.step("test-animation", "Run explicit-clock motion, timeline and wake invariant tests").dependOn(&run_animation_tests.step);
    const run_producer_tests = b.addRunArtifact(producer_tests);
    test_step.dependOn(&run_producer_tests.step);
    const producer_test_step = b.step("test-resource-producer", "Run page producer bridge ownership, schema and reentry tests without a Runtime");
    producer_test_step.dependOn(&run_producer_tests.step);
    const run_producer_fixture_tests = b.addRunArtifact(producer_fixture_tests);
    test_step.dependOn(&run_producer_fixture_tests.step);
    producer_test_step.dependOn(&run_producer_fixture_tests.step);
    const initializer_test_step = b.step("test-document-initializers", "Run owned document initializer and replacement responsibility contracts without a Runtime");
    for ([_][]const u8{ "src/webview/document_initializers.zig", "src/webview/initializer_transaction.zig" }) |source| {
        const initializer_tests = addTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path(source), .target = target, .optimize = optimize }) });
        const run_initializer_tests = b.addRunArtifact(initializer_tests);
        test_step.dependOn(&run_initializer_tests.step);
        check.dependOn(&initializer_tests.step);
        initializer_test_step.dependOn(&run_initializer_tests.step);
    }
    const initializer_source = b.createModule(.{ .root_source_file = b.path("src/webview/document_initializers.zig"), .target = target, .optimize = optimize });
    const initializer_emitter = b.addExecutable(.{ .name = "initializer-semantics-source", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/document_initializers_emit.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ziggurat_document_initializers", .module = initializer_source }},
    }) });
    check.dependOn(&initializer_emitter.step);
    const initializer_emitter_install = b.addInstallArtifact(initializer_emitter, .{});
    b.step("build-initializer-semantics-emitter", "Build the pure encoded initializer source for the explicit JavaScript VM oracle").dependOn(&initializer_emitter_install.step);
    if (view_tests) |selected| {
        check.dependOn(&selected.step);
        const run_view_tests = b.addRunArtifact(selected);
        test_step.dependOn(&run_view_tests.step);
        b.step("test-webview", "Run page policies, requests and session ownership tests").dependOn(&run_view_tests.step);
    }
    test_step.dependOn(&run_tests.step);
    const run_ipc_tests = b.addRunArtifact(ipc_tests);
    test_step.dependOn(&run_ipc_tests.step);
    b.step("test-ipc", "Run typed protocol, event and allocator reentry tests").dependOn(&run_ipc_tests.step);
    test_step.dependOn(&b.addRunArtifact(ipc_fixture_tests).step);
    test_step.dependOn(&b.addRunArtifact(update_tests).step);
    const run_net_tests = b.addRunArtifact(net_tests);
    test_step.dependOn(&run_net_tests.step);
    b.step("test-net", "Run fetch and WebSocket client tests against local servers").dependOn(&run_net_tests.step);
    const net_tls_probe = b.addExecutable(.{ .name = "net-tls-probe", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/net_tls_probe.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ziggurat_net", .module = net }},
    }) });
    check.dependOn(&net_tls_probe.step);
    b.step("install-net-tls-probe", "Install the real TLS fetch/WebSocket probe; run it with scripts/net-tls-probe.sh").dependOn(&b.addInstallArtifact(net_tls_probe, .{}).step);
    test_step.dependOn(&b.addRunArtifact(asset_tests).step);
    test_step.dependOn(&b.addRunArtifact(extension_tests).step);
    const run_vector_tests = b.addRunArtifact(vector_tests);
    test_step.dependOn(&run_vector_tests.step);
    b.step("test-vector", "Run bounded path geometry and coverage tests").dependOn(&run_vector_tests.step);
    const run_svg_tests = b.addRunArtifact(svg_tests);
    test_step.dependOn(&run_svg_tests.step);
    b.step("test-svg", "Run bounded SVG document and rendering tests").dependOn(&run_svg_tests.step);
    test_step.dependOn(&b.addRunArtifact(shadow_tests).step);
    const run_document_tests = b.addRunArtifact(document_tests);
    test_step.dependOn(&run_document_tests.step);
    b.step("test-document", "Run indexed document and snapshot invariant tests").dependOn(&run_document_tests.step);
    const run_document_diff_tests = b.addRunArtifact(document_diff_tests);
    test_step.dependOn(&run_document_diff_tests.step);
    b.step("test-document-diff", "Run bounded snapshot comparison and minimal edit invariants").dependOn(&run_document_diff_tests.step);
    const run_document_diff_view_tests = b.addRunArtifact(document_diff_view_tests);
    test_step.dependOn(&run_document_diff_view_tests.step);
    b.step("test-document-diff-view", "Run paired snapshot delivery and aligned diff view invariants").dependOn(&run_document_diff_view_tests.step);
    test_step.dependOn(&b.addRunArtifact(shell_tests).step);
    const run_system_tests = b.addRunArtifact(system_tests);
    const run_clipboard_tests = b.addRunArtifact(clipboard_tests);
    test_step.dependOn(&run_clipboard_tests.step);
    const system_test_step = b.step("test-system", "Run system module capability, convention and unsupported-path tests");
    system_test_step.dependOn(&run_system_tests.step);
    system_test_step.dependOn(&run_clipboard_tests.step);
    test_step.dependOn(&b.addRunArtifact(watch_tests).step);
    test_step.dependOn(&b.addRunArtifact(menu_tests).step);
    test_step.dependOn(&run_system_tests.step);
    const run_system_unit_tests = b.addRunArtifact(system_unit_tests);
    test_step.dependOn(&run_system_unit_tests.step);
    b.step("test-system-integration", "Run single-instance framing, identity, registration and power unit tests").dependOn(&run_system_unit_tests.step);
    test_step.dependOn(&b.addRunArtifact(embed_probe).step);
    test_step.dependOn(&b.addRunArtifact(packaging_tests).step);
    // The system's media engines, on Windows and macOS as on Linux.
    if (target.result.cpu.arch != .wasm32) {
        const system_video_tests = addTest(b, .{ .root_module = system_video });
        check.dependOn(&system_video_tests.step);
        const run_system_video_tests = b.addRunArtifact(system_video_tests);
        test_step.dependOn(&run_system_video_tests.step);
        b.step("test-video", "Play a clip with the system's media engine: frames in order, its end, seeks (skips without an engine)").dependOn(&run_system_video_tests.step);
    }
    const chart_view = b.addModule("ziggurat_chart_view", .{ .root_source_file = b.path("src/chart/view.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },                  .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_view", .module = declarative_view }, .{ .name = "ziggurat_vector", .module = vector },
        .{ .name = "ziggurat_chart", .module = chart },
    } });
    if (target.result.os.tag == .windows or target.result.os.tag == .linux) {
        smokes.addUiTests(b, .{
            .ui = ui,
            .check = check,
            .test_step = test_step,
            .target = target,
            .optimize = optimize,
            .core = core,
            .text_layout = text_layout,
            .drawing_resources = drawing_resources,
            .gif = gif,
            .png = png,
            .apng = apng,
            .images = images,
            .image_drawing = image_drawing,
            .shaped_editor = shaped_editor,
            .document_editor = document_editor,
            .virtual_list = virtual_list,
            .declarative_view = declarative_view,
            .markdown_view = markdown_view,
            .chart_view = chart_view,
            .view_video = view_video,
            .view_graphics = view_graphics,
            .i18n = i18n,
            .chart = chart,
        });
    }
    if (target.result.os.tag == .windows or target.result.os.tag == .linux or target.result.os.tag == .macos or target.result.cpu.arch == .wasm32) {
        const game = b.addModule("ziggurat_game", .{ .root_source_file = b.path("src/game/root.zig"), .target = target, .optimize = optimize, .imports = &.{
            .{ .name = "ziggurat", .module = core },                  .{ .name = "ziggurat_ui", .module = ui },
            .{ .name = "ziggurat_view", .module = declarative_view },
        } });
        if (target.result.os.tag == .macos) {
            _ = native_support.add(b, game, "game-gamepad-macos", "src/game/gamepad_macos.m", &.{ "-fno-objc-arc", "-Wall", "-Wextra", "-Werror" }, target, optimize);
            native_support.linkFrameworks(b, game, &.{ "GameController", "Foundation" });
            game.linkSystemLibrary("objc", .{ .use_pkg_config = .no });
        }
        const game_tests = addTest(b, .{ .root_module = game });
        check.dependOn(&game_tests.step);
        const run_game_tests = b.addRunArtifact(game_tests);
        test_step.dependOn(&run_game_tests.step);
        b.step("test-game", "Run game loop, camera, scaling and gamepad tests").dependOn(&run_game_tests.step);
    }
    const rich_text = b.addModule("ziggurat_rich_text", .{ .root_source_file = b.path("src/rich_text/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat_markdown", .module = markdown }} });
    const rich_text_tests = addTest(b, .{ .root_module = rich_text });
    const run_rich_text_tests = b.addRunArtifact(rich_text_tests);
    check.dependOn(&rich_text_tests.step);
    test_step.dependOn(&run_rich_text_tests.step);
    const test_rich_text = b.step("test-rich-text", "Run attributed text, document, undo, HTML, RTF, Markdown and clipboard codec tests");
    test_rich_text.dependOn(&run_rich_text_tests.step);
    const rich_text_editor = b.addModule("ziggurat_rich_text_editor", .{ .root_source_file = b.path("src/rich_text/editor.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },                  .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_view", .module = declarative_view }, .{ .name = "ziggurat_rich_text", .module = rich_text },
    } });
    const rich_text_editor_tests = addTest(b, .{ .root_module = rich_text_editor });
    const run_rich_text_editor_tests = b.addRunArtifact(rich_text_editor_tests);
    check.dependOn(&rich_text_editor_tests.step);
    test_step.dependOn(&run_rich_text_editor_tests.step);
    test_rich_text.dependOn(&run_rich_text_editor_tests.step);
    _ = b.addModule("ziggurat_rich_text_clipboard", .{ .root_source_file = b.path("src/rich_text/clipboard.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat_rich_text", .module = rich_text }, .{ .name = "ziggurat_rich_text_editor", .module = rich_text_editor },
        .{ .name = "ziggurat_system", .module = system },
    } });
    const text_measure = b.addModule("ziggurat_text_measure", .{ .root_source_file = b.path("src/text_measure/root.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat_view", .module = declarative_view }, .{ .name = "ziggurat_text_layout", .module = text_layout },
    } });
    ui.addImport("ziggurat_fonts", fonts);
    text_layout.addImport("ziggurat_fonts", fonts);
    text_measure.addImport("ziggurat_fonts", fonts);
    if (target.result.os.tag == .windows or target.result.os.tag == .linux or target.result.os.tag == .macos) addSmoke(b, "smoke-text-measure", "tests/text_measure_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat_view", .module = declarative_view }, .{ .name = "ziggurat_text_measure", .module = text_measure },
    });
    rich_text_editor.addImport("ziggurat_fonts", fonts);
    const fonts_tests = addTest(b, .{ .root_module = fonts });
    const run_fonts_tests = b.addRunArtifact(fonts_tests);
    check.dependOn(&fonts_tests.step);
    test_step.dependOn(&run_fonts_tests.step);
    b.step("test-fonts", "Run font family and registration tests").dependOn(&run_fonts_tests.step);
    if (target.result.os.tag == .windows or target.result.os.tag == .linux) addSmoke(b, "smoke-fonts", "tests/fonts_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat_fonts", .module = fonts }, .{ .name = "ziggurat_text_layout", .module = text_layout },
    });
    addExamples(b, target, optimize);
    shareCommonModules(b, target, optimize, check, test_step);
    useWindowsSelfHostedBackend(b, b.option(bool, "windows-llvm", "Build Windows Debug artifacts with the LLVM backend instead of Zig's self-hosted backend") orelse false);
}
