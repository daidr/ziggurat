//! The optional system WebView (`-Dwebview=true`), one function per platform.
const std = @import("std");
const native_support = @import("native.zig");
const helpers = @import("helpers.zig");
const sourcePath = helpers.sourcePath;
const addExample = helpers.addExample;
const addWebNativeBoundarySmoke = helpers.addWebNativeBoundarySmoke;
const addWindowsProfileNative = helpers.addWindowsProfileNative;
const addPageRuntimeSmoke = helpers.addPageRuntimeSmoke;
const addEmbeddedWebView = helpers.addEmbeddedWebView;
const addSmoke = helpers.addSmoke;
const addSmokeModule = helpers.addSmokeModule;
const addHttpAuthSmoke = helpers.addHttpAuthSmoke;
const addTest = helpers.addTest;

pub fn addMacos(b: *std.Build, c: anytype) void {
    const target = c.target;
    const optimize = c.optimize;
    const core = c.core;
    const file_stream = c.file_stream;
    const http_response = c.http_response;
    const automation = c.automation;
    const tls_pem = c.tls_pem;
    const view_tests = c.view_tests;
    const ui = c.ui;
    const declarative_view = c.declarative_view;
    const view = b.addModule("ziggurat_webview", .{
        .root_source_file = b.path("src/webview/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_file_stream", .module = file_stream }, .{ .name = "ziggurat_http_response", .module = http_response } },
        .link_libc = true,
    });
    automation.addImport("ziggurat_webview", view);
    view.addImport("ziggurat_tls_pem", tls_pem);
    _ = native_support.add(b, view, "webview-webkit-macos", "src/webview/webkit_macos.m", &.{ "-fobjc-arc", "-Wall", "-Wextra", "-Werror" }, target, optimize);
    native_support.linkFrameworks(b, view, &.{ "WebKit", "AppKit", "QuartzCore", "CoreGraphics", "Foundation", "CoreFoundation", "Security" });
    view_tests.* = addTest(b, .{ .root_module = view });
    _ = b.step("webview-runtime", "Use the system WKWebView");
    _ = addExample(b, "web-counter", "examples/web_counter.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_webview", .module = view },
    });
    _ = addExample(b, "rectangular-pages", "examples/rectangular_pages.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_ui", .module = ui },
        .{ .name = "ziggurat_webview", .module = view },
    });
    addSmoke(b, "smoke-webview-macos", "tests/macos_webview_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_webview", .module = view },
    });
    addSmoke(b, "smoke-webview-content-rules", "tests/content_rules_webview_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_webview", .module = view },
    });
    addSmoke(b, "smoke-webview-context-menu", "tests/context_menu_webview_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_webview", .module = view },
    });
    addSmoke(b, "smoke-webview-local-macos", "tests/macos_local_webview_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_webview", .module = view },
    });
    const remote_smoke = addSmokeModule(b, "smoke-webview-remote-macos", "tests/macos_remote_webview_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_webview", .module = view },
    });
    remote_smoke.link_libc = true;
    remote_smoke.addCSourceFile(.{ .file = b.path("tests/macos_remote_fixture.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    addSmoke(b, "smoke-webview-find-macos", "tests/macos_find_webview_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_webview", .module = view },
    });
    addSmoke(b, "smoke-webview-capture-macos", "tests/macos_capture_webview_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_webview", .module = view },
    });
    addSmoke(b, "smoke-webview-profile-macos", "tests/macos_profile_webview_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_webview", .module = view },
    });
    addSmoke(b, "smoke-webview-cookies-macos", "tests/macos_cookie_store_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_webview", .module = view },
    });
    addSmoke(b, "smoke-webview-initializers-macos", "tests/macos_document_initializers_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_webview", .module = view },
    });
    _ = addHttpAuthSmoke(b, target, optimize, core, view);
    addSmoke(b, "smoke-webview-files-macos", "tests/macos_file_response_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_webview", .module = view },
    });
    addSmoke(b, "smoke-webview-permissions-macos", "tests/macos_permission_webview_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_webview", .module = view },
    });
    addSmoke(b, "smoke-webview-regions-macos", "tests/macos_regions_webview_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_webview", .module = view },
    });
    addSmoke(b, "smoke-webview-downloads-macos", "tests/macos_download_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_webview", .module = view },
    });
    addSmoke(b, "smoke-webview-session-state", "tests/session_state_webview_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_webview", .module = view },
    });
    addEmbeddedWebView(b, target, optimize, core, ui, declarative_view, view);
}

