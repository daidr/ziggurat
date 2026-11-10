//! The application examples: every entry in `app_examples` gets `run-<name>`,
//! `example-<name>` and `test-example-<name>` on Windows, Linux and macOS, and
//! entries marked `browser` are built for wasm32 too.
const std = @import("std");
const helpers = @import("helpers.zig");
const addExample = helpers.addExample;
const addWebApp = helpers.addWebApp;
const addTest = helpers.addTest;

pub const app_example_imports = [_][]const u8{
    "ziggurat",               "ziggurat_ui",               "ziggurat_view",             "ziggurat_view_timer",
    "ziggurat_view_text",     "ziggurat_document",         "ziggurat_document_editor",  "ziggurat_wake",
    "ziggurat_system",        "ziggurat_i18n",             "ziggurat_animation",        "ziggurat_document_app",
    "ziggurat_chart",         "ziggurat_chart_view",       "ziggurat_audio",            "ziggurat_code_editor",
    "ziggurat_text_layout",   "ziggurat_window_placement", "ziggurat_game",             "ziggurat_terminal",
    "ziggurat_terminal_view", "ziggurat_rich_text",        "ziggurat_rich_text_editor", "ziggurat_rich_text_clipboard",
    "ziggurat_text_measure",  "ziggurat_markdown",         "ziggurat_markdown_view",    "ziggurat_vector",
    "ziggurat_text_outlines", "ziggurat_view_video",       "ziggurat_video",
};

/// `web` examples show web pages and need `-Dwebview=true`; `browser`
/// examples are built for browsers too (`-Dtarget=wasm32-wasi`): those
/// that start threads of their own, run a shell, show web pages or need
/// menu bars, trays or dropped files, which browsers lack, are not.
pub const Example = struct { name: []const u8, path: []const u8, web: bool = false, browser: bool = false };

pub const app_examples = [_]Example{
    .{ .name = "hello", .path = "examples/hello.zig", .browser = true },
    .{ .name = "todo", .path = "examples/todo.zig", .browser = true },
    .{ .name = "notes", .path = "examples/notes.zig" },
    .{ .name = "gallery", .path = "examples/gallery.zig", .browser = true },
    .{ .name = "frameless", .path = "examples/frameless.zig", .browser = true },
    .{ .name = "menubar", .path = "examples/menubar.zig" },
    .{ .name = "clipboard", .path = "examples/clipboard.zig", .browser = true },
    .{ .name = "drag-drop", .path = "examples/drag_drop.zig" },
    .{ .name = "text-input", .path = "examples/text_input.zig", .browser = true },
    .{ .name = "code-editor", .path = "examples/code_editor.zig" },
    .{ .name = "chart-streaming", .path = "examples/chart_streaming.zig" },
    .{ .name = "piano", .path = "examples/piano.zig", .browser = true },
    .{ .name = "launcher", .path = "examples/launcher.zig" },
    .{ .name = "timeline", .path = "examples/timeline.zig", .browser = true },
    .{ .name = "i18n", .path = "examples/i18n.zig", .browser = true },
    .{ .name = "farm", .path = "examples/farm.zig", .browser = true },
    .{ .name = "loading", .path = "examples/loading.zig", .browser = true },
    .{ .name = "terminal", .path = "examples/terminal.zig" },
    .{ .name = "text-buffer", .path = "examples/text_buffer.zig", .browser = true },
    .{ .name = "native", .path = "examples/native.zig" },
    .{ .name = "flyout", .path = "examples/flyout.zig", .browser = true },
    .{ .name = "menubar-flyout", .path = "examples/menubar_flyout.zig" },
    .{ .name = "markdown-chat", .path = "examples/markdown_chat.zig", .browser = true },
    .{ .name = "confetti", .path = "examples/confetti.zig", .browser = true },
    .{ .name = "effort-slider", .path = "examples/effort_slider.zig", .browser = true },
    .{ .name = "chat-glow", .path = "examples/chat_glow.zig", .browser = true },
    .{ .name = "liquid-glass", .path = "examples/liquid_glass.zig", .browser = true },
    .{ .name = "blackhole", .path = "examples/blackhole.zig" },
    .{ .name = "wind", .path = "examples/wind.zig" },
    .{ .name = "mayoi", .path = "examples/mayoi.zig" },
    .{ .name = "rich-text", .path = "examples/rich_text.zig", .browser = true },
    .{ .name = "video", .path = "examples/video.zig", .browser = true },
    .{ .name = "hybrid", .path = "examples/hybrid.zig", .web = true },
};

/// Registers every application example under `run-<name>` and `example-<name>`, and compiles them in `check`.
/// Examples use only public modules; WebView examples require `-Dwebview=true`.
pub fn addExamples(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    if (target.result.os.tag != .windows and target.result.os.tag != .linux and target.result.os.tag != .macos and target.result.cpu.arch != .wasm32) return;
    const all = b.step("examples", "Compile every application example");
    const tests = b.step("test-examples", "Run the headless view tests inside the application examples");
    // Windows pull request checks leave these out of `test`: they are the same
    // headless tests on every platform, and Linux and macOS run them.
    if (b.option(bool, "example-tests", "Include the examples' headless view tests in `test` (default true)") orelse true)
        b.top_level_steps.get("test").?.step.dependOn(tests);
    var imports: [app_example_imports.len + 1]std.Build.Module.Import = undefined;
    // Browsers have fewer modules: an example is built for them when it is
    // listed in `web_examples`, with the modules there are.
    const web = target.result.cpu.arch == .wasm32;
    var available: usize = 0;
    for (app_example_imports) |name| {
        imports[available] = .{ .name = name, .module = b.modules.get(name) orelse if (web) continue else @panic(name) };
        available += 1;
    }
    const webview = b.modules.get("ziggurat_webview");
    for (app_examples) |example| {
        if (web and !example.browser) continue;
        var count: usize = available;
        if (example.web) {
            imports[count] = .{ .name = "ziggurat_webview", .module = webview orelse continue };
            count += 1;
        }
        const exe = addExample(b, example.name, example.path, target, optimize, b.allocator.dupe(std.Build.Module.Import, imports[0..count]) catch @panic("OOM"));
        all.dependOn(&exe.step);
        if (target.result.cpu.arch == .wasm32) {
            addWebApp(b, exe);
            continue;
        }
        const example_tests = addTest(b, .{ .name = b.fmt("example-{s}-test", .{example.name}), .root_module = exe.root_module });
        b.top_level_steps.get("check").?.step.dependOn(&example_tests.step);
        const run_example_tests = b.addRunArtifact(example_tests);
        tests.dependOn(&run_example_tests.step);
        b.step(b.fmt("test-example-{s}", .{example.name}), b.fmt("Run the headless view tests inside {s}", .{example.name})).dependOn(&run_example_tests.step);
    }
}
