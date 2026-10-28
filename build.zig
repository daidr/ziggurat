const std = @import("std");
pub const packaging = @import("build_support/packaging.zig");
const native_support = @import("build_support/native.zig");

pub fn build(b: *std.Build) void {
    b.installFile("LICENSE", "share/ziggurat/LICENSE");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const web = b.option(bool, "webview", "Build the optional system WebView (Windows SDK or Linux WebKitGTK)") orelse false;
    const https_resources_enabled = b.option(bool, "https-resources", "Build the optional HTTPS resource transport on Windows or Linux") orelse false;
    const gpu = b.option(bool, "gpu", "Build the optional D3D11 renderer with GDI fallback") orelse false;
    const webp = b.option(bool, "webp", "Build the optional pinned WebP decoder (fetch source first)") orelse false;
    const accessibility = b.option(bool, "accessibility", "Build the optional Windows UI Automation bridge") orelse false;
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
    const classifier_tests = b.addTest(.{ .root_module = pointer_classifier });
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
    const runtime_tests = b.addTest(.{ .root_module = webview_runtime });
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
        const native_tests = b.addTest(.{ .root_module = b.createModule(.{
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
        const transport_tests = b.addTest(.{ .root_module = b.createModule(.{
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
    const file_stream_tests = b.addTest(.{ .root_module = file_stream });
    const run_file_stream_tests = b.addRunArtifact(file_stream_tests);
    check.dependOn(&file_stream_tests.step);
    b.step("test-file-stream", "Verify consumer-neutral file preparation, cancellation and ownership contracts").dependOn(&run_file_stream_tests.step);
    const native_stream_tests = b.addTest(.{ .root_module = native_stream });
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
        const native_tests = b.addTest(.{ .root_module = b.createModule(.{
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
    const i18n_tests = b.addTest(.{ .root_module = i18n });
    check.dependOn(&i18n_tests.step);
    const run_i18n_tests = b.addRunArtifact(i18n_tests);
    test_step.dependOn(&run_i18n_tests.step);
    b.step("test-i18n", "Run locale fallback, catalog, plural, number, date and pseudolocale tests").dependOn(&run_i18n_tests.step);
    const page_runtime = b.addModule("ziggurat_page_runtime", .{ .root_source_file = b.path("src/page_runtime/root.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ipc", .module = ipc },
        .{ .name = "ziggurat_i18n", .module = i18n },
    } });
    const page_runtime_tests = b.addTest(.{ .root_module = page_runtime });
    check.dependOn(&page_runtime_tests.step);
    const run_page_runtime_tests = b.addRunArtifact(page_runtime_tests);
    test_step.dependOn(&run_page_runtime_tests.step);
    b.step("test-page-runtime", "Run page handshake, runtime service, plugin routing, find script and plugin manifest tests").dependOn(&run_page_runtime_tests.step);
    const markdown = b.addModule("ziggurat_markdown", .{ .root_source_file = b.path("src/markdown/root.zig"), .target = target, .optimize = optimize });
    const markdown_tests = b.addTest(.{ .root_module = markdown });
    check.dependOn(&markdown_tests.step);
    const run_markdown_tests = b.addRunArtifact(markdown_tests);
    test_step.dependOn(&run_markdown_tests.step);
    b.step("test-markdown", "Run CommonMark block, inline, table, task list and HTML output tests").dependOn(&run_markdown_tests.step);
    // Optional: needs `python scripts/fetch-sqlite.py`, so it stays out of `test` and `check`.
    const sqlite = b.addModule("ziggurat_sqlite", .{ .root_source_file = b.path("src/sqlite/root.zig"), .target = target, .optimize = optimize });
    @import("build_support/sqlite.zig").add(b, sqlite, target, optimize);
    const sqlite_tests = b.addTest(.{ .root_module = sqlite });
    b.step("test-sqlite", "Run SQLite connection, binding, row, transaction, migration and thread tests (fetch source first)").dependOn(&b.addRunArtifact(sqlite_tests).step);
    const wake = b.addModule("ziggurat_wake", .{ .root_source_file = b.path("src/wake/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat", .module = core }} });
    if (target.result.os.tag == .windows or target.result.os.tag == .linux) {
        wake.link_libc = true;
        const native = native_support.add(b, wake, "wake-native", "src/wake/native.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        if (target.result.os.tag == .linux) {
            native.linkSystemLibrary("glib-2.0", .{ .use_pkg_config = .force });
            wake.linkSystemLibrary("glib-2.0", .{ .use_pkg_config = .force });
        }
        addSmoke(b, "smoke-wake", "tests/wake_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_wake", .module = wake },
            .{ .name = "ziggurat_animation", .module = animation },
        });
    }
    // Linux loads GIO for the system proxy settings with dlopen.
    const net = b.addModule("ziggurat_net", .{ .root_source_file = b.path("src/net/root.zig"), .target = target, .optimize = optimize, .link_libc = target.result.os.tag == .linux });
    const update = b.addModule("ziggurat_update", .{ .root_source_file = b.path("src/update/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat_net", .module = net }} });
    const plugin_fetch = b.addModule("ziggurat_plugin_fetch", .{ .root_source_file = b.path("src/page_runtime/plugins/fetch.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat_ipc", .module = ipc },
        .{ .name = "ziggurat_net", .module = net },
        .{ .name = "ziggurat_page_runtime", .module = page_runtime },
    } });
    const plugin_fetch_tests = b.addTest(.{ .root_module = plugin_fetch });
    check.dependOn(&plugin_fetch_tests.step);
    const run_plugin_fetch_tests = b.addRunArtifact(plugin_fetch_tests);
    test_step.dependOn(&run_plugin_fetch_tests.step);
    b.step("test-plugin-fetch", "Run the fetch plugin's streaming, redirect, validation and cancellation tests against local servers").dependOn(&run_plugin_fetch_tests.step);
    const plugin_websocket = b.addModule("ziggurat_plugin_websocket", .{ .root_source_file = b.path("src/page_runtime/plugins/websocket.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat_ipc", .module = ipc },
        .{ .name = "ziggurat_net", .module = net },
        .{ .name = "ziggurat_page_runtime", .module = page_runtime },
    } });
    const plugin_websocket_tests = b.addTest(.{ .root_module = plugin_websocket });
    check.dependOn(&plugin_websocket_tests.step);
    const run_plugin_websocket_tests = b.addRunArtifact(plugin_websocket_tests);
    test_step.dependOn(&run_plugin_websocket_tests.step);
    b.step("test-plugin-websocket", "Run the WebSocket plugin's message, piece, close, refusal and page-leave tests against local servers").dependOn(&run_plugin_websocket_tests.step);
    const system_watch = b.createModule(.{ .root_source_file = b.path("src/system/watch.zig"), .target = target, .optimize = optimize, .link_libc = target.result.os.tag == .windows });
    const plugin_watch = b.addModule("ziggurat_plugin_watch", .{ .root_source_file = b.path("src/page_runtime/plugins/watch.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat_ipc", .module = ipc },
        .{ .name = "ziggurat_page_runtime", .module = page_runtime },
        .{ .name = "ziggurat_system_watch", .module = system_watch },
    } });
    const plugin_watch_tests = b.addTest(.{ .root_module = plugin_watch });
    check.dependOn(&plugin_watch_tests.step);
    const run_plugin_watch_tests = b.addRunArtifact(plugin_watch_tests);
    test_step.dependOn(&run_plugin_watch_tests.step);
    b.step("test-plugin-watch", "Run the watch plugin's snapshot comparison, rename pairing, root and request checks against temporary directories").dependOn(&run_plugin_watch_tests.step);
    // Loads SQLite at run time; libc gives the dynamic loader on Linux.
    const plugin_sqlite = b.addModule("ziggurat_plugin_sqlite", .{ .root_source_file = b.path("src/page_runtime/plugins/sqlite.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{
        .{ .name = "ziggurat_ipc", .module = ipc },
        .{ .name = "ziggurat_page_runtime", .module = page_runtime },
    } });
    const plugin_sqlite_tests = b.addTest(.{ .root_module = plugin_sqlite });
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
    const images = b.addModule("ziggurat_images", .{ .root_source_file = b.path("src/images/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat_drawing_resources", .module = drawing_resources }} });
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
    if (target.result.os.tag == .windows) {
        _ = native_support.add(b, text_layout, "text-layout-native", "src/ui/text_layout_windows.c", &.{"-std=c11"}, target, optimize);
        text_layout.linkSystemLibrary("dwrite", .{});
        text_layout.linkSystemLibrary("gdi32", .{});
        text_layout.link_libc = true;
    }
    if (target.result.os.tag == .linux) {
        const native = native_support.add(b, text_layout, "text-layout-native", "src/ui/text_layout_linux.c", &.{"-std=c11"}, target, optimize);
        native.linkSystemLibrary("pangocairo", .{ .use_pkg_config = .force });
        text_layout.linkSystemLibrary("pangocairo", .{ .use_pkg_config = .force });
        text_layout.link_libc = true;
    }
    if (target.result.os.tag == .windows or target.result.os.tag == .linux) {
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
    const system = b.addModule("ziggurat_system", .{ .root_source_file = b.path("src/system/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat", .module = core }} });
    if (target.result.os.tag == .linux) {
        const native = native_support.add(b, system, "system-shell-native", "src/system/shell_linux.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        native.linkSystemLibrary("gio-2.0", .{ .use_pkg_config = .force });
        native.linkSystemLibrary("gio-unix-2.0", .{ .use_pkg_config = .force });
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
        addSmoke(b, "smoke-desktop", "tests/system_desktop_smoke.zig", target, optimize, &.{
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
    if (target.result.os.tag == .linux) {
        const desktop_native = native_support.add(b, system, "system-desktop-native", "src/system/desktop_linux.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        desktop_native.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        const clipboard_native = native_support.add(b, system, "system-clipboard-native", "src/system/clipboard_linux.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        clipboard_native.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        const drop_native = native_support.add(b, system, "system-drop-native", "src/system/drop_linux.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        drop_native.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
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
        desktop_smoke.linkSystemLibrary("gio-2.0", .{ .use_pkg_config = .force });
        desktop_smoke.linkSystemLibrary("x11", .{ .use_pkg_config = .force });
        // Needs a session bus and an X11 display: dbus-run-session -- xvfb-run.
        const now_playing_smoke = addSmokeModule(b, "smoke-now-playing", "tests/now_playing_linux_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_system", .module = system },
        });
        const now_playing_fixture = native_support.add(b, now_playing_smoke, "now-playing-fixture", "tests/now_playing_linux_fixture.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        now_playing_fixture.linkSystemLibrary("gio-2.0", .{ .use_pkg_config = .force });
        now_playing_smoke.linkSystemLibrary("gio-2.0", .{ .use_pkg_config = .force });
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
        const desktop = native_support.add(b, system, "system-linux-desktop", "src/system/linux_desktop.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        desktop.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        desktop.linkSystemLibrary("x11", .{ .use_pkg_config = .force });
        system.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        system.linkSystemLibrary("x11", .{ .use_pkg_config = .force });
        system.link_libc = true;
    }
    addSystemIntegrationNative(b, system, target, optimize);
    const system_unit_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/system/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat", .module = core }} }) });
    addSystemIntegrationNative(b, system_unit_tests.root_module, target, optimize);
    if (target.result.os.tag == .windows) {
        for ([_][]const u8{ "user32", "gdi32", "shell32", "ole32" }) |library| system_unit_tests.root_module.linkSystemLibrary(library, .{});
        _ = native_support.add(b, system_unit_tests.root_module, "system-picker-native-test", "src/system/picker.c", &.{"-std=c11"}, target, optimize);
    }
    if (target.result.os.tag == .windows or target.result.os.tag == .linux) {
        const integration_probe = b.createModule(.{ .root_source_file = b.path("tests/os_integration_probe.zig"), .target = target, .optimize = optimize, .link_libc = true });
        if (target.result.os.tag == .linux) {
            integration_probe.addCSourceFile(.{ .file = b.path("tests/os_integration_probe.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
            for ([_][]const u8{ "gio-2.0", "gio-unix-2.0" }) |library| integration_probe.linkSystemLibrary(library, .{ .use_pkg_config = .yes });
        } else integration_probe.linkSystemLibrary("shlwapi", .{});
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
        core.link_libc = true;
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
    const view_graphics = b.addModule("ziggurat_view_graphics", .{ .root_source_file = b.path("src/view/graphics.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },                  .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_view", .module = declarative_view }, .{ .name = "ziggurat_vector", .module = vector },
        .{ .name = "ziggurat_svg", .module = svg },
    } });
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
    const view_rich_text_tests = b.addTest(.{ .root_module = view_rich_text });
    check.dependOn(&view_rich_text_tests.step);
    const run_view_rich_text_tests = b.addRunArtifact(view_rich_text_tests);
    test_step.dependOn(&run_view_rich_text_tests.step);
    b.step("test-view-rich-text", "Run rich text wrapping, baseline, decoration and paint tests").dependOn(&run_view_rich_text_tests.step);
    const markdown_rich = b.addModule("ziggurat_markdown_rich", .{ .root_source_file = b.path("src/markdown/rich_text.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat_markdown", .module = markdown },     .{ .name = "ziggurat_markdown_view", .module = markdown_view },
        .{ .name = "ziggurat_view", .module = declarative_view }, .{ .name = "ziggurat_view_rich_text", .module = view_rich_text },
    } });
    const markdown_rich_tests = b.addTest(.{ .root_module = markdown_rich });
    check.dependOn(&markdown_rich_tests.step);
    const run_markdown_rich_tests = b.addRunArtifact(markdown_rich_tests);
    test_step.dependOn(&run_markdown_rich_tests.step);
    b.step("test-markdown-rich", "Run Markdown inline style to rich text span tests").dependOn(&run_markdown_rich_tests.step);
    const chart = b.addModule("ziggurat_chart", .{ .root_source_file = b.path("src/chart/root.zig"), .target = target, .optimize = optimize });
    const chart_tests = b.addTest(.{ .root_module = chart });
    check.dependOn(&chart_tests.step);
    const run_chart_tests = b.addRunArtifact(chart_tests);
    test_step.dependOn(&run_chart_tests.step);
    b.step("test-chart", "Run chart scale, tick, stack, path, downsampling, layout and selection tests").dependOn(&run_chart_tests.step);
    if (target.result.os.tag == .windows or target.result.os.tag == .linux) {
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
    const ui_options = b.addOptions();
    ui.addImport("ziggurat_drawing_resources", drawing_resources);
    const shader = b.addModule("ziggurat_shader", .{ .root_source_file = b.path("src/shader/root.zig"), .target = target, .optimize = optimize });
    ui.addImport("ziggurat_shader", shader);
    const shader_tests = b.addTest(.{ .root_module = shader });
    check.dependOn(&shader_tests.step);
    const run_shader_tests = b.addRunArtifact(shader_tests);
    test_step.dependOn(&run_shader_tests.step);
    b.step("test-shader", "Run shader language, bounded execution and uniform contracts").dependOn(&run_shader_tests.step);
    if (target.result.os.tag == .linux) {
        // Translated programs against the CPU machine on OpenGL (Mesa
        // draws without a GPU); needs EGL and libepoxy.
        const gl_parity = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/shader_gpu_gl.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "ziggurat_shader", .module = shader }} }) });
        gl_parity.root_module.addCSourceFile(.{ .file = b.path("tests/shader_gpu_gl.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        gl_parity.root_module.linkSystemLibrary("epoxy", .{});
        check.dependOn(&gl_parity.step);
        b.step("test-shader-gl", "Run translated shader programs on OpenGL against the CPU machine").dependOn(&b.addRunArtifact(gl_parity).step);
    }
    if (target.result.os.tag == .windows) {
        // Translated programs against the CPU machine on Direct3D 11 WARP,
        // compiled by the system's HLSL compiler.
        const d3d_parity = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/shader_gpu_d3d.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "ziggurat_shader", .module = shader }} }) });
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
        addSmoke(b, "smoke-virtual-list-control", "tests/virtual_list_control_linux_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_ui", .module = ui },
            .{ .name = "ziggurat_virtual_list", .module = virtual_list },
        });
    }
    const prepared_hit = b.createModule(.{ .root_source_file = b.path("src/document_editor/prepared_hit.zig"), .target = target, .optimize = optimize });
    const prepared_hit_tests = b.addTest(.{ .root_module = prepared_hit });
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
        const provider_tests = b.addTest(.{ .root_module = b.createModule(.{
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
    ui_options.addOption(bool, "gpu", gpu);
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
    if (gpu) {
        if (target.result.os.tag != .windows) @panic("D3D11 requires Windows");
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
    if (accessibility) {
        if (target.result.os.tag != .windows) @panic("UI Automation requires Windows");
        // An archive member is linked only by programs that reference UIA.
        _ = native_support.addArchive(b, ui, "ui-accessibility-native", "src/ui/accessibility.c", &.{"-std=c11"}, target, optimize);
        ui.linkSystemLibrary("uiautomationcore", .{});
        ui.linkSystemLibrary("oleaut32", .{});
    }
    if (target.result.os.tag == .windows) {
        ui.linkSystemLibrary("gdi32", .{});
        ui.link_libc = true;
    }
    if (target.result.os.tag == .linux) {
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
        addSmoke(b, "smoke-window-state", "tests/window_state_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
        addSmoke(b, "smoke-window-relationships", "tests/window_relationship_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
        addSmoke(b, "smoke-key-input", "tests/key_input_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
        addSmoke(b, "smoke-window-chrome", "tests/window_chrome_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
        addSmoke(b, "smoke-window-policy", "tests/window_policy_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
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
    if (target.result.os.tag == .windows) {
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
        addSmoke(b, "smoke-window-relationships", "tests/window_relationship_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
        addSmoke(b, "smoke-key-input", "tests/key_input_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
        addSmoke(b, "smoke-window-chrome", "tests/window_chrome_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
        addSmoke(b, "smoke-window-policy", "tests/window_policy_smoke.zig", target, optimize, &.{.{ .name = "ziggurat", .module = core }});
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
        }
    }
    if (web and target.result.os.tag != .windows and target.result.os.tag != .linux)
        @panic("WebView currently requires Windows x86_64 or Linux GTK3");
    if (web and target.result.os.tag == .windows) {
        if (target.result.cpu.arch != .x86_64)
            @panic("The first WebView2 backend supports Windows x86_64 only");
        const sdk = b.option([]const u8, "webview2-sdk", "Path to the extracted WebView2 SDK") orelse ".deps/webview2";
        const view = b.addModule("ziggurat_webview", .{
            .root_source_file = b.path("src/webview/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_file_stream", .module = file_stream }, .{ .name = "ziggurat_http_response", .module = http_response } },
            .link_libc = true,
        });
        view.addImport("ziggurat_tls_pem", tls_pem);
        for ([_][]const u8{ "webview2.c", "page_host.c" }) |file| {
            const native = native_support.add(b, view, b.fmt("webview-{s}", .{file}), b.fmt("src/webview/{s}", .{file}), &.{"-std=c11"}, target, optimize);
            native.addIncludePath(sourcePath(b, b.pathJoin(&.{ sdk, "build/native/include" })));
            native.addIncludePath(b.path("src/webview/include"));
        }
        addWindowsProfileNative(b, view, "webview", sdk, target, optimize);
        view.linkSystemLibrary("ole32", .{});
        view.linkSystemLibrary("shlwapi", .{});
        view.linkSystemLibrary("urlmon", .{});
        view.linkSystemLibrary("oleaut32", .{});
        const producer = b.addModule("ziggurat_webview_producer", .{
            .root_source_file = b.path("src/resource_stream/web.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ziggurat", .module = core },
                .{ .name = "ziggurat_webview", .module = view },
                .{ .name = "ziggurat_ipc", .module = ipc },
                .{ .name = "ziggurat_resource_stream", .module = resource_stream },
            },
        });
        view_tests = b.addTest(.{ .root_module = view });
        const web_runtime = b.step("webview-runtime", "Install the optional WebView2 loader and SDK license");
        web_runtime.dependOn(&b.addInstallFileWithDir(sourcePath(b, b.pathJoin(&.{ sdk, "build/native/x64/WebView2Loader.dll" })), .bin, "WebView2Loader.dll").step);
        web_runtime.dependOn(&b.addInstallFileWithDir(sourcePath(b, b.pathJoin(&.{ sdk, "LICENSE.txt" })), .bin, "WebView2-SDK-LICENSE.txt").step);
        b.getInstallStep().dependOn(web_runtime);
        // Test-only certificate oracle compiles the real adapter in isolation.
        // Production View never links this fixture or a TLS exception entry.
        const credentials_view = b.createModule(.{
            .root_source_file = b.path("src/webview/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_file_stream", .module = file_stream }, .{ .name = "ziggurat_http_response", .module = http_response } },
            .link_libc = true,
        });
        credentials_view.addImport("ziggurat_tls_pem", tls_pem);
        for ([_][]const u8{ "tests/windows_request_credentials_adapter.c", "src/webview/page_host.c" }) |file| {
            const native = native_support.add(b, credentials_view, b.fmt("credential-probe-{s}", .{std.fs.path.stem(file)}), file, &.{"-std=c11"}, target, optimize);
            native.addIncludePath(sourcePath(b, b.pathJoin(&.{ sdk, "build/native/include" })));
            native.addIncludePath(b.path("src/webview/include"));
        }
        addWindowsProfileNative(b, credentials_view, "credential-probe", sdk, target, optimize);
        for ([_][]const u8{ "ole32", "shlwapi", "urlmon", "oleaut32", "crypt32" }) |library| credentials_view.linkSystemLibrary(library, .{});
        const credentials_smoke = b.addExecutable(.{ .name = "smoke-request-credentials", .root_module = b.createModule(.{
            .root_source_file = b.path("tests/windows_request_credentials_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = credentials_view } },
        }) });
        check.dependOn(&credentials_smoke.step);
        const credentials_install = b.addInstallArtifact(credentials_smoke, .{});
        const credentials_build = b.step("build-smoke-request-credentials", "Build the isolated HTTPS credential Runtime oracle; run with its explicit Python host");
        credentials_build.dependOn(&credentials_install.step);
        credentials_build.dependOn(web_runtime);
        if (https_resources_enabled) {
            const producer_smoke = b.addExecutable(.{ .name = "smoke-https-producer", .root_module = b.createModule(.{
                .root_source_file = b.path("tests/windows_https_producer_smoke.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "ziggurat", .module = core },
                    .{ .name = "ziggurat_webview", .module = credentials_view },
                    .{ .name = "ziggurat_https_resources", .module = https_resources },
                    .{ .name = "ziggurat_native_stream", .module = native_stream },
                },
            }) });
            check.dependOn(&producer_smoke.step);
            const producer_install = b.addInstallArtifact(producer_smoke, .{});
            const producer_build = b.step("build-smoke-https-producer", "Build explicit Windows HTTPS producer checks; run with the Python host");
            producer_build.dependOn(&producer_install.step);
            producer_build.dependOn(web_runtime);
        }
        // Keep the initializer callback interception and certificate oracle in
        // their own test module; the production adapter is not linked twice.
        const initializers_view = b.createModule(.{
            .root_source_file = b.path("src/webview/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_file_stream", .module = file_stream }, .{ .name = "ziggurat_http_response", .module = http_response } },
            .link_libc = true,
        });
        initializers_view.addImport("ziggurat_tls_pem", tls_pem);
        for ([_][]const u8{ "tests/windows_document_initializers_adapter.c", "src/webview/page_host.c" }) |file| {
            const native = native_support.add(b, initializers_view, b.fmt("initializer-probe-{s}", .{std.fs.path.stem(file)}), file, &.{"-std=c11"}, target, optimize);
            native.addIncludePath(sourcePath(b, b.pathJoin(&.{ sdk, "build/native/include" })));
            native.addIncludePath(b.path("src/webview/include"));
        }
        addWindowsProfileNative(b, initializers_view, "initializer-probe", sdk, target, optimize);
        for ([_][]const u8{ "ole32", "shlwapi", "urlmon", "oleaut32", "crypt32" }) |library| initializers_view.linkSystemLibrary(library, .{});
        const initializers_smoke = b.addExecutable(.{ .name = "smoke-document-initializers", .root_module = b.createModule(.{
            .root_source_file = b.path("tests/windows_document_initializers_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = initializers_view } },
        }) });
        check.dependOn(&initializers_smoke.step);
        const initializers_install = b.addInstallArtifact(initializers_smoke, .{});
        const initializers_build = b.step("build-smoke-document-initializers", "Build the isolated initializer Runtime oracle; run with its explicit Python host");
        initializers_build.dependOn(&initializers_install.step);
        initializers_build.dependOn(web_runtime);
        _ = addExample(b, "web-counter", "examples/web_counter.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_webview", .module = view },
        });
        _ = addExample(b, "rectangular-pages", "examples/rectangular_pages.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_ui", .module = ui },
            .{ .name = "ziggurat_webview", .module = view },
        });
        addSmoke(b, "smoke-webview", "tests/webview_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_webview", .module = view },
        });
        addWebNativeBoundarySmoke(b, target, optimize, core, view);
        addSmoke(b, "smoke-resource-file", "tests/file_response_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_webview", .module = view },
        });
        addSmoke(b, "smoke-scheme", "tests/scheme_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_webview", .module = view },
        });
        addSmoke(b, "smoke-permission", "tests/permission_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_webview", .module = view },
        });
        addSmoke(b, "smoke-download", "tests/download_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_webview", .module = view },
        });
        addSmoke(b, "smoke-browser-policy", "tests/policy_store_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_webview", .module = view },
        });
        addSmoke(b, "smoke-composition-webview", "tests/composition_webview_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_webview", .module = view },
            .{ .name = "ziggurat_ui", .module = ui },
        });
        addSmoke(b, "smoke-page-session", "tests/page_session_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_webview", .module = view },
            .{ .name = "ziggurat_ui", .module = ui },
        });
        addSmoke(b, "smoke-page", "tests/page_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_webview", .module = view },
        });
        const page_authorization = b.addExecutable(.{ .name = "smoke-page-authorization", .root_module = b.createModule(.{
            .root_source_file = b.path("tests/page_authorization_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }) });
        page_authorization.root_module.addCSourceFile(.{ .file = b.path("tests/page_authorization_smoke.c"), .flags = &.{"-std=c11"} });
        page_authorization.root_module.addCSourceFile(.{ .file = b.path("src/webview/page_host.c"), .flags = &.{"-std=c11"} });
        _ = native_support.add(b, page_authorization.root_module, "page-authorization-stream-native", "src/file_stream/windows_core.c", &.{"-std=c11"}, target, optimize);
        page_authorization.root_module.addIncludePath(sourcePath(b, b.pathJoin(&.{ sdk, "build/native/include" })));
        page_authorization.root_module.addIncludePath(b.path("src/webview/include"));
        addWindowsProfileNative(b, page_authorization.root_module, "page-authorization", sdk, target, optimize);
        for ([_][]const u8{ "user32", "ole32", "shlwapi", "gdi32", "urlmon", "oleaut32" }) |library| page_authorization.root_module.linkSystemLibrary(library, .{});
        check.dependOn(&page_authorization.step);
        const page_authorization_run = b.addRunArtifact(page_authorization);
        b.step("smoke-page-authorization", "Check page authorization through native callback ABI without a Runtime").dependOn(&page_authorization_run.step);
        const remote_origins = b.addExecutable(.{ .name = "test-remote-origin", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
        remote_origins.root_module.addCSourceFile(.{ .file = b.path("tests/remote_origin_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        remote_origins.root_module.addSystemIncludePath(sourcePath(b, b.pathJoin(&.{ sdk, "build/native/include" })));
        remote_origins.root_module.addIncludePath(b.path("src/webview/include"));
        for ([_][]const u8{ "ole32", "oleaut32", "urlmon" }) |library| remote_origins.root_module.linkSystemLibrary(library, .{});
        check.dependOn(&remote_origins.step);
        b.step("test-remote-origin", "Run native canonical remote origin and loopback policy regressions").dependOn(&b.addRunArtifact(remote_origins).step);
        const initializer_native = b.addExecutable(.{ .name = "test-document-initializers-native", .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }) });
        // The regression includes the actual adapter once and supplies its own
        // bounded SDK double. It does not create a browser or open a window.
        initializer_native.root_module.addCSourceFile(.{ .file = b.path("tests/document_initializers_native_test.c"), .flags = &.{"-std=c11"} });
        _ = native_support.add(b, initializer_native.root_module, "initializer-stream-native", "src/file_stream/windows_core.c", &.{"-std=c11"}, target, optimize);
        initializer_native.root_module.addIncludePath(sourcePath(b, b.pathJoin(&.{ sdk, "build/native/include" })));
        initializer_native.root_module.addIncludePath(b.path("src/webview/include"));
        addWindowsProfileNative(b, initializer_native.root_module, "initializer-native", sdk, target, optimize);
        for ([_][]const u8{ "user32", "ole32", "shlwapi", "gdi32", "urlmon", "oleaut32" }) |library| initializer_native.root_module.linkSystemLibrary(library, .{});
        check.dependOn(&initializer_native.step);
        initializer_native_run = b.addRunArtifact(initializer_native);
        b.step("test-document-initializers-native", "Run native document initializer mutation and lifetime contracts without a Runtime").dependOn(&initializer_native_run.?.step);
        const page_host_test = b.addExecutable(.{ .name = "smoke-page-host", .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }) });
        page_host_test.root_module.addCSourceFile(.{ .file = b.path("tests/page_host_smoke.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        page_host_test.root_module.linkSystemLibrary("user32", .{});
        check.dependOn(&page_host_test.step);
        b.step("smoke-page-host", "Check native page subtree ownership and rollback without a Runtime").dependOn(&b.addRunArtifact(page_host_test).step);
        addSmoke(b, "smoke-webview-policy", "tests/webview_policy_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_webview", .module = view },
        });
        addSmoke(b, "smoke-webview-page-facts", "tests/page_facts_webview_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view },
        });
        _ = addHttpAuthSmoke(b, target, optimize, core, view);
        addSmoke(b, "smoke-webview-context-menu", "tests/context_menu_webview_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view },
        });
        addSmoke(b, "smoke-webview-page-options", "tests/page_options_webview_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view },
        });
        addSmoke(b, "smoke-webview-session-state", "tests/session_state_webview_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view },
        });
        addSmoke(b, "smoke-webview-picture-in-picture", "tests/picture_in_picture_webview_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view },
        });
        addSmoke(b, "smoke-page-remote", "tests/remote_page_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_webview", .module = view },
        });
        addSmoke(b, "smoke-script", "tests/script_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view },
        });
        addSmoke(b, "smoke-browser-tools", "tests/browser_tools_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view },
        });
        addSmoke(b, "smoke-request-policy", "tests/request_policy_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view },
        });
        addSmoke(b, "smoke-resource-async", "tests/resource_async_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view },
        });
        addSmoke(b, "smoke-assets", "tests/assets_webview_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_webview", .module = view },
            .{ .name = "ziggurat_assets", .module = assets },
        });
        const bundle = b.addSystemCommand(&.{ "bun", "build" });
        bundle.addFileArg(b.path("tests/ipc_page.ts"));
        bundle.addFileInput(b.path("tests/ipc_fixture.ts"));
        bundle.addArgs(&.{ "--target", "browser", "--format", "iife", "--outfile" });
        const page_script = bundle.addOutputFileArg("ipc-page.js");
        const page_module = b.createModule(.{ .root_source_file = page_script });
        const counter_service = b.createModule(.{ .root_source_file = b.path("examples/counter_service.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat_ipc", .module = ipc }} });
        addSmoke(b, "smoke-ipc", "tests/ipc_webview_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_webview", .module = view },
            .{ .name = "ziggurat_ipc", .module = ipc },
            .{ .name = "counter_service", .module = counter_service },
            .{ .name = "ipc_page", .module = page_module },
        });
        addPageRuntimeSmoke(b, target, optimize, core, view, ipc, i18n, page_runtime, net, plugin_fetch, plugin_watch, plugin_sqlite, plugin_websocket);
        addEmbeddedWebView(b, target, optimize, core, ui, declarative_view, view);
        const producer_bundle = b.addSystemCommand(&.{ "bun", "build" });
        producer_bundle.addFileArg(b.path("tests/resource_producer_page.ts"));
        producer_bundle.addFileInput(b.path("tests/resource_producer_fixture.ts"));
        producer_bundle.addFileInput(b.path("src/resource_stream/client.ts"));
        producer_bundle.addArgs(&.{ "--target", "browser", "--format", "iife", "--outfile" });
        const producer_script = producer_bundle.addOutputFileArg("producer-page.js");
        const producer_page = b.createModule(.{ .root_source_file = producer_script });
        addSmoke(b, "smoke-resource-producer", "tests/resource_producer_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_webview", .module = view },
            .{ .name = "ziggurat_ipc", .module = ipc },
            .{ .name = "ziggurat_webview_producer", .module = producer },
            .{ .name = "producer_page", .module = producer_page },
        });
    }
    if (web and target.result.os.tag == .linux) {
        const view = b.addModule("ziggurat_webview", .{
            .root_source_file = b.path("src/webview/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_file_stream", .module = file_stream }, .{ .name = "ziggurat_http_response", .module = http_response } },
            .link_libc = true,
        });
        view.addImport("ziggurat_tls_pem", tls_pem);
        for ([_][]const u8{ "webkit_native.c", "webkit_profile.c", "webkit_cookies.c" }) |file| {
            const native = native_support.add(b, view, b.fmt("webview-{s}", .{file}), b.fmt("src/webview/{s}", .{file}), &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
            native.linkSystemLibrary("gio-unix-2.0", .{ .use_pkg_config = .force });
            native.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes });
        }
        view.linkSystemLibrary("gio-unix-2.0", .{ .use_pkg_config = .force });
        const test_file_stream = b.createModule(.{ .root_source_file = b.path("src/file_stream/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
        const test_file_native = native_support.add(b, test_file_stream, "file-stream-native-test", "src/file_stream/linux.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-DZWK_FILE_TESTING" }, target, optimize);
        test_file_native.linkSystemLibrary("gio-unix-2.0", .{ .use_pkg_config = .force });
        test_file_stream.linkSystemLibrary("gio-unix-2.0", .{ .use_pkg_config = .force });
        const file_response_module = b.createModule(.{ .root_source_file = b.path("src/webview/file_responses.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ziggurat_file_stream", .module = test_file_stream }, .{ .name = "ziggurat_http_response", .module = http_response } } });
        const file_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/webkit_file_test.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{ .{ .name = "file_responses", .module = file_response_module }, .{ .name = "ziggurat_file_stream", .module = test_file_stream } } }) });
        const file_test_helper = native_support.add(b, file_tests.root_module, "file-stream-test-helper", "tests/webkit_file_test.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-DZWK_FILE_TESTING" }, target, optimize);
        file_test_helper.linkSystemLibrary("gio-unix-2.0", .{ .use_pkg_config = .force });
        file_tests.root_module.linkSystemLibrary("gio-unix-2.0", .{ .use_pkg_config = .force });
        check.dependOn(&file_tests.step);
        webkit_file_run = b.addRunArtifact(file_tests);
        b.step("test-webkit-file", "Verify explicit file pumps, socket readiness, cancellation and physical lifetime without a browser").dependOn(&webkit_file_run.?.step);
        const profile_module = b.createModule(.{ .root_source_file = b.path("src/webview/profile.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat_tls_pem", .module = tls_pem }} });
        const profile_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("tests/profile_owner_linux.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "profile", .module = profile_module }},
        }) });
        const profile_native = native_support.add(b, profile_tests.root_module, "webkit-profile-native-test", "src/webview/webkit_profile.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-DZWK_PROFILE_TESTING" }, target, optimize);
        profile_native.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes });
        profile_tests.root_module.addCSourceFile(.{ .file = b.path("tests/webkit_profile_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-DZWK_PROFILE_TESTING" } });
        profile_tests.root_module.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes });
        check.dependOn(&profile_tests.step);
        b.step("test-webkit-profile", "Verify private profile manager ownership, native finalization and exclusive storage without a page").dependOn(&b.addRunArtifact(profile_tests).step);
        const profile_tls_owner_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("tests/profile_tls_owner_linux.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "profile", .module = profile_module }},
        }) });
        const profile_tls_native = native_support.add(b, profile_tls_owner_tests.root_module, "webkit-profile-tls-native-test", "src/webview/webkit_profile.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-DZWK_PROFILE_TESTING" }, target, optimize);
        profile_tls_native.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes });
        profile_tls_owner_tests.root_module.addCSourceFile(.{ .file = b.path("tests/webkit_profile_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-DZWK_PROFILE_TESTING" } });
        profile_tls_owner_tests.root_module.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes });
        check.dependOn(&profile_tls_owner_tests.step);
        b.step("test-webkit-profile-tls", "Verify frozen TLS profile construction, allocation failure and late native ownership without a page").dependOn(&b.addRunArtifact(profile_tls_owner_tests).step);
        const cookies_owner_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cookie_owner_linux.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "profile", .module = profile_module }},
        }) });
        const cookies_profile_native = native_support.add(b, cookies_owner_tests.root_module, "cookies-profile-native-test", "src/webview/webkit_profile.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        cookies_profile_native.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes });
        const cookies_native = native_support.add(b, cookies_owner_tests.root_module, "cookies-native-test", "src/webview/webkit_cookies.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-DZWK_COOKIES_TESTING" }, target, optimize);
        cookies_native.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes });
        cookies_owner_tests.root_module.addCSourceFile(.{ .file = b.path("tests/webkit_cookies_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-DZWK_COOKIES_TESTING" } });
        cookies_owner_tests.root_module.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes });
        check.dependOn(&cookies_owner_tests.step);
        b.step("test-webkit-cookies", "Verify native cookie allocation failure, acceptance and task finalization without a page").dependOn(&b.addRunArtifact(cookies_owner_tests).step);
        view.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes });
        const request_extension = b.addLibrary(.{ .name = "ziggurat-request-policy", .linkage = .dynamic, .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
        request_extension.root_module.addCSourceFile(.{ .file = b.path("src/webview/webkit_request_extension.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        request_extension.root_module.linkSystemLibrary("webkit2gtk-web-extension-4.1", .{ .use_pkg_config = .yes });
        const install_extension = b.addInstallArtifact(request_extension, .{});
        b.step("webview-request-extension", "Install the optional WebProcess request policy adapter for explicit deployment").dependOn(&install_extension.step);
        check.dependOn(&request_extension.step);
        view_tests = b.addTest(.{ .root_module = view });
        _ = b.step("webview-runtime", "Use the installed WebKitGTK 4.1 runtime");
        addWebNativeBoundarySmoke(b, target, optimize, core, view);
        addPageRuntimeSmoke(b, target, optimize, core, view, ipc, i18n, page_runtime, net, plugin_fetch, plugin_watch, plugin_sqlite, plugin_websocket);
        addEmbeddedWebView(b, target, optimize, core, ui, declarative_view, view);
        addSmoke(b, "smoke-webview-linux", "tests/linux_webview_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_webview", .module = view },
        });
        addSmoke(b, "smoke-webview-page-facts", "tests/page_facts_webview_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view },
        });
        const http_auth_run = addHttpAuthSmoke(b, target, optimize, core, view);
        http_auth_run.step.dependOn(&install_extension.step);
        http_auth_run.addArg("--extension");
        http_auth_run.addDirectoryArg(b.graph.path(.install_lib, ""));
        const context_menu_module = addSmokeModule(b, "smoke-webview-context-menu", "tests/context_menu_webview_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view },
        });
        context_menu_module.addCSourceFile(.{ .file = b.path("tests/context_menu_probe.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        context_menu_module.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes });
        const page_options_module = addSmokeModule(b, "smoke-webview-page-options", "tests/page_options_webview_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view },
        });
        page_options_module.addCSourceFile(.{ .file = b.path("tests/page_options_probe.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        page_options_module.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes });
        addSmoke(b, "smoke-webview-session-state", "tests/session_state_webview_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view },
        });
        addSmoke(b, "smoke-webview-dynamic-linux", "tests/linux_dynamic_webview_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_webview", .module = view },
        });
        const capture_smoke = b.addExecutable(.{ .name = "smoke-webview-capture-linux", .root_module = b.createModule(.{
            .root_source_file = b.path("tests/linux_capture_webview_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view } },
        }) });
        capture_smoke.root_module.addCSourceFile(.{ .file = b.path("tests/webkit_capture_fixture.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        capture_smoke.root_module.linkSystemLibrary("cairo", .{ .use_pkg_config = .force });
        check.dependOn(&capture_smoke.step);
        b.step("smoke-webview-capture-linux", "Verify bounded native PNG capture, independent pixel data and request ownership").dependOn(&b.addRunArtifact(capture_smoke).step);
        addSmoke(b, "smoke-webview-pdf-linux", "tests/linux_pdf_webview_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view },
        });
        const capture_owner_tests = b.addExecutable(.{ .name = "test-webkit-capture", .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }) });
        capture_owner_tests.root_module.addCSourceFile(.{ .file = b.path("tests/webkit_capture_owner_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        capture_owner_tests.root_module.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes });
        check.dependOn(&capture_owner_tests.step);
        b.step("test-webkit-capture", "Verify native capture allocation, cancellation and task finalization ownership").dependOn(&b.addRunArtifact(capture_owner_tests).step);
        const find_owner_tests = b.addExecutable(.{ .name = "test-webkit-find", .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }) });
        find_owner_tests.root_module.addCSourceFile(.{ .file = b.path("tests/webkit_find_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        find_owner_tests.root_module.linkSystemLibrary("gobject-2.0", .{ .use_pkg_config = .force });
        check.dependOn(&find_owner_tests.step);
        const find_owner_run = b.addRunArtifact(find_owner_tests);
        test_step.dependOn(&find_owner_run.step);
        b.step("test-webkit-find", "Verify single native Find command, logical cancellation and physical ownership").dependOn(&find_owner_run.step);
        const find_smoke = b.addExecutable(.{ .name = "smoke-find", .root_module = b.createModule(.{
            .root_source_file = b.path("tests/linux_find_webview_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view } },
        }) });
        find_smoke.root_module.addCSourceFile(.{ .file = b.path("tests/webkit_find_fixture.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        find_smoke.root_module.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes });
        check.dependOn(&find_smoke.step);
        const install_find_smoke = b.addInstallArtifact(find_smoke, .{});
        b.step("build-smoke-find", "Install the native Find ownership and lifecycle integration probe").dependOn(&install_find_smoke.step);
        const find_smoke_run = b.addRunArtifact(find_smoke);
        find_smoke_run.addPassthruArgs();
        b.step("smoke-find", "Verify native Find request ordering, cancellation and lifecycle").dependOn(&find_smoke_run.step);
        const initializers_smoke = b.addExecutable(.{ .name = "smoke-webview-initializers-linux", .root_module = b.createModule(.{
            .root_source_file = b.path("tests/linux_document_initializers_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view } },
        }) });
        initializers_smoke.root_module.addCSourceFile(.{ .file = b.path("tests/initializer_https_fixture.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        initializers_smoke.root_module.linkSystemLibrary("libsoup-3.0", .{ .use_pkg_config = .yes });
        check.dependOn(&initializers_smoke.step);
        const initializers_run = b.addRunArtifact(initializers_smoke);
        initializers_run.step.dependOn(&install_extension.step);
        initializers_run.setEnvironmentVariable("ZIGGURAT_REQUEST_POLICY_EXTENSION", "zig-out/lib");
        b.step("smoke-webview-initializers-linux", "Verify trusted future-document initializers and owned bootstrap replacement").dependOn(&initializers_run.step);
        const initializers_owner_tests = b.addExecutable(.{ .name = "test-webkit-initializers", .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }) });
        initializers_owner_tests.root_module.addCSourceFile(.{ .file = b.path("tests/webkit_initializers_owner_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        initializers_owner_tests.root_module.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes });
        check.dependOn(&initializers_owner_tests.step);
        b.step("test-webkit-initializers", "Verify prepared native initializer ownership and synchronous replacement transactions").dependOn(&b.addRunArtifact(initializers_owner_tests).step);
        addSmoke(b, "smoke-webview-navigation-linux", "tests/linux_navigation_webview_smoke.zig", target, optimize, &.{
            .{ .name = "ziggurat", .module = core },
            .{ .name = "ziggurat_webview", .module = view },
        });
        const regions_smoke = b.addExecutable(.{ .name = "smoke-webview-regions-linux", .root_module = b.createModule(.{ .root_source_file = b.path("tests/linux_regions_webview_smoke.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view } } }) });
        regions_smoke.root_module.addCSourceFile(.{ .file = b.path("tests/linux_regions_webview_probe.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        regions_smoke.root_module.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes });
        check.dependOn(&regions_smoke.step);
        b.step("smoke-webview-regions-linux", "Verify independent rectangular WebKit children, geometry and close lifetime").dependOn(&b.addRunArtifact(regions_smoke).step);
        const session_smoke = b.addExecutable(.{ .name = "smoke-webview-session-linux", .root_module = b.createModule(.{ .root_source_file = b.path("tests/linux_session_webview_smoke.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view } } }) });
        session_smoke.root_module.addCSourceFile(.{ .file = b.path("tests/webkit_remote_fixture.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        session_smoke.root_module.linkSystemLibrary("libsoup-3.0", .{ .use_pkg_config = .yes });
        check.dependOn(&session_smoke.step);
        const session_run = b.addRunArtifact(session_smoke);
        session_run.step.dependOn(&install_extension.step);
        session_run.setEnvironmentVariable("ZIGGURAT_REQUEST_POLICY_EXTENSION", "zig-out/lib");
        b.step("smoke-webview-session-linux", "Verify parked and rehosted page ownership, pending work and shutdown").dependOn(&session_run.step);
        const remote_smoke = b.addExecutable(.{ .name = "smoke-webview-remote-linux", .root_module = b.createModule(.{ .root_source_file = b.path("tests/linux_remote_webview_smoke.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view } } }) });
        remote_smoke.root_module.addCSourceFile(.{ .file = b.path("tests/webkit_remote_fixture.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        remote_smoke.root_module.linkSystemLibrary("libsoup-3.0", .{ .use_pkg_config = .yes });
        check.dependOn(&remote_smoke.step);
        const remote_run = b.addRunArtifact(remote_smoke);
        remote_run.step.dependOn(&install_extension.step);
        remote_run.setEnvironmentVariable("ZIGGURAT_REQUEST_POLICY_EXTENSION", "zig-out/lib");
        b.step("smoke-webview-remote-linux", "Run isolated loopback remote View policy and lifetime checks").dependOn(&remote_run.step);
        const profile_smoke = b.addExecutable(.{ .name = "smoke-webview-profile-linux", .root_module = b.createModule(.{
            .root_source_file = b.path("tests/linux_profile_webview_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view } },
        }) });
        check.dependOn(&profile_smoke.step);
        const profile_run = b.addRunArtifact(profile_smoke);
        profile_run.step.dependOn(&install_extension.step);
        profile_run.setEnvironmentVariable("ZIGGURAT_REQUEST_POLICY_EXTENSION", "zig-out/lib");
        b.step("smoke-webview-profile-linux", "Verify explicit persistent profile ownership, admission and first-request restoration").dependOn(&profile_run.step);
        const cookies_smoke = b.addExecutable(.{ .name = "smoke-webview-cookies-linux", .root_module = b.createModule(.{
            .root_source_file = b.path("tests/linux_cookie_store_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view } },
        }) });
        check.dependOn(&cookies_smoke.step);
        const cookies_run = b.addRunArtifact(cookies_smoke);
        cookies_run.step.dependOn(&install_extension.step);
        cookies_run.setEnvironmentVariable("ZIGGURAT_REQUEST_POLICY_EXTENSION", "zig-out/lib");
        b.step("smoke-webview-cookies-linux", "Verify independent profile cookie operations, bounded ownership and shutdown").dependOn(&cookies_run.step);
        const https_smoke = b.addExecutable(.{ .name = "smoke-webview-https-linux", .root_module = b.createModule(.{
            .root_source_file = b.path("tests/linux_profile_https_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view } },
        }) });
        const https_fixture = native_support.add(b, https_smoke.root_module, "profile-https-fixture", "tests/profile_https_fixture.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
        https_fixture.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes });
        https_smoke.root_module.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes });
        check.dependOn(&https_smoke.step);
        const https_run = b.addRunArtifact(https_smoke);
        https_run.step.dependOn(&install_extension.step);
        https_run.setEnvironmentVariable("ZIGGURAT_REQUEST_POLICY_EXTENSION", "zig-out/lib");
        b.step("smoke-webview-https-linux", "Verify frozen profile trust and policy for a host-owned loopback HTTPS service").dependOn(&https_run.step);
        if (https_resources_enabled) {
            const pages_smoke = b.addExecutable(.{ .name = "smoke-https-pages", .root_module = b.createModule(.{
                .root_source_file = b.path("tests/linux_https_page_resources_smoke.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_webview", .module = view }, .{ .name = "ziggurat_https_resources", .module = https_resources }, .{ .name = "ziggurat_native_stream", .module = native_stream } },
            }) });
            const pages_host = native_support.add(b, pages_smoke.root_module, "https-page-resources-host", "tests/https_page_resources_host.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, optimize);
            for ([_][]const u8{ "libsoup-3.0", "gio-unix-2.0" }) |library| {
                pages_host.linkSystemLibrary(library, .{ .use_pkg_config = .yes });
                pages_smoke.root_module.linkSystemLibrary(library, .{ .use_pkg_config = .yes });
            }
            check.dependOn(&pages_smoke.step);
            const pages_run = b.addRunArtifact(pages_smoke);
            pages_run.step.dependOn(&install_extension.step);
            pages_run.setEnvironmentVariable("ZIGGURAT_REQUEST_POLICY_EXTENSION", "zig-out/lib");
            b.step("smoke-https-pages", "Verify WebKit credentials and host HTTPS memory and file resources together").dependOn(&pages_run.step);
        }
    }
    const tests = b.addTest(.{ .root_module = core });
    const webkit_remote_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/webview/webkit_remote.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat_http_response", .module = http_response }} }) });
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
    const ipc_tests = b.addTest(.{ .root_module = ipc });
    const ipc_fixture = b.createModule(.{ .root_source_file = b.path("src/ipc/fixture.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ipc", .module = ipc }} });
    const ipc_fixture_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/ipc_fixture_check.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "ipc", .module = ipc }, .{ .name = "fixture", .module = ipc_fixture } },
    }) });
    const update_tests = b.addTest(.{ .root_module = update });
    const net_tests = b.addTest(.{ .root_module = net });
    const producer_service = b.createModule(.{ .root_source_file = b.path("tests/resource_producer_service.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ziggurat_ipc", .module = ipc }, .{ .name = "ziggurat_resource_stream", .module = resource_stream } } });
    const producer_fixture_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/resource_producer_fixture_check.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "ziggurat_ipc", .module = ipc }, .{ .name = "producer_service", .module = producer_service } },
    }) });
    const asset_tests = b.addTest(.{ .root_module = assets });
    const extension_tests = b.addTest(.{ .root_module = extensions });
    const vector_tests = b.addTest(.{ .root_module = vector });
    const svg_tests = b.addTest(.{ .root_module = svg });
    const shadow_tests = b.addTest(.{ .root_module = shadows });
    const document_tests = b.addTest(.{ .root_module = document });
    const document_diff_tests = b.addTest(.{ .root_module = document_diff });
    const document_diff_view_tests = b.addTest(.{ .root_module = document_diff_view });
    const code_editor_tests = b.addTest(.{ .root_module = code_editor });
    const resource_stream_tests = b.addTest(.{ .root_module = resource_stream });
    const animation_tests = b.addTest(.{ .root_module = animation });
    const producer_tests = b.addTest(.{ .root_module = b.createModule(.{
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
    const shell_tests = b.addTest(.{ .root_module = shell_test_module });
    const clipboard_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/system/clipboard.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ziggurat", .module = core }},
    }) });
    const watch_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/system/watch.zig"), .target = target, .optimize = optimize, .link_libc = target.result.os.tag == .windows }) });
    b.step("test-file-watch", "Run coarse file-watch unit tests").dependOn(&b.addRunArtifact(watch_tests).step);
    const menu_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/system/menus.zig"), .target = target, .optimize = optimize }) });
    const system_extra_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/system/extras_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ziggurat", .module = core }},
    }) });
    check.dependOn(&system_extra_tests.step);
    const run_system_extra_tests = b.addRunArtifact(system_extra_tests);
    test_step.dependOn(&run_system_extra_tests.step);
    b.step("test-system-extras", "Run application paths, menu role, role action, signal quit, jump list, recent document and relaunch tests").dependOn(&run_system_extra_tests.step);
    const system_tests = b.addTest(.{ .root_module = b.createModule(.{
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
        const module_tests = b.addTest(.{ .root_module = module });
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
    const cli_tests = b.addTest(.{ .root_module = cli_module, .use_llvm = true });
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
            const tool_tests = b.addTest(.{ .root_module = module });
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
    const generated_catalog_tests = b.addTest(.{ .root_module = b.createModule(.{
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
    const packaging_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("build_support/packaging.zig"), .target = target, .optimize = optimize }) });
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
    const https_resources_tests = b.addTest(.{ .root_module = https_resources });
    const run_https_resources_tests = b.addRunArtifact(https_resources_tests);
    check.dependOn(&https_resources_tests.step);
    test_step.dependOn(&run_https_resources_tests.step);
    b.step("test-https-resources", "Verify optional HTTPS resource admission, limits and cold capability rejection").dependOn(&run_https_resources_tests.step);
    const site_routes_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/https_resources/site_routes.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ziggurat_http_response", .module = http_response }},
    }) });
    const run_site_routes_tests = b.addRunArtifact(site_routes_tests);
    check.dependOn(&site_routes_tests.step);
    test_step.dependOn(&run_site_routes_tests.step);
    b.step("test-https-site-routes", "Run owned HTTPS route, static response and explicit header policy contracts").dependOn(&run_site_routes_tests.step);
    const http_response_tests = b.addTest(.{ .root_module = http_response });
    const run_http_response_tests = b.addRunArtifact(http_response_tests);
    check.dependOn(&http_response_tests.step);
    test_step.dependOn(&run_http_response_tests.step);
    b.step("test-http-response", "Verify shared HTTP response validation and owned metadata without a browser or server").dependOn(&run_http_response_tests.step);
    const caret_tests = b.addTest(.{ .root_module = caret });
    const run_caret_tests = b.addRunArtifact(caret_tests);
    check.dependOn(&caret_tests.step);
    test_step.dependOn(&run_caret_tests.step);
    b.step("test-caret", "Verify bounded visual caret geometry independently of shaping and native rendering").dependOn(&run_caret_tests.step);
    const gaussian_tests = b.addTest(.{ .root_module = gaussian });
    const run_gaussian_tests = b.addRunArtifact(gaussian_tests);
    check.dependOn(&gaussian_tests.step);
    test_step.dependOn(&run_gaussian_tests.step);
    b.step("test-gaussian", "Verify bounded composed-image Gaussian preparation, worker handoff and resource leases").dependOn(&run_gaussian_tests.step);
    const profile_storage_module = b.createModule(.{ .root_source_file = b.path("src/webview/profile_storage.zig"), .target = target, .optimize = optimize, .link_libc = target.result.os.tag == .windows });
    if (target.result.os.tag == .windows) addWindowsProfileStorageNative(b, profile_storage_module, "profile-storage-test", target, optimize);
    const profile_storage_tests = b.addTest(.{ .root_module = profile_storage_module });
    const run_profile_storage_tests = b.addRunArtifact(profile_storage_tests);
    check.dependOn(&profile_storage_tests.step);
    test_step.dependOn(&run_profile_storage_tests.step);
    b.step("test-profile-storage", "Verify private profile preparation metadata, handoff and ownership without an engine").dependOn(&run_profile_storage_tests.step);
    const profile_tls_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/webview/profile_tls_policy.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat_tls_pem", .module = tls_pem }} }) });
    const run_profile_tls_tests = b.addRunArtifact(profile_tls_tests);
    check.dependOn(&profile_tls_tests.step);
    test_step.dependOn(&run_profile_tls_tests.step);
    b.step("test-profile-tls", "Verify bounded certificate-only profile policy without TLS or an engine").dependOn(&run_profile_tls_tests.step);
    const pem_tests = b.addTest(.{ .root_module = tls_pem });
    const run_pem_tests = b.addRunArtifact(pem_tests);
    check.dependOn(&pem_tests.step);
    test_step.dependOn(&run_pem_tests.step);
    b.step("test-tls-pem", "Verify bounded shared certificate and private-key framing without native TLS").dependOn(&run_pem_tests.step);
    const cookies_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/webview/cookies.zig"), .target = target, .optimize = optimize }) });
    const run_cookies_tests = b.addRunArtifact(cookies_tests);
    check.dependOn(&cookies_tests.step);
    test_step.dependOn(&run_cookies_tests.step);
    b.step("test-cookies", "Verify cookie identity, owned result batches and bounded operation tokens without an engine").dependOn(&run_cookies_tests.step);
    if (target.result.os.tag == .linux) {
        const file_tests = b.addTest(.{ .root_module = b.createModule(.{
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
    const language_protocol_tests = b.addTest(.{ .root_module = language_protocol });
    const run_language_protocol_tests = b.addRunArtifact(language_protocol_tests);
    check.dependOn(&language_protocol_tests.step);
    test_step.dependOn(&run_language_protocol_tests.step);
    b.step("test-language-protocol", "Verify bounded framing, versioned synchronization and explicit language client ownership").dependOn(&run_language_protocol_tests.step);
    const window_placement_tests = b.addTest(.{ .root_module = window_placement });
    const run_window_placement_tests = b.addRunArtifact(window_placement_tests);
    check.dependOn(&window_placement_tests.step);
    test_step.dependOn(&run_window_placement_tests.step);
    b.step("test-window-placement", "Run monitor placement, versioned encoding and explicit worker storage invariants").dependOn(&run_window_placement_tests.step);
    const document_app_tests = b.addTest(.{ .root_module = document_app });
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
    const updater_tests = b.addTest(.{ .root_module = updater });
    const run_updater_tests = b.addRunArtifact(updater_tests);
    check.dependOn(&updater_tests.step);
    test_step.dependOn(&run_updater_tests.step);
    b.step("test-updater", "Run update window sessions, choices, texts and feed backend tests").dependOn(&run_updater_tests.step);
    test_step.dependOn(&run_webkit_remote.step);
    const audio = b.addModule("ziggurat_audio", .{ .root_source_file = b.path("src/audio/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat", .module = core }} });
    audio.link_libc = true;
    if (target.result.os.tag == .windows) audio.linkSystemLibrary("ole32", .{});
    // Pinned third-party decoders: their own warnings and undefined-behavior
    // checks are not this project's to enforce.
    for ([_][]const u8{ "mp3", "vorbis" }) |codec| _ = native_support.add(b, audio, b.fmt("audio-{s}-native", .{codec}), b.fmt("src/audio/{s}.c", .{codec}), &.{ "-std=c99", "-w", "-fno-sanitize=undefined" }, target, optimize);
    const audio_tests = b.addTest(.{ .root_module = audio });
    const run_audio_tests = b.addRunArtifact(audio_tests);
    check.dependOn(&audio_tests.step);
    test_step.dependOn(&run_audio_tests.step);
    b.step("test-audio", "Run WAV/FLAC decoding, mixing, player, stream, notification and test-backend output invariants").dependOn(&run_audio_tests.step);
    addSmoke(b, "smoke-audio", "tests/audio_smoke.zig", target, optimize, &.{.{ .name = "ziggurat_audio", .module = audio }});
    const terminal = b.addModule("ziggurat_terminal", .{ .root_source_file = b.path("src/terminal/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat", .module = core }} });
    terminal.link_libc = true;
    const terminal_tests = b.addTest(.{ .root_module = terminal });
    const run_terminal_tests = b.addRunArtifact(terminal_tests);
    check.dependOn(&terminal_tests.step);
    test_step.dependOn(&run_terminal_tests.step);
    const terminal_view = b.addModule("ziggurat_terminal_view", .{ .root_source_file = b.path("src/terminal/view.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },                  .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_view", .module = declarative_view }, .{ .name = "ziggurat_terminal", .module = terminal },
    } });
    const terminal_view_tests = b.addTest(.{ .root_module = terminal_view });
    const run_terminal_view_tests = b.addRunArtifact(terminal_view_tests);
    check.dependOn(&terminal_view_tests.step);
    test_step.dependOn(&run_terminal_view_tests.step);
    const test_terminal = b.step("test-terminal", "Run escape sequence parsing, screen, scrollback, key and mouse encoding, selection, link, PTY session and terminal view tests");
    test_terminal.dependOn(&run_terminal_tests.step);
    test_terminal.dependOn(&run_terminal_view_tests.step);
    addSmoke(b, "smoke-terminal", "tests/terminal_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_view", .module = declarative_view },
        .{ .name = "ziggurat_terminal", .module = terminal },
        .{ .name = "ziggurat_terminal_view", .module = terminal_view },
    });
    const snippets_tests = b.addTest(.{ .root_module = b.createModule(.{
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
    const document_accessibility_tests = b.addTest(.{ .root_module = document_accessibility });
    const run_document_accessibility_tests = b.addRunArtifact(document_accessibility_tests);
    test_step.dependOn(&run_document_accessibility_tests.step);
    check.dependOn(&document_accessibility_tests.step);
    b.step("test-document-accessibility", "Run complete document text snapshot and ownership invariants").dependOn(&run_document_accessibility_tests.step);
    const diff_accessibility_tests = b.addTest(.{ .root_module = document_diff_accessibility });
    const run_diff_accessibility_tests = b.addRunArtifact(diff_accessibility_tests);
    test_step.dependOn(&run_diff_accessibility_tests.step);
    check.dependOn(&diff_accessibility_tests.step);
    b.step("test-document-diff-accessibility", "Verify optional paired document accessibility ownership and presentation gates").dependOn(&run_diff_accessibility_tests.step);
    inline for (.{
        .{ "test-affine", "affine", "src/ui/affine.zig", "tests/ui_affine.zig" },
        .{ "test-affine-state", "affine_state", "src/ui/affine_state.zig", "tests/ui_affine_state.zig" },
    }) |entry| {
        const math_module = b.createModule(.{ .root_source_file = b.path(entry[2]), .target = target, .optimize = optimize });
        const math_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path(entry[3]), .target = target, .optimize = optimize, .imports = &.{.{ .name = entry[1], .module = math_module }} }) });
        const run_math_tests = b.addRunArtifact(math_tests);
        test_step.dependOn(&run_math_tests.step);
        check.dependOn(&math_tests.step);
        b.step(entry[0], "Run pure coordinate and committed-frame geometry invariants").dependOn(&run_math_tests.step);
    }
    const code_syntax_tests = b.addTest(.{ .root_module = code_syntax });
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
        const initializer_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path(source), .target = target, .optimize = optimize }) });
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
    if (target.result.os.tag == .windows or target.result.os.tag == .linux) {
        const ui_tests = b.addTest(.{ .root_module = ui });
        check.dependOn(&ui_tests.step);
        const run_ui_tests = b.addRunArtifact(ui_tests);
        test_step.dependOn(&run_ui_tests.step);
        b.step("test-ui", "Run UI frame, geometry, widgets and theme contracts").dependOn(&run_ui_tests.step);
        const pointer_controls_tests = b.addTest(.{ .root_module = b.createModule(.{
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
        const shortcut_scopes_tests = b.addTest(.{ .root_module = b.createModule(.{
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
        const text_tests = b.addTest(.{ .root_module = text_layout });
        check.dependOn(&text_tests.step);
        const run_text_tests = b.addRunArtifact(text_tests);
        test_step.dependOn(&run_text_tests.step);
        b.step("test-text-layout", "Run immutable text layout and ownership invariants").dependOn(&run_text_tests.step);
        const drawing_tests = b.addTest(.{ .root_module = drawing_resources });
        check.dependOn(&drawing_tests.step);
        test_step.dependOn(&b.addRunArtifact(drawing_tests).step);
        const image_tests = b.addTest(.{ .root_module = images });
        check.dependOn(&image_tests.step);
        test_step.dependOn(&b.addRunArtifact(image_tests).step);
        const image_drawing_tests = b.addTest(.{ .root_module = image_drawing });
        check.dependOn(&image_drawing_tests.step);
        test_step.dependOn(&b.addRunArtifact(image_drawing_tests).step);
        const shaped_tests = b.addTest(.{ .root_module = shaped_editor });
        const document_editor_tests = b.addTest(.{ .root_module = document_editor });
        check.dependOn(&document_editor_tests.step);
        const run_document_editor_tests = b.addRunArtifact(document_editor_tests);
        test_step.dependOn(&run_document_editor_tests.step);
        b.step("test-document-editor", "Run indexed document editor invariant tests").dependOn(&run_document_editor_tests.step);
        check.dependOn(&shaped_tests.step);
        test_step.dependOn(&b.addRunArtifact(shaped_tests).step);
        const list_tests = b.addTest(.{ .root_module = virtual_list });
        check.dependOn(&list_tests.step);
        const run_list_tests = b.addRunArtifact(list_tests);
        test_step.dependOn(&run_list_tests.step);
        b.step("test-virtual-list", "Run virtual list model and control invariant tests").dependOn(&run_list_tests.step);
        const declarative_view_tests = b.addTest(.{ .root_module = declarative_view });
        check.dependOn(&declarative_view_tests.step);
        const run_declarative_view_tests = b.addRunArtifact(declarative_view_tests);
        test_step.dependOn(&run_declarative_view_tests.step);
        b.step("test-view", "Run declarative view build, identity and layout tests").dependOn(&run_declarative_view_tests.step);
        const markdown_view_tests = b.addTest(.{ .root_module = markdown_view });
        check.dependOn(&markdown_view_tests.step);
        const run_markdown_view_tests = b.addRunArtifact(markdown_view_tests);
        test_step.dependOn(&run_markdown_view_tests.step);
        b.step("test-markdown-view", "Run Markdown to declarative view mapping, wrapping and activation tests").dependOn(&run_markdown_view_tests.step);
        const chart_view = b.addModule("ziggurat_chart_view", .{ .root_source_file = b.path("src/chart/view.zig"), .target = target, .optimize = optimize, .imports = &.{
            .{ .name = "ziggurat", .module = core },                  .{ .name = "ziggurat_ui", .module = ui },
            .{ .name = "ziggurat_view", .module = declarative_view }, .{ .name = "ziggurat_vector", .module = vector },
            .{ .name = "ziggurat_chart", .module = chart },
        } });
        const chart_view_tests = b.addTest(.{ .root_module = chart_view });
        check.dependOn(&chart_view_tests.step);
        const run_chart_view_tests = b.addRunArtifact(chart_view_tests);
        test_step.dependOn(&run_chart_view_tests.step);
        b.step("test-chart-view", "Run chart view arrangement, storage and preparation key tests").dependOn(&run_chart_view_tests.step);
        const view_graphics_tests = b.addTest(.{ .root_module = view_graphics });
        check.dependOn(&view_graphics_tests.step);
        const run_view_graphics_tests = b.addRunArtifact(view_graphics_tests);
        test_step.dependOn(&run_view_graphics_tests.step);
        b.step("test-view-graphics", "Run view icon mask and SVG picture preparation tests").dependOn(&run_view_graphics_tests.step);
        const view_pickers = b.addModule("ziggurat_view_pickers", .{ .root_source_file = b.path("src/view/pickers.zig"), .target = target, .optimize = optimize, .imports = &.{
            .{ .name = "ziggurat", .module = core },                  .{ .name = "ziggurat_ui", .module = ui },
            .{ .name = "ziggurat_view", .module = declarative_view }, .{ .name = "ziggurat_i18n", .module = i18n },
        } });
        const view_pickers_tests = b.addTest(.{ .root_module = view_pickers });
        check.dependOn(&view_pickers_tests.step);
        const run_view_pickers_tests = b.addRunArtifact(view_pickers_tests);
        test_step.dependOn(&run_view_pickers_tests.step);
        b.step("test-view-pickers", "Run calendar, date, time, number and color picker tests").dependOn(&run_view_pickers_tests.step);
        const view_collections = b.addModule("ziggurat_view_collections", .{ .root_source_file = b.path("src/view/collections.zig"), .target = target, .optimize = optimize, .imports = &.{
            .{ .name = "ziggurat", .module = core },                  .{ .name = "ziggurat_ui", .module = ui },
            .{ .name = "ziggurat_view", .module = declarative_view },
        } });
        const view_collections_tests = b.addTest(.{ .root_module = view_collections });
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
        const game = b.addModule("ziggurat_game", .{ .root_source_file = b.path("src/game/root.zig"), .target = target, .optimize = optimize, .imports = &.{
            .{ .name = "ziggurat", .module = core },                  .{ .name = "ziggurat_ui", .module = ui },
            .{ .name = "ziggurat_view", .module = declarative_view },
        } });
        const game_tests = b.addTest(.{ .root_module = game });
        check.dependOn(&game_tests.step);
        const run_game_tests = b.addRunArtifact(game_tests);
        test_step.dependOn(&run_game_tests.step);
        b.step("test-game", "Run game loop, camera, scaling and gamepad tests").dependOn(&run_game_tests.step);
    }
    const rich_text = b.addModule("ziggurat_rich_text", .{ .root_source_file = b.path("src/rich_text/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat_markdown", .module = markdown }} });
    const rich_text_tests = b.addTest(.{ .root_module = rich_text });
    const run_rich_text_tests = b.addRunArtifact(rich_text_tests);
    check.dependOn(&rich_text_tests.step);
    test_step.dependOn(&run_rich_text_tests.step);
    const test_rich_text = b.step("test-rich-text", "Run attributed text, document, undo, HTML, RTF, Markdown and clipboard codec tests");
    test_rich_text.dependOn(&run_rich_text_tests.step);
    const rich_text_editor = b.addModule("ziggurat_rich_text_editor", .{ .root_source_file = b.path("src/rich_text/editor.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },                  .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_view", .module = declarative_view }, .{ .name = "ziggurat_rich_text", .module = rich_text },
    } });
    const rich_text_editor_tests = b.addTest(.{ .root_module = rich_text_editor });
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
    rich_text_editor.addImport("ziggurat_fonts", fonts);
    const fonts_tests = b.addTest(.{ .root_module = fonts });
    const run_fonts_tests = b.addRunArtifact(fonts_tests);
    check.dependOn(&fonts_tests.step);
    test_step.dependOn(&run_fonts_tests.step);
    b.step("test-fonts", "Run font family and registration tests").dependOn(&run_fonts_tests.step);
    if (target.result.os.tag == .windows or target.result.os.tag == .linux) addSmoke(b, "smoke-fonts", "tests/fonts_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat_fonts", .module = fonts }, .{ .name = "ziggurat_text_layout", .module = text_layout },
    });
    addExamples(b, target, optimize);
    shareCommonModules(b, target, optimize, check, test_step);
}

/// Every module may import the process-wide Io (`ziggurat_io`) and the system
/// declarations (`ziggurat_c_win32`, `ziggurat_c_gtk`, `ziggurat_c_posix`).
/// They are added to each module reachable from a step or an exported module.
fn shareCommonModules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, check: *std.Build.Step, test_step: *std.Build.Step) void {
    // Shared modules leave target and optimization to the module importing them.
    const io = b.addModule("ziggurat_io", .{ .root_source_file = b.path("src/io/root.zig") });
    const io_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/io/root.zig"), .target = target, .optimize = optimize }) });
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

fn collectStep(b: *std.Build, modules: *std.AutoArrayHashMapUnmanaged(*std.Build.Module, void), steps: *std.AutoArrayHashMapUnmanaged(*std.Build.Step, void), step: *std.Build.Step) void {
    if ((steps.getOrPut(b.allocator, step) catch @panic("OOM")).found_existing) return;
    if (step.cast(std.Build.Step.Compile)) |compile| collectModule(b, modules, compile.root_module);
    // A run step names the executable it runs without depending on its step.
    if (step.cast(std.Build.Step.Run)) |run| if (run.producer) |producer| collectStep(b, modules, steps, &producer.step);
    for (step.dependencies.items) |dependency| collectStep(b, modules, steps, dependency);
}

fn collectModule(b: *std.Build, modules: *std.AutoArrayHashMapUnmanaged(*std.Build.Module, void), module: *std.Build.Module) void {
    if ((modules.getOrPut(b.allocator, module) catch @panic("OOM")).found_existing) return;
    for (module.import_table.values()) |import| collectModule(b, modules, import);
}

const app_example_imports = [_][]const u8{
    "ziggurat",               "ziggurat_ui",               "ziggurat_view",             "ziggurat_view_timer",
    "ziggurat_view_text",     "ziggurat_document",         "ziggurat_document_editor",  "ziggurat_wake",
    "ziggurat_system",        "ziggurat_i18n",             "ziggurat_animation",        "ziggurat_document_app",
    "ziggurat_chart",         "ziggurat_chart_view",       "ziggurat_audio",            "ziggurat_code_editor",
    "ziggurat_text_layout",   "ziggurat_window_placement", "ziggurat_game",             "ziggurat_terminal",
    "ziggurat_terminal_view", "ziggurat_rich_text",        "ziggurat_rich_text_editor", "ziggurat_rich_text_clipboard",
    "ziggurat_text_measure",  "ziggurat_markdown",         "ziggurat_markdown_view",    "ziggurat_vector",
    "ziggurat_text_outlines",
};

const Example = struct { name: []const u8, path: []const u8, web: bool = false };

const app_examples = [_]Example{
    .{ .name = "hello", .path = "examples/hello.zig" },
    .{ .name = "todo", .path = "examples/todo.zig" },
    .{ .name = "notes", .path = "examples/notes.zig" },
    .{ .name = "gallery", .path = "examples/gallery.zig" },
    .{ .name = "frameless", .path = "examples/frameless.zig" },
    .{ .name = "menubar", .path = "examples/menubar.zig" },
    .{ .name = "clipboard", .path = "examples/clipboard.zig" },
    .{ .name = "drag-drop", .path = "examples/drag_drop.zig" },
    .{ .name = "text-input", .path = "examples/text_input.zig" },
    .{ .name = "code-editor", .path = "examples/code_editor.zig" },
    .{ .name = "chart-streaming", .path = "examples/chart_streaming.zig" },
    .{ .name = "piano", .path = "examples/piano.zig" },
    .{ .name = "launcher", .path = "examples/launcher.zig" },
    .{ .name = "timeline", .path = "examples/timeline.zig" },
    .{ .name = "i18n", .path = "examples/i18n.zig" },
    .{ .name = "farm", .path = "examples/farm.zig" },
    .{ .name = "loading", .path = "examples/loading.zig" },
    .{ .name = "terminal", .path = "examples/terminal.zig" },
    .{ .name = "text-buffer", .path = "examples/text_buffer.zig" },
    .{ .name = "native", .path = "examples/native.zig" },
    .{ .name = "flyout", .path = "examples/flyout.zig" },
    .{ .name = "menubar-flyout", .path = "examples/menubar_flyout.zig" },
    .{ .name = "markdown-chat", .path = "examples/markdown_chat.zig" },
    .{ .name = "confetti", .path = "examples/confetti.zig" },
    .{ .name = "effort-slider", .path = "examples/effort_slider.zig" },
    .{ .name = "chat-glow", .path = "examples/chat_glow.zig" },
    .{ .name = "blackhole", .path = "examples/blackhole.zig" },
    .{ .name = "wind", .path = "examples/wind.zig" },
    .{ .name = "mayoi", .path = "examples/mayoi.zig" },
    .{ .name = "rich-text", .path = "examples/rich_text.zig" },
    .{ .name = "hybrid", .path = "examples/hybrid.zig", .web = true },
};

/// Registers every application example under `run-<name>` and `example-<name>`, and compiles them in `check`.
/// Examples use only public modules; WebView examples require `-Dwebview=true`.
fn addExamples(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    if (target.result.os.tag != .windows and target.result.os.tag != .linux) return;
    const all = b.step("examples", "Compile every application example");
    const tests = b.step("test-examples", "Run the headless view tests inside the application examples");
    b.top_level_steps.get("test").?.step.dependOn(tests);
    var imports: [app_example_imports.len + 1]std.Build.Module.Import = undefined;
    for (app_example_imports, 0..) |name, index| imports[index] = .{ .name = name, .module = b.modules.get(name) orelse @panic(name) };
    const webview = b.modules.get("ziggurat_webview");
    for (app_examples) |example| {
        var count: usize = app_example_imports.len;
        if (example.web) {
            imports[count] = .{ .name = "ziggurat_webview", .module = webview orelse continue };
            count += 1;
        }
        const exe = addExample(b, example.name, example.path, target, optimize, b.allocator.dupe(std.Build.Module.Import, imports[0..count]) catch @panic("OOM"));
        all.dependOn(&exe.step);
        const example_tests = b.addTest(.{ .name = b.fmt("example-{s}-test", .{example.name}), .root_module = exe.root_module });
        b.top_level_steps.get("check").?.step.dependOn(&example_tests.step);
        const run_example_tests = b.addRunArtifact(example_tests);
        tests.dependOn(&run_example_tests.step);
        b.step(b.fmt("test-example-{s}", .{example.name}), b.fmt("Run the headless view tests inside {s}", .{example.name})).dependOn(&run_example_tests.step);
    }
}

fn sourcePath(b: *std.Build, path: []const u8) std.Build.LazyPath {
    return if (std.fs.path.isAbsolute(path)) .{ .cwd_relative = path } else b.path(path);
}

fn addExample(b: *std.Build, name: []const u8, path: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, imports: []const std.Build.Module.Import) *std.Build.Step.Compile {
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

fn addLinuxPointerCoreSmoke(b: *std.Build, check: *std.Build.Step, core: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
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

fn addPointerCostSmoke(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module) void {
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

fn addWebNativeBoundarySmoke(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module, view: *std.Build.Module) void {
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
fn addWindowsProfileNative(b: *std.Build, owner: *std.Build.Module, prefix: []const u8, sdk: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const native = native_support.add(b, owner, b.fmt("{s}-windows_profile.c", .{prefix}), "src/webview/windows_profile.c", &.{"-std=c11"}, target, optimize);
    native.addIncludePath(sourcePath(b, b.pathJoin(&.{ sdk, "build/native/include" })));
    native.addIncludePath(b.path("src/webview/include"));
    owner.linkSystemLibrary("crypt32", .{});
    addWindowsProfileStorageNative(b, owner, prefix, target, optimize);
}

/// Profile storage preparation and process lifetime need no WebView2 SDK.
fn addWindowsProfileStorageNative(b: *std.Build, owner: *std.Build.Module, prefix: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    for ([_][]const u8{ "windows_profile_lifetime.c", "windows_profile_storage.c" }) |file|
        _ = native_support.add(b, owner, b.fmt("{s}-{s}", .{ prefix, file }), b.fmt("src/webview/{s}", .{file}), &.{"-std=c11"}, target, optimize);
    owner.linkSystemLibrary("advapi32", .{});
}

/// Single-instance, registration, power and taskbar natives of ziggurat_system.
fn addSystemIntegrationNative(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    switch (target.result.os.tag) {
        .windows => {
            _ = native_support.add(b, module, "system-taskbar-native", "src/system/taskbar_windows.c", &.{"-std=c11"}, target, optimize);
            _ = native_support.add(b, module, "system-jump-list-native", "src/system/jump_list_windows.c", &.{"-std=c11"}, target, optimize);
            for ([_][]const u8{ "advapi32", "ole32", "shell32" }) |library| module.linkSystemLibrary(library, .{});
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
        else => {},
    }
}

/// One end-to-end page: the runtime package bundled into a hidden window.
fn addPageRuntimeSmoke(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module, view: *std.Build.Module, ipc: *std.Build.Module, i18n: *std.Build.Module, page_runtime: *std.Build.Module, net: *std.Build.Module, plugin_fetch: *std.Build.Module, plugin_watch: *std.Build.Module, plugin_sqlite: *std.Build.Module, plugin_websocket: *std.Build.Module) void {
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
fn addEmbeddedWebView(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module, ui: *std.Build.Module, declarative_view: *std.Build.Module, view: *std.Build.Module) void {
    const embedded = b.addModule("ziggurat_webview_view", .{ .root_source_file = b.path("src/webview/embedded.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_view", .module = declarative_view },
        .{ .name = "ziggurat_webview", .module = view },
    } });
    addSmoke(b, "smoke-embedded-webview", "tests/embedded_webview_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_view", .module = declarative_view },
        .{ .name = "ziggurat_webview", .module = view },
        .{ .name = "ziggurat_webview_view", .module = embedded },
    });
}

fn addSmoke(b: *std.Build, name: []const u8, path: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, imports: []const std.Build.Module.Import) void {
    _ = addSmokeExecutable(b, name, path, target, optimize, imports);
}

/// Like addSmoke, returning the root module for native test fixtures.
fn addSmokeModule(b: *std.Build, name: []const u8, path: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, imports: []const std.Build.Module.Import) *std.Build.Module {
    return addSmokeExecutable(b, name, path, target, optimize, imports).root_module;
}

/// addSmoke that returns the executable for test-only native additions.
fn addSmokeExecutable(b: *std.Build, name: []const u8, path: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, imports: []const std.Build.Module.Import) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize, .imports = imports }),
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
    if (exe.root_module.resolved_target.?.result.os.tag != .windows) return;
    const file = iconFile(b, dependency.path("tools/icon_main.zig"), dependency.path("assets/application.ico"), icon);
    _ = packaging.addWindowsResources(b, exe, .{ .metadata = metadata, .icon = file }) catch |err| std.debug.panic("invalid application resources: {s}", .{@errorName(err)});
}

/// The .ico of `icon`: a PNG is rendered by the icon tool, built for the
/// machine that runs the build.
fn iconFile(b: *std.Build, tool_source: std.Build.LazyPath, default: std.Build.LazyPath, icon: ApplicationIcon) std.Build.LazyPath {
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
fn addHttpAuthSmoke(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module, view: *std.Build.Module) *std.Build.Step.Run {
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

fn runInstalled(b: *std.Build, executable: std.Build.LazyPath) *std.Build.Step.Run {
    if (b.graph.host.result.os.tag == .windows) return b.addRunFile(executable);
    const run = b.addSystemCommand(&.{ "/bin/sh", "-c", "n=0; while :; do \"$0\" \"$@\"; s=$?; if [ $s -ne 126 ] || [ $n -ge 20 ]; then exit $s; fi; n=$((n + 1)); sleep 0.1; done" });
    run.addFileArg(executable);
    return run;
}

fn addResources(b: *std.Build, exe: *std.Build.Step.Compile) void {
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