pub fn addWindows(b: *std.Build, c: anytype) void {
    const target = c.target;
    const optimize = c.optimize;
    const core = c.core;
    const file_stream = c.file_stream;
    const http_response = c.http_response;
    const automation = c.automation;
    const tls_pem = c.tls_pem;
    const ipc = c.ipc;
    const resource_stream = c.resource_stream;
    const view_tests = c.view_tests;
    const check = c.check;
    const https_resources_enabled = c.https_resources_enabled;
    const https_resources = c.https_resources;
    const native_stream = c.native_stream;
    const ui = c.ui;
    const initializer_native_run = c.initializer_native_run;
    const assets = c.assets;
    const i18n = c.i18n;
    const page_runtime = c.page_runtime;
    const net = c.net;
    const plugin_fetch = c.plugin_fetch;
    const plugin_watch = c.plugin_watch;
    const plugin_sqlite = c.plugin_sqlite;
    const plugin_websocket = c.plugin_websocket;
    const declarative_view = c.declarative_view;
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
    automation.addImport("ziggurat_webview", view);
    view.addImport("ziggurat_tls_pem", tls_pem);
    for ([_][]const u8{ "webview2.c", "page_host.c", "windows_cookies.c" }) |file| {
        const native = native_support.add(b, view, b.fmt("webview-{s}", .{file}), b.fmt("src/webview/{s}", .{file}), &.{"-std=c11"}, target, optimize);
        native.addIncludePath(sourcePath(b, b.pathJoin(&.{ sdk, "build/native/include" })));
        native.addIncludePath(b.path("src/webview/include"));
    }
    addWindowsProfileNative(b, view, "webview", sdk, target, optimize);
    view.linkSystemLibrary("ole32", .{});
    view.linkSystemLibrary("shlwapi", .{});
    view.linkSystemLibrary("urlmon", .{});
    view.linkSystemLibrary("oleaut32", .{});
    // Web views in native UI subclass their window (webview2_embed.h).
    view.linkSystemLibrary("comctl32", .{});
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
    view_tests.* = addTest(b, .{ .root_module = view });
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
    for ([_][]const u8{ "ole32", "shlwapi", "urlmon", "oleaut32", "crypt32", "comctl32" }) |library| credentials_view.linkSystemLibrary(library, .{});
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
    for ([_][]const u8{ "ole32", "shlwapi", "urlmon", "oleaut32", "crypt32", "comctl32" }) |library| initializers_view.linkSystemLibrary(library, .{});
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
    addSmoke(b, "smoke-webview-content-rules", "tests/content_rules_webview_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_webview", .module = view },
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
    for ([_][]const u8{ "user32", "ole32", "shlwapi", "gdi32", "urlmon", "oleaut32", "comctl32" }) |library| page_authorization.root_module.linkSystemLibrary(library, .{});
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
    for ([_][]const u8{ "user32", "ole32", "shlwapi", "gdi32", "urlmon", "oleaut32", "comctl32" }) |library| initializer_native.root_module.linkSystemLibrary(library, .{});
    check.dependOn(&initializer_native.step);
    initializer_native_run.* = b.addRunArtifact(initializer_native);
    b.step("test-document-initializers-native", "Run native document initializer mutation and lifetime contracts without a Runtime").dependOn(&initializer_native_run.*.?.step);
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
    addSmoke(b, "smoke-webview-cookies-windows", "tests/windows_cookie_store_smoke.zig", target, optimize, &.{
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

pub fn addLinux(b: *std.Build, c: anytype) void {
    const target = c.target;
    const optimize = c.optimize;
    const core = c.core;
    const file_stream = c.file_stream;
    const http_response = c.http_response;
    const automation = c.automation;
    const tls_pem = c.tls_pem;
    const check = c.check;
    const webkit_file_run = c.webkit_file_run;
    const view_tests = c.view_tests;
    const ipc = c.ipc;
    const i18n = c.i18n;
    const page_runtime = c.page_runtime;
    const net = c.net;
    const plugin_fetch = c.plugin_fetch;
    const plugin_watch = c.plugin_watch;
    const plugin_sqlite = c.plugin_sqlite;
    const plugin_websocket = c.plugin_websocket;
    const ui = c.ui;
    const declarative_view = c.declarative_view;
    const test_step = c.test_step;
    const https_resources_enabled = c.https_resources_enabled;
    const https_resources = c.https_resources;
    const native_stream = c.native_stream;
    const view = b.addModule("ziggurat_webview", .{
        .root_source_file = b.path("src/webview/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "ziggurat", .module = core }, .{ .name = "ziggurat_file_stream", .module = file_stream }, .{ .name = "ziggurat_http_response", .module = http_response } },
        .link_libc = true,
    });
    automation.addImport("ziggurat_webview", view);
    view.addImport("ziggurat_tls_pem", tls_pem);
    for ([_][]const u8{ "webkit_native.c", "webkit_profile.c", "webkit_cookies.c", "webkit_content_rules.c" }) |file| {
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
    const file_tests = addTest(b, .{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/webkit_file_test.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{ .{ .name = "file_responses", .module = file_response_module }, .{ .name = "ziggurat_file_stream", .module = test_file_stream } } }) });
    const file_test_helper = native_support.add(b, file_tests.root_module, "file-stream-test-helper", "tests/webkit_file_test.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-DZWK_FILE_TESTING" }, target, optimize);
    file_test_helper.linkSystemLibrary("gio-unix-2.0", .{ .use_pkg_config = .force });
    file_tests.root_module.linkSystemLibrary("gio-unix-2.0", .{ .use_pkg_config = .force });
    check.dependOn(&file_tests.step);
    webkit_file_run.* = b.addRunArtifact(file_tests);
    b.step("test-webkit-file", "Verify explicit file pumps, socket readiness, cancellation and physical lifetime without a browser").dependOn(&webkit_file_run.*.?.step);
    const profile_module = b.createModule(.{ .root_source_file = b.path("src/webview/profile.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ziggurat_tls_pem", .module = tls_pem }} });
    const profile_tests = addTest(b, .{ .root_module = b.createModule(.{
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
    const dmabuf_tests = addTest(b, .{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/webkit_dmabuf_linux.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    const dmabuf_native = native_support.add(b, dmabuf_tests.root_module, "webkit-dmabuf-native-test", "src/webview/webkit_profile.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-DZWK_PROFILE_TESTING" }, target, optimize);
    dmabuf_native.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes });
    dmabuf_tests.root_module.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes });
    check.dependOn(&dmabuf_tests.step);
    b.step("test-webkit-dmabuf", "Decide whether WebKitGTK's DMA-BUF renderer stays on from the app's choice, the user's variable and the host").dependOn(&b.addRunArtifact(dmabuf_tests).step);
    const profile_tls_owner_tests = addTest(b, .{ .root_module = b.createModule(.{
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
    const cookies_owner_tests = addTest(b, .{ .root_module = b.createModule(.{
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
    view_tests.* = addTest(b, .{ .root_module = view });
    _ = b.step("webview-runtime", "Use the installed WebKitGTK 4.1 runtime");
    addWebNativeBoundarySmoke(b, target, optimize, core, view);
    addPageRuntimeSmoke(b, target, optimize, core, view, ipc, i18n, page_runtime, net, plugin_fetch, plugin_watch, plugin_sqlite, plugin_websocket);
    addEmbeddedWebView(b, target, optimize, core, ui, declarative_view, view);
    addSmoke(b, "smoke-webview-linux", "tests/linux_webview_smoke.zig", target, optimize, &.{
        .{ .name = "ziggurat", .module = core },
        .{ .name = "ziggurat_webview", .module = view },
    });
    addSmoke(b, "smoke-webview-content-rules", "tests/content_rules_webview_smoke.zig", target, optimize, &.{
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
